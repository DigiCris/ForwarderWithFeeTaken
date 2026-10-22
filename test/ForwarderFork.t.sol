// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Forwarder} from "../src/Forwarder.sol";
import {DeployForwarder} from "../script/DeployForwarder.s.sol";
import {ForwarderDeployConfig as Config} from "../script/ForwarderDeployConfig.sol";
import {ForkTestBase} from "./fork/ForkTestBase.sol";

/**
 * @dev Pre-deployment integration suite: deploys the Forwarder with the production deploy script on a Base mainnet
 * fork. Pinned block by default; `FORK_BLOCK=0` runs it against the latest block.
 */
contract ForwarderForkTest is ForkTestBase {
    uint256 internal constant PINNED_BLOCK = 52_951_000; // after the V1 deployment (block 52,925,346)

    uint256 internal deployerUsdcBefore;

    function _forkBlock() internal view override returns (uint256) {
        return vm.envOr("FORK_BLOCK", PINNED_BLOCK);
    }

    function _setUpForwarder() internal override returns (Forwarder) {
        deployerUsdcBefore = USDC.balanceOf(Config.FEE_MANAGER_CM2);
        return new DeployForwarder().deploy(Config.FEE_MANAGER_CM2);
    }

    function test_Fork_DeploymentState() public view {
        assertEq(uint8(forwarder.routingMode()), uint8(Config.ROUTING_MODE));
        assertEq(uint8(forwarder.lowerFeeModel()), uint8(Forwarder.FeeModel.NONE));
        assertEq(uint8(forwarder.upperFeeModel()), uint8(Forwarder.FeeModel.NONE));
        assertEq(forwarder.threshold(), 0);
        assertEq(forwarder.fixedFee(), 0);
        assertEq(forwarder.variableFee(), 0);
        assertFalse(forwarder.paused());
        assertFalse(forwarder.hasRole(forwarder.DEFAULT_ADMIN_ROLE(), Config.FEE_MANAGER_CM2));
        assertEq(address(forwarder.pendingVault()), address(0));
        assertEq(forwarder.pendingVaultExecutableAt(), 0);
        assertEq(_pendingFeeExecutableAt(), 0);
        assertEq(forwarder.pendingTreasury(), address(0));
        assertEq(forwarder.pendingTreasuryExecutableAt(), 0);
        assertEq(forwarder.calculateFeeFor(user, 1_000_000e6), 0);
        assertEq(USDC.allowance(address(forwarder), Config.VAULT), 0);
        assertEq(USDC.allowance(Config.FEE_MANAGER_CM2, address(forwarder)), 0);
        assertEq(USDC.balanceOf(address(forwarder)), 0);
        assertEq(LUCA_VAULT.balanceOf(address(forwarder)), 0);
        // The health check returned the deployer's 0.001 USDC minus the vault rounding (at most a few units).
        uint256 cost = deployerUsdcBefore - USDC.balanceOf(Config.FEE_MANAGER_CM2);
        assertLe(cost, 2);
    }

    function test_Fork_DeployerOutsideTheListIsAddedAsFeeManager() public {
        address otherDeployer = makeAddr("otherDeployer");
        deal(address(USDC), otherDeployer, 1e6);
        Forwarder other = new DeployForwarder().deploy(otherDeployer);
        assertTrue(other.hasRole(other.FEE_MANAGER_ROLE(), otherDeployer));
        assertFalse(other.hasRole(other.DEFAULT_ADMIN_ROLE(), otherDeployer));
        assertEq(Config.feeManagers(otherDeployer).length, 8);
    }

    function test_Fork_RevertWhen_DeployerHasNoUsdc() public {
        DeployForwarder script = new DeployForwarder();
        address poorDeployer = makeAddr("poorDeployer");
        vm.expectRevert(bytes("preflight: deployer needs 0.001 USDC for the vault health check"));
        script.deploy(poorDeployer);
    }

    function test_Fork_SameBytecodeAsLocalArtifact() public {
        // A second deployment with the same arguments has identical runtime code (immutables included).
        address otherDeployer = makeAddr("otherDeployer");
        deal(address(USDC), otherDeployer, 1e6);
        Forwarder other = new DeployForwarder().deploy(otherDeployer);
        assertEq(address(other).codehash, address(forwarder).codehash);
        assertGt(address(forwarder).code.length, 0);
    }
}
