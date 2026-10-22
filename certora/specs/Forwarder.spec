/*
 * Certora specification of src/Forwarder.sol (verified through certora/harness/ForwarderHarness.sol).
 *
 * Model:
 * - USDC is DummyUSDC (balances, always-decremented allowances, `blocked` accounts whose transfers revert).
 * - OpenZeppelin SafeERC20 builds its calls in assembly, which the prover cannot resolve (it would treat them as
 *   unknown calls that may change any other contract). Its internal functions are therefore summarized as the same
 *   ERC-20 call made by the Forwarder on DummyUSDC: reverts propagate (safe*) or become `false` (trySafeTransfer).
 * - The ERC-4626 vault is DummyVault / DummyVault2 (1:1, deposits and redeems can revert). Calls to any vault address
 *   are dispatched to them, so properties that depend on vault behaviour hold for a vault of this kind (trusted vault).
 * - Address.sendValue (rescueNative) is summarized by recording the recipient and the amount in ghosts.
 * - Parametric rules and invariants range over the Forwarder's own external functions.
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

/// The model contracts are the USDC and the vaults used by the Forwarder. Rules start a new transaction, so the
/// transient reentrancy flag is clear.
function linkModel() {
    require !reentrancyGuardEntered();
    require usdcAddress() == usdc;
    require dvault.underlying() == usdc && dvault2.underlying() == usdc;
    require vault() == 0 || vault() == dvault || vault() == dvault2;
    require treasury() != usdc && treasury() != dvault && treasury() != dvault2;
    requireInvariant enumsAreValid();
}

/// forward rules observe the shares of `dvault`.
function linkForward() {
    linkModel();
    require vault() == 0 || vault() == dvault;
}

// -------------------------------------------------------------------------------------------------------------------
// Configuration invariants
// -------------------------------------------------------------------------------------------------------------------

/// Stored enums always hold valid values (every write comes from an ABI-validated enum).
invariant enumsAreValid()
    routingModeRaw() < 4 && lowerFeeModelRaw() < 4 && upperFeeModelRaw() < 4
    filtered { f -> f.contract == currentContract }

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

/// Setters reject values above the caps; a fee manager can always set values within the caps.
rule settersRejectValuesAboveCaps(env e, uint256 value) {
    requireInvariant enumsAreValid();
    bool isManager = hasRole(FEE_MANAGER_ROLE(), e.msg.sender);
    require e.msg.value == 0;
    setVariableFee@withrevert(e, value);
    bool reverted = lastReverted;
    assert value > 10000 => reverted;
    assert (value <= 10000 && isManager) => !reverted;
}

rule fixedFeeSetterRejectsValuesAboveCap(env e, uint256 value) {
    requireInvariant enumsAreValid();
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
    requireInvariant treasuryIsValid();
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

// -------------------------------------------------------------------------------------------------------------------
// Rules over configurations built with the real setters
//
// The prover models the packed storage slot `vault | routingMode | lowerFeeModel | upperFeeModel` with the enum bytes
// at zero in the initial state (NONE / DIRECT_DIRECT), so the rules above only cover that starting configuration.
// The rules below first write an arbitrary configuration through `setFeeConfig` / `setRoutingMode` (whose writes are
// modelled exactly with precise bitwise operations) and then check the properties for every fee model and routing.
// -------------------------------------------------------------------------------------------------------------------

function specFeeWith(Forwarder.FeeModel m, uint256 amount, uint256 fixedF, uint256 variableF) returns mathint {
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

function configure(
    env eManager,
    env eAdmin,
    Forwarder.FeeModel lower,
    Forwarder.FeeModel upper,
    uint256 thr,
    uint256 fixedF,
    uint256 variableF,
    Forwarder.RoutingMode mode
) {
    setFeeConfig(eManager, lower, upper, thr, fixedF, variableF);
    setRoutingMode(eAdmin, mode);
}

/// The fee equals the specification for every configuration a fee manager can set. Amounts are bounded to 2^200
/// (no overflow is possible below it with variableFee <= 10_000); the overflow case is covered by
/// `feeMatchesSpecification`, and bounding avoids a non-linear solver imprecision reported by the prover.
rule feeMatchesSpecificationForAnyConfiguration(
    env eManager,
    Forwarder.FeeModel lower,
    Forwarder.FeeModel upper,
    uint256 thr,
    uint256 fixedF,
    uint256 variableF,
    uint256 amount
) {
    requireInvariant enumsAreValid();
    require !paused();
    setFeeConfig(eManager, lower, upper, thr, fixedF, variableF);
    require amount < 2^200;
    Forwarder.FeeModel m = amount <= thr ? lower : upper;

    uint256 fee = calculateFee@withrevert(amount);

    assert !lastReverted, "no revert for amounts below 2^200";
    assert to_mathint(fee) == specFeeWith(m, amount, fixedF, variableF), "fee value";
}

/// Localization of the previous rule: stored configuration equals the one written by setFeeConfig.
rule setFeeConfigStoresConfiguration(
    env eManager,
    Forwarder.FeeModel lower,
    Forwarder.FeeModel upper,
    uint256 thr,
    uint256 fixedF,
    uint256 variableF
) {
    requireInvariant enumsAreValid();
    setFeeConfig(eManager, lower, upper, thr, fixedF, variableF);
    assert lowerFeeModel() == lower, "lower";
    assert upperFeeModel() == upper, "upper";
    assert threshold() == thr && fixedFee() == fixedF && variableFee() == variableF, "values";
}

/// PERCENT above the threshold charges the percentage of the whole amount.
rule percentAboveThresholdUsesWholeAmount(env eManager, uint256 thr, uint256 variableF, uint256 amount) {
    require !paused();
    setFeeConfig(eManager, Forwarder.FeeModel.NONE, Forwarder.FeeModel.PERCENT, thr, 0, variableF);
    require amount > thr && amount * variableF <= MAX_UINT();
    assert to_mathint(calculateFee(amount)) == (amount * variableF) / 100000;
}

/// Witness: the whole-amount fee differs from an excess-only fee in some configuration (the rule above is not trivial).
rule percentAboveThresholdIsNotExcessFee(env eManager, uint256 thr, uint256 variableF, uint256 amount) {
    require !paused();
    setFeeConfig(eManager, Forwarder.FeeModel.NONE, Forwarder.FeeModel.PERCENT, thr, 0, variableF);
    require amount > thr && amount * variableF <= MAX_UINT();
    satisfy to_mathint(calculateFee(amount)) != ((amount - thr) * variableF) / 100000;
}

/// Witnesses: every non-NONE model yields a positive fee after configuration.
rule fixedModelChargesAfterConfiguration(env eManager, uint256 fixedF, uint256 amount) {
    require !paused();
    setFeeConfig(eManager, Forwarder.FeeModel.FIXED, Forwarder.FeeModel.FIXED, 0, fixedF, 0);
    satisfy calculateFee(amount) > 0;
}

rule fixedPlusPercentModelChargesAfterConfiguration(env eManager, uint256 fixedF, uint256 variableF, uint256 amount) {
    require !paused();
    setFeeConfig(eManager, Forwarder.FeeModel.FIXED_PLUS_PERCENT, Forwarder.FeeModel.FIXED_PLUS_PERCENT, 0, fixedF, variableF);
    satisfy to_mathint(calculateFee(amount)) > to_mathint(fixedF);
}

/// The recipient receives exactly amount - fee for every fee configuration and routing mode.
rule forwardUserReceivesAmountMinusFeeForAnyConfiguration(
    env e,
    env eManager,
    env eAdmin,
    Forwarder.FeeModel lower,
    Forwarder.FeeModel upper,
    uint256 thr,
    uint256 fixedF,
    uint256 variableF,
    Forwarder.RoutingMode mode,
    uint256 amount,
    address recipient
) {
    linkForward();
    require vault() == dvault;
    configure(eManager, eAdmin, lower, upper, thr, fixedF, variableF, mode);
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

/// Treasury accounting for every fee configuration and routing mode.
rule forwardTreasuryAccountingForAnyConfiguration(
    env e,
    env eManager,
    env eAdmin,
    Forwarder.FeeModel lower,
    Forwarder.FeeModel upper,
    uint256 thr,
    uint256 fixedF,
    uint256 variableF,
    Forwarder.RoutingMode mode,
    uint256 amount,
    address recipient
) {
    linkForward();
    requireInvariant treasuryIsValid();
    require vault() == dvault;
    configure(eManager, eAdmin, lower, upper, thr, fixedF, variableF, mode);
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

/// A failing treasury delivery never makes forward revert, for every fee configuration and routing mode.
rule treasuryFailureNeverRevertsForwardForAnyConfiguration(
    env e,
    env eManager,
    env eAdmin,
    Forwarder.FeeModel lower,
    Forwarder.FeeModel upper,
    uint256 thr,
    uint256 fixedF,
    uint256 variableF,
    Forwarder.RoutingMode mode,
    uint256 amount,
    address recipient
) {
    linkForward();
    requireInvariant treasuryIsValid();
    require vault() == dvault;
    configure(eManager, eAdmin, lower, upper, thr, fixedF, variableF, mode);
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

/// With fees paused the recipient receives the whole amount, for every fee configuration and routing mode.
rule pausedForwardDeliversWholeAmountForAnyConfiguration(
    env e,
    env eManager,
    env eAdmin,
    Forwarder.FeeModel lower,
    Forwarder.FeeModel upper,
    uint256 thr,
    uint256 fixedF,
    uint256 variableF,
    Forwarder.RoutingMode mode,
    uint256 amount,
    address recipient
) {
    linkForward();
    require vault() == dvault;
    configure(eManager, eAdmin, lower, upper, thr, fixedF, variableF, mode);
    pause(eManager);
    require recipient != currentContract && recipient != treasury() && recipient != e.msg.sender;
    require recipient != usdc && recipient != dvault && e.msg.sender != currentContract;
    mathint before = usdcBalance(recipient) + dvault.balanceOf(recipient);
    forward(e, usdc, amount, recipient);
    assert usdcBalance(recipient) + dvault.balanceOf(recipient) == before + amount;
}
