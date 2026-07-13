#!/usr/bin/env python3
"""Reads a Zeebe /actuator/partitions response from stdin for ONE broker pod
and prints a one-line summary of how many LEADER roles it holds, tagged with
the given region label. Meant to be called once per pod (8 times total,
4 east + 4 west) by leadership-distribution.sh, which accumulates the counts
into a cross-region east-vs-west table.
Usage: cat partitions.json | python3 leadership_view.py <region> <pod>
"""
import json
import sys

region = sys.argv[1] if len(sys.argv) > 1 else "?"
pod = sys.argv[2] if len(sys.argv) > 2 else "?"
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except json.JSONDecodeError:
    print(f"{region}\t{pod}\tunreachable\t-")
    sys.exit(0)

leaders = sorted((pid for pid, p in d.items() if p.get("role") == "LEADER"), key=int)
print(f"{region}\t{pod}\t{len(leaders)}\t{','.join(leaders) if leaders else '-'}")
