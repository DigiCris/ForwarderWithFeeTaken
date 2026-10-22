// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Forwarder} from "../src/Forwarder.sol";
import {MockERC20} from "./mocks/MockTokens.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockVault, NotAVault} from "./mocks/MockVault.sol";
import {VaultChangeHandler} from "./invariants/VaultChangeHandler.sol";
import {ForwarderTestBase} from "./utils/ForwarderTestBase.sol";

/// @dev Targeted invariants of the vault change lifecycle (see VaultChangeHandler).
contract ForwarderVaultChangeInvariantTest is ForwarderTestBase {
    VaultChangeHandler internal handler;
    bytes32 internal initialCodehash;
    address internal feeManagerGuardian = makeAddr("feeManagerGuardian");

    function setUp() public override {
        usdc = new MockUSDC();
        vault = new MockVault(IERC20(address(usdc)));
        address[] memory managers = new address[](2);
        managers[0] = feeManager;
        managers[1] = feeManagerGuardian;
        address[] memory guardians = new address[](3);
        guardians[0] = guardian;
        guardians[1] = guardian2;
        guardians[2] = feeManagerGuardian;
        _fundDeployment();
        forwarder = new Forwarder(
            IERC20(address(usdc)),
            admin,
            ADMIN_DELAY,
            treasury,
            IERC4626(address(vault)),
            DIRECT_DIRECT,
            managers,
            guardians
        );
        FEE_MANAGER_ROLE = forwarder.FEE_MANAGER_ROLE();
        DEFAULT_ADMIN_ROLE = forwarder.DEFAULT_ADMIN_ROLE();
        VAULT_GUARDIAN_ROLE = forwarder.VAULT_GUARDIAN_ROLE();

        MockVault[] memory vaults = new MockVault[](4);
        vaults[0] = vault;
        vaults[1] = new MockVault(IERC20(address(usdc)));
        vaults[2] = new MockVault(IERC20(address(usdc)));
        vaults[3] = new MockVault(IERC20(address(usdc)));
        vaults[3].setRedeemReverts(true); // always fails the health check
        address[] memory invalid = new address[](4);
        invalid[0] = makeAddr("eoa-candidate");
        invalid[1] = address(new NotAVault());
        invalid[2] = address(new MockVault(IERC20(address(new MockERC20("Other", "OTH", 6)))));
        invalid[3] = address(0);
        address[] memory handlerGuardians = new address[](2);
        handlerGuardians[0] = guardian;
        handlerGuardians[1] = guardian2;

        handler = new VaultChangeHandler(
            forwarder, usdc, admin, vaults, invalid, handlerGuardians, feeManager, feeManagerGuardian, treasury
        );
        initialCodehash = address(forwarder).codehash;

        bytes4[] memory selectors = new bytes4[](17);
        selectors[0] = VaultChangeHandler.propose.selector;
        selectors[1] = VaultChangeHandler.propose.selector;
        selectors[2] = VaultChangeHandler.cancel.selector;
        selectors[3] = VaultChangeHandler.execute.selector;
        selectors[4] = VaultChangeHandler.execute.selector;
        selectors[5] = VaultChangeHandler.warp.selector;
        selectors[6] = VaultChangeHandler.warp.selector;
        selectors[7] = VaultChangeHandler.setGuardian.selector;
        selectors[8] = VaultChangeHandler.renounceGuardian.selector;
        selectors[9] = VaultChangeHandler.unauthorizedCall.selector;
        selectors[10] = VaultChangeHandler.setRoutingMode.selector;
        selectors[11] = VaultChangeHandler.toggleFailure.selector;
        selectors[12] = VaultChangeHandler.toggleFailure.selector;
        selectors[13] = VaultChangeHandler.forward.selector;
        selectors[14] = VaultChangeHandler.setFees.selector;
        selectors[15] = VaultChangeHandler.togglePause.selector;
        selectors[16] = VaultChangeHandler.setTreasury.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev 1 and 2: no pending change <=> no timestamp.
    function invariant_PendingVaultAndTimestampAreConsistent() public view {
        bool noPending = address(forwarder.pendingVault()) == address(0);
        assertEq(noPending, forwarder.pendingVaultExecutableAt() == 0);
    }

    /// @dev The pending timestamp is always the proposal timestamp plus the immutable 72 hours.
    function invariant_ExecutableAtIsProposalTimePlusDelay() public view {
        if (address(forwarder.pendingVault()) != address(0)) {
            assertEq(forwarder.pendingVaultExecutableAt(), handler.ghostProposedAt() + 72 hours);
        }
    }

    function invariant_PendingVaultIsNeverTheActiveVault() public view {
        address pending = address(forwarder.pendingVault());
        if (pending != address(0)) assertTrue(pending != address(forwarder.vault()));
    }

    /// @dev 3, 4 and 5: propose and cancel never change the active vault; only a successful execution does.
    function invariant_ActiveVaultOnlyChangesThroughExecute() public view {
        assertEq(handler.ghostVaultChangedOutsideExecute(), 0);
        assertEq(address(forwarder.vault()), handler.ghostVault());
        assertEq(address(forwarder.pendingVault()), handler.ghostPending());
        assertEq(forwarder.pendingVaultExecutableAt(), handler.ghostExecutableAt());
    }

    /// @dev 6: no execution ever succeeded before `executableAt`.
    function invariant_NoExecutionBeforeTheDelay() public view {
        assertEq(handler.ghostEarlyExecutions(), 0);
    }

    /// @dev 7: the pending vault never holds an allowance.
    function invariant_PendingVaultHasNoAllowance() public view {
        address pending = address(forwarder.pendingVault());
        if (pending != address(0)) assertEq(usdc.allowance(address(forwarder), pending), 0);
        assertEq(handler.ghostPendingAllowance(), 0);
    }

    /// @dev 8, 9 and 10: every vault other than the active one has zero allowance (old vaults included); the active
    /// one has the modelled allowance (unlimited minus USDC decrements in vault modes, zero in DIRECT_DIRECT).
    function invariant_Allowances() public view {
        address active = address(forwarder.vault());
        bool direct = forwarder.routingMode() == DIRECT_DIRECT;
        for (uint256 i = 0; i < handler.vaultCount(); ++i) {
            address v = address(handler.vaults(i));
            uint256 allowance = usdc.allowance(address(forwarder), v);
            if (v != active || direct) assertEq(allowance, 0, "stale allowance");
            else assertGt(allowance, MAX - 1e30, "active vault allowance not unlimited");
            assertEq(allowance, handler.ghostAllowance(v), "allowance != model");
        }
    }

    /// @dev 11 and 12: guardians, fee managers and strangers never propose, execute, change routing or manage roles.
    function invariant_LifecycleAuthorization() public view {
        assertEq(handler.ghostUnauthorizedSuccesses(), 0);
    }

    /// @dev 13: guardian grants, revocations and renouncements (and every non-lifecycle action) leave the pending change
    /// and its timestamp untouched.
    function invariant_PendingChangeIsNeverTampered() public view {
        assertEq(handler.ghostDelayTampering(), 0);
    }

    /// @dev 14: the delay is a constant of the deployed code.
    function invariant_DelayIsImmutable() public view {
        assertEq(forwarder.VAULT_CHANGE_DELAY(), 72 hours);
        assertEq(address(forwarder).codehash, initialCodehash);
    }

    /// @dev 15: a failed execution keeps the pending change, the active vault and both allowances.
    function invariant_FailedExecutionKeepsState() public view {
        assertEq(handler.ghostFailedExecuteMutations(), 0);
    }

    /// @dev 16: proposals, cancellations and executions never modify fees, treasury, pause state or routing.
    function invariant_LifecycleKeepsFeesTreasuryAndPause() public view {
        assertEq(handler.ghostConfigTouched(), 0);
        assertEq(handler.configHash(), handler.ghostConfig());
        assertEq(uint8(forwarder.routingMode()), uint8(handler.ghostMode()));
    }

    /// @dev Every outcome matches the reference model (success exactly when the model predicts it).
    function invariant_OutcomesMatchModel() public view {
        assertEq(handler.ghostUnexpectedOutcomes(), 0);
        assertEq(handler.ghostForwarderFundsUsed(), 0);
    }

    function invariant_RolesMatchModel() public view {
        assertEq(forwarder.defaultAdmin(), admin);
        assertEq(forwarder.getRoleAdmin(VAULT_GUARDIAN_ROLE), DEFAULT_ADMIN_ROLE);
        for (uint256 i = 1; i < handler.actorCount(); ++i) {
            address actor = handler.actors(i);
            assertEq(forwarder.hasRole(VAULT_GUARDIAN_ROLE, actor), handler.ghostGuardian(actor), "guardian model");
            assertFalse(forwarder.hasRole(DEFAULT_ADMIN_ROLE, actor));
        }
        assertTrue(forwarder.hasRole(FEE_MANAGER_ROLE, feeManager));
        assertTrue(forwarder.hasRole(FEE_MANAGER_ROLE, feeManagerGuardian));
    }

    function invariant_VaultModeHasVault() public view {
        if (forwarder.routingMode() != DIRECT_DIRECT) assertTrue(address(forwarder.vault()) != address(0));
    }
}
