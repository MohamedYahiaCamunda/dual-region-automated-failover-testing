#!/usr/bin/env python3
"""Reads a Zeebe /actuator/partitions response from stdin, prints a table.
Usage: cat partitions.json | python3 partitions_view.py "east zeebe-0 (node 0)"
"""
import json
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from table import render  # noqa: E402

label = sys.argv[1] if len(sys.argv) > 1 else "broker"
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except json.JSONDecodeError:
    print(f"(could not parse partitions response for {label} - broker may be unreachable)")
    sys.exit(1)

rows = [["Partition", "Role", "Exporter Phase", "Health"]]
for pid, p in sorted(d.items(), key=lambda x: int(x[0])):
    rows.append([pid, p.get("role", "?"), p.get("exporterPhase", "?"),
                 p.get("health", {}).get("status", "?")])
render(rows, title=f"Partitions on {label}")
