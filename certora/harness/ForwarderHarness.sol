// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Forwarder} from "../../src/Forwarder.sol";

/// @dev Exposes read-only helpers to the Certora spec. Adds no state and no behaviour to the Forwarder.
contract ForwarderHarness is Forwarder {
    constructor(
        IERC20 usdc,
        address initialAdmin,
        uint48 initialAdminDelay,
        address initialTreasury,
        IERC4626 initialVault,
        RoutingMode initialRoutingMode,
        address[] memory initialFeeManagers,
        address[] memory initialVaultGuardians
    )
        Forwarder(
            usdc,
            initialAdmin,
            initialAdminDelay,
            initialTreasury,
            initialVault,
            initialRoutingMode,
            initialFeeManagers,
            initialVaultGuardians
        )
    {}

    function usdcAddress() external view returns (address) {
        return address(USDC);
    }

    function vaultAllowance() external view returns (uint256) {
        return USDC.allowance(address(this), address(vault));
    }

    function allowanceTo(address spender) external view returns (uint256) {
        return USDC.allowance(address(this), spender);
    }

    function usdcBalance(address account) external view returns (uint256) {
        return USDC.balanceOf(account);
    }

    /// @dev True while a `nonReentrant` function is executing (transient storage, zero at the start of a transaction).
    function reentrancyGuardEntered() external view returns (bool) {
        return _reentrancyGuardEntered();
    }

    /// @dev Raw storage values of the enums (no ABI enum decoding), used to state that they are always valid.
    function routingModeRaw() external view returns (uint8 value) {
        RoutingMode mode = routingMode;
        assembly ("memory-safe") {
            value := mode
        }
    }

    function lowerFeeModelRaw() external view returns (uint8 value) {
        FeeModel model = lowerFeeModel;
        assembly ("memory-safe") {
            value := model
        }
    }

    function upperFeeModelRaw() external view returns (uint8 value) {
        FeeModel model = upperFeeModel;
        assembly ("memory-safe") {
            value := model
        }
    }

    // Pending fee configuration and overrides, field by field (V3).

    function pendingLowerFeeModel() external view returns (FeeModel) {
        return pendingFeeConfig.lowerFeeModel;
    }

    function pendingUpperFeeModel() external view returns (FeeModel) {
        return pendingFeeConfig.upperFeeModel;
    }

    function pendingThreshold() external view returns (uint256) {
        return pendingFeeConfig.threshold;
    }

    function pendingFixedFee() external view returns (uint256) {
        return pendingFeeConfig.fixedFee;
    }

    function pendingVariableFee() external view returns (uint256) {
        return pendingFeeConfig.variableFee;
    }

    function pendingFeeExecutableAt() external view returns (uint256) {
        return pendingFeeConfig.executableAt;
    }

    function pendingLowerFeeModelRaw() external view returns (uint8 value) {
        FeeModel model = pendingFeeConfig.lowerFeeModel;
        assembly ("memory-safe") {
            value := model
        }
    }

    function pendingUpperFeeModelRaw() external view returns (uint8 value) {
        FeeModel model = pendingFeeConfig.upperFeeModel;
        assembly ("memory-safe") {
            value := model
        }
    }

    function overrideFixed(address recipient) external view returns (uint256) {
        return userFeeOverrides[recipient].fixedFee;
    }

    function overrideVariable(address recipient) external view returns (uint256) {
        return userFeeOverrides[recipient].variableFee;
    }

    function overrideUntil(address recipient) external view returns (uint256) {
        return userFeeOverrides[recipient].validUntil;
    }

    /// @dev The OpenZeppelin `Math.min` used by `calculateFeeFor`, exposed to prove that the CVL summary of
    /// certora/specs/ForwarderV3.spec is exact (certora/specs/MathMinSummary.spec).
    function mathMin(uint256 a, uint256 b) external pure returns (uint256) {
        return Math.min(a, b);
    }
}
