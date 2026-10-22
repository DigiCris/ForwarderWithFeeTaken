// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockVault} from "./MockVault.sol";

/// @dev Vault whose reported `asset()` can be switched after a proposal (e.g. a proxy upgraded to another asset).
contract AssetSwitchVault is MockVault {
    address public reportedAsset;

    constructor(IERC20 asset_) MockVault(asset_) {}

    function setReportedAsset(address value) external {
        reportedAsset = value;
    }

    function asset() public view override returns (address) {
        return reportedAsset == address(0) ? super.asset() : reportedAsset;
    }
}
