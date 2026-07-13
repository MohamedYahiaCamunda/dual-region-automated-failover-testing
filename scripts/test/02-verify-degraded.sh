#!/usr/bin/env bash
# Step 2: Verify the degraded state
# East is fully down - both Zeebe and Elasticsearch - so all checks run
# against west, the surviving region. The expected signature is a
# "no leader anywhere" state, plus east's Elasticsearch being genuinely gone
# rather than merely unreachable.
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

header "STEP 2: Verify degraded state"

warn "Note: /actuator/cluster still lists east's brokers as ACTIVE right now - that's"
warn "topology CONFIG, not live reachability. It does NOT mean the failure didn't happen."
echo

LEADER_FOUND=0
for i in 0 1 2 3; do
  POD="camunda-zeebe-$i"
  JSON=$(get_partitions_json "$CONTEXT_WEST" "$NS_WEST" "$POD" "1970$i")
  echo "$JSON" | python3 "$LIB_DIR/partitions_view.py" "west $POD" || true
  if echo "$JSON" | grep -q '"role":"LEADER"'; then
    LEADER_FOUND=1
  fi
  echo
done

if [ "$LEADER_FOUND" -eq 0 ]; then
  fail "CONFIRMED DEGRADED (Zeebe): zero LEADER roles found anywhere in west - total write-stall."
else
  warn "A LEADER role was found - double-check timing (failure detection has ~10s delay)."
fi

echo
info "Confirming east's Elasticsearch is genuinely unreachable..."
show_cmd "oc --context $CONTEXT_EAST -n $NS_EAST get pods   (grep camunda-elasticsearch-master-)"
if oc --context "$CONTEXT_EAST" -n "$NS_EAST" get pods --no-headers 2>/dev/null | grep -q "camunda-elasticsearch-master-"; then
  warn "East's Elasticsearch pods still exist - expected none."
else
  fail "CONFIRMED DEGRADED (Elasticsearch): east has no Elasticsearch pods at all."
fi

next_step "./03-failover.sh   (force-remove dead brokers AND disable east's exporter, then promote west)"
