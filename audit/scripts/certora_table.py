#!/usr/bin/env python3
"""Per-rule PASS / FAIL / TIMEOUT table from (redacted) certoraRun logs.

For every rule and invariant of the logs it aggregates the "Result for" lines (one per method for parametric rules):
TIMEOUT if any instance timed out, FAIL if any assertion was violated, PASS otherwise. For `satisfy` rules the prover
prints the negated low-level assertion, so "Satisfy_...: FAIL" means that a witness WAS found (PASS). It also counts
the non-vacuity witnesses of `rule_sanity basic` ("<rule>...-rule_not_vacuous: A property is violated", or
"...-invariant_not_trivial_postcondition: A property is violated" for invariants) and reports any vacuity or
triviality finding.

Usage: python3 audit/scripts/certora_table.py <label>=<log> [<label>=<log> ...]
Later logs override earlier ones for the rules they contain (re-checks).
"""
import collections
import re
import sys


def parse(path):
    text = open(path).read()
    status = collections.defaultdict(set)
    for line in text.splitlines():
        m = re.match(r"Result for (\w+): (.*)$", line)
        if not m or m.group(1) == "envfreeFuncsStaticCheck":
            continue
        rule, rest = m.group(1), m.group(2)
        if rest.endswith(": SUCCESS") or rest == f"{rule}: SUCCESS":
            status[rule].add("PASS")
        elif "TIMEOUT" in rest:
            status[rule].add("TIMEOUT")
        elif "Satisfy_" in rest and "FAIL" in rest:
            status[rule].add("PASS")  # witness found
        elif "FAIL" in rest or "VIOLATED" in rest.upper():
            status[rule].add("FAIL")
        else:
            status[rule].add("UNKNOWN: " + rest[-60:])
    # Rules that only appear in the final violation list (e.g. UNKNOWN after an internal prover error).
    for line in text.splitlines():
        m = re.match(r"\[rule\] (\w+): (\w+)$", line)
        if m and m.group(1) not in status:
            status[m.group(1)].add("UNKNOWN" if m.group(2) == "UNKNOWN" else m.group(2))
    witnesses = collections.Counter()
    vacuous = collections.Counter()
    for line in text.splitlines():
        m = re.match(r"(\w+)-.*(rule_not_vacuous|invariant_not_trivial_postcondition): (.*)$", line)
        if not m:
            continue
        if m.group(3).startswith("A property is violated"):
            witnesses[m.group(1)] += 1
        elif "successfully verified" in m.group(3):
            vacuous[m.group(1)] += 1
    return status, witnesses, vacuous


def verdict(statuses):
    if any(s.startswith("UNKNOWN") for s in statuses):
        return "UNKNOWN"
    if "FAIL" in statuses:
        return "FAIL"
    if "TIMEOUT" in statuses:
        return "TIMEOUT"
    return "PASS"


def main():
    final = {}
    history = collections.defaultdict(list)
    for arg in sys.argv[1:]:
        label, path = arg.split("=", 1)
        status, witnesses, vacuous = parse(path)
        for rule, statuses in status.items():
            v = verdict(statuses)
            history[rule].append(f"{label}: {v}")
            final[rule] = (v, label, witnesses.get(rule, 0), vacuous.get(rule, 0))
    print("| Rule / invariant | Job (final) | Final | Non-vacuity witnesses | History |")
    print("|---|---|---|---|---|")
    for rule in sorted(final):
        v, label, w, vac = final[rule]
        wit = f"{w}" if w else "— (satisfy rule: the witness is the result)" if v == "PASS" else "—"
        if vac:
            wit += f" / **{vac} vacuous**"
        print(f"| `{rule}` | {label} | **{v}** | {wit} | {'; '.join(history[rule])} |")
    counts = collections.Counter(v for v, *_ in final.values())
    print()
    print("Totals (final):", ", ".join(f"{k} {counts[k]}" for k in sorted(counts)), f"— {len(final)} entries")


if __name__ == "__main__":
    main()
