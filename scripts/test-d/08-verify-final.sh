#!/usr/bin/env bash
# Test D - Step 8: Final verification
# Confirms all 8 test instances (5 baseline + 3 during-outage, a mix of
# COMPLETED and still-ACTIVE) are present in both regions' Elasticsearch after
# a full combined region-loss recovery, with ACTIVE instances still genuinely
# ACTIVE - confirming that Zeebe's own replicated state survived, not just
# historical ES records - and that active-passive roles were correctly
# restored (east active again, west back to passive).
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

STATE=$(state_file "test-d")
state_load "$STATE"
require_state TESTD_BASELINE_COMPLETED_KEYS "./00-baseline.sh"
require_state TESTD_BASELINE_ACTIVE_KEYS "./00-baseline.sh"
require_state TESTD_DURING_COMPLETED_KEYS "./05-create-data-during-outage.sh"
require_state TESTD_DURING_ACTIVE_KEYS "./05-create-data-during-outage.sh"
require_state TESTD_IDENTITY_USER "./05-create-data-during-outage.sh"
require_state TESTD_IDENTITY_ROLE "./05-create-data-during-outage.sh"

header "TEST D - STEP 8: Final verification"

ALL_KEYS="$TESTD_BASELINE_COMPLETED_KEYS $TESTD_BASELINE_ACTIVE_KEYS $TESTD_DURING_COMPLETED_KEYS $TESTD_DURING_ACTIVE_KEYS"
ACTIVE_KEYS="$TESTD_BASELINE_ACTIVE_KEYS $TESTD_DURING_ACTIVE_KEYS"
CSV=$(join_csv "$ALL_KEYS")
ACTIVE_CSV=$(join_csv "$ACTIVE_KEYS")
COUNT=$(echo "$ALL_KEYS" | wc -w | tr -d ' ')
ACTIVE_COUNT=$(echo "$ACTIVE_KEYS" | wc -w | tr -d ' ')

EAST_COUNT=$(es_query_count "$CONTEXT_EAST" "$NS_EAST" 19200 "$CSV")
WEST_COUNT=$(es_query_count "$CONTEXT_WEST" "$NS_WEST" 19201 "$CSV")
EAST_ACTIVE=$(es_query_count_by_state "$CONTEXT_EAST" "$NS_EAST" 19200 "$ACTIVE_CSV" "ACTIVE")
WEST_ACTIVE=$(es_query_count_by_state "$CONTEXT_WEST" "$NS_WEST" 19201 "$ACTIVE_CSV" "ACTIVE")

printf 'Region\tTotal\tStill Active\tExpected\tStatus\n' > /tmp/dr_tableD8.tsv
printf 'East (fully destroyed + restored)\t%s\t%s/%s\t%s\t%s\n' "$EAST_COUNT" "$EAST_ACTIVE" "$ACTIVE_COUNT" "$COUNT" "$([ "$EAST_COUNT" -eq "$COUNT" ] && [ "$EAST_ACTIVE" -eq "$ACTIVE_COUNT" ] && echo OK || echo MISMATCH)" >> /tmp/dr_tableD8.tsv
printf 'West\t%s\t%s/%s\t%s\t%s\n' "$WEST_COUNT" "$WEST_ACTIVE" "$ACTIVE_COUNT" "$COUNT" "$([ "$WEST_COUNT" -eq "$COUNT" ] && [ "$WEST_ACTIVE" -eq "$ACTIVE_COUNT" ] && echo OK || echo MISMATCH)" >> /tmp/dr_tableD8.tsv
table < /tmp/dr_tableD8.tsv

EAST_TOTAL=$(es_total_count "$CONTEXT_EAST" "$NS_EAST" 19200)
WEST_TOTAL=$(es_total_count "$CONTEXT_WEST" "$NS_WEST" 19201)
echo "${C_CYAN}ℹ (informational, not part of pass/fail) Total documents in the index across ALL test runs - East: $EAST_TOTAL, West: $WEST_TOTAL${C_RESET}"

echo
info "Confirming east's Connectors were promoted back, west's were demoted (Identity/Keycloak/Optimize are active-active now, both regions, always)..."
EAST_PASSIVE_UP=$(oc --context "$CONTEXT_EAST" -n "$NS_EAST" get pods --no-headers 2>/dev/null | grep -cE "camunda-connectors" || true)
WEST_PASSIVE_DOWN=$(oc --context "$CONTEXT_WEST" -n "$NS_WEST" get pods --no-headers 2>/dev/null | grep -cE "camunda-connectors" || true)
printf 'Check\tResult\n' > /tmp/dr_tableD8_promo.tsv
printf 'East Connectors running\t%s (expect >0)\n' "$EAST_PASSIVE_UP" >> /tmp/dr_tableD8_promo.tsv
printf 'West Connectors running\t%s (expect 0)\n' "$WEST_PASSIVE_DOWN" >> /tmp/dr_tableD8_promo.tsv
table < /tmp/dr_tableD8_promo.tsv

echo
info "Engine-level recovery proof: the ACTIVE checks above only confirm the ES"
info "PROJECTION of these instances survived - that document was exported at"
info "creation time and never touched again, so it proves nothing about whether"
info "the underlying Zeebe/RocksDB engine state is still genuinely operable."
info "Completing a PRE-OUTAGE baseline instance now is the real proof: it"
info "requires the engine to still have valid job/variable state for it."
ENGINE_KEY=$(echo "$TESTD_BASELINE_ACTIVE_KEYS" | awk '{print $1}')
ENGINE_OK=0
if complete_job_for_instance "$CONTEXT_EAST" "$NS_EAST" "$ENGINE_KEY"; then
  sleep 8
  EAST_ENGINE=$(es_query_count_by_state "$CONTEXT_EAST" "$NS_EAST" 19200 "$ENGINE_KEY" "COMPLETED")
  WEST_ENGINE=$(es_query_count_by_state "$CONTEXT_WEST" "$NS_WEST" 19201 "$ENGINE_KEY" "COMPLETED")
  printf 'Check\tResult\n' > /tmp/dr_tableD8_engine.tsv
  printf 'Pre-outage instance completed (key=%s)\tjob accepted\n' "$ENGINE_KEY" >> /tmp/dr_tableD8_engine.tsv
  printf 'Transitioned to COMPLETED in east\t%s/1\n' "$EAST_ENGINE" >> /tmp/dr_tableD8_engine.tsv
  printf 'Transitioned to COMPLETED in west\t%s/1\n' "$WEST_ENGINE" >> /tmp/dr_tableD8_engine.tsv
  table < /tmp/dr_tableD8_engine.tsv
  if [ "$EAST_ENGINE" -eq 1 ] && [ "$WEST_ENGINE" -eq 1 ]; then
    ENGINE_OK=1
    ok "Engine-level recovery confirmed: RocksDB/Raft state for the pre-outage instance was genuinely intact and operable."
  else
    fail "Job completed but COMPLETED state did not propagate to both regions - check exporter health."
  fi
else
  fail "Could not complete the pre-outage instance's job - the underlying engine state may not have survived correctly."
fi

echo
info "Architecture proof: '$TESTD_IDENTITY_USER' + role '$TESTD_IDENTITY_ROLE' were created via WEST's Keycloak during the outage (05-create-data-during-outage.sh). Confirming they're visible via EAST's Keycloak now, post-failback - proving both regions genuinely share one realm/database, not two independent ones that merely look alike..."
IDENTITY_OK=0
KC_ADMIN_PASS=$(oc --context "$CONTEXT_EAST" -n "$NS_EAST" get secret camunda-credentials -o jsonpath='{.data.identity-keycloak-admin-password}' 2>/dev/null | base64 -d)
PF=$(pf_start "$CONTEXT_EAST" "$NS_EAST" svc/camunda-keycloak 18380 80)
KC_TOKEN=$(curl -s -X POST "http://localhost:18380/auth/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "username=admin" -d "password=$KC_ADMIN_PASS" -d "grant_type=password" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
if [ -n "$KC_TOKEN" ]; then
  USER_ID=$(curl -s "http://localhost:18380/auth/admin/realms/camunda-platform/users?username=$TESTD_IDENTITY_USER" \
    -H "Authorization: Bearer $KC_TOKEN" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null)
  ROLE_ASSIGNED="no"
  if [ -n "$USER_ID" ]; then
    ROLE_ASSIGNED=$(curl -s "http://localhost:18380/auth/admin/realms/camunda-platform/users/${USER_ID}/role-mappings/realm" \
      -H "Authorization: Bearer $KC_TOKEN" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print('yes' if any(r.get('name')=='$TESTD_IDENTITY_ROLE' for r in d) else 'no')
" 2>/dev/null)
  fi
  printf 'Check\tResult\n' > /tmp/dr_tableD8_identity.tsv
  printf 'User %s found via east\t%s\n' "$TESTD_IDENTITY_USER" "$([ -n "$USER_ID" ] && echo yes || echo no)" >> /tmp/dr_tableD8_identity.tsv
  printf 'Role %s assigned\t%s\n' "$TESTD_IDENTITY_ROLE" "$ROLE_ASSIGNED" >> /tmp/dr_tableD8_identity.tsv
  table < /tmp/dr_tableD8_identity.tsv
  if [ -n "$USER_ID" ] && [ "$ROLE_ASSIGNED" = "yes" ]; then
    IDENTITY_OK=1
    ok "Confirmed: user+role created via west are fully visible via east - one shared Keycloak realm/database across both regions."
  else
    fail "User/role created during the outage were not found (or not fully assigned) via east - Identity/Keycloak may not genuinely be sharing state."
  fi
else
  fail "Could not obtain a Keycloak admin token via east - skipping identity architecture check."
fi
pf_stop "$PF"
unset KC_ADMIN_PASS KC_TOKEN USER_ID ROLE_ASSIGNED

echo
if [ "$EAST_COUNT" -eq "$COUNT" ] && [ "$WEST_COUNT" -eq "$COUNT" ] && [ "$EAST_ACTIVE" -eq "$ACTIVE_COUNT" ] && [ "$WEST_ACTIVE" -eq "$ACTIVE_COUNT" ] && [ "$EAST_PASSIVE_UP" -gt 0 ] && [ "$WEST_PASSIVE_DOWN" -eq 0 ] && [ "$ENGINE_OK" -eq 1 ] && [ "$IDENTITY_OK" -eq 1 ]; then
  ok "TEST D PASSED: all $COUNT instances (completed + still-active) present in both regions, and roles correctly restored (east active, west passive)."
  echo
  echo "${C_BOLD}${C_GREEN}Summary: full region loss (Zeebe + Elasticsearch + active-passive components${C_RESET}"
  echo "${C_BOLD}${C_GREEN}together) - the hardest scenario. Recovery required combining Test A's Zeebe${C_RESET}"
  echo "${C_BOLD}${C_GREEN}RF4 fresh-bootstrap lesson with Test B's snapshot/restore and exporter-bug${C_RESET}"
  echo "${C_BOLD}${C_GREEN}lessons, plus promoting the secondary site and re-promoting the primary once${C_RESET}"
  echo "${C_BOLD}${C_GREEN}it recovered - all without ever wiping the survivor's storage.${C_RESET}"
else
  fail "TEST D FAILED: instance counts, active-state, or component roles do not match expectations. See tables above."
  exit 1
fi
