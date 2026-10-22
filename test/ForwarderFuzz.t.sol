// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Forwarder} from "../src/Forwarder.sol";
import {MockVault} from "./mocks/MockVault.sol";
import {MockERC20} from "./mocks/MockTokens.sol";
import {ForwarderTestBase} from "./utils/ForwarderTestBase.sol";

contract ForwarderFuzzTest is ForwarderTestBase {
    uint256 internal constant SHARE_SCALE = 1e12;

    struct FeeInput {
        uint8 lower;
        uint8 upper;
        uint256 threshold;
        uint256 fixedFee;
        uint256 variableFee;
        bool paused;
    }

    function _applyFees(FeeInput memory f) internal returns (FeeInput memory) {
        f.lower = uint8(bound(f.lower, 0, 3));
        f.upper = uint8(bound(f.upper, 0, 3));
        f.fixedFee = bound(f.fixedFee, 0, 10e6);
        f.variableFee = bound(f.variableFee, 0, 10_000);
        _setFees(Forwarder.FeeModel(f.lower), Forwarder.FeeModel(f.upper), f.threshold, f.fixedFee, f.variableFee);
        if (f.paused) {
            vm.prank(feeManager);
            forwarder.pause();
        }
        return f;
    }

    function _expected(FeeInput memory f, uint256 amount) internal pure returns (uint256) {
        return _referenceFee(
            Forwarder.FeeModel(f.lower),
            Forwarder.FeeModel(f.upper),
            f.threshold,
            f.fixedFee,
            f.variableFee,
            f.paused,
            amount
        );
    }

    /// @dev The fee equals the specification for any configuration accepted by the setters.
    function testFuzz_CalculateFeeMatchesSpecification(FeeInput memory f, uint256 amount) public {
        f = _applyFees(f);
        amount = bound(amount, 0, type(uint128).max);
        assertEq(forwarder.calculateFee(amount), _expected(f, amount));
    }

    /// @dev The selected model is applied to the whole amount, never to the part above the threshold.
    function testFuzz_FeeAboveThresholdUsesFullAmount(uint256 thresholdValue, uint256 amount, uint256 variableFee)
        public
    {
        thresholdValue = bound(thresholdValue, 0, 1e15);
        amount = bound(amount, thresholdValue + 1, 1e18);
        variableFee = bound(variableFee, 1, 10_000);
        _setFees(NONE, PERCENT, thresholdValue, 0, variableFee);
        assertEq(forwarder.calculateFee(amount), amount * variableFee / 100_000);
        assertEq(forwarder.calculateFee(thresholdValue), 0);
    }

    function testFuzz_FeeIsBoundedByCaps(FeeInput memory f, uint256 amount) public {
        f = _applyFees(f);
        amount = bound(amount, 0, type(uint128).max);
        assertLe(forwarder.calculateFee(amount), 10e6 + amount / 10);
    }

    function testFuzz_PausedFeeIsZero(FeeInput memory f, uint256 amount) public {
        f.paused = true;
        f = _applyFees(f);
        assertEq(forwarder.calculateFee(amount), 0);
    }

    /// @dev Overflow is only possible for amounts far above any USDC supply; it then reverts (checked arithmetic).
    function testFuzz_CalculateFeeNeverRevertsForRealisticAmounts(FeeInput memory f, uint256 amount) public {
        f = _applyFees(f);
        amount = bound(amount, 0, type(uint256).max / 10_000);
        forwarder.calculateFee(amount);
    }

    function testFuzz_SetterBounds(uint256 variableFee, uint256 fixedFee) public {
        vm.startPrank(feeManager);
        if (variableFee > 10_000) {
            vm.expectRevert(abi.encodeWithSelector(Forwarder.VariableFeeTooHigh.selector, variableFee));
        }
        forwarder.setVariableFee(variableFee);
        if (fixedFee > 10e6) vm.expectRevert(abi.encodeWithSelector(Forwarder.FixedFeeTooHigh.selector, fixedFee));
        forwarder.setFixedFee(fixedFee);
        vm.stopPrank();
        assertLe(forwarder.variableFee(), 10_000);
        assertLe(forwarder.fixedFee(), 10e6);
    }

    /// @dev Full forward accounting for every routing mode, fee configuration, donation and failure combination.
    function testFuzz_ForwardAccounting(
        FeeInput memory f,
        uint256 amount,
        uint8 modeSeed,
        uint256 donation,
        bool userDepositFails,
        bool treasuryFails
    ) public {
        f = _applyFees(f);
        amount = bound(amount, 0, 1e15); // up to 1 billion USDC
        donation = bound(donation, 0, 1e12);
        Forwarder.RoutingMode mode = Forwarder.RoutingMode(bound(modeSeed, 0, 3));
        _setRouting(mode);
        if (donation != 0) usdc.mint(address(forwarder), donation);
        if (userDepositFails) vault.setBlockedReceiver(user);
        if (treasuryFails) {
            if (_treasuryUsesVault(mode)) vault.setDepositReverts(true);
            else usdc.setBlacklisted(treasury, true);
        }

        uint256 fee = _expected(f, amount);
        _fundSra(amount);
        vm.prank(sra);
        if (fee > amount) {
            vm.expectRevert();
            forwarder.forward(address(usdc), amount, user);
            assertEq(usdc.balanceOf(sra), amount);
            return;
        }
        forwarder.forward(address(usdc), amount, user);
        uint256 userAmount = amount - fee;

        // The caller paid exactly `amount`.
        assertEq(usdc.balanceOf(sra), 0);

        // The user receives exactly `amount - fee`, as shares or as USDC (fallback included).
        bool userGetsShares = _userUsesVault(mode) && !userDepositFails && !(treasuryFails && _treasuryUsesVault(mode));
        if (userGetsShares) {
            assertEq(vault.balanceOf(user), userAmount * SHARE_SCALE);
            assertEq(usdc.balanceOf(user), 0);
        } else {
            assertEq(usdc.balanceOf(user), userAmount);
            assertEq(vault.balanceOf(user), 0);
        }

        // Everything else (fee + donation) is either delivered to the treasury or kept for a retry.
        uint256 rest = fee + donation;
        uint256 treasuryValue = usdc.balanceOf(treasury) + vault.balanceOf(treasury) / SHARE_SCALE;
        assertEq(treasuryValue + usdc.balanceOf(address(forwarder)), rest);
        if (rest == 0 || !treasuryFails) {
            assertEq(usdc.balanceOf(address(forwarder)), 0);
            assertEq(treasuryValue, rest);
        } else {
            assertEq(usdc.balanceOf(address(forwarder)), rest);
            assertEq(treasuryValue, 0);
        }
        assertEq(vault.balanceOf(address(forwarder)), 0);
    }

    function testFuzz_RevertWhen_TokenIsNotUsdc(address token, uint256 amount) public {
        vm.assume(token != address(usdc));
        vm.expectRevert(abi.encodeWithSelector(Forwarder.UnsupportedToken.selector, token));
        forwarder.forward(token, amount, user);
    }

    function testFuzz_AnyValidRecipient(address recipient, uint256 amount) public {
        vm.assume(recipient != address(0) && recipient != address(forwarder) && recipient != sra);
        amount = bound(amount, 0, 1e15);
        uint256 before = usdc.balanceOf(recipient);
        _forward(amount, recipient);
        assertEq(usdc.balanceOf(recipient) - before, amount);
    }

    /// @dev Random sequences of routing modes always leave the expected allowance on the vault.
    function testFuzz_RoutingSequenceAllowance(uint8[8] memory seeds) public {
        for (uint256 i = 0; i < seeds.length; ++i) {
            Forwarder.RoutingMode mode = Forwarder.RoutingMode(bound(seeds[i], 0, 3));
            _setRouting(mode);
            assertEq(usdc.allowance(address(forwarder), address(vault)), _usesVault(mode) ? MAX : 0);
        }
    }

    /// @dev Both health checks (proposal and execution) accept any positive amount returned by the round trip.
    function testFuzz_HealthCheckAcceptsAnyPositiveReturn(uint256 lossBps) public {
        lossBps = bound(lossBps, 0, 10_000);
        MockVault candidate = new MockVault(IERC20(address(usdc)));
        candidate.setRedeemLossBps(lossBps);
        uint256 expectedAssets = TEST_AMOUNT * (10_000 - lossBps) / 10_000;
        _fundAdminForHealthCheck();
        vm.prank(admin);
        if (expectedAssets == 0) {
            vm.expectRevert(abi.encodeWithSelector(Forwarder.VaultNoAssetsReturned.selector, address(candidate)));
            forwarder.proposeVault(IERC4626(address(candidate)));
            assertEq(address(forwarder.vault()), address(vault));
            assertEq(address(forwarder.pendingVault()), address(0));
        } else {
            forwarder.proposeVault(IERC4626(address(candidate)));
            assertEq(address(forwarder.pendingVault()), address(candidate));
            assertEq(usdc.balanceOf(admin), expectedAssets);
            // The first round trip left the lost assets in the vault, so the second one runs at another exchange
            // rate: it only has to return something.
            vm.warp(forwarder.pendingVaultExecutableAt());
            _executeVaultChange();
            assertEq(address(forwarder.vault()), address(candidate));
            assertGt(usdc.balanceOf(admin), expectedAssets);
            assertLe(usdc.balanceOf(admin), expectedAssets + TEST_AMOUNT);
            assertEq(usdc.balanceOf(address(forwarder)), 0);
        }
    }

    function testFuzz_RescueSendsEverythingToTreasury(uint256 amount, uint256 native) public {
        amount = bound(amount, 0, type(uint128).max);
        native = bound(native, 0, 1e30);
        MockERC20 token = new MockERC20("Token", "TKN", 18);
        token.mint(address(forwarder), amount);
        vm.deal(address(forwarder), native);
        vm.startPrank(admin);
        forwarder.rescueToken(IERC20(address(token)));
        forwarder.rescueNative();
        vm.stopPrank();
        assertEq(token.balanceOf(treasury), amount);
        assertEq(treasury.balance, native);
        assertEq(token.balanceOf(address(forwarder)), 0);
        assertEq(address(forwarder).balance, 0);
    }

    /// @dev Accounts without roles cannot call any privileged function.
    function testFuzz_UnprivilegedCallerCannotConfigure(address caller, uint8 selectorSeed, uint256 value) public {
        vm.assume(caller != admin && caller != feeManager && caller != feeManager2);
        vm.assume(caller != guardian && caller != guardian2);
        // A matured proposal, so that cancel/execute can only fail because of the caller.
        _proposeVault(address(new MockVault(IERC20(address(usdc)))));
        vm.warp(forwarder.pendingVaultExecutableAt());
        bytes[15] memory calls = [
            abi.encodeCall(Forwarder.setTreasury, (address(uint160(value | 1)))),
            abi.encodeCall(Forwarder.proposeVault, (IERC4626(address(uint160(value))))),
            abi.encodeCall(Forwarder.executeVaultChange, ()),
            abi.encodeCall(Forwarder.cancelVaultChange, ()),
            abi.encodeCall(Forwarder.setRoutingMode, (Forwarder.RoutingMode(value % 4))),
            abi.encodeCall(Forwarder.rescueToken, (IERC20(address(usdc)))),
            abi.encodeCall(Forwarder.rescueNative, ()),
            abi.encodeCall(Forwarder.pause, ()),
            abi.encodeCall(Forwarder.unpause, ()),
            abi.encodeCall(Forwarder.setFeeConfig, (FIXED, FIXED, value, value % 10e6, value % 10_000)),
            abi.encodeCall(Forwarder.setVariableFee, (value % 10_000)),
            abi.encodeCall(Forwarder.setFixedFee, (value % 10e6)),
            abi.encodeCall(Forwarder.setThreshold, (value)),
            abi.encodeCall(Forwarder.setLowerFeeModel, (Forwarder.FeeModel(value % 4))),
            abi.encodeCall(IAccessControl.grantRole, (FEE_MANAGER_ROLE, caller))
        ];
        vm.prank(caller);
        (bool success,) = address(forwarder).call(calls[bound(selectorSeed, 0, calls.length - 1)]);
        assertFalse(success);
        assertFalse(forwarder.hasRole(FEE_MANAGER_ROLE, caller));
        assertFalse(forwarder.hasRole(DEFAULT_ADMIN_ROLE, caller));
        assertFalse(forwarder.hasRole(VAULT_GUARDIAN_ROLE, caller));
        assertEq(address(forwarder.vault()), address(vault));
        assertTrue(address(forwarder.pendingVault()) != address(0));
    }
}
