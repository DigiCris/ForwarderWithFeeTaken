// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Forwarder} from "../src/Forwarder.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {MockVault} from "../test/mocks/MockVault.sol";
import {Actor, IHevm} from "./ForwarderEchidna.sol";

/**
 * @title ForwarderV3Echidna
 * @notice Property-based campaign for the V3 additions: delayed fee configuration and treasury changes (propose /
 * execute / cancel by every kind of actor), per-recipient fee overrides (valid, worsening and above-global
 * attempts), time jumps (random and exactly at every boundary), pause, routing, forwards to recipients with and
 * without overrides, treasury and vault failures, rescues, donations and unauthorized calls. A reference model
 * predicts every outcome; the `echidna_*` properties must always hold. The vault is 1:1, so share values are exact.
 */
contract ForwarderV3Echidna {
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

    uint256 internal constant DELAY = 72 hours;
    uint256 internal constant SHARE_SCALE = 1e12;
    IHevm internal constant HEVM = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    MockUSDC internal usdc;
    MockVault internal vault;
    Forwarder internal forwarder;
    Actor internal admin;
    Actor internal feeManager; // FEE_MANAGER_ROLE only
    Actor internal feeManagerGuardian; // FEE_MANAGER_ROLE and VAULT_GUARDIAN_ROLE, like the production wallets
    Actor[2] internal guardians; // VAULT_GUARDIAN_ROLE only
    Actor internal stranger;
    Actor internal sra;
    Actor[6] internal actors;
    address[3] internal treasuries; // [0] initial treasury
    address[4] internal recipients;
    bytes32 internal feeManagerRole;
    bytes32 internal guardianRole;
    bytes32 internal adminRole;

    // Reference model.
    FeeConfig internal mActive;
    FeeConfig internal mPending;
    uint256 internal mFeeExecutableAt;
    address internal mTreasury;
    address internal mPendingTreasury;
    uint256 internal mTreasuryExecutableAt;
    mapping(address => Override) internal mOverride;
    bool internal mPaused;

    // Accounting ghosts.
    uint256 internal deposited;
    uint256 internal donated;
    uint256 internal fees;
    uint256 internal userReceived;
    uint256 internal treasuryReceived;

    // Violation counters.
    uint256 internal unexpectedReverts;
    uint256 internal unexpectedSuccesses;
    uint256 internal earlyExecutions;
    uint256 internal feeMismatches;
    uint256 internal pausedFeeCharged;
    uint256 internal userMismatches;
    uint256 internal treasuryMismatches;
    uint256 internal pendingTreasuryFunded;
    uint256 internal rescueMisroutes;
    uint256 internal promisesBroken;

    // Progress counters (visible in the coverage report).
    uint256 internal proposeFeesOk;
    uint256 internal executeFeesOk;
    uint256 internal cancelFeesOk;
    uint256 internal proposeTreasuryOk;
    uint256 internal executeTreasuryOk;
    uint256 internal cancelTreasuryOk;
    uint256 internal overrideOk;
    uint256 internal overrideImprovedWhileActive;
    uint256 internal forwardOk;
    uint256 internal forwardDiscounted;

    constructor() {
        usdc = new MockUSDC();
        vault = new MockVault(IERC20(address(usdc)));
        admin = new Actor();
        feeManager = new Actor();
        feeManagerGuardian = new Actor();
        guardians[0] = new Actor();
        guardians[1] = new Actor();
        stranger = new Actor();
        sra = new Actor();
        actors = [admin, feeManager, feeManagerGuardian, guardians[0], guardians[1], stranger];
        treasuries = [address(0x7000), address(0x7001), address(0x7002)];
        recipients = [address(0xA000), address(0xA001), address(0xA002), address(0xA003)];

        address[] memory managers = new address[](2);
        managers[0] = address(feeManager);
        managers[1] = address(feeManagerGuardian);
        address[] memory initialGuardians = new address[](3);
        initialGuardians[0] = address(feeManagerGuardian);
        initialGuardians[1] = address(guardians[0]);
        initialGuardians[2] = address(guardians[1]);
        // No initial vault (no constructor health check to fund); the vault is activated below through the delay.
        forwarder = new Forwarder(
            IERC20(address(usdc)),
            address(admin),
            3 days,
            treasuries[0],
            IERC4626(address(0)),
            Forwarder.RoutingMode.DIRECT_DIRECT,
            managers,
            initialGuardians
        );
        feeManagerRole = forwarder.FEE_MANAGER_ROLE();
        guardianRole = forwarder.VAULT_GUARDIAN_ROLE();
        adminRole = forwarder.DEFAULT_ADMIN_ROLE();

        // Activate the vault through the V2 lifecycle (initial vault zero, so the health checks are funded here).
        usdc.mint(address(admin), 2000);
        admin.exec(address(usdc), abi.encodeCall(IERC20.approve, (address(forwarder), 2000)));
        require(_call(admin, abi.encodeCall(Forwarder.proposeVault, (IERC4626(address(vault))))), "harness: propose");
        HEVM.warp(forwarder.pendingVaultExecutableAt());
        require(_call(admin, abi.encodeCall(Forwarder.executeVaultChange, ())), "harness: execute");
        admin.exec(address(usdc), abi.encodeCall(IERC20.approve, (address(forwarder), 0)));

        // Start from a non-zero global configuration, applied through the delay, so that overrides matter at once.
        require(
            _call(
                feeManager,
                abi.encodeCall(
                    Forwarder.proposeFeeConfig,
                    (Forwarder.FeeModel.FIXED_PLUS_PERCENT, Forwarder.FeeModel.PERCENT, 100e6, 1e6, 1000)
                )
            ),
            "harness: propose fees"
        );
        (,,,,, uint256 executableAt) = forwarder.pendingFeeConfig();
        HEVM.warp(executableAt);
        require(_call(feeManager, abi.encodeCall(Forwarder.executeFeeConfigChange, ())), "harness: execute fees");
        mActive = FeeConfig(3, 2, 100e6, 1e6, 1000);
        mTreasury = treasuries[0];
    }

    // -----------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------

    function _call(Actor actor, bytes memory data) internal returns (bool success) {
        (success,) = actor.exec(address(forwarder), data);
    }

    function _isAdmin(Actor a) internal view returns (bool) {
        return a == admin;
    }

    function _isManager(Actor a) internal view returns (bool) {
        return a == feeManager || a == feeManagerGuardian;
    }

    function _isGuardian(Actor a) internal view returns (bool) {
        return a == feeManagerGuardian || a == guardians[0] || a == guardians[1];
    }

    /// @dev Three times out of four an actor allowed to make the call, otherwise any actor.
    function _pick(uint256 seed, Actor[] memory allowed) internal view returns (Actor) {
        if (seed % 4 == 0) return actors[(seed >> 2) % actors.length];
        return allowed[(seed >> 2) % allowed.length];
    }

    function _managers() internal view returns (Actor[] memory a) {
        a = new Actor[](2);
        a[0] = feeManager;
        a[1] = feeManagerGuardian;
    }

    function _admins() internal view returns (Actor[] memory a) {
        a = new Actor[](1);
        a[0] = admin;
    }

    function _feeCancellers() internal view returns (Actor[] memory a) {
        a = new Actor[](5);
        a[0] = admin;
        a[1] = feeManager;
        a[2] = feeManagerGuardian;
        a[3] = guardians[0];
        a[4] = guardians[1];
    }

    function _treasuryCancellers() internal view returns (Actor[] memory a) {
        a = new Actor[](4);
        a[0] = admin;
        a[1] = feeManagerGuardian;
        a[2] = guardians[0];
        a[3] = guardians[1];
    }

    function _value(address account) internal view returns (uint256) {
        return usdc.balanceOf(account) + vault.balanceOf(account) / SHARE_SCALE;
    }

    /// @dev Specification of the fee of `recipient`, from the reference model only.
    function _modelFee(address recipient, uint256 amount) internal view returns (uint256) {
        if (mPaused) return 0;
        FeeConfig memory c = mActive;
        uint256 fixedValue = c.fixedFee;
        uint256 variableValue = c.variableFee;
        Override memory o = mOverride[recipient];
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

    function _amounts() internal view returns (uint256[6] memory) {
        uint256 t = forwarder.threshold();
        return [uint256(0), 1, t, t == type(uint256).max ? t : t + 1, 1e9, 1e13];
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
    ) public {
        Actor a = _pick(actorSeed, _managers());
        FeeConfig memory next = FeeConfig(lower % 4, upper % 4, threshold % 1e13, fixedFee % 11e6, variableFee % 11_000);
        bool ok = _isManager(a) && mFeeExecutableAt == 0 && next.fixedFee <= 10e6 && next.variableFee <= 10_000;
        bool success = _call(
            a,
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
        if (success != ok) success ? unexpectedSuccesses++ : unexpectedReverts++;
        if (success) {
            proposeFeesOk++;
            mPending = next;
            mFeeExecutableAt = block.timestamp + DELAY;
        }
    }

    function executeFees(uint256 actorSeed) public {
        Actor a = _pick(actorSeed, _managers());
        bool ok = _isManager(a) && mFeeExecutableAt != 0 && block.timestamp >= mFeeExecutableAt;
        bool success = _call(a, abi.encodeCall(Forwarder.executeFeeConfigChange, ()));
        if (success != ok) success ? unexpectedSuccesses++ : unexpectedReverts++;
        if (success) {
            if (block.timestamp < mFeeExecutableAt) earlyExecutions++;
            executeFeesOk++;
            mActive = mPending;
            delete mPending;
            mFeeExecutableAt = 0;
        }
    }

    function cancelFees(uint256 actorSeed) public {
        Actor a = _pick(actorSeed, _feeCancellers());
        bool ok = (_isAdmin(a) || _isManager(a) || _isGuardian(a)) && mFeeExecutableAt != 0;
        bool success = _call(a, abi.encodeCall(Forwarder.cancelFeeConfigChange, ()));
        if (success != ok) success ? unexpectedSuccesses++ : unexpectedReverts++;
        if (success) {
            cancelFeesOk++;
            delete mPending;
            mFeeExecutableAt = 0;
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Treasury lifecycle
    // -----------------------------------------------------------------------------------------------------------

    function proposeTreasury(uint256 actorSeed, uint8 candidateSeed) public {
        Actor a = _pick(actorSeed, _admins());
        uint256 pick = candidateSeed % 5;
        address candidate = pick < 3 ? treasuries[pick] : (pick == 3 ? address(0) : address(forwarder));
        bool ok =
            _isAdmin(a) && mPendingTreasury == address(0) && candidate != address(0) && candidate != address(forwarder);
        bool success = _call(a, abi.encodeCall(Forwarder.proposeTreasury, (candidate)));
        if (success != ok) success ? unexpectedSuccesses++ : unexpectedReverts++;
        if (success) {
            proposeTreasuryOk++;
            mPendingTreasury = candidate;
            mTreasuryExecutableAt = block.timestamp + DELAY;
        }
    }

    function executeTreasury(uint256 actorSeed) public {
        Actor a = _pick(actorSeed, _admins());
        bool ok = _isAdmin(a) && mPendingTreasury != address(0) && block.timestamp >= mTreasuryExecutableAt;
        bool success = _call(a, abi.encodeCall(Forwarder.executeTreasuryChange, ()));
        if (success != ok) success ? unexpectedSuccesses++ : unexpectedReverts++;
        if (success) {
            if (block.timestamp < mTreasuryExecutableAt) earlyExecutions++;
            executeTreasuryOk++;
            mTreasury = mPendingTreasury;
            mPendingTreasury = address(0);
            mTreasuryExecutableAt = 0;
        }
    }

    function cancelTreasury(uint256 actorSeed) public {
        Actor a = _pick(actorSeed, _treasuryCancellers());
        bool ok = (_isAdmin(a) || _isGuardian(a)) && mPendingTreasury != address(0);
        bool success = _call(a, abi.encodeCall(Forwarder.cancelTreasuryChange, ()));
        if (success != ok) success ? unexpectedSuccesses++ : unexpectedReverts++;
        if (success) {
            cancelTreasuryOk++;
            mPendingTreasury = address(0);
            mTreasuryExecutableAt = 0;
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Overrides
    // -----------------------------------------------------------------------------------------------------------

    /// @param style 0: improve (lower and/or extend), 1: raise the fixed fee, 2: raise the variable fee, 3: shorten,
    /// 4: random values up to slightly above the global fee, 5: zero recipient.
    function setOverride(
        uint256 actorSeed,
        uint8 recipientSeed,
        uint8 style,
        uint256 fixedSeed,
        uint256 variableSeed,
        uint256 untilSeed
    ) public {
        Actor a = _pick(actorSeed, _managers());
        style = style % 6;
        address recipient = style == 5 ? address(0) : recipients[recipientSeed % 4];
        Override memory current = mOverride[recipient];
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
            next.fixedFee = fixedSeed % (mActive.fixedFee + 2);
            next.variableFee = variableSeed % (mActive.variableFee + 2);
            next.validUntil = block.timestamp + untilSeed % 60 days;
        }
        bool ok = _isManager(a) && recipient != address(0) && next.validUntil > block.timestamp
            && next.fixedFee <= mActive.fixedFee && next.variableFee <= mActive.variableFee
            && (!active
                || (next.fixedFee <= current.fixedFee
                    && next.variableFee <= current.variableFee
                    && next.validUntil >= current.validUntil));
        bool success = _call(
            a,
            abi.encodeCall(Forwarder.setUserFeeOverride, (recipient, next.fixedFee, next.variableFee, next.validUntil))
        );
        if (success != ok) success ? unexpectedSuccesses++ : unexpectedReverts++;
        if (success) {
            if (
                active
                    && (next.fixedFee > current.fixedFee
                        || next.variableFee > current.variableFee
                        || next.validUntil < current.validUntil)
            ) promisesBroken++;
            overrideOk++;
            if (active) overrideImprovedWhileActive++;
            mOverride[recipient] = next;
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Time
    // -----------------------------------------------------------------------------------------------------------

    /// @dev Besides Echidna's random delays, jumps exactly to one second before / at a pending executableAt or an
    /// override expiry.
    function warp(uint256 seed) public {
        uint256 target = block.timestamp + (seed >> 8) % (2 * DELAY);
        uint256 choice = seed % 8;
        Override memory o = mOverride[recipients[(seed >> 4) % 4]];
        if (choice == 0 && mFeeExecutableAt > block.timestamp + 1) target = mFeeExecutableAt - 1;
        else if (choice == 1 && mFeeExecutableAt > block.timestamp) target = mFeeExecutableAt;
        else if (choice == 2 && mTreasuryExecutableAt > block.timestamp + 1) target = mTreasuryExecutableAt - 1;
        else if (choice == 3 && mTreasuryExecutableAt > block.timestamp) target = mTreasuryExecutableAt;
        else if (choice == 4 && o.validUntil > block.timestamp + 1) target = o.validUntil - 1;
        else if (choice == 5 && o.validUntil > block.timestamp) target = o.validUntil;
        else if (choice == 6) target = block.timestamp + (seed >> 8) % 1 hours;
        HEVM.warp(target);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Forward and funds
    // -----------------------------------------------------------------------------------------------------------

    function forward(uint256 amount, uint8 recipientSeed) public {
        amount = amount % 1e13;
        address recipient = recipients[recipientSeed % 4];
        uint256 fee = forwarder.calculateFeeFor(recipient, amount);
        if (fee != _modelFee(recipient, amount) || fee > forwarder.calculateFee(amount)) feeMismatches++;
        if (mPaused && fee != 0) pausedFeeCharged++;

        usdc.mint(address(sra), amount);
        sra.exec(address(usdc), abi.encodeCall(IERC20.approve, (address(forwarder), amount)));
        uint256 recipientBefore = _value(recipient);
        uint256 forwarderBefore = usdc.balanceOf(address(forwarder));
        uint256[3] memory treasuryBefore;
        for (uint256 i = 0; i < 3; ++i) {
            treasuryBefore[i] = _value(treasuries[i]);
        }
        bool success = _call(sra, abi.encodeCall(Forwarder.forward, (address(usdc), amount, recipient)));
        if (!success) {
            if (fee <= amount) unexpectedReverts++;
            return;
        }
        if (fee > amount) {
            unexpectedSuccesses++;
            return;
        }
        forwardOk++;
        (,, uint256 validUntil) = forwarder.userFeeOverrides(recipient);
        if (block.timestamp < validUntil && fee < forwarder.calculateFee(amount)) forwardDiscounted++;
        deposited += amount;
        fees += fee;
        uint256 received = _value(recipient) - recipientBefore;
        userReceived += received;
        if (received != amount - fee) userMismatches++;

        uint256 forwarderAfter = usdc.balanceOf(address(forwarder));
        uint256 activeDelta;
        for (uint256 i = 0; i < 3; ++i) {
            uint256 delta = _value(treasuries[i]) - treasuryBefore[i];
            if (treasuries[i] == mTreasury) activeDelta = delta;
            else if (delta != 0) treasuries[i] == mPendingTreasury ? pendingTreasuryFunded++ : treasuryMismatches++;
        }
        treasuryReceived += activeDelta;
        if (activeDelta + forwarderAfter != forwarderBefore + fee) treasuryMismatches++;
        if (activeDelta != 0 && forwarderAfter != 0) treasuryMismatches++;
    }

    function donate(uint256 amount) public {
        amount = 1 + amount % 1e12;
        usdc.mint(address(forwarder), amount);
        donated += amount;
    }

    function rescueUsdc() public {
        uint256 amount = usdc.balanceOf(address(forwarder));
        uint256[3] memory before;
        for (uint256 i = 0; i < 3; ++i) {
            before[i] = _value(treasuries[i]);
        }
        if (_call(admin, abi.encodeCall(Forwarder.rescueToken, (IERC20(address(usdc)))))) {
            for (uint256 i = 0; i < 3; ++i) {
                uint256 delta = _value(treasuries[i]) - before[i];
                if (treasuries[i] == mTreasury ? delta != amount : delta != 0) rescueMisroutes++;
            }
            if (usdc.balanceOf(address(forwarder)) != 0) rescueMisroutes++;
            treasuryReceived += amount;
        } else if (!usdc.isBlacklisted(mTreasury)) {
            unexpectedReverts++;
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Pause, routing, failures, unauthorized calls
    // -----------------------------------------------------------------------------------------------------------

    function togglePause(uint256 actorSeed) public {
        Actor a = actors[actorSeed % actors.length];
        bool wasPaused = mPaused;
        bool ok = wasPaused ? _isAdmin(a) : (_isAdmin(a) || _isManager(a));
        bytes memory data = wasPaused ? abi.encodeCall(Forwarder.unpause, ()) : abi.encodeCall(Forwarder.pause, ());
        bool success = _call(a, data);
        if (success != ok) success ? unexpectedSuccesses++ : unexpectedReverts++;
        if (success) mPaused = !wasPaused;
    }

    function setRoutingMode(uint8 modeSeed) public {
        if (!_call(admin, abi.encodeCall(Forwarder.setRoutingMode, (Forwarder.RoutingMode(modeSeed % 4))))) {
            unexpectedReverts++;
        }
    }

    function toggleFailure(bool vaultFailure, uint8 seed, bool on) public {
        if (vaultFailure) vault.setDepositReverts(on);
        else usdc.setBlacklisted(treasuries[seed % 3], on);
    }

    function unauthorizedCall(uint256 actorSeed, uint8 selectorSeed, uint256 value) public {
        Actor a = actors[1 + actorSeed % (actors.length - 1)]; // never the admin
        bytes[12] memory candidates = [
            abi.encodeCall(Forwarder.proposeTreasury, (address(a))),
            abi.encodeCall(Forwarder.executeTreasuryChange, ()),
            abi.encodeCall(Forwarder.rescueToken, (IERC20(address(usdc)))),
            abi.encodeCall(Forwarder.setRoutingMode, (Forwarder.RoutingMode(value % 4))),
            abi.encodeCall(Forwarder.unpause, ()),
            abi.encodeCall(IAccessControl.grantRole, (feeManagerRole, address(a))),
            abi.encodeCall(Forwarder.proposeFeeConfig, (Forwarder.FeeModel.FIXED, Forwarder.FeeModel.FIXED, 0, 1, 1)),
            abi.encodeCall(Forwarder.executeFeeConfigChange, ()),
            abi.encodeCall(Forwarder.setUserFeeOverride, (address(a), 0, 0, block.timestamp + 1)),
            abi.encodeCall(Forwarder.pause, ()),
            abi.encodeCall(Forwarder.cancelTreasuryChange, ()),
            abi.encodeCall(Forwarder.cancelFeeConfigChange, ())
        ];
        // Only calls the actor is not allowed to make.
        uint256 limit = _isManager(a) ? 6 : (_isGuardian(a) ? 10 : 12);
        if (_call(a, candidates[selectorSeed % limit])) unexpectedSuccesses++;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Properties
    // -----------------------------------------------------------------------------------------------------------

    function echidna_no_unexpected_outcome() public view returns (bool) {
        return unexpectedReverts == 0 && unexpectedSuccesses == 0;
    }

    function echidna_no_execution_before_the_delay() public view returns (bool) {
        return earlyExecutions == 0;
    }

    function echidna_active_fee_config_matches_model() public view returns (bool) {
        return uint8(forwarder.lowerFeeModel()) == mActive.lower && uint8(forwarder.upperFeeModel()) == mActive.upper
            && forwarder.threshold() == mActive.threshold && forwarder.fixedFee() == mActive.fixedFee
            && forwarder.variableFee() == mActive.variableFee;
    }

    function echidna_pending_fee_config_matches_model() public view returns (bool) {
        (
            Forwarder.FeeModel lower,
            Forwarder.FeeModel upper,
            uint256 threshold,
            uint256 fixedFee,
            uint256 variableFee,
            uint256 executableAt
        ) = forwarder.pendingFeeConfig();
        return executableAt == mFeeExecutableAt && uint8(lower) == mPending.lower && uint8(upper) == mPending.upper
            && threshold == mPending.threshold && fixedFee == mPending.fixedFee && variableFee == mPending.variableFee
            && (executableAt != 0 || uint8(lower) + uint8(upper) + threshold + fixedFee + variableFee == 0);
    }

    function echidna_fee_caps() public view returns (bool) {
        (,,, uint256 pendingFixed, uint256 pendingVariable,) = forwarder.pendingFeeConfig();
        return forwarder.fixedFee() <= 10e6 && forwarder.variableFee() <= 10_000 && pendingFixed <= 10e6
            && pendingVariable <= 10_000;
    }

    function echidna_treasury_matches_model() public view returns (bool) {
        return forwarder.treasury() == mTreasury && forwarder.pendingTreasury() == mPendingTreasury
            && forwarder.pendingTreasuryExecutableAt() == mTreasuryExecutableAt;
    }

    function echidna_treasury_valid() public view returns (bool) {
        address t = forwarder.treasury();
        return t != address(0) && t != address(forwarder);
    }

    function echidna_pending_treasury_never_funded() public view returns (bool) {
        return pendingTreasuryFunded == 0 && rescueMisroutes == 0;
    }

    function echidna_effective_fee_never_above_global() public view returns (bool) {
        if (feeMismatches != 0) return false;
        uint256[6] memory amounts = _amounts();
        for (uint256 r = 0; r < 4; ++r) {
            for (uint256 a = 0; a < 6; ++a) {
                if (forwarder.calculateFeeFor(recipients[r], amounts[a]) > forwarder.calculateFee(amounts[a])) {
                    return false;
                }
            }
        }
        return true;
    }

    function echidna_fee_matches_specification() public view returns (bool) {
        uint256[6] memory amounts = _amounts();
        for (uint256 r = 0; r < 4; ++r) {
            for (uint256 a = 0; a < 6; ++a) {
                if (forwarder.calculateFeeFor(recipients[r], amounts[a]) != _modelFee(recipients[r], amounts[a])) {
                    return false;
                }
            }
        }
        return true;
    }

    function echidna_expired_override_is_global() public view returns (bool) {
        uint256[6] memory amounts = _amounts();
        for (uint256 r = 0; r < 4; ++r) {
            (,, uint256 validUntil) = forwarder.userFeeOverrides(recipients[r]);
            if (block.timestamp < validUntil) continue;
            for (uint256 a = 0; a < 6; ++a) {
                if (forwarder.calculateFeeFor(recipients[r], amounts[a]) != forwarder.calculateFee(amounts[a])) {
                    return false;
                }
            }
        }
        return true;
    }

    function echidna_paused_means_zero_fee() public view returns (bool) {
        if (pausedFeeCharged != 0 || forwarder.paused() != mPaused) return false;
        if (!mPaused) return true;
        uint256[6] memory amounts = _amounts();
        for (uint256 r = 0; r < 4; ++r) {
            for (uint256 a = 0; a < 6; ++a) {
                if (forwarder.calculateFeeFor(recipients[r], amounts[a]) != 0) return false;
            }
        }
        return true;
    }

    function echidna_overrides_match_model_and_promises_hold() public view returns (bool) {
        if (promisesBroken != 0) return false;
        for (uint256 r = 0; r < 4; ++r) {
            (uint256 fixedFee, uint256 variableFee, uint256 validUntil) = forwarder.userFeeOverrides(recipients[r]);
            Override memory m = mOverride[recipients[r]];
            if (fixedFee != m.fixedFee || variableFee != m.variableFee || validUntil != m.validUntil) return false;
        }
        (,, uint256 zeroUntil) = forwarder.userFeeOverrides(address(0));
        return zeroUntil == 0;
    }

    function echidna_user_gets_amount_minus_effective_fee() public view returns (bool) {
        return userMismatches == 0 && deposited == userReceived + fees;
    }

    function echidna_treasury_accounting() public view returns (bool) {
        return treasuryMismatches == 0;
    }

    function echidna_conservation() public view returns (bool) {
        return deposited + donated == userReceived + treasuryReceived + usdc.balanceOf(address(forwarder));
    }

    function echidna_roles_never_change() public view returns (bool) {
        (address pending,) = forwarder.pendingDefaultAdmin();
        if (forwarder.defaultAdmin() != address(admin) || pending != address(0)) return false;
        for (uint256 i = 0; i < actors.length; ++i) {
            address account = address(actors[i]);
            if (forwarder.hasRole(adminRole, account) != _isAdmin(actors[i])) return false;
            if (forwarder.hasRole(feeManagerRole, account) != _isManager(actors[i])) return false;
            if (forwarder.hasRole(guardianRole, account) != _isGuardian(actors[i])) return false;
        }
        return !forwarder.hasRole(feeManagerRole, address(sra)) && !forwarder.hasRole(guardianRole, address(sra));
    }

    function echidna_vault_untouched() public view returns (bool) {
        uint256 allowance = usdc.allowance(address(forwarder), address(vault));
        bool direct = forwarder.routingMode() == Forwarder.RoutingMode.DIRECT_DIRECT;
        return address(forwarder.vault()) == address(vault) && address(forwarder.pendingVault()) == address(0)
            && forwarder.pendingVaultExecutableAt() == 0
            && (direct ? allowance == 0 : allowance > type(uint256).max - 1e30)
            && vault.balanceOf(address(forwarder)) == 0;
    }
}
