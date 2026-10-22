// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Forwarder} from "../../src/Forwarder.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockVault} from "../mocks/MockVault.sol";

/**
 * @dev Stateful handler: random sequences of forwards, fee configuration, pause/unpause, routing changes, vault and
 * treasury replacements, failure injection, donations, rescues and unauthorized attempts. It never reverts; every
 * unexpected outcome increments a ghost counter that the invariants require to stay at zero.
 *
 * All vaults are 1:1 (1 USDC unit = 1e12 shares) because nothing donates to them, so share values are exact.
 */
contract ForwarderHandler is Test {
    uint256 internal constant SHARE_SCALE = 1e12;
    uint256 internal constant TEST_AMOUNT = 1000;
    uint256 internal constant MAX = type(uint256).max;

    Forwarder public immutable forwarder;
    MockUSDC public immutable usdc;
    address public immutable admin;

    MockVault[] public vaults; // vaults[0] is the initial vault; the last one always fails its health check
    address[] public feeManagers;
    address[] public strangers;
    address[] public treasuries;
    address[] public recipients;
    address public sra = makeAddr("handler-sra");

    // Accounting ghosts (USDC units).
    uint256 public ghostDeposited;
    uint256 public ghostDonated;
    uint256 public ghostFees;
    uint256 public ghostUserReceived;
    uint256 public ghostTreasuryReceived;

    // Violation ghosts: must remain zero.
    uint256 public ghostUnexpectedReverts;
    uint256 public ghostUnexpectedSuccesses;
    uint256 public ghostUserMismatches;
    uint256 public ghostTreasuryMismatches;
    uint256 public ghostRescueMisroutes;
    uint256 public ghostPausedFeeCharged;

    // Expected USDC allowance from the Forwarder to each vault.
    mapping(address vault => uint256) public ghostAllowance;

    mapping(bytes32 => uint256) public calls;

    constructor(
        Forwarder forwarder_,
        MockUSDC usdc_,
        address admin_,
        MockVault[] memory vaults_,
        address[] memory feeManagers_,
        address[] memory treasuries_
    ) {
        forwarder = forwarder_;
        usdc = usdc_;
        admin = admin_;
        vaults = vaults_;
        feeManagers = feeManagers_;
        treasuries = treasuries_;
        for (uint256 i = 0; i < 3; ++i) {
            strangers.push(makeAddr(string.concat("stranger", vm.toString(i))));
            recipients.push(makeAddr(string.concat("recipient", vm.toString(i))));
        }
        ghostAllowance[address(forwarder.vault())] = usdc.allowance(address(forwarder), address(forwarder.vault()));
    }

    // -----------------------------------------------------------------------------------------------------------
    // Views used by the invariants
    // -----------------------------------------------------------------------------------------------------------

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    function strangerCount() external view returns (uint256) {
        return strangers.length;
    }

    /// @dev USDC value held by all treasuries (USDC + vault shares).
    function treasuryValue() public view returns (uint256 value) {
        for (uint256 t = 0; t < treasuries.length; ++t) {
            value += usdc.balanceOf(treasuries[t]);
            for (uint256 v = 0; v < vaults.length; ++v) {
                value += vaults[v].balanceOf(treasuries[t]) / SHARE_SCALE;
            }
        }
    }

    function _accountValue(address account) internal view returns (uint256 value) {
        value = usdc.balanceOf(account);
        for (uint256 v = 0; v < vaults.length; ++v) {
            value += vaults[v].balanceOf(account) / SHARE_SCALE;
        }
    }

    function _usesVault(Forwarder.RoutingMode mode) internal pure returns (bool) {
        return mode != Forwarder.RoutingMode.DIRECT_DIRECT;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Actions
    // -----------------------------------------------------------------------------------------------------------

    function forward(uint256 amount, uint256 recipientSeed) external {
        calls["forward"]++;
        amount = bound(amount, 0, 1e13);
        address recipient = recipients[recipientSeed % recipients.length];
        IERC4626 currentVault = forwarder.vault();
        bool paused = forwarder.paused();
        uint256 fee = forwarder.calculateFee(amount);
        if (paused && fee != 0) ghostPausedFeeCharged++;

        usdc.mint(sra, amount);
        vm.prank(sra);
        usdc.approve(address(forwarder), amount);

        uint256 recipientBefore = _accountValue(recipient);
        uint256 treasuryBefore = treasuryValue();
        uint256 forwarderBefore = usdc.balanceOf(address(forwarder));
        uint256 vaultUsdcBefore = usdc.balanceOf(address(currentVault));

        vm.prank(sra);
        try forwarder.forward(address(usdc), amount, recipient) {
            if (fee > amount) {
                ghostUnexpectedSuccesses++;
                return;
            }
        } catch {
            if (fee <= amount) ghostUnexpectedReverts++;
            // Funds never left the caller; burn them from the accounting by leaving them with the SRA.
            return;
        }

        uint256 userAmount = amount - fee;
        ghostDeposited += amount;
        ghostFees += fee;

        uint256 received = _accountValue(recipient) - recipientBefore;
        ghostUserReceived += received;
        if (received != userAmount) ghostUserMismatches++;

        uint256 treasuryDelta = treasuryValue() - treasuryBefore;
        ghostTreasuryReceived += treasuryDelta;
        if (treasuryDelta + usdc.balanceOf(address(forwarder)) != forwarderBefore + fee) ghostTreasuryMismatches++;

        if (_usesVault(forwarder.routingMode())) {
            ghostAllowance[address(currentVault)] -= usdc.balanceOf(address(currentVault)) - vaultUsdcBefore;
        }
    }

    function donate(uint256 amount) external {
        calls["donate"]++;
        amount = bound(amount, 1, 1e12);
        usdc.mint(address(forwarder), amount);
        ghostDonated += amount;
    }

    function setFeeConfig(
        uint256 managerSeed,
        uint8 lower,
        uint8 upper,
        uint256 threshold,
        uint256 fixedFee,
        uint256 variableFee
    ) external {
        calls["setFeeConfig"]++;
        address manager = feeManagers[managerSeed % feeManagers.length];
        fixedFee = bound(fixedFee, 0, 12e6);
        variableFee = bound(variableFee, 0, 12_000);
        threshold = bound(threshold, 0, 1e13);
        bool valid = fixedFee <= 10e6 && variableFee <= 10_000;
        vm.prank(manager);
        try forwarder.setFeeConfig(
            Forwarder.FeeModel(lower % 4), Forwarder.FeeModel(upper % 4), threshold, fixedFee, variableFee
        ) {
            if (!valid) ghostUnexpectedSuccesses++;
        } catch {
            if (valid) ghostUnexpectedReverts++;
        }
    }

    function setSingleFeeParameter(uint256 managerSeed, uint8 which, uint256 value) external {
        calls["setSingleFeeParameter"]++;
        address manager = feeManagers[managerSeed % feeManagers.length];
        which = which % 5;
        bool valid = true;
        bytes memory data;
        if (which == 0) {
            value = bound(value, 0, 12_000);
            valid = value <= 10_000;
            data = abi.encodeCall(Forwarder.setVariableFee, (value));
        } else if (which == 1) {
            value = bound(value, 0, 12e6);
            valid = value <= 10e6;
            data = abi.encodeCall(Forwarder.setFixedFee, (value));
        } else if (which == 2) {
            data = abi.encodeCall(Forwarder.setThreshold, (bound(value, 0, 1e13)));
        } else if (which == 3) {
            data = abi.encodeCall(Forwarder.setLowerFeeModel, (Forwarder.FeeModel(value % 4)));
        } else {
            data = abi.encodeCall(Forwarder.setUpperFeeModel, (Forwarder.FeeModel(value % 4)));
        }
        vm.prank(manager);
        (bool success,) = address(forwarder).call(data);
        if (success && !valid) ghostUnexpectedSuccesses++;
        if (!success && valid) ghostUnexpectedReverts++;
    }

    function pause(bool asAdmin, uint256 managerSeed) external {
        calls["pause"]++;
        address caller = asAdmin ? admin : feeManagers[managerSeed % feeManagers.length];
        bool wasPaused = forwarder.paused();
        vm.prank(caller);
        try forwarder.pause() {
            if (wasPaused) ghostUnexpectedSuccesses++;
        } catch {
            if (!wasPaused) ghostUnexpectedReverts++;
        }
    }

    function unpause() external {
        calls["unpause"]++;
        bool wasPaused = forwarder.paused();
        vm.prank(admin);
        try forwarder.unpause() {
            if (!wasPaused) ghostUnexpectedSuccesses++;
        } catch {
            if (wasPaused) ghostUnexpectedReverts++;
        }
    }

    function setRoutingMode(uint8 modeSeed) external {
        calls["setRoutingMode"]++;
        Forwarder.RoutingMode previous = forwarder.routingMode();
        Forwarder.RoutingMode mode = Forwarder.RoutingMode(modeSeed % 4);
        address currentVault = address(forwarder.vault());
        vm.prank(admin);
        try forwarder.setRoutingMode(mode) {
            if (_usesVault(previous) != _usesVault(mode)) ghostAllowance[currentVault] = _usesVault(mode) ? MAX : 0;
        } catch {
            ghostUnexpectedReverts++;
        }
    }

    function setVault(uint256 vaultSeed) external {
        calls["setVault"]++;
        MockVault candidate = vaults[vaultSeed % vaults.length];
        bool healthy = candidate != vaults[vaults.length - 1] && !candidate.depositReverts() && !candidate.paused();
        address previous = address(forwarder.vault());

        usdc.mint(admin, TEST_AMOUNT);
        vm.prank(admin);
        usdc.approve(address(forwarder), TEST_AMOUNT);
        uint256 adminBefore = usdc.balanceOf(admin);
        uint256 forwarderBefore = usdc.balanceOf(address(forwarder));

        vm.prank(admin);
        try forwarder.setVault(IERC4626(address(candidate))) {
            if (!healthy) ghostUnexpectedSuccesses++;
            ghostAllowance[previous] = 0;
            ghostAllowance[address(candidate)] = _usesVault(forwarder.routingMode()) ? MAX : 0;
            // 1:1 vault: the caller gets back exactly what it provided; the Forwarder balance is untouched.
            if (usdc.balanceOf(admin) != adminBefore) ghostTreasuryMismatches++;
        } catch {
            if (healthy) ghostUnexpectedReverts++;
        }
        if (usdc.balanceOf(address(forwarder)) != forwarderBefore) ghostTreasuryMismatches++;
        // Leave no allowance behind for the next round.
        vm.prank(admin);
        usdc.approve(address(forwarder), 0);
    }

    function setTreasury(uint256 treasurySeed) external {
        calls["setTreasury"]++;
        vm.prank(admin);
        try forwarder.setTreasury(treasuries[treasurySeed % treasuries.length]) {}
        catch {
            ghostUnexpectedReverts++;
        }
    }

    /// @dev Failure injection on the vaults and on USDC transfers to treasuries.
    function toggleFailure(uint8 kind, uint256 seed, bool on) external {
        calls["toggleFailure"]++;
        kind = kind % 5;
        MockVault v = vaults[seed % (vaults.length - 1)];
        address t = treasuries[seed % treasuries.length];
        if (kind == 0) v.setDepositReverts(on);
        else if (kind == 1) v.setPaused(on);
        else if (kind == 2) v.setBlockedReceiver(on ? t : address(0));
        else if (kind == 3) usdc.setBlacklisted(t, on);
        else usdc.setReturnFalseOnTransferTo(t, on);
    }

    function rescueUsdc() external {
        calls["rescueUsdc"]++;
        address currentTreasury = forwarder.treasury();
        uint256 amount = usdc.balanceOf(address(forwarder));
        uint256 treasuryBefore = usdc.balanceOf(currentTreasury);
        vm.prank(admin);
        try forwarder.rescueToken(IERC20(address(usdc))) {
            if (usdc.balanceOf(currentTreasury) - treasuryBefore != amount) ghostRescueMisroutes++;
            if (usdc.balanceOf(address(forwarder)) != 0) ghostRescueMisroutes++;
            ghostTreasuryReceived += amount;
        } catch {
            // Only acceptable reason: the treasury cannot receive USDC (blacklisted / returns false).
            if (!usdc.isBlacklisted(currentTreasury) && !usdc.returnFalseOnTransferTo(currentTreasury)) {
                ghostUnexpectedReverts++;
            }
        }
    }

    function rescueNative(uint256 amount) external {
        calls["rescueNative"]++;
        amount = bound(amount, 0, 100 ether);
        vm.deal(address(forwarder), address(forwarder).balance + amount);
        address currentTreasury = forwarder.treasury();
        uint256 total = address(forwarder).balance;
        uint256 before = currentTreasury.balance;
        vm.prank(admin);
        try forwarder.rescueNative() {
            if (currentTreasury.balance - before != total || address(forwarder).balance != 0) ghostRescueMisroutes++;
        } catch {
            ghostUnexpectedReverts++;
        }
    }

    /// @dev Strangers and fee managers try privileged functions they must not be able to call.
    function unauthorizedCall(uint256 actorSeed, uint8 selectorSeed, uint256 value) external {
        calls["unauthorizedCall"]++;
        bool asFeeManager = actorSeed % 2 == 0;
        address actor =
            asFeeManager ? feeManagers[actorSeed % feeManagers.length] : strangers[actorSeed % strangers.length];
        bytes memory data;
        uint8 s = selectorSeed % (asFeeManager ? 8 : 15);
        if (s == 0) {
            data = abi.encodeCall(Forwarder.setTreasury, (actor));
        } else if (s == 1) {
            data = abi.encodeCall(Forwarder.setVault, (IERC4626(address(vaults[0]))));
        } else if (s == 2) {
            data = abi.encodeCall(Forwarder.setRoutingMode, (Forwarder.RoutingMode(value % 4)));
        } else if (s == 3) {
            data = abi.encodeCall(Forwarder.rescueToken, (IERC20(address(usdc))));
        } else if (s == 4) {
            data = abi.encodeCall(Forwarder.rescueNative, ());
        } else if (s == 5) {
            data = abi.encodeCall(Forwarder.unpause, ());
        } else if (s == 6) {
            data = abi.encodeCall(IAccessControl.grantRole, (forwarder.FEE_MANAGER_ROLE(), actor));
        } else if (s == 7) {
            data = abi.encodeCall(IAccessControl.grantRole, (forwarder.DEFAULT_ADMIN_ROLE(), actor));
        } else if (s == 8) {
            data = abi.encodeCall(Forwarder.pause, ());
        } else if (s == 9) {
            data = abi.encodeCall(
                Forwarder.setFeeConfig, (Forwarder.FeeModel.FIXED, Forwarder.FeeModel.FIXED, value, 1, 1)
            );
        } else if (s == 10) {
            data = abi.encodeCall(Forwarder.setVariableFee, (value % 10_000));
        } else if (s == 11) {
            data = abi.encodeCall(Forwarder.setFixedFee, (value % 10e6));
        } else if (s == 12) {
            data = abi.encodeCall(Forwarder.setThreshold, (value));
        } else if (s == 13) {
            data = abi.encodeCall(Forwarder.setLowerFeeModel, (Forwarder.FeeModel(value % 4)));
        } else {
            data = abi.encodeCall(Forwarder.setUpperFeeModel, (Forwarder.FeeModel(value % 4)));
        }
        vm.prank(actor);
        (bool success,) = address(forwarder).call(data);
        if (success) ghostUnexpectedSuccesses++;
    }
}
