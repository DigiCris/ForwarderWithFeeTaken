// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm, console} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Forwarder} from "../../src/Forwarder.sol";
import {ForwarderDeployConfig as Config} from "../../script/ForwarderDeployConfig.sol";

interface IFiatToken {
    function blacklister() external view returns (address);
    function blacklist(address account) external;
    function unBlacklist(address account) external;
}

interface ILucaVault {
    function pauseDeposits() external;
    function unpauseDeposits() external;
}

/**
 * @dev Integration tests against Base mainnet state: real USDC, real Luca Money Vault, real Safes and real third-party
 * ERC-4626 vaults. Failures are reproduced with real mechanisms only (vault guardian pause, USDC blacklist, Aave
 * supply capacity, exhausted allowance). Concrete suites choose the fork block and the Forwarder instance.
 */
abstract contract ForkTestBase is Test {
    IERC20 internal constant USDC = IERC20(Config.USDC);
    IERC4626 internal constant LUCA_VAULT = IERC4626(Config.VAULT);
    address internal constant ADMIN = Config.ADMIN;
    address internal constant TREASURY = Config.TREASURY;
    address internal constant LUCA_VAULT_CONTROLLER = Config.FEE_MANAGER_CM2; // CONTROLLER_ROLE on the Luca vault
    address internal constant LUCA_VAULT_MULTISIG = Config.FEE_MANAGER_HM; // MULTISIG_ROLE on the Luca vault
    IERC4626 internal constant STEAKHOUSE_USDC = IERC4626(0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183);
    IERC4626 internal constant MOONWELL_FLAGSHIP_ETH = IERC4626(0xa0E430870c4604CcfC7B38Ca7845B1FF653D0ff1);
    address internal constant USDBC = 0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA;
    address internal constant DAI = 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb;
    address internal constant USDT = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    uint256 internal constant MAX = type(uint256).max;

    Forwarder internal forwarder;
    address internal sra = makeAddr("fork-sra");
    address internal user = makeAddr("fork-user");
    address internal stranger = makeAddr("fork-stranger");
    address internal feeManager = Config.FEE_MANAGER_MANAGEMENT_1;

    /// @dev Block to fork; 0 means the latest block.
    function _forkBlock() internal view virtual returns (uint256);

    /// @dev Forwarder under test on the fork (fresh deployment or the deployed instance).
    function _setUpForwarder() internal virtual returns (Forwarder);

    function setUp() public virtual {
        uint256 forkBlock = _forkBlock();
        if (forkBlock == 0) vm.createSelectFork("base");
        else vm.createSelectFork("base", forkBlock);
        forwarder = _setUpForwarder();
        console.log("Fork block:", block.number);
        vm.label(address(forwarder), "Forwarder");
        vm.label(address(USDC), "USDC");
        vm.label(address(LUCA_VAULT), "LucaVault");
        vm.label(ADMIN, "AdminSafe");
        vm.label(TREASURY, "TreasurySafe");
    }

    // -----------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------

    function _routing(Forwarder.RoutingMode mode) internal {
        vm.prank(ADMIN);
        forwarder.setRoutingMode(mode);
    }

    function _fees(
        Forwarder.FeeModel lower,
        Forwarder.FeeModel upper,
        uint256 threshold,
        uint256 fixedFee,
        uint256 variableFee
    ) internal {
        vm.prank(feeManager);
        forwarder.setFeeConfig(lower, upper, threshold, fixedFee, variableFee);
    }

    function _fundSra(uint256 amount) internal {
        deal(address(USDC), sra, amount);
        vm.prank(sra);
        USDC.approve(address(forwarder), amount);
    }

    function _forward(uint256 amount, address recipient) internal returns (uint256 gasUsed) {
        _fundSra(amount);
        vm.prank(sra);
        uint256 gasBefore = gasleft();
        forwarder.forward(address(USDC), amount, recipient);
        gasUsed = gasBefore - gasleft();
    }

    function _value(IERC4626 vault, address account) internal view returns (uint256) {
        return vault.previewRedeem(vault.balanceOf(account));
    }

    function _pauseLucaVault() internal {
        vm.prank(LUCA_VAULT_CONTROLLER);
        ILucaVault(address(LUCA_VAULT)).pauseDeposits();
    }

    function _unpauseLucaVault() internal {
        vm.prank(LUCA_VAULT_MULTISIG);
        ILucaVault(address(LUCA_VAULT)).unpauseDeposits();
    }

    function _blacklist(address account, bool on) internal {
        IFiatToken token = IFiatToken(address(USDC));
        vm.prank(token.blacklister());
        if (on) token.blacklist(account);
        else token.unBlacklist(account);
    }

    /// @dev Funds the admin Safe with the health check amount and approves the Forwarder, as a Safe batch would.
    function _fundAdminHealthCheck() internal {
        uint256 amount = forwarder.VAULT_TEST_AMOUNT();
        deal(address(USDC), ADMIN, USDC.balanceOf(ADMIN) + amount);
        vm.prank(ADMIN);
        USDC.approve(address(forwarder), amount);
    }

    function _proposeAsAdmin(IERC4626 candidate) internal {
        _fundAdminHealthCheck();
        vm.prank(ADMIN);
        forwarder.proposeVault(candidate);
    }

    function _executeAsAdmin() internal {
        _fundAdminHealthCheck();
        vm.prank(ADMIN);
        forwarder.executeVaultChange();
    }

    /// @dev Full post-deployment replacement: propose, wait the 72 hours, execute.
    function _replaceVaultAsAdmin(IERC4626 newVault) internal {
        _proposeAsAdmin(newVault);
        vm.warp(forwarder.pendingVaultExecutableAt());
        _executeAsAdmin();
    }

    /// @dev A VAULT_GUARDIAN_ROLE holder: the first configured guardian, or an account granted by the admin Safe when
    /// the production configuration has none.
    function _guardian() internal returns (address account) {
        address[] memory guardians = Config.vaultGuardians();
        if (guardians.length > 0) return guardians[0];
        account = makeAddr("fork-guardian");
        if (!forwarder.hasRole(forwarder.VAULT_GUARDIAN_ROLE(), account)) {
            bytes32 role = forwarder.VAULT_GUARDIAN_ROLE();
            vm.prank(ADMIN);
            forwarder.grantRole(role, account);
        }
    }

    function _resetToBaseline() internal {
        if (forwarder.paused()) {
            vm.prank(ADMIN);
            forwarder.unpause();
        }
        if (address(forwarder.pendingVault()) != address(0)) {
            vm.prank(ADMIN);
            forwarder.cancelVaultChange();
        }
        if (address(forwarder.vault()) != Config.VAULT) _replaceVaultAsAdmin(LUCA_VAULT);
        _routing(Forwarder.RoutingMode.DIRECT_DIRECT);
        _fees(Forwarder.FeeModel.NONE, Forwarder.FeeModel.NONE, 0, 0, 0);
        if (USDC.balanceOf(address(forwarder)) != 0) {
            vm.prank(ADMIN);
            forwarder.rescueToken(USDC);
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Configuration and roles
    // -----------------------------------------------------------------------------------------------------------

    function test_Fork_ProductionConfiguration() public view {
        assertEq(block.chainid, 8453);
        assertEq(address(forwarder.USDC()), Config.USDC);
        assertEq(forwarder.defaultAdmin(), ADMIN);
        assertEq(forwarder.owner(), ADMIN);
        assertEq(forwarder.defaultAdminDelay(), Config.ADMIN_DELAY);
        assertEq(forwarder.treasury(), TREASURY);
        assertEq(address(forwarder.vault()), Config.VAULT);
        address[] memory managers = Config.feeManagers(Config.FEE_MANAGER_CM2);
        assertEq(managers.length, 7);
        for (uint256 i = 0; i < managers.length; ++i) {
            assertTrue(forwarder.hasRole(forwarder.FEE_MANAGER_ROLE(), managers[i]));
            assertFalse(forwarder.hasRole(forwarder.DEFAULT_ADMIN_ROLE(), managers[i]));
        }
        assertFalse(forwarder.hasRole(forwarder.FEE_MANAGER_ROLE(), ADMIN));

        bytes32 guardianRole = forwarder.VAULT_GUARDIAN_ROLE();
        assertEq(guardianRole, keccak256("VAULT_GUARDIAN_ROLE"));
        assertEq(forwarder.getRoleAdmin(guardianRole), forwarder.DEFAULT_ADMIN_ROLE());
        address[] memory guardians = Config.vaultGuardians();
        assertEq(guardians.length, 7, "the seven management wallets");
        for (uint256 i = 0; i < guardians.length; ++i) {
            assertEq(guardians[i], managers[i], "guardian is the management wallet");
            assertTrue(forwarder.hasRole(guardianRole, guardians[i]));
            assertFalse(forwarder.hasRole(forwarder.DEFAULT_ADMIN_ROLE(), guardians[i]));
        }
        assertFalse(forwarder.hasRole(guardianRole, ADMIN));
        assertEq(forwarder.VAULT_CHANGE_DELAY(), 72 hours);
    }

    function test_Fork_EveryFeeManagerCanConfigureAndPauseButNotAdminister() public {
        address[] memory managers = Config.feeManagers(Config.FEE_MANAGER_CM2);
        bytes32 adminRole = forwarder.DEFAULT_ADMIN_ROLE();
        bytes32 feeRole = forwarder.FEE_MANAGER_ROLE();
        for (uint256 i = 0; i < managers.length; ++i) {
            address manager = managers[i];
            vm.startPrank(manager);
            forwarder.setFeeConfig(Forwarder.FeeModel.FIXED, Forwarder.FeeModel.PERCENT, i, i, i);
            forwarder.setVariableFee(i + 1);
            forwarder.pause();
            assertTrue(forwarder.paused());
            _expectUnauthorized(manager, adminRole);
            forwarder.unpause();
            _expectUnauthorized(manager, adminRole);
            forwarder.setTreasury(manager);
            _expectUnauthorized(manager, adminRole);
            forwarder.proposeVault(STEAKHOUSE_USDC);
            _expectUnauthorized(manager, adminRole);
            forwarder.executeVaultChange();
            if (!forwarder.hasRole(forwarder.VAULT_GUARDIAN_ROLE(), manager)) {
                _expectUnauthorized(manager, forwarder.VAULT_GUARDIAN_ROLE());
                forwarder.cancelVaultChange();
            }
            _expectUnauthorized(manager, adminRole);
            forwarder.setRoutingMode(Forwarder.RoutingMode.VAULT_VAULT);
            _expectUnauthorized(manager, adminRole);
            forwarder.rescueToken(USDC);
            _expectUnauthorized(manager, adminRole);
            forwarder.rescueNative();
            _expectUnauthorized(manager, adminRole);
            forwarder.grantRole(feeRole, stranger);
            vm.stopPrank();

            vm.prank(ADMIN);
            forwarder.unpause();
        }
        assertEq(forwarder.treasury(), TREASURY);
    }

    function test_Fork_StrangerCannotDoAnything() public {
        bytes32 feeRole = forwarder.FEE_MANAGER_ROLE();
        bytes32 adminRole = forwarder.DEFAULT_ADMIN_ROLE();
        vm.startPrank(stranger);
        _expectUnauthorized(stranger, feeRole);
        forwarder.setFeeConfig(Forwarder.FeeModel.FIXED, Forwarder.FeeModel.FIXED, 0, 1, 1);
        _expectUnauthorized(stranger, feeRole);
        forwarder.pause();
        _expectUnauthorized(stranger, adminRole);
        forwarder.setTreasury(stranger);
        _expectUnauthorized(stranger, adminRole);
        forwarder.setRoutingMode(Forwarder.RoutingMode.VAULT_VAULT);
        _expectUnauthorized(stranger, adminRole);
        forwarder.rescueToken(USDC);
        _expectUnauthorized(stranger, adminRole);
        forwarder.proposeVault(STEAKHOUSE_USDC);
        _expectUnauthorized(stranger, adminRole);
        forwarder.executeVaultChange();
        _expectUnauthorized(stranger, forwarder.VAULT_GUARDIAN_ROLE());
        forwarder.cancelVaultChange();
        vm.stopPrank();
    }

    function test_Fork_AdminSafeCanAdminister() public {
        address newTreasury = makeAddr("newTreasury");
        vm.startPrank(ADMIN);
        forwarder.setTreasury(newTreasury);
        forwarder.setTreasury(TREASURY);
        forwarder.pause();
        forwarder.unpause();
        forwarder.grantRole(forwarder.FEE_MANAGER_ROLE(), stranger);
        forwarder.revokeRole(forwarder.FEE_MANAGER_ROLE(), stranger);
        vm.stopPrank();
        assertEq(forwarder.treasury(), TREASURY);
        assertFalse(forwarder.hasRole(forwarder.FEE_MANAGER_ROLE(), stranger));
    }

    function _expectUnauthorized(address account, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role));
    }

    // -----------------------------------------------------------------------------------------------------------
    // Routing with the real vault
    // -----------------------------------------------------------------------------------------------------------

    function test_Fork_AllRoutingModes() public {
        _resetToBaseline();
        _fees(Forwarder.FeeModel.FIXED_PLUS_PERCENT, Forwarder.FeeModel.FIXED_PLUS_PERCENT, 0, 1e6, 1000);
        uint256 amount = 1000e6;
        uint256 fee = 11e6; // 1 USDC + 1%
        uint256 userAmount = amount - fee;
        Forwarder.RoutingMode[4] memory modes = [
            Forwarder.RoutingMode.DIRECT_DIRECT,
            Forwarder.RoutingMode.VAULT_USER_DIRECT_TREASURY,
            Forwarder.RoutingMode.DIRECT_USER_VAULT_TREASURY,
            Forwarder.RoutingMode.VAULT_VAULT
        ];
        for (uint256 i = 0; i < modes.length; ++i) {
            _routing(modes[i]);
            address recipient = makeAddr(string.concat("recipient", vm.toString(i)));
            uint256 treasuryUsdcBefore = USDC.balanceOf(TREASURY);
            uint256 treasurySharesBefore = LUCA_VAULT.balanceOf(TREASURY);
            uint256 gasUsed = _forward(amount, recipient);
            console.log("forward gas, mode", i, gasUsed);

            bool userVault = i == 1 || i == 3;
            bool treasuryVault = i == 2 || i == 3;
            if (userVault) {
                assertEq(USDC.balanceOf(recipient), 0);
                assertApproxEqAbs(_value(LUCA_VAULT, recipient), userAmount, 2);
                assertLe(_value(LUCA_VAULT, recipient), userAmount);
            } else {
                assertEq(USDC.balanceOf(recipient), userAmount);
                assertEq(LUCA_VAULT.balanceOf(recipient), 0);
            }
            uint256 treasurySharesDelta = LUCA_VAULT.balanceOf(TREASURY) - treasurySharesBefore;
            if (treasuryVault) {
                assertEq(USDC.balanceOf(TREASURY), treasuryUsdcBefore);
                assertApproxEqAbs(LUCA_VAULT.previewRedeem(treasurySharesDelta), fee, 2);
            } else {
                assertEq(USDC.balanceOf(TREASURY) - treasuryUsdcBefore, fee);
                assertEq(treasurySharesDelta, 0);
            }
            assertEq(USDC.balanceOf(address(forwarder)), 0);
            assertEq(LUCA_VAULT.balanceOf(address(forwarder)), 0);
            assertEq(USDC.balanceOf(sra), 0);
        }
    }

    function test_Fork_FeeUsesFullAmountAboveThreshold() public {
        _resetToBaseline();
        _fees(Forwarder.FeeModel.FIXED, Forwarder.FeeModel.PERCENT, 100e6, 1e6, 1000);
        _forward(150e6, user);
        assertEq(USDC.balanceOf(user), 148.5e6);
        _forward(100e6, user);
        assertEq(USDC.balanceOf(user), 148.5e6 + 99e6);
    }

    function test_Fork_PausedFeesForwardFullAmount() public {
        _resetToBaseline();
        _fees(Forwarder.FeeModel.FIXED_PLUS_PERCENT, Forwarder.FeeModel.FIXED_PLUS_PERCENT, 0, 10e6, 10_000);
        vm.prank(feeManager);
        forwarder.pause();
        uint256 treasuryBefore = USDC.balanceOf(TREASURY);
        _forward(500e6, user);
        assertEq(USDC.balanceOf(user), 500e6);
        assertEq(USDC.balanceOf(TREASURY), treasuryBefore);
        vm.prank(ADMIN);
        forwarder.unpause();
        _forward(500e6, user);
        assertEq(USDC.balanceOf(user), 500e6 + 440e6);
    }

    function test_Fork_FeeEqualToAndAboveAmount() public {
        _resetToBaseline();
        _fees(Forwarder.FeeModel.FIXED, Forwarder.FeeModel.FIXED, 0, 2e6, 0);
        _forward(2e6, user);
        assertEq(USDC.balanceOf(user), 0);

        _fundSra(2e6 - 1);
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(sra);
        forwarder.forward(address(USDC), 2e6 - 1, user);
    }

    function test_Fork_ZeroAmount() public {
        _resetToBaseline();
        _forward(0, user);
        _routing(Forwarder.RoutingMode.VAULT_USER_DIRECT_TREASURY);
        // Whatever the real vault does with deposit(0), the user leg must complete (vault or fallback).
        vm.recordLogs();
        vm.prank(sra);
        forwarder.forward(address(USDC), 0, user);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool fallbackUsed;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(forwarder) && logs[i].topics[0] == Forwarder.UserVaultDepositFailed.selector)
            {
                fallbackUsed = true;
            }
        }
        console.log("Luca vault deposit(0) fell back to USDC:", fallbackUsed);
        assertEq(USDC.balanceOf(user), 0);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Failures reproduced with real mechanisms
    // -----------------------------------------------------------------------------------------------------------

    function test_Fork_UserFallbackWhenVaultDepositsArePaused() public {
        _resetToBaseline();
        _routing(Forwarder.RoutingMode.VAULT_USER_DIRECT_TREASURY);
        _pauseLucaVault();
        _fundSra(100e6);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.UserVaultDepositFailed(
            user, address(LUCA_VAULT), 100e6, abi.encodeWithSelector(Pausable.EnforcedPause.selector)
        );
        vm.prank(sra);
        forwarder.forward(address(USDC), 100e6, user);
        assertEq(USDC.balanceOf(user), 100e6);
        assertEq(LUCA_VAULT.balanceOf(user), 0);

        _unpauseLucaVault();
        _forward(100e6, user);
        assertApproxEqAbs(_value(LUCA_VAULT, user), 100e6, 2);
    }

    function test_Fork_UserFallbackWhenAllowanceIsExhausted() public {
        _resetToBaseline();
        _routing(Forwarder.RoutingMode.VAULT_USER_DIRECT_TREASURY);
        vm.prank(address(forwarder));
        USDC.approve(address(LUCA_VAULT), 0);
        vm.recordLogs();
        _forward(100e6, user);
        assertTrue(_emitted(vm.getRecordedLogs(), Forwarder.UserVaultDepositFailed.selector));
        assertEq(USDC.balanceOf(user), 100e6);
        // Leaving the vault modes and entering them again restores the unlimited allowance.
        _routing(Forwarder.RoutingMode.DIRECT_DIRECT);
        _routing(Forwarder.RoutingMode.VAULT_USER_DIRECT_TREASURY);
        assertEq(USDC.allowance(address(forwarder), address(LUCA_VAULT)), MAX);
    }

    function test_Fork_UserFallbackAboveVaultCapacity() public {
        _resetToBaseline();
        _routing(Forwarder.RoutingMode.VAULT_USER_DIRECT_TREASURY);
        uint256 amount = LUCA_VAULT.maxDeposit(user) + 1;
        _fundSra(amount);
        vm.recordLogs();
        vm.prank(sra);
        forwarder.forward(address(USDC), amount, user);
        bytes memory reason = _userFallbackReason(vm.getRecordedLogs());
        assertEq(bytes4(reason), ERC4626.ERC4626ExceededMaxDeposit.selector);
        assertEq(USDC.balanceOf(user), amount);
        assertEq(LUCA_VAULT.balanceOf(user), 0);
    }

    function _userFallbackReason(Vm.Log[] memory logs) internal view returns (bytes memory reason) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(forwarder) && logs[i].topics[0] == Forwarder.UserVaultDepositFailed.selector)
            {
                (, reason) = abi.decode(logs[i].data, (uint256, bytes));
                return reason;
            }
        }
        revert("UserVaultDepositFailed not emitted");
    }

    function test_Fork_TreasuryVaultFailureIsRetried() public {
        _resetToBaseline();
        _routing(Forwarder.RoutingMode.DIRECT_USER_VAULT_TREASURY);
        _fees(Forwarder.FeeModel.FIXED, Forwarder.FeeModel.FIXED, 0, 1e6, 0);
        _pauseLucaVault();
        _fundSra(100e6);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TreasuryVaultDepositFailed(
            TREASURY, address(LUCA_VAULT), 1e6, abi.encodeWithSelector(Pausable.EnforcedPause.selector)
        );
        vm.prank(sra);
        forwarder.forward(address(USDC), 100e6, user);
        assertEq(USDC.balanceOf(user), 99e6);
        assertEq(USDC.balanceOf(address(forwarder)), 1e6);

        _unpauseLucaVault();
        uint256 sharesBefore = LUCA_VAULT.balanceOf(TREASURY);
        _forward(100e6, user);
        assertEq(USDC.balanceOf(address(forwarder)), 0);
        assertApproxEqAbs(LUCA_VAULT.previewRedeem(LUCA_VAULT.balanceOf(TREASURY) - sharesBefore), 2e6, 2);
    }

    function test_Fork_TreasuryDirectFailureIsRetried() public {
        _resetToBaseline();
        _fees(Forwarder.FeeModel.FIXED, Forwarder.FeeModel.FIXED, 0, 1e6, 0);
        _blacklist(TREASURY, true);
        _fundSra(100e6);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TreasuryTransferFailed(TREASURY, 1e6);
        vm.prank(sra);
        forwarder.forward(address(USDC), 100e6, user);
        assertEq(USDC.balanceOf(user), 99e6);
        assertEq(USDC.balanceOf(address(forwarder)), 1e6);

        _blacklist(TREASURY, false);
        uint256 treasuryBefore = USDC.balanceOf(TREASURY);
        _fundSra(100e6);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TreasuryTransferred(TREASURY, 2e6);
        vm.prank(sra);
        forwarder.forward(address(USDC), 100e6, user);
        assertEq(USDC.balanceOf(TREASURY) - treasuryBefore, 2e6);
    }

    function test_Fork_RevertWhen_UserIsBlacklisted() public {
        _resetToBaseline();
        _blacklist(user, true);
        _fundSra(100e6);
        vm.expectRevert();
        vm.prank(sra);
        forwarder.forward(address(USDC), 100e6, user);
        assertEq(USDC.balanceOf(sra), 100e6);
    }

    function test_Fork_AccidentalUsdcIsSwept() public {
        _resetToBaseline();
        _fees(Forwarder.FeeModel.FIXED, Forwarder.FeeModel.FIXED, 0, 1e6, 0);
        deal(address(USDC), address(forwarder), 5e6);
        uint256 treasuryBefore = USDC.balanceOf(TREASURY);
        _forward(100e6, user);
        assertEq(USDC.balanceOf(TREASURY) - treasuryBefore, 6e6);
        assertEq(USDC.balanceOf(user), 99e6);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Vault replacement and allowances
    // -----------------------------------------------------------------------------------------------------------

    /// @dev Both health checks (proposal and execution) on the real Luca vault, which rounds the round trip down.
    function test_Fork_HealthCheckOnLucaVaultAcceptsRounding() public {
        _resetToBaseline();
        _replaceVaultAsAdmin(STEAKHOUSE_USDC);
        _fundAdminHealthCheck();
        uint256 adminBefore = USDC.balanceOf(ADMIN) - forwarder.VAULT_TEST_AMOUNT();
        vm.prank(ADMIN);
        forwarder.proposeVault(LUCA_VAULT);
        uint256 proposalRefund = USDC.balanceOf(ADMIN) - adminBefore;
        console.log("Luca vault proposal health check: assets returned", proposalRefund);
        assertGt(proposalRefund, 0);
        assertLe(proposalRefund, 1000);
        assertEq(USDC.allowance(address(forwarder), address(LUCA_VAULT)), 0);

        vm.warp(forwarder.pendingVaultExecutableAt());
        _fundAdminHealthCheck();
        adminBefore = USDC.balanceOf(ADMIN) - forwarder.VAULT_TEST_AMOUNT();
        vm.recordLogs();
        vm.prank(ADMIN);
        forwarder.executeVaultChange();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(forwarder) && logs[i].topics[0] == Forwarder.VaultUpdated.selector) {
                (uint256 shares, uint256 assets) = abi.decode(logs[i].data, (uint256, uint256));
                console.log("Luca vault health check: shares", shares, "assets returned", assets);
                assertGt(shares, 0);
                assertGt(assets, 0);
                assertLe(assets, 1000);
                assertEq(USDC.balanceOf(ADMIN), adminBefore + assets);
            }
        }
        assertEq(USDC.balanceOf(address(forwarder)), 0);
    }

    function test_Fork_ReplaceVaultWithThirdPartyVault() public {
        _resetToBaseline();
        _routing(Forwarder.RoutingMode.VAULT_VAULT);
        _replaceVaultAsAdmin(STEAKHOUSE_USDC);
        assertEq(address(forwarder.vault()), address(STEAKHOUSE_USDC));
        assertEq(USDC.allowance(address(forwarder), address(LUCA_VAULT)), 0);
        assertEq(USDC.allowance(address(forwarder), address(STEAKHOUSE_USDC)), MAX);
        _forward(250e6, user);
        assertApproxEqAbs(_value(STEAKHOUSE_USDC, user), 250e6, 2);
        assertEq(LUCA_VAULT.balanceOf(user), 0);
        _replaceVaultAsAdmin(LUCA_VAULT);
        assertEq(USDC.allowance(address(forwarder), address(STEAKHOUSE_USDC)), 0);
        assertEq(USDC.allowance(address(forwarder), address(LUCA_VAULT)), MAX);
    }

    function test_Fork_RejectInvalidVaults() public {
        _resetToBaseline();
        deal(address(USDC), ADMIN, 1e6);
        vm.startPrank(ADMIN);
        USDC.approve(address(forwarder), 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(Forwarder.VaultAssetMismatch.selector, address(MOONWELL_FLAGSHIP_ETH), WETH)
        );
        forwarder.proposeVault(MOONWELL_FLAGSHIP_ETH);
        vm.expectRevert(abi.encodeWithSelector(Forwarder.VaultNotContract.selector, stranger));
        forwarder.proposeVault(IERC4626(stranger));
        vm.expectRevert();
        forwarder.proposeVault(IERC4626(address(USDC))); // USDC is not an ERC-4626
        vm.expectRevert(abi.encodeWithSelector(Forwarder.VaultAlreadyActive.selector, address(LUCA_VAULT)));
        forwarder.proposeVault(LUCA_VAULT);
        vm.stopPrank();
        assertEq(address(forwarder.vault()), Config.VAULT);
        assertEq(address(forwarder.pendingVault()), address(0));
    }

    function test_Fork_AllowanceTransitionsWithRealUsdc() public {
        _resetToBaseline();
        Forwarder.RoutingMode[4] memory modes = [
            Forwarder.RoutingMode.DIRECT_DIRECT,
            Forwarder.RoutingMode.VAULT_USER_DIRECT_TREASURY,
            Forwarder.RoutingMode.DIRECT_USER_VAULT_TREASURY,
            Forwarder.RoutingMode.VAULT_VAULT
        ];
        for (uint256 a = 0; a < 4; ++a) {
            for (uint256 b = 0; b < 4; ++b) {
                _routing(modes[a]);
                _routing(modes[b]);
                uint256 expected = modes[b] == Forwarder.RoutingMode.DIRECT_DIRECT ? 0 : MAX;
                assertEq(USDC.allowance(address(forwarder), address(LUCA_VAULT)), expected);
            }
        }
        // Real USDC decrements even an unlimited allowance.
        _routing(Forwarder.RoutingMode.DIRECT_DIRECT);
        _routing(Forwarder.RoutingMode.VAULT_VAULT);
        _forward(100e6, user);
        assertEq(USDC.allowance(address(forwarder), address(LUCA_VAULT)), MAX - 100e6);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Vault change lifecycle (immutable 72-hour delay)
    // -----------------------------------------------------------------------------------------------------------

    function test_Fork_VaultChangeLifecycleWithRealVaults() public {
        _resetToBaseline();
        assertEq(address(forwarder.vault()), address(LUCA_VAULT));
        assertEq(uint8(forwarder.routingMode()), uint8(Forwarder.RoutingMode.DIRECT_DIRECT));
        assertEq(USDC.allowance(address(forwarder), address(LUCA_VAULT)), 0);
        assertEq(address(forwarder.pendingVault()), address(0));
        assertEq(forwarder.pendingVaultExecutableAt(), 0);
        _forward(100e6, user); // before the proposal

        _proposeAsAdmin(STEAKHOUSE_USDC);
        uint256 executableAt = forwarder.pendingVaultExecutableAt();
        assertEq(executableAt, block.timestamp + 72 hours);
        assertEq(address(forwarder.pendingVault()), address(STEAKHOUSE_USDC));
        assertEq(address(forwarder.vault()), address(LUCA_VAULT));
        assertEq(USDC.allowance(address(forwarder), address(STEAKHOUSE_USDC)), 0, "candidate allowance");
        assertEq(USDC.allowance(address(forwarder), address(LUCA_VAULT)), 0);
        assertEq(STEAKHOUSE_USDC.balanceOf(address(forwarder)), 0);
        assertEq(USDC.balanceOf(address(forwarder)), 0);

        _forward(100e6, user); // while the change is pending
        assertEq(USDC.balanceOf(user), 200e6);
        assertEq(STEAKHOUSE_USDC.balanceOf(user), 0);

        _fundAdminHealthCheck();
        vm.expectRevert(abi.encodeWithSelector(Forwarder.VaultChangeDelayNotElapsed.selector, executableAt));
        vm.prank(ADMIN);
        forwarder.executeVaultChange();
        vm.warp(executableAt - 1);
        vm.expectRevert(abi.encodeWithSelector(Forwarder.VaultChangeDelayNotElapsed.selector, executableAt));
        vm.prank(ADMIN);
        forwarder.executeVaultChange();

        vm.warp(executableAt);
        vm.prank(ADMIN);
        forwarder.executeVaultChange();
        assertEq(address(forwarder.vault()), address(STEAKHOUSE_USDC));
        assertEq(address(forwarder.pendingVault()), address(0));
        assertEq(forwarder.pendingVaultExecutableAt(), 0);
        assertEq(USDC.allowance(address(forwarder), address(LUCA_VAULT)), 0);
        assertEq(USDC.allowance(address(forwarder), address(STEAKHOUSE_USDC)), 0, "DIRECT_DIRECT at execution");
        assertEq(USDC.balanceOf(address(forwarder)), 0);

        _forward(100e6, user); // after the change, still DIRECT_DIRECT
        assertEq(USDC.balanceOf(user), 300e6);
        _routing(Forwarder.RoutingMode.VAULT_VAULT);
        assertEq(USDC.allowance(address(forwarder), address(STEAKHOUSE_USDC)), MAX);
        _forward(250e6, user);
        assertApproxEqAbs(_value(STEAKHOUSE_USDC, user), 250e6, 2);
        assertEq(LUCA_VAULT.balanceOf(user), 0);
    }

    function test_Fork_GuardianCancelsPendingVaultChange() public {
        _resetToBaseline();
        address guardianAccount = _guardian();
        _proposeAsAdmin(STEAKHOUSE_USDC);
        vm.warp(forwarder.pendingVaultExecutableAt()); // still cancellable once executable
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.VaultChangeCancelled(address(STEAKHOUSE_USDC), guardianAccount);
        vm.prank(guardianAccount);
        forwarder.cancelVaultChange();
        assertEq(address(forwarder.pendingVault()), address(0));
        assertEq(forwarder.pendingVaultExecutableAt(), 0);
        assertEq(address(forwarder.vault()), address(LUCA_VAULT));
        _fundAdminHealthCheck();
        vm.expectRevert(Forwarder.NoPendingVaultChange.selector);
        vm.prank(ADMIN);
        forwarder.executeVaultChange();

        address[] memory guardians = Config.vaultGuardians();
        for (uint256 i = 0; i < guardians.length; ++i) {
            _proposeAsAdmin(STEAKHOUSE_USDC);
            vm.prank(guardians[i]);
            forwarder.cancelVaultChange();
            assertEq(address(forwarder.pendingVault()), address(0));
        }
        _proposeAsAdmin(STEAKHOUSE_USDC);
        vm.prank(ADMIN);
        forwarder.cancelVaultChange();
        assertEq(address(forwarder.pendingVault()), address(0));
        assertEq(address(forwarder.vault()), address(LUCA_VAULT));
    }

    function test_Fork_GuardianCannotProposeOrExecute() public {
        _resetToBaseline();
        address guardianAccount = _guardian();
        bytes32 adminRole = forwarder.DEFAULT_ADMIN_ROLE();
        deal(address(USDC), guardianAccount, 1e6);
        vm.prank(guardianAccount);
        USDC.approve(address(forwarder), 1e6);
        _expectUnauthorized(guardianAccount, adminRole);
        vm.prank(guardianAccount);
        forwarder.proposeVault(STEAKHOUSE_USDC);

        _proposeAsAdmin(STEAKHOUSE_USDC);
        vm.warp(forwarder.pendingVaultExecutableAt());
        _expectUnauthorized(guardianAccount, adminRole);
        vm.prank(guardianAccount);
        forwarder.executeVaultChange();
        assertEq(address(forwarder.vault()), address(LUCA_VAULT));
        assertEq(address(forwarder.pendingVault()), address(STEAKHOUSE_USDC));
    }

    function test_Fork_RevokingGuardiansDoesNotShortenTheDelay() public {
        _resetToBaseline();
        address guardianAccount = _guardian();
        _proposeAsAdmin(STEAKHOUSE_USDC);
        uint256 executableAt = forwarder.pendingVaultExecutableAt();
        bytes32 role = forwarder.VAULT_GUARDIAN_ROLE();
        address[] memory guardians = Config.vaultGuardians();
        vm.startPrank(ADMIN);
        forwarder.revokeRole(role, guardianAccount);
        for (uint256 i = 0; i < guardians.length; ++i) {
            forwarder.revokeRole(role, guardians[i]);
        }
        vm.stopPrank();
        assertEq(forwarder.pendingVaultExecutableAt(), executableAt);

        _expectUnauthorized(guardianAccount, role);
        vm.prank(guardianAccount);
        forwarder.cancelVaultChange();

        vm.warp(executableAt - 1);
        _fundAdminHealthCheck();
        vm.expectRevert(abi.encodeWithSelector(Forwarder.VaultChangeDelayNotElapsed.selector, executableAt));
        vm.prank(ADMIN);
        forwarder.executeVaultChange();
        vm.warp(executableAt);
        vm.prank(ADMIN);
        forwarder.executeVaultChange();
        assertEq(address(forwarder.vault()), address(STEAKHOUSE_USDC));
    }

    /// @dev Case A: proposal in VAULT_VAULT; DIRECT_DIRECT is selected while pending; the new vault gets no allowance.
    function test_Fork_RoutingToDirectWhilePending() public {
        _resetToBaseline();
        _routing(Forwarder.RoutingMode.VAULT_VAULT);
        _proposeAsAdmin(STEAKHOUSE_USDC);
        assertEq(USDC.allowance(address(forwarder), address(LUCA_VAULT)), MAX, "active allowance kept");
        _forward(100e6, user);
        assertApproxEqAbs(_value(LUCA_VAULT, user), 100e6, 2);
        _routing(Forwarder.RoutingMode.DIRECT_DIRECT);
        assertEq(USDC.allowance(address(forwarder), address(LUCA_VAULT)), 0);
        vm.warp(forwarder.pendingVaultExecutableAt());
        _executeAsAdmin();
        assertEq(USDC.allowance(address(forwarder), address(LUCA_VAULT)), 0);
        assertEq(USDC.allowance(address(forwarder), address(STEAKHOUSE_USDC)), 0);
    }

    /// @dev Case B: proposal in DIRECT_DIRECT; VAULT_VAULT is selected while pending (active vault); the new vault gets
    /// the unlimited allowance at execution.
    function test_Fork_RoutingToVaultWhilePending() public {
        _resetToBaseline();
        _proposeAsAdmin(STEAKHOUSE_USDC);
        _routing(Forwarder.RoutingMode.VAULT_VAULT);
        assertEq(USDC.allowance(address(forwarder), address(LUCA_VAULT)), MAX);
        assertEq(USDC.allowance(address(forwarder), address(STEAKHOUSE_USDC)), 0);
        _forward(100e6, user);
        assertApproxEqAbs(_value(LUCA_VAULT, user), 100e6, 2);
        assertEq(STEAKHOUSE_USDC.balanceOf(user), 0);
        vm.warp(forwarder.pendingVaultExecutableAt());
        _executeAsAdmin();
        assertEq(USDC.allowance(address(forwarder), address(LUCA_VAULT)), 0);
        assertEq(USDC.allowance(address(forwarder), address(STEAKHOUSE_USDC)), MAX);
        _forward(100e6, user);
        assertApproxEqAbs(_value(STEAKHOUSE_USDC, user), 100e6, 2);
    }

    /// @dev The candidate stops working after the proposal (real Luca vault deposit pause): execution reverts and
    /// keeps everything; once the candidate recovers, the same proposal executes without a new one.
    function test_Fork_FailedExecutionKeepsPendingChange() public {
        _resetToBaseline();
        _routing(Forwarder.RoutingMode.VAULT_VAULT);
        _replaceVaultAsAdmin(STEAKHOUSE_USDC);
        _proposeAsAdmin(LUCA_VAULT);
        uint256 executableAt = forwarder.pendingVaultExecutableAt();
        _pauseLucaVault();
        vm.warp(executableAt);
        _fundAdminHealthCheck();
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        vm.prank(ADMIN);
        forwarder.executeVaultChange();
        assertEq(address(forwarder.vault()), address(STEAKHOUSE_USDC));
        assertEq(USDC.allowance(address(forwarder), address(STEAKHOUSE_USDC)), MAX);
        assertEq(USDC.allowance(address(forwarder), address(LUCA_VAULT)), 0);
        assertEq(address(forwarder.pendingVault()), address(LUCA_VAULT));
        assertEq(forwarder.pendingVaultExecutableAt(), executableAt);

        _unpauseLucaVault();
        vm.prank(ADMIN);
        forwarder.executeVaultChange();
        assertEq(address(forwarder.vault()), address(LUCA_VAULT));
        assertEq(USDC.allowance(address(forwarder), address(STEAKHOUSE_USDC)), 0);
        assertEq(USDC.allowance(address(forwarder), address(LUCA_VAULT)), MAX);
        assertEq(address(forwarder.pendingVault()), address(0));
    }

    function test_Fork_SecondProposalRequiresCancellation() public {
        _resetToBaseline();
        _proposeAsAdmin(STEAKHOUSE_USDC);
        _fundAdminHealthCheck();
        vm.expectRevert(abi.encodeWithSelector(Forwarder.VaultChangeAlreadyPending.selector, address(STEAKHOUSE_USDC)));
        vm.prank(ADMIN);
        forwarder.proposeVault(STEAKHOUSE_USDC);
        vm.prank(ADMIN);
        forwarder.cancelVaultChange();
        vm.prank(ADMIN);
        forwarder.proposeVault(STEAKHOUSE_USDC); // funded above
        assertEq(forwarder.pendingVaultExecutableAt(), block.timestamp + 72 hours);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Rescue
    // -----------------------------------------------------------------------------------------------------------

    function test_Fork_RescueRealTokensAndNative() public {
        address[5] memory tokens = [address(USDC), USDBC, DAI, USDT, WETH];
        uint256[5] memory amounts = [uint256(3e6), 4e6, 5e18, 6e6, 7e17];
        for (uint256 i = 0; i < tokens.length; ++i) {
            deal(tokens[i], address(forwarder), amounts[i]);
            uint256 before = IERC20(tokens[i]).balanceOf(TREASURY);
            vm.prank(ADMIN);
            forwarder.rescueToken(IERC20(tokens[i]));
            assertEq(IERC20(tokens[i]).balanceOf(TREASURY) - before, amounts[i]);
            assertEq(IERC20(tokens[i]).balanceOf(address(forwarder)), 0);
        }
        vm.deal(address(forwarder), 0.25 ether);
        uint256 nativeBefore = TREASURY.balance;
        vm.prank(ADMIN);
        forwarder.rescueNative();
        assertEq(TREASURY.balance - nativeBefore, 0.25 ether);
        assertEq(address(forwarder).balance, 0);
    }

    function test_Fork_RejectsDirectNative() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool success,) = address(forwarder).call{value: 1 ether}("");
        assertFalse(success);
    }

    function _emitted(Vm.Log[] memory logs, bytes32 topic) internal view returns (bool) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(forwarder) && logs[i].topics[0] == topic) return true;
        }
        return false;
    }
}
