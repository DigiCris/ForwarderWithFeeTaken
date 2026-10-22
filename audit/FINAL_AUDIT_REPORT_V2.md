# Forwarder V2 — Informe de auditoría del cambio aislado (delay inmutable de 72 h para el vault)

| | |
|---|---|
| Fecha | 2026-10-22 |
| Rama | `feature/forwarder-v2-vault-delay` (desde `feature/forwarder` @ `8687669`, sin reescribir historia) |
| Baseline V1 | `src/Forwarder.sol` sha256 `606d02c7…acf7` (commit `1ef93c9`), desplegado en `0xA7A2Be29D45F0cD465BF4F8775931bfb096d5647`, informe [`FINAL_AUDIT_REPORT_V1.md`](FINAL_AUDIT_REPORT_V1.md) |
| Alcance | Sólo el ciclo de vida del vault: propuesta, delay de 72 h, ejecución, cancelación, guardians, estado pending, eventos/errores, allowances del ciclo y constructor. La lógica V1 (forward, fees, treasury, accounting, rescue, pausa, routing) **no se modificó** y no se re-auditó en profundidad. |
| Evidencia cruda | [`audit/raw/v2/`](raw/v2/) (V1 sigue en `audit/raw/`) |

## Resumen ejecutivo

- **Cambio:** después del deploy, el vault activo sólo puede cambiar mediante `proposeVault` → (72 h) →
  `executeVaultChange`. `VAULT_CHANGE_DELAY = 72 hours` es una constante: no hay setter, bypass ni camino alternativo,
  ni siquiera para `DEFAULT_ADMIN_ROLE`. El admin y los `VAULT_GUARDIAN_ROLE` pueden cancelar una propuesta pendiente.
  El `setVault` inmediato de V1 se eliminó.
- **Aislamiento:** `forward`, `calculateFee`, setters de fees, `pause`/`unpause`, `setTreasury`, `setRoutingMode`,
  `rescueToken`, `rescueNative`, `_deliverToTreasury`, `_vaultHealthCheck`, `_setRoutingMode` y `_setTreasury` están
  **textualmente sin cambios** (código y NatSpec; ver B). `_setVault` sólo cambió por extraer sus 4 líneas de
  validación, sin modificarlas, a `_validateVault`.
- **Resultados (todos ejecutados):**
  - Suite local: 266/266 (176 de las suites V1 + 90 nuevos).
  - Fork de Base: 34/34 en el bloque pinneado y 34/34 en el último bloque.
  - Fuzz dirigido V2: 10 × 50.000 runs.
  - Invariantes V2: 15 × 500.000 llamadas.
  - Echidna V2: 500.339 llamadas, 19/19 propiedades. Regresión del harness V1: 100.212 llamadas, 11/11.
  - Certora V2: 33 reglas y 8 invariantes, "No errors found".
  - Slither: 0 true positives; 1 aviso nuevo e intencional (`timestamp`).
  - Mutation testing V2: 22/22 mutantes detectados.
  - Coverage de `src/Forwarder.sol`: 100% en líneas, statements, branches y funciones.
- **Findings:** 0 Critical, 0 High, 0 Medium de contrato; 2 Low acknowledged y 5 Informational. La Safe admin 1/1 se
  documenta como decisión operativa intencional.
- **Deploy:** `0xCD09f43D738b10584CaBfb2f73C3adA29fc5AD53` (bloque 52.955.151), verificado en Basescan. El código de
  creación es idéntico al build local, el runtime es idéntico al source auditado y la suite post-deploy en fork contra
  la dirección real pasa 32/32.

---

## A. V2 change

### A.1 Qué se agregó

| Elemento | Definición |
|---|---|
| `VAULT_CHANGE_DELAY` | `uint256 public constant VAULT_CHANGE_DELAY = 72 hours;` (259.200 s). Constante de bytecode: no hay setter. |
| `VAULT_GUARDIAN_ROLE` | `keccak256("VAULT_GUARDIAN_ROLE")`. Admin del rol: `DEFAULT_ADMIN_ROLE` (default de AccessControl, sin `_setRoleAdmin`). Sólo habilita `cancelVaultChange`. |
| `pendingVault` | `IERC4626 public pendingVault;` — cero = no hay propuesta. |
| `pendingVaultExecutableAt` | `uint256 public pendingVaultExecutableAt;` — cero = no hay propuesta. |
| `proposeVault(IERC4626 candidate)` | `onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant`. Revierte si ya hay propuesta (`VaultChangeAlreadyPending`), valida el candidato (cero, código, `asset() == USDC`), revierte si el candidato es el vault activo (`VaultAlreadyActive`), guarda `pendingVault = candidate` y `pendingVaultExecutableAt = block.timestamp + 72 h`, emite `VaultChangeProposed`, ejecuta el **mismo** health check real de V1 (`_vaultHealthCheck`, 0,001 USDC del llamador, deposit + redeem, devolución neta) y deja el allowance del candidato en 0. No toca el vault activo, su allowance ni el routing. |
| `executeVaultChange()` | `onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant`. Revierte si no hay propuesta (`NoPendingVaultChange`) o si `block.timestamp < pendingVaultExecutableAt` (`VaultChangeDelayNotElapsed`). Limpia el estado pending y llama `_setVault(candidate)`: re-validación, allowance del vault viejo → 0, **segundo health check real** financiado por el llamador, `vault = candidate`, allowance nuevo según el `routingMode` **vigente al ejecutar**, evento `VaultUpdated`. Cualquier falla revierte todo (el pending queda intacto). |
| `cancelVaultChange()` | `DEFAULT_ADMIN_ROLE` o `VAULT_GUARDIAN_ROLE` (mismo patrón que `pause()`). Exige propuesta pendiente, la limpia y emite `VaultChangeCancelled`. Sin restricción temporal (antes, en o después de `executableAt`). No toca vault, routing, allowances, fees ni treasury. |
| Constructor | Nuevo parámetro `address[] initialVaultGuardians` (rechaza `address(0)`). El vault inicial se sigue activando **sin delay** con su health check (sin cambios). |
| Eventos | `VaultChangeProposed(address indexed currentVault, address indexed pendingVault, uint256 executableAt, address proposer)`, `VaultChangeCancelled(address indexed pendingVault, address indexed cancelledBy)`. `VaultUpdated` se mantiene para el cambio efectivo. |
| Errores | `VaultAlreadyActive(address)`, `VaultChangeAlreadyPending(address)`, `NoPendingVaultChange()`, `VaultChangeDelayNotElapsed(uint256 executableAt)`. |
| Helper | `_validateVault(IERC4626)`: las 4 líneas de validación que estaban en `_setVault`, movidas sin cambios para reutilizarlas en `proposeVault`. |

### A.2 Especificación funcional de V2 y aclaraciones de V1

- **Delay:** ningún vault nuevo puede quedar activo antes de `executableAt = timestamp de la propuesta + 72 h`. Ni el
  admin ni nadie puede reducirlo, reiniciarlo o saltarlo. Revocar guardians no cambia `executableAt`.
- **Una propuesta por vez:** proponer con un pending existente revierte. Primero hay que cancelar o ejecutar.
- **Routing durante pending:** la existencia de un pending no afecta a `forward` ni a `setRoutingMode`, que siguen
  operando sobre el vault activo exactamente como en V1. Al ejecutar se aplica el routing vigente en ese momento.
- **Pausa de fees ≠ emergencia del vault.** `pause()` sigue significando "fee = 0": no fuerza `DIRECT_DIRECT`, no pausa
  `forward`, no cambia routing ni allowances. La respuesta inmediata ante un vault activo con problemas es
  `setRoutingMode(DIRECT_DIRECT)`: deja de llamarlo y pone su allowance en 0. Reemplazarlo lleva ≥ 72 h.
- **Aclaración V1 — retorno malformado en la pierna del usuario:** si el ERC-4626 ejecuta `deposit()` pero devuelve
  returndata ABI malformada (por ejemplo, sin datos), la decodificación del `try/catch` revierte y **todo `forward`
  revierte** en vez de hacer fallback a USDC. Es **intencional**: no se paga USDC directo después de una ejecución cuyo
  resultado no se puede interpretar, porque podría producir un doble pago (el vault pudo haber tomado los fondos y
  emitido shares). El revert atómico deshace la operación completa y los fondos quedan en la SRA. Cubierto por el test
  V1 `test_UserLegRevertsWhenVaultReturnsMalformedData`. Sin cambios de código.
- **Aclaración V1 — shares en 0 por redondeo:** un ERC-4626 puede emitir 0 shares para un depósito positivo por
  redondeo (precio por share alto y/o pocas decimales de share). `forward` no impone un depósito mínimo y el health
  check sólo prueba 0,001 USDC. Ver la recomendación operativa en M.

---

## B. Productive diff

Diff completo: `git diff 8687669 -- src/Forwarder.sol` (`audit/raw/v2/diff/forwarder.diff`). En `src/Forwarder.sol`:
**+97 / −16 líneas**. Comparación función por función (código + NatSpec) generada con
`audit/scripts/function_diff.py` (`audit/raw/v2/diff/function-diff.md`); selectores y storage layout en
`audit/raw/v2/diff/selectors-and-storage.txt`.

### B.1 Funciones y estado

| Function/state | V1 | V2 | Changed? | Reason |
|---|---|---|---|---|
| `forward` | 30 líneas | idéntico | **UNCHANGED** | — |
| `calculateFee` | 11 líneas | idéntico | **UNCHANGED** | — |
| treasury delivery (`_deliverToTreasury`) | 19 líneas | idéntico | **UNCHANGED** | — |
| fee setters (`setFeeConfig`, `setVariableFee`, `setFixedFee`, `setThreshold`, `setLowerFeeModel`, `setUpperFeeModel`, `_checkVariableFee`, `_checkFixedFee`, `_emitFeeConfig`) | — | idénticos | **UNCHANGED** | — |
| rescue (`rescueToken`, `rescueNative`) | — | idénticos | **UNCHANGED** | — |
| routing behavior (`setRoutingMode`, `_setRoutingMode`) | — | idénticos | **UNCHANGED** | — |
| `pause` / `unpause` | — | idénticos | **UNCHANGED** | — |
| `setTreasury` / `_setTreasury` | — | idénticos | **UNCHANGED** | — |
| `_vaultHealthCheck` | 17 líneas | idéntico | **UNCHANGED** | Se reutiliza tal cual en propose y execute |
| `_setVault` | 15 líneas | 12 líneas | Changed (refactor sin cambio de comportamiento) | Sus 4 líneas de validación pasan, idénticas y en la misma posición, a `_validateVault`. Mismo orden de efectos. |
| `_validateVault` | — | 6 líneas | Added | Reutilizar la validación en `proposeVault` sin duplicarla |
| `setVault` (external) | 3 líneas | — | **Removed** | Era el único camino inmediato para cambiar el vault |
| `proposeVault` | — | 13 líneas | Added | Propuesta + health check, sin efecto sobre el vault activo |
| `executeVaultChange` | — | 10 líneas | Added | Único camino post-deploy para cambiar el vault, después del delay |
| `cancelVaultChange` | — | 11 líneas | Added | Cancelación por admin o guardian |
| constructor | 21 líneas | 26 líneas | Changed | Parámetro `initialVaultGuardians` y loop de `_grantRole(VAULT_GUARDIAN_ROLE, …)` (rechaza cero, como los fee managers) |
| Estado | 8 variables propias | +`pendingVault` (slot 8), +`pendingVaultExecutableAt` (slot 9) | Added | Todas las variables V1 conservan slot y offset |
| Constantes | — | +`VAULT_GUARDIAN_ROLE`, +`VAULT_CHANGE_DELAY` | Added | — |
| Eventos / errores | — | +2 eventos, +4 errores | Added | — |
| NatSpec | — | Cabecera del contrato (+2 líneas), `VAULT_TEST_AMOUNT` y `initialVault` (mencionaban `setVault`) | Changed (sólo comentarios) | Reflejar el nuevo ciclo de vida |

**Selectores:** V1 48 → V2 54. Eliminado: `setVault(address)` (`0x6817031b`). Agregados: `proposeVault(address)`,
`executeVaultChange()`, `cancelVaultChange()` (únicas funciones nuevas que escriben estado), `pendingVault()`,
`pendingVaultExecutableAt()`, `VAULT_CHANGE_DELAY()`, `VAULT_GUARDIAN_ROLE()` (getters). Los otros 47 selectores no
cambian.

**Quién escribe `vault`:** sólo `_setVault` (`vault = newVault`), llamada únicamente desde el constructor y desde
`executeVaultChange`. El contrato no es upgradeable, no tiene `delegatecall` ni `selfdestruct`
(`test_RuntimeCodeHasNoDelegatecallOrSelfdestruct`), así que no existe otro camino para escribir `vault`. El printer
`vars-and-auth` de Slither lo confirma (J), y Certora lo prueba para todos los métodos
(`vaultOnlyChangesThroughExecuteAfterDelay`, I.2).

### B.2 Revisión manual del diff

| Tema | Análisis | Conclusión |
|---|---|---|
| Borde del timestamp | `if (block.timestamp < executableAt) revert` ⇒ se ejecuta desde `executableAt` inclusive. Tests: inmediato, `executableAt − 1`, exacto, `+1 año`; fuzz alrededor del borde (±2000 s); Certora `executeRevertsBeforeExecutableAt`; mutantes de borde (M02, M03). | Correcto |
| Manipulación de timestamp | En Base (OP Stack) los timestamps L2 avanzan 2 s por bloque de forma determinística y el desvío respecto de L1 está acotado (`max_sequencer_drift`, minutos). No pueden retroceder. Frente a 72 h es irrelevante. `block.timestamp + 72 h` usa aritmética checked: un timestamp cercano a `2^256` revierte, no da la vuelta (`testFuzz_ExecutableAtCannotOverflow`). | Sin riesgo |
| Front-running cancel/execute | Un guardian puede cancelar justo antes del `execute` del admin. Es su función: en el peor caso, un guardian malicioso sólo puede demorar cambios de vault (griefing), nunca mover fondos; el admin lo revoca y re-propone. Un admin comprometido puede revocar a un guardian antes de que cancele, pero igual debe esperar las 72 h. Base no tiene mempool pública. | Aceptado (spec) |
| Pending overwrite | `proposeVault` revierte con `VaultChangeAlreadyPending` si hay pending. Unit, fuzz, invariantes, Echidna, Certora `proposeRevertsWhileAChangeIsPending`, mutante M19. | Correcto |
| Pending vencido (stale) | Una propuesta madura no vence: el admin puede ejecutarla en cualquier momento posterior. Ver L-V2-01 (Low, acknowledged). | Recomendación operativa |
| Remoción de guardians | El admin revoca guardians al instante (`revokeRole`); los guardians pueden renunciar. `executableAt` no cambia (unit, fuzz `testFuzz_GuardianChangesKeepTheDelay`, invariantes, Echidna, Certora `guardianRoleChangesKeepPendingChange` y `pendingChangeCannotBeShortened`, mutante M17). | Correcto (aceptado por spec) |
| Reentrancy | `proposeVault` y `executeVaultChange` son `nonReentrant` y siguen checks-effects-interactions: el estado pending se escribe (propose) o se limpia (execute) **antes** de cualquier llamada externa. `cancelVaultChange` no hace llamadas externas y sigue la convención V1 (sin guard). Tests: el candidato reentrando en execute/propose/forward/`setRoutingMode`/cancel durante propose y execute; el vault activo reentrando en execute desde `forward`; un token reentrando desde `rescueToken`. El chequeo del delay no depende del guard. | Correcto |
| Allowances del health check | En propose, el candidato recibe 1000 unidades temporalmente; el `deposit` las consume y el remanente (vault no conforme) se pone en 0 al terminar. El vault activo no se toca. En execute, `_setVault` pone el vault viejo en 0 **antes** del health check (como V1). | Correcto |
| Ciclo old/current/new allowance | Activo: MAX si el routing usa vault (menos descuentos de USDC), 0 en `DIRECT_DIRECT`. Pending: siempre 0. Viejos: 0 después del execute. Probado con unit (16 pares de routing), fuzz, invariantes, Echidna y Certora (`pendingVaultHasNoAllowance`, `executeAllowancesFollowCurrentRouting`, `executeUsesRoutingInForceAtExecution`). | Correcto |
| Atomicidad del execute fallido | El camino de `executeVaultChange` no tiene `try/catch`: cualquier falla del segundo health check revierte todo, incluida la limpieza del pending. Tests por tipo de falla (deposit, redeem, pausa, sin shares, sin assets, cambio de asset, código removido), recuperación y re-ejecución sin nueva propuesta, mutante M16. | Correcto |
| Routing vigente al ejecutar | `_setVault` lee `routingMode` al ejecutar. Casos A y B y los 16 pares (unit), fuzz, Certora `executeUsesRoutingInForceAtExecution`, mutante M14. | Correcto |
| Supuestos ante compromiso del admin | Con el admin comprometido se pueden revocar guardians y proponer un vault malicioso, pero **no activarlo antes de 72 h**. El delay no protege otras capacidades del admin (ver M). | Documentado |
| Re-proponer el vault activo | Revierte con `VaultAlreadyActive`. Si se permitiera, el reset del allowance del candidato a 0 pisaría el allowance MAX del vault activo en modo vault (violaría "no modificar el allowance del vault activo"). Consecuencia: el allowance MAX decrementado por USDC ya no se "refresca" re-seteando el mismo vault; se refresca saliendo y volviendo a un modo vault (I-V2-02). | Agregado necesario |

---

## C. Vault state machine

```text
ACTIVE VAULT (constructor: vault inicial sin delay)
     |
     | proposeVault(candidate)            [admin; sin pending; candidato válido ≠ activo; health check #1]
     v
PENDING VAULT
 executableAt = now + 72h                 (vault activo, su allowance y el routing NO cambian; candidato sin allowance)
     |                         |
     | cancelVaultChange       | executeVaultChange      [admin; block.timestamp >= executableAt; health check #2]
     | (admin o guardian,      |   si falla cualquier paso: revert total, el pending queda igual
     |  en cualquier momento)  v
     v                     NEW ACTIVE VAULT
NO PENDING                 (viejo → allowance 0; nuevo → MAX si el routing vigente usa vault, si no 0; pending limpio)
```

| Desde | Acción | Quién | Condición | Hacia | Efectos |
|---|---|---|---|---|---|
| sin pending | `proposeVault(c)` | admin | `c` contrato, `asset()==USDC`, `c ≠ vault`, health check OK, llamador aprobó 1000 | pending(c) | `pendingVault=c`, `executableAt=now+72h`, `VaultChangeProposed`, allowance(c)=0 |
| pending | `proposeVault(*)` | cualquiera | — | (revert) | `VaultChangeAlreadyPending` |
| pending | `cancelVaultChange()` | admin / guardian | — (sin límite temporal) | sin pending | pending=0, executableAt=0, `VaultChangeCancelled` |
| pending | `executeVaultChange()` | admin | `now < executableAt` | (revert) | `VaultChangeDelayNotElapsed(executableAt)` |
| pending | `executeVaultChange()` | admin | `now ≥ executableAt` y health check #2 OK | sin pending, vault=c | allowance(viejo)=0, allowance(c)=MAX/0 según routing vigente, `VaultUpdated` |
| pending | `executeVaultChange()` | admin | `now ≥ executableAt` y health check #2 falla | pending (igual) | revert total |
| sin pending | `executeVaultChange()` / `cancelVaultChange()` | — | — | (revert) | `NoPendingVaultChange` |
| cualquiera | `grantRole`/`revokeRole`/`renounceRole` (guardian) | admin / el propio guardian | — | mismo estado | `executableAt` no cambia |
| cualquiera | `setRoutingMode(m)` | admin | como V1 | mismo estado | sólo el allowance del vault **activo** (como V1) |

---

## D. Tests nuevos

Archivos nuevos: `test/ForwarderVaultChange.t.sol` (65 tests unitarios), `test/ForwarderVaultChangeFuzz.t.sol` (10 fuzz),
`test/ForwarderVaultChangeInvariant.t.sol` + `test/invariants/VaultChangeHandler.sol` (15 invariantes),
`test/mocks/VaultChangeMocks.sol` (`AssetSwitchVault`). En `test/ForwarderVaultAndRescue.t.sol`, la suite del health
check (antes vía `setVault`) se convirtió a `proposeVault`/`executeVaultChange` (20 tests) y en `test/fork/ForkTestBase.sol`
se agregaron 8 tests de ciclo de vida sobre vaults reales.

| Requisito (sección 18 del pedido) | Tests |
|---|---|
| **propose:** admin puede | `test_AdminProposes` |
| fee manager / guardian / stranger no | `test_RevertWhen_FeeManagerProposes`, `test_RevertWhen_GuardianProposes`, `test_RevertWhen_StrangerProposes`, `testFuzz_OnlyAdminProposesOrExecutes` |
| guarda el candidato; `executableAt` = now + 72 h exacto | `test_AdminProposes`, `test_ExecutableAtIsExactlyProposalTimePlus72Hours`, `testFuzz_ExecutableAtIsProposalTimePlusDelay` |
| no cambia vault activo, routing ni allowance activo; candidato con allowance 0 | `test_AdminProposes`, `test_ProposeInVaultModeKeepsActiveVaultAllowanceAndRouting` (allowance decrementado exacto), `test_HealthCheckRefundsAssetsTheVaultDidNotPull` |
| segunda propuesta con pending revierte | `test_RevertWhen_ProposingWhileAChangeIsPending` (incluso con la primera ya ejecutable), `test_Fork_SecondProposalRequiresCancellation` |
| otros | `test_ProposeAgainAfterCancellationRestartsTheDelay`, `test_ProposeAgainAfterExecution`, `test_ProposeDoesNotTouchFeesTreasuryOrPause`, `test_RevertWhen_ProposingTheActiveVault`, `test_RevertWhen_ProposingTheActiveVaultInVaultMode` |
| **candidato inválido** (cobertura V1 reutilizada) | zero `test_RevertWhen_VaultIsZero`; EOA `test_RevertWhen_VaultIsEoa`; no ERC-4626 `test_RevertWhen_VaultIsNotErc4626`; asset incorrecto `test_RevertWhen_VaultAssetIsNotUsdc`; falla deposit `test_RevertWhen_VaultDepositFails` / `test_RevertWhen_VaultIsPaused`; zero shares `test_RevertWhen_VaultMintsNoShares`; falla redeem `test_RevertWhen_VaultRedeemFails`; zero assets `test_RevertWhen_VaultRedeemReturnsNothing`; sin fondeo `test_RevertWhen_CallerDidNotFundHealthCheck`; rounding válido `test_VaultWithRoundingLossIsAccepted`; menos que lo depositado pero > 0 `test_VaultReturningLessThanDepositedIsAccepted`, `testFuzz_HealthCheckAcceptsAnyPositiveReturn` (ambos health checks); fondos del Forwarder intactos `test_HealthCheckNeverUsesForwarderFunds`; sólo redime shares nuevas `test_HealthCheckOnlyRedeemsNewShares`; sin estado parcial `test_FailedHealthCheckLeavesNoPartialState`; fork `test_Fork_RejectInvalidVaults` |
| **cancel:** admin; guardian; varios guardians | `test_AdminCancels`, `test_GuardianCancels`, `test_EveryGuardianCanCancel` |
| fee manager sin guardian no; stranger no | `test_RevertWhen_FeeManagerWithoutGuardianRoleCancels`, `test_RevertWhen_StrangerCancels`, `testFuzz_CancelAuthorization` |
| antes / exactamente a las 72 h / después | `test_CancelBeforeTheDelay`, `test_CancelExactlyAtExecutableAt`, `test_CancelAfterTheDelay`, `test_Fork_GuardianCancelsPendingVaultChange` (ya ejecutable) |
| limpia pending; no toca vault, allowance activo ni routing | `test_CancelKeepsActiveVaultAllowanceAndRouting`, `test_CancelDoesNotTouchFeesTreasuryOrPause`, `test_CancelledChangeCannotBeExecuted`, `test_RevertWhen_NothingIsPending` |
| roles independientes | `test_FeeManagerWithGuardianRoleCancelsAndKeepsFeePowers` |
| **guardian lifecycle:** sólo admin grant/revoke | `test_OnlyAdminGrantsAndRevokesGuardians` |
| guardian revocado no cancela | `test_RevokedGuardianCannotCancel` |
| revocar guardian / TODOS no cambia `executableAt`; sin guardians, execute antes de 72 h sigue revirtiendo | `test_RevokingAGuardianDoesNotChangeExecutableAt`, `test_RevokingAllGuardiansDoesNotShortenTheDelay`, `test_GrantingAndRenouncingGuardiansDoesNotChangeExecutableAt`, `testFuzz_GuardianChangesKeepTheDelay`, `test_Fork_RevokingGuardiansDoesNotShortenTheDelay` |
| guardian sin otros poderes | `test_GuardianHasNoOtherPower` (13 funciones privilegiadas), `test_Fork_GuardianCannotProposeOrExecute` |
| rotación del admin | `test_AdminRotationDoesNotChangeExecutableAt` |
| **execute:** inmediatamente revierte; un segundo antes revierte | `test_RevertWhen_ExecutingImmediately`, `test_RevertWhen_ExecutingOneSecondEarly`, `testFuzz_DelayBoundary`, `testFuzz_DelayBoundaryNeighbourhood` |
| exactamente en `executableAt` funciona; después funciona | `test_ExecuteExactlyAtExecutableAt`, `test_ExecuteLongAfterExecutableAt` |
| sólo admin (guardian / fee manager / stranger no) | `test_RevertWhen_GuardianExecutes`, `test_RevertWhen_FeeManagerExecutes`, `test_RevertWhen_StrangerExecutes`, `testFuzz_OnlyAdminProposesOrExecutes` |
| otros | `test_RevertWhen_NothingIsPending`, `test_RevertWhen_ExecutionIsNotFunded`, `test_ExecutionDoesNotTouchFeesTreasuryOrPause`, `test_ForwardUsesTheNewVaultAfterExecution` |
| **segundo health check** (mock mutable: propose PASS → el candidato cambia → execute FAIL → todo igual → recuperación → execute OK sin nueva propuesta) | `test_RedeemStartsFailingAfterProposal`, `test_DepositStartsFailingAfterProposal`, `test_CandidatePausedAfterProposal`, `test_CandidateStopsMintingSharesAfterProposal`, `test_CandidateStopsReturningAssetsAfterProposal`, `test_CandidateAssetChangesAfterProposal`, `test_CandidateCodeRemovedAfterProposal`, `test_FailedExecutionCanBeCancelled`, `testFuzz_FailedSecondHealthCheckKeepsPending`, fork `test_Fork_FailedExecutionKeepsPendingChange` (pausa real del Luca Vault por su controller) |
| **ejecución exitosa:** viejo 0; vault = candidato; pending y timestamp en 0; allowance nuevo según routing; eventos | `test_SuccessfulExecutionInDirectDirect` (cuenta eventos: 1 `VaultUpdated`, 0 propose/cancel), `test_SuccessfulExecutionInEachVaultMode`, `test_ExecuteVaultChange` |
| **routing durante pending** — Caso A y Caso B | `test_CaseA_DirectDirectSelectedWhilePending`, `test_CaseB_VaultVaultSelectedWhilePending`, `test_RoutingAtExecutionDecidesForEveryPair` (16 pares), `test_RoutingChangesNeverGiveAllowanceToThePendingVault`, `test_ForwardWhilePendingUsesTheActiveVault`, `testFuzz_RoutingWhilePending`, fork `test_Fork_RoutingToDirectWhilePending` / `test_Fork_RoutingToVaultWhilePending` |
| **reentrancy:** durante propose | `test_CandidateCannotReenterExecuteDuringProposal`, `test_CandidateVaultCannotReenterProposeDuringHealthCheck`, `test_CandidateVaultCannotReenterForwardDuringHealthCheck`, `test_ReentrantCancelDuringProposalLeavesConsistentState` |
| durante execute | `test_CandidateCannotReenterExecuteDuringExecution`, `test_CandidateCannotReenterProposeDuringExecution`, `test_CandidateCannotReenterForwardDuringExecution`, `test_CandidateCannotReenterSetRoutingModeDuringExecution`, `test_ReentrantCancelDuringExecutionFindsNothingPending` |
| ninguna reentrada ejecuta antes del delay | `test_ActiveVaultCannotReenterExecuteFromForward`, `test_NoReentrantPathExecutesBeforeTheDelay`, `test_ProposeVaultCannotBeReenteredFromForward` |
| **constructor** | `test_RevertWhen_DeployZeroGuardian`, `test_DeployWithoutGuardians`, `test_DeployActivatesInitialVaultWithoutDelay`, `test_DeployEmitsConfigurationEvents` (eventos `RoleGranted` de guardians), `test_InitialState`, `test_Constants` |
| **fork Base mainnet** (USDC, Luca Vault, Steakhouse USDC, Safes reales) | `test_Fork_VaultChangeLifecycleWithRealVaults` (deploy, vault inicial, allowance 0, propose, candidato sin allowance, execute antes de 72 h y en `executableAt − 1` revierte, warp, execute, allowances reales, `forward` antes/durante/después), `test_Fork_GuardianCancelsPendingVaultChange`, `test_Fork_GuardianCannotProposeOrExecute`, `test_Fork_RevokingGuardiansDoesNotShortenTheDelay`, `test_Fork_RoutingToDirectWhilePending`, `test_Fork_RoutingToVaultWhilePending`, `test_Fork_FailedExecutionKeepsPendingChange`, `test_Fork_SecondProposalRequiresCancellation`, `test_Fork_HealthCheckOnLucaVaultAcceptsRounding` (ambos health checks sobre el Luca Vault real: 999/1000) |

---

## E. Regression V1

Todas las suites existentes se ejecutaron sobre V2 como regresión. Las que usaban `setVault` se adaptaron al nuevo
ciclo (helper `_replaceVault` = propose → warp a `executableAt` → execute). Esas adaptaciones son el único cambio en
tests V1. Los tests de fees, `forward`, treasury, accounting, fallback y rescue no se modificaron.

| Suite | Tests | Resultado | Adaptación |
|---|---|---|---|
| `Forwarder.t.sol` (constructor, fees, roles, validación) | 70 (V1: 67) | PASS | Constructor con guardians (+3 tests); listas de llamadas admin-only con `proposeVault`/`executeVaultChange`/roles de guardian |
| `ForwarderRouting.t.sol` (routing, fallback, treasury, donaciones, ceros, allowances) | 39 | PASS | Reemplazos de vault vía lifecycle; refresco de allowance vía routing (ver I-V2-02) |
| `ForwarderVaultAndRescue.t.sol` (health check, rescue, reentrancy) | 42 (V1: 40) | PASS | Health check vía `proposeVault`/`executeVaultChange` |
| `ForwarderFuzz.t.sol` | 13 × 1.000 runs | PASS | Health check en ambos pasos; llamadas no autorizadas con un pending maduro |
| `ForwarderInvariant.t.sol` | 12 × 256 runs × 64 | PASS | Acción `replaceVault` vía lifecycle completo |
| **Total local** (`forge test --no-match-contract Fork`) | **266** (176 de suites V1 + 90 nuevos) | **266/266 PASS** | — |
| Fork pre-deploy, bloque pinneado 52.951.000 (posterior al deploy de V1) | 34 (22 base + 8 lifecycle + 4 deploy) | **34/34 PASS** | `audit/raw/v2/fork/fork-pinned-52951000.txt` |
| Fork pre-deploy, último bloque (52.954.790) | 34 | **34/34 PASS** | `audit/raw/v2/fork/fork-latest.txt` |

Los 16 casos de fee models (lower × upper) siguen existiendo y funcionando: `test_AllModelCombinationsAroundThreshold`
(4 × 4 modelos × 5 montos alrededor del threshold, más un monto grande) pasa sin cambios, y `calculateFee` es
textualmente idéntico. El enum `FeeModel` no cambió (no se agregó `PERCENT_PLUS_FIXED`).

**Coverage de `src/Forwarder.sol` V2** (`forge coverage --no-match-coverage "(test|script)/" --no-match-contract Fork`):

| Líneas | Statements | Branches | Funciones |
|---|---|---|---|
| 100,00% (167/167) | 100,00% (200/200) | 100,00% (39/39) | 100,00% (27/27) |

No queda nada sin cubrir (`audit/raw/v2/forge/coverage-summary.txt`, `lcov.info`). En la primera corrida bajo coverage
falló el chequeo de campaña `afterInvariant` de la suite V2 ("cada run llamó `propose` al menos una vez"): la
instrumentación cambia la aleatoriedad y apareció un run sin propuestas. Es un chequeo del test, no una propiedad del
contrato. Se eliminó (la no-vacuidad se demuestra por muestreo, G) y la suite y coverage se re-ejecutaron en verde.
Coverage no sustituye al fuzz ni a la revisión.

Los fork tests usan USDC real, el Luca Vault real, Steakhouse USDC (el mismo vault secundario de V1), la Safe admin y
la Safe treasury reales, y la configuración de producción (`ForwarderDeployConfig`, con los 7 guardians), desplegando
con el script de producción. El health check sobre el Luca Vault real devuelve 999 de 1000 unidades en propose y en
execute (redondeo aceptado).

---

## F. Fuzz (sólo V2)

`test/ForwarderVaultChangeFuzz.t.sol`, **10 tests × 50.000 runs** (`FOUNDRY_PROFILE=deep`, seed `0x4c756361`):
**10/10 PASS** en 310 s (`audit/raw/v2/forge/fuzz-v2-deep.txt`).

| Test | Qué fuzzea |
|---|---|
| `testFuzz_DelayBoundary` | Timestamp de propuesta arbitrario × tiempo transcurrido 0–288 h: antes de 72 h revierte con el error exacto y sin cambios; desde 72 h, ejecuta |
| `testFuzz_DelayBoundaryNeighbourhood` | Lo mismo concentrado en ±2.000 s alrededor del borde |
| `testFuzz_ExecutableAtIsProposalTimePlusDelay` | `executableAt == t + 72 h` para cualquier `t` válido |
| `testFuzz_ExecutableAtCannotOverflow` | Timestamps cercanos a `2^256`: revierte, nunca da la vuelta |
| `testFuzz_OnlyAdminProposesOrExecutes` | Llamador arbitrario, con o sin rol de guardian y de fee manager |
| `testFuzz_CancelAuthorization` | Llamador y momento arbitrarios: cancela ⇔ admin o guardian vigente |
| `testFuzz_GuardianChangesKeepTheDelay` | Secuencias de grant/revoke/renounce/revocar-todos: `executableAt` intacto; sin guardians, execute antes de 72 h revierte |
| `testFuzz_RoutingWhilePending` | Routing al proponer × 6 cambios durante el pending: candidato sin allowance; al ejecutar manda el routing final |
| `testFuzz_FailedSecondHealthCheckKeepsPending` | 5 tipos de falla × demora × routing: revert total, pending intacto, recuperación y ejecución |
| `testFuzz_LifecycleStateMachine` | Secuencias de 32 pasos (propose con candidatos válidos/inválidos, cancel/execute por cualquier actor, saltos de tiempo incluidos los bordes exactos, grant/revoke de guardians, routing, fallas/recuperación del candidato, forwards) contra un modelo de referencia que predice cada resultado; el estado completo se compara después de cada paso |

No-vacuidad de la máquina de estados (muestreo determinista de 300 secuencias, instrumentación temporal no commiteada):
181 propuestas exitosas, 46 ejecuciones exitosas, 42 ejecuciones tempranas rechazadas, 93 cancelaciones, 4 fallas del
segundo health check y 54 ejecuciones no autorizadas rechazadas.

**Campañas V1 profundas no repetidas** (código sin cambios): fee calculation, topes, threshold, accounting de
`forward`, accounting del treasury, rescue. La suite fuzz V1 (13 tests) corrió a 1.000 runs como regresión (E).

---

## G. Invariants (sólo V2)

`test/ForwarderVaultChangeInvariant.t.sol` + `test/invariants/VaultChangeHandler.sol` (17 acciones, modelo de
referencia): **15 invariantes × 2.000 runs × profundidad 250 = 500.000 llamadas por invariante (7,5 M en total),
15/15 PASS, 0 reverts** en 1.380 s (`audit/raw/v2/forge/invariant-v2-deep.txt`).

| # pedido | Invariante | Foundry |
|---|---|---|
| 1, 2 | `pendingVault == 0 ⇔ executableAt == 0` | `invariant_PendingVaultAndTimestampAreConsistent` |
| — | `executableAt == timestamp de la propuesta + 72 h` | `invariant_ExecutableAtIsProposalTimePlusDelay` |
| — | el pending nunca es el vault activo | `invariant_PendingVaultIsNeverTheActiveVault` |
| 3, 4, 5 | propose/cancel nunca cambian el vault activo; sólo un execute exitoso lo cambia | `invariant_ActiveVaultOnlyChangesThroughExecute` (vault, pending y timestamp idénticos al modelo después de cada acción) |
| 6 | execute antes del timestamp nunca cambia el vault | `invariant_NoExecutionBeforeTheDelay` |
| 7 | el pending no mantiene allowance | `invariant_PendingVaultHasNoAllowance` |
| 8, 9, 10 | viejo con allowance 0; nuevo según routing actual; `DIRECT_DIRECT` ⇒ 0 | `invariant_Allowances` (exacto contra el modelo, incluido el descuento de USDC) |
| 11, 12 | guardian no propone ni ejecuta (ni fee managers ni extraños) | `invariant_LifecycleAuthorization` |
| 13 | revocar guardians no cambia `executableAt` (ni ninguna acción que no sea del ciclo) | `invariant_PendingChangeIsNeverTampered` |
| 14 | el admin no puede reducir el delay | `invariant_DelayIsImmutable` (constante + codehash) |
| 15 | execute fallido conserva el pending | `invariant_FailedExecutionKeepsState` |
| 16 | propose/cancel/execute no tocan fees, treasury, pausa ni routing | `invariant_LifecycleKeepsFeesTreasuryAndPause` |
| — | cada resultado coincide con el modelo; el health check nunca usa USDC del Forwarder | `invariant_OutcomesMatchModel` |
| — | roles: admin intacto, guardians = modelo, admin del rol = `DEFAULT_ADMIN_ROLE` | `invariant_RolesMatchModel` |
| — | modo vault ⇒ hay vault | `invariant_VaultModeHasVault` |

No-vacuidad (30 runs de profundidad 200, muestreo con instrumentación temporal): 36 propuestas, 14 ejecuciones
exitosas, 21 cancelaciones, 32 ejecuciones tempranas rechazadas y 21 ejecuciones rechazadas por el segundo health
check. La campaña profunda (2.000 runs × 250) multiplica esos números por ~80.

**No repetido en profundidad:** las 12 invariantes V1 de fees/accounting/treasury corrieron sólo como regresión
(256 runs × 64; E).

---

## H. Echidna

**Harness V2:** `echidna/ForwarderVaultChangeEchidna.sol`, configuración `echidna/echidna-v2.yaml`. El Forwarder se
despliega con vault inicial por constructor, como en producción. Actores como contratos reales: admin, 3 guardians,
un fee manager, un fee manager que además es guardian y un extraño. 4 vaults (uno siempre falla) y 4 candidatos
inválidos (EOA, contrato sin ERC-4626, asset incorrecto, cero). Tiempo: `hevm.warp` (al azar o exactamente a
`executableAt − 1`, `executableAt` y más allá) más el retardo aleatorio de Echidna entre transacciones (hasta 1 semana).

**Acciones (14):** `propose`, `cancel`, `execute`, `warp`, `setGuardian` (grant/revoke), `renounceGuardian`,
`unauthorizedCall` (propose/execute/routing/gestión de guardians por no-admins), `setRoutingMode`, `toggleFailure`
(falla y recuperación del candidato o del activo), `forward`, `setFees`, `togglePause`, `setTreasury`.

**Resultado:** **500.339 llamadas, 19/19 propiedades passing, 0 contraejemplos** (4 workers, 60 min 35 s, seed
`7203172025`, 22.882 instrucciones únicas, 7 codehashes). Log: `audit/raw/v2/echidna/echidna-v2-500k.txt`; cobertura:
`audit/raw/v2/echidna/covered-v2.txt`. En la cobertura figuran ejecutadas las ramas de propuesta exitosa, cancelación,
ejecución exitosa, ejecución temprana rechazada, ejecución rechazada por health check, `warp` y, en
`src/Forwarder.sol`, los reverts `VaultChangeAlreadyPending`, `VaultAlreadyActive` y `VaultChangeDelayNotElapsed`.

| Propiedad V2 | Exige |
|---|---|
| `echidna_pending_vault_and_timestamp_consistent` | pending = 0 ⇔ timestamp = 0 |
| `echidna_executable_at_is_proposal_time_plus_72h` | timestamp = propuesta + 72 h |
| `echidna_pending_vault_is_not_the_active_vault` | pending ≠ activo |
| `echidna_active_vault_only_changes_through_execute` | el vault sólo cambia por execute exitoso; estado = modelo |
| `echidna_no_execution_before_the_delay` | ningún execute exitoso antes de `executableAt` |
| `echidna_pending_vault_has_no_allowance` | allowance del pending = 0 (también tras routing/forward) |
| `echidna_allowances` | allowances exactos contra el modelo; 0 para no activos y en `DIRECT_DIRECT` |
| `echidna_lifecycle_authorization` | ningún no-admin propone/ejecuta/rutea/gestiona guardians; cancel sólo admin/guardian |
| `echidna_pending_change_never_tampered` | ninguna acción ajena al ciclo (incluidos grant/revoke/renounce) cambia pending/timestamp |
| `echidna_failed_execution_keeps_state` | execute fallido conserva pending, vault y allowances |
| `echidna_lifecycle_keeps_fees_treasury_pause_routing` | el ciclo no toca fees, treasury, pausa ni routing |
| `echidna_outcomes_match_model` | éxito ⇔ el modelo lo predice; el health check nunca usa USDC del Forwarder |
| `echidna_roles_match_model` | admin intacto; guardians = modelo; admin del rol |
| `echidna_delay_is_72_hours` | constante |

Propiedades V1 mantenidas como regresión (baratas): `echidna_user_gets_amount_minus_fee`,
`echidna_vault_mode_has_vault`, `echidna_fee_caps`, `echidna_treasury_valid`, `echidna_forwarder_holds_no_shares`.

**Harness V1** (`echidna/ForwarderEchidna.sol`, adaptado: el reemplazo de vault usa el lifecycle con `hevm.warp`),
corrido como regresión con presupuesto reducido: **100.212 llamadas, 11/11 propiedades passing** (309 s, 18.813
instrucciones únicas; `audit/raw/v2/echidna/echidna-v1-harness-regression-100k.txt`). La campaña V1 de 500k sobre
fees/accounting no se repitió (código sin cambios).

---

## I. Certora

### I.1 Pruebas V1 heredadas (no re-ejecutadas)

Las 42 reglas y 6 invariantes de `certora/specs/Forwarder.spec` se probaron sobre el **source V1** (jobs
`3658204/3e6503ed…` y `3658204/79a63e17…`, ver [`FINAL_AUDIT_REPORT_V1.md`](FINAL_AUDIT_REPORT_V1.md) §I). Las que
cubren código sin cambios (fees, `forward`, treasury, rescue) siguen describiendo ese código, pero **no se re-ejecutaron
sobre V2 y no se presentan como PASS de V2**. Esa spec referencia `setVault`, que ya no existe; queda como registro de
V1.

### I.2 Pruebas V2 realmente ejecutadas

`certora/specs/ForwarderV2.spec` (mismo modelo que V1: `DummyUSDC`, `DummyVault`/`DummyVault2`, resúmenes de
SafeERC20; `-enableStorageSplitting false`, `precise_bitwise_ops`, `optimistic_loop`/`loop_iter 3`,
`rule_sanity basic`). Certora CLI 8.8.0.

- Reglas: `certora/conf/ForwarderV2.conf`, job `3658204/abc90974a3064a65ac81eaa3568bfc23` —
  **"No errors found by Prover!"**. 32 de las 33 reglas tienen su línea `Result for … SUCCESS`. Para
  `feeManagerRoleOnlyChangedByAdminOrSelf`, el stream no imprimió la línea de resultado ni el testigo de no-vacuidad
  de su instancia `executeVaultChange()`. No se la contó como probada hasta re-ejecutarla sola: job
  `3658204/ca5d97f106c64b67a97a56042ca0f3d6`, **SUCCESS** en los 24 métodos y 24/24 testigos de no-vacuidad
  (`audit/raw/v2/certora/run3-recheck.*`).
- Invariantes: `certora/conf/ForwarderV2Invariants.conf`, job `3658204/a8f16e813a184f288ce45c5393b859cc` —
  **"No errors found by Prover!"**, 8/8 invariantes `SUCCESS` (caso base + paso inductivo por método).

Veredictos por regla: `audit/raw/v2/certora/run2-*.summary.txt`; logs completos (claves redactadas):
`audit/raw/v2/certora/run2-*.log`. En el log, las líneas `Violated: …-rule_not_vacuous` e
`…-invariant_not_trivial_postcondition` son los chequeos de sanidad (formulados como `assert false`): "violated" significa
que la regla es alcanzable o que la invariante no es trivial, es decir, el resultado esperado. La corrida 1 (jobs
`ac15c7e9…`, `7ea82dac…`) se envió sin esperar resultados y se reemplazó por la corrida 2. El prover emitió un mensaje
interno `FUNCTION_BUILDER` sobre `Math.ternary` dentro de `changeDefaultAdminDelay` de OpenZeppelin; no afecta a las
reglas: todas las instancias paramétricas de ese método figuran `Verified`.

| Grupo | Regla / invariante | Resultado |
|---|---|---|
| Autorización | `onlyAdminProposes`, `onlyAdminExecutes`, `onlyAdminOrGuardianCancels` | SUCCESS |
| | `guardianOrAdminCanAlwaysCancel` (liveness: un guardian o el admin siempre puede cancelar un pending) | SUCCESS |
| | `guardianCannotProposeOrExecute` | SUCCESS |
| | `feeManagerCannotAdministerVault` (fee manager sin admin/guardian: vault, pending y timestamp intactos para cualquier método) | SUCCESS |
| | `unprivilegedCannotTouchVaultLifecycle` (sin roles: idem) | SUCCESS |
| | `guardianRoleOnlyChangedByAdminOrSelf` | SUCCESS |
| Delay | `vaultChangeDelayIs72Hours` | SUCCESS |
| | `proposeStoresCandidateWithExactDelay` (pending = candidato, `executableAt = timestamp + 259.200`, vault/routing/allowance activos intactos) | SUCCESS |
| | `executeRevertsBeforeExecutableAt` (cualquier llamador, cualquier estado) | SUCCESS |
| | `vaultOnlyChangesThroughExecuteAfterDelay` (paramétrica: el vault sólo cambia por `executeVaultChange` del admin, con `timestamp ≥ executableAt`, al pending) — adaptación de `onlyAdminChangesVault` | SUCCESS |
| | `pendingChangeCannotBeShortened` (paramétrica: ningún método modifica el timestamp de un pending; un pending nuevo sólo nace de `proposeVault` con `+259.200`) | SUCCESS |
| | `guardianRoleChangesKeepPendingChange` (grant/revoke/renounce) | SUCCESS |
| Pending | `proposeRevertsWhileAChangeIsPending`, `executeRevertsWithoutPendingChange` | SUCCESS |
| | `cancelClearsPendingOnly`, `executeActivatesPendingVaultAndClearsIt`, `failedExecutionKeepsState` (por atomicidad del EVM) | SUCCESS |
| | `pendingOnlyClearedByCancelOrExecute` (paramétrica), `vaultLifecycleKeepsConfiguration` | SUCCESS |
| Allowances | `proposeLeavesNoCandidateAllowance`, `executeAllowancesFollowCurrentRouting` (adaptación de `setVaultAllowances`), `executeUsesRoutingInForceAtExecution` (cambio de routing durante el pending: casos A, B y todos los pares) | SUCCESS |
| | `forwardKeepsPendingChange`, `proposeHealthCheckUsesOnlyCallerFunds`, `executeHealthCheckUsesOnlyCallerFunds` (adaptaciones de `healthCheckUsesOnlyCallerFunds`) | SUCCESS |
| V1 re-ejecutadas sobre V2 (texto sin cambios) | `onlyAdminChangesVault`, `feeManagerCannotAdminister`, `unprivilegedChangesNoConfiguration`, `routingModeAllowance`, `forwardNeverApproves` | SUCCESS |
| | `feeManagerRoleOnlyChangedByAdminOrSelf` | SUCCESS (re-ejecución `ca5d97f1…`) |
| Invariantes V1 re-ejecutadas | `enumsAreValid`, `vaultModeHasVault`, `feeManagerAdminIsDefaultAdmin`, `directDirectMeansNoVaultAllowance` | SUCCESS |
| Invariantes V2 | `guardianAdminIsDefaultAdmin`, `pendingVaultConsistency`, `pendingVaultIsNotActive`, `pendingVaultHasNoAllowance` | SUCCESS |

**Límite del modelo:** los candidatos se modelan como `DummyVault`/`DummyVault2` (despacho optimista). Los candidatos
inválidos (EOA, sin ERC-4626, asset incorrecto) y los vaults reales se cubren con Foundry y el fork.

---

## J. Slither

Corrida completa sobre V2 con **Slither 0.11.6** (crytic-compile 0.4.2, 102 detectores) y **Slither 0.10.4** (93
detectores), mismo filtro que V1 (`lib/|test/|script/|echidna/|certora/`). Salidas completas (texto, JSON y printers
`human-summary`, `vars-and-auth`, `modifiers`, `require`, `function-summary`) en `audit/raw/v2/slither/`.

**Comparación con V1:** 0.11.6: V1 13 → V2 **14**. 0.10.4: V1 11 → V2 **12**. Los 13 (11) avisos de V1 siguen
presentes con el mismo detector, la misma función y la misma causa (sólo cambian los números de línea). Hay **1 aviso
nuevo** (`timestamp`) y **ninguno desaparecido**. Slither **no** reporta reentrancy en `proposeVault` ni en
`executeVaultChange`, porque escriben o limpian el estado pending antes de las llamadas externas.

| ID | Detector | Severity / Confidence | Ubicación V2 | V1 | Análisis | Clasificación |
|---|---|---|---|---|---|---|
| S-01 | `reentrancy-balance` | High / Medium | `_vaultHealthCheck` (shares, L498-L500) | = S-01 | Sin cambios de código. Medición intencional del delta de shares; en V2 lo invocan `proposeVault` y `executeVaultChange` (`nonReentrant`) y el constructor. | False positive |
| S-02 | `reentrancy-balance` | High / Medium | `_vaultHealthCheck` (assets, L503-L505) | = S-02 | Idem con USDC alrededor de `redeem`. El candidato sólo tiene allowance de 1000 (fondos del llamador); el refund con aritmética checked impide usar fondos del Forwarder (Certora `proposeHealthCheckUsesOnlyCallerFunds`/`executeHealthCheckUsesOnlyCallerFunds`). En propose el vault activo mantiene su allowance, pero el candidato no puede usarlo (el spender es otra dirección). | False positive |
| S-03 | `incorrect-equality` | Medium / High | `_deliverToTreasury` `balance == 0` | = S-03 | Código sin cambios. | False positive |
| S-04 | `incorrect-equality` | Medium / High | `_vaultHealthCheck` `shares == 0` | = S-04 | Requisito (shares > 0). | False positive |
| S-05 | `incorrect-equality` | Medium / High | `_vaultHealthCheck` `assets == 0` | = S-05 | Requisito (assets > 0). | False positive |
| S-06 | `reentrancy-no-eth` | Medium / Medium | `_setVault`: escribe `vault` después del health check | = S-06 | Mismo patrón que V1: el vault sólo se acepta después del round-trip. En V2 `_setVault` sólo se llama desde el constructor y desde `executeVaultChange` (`nonReentrant`, con el pending ya limpio); las funciones que leen `vault` para escribir allowances (`setRoutingMode`) son `nonReentrant`. Tests de reentrancy del candidato durante execute. | False positive |
| S-07 | `uninitialized-local` | Medium / Medium | `forward`: `userVaultDeposit` | = S-07 | Código sin cambios. | False positive |
| S-08 | `uninitialized-local` | Medium / Medium | `forward`: `userShares` | = S-08 | Código sin cambios. | False positive |
| S-09 | `unused-return` | Medium / Medium | `_vaultHealthCheck`: `deposit` | = S-09 | Se miden balances (por diseño). | False positive / by design |
| S-10 | `unused-return` | Medium / Medium | `_vaultHealthCheck`: `redeem` | = S-10 | Idem. | False positive / by design |
| S-11 | `reentrancy-events` | Low / Medium | `_setVault`: `VaultUpdated` después del health check | = S-11 | Debe emitirse después del health check (incluye sus resultados). Protegido por `nonReentrant` en `executeVaultChange`. | Informational |
| S-12 | `low-level-calls` | Informational / High | `_deliverToTreasury` | = S-12 | Intencional (pierna del treasury que nunca revierte). | Informational |
| S-13 | `naming-convention` | Informational / High | `USDC` | = S-13 | Nombre exigido por la especificación. | Informational |
| **S-14** | **`timestamp`** | Low / Medium | `executeVaultChange`: `block.timestamp < executableAt` (L389) | **nuevo** | Es la comparación del delay, intencional. Base no permite manipular el timestamp más que unos segundos dentro de las reglas del sequencer, frente a una ventana de 72 h. Ver B.2. | Informational / by design |

Conclusión: **0 true positives**; ninguna de las nuevas funciones introduce avisos de reentrancy.

El printer `vars-and-auth` confirma el aislamiento de escrituras:

| Función | Variables escritas |
|---|---|
| constructor | `USDC`, roles, `treasury`, **`vault`**, `routingMode` |
| `proposeVault` | `pendingVault`, `pendingVaultExecutableAt` |
| `executeVaultChange` | `pendingVault`, `pendingVaultExecutableAt`, **`vault`** (vía `_setVault`) |
| `cancelVaultChange` | `pendingVault`, `pendingVaultExecutableAt` |
| `_setVault` | **`vault`** |

Ninguna otra función escribe `vault`, `pendingVault` ni `pendingVaultExecutableAt`.

---

## K. Mutation

`audit/scripts/mutation_v2.py`: cada mutante se aplica sobre una copia aislada del repositorio (sin `.env`) y se corre
la suite local completa (`forge test --no-match-contract Fork`). **22/22 mutantes KILLED** (los 15 pedidos + 7
adicionales). Detalle y logs: `audit/raw/v2/mutation/`.

| ID | Mutación | Resultado | Detectado por (ejemplos) |
|---|---|---|---|
| M01 | delay 72 h → 0 | KILLED | `invariant_DelayIsImmutable`, `test_Constants`, `test_AdminProposes` |
| M02 | borde: ejecutar 1 s antes | KILLED | `test_RevertWhen_ExecutingOneSecondEarly`, `test_RevokingAllGuardiansDoesNotShortenTheDelay` |
| M03 | borde: rechazar exactamente en `executableAt` | KILLED | `test_ExecuteVaultChange`, `test_SuccessfulExecutionInDirectDirect` |
| M04 | execute sin chequeo de delay | KILLED | `test_RevertWhen_ExecutingImmediately`, `test_NoReentrantPathExecutesBeforeTheDelay` |
| M05 | guardian puede ejecutar | KILLED | `test_RevertWhen_GuardianExecutes`, `test_GuardianHasNoOtherPower` |
| M06 | guardian puede proponer | KILLED | `test_RevertWhen_GuardianProposes`, `test_FeeManagerWithGuardianRoleCancelsAndKeepsFeePowers` |
| M07 | fee manager puede proponer | KILLED | `test_RevertWhen_FeeManagerProposes`, `test_FeeManagerAndStrangerCannotCallAdminFunctions` |
| M08 | la propuesta cambia el vault activo inmediatamente | KILLED | `test_AdminProposes`, `test_CancelKeepsActiveVaultAllowanceAndRouting` |
| M09 | cancel no limpia el pending | KILLED | `test_AdminCancels`, `test_CancelBeforeTheDelay` |
| M10 | execute no limpia el pending | KILLED | `test_SuccessfulExecutionInDirectDirect`, `test_ExecuteExactlyAtExecutableAt` |
| M11 | la propuesta deja allowance ilimitado al candidato | KILLED | `test_AdminProposes`, `test_ProposeInVaultModeKeepsActiveVaultAllowanceAndRouting` |
| M12 | la propuesta no limpia el allowance no usado del health check | KILLED | `test_HealthCheckRefundsAssetsTheVaultDidNotPull` |
| M13 | el vault viejo mantiene su allowance | KILLED | `test_CaseB_VaultVaultSelectedWhilePending`, `test_SuccessfulExecutionInEachVaultMode` |
| M14 | execute usa el routing de la propuesta en vez del actual | KILLED | `test_CaseA_DirectDirectSelectedWhilePending`, `test_CaseB_VaultVaultSelectedWhilePending` |
| M15 | se elimina el segundo health check | KILLED | `test_CandidateAssetChangesAfterProposal`, `test_RedeemStartsFailingAfterProposal` |
| M16 | execute fallido borra la propuesta en vez de revertir | KILLED | `test_CandidateAssetChangesAfterProposal`, `test_CandidateCodeRemovedAfterProposal` |
| M17 | revocar un guardian resetea el timestamp | KILLED | `test_RevokingAGuardianDoesNotChangeExecutableAt`, `test_GrantingAndRenouncingGuardiansDoesNotChangeExecutableAt` |
| M18 | cualquiera puede cancelar | KILLED | `test_RevertWhen_StrangerCancels`, `test_RevertWhen_FeeManagerWithoutGuardianRoleCancels` |
| M19 | una propuesta nueva reemplaza en silencio a la pendiente | KILLED | `test_RevertWhen_ProposingWhileAChangeIsPending` |
| M20 | se puede re-proponer el vault activo | KILLED | `test_RevertWhen_ProposingTheActiveVault`, `…InVaultMode` |
| M21 | execute sin `nonReentrant` | KILLED | `test_CandidateCannotReenterExecuteDuringExecution`, `test_ActiveVaultCannotReenterExecuteFromForward` |
| M22 | el constructor no otorga los guardians iniciales | KILLED | `invariant_RolesMatchModel`, `test_GuardianCancels` |

---

## L. Findings

**Critical: 0 · High: 0 · Medium (contrato): 0 · Low: 2 (acknowledged) · Informational: 5.** Ningún finding requirió
cambiar el código: la revisión manual, los tests, el fuzz, las invariantes, Echidna, Certora y Slither no encontraron
defectos en la implementación V2.

| ID | Severity | Title | Status | Detalle | Recomendación |
|---|---|---|---|---|---|
| L-V2-01 | Low | Una propuesta madura no vence | Acknowledged (por especificación: se puede ejecutar "después de las 72 h") | Si una propuesta legítima queda pendiente después de `executableAt`, quien controle el admin puede activarla en cualquier momento posterior sin una nueva ventana de 72 h. El riesgo práctico es bajo: es un vault propuesto por el equipo, re-validado con un segundo health check real al ejecutar. Sería relevante si ese vault se volviera malicioso después (por ejemplo, un vault upgradeable). | Operativo: cancelar (admin o cualquier guardian) toda propuesta que no se vaya a ejecutar pronto; alertar sobre propuestas maduras pendientes (`pendingVaultExecutableAt <= now`). |
| L-V2-02 | Low | Los guardians son revocables al instante y pueden demorar cambios | Acknowledged (por especificación) | Un admin comprometido puede revocar todos los guardians en una transacción, pero el delay no cambia (probado). Un guardian comprometido sólo puede cancelar propuestas una y otra vez (griefing que demora cambios de vault); no puede mover fondos, proponer, ejecutar ni cambiar el routing. | Monitorear `RoleRevoked(VAULT_GUARDIAN_ROLE)` y `VaultChangeCancelled`; ante un guardian hostil, el admin lo revoca y vuelve a proponer. |
| I-V2-01 | Informational | El delay protege sólo el cambio de vault | Acknowledged (alcance pedido) | Con el admin comprometido se puede, de inmediato, cambiar el treasury, otorgarse `FEE_MANAGER_ROLE` y subir las fees hasta el tope (10 % + 10 USDC por depósito), rescatar saldos al treasury, cambiar el routing entre los modos del vault activo y gestionar roles. El delay sólo impide activar un vault nuevo antes de 72 h, que es el vector de mayor impacto (un vault malicioso con allowance ilimitado podría quedarse con el 100 % de los depósitos de usuarios en modo vault). | Monitorear `TreasuryUpdated`, `FeeConfigUpdated`, `RoleGranted` y `VaultChangeProposed`, y poder cortar el flujo de SRA. |
| I-V2-02 | Informational | El vault activo no se puede re-proponer; el allowance se refresca vía routing | By design | `VaultAlreadyActive` evita que el reset del allowance del candidato pise el allowance del vault activo. En V1, `setVault(mismoVault)` restablecía el `MAX` que USDC descuenta en cada depósito (V1 I-03); en V2 se restablece con `setRoutingMode(DIRECT_DIRECT)` + `setRoutingMode(modo vault)` (una batch de la Safe). Agotar `2^256 − 1` no es realista. | Ninguna (documentado en README). |
| I-V2-03 | Informational | Cada propuesta y cada ejecución cuestan el redondeo del health check | Acknowledged | La Safe admin debe aprobar 1000 unidades (0,001 USDC) antes de `proposeVault` y antes de `executeVaultChange` (batch). Con el Luca Vault se recuperan 999 (1 unidad de redondeo por health check). | Usar batches de la Safe (`approve` + llamada). |
| I-V2-04 | Informational | `cancelVaultChange` no es `nonReentrant` | By design (convención V1: sólo llevan guard las funciones con llamadas externas) | No hace llamadas externas. Un cancel reentrante durante una propuesta sólo es posible para una cuenta con rol de admin o guardian y deja un estado consistente (`test_ReentrantCancelDuringProposalLeavesConsistentState`). Durante un execute, el pending ya está limpio y un cancel reentrante revierte (`test_ReentrantCancelDuringExecutionFindsNothingPending`). | Ninguna. |
| I-V2-05 | Informational | Los guardians son las 7 wallets de management | Acknowledged (decisión del usuario) | Son las mismas cuentas que los fee managers, incluida `0xa737…C5db`, único owner de la Safe admin. Varias son EOAs con delegación EIP-7702 (V1 I-06). Frente a un compromiso del admin, la protección de los guardians es tan independiente como lo sean esas claves de la del owner de la Safe. El delay de 72 h aplica igual. | Considerar al menos un guardian cuya clave no sea la del owner de la Safe; revisar las delegaciones 7702 activas. |

**Safe admin 1/1:** es una **decisión operativa intencional** para mantener maniobrabilidad en esta etapa y se registra
como supuesto de confianza (M), no como defecto del contrato ni como bloqueo de producción. Reemplaza al M-01 de V1.

**Findings V1 sin cambios** (código sin cambios): L-03 y I-01, I-02, I-04 a I-08 siguen vigentes tal como están en
[`FINAL_AUDIT_REPORT_V1.md`](FINAL_AUDIT_REPORT_V1.md) §J. I-03 se actualiza con I-V2-02; I-04 se documenta ahora
también en A.2, M y N.

---

## M. Residual Risks

1. **Admin de confianza:** `DEFAULT_ADMIN_ROLE` sigue siendo la autoridad máxima (treasury, fees vía rol, rescue,
   routing, roles). El delay de 72 h **sólo** protege la activación de un vault nuevo (I-V2-01).
2. **Safe admin 1/1 (intencional):** una sola clave (`0xa737…C5db`) controla el admin. Es una decisión operativa
   deliberada. Si esa clave se compromete, el atacante puede revocar guardians y proponer un vault malicioso, pero
   **no puede activarlo antes de 72 h**.
3. **Guardians revocables:** el admin los revoca al instante (L-V2-02). Lo que no puede quitarse es el delay.
4. **72 h como ventana de respuesta:** la protección real depende de **detectar** `VaultChangeProposed` (y las
   revocaciones de guardians) y de que Luca **corte el flujo hacia las SRA** antes de `executableAt`. Sin monitoreo ni
   procedimiento de corte, el delay no evita la pérdida. Recomendación: alertas en tiempo real para
   `VaultChangeProposed`, `RoleRevoked`/`RoleGranted`, `TreasuryUpdated` y `FeeConfigUpdated`, y un runbook para
   detener nuevos depósitos.
5. **Vault de confianza:** el vault activo tiene allowance ilimitado mientras el routing lo usa, y su comportamiento
   (pausas, caps, redondeos, upgrades) afecta las piernas que lo usan. Mitigación inmediata: `DIRECT_DIRECT`.
6. **Returndata malformada en la pierna del usuario:** un vault que ejecuta `deposit()` pero devuelve datos ABI
   malformados hace revertir todo `forward` (sin fallback), por decisión intencional: evitar un doble pago después de
   un resultado ininterpretable. Los fondos quedan en la SRA (revert atómico).
7. **Shares en 0 por redondeo:** un ERC-4626 puede emitir 0 shares para un depósito positivo. `forward` no impone un
   mínimo y el health check usa 0,001 USDC. **Recomendación operativa antes de proponer un vault:** verificar
   `previewDeposit` para el depósito mínimo operativo de Luca/SRA, revisar el redondeo y el offset de decimales del
   vault, y confirmar que todos los montos operativos positivos producen shares > 0. No se agregó un depósito mínimo
   ni se modificó `forward`.
8. **Entrega al treasury best-effort:** los fondos pueden quedar retenidos en el Forwarder hasta el próximo `forward`,
   un rescate o un cambio de treasury/routing.
9. **Circle / USDC:** Circle puede pausar USDC, poner cuentas en blacklist o actualizar el contrato. Un usuario en
   blacklist no puede recibir y su depósito queda en la SRA.
10. **Propuestas maduras sin ejecutar** (L-V2-01) y **fee managers** sin timelock dentro de los topes (V1 L-03/I-05).

---

## N. Deviations

Ninguna desviación cambia el comportamiento pedido. Diferencias de forma, agregados y aclaraciones:

| ID | Diferencia | Motivo | Impacto funcional |
|---|---|---|---|
| N-1 | `proposeVault` rechaza el vault activo (`VaultAlreadyActive`), caso que el pedido no contemplaba | Sin el chequeo, el reset del allowance del candidato pisaría el allowance del vault activo en modo vault (violaría "no modificar el allowance del vault activo") | Ninguno para usos válidos; ver I-V2-02 |
| N-2 | Orden checks-effects-interactions: `proposeVault` guarda el pending y emite el evento **antes** del health check; `executeVaultChange` limpia el pending **antes** de `_setVault` | Evita escrituras de estado después de llamadas externas (Slither no reporta reentrancy en las funciones nuevas) | Ninguno: cualquier falla revierte todo, así que el resultado es el mismo que en el orden de la especificación |
| N-3 | `executeVaultChange` repite también la validación (código, `asset() == USDC`), no sólo el health check | Reutiliza `_setVault` completo sin duplicar lógica; atrapa un candidato que cambió de asset o perdió código | Más estricto |
| N-4 | `cancelVaultChange` revierte con `AccessControlUnauthorizedAccount(sender, VAULT_GUARDIAN_ROLE)` | Mismo patrón que `pause()` | Ninguno |
| N-5 | El refresco del allowance `MAX` decrementado por USDC pasa de `setVault(mismo)` a un cambio de routing | Consecuencia de N-1 y de eliminar `setVault` | Ninguno práctico |
| N-6 | Guardians iniciales = las 7 wallets de management (las mismas que los fee managers) | Decisión del usuario ("dar el rol a los management"). Lista en `ForwarderDeployConfig.vaultGuardians()`; `run()` no transmite con lista vacía; el preflight rechaza cero, duplicados y el admin | Ninguno |
| N-7 | (V1, documentado ahora) Returndata malformada del vault en la pierna del usuario ⇒ revierte todo `forward` en vez de hacer fallback | Intencional: evitar doble pago (A.2, M.6) | Los fondos quedan en la SRA |
| N-8 | El vault inicial del constructor no tiene delay | Pedido explícito (sección 13) | Ninguno |
| N-9 | Las desviaciones de forma de V1 (L-D1 a L-D11) siguen vigentes | Código sin cambios | Ver V1 §L |

---

## O. Deployment

### O.1 Antes del broadcast

- Regresión final: suite local 266/266; fork 34/34 en el bloque pinneado 52.951.000 y 34/34 en el último bloque
  (52.954.790), ambos con la configuración final (7 guardians).
- Dry-run (`forge script … --sender CM2`, sin broadcast; `audit/raw/v2/deploy/dry-run.txt`): preflight OK (chain 8453,
  USDC, Safes con código, `asset() == USDC`, sin duplicados ni ceros y el admin no es guardian), dirección predicha
  `0xCD09…AD53`, costo del health check 1 unidad, gas estimado 4.843.728.
- Source desplegado: `src/Forwarder.sol` sha256 `2ddd2b60cbf172b9218b34505de6fead9dd8e56c15f80133198e16b2144f3c3c`,
  introducido en el commit `fe7a4af`. El broadcast se ejecutó con HEAD `d0c74ee` (campo `commit` del broadcast), que
  tiene el mismo archivo. El commit `fe7a4af` incluye además los renombres, sin cambios de contenido, de
  `FINAL_AUDIT_REPORT.md` → `FINAL_AUDIT_REPORT_V1.md` y `TEST_MATRIX.md` → `TEST_MATRIX_V1.md`.

### O.2 Deployment

| | |
|---|---|
| Red | Base mainnet (chainId 8453) |
| **Dirección** | **`0xCD09f43D738b10584CaBfb2f73C3adA29fc5AD53`** |
| Tx de deployment | `0x498f8a43fb73cee1c29781019ff0e5f04f92c5ae8597245eb62a17b1defe2b1a` (status 1, gas 3.663.593) |
| Tx de `approve` del health check | `0x1b282be5974acbb137dfbf4c4467920497cd7f410905df18f7f5609ca8526662` (status 1, gas 55.425) |
| Bloque | 52.955.151 (ambas transacciones) |
| Deployer | `0x18e129122a338f2e6871764fe0e4426dE848Ef99` (CM2, keystore existente; costo del health check: 1 unidad de USDC) |
| Constructor args | USDC `0x8335…2913`; admin `0x4206…7602`; admin delay 259.200 s (3 días); treasury `0x7a5F…843e`; vault `0xc462…090D` (Luca Vault); routing `DIRECT_DIRECT`; fee managers = guardians = `0xa737…C5db`, `0x31B5…ac62`, `0x61D4…1050`, `0xa82a…93F7`, `0xe368…1c5f`, `0x5aDF…0A48`, `0x18e1…Ef99`. ABI-encoded completo en `audit/raw/v2/deploy/compare-deployment.txt`. |
| Broadcast | `broadcast/DeployForwarder.s.sol/8453/run-1792699672861.json` (= `run-latest.json`) |

### O.3 Verificación

| Verificación | Resultado | Evidencia |
|---|---|---|
| Source verification | Basescan **`Pass - Verified`** (GUID `bhcbim5wqzh6bxs87wsrggtqnjmypuentjjnaiuvzrmixapibd`) | `audit/raw/v2/deploy/broadcast.txt` |
| Compiler / optimizer / EVM | `v0.8.30+commit.73712a01`, optimizer habilitado con 200 runs, `cancun`, sin via-IR, no es proxy | `audit/raw/v2/deploy/verify-check.txt` (API de Basescan) |
| Source verificado = auditado | `src/Forwarder.sol` del standard-JSON verificado **idéntico** al archivo local (mismo sha256) | idem |
| OpenZeppelin | v5.7.0 (`cab19933…`); 25 fuentes de OZ en el input verificado | idem |
| Creation bytecode | Input de creación on-chain = bytecode de creación compilado localmente (16.118 bytes) + constructor args; los 8 argumentos coinciden con la configuración de producción | `audit/scripts/compare_deployment.py` → `audit/raw/v2/deploy/compare-deployment.txt` |
| Runtime bytecode | Runtime on-chain (11.965 bytes, codehash `0xc4f71db9ebfed1fe5a07d798aadc98c2647be95c40f02eba89849bfff32a0b21`) **byte a byte idéntico** al de una instancia compilada del source auditado con los mismos argumentos | `test_PostDeploy_RuntimeCodeMatchesAuditedSource` (fork posterior al deploy) |
| Configuración on-chain | admin = Safe, delay 3 días, treasury, Luca Vault, `DIRECT_DIRECT`, fees `NONE`/0, sin pausa, **sin pending** (`pendingVault = 0`, `executableAt = 0`), `VAULT_CHANGE_DELAY = 259.200`, allowance al vault 0, saldos 0, allowance del deployer 0; las 7 wallets con `VAULT_GUARDIAN_ROLE` y `FEE_MANAGER_ROLE` y sin admin; la Safe es admin y no guardian; admin de ambos roles = `DEFAULT_ADMIN_ROLE`; `eth_call` de `forward(USDC, 0, …)` exitoso en el nodo real (EIP-1153) | `audit/raw/v2/deploy/onchain-checks.txt` |

### O.4 Post-deploy (fork posterior al deploy, dirección real)

`DEPLOYED_FORWARDER=0xCD09…AD53 POST_DEPLOY_FORK_BLOCK=52955389 forge test --match-contract ForwarderPostDeployForkTest`:
**32/32 PASS** (`audit/raw/v2/fork/post-deploy-52955389.txt`). Cubre bytecode runtime, configuración inicial, roles y
guardians, ausencia de pending, `DIRECT_DIRECT`, allowance 0 y fees 0. También ejecuta sobre la dirección real, en el
fork, propuesta, delay (execute inmediato y en `executableAt − 1` revierte), cancelación por guardians, ejecución,
segundo health check (incluida la falla con la pausa real del Luca Vault y la recuperación), transiciones de routing
(casos A y B), allowances reales y regresión de `forward` en los 4 modos, fallbacks, treasury y rescue. **No se
hicieron operaciones experimentales en mainnet**: las únicas transacciones reales fueron el `approve` y el deploy.

V1 (`0xA7A2…5647`) sigue desplegado y no se tocó. Recomendación: apuntar el flujo de SRA a V2 y dejar de usar V1, que
no tiene el delay.

---

## P. Final Assessment

1. **¿Se mantuvo el diff aislado?** Sí. Hay +97/−16 líneas en `src/Forwarder.sol`, limitadas al ciclo del vault,
   guardians, estado pending, eventos/errores y constructor (B). La única función existente modificada es `_setVault`,
   y sólo por extraer sin cambios su validación.
2. **¿`forward()` está textualmente sin cambios?** Sí: código y NatSpec idénticos (`function-diff.md`).
3. **¿La lógica de fees está sin cambios?** Sí: `calculateFee`, los 6 setters, los chequeos de topes,
   `_emitFeeConfig`, `pause`/`unpause` y el enum `FeeModel` son idénticos. Las 16 combinaciones siguen funcionando.
4. **¿Treasury/accounting están sin cambios?** Sí: `_deliverToTreasury`, `setTreasury`/`_setTreasury`, rescue y
   `_vaultHealthCheck` son idénticos.
5. **¿Existe algún camino post-deploy para cambiar el vault sin 72 h?** No. Sólo `_setVault` escribe `vault`, y sólo
   lo llaman el constructor y `executeVaultChange`, que revierte si `block.timestamp < executableAt`. No hay setter del
   delay, no hay proxy, `delegatecall` ni `selfdestruct`. Probado por Certora para todos los métodos
   (`vaultOnlyChangesThroughExecuteAfterDelay`, `executeRevertsBeforeExecutableAt`, `pendingChangeCannotBeShortened`),
   por invariantes, Echidna, fuzz, tests unitarios y de fork, y por los mutantes M01–M04, M08 y M15–M17.
6. **¿El admin puede ejecutar antes?** No.
7. **¿Un guardian puede ejecutar?** No.
8. **¿Un guardian puede proponer?** No.
9. **¿Revocar guardians modifica el delay?** No (probado también revocando a todos los guardians).
10. **¿El candidato pendiente tiene allowance?** No, 0 (`pendingVaultHasNoAllowance`, invariante probada).
11. **¿Un execute fallido conserva el estado?** Sí: pending, timestamp, vault activo y allowances quedan igual; se
    puede reintentar o cancelar.
12. **¿El routing al ejecutar usa la configuración actual?** Sí (casos A y B, los 16 pares, Certora).
13. **¿Hay Critical abiertos?** No.
14. **¿Hay High abiertos?** No.
15. **¿Hay Medium de contrato abiertos?** No. La Safe 1/1 es una decisión operativa intencional (M.2).
16. **¿Bytecode auditado == desplegado?** Sí: creation input = build local + args, y runtime idéntico byte a byte
    (O.3).
17. **¿Source verificado?** Sí, en Basescan, con el `src/Forwarder.sol` idéntico al auditado.
18. **¿Recomendada para producción?** Sí, con las condiciones operativas que dan sentido al delay: monitoreo en tiempo
    real de `VaultChangeProposed` y de cambios de roles/treasury/fees, un procedimiento para cortar el flujo hacia las
    SRA dentro de las 72 h, la cancelación de propuestas que no se vayan a ejecutar (L-V2-01) y la verificación de
    `previewDeposit`/redondeo antes de proponer un vault (M.7).

---

## Reproducibility

| Herramienta | Versión |
|---|---|
| forge / cast | 1.5.1-stable (`b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2`) |
| solc | 0.8.30+commit.73712a01 |
| OpenZeppelin Contracts | v5.7.0 (`cab19933c33c2ad1d4c7a84864a3601dddfd16f3`) |
| forge-std | v1.12.0 (`7117c90c8cf6c68e5acce4f09a6b24715cea4de6`) |
| Slither | 0.11.6 (crytic-compile 0.4.2) y 0.10.4 |
| Echidna | 2.2.5 |
| Certora CLI | 8.8.0 (Java OpenJDK 21.0.10) |
| Python | 3.10.12 |

```shell
git checkout feature/forwarder-v2-vault-delay && git submodule update --init --recursive
forge build --sizes
forge test --no-match-contract Fork                                                    # 266 tests
FOUNDRY_PROFILE=deep forge test --match-path test/ForwarderVaultChangeFuzz.t.sol       # 10 x 50k runs
FOUNDRY_INVARIANT_RUNS=2000 FOUNDRY_INVARIANT_DEPTH=250 forge test --match-path test/ForwarderVaultChangeInvariant.t.sol
forge test --match-contract ForwarderForkTest                                          # pinned 52,951,000
FORK_BLOCK=0 forge test --match-contract ForwarderForkTest                             # latest
forge coverage --no-match-coverage "(test|script)/" --no-match-contract Fork --report summary --report lcov
slither . --filter-paths "lib/|test/|script/|echidna/|certora/"
SOLC_VERSION=0.8.30 echidna echidna/ForwarderVaultChangeEchidna.sol --contract ForwarderVaultChangeEchidna --config echidna/echidna-v2.yaml --workers 4
SOLC_VERSION=0.8.30 echidna echidna/ForwarderEchidna.sol --contract ForwarderEchidna --config echidna/echidna.yaml --test-limit 100000 --workers 4
SOLC_VERSION=0.8.30 certoraRun certora/conf/ForwarderV2.conf --wait_for_results all
SOLC_VERSION=0.8.30 certoraRun certora/conf/ForwarderV2Invariants.conf --wait_for_results all
python3 audit/scripts/mutation_v2.py <work dir> <report.md>
python3 audit/scripts/function_diff.py <(git show 8687669:src/Forwarder.sol) src/Forwarder.sol
forge script script/DeployForwarder.s.sol --rpc-url base --sender 0x18e129122a338f2e6871764fe0e4426dE848Ef99   # dry-run
python3 audit/scripts/compare_deployment.py broadcast/DeployForwarder.s.sol/8453/run-1792699672861.json
DEPLOYED_FORWARDER=0xCD09f43D738b10584CaBfb2f73C3adA29fc5AD53 POST_DEPLOY_FORK_BLOCK=52955389 forge test --match-contract ForwarderPostDeployForkTest
```
