// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Forwarder} from "../src/Forwarder.sol";
import {MockVault} from "./mocks/MockVault.sol";
import {ForwarderTestBase} from "./utils/ForwarderTestBase.sol";

/// @dev Global fee configuration cooling period: `proposeFeeConfig` -> 72 hours -> `executeFeeConfigChange`, and
/// `cancelFeeConfigChange`.
contract ForwarderFeeChangeTest is ForwarderTestBase {
    function _expectUnauthorized(address account, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role));
    }

    function _expectTooEarly(uint256 executableAt) internal {
        vm.expectRevert(abi.encodeWithSelector(Forwarder.FeeConfigChangeDelayNotElapsed.selector, executableAt));
    }

    function _activeConfigHash() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                forwarder.lowerFeeModel(),
                forwarder.upperFeeModel(),
                forwarder.threshold(),
                forwarder.fixedFee(),
                forwarder.variableFee()
            )
        );
    }

    /// @dev Everything outside the fee configuration that the fee lifecycle must not touch.
    function _otherStateHash() internal view returns (bytes32) {
        (uint256 overrideFixed, uint256 overrideVariable, uint256 validUntil) = forwarder.userFeeOverrides(user);
        return keccak256(
            abi.encode(
                forwarder.treasury(),
                forwarder.vault(),
                forwarder.routingMode(),
                forwarder.paused(),
                forwarder.pendingVault(),
                forwarder.pendingVaultExecutableAt(),
                forwarder.pendingTreasury(),
                forwarder.pendingTreasuryExecutableAt(),
                overrideFixed,
                overrideVariable,
                validUntil,
                usdc.allowance(address(forwarder), address(vault))
            )
        );
    }

    function _assertNoPending() internal view {
        (
            Forwarder.FeeModel lower,
            Forwarder.FeeModel upper,
            uint256 pendingThreshold,
            uint256 pendingFixedFee,
            uint256 pendingVariableFee,
            uint256 executableAt
        ) = forwarder.pendingFeeConfig();
        assertEq(uint8(lower), 0, "pending lower");
        assertEq(uint8(upper), 0, "pending upper");
        assertEq(pendingThreshold, 0, "pending threshold");
        assertEq(pendingFixedFee, 0, "pending fixed");
        assertEq(pendingVariableFee, 0, "pending variable");
        assertEq(executableAt, 0, "pending executableAt");
    }

    function _assertActive(
        Forwarder.FeeModel lower,
        Forwarder.FeeModel upper,
        uint256 threshold,
        uint256 fixedFee,
        uint256 variableFee
    ) internal view {
        assertEq(uint8(forwarder.lowerFeeModel()), uint8(lower), "lower");
        assertEq(uint8(forwarder.upperFeeModel()), uint8(upper), "upper");
        assertEq(forwarder.threshold(), threshold, "threshold");
        assertEq(forwarder.fixedFee(), fixedFee, "fixed");
        assertEq(forwarder.variableFee(), variableFee, "variable");
    }

    // -----------------------------------------------------------------------------------------------------------
    // Proposal
    // -----------------------------------------------------------------------------------------------------------

    function test_FeeManagerProposes() public {
        uint256 expectedAt = block.timestamp + 72 hours;
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.FeeConfigChangeProposed(FIXED, FIXED_PLUS_PERCENT, 100e6, 2e6, 1500, expectedAt, feeManager);
        _proposeFees(FIXED, FIXED_PLUS_PERCENT, 100e6, 2e6, 1500);

        (
            Forwarder.FeeModel lower,
            Forwarder.FeeModel upper,
            uint256 pendingThreshold,
            uint256 pendingFixedFee,
            uint256 pendingVariableFee,
            uint256 executableAt
        ) = forwarder.pendingFeeConfig();
        assertEq(uint8(lower), uint8(FIXED));
        assertEq(uint8(upper), uint8(FIXED_PLUS_PERCENT));
        assertEq(pendingThreshold, 100e6);
        assertEq(pendingFixedFee, 2e6);
        assertEq(pendingVariableFee, 1500);
        assertEq(executableAt, expectedAt);
    }

    function test_ProposalDoesNotChangeActiveConfiguration() public {
        _setFees(FIXED, FIXED, 0, 1e6, 0);
        bytes32 active = _activeConfigHash();
        bytes32 other = _otherStateHash();
        _proposeFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, 10e6, 10_000);

        assertEq(_activeConfigHash(), active);
        assertEq(_otherStateHash(), other);
        assertEq(forwarder.calculateFee(100e6), 1e6);
        assertEq(forwarder.calculateFeeFor(user, 100e6), 1e6);

        // Until the execution `forward` keeps charging the active configuration.
        vm.warp(_pendingFeeExecutableAt() - 1);
        _forward(100e6, user);
        assertEq(usdc.balanceOf(user), 99e6);
        assertEq(usdc.balanceOf(treasury), 1e6);
    }

    function test_ExecutableAtIsAlwaysProposalTimePlus72Hours() public {
        uint256[3] memory times = [uint256(1), 1_700_000_000, 4_000_000_000];
        for (uint256 i = 0; i < times.length; ++i) {
            vm.warp(times[i]);
            _proposeFees(FIXED, FIXED, 0, i, 0);
            assertEq(_pendingFeeExecutableAt(), times[i] + 72 hours);
            vm.prank(feeManager);
            forwarder.cancelFeeConfigChange();
        }
    }

    function test_RevertWhen_ProposingWhileAChangeIsPending() public {
        _proposeFees(FIXED, FIXED, 0, 1e6, 0);
        uint256 executableAt = _pendingFeeExecutableAt();
        vm.expectRevert(abi.encodeWithSelector(Forwarder.FeeConfigChangeAlreadyPending.selector, executableAt));
        _proposeFees(PERCENT, PERCENT, 0, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(Forwarder.FeeConfigChangeAlreadyPending.selector, executableAt));
        vm.prank(feeManager2);
        forwarder.proposeFeeConfig(NONE, NONE, 0, 0, 0);

        // Still rejected once the pending change has matured: there is no overwrite.
        vm.warp(executableAt + 1 days);
        vm.expectRevert(abi.encodeWithSelector(Forwarder.FeeConfigChangeAlreadyPending.selector, executableAt));
        _proposeFees(PERCENT, PERCENT, 0, 0, 1);

        (,,, uint256 pendingFixedFee,, uint256 pendingAt) = forwarder.pendingFeeConfig();
        assertEq(pendingFixedFee, 1e6);
        assertEq(pendingAt, executableAt);
    }

    function test_ProposalValidatesTheCaps() public {
        vm.startPrank(feeManager);
        vm.expectRevert(abi.encodeWithSelector(Forwarder.FixedFeeTooHigh.selector, 10e6 + 1));
        forwarder.proposeFeeConfig(FIXED, FIXED, 0, 10e6 + 1, 0);
        vm.expectRevert(abi.encodeWithSelector(Forwarder.VariableFeeTooHigh.selector, 10_001));
        forwarder.proposeFeeConfig(PERCENT, PERCENT, 0, 0, 10_001);
        vm.expectRevert(abi.encodeWithSelector(Forwarder.FixedFeeTooHigh.selector, MAX));
        forwarder.proposeFeeConfig(NONE, NONE, 0, MAX, MAX);
        vm.stopPrank();
        _assertNoPending();

        // The caps themselves are accepted.
        _proposeFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, MAX, 10e6, 10_000);
        (,, uint256 pendingThreshold, uint256 pendingFixedFee, uint256 pendingVariableFee,) =
            forwarder.pendingFeeConfig();
        assertEq(pendingThreshold, MAX);
        assertEq(pendingFixedFee, 10e6);
        assertEq(pendingVariableFee, 10_000);
    }

    function test_RevertWhen_InvalidModelIsProposed() public {
        vm.prank(feeManager);
        (bool success,) =
            address(forwarder).call(abi.encodeWithSelector(Forwarder.proposeFeeConfig.selector, 4, 0, 0, 0, 0));
        assertFalse(success);
        vm.prank(feeManager);
        (success,) = address(forwarder).call(abi.encodeWithSelector(Forwarder.proposeFeeConfig.selector, 0, 4, 0, 0, 0));
        assertFalse(success);
        _assertNoPending();
    }

    function test_EveryFeeManagerCanPropose() public {
        _proposeFees(FIXED, FIXED, 0, 1, 0);
        vm.prank(feeManager);
        forwarder.cancelFeeConfigChange();
        vm.prank(feeManager2);
        forwarder.proposeFeeConfig(FIXED, FIXED, 0, 2, 0);
        (,,, uint256 pendingFixedFee,,) = forwarder.pendingFeeConfig();
        assertEq(pendingFixedFee, 2);
    }

    function test_RevertWhen_StrangerProposes() public {
        _expectUnauthorized(stranger, FEE_MANAGER_ROLE);
        vm.prank(stranger);
        forwarder.proposeFeeConfig(FIXED, FIXED, 0, 1, 0);
        _assertNoPending();
    }

    function test_RevertWhen_GuardianProposes() public {
        _expectUnauthorized(guardian, FEE_MANAGER_ROLE);
        vm.prank(guardian);
        forwarder.proposeFeeConfig(FIXED, FIXED, 0, 1, 0);
        _assertNoPending();
    }

    function test_RevertWhen_AdminProposes() public {
        _expectUnauthorized(admin, FEE_MANAGER_ROLE);
        vm.prank(admin);
        forwarder.proposeFeeConfig(FIXED, FIXED, 0, 1, 0);
        _assertNoPending();
    }

    // -----------------------------------------------------------------------------------------------------------
    // Execution
    // -----------------------------------------------------------------------------------------------------------

    function test_RevertWhen_ExecutingImmediately() public {
        _proposeFees(FIXED, FIXED, 0, 1e6, 0);
        uint256 executableAt = _pendingFeeExecutableAt();
        _expectTooEarly(executableAt);
        vm.prank(feeManager);
        forwarder.executeFeeConfigChange();
        _assertActive(NONE, NONE, 0, 0, 0);
    }

    function test_RevertWhen_ExecutingOneSecondEarly() public {
        _proposeFees(FIXED, FIXED, 0, 1e6, 0);
        uint256 executableAt = _pendingFeeExecutableAt();
        vm.warp(executableAt - 1);
        _expectTooEarly(executableAt);
        vm.prank(feeManager);
        forwarder.executeFeeConfigChange();
        _assertActive(NONE, NONE, 0, 0, 0);
        assertEq(_pendingFeeExecutableAt(), executableAt);
    }

    function test_ExecuteExactlyAtExecutableAt() public {
        _proposeFees(FIXED, PERCENT, 100e6, 3e6, 2000);
        vm.warp(_pendingFeeExecutableAt());
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.FeeConfigUpdated(FIXED, PERCENT, 100e6, 3e6, 2000);
        vm.prank(feeManager);
        forwarder.executeFeeConfigChange();
        _assertActive(FIXED, PERCENT, 100e6, 3e6, 2000);
        _assertNoPending();
        assertEq(forwarder.calculateFee(100e6), 3e6);
        assertEq(forwarder.calculateFee(200e6), 4e6);
    }

    function test_ExecuteAfterExecutableAt() public {
        uint256[2] memory delays = [uint256(1), 365 days];
        for (uint256 i = 0; i < delays.length; ++i) {
            _proposeFees(FIXED, FIXED, 0, i + 1, 0);
            vm.warp(_pendingFeeExecutableAt() + delays[i]);
            vm.prank(feeManager);
            forwarder.executeFeeConfigChange();
            assertEq(forwarder.fixedFee(), i + 1);
            _assertNoPending();
        }
    }

    function test_AnotherFeeManagerExecutes() public {
        _proposeFees(FIXED, FIXED, 0, 1e6, 0);
        vm.warp(_pendingFeeExecutableAt());
        vm.prank(feeManager2);
        forwarder.executeFeeConfigChange();
        assertEq(forwarder.fixedFee(), 1e6);
    }

    function test_RevertWhen_GuardianExecutes() public {
        _proposeFees(FIXED, FIXED, 0, 1e6, 0);
        vm.warp(_pendingFeeExecutableAt());
        _expectUnauthorized(guardian, FEE_MANAGER_ROLE);
        vm.prank(guardian);
        forwarder.executeFeeConfigChange();
        assertEq(forwarder.fixedFee(), 0);
    }

    function test_RevertWhen_StrangerExecutes() public {
        _proposeFees(FIXED, FIXED, 0, 1e6, 0);
        vm.warp(_pendingFeeExecutableAt());
        _expectUnauthorized(stranger, FEE_MANAGER_ROLE);
        vm.prank(stranger);
        forwarder.executeFeeConfigChange();
        assertEq(forwarder.fixedFee(), 0);
    }

    function test_RevertWhen_AdminExecutes() public {
        _proposeFees(FIXED, FIXED, 0, 1e6, 0);
        vm.warp(_pendingFeeExecutableAt());
        _expectUnauthorized(admin, FEE_MANAGER_ROLE);
        vm.prank(admin);
        forwarder.executeFeeConfigChange();
        assertEq(forwarder.fixedFee(), 0);
    }

    /// @dev The default admin can give itself FEE_MANAGER_ROLE, but the delay still applies to it.
    function test_AdminWithFeeManagerRoleStillWaitsTheDelay() public {
        vm.startPrank(admin);
        forwarder.grantRole(FEE_MANAGER_ROLE, admin);
        forwarder.proposeFeeConfig(FIXED, FIXED, 0, 10e6, 0);
        uint256 executableAt = block.timestamp + 72 hours;
        _expectTooEarly(executableAt);
        forwarder.executeFeeConfigChange();
        vm.warp(executableAt - 1);
        _expectTooEarly(executableAt);
        forwarder.executeFeeConfigChange();
        vm.warp(executableAt);
        forwarder.executeFeeConfigChange();
        vm.stopPrank();
        assertEq(forwarder.fixedFee(), 10e6);
    }

    function test_RevertWhen_ExecutingWithNothingPending() public {
        vm.expectRevert(Forwarder.NoPendingFeeConfigChange.selector);
        vm.prank(feeManager);
        forwarder.executeFeeConfigChange();
    }

    function test_RevertWhen_ExecutingTwice() public {
        _setFees(FIXED, FIXED, 0, 1e6, 0);
        vm.expectRevert(Forwarder.NoPendingFeeConfigChange.selector);
        vm.prank(feeManager);
        forwarder.executeFeeConfigChange();
    }

    function test_ExecutionOnlyChangesTheFeeConfiguration() public {
        _setOverrideBaseline();
        bytes32 other = _otherStateHash();
        _setFees(PERCENT, FIXED, 7, 8, 9);
        assertEq(_otherStateHash(), other);
        _assertActive(PERCENT, FIXED, 7, 8, 9);
    }

    function _setOverrideBaseline() internal {
        _setFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, 5e6, 5000);
        _setOverride(user, 1e6, 1000, block.timestamp + 365 days);
        vm.prank(admin);
        forwarder.proposeTreasury(makeAddr("pendingTreasury"));
        _proposeVault(address(new MockVault(IERC20(address(usdc)))));
        _setRouting(VAULT_VAULT);
        vm.prank(feeManager);
        forwarder.pause();
    }

    // -----------------------------------------------------------------------------------------------------------
    // Cancellation
    // -----------------------------------------------------------------------------------------------------------

    function test_GuardianCancels() public {
        _cancelAs(guardian);
    }

    function test_AdminCancels() public {
        _cancelAs(admin);
    }

    function test_ProposingFeeManagerCancels() public {
        _cancelAs(feeManager);
    }

    function test_AnotherFeeManagerCancels() public {
        _cancelAs(feeManager2);
    }

    function _cancelAs(address canceller) internal {
        _setFees(FIXED, FIXED, 0, 1e6, 0);
        bytes32 active = _activeConfigHash();
        bytes32 other = _otherStateHash();
        _proposeFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, 10e6, 10_000);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.FeeConfigChangeCancelled(canceller);
        vm.prank(canceller);
        forwarder.cancelFeeConfigChange();
        _assertNoPending();
        assertEq(_activeConfigHash(), active);
        assertEq(_otherStateHash(), other);
    }

    function test_RevertWhen_StrangerCancels() public {
        _proposeFees(FIXED, FIXED, 0, 1e6, 0);
        _expectUnauthorized(stranger, VAULT_GUARDIAN_ROLE);
        vm.prank(stranger);
        forwarder.cancelFeeConfigChange();
        assertTrue(_pendingFeeExecutableAt() != 0);
    }

    function test_CancelBeforeAtAndAfterMaturity() public {
        uint256[3] memory offsets = [uint256(0), 72 hours, 1000 days];
        for (uint256 i = 0; i < offsets.length; ++i) {
            _proposeFees(FIXED, FIXED, 0, 1e6, 0);
            vm.warp(block.timestamp + offsets[i]);
            vm.prank(guardian);
            forwarder.cancelFeeConfigChange();
            _assertNoPending();
        }
        assertEq(forwarder.fixedFee(), 0);
    }

    function test_RevertWhen_CancellingWithNothingPending() public {
        address[3] memory cancellers = [admin, guardian, feeManager];
        for (uint256 i = 0; i < cancellers.length; ++i) {
            vm.expectRevert(Forwarder.NoPendingFeeConfigChange.selector);
            vm.prank(cancellers[i]);
            forwarder.cancelFeeConfigChange();
        }
    }

    function test_CancelledChangeCannotBeExecuted() public {
        _proposeFees(FIXED, FIXED, 0, 1e6, 0);
        uint256 executableAt = _pendingFeeExecutableAt();
        vm.prank(guardian);
        forwarder.cancelFeeConfigChange();
        vm.warp(executableAt);
        vm.expectRevert(Forwarder.NoPendingFeeConfigChange.selector);
        vm.prank(feeManager);
        forwarder.executeFeeConfigChange();
        assertEq(forwarder.fixedFee(), 0);
    }

    function test_ProposeAgainAfterCancellationRestartsTheDelay() public {
        _proposeFees(FIXED, FIXED, 0, 1e6, 0);
        vm.warp(block.timestamp + 71 hours);
        vm.prank(feeManager);
        forwarder.cancelFeeConfigChange();
        _proposeFees(FIXED, FIXED, 0, 2e6, 0);
        uint256 executableAt = _pendingFeeExecutableAt();
        assertEq(executableAt, block.timestamp + 72 hours);
        vm.warp(block.timestamp + 1 hours);
        _expectTooEarly(executableAt);
        vm.prank(feeManager);
        forwarder.executeFeeConfigChange();
    }

    function test_ProposeAgainAfterExecution() public {
        _setFees(FIXED, FIXED, 0, 1e6, 0);
        _proposeFees(FIXED, FIXED, 0, 2e6, 0);
        assertEq(_pendingFeeExecutableAt(), block.timestamp + 72 hours);
        assertEq(forwarder.fixedFee(), 1e6);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Pause
    // -----------------------------------------------------------------------------------------------------------

    function test_PauseStaysImmediateWhileAChangeIsPending() public {
        _setFees(FIXED, FIXED, 0, 1e6, 0);
        _proposeFees(FIXED, FIXED, 0, 5e6, 0);
        vm.prank(feeManager);
        forwarder.pause();
        assertEq(forwarder.calculateFee(100e6), 0);
        assertTrue(_pendingFeeExecutableAt() != 0, "pause keeps the proposal");
        _forward(100e6, user);
        assertEq(usdc.balanceOf(user), 100e6);
    }

    function test_ProposeAndExecuteWhilePausedKeepsTheFeeAtZero() public {
        vm.prank(feeManager);
        forwarder.pause();
        _setFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, 2e6, 1000);
        _assertActive(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, 2e6, 1000);
        assertEq(forwarder.calculateFee(100e6), 0);
        assertEq(forwarder.calculateFeeFor(user, 100e6), 0);
        _forward(100e6, user);
        assertEq(usdc.balanceOf(user), 100e6);

        vm.prank(admin);
        forwarder.unpause();
        assertEq(forwarder.calculateFee(100e6), 3e6);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Regression: the 16 model combinations through the delayed lifecycle, with real forwards
    // -----------------------------------------------------------------------------------------------------------

    function test_AllSixteenCombinationsWithForward() public {
        Forwarder.FeeModel[4] memory models = [NONE, FIXED, PERCENT, FIXED_PLUS_PERCENT];
        uint256 thresholdValue = 500e6;
        uint256 fixedValue = 7e6;
        uint256 variableValue = 3333;
        uint256[3] memory amounts = [thresholdValue, thresholdValue + 1, 2000e6];
        uint256 treasuryTotal;
        uint256 userTotal;
        for (uint256 l = 0; l < 4; ++l) {
            for (uint256 u = 0; u < 4; ++u) {
                _setFees(models[l], models[u], thresholdValue, fixedValue, variableValue);
                for (uint256 a = 0; a < amounts.length; ++a) {
                    uint256 fee = _referenceFee(
                        models[l], models[u], thresholdValue, fixedValue, variableValue, false, amounts[a]
                    );
                    assertEq(forwarder.calculateFee(amounts[a]), fee);
                    assertEq(forwarder.calculateFeeFor(user, amounts[a]), fee);
                    _forward(amounts[a], user);
                    treasuryTotal += fee;
                    userTotal += amounts[a] - fee;
                    assertEq(usdc.balanceOf(treasury), treasuryTotal);
                    assertEq(usdc.balanceOf(user), userTotal);
                }
            }
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // No immediate path
    // -----------------------------------------------------------------------------------------------------------

    /// @dev The V2 immediate setters no longer exist: their selectors hit no function and revert.
    function test_V2ImmediateSettersAreGone() public {
        bytes[8] memory calls = [
            abi.encodeWithSignature("setFeeConfig(uint8,uint8,uint256,uint256,uint256)", 1, 1, 0, 1e6, 0),
            abi.encodeWithSignature("setVariableFee(uint256)", 1000),
            abi.encodeWithSignature("setFixedFee(uint256)", 1e6),
            abi.encodeWithSignature("setThreshold(uint256)", 1),
            abi.encodeWithSignature("setLowerFeeModel(uint8)", 1),
            abi.encodeWithSignature("setUpperFeeModel(uint8)", 1),
            abi.encodeWithSignature("setTreasury(address)", stranger),
            abi.encodeWithSignature("setVault(address)", address(vault))
        ];
        address[3] memory callers = [feeManager, admin, guardian];
        for (uint256 c = 0; c < callers.length; ++c) {
            for (uint256 i = 0; i < calls.length; ++i) {
                vm.prank(callers[c]);
                (bool success, bytes memory returnData) = address(forwarder).call(calls[i]);
                assertFalse(success);
                assertEq(returnData.length, 0);
            }
        }
        _assertActive(NONE, NONE, 0, 0, 0);
        assertEq(forwarder.treasury(), treasury);
    }
}
