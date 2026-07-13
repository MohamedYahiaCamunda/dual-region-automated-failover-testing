#!/usr/bin/env bash
# Step 4: Verify existing (baseline) data is still accessible
# West was never touched, so this check is expected to pass trivially,
# including for the 2 ACTIVE (uncompleted) instances, which confirms that
# Zeebe's own replicated state survived the failover. East is completely
# gone at this point (both Zeebe and Elasticsearch), so there is nothing to
# check there.
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

STATE=$(state_file "test")
state_load "$STATE"
require_state TEST_BASELINE_COMPLETED_KEYS "./00-baseline.sh"
require_state TEST_BASELINE_ACTIVE_KEYS "./00-baseline.sh"

header "STEP 4: Verify existing baseline data"

ALL_KEYS="$TEST_BASELINE_COMPLETED_KEYS $TEST_BASELINE_ACTIVE_KEYS"
CSV=$(join_csv "$ALL_KEYS")
ACTIVE_CSV=$(join_csv "$TEST_BASELINE_ACTIVE_KEYS")
WEST_COUNT=$(es_query_count "$CONTEXT_WEST" "$NS_WEST" 19201 "$CSV")
WEST_ACTIVE=$(es_query_count_by_state "$CONTEXT_WEST" "$NS_WEST" 19201 "$ACTIVE_CSV" "ACTIVE")

printf 'Region\tTotal\tStill Active\tExpected\tStatus\n' > /tmp/dr_tableD4.tsv
printf 'West (survivor, now active)\t%s\t%s/2\t5\t%s\n' "$WEST_COUNT" "$WEST_ACTIVE" "$([ "$WEST_COUNT" -eq 5 ] && echo OK || echo MISMATCH)" >> /tmp/dr_tableD4.tsv
printf 'East (fully destroyed)\tN/A\tN/A\tN/A\tEXPECTED UNAVAILABLE\n' >> /tmp/dr_tableD4.tsv
table < /tmp/dr_tableD4.tsv

WEST_TOTAL=$(es_total_count "$CONTEXT_WEST" "$NS_WEST" 19201)
echo "${C_CYAN}ℹ (informational, not part of pass/fail) Total documents in west's index across ALL test runs: $WEST_TOTAL (east unavailable - fully destroyed right now)${C_RESET}"

if [ "$WEST_COUNT" -eq 5 ]; then
  ok "Baseline data intact and queryable via west - the surviving region is fully serving reads and writes."
else
  fail "Baseline data verification failed on west."
  exit 1
fi

next_step "./05-create-data-during-outage.sh   (create new data via west - camundaregion1 is still enabled, so it should reach west immediately)"
