// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @dev OpenZeppelin ERC-4626 vault with switches to reproduce vault failures in unit tests. Shares use 18 decimals
 * (offset 12 over a 6-decimals asset) like the production Luca Money Vault.
 */
contract MockVault is ERC4626 {
    bool public depositReverts;
    bool public zeroDepositReverts;
    bool public mintsNoShares;
    bool public redeemReverts;
    bool public redeemPaysNothing;
    uint256 public redeemLossBps;
    bool public paused;
    uint256 public depositCap = type(uint256).max;
    address public blockedReceiver;
    uint256 public partialPullBps;

    error DepositDisabled();
    error ReceiverBlocked(address receiver);
    error ZeroDeposit();
    error RedeemDisabled();

    constructor(IERC20 asset_) ERC20("Mock Vault USDC", "mvUSDC") ERC4626(asset_) {}

    function setDepositReverts(bool value) external {
        depositReverts = value;
    }

    function setZeroDepositReverts(bool value) external {
        zeroDepositReverts = value;
    }

    function setMintsNoShares(bool value) external {
        mintsNoShares = value;
    }

    function setRedeemReverts(bool value) external {
        redeemReverts = value;
    }

    function setRedeemPaysNothing(bool value) external {
        redeemPaysNothing = value;
    }

    function setRedeemLossBps(uint256 value) external {
        redeemLossBps = value;
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setDepositCap(uint256 value) external {
        depositCap = value;
    }

    /// @dev Deposits whose receiver is `value` revert (e.g. only the treasury deposit fails).
    function setBlockedReceiver(address value) external {
        blockedReceiver = value;
    }

    /// @dev Non-compliant behaviour: `deposit` pulls only `partialPullBps` of the assets but mints the full shares.
    function setPartialPullBps(uint256 value) external {
        partialPullBps = value;
    }

    function maxDeposit(address) public view override returns (uint256) {
        return paused ? 0 : depositCap;
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 12;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        if (depositReverts) revert DepositDisabled();
        if (zeroDepositReverts && assets == 0) revert ZeroDeposit();
        if (receiver == blockedReceiver) revert ReceiverBlocked(receiver);
        if (partialPullBps != 0) {
            SafeERC20.safeTransferFrom(IERC20(asset()), caller, address(this), assets * partialPullBps / 10_000);
            _mint(receiver, shares);
            emit Deposit(caller, receiver, assets, shares);
            return;
        }
        if (mintsNoShares) {
            SafeERC20.safeTransferFrom(IERC20(asset()), caller, address(this), assets);
            emit Deposit(caller, receiver, assets, 0);
            return;
        }
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        if (redeemReverts) revert RedeemDisabled();
        if (redeemPaysNothing) assets = 0;
        else if (redeemLossBps != 0) assets = assets * (10_000 - redeemLossBps) / 10_000;
        super._withdraw(caller, receiver, owner, assets, shares);
    }
}

/// @dev Contract without any ERC-4626 function.
contract NotAVault {
    uint256 public value;
}

/// @dev Vault whose `deposit` can be switched to succeed while returning no data (violates the ERC-4626 ABI).
contract NoReturnDataVault is MockVault {
    bool public returnsNoData;

    constructor(IERC20 asset_) MockVault(asset_) {}

    function setReturnsNoData(bool value) external {
        returnsNoData = value;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        uint256 shares = super.deposit(assets, receiver);
        if (returnsNoData) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return shares;
    }
}
