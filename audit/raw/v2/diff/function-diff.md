| Function | V1 lines | V2 lines | Code | NatSpec |
|---|---|---|---|---|
| `constructor` | 21 | 26 | CHANGED | changed |
| `forward` | 30 | 30 | UNCHANGED | unchanged |
| `calculateFee` | 11 | 11 | UNCHANGED | unchanged |
| `setFeeConfig` | 16 | 16 | UNCHANGED | unchanged |
| `setVariableFee` | 5 | 5 | UNCHANGED | unchanged |
| `setFixedFee` | 5 | 5 | UNCHANGED | unchanged |
| `setThreshold` | 4 | 4 | UNCHANGED | unchanged |
| `setLowerFeeModel` | 4 | 4 | UNCHANGED | unchanged |
| `setUpperFeeModel` | 4 | 4 | UNCHANGED | unchanged |
| `pause` | 6 | 6 | UNCHANGED | unchanged |
| `unpause` | 3 | 3 | UNCHANGED | unchanged |
| `setTreasury` | 3 | 3 | UNCHANGED | unchanged |
| `setVault` | 3 | - | REMOVED | - |
| `setRoutingMode` | 3 | 3 | UNCHANGED | unchanged |
| `rescueToken` | 6 | 6 | UNCHANGED | unchanged |
| `rescueNative` | 6 | 6 | UNCHANGED | unchanged |
| `_deliverToTreasury` | 19 | 19 | UNCHANGED | unchanged |
| `_setTreasury` | 5 | 5 | UNCHANGED | unchanged |
| `_setVault` | 15 | 12 | CHANGED | unchanged |
| `_vaultHealthCheck` | 17 | 17 | UNCHANGED | unchanged |
| `_setRoutingMode` | 12 | 12 | UNCHANGED | unchanged |
| `_checkVariableFee` | 3 | 3 | UNCHANGED | unchanged |
| `_checkFixedFee` | 3 | 3 | UNCHANGED | unchanged |
| `_emitFeeConfig` | 3 | 3 | UNCHANGED | unchanged |
| `proposeVault` | - | 13 | ADDED | - |
| `executeVaultChange` | - | 10 | ADDED | - |
| `cancelVaultChange` | - | 11 | ADDED | - |
| `_validateVault` | - | 6 | ADDED | - |

Declarations outside functions (state, constants, events, errors, comments):
- lines only in V1: 2
  - `/// @notice USDC amount (0.001 USDC) used by the vault health check. It is provided by the caller of `setVault``
  - `/// (or by the deployer for the initial vault) and the recovered USDC is returned to that caller.`
- lines only in V2: 22
  + `* - After deployment the vault can only be replaced through `proposeVault` and, once `VAULT_CHANGE_DELAY` has`
  + `*   elapsed, `executeVaultChange`. The default admin and `VAULT_GUARDIAN_ROLE` can cancel a pending change.`
  + `/// @notice Role allowed to cancel a pending vault change. Its admin is DEFAULT_ADMIN_ROLE.`
  + `bytes32 public constant VAULT_GUARDIAN_ROLE = keccak256("VAULT_GUARDIAN_ROLE");`
  + `/// @notice USDC amount (0.001 USDC) used by the vault health check. It is provided by the caller of `proposeVault``
  + `/// and of `executeVaultChange` (or by the deployer for the initial vault) and the recovered USDC is returned to`
  + `/// that caller.`
  + `/// @notice Minimum time between `proposeVault` and `executeVaultChange`. Not configurable.`
  + `uint256 public constant VAULT_CHANGE_DELAY = 72 hours;`
  + `/// @notice Vault proposed by `proposeVault`. Not used by `forward` until `executeVaultChange` activates it. Zero`
  + `/// when no change is pending.`
  + `IERC4626 public pendingVault;`
  + `/// @notice Timestamp from which `executeVaultChange` can activate `pendingVault`. Zero when no change is pending.`
  + `uint256 public pendingVaultExecutableAt;`
  + `/// @notice `pendingVault` can replace `currentVault` from `executableAt` unless the change is cancelled before.`
  + `event VaultChangeProposed(`
  + `address indexed currentVault, address indexed pendingVault, uint256 executableAt, address proposer`
  + `event VaultChangeCancelled(address indexed pendingVault, address indexed cancelledBy);`
  + `error VaultAlreadyActive(address vault);`
  + `error VaultChangeAlreadyPending(address pendingVault);`
  + `error NoPendingVaultChange();`
  + `error VaultChangeDelayNotElapsed(uint256 executableAt);`
