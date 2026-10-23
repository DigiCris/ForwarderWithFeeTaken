# Forwarder V3 (versión final) — Informe de auditoría completa post-deploy

| | |
|---|---|
| Fecha | 2026-10-22 / 2026-10-23 |
| Rama | `feature/forwarder-v3-final` (desde `feature/forwarder-v2-vault-delay` @ `0699df7`, sin reescribir historia) |
| Baseline V2 | `src/Forwarder.sol` sha256 `2ddd2b60…3c3c`, desplegado en `0xCD09f43D738b10584CaBfb2f73C3adA29fc5AD53`, informe [`FINAL_AUDIT_REPORT_V2.md`](FINAL_AUDIT_REPORT_V2.md) (V1: [`FINAL_AUDIT_REPORT_V1.md`](FINAL_AUDIT_REPORT_V1.md)) |
| Código auditado | `src/Forwarder.sol` sha256 `22aeb8e536cabe68d5ba3005decb1f43179d38ffc261b032a14085432ffd3d6b` (commit `ae8cd1b`), idéntico al desplegado y verificado |
| V3 en Base | `0x66c101cb2617256EC61833B607e3F0d98e0C1968` (bloque 52.958.903) |
| Alcance | Cambio V2 → V3 (cooling de 72 h de la configuración global de fees y del treasury, overrides de fee por recipient, una línea de `forward`) y **auditoría completa del contrato desplegado** (lógica V1 + V2 + V3), no sólo del diff |
| Orden seguido | pre-deploy rápido (diff, fmt, build, unit, fork, fuzz liviano, dry-run) → deploy → verificación → auditoría completa post-deploy |
| Evidencia cruda | [`audit/raw/v3/`](raw/v3/) (V2 en `audit/raw/v2/`, V1 en `audit/raw/`) |
| Uso | V3 **sin tráfico real**: las SRA no se modificaron; conectarlas es decisión del owner (T) |

## A. Executive Summary

- **Cambio:** después del deploy, la configuración global de fees (`lowerFeeModel`, `upperFeeModel`, `threshold`,
  `fixedFee`, `variableFee`) sólo cambia con `proposeFeeConfig` → 72 h → `executeFeeConfigChange`, y el treasury sólo
  con `proposeTreasury` → 72 h → `executeTreasuryChange`. Ambos delays son constantes, sin setter ni bypass; los
  setters inmediatos de V2 (`setFeeConfig`, `setVariableFee`, `setFixedFee`, `setThreshold`, `setLowerFeeModel`,
  `setUpperFeeModel`, `setTreasury`) se eliminaron. Admin y guardians pueden cancelar ambas propuestas; los fee
  managers, también la de fees. Los fee managers pueden dar a un recipient un **override temporal** que sólo baja su
  fee: `forward` cobra `calculateFeeFor(recipient, amount)` = fee global, o con override activo los modelos y el
  threshold globales con `min(override, global)`. `pause()` sigue siendo inmediata (fee = 0).
- **Aislamiento:** en `forward` cambió **una sola línea** (`calculateFee(amount)` → `calculateFeeFor(recipient, amount)`).
  `calculateFee`, el ciclo del vault de V2, routing, health check, rescue, entrega best-effort, pausa, topes, modelos y
  constructor están **textualmente sin cambios**. `setFeeConfig` pasó a ser el helper privado `_setFeeConfig` con el
  **mismo cuerpo** (B).
- **Pre-deploy (código `ae8cd1b`):** fmt y build OK; **385/385** tests (266 de V1/V2 adaptados + 119 nuevos, con fuzz
  liviano de 1.000 runs); fork **39/39** (bloque fijo y último); dry-run OK.
- **Deploy:** `0x66c101cb2617256EC61833B607e3F0d98e0C1968`, tx `0x9e10d79e…c75a`, bloque 52.958.903, deployer CM2.
  Basescan **Pass - Verified**. Creation code idéntico al build local, source verificado idéntico (sha256), runtime
  idéntico al del source auditado (S).
- **Auditoría completa post-deploy (todo ejecutado sobre el código desplegado):**
  - Regresión final: **407/407** tests; fork **39/39** (fijo y último); **post-deploy fork contra la dirección real
    37/37**.
  - Fuzz profundo: **36 tests × 50.000 runs** (V1, V2 y V3).
  - Invariantes: **V3 16 × 500.000 llamadas**; V2 15 × 200.000; V1 12 × 200.000; 0 reverts.
  - Echidna: **V3 1.000.363 llamadas, 18/18**; harness V2 500.070, 19/19; harness V1 500.076, 11/11.
  - Certora (spec completa: V1 adaptada + V2 + V3): **142 chequeos, 137 PASS**, 0 reglas vacuas, 0 invariantes
    triviales. Las 3 comparaciones directas entre dos cálculos de fee terminan en TIMEOUT, una variante en UNKNOWN
    (error interno del prover) y el lema `a·x ≤ a·y` en FAIL **espurio** (sobreaproximación no lineal de Certora);
    esas propiedades quedan probadas por descomposición: reglas de Certora en PASS + lemas probados con Z3 en
    aritmética exacta (6/6). Ningún contraejemplo real (L).
  - Slither 0.11.6 / 0.10.4: **0 true positives**; 5 / 4 avisos nuevos, todos por diseño (M).
  - Mutation testing: **65/65 KILLED** (22 V2 + 43 V3).
  - Coverage de `src/Forwarder.sol`: **100 %** (líneas 211/211, statements 275/275, branches 59/59, funciones 29/29).
  - Gas: `forward` +2.320 gas respecto de V2.
  - Revisión manual propia y revisión manual independiente: sin defectos de código ni desvíos de los requisitos.
- **Findings:** **0 Critical, 0 High, 0 Medium de contrato**; 3 Low (de diseño, acknowledged) y 14 Informational (O).
  Resueltos respecto de versiones anteriores: fees sin timelock (V1 I-05) y "el delay sólo protege el vault" (V2
  I-V2-01).
- **Punto operativo clave:** las fees globales están en 0, así que hoy el único override posible es (0, 0), una
  exención total que seguiría vigente al activar las fees (I-V3-01). Además, toda propuesta madura que no se ejecute de
  inmediato debe cancelarse (L-V3-01) y los delays sólo protegen con monitoreo de eventos (Q).

---

## B. Diff V2 → V3

Diff completo: [`audit/raw/v3/diff/forwarder.diff`](raw/v3/diff/forwarder.diff) (+237 / −31 líneas en
`src/Forwarder.sol`), diff del script: [`script.diff`](raw/v3/diff/script.diff). Comparación función por función
(código y NatSpec por separado, con el renombre `setFeeConfig` → `_setFeeConfig`):
[`function-diff.md`](raw/v3/diff/function-diff.md) (`audit/scripts/function_diff.py`). Selectores y layout de storage:
[`selectors-and-storage.txt`](raw/v3/diff/selectors-and-storage.txt).

### B.1 Funciones

| Función | V2 | V3 | Código | Motivo |
|---|---|---|---|---|
| `forward` | 30 líneas | 30 líneas | **1 línea cambiada** | `calculateFee(amount)` → `calculateFeeFor(recipient, amount)`. El resto (orden, `transferFrom`, `userAmount`, entrega al usuario, fallback ERC-4626, evento `Forwarded`, entrega best-effort al treasury) es idéntico; NatSpec sin cambios |
| `calculateFee` | 11 | 11 | **sin cambios** | Sólo el `@notice` (ahora documenta que es la fee global) |
| `setFeeConfig` → `_setFeeConfig` | external `onlyRole(FEE_MANAGER_ROLE)` | private | **cuerpo idéntico** | Convertida en el helper privado que usa `executeFeeConfigChange`: misma validación de topes, mismas escrituras, mismo `_emitFeeConfig()`. Dejó de ser invocable desde afuera |
| `setVariableFee`, `setFixedFee`, `setThreshold`, `setLowerFeeModel`, `setUpperFeeModel` | external | — | **eliminadas** | Eran caminos inmediatos (bypass) |
| `setTreasury` | external | — | **eliminada** | Era el camino inmediato del treasury |
| `calculateFeeFor` | — | 14 | agregada | Fee efectiva del recipient (override) |
| `proposeFeeConfig` / `executeFeeConfigChange` / `cancelFeeConfigChange` | — | 25 / 8 / 12 | agregadas | Ciclo con delay de la config global |
| `setUserFeeOverride` | — | 26 | agregada | Overrides por recipient |
| `proposeTreasury` / `executeTreasuryChange` / `cancelTreasuryChange` | — | 9 / 10 / 11 | agregadas | Ciclo con delay del treasury |
| constructor, `pause`, `unpause`, `proposeVault`, `executeVaultChange`, `cancelVaultChange`, `setRoutingMode`, `rescueToken`, `rescueNative`, `_deliverToTreasury`, `_setTreasury`, `_setVault`, `_validateVault`, `_vaultHealthCheck`, `_setRoutingMode`, `_checkVariableFee`, `_checkFixedFee`, `_emitFeeConfig` | — | — | **sin cambios** (código y NatSpec) | — |

El diff textual de `forward`:

```diff
         if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient(recipient);

-        uint256 fee = calculateFee(amount);
+        uint256 fee = calculateFeeFor(recipient, amount);
         uint256 userAmount = amount - fee;
```

### B.2 Estado, constantes, eventos, errores, selectores

| Elemento | V3 |
|---|---|
| Constantes | `FEE_CHANGE_DELAY = 72 hours`, `TREASURY_CHANGE_DELAY = 72 hours` (259.200 s, en bytecode, sin setter) |
| Tipos | `struct PendingFeeConfig { FeeModel lowerFeeModel; FeeModel upperFeeModel; uint256 threshold; uint256 fixedFee; uint256 variableFee; uint256 executableAt; }`, `struct UserFeeOverride { uint256 fixedFee; uint256 variableFee; uint256 validUntil; }` |
| Estado nuevo | `pendingFeeConfig` (slots 10–14), `pendingTreasury` (15), `pendingTreasuryExecutableAt` (16), `userFeeOverrides` (17, mapping). Las 18 entradas de layout de V2 conservan slot y offset |
| Eventos nuevos | `FeeConfigChangeProposed(lower, upper, threshold, fixedFee, variableFee, executableAt, proposer)`, `FeeConfigChangeCancelled(address indexed cancelledBy)`, `TreasuryChangeProposed(address indexed currentTreasury, address indexed pendingTreasury, uint256 executableAt, address proposer)`, `TreasuryChangeCancelled(address indexed pendingTreasury, address indexed cancelledBy)`, `UserFeeOverrideSet(address indexed recipient, uint256 fixedFee, uint256 variableFee, uint256 validUntil, address setBy)`. La ejecución usa los eventos existentes `FeeConfigUpdated` y `TreasuryUpdated` |
| Errores nuevos | `FeeConfigChangeAlreadyPending(uint256)`, `NoPendingFeeConfigChange()`, `FeeConfigChangeDelayNotElapsed(uint256)`, `TreasuryChangeAlreadyPending(address)`, `NoPendingTreasuryChange()`, `TreasuryChangeDelayNotElapsed(uint256)`, `FeeOverrideExpiryNotInFuture(uint256)`, `FeeOverrideAboveGlobalFee(uint256,uint256)`, `ActiveFeeOverrideWorsened(address)` |
| Import | `Math` de OpenZeppelin (`Math.min`, función `internal pure`) |
| Selectores | 54 → 61: **7 eliminados** (`setFeeConfig`, `setFixedFee`, `setLowerFeeModel`, `setThreshold`, `setTreasury`, `setUpperFeeModel`, `setVariableFee`), 14 agregados, 47 sin cambios (mismo nombre y selector), 0 colisiones. Los selectores eliminados (y el `setVault` de V1) revierten on-chain incluso llamados por la Safe admin (`audit/raw/v3/deploy/onchain-checks.txt`) |
| Tamaño | runtime 14.330 bytes (V2: 11.965; límite 24.576); creation 18.483 bytes |
| Constructor | **sin cambios** (mismos 8 parámetros; las fees arrancan en 0/NONE y el treasury inicial se fija sin delay, como en V2) |

### B.3 Revisión del diff (pre-deploy)

Antes del deploy se revisó el diff completo (no sólo el texto: también la comparación por función). Puntos verificados:
única línea cambiada en `forward`; cuerpo de `_setFeeConfig` idéntico al de `setFeeConfig`; ninguna función V2 del
vault/routing/rescue/best-effort cambió; escrituras de fees sólo en `_setFeeConfig` (llamada sólo por
`executeFeeConfigChange`) y del treasury sólo en `_setTreasury` (constructor y `executeTreasuryChange`), confirmado
después con el printer `vars-and-auth` de Slither (M).

---

## C. Global Fee Cooling

| Elemento | Comportamiento |
|---|---|
| `proposeFeeConfig(lower, upper, threshold, fixedFee, variableFee)` | `FEE_MANAGER_ROLE`. Revierte si hay propuesta (`FeeConfigChangeAlreadyPending`, también si ya maduró: no hay overwrite). Valida los topes actuales (`fixedFee ≤ 10 USDC`, `variableFee ≤ 10 %`; enums por el decoder ABI). Guarda la configuración **completa** y `executableAt = block.timestamp + 72 h`. No toca la configuración activa. Emite `FeeConfigChangeProposed` |
| `executeFeeConfigChange()` | `FEE_MANAGER_ROLE`. Revierte sin propuesta (`NoPendingFeeConfigChange`) o si `block.timestamp < executableAt` (`FeeConfigChangeDelayNotElapsed`). Copia la propuesta a memoria, **borra el pending** y aplica con `_setFeeConfig` (misma validación y escrituras de V2, evento `FeeConfigUpdated` con la configuración completa) |
| `cancelFeeConfigChange()` | `DEFAULT_ADMIN_ROLE`, `VAULT_GUARDIAN_ROLE` o cualquier `FEE_MANAGER_ROLE`. Exige propuesta; la borra (todos los campos a 0); emite `FeeConfigChangeCancelled`. Sin límite temporal (antes o después de madurar) |
| Clasificación de cambios | **No existe**: todo cambio (suba o baja) pasa por el delay, como se pidió |
| Admin | No puede proponer ni ejecutar sin `FEE_MANAGER_ROLE`; si se lo otorga, el delay le aplica igual (`test_AdminWithFeeManagerRoleStillWaitsTheDelay`) |
| Pausa | `pause()` inmediata (fee = 0) sin cambios. Se puede proponer y ejecutar con fees pausadas: la configuración se guarda pero la fee sigue en 0 hasta `unpause()` |

```text
ACTIVA(c) --proposeFeeConfig(p)--> ACTIVA(c) + PENDING(p, t+72h)
  PENDING --cancelFeeConfigChange (admin/guardian/fee manager, cualquier momento)--> ACTIVA(c), sin pending
  PENDING --executeFeeConfigChange (fee manager, now >= t+72h)--> ACTIVA(p), sin pending
  PENDING --executeFeeConfigChange (now < t+72h)--> revert FeeConfigChangeDelayNotElapsed
  PENDING --proposeFeeConfig--> revert FeeConfigChangeAlreadyPending
```

---

## D. Treasury Cooling

| Elemento | Comportamiento |
|---|---|
| `proposeTreasury(newTreasury)` | `DEFAULT_ADMIN_ROLE`. Revierte si hay propuesta (`TreasuryChangeAlreadyPending`); valida igual que V2 (`≠ 0`, `≠ Forwarder`, `InvalidTreasury`). Guarda `pendingTreasury` y `executableAt = now + 72 h`. No toca el treasury activo. Emite `TreasuryChangeProposed(current, pending, executableAt, proposer)` |
| `executeTreasuryChange()` | `DEFAULT_ADMIN_ROLE`. Revierte sin propuesta o antes de `executableAt`. Borra el pending y llama `_setTreasury` (sin cambios: re-valida y emite `TreasuryUpdated`). No toca nada más |
| `cancelTreasuryChange()` | `DEFAULT_ADMIN_ROLE` o `VAULT_GUARDIAN_ROLE`, cualquier momento. Borra el pending, emite `TreasuryChangeCancelled`. No modifica el treasury activo |
| Fondos mientras está pendiente | `forward` y `rescueToken`/`rescueNative` leen `treasury` (activo): el treasury pendiente **nunca recibe fondos por estar pendiente**. El saldo retenido (treasury que no puede recibir) llega al treasury nuevo recién con el primer `forward` posterior a la ejecución (comportamiento V2, I-07 de V1) |
| Constructor | Fija el treasury inicial sin delay (sin cambios) |

```text
ACTIVO(t) --proposeTreasury(n)--> ACTIVO(t) + PENDING(n, x+72h)
  PENDING --cancelTreasuryChange (admin/guardian, cualquier momento)--> ACTIVO(t), sin pending
  PENDING --executeTreasuryChange (admin, now >= x+72h)--> ACTIVO(n), sin pending
  PENDING --executeTreasuryChange (now < x+72h)--> revert TreasuryChangeDelayNotElapsed
  PENDING --proposeTreasury--> revert TreasuryChangeAlreadyPending
```

---

## E. User Fee Overrides

| Elemento | Comportamiento |
|---|---|
| Identificación | El `recipient` de `forward(token, amount, recipient)` (el Kernel/destino del usuario) |
| Estado | `mapping(address recipient => UserFeeOverride) public userFeeOverrides` con `fixedFee`, `variableFee`, `validUntil`. Sin threshold ni modelos por usuario |
| `setUserFeeOverride(recipient, fixedFee, variableFee, validUntil)` | `FEE_MANAGER_ROLE`. Exige `recipient ≠ 0` (`ZeroAddress`), `validUntil > now` (`FeeOverrideExpiryNotInFuture`) y ambos valores `≤` la configuración global **activa** (no la pendiente) (`FeeOverrideAboveGlobalFee`). Si hay un override **activo** exige además `fixed ≤ actual`, `variable ≤ actual` y `validUntil ≥ actual` (`ActiveFeeOverrideWorsened`). Emite `UserFeeOverrideSet` |
| Vigencia | Activo sólo si `block.timestamp < validUntil`. En `validUntil` exacto ya expiró; sin transacción ni borrado: el cálculo simplemente lo ignora (los datos quedan en el mapping) |
| Garantía | Mientras está activo no puede subirse, acortarse ni eliminarse (no existe función de borrado). Sí bajarse y/o extenderse. Vencido, puede reemplazarse libremente |
| `calculateFeeFor(recipient, amount)` | Sin override activo: `return calculateFee(amount)` (literal, mismo resultado y mismas reversiones). Con override activo: si `paused()` → 0; modelo global según `amount ≤ threshold` global; `fixed = min(override.fixed, global.fixed)`, `variable = min(override.variable, global.variable)`; mismas fórmulas V2 (porcentaje redondeado hacia abajo, aplicado al monto completo) |
| `calculateFee(amount)` | Sin cambios: la fee global/default |

**Por qué el override nunca cobra más que la fee global actual:** para cada uno de los 4 modelos la fórmula es no
decreciente en `fixed` y en `variable` (`NONE` = 0; `FIXED` = fixed; `PERCENT` = ⌊amount·variable/100000⌋;
`FIXED_PLUS_PERCENT` = fixed + ⌊amount·variable/100000⌋), y la fee efectiva usa el mismo modelo con valores
`≤` los globales. El `min()` en runtime hace que valga aunque la configuración global baje después de crear el
override. Probado con unit, fuzz (50k), invariantes, Echidna y Certora (`effectiveFeeNeverExceedsGlobalFee`,
`effectiveFeeFollowsLaterGlobalChanges`).

**Ejemplo de la especificación** (`test_TheUserNeverPaysMoreThanTheCurrentGlobalFee`): global 1 USDC + 1 %, usuario
0,20 + 0,30 % → paga 0,20 + 0,30 %; el global baja a 0,10 + 0,20 % → paga 0,10 + 0,20 %; el global vuelve a 1 + 1 % →
paga otra vez 0,20 + 0,30 % mientras el override siga vigente.

**Consecuencias de diseño (documentadas en O):** la garantía es sobre los parámetros `fixed`/`variable`; el modelo y
el threshold siguen siendo globales y un cambio de modelo (con su delay de 72 h) puede cambiar qué fórmula aplica
(I-V3-01). Extender un override activo cuando el global bajó por debajo de él exige bajarlo al global (validación
contra la configuración activa; nunca empeora al usuario) (I-V3-03). Un override es irrevocable hasta su `validUntil`,
que no tiene tope (L-V3-02).

---

## F. Vault V2 Regression

**Código:** `proposeVault`, `executeVaultChange`, `cancelVaultChange`, `_setVault`, `_validateVault`,
`_vaultHealthCheck`, `setRoutingMode`, `_setRoutingMode`, `rescueToken`, `rescueNative`, `_deliverToTreasury` y el
constructor están **textualmente sin cambios** (código y NatSpec, `function-diff.md`). Lo único del ciclo del vault que
tocó V3 es la línea de `forward` que elige la fee (B.1); el comportamiento del vault durante `forward` es el mismo.

| Herramienta | Ejecución sobre V3 | Resultado |
|---|---|---|
| Unit V2 (`ForwarderVaultChange.t.sol`, 65 tests; `ForwarderVaultAndRescue.t.sol`; `ForwarderRouting.t.sol`) | suites V2 completas; sólo se adaptaron helpers que usaban `setTreasury`/`setFeeConfig` y se reforzó `_configHash` para exigir que el ciclo del vault no toque tampoco los pending de fees/treasury | PASS (en los 407/407) |
| Fuzz V2 (`ForwarderVaultChangeFuzz.t.sol`) | 10 tests × 50.000 runs | PASS |
| Invariantes V2 (`ForwarderVaultChangeInvariant.t.sol`) | 15 × 200.000 llamadas (1.000 runs × 200) | PASS, 0 reverts |
| Echidna V2 (`ForwarderVaultChangeEchidna.sol`) | 500.070 llamadas, 19 propiedades; acciones de fees/treasury reescritas al ciclo con delay e intercaladas con el del vault | 19/19 passing |
| Certora | las 26 reglas y 4 invariantes del ciclo del vault de V2, re-ejecutadas sobre V3 (job Vault e Invariants); `guardianRoleChangesKeepPendingChange`, `vaultLifecycleKeepsConfiguration` y `forwardKeepsPendingChange` ampliadas a los pending de V3 | PASS |
| Mutation | M01–M22 (mutantes V2) contra la suite V3 | 22/22 KILLED |
| Fork | ciclo del vault con vaults reales (Steakhouse, Luca), health checks, allowances, routing mientras está pending; nuevo `test_Fork_VaultFeeAndTreasuryChangesPendingTogether` (los tres delays en paralelo, ninguno ejecutable antes) | PASS (pinned, latest y post-deploy) |

---

## G. Access Control / Trust Model

### G.1 Quién puede qué

| Función | Admin (`DEFAULT_ADMIN_ROLE`) | Fee manager | Guardian (`VAULT_GUARDIAN_ROLE`) | Cualquiera |
|---|---|---|---|---|
| `forward` | ✓ | ✓ | ✓ | ✓ (con sus propios fondos) |
| `proposeVault` / `executeVaultChange` (72 h) | ✓ | — | — | — |
| `cancelVaultChange` | ✓ | — | ✓ | — |
| `proposeFeeConfig` / `executeFeeConfigChange` (72 h) | sólo si también tiene `FEE_MANAGER_ROLE` | ✓ | — | — |
| `cancelFeeConfigChange` | ✓ | ✓ | ✓ | — |
| `proposeTreasury` / `executeTreasuryChange` (72 h) | ✓ | — | — | — |
| `cancelTreasuryChange` | ✓ | — | ✓ | — |
| `setUserFeeOverride` (sólo ≤ global, irrevocable hasta `validUntil`) | sólo con `FEE_MANAGER_ROLE` | ✓ | — | — |
| `pause` (inmediata, fee = 0) | ✓ | ✓ | — | — |
| `unpause` | ✓ | — | — | — |
| `setRoutingMode` (inmediato, sobre el vault **activo**) | ✓ | — | — | — |
| `rescueToken` / `rescueNative` (al treasury **activo**) | ✓ | — | — | — |
| `grantRole` / `revokeRole` (fee manager, guardian) | ✓ | — | — | — |
| transferencia del admin (`beginDefaultAdminTransfer`, delay 3 días) | ✓ | — | — | — |
| `renounceRole` (propio) | ✓ | ✓ | ✓ | — |

`VAULT_GUARDIAN_ROLE` conserva el nombre de V2 por compatibilidad y diff mínimo, aunque su poder de veto ahora abarca
también la configuración de fees y el treasury. No puede proponer, ejecutar, modificar fees ni treasury, hacer rescue,
cambiar routing ni hacer unpause (probado: `test_GuardianHasNoOtherPower`, `testFuzz_AccessControlOfTheNewFunctions`,
Certora `guardianCanOnlyCancel`, mutantes M05/M06/N26/N31/N32).

En producción las 7 wallets de management son a la vez fee managers y guardians (I-V2-05): una sola clave comprometida
de esas tiene ambos conjuntos de poderes. La Safe admin es 1/1 (decisión operativa intencional, V2).

### G.2 Compromiso del admin

| Puede de inmediato | No puede |
|---|---|
| administrar roles (otorgarse `FEE_MANAGER_ROLE`, revocar guardians y fee managers), iniciar la transferencia del admin (3 días) | activar un vault nuevo antes de 72 h |
| `rescueToken` / `rescueNative` — siempre al treasury **activo** (el de Luca) | activar un treasury nuevo antes de 72 h |
| `setRoutingMode` entre los modos del vault **activo** (ya validado) | cambiar la configuración global de fees antes de 72 h (ni siquiera otorgándose el rol) |
| `pause` / `unpause` (unpause sólo restablece la configuración **activa**, que no pudo cambiar sin delay) | crear un override que cobre más que la fee global |
| proponer vault y treasury (y, con el rol, fees); con el rol, crear overrides (sólo descuentos) | |

Escenario de captura: revocar guardians, proponer treasury propio + fees máximas (10 % + 10 USDC) y/o un vault
malicioso. Nada de eso se activa antes de 72 h; durante ese plazo quedan eventos (`RoleRevoked`,
`TreasuryChangeProposed`, `FeeConfigChangeProposed`, `VaultChangeProposed`) que deben disparar la respuesta: cancelar
(si queda algún guardian) y, sobre todo, **cortar el flujo de las SRA** hacia este Forwarder antes de `executableAt`.

### G.3 Compromiso de un fee manager

| Puede | No puede |
|---|---|
| proponer una configuración global dentro de los topes (efectiva recién a las 72 h, cancelable por admin, guardians y cualquier otro fee manager) | subir las fees globales de inmediato |
| ejecutar una propuesta ya madura (de cualquier fee manager) | cobrar más que la fee global con un override |
| crear overrides de descuento válidos (≤ global); irrevocables hasta `validUntil` (L-V3-02) | cambiar treasury, vault, routing; rescue; unpause; roles |
| `pause()` (fee = 0; el admin puede despausar) | |
| cancelar propuestas de fees (griefing; si además es guardian, también de vault y treasury) | |

Un fee manager solo **no puede desviar fondos**: las fees van al treasury activo (de Luca). Su impacto máximo es
económico: cobrar de más (sólo después de 72 h y dentro de los topes) o de menos (descuentos/pausa).

### G.4 Compromiso de un guardian

Sólo puede cancelar propuestas pendientes (griefing: demorar cambios). No mueve fondos ni cambia configuración.
El admin lo revoca (L-V3-03).

### G.5 Sin camino de upgrade

Sin proxy, sin `delegatecall`, sin `selfdestruct` en el runtime (`test_RuntimeCodeHasNoDelegatecallOrSelfdestruct`),
sin setters de los delays. El código desplegado es el auditado (S).

---

## H. Unit / Integration

### H.1 Pre-deploy (código `ae8cd1b`, idéntico al desplegado)

| Paso | Resultado | Evidencia |
|---|---|---|
| Revisión del diff | sin errores evidentes (B.3) | `diff/` |
| `forge fmt --check` | OK | `predeploy/fmt-build.txt` |
| Build | OK; el contrato compila sin warnings (los warnings son de tests/mocks heredados) | `predeploy/fmt-build.txt` |
| Unit + fuzz liviano + invariantes (perfil default) | **385/385** (28 suites): 266 de las suites V1/V2 adaptadas + 119 nuevos (36 fee cooling, 34 treasury cooling, 41 overrides, 8 fuzz V3 × 1.000 runs) | `predeploy/unit.txt` |
| Fork Base (USDC real, Luca Vault, Safes reales, deploy con el script de producción) | **39/39** en el bloque 52.951.000 y **39/39** en 52.958.414 (latest) | `predeploy/fork-*.txt` |
| Dry-run del deploy | OK (ver R: un primer intento de simulación con el panic de Aave) | `predeploy/dry-run*.txt` |

### H.2 Post-deploy (regresión final, HEAD con todos los tests)

| Suite | Resultado | Evidencia |
|---|---|---|
| Unit + fuzz + invariantes (perfil default) | **407/407** (29 suites: las 385 + 5 fuzz de máquinas de estado V3 + 17 de la campaña de invariantes V3) | `final/unit.txt` |
| Fork pinned | **39/39** (bloque 52.951.000) | `final/fork-pinned-52951000.txt` |
| Fork latest | **39/39** (bloque 52.969.621) | `final/fork-latest.txt` |
| Post-deploy fork contra `0x66c1…1968` | **37/37** inmediatamente después del deploy (bloque 52.959.267) y **37/37** al final (bloque 52.969.649), incluye `test_PostDeploy_RuntimeCodeMatchesAuditedSource` y `test_PostDeploy_InitialConfiguration` | `fork/post-deploy-52959267.txt`, `final/post-deploy-52969649.txt` |

**Tests nuevos (sección 30 del pedido):** `test/ForwarderFeeChange.t.sol` (36), `test/ForwarderTreasuryChange.t.sol`
(34), `test/ForwarderFeeOverride.t.sol` (41) y `test/ForwarderV3Fuzz.t.sol` (13). Cubren cada ítem de la lista del
pedido (mapa completo en [`TEST_MATRIX.md`](TEST_MATRIX.md)), incluidos: T−1 / T exacto / T+, quién puede proponer,
ejecutar y cancelar, cancelación antes y después de madurar, las 16 combinaciones globales con `forward` real,
rescue antes del execute al treasury **actual**, el ejemplo numérico del override, borde de expiración, pausa con
override, y la regresión de `forward` sin override (idéntica a V2), con override (`amount − discountedFee` al usuario,
`discountedFee` al treasury) en los cuatro modos, best-effort del treasury y fallback del vault.

**Fork nuevos:** `test_Fork_FeeConfigChangeLifecycle`, `test_Fork_TreasuryChangeLifecycle`,
`test_Fork_GuardianCancelsFeeAndTreasuryChanges`, `test_Fork_UserFeeOverrideWithRealUsdcAndVault`,
`test_Fork_VaultFeeAndTreasuryChangesPendingTogether`, más las verificaciones de configuración (delays, pending
vacíos). Corren también contra la dirección desplegada.

**Adaptaciones de suites existentes:** los helpers `_setFees` / `_fees` pasan por propose → 72 h → execute y
`_setTreasury` por el ciclo del treasury; las listas de llamadas no autorizadas usan las funciones nuevas; los
handlers de invariantes y Echidna ejecutan los ciclos completos. En fork, avanzar 72 h hace que el primer depósito en el
Luca Vault acuñe sus fee shares de performance a la Safe del treasury (`YieldAccrued`, el treasury es su fee
recipient); el helper de fork dispara esa acumulación antes de medir saldos del treasury. Es un efecto del vault real
sobre la medición del test, no del Forwarder.

---

## I. Fuzz

| Campaña | Tests | Runs | Resultado | Evidencia |
|---|---|---|---|---|
| Pre-deploy (liviano) | 8 tests V3 (delays de fees y treasury, overrides, accounting) | 1.000 c/u | PASS | `predeploy/unit.txt` |
| Deep (post-deploy) | **36**: 13 V1 (`ForwarderFuzz`), 10 V2 (`ForwarderVaultChangeFuzz`), 13 V3 (`ForwarderV3Fuzz`) | **50.000 c/u** (seed fija `0x4c756361`) | 36/36 PASS (564 s) | `forge/fuzz-deep.txt` |

Fuzz V3 profundo, por tema:

- **Máquina de estados de fees** (`testFuzz_FeeLifecycleStateMachine`, 16 operaciones por run): propose / execute /
  cancel por 5 tipos de llamador, saltos de tiempo a `executableAt − 1`, `executableAt` y aleatorios, pausa; modelo
  de referencia de configuración activa y pendiente en cada paso.
- **Máquina de estados del treasury** (`testFuzz_TreasuryLifecycleStateMachine`): igual, con `forward` y rescates
  intercalados; los fondos sólo llegan al treasury activo.
- **Overrides con cambios globales** (`testFuzz_OverrideLifecycleWithGlobalChanges`): overrides, cambios de la
  configuración global, tiempo y pausa intercalados; en cada paso fee ≤ global, fee = especificación, pausa = 0 y la
  promesa activa nunca empeora. `testFuzz_OverrideUpdateRule`: regla exacta de aceptación de un segundo override.
- **Timestamps:** `testFuzz_ExecutableAtBoundariesAtAnyTime` (cualquier tiempo absoluto hasta 2^64),
  `testFuzz_FeeConfigChangesOnlyAfterTheDelay`, `testFuzz_TreasuryChangesOnlyAfterTheDelay`.
- **Access control:** `testFuzz_AccessControlOfTheNewFunctions` (cualquier dirección × 7 funciones nuevas).
- **Accounting:** `testFuzz_ForwardAccountingWithTheEffectiveFee`: `amount = userAmount + effectiveFee` y entregas
  exactas con y sin override, override vencido, configuración global aleatoria, pausa y los 4 modos de routing.
- `testFuzz_ActiveOverrideNeverExceedsTheGlobalFee`, `testFuzz_ExpiredOverrideIsTheGlobalFee`,
  `testFuzz_WithoutOverrideTheFeeIsTheGlobalFee`, `testFuzz_CancellationsKeepTheActiveConfiguration`.

---

## J. Invariants

| Suite | Invariantes | Profundidad | Resultado | Evidencia |
|---|---|---|---|---|
| **V3** (`ForwarderV3Invariant.t.sol` + `FeeTreasuryHandler`) | 16 | 2.000 runs × 250 = **500.000 llamadas por invariante** (8.000.000 en total) | 16/16 PASS, 0 reverts (45 min) | `forge/invariant-v3-deep.txt` |
| V2 (`ForwarderVaultChangeInvariant.t.sol`) | 15 | 1.000 × 200 = 200.000 c/u | 15/15 PASS | `forge/invariant-v2-deep.txt` |
| V1 (`ForwarderInvariant.t.sol`, handler adaptado a los ciclos con delay y a `calculateFeeFor`) | 12 | 1.000 × 200 = 200.000 c/u | 12/12 PASS | `forge/invariant-v1-deep.txt` |

El handler V3 tiene 15 acciones (propose/execute/cancel de fees y treasury por 7 actores — admin, fee manager, fee
manager + guardian como en producción, 2 guardians, 2 strangers —, overrides válidos/empeorados/sobre el global,
warps a cada borde, `forward` en los 4 modos, donaciones, rescue, pausa, routing, fallas de treasury y del vault,
llamadas no autorizadas) y un **modelo de referencia** contra el que compara cada resultado. Invariantes:

| Requisito (sección 37) | Invariante |
|---|---|
| config activa no cambia durante pending; sin execute antes del delay; limpieza del pending; topes | `ActiveFeeConfigurationMatchesTheModel`, `NoExecutionBeforeTheDelay`, `PendingFeeConfigurationMatchesTheModel`, `FeeCapsAlwaysHold` |
| treasury activo no cambia durante pending; sin execute antes; rescue sólo al activo; el pending nunca recibe fondos | `TreasuryMatchesTheModel`, `NoExecutionBeforeTheDelay`, `PendingTreasuryNeverReceivesFunds` |
| **effectiveFee ≤ globalDefaultFee** para todo recipient y monto; vencido = default; pausa = 0; override activo nunca empeora; no cambia threshold/modelos | `EffectiveFeeNeverExceedsTheGlobalFee` (también exige igualdad con la especificación), `ExpiredOverrideIsTheGlobalFee`, `PausedMeansZeroFee`, `OverridesMatchTheModelAndPromisesHold`, `ActiveFeeConfigurationMatchesTheModel` |
| `userAmount = amount − effectiveFee`; accounting del treasury | `UserGetsExactlyAmountMinusEffectiveFee`, `TreasuryAccounting`, `Conservation` |
| otros | `NoUnexpectedOutcome` (cada acción predicha por el modelo), `PrivilegesNeverChange`, `VaultUntouched` |

**No vacuidad:** `test_HandlerReachesEverySuccessfulPath` recorre de forma determinista cada camino exitoso del
handler (proponer/ejecutar/cancelar fees y treasury, override nuevo y extendido, forward con descuento, pausa, vault,
falla del treasury y reintento) y exige que todos los invariantes valgan después. La muestra de la última corrida de
la campaña profunda (250 llamadas) registró 4 propuestas de fees, 1 ejecución, 3 cancelaciones, 5 propuestas de
treasury, 3 ejecuciones, 15 overrides (4 mejorando uno activo) y 23 forwards (5 con descuento).

---

## K. Echidna

Echidna 2.2.5, solc 0.8.30, modo property, `seqLen` 100, saltos de tiempo aleatorios de hasta una semana entre
transacciones además de las acciones `warp` del harness.

| Harness | Propiedades | Llamadas | Workers / duración | Resultado | Evidencia |
|---|---|---|---|---|---|
| **V3** `echidna/ForwarderV3Echidna.sol` (nuevo) | 18 | **1.000.363** (el doble de la campaña V2) | 6 / 317 min | **18/18 passing** | `echidna/echidna-v3-1m.txt` |
| V2 `ForwarderVaultChangeEchidna.sol` (adaptado) | 19 (todas las de V2) | 500.070 | 2 / 167 min | 19/19 passing | `echidna/echidna-v2-harness-500k.txt` |
| V1 `ForwarderEchidna.sol` (adaptado) | 11 (todas las de V1) | 500.076 | 2 / 91 min | 11/11 passing | `echidna/echidna-v1-harness-500k.txt` |

**Harness V3:** actores como contratos (admin, fee manager, fee manager + guardian, 2 guardians, stranger), modelo de
referencia, y acciones `proposeFees`, `executeFees`, `cancelFees`, `proposeTreasury`, `executeTreasury`,
`cancelTreasury`, `setOverride` (mejorar, subir fijo, subir variable, acortar, aleatorio sobre el global, recipient
cero), `warp` (a `executableAt − 1`, `executableAt`, `validUntil − 1`, `validUntil` o aleatorio), `forward`, `donate`,
`rescueUsdc`, `togglePause`, `setRoutingMode`, `toggleFailure` y `unauthorizedCall`; el 75 % de las llamadas de cada
ciclo las hace un actor autorizado y el resto cualquier actor. El vault se activa con el ciclo V2 y la campaña arranca
con una configuración global no nula (aplicada con el delay) para que los overrides importen desde el inicio.
Propiedades: `no_unexpected_outcome`, `no_execution_before_the_delay`, `active_fee_config_matches_model`,
`pending_fee_config_matches_model`, `fee_caps`, `treasury_matches_model`, `treasury_valid`,
`pending_treasury_never_funded`, `effective_fee_never_above_global`, `fee_matches_specification`,
`expired_override_is_global`, `paused_means_zero_fee`, `overrides_match_model_and_promises_hold`,
`user_gets_amount_minus_effective_fee`, `treasury_accounting`, `conservation`, `roles_never_change`, `vault_untouched`.

**Harness V1 y V2:** se conservaron todas sus propiedades; sólo se reemplazaron las llamadas a los setters eliminados
por los ciclos con delay (en V1 en un solo paso con `HEVM.warp`; en V2 proponer / ejecutar si maduró / cancelar,
intercalado con el ciclo del vault y con `_configHash` ampliado a los pending de V3), y `calculateFee` por
`calculateFeeFor` en `forward`.

**Notas de ejecución:** la primera ejecución de V3 falló al cargar porque las tres campañas se lanzaron a la vez y
comparten `crytic-export/combined_solc.json`; se relanzó sola. Esa campaña (4 workers) se reinició luego con 6
workers a los ~45.000 llamadas (con las 18 propiedades en passing) reutilizando su corpus de cobertura; el log
registrado es el de la campaña completa de 1.000.363 llamadas. El paso de Slither de Echidna fallaba en el harness V3
por un bug de plegado de constantes de Slither 0.10.4 (constante `MAX = type(uint256).max` usada en comparaciones);
se reemplazó por la expresión literal y el paso funciona en las tres campañas registradas.

---

## L. Certora

**Alcance (completo, no targeted):** `certora/specs/ForwarderV3.spec` contiene, sobre el código desplegado (vía
`certora/harness/ForwarderHarness.sol`, que sólo agrega getters de lectura):

- **V1 re-probado:** cálculo de la fee (`calculateFee` sin cambios), accounting de `forward` (ahora con
  `calculateFeeFor`), entrega al treasury best-effort, rescue, routing/allowances y access control, más las versiones
  `*ForAnyConfiguration` que escriben una configuración arbitraria con las funciones reales (en V3: propuesta + 72 h +
  ejecución, `configureFees`) y además un override del recipient.
- **V2 re-probado:** las 26 reglas y los invariantes del ciclo del vault (ampliados donde corresponde a los pending de
  V3).
- **V3 nuevo:** cooling de fees y treasury (delay exacto, sin bypass, sin overwrite, no acortable, limpieza,
  cancelaciones y liveness de la cancelación, quién propone/ejecuta/cancela, el treasury pendiente nunca cobra,
  rescue al activo), overrides (fee efectiva = especificación, nunca mayor que la global, vencimiento automático,
  pausa = 0, nunca empeora mientras está activo, sólo `setUserFeeOverride` los cambia, no toca nada más),
  `guardianCanOnlyCancel`, `feeManagerCannotTouchTheTreasury`, `adminWithoutFeeRoleCannotChangeFees`, e invariantes
  del estado pendiente (`pendingFeeConsistency`, `pendingFeeCaps`, `pendingFeeEnumsAreValid`,
  `pendingTreasuryConsistency`, `pendingTreasuryIsValid`, `zeroAddressHasNoOverride`).

**Configuración:** Certora CLI 8.8.0, solc 0.8.30, `cancun`, optimizer 200, `optimistic_loop` (`loop_iter 3`),
`precise_bitwise_ops`, `-enableStorageSplitting false`, `rule_sanity basic` (detecta reglas vacuas e invariantes
triviales), resúmenes de SafeERC20 como la llamada ERC-20 equivalente, DISPATCHER para vault/USDC, modelos
`DummyUSDC` / `DummyVault` / `DummyVault2`. Se reparte en 7 jobs (`certora/conf/ForwarderV3{Lifecycle,Fees,Forward,
Access,Vault,Invariants,MathMin}.conf`) más el recheck (`ForwarderV3Recheck.conf`) y los lemas aritméticos
(`ForwarderV3Lemmas.conf`); el paso no lineal se verifica además con Z3 (`audit/scripts/lemmas_z3.py`).

**`Math.min`:** OpenZeppelin 5.7 lo implementa sin ramas (`b ^ ((a ^ b) * toUint(a < b))`). En la spec final se
resume con su definición exacta (`a < b ? a : b`) y un job aparte **sin** ese resumen prueba que la implementación
real devuelve exactamente eso para todo par de `uint256` (`mathMinIsTheMinimum`, con testigos de ambas ramas): el
resumen es fiel, no un supuesto.

**Historial de corridas (todas en `audit/raw/v3/certora/`, resúmenes `*.summary.txt`):**

| Corrida | Spec | Resultado |
|---|---|---|
| Run 1 (6 jobs) | sin el resumen de `Math.min` | 113 reglas + 16 invariantes PASS; **3 TIMEOUT** (`effectiveFeeNeverExceedsGlobalFee`, `effectiveFeeFollowsLaterGlobalChanges`, `forwardUserReceivesAmountMinusFeeForAnyConfiguration`); 0 FAIL |
| Run 2 (7 jobs) | final (resumen de `Math.min` + job de fidelidad) | todo PASS salvo **los mismos 3 TIMEOUT**; 0 FAIL; 0 reglas vacuas; 0 invariantes triviales |
| Run 3 (recheck, `smt_timeout` 1800 s) | final + sección de descomposición | lemas `percentPartIsMonotone`, `specFeeIsMonotone`, `effectiveSpecFeeNeverExceedsGlobalSpecFee`, regla asistida `effectiveFeeNeverExceedsGlobalFeeAssisted` y `forwardUserReceivesAmountMinusEffectiveFeeForAnyConfiguration` **PASS**; `productIsMonotone` **FAIL** (contraejemplo espurio, ver abajo); `effectiveFeeFollowsLaterGlobalChangesAssisted` **UNKNOWN** (error interno del prover al vencer el timeout global); las 3 originales siguen en **TIMEOUT** |
| Run 4 | lemas con `-smt_nonLinearArithmetic true` | `productIsMonotone` sigue en FAIL; el resto PASS |
| Run 5 | lemas acotados al dominio del contrato (topes; `requireInvariant feeCaps` en las reglas que los instancian) | `productIsMonotone` FAIL; el resto PASS, incluida `effectiveFeeNeverExceedsGlobalFeeAssisted` |

Los 3 TIMEOUT comparan **dos cálculos de fee** en la misma consulta: contienen el paso no lineal
`amount · x ≤ amount · y` (con `x = min(override, global) ≤ y = global`). En la corrida 3 ese paso se prueba una vez,
para todos los valores, con el lema aritmético puro `productIsMonotone`, y se lo instancia en reglas "assisted" (un
`require` de una instancia de un enunciado universal ya probado, lo que es sound); además se prueba la propiedad por
composición: `effectiveFeeMatchesSpecification` (contrato = especificación, revert ⇔ overflow) +
`feeMatchesSpecification` (ídem para la global) + `effectiveSpecFeeNeverExceedsGlobalSpecFee` / `specFeeIsMonotone`
(especificación efectiva ≤ especificación global, y definida cuando la global lo está). Las 3 reglas originales se
re-ejecutan con `smt_timeout` 1800 s.

**El FAIL de `productIsMonotone` es espurio.** El lema dice `a ≥ 0 ∧ x ≤ y ⇒ a·x ≤ a·y` (multiplicar por un entero
no negativo preserva el orden), un teorema elemental de los enteros; Certora sobreaproxima la aritmética entera no
lineal (con aritmética lineal o real) y, para productos entre dos valores simbólicos distintos, reporta un
contraejemplo de esa aproximación. Las reglas que sólo necesitan igualdades entre productos (como
`feeMatchesSpecification`) pasan. Para no dejar ese paso sin verificación mecánica se probó con **Z3 en aritmética
entera exacta** (`audit/scripts/lemmas_z3.py`, salida en `audit/raw/v3/certora/lemmas-z3.txt`): `productIsMonotone`
(sin cotas y en el dominio uint256), `percentPartIsMonotone`, `specFeeIsMonotone` y "la especificación efectiva
nunca supera la global" para los 4 modelos, más "si el producto global no desborda, el efectivo tampoco": **6/6
PROVED**.

**Cobertura de los 5 resultados que no son PASS** (ninguno es un contraejemplo real):

| Regla | Final | Propiedad cubierta por |
|---|---|---|
| `effectiveFeeNeverExceedsGlobalFee` | TIMEOUT | `effectiveFeeNeverExceedsGlobalFeeAssisted` (PASS, sobre el contrato) + `productIsMonotone` (Z3); y por composición `effectiveFeeMatchesSpecification` + `feeMatchesSpecification` (PASS) + lemas de especificación (Certora PASS y Z3) |
| `effectiveFeeFollowsLaterGlobalChanges` | TIMEOUT | caso particular de la anterior (vale para todo estado, incluidos los alcanzados tras cambios globales posteriores) + `effectiveFeeMatchesSpecification` |
| `effectiveFeeFollowsLaterGlobalChangesAssisted` | UNKNOWN | ídem |
| `forwardUserReceivesAmountMinusFeeForAnyConfiguration` | TIMEOUT | su parte de accounting: `forwardUserReceivesAmountMinusEffectiveFeeForAnyConfiguration` (PASS); su desigualdad extra: la primera fila |
| `productIsMonotone` | FAIL (espurio) | Z3, aritmética exacta: PROVED |

Además, todas esas propiedades están ejercitadas por el fuzz (50.000 runs), los invariantes (8.000.000 de llamadas),
Echidna (1.000.363 llamadas) y los mutantes N07, N39, N40 y N41 (detectados).

**Lectura de los resultados:** para `satisfy`, Certora imprime la aserción negada de bajo nivel, por lo que
"`Satisfy_…: FAIL`" significa **testigo encontrado** (PASS); del mismo modo, "`…-rule_not_vacuous: A property is
violated`" significa que la regla **no es vacua**. La tabla siguiente aplica esa lectura
(`audit/scripts/certora_table.py`).

Tabla por regla (las corridas posteriores reemplazan a las anteriores para las reglas que re-ejecutan; `audit/raw/v3/certora/rules-table.md`):

| Rule / invariant | Job (final) | Final | Non-vacuity witnesses | History |
|---|---|---|---|---|
| `activeOverrideIsNeverWorsened` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `adminWithoutFeeRoleCannotChangeFees` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `authorizedCanAlwaysCancelFeeConfig` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `cancelClearsPendingOnly` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `cancelFeeConfigClearsPendingOnly` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `cancelTreasuryClearsPendingOnly` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `directDirectMeansNoVaultAllowance` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `discountedFeeIsReachable` | run2 | **PASS** | — (satisfy rule: the witness is the result) | run1: PASS; run2: PASS |
| `effectiveFeeFollowsLaterGlobalChanges` | run3 | **TIMEOUT** | — | run1: TIMEOUT; run2: TIMEOUT; run3: TIMEOUT |
| `effectiveFeeFollowsLaterGlobalChangesAssisted` | run3 | **UNKNOWN** | — | run3: UNKNOWN |
| `effectiveFeeMatchesSpecification` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `effectiveFeeMatchesSpecificationForAnyConfiguration` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `effectiveFeeNeverExceedsGlobalFee` | run3 | **TIMEOUT** | — | run1: TIMEOUT; run2: TIMEOUT; run3: TIMEOUT |
| `effectiveFeeNeverExceedsGlobalFeeAssisted` | run5 | **PASS** | 1 | run3: PASS; run5: PASS |
| `effectiveSpecFeeNeverExceedsGlobalSpecFee` | run5 | **PASS** | 1 | run3: PASS; run4: PASS; run5: PASS |
| `enumsAreValid` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `executeActivatesPendingVaultAndClearsIt` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `executeAllowancesFollowCurrentRouting` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `executeFeeConfigAppliesPendingAndClearsIt` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `executeFeeConfigRevertsBeforeExecutableAt` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `executeFeeConfigRevertsWithoutPendingChange` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `executeFeeConfigStoresProposedConfiguration` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `executeHealthCheckUsesOnlyCallerFunds` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `executeRevertsBeforeExecutableAt` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `executeRevertsWithoutPendingChange` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `executeTreasuryActivatesPendingAndClearsIt` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `executeTreasuryRevertsBeforeExecutableAt` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `executeTreasuryRevertsWithoutPendingChange` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `executeUsesRoutingInForceAtExecution` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `expiredOverrideIsTheGlobalFee` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `failedExecutionKeepsState` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `failedFeeExecutionKeepsState` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `feeCaps` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `feeChangeDelayIs72Hours` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `feeConfigOnlyChangesThroughMaturedExecution` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `feeLifecycleKeepsEverythingElse` | run2 | **PASS** | 3 | run1: PASS; run2: PASS |
| `feeManagerAdminIsDefaultAdmin` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `feeManagerCannotAdminister` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `feeManagerCannotAdministerVault` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `feeManagerCannotTouchTheTreasury` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `feeManagerRoleOnlyChangedByAdminOrSelf` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `feeMatchesSpecification` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `feeMatchesSpecificationForAnyConfiguration` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `fixedModelChargesAfterConfiguration` | run2 | **PASS** | — (satisfy rule: the witness is the result) | run1: PASS; run2: PASS |
| `fixedModelIsReachable` | run2 | **PASS** | — (satisfy rule: the witness is the result) | run1: PASS; run2: PASS |
| `fixedPlusPercentModelChargesAfterConfiguration` | run2 | **PASS** | — (satisfy rule: the witness is the result) | run1: PASS; run2: PASS |
| `fixedPlusPercentModelIsReachable` | run2 | **PASS** | — (satisfy rule: the witness is the result) | run1: PASS; run2: PASS |
| `forwardDoesNotChangeConfiguration` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `forwardKeepsPendingChange` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `forwardNeverApproves` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `forwardNeverPaysThePendingTreasury` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `forwardOnlyAcceptsUsdc` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `forwardTreasuryAccounting` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `forwardTreasuryAccountingForAnyConfiguration` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `forwardUserReceivesAmountMinusEffectiveFeeForAnyConfiguration` | run3 | **PASS** | 1 | run3: PASS |
| `forwardUserReceivesAmountMinusFee` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `forwardUserReceivesAmountMinusFeeForAnyConfiguration` | run3 | **TIMEOUT** | — | run1: TIMEOUT; run2: TIMEOUT; run3: TIMEOUT |
| `guardianAdminIsDefaultAdmin` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `guardianCanOnlyCancel` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `guardianCannotProposeOrExecute` | run2 | **PASS** | 2 | run1: PASS; run2: PASS |
| `guardianOrAdminCanAlwaysCancel` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `guardianOrAdminCanAlwaysCancelTreasury` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `guardianRoleChangesKeepPendingChange` | run2 | **PASS** | 3 | run1: PASS; run2: PASS |
| `guardianRoleOnlyChangedByAdminOrSelf` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `lowerModelUpToThreshold` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `mathMinIsTheMinimum` | run2 | **PASS** | 1 | run2: PASS |
| `mathMinReturnsTheFirstArgument` | run2 | **PASS** | — (satisfy rule: the witness is the result) | run2: PASS |
| `mathMinReturnsTheSecondArgument` | run2 | **PASS** | — (satisfy rule: the witness is the result) | run2: PASS |
| `onlyAdminChangesRoutingMode` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `onlyAdminChangesTreasury` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `onlyAdminChangesVault` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `onlyAdminExecutes` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `onlyAdminExecutesTreasury` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `onlyAdminOrGuardianCancels` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `onlyAdminOrGuardianCancelsTreasury` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `onlyAdminProposes` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `onlyAdminProposesTreasury` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `onlyAdminUnpauses` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `onlyAuthorizedCancelsFeeConfig` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `onlyFeeManagerChangesFeeConfig` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `onlyFeeManagerExecutesFeeConfig` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `onlyFeeManagerProposesFeeConfig` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `onlyFeeManagerSetsOverrides` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `onlyPrivilegedPause` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `overridesOnlyChangeThroughSetUserFeeOverride` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `pausedEffectiveFeeIsZero` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `pausedFeeIsZero` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `pausedForwardDeliversWholeAmount` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `pausedForwardDeliversWholeAmountForAnyConfiguration` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `pendingChangeCannotBeShortened` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `pendingFeeCaps` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `pendingFeeConfigCannotBeShortened` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `pendingFeeConfigOnlyClearedByCancelOrExecute` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `pendingFeeConsistency` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `pendingFeeEnumsAreValid` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `pendingOnlyClearedByCancelOrExecute` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `pendingTreasuryCannotBeShortened` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `pendingTreasuryConsistency` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `pendingTreasuryIsValid` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `pendingTreasuryOnlyClearedByCancelOrExecute` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `pendingVaultConsistency` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `pendingVaultHasNoAllowance` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `pendingVaultIsNotActive` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `percentAboveThresholdIsNotExcessFee` | run2 | **PASS** | — (satisfy rule: the witness is the result) | run1: PASS; run2: PASS |
| `percentAboveThresholdUsesWholeAmount` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `percentModelIsReachable` | run2 | **PASS** | — (satisfy rule: the witness is the result) | run1: PASS; run2: PASS |
| `percentPartIsMonotone` | run5 | **PASS** | 1 | run3: PASS; run4: PASS; run5: PASS |
| `percentUsesWholeAmount` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `percentUsesWholeAmountIsNotTheExcessFee` | run2 | **PASS** | — (satisfy rule: the witness is the result) | run1: PASS; run2: PASS |
| `productIsMonotone` | run5 | **FAIL** | — | run3: FAIL; run4: FAIL; run5: FAIL |
| `proposeFeeConfigEnforcesTheCaps` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `proposeFeeConfigRevertsWhileAChangeIsPending` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `proposeFeeConfigStoresExactProposal` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `proposeHealthCheckUsesOnlyCallerFunds` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `proposeLeavesNoCandidateAllowance` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `proposeRevertsWhileAChangeIsPending` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `proposeStoresCandidateWithExactDelay` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `proposeTreasuryRejectsInvalidCandidates` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `proposeTreasuryRevertsWhileAChangeIsPending` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `proposeTreasuryStoresCandidateWithExactDelay` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `rescueNativeOnlyToTreasury` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `rescueTokenOnlyToTreasury` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `rescueWhileTreasuryPendingPaysTheActiveTreasury` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `routingModeAllowance` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `setUserFeeOverrideLiveness` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `setUserFeeOverrideTouchesOnlyThatOverride` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `setUserFeeOverrideValidation` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `specFeeIsMonotone` | run5 | **PASS** | 1 | run3: PASS; run4: PASS; run5: PASS |
| `treasuryChangeDelayIs72Hours` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `treasuryFailureNeverRevertsForward` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `treasuryFailureNeverRevertsForwardForAnyConfiguration` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `treasuryIsValid` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `treasuryLifecycleKeepsEverythingElse` | run2 | **PASS** | 3 | run1: PASS; run2: PASS |
| `treasuryOnlyChangesThroughMaturedExecution` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `unprivilegedCannotTouchVaultLifecycle` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `unprivilegedChangesNoConfiguration` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `upperModelAboveThreshold` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `vaultChangeDelayIs72Hours` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `vaultLifecycleKeepsConfiguration` | run2 | **PASS** | 3 | run1: PASS; run2: PASS |
| `vaultModeHasVault` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `vaultOnlyChangesThroughExecuteAfterDelay` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `zeroAddressHasNoOverride` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |

Totals (final): FAIL 1, PASS 137, TIMEOUT 3, UNKNOWN 1 — 142 entries

---

## M. Slither

Corrida completa sobre el código desplegado con **Slither 0.11.6** (102 detectores) y **Slither 0.10.4** (93), mismo
filtro que V1/V2 (`lib/|test/|script/|echidna/|certora/`). Salidas (texto, JSON y printer `vars-and-auth`) en
`audit/raw/v3/slither/`.

**Comparación con V2:** 0.11.6: V2 14 → V3 **19**; 0.10.4: V2 12 → V3 **16**. Los 14 (12) avisos de V2 siguen
presentes con el mismo detector, la misma función y la misma causa (sólo cambian números de línea; clasificación
S-01…S-14 de [`FINAL_AUDIT_REPORT_V2.md`](FINAL_AUDIT_REPORT_V2.md) §J, todos false positive / by design). Ninguno
desapareció. Nuevos:

| ID | Detector | Severidad / Confianza | Ubicación V3 | Análisis | Clasificación |
|---|---|---|---|---|---|
| S-15 | `timestamp` | Low / Medium | `executeFeeConfigChange`: `block.timestamp < config.executableAt` | Es la comparación del delay de 72 h (intencional). En Base los timestamps L2 son monótonos y el desvío permitido al sequencer es de segundos/minutos frente a 72 h | By design |
| S-16 | `timestamp` | Low / Medium | `executeTreasuryChange`: `block.timestamp < executableAt` | Idem | By design |
| S-17 | `timestamp` | Low / Medium | `calculateFeeFor`: `block.timestamp >= feeOverride.validUntil` | Vigencia del override; una variación de segundos en el borde sólo cambia si el último segundo usa el descuento o la fee global (ambas ≤ global) | By design |
| S-18 | `timestamp` | Low / Medium | `setUserFeeOverride`: `validUntil <= block.timestamp`, `block.timestamp < feeOverride.validUntil` | Validación de vencimiento y de override activo; mismo análisis | By design |
| S-19 | `unindexed-event-address` (sólo 0.11.6) | Informational / High | `FeeConfigChangeProposed` no tiene topics indexados | El monitoreo filtra por `topic0` y decodifica los datos; hay una sola propuesta pendiente a la vez | Informational (I-V3-08) |

Conclusión: **0 true positives**; las funciones nuevas no generan avisos de reentrancy (no hacen llamadas externas).

`vars-and-auth` confirma qué funciones escriben cada variable sensible:

| Variable | Escrita por |
|---|---|
| `lowerFeeModel`, `upperFeeModel`, `threshold`, `fixedFee`, `variableFee` | `_setFeeConfig` ← **sólo** `executeFeeConfigChange` (el constructor no las toca) |
| `treasury` | constructor, `_setTreasury` ← **sólo** `executeTreasuryChange` |
| `vault` | constructor, `_setVault` ← **sólo** `executeVaultChange` |
| `pendingFeeConfig` | `proposeFeeConfig`, `executeFeeConfigChange`, `cancelFeeConfigChange` |
| `pendingTreasury`, `pendingTreasuryExecutableAt` | `proposeTreasury`, `executeTreasuryChange`, `cancelTreasuryChange` |
| `userFeeOverrides` | **sólo** `setUserFeeOverride` |

---

## N. Mutation Testing

`audit/scripts/mutation_v3.py`: cada mutante se aplica sobre una copia aislada del repositorio (sin `.env`) y se corre
la suite local completa (`forge test --no-match-contract Fork`: unit + fuzz + invariantes). Se validó antes que cada
patrón aplica exactamente una vez y que los 65 mutantes compilan. **65/65 KILLED**: los 22 mutantes V2 (vault) y 43
mutantes V3, que incluyen todos los sugeridos en la sección 41 (delays a 0, execute sin delay, rescue al treasury
pendiente, override > global, sin `min`, borde de expiración, override que cobra en pausa, override activo que sube,
expiración que se acorta, `forward` con la fee global, `userAmount` con otra fee) y además bordes T−1/T, sobreescritura
de propuestas, topes sin validar, limpiezas faltantes, permisos ampliados, aplicación inmediata, `min` parcial, `max`
en vez de `min`, `executeFeeConfigChange` que conserva un valor viejo y delays de 71 h. Detalle y logs:
`audit/raw/v3/mutation/`.

| ID | Mutación | Resultado | Detectado por (primeros) |
|---|---|---|---|
| M01 | VAULT_CHANGE_DELAY 72 hours -> 0 | KILLED | `invariant_DelayIsImmutable`, `test_AdminProposes` |
| M02 | Vault: execution allowed one second before executableAt | KILLED | `test_RevertWhen_ExecutingOneSecondEarly`, `test_RevokingAllGuardiansDoesNotShortenTheDelay` |
| M03 | Vault: execution rejected exactly at executableAt | KILLED | `test_ExecuteVaultChange`, `test_SuccessfulExecutionInDirectDirect` |
| M04 | executeVaultChange without the delay check | KILLED | `test_NoReentrantPathExecutesBeforeTheDelay`, `test_RevertWhen_ExecutingImmediately` |
| M05 | A guardian can execute the vault change | KILLED | `test_GuardianHasNoOtherPower`, `test_RevertWhen_GuardianExecutes` |
| M06 | A guardian can propose a vault | KILLED | `test_FeeManagerWithGuardianRoleCancelsAndKeepsFeePowers`, `test_RevertWhen_GuardianProposes` |
| M07 | A fee manager can propose a vault | KILLED | `test_FeeManagerAndStrangerCannotCallAdminFunctions`, `test_FeeManagerCannotChangeTreasuryVaultRoutingOrRescue` |
| M08 | The vault proposal changes the active vault immediately | KILLED | `test_ActiveVaultCannotReenterExecuteFromForward`, `test_AdminProposes` |
| M09 | cancelVaultChange does not clear the pending change | KILLED | `test_AdminCancels`, `test_CancelAfterTheDelay` |
| M10 | executeVaultChange does not clear the pending change | KILLED | `test_ActiveVaultCannotReenterExecuteFromForward`, `test_CandidateAssetChangesAfterProposal` |
| M11 | The vault proposal leaves an unlimited allowance to the candidate | KILLED | `test_AdminProposes`, `test_CancelKeepsActiveVaultAllowanceAndRouting` |
| M12 | The vault proposal does not clear the unused health check allowance | KILLED | `test_HealthCheckRefundsAssetsTheVaultDidNotPull` |
| M13 | The old vault keeps its allowance after the execution | KILLED | `test_CandidateAssetChangesAfterProposal`, `test_CandidateCodeRemovedAfterProposal` |
| M14 | The vault execution uses the routing mode of the proposal instead of the current one | KILLED | `test_CaseA_DirectDirectSelectedWhilePending`, `test_CaseB_VaultVaultSelectedWhilePending` |
| M15 | The second health check is removed from the vault execution | KILLED | `test_CandidateAssetChangesAfterProposal`, `test_CandidateCannotReenterExecuteDuringExecution` |
| M16 | A failed vault execution deletes the pending change instead of reverting | KILLED | `test_CandidateAssetChangesAfterProposal`, `test_CandidateCodeRemovedAfterProposal` |
| M17 | Revoking a guardian resets the pending vault timestamp to now | KILLED | `test_GrantingAndRenouncingGuardiansDoesNotChangeExecutableAt`, `test_RevokingAGuardianDoesNotChangeExecutableAt` |
| M18 | Anyone can cancel the vault change | KILLED | `test_FeeManagerCannotChangeTreasuryVaultRoutingOrRescue`, `test_RevertWhen_FeeManagerWithoutGuardianRoleCancels` |
| M19 | A new vault proposal silently replaces the pending one | KILLED | `test_RevertWhen_ProposingWhileAChangeIsPending` |
| M20 | The active vault can be proposed again | KILLED | `test_RevertWhen_ProposingTheActiveVault`, `test_RevertWhen_ProposingTheActiveVaultInVaultMode` |
| M21 | executeVaultChange without nonReentrant | KILLED | `test_ActiveVaultCannotReenterExecuteFromForward`, `test_CandidateCannotReenterExecuteDuringExecution` |
| M22 | The constructor does not grant the initial guardians | KILLED | `invariant_PrivilegesNeverChange`, `invariant_RolesMatchModel` |
| N01 | FEE_CHANGE_DELAY 72 hours -> 0 | KILLED | `test_AdminWithFeeManagerRoleStillWaitsTheDelay`, `test_CompromisedFeeManagerBlastRadius` |
| N02 | TREASURY_CHANGE_DELAY 72 hours -> 0 | KILLED | `test_Constants`, `test_ProposeAgainAfterCancellationRestartsTheDelay` |
| N03 | executeFeeConfigChange without the delay check | KILLED | `test_AdminWithFeeManagerRoleStillWaitsTheDelay`, `test_CompromisedFeeManagerBlastRadius` |
| N04 | executeTreasuryChange without the delay check | KILLED | `test_ProposeAgainAfterCancellationRestartsTheDelay`, `test_RevertWhen_ExecutingImmediately` |
| N05 | rescueToken pays the pending treasury when there is one | KILLED | `test_RescueTokenBeforeExecutionGoesToTheActiveTreasury` |
| N06 | An override above the global fee is accepted | KILLED | `test_CompromisedFeeManagerBlastRadius`, `test_ExtendingWhileTheGlobalFeeIsBelowTheOverride` |
| N07 | calculateFeeFor without min(override, global) | KILLED | `test_TheUserNeverPaysMoreThanTheCurrentGlobalFee` |
| N08 | Expiry boundary: the override is still active at validUntil | KILLED | `test_ExpiredOverrideForwardChargesTheGlobalFee`, `test_OverrideExpiresExactlyAtValidUntil` |
| N09 | A paused fee still charges recipients with an active override | KILLED | `test_PausedFeeIsZeroWithOverride` |
| N10 | The fixed fee of an active override can be raised | KILLED | `test_RevertWhen_RaisingTheFixedFeeOfAnActiveOverride` |
| N11 | The variable fee of an active override can be raised | KILLED | `test_RevertWhen_RaisingTheVariableFeeOfAnActiveOverride` |
| N12 | The expiry of an active override can be shortened | KILLED | `test_RevertWhen_ShorteningAnActiveOverride` |
| N13 | forward charges the global fee instead of the effective fee | KILLED | `test_ForwardWithOverrideChargesTheDiscountedFeeInEveryMode`, `test_ForwardedEventReportsTheEffectiveFee` |
| N14 | userAmount uses a fee different from the one accounted to the treasury | KILLED | `test_ForwardWithOverrideChargesTheDiscountedFeeInEveryMode`, `test_ForwardedEventReportsTheEffectiveFee` |
| N15 | Fee configuration: execution allowed one second before executableAt | KILLED | `test_AdminWithFeeManagerRoleStillWaitsTheDelay`, `test_RevertWhen_ExecutingOneSecondEarly` |
| N16 | Fee configuration: execution rejected exactly at executableAt | KILLED | `test_ExecuteExactlyAtExecutableAt`, `test_ExecuteFeeConfigChangeEmitsFullConfig` |
| N17 | Treasury: execution allowed one second before executableAt | KILLED | `test_RevertWhen_ExecutingOneSecondEarly`, `test_RevokingAllGuardiansDoesNotShortenTheDelay` |
| N18 | Treasury: execution rejected exactly at executableAt | KILLED | `test_ExecuteExactlyAtExecutableAt`, `test_ForwardUsesConfigurationSnapshot` |
| N19 | A new fee proposal silently replaces the pending one | KILLED | `test_RevertWhen_ProposingWhileAChangeIsPending` |
| N20 | A new treasury proposal silently replaces the pending one | KILLED | `test_RevertWhen_ProposingWhileAChangeIsPending` |
| N21 | proposeFeeConfig does not check the caps | KILLED | `test_ProposalValidatesTheCaps`, `test_RevertWhen_FixedFeeAboveMaximum` |
| N22 | cancelFeeConfigChange does not clear the pending configuration | KILLED | `test_AdminCancels`, `test_AnotherFeeManagerCancels` |
| N23 | executeFeeConfigChange does not clear the pending configuration | KILLED | `invariant_PendingFeeConfigurationMatchesTheModel`, `test_ExecuteAfterExecutableAt` |
| N24 | cancelTreasuryChange does not clear the pending treasury | KILLED | `test_AdminCancels`, `test_AnotherGuardianCancels` |
| N25 | executeTreasuryChange does not clear the pending treasury | KILLED | `test_ExecuteExactlyAtExecutableAt`, `test_ExecuteLongAfterExecutableAt` |
| N26 | A guardian can execute the fee configuration | KILLED | `test_RevertWhen_GuardianExecutes` |
| N27 | The admin can execute the fee configuration without FEE_MANAGER_ROLE | KILLED | `test_AdminAndStrangerCannotCallFeeManagerFunctions`, `test_RevertWhen_AdminExecutes` |
| N28 | Anyone can cancel the fee configuration | KILLED | `test_RevertWhen_StrangerCancels` |
| N29 | A fee manager can cancel the treasury change | KILLED | `test_FeeManagerCannotChangeTreasuryVaultRoutingOrRescue`, `test_RevertWhen_FeeManagerWithoutGuardianRoleCancels` |
| N30 | Anyone can cancel the treasury change | KILLED | `test_FeeManagerCannotChangeTreasuryVaultRoutingOrRescue`, `test_RevertWhen_FeeManagerWithoutGuardianRoleCancels` |
| N31 | A guardian can propose a treasury | KILLED | `test_GuardianHasNoOtherPower`, `test_RevertWhen_GuardianProposes` |
| N32 | A guardian can execute the treasury change | KILLED | `test_RevertWhen_GuardianExecutes` |
| N33 | proposeFeeConfig applies the configuration immediately | KILLED | `test_AdminCancels`, `test_AnotherFeeManagerCancels` |
| N34 | proposeTreasury changes the treasury immediately | KILLED | `test_AdminCancels`, `test_AdminProposes` |
| N35 | setUserFeeOverride accepts the zero address | KILLED | `test_RevertWhen_RecipientIsZero` |
| N36 | setUserFeeOverride accepts a validUntil that is not in the future | KILLED | `test_RevertWhen_ValidUntilIsNotInTheFuture` |
| N37 | Anyone can set overrides | KILLED | `test_AdminAndStrangerCannotCallFeeManagerFunctions`, `test_GuardianHasNoOtherPower` |
| N38 | calculateFeeFor ignores the threshold (always the lower model) | KILLED | `test_ExpectedOverrideFeeMatchesForEveryModelPair`, `test_OverrideUsesTheGlobalLowerAndUpperModels` |
| N39 | calculateFeeFor uses the global variable fee | KILLED | `test_ExpectedOverrideFeeMatchesForEveryModelPair`, `test_ExtendingAnActiveOverride` |
| N40 | calculateFeeFor uses the global fixed fee | KILLED | `test_ActiveOverrideSurvivesGlobalChangesAndPause`, `test_ExpectedOverrideFeeMatchesForEveryModelPair` |
| N41 | calculateFeeFor uses max(override, global) | KILLED | `test_ActiveOverrideSurvivesGlobalChangesAndPause`, `test_ExpectedOverrideFeeMatchesForEveryModelPair` |
| N42 | executeFeeConfigChange keeps the old fixed fee | KILLED | `test_AdminWithFeeManagerRoleStillWaitsTheDelay`, `test_AllModelCombinationsAroundThreshold` |
| N43 | FEE_CHANGE_DELAY and TREASURY_CHANGE_DELAY 72 hours -> 71 hours | KILLED | `test_Constants`, `test_ExecutableAtIsAlwaysProposalTimePlus72Hours` |

---

## O. Findings

**Critical: 0 · High: 0 · Medium (contrato): 0 · Low: 3 (acknowledged, de diseño) · Informational: 14.** Ninguno
requirió cambiar el código desplegado. Además de la revisión propia, una **revisión manual independiente** del diff
(adversarial, sólo lectura) llegó a la misma conclusión (sin Critical/High/Medium, sin desvíos de los requisitos); sus
observaciones están consolidadas abajo.

| ID | Severidad | Título | Estado | Detalle | Recomendación |
|---|---|---|---|---|---|
| L-V3-01 | Low | Las propuestas maduras no vencen (vault, fees y treasury) | Acknowledged (no se pidió expiración) | Una propuesta que alcanzó `executableAt` queda ejecutable indefinidamente: cualquier fee manager puede ejecutar una propuesta de fees madura (de cualquier fee manager) y el admin una de treasury o vault, en cualquier momento posterior y sin nuevo aviso. Además ocupa el único slot pendiente y bloquea nuevas propuestas hasta cancelarla. Generaliza L-V2-01 | **Toda propuesta madura que no vaya a ejecutarse de inmediato debe cancelarse**; alertar si `executableAt ≤ now` con pending |
| L-V3-02 | Low | Overrides irrevocables y sin tope de duración | Acknowledged (garantía pedida) | `validUntil` sólo exige `> now`; un override activo no puede quitarse ni acortarse, ni siquiera por el admin, y revocar al fee manager no lo deshace. Un fee manager comprometido (o un error de unidades, p. ej. milisegundos) puede dejar descuentos permanentes (hasta 0) para recipients elegidos. Impacto: ingresos de fees; nunca fondos de usuarios | Validar `validUntil` off-chain (segundos, plazo acotado); monitorear `UserFeeOverrideSet`; si hiciera falta, la única remediación es un deploy nuevo |
| L-V3-03 | Low | El veto de los guardians no resiste a un admin comprometido | Acknowledged (diseño V2, L-V2-02) | `revokeRole` es inmediato (sólo el rol de admin tiene delay). En producción una misma clave (`0xa737…C5db`, único owner de la Safe 1/1) es admin, fee manager y guardian: puede revocar guardians y fee managers, otorgarse `FEE_MANAGER_ROLE` y proponer treasury propio + fees máximas. El delay de 72 h no se puede saltear: la protección real es la ventana pública de 72 h + cortar el flujo de las SRA off-chain | Monitoreo (Q.1) y procedimiento de corte; considerar al menos un guardian con clave independiente del owner de la Safe y subir el threshold de la Safe |
| I-V3-01 | Info | El override limita cada componente por separado; modelos y threshold son globales | By design (pedido) | Un componente que vale 0 al crear el override queda en 0 mientras esté activo. **Con las fees globales actuales en 0, el único override posible es (0, 0): una exención total que seguiría valiendo después de activar las fees.** Un cambio de modelo o de threshold (con delay) puede hacer que aplique el otro componente (p. ej. de PERCENT a FIXED), con lo que la fee del usuario puede subir, siempre ≤ la fee global y con cada componente ≤ el del override | No crear overrides hasta tener activa la configuración global deseada; comunicar los overrides como topes por componente |
| I-V3-02 | Info | `unpause()` es un cambio inmediato de 0 a la configuración guardada | By design (pausa sin cambios) | Una configuración puede ejecutarse con fees pausadas sin efecto visible y activarse luego al instante con `unpause()` (sólo admin), quizás mucho después de su aviso de 72 h | Tratar `FeeConfigUpdated` con fees pausadas y `Unpaused` como cambios de fees en el monitoreo; revisar la configuración antes de despausar |
| I-V3-03 | Info | Los fee managers pueden blindar recipients ante una suba pendiente | By design | La validación usa la configuración activa: durante las 72 h de una suba, un fee manager puede fijar overrides a los valores actuales con `validUntil` largo | Política comercial y monitoreo de `UserFeeOverrideSet` |
| I-V3-04 | Info | Griefing con el slot único y las cancelaciones | By design | Un fee manager (o guardian, para vault y treasury) hostil puede ocupar el slot con una propuesta basura, re-proponer tras cada cancelación, cancelar justo antes de madurar o fijar antes un override menor para que uno legítimo posterior revierta (`ActiveFeeOverrideWorsened`). No mueve fondos | El admin revoca la cuenta (inmediato) |
| I-V3-05 | Info | Revocar un rol no deshace lo que esa cuenta hizo | Operativo | Las propuestas pendientes no están atadas al proponente (cualquier otro fee manager puede ejecutarlas) y los overrides siguen vigentes | Al revocar, cancelar también sus propuestas pendientes |
| I-V3-06 | Info | Carrera execute/cancel desde `executableAt` | By design | Ambas funciones son válidas desde ese instante; el sequencer de Base ordena por prioridad | Cancelar antes de `executableAt` |
| I-V3-07 | Info | `proposeTreasury` valida menos que `proposeVault` | By design (validación V2) | Acepta el treasury actual (no-op inofensivo) y no verifica que pueda recibir USDC. Reemplazar un treasury bloqueado ahora tarda ≥ 72 h (en V2 era inmediato); mientras tanto las fees quedan retenidas en el Forwarder (sin pérdida) y los rescues siguen yendo al treasury viejo, como se pidió | `pause()` si hace falta; verificar el candidato antes de proponer |
| I-V3-08 | Info | Detalles cosméticos de eventos y errores | Acknowledged | `cancelFeeConfigChange` revierte nombrando sólo `VAULT_GUARDIAN_ROLE` aunque acepta tres roles (mismo patrón que V2); `FeeConfigChangeProposed` sin topics indexados (S-19); `FeeConfigChangeCancelled` sólo lleva `cancelledBy` (hay una única propuesta); `UserFeeOverrideSet` se emite aunque los valores no cambien | Ninguna |
| I-V3-09 | Info | Costo de gas de `forward` | Medido | +2.320 gas por `forward` sin override (lectura en frío de `validUntil` + llamada), p. ej. 89.462 → 91.782 en `DIRECT_DIRECT` sobre fork; con override activo, dos lecturas más | Confirmar margen si las SRA usan un gas limit fijo |
| I-V3-10 | Info | Integraciones | Documentado | `calculateFee` sigue devolviendo la fee global: las cotizaciones por recipient deben usar `calculateFeeFor`. Los overrides se indexan por `recipient`, no por quien llama a `forward`: no otorgarlos a contratos compartidos o reenviadores | README |
| I-V3-11 | Info | Dependencia de timestamps | By design | S-15…S-18 | — |
| I-V3-12 | Info | La simulación del deploy contra "latest" puede fallar dentro de Aave | Resuelto (operativo) | Mismo artefacto que V1 I-09 (estado del RPC más nuevo que el bloque simulado); se resolvió de forma determinista fijando `--fork-block-number` (R) | Documentado en el README |
| I-V3-13 | Info | V1 y V2 siguen activos con setters inmediatos | Acknowledged (V1/V2 se mantienen intactos por instrucción) | Los delays de V3 sólo protegen a las SRA que apunten a V3 | Tras migrar las SRA, considerar revocar `FEE_MANAGER_ROLE`/pausar en V1 y V2 (decisión del owner) |
| I-V3-14 | Info | Documentación desactualizada en archivos no desplegados | Resuelto | Comentario de `vaultGuardians()` en `script/ForwarderDeployConfig.sol` y dos imprecisiones del README (overrides "sólo menores" → "a lo sumo iguales"; topes por componente). El NatSpec desplegado dice "temporary" aunque la duración no tiene tope (L-V3-02) | Corregido en el repo; el NatSpec no se puede cambiar sin redeploy |

**Estado de findings anteriores:**

| ID previo | Estado en V3 |
|---|---|
| V1 I-05 — fees sin timelock (subir la fee justo antes de un depósito) | **Resuelto**: toda configuración global tarda 72 h y se puede cancelar |
| V2 I-V2-01 — el delay sólo protegía el vault | **Resuelto para treasury y fees**. Quedan inmediatos para el admin: routing sobre el vault activo, rescue al treasury activo, roles, pause/unpause (G.2) |
| V1 M-01 / V2 — Safe admin 1/1 | Decisión operativa intencional (sin cambios) |
| V1 L-03 — `fee > amount` revierte | Sin cambios en el código; ahora cualquier configuración tarda 72 h y se puede cancelar |
| V1 I-07 — el saldo pendiente sigue al treasury vigente | Sin cambios de semántica; el treasury nuevo recién rige tras 72 h |
| V2 L-V2-01, L-V2-02 | Generalizados en L-V3-01 y L-V3-03 |
| V1 I-01…I-04, I-06, I-08; V2 I-V2-02…I-V2-05 | Sin cambios (código sin cambios) |

---

## P. Residual Risks

1. **Propuestas maduras sin vencimiento (vault, fees y treasury).** Una propuesta que alcanzó su `executableAt`
   queda ejecutable **indefinidamente** hasta que se ejecute o se cancele (L-V3-01; para el vault, L-V2-01). No se
   agregó expiración (no fue pedida). **Regla operativa: toda propuesta madura que no vaya a ejecutarse de forma
   inmediata debe cancelarse.**
2. **72 h como ventana de reacción.** Los delays sólo protegen si los eventos se detectan y alguien reacciona:
   cancelar (guardians, admin, fee managers) y/o **cortar el flujo de las SRA** antes de `executableAt`. Sin monitoreo
   externo y sin un procedimiento de corte, el delay no evita la pérdida.
3. **Admin de confianza, Safe 1/1 (intencional).** El admin sigue controlando de inmediato roles, routing (sobre el
   vault activo), rescue (al treasury activo) y pause/unpause, y puede proponer vault y treasury (G.2). Una sola clave
   controla la Safe.
4. **Overrides irrevocables y sin tope de duración** (L-V3-02): un fee manager comprometido puede dar descuentos
   permanentes (hasta 0) a recipients elegidos; nadie puede revocarlos antes de su `validUntil`. Impacto: ingresos de
   fees, nunca fondos de usuarios.
5. **Griefing de cancelación** (L-V3-03): guardians y fee managers pueden cancelar propuestas una y otra vez; el admin
   revoca al hostil.
6. **Garantía del override sobre parámetros, no sobre el modelo** (I-V3-01): un cambio de modelo o threshold (con
   delay) puede cambiar qué fórmula aplica al usuario, siempre ≤ la fee global y con `fixed`/`variable` ≤ los del
   override.
7. **Vault de confianza.** Mientras el routing usa el vault, éste tiene allowance ilimitado; su comportamiento
   (pausas, caps, redondeos, upgrades) afecta las piernas que lo usan. Mitigación inmediata: `DIRECT_DIRECT`.
8. **Returndata malformada del vault en la pierna del usuario.** Si `deposit()` se ejecuta pero devuelve datos ABI
   malformados, `forward` **revierte completo** en vez de usar el fallback en USDC. Es intencional: evita un posible
   doble pago (el vault podría haber acreditado shares). Los fondos quedan en la SRA (revert atómico). No se modificó.
9. **Shares en 0 por redondeo (ERC-4626).** Un vault puede emitir 0 shares para un depósito positivo; `forward` no
   impone un mínimo. Antes de aprobar un vault nuevo hay que revisar `previewDeposit`, el mínimo depósito operativo,
   el redondeo/offset de decimales y confirmar que los depósitos positivos normales producen shares > 0 (Q.4). No se
   modificó `forward`.
10. **Entrega al treasury best-effort.** Los fondos pueden quedar retenidos en el Forwarder hasta el próximo
    `forward`, un rescate o un cambio de treasury/routing.
11. **Circle / USDC.** Circle puede pausar USDC, poner cuentas en blacklist o actualizar el contrato. Un recipient en
    blacklist no puede recibir y su depósito queda en la SRA.
12. **Fees mal configuradas** (V1 L-03): `fee > amount` revierte (sin clamp); ahora cualquier configuración tarda
    72 h en aplicarse y puede cancelarse antes.

---

## Q. Operational Runbook

### Q.1 Monitoreo (externo; no implementado en el contrato)

Alertas en tiempo real como mínimo para:

| Evento | Qué significa | Acción |
|---|---|---|
| `VaultChangeProposed` | vault propuesto (ejecutable desde `executableAt`) | verificar que sea esperado; si no, `cancelVaultChange` (guardian) y evaluar compromiso del admin |
| `VaultChangeCancelled` / `VaultUpdated` | cancelación / vault cambiado | confirmar |
| `FeeConfigChangeProposed` | config global propuesta (valores completos en el evento) | verificar; si no es esperada, `cancelFeeConfigChange` |
| `FeeConfigChangeCancelled` | config cancelada | confirmar |
| `FeeConfigUpdated` | config ejecutada (sólo la emite `executeFeeConfigChange`) | confirmar valores |
| `TreasuryChangeProposed` | treasury propuesto | verificar; si no, `cancelTreasuryChange` (guardian) |
| `TreasuryChangeCancelled` / `TreasuryUpdated` | cancelación / treasury cambiado | confirmar |
| `UserFeeOverrideSet` | descuento otorgado (irrevocable hasta `validUntil`) | verificar contra la política comercial |
| `RoleGranted` / `RoleRevoked` (`VAULT_GUARDIAN_ROLE`, `FEE_MANAGER_ROLE`, `DEFAULT_ADMIN_ROLE`), `DefaultAdminTransferScheduled` | cambios de poderes | una revocación masiva de guardians es señal de compromiso del admin |
| `Paused` / `Unpaused` | fees pausadas / restablecidas | `Unpaused` y un `FeeConfigUpdated` con fees pausadas son cambios de fee efectivos (I-V3-02) |

Además, un chequeo periódico de **propuestas maduras**: `pendingVaultExecutableAt`, `pendingFeeConfig().executableAt`
y `pendingTreasuryExecutableAt` distintos de 0 y `≤ now`.

### Q.2 Procedimientos

| Operación | Pasos |
|---|---|
| Cambiar fees | fee manager: `proposeFeeConfig(lower, upper, threshold, fixed, variable)` (configuración completa) → comunicar → a partir de `executableAt`: `executeFeeConfigChange()` **inmediatamente**; si no se va a ejecutar, `cancelFeeConfigChange()` |
| Corregir una propuesta | `cancelFeeConfigChange()` (el propio fee manager puede) → nueva propuesta (el delay vuelve a empezar) |
| Cambiar treasury | admin: `proposeTreasury(nuevo)` → a partir de `executableAt`: `executeTreasuryChange()`; hasta entonces fees y rescues van al treasury actual |
| Cambiar vault | como V2 (`approve(1000)` + `proposeVault`, luego `approve(1000)` + `executeVaultChange`), previa checklist Q.4 |
| Emergencia de fees | `pause()` (admin o fee manager): fee = 0 al instante; no afecta forward, vault ni routing |
| Emergencia de vault | `setRoutingMode(DIRECT_DIRECT)`: sin llamadas al vault y allowance 0 al instante |
| Override comercial | fee manager: `setUserFeeOverride(recipient, fixed, variable, validUntil)` **sólo con la configuración global deseada ya activa** (con fees globales en 0 el único override posible es (0, 0), una exención total que seguiría vigente al activar las fees; I-V3-01); `validUntil` en **segundos** (no milisegundos), finito y acotado; nunca a contratos compartidos o reenviadores; registrar la promesa: no se puede retirar antes de `validUntil` |
| Revocar una cuenta (fee manager o guardian) | admin: `revokeRole(...)` **y** cancelar las propuestas pendientes que esa cuenta haya hecho; sus overrides activos siguen vigentes (I-V3-05) |
| Propuesta madura no ejecutada | **cancelarla** (vault: admin/guardian; fees: admin/guardian/fee manager; treasury: admin/guardian) |

### Q.3 Respuesta a incidentes

- **Propuesta inesperada:** cancelar con cualquier guardian; si el origen es el admin, asumir compromiso: detener el
  flujo de las SRA hacia este Forwarder (off-chain) antes de `executableAt` y planificar la migración.
- **Fee manager comprometido:** el admin revoca el rol (`revokeRole`), cancela la propuesta pendiente, revisa
  overrides emitidos (`UserFeeOverrideSet`; los activos no se pueden revocar) y, si hace falta, `pause()`.
- **Guardian hostil (cancelaciones repetidas):** el admin lo revoca y vuelve a proponer.

### Q.4 Checklist antes de proponer un vault (ERC-4626)

1. `asset() == USDC`, código verificado, sin upgrades inesperados.
2. `previewDeposit(x) > 0` para el **mínimo depósito operativo** de Luca/SRA y montos típicos; revisar redondeo y
   offset de decimales; confirmar que depósitos positivos normales producen shares > 0.
3. `maxDeposit`, pausas y caps del vault (afectan el fallback y la pierna del treasury).
4. Que `deposit()` devuelva un `uint256` ABI correcto (si no, la pierna del usuario revierte completa; P.8).

---

## R. Deployment

| Campo | Valor |
|---|---|
| Red | Base mainnet (chain id 8453) |
| Dirección V3 | `0x66c101cb2617256EC61833B607e3F0d98e0C1968` |
| Tx de deploy | `0x9e10d79ed8f2a4b14a5188f66534b77aed30952c8572d60cae534fdaef40c75a` (bloque **52.958.903**, gas 4.175.586, nonce 261) |
| Tx de approve previa (health check del constructor) | `0x4fa3ef4f32cbf679ddfe6d1b3141e273ac6426883c29933b3f6df7ee9d84ebea` (bloque 52.958.901, gas 55.425, nonce 260) |
| Deployer | `0x18e129122a338f2e6871764fe0e4426dE848Ef99` (CM2, keystore `LucaDeployERC4626`; la clave nunca se mostró ni se exportó) |
| Commit del broadcast | `38cc09f` (source idéntico al de `ae8cd1b`) |
| Costo del health check | 1 unidad de USDC (redondeo del Luca Vault) |
| Configuración | USDC canónico de Base; admin Safe `0x4206…7602` con delay de 3 días; treasury Safe `0x7a5F…843e`; Luca Vault `0xc462…090D`; 7 fee managers = 7 guardians (management); `DIRECT_DIRECT`; fees globales 0 (NONE/NONE); no pausado; sin pending de vault, fees ni treasury; sin overrides |
| V1 / V2 | intactos (no se llamó ninguna función de esos contratos) |
| SRA | **no se modificaron**: V3 queda sin tráfico real hasta la decisión del owner |

Secuencia (evidencia en `audit/raw/v3/predeploy/` y `audit/raw/v3/deploy/`):

1. Dry-run 1 contra "latest": `panic 0x11` **dentro de Aave** (`getReserveNormalizedIncome`, vía el Luca Vault en el
   health check del constructor): la simulación vio `block.timestamp < lastUpdateTimestamp` de la reserva, estado del
   RPC más nuevo que el bloque simulado (el mismo artefacto documentado en V1 I-09). On-chain es imposible
   (`lastUpdateTimestamp ≤ block.timestamp` siempre). Reintento: OK.
2. Diagnóstico: 3 dry-runs con `--fork-block-number head−2` → 3/3 OK; 3 contra "latest" → 1/3 con el mismo panic.
3. Broadcast 1 (contra "latest"): la **simulación previa** falló con el mismo panic y forge **no envió nada** (nonce
   del deployer 260 sin cambios, sin código en la dirección prevista, allowance 0; verificado on-chain).
4. Broadcast 2 con `--fork-block-number head−2 --slow`: approve y deploy confirmados ("ONCHAIN EXECUTION COMPLETE &
   SUCCESSFUL"). La verificación integrada falló porque Basescan aún no indexaba el código ("Unable to locate
   ContractCode").
5. `forge verify-contract` con los constructor args del log: **Pass - Verified** (GUID
   `ctqf6yshnjgcxrrhm2txsd4uqvwxnqdezjs6kkkweraqrbqbcu`).
6. Checks on-chain de solo lectura (`onchain-checks.txt`) y suite post-deploy en fork contra la dirección real.

---

## S. Bytecode Verification

| Verificación | Resultado | Evidencia |
|---|---|---|
| Creation code de la tx = build local (`forge inspect … bytecode`) + constructor args | **idéntico** (18.483 bytes) | `compare-deployment.txt` |
| Constructor args decodificados = configuración de producción (USDC, admin, delay, treasury, vault, routing, 7 managers, 7 guardians) | 8/8 OK | `compare-deployment.txt` |
| Source verificado en Basescan = `src/Forwarder.sol` auditado | **idéntico**; sha256 `22aeb8e536cabe68d5ba3005decb1f43179d38ffc261b032a14085432ffd3d6b` | `verify-check.txt` |
| Compilador / optimizer / EVM / via-IR | `v0.8.30+commit.73712a01`, optimizer on 200 runs, `cancun`, via-IR off | `verify-check.txt` |
| OpenZeppelin | 25 fuentes de OZ v5.7.0 (`cab19933…`) en el standard-json verificado | `verify-check.txt` |
| Runtime desplegado = runtime del source auditado compilado y desplegado con los mismos args (incluye el immutable USDC) | **idéntico** (14.330 bytes; codehash `0x56aace6292b336e20f43338b458c504b72d0496f701ab66cb2ad63a1c7339379`) | `test_PostDeploy_RuntimeCodeMatchesAuditedSource` (fork post-deploy) |
| Selectores removidos responden revert on-chain (`setTreasury`, setters de fees, `setVault`) | 8/8 revierten | `onchain-checks.txt` |

---

## T. Final Assessment

| # | Pregunta | Respuesta | Fundamento |
|---|---|---|---|
| 1 | ¿Existe algún path para activar global fees nuevos antes de 72 horas? | **No.** | Los cinco campos sólo los escribe `_setFeeConfig`, llamado únicamente por `executeFeeConfigChange`, que revierte antes de `executableAt = propuesta + 72 h`; la propuesta no se puede sobreescribir ni acortar. Probado: Slither `vars-and-auth`; Certora `feeConfigOnlyChangesThroughMaturedExecution`, `pendingFeeConfigCannotBeShortened`, `proposeFeeConfigStoresExactProposal`, `executeFeeConfigRevertsBeforeExecutableAt`; fuzz de máquina de estados; invariantes; Echidna; mutantes N01, N03, N15, N19, N33, N43. `unpause()` (admin) reactiva al instante la configuración **activa** (que tampoco pudo cambiar sin delay; I-V3-02) y un override sólo puede bajar la fee |
| 2 | ¿Existe algún path para cambiar treasury antes de 72 horas? | **No.** | `treasury` sólo la escriben el constructor y `_setTreasury` ← `executeTreasuryChange` (revierte antes de `executableAt`). Certora `treasuryOnlyChangesThroughMaturedExecution`, `pendingTreasuryCannotBeShortened`; tests, fuzz, invariantes, Echidna; mutantes N02, N04, N17, N20, N34. Hasta la ejecución, `forward` y rescue pagan al treasury actual |
| 3 | ¿Puede un user override cobrar más que el fee global actual? | **No.** | Fórmula monótona por modelo con `min(override, global)` en runtime (E). Certora: `effectiveFeeMatchesSpecification` y `feeMatchesSpecification` (contrato = especificación) y `effectiveFeeNeverExceedsGlobalFeeAssisted` en PASS; el paso aritmético `a·x ≤ a·y` probado con Z3 en aritmética exacta (las comparaciones directas en Certora terminan en TIMEOUT; L). Además invariante V3 `EffectiveFeeNeverExceedsTheGlobalFee` (8M llamadas en total en la campaña), Echidna `effective_fee_never_above_global` (1M), fuzz 50.000, mutantes N07, N39, N40, N41 |
| 4 | ¿Puede retirarse o empeorarse un override antes de su fecha prometida? | **No.** | Mientras está activo sus valores no pueden subir ni su `validUntil` acortarse, y no hay función de borrado (Certora `activeOverrideIsNeverWorsened`, `overridesOnlyChangeThroughSetUserFeeOverride`; invariante y Echidna de promesas; mutantes N10, N11, N12). Aclaración: la garantía es por componente; un cambio de modelo o threshold (con delay) puede hacer que aplique el otro componente, siempre ≤ global (I-V3-01) |
| 5 | ¿Expired override vuelve automáticamente al default? | **Sí.** | Desde `block.timestamp >= validUntil`, sin transacción: `calculateFeeFor` devuelve literalmente `calculateFee(amount)`. Certora `expiredOverrideIsTheGlobalFee`; tests T−1 / T; mutante N08 |
| 6 | ¿Paused sigue significando fee 0 incluso con override? | **Sí.** | Ambas ramas de `calculateFeeFor` devuelven 0 con `paused()`. Certora `pausedEffectiveFeeIsZero`, `pausedForwardDeliversWholeAmount*`; invariante y Echidna; mutante N09 |
| 7 | ¿El accounting de `forward` sigue siendo exacto? | **Sí.** | `amount = userAmount + effectiveFee`; el usuario recibe exactamente `userAmount` y el treasury la fee (o queda en el Forwarder para el reintento). Certora `forwardUserReceivesAmountMinusFee`, `forwardTreasuryAccounting` y sus versiones para cualquier configuración, routing y override; invariantes `UserGetsExactlyAmountMinusEffectiveFee`, `TreasuryAccounting`, `Conservation`; Echidna; mutantes N13, N14 |
| 8 | ¿La lógica V2 del vault permanece intacta? | **Sí.** | Código textualmente sin cambios; suites, fuzz, invariantes, Echidna y las 26 reglas de Certora de V2 re-ejecutadas en verde; 22/22 mutantes V2 detectados (F) |
| 9 | ¿Hay Critical abiertos? | **No.** | O |
| 10 | ¿Hay High abiertos? | **No.** | O |
| 11 | ¿Hay Medium de contrato abiertos? | **No.** | O (los 3 Low son decisiones de diseño acknowledged) |
| 12 | ¿La dirección desplegada corresponde exactamente al código auditado? | **Sí.** | Creation code idéntico al build local, source verificado en Basescan idéntico (sha256 `22aeb8e5…3d6b`), runtime idéntico al del source auditado desplegado con los mismos argumentos (S) |
| 13 | ¿Recomendás conectar las SRA a V3? | **Sí, desde el punto de vista del contrato**, una vez cumplidas las condiciones operativas de la derecha | Se cumplen los criterios de la sección 46 (abajo). Antes de conectar: (1) alertas en tiempo real de los eventos de Q.1 y un procedimiento probado para cortar el flujo de las SRA (sin eso los delays no protegen); (2) adoptar las reglas operativas: cancelar toda propuesta madura que no se ejecute de inmediato, no crear overrides mientras las fees globales estén en 0 y usar `validUntil` acotado y en segundos; (3) recomendado: al menos un guardian con clave independiente del owner de la Safe y subir el threshold de la Safe (L-V3-03). Después de migrar, considerar quitar los roles de fees en V1/V2 (I-V3-13). La decisión es del owner |

**Criterios de la sección 46:** auditoría completa ejecutada con todas las herramientas en verde (en Certora, los 5
resultados que no son PASS están cubiertos por descomposición verificada y ninguno es un contraejemplo real); sin
Critical; sin High; sin Medium de contrato; bytecode auditado = desplegado; post-deploy fork PASS (37/37 al deploy y
al final).

**Declaraciones finales** (sólo lo demostrado):

- `No post-deployment path can activate a new global fee configuration or a new treasury before the immutable 72-hour delay.`
- `A user fee override can never charge more than the current global fee, cannot be worsened or removed before its validUntil, expires automatically and yields zero fee while fees are paused.`
- `The V2 vault lifecycle, routing, rescue, treasury best-effort delivery and fee calculation (calculateFee) were not modified; forward changed only in the line that selects the fee.`

---

## Reproducibility

Herramientas: Foundry 1.5.1 (`b0a9dd9c`), solc 0.8.30, OpenZeppelin v5.7.0 (`cab19933`), forge-std v1.12.0, Slither
0.11.6 y 0.10.4, Echidna 2.2.5, Certora CLI 8.8.0. `.env` con `BASE_RPC_URL` y `ETHERSCAN_API_KEY` (nunca versionado;
los logs se redactan con el valor de las variables y las claves `anonymousKey` de Certora).

```shell
forge fmt --check && forge build --sizes
forge test --no-match-contract Fork                                                   # 407 tests
FOUNDRY_PROFILE=deep forge test --no-match-contract "Fork|Invariant" --match-test testFuzz   # 36 × 50.000
FOUNDRY_INVARIANT_RUNS=2000 FOUNDRY_INVARIANT_DEPTH=250 forge test --match-path test/ForwarderV3Invariant.t.sol
FOUNDRY_PROFILE=deep forge test --match-path test/ForwarderVaultChangeInvariant.t.sol
FOUNDRY_PROFILE=deep forge test --match-path test/ForwarderInvariant.t.sol
forge test --match-contract ForwarderForkTest                                         # pinned 52.951.000
FORK_BLOCK=0 forge test --match-contract ForwarderForkTest                            # latest
DEPLOYED_FORWARDER=0x66c101cb2617256EC61833B607e3F0d98e0C1968 POST_DEPLOY_FORK_BLOCK=<bloque> \
  forge test --match-contract ForwarderPostDeployForkTest
forge coverage --no-match-coverage "(test|script)/" --no-match-contract Fork --report summary --report lcov
forge test --no-match-contract "Fork|Invariant" --gas-report
slither . --filter-paths "lib/|test/|script/|echidna/|certora/"
SOLC_VERSION=0.8.30 echidna echidna/ForwarderV3Echidna.sol --contract ForwarderV3Echidna --config echidna/echidna-v3.yaml --workers 6
SOLC_VERSION=0.8.30 echidna echidna/ForwarderVaultChangeEchidna.sol --contract ForwarderVaultChangeEchidna --config echidna/echidna-v2.yaml --workers 2
SOLC_VERSION=0.8.30 echidna echidna/ForwarderEchidna.sol --contract ForwarderEchidna --config echidna/echidna.yaml --workers 2
for c in Lifecycle Fees Forward Access Vault Invariants MathMin Recheck Lemmas; do
  SOLC_VERSION=0.8.30 certoraRun certora/conf/ForwarderV3$c.conf --wait_for_results all
done
python3 audit/scripts/lemmas_z3.py                                                    # lemas aritméticos (Z3, exacto)
python3 audit/scripts/certora_table.py <label>=<log> ...                              # tabla por regla
python3 audit/scripts/mutation_v3.py <work dir> <report.md> --jobs 1                  # 65 mutantes
python3 audit/scripts/function_diff.py <(git show feature/forwarder-v2-vault-delay:src/Forwarder.sol) src/Forwarder.sol \
  --labels V2 V3 --rename setFeeConfig=_setFeeConfig
python3 audit/scripts/compare_deployment.py broadcast/DeployForwarder.s.sol/8453/run-1792707186487.json
```
