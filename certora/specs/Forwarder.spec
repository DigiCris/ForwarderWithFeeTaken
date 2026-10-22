/*
 * Certora specification of src/Forwarder.sol (verified through certora/harness/ForwarderHarness.sol).
 *
 * Model:
 * - USDC is DummyUSDC (balances, always-decremented allowances, `blocked` accounts whose transfers revert).
 * - The ERC-4626 vault is DummyVault (1:1, deposits/redeems can revert). Calls to any vault address are dispatched to
 *   it, so properties that depend on vault behaviour assume a vault of this kind (trusted-vault assumption).
 * - Native transfers in rescueNative go to the treasury; its code is unknown to the prover.
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
    function FEE_MANAGER_ROLE() external returns (bytes32) envfree;
    function DEFAULT_ADMIN_ROLE() external returns (bytes32) envfree;
    function defaultAdmin() external returns (address) envfree;
    function pendingDefaultAdmin() external returns (address, uint48) envfree;
    function usdcAddress() external returns (address) envfree;
    function vaultAllowance() external returns (uint256) envfree;
    function allowanceTo(address) external returns (uint256) envfree;
    function usdcBalance(address) external returns (uint256) envfree;

    function DummyUSDC.balanceOf(address) external returns (uint256) envfree;
    function DummyUSDC.allowance(address, address) external returns (uint256) envfree;
    function DummyUSDC.blocked(address) external returns (bool) envfree;
    function DummyVault.balanceOf(address) external returns (uint256) envfree;
    function DummyVault.underlying() external returns (address) envfree;
    function DummyVault.depositReverts() external returns (bool) envfree;
    function DummyVault.redeemReverts() external returns (bool) envfree;
    function DummyVault2.underlying() external returns (address) envfree;

    // External calls made by the Forwarder are resolved to the model contracts.
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
// Definitions
// -------------------------------------------------------------------------------------------------------------------

definition MAX_UINT() returns mathint = 2^256 - 1;

definition usesVault(Forwarder.RoutingMode m) returns bool = m != Forwarder.RoutingMode.DIRECT_DIRECT;

definition userUsesVault(Forwarder.RoutingMode m) returns bool =
    m == Forwarder.RoutingMode.VAULT_USER_DIRECT_TREASURY || m == Forwarder.RoutingMode.VAULT_VAULT;

definition treasuryUsesVault(Forwarder.RoutingMode m) returns bool =
    m == Forwarder.RoutingMode.DIRECT_USER_VAULT_TREASURY || m == Forwarder.RoutingMode.VAULT_VAULT;

/// Fee formula of the specification: the model is applied to the full amount, percentage rounded down.
function specFee(Forwarder.FeeModel m, uint256 amount) returns mathint {
    mathint pct = (amount * variableFee()) / 100000;
    if (m == Forwarder.FeeModel.NONE) {
        return 0;
    }
    if (m == Forwarder.FeeModel.FIXED) {
        return fixedFee();
    }
    if (m == Forwarder.FeeModel.PERCENT) {
        return pct;
    }
    return fixedFee() + pct;
}

/// The model contracts are the USDC and the vaults used by the Forwarder.
function linkModel() {
    require usdcAddress() == usdc;
    require dvault.underlying() == usdc && dvault2.underlying() == usdc;
    require vault() == 0 || vault() == dvault || vault() == dvault2;
    require treasury() != usdc && treasury() != dvault && treasury() != dvault2;
}

/// forward rules observe the shares of `dvault`.
function linkForward() {
    linkModel();
    require vault() == 0 || vault() == dvault;
}

// -------------------------------------------------------------------------------------------------------------------
// Configuration invariants
// -------------------------------------------------------------------------------------------------------------------

/// Fee caps: variable fee <= 10% and fixed fee <= 10 USDC, whatever the sequence of calls.
invariant feeCaps()
    variableFee() <= 10000 && fixedFee() <= 10000000;

/// A routing mode that uses the vault always has a vault.
invariant vaultModeHasVault()
    usesVault(routingMode()) => vault() != 0;

/// The treasury is never zero nor the Forwarder itself.
invariant treasuryIsValid()
    treasury() != 0 && treasury() != currentContract;

/// DIRECT_DIRECT never leaves an allowance to the vault.
invariant directDirectMeansNoVaultAllowance()
    (routingMode() == Forwarder.RoutingMode.DIRECT_DIRECT && vault() != 0) => vaultAllowance() == 0
    {
        preserved with (env e) {
            linkModel();
            require e.msg.sender != currentContract;
        }
    }

// -------------------------------------------------------------------------------------------------------------------
// Fee calculation
// -------------------------------------------------------------------------------------------------------------------

/// paused => fee = 0.
rule pausedFeeIsZero(uint256 amount) {
    require paused();
    assert calculateFee(amount) == 0;
}

/// The fee equals the specification formula; the only possible revert is the overflow of amount * variableFee.
rule feeMatchesSpecification(uint256 amount) {
    requireInvariant feeCaps();
    require !paused();
    Forwarder.FeeModel m = amount <= threshold() ? lowerFeeModel() : upperFeeModel();
    bool percentModel = m == Forwarder.FeeModel.PERCENT || m == Forwarder.FeeModel.FIXED_PLUS_PERCENT;
    bool overflow = percentModel && amount * variableFee() > MAX_UINT();

    uint256 fee = calculateFee@withrevert(amount);

    assert lastReverted <=> overflow;
    assert !lastReverted => to_mathint(fee) == specFee(m, amount);
}

/// amount <= threshold selects the lower model.
rule lowerModelUpToThreshold(uint256 amount) {
    require !paused();
    require amount <= threshold();
    require amount * variableFee() <= MAX_UINT();
    assert to_mathint(calculateFee(amount)) == specFee(lowerFeeModel(), amount);
}

/// amount > threshold selects the upper model.
rule upperModelAboveThreshold(uint256 amount) {
    require !paused();
    require amount > threshold();
    require amount * variableFee() <= MAX_UINT();
    assert to_mathint(calculateFee(amount)) == specFee(upperFeeModel(), amount);
}

/// Above the threshold the percentage is computed on the whole amount, not on the excess over the threshold.
rule percentUsesWholeAmount(uint256 amount) {
    require !paused();
    require amount > threshold();
    require upperFeeModel() == Forwarder.FeeModel.PERCENT;
    require amount * variableFee() <= MAX_UINT();
    assert to_mathint(calculateFee(amount)) == (amount * variableFee()) / 100000;
}

/// Non-vacuity of the previous rule: there are states where the whole-amount fee differs from the excess-only fee.
rule percentUsesWholeAmountIsNotTheExcessFee(uint256 amount) {
    require !paused();
    require amount > threshold();
    require upperFeeModel() == Forwarder.FeeModel.PERCENT;
    require amount * variableFee() <= MAX_UINT();
    satisfy to_mathint(calculateFee(amount)) != ((amount - threshold()) * variableFee()) / 100000;
}

/// Setters reject values above the caps.
rule settersRejectValuesAboveCaps(env e, uint256 value) {
    bool isManager = hasRole(FEE_MANAGER_ROLE(), e.msg.sender);
    require e.msg.value == 0;
    setVariableFee@withrevert(e, value);
    bool reverted = lastReverted;
    assert value > 10000 => reverted;
    assert (value <= 10000 && isManager) => !reverted;
}

rule fixedFeeSetterRejectsValuesAboveCap(env e, uint256 value) {
    bool isManager = hasRole(FEE_MANAGER_ROLE(), e.msg.sender);
    require e.msg.value == 0;
    setFixedFee@withrevert(e, value);
    bool reverted = lastReverted;
    assert value > 10000000 => reverted;
    assert (value <= 10000000 && isManager) => !reverted;
}

// -------------------------------------------------------------------------------------------------------------------
// Access control
// -------------------------------------------------------------------------------------------------------------------

/// Only FEE_MANAGER_ROLE changes the fee configuration.
rule onlyFeeManagerChangesFeeConfig(method f, env e, calldataarg args) filtered { f -> !f.isView } {
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
rule onlyAdminChangesTreasury(method f, env e, calldataarg args) filtered { f -> !f.isView } {
    address before = treasury();
    bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);
    f(e, args);
    assert treasury() != before => isAdmin;
}

/// Only DEFAULT_ADMIN_ROLE changes the vault.
rule onlyAdminChangesVault(method f, env e, calldataarg args) filtered { f -> !f.isView } {
    address before = vault();
    bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);
    f(e, args);
    assert vault() != before => isAdmin;
}

/// Only DEFAULT_ADMIN_ROLE changes the routing mode.
rule onlyAdminChangesRoutingMode(method f, env e, calldataarg args) filtered { f -> !f.isView } {
    Forwarder.RoutingMode before = routingMode();
    bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);
    f(e, args);
    assert routingMode() != before => isAdmin;
}

/// Only DEFAULT_ADMIN_ROLE unpauses fees.
rule onlyAdminUnpauses(method f, env e, calldataarg args) filtered { f -> !f.isView } {
    bool pausedBefore = paused();
    bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);
    f(e, args);
    assert (pausedBefore && !paused()) => isAdmin;
}

/// Only FEE_MANAGER_ROLE or DEFAULT_ADMIN_ROLE pause fees.
rule onlyPrivilegedPause(method f, env e, calldataarg args) filtered { f -> !f.isView } {
    bool pausedBefore = paused();
    bool privileged = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender) || hasRole(FEE_MANAGER_ROLE(), e.msg.sender);
    f(e, args);
    assert (!pausedBefore && paused()) => privileged;
}

/// A fee manager without the admin role cannot change treasury, vault or routing, nor unpause.
rule feeManagerCannotAdminister(method f, env e, calldataarg args) filtered { f -> !f.isView } {
    require hasRole(FEE_MANAGER_ROLE(), e.msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);
    address treasuryBefore = treasury();
    address vaultBefore = vault();
    Forwarder.RoutingMode modeBefore = routingMode();
    bool pausedBefore = paused();

    f(e, args);

    assert treasury() == treasuryBefore;
    assert vault() == vaultBefore;
    assert routingMode() == modeBefore;
    assert pausedBefore => paused();
}

/// An account without roles (and not the pending default admin) changes no configuration and no role of others.
rule unprivilegedChangesNothing(method f, env e, calldataarg args, bytes32 role, address account)
    filtered { f -> !f.isView }
{
    require !hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender) && !hasRole(FEE_MANAGER_ROLE(), e.msg.sender);
    address pendingAdmin;
    uint48 schedule;
    pendingAdmin, schedule = pendingDefaultAdmin();
    require e.msg.sender != pendingAdmin;
    require account != e.msg.sender;

    address treasuryBefore = treasury();
    address vaultBefore = vault();
    Forwarder.RoutingMode modeBefore = routingMode();
    bool pausedBefore = paused();
    uint256 thresholdBefore = threshold();
    uint256 fixedBefore = fixedFee();
    uint256 variableBefore = variableFee();
    Forwarder.FeeModel lowerBefore = lowerFeeModel();
    Forwarder.FeeModel upperBefore = upperFeeModel();
    bool roleBefore = hasRole(role, account);
    address adminBefore = defaultAdmin();

    f(e, args);

    assert treasury() == treasuryBefore && vault() == vaultBefore && routingMode() == modeBefore;
    assert paused() == pausedBefore;
    assert threshold() == thresholdBefore && fixedFee() == fixedBefore && variableFee() == variableBefore;
    assert lowerFeeModel() == lowerBefore && upperFeeModel() == upperBefore;
    assert hasRole(role, account) == roleBefore;
    assert defaultAdmin() == adminBefore;
}

// -------------------------------------------------------------------------------------------------------------------
// Allowance lifecycle
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

/// setVault: the previous vault ends with zero allowance and the new one with MAX (vault modes) or zero.
rule setVaultAllowances(env e, address newVault) {
    linkModel();
    require newVault == dvault || newVault == dvault2;
    address oldVault = vault();
    require oldVault != newVault;
    require e.msg.sender != currentContract && e.msg.sender != oldVault && e.msg.sender != newVault;

    setVault(e, newVault);

    assert vault() == newVault;
    assert oldVault != 0 => allowanceTo(oldVault) == 0;
    assert usesVault(routingMode()) => to_mathint(allowanceTo(newVault)) == MAX_UINT();
    assert !usesVault(routingMode()) => allowanceTo(newVault) == 0;
}

/// The health check only uses the caller's funds and returns them (1:1 vault): no USDC of the Forwarder is used.
rule healthCheckUsesOnlyCallerFunds(env e, address newVault) {
    linkModel();
    require newVault == dvault || newVault == dvault2;
    require e.msg.sender != currentContract && e.msg.sender != dvault && e.msg.sender != dvault2;
    mathint forwarderBefore = usdcBalance(currentContract);
    mathint callerBefore = usdcBalance(e.msg.sender);

    setVault(e, newVault);

    assert to_mathint(usdcBalance(currentContract)) == forwarderBefore;
    assert to_mathint(usdcBalance(e.msg.sender)) == callerBefore;
}

/// forward never raises the vault allowance (it never approves).
rule forwardNeverApproves(env e, address token, uint256 amount, address recipient) {
    linkForward();
    uint256 before = vaultAllowance();
    forward(e, token, amount, recipient);
    assert vaultAllowance() <= before;
}

// -------------------------------------------------------------------------------------------------------------------
// forward accounting
// -------------------------------------------------------------------------------------------------------------------

/// The recipient receives exactly amount - fee, as USDC or as vault shares (1:1 vault).
rule forwardUserReceivesAmountMinusFee(env e, uint256 amount, address recipient) {
    linkForward();
    require recipient != currentContract && recipient != treasury() && recipient != e.msg.sender;
    require recipient != usdc && recipient != dvault;
    require e.msg.sender != currentContract;
    uint256 fee = calculateFee(amount);
    mathint usdcBefore = usdcBalance(recipient);
    mathint sharesBefore = dvault.balanceOf(recipient);

    forward(e, usdc, amount, recipient);

    mathint received = usdcBalance(recipient) - usdcBefore + dvault.balanceOf(recipient) - sharesBefore;
    assert received == amount - fee;
}

/// After forward the Forwarder either delivered everything to the treasury or kept previous balance + fee.
rule forwardTreasuryAccounting(env e, uint256 amount, address recipient) {
    linkForward();
    address t = treasury();
    require recipient != currentContract && recipient != t && recipient != e.msg.sender;
    require recipient != usdc && recipient != dvault && t != e.msg.sender;
    require e.msg.sender != currentContract;
    uint256 fee = calculateFee(amount);
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
    uint256 fee = calculateFee(amount);
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

/// paused fees: the recipient receives the whole amount.
rule pausedForwardDeliversWholeAmount(env e, uint256 amount, address recipient) {
    linkForward();
    require paused();
    require recipient != currentContract && recipient != treasury() && recipient != e.msg.sender;
    require recipient != usdc && recipient != dvault && e.msg.sender != currentContract;
    mathint before = usdcBalance(recipient) + dvault.balanceOf(recipient);
    forward(e, usdc, amount, recipient);
    assert usdcBalance(recipient) + dvault.balanceOf(recipient) == before + amount;
}

/// forward does not change any configuration.
rule forwardDoesNotChangeConfiguration(env e, address token, uint256 amount, address recipient) {
    address treasuryBefore = treasury();
    address vaultBefore = vault();
    Forwarder.RoutingMode modeBefore = routingMode();
    bool pausedBefore = paused();
    uint256 fixedBefore = fixedFee();
    uint256 variableBefore = variableFee();
    uint256 thresholdBefore = threshold();
    forward(e, token, amount, recipient);
    assert treasury() == treasuryBefore && vault() == vaultBefore && routingMode() == modeBefore;
    assert paused() == pausedBefore && fixedFee() == fixedBefore && variableFee() == variableBefore;
    assert threshold() == thresholdBefore;
}

/// forward only accepts USDC.
rule forwardOnlyAcceptsUsdc(env e, address token, uint256 amount, address recipient) {
    linkModel();
    forward@withrevert(e, token, amount, recipient);
    assert token != usdc => lastReverted;
}

// -------------------------------------------------------------------------------------------------------------------
// Rescue
// -------------------------------------------------------------------------------------------------------------------

/// rescueToken sends the whole balance to the treasury and nothing to anybody else.
rule rescueTokenOnlyToTreasury(env e, address other) {
    linkModel();
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

/// rescueNative sends the whole native balance to the treasury.
rule rescueNativeOnlyToTreasury(env e) {
    address t = treasury();
    require t != currentContract && e.msg.sender != currentContract;
    mathint forwarderBefore = nativeBalances[currentContract];
    mathint treasuryBefore = nativeBalances[t];

    rescueNative(e);

    assert nativeBalances[currentContract] == 0;
    assert nativeBalances[t] == treasuryBefore + forwarderBefore;
}
