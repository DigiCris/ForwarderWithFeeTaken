// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Forwarder} from "../src/Forwarder.sol";
import {MockERC20} from "./mocks/MockTokens.sol";
import {MockVault} from "./mocks/MockVault.sol";
import {ForwarderTestBase} from "./utils/ForwarderTestBase.sol";

/// @dev Treasury cooling period: `proposeTreasury` -> 72 hours -> `executeTreasuryChange`, and `cancelTreasuryChange`.
contract ForwarderTreasuryChangeTest is ForwarderTestBase {
    address internal newTreasury = makeAddr("newTreasury");

    function _expectUnauthorized(address account, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role));
    }

    function _expectTooEarly(uint256 executableAt) internal {
        vm.expectRevert(abi.encodeWithSelector(Forwarder.TreasuryChangeDelayNotElapsed.selector, executableAt));
    }

    function _propose(address candidate) internal returns (uint256 executableAt) {
        vm.prank(admin);
        forwarder.proposeTreasury(candidate);
        executableAt = forwarder.pendingTreasuryExecutableAt();
    }

    function _execute() internal {
        vm.prank(admin);
        forwarder.executeTreasuryChange();
    }

    function _assertNoPending() internal view {
        assertEq(forwarder.pendingTreasury(), address(0), "pending treasury");
        assertEq(forwarder.pendingTreasuryExecutableAt(), 0, "pending timestamp");
    }

    /// @dev Everything outside the treasury that the treasury lifecycle must not touch.
    function _otherStateHash() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                forwarder.vault(),
                forwarder.routingMode(),
                forwarder.lowerFeeModel(),
                forwarder.upperFeeModel(),
                forwarder.threshold(),
                forwarder.fixedFee(),
                forwarder.variableFee(),
                forwarder.paused(),
                forwarder.pendingVault(),
                forwarder.pendingVaultExecutableAt(),
                _pendingFeeExecutableAt(),
                usdc.allowance(address(forwarder), address(vault))
            )
        );
    }

    // -----------------------------------------------------------------------------------------------------------
    // Proposal
    // -----------------------------------------------------------------------------------------------------------

    function test_AdminProposes() public {
        uint256 expectedAt = block.timestamp + 72 hours;
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TreasuryChangeProposed(treasury, newTreasury, expectedAt, admin);
        uint256 executableAt = _propose(newTreasury);
        assertEq(executableAt, expectedAt);
        assertEq(forwarder.pendingTreasury(), newTreasury);
        assertEq(forwarder.treasury(), treasury, "active treasury unchanged");
    }

    function test_ProposalDoesNotTouchAnythingElse() public {
        _setFees(FIXED, FIXED, 0, 1e6, 0);
        _setRouting(VAULT_USER_DIRECT_TREASURY);
        bytes32 other = _otherStateHash();
        _propose(newTreasury);
        assertEq(_otherStateHash(), other);
        assertEq(forwarder.treasury(), treasury);
    }

    function test_RevertWhen_ProposingWhileAChangeIsPending() public {
        uint256 executableAt = _propose(newTreasury);
        vm.expectRevert(abi.encodeWithSelector(Forwarder.TreasuryChangeAlreadyPending.selector, newTreasury));
        vm.prank(admin);
        forwarder.proposeTreasury(stranger);
        vm.warp(executableAt + 1 days); // matured but not executed: still no overwrite
        vm.expectRevert(abi.encodeWithSelector(Forwarder.TreasuryChangeAlreadyPending.selector, newTreasury));
        vm.prank(admin);
        forwarder.proposeTreasury(stranger);
        assertEq(forwarder.pendingTreasury(), newTreasury);
        assertEq(forwarder.pendingTreasuryExecutableAt(), executableAt);
    }

    function test_RevertWhen_ProposingAnInvalidTreasury() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Forwarder.InvalidTreasury.selector, address(0)));
        forwarder.proposeTreasury(address(0));
        vm.expectRevert(abi.encodeWithSelector(Forwarder.InvalidTreasury.selector, address(forwarder)));
        forwarder.proposeTreasury(address(forwarder));
        vm.stopPrank();
        _assertNoPending();
    }

    function test_RevertWhen_FeeManagerProposes() public {
        _expectUnauthorized(feeManager, DEFAULT_ADMIN_ROLE);
        vm.prank(feeManager);
        forwarder.proposeTreasury(newTreasury);
        _assertNoPending();
    }

    function test_RevertWhen_GuardianProposes() public {
        _expectUnauthorized(guardian, DEFAULT_ADMIN_ROLE);
        vm.prank(guardian);
        forwarder.proposeTreasury(newTreasury);
        _assertNoPending();
    }

    function test_RevertWhen_StrangerProposes() public {
        _expectUnauthorized(stranger, DEFAULT_ADMIN_ROLE);
        vm.prank(stranger);
        forwarder.proposeTreasury(newTreasury);
        _assertNoPending();
    }

    // -----------------------------------------------------------------------------------------------------------
    // Execution
    // -----------------------------------------------------------------------------------------------------------

    function test_RevertWhen_ExecutingImmediately() public {
        uint256 executableAt = _propose(newTreasury);
        _expectTooEarly(executableAt);
        _execute();
        assertEq(forwarder.treasury(), treasury);
    }

    function test_RevertWhen_ExecutingOneSecondEarly() public {
        uint256 executableAt = _propose(newTreasury);
        vm.warp(executableAt - 1);
        _expectTooEarly(executableAt);
        _execute();
        assertEq(forwarder.treasury(), treasury);
        assertEq(forwarder.pendingTreasury(), newTreasury);
    }

    function test_ExecuteExactlyAtExecutableAt() public {
        uint256 executableAt = _propose(newTreasury);
        vm.warp(executableAt);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TreasuryUpdated(treasury, newTreasury);
        _execute();
        assertEq(forwarder.treasury(), newTreasury);
        _assertNoPending();
    }

    function test_ExecuteLongAfterExecutableAt() public {
        uint256 executableAt = _propose(newTreasury);
        vm.warp(executableAt + 400 days);
        _execute();
        assertEq(forwarder.treasury(), newTreasury);
        _assertNoPending();
    }

    function test_ExecutionOnlyChangesTheTreasury() public {
        _setFees(FIXED, PERCENT, 5e6, 1e6, 100);
        _setRouting(VAULT_VAULT);
        _proposeFees(PERCENT, PERCENT, 0, 0, 7);
        _proposeVault(address(new MockVault(IERC20(address(usdc)))));
        vm.prank(feeManager);
        forwarder.pause();
        bytes32 other = _otherStateHash();
        uint256 executableAt = _propose(newTreasury);
        vm.warp(executableAt);
        _execute();
        assertEq(_otherStateHash(), other);
        assertEq(forwarder.treasury(), newTreasury);
    }

    function test_RevertWhen_GuardianExecutes() public {
        vm.warp(_propose(newTreasury));
        _expectUnauthorized(guardian, DEFAULT_ADMIN_ROLE);
        vm.prank(guardian);
        forwarder.executeTreasuryChange();
        assertEq(forwarder.treasury(), treasury);
    }

    function test_RevertWhen_FeeManagerExecutes() public {
        vm.warp(_propose(newTreasury));
        _expectUnauthorized(feeManager, DEFAULT_ADMIN_ROLE);
        vm.prank(feeManager);
        forwarder.executeTreasuryChange();
        assertEq(forwarder.treasury(), treasury);
    }

    function test_RevertWhen_StrangerExecutes() public {
        vm.warp(_propose(newTreasury));
        _expectUnauthorized(stranger, DEFAULT_ADMIN_ROLE);
        vm.prank(stranger);
        forwarder.executeTreasuryChange();
        assertEq(forwarder.treasury(), treasury);
    }

    function test_RevertWhen_ExecutingWithNothingPending() public {
        vm.expectRevert(Forwarder.NoPendingTreasuryChange.selector);
        _execute();
    }

    function test_RevertWhen_ExecutingTwice() public {
        vm.warp(_propose(newTreasury));
        _execute();
        vm.expectRevert(Forwarder.NoPendingTreasuryChange.selector);
        _execute();
    }

    function test_AdminRotationDoesNotChangeExecutableAt() public {
        uint256 executableAt = _propose(newTreasury);
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        forwarder.beginDefaultAdminTransfer(newAdmin);
        vm.warp(block.timestamp + ADMIN_DELAY + 1);
        vm.prank(newAdmin);
        forwarder.acceptDefaultAdminTransfer();
        assertEq(forwarder.pendingTreasuryExecutableAt(), executableAt);

        vm.warp(executableAt);
        _expectUnauthorized(admin, DEFAULT_ADMIN_ROLE);
        vm.prank(admin);
        forwarder.executeTreasuryChange();
        vm.prank(newAdmin);
        forwarder.executeTreasuryChange();
        assertEq(forwarder.treasury(), newTreasury);
    }

    function test_RevokingAllGuardiansDoesNotShortenTheDelay() public {
        uint256 executableAt = _propose(newTreasury);
        vm.startPrank(admin);
        forwarder.revokeRole(VAULT_GUARDIAN_ROLE, guardian);
        forwarder.revokeRole(VAULT_GUARDIAN_ROLE, guardian2);
        vm.stopPrank();
        assertEq(forwarder.pendingTreasuryExecutableAt(), executableAt);
        vm.warp(executableAt - 1);
        _expectTooEarly(executableAt);
        _execute();
    }

    // -----------------------------------------------------------------------------------------------------------
    // Cancellation
    // -----------------------------------------------------------------------------------------------------------

    function test_GuardianCancels() public {
        _cancelAs(guardian);
    }

    function test_AnotherGuardianCancels() public {
        _cancelAs(guardian2);
    }

    function test_AdminCancels() public {
        _cancelAs(admin);
    }

    function _cancelAs(address canceller) internal {
        bytes32 other = _otherStateHash();
        _propose(newTreasury);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TreasuryChangeCancelled(newTreasury, canceller);
        vm.prank(canceller);
        forwarder.cancelTreasuryChange();
        _assertNoPending();
        assertEq(forwarder.treasury(), treasury);
        assertEq(_otherStateHash(), other);
    }

    function test_RevertWhen_FeeManagerWithoutGuardianRoleCancels() public {
        _propose(newTreasury);
        _expectUnauthorized(feeManager, VAULT_GUARDIAN_ROLE);
        vm.prank(feeManager);
        forwarder.cancelTreasuryChange();
        assertEq(forwarder.pendingTreasury(), newTreasury);
    }

    function test_RevertWhen_StrangerCancels() public {
        _propose(newTreasury);
        _expectUnauthorized(stranger, VAULT_GUARDIAN_ROLE);
        vm.prank(stranger);
        forwarder.cancelTreasuryChange();
        assertEq(forwarder.pendingTreasury(), newTreasury);
    }

    function test_CancelBeforeAtAndAfterMaturity() public {
        uint256[3] memory offsets = [uint256(0), 72 hours, 1000 days];
        for (uint256 i = 0; i < offsets.length; ++i) {
            _propose(newTreasury);
            vm.warp(block.timestamp + offsets[i]);
            vm.prank(guardian);
            forwarder.cancelTreasuryChange();
            _assertNoPending();
        }
        assertEq(forwarder.treasury(), treasury);
    }

    function test_RevertWhen_CancellingWithNothingPending() public {
        vm.expectRevert(Forwarder.NoPendingTreasuryChange.selector);
        vm.prank(guardian);
        forwarder.cancelTreasuryChange();
        vm.expectRevert(Forwarder.NoPendingTreasuryChange.selector);
        vm.prank(admin);
        forwarder.cancelTreasuryChange();
    }

    function test_CancelledChangeCannotBeExecuted() public {
        uint256 executableAt = _propose(newTreasury);
        vm.prank(guardian);
        forwarder.cancelTreasuryChange();
        vm.warp(executableAt);
        vm.expectRevert(Forwarder.NoPendingTreasuryChange.selector);
        _execute();
        assertEq(forwarder.treasury(), treasury);
    }

    function test_ProposeAgainAfterCancellationRestartsTheDelay() public {
        _propose(newTreasury);
        vm.warp(block.timestamp + 71 hours);
        vm.prank(admin);
        forwarder.cancelTreasuryChange();
        uint256 executableAt = _propose(stranger);
        assertEq(executableAt, block.timestamp + 72 hours);
        vm.warp(block.timestamp + 1 hours);
        _expectTooEarly(executableAt);
        _execute();
    }

    function test_ProposeAgainAfterExecution() public {
        vm.warp(_propose(newTreasury));
        _execute();
        uint256 executableAt = _propose(treasury);
        assertEq(executableAt, block.timestamp + 72 hours);
        assertEq(forwarder.treasury(), newTreasury);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Funds while a change is pending
    // -----------------------------------------------------------------------------------------------------------

    /// @dev Fees keep going to the active treasury until the execution; the pending treasury never receives funds.
    function test_ForwardDeliversToTheActiveTreasuryUntilExecution() public {
        _setFees(FIXED, FIXED, 0, 1e6, 0);
        Forwarder.RoutingMode[4] memory modes =
            [DIRECT_DIRECT, VAULT_USER_DIRECT_TREASURY, DIRECT_USER_VAULT_TREASURY, VAULT_VAULT];
        uint256 executableAt = _propose(newTreasury);
        for (uint256 i = 0; i < modes.length; ++i) {
            _setRouting(modes[i]);
            _forward(10e6, user);
        }
        _setRouting(DIRECT_DIRECT);
        vm.warp(executableAt - 1);
        _forward(10e6, user);
        // 3 USDC fees in DIRECT modes (direct, direct, plus the last forward) + 2 USDC as vault shares.
        assertEq(usdc.balanceOf(treasury), 3e6);
        assertEq(vault.balanceOf(treasury), 2e6 * 1e12);
        assertEq(usdc.balanceOf(newTreasury), 0);
        assertEq(vault.balanceOf(newTreasury), 0);

        vm.warp(executableAt);
        _execute();
        _forward(10e6, user);
        assertEq(usdc.balanceOf(newTreasury), 1e6);
        assertEq(usdc.balanceOf(treasury), 3e6);
    }

    function test_RescueTokenBeforeExecutionGoesToTheActiveTreasury() public {
        uint256 executableAt = _propose(newTreasury);
        usdc.mint(address(forwarder), 5e6);
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(address(forwarder), 1e18);
        vm.warp(executableAt - 1);
        vm.startPrank(admin);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TokenRescued(address(usdc), treasury, 5e6);
        forwarder.rescueToken(IERC20(address(usdc)));
        forwarder.rescueToken(IERC20(address(other)));
        vm.stopPrank();
        assertEq(usdc.balanceOf(treasury), 5e6);
        assertEq(other.balanceOf(treasury), 1e18);
        assertEq(usdc.balanceOf(newTreasury), 0);
        assertEq(other.balanceOf(newTreasury), 0);
    }

    function test_RescueNativeBeforeExecutionGoesToTheActiveTreasury() public {
        uint256 executableAt = _propose(newTreasury);
        vm.deal(address(forwarder), 1 ether);
        vm.warp(executableAt);
        vm.prank(admin);
        forwarder.rescueNative(); // matured but not executed: still the active treasury
        assertEq(treasury.balance, 1 ether);
        assertEq(newTreasury.balance, 0);
    }

    function test_RescueAfterExecutionGoesToTheNewTreasury() public {
        vm.warp(_propose(newTreasury));
        _execute();
        usdc.mint(address(forwarder), 5e6);
        vm.deal(address(forwarder), 1 ether);
        vm.startPrank(admin);
        forwarder.rescueToken(IERC20(address(usdc)));
        forwarder.rescueNative();
        vm.stopPrank();
        assertEq(usdc.balanceOf(newTreasury), 5e6);
        assertEq(newTreasury.balance, 1 ether);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    /// @dev USDC stuck because the active treasury cannot receive stays in the Forwarder while the change is pending
    /// and goes to the new treasury with the first `forward` after the execution.
    function test_StuckFeesReachTheNewTreasuryOnlyAfterExecution() public {
        _setFees(FIXED, FIXED, 0, 1e6, 0);
        usdc.setBlacklisted(treasury, true);
        uint256 executableAt = _propose(newTreasury);
        _forward(10e6, user);
        vm.warp(executableAt - 1);
        _forward(10e6, user);
        assertEq(usdc.balanceOf(address(forwarder)), 2e6);
        assertEq(usdc.balanceOf(newTreasury), 0);

        vm.warp(executableAt);
        _execute();
        _forward(10e6, user);
        assertEq(usdc.balanceOf(newTreasury), 3e6);
        assertEq(usdc.balanceOf(address(forwarder)), 0);
    }
}
