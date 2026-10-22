# Forwarder — Informe final de implementación, pruebas y auditoría

| Campo | Valor |
|---|---|
| Proyecto | `ForwarderWithFeeTaken` |
| Contrato | `src/Forwarder.sol` (`Forwarder`) |
| Red | Base mainnet (chainId 8453) |
| Fecha | 2026-10-21 |
| Compilador | solc 0.8.30+commit.73712a01, optimizer 200 runs, EVM `cancun`, pipeline legacy (sin via-IR), metadata `ipfs` |
| Dependencias | OpenZeppelin Contracts `v5.7.0` (`cab19933c33c2ad1d4c7a84864a3601dddfd16f3`), forge-std `v1.12.0` (`7117c90c8cf6c68e5acce4f09a6b24715cea4de6`) |
| Código desplegado | `src/Forwarder.sol` del commit `1ef93c9` (rama `feature/forwarder`; sin cambios posteriores), sha256 `606d02c702d01fdf546d9ae9f513f171dc3b96b7c7ba5150f005b6369367acf7` |
| Dirección | `0xA7A2Be29D45F0cD465BF4F8775931bfb096d5647` (Base, verificado) |

Este documento describe lo que **efectivamente quedó implementado y desplegado**, cómo se verificó y qué riesgos
quedan. Está escrito para que un revisor sin acceso a la conversación original pueda contrastarlo punto por punto
contra la especificación.

---

## A. Executive Summary

**Qué se construyó.** Un contrato no upgradeable (`Forwarder`) que es el último salto del flujo de depósitos
cross-chain de ZeroDev Smart Routing Addresses (SRA) en Base. La SRA aprueba USDC al Forwarder y llama
`forward(token, amount, recipient)`. El Forwarder toma `amount` USDC del llamador, calcula la comisión de Luca,
entrega `amount - fee` al usuario (USDC directo o shares de un ERC-4626 emitidas al usuario, con fallback automático a
USDC si el depósito en el vault falla) y luego intenta entregar **todo** el saldo USDC remanente del contrato al
treasury (USDC directo o shares del vault), en modo best-effort: si la entrega al treasury falla, los fondos quedan en
el contrato y se reintentan en el próximo `forward`, sin revertir nunca la entrega al usuario.

**Resultado general.** Implementación completa de la especificación, con las desviaciones menores (todas sin impacto
funcional o explícitamente confirmadas por el usuario) listadas en la sección L.

**Evidencia.**

- 171 tests locales (unit + fuzz + invariantes) y 26 tests de integración sobre fork de Base mainnet: todos pasan.
- Coverage de `src/Forwarder.sol`: 100% líneas (142/142), 100% statements (167/167), 100% branches (32/32),
  100% funciones (24/24).
- Fuzz profundo: 13 tests × 50.000 runs. Invariantes profundas: 12 invariantes × 1.000 runs × 200 llamadas
  (200.000 llamadas por invariante), 0 fallas.
- Mutation testing dirigido: 16/16 mutantes detectados.
- Slither 0.11.6 y 0.10.4: 0 true positives (13 y 11 resultados, todos analizados en la sección G).
- Echidna 2.2.5: 11 propiedades, 500.000 llamadas, 0 contraejemplos (sección H).
- Certora Prover: **42 reglas y 6 invariantes verificadas** ("No errors found by Prover!", sin reglas vacuas), con el
  modelado y las configuraciones del prover documentados en la sección I.

**Hallazgos.** 0 Critical, 0 High, 1 Medium **abierto de configuración** (el Safe admin indicado es 1-de-1 y su único
owner también es fee manager; el usuario decidió desplegar igual y subir el threshold después — no requiere redeploy),
y hallazgos Low/Informational, la mayoría resueltos durante el desarrollo (sección J).

**Nivel de confianza.** Alto sobre la lógica del contrato (pruebas exhaustivas, fork real, verificación formal de
propiedades clave). La seguridad global depende de supuestos de confianza explícitos: admin (multisig), USDC y vault
(sección D).

**Deploy y verificación.** Desplegado en Base mainnet en `0xA7A2Be29D45F0cD465BF4F8775931bfb096d5647` (bloque
52.925.346, tx `0x907a1d46…56dd`) y **verificado** en Basescan. El bytecode desplegado es idéntico al auditado
(comparación de creation code, runtime code y constructor args). La suite de fork contra la dirección real pasa 24/24.

---

## B. Functional Specification Implemented

Referencias de línea sobre `src/Forwarder.sol` del commit desplegado.

### B.1 Herencia y estado

- `Forwarder is AccessControlDefaultAdminRules, Pausable, ReentrancyGuardTransient` (L30), todo de OpenZeppelin v5.7.0.
- Sin proxy, sin `delegatecall`, sin `selfdestruct`, sin `receive`/`fallback` (no acepta ETH directo). Verificado
  recorriendo los opcodes del runtime (`test_RuntimeCodeHasNoDelegatecallOrSelfdestruct`) y por Slither.
- Constantes: `FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE")` (L50), `FEE_DENOMINATOR = 100_000` (L53),
  `MAX_VARIABLE_FEE = 10_000` (10%, L56), `MAX_FIXED_FEE = 10_000_000` (10 USDC, L59),
  `VAULT_TEST_AMOUNT = 1000` (0.001 USDC, L63).
- Inmutable: `IERC20 public immutable USDC` (L66). No hay forma de cambiarlo después del deploy.
- Storage configurable: `treasury` (L69), `vault` (L72), `routingMode` (L75), `lowerFeeModel` (L78),
  `upperFeeModel` (L81), `threshold` (L84), `fixedFee` (L87), `variableFee` (L90). Más el estado heredado de
  AccessControlDefaultAdminRules y Pausable (`_paused`).

### B.2 `forward(address token, uint256 amount, address recipient)` (L199-L228), `nonReentrant`

Orden real de ejecución:

1. `token != USDC` → revert `UnsupportedToken(token)`. `forward` no procesa ningún otro token.
2. `recipient == address(0)` o `recipient == address(this)` → revert `InvalidRecipient(recipient)`.
3. `fee = calculateFee(amount)`; `userAmount = amount - fee` (aritmética checked: si `fee > amount` revierte con
   `Panic(0x11)`; no hay clamp ni require adicional). Se calcula antes de mover fondos; como la tx es atómica, el
   resultado es idéntico al orden conceptual de la especificación (ver L-02).
4. `USDC.safeTransferFrom(msg.sender, address(this), amount)`: toma `amount` usando el allowance que otorgó la SRA.
   Si falla, revierte todo.
5. Snapshot de configuración: `mode = routingMode`, `currentVault = vault`, `currentTreasury = treasury` (L208-L210).
   Toda la operación usa esta foto, aun si un actor privilegiado reentrara a un setter no protegido.
6. Pierna del usuario:
   - Si `mode ∈ {VAULT_USER_DIRECT_TREASURY, VAULT_VAULT}`: `try currentVault.deposit(userAmount, recipient)`; las
     shares se emiten directamente a `recipient`. Si el depósito revierte por cualquier motivo (incluido allowance
     agotado, vault pausado, cap, `deposit(0)` rechazado), se emite
     `UserVaultDepositFailed(recipient, vault, userAmount, reason)` y se cae al punto siguiente.
   - Si no hubo depósito exitoso: `USDC.safeTransfer(recipient, userAmount)`. Si esa transferencia falla, **revierte
     toda la operación** (los fondos vuelven a quedar en la SRA).
   - No hay rama especial para `userAmount == 0`.
7. `emit Forwarded(caller, recipient, amount, fee, userAmount, userVaultDeposit, userShares)`.
8. Pierna del treasury: `_deliverToTreasury(mode, currentVault, currentTreasury)` (B.10).

### B.3 Cálculo de la comisión — `calculateFee(uint256 amount)` (L235-L245)

```text
si paused()                → 0
modelo = amount <= threshold ? lowerFeeModel : upperFeeModel
NONE                       → 0
FIXED                      → fixedFee
PERCENT                    → amount * variableFee / 100_000          (redondeo hacia abajo)
FIXED_PLUS_PERCENT         → fixedFee + amount * variableFee / 100_000
```

- El modelo elegido se aplica sobre el **monto completo** (nunca sobre el excedente del threshold).
- `enum FeeModel { NONE, FIXED, PERCENT, FIXED_PLUS_PERCENT }` (L34); selección con `if` encadenados, sin function
  pointers ni abstracciones.
- La multiplicación sólo puede desbordar con `amount > type(uint256).max / variableFee` (≈1,16e73), inalcanzable con
  USDC; en ese caso revierte (checked arithmetic). Probado formalmente (`feeMatchesSpecification`).

### B.4 Configuración de fees (`FEE_MANAGER_ROLE`)

- `setVariableFee(v)` (L270): revierte `VariableFeeTooHigh(v)` si `v > 10_000`.
- `setFixedFee(f)` (L277): revierte `FixedFeeTooHigh(f)` si `f > 10_000_000`.
- `setThreshold(t)` (L284), `setLowerFeeModel(m)` (L290), `setUpperFeeModel(m)` (L296).
- `setFeeConfig(lower, upper, threshold, fixedFee, variableFee)` (L252): actualización atómica de los cinco valores con
  las mismas validaciones (agregado, ver L-04).
- Todos emiten `FeeConfigUpdated(lowerFeeModel, upperFeeModel, threshold, fixedFee, variableFee)` con la
  configuración **completa** resultante.
- Valores de enum fuera de rango los rechaza el decoder ABI.
- Estado inicial: `NONE/NONE`, `threshold = fixedFee = variableFee = 0`, no pausado → fee 0.

### B.5 Pausa de fees

- `paused()` significa exclusivamente "fees pausados": `calculateFee` devuelve 0 y `forward` funciona como router
  puro. `forward` no tiene `whenNotPaused`.
- `pause()` (L302): `FEE_MANAGER_ROLE` o `DEFAULT_ADMIN_ROLE`; cualquier otro recibe
  `AccessControlUnauthorizedAccount(sender, FEE_MANAGER_ROLE)`. Revierte `EnforcedPause` si ya estaba pausado.
- `unpause()` (L310): sólo `DEFAULT_ADMIN_ROLE`. Revierte `ExpectedPause` si no estaba pausado.
- Eventos estándar `Paused`/`Unpaused` de OpenZeppelin (no se duplicaron).

### B.6 Roles

- `AccessControlDefaultAdminRules` con delay de transferencia del admin de **3 días** (constructor; mismo valor que usa
  el contrato `RainExecutor` del equipo). Un solo `DEFAULT_ADMIN_ROLE`; no se puede otorgar con `grantRole`;
  transferencia en dos pasos con delay; renuncia en dos pasos.
- `DEFAULT_ADMIN_ROLE`: `setTreasury`, `setVault`, `setRoutingMode`, `grantRole`/`revokeRole` (incluido
  `FEE_MANAGER_ROLE`, cuyo admin es `DEFAULT_ADMIN_ROLE`), `pause`, `unpause`, `rescueToken`, `rescueNative`, y las
  funciones de administración del propio rol admin. **No** puede cambiar fees directamente: si lo necesitara, se otorga
  `FEE_MANAGER_ROLE` (ver L-05).
- `FEE_MANAGER_ROLE` (varias cuentas): los seis setters de fees y `pause()`. No puede despausar, cambiar treasury, vault
  o routing, rescatar fondos ni otorgar roles.
- No existe `TREASURY_MANAGER_ROLE` ni whitelist de llamadores de `forward`.

### B.7 Routing

`enum RoutingMode { DIRECT_DIRECT, VAULT_USER_DIRECT_TREASURY, DIRECT_USER_VAULT_TREASURY, VAULT_VAULT }` (L42).

| Modo | Usuario | Treasury |
|---|---|---|
| `DIRECT_DIRECT` | USDC | USDC |
| `VAULT_USER_DIRECT_TREASURY` | shares | USDC |
| `DIRECT_USER_VAULT_TREASURY` | USDC | shares |
| `VAULT_VAULT` | shares | shares |

`setRoutingMode(mode)` (L334, `DEFAULT_ADMIN_ROLE`, `nonReentrant`): un modo que usa el vault exige vault
configurado (`VaultNotSet`); actualiza el allowance según B.12; emite `RoutingModeUpdated(previous, new)`.

### B.8 ERC-4626

- El vault es una dependencia **de confianza** configurada sólo por el admin (D).
- Depósitos: `deposit(assets, receiver)` con `receiver = recipient` (usuario) o `receiver = treasury`.
- Por estar en modo vault, el vault tiene allowance ilimitado de USDC del Forwarder.

### B.9 Fallback del usuario

Descrito en B.2 paso 6. Detalle de robustez: `try/catch` captura cualquier revert del vault, pero Solidity **no**
captura errores de decodificación del valor de retorno. Si un vault (no conforme) completara `deposit` devolviendo
datos malformados, `forward` revierte entero y los fondos siguen en la SRA. Se eligió así a propósito: tratarlo como
"fallo" y pagar USDC al usuario podría pagarle dos veces si el vault sí tomó los fondos. Cubierto por
`test_UserLegRevertsWhenVaultReturnsMalformedData` (ver J, I-04).

### B.10 Entrega al treasury — `_deliverToTreasury` (L364-L382)

1. `balance = USDC.balanceOf(this)`. Incluye la fee de esta operación, fees no entregadas antes, USDC donado y dust.
2. Si `balance == 0` no hace nada (sin llamadas ni eventos; ver L-07).
3. Modo vault para treasury: llamada de bajo nivel `deposit(balance, treasury)`.
   - Éxito con al menos 32 bytes de retorno → `TreasuryVaultDeposited(treasury, vault, balance, shares)`.
   - Cualquier otra cosa → `TreasuryVaultDepositFailed(treasury, vault, balance, returnData)`; nunca revierte.
   - Se usa bajo nivel (y no `try/catch`) para que ni siquiera un retorno malformado pueda revertir una entrega ya
     hecha al usuario (requisito "si falla el treasury, no revertir al usuario"). Como no se lleva contabilidad interna
     y el próximo `forward` vuelve a medir el saldo, un resultado mal reportado no puede duplicar fondos.
4. Modo directo: `USDC.trySafeTransfer(treasury, balance)` (primitiva estándar de OpenZeppelin, no revierte; devuelve
   `false` si el token revierte o devuelve `false`) → `TreasuryTransferred` o `TreasuryTransferFailed`.
5. Si falla, el USDC queda en el Forwarder y el próximo `forward` intenta entregar todo el acumulado. También puede
   recuperarse con `rescueToken(USDC)`.

### B.11 Saldos acumulados

El Forwarder no lleva contabilidad interna. El usuario sólo recibe `amount - fee` de su propio depósito; todo lo demás
(acumulado, donaciones, dust) va siempre al treasury **vigente** en el momento de la entrega. Un llamador no puede
retirar saldos ajenos: la pierna del usuario está acotada a lo que ese llamador pagó.

### B.12 Allowance hacia el vault

- `forward` nunca llama `approve`.
- `setRoutingMode`: si cambia el uso del vault, `forceApprove(vault, MAX)` (a modo vault) o `forceApprove(vault, 0)`
  (a `DIRECT_DIRECT`); si no cambia (DIRECT→DIRECT o vault→vault), no hace nada.
- `setVault`: allowance del vault anterior a 0 antes de llamar al candidato; al final, nuevo vault con MAX si el routing
  usa vault o 0 si es `DIRECT_DIRECT`.
- Se usa `SafeERC20.forceApprove`.
- Nota: el USDC real (FiatToken) descuenta incluso un allowance `type(uint256).max` en cada `transferFrom`; el valor
  es inagotable en la práctica y volver a ejecutar `setVault` con el mismo vault lo restablece a MAX.

### B.13 Reemplazo de vault y health check — `setVault(IERC4626)` (L329), `_setVault` (L390), `_vaultHealthCheck` (L412)

`setVault` es `DEFAULT_ADMIN_ROLE` + `nonReentrant`:

1. Candidato `!= 0` (`ZeroAddress`), con código (`VaultNotContract`), `asset()` responde y es USDC
   (`VaultAssetMismatch`).
2. Allowance del vault anterior → 0.
3. Health check real con fondos del **llamador**:
   - `transferFrom(msg.sender, this, 1000)` (el admin debe aprobar 0,001 USDC antes).
   - `forceApprove(candidato, 1000)`; `deposit(1000, this)`.
   - Shares recibidas = delta de `balanceOf(this)` (no se confía en el valor devuelto); si 0 → `VaultNoSharesMinted`.
   - `redeem(todas esas shares, this, this)` (se prefiere `redeem` a `withdraw`).
   - USDC recuperado = delta de `USDC.balanceOf(this)`; si 0 → `VaultNoAssetsReturned`. No se exige igualdad con
     1000: el vault real de Luca devuelve 999 por redondeo y se acepta.
   - Se devuelve al llamador **todo** el USDC neto de la operación (lo recuperado + lo que el vault no hubiera tomado).
     Nunca se usa USDC que el Forwarder tuviera antes.
4. `vault = nuevo`; allowance final según el routing; `VaultUpdated(previous, new, healthCheckShares, healthCheckAssets)`.
5. Cualquier falla revierte todo: no hay cambios parciales de configuración.

### B.14 Rescate

- `rescueToken(IERC20 token)` (L339): `DEFAULT_ADMIN_ROLE`, `nonReentrant`; envía **todo** el balance de cualquier
  ERC-20 (USDC incluido, también shares del vault) al treasury vigente con `safeTransfer`; `TokenRescued`.
- `rescueNative()` (L347): `DEFAULT_ADMIN_ROLE`, `nonReentrant`; envía todo el ETH (que sólo puede llegar forzado:
  `selfdestruct`, etc.) al treasury con `Address.sendValue`; `NativeRescued`.

### B.15 Reentrancy

`ReentrancyGuardTransient` (EIP-1153). `nonReentrant` en `forward`, `setVault` (llama al candidato no confiable),
`setRoutingMode` (`approve` externo), `rescueToken` (token arbitrario) y `rescueNative` (llamada con valor). No se aplicó
a setters que sólo escriben storage (no hacen llamadas externas). Verificado: TSTORE/TLOAD funcionan con
`evm_version = cancun` en fork de Base; Base soporta EIP-1153 desde el upgrade Ecotone.

### B.16 Constructor

`constructor(usdc, initialAdmin, initialAdminDelay, initialTreasury, initialVault, initialRoutingMode, initialFeeManagers)`:

- `usdc != 0`; admin `!= 0` (lo valida OpenZeppelin); treasury válido.
- Si `initialVault != 0` corre **el mismo** `_setVault` con health check, financiado por el deployer (que aprueba 0,001
  USDC a la dirección del contrato antes de desplegarlo).
- Aplica `initialRoutingMode` con las mismas reglas que `setRoutingMode`.
- Otorga `FEE_MANAGER_ROLE` a cada dirección de `initialFeeManagers` (`!= 0`). El deployer no recibe ningún rol salvo
  que esté en la lista.
- Fees en cero.

### B.17 Eventos y errores

Eventos: `Forwarded`, `UserVaultDepositFailed`, `TreasuryTransferred`, `TreasuryTransferFailed`,
`TreasuryVaultDeposited`, `TreasuryVaultDepositFailed`, `TreasuryUpdated`, `VaultUpdated`, `RoutingModeUpdated`,
`FeeConfigUpdated`, `TokenRescued`, `NativeRescued`, más los estándar de AccessControl y Pausable.
Errores: `ZeroAddress`, `UnsupportedToken`, `InvalidRecipient`, `InvalidTreasury`, `VariableFeeTooHigh`,
`FixedFeeTooHigh`, `VaultNotContract`, `VaultAssetMismatch`, `VaultNoSharesMinted`, `VaultNoAssetsReturned`,
`VaultNotSet`.

---

## C. Requirement Traceability Matrix

Referencias de código: `src/Forwarder.sol` (L = línea). Tests: ver abreviaturas en `audit/TEST_MATRIX.md`
(U = unit, F = fuzz, I = invariantes, K = fork Base, P = post-deploy sobre el contrato desplegado, E = Echidna,
C = Certora).

| # | Requirement | Implemented | Code reference | Test reference | Result |
|---|---|---|---|---|---|
| 1.1 | Recibir USDC desde la SRA (`transferFrom` con allowance) | Sí | L206 | U-Val `test_RevertWhen_CallerHasNoAllowance`; K `test_Fork_AllRoutingModes` | PASS |
| 1.2 | Calcular comisión | Sí | L203, L235-L245 | U-Fee (21); F; C `feeMatchesSpecification` | PASS |
| 1.3 | Usuario recibe USDC o shares emitidas al usuario | Sí | L213-L224 | U-Route (6); K `test_Fork_AllRoutingModes` | PASS |
| 1.4 | Treasury recibe fee + remanente (USDC o shares) | Sí | L364-L382 | U-Treasury; U-Donation; C `forwardTreasuryAccounting` | PASS |
| 1.5 | Fees apagables sin detener forward | Sí | L236, L302-L312 | U-Fee `test_PausedFeeIsZero`; U-Val `test_ForwardWorksWhilePaused` | PASS |
| 1.6 | Fallback automático a USDC si falla el vault del usuario | Sí | L215-L224 | U-Fallback (9); K (3) | PASS |
| 1.7 | Falla del treasury no revierte al usuario | Sí | L364-L382 | U-Treasury (8); C `treasuryFailureNeverRevertsForward` | PASS |
| 1.8 | Contrato chico y explícito | Sí | 456 líneas con NatSpec; 11.015 B runtime | — | OK |
| 2 | Stack: Solidity, Foundry, OZ pinneado, fork, Slither, Echidna, Certora, unit/fuzz/invariant | Sí | `foundry.toml`, `foundry.lock`, `.gitmodules` | secciones F-I | OK |
| 2.1 | `ReentrancyGuardTransient` verificado en Base | Sí | L30 | K (todas ejecutan TSTORE/TLOAD) | PASS |
| 3.1 | USDC canónico de Base, verificado con fuente oficial | Sí | `script/ForwarderDeployConfig.sol` | K `test_Fork_ProductionConfiguration` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| 3.2 | USDC inmutable | Sí | L66 | U-Ctor `test_InitialState` | PASS |
| 3.3 | `forward(address,uint256,address)` exige `token == USDC` | Sí | L200 | U-Val; F; C `forwardOnlyAcceptsUsdc` | PASS |
| 3.4 | Otros ERC-20 sólo por rescue | Sí | L339-L345 | U-Rescue | PASS |
| 4.1 | Treasury configurable | Sí | L319, L384-L388 | U-Val `test_SetTreasury` | PASS |
| 4.2 | Variable fee 0-10%, granularidad 0,001%, denominador 100.000 | Sí | L53, L56, L443 | U-Fee `test_VariableFeeGranularity`, `test_RevertWhen_VariableFeeAboveMaximum`; C `feeCaps` | PASS |
| 4.3 | Fixed fee 0-10 USDC | Sí | L59, L447 | U-Fee `test_FixedFeeValues`, `test_RevertWhen_FixedFeeAboveMaximum` | PASS |
| 4.4 | `lowerFeeModel`/`upperFeeModel`/`threshold`, `<=` usa lower | Sí | L78-L84, L238 | U-Fee `test_ThresholdBoundaries`; C `lowerModelUpToThreshold`/`upperModelAboveThreshold` | PASS |
| 4.5 | Cálculo sobre el monto completo | Sí | L242 | U-Fee `test_FeeUsesFullAmountAboveThreshold`; C `percentUsesWholeAmount` | PASS |
| 4.6 | enum + if, sin function pointers | Sí | L34, L237-L245 | revisión | OK |
| 4.7 | `Pausable`: paused ⇒ fee 0, forward nunca pausado | Sí | L236 | C `pausedFeeIsZero`; I `invariant_PausedImpliesZeroFee` | PASS |
| 5.1 | `fee == amount` permitido (usuario recibe 0) | Sí | L204 | U-Fee `test_FeeEqualToAmount` | PASS |
| 5.2 | `fee > amount` revierte por aritmética checked, sin clamp | Sí | L204 | U-Fee `test_RevertWhen_FeeAboveAmount` | PASS (`Panic(0x11)`) |
| 6.1 | Cuatro `RoutingMode`, sólo admin los cambia | Sí | L42, L334 | U-Route; U-AC; C `onlyAdminChangesRoutingMode` | PASS |
| 7.1 | Usuario primero, treasury después | Sí | L213-L227 | U-Route (orden de eventos) | PASS |
| 7.2 | Falla de entrada revierte | Sí | L206 | U-Val (allowance, balance, USDC pausado) | PASS |
| 7.3 | DIRECT: falla al usuario revierte todo | Sí | L223 | U-Fallback `test_RevertWhen_DirectUserTransferFails`; K `test_Fork_RevertWhen_UserIsBlacklisted` | PASS |
| 7.4 | VAULT: `deposit(userAmount, recipient)`; fallback + evento | Sí | L215-L224 | U-Fallback; K | PASS |
| 7.5 | Sin rama especial para `userAmount == 0` | Sí | — | U-Zero | PASS |
| 8.1 | Treasury toma TODO el saldo | Sí | L365 | U-Donation; U-Treasury `test_FailuresAccumulateAndAreDeliveredTogether` | PASS |
| 8.2 | Treasury DIRECT best-effort con `trySafeTransfer` + evento de falla | Sí | L377-L381 | U-Treasury `test_DirectTreasuryTransferReturningFalse`, `...Reverting`; K | PASS |
| 8.3 | Treasury VAULT best-effort, shares al treasury, evento de falla | Sí | L368-L376 | U-Treasury; K `test_Fork_TreasuryVaultFailureIsRetried` | PASS |
| 8.4 | Reintento en el próximo forward / rescue | Sí | L365 | U-Treasury; U-Rescue | PASS |
| 9.1 | Lógica no upgradeable; vault configurable por admin | Sí | L329 | U-Ctor `test_RuntimeCodeHasNoDelegatecallOrSelfdestruct`; C `onlyAdminChangesVault` | PASS |
| 9.2 | Vault documentado como trusted dependency | Sí | NatSpec L13-L29, sección D | — | OK |
| 10.1 | Health check: contrato, `asset()`, `asset == USDC`, depósito real, shares, `redeem`, assets > 0 | Sí | L390-L428 | U-SetVault (18); K `test_Fork_HealthCheckOnLucaVaultAcceptsRounding`, `test_Fork_RejectInvalidVaults` | PASS |
| 10.2 | `TEST_AMOUNT = 1000` aportado por el llamador vía `transferFrom`, sin usar USDC previo | Sí | L63, L414, L427 | U-SetVault `test_HealthCheckNeverUsesForwarderFunds`; C `healthCheckUsesOnlyCallerFunds` | PASS |
| 10.3 | No exigir igualdad; aceptar menos pero > 0 | Sí | L425 | U-SetVault `test_VaultWithRoundingLossIsAccepted`, `test_VaultReturningLessThanDepositedIsAccepted`; F | PASS |
| 10.4 | Devolver al caller lo recuperado; sin cambios parciales si falla | Sí | L427 | U-SetVault `test_FailedHealthCheckLeavesNoPartialState` | PASS |
| 10.5 | `redeem` en lugar de `withdraw`; evento al cambiar vault | Sí | L423, L403 | U-SetVault `test_SetVault` | PASS |
| 11.1 | Sin `approve` en `forward` | Sí | L199-L228 | U-Allow `test_ForwardNeverApproves`; C `forwardNeverApproves` | PASS |
| 11.2 | Allowance MAX en modos vault, 0 en DIRECT_DIRECT, con `forceApprove` | Sí | L402, L438 | U-Allow `test_EveryRoutingTransition`; C `routingModeAllowance`, `directDirectMeansNoVaultAllowance` | PASS |
| 11.3 | Cambio de vault: viejo 0, nuevo MAX/0, atómico | Sí | L397-L403 | U-Allow; C `setVaultAllowances` | PASS |
| 11.4 | DIRECT→DIRECT y vault→vault sin trabajo innecesario | Sí | L437 | U-Allow `test_EveryRoutingTransition` (cuenta `Approval`) | PASS |
| 11.5 | Allowance agotado ⇒ fallback | Sí | L218 | U-Fallback `test_FallbackWhenAllowanceIsExhausted`; K | PASS |
| 12.1 | `AccessControlDefaultAdminRules`, admin multisig, delay explícito | Sí (3 días) | L30, L171 | U-AC `test_DefaultAdminTransferRespectsDelay` | PASS (ver M-01 sobre el threshold del Safe) |
| 12.2 | Permisos del admin | Sí | L310-L352 | U-AC; K `test_Fork_AdminSafeCanAdminister` | PASS |
| 12.3 | Permisos y restricciones de FEE_MANAGER | Sí | L252-L308 | U-AC; K (7 fee managers reales); C `feeManagerCannotAdminister` | PASS |
| 12.4 | Sin `TREASURY_MANAGER_ROLE` | Sí | — | revisión | OK |
| 13 | `pause` por fee manager o admin; `unpause` sólo admin | Sí | L302-L312 | U-AC; C `onlyAdminUnpauses`, `onlyPrivilegedPause` | PASS |
| 14.1 | `rescueToken` cualquier ERC-20 → treasury, sólo admin, evento | Sí | L339-L345 | U-Rescue; K (USDC, USDbC, DAI, USDT, WETH reales); C `rescueTokenOnlyToTreasury` | PASS |
| 14.2 | `rescueNative` → treasury, sólo admin, evento | Sí | L347-L352 | U-Rescue; K; C `rescueNativeOnlyToTreasury` | PASS |
| 15 | `nonReentrant` en rutas con llamadas externas | Sí | L199, L329, L334, L339, L347 | U-Reent (9) | PASS |
| 16 | Eventos de trazabilidad | Sí | L92-L137 | tests con `expectEmit` en todas las ramas | PASS |
| 17 | Validaciones básicas sin reglas arbitrarias | Sí | L200-L201, L385, L391-L394, L443-L449 | U-Val; U-SetVault | PASS |
| — | Admin, treasury, vault y fee managers en constructor (una sola tx) | Sí | L163-L183; `script/ForwarderDeployConfig.sol` | K `test_Fork_ProductionConfiguration` | PASS |
| 22 | Deploy en Base sólo con suite limpia, dry-run, sin direcciones inventadas | Sí | `script/DeployForwarder.s.sol` | sección E | ver E |
| 23 | Verificación de source en Basescan | ver E | — | — | ver E |
| 24 | Auditoría post-deploy sobre la dirección real | ver E/F | `test/ForwarderPostDeployFork.t.sol` | P | ver F |

---

## D. Architecture / Trust Model

```text
 Usuario / CEX / otra chain
          │ fondos
          ▼
 ZeroDev SRA (smart account en Base) ── approve(Forwarder, amount) + forward(USDC, amount, recipient)
          │ transferFrom(amount)
          ▼
 Forwarder ── fee = calculateFee(amount)
          ├── usuario: deposit(amount-fee, recipient) en el vault ─(falla)→ USDC directo al recipient
          └── treasury: TODO el saldo USDC → deposit(balance, treasury) o transfer(treasury)   [best effort]
```

**Componentes de confianza.**

| Componente | Supuesto | Qué pasa si falla |
|---|---|---|
| Admin (`DEFAULT_ADMIN_ROLE`, Safe `0x420675DFAf02750a7DdFad702D13e32eb2C67602`) | Autoridad máxima: puede redirigir el treasury, cambiar el vault y el routing, rescatar todo el saldo del contrato y otorgar roles. Debe ser una multisig bien custodiada. | Un admin comprometido puede configurar un vault malicioso y capturar todos los depósitos futuros enrutados al vault y el saldo pendiente. **Hoy el Safe es 1-de-1** (hallazgo M-01). |
| `FEE_MANAGER_ROLE` (7 cuentas operativas) | Configurar fees dentro de los topes y pausarlas. | Un fee manager comprometido puede poner fees al máximo (10% + 10 USDC), cambiar el modelo/threshold (lo que puede hacer revertir depósitos chicos por `fee > amount`) o pausar fees. No puede despausar, ni mover fondos, ni tocar treasury/vault/routing/roles. Mitigación: cualquier fee manager o el admin pausan (fee 0) al instante; el admin revoca el rol. |
| USDC (FiatToken de Circle) | Token canónico, upgradeable por Circle; puede pausar o blacklistear cuentas. | USDC pausado o llamador blacklisteado ⇒ `forward` revierte (fondos quedan en la SRA). Usuario blacklisteado ⇒ revierte (no hay otra forma de entregarle USDC). Treasury blacklisteado ⇒ best-effort: queda pendiente, se cambia el treasury. |
| Vault ERC-4626 (LucaMoneyVault `0xc462cA16286a9a877a499f9474827bA801f2090D`) | **Dependencia de confianza.** Con allowance ilimitado mientras el routing lo usa, puede tomar cualquier USDC que el Forwarder tenga (por ejemplo fees pendientes). Debe cumplir ERC-4626 (tomar exactamente `assets`, emitir shares al `receiver`). | Si revierte: fallback al usuario / reintento al treasury. Si se vuelve malicioso o no conforme: compromete el camino que lo usa. Mitigación: el admin pasa a `DIRECT_DIRECT` (sin llamadas al vault y allowance 0) y/o reemplaza el vault. Configurarlo está reservado a la multisig. |
| Treasury (Safe 2/3 `0x7a5F8A4aF0FEDaBb1625b6f04bA38fC75e7E843e`) | Receptor de fees y rescates. | Si no puede recibir, los fondos quedan en el Forwarder hasta que el admin cambie el treasury. |
| ZeroDev SRA | **Fuera del trust directo del contrato.** `forward` es permissionless: cualquiera puede llamarlo con sus propios fondos y sólo puede afectar su propio depósito. | Si `forward` revierte, la SRA conserva los fondos (según la documentación de ZeroDev, quedan en la SRA hasta que el owner los retire). |

**Si los fees están pausados.** `calculateFee` devuelve 0 y el contrato se comporta como router puro; la pierna del
treasury sigue entregando cualquier saldo previo o donado.

**Integración ZeroDev.** La SRA ejecuta "actions" definidas con `createCall` y los placeholders `FLEX.TOKEN_ADDRESS`
y `FLEX.AMOUNT` (docs.zerodev.app, quickstart de Smart Routing Address). La integración esperada es
`[approve(Forwarder, FLEX.AMOUNT), forward(FLEX.TOKEN_ADDRESS, FLEX.AMOUNT, recipient)]`. No se encontró necesidad real
de whitelist de llamadores, por lo que no se agregó.

---

## E. Deployment

| Campo | Valor |
|---|---|
| Network | Base mainnet |
| chainId | 8453 |
| Contract address | `0xA7A2Be29D45F0cD465BF4F8775931bfb096d5647` |
| Deployment tx | `0x907a1d460133a7ec94718dab3c038ae0ce6cc5c6e3f89c20678426e44d8456dd` (status 1, gas 3.276.454) |
| Approve del health check (tx previa del deployer) | `0x00753c79db3ea7886ed39880389f0c9920919b0a7b29ff24d46e2931e908894e` (status 1, gas 55.425, `approve(0xA7A2…5647, 1000)`) |
| Block | 52.925.346 (ambas transacciones) |
| Gas price efectivo | 5.875.000 wei (0,005875 gwei) |
| Deployer | `0x18e129122a338f2e6871764fe0e4426dE848Ef99` (CM2, keystore `LucaDeployERC4626`; EOA con delegación EIP-7702 a `0x63c0c19a…E32b`) |
| Admin (`DEFAULT_ADMIN_ROLE`) | `0x420675DFAf02750a7DdFad702D13e32eb2C67602` (Safe v1.5.0, **threshold 1/1**, owner `0xa737…C5db`; ver M-01) |
| Admin delay | 259.200 s (3 días) |
| Treasury | `0x7a5F8A4aF0FEDaBb1625b6f04bA38fC75e7E843e` (Safe v1.4.1, 2/3) |
| Vault | `0xc462cA16286a9a877a499f9474827bA801f2090D` (LucaMoneyVault, asset USDC) |
| Routing inicial | `DIRECT_DIRECT` (0), elegido por el usuario; allowance al vault = 0 |
| Fee inicial | `NONE/NONE`, threshold 0, fixed 0, variable 0, no pausado (`calculateFee` = 0) |
| `FEE_MANAGER_ROLE` | `0xa737cB590c0F4d00D2140a429728681e1e74C5db` (MANAGEMENT_ROLE_1), `0x31B5aBcF044049daa96cDC387a44747a48a0ac62` (MM), `0x61D4d1Ab7eA7B3A54C7B2D646Eb8189faD7B1050` (OC), `0xa82a5201E630b40914bf4fed0B0b40180BCB93F7` (CM), `0xe3685F1C0652430e501B314b3035CB7Dd5b21c5f` (BB), `0x5aDF0B683B49217704eff3f85eda468651C50A48` (HM), `0x18e129122a338f2e6871764fe0e4426dE848Ef99` (CM2 = deployer) |
| Verification | **Verified** en Basescan (Etherscan v2), GUID `jkustthkvcskryayfduyjbhgjhuqimqlnpu4wtj4wqwfuikv37`, estado reconfirmado con `forge verify-check` |
| Explorer | https://basescan.org/address/0xa7a2be29d45f0cd465bf4f8775931bfb096d5647#code |
| Compiler | solc 0.8.30 (`v0.8.30+commit.73712a01`) |
| Optimizer | habilitado, 200 runs; via-IR deshabilitado |
| EVM target | `cancun` |
| OpenZeppelin | v5.7.0 (`cab19933c33c2ad1d4c7a84864a3601dddfd16f3`) |
| Runtime | 11.015 bytes, `keccak256(code) = 0x1bb9cfaa6638eb4bbf028291c5bda669de69b55686a2a38bf07d7f4a89949a19` |
| Costo del health check | 1 unidad de USDC (0,000001) para el deployer (84.759.159 → 84.759.158) |

**Constructor args (ABI)**:

```text
0x000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda02913000000000000000000000000420675dfaf02750a7ddfad702d13e32eb2c67602000000000000000000000000000000000000000000000000000000000003f4800000000000000000000000007a5f8a4af0fedabb1625b6f04ba38fc75e7e843e000000000000000000000000c462ca16286a9a877a499f9474827ba801f2090d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000007000000000000000000000000a737cb590c0f4d00d2140a429728681e1e74c5db00000000000000000000000031b5abcf044049daa96cdc387a44747a48a0ac6200000000000000000000000061d4d1ab7ea7b3a54c7b2d646eb8189fad7b1050000000000000000000000000a82a5201e630b40914bf4fed0b0b40180bcb93f7000000000000000000000000e3685f1c0652430e501b314b3035cb7dd5b21c5f0000000000000000000000005adf0b683b49217704eff3f85eda468651c50a4800000000000000000000000018e129122a338f2e6871764fe0e4426de848ef99
```

Decodificados: `(USDC, admin, 259200, treasury, vault, 0, [7 fee managers en el orden de la tabla])`.

**Procedimiento seguido.**

1. Dry-run contra Base (`forge script … --sender 0x18e1…Ef99`): preflight completo (chainId, código y metadata de USDC,
   admin y treasury con código, `vault.asset() == USDC`, sin duplicados, saldo de USDC del deployer), dirección predicha
   y verificación post-deploy simulada. Un primer intento falló por un estado inconsistente devuelto por el RPC dentro
   de Aave (I-09); el siguiente fue exitoso (`audit/raw/deploy/dry-run-run-latest.json`).
2. Broadcast + `--verify` con la keystore `LucaDeployERC4626` (la contraseña sólo se pasó como ruta a Foundry; nunca se
   leyó ni imprimió). Registro: `broadcast/DeployForwarder.s.sol/8453/run-latest.json`.
3. Comparaciones independientes (`audit/raw/deploy/`): input de la transacción on-chain == registro de forge ==
   bytecode de creación local (14.952 B) + args; argumentos decodificados == configuración de producción
   (`compare-deployment.txt`, `onchain-checks.txt`); configuración y roles leídos on-chain
   (`onchain-configuration.txt`).
4. `eth_call` de `forward(USDC, 0, 0x…dEaD)` contra un nodo real de Base: ejecuta sin error, lo que demuestra que el
   guard `nonReentrant` (TSTORE/TLOAD, EIP-1153) funciona en Base con este bytecode; `forward` con WETH revierte con
   `UnsupportedToken` (`0xbf16aab6`).

---

## F. Test Results

### F.1 Números

| Suite | Tests | Detalle |
|---|---|---|
| Unit (`Forwarder.t.sol`, `ForwarderRouting.t.sol`, `ForwarderVaultAndRescue.t.sol`) | 146 | 13 contratos de test (constructor 18, fees 21, roles 17, validación 11, routing 6, fallback 9, treasury 8, donaciones 4, ceros 6, allowances 6, setVault 18, rescue 13, reentrancy 9) |
| Fuzz (`ForwarderFuzz.t.sol`) | 13 | 1.000 runs por defecto; campaña profunda 50.000 runs cada uno (seed `0x4c756361`) |
| Invariantes (`ForwarderInvariant.t.sol`) | 12 | 256 runs × 64 de profundidad por defecto; campaña profunda 1.000 runs × 200 = 200.000 llamadas por invariante, 0 reverts, 13 acciones del handler |
| **Total local** | **171** | 171 pasan, 0 fallan |
| Fork Base, bloque pinneado 52.921.000 (`ForwarderForkTest`) | 26 | 26 pasan (75,7 s) |
| Fork Base, último bloque (`FORK_BLOCK=0`, bloque 52.923.449) | 26 | 26 pasan |
| Post-deploy sobre el contrato desplegado (`ForwarderPostDeployForkTest`, bloque 52.925.421) | 24 | 24 pasan |

### F.2 Coverage (`src/Forwarder.sol`)

| Líneas | Statements | Branches | Funciones |
|---|---|---|---|
| 100,00% (142/142) | 100,00% (167/167) | 100,00% (32/32) | 100,00% (24/24) |

No quedan líneas ni ramas sin cubrir. Evidencia: `audit/raw/forge/coverage/summary.txt` y `lcov.info`.

### F.3 Mutation testing (validación de la calidad de la suite)

16 mutantes dirigidos aplicados uno por uno sobre una copia del repositorio y ejecutados contra la suite local:
**16/16 detectados (KILLED)**.

| ID | Mutación | Detectado por (ejemplos) |
|---|---|---|
| M01 | `<=` → `<` en la selección por threshold | `test_ThresholdBoundaries`, `testFuzz_FeeAboveThresholdUsesFullAmount` |
| M02 | porcentaje sobre el excedente del threshold | `test_FeeUsesFullAmountAboveThreshold`, `testFuzz_CalculateFeeMatchesSpecification` |
| M03 | la pausa no anula la fee | `test_PausedFeeIsZero`, `testFuzz_PausedFeeIsZero` |
| M04 | tope de variable fee +1 | `test_RevertWhen_VariableFeeAboveMaximum`, `invariant_NoUnexpectedOutcome` |
| M05 | sin fallback tras falla del vault | `test_FallbackWhenDepositReverts`, `testFuzz_ForwardAccounting` |
| M06 | el fallback paga `amount` en vez de `amount - fee` | `test_DirectDirect`, `testFuzz_ForwardAccounting` |
| M07 | falla del treasury directo revierte | `test_DirectTreasuryTransferReverting`, `invariant_NoUnexpectedOutcome` |
| M08 | DIRECT_DIRECT mantiene el allowance | `test_EveryRoutingTransition`, `invariant_Allowances` |
| M09 | no se limpia el allowance del vault viejo | `test_VaultReplacementInVaultMode`, `invariant_Allowances` |
| M10 | rescue al `msg.sender` | `test_RescueUsdc`, `testFuzz_RescueSendsEverythingToTreasury` |
| M11 | fee manager puede despausar | `test_FeeManagerCannotUnpause` |
| M12 | fee manager puede cambiar el treasury | `test_FeeManagerAndStrangerCannotCallAdminFunctions`, `invariant_NoUnexpectedOutcome` |
| M13 | `forward` sin `nonReentrant` | `test_ForwardCannotBeReentered` y 5 más |
| M14 | health check devuelve un monto fijo | `test_HealthCheckNeverUsesForwarderFunds` |
| M15 | treasury recibe sólo la fee, no el saldo acumulado | `test_DonationIsSweptDirectly`, `testFuzz_ForwardAccounting` |
| M16 | treasury leído después de la pierna del usuario | `test_ForwardUsesConfigurationSnapshot` |

### F.4 Fork de Base mainnet

- Bloque pinneado: **52.921.000** (reproducible). El Forwarder se despliega en el fork con el **mismo script de
  producción** (`DeployForwarder.deploy(0x18e1…Ef99)`), con USDC real, LucaMoneyVault real y los Safes reales.
- Fallos reproducidos sólo con mecanismos reales: pausa de depósitos del vault por un guardian (`pauseDeposits`),
  blacklist de USDC por el blacklister de Circle, capacidad de Aave superada (`maxDeposit + 1`), allowance agotado.
- Vault de terceros real: Steakhouse USDC (`0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183`, MetaMorpho) aceptado por el
  health check y usado en VAULT_VAULT; Moonwell Flagship ETH (`0xa0E430870c4604CcfC7B38Ca7845B1FF653D0ff1`, asset WETH)
  rechazado.
- Observaciones reales: el health check sobre el LucaMoneyVault mintea 990.365.493.175.843 shares y devuelve **999** de
  1000 (1 unidad de redondeo; costo para quien llama: 0,000001 USDC). `deposit(0)` del LucaMoneyVault revierte (Aave
  rechaza montos cero) y el Forwarder cae correctamente al fallback.
- Gas medido en fork (primer forward, accesos fríos, fee FIXED_PLUS_PERCENT): DIRECT_DIRECT 89.550;
  VAULT_USER_DIRECT_TREASURY 374.129; DIRECT_USER_VAULT_TREASURY 246.097; VAULT_VAULT 416.050.

### F.5 Post-deploy

`ForwarderPostDeployForkTest` ejecuta **todos** los tests de `ForkTestBase` contra la dirección real desplegada, más
dos tests propios, en un fork de Base en el bloque **52.925.421** (posterior al deploy, 52.925.346):

```shell
DEPLOYED_FORWARDER=0xA7A2Be29D45F0cD465BF4F8775931bfb096d5647 POST_DEPLOY_FORK_BLOCK=52925421 \
  forge test --match-contract ForwarderPostDeployForkTest -vv
```

Resultado: **24 passed, 0 failed** (`audit/raw/fork/post-deploy-52925421.txt`). Cubre integración, control de acceso
(Safe admin real y los 7 fee managers reales), fees, pausa, los 4 routings con el LucaMoneyVault real, fallbacks y fallas
del treasury reproducidas con mecanismos reales, allowances con USDC real, health check, reemplazo por Steakhouse USDC,
rescate de USDC/USDbC/DAI/USDT/WETH/ETH hacia el Safe del treasury (todo en el fork, sin tocar mainnet), y:

- `test_PostDeploy_RuntimeCodeMatchesAuditedSource`: el runtime desplegado es **idéntico byte a byte** al del código
  auditado compilado localmente con los mismos argumentos (incluye el inmutable `USDC`).
- `test_PostDeploy_InitialConfiguration`: fees en cero, no pausado, sin transferencia de admin pendiente, routing y
  allowance iniciales.

No se hicieron transacciones experimentales en mainnet: además del deploy (2 transacciones) sólo hubo lecturas y
`eth_call`.

### F.6 Gas report y tamaño

Tamaño (`forge build --sizes`): runtime **11.015 B** (margen 13.561 B al límite EIP-170), initcode 14.952 B.

Gas report (`forge test --no-match-contract Fork --gas-report`, mocks): deployment 2.763.657 gas; `forward`
min 22.728 / promedio 102.211 / mediana 90.818 / máx 224.267; `setRoutingMode` mediana 31.484; `setFeeConfig` mediana
48.000; `setTreasury` mediana 31.041; `pause` mediana 29.966; `rescueToken` mediana 49.112; `rescueNative` mediana
37.328. Completo en `audit/raw/forge/gas-report.txt`.

### F.7 Comandos ejecutados

```shell
forge fmt --check
forge build --sizes
forge test --no-match-contract Fork
FOUNDRY_PROFILE=deep forge test --match-path test/ForwarderFuzz.t.sol
FOUNDRY_PROFILE=deep FOUNDRY_INVARIANT_SHOW_METRICS=true forge test --match-contract ForwarderInvariantTest
forge test --match-contract ForwarderForkTest -vv                      # bloque 52.921.000
FORK_BLOCK=0 forge test --match-contract ForwarderForkTest -vv         # último bloque
forge coverage --no-match-coverage "(test|script)/" --no-match-contract Fork --report summary --report lcov
forge test --no-match-contract Fork --gas-report
DEPLOYED_FORWARDER=<addr> POST_DEPLOY_FORK_BLOCK=<block> forge test --match-contract ForwarderPostDeployForkTest -vv
```

---

## G. Slither

Ejecutado con **Slither 0.11.6** (crytic-compile 0.4.2, 102 detectores; instalación aislada) y con **Slither 0.10.4**
(instalación del sistema, 93 detectores), filtrando `lib/|test/|script/|echidna/|certora/`. Salidas completas en
`audit/raw/slither/` (texto y JSON, más printers `human-summary`, `vars-and-auth`, `modifiers`, `require`,
`function-summary`). 0.11.6: 13 resultados; 0.10.4: 11 (los mismos menos `reentrancy-balance`, detector nuevo).

| ID | Detector | Severity | Confidence | Location | Análisis manual | Clasificación | Resolución |
|---|---|---|---|---|---|---|---|
| S-01 | `reentrancy-balance` | High | Medium | `_vaultHealthCheck` L417-L421 (shares) | Se lee `balanceOf` antes de `deposit` y se usa después: es la medición intencional del efecto de esa llamada. Reentrada bloqueada por `nonReentrant` en `setVault` (en el constructor el contrato todavía no tiene código). Lo que el candidato haga con sus propias shares sólo afecta lo que se redime y se devuelve al llamador. | False positive | Sin cambios. Tests `test_HealthCheckOnlyRedeemsNewShares`, `test_CandidateVault*` |
| S-02 | `reentrancy-balance` | High | Medium | `_vaultHealthCheck` L422-L424 (assets) | Mismo patrón con USDC alrededor de `redeem`. El saldo previo del Forwarder está protegido: el candidato sólo tiene allowance exacto de 1000 (que vino del llamador), el allowance del vault anterior se puso en 0 antes, y el reembolso `balance - usdcBefore` usa aritmética checked (si el saldo cayera por debajo del previo, revierte). | False positive | Sin cambios. `test_HealthCheckNeverUsesForwarderFunds`; Certora `healthCheckUsesOnlyCallerFunds` |
| S-03 | `incorrect-equality` | Medium | High | `_deliverToTreasury` L366 `balance == 0` | Igualdad sobre un saldo usada sólo para saltear una entrega vacía; manipularla (donar) sólo hace que se entregue más al treasury. | False positive | Sin cambios |
| S-04 | `incorrect-equality` | Medium | High | `_vaultHealthCheck` L420 `shares == 0` | Requisito de la especificación (emitir shares > 0). | False positive | Sin cambios |
| S-05 | `incorrect-equality` | Medium | High | `_vaultHealthCheck` L425 `assets == 0` | Requisito de la especificación (assets > 0). | False positive | Sin cambios |
| S-06 | `reentrancy-no-eth` | Medium | Medium | `_setVault`: escribe `vault` después del health check | Por diseño: el vault sólo se acepta después del round-trip, y si algo falla todo revierte (sin estados parciales). `setVault` y `setRoutingMode` (los únicos que leen `vault` para escribir allowances) son `nonReentrant`. | False positive | Sin cambios. `test_CandidateVaultCannotReenter*` |
| S-07 | `uninitialized-local` | Medium | Medium | `forward`: `userVaultDeposit` | Inicialización implícita a `false` intencional. | False positive | Sin cambios |
| S-08 | `uninitialized-local` | Medium | Medium | `forward`: `userShares` | Inicialización implícita a `0` intencional. | False positive | Sin cambios |
| S-09 | `unused-return` | Medium | Medium | `_vaultHealthCheck`: `candidate.deposit(...)` | Se ignora a propósito: se miden balances en vez de confiar en el valor devuelto por un candidato no confiable. | False positive / by design | Sin cambios |
| S-10 | `unused-return` | Medium | Medium | `_vaultHealthCheck`: `candidate.redeem(...)` | Idem. | False positive / by design | Sin cambios |
| S-11 | `reentrancy-events` | Low | Medium | `_setVault`: `VaultUpdated` después de llamadas externas | Debe emitirse después del health check (incluye sus resultados). Protegido por `nonReentrant`. | Informational | Sin cambios |
| S-12 | `low-level-calls` | Informational | High | `_deliverToTreasury` L370 | Intencional (B.10): garantiza que la pierna del treasury nunca revierta. | Informational | Documentado |
| S-13 | `naming-convention` | Informational | High | `USDC` inmutable | Nombre exigido por la especificación. | Informational | Sin cambios |

Conclusión: **0 true positives**. Además, el compilador emite la advertencia estándar sobre transient storage
(EIP-1153); el uso es el de OpenZeppelin para guardas de reentrancy que se limpian al final de cada llamada, que la
propia advertencia indica como seguro.

---

## H. Echidna

**Arnés:** `echidna/ForwarderEchidna.sol`. Despliega USDC mock (comportamiento FiatToken: descuenta allowance MAX,
blacklist, pausa), tres vaults ERC-4626 (el tercero siempre falla el health check), y actores como contratos reales
(`Actor`) para admin, dos fee managers, un extraño y la SRA, de modo que `msg.sender` es auténtico sin cheatcodes.
Cada acción verifica sus propias postcondiciones y cuenta violaciones; las propiedades exigen que esos contadores sigan
en cero y que se mantengan los invariantes estructurales.

**Acciones fuzzeadas (13):** `forward`, `donate`, `setFeeConfig` (incluye valores fuera de tope), `setVariableFee`,
`setFixedFee`, `pause` (admin o fee manager), `unpause`, `setRoutingMode`, `setVault` (vault sano o roto),
`setTreasury`, `toggleFailure` (depósito del vault revierte, vault pausado, receptor bloqueado, treasury blacklisteado,
transferencia que devuelve `false`), `rescueUsdc`, `unauthorizedCall` (14 funciones privilegiadas desde fee manager o
extraño).

**Propiedades (11):**

| Propiedad | Qué exige | Resultado |
|---|---|---|
| `echidna_no_unexpected_outcome` | Ningún revert inesperado, ningún éxito indebido (incluye toda llamada no autorizada) y ningún rescate mal dirigido | passing |
| `echidna_user_gets_amount_minus_fee` | El usuario recibe exactamente `amount - fee` (USDC + shares), incluso con fallos del vault o del treasury | passing |
| `echidna_treasury_accounting` | `entregado al treasury + saldo del Forwarder == saldo previo + fee` en cada `forward`; el health check no toca fondos del Forwarder | passing |
| `echidna_conservation` | `depositado + donado == recibido por usuarios + recibido por treasuries + saldo del Forwarder` y `depositado == recibido por usuarios + fees` | passing |
| `echidna_fee_caps` | `variableFee <= 10_000` y `fixedFee <= 10e6` | passing |
| `echidna_paused_means_zero_fee` | Pausado ⇒ fee 0 (también en cada `forward` ejecutado) | passing |
| `echidna_vault_mode_has_vault` | Modo vault ⇒ vault configurado | passing |
| `echidna_allowances` | Allowance exacto contra un modelo (incluye el descuento de USDC); 0 en DIRECT_DIRECT y en vaults no actuales | passing |
| `echidna_roles_never_change` | Admin y fee managers intactos; extraños y SRA sin roles; sin transferencia de admin pendiente | passing |
| `echidna_forwarder_holds_no_shares` | El Forwarder nunca retiene shares | passing |
| `echidna_treasury_valid` | Treasury nunca es 0 ni el propio Forwarder | passing |

**Configuración:** `echidna/echidna.yaml` — `testMode: property`, `testLimit: 500000`, `seqLen: 100`,
`shrinkLimit: 5000`, `seed: 1280263521`, senders `0x10000`/`0x20000`, solc 0.8.30 (`--evm-version cancun --optimize
--optimize-runs 200`).

**Resultado:** 500.223 llamadas (4 workers, 20 min 05 s), **11/11 propiedades passing, 0 contraejemplos**,
17.920 instrucciones únicas cubiertas, 5 codehashes. Log y cobertura: `audit/raw/echidna/`.

**Control de no-vacuidad:** las mismas propiedades se ejecutaron contra 5 mutantes del contrato (30.000 llamadas cada
uno): **5/5 detectados** — M05 (sin fallback), M08 (allowance en DIRECT_DIRECT), M10 (rescate a otro destino), M12
(fee manager cambia el treasury), M15 (treasury recibe sólo la fee y no el saldo acumulado). La primera versión del
arnés no detectaba M15 (sus propiedades de conservación no exigían el barrido completo); se agregó la condición "si
hubo entrega al treasury, el Forwarder queda en 0" en Echidna y en el handler de invariantes de Foundry, ambos pasaron
a detectarlo, y todas las campañas se re-ejecutaron con los arneses finales (`audit/raw/echidna/mutation-check.txt`).

---

## I. Certora Prover

Certora CLI 8.8.0, ejecutado en la nube de Certora con la `CERTORAKEY` del entorno. Archivos: `certora/specs/Forwarder.spec`,
`certora/harness/` (`ForwarderHarness` hereda el contrato y sólo agrega getters de lectura; `DummyUSDC`, `DummyVault`,
`DummyVault2` son modelos), `certora/conf/` (`Forwarder.conf` reglas; `ForwarderInvariants*.conf` invariantes).
Resultados crudos y diagnósticos: `audit/raw/certora/`.

### I.1 Modelo y supuestos

- **USDC** = `DummyUSDC`: balances, allowance que siempre se descuenta (como FiatToken), cuentas `blocked` cuyas
  transferencias revierten (blacklist).
- **SafeERC20**: sus llamadas se construyen en assembly y el prover no las resuelve (las trataría como llamadas
  desconocidas que pueden cambiar cualquier otro contrato). Sus funciones internas (`safeTransfer`, `safeTransferFrom`,
  `trySafeTransfer`, `forceApprove`) se resumen como la misma llamada ERC-20 hecha por el Forwarder sobre `DummyUSDC`;
  los reverts se propagan (o devuelven `false` en `trySafeTransfer`), igual que la librería real.
- **ERC-4626** = `DummyVault`/`DummyVault2`: 1:1, `deposit`/`redeem` pueden revertir (flags arbitrarios), así que cada
  regla cubre vault sano y vault que falla. Es el supuesto de vault de confianza; redondeos, caps y vaults reales se
  cubren en el fork.
- **`Address.sendValue`** (rescate nativo) se resume registrando destinatario y monto en ghosts.
- Reglas paramétricas e invariantes recorren los 22 métodos externos del Forwarder (incluidos los heredados de
  AccessControlDefaultAdminRules); cada regla parte de un estado arbitrario y de una transacción nueva (flag transitorio
  de reentrancy en 0).
- **Configuración del prover**: `-enableStorageSplitting false` (ver I.3), `precise_bitwise_ops` en reglas,
  `optimistic_loop` con `loop_iter 3`, `rule_sanity basic` (detecta reglas vacuas).

### I.2 Resultados (corrida final de los archivos versionados)

- Reglas: `certora/conf/Forwarder.conf`, job `3658204/3e6503ed995c441e8075f559b81b3f75` — **"No errors found by Prover!"**
  (42 reglas; 231 sub-chequeos verificados; todos los chequeos de no-vacuidad satisfechos).
- Invariantes: `certora/conf/ForwarderInvariants.conf`, job `3658204/79a63e178af844dea2a24082656b832c` —
  **"No errors found by Prover!"** (6 invariantes; caso base + 22 pasos inductivos cada una).

Los jobs pueden abrirse en `https://prover.certora.com/output/<job>` con la cuenta de Certora del equipo; resúmenes y
veredictos por sub-chequeo en `audit/raw/certora/final-*.summary.txt` y `final-*.verdicts.txt`.

| Regla | Objetivo | Resultado |
|---|---|---|

| Regla | Objetivo | Resultado |
|---|---|---|
| `pausedFeeIsZero` | pausado ⇒ fee 0 | PASS |
| `feeMatchesSpecification` | `calculateFee` = fórmula de la especificación para cualquier configuración almacenada; el único revert posible es el overflow de `amount * variableFee` | PASS |
| `fixedModelIsReachable`, `percentModelIsReachable`, `fixedPlusPercentModelIsReachable` | testigos (`satisfy`): cada modelo produce fee > 0 en algún estado; prueba que la regla anterior no es vacua para esos modelos | PASS (satisfechos) |
| `lowerModelUpToThreshold` | `amount <= threshold` usa `lowerFeeModel` | PASS |
| `upperModelAboveThreshold` | `amount > threshold` usa `upperFeeModel` | PASS |
| `percentUsesWholeAmount` | sobre el threshold, PERCENT cobra sobre el monto completo | PASS |
| `percentUsesWholeAmountIsNotTheExcessFee` | testigo: existe un caso donde la fee sobre el monto completo difiere de la fee sobre el excedente | PASS (satisfecho) |
| `settersRejectValuesAboveCaps` | `setVariableFee` revierte si > 10%; un fee manager siempre puede setear valores válidos | PASS |
| `fixedFeeSetterRejectsValuesAboveCap` | `setFixedFee` revierte si > 10 USDC; un fee manager siempre puede setear valores válidos | PASS |
| `feeMatchesSpecificationForAnyConfiguration` | igual que `feeMatchesSpecification` pero construyendo la configuración con `setFeeConfig` (montos < 2^200; el caso de overflow lo cubre `feeMatchesSpecification`) | PASS |
| `setFeeConfigStoresConfiguration` | `setFeeConfig` almacena exactamente la configuración pedida | PASS |
| `percentAboveThresholdUsesWholeAmount`, `percentAboveThresholdIsNotExcessFee` | monto completo tras configurar con `setFeeConfig` (+ testigo) | PASS |
| `fixedModelChargesAfterConfiguration`, `fixedPlusPercentModelChargesAfterConfiguration` | testigos tras configurar | PASS (satisfechos) |
| `onlyFeeManagerChangesFeeConfig` | sólo `FEE_MANAGER_ROLE` cambia modelos, threshold, fixed y variable fee | PASS (22/22 métodos) |
| `onlyAdminChangesTreasury` | sólo `DEFAULT_ADMIN_ROLE` cambia el treasury | PASS (22/22) |
| `onlyAdminChangesVault` | sólo `DEFAULT_ADMIN_ROLE` cambia el vault | PASS (22/22) |
| `onlyAdminChangesRoutingMode` | sólo `DEFAULT_ADMIN_ROLE` cambia el routing | PASS (22/22) |
| `onlyAdminUnpauses` | sólo `DEFAULT_ADMIN_ROLE` despausa | PASS (22/22) |
| `onlyPrivilegedPause` | sólo fee manager o admin pausan | PASS (22/22) |
| `feeManagerCannotAdminister` | un fee manager sin rol admin no cambia treasury, vault ni routing, ni despausa | PASS (22/22) |
| `unprivilegedChangesNoConfiguration` | una cuenta sin roles no cambia ninguna configuración | PASS (22/22) |
| `feeManagerRoleOnlyChangedByAdminOrSelf` | `FEE_MANAGER_ROLE` sólo cambia por el admin (grant/revoke) o por la propia cuenta (renounce) | PASS (22/22) |
| `routingModeAllowance` | `setRoutingMode`: MAX al pasar a modo vault, 0 al pasar a DIRECT_DIRECT, sin cambios si el uso del vault no cambia | PASS |
| `setVaultAllowances` | `setVault`: vault anterior en 0; nuevo en MAX o 0 según el routing | PASS |
| `healthCheckUsesOnlyCallerFunds` | el health check no usa USDC del Forwarder y devuelve todo al llamador (vault 1:1) | PASS |
| `forwardNeverApproves` | `forward` nunca aumenta el allowance al vault | PASS |
| `forwardUserReceivesAmountMinusFee` (+ `ForAnyConfiguration`) | el usuario recibe exactamente `amount - fee` (USDC o shares), con cualquier fee y cualquier routing, incluso si el vault falla | PASS / PASS |
| `forwardTreasuryAccounting` (+ `ForAnyConfiguration`) | el Forwarder queda en 0 o en `saldo previo + fee`; `treasury + Forwarder` crece exactamente en `fee` | PASS / PASS |
| `treasuryFailureNeverRevertsForward` (+ `ForAnyConfiguration`) | si el treasury no puede recibir (blacklist o vault que revierte), `forward` igual no revierte | PASS / PASS |
| `pausedForwardDeliversWholeAmount` (+ `ForAnyConfiguration`) | con fees pausadas el usuario recibe el monto completo | PASS / PASS |
| `forwardDoesNotChangeConfiguration` | `forward` no modifica configuración | PASS |
| `forwardOnlyAcceptsUsdc` | `forward` con otro token revierte | PASS |
| `rescueTokenOnlyToTreasury` | `rescueToken` deja el Forwarder en 0, el treasury recibe todo y nadie más cambia | PASS |
| `rescueNativeOnlyToTreasury` | `rescueNative` hace un único envío, al treasury, por todo el balance | PASS |
| `envfreeFuncsStaticCheck` | getters declarados `envfree` no dependen del entorno | PASS (31) |

Invariantes (inducción sobre los 22 métodos; caso base = constructor):

| Invariante | Objetivo | Resultado |
|---|---|---|
| `enumsAreValid` | los enums almacenados siempre son válidos | PASS (base + 22/22) |
| `feeCaps` | `variableFee <= 10%` y `fixedFee <= 10 USDC` siempre | PASS (base + 22/22) |
| `vaultModeHasVault` | modo vault ⇒ vault configurado | PASS (base + 22/22) |
| `treasuryIsValid` | treasury nunca 0 ni el propio Forwarder | PASS (base + 22/22) |
| `feeManagerAdminIsDefaultAdmin` | el admin de `FEE_MANAGER_ROLE` es siempre `DEFAULT_ADMIN_ROLE` | PASS (base + 22/22) |
| `directDirectMeansNoVaultAllowance` | DIRECT_DIRECT ⇒ allowance al vault = 0 | PASS (base + 22/22) |

### I.3 Historia de las corridas (sin ocultar fallas)

| Corrida | Configuración | Resultado | Diagnóstico |
|---|---|---|---|
| 1 (`3658204/db9c4122…`) | spec inicial | 15 reglas PASS; FAIL en reglas de balances/allowances y en reglas paramétricas | (a) llamadas en assembly de SafeERC20 no resueltas ⇒ el prover asumía cambios arbitrarios en USDC (`forwardNeverApproves` "fallaba" con el allowance subiendo); (b) reglas paramétricas aplicadas también a métodos de los modelos; (c) ver corrida 3. **Ningún contraejemplo correspondía a un defecto del contrato.** |
| diagnósticos (`audit/raw/certora/diagnostics/`) | reglas mínimas con estados concretos | con storage splitting el prover no alcanza `upperFeeModel = FIXED/PERCENT` | el análisis de storage splitting trata el slot 4 (`vault` + `routingMode` + `lowerFeeModel` + `upperFeeModel`, empaquetados) como un `address` y fuerza en 0 los bytes de los enums; las escrituras de enums ≠ 0 quedaban como rutas inviables |
| 3-4 | resúmenes de SafeERC20 + filtros + `precise_bitwise_ops`, con storage splitting | reglas PASS pero **vacuas para fees/routing ≠ 0** | no se cuentan como prueba; motivó la configuración final |
| 5 (`deef03dc…`, `81160b54…`) | `-enableStorageSplitting false` | 39/42 reglas PASS; 6/6 invariantes PASS con `precise_bitwise_ops` (sin él, 3 invariantes fallaban en setters de enums por sobre-aproximación de máscaras) | 2 reglas de setters fallaban porque el estado inicial arbitrario admite bytes de enum inválidos y Solidity hace `Panic(0x21)` al codificarlos en el evento: se agregó `requireInvariant enumsAreValid()` (invariante probada). 1 regla con contraejemplo que el propio prover marcó como espurio (imprecisión en la multiplicación no lineal del lado CVL): se acotó el monto a `< 2^200` |
| re-chequeos (`bd5c150e…` y siguiente) | idem | 4/4 PASS | confirmación de las correcciones anteriores |
| **final** (`3e6503ed…`, `79a63e17…`) | archivos versionados | **42/42 reglas y 6/6 invariantes PASS** | todos los testigos de alcanzabilidad satisfechos ⇒ las pruebas cubren todos los modelos de fee y routings |

### I.4 Lo que no se modela con Certora

- Comportamiento real de ERC-4626 (redondeos, caps, pausas, vaults de terceros): fork de Base (F.4/F.5).
- Reentrancy: las reglas modelan llamadas de primer nivel; la protección está probada con contratos reentrantes en
  `ForwarderReentrancyTest`.
- Ausencia de `delegatecall`/`selfdestruct`: propiedad de bytecode, cubierta por test y Slither.
- La implementación de SafeERC20/OpenZeppelin no se re-verifica: se modela su efecto.

---

## J. Findings

| ID | Severity | Title | Status | Impact | Evidence | Remediation |
|---|---|---|---|---|---|---|
| M-01 | Medium | El Safe admin es 1-de-1 y su único owner también es fee manager | **Open** (configuración externa; el usuario decidió desplegar y subir el threshold después) | Una sola clave (`0xa737cB590c0F4d00D2140a429728681e1e74C5db`) controla todo el poder de `DEFAULT_ADMIN_ROLE`: podría cambiar treasury, configurar un vault malicioso + routing de vault y capturar depósitos futuros, o rescatar el saldo pendiente. | On-chain: `getThreshold() = 1`, `getOwners() = [0xa737…C5db]`, Safe v1.5.0 | Agregar owners y subir el threshold del Safe `0x4206…7602` (no requiere redeploy: el admin es la dirección del Safe). Opcional: quitar `FEE_MANAGER_ROLE` a esa clave. |
| L-01 | Low | (Resuelto) `try/catch` en la pierna del treasury podía revertir una entrega exitosa al usuario | Resolved | Con un vault que devolviera datos malformados en `deposit`, el error de decodificación (no capturable por `try/catch`) habría revertido todo `forward` en `DIRECT_USER_VAULT_TREASURY`, violando el requisito 7. | Diseño inicial; `test_TreasuryLegNeverRevertsOnMalformedVaultReturn` | Llamada de bajo nivel + chequeo de ≥32 bytes (L368-L376). Regression test incluido. |
| L-02 | Low | Configuración inconsistente si un privilegiado reentrara durante `forward` | Resolved | Antes del cambio, `treasury` se leía después de las llamadas al vault; un admin reentrando (vía vault) podía cambiar el destino de la pierna del treasury a mitad de la operación. | `test_ForwardUsesConfigurationSnapshot`; mutante M16 | Snapshot de `routingMode`, `vault` y `treasury` antes de cualquier llamada externa (L208-L210). |
| L-03 | Low | Fees mal configuradas pueden hacer revertir depósitos chicos | Acknowledged (por especificación) | Con FIXED/FIXED_PLUS_PERCENT, `fee > amount` revierte por diseño (no clamp). Un fee manager (error o compromiso) puede hacer que depósitos menores a la fee queden en la SRA hasta corregir. | `test_RevertWhen_FeeAboveAmount` | Operativo: monitorear `FeeConfigUpdated`; cualquier fee manager o el admin puede pausar fees al instante (fee 0). |
| I-01 | Informational | `recipient == address(this)` y `treasury == address(this)` rechazados | Resolved (mejora de seguridad) | Sin el chequeo, un `recipient` mal configurado igual al Forwarder habría barrido los fondos del usuario al treasury; un treasury igual al Forwarder habría dejado los fondos sin salida. | `test_RevertWhen_RecipientIsForwarder`, `test_RevertWhen_TreasuryIsZeroOrForwarder` | Implementado (L201, L385). No cambia la funcionalidad pedida. |
| I-02 | Informational | El vault con allowance ilimitado puede tomar cualquier USDC del Forwarder | Acknowledged (trusted dependency) | Mientras el routing usa el vault, éste puede retirar fees pendientes o donaciones. | Sección D | Por especificación. Mitigación: `DIRECT_DIRECT` deja allowance 0; reemplazo del vault. |
| I-03 | Informational | USDC descuenta incluso el allowance MAX | Acknowledged | Tras depósitos, el allowance queda en `MAX - total depositado`; inagotable en la práctica. | `test_UsdcStyleAllowanceDecrementAndRefresh`; `test_Fork_AllowanceTransitionsWithRealUsdc` | Re-ejecutar `setVault` con el mismo vault lo restablece. Si se agotara, el usuario cae al fallback. |
| I-04 | Informational | Retorno malformado del vault en la pierna del usuario revierte `forward` | Acknowledged (decisión de diseño) | Con un vault no conforme los depósitos quedan en la SRA en vez de completarse. Evita pagar dos veces. | `test_UserLegRevertsWhenVaultReturnsMalformedData` | Trusted vault; mitigación `DIRECT_DIRECT`. |
| I-05 | Informational | Fees sin timelock | Acknowledged | Un fee manager puede subir la fee justo antes de un depósito (front-running) dentro de los topes (10% + 10 USDC). | Topes probados (C `feeCaps`) | Rol de confianza; monitoreo de `FeeConfigUpdated`. |
| I-06 | Informational | Varios fee managers son EOAs con delegación EIP-7702 | Acknowledged | `MM`, `OC`, `BB` y `CM2` delegan a `0x63c0c19a282a1B52b07dD5a65b58948A07DAE32B` (MetaMask DeleGator): sus permisos pueden extenderse a terceros mediante delegaciones del framework. | `cast code` on-chain | Revisar las delegaciones activas de esas cuentas. |
| I-07 | Informational | El saldo pendiente sigue al treasury vigente | Acknowledged | Si se cambia el treasury, lo pendiente va al nuevo en el próximo `forward`. | `test_PendingFundsGoToTheNewTreasury` | Documentado (NatSpec de `setTreasury`). |
| I-08 | Informational | Treasury vault: un depósito acumulado muy grande podría superar el `maxDeposit` del vault | Acknowledged | Las entregas fallarían hasta que el admin rescate o cambie de modo; sin pérdida de fondos. | `test_FallbackWhenDepositCapIsExceededWhileTreasuryDepositWorks` | `rescueToken(USDC)` o `DIRECT_*` para el treasury. |
| I-09 | Informational | Dry-run del deploy falló una vez por estado inconsistente del RPC | Resolved (operativo) | Simulación contra "latest" observó `block.timestamp` < `lastUpdateTimestamp` de Aave (panic 0x11 dentro de Aave). El estado on-chain era consistente; los tests contra el último bloque pasan. | `audit/raw/deploy/dry-run.txt` | Repetir la simulación antes de transmitir (ver E). |

No hay findings Critical ni High.

---

## K. Residual Risks

1. **Vault como trusted dependency**: un vault comprometido o no conforme afecta el camino que lo usa (y, por el allowance
   ilimitado, el saldo pendiente del Forwarder). Mitigación: `DIRECT_DIRECT` y reemplazo por la multisig.
2. **Multisig como autoridad máxima**, hoy con threshold 1/1 (M-01).
3. **Redondeo del ERC-4626**: el usuario y el treasury reciben shares cuyo valor puede ser 1-2 unidades menor a lo
   depositado por el redondeo del vault; el health check cuesta ~1 unidad al llamador.
4. **Entrega al treasury best-effort**: fondos pueden quedar retenidos en el Forwarder hasta un próximo `forward`,
   un rescate o un cambio de treasury/routing.
5. **Fee managers**: pueden cambiar fees sin timelock dentro de los topes y provocar reverts de depósitos chicos (L-03).
6. **USDC**: Circle puede pausar o blacklistear; un usuario blacklisteado no puede recibir y su depósito queda en la SRA.

---

## L. Deviations from requested specification

Ninguna desviación cambia el comportamiento funcional pedido. Se listan todas las diferencias de forma o agregados:

| ID | Diferencia | Motivo | Impacto funcional |
|---|---|---|---|
| L-D1 | Las direcciones de producción (admin, treasury, vault, 7 fee managers + deployer) están hardcodeadas en `script/ForwarderDeployConfig.sol` y se pasan al constructor, en vez de ser constantes literales dentro del contrato. | Testeabilidad con mocks, Echidna y Certora. **Confirmado por el usuario.** Todos los roles se otorgan en la única transacción de deploy. | Ninguno |
| L-D2 | `forward` calcula la fee antes del `transferFrom`. | Checks-effects-interactions; la tx es atómica. | Ninguno (mismo resultado) |
| L-D3 | El vault inicial del constructor pasa por el mismo health check, financiado por el deployer (que aprueba 0,001 USDC a la dirección predicha). | Consistencia: ningún vault se acepta sin round-trip real. | Ninguno |
| L-D4 | Setter atómico adicional `setFeeConfig`. | Evitar configuraciones intermedias entre transacciones. | Ninguno (mismos permisos y topes) |
| L-D5 | El admin no tiene setters de fee propios (debe otorgarse `FEE_MANAGER_ROLE`). | La especificación asigna los setters de fee al fee manager. | Ninguno |
| L-D6 | Chequeos `recipient != address(this)` y `treasury != address(this)`. | Mejora de seguridad (I-01). | Ninguno para usos válidos |
| L-D7 | Pierna del treasury en modo vault con llamada de bajo nivel en vez de `try/catch`. | Garantiza el requisito 7 incluso con retornos malformados (L-01). | Ninguno |
| L-D8 | Si el saldo a entregar al treasury es 0, no se llama al vault/USDC ni se emite evento. | Evita llamadas vacías y eventos de falla espurios (p. ej. vaults que rechazan `deposit(0)`). | Ninguno |
| L-D9 | Eventos de éxito adicionales (`TreasuryTransferred`, `TreasuryVaultDeposited`) y resultados del health check en `VaultUpdated`. | Trazabilidad y conciliación. | Ninguno |
| L-D10 | El health check devuelve al llamador todo el USDC neto (recuperado + lo que un vault no conforme no hubiera tomado), no sólo lo recuperado. | Nunca retener fondos del llamador. | Ninguno con vaults conformes |
| L-D11 | El deployer se agrega a `FEE_MANAGER_ROLE` sólo si no está ya en la lista. En el deploy real el deployer es CM2, que ya está, así que quedan 7 fee managers. | Pedido del usuario ("y el deployer"). | Ninguno |

---

## M. Final Assessment

1. **¿El contrato implementa exactamente el comportamiento solicitado?** Sí. Las diferencias de la sección L son de
   forma o agregados de seguridad/trazabilidad y no cambian el comportamiento pedido; la única de alcance
   (direcciones en el script de deploy en vez de constantes del contrato) fue confirmada por el usuario.
2. **¿Hay Critical findings abiertos?** No.
3. **¿Hay High findings abiertos?** No.
4. **¿Hay Medium findings abiertos?** Sí, uno: **M-01**, de configuración externa (el Safe admin es 1-de-1 y su owner
   también es fee manager). No es un defecto del contrato y se corrige en el Safe sin redeploy. El usuario decidió
   desplegar y subir el threshold después.
5. **¿Está listo para producción?** El contrato sí: implementado, probado (unit, fuzz, invariantes, Echidna, fork real,
   mutation testing), analizado (Slither, Certora — ver I), desplegado y verificado. Recomendación operativa fuerte:
   resolver M-01 (agregar owners y subir el threshold del Safe `0x4206…7602`) antes de cambiar el routing a un modo
   vault o de habilitar fees con volumen relevante.
6. **¿Qué riesgos residuales quedan?** Los de la sección K: vault como dependencia de confianza, multisig como
   autoridad máxima (hoy 1/1), redondeo del ERC-4626, entrega best-effort al treasury, fee managers sin timelock dentro
   de los topes y las facultades de Circle sobre USDC.
7. **¿El bytecode auditado coincide con el desplegado?** Sí. Input de creación on-chain = bytecode de creación
   compilado localmente desde `src/Forwarder.sol` (commit `1ef93c9`) + constructor args esperados; runtime on-chain
   idéntico byte a byte al de una instancia compilada y desplegada localmente con los mismos argumentos
   (`test_PostDeploy_RuntimeCodeMatchesAuditedSource`).
8. **¿El source está verificado?** Sí, en Basescan (`Pass - Verified`), con solc 0.8.30, optimizer 200, EVM cancun.
9. **¿Todos los tests finales pasan contra Base mainnet fork usando el deployment real?** Sí: 24/24 en el bloque
   52.925.421 (posterior al deploy).

---

## Reproducibility

| Herramienta | Versión |
|---|---|
| forge / cast / anvil | 1.5.1-stable (`b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2`) |
| solc | 0.8.30+commit.73712a01 |
| OpenZeppelin Contracts | v5.7.0 (`cab19933c33c2ad1d4c7a84864a3601dddfd16f3`) |
| forge-std | v1.12.0 (`7117c90c8cf6c68e5acce4f09a6b24715cea4de6`) |
| Slither | 0.11.6 (crytic-compile 0.4.2) y 0.10.4 (crytic-compile 0.3.7) |
| Echidna | 2.2.5 |
| Certora CLI | 8.8.0 (Java OpenJDK 21.0.10) |
| Python | 3.10.12 |
| Sistema | Linux 6.18 (WSL2) |

```shell
git clone <repo> && cd ForwarderWithFeeTaken && git checkout feature/forwarder
git submodule update --init --recursive
cp <.env con BASE_RPC_URL y ETHERSCAN_API_KEY> .env
forge build --sizes
forge test --no-match-contract Fork
FOUNDRY_PROFILE=deep forge test --no-match-contract Fork
forge test --match-contract ForwarderForkTest            # fork pinneado
FORK_BLOCK=0 forge test --match-contract ForwarderForkTest
forge coverage --no-match-coverage "(test|script)/" --no-match-contract Fork --report summary
slither . --filter-paths "lib/|test/|script/|echidna/|certora/"
SOLC_VERSION=0.8.30 echidna echidna/ForwarderEchidna.sol --contract ForwarderEchidna --config echidna/echidna.yaml
SOLC_VERSION=0.8.30 certoraRun certora/conf/Forwarder.conf            # 42 reglas
SOLC_VERSION=0.8.30 certoraRun certora/conf/ForwarderInvariants.conf  # 6 invariantes
forge script script/DeployForwarder.s.sol --rpc-url base --sender 0x18e129122a338f2e6871764fe0e4426dE848Ef99
forge verify-contract <address> src/Forwarder.sol:Forwarder --chain base --constructor-args <args> --watch
```
