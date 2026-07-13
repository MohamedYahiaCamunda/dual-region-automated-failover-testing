#!/usr/bin/env python3
"""Reads a Zeebe /actuator/exporters response from stdin, prints a table."""
import json
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from table import render  # noqa: E402

title = sys.argv[1] if len(sys.argv) > 1 else "Exporter Status"
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except json.JSONDecodeError:
    print("(could not parse exporters response)")
    sys.exit(1)

rows = [["Exporter", "Status"]]
for e in d:
    rows.append([e["exporterId"], e["status"]])
render(rows, title=title)
