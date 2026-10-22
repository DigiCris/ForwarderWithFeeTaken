// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console} from "forge-std/console.sol";

import {Forwarder} from "../src/Forwarder.sol";
import {FeeTreasuryHandler} from "./invariants/FeeTreasuryHandler.sol";
import {ForwarderTestBase} from "./utils/ForwarderTestBase.sol";

/// @dev Stateful invariants of the V3 additions (see FeeTreasuryHandler): delayed fee configuration and treasury
/// changes, per-recipient fee overrides and the `forward` accounting with the effective fee.
contract ForwarderV3InvariantTest is ForwarderTestBase {
    FeeTreasuryHandler internal handler;

    function setUp() public override {
        super.setUp();
        // Like the production management wallets, one account is both fee manager and guardian.
        vm.prank(admin);
        forwarder.grantRole(VAULT_GUARDIAN_ROLE, feeManager2);
        // Start from a non-zero global configuration (applied through the delay) so that overrides matter at once.
        _setFees(FIXED_PLUS_PERCENT, PERCENT, 100e6, 1e6, 1000);
        address[] memory managersOnly = new address[](1);
        managersOnly[0] = feeManager;
        handler =
            new FeeTreasuryHandler(forwarder, usdc, vault, admin, managersOnly, _guardians(), feeManager2, treasury);

        bytes4[] memory selectors = new bytes4[](22);
        selectors[0] = FeeTreasuryHandler.proposeFees.selector;
        selectors[1] = FeeTreasuryHandler.executeFees.selector;
        selectors[2] = FeeTreasuryHandler.executeFees.selector; // executions twice as likely as cancellations
        selectors[3] = FeeTreasuryHandler.cancelFees.selector;
        selectors[4] = FeeTreasuryHandler.proposeTreasury.selector;
        selectors[5] = FeeTreasuryHandler.executeTreasury.selector;
        selectors[6] = FeeTreasuryHandler.executeTreasury.selector;
        selectors[7] = FeeTreasuryHandler.cancelTreasury.selector;
        selectors[8] = FeeTreasuryHandler.setOverride.selector;
        selectors[9] = FeeTreasuryHandler.setOverride.selector;
        selectors[10] = FeeTreasuryHandler.warp.selector;
        selectors[11] = FeeTreasuryHandler.warp.selector;
        selectors[12] = FeeTreasuryHandler.warp.selector;
        selectors[13] = FeeTreasuryHandler.forward.selector;
        selectors[14] = FeeTreasuryHandler.forward.selector;
        selectors[15] = FeeTreasuryHandler.forward.selector;
        selectors[16] = FeeTreasuryHandler.donate.selector;
        selectors[17] = FeeTreasuryHandler.rescueUsdc.selector;
        selectors[18] = FeeTreasuryHandler.togglePause.selector;
        selectors[19] = FeeTreasuryHandler.setRoutingMode.selector;
        selectors[20] = FeeTreasuryHandler.toggleFailure.selector;
        selectors[21] = FeeTreasuryHandler.unauthorizedCall.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function _amounts() internal view returns (uint256[6] memory) {
        uint256 t = forwarder.threshold();
        return [uint256(0), 1, t, t == type(uint256).max ? t : t + 1, 1e9, 1e13];
    }

    function invariant_NoUnexpectedOutcome() public view {
        assertEq(handler.ghostUnexpectedReverts(), 0, "unexpected revert");
        assertEq(handler.ghostUnexpectedSuccesses(), 0, "unexpected success");
    }

    /// @dev No fee configuration or treasury change is ever executed before its executableAt.
    function invariant_NoExecutionBeforeTheDelay() public view {
        assertEq(handler.ghostEarlyExecutions(), 0);
    }

    /// @dev The active fee configuration is exactly the model: it only changes through a matured execution, never
    /// while a change is pending, never through an override.
    function invariant_ActiveFeeConfigurationMatchesTheModel() public view {
        (uint8 lower, uint8 upper, uint256 threshold, uint256 fixedFee, uint256 variableFee) = handler.activeFees();
        assertEq(uint8(forwarder.lowerFeeModel()), lower, "lower");
        assertEq(uint8(forwarder.upperFeeModel()), upper, "upper");
        assertEq(forwarder.threshold(), threshold, "threshold");
        assertEq(forwarder.fixedFee(), fixedFee, "fixed");
        assertEq(forwarder.variableFee(), variableFee, "variable");
    }

    /// @dev The pending fee configuration is the model (all zero when nothing is pending: cleanup), and its
    /// executableAt is always the proposal time plus 72 hours.
    function invariant_PendingFeeConfigurationMatchesTheModel() public view {
        (
            Forwarder.FeeModel lower,
            Forwarder.FeeModel upper,
            uint256 threshold,
            uint256 fixedFee,
            uint256 variableFee,
            uint256 executableAt
        ) = forwarder.pendingFeeConfig();
        (uint8 mLower, uint8 mUpper, uint256 mThreshold, uint256 mFixed, uint256 mVariable) = handler.pendingFees();
        assertEq(executableAt, handler.feeExecutableAt(), "executableAt");
        assertEq(uint8(lower), mLower, "lower");
        assertEq(uint8(upper), mUpper, "upper");
        assertEq(threshold, mThreshold, "threshold");
        assertEq(fixedFee, mFixed, "fixed");
        assertEq(variableFee, mVariable, "variable");
        if (executableAt == 0) {
            assertEq(uint8(lower) + uint8(upper) + threshold + fixedFee + variableFee, 0, "cleanup");
        }
    }

    function invariant_FeeCapsAlwaysHold() public view {
        assertLe(forwarder.fixedFee(), forwarder.MAX_FIXED_FEE());
        assertLe(forwarder.variableFee(), forwarder.MAX_VARIABLE_FEE());
        (,,, uint256 fixedFee, uint256 variableFee,) = forwarder.pendingFeeConfig();
        assertLe(fixedFee, forwarder.MAX_FIXED_FEE());
        assertLe(variableFee, forwarder.MAX_VARIABLE_FEE());
    }

    /// @dev The active treasury only changes through a matured execution; the pending one is the model.
    function invariant_TreasuryMatchesTheModel() public view {
        assertEq(forwarder.treasury(), handler.activeTreasury(), "active");
        assertEq(forwarder.pendingTreasury(), handler.pendingTreasury(), "pending");
        assertEq(forwarder.pendingTreasuryExecutableAt(), handler.treasuryExecutableAt(), "executableAt");
        address current = forwarder.treasury();
        assertTrue(current != address(0) && current != address(forwarder), "valid treasury");
    }

    /// @dev Neither `forward` nor the rescue ever deliver to a treasury that is only pending.
    function invariant_PendingTreasuryNeverReceivesFunds() public view {
        assertEq(handler.ghostPendingTreasuryFunded(), 0, "pending treasury funded");
        assertEq(handler.ghostRescueMisroutes(), 0, "rescue misroute");
    }

    /// @dev Central property: for every recipient and amount, the effective fee never exceeds the global fee and
    /// always matches the specification (global models and threshold, min(override, global), zero while paused).
    function invariant_EffectiveFeeNeverExceedsTheGlobalFee() public view {
        assertEq(handler.ghostFeeMismatches(), 0, "forward fee mismatch");
        uint256[6] memory amounts = _amounts();
        for (uint256 r = 0; r < handler.recipientCount(); ++r) {
            address recipient = handler.recipients(r);
            for (uint256 a = 0; a < amounts.length; ++a) {
                uint256 fee = forwarder.calculateFeeFor(recipient, amounts[a]);
                assertLe(fee, forwarder.calculateFee(amounts[a]), "above global");
                assertEq(fee, handler.modelFee(recipient, amounts[a]), "model");
            }
        }
    }

    function invariant_ExpiredOverrideIsTheGlobalFee() public view {
        uint256[6] memory amounts = _amounts();
        for (uint256 r = 0; r < handler.recipientCount(); ++r) {
            address recipient = handler.recipients(r);
            (,, uint256 validUntil) = forwarder.userFeeOverrides(recipient);
            if (block.timestamp < validUntil) continue;
            for (uint256 a = 0; a < amounts.length; ++a) {
                assertEq(forwarder.calculateFeeFor(recipient, amounts[a]), forwarder.calculateFee(amounts[a]));
            }
        }
    }

    function invariant_PausedMeansZeroFee() public view {
        assertEq(handler.ghostPausedFeeCharged(), 0);
        assertEq(forwarder.paused(), handler.paused());
        if (!forwarder.paused()) return;
        uint256[6] memory amounts = _amounts();
        for (uint256 r = 0; r < handler.recipientCount(); ++r) {
            for (uint256 a = 0; a < amounts.length; ++a) {
                assertEq(forwarder.calculateFeeFor(handler.recipients(r), amounts[a]), 0);
            }
        }
    }

    /// @dev Stored overrides are exactly the model and no active override was ever worsened (raised or shortened).
    function invariant_OverridesMatchTheModelAndPromisesHold() public view {
        assertEq(handler.ghostPromiseBroken(), 0, "promise broken");
        for (uint256 r = 0; r < handler.recipientCount(); ++r) {
            address recipient = handler.recipients(r);
            (uint256 fixedFee, uint256 variableFee, uint256 validUntil) = forwarder.userFeeOverrides(recipient);
            (uint256 mFixed, uint256 mVariable, uint256 mUntil) = handler.overrides(recipient);
            assertEq(fixedFee, mFixed, "fixed");
            assertEq(variableFee, mVariable, "variable");
            assertEq(validUntil, mUntil, "validUntil");
        }
        (,, uint256 zeroUntil) = forwarder.userFeeOverrides(address(0));
        assertEq(zeroUntil, 0, "no override for the zero address");
    }

    /// @dev amount = userAmount + effectiveFee and the user receives exactly userAmount.
    function invariant_UserGetsExactlyAmountMinusEffectiveFee() public view {
        assertEq(handler.ghostUserMismatches(), 0);
        assertEq(handler.ghostDeposited(), handler.ghostUserReceived() + handler.ghostFees());
    }

    /// @dev Fee + previous balance are either delivered (entirely) to the active treasury or kept in the Forwarder.
    function invariant_TreasuryAccounting() public view {
        assertEq(handler.ghostTreasuryMismatches(), 0);
    }

    /// @dev No USDC is created or lost.
    function invariant_Conservation() public view {
        assertEq(
            handler.ghostDeposited() + handler.ghostDonated(),
            handler.ghostUserReceived() + handler.ghostTreasuryReceived() + usdc.balanceOf(address(forwarder))
        );
    }

    function invariant_PrivilegesNeverChange() public view {
        assertEq(forwarder.defaultAdmin(), admin);
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            (address account, bool isAdmin, bool isManager, bool isGuardian) = handler.actorAt(i);
            assertEq(forwarder.hasRole(DEFAULT_ADMIN_ROLE, account), isAdmin, "admin role");
            assertEq(forwarder.hasRole(FEE_MANAGER_ROLE, account), isManager, "fee manager role");
            assertEq(forwarder.hasRole(VAULT_GUARDIAN_ROLE, account), isGuardian, "guardian role");
        }
    }

    /// @dev The V3 functions never touch the vault lifecycle: same vault, nothing pending, allowance per routing.
    function invariant_VaultUntouched() public view {
        assertEq(address(forwarder.vault()), address(vault));
        assertEq(address(forwarder.pendingVault()), address(0));
        assertEq(forwarder.pendingVaultExecutableAt(), 0);
        uint256 allowance = usdc.allowance(address(forwarder), address(vault));
        if (forwarder.routingMode() == DIRECT_DIRECT) assertEq(allowance, 0);
        else assertGt(allowance, MAX - 1e30);
    }

    /// @dev Deterministic walk through every successful path of the handler (seed 1 = first authorized actor): the
    /// invariants above are never vacuous because each of these steps is reachable and passes the model checks.
    function test_HandlerReachesEverySuccessfulPath() public {
        handler.proposeFees(1, 3, 2, 50e6, 2e6, 2000); // fee manager proposes FIXED_PLUS_PERCENT / PERCENT
        handler.warp(1); // to the fee executableAt
        handler.executeFees(1);
        handler.proposeTreasury(1, 1); // admin proposes the second treasury
        handler.warp(3); // to the treasury executableAt
        handler.executeTreasury(1);
        handler.proposeFees(1, 1, 1, 0, 1e6, 0);
        handler.cancelFees(1);
        handler.proposeTreasury(1, 0);
        handler.cancelTreasury(1);
        handler.setOverride(1, 0, 4, 0, 0, 30 days); // zero override for recipient 0
        handler.setOverride(1, 0, 0, 0, 0, 1 days); // extends the active override
        handler.forward(1000e6, 0); // discounted
        handler.forward(1000e6, 1); // global fee
        handler.donate(5e6);
        handler.rescueUsdc();
        handler.togglePause(0); // admin pauses
        handler.forward(1000e6, 1); // no fee while paused
        handler.togglePause(0); // admin unpauses
        handler.setRoutingMode(3); // VAULT_VAULT
        handler.forward(1000e6, 0);
        handler.toggleFailure(0, 1, true); // the active treasury cannot receive USDC
        handler.setRoutingMode(0);
        handler.forward(1000e6, 1); // fee kept in the Forwarder
        handler.toggleFailure(0, 1, false);
        handler.forward(1000e6, 1); // retried with the whole balance
        handler.unauthorizedCall(5, 0, 0); // a stranger tries proposeTreasury

        string[10] memory keys = [
            "proposeFees.ok",
            "executeFees.ok",
            "cancelFees.ok",
            "proposeTreasury.ok",
            "executeTreasury.ok",
            "cancelTreasury.ok",
            "setOverride.ok",
            "setOverride.improvedActive",
            "forward.ok",
            "forward.discounted"
        ];
        for (uint256 i = 0; i < keys.length; ++i) {
            assertGt(handler.calls(bytes32(bytes(keys[i]))), 0, keys[i]);
        }
        invariant_NoUnexpectedOutcome();
        invariant_NoExecutionBeforeTheDelay();
        invariant_ActiveFeeConfigurationMatchesTheModel();
        invariant_PendingFeeConfigurationMatchesTheModel();
        invariant_TreasuryMatchesTheModel();
        invariant_PendingTreasuryNeverReceivesFunds();
        invariant_EffectiveFeeNeverExceedsTheGlobalFee();
        invariant_OverridesMatchTheModelAndPromisesHold();
        invariant_UserGetsExactlyAmountMinusEffectiveFee();
        invariant_TreasuryAccounting();
        invariant_Conservation();
        assertEq(forwarder.treasury(), handler.treasuryCandidates(1));
        assertEq(forwarder.variableFee(), 2000);
    }

    /// @dev Logs what the run exercised (successful lifecycle steps). No assertion: the shape of a run depends on the
    /// fuzzer's randomness, which coverage instrumentation changes.
    function afterInvariant() external view {
        string[12] memory keys = [
            "proposeFees.ok",
            "executeFees.ok",
            "cancelFees.ok",
            "proposeTreasury.ok",
            "executeTreasury.ok",
            "cancelTreasury.ok",
            "setOverride.ok",
            "setOverride.improvedActive",
            "forward.ok",
            "forward.discounted",
            "unauthorizedCall",
            "warp"
        ];
        for (uint256 i = 0; i < keys.length; ++i) {
            console.log(keys[i], handler.calls(bytes32(bytes(keys[i]))));
        }
    }
}
