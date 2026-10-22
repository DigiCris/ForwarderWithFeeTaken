// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {DummyUSDC} from "./DummyUSDC.sol";

/// @dev 1:1 ERC-4626 model whose deposits and redeems can fail (`depositReverts`, `redeemReverts`). The prover
/// starts from arbitrary values of these flags, so every rule covers both the working and the failing vault.
contract DummyVault {
    DummyUSDC public underlying;
    mapping(address => uint256) public balanceOf;
    bool public depositReverts;
    bool public redeemReverts;

    function asset() external view returns (address) {
        return address(underlying);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256) {
        require(!depositReverts);
        underlying.transferFrom(msg.sender, address(this), assets);
        balanceOf[receiver] += assets;
        return assets;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256) {
        require(!redeemReverts && msg.sender == owner);
        balanceOf[owner] -= shares;
        underlying.transfer(receiver, shares);
        return shares;
    }
}
