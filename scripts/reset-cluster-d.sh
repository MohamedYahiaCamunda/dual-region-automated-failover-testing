#!/usr/bin/env bash
# Test D's own reset script - see reset-cluster.sh's header comment for the
# shared Test A/B/C version. This is the same "wipe everything, rebuild a
# clean baseline" reset, but restores Test D's baseline instead:
#   - Unconditionally wipes and recreates BOTH regions' Elasticsearch (fresh
#     PVCs, both regions, every run) - including re-registering MinIO
#     keystore/snapshot repo credentials. Identical to the shared reset.
#   - Always does a full fresh bootstrap of Zeebe in BOTH regions (the only
#     reliable way to restore true RF4). This PVC wipe/rebuild is a
#     deliberate, expected Zeebe restart - it's the "start from zero" step of
#     a reset, not the kind of unnecessary restart Test D exists to avoid
#     (which is Zeebe being restarted merely as a side effect of toggling
#     unrelated Operate/Tasklist flags during promote/demote).
#   - Force-resumes exporting and re-enables both exporters.
#   - Resets active-passive component roles back to Test D's canonical
#     baseline using promote-region-d.sh / demote-region-d.sh (NOT the shared
#     promote-region.sh/demote-region.sh) and the helm-overlays/test-d/*.yaml
#     files: east ACTIVE (Connectors/Identity/Keycloak/Optimize), west
#     PASSIVE. Operate/Tasklist are never toggled here - they're permanently
#     baked on in helm-overlays/test-d/{east,west}-values.yaml, so there's
#     nothing to reset for them.
#   - Clears scripts/.state/test-d.env only (test-a/b/c's state files are
#     untouched - use reset-cluster.sh for those suites).
#
# Deliberately NOT touched: the standalone "keycloak-postgres" Helm release in
# east (Keycloak's one, shared, always-on Postgres - see helm-overlays/
# east-values.yaml's identityKeycloak.externalDatabase comment). It's a
# separate release from "camunda", so nothing here can reach it even by
# accident - by design, so Keycloak's realm/user state survives every reset.
#
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

header "RESET (TEST D): restoring the full Camunda footprint (both regions) to Test D's clean baseline"

confirm_destructive "This wipes ALL 8 Zeebe PVCs AND both regions' Elasticsearch PVCs (data-camunda-elasticsearch-master-0/1/2, east and west) unconditionally for a full fresh bootstrap, and resets active-passive component roles to east=active/west=passive via promote-region-d.sh/demote-region-d.sh (Test D's Zeebe-restart-free variant). ALL existing process data (Zeebe engine state and Elasticsearch history) will be lost - this is a genuinely clean slate, not just a repair of whatever looks broken."

# recreate_es CTX NS LPORT REGION_LABEL -> unconditionally scales that
# region's Elasticsearch to 0, deletes its 3 PVCs, scales back to 3, and
# re-registers the MinIO keystore/snapshot repo. Identical to reset-cluster.sh.
recreate_es() {
  local ctx="$1" ns="$2" lport="$3" region_label="$4"

  info "Scaling $region_label's Elasticsearch to 0..."
  run_cmd oc --context "$ctx" -n "$ns" scale statefulset camunda-elasticsearch-master --replicas=0 > /dev/null
  if ! wait_for_pod_pattern_count "$ctx" "$ns" "camunda-elasticsearch-master-" 0 12 5 "Waiting for $region_label's Elasticsearch to terminate"; then
    fail "$region_label's Elasticsearch did not scale down in time."
    exit 1
  fi

  info "Deleting $region_label's 3 Elasticsearch PVCs..."
  run_cmd oc --context "$ctx" -n "$ns" delete pvc data-camunda-elasticsearch-master-0 data-camunda-elasticsearch-master-1 data-camunda-elasticsearch-master-2 > /dev/null
  ok "$region_label's Elasticsearch PVCs deleted."

  info "Scaling $region_label's Elasticsearch back to 3 (fresh, empty storage)..."
  run_cmd oc --context "$ctx" -n "$ns" scale statefulset camunda-elasticsearch-master --replicas=3 > /dev/null
  if ! wait_for_pod_pattern_count "$ctx" "$ns" "camunda-elasticsearch-master-" 3 12 15 "Waiting for $region_label's Elasticsearch to become ready"; then
    fail "$region_label's Elasticsearch did not come back ready in time."
    exit 1
  fi
  ok "$region_label's Elasticsearch is up (3/3), fresh and empty."

  info "Re-adding MinIO S3 credentials to $region_label's ES keystore..."
  for i in 0 1 2; do
    show_cmd "oc --context $ctx -n $ns exec camunda-elasticsearch-master-$i -- bash -c \"elasticsearch-keystore add -x -f s3.client.camunda.secret_key / access_key\""
    oc --context "$ctx" -n "$ns" exec "camunda-elasticsearch-master-$i" -- bash -c "
      echo -n '$MINIO_SECRET_KEY' | elasticsearch-keystore add -x -f s3.client.camunda.secret_key
      echo -n '$MINIO_ACCESS_KEY' | elasticsearch-keystore add -x -f s3.client.camunda.access_key
    " > /dev/null 2>&1
  done
  local pf
  pf=$(pf_start "$ctx" "$ns" svc/camunda-elasticsearch "$lport" 9200)
  show_cmd "curl -s -X POST http://localhost:${lport}/_nodes/reload_secure_settings"
  curl -s -X POST "http://localhost:${lport}/_nodes/reload_secure_settings" > /dev/null
  show_cmd "curl -s -X PUT http://localhost:${lport}/_snapshot/$BACKUP_REPO -H 'Content-Type: application/json' -d '{\"type\":\"s3\",\"settings\":{...}}'"
  curl -s -X PUT "http://localhost:${lport}/_snapshot/$BACKUP_REPO" -H 'Content-Type: application/json' -d "{
    \"type\": \"s3\",
    \"settings\": {\"bucket\": \"$MINIO_BUCKET\", \"client\": \"camunda\", \"endpoint\": \"minio.${ns}.svc.cluster.local:9000\", \"protocol\": \"http\", \"path_style_access\": true}
  }" > /dev/null
  pf_stop "$pf"
  ok "$region_label's snapshot repository re-registered."
}

# --- 1. Unconditionally wipe + recreate BOTH regions' Elasticsearch ---
header "1/5: Wiping and recreating both regions' Elasticsearch"
recreate_es "$CONTEXT_EAST" "$NS_EAST" 19200 "East"
recreate_es "$CONTEXT_WEST" "$NS_WEST" 19201 "West"

# --- 2. Full fresh bootstrap of Zeebe, both regions ---
header "2/5: Full fresh bootstrap of Zeebe (both regions)"
info "Scaling both regions' Zeebe to 0..."
run_cmd oc --context "$CONTEXT_EAST" -n "$NS_EAST" scale statefulset camunda-zeebe --replicas=0 > /dev/null
run_cmd oc --context "$CONTEXT_WEST" -n "$NS_WEST" scale statefulset camunda-zeebe --replicas=0 > /dev/null
wait_for_zero_zeebe_pods "$CONTEXT_EAST" "$NS_EAST"
wait_for_zero_zeebe_pods "$CONTEXT_WEST" "$NS_WEST"
ok "Both regions' Zeebe fully down."

info "Deleting all 8 Zeebe PVCs..."
run_cmd oc --context "$CONTEXT_EAST" -n "$NS_EAST" delete pvc data-camunda-zeebe-0 data-camunda-zeebe-1 data-camunda-zeebe-2 data-camunda-zeebe-3 > /dev/null
run_cmd oc --context "$CONTEXT_WEST" -n "$NS_WEST" delete pvc data-camunda-zeebe-0 data-camunda-zeebe-1 data-camunda-zeebe-2 data-camunda-zeebe-3 > /dev/null
ok "PVCs deleted."

info "Scaling both regions back to 4 replicas..."
run_cmd oc --context "$CONTEXT_EAST" -n "$NS_EAST" scale statefulset camunda-zeebe --replicas=4 > /dev/null
run_cmd oc --context "$CONTEXT_WEST" -n "$NS_WEST" scale statefulset camunda-zeebe --replicas=4 > /dev/null

info "Waiting for all 8 pods to become ready (this can take ~1-2 minutes)..."
if wait_for_zeebe_pods "$CONTEXT_EAST" "$NS_EAST" 4 && wait_for_zeebe_pods "$CONTEXT_WEST" "$NS_WEST" 4; then
  ok "All 8 Zeebe pods ready."
else
  fail "Pods did not become ready in time - check manually."
  exit 1
fi

# --- 3. Force exporters back to enabled + resumed (a failed test can leave
#         exporting paused, or one exporter disabled) ---
header "3/5: Resetting exporter state"
info "Resuming exporting globally (no-op if already resumed) and re-enabling both exporters..."
resume_exporting "$CONTEXT_EAST" "$NS_EAST" camunda-zeebe-0 19600 > /dev/null
set_exporter "$CONTEXT_EAST" "$NS_EAST" camunda-zeebe-0 19600 camundaregion0 enable
set_exporter "$CONTEXT_EAST" "$NS_EAST" camunda-zeebe-0 19600 camundaregion1 enable
sleep 8
get_exporters_json "$CONTEXT_EAST" "$NS_EAST" camunda-zeebe-0 19600 | python3 "$LIB_DIR/exporters_view.py" "Exporter Status" || true

# --- 4. Reset active-passive component roles to Test D's canonical baseline ---
header "4/5: Resetting active-passive roles (east=active, west=passive) - Test D variant, no Zeebe restart"
"$SCRIPTS_DIR/promote-region-d.sh" east
"$SCRIPTS_DIR/demote-region-d.sh" west

# --- 5. Verify + clear state ---
header "5/5: Verifying clean baseline and clearing Test D state"
# A flat sleep here is not enough: promote-region-d.sh/demote-region-d.sh
# don't restart Zeebe on repeated use, but the FIRST time this runs against a
# region that was last deployed via the shared (non-Test-D) values lineage,
# switching to test-d/*.yaml is itself a genuine one-time values diff (still
# just a comment/whitespace difference in the rendered manifest, but enough
# to change the StatefulSet's pod template hash and trigger one real rolling
# restart) - so wait for actual Zeebe readiness, not a guessed delay.
if ! wait_for_zeebe_pods "$CONTEXT_EAST" "$NS_EAST" 4 || ! wait_for_zeebe_pods "$CONTEXT_WEST" "$NS_WEST" 4; then
  warn "Zeebe pods did not all reach 1/1 in time - checks below may still show stale/unreachable results."
fi
CLUSTER=$(get_cluster_json "$CONTEXT_EAST" "$NS_EAST" camunda-zeebe-0 19600)
RF_OK=0
echo "$CLUSTER" | python3 "$LIB_DIR/rf_view.py" || RF_OK=$?

READY_E=0; READY_W=0
get_readiness_json "$CONTEXT_EAST" "$NS_EAST" camunda-zeebe-0 19600 | python3 "$LIB_DIR/readiness_view.py" "East readiness" || READY_E=$?
get_readiness_json "$CONTEXT_WEST" "$NS_WEST" camunda-zeebe-0 19700 | python3 "$LIB_DIR/readiness_view.py" "West readiness" || READY_W=$?

# Identity/Keycloak/Optimize are active-active now (both regions, always) -
# Connectors is the only genuinely active-passive component left to check.
EAST_PASSIVE_UP=$(oc --context "$CONTEXT_EAST" -n "$NS_EAST" get pods --no-headers 2>/dev/null | grep -cE "camunda-connectors" || true)
WEST_PASSIVE_DOWN=$(oc --context "$CONTEXT_WEST" -n "$NS_WEST" get pods --no-headers 2>/dev/null | grep -cE "camunda-connectors" || true)
printf 'Check\tResult\n' > /tmp/dr_reset_roles_d.tsv
printf 'East Connectors running\t%s (expect >0)\n' "$EAST_PASSIVE_UP" >> /tmp/dr_reset_roles_d.tsv
printf 'West Connectors running\t%s (expect 0)\n' "$WEST_PASSIVE_DOWN" >> /tmp/dr_reset_roles_d.tsv
table < /tmp/dr_reset_roles_d.tsv

: > "$(state_file "test-d")"
ok "Cleared scripts/.state/test-d.env."

echo
if [ "$RF_OK" -eq 0 ] && [ "$READY_E" -eq 0 ] && [ "$READY_W" -eq 0 ] && [ "$EAST_PASSIVE_UP" -gt 0 ] && [ "$WEST_PASSIVE_DOWN" -eq 0 ]; then
  echo "${C_BOLD}${C_GREEN}✔ RESET COMPLETE - full Camunda footprint (both regions) is back to Test D's clean baseline.${C_RESET}"
  echo "You can now restart from ./test-d/00-baseline.sh"
else
  fail "Reset finished but verification shows issues above (RF/readiness/roles) - review before restarting a test."
  exit 1
fi
