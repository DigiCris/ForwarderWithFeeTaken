/*
 * Certora specification of src/Forwarder.sol V3 (the deployed final version), verified through
 * certora/harness/ForwarderHarness.sol. Complete, not targeted: it re-proves
 *   - the V1 rules (fee calculation, forward accounting, treasury delivery, rescue, routing, access control), adapted
 *     where V1 used the immediate setters that V3 removed (the configuration is now written through
 *     proposeFeeConfig / executeFeeConfigChange and proposeTreasury / executeTreasuryChange);
 *   - every V2 rule and invariant of the vault change lifecycle;
 * and proves the V3 additions:
 *   - 72-hour cooling period of the global fee configuration and of the treasury, with no bypass, and cancellation
 *     by the admin, the guardians (and the fee managers for the fee configuration);
 *   - per-recipient fee overrides: never above the global fee, never worsened while active, automatic expiry, zero
 *     while paused, global models and threshold;
 *   - forward accounting with the effective fee.
 *
 * Model (same as V1/V2):
 * - USDC is DummyUSDC (balances, always-decremented allowances, `blocked` accounts whose transfers revert).
 * - SafeERC20 internal functions are summarized as the same ERC-20 call made by the Forwarder on DummyUSDC.
 * - Vaults (active, pending and candidates) are DummyVault / DummyVault2 (1:1, deposits and redeems can revert).
 *   Invalid candidates (EOA, wrong asset, non ERC-4626) are covered by the Foundry and fork suites.
 * - Parametric rules and invariants range over the Forwarder's own external functions.
 * - The packed slot `vault | routingMode | lowerFeeModel | upperFeeModel` starts with the enum bytes at zero in the
 *   prover's initial state, so the rules that need an arbitrary fee configuration first write it with the real
 *   functions (`configureFees`: proposeFeeConfig, then executeFeeConfigChange once matured), as V1 did with its
 *   setters (rules named *ForAnyConfiguration).
 */

using DummyUSDC as usdc;
using DummyVault as dvault;
using DummyVault2 as dvault2;

methods {
    function calculateFee(uint256) external returns (uint256) envfree;
    function paused() external returns (bool) envfree;
    function treasury() external returns (address) envfree;
    function vault() external returns (address) envfree;
    function routingMode() external returns (Forwarder.RoutingMode) envfree;
    function lowerFeeModel() external returns (Forwarder.FeeModel) envfree;
    function upperFeeModel() external returns (Forwarder.FeeModel) envfree;
    function threshold() external returns (uint256) envfree;
    function fixedFee() external returns (uint256) envfree;
    function variableFee() external returns (uint256) envfree;
    function hasRole(bytes32, address) external returns (bool) envfree;
    function getRoleAdmin(bytes32) external returns (bytes32) envfree;
    function FEE_MANAGER_ROLE() external returns (bytes32) envfree;
    function DEFAULT_ADMIN_ROLE() external returns (bytes32) envfree;
    function defaultAdmin() external returns (address) envfree;
    function pendingDefaultAdmin() external returns (address, uint48) envfree;
    function usdcAddress() external returns (address) envfree;
    function vaultAllowance() external returns (uint256) envfree;
    function allowanceTo(address) external returns (uint256) envfree;
    function usdcBalance(address) external returns (uint256) envfree;
    function routingModeRaw() external returns (uint8) envfree;
    function lowerFeeModelRaw() external returns (uint8) envfree;
    function upperFeeModelRaw() external returns (uint8) envfree;
    function reentrancyGuardEntered() external returns (bool) envfree;
    function pendingVault() external returns (address) envfree;
    function pendingVaultExecutableAt() external returns (uint256) envfree;
    function VAULT_CHANGE_DELAY() external returns (uint256) envfree;
    function VAULT_GUARDIAN_ROLE() external returns (bytes32) envfree;

    // V3
    function pendingTreasury() external returns (address) envfree;
    function pendingTreasuryExecutableAt() external returns (uint256) envfree;
    function FEE_CHANGE_DELAY() external returns (uint256) envfree;
    function TREASURY_CHANGE_DELAY() external returns (uint256) envfree;
    // Depends on block.timestamp (override expiry): not envfree.
    function calculateFeeFor(address, uint256) external returns (uint256);
    function pendingLowerFeeModel() external returns (Forwarder.FeeModel) envfree;
    function pendingUpperFeeModel() external returns (Forwarder.FeeModel) envfree;
    function pendingThreshold() external returns (uint256) envfree;
    function pendingFixedFee() external returns (uint256) envfree;
    function pendingVariableFee() external returns (uint256) envfree;
    function pendingFeeExecutableAt() external returns (uint256) envfree;
    function pendingLowerFeeModelRaw() external returns (uint8) envfree;
    function pendingUpperFeeModelRaw() external returns (uint8) envfree;
    function overrideFixed(address) external returns (uint256) envfree;
    function overrideVariable(address) external returns (uint256) envfree;
    function overrideUntil(address) external returns (uint256) envfree;

    function DummyUSDC.balanceOf(address) external returns (uint256) envfree;
    function DummyUSDC.allowance(address, address) external returns (uint256) envfree;
    function DummyUSDC.blocked(address) external returns (bool) envfree;
    function DummyUSDC.transfer(address, uint256) external returns (bool);
    function DummyUSDC.transferFrom(address, address, uint256) external returns (bool);
    function DummyUSDC.approve(address, uint256) external returns (bool);
    function DummyVault.balanceOf(address) external returns (uint256) envfree;
    function DummyVault.underlying() external returns (address) envfree;
    function DummyVault.depositReverts() external returns (bool) envfree;
    function DummyVault2.underlying() external returns (address) envfree;

    // SafeERC20 (assembly calls) modelled as the corresponding ERC-20 call made by the Forwarder.
    function SafeERC20.safeTransfer(address token, address to, uint256 value) internal
        => cvlTransfer(executingContract, token, to, value);
    function SafeERC20.safeTransferFrom(address token, address from, address to, uint256 value) internal
        => cvlTransferFrom(executingContract, token, from, to, value);
    function SafeERC20.trySafeTransfer(address token, address to, uint256 value) internal returns (bool)
        => cvlTryTransfer(executingContract, token, to, value);
    function SafeERC20.forceApprove(address token, address spender, uint256 value) internal
        => cvlApprove(executingContract, token, spender, value);

    // Native transfer of rescueNative.
    function Address.sendValue(address recipient, uint256 amount) internal => cvlSendValue(recipient, amount);

    // High-level calls made by the Forwarder and the vault models.
    function _.deposit(uint256, address) external => DISPATCHER(true);
    function _.redeem(uint256, address, address) external => DISPATCHER(true);
    function _.asset() external => DISPATCHER(true);
    function _.balanceOf(address) external => DISPATCHER(true);
    function _.transfer(address, uint256) external => DISPATCHER(true);
    function _.transferFrom(address, address, uint256) external => DISPATCHER(true);
    function _.approve(address, uint256) external => DISPATCHER(true);
    function _.allowance(address, address) external => DISPATCHER(true);
}

// -------------------------------------------------------------------------------------------------------------------
// Summaries
// -------------------------------------------------------------------------------------------------------------------

ghost address ghostNativeRecipient;
ghost mathint ghostNativeAmount;
ghost mathint ghostNativeTransfers;

function cvlTransfer(address caller, address token, address to, uint256 value) {
    env e;
    require e.msg.sender == caller && e.msg.value == 0;
    if (token == usdc) {
        bool ok = usdc.transfer(e, to, value);
        require ok;
    }
}

function cvlTransferFrom(address caller, address token, address from, address to, uint256 value) {
    env e;
    require e.msg.sender == caller && e.msg.value == 0;
    if (token == usdc) {
        bool ok = usdc.transferFrom(e, from, to, value);
        require ok;
    }
}

function cvlTryTransfer(address caller, address token, address to, uint256 value) returns bool {
    env e;
    require e.msg.sender == caller && e.msg.value == 0;
    if (token != usdc) {
        return true;
    }
    usdc.transfer@withrevert(e, to, value);
    return !lastReverted;
}

function cvlApprove(address caller, address token, address spender, uint256 value) {
    env e;
    require e.msg.sender == caller && e.msg.value == 0;
    if (token == usdc) {
        bool ok = usdc.approve(e, spender, value);
        require ok;
    }
}

function cvlSendValue(address recipient, uint256 amount) {
    ghostNativeRecipient = recipient;
    ghostNativeAmount = amount;
    ghostNativeTransfers = ghostNativeTransfers + 1;
}

// -------------------------------------------------------------------------------------------------------------------
// Definitions
// -------------------------------------------------------------------------------------------------------------------

definition MAX_UINT() returns mathint = 2^256 - 1;

definition DELAY() returns mathint = 259200;

definition usesVault(Forwarder.RoutingMode m) returns bool = m != Forwarder.RoutingMode.DIRECT_DIRECT;

definition userUsesVault(Forwarder.RoutingMode m) returns bool =
    m == Forwarder.RoutingMode.VAULT_USER_DIRECT_TREASURY || m == Forwarder.RoutingMode.VAULT_VAULT;

definition treasuryUsesVault(Forwarder.RoutingMode m) returns bool =
    m == Forwarder.RoutingMode.DIRECT_USER_VAULT_TREASURY || m == Forwarder.RoutingMode.VAULT_VAULT;

/// Fee formula of the specification with explicit fixed / variable values: the model is applied to the full amount,
/// percentage rounded down.
function specFeeWith(Forwarder.FeeModel m, uint256 amount, mathint fixedF, mathint variableF) returns mathint {
    mathint pct = (amount * variableF) / 100000;
    if (m == Forwarder.FeeModel.NONE) {
        return 0;
    }
    if (m == Forwarder.FeeModel.FIXED) {
        return fixedF;
    }
    if (m == Forwarder.FeeModel.PERCENT) {
        return pct;
    }
    return fixedF + pct;
}

/// Global fee of the specification (V1).
function specFee(Forwarder.FeeModel m, uint256 amount) returns mathint {
    return specFeeWith(m, amount, fixedFee(), variableFee());
}

function minOf(mathint a, mathint b) returns mathint {
    return a < b ? a : b;
}

/// Effective fixed / variable fee of `r` at time `t` (V3): min(override, global) while the override is active.
function effectiveFixed(address r, uint256 t) returns mathint {
    return t < overrideUntil(r) ? minOf(overrideFixed(r), fixedFee()) : to_mathint(fixedFee());
}

function effectiveVariable(address r, uint256 t) returns mathint {
    return t < overrideUntil(r) ? minOf(overrideVariable(r), variableFee()) : to_mathint(variableFee());
}

/// Fee charged by forward to `r` at time `t` (V3 specification): global model and threshold, effective values, zero
/// while paused.
function specFeeFor(address r, uint256 t, uint256 amount) returns mathint {
    if (paused()) {
        return 0;
    }
    Forwarder.FeeModel m = amount <= threshold() ? lowerFeeModel() : upperFeeModel();
    return specFeeWith(m, amount, effectiveFixed(r, t), effectiveVariable(r, t));
}

/// The model contracts are the USDC and the vaults used (or proposed) by the Forwarder. Rules start a new transaction,
/// so the transient reentrancy flag is clear. Treasuries (active and pending) are not model contracts.
function linkModel() {
    require !reentrancyGuardEntered();
    require usdcAddress() == usdc;
    require dvault.underlying() == usdc && dvault2.underlying() == usdc;
    require vault() == 0 || vault() == dvault || vault() == dvault2;
    require pendingVault() == 0 || pendingVault() == dvault || pendingVault() == dvault2;
    require treasury() != usdc && treasury() != dvault && treasury() != dvault2;
    require pendingTreasury() != usdc && pendingTreasury() != dvault && pendingTreasury() != dvault2;
    requireInvariant enumsAreValid();
    requireInvariant pendingVaultConsistency();
    requireInvariant pendingVaultIsNotActive();
    requireInvariant pendingTreasuryConsistency();
    requireInvariant pendingFeeConsistency();
    requireInvariant pendingFeeEnumsAreValid();
}

/// forward rules observe the shares of `dvault`.
function linkForward() {
    linkModel();
    require vault() == 0 || vault() == dvault;
}

/// Writes an arbitrary fee configuration through the delayed lifecycle: proposal, then execution once matured (a
/// call without @withrevert only keeps the paths where it succeeds, i.e. eExecute is a fee manager acting at or
/// after executableAt).
function configureFees(
    env eManager,
    env eExecute,
    Forwarder.FeeModel lower,
    Forwarder.FeeModel upper,
    uint256 thr,
    uint256 fixedF,
    uint256 variableF
) {
    proposeFeeConfig(eManager, lower, upper, thr, fixedF, variableF);
    executeFeeConfigChange(eExecute);
}

// -------------------------------------------------------------------------------------------------------------------
// Invariants (V1)
// -------------------------------------------------------------------------------------------------------------------

/// Stored enums always hold valid values (every write comes from an ABI-validated enum, directly or through the
/// pending fee configuration).
invariant enumsAreValid()
    routingModeRaw() < 4 && lowerFeeModelRaw() < 4 && upperFeeModelRaw() < 4
    filtered { f -> f.contract == currentContract }
    {
        preserved {
            requireInvariant pendingFeeEnumsAreValid();
        }
    }

/// Fee caps: variable fee <= 10% and fixed fee <= 10 USDC, whatever the sequence of calls.
invariant feeCaps()
    variableFee() <= 10000 && fixedFee() <= 10000000
    filtered { f -> f.contract == currentContract }

/// A routing mode that uses the vault always has a vault.
invariant vaultModeHasVault()
    usesVault(routingMode()) => vault() != 0
    filtered { f -> f.contract == currentContract }
    {
        preserved {
            requireInvariant enumsAreValid();
        }
    }

/// The treasury is never zero nor the Forwarder itself.
invariant treasuryIsValid()
    treasury() != 0 && treasury() != currentContract
    filtered { f -> f.contract == currentContract }

/// The admin of FEE_MANAGER_ROLE is always DEFAULT_ADMIN_ROLE.
invariant feeManagerAdminIsDefaultAdmin()
    getRoleAdmin(FEE_MANAGER_ROLE()) == DEFAULT_ADMIN_ROLE()
    filtered { f -> f.contract == currentContract }

/// DIRECT_DIRECT never leaves an allowance to the vault.
invariant directDirectMeansNoVaultAllowance()
    (routingMode() == Forwarder.RoutingMode.DIRECT_DIRECT && vault() != 0) => vaultAllowance() == 0
    filtered { f -> f.contract == currentContract }
    {
        preserved with (env e) {
            linkModel();
            require e.msg.sender != currentContract;
        }
    }

// -------------------------------------------------------------------------------------------------------------------
// Invariants (V2)
// -------------------------------------------------------------------------------------------------------------------

/// The admin of VAULT_GUARDIAN_ROLE is always DEFAULT_ADMIN_ROLE.
invariant guardianAdminIsDefaultAdmin()
    getRoleAdmin(VAULT_GUARDIAN_ROLE()) == DEFAULT_ADMIN_ROLE()
    filtered { f -> f.contract == currentContract }

/// No pending vault <=> no pending timestamp.
invariant pendingVaultConsistency()
    (pendingVault() == 0) <=> (pendingVaultExecutableAt() == 0)
    filtered { f -> f.contract == currentContract }

/// A pending vault is never the active vault.
invariant pendingVaultIsNotActive()
    pendingVault() != 0 => pendingVault() != vault()
    filtered { f -> f.contract == currentContract }

/// A pending vault never holds an allowance from the Forwarder.
invariant pendingVaultHasNoAllowance()
    pendingVault() != 0 => allowanceTo(pendingVault()) == 0
    filtered { f -> f.contract == currentContract }
    {
        preserved with (env e) {
            linkModel();
            require e.msg.sender != currentContract;
        }
    }

// -------------------------------------------------------------------------------------------------------------------
// Invariants (V3)
// -------------------------------------------------------------------------------------------------------------------

/// The pending fee configuration only holds ABI-validated enums.
invariant pendingFeeEnumsAreValid()
    pendingLowerFeeModelRaw() < 4 && pendingUpperFeeModelRaw() < 4
    filtered { f -> f.contract == currentContract }

/// A pending fee configuration always respects the caps.
invariant pendingFeeCaps()
    pendingVariableFee() <= 10000 && pendingFixedFee() <= 10000000
    filtered { f -> f.contract == currentContract }

/// No pending fee configuration (executableAt == 0) means an all-zero pending slot (clean-up).
invariant pendingFeeConsistency()
    pendingFeeExecutableAt() == 0 => (
        pendingLowerFeeModelRaw() == 0 && pendingUpperFeeModelRaw() == 0 && pendingThreshold() == 0
            && pendingFixedFee() == 0 && pendingVariableFee() == 0
    )
    filtered { f -> f.contract == currentContract }

/// No pending treasury <=> no pending timestamp.
invariant pendingTreasuryConsistency()
    (pendingTreasury() == 0) <=> (pendingTreasuryExecutableAt() == 0)
    filtered { f -> f.contract == currentContract }

/// A pending treasury is never the Forwarder itself.
invariant pendingTreasuryIsValid()
    pendingTreasury() != currentContract
    filtered { f -> f.contract == currentContract }

/// The zero address never has a fee override.
invariant zeroAddressHasNoOverride()
    overrideUntil(0) == 0 && overrideFixed(0) == 0 && overrideVariable(0) == 0
    filtered { f -> f.contract == currentContract }

// -------------------------------------------------------------------------------------------------------------------
// Fee calculation (V1: calculateFee is unchanged)
// -------------------------------------------------------------------------------------------------------------------

/// paused => fee = 0.
rule pausedFeeIsZero(uint256 amount) {
    require paused();
    assert calculateFee(amount) == 0;
}

/// The fee equals the specification formula; the only possible revert is the overflow of amount * variableFee.
rule feeMatchesSpecification(uint256 amount) {
    requireInvariant feeCaps();
    requireInvariant enumsAreValid();
    require !paused();
    Forwarder.FeeModel m = amount <= threshold() ? lowerFeeModel() : upperFeeModel();
    bool percentModel = m == Forwarder.FeeModel.PERCENT || m == Forwarder.FeeModel.FIXED_PLUS_PERCENT;
    bool overflow = percentModel && amount * variableFee() > MAX_UINT();

    uint256 fee = calculateFee@withrevert(amount);

    assert lastReverted <=> overflow;
    assert !lastReverted => to_mathint(fee) == specFee(m, amount);
}

/// Non-vacuity witnesses: each fee model produces a non-zero fee in some reachable state.
rule fixedModelIsReachable(uint256 amount) {
    requireInvariant enumsAreValid();
    require !paused() && amount > threshold() && upperFeeModel() == Forwarder.FeeModel.FIXED;
    satisfy calculateFee(amount) > 0;
}

rule percentModelIsReachable(uint256 amount) {
    requireInvariant enumsAreValid();
    require !paused() && amount > threshold() && upperFeeModel() == Forwarder.FeeModel.PERCENT;
    satisfy calculateFee(amount) > 0;
}

rule fixedPlusPercentModelIsReachable(uint256 amount) {
    requireInvariant enumsAreValid();
    require !paused() && amount > threshold() && upperFeeModel() == Forwarder.FeeModel.FIXED_PLUS_PERCENT;
    satisfy to_mathint(calculateFee(amount)) > to_mathint(fixedFee());
}

/// amount <= threshold selects the lower model.
rule lowerModelUpToThreshold(uint256 amount) {
    requireInvariant enumsAreValid();
    require !paused();
    require amount <= threshold();
    require amount * variableFee() <= MAX_UINT();
    assert to_mathint(calculateFee(amount)) == specFee(lowerFeeModel(), amount);
}

/// amount > threshold selects the upper model.
rule upperModelAboveThreshold(uint256 amount) {
    requireInvariant enumsAreValid();
    require !paused();
    require amount > threshold();
    require amount * variableFee() <= MAX_UINT();
    assert to_mathint(calculateFee(amount)) == specFee(upperFeeModel(), amount);
}

/// Above the threshold the percentage is computed on the whole amount, not on the excess over the threshold.
rule percentUsesWholeAmount(uint256 amount) {
    requireInvariant enumsAreValid();
    require !paused();
    require amount > threshold();
    require upperFeeModel() == Forwarder.FeeModel.PERCENT;
    require amount * variableFee() <= MAX_UINT();
    assert to_mathint(calculateFee(amount)) == (amount * variableFee()) / 100000;
}

/// Witness: there are states where the whole-amount fee differs from an excess-only fee.
rule percentUsesWholeAmountIsNotTheExcessFee(uint256 amount) {
    requireInvariant enumsAreValid();
    require !paused();
    require amount > threshold();
    require upperFeeModel() == Forwarder.FeeModel.PERCENT;
    require amount * variableFee() <= MAX_UINT();
    satisfy to_mathint(calculateFee(amount)) != ((amount - threshold()) * variableFee()) / 100000;
}

/// The fee equals the specification for every configuration a fee manager can apply. Amounts are bounded to 2^200
/// (no overflow is possible below it with variableFee <= 10_000); the overflow case is covered by
/// `feeMatchesSpecification`.
rule feeMatchesSpecificationForAnyConfiguration(
    env eManager,
    env eExecute,
    Forwarder.FeeModel lower,
    Forwarder.FeeModel upper,
    uint256 thr,
    uint256 fixedF,
    uint256 variableF,
    uint256 amount
) {
    linkModel();
    require !paused();
    configureFees(eManager, eExecute, lower, upper, thr, fixedF, variableF);
    require amount < 2^200;
    Forwarder.FeeModel m = amount <= thr ? lower : upper;

    uint256 fee = calculateFee@withrevert(amount);

    assert !lastReverted, "no revert for amounts below 2^200";
    assert to_mathint(fee) == specFeeWith(m, amount, fixedF, variableF), "fee value";
}

/// PERCENT above the threshold charges the percentage of the whole amount.
rule percentAboveThresholdUsesWholeAmount(env eManager, env eExecute, uint256 thr, uint256 variableF, uint256 amount) {
    linkModel();
    require !paused();
    configureFees(eManager, eExecute, Forwarder.FeeModel.NONE, Forwarder.FeeModel.PERCENT, thr, 0, variableF);
    require amount > thr && amount * variableF <= MAX_UINT();
    assert to_mathint(calculateFee(amount)) == (amount * variableF) / 100000;
}

/// Witness: the whole-amount fee differs from an excess-only fee in some configuration (the rule above is not trivial).
rule percentAboveThresholdIsNotExcessFee(env eManager, env eExecute, uint256 thr, uint256 variableF, uint256 amount) {
    linkModel();
    require !paused();
    configureFees(eManager, eExecute, Forwarder.FeeModel.NONE, Forwarder.FeeModel.PERCENT, thr, 0, variableF);
    require amount > thr && amount * variableF <= MAX_UINT();
    satisfy to_mathint(calculateFee(amount)) != ((amount - thr) * variableF) / 100000;
}

/// Witnesses: every non-NONE model yields a positive fee after configuration.
rule fixedModelChargesAfterConfiguration(env eManager, env eExecute, uint256 fixedF, uint256 amount) {
    linkModel();
    require !paused();
    configureFees(eManager, eExecute, Forwarder.FeeModel.FIXED, Forwarder.FeeModel.FIXED, 0, fixedF, 0);
    satisfy calculateFee(amount) > 0;
}

rule fixedPlusPercentModelChargesAfterConfiguration(
    env eManager,
    env eExecute,
    uint256 fixedF,
    uint256 variableF,
    uint256 amount
) {
    linkModel();
    require !paused();
    configureFees(
        eManager,
        eExecute,
        Forwarder.FeeModel.FIXED_PLUS_PERCENT,
        Forwarder.FeeModel.FIXED_PLUS_PERCENT,
        0,
        fixedF,
        variableF
    );
    satisfy to_mathint(calculateFee(amount)) > to_mathint(fixedF);
}

// -------------------------------------------------------------------------------------------------------------------
// Effective fee with overrides (V3)
// -------------------------------------------------------------------------------------------------------------------

/// paused => effective fee = 0 for every recipient, override or not.
rule pausedEffectiveFeeIsZero(env e, address r, uint256 amount) {
    require e.msg.value == 0;
    require paused();
    assert calculateFeeFor(e, r, amount) == 0;
}

/// The effective fee equals the specification (global model and threshold, min(override, global) while active); the
/// only possible revert is the overflow of amount * effective variable fee.
rule effectiveFeeMatchesSpecification(env e, address r, uint256 amount) {
    requireInvariant feeCaps();
    requireInvariant enumsAreValid();
    require e.msg.value == 0;
    require !paused();
    Forwarder.FeeModel m = amount <= threshold() ? lowerFeeModel() : upperFeeModel();
    bool percentModel = m == Forwarder.FeeModel.PERCENT || m == Forwarder.FeeModel.FIXED_PLUS_PERCENT;
    bool overflow = percentModel && amount * effectiveVariable(r, e.block.timestamp) > MAX_UINT();

    uint256 fee = calculateFeeFor@withrevert(e, r, amount);

    assert lastReverted <=> overflow;
    assert !lastReverted => to_mathint(fee) == specFeeFor(r, e.block.timestamp, amount);
}

/// Central property: whenever the global fee is defined, the effective fee of any recipient is defined too and never
/// exceeds it.
rule effectiveFeeNeverExceedsGlobalFee(env e, address r, uint256 amount) {
    requireInvariant enumsAreValid();
    require e.msg.value == 0;
    uint256 globalFee = calculateFee@withrevert(amount);
    bool globalReverted = lastReverted;
    uint256 fee = calculateFeeFor@withrevert(e, r, amount);
    assert !globalReverted => !lastReverted && fee <= globalFee;
}

/// From validUntil on (and without override) the effective fee is exactly the global fee: automatic expiry.
rule expiredOverrideIsTheGlobalFee(env e, address r, uint256 amount) {
    require e.msg.value == 0;
    require e.block.timestamp >= overrideUntil(r);
    uint256 globalFee = calculateFee@withrevert(amount);
    bool globalReverted = lastReverted;
    uint256 fee = calculateFeeFor@withrevert(e, r, amount);
    assert lastReverted == globalReverted;
    assert !globalReverted => fee == globalFee;
}

/// The effective fee for any applied configuration and any override (set afterwards), against the specification.
rule effectiveFeeMatchesSpecificationForAnyConfiguration(
    env eManager,
    env eExecute,
    env eOverride,
    env e,
    Forwarder.FeeModel lower,
    Forwarder.FeeModel upper,
    uint256 thr,
    uint256 fixedF,
    uint256 variableF,
    address r,
    uint256 overrideF,
    uint256 overrideV,
    uint256 until,
    uint256 amount
) {
    linkModel();
    require !paused();
    configureFees(eManager, eExecute, lower, upper, thr, fixedF, variableF);
    setUserFeeOverride(eOverride, r, overrideF, overrideV, until);
    require e.msg.value == 0 && amount < 2^200;
    Forwarder.FeeModel m = amount <= thr ? lower : upper;
    bool active = e.block.timestamp < until;
    mathint fixedEff = active ? minOf(overrideF, fixedF) : to_mathint(fixedF);
    mathint variableEff = active ? minOf(overrideV, variableF) : to_mathint(variableF);

    uint256 fee = calculateFeeFor@withrevert(e, r, amount);

    assert !lastReverted, "no revert for amounts below 2^200";
    assert to_mathint(fee) == specFeeWith(m, amount, fixedEff, variableEff), "effective fee value";
}

/// After an override is set, the global configuration can change again (it goes through the delay): the effective
/// fee then follows min(override, new global), never above the new global fee (spec example: the global fee drops
/// below the override, or rises again above it).
rule effectiveFeeFollowsLaterGlobalChanges(
    env eManager,
    env eExecute,
    env eOverride,
    env eManager2,
    env eExecute2,
    env e,
    Forwarder.FeeModel lower,
    Forwarder.FeeModel upper,
    uint256 thr,
    uint256 fixedF,
    uint256 variableF,
    uint256 fixedF2,
    uint256 variableF2,
    address r,
    uint256 overrideF,
    uint256 overrideV,
    uint256 until,
    uint256 amount
) {
    linkModel();
    require !paused();
    configureFees(eManager, eExecute, lower, upper, thr, fixedF, variableF);
    setUserFeeOverride(eOverride, r, overrideF, overrideV, until);
    configureFees(eManager2, eExecute2, lower, upper, thr, fixedF2, variableF2);
    require e.msg.value == 0 && amount < 2^200;
    bool active = e.block.timestamp < until;

    uint256 globalFee = calculateFee(amount);
    uint256 fee = calculateFeeFor(e, r, amount);

    Forwarder.FeeModel m = amount <= thr ? lower : upper;
    mathint fixedEff = active ? minOf(overrideF, fixedF2) : to_mathint(fixedF2);
    mathint variableEff = active ? minOf(overrideV, variableF2) : to_mathint(variableF2);
    assert fee <= globalFee;
    assert to_mathint(fee) == specFeeWith(m, amount, fixedEff, variableEff);
}

/// Witness: an active override really lowers the fee in some configuration.
rule discountedFeeIsReachable(
    env eManager,
    env eExecute,
    env eOverride,
    env e,
    uint256 fixedF,
    uint256 variableF,
    address r,
    uint256 overrideF,
    uint256 overrideV,
    uint256 until,
    uint256 amount
) {
    linkModel();
    require !paused();
    configureFees(
        eManager,
        eExecute,
        Forwarder.FeeModel.FIXED_PLUS_PERCENT,
        Forwarder.FeeModel.FIXED_PLUS_PERCENT,
        0,
        fixedF,
        variableF
    );
    setUserFeeOverride(eOverride, r, overrideF, overrideV, until);
    require e.msg.value == 0 && amount < 2^200 && e.block.timestamp < until;
    satisfy calculateFeeFor(e, r, amount) < calculateFee(amount);
}

// -------------------------------------------------------------------------------------------------------------------
// Override lifecycle (V3)
// -------------------------------------------------------------------------------------------------------------------

/// Only FEE_MANAGER_ROLE sets overrides.
rule onlyFeeManagerSetsOverrides(env e, address r, uint256 overrideF, uint256 overrideV, uint256 until) {
    bool isManager = hasRole(FEE_MANAGER_ROLE(), e.msg.sender);
    setUserFeeOverride@withrevert(e, r, overrideF, overrideV, until);
    assert !lastReverted => isManager;
}

/// setUserFeeOverride only succeeds with a non-zero recipient, a future validUntil, values not above the active
/// global fee and, if an override is active, values that do not worsen it; it stores exactly the arguments.
rule setUserFeeOverrideValidation(env e, address r, uint256 overrideF, uint256 overrideV, uint256 until) {
    uint256 oldF = overrideFixed(r);
    uint256 oldV = overrideVariable(r);
    uint256 oldU = overrideUntil(r);
    bool wasActive = e.block.timestamp < oldU;
    uint256 globalF = fixedFee();
    uint256 globalV = variableFee();

    setUserFeeOverride@withrevert(e, r, overrideF, overrideV, until);
    bool reverted = lastReverted;

    assert !reverted => (r != 0 && until > e.block.timestamp && overrideF <= globalF && overrideV <= globalV);
    assert (!reverted && wasActive) => (overrideF <= oldF && overrideV <= oldV && until >= oldU);
    assert !reverted => (overrideFixed(r) == overrideF && overrideVariable(r) == overrideV && overrideUntil(r) == until);
    assert reverted => (overrideFixed(r) == oldF && overrideVariable(r) == oldV && overrideUntil(r) == oldU);
}

/// Liveness: a fee manager can always set a valid, non-worsening override.
rule setUserFeeOverrideLiveness(env e, address r, uint256 overrideF, uint256 overrideV, uint256 until) {
    require e.msg.value == 0;
    require hasRole(FEE_MANAGER_ROLE(), e.msg.sender);
    require r != 0 && until > e.block.timestamp && overrideF <= fixedFee() && overrideV <= variableFee();
    require e.block.timestamp < overrideUntil(r) => (
        overrideF <= overrideFixed(r) && overrideV <= overrideVariable(r) && until >= overrideUntil(r)
    );
    setUserFeeOverride@withrevert(e, r, overrideF, overrideV, until);
    assert !lastReverted;
}

/// The guarantee: while an override is active no function can raise its fees or shorten its validity (and there is
/// no way to remove it).
rule activeOverrideIsNeverWorsened(method f, env e, calldataarg args, address r)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    uint256 fixedBefore = overrideFixed(r);
    uint256 variableBefore = overrideVariable(r);
    uint256 untilBefore = overrideUntil(r);
    require e.block.timestamp < untilBefore;

    f(e, args);

    assert overrideFixed(r) <= fixedBefore && overrideVariable(r) <= variableBefore && overrideUntil(r) >= untilBefore;
}

/// Overrides only change through setUserFeeOverride by a fee manager.
rule overridesOnlyChangeThroughSetUserFeeOverride(method f, env e, calldataarg args, address r)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    uint256 fixedBefore = overrideFixed(r);
    uint256 variableBefore = overrideVariable(r);
    uint256 untilBefore = overrideUntil(r);
    bool isManager = hasRole(FEE_MANAGER_ROLE(), e.msg.sender);

    f(e, args);

    bool changed = overrideFixed(r) != fixedBefore || overrideVariable(r) != variableBefore
        || overrideUntil(r) != untilBefore;
    assert changed => (
        f.selector == sig:setUserFeeOverride(address, uint256, uint256, uint256).selector && isManager
    );
}

/// setUserFeeOverride only touches the override of its recipient: no other override, no global configuration, no
/// pending change, no treasury, vault, routing or pause.
rule setUserFeeOverrideTouchesOnlyThatOverride(
    env e,
    address r,
    address other,
    uint256 overrideF,
    uint256 overrideV,
    uint256 until
) {
    require other != r;
    uint256 otherF = overrideFixed(other);
    uint256 otherV = overrideVariable(other);
    uint256 otherU = overrideUntil(other);
    Forwarder.FeeModel lowerBefore = lowerFeeModel();
    Forwarder.FeeModel upperBefore = upperFeeModel();
    uint256 thresholdBefore = threshold();
    uint256 fixedBefore = fixedFee();
    uint256 variableBefore = variableFee();
    uint256 pendingFeeAtBefore = pendingFeeExecutableAt();
    address treasuryBefore = treasury();
    address pendingTreasuryBefore = pendingTreasury();
    address vaultBefore = vault();
    address pendingVaultBefore = pendingVault();
    Forwarder.RoutingMode modeBefore = routingMode();
    bool pausedBefore = paused();

    setUserFeeOverride(e, r, overrideF, overrideV, until);

    assert overrideFixed(other) == otherF && overrideVariable(other) == otherV && overrideUntil(other) == otherU;
    assert lowerFeeModel() == lowerBefore && upperFeeModel() == upperBefore && threshold() == thresholdBefore;
    assert fixedFee() == fixedBefore && variableFee() == variableBefore;
    assert pendingFeeExecutableAt() == pendingFeeAtBefore && pendingTreasury() == pendingTreasuryBefore;
    assert treasury() == treasuryBefore && vault() == vaultBefore && pendingVault() == pendingVaultBefore;
    assert routingMode() == modeBefore && paused() == pausedBefore;
}

// -------------------------------------------------------------------------------------------------------------------
// Fee configuration cooling period (V3)
// -------------------------------------------------------------------------------------------------------------------

/// The delay is the constant 72 hours.
rule feeChangeDelayIs72Hours() {
    assert FEE_CHANGE_DELAY() == 259200;
}

/// Only FEE_MANAGER_ROLE proposes and executes.
rule onlyFeeManagerProposesFeeConfig(
    env e,
    Forwarder.FeeModel lower,
    Forwarder.FeeModel upper,
    uint256 thr,
    uint256 fixedF,
    uint256 variableF
) {
    bool isManager = hasRole(FEE_MANAGER_ROLE(), e.msg.sender);
    proposeFeeConfig@withrevert(e, lower, upper, thr, fixedF, variableF);
    assert !lastReverted => isManager;
}

rule onlyFeeManagerExecutesFeeConfig(env e) {
    bool isManager = hasRole(FEE_MANAGER_ROLE(), e.msg.sender);
    executeFeeConfigChange@withrevert(e);
    assert !lastReverted => isManager;
}

/// Only the admin, a guardian or a fee manager cancels.
rule onlyAuthorizedCancelsFeeConfig(env e) {
    bool allowed = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender) || hasRole(VAULT_GUARDIAN_ROLE(), e.msg.sender)
        || hasRole(FEE_MANAGER_ROLE(), e.msg.sender);
    cancelFeeConfigChange@withrevert(e);
    assert !lastReverted => allowed;
}

/// Liveness: any of them can always cancel a pending change, at any time (before or after it matures).
rule authorizedCanAlwaysCancelFeeConfig(env e) {
    require e.msg.value == 0;
    require hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender) || hasRole(VAULT_GUARDIAN_ROLE(), e.msg.sender)
        || hasRole(FEE_MANAGER_ROLE(), e.msg.sender);
    require pendingFeeExecutableAt() != 0;
    cancelFeeConfigChange@withrevert(e);
    assert !lastReverted;
    assert pendingFeeExecutableAt() == 0;
}

/// proposeFeeConfig stores exactly the proposal with executableAt = proposal timestamp + 72 hours and leaves the
/// active configuration untouched.
rule proposeFeeConfigStoresExactProposal(
    env e,
    Forwarder.FeeModel lower,
    Forwarder.FeeModel upper,
    uint256 thr,
    uint256 fixedF,
    uint256 variableF
) {
    Forwarder.FeeModel lowerBefore = lowerFeeModel();
    Forwarder.FeeModel upperBefore = upperFeeModel();
    uint256 thresholdBefore = threshold();
    uint256 fixedBefore = fixedFee();
    uint256 variableBefore = variableFee();

    proposeFeeConfig(e, lower, upper, thr, fixedF, variableF);

    assert pendingLowerFeeModel() == lower && pendingUpperFeeModel() == upper && pendingThreshold() == thr;
    assert pendingFixedFee() == fixedF && pendingVariableFee() == variableF;
    assert to_mathint(pendingFeeExecutableAt()) == e.block.timestamp + DELAY();
    assert lowerFeeModel() == lowerBefore && upperFeeModel() == upperBefore && threshold() == thresholdBefore;
    assert fixedFee() == fixedBefore && variableFee() == variableBefore;
}

/// A proposal never overwrites a pending change, even a matured one.
rule proposeFeeConfigRevertsWhileAChangeIsPending(
    env e,
    Forwarder.FeeModel lower,
    Forwarder.FeeModel upper,
    uint256 thr,
    uint256 fixedF,
    uint256 variableF
) {
    require pendingFeeExecutableAt() != 0;
    proposeFeeConfig@withrevert(e, lower, upper, thr, fixedF, variableF);
    assert lastReverted;
}

/// The caps are enforced at proposal time; a fee manager can always propose values within the caps.
rule proposeFeeConfigEnforcesTheCaps(
    env e,
    Forwarder.FeeModel lower,
    Forwarder.FeeModel upper,
    uint256 thr,
    uint256 fixedF,
    uint256 variableF
) {
    bool isManager = hasRole(FEE_MANAGER_ROLE(), e.msg.sender);
    bool nothingPending = pendingFeeExecutableAt() == 0;
    require e.msg.value == 0 && e.block.timestamp + DELAY() <= MAX_UINT();
    proposeFeeConfig@withrevert(e, lower, upper, thr, fixedF, variableF);
    bool reverted = lastReverted;
    assert (fixedF > 10000000 || variableF > 10000) => reverted;
    assert (fixedF <= 10000000 && variableF <= 10000 && isManager && nothingPending) => !reverted;
}

/// No execution before executableAt, whoever calls and whatever the state; none without a pending change.
rule executeFeeConfigRevertsBeforeExecutableAt(env e) {
    require e.block.timestamp < pendingFeeExecutableAt();
    executeFeeConfigChange@withrevert(e);
    assert lastReverted;
}

rule executeFeeConfigRevertsWithoutPendingChange(env e) {
    require pendingFeeExecutableAt() == 0;
    executeFeeConfigChange@withrevert(e);
    assert lastReverted;
}

/// No bypass: after the deployment the global fee configuration only changes through a successful
/// executeFeeConfigChange by a fee manager, from executableAt on, and only to the pending configuration.
rule feeConfigOnlyChangesThroughMaturedExecution(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    Forwarder.FeeModel lowerBefore = lowerFeeModel();
    Forwarder.FeeModel upperBefore = upperFeeModel();
    uint256 thresholdBefore = threshold();
    uint256 fixedBefore = fixedFee();
    uint256 variableBefore = variableFee();
    Forwarder.FeeModel pendingLowerBefore = pendingLowerFeeModel();
    Forwarder.FeeModel pendingUpperBefore = pendingUpperFeeModel();
    uint256 pendingThresholdBefore = pendingThreshold();
    uint256 pendingFixedBefore = pendingFixedFee();
    uint256 pendingVariableBefore = pendingVariableFee();
    uint256 atBefore = pendingFeeExecutableAt();
    bool isManager = hasRole(FEE_MANAGER_ROLE(), e.msg.sender);

    f(e, args);

    bool changed = lowerFeeModel() != lowerBefore || upperFeeModel() != upperBefore || threshold() != thresholdBefore
        || fixedFee() != fixedBefore || variableFee() != variableBefore;
    assert changed => (
        f.selector == sig:executeFeeConfigChange().selector && isManager && atBefore != 0 && e.block.timestamp >= atBefore
            && lowerFeeModel() == pendingLowerBefore && upperFeeModel() == pendingUpperBefore
            && threshold() == pendingThresholdBefore && fixedFee() == pendingFixedBefore
            && variableFee() == pendingVariableBefore
    );
}

/// No method shortens or modifies a pending change: it keeps its values and its timestamp until it is cleared, and a
/// new pending change always gets exactly the proposal timestamp + 72 hours.
rule pendingFeeConfigCannotBeShortened(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    Forwarder.FeeModel lowerBefore = pendingLowerFeeModel();
    Forwarder.FeeModel upperBefore = pendingUpperFeeModel();
    uint256 thresholdBefore = pendingThreshold();
    uint256 fixedBefore = pendingFixedFee();
    uint256 variableBefore = pendingVariableFee();
    uint256 atBefore = pendingFeeExecutableAt();

    f(e, args);

    uint256 atAfter = pendingFeeExecutableAt();
    bool unchanged = atAfter == atBefore && pendingLowerFeeModel() == lowerBefore
        && pendingUpperFeeModel() == upperBefore && pendingThreshold() == thresholdBefore
        && pendingFixedFee() == fixedBefore && pendingVariableFee() == variableBefore;
    assert atAfter != 0 => (
        unchanged || (
            atBefore == 0 && f.selector == sig:proposeFeeConfig(
                Forwarder.FeeModel, Forwarder.FeeModel, uint256, uint256, uint256
            ).selector && to_mathint(atAfter) == e.block.timestamp + DELAY()
        )
    );
}

/// The pending change is only removed by cancelFeeConfigChange or executeFeeConfigChange.
rule pendingFeeConfigOnlyClearedByCancelOrExecute(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    uint256 atBefore = pendingFeeExecutableAt();
    f(e, args);
    assert (atBefore != 0 && pendingFeeExecutableAt() == 0) => (
        f.selector == sig:cancelFeeConfigChange().selector || f.selector == sig:executeFeeConfigChange().selector
    );
}

/// A successful execution applies exactly the pending configuration and clears it.
rule executeFeeConfigAppliesPendingAndClearsIt(env e) {
    Forwarder.FeeModel lowerP = pendingLowerFeeModel();
    Forwarder.FeeModel upperP = pendingUpperFeeModel();
    uint256 thresholdP = pendingThreshold();
    uint256 fixedP = pendingFixedFee();
    uint256 variableP = pendingVariableFee();
    uint256 atBefore = pendingFeeExecutableAt();

    executeFeeConfigChange(e);

    assert atBefore != 0 && e.block.timestamp >= atBefore;
    assert lowerFeeModel() == lowerP && upperFeeModel() == upperP && threshold() == thresholdP;
    assert fixedFee() == fixedP && variableFee() == variableP;
    assert pendingFeeExecutableAt() == 0 && pendingThreshold() == 0 && pendingFixedFee() == 0;
    assert pendingVariableFee() == 0 && pendingLowerFeeModelRaw() == 0 && pendingUpperFeeModelRaw() == 0;
}

/// The configuration written by the delayed lifecycle is exactly the proposed one (V1 setFeeConfigStoresConfiguration
/// adapted).
rule executeFeeConfigStoresProposedConfiguration(
    env eManager,
    env eExecute,
    Forwarder.FeeModel lower,
    Forwarder.FeeModel upper,
    uint256 thr,
    uint256 fixedF,
    uint256 variableF
) {
    linkModel();
    configureFees(eManager, eExecute, lower, upper, thr, fixedF, variableF);
    assert lowerFeeModel() == lower, "lower";
    assert upperFeeModel() == upper, "upper";
    assert threshold() == thr && fixedFee() == fixedF && variableFee() == variableF, "values";
    assert to_mathint(eExecute.block.timestamp) >= eManager.block.timestamp + DELAY(), "72 hours elapsed";
}

/// A failed execution keeps the pending change and the active configuration.
rule failedFeeExecutionKeepsState(env e) {
    uint256 atBefore = pendingFeeExecutableAt();
    uint256 fixedP = pendingFixedFee();
    uint256 fixedBefore = fixedFee();
    uint256 variableBefore = variableFee();

    executeFeeConfigChange@withrevert(e);

    assert lastReverted => (
        pendingFeeExecutableAt() == atBefore && pendingFixedFee() == fixedP && fixedFee() == fixedBefore
            && variableFee() == variableBefore
    );
}

/// cancelFeeConfigChange clears the pending change and leaves the active configuration untouched.
rule cancelFeeConfigClearsPendingOnly(env e) {
    Forwarder.FeeModel lowerBefore = lowerFeeModel();
    Forwarder.FeeModel upperBefore = upperFeeModel();
    uint256 thresholdBefore = threshold();
    uint256 fixedBefore = fixedFee();
    uint256 variableBefore = variableFee();
    uint256 atBefore = pendingFeeExecutableAt();

    cancelFeeConfigChange(e);

    assert atBefore != 0;
    assert pendingFeeExecutableAt() == 0 && pendingFixedFee() == 0 && pendingVariableFee() == 0;
    assert pendingThreshold() == 0 && pendingLowerFeeModelRaw() == 0 && pendingUpperFeeModelRaw() == 0;
    assert lowerFeeModel() == lowerBefore && upperFeeModel() == upperBefore && threshold() == thresholdBefore;
    assert fixedFee() == fixedBefore && variableFee() == variableBefore;
}

/// The fee lifecycle functions never touch the treasury, the vault, the routing, the pause, the other pending
/// changes nor the overrides.
rule feeLifecycleKeepsEverythingElse(method f, env e, calldataarg args, address r)
    filtered {
        f -> f.contract == currentContract && (
            f.selector == sig:proposeFeeConfig(Forwarder.FeeModel, Forwarder.FeeModel, uint256, uint256, uint256).selector
                || f.selector == sig:executeFeeConfigChange().selector
                || f.selector == sig:cancelFeeConfigChange().selector
        )
    }
{
    address treasuryBefore = treasury();
    address pendingTreasuryBefore = pendingTreasury();
    uint256 treasuryAtBefore = pendingTreasuryExecutableAt();
    address vaultBefore = vault();
    address pendingVaultBefore = pendingVault();
    Forwarder.RoutingMode modeBefore = routingMode();
    bool pausedBefore = paused();
    uint256 overrideFBefore = overrideFixed(r);
    uint256 overrideVBefore = overrideVariable(r);
    uint256 overrideUBefore = overrideUntil(r);

    f(e, args);

    assert treasury() == treasuryBefore && pendingTreasury() == pendingTreasuryBefore;
    assert pendingTreasuryExecutableAt() == treasuryAtBefore;
    assert vault() == vaultBefore && pendingVault() == pendingVaultBefore && routingMode() == modeBefore;
    assert paused() == pausedBefore;
    assert overrideFixed(r) == overrideFBefore && overrideVariable(r) == overrideVBefore;
    assert overrideUntil(r) == overrideUBefore;
}

// -------------------------------------------------------------------------------------------------------------------
// Treasury cooling period (V3)
// -------------------------------------------------------------------------------------------------------------------

/// The delay is the constant 72 hours.
rule treasuryChangeDelayIs72Hours() {
    assert TREASURY_CHANGE_DELAY() == 259200;
}

/// Only DEFAULT_ADMIN_ROLE proposes and executes; only the admin or a guardian cancels.
rule onlyAdminProposesTreasury(env e, address candidate) {
    bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);
    proposeTreasury@withrevert(e, candidate);
    assert !lastReverted => isAdmin;
}

rule onlyAdminExecutesTreasury(env e) {
    bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);
    executeTreasuryChange@withrevert(e);
    assert !lastReverted => isAdmin;
}

rule onlyAdminOrGuardianCancelsTreasury(env e) {
    bool allowed = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender) || hasRole(VAULT_GUARDIAN_ROLE(), e.msg.sender);
    cancelTreasuryChange@withrevert(e);
    assert !lastReverted => allowed;
}

/// Liveness: a guardian (or the admin) can always cancel a pending treasury change, at any time.
rule guardianOrAdminCanAlwaysCancelTreasury(env e) {
    require e.msg.value == 0;
    require hasRole(VAULT_GUARDIAN_ROLE(), e.msg.sender) || hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);
    require pendingTreasury() != 0;
    cancelTreasuryChange@withrevert(e);
    assert !lastReverted;
    assert pendingTreasury() == 0 && pendingTreasuryExecutableAt() == 0;
}

/// proposeTreasury stores the candidate with executableAt = proposal timestamp + 72 hours and does not change the
/// active treasury.
rule proposeTreasuryStoresCandidateWithExactDelay(env e, address candidate) {
    address treasuryBefore = treasury();
    proposeTreasury(e, candidate);
    assert pendingTreasury() == candidate;
    assert to_mathint(pendingTreasuryExecutableAt()) == e.block.timestamp + DELAY();
    assert treasury() == treasuryBefore;
}

/// A proposal never overwrites a pending change; invalid candidates are rejected.
rule proposeTreasuryRevertsWhileAChangeIsPending(env e, address candidate) {
    require pendingTreasury() != 0;
    proposeTreasury@withrevert(e, candidate);
    assert lastReverted;
}

rule proposeTreasuryRejectsInvalidCandidates(env e, address candidate) {
    require candidate == 0 || candidate == currentContract;
    proposeTreasury@withrevert(e, candidate);
    assert lastReverted;
}

/// No execution before executableAt; none without a pending change.
rule executeTreasuryRevertsBeforeExecutableAt(env e) {
    require e.block.timestamp < pendingTreasuryExecutableAt();
    executeTreasuryChange@withrevert(e);
    assert lastReverted;
}

rule executeTreasuryRevertsWithoutPendingChange(env e) {
    require pendingTreasury() == 0;
    executeTreasuryChange@withrevert(e);
    assert lastReverted;
}

/// No bypass: after the deployment the treasury only changes through a successful executeTreasuryChange by the
/// admin, from executableAt on, and only to the pending treasury.
rule treasuryOnlyChangesThroughMaturedExecution(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    address treasuryBefore = treasury();
    address pendingBefore = pendingTreasury();
    uint256 atBefore = pendingTreasuryExecutableAt();
    bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);

    f(e, args);

    assert treasury() != treasuryBefore => (
        f.selector == sig:executeTreasuryChange().selector && isAdmin && pendingBefore != 0
            && treasury() == pendingBefore && e.block.timestamp >= atBefore
    );
}

/// No method shortens or modifies a pending treasury change; a new one always gets proposal timestamp + 72 hours.
rule pendingTreasuryCannotBeShortened(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    address pendingBefore = pendingTreasury();
    uint256 atBefore = pendingTreasuryExecutableAt();

    f(e, args);

    address pendingAfter = pendingTreasury();
    uint256 atAfter = pendingTreasuryExecutableAt();
    assert pendingAfter != 0 => (
        (pendingAfter == pendingBefore && atAfter == atBefore)
            || (pendingBefore == 0 && f.selector == sig:proposeTreasury(address).selector
                && to_mathint(atAfter) == e.block.timestamp + DELAY())
    );
}

/// The pending treasury is only removed by cancelTreasuryChange or executeTreasuryChange.
rule pendingTreasuryOnlyClearedByCancelOrExecute(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    address pendingBefore = pendingTreasury();
    f(e, args);
    assert (pendingBefore != 0 && pendingTreasury() != pendingBefore) => (
        f.selector == sig:cancelTreasuryChange().selector || f.selector == sig:executeTreasuryChange().selector
    );
}

/// A successful execution activates the pending treasury and clears it.
rule executeTreasuryActivatesPendingAndClearsIt(env e) {
    address pendingBefore = pendingTreasury();
    uint256 atBefore = pendingTreasuryExecutableAt();

    executeTreasuryChange(e);

    assert pendingBefore != 0 && e.block.timestamp >= atBefore;
    assert treasury() == pendingBefore;
    assert pendingTreasury() == 0 && pendingTreasuryExecutableAt() == 0;
}

/// cancelTreasuryChange clears the pending change and keeps the active treasury.
rule cancelTreasuryClearsPendingOnly(env e) {
    address treasuryBefore = treasury();
    address pendingBefore = pendingTreasury();

    cancelTreasuryChange(e);

    assert pendingBefore != 0;
    assert pendingTreasury() == 0 && pendingTreasuryExecutableAt() == 0;
    assert treasury() == treasuryBefore;
}

/// The treasury lifecycle functions never touch the fees, the vault, the routing, the pause, the other pending
/// changes nor the overrides.
rule treasuryLifecycleKeepsEverythingElse(method f, env e, calldataarg args, address r)
    filtered {
        f -> f.contract == currentContract && (
            f.selector == sig:proposeTreasury(address).selector || f.selector == sig:executeTreasuryChange().selector
                || f.selector == sig:cancelTreasuryChange().selector
        )
    }
{
    Forwarder.FeeModel lowerBefore = lowerFeeModel();
    Forwarder.FeeModel upperBefore = upperFeeModel();
    uint256 thresholdBefore = threshold();
    uint256 fixedBefore = fixedFee();
    uint256 variableBefore = variableFee();
    uint256 pendingFeeAtBefore = pendingFeeExecutableAt();
    address vaultBefore = vault();
    address pendingVaultBefore = pendingVault();
    Forwarder.RoutingMode modeBefore = routingMode();
    bool pausedBefore = paused();
    uint256 overrideUBefore = overrideUntil(r);
    uint256 overrideFBefore = overrideFixed(r);

    f(e, args);

    assert lowerFeeModel() == lowerBefore && upperFeeModel() == upperBefore && threshold() == thresholdBefore;
    assert fixedFee() == fixedBefore && variableFee() == variableBefore;
    assert pendingFeeExecutableAt() == pendingFeeAtBefore;
    assert vault() == vaultBefore && pendingVault() == pendingVaultBefore && routingMode() == modeBefore;
    assert paused() == pausedBefore && overrideUntil(r) == overrideUBefore && overrideFixed(r) == overrideFBefore;
}

/// While a change is pending, rescueToken pays the active treasury, never the pending one.
rule rescueWhileTreasuryPendingPaysTheActiveTreasury(env e) {
    linkModel();
    requireInvariant treasuryIsValid();
    address t = treasury();
    address p = pendingTreasury();
    require p != 0 && p != t && p != currentContract;
    mathint forwarderBefore = usdcBalance(currentContract);
    mathint treasuryBefore = usdcBalance(t);
    mathint pendingBefore = usdcBalance(p);

    rescueToken(e, usdc);

    assert to_mathint(usdcBalance(t)) == treasuryBefore + forwarderBefore;
    assert to_mathint(usdcBalance(p)) == pendingBefore;
}

/// forward never pays the pending treasury (USDC or shares) while it is only pending.
rule forwardNeverPaysThePendingTreasury(env e, uint256 amount, address recipient) {
    linkForward();
    requireInvariant treasuryIsValid();
    address p = pendingTreasury();
    require p != 0 && p != treasury() && p != recipient && p != e.msg.sender && p != currentContract;
    mathint pendingBefore = usdcBalance(p) + dvault.balanceOf(p);

    forward(e, usdc, amount, recipient);

    assert usdcBalance(p) + dvault.balanceOf(p) == pendingBefore;
}

// -------------------------------------------------------------------------------------------------------------------
// Access control (V1, re-proven on V3; V3 additions)
// -------------------------------------------------------------------------------------------------------------------

/// Only FEE_MANAGER_ROLE changes the fee configuration.
rule onlyFeeManagerChangesFeeConfig(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    requireInvariant enumsAreValid();
    Forwarder.FeeModel lowerBefore = lowerFeeModel();
    Forwarder.FeeModel upperBefore = upperFeeModel();
    uint256 thresholdBefore = threshold();
    uint256 fixedBefore = fixedFee();
    uint256 variableBefore = variableFee();
    bool isManager = hasRole(FEE_MANAGER_ROLE(), e.msg.sender);

    f(e, args);

    bool changed = lowerFeeModel() != lowerBefore || upperFeeModel() != upperBefore || threshold() != thresholdBefore
        || fixedFee() != fixedBefore || variableFee() != variableBefore;
    assert changed => isManager;
}

/// Only DEFAULT_ADMIN_ROLE changes the treasury.
rule onlyAdminChangesTreasury(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    address before = treasury();
    bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);
    f(e, args);
    assert treasury() != before => isAdmin;
}

/// Only DEFAULT_ADMIN_ROLE changes the vault.
rule onlyAdminChangesVault(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    address before = vault();
    bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);
    f(e, args);
    assert vault() != before => isAdmin;
}

/// Only DEFAULT_ADMIN_ROLE changes the routing mode.
rule onlyAdminChangesRoutingMode(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    requireInvariant enumsAreValid();
    Forwarder.RoutingMode before = routingMode();
    bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);
    f(e, args);
    assert routingMode() != before => isAdmin;
}

/// Only DEFAULT_ADMIN_ROLE unpauses fees.
rule onlyAdminUnpauses(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    bool pausedBefore = paused();
    bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);
    f(e, args);
    assert (pausedBefore && !paused()) => isAdmin;
}

/// Only FEE_MANAGER_ROLE or DEFAULT_ADMIN_ROLE pause fees.
rule onlyPrivilegedPause(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    bool pausedBefore = paused();
    bool privileged = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender) || hasRole(FEE_MANAGER_ROLE(), e.msg.sender);
    f(e, args);
    assert (!pausedBefore && paused()) => privileged;
}

/// A fee manager without the admin role cannot change treasury, vault or routing, nor unpause.
rule feeManagerCannotAdminister(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    requireInvariant enumsAreValid();
    require hasRole(FEE_MANAGER_ROLE(), e.msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);
    address treasuryBefore = treasury();
    address vaultBefore = vault();
    Forwarder.RoutingMode modeBefore = routingMode();
    bool pausedBefore = paused();

    f@withrevert(e, args);

    assert treasury() == treasuryBefore;
    assert vault() == vaultBefore;
    assert routingMode() == modeBefore;
    assert pausedBefore => paused();
}

/// An account without roles (and not the pending default admin) changes no configuration.
rule unprivilegedChangesNoConfiguration(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    requireInvariant enumsAreValid();
    require !hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender) && !hasRole(FEE_MANAGER_ROLE(), e.msg.sender);

    address treasuryBefore = treasury();
    address vaultBefore = vault();
    Forwarder.RoutingMode modeBefore = routingMode();
    bool pausedBefore = paused();
    uint256 thresholdBefore = threshold();
    uint256 fixedBefore = fixedFee();
    uint256 variableBefore = variableFee();
    Forwarder.FeeModel lowerBefore = lowerFeeModel();
    Forwarder.FeeModel upperBefore = upperFeeModel();

    f@withrevert(e, args);

    assert treasury() == treasuryBefore && vault() == vaultBefore && routingMode() == modeBefore;
    assert paused() == pausedBefore;
    assert threshold() == thresholdBefore && fixedFee() == fixedBefore && variableFee() == variableBefore;
    assert lowerFeeModel() == lowerBefore && upperFeeModel() == upperBefore;
}

/// FEE_MANAGER_ROLE membership only changes by the admin (grant/revoke) or by the account itself (renounce).
rule feeManagerRoleOnlyChangedByAdminOrSelf(method f, env e, calldataarg args, address account)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    requireInvariant feeManagerAdminIsDefaultAdmin();
    bool before = hasRole(FEE_MANAGER_ROLE(), account);
    bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);

    f(e, args);

    assert hasRole(FEE_MANAGER_ROLE(), account) != before => (isAdmin || (e.msg.sender == account && before));
}

/// VAULT_GUARDIAN_ROLE membership only changes by the admin (grant/revoke) or by the account itself (renounce).
rule guardianRoleOnlyChangedByAdminOrSelf(method f, env e, calldataarg args, address account)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    requireInvariant guardianAdminIsDefaultAdmin();
    bool before = hasRole(VAULT_GUARDIAN_ROLE(), account);
    bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);

    f(e, args);

    assert hasRole(VAULT_GUARDIAN_ROLE(), account) != before => (isAdmin || (e.msg.sender == account && before));
}

/// A guardian (without admin and fee manager roles) can only clear pending changes: it never changes the active
/// configuration, the overrides, nor sets or modifies a pending change.
rule guardianCanOnlyCancel(method f, env e, calldataarg args, address r)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    requireInvariant enumsAreValid();
    require hasRole(VAULT_GUARDIAN_ROLE(), e.msg.sender);
    require !hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender) && !hasRole(FEE_MANAGER_ROLE(), e.msg.sender);
    address treasuryBefore = treasury();
    address vaultBefore = vault();
    Forwarder.RoutingMode modeBefore = routingMode();
    bool pausedBefore = paused();
    uint256 thresholdBefore = threshold();
    uint256 fixedBefore = fixedFee();
    uint256 variableBefore = variableFee();
    Forwarder.FeeModel lowerBefore = lowerFeeModel();
    Forwarder.FeeModel upperBefore = upperFeeModel();
    uint256 overrideFBefore = overrideFixed(r);
    uint256 overrideVBefore = overrideVariable(r);
    uint256 overrideUBefore = overrideUntil(r);
    address pendingVaultBefore = pendingVault();
    uint256 vaultAtBefore = pendingVaultExecutableAt();
    address pendingTreasuryBefore = pendingTreasury();
    uint256 treasuryAtBefore = pendingTreasuryExecutableAt();
    uint256 feeAtBefore = pendingFeeExecutableAt();
    uint256 pendingFixedBefore = pendingFixedFee();

    f@withrevert(e, args);

    assert treasury() == treasuryBefore && vault() == vaultBefore && routingMode() == modeBefore;
    assert paused() == pausedBefore;
    assert threshold() == thresholdBefore && fixedFee() == fixedBefore && variableFee() == variableBefore;
    assert lowerFeeModel() == lowerBefore && upperFeeModel() == upperBefore;
    assert overrideFixed(r) == overrideFBefore && overrideVariable(r) == overrideVBefore;
    assert overrideUntil(r) == overrideUBefore;
    assert (pendingVault() == pendingVaultBefore && pendingVaultExecutableAt() == vaultAtBefore) || pendingVault() == 0;
    assert (pendingTreasury() == pendingTreasuryBefore && pendingTreasuryExecutableAt() == treasuryAtBefore)
        || pendingTreasury() == 0;
    assert (pendingFeeExecutableAt() == feeAtBefore && pendingFixedFee() == pendingFixedBefore)
        || pendingFeeExecutableAt() == 0;
}

/// A fee manager (without admin and guardian roles) cannot touch the treasury nor its pending change.
rule feeManagerCannotTouchTheTreasury(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    require hasRole(FEE_MANAGER_ROLE(), e.msg.sender);
    require !hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender) && !hasRole(VAULT_GUARDIAN_ROLE(), e.msg.sender);
    address treasuryBefore = treasury();
    address pendingBefore = pendingTreasury();
    uint256 atBefore = pendingTreasuryExecutableAt();

    f@withrevert(e, args);

    assert treasury() == treasuryBefore && pendingTreasury() == pendingBefore && pendingTreasuryExecutableAt() == atBefore;
}

/// The admin without FEE_MANAGER_ROLE cannot change the fee configuration nor the overrides, nor set a pending fee
/// configuration (it can only cancel one).
rule adminWithoutFeeRoleCannotChangeFees(method f, env e, calldataarg args, address r)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    requireInvariant enumsAreValid();
    require hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender) && !hasRole(FEE_MANAGER_ROLE(), e.msg.sender);
    uint256 thresholdBefore = threshold();
    uint256 fixedBefore = fixedFee();
    uint256 variableBefore = variableFee();
    Forwarder.FeeModel lowerBefore = lowerFeeModel();
    Forwarder.FeeModel upperBefore = upperFeeModel();
    uint256 overrideFBefore = overrideFixed(r);
    uint256 overrideVBefore = overrideVariable(r);
    uint256 overrideUBefore = overrideUntil(r);
    uint256 feeAtBefore = pendingFeeExecutableAt();
    uint256 pendingFixedBefore = pendingFixedFee();

    f@withrevert(e, args);

    assert threshold() == thresholdBefore && fixedFee() == fixedBefore && variableFee() == variableBefore;
    assert lowerFeeModel() == lowerBefore && upperFeeModel() == upperBefore;
    assert overrideFixed(r) == overrideFBefore && overrideVariable(r) == overrideVBefore;
    assert overrideUntil(r) == overrideUBefore;
    assert (pendingFeeExecutableAt() == feeAtBefore && pendingFixedFee() == pendingFixedBefore)
        || pendingFeeExecutableAt() == 0;
}

// -------------------------------------------------------------------------------------------------------------------
// Vault change lifecycle (V2, re-proven on V3)
// -------------------------------------------------------------------------------------------------------------------

/// Only DEFAULT_ADMIN_ROLE proposes.
rule onlyAdminProposes(env e, address candidate) {
    bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);
    proposeVault@withrevert(e, candidate);
    assert !lastReverted => isAdmin;
}

/// Only DEFAULT_ADMIN_ROLE executes.
rule onlyAdminExecutes(env e) {
    bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);
    executeVaultChange@withrevert(e);
    assert !lastReverted => isAdmin;
}

/// Only DEFAULT_ADMIN_ROLE or VAULT_GUARDIAN_ROLE cancel.
rule onlyAdminOrGuardianCancels(env e) {
    bool allowed = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender) || hasRole(VAULT_GUARDIAN_ROLE(), e.msg.sender);
    cancelVaultChange@withrevert(e);
    assert !lastReverted => allowed;
}

/// Liveness: a guardian (or the admin) can always cancel a pending change, at any time.
rule guardianOrAdminCanAlwaysCancel(env e) {
    require e.msg.value == 0;
    require hasRole(VAULT_GUARDIAN_ROLE(), e.msg.sender) || hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);
    require pendingVault() != 0;
    cancelVaultChange@withrevert(e);
    assert !lastReverted;
    assert pendingVault() == 0 && pendingVaultExecutableAt() == 0;
}

/// A guardian without the admin role can neither propose nor execute.
rule guardianCannotProposeOrExecute(method f, env e, calldataarg args)
    filtered {
        f -> f.contract == currentContract
            && (f.selector == sig:proposeVault(address).selector || f.selector == sig:executeVaultChange().selector)
    }
{
    require hasRole(VAULT_GUARDIAN_ROLE(), e.msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);
    f@withrevert(e, args);
    assert lastReverted;
}

/// A fee manager without the admin and guardian roles cannot touch the active vault nor the pending change.
rule feeManagerCannotAdministerVault(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    require hasRole(FEE_MANAGER_ROLE(), e.msg.sender);
    require !hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender) && !hasRole(VAULT_GUARDIAN_ROLE(), e.msg.sender);
    address vaultBefore = vault();
    address pendingBefore = pendingVault();
    uint256 atBefore = pendingVaultExecutableAt();

    f@withrevert(e, args);

    assert vault() == vaultBefore && pendingVault() == pendingBefore && pendingVaultExecutableAt() == atBefore;
}

/// An account without any role cannot touch the active vault nor the pending change.
rule unprivilegedCannotTouchVaultLifecycle(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    require !hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender) && !hasRole(FEE_MANAGER_ROLE(), e.msg.sender);
    require !hasRole(VAULT_GUARDIAN_ROLE(), e.msg.sender);
    address vaultBefore = vault();
    address pendingBefore = pendingVault();
    uint256 atBefore = pendingVaultExecutableAt();

    f@withrevert(e, args);

    assert vault() == vaultBefore && pendingVault() == pendingBefore && pendingVaultExecutableAt() == atBefore;
}

/// The delay is the constant 72 hours.
rule vaultChangeDelayIs72Hours() {
    assert VAULT_CHANGE_DELAY() == 259200;
}

/// proposeVault stores the candidate with executableAt = proposal timestamp + 72 hours and does not change the active
/// vault, the routing nor the active vault allowance.
rule proposeStoresCandidateWithExactDelay(env e, address candidate) {
    linkModel();
    require candidate == dvault || candidate == dvault2;
    require e.msg.sender != currentContract && e.msg.sender != dvault && e.msg.sender != dvault2;
    address vaultBefore = vault();
    Forwarder.RoutingMode modeBefore = routingMode();
    uint256 activeAllowanceBefore = vaultAllowance();

    proposeVault(e, candidate);

    assert pendingVault() == candidate;
    assert to_mathint(pendingVaultExecutableAt()) == e.block.timestamp + 259200;
    assert vault() == vaultBefore;
    assert routingMode() == modeBefore;
    assert vaultAllowance() == activeAllowanceBefore;
}

/// A proposal never overwrites a pending change.
rule proposeRevertsWhileAChangeIsPending(env e, address candidate) {
    require pendingVault() != 0;
    proposeVault@withrevert(e, candidate);
    assert lastReverted;
}

/// No execution before executableAt, whoever calls and whatever the state.
rule executeRevertsBeforeExecutableAt(env e) {
    require e.block.timestamp < pendingVaultExecutableAt();
    executeVaultChange@withrevert(e);
    assert lastReverted;
}

rule executeRevertsWithoutPendingChange(env e) {
    require pendingVault() == 0;
    executeVaultChange@withrevert(e);
    assert lastReverted;
}

/// After the deployment the active vault only changes through a successful executeVaultChange, from executableAt on,
/// and only to the pending vault.
rule vaultOnlyChangesThroughExecuteAfterDelay(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    address vaultBefore = vault();
    address pendingBefore = pendingVault();
    uint256 atBefore = pendingVaultExecutableAt();
    bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);

    f(e, args);

    assert vault() != vaultBefore => (
        f.selector == sig:executeVaultChange().selector && isAdmin && pendingBefore != 0 && vault() == pendingBefore
            && e.block.timestamp >= atBefore
    );
}

/// No method shortens or modifies the delay of a pending change.
rule pendingChangeCannotBeShortened(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    address pendingBefore = pendingVault();
    uint256 atBefore = pendingVaultExecutableAt();

    f(e, args);

    address pendingAfter = pendingVault();
    uint256 atAfter = pendingVaultExecutableAt();
    assert pendingAfter != 0 => (
        (pendingAfter == pendingBefore && atAfter == atBefore)
            || (pendingBefore == 0 && f.selector == sig:proposeVault(address).selector
                && to_mathint(atAfter) == e.block.timestamp + 259200)
    );
}

/// Guardian grants, revocations and renouncements never alter any pending change nor its timestamp (vault, and in
/// V3 also fee configuration and treasury).
rule guardianRoleChangesKeepPendingChange(method f, env e, calldataarg args)
    filtered {
        f -> f.contract == currentContract && (
            f.selector == sig:grantRole(bytes32, address).selector
                || f.selector == sig:revokeRole(bytes32, address).selector
                || f.selector == sig:renounceRole(bytes32, address).selector
        )
    }
{
    address pendingBefore = pendingVault();
    uint256 atBefore = pendingVaultExecutableAt();
    address pendingTreasuryBefore = pendingTreasury();
    uint256 treasuryAtBefore = pendingTreasuryExecutableAt();
    uint256 feeAtBefore = pendingFeeExecutableAt();
    f(e, args);
    assert pendingVault() == pendingBefore && pendingVaultExecutableAt() == atBefore;
    assert pendingTreasury() == pendingTreasuryBefore && pendingTreasuryExecutableAt() == treasuryAtBefore;
    assert pendingFeeExecutableAt() == feeAtBefore;
}

/// cancelVaultChange clears the pending change and touches nothing else of the vault configuration.
rule cancelClearsPendingOnly(env e) {
    linkModel();
    address vaultBefore = vault();
    address pendingBefore = pendingVault();
    Forwarder.RoutingMode modeBefore = routingMode();
    uint256 activeAllowanceBefore = vaultAllowance();

    cancelVaultChange(e);

    assert pendingBefore != 0;
    assert pendingVault() == 0 && pendingVaultExecutableAt() == 0;
    assert vault() == vaultBefore && routingMode() == modeBefore && vaultAllowance() == activeAllowanceBefore;
}

/// A successful executeVaultChange activates the pending vault and clears the pending change.
rule executeActivatesPendingVaultAndClearsIt(env e) {
    linkModel();
    require e.msg.sender != currentContract && e.msg.sender != dvault && e.msg.sender != dvault2;
    address pendingBefore = pendingVault();
    uint256 atBefore = pendingVaultExecutableAt();

    executeVaultChange(e);

    assert pendingBefore != 0 && e.block.timestamp >= atBefore;
    assert vault() == pendingBefore;
    assert pendingVault() == 0 && pendingVaultExecutableAt() == 0;
}

/// A failed executeVaultChange keeps the pending change, the active vault and both allowances (EVM atomicity).
rule failedExecutionKeepsState(env e) {
    address vaultBefore = vault();
    address pendingBefore = pendingVault();
    uint256 atBefore = pendingVaultExecutableAt();
    uint256 activeAllowanceBefore = vaultAllowance();
    uint256 pendingAllowanceBefore = allowanceTo(pendingBefore);

    executeVaultChange@withrevert(e);

    assert lastReverted => (
        vault() == vaultBefore && pendingVault() == pendingBefore && pendingVaultExecutableAt() == atBefore
            && vaultAllowance() == activeAllowanceBefore && allowanceTo(pendingBefore) == pendingAllowanceBefore
    );
}

/// The pending change is only removed by cancelVaultChange or executeVaultChange.
rule pendingOnlyClearedByCancelOrExecute(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    address pendingBefore = pendingVault();
    f(e, args);
    assert (pendingBefore != 0 && pendingVault() != pendingBefore) => (
        f.selector == sig:cancelVaultChange().selector || f.selector == sig:executeVaultChange().selector
    );
}

/// The vault lifecycle functions never modify fees, treasury, pause state, routing, the other pending changes nor
/// the overrides.
rule vaultLifecycleKeepsConfiguration(method f, env e, calldataarg args, address r)
    filtered {
        f -> f.contract == currentContract && (
            f.selector == sig:proposeVault(address).selector || f.selector == sig:executeVaultChange().selector
                || f.selector == sig:cancelVaultChange().selector
        )
    }
{
    linkModel();
    address treasuryBefore = treasury();
    Forwarder.RoutingMode modeBefore = routingMode();
    bool pausedBefore = paused();
    uint256 thresholdBefore = threshold();
    uint256 fixedBefore = fixedFee();
    uint256 variableBefore = variableFee();
    Forwarder.FeeModel lowerBefore = lowerFeeModel();
    Forwarder.FeeModel upperBefore = upperFeeModel();
    address pendingTreasuryBefore = pendingTreasury();
    uint256 feeAtBefore = pendingFeeExecutableAt();
    uint256 overrideUBefore = overrideUntil(r);

    f(e, args);

    assert treasury() == treasuryBefore && routingMode() == modeBefore && paused() == pausedBefore;
    assert threshold() == thresholdBefore && fixedFee() == fixedBefore && variableFee() == variableBefore;
    assert lowerFeeModel() == lowerBefore && upperFeeModel() == upperBefore;
    assert pendingTreasury() == pendingTreasuryBefore && pendingFeeExecutableAt() == feeAtBefore;
    assert overrideUntil(r) == overrideUBefore;
}

/// After a proposal the candidate holds no allowance.
rule proposeLeavesNoCandidateAllowance(env e, address candidate) {
    linkModel();
    require candidate == dvault || candidate == dvault2;
    require e.msg.sender != currentContract && e.msg.sender != dvault && e.msg.sender != dvault2;

    proposeVault(e, candidate);

    assert allowanceTo(candidate) == 0;
}

/// executeVaultChange: the previous vault ends with zero allowance and the new one with MAX if the routing mode in
/// force at execution uses the vault, zero otherwise.
rule executeAllowancesFollowCurrentRouting(env e) {
    linkModel();
    require e.msg.sender != currentContract && e.msg.sender != dvault && e.msg.sender != dvault2;
    address oldVault = vault();
    address newVault = pendingVault();
    Forwarder.RoutingMode mode = routingMode();

    executeVaultChange(e);

    assert routingMode() == mode;
    assert oldVault != 0 => allowanceTo(oldVault) == 0;
    assert usesVault(mode) => to_mathint(allowanceTo(newVault)) == MAX_UINT();
    assert !usesVault(mode) => allowanceTo(newVault) == 0;
}

/// Same, with any routing change made while the change was pending: the routing in force at execution decides.
rule executeUsesRoutingInForceAtExecution(env eAdmin, env e, Forwarder.RoutingMode modeWhilePending) {
    linkModel();
    require e.msg.sender != currentContract && e.msg.sender != dvault && e.msg.sender != dvault2;
    require eAdmin.msg.sender != currentContract;
    address oldVault = vault();
    address newVault = pendingVault();

    setRoutingMode(eAdmin, modeWhilePending);
    executeVaultChange(e);

    assert oldVault != 0 => allowanceTo(oldVault) == 0;
    assert usesVault(modeWhilePending) => to_mathint(allowanceTo(newVault)) == MAX_UINT();
    assert !usesVault(modeWhilePending) => allowanceTo(newVault) == 0;
}

/// forward keeps every pending change (vault, fee configuration, treasury) and the pending vault allowance.
rule forwardKeepsPendingChange(env e, address token, uint256 amount, address recipient) {
    linkForward();
    address pendingBefore = pendingVault();
    uint256 atBefore = pendingVaultExecutableAt();
    uint256 pendingAllowanceBefore = allowanceTo(pendingBefore);
    address pendingTreasuryBefore = pendingTreasury();
    uint256 feeAtBefore = pendingFeeExecutableAt();

    forward(e, token, amount, recipient);

    assert pendingVault() == pendingBefore && pendingVaultExecutableAt() == atBefore;
    assert allowanceTo(pendingBefore) == pendingAllowanceBefore;
    assert pendingTreasury() == pendingTreasuryBefore && pendingFeeExecutableAt() == feeAtBefore;
}

/// The proposal health check only uses the caller's funds and returns them (1:1 vault).
rule proposeHealthCheckUsesOnlyCallerFunds(env e, address candidate) {
    linkModel();
    require candidate == dvault || candidate == dvault2;
    require e.msg.sender != currentContract && e.msg.sender != dvault && e.msg.sender != dvault2;
    mathint forwarderBefore = usdcBalance(currentContract);
    mathint callerBefore = usdcBalance(e.msg.sender);

    proposeVault(e, candidate);

    assert to_mathint(usdcBalance(currentContract)) == forwarderBefore;
    assert to_mathint(usdcBalance(e.msg.sender)) == callerBefore;
}

/// Same for the execution health check.
rule executeHealthCheckUsesOnlyCallerFunds(env e) {
    linkModel();
    require e.msg.sender != currentContract && e.msg.sender != dvault && e.msg.sender != dvault2;
    mathint forwarderBefore = usdcBalance(currentContract);
    mathint callerBefore = usdcBalance(e.msg.sender);

    executeVaultChange(e);

    assert to_mathint(usdcBalance(currentContract)) == forwarderBefore;
    assert to_mathint(usdcBalance(e.msg.sender)) == callerBefore;
}

// -------------------------------------------------------------------------------------------------------------------
// Routing and allowances (V1)
// -------------------------------------------------------------------------------------------------------------------

/// setRoutingMode: unlimited allowance when switching to a vault mode, zero when switching to DIRECT_DIRECT,
/// untouched when the vault usage does not change.
rule routingModeAllowance(env e, Forwarder.RoutingMode newMode) {
    linkModel();
    require vault() != 0;
    requireInvariant directDirectMeansNoVaultAllowance();
    Forwarder.RoutingMode oldMode = routingMode();
    uint256 before = vaultAllowance();

    setRoutingMode(e, newMode);

    assert routingMode() == newMode;
    assert !usesVault(newMode) => vaultAllowance() == 0;
    assert (usesVault(newMode) && !usesVault(oldMode)) => to_mathint(vaultAllowance()) == MAX_UINT();
    assert (usesVault(newMode) == usesVault(oldMode)) => vaultAllowance() == before;
}

/// forward never raises the vault allowance (it never approves).
rule forwardNeverApproves(env e, address token, uint256 amount, address recipient) {
    linkForward();
    uint256 before = vaultAllowance();
    forward(e, token, amount, recipient);
    assert vaultAllowance() <= before;
}

// -------------------------------------------------------------------------------------------------------------------
// forward accounting with the effective fee (V1 rules, fee = calculateFeeFor(recipient, amount))
// -------------------------------------------------------------------------------------------------------------------

/// The recipient receives exactly amount - effective fee, as USDC or as vault shares (1:1 vault).
rule forwardUserReceivesAmountMinusFee(env e, uint256 amount, address recipient) {
    linkForward();
    require recipient != currentContract && recipient != treasury() && recipient != e.msg.sender;
    require recipient != usdc && recipient != dvault;
    require e.msg.sender != currentContract;
    uint256 fee = calculateFeeFor(e, recipient, amount);
    mathint usdcBefore = usdcBalance(recipient);
    mathint sharesBefore = dvault.balanceOf(recipient);

    forward(e, usdc, amount, recipient);

    mathint received = usdcBalance(recipient) - usdcBefore + dvault.balanceOf(recipient) - sharesBefore;
    assert received == amount - fee;
}

/// After forward the Forwarder either delivered everything to the treasury or kept previous balance + fee.
rule forwardTreasuryAccounting(env e, uint256 amount, address recipient) {
    linkForward();
    requireInvariant treasuryIsValid();
    address t = treasury();
    require recipient != currentContract && recipient != t && recipient != e.msg.sender;
    require recipient != usdc && recipient != dvault && t != e.msg.sender;
    require e.msg.sender != currentContract;
    uint256 fee = calculateFeeFor(e, recipient, amount);
    mathint forwarderBefore = usdcBalance(currentContract);
    mathint treasuryBefore = usdcBalance(t) + dvault.balanceOf(t);

    forward(e, usdc, amount, recipient);

    mathint forwarderAfter = usdcBalance(currentContract);
    mathint treasuryAfter = usdcBalance(t) + dvault.balanceOf(t);
    assert forwarderAfter == 0 || forwarderAfter == forwarderBefore + fee;
    assert treasuryAfter + forwarderAfter == treasuryBefore + forwarderBefore + fee;
}

/// A treasury delivery that fails (treasury blocked by USDC or failing vault deposit) never makes forward revert.
rule treasuryFailureNeverRevertsForward(env e, uint256 amount, address recipient) {
    linkForward();
    requireInvariant treasuryIsValid();
    requireInvariant vaultModeHasVault();
    address t = treasury();
    require e.msg.value == 0;
    require usdc.blocked(t) || dvault.depositReverts();
    require !usdc.blocked(recipient) && !usdc.blocked(e.msg.sender) && !usdc.blocked(currentContract);
    require recipient != 0 && recipient != currentContract && recipient != t;
    require e.msg.sender != currentContract && e.msg.sender != t;
    uint256 fee = calculateFeeFor(e, recipient, amount);
    require fee <= amount;
    require usdc.balanceOf(e.msg.sender) >= amount;
    require usdc.allowance(e.msg.sender, currentContract) >= amount;
    require usdc.balanceOf(currentContract) + amount <= MAX_UINT();
    require usdc.balanceOf(recipient) + amount <= MAX_UINT();
    require usdc.balanceOf(dvault) + amount + usdc.balanceOf(currentContract) <= MAX_UINT();
    require dvault.balanceOf(recipient) + amount <= MAX_UINT();

    forward@withrevert(e, usdc, amount, recipient);

    assert !lastReverted;
}

/// paused fees: the recipient receives the whole amount (override or not).
rule pausedForwardDeliversWholeAmount(env e, uint256 amount, address recipient) {
    linkForward();
    require paused();
    require recipient != currentContract && recipient != treasury() && recipient != e.msg.sender;
    require recipient != usdc && recipient != dvault && e.msg.sender != currentContract;
    mathint before = usdcBalance(recipient) + dvault.balanceOf(recipient);
    forward(e, usdc, amount, recipient);
    assert usdcBalance(recipient) + dvault.balanceOf(recipient) == before + amount;
}

/// forward does not change any configuration, pending change or override.
rule forwardDoesNotChangeConfiguration(env e, address token, uint256 amount, address recipient, address r) {
    address treasuryBefore = treasury();
    address vaultBefore = vault();
    Forwarder.RoutingMode modeBefore = routingMode();
    bool pausedBefore = paused();
    uint256 fixedBefore = fixedFee();
    uint256 variableBefore = variableFee();
    uint256 thresholdBefore = threshold();
    uint256 feeAtBefore = pendingFeeExecutableAt();
    address pendingTreasuryBefore = pendingTreasury();
    uint256 overrideUBefore = overrideUntil(r);
    uint256 overrideFBefore = overrideFixed(r);
    forward(e, token, amount, recipient);
    assert treasury() == treasuryBefore && vault() == vaultBefore && routingMode() == modeBefore;
    assert paused() == pausedBefore && fixedFee() == fixedBefore && variableFee() == variableBefore;
    assert threshold() == thresholdBefore;
    assert pendingFeeExecutableAt() == feeAtBefore && pendingTreasury() == pendingTreasuryBefore;
    assert overrideUntil(r) == overrideUBefore && overrideFixed(r) == overrideFBefore;
}

/// forward only accepts USDC.
rule forwardOnlyAcceptsUsdc(env e, address token, uint256 amount, address recipient) {
    linkModel();
    forward@withrevert(e, token, amount, recipient);
    assert token != usdc => lastReverted;
}

/// Same accounting rules for every fee configuration (applied through the delay), routing mode and override of the
/// recipient.
function configureAll(
    env eManager,
    env eExecute,
    env eAdmin,
    env eOverride,
    Forwarder.FeeModel lower,
    Forwarder.FeeModel upper,
    uint256 thr,
    uint256 fixedF,
    uint256 variableF,
    Forwarder.RoutingMode mode,
    address recipient,
    uint256 overrideF,
    uint256 overrideV,
    uint256 until
) {
    configureFees(eManager, eExecute, lower, upper, thr, fixedF, variableF);
    setRoutingMode(eAdmin, mode);
    setUserFeeOverride(eOverride, recipient, overrideF, overrideV, until);
}

rule forwardUserReceivesAmountMinusFeeForAnyConfiguration(
    env e,
    env eManager,
    env eExecute,
    env eAdmin,
    env eOverride,
    Forwarder.FeeModel lower,
    Forwarder.FeeModel upper,
    uint256 thr,
    uint256 fixedF,
    uint256 variableF,
    Forwarder.RoutingMode mode,
    uint256 overrideF,
    uint256 overrideV,
    uint256 until,
    uint256 amount,
    address recipient
) {
    linkForward();
    require vault() == dvault;
    configureAll(eManager, eExecute, eAdmin, eOverride, lower, upper, thr, fixedF, variableF, mode, recipient, overrideF, overrideV, until);
    require recipient != currentContract && recipient != treasury() && recipient != e.msg.sender;
    require recipient != usdc && recipient != dvault;
    require e.msg.sender != currentContract;
    uint256 fee = calculateFeeFor(e, recipient, amount);
    mathint usdcBefore = usdcBalance(recipient);
    mathint sharesBefore = dvault.balanceOf(recipient);

    forward(e, usdc, amount, recipient);

    mathint received = usdcBalance(recipient) - usdcBefore + dvault.balanceOf(recipient) - sharesBefore;
    assert received == amount - fee;
    assert fee <= calculateFee(amount);
}

rule forwardTreasuryAccountingForAnyConfiguration(
    env e,
    env eManager,
    env eExecute,
    env eAdmin,
    env eOverride,
    Forwarder.FeeModel lower,
    Forwarder.FeeModel upper,
    uint256 thr,
    uint256 fixedF,
    uint256 variableF,
    Forwarder.RoutingMode mode,
    uint256 overrideF,
    uint256 overrideV,
    uint256 until,
    uint256 amount,
    address recipient
) {
    linkForward();
    requireInvariant treasuryIsValid();
    require vault() == dvault;
    configureAll(eManager, eExecute, eAdmin, eOverride, lower, upper, thr, fixedF, variableF, mode, recipient, overrideF, overrideV, until);
    address t = treasury();
    require recipient != currentContract && recipient != t && recipient != e.msg.sender;
    require recipient != usdc && recipient != dvault && t != e.msg.sender;
    require e.msg.sender != currentContract;
    uint256 fee = calculateFeeFor(e, recipient, amount);
    mathint forwarderBefore = usdcBalance(currentContract);
    mathint treasuryBefore = usdcBalance(t) + dvault.balanceOf(t);

    forward(e, usdc, amount, recipient);

    mathint forwarderAfter = usdcBalance(currentContract);
    mathint treasuryAfter = usdcBalance(t) + dvault.balanceOf(t);
    assert forwarderAfter == 0 || forwarderAfter == forwarderBefore + fee;
    assert treasuryAfter + forwarderAfter == treasuryBefore + forwarderBefore + fee;
}

rule treasuryFailureNeverRevertsForwardForAnyConfiguration(
    env e,
    env eManager,
    env eExecute,
    env eAdmin,
    env eOverride,
    Forwarder.FeeModel lower,
    Forwarder.FeeModel upper,
    uint256 thr,
    uint256 fixedF,
    uint256 variableF,
    Forwarder.RoutingMode mode,
    uint256 overrideF,
    uint256 overrideV,
    uint256 until,
    uint256 amount,
    address recipient
) {
    linkForward();
    requireInvariant treasuryIsValid();
    require vault() == dvault;
    configureAll(eManager, eExecute, eAdmin, eOverride, lower, upper, thr, fixedF, variableF, mode, recipient, overrideF, overrideV, until);
    address t = treasury();
    require e.msg.value == 0;
    require usdc.blocked(t) || dvault.depositReverts();
    require !usdc.blocked(recipient) && !usdc.blocked(e.msg.sender) && !usdc.blocked(currentContract);
    require recipient != 0 && recipient != currentContract && recipient != t;
    require e.msg.sender != currentContract && e.msg.sender != t;
    uint256 fee = calculateFeeFor(e, recipient, amount);
    require fee <= amount;
    require usdc.balanceOf(e.msg.sender) >= amount;
    require usdc.allowance(e.msg.sender, currentContract) >= amount;
    require usdc.balanceOf(currentContract) + amount <= MAX_UINT();
    require usdc.balanceOf(recipient) + amount <= MAX_UINT();
    require usdc.balanceOf(dvault) + amount + usdc.balanceOf(currentContract) <= MAX_UINT();
    require dvault.balanceOf(recipient) + amount <= MAX_UINT();

    forward@withrevert(e, usdc, amount, recipient);

    assert !lastReverted;
}

rule pausedForwardDeliversWholeAmountForAnyConfiguration(
    env e,
    env eManager,
    env eExecute,
    env eAdmin,
    env eOverride,
    Forwarder.FeeModel lower,
    Forwarder.FeeModel upper,
    uint256 thr,
    uint256 fixedF,
    uint256 variableF,
    Forwarder.RoutingMode mode,
    uint256 overrideF,
    uint256 overrideV,
    uint256 until,
    uint256 amount,
    address recipient
) {
    linkForward();
    require vault() == dvault;
    configureAll(eManager, eExecute, eAdmin, eOverride, lower, upper, thr, fixedF, variableF, mode, recipient, overrideF, overrideV, until);
    pause(eManager);
    require recipient != currentContract && recipient != treasury() && recipient != e.msg.sender;
    require recipient != usdc && recipient != dvault && e.msg.sender != currentContract;
    mathint before = usdcBalance(recipient) + dvault.balanceOf(recipient);
    forward(e, usdc, amount, recipient);
    assert usdcBalance(recipient) + dvault.balanceOf(recipient) == before + amount;
}

// -------------------------------------------------------------------------------------------------------------------
// Rescue (V1)
// -------------------------------------------------------------------------------------------------------------------

/// rescueToken sends the whole balance to the treasury and nothing to anybody else.
rule rescueTokenOnlyToTreasury(env e, address other) {
    linkModel();
    requireInvariant treasuryIsValid();
    address t = treasury();
    require other != t && other != currentContract;
    mathint forwarderBefore = usdcBalance(currentContract);
    mathint treasuryBefore = usdcBalance(t);
    mathint otherBefore = usdcBalance(other);

    rescueToken(e, usdc);

    assert usdcBalance(currentContract) == 0;
    assert to_mathint(usdcBalance(t)) == treasuryBefore + forwarderBefore;
    assert to_mathint(usdcBalance(other)) == otherBefore;
}

/// rescueNative sends the whole native balance, in a single transfer, to the treasury.
rule rescueNativeOnlyToTreasury(env e) {
    address t = treasury();
    mathint balanceBefore = nativeBalances[currentContract];
    require ghostNativeTransfers == 0;

    rescueNative(e);

    assert ghostNativeTransfers == 1;
    assert ghostNativeRecipient == t;
    assert ghostNativeAmount == balanceBefore;
}
