// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {stdError} from "forge-std/StdError.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Forwarder} from "../src/Forwarder.sol";
import {MockVault} from "./mocks/MockVault.sol";
import {ForwarderTestBase} from "./utils/ForwarderTestBase.sol";

/**
 * @dev Targeted fuzzing of the vault change lifecycle only (propose / cancel / execute, the 72-hour boundary,
 * guardians, routing while pending, the second health check). The V1 fee, accounting, treasury and rescue campaigns
 * are not repeated here: that code is unchanged.
 */
contract ForwarderVaultChangeFuzzTest is ForwarderTestBase {
    MockVault internal candidate;

    function setUp() public override {
        super.setUp();
        candidate = new MockVault(IERC20(address(usdc)));
    }

    function _expectUnauthorized(address account, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role));
    }

    function _allowance(address spender) internal view returns (uint256) {
        return usdc.allowance(address(forwarder), spender);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Delay
    // -----------------------------------------------------------------------------------------------------------

    /// @dev Before `executableAt` the execution always reverts and changes nothing; from it on, it succeeds.
    function testFuzz_DelayBoundary(uint256 proposedAt, uint256 elapsed) public {
        proposedAt = bound(proposedAt, 1, type(uint64).max);
        elapsed = bound(elapsed, 0, 4 * VAULT_CHANGE_DELAY);
        _assertBoundary(proposedAt, elapsed);
    }

    /// @dev Same property concentrated on the seconds around the boundary.
    function testFuzz_DelayBoundaryNeighbourhood(uint256 proposedAt, uint256 offset) public {
        proposedAt = bound(proposedAt, 1, type(uint64).max);
        offset = bound(offset, 0, 4000);
        _assertBoundary(proposedAt, VAULT_CHANGE_DELAY - 2000 + offset);
    }

    function _assertBoundary(uint256 proposedAt, uint256 elapsed) internal {
        vm.warp(proposedAt);
        _proposeVault(address(candidate));
        uint256 executableAt = forwarder.pendingVaultExecutableAt();
        assertEq(executableAt, proposedAt + VAULT_CHANGE_DELAY);

        vm.warp(proposedAt + elapsed);
        _fundAdminForHealthCheck();
        if (elapsed < VAULT_CHANGE_DELAY) {
            vm.expectRevert(abi.encodeWithSelector(Forwarder.VaultChangeDelayNotElapsed.selector, executableAt));
            vm.prank(admin);
            forwarder.executeVaultChange();
            assertEq(address(forwarder.vault()), address(vault));
            assertEq(address(forwarder.pendingVault()), address(candidate));
            assertEq(forwarder.pendingVaultExecutableAt(), executableAt);
        } else {
            vm.prank(admin);
            forwarder.executeVaultChange();
            assertEq(address(forwarder.vault()), address(candidate));
            assertEq(address(forwarder.pendingVault()), address(0));
            assertEq(forwarder.pendingVaultExecutableAt(), 0);
        }
    }

    /// @dev `executableAt` is exactly the proposal timestamp plus 72 hours, for any timestamp.
    function testFuzz_ExecutableAtIsProposalTimePlusDelay(uint256 proposedAt) public {
        proposedAt = bound(proposedAt, 0, type(uint256).max - VAULT_CHANGE_DELAY);
        vm.warp(proposedAt);
        _proposeVault(address(candidate));
        assertEq(forwarder.pendingVaultExecutableAt(), proposedAt + VAULT_CHANGE_DELAY);
    }

    /// @dev Checked arithmetic: no timestamp can make `executableAt` wrap around to an earlier time.
    function testFuzz_ExecutableAtCannotOverflow(uint256 proposedAt) public {
        proposedAt = bound(proposedAt, type(uint256).max - VAULT_CHANGE_DELAY + 1, type(uint256).max);
        vm.warp(proposedAt);
        _fundAdminForHealthCheck();
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(admin);
        forwarder.proposeVault(IERC4626(address(candidate)));
        assertEq(address(forwarder.pendingVault()), address(0));
    }

    // -----------------------------------------------------------------------------------------------------------
    // Authorization
    // -----------------------------------------------------------------------------------------------------------

    /// @dev Nobody but the default admin proposes or executes, whatever other roles the caller holds.
    function testFuzz_OnlyAdminProposesOrExecutes(address caller, bool asGuardian, bool asFeeManager) public {
        vm.assume(caller != admin && caller != address(0) && caller != address(forwarder));
        assumeNotForgeAddress(caller);
        vm.startPrank(admin);
        if (asGuardian) forwarder.grantRole(VAULT_GUARDIAN_ROLE, caller);
        if (asFeeManager) forwarder.grantRole(FEE_MANAGER_ROLE, caller);
        vm.stopPrank();
        usdc.mint(caller, 2 * TEST_AMOUNT);
        vm.prank(caller);
        usdc.approve(address(forwarder), 2 * TEST_AMOUNT);

        _expectUnauthorized(caller, DEFAULT_ADMIN_ROLE);
        vm.prank(caller);
        forwarder.proposeVault(IERC4626(address(candidate)));
        assertEq(address(forwarder.pendingVault()), address(0));

        _proposeVault(address(candidate));
        uint256 executableAt = forwarder.pendingVaultExecutableAt();
        vm.warp(executableAt);
        _expectUnauthorized(caller, DEFAULT_ADMIN_ROLE);
        vm.prank(caller);
        forwarder.executeVaultChange();
        assertEq(address(forwarder.vault()), address(vault));
        assertEq(address(forwarder.pendingVault()), address(candidate));
        assertEq(forwarder.pendingVaultExecutableAt(), executableAt);
    }

    /// @dev Cancel succeeds iff the caller is the admin or a current guardian, at any time while pending.
    function testFuzz_CancelAuthorization(address caller, bool asGuardian, bool asFeeManager, uint256 elapsed) public {
        vm.assume(caller != address(0) && caller != address(forwarder));
        assumeNotForgeAddress(caller);
        vm.startPrank(admin);
        if (asGuardian) forwarder.grantRole(VAULT_GUARDIAN_ROLE, caller);
        if (asFeeManager && caller != admin) forwarder.grantRole(FEE_MANAGER_ROLE, caller);
        vm.stopPrank();
        bool allowed = caller == admin || forwarder.hasRole(VAULT_GUARDIAN_ROLE, caller);

        _proposeVault(address(candidate));
        uint256 executableAt = forwarder.pendingVaultExecutableAt();
        vm.warp(block.timestamp + bound(elapsed, 0, 10 * VAULT_CHANGE_DELAY));
        vm.prank(caller);
        (bool success,) = address(forwarder).call(abi.encodeCall(Forwarder.cancelVaultChange, ()));
        assertEq(success, allowed);
        assertEq(address(forwarder.vault()), address(vault));
        if (allowed) {
            assertEq(address(forwarder.pendingVault()), address(0));
            assertEq(forwarder.pendingVaultExecutableAt(), 0);
        } else {
            assertEq(address(forwarder.pendingVault()), address(candidate));
            assertEq(forwarder.pendingVaultExecutableAt(), executableAt);
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Guardians
    // -----------------------------------------------------------------------------------------------------------

    /// @dev Any sequence of guardian grants, revocations and renouncements keeps `executableAt`, and the execution
    /// still waits for it even with no guardian left.
    function testFuzz_GuardianChangesKeepTheDelay(uint8[10] memory ops, uint256 earlyElapsed) public {
        address[4] memory pool = [guardian, guardian2, makeAddr("g3"), feeManager];
        _proposeVault(address(candidate));
        uint256 proposedAt = block.timestamp;
        uint256 executableAt = forwarder.pendingVaultExecutableAt();
        for (uint256 i = 0; i < ops.length; ++i) {
            address account = pool[(ops[i] >> 2) % pool.length];
            uint8 kind = ops[i] % 4;
            if (kind == 0) {
                vm.prank(admin);
                forwarder.grantRole(VAULT_GUARDIAN_ROLE, account);
            } else if (kind == 1) {
                vm.prank(admin);
                forwarder.revokeRole(VAULT_GUARDIAN_ROLE, account);
            } else if (kind == 2) {
                vm.prank(account);
                forwarder.renounceRole(VAULT_GUARDIAN_ROLE, account);
            } else {
                vm.startPrank(admin);
                for (uint256 j = 0; j < pool.length; ++j) {
                    forwarder.revokeRole(VAULT_GUARDIAN_ROLE, pool[j]);
                }
                vm.stopPrank();
            }
            assertEq(forwarder.pendingVaultExecutableAt(), executableAt);
            assertEq(address(forwarder.pendingVault()), address(candidate));
        }
        vm.warp(proposedAt + bound(earlyElapsed, 0, VAULT_CHANGE_DELAY - 1));
        _fundAdminForHealthCheck();
        vm.expectRevert(abi.encodeWithSelector(Forwarder.VaultChangeDelayNotElapsed.selector, executableAt));
        vm.prank(admin);
        forwarder.executeVaultChange();
        vm.warp(executableAt);
        vm.prank(admin);
        forwarder.executeVaultChange();
        assertEq(address(forwarder.vault()), address(candidate));
    }

    // -----------------------------------------------------------------------------------------------------------
    // Routing while pending and allowances
    // -----------------------------------------------------------------------------------------------------------

    /// @dev Routing changes while pending never touch the candidate; the execution applies the final routing.
    function testFuzz_RoutingWhilePending(uint8 modeAtProposal, uint8[6] memory modesWhilePending) public {
        _setRouting(Forwarder.RoutingMode(modeAtProposal % 4));
        _proposeVault(address(candidate));
        Forwarder.RoutingMode mode = forwarder.routingMode();
        for (uint256 i = 0; i < modesWhilePending.length; ++i) {
            mode = Forwarder.RoutingMode(modesWhilePending[i] % 4);
            _setRouting(mode);
            assertEq(_allowance(address(candidate)), 0, "pending vault allowance");
            assertEq(_allowance(address(vault)), _usesVault(mode) ? MAX : 0, "active vault allowance");
        }
        vm.warp(forwarder.pendingVaultExecutableAt());
        _executeVaultChange();
        assertEq(_allowance(address(vault)), 0, "old vault allowance");
        assertEq(_allowance(address(candidate)), _usesVault(mode) ? MAX : 0, "new vault allowance");
        assertEq(uint8(forwarder.routingMode()), uint8(mode));
    }

    /// @dev A failed second health check reverts entirely; the same proposal executes once the candidate recovers.
    function testFuzz_FailedSecondHealthCheckKeepsPending(uint8 failureKind, uint256 extraDelay, uint8 modeSeed)
        public
    {
        Forwarder.RoutingMode mode = Forwarder.RoutingMode(modeSeed % 4);
        _setRouting(mode);
        _proposeVault(address(candidate));
        uint256 executableAt = forwarder.pendingVaultExecutableAt();
        uint256 activeAllowance = _allowance(address(vault));
        uint8 kind = failureKind % 5;
        _setFailure(kind, true);

        vm.warp(executableAt + bound(extraDelay, 0, 365 days));
        _fundAdminForHealthCheck();
        vm.prank(admin);
        (bool success,) = address(forwarder).call(abi.encodeCall(Forwarder.executeVaultChange, ()));
        assertFalse(success);
        assertEq(address(forwarder.vault()), address(vault));
        assertEq(_allowance(address(vault)), activeAllowance);
        assertEq(_allowance(address(candidate)), 0);
        assertEq(address(forwarder.pendingVault()), address(candidate));
        assertEq(forwarder.pendingVaultExecutableAt(), executableAt);

        _setFailure(kind, false);
        vm.prank(admin);
        forwarder.executeVaultChange();
        assertEq(address(forwarder.vault()), address(candidate));
        assertEq(_allowance(address(vault)), 0);
        assertEq(_allowance(address(candidate)), _usesVault(mode) ? MAX : 0);
    }

    function _setFailure(uint8 kind, bool on) internal {
        if (kind == 0) candidate.setDepositReverts(on);
        else if (kind == 1) candidate.setRedeemReverts(on);
        else if (kind == 2) candidate.setPaused(on);
        else if (kind == 3) candidate.setMintsNoShares(on);
        else candidate.setRedeemPaysNothing(on);
    }

    // -----------------------------------------------------------------------------------------------------------
    // State machine against a reference model
    // -----------------------------------------------------------------------------------------------------------

    struct Model {
        address vault;
        address pending;
        uint256 executableAt;
        Forwarder.RoutingMode mode;
    }

    MockVault[3] internal pool;
    address[6] internal actors;
    mapping(address => bool) internal broken;
    mapping(address => bool) internal isGuardian;

    /// @dev Random sequences of proposals, cancellations, executions (by any actor), time jumps (including exact
    /// boundaries), guardian grants/revocations, routing changes, candidate failures/recoveries and forwards. The
    /// model predicts the outcome of every step and the full vault state is compared after each one.
    function testFuzz_LifecycleStateMachine(uint256[32] memory ops) public {
        pool = [MockVault(address(vault)), new MockVault(IERC20(address(usdc))), new MockVault(IERC20(address(usdc)))];
        actors = [admin, guardian, guardian2, feeManager, stranger, makeAddr("g3")];
        isGuardian[guardian] = true;
        isGuardian[guardian2] = true;
        Model memory m = Model(address(vault), address(0), 0, DIRECT_DIRECT);

        for (uint256 i = 0; i < ops.length; ++i) {
            uint256 op = ops[i];
            uint256 kind = op % 9;
            // Half of the steps are sent by the admin so that successful lifecycles are frequent.
            address actor = (op >> 8) % 2 == 0 ? admin : actors[(op >> 9) % actors.length];
            address target = address(pool[(op >> 16) % pool.length]);
            if (kind == 0) _stepPropose(m, actor, target);
            else if (kind == 1) _stepCancel(m, actor);
            else if (kind == 2) _stepExecute(m, actor);
            else if (kind == 3) _stepWarp(m, op >> 24);
            else if (kind == 4) _stepGuardian(actor, (op >> 24) % 2 == 0);
            else if (kind == 5) _stepRouting(m, Forwarder.RoutingMode((op >> 24) % 4));
            else if (kind == 6) _stepBreak(target, (op >> 24) % 2 == 0);
            else if (kind == 7) _forward(bound(op >> 24, 0, 1000e6), user);
            else _stepWarp(m, 2); // jump exactly to executableAt when a change is pending
            _assertModel(m);
        }
    }

    function _healthy(address target) internal view returns (bool) {
        return !broken[target];
    }

    function _stepPropose(Model memory m, address actor, address target) internal {
        bool expected = actor == admin && m.pending == address(0) && target != m.vault && _healthy(target);
        usdc.mint(actor, TEST_AMOUNT);
        vm.prank(actor);
        usdc.approve(address(forwarder), TEST_AMOUNT);
        vm.prank(actor);
        (bool success,) = address(forwarder).call(abi.encodeCall(Forwarder.proposeVault, (IERC4626(target))));
        assertEq(success, expected, "propose outcome");
        if (success) {
            m.pending = target;
            m.executableAt = block.timestamp + VAULT_CHANGE_DELAY;
        }
    }

    function _stepCancel(Model memory m, address actor) internal {
        bool expected = (actor == admin || isGuardian[actor]) && m.pending != address(0);
        vm.prank(actor);
        (bool success,) = address(forwarder).call(abi.encodeCall(Forwarder.cancelVaultChange, ()));
        assertEq(success, expected, "cancel outcome");
        if (success) {
            m.pending = address(0);
            m.executableAt = 0;
        }
    }

    function _stepExecute(Model memory m, address actor) internal {
        bool expected =
            actor == admin && m.pending != address(0) && block.timestamp >= m.executableAt && _healthy(m.pending);
        usdc.mint(actor, TEST_AMOUNT);
        vm.prank(actor);
        usdc.approve(address(forwarder), TEST_AMOUNT);
        vm.prank(actor);
        (bool success,) = address(forwarder).call(abi.encodeCall(Forwarder.executeVaultChange, ()));
        assertEq(success, expected, "execute outcome");
        if (success) {
            assertGe(block.timestamp, m.executableAt, "executed before the delay");
            m.vault = m.pending;
            m.pending = address(0);
            m.executableAt = 0;
        }
    }

    function _stepWarp(Model memory m, uint256 seed) internal {
        uint256 choice = seed % 4;
        uint256 target = block.timestamp + (seed >> 2) % (2 * VAULT_CHANGE_DELAY);
        if (m.executableAt != 0 && choice == 1 && m.executableAt - 1 > block.timestamp) target = m.executableAt - 1;
        if (m.executableAt != 0 && choice == 2 && m.executableAt > block.timestamp) target = m.executableAt;
        vm.warp(target);
    }

    function _stepGuardian(address account, bool grant) internal {
        vm.prank(admin);
        if (grant) forwarder.grantRole(VAULT_GUARDIAN_ROLE, account);
        else forwarder.revokeRole(VAULT_GUARDIAN_ROLE, account);
        isGuardian[account] = grant;
    }

    function _stepRouting(Model memory m, Forwarder.RoutingMode mode) internal {
        _setRouting(mode);
        m.mode = mode;
    }

    function _stepBreak(address target, bool on) internal {
        MockVault(target).setRedeemReverts(on);
        broken[target] = on;
    }

    function _assertModel(Model memory m) internal view {
        assertEq(address(forwarder.vault()), m.vault, "active vault");
        assertEq(address(forwarder.pendingVault()), m.pending, "pending vault");
        assertEq(forwarder.pendingVaultExecutableAt(), m.executableAt, "executableAt");
        assertEq(uint8(forwarder.routingMode()), uint8(m.mode), "routing");
        for (uint256 i = 0; i < pool.length; ++i) {
            address v = address(pool[i]);
            uint256 allowance = _allowance(v);
            if (v == m.vault && _usesVault(m.mode)) assertGt(allowance, MAX / 2, "active vault allowance");
            else assertEq(allowance, 0, "allowance of a non-active vault, pending vault or DIRECT_DIRECT");
        }
        for (uint256 i = 0; i < actors.length; ++i) {
            if (actors[i] != admin) assertEq(forwarder.hasRole(VAULT_GUARDIAN_ROLE, actors[i]), isGuardian[actors[i]]);
        }
        assertEq(usdc.balanceOf(address(forwarder)), 0, "Forwarder holds USDC");
    }
}
