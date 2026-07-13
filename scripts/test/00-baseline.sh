#!/usr/bin/env bash
# Step 0: Baseline
# Combined-failure scenario: Zeebe and Elasticsearch are destroyed together in
# a single region, simulating a genuine full region loss. This step creates 5
# baseline process instances: 3 COMPLETED (to prove ES export/history
# survives) and 2 left ACTIVE/in-flight (to prove Zeebe's own replicated
# state survives independently of ES, via PVC/Raft replication).
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

STATE=$(state_file "test")
: > "$STATE"

header "STEP 0: Baseline"

info "Deploying process definition '$PROCESS_ID' (idempotent - new version if already exists)..."
DEPLOY_RESP=$(deploy_process)
echo "$DEPLOY_RESP" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
    print('  -> deployed:', d['deployments'][0]['processDefinition']['processDefinitionId'], 'v' + str(d['deployments'][0]['processDefinition']['processDefinitionVersion']))
except Exception:
    print('  -> deploy response (raw):', sys.stdin)
"

info "Creating 3 COMPLETED baseline instances (batch=baseline-testD)..."
COMPLETED_KEYS=""
for i in 1 2 3; do
  KEY=$(create_completed_instance "$CONTEXT_EAST" "$NS_EAST" "baseline-testD" "$i")
  COMPLETED_KEYS="$COMPLETED_KEYS $KEY"
  echo "  completed instance $i: $KEY"
done
COMPLETED_KEYS=$(echo "$COMPLETED_KEYS" | xargs)
state_set "$STATE" "TEST_BASELINE_COMPLETED_KEYS" "$COMPLETED_KEYS"

info "Creating 2 ACTIVE (uncompleted/in-flight) baseline instances (batch=baseline-testD)..."
ACTIVE_KEYS=""
for i in 4 5; do
  KEY=$(create_instance "$CONTEXT_EAST" "$NS_EAST" "baseline-testD" "$i")
  ACTIVE_KEYS="$ACTIVE_KEYS $KEY"
  echo "  active (left running) instance $i: $KEY"
done
ACTIVE_KEYS=$(echo "$ACTIVE_KEYS" | xargs)
state_set "$STATE" "TEST_BASELINE_ACTIVE_KEYS" "$ACTIVE_KEYS"

sleep 5
ALL_KEYS="$COMPLETED_KEYS $ACTIVE_KEYS"
CSV=$(join_csv "$ALL_KEYS")
COMPLETED_CSV=$(join_csv "$COMPLETED_KEYS")
ACTIVE_CSV=$(join_csv "$ACTIVE_KEYS")

ACTIVE_REGION=$(active_region_name)
if [ "$ACTIVE_REGION" = "east" ]; then
  ACTIVE_CTX="$CONTEXT_EAST"; ACTIVE_NS="$NS_EAST"; ACTIVE_ESPORT=19200
else
  ACTIVE_CTX="$CONTEXT_WEST"; ACTIVE_NS="$NS_WEST"; ACTIVE_ESPORT=19201
fi

info "Verifying presence + correct state in Elasticsearch (active region only: $ACTIVE_REGION - Zeebe/ES are active-active so this data is already replicating to the passive region too, but that's not what this check is for)..."
TOTAL_MATCH=$(es_query_count "$ACTIVE_CTX" "$ACTIVE_NS" "$ACTIVE_ESPORT" "$CSV")
COMPLETED_MATCH=$(es_query_count_by_state "$ACTIVE_CTX" "$ACTIVE_NS" "$ACTIVE_ESPORT" "$COMPLETED_CSV" "COMPLETED")
ACTIVE_MATCH=$(es_query_count_by_state "$ACTIVE_CTX" "$ACTIVE_NS" "$ACTIVE_ESPORT" "$ACTIVE_CSV" "ACTIVE")

printf 'Region\tCompleted\tActive\tTotal\tExpected\tStatus\n' > /tmp/dr_tableD0.tsv
printf '%s\t%s/3\t%s/2\t%s\t5\t%s\n' "$ACTIVE_REGION" "$COMPLETED_MATCH" "$ACTIVE_MATCH" "$TOTAL_MATCH" "$([ "$TOTAL_MATCH" -eq 5 ] && echo OK || echo MISMATCH)" >> /tmp/dr_tableD0.tsv
table < /tmp/dr_tableD0.tsv

TOTAL_DOCS=$(es_total_count "$ACTIVE_CTX" "$ACTIVE_NS" "$ACTIVE_ESPORT")
echo "${C_CYAN}ℹ (informational, not part of pass/fail) Total documents in $ACTIVE_REGION's index across ALL test runs: $TOTAL_DOCS${C_RESET}"

if [ "$TOTAL_MATCH" -eq 5 ]; then
  ok "Baseline established: 3 completed + 2 active instances confirmed in $ACTIVE_REGION (the active region)."
else
  fail "Baseline verification failed - expected 5 in $ACTIVE_REGION."
  exit 1
fi

next_step "./01-inject-failure.sh   (destroy EAST's Zeebe AND Elasticsearch together - full region loss of the primary)"
