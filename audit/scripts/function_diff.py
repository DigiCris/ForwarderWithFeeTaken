#!/usr/bin/env python3
"""Function-by-function comparison of two versions of src/Forwarder.sol.

For every function, modifier and the constructor it compares the code (signature + body) and, separately, the
NatSpec comment right above it. Also compares the declarations outside functions (state, constants, events,
errors). Output is a Markdown table.

Usage: python3 audit/scripts/function_diff.py <old.sol> <new.sol> [--labels OLD NEW] [--rename old=new ...]

`--rename old=new` pairs a function of the old version with a renamed one of the new version and reports whether
the body (everything from the opening brace) is identical; the signature lines are shown separately.
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


def body(code):
    return code[code.index("{"):] if "{" in code else code


def main():
    args = sys.argv[1:]
    labels = ("V1", "V2")
    renames = {}
    if "--labels" in args:
        i = args.index("--labels")
        labels = (args[i + 1], args[i + 2])
        del args[i:i + 3]
    while "--rename" in args:
        i = args.index("--rename")
        old, new = args[i + 1].split("=")
        renames[old] = new
        del args[i:i + 2]
    v1_src = open(args[0]).read()
    v2_src = open(args[1]).read()
    v1, v1_rest = blocks(v1_src)
    v2, v2_rest = blocks(v2_src)
    names = list(v1) + [n for n in v2 if n not in v1]
    print(f"| Function | {labels[0]} lines | {labels[1]} lines | Code | NatSpec |")
    print("|---|---|---|---|---|")
    for name in names:
        if name in renames and name in v1 and renames[name] in v2:
            a, b = v1[name], v2[renames[name]]
            same = "IDENTICAL BODY" if body(a[1]) == body(b[1]) else "BODY CHANGED"
            print(
                f"| `{name}` -> `{renames[name]}` | {a[1].count(chr(10)) + 1} | {b[1].count(chr(10)) + 1} | "
                f"RENAMED, {same} | changed |"
            )
            continue
        if name in renames.values() and name not in v1:
            continue
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
    for old, new in renames.items():
        if old in v1 and new in v2:
            print()
            print(f"`{old}` ({labels[0]}) signature:")
            print("```solidity")
            print(v1[old][1][: v1[old][1].index("{")].rstrip())
            print("```")
            print(f"`{new}` ({labels[1]}) signature:")
            print("```solidity")
            print(v2[new][1][: v2[new][1].index("{")].rstrip())
            print("```")
    print()
    print("Declarations outside functions (state, constants, events, errors, comments):")
    print(f"- lines only in {labels[0]}: {len(removed)}")
    for l in removed:
        print(f"  - `{l}`")
    print(f"- lines only in {labels[1]}: {len(added)}")
    for l in added:
        print(f"  + `{l}`")


if __name__ == "__main__":
    main()
