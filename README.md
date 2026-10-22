# ForwarderWithFeeTaken

`Forwarder` is the last hop of the ZeroDev Smart Routing Address (SRA) deposit flow on Base. The SRA approves USDC
to the Forwarder and calls `forward(token, amount, recipient)`; the Forwarder:

1. pulls `amount` USDC from the caller;
2. computes the Luca fee (zero while fees are paused);
3. delivers `amount - fee` to `recipient`, as USDC or as shares of an ERC-4626 vault (falling back to USDC if the
   vault deposit fails);
4. tries to deliver its **whole** remaining USDC balance (fee + anything left from previous calls or donations) to
   the treasury, as USDC or as vault shares. This step is best effort: if it fails the USDC stays in the contract and
   the next `forward` retries.

The contract is not upgradeable. After deployment the vault can only be replaced through a proposal that becomes
executable after an immutable **72-hour delay** (`proposeVault` → `executeVaultChange`); `VAULT_GUARDIAN_ROLE` holders
and the admin can cancel a pending proposal.

**V2 (current), deployed on Base mainnet:**
[`0xCD09f43D738b10584CaBfb2f73C3adA29fc5AD53`](https://basescan.org/address/0xcd09f43d738b10584cabfb2f73c3ada29fc5ad53#code)
(verified; block 52,955,151; initial routing `DIRECT_DIRECT`, fees off, no pending vault change, the seven management
wallets hold `VAULT_GUARDIAN_ROLE` and `FEE_MANAGER_ROLE`).

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
| `echidna/` | Echidna harnesses: `ForwarderEchidna.sol` (V1 regression) and `ForwarderVaultChangeEchidna.sol` (vault change lifecycle) |
| `certora/` | Certora harness, model contracts, specifications (`Forwarder.spec` V1, `ForwarderV2.spec` vault lifecycle) and configuration |
| `audit/` | Audit reports (V2 current, V1 kept), test matrices, scripts and raw tool outputs (`audit/raw/v2/` for V2) |

## Roles

| Role | Holder | Can |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` (`AccessControlDefaultAdminRules`, 3-day transfer delay) | Admin Safe | set treasury, propose / execute (after 72 h) / cancel a vault change, set routing mode, grant/revoke roles, pause and unpause fees, rescue ERC-20 and native balances |
| `FEE_MANAGER_ROLE` | Operational wallets | set fee models, threshold, fixed fee, variable fee; pause fees |
| `VAULT_GUARDIAN_ROLE` (admin: `DEFAULT_ADMIN_ROLE`) | Guardian wallets | cancel a pending vault change — nothing else |

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

## Fees

- `variableFee` over `FEE_DENOMINATOR = 100_000` (1 = 0.001%), at most `10_000` (10%).
- `fixedFee` in USDC units (6 decimals), at most `10_000_000` (10 USDC).
- `amount <= threshold` uses `lowerFeeModel`, `amount > threshold` uses `upperFeeModel`; the selected model is applied
  to the full amount. Models: `NONE`, `FIXED`, `PERCENT`, `FIXED_PLUS_PERCENT`. The percentage rounds down.
- `fee > amount` reverts (checked arithmetic). `fee == amount` is allowed (the user receives 0).

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
forge test --no-match-contract Fork                       # unit + fuzz + invariant
FOUNDRY_PROFILE=deep forge test --match-path test/ForwarderVaultChangeFuzz.t.sol    # V2 targeted fuzz (50k runs)
FOUNDRY_INVARIANT_RUNS=2000 FOUNDRY_INVARIANT_DEPTH=250 \
  forge test --match-path test/ForwarderVaultChangeInvariant.t.sol                   # V2 targeted invariants
forge test --match-contract ForwarderForkTest             # Base fork, pinned block 52,951,000
FORK_BLOCK=0 forge test --match-contract ForwarderForkTest  # Base fork, latest block
forge coverage --no-match-coverage "(test|script)/" --report summary --report lcov
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
SOLC_VERSION=0.8.30 echidna echidna/ForwarderVaultChangeEchidna.sol --contract ForwarderVaultChangeEchidna \
  --config echidna/echidna-v2.yaml --workers 4                                    # vault lifecycle (V2)
SOLC_VERSION=0.8.30 echidna echidna/ForwarderEchidna.sol --contract ForwarderEchidna --config echidna/echidna.yaml
SOLC_VERSION=0.8.30 certoraRun certora/conf/ForwarderV2.conf            # V2 targeted rules
SOLC_VERSION=0.8.30 certoraRun certora/conf/ForwarderV2Invariants.conf  # V2 targeted invariants
python3 audit/scripts/mutation_v2.py <work dir> <report.md>              # V2 mutation testing
```

`certora/conf/Forwarder*.conf` are the V1 configurations (proven on the V1 source, commit `8687669`); they reference
`setVault`, which V2 removed, and are kept as the record of the V1 proofs.

```shell
```

## Deployment

All production parameters are constants in `script/ForwarderDeployConfig.sol`; every role is granted by the
constructor in the deployment transaction. `run()` refuses to broadcast while `vaultGuardians()` is empty. The constructor runs the vault health check with 0.001 USDC of the
deployer, so the script sends `approve(predictedForwarder, 1000)` first (the recovered USDC is refunded; the Luca
vault keeps 1 unit to rounding).

```shell
# simulation only
forge script script/DeployForwarder.s.sol --rpc-url base --sender <DEPLOYER>
# broadcast + verification
forge script script/DeployForwarder.s.sol --rpc-url base --account <KEYSTORE> --sender <DEPLOYER> \
  --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
```

## Operations (admin Safe)

| Action | Calls (Safe batch) |
|---|---|
| Switch routing | `setRoutingMode(mode)` |
| Propose a vault | `USDC.approve(forwarder, 1000)` then `proposeVault(candidate)` (the recovered USDC returns to the Safe) |
| Execute the change (from `pendingVaultExecutableAt`) | `USDC.approve(forwarder, 1000)` then `executeVaultChange()` |
| Cancel the change | `cancelVaultChange()` (admin Safe or any guardian) |
| Manage guardians | `grantRole(VAULT_GUARDIAN_ROLE, account)` / `revokeRole(VAULT_GUARDIAN_ROLE, account)` |
| Change treasury | `setTreasury(newTreasury)` — pending USDC goes to the new treasury on the next `forward` |
| Recover stuck funds | `rescueToken(token)` / `rescueNative()` — always to the current treasury |
| Unpause fees | `unpause()` — check the fee configuration first |

Calldata can be produced with `cast calldata`, e.g. `cast calldata "setRoutingMode(uint8)" 1`.
If a vault misbehaves, switch to `DIRECT_DIRECT` (no vault calls, allowance set to 0); a replacement takes at least
72 hours. Monitor `VaultChangeProposed`: an unexpected proposal must be cancelled by a guardian and, if the admin Safe
may be compromised, the SRA flow must be stopped off-chain before `executableAt`.
