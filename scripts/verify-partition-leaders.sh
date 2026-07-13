#!/usr/bin/env bash
# Standalone, read-only check: prints partition/role status for all 4 Zeebe
# pods in a region and reports the total LEADER count found. Pure
# verification - no cluster-control action of any kind. Reusable at any
# point in a manual failover/failback: 0 leaders means that region's Zeebe
# has lost quorum (degraded/write-stalled); >0 means it's serving writes.
#
# Usage: ./verify-partition-leaders.sh <east|west>
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

REGION="${1:-}"
if [ "$REGION" != "east" ] && [ "$REGION" != "west" ]; then
  fail "Usage: $0 <east|west>"
  exit 1
fi

if [ "$REGION" = "east" ]; then
  CTX="$CONTEXT_EAST"; NS="$NS_EAST"; BASE_PORT=19600
else
  CTX="$CONTEXT_WEST"; NS="$NS_WEST"; BASE_PORT=19700
fi

header "VERIFY PARTITION LEADERS ($REGION)"

LEADER_COUNT=0
for i in 0 1 2 3; do
  POD="camunda-zeebe-$i"
  JSON=$(get_partitions_json "$CTX" "$NS" "$POD" "$((BASE_PORT + i))")
  echo "$JSON" | python3 "$LIB_DIR/partitions_view.py" "$REGION $POD" || true
  COUNT=$(echo "$JSON" | grep -o '"role":"LEADER"' | wc -l | tr -d ' ') || true
  LEADER_COUNT=$((LEADER_COUNT + COUNT)) || true
  echo
done

if [ "$LEADER_COUNT" -gt 0 ]; then
  ok "$LEADER_COUNT partition leader(s) found in $REGION - serving writes."
else
  fail "Zero LEADER roles found in $REGION - total write-stall (quorum lost, or this region isn't up)."
fi
