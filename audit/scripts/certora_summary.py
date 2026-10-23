#!/usr/bin/env python3
"""Extracts from a (redacted) certoraRun log the job URL, the per-rule results and the final verdict, as committed in
audit/raw/v3/certora/*.summary.txt (the full logs are kept locally; *.log files are git-ignored).

Usage: python3 audit/scripts/certora_summary.py <log> > <summary>
"""
import re
import sys

text = open(sys.argv[1]).read()
for line in text.splitlines()[:3]:
    if line.startswith("=="):
        print(line)
for url in sorted(set(re.findall(r"https://prover\.certora\.com/output/\S+", text))):
    print("job:", url)
for line in text.splitlines():
    if line.startswith("Result for "):
        print(line)
for marker in ("No errors found by Prover!", "Prover found violations"):
    if marker in text:
        print("verdict:", marker)
tail = text.split("ERROR: Prover found violations:", 1)
if len(tail) == 2:
    print(tail[1].split("report url", 1)[0].strip())
