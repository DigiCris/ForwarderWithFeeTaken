// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

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
        address[] memory initialFeeManagers
    )
        Forwarder(
            usdc, initialAdmin, initialAdminDelay, initialTreasury, initialVault, initialRoutingMode, initialFeeManagers
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
}
