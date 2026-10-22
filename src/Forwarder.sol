// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/**
 * @title Forwarder
 * @notice Last hop of the ZeroDev Smart Routing Address (SRA) deposit flow on Base. `forward` pulls USDC from the
 * caller, charges the Luca fee, delivers the rest to the user (as USDC or as shares of an ERC-4626 vault) and then
 * tries to deliver the whole remaining USDC balance of this contract to the treasury (as USDC or as vault shares).
 *
 * @dev Design rules:
 * - `paused()` means "fees are paused": while paused the fee is zero and `forward` keeps working as a pure router.
 *   `forward` is never paused.
 * - If the user vault deposit fails, the user receives USDC directly instead.
 * - Treasury delivery is best effort: if it fails the USDC stays in this contract and the next `forward` retries
 *   with the whole accumulated balance. It never reverts a user delivery.
 * - The vault is a trusted dependency set by the default admin. While the routing mode uses it, the vault holds an
 *   unlimited USDC allowance from this contract.
 * - After deployment the vault can only be replaced through `proposeVault` and, once `VAULT_CHANGE_DELAY` has
 *   elapsed, `executeVaultChange`. The default admin and `VAULT_GUARDIAN_ROLE` can cancel a pending change.
 * - The contract is not upgradeable.
 */
contract Forwarder is AccessControlDefaultAdminRules, Pausable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Fee formula applied to the full deposited amount.
    enum FeeModel {
        NONE,
        FIXED,
        PERCENT,
        FIXED_PLUS_PERCENT
    }

    /// @notice Destination of the user amount and of the treasury balance (USDC transfer or vault deposit).
    enum RoutingMode {
        DIRECT_DIRECT,
        VAULT_USER_DIRECT_TREASURY,
        DIRECT_USER_VAULT_TREASURY,
        VAULT_VAULT
    }

    /// @notice Role allowed to change the fee configuration and to pause fees.
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    /// @notice Role allowed to cancel a pending vault change. Its admin is DEFAULT_ADMIN_ROLE.
    bytes32 public constant VAULT_GUARDIAN_ROLE = keccak256("VAULT_GUARDIAN_ROLE");

    /// @notice Denominator of `variableFee`: 1 = 0.001%, 1_000 = 1%, 10_000 = 10%.
    uint256 public constant FEE_DENOMINATOR = 100_000;

    /// @notice Maximum `variableFee` (10%).
    uint256 public constant MAX_VARIABLE_FEE = 10_000;

    /// @notice Maximum `fixedFee` (10 USDC, 6 decimals).
    uint256 public constant MAX_FIXED_FEE = 10_000_000;

    /// @notice USDC amount (0.001 USDC) used by the vault health check. It is provided by the caller of `proposeVault`
    /// and of `executeVaultChange` (or by the deployer for the initial vault) and the recovered USDC is returned to
    /// that caller.
    uint256 public constant VAULT_TEST_AMOUNT = 1000;

    /// @notice Minimum time between `proposeVault` and `executeVaultChange`. Not configurable.
    uint256 public constant VAULT_CHANGE_DELAY = 72 hours;

    /// @notice The only token accepted by `forward`.
    IERC20 public immutable USDC;

    /// @notice Receiver of fees and of any other USDC left in this contract.
    address public treasury;

    /// @notice ERC-4626 vault (asset = USDC) used by the routing modes that deposit. Zero until configured.
    IERC4626 public vault;

    /// @notice Current routing of the user amount and of the treasury balance.
    RoutingMode public routingMode;

    /// @notice Fee model applied when `amount <= threshold`.
    FeeModel public lowerFeeModel;

    /// @notice Fee model applied when `amount > threshold`.
    FeeModel public upperFeeModel;

    /// @notice Amount (inclusive) up to which `lowerFeeModel` applies.
    uint256 public threshold;

    /// @notice Fixed fee in USDC units (6 decimals), at most `MAX_FIXED_FEE`.
    uint256 public fixedFee;

    /// @notice Variable fee over `FEE_DENOMINATOR`, at most `MAX_VARIABLE_FEE`.
    uint256 public variableFee;

    /// @notice Vault proposed by `proposeVault`. Not used by `forward` until `executeVaultChange` activates it. Zero
    /// when no change is pending.
    IERC4626 public pendingVault;

    /// @notice Timestamp from which `executeVaultChange` can activate `pendingVault`. Zero when no change is pending.
    uint256 public pendingVaultExecutableAt;

    /// @notice Emitted once the user leg of `forward` is complete.
    /// @param userVaultDeposit True if the user received vault shares, false if the user received USDC.
    /// @param userShares Shares minted to the user (zero when `userVaultDeposit` is false).
    event Forwarded(
        address indexed caller,
        address indexed recipient,
        uint256 amount,
        uint256 fee,
        uint256 userAmount,
        bool userVaultDeposit,
        uint256 userShares
    );

    /// @notice The user vault deposit failed and `assets` USDC were transferred to `recipient` instead.
    event UserVaultDepositFailed(address indexed recipient, address indexed vault, uint256 assets, bytes reason);

    /// @notice `assets` USDC were transferred to the treasury.
    event TreasuryTransferred(address indexed treasury, uint256 assets);

    /// @notice The USDC transfer to the treasury failed; `assets` USDC remain in this contract.
    event TreasuryTransferFailed(address indexed treasury, uint256 assets);

    /// @notice `assets` USDC were deposited in the vault on behalf of the treasury.
    event TreasuryVaultDeposited(address indexed treasury, address indexed vault, uint256 assets, uint256 shares);

    /// @notice The treasury vault deposit failed; `assets` USDC remain in this contract.
    event TreasuryVaultDepositFailed(address indexed treasury, address indexed vault, uint256 assets, bytes reason);

    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);

    /// @param healthCheckShares Shares minted by the health-check deposit of `VAULT_TEST_AMOUNT`.
    /// @param healthCheckAssets USDC returned by redeeming those shares.
    event VaultUpdated(
        address indexed previousVault, address indexed newVault, uint256 healthCheckShares, uint256 healthCheckAssets
    );

    /// @notice `pendingVault` can replace `currentVault` from `executableAt` unless the change is cancelled before.
    event VaultChangeProposed(
        address indexed currentVault, address indexed pendingVault, uint256 executableAt, address proposer
    );

    event VaultChangeCancelled(address indexed pendingVault, address indexed cancelledBy);

    event RoutingModeUpdated(RoutingMode previousMode, RoutingMode newMode);

    /// @notice Full fee configuration after any change.
    event FeeConfigUpdated(
        FeeModel lowerFeeModel, FeeModel upperFeeModel, uint256 threshold, uint256 fixedFee, uint256 variableFee
    );

    event TokenRescued(address indexed token, address indexed treasury, uint256 amount);

    event NativeRescued(address indexed treasury, uint256 amount);

    error ZeroAddress();
    error UnsupportedToken(address token);
    error InvalidRecipient(address recipient);
    error InvalidTreasury(address treasury);
    error VariableFeeTooHigh(uint256 variableFee);
    error FixedFeeTooHigh(uint256 fixedFee);
    error VaultNotContract(address vault);
    error VaultAssetMismatch(address vault, address asset);
    error VaultNoSharesMinted(address vault);
    error VaultNoAssetsReturned(address vault);
    error VaultNotSet();
    error VaultAlreadyActive(address vault);
    error VaultChangeAlreadyPending(address pendingVault);
    error NoPendingVaultChange();
    error VaultChangeDelayNotElapsed(uint256 executableAt);

    /**
     * @param usdc USDC token. Immutable.
     * @param initialAdmin Holder of `DEFAULT_ADMIN_ROLE` (production multisig).
     * @param initialAdminDelay Delay of `AccessControlDefaultAdminRules` for default admin transfers.
     * @param initialTreasury Fee receiver.
     * @param initialVault Optional vault (zero for none). A non-zero vault is activated without delay after the same
     * health check as `proposeVault`, funded by the deployer: the deployer must approve `VAULT_TEST_AMOUNT` USDC to
     * the address of this contract before deploying it.
     * @param initialRoutingMode Initial routing. Modes that use the vault require `initialVault`.
     * @param initialFeeManagers Accounts granted `FEE_MANAGER_ROLE`.
     * @param initialVaultGuardians Accounts granted `VAULT_GUARDIAN_ROLE`.
     * @dev Fees start disabled: both fee models are NONE and every fee parameter is zero.
     */
    constructor(
        IERC20 usdc,
        address initialAdmin,
        uint48 initialAdminDelay,
        address initialTreasury,
        IERC4626 initialVault,
        RoutingMode initialRoutingMode,
        address[] memory initialFeeManagers,
        address[] memory initialVaultGuardians
    ) AccessControlDefaultAdminRules(initialAdminDelay, initialAdmin) {
        if (address(usdc) == address(0)) revert ZeroAddress();
        USDC = usdc;

        _setTreasury(initialTreasury);
        if (address(initialVault) != address(0)) _setVault(initialVault);
        _setRoutingMode(initialRoutingMode);

        for (uint256 i = 0; i < initialFeeManagers.length; ++i) {
            if (initialFeeManagers[i] == address(0)) revert ZeroAddress();
            _grantRole(FEE_MANAGER_ROLE, initialFeeManagers[i]);
        }
        for (uint256 i = 0; i < initialVaultGuardians.length; ++i) {
            if (initialVaultGuardians[i] == address(0)) revert ZeroAddress();
            _grantRole(VAULT_GUARDIAN_ROLE, initialVaultGuardians[i]);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Forwarding
    // ---------------------------------------------------------------------------------------------------------------

    /**
     * @notice Pulls `amount` USDC from the caller (allowance required), charges the fee, delivers `amount - fee` to
     * `recipient` and then tries to deliver the whole remaining USDC balance of this contract to the treasury.
     * @dev Reverts if `token` is not USDC, if `recipient` is invalid, if the fee is larger than `amount` (checked
     * arithmetic), if the USDC pull fails or if the direct USDC delivery to the user fails. A failed user vault
     * deposit falls back to a direct USDC transfer. A failed treasury delivery never reverts.
     * @param token Must be USDC. Kept in the signature for compatibility with the SRA call.
     * @param amount USDC amount pulled from the caller.
     * @param recipient Receiver of the user amount (USDC or vault shares).
     */
    function forward(address token, uint256 amount, address recipient) external nonReentrant {
        if (token != address(USDC)) revert UnsupportedToken(token);
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient(recipient);

        uint256 fee = calculateFee(amount);
        uint256 userAmount = amount - fee;

        USDC.safeTransferFrom(msg.sender, address(this), amount);

        RoutingMode mode = routingMode;
        IERC4626 currentVault = vault;
        address currentTreasury = treasury;

        bool userVaultDeposit;
        uint256 userShares;
        if (mode == RoutingMode.VAULT_USER_DIRECT_TREASURY || mode == RoutingMode.VAULT_VAULT) {
            try currentVault.deposit(userAmount, recipient) returns (uint256 shares) {
                userVaultDeposit = true;
                userShares = shares;
            } catch (bytes memory reason) {
                emit UserVaultDepositFailed(recipient, address(currentVault), userAmount, reason);
            }
        }
        if (!userVaultDeposit) {
            USDC.safeTransfer(recipient, userAmount);
        }
        emit Forwarded(msg.sender, recipient, amount, fee, userAmount, userVaultDeposit, userShares);

        _deliverToTreasury(mode, currentVault, currentTreasury);
    }

    /**
     * @notice Fee charged by `forward` for `amount`. Zero while fees are paused.
     * @dev `lowerFeeModel` applies when `amount <= threshold`, `upperFeeModel` otherwise. The selected model is
     * applied to the full `amount`. The percentage part rounds down.
     */
    function calculateFee(uint256 amount) public view returns (uint256) {
        if (paused()) return 0;

        FeeModel model = amount <= threshold ? lowerFeeModel : upperFeeModel;
        if (model == FeeModel.NONE) return 0;
        if (model == FeeModel.FIXED) return fixedFee;

        uint256 percentFee = amount * variableFee / FEE_DENOMINATOR;
        if (model == FeeModel.PERCENT) return percentFee;
        return fixedFee + percentFee;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Fee configuration (FEE_MANAGER_ROLE)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Sets the whole fee configuration atomically.
    function setFeeConfig(
        FeeModel newLowerFeeModel,
        FeeModel newUpperFeeModel,
        uint256 newThreshold,
        uint256 newFixedFee,
        uint256 newVariableFee
    ) external onlyRole(FEE_MANAGER_ROLE) {
        _checkFixedFee(newFixedFee);
        _checkVariableFee(newVariableFee);
        lowerFeeModel = newLowerFeeModel;
        upperFeeModel = newUpperFeeModel;
        threshold = newThreshold;
        fixedFee = newFixedFee;
        variableFee = newVariableFee;
        _emitFeeConfig();
    }

    /// @notice Sets `variableFee` (over `FEE_DENOMINATOR`, at most `MAX_VARIABLE_FEE`).
    function setVariableFee(uint256 newVariableFee) external onlyRole(FEE_MANAGER_ROLE) {
        _checkVariableFee(newVariableFee);
        variableFee = newVariableFee;
        _emitFeeConfig();
    }

    /// @notice Sets `fixedFee` (USDC units, at most `MAX_FIXED_FEE`).
    function setFixedFee(uint256 newFixedFee) external onlyRole(FEE_MANAGER_ROLE) {
        _checkFixedFee(newFixedFee);
        fixedFee = newFixedFee;
        _emitFeeConfig();
    }

    /// @notice Sets `threshold` (USDC units).
    function setThreshold(uint256 newThreshold) external onlyRole(FEE_MANAGER_ROLE) {
        threshold = newThreshold;
        _emitFeeConfig();
    }

    /// @notice Sets the fee model used when `amount <= threshold`.
    function setLowerFeeModel(FeeModel newLowerFeeModel) external onlyRole(FEE_MANAGER_ROLE) {
        lowerFeeModel = newLowerFeeModel;
        _emitFeeConfig();
    }

    /// @notice Sets the fee model used when `amount > threshold`.
    function setUpperFeeModel(FeeModel newUpperFeeModel) external onlyRole(FEE_MANAGER_ROLE) {
        upperFeeModel = newUpperFeeModel;
        _emitFeeConfig();
    }

    /// @notice Pauses fees (fee = 0). Callable by `FEE_MANAGER_ROLE` or `DEFAULT_ADMIN_ROLE`. Does not stop `forward`.
    function pause() external {
        if (!hasRole(FEE_MANAGER_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, FEE_MANAGER_ROLE);
        }
        _pause();
    }

    /// @notice Unpauses fees. Only `DEFAULT_ADMIN_ROLE`.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Administration (DEFAULT_ADMIN_ROLE)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Sets the treasury. USDC pending in this contract is delivered to the new treasury by the next `forward`.
    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setTreasury(newTreasury);
    }

    /**
     * @notice Proposes `candidate` as the next vault after a real deposit/redeem health check of `VAULT_TEST_AMOUNT`
     * USDC pulled from the caller (allowance required). The USDC recovered by the health check is returned to the
     * caller. The change can be executed from `block.timestamp + VAULT_CHANGE_DELAY`. Only one change can be pending:
     * the pending one must be cancelled before proposing another.
     * @dev Does not modify the active vault, its allowance nor the routing mode. The candidate is left with zero
     * allowance. Any failure reverts the whole call.
     */
    function proposeVault(IERC4626 candidate) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (address(pendingVault) != address(0)) revert VaultChangeAlreadyPending(address(pendingVault));
        _validateVault(candidate);
        if (address(candidate) == address(vault)) revert VaultAlreadyActive(address(candidate));

        uint256 executableAt = block.timestamp + VAULT_CHANGE_DELAY;
        pendingVault = candidate;
        pendingVaultExecutableAt = executableAt;
        emit VaultChangeProposed(address(vault), address(candidate), executableAt, msg.sender);

        _vaultHealthCheck(candidate);
        USDC.forceApprove(address(candidate), 0);
    }

    /**
     * @notice Activates the pending vault once `pendingVaultExecutableAt` is reached, after repeating the health check
     * with `VAULT_TEST_AMOUNT` USDC pulled from the caller (allowance required).
     * @dev The previous vault allowance is set to zero. The new vault gets an unlimited allowance if the routing mode
     * at execution time uses the vault, zero otherwise. Any failure reverts the whole call and keeps the pending
     * change, which can be executed again or cancelled.
     */
    function executeVaultChange() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        IERC4626 candidate = pendingVault;
        if (address(candidate) == address(0)) revert NoPendingVaultChange();
        uint256 executableAt = pendingVaultExecutableAt;
        if (block.timestamp < executableAt) revert VaultChangeDelayNotElapsed(executableAt);

        delete pendingVault;
        delete pendingVaultExecutableAt;
        _setVault(candidate);
    }

    /// @notice Cancels the pending vault change at any time before it is executed. Callable by `VAULT_GUARDIAN_ROLE`
    /// or `DEFAULT_ADMIN_ROLE`.
    function cancelVaultChange() external {
        if (!hasRole(VAULT_GUARDIAN_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, VAULT_GUARDIAN_ROLE);
        }
        IERC4626 cancelledVault = pendingVault;
        if (address(cancelledVault) == address(0)) revert NoPendingVaultChange();

        delete pendingVault;
        delete pendingVaultExecutableAt;
        emit VaultChangeCancelled(address(cancelledVault), msg.sender);
    }

    /// @notice Sets the routing mode and updates the vault allowance when the vault usage changes.
    function setRoutingMode(RoutingMode newRoutingMode) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        _setRoutingMode(newRoutingMode);
    }

    /// @notice Sends the whole balance of `token` held by this contract to the treasury.
    function rescueToken(IERC20 token) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        address currentTreasury = treasury;
        uint256 amount = token.balanceOf(address(this));
        token.safeTransfer(currentTreasury, amount);
        emit TokenRescued(address(token), currentTreasury, amount);
    }

    /// @notice Sends the whole native balance of this contract to the treasury.
    function rescueNative() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        address currentTreasury = treasury;
        uint256 amount = address(this).balance;
        Address.sendValue(payable(currentTreasury), amount);
        emit NativeRescued(currentTreasury, amount);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------------------------

    /**
     * @dev Best-effort delivery of the whole USDC balance to the treasury. Never reverts because of the delivery.
     * The vault deposit uses a low-level call instead of try/catch because try/catch does not catch the decoding of
     * malformed return data; a deposit that does not return a full word is reported as failed. Nothing is accounted
     * here: the next call measures the balance again, so a misreported result cannot double count funds.
     */
    function _deliverToTreasury(RoutingMode mode, IERC4626 currentVault, address currentTreasury) private {
        uint256 balance = USDC.balanceOf(address(this));
        if (balance == 0) return;

        if (mode == RoutingMode.DIRECT_USER_VAULT_TREASURY || mode == RoutingMode.VAULT_VAULT) {
            (bool success, bytes memory returnData) =
                address(currentVault).call(abi.encodeCall(IERC4626.deposit, (balance, currentTreasury)));
            if (success && returnData.length >= 32) {
                uint256 shares = abi.decode(returnData, (uint256));
                emit TreasuryVaultDeposited(currentTreasury, address(currentVault), balance, shares);
            } else {
                emit TreasuryVaultDepositFailed(currentTreasury, address(currentVault), balance, returnData);
            }
        } else if (USDC.trySafeTransfer(currentTreasury, balance)) {
            emit TreasuryTransferred(currentTreasury, balance);
        } else {
            emit TreasuryTransferFailed(currentTreasury, balance);
        }
    }

    function _setTreasury(address newTreasury) private {
        if (newTreasury == address(0) || newTreasury == address(this)) revert InvalidTreasury(newTreasury);
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    function _setVault(IERC4626 newVault) private {
        _validateVault(newVault);

        IERC4626 previousVault = vault;
        if (address(previousVault) != address(0)) USDC.forceApprove(address(previousVault), 0);

        (uint256 shares, uint256 assets) = _vaultHealthCheck(newVault);

        vault = newVault;
        USDC.forceApprove(address(newVault), routingMode == RoutingMode.DIRECT_DIRECT ? 0 : type(uint256).max);
        emit VaultUpdated(address(previousVault), address(newVault), shares, assets);
    }

    function _validateVault(IERC4626 newVault) private view {
        if (address(newVault) == address(0)) revert ZeroAddress();
        if (address(newVault).code.length == 0) revert VaultNotContract(address(newVault));
        address asset = newVault.asset();
        if (asset != address(USDC)) revert VaultAssetMismatch(address(newVault), asset);
    }

    /**
     * @dev Deposits `VAULT_TEST_AMOUNT` USDC pulled from `msg.sender`, redeems every share received and returns to
     * `msg.sender` all the USDC obtained by the round trip. Measures balances instead of trusting return values.
     * Requires shares > 0 and recovered assets > 0; a recovered amount below `VAULT_TEST_AMOUNT` (rounding) is
     * accepted. USDC already held by this contract is never used.
     */
    function _vaultHealthCheck(IERC4626 candidate) private returns (uint256 shares, uint256 assets) {
        uint256 usdcBefore = USDC.balanceOf(address(this));
        USDC.safeTransferFrom(msg.sender, address(this), VAULT_TEST_AMOUNT);
        USDC.forceApprove(address(candidate), VAULT_TEST_AMOUNT);

        uint256 sharesBefore = candidate.balanceOf(address(this));
        candidate.deposit(VAULT_TEST_AMOUNT, address(this));
        shares = candidate.balanceOf(address(this)) - sharesBefore;
        if (shares == 0) revert VaultNoSharesMinted(address(candidate));

        uint256 usdcBeforeRedeem = USDC.balanceOf(address(this));
        candidate.redeem(shares, address(this), address(this));
        assets = USDC.balanceOf(address(this)) - usdcBeforeRedeem;
        if (assets == 0) revert VaultNoAssetsReturned(address(candidate));

        USDC.safeTransfer(msg.sender, USDC.balanceOf(address(this)) - usdcBefore);
    }

    function _setRoutingMode(RoutingMode newRoutingMode) private {
        RoutingMode previousRoutingMode = routingMode;
        bool usedVault = previousRoutingMode != RoutingMode.DIRECT_DIRECT;
        bool usesVault = newRoutingMode != RoutingMode.DIRECT_DIRECT;
        if (usesVault && address(vault) == address(0)) revert VaultNotSet();

        routingMode = newRoutingMode;
        if (usesVault != usedVault) {
            USDC.forceApprove(address(vault), usesVault ? type(uint256).max : 0);
        }
        emit RoutingModeUpdated(previousRoutingMode, newRoutingMode);
    }

    function _checkVariableFee(uint256 newVariableFee) private pure {
        if (newVariableFee > MAX_VARIABLE_FEE) revert VariableFeeTooHigh(newVariableFee);
    }

    function _checkFixedFee(uint256 newFixedFee) private pure {
        if (newFixedFee > MAX_FIXED_FEE) revert FixedFeeTooHigh(newFixedFee);
    }

    function _emitFeeConfig() private {
        emit FeeConfigUpdated(lowerFeeModel, upperFeeModel, threshold, fixedFee, variableFee);
    }
}
