// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Forwarder} from "../src/Forwarder.sol";
import {MockVault} from "./mocks/MockVault.sol";
import {ForwarderHandler} from "./invariants/ForwarderHandler.sol";
import {ForwarderTestBase} from "./utils/ForwarderTestBase.sol";

/// @dev Stateful invariants over random sequences of every action (see ForwarderHandler).
contract ForwarderInvariantTest is ForwarderTestBase {
    ForwarderHandler internal handler;
    bytes32 internal initialCodehash;
    address[] internal treasuries;

    function setUp() public override {
        super.setUp();
        MockVault[] memory vaults = new MockVault[](3);
        vaults[0] = vault;
        vaults[1] = new MockVault(IERC20(address(usdc)));
        vaults[2] = new MockVault(IERC20(address(usdc)));
        vaults[2].setRedeemReverts(true); // always fails the health check

        treasuries.push(treasury);
        treasuries.push(makeAddr("treasury2"));
        treasuries.push(makeAddr("treasury3"));

        handler = new ForwarderHandler(forwarder, usdc, admin, vaults, _feeManagers(), treasuries);
        initialCodehash = address(forwarder).codehash;

        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = ForwarderHandler.forward.selector;
        selectors[1] = ForwarderHandler.forward.selector; // forward twice as likely
        selectors[2] = ForwarderHandler.donate.selector;
        selectors[3] = ForwarderHandler.setFeeConfig.selector;
        selectors[4] = ForwarderHandler.setSingleFeeParameter.selector;
        selectors[5] = ForwarderHandler.pause.selector;
        selectors[6] = ForwarderHandler.unpause.selector;
        selectors[7] = ForwarderHandler.setRoutingMode.selector;
        selectors[8] = ForwarderHandler.setVault.selector;
        selectors[9] = ForwarderHandler.setTreasury.selector;
        selectors[10] = ForwarderHandler.toggleFailure.selector;
        selectors[11] = ForwarderHandler.rescueUsdc.selector;
        selectors[12] = ForwarderHandler.rescueNative.selector;
        selectors[13] = ForwarderHandler.unauthorizedCall.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_NoUnexpectedOutcome() public view {
        assertEq(handler.ghostUnexpectedReverts(), 0, "unexpected revert");
        assertEq(handler.ghostUnexpectedSuccesses(), 0, "unexpected success");
        assertEq(handler.ghostRescueMisroutes(), 0, "rescue misroute");
    }

    /// @dev The user always receives exactly amount - fee; a treasury failure never affects it.
    function invariant_UserGetsExactlyAmountMinusFee() public view {
        assertEq(handler.ghostUserMismatches(), 0);
    }

    /// @dev Fee + previous balance are either delivered to the treasury or kept in the Forwarder.
    function invariant_TreasuryAccounting() public view {
        assertEq(handler.ghostTreasuryMismatches(), 0);
    }

    /// @dev No USDC is created or lost: everything that came in is with users, treasuries or the Forwarder.
    function invariant_Conservation() public view {
        assertEq(
            handler.ghostDeposited() + handler.ghostDonated(),
            handler.ghostUserReceived() + handler.ghostTreasuryReceived() + usdc.balanceOf(address(forwarder))
        );
        assertEq(handler.ghostDeposited(), handler.ghostUserReceived() + handler.ghostFees());
    }

    function invariant_FeeConfigWithinCaps() public view {
        assertLe(forwarder.variableFee(), forwarder.MAX_VARIABLE_FEE());
        assertLe(forwarder.fixedFee(), forwarder.MAX_FIXED_FEE());
    }

    function invariant_PausedImpliesZeroFee() public view {
        assertEq(handler.ghostPausedFeeCharged(), 0);
        if (forwarder.paused()) {
            assertEq(forwarder.calculateFee(0), 0);
            assertEq(forwarder.calculateFee(forwarder.threshold()), 0);
            assertEq(forwarder.calculateFee(1e13), 0);
        }
    }

    function invariant_VaultModeHasVault() public view {
        if (forwarder.routingMode() != DIRECT_DIRECT) assertTrue(address(forwarder.vault()) != address(0));
    }

    /// @dev Exact allowance per vault; zero for DIRECT_DIRECT and for every vault that is not the current one.
    function invariant_Allowances() public view {
        address current = address(forwarder.vault());
        for (uint256 i = 0; i < handler.vaultCount(); ++i) {
            address v = address(handler.vaults(i));
            uint256 allowance = usdc.allowance(address(forwarder), v);
            assertEq(allowance, handler.ghostAllowance(v), "allowance != model");
            if (v != current || forwarder.routingMode() == DIRECT_DIRECT) assertEq(allowance, 0, "stale allowance");
            else assertGt(allowance, MAX - 1e30, "vault allowance not unlimited");
        }
    }

    function invariant_ForwarderNeverHoldsShares() public view {
        for (uint256 i = 0; i < handler.vaultCount(); ++i) {
            assertEq(handler.vaults(i).balanceOf(address(forwarder)), 0);
        }
    }

    function invariant_PrivilegesNeverChange() public view {
        assertEq(forwarder.defaultAdmin(), admin);
        (address pendingAdmin,) = forwarder.pendingDefaultAdmin();
        assertEq(pendingAdmin, address(0));
        assertTrue(forwarder.hasRole(FEE_MANAGER_ROLE, feeManager));
        assertTrue(forwarder.hasRole(FEE_MANAGER_ROLE, feeManager2));
        assertFalse(forwarder.hasRole(DEFAULT_ADMIN_ROLE, feeManager));
        assertFalse(forwarder.hasRole(DEFAULT_ADMIN_ROLE, feeManager2));
        for (uint256 i = 0; i < handler.strangerCount(); ++i) {
            address s = handler.strangers(i);
            assertFalse(forwarder.hasRole(DEFAULT_ADMIN_ROLE, s));
            assertFalse(forwarder.hasRole(FEE_MANAGER_ROLE, s));
        }
        assertFalse(forwarder.hasRole(FEE_MANAGER_ROLE, handler.sra()));
    }

    function invariant_TreasuryIsAlwaysValid() public view {
        address current = forwarder.treasury();
        assertTrue(current != address(0) && current != address(forwarder));
    }

    function invariant_CodeNeverChanges() public view {
        assertEq(address(forwarder).codehash, initialCodehash);
    }

    function afterInvariant() external view {
        // Make sure the campaign exercised the main paths.
        assertGt(handler.calls("forward"), 0);
    }
}
