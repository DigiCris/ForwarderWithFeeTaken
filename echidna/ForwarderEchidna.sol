// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Forwarder} from "../src/Forwarder.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {MockVault} from "../test/mocks/MockVault.sol";

interface IHevm {
    function warp(uint256 newTimestamp) external;
}

/// @dev Account controlled by the harness; `msg.sender` of every call it relays.
contract Actor {
    address internal immutable owner;

    constructor() {
        owner = msg.sender;
    }

    function exec(address target, bytes calldata data) external returns (bool success, bytes memory result) {
        require(msg.sender == owner, "actor: only harness");
        (success, result) = target.call(data);
    }
}

/**
 * @title ForwarderEchidna
 * @notice Property-based campaign. Echidna calls the public functions below in random sequences; every action
 * checks its own post-conditions and counts violations, and the `echidna_*` properties must always hold.
 * Vaults are 1:1 (nothing donates to them), so share values are exact.
 */
contract ForwarderEchidna {
    uint256 internal constant SHARE_SCALE = 1e12;
    uint256 internal constant TEST_AMOUNT = 1000;
    uint256 internal constant MAX = type(uint256).max;
    IHevm internal constant HEVM = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    MockUSDC internal usdc;
    Forwarder internal forwarder;
    MockVault[3] internal vaults; // vaults[2] always fails its health check
    Actor internal admin;
    Actor[2] internal feeManagers;
    Actor internal stranger;
    Actor internal sra;
    address[3] internal treasuries;
    address[3] internal recipients;

    bytes32 internal feeManagerRole;
    bytes32 internal adminRole;

    // Accounting ghosts.
    uint256 internal deposited;
    uint256 internal donated;
    uint256 internal fees;
    uint256 internal userReceived;
    uint256 internal treasuryReceived;
    mapping(address => uint256) internal expectedAllowance;

    // Violation counters.
    uint256 internal unexpectedReverts;
    uint256 internal unexpectedSuccesses;
    uint256 internal userMismatches;
    uint256 internal treasuryMismatches;
    uint256 internal rescueMisroutes;
    uint256 internal pausedFeeCharged;

    constructor() {
        usdc = new MockUSDC();
        for (uint256 i = 0; i < 3; ++i) {
            vaults[i] = new MockVault(IERC20(address(usdc)));
            treasuries[i] = address(uint160(0x7000 + i));
            recipients[i] = address(uint160(0xA000 + i));
        }
        vaults[2].setRedeemReverts(true);
        admin = new Actor();
        feeManagers[0] = new Actor();
        feeManagers[1] = new Actor();
        stranger = new Actor();
        sra = new Actor();

        address[] memory managers = new address[](2);
        managers[0] = address(feeManagers[0]);
        managers[1] = address(feeManagers[1]);
        forwarder = new Forwarder(
            IERC20(address(usdc)),
            address(admin),
            3 days,
            treasuries[0],
            IERC4626(address(0)),
            Forwarder.RoutingMode.DIRECT_DIRECT,
            managers,
            new address[](0)
        );
        feeManagerRole = forwarder.FEE_MANAGER_ROLE();
        adminRole = forwarder.DEFAULT_ADMIN_ROLE();
        _adminSetVault(vaults[0]);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------

    function _call(Actor actor, bytes memory data) internal returns (bool success) {
        (success,) = actor.exec(address(forwarder), data);
    }

    function _usesVault(Forwarder.RoutingMode mode) internal pure returns (bool) {
        return mode != Forwarder.RoutingMode.DIRECT_DIRECT;
    }

    function _value(address account) internal view returns (uint256 value) {
        value = usdc.balanceOf(account);
        for (uint256 v = 0; v < 3; ++v) {
            value += vaults[v].balanceOf(account) / SHARE_SCALE;
        }
    }

    function _treasuryValue() internal view returns (uint256 value) {
        for (uint256 t = 0; t < 3; ++t) {
            value += _value(treasuries[t]);
        }
    }

    /// @dev Vault replacement through the whole lifecycle in one step: propose, wait the delay, execute. The targeted
    /// lifecycle campaign is echidna/ForwarderVaultChangeEchidna.sol.
    function _adminSetVault(MockVault candidate) internal returns (bool success) {
        usdc.mint(address(admin), 2 * TEST_AMOUNT);
        admin.exec(address(usdc), abi.encodeCall(IERC20.approve, (address(forwarder), 2 * TEST_AMOUNT)));
        address previous = address(forwarder.vault());
        uint256 adminBefore = usdc.balanceOf(address(admin));
        uint256 forwarderBefore = usdc.balanceOf(address(forwarder));
        success = _call(admin, abi.encodeCall(Forwarder.proposeVault, (IERC4626(address(candidate)))));
        if (success) {
            HEVM.warp(forwarder.pendingVaultExecutableAt());
            success = _call(admin, abi.encodeCall(Forwarder.executeVaultChange, ()));
            if (!success) unexpectedReverts++;
        }
        if (success) {
            if (previous != address(0)) expectedAllowance[previous] = 0;
            expectedAllowance[address(candidate)] = _usesVault(forwarder.routingMode()) ? MAX : 0;
            if (usdc.balanceOf(address(admin)) != adminBefore) treasuryMismatches++;
        }
        if (usdc.balanceOf(address(forwarder)) != forwarderBefore) treasuryMismatches++;
        admin.exec(address(usdc), abi.encodeCall(IERC20.approve, (address(forwarder), 0)));
    }

    // -----------------------------------------------------------------------------------------------------------
    // Actions
    // -----------------------------------------------------------------------------------------------------------

    function forward(uint256 amount, uint8 recipientSeed) public {
        amount = amount % 1e13;
        address recipient = recipients[recipientSeed % 3];
        IERC4626 currentVault = forwarder.vault();
        uint256 fee = forwarder.calculateFeeFor(recipient, amount);
        if (forwarder.paused() && fee != 0) pausedFeeCharged++;

        usdc.mint(address(sra), amount);
        sra.exec(address(usdc), abi.encodeCall(IERC20.approve, (address(forwarder), amount)));
        uint256 recipientBefore = _value(recipient);
        uint256 treasuryBefore = _treasuryValue();
        uint256 forwarderBefore = usdc.balanceOf(address(forwarder));
        uint256 vaultUsdcBefore = usdc.balanceOf(address(currentVault));

        bool success = _call(sra, abi.encodeCall(Forwarder.forward, (address(usdc), amount, recipient)));
        if (!success) {
            if (fee <= amount) unexpectedReverts++;
            return;
        }
        if (fee > amount) {
            unexpectedSuccesses++;
            return;
        }
        deposited += amount;
        fees += fee;
        uint256 received = _value(recipient) - recipientBefore;
        userReceived += received;
        if (received != amount - fee) userMismatches++;
        uint256 treasuryDelta = _treasuryValue() - treasuryBefore;
        treasuryReceived += treasuryDelta;
        if (treasuryDelta + usdc.balanceOf(address(forwarder)) != forwarderBefore + fee) treasuryMismatches++;
        // A successful treasury delivery always takes the whole balance (fee + anything pending), never part of it.
        if (treasuryDelta != 0 && usdc.balanceOf(address(forwarder)) != 0) treasuryMismatches++;
        if (_usesVault(forwarder.routingMode())) {
            expectedAllowance[address(currentVault)] -= usdc.balanceOf(address(currentVault)) - vaultUsdcBefore;
        }
    }

    function donate(uint256 amount) public {
        amount = 1 + amount % 1e12;
        usdc.mint(address(forwarder), amount);
        donated += amount;
    }

    /// @dev Fee configuration change through the whole delayed lifecycle in one step: propose, wait the delay,
    /// execute. The targeted lifecycle campaign is echidna/ForwarderV3Echidna.sol.
    function _changeFees(
        Actor manager,
        Forwarder.FeeModel lower,
        Forwarder.FeeModel upper,
        uint256 threshold,
        uint256 fixedFee,
        uint256 variableFee
    ) internal {
        bool valid = fixedFee <= 10e6 && variableFee <= 10_000;
        bool success = _call(
            manager, abi.encodeCall(Forwarder.proposeFeeConfig, (lower, upper, threshold, fixedFee, variableFee))
        );
        if (success && !valid) unexpectedSuccesses++;
        if (!success && valid) unexpectedReverts++;
        if (!success) return;
        (,,,,, uint256 executableAt) = forwarder.pendingFeeConfig();
        HEVM.warp(executableAt);
        if (!_call(manager, abi.encodeCall(Forwarder.executeFeeConfigChange, ()))) unexpectedReverts++;
    }

    function setFeeConfig(
        uint8 manager,
        uint8 lower,
        uint8 upper,
        uint256 threshold,
        uint256 fixedFee,
        uint256 variableFee
    ) public {
        _changeFees(
            feeManagers[manager % 2],
            Forwarder.FeeModel(lower % 4),
            Forwarder.FeeModel(upper % 4),
            threshold % 1e13,
            fixedFee % 12e6,
            variableFee % 12_000
        );
    }

    /// @dev Changes only the variable fee (the rest of the active configuration is kept).
    function setVariableFee(uint8 manager, uint256 value) public {
        _changeFees(
            feeManagers[manager % 2],
            forwarder.lowerFeeModel(),
            forwarder.upperFeeModel(),
            forwarder.threshold(),
            forwarder.fixedFee(),
            value % 12_000
        );
    }

    /// @dev Changes only the fixed fee (the rest of the active configuration is kept).
    function setFixedFee(uint8 manager, uint256 value) public {
        _changeFees(
            feeManagers[manager % 2],
            forwarder.lowerFeeModel(),
            forwarder.upperFeeModel(),
            forwarder.threshold(),
            value % 12e6,
            forwarder.variableFee()
        );
    }

    function pause(bool asAdmin, uint8 manager) public {
        bool wasPaused = forwarder.paused();
        bool success = _call(asAdmin ? admin : feeManagers[manager % 2], abi.encodeCall(Forwarder.pause, ()));
        if (success == wasPaused) success ? unexpectedSuccesses++ : unexpectedReverts++;
    }

    function unpause() public {
        bool wasPaused = forwarder.paused();
        bool success = _call(admin, abi.encodeCall(Forwarder.unpause, ()));
        if (success != wasPaused) success ? unexpectedSuccesses++ : unexpectedReverts++;
    }

    function setRoutingMode(uint8 modeSeed) public {
        Forwarder.RoutingMode previous = forwarder.routingMode();
        Forwarder.RoutingMode mode = Forwarder.RoutingMode(modeSeed % 4);
        address currentVault = address(forwarder.vault());
        bool success = _call(admin, abi.encodeCall(Forwarder.setRoutingMode, (mode)));
        if (!success) {
            unexpectedReverts++;
            return;
        }
        if (_usesVault(previous) != _usesVault(mode)) expectedAllowance[currentVault] = _usesVault(mode) ? MAX : 0;
    }

    function setVault(uint8 seed) public {
        MockVault candidate = vaults[seed % 3];
        bool healthy = seed % 3 != 2 && !candidate.depositReverts() && !candidate.paused()
            && address(candidate) != address(forwarder.vault());
        bool success = _adminSetVault(candidate);
        if (success != healthy) success ? unexpectedSuccesses++ : unexpectedReverts++;
    }

    /// @dev Treasury change through the whole delayed lifecycle in one step: propose, wait the delay, execute.
    function setTreasury(uint8 seed) public {
        if (!_call(admin, abi.encodeCall(Forwarder.proposeTreasury, (treasuries[seed % 3])))) {
            unexpectedReverts++;
            return;
        }
        HEVM.warp(forwarder.pendingTreasuryExecutableAt());
        if (!_call(admin, abi.encodeCall(Forwarder.executeTreasuryChange, ()))) unexpectedReverts++;
    }

    function toggleFailure(uint8 kind, uint8 seed, bool on) public {
        MockVault v = vaults[seed % 2];
        address t = treasuries[seed % 3];
        kind = kind % 5;
        if (kind == 0) v.setDepositReverts(on);
        else if (kind == 1) v.setPaused(on);
        else if (kind == 2) v.setBlockedReceiver(on ? t : address(0));
        else if (kind == 3) usdc.setBlacklisted(t, on);
        else usdc.setReturnFalseOnTransferTo(t, on);
    }

    function rescueUsdc() public {
        address currentTreasury = forwarder.treasury();
        uint256 amount = usdc.balanceOf(address(forwarder));
        uint256 before = usdc.balanceOf(currentTreasury);
        if (_call(admin, abi.encodeCall(Forwarder.rescueToken, (IERC20(address(usdc)))))) {
            if (usdc.balanceOf(currentTreasury) - before != amount) rescueMisroutes++;
            if (usdc.balanceOf(address(forwarder)) != 0) rescueMisroutes++;
            treasuryReceived += amount;
        } else if (!usdc.isBlacklisted(currentTreasury) && !usdc.returnFalseOnTransferTo(currentTreasury)) {
            unexpectedReverts++;
        }
    }

    function unauthorizedCall(bool asFeeManager, uint8 selectorSeed, uint256 value) public {
        Actor actor = asFeeManager ? feeManagers[value % 2] : stranger;
        uint8 s = selectorSeed % (asFeeManager ? 8 : 14);
        bytes memory data;
        if (s == 0) {
            data = abi.encodeCall(Forwarder.proposeTreasury, (address(actor)));
        } else if (s == 1) {
            data = abi.encodeCall(Forwarder.proposeVault, (IERC4626(address(vaults[1]))));
        } else if (s == 2) {
            data = abi.encodeCall(Forwarder.setRoutingMode, (Forwarder.RoutingMode(value % 4)));
        } else if (s == 3) {
            data = abi.encodeCall(Forwarder.rescueToken, (IERC20(address(usdc))));
        } else if (s == 4) {
            data = abi.encodeCall(Forwarder.rescueNative, ());
        } else if (s == 5) {
            data = abi.encodeCall(Forwarder.unpause, ());
        } else if (s == 6) {
            data = abi.encodeCall(IAccessControl.grantRole, (feeManagerRole, address(actor)));
        } else if (s == 7) {
            data = abi.encodeCall(IAccessControl.grantRole, (adminRole, address(actor)));
        } else if (s == 8) {
            data = abi.encodeCall(Forwarder.pause, ());
        } else if (s == 9) {
            data = abi.encodeCall(
                Forwarder.proposeFeeConfig, (Forwarder.FeeModel.FIXED, Forwarder.FeeModel.FIXED, value, 1, 1)
            );
        } else if (s == 10) {
            data = abi.encodeCall(Forwarder.executeFeeConfigChange, ());
        } else if (s == 11) {
            data = abi.encodeCall(Forwarder.cancelFeeConfigChange, ());
        } else if (s == 12) {
            data = abi.encodeCall(Forwarder.setUserFeeOverride, (address(actor), 0, 0, block.timestamp + 1));
        } else {
            data = abi.encodeCall(Forwarder.executeTreasuryChange, ());
        }
        if (_call(actor, data)) unexpectedSuccesses++;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Properties
    // -----------------------------------------------------------------------------------------------------------

    function echidna_no_unexpected_outcome() public view returns (bool) {
        return unexpectedReverts == 0 && unexpectedSuccesses == 0 && rescueMisroutes == 0;
    }

    function echidna_user_gets_amount_minus_fee() public view returns (bool) {
        return userMismatches == 0;
    }

    function echidna_treasury_accounting() public view returns (bool) {
        return treasuryMismatches == 0;
    }

    function echidna_conservation() public view returns (bool) {
        return deposited + donated == userReceived + treasuryReceived + usdc.balanceOf(address(forwarder))
            && deposited == userReceived + fees;
    }

    function echidna_fee_caps() public view returns (bool) {
        return forwarder.variableFee() <= 10_000 && forwarder.fixedFee() <= 10e6;
    }

    function echidna_paused_means_zero_fee() public view returns (bool) {
        if (pausedFeeCharged != 0) return false;
        if (!forwarder.paused()) return true;
        return forwarder.calculateFee(0) == 0 && forwarder.calculateFee(1e13) == 0
            && forwarder.calculateFee(forwarder.threshold()) == 0 && forwarder.calculateFeeFor(recipients[0], 1e13) == 0;
    }

    function echidna_vault_mode_has_vault() public view returns (bool) {
        return !_usesVault(forwarder.routingMode()) || address(forwarder.vault()) != address(0);
    }

    function echidna_allowances() public view returns (bool) {
        address current = address(forwarder.vault());
        bool direct = !_usesVault(forwarder.routingMode());
        for (uint256 i = 0; i < 3; ++i) {
            address v = address(vaults[i]);
            uint256 allowance = usdc.allowance(address(forwarder), v);
            if (allowance != expectedAllowance[v]) return false;
            if ((v != current || direct) && allowance != 0) return false;
        }
        return true;
    }

    function echidna_roles_never_change() public view returns (bool) {
        (address pending,) = forwarder.pendingDefaultAdmin();
        return forwarder.defaultAdmin() == address(admin) && pending == address(0)
            && forwarder.hasRole(feeManagerRole, address(feeManagers[0]))
            && forwarder.hasRole(feeManagerRole, address(feeManagers[1]))
            && !forwarder.hasRole(adminRole, address(feeManagers[0]))
            && !forwarder.hasRole(adminRole, address(feeManagers[1]))
            && !forwarder.hasRole(adminRole, address(stranger)) && !forwarder.hasRole(feeManagerRole, address(stranger))
            && !forwarder.hasRole(feeManagerRole, address(sra));
    }

    function echidna_forwarder_holds_no_shares() public view returns (bool) {
        for (uint256 i = 0; i < 3; ++i) {
            if (vaults[i].balanceOf(address(forwarder)) != 0) return false;
        }
        return true;
    }

    function echidna_treasury_valid() public view returns (bool) {
        address t = forwarder.treasury();
        return t != address(0) && t != address(forwarder);
    }
}
