// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {Forwarder} from "../src/Forwarder.sol";
import {MockERC20} from "./mocks/MockTokens.sol";
import {MockVault} from "./mocks/MockVault.sol";
import {ReentrantToken, ReentrantVault} from "./mocks/ReentrancyMocks.sol";
import {AssetSwitchVault} from "./mocks/VaultChangeMocks.sol";
import {ForwarderTestBase} from "./utils/ForwarderTestBase.sol";

/// @dev Fixture of the vault change lifecycle: the active `vault` plus a healthy `candidate`.
abstract contract VaultChangeFixture is ForwarderTestBase {
    MockVault internal candidate;

    function setUp() public virtual override {
        super.setUp();
        candidate = new MockVault(IERC20(address(usdc)));
        vm.label(address(candidate), "Candidate");
    }

    function _expectUnauthorized(address account, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role));
    }

    function _expectTooEarly(uint256 executableAt) internal {
        vm.expectRevert(abi.encodeWithSelector(Forwarder.VaultChangeDelayNotElapsed.selector, executableAt));
    }

    function _assertNoPending() internal view {
        assertEq(address(forwarder.pendingVault()), address(0), "pending vault");
        assertEq(forwarder.pendingVaultExecutableAt(), 0, "pending timestamp");
    }

    function _assertPending(address expected, uint256 executableAt) internal view {
        assertEq(address(forwarder.pendingVault()), expected, "pending vault");
        assertEq(forwarder.pendingVaultExecutableAt(), executableAt, "pending timestamp");
    }

    function _allowance(address spender) internal view returns (uint256) {
        return usdc.allowance(address(forwarder), spender);
    }

    /// @dev Snapshot of every configuration value that the vault lifecycle must not touch.
    function _configHash() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                forwarder.treasury(),
                forwarder.routingMode(),
                forwarder.lowerFeeModel(),
                forwarder.upperFeeModel(),
                forwarder.threshold(),
                forwarder.fixedFee(),
                forwarder.variableFee(),
                forwarder.paused()
            )
        );
    }

    function _nonDefaultConfiguration() internal {
        _setFees(FIXED, FIXED_PLUS_PERCENT, 100e6, 1e6, 500);
        vm.prank(feeManager);
        forwarder.pause();
        vm.prank(admin);
        forwarder.setTreasury(makeAddr("otherTreasury"));
    }

    function _countEvents(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(forwarder) && logs[i].topics[0] == topic) ++count;
        }
    }
}

/// @dev proposeVault (spec V2 section 8).
contract ForwarderProposeVaultTest is VaultChangeFixture {
    function test_AdminProposes() public {
        uint256 expectedAt = block.timestamp + 72 hours;
        _fundAdminForHealthCheck();
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.VaultChangeProposed(address(vault), address(candidate), expectedAt, admin);
        vm.prank(admin);
        forwarder.proposeVault(IERC4626(address(candidate)));

        _assertPending(address(candidate), expectedAt);
        assertEq(address(forwarder.vault()), address(vault), "active vault changed");
        assertEq(uint8(forwarder.routingMode()), uint8(DIRECT_DIRECT), "routing changed");
        assertEq(_allowance(address(vault)), 0, "active allowance changed");
        assertEq(_allowance(address(candidate)), 0, "candidate allowance");
        assertEq(usdc.balanceOf(admin), TEST_AMOUNT, "health check refund");
    }

    function test_ExecutableAtIsExactlyProposalTimePlus72Hours() public {
        vm.warp(1_800_000_000);
        _proposeVault(address(candidate));
        assertEq(forwarder.pendingVaultExecutableAt(), 1_800_000_000 + 259_200);
    }

    function test_ProposeInVaultModeKeepsActiveVaultAllowanceAndRouting() public {
        _setRouting(VAULT_VAULT);
        _forward(10e6, user); // USDC decrements even the unlimited allowance
        uint256 activeAllowance = _allowance(address(vault));
        assertEq(activeAllowance, MAX - 10e6);

        _proposeVault(address(candidate));
        assertEq(_allowance(address(vault)), activeAllowance, "active allowance changed");
        assertEq(_allowance(address(candidate)), 0, "candidate allowance");
        assertEq(uint8(forwarder.routingMode()), uint8(VAULT_VAULT));
        assertEq(address(forwarder.vault()), address(vault));
    }

    function test_RevertWhen_FeeManagerProposes() public {
        usdc.mint(feeManager, TEST_AMOUNT);
        vm.prank(feeManager);
        usdc.approve(address(forwarder), TEST_AMOUNT);
        _expectUnauthorized(feeManager, DEFAULT_ADMIN_ROLE);
        vm.prank(feeManager);
        forwarder.proposeVault(IERC4626(address(candidate)));
        _assertNoPending();
    }

    function test_RevertWhen_GuardianProposes() public {
        usdc.mint(guardian, TEST_AMOUNT);
        vm.prank(guardian);
        usdc.approve(address(forwarder), TEST_AMOUNT);
        _expectUnauthorized(guardian, DEFAULT_ADMIN_ROLE);
        vm.prank(guardian);
        forwarder.proposeVault(IERC4626(address(candidate)));
        _assertNoPending();
    }

    function test_RevertWhen_StrangerProposes() public {
        _expectUnauthorized(stranger, DEFAULT_ADMIN_ROLE);
        vm.prank(stranger);
        forwarder.proposeVault(IERC4626(address(candidate)));
        _assertNoPending();
    }

    function test_RevertWhen_ProposingWhileAChangeIsPending() public {
        _proposeVault(address(candidate));
        uint256 executableAt = forwarder.pendingVaultExecutableAt();
        MockVault other = new MockVault(IERC20(address(usdc)));

        vm.warp(block.timestamp + 10 days); // even after the first proposal is executable
        _fundAdminForHealthCheck();
        vm.expectRevert(abi.encodeWithSelector(Forwarder.VaultChangeAlreadyPending.selector, address(candidate)));
        vm.prank(admin);
        forwarder.proposeVault(IERC4626(address(other)));
        vm.expectRevert(abi.encodeWithSelector(Forwarder.VaultChangeAlreadyPending.selector, address(candidate)));
        vm.prank(admin);
        forwarder.proposeVault(IERC4626(address(candidate)));
        _assertPending(address(candidate), executableAt);
    }

    function test_ProposeAgainAfterCancellationRestartsTheDelay() public {
        _proposeVault(address(candidate));
        vm.warp(block.timestamp + 71 hours);
        vm.prank(guardian);
        forwarder.cancelVaultChange();
        _proposeVault(address(candidate));
        _assertPending(address(candidate), block.timestamp + 72 hours);
    }

    function test_ProposeAgainAfterExecution() public {
        _replaceVault(address(candidate));
        _proposeVault(address(vault)); // the previous vault is a valid candidate again
        _assertPending(address(vault), block.timestamp + 72 hours);
        assertEq(address(forwarder.vault()), address(candidate));
        assertEq(_allowance(address(vault)), 0);
    }

    function test_ProposeDoesNotTouchFeesTreasuryOrPause() public {
        _nonDefaultConfiguration();
        bytes32 before = _configHash();
        _proposeVault(address(candidate));
        assertEq(_configHash(), before);
    }
}

/// @dev cancelVaultChange (spec V2 section 10).
contract ForwarderCancelVaultChangeTest is VaultChangeFixture {
    function setUp() public override {
        super.setUp();
        _proposeVault(address(candidate));
    }

    function _cancelAs(address account) internal {
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.VaultChangeCancelled(address(candidate), account);
        vm.prank(account);
        forwarder.cancelVaultChange();
        _assertNoPending();
    }

    function test_AdminCancels() public {
        _cancelAs(admin);
    }

    function test_GuardianCancels() public {
        _cancelAs(guardian);
    }

    function test_EveryGuardianCanCancel() public {
        _cancelAs(guardian2);
        _proposeVault(address(candidate));
        _cancelAs(guardian);
        address extra = makeAddr("extraGuardian");
        vm.prank(admin);
        forwarder.grantRole(VAULT_GUARDIAN_ROLE, extra);
        _proposeVault(address(candidate));
        _cancelAs(extra);
    }

    function test_RevertWhen_FeeManagerWithoutGuardianRoleCancels() public {
        _expectUnauthorized(feeManager, VAULT_GUARDIAN_ROLE);
        vm.prank(feeManager);
        forwarder.cancelVaultChange();
        assertEq(address(forwarder.pendingVault()), address(candidate));
    }

    function test_RevertWhen_StrangerCancels() public {
        _expectUnauthorized(stranger, VAULT_GUARDIAN_ROLE);
        vm.prank(stranger);
        forwarder.cancelVaultChange();
        assertEq(address(forwarder.pendingVault()), address(candidate));
    }

    function test_CancelBeforeTheDelay() public {
        vm.warp(block.timestamp + 1 hours);
        _cancelAs(guardian);
    }

    function test_CancelExactlyAtExecutableAt() public {
        vm.warp(forwarder.pendingVaultExecutableAt());
        _cancelAs(guardian);
    }

    function test_CancelAfterTheDelay() public {
        vm.warp(forwarder.pendingVaultExecutableAt() + 30 days);
        _cancelAs(guardian2);
    }

    function test_RevertWhen_NothingIsPending() public {
        vm.prank(guardian);
        forwarder.cancelVaultChange();
        vm.expectRevert(Forwarder.NoPendingVaultChange.selector);
        vm.prank(guardian);
        forwarder.cancelVaultChange();
        vm.expectRevert(Forwarder.NoPendingVaultChange.selector);
        vm.prank(admin);
        forwarder.cancelVaultChange();
    }

    function test_CancelKeepsActiveVaultAllowanceAndRouting() public {
        _setRouting(VAULT_USER_DIRECT_TREASURY);
        _forward(5e6, user);
        uint256 activeAllowance = _allowance(address(vault));
        _cancelAs(guardian);
        assertEq(address(forwarder.vault()), address(vault));
        assertEq(_allowance(address(vault)), activeAllowance);
        assertEq(_allowance(address(candidate)), 0);
        assertEq(uint8(forwarder.routingMode()), uint8(VAULT_USER_DIRECT_TREASURY));
    }

    function test_CancelDoesNotTouchFeesTreasuryOrPause() public {
        _nonDefaultConfiguration();
        bytes32 before = _configHash();
        _cancelAs(guardian);
        assertEq(_configHash(), before);
    }

    function test_CancelledChangeCannotBeExecuted() public {
        _cancelAs(guardian);
        vm.warp(block.timestamp + 72 hours);
        _fundAdminForHealthCheck();
        vm.expectRevert(Forwarder.NoPendingVaultChange.selector);
        vm.prank(admin);
        forwarder.executeVaultChange();
        assertEq(address(forwarder.vault()), address(vault));
    }

    /// @dev Roles are independent: a fee manager that is also a guardian keeps both powers and nothing more.
    function test_FeeManagerWithGuardianRoleCancelsAndKeepsFeePowers() public {
        vm.prank(admin);
        forwarder.grantRole(VAULT_GUARDIAN_ROLE, feeManager);
        _cancelAs(feeManager);
        _setFees(FIXED, FIXED, 0, 1e6, 0);
        assertEq(forwarder.fixedFee(), 1e6);
        _expectUnauthorized(feeManager, DEFAULT_ADMIN_ROLE);
        vm.prank(feeManager);
        forwarder.proposeVault(IERC4626(address(candidate)));
    }
}

/// @dev VAULT_GUARDIAN_ROLE management and its (absent) effect on the delay (spec V2 section 6).
contract ForwarderGuardianLifecycleTest is VaultChangeFixture {
    function test_OnlyAdminGrantsAndRevokesGuardians() public {
        address newGuardian = makeAddr("newGuardian");
        address[3] memory nonAdmins = [feeManager, guardian, stranger];
        for (uint256 i = 0; i < nonAdmins.length; ++i) {
            _expectUnauthorized(nonAdmins[i], DEFAULT_ADMIN_ROLE);
            vm.prank(nonAdmins[i]);
            forwarder.grantRole(VAULT_GUARDIAN_ROLE, newGuardian);
            _expectUnauthorized(nonAdmins[i], DEFAULT_ADMIN_ROLE);
            vm.prank(nonAdmins[i]);
            forwarder.revokeRole(VAULT_GUARDIAN_ROLE, guardian2);
        }
        assertFalse(forwarder.hasRole(VAULT_GUARDIAN_ROLE, newGuardian));
        assertTrue(forwarder.hasRole(VAULT_GUARDIAN_ROLE, guardian2));

        vm.startPrank(admin);
        forwarder.grantRole(VAULT_GUARDIAN_ROLE, newGuardian);
        forwarder.revokeRole(VAULT_GUARDIAN_ROLE, guardian2);
        vm.stopPrank();
        assertTrue(forwarder.hasRole(VAULT_GUARDIAN_ROLE, newGuardian));
        assertFalse(forwarder.hasRole(VAULT_GUARDIAN_ROLE, guardian2));
    }

    function test_RevokedGuardianCannotCancel() public {
        _proposeVault(address(candidate));
        vm.prank(admin);
        forwarder.revokeRole(VAULT_GUARDIAN_ROLE, guardian);
        _expectUnauthorized(guardian, VAULT_GUARDIAN_ROLE);
        vm.prank(guardian);
        forwarder.cancelVaultChange();
        assertEq(address(forwarder.pendingVault()), address(candidate));
    }

    function test_RevokingAGuardianDoesNotChangeExecutableAt() public {
        _proposeVault(address(candidate));
        uint256 executableAt = forwarder.pendingVaultExecutableAt();
        vm.warp(block.timestamp + 1 days);
        vm.prank(admin);
        forwarder.revokeRole(VAULT_GUARDIAN_ROLE, guardian);
        _assertPending(address(candidate), executableAt);
    }

    /// @dev A compromised admin can remove every guardian, but still has to wait the full delay.
    function test_RevokingAllGuardiansDoesNotShortenTheDelay() public {
        _proposeVault(address(candidate));
        uint256 executableAt = forwarder.pendingVaultExecutableAt();
        vm.startPrank(admin);
        forwarder.revokeRole(VAULT_GUARDIAN_ROLE, guardian);
        forwarder.revokeRole(VAULT_GUARDIAN_ROLE, guardian2);
        vm.stopPrank();
        assertFalse(forwarder.hasRole(VAULT_GUARDIAN_ROLE, guardian));
        assertFalse(forwarder.hasRole(VAULT_GUARDIAN_ROLE, guardian2));
        _assertPending(address(candidate), executableAt);

        _fundAdminForHealthCheck();
        _expectTooEarly(executableAt);
        vm.prank(admin);
        forwarder.executeVaultChange();
        vm.warp(executableAt - 1);
        _expectTooEarly(executableAt);
        vm.prank(admin);
        forwarder.executeVaultChange();
        assertEq(address(forwarder.vault()), address(vault));

        vm.warp(executableAt);
        vm.prank(admin);
        forwarder.executeVaultChange();
        assertEq(address(forwarder.vault()), address(candidate));
    }

    function test_GrantingAndRenouncingGuardiansDoesNotChangeExecutableAt() public {
        _proposeVault(address(candidate));
        uint256 executableAt = forwarder.pendingVaultExecutableAt();
        address newGuardian = makeAddr("newGuardian");
        vm.prank(admin);
        forwarder.grantRole(VAULT_GUARDIAN_ROLE, newGuardian);
        vm.prank(guardian2);
        forwarder.renounceRole(VAULT_GUARDIAN_ROLE, guardian2);
        assertFalse(forwarder.hasRole(VAULT_GUARDIAN_ROLE, guardian2));
        _assertPending(address(candidate), executableAt);
    }

    /// @dev Rotating the default admin (3-day AccessControlDefaultAdminRules delay) does not affect a pending change.
    function test_AdminRotationDoesNotChangeExecutableAt() public {
        _proposeVault(address(candidate));
        uint256 executableAt = forwarder.pendingVaultExecutableAt();
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        forwarder.beginDefaultAdminTransfer(newAdmin);
        vm.warp(block.timestamp + ADMIN_DELAY + 1);
        vm.prank(newAdmin);
        forwarder.acceptDefaultAdminTransfer();
        _assertPending(address(candidate), executableAt);
        assertLt(executableAt, block.timestamp + 1, "the change matured during the rotation");
        usdc.mint(newAdmin, TEST_AMOUNT);
        vm.prank(newAdmin);
        usdc.approve(address(forwarder), TEST_AMOUNT);
        vm.prank(newAdmin);
        forwarder.executeVaultChange();
        assertEq(address(forwarder.vault()), address(candidate));
    }

    /// @dev A guardian can only cancel: every other privileged function is rejected.
    function test_GuardianHasNoOtherPower() public {
        _proposeVault(address(candidate));
        vm.warp(forwarder.pendingVaultExecutableAt());
        usdc.mint(guardian, TEST_AMOUNT);
        vm.prank(guardian);
        usdc.approve(address(forwarder), TEST_AMOUNT);
        bytes[13] memory calls = [
            abi.encodeCall(Forwarder.proposeVault, (IERC4626(address(new MockVault(IERC20(address(usdc))))))),
            abi.encodeCall(Forwarder.executeVaultChange, ()),
            abi.encodeCall(Forwarder.setRoutingMode, (VAULT_VAULT)),
            abi.encodeCall(Forwarder.setTreasury, (guardian)),
            abi.encodeCall(Forwarder.rescueToken, (IERC20(address(usdc)))),
            abi.encodeCall(Forwarder.rescueNative, ()),
            abi.encodeCall(Forwarder.unpause, ()),
            abi.encodeCall(Forwarder.pause, ()),
            abi.encodeCall(Forwarder.setFeeConfig, (FIXED, FIXED, 0, 1, 1)),
            abi.encodeCall(Forwarder.setVariableFee, (1)),
            abi.encodeCall(IAccessControl.grantRole, (VAULT_GUARDIAN_ROLE, stranger)),
            abi.encodeCall(IAccessControl.revokeRole, (VAULT_GUARDIAN_ROLE, guardian2)),
            abi.encodeCall(IAccessControl.grantRole, (FEE_MANAGER_ROLE, guardian))
        ];
        for (uint256 i = 0; i < calls.length; ++i) {
            vm.prank(guardian);
            (bool success,) = address(forwarder).call(calls[i]);
            assertFalse(success);
        }
        assertEq(address(forwarder.vault()), address(vault));
        assertEq(address(forwarder.pendingVault()), address(candidate));
        assertEq(forwarder.treasury(), treasury);
        assertEq(uint8(forwarder.routingMode()), uint8(DIRECT_DIRECT));
        assertFalse(forwarder.paused());
        assertFalse(forwarder.hasRole(VAULT_GUARDIAN_ROLE, stranger));
        assertTrue(forwarder.hasRole(VAULT_GUARDIAN_ROLE, guardian2));
    }
}

/// @dev executeVaultChange (spec V2 section 11).
contract ForwarderExecuteVaultChangeTest is VaultChangeFixture {
    uint256 internal executableAt;

    function setUp() public override {
        super.setUp();
        _proposeVault(address(candidate));
        executableAt = forwarder.pendingVaultExecutableAt();
        _fundAdminForHealthCheck();
    }

    function _execute() internal {
        vm.prank(admin);
        forwarder.executeVaultChange();
    }

    function test_RevertWhen_ExecutingImmediately() public {
        _expectTooEarly(executableAt);
        _execute();
        _assertPending(address(candidate), executableAt);
        assertEq(address(forwarder.vault()), address(vault));
    }

    function test_RevertWhen_ExecutingOneSecondEarly() public {
        vm.warp(executableAt - 1);
        _expectTooEarly(executableAt);
        _execute();
        _assertPending(address(candidate), executableAt);
    }

    function test_ExecuteExactlyAtExecutableAt() public {
        vm.warp(executableAt);
        _execute();
        assertEq(address(forwarder.vault()), address(candidate));
        _assertNoPending();
    }

    function test_ExecuteLongAfterExecutableAt() public {
        vm.warp(executableAt + 365 days);
        _execute();
        assertEq(address(forwarder.vault()), address(candidate));
        _assertNoPending();
    }

    function test_RevertWhen_GuardianExecutes() public {
        vm.warp(executableAt);
        _expectUnauthorized(guardian, DEFAULT_ADMIN_ROLE);
        vm.prank(guardian);
        forwarder.executeVaultChange();
        _assertPending(address(candidate), executableAt);
    }

    function test_RevertWhen_FeeManagerExecutes() public {
        vm.warp(executableAt);
        _expectUnauthorized(feeManager, DEFAULT_ADMIN_ROLE);
        vm.prank(feeManager);
        forwarder.executeVaultChange();
        _assertPending(address(candidate), executableAt);
    }

    function test_RevertWhen_StrangerExecutes() public {
        vm.warp(executableAt);
        _expectUnauthorized(stranger, DEFAULT_ADMIN_ROLE);
        vm.prank(stranger);
        forwarder.executeVaultChange();
        _assertPending(address(candidate), executableAt);
    }

    function test_RevertWhen_NothingIsPending() public {
        vm.prank(admin);
        forwarder.cancelVaultChange();
        vm.warp(executableAt);
        vm.expectRevert(Forwarder.NoPendingVaultChange.selector);
        _execute();
    }

    function test_RevertWhen_ExecutionIsNotFunded() public {
        vm.prank(admin);
        usdc.approve(address(forwarder), 0);
        vm.warp(executableAt);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(forwarder), 0, TEST_AMOUNT)
        );
        _execute();
        _assertPending(address(candidate), executableAt);
        assertEq(address(forwarder.vault()), address(vault));
    }

    function test_SuccessfulExecutionInDirectDirect() public {
        vm.warp(executableAt);
        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.VaultUpdated(address(vault), address(candidate), TEST_AMOUNT * 1e12, TEST_AMOUNT);
        _execute();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(address(forwarder.vault()), address(candidate));
        _assertNoPending();
        assertEq(_allowance(address(vault)), 0, "old vault allowance");
        assertEq(_allowance(address(candidate)), 0, "new vault allowance in DIRECT_DIRECT");
        assertEq(usdc.balanceOf(admin), 2 * TEST_AMOUNT, "both health checks refunded");
        assertEq(usdc.balanceOf(address(forwarder)), 0);
        assertEq(_countEvents(logs, Forwarder.VaultUpdated.selector), 1);
        assertEq(_countEvents(logs, Forwarder.VaultChangeProposed.selector), 0);
        assertEq(_countEvents(logs, Forwarder.VaultChangeCancelled.selector), 0);
    }

    function test_SuccessfulExecutionInEachVaultMode() public {
        Forwarder.RoutingMode[3] memory modes = [VAULT_USER_DIRECT_TREASURY, DIRECT_USER_VAULT_TREASURY, VAULT_VAULT];
        for (uint256 i = 0; i < modes.length; ++i) {
            if (address(forwarder.pendingVault()) == address(0)) {
                MockVault next = new MockVault(IERC20(address(usdc)));
                _proposeVault(address(next));
                _fundAdminForHealthCheck();
            }
            address previous = address(forwarder.vault());
            address next_ = address(forwarder.pendingVault());
            _setRouting(modes[i]);
            vm.warp(forwarder.pendingVaultExecutableAt());
            _execute();
            assertEq(address(forwarder.vault()), next_);
            assertEq(_allowance(previous), 0, "old vault allowance");
            assertEq(_allowance(next_), MAX, "new vault allowance");
            _assertNoPending();
        }
    }

    function test_ExecutionDoesNotTouchFeesTreasuryOrPause() public {
        _nonDefaultConfiguration();
        bytes32 before = _configHash();
        vm.warp(executableAt);
        _execute();
        assertEq(_configHash(), before);
    }

    function test_ForwardUsesTheNewVaultAfterExecution() public {
        _setRouting(VAULT_VAULT);
        vm.warp(executableAt);
        _execute();
        _forward(100e6, user);
        assertEq(candidate.convertToAssets(candidate.balanceOf(user)), 100e6);
        assertEq(vault.balanceOf(user), 0);
    }
}

/// @dev The execution repeats the real health check (spec V2 section 11): a candidate that stops working after its
/// proposal cannot be activated, and nothing changes until it works again.
contract ForwarderSecondHealthCheckTest is VaultChangeFixture {
    function setUp() public override {
        super.setUp();
        _setRouting(VAULT_VAULT); // the active vault holds the unlimited allowance during the whole test
    }

    function _assertFailedExecutionKeepsState(bytes memory revertData) internal {
        uint256 executableAt = forwarder.pendingVaultExecutableAt();
        address pending = address(forwarder.pendingVault());
        vm.warp(executableAt);
        _fundAdminForHealthCheck();
        if (revertData.length == 0) vm.expectRevert();
        else vm.expectRevert(revertData);
        vm.prank(admin);
        forwarder.executeVaultChange();

        assertEq(address(forwarder.vault()), address(vault), "active vault changed");
        assertEq(_allowance(address(vault)), MAX, "active allowance changed");
        assertEq(_allowance(pending), 0, "candidate allowance");
        _assertPending(pending, executableAt);
        assertEq(usdc.balanceOf(admin), 2 * TEST_AMOUNT, "admin funds back");
        assertEq(usdc.balanceOf(address(forwarder)), 0);
    }

    function _recoverAndExecute(address pending) internal {
        vm.prank(admin);
        forwarder.executeVaultChange(); // still funded: the failed attempt reverted entirely
        assertEq(address(forwarder.vault()), pending);
        assertEq(_allowance(address(vault)), 0);
        assertEq(_allowance(pending), MAX);
        _assertNoPending();
    }

    function test_RedeemStartsFailingAfterProposal() public {
        _proposeVault(address(candidate));
        candidate.setRedeemReverts(true);
        _assertFailedExecutionKeepsState(abi.encodeWithSelector(MockVault.RedeemDisabled.selector));
        candidate.setRedeemReverts(false);
        _recoverAndExecute(address(candidate));
    }

    function test_DepositStartsFailingAfterProposal() public {
        _proposeVault(address(candidate));
        candidate.setDepositReverts(true);
        _assertFailedExecutionKeepsState(abi.encodeWithSelector(MockVault.DepositDisabled.selector));
        candidate.setDepositReverts(false);
        _recoverAndExecute(address(candidate));
    }

    function test_CandidatePausedAfterProposal() public {
        _proposeVault(address(candidate));
        candidate.setPaused(true);
        _assertFailedExecutionKeepsState(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, address(forwarder), TEST_AMOUNT, 0)
        );
        candidate.setPaused(false);
        _recoverAndExecute(address(candidate));
    }

    function test_CandidateStopsMintingSharesAfterProposal() public {
        _proposeVault(address(candidate));
        candidate.setMintsNoShares(true);
        _assertFailedExecutionKeepsState(
            abi.encodeWithSelector(Forwarder.VaultNoSharesMinted.selector, address(candidate))
        );
        candidate.setMintsNoShares(false);
        _recoverAndExecute(address(candidate));
    }

    function test_CandidateStopsReturningAssetsAfterProposal() public {
        _proposeVault(address(candidate));
        candidate.setRedeemPaysNothing(true);
        _assertFailedExecutionKeepsState(
            abi.encodeWithSelector(Forwarder.VaultNoAssetsReturned.selector, address(candidate))
        );
        candidate.setRedeemPaysNothing(false);
        _recoverAndExecute(address(candidate));
    }

    function test_CandidateAssetChangesAfterProposal() public {
        AssetSwitchVault switching = new AssetSwitchVault(IERC20(address(usdc)));
        _proposeVault(address(switching));
        MockERC20 other = new MockERC20("Other", "OTH", 6);
        switching.setReportedAsset(address(other));
        _assertFailedExecutionKeepsState(
            abi.encodeWithSelector(Forwarder.VaultAssetMismatch.selector, address(switching), address(other))
        );
        switching.setReportedAsset(address(0));
        _recoverAndExecute(address(switching));
    }

    function test_CandidateCodeRemovedAfterProposal() public {
        _proposeVault(address(candidate));
        bytes memory code = address(candidate).code;
        vm.etch(address(candidate), "");
        _assertFailedExecutionKeepsState(
            abi.encodeWithSelector(Forwarder.VaultNotContract.selector, address(candidate))
        );
        vm.etch(address(candidate), code);
        _recoverAndExecute(address(candidate));
    }

    /// @dev After a failed execution the change can also be cancelled instead of retried.
    function test_FailedExecutionCanBeCancelled() public {
        _proposeVault(address(candidate));
        candidate.setRedeemReverts(true);
        _assertFailedExecutionKeepsState(abi.encodeWithSelector(MockVault.RedeemDisabled.selector));
        vm.prank(guardian);
        forwarder.cancelVaultChange();
        _assertNoPending();
        assertEq(address(forwarder.vault()), address(vault));
        assertEq(_allowance(address(vault)), MAX);
    }
}

/// @dev Routing changes while a change is pending only concern the active vault; the execution applies the routing
/// mode in force at execution time (spec V2 section 12).
contract ForwarderRoutingWhilePendingTest is VaultChangeFixture {
    /// @dev Case A: proposal in VAULT_VAULT, DIRECT_DIRECT selected while pending.
    function test_CaseA_DirectDirectSelectedWhilePending() public {
        _setRouting(VAULT_VAULT);
        _proposeVault(address(candidate));
        assertEq(_allowance(address(vault)), MAX);
        _setRouting(DIRECT_DIRECT);
        assertEq(_allowance(address(vault)), 0);
        assertEq(_allowance(address(candidate)), 0);
        vm.warp(forwarder.pendingVaultExecutableAt());
        _executeVaultChange();
        assertEq(_allowance(address(vault)), 0, "old vault allowance");
        assertEq(_allowance(address(candidate)), 0, "new vault allowance");
        assertEq(uint8(forwarder.routingMode()), uint8(DIRECT_DIRECT));
    }

    /// @dev Case B: proposal in DIRECT_DIRECT, VAULT_VAULT selected (with the active vault) while pending.
    function test_CaseB_VaultVaultSelectedWhilePending() public {
        _proposeVault(address(candidate));
        _setRouting(VAULT_VAULT);
        assertEq(_allowance(address(vault)), MAX);
        assertEq(_allowance(address(candidate)), 0);
        vm.warp(forwarder.pendingVaultExecutableAt());
        _executeVaultChange();
        assertEq(_allowance(address(vault)), 0, "old vault allowance");
        assertEq(_allowance(address(candidate)), MAX, "new vault allowance");
        assertEq(uint8(forwarder.routingMode()), uint8(VAULT_VAULT));
    }

    /// @dev Every pair (routing at proposal, routing at execution): the execution routing decides.
    function test_RoutingAtExecutionDecidesForEveryPair() public {
        Forwarder.RoutingMode[4] memory modes =
            [DIRECT_DIRECT, VAULT_USER_DIRECT_TREASURY, DIRECT_USER_VAULT_TREASURY, VAULT_VAULT];
        for (uint256 p = 0; p < 4; ++p) {
            for (uint256 x = 0; x < 4; ++x) {
                MockVault next = new MockVault(IERC20(address(usdc)));
                address previous = address(forwarder.vault());
                _setRouting(modes[p]);
                _proposeVault(address(next));
                _setRouting(modes[x]);
                assertEq(_allowance(address(next)), 0, "pending vault allowance");
                vm.warp(forwarder.pendingVaultExecutableAt());
                _executeVaultChange();
                assertEq(_allowance(previous), 0, "old vault allowance");
                assertEq(_allowance(address(next)), _usesVault(modes[x]) ? MAX : 0, "new vault allowance");
            }
        }
    }

    function test_RoutingChangesNeverGiveAllowanceToThePendingVault() public {
        _proposeVault(address(candidate));
        Forwarder.RoutingMode[6] memory sequence = [
            VAULT_VAULT,
            DIRECT_DIRECT,
            VAULT_USER_DIRECT_TREASURY,
            DIRECT_USER_VAULT_TREASURY,
            VAULT_VAULT,
            DIRECT_DIRECT
        ];
        for (uint256 i = 0; i < sequence.length; ++i) {
            _setRouting(sequence[i]);
            assertEq(_allowance(address(candidate)), 0);
            assertEq(_allowance(address(vault)), _usesVault(sequence[i]) ? MAX : 0);
            assertEq(address(forwarder.pendingVault()), address(candidate));
        }
    }

    function test_ForwardWhilePendingUsesTheActiveVault() public {
        _setRouting(VAULT_VAULT);
        _setFees(FIXED, FIXED, 0, 1e6, 0);
        _proposeVault(address(candidate));
        _forward(100e6, user);
        assertEq(vault.convertToAssets(vault.balanceOf(user)), 99e6);
        assertEq(vault.convertToAssets(vault.balanceOf(treasury)), 1e6);
        assertEq(candidate.balanceOf(user), 0);
        assertEq(candidate.totalSupply(), 0);
        assertEq(_allowance(address(candidate)), 0);
        assertEq(address(forwarder.pendingVault()), address(candidate));
    }
}

/// @dev Reentrancy around the vault lifecycle (spec V2 section 18, reentrancy).
contract ForwarderVaultChangeReentrancyTest is VaultChangeFixture {
    bytes internal guardError;
    ReentrantVault internal evilCandidate;

    function setUp() public override {
        super.setUp();
        guardError = abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        evilCandidate = new ReentrantVault(IERC20(address(usdc)));
    }

    function _assertBlocked(ReentrantVault target) internal view {
        assertTrue(target.attempted(), "reentry not attempted");
        assertFalse(target.reentrySucceeded(), "reentry succeeded");
        assertEq(target.reentryReturnData(), guardError);
    }

    /// @dev Single-call pranks: the reentering mocks use `vm.prank` themselves.
    function _proposeOnce(address target) internal {
        _fundAdminForHealthCheck();
        vm.prank(admin);
        forwarder.proposeVault(IERC4626(target));
    }

    function _executeOnce() internal {
        _fundAdminForHealthCheck();
        vm.prank(admin);
        forwarder.executeVaultChange();
    }

    function test_CandidateCannotReenterExecuteDuringProposal() public {
        evilCandidate.arm(address(forwarder), abi.encodeCall(Forwarder.executeVaultChange, ()), admin);
        _proposeOnce(address(evilCandidate));
        _assertBlocked(evilCandidate);
        assertEq(address(forwarder.vault()), address(vault));
        assertEq(address(forwarder.pendingVault()), address(evilCandidate));
    }

    function test_CandidateCannotReenterExecuteDuringExecution() public {
        _proposeOnce(address(evilCandidate));
        vm.warp(forwarder.pendingVaultExecutableAt());
        evilCandidate.arm(address(forwarder), abi.encodeCall(Forwarder.executeVaultChange, ()), admin);
        _executeOnce();
        _assertBlocked(evilCandidate);
        assertEq(address(forwarder.vault()), address(evilCandidate));
        _assertNoPending();
    }

    function test_CandidateCannotReenterProposeDuringExecution() public {
        _proposeOnce(address(evilCandidate));
        vm.warp(forwarder.pendingVaultExecutableAt());
        evilCandidate.arm(
            address(forwarder), abi.encodeCall(Forwarder.proposeVault, (IERC4626(address(candidate)))), admin
        );
        _executeOnce();
        _assertBlocked(evilCandidate);
        assertEq(address(forwarder.vault()), address(evilCandidate));
        _assertNoPending();
    }

    function test_CandidateCannotReenterForwardDuringExecution() public {
        _proposeOnce(address(evilCandidate));
        vm.warp(forwarder.pendingVaultExecutableAt());
        evilCandidate.arm(
            address(forwarder), abi.encodeCall(Forwarder.forward, (address(usdc), 0, stranger)), address(0)
        );
        _executeOnce();
        _assertBlocked(evilCandidate);
    }

    function test_CandidateCannotReenterSetRoutingModeDuringExecution() public {
        _proposeOnce(address(evilCandidate));
        vm.warp(forwarder.pendingVaultExecutableAt());
        evilCandidate.arm(address(forwarder), abi.encodeCall(Forwarder.setRoutingMode, (VAULT_VAULT)), admin);
        _executeOnce();
        _assertBlocked(evilCandidate);
        assertEq(uint8(forwarder.routingMode()), uint8(DIRECT_DIRECT));
        assertEq(_allowance(address(evilCandidate)), 0);
    }

    /// @dev The pending state is cleared before any external call of the execution: a reentrant cancel finds nothing.
    function test_ReentrantCancelDuringExecutionFindsNothingPending() public {
        _proposeOnce(address(evilCandidate));
        vm.warp(forwarder.pendingVaultExecutableAt());
        evilCandidate.arm(address(forwarder), abi.encodeCall(Forwarder.cancelVaultChange, ()), admin);
        _executeOnce();
        assertTrue(evilCandidate.attempted());
        assertFalse(evilCandidate.reentrySucceeded());
        assertEq(evilCandidate.reentryReturnData(), abi.encodeWithSelector(Forwarder.NoPendingVaultChange.selector));
        assertEq(address(forwarder.vault()), address(evilCandidate));
    }

    /// @dev `cancelVaultChange` makes no external call and is not guarded. A reentrant cancel during a proposal (only
    /// possible for an account that holds the admin or guardian role) leaves a consistent state: as if the proposal
    /// had been cancelled right after it.
    function test_ReentrantCancelDuringProposalLeavesConsistentState() public {
        evilCandidate.arm(address(forwarder), abi.encodeCall(Forwarder.cancelVaultChange, ()), guardian);
        _proposeOnce(address(evilCandidate));
        assertTrue(evilCandidate.reentrySucceeded());
        _assertNoPending();
        assertEq(address(forwarder.vault()), address(vault));
        assertEq(_allowance(address(evilCandidate)), 0);
        assertEq(usdc.balanceOf(admin), TEST_AMOUNT);
    }

    /// @dev The active vault reenters the execution of a change that is not yet executable: always rejected.
    function test_ActiveVaultCannotReenterExecuteFromForward() public {
        _replaceVault(address(evilCandidate));
        _setRouting(VAULT_VAULT);
        _proposeOnce(address(candidate));
        _fundAdminForHealthCheck();
        evilCandidate.arm(address(forwarder), abi.encodeCall(Forwarder.executeVaultChange, ()), admin);
        _fundSra(10e6);
        vm.prank(sra);
        forwarder.forward(address(usdc), 10e6, user);
        _assertBlocked(evilCandidate);
        assertEq(address(forwarder.vault()), address(evilCandidate));
        assertEq(address(forwarder.pendingVault()), address(candidate));
    }

    /// @dev No reentrancy path executes a change before its delay: the delay check does not depend on the guard.
    function test_NoReentrantPathExecutesBeforeTheDelay() public {
        _proposeOnce(address(candidate));
        uint256 executableAt = forwarder.pendingVaultExecutableAt();
        _fundAdminForHealthCheck();

        ReentrantToken token = new ReentrantToken();
        token.mint(address(forwarder), 1e18);
        token.arm(address(forwarder), abi.encodeCall(Forwarder.executeVaultChange, ()), admin);
        vm.prank(admin);
        forwarder.rescueToken(IERC20(address(token)));
        assertFalse(token.reentrySucceeded());
        assertEq(token.reentryReturnData(), guardError);

        // Outside of any guarded call the delay check is what rejects the execution.
        _expectTooEarly(executableAt);
        vm.prank(admin);
        forwarder.executeVaultChange();
        assertEq(address(forwarder.vault()), address(vault));
        _assertPending(address(candidate), executableAt);
    }
}
