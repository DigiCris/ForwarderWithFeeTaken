// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockVault} from "./MockVault.sol";

/// @dev Performs one reentrant call into `target` and records the outcome.
abstract contract Reenterer {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address public target;
    bytes public payload;
    address public prankAs;
    bool public attempted;
    bool public reentrySucceeded;
    bytes public reentryReturnData;

    /// @param prankAs_ If non-zero, the reentrant call is sent with this `msg.sender` (privileged reentry).
    function arm(address target_, bytes calldata payload_, address prankAs_) external {
        target = target_;
        payload = payload_;
        prankAs = prankAs_;
        attempted = false;
    }

    function _reenter() internal {
        if (target == address(0) || attempted) return;
        attempted = true;
        if (prankAs != address(0)) VM.prank(prankAs);
        (reentrySucceeded, reentryReturnData) = target.call(payload);
    }
}

/// @dev Vault that reenters `target` from inside `deposit`, then completes the deposit normally.
contract ReentrantVault is MockVault, Reenterer {
    constructor(IERC20 asset_) MockVault(asset_) {}

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        _reenter();
        super._deposit(caller, receiver, assets, shares);
    }
}

/// @dev ERC-20 that reenters `target` from inside `transfer`, then completes the transfer normally.
contract ReentrantToken is ERC20, Reenterer {
    constructor() ERC20("Reentrant", "REENT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _reenter();
        return super.transfer(to, amount);
    }
}
