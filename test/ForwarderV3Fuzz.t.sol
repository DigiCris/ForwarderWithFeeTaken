// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Forwarder} from "../src/Forwarder.sol";
import {ForwarderTestBase} from "./utils/ForwarderTestBase.sol";

/// @dev Fuzz tests of the V3 additions: delayed fee configuration and treasury changes, per-recipient fee overrides
/// and the `forward` accounting with the effective fee.
contract ForwarderV3FuzzTest is ForwarderTestBase {
    struct Config {
        uint8 lower;
        uint8 upper;
        uint256 threshold;
        uint256 fixedFee;
        uint256 variableFee;
    }

    address internal vip = makeAddr("vip");

    function _bound(Config memory c) internal pure returns (Config memory) {
        c.lower = c.lower % 4;
        c.upper = c.upper % 4;
        c.threshold = c.threshold % 1e15;
        c.fixedFee = c.fixedFee % (10e6 + 1);
        c.variableFee = c.variableFee % (10_000 + 1);
        return c;
    }

    function _apply(Config memory c) internal {
        _setFees(Forwarder.FeeModel(c.lower), Forwarder.FeeModel(c.upper), c.threshold, c.fixedFee, c.variableFee);
    }

    /// @dev Reference fee of a recipient: global models and threshold, min(override, global) when the override is
    /// active, zero while paused.
    function _reference(address recipient, uint256 amount) internal view returns (uint256) {
        (uint256 overrideFixed, uint256 overrideVariable, uint256 validUntil) = forwarder.userFeeOverrides(recipient);
        uint256 fixedValue = forwarder.fixedFee();
        uint256 variableValue = forwarder.variableFee();
        if (block.timestamp < validUntil) {
            if (overrideFixed < fixedValue) fixedValue = overrideFixed;
            if (overrideVariable < variableValue) variableValue = overrideVariable;
        }
        return _referenceFee(
            forwarder.lowerFeeModel(),
            forwarder.upperFeeModel(),
            forwarder.threshold(),
            fixedValue,
            variableValue,
            forwarder.paused(),
            amount
        );
    }

    // -----------------------------------------------------------------------------------------------------------
    // Overrides
    // -----------------------------------------------------------------------------------------------------------

    function testFuzz_WithoutOverrideTheFeeIsTheGlobalFee(Config memory c, address recipient, uint256 amount) public {
        _apply(_bound(c));
        amount = bound(amount, 0, type(uint128).max);
        assertEq(forwarder.calculateFeeFor(recipient, amount), forwarder.calculateFee(amount));
    }

    /// @dev Central property: with an active override the fee never exceeds the current global fee, whatever the
    /// global configuration becomes afterwards, and it always matches the specification.
    function testFuzz_ActiveOverrideNeverExceedsTheGlobalFee(
        Config memory atCreation,
        Config memory later,
        uint256 overrideFixed,
        uint256 overrideVariable,
        uint256 amount,
        bool paused
    ) public {
        atCreation = _bound(atCreation);
        _apply(atCreation);
        overrideFixed = bound(overrideFixed, 0, atCreation.fixedFee);
        overrideVariable = bound(overrideVariable, 0, atCreation.variableFee);
        _setOverride(vip, overrideFixed, overrideVariable, MAX);
        _apply(_bound(later));
        if (paused) {
            vm.prank(feeManager);
            forwarder.pause();
        }
        amount = bound(amount, 0, type(uint128).max);
        uint256 fee = forwarder.calculateFeeFor(vip, amount);
        assertLe(fee, forwarder.calculateFee(amount));
        assertEq(fee, _reference(vip, amount));
        if (paused) assertEq(fee, 0);
    }

    function testFuzz_ExpiredOverrideIsTheGlobalFee(
        Config memory c,
        uint256 overrideFixed,
        uint256 overrideVariable,
        uint256 duration,
        uint256 afterExpiry,
        uint256 amount
    ) public {
        c = _bound(c);
        _apply(c);
        duration = bound(duration, 1, 10 * 365 days);
        uint256 validUntil = block.timestamp + duration;
        _setOverride(vip, bound(overrideFixed, 0, c.fixedFee), bound(overrideVariable, 0, c.variableFee), validUntil);
        vm.warp(validUntil + bound(afterExpiry, 0, 10 * 365 days));
        amount = bound(amount, 0, type(uint128).max);
        assertEq(forwarder.calculateFeeFor(vip, amount), forwarder.calculateFee(amount));
    }

    /// @dev Exact acceptance rule of `setUserFeeOverride` for a second override after an arbitrary time.
    function testFuzz_OverrideUpdateRule(
        uint256 firstFixed,
        uint256 firstVariable,
        uint256 firstDuration,
        uint256 nextFixed,
        uint256 nextVariable,
        uint256 nextValidUntil,
        uint256 elapsed
    ) public {
        _setFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, 5e6, 5000);
        firstFixed = bound(firstFixed, 0, 5e6);
        firstVariable = bound(firstVariable, 0, 5000);
        uint256 firstValidUntil = block.timestamp + bound(firstDuration, 1, 365 days);
        _setOverride(vip, firstFixed, firstVariable, firstValidUntil);

        vm.warp(block.timestamp + bound(elapsed, 0, 400 days));
        nextFixed = bound(nextFixed, 0, 6e6);
        nextVariable = bound(nextVariable, 0, 6000);
        nextValidUntil = bound(nextValidUntil, block.timestamp - 1, block.timestamp + 800 days);

        bool active = block.timestamp < firstValidUntil;
        bool accepted = nextValidUntil > block.timestamp && nextFixed <= 5e6 && nextVariable <= 5000
            && (!active
                || (nextFixed <= firstFixed && nextVariable <= firstVariable && nextValidUntil >= firstValidUntil));

        vm.prank(feeManager);
        (bool success,) = address(forwarder)
            .call(abi.encodeCall(Forwarder.setUserFeeOverride, (vip, nextFixed, nextVariable, nextValidUntil)));
        assertEq(success, accepted);

        (uint256 storedFixed, uint256 storedVariable, uint256 storedValidUntil) = forwarder.userFeeOverrides(vip);
        if (accepted) {
            assertEq(storedFixed, nextFixed);
            assertEq(storedVariable, nextVariable);
            assertEq(storedValidUntil, nextValidUntil);
        } else {
            assertEq(storedFixed, firstFixed);
            assertEq(storedVariable, firstVariable);
            assertEq(storedValidUntil, firstValidUntil);
        }
        if (active) {
            // Whatever happened, the promised maximum still holds until the original `validUntil`.
            assertLe(storedFixed, firstFixed);
            assertLe(storedVariable, firstVariable);
            assertGe(storedValidUntil, firstValidUntil);
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Delays
    // -----------------------------------------------------------------------------------------------------------

    function testFuzz_FeeConfigChangesOnlyAfterTheDelay(Config memory current, Config memory next, uint256 elapsed)
        public
    {
        current = _bound(current);
        next = _bound(next);
        _apply(current);
        _proposeFees(
            Forwarder.FeeModel(next.lower),
            Forwarder.FeeModel(next.upper),
            next.threshold,
            next.fixedFee,
            next.variableFee
        );
        uint256 proposedAt = block.timestamp;
        elapsed = bound(elapsed, 0, 2 * FEE_CHANGE_DELAY);
        vm.warp(proposedAt + elapsed);

        vm.prank(feeManager);
        (bool success,) = address(forwarder).call(abi.encodeCall(Forwarder.executeFeeConfigChange, ()));
        assertEq(success, elapsed >= FEE_CHANGE_DELAY);
        Config memory active = success ? next : current;
        assertEq(uint8(forwarder.lowerFeeModel()), active.lower);
        assertEq(uint8(forwarder.upperFeeModel()), active.upper);
        assertEq(forwarder.threshold(), active.threshold);
        assertEq(forwarder.fixedFee(), active.fixedFee);
        assertEq(forwarder.variableFee(), active.variableFee);
        assertEq(_pendingFeeExecutableAt(), success ? 0 : proposedAt + FEE_CHANGE_DELAY);
    }

    function testFuzz_TreasuryChangesOnlyAfterTheDelay(address candidate, uint256 elapsed) public {
        vm.assume(candidate != address(0) && candidate != address(forwarder));
        vm.prank(admin);
        forwarder.proposeTreasury(candidate);
        uint256 proposedAt = block.timestamp;
        elapsed = bound(elapsed, 0, 2 * TREASURY_CHANGE_DELAY);
        vm.warp(proposedAt + elapsed);

        vm.prank(admin);
        (bool success,) = address(forwarder).call(abi.encodeCall(Forwarder.executeTreasuryChange, ()));
        assertEq(success, elapsed >= TREASURY_CHANGE_DELAY);
        assertEq(forwarder.treasury(), success ? candidate : treasury);
        assertEq(forwarder.pendingTreasury(), success ? address(0) : candidate);
    }

    /// @dev Any authorized canceller clears the proposals at any time and never touches the active values.
    function testFuzz_CancellationsKeepTheActiveConfiguration(uint8 who, uint256 elapsed, Config memory next) public {
        next = _bound(next);
        _setFees(FIXED, FIXED, 0, 1e6, 0);
        _proposeFees(
            Forwarder.FeeModel(next.lower),
            Forwarder.FeeModel(next.upper),
            next.threshold,
            next.fixedFee,
            next.variableFee
        );
        vm.prank(admin);
        forwarder.proposeTreasury(stranger);
        vm.warp(block.timestamp + bound(elapsed, 0, 1000 days));

        address[4] memory feeCancellers = [admin, guardian, feeManager, feeManager2];
        address[3] memory treasuryCancellers = [admin, guardian, guardian2];
        vm.prank(feeCancellers[who % 4]);
        forwarder.cancelFeeConfigChange();
        vm.prank(treasuryCancellers[who % 3]);
        forwarder.cancelTreasuryChange();

        assertEq(_pendingFeeExecutableAt(), 0);
        assertEq(forwarder.pendingTreasury(), address(0));
        assertEq(forwarder.pendingTreasuryExecutableAt(), 0);
        assertEq(uint8(forwarder.lowerFeeModel()), uint8(FIXED));
        assertEq(forwarder.fixedFee(), 1e6);
        assertEq(forwarder.treasury(), treasury);
    }

    // -----------------------------------------------------------------------------------------------------------
    // forward accounting with the effective fee
    // -----------------------------------------------------------------------------------------------------------

    /// @dev amount = userAmount + effectiveFee; the user receives exactly userAmount and the treasury the fee, with
    /// or without an override, expired or not, paused or not, in every routing mode.
    function testFuzz_ForwardAccountingWithTheEffectiveFee(
        Config memory c,
        uint256 overrideFixed,
        uint256 overrideVariable,
        uint256 overrideDuration,
        uint256 elapsed,
        uint256 amount,
        uint8 modeSeed,
        bool withOverride,
        bool paused
    ) public {
        c = _bound(c);
        _apply(c);
        if (withOverride) {
            _setOverride(
                vip,
                bound(overrideFixed, 0, c.fixedFee),
                bound(overrideVariable, 0, c.variableFee),
                block.timestamp + bound(overrideDuration, 1, 30 days)
            );
        }
        vm.warp(block.timestamp + bound(elapsed, 0, 60 days));
        if (paused) {
            vm.prank(feeManager);
            forwarder.pause();
        }
        Forwarder.RoutingMode mode = Forwarder.RoutingMode(modeSeed % 4);
        _setRouting(mode);
        amount = bound(amount, 0, 1e15);

        uint256 fee = forwarder.calculateFeeFor(vip, amount);
        assertEq(fee, _reference(vip, amount));
        assertLe(fee, forwarder.calculateFee(amount));
        _fundSra(amount);
        if (fee > amount) {
            vm.expectRevert();
            vm.prank(sra);
            forwarder.forward(address(usdc), amount, vip);
            return;
        }
        vm.prank(sra);
        forwarder.forward(address(usdc), amount, vip);

        uint256 userAmount = amount - fee;
        assertEq(userAmount + fee, amount);
        assertEq(usdc.balanceOf(vip) + vault.balanceOf(vip) / 1e12, userAmount, "user");
        assertEq(usdc.balanceOf(treasury) + vault.balanceOf(treasury) / 1e12, fee, "treasury");
        assertEq(usdc.balanceOf(address(forwarder)), 0);
        assertEq(usdc.balanceOf(sra), 0);
    }
}
