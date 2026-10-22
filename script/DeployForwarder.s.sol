// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Forwarder} from "../src/Forwarder.sol";
import {ForwarderDeployConfig as Config} from "./ForwarderDeployConfig.sol";

/**
 * @title DeployForwarder
 * @notice Deploys the Forwarder on Base mainnet with the production parameters of `ForwarderDeployConfig` in a
 * single contract creation (all roles are granted by the constructor).
 *
 * The constructor runs the vault health check with 0.001 USDC of the deployer, so the script first sends an
 * `approve(predictedAddress, VAULT_TEST_AMOUNT)` from the deployer and then the creation transaction. The USDC
 * recovered by the health check is returned to the deployer (the Luca vault rounds the round trip down by 1 unit).
 *
 * Dry run (no broadcast):
 *   forge script script/DeployForwarder.s.sol --rpc-url base --sender <DEPLOYER> -vvvv
 * Broadcast and verify:
 *   forge script script/DeployForwarder.s.sol --rpc-url base --account <KEYSTORE> --sender <DEPLOYER> \
 *     --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY -vvvv
 */
contract DeployForwarder is Script {
    function run() external returns (Forwarder) {
        return deploy(msg.sender);
    }

    function deploy(address deployer) public returns (Forwarder forwarder) {
        address[] memory managers = Config.feeManagers(deployer);
        _preflight(deployer, managers);

        uint256 testAmount = 1000; // Forwarder.VAULT_TEST_AMOUNT
        uint256 deployerUsdcBefore = IERC20(Config.USDC).balanceOf(deployer);
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        console.log("Predicted Forwarder  :", predicted);

        vm.startBroadcast(deployer);
        IERC20(Config.USDC).approve(predicted, testAmount);
        forwarder = new Forwarder(
            IERC20(Config.USDC),
            Config.ADMIN,
            Config.ADMIN_DELAY,
            Config.TREASURY,
            IERC4626(Config.VAULT),
            Config.ROUTING_MODE,
            managers
        );
        vm.stopBroadcast();

        require(address(forwarder) == predicted, "deploy: unexpected address");
        require(forwarder.VAULT_TEST_AMOUNT() == testAmount, "deploy: test amount");
        _verify(forwarder, deployer, managers, deployerUsdcBefore);

        console.log("Forwarder deployed   :", address(forwarder));
        console.log("Constructor args     :");
        console.logBytes(
            abi.encode(
                Config.USDC,
                Config.ADMIN,
                Config.ADMIN_DELAY,
                Config.TREASURY,
                Config.VAULT,
                uint8(Config.ROUTING_MODE),
                managers
            )
        );
    }

    function _preflight(address deployer, address[] memory managers) internal view {
        console.log("=== Preflight ===");
        console.log("Chain id             :", block.chainid);
        console.log("Deployer             :", deployer);
        console.log("USDC                 :", Config.USDC);
        console.log("Admin                :", Config.ADMIN);
        console.log("Admin delay (s)      :", uint256(Config.ADMIN_DELAY));
        console.log("Treasury             :", Config.TREASURY);
        console.log("Vault                :", Config.VAULT);
        console.log("Routing mode         :", uint256(Config.ROUTING_MODE));
        console.log("Initial fees         : NONE/NONE, threshold 0, fixed 0, variable 0, not paused");
        for (uint256 i = 0; i < managers.length; ++i) {
            console.log("Fee manager          :", managers[i]);
        }

        require(block.chainid == Config.CHAIN_ID, "preflight: not Base mainnet");
        require(deployer != address(0), "preflight: deployer");
        require(Config.USDC.code.length > 0, "preflight: USDC has no code");
        require(IERC20Metadata(Config.USDC).decimals() == 6, "preflight: USDC decimals");
        require(keccak256(bytes(IERC20Metadata(Config.USDC).symbol())) == keccak256("USDC"), "preflight: USDC symbol");
        require(Config.ADMIN.code.length > 0, "preflight: admin is not a contract");
        require(Config.TREASURY.code.length > 0, "preflight: treasury is not a contract");
        require(Config.VAULT.code.length > 0, "preflight: vault has no code");
        require(IERC4626(Config.VAULT).asset() == Config.USDC, "preflight: vault asset");
        require(deployer != Config.ADMIN, "preflight: deployer must not be the admin");
        for (uint256 i = 0; i < managers.length; ++i) {
            require(managers[i] != address(0), "preflight: zero fee manager");
            for (uint256 j = i + 1; j < managers.length; ++j) {
                require(managers[i] != managers[j], "preflight: duplicated fee manager");
            }
        }
        uint256 deployerUsdc = IERC20(Config.USDC).balanceOf(deployer);
        console.log("Deployer USDC        :", deployerUsdc);
        console.log("Deployer ETH (wei)   :", deployer.balance);
        require(deployerUsdc >= 1000, "preflight: deployer needs 0.001 USDC for the vault health check");
    }

    function _verify(Forwarder forwarder, address deployer, address[] memory managers, uint256 deployerUsdcBefore)
        internal
        view
    {
        require(address(forwarder.USDC()) == Config.USDC, "verify: USDC");
        require(forwarder.defaultAdmin() == Config.ADMIN, "verify: admin");
        require(forwarder.defaultAdminDelay() == Config.ADMIN_DELAY, "verify: admin delay");
        require(forwarder.treasury() == Config.TREASURY, "verify: treasury");
        require(address(forwarder.vault()) == Config.VAULT, "verify: vault");
        require(forwarder.routingMode() == Config.ROUTING_MODE, "verify: routing");
        require(forwarder.lowerFeeModel() == Forwarder.FeeModel.NONE, "verify: lower model");
        require(forwarder.upperFeeModel() == Forwarder.FeeModel.NONE, "verify: upper model");
        require(forwarder.threshold() == 0 && forwarder.fixedFee() == 0, "verify: fee values");
        require(forwarder.variableFee() == 0, "verify: variable fee");
        require(!forwarder.paused(), "verify: paused");
        require(forwarder.calculateFee(1_000_000e6) == 0, "verify: fee not zero");
        bytes32 feeManagerRole = forwarder.FEE_MANAGER_ROLE();
        for (uint256 i = 0; i < managers.length; ++i) {
            require(forwarder.hasRole(feeManagerRole, managers[i]), "verify: fee manager");
        }
        require(!forwarder.hasRole(forwarder.DEFAULT_ADMIN_ROLE(), deployer), "verify: deployer is admin");
        uint256 expectedAllowance = Config.ROUTING_MODE == Forwarder.RoutingMode.DIRECT_DIRECT ? 0 : type(uint256).max;
        require(
            IERC20(Config.USDC).allowance(address(forwarder), Config.VAULT) == expectedAllowance, "verify: allowance"
        );
        require(IERC20(Config.USDC).balanceOf(address(forwarder)) == 0, "verify: forwarder USDC");
        require(IERC4626(Config.VAULT).balanceOf(address(forwarder)) == 0, "verify: forwarder shares");
        require(IERC20(Config.USDC).allowance(deployer, address(forwarder)) == 0, "verify: deployer allowance");
        uint256 deployerUsdcAfter = IERC20(Config.USDC).balanceOf(deployer);
        console.log("Health check cost    :", deployerUsdcBefore - deployerUsdcAfter, "USDC units");
        require(deployerUsdcBefore - deployerUsdcAfter < 1000, "verify: health check refund");
    }
}
