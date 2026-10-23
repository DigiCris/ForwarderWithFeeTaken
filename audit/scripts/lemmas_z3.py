#!/usr/bin/env python3
"""Proves with Z3, in exact (unbounded) integer arithmetic, the arithmetic lemmas used by the Certora decomposition of
`calculateFeeFor(recipient, amount) <= calculateFee(amount)` (certora/specs/ForwarderV3.spec, section "Decomposition
of the fee comparisons").

Certora over-approximates non-linear integer arithmetic; on the product lemma it reports a counterexample of the
approximation (productIsMonotone), while the lemmas that only need linear reasoning given the product step pass. This
script closes that step with a solver that decides it exactly: each claim is proven by showing that its negation is
unsatisfiable.

Usage: python3 audit/scripts/lemmas_z3.py
"""

from z3 import And, If, Implies, Int, Not, Solver, sat, unsat

D = 100_000  # FEE_DENOMINATOR
MAX_UINT = 2**256 - 1
MAX_VARIABLE_FEE = 10_000
MAX_FIXED_FEE = 10_000_000


def prove(name, claim):
    solver = Solver()
    solver.add(Not(claim))
    result = solver.check()
    status = "PROVED" if result == unsat else ("COUNTEREXAMPLE " + str(solver.model()) if result == sat else "UNKNOWN")
    print(f"{name}: {status}")
    return result == unsat


def spec_fee(model, amount, fixed, variable):
    """Fee formula of the specification (Forwarder.calculateFee / calculateFeeFor): model applied to the whole amount,
    percentage rounded down. model: 0 NONE, 1 FIXED, 2 PERCENT, 3 FIXED_PLUS_PERCENT."""
    pct = (amount * variable) / D  # Z3 integer division on non-negative operands is the floor
    return If(model == 0, 0, If(model == 1, fixed, If(model == 2, pct, fixed + pct)))


def main():
    a, x, y = Int("amount"), Int("x"), Int("y")
    f1, v1, f2, v2, m = Int("f1"), Int("v1"), Int("f2"), Int("v2"), Int("model")
    o_f, o_v, g_f, g_v = Int("overrideFixed"), Int("overrideVariable"), Int("globalFixed"), Int("globalVariable")
    in_uint = lambda *vs: And(*[And(v >= 0, v <= MAX_UINT) for v in vs])
    ok = True

    # productIsMonotone, unbounded and on the uint256 domain with the fee caps.
    ok &= prove("productIsMonotone (all integers, amount >= 0)", Implies(And(a >= 0, x <= y), a * x <= a * y))
    ok &= prove(
        "productIsMonotone (uint256 amount, x <= y <= MAX_VARIABLE_FEE)",
        Implies(And(in_uint(a, x, y), x <= y, y <= MAX_VARIABLE_FEE), a * x <= a * y),
    )
    # percentPartIsMonotone: floor division by the denominator preserves the order.
    ok &= prove(
        "percentPartIsMonotone",
        Implies(And(in_uint(a, x, y), x <= y), (a * x) / D <= (a * y) / D),
    )
    # specFeeIsMonotone: for every model the fee is monotone in the fixed and in the variable fee.
    ok &= prove(
        "specFeeIsMonotone (4 models)",
        Implies(
            And(in_uint(a, f1, v1, f2, v2), m >= 0, m <= 3, f1 <= f2, v1 <= v2),
            spec_fee(m, a, f1, v1) <= spec_fee(m, a, f2, v2),
        ),
    )
    # Effective fee (min(override, global) per component) never exceeds the global fee, for every model.
    eff_f = If(o_f < g_f, o_f, g_f)
    eff_v = If(o_v < g_v, o_v, g_v)
    ok &= prove(
        "effectiveFeeNeverExceedsGlobalFee (specification, 4 models)",
        Implies(
            And(in_uint(a, o_f, o_v, g_f, g_v), m >= 0, m <= 3),
            spec_fee(m, a, eff_f, eff_v) <= spec_fee(m, a, g_f, g_v),
        ),
    )
    # No new overflow: if amount * globalVariable fits in uint256, so does amount * effectiveVariable.
    ok &= prove(
        "effective product fits whenever the global one fits",
        Implies(And(in_uint(a, o_v, g_v), a * g_v <= MAX_UINT), a * eff_v <= MAX_UINT),
    )
    print("ALL PROVED" if ok else "NOT ALL PROVED")


if __name__ == "__main__":
    main()
