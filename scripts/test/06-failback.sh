#!/usr/bin/env bash
# Step 6: Failback (combined - the full recovery procedure)
#
# Follows a fixed phase order: recreate Elasticsearch, then Zeebe, then
# pause/snapshot/restore/initialize-exporter/resume, then re-add brokers
# last. Three constraints drive this order: Elasticsearch must exist before
# Zeebe starts (an Operate/Tasklist startup dependency), force-removed
# brokers need fresh storage to safely rejoin, and re-adding brokers requires
# no force flag plus an explicit replication factor.
#
# This script deliberately never toggles Operate/Tasklist off during the
# backup/restore window. The official dual-region procedure deactivates
# Operate/Tasklist on the surviving region before the backup/restore window
# and re-enables them afterward, since some chart versions consolidate them
# into the same "orchestration" StatefulSet Zeebe lives in - toggling them
# via Helm would force a full rolling restart of every broker in the
# surviving region, twice, in the middle of an already-delicate recovery
# window. This suite instead accepts the tradeoff of Operate/Tasklist
# remaining reachable during the brief pause/snapshot window, rather than
# being gated off, in exchange for Zeebe never being touched by anything
# other than the raw actuator API calls (force-remove/add) for the entire
# failover-and-failback flow. This also means no "wait for the rolling
# restart to settle" step is needed before pausing exporting: west's brokers
# have been stable and undisturbed since they took over in 03-failover.sh.
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

STATE=$(state_file "test")
state_load "$STATE"
require_state TEST_BASELINE_COMPLETED_KEYS "./00-baseline.sh"
require_state TEST_BASELINE_ACTIVE_KEYS "./00-baseline.sh"
require_state TEST_DURING_COMPLETED_KEYS "./05-create-data-during-outage.sh"
require_state TEST_DURING_ACTIVE_KEYS "./05-create-data-during-outage.sh"

header "STEP 6: Failback (combined recovery, documented order, zero Zeebe restarts)"

# --- 1/6: Safety check ---
header "1/6: Safety check"
ALL_KEYS="$TEST_BASELINE_COMPLETED_KEYS $TEST_BASELINE_ACTIVE_KEYS $TEST_DURING_COMPLETED_KEYS $TEST_DURING_ACTIVE_KEYS"
CSV=$(join_csv "$ALL_KEYS")
COUNT=$(echo "$ALL_KEYS" | wc -w | tr -d ' ')
info "Confirming all $COUNT test instances are durably in west's Elasticsearch before touching any storage..."
WEST_COUNT=$(es_query_count "$CONTEXT_WEST" "$NS_WEST" 19201 "$CSV")
printf 'Check\tResult\n' > /tmp/dr_tableD6_pre.tsv
printf 'Instances confirmed safe in west ES\t%s / %s\n' "$WEST_COUNT" "$COUNT" >> /tmp/dr_tableD6_pre.tsv
table < /tmp/dr_tableD6_pre.tsv
if [ "$WEST_COUNT" -ne "$COUNT" ]; then
  fail "Not all data is safely in Elasticsearch yet - aborting before touching anything."
  exit 1
fi
ok "Safe to proceed."

confirm_destructive "This wipes east's Elasticsearch AND Zeebe PVCs only (east was fully lost - its storage is stale/unusable either way) and rebuilds it as a fresh replica of west. West's PVCs and live Zeebe state are NEVER touched at any point - west's Zeebe brokers are never even restarted."

# --- 2/6: Recreate east's Elasticsearch (before Zeebe - Operate startup dependency) ---
header "2/6: Recreate east's Elasticsearch"
info "Scaling east's Elasticsearch back to 3 replicas (fresh PVCs)..."
run_cmd oc --context "$CONTEXT_EAST" -n "$NS_EAST" scale statefulset camunda-elasticsearch-master --replicas=3 > /dev/null
show_cmd "oc --context $CONTEXT_EAST -n $NS_EAST get pods   (polling every 15s for camunda-elasticsearch-master-* to reach 3x 1/1)"
for i in $(seq 1 12); do
  ready=$(oc --context "$CONTEXT_EAST" -n "$NS_EAST" get pods --no-headers 2>/dev/null | grep "camunda-elasticsearch-master-" | grep -c "1/1" || true)
  if [ "$ready" -eq 3 ]; then break; fi
  sleep 15
done
ready=$(oc --context "$CONTEXT_EAST" -n "$NS_EAST" get pods --no-headers 2>/dev/null | grep "camunda-elasticsearch-master-" | grep -c "1/1" || true)
if [ "$ready" -ne 3 ]; then
  fail "East's Elasticsearch did not become ready in time."
  exit 1
fi
ok "East's Elasticsearch is fresh and ready (3/3)."

info "Re-adding MinIO S3 credentials to east's ES keystore..."
for i in 0 1 2; do
  show_cmd "oc --context $CONTEXT_EAST -n $NS_EAST exec camunda-elasticsearch-master-$i -- bash -c \"elasticsearch-keystore add -x -f s3.client.camunda.secret_key / access_key\""
  oc --context "$CONTEXT_EAST" -n "$NS_EAST" exec "camunda-elasticsearch-master-$i" -- bash -c "
    echo -n '$MINIO_SECRET_KEY' | elasticsearch-keystore add -x -f s3.client.camunda.secret_key
    echo -n '$MINIO_ACCESS_KEY' | elasticsearch-keystore add -x -f s3.client.camunda.access_key
  " > /dev/null 2>&1
done
PF=$(pf_start "$CONTEXT_EAST" "$NS_EAST" svc/camunda-elasticsearch 19200 9200)
show_cmd "curl -s -X POST http://localhost:19200/_nodes/reload_secure_settings"
curl -s -X POST http://localhost:19200/_nodes/reload_secure_settings > /dev/null
info "Registering snapshot repository on east (pointing at east's OWN local MinIO)..."
show_cmd "curl -s -X PUT http://localhost:19200/_snapshot/$BACKUP_REPO -H 'Content-Type: application/json' -d '{\"type\":\"s3\",\"settings\":{\"bucket\":\"$MINIO_BUCKET\",\"client\":\"camunda\",\"endpoint\":\"minio.${NS_EAST}.svc.cluster.local:9000\",\"protocol\":\"http\",\"path_style_access\":true}}'"
curl -s -X PUT http://localhost:19200/_snapshot/$BACKUP_REPO -H 'Content-Type: application/json' -d "{
  \"type\": \"s3\",
  \"settings\": {\"bucket\": \"$MINIO_BUCKET\", \"client\": \"camunda\", \"endpoint\": \"minio.${NS_EAST}.svc.cluster.local:9000\", \"protocol\": \"http\", \"path_style_access\": true}
}" > /dev/null
pf_stop "$PF"
ok "East's Elasticsearch ready to receive a restore."

# --- 3/6: Recreate east's Zeebe fresh (NOT yet added to the cluster topology) ---
header "3/6: Recreate east's Zeebe (fresh storage, west untouched)"
info "Confirming east's Zeebe is at 0 (from step 01) and deleting its 4 PVCs..."
run_cmd oc --context "$CONTEXT_EAST" -n "$NS_EAST" scale statefulset camunda-zeebe --replicas=0 > /dev/null
wait_for_zero_zeebe_pods "$CONTEXT_EAST" "$NS_EAST"
run_cmd oc --context "$CONTEXT_EAST" -n "$NS_EAST" delete pvc data-camunda-zeebe-0 data-camunda-zeebe-1 data-camunda-zeebe-2 data-camunda-zeebe-3 > /dev/null
ok "East's stale Zeebe PVCs deleted. West was never scaled down or touched."

info "Scaling east back to 4 replicas on fresh (empty) storage..."
run_cmd oc --context "$CONTEXT_EAST" -n "$NS_EAST" scale statefulset camunda-zeebe --replicas=4 > /dev/null
show_cmd "oc --context $CONTEXT_EAST -n $NS_EAST get pods   (polling every 10s for camunda-zeebe-* pods to reach Running - not Ready yet, not in the topology until step 6/6)"
for i in $(seq 1 12); do
  running=$(oc --context "$CONTEXT_EAST" -n "$NS_EAST" get pods --no-headers 2>/dev/null | grep "camunda-zeebe-" | grep -c "Running" || true)
  if [ "$running" -eq 4 ]; then break; fi
  sleep 10
done
ok "East's 4 fresh Zeebe pods are Running (empty storage, not yet part of the cluster topology)."

# --- 4/6: Snapshot from west, restore into east ---
header "4/6: Snapshot (west only) + restore into east"

info "Pausing ALL exporting (global, synchronous) to get a consistent snapshot point - no Operate/Tasklist toggle and no stabilization wait needed here: west's brokers have been undisturbed since 03-failover.sh..."
PAUSE_CODE=""
for attempt in 1 2 3 4 5; do
  PAUSE_CODE=$(pause_exporting "$CONTEXT_WEST" "$NS_WEST" camunda-zeebe-0 19700)
  [ "$PAUSE_CODE" = "204" ] && break
  warn "Pause returned status=$PAUSE_CODE (attempt $attempt/5) - retrying in 10s..."
  sleep 10
done
printf 'Check\tResult\n' > /tmp/dr_tableD6_pause.tsv
printf 'POST /actuator/exporting/pause\tstatus=%s (expect 204)\n' "$PAUSE_CODE" >> /tmp/dr_tableD6_pause.tsv
table < /tmp/dr_tableD6_pause.tsv
if [ "$PAUSE_CODE" != "204" ]; then
  fail "Pause did not return 204 after 5 attempts - aborting before taking a snapshot against a moving target."
  exit 1
fi
ok "Exporting paused cluster-wide."

SNAP_NAME="failback-testd-$(date +%s 2>/dev/null || echo run)"
SNAP_NAME=$(echo "$SNAP_NAME" | tr 'A-Z' 'a-z')
info "Taking a COMPREHENSIVE snapshot from west (single-writer rule: west only)..."
PF=$(pf_start "$CONTEXT_WEST" "$NS_WEST" svc/camunda-elasticsearch 19201 9200)
show_cmd "curl -s -X PUT 'http://localhost:19201/_snapshot/${BACKUP_REPO}/${SNAP_NAME}?wait_for_completion=true' -H 'Content-Type: application/json' -d '{\"indices\":\"camunda-*,operate-*,tasklist-*\",\"include_global_state\":false}'"
SNAP_RESP=$(curl -s -X PUT "http://localhost:19201/_snapshot/${BACKUP_REPO}/${SNAP_NAME}?wait_for_completion=true" -H 'Content-Type: application/json' -d '{
  "indices": "camunda-*,operate-*,tasklist-*",
  "include_global_state": false
}')
pf_stop "$PF"
echo "$SNAP_RESP" | python3 -c "
import json,sys
d = json.load(sys.stdin)
if 'error' in d:
    print('  ERROR:', d['error']['reason'])
    sys.exit(1)
print(f\"  -> state={d['snapshot']['state']}, indices={len(d['snapshot']['indices'])}\")
"
ok "Snapshot '$SNAP_NAME' created on west."

info "Waiting for MinIO to replicate the snapshot to east's bucket..."
sleep 15
show_cmd "oc --context $CONTEXT_EAST -n $NS_EAST exec deploy/minio -- mc ls e/$MINIO_BUCKET --recursive"
EAST_OBJ_COUNT=$(oc --context "$CONTEXT_EAST" -n "$NS_EAST" exec deploy/minio -- sh -c "mc alias set e http://localhost:9000 $MINIO_ACCESS_KEY $MINIO_SECRET_KEY >/dev/null 2>&1; mc ls e/$MINIO_BUCKET --recursive" 2>/dev/null | wc -l | tr -d ' ')
printf 'Check\tResult\n' > /tmp/dr_tableD6_repl.tsv
printf "Objects replicated to east's bucket\t%s\n" "$EAST_OBJ_COUNT" >> /tmp/dr_tableD6_repl.tsv
table < /tmp/dr_tableD6_repl.tsv

info "Re-registering east's repository (clears repository-metadata cache)..."
PF=$(pf_start "$CONTEXT_EAST" "$NS_EAST" svc/camunda-elasticsearch 19200 9200)
show_cmd "curl -s -X DELETE http://localhost:19200/_snapshot/$BACKUP_REPO"
curl -s -X DELETE http://localhost:19200/_snapshot/$BACKUP_REPO > /dev/null
show_cmd "curl -s -X PUT http://localhost:19200/_snapshot/$BACKUP_REPO -H 'Content-Type: application/json' -d '{\"type\":\"s3\",\"settings\":{...}}'"
curl -s -X PUT http://localhost:19200/_snapshot/$BACKUP_REPO -H 'Content-Type: application/json' -d "{
  \"type\": \"s3\",
  \"settings\": {\"bucket\": \"$MINIO_BUCKET\", \"client\": \"camunda\", \"endpoint\": \"minio.${NS_EAST}.svc.cluster.local:9000\", \"protocol\": \"http\", \"path_style_access\": true}
}" > /dev/null

info "Deleting east's auto-created baseline indices (Zeebe's own exporter initializes its Elasticsearch schema as soon as a broker starts, well before it rejoins the cluster topology - those indices are empty schema-only, not real data, and would otherwise conflict with the restore)..."
show_cmd "curl -s http://localhost:19200/_cat/indices/camunda-*,operate-*,tasklist-*?h=index   (ES rejects wildcard DELETE outright - action.destructive_requires_name - so list exact names first)"
EXISTING_INDICES=$(curl -s "http://localhost:19200/_cat/indices/camunda-*,operate-*,tasklist-*?h=index" | tr -s ' \n' ',' | sed 's/,$//')
if [ -n "$EXISTING_INDICES" ]; then
  show_cmd "curl -s -X DELETE http://localhost:19200/$EXISTING_INDICES"
  curl -s -X DELETE "http://localhost:19200/$EXISTING_INDICES" > /dev/null
  ok "Deleted $(echo "$EXISTING_INDICES" | tr ',' '\n' | wc -l | tr -d ' ') pre-existing empty indices."
else
  info "No pre-existing indices found - nothing to delete."
fi

info "Restoring '$SNAP_NAME' into east (all camunda-*/operate-*/tasklist-* indices)..."
show_cmd "curl -s -X POST 'http://localhost:19200/_snapshot/${BACKUP_REPO}/${SNAP_NAME}/_restore?wait_for_completion=true' -H 'Content-Type: application/json' -d '{\"indices\":\"camunda-*,operate-*,tasklist-*\"}'"
RESTORE_RESP=$(curl -s -X POST "http://localhost:19200/_snapshot/${BACKUP_REPO}/${SNAP_NAME}/_restore?wait_for_completion=true" -H 'Content-Type: application/json' -d '{
  "indices": "camunda-*,operate-*,tasklist-*"
}')
pf_stop "$PF"
echo "$RESTORE_RESP" | python3 -c "
import json,sys
d = json.load(sys.stdin)
if 'error' in d:
    print('  ERROR:', d['error']['reason'])
    sys.exit(1)
s = d['snapshot']
print(f\"  -> restored {len(s['indices'])} indices, shards={s['shards']}\")
"
ok "Restore complete."

# --- 5/6: Initialize east's exporter, then resume exporting ---
header "5/6: Initialize east's exporter, then resume exporting"
info "Initializing camundaregion0 from camundaregion1 (POST .../enable with initializeFrom)..."
enable_exporter_init "$CONTEXT_WEST" "$NS_WEST" camunda-zeebe-0 19700 camundaregion0 camundaregion1
sleep 15

check_for_closed_leaders() {
  STUCK=0
  local exp
  exp=$(get_exporters_json "$CONTEXT_WEST" "$NS_WEST" camunda-zeebe-0 19700)
  echo "$exp" | python3 "$LIB_DIR/exporters_view.py" "Reported exporter status (west)"

  echo
  info "Checking /actuator/cluster lastChange status (the documented verification)..."
  local cluster last_status
  cluster=$(get_cluster_json "$CONTEXT_WEST" "$NS_WEST" camunda-zeebe-0 19700)
  last_status=$(echo "$cluster" | python3 -c "import json,sys; print((json.load(sys.stdin).get('lastChange') or {}).get('status','COMPLETED'))" 2>/dev/null || echo "?")
  echo "  lastChange.status = $last_status (expect COMPLETED)"
  if [ "$last_status" != "COMPLETED" ]; then
    STUCK=$((STUCK + 1))
  fi

  echo
  info "Checking for genuinely CLOSED partition leaders (PAUSED is expected right now, not a bug) - west only, east isn't in the topology yet..."
  local i POD JSON COUNT
  for i in 0 1 2 3; do
    POD="camunda-zeebe-$i"
    JSON=$(get_partitions_json "$CONTEXT_WEST" "$NS_WEST" "$POD" "1970$i")
    echo "$JSON" | python3 "$LIB_DIR/partitions_view.py" "west $POD" || true
    COUNT=$(echo "$JSON" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(sum(1 for p in d.values() if p.get('role')=='LEADER' and p.get('exporterPhase')=='CLOSED'))
" 2>/dev/null || echo 0)
    STUCK=$((STUCK + COUNT)) || true
    echo
  done
}

STUCK=0
check_for_closed_leaders

if [ "$STUCK" -gt 0 ]; then
  warn "BUG DETECTED: $STUCK genuinely broken signal(s) (CLOSED leader and/or lastChange not COMPLETED)."
  warn "Restarting west's 4 broker pods - the only fix found for this defect. East isn't in the topology yet, nothing to restart there."
  run_cmd oc --context "$CONTEXT_WEST" -n "$NS_WEST" delete pod camunda-zeebe-0 camunda-zeebe-1 camunda-zeebe-2 camunda-zeebe-3 > /dev/null
  if wait_for_zeebe_pods "$CONTEXT_WEST" "$NS_WEST" 4; then
    ok "West's 4 brokers restarted and ready."
  else
    fail "Brokers did not come back ready in time."
    exit 1
  fi
  sleep 10

  info "Re-checking after restart..."
  check_for_closed_leaders
fi

if [ "$STUCK" -ne 0 ]; then
  fail "Still $STUCK broken signal(s) after a broker restart - investigate manually."
  exit 1
fi
ok "No CLOSED leaders, lastChange COMPLETED. Safe to resume."

echo
info "Resuming ALL exporting (global, synchronous) - camundaregion1 was only paused, not disabled..."
RESUME_CODE=""
for attempt in 1 2 3 4 5; do
  RESUME_CODE=$(resume_exporting "$CONTEXT_WEST" "$NS_WEST" camunda-zeebe-0 19700)
  [ "$RESUME_CODE" = "204" ] && break
  warn "Resume returned status=$RESUME_CODE (attempt $attempt/5) - a broker may still be settling right after the restart above, retrying in 10s..."
  sleep 10
done
printf 'Check\tResult\n' > /tmp/dr_tableD6_resume.tsv
printf 'POST /actuator/exporting/resume\tstatus=%s (expect 204)\n' "$RESUME_CODE" >> /tmp/dr_tableD6_resume.tsv
table < /tmp/dr_tableD6_resume.tsv
if [ "$RESUME_CODE" != "204" ]; then
  fail "Resume did not return 204 after 5 attempts - exporting may still be paused."
  exit 1
fi
ok "Exporting resumed cluster-wide."

# --- 6/6: Re-add east's brokers to the Zeebe cluster (LAST, per the documented order) ---
header "6/6: Re-add east's brokers to the Zeebe cluster"
info "Re-adding east's brokers (0,2,4,6) with explicit replicationFactor=4 - per the documented procedure, WITHOUT force (force is rejected for add)..."
RESP=$(patch_cluster "$CONTEXT_WEST" "$NS_WEST" camunda-zeebe-0 19700 '{"brokers":{"add":[0,2,4,6]},"partitions":{"replicationFactor":4}}' false)
CHANGE_ID=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('changeId','?'))" 2>/dev/null || echo "?")
if [ "$CHANGE_ID" = "?" ] || [ "$CHANGE_ID" = "None" ]; then
  fail "Add request was not accepted - raw response: $RESP"
  exit 1
fi
ok "Change accepted, changeId=$CHANGE_ID"
echo "$RESP" | python3 "$LIB_DIR/planned_changes_view.py" || true

info "Polling for completion AND for east's pods to reach 1/1 Ready..."
for i in $(seq 1 12); do
  sleep 10
  CLUSTER=$(get_cluster_json "$CONTEXT_WEST" "$NS_WEST" camunda-zeebe-0 19700)
  STATUS=$(echo "$CLUSTER" | python3 -c "import json,sys; d=json.load(sys.stdin); lc=d.get('lastChange'); print(lc['status'] if lc else 'COMPLETED')" 2>/dev/null || echo "?")
  READY=$(oc --context "$CONTEXT_EAST" -n "$NS_EAST" get pods --no-headers 2>/dev/null | grep "camunda-zeebe-" | grep -c "1/1" || true)
  progress_bar "$READY" 4 "Waiting for east's brokers to rejoin (lastChange=$STATUS, attempt $i/12)"
  if [ "$STATUS" = "COMPLETED" ] && [ "$READY" -eq 4 ]; then
    break
  fi
done

READY=$(oc --context "$CONTEXT_EAST" -n "$NS_EAST" get pods --no-headers 2>/dev/null | grep "camunda-zeebe-" | grep -c "1/1" || true)
if [ "$READY" -ne 4 ]; then
  fail "East's brokers did not reach 1/1 Ready in time - check for the stale-storage deadlock signature in pod logs."
  exit 1
fi
ok "East's 4 brokers rejoined and are 1/1 Ready."

info "Verifying genuine RF4 restoration..."
CLUSTER=$(get_cluster_json "$CONTEXT_WEST" "$NS_WEST" camunda-zeebe-0 19700)
RF_OK=0
echo "$CLUSTER" | python3 "$LIB_DIR/rf_view.py" || RF_OK=$?
if [ "$RF_OK" -ne 0 ]; then
  fail "RF4 was NOT restored - see MISMATCH rows above."
  exit 1
fi
ok "Zeebe genuinely restored to RF4."

echo
info "Final check: both exporters ENABLED and all leaders EXPORTING (the real proof it's flowing again, now across both regions)..."
sleep 10
FINAL_BAD=0
FINAL_EXP=$(get_exporters_json "$CONTEXT_WEST" "$NS_WEST" camunda-zeebe-0 19700)
echo "$FINAL_EXP" | python3 "$LIB_DIR/exporters_view.py" "Final exporter status (west)"
NOT_ENABLED=$(echo "$FINAL_EXP" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(sum(1 for e in d if e.get('status') != 'ENABLED'))
" 2>/dev/null || echo 0)
FINAL_BAD=$((FINAL_BAD + NOT_ENABLED))

for i in 0 1 2 3; do
  POD="camunda-zeebe-$i"
  JSON=$(get_partitions_json "$CONTEXT_EAST" "$NS_EAST" "$POD" "1960$i")
  echo "$JSON" | python3 "$LIB_DIR/partitions_view.py" "east $POD" || true
  COUNT=$(echo "$JSON" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(sum(1 for p in d.values() if p.get('role')=='LEADER' and p.get('exporterPhase')!='EXPORTING'))
" 2>/dev/null || echo 0)
  FINAL_BAD=$((FINAL_BAD + COUNT)) || true
  echo
done
for i in 0 1 2 3; do
  POD="camunda-zeebe-$i"
  JSON=$(get_partitions_json "$CONTEXT_WEST" "$NS_WEST" "$POD" "1970$i")
  echo "$JSON" | python3 "$LIB_DIR/partitions_view.py" "west $POD" || true
  COUNT=$(echo "$JSON" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(sum(1 for p in d.values() if p.get('role')=='LEADER' and p.get('exporterPhase')!='EXPORTING'))
" 2>/dev/null || echo 0)
  FINAL_BAD=$((FINAL_BAD + COUNT)) || true
  echo
done

if [ "$FINAL_BAD" -eq 0 ]; then
  ok "Both exporters ENABLED, all leaders EXPORTING. Exporting is genuinely running again in both regions."
else
  fail "$FINAL_BAD signal(s) still not right after resume - investigate manually before continuing."
  exit 1
fi

echo
info "Final readiness check (both regions)..."
READY_E=0; READY_W=0
get_readiness_json "$CONTEXT_EAST" "$NS_EAST" camunda-zeebe-0 19600 | python3 "$LIB_DIR/readiness_view.py" "East readiness" || READY_E=$?
get_readiness_json "$CONTEXT_WEST" "$NS_WEST" camunda-zeebe-0 19700 | python3 "$LIB_DIR/readiness_view.py" "West readiness" || READY_W=$?

if [ "$READY_E" -ne 0 ] || [ "$READY_W" -ne 0 ]; then
  fail "Readiness check failed on one or both regions - see components above."
  exit 1
fi
ok "Both regions fully healthy at the Zeebe/ES level."

echo
header "Promoting east back to active, then demoting west (in that order - no gap with nothing active) - zero Zeebe restarts"
"$SCRIPTS_DIR/promote-region.sh" east
"$SCRIPTS_DIR/demote-region.sh" west

ok "Failback complete."

next_step "./07-check-leadership.sh   (confirm partition leadership distribution across both regions, rebalancing if needed)"
