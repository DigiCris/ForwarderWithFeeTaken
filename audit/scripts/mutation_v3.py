#!/usr/bin/env python3
"""Mutation testing of the final Forwarder (V3): the V2 vault lifecycle mutants plus the V3 mutants (fee configuration
and treasury cooling periods, per-recipient fee overrides, effective fee in forward).

Each mutant is a textual change of src/Forwarder.sol applied, one at a time, to an isolated copy of the repository.
The local suite (unit + fuzz + invariants, no fork) runs against every mutant; a mutant is KILLED when at least one
test fails and SURVIVED when the whole suite passes. A mutant that does not compile is reported as INVALID (it would
not prove anything). The original source is never modified.

Usage: python3 audit/scripts/mutation_v3.py <work_dir> <report_path> [--jobs N] [--only ID,ID,...]
"""

import concurrent.futures
import pathlib
import re
import shutil
import subprocess
import sys
import time

REPO = pathlib.Path(__file__).resolve().parents[2]
SOURCE = "src/Forwarder.sol"


def role_gate(roles, reported="DEFAULT_ADMIN_ROLE"):
    checks = " && ".join(f"!hasRole({r}, msg.sender)" for r in roles)
    return f"        if ({checks}) revert AccessControlUnauthorizedAccount(msg.sender, {reported});\n"


# ---------------------------------------------------------------------------------------------------------------------
# V2 mutants (vault change lifecycle), patterns made unique where V3 repeats the same text
# ---------------------------------------------------------------------------------------------------------------------

PROPOSE_SIG = "function proposeVault(IERC4626 candidate) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {"
EXECUTE_SIG = "function executeVaultChange() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {"
DELAY_CHECK = "        if (block.timestamp < executableAt) revert VaultChangeDelayNotElapsed(executableAt);\n"
EXECUTE_CLEAR = """        delete pendingVault;
        delete pendingVaultExecutableAt;
        _setVault(candidate);"""
CANCEL_CLEAR = """        delete pendingVault;
        delete pendingVaultExecutableAt;
        emit VaultChangeCancelled(address(cancelledVault), msg.sender);"""
CANCEL_VAULT_GUARD = """        if (!hasRole(VAULT_GUARDIAN_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, VAULT_GUARDIAN_ROLE);
        }
        IERC4626 cancelledVault = pendingVault;
"""

V2_MUTANTS = [
    ("M01", "VAULT_CHANGE_DELAY 72 hours -> 0", [
        ("uint256 public constant VAULT_CHANGE_DELAY = 72 hours;", "uint256 public constant VAULT_CHANGE_DELAY = 0;"),
    ]),
    ("M02", "Vault: execution allowed one second before executableAt", [
        ("if (block.timestamp < executableAt) revert VaultChangeDelayNotElapsed",
         "if (block.timestamp + 1 < executableAt) revert VaultChangeDelayNotElapsed"),
    ]),
    ("M03", "Vault: execution rejected exactly at executableAt", [
        ("if (block.timestamp < executableAt) revert VaultChangeDelayNotElapsed",
         "if (block.timestamp <= executableAt) revert VaultChangeDelayNotElapsed"),
    ]),
    ("M04", "executeVaultChange without the delay check", [(DELAY_CHECK, "")]),
    ("M05", "A guardian can execute the vault change", [
        (EXECUTE_SIG, "function executeVaultChange() external nonReentrant {\n"
         + role_gate(["DEFAULT_ADMIN_ROLE", "VAULT_GUARDIAN_ROLE"])),
    ]),
    ("M06", "A guardian can propose a vault", [
        (PROPOSE_SIG, "function proposeVault(IERC4626 candidate) external nonReentrant {\n"
         + role_gate(["DEFAULT_ADMIN_ROLE", "VAULT_GUARDIAN_ROLE"])),
    ]),
    ("M07", "A fee manager can propose a vault", [
        (PROPOSE_SIG, "function proposeVault(IERC4626 candidate) external nonReentrant {\n"
         + role_gate(["DEFAULT_ADMIN_ROLE", "FEE_MANAGER_ROLE"])),
    ]),
    ("M08", "The vault proposal changes the active vault immediately", [
        ("        pendingVault = candidate;\n", "        pendingVault = candidate;\n        vault = candidate;\n"),
    ]),
    ("M09", "cancelVaultChange does not clear the pending change", [
        (CANCEL_CLEAR, "        emit VaultChangeCancelled(address(cancelledVault), msg.sender);"),
    ]),
    ("M10", "executeVaultChange does not clear the pending change", [(EXECUTE_CLEAR, "        _setVault(candidate);")]),
    ("M11", "The vault proposal leaves an unlimited allowance to the candidate", [
        ("USDC.forceApprove(address(candidate), 0);", "USDC.forceApprove(address(candidate), type(uint256).max);"),
    ]),
    ("M12", "The vault proposal does not clear the unused health check allowance", [
        ("        _vaultHealthCheck(candidate);\n        USDC.forceApprove(address(candidate), 0);\n",
         "        _vaultHealthCheck(candidate);\n"),
    ]),
    ("M13", "The old vault keeps its allowance after the execution", [
        ("        if (address(previousVault) != address(0)) USDC.forceApprove(address(previousVault), 0);\n", ""),
    ]),
    ("M14", "The vault execution uses the routing mode of the proposal instead of the current one", [
        ("    uint256 public pendingVaultExecutableAt;\n",
         "    uint256 public pendingVaultExecutableAt;\n\n    RoutingMode internal proposedRoutingMode;\n"),
        ("        pendingVaultExecutableAt = executableAt;\n",
         "        pendingVaultExecutableAt = executableAt;\n        proposedRoutingMode = routingMode;\n"),
        (EXECUTE_CLEAR, EXECUTE_CLEAR + "\n        USDC.forceApprove(address(candidate), "
         "proposedRoutingMode == RoutingMode.DIRECT_DIRECT ? 0 : type(uint256).max);"),
    ]),
    ("M15", "The second health check is removed from the vault execution", [
        (EXECUTE_CLEAR, """        delete pendingVault;
        delete pendingVaultExecutableAt;
        IERC4626 previousVault = vault;
        if (address(previousVault) != address(0)) USDC.forceApprove(address(previousVault), 0);
        vault = candidate;
        USDC.forceApprove(address(candidate), routingMode == RoutingMode.DIRECT_DIRECT ? 0 : type(uint256).max);
        emit VaultUpdated(address(previousVault), address(candidate), 0, 0);"""),
    ]),
    ("M16", "A failed vault execution deletes the pending change instead of reverting", [
        (EXECUTE_CLEAR, """        delete pendingVault;
        delete pendingVaultExecutableAt;
        (bool ok,) = address(this).delegatecall(abi.encodeCall(this.mutantSetVault, (candidate)));
        ok;"""),
        ("    function _validateVault(", """    function mutantSetVault(IERC4626 candidate) external {
        _setVault(candidate);
    }

    function _validateVault("""),
    ]),
    ("M17", "Revoking a guardian resets the pending vault timestamp to now", [
        ("    function _validateVault(", """    function _revokeRole(bytes32 role, address account) internal override returns (bool) {
        if (role == VAULT_GUARDIAN_ROLE && pendingVaultExecutableAt != 0) pendingVaultExecutableAt = block.timestamp;
        return super._revokeRole(role, account);
    }

    function _validateVault("""),
    ]),
    ("M18", "Anyone can cancel the vault change", [(CANCEL_VAULT_GUARD, "        IERC4626 cancelledVault = pendingVault;\n")]),
    ("M19", "A new vault proposal silently replaces the pending one", [
        ("        if (address(pendingVault) != address(0)) revert VaultChangeAlreadyPending(address(pendingVault));\n",
         ""),
    ]),
    ("M20", "The active vault can be proposed again", [
        ("        if (address(candidate) == address(vault)) revert VaultAlreadyActive(address(candidate));\n", ""),
    ]),
    ("M21", "executeVaultChange without nonReentrant", [
        (EXECUTE_SIG, "function executeVaultChange() external onlyRole(DEFAULT_ADMIN_ROLE) {"),
    ]),
    ("M22", "The constructor does not grant the initial guardians", [
        ("            _grantRole(VAULT_GUARDIAN_ROLE, initialVaultGuardians[i]);\n", ""),
    ]),
]

# ---------------------------------------------------------------------------------------------------------------------
# V3 mutants
# ---------------------------------------------------------------------------------------------------------------------

FEE_DELAY_CHECK = (
    "        if (block.timestamp < config.executableAt) revert FeeConfigChangeDelayNotElapsed(config.executableAt);\n"
)
TREASURY_DELAY_CHECK = "        if (block.timestamp < executableAt) revert TreasuryChangeDelayNotElapsed(executableAt);\n"
EXECUTE_FEE_SIG = "    function executeFeeConfigChange() external onlyRole(FEE_MANAGER_ROLE) {\n"
EXECUTE_TREASURY_SIG = "    function executeTreasuryChange() external onlyRole(DEFAULT_ADMIN_ROLE) {\n"
PROPOSE_TREASURY_SIG = "    function proposeTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {\n"
CANCEL_FEE_GUARD = """        if (
            !hasRole(FEE_MANAGER_ROLE, msg.sender) && !hasRole(VAULT_GUARDIAN_ROLE, msg.sender)
                && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)
        ) {
            revert AccessControlUnauthorizedAccount(msg.sender, VAULT_GUARDIAN_ROLE);
        }
"""
CANCEL_TREASURY_GUARD = """        if (!hasRole(VAULT_GUARDIAN_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, VAULT_GUARDIAN_ROLE);
        }
        address cancelledTreasury = pendingTreasury;
"""
WORSENED = """                && (overrideFixedFee > feeOverride.fixedFee
                    || overrideVariableFee > feeOverride.variableFee
                    || validUntil < feeOverride.validUntil)"""
ABOVE_GLOBAL = """        if (overrideFixedFee > fixedFee || overrideVariableFee > variableFee) {
            revert FeeOverrideAboveGlobalFee(overrideFixedFee, overrideVariableFee);
        }
"""
EFFECTIVE_FIXED = "        uint256 effectiveFixedFee = Math.min(feeOverride.fixedFee, fixedFee);"
EFFECTIVE_PERCENT = "amount * Math.min(feeOverride.variableFee, variableFee) / FEE_DENOMINATOR"
FOR_MODEL = """        if (paused()) return 0;

        FeeModel model = amount <= threshold ? lowerFeeModel : upperFeeModel;
        if (model == FeeModel.NONE) return 0;
        uint256 effectiveFixedFee"""
PROPOSE_FEE_EMIT = (
    "            newLowerFeeModel, newUpperFeeModel, newThreshold, newFixedFee, newVariableFee, executableAt, msg.sender\n"
    "        );\n"
)
APPLY = "_setFeeConfig(config.lowerFeeModel, config.upperFeeModel, config.threshold, config.fixedFee, config.variableFee);"

V3_MUTANTS = [
    ("N01", "FEE_CHANGE_DELAY 72 hours -> 0", [
        ("uint256 public constant FEE_CHANGE_DELAY = 72 hours;", "uint256 public constant FEE_CHANGE_DELAY = 0;"),
    ]),
    ("N02", "TREASURY_CHANGE_DELAY 72 hours -> 0", [
        ("uint256 public constant TREASURY_CHANGE_DELAY = 72 hours;",
         "uint256 public constant TREASURY_CHANGE_DELAY = 0;"),
    ]),
    ("N03", "executeFeeConfigChange without the delay check", [(FEE_DELAY_CHECK, "")]),
    ("N04", "executeTreasuryChange without the delay check", [(TREASURY_DELAY_CHECK, "")]),
    ("N05", "rescueToken pays the pending treasury when there is one", [
        ("    function rescueToken(IERC20 token) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {\n"
         "        address currentTreasury = treasury;",
         "    function rescueToken(IERC20 token) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {\n"
         "        address currentTreasury = pendingTreasury != address(0) ? pendingTreasury : treasury;"),
    ]),
    ("N06", "An override above the global fee is accepted", [(ABOVE_GLOBAL, "")]),
    ("N07", "calculateFeeFor without min(override, global)", [
        (EFFECTIVE_FIXED, "        uint256 effectiveFixedFee = feeOverride.fixedFee;"),
        (EFFECTIVE_PERCENT, "amount * feeOverride.variableFee / FEE_DENOMINATOR"),
    ]),
    ("N08", "Expiry boundary: the override is still active at validUntil", [
        ("if (block.timestamp >= feeOverride.validUntil) return calculateFee(amount);",
         "if (block.timestamp > feeOverride.validUntil) return calculateFee(amount);"),
    ]),
    ("N09", "A paused fee still charges recipients with an active override", [
        ("        if (block.timestamp >= feeOverride.validUntil) return calculateFee(amount);\n        if (paused()) return 0;\n",
         "        if (block.timestamp >= feeOverride.validUntil) return calculateFee(amount);\n"),
    ]),
    ("N10", "The fixed fee of an active override can be raised", [
        (WORSENED, """                && (overrideVariableFee > feeOverride.variableFee
                    || validUntil < feeOverride.validUntil)"""),
    ]),
    ("N11", "The variable fee of an active override can be raised", [
        (WORSENED, """                && (overrideFixedFee > feeOverride.fixedFee
                    || validUntil < feeOverride.validUntil)"""),
    ]),
    ("N12", "The expiry of an active override can be shortened", [
        (WORSENED, """                && (overrideFixedFee > feeOverride.fixedFee
                    || overrideVariableFee > feeOverride.variableFee)"""),
    ]),
    ("N13", "forward charges the global fee instead of the effective fee", [
        ("        uint256 fee = calculateFeeFor(recipient, amount);", "        uint256 fee = calculateFee(amount);"),
    ]),
    ("N14", "userAmount uses a fee different from the one accounted to the treasury", [
        ("        uint256 userAmount = amount - fee;", "        uint256 userAmount = amount - calculateFee(amount);"),
    ]),
    ("N15", "Fee configuration: execution allowed one second before executableAt", [
        ("if (block.timestamp < config.executableAt) revert", "if (block.timestamp + 1 < config.executableAt) revert"),
    ]),
    ("N16", "Fee configuration: execution rejected exactly at executableAt", [
        ("if (block.timestamp < config.executableAt) revert", "if (block.timestamp <= config.executableAt) revert"),
    ]),
    ("N17", "Treasury: execution allowed one second before executableAt", [
        ("if (block.timestamp < executableAt) revert TreasuryChangeDelayNotElapsed",
         "if (block.timestamp + 1 < executableAt) revert TreasuryChangeDelayNotElapsed"),
    ]),
    ("N18", "Treasury: execution rejected exactly at executableAt", [
        ("if (block.timestamp < executableAt) revert TreasuryChangeDelayNotElapsed",
         "if (block.timestamp <= executableAt) revert TreasuryChangeDelayNotElapsed"),
    ]),
    ("N19", "A new fee proposal silently replaces the pending one", [
        ("        if (pendingExecutableAt != 0) revert FeeConfigChangeAlreadyPending(pendingExecutableAt);\n", ""),
    ]),
    ("N20", "A new treasury proposal silently replaces the pending one", [
        ("        if (pendingTreasury != address(0)) revert TreasuryChangeAlreadyPending(pendingTreasury);\n", ""),
    ]),
    ("N21", "proposeFeeConfig does not check the caps", [
        ("        if (pendingExecutableAt != 0) revert FeeConfigChangeAlreadyPending(pendingExecutableAt);\n"
         "        _checkFixedFee(newFixedFee);\n        _checkVariableFee(newVariableFee);\n",
         "        if (pendingExecutableAt != 0) revert FeeConfigChangeAlreadyPending(pendingExecutableAt);\n"),
    ]),
    ("N22", "cancelFeeConfigChange does not clear the pending configuration", [
        ("        delete pendingFeeConfig;\n        emit FeeConfigChangeCancelled(msg.sender);",
         "        emit FeeConfigChangeCancelled(msg.sender);"),
    ]),
    ("N23", "executeFeeConfigChange does not clear the pending configuration", [
        ("        delete pendingFeeConfig;\n        _setFeeConfig(config.", "        _setFeeConfig(config."),
    ]),
    ("N24", "cancelTreasuryChange does not clear the pending treasury", [
        ("        delete pendingTreasury;\n        delete pendingTreasuryExecutableAt;\n        emit TreasuryChangeCancelled",
         "        emit TreasuryChangeCancelled"),
    ]),
    ("N25", "executeTreasuryChange does not clear the pending treasury", [
        ("        delete pendingTreasury;\n        delete pendingTreasuryExecutableAt;\n        _setTreasury(newTreasury);",
         "        _setTreasury(newTreasury);"),
    ]),
    ("N26", "A guardian can execute the fee configuration", [
        (EXECUTE_FEE_SIG, "    function executeFeeConfigChange() external {\n"
         + role_gate(["FEE_MANAGER_ROLE", "VAULT_GUARDIAN_ROLE"], "FEE_MANAGER_ROLE")),
    ]),
    ("N27", "The admin can execute the fee configuration without FEE_MANAGER_ROLE", [
        (EXECUTE_FEE_SIG, "    function executeFeeConfigChange() external {\n"
         + role_gate(["FEE_MANAGER_ROLE", "DEFAULT_ADMIN_ROLE"], "FEE_MANAGER_ROLE")),
    ]),
    ("N28", "Anyone can cancel the fee configuration", [(CANCEL_FEE_GUARD, "")]),
    ("N29", "A fee manager can cancel the treasury change", [
        (CANCEL_TREASURY_GUARD, CANCEL_TREASURY_GUARD.replace(
            "!hasRole(DEFAULT_ADMIN_ROLE, msg.sender))",
            "!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(FEE_MANAGER_ROLE, msg.sender))")),
    ]),
    ("N30", "Anyone can cancel the treasury change", [
        (CANCEL_TREASURY_GUARD, "        address cancelledTreasury = pendingTreasury;\n"),
    ]),
    ("N31", "A guardian can propose a treasury", [
        (PROPOSE_TREASURY_SIG, "    function proposeTreasury(address newTreasury) external {\n"
         + role_gate(["DEFAULT_ADMIN_ROLE", "VAULT_GUARDIAN_ROLE"])),
    ]),
    ("N32", "A guardian can execute the treasury change", [
        (EXECUTE_TREASURY_SIG, "    function executeTreasuryChange() external {\n"
         + role_gate(["DEFAULT_ADMIN_ROLE", "VAULT_GUARDIAN_ROLE"])),
    ]),
    ("N33", "proposeFeeConfig applies the configuration immediately", [
        (PROPOSE_FEE_EMIT, PROPOSE_FEE_EMIT
         + "        _setFeeConfig(newLowerFeeModel, newUpperFeeModel, newThreshold, newFixedFee, newVariableFee);\n"),
    ]),
    ("N34", "proposeTreasury changes the treasury immediately", [
        ("        pendingTreasury = newTreasury;\n", "        pendingTreasury = newTreasury;\n        treasury = newTreasury;\n"),
    ]),
    ("N35", "setUserFeeOverride accepts the zero address", [
        ("        if (recipient == address(0)) revert ZeroAddress();\n", ""),
    ]),
    ("N36", "setUserFeeOverride accepts a validUntil that is not in the future", [
        ("        if (validUntil <= block.timestamp) revert FeeOverrideExpiryNotInFuture(validUntil);\n", ""),
    ]),
    ("N37", "Anyone can set overrides", [
        ("    ) external onlyRole(FEE_MANAGER_ROLE) {\n        if (recipient == address(0)) revert ZeroAddress();",
         "    ) external {\n        if (recipient == address(0)) revert ZeroAddress();"),
    ]),
    ("N38", "calculateFeeFor ignores the threshold (always the lower model)", [
        (FOR_MODEL, FOR_MODEL.replace("amount <= threshold ? lowerFeeModel : upperFeeModel", "lowerFeeModel")),
    ]),
    ("N39", "calculateFeeFor uses the global variable fee", [(EFFECTIVE_PERCENT, "amount * variableFee / FEE_DENOMINATOR")]),
    ("N40", "calculateFeeFor uses the global fixed fee", [
        (EFFECTIVE_FIXED, "        uint256 effectiveFixedFee = fixedFee;"),
    ]),
    ("N41", "calculateFeeFor uses max(override, global)", [
        (EFFECTIVE_FIXED, EFFECTIVE_FIXED.replace("Math.min", "Math.max")),
        (EFFECTIVE_PERCENT, EFFECTIVE_PERCENT.replace("Math.min", "Math.max")),
    ]),
    ("N42", "executeFeeConfigChange keeps the old fixed fee", [
        (APPLY, APPLY.replace("config.fixedFee", "fixedFee")),
    ]),
    ("N43", "FEE_CHANGE_DELAY and TREASURY_CHANGE_DELAY 72 hours -> 71 hours", [
        ("uint256 public constant FEE_CHANGE_DELAY = 72 hours;", "uint256 public constant FEE_CHANGE_DELAY = 71 hours;"),
        ("uint256 public constant TREASURY_CHANGE_DELAY = 72 hours;",
         "uint256 public constant TREASURY_CHANGE_DELAY = 71 hours;"),
    ]),
]

MUTANTS = V2_MUTANTS + V3_MUTANTS


def apply(source, edits):
    for old, new in edits:
        count = source.count(old)
        if count != 1:
            raise SystemExit(f"pattern found {count} times: {old!r}")
        source = source.replace(old, new)
    return source


def prepare(work):
    if work.exists():
        shutil.rmtree(work)
    ignore = shutil.ignore_patterns("out", "cache", "lib", "broadcast", "audit", ".git", "echidna", "crytic-export",
                                    ".certora_internal", "emv-*", "*.log", ".env", "certora")
    shutil.copytree(REPO, work, ignore=ignore)
    (work / "lib").symlink_to(REPO / "lib")


def run_mutant(work, report_dir, original, mutant):
    mutant_id, description, edits = mutant
    (work / SOURCE).write_text(apply(original, edits))
    start = time.time()
    proc = subprocess.run(["forge", "test", "--no-match-contract", "Fork"], cwd=work, capture_output=True, text=True,
                          timeout=3600)
    elapsed = int(time.time() - start)
    output = proc.stdout + proc.stderr
    (report_dir / f"{mutant_id}.log").write_text(output)
    failing = re.findall(r"\[FAIL[^\]]*\] (\w+)\(", output)
    if "Compiler run failed" in output or "Error (" in output and not failing:
        result = "INVALID (does not compile)"
    elif proc.returncode != 0 and failing:
        result = "KILLED"
    elif proc.returncode == 0:
        result = "SURVIVED"
    else:
        result = f"ERROR (exit {proc.returncode})"
    shown = ", ".join(f"`{name}`" for name in sorted(set(failing))[:6])
    total = len(set(failing))
    line = f"| {mutant_id} | {description} | {result} | {shown}{' …' if total > 6 else ''} ({total}) | {elapsed} |"
    print(line, flush=True)
    return mutant_id, line


def main():
    args = sys.argv[1:]
    jobs = 1
    only = None
    if "--jobs" in args:
        i = args.index("--jobs")
        jobs = int(args[i + 1])
        del args[i:i + 2]
    if "--only" in args:
        i = args.index("--only")
        only = set(args[i + 1].split(","))
        del args[i:i + 2]
    work_root = pathlib.Path(args[0]).resolve()
    report = pathlib.Path(args[1]).resolve()
    report.parent.mkdir(parents=True, exist_ok=True)
    original = (REPO / SOURCE).read_text()
    selected = [m for m in MUTANTS if only is None or m[0] in only]
    for m in selected:  # fail fast on a stale pattern before spending any test time
        apply(original, m[2])

    chunks = [selected[i::jobs] for i in range(jobs)]

    def worker(index):
        work = work_root / f"w{index}"
        prepare(work)
        return [run_mutant(work, report.parent, original, m) for m in chunks[index]]

    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        for chunk_results in pool.map(worker, range(jobs)):
            results.update(dict(chunk_results))

    lines = ["# V3 mutation testing (V2 vault mutants + V3 mutants)", "",
             "Suite: `forge test --no-match-contract Fork` (unit + fuzz + invariants, default profile).", "",
             "| ID | Mutation | Result | Failing tests (first 6) | Seconds |", "|---|---|---|---|---|"]
    lines += [results[m[0]] for m in selected]
    killed = sum(1 for m in selected if "| KILLED |" in results[m[0]])
    lines += ["", f"Killed: {killed}/{len(selected)}"]
    report.write_text("\n".join(lines) + "\n")
    print(f"Killed: {killed}/{len(selected)}")


if __name__ == "__main__":
    main()
