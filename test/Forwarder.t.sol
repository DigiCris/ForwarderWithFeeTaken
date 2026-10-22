// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {stdError} from "forge-std/StdError.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Forwarder} from "../src/Forwarder.sol";
import {MockERC20} from "./mocks/MockTokens.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockVault} from "./mocks/MockVault.sol";
import {ForwarderTestBase} from "./utils/ForwarderTestBase.sol";

/// @dev Constructor, constants and initial configuration.
contract ForwarderConstructorTest is ForwarderTestBase {
    function test_Constants() public view {
        assertEq(forwarder.FEE_MANAGER_ROLE(), keccak256("FEE_MANAGER_ROLE"));
        assertEq(forwarder.DEFAULT_ADMIN_ROLE(), bytes32(0));
        assertEq(forwarder.FEE_DENOMINATOR(), 100_000);
        assertEq(forwarder.MAX_VARIABLE_FEE(), 10_000);
        assertEq(forwarder.MAX_FIXED_FEE(), 10_000_000);
        assertEq(forwarder.VAULT_TEST_AMOUNT(), 1000);
    }

    function test_InitialState() public view {
        assertEq(address(forwarder.USDC()), address(usdc));
        assertEq(forwarder.defaultAdmin(), admin);
        assertEq(forwarder.owner(), admin);
        assertEq(forwarder.defaultAdminDelay(), ADMIN_DELAY);
        assertEq(forwarder.treasury(), treasury);
        assertEq(address(forwarder.vault()), address(vault));
        assertEq(uint8(forwarder.routingMode()), uint8(DIRECT_DIRECT));
        assertEq(uint8(forwarder.lowerFeeModel()), uint8(NONE));
        assertEq(uint8(forwarder.upperFeeModel()), uint8(NONE));
        assertEq(forwarder.threshold(), 0);
        assertEq(forwarder.fixedFee(), 0);
        assertEq(forwarder.variableFee(), 0);
        assertFalse(forwarder.paused());

        assertTrue(forwarder.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(forwarder.hasRole(FEE_MANAGER_ROLE, feeManager));
        assertTrue(forwarder.hasRole(FEE_MANAGER_ROLE, feeManager2));
        assertFalse(forwarder.hasRole(FEE_MANAGER_ROLE, admin));
        assertFalse(forwarder.hasRole(DEFAULT_ADMIN_ROLE, address(this)));
        assertFalse(forwarder.hasRole(FEE_MANAGER_ROLE, address(this)));
        assertEq(forwarder.getRoleAdmin(FEE_MANAGER_ROLE), DEFAULT_ADMIN_ROLE);

        assertEq(usdc.allowance(address(forwarder), address(vault)), 0);
        assertEq(forwarder.calculateFee(1_000_000e6), 0);
    }

    function test_DeploymentHealthCheckUsesAndRefundsDeployerFunds() public view {
        // `_deploy` minted TEST_AMOUNT to this contract; the constructor pulled it, ran the round trip and refunded it.
        assertEq(usdc.balanceOf(address(this)), TEST_AMOUNT);
        assertEq(usdc.balanceOf(address(forwarder)), 0);
        assertEq(vault.balanceOf(address(forwarder)), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(usdc.allowance(address(this), address(forwarder)), 0);
    }

    function test_DeployWithEachVaultModeSetsMaxAllowance() public {
        Forwarder.RoutingMode[3] memory modes = [VAULT_USER_DIRECT_TREASURY, DIRECT_USER_VAULT_TREASURY, VAULT_VAULT];
        for (uint256 i = 0; i < modes.length; ++i) {
            Forwarder f = _deploy(IERC4626(address(vault)), modes[i]);
            assertEq(uint8(f.routingMode()), uint8(modes[i]));
            assertEq(usdc.allowance(address(f), address(vault)), MAX);
        }
    }

    function test_DeployWithoutVault() public {
        Forwarder f = _deploy(IERC4626(address(0)), DIRECT_DIRECT);
        assertEq(address(f.vault()), address(0));
        assertEq(uint8(f.routingMode()), uint8(DIRECT_DIRECT));
    }

    function test_DeployEmitsConfigurationEvents() public {
        address predicted = _fundDeployment();

        vm.expectEmit(true, true, true, true, predicted);
        emit Forwarder.TreasuryUpdated(address(0), treasury);
        vm.expectEmit(true, true, true, true, predicted);
        emit Forwarder.VaultUpdated(address(0), address(vault), TEST_AMOUNT * 1e12, TEST_AMOUNT);
        vm.expectEmit(true, true, true, true, predicted);
        emit Forwarder.RoutingModeUpdated(DIRECT_DIRECT, VAULT_VAULT);
        vm.expectEmit(true, true, true, true, predicted);
        emit IAccessControl.RoleGranted(FEE_MANAGER_ROLE, feeManager, address(this));
        vm.expectEmit(true, true, true, true, predicted);
        emit IAccessControl.RoleGranted(FEE_MANAGER_ROLE, feeManager2, address(this));
        new Forwarder(
            IERC20(address(usdc)), admin, ADMIN_DELAY, treasury, IERC4626(address(vault)), VAULT_VAULT, _feeManagers()
        );
    }

    function test_DeployWithDuplicatedFeeManagers() public {
        address[] memory managers = new address[](3);
        managers[0] = feeManager;
        managers[1] = feeManager;
        managers[2] = admin;
        Forwarder f = new Forwarder(
            IERC20(address(usdc)), admin, ADMIN_DELAY, treasury, IERC4626(address(0)), DIRECT_DIRECT, managers
        );
        assertTrue(f.hasRole(FEE_MANAGER_ROLE, feeManager));
        assertTrue(f.hasRole(FEE_MANAGER_ROLE, admin));
    }

    function test_RevertWhen_DeployVaultModeWithoutVault() public {
        Forwarder.RoutingMode[3] memory modes = [VAULT_USER_DIRECT_TREASURY, DIRECT_USER_VAULT_TREASURY, VAULT_VAULT];
        for (uint256 i = 0; i < modes.length; ++i) {
            vm.expectRevert(Forwarder.VaultNotSet.selector);
            new Forwarder(
                IERC20(address(usdc)), admin, ADMIN_DELAY, treasury, IERC4626(address(0)), modes[i], _feeManagers()
            );
        }
    }

    function test_RevertWhen_DeployZeroUsdc() public {
        vm.expectRevert(Forwarder.ZeroAddress.selector);
        new Forwarder(
            IERC20(address(0)), admin, ADMIN_DELAY, treasury, IERC4626(address(0)), DIRECT_DIRECT, _feeManagers()
        );
    }

    function test_RevertWhen_DeployZeroAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector, address(0)
            )
        );
        new Forwarder(
            IERC20(address(usdc)),
            address(0),
            ADMIN_DELAY,
            treasury,
            IERC4626(address(0)),
            DIRECT_DIRECT,
            _feeManagers()
        );
    }

    function test_RevertWhen_DeployZeroTreasury() public {
        vm.expectRevert(abi.encodeWithSelector(Forwarder.InvalidTreasury.selector, address(0)));
        new Forwarder(
            IERC20(address(usdc)), admin, ADMIN_DELAY, address(0), IERC4626(address(0)), DIRECT_DIRECT, _feeManagers()
        );
    }

    function test_RevertWhen_DeployZeroFeeManager() public {
        address[] memory managers = new address[](2);
        managers[0] = feeManager;
        vm.expectRevert(Forwarder.ZeroAddress.selector);
        new Forwarder(
            IERC20(address(usdc)), admin, ADMIN_DELAY, treasury, IERC4626(address(0)), DIRECT_DIRECT, managers
        );
    }

    function test_RevertWhen_DeployHealthCheckNotFunded() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, predicted, 0, TEST_AMOUNT)
        );
        new Forwarder(
            IERC20(address(usdc)), admin, ADMIN_DELAY, treasury, IERC4626(address(vault)), DIRECT_DIRECT, _feeManagers()
        );
    }

    function test_RevertWhen_DeployWithWrongAssetVault() public {
        MockERC20 other = new MockERC20("Other", "OTH", 6);
        MockVault wrongVault = new MockVault(IERC20(address(other)));
        _fundDeployment();
        vm.expectRevert(
            abi.encodeWithSelector(Forwarder.VaultAssetMismatch.selector, address(wrongVault), address(other))
        );
        new Forwarder(
            IERC20(address(usdc)),
            admin,
            ADMIN_DELAY,
            treasury,
            IERC4626(address(wrongVault)),
            DIRECT_DIRECT,
            _feeManagers()
        );
    }

    function test_RevertWhen_DeployWithFailingVault() public {
        vault.setRedeemReverts(true);
        _fundDeployment();
        vm.expectRevert(MockVault.RedeemDisabled.selector);
        new Forwarder(
            IERC20(address(usdc)), admin, ADMIN_DELAY, treasury, IERC4626(address(vault)), VAULT_VAULT, _feeManagers()
        );
    }

    function test_SupportsInterface() public view {
        assertTrue(forwarder.supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(forwarder.supportsInterface(type(IAccessControlDefaultAdminRules).interfaceId));
        assertTrue(forwarder.supportsInterface(type(IERC165).interfaceId));
        assertFalse(forwarder.supportsInterface(0xffffffff));
    }

    function test_RejectsDirectNativeTransfers() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool success,) = address(forwarder).call{value: 1 ether}("");
        assertFalse(success);
        assertEq(address(forwarder).balance, 0);
    }

    /// @dev The runtime code contains no DELEGATECALL, CALLCODE or SELFDESTRUCT opcode (no upgrade/proxy path).
    function test_RuntimeCodeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory code = address(forwarder).code;
        // Strip the CBOR metadata: its length is stored in the last two bytes.
        uint256 metadataLength =
            (uint256(uint8(code[code.length - 2])) << 8 | uint256(uint8(code[code.length - 1]))) + 2;
        uint256 end = code.length - metadataLength;
        for (uint256 i = 0; i < end; ++i) {
            uint8 op = uint8(code[i]);
            assertTrue(op != 0xf4, "DELEGATECALL");
            assertTrue(op != 0xf2, "CALLCODE");
            assertTrue(op != 0xff, "SELFDESTRUCT");
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f; // skip PUSH1..PUSH32 data
        }
    }
}

/// @dev Fee calculation (spec section 4 and 5).
contract ForwarderFeeTest is ForwarderTestBase {
    function test_VariableFeeGranularity() public {
        uint256 amount = 1000e6; // 1,000 USDC
        uint256[5] memory variableFees = [uint256(0), 1, 100, 1000, 10_000]; // 0%, 0.001%, 0.1%, 1%, 10%
        uint256[5] memory expected = [uint256(0), 10_000, 1e6, 10e6, 100e6];
        for (uint256 i = 0; i < variableFees.length; ++i) {
            _setFees(PERCENT, PERCENT, 0, 0, variableFees[i]);
            assertEq(forwarder.calculateFee(amount), expected[i]);
        }
    }

    function test_VariableFeeAtMaximumIsAccepted() public {
        vm.prank(feeManager);
        forwarder.setVariableFee(10_000);
        assertEq(forwarder.variableFee(), 10_000);
    }

    function test_RevertWhen_VariableFeeAboveMaximum() public {
        vm.startPrank(feeManager);
        vm.expectRevert(abi.encodeWithSelector(Forwarder.VariableFeeTooHigh.selector, 10_001));
        forwarder.setVariableFee(10_001);
        vm.expectRevert(abi.encodeWithSelector(Forwarder.VariableFeeTooHigh.selector, 10_001));
        forwarder.setFeeConfig(PERCENT, PERCENT, 0, 0, 10_001);
        vm.expectRevert(abi.encodeWithSelector(Forwarder.VariableFeeTooHigh.selector, MAX));
        forwarder.setVariableFee(MAX);
        vm.stopPrank();
        assertEq(forwarder.variableFee(), 0);
    }

    function test_FixedFeeValues() public {
        uint256[3] memory fixedFees = [uint256(0), 1, 10e6]; // 0, 0.000001 USDC, 10 USDC
        for (uint256 i = 0; i < fixedFees.length; ++i) {
            _setFees(FIXED, FIXED, 0, fixedFees[i], 0);
            assertEq(forwarder.calculateFee(100e6), fixedFees[i]);
        }
    }

    function test_RevertWhen_FixedFeeAboveMaximum() public {
        vm.startPrank(feeManager);
        vm.expectRevert(abi.encodeWithSelector(Forwarder.FixedFeeTooHigh.selector, 10e6 + 1));
        forwarder.setFixedFee(10e6 + 1);
        vm.expectRevert(abi.encodeWithSelector(Forwarder.FixedFeeTooHigh.selector, 10e6 + 1));
        forwarder.setFeeConfig(FIXED, FIXED, 0, 10e6 + 1, 0);
        vm.stopPrank();
        assertEq(forwarder.fixedFee(), 0);
    }

    function test_EachFeeModel() public {
        uint256 amount = 250e6;
        // fixed 2 USDC, variable 1%
        _setFees(NONE, NONE, 0, 2e6, 1000);
        assertEq(forwarder.calculateFee(amount), 0);
        _setFees(FIXED, FIXED, 0, 2e6, 1000);
        assertEq(forwarder.calculateFee(amount), 2e6);
        _setFees(PERCENT, PERCENT, 0, 2e6, 1000);
        assertEq(forwarder.calculateFee(amount), 2.5e6);
        _setFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, 2e6, 1000);
        assertEq(forwarder.calculateFee(amount), 4.5e6);
    }

    function test_ThresholdBoundaries() public {
        // <= 100 USDC: FIXED 3 USDC; > 100 USDC: PERCENT 2%.
        _setFees(FIXED, PERCENT, 100e6, 3e6, 2000);
        assertEq(forwarder.calculateFee(100e6 - 1), 3e6, "below threshold");
        assertEq(forwarder.calculateFee(100e6), 3e6, "at threshold");
        assertEq(forwarder.calculateFee(100e6 + 1), 2_000_000, "above threshold"); // floor(100.000001 * 2%)
        assertEq(forwarder.calculateFee(200e6), 4e6);
    }

    function test_FeeUsesFullAmountAboveThreshold() public {
        // Spec example: up to 100 USDC FIXED, above PERCENT. 150 USDC pays 1% of 150, not of the 50 excess.
        _setFees(FIXED, PERCENT, 100e6, 1e6, 1000);
        assertEq(forwarder.calculateFee(150e6), 1.5e6);

        _forward(150e6, user);
        assertEq(usdc.balanceOf(user), 148.5e6);
        assertEq(usdc.balanceOf(treasury), 1.5e6);
    }

    function test_FeeUsesFullAmountWhenUpperIsFixedPlusPercent() public {
        _setFees(PERCENT, FIXED_PLUS_PERCENT, 1000e6, 5e6, 500);
        assertEq(forwarder.calculateFee(1000e6), 5e6); // 0.5% of 1,000
        assertEq(forwarder.calculateFee(3000e6), 5e6 + 15e6); // 5 + 0.5% of 3,000
    }

    function test_AllModelCombinationsAroundThreshold() public {
        Forwarder.FeeModel[4] memory models = [NONE, FIXED, PERCENT, FIXED_PLUS_PERCENT];
        uint256 thresholdValue = 500e6;
        uint256 fixedValue = 7e6;
        uint256 variableValue = 3333;
        uint256[5] memory amounts = [uint256(0), 1, thresholdValue - 1, thresholdValue, thresholdValue + 1];
        for (uint256 l = 0; l < 4; ++l) {
            for (uint256 u = 0; u < 4; ++u) {
                _setFees(models[l], models[u], thresholdValue, fixedValue, variableValue);
                for (uint256 a = 0; a < amounts.length; ++a) {
                    uint256 expected = _referenceFee(
                        models[l], models[u], thresholdValue, fixedValue, variableValue, false, amounts[a]
                    );
                    assertEq(forwarder.calculateFee(amounts[a]), expected);
                }
                // Large amount: the selected model is applied to the whole amount.
                uint256 big = 10_000e6;
                uint256 bigFee = models[u] == NONE
                    ? 0
                    : models[u] == FIXED
                        ? fixedValue
                        : models[u] == PERCENT
                            ? big * variableValue / 100_000
                            : fixedValue + big * variableValue / 100_000;
                assertEq(forwarder.calculateFee(big), bigFee);
            }
        }
    }

    function test_PercentRoundsDown() public {
        _setFees(PERCENT, PERCENT, 0, 0, 1); // 0.001%
        assertEq(forwarder.calculateFee(99_999), 0);
        assertEq(forwarder.calculateFee(100_000), 1);
        assertEq(forwarder.calculateFee(199_999), 1);
    }

    function test_MaximumFeeConfiguration() public {
        _setFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, 10e6, 10_000);
        assertEq(forwarder.calculateFee(1000e6), 110e6);
    }

    function test_DefaultThresholdZero() public {
        _setFees(FIXED, PERCENT, 0, 1e6, 1000);
        assertEq(forwarder.calculateFee(0), 1e6); // 0 <= 0 -> lower
        assertEq(forwarder.calculateFee(100e6), 1e6); // > 0 -> upper (1%)
        assertEq(forwarder.calculateFee(1), 0); // upper: floor(1 * 1%)
    }

    function test_MaxThresholdAlwaysUsesLowerModel() public {
        _setFees(FIXED, PERCENT, MAX, 1e6, 1000);
        assertEq(forwarder.calculateFee(MAX), 1e6);
        assertEq(forwarder.calculateFee(1e30), 1e6);
    }

    function test_PausedFeeIsZero() public {
        _setFees(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 100e6, 10e6, 10_000);
        vm.prank(feeManager);
        forwarder.pause();
        assertEq(forwarder.calculateFee(0), 0);
        assertEq(forwarder.calculateFee(1), 0);
        assertEq(forwarder.calculateFee(100e6), 0);
        assertEq(forwarder.calculateFee(1_000_000e6), 0);

        _forward(50e6, user);
        assertEq(usdc.balanceOf(user), 50e6);
        assertEq(usdc.balanceOf(treasury), 0);

        vm.prank(admin);
        forwarder.unpause();
        assertEq(forwarder.calculateFee(1000e6), 110e6);
    }

    function test_FeeEqualToAmount() public {
        _setFees(FIXED, FIXED, 0, 5e6, 0);
        _fundSra(5e6);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.Forwarded(sra, user, 5e6, 5e6, 0, false, 0);
        vm.prank(sra);
        forwarder.forward(address(usdc), 5e6, user);
        assertEq(usdc.balanceOf(user), 0);
        assertEq(usdc.balanceOf(treasury), 5e6);
        assertEq(usdc.balanceOf(address(forwarder)), 0);
    }

    function test_FeeJustBelowAmount() public {
        _setFees(FIXED, FIXED, 0, 5e6, 0);
        _forward(5e6 + 1, user);
        assertEq(usdc.balanceOf(user), 1);
        assertEq(usdc.balanceOf(treasury), 5e6);
    }

    function test_RevertWhen_FeeAboveAmount() public {
        _setFees(FIXED, FIXED, 0, 5e6, 0);
        _fundSra(5e6 - 1);
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(sra);
        forwarder.forward(address(usdc), 5e6 - 1, user);
        assertEq(usdc.balanceOf(sra), 5e6 - 1);
    }

    function test_RevertWhen_FixedFeeAndZeroAmount() public {
        _setFees(FIXED, FIXED, 0, 1, 0);
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(sra);
        forwarder.forward(address(usdc), 0, user);
    }

    function test_IndividualSettersEmitFullConfig() public {
        vm.startPrank(feeManager);
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.FeeConfigUpdated(NONE, NONE, 0, 0, 1000);
        forwarder.setVariableFee(1000);

        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.FeeConfigUpdated(NONE, NONE, 0, 2e6, 1000);
        forwarder.setFixedFee(2e6);

        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.FeeConfigUpdated(NONE, NONE, 100e6, 2e6, 1000);
        forwarder.setThreshold(100e6);

        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.FeeConfigUpdated(FIXED, NONE, 100e6, 2e6, 1000);
        forwarder.setLowerFeeModel(FIXED);

        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.FeeConfigUpdated(FIXED, FIXED_PLUS_PERCENT, 100e6, 2e6, 1000);
        forwarder.setUpperFeeModel(FIXED_PLUS_PERCENT);

        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.FeeConfigUpdated(PERCENT, FIXED, 7, 8, 9);
        forwarder.setFeeConfig(PERCENT, FIXED, 7, 8, 9);
        vm.stopPrank();

        assertEq(uint8(forwarder.lowerFeeModel()), uint8(PERCENT));
        assertEq(uint8(forwarder.upperFeeModel()), uint8(FIXED));
        assertEq(forwarder.threshold(), 7);
        assertEq(forwarder.fixedFee(), 8);
        assertEq(forwarder.variableFee(), 9);
    }

    function test_RevertWhen_InvalidEnumValue() public {
        vm.prank(feeManager);
        (bool success,) = address(forwarder).call(abi.encodeWithSelector(Forwarder.setLowerFeeModel.selector, 4));
        assertFalse(success);
        vm.prank(admin);
        (success,) = address(forwarder).call(abi.encodeWithSelector(Forwarder.setRoutingMode.selector, 4));
        assertFalse(success);
    }
}

/// @dev Roles (spec sections 12 and 13).
contract ForwarderAccessControlTest is ForwarderTestBase {
    function _expectUnauthorized(address account, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role));
    }

    function _adminOnlyCalls() internal view returns (bytes[] memory calls) {
        calls = new bytes[](12);
        calls[0] = abi.encodeCall(Forwarder.setTreasury, (stranger));
        calls[1] = abi.encodeCall(Forwarder.setVault, (IERC4626(address(vault))));
        calls[2] = abi.encodeCall(Forwarder.setRoutingMode, (VAULT_VAULT));
        calls[3] = abi.encodeCall(Forwarder.rescueToken, (IERC20(address(usdc))));
        calls[4] = abi.encodeCall(Forwarder.rescueNative, ());
        calls[5] = abi.encodeCall(Forwarder.unpause, ());
        calls[6] = abi.encodeCall(IAccessControl.grantRole, (FEE_MANAGER_ROLE, stranger));
        calls[7] = abi.encodeCall(IAccessControl.revokeRole, (FEE_MANAGER_ROLE, feeManager));
        calls[8] = abi.encodeCall(IAccessControlDefaultAdminRules.beginDefaultAdminTransfer, (stranger));
        calls[9] = abi.encodeCall(IAccessControlDefaultAdminRules.cancelDefaultAdminTransfer, ());
        calls[10] = abi.encodeCall(IAccessControlDefaultAdminRules.changeDefaultAdminDelay, (1 days));
        calls[11] = abi.encodeCall(IAccessControlDefaultAdminRules.rollbackDefaultAdminDelay, ());
    }

    function _feeManagerOnlyCalls() internal pure returns (bytes[] memory calls) {
        calls = new bytes[](6);
        calls[0] = abi.encodeCall(Forwarder.setFeeConfig, (FIXED, PERCENT, 1, 2, 3));
        calls[1] = abi.encodeCall(Forwarder.setVariableFee, (1));
        calls[2] = abi.encodeCall(Forwarder.setFixedFee, (1));
        calls[3] = abi.encodeCall(Forwarder.setThreshold, (1));
        calls[4] = abi.encodeCall(Forwarder.setLowerFeeModel, (FIXED));
        calls[5] = abi.encodeCall(Forwarder.setUpperFeeModel, (FIXED));
    }

    function test_FeeManagerAndStrangerCannotCallAdminFunctions() public {
        vm.prank(feeManager);
        forwarder.pause(); // makes `unpause` reach the role check rather than the pause check
        bytes[] memory calls = _adminOnlyCalls();
        address[2] memory callers = [feeManager, stranger];
        for (uint256 c = 0; c < callers.length; ++c) {
            for (uint256 i = 0; i < calls.length; ++i) {
                vm.prank(callers[c]);
                (bool success, bytes memory returnData) = address(forwarder).call(calls[i]);
                assertFalse(success);
                assertEq(
                    returnData,
                    abi.encodeWithSelector(
                        IAccessControl.AccessControlUnauthorizedAccount.selector, callers[c], DEFAULT_ADMIN_ROLE
                    )
                );
            }
        }
    }

    function test_AdminAndStrangerCannotCallFeeManagerFunctions() public {
        bytes[] memory calls = _feeManagerOnlyCalls();
        address[2] memory callers = [admin, stranger];
        for (uint256 c = 0; c < callers.length; ++c) {
            for (uint256 i = 0; i < calls.length; ++i) {
                vm.prank(callers[c]);
                (bool success, bytes memory returnData) = address(forwarder).call(calls[i]);
                assertFalse(success);
                assertEq(
                    returnData,
                    abi.encodeWithSelector(
                        IAccessControl.AccessControlUnauthorizedAccount.selector, callers[c], FEE_MANAGER_ROLE
                    )
                );
            }
        }
    }

    function test_EveryFeeManagerCanSetFees() public {
        bytes[] memory calls = _feeManagerOnlyCalls();
        address[2] memory managers = [feeManager, feeManager2];
        for (uint256 m = 0; m < managers.length; ++m) {
            for (uint256 i = 0; i < calls.length; ++i) {
                vm.prank(managers[m]);
                (bool success,) = address(forwarder).call(calls[i]);
                assertTrue(success);
            }
        }
    }

    function test_FeeManagerCanPause() public {
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Pausable.Paused(feeManager);
        vm.prank(feeManager);
        forwarder.pause();
        assertTrue(forwarder.paused());
    }

    function test_AdminCanPause() public {
        vm.prank(admin);
        forwarder.pause();
        assertTrue(forwarder.paused());
    }

    function test_RevertWhen_StrangerPauses() public {
        _expectUnauthorized(stranger, FEE_MANAGER_ROLE);
        vm.prank(stranger);
        forwarder.pause();
    }

    function test_RevertWhen_PauseWhilePaused() public {
        vm.prank(feeManager);
        forwarder.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(feeManager2);
        forwarder.pause();
    }

    function test_FeeManagerCannotUnpause() public {
        vm.prank(feeManager);
        forwarder.pause();
        _expectUnauthorized(feeManager, DEFAULT_ADMIN_ROLE);
        vm.prank(feeManager);
        forwarder.unpause();
        assertTrue(forwarder.paused());
    }

    function test_AdminCanUnpause() public {
        vm.prank(feeManager);
        forwarder.pause();
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Pausable.Unpaused(admin);
        vm.prank(admin);
        forwarder.unpause();
        assertFalse(forwarder.paused());
    }

    function test_RevertWhen_UnpauseWhileNotPaused() public {
        vm.expectRevert(Pausable.ExpectedPause.selector);
        vm.prank(admin);
        forwarder.unpause();
    }

    function test_FeeManagerCannotChangeTreasuryVaultRoutingOrRescue() public {
        vm.startPrank(feeManager);
        _expectUnauthorized(feeManager, DEFAULT_ADMIN_ROLE);
        forwarder.setTreasury(feeManager);
        _expectUnauthorized(feeManager, DEFAULT_ADMIN_ROLE);
        forwarder.setVault(IERC4626(address(vault)));
        _expectUnauthorized(feeManager, DEFAULT_ADMIN_ROLE);
        forwarder.setRoutingMode(VAULT_VAULT);
        _expectUnauthorized(feeManager, DEFAULT_ADMIN_ROLE);
        forwarder.rescueToken(IERC20(address(usdc)));
        _expectUnauthorized(feeManager, DEFAULT_ADMIN_ROLE);
        forwarder.rescueNative();
        vm.stopPrank();
        assertEq(forwarder.treasury(), treasury);
        assertEq(uint8(forwarder.routingMode()), uint8(DIRECT_DIRECT));
    }

    function test_FeeManagerCannotGrantRoles() public {
        _expectUnauthorized(feeManager, DEFAULT_ADMIN_ROLE);
        vm.prank(feeManager);
        forwarder.grantRole(FEE_MANAGER_ROLE, stranger);

        vm.expectRevert(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector);
        vm.prank(feeManager);
        forwarder.grantRole(DEFAULT_ADMIN_ROLE, feeManager);

        _expectUnauthorized(feeManager, DEFAULT_ADMIN_ROLE);
        vm.prank(feeManager);
        forwarder.beginDefaultAdminTransfer(feeManager);
        assertFalse(forwarder.hasRole(FEE_MANAGER_ROLE, stranger));
    }

    function test_AdminManagesFeeManagers() public {
        vm.prank(admin);
        forwarder.grantRole(FEE_MANAGER_ROLE, stranger);
        vm.prank(stranger);
        forwarder.setVariableFee(5);
        assertEq(forwarder.variableFee(), 5);

        vm.prank(admin);
        forwarder.revokeRole(FEE_MANAGER_ROLE, stranger);
        _expectUnauthorized(stranger, FEE_MANAGER_ROLE);
        vm.prank(stranger);
        forwarder.setVariableFee(6);
    }

    function test_FeeManagerCanRenounce() public {
        vm.prank(feeManager);
        forwarder.renounceRole(FEE_MANAGER_ROLE, feeManager);
        assertFalse(forwarder.hasRole(FEE_MANAGER_ROLE, feeManager));
    }

    function test_DefaultAdminCannotBeGrantedDirectly() public {
        vm.expectRevert(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector);
        vm.prank(admin);
        forwarder.grantRole(DEFAULT_ADMIN_ROLE, stranger);
    }

    function test_DefaultAdminTransferRespectsDelay() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        forwarder.beginDefaultAdminTransfer(newAdmin);
        (address pending, uint48 schedule) = forwarder.pendingDefaultAdmin();
        assertEq(pending, newAdmin);
        assertEq(schedule, block.timestamp + ADMIN_DELAY);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, schedule
            )
        );
        vm.prank(newAdmin);
        forwarder.acceptDefaultAdminTransfer();

        vm.warp(schedule + 1);
        vm.prank(newAdmin);
        forwarder.acceptDefaultAdminTransfer();
        assertEq(forwarder.defaultAdmin(), newAdmin);
        assertFalse(forwarder.hasRole(DEFAULT_ADMIN_ROLE, admin));

        _expectUnauthorized(admin, DEFAULT_ADMIN_ROLE);
        vm.prank(admin);
        forwarder.setTreasury(stranger);
        vm.prank(newAdmin);
        forwarder.setTreasury(stranger);
        assertEq(forwarder.treasury(), stranger);
    }

    /// @dev A compromised fee manager can misconfigure fees (within caps) or pause them, nothing else.
    function test_CompromisedFeeManagerBlastRadius() public {
        vm.startPrank(feeManager);
        forwarder.setFeeConfig(FIXED_PLUS_PERCENT, FIXED_PLUS_PERCENT, 0, 10e6, 10_000);
        forwarder.pause();
        vm.expectRevert();
        forwarder.unpause();
        vm.expectRevert();
        forwarder.setTreasury(feeManager);
        vm.expectRevert();
        forwarder.setFeeConfig(FIXED, FIXED, 0, 10e6 + 1, 0);
        vm.stopPrank();
        assertEq(forwarder.treasury(), treasury);
        assertTrue(forwarder.paused());
        assertEq(forwarder.calculateFee(1000e6), 0);
    }
}

/// @dev Input validation of `forward` and admin setters.
contract ForwarderValidationTest is ForwarderTestBase {
    function test_RevertWhen_TokenIsNotUsdc() public {
        MockERC20 other = new MockERC20("Other", "OTH", 6);
        vm.expectRevert(abi.encodeWithSelector(Forwarder.UnsupportedToken.selector, address(other)));
        vm.prank(sra);
        forwarder.forward(address(other), 1e6, user);

        vm.expectRevert(abi.encodeWithSelector(Forwarder.UnsupportedToken.selector, address(0)));
        vm.prank(sra);
        forwarder.forward(address(0), 1e6, user);
    }

    function test_RevertWhen_RecipientIsZero() public {
        _fundSra(1e6);
        vm.expectRevert(abi.encodeWithSelector(Forwarder.InvalidRecipient.selector, address(0)));
        vm.prank(sra);
        forwarder.forward(address(usdc), 1e6, address(0));
    }

    function test_RevertWhen_RecipientIsForwarder() public {
        _fundSra(1e6);
        vm.expectRevert(abi.encodeWithSelector(Forwarder.InvalidRecipient.selector, address(forwarder)));
        vm.prank(sra);
        forwarder.forward(address(usdc), 1e6, address(forwarder));
    }

    function test_RevertWhen_CallerHasNoAllowance() public {
        usdc.mint(sra, 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(forwarder), 0, 1e6)
        );
        vm.prank(sra);
        forwarder.forward(address(usdc), 1e6, user);
    }

    function test_RevertWhen_CallerHasNoBalance() public {
        vm.prank(sra);
        usdc.approve(address(forwarder), 1e6);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, sra, 0, 1e6));
        vm.prank(sra);
        forwarder.forward(address(usdc), 1e6, user);
    }

    function test_RevertWhen_UsdcIsPaused() public {
        _fundSra(1e6);
        usdc.setPaused(true);
        vm.expectRevert(MockUSDC.TokenPaused.selector);
        vm.prank(sra);
        forwarder.forward(address(usdc), 1e6, user);
    }

    function test_AnyCallerCanForwardItsOwnFunds() public {
        usdc.mint(stranger, 3e6);
        vm.startPrank(stranger);
        usdc.approve(address(forwarder), 3e6);
        forwarder.forward(address(usdc), 3e6, user);
        vm.stopPrank();
        assertEq(usdc.balanceOf(user), 3e6);
    }

    function test_ForwardWorksWhilePaused() public {
        vm.prank(admin);
        forwarder.pause();
        _forward(10e6, user);
        assertEq(usdc.balanceOf(user), 10e6);
    }

    function test_SetTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        vm.expectEmit(true, true, true, true, address(forwarder));
        emit Forwarder.TreasuryUpdated(treasury, newTreasury);
        vm.prank(admin);
        forwarder.setTreasury(newTreasury);
        assertEq(forwarder.treasury(), newTreasury);
    }

    function test_RevertWhen_TreasuryIsZeroOrForwarder() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Forwarder.InvalidTreasury.selector, address(0)));
        forwarder.setTreasury(address(0));
        vm.expectRevert(abi.encodeWithSelector(Forwarder.InvalidTreasury.selector, address(forwarder)));
        forwarder.setTreasury(address(forwarder));
        vm.stopPrank();
    }

    function test_RevertWhen_VaultModeWithoutVault() public {
        forwarder = _deploy(IERC4626(address(0)), DIRECT_DIRECT);
        vm.startPrank(admin);
        vm.expectRevert(Forwarder.VaultNotSet.selector);
        forwarder.setRoutingMode(VAULT_USER_DIRECT_TREASURY);
        vm.expectRevert(Forwarder.VaultNotSet.selector);
        forwarder.setRoutingMode(DIRECT_USER_VAULT_TREASURY);
        vm.expectRevert(Forwarder.VaultNotSet.selector);
        forwarder.setRoutingMode(VAULT_VAULT);
        forwarder.setRoutingMode(DIRECT_DIRECT);
        vm.stopPrank();
    }
}
