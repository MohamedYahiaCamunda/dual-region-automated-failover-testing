#!/usr/bin/env bash
# Promotes a region to active. Identity, Keycloak, and Optimize run
# active-active in both regions permanently (see the identityKeycloak
# comment in helm-overlays/east-values.yaml), and Operate/Tasklist are
# permanently enabled in helm-overlays/test/{east,west}-values.yaml rather
# than toggled - so Connectors is the only component this promotion
# actually touches, a Deployment entirely separate from Zeebe's
# "orchestration" StatefulSet. Zeebe is never restarted by this script.
#
# Keycloak's Postgres is a single standalone, always-on "keycloak-postgres"
# release shared by both regions - its credentials are kept in sync via
# ensure_shared_keycloak_db_secret (see scripts/lib/common.sh).
#
# Usage: ./promote-region.sh <east|west>
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

REGION="${1:-}"
if [ "$REGION" != "east" ] && [ "$REGION" != "west" ]; then
  fail "Usage: $0 <east|west>"
  exit 1
fi

if [ "$REGION" = "east" ]; then
  CTX="$CONTEXT_EAST"; NS="$NS_EAST"
else
  CTX="$CONTEXT_WEST"; NS="$NS_WEST"
fi
MAIN_VALUES="$SCRIPTS_DIR/../helm-overlays/test/${REGION}-values.yaml"
OVERLAY_VALUES="$SCRIPTS_DIR/../helm-overlays/test/active-overlay.yaml"
USERS_VALUES="${USERS_VALUES:-$SCRIPTS_DIR/../helm-overlays/orchestration-users.yaml}"

header "PROMOTE $REGION TO ACTIVE (Connectors only - Zeebe/Operate/Tasklist/Identity/Keycloak/Optimize untouched)"

info "Ensuring the shared Keycloak Postgres credentials are in sync across both regions (identical in both, since there's only one Keycloak DB)..."
ensure_shared_keycloak_db_secret "$CTX" "$NS"

info "Ensuring every other per-region DB/admin password key the identity/webModeler sub-charts expect exists in camunda-credentials..."
gen() { openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20; }
for key in identity-postgresql-admin-password \
           identity-postgresql-user-password \
           web-modeler-postgresql-admin-password \
           web-modeler-postgresql-user-password \
           identity-migration-client-secret; do
  if ! oc --context "$CTX" -n "$NS" get secret camunda-credentials -o jsonpath="{.data.$key}" 2>/dev/null | grep -q .; then
    show_cmd "oc --context $CTX -n $NS patch secret camunda-credentials --type=merge -p={data:{$key:<generated>}}"
    oc --context "$CTX" -n "$NS" patch secret camunda-credentials --type=merge \
      -p="{\"data\":{\"$key\":\"$(echo -n "$(gen)" | base64)\"}}" > /dev/null
    ok "'$key' added."
  else
    info "'$key' already present - skipping."
  fi
done

info "Scaling up Connectors via a minimal, declarative helm upgrade (Identity/Keycloak/Optimize/Operate/Tasklist are already on, permanently, from test/${REGION}-values.yaml)..."
show_cmd "helm --kube-context $CTX -n $NS upgrade camunda camunda/camunda-platform --version 13.11.1 -f $MAIN_VALUES -f $OVERLAY_VALUES -f $USERS_VALUES --timeout 5m"

# Snapshot Zeebe pod ages before the upgrade, so we can prove afterward that
# none of them restarted.
ZEEBE_AGES_BEFORE=$(oc --context "$CTX" -n "$NS" get pods -l app.kubernetes.io/component=zeebe-broker -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.metadata.creationTimestamp}{" "}{end}' 2>/dev/null || true)

run_cmd helm --kube-context "$CTX" -n "$NS" upgrade camunda camunda/camunda-platform \
  --version 13.11.1 \
  -f "$MAIN_VALUES" \
  -f "$OVERLAY_VALUES" \
  -f "$USERS_VALUES" \
  --timeout 5m > /dev/null

info "Waiting for Connectors to scale up (Identity/Keycloak/Optimize don't need to - they're already active-active)..."
for i in $(seq 1 20); do
  NOT_READY=$(oc --context "$CTX" -n "$NS" get pods --no-headers 2>/dev/null | grep -vE "1/1|2/2" | grep -cE "camunda-connectors" || true)
  READY_COUNT=$(oc --context "$CTX" -n "$NS" get pods --no-headers 2>/dev/null | grep -cE "camunda-connectors" || true)
  READY_NOW=$((READY_COUNT - NOT_READY))
  DENOM=$READY_COUNT; [ "$DENOM" -eq 0 ] && DENOM=1
  progress_bar "$READY_NOW" "$DENOM" "Waiting for Connectors (attempt $i/20)"
  if [ "$NOT_READY" -eq 0 ] && [ "$READY_COUNT" -gt 0 ]; then
    break
  fi
  sleep 15
done

echo
oc --context "$CTX" -n "$NS" get pods 2>&1
echo

info "Verifying Zeebe was NOT restarted by this promotion..."
ZEEBE_AGES_AFTER=$(oc --context "$CTX" -n "$NS" get pods -l app.kubernetes.io/component=zeebe-broker -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.metadata.creationTimestamp}{" "}{end}' 2>/dev/null || true)
if [ "$ZEEBE_AGES_BEFORE" = "$ZEEBE_AGES_AFTER" ] && [ -n "$ZEEBE_AGES_BEFORE" ]; then
  ok "Confirmed: all Zeebe broker pod creation timestamps are unchanged - no restart occurred."
else
  warn "Zeebe pod creation timestamps changed across this promotion - investigate (this should never happen)."
  warn "Before: $ZEEBE_AGES_BEFORE"
  warn "After:  $ZEEBE_AGES_AFTER"
fi

# --- Everything below is Identity/Keycloak login provisioning - not
# expressible as Helm values at all (direct Keycloak admin REST API calls),
# so it stays exactly as-is: manual-style curl steps, per project convention. ---

info "Ensuring the Identity/Keycloak first-user login password key exists in camunda-credentials..."
if ! oc --context "$CTX" -n "$NS" get secret camunda-credentials -o jsonpath='{.data.identity-firstuser-password}' 2>/dev/null | grep -q .; then
  gen() { openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20; }
  show_cmd "oc --context $CTX -n $NS patch secret camunda-credentials --type=merge -p={data:{identity-firstuser-password:<generated>}}"
  oc --context "$CTX" -n "$NS" patch secret camunda-credentials --type=merge \
    -p="{\"data\":{\"identity-firstuser-password\":\"$(echo -n "$(gen)" | base64)\"}}" > /dev/null
  ok "Identity first-user password key added."
else
  info "Already present - skipping."
fi

WEBPORT=18080; [ "$REGION" = "west" ] && WEBPORT=18081
IDENTITY_PORT=$((WEBPORT + 200))
KEYCLOAK_PORT=$((WEBPORT + 300))

info "Ensuring a real login user ('venom') exists in the camunda-platform Keycloak realm..."
KC_ADMIN_PASS=$(oc --context "$CTX" -n "$NS" get secret camunda-credentials -o jsonpath='{.data.identity-keycloak-admin-password}' 2>/dev/null | base64 -d)
USER_PASS=$(oc --context "$CTX" -n "$NS" get secret camunda-credentials -o jsonpath='{.data.identity-firstuser-password}' 2>/dev/null | base64 -d)
PF=$(pf_start "$CTX" "$NS" svc/camunda-keycloak "$KEYCLOAK_PORT" 80)
show_cmd "curl -s -X POST http://localhost:${KEYCLOAK_PORT}/auth/realms/master/protocol/openid-connect/token -d client_id=admin-cli -d username=admin -d password=*** -d grant_type=password"
KC_TOKEN=$(curl -s -X POST "http://localhost:${KEYCLOAK_PORT}/auth/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "username=admin" -d "password=$KC_ADMIN_PASS" -d "grant_type=password" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
if [ -n "$KC_TOKEN" ]; then
  EXISTING_USER=$(curl -s "http://localhost:${KEYCLOAK_PORT}/auth/admin/realms/camunda-platform/users?username=venom" \
    -H "Authorization: Bearer $KC_TOKEN" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null)
  if [ -z "$EXISTING_USER" ]; then
    show_cmd "curl -s -X POST http://localhost:${KEYCLOAK_PORT}/auth/admin/realms/camunda-platform/users -d '{\"username\":\"venom\",...}'"
    curl -s -X POST "http://localhost:${KEYCLOAK_PORT}/auth/admin/realms/camunda-platform/users" \
      -H "Authorization: Bearer $KC_TOKEN" -H 'Content-Type: application/json' \
      -d '{"username":"venom","email":"venom@ci.local","firstName":"CI","lastName":"Admin","enabled":true,"emailVerified":true}' > /dev/null
    EXISTING_USER=$(curl -s "http://localhost:${KEYCLOAK_PORT}/auth/admin/realms/camunda-platform/users?username=venom" \
      -H "Authorization: Bearer $KC_TOKEN" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null)
    ok "Created 'venom' user in the camunda-platform realm."
  else
    info "'venom' user already exists in the camunda-platform realm - skipping creation."
  fi
  if [ -n "$EXISTING_USER" ]; then
    curl -s -X PUT "http://localhost:${KEYCLOAK_PORT}/auth/admin/realms/camunda-platform/users/${EXISTING_USER}/reset-password" \
      -H "Authorization: Bearer $KC_TOKEN" -H 'Content-Type: application/json' \
      -d "{\"type\":\"password\",\"value\":\"$USER_PASS\",\"temporary\":false}" > /dev/null
    ok "'venom' password set to match the identity-firstuser-password secret."

    info "Granting 'venom' the 'ManagementIdentity' realm role..."
    ROLE_JSON=$(curl -s "http://localhost:${KEYCLOAK_PORT}/auth/admin/realms/camunda-platform/roles/ManagementIdentity" \
      -H "Authorization: Bearer $KC_TOKEN")
    show_cmd "curl -s -X POST http://localhost:${KEYCLOAK_PORT}/auth/admin/realms/camunda-platform/users/${EXISTING_USER}/role-mappings/realm -d '[{\"name\":\"ManagementIdentity\",...}]'"
    curl -s -X POST "http://localhost:${KEYCLOAK_PORT}/auth/admin/realms/camunda-platform/users/${EXISTING_USER}/role-mappings/realm" \
      -H "Authorization: Bearer $KC_TOKEN" -H 'Content-Type: application/json' \
      -d "[$ROLE_JSON]" > /dev/null
    ok "'venom' granted the 'ManagementIdentity' role (idempotent)."
  else
    fail "Could not find or create the 'venom' user - check Keycloak manually."
  fi

  info "Patching the 'camunda-identity' Keycloak client's redirect URIs to match identity.fullURL..."
  CLIENT_UUID=$(curl -s "http://localhost:${KEYCLOAK_PORT}/auth/admin/realms/camunda-platform/clients?clientId=camunda-identity" \
    -H "Authorization: Bearer $KC_TOKEN" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null)
  if [ -n "$CLIENT_UUID" ]; then
    show_cmd "curl -s -X PUT http://localhost:${KEYCLOAK_PORT}/auth/admin/realms/camunda-platform/clients/$CLIENT_UUID -d '{\"rootUrl\":\"http://localhost:${IDENTITY_PORT}\",\"redirectUris\":[...]}'"
    curl -s -X PUT "http://localhost:${KEYCLOAK_PORT}/auth/admin/realms/camunda-platform/clients/${CLIENT_UUID}" \
      -H "Authorization: Bearer $KC_TOKEN" -H 'Content-Type: application/json' \
      -d "{\"rootUrl\":\"http://localhost:${IDENTITY_PORT}\",\"redirectUris\":[\"http://localhost:${IDENTITY_PORT}/auth/login-callback\"],\"webOrigins\":[\"+\"]}" > /dev/null
    ok "'camunda-identity' client redirect URIs updated to http://localhost:${IDENTITY_PORT}."
  else
    fail "Could not find the 'camunda-identity' Keycloak client."
  fi
else
  fail "Could not obtain a Keycloak admin token - skipping user/client provisioning."
fi
pf_stop "$PF"
unset KC_ADMIN_PASS USER_PASS KC_TOKEN CLIENT_UUID

ok "$REGION promoted to active."
