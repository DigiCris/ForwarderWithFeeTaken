// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {stdError} from "forge-std/StdError.sol";

import {Forwarder} from "../src/Forwarder.sol";
import {ForwarderTestBase} from "./utils/ForwarderTestBase.sol";

/// @dev Per-recipient temporary fee overrides: `setUserFeeOverride`, `calculateFeeFor` and the fee charged by
/// `forward`.
contract ForwarderFeeOverrideTest is ForwarderTestBase {
    address internal vip = makeAddr("vip");

    // Spec example: global 1 USDC + 1%, override 0.20 USDC + 0.30%.
    uint256 internal constant GLOBAL_FIXED = 1e6;
    uint256 internal constant GLOBAL_VARIABLE = 1000;
    uint256 internal constant OVERRIDE_FIXED = 0.2e6;
    uint256 internal constant OVERRIDE_VARIABLE = 300;

    function _expectUnauthorized(address account, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role));
    }

    /// @dev Specification of the fee of a recipient with an active override: global models and threshold,
    /// min(override, global) as fixed and variable fee, zero while paused.
    function _expectedOverrideFee(uint256 overrideFixed, uint256 overrideVariable, uint256 amount)
        internal
        view
        returns (uint256)
    {
        uint256 globalFixed = forwarder.fixedFee();
        uint256 globalVariable = forwarder.variableFee();
        return _referenceFee(
            forwarder.lowerFeeModel(),
            forwarder.upperFeeModel(),
            forwarder.threshold(),
            overrideFixed < globalFixed ? overrideFixed : globalFixed,
            overrideVariable < globalVariable ? overrideVariable : globalVariable,
            forwarder.paused(),
            amount
        );
    }

    function _override(address recipient)
        internal
        view
        returns (uint256 overrideFixed, uint256 overrideVariable, uint256 validUntil)
    {
        return forwarder.userFeeOverrides(recipient);
    }

    function _globalConfigHash() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                forwarder.lowerFeeModel(),
                forwarder.upperFeeModel(),
                forwarder.threshold(),
                forwarder.fixedFee(),
                forwarder.variableFee(),
                forwarder.paused(),
                _pendingFeeExecutableAt()
            )
        );
    }

    // -----------------------------------------------------------------------------------------------------------
    // Fee calculation
    // -----------------------------------------------------------------------------------------------------------

    function test_NoOverrideIsExactlyTheGlobalFee() public {
        Forwarder.FeeModel[4] memory models = [NONE, FIXED, PERCENT, FIXED_PLUS_PERCENT];
        uint256[6] memory amounts = [uint256(0), 1, 99e6, 100e6, 100e6 + 1, 1_000_000e6];
        for (uint256 l = 0; l < 4; ++l) {
            for (uint256 u = 0; u < 4; ++u) {
                _setFees(models[l], models[u], 100e6, 3e6, 777);
                for (uint256 a = 0; a < amounts.length; ++a) {
                    assertEq(forwarder.calculateFeeFor(user, amounts[a]), forwarder.calculateFee(amounts[a]));
                    assertEq(forwarder.calculateFeeFor(vip, amounts[a]), forwarder.calculateFee(amounts[a]));
                }
            }
        }
    }

    function test_OverrideLowersTheFixedFee() public {
        _setFees(FIXED, FIXED, 0, GLOBAL_FIXED, GLOBAL_VARIABLE);
        _setOverride(vip, OVERRIDE_FIXED, OVERRIDE_VARIABLE, block.timestamp + 30 days);
        assertEq(forwarder.calculateFeeFor(vip, 1000e6), OVERRIDE_FIXED);
        assertEq(forwarder.calculateFeeFor(user, 1000e6), GLOBAL_FIXED);
    }

    function test_OverrideLowersThePercentFee() public {
        _setFees(PERCENT, PERCENT, 0, GLOBAL_FIXED, GLOBAL_VARIABLE);
        _setOverride(vip, OVERRIDE_FIXED, OVERRIDE_VARIABLE, block.timestamp + 30 days);
        assertEq(forwarder.calculateFeeFor(vip, 1000e6), 3e6); // 0.3% of 1,000
        assertEq(forwarder.calculateFeeFor(user, 1000e6), 10e6);
        assertEq(forwarder.calculateFeeFor(vip, 333), 0); // rounds down like the global fee
    }

    function test_OverrideLowersFixedPlusPercent() public {
        _setFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, GLOBAL_FIXED, GLOBAL_VARIABLE);
        _setOverride(vip, OVERRIDE_FIXED, OVERRIDE_VARIABLE, block.timestamp + 30 days);
        assertEq(forwarder.calculateFeeFor(vip, 1000e6), 0.2e6 + 3e6);
        assertEq(forwarder.calculateFeeFor(user, 1000e6), 1e6 + 10e6);
    }

    function test_OverrideUsesTheGlobalLowerAndUpperModels() public {
        // <= 100 USDC: FIXED; > 100 USDC: PERCENT. The override never changes which model applies.
        _setFees(FIXED, PERCENT, 100e6, GLOBAL_FIXED, GLOBAL_VARIABLE);
        _setOverride(vip, OVERRIDE_FIXED, OVERRIDE_VARIABLE, block.timestamp + 30 days);
        assertEq(forwarder.calculateFeeFor(vip, 50e6), OVERRIDE_FIXED, "lower model");
        assertEq(forwarder.calculateFeeFor(vip, 100e6), OVERRIDE_FIXED, "exact threshold uses the lower model");
        assertEq(forwarder.calculateFeeFor(vip, 100e6 + 1), uint256(100e6 + 1) * 300 / 100_000, "upper model");
        assertEq(forwarder.calculateFeeFor(vip, 1000e6), 3e6, "upper model on the full amount");
        assertEq(forwarder.threshold(), 100e6);
        assertEq(uint8(forwarder.lowerFeeModel()), uint8(FIXED));
        assertEq(uint8(forwarder.upperFeeModel()), uint8(PERCENT));
    }

    function test_OverrideWithModelNoneIsZero() public {
        _setFees(NONE, FIXED_PLUS_PERCENT, 100e6, GLOBAL_FIXED, GLOBAL_VARIABLE);
        _setOverride(vip, OVERRIDE_FIXED, OVERRIDE_VARIABLE, block.timestamp + 30 days);
        assertEq(forwarder.calculateFeeFor(vip, 100e6), 0);
        assertEq(forwarder.calculateFeeFor(vip, 200e6), 0.2e6 + 0.6e6);
    }

    function test_ZeroOverride() public {
        Forwarder.FeeModel[4] memory models = [NONE, FIXED, PERCENT, FIXED_PLUS_PERCENT];
        _setOverride(vip, 0, 0, MAX);
        for (uint256 m = 0; m < 4; ++m) {
            _setFees(models[m], models[m], 0, 10e6, 10_000);
            assertEq(forwarder.calculateFeeFor(vip, 1_000_000e6), 0);
            assertEq(forwarder.calculateFeeFor(user, 1_000_000e6), forwarder.calculateFee(1_000_000e6));
        }
    }

    function test_OverrideEqualToTheGlobalFeeIsAllowed() public {
        _setFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, GLOBAL_FIXED, GLOBAL_VARIABLE);
        _setOverride(vip, GLOBAL_FIXED, GLOBAL_VARIABLE, block.timestamp + 1 days);
        assertEq(forwarder.calculateFeeFor(vip, 1000e6), forwarder.calculateFee(1000e6));
    }

    function test_OverrideIsActiveOneSecondBeforeValidUntil() public {
        _setFees(FIXED, FIXED, 0, GLOBAL_FIXED, GLOBAL_VARIABLE);
        uint256 validUntil = block.timestamp + 7 days;
        _setOverride(vip, OVERRIDE_FIXED, OVERRIDE_VARIABLE, validUntil);
        vm.warp(validUntil - 1);
        assertEq(forwarder.calculateFeeFor(vip, 10e6), OVERRIDE_FIXED);
    }

    function test_OverrideExpiresExactlyAtValidUntil() public {
        _setFees(FIXED, FIXED, 0, GLOBAL_FIXED, GLOBAL_VARIABLE);
        uint256 validUntil = block.timestamp + 7 days;
        _setOverride(vip, OVERRIDE_FIXED, OVERRIDE_VARIABLE, validUntil);
        vm.warp(validUntil);
        assertEq(forwarder.calculateFeeFor(vip, 10e6), GLOBAL_FIXED);
        assertEq(forwarder.calculateFeeFor(vip, 10e6), forwarder.calculateFee(10e6));
        // The expired entry stays in storage and is ignored.
        (uint256 overrideFixed,, uint256 storedValidUntil) = _override(vip);
        assertEq(overrideFixed, OVERRIDE_FIXED);
        assertEq(storedValidUntil, validUntil);
    }

    function test_ExpiredOverrideUsesTheGlobalFee() public {
        _setFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, GLOBAL_FIXED, GLOBAL_VARIABLE);
        _setOverride(vip, 0, 0, block.timestamp + 1 days);
        vm.warp(block.timestamp + 400 days);
        uint256[4] memory amounts = [uint256(0), 1, 100e6, 1_000_000e6];
        for (uint256 a = 0; a < amounts.length; ++a) {
            assertEq(forwarder.calculateFeeFor(vip, amounts[a]), forwarder.calculateFee(amounts[a]));
        }
    }

    function test_PausedFeeIsZeroWithOverride() public {
        _setFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, GLOBAL_FIXED, GLOBAL_VARIABLE);
        _setOverride(vip, OVERRIDE_FIXED, OVERRIDE_VARIABLE, block.timestamp + 30 days);
        vm.prank(feeManager);
        forwarder.pause();
        assertEq(forwarder.calculateFeeFor(vip, 1000e6), 0);
        assertEq(forwarder.calculateFeeFor(user, 1000e6), 0);
        _forward(1000e6, vip);
        assertEq(usdc.balanceOf(vip), 1000e6);
        assertEq(usdc.balanceOf(treasury), 0);

        vm.prank(admin);
        forwarder.unpause();
        assertEq(forwarder.calculateFeeFor(vip, 1000e6), 3.2e6);
    }

    /// @dev Spec example: the global fee drops below the override, then rises again while the override is active.
    function test_TheUserNeverPaysMoreThanTheCurrentGlobalFee() public {
        _setFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, GLOBAL_FIXED, GLOBAL_VARIABLE);
        _setOverride(vip, OVERRIDE_FIXED, OVERRIDE_VARIABLE, block.timestamp + 365 days);
        assertEq(forwarder.calculateFeeFor(vip, 1000e6), 0.2e6 + 3e6);

        // Global drops to 0.10 USDC + 0.20%: the user pays the lower global values.
        _setFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, 0.1e6, 200);
        assertEq(forwarder.calculateFeeFor(vip, 1000e6), 0.1e6 + 2e6);
        assertEq(forwarder.calculateFeeFor(vip, 1000e6), forwarder.calculateFee(1000e6));

        // Global goes back up to 1 USDC + 1%: the active override limits the user again to 0.20 USDC + 0.30%.
        _setFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, GLOBAL_FIXED, GLOBAL_VARIABLE);
        assertEq(forwarder.calculateFeeFor(vip, 1000e6), 0.2e6 + 3e6);

        // Mixed: global fixed below the override, global variable above it.
        _setFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, 0.05e6, 5000);
        assertEq(forwarder.calculateFeeFor(vip, 1000e6), 0.05e6 + 3e6);
        assertLe(forwarder.calculateFeeFor(vip, 1000e6), forwarder.calculateFee(1000e6));
    }

    // -----------------------------------------------------------------------------------------------------------
    // Creation and validation
    // -----------------------------------------------------------------------------------------------------------

    function test_SetOverrideStoresAndEmits() public {
        _setFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, GLOBAL_FIXED, GLOBAL_VARIABLE);
        uint256 validUntil = block.timestamp + 30 days;
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.UserFeeOverrideSet(vip, OVERRIDE_FIXED, OVERRIDE_VARIABLE, validUntil, feeManager);
        _setOverride(vip, OVERRIDE_FIXED, OVERRIDE_VARIABLE, validUntil);
        (uint256 overrideFixed, uint256 overrideVariable, uint256 storedValidUntil) = _override(vip);
        assertEq(overrideFixed, OVERRIDE_FIXED);
        assertEq(overrideVariable, OVERRIDE_VARIABLE);
        assertEq(storedValidUntil, validUntil);
    }

    function test_OverrideDoesNotChangeTheGlobalConfiguration() public {
        _setFees(FIXED, PERCENT, 100e6, GLOBAL_FIXED, GLOBAL_VARIABLE);
        _proposeFees(PERCENT, FIXED, 7, 8, 9);
        bytes32 config = _globalConfigHash();
        _setOverride(vip, 0, 0, block.timestamp + 30 days);
        assertEq(_globalConfigHash(), config);
    }

    function test_OverrideOnlyAffectsItsRecipient() public {
        _setFees(FIXED, FIXED, 0, GLOBAL_FIXED, 0);
        _setOverride(vip, 0, 0, block.timestamp + 30 days);
        assertEq(forwarder.calculateFeeFor(vip, 10e6), 0);
        assertEq(forwarder.calculateFeeFor(user, 10e6), GLOBAL_FIXED);
        assertEq(forwarder.calculateFeeFor(address(0), 10e6), GLOBAL_FIXED);
        assertEq(forwarder.calculateFee(10e6), GLOBAL_FIXED);
    }

    function test_RevertWhen_OverrideAboveTheGlobalFee() public {
        _setFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, GLOBAL_FIXED, GLOBAL_VARIABLE);
        uint256 validUntil = block.timestamp + 1 days;
        vm.startPrank(feeManager);
        vm.expectRevert(
            abi.encodeWithSelector(Forwarder.FeeOverrideAboveGlobalFee.selector, GLOBAL_FIXED + 1, GLOBAL_VARIABLE)
        );
        forwarder.setUserFeeOverride(vip, GLOBAL_FIXED + 1, GLOBAL_VARIABLE, validUntil);
        vm.expectRevert(
            abi.encodeWithSelector(Forwarder.FeeOverrideAboveGlobalFee.selector, GLOBAL_FIXED, GLOBAL_VARIABLE + 1)
        );
        forwarder.setUserFeeOverride(vip, GLOBAL_FIXED, GLOBAL_VARIABLE + 1, validUntil);
        vm.stopPrank();
        (,, uint256 storedValidUntil) = _override(vip);
        assertEq(storedValidUntil, 0);
    }

    function test_RevertWhen_OverrideWithGlobalFeesAtZero() public {
        vm.expectRevert(abi.encodeWithSelector(Forwarder.FeeOverrideAboveGlobalFee.selector, 1, 0));
        _setOverride(vip, 1, 0, block.timestamp + 1 days);
        _setOverride(vip, 0, 0, block.timestamp + 1 days);
    }

    /// @dev The comparison uses the active configuration, never a pending proposal.
    function test_ValidationUsesTheActiveConfiguration() public {
        _setFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, GLOBAL_FIXED, GLOBAL_VARIABLE);
        _proposeFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, 10e6, 10_000); // pending higher
        vm.expectRevert(
            abi.encodeWithSelector(Forwarder.FeeOverrideAboveGlobalFee.selector, GLOBAL_FIXED + 1, GLOBAL_VARIABLE)
        );
        _setOverride(vip, GLOBAL_FIXED + 1, GLOBAL_VARIABLE, block.timestamp + 1 days);

        vm.prank(feeManager);
        forwarder.cancelFeeConfigChange();
        _proposeFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, 0, 0); // pending lower
        _setOverride(vip, GLOBAL_FIXED, GLOBAL_VARIABLE, block.timestamp + 1 days);
    }

    function test_RevertWhen_ValidUntilIsNotInTheFuture() public {
        vm.expectRevert(abi.encodeWithSelector(Forwarder.FeeOverrideExpiryNotInFuture.selector, block.timestamp));
        _setOverride(vip, 0, 0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(Forwarder.FeeOverrideExpiryNotInFuture.selector, block.timestamp - 1));
        _setOverride(vip, 0, 0, block.timestamp - 1);
        vm.expectRevert(abi.encodeWithSelector(Forwarder.FeeOverrideExpiryNotInFuture.selector, 0));
        _setOverride(vip, 0, 0, 0);
        _setOverride(vip, 0, 0, block.timestamp + 1);
    }

    function test_RevertWhen_RecipientIsZero() public {
        vm.expectRevert(Forwarder.ZeroAddress.selector);
        _setOverride(address(0), 0, 0, block.timestamp + 1 days);
    }

    function test_RevertWhen_NotAFeeManager() public {
        address[3] memory callers = [admin, guardian, stranger];
        for (uint256 i = 0; i < callers.length; ++i) {
            _expectUnauthorized(callers[i], FEE_MANAGER_ROLE);
            vm.prank(callers[i]);
            forwarder.setUserFeeOverride(vip, 0, 0, block.timestamp + 1 days);
        }
        (,, uint256 validUntil) = _override(vip);
        assertEq(validUntil, 0);
    }

    function test_AnyFeeManagerCanSetAndImproveAnOverride() public {
        _setFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, GLOBAL_FIXED, GLOBAL_VARIABLE);
        _setOverride(vip, OVERRIDE_FIXED, OVERRIDE_VARIABLE, block.timestamp + 1 days);
        vm.prank(feeManager2);
        forwarder.setUserFeeOverride(vip, 0, OVERRIDE_VARIABLE, block.timestamp + 2 days);
        (uint256 overrideFixed,, uint256 validUntil) = _override(vip);
        assertEq(overrideFixed, 0);
        assertEq(validUntil, block.timestamp + 2 days);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Guarantee while active: never worse before `validUntil`
    // -----------------------------------------------------------------------------------------------------------

    function _activeVip() internal returns (uint256 validUntil) {
        _setFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, GLOBAL_FIXED, GLOBAL_VARIABLE);
        validUntil = block.timestamp + 30 days;
        _setOverride(vip, OVERRIDE_FIXED, OVERRIDE_VARIABLE, validUntil);
    }

    function test_RevertWhen_RaisingTheFixedFeeOfAnActiveOverride() public {
        uint256 validUntil = _activeVip();
        vm.expectRevert(abi.encodeWithSelector(Forwarder.ActiveFeeOverrideWorsened.selector, vip));
        _setOverride(vip, OVERRIDE_FIXED + 1, OVERRIDE_VARIABLE, validUntil);
        vm.expectRevert(abi.encodeWithSelector(Forwarder.ActiveFeeOverrideWorsened.selector, vip));
        _setOverride(vip, OVERRIDE_FIXED + 1, 0, validUntil + 365 days); // not even with other improvements
        (uint256 overrideFixed,,) = _override(vip);
        assertEq(overrideFixed, OVERRIDE_FIXED);
    }

    function test_RevertWhen_RaisingTheVariableFeeOfAnActiveOverride() public {
        uint256 validUntil = _activeVip();
        vm.expectRevert(abi.encodeWithSelector(Forwarder.ActiveFeeOverrideWorsened.selector, vip));
        _setOverride(vip, OVERRIDE_FIXED, OVERRIDE_VARIABLE + 1, validUntil);
        vm.expectRevert(abi.encodeWithSelector(Forwarder.ActiveFeeOverrideWorsened.selector, vip));
        _setOverride(vip, 0, OVERRIDE_VARIABLE + 1, validUntil + 365 days);
        (, uint256 overrideVariable,) = _override(vip);
        assertEq(overrideVariable, OVERRIDE_VARIABLE);
    }

    function test_RevertWhen_ShorteningAnActiveOverride() public {
        uint256 validUntil = _activeVip();
        vm.expectRevert(abi.encodeWithSelector(Forwarder.ActiveFeeOverrideWorsened.selector, vip));
        _setOverride(vip, OVERRIDE_FIXED, OVERRIDE_VARIABLE, validUntil - 1);
        // An attempt to "remove" it early (shortest possible expiry, even with lower fees) is also rejected.
        vm.expectRevert(abi.encodeWithSelector(Forwarder.ActiveFeeOverrideWorsened.selector, vip));
        _setOverride(vip, 0, 0, block.timestamp + 1);
        (,, uint256 storedValidUntil) = _override(vip);
        assertEq(storedValidUntil, validUntil);
    }

    /// @dev The guarantee holds until the last active second.
    function test_RevertWhen_WorseningOneSecondBeforeExpiry() public {
        uint256 validUntil = _activeVip();
        vm.warp(validUntil - 1);
        vm.expectRevert(abi.encodeWithSelector(Forwarder.ActiveFeeOverrideWorsened.selector, vip));
        _setOverride(vip, GLOBAL_FIXED, GLOBAL_VARIABLE, validUntil);
    }

    function test_LoweringAnActiveOverride() public {
        uint256 validUntil = _activeVip();
        _setOverride(vip, OVERRIDE_FIXED - 1, OVERRIDE_VARIABLE, validUntil);
        _setOverride(vip, OVERRIDE_FIXED - 1, OVERRIDE_VARIABLE - 1, validUntil);
        _setOverride(vip, 0, 0, validUntil);
        (uint256 overrideFixed, uint256 overrideVariable, uint256 storedValidUntil) = _override(vip);
        assertEq(overrideFixed, 0);
        assertEq(overrideVariable, 0);
        assertEq(storedValidUntil, validUntil);
    }

    function test_ExtendingAnActiveOverride() public {
        uint256 validUntil = _activeVip();
        _setOverride(vip, OVERRIDE_FIXED, OVERRIDE_VARIABLE, validUntil + 1);
        _setOverride(vip, OVERRIDE_FIXED, OVERRIDE_VARIABLE, MAX);
        (,, uint256 storedValidUntil) = _override(vip);
        assertEq(storedValidUntil, MAX);
        vm.warp(block.timestamp + 100 * 365 days);
        assertEq(forwarder.calculateFeeFor(vip, 1000e6), 3.2e6);
    }

    function test_SettingTheSameActiveOverrideAgain() public {
        uint256 validUntil = _activeVip();
        _setOverride(vip, OVERRIDE_FIXED, OVERRIDE_VARIABLE, validUntil);
        (uint256 overrideFixed, uint256 overrideVariable, uint256 storedValidUntil) = _override(vip);
        assertEq(overrideFixed, OVERRIDE_FIXED);
        assertEq(overrideVariable, OVERRIDE_VARIABLE);
        assertEq(storedValidUntil, validUntil);
    }

    /// @dev After the global fee drops below an active override, extending it requires lowering it to the global
    /// values (never a worse override for the user).
    function test_ExtendingWhileTheGlobalFeeIsBelowTheOverride() public {
        uint256 validUntil = _activeVip();
        _setFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, 0.1e6, 200);
        vm.expectRevert(
            abi.encodeWithSelector(Forwarder.FeeOverrideAboveGlobalFee.selector, OVERRIDE_FIXED, OVERRIDE_VARIABLE)
        );
        _setOverride(vip, OVERRIDE_FIXED, OVERRIDE_VARIABLE, validUntil + 30 days);
        _setOverride(vip, 0.1e6, 200, validUntil + 30 days);
        (uint256 overrideFixed, uint256 overrideVariable,) = _override(vip);
        assertEq(overrideFixed, 0.1e6);
        assertEq(overrideVariable, 200);
    }

    function test_ReplacingAnExpiredOverrideFreely() public {
        uint256 validUntil = _activeVip();
        vm.warp(validUntil);
        // Higher fees and a shorter expiry than the old entry are accepted once it has expired.
        _setOverride(vip, GLOBAL_FIXED, GLOBAL_VARIABLE, validUntil + 1);
        (uint256 overrideFixed, uint256 overrideVariable, uint256 storedValidUntil) = _override(vip);
        assertEq(overrideFixed, GLOBAL_FIXED);
        assertEq(overrideVariable, GLOBAL_VARIABLE);
        assertEq(storedValidUntil, validUntil + 1);
    }

    function test_ActiveOverrideSurvivesGlobalChangesAndPause() public {
        uint256 validUntil = _activeVip();
        _setFees(FIXED, FIXED, 0, 5e6, 0);
        vm.prank(feeManager);
        forwarder.pause();
        vm.prank(admin);
        forwarder.unpause();
        (uint256 overrideFixed, uint256 overrideVariable, uint256 storedValidUntil) = _override(vip);
        assertEq(overrideFixed, OVERRIDE_FIXED);
        assertEq(overrideVariable, OVERRIDE_VARIABLE);
        assertEq(storedValidUntil, validUntil);
        assertEq(forwarder.calculateFeeFor(vip, 1000e6), OVERRIDE_FIXED);
    }

    // -----------------------------------------------------------------------------------------------------------
    // forward regression
    // -----------------------------------------------------------------------------------------------------------

    function test_ForwardWithoutOverrideChargesTheGlobalFeeInEveryMode() public {
        _setFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, GLOBAL_FIXED, GLOBAL_VARIABLE);
        _forwardInEveryMode(user, 11e6);
    }

    function test_ForwardWithOverrideChargesTheDiscountedFeeInEveryMode() public {
        _setFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, GLOBAL_FIXED, GLOBAL_VARIABLE);
        _setOverride(vip, OVERRIDE_FIXED, OVERRIDE_VARIABLE, block.timestamp + 30 days);
        _forwardInEveryMode(vip, 3.2e6);
    }

    /// @dev amount = userAmount + fee in every routing mode; the user and the treasury receive exactly their part.
    function _forwardInEveryMode(address recipient, uint256 expectedFee) internal {
        uint256 amount = 1000e6;
        Forwarder.RoutingMode[4] memory modes =
            [DIRECT_DIRECT, VAULT_USER_DIRECT_TREASURY, DIRECT_USER_VAULT_TREASURY, VAULT_VAULT];
        uint256 userValue;
        uint256 treasuryValue;
        for (uint256 i = 0; i < modes.length; ++i) {
            _setRouting(modes[i]);
            assertEq(forwarder.calculateFeeFor(recipient, amount), expectedFee);
            _fundSra(amount);
            bool userVault = _userUsesVault(modes[i]);
            vm.expectEmit(true, true, true, true, address(forwarder));
            emit Forwarder.Forwarded(
                sra,
                recipient,
                amount,
                expectedFee,
                amount - expectedFee,
                userVault,
                userVault ? (amount - expectedFee) * 1e12 : 0
            );
            vm.prank(sra);
            forwarder.forward(address(usdc), amount, recipient);
            userValue += amount - expectedFee;
            treasuryValue += expectedFee;
            assertEq(usdc.balanceOf(recipient) + vault.balanceOf(recipient) / 1e12, userValue, "user");
            assertEq(usdc.balanceOf(treasury) + vault.balanceOf(treasury) / 1e12, treasuryValue, "treasury");
            assertEq(usdc.balanceOf(address(forwarder)), 0);
            assertEq(vault.balanceOf(address(forwarder)), 0);
        }
        assertEq(usdc.balanceOf(recipient), 2 * (amount - expectedFee), "USDC in the DIRECT user modes");
        assertEq(vault.balanceOf(recipient) / 1e12, 2 * (amount - expectedFee), "shares in the VAULT user modes");
        assertEq(usdc.balanceOf(treasury), 2 * expectedFee, "USDC in the DIRECT treasury modes");
        assertEq(vault.balanceOf(treasury) / 1e12, 2 * expectedFee, "shares in the VAULT treasury modes");
    }

    function test_ForwardedEventReportsTheEffectiveFee() public {
        _setFees(FIXED, FIXED, 0, GLOBAL_FIXED, 0);
        _setOverride(vip, OVERRIDE_FIXED, 0, block.timestamp + 1 days);
        _fundSra(10e6);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.Forwarded(sra, vip, 10e6, OVERRIDE_FIXED, 10e6 - OVERRIDE_FIXED, false, 0);
        vm.prank(sra);
        forwarder.forward(address(usdc), 10e6, vip);
    }

    function test_TreasuryBestEffortWithOverride() public {
        _setFees(FIXED, FIXED, 0, GLOBAL_FIXED, 0);
        _setOverride(vip, OVERRIDE_FIXED, 0, block.timestamp + 30 days);
        usdc.setBlacklisted(treasury, true);
        _forward(10e6, vip);
        assertEq(usdc.balanceOf(vip), 10e6 - OVERRIDE_FIXED);
        assertEq(usdc.balanceOf(address(forwarder)), OVERRIDE_FIXED, "discounted fee kept for the retry");

        usdc.setBlacklisted(treasury, false);
        _forward(10e6, user);
        assertEq(usdc.balanceOf(treasury), OVERRIDE_FIXED + GLOBAL_FIXED);
        assertEq(usdc.balanceOf(address(forwarder)), 0);
    }

    function test_UserVaultFallbackWithOverride() public {
        _setFees(FIXED, FIXED, 0, GLOBAL_FIXED, 0);
        _setOverride(vip, OVERRIDE_FIXED, 0, block.timestamp + 30 days);
        _setRouting(VAULT_VAULT);
        vault.setDepositReverts(true);
        _forward(10e6, vip);
        assertEq(usdc.balanceOf(vip), 10e6 - OVERRIDE_FIXED, "fallback delivers amount - discounted fee in USDC");
        assertEq(vault.balanceOf(vip), 0);
        assertEq(usdc.balanceOf(address(forwarder)), OVERRIDE_FIXED);
    }

    function test_ExpiredOverrideForwardChargesTheGlobalFee() public {
        _setFees(FIXED, FIXED, 0, GLOBAL_FIXED, 0);
        _setOverride(vip, 0, 0, block.timestamp + 1 days);
        vm.warp(block.timestamp + 1 days);
        _forward(10e6, vip);
        assertEq(usdc.balanceOf(vip), 10e6 - GLOBAL_FIXED);
        assertEq(usdc.balanceOf(treasury), GLOBAL_FIXED);
    }

    /// @dev A fee above the amount reverts the global path (checked arithmetic, unchanged); a lower override can make
    /// the same deposit go through.
    function test_OverrideCanMakeASmallDepositPossible() public {
        _setFees(FIXED, FIXED, 0, 5e6, 0);
        _fundSra(1e6);
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(sra);
        forwarder.forward(address(usdc), 1e6, user);

        _setOverride(vip, 0.5e6, 0, block.timestamp + 1 days);
        vm.prank(sra);
        forwarder.forward(address(usdc), 1e6, vip);
        assertEq(usdc.balanceOf(vip), 0.5e6);
        assertEq(usdc.balanceOf(treasury), 0.5e6);
    }

    function test_ExpectedOverrideFeeMatchesForEveryModelPair() public {
        Forwarder.FeeModel[4] memory models = [NONE, FIXED, PERCENT, FIXED_PLUS_PERCENT];
        uint256[5] memory amounts = [uint256(0), 1, 500e6, 500e6 + 1, 3000e6];
        _setOverride(vip, 0, 0, MAX); // set while the global fee is zero; later global changes never raise it
        for (uint256 l = 0; l < 4; ++l) {
            for (uint256 u = 0; u < 4; ++u) {
                _setFees(models[l], models[u], 500e6, 7e6, 3333);
                for (uint256 a = 0; a < amounts.length; ++a) {
                    assertEq(forwarder.calculateFeeFor(vip, amounts[a]), _expectedOverrideFee(0, 0, amounts[a]));
                    assertEq(forwarder.calculateFeeFor(vip, amounts[a]), 0);
                }
            }
        }
        address vip2 = makeAddr("vip2");
        _setOverride(vip2, 2e6, 1000, MAX);
        for (uint256 l = 0; l < 4; ++l) {
            for (uint256 u = 0; u < 4; ++u) {
                _setFees(models[l], models[u], 500e6, 7e6, 3333);
                for (uint256 a = 0; a < amounts.length; ++a) {
                    uint256 expected = _expectedOverrideFee(2e6, 1000, amounts[a]);
                    assertEq(forwarder.calculateFeeFor(vip2, amounts[a]), expected);
                    assertLe(expected, forwarder.calculateFee(amounts[a]));
                }
            }
        }
    }
}
