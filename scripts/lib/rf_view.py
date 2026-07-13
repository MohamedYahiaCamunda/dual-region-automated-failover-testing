#!/usr/bin/env python3
"""Reads a Zeebe /actuator/cluster response from stdin, prints a per-partition
replication-factor table (east member count / west member count) and exits
0 if every partition shows exactly 2 east + 2 west, 1 otherwise.

Broker count, readiness, and exporter status can all look healthy while
replication is silently degraded, so this check verifies replication factor
explicitly rather than inferring it from those other signals.
"""
import json
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from table import render, GREEN, RED, BOLD, RESET  # noqa: E402

EAST_NODES = {0, 2, 4, 6}
WEST_NODES = {1, 3, 5, 7}

raw = sys.stdin.read()
try:
    d = json.loads(raw)
except json.JSONDecodeError:
    print("(could not parse cluster response)")
    sys.exit(1)

brokers = d.get("brokers", [])
present = sorted(b["id"] for b in brokers)

pm = {}
for b in brokers:
    for p in b.get("partitions", []):
        pm.setdefault(p["id"], []).append(b["id"])

rows = [["Partition", "Members", "East", "West", "Status"]]
all_ok = True
for pid in sorted(pm, key=int):
    members = sorted(pm[pid])
    e = len([m for m in members if m in EAST_NODES])
    w = len([m for m in members if m in WEST_NODES])
    status = "OK" if (e == 2 and w == 2) else "MISMATCH"
    if status != "OK":
        all_ok = False
    rows.append([pid, ",".join(map(str, members)), e, w, status])

print(f"Brokers present in topology: {present}")
render(rows, title="Replication Factor Check (expect East=2, West=2 per partition)")
print()
if all_ok:
    print(f"{GREEN}{BOLD}✔ ALL PARTITIONS AT FULL REPLICATION FACTOR (RF4){RESET}")
else:
    print(f"{RED}{BOLD}✘ REPLICATION DEGRADED - see MISMATCH rows above{RESET}")
sys.exit(0 if all_ok else 1)
