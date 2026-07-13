#!/usr/bin/env bash
# Step 1: Inject failure (combined Zeebe + Elasticsearch)
# Destroys east's Zeebe (scaled to 0, with PVCs left intact for now - the
# fresh bootstrap performed during failback will wipe them, since a full
# re-bootstrap is the only reliable way to restore RF4) and east's
# Elasticsearch data (PVCs deleted immediately, since a mere restart would
# not exercise the snapshot/restore mechanism).
# East also hosts the active-passive components in this environment, so this
# step represents a genuine "primary site totally lost" drill, not the loss
# of a single subsystem.
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

header "STEP 1: Inject failure (destroy EAST's Zeebe AND Elasticsearch)"

confirm_destructive "This scales east's Zeebe to 0 AND deletes east's 3 Elasticsearch PVCs (data-camunda-elasticsearch-master-0/1/2). The ES data also exists in west's ES, so nothing is permanently lost, but this simulates a genuine full loss of the primary region."

info "Pods in east BEFORE:"
show_cmd "oc --context $CONTEXT_EAST -n $NS_EAST get pods"
oc --context "$CONTEXT_EAST" -n "$NS_EAST" get pods --no-headers | awk '{print $1"\t"$2"\t"$3}' | table

info "Scaling east's Zeebe to 0..."
run_cmd oc --context "$CONTEXT_EAST" -n "$NS_EAST" scale statefulset camunda-zeebe --replicas=0 > /dev/null
wait_for_zero_zeebe_pods "$CONTEXT_EAST" "$NS_EAST"
ok "East's Zeebe fully down."

info "Scaling east's Elasticsearch to 0..."
run_cmd oc --context "$CONTEXT_EAST" -n "$NS_EAST" scale statefulset camunda-elasticsearch-master --replicas=0 > /dev/null
show_cmd "oc --context $CONTEXT_EAST -n $NS_EAST get pods --no-headers   (polling every 5s for camunda-elasticsearch-master-* to reach 0)"
for i in $(seq 1 12); do
  remaining=$(oc --context "$CONTEXT_EAST" -n "$NS_EAST" get pods --no-headers 2>/dev/null | grep -c "camunda-elasticsearch-master-" || true)
  if [ "$remaining" -eq 0 ]; then break; fi
  sleep 5
done
ok "East's Elasticsearch pods terminated."

info "Deleting east's 3 Elasticsearch PVCs (real data destruction)..."
run_cmd oc --context "$CONTEXT_EAST" -n "$NS_EAST" delete pvc data-camunda-elasticsearch-master-0 data-camunda-elasticsearch-master-1 data-camunda-elasticsearch-master-2 > /dev/null
ok "East's Elasticsearch data destroyed."

echo
info "Pods in east AFTER:"
show_cmd "oc --context $CONTEXT_EAST -n $NS_EAST get pods"
oc --context "$CONTEXT_EAST" -n "$NS_EAST" get pods --no-headers | awk '{print $1"\t"$2"\t"$3}' | table

printf 'Check\tResult\n' > /tmp/dr_tableD1.tsv
ZEEBE_REMAINING=$(oc --context "$CONTEXT_EAST" -n "$NS_EAST" get pods --no-headers 2>/dev/null | grep -c "camunda-zeebe-" || true)
ES_REMAINING=$(oc --context "$CONTEXT_EAST" -n "$NS_EAST" get pods --no-headers 2>/dev/null | grep -c "camunda-elasticsearch-master-" || true)
printf 'East Zeebe pods remaining\t%s (expected 0)\n' "$ZEEBE_REMAINING" >> /tmp/dr_tableD1.tsv
printf 'East Elasticsearch pods remaining\t%s (expected 0)\n' "$ES_REMAINING" >> /tmp/dr_tableD1.tsv
table < /tmp/dr_tableD1.tsv

if [ "$ZEEBE_REMAINING" -eq 0 ] && [ "$ES_REMAINING" -eq 0 ]; then
  ok "Full region loss confirmed: east's Zeebe AND Elasticsearch are both down."
else
  fail "East is not fully down yet - check manually before continuing."
  exit 1
fi

next_step "./02-verify-degraded.sh   (confirm west sees quorum loss)"
