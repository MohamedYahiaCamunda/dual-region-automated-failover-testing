#!/usr/bin/env bash
# Shared helpers for the dual-region failover/failback test scripts.
# Source this from every step script: source "$(dirname "$0")/../lib/common.sh"

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$LIB_DIR/.." && pwd)"
STATE_DIR="$SCRIPTS_DIR/.state"
mkdir -p "$STATE_DIR"

# --- Environment ---
# Update these to match your own clusters, or override any of them via
# environment variable before running a script (e.g. AUTH_PASS=... ./scripts/test/00-baseline.sh).
CONTEXT_EAST="${CONTEXT_EAST:-camunda-dr-east}"
NS_EAST="${NS_EAST:-camunda-dr-east-ns}"
CONTEXT_WEST="${CONTEXT_WEST:-camunda-dr-west}"
NS_WEST="${NS_WEST:-camunda-dr-west-ns}"

AUTH_USER="${AUTH_USER:-your-basic-auth-username}"
AUTH_PASS="${AUTH_PASS:-your-basic-auth-password}"
PROCESS_ID=dr-test-process
BPMN_FILE="$SCRIPTS_DIR/assets/test-process.bpmn"
JOB_TYPE=dr-test-job

# MinIO's root credentials. This project's Elasticsearch keystore ties its S3
# "camunda" client to whatever S3_ACCESS_KEY/S3_SECRET_KEY lives in the
# elasticsearch-env-secret Secret (baked in at pod-init time and not
# changeable without restarting Elasticsearch), so MinIO's own credentials
# are read from that same Secret at runtime rather than hardcoded, keeping
# the two in sync automatically. Falls back to environment variables (or the
# placeholders below) only if that Secret isn't present.
MINIO_ACCESS_KEY=$(oc --context "$CONTEXT_EAST" -n "$NS_EAST" get secret elasticsearch-env-secret -o jsonpath='{.data.S3_ACCESS_KEY}' 2>/dev/null | base64 -d)
MINIO_SECRET_KEY=$(oc --context "$CONTEXT_EAST" -n "$NS_EAST" get secret elasticsearch-env-secret -o jsonpath='{.data.S3_SECRET_KEY}' 2>/dev/null | base64 -d)
if [ -z "$MINIO_ACCESS_KEY" ] || [ -z "$MINIO_SECRET_KEY" ]; then
  MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-your-minio-access-key}"
  MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-your-minio-secret-key}"
fi
MINIO_BUCKET=camunda-dr-backup
BACKUP_REPO=camunda_backup

# East node IDs: 0,2,4,6 (pods zeebe-0..3). West node IDs: 1,3,5,7 (pods zeebe-0..3).

# is_active_region CTX NS -> 0 (true) if this region currently has the
# active-passive components running (promoted), 1 (false) otherwise. Checked
# via the camunda-connectors Deployment's replica count. Identity/Keycloak/
# Optimize run active-active in both regions permanently (see
# helm-overlays/east-values.yaml's identityKeycloak comment), so their
# presence does not distinguish active from passive. Connectors is the only
# genuinely active-passive component, making it the only reliable signal.
is_active_region() {
  local replicas
  replicas=$(oc --context "$1" -n "$2" get deployment camunda-connectors -o jsonpath='{.spec.replicas}' 2>/dev/null)
  [ -n "$replicas" ] && [ "$replicas" -gt 0 ]
}

# active_region_name -> "east" or "west", whichever currently has
# camunda-connectors scaled up. Falls back to "east" (with a warning) if
# neither does, since callers need a single region to act against.
active_region_name() {
  if is_active_region "$CONTEXT_EAST" "$NS_EAST"; then
    echo east
  elif is_active_region "$CONTEXT_WEST" "$NS_WEST"; then
    echo west
  else
    warn "Neither region shows active-passive components running - defaulting to east." >&2
    echo east
  fi
}

# --- Colors / output helpers ---
# Deliberately avoids the ANSI "dim" attribute (\033[2m) - terminals render it
# very inconsistently (many shift the hue toward brown/red instead of just
# darkening it, which looks like an error against light-background themes).
# Every color below is a plain bold foreground color instead, which renders
# consistently across light and dark themes.
#
# Set DR_NO_COLOR=1 (or the standard NO_COLOR env var, see no-color.org) to
# disable all color output if it still clashes with your terminal theme.
if [ -n "${DR_NO_COLOR:-}" ] || [ -n "${NO_COLOR:-}" ]; then
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_MAGENTA=""
else
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
  # Command-echo color (show_cmd/run_cmd): a pale whitish-yellow (256-color
  # cornsilk, 230) instead of magenta/pink - reads as "informational command
  # trace" rather than a warning or error color.
  C_MAGENTA=$'\033[38;5;230m'
fi

hr() { printf '%s\n' "──────────────────────────────────────────────────────────────────────"; }

header() {
  echo
  echo "${C_BOLD}${C_CYAN}=== $1 ===${C_RESET}"
  hr
}

info() { echo "${C_CYAN}ℹ${C_RESET}  $1"; }
ok()   { echo "${C_GREEN}✔${C_RESET}  $1"; }
fail() { echo "${C_RED}✘${C_RESET}  $1"; }
warn() { echo "${C_YELLOW}⚠${C_RESET}  $1"; }

table() { python3 "$LIB_DIR/table.py"; }

next_step() {
  echo
  echo "${C_BOLD}Next:${C_RESET} $1"
  echo
}

# progress_bar CURRENT TOTAL LABEL -> draws/redraws an in-place terminal
# progress bar (via \r, no scrolling spam) for a poll loop with a known
# iteration cap. Always writes to stderr, same rationale as show_cmd - must
# still appear even when a caller redirects stdout, and never gets captured
# into a $(...) substitution. Call once per iteration; reaching CURRENT=TOTAL
# prints a trailing newline so subsequent output starts on its own line.
progress_bar() {
  local current="$1" total="$2" label="$3" width=30 filled empty bar_filled bar_empty
  [ "$total" -le 0 ] && total=1
  filled=$(( current * width / total ))
  [ "$filled" -gt "$width" ] && filled=$width
  [ "$filled" -lt 0 ] && filled=0
  empty=$((width - filled))
  bar_filled=$(printf '%*s' "$filled" '' | tr ' ' '#')
  bar_empty=$(printf '%*s' "$empty" '' | tr ' ' '.')
  printf '\r%s [%s%s%s%s] %d/%d  ' "$label" "$C_GREEN" "$bar_filled" "$C_RESET" "$bar_empty" "$current" "$total" >&2
  if [ "$current" -ge "$total" ]; then printf '\n' >&2; fi
}

confirm_destructive() {
  local msg="$1"
  echo
  echo "${C_YELLOW}${C_BOLD}⚠  DESTRUCTIVE ACTION${C_RESET}: $msg"
  read -r -p "Type YES to proceed, anything else to abort: " REPLY
  if [ "$REPLY" != "YES" ]; then
    fail "Aborted by user. No changes made."
    exit 1
  fi
}

# --- Educational command echoing ---
# Every real oc/curl command run by these scripts is printed before it runs,
# so you can see (and later run yourself) the exact underlying command - not
# just a friendly description of what happened. Always printed to STDERR so
# it (a) still shows up even when a caller redirects stdout to /dev/null, and
# (b) never gets swallowed into a $(...) command-substitution capture.

# show_cmd "the command string as you'd type it" -> prints it, does not run it
show_cmd() {
  echo "${C_BOLD}${C_MAGENTA}\$ $1${C_RESET}" >&2
}

# run_cmd CMD ARGS... -> prints the command, then actually executes it via "$@"
run_cmd() {
  echo "${C_BOLD}${C_MAGENTA}\$ $*${C_RESET}" >&2
  "$@"
}

# --- Port-forward helpers ---
# pf_start CONTEXT NAMESPACE TARGET LOCAL_PORT REMOTE_PORT -> echoes PID
# Rapid reuse of the same fixed local ports across many script invocations
# in one session can race against OS socket cleanup (or a prior script that
# was interrupted before its own pf_stop ran), producing "address already in
# use" - oc's port-forward then exits immediately, but a blind fixed sleep
# has no way to tell that apart from "still starting up", so curl silently
# hits a dead tunnel ("could not parse ... unreachable"). This verifies the
# tunnel actually came up (process still alive AND oc's own "Forwarding
# from" success line present in its log) before trusting it, defensively
# clears anything already bound to the port first, and retries a few times.
pf_start() {
  local ctx="$1" ns="$2" target="$3" lport="$4" rport="$5" pid attempt
  show_cmd "oc --context $ctx -n $ns port-forward $target $lport:$rport"
  for attempt in 1 2 3; do
    lsof -ti "tcp:$lport" -sTCP:LISTEN 2>/dev/null | xargs -r kill -9 2>/dev/null || true
    oc --context "$ctx" -n "$ns" port-forward "$target" "$lport:$rport" > "/tmp/dr_pf_${lport}.log" 2>&1 &
    pid=$!
    sleep 3
    if kill -0 "$pid" 2>/dev/null && grep -q "Forwarding from" "/tmp/dr_pf_${lport}.log" 2>/dev/null; then
      echo "$pid"
      return 0
    fi
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" 2>/dev/null || true
    sleep 1
  done
  echo "$pid"
}

pf_stop() {
  local pid="$1"
  # NOTE: pf_start is always invoked as `PID=$(pf_start ...)`, and command
  # substitution always forks a subshell - the backgrounded `oc port-forward &`
  # process is created INSIDE that subshell, so it is not a direct child of
  # THIS shell once the subshell exits. `wait "$pid"` on a PID that isn't a
  # tracked child of the current shell fails with "not a child of this shell"
  # (exit 127) - intermittently, depending on bash's internal job-table
  # timing. Under `set -e` (used by every step script), that 127 silently
  # kills the entire script with no error message. Both commands below MUST
  # have their own `|| true` - relying on a trailing `true` as the function's
  # last line does NOT protect earlier lines from aborting the script first.
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" 2>/dev/null || true
  return 0
}

# --- State persistence (so later steps can read what earlier steps created) ---
# state_file NAME -> path to scripts/.state/NAME.env
state_file() { echo "$STATE_DIR/$1.env"; }

# state_set FILE KEY VALUE
state_set() {
  local file="$1" key="$2" value="$3"
  touch "$file"
  grep -v "^${key}=" "$file" > "${file}.tmp" 2>/dev/null || true
  mv "${file}.tmp" "$file"
  echo "${key}=\"${value}\"" >> "$file"
}

# state_load FILE -> sources it into the current shell (no-op if missing)
state_load() {
  local file="$1"
  if [ -f "$file" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$file"
    set +a
  fi
}

require_state() {
  local varname="$1" step_hint="$2"
  if [ -z "${!varname:-}" ]; then
    fail "Missing state variable '$varname'. Run '$step_hint' first."
    exit 1
  fi
}

# --- Camunda REST API helpers (port 8080) ---
deploy_process() {
  local pf_pid resp
  pf_pid=$(pf_start "$CONTEXT_EAST" "$NS_EAST" pod/camunda-zeebe-0 18080 8080)
  show_cmd "curl -s -u $AUTH_USER:$AUTH_PASS -X POST http://localhost:18080/v2/deployments -F resources=@${BPMN_FILE}"
  resp=$(curl -s -u "$AUTH_USER:$AUTH_PASS" -X POST http://localhost:18080/v2/deployments -F "resources=@${BPMN_FILE}")
  pf_stop "$pf_pid"
  echo "$resp"
}

# create_instance CONTEXT NS BATCH SEQ -> echoes the processInstanceKey
# Routes through whichever region's gateway is passed in - during an outage
# that must be the surviving region, not always east.
create_instance() {
  local ctx="$1" ns="$2" batch="$3" seq="$4" pf_pid resp
  pf_pid=$(pf_start "$ctx" "$ns" pod/camunda-zeebe-0 18080 8080)
  show_cmd "curl -s -X POST http://localhost:18080/v2/process-instances -u $AUTH_USER:*** -H 'Content-Type: application/json' -d '{\"processDefinitionId\":\"$PROCESS_ID\",\"variables\":{\"batch\":\"$batch\",\"seq\":$seq}}'"
  resp=$(curl -s -X POST http://localhost:18080/v2/process-instances \
    -u "$AUTH_USER:$AUTH_PASS" -H 'Content-Type: application/json' \
    -d "{\"processDefinitionId\":\"$PROCESS_ID\",\"variables\":{\"batch\":\"$batch\",\"seq\":$seq}}")
  pf_stop "$pf_pid"
  local key
  key=$(python3 -c "
import json,sys
try:
    k = json.loads(sys.argv[1]).get('processInstanceKey','')
except Exception:
    k = ''
print(k)
" "$resp")
  if [ -z "$key" ]; then
    fail "create_instance failed (batch=$batch seq=$seq) - raw response: $resp" >&2
    return 1
  fi
  echo "$key"
}

# complete_job_for_instance CONTEXT NS TARGET_KEY -> activates a batch of
# pending $JOB_TYPE jobs and completes ONLY the one belonging to
# TARGET_KEY's process instance. Plain FIFO activation (grab 1, complete it)
# is unsafe on this shared, never-wiped cluster: other tests deliberately
# leave ACTIVE instances behind with their job still pending, so a bare
# "activate 1" can grab one of those leftovers instead of the instance we
# just created. Activating a wider batch and matching by processInstanceKey
# sidesteps that entirely. Any non-matching jobs activated here are simply
# left alone - Zeebe returns them to pending once their activation timeout
# (10s) elapses, so this cannot strand or lose them.
complete_job_for_instance() {
  local ctx="$1" ns="$2" target_key="$3" pf_pid resp job_key
  pf_pid=$(pf_start "$ctx" "$ns" pod/camunda-zeebe-0 18080 8080)
  show_cmd "curl -s -X POST http://localhost:18080/v2/jobs/activation -u $AUTH_USER:*** -H 'Content-Type: application/json' -d '{\"type\":\"$JOB_TYPE\",\"maxJobsToActivate\":50,\"worker\":\"dr-test-runner\",\"timeout\":10000}'"
  resp=$(curl -s -X POST http://localhost:18080/v2/jobs/activation \
    -u "$AUTH_USER:$AUTH_PASS" -H 'Content-Type: application/json' \
    -d "{\"type\":\"$JOB_TYPE\",\"maxJobsToActivate\":50,\"worker\":\"dr-test-runner\",\"timeout\":10000}")
  job_key=$(python3 -c "
import json,sys
try:
    jobs = json.loads(sys.argv[1]).get('jobs', [])
    target = int(sys.argv[2])
    match = next((j for j in jobs if int(j.get('processInstanceKey', -1)) == target), None)
    print(match['jobKey'] if match else '')
except Exception:
    print('')
" "$resp" "$target_key")
  if [ -z "$job_key" ]; then
    pf_stop "$pf_pid"
    fail "complete_job_for_instance: no job activated for processInstanceKey=$target_key - raw response: $resp" >&2
    return 1
  fi
  show_cmd "curl -s -X POST http://localhost:18080/v2/jobs/$job_key/completion -u $AUTH_USER:*** -H 'Content-Type: application/json' -d '{}'"
  curl -s -X POST "http://localhost:18080/v2/jobs/$job_key/completion" \
    -u "$AUTH_USER:$AUTH_PASS" -H 'Content-Type: application/json' -d '{}' > /dev/null
  pf_stop "$pf_pid"
}

# create_completed_instance CONTEXT NS BATCH SEQ -> creates an instance and
# immediately completes it, echoes the processInstanceKey
create_completed_instance() {
  local ctx="$1" ns="$2" batch="$3" seq="$4" key
  key=$(create_instance "$ctx" "$ns" "$batch" "$seq") || return 1
  complete_job_for_instance "$ctx" "$ns" "$key" || return 1
  echo "$key"
}

# --- Elasticsearch helpers ---
# NOTE: query against operate-list-view-8.3.0_* (wildcard), not the exact base
# index name. Camunda's archiver moves COMPLETED instances out of the base
# "operate-list-view-8.3.0_" index into date-suffixed indices (e.g.
# "operate-list-view-8.3.0_2026-07-09") once their wait-period elapses
# (~1h by default). Querying the exact base name only finds not-yet-archived
# instances - anything archived during a long pause between steps would
# silently disappear from the count otherwise. The wildcard covers both.
ES_INDEX_PATTERN="operate-list-view-8.3.0_*"

# es_query_count CONTEXT NAMESPACE LOCAL_PORT "key1,key2,..." -> echoes matched count
es_query_count() {
  local ctx="$1" ns="$2" lport="$3" keys_csv="$4" pf_pid body
  pf_pid=$(pf_start "$ctx" "$ns" svc/camunda-elasticsearch "$lport" 9200)
  show_cmd "curl -s http://localhost:${lport}/${ES_INDEX_PATTERN}/_search -H 'Content-Type: application/json' -d '{\"query\":{\"bool\":{\"must\":[{\"terms\":{\"processInstanceKey\":[${keys_csv}]}}],\"filter\":[{\"exists\":{\"field\":\"state\"}}]}},\"size\":0}'"
  body=$(curl -s "http://localhost:${lport}/${ES_INDEX_PATTERN}/_search" -H 'Content-Type: application/json' -d "{
    \"query\": {\"bool\": {\"must\": [{\"terms\": {\"processInstanceKey\": [${keys_csv}]}}], \"filter\": [{\"exists\": {\"field\": \"state\"}}]}},
    \"size\": 0
  }")
  pf_stop "$pf_pid"
  python3 -c "
import json,sys
try:
    print(json.loads(sys.argv[1])['hits']['total']['value'])
except Exception:
    print(0)
" "$body"
}

# es_query_count_by_state CONTEXT NAMESPACE LOCAL_PORT "key1,key2,..." STATE
# -> echoes count of matched instance-level records in the EXACT given state
# ("COMPLETED" or "ACTIVE") - used to distinguish completed instances from
# genuinely in-flight ones, which only live in Zeebe's own replicated state
# until they finish (proving Raft/PVC replication, not just ES export).
es_query_count_by_state() {
  local ctx="$1" ns="$2" lport="$3" keys_csv="$4" state="$5" pf_pid body
  pf_pid=$(pf_start "$ctx" "$ns" svc/camunda-elasticsearch "$lport" 9200)
  show_cmd "curl -s http://localhost:${lport}/${ES_INDEX_PATTERN}/_search -H 'Content-Type: application/json' -d '{\"query\":{\"bool\":{\"must\":[{\"terms\":{\"processInstanceKey\":[${keys_csv}]}},{\"term\":{\"state\":\"${state}\"}}],\"filter\":[{\"term\":{\"joinRelation\":\"processInstance\"}}]}},\"size\":0}'"
  body=$(curl -s "http://localhost:${lport}/${ES_INDEX_PATTERN}/_search" -H 'Content-Type: application/json' -d "{
    \"query\": {\"bool\": {\"must\": [{\"terms\": {\"processInstanceKey\": [${keys_csv}]}}, {\"term\": {\"state\": \"${state}\"}}], \"filter\": [{\"term\": {\"joinRelation\": \"processInstance\"}}]}},
    \"size\": 0
  }")
  pf_stop "$pf_pid"
  python3 -c "
import json,sys
try:
    print(json.loads(sys.argv[1])['hits']['total']['value'])
except Exception:
    print(0)
" "$body"
}

# es_total_count CONTEXT NAMESPACE LOCAL_PORT -> echoes the total document
# count across the whole index pattern (all process instances ever created,
# across every test run, not scoped to any particular set of keys).
# Informational only - deliberately NOT used in any pass/fail check, since
# each test suite verifies only the specific keys it itself created (see the
# comment on ES_INDEX_PATTERN above for why "total in index" and "matched for
# this test" are two different, both-correct numbers).
es_total_count() {
  local ctx="$1" ns="$2" lport="$3" pf_pid body
  pf_pid=$(pf_start "$ctx" "$ns" svc/camunda-elasticsearch "$lport" 9200)
  show_cmd "curl -s http://localhost:${lport}/${ES_INDEX_PATTERN}/_count -H 'Content-Type: application/json' -d '{\"query\":{\"exists\":{\"field\":\"state\"}}}'"
  body=$(curl -s "http://localhost:${lport}/${ES_INDEX_PATTERN}/_count" -H 'Content-Type: application/json' -d '{"query":{"exists":{"field":"state"}}}')
  pf_stop "$pf_pid"
  python3 -c "
import json,sys
try:
    print(json.loads(sys.argv[1])['count'])
except Exception:
    print(0)
" "$body"
}

# join_csv "k1 k2 k3" -> "k1,k2,k3"
join_csv() {
  echo "$1" | tr -s ' ' ',' | sed 's/^,//; s/,$//'
}

# --- Zeebe actuator helpers (port 9600) ---
get_partitions_json() {
  local ctx="$1" ns="$2" pod="$3" lport="$4" pf_pid body
  pf_pid=$(pf_start "$ctx" "$ns" "pod/$pod" "$lport" 9600)
  show_cmd "curl -s http://localhost:${lport}/actuator/partitions"
  body=$(curl -s "http://localhost:${lport}/actuator/partitions")
  pf_stop "$pf_pid"
  echo "$body"
}

get_exporters_json() {
  local ctx="$1" ns="$2" pod="$3" lport="$4" pf_pid body
  pf_pid=$(pf_start "$ctx" "$ns" "pod/$pod" "$lport" 9600)
  show_cmd "curl -s http://localhost:${lport}/actuator/exporters"
  body=$(curl -s "http://localhost:${lport}/actuator/exporters")
  pf_stop "$pf_pid"
  echo "$body"
}

get_readiness_json() {
  local ctx="$1" ns="$2" pod="$3" lport="$4" pf_pid body
  pf_pid=$(pf_start "$ctx" "$ns" "pod/$pod" "$lport" 9600)
  show_cmd "curl -s http://localhost:${lport}/actuator/health/readiness"
  body=$(curl -s "http://localhost:${lport}/actuator/health/readiness")
  pf_stop "$pf_pid"
  echo "$body"
}

get_cluster_json() {
  local ctx="$1" ns="$2" pod="$3" lport="$4" pf_pid body
  pf_pid=$(pf_start "$ctx" "$ns" "pod/$pod" "$lport" 9600)
  show_cmd "curl -s http://localhost:${lport}/actuator/cluster"
  body=$(curl -s "http://localhost:${lport}/actuator/cluster")
  pf_stop "$pf_pid"
  echo "$body"
}

# patch_cluster CONTEXT NS POD LPORT JSON_BODY FORCE(true/false)
patch_cluster() {
  local ctx="$1" ns="$2" pod="$3" lport="$4" body="$5" force="$6" pf_pid qs="" resp
  [ "$force" = "true" ] && qs="?force=true"
  pf_pid=$(pf_start "$ctx" "$ns" "pod/$pod" "$lport" 9600)
  show_cmd "curl -s -X PATCH http://localhost:${lport}/actuator/cluster${qs} -H 'Content-Type: application/json' -d '$body'"
  resp=$(curl -s -X PATCH "http://localhost:${lport}/actuator/cluster${qs}" -H 'Content-Type: application/json' -d "$body")
  pf_stop "$pf_pid"
  echo "$resp"
}

set_exporter() {
  local ctx="$1" ns="$2" pod="$3" lport="$4" exporter="$5" action="$6" pf_pid
  pf_pid=$(pf_start "$ctx" "$ns" "pod/$pod" "$lport" 9600)
  show_cmd "curl -s -X POST http://localhost:${lport}/actuator/exporters/${exporter}/${action}"
  curl -s -X POST "http://localhost:${lport}/actuator/exporters/${exporter}/${action}" > /dev/null
  pf_stop "$pf_pid"
}

# toggle_operate_tasklist CTX NS true|false
# Per the documented failback procedure's steps 2 and 8: "Deactivate Operate
# and Tasklist in the active region" before the ES backup/restore window (to
# avoid interference during it), then "Enable Operate and Tasklist in both
# the surviving and recreated regions" once exporting has resumed. In this
# chart version Operate/Tasklist are consolidated into the same orchestration
# pod as the Zeebe broker/gateway (not separate deployments) - the docs'
# own documented lever for this is exactly these two profile flags, applied
# via Helm, same as used elsewhere in promote-region.sh/demote-region.sh.
# Deliberately does NOT touch Identity/Keycloak/Optimize/Connectors - this is
# only the documented backup/restore safety pause, not this project's
# separate active-passive promote/demote convention for those components.
toggle_operate_tasklist() {
  local ctx="$1" ns="$2" enabled="$3" region
  [ "$ctx" = "$CONTEXT_EAST" ] && region="east" || region="west"
  local main_values="$SCRIPTS_DIR/../helm-overlays/${region}-values.yaml"
  local toggle_overlay="$SCRIPTS_DIR/../helm-overlays/operate-tasklist-off.yaml"
  [ "$enabled" = "true" ] && toggle_overlay="$SCRIPTS_DIR/../helm-overlays/operate-tasklist-on.yaml"

  run_cmd helm --kube-context "$ctx" -n "$ns" upgrade camunda camunda/camunda-platform \
    --version 13.11.1 \
    -f "$main_values" \
    -f "$SCRIPTS_DIR/../helm-overlays/active-overlay.yaml" \
    -f "$toggle_overlay" \
    -f "${USERS_VALUES:-$SCRIPTS_DIR/../helm-overlays/orchestration-users.yaml}" \
    --timeout 5m > /dev/null
}

# ensure_shared_keycloak_db_secret CTX NS
# Keycloak's Postgres is a single, standalone, always-on instance shared by
# BOTH regions (see helm-overlays/east-values.yaml's identityKeycloak.
# externalDatabase comment - "keycloak-postgres", a Helm release of its own,
# living permanently in east). Unlike every other per-region-independent DB
# password this project generates, the three secret keys that authenticate
# against THAT one database - identity-keycloak-admin-password,
# identity-keycloak-postgresql-admin-password, identity-keycloak-postgresql-
# user-password - MUST be byte-identical in both regions' camunda-credentials
# secrets, or whichever region connects second will either fail to reach the
# DB (wrong DB password) or fail its own later Keycloak-admin-API calls in
# promote-region.sh/promote-region.sh (wrong app-admin password). Naively
# generating any of these independently per region (the way every other
# per-region key here is handled) would silently desync them the next time
# either region rebuilds this secret from scratch. This function keeps them
# in sync no matter which region is missing a key:
#   - already present in CTX/NS -> leave alone
#   - missing in CTX/NS but present in the other region -> copy it over
#   - missing in both -> generate once, write the same value to both regions
ensure_shared_keycloak_db_secret() {
  local ctx="$1" ns="$2" other_ctx other_ns
  if [ "$ctx" = "$CONTEXT_EAST" ]; then
    other_ctx="$CONTEXT_WEST"; other_ns="$NS_WEST"
  else
    other_ctx="$CONTEXT_EAST"; other_ns="$NS_EAST"
  fi

  gen() { openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20; }

  local key existing other_value new_b64
  for key in identity-keycloak-admin-password \
             identity-keycloak-postgresql-admin-password \
             identity-keycloak-postgresql-user-password; do
    existing=$(oc --context "$ctx" -n "$ns" get secret camunda-credentials -o jsonpath="{.data.$key}" 2>/dev/null)
    if [ -n "$existing" ]; then
      info "'$key' already present - skipping (must stay in sync with the other region - shared Keycloak Postgres)."
      continue
    fi

    other_value=$(oc --context "$other_ctx" -n "$other_ns" get secret camunda-credentials -o jsonpath="{.data.$key}" 2>/dev/null)
    if [ -n "$other_value" ]; then
      show_cmd "oc --context $ctx -n $ns patch secret camunda-credentials --type=merge -p={data:{$key:<copied-from-other-region>}}"
      oc --context "$ctx" -n "$ns" patch secret camunda-credentials --type=merge \
        -p="{\"data\":{\"$key\":\"$other_value\"}}" > /dev/null
      ok "'$key' copied from the other region (shared Keycloak Postgres - values must match)."
    else
      new_b64=$(echo -n "$(gen)" | base64)
      show_cmd "oc --context $ctx -n $ns patch secret camunda-credentials --type=merge -p={data:{$key:<generated>}} (mirrored to both regions)"
      oc --context "$ctx" -n "$ns" patch secret camunda-credentials --type=merge \
        -p="{\"data\":{\"$key\":\"$new_b64\"}}" > /dev/null
      oc --context "$other_ctx" -n "$other_ns" patch secret camunda-credentials --type=merge \
        -p="{\"data\":{\"$key\":\"$new_b64\"}}" > /dev/null
      ok "'$key' generated fresh and set identically in both regions (shared Keycloak Postgres)."
    fi
  done
}

# enable_exporter_init CONTEXT NS POD LPORT EXPORTER_ID INIT_FROM_EXPORTER_ID
# Per the documented dual-region procedure, a recreated region's exporter
# should be (re-)enabled with `initializeFrom` pointing at the already-running
# exporter, so it bootstraps its position instead of resuming from an
# undefined one. This is a different, more specific request body than a bare
# enable - used ONCE to bring a freshly-restored region's exporter back, not
# for repeated disable/enable toggling of an exporter that never lost its
# target.
enable_exporter_init() {
  local ctx="$1" ns="$2" pod="$3" lport="$4" exporter="$5" init_from="$6" pf_pid body
  pf_pid=$(pf_start "$ctx" "$ns" "pod/$pod" "$lport" 9600)
  body="{\"initializeFrom\":\"${init_from}\"}"
  show_cmd "curl -s -X POST http://localhost:${lport}/actuator/exporters/${exporter}/enable -H 'Content-Type: application/json' -d '$body'"
  curl -s -X POST "http://localhost:${lport}/actuator/exporters/${exporter}/enable" -H 'Content-Type: application/json' -d "$body" > /dev/null
  pf_stop "$pf_pid"
}

# pause_exporting / resume_exporting CONTEXT NS POD LPORT -> echoes an
# effective status code (204 on success)
# This is a GLOBAL, SYNCHRONOUS control separate from per-exporter enable/
# disable - it's what the documented procedure actually uses to freeze all
# exporters for a consistent snapshot window. The documented API returns a
# bare 204 No Content, but this Camunda version's actuator wraps it: the
# outer HTTP status is 200, with a JSON body of {"body":null,"status":204,...}
# carrying the real result. Both helpers below check the embedded "status"
# field, not the outer HTTP code, so a genuine failure (which would show a
# different embedded status, or no valid JSON at all) is still caught.
pause_exporting() {
  local ctx="$1" ns="$2" pod="$3" lport="$4" pf_pid body
  pf_pid=$(pf_start "$ctx" "$ns" "pod/$pod" "$lport" 9600)
  show_cmd "curl -s -X POST http://localhost:${lport}/actuator/exporting/pause"
  body=$(curl -s -X POST "http://localhost:${lport}/actuator/exporting/pause")
  pf_stop "$pf_pid"
  echo "$body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null || echo "?"
}

resume_exporting() {
  local ctx="$1" ns="$2" pod="$3" lport="$4" pf_pid body
  pf_pid=$(pf_start "$ctx" "$ns" "pod/$pod" "$lport" 9600)
  show_cmd "curl -s -X POST http://localhost:${lport}/actuator/exporting/resume"
  body=$(curl -s -X POST "http://localhost:${lport}/actuator/exporting/resume")
  pf_stop "$pf_pid"
  echo "$body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null || echo "?"
}

# wait_for_zeebe_pods CONTEXT NS COUNT -> blocks (up to ~3min) until COUNT pods are 1/1
# The bar's fill tracks the REAL metric (ready/count), not the polling
# iteration - otherwise it visibly advances even when nothing has actually
# changed yet, which is misleading. The "attempt i/12" in the label is the
# separate heartbeat signal that proves it's still alive and re-querying
# every 15s, even during stretches where ready count hasn't moved.
wait_for_zeebe_pods() {
  local ctx="$1" ns="$2" count="$3" i ready
  show_cmd "oc --context $ctx -n $ns get pods --no-headers   (polling every 15s for camunda-zeebe-* pods to reach 1/1)"
  for i in $(seq 1 12); do
    ready=$(oc --context "$ctx" -n "$ns" get pods --no-headers 2>/dev/null | grep "camunda-zeebe-" | grep -c "1/1" || true)
    progress_bar "$ready" "$count" "Waiting for Zeebe pods ready (attempt $i/12)"
    if [ "$ready" -eq "$count" ]; then
      return 0
    fi
    sleep 15
  done
  return 1
}

wait_for_zero_zeebe_pods() {
  local ctx="$1" ns="$2" i remaining initial=0
  show_cmd "oc --context $ctx -n $ns get pods --no-headers   (polling every 5s for camunda-zeebe-* pods to reach 0)"
  initial=$(oc --context "$ctx" -n "$ns" get pods --no-headers 2>/dev/null | grep -c "camunda-zeebe-" || true)
  [ "$initial" -eq 0 ] && initial=1
  for i in $(seq 1 12); do
    remaining=$(oc --context "$ctx" -n "$ns" get pods --no-headers 2>/dev/null | grep -c "camunda-zeebe-" || true)
    progress_bar "$((initial - remaining))" "$initial" "Waiting for Zeebe pods to terminate ($remaining left, attempt $i/12)"
    if [ "$remaining" -eq 0 ]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

# wait_for_pod_pattern_count CONTEXT NS GREP_PATTERN TARGET_COUNT MAX_POLLS SLEEP_SECS LABEL
# Generic version of the two helpers above, for anything matched by a grep
# pattern other than "camunda-zeebe-" (e.g. "camunda-elasticsearch-master-").
# Counts pods showing "1/1" for that pattern; pass TARGET_COUNT=0 to instead
# wait for the pattern to disappear entirely (any status). The bar tracks the
# real ready/target (or terminated/initial) fraction - the attempt counter in
# the label is the separate proof-of-life signal between polls.
wait_for_pod_pattern_count() {
  local ctx="$1" ns="$2" pattern="$3" target="$4" max_polls="$5" sleep_secs="$6" label="$7" i count denom
  if [ "$target" -eq 0 ]; then
    denom=$(oc --context "$ctx" -n "$ns" get pods --no-headers 2>/dev/null | grep -c "$pattern" || true)
    [ "$denom" -eq 0 ] && denom=1
  else
    denom="$target"
  fi
  for i in $(seq 1 "$max_polls"); do
    if [ "$target" -eq 0 ]; then
      count=$(oc --context "$ctx" -n "$ns" get pods --no-headers 2>/dev/null | grep -c "$pattern" || true)
      progress_bar "$((denom - count))" "$denom" "$label ($count remaining, attempt $i/$max_polls)"
    else
      count=$(oc --context "$ctx" -n "$ns" get pods --no-headers 2>/dev/null | grep "$pattern" | grep -c "1/1" || true)
      progress_bar "$count" "$denom" "$label ($count/$target now, attempt $i/$max_polls)"
    fi
    if [ "$count" -eq "$target" ]; then
      return 0
    fi
    sleep "$sleep_secs"
  done
  return 1
}
