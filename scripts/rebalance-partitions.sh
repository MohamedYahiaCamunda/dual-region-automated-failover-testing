#!/usr/bin/env bash
# Actively influences partition leadership distribution, instead of just
# observing it (see leadership-distribution.sh for the read-only view).
#
# Uses Zeebe's documented POST /actuator/rebalance endpoint: it forces every
# partition leader to step down simultaneously, triggering fresh elections.
# With this cluster's defaults (round-robin partition distribution, priority
# election enabled - neither is overridden anywhere in helm-overlays/*.yaml),
# the new elections settle back toward the cluster's natural even
# distribution - which is exactly what you want after a failback, when
# leadership can otherwise sit "stuck" on whichever region was last active
# even though both regions' brokers are healthy again.
#
# Caveats (from Camunda's docs, not this script's own logic):
#   - Always returns 200 OK, even if rebalancing silently did nothing
#     (e.g. priority election disabled, or a follower too far behind to
#     safely take over) - that's why this script always re-queries and
#     prints the actual before/after distribution rather than trusting the
#     HTTP response.
#   - Briefly pauses command processing/exporting on every affected
#     partition while the re-election happens (same as any leader step-down).
#     Do not run this mid-load-test if you care about that short blip.
#
# Usage: ./rebalance-partitions.sh <east|west>
#   <east|west> selects which region's broker to route the POST through -
#   pick whichever region is actually reachable right now (during a
#   real/simulated region outage, that's only the surviving region; rebalance
#   is a cluster-wide operation, so it affects all 8 brokers either way).
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

REGION="${1:-}"
if [ "$REGION" != "east" ] && [ "$REGION" != "west" ]; then
  fail "Usage: $0 <east|west>"
  exit 1
fi

if [ "$REGION" = "east" ]; then
  CTX="$CONTEXT_EAST"; NS="$NS_EAST"; LPORT=19600
else
  CTX="$CONTEXT_WEST"; NS="$NS_WEST"; LPORT=19700
fi

header "REBALANCE PARTITION LEADERSHIP (routed via $REGION)"

info "Leadership distribution BEFORE rebalance:"
"$SCRIPTS_DIR/leadership-distribution.sh" || true
echo

info "Requesting rebalance (POST /actuator/rebalance via $REGION)..."
PF_PID=$(pf_start "$CTX" "$NS" pod/camunda-zeebe-0 "$LPORT" 9600)
show_cmd "curl -s -X POST http://localhost:${LPORT}/actuator/rebalance"
curl -s -X POST "http://localhost:${LPORT}/actuator/rebalance" > /dev/null
pf_stop "$PF_PID"
ok "Rebalance request accepted (this always returns 200 OK, even if a no-op - see script header)."

info "Waiting for re-elections to settle..."
sleep 10

echo
info "Leadership distribution AFTER rebalance:"
"$SCRIPTS_DIR/leadership-distribution.sh"
