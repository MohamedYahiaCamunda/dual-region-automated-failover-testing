#!/usr/bin/env bash
# Test D - Step 3: Failover (combined)
# Performs three actions:
#   1. Force-removes east's dead brokers from the Zeebe topology (as in
#      Test A/C), required because Zeebe itself lost quorum. This is the only
#      mechanism that ever changes Zeebe's own membership in Test D - a raw
#      actuator API call, never a Kubernetes-level scale/restart.
#   2. Disables camundaregion0 (east's exporter) only. camundaregion1 (west)
#      stays enabled throughout; it is only briefly paused later, around the
#      backup snapshot (see 06-failback.sh), not disabled here.
#   3. Promotes west's active-passive components via promote-region-d.sh -
#      Identity/Keycloak/Optimize/Connectors only. Operate/Tasklist are
#      already permanently on (test-d/west-values.yaml), so this step does
#      not touch the orchestration StatefulSet Zeebe lives in: west's
#      brokers, which just won the failover above, are never restarted by
#      this promotion.
# All actuator calls route through west, since east is fully scaled to 0 and
# its actuator is completely unreachable, not just unhealthy.
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

header "TEST D - STEP 3: Failover (force-remove brokers + disable east's exporter)"

info "Part 1/2: Submitting PATCH /actuator/cluster?force=true to remove brokers 0,2,4,6 (via west, the only reachable region)..."
RESP=$(patch_cluster "$CONTEXT_WEST" "$NS_WEST" camunda-zeebe-0 19700 '{"brokers":{"remove":[0,2,4,6]}}' true)
CHANGE_ID=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('changeId','?'))" 2>/dev/null || echo "?")
ok "Change accepted, changeId=$CHANGE_ID"
echo "$RESP" | python3 "$LIB_DIR/planned_changes_view.py" || true

info "Polling for completion..."
for i in 1 2 3 4 5; do
  sleep 3
  CLUSTER=$(get_cluster_json "$CONTEXT_WEST" "$NS_WEST" camunda-zeebe-0 19700)
  STATUS=$(echo "$CLUSTER" | python3 -c "import json,sys; d=json.load(sys.stdin); pc=d.get('pendingChange'); print(pc['status'] if pc else 'COMPLETED')" 2>/dev/null || echo "?")
  DONE=0; [ "$STATUS" = "COMPLETED" ] && DONE=1
  progress_bar "$DONE" 1 "Waiting for cluster change to complete (status=$STATUS, attempt $i/5)"
  if [ "$STATUS" = "COMPLETED" ]; then
    break
  fi
done

echo
info "Verifying leadership is restored..."
LEADER_COUNT=0
for i in 0 1 2 3; do
  POD="camunda-zeebe-$i"
  JSON=$(get_partitions_json "$CONTEXT_WEST" "$NS_WEST" "$POD" "1970$i")
  echo "$JSON" | python3 "$LIB_DIR/partitions_view.py" "west $POD" || true
  COUNT=$(echo "$JSON" | grep -o '"role":"LEADER"' | wc -l | tr -d ' ') || true
  LEADER_COUNT=$((LEADER_COUNT + COUNT)) || true
  echo
done

if [ "$LEADER_COUNT" -gt 0 ]; then
  ok "Zeebe recovery confirmed: $LEADER_COUNT partition leader(s) found across west."
else
  fail "No leaders found - Zeebe failover did not complete successfully."
  exit 1
fi

echo
info "Part 2/2: Disabling camundaregion0 only (east's target ES is gone). camundaregion1 (west) stays enabled..."
set_exporter "$CONTEXT_WEST" "$NS_WEST" camunda-zeebe-0 19700 camundaregion0 disable
sleep 8

EXP_JSON=$(get_exporters_json "$CONTEXT_WEST" "$NS_WEST" camunda-zeebe-0 19700)
echo "$EXP_JSON" | python3 "$LIB_DIR/exporters_view.py" "Exporter Status" || true

EAST_DISABLED=$(echo "$EXP_JSON" | python3 -c "
import json,sys
d = json.load(sys.stdin)
states = {e['exporterId']: e['status'] for e in d}
print('yes' if states.get('camundaregion0')=='DISABLED' and states.get('camundaregion1')=='ENABLED' else 'no')
" 2>/dev/null || echo no)

if [ "$EAST_DISABLED" = "yes" ]; then
  ok "camundaregion0 confirmed DISABLED, camundaregion1 confirmed still ENABLED."
  ok "Failover complete: Zeebe quorum restored on west-only, east's exporter disabled ahead of failback."
else
  fail "Exporter states are not as expected - retry before continuing."
  exit 1
fi

echo
header "Promoting west's active-passive components (east hosted them, east is gone) - Test D variant, no Zeebe restart"
"$SCRIPTS_DIR/promote-region-d.sh" west

next_step "./04-verify-existing-data.sh   (confirm baseline data still accessible via west)"
