// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Forwarder} from "../src/Forwarder.sol";
import {MockERC20} from "../test/mocks/MockTokens.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {MockVault, NotAVault} from "../test/mocks/MockVault.sol";
import {Actor, IHevm} from "./ForwarderEchidna.sol";

/**
 * @title ForwarderVaultChangeEchidna
 * @notice Property-based campaign focused on the vault change lifecycle: proposals (valid and invalid candidates),
 * cancellations and executions by every kind of actor, time jumps (random and exactly at the 72-hour boundary),
 * guardian grants/revocations/renouncements, routing changes, candidate failures and recoveries, with forwards and
 * fee/treasury/pause changes interleaved. A reference model predicts every outcome; the `echidna_*` properties must
 * always hold. The initial vault is set by the constructor, as in production.
 */
contract ForwarderVaultChangeEchidna {
    uint256 internal constant TEST_AMOUNT = 1_000;
    uint256 internal constant DELAY = 72 hours;
    uint256 internal constant SHARE_SCALE = 1e12;
    uint256 internal constant MAX = type(uint256).max;
    IHevm internal constant HEVM = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    MockUSDC internal usdc;
    Forwarder internal forwarder;
    MockVault[4] internal vaults; // [0] initial vault, [3] always fails the health check
    address[4] internal invalidCandidates; // EOA, contract without ERC-4626, wrong asset, zero
    Actor internal admin;
    Actor[3] internal guardians; // [0] and [1] granted at deployment, [2] not
    Actor internal feeManager;
    Actor internal feeManagerGuardian; // holds both FEE_MANAGER_ROLE and VAULT_GUARDIAN_ROLE
    Actor internal stranger;
    Actor internal sra;
    Actor[7] internal actors;
    address internal constant USER = address(0xA001);
    address[2] internal treasuries;
    bytes32 internal guardianRole;
    bytes32 internal adminRole;

    // Reference model.
    address internal mVault;
    address internal mPending;
    uint256 internal mExecutableAt;
    uint256 internal mProposedAt;
    Forwarder.RoutingMode internal mMode;
    bytes32 internal mConfig;
    mapping(address => bool) internal mGuardian;
    mapping(address => uint256) internal mAllowance;
    mapping(address => uint8) internal failureFlags;

    // Violation counters.
    uint256 internal unexpectedOutcomes;
    uint256 internal earlyExecutions;
    uint256 internal vaultChangedOutsideExecute;
    uint256 internal delayTampering;
    uint256 internal failedExecuteMutations;
    uint256 internal pendingAllowanceViolations;
    uint256 internal configTouched;
    uint256 internal unauthorizedSuccesses;
    uint256 internal forwarderFundsUsed;
    uint256 internal userMismatches;

    // Progress counters (visible in the coverage report).
    uint256 internal proposeOk;
    uint256 internal cancelOk;
    uint256 internal executeOk;
    uint256 internal executeEarlyRejected;
    uint256 internal executeUnhealthyRejected;

    struct Snapshot {
        address vault;
        address pending;
        uint256 executableAt;
        uint256 activeAllowance;
        bytes32 config;
        Forwarder.RoutingMode mode;
        uint256 forwarderUsdc;
    }

    constructor() {
        usdc = new MockUSDC(); // nonce 1
        vaults[0] = new MockVault(IERC20(address(usdc))); // nonce 2
        admin = new Actor(); // nonce 3
        guardians[0] = new Actor(); // nonce 4
        guardians[1] = new Actor(); // nonce 5
        feeManager = new Actor(); // nonce 6
        feeManagerGuardian = new Actor(); // nonce 7

        address[] memory managers = new address[](2);
        managers[0] = address(feeManager);
        managers[1] = address(feeManagerGuardian);
        address[] memory initialGuardians = new address[](3);
        initialGuardians[0] = address(guardians[0]);
        initialGuardians[1] = address(guardians[1]);
        initialGuardians[2] = address(feeManagerGuardian);
        treasuries = [address(0x7000), address(0x7001)];

        // The constructor health check of the initial vault is funded by this contract (nonce 8 deploys it).
        address predicted = _createAddress(8);
        usdc.mint(address(this), TEST_AMOUNT);
        usdc.approve(predicted, TEST_AMOUNT);
        forwarder = new Forwarder(
            IERC20(address(usdc)),
            address(admin),
            3 days,
            treasuries[0],
            IERC4626(address(vaults[0])),
            Forwarder.RoutingMode.DIRECT_DIRECT,
            managers,
            initialGuardians
        );
        require(address(forwarder) == predicted, "harness: unexpected Forwarder address");

        for (uint256 i = 1; i < 4; ++i) {
            vaults[i] = new MockVault(IERC20(address(usdc)));
        }
        vaults[3].setRedeemReverts(true);
        invalidCandidates[0] = address(0xE0A);
        invalidCandidates[1] = address(new NotAVault());
        invalidCandidates[2] = address(new MockVault(IERC20(address(new MockERC20("Other", "OTH", 6)))));
        invalidCandidates[3] = address(0);
        guardians[2] = new Actor();
        stranger = new Actor();
        sra = new Actor();
        actors = [admin, guardians[0], guardians[1], guardians[2], feeManager, feeManagerGuardian, stranger];

        guardianRole = forwarder.VAULT_GUARDIAN_ROLE();
        adminRole = forwarder.DEFAULT_ADMIN_ROLE();
        mGuardian[address(guardians[0])] = true;
        mGuardian[address(guardians[1])] = true;
        mGuardian[address(feeManagerGuardian)] = true;
        mVault = address(vaults[0]);
        mMode = Forwarder.RoutingMode.DIRECT_DIRECT;
        mConfig = _configHash();
    }

    // -----------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------

    function _createAddress(uint8 nonce) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), address(this), nonce)))));
    }

    function _call(Actor actor, bytes memory data) internal returns (bool success) {
        (success,) = actor.exec(address(forwarder), data);
    }

    function _fund(Actor actor) internal {
        usdc.mint(address(actor), TEST_AMOUNT);
        actor.exec(address(usdc), abi.encodeCall(IERC20.approve, (address(forwarder), TEST_AMOUNT)));
    }

    function _clearFunding(Actor actor) internal {
        actor.exec(address(usdc), abi.encodeCall(IERC20.approve, (address(forwarder), 0)));
    }

    function _usesVault(Forwarder.RoutingMode mode) internal pure returns (bool) {
        return mode != Forwarder.RoutingMode.DIRECT_DIRECT;
    }

    function _configHash() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                forwarder.treasury(),
                forwarder.lowerFeeModel(),
                forwarder.upperFeeModel(),
                forwarder.threshold(),
                forwarder.fixedFee(),
                forwarder.variableFee(),
                forwarder.paused()
            )
        );
    }

    function _isVault(address candidate) internal view returns (bool) {
        for (uint256 i = 0; i < 4; ++i) {
            if (address(vaults[i]) == candidate) return true;
        }
        return false;
    }

    function _healthy(address candidate) internal view returns (bool) {
        return _isVault(candidate) && candidate != address(vaults[3]) && failureFlags[candidate] == 0;
    }

    function _lifecycleActor(uint8 seed) internal view returns (Actor) {
        return seed % 3 == 0 ? actors[(seed / 3) % 7] : admin;
    }

    function _candidate(uint8 seed) internal view returns (address) {
        if (seed % 3 == 0) {
            uint8 index = (seed / 3) % 8;
            return index < 4 ? address(vaults[index]) : invalidCandidates[index - 4];
        }
        return address(vaults[(seed / 3) % 4]);
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        s.vault = address(forwarder.vault());
        s.pending = address(forwarder.pendingVault());
        s.executableAt = forwarder.pendingVaultExecutableAt();
        s.activeAllowance = usdc.allowance(address(forwarder), s.vault);
        s.config = _configHash();
        s.mode = forwarder.routingMode();
        s.forwarderUsdc = usdc.balanceOf(address(forwarder));
    }

    function _checkUntouched(Snapshot memory before) internal {
        if (address(forwarder.vault()) != before.vault) vaultChangedOutsideExecute++;
        if (address(forwarder.pendingVault()) != before.pending) delayTampering++;
        if (forwarder.pendingVaultExecutableAt() != before.executableAt) delayTampering++;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Lifecycle actions
    // -----------------------------------------------------------------------------------------------------------

    function propose(uint8 actorSeed, uint8 candidateSeed) public {
        Actor actor = _lifecycleActor(actorSeed);
        address candidate = _candidate(candidateSeed);
        bool authorized = actor == admin;
        bool expected = authorized && mPending == address(0) && candidate != mVault && _healthy(candidate);
        _fund(actor);
        Snapshot memory before = _snapshot();

        bool success = _call(actor, abi.encodeCall(Forwarder.proposeVault, (IERC4626(candidate))));
        if (success != expected) unexpectedOutcomes++;
        if (success && !authorized) unauthorizedSuccesses++;
        if (success) {
            proposeOk++;
            if (address(forwarder.pendingVault()) != candidate) unexpectedOutcomes++;
            if (forwarder.pendingVaultExecutableAt() != block.timestamp + DELAY) delayTampering++;
            if (address(forwarder.vault()) != before.vault) vaultChangedOutsideExecute++;
            if (usdc.allowance(address(forwarder), before.vault) != before.activeAllowance) unexpectedOutcomes++;
            if (usdc.allowance(address(forwarder), candidate) != 0) pendingAllowanceViolations++;
            if (_configHash() != before.config || forwarder.routingMode() != before.mode) configTouched++;
            mPending = candidate;
            mExecutableAt = block.timestamp + DELAY;
            mProposedAt = block.timestamp;
        } else {
            _checkUntouched(before);
        }
        if (usdc.balanceOf(address(forwarder)) != before.forwarderUsdc) forwarderFundsUsed++;
        _clearFunding(actor);
    }

    function cancel(uint8 actorSeed) public {
        Actor actor = actors[actorSeed % 7];
        bool authorized = actor == admin || mGuardian[address(actor)];
        bool expected = authorized && mPending != address(0);
        Snapshot memory before = _snapshot();

        bool success = _call(actor, abi.encodeCall(Forwarder.cancelVaultChange, ()));
        if (success != expected) unexpectedOutcomes++;
        if (success && !authorized) unauthorizedSuccesses++;
        if (success) {
            cancelOk++;
            if (address(forwarder.pendingVault()) != address(0) || forwarder.pendingVaultExecutableAt() != 0) {
                unexpectedOutcomes++;
            }
            if (address(forwarder.vault()) != before.vault) vaultChangedOutsideExecute++;
            if (usdc.allowance(address(forwarder), before.vault) != before.activeAllowance) unexpectedOutcomes++;
            if (_configHash() != before.config || forwarder.routingMode() != before.mode) configTouched++;
            mPending = address(0);
            mExecutableAt = 0;
            mProposedAt = 0;
        } else {
            _checkUntouched(before);
        }
    }

    function execute(uint8 actorSeed) public {
        Actor actor = _lifecycleActor(actorSeed);
        bool authorized = actor == admin;
        bool early = block.timestamp < mExecutableAt;
        bool expected = authorized && mPending != address(0) && !early && _healthy(mPending);
        if (authorized && mPending != address(0) && early) executeEarlyRejected++;
        if (authorized && mPending != address(0) && !early && !_healthy(mPending)) executeUnhealthyRejected++;
        _fund(actor);
        Snapshot memory before = _snapshot();

        bool success = _call(actor, abi.encodeCall(Forwarder.executeVaultChange, ()));
        if (success != expected) unexpectedOutcomes++;
        if (success && !authorized) unauthorizedSuccesses++;
        if (success) {
            executeOk++;
            if (block.timestamp < before.executableAt) earlyExecutions++;
            if (address(forwarder.vault()) != before.pending) unexpectedOutcomes++;
            if (address(forwarder.pendingVault()) != address(0) || forwarder.pendingVaultExecutableAt() != 0) {
                unexpectedOutcomes++;
            }
            if (usdc.allowance(address(forwarder), before.vault) != 0) unexpectedOutcomes++;
            uint256 expectedAllowance = _usesVault(forwarder.routingMode()) ? MAX : 0;
            if (usdc.allowance(address(forwarder), before.pending) != expectedAllowance) unexpectedOutcomes++;
            if (_configHash() != before.config || forwarder.routingMode() != before.mode) configTouched++;
            mAllowance[before.vault] = 0;
            mAllowance[before.pending] = expectedAllowance;
            mVault = before.pending;
            mPending = address(0);
            mExecutableAt = 0;
            mProposedAt = 0;
        } else {
            _checkUntouched(before);
            if (usdc.allowance(address(forwarder), before.vault) != before.activeAllowance) failedExecuteMutations++;
            if (before.pending != address(0) && usdc.allowance(address(forwarder), before.pending) != 0) {
                failedExecuteMutations++;
            }
        }
        if (usdc.balanceOf(address(forwarder)) != before.forwarderUsdc) forwarderFundsUsed++;
        _clearFunding(actor);
    }

    /// @dev Time jump: random, or exactly to `executableAt - 1`, `executableAt` or beyond it.
    function warp(uint32 seed, uint8 choice) public {
        Snapshot memory before = _snapshot();
        uint256 target = block.timestamp + uint256(seed) % (2 * DELAY);
        if (mExecutableAt != 0) {
            choice = choice % 4;
            if (choice == 1 && mExecutableAt - 1 > block.timestamp) target = mExecutableAt - 1;
            if (choice == 2 && mExecutableAt > block.timestamp) target = mExecutableAt;
            if (choice == 3 && mExecutableAt > block.timestamp) target = mExecutableAt + uint256(seed) % DELAY;
        }
        HEVM.warp(target);
        _checkUntouched(before);
    }

    function setGuardian(uint8 accountSeed, bool grant) public {
        Actor account = actors[1 + accountSeed % 6];
        Snapshot memory before = _snapshot();
        bytes memory data = grant
            ? abi.encodeCall(IAccessControl.grantRole, (guardianRole, address(account)))
            : abi.encodeCall(IAccessControl.revokeRole, (guardianRole, address(account)));
        if (!_call(admin, data)) unexpectedOutcomes++;
        mGuardian[address(account)] = grant;
        _checkUntouched(before);
    }

    function renounceGuardian(uint8 accountSeed) public {
        Actor account = actors[1 + accountSeed % 6];
        Snapshot memory before = _snapshot();
        if (!_call(account, abi.encodeCall(IAccessControl.renounceRole, (guardianRole, address(account))))) {
            unexpectedOutcomes++;
        }
        mGuardian[address(account)] = false;
        _checkUntouched(before);
    }

    /// @dev Non-admin actors try the admin-only lifecycle functions, routing and guardian management.
    function unauthorizedCall(uint8 actorSeed, uint8 selectorSeed, uint8 candidateSeed) public {
        Actor actor = actors[1 + actorSeed % 6];
        uint8 s = selectorSeed % 5;
        bytes memory data;
        if (s == 0) data = abi.encodeCall(Forwarder.proposeVault, (IERC4626(_candidate(candidateSeed))));
        else if (s == 1) data = abi.encodeCall(Forwarder.executeVaultChange, ());
        else if (s == 2) data = abi.encodeCall(Forwarder.setRoutingMode, (Forwarder.RoutingMode(candidateSeed % 4)));
        else if (s == 3) data = abi.encodeCall(IAccessControl.grantRole, (guardianRole, address(actor)));
        else data = abi.encodeCall(IAccessControl.revokeRole, (guardianRole, address(guardians[0])));
        _fund(actor);
        Snapshot memory before = _snapshot();
        if (_call(actor, data)) unauthorizedSuccesses++;
        _checkUntouched(before);
        _clearFunding(actor);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Routing, candidate state and V1 operations interleaved with the lifecycle
    // -----------------------------------------------------------------------------------------------------------

    function setRoutingMode(uint8 modeSeed) public {
        Forwarder.RoutingMode mode = Forwarder.RoutingMode(modeSeed % 4);
        Snapshot memory before = _snapshot();
        if (_call(admin, abi.encodeCall(Forwarder.setRoutingMode, (mode)))) {
            if (_usesVault(mMode) != _usesVault(mode)) mAllowance[mVault] = _usesVault(mode) ? MAX : 0;
            mMode = mode;
        } else {
            unexpectedOutcomes++;
        }
        _checkUntouched(before);
        if (before.pending != address(0) && usdc.allowance(address(forwarder), before.pending) != 0) {
            pendingAllowanceViolations++;
        }
    }

    function toggleFailure(uint8 vaultSeed, uint8 kind, bool on) public {
        MockVault v = vaults[vaultSeed % 3];
        kind = kind % 5;
        // Deposits without shares break the trusted-vault assumption of `forward`: only on non-active vaults.
        if (kind == 3 && address(v) == mVault) return;
        if (kind == 0) v.setDepositReverts(on);
        else if (kind == 1) v.setRedeemReverts(on);
        else if (kind == 2) v.setPaused(on);
        else if (kind == 3) v.setMintsNoShares(on);
        else v.setRedeemPaysNothing(on);
        uint8 bit = uint8(1 << kind);
        failureFlags[address(v)] = on ? failureFlags[address(v)] | bit : failureFlags[address(v)] & ~bit;
    }

    function forward(uint64 amount) public {
        uint256 value = uint256(amount) % 1e12;
        uint256 fee = forwarder.calculateFee(value);
        if (fee > value) return;
        Snapshot memory before = _snapshot();
        uint256 vaultUsdcBefore = usdc.balanceOf(mVault);
        uint256 userBefore = usdc.balanceOf(USER) + MockVault(mVault).balanceOf(USER) / SHARE_SCALE;
        usdc.mint(address(sra), value);
        sra.exec(address(usdc), abi.encodeCall(IERC20.approve, (address(forwarder), value)));
        if (_call(sra, abi.encodeCall(Forwarder.forward, (address(usdc), value, USER)))) {
            uint256 userAfter = usdc.balanceOf(USER) + MockVault(mVault).balanceOf(USER) / SHARE_SCALE;
            if (userAfter - userBefore != value - fee) userMismatches++;
        } else {
            unexpectedOutcomes++;
        }
        if (_usesVault(mMode)) mAllowance[mVault] -= usdc.balanceOf(mVault) - vaultUsdcBefore;
        _checkUntouched(before);
        if (before.pending != address(0) && usdc.allowance(address(forwarder), before.pending) != 0) {
            pendingAllowanceViolations++;
        }
    }

    function setFees(uint8 lower, uint8 upper, uint64 threshold, uint32 fixedFee, uint16 variableFee) public {
        Snapshot memory before = _snapshot();
        bytes memory data = abi.encodeCall(
            Forwarder.setFeeConfig,
            (
                Forwarder.FeeModel(lower % 4),
                Forwarder.FeeModel(upper % 4),
                uint256(threshold) % 1e12,
                uint256(fixedFee) % 10e6,
                uint256(variableFee) % 10_000
            )
        );
        if (!_call(feeManager, data)) unexpectedOutcomes++;
        mConfig = _configHash();
        _checkUntouched(before);
    }

    function togglePause() public {
        Snapshot memory before = _snapshot();
        bytes memory data =
            forwarder.paused() ? abi.encodeCall(Forwarder.unpause, ()) : abi.encodeCall(Forwarder.pause, ());
        if (!_call(admin, data)) unexpectedOutcomes++;
        mConfig = _configHash();
        _checkUntouched(before);
    }

    function setTreasury(uint8 seed) public {
        Snapshot memory before = _snapshot();
        if (!_call(admin, abi.encodeCall(Forwarder.setTreasury, (treasuries[seed % 2])))) unexpectedOutcomes++;
        mConfig = _configHash();
        _checkUntouched(before);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Properties: vault change lifecycle
    // -----------------------------------------------------------------------------------------------------------

    function echidna_pending_vault_and_timestamp_consistent() public view returns (bool) {
        return (address(forwarder.pendingVault()) == address(0)) == (forwarder.pendingVaultExecutableAt() == 0);
    }

    function echidna_executable_at_is_proposal_time_plus_72h() public view returns (bool) {
        if (address(forwarder.pendingVault()) == address(0)) return true;
        return forwarder.pendingVaultExecutableAt() == mProposedAt + DELAY;
    }

    function echidna_pending_vault_is_not_the_active_vault() public view returns (bool) {
        address pending = address(forwarder.pendingVault());
        return pending == address(0) || pending != address(forwarder.vault());
    }

    function echidna_active_vault_only_changes_through_execute() public view returns (bool) {
        return vaultChangedOutsideExecute == 0 && address(forwarder.vault()) == mVault
            && address(forwarder.pendingVault()) == mPending && forwarder.pendingVaultExecutableAt() == mExecutableAt;
    }

    function echidna_no_execution_before_the_delay() public view returns (bool) {
        return earlyExecutions == 0;
    }

    function echidna_pending_vault_has_no_allowance() public view returns (bool) {
        address pending = address(forwarder.pendingVault());
        if (pendingAllowanceViolations != 0) return false;
        return pending == address(0) || usdc.allowance(address(forwarder), pending) == 0;
    }

    function echidna_allowances() public view returns (bool) {
        address active = address(forwarder.vault());
        bool direct = !_usesVault(forwarder.routingMode());
        for (uint256 i = 0; i < 4; ++i) {
            address v = address(vaults[i]);
            uint256 allowance = usdc.allowance(address(forwarder), v);
            if (allowance != mAllowance[v]) return false;
            if ((v != active || direct) && allowance != 0) return false;
        }
        return true;
    }

    function echidna_lifecycle_authorization() public view returns (bool) {
        return unauthorizedSuccesses == 0;
    }

    function echidna_pending_change_never_tampered() public view returns (bool) {
        return delayTampering == 0;
    }

    function echidna_failed_execution_keeps_state() public view returns (bool) {
        return failedExecuteMutations == 0;
    }

    function echidna_lifecycle_keeps_fees_treasury_pause_routing() public view returns (bool) {
        return configTouched == 0 && _configHash() == mConfig && forwarder.routingMode() == mMode;
    }

    function echidna_outcomes_match_model() public view returns (bool) {
        return unexpectedOutcomes == 0 && forwarderFundsUsed == 0;
    }

    function echidna_roles_match_model() public view returns (bool) {
        if (forwarder.defaultAdmin() != address(admin)) return false;
        if (forwarder.getRoleAdmin(guardianRole) != adminRole) return false;
        for (uint256 i = 1; i < 7; ++i) {
            address a = address(actors[i]);
            if (forwarder.hasRole(guardianRole, a) != mGuardian[a]) return false;
            if (forwarder.hasRole(adminRole, a)) return false;
        }
        return true;
    }

    function echidna_delay_is_72_hours() public view returns (bool) {
        return forwarder.VAULT_CHANGE_DELAY() == 72 hours;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Properties: V1 regression kept because they are cheap
    // -----------------------------------------------------------------------------------------------------------

    function echidna_user_gets_amount_minus_fee() public view returns (bool) {
        return userMismatches == 0;
    }

    function echidna_vault_mode_has_vault() public view returns (bool) {
        return !_usesVault(forwarder.routingMode()) || address(forwarder.vault()) != address(0);
    }

    function echidna_fee_caps() public view returns (bool) {
        return forwarder.variableFee() <= 10_000 && forwarder.fixedFee() <= 10e6;
    }

    function echidna_treasury_valid() public view returns (bool) {
        address t = forwarder.treasury();
        return t != address(0) && t != address(forwarder);
    }

    function echidna_forwarder_holds_no_shares() public view returns (bool) {
        for (uint256 i = 0; i < 4; ++i) {
            if (vaults[i].balanceOf(address(forwarder)) != 0) return false;
        }
        return true;
    }
}
