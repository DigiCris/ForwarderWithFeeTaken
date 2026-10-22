#!/usr/bin/env python3
"""Function-by-function comparison of two versions of src/Forwarder.sol.

For every function, modifier and the constructor it compares the code (signature + body) and, separately, the
NatSpec comment right above it. Also compares the declarations outside functions (state, constants, events,
errors). Output is a Markdown table.

Usage: python3 audit/scripts/function_diff.py <v1.sol> <v2.sol>
"""

import re
import sys


def blocks(source):
    """Returns {name: (natspec, code)} for functions/constructor and the remaining top-level declarations."""
    result = {}
    lines = source.splitlines(keepends=True)
    text = "".join(lines)
    pattern = re.compile(r"^    (function (\w+)\s*\(|constructor\s*\()", re.M)
    spans = []
    for match in pattern.finditer(text):
        name = match.group(2) or "constructor"
        start = match.start()
        # NatSpec / comments directly above.
        doc_start = start
        while True:
            prev_end = text.rfind("\n", 0, doc_start - 1)
            prev_line = text[prev_end + 1:doc_start]
            if prev_line.strip().startswith(("///", "/**", "*", "*/")):
                doc_start = prev_end + 1
            else:
                break
        brace = text.index("{", match.end())
        semicolon = text.find(";", match.end())
        if semicolon != -1 and semicolon < brace:
            end = semicolon + 1  # declaration without body
        else:
            depth = 0
            i = brace
            while True:
                if text[i] == "{":
                    depth += 1
                elif text[i] == "}":
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            end = i + 1
        result[name] = (text[doc_start:start], text[start:end])
        spans.append((doc_start, end))
    rest = []
    last = 0
    for s, e in sorted(spans):
        rest.append(text[last:s])
        last = e
    rest.append(text[last:])
    return result, "".join(rest)


def main():
    v1_src = open(sys.argv[1]).read()
    v2_src = open(sys.argv[2]).read()
    v1, v1_rest = blocks(v1_src)
    v2, v2_rest = blocks(v2_src)
    names = list(v1) + [n for n in v2 if n not in v1]
    print("| Function | V1 lines | V2 lines | Code | NatSpec |")
    print("|---|---|---|---|---|")
    for name in names:
        a = v1.get(name)
        b = v2.get(name)
        if a and not b:
            print(f"| `{name}` | {a[1].count(chr(10)) + 1} | - | REMOVED | - |")
        elif b and not a:
            print(f"| `{name}` | - | {b[1].count(chr(10)) + 1} | ADDED | - |")
        else:
            code = "UNCHANGED" if a[1] == b[1] else "CHANGED"
            doc = "unchanged" if a[0] == b[0] else "changed"
            print(f"| `{name}` | {a[1].count(chr(10)) + 1} | {b[1].count(chr(10)) + 1} | {code} | {doc} |")
    v1_decl = [l.strip() for l in v1_rest.splitlines() if l.strip()]
    v2_decl = [l.strip() for l in v2_rest.splitlines() if l.strip()]
    added = [l for l in v2_decl if l not in v1_decl]
    removed = [l for l in v1_decl if l not in v2_decl]
    print()
    print("Declarations outside functions (state, constants, events, errors, comments):")
    print(f"- lines only in V1: {len(removed)}")
    for l in removed:
        print(f"  - `{l}`")
    print(f"- lines only in V2: {len(added)}")
    for l in added:
        print(f"  + `{l}`")


if __name__ == "__main__":
    main()
