#!/usr/bin/env python3
"""Reads a Zeebe /actuator/health/readiness response from stdin, prints a table.
Exits 0 if overall status is UP, 1 otherwise (so callers can branch on it)."""
import json
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from table import render  # noqa: E402

title = sys.argv[1] if len(sys.argv) > 1 else "Readiness"
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except json.JSONDecodeError:
    print(f"(could not parse readiness response for {title} - unreachable)")
    sys.exit(1)

rows = [["Component", "Status"]]
rows.append(["overall", d.get("status", "?")])
for k, v in d.get("components", {}).items():
    rows.append([k, v.get("status", "?")])
render(rows, title=title)
sys.exit(0 if d.get("status") == "UP" else 1)
