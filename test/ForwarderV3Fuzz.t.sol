// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

    // -----------------------------------------------------------------------------------------------------------
    // State machines with a reference model
    // -----------------------------------------------------------------------------------------------------------

    /// @dev Random sequences of propose / execute / cancel / warp / pause on the fee configuration, checked step by
    /// step against a reference model (active and pending configuration, executableAt).
    function testFuzz_FeeLifecycleStateMachine(uint256[16] memory ops) public {
        Config memory active = Config(0, 0, 0, 0, 0);
        Config memory pending;
        uint256 executableAt;
        address[5] memory callers = [feeManager, feeManager2, guardian, admin, stranger];
        for (uint256 i = 0; i < ops.length; ++i) {
            uint256 op = ops[i];
            address caller = callers[(op >> 8) % 5];
            bool isManager = caller == feeManager || caller == feeManager2;
            uint256 kind = op % 5;
            if (kind == 0) {
                Config memory next = _bound(Config(uint8(op >> 16), uint8(op >> 24), op >> 32, op >> 40, op >> 64));
                bool ok = isManager && executableAt == 0;
                vm.prank(caller);
                (bool success,) = address(forwarder)
                    .call(
                        abi.encodeCall(
                            Forwarder.proposeFeeConfig,
                            (
                                Forwarder.FeeModel(next.lower),
                                Forwarder.FeeModel(next.upper),
                                next.threshold,
                                next.fixedFee,
                                next.variableFee
                            )
                        )
                    );
                assertEq(success, ok, "propose");
                if (success) {
                    pending = next;
                    executableAt = block.timestamp + FEE_CHANGE_DELAY;
                }
            } else if (kind == 1) {
                bool ok = isManager && executableAt != 0 && block.timestamp >= executableAt;
                vm.prank(caller);
                (bool success,) = address(forwarder).call(abi.encodeCall(Forwarder.executeFeeConfigChange, ()));
                assertEq(success, ok, "execute");
                if (success) {
                    active = pending;
                    executableAt = 0;
                }
            } else if (kind == 2) {
                bool ok = caller != stranger && executableAt != 0;
                vm.prank(caller);
                (bool success,) = address(forwarder).call(abi.encodeCall(Forwarder.cancelFeeConfigChange, ()));
                assertEq(success, ok, "cancel");
                if (success) executableAt = 0;
            } else if (kind == 3) {
                uint256 choice = (op >> 8) % 4;
                if (choice == 0 && executableAt > block.timestamp + 1) vm.warp(executableAt - 1);
                else if (choice == 1 && executableAt > block.timestamp) vm.warp(executableAt);
                else vm.warp(block.timestamp + (op >> 16) % (2 * FEE_CHANGE_DELAY));
            } else {
                bool isPaused = forwarder.paused(); // read before the prank: a view call would consume it
                vm.prank(admin);
                if (isPaused) forwarder.unpause();
                else forwarder.pause();
            }
            _assertFeeModel(active, executableAt == 0 ? Config(0, 0, 0, 0, 0) : pending, executableAt);
        }
    }

    function _assertFeeModel(Config memory active, Config memory pending, uint256 executableAt) internal view {
        assertEq(uint8(forwarder.lowerFeeModel()), active.lower, "active lower");
        assertEq(uint8(forwarder.upperFeeModel()), active.upper, "active upper");
        assertEq(forwarder.threshold(), active.threshold, "active threshold");
        assertEq(forwarder.fixedFee(), active.fixedFee, "active fixed");
        assertEq(forwarder.variableFee(), active.variableFee, "active variable");
        (
            Forwarder.FeeModel lower,
            Forwarder.FeeModel upper,
            uint256 pendingThreshold,
            uint256 pendingFixedFee,
            uint256 pendingVariableFee,
            uint256 pendingAt
        ) = forwarder.pendingFeeConfig();
        assertEq(uint8(lower), pending.lower, "pending lower");
        assertEq(uint8(upper), pending.upper, "pending upper");
        assertEq(pendingThreshold, pending.threshold, "pending threshold");
        assertEq(pendingFixedFee, pending.fixedFee, "pending fixed");
        assertEq(pendingVariableFee, pending.variableFee, "pending variable");
        assertEq(pendingAt, executableAt, "pending executableAt");
        assertLe(forwarder.fixedFee(), 10e6);
        assertLe(forwarder.variableFee(), 10_000);
    }

    /// @dev Same for the treasury, with forwards and rescues in between: funds only ever reach the active treasury.
    function testFuzz_TreasuryLifecycleStateMachine(uint256[16] memory ops) public {
        _setFees(FIXED, FIXED, 0, 1e6, 0);
        address[4] memory candidates = [makeAddr("t1"), makeAddr("t2"), address(0), address(forwarder)];
        address[4] memory callers = [admin, guardian, feeManager, stranger];
        address active = treasury;
        address pending;
        uint256 executableAt;
        for (uint256 i = 0; i < ops.length; ++i) {
            uint256 op = ops[i];
            address caller = callers[(op >> 8) % 4];
            uint256 kind = op % 6;
            if (kind == 0) {
                address candidate = candidates[(op >> 16) % 4];
                bool ok = caller == admin && pending == address(0) && candidate != address(0)
                    && candidate != address(forwarder);
                vm.prank(caller);
                (bool success,) = address(forwarder).call(abi.encodeCall(Forwarder.proposeTreasury, (candidate)));
                assertEq(success, ok, "propose");
                if (success) {
                    pending = candidate;
                    executableAt = block.timestamp + TREASURY_CHANGE_DELAY;
                }
            } else if (kind == 1) {
                bool ok = caller == admin && pending != address(0) && block.timestamp >= executableAt;
                vm.prank(caller);
                (bool success,) = address(forwarder).call(abi.encodeCall(Forwarder.executeTreasuryChange, ()));
                assertEq(success, ok, "execute");
                if (success) {
                    active = pending;
                    pending = address(0);
                    executableAt = 0;
                }
            } else if (kind == 2) {
                bool ok = (caller == admin || caller == guardian) && pending != address(0);
                vm.prank(caller);
                (bool success,) = address(forwarder).call(abi.encodeCall(Forwarder.cancelTreasuryChange, ()));
                assertEq(success, ok, "cancel");
                if (success) {
                    pending = address(0);
                    executableAt = 0;
                }
            } else if (kind == 3) {
                uint256 choice = (op >> 16) % 3;
                if (choice == 0 && executableAt > block.timestamp + 1) vm.warp(executableAt - 1);
                else if (choice == 1 && executableAt > block.timestamp) vm.warp(executableAt);
                else vm.warp(block.timestamp + (op >> 24) % (2 * TREASURY_CHANGE_DELAY));
            } else if (kind == 4) {
                uint256 activeBefore = usdc.balanceOf(active);
                uint256 pendingBefore = pending == address(0) ? 0 : usdc.balanceOf(pending);
                _forward(10e6, user);
                assertEq(usdc.balanceOf(active) - activeBefore, 1e6, "fee to the active treasury");
                if (pending != address(0) && pending != active) {
                    assertEq(usdc.balanceOf(pending), pendingBefore, "pending treasury received funds");
                }
            } else {
                usdc.mint(address(forwarder), 3e6);
                uint256 activeBefore = usdc.balanceOf(active);
                vm.prank(admin);
                forwarder.rescueToken(IERC20(address(usdc)));
                assertEq(usdc.balanceOf(active) - activeBefore, 3e6, "rescue to the active treasury");
            }
            assertEq(forwarder.treasury(), active, "active treasury");
            assertEq(forwarder.pendingTreasury(), pending, "pending treasury");
            assertEq(forwarder.pendingTreasuryExecutableAt(), executableAt, "pending executableAt");
        }
    }

    /// @dev Overrides interleaved with global fee changes, pause and time: the fee never exceeds the current global
    /// fee, always matches the specification, and an active override is never worsened before its `validUntil`.
    function testFuzz_OverrideLifecycleWithGlobalChanges(uint256[12] memory ops, uint256 amount) public {
        amount = bound(amount, 0, 1e15);
        address[3] memory recipients = [vip, user, makeAddr("vip2")];
        for (uint256 i = 0; i < ops.length; ++i) {
            uint256 op = ops[i];
            address recipient = recipients[(op >> 8) % 3];
            uint256 kind = op % 4;
            (uint256 oldFixed, uint256 oldVariable, uint256 oldUntil) = forwarder.userFeeOverrides(recipient);
            bool wasActive = block.timestamp < oldUntil;
            if (kind == 0) {
                _apply(_bound(Config(uint8(op >> 16), uint8(op >> 24), op >> 32, op >> 48, op >> 80)));
                if (wasActive) assertGt(oldUntil, 0);
            } else if (kind == 1) {
                uint256 newFixed = (op >> 16) % (forwarder.fixedFee() + 2);
                uint256 newVariable = (op >> 48) % (forwarder.variableFee() + 2);
                uint256 newUntil = block.timestamp + (op >> 80) % (60 days) + ((op >> 120) % 2 == 0 ? 0 : oldUntil);
                vm.prank(feeManager);
                (bool success,) = address(forwarder)
                    .call(abi.encodeCall(Forwarder.setUserFeeOverride, (recipient, newFixed, newVariable, newUntil)));
                bool ok = newUntil > block.timestamp && newFixed <= forwarder.fixedFee()
                    && newVariable <= forwarder.variableFee()
                    && (!wasActive || (newFixed <= oldFixed && newVariable <= oldVariable && newUntil >= oldUntil));
                assertEq(success, ok, "override rule");
            } else if (kind == 2) {
                vm.warp(block.timestamp + (op >> 16) % (90 days));
            } else {
                bool isPaused = forwarder.paused(); // read before the prank: a view call would consume it
                vm.prank(admin);
                if (isPaused) forwarder.unpause();
                else forwarder.pause();
            }
            for (uint256 r = 0; r < recipients.length; ++r) {
                uint256 fee = forwarder.calculateFeeFor(recipients[r], amount);
                assertLe(fee, forwarder.calculateFee(amount), "above global");
                assertEq(fee, _reference(recipients[r], amount), "reference");
                if (forwarder.paused()) assertEq(fee, 0, "paused");
            }
            if (wasActive && block.timestamp < oldUntil) {
                (uint256 nowFixed, uint256 nowVariable, uint256 nowUntil) = forwarder.userFeeOverrides(recipient);
                assertLe(nowFixed, oldFixed, "fixed raised");
                assertLe(nowVariable, oldVariable, "variable raised");
                assertGe(nowUntil, oldUntil, "expiry shortened");
            }
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Access control and timestamps
    // -----------------------------------------------------------------------------------------------------------

    /// @dev Who can call each new function: unprivileged accounts nothing, guardians only cancel, fee managers only the
    /// fee functions, the admin only the treasury functions and the cancellations.
    function testFuzz_AccessControlOfTheNewFunctions(address caller, uint8 selectorSeed) public {
        _proposeFees(FIXED, FIXED, 0, 1, 1);
        vm.prank(admin);
        forwarder.proposeTreasury(makeAddr("pendingTreasury"));
        vm.warp(block.timestamp + 72 hours);
        bool isAdmin = caller == admin;
        bool isManager = caller == feeManager || caller == feeManager2;
        bool isGuardian = caller == guardian || caller == guardian2;
        uint256 s = selectorSeed % 7;
        bytes memory data;
        bool allowed;
        if (s == 0) {
            (data, allowed) = (abi.encodeCall(Forwarder.executeFeeConfigChange, ()), isManager);
        } else if (s == 1) {
            (data, allowed) = (abi.encodeCall(Forwarder.cancelFeeConfigChange, ()), isManager || isGuardian || isAdmin);
        } else if (s == 2) {
            (data, allowed) = (abi.encodeCall(Forwarder.executeTreasuryChange, ()), isAdmin);
        } else if (s == 3) {
            (data, allowed) = (abi.encodeCall(Forwarder.cancelTreasuryChange, ()), isGuardian || isAdmin);
        } else if (s == 4) {
            (data, allowed) =
            (abi.encodeCall(Forwarder.setUserFeeOverride, (caller == address(0) ? vip : caller, 0, 0, MAX)), isManager);
        } else if (s == 5) {
            vm.prank(feeManager);
            forwarder.cancelFeeConfigChange();
            (data, allowed) = (abi.encodeCall(Forwarder.proposeFeeConfig, (NONE, NONE, 0, 0, 0)), isManager);
        } else {
            vm.prank(admin);
            forwarder.cancelTreasuryChange();
            (data, allowed) = (abi.encodeCall(Forwarder.proposeTreasury, (makeAddr("other"))), isAdmin);
        }
        vm.prank(caller);
        (bool success,) = address(forwarder).call(data);
        assertEq(success, allowed);
    }

    /// @dev At any absolute time, executing one second before `executableAt` fails and at `executableAt` succeeds.
    function testFuzz_ExecutableAtBoundariesAtAnyTime(uint256 proposeTime) public {
        proposeTime = bound(proposeTime, block.timestamp, type(uint64).max);
        vm.warp(proposeTime);
        _proposeFees(FIXED, FIXED, 0, 1e6, 0);
        vm.prank(admin);
        forwarder.proposeTreasury(makeAddr("next"));
        assertEq(_pendingFeeExecutableAt(), proposeTime + 72 hours);
        assertEq(forwarder.pendingTreasuryExecutableAt(), proposeTime + 72 hours);

        vm.warp(proposeTime + 72 hours - 1);
        vm.prank(feeManager);
        (bool feeEarly,) = address(forwarder).call(abi.encodeCall(Forwarder.executeFeeConfigChange, ()));
        vm.prank(admin);
        (bool treasuryEarly,) = address(forwarder).call(abi.encodeCall(Forwarder.executeTreasuryChange, ()));
        assertFalse(feeEarly);
        assertFalse(treasuryEarly);

        vm.warp(proposeTime + 72 hours);
        vm.prank(feeManager);
        forwarder.executeFeeConfigChange();
        vm.prank(admin);
        forwarder.executeTreasuryChange();
        assertEq(forwarder.fixedFee(), 1e6);
        assertEq(forwarder.treasury(), makeAddr("next"));
    }
}
