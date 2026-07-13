#!/usr/bin/env bash
# Test D - Step 7: Partition leadership check + rebalance
# After failback (06-failback.sh), both regions' brokers are healthy again,
# but Zeebe does not move partition leadership on its own just because a
# broker rejoined the cluster - whatever distribution settled during the
# outage (all 8 partitions led from west) persists until something forces new
# elections. This step unconditionally triggers a rebalance (POST
# /actuator/rebalance via rebalance-partitions.sh), with no manual step and no
# "only if skewed" branch, then fails if leadership is not split across both
# regions afterward.
#
# An explicit rebalance step is necessary specifically in this scenario:
# because Zeebe is never restarted by promote/demote in Test D, there is no
# other point in the failover/failback flow that would naturally nudge
# leadership back toward east, so this step provides that deliberate nudge.
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

header "TEST D - STEP 7: Partition leadership check + rebalance"

info "Rebalancing partition leadership (always run, unconditionally - shows before/after distribution)..."
"$SCRIPTS_DIR/rebalance-partitions.sh" east

EAST_LEADERS=$(get_partitions_json "$CONTEXT_EAST" "$NS_EAST" camunda-zeebe-0 19600 | grep -o '"role":"LEADER"' | wc -l | tr -d ' ') || true
WEST_LEADERS=$(get_partitions_json "$CONTEXT_WEST" "$NS_WEST" camunda-zeebe-0 19700 | grep -o '"role":"LEADER"' | wc -l | tr -d ' ') || true
for i in 1 2 3; do
  EAST_LEADERS=$((EAST_LEADERS + $(get_partitions_json "$CONTEXT_EAST" "$NS_EAST" "camunda-zeebe-$i" "$((19600 + i))" | grep -o '"role":"LEADER"' | wc -l | tr -d ' '))) || true
  WEST_LEADERS=$((WEST_LEADERS + $(get_partitions_json "$CONTEXT_WEST" "$NS_WEST" "camunda-zeebe-$i" "$((19700 + i))" | grep -o '"role":"LEADER"' | wc -l | tr -d ' '))) || true
done

if [ "$EAST_LEADERS" -gt 0 ] && [ "$WEST_LEADERS" -gt 0 ]; then
  ok "Leadership is split across both regions ($EAST_LEADERS east / $WEST_LEADERS west)."
else
  fail "Still fully concentrated in one region after rebalancing ($EAST_LEADERS east / $WEST_LEADERS west) - a follower may be too far behind to take over; investigate before continuing."
  exit 1
fi

next_step "./08-verify-final.sh   (confirm baseline + during-outage data - completed and active - present in BOTH regions)"
