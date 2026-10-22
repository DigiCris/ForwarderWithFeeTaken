#!/usr/bin/env python3
"""Targeted mutation testing of the V2 vault change lifecycle.

Each mutant is a textual change of src/Forwarder.sol applied, one at a time, to an isolated copy of the repository.
The local suite (unit + fuzz + invariants, no fork) runs against every mutant; a mutant is KILLED when at least one
test fails and SURVIVED when the whole suite passes. A mutant that does not compile is reported as INVALID (it would
not prove anything). The original source is never modified.

Usage: python3 audit/scripts/mutation_v2.py <work_dir> <report_path>
"""

import pathlib
import re
import shutil
import subprocess
import sys
import time

REPO = pathlib.Path(__file__).resolve().parents[2]
SOURCE = "src/Forwarder.sol"

PROPOSE_SIG = "function proposeVault(IERC4626 candidate) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {"
EXECUTE_SIG = "function executeVaultChange() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {"
DELAY_CHECK = "        if (block.timestamp < executableAt) revert VaultChangeDelayNotElapsed(executableAt);\n"
EXECUTE_CLEAR = """        delete pendingVault;
        delete pendingVaultExecutableAt;
        _setVault(candidate);"""
CANCEL_CLEAR = """        delete pendingVault;
        delete pendingVaultExecutableAt;
        emit VaultChangeCancelled(address(cancelledVault), msg.sender);"""


def role_gate(roles):
    checks = " && ".join(f"!hasRole({r}, msg.sender)" for r in roles)
    return f"        if ({checks}) revert AccessControlUnauthorizedAccount(msg.sender, DEFAULT_ADMIN_ROLE);\n"


MUTANTS = [
    ("M01", "VAULT_CHANGE_DELAY 72 hours -> 0", [
        ("uint256 public constant VAULT_CHANGE_DELAY = 72 hours;", "uint256 public constant VAULT_CHANGE_DELAY = 0;"),
    ]),
    ("M02", "Boundary: execution allowed one second before executableAt", [
        ("if (block.timestamp < executableAt) revert", "if (block.timestamp + 1 < executableAt) revert"),
    ]),
    ("M03", "Boundary: execution rejected exactly at executableAt", [
        ("if (block.timestamp < executableAt) revert", "if (block.timestamp <= executableAt) revert"),
    ]),
    ("M04", "executeVaultChange without the delay check", [
        (DELAY_CHECK, ""),
    ]),
    ("M05", "A guardian can execute", [
        (EXECUTE_SIG, "function executeVaultChange() external nonReentrant {\n"
         + role_gate(["DEFAULT_ADMIN_ROLE", "VAULT_GUARDIAN_ROLE"])),
    ]),
    ("M06", "A guardian can propose", [
        (PROPOSE_SIG, "function proposeVault(IERC4626 candidate) external nonReentrant {\n"
         + role_gate(["DEFAULT_ADMIN_ROLE", "VAULT_GUARDIAN_ROLE"])),
    ]),
    ("M07", "A fee manager can propose", [
        (PROPOSE_SIG, "function proposeVault(IERC4626 candidate) external nonReentrant {\n"
         + role_gate(["DEFAULT_ADMIN_ROLE", "FEE_MANAGER_ROLE"])),
    ]),
    ("M08", "The proposal changes the active vault immediately", [
        ("        pendingVault = candidate;\n", "        pendingVault = candidate;\n        vault = candidate;\n"),
    ]),
    ("M09", "cancelVaultChange does not clear the pending change", [
        (CANCEL_CLEAR, "        emit VaultChangeCancelled(address(cancelledVault), msg.sender);"),
    ]),
    ("M10", "executeVaultChange does not clear the pending change", [
        (EXECUTE_CLEAR, "        _setVault(candidate);"),
    ]),
    ("M11", "The proposal leaves an unlimited allowance to the candidate", [
        ("USDC.forceApprove(address(candidate), 0);", "USDC.forceApprove(address(candidate), type(uint256).max);"),
    ]),
    ("M12", "The proposal does not clear the unused health check allowance", [
        ("        _vaultHealthCheck(candidate);\n        USDC.forceApprove(address(candidate), 0);\n",
         "        _vaultHealthCheck(candidate);\n"),
    ]),
    ("M13", "The old vault keeps its allowance after the execution", [
        ("        if (address(previousVault) != address(0)) USDC.forceApprove(address(previousVault), 0);\n", ""),
    ]),
    ("M14", "The execution uses the routing mode of the proposal instead of the current one", [
        ("    uint256 public pendingVaultExecutableAt;\n",
         "    uint256 public pendingVaultExecutableAt;\n\n    RoutingMode internal proposedRoutingMode;\n"),
        ("        pendingVaultExecutableAt = executableAt;\n",
         "        pendingVaultExecutableAt = executableAt;\n        proposedRoutingMode = routingMode;\n"),
        (EXECUTE_CLEAR, EXECUTE_CLEAR + "\n        USDC.forceApprove(address(candidate), "
         "proposedRoutingMode == RoutingMode.DIRECT_DIRECT ? 0 : type(uint256).max);"),
    ]),
    ("M15", "The second health check is removed from the execution", [
        (EXECUTE_CLEAR, """        delete pendingVault;
        delete pendingVaultExecutableAt;
        IERC4626 previousVault = vault;
        if (address(previousVault) != address(0)) USDC.forceApprove(address(previousVault), 0);
        vault = candidate;
        USDC.forceApprove(address(candidate), routingMode == RoutingMode.DIRECT_DIRECT ? 0 : type(uint256).max);
        emit VaultUpdated(address(previousVault), address(candidate), 0, 0);"""),
    ]),
    ("M16", "A failed execution deletes the pending change instead of reverting", [
        (EXECUTE_CLEAR, """        delete pendingVault;
        delete pendingVaultExecutableAt;
        (bool ok,) = address(this).delegatecall(abi.encodeCall(this.mutantSetVault, (candidate)));
        ok;"""),
        ("    function _validateVault(", """    function mutantSetVault(IERC4626 candidate) external {
        _setVault(candidate);
    }

    function _validateVault("""),
    ]),
    ("M17", "Revoking a guardian resets the pending timestamp to now", [
        ("    function _validateVault(", """    function _revokeRole(bytes32 role, address account) internal override returns (bool) {
        if (role == VAULT_GUARDIAN_ROLE && pendingVaultExecutableAt != 0) pendingVaultExecutableAt = block.timestamp;
        return super._revokeRole(role, account);
    }

    function _validateVault("""),
    ]),
    ("M18", "Anyone can cancel", [
        ("""        if (!hasRole(VAULT_GUARDIAN_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, VAULT_GUARDIAN_ROLE);
        }
""", ""),
    ]),
    ("M19", "A new proposal silently replaces the pending one", [
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


def apply(source, edits):
    for old, new in edits:
        count = source.count(old)
        if count != 1:
            raise SystemExit(f"pattern found {count} times: {old!r}")
        source = source.replace(old, new)
    return source


def main():
    work = pathlib.Path(sys.argv[1]).resolve()
    report = pathlib.Path(sys.argv[2]).resolve()
    if work.exists():
        shutil.rmtree(work)
    ignore = shutil.ignore_patterns("out", "cache", "lib", "broadcast", "audit", ".git", "echidna", "crytic-export",
                                    ".certora_internal", "emv-*", "*.log", ".env")
    shutil.copytree(REPO, work, ignore=ignore)
    (work / "lib").symlink_to(REPO / "lib")
    original = (REPO / SOURCE).read_text()

    lines = ["# V2 targeted mutation testing", "",
             "Suite: `forge test --no-match-contract Fork` (unit + fuzz + invariants, default profile).", "",
             "| ID | Mutation | Result | Failing tests (first 6) | Seconds |", "|---|---|---|---|---|"]
    for mutant_id, description, edits in MUTANTS:
        (work / SOURCE).write_text(apply(original, edits))
        start = time.time()
        proc = subprocess.run(["forge", "test", "--no-match-contract", "Fork"], cwd=work, capture_output=True,
                              text=True, timeout=3600)
        elapsed = int(time.time() - start)
        output = proc.stdout + proc.stderr
        (report.parent / f"{mutant_id}.log").write_text(output)
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
        lines.append(f"| {mutant_id} | {description} | {result} | {shown}{' …' if total > 6 else ''} ({total}) | {elapsed} |")
        print(lines[-1], flush=True)
    (work / SOURCE).write_text(original)
    killed = sum(1 for line in lines if "| KILLED |" in line)
    lines += ["", f"Killed: {killed}/{len(MUTANTS)}"]
    report.write_text("\n".join(lines) + "\n")
    print(f"Killed: {killed}/{len(MUTANTS)}")


if __name__ == "__main__":
    main()
