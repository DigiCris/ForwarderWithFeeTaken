// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @dev USDC stand-in for unit tests. Mirrors the FiatToken behaviours that matter to the Forwarder:
 * - 6 decimals;
 * - `transferFrom` always decrements the allowance, even when it is `type(uint256).max`;
 * - blacklisted accounts cannot send nor receive (reverts);
 * - the whole token can be paused (reverts).
 * It can also be configured to return `false` (without moving funds) on transfers to a given account, which real
 * USDC never does, to exercise the "returns false" branch of the best-effort treasury delivery.
 */
contract MockUSDC is ERC20 {
    mapping(address account => bool) public isBlacklisted;
    mapping(address account => bool) public returnFalseOnTransferTo;
    bool public paused;

    error Blacklisted(address account);
    error TokenPaused();

    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlacklisted(address account, bool value) external {
        isBlacklisted[account] = value;
    }

    function setReturnFalseOnTransferTo(address account, bool value) external {
        returnFalseOnTransferTo[account] = value;
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (returnFalseOnTransferTo[to]) return false;
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (returnFalseOnTransferTo[to]) return false;
        uint256 currentAllowance = allowance(from, msg.sender);
        if (currentAllowance < value) revert ERC20InsufficientAllowance(msg.sender, currentAllowance, value);
        _approve(from, msg.sender, currentAllowance - value, false);
        _transfer(from, to, value);
        return true;
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        _requireAllowed(msg.sender);
        _requireAllowed(spender);
        return super.approve(spender, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        _requireAllowed(from);
        _requireAllowed(to);
        _requireAllowed(msg.sender);
        super._update(from, to, value);
    }

    function _requireAllowed(address account) private view {
        if (paused) revert TokenPaused();
        if (isBlacklisted[account]) revert Blacklisted(account);
    }
}
