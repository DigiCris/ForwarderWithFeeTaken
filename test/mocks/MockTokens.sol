// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Standard ERC-20 with configurable decimals (DAI-like or arbitrary tokens in rescue tests).
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev USDT-like token: `transfer`, `transferFrom` and `approve` return no value.
contract MockNoReturnToken {
    string public constant name = "Tether USD";
    string public constant symbol = "USDT";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(balanceOf[from] >= amount, "balance");
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }
}

/// @dev Token whose `transfer` returns false without moving funds.
contract MockFalseReturnToken is ERC20 {
    constructor() ERC20("False Token", "FALSE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @dev Account that rejects native transfers.
contract RejectNative {
    receive() external payable {
        revert("no native");
    }
}

/// @dev Sends its balance to `target` through SELFDESTRUCT (still transfers the balance after EIP-6780).
contract ForceSendNative {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}
