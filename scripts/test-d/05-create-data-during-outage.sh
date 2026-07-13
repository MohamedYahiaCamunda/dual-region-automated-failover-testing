#!/usr/bin/env bash
# Test D - Step 5: Create new data during the outage
# camundaregion1 (west) was never disabled; only camundaregion0 (east) was
# disabled, in step 03. This data, created via west's gateway since east is
# fully down, is expected to reach west's Elasticsearch normally and
# immediately. Creates 2 COMPLETED and 1 left ACTIVE instance, the same
# completed/active mix used for the baseline. East is fully absent (both its
# Zeebe and its Elasticsearch are gone) and only catches up after the
# combined failback in step 06 (fresh Zeebe bootstrap, ES restore, and
# exporter initialization).
#
# Also creates a Keycloak user and role via west's Identity/Keycloak during
# this same outage window, as a concrete architecture check rather than a
# process-data check. Identity/Keycloak are active-active, with both regions
# pointed at the single, always-on "keycloak-postgres" instance (see the
# identityKeycloak comment in helm-overlays/test-d/east-values.yaml). Creating the
# user/role via west and confirming visibility via east after failback
# (08-verify-final.sh) demonstrates that both regions' Keycloak genuinely
# share one realm/database, rather than two independent instances that
# merely look alike.
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

STATE=$(state_file "test-d")
state_load "$STATE"

header "TEST D - STEP 5: Create data during the outage"

info "Creating 2 COMPLETED instances via west (batch=during-outage-testD)..."
COMPLETED_KEYS=""
for i in 1 2; do
  KEY=$(create_completed_instance "$CONTEXT_WEST" "$NS_WEST" "during-outage-testD" "$i")
  COMPLETED_KEYS="$COMPLETED_KEYS $KEY"
  echo "  completed instance $i: $KEY"
done
COMPLETED_KEYS=$(echo "$COMPLETED_KEYS" | xargs)
state_set "$STATE" "TESTD_DURING_COMPLETED_KEYS" "$COMPLETED_KEYS"

info "Creating 1 ACTIVE (uncompleted/in-flight) instance via west (batch=during-outage-testD)..."
KEY=$(create_instance "$CONTEXT_WEST" "$NS_WEST" "during-outage-testD" 3)
echo "  active (left running) instance 3: $KEY"
state_set "$STATE" "TESTD_DURING_ACTIVE_KEYS" "$KEY"

sleep 5
ALL_KEYS="$COMPLETED_KEYS $KEY"
CSV=$(join_csv "$ALL_KEYS")
ACTIVE_CSV=$(join_csv "$KEY")
WEST_COUNT=$(es_query_count "$CONTEXT_WEST" "$NS_WEST" 19201 "$CSV")
WEST_ACTIVE=$(es_query_count_by_state "$CONTEXT_WEST" "$NS_WEST" 19201 "$ACTIVE_CSV" "ACTIVE")

printf 'Check\tResult\n' > /tmp/dr_tableD5.tsv
printf 'New instances created\t3\n' >> /tmp/dr_tableD5.tsv
printf "Found in west's ES (camundaregion1 still enabled)\t%s / 3 (expect 3)\n" "$WEST_COUNT" >> /tmp/dr_tableD5.tsv
printf 'ACTIVE instance correctly shows ACTIVE\t%s / 1\n' "$WEST_ACTIVE" >> /tmp/dr_tableD5.tsv
table < /tmp/dr_tableD5.tsv

if [ "$WEST_COUNT" -eq 3 ]; then
  ok "CONFIRMED: west's visibility was never interrupted - only east's exporter was disabled, not the whole pipeline."
else
  warn "Expected 3 matches in west (camundaregion1 should still be exporting normally), got $WEST_COUNT - check exporter state before continuing."
fi

echo
info "Creating a Keycloak user + role via WEST's Identity/Keycloak (architecture check: proves both regions share one realm/database, not just process data)..."
TESTD_IDENTITY_USER="dr-failover-test-user"
TESTD_IDENTITY_ROLE="dr-failover-test-role"
state_set "$STATE" "TESTD_IDENTITY_USER" "$TESTD_IDENTITY_USER"
state_set "$STATE" "TESTD_IDENTITY_ROLE" "$TESTD_IDENTITY_ROLE"

KC_ADMIN_PASS=$(oc --context "$CONTEXT_WEST" -n "$NS_WEST" get secret camunda-credentials -o jsonpath='{.data.identity-keycloak-admin-password}' 2>/dev/null | base64 -d)
PF=$(pf_start "$CONTEXT_WEST" "$NS_WEST" svc/camunda-keycloak 18381 80)
KC_TOKEN=$(curl -s -X POST "http://localhost:18381/auth/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "username=admin" -d "password=$KC_ADMIN_PASS" -d "grant_type=password" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)

IDENTITY_OK=0
if [ -n "$KC_TOKEN" ]; then
  info "Creating role '$TESTD_IDENTITY_ROLE' in the camunda-platform realm (idempotent)..."
  curl -s -X POST "http://localhost:18381/auth/admin/realms/camunda-platform/roles" \
    -H "Authorization: Bearer $KC_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$TESTD_IDENTITY_ROLE\",\"description\":\"DR Test D - created during outage via west, verified after failback via east\"}" > /dev/null

  info "Creating user '$TESTD_IDENTITY_USER' in the camunda-platform realm (idempotent)..."
  EXISTING_USER=$(curl -s "http://localhost:18381/auth/admin/realms/camunda-platform/users?username=$TESTD_IDENTITY_USER" \
    -H "Authorization: Bearer $KC_TOKEN" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null)
  if [ -z "$EXISTING_USER" ]; then
    curl -s -X POST "http://localhost:18381/auth/admin/realms/camunda-platform/users" \
      -H "Authorization: Bearer $KC_TOKEN" -H 'Content-Type: application/json' \
      -d "{\"username\":\"$TESTD_IDENTITY_USER\",\"email\":\"${TESTD_IDENTITY_USER}@ci.local\",\"enabled\":true,\"emailVerified\":true}" > /dev/null
    EXISTING_USER=$(curl -s "http://localhost:18381/auth/admin/realms/camunda-platform/users?username=$TESTD_IDENTITY_USER" \
      -H "Authorization: Bearer $KC_TOKEN" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null)
  fi

  if [ -n "$EXISTING_USER" ]; then
    info "Assigning role '$TESTD_IDENTITY_ROLE' to '$TESTD_IDENTITY_USER'..."
    ROLE_JSON=$(curl -s "http://localhost:18381/auth/admin/realms/camunda-platform/roles/$TESTD_IDENTITY_ROLE" \
      -H "Authorization: Bearer $KC_TOKEN")
    curl -s -X POST "http://localhost:18381/auth/admin/realms/camunda-platform/users/${EXISTING_USER}/role-mappings/realm" \
      -H "Authorization: Bearer $KC_TOKEN" -H 'Content-Type: application/json' \
      -d "[$ROLE_JSON]" > /dev/null
    ok "User '$TESTD_IDENTITY_USER' created via west with role '$TESTD_IDENTITY_ROLE' - 08-verify-final.sh will confirm this survives failback, visible via east."
    IDENTITY_OK=1
  else
    fail "Could not find or create '$TESTD_IDENTITY_USER' - check west's Keycloak manually."
  fi
else
  fail "Could not obtain a Keycloak admin token via west - skipping user/role creation."
fi
pf_stop "$PF"
unset KC_ADMIN_PASS KC_TOKEN EXISTING_USER ROLE_JSON

if [ "$IDENTITY_OK" -ne 1 ]; then
  warn "Identity/Keycloak architecture check could not be set up this run - 08-verify-final.sh will report it missing."
fi

next_step "./06-failback.sh   (the full combined recovery: rebuild east, ES snapshot/restore, promote east, demote west)"
