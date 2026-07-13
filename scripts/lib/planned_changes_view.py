#!/usr/bin/env python3
"""Reads a PATCH /actuator/cluster response from stdin, prints the planned
reconfiguration operations as a table."""
import json
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from table import render  # noqa: E402

raw = sys.stdin.read()
try:
    d = json.loads(raw)
except json.JSONDecodeError:
    print("(could not parse cluster PATCH response)")
    sys.exit(1)

rows = [["Operation", "Partition/Broker", "Target Brokers"]]
for op in d.get("plannedChanges", []):
    kind = op.get("operation", "?")
    if kind == "PARTITION_FORCE_RECONFIGURE":
        rows.append([kind, f"p{op.get('partitionId','-')}", ",".join(map(str, op.get("brokers", [])))])
    elif kind in ("BROKER_REMOVE", "BROKER_ADD"):
        rows.append([kind, f"broker {op.get('brokers', ['?'])[0] if op.get('brokers') else '?'}", "-"])
    elif kind in ("PARTITION_JOIN", "PARTITION_LEAVE"):
        rows.append([kind, f"broker {op.get('brokerId','?')} / p{op.get('partitionId','-')}", "-"])
    elif kind in ("PARTITION_DISABLE_EXPORTER", "PARTITION_ENABLE_EXPORTER"):
        rows.append([kind, f"broker {op.get('brokerId','?')} / p{op.get('partitionId','-')}", op.get("exporterId", "-")])
    else:
        rows.append([kind, str(op.get("partitionId", op.get("brokerId", "-"))), "-"])

if len(rows) == 1:
    print("(no planned changes in response)")
else:
    render(rows, title="Planned Cluster Changes")
