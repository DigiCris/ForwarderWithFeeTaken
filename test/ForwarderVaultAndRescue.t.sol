// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {Forwarder} from "../src/Forwarder.sol";
import {MockVault, NotAVault} from "./mocks/MockVault.sol";
import {
    ForceSendNative,
    MockERC20,
    MockFalseReturnToken,
    MockNoReturnToken,
    RejectNative
} from "./mocks/MockTokens.sol";
import {ReentrantToken, ReentrantVault} from "./mocks/ReentrancyMocks.sol";
import {ForwarderTestBase} from "./utils/ForwarderTestBase.sol";

/// @dev Vault health check, run by `proposeVault` and again by `executeVaultChange` (spec section 10).
contract ForwarderVaultHealthCheckTest is ForwarderTestBase {
    MockVault internal newVault;

    function setUp() public override {
        super.setUp();
        newVault = new MockVault(IERC20(address(usdc)));
    }

    function _expectProposeRevert(address candidate, bytes memory revertData) internal {
        _fundAdminForHealthCheck();
        vm.expectRevert(revertData);
        vm.prank(admin);
        forwarder.proposeVault(IERC4626(candidate));
        assertEq(address(forwarder.vault()), address(vault), "vault changed");
        assertEq(address(forwarder.pendingVault()), address(0), "proposal stored");
        assertEq(forwarder.pendingVaultExecutableAt(), 0, "timestamp stored");
    }

    function test_ProposeVault() public {
        _fundAdminForHealthCheck();
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.VaultChangeProposed(address(vault), address(newVault), block.timestamp + 72 hours, admin);
        vm.prank(admin);
        forwarder.proposeVault(IERC4626(address(newVault)));

        assertEq(address(forwarder.vault()), address(vault), "active vault changed");
        assertEq(address(forwarder.pendingVault()), address(newVault));
        assertEq(usdc.balanceOf(admin), TEST_AMOUNT, "admin refunded");
        assertEq(usdc.balanceOf(address(forwarder)), 0);
        assertEq(newVault.balanceOf(address(forwarder)), 0);
        assertEq(newVault.totalSupply(), 0, "health check shares not redeemed");
        assertEq(usdc.allowance(admin, address(forwarder)), 0);
        assertEq(usdc.allowance(address(forwarder), address(newVault)), 0, "candidate allowance");
    }

    function test_ExecuteVaultChange() public {
        _proposeVault(address(newVault));
        vm.warp(block.timestamp + VAULT_CHANGE_DELAY);
        _fundAdminForHealthCheck();
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.VaultUpdated(address(vault), address(newVault), TEST_AMOUNT * 1e12, TEST_AMOUNT);
        vm.prank(admin);
        forwarder.executeVaultChange();

        assertEq(address(forwarder.vault()), address(newVault));
        assertEq(usdc.balanceOf(admin), 2 * TEST_AMOUNT, "admin refunded twice");
        assertEq(usdc.balanceOf(address(forwarder)), 0);
        assertEq(newVault.totalSupply(), 0);
        assertEq(usdc.allowance(admin, address(forwarder)), 0);
    }

    function test_RevertWhen_VaultIsZero() public {
        _expectProposeRevert(address(0), abi.encodeWithSelector(Forwarder.ZeroAddress.selector));
    }

    function test_RevertWhen_VaultIsEoa() public {
        address eoa = makeAddr("eoa");
        _expectProposeRevert(eoa, abi.encodeWithSelector(Forwarder.VaultNotContract.selector, eoa));
    }

    function test_RevertWhen_VaultIsNotErc4626() public {
        _expectProposeRevert(address(new NotAVault()), "");
    }

    function test_RevertWhen_VaultAssetIsNotUsdc() public {
        MockERC20 other = new MockERC20("Other", "OTH", 6);
        MockVault wrongVault = new MockVault(IERC20(address(other)));
        _expectProposeRevert(
            address(wrongVault),
            abi.encodeWithSelector(Forwarder.VaultAssetMismatch.selector, address(wrongVault), address(other))
        );
    }

    function test_RevertWhen_VaultDepositFails() public {
        newVault.setDepositReverts(true);
        _expectProposeRevert(address(newVault), abi.encodeWithSelector(MockVault.DepositDisabled.selector));
    }

    function test_RevertWhen_VaultIsPaused() public {
        newVault.setPaused(true);
        _expectProposeRevert(
            address(newVault),
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, address(forwarder), TEST_AMOUNT, 0)
        );
    }

    function test_RevertWhen_VaultMintsNoShares() public {
        newVault.setMintsNoShares(true);
        _expectProposeRevert(
            address(newVault), abi.encodeWithSelector(Forwarder.VaultNoSharesMinted.selector, address(newVault))
        );
    }

    function test_RevertWhen_VaultRedeemFails() public {
        newVault.setRedeemReverts(true);
        _expectProposeRevert(address(newVault), abi.encodeWithSelector(MockVault.RedeemDisabled.selector));
    }

    function test_RevertWhen_VaultRedeemReturnsNothing() public {
        newVault.setRedeemPaysNothing(true);
        _expectProposeRevert(
            address(newVault), abi.encodeWithSelector(Forwarder.VaultNoAssetsReturned.selector, address(newVault))
        );
    }

    function test_RevertWhen_CallerDidNotFundHealthCheck() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(forwarder), 0, TEST_AMOUNT)
        );
        vm.prank(admin);
        forwarder.proposeVault(IERC4626(address(newVault)));
        assertEq(address(forwarder.pendingVault()), address(0));
    }

    function test_RevertWhen_ProposingTheActiveVault() public {
        _expectProposeRevert(
            address(vault), abi.encodeWithSelector(Forwarder.VaultAlreadyActive.selector, address(vault))
        );
    }

    /// @dev Re-proposing the active vault would otherwise overwrite its allowance in a vault mode.
    function test_RevertWhen_ProposingTheActiveVaultInVaultMode() public {
        _setRouting(VAULT_VAULT);
        _expectProposeRevert(
            address(vault), abi.encodeWithSelector(Forwarder.VaultAlreadyActive.selector, address(vault))
        );
        assertEq(usdc.allowance(address(forwarder), address(vault)), MAX);
    }

    /// @dev A non 1:1 exchange rate makes the round trip lose one unit to rounding; that must be accepted by both
    /// health checks.
    function test_VaultWithRoundingLossIsAccepted() public {
        usdc.mint(stranger, 1_000_000);
        vm.startPrank(stranger);
        usdc.approve(address(newVault), 1_000_000);
        newVault.deposit(1_000_000, stranger);
        vm.stopPrank();
        usdc.mint(address(newVault), 9700); // ~0.97% yield, like the production vault

        _proposeVault(address(newVault));
        uint256 proposalRefund = usdc.balanceOf(admin);
        assertGt(proposalRefund, 0);
        assertLt(proposalRefund, TEST_AMOUNT, "rounding loss expected");
        assertEq(address(forwarder.pendingVault()), address(newVault));

        vm.warp(forwarder.pendingVaultExecutableAt());
        uint256 expectedShares = newVault.previewDeposit(TEST_AMOUNT);
        _fundAdminForHealthCheck();
        vm.recordLogs();
        vm.prank(admin);
        forwarder.executeVaultChange();
        (uint256 shares, uint256 assets) = _vaultUpdatedData(vm.getRecordedLogs());

        assertEq(shares, expectedShares);
        assertGt(assets, 0);
        assertLt(assets, TEST_AMOUNT, "rounding loss expected");
        assertEq(usdc.balanceOf(admin), proposalRefund + assets, "admin gets exactly what came back");
        assertEq(address(forwarder.vault()), address(newVault));
    }

    function test_VaultReturningLessThanDepositedIsAccepted() public {
        newVault.setRedeemLossBps(5000);
        _proposeVault(address(newVault));
        assertEq(usdc.balanceOf(admin), TEST_AMOUNT / 2);
        assertEq(usdc.balanceOf(address(forwarder)), 0);

        // The lost half stays in the vault, so the second round trip runs at another exchange rate.
        vm.warp(forwarder.pendingVaultExecutableAt());
        _fundAdminForHealthCheck();
        vm.recordLogs();
        vm.prank(admin);
        forwarder.executeVaultChange();
        (uint256 shares, uint256 assets) = _vaultUpdatedData(vm.getRecordedLogs());
        assertGt(shares, 0);
        assertGt(assets, 0);
        assertLt(assets, TEST_AMOUNT);
        assertEq(usdc.balanceOf(admin), TEST_AMOUNT / 2 + assets);
        assertEq(usdc.balanceOf(address(forwarder)), 0);
        assertEq(address(forwarder.vault()), address(newVault));
    }

    function test_HealthCheckNeverUsesForwarderFunds() public {
        usdc.mint(address(forwarder), 5e6);
        newVault.setRedeemLossBps(5000);
        _proposeVault(address(newVault));
        assertEq(usdc.balanceOf(address(forwarder)), 5e6);
        assertEq(usdc.balanceOf(admin), TEST_AMOUNT / 2);
        vm.warp(forwarder.pendingVaultExecutableAt());
        _fundAdminForHealthCheck();
        vm.recordLogs();
        vm.prank(admin);
        forwarder.executeVaultChange();
        (, uint256 assets) = _vaultUpdatedData(vm.getRecordedLogs());
        assertEq(usdc.balanceOf(address(forwarder)), 5e6);
        assertEq(usdc.balanceOf(admin), TEST_AMOUNT / 2 + assets);
    }

    function test_HealthCheckRefundsAssetsTheVaultDidNotPull() public {
        newVault.setPartialPullBps(5000);
        _proposeVault(address(newVault));
        assertEq(usdc.balanceOf(address(forwarder)), 0);
        // 500 never left the Forwarder and ~500 came back from the redeem; all of it goes back to the caller.
        assertApproxEqAbs(usdc.balanceOf(admin), TEST_AMOUNT, 1);
        // The unused part of the health check allowance is cleared: a pending candidate keeps no allowance.
        assertEq(usdc.allowance(address(forwarder), address(newVault)), 0);

        vm.warp(forwarder.pendingVaultExecutableAt());
        _executeVaultChange();
        assertEq(usdc.balanceOf(address(forwarder)), 0);
        assertEq(usdc.allowance(address(forwarder), address(newVault)), 0);
    }

    function test_HealthCheckOnlyRedeemsNewShares() public {
        usdc.mint(stranger, 5e6);
        vm.startPrank(stranger);
        usdc.approve(address(newVault), 5e6);
        newVault.deposit(5e6, address(forwarder)); // shares held by the Forwarder before the health check
        vm.stopPrank();
        uint256 sharesBefore = newVault.balanceOf(address(forwarder));

        _replaceVault(address(newVault));
        assertEq(newVault.balanceOf(address(forwarder)), sharesBefore);
        assertEq(usdc.balanceOf(admin), 2 * TEST_AMOUNT);
    }

    function test_FailedHealthCheckLeavesNoPartialState() public {
        vm.prank(admin);
        forwarder.setRoutingMode(VAULT_VAULT);
        newVault.setRedeemPaysNothing(true);
        _fundAdminForHealthCheck();
        vm.expectRevert(abi.encodeWithSelector(Forwarder.VaultNoAssetsReturned.selector, address(newVault)));
        vm.prank(admin);
        forwarder.proposeVault(IERC4626(address(newVault)));

        assertEq(address(forwarder.vault()), address(vault));
        assertEq(address(forwarder.pendingVault()), address(0));
        assertEq(forwarder.pendingVaultExecutableAt(), 0);
        assertEq(usdc.allowance(address(forwarder), address(vault)), MAX);
        assertEq(usdc.allowance(address(forwarder), address(newVault)), 0);
        assertEq(usdc.balanceOf(admin), TEST_AMOUNT);
        assertEq(newVault.totalSupply(), 0);
    }

    function _vaultUpdatedData(Vm.Log[] memory logs) internal view returns (uint256 shares, uint256 assets) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(forwarder) && logs[i].topics[0] == Forwarder.VaultUpdated.selector) {
                return abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        revert("VaultUpdated not found");
    }
}

/// @dev Rescue of ERC-20 and native balances (spec section 14).
contract ForwarderRescueTest is ForwarderTestBase {
    function _rescue(address token) internal {
        vm.prank(admin);
        forwarder.rescueToken(IERC20(token));
    }

    function test_RescueUsdc() public {
        usdc.mint(address(forwarder), 5e6);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TokenRescued(address(usdc), treasury, 5e6);
        _rescue(address(usdc));
        assertEq(usdc.balanceOf(treasury), 5e6);
        assertEq(usdc.balanceOf(address(forwarder)), 0);
    }

    function test_RescueUsdcInVaultModeGoesDirectlyToTreasury() public {
        vm.prank(admin);
        forwarder.setRoutingMode(VAULT_VAULT);
        usdc.mint(address(forwarder), 5e6);
        _rescue(address(usdc));
        assertEq(usdc.balanceOf(treasury), 5e6);
        assertEq(vault.balanceOf(treasury), 0);
    }

    function test_RescueUsdtLikeToken() public {
        MockNoReturnToken usdt = new MockNoReturnToken();
        usdt.mint(address(forwarder), 3e6);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TokenRescued(address(usdt), treasury, 3e6);
        _rescue(address(usdt));
        assertEq(usdt.balanceOf(treasury), 3e6);
        assertEq(usdt.balanceOf(address(forwarder)), 0);
    }

    function test_RescueDaiLikeToken() public {
        MockERC20 dai = new MockERC20("Dai Stablecoin", "DAI", 18);
        dai.mint(address(forwarder), 12.5e18);
        _rescue(address(dai));
        assertEq(dai.balanceOf(treasury), 12.5e18);
        assertEq(dai.balanceOf(address(forwarder)), 0);
    }

    function test_RescueArbitraryToken() public {
        MockERC20 token = new MockERC20("Random", "RND", 9);
        token.mint(address(forwarder), 123_456_789);
        _rescue(address(token));
        assertEq(token.balanceOf(treasury), 123_456_789);
    }

    function test_RescueVaultShares() public {
        usdc.mint(stranger, 5e6);
        vm.startPrank(stranger);
        usdc.approve(address(vault), 5e6);
        vault.deposit(5e6, address(forwarder));
        vm.stopPrank();
        uint256 shares = vault.balanceOf(address(forwarder));
        _rescue(address(vault));
        assertEq(vault.balanceOf(treasury), shares);
        assertEq(vault.balanceOf(address(forwarder)), 0);
    }

    function test_RescueZeroBalance() public {
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TokenRescued(address(usdc), treasury, 0);
        _rescue(address(usdc));
    }

    function test_RescueGoesToCurrentTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(admin);
        forwarder.setTreasury(newTreasury);
        usdc.mint(address(forwarder), 1e6);
        _rescue(address(usdc));
        assertEq(usdc.balanceOf(newTreasury), 1e6);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_RevertWhen_RescueTokenReturnsFalse() public {
        MockFalseReturnToken token = new MockFalseReturnToken();
        token.mint(address(forwarder), 1e18);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        _rescue(address(token));
    }

    function test_RescueNative() public {
        vm.deal(address(forwarder), 1.5 ether);
        uint256 before = treasury.balance;
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.NativeRescued(treasury, 1.5 ether);
        vm.prank(admin);
        forwarder.rescueNative();
        assertEq(treasury.balance - before, 1.5 ether);
        assertEq(address(forwarder).balance, 0);
    }

    function test_RescueForcedNative() public {
        vm.deal(address(this), 2 ether);
        new ForceSendNative{value: 2 ether}(payable(address(forwarder)));
        assertEq(address(forwarder).balance, 2 ether);
        vm.prank(admin);
        forwarder.rescueNative();
        assertEq(treasury.balance, 2 ether);
    }

    function test_RescueNativeZeroBalance() public {
        vm.prank(admin);
        forwarder.rescueNative();
        assertEq(treasury.balance, 0);
    }

    function test_RevertWhen_TreasuryRejectsNative() public {
        RejectNative rejecter = new RejectNative();
        vm.prank(admin);
        forwarder.setTreasury(address(rejecter));
        vm.deal(address(forwarder), 1 ether);
        vm.expectRevert(bytes("no native"));
        vm.prank(admin);
        forwarder.rescueNative();
        assertEq(address(forwarder).balance, 1 ether);
    }
}

/// @dev Reentrancy protection (spec section 15).
contract ForwarderReentrancyTest is ForwarderTestBase {
    ReentrantVault internal evilVault;
    bytes internal guardError;

    function setUp() public override {
        super.setUp();
        evilVault = new ReentrantVault(IERC20(address(usdc)));
        _replaceVault(address(evilVault));
        vm.prank(admin);
        forwarder.setRoutingMode(VAULT_VAULT);
        guardError = abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    }

    /// @dev Single-call pranks: the reentering mocks use `vm.prank` themselves, which cannot override a `startPrank`.
    function _forwardOnce(uint256 amount, address recipient) internal {
        _fundSra(amount);
        vm.prank(sra);
        forwarder.forward(address(usdc), amount, recipient);
    }

    function _proposeOnce(address candidate) internal {
        _fundAdminForHealthCheck();
        vm.prank(admin);
        forwarder.proposeVault(IERC4626(candidate));
    }

    function _assertBlocked(ReentrantVault target) internal view {
        assertTrue(target.attempted(), "reentry not attempted");
        assertFalse(target.reentrySucceeded(), "reentry succeeded");
        assertEq(target.reentryReturnData(), guardError);
    }

    function test_ForwardCannotBeReentered() public {
        evilVault.arm(address(forwarder), abi.encodeCall(Forwarder.forward, (address(usdc), 0, stranger)), address(0));
        _forwardOnce(10e6, user);
        _assertBlocked(evilVault);
        assertEq(evilVault.convertToAssets(evilVault.balanceOf(user)), 10e6);
    }

    function test_SetRoutingModeCannotBeReenteredFromForward() public {
        evilVault.arm(address(forwarder), abi.encodeCall(Forwarder.setRoutingMode, (DIRECT_DIRECT)), admin);
        _forwardOnce(10e6, user);
        _assertBlocked(evilVault);
        assertEq(uint8(forwarder.routingMode()), uint8(VAULT_VAULT));
    }

    function test_ProposeVaultCannotBeReenteredFromForward() public {
        evilVault.arm(address(forwarder), abi.encodeCall(Forwarder.proposeVault, (IERC4626(address(vault)))), admin);
        _forwardOnce(10e6, user);
        _assertBlocked(evilVault);
        assertEq(address(forwarder.vault()), address(evilVault));
        assertEq(address(forwarder.pendingVault()), address(0));
    }

    function test_RescueTokenCannotBeReenteredFromForward() public {
        evilVault.arm(address(forwarder), abi.encodeCall(Forwarder.rescueToken, (IERC20(address(usdc)))), admin);
        _forwardOnce(10e6, user);
        _assertBlocked(evilVault);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_RescueNativeCannotBeReenteredFromForward() public {
        vm.deal(address(forwarder), 1 ether);
        evilVault.arm(address(forwarder), abi.encodeCall(Forwarder.rescueNative, ()), admin);
        _forwardOnce(10e6, user);
        _assertBlocked(evilVault);
        assertEq(address(forwarder).balance, 1 ether);
    }

    function test_CandidateVaultCannotReenterForwardDuringHealthCheck() public {
        ReentrantVault candidate = new ReentrantVault(IERC20(address(usdc)));
        candidate.arm(address(forwarder), abi.encodeCall(Forwarder.forward, (address(usdc), 0, stranger)), address(0));
        _proposeOnce(address(candidate));
        _assertBlocked(candidate);
        assertEq(address(forwarder.pendingVault()), address(candidate));
    }

    function test_CandidateVaultCannotReenterProposeDuringHealthCheck() public {
        ReentrantVault candidate = new ReentrantVault(IERC20(address(usdc)));
        candidate.arm(address(forwarder), abi.encodeCall(Forwarder.proposeVault, (IERC4626(address(vault)))), admin);
        _proposeOnce(address(candidate));
        _assertBlocked(candidate);
        assertEq(address(forwarder.pendingVault()), address(candidate));
        assertEq(address(forwarder.vault()), address(evilVault));
    }

    function test_RescuedTokenCannotReenter() public {
        ReentrantToken token = new ReentrantToken();
        token.mint(address(forwarder), 1e18);
        token.arm(address(forwarder), abi.encodeCall(Forwarder.forward, (address(usdc), 0, stranger)), address(0));
        vm.prank(admin);
        forwarder.rescueToken(IERC20(address(token)));
        assertFalse(token.reentrySucceeded());
        assertEq(token.reentryReturnData(), guardError);

        token.mint(address(forwarder), 1e18);
        token.arm(address(forwarder), abi.encodeCall(Forwarder.rescueToken, (IERC20(address(token)))), admin);
        vm.prank(admin);
        forwarder.rescueToken(IERC20(address(token)));
        assertFalse(token.reentrySucceeded());
        assertEq(token.reentryReturnData(), guardError);
        assertEq(token.balanceOf(treasury), 2e18);
    }

    /// @dev Pure storage setters are not guarded (no external call). Even if a privileged account reentered one of
    /// them, `forward` works on the configuration snapshot taken before any external call.
    function test_ForwardUsesConfigurationSnapshot() public {
        _setFees(FIXED, FIXED, 0, 1e6, 0);
        address newTreasury = makeAddr("newTreasury");
        evilVault.arm(address(forwarder), abi.encodeCall(Forwarder.setTreasury, (newTreasury)), admin);
        _forwardOnce(10e6, user);
        assertTrue(evilVault.reentrySucceeded());
        assertEq(forwarder.treasury(), newTreasury);
        assertEq(evilVault.convertToAssets(evilVault.balanceOf(treasury)), 1e6, "fee went to the snapshot treasury");
        assertEq(evilVault.balanceOf(newTreasury), 0);
    }
}
