#!/usr/bin/env python3
"""Compares the Forwarder deployment recorded by forge (broadcast file) with the local build.

Checks that the creation transaction input is exactly `local creation bytecode || abi-encoded constructor args`, that
the arguments are the production configuration (V2/V3 constructor: fee managers and vault guardians), and prints the
data needed for the audit report. The runtime code
equality (immutables included) is checked separately by test/ForwarderPostDeployFork.t.sol.

Usage: python3 audit/scripts/compare_deployment.py broadcast/DeployForwarder.s.sol/8453/run-latest.json
"""
import json
import subprocess
import sys

EXPECTED = {
    "usdc": "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
    "admin": "0x420675dfaf02750a7ddfad702d13e32eb2c67602",
    "delay": 3 * 24 * 3600,
    "treasury": "0x7a5f8a4af0fedabb1625b6f04ba38fc75e7e843e",
    "vault": "0xc462ca16286a9a877a499f9474827ba801f2090d",
    "routing": 0,
    "managers": [
        "0xa737cb590c0f4d00d2140a429728681e1e74c5db",
        "0x31b5abcf044049daa96cdc387a44747a48a0ac62",
        "0x61d4d1ab7ea7b3a54c7b2d646eb8189fad7b1050",
        "0xa82a5201e630b40914bf4fed0b0b40180bcb93f7",
        "0xe3685f1c0652430e501b314b3035cb7dd5b21c5f",
        "0x5adf0b683b49217704eff3f85eda468651c50a48",
        "0x18e129122a338f2e6871764fe0e4426de848ef99",
    ],
}
# The vault guardians are the same seven management wallets (ForwarderDeployConfig.vaultGuardians).
EXPECTED["guardians"] = list(EXPECTED["managers"])


def main(path):
    run = json.load(open(path))
    create = [t for t in run["transactions"] if t["transactionType"] == "CREATE"]
    assert len(create) == 1, "expected exactly one CREATE"
    tx = create[0]
    receipt = [r for r in run["receipts"] if r["transactionHash"] == tx["hash"]][0]
    data = tx["transaction"].get("input") or tx["transaction"].get("data")
    data = data.lower()

    local = subprocess.check_output(["forge", "inspect", "src/Forwarder.sol:Forwarder", "bytecode"], text=True).strip().lower()
    assert data.startswith(local), "creation code differs from the local build"
    args = "0x" + data[len(local):]
    decoded = subprocess.check_output(
        ["cast", "abi-decode", "--input", "f(address,address,uint48,address,address,uint8,address[],address[])", args],
        text=True,
    ).split("\n")
    usdc, admin, delay, treasury, vault, routing, managers, guardians = [d.strip() for d in decoded[:8]]
    managers = [m.strip().lower() for m in managers.strip("[]").split(",")]
    guardians = [g.strip().lower() for g in guardians.strip("[]").split(",")]
    checks = {
        "usdc": usdc.lower() == EXPECTED["usdc"],
        "admin": admin.lower() == EXPECTED["admin"],
        "delay": int(delay.split()[0]) == EXPECTED["delay"],
        "treasury": treasury.lower() == EXPECTED["treasury"],
        "vault": vault.lower() == EXPECTED["vault"],
        "routing": int(routing.split()[0]) == EXPECTED["routing"],
        "managers": managers == EXPECTED["managers"],
        "guardians": guardians == EXPECTED["guardians"],
    }
    print("contract address :", tx["contractAddress"])
    print("deployment tx    :", tx["hash"])
    print("block            :", int(receipt["blockNumber"], 16))
    print("gas used         :", int(receipt["gasUsed"], 16))
    print("deployer         :", tx["transaction"]["from"])
    print("creation code    : identical to local build (", len(local) // 2 - 1, "bytes )")
    print("constructor args :", args)
    for name, ok in checks.items():
        print(f"arg {name:<9}    : {'OK' if ok else 'MISMATCH'}")
    approve = [t for t in run["transactions"] if t["transactionType"] == "CALL"]
    for t in approve:
        print("approve tx       :", t["hash"])
    if not all(checks.values()):
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1])
