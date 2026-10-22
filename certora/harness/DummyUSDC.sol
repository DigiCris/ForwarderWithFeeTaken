// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev USDC model for the prover: plain balances, an allowance that is always decremented (FiatToken behaviour)
/// and a `blocked` flag that makes any transfer to or from an account revert (blacklist).
contract DummyUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blocked;

    function transfer(address to, uint256 amount) external returns (bool) {
        require(!blocked[msg.sender] && !blocked[to]);
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(!blocked[msg.sender] && !blocked[from] && !blocked[to]);
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}
