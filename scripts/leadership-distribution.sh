#!/usr/bin/env bash
# Standalone, read-only check: queries all 8 Zeebe broker pods (4 east + 4
# west) via GET /actuator/partitions and prints a single table showing how
# many of the 8 partition leaders currently sit in each region, plus which
# partition IDs. Pure verification - same underlying data source as
# verify-partition-leaders.sh, just both regions at once for an at-a-glance
# "which region is actually doing the work" view.
#
# Usage: ./leadership-distribution.sh
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

header "PARTITION LEADERSHIP DISTRIBUTION (east vs west)"

TSV=$(mktemp)
printf 'Region\tPod\tLeaders\tPartition IDs\n' > "$TSV"

EAST_TOTAL=0
for i in 0 1 2 3; do
  POD="camunda-zeebe-$i"
  JSON=$(get_partitions_json "$CONTEXT_EAST" "$NS_EAST" "$POD" "$((19600 + i))" || echo '{}')
  LINE=$(echo "$JSON" | python3 "$LIB_DIR/leadership_view.py" east "$POD")
  echo "$LINE" >> "$TSV"
  COUNT=$(echo "$LINE" | cut -f3)
  case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac
  EAST_TOTAL=$((EAST_TOTAL + COUNT)) || true
done

WEST_TOTAL=0
for i in 0 1 2 3; do
  POD="camunda-zeebe-$i"
  JSON=$(get_partitions_json "$CONTEXT_WEST" "$NS_WEST" "$POD" "$((19700 + i))" || echo '{}')
  LINE=$(echo "$JSON" | python3 "$LIB_DIR/leadership_view.py" west "$POD")
  echo "$LINE" >> "$TSV"
  COUNT=$(echo "$LINE" | cut -f3)
  case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac
  WEST_TOTAL=$((WEST_TOTAL + COUNT)) || true
done

table < "$TSV"
rm -f "$TSV"

echo
info "East holds $EAST_TOTAL leader(s), West holds $WEST_TOTAL leader(s) (8 total partitions)."
if [ "$EAST_TOTAL" -gt 0 ] && [ "$WEST_TOTAL" -gt 0 ]; then
  ok "Leadership is split across both regions."
elif [ "$EAST_TOTAL" -eq 0 ] && [ "$WEST_TOTAL" -gt 0 ]; then
  warn "All leadership is currently on West - East is fully passive for writes right now."
elif [ "$WEST_TOTAL" -eq 0 ] && [ "$EAST_TOTAL" -gt 0 ]; then
  warn "All leadership is currently on East - West is fully passive for writes right now."
else
  fail "No leaders found anywhere - cluster has lost quorum."
fi

next_step "./rebalance-partitions.sh <east|west>   (to actively influence this distribution instead of just observing it)"
