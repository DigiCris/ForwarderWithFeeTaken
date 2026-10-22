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

The contract is not upgradeable.

**Deployed on Base mainnet:** [`0xA7A2Be29D45F0cD465BF4F8775931bfb096d5647`](https://basescan.org/address/0xa7a2be29d45f0cd465bf4f8775931bfb096d5647#code)
(verified; block 52,925,346; initial routing `DIRECT_DIRECT`, fees off). The full specification as implemented, the trust model and the audit results are in
[audit/FINAL_AUDIT_REPORT.md](audit/FINAL_AUDIT_REPORT.md); the test matrix is in
[audit/TEST_MATRIX.md](audit/TEST_MATRIX.md).

## Layout

| Path | Content |
|---|---|
| `src/Forwarder.sol` | The contract |
| `script/ForwarderDeployConfig.sol` | Base mainnet production parameters (USDC, admin, treasury, vault, routing, fee managers) |
| `script/DeployForwarder.s.sol` | Deployment script (preflight checks, health-check approval, deployment, post-deployment assertions) |
| `test/` | Unit, fuzz, invariant (`test/invariants/`), Base fork (`test/fork/`, `ForwarderFork.t.sol`) and post-deployment fork tests |
| `echidna/` | Echidna harness and configuration |
| `certora/` | Certora harness, model contracts, specification and configuration |
| `audit/` | Final audit report, test matrix and raw tool outputs |

## Roles

| Role | Holder | Can |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` (`AccessControlDefaultAdminRules`, 3-day transfer delay) | Admin Safe | set treasury, set vault (with health check), set routing mode, grant/revoke roles, pause and unpause fees, rescue ERC-20 and native balances |
| `FEE_MANAGER_ROLE` | Operational wallets | set fee models, threshold, fixed fee, variable fee; pause fees |

`pause()` only pauses **fees** (fee = 0). `forward` is never paused. Only the admin can unpause.

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
FOUNDRY_PROFILE=deep forge test --no-match-contract Fork  # deep fuzz/invariant campaign
forge test --match-contract ForwarderForkTest             # Base fork, pinned block 52,921,000
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
SOLC_VERSION=0.8.30 echidna echidna/ForwarderEchidna.sol --contract ForwarderEchidna --config echidna/echidna.yaml
SOLC_VERSION=0.8.30 certoraRun certora/conf/Forwarder.conf
```

## Deployment

All production parameters are constants in `script/ForwarderDeployConfig.sol`; every role is granted by the
constructor in the deployment transaction. The constructor runs the vault health check with 0.001 USDC of the
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
| Replace the vault | `USDC.approve(forwarder, 1000)` then `setVault(newVault)` (the recovered USDC returns to the Safe) |
| Change treasury | `setTreasury(newTreasury)` — pending USDC goes to the new treasury on the next `forward` |
| Recover stuck funds | `rescueToken(token)` / `rescueNative()` — always to the current treasury |
| Unpause fees | `unpause()` — check the fee configuration first |

Calldata can be produced with `cast calldata`, e.g. `cast calldata "setRoutingMode(uint8)" 1`.
If a vault misbehaves, switch to `DIRECT_DIRECT` (no vault calls, allowance set to 0) and/or replace the vault.
