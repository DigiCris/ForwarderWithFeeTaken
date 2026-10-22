| Function | V2 lines | V3 lines | Code | NatSpec |
|---|---|---|---|---|
| `constructor` | 26 | 26 | UNCHANGED | unchanged |
| `forward` | 30 | 30 | CHANGED | unchanged |
| `calculateFee` | 11 | 11 | UNCHANGED | changed |
| `setFeeConfig` -> `_setFeeConfig` | 16 | 16 | RENAMED, IDENTICAL BODY | changed |
| `setVariableFee` | 5 | - | REMOVED | - |
| `setFixedFee` | 5 | - | REMOVED | - |
| `setThreshold` | 4 | - | REMOVED | - |
| `setLowerFeeModel` | 4 | - | REMOVED | - |
| `setUpperFeeModel` | 4 | - | REMOVED | - |
| `pause` | 6 | 6 | UNCHANGED | unchanged |
| `unpause` | 3 | 3 | UNCHANGED | unchanged |
| `setTreasury` | 3 | - | REMOVED | - |
| `proposeVault` | 13 | 13 | UNCHANGED | unchanged |
| `executeVaultChange` | 10 | 10 | UNCHANGED | unchanged |
| `cancelVaultChange` | 11 | 11 | UNCHANGED | unchanged |
| `setRoutingMode` | 3 | 3 | UNCHANGED | unchanged |
| `rescueToken` | 6 | 6 | UNCHANGED | unchanged |
| `rescueNative` | 6 | 6 | UNCHANGED | unchanged |
| `_deliverToTreasury` | 19 | 19 | UNCHANGED | unchanged |
| `_setTreasury` | 5 | 5 | UNCHANGED | unchanged |
| `_setVault` | 12 | 12 | UNCHANGED | unchanged |
| `_validateVault` | 6 | 6 | UNCHANGED | unchanged |
| `_vaultHealthCheck` | 17 | 17 | UNCHANGED | unchanged |
| `_setRoutingMode` | 12 | 12 | UNCHANGED | unchanged |
| `_checkVariableFee` | 3 | 3 | UNCHANGED | unchanged |
| `_checkFixedFee` | 3 | 3 | UNCHANGED | unchanged |
| `_emitFeeConfig` | 3 | 3 | UNCHANGED | unchanged |
| `calculateFeeFor` | - | 14 | ADDED | - |
| `proposeFeeConfig` | - | 25 | ADDED | - |
| `executeFeeConfigChange` | - | 8 | ADDED | - |
| `cancelFeeConfigChange` | - | 12 | ADDED | - |
| `setUserFeeOverride` | - | 26 | ADDED | - |
| `proposeTreasury` | - | 9 | ADDED | - |
| `executeTreasuryChange` | - | 10 | ADDED | - |
| `cancelTreasuryChange` | - | 11 | ADDED | - |


`setFeeConfig` (V2) signature:
```solidity
    function setFeeConfig(
        FeeModel newLowerFeeModel,
        FeeModel newUpperFeeModel,
        uint256 newThreshold,
        uint256 newFixedFee,
        uint256 newVariableFee
    ) external onlyRole(FEE_MANAGER_ROLE)
```
`_setFeeConfig` (V3) signature:
```solidity
    function _setFeeConfig(
        FeeModel newLowerFeeModel,
        FeeModel newUpperFeeModel,
        uint256 newThreshold,
        uint256 newFixedFee,
        uint256 newVariableFee
    ) private
```

Declarations outside functions (state, constants, events, errors, comments):
- lines only in V2: 2
  - `/// @notice Role allowed to change the fee configuration and to pause fees.`
  - `/// @notice Role allowed to cancel a pending vault change. Its admin is DEFAULT_ADMIN_ROLE.`
- lines only in V3: 67
  + `import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";`
  + `* - Likewise the fee configuration only changes through `proposeFeeConfig` and, after `FEE_CHANGE_DELAY`,`
  + `*   `executeFeeConfigChange`; the treasury only through `proposeTreasury` and, after `TREASURY_CHANGE_DELAY`,`
  + `*   `executeTreasuryChange`. The default admin and `VAULT_GUARDIAN_ROLE` can cancel both; fee managers can also`
  + `*   cancel a fee configuration change. Pausing fees stays immediate.`
  + `* - A fee manager can give a recipient a temporary fee override that can only lower its fixed and variable fee. The`
  + `*   global models and threshold always apply (see `calculateFeeFor`).`
  + `/// @notice Fee configuration proposed by `proposeFeeConfig`.`
  + `struct PendingFeeConfig {`
  + `FeeModel lowerFeeModel;`
  + `FeeModel upperFeeModel;`
  + `uint256 threshold;`
  + `uint256 fixedFee;`
  + `uint256 variableFee;`
  + `uint256 executableAt;`
  + `/// @notice Fee override of one recipient, active while `block.timestamp < validUntil`.`
  + `struct UserFeeOverride {`
  + `uint256 fixedFee;`
  + `uint256 variableFee;`
  + `uint256 validUntil;`
  + `/// @notice Role allowed to propose, execute and cancel fee configuration changes, to set fee overrides and to`
  + `/// pause fees.`
  + `/// @notice Role allowed to cancel pending vault, fee configuration and treasury changes, and nothing else. The name`
  + `/// is kept from V2. Its admin is DEFAULT_ADMIN_ROLE.`
  + `/// @notice Minimum time between `proposeFeeConfig` and `executeFeeConfigChange`. Not configurable.`
  + `uint256 public constant FEE_CHANGE_DELAY = 72 hours;`
  + `/// @notice Minimum time between `proposeTreasury` and `executeTreasuryChange`. Not configurable.`
  + `uint256 public constant TREASURY_CHANGE_DELAY = 72 hours;`
  + `/// @notice Fee configuration proposed by `proposeFeeConfig`. Not used by `forward` until `executeFeeConfigChange``
  + `/// applies it. `executableAt` is zero when no change is pending.`
  + `PendingFeeConfig public pendingFeeConfig;`
  + `/// @notice Treasury proposed by `proposeTreasury`. Not used until `executeTreasuryChange` activates it. Zero when`
  + `/// no change is pending.`
  + `address public pendingTreasury;`
  + `/// @notice Timestamp from which `executeTreasuryChange` can activate `pendingTreasury`. Zero when no change is`
  + `/// pending.`
  + `uint256 public pendingTreasuryExecutableAt;`
  + `/// @notice Fee overrides by recipient (see `setUserFeeOverride`). Expired entries are kept and ignored.`
  + `mapping(address recipient => UserFeeOverride) public userFeeOverrides;`
  + `/// @notice `pendingTreasury` can replace `currentTreasury` from `executableAt` unless the change is cancelled before.`
  + `event TreasuryChangeProposed(`
  + `address indexed currentTreasury, address indexed pendingTreasury, uint256 executableAt, address proposer`
  + `event TreasuryChangeCancelled(address indexed pendingTreasury, address indexed cancelledBy);`
  + `/// @notice This fee configuration can replace the active one from `executableAt` unless the change is cancelled`
  + `/// before.`
  + `event FeeConfigChangeProposed(`
  + `FeeModel lowerFeeModel,`
  + `FeeModel upperFeeModel,`
  + `uint256 threshold,`
  + `uint256 fixedFee,`
  + `uint256 variableFee,`
  + `uint256 executableAt,`
  + `address proposer`
  + `event FeeConfigChangeCancelled(address indexed cancelledBy);`
  + `/// @notice Until `validUntil` (exclusive) `recipient` pays at most `fixedFee` and `variableFee` as fixed and`
  + `/// variable fee.`
  + `event UserFeeOverrideSet(`
  + `address indexed recipient, uint256 fixedFee, uint256 variableFee, uint256 validUntil, address setBy`
  + `error FeeConfigChangeAlreadyPending(uint256 executableAt);`
  + `error NoPendingFeeConfigChange();`
  + `error FeeConfigChangeDelayNotElapsed(uint256 executableAt);`
  + `error TreasuryChangeAlreadyPending(address pendingTreasury);`
  + `error NoPendingTreasuryChange();`
  + `error TreasuryChangeDelayNotElapsed(uint256 executableAt);`
  + `error FeeOverrideExpiryNotInFuture(uint256 validUntil);`
  + `error FeeOverrideAboveGlobalFee(uint256 fixedFee, uint256 variableFee);`
  + `error ActiveFeeOverrideWorsened(address recipient);`
