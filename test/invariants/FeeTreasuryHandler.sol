// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Forwarder} from "../../src/Forwarder.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockVault} from "../mocks/MockVault.sol";

/**
 * @dev Stateful handler for the V3 additions: delayed fee configuration and treasury changes (propose / execute /
 * cancel by every kind of caller), per-recipient fee overrides (valid, worsening and above-global attempts), time
 * advancement aimed at every boundary, pause, routing, forwards to recipients with and without overrides, treasury
 * and vault failures, rescues, donations and unauthorized calls. It never reverts: every outcome is compared with a
 * reference model and every discrepancy increments a ghost counter that the invariants require to stay at zero.
 *
 * The vault is 1:1 (1 USDC unit = 1e12 shares) because nothing donates to it, so share values are exact.
 */
contract FeeTreasuryHandler is Test {
    struct FeeConfig {
        uint8 lower;
        uint8 upper;
        uint256 threshold;
        uint256 fixedFee;
        uint256 variableFee;
    }

    struct Override {
        uint256 fixedFee;
        uint256 variableFee;
        uint256 validUntil;
    }

    struct Actor {
        address account;
        bool isAdmin;
        bool isManager;
        bool isGuardian;
    }

    uint256 internal constant DELAY = 72 hours;
    uint256 internal constant SHARE_SCALE = 1e12;

    Forwarder public immutable forwarder;
    MockUSDC public immutable usdc;
    MockVault public immutable vault;
    address public immutable admin;

    Actor[] internal actors;
    address[] public treasuryCandidates; // valid treasuries; [0] is the initial one
    address[] public recipients;
    address public sra = makeAddr("v3-handler-sra");

    // Reference model.
    FeeConfig public activeFees;
    FeeConfig public pendingFees;
    uint256 public feeExecutableAt; // 0 = no pending fee configuration change
    address public activeTreasury;
    address public pendingTreasury; // 0 = no pending treasury change
    uint256 public treasuryExecutableAt;
    mapping(address recipient => Override) public overrides;
    bool public paused;

    // Accounting ghosts (USDC units).
    uint256 public ghostDeposited;
    uint256 public ghostDonated;
    uint256 public ghostFees;
    uint256 public ghostUserReceived;
    uint256 public ghostTreasuryReceived;

    // Violation ghosts: must remain zero.
    uint256 public ghostUnexpectedReverts;
    uint256 public ghostUnexpectedSuccesses;
    uint256 public ghostEarlyExecutions;
    uint256 public ghostFeeMismatches;
    uint256 public ghostPausedFeeCharged;
    uint256 public ghostUserMismatches;
    uint256 public ghostTreasuryMismatches;
    uint256 public ghostPendingTreasuryFunded;
    uint256 public ghostRescueMisroutes;
    uint256 public ghostPromiseBroken;

    mapping(bytes32 => uint256) public calls;

    constructor(
        Forwarder forwarder_,
        MockUSDC usdc_,
        MockVault vault_,
        address admin_,
        address[] memory managersOnly,
        address[] memory guardiansOnly,
        address managerAndGuardian,
        address initialTreasury
    ) {
        forwarder = forwarder_;
        usdc = usdc_;
        vault = vault_;
        admin = admin_;
        actors.push(Actor(admin_, true, false, false));
        for (uint256 i = 0; i < managersOnly.length; ++i) {
            actors.push(Actor(managersOnly[i], false, true, false));
        }
        actors.push(Actor(managerAndGuardian, false, true, true));
        for (uint256 i = 0; i < guardiansOnly.length; ++i) {
            actors.push(Actor(guardiansOnly[i], false, false, true));
        }
        for (uint256 i = 0; i < 2; ++i) {
            actors.push(Actor(makeAddr(string.concat("v3-stranger", vm.toString(i))), false, false, false));
        }
        treasuryCandidates.push(initialTreasury);
        treasuryCandidates.push(makeAddr("v3-treasury2"));
        treasuryCandidates.push(makeAddr("v3-treasury3"));
        for (uint256 i = 0; i < 4; ++i) {
            recipients.push(makeAddr(string.concat("v3-recipient", vm.toString(i))));
        }
        activeTreasury = initialTreasury;
        activeFees = FeeConfig(
            uint8(forwarder_.lowerFeeModel()),
            uint8(forwarder_.upperFeeModel()),
            forwarder_.threshold(),
            forwarder_.fixedFee(),
            forwarder_.variableFee()
        );
    }

    // -----------------------------------------------------------------------------------------------------------
    // Views used by the invariants
    // -----------------------------------------------------------------------------------------------------------

    function recipientCount() external view returns (uint256) {
        return recipients.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address account, bool isAdmin, bool isManager, bool isGuardian) {
        Actor memory a = actors[i];
        return (a.account, a.isAdmin, a.isManager, a.isGuardian);
    }

    function treasuryCandidateCount() external view returns (uint256) {
        return treasuryCandidates.length;
    }

    /// @dev Specification of the fee of `recipient`, computed from the reference model only.
    function modelFee(address recipient, uint256 amount) public view returns (uint256) {
        if (paused) return 0;
        FeeConfig memory c = activeFees;
        uint256 fixedValue = c.fixedFee;
        uint256 variableValue = c.variableFee;
        Override memory o = overrides[recipient];
        if (block.timestamp < o.validUntil) {
            if (o.fixedFee < fixedValue) fixedValue = o.fixedFee;
            if (o.variableFee < variableValue) variableValue = o.variableFee;
        }
        uint8 model = amount <= c.threshold ? c.lower : c.upper;
        if (model == 0) return 0;
        if (model == 1) return fixedValue;
        uint256 percent = amount * variableValue / 100_000;
        if (model == 2) return percent;
        return fixedValue + percent;
    }

    function _value(address account) internal view returns (uint256) {
        return usdc.balanceOf(account) + vault.balanceOf(account) / SHARE_SCALE;
    }

    function _actor(uint256 seed) internal view returns (Actor memory) {
        return actors[seed % actors.length];
    }

    uint8 internal constant ADMIN = 1;
    uint8 internal constant MANAGER = 2;
    uint8 internal constant GUARDIAN = 4;

    /// @dev Three times out of four an actor holding one of `roles` (bit mask), otherwise any actor, so that the
    /// campaign reaches the successful paths often while still trying every unauthorized caller.
    function _actorFor(uint256 seed, uint8 roles) internal view returns (Actor memory) {
        if (seed % 4 == 0) return _actor(seed >> 2);
        uint256 count;
        for (uint256 i = 0; i < actors.length; ++i) {
            if (_holds(actors[i], roles)) ++count;
        }
        uint256 target = (seed >> 2) % count;
        for (uint256 i = 0; i < actors.length; ++i) {
            if (_holds(actors[i], roles)) {
                if (target == 0) return actors[i];
                --target;
            }
        }
        revert("unreachable");
    }

    function _holds(Actor memory a, uint8 roles) internal pure returns (bool) {
        return (roles & ADMIN != 0 && a.isAdmin) || (roles & MANAGER != 0 && a.isManager)
            || (roles & GUARDIAN != 0 && a.isGuardian);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Fee configuration lifecycle
    // -----------------------------------------------------------------------------------------------------------

    function proposeFees(
        uint256 actorSeed,
        uint8 lower,
        uint8 upper,
        uint256 threshold,
        uint256 fixedFee,
        uint256 variableFee
    ) external {
        calls["proposeFees"]++;
        Actor memory a = _actorFor(actorSeed, MANAGER);
        FeeConfig memory next = FeeConfig(
            lower % 4, upper % 4, bound(threshold, 0, 1e13), bound(fixedFee, 0, 11e6), bound(variableFee, 0, 11_000)
        );
        bool ok = a.isManager && feeExecutableAt == 0 && next.fixedFee <= 10e6 && next.variableFee <= 10_000;
        vm.prank(a.account);
        try forwarder.proposeFeeConfig(
            Forwarder.FeeModel(next.lower),
            Forwarder.FeeModel(next.upper),
            next.threshold,
            next.fixedFee,
            next.variableFee
        ) {
            if (!ok) ghostUnexpectedSuccesses++;
            calls["proposeFees.ok"]++;
            pendingFees = next;
            feeExecutableAt = block.timestamp + DELAY;
        } catch {
            if (ok) ghostUnexpectedReverts++;
        }
    }

    function executeFees(uint256 actorSeed) external {
        calls["executeFees"]++;
        Actor memory a = _actorFor(actorSeed, MANAGER);
        bool ok = a.isManager && feeExecutableAt != 0 && block.timestamp >= feeExecutableAt;
        vm.prank(a.account);
        try forwarder.executeFeeConfigChange() {
            if (!ok) ghostUnexpectedSuccesses++;
            if (block.timestamp < feeExecutableAt) ghostEarlyExecutions++;
            calls["executeFees.ok"]++;
            activeFees = pendingFees;
            delete pendingFees;
            feeExecutableAt = 0;
        } catch {
            if (ok) ghostUnexpectedReverts++;
        }
    }

    function cancelFees(uint256 actorSeed) external {
        calls["cancelFees"]++;
        Actor memory a = _actorFor(actorSeed, ADMIN | MANAGER | GUARDIAN);
        bool ok = (a.isAdmin || a.isManager || a.isGuardian) && feeExecutableAt != 0;
        vm.prank(a.account);
        try forwarder.cancelFeeConfigChange() {
            if (!ok) ghostUnexpectedSuccesses++;
            calls["cancelFees.ok"]++;
            delete pendingFees;
            feeExecutableAt = 0;
        } catch {
            if (ok) ghostUnexpectedReverts++;
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Treasury lifecycle
    // -----------------------------------------------------------------------------------------------------------

    function proposeTreasury(uint256 actorSeed, uint256 candidateSeed) external {
        calls["proposeTreasury"]++;
        Actor memory a = _actorFor(actorSeed, ADMIN);
        uint256 pick = candidateSeed % (treasuryCandidates.length + 2);
        address candidate = pick < treasuryCandidates.length
            ? treasuryCandidates[pick]
            : (pick == treasuryCandidates.length ? address(0) : address(forwarder));
        bool ok =
            a.isAdmin && pendingTreasury == address(0) && candidate != address(0) && candidate != address(forwarder);
        vm.prank(a.account);
        try forwarder.proposeTreasury(candidate) {
            if (!ok) ghostUnexpectedSuccesses++;
            calls["proposeTreasury.ok"]++;
            pendingTreasury = candidate;
            treasuryExecutableAt = block.timestamp + DELAY;
        } catch {
            if (ok) ghostUnexpectedReverts++;
        }
    }

    function executeTreasury(uint256 actorSeed) external {
        calls["executeTreasury"]++;
        Actor memory a = _actorFor(actorSeed, ADMIN);
        bool ok = a.isAdmin && pendingTreasury != address(0) && block.timestamp >= treasuryExecutableAt;
        vm.prank(a.account);
        try forwarder.executeTreasuryChange() {
            if (!ok) ghostUnexpectedSuccesses++;
            if (block.timestamp < treasuryExecutableAt) ghostEarlyExecutions++;
            calls["executeTreasury.ok"]++;
            activeTreasury = pendingTreasury;
            pendingTreasury = address(0);
            treasuryExecutableAt = 0;
        } catch {
            if (ok) ghostUnexpectedReverts++;
        }
    }

    function cancelTreasury(uint256 actorSeed) external {
        calls["cancelTreasury"]++;
        Actor memory a = _actorFor(actorSeed, ADMIN | GUARDIAN);
        bool ok = (a.isAdmin || a.isGuardian) && pendingTreasury != address(0);
        vm.prank(a.account);
        try forwarder.cancelTreasuryChange() {
            if (!ok) ghostUnexpectedSuccesses++;
            calls["cancelTreasury.ok"]++;
            pendingTreasury = address(0);
            treasuryExecutableAt = 0;
        } catch {
            if (ok) ghostUnexpectedReverts++;
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Overrides
    // -----------------------------------------------------------------------------------------------------------

    /// @param style 0: improve (lower and/or extend), 1: raise the fixed fee, 2: raise the variable fee, 3: shorten,
    /// 4: random values up to slightly above the global fee, 5: zero recipient.
    function setOverride(
        uint256 actorSeed,
        uint256 recipientSeed,
        uint8 style,
        uint256 fixedSeed,
        uint256 variableSeed,
        uint256 untilSeed
    ) external {
        calls["setOverride"]++;
        Actor memory a = _actorFor(actorSeed, MANAGER);
        style = style % 6;
        address recipient = style == 5 ? address(0) : recipients[recipientSeed % recipients.length];
        Override memory current = overrides[recipient];
        bool active = block.timestamp < current.validUntil;
        Override memory next;
        if (active && style <= 3) {
            next.fixedFee = fixedSeed % (current.fixedFee + 1);
            next.variableFee = variableSeed % (current.variableFee + 1);
            next.validUntil = current.validUntil + untilSeed % 30 days;
            if (style == 1) next.fixedFee = current.fixedFee + 1 + fixedSeed % 3;
            if (style == 2) next.variableFee = current.variableFee + 1 + variableSeed % 3;
            if (style == 3) {
                next.validUntil = current.validUntil - 1 - untilSeed % (current.validUntil - block.timestamp);
            }
        } else {
            next.fixedFee = fixedSeed % (activeFees.fixedFee + 2);
            next.variableFee = variableSeed % (activeFees.variableFee + 2);
            next.validUntil = block.timestamp + untilSeed % 60 days; // may equal now: invalid
        }
        bool ok = a.isManager && recipient != address(0) && next.validUntil > block.timestamp
            && next.fixedFee <= activeFees.fixedFee && next.variableFee <= activeFees.variableFee
            && (!active
                || (next.fixedFee <= current.fixedFee
                    && next.variableFee <= current.variableFee
                    && next.validUntil >= current.validUntil));
        vm.prank(a.account);
        try forwarder.setUserFeeOverride(recipient, next.fixedFee, next.variableFee, next.validUntil) {
            if (!ok) ghostUnexpectedSuccesses++;
            if (
                active
                    && (next.fixedFee > current.fixedFee
                        || next.variableFee > current.variableFee
                        || next.validUntil < current.validUntil)
            ) ghostPromiseBroken++;
            calls["setOverride.ok"]++;
            if (active) calls["setOverride.improvedActive"]++;
            overrides[recipient] = next;
        } catch {
            if (ok) ghostUnexpectedReverts++;
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Time
    // -----------------------------------------------------------------------------------------------------------

    /// @dev Advances time, half of the time to a boundary: one second before / exactly at a pending executableAt or
    /// an override expiry.
    function warp(uint256 seed) external {
        calls["warp"]++;
        uint256 target = block.timestamp + (seed >> 8) % (2 * DELAY);
        uint256 choice = seed % 8;
        Override memory o = overrides[recipients[(seed >> 4) % recipients.length]];
        if (choice == 0 && feeExecutableAt > block.timestamp + 1) target = feeExecutableAt - 1;
        else if (choice == 1 && feeExecutableAt > block.timestamp) target = feeExecutableAt;
        else if (choice == 2 && treasuryExecutableAt > block.timestamp + 1) target = treasuryExecutableAt - 1;
        else if (choice == 3 && treasuryExecutableAt > block.timestamp) target = treasuryExecutableAt;
        else if (choice == 4 && o.validUntil > block.timestamp + 1) target = o.validUntil - 1;
        else if (choice == 5 && o.validUntil > block.timestamp) target = o.validUntil;
        else if (choice == 6) target = block.timestamp + (seed >> 8) % 1 hours;
        vm.warp(target);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Forward and funds
    // -----------------------------------------------------------------------------------------------------------

    struct Balances {
        uint256 recipient;
        uint256 forwarder;
        uint256[3] treasuries;
    }

    function _balances(address recipient) internal view returns (Balances memory b) {
        b.recipient = _value(recipient);
        b.forwarder = usdc.balanceOf(address(forwarder));
        for (uint256 i = 0; i < 3; ++i) {
            b.treasuries[i] = _value(treasuryCandidates[i]);
        }
    }

    function forward(uint256 amount, uint256 recipientSeed) external {
        calls["forward"]++;
        amount = bound(amount, 0, 1e13);
        address recipient = recipients[recipientSeed % recipients.length];
        uint256 fee = forwarder.calculateFeeFor(recipient, amount);
        if (fee != modelFee(recipient, amount) || fee > forwarder.calculateFee(amount)) ghostFeeMismatches++;
        if (paused && fee != 0) ghostPausedFeeCharged++;

        usdc.mint(sra, amount);
        Balances memory before = _balances(recipient);
        vm.startPrank(sra);
        usdc.approve(address(forwarder), amount);
        try forwarder.forward(address(usdc), amount, recipient) {
            vm.stopPrank();
            if (fee > amount) {
                ghostUnexpectedSuccesses++;
                return;
            }
        } catch {
            vm.stopPrank();
            // The funds never left the SRA and are not accounted.
            if (fee <= amount) ghostUnexpectedReverts++;
            return;
        }
        ghostDeposited += amount;
        ghostFees += fee;
        calls["forward.ok"]++;
        (,, uint256 validUntil) = forwarder.userFeeOverrides(recipient);
        if (block.timestamp < validUntil && fee < forwarder.calculateFee(amount)) calls["forward.discounted"]++;
        _checkForward(recipient, amount - fee, fee, before);
    }

    function _checkForward(address recipient, uint256 userAmount, uint256 fee, Balances memory before) internal {
        uint256 received = _value(recipient) - before.recipient;
        ghostUserReceived += received;
        if (received != userAmount) ghostUserMismatches++;

        uint256 forwarderAfter = usdc.balanceOf(address(forwarder));
        uint256 activeDelta;
        for (uint256 i = 0; i < 3; ++i) {
            address t = treasuryCandidates[i];
            uint256 delta = _value(t) - before.treasuries[i];
            if (t == activeTreasury) {
                activeDelta = delta;
            } else if (delta != 0) {
                if (t == pendingTreasury) ghostPendingTreasuryFunded++;
                else ghostTreasuryMismatches++;
            }
        }
        ghostTreasuryReceived += activeDelta;
        if (activeDelta + forwarderAfter != before.forwarder + fee) ghostTreasuryMismatches++;
        // A successful treasury delivery always takes the whole balance, never part of it.
        if (activeDelta != 0 && forwarderAfter != 0) ghostTreasuryMismatches++;
    }

    function donate(uint256 amount) external {
        calls["donate"]++;
        amount = bound(amount, 1, 1e12);
        usdc.mint(address(forwarder), amount);
        ghostDonated += amount;
    }

    function rescueUsdc() external {
        calls["rescueUsdc"]++;
        uint256 amount = usdc.balanceOf(address(forwarder));
        Balances memory before = _balances(recipients[0]);
        vm.prank(admin);
        try forwarder.rescueToken(IERC20(address(usdc))) {
            for (uint256 i = 0; i < 3; ++i) {
                address t = treasuryCandidates[i];
                uint256 delta = usdc.balanceOf(t) + vault.balanceOf(t) / SHARE_SCALE - before.treasuries[i];
                if (t == activeTreasury ? delta != amount : delta != 0) ghostRescueMisroutes++;
            }
            if (usdc.balanceOf(address(forwarder)) != 0) ghostRescueMisroutes++;
            ghostTreasuryReceived += amount;
        } catch {
            // Only acceptable reason: the active treasury cannot receive USDC.
            if (!usdc.isBlacklisted(activeTreasury)) ghostUnexpectedReverts++;
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Pause, routing, failures
    // -----------------------------------------------------------------------------------------------------------

    function togglePause(uint256 actorSeed) external {
        calls["togglePause"]++;
        Actor memory a = _actor(actorSeed);
        bool wasPaused = paused;
        bool ok = wasPaused ? a.isAdmin : (a.isAdmin || a.isManager);
        vm.prank(a.account);
        if (wasPaused) {
            try forwarder.unpause() {
                if (!ok) ghostUnexpectedSuccesses++;
                paused = false;
            } catch {
                if (ok) ghostUnexpectedReverts++;
            }
        } else {
            try forwarder.pause() {
                if (!ok) ghostUnexpectedSuccesses++;
                paused = true;
            } catch {
                if (ok) ghostUnexpectedReverts++;
            }
        }
    }

    function setRoutingMode(uint8 modeSeed) external {
        calls["setRoutingMode"]++;
        vm.prank(admin);
        try forwarder.setRoutingMode(Forwarder.RoutingMode(modeSeed % 4)) {}
        catch {
            ghostUnexpectedReverts++;
        }
    }

    /// @dev Treasuries that cannot receive USDC (blacklist) and a vault whose deposits revert.
    function toggleFailure(uint8 kind, uint256 seed, bool on) external {
        calls["toggleFailure"]++;
        if (kind % 2 == 0) usdc.setBlacklisted(treasuryCandidates[seed % 3], on);
        else vault.setDepositReverts(on);
    }

    /// @dev Accounts try functions their roles do not allow.
    function unauthorizedCall(uint256 actorSeed, uint8 selectorSeed, uint256 value) external {
        calls["unauthorizedCall"]++;
        Actor memory a = _actor(actorSeed);
        if (a.isAdmin) return;
        bytes[12] memory candidates = [
            abi.encodeCall(Forwarder.proposeTreasury, (a.account)),
            abi.encodeCall(Forwarder.executeTreasuryChange, ()),
            abi.encodeCall(Forwarder.rescueToken, (IERC20(address(usdc)))),
            abi.encodeCall(Forwarder.setRoutingMode, (Forwarder.RoutingMode(value % 4))),
            abi.encodeCall(Forwarder.unpause, ()),
            abi.encodeCall(IAccessControl.grantRole, (forwarder.FEE_MANAGER_ROLE(), a.account)),
            abi.encodeCall(Forwarder.proposeFeeConfig, (Forwarder.FeeModel.FIXED, Forwarder.FeeModel.FIXED, 0, 1, 1)),
            abi.encodeCall(Forwarder.executeFeeConfigChange, ()),
            abi.encodeCall(Forwarder.setUserFeeOverride, (a.account, 0, 0, block.timestamp + 1)),
            abi.encodeCall(Forwarder.pause, ()),
            abi.encodeCall(Forwarder.cancelTreasuryChange, ()),
            abi.encodeCall(Forwarder.cancelFeeConfigChange, ())
        ];
        // Only calls the actor is not allowed to make: fee managers may use 6-9 (and 10-11 as guardian), guardians
        // 10-11, strangers nothing.
        uint256 limit = a.isManager ? 6 : (a.isGuardian ? 10 : 12);
        uint256 s = selectorSeed % limit;
        vm.prank(a.account);
        (bool success,) = address(forwarder).call(candidates[s]);
        if (success) ghostUnexpectedSuccesses++;
    }
}
