// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {Forwarder} from "../src/Forwarder.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockVault, NoReturnDataVault} from "./mocks/MockVault.sol";
import {ForwarderTestBase} from "./utils/ForwarderTestBase.sol";

/// @dev Shared numbers: 100 USDC deposit, fee = 1 USDC + 1% = 2 USDC, user amount = 98 USDC.
abstract contract RoutingFixture is ForwarderTestBase {
    uint256 internal constant AMOUNT = 100e6;
    uint256 internal constant FEE = 2e6;
    uint256 internal constant USER_AMOUNT = 98e6;
    uint256 internal constant SHARE_SCALE = 1e12; // fresh mock vault: 1 USDC unit = 1e12 shares

    function setUp() public virtual override {
        super.setUp();
        _setFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, 1e6, 1000);
    }

    function _treasuryEventCount(Vm.Log[] memory logs) internal view returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(forwarder)) continue;
            bytes32 topic = logs[i].topics[0];
            if (
                topic == Forwarder.TreasuryTransferred.selector || topic == Forwarder.TreasuryTransferFailed.selector
                    || topic == Forwarder.TreasuryVaultDeposited.selector
                    || topic == Forwarder.TreasuryVaultDepositFailed.selector
            ) ++count;
        }
    }
}

/// @dev The four routing modes (spec section 6).
contract ForwarderRoutingTest is RoutingFixture {
    function test_DirectDirect() public {
        _fundSra(AMOUNT);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.Forwarded(sra, user, AMOUNT, FEE, USER_AMOUNT, false, 0);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TreasuryTransferred(treasury, FEE);
        vm.prank(sra);
        forwarder.forward(address(usdc), AMOUNT, user);

        assertEq(usdc.balanceOf(user), USER_AMOUNT);
        assertEq(vault.balanceOf(user), 0);
        assertEq(usdc.balanceOf(treasury), FEE);
        assertEq(vault.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(address(forwarder)), 0);
        assertEq(usdc.balanceOf(sra), 0);
        assertEq(vault.totalAssets(), 0);
    }

    function test_VaultUserDirectTreasury() public {
        _setRouting(VAULT_USER_DIRECT_TREASURY);
        _fundSra(AMOUNT);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.Forwarded(sra, user, AMOUNT, FEE, USER_AMOUNT, true, USER_AMOUNT * SHARE_SCALE);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TreasuryTransferred(treasury, FEE);
        vm.prank(sra);
        forwarder.forward(address(usdc), AMOUNT, user);

        assertEq(usdc.balanceOf(user), 0);
        assertEq(vault.balanceOf(user), USER_AMOUNT * SHARE_SCALE);
        assertEq(vault.convertToAssets(vault.balanceOf(user)), USER_AMOUNT);
        assertEq(usdc.balanceOf(treasury), FEE);
        assertEq(vault.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(address(forwarder)), 0);
        assertEq(vault.balanceOf(address(forwarder)), 0);
        assertEq(vault.totalAssets(), USER_AMOUNT);
    }

    function test_DirectUserVaultTreasury() public {
        _setRouting(DIRECT_USER_VAULT_TREASURY);
        _fundSra(AMOUNT);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.Forwarded(sra, user, AMOUNT, FEE, USER_AMOUNT, false, 0);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TreasuryVaultDeposited(treasury, address(vault), FEE, FEE * SHARE_SCALE);
        vm.prank(sra);
        forwarder.forward(address(usdc), AMOUNT, user);

        assertEq(usdc.balanceOf(user), USER_AMOUNT);
        assertEq(vault.balanceOf(user), 0);
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(vault.balanceOf(treasury), FEE * SHARE_SCALE);
        assertEq(usdc.balanceOf(address(forwarder)), 0);
        assertEq(vault.totalAssets(), FEE);
    }

    function test_VaultVault() public {
        _setRouting(VAULT_VAULT);
        _fundSra(AMOUNT);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.Forwarded(sra, user, AMOUNT, FEE, USER_AMOUNT, true, USER_AMOUNT * SHARE_SCALE);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TreasuryVaultDeposited(treasury, address(vault), FEE, FEE * SHARE_SCALE);
        vm.prank(sra);
        forwarder.forward(address(usdc), AMOUNT, user);

        assertEq(usdc.balanceOf(user), 0);
        assertEq(vault.balanceOf(user), USER_AMOUNT * SHARE_SCALE);
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(vault.balanceOf(treasury), FEE * SHARE_SCALE);
        assertEq(usdc.balanceOf(address(forwarder)), 0);
        assertEq(vault.balanceOf(address(forwarder)), 0);
        assertEq(vault.totalAssets(), AMOUNT);
    }

    function test_RecipientCanBeTheTreasury() public {
        _forward(AMOUNT, treasury);
        assertEq(usdc.balanceOf(treasury), AMOUNT);
    }

    function test_SequentialForwardsAcrossModeChanges() public {
        _forward(AMOUNT, user); // DIRECT_DIRECT
        _setRouting(VAULT_VAULT);
        _forward(AMOUNT, user);
        _setRouting(DIRECT_USER_VAULT_TREASURY);
        _forward(AMOUNT, user);
        _setRouting(VAULT_USER_DIRECT_TREASURY);
        _forward(AMOUNT, user);

        assertEq(usdc.balanceOf(user), 2 * USER_AMOUNT);
        assertEq(vault.convertToAssets(vault.balanceOf(user)), 2 * USER_AMOUNT);
        assertEq(usdc.balanceOf(treasury), 2 * FEE);
        assertEq(vault.convertToAssets(vault.balanceOf(treasury)), 2 * FEE);
        assertEq(usdc.balanceOf(address(forwarder)), 0);
    }
}

/// @dev User vault deposit failures fall back to USDC (spec section 7).
contract ForwarderUserFallbackTest is RoutingFixture {
    function test_FallbackWhenDepositReverts() public {
        _setRouting(VAULT_USER_DIRECT_TREASURY);
        vault.setDepositReverts(true);
        _fundSra(AMOUNT);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.UserVaultDepositFailed(
            user, address(vault), USER_AMOUNT, abi.encodeWithSelector(MockVault.DepositDisabled.selector)
        );
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.Forwarded(sra, user, AMOUNT, FEE, USER_AMOUNT, false, 0);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TreasuryTransferred(treasury, FEE);
        vm.prank(sra);
        forwarder.forward(address(usdc), AMOUNT, user);

        assertEq(usdc.balanceOf(user), USER_AMOUNT);
        assertEq(vault.balanceOf(user), 0);
        assertEq(usdc.balanceOf(treasury), FEE);
        assertEq(usdc.balanceOf(address(forwarder)), 0);
    }

    function test_FallbackWhenAllowanceIsExhausted() public {
        _setRouting(VAULT_USER_DIRECT_TREASURY);
        vm.prank(address(forwarder));
        usdc.approve(address(vault), 0);
        _fundSra(AMOUNT);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.UserVaultDepositFailed(
            user,
            address(vault),
            USER_AMOUNT,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, USER_AMOUNT)
        );
        vm.prank(sra);
        forwarder.forward(address(usdc), AMOUNT, user);
        assertEq(usdc.balanceOf(user), USER_AMOUNT);
    }

    function test_FallbackWhenVaultIsPaused() public {
        _setRouting(VAULT_USER_DIRECT_TREASURY);
        vault.setPaused(true);
        _fundSra(AMOUNT);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.UserVaultDepositFailed(
            user,
            address(vault),
            USER_AMOUNT,
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, user, USER_AMOUNT, 0)
        );
        vm.prank(sra);
        forwarder.forward(address(usdc), AMOUNT, user);
        assertEq(usdc.balanceOf(user), USER_AMOUNT);
    }

    function test_FallbackWhenDepositCapIsExceededWhileTreasuryDepositWorks() public {
        _setRouting(VAULT_VAULT);
        vault.setDepositCap(50e6);
        _forward(AMOUNT, user);
        assertEq(usdc.balanceOf(user), USER_AMOUNT);
        assertEq(vault.balanceOf(user), 0);
        assertEq(vault.convertToAssets(vault.balanceOf(treasury)), FEE);
        assertEq(usdc.balanceOf(address(forwarder)), 0);
    }

    function test_FallbackInVaultVaultKeepsTreasuryFundsWhenBothDepositsFail() public {
        _setRouting(VAULT_VAULT);
        vault.setDepositReverts(true);
        _fundSra(AMOUNT);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TreasuryVaultDepositFailed(
            treasury, address(vault), FEE, abi.encodeWithSelector(MockVault.DepositDisabled.selector)
        );
        vm.prank(sra);
        forwarder.forward(address(usdc), AMOUNT, user);
        assertEq(usdc.balanceOf(user), USER_AMOUNT);
        assertEq(usdc.balanceOf(address(forwarder)), FEE);
    }

    function test_RevertWhen_FallbackTransferAlsoFails() public {
        _setRouting(VAULT_USER_DIRECT_TREASURY);
        vault.setDepositReverts(true);
        usdc.setBlacklisted(user, true);
        _fundSra(AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.Blacklisted.selector, user));
        vm.prank(sra);
        forwarder.forward(address(usdc), AMOUNT, user);
        assertEq(usdc.balanceOf(sra), AMOUNT);
        assertEq(usdc.balanceOf(address(forwarder)), 0);
    }

    function test_RevertWhen_DirectUserTransferFails() public {
        usdc.setBlacklisted(user, true);
        _fundSra(AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.Blacklisted.selector, user));
        vm.prank(sra);
        forwarder.forward(address(usdc), AMOUNT, user);
        assertEq(usdc.balanceOf(sra), AMOUNT);
    }

    function test_VaultDepositResumesAfterRecovery() public {
        _setRouting(VAULT_USER_DIRECT_TREASURY);
        vault.setDepositReverts(true);
        _forward(AMOUNT, user);
        vault.setDepositReverts(false);
        _forward(AMOUNT, user);
        assertEq(usdc.balanceOf(user), USER_AMOUNT);
        assertEq(vault.convertToAssets(vault.balanceOf(user)), USER_AMOUNT);
    }

    /// @dev A vault that violates the ERC-4626 ABI on the user leg makes the whole call revert: try/catch cannot catch
    /// ABI decoding errors. Funds stay with the caller (no loss); this is part of the trusted-vault assumption.
    function test_UserLegRevertsWhenVaultReturnsMalformedData() public {
        NoReturnDataVault badVault = new NoReturnDataVault(IERC20(address(usdc)));
        _replaceVault(address(badVault));
        _setRouting(VAULT_USER_DIRECT_TREASURY);
        badVault.setReturnsNoData(true);
        _fundSra(AMOUNT);
        vm.expectRevert();
        vm.prank(sra);
        forwarder.forward(address(usdc), AMOUNT, user);
        assertEq(usdc.balanceOf(sra), AMOUNT);
    }
}

/// @dev Treasury delivery is best effort and retried (spec section 8).
contract ForwarderTreasuryDeliveryTest is RoutingFixture {
    function test_TreasuryVaultFailureKeepsFundsAndRetries() public {
        _setRouting(DIRECT_USER_VAULT_TREASURY);
        vault.setDepositReverts(true);
        _fundSra(AMOUNT);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TreasuryVaultDepositFailed(
            treasury, address(vault), FEE, abi.encodeWithSelector(MockVault.DepositDisabled.selector)
        );
        vm.prank(sra);
        forwarder.forward(address(usdc), AMOUNT, user);
        assertEq(usdc.balanceOf(user), USER_AMOUNT);
        assertEq(usdc.balanceOf(address(forwarder)), FEE);

        vault.setDepositReverts(false);
        _fundSra(AMOUNT);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TreasuryVaultDeposited(treasury, address(vault), 2 * FEE, 2 * FEE * SHARE_SCALE);
        vm.prank(sra);
        forwarder.forward(address(usdc), AMOUNT, user);
        assertEq(usdc.balanceOf(address(forwarder)), 0);
        assertEq(vault.convertToAssets(vault.balanceOf(treasury)), 2 * FEE);
    }

    function test_TreasuryOnlyVaultFailureInVaultVault() public {
        _setRouting(VAULT_VAULT);
        vault.setBlockedReceiver(treasury);
        _fundSra(AMOUNT);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.Forwarded(sra, user, AMOUNT, FEE, USER_AMOUNT, true, USER_AMOUNT * SHARE_SCALE);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TreasuryVaultDepositFailed(
            treasury, address(vault), FEE, abi.encodeWithSelector(MockVault.ReceiverBlocked.selector, treasury)
        );
        vm.prank(sra);
        forwarder.forward(address(usdc), AMOUNT, user);
        assertEq(vault.convertToAssets(vault.balanceOf(user)), USER_AMOUNT);
        assertEq(usdc.balanceOf(address(forwarder)), FEE);

        vault.setBlockedReceiver(address(0));
        _forward(AMOUNT, user);
        assertEq(vault.convertToAssets(vault.balanceOf(treasury)), 2 * FEE);
        assertEq(usdc.balanceOf(address(forwarder)), 0);
    }

    /// @dev A treasury deposit that succeeds without returning a full word is reported as failed but never reverts the
    /// user delivery; nothing is double counted because the next call measures the balance again.
    function test_TreasuryLegNeverRevertsOnMalformedVaultReturn() public {
        NoReturnDataVault badVault = new NoReturnDataVault(IERC20(address(usdc)));
        _replaceVault(address(badVault));
        _setRouting(DIRECT_USER_VAULT_TREASURY);
        badVault.setReturnsNoData(true);
        _fundSra(AMOUNT);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TreasuryVaultDepositFailed(treasury, address(badVault), FEE, "");
        vm.prank(sra);
        forwarder.forward(address(usdc), AMOUNT, user);
        assertEq(usdc.balanceOf(user), USER_AMOUNT);
        assertEq(usdc.balanceOf(address(forwarder)), 0); // the vault did take the funds
        assertEq(badVault.convertToAssets(badVault.balanceOf(treasury)), FEE);
    }

    function test_DirectTreasuryTransferReturningFalse() public {
        usdc.setReturnFalseOnTransferTo(treasury, true);
        _fundSra(AMOUNT);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TreasuryTransferFailed(treasury, FEE);
        vm.prank(sra);
        forwarder.forward(address(usdc), AMOUNT, user);
        assertEq(usdc.balanceOf(user), USER_AMOUNT);
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(address(forwarder)), FEE);

        usdc.setReturnFalseOnTransferTo(treasury, false);
        _fundSra(AMOUNT);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TreasuryTransferred(treasury, 2 * FEE);
        vm.prank(sra);
        forwarder.forward(address(usdc), AMOUNT, user);
        assertEq(usdc.balanceOf(treasury), 2 * FEE);
        assertEq(usdc.balanceOf(address(forwarder)), 0);
    }

    function test_DirectTreasuryTransferReverting() public {
        usdc.setBlacklisted(treasury, true);
        _fundSra(AMOUNT);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TreasuryTransferFailed(treasury, FEE);
        vm.prank(sra);
        forwarder.forward(address(usdc), AMOUNT, user);
        assertEq(usdc.balanceOf(user), USER_AMOUNT);
        assertEq(usdc.balanceOf(address(forwarder)), FEE);

        usdc.setBlacklisted(treasury, false);
        _forward(AMOUNT, user);
        assertEq(usdc.balanceOf(treasury), 2 * FEE);
    }

    function test_FailuresAccumulateAndAreDeliveredTogether() public {
        usdc.setBlacklisted(treasury, true);
        for (uint256 i = 0; i < 3; ++i) {
            _forward(AMOUNT, user);
        }
        assertEq(usdc.balanceOf(address(forwarder)), 3 * FEE);
        usdc.setBlacklisted(treasury, false);
        _forward(AMOUNT, user);
        assertEq(usdc.balanceOf(treasury), 4 * FEE);
        assertEq(usdc.balanceOf(user), 4 * USER_AMOUNT);
    }

    function test_PendingFundsGoToTheNewTreasury() public {
        usdc.setBlacklisted(treasury, true);
        _forward(AMOUNT, user);
        address newTreasury = makeAddr("newTreasury");
        _setTreasury(newTreasury);
        _forward(AMOUNT, user);
        assertEq(usdc.balanceOf(newTreasury), 2 * FEE);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_NoTreasuryActionWhenNothingIsLeft() public {
        _setFees(NONE, NONE, 0, 0, 0);
        Forwarder.RoutingMode[4] memory modes =
            [DIRECT_DIRECT, VAULT_USER_DIRECT_TREASURY, DIRECT_USER_VAULT_TREASURY, VAULT_VAULT];
        for (uint256 i = 0; i < modes.length; ++i) {
            _setRouting(modes[i]);
            _fundSra(AMOUNT);
            vm.recordLogs();
            vm.prank(sra);
            forwarder.forward(address(usdc), AMOUNT, user);
            assertEq(_treasuryEventCount(vm.getRecordedLogs()), 0);
        }
    }
}

/// @dev USDC sent to the Forwarder by mistake is delivered to the treasury with the next fee (spec section 8).
contract ForwarderAccidentalBalanceTest is RoutingFixture {
    uint256 internal constant DONATION = 7e6;

    function test_DonationIsSweptDirectly() public {
        usdc.mint(address(forwarder), DONATION);
        _fundSra(AMOUNT);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TreasuryTransferred(treasury, FEE + DONATION);
        vm.prank(sra);
        forwarder.forward(address(usdc), AMOUNT, user);
        assertEq(usdc.balanceOf(user), USER_AMOUNT);
        assertEq(usdc.balanceOf(treasury), FEE + DONATION);
        assertEq(usdc.balanceOf(address(forwarder)), 0);
    }

    function test_DonationIsDepositedForTreasury() public {
        _setRouting(VAULT_VAULT);
        usdc.mint(address(forwarder), DONATION);
        _forward(AMOUNT, user);
        assertEq(vault.convertToAssets(vault.balanceOf(user)), USER_AMOUNT);
        assertEq(vault.convertToAssets(vault.balanceOf(treasury)), FEE + DONATION);
        assertEq(usdc.balanceOf(address(forwarder)), 0);
    }

    function test_DonationIsSweptEvenWithoutFees() public {
        _setFees(NONE, NONE, 0, 0, 0);
        usdc.mint(address(forwarder), DONATION);
        _forward(AMOUNT, user);
        assertEq(usdc.balanceOf(user), AMOUNT);
        assertEq(usdc.balanceOf(treasury), DONATION);
    }

    function test_UserNeverReceivesTheDonation() public {
        _setRouting(VAULT_USER_DIRECT_TREASURY);
        vault.setDepositReverts(true);
        usdc.mint(address(forwarder), DONATION);
        _forward(AMOUNT, user);
        assertEq(usdc.balanceOf(user), USER_AMOUNT);
        assertEq(usdc.balanceOf(treasury), FEE + DONATION);
    }
}

/// @dev Zero amounts (spec section 19, "Zero values").
contract ForwarderZeroValuesTest is RoutingFixture {
    function setUp() public override {
        super.setUp();
        _setFees(NONE, NONE, 0, 0, 0);
    }

    function test_ZeroAmountDirect() public {
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.Forwarded(sra, user, 0, 0, 0, false, 0);
        vm.prank(sra);
        forwarder.forward(address(usdc), 0, user);
        assertEq(usdc.balanceOf(user), 0);
    }

    function test_ZeroAmountVaultDepositThatWorks() public {
        _setRouting(VAULT_VAULT);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.Forwarded(sra, user, 0, 0, 0, true, 0);
        vm.prank(sra);
        forwarder.forward(address(usdc), 0, user);
        assertEq(vault.balanceOf(user), 0);
    }

    function test_ZeroAmountVaultDepositThatRevertsFallsBack() public {
        _setRouting(VAULT_USER_DIRECT_TREASURY);
        vault.setZeroDepositReverts(true);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.UserVaultDepositFailed(
            user, address(vault), 0, abi.encodeWithSelector(MockVault.ZeroDeposit.selector)
        );
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.Forwarded(sra, user, 0, 0, 0, false, 0);
        vm.prank(sra);
        forwarder.forward(address(usdc), 0, user);
    }

    function test_ZeroFee() public {
        _forward(AMOUNT, user);
        assertEq(usdc.balanceOf(user), AMOUNT);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_ZeroUserAmountWithFallback() public {
        _setFees(FIXED, FIXED, 0, 3e6, 0);
        _setRouting(VAULT_USER_DIRECT_TREASURY);
        vault.setZeroDepositReverts(true);
        _fundSra(3e6);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.UserVaultDepositFailed(
            user, address(vault), 0, abi.encodeWithSelector(MockVault.ZeroDeposit.selector)
        );
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.Forwarded(sra, user, 3e6, 3e6, 0, false, 0);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TreasuryTransferred(treasury, 3e6);
        vm.prank(sra);
        forwarder.forward(address(usdc), 3e6, user);
    }

    function test_ZeroUserAmountWithWorkingZeroDeposit() public {
        _setFees(FIXED, FIXED, 0, 3e6, 0);
        _setRouting(VAULT_VAULT);
        _forward(3e6, user);
        assertEq(vault.balanceOf(user), 0);
        assertEq(vault.convertToAssets(vault.balanceOf(treasury)), 3e6);
    }
}

/// @dev Vault allowance lifecycle (spec section 11).
contract ForwarderAllowanceTest is RoutingFixture {
    function _modes() internal pure returns (Forwarder.RoutingMode[4] memory) {
        return [DIRECT_DIRECT, VAULT_USER_DIRECT_TREASURY, DIRECT_USER_VAULT_TREASURY, VAULT_VAULT];
    }

    function test_EveryRoutingTransition() public {
        Forwarder.RoutingMode[4] memory modes = _modes();
        for (uint256 a = 0; a < 4; ++a) {
            for (uint256 b = 0; b < 4; ++b) {
                _setRouting(modes[a]);
                assertEq(usdc.allowance(address(forwarder), address(vault)), _usesVault(modes[a]) ? MAX : 0);

                vm.recordLogs();
                vm.expectEmit(true, true, true, true, address(forwarder));
                emit Forwarder.RoutingModeUpdated(modes[a], modes[b]);
                _setRouting(modes[b]);
                uint256 approvals = _countApprovals(vm.getRecordedLogs(), address(usdc));

                assertEq(uint8(forwarder.routingMode()), uint8(modes[b]));
                assertEq(usdc.allowance(address(forwarder), address(vault)), _usesVault(modes[b]) ? MAX : 0);
                // Approve only when the vault usage changes; DIRECT->DIRECT and vault->vault do no work.
                assertEq(approvals, _usesVault(modes[a]) == _usesVault(modes[b]) ? 0 : 1);
            }
        }
    }

    function test_ForwardNeverApproves() public {
        Forwarder.RoutingMode[4] memory modes = _modes();
        for (uint256 i = 0; i < 4; ++i) {
            _setRouting(modes[i]);
            _fundSra(AMOUNT);
            vm.recordLogs();
            vm.prank(sra);
            forwarder.forward(address(usdc), AMOUNT, user);
            assertEq(_countApprovals(vm.getRecordedLogs(), address(usdc)), 0);
        }
    }

    /// @dev USDC decrements even an unlimited allowance. A vault->vault mode change keeps it; leaving the vault modes
    /// and entering them again restores the maximum (the active vault cannot be proposed again).
    function test_UsdcStyleAllowanceDecrementAndRefresh() public {
        _setRouting(VAULT_VAULT);
        _forward(AMOUNT, user);
        assertEq(usdc.allowance(address(forwarder), address(vault)), MAX - AMOUNT);
        _setRouting(VAULT_USER_DIRECT_TREASURY);
        assertEq(usdc.allowance(address(forwarder), address(vault)), MAX - AMOUNT);
        _setRouting(DIRECT_DIRECT);
        _setRouting(VAULT_USER_DIRECT_TREASURY);
        assertEq(usdc.allowance(address(forwarder), address(vault)), MAX);
    }

    function test_VaultReplacementInVaultMode() public {
        _setRouting(VAULT_VAULT);
        MockVault newVault = new MockVault(IERC20(address(usdc)));
        _replaceVault(address(newVault));
        assertEq(usdc.allowance(address(forwarder), address(vault)), 0);
        assertEq(usdc.allowance(address(forwarder), address(newVault)), MAX);
        _forward(AMOUNT, user);
        assertEq(newVault.convertToAssets(newVault.balanceOf(user)), USER_AMOUNT);
        assertEq(vault.balanceOf(user), 0);
    }

    function test_VaultReplacementInDirectMode() public {
        MockVault newVault = new MockVault(IERC20(address(usdc)));
        _replaceVault(address(newVault));
        assertEq(usdc.allowance(address(forwarder), address(vault)), 0);
        assertEq(usdc.allowance(address(forwarder), address(newVault)), 0);
        _setRouting(DIRECT_USER_VAULT_TREASURY);
        assertEq(usdc.allowance(address(forwarder), address(newVault)), MAX);
        assertEq(usdc.allowance(address(forwarder), address(vault)), 0);
    }

    function test_FailedReplacementKeepsAllowances() public {
        _setRouting(VAULT_VAULT);
        MockVault badVault = new MockVault(IERC20(address(usdc)));
        badVault.setRedeemReverts(true);
        _fundAdminForHealthCheck();
        vm.expectRevert(MockVault.RedeemDisabled.selector);
        vm.prank(admin);
        forwarder.proposeVault(IERC4626(address(badVault)));
        assertEq(address(forwarder.vault()), address(vault));
        assertEq(usdc.allowance(address(forwarder), address(vault)), MAX);
        assertEq(usdc.allowance(address(forwarder), address(badVault)), 0);
    }
}
