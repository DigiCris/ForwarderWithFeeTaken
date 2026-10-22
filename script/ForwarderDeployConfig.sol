// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Forwarder} from "../src/Forwarder.sol";

/// @notice Base mainnet production parameters of the Forwarder. Shared by the deploy script and the fork tests.
library ForwarderDeployConfig {
    uint256 internal constant CHAIN_ID = 8453;

    /// @dev Native USDC issued by Circle on Base (developers.circle.com/stablecoins/usdc-contract-addresses).
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @dev DEFAULT_ADMIN_ROLE holder (Safe). `.env` DEFAULT_ADMIN_ROLE.
    address internal constant ADMIN = 0x420675DFAf02750a7DdFad702D13e32eb2C67602;

    /// @dev AccessControlDefaultAdminRules delay. Same 3 days used by the team's RainExecutor contract.
    uint48 internal constant ADMIN_DELAY = 3 days;

    /// @dev Luca fee account (Safe). `.env` TREASURY_ADDRESS.
    address internal constant TREASURY = 0x7a5F8A4aF0FEDaBb1625b6f04bA38fC75e7E843e;

    /// @dev Luca Money Vault (ERC-4626, asset USDC). `.env` LUCAVAULT_ADDRESS.
    address internal constant VAULT = 0xc462cA16286a9a877a499f9474827bA801f2090D;

    /// @dev Initial routing. Users and treasury receive USDC until the admin switches to a vault mode.
    Forwarder.RoutingMode internal constant ROUTING_MODE = Forwarder.RoutingMode.DIRECT_DIRECT;

    // FEE_MANAGER_ROLE holders granted at deployment.
    address internal constant FEE_MANAGER_MANAGEMENT_1 = 0xa737cB590c0F4d00D2140a429728681e1e74C5db; // .env MANAGEMENT_ROLE_1
    address internal constant FEE_MANAGER_MM = 0x31B5aBcF044049daa96cDC387a44747a48a0ac62;
    address internal constant FEE_MANAGER_OC = 0x61D4d1Ab7eA7B3A54C7B2D646Eb8189faD7B1050;
    address internal constant FEE_MANAGER_CM = 0xa82a5201E630b40914bf4fed0B0b40180BCB93F7;
    address internal constant FEE_MANAGER_BB = 0xe3685F1C0652430e501B314b3035CB7Dd5b21c5f;
    address internal constant FEE_MANAGER_HM = 0x5aDF0B683B49217704eff3f85eda468651C50A48;
    address internal constant FEE_MANAGER_CM2 = 0x18e129122a338f2e6871764fe0e4426dE848Ef99; // expected deployer

    /// @notice The seven fee managers above plus `deployer` when it is not one of them.
    function feeManagers(address deployer) internal pure returns (address[] memory managers) {
        address[7] memory fixedManagers = [
            FEE_MANAGER_MANAGEMENT_1,
            FEE_MANAGER_MM,
            FEE_MANAGER_OC,
            FEE_MANAGER_CM,
            FEE_MANAGER_BB,
            FEE_MANAGER_HM,
            FEE_MANAGER_CM2
        ];
        bool deployerIncluded;
        for (uint256 i = 0; i < fixedManagers.length; ++i) {
            if (fixedManagers[i] == deployer) deployerIncluded = true;
        }
        managers = new address[](deployerIncluded ? 7 : 8);
        for (uint256 i = 0; i < fixedManagers.length; ++i) {
            managers[i] = fixedManagers[i];
        }
        if (!deployerIncluded) managers[7] = deployer;
    }
}
