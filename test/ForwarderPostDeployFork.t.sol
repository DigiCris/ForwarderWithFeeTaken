// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Forwarder} from "../src/Forwarder.sol";
import {ForwarderDeployConfig as Config} from "../script/ForwarderDeployConfig.sol";
import {ForkTestBase} from "./fork/ForkTestBase.sol";

/**
 * @dev Post-deployment suite: runs every fork test against the Forwarder actually deployed on Base mainnet.
 * Requires `DEPLOYED_FORWARDER`; `POST_DEPLOY_FORK_BLOCK` (default: latest) must be after the deployment block.
 * Skipped when `DEPLOYED_FORWARDER` is not set.
 */
contract ForwarderPostDeployForkTest is ForkTestBase {
    function setUp() public override {
        if (vm.envOr("DEPLOYED_FORWARDER", address(0)) == address(0)) {
            vm.skip(true);
            return;
        }
        super.setUp();
    }

    function _forkBlock() internal view override returns (uint256) {
        return vm.envOr("POST_DEPLOY_FORK_BLOCK", uint256(0));
    }

    function _setUpForwarder() internal view override returns (Forwarder) {
        return Forwarder(vm.envAddress("DEPLOYED_FORWARDER"));
    }

    /// @dev The deployed runtime code is byte-identical to the audited source compiled locally with the same
    /// constructor arguments (the only immutable is USDC).
    function test_PostDeploy_RuntimeCodeMatchesAuditedSource() public {
        address[] memory managers = Config.feeManagers(Config.FEE_MANAGER_CM2);
        deal(address(USDC), address(this), 1e6);
        USDC.approve(vm.computeCreateAddress(address(this), vm.getNonce(address(this))), 1000);
        Forwarder local = new Forwarder(
            IERC20(Config.USDC),
            Config.ADMIN,
            Config.ADMIN_DELAY,
            Config.TREASURY,
            IERC4626(Config.VAULT),
            Config.ROUTING_MODE,
            managers,
            Config.vaultGuardians()
        );
        assertEq(address(local).code, address(forwarder).code);
        assertEq(address(local).codehash, address(forwarder).codehash);
    }

    function test_PostDeploy_InitialConfiguration() public view {
        assertEq(uint8(forwarder.routingMode()), uint8(Config.ROUTING_MODE));
        assertEq(uint8(forwarder.lowerFeeModel()), uint8(Forwarder.FeeModel.NONE));
        assertEq(uint8(forwarder.upperFeeModel()), uint8(Forwarder.FeeModel.NONE));
        assertEq(forwarder.threshold(), 0);
        assertEq(forwarder.fixedFee(), 0);
        assertEq(forwarder.variableFee(), 0);
        assertFalse(forwarder.paused());
        (address pendingAdmin, uint48 schedule) = forwarder.pendingDefaultAdmin();
        assertEq(pendingAdmin, address(0));
        assertEq(schedule, 0);
        assertEq(address(forwarder.pendingVault()), address(0));
        assertEq(forwarder.pendingVaultExecutableAt(), 0);
        assertEq(forwarder.VAULT_CHANGE_DELAY(), 72 hours);
        assertEq(
            USDC.allowance(address(forwarder), Config.VAULT),
            Config.ROUTING_MODE == Forwarder.RoutingMode.DIRECT_DIRECT ? 0 : type(uint256).max
        );
    }
}
