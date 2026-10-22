// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Forwarder} from "../../src/Forwarder.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockVault} from "../mocks/MockVault.sol";

/// @dev Shared fixture for the unit, fuzz and invariant suites (mock USDC + mock ERC-4626 vault).
abstract contract ForwarderTestBase is Test {
    uint48 internal constant ADMIN_DELAY = 3 days;
    uint256 internal constant TEST_AMOUNT = 1000;
    uint256 internal constant VAULT_CHANGE_DELAY = 72 hours;
    uint256 internal constant MAX = type(uint256).max;

    Forwarder.FeeModel internal constant NONE = Forwarder.FeeModel.NONE;
    Forwarder.FeeModel internal constant FIXED = Forwarder.FeeModel.FIXED;
    Forwarder.FeeModel internal constant PERCENT = Forwarder.FeeModel.PERCENT;
    Forwarder.FeeModel internal constant FIXED_PLUS_PERCENT = Forwarder.FeeModel.FIXED_PLUS_PERCENT;

    Forwarder.RoutingMode internal constant DIRECT_DIRECT = Forwarder.RoutingMode.DIRECT_DIRECT;
    Forwarder.RoutingMode internal constant VAULT_USER_DIRECT_TREASURY =
    Forwarder.RoutingMode.VAULT_USER_DIRECT_TREASURY;
    Forwarder.RoutingMode internal constant DIRECT_USER_VAULT_TREASURY =
    Forwarder.RoutingMode.DIRECT_USER_VAULT_TREASURY;
    Forwarder.RoutingMode internal constant VAULT_VAULT = Forwarder.RoutingMode.VAULT_VAULT;

    bytes32 internal constant APPROVAL_TOPIC = keccak256("Approval(address,address,uint256)");

    MockUSDC internal usdc;
    MockVault internal vault;
    Forwarder internal forwarder;

    address internal admin = makeAddr("admin");
    address internal feeManager = makeAddr("feeManager");
    address internal feeManager2 = makeAddr("feeManager2");
    address internal guardian = makeAddr("guardian");
    address internal guardian2 = makeAddr("guardian2");
    address internal stranger = makeAddr("stranger");
    address internal treasury = makeAddr("treasury");
    address internal sra = makeAddr("sra");
    address internal user = makeAddr("user");

    bytes32 internal FEE_MANAGER_ROLE;
    bytes32 internal DEFAULT_ADMIN_ROLE;
    bytes32 internal VAULT_GUARDIAN_ROLE;

    function setUp() public virtual {
        usdc = new MockUSDC();
        vault = new MockVault(IERC20(address(usdc)));
        forwarder = _deploy(IERC4626(address(vault)), DIRECT_DIRECT);
        FEE_MANAGER_ROLE = forwarder.FEE_MANAGER_ROLE();
        DEFAULT_ADMIN_ROLE = forwarder.DEFAULT_ADMIN_ROLE();
        VAULT_GUARDIAN_ROLE = forwarder.VAULT_GUARDIAN_ROLE();
        vm.label(address(forwarder), "Forwarder");
        vm.label(address(usdc), "USDC");
        vm.label(address(vault), "Vault");
    }

    // -----------------------------------------------------------------------------------------------------------
    // Deployment helpers
    // -----------------------------------------------------------------------------------------------------------

    function _feeManagers() internal view returns (address[] memory managers) {
        managers = new address[](2);
        managers[0] = feeManager;
        managers[1] = feeManager2;
    }

    function _guardians() internal view returns (address[] memory guardians) {
        guardians = new address[](2);
        guardians[0] = guardian;
        guardians[1] = guardian2;
    }

    /// @dev Deploys a Forwarder from this test contract, funding and approving the constructor health check.
    function _deploy(IERC4626 vault_, Forwarder.RoutingMode mode) internal returns (Forwarder) {
        if (address(vault_) != address(0)) _fundDeployment();
        return
            new Forwarder(
                IERC20(address(usdc)), admin, ADMIN_DELAY, treasury, vault_, mode, _feeManagers(), _guardians()
            );
    }

    /// @dev Funds this contract and approves the address of its next deployment for the constructor health check.
    /// Under `--isolate` (enabled by `--gas-report`) every top-level call is a transaction that bumps this contract's
    /// nonce, so the approval is repeated for the address that the next CREATE will actually use.
    function _fundDeployment() internal returns (address predicted) {
        usdc.mint(address(this), TEST_AMOUNT);
        uint64 nonce = vm.getNonce(address(this));
        predicted = vm.computeCreateAddress(address(this), nonce);
        usdc.approve(predicted, TEST_AMOUNT);
        uint64 nonceAfter = vm.getNonce(address(this));
        if (nonceAfter != nonce) {
            predicted = vm.computeCreateAddress(address(this), nonceAfter + 1);
            usdc.approve(predicted, TEST_AMOUNT);
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Action helpers
    // -----------------------------------------------------------------------------------------------------------

    function _setRouting(Forwarder.RoutingMode mode) internal {
        vm.prank(admin);
        forwarder.setRoutingMode(mode);
    }

    function _setFees(
        Forwarder.FeeModel lower,
        Forwarder.FeeModel upper,
        uint256 threshold,
        uint256 fixedFee,
        uint256 variableFee
    ) internal {
        vm.prank(feeManager);
        forwarder.setFeeConfig(lower, upper, threshold, fixedFee, variableFee);
    }

    /// @dev Mints `amount` to the SRA, approves the Forwarder and calls `forward` as the SRA.
    function _forward(uint256 amount, address recipient) internal {
        usdc.mint(sra, amount);
        vm.startPrank(sra);
        usdc.approve(address(forwarder), amount);
        forwarder.forward(address(usdc), amount, recipient);
        vm.stopPrank();
    }

    /// @dev Prepares the SRA allowance so that the next call can be wrapped by `vm.expectRevert`/`expectEmit`.
    function _fundSra(uint256 amount) internal {
        usdc.mint(sra, amount);
        vm.prank(sra);
        usdc.approve(address(forwarder), amount);
    }

    /// @dev Calls `proposeVault` as the admin, funding and approving the health check amount.
    function _proposeVault(address candidate) internal {
        _fundAdminForHealthCheck();
        vm.prank(admin);
        forwarder.proposeVault(IERC4626(candidate));
    }

    /// @dev Calls `executeVaultChange` as the admin, funding and approving the health check amount.
    function _executeVaultChange() internal {
        _fundAdminForHealthCheck();
        vm.prank(admin);
        forwarder.executeVaultChange();
    }

    /// @dev Replaces the active vault through the whole lifecycle: propose, wait until `pendingVaultExecutableAt`,
    /// execute.
    function _replaceVault(address newVault) internal {
        _proposeVault(newVault);
        vm.warp(forwarder.pendingVaultExecutableAt());
        _executeVaultChange();
    }

    function _fundAdminForHealthCheck() internal {
        usdc.mint(admin, TEST_AMOUNT);
        vm.prank(admin);
        usdc.approve(address(forwarder), TEST_AMOUNT);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Reference model
    // -----------------------------------------------------------------------------------------------------------

    function _usesVault(Forwarder.RoutingMode mode) internal pure returns (bool) {
        return mode != DIRECT_DIRECT;
    }

    function _userUsesVault(Forwarder.RoutingMode mode) internal pure returns (bool) {
        return mode == VAULT_USER_DIRECT_TREASURY || mode == VAULT_VAULT;
    }

    function _treasuryUsesVault(Forwarder.RoutingMode mode) internal pure returns (bool) {
        return mode == DIRECT_USER_VAULT_TREASURY || mode == VAULT_VAULT;
    }

    /// @dev Specification of the fee: model selected by `amount <= threshold`, applied to the full amount.
    function _referenceFee(
        Forwarder.FeeModel lower,
        Forwarder.FeeModel upper,
        uint256 threshold,
        uint256 fixedFee,
        uint256 variableFee,
        bool paused,
        uint256 amount
    ) internal pure returns (uint256) {
        if (paused) return 0;
        Forwarder.FeeModel model = amount <= threshold ? lower : upper;
        uint256 percent = amount * variableFee / 100_000;
        if (model == NONE) return 0;
        if (model == FIXED) return fixedFee;
        if (model == PERCENT) return percent;
        return fixedFee + percent;
    }

    function _countApprovals(Vm.Log[] memory logs, address token) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == token && logs[i].topics[0] == APPROVAL_TOPIC) ++count;
        }
    }
}
