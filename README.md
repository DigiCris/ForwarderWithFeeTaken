# ForwarderWithFeeTaken

`Forwarder` is the last hop of the ZeroDev Smart Routing Address (SRA) deposit flow on Base. The SRA approves USDC
to the Forwarder and calls `forward(token, amount, recipient)`; the Forwarder:

1. pulls `amount` USDC from the caller;
2. computes the Luca fee of `recipient` (`calculateFeeFor`: the global fee, or a lower temporary override of that
   recipient; zero while fees are paused);
3. delivers `amount - fee` to `recipient`, as USDC or as shares of an ERC-4626 vault (falling back to USDC if the
   vault deposit fails);
4. tries to deliver its **whole** remaining USDC balance (fee + anything left from previous calls or donations) to
   the treasury, as USDC or as vault shares. This step is best effort: if it fails the USDC stays in the contract and
   the next `forward` retries.

The contract is not upgradeable. After deployment the vault, the global fee configuration and the treasury can only
change through proposals that become executable after immutable **72-hour delays** (`proposeVault` →
`executeVaultChange`, `proposeFeeConfig` → `executeFeeConfigChange`, `proposeTreasury` → `executeTreasuryChange`).
`VAULT_GUARDIAN_ROLE` holders and the admin can cancel any pending proposal; fee managers can also cancel a pending fee
configuration. Pausing fees (fee = 0) stays immediate.

**V3 (final), deployed on Base mainnet:**
[`0x66c101cb2617256EC61833B607e3F0d98e0C1968`](https://basescan.org/address/0x66c101cb2617256ec61833b607e3f0d98e0c1968#code)
(verified; block 52,958,903; initial routing `DIRECT_DIRECT`, fees off, no pending vault / fee / treasury change, no
fee overrides, the seven management wallets hold `VAULT_GUARDIAN_ROLE` and `FEE_MANAGER_ROLE`). Audit:
[audit/FINAL_AUDIT_REPORT.md](audit/FINAL_AUDIT_REPORT.md), test matrix [audit/TEST_MATRIX.md](audit/TEST_MATRIX.md).
The SRAs are switched to V3 only after the post-deployment audit, by decision of the owner (see the report).

**V2 (previous, vault change delay only):**
[`0xCD09f43D738b10584CaBfb2f73C3adA29fc5AD53`](https://basescan.org/address/0xcd09f43d738b10584cabfb2f73c3ada29fc5ad53#code)
(verified; block 52,955,151).

**V1 (previous, without the vault change delay):**
[`0xA7A2Be29D45F0cD465BF4F8775931bfb096d5647`](https://basescan.org/address/0xa7a2be29d45f0cd465bf4f8775931bfb096d5647#code)
(verified; block 52,925,346). V1 report: [audit/FINAL_AUDIT_REPORT_V1.md](audit/FINAL_AUDIT_REPORT_V1.md), V1 test
matrix: [audit/TEST_MATRIX_V1.md](audit/TEST_MATRIX_V1.md).

The V2 audit (scope: the vault change lifecycle; V1 logic unchanged) is in
[audit/FINAL_AUDIT_REPORT_V2.md](audit/FINAL_AUDIT_REPORT_V2.md), test matrix
[audit/TEST_MATRIX_V2.md](audit/TEST_MATRIX_V2.md).

## Layout

| Path | Content |
|---|---|
| `src/Forwarder.sol` | The contract |
| `script/ForwarderDeployConfig.sol` | Base mainnet production parameters (USDC, admin, treasury, vault, routing, fee managers, vault guardians) |
| `script/DeployForwarder.s.sol` | Deployment script (preflight checks, health-check approval, deployment, post-deployment assertions) |
| `test/` | Unit, fuzz, invariant (`test/invariants/`), Base fork (`test/fork/`, `ForwarderFork.t.sol`) and post-deployment fork tests |
| `echidna/` | Echidna harnesses: `ForwarderV3Echidna.sol` (fee, treasury and override lifecycles), `ForwarderVaultChangeEchidna.sol` (vault change lifecycle) and `ForwarderEchidna.sol` (V1 regression) |
| `certora/` | Certora harness, model contracts, specifications (`ForwarderV3.spec` complete V3; `Forwarder.spec` V1 and `ForwarderV2.spec` V2 kept as record) and configuration (`ForwarderV3*.conf`) |
| `audit/` | Audit reports (V3 current, V2 and V1 kept), test matrices, scripts and raw tool outputs (`audit/raw/v3/` for V3) |

## Roles

| Role | Holder | Can |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` (`AccessControlDefaultAdminRules`, 3-day transfer delay) | Admin Safe | propose / execute (after 72 h) / cancel a vault change and a treasury change, cancel a fee configuration change, set routing mode, grant/revoke roles, pause and unpause fees, rescue ERC-20 and native balances (always to the current treasury) |
| `FEE_MANAGER_ROLE` | Operational wallets | propose / execute (after 72 h) / cancel a fee configuration change, set fee overrides (at most the global fee), pause fees |
| `VAULT_GUARDIAN_ROLE` (admin: `DEFAULT_ADMIN_ROLE`) | Guardian wallets | cancel a pending vault change, fee configuration change or treasury change — nothing else (the name is kept from V2) |

`pause()` only pauses **fees** (fee = 0). `forward` is never paused, the routing and the allowances do not change. Only
the admin can unpause. To stop using the active vault in an emergency use `setRoutingMode(DIRECT_DIRECT)` (immediate:
no vault calls, allowance set to 0); `pause()` does not do that.

## Vault change (72-hour delay)

```text
ACTIVE VAULT --proposeVault--> PENDING (executableAt = now + 72 h) --executeVaultChange (>= executableAt)--> NEW ACTIVE VAULT
                                       \--cancelVaultChange (admin or guardian, any time)--> NO PENDING
```

- `VAULT_CHANGE_DELAY = 72 hours` is a constant: no setter, no bypass, not even for the admin.
- One proposal at a time: a second proposal reverts until the pending one is cancelled or executed.
- `proposeVault` and `executeVaultChange` both run the real health check (0.001 USDC of the caller, deposit + redeem,
  refunded). The candidate gets no allowance while pending; the execution sets the old vault allowance to 0 and gives
  the new vault an unlimited allowance only if the routing mode in force **at execution** uses the vault.
- A failed execution reverts entirely (the proposal stays pending and can be retried or cancelled).
- The initial vault is set by the constructor without delay.

## Fee configuration change (72-hour delay)

```text
ACTIVE FEES --proposeFeeConfig--> PENDING (executableAt = now + 72 h) --executeFeeConfigChange (>= executableAt)--> NEW ACTIVE FEES
                                         \--cancelFeeConfigChange (admin, guardian or fee manager, any time)--> NO PENDING
```

- `FEE_CHANGE_DELAY = 72 hours` is a constant. **Every** change of `lowerFeeModel`, `upperFeeModel`, `threshold`,
  `fixedFee` and `variableFee` goes through it (there is no immediate setter and changes are not classified as
  increases or decreases). Proposing and executing require `FEE_MANAGER_ROLE` (the admin only with that role too).
- The proposal holds the whole configuration (`pendingFeeConfig`), checks the caps, and does not touch the active
  configuration. One proposal at a time: a second one reverts until the pending one is cancelled or executed.
- `pause()` stays immediate (fee = 0). A proposal can be made and executed while paused; the fee stays zero until
  the admin unpauses.

## Treasury change (72-hour delay)

```text
ACTIVE TREASURY --proposeTreasury--> PENDING (executableAt = now + 72 h) --executeTreasuryChange (>= executableAt)--> NEW TREASURY
                                             \--cancelTreasuryChange (admin or guardian, any time)--> NO PENDING
```

- `TREASURY_CHANGE_DELAY = 72 hours` is a constant; only the admin proposes and executes. Until the execution, fees and
  rescues keep going to the **current** treasury; the pending treasury receives nothing. USDC left in the contract is
  delivered to the new treasury by the first `forward` after the execution.
- The initial treasury is set by the constructor without delay.

## Fee overrides

- `setUserFeeOverride(recipient, fixedFee, variableFee, validUntil)` (`FEE_MANAGER_ROLE`): `recipient != 0`,
  `validUntil > now`, both values at most the **active** global values. The recipient is the `recipient` of
  `forward` (the user's Kernel).
- While active (`block.timestamp < validUntil`) the override can only be lowered and/or extended: it cannot be
  raised, shortened or removed. From `validUntil` on it is ignored automatically (no transaction needed); an expired
  override can be replaced freely.
- `calculateFeeFor(recipient, amount)` is the fee `forward` charges: `calculateFee(amount)` without an active override;
  with one, the global models and threshold with `min(override, global)` as fixed and variable fee, so a recipient
  never pays more than the current global fee. Zero while fees are paused. `calculateFee(amount)` keeps returning the
  global fee: quotes for a recipient must use `calculateFeeFor`.
- An override caps each component separately (fixed and variable), not the total: the model and the threshold stay
  global, so a later model change can make the other component apply. A component that is 0 when the override is set
  stays 0 while it is active. **While the global fees are 0 (as at deployment) the only possible override is (0, 0),
  a full exemption that keeps applying after fees are enabled: set overrides only once the intended global
  configuration is active.**
- `validUntil` is a Unix timestamp in **seconds** and has no upper bound (an override cannot be revoked before it):
  use finite, short periods and check the value off-chain before sending. Overrides are keyed by recipient, whoever
  calls `forward`: do not grant them to shared or forwarding contracts.

## Fees

- `variableFee` over `FEE_DENOMINATOR = 100_000` (1 = 0.001%), at most `10_000` (10%).
- `fixedFee` in USDC units (6 decimals), at most `10_000_000` (10 USDC).
- `amount <= threshold` uses `lowerFeeModel`, `amount > threshold` uses `upperFeeModel`; the selected model is applied
  to the full amount. Models: `NONE`, `FIXED`, `PERCENT`, `FIXED_PLUS_PERCENT`. The percentage rounds down.
- `fee > amount` reverts (checked arithmetic). `fee == amount` is allowed (the user receives 0).
- The fee of a recipient is `calculateFeeFor(recipient, amount)` (see Fee overrides).

## Routing modes

| Mode | User receives | Treasury receives | Vault allowance |
|---|---|---|---|
| `DIRECT_DIRECT` | USDC | USDC | 0 |
| `VAULT_USER_DIRECT_TREASURY` | vault shares | USDC | unlimited |
| `DIRECT_USER_VAULT_TREASURY` | USDC | vault shares | unlimited |
| `VAULT_VAULT` | vault shares | vault shares | unlimited |

## Requirements

- Foundry 1.5.1 (`forge`, `cast`), solc 0.8.30 (downloaded by Foundry; `solc-select` 0.8.30 for Echidna/Certora)
- `.env` with `BASE_RPC_URL` (Base mainnet RPC) and `ETHERSCAN_API_KEY` (Etherscan v2 key) — never commit it
- Slither, Echidna 2.2.5, Certora CLI with `CERTORAKEY` for the respective tools

Dependencies are git submodules pinned to tags: OpenZeppelin Contracts `v5.7.0`
(`cab19933c33c2ad1d4c7a84864a3601dddfd16f3`) and forge-std `v1.12.0` (`7117c90c8cf6c68e5acce4f09a6b24715cea4de6`).

```shell
git submodule update --init --recursive
```

## Build and test

```shell
forge fmt --check
forge build --sizes
forge test --no-match-contract Fork                       # unit + fuzz + invariant (default profile)
FOUNDRY_PROFILE=deep forge test --no-match-contract "Fork|Invariant" --match-test testFuzz   # every fuzz test, 50k runs
FOUNDRY_INVARIANT_RUNS=2000 FOUNDRY_INVARIANT_DEPTH=250 \
  forge test --match-path test/ForwarderV3Invariant.t.sol                            # V3 deep invariants
FOUNDRY_PROFILE=deep forge test --match-path "test/Forwarder{,VaultChange}Invariant.t.sol"   # V1 / V2 invariants
forge test --match-contract ForwarderForkTest             # Base fork, pinned block 52,951,000
FORK_BLOCK=0 forge test --match-contract ForwarderForkTest  # Base fork, latest block
forge coverage --no-match-coverage "(test|script)/" --no-match-contract Fork --report summary --report lcov
forge test --no-match-contract Fork --gas-report
```

Post-deployment suite against the deployed contract (skipped when `DEPLOYED_FORWARDER` is not set):

```shell
DEPLOYED_FORWARDER=<address> POST_DEPLOY_FORK_BLOCK=<block after deployment> \
  forge test --match-contract ForwarderPostDeployForkTest
```

## Static analysis and formal tools

```shell
slither . --filter-paths "lib/|test/|script/|echidna/|certora/"
SOLC_VERSION=0.8.30 echidna echidna/ForwarderV3Echidna.sol --contract ForwarderV3Echidna \
  --config echidna/echidna-v3.yaml --workers 4                                    # fee / treasury / overrides (V3)
SOLC_VERSION=0.8.30 echidna echidna/ForwarderVaultChangeEchidna.sol --contract ForwarderVaultChangeEchidna \
  --config echidna/echidna-v2.yaml --workers 4                                    # vault lifecycle (V2)
SOLC_VERSION=0.8.30 echidna echidna/ForwarderEchidna.sol --contract ForwarderEchidna --config echidna/echidna.yaml
for c in Lifecycle Fees Forward Access Vault Invariants; do
  SOLC_VERSION=0.8.30 certoraRun certora/conf/ForwarderV3$c.conf --wait_for_results all   # complete V3 spec
done
python3 audit/scripts/mutation_v3.py <work dir> <report.md> --jobs 2   # V2 + V3 mutation testing
```

Run the Echidna campaigns one after the other (or wait until each has finished compiling): they share
`crytic-export/combined_solc.json`. `certora/conf/Forwarder*.conf` (V1) and `ForwarderV2*.conf` (V2) are kept as the
record of the earlier proofs; they reference functions that V2/V3 removed.

## Deployment

All production parameters are constants in `script/ForwarderDeployConfig.sol`; every role is granted by the
constructor in the deployment transaction. `run()` refuses to broadcast while `vaultGuardians()` is empty. The constructor runs the vault health check with 0.001 USDC of the
deployer, so the script sends `approve(predictedForwarder, 1000)` first (the recovered USDC is refunded; the Luca
vault keeps 1 unit to rounding).

```shell
# simulation only (pin a recent block: simulating on "latest" can see Aave state newer than the block timestamp)
forge script script/DeployForwarder.s.sol --rpc-url base --fork-block-number <head - 2> --sender <DEPLOYER>
# broadcast + verification
forge script script/DeployForwarder.s.sol --rpc-url base --fork-block-number <head - 2> --account <KEYSTORE> \
  --sender <DEPLOYER> --broadcast --slow --verify --verifier etherscan
# if Basescan has not indexed the code yet, verify afterwards with the constructor args logged by the script
forge verify-contract <address> src/Forwarder.sol:Forwarder --chain 8453 --verifier etherscan \
  --constructor-args <args> --watch
```

## Operations

| Action | Who | Calls (Safe batch for the admin) |
|---|---|---|
| Switch routing | admin | `setRoutingMode(mode)` |
| Propose a vault | admin | `USDC.approve(forwarder, 1000)` then `proposeVault(candidate)` (the recovered USDC returns to the Safe) |
| Execute the vault change (from `pendingVaultExecutableAt`) | admin | `USDC.approve(forwarder, 1000)` then `executeVaultChange()` |
| Cancel the vault change | admin or guardian | `cancelVaultChange()` |
| Propose a fee configuration | fee manager | `proposeFeeConfig(lower, upper, threshold, fixedFee, variableFee)` (whole configuration) |
| Execute it (from `pendingFeeConfig().executableAt`) | fee manager | `executeFeeConfigChange()` |
| Cancel it | admin, guardian or fee manager | `cancelFeeConfigChange()` |
| Propose a treasury | admin | `proposeTreasury(newTreasury)` |
| Execute it (from `pendingTreasuryExecutableAt`) | admin | `executeTreasuryChange()` — USDC left in the contract goes to the new treasury on the next `forward` |
| Cancel it | admin or guardian | `cancelTreasuryChange()` |
| Fee discount for a recipient | fee manager | `setUserFeeOverride(recipient, fixedFee, variableFee, validUntil)` — irrevocable until `validUntil` |
| Pause fees | admin or fee manager | `pause()` (immediate, fee = 0) |
| Unpause fees | admin | `unpause()` — check the fee configuration first |
| Manage guardians / fee managers | admin | `grantRole` / `revokeRole` |
| Recover stuck funds | admin | `rescueToken(token)` / `rescueNative()` — always to the current treasury |

Calldata can be produced with `cast calldata`, e.g. `cast calldata "setRoutingMode(uint8)" 1`.
If a vault misbehaves, switch to `DIRECT_DIRECT` (no vault calls, allowance set to 0); a replacement takes at least
72 hours.

**Matured proposals do not expire.** A vault, fee or treasury proposal that has reached its `executableAt` stays
executable until it is executed or cancelled. Any matured proposal that is not going to be executed right away must be
cancelled.

## Monitoring

The delays only protect if the proposals are noticed in time. Alert (externally, in real time) at least on:
`VaultChangeProposed`, `VaultChangeCancelled`, `VaultUpdated`, `FeeConfigChangeProposed`, `FeeConfigChangeCancelled`,
`FeeConfigUpdated` (fee configuration executed), `TreasuryChangeProposed`, `TreasuryChangeCancelled`, `TreasuryUpdated`
(treasury changed), `UserFeeOverrideSet`, `Paused` / `Unpaused`, `RoleGranted` / `RoleRevoked` (in particular
`VAULT_GUARDIAN_ROLE` and `FEE_MANAGER_ROLE`) and the `DefaultAdmin*` transfer events. An unexpected proposal must be
cancelled by a guardian and, if the admin Safe or a fee manager may be compromised, the SRA flow must be stopped
off-chain before `executableAt`.
