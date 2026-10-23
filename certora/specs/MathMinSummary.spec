/*
 * Faithfulness of the `Math.min` summary used by certora/specs/ForwarderV3.spec: the OpenZeppelin 5.7 branchless
 * implementation (`ternary(a < b, a, b)` = `b ^ ((a ^ b) * toUint(a < b))`), called through the harness, returns
 * exactly `a < b ? a : b` for every pair of uint256. This spec has no summary of `Math.min`.
 */

methods {
    function mathMin(uint256, uint256) external returns (uint256) envfree;
}

rule mathMinIsTheMinimum(uint256 a, uint256 b) {
    assert to_mathint(mathMin(a, b)) == (a < b ? to_mathint(a) : to_mathint(b));
}

/// Witnesses: both branches are reachable.
rule mathMinReturnsTheFirstArgument(uint256 a, uint256 b) {
    satisfy a < b && mathMin(a, b) == a;
}

rule mathMinReturnsTheSecondArgument(uint256 a, uint256 b) {
    satisfy a > b && mathMin(a, b) == b;
}
