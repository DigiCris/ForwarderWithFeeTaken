// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Forwarder} from "../../src/Forwarder.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockVault} from "../mocks/MockVault.sol";

/**
 * @dev Stateful handler of the vault change lifecycle: proposals (valid and invalid candidates), cancellations and
 * executions by every kind of actor, time jumps (including the exact boundaries), guardian grants, revocations and
 * renouncements, routing changes, candidate failures and recoveries, and forwards/fee/treasury changes in between.
 * A reference model predicts every outcome; any divergence increments a ghost counter that must stay at zero.
 * It never reverts.
 */
contract VaultChangeHandler is Test {
    uint256 internal constant TEST_AMOUNT = 1000;
    uint256 internal constant DELAY = 72 hours;
    uint256 internal constant MAX = type(uint256).max;

    Forwarder public immutable forwarder;
    MockUSDC public immutable usdc;
    address public immutable admin;
    address public immutable feeManager;

    MockVault[] public vaults; // vaults[0] is the initial vault; the last one always fails the health check
    address[] public candidates; // the vaults plus invalid candidates (EOA, contract without ERC-4626, wrong asset, zero)
    address[] public actors; // admin, guardians, a fee manager, a fee manager that is also a guardian, strangers
    address public sra = makeAddr("lifecycle-sra");
    address public user = makeAddr("lifecycle-user");
    address[2] public treasuries;

    // Reference model.
    address public ghostVault;
    address public ghostPending;
    uint256 public ghostExecutableAt;
    uint256 public ghostProposedAt;
    Forwarder.RoutingMode public ghostMode;
    bytes32 public ghostConfig;
    mapping(address => bool) public ghostGuardian;
    mapping(address => uint256) public ghostAllowance;
    mapping(address => uint8) public failureFlags;

    // Violations: must remain zero.
    uint256 public ghostUnexpectedOutcomes;
    uint256 public ghostEarlyExecutions;
    uint256 public ghostVaultChangedOutsideExecute;
    uint256 public ghostDelayTampering;
    uint256 public ghostFailedExecuteMutations;
    uint256 public ghostPendingAllowance;
    uint256 public ghostConfigTouched;
    uint256 public ghostUnauthorizedSuccesses;
    uint256 public ghostForwarderFundsUsed;

    mapping(bytes32 => uint256) public calls;

    struct Snapshot {
        address vault;
        address pending;
        uint256 executableAt;
        uint256 activeAllowance;
        uint256 pendingAllowance;
        bytes32 config;
        uint256 forwarderUsdc;
    }

    constructor(
        Forwarder forwarder_,
        MockUSDC usdc_,
        address admin_,
        MockVault[] memory vaults_,
        address[] memory invalidCandidates,
        address[] memory guardians,
        address feeManager_,
        address feeManagerGuardian,
        address treasury
    ) {
        forwarder = forwarder_;
        usdc = usdc_;
        admin = admin_;
        feeManager = feeManager_;
        for (uint256 i = 0; i < vaults_.length; ++i) {
            vaults.push(vaults_[i]);
            candidates.push(address(vaults_[i]));
        }
        for (uint256 i = 0; i < invalidCandidates.length; ++i) {
            candidates.push(invalidCandidates[i]);
        }
        actors.push(admin_);
        for (uint256 i = 0; i < guardians.length; ++i) {
            actors.push(guardians[i]);
            ghostGuardian[guardians[i]] = true;
        }
        actors.push(makeAddr("not-yet-guardian"));
        actors.push(feeManager_);
        actors.push(feeManagerGuardian);
        ghostGuardian[feeManagerGuardian] = true;
        actors.push(makeAddr("lifecycle-stranger"));
        treasuries = [treasury, makeAddr("lifecycle-treasury2")];

        ghostVault = address(forwarder_.vault());
        ghostMode = forwarder_.routingMode();
        ghostAllowance[ghostVault] = usdc_.allowance(address(forwarder_), ghostVault);
        ghostConfig = configHash();
    }

    // -----------------------------------------------------------------------------------------------------------
    // Views used by the invariants
    // -----------------------------------------------------------------------------------------------------------

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function configHash() public view returns (bytes32) {
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

    function _usesVault(Forwarder.RoutingMode mode) internal pure returns (bool) {
        return mode != Forwarder.RoutingMode.DIRECT_DIRECT;
    }

    function _isVault(address candidate) internal view returns (bool) {
        for (uint256 i = 0; i < vaults.length; ++i) {
            if (address(vaults[i]) == candidate) return true;
        }
        return false;
    }

    /// @dev The health check passes for one of the healthy vaults without failure flags.
    function _healthy(address candidate) internal view returns (bool) {
        return _isVault(candidate) && candidate != address(vaults[vaults.length - 1]) && failureFlags[candidate] == 0;
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        s.vault = address(forwarder.vault());
        s.pending = address(forwarder.pendingVault());
        s.executableAt = forwarder.pendingVaultExecutableAt();
        s.activeAllowance = usdc.allowance(address(forwarder), s.vault);
        s.pendingAllowance = s.pending == address(0) ? 0 : usdc.allowance(address(forwarder), s.pending);
        s.config = configHash();
        s.forwarderUsdc = usdc.balanceOf(address(forwarder));
    }

    function _fund(address account) internal {
        usdc.mint(account, TEST_AMOUNT);
        vm.prank(account);
        usdc.approve(address(forwarder), TEST_AMOUNT);
    }

    function _clearFunding(address account) internal {
        vm.prank(account);
        usdc.approve(address(forwarder), 0);
    }

    /// @dev Every action that is not a lifecycle transition must leave the vault and the pending change untouched.
    function _checkUntouched(Snapshot memory before) internal {
        if (address(forwarder.vault()) != before.vault) ghostVaultChangedOutsideExecute++;
        if (address(forwarder.pendingVault()) != before.pending) ghostDelayTampering++;
        if (forwarder.pendingVaultExecutableAt() != before.executableAt) ghostDelayTampering++;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Lifecycle actions
    // -----------------------------------------------------------------------------------------------------------

    /// @dev Two thirds of the lifecycle calls are sent by the admin so that complete lifecycles are frequent.
    function _lifecycleActor(uint256 seed) internal view returns (address) {
        return seed % 3 == 0 ? actors[(seed / 3) % actors.length] : admin;
    }

    /// @dev Two thirds of the proposals target one of the vaults; the rest any candidate (invalid ones included).
    function _candidate(uint256 seed) internal view returns (address) {
        return seed % 3 == 0 ? candidates[(seed / 3) % candidates.length] : address(vaults[(seed / 3) % vaults.length]);
    }

    function propose(uint256 actorSeed, uint256 candidateSeed) external {
        calls["propose"]++;
        address actor = _lifecycleActor(actorSeed);
        address candidate = _candidate(candidateSeed);
        bool authorized = actor == admin;
        bool expected = authorized && ghostPending == address(0) && candidate != ghostVault && _healthy(candidate);
        _fund(actor);
        Snapshot memory before = _snapshot();

        vm.prank(actor);
        (bool success,) = address(forwarder).call(abi.encodeCall(Forwarder.proposeVault, (IERC4626(candidate))));
        if (success != expected) ghostUnexpectedOutcomes++;
        if (success && !authorized) ghostUnauthorizedSuccesses++;

        if (success) {
            calls["proposeOk"]++;
            if (address(forwarder.pendingVault()) != candidate) ghostUnexpectedOutcomes++;
            if (forwarder.pendingVaultExecutableAt() != block.timestamp + DELAY) ghostDelayTampering++;
            if (address(forwarder.vault()) != before.vault) ghostVaultChangedOutsideExecute++;
            if (usdc.allowance(address(forwarder), before.vault) != before.activeAllowance) ghostUnexpectedOutcomes++;
            if (usdc.allowance(address(forwarder), candidate) != 0) ghostPendingAllowance++;
            if (configHash() != before.config) ghostConfigTouched++;
            if (forwarder.routingMode() != ghostMode) ghostConfigTouched++;
            ghostPending = candidate;
            ghostExecutableAt = block.timestamp + DELAY;
            ghostProposedAt = block.timestamp;
        } else {
            _checkUntouched(before);
        }
        if (usdc.balanceOf(address(forwarder)) != before.forwarderUsdc) ghostForwarderFundsUsed++;
        _clearFunding(actor);
    }

    function cancel(uint256 actorSeed) external {
        calls["cancel"]++;
        address actor = actors[actorSeed % actors.length];
        bool authorized = actor == admin || ghostGuardian[actor];
        bool expected = authorized && ghostPending != address(0);
        Snapshot memory before = _snapshot();

        vm.prank(actor);
        (bool success,) = address(forwarder).call(abi.encodeCall(Forwarder.cancelVaultChange, ()));
        if (success != expected) ghostUnexpectedOutcomes++;
        if (success && !authorized) ghostUnauthorizedSuccesses++;

        if (success) {
            calls["cancelOk"]++;
            if (address(forwarder.pendingVault()) != address(0) || forwarder.pendingVaultExecutableAt() != 0) {
                ghostUnexpectedOutcomes++;
            }
            if (address(forwarder.vault()) != before.vault) ghostVaultChangedOutsideExecute++;
            if (usdc.allowance(address(forwarder), before.vault) != before.activeAllowance) ghostUnexpectedOutcomes++;
            if (configHash() != before.config || forwarder.routingMode() != ghostMode) ghostConfigTouched++;
            ghostPending = address(0);
            ghostExecutableAt = 0;
            ghostProposedAt = 0;
        } else {
            _checkUntouched(before);
        }
    }

    function execute(uint256 actorSeed) external {
        calls["execute"]++;
        address actor = _lifecycleActor(actorSeed);
        bool authorized = actor == admin;
        bool early = block.timestamp < ghostExecutableAt;
        bool expected = authorized && ghostPending != address(0) && !early && _healthy(ghostPending);
        if (authorized && ghostPending != address(0) && early) calls["executeEarlyAttempt"]++;
        if (authorized && ghostPending != address(0) && !early && !_healthy(ghostPending)) {
            calls["executeUnhealthyAttempt"]++;
        }
        _fund(actor);
        Snapshot memory before = _snapshot();

        vm.prank(actor);
        (bool success,) = address(forwarder).call(abi.encodeCall(Forwarder.executeVaultChange, ()));
        if (success != expected) ghostUnexpectedOutcomes++;
        if (success && !authorized) ghostUnauthorizedSuccesses++;

        if (success) {
            calls["executeOk"]++;
            if (block.timestamp < before.executableAt) ghostEarlyExecutions++;
            if (address(forwarder.vault()) != before.pending) ghostUnexpectedOutcomes++;
            if (address(forwarder.pendingVault()) != address(0) || forwarder.pendingVaultExecutableAt() != 0) {
                ghostUnexpectedOutcomes++;
            }
            if (usdc.allowance(address(forwarder), before.vault) != 0) ghostUnexpectedOutcomes++;
            uint256 expectedAllowance = _usesVault(forwarder.routingMode()) ? MAX : 0;
            if (usdc.allowance(address(forwarder), before.pending) != expectedAllowance) ghostUnexpectedOutcomes++;
            if (configHash() != before.config || forwarder.routingMode() != ghostMode) ghostConfigTouched++;
            ghostAllowance[before.vault] = 0;
            ghostAllowance[before.pending] = expectedAllowance;
            ghostVault = before.pending;
            ghostPending = address(0);
            ghostExecutableAt = 0;
            ghostProposedAt = 0;
        } else {
            _checkUntouched(before);
            if (usdc.allowance(address(forwarder), before.vault) != before.activeAllowance) {
                ghostFailedExecuteMutations++;
            }
            if (before.pending != address(0) && usdc.allowance(address(forwarder), before.pending) != 0) {
                ghostFailedExecuteMutations++;
            }
        }
        if (usdc.balanceOf(address(forwarder)) != before.forwarderUsdc) ghostForwarderFundsUsed++;
        _clearFunding(actor);
    }

    /// @dev Moves time forward: randomly, or exactly to `executableAt - 1`, `executableAt`, or beyond it.
    function warp(uint256 seed) external {
        calls["warp"]++;
        Snapshot memory before = _snapshot();
        uint256 choice = seed % 4;
        uint256 target = block.timestamp + (seed >> 2) % (2 * DELAY);
        if (ghostExecutableAt != 0) {
            if (choice == 1 && ghostExecutableAt - 1 > block.timestamp) target = ghostExecutableAt - 1;
            if (choice == 2 && ghostExecutableAt > block.timestamp) target = ghostExecutableAt;
            if (choice == 3 && ghostExecutableAt > block.timestamp) target = ghostExecutableAt + (seed >> 2) % DELAY;
        }
        vm.warp(target);
        _checkUntouched(before);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Guardians
    // -----------------------------------------------------------------------------------------------------------

    function setGuardian(uint256 accountSeed, bool grant) external {
        calls["setGuardian"]++;
        address account = actors[accountSeed % actors.length];
        if (account == admin) return;
        Snapshot memory before = _snapshot();
        bytes32 role = forwarder.VAULT_GUARDIAN_ROLE();
        vm.prank(admin);
        if (grant) forwarder.grantRole(role, account);
        else forwarder.revokeRole(role, account);
        ghostGuardian[account] = grant;
        _checkUntouched(before);
    }

    function renounceGuardian(uint256 accountSeed) external {
        calls["renounceGuardian"]++;
        address account = actors[accountSeed % actors.length];
        if (account == admin) return;
        Snapshot memory before = _snapshot();
        bytes32 role = forwarder.VAULT_GUARDIAN_ROLE();
        vm.prank(account);
        forwarder.renounceRole(role, account);
        ghostGuardian[account] = false;
        _checkUntouched(before);
    }

    /// @dev Non-admin actors try the admin-only lifecycle functions and the guardian role management.
    function unauthorizedCall(uint256 actorSeed, uint8 selectorSeed, uint256 candidateSeed) external {
        calls["unauthorizedCall"]++;
        address actor = actors[1 + actorSeed % (actors.length - 1)];
        bytes32 role = forwarder.VAULT_GUARDIAN_ROLE();
        bytes memory data;
        uint8 s = selectorSeed % 5;
        if (s == 0) {
            data = abi.encodeCall(Forwarder.proposeVault, (IERC4626(candidates[candidateSeed % candidates.length])));
        } else if (s == 1) {
            data = abi.encodeCall(Forwarder.executeVaultChange, ());
        } else if (s == 2) {
            data = abi.encodeCall(Forwarder.setRoutingMode, (Forwarder.RoutingMode(candidateSeed % 4)));
        } else if (s == 3) {
            data = abi.encodeCall(IAccessControl.grantRole, (role, actor));
        } else {
            data = abi.encodeCall(IAccessControl.revokeRole, (role, actors[1]));
        }
        _fund(actor);
        Snapshot memory before = _snapshot();
        vm.prank(actor);
        (bool success,) = address(forwarder).call(data);
        if (success) ghostUnauthorizedSuccesses++;
        _checkUntouched(before);
        _clearFunding(actor);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Routing and candidate state
    // -----------------------------------------------------------------------------------------------------------

    function setRoutingMode(uint8 modeSeed) external {
        calls["setRoutingMode"]++;
        Forwarder.RoutingMode mode = Forwarder.RoutingMode(modeSeed % 4);
        Snapshot memory before = _snapshot();
        vm.prank(admin);
        try forwarder.setRoutingMode(mode) {
            if (_usesVault(ghostMode) != _usesVault(mode)) ghostAllowance[ghostVault] = _usesVault(mode) ? MAX : 0;
            ghostMode = mode;
        } catch {
            ghostUnexpectedOutcomes++;
        }
        _checkUntouched(before);
        if (before.pending != address(0) && usdc.allowance(address(forwarder), before.pending) != 0) {
            ghostPendingAllowance++;
        }
    }

    /// @dev Failure injection and recovery on a vault (the active one, the pending one or another candidate).
    function toggleFailure(uint256 vaultSeed, uint8 kind, bool on) external {
        calls["toggleFailure"]++;
        MockVault v = vaults[vaultSeed % (vaults.length - 1)];
        kind = kind % 5;
        // A vault that accepts deposits without minting shares breaks the trusted-vault assumption of `forward`; it
        // is only injected on vaults that are not active (it makes their health check fail).
        if (kind == 3 && address(v) == ghostVault) return;
        if (kind == 0) v.setDepositReverts(on);
        else if (kind == 1) v.setRedeemReverts(on);
        else if (kind == 2) v.setPaused(on);
        else if (kind == 3) v.setMintsNoShares(on);
        else v.setRedeemPaysNothing(on);
        uint8 bit = uint8(1 << kind);
        failureFlags[address(v)] = on ? failureFlags[address(v)] | bit : failureFlags[address(v)] & ~bit;
    }

    // -----------------------------------------------------------------------------------------------------------
    // V1 operations interleaved with the lifecycle (interaction checks only)
    // -----------------------------------------------------------------------------------------------------------

    function forward(uint256 amount) external {
        calls["forward"]++;
        amount = bound(amount, 0, 1e12);
        // `bound` logs through the console; nothing below is pranked before the explicit startPrank.
        uint256 fee = forwarder.calculateFeeFor(user, amount);
        if (fee > amount) return;
        Snapshot memory before = _snapshot();
        uint256 vaultUsdcBefore = usdc.balanceOf(ghostVault);
        uint256 userBefore =
            usdc.balanceOf(user) + (ghostVault == address(0) ? 0 : MockVault(ghostVault).balanceOf(user) / 1e12);
        usdc.mint(sra, amount);
        vm.startPrank(sra);
        usdc.approve(address(forwarder), amount);
        try forwarder.forward(address(usdc), amount, user) {
            uint256 userAfter =
                usdc.balanceOf(user) + (ghostVault == address(0) ? 0 : MockVault(ghostVault).balanceOf(user) / 1e12);
            if (userAfter - userBefore != amount - fee) ghostUnexpectedOutcomes++;
        } catch {
            ghostUnexpectedOutcomes++;
        }
        vm.stopPrank();
        if (_usesVault(ghostMode) && ghostVault != address(0)) {
            ghostAllowance[ghostVault] -= usdc.balanceOf(ghostVault) - vaultUsdcBefore;
        }
        _checkUntouched(before);
        if (before.pending != address(0) && usdc.allowance(address(forwarder), before.pending) != 0) {
            ghostPendingAllowance++;
        }
    }

    /// @dev Fee configuration through its delayed lifecycle, interleaved with the vault lifecycle: proposes when
    /// nothing is pending, executes a matured proposal, cancels an immature one (time only advances via `warp`).
    function setFees(uint8 lower, uint8 upper, uint256 threshold, uint256 fixedFee, uint256 variableFee) external {
        calls["setFees"]++;
        Snapshot memory before = _snapshot();
        threshold = bound(threshold, 0, 1e12);
        fixedFee = bound(fixedFee, 0, 10e6);
        variableFee = bound(variableFee, 0, 10_000);
        (,,,,, uint256 executableAt) = forwarder.pendingFeeConfig();
        vm.prank(feeManager);
        if (executableAt == 0) {
            forwarder.proposeFeeConfig(
                Forwarder.FeeModel(lower % 4), Forwarder.FeeModel(upper % 4), threshold, fixedFee, variableFee
            );
        } else if (block.timestamp >= executableAt) {
            forwarder.executeFeeConfigChange();
        } else {
            forwarder.cancelFeeConfigChange();
        }
        ghostConfig = configHash();
        _checkUntouched(before);
    }

    function togglePause() external {
        calls["togglePause"]++;
        Snapshot memory before = _snapshot();
        bool paused = forwarder.paused();
        vm.prank(admin);
        if (paused) forwarder.unpause();
        else forwarder.pause();
        ghostConfig = configHash();
        _checkUntouched(before);
    }

    /// @dev Treasury through its delayed lifecycle, same pattern as `setFees`.
    function setTreasury(uint256 seed) external {
        calls["setTreasury"]++;
        Snapshot memory before = _snapshot();
        address pending = forwarder.pendingTreasury();
        uint256 executableAt = forwarder.pendingTreasuryExecutableAt();
        vm.prank(admin);
        if (pending == address(0)) forwarder.proposeTreasury(treasuries[seed % 2]);
        else if (block.timestamp >= executableAt) forwarder.executeTreasuryChange();
        else forwarder.cancelTreasuryChange();
        ghostConfig = configHash();
        _checkUntouched(before);
    }
}
