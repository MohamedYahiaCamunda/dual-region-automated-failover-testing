#!/usr/bin/env bash
# Test D's own demote script - see promote-region-d.sh's header comment.
# Only touches Connectors now; Identity/Keycloak/Optimize/Operate/Tasklist
# and Zeebe are never touched, so Zeebe is never restarted by this script.
#
# Usage: ./demote-region-d.sh <east|west>
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
MAIN_VALUES="$SCRIPTS_DIR/../helm-overlays/test-d/${REGION}-values.yaml"
OVERLAY_VALUES="$SCRIPTS_DIR/../helm-overlays/test-d/passive-overlay.yaml"
USERS_VALUES="$SCRIPTS_DIR/../helm-overlays/orchestration-users.yaml"

header "TEST D: DEMOTE $REGION TO PASSIVE (Connectors only - Zeebe/Operate/Tasklist/Identity/Keycloak/Optimize untouched)"

ZEEBE_AGES_BEFORE=$(oc --context "$CTX" -n "$NS" get pods -l app.kubernetes.io/component=zeebe-broker -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.metadata.creationTimestamp}{" "}{end}' 2>/dev/null || true)

info "Scaling down Connectors via a minimal, declarative helm upgrade (Identity/Keycloak/Optimize/Operate/Tasklist stay on, permanently, per test-d/${REGION}-values.yaml)..."
show_cmd "helm --kube-context $CTX -n $NS upgrade camunda camunda/camunda-platform --version 13.11.1 -f $MAIN_VALUES -f $OVERLAY_VALUES -f $USERS_VALUES --timeout 5m"
run_cmd helm --kube-context "$CTX" -n "$NS" upgrade camunda camunda/camunda-platform \
  --version 13.11.1 \
  -f "$MAIN_VALUES" \
  -f "$OVERLAY_VALUES" \
  -f "$USERS_VALUES" \
  --timeout 5m > /dev/null

info "Waiting for Connectors to fully terminate (Identity/Keycloak/Optimize stay up)..."
INITIAL=$(oc --context "$CTX" -n "$NS" get pods --no-headers 2>/dev/null | grep -cE "camunda-connectors" || true)
[ "$INITIAL" -eq 0 ] && INITIAL=1
for i in $(seq 1 10); do
  REMAINING=$(oc --context "$CTX" -n "$NS" get pods --no-headers 2>/dev/null | grep -cE "camunda-connectors" || true)
  progress_bar "$((INITIAL - REMAINING))" "$INITIAL" "Waiting for Connectors to terminate ($REMAINING left, attempt $i/10)"
  if [ "$REMAINING" -eq 0 ]; then
    break
  fi
  sleep 10
done

echo
oc --context "$CTX" -n "$NS" get pods 2>&1
echo

info "Verifying Zeebe was NOT restarted by this demotion..."
ZEEBE_AGES_AFTER=$(oc --context "$CTX" -n "$NS" get pods -l app.kubernetes.io/component=zeebe-broker -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.metadata.creationTimestamp}{" "}{end}' 2>/dev/null || true)
if [ "$ZEEBE_AGES_BEFORE" = "$ZEEBE_AGES_AFTER" ] && [ -n "$ZEEBE_AGES_BEFORE" ]; then
  ok "Confirmed: all Zeebe broker pod creation timestamps are unchanged - no restart occurred."
else
  warn "Zeebe pod creation timestamps changed across this demotion - investigate (this should never happen in Test D)."
  warn "Before: $ZEEBE_AGES_BEFORE"
  warn "After:  $ZEEBE_AGES_AFTER"
fi

ok "$REGION demoted to passive (Test D). Zeebe/Elasticsearch/Operate/Tasklist/Identity/Keycloak/Optimize remain untouched."
