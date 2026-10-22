/*
 * Certora specification of the vault change lifecycle of src/Forwarder.sol (V2), verified through
 * certora/harness/ForwarderHarness.sol. Targeted: it proves the new properties (proposal, 72-hour delay, cancellation,
 * execution, guardians, pending state, allowances) and re-proves the V1 rules and invariants directly related to the
 * vault, its allowance and the roles. The other V1 rules (fees, forward accounting, treasury, rescue) live in
 * certora/specs/Forwarder.spec and were proven on V1; their code is unchanged and they are not re-run here.
 *
 * Model (same as V1):
 * - USDC is DummyUSDC (balances, always-decremented allowances, `blocked` accounts whose transfers revert).
 * - SafeERC20 internal functions are summarized as the same ERC-20 call made by the Forwarder on DummyUSDC.
 * - Vaults (active, pending and candidates) are DummyVault / DummyVault2 (1:1, deposits and redeems can revert).
 *   Invalid candidates (EOA, wrong asset, non ERC-4626) are covered by the Foundry and fork suites.
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
    function pendingVault() external returns (address) envfree;
    function pendingVaultExecutableAt() external returns (uint256) envfree;
    function VAULT_CHANGE_DELAY() external returns (uint256) envfree;
    function VAULT_GUARDIAN_ROLE() external returns (bytes32) envfree;

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

/// The model contracts are the USDC and the vaults used (or proposed) by the Forwarder. Rules start a new transaction,
/// so the transient reentrancy flag is clear.
function linkModel() {
    require !reentrancyGuardEntered();
    require usdcAddress() == usdc;
    require dvault.underlying() == usdc && dvault2.underlying() == usdc;
    require vault() == 0 || vault() == dvault || vault() == dvault2;
    require pendingVault() == 0 || pendingVault() == dvault || pendingVault() == dvault2;
    require treasury() != usdc && treasury() != dvault && treasury() != dvault2;
    requireInvariant enumsAreValid();
    requireInvariant pendingVaultConsistency();
    requireInvariant pendingVaultIsNotActive();
}

/// forward rules observe the shares of `dvault`.
function linkForward() {
    linkModel();
    require vault() == 0 || vault() == dvault;
}

// -------------------------------------------------------------------------------------------------------------------
// Invariants (V1, re-proven on V2)
// -------------------------------------------------------------------------------------------------------------------

/// Stored enums always hold valid values (every write comes from an ABI-validated enum).
invariant enumsAreValid()
    routingModeRaw() < 4 && lowerFeeModelRaw() < 4 && upperFeeModelRaw() < 4
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
// Authorization (V2)
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

// -------------------------------------------------------------------------------------------------------------------
// Delay (V2)
// -------------------------------------------------------------------------------------------------------------------

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
/// and only to the pending vault (adaptation of the V1 rule onlyAdminChangesVault to the lifecycle).
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

/// No method shortens or modifies the delay of a pending change: a pending vault keeps its timestamp until it is
/// cleared, and a new pending vault always gets exactly the proposal timestamp + 72 hours.
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

/// Guardian grants, revocations and renouncements never alter the pending change nor its timestamp.
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
    f(e, args);
    assert pendingVault() == pendingBefore && pendingVaultExecutableAt() == atBefore;
}

// -------------------------------------------------------------------------------------------------------------------
// Pending state (V2)
// -------------------------------------------------------------------------------------------------------------------

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

/// The vault lifecycle functions never modify fees, treasury, pause state or routing.
rule vaultLifecycleKeepsConfiguration(method f, env e, calldataarg args)
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

    f(e, args);

    assert treasury() == treasuryBefore && routingMode() == modeBefore && paused() == pausedBefore;
    assert threshold() == thresholdBefore && fixedFee() == fixedBefore && variableFee() == variableBefore;
    assert lowerFeeModel() == lowerBefore && upperFeeModel() == upperBefore;
}

// -------------------------------------------------------------------------------------------------------------------
// Allowances (V2)
// -------------------------------------------------------------------------------------------------------------------

/// After a proposal the candidate holds no allowance.
rule proposeLeavesNoCandidateAllowance(env e, address candidate) {
    linkModel();
    require candidate == dvault || candidate == dvault2;
    require e.msg.sender != currentContract && e.msg.sender != dvault && e.msg.sender != dvault2;

    proposeVault(e, candidate);

    assert allowanceTo(candidate) == 0;
}

/// executeVaultChange: the previous vault ends with zero allowance and the new one with MAX if the routing mode in
/// force at execution uses the vault, zero otherwise (adaptation of the V1 rule setVaultAllowances).
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

/// Same, with any routing change made while the change was pending (cases A and B and every other pair): the
/// routing in force at execution decides.
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

/// forward keeps the pending change and the pending vault allowance.
rule forwardKeepsPendingChange(env e, address token, uint256 amount, address recipient) {
    linkForward();
    address pendingBefore = pendingVault();
    uint256 atBefore = pendingVaultExecutableAt();
    uint256 pendingAllowanceBefore = allowanceTo(pendingBefore);

    forward(e, token, amount, recipient);

    assert pendingVault() == pendingBefore && pendingVaultExecutableAt() == atBefore;
    assert allowanceTo(pendingBefore) == pendingAllowanceBefore;
}

/// The proposal health check only uses the caller's funds and returns them (1:1 vault): no USDC of the Forwarder is
/// used (adaptation of the V1 rule healthCheckUsesOnlyCallerFunds).
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
// V1 rules re-proven on V2 (text unchanged)
// -------------------------------------------------------------------------------------------------------------------

/// Only DEFAULT_ADMIN_ROLE changes the vault.
rule onlyAdminChangesVault(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract && !f.isView }
{
    address before = vault();
    bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);
    f(e, args);
    assert vault() != before => isAdmin;
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
