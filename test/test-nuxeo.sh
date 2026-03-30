#!/usr/bin/env bash
# test-nuxeo.sh — Nuxeo end-to-end test suite.
# Sections: health checks, D (batch ingestion), E (live ingestion),
#           F (security), G (permissions), H (chunking), I (scope).
#
# Requires STACK_MODE=nuxeo stack to be healthy and the nuxeo-deployment
# companion stack running at http://localhost:8081.
# Run via run-tests.sh or directly after the stack is up.
# Requires: curl, jq, python3.

set -uo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
NUXEO_BASE='http://localhost:8081/nuxeo/api/v1'
NUXEO_AUTH='Administrator:Administrator'
SYNC_URL='http://localhost/api/sync'
RAG_URL='http://localhost/api/rag'
NUXEO_INCLUDED_ROOT="${NUXEO_INCLUDED_ROOT:-/default-domain/workspaces/content-lake-demo}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_SCRIPT="$SCRIPT_DIR/../scripts/create-nuxeo-demo-file.sh"

PASS=0; FAIL=0
TMPDIR_DATA="$(mktemp -d)"
TEST_RUN_TAG="$(date +%Y%m%d-%H%M%S)-$$"
TEST_RUN_ALPHA_TAG="$(printf '%s' "$TEST_RUN_TAG" | tr '0123456789-' 'abcdefghijx')"
RAG_PRESENCE_TOPK="${RAG_PRESENCE_TOPK:-50}"
LOG="test-results-nuxeo-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
pass()    { printf "${G}[PASS]${N} %s\n" "$*"; PASS=$((PASS+1)); }
fail()    { printf "${R}[FAIL]${N} %s\n" "$*"; FAIL=$((FAIL+1)); }
info()    { printf "${C}[INFO]${N} %s\n" "$*"; }
section() { printf "\n${B}${C}─── %s ───${N}\n" "$*"; }
cleanup() { rm -rf "$TMPDIR_DATA"; }
trap cleanup EXIT

# ── Test helpers ──────────────────────────────────────────────────────────────

# run_nuxeo_sync_wait [trigger_tid] [complete_tid] [label]
# Triggers configured sync, waits up to 5 min for COMPLETED.
run_nuxeo_sync_wait() {
  local trigger_tid="${1:-D3}" complete_tid="${2:-D4}" label="${3:-Nuxeo sync}"
  local resp job_id status
  resp=$(curl -sf -u "$NUXEO_AUTH" -X POST "$SYNC_URL/configured" 2>/dev/null || echo '{}')
  job_id=$(echo "$resp" | jq -r '.jobId // empty')

  if [ -z "$job_id" ]; then
    fail "$trigger_tid: Sync trigger returned no jobId (response: $resp)"
    return 1
  fi
  pass "$trigger_tid: $label triggered — jobId=$job_id"

  local elapsed=0
  while [ $elapsed -lt 300 ]; do
    local sr
    sr=$(curl -sf -u "$NUXEO_AUTH" "$SYNC_URL/status/$job_id" 2>/dev/null || echo '{}')
    status=$(echo "$sr" | jq -r '.status // "UNKNOWN"')
    case "$status" in
      COMPLETED)
        local discovered synced
        discovered=$(echo "$sr" | jq -r '.discoveredCount // "?"')
        synced=$(echo "$sr" | jq -r '.syncedCount // "?"')
        pass "$complete_tid: $label COMPLETED (discoveredCount=$discovered, syncedCount=$synced)"
        return 0
        ;;
      FAILED|ERROR)
        fail "$complete_tid: $label job FAILED"
        return 1
        ;;
    esac
    sleep 10; elapsed=$((elapsed+10))
  done
  fail "$complete_tid: $label timed out after 5 min (last status=$status)"
  return 1
}

# rag_find_source <query> <uid> <source_type> <test_id> <label>
# Returns 0 if found, 1 if not found.
rag_find_source() {
  local query="$1" uid="$2" src_type="$3" tid="$4" label="$5"
  local resp found
  # Presence checks validate indexing/access, not ranking. Search across a wider
  # window because the shared demo workspace intentionally accumulates prior runs.
  resp=$(curl -sf -u "$NUXEO_AUTH" -X POST "$RAG_URL/search/semantic" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"$query\",\"topK\":$RAG_PRESENCE_TOPK,\"minScore\":0.2}" 2>/dev/null || echo '{}')
  found=$(echo "$resp" | jq --arg id "$uid" --arg src "$src_type" \
    '[.results[]? | select(
        .sourceDocument.nodeId     == $id and
        .sourceDocument.sourceType == $src
      )] | length' 2>/dev/null || echo 0)
  if [ "${found:-0}" -gt 0 ]; then
    pass "$tid: $label found in search (uid=$uid, source_type=$src_type)"
    return 0
  else
    fail "$tid: $label NOT found (uid=$uid, source_type=$src_type, query='$query')"
    echo "    top results: $(echo "$resp" | jq -c '[.results[:2][]? | {id:.sourceDocument.nodeId, src:.sourceDocument.sourceType, score:.score}]')"
    return 1
  fi
}

# rag_find_source_as <query> <uid> <source_type> <test_id> <label> <user:password>
rag_find_source_as() {
  local query="$1" uid="$2" src_type="$3" tid="$4" label="$5" auth="$6"
  local resp found
  resp=$(curl -sf -u "$auth" -X POST "$RAG_URL/search/semantic" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"$query\",\"topK\":$RAG_PRESENCE_TOPK,\"minScore\":0.2}" 2>/dev/null || echo '{}')
  found=$(echo "$resp" | jq --arg id "$uid" --arg src "$src_type" \
    '[.results[]? | select(
        .sourceDocument.nodeId     == $id and
        .sourceDocument.sourceType == $src
      )] | length' 2>/dev/null || echo 0)
  if [ "${found:-0}" -gt 0 ]; then
    pass "$tid: $label found in search (as ${auth%%:*})"
    return 0
  else
    fail "$tid: $label NOT found (as ${auth%%:*}, uid=$uid, source_type=$src_type)"
    echo "    top results: $(echo "$resp" | jq -c '[.results[:3][]? | {id:.sourceDocument.nodeId, src:.sourceDocument.sourceType, score:.score}]')"
    return 1
  fi
}

# rag_absent_uid <query> <uid> <test_id> <label>
rag_absent_uid() {
  local query="$1" uid="$2" tid="$3" label="$4"
  local resp found
  resp=$(curl -sf -u "$NUXEO_AUTH" -X POST "$RAG_URL/search/semantic" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"$query\",\"topK\":10,\"minScore\":0.1}" 2>/dev/null || echo '{}')
  found=$(echo "$resp" | jq --arg id "$uid" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)] | length' 2>/dev/null || echo 0)
  if [ "${found:-0}" -eq 0 ]; then
    pass "$tid: $label correctly absent from search"
  else
    fail "$tid: $label still appears in search (uid=$uid)"
  fi
}

# rag_absent_uid_as <query> <uid> <test_id> <label> <user:password>
rag_absent_uid_as() {
  local query="$1" uid="$2" tid="$3" label="$4" auth="$5"
  local resp found
  resp=$(curl -sf -u "$auth" -X POST "$RAG_URL/search/semantic" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"$query\",\"topK\":10,\"minScore\":0.1}" 2>/dev/null || echo '{}')
  found=$(echo "$resp" | jq --arg id "$uid" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)] | length' 2>/dev/null || echo 0)
  if [ "${found:-0}" -eq 0 ]; then
    pass "$tid: $label correctly absent from search (as ${auth%%:*})"
  else
    fail "$tid: $label still appears in search (as ${auth%%:*}, uid=$uid)"
  fi
}

# create_demo_file <title> <text> [workspace_name] [workspace_title] — returns the Nuxeo UID or empty
create_demo_file() {
  local title="$1" text="$2" workspace_name="${3:-}" workspace_title="${4:-}"
  if [ -z "$workspace_name" ] && [[ "$NUXEO_INCLUDED_ROOT" == /default-domain/workspaces/* ]]; then
    workspace_name="${NUXEO_INCLUDED_ROOT#/default-domain/workspaces/}"
    [[ "$workspace_name" == */* ]] && workspace_name=""
  fi
  local -a cmd=(bash "$DEMO_SCRIPT" --title "$title" --text "$text")
  [ -n "$workspace_name" ] && cmd+=(--workspace-name "$workspace_name")
  [ -n "$workspace_title" ] && cmd+=(--workspace-title "$workspace_title")
  local output
  output=$("${cmd[@]}" 2>/dev/null) || { echo ""; return; }
  echo "$output" | grep '^UID:' | awk '{print $2}'
}

# create_demo_file_from_file <title> <path> [mime] [workspace_name] [workspace_title]
create_demo_file_from_file() {
  local title="$1" input_path="$2" mime="${3:-text/plain}" workspace_name="${4:-}" workspace_title="${5:-}"
  if [ -z "$workspace_name" ] && [[ "$NUXEO_INCLUDED_ROOT" == /default-domain/workspaces/* ]]; then
    workspace_name="${NUXEO_INCLUDED_ROOT#/default-domain/workspaces/}"
    [[ "$workspace_name" == */* ]] && workspace_name=""
  fi
  local -a cmd=(bash "$DEMO_SCRIPT" --title "$title" --input-file "$input_path" --mime-type "$mime")
  [ -n "$workspace_name" ] && cmd+=(--workspace-name "$workspace_name")
  [ -n "$workspace_title" ] && cmd+=(--workspace-title "$workspace_title")
  local output
  output=$("${cmd[@]}" 2>/dev/null) || { echo ""; return; }
  echo "$output" | grep '^UID:' | awk '{print $2}'
}

# nuxeo_doc_path <uid> — returns the persisted repository path or empty
nuxeo_doc_path() {
  local uid="$1"
  local resp code body
  resp=$(curl -s -w '\n%{http_code}' -u "$NUXEO_AUTH" \
    "$NUXEO_BASE/id/$uid" 2>/dev/null || echo $'\n000')
  code=$(printf '%s' "$resp" | tail -1)
  body=$(printf '%s' "$resp" | sed '$d')
  if [ "$code" = "200" ]; then
    printf '%s' "$body" | jq -r '.path // empty'
  else
    echo ""
  fi
}

# delete_nuxeo_doc <uid>
delete_nuxeo_doc() {
  curl -sf -o /dev/null -w '%{http_code}' -u "$NUXEO_AUTH" -X DELETE \
    "$NUXEO_BASE/id/$1" 2>/dev/null || echo 000
}

# remove_nuxeo_acl <uid> [acl_name]
remove_nuxeo_acl() {
  local uid="$1" acl_name="${2:-local}"
  local payload code
  payload=$(NUXEO_UID="$uid" NUXEO_ACL="$acl_name" python3 - <<'PY'
import json, os
print(json.dumps({
    "params": {
        "acl": os.environ["NUXEO_ACL"],
    },
    "input": f"doc:{os.environ['NUXEO_UID']}",
}))
PY
)
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "$NUXEO_AUTH" -X POST \
    "$NUXEO_BASE/automation/Document.RemoveACL" \
    -H 'Content-Type: application/json' \
    --data "$payload" 2>/dev/null || echo 000)
  [ "$code" = "200" ] || [ "$code" = "204" ]
}

# create_nuxeo_user <id>
create_nuxeo_user() {
  local id="$1"
  local check_code payload code
  check_code=$(curl -s -o /dev/null -w '%{http_code}' -u "$NUXEO_AUTH" \
    "$NUXEO_BASE/user/$id" 2>/dev/null || echo 000)
  case "$check_code" in
    200)
      info "Nuxeo user $id already exists"
      return 0
      ;;
    404)
      payload=$(NUXEO_USER_ID="$id" python3 - <<'PY'
import json, os
user_id = os.environ["NUXEO_USER_ID"]
print(json.dumps({
    "entity-type": "user",
    "id": user_id,
    "name": user_id,
    "properties": {
        "username": user_id,
        "firstName": "Test",
        "lastName": user_id,
        "password": "password",
        "email": f"{user_id}@test.local",
    },
}))
PY
)
      code=$(curl -s -o /dev/null -w '%{http_code}' -u "$NUXEO_AUTH" -X POST \
        "$NUXEO_BASE/user" \
        -H 'Content-Type: application/json' \
        --data "$payload" 2>/dev/null || echo 000)
      case "$code" in
        200|201) info "Created Nuxeo user $id" ; return 0 ;;
        409) info "Nuxeo user $id already exists" ; return 0 ;;
        *) fail "G0: Failed to create Nuxeo user $id (HTTP $code)" ; return 1 ;;
      esac
      ;;
    *)
      fail "G0: Failed to check Nuxeo user $id (HTTP $check_code)"
      return 1
      ;;
  esac
}

# set_nuxeo_ace <uid> <principal> <grant:true|false> [block_inheritance:true|false]
set_nuxeo_ace() {
  local uid="$1" principal="$2" grant="${3:-true}" block_inheritance="${4:-false}"
  local payload code
  if [ "$grant" = "true" ]; then
    if [ "$principal" = "Everyone" ]; then
      payload=$(NUXEO_UID="$uid" NUXEO_PRINCIPAL="$principal" NUXEO_BLOCK="$block_inheritance" python3 - <<'PY'
import json, os

def as_bool(value: str) -> bool:
    return value.strip().lower() == "true"

print(json.dumps({
    "params": {
        "user": os.environ["NUXEO_PRINCIPAL"],
        "permission": "Read",
        "grant": True,
        "blockInheritance": as_bool(os.environ["NUXEO_BLOCK"]),
    },
    "input": f"doc:{os.environ['NUXEO_UID']}",
}))
PY
)
      code=$(curl -s -o /dev/null -w '%{http_code}' -u "$NUXEO_AUTH" -X POST \
        "$NUXEO_BASE/automation/Document.SetACE" \
        -H 'Content-Type: application/json' \
        --data "$payload" 2>/dev/null || echo 000)
    else
      payload=$(NUXEO_UID="$uid" NUXEO_PRINCIPAL="$principal" NUXEO_BLOCK="$block_inheritance" python3 - <<'PY'
import json, os

def as_bool(value: str) -> bool:
    return value.strip().lower() == "true"

print(json.dumps({
    "params": {
        "permission": "Read",
        "users": [os.environ["NUXEO_PRINCIPAL"]],
        "blockInheritance": as_bool(os.environ["NUXEO_BLOCK"]),
    },
    "input": f"doc:{os.environ['NUXEO_UID']}",
}))
PY
)
      code=$(curl -s -o /dev/null -w '%{http_code}' -u "$NUXEO_AUTH" -X POST \
        "$NUXEO_BASE/automation/Document.AddPermission" \
        -H 'Content-Type: application/json' \
        --data "$payload" 2>/dev/null || echo 000)
    fi
  else
    payload=$(NUXEO_UID="$uid" NUXEO_PRINCIPAL="$principal" python3 - <<'PY'
import json, os
print(json.dumps({
    "params": {
        "user": os.environ["NUXEO_PRINCIPAL"],
        "acl": "local",
    },
    "input": f"doc:{os.environ['NUXEO_UID']}",
}))
PY
)
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "$NUXEO_AUTH" -X POST \
      "$NUXEO_BASE/automation/Document.RemovePermission" \
      -H 'Content-Type: application/json' \
      --data "$payload" 2>/dev/null || echo 000)
  fi
  [ "$code" = "200" ] || [ "$code" = "204" ]
}

# grant_nuxeo_read_aces <uid> <block_inheritance:true|false> <principal...>
grant_nuxeo_read_aces() {
  local uid="$1" block_inheritance="$2"
  shift 2
  local principal rc=0 first=true
  for principal in "$@"; do
    if [ "$first" = true ]; then
      set_nuxeo_ace "$uid" "$principal" true "$block_inheritance" || rc=1
      first=false
    else
      set_nuxeo_ace "$uid" "$principal" true false || rc=1
    fi
  done
  [ "$rc" -eq 0 ]
}

# create_nuxeo_folder <parent_path> <name> [title] — returns the folder UID or empty
create_nuxeo_folder() {
  local parent_path="$1" name="$2" title="${3:-$2}"
  local payload resp body code
  payload=$(NUXEO_DOC_NAME="$name" NUXEO_DOC_TITLE="$title" python3 - <<'PY'
import json, os
print(json.dumps({
    "entity-type": "document",
    "name": os.environ["NUXEO_DOC_NAME"],
    "type": "Folder",
    "properties": {
        "dc:title": os.environ["NUXEO_DOC_TITLE"],
    },
}))
PY
)
  resp=$(curl -s -w '\n%{http_code}' -u "$NUXEO_AUTH" -X POST \
    "$NUXEO_BASE/path${parent_path}" \
    -H 'Content-Type: application/json' \
    --data "$payload" 2>/dev/null)
  code=$(printf '%s' "$resp" | tail -1)
  body=$(printf '%s' "$resp" | sed '$d')
  if [ "$code" = "201" ]; then
    printf '%s' "$body" | jq -r '.uid // empty'
  else
    echo ""
  fi
}

# attach_blob_to_doc <uid> <local_path> <filename> [mime]
attach_blob_to_doc() {
  local uid="$1" local_path="$2" filename="$3" mime="${4:-text/plain}"
  local params code
  params=$(NUXEO_UID="$uid" python3 - <<'PY'
import json, os
print(json.dumps({
    "params": {
        "document": os.environ["NUXEO_UID"],
        "save": True,
        "xpath": "file:content",
    }
}))
PY
)
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "$NUXEO_AUTH" -X POST \
    "$NUXEO_BASE/automation/Blob.AttachOnDocument" \
    -F "params=${params};type=application/json" \
    -F "input=@${local_path};filename=${filename};type=${mime}" 2>/dev/null || echo 000)
  [ "$code" = "200" ]
}

# create_nuxeo_text_document <parent_path> <name> <title> <text> [mime] — returns the document UID or empty
create_nuxeo_text_document() {
  local parent_path="$1" name="$2" title="$3" text="$4" mime="${5:-text/plain}"
  local tmp_path="$TMPDIR_DATA/$name"
  local payload resp body code uid
  printf '%s' "$text" > "$tmp_path"
  payload=$(NUXEO_DOC_NAME="$name" NUXEO_DOC_TITLE="$title" python3 - <<'PY'
import json, os
print(json.dumps({
    "entity-type": "document",
    "name": os.environ["NUXEO_DOC_NAME"],
    "type": "File",
    "properties": {
        "dc:title": os.environ["NUXEO_DOC_TITLE"],
    },
}))
PY
)
  resp=$(curl -s -w '\n%{http_code}' -u "$NUXEO_AUTH" -X POST \
    "$NUXEO_BASE/path${parent_path}" \
    -H 'Content-Type: application/json' \
    --data "$payload" 2>/dev/null)
  code=$(printf '%s' "$resp" | tail -1)
  body=$(printf '%s' "$resp" | sed '$d')
  if [ "$code" != "201" ]; then
    echo ""
    return
  fi
  uid=$(printf '%s' "$body" | jq -r '.uid // empty')
  if [ -n "$uid" ] && attach_blob_to_doc "$uid" "$tmp_path" "$name" "$mime"; then
    printf '%s' "$uid"
  else
    echo ""
  fi
}

# update_nuxeo_text_document <uid> <filename> <text> [mime]
update_nuxeo_text_document() {
  local uid="$1" filename="$2" text="$3" mime="${4:-text/plain}"
  local tmp_path="$TMPDIR_DATA/$filename"
  printf '%s' "$text" > "$tmp_path"
  attach_blob_to_doc "$uid" "$tmp_path" "$filename" "$mime"
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Health checks
# ═══════════════════════════════════════════════════════════════════════════════
section "A — Smoke Tests (Nuxeo mode)"

# N-A1: RAG service health
code=$(curl -sf -o /dev/null -w '%{http_code}' "$RAG_URL/health" 2>/dev/null || echo 000)
[ "$code" = "200" ] && pass "N-A1: RAG service /health is UP" \
                     || fail "N-A1: RAG service returned HTTP $code"

# N-A2: Nuxeo connectivity
code=$(curl -sf -o /dev/null -w '%{http_code}' -u "$NUXEO_AUTH" \
  "$NUXEO_BASE/path/default-domain" 2>/dev/null || echo 000)
[ "$code" = "200" ] && pass "N-A2: Nuxeo repository responds" \
                     || fail "N-A2: Nuxeo /path/default-domain returned HTTP $code"

# N-A3: Nuxeo batch ingester health (via proxy sync status)
code=$(curl -sf -o /dev/null -w '%{http_code}' -u "$NUXEO_AUTH" \
  "$SYNC_URL/status" 2>/dev/null || echo 000)
[ "$code" = "200" ] && pass "N-A3: Nuxeo batch ingester status endpoint is healthy" \
                     || fail "N-A3: Batch ingester status returned HTTP $code"

# N-A4: Nuxeo live ingester container health (Docker health check)
live_health=$(docker inspect --format='{{.State.Health.Status}}' \
  content-lake-app-nuxeo-live-ingester-1 2>/dev/null || echo "not-found")
[ "$live_health" = "healthy" ] \
  && pass "N-A4: Nuxeo live ingester container is healthy" \
  || fail "N-A4: Nuxeo live ingester container is '$live_health' (expected healthy)"

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION D — Nuxeo Batch Ingestion
# ═══════════════════════════════════════════════════════════════════════════════
section "D — Nuxeo Batch Ingestion"

[ -f "$DEMO_SCRIPT" ] || { fail "D1: create-nuxeo-demo-file.sh not found at $DEMO_SCRIPT"; exit 1; }

# D1: Upload test documents via the demo helper (targets content-lake-demo workspace,
#     which is the default NUXEO_INCLUDED_ROOT_1 for the batch ingester)
info "Creating Nuxeo test documents in the content-lake-demo workspace …"

D_HR_QUERY="remote work eligibility home three days $TEST_RUN_ALPHA_TAG"
D_SEC_QUERY="information security policy password complexity access control $TEST_RUN_ALPHA_TAG"
D_ROAD_QUERY="product roadmap Q3 mobile AI open API platform $TEST_RUN_ALPHA_TAG"
D_FIN_QUERY="revenue growth EBITDA margin free cash flow $TEST_RUN_ALPHA_TAG"

HR_UID=$(create_demo_file "Nuxeo HR Remote Work Policy $TEST_RUN_TAG" \
  "Remote work eligibility criteria for Nuxeo employees. Work from home three days per week is permitted with manager approval. Home office equipment allowance applies. Content: $D_HR_QUERY.")
SEC_UID=$(create_demo_file "Nuxeo IT Security Policy $TEST_RUN_TAG" \
  "Information security policy for Nuxeo platform. Password complexity requirements, access control, data classification scheme, and incident response procedures. Content: $D_SEC_QUERY.")
ROAD_UID=$(create_demo_file "Nuxeo Product Roadmap 2025 $TEST_RUN_TAG" \
  "Product roadmap Q3 delivery milestones. Mobile-first strategy, AI feature integration, open API platform, developer portal launch planned for fiscal year 2025. Content: $D_ROAD_QUERY.")
FIN_UID=$(create_demo_file "Nuxeo Financial Summary Q4 $TEST_RUN_TAG" \
  "Quarterly financial results. Revenue growth fifteen percent, EBITDA margin twenty percent, capital expenditure within budget, free cash flow exceeds target. Content: $D_FIN_QUERY.")

for entry in "HR Policy:$HR_UID" "IT Security:$SEC_UID" "Product Roadmap:$ROAD_UID" "Financial Summary:$FIN_UID"; do
  label="${entry%%:*}"; uid="${entry##*:}"
  if [ -n "$uid" ]; then
    pass "D1: Uploaded '$label' to Nuxeo (uid=$uid)"
  else
    fail "D1: Failed to create '$label' document in Nuxeo"
  fi
done

# D2+D3+D4: Trigger Nuxeo sync and wait for completion
run_nuxeo_sync_wait

info "Waiting 30 s for embedding pipeline to finish …"
sleep 30

# D5–D8: Verify each document appears in semantic search with source_type=nuxeo
[ -n "${HR_UID:-}" ]   && rag_find_source "$D_HR_QUERY" \
  "$HR_UID"   "nuxeo" "D5" "Nuxeo HR policy"
[ -n "${SEC_UID:-}" ]  && rag_find_source "$D_SEC_QUERY" \
  "$SEC_UID"  "nuxeo" "D6" "Nuxeo IT security policy"
[ -n "${ROAD_UID:-}" ] && rag_find_source "$D_ROAD_QUERY" \
  "$ROAD_UID" "nuxeo" "D7" "Nuxeo product roadmap"
[ -n "${FIN_UID:-}" ]  && rag_find_source "$D_FIN_QUERY" \
  "$FIN_UID"  "nuxeo" "D8" "Nuxeo financial summary"

# D9: Idempotency re-run
info "Re-running Nuxeo sync for idempotency check …"
curl -sf -u "$NUXEO_AUTH" -X POST "$SYNC_URL/configured" >/dev/null 2>&1 || true
sleep 10
if [ -n "${HR_UID:-}" ]; then
  resp=$(curl -sf -u "$NUXEO_AUTH" -X POST "$RAG_URL/search/semantic" \
    -H 'Content-Type: application/json' \
    -d '{"query":"remote work eligibility Nuxeo","topK":20,"minScore":0.2}' 2>/dev/null || echo '{}')
  count=$(echo "$resp" | jq --arg id "$HR_UID" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)] | length' 2>/dev/null || echo 0)
  if [ "${count:-0}" -eq 1 ]; then
    pass "D9: Idempotency — Nuxeo HR document present exactly once (count=$count)"
  elif [ "${count:-0}" -eq 0 ]; then
    fail "D9: Idempotency — Nuxeo HR document not found (count=0, batch sync may have failed)"
  else
    fail "D9: Idempotency — Nuxeo HR document appears $count times (expected 1)"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION E — Nuxeo Live Ingestion (audit-poll based, ~30 s default interval)
# ═══════════════════════════════════════════════════════════════════════════════
section "E — Nuxeo Live Ingestion"

LIVE_NUX_UID=""
E1B_PASS=false
E2B_PASS=false
LIVE_DELETE_QUERY="corvette-iridescent-nebula-92k version one"

# E1: Create a new document — should appear after one audit poll cycle
LIVE_NUX_UID=$(create_demo_file "Nuxeo Live Test V1 $TEST_RUN_TAG" \
  "Live ingestion sentinel phrase: corvette-iridescent-nebula-92k version one. This document tests real-time audit-based ingestion for the Nuxeo connector.")
if [ -n "$LIVE_NUX_UID" ]; then
  pass "E1a: Live test document created in Nuxeo (uid=$LIVE_NUX_UID)"
  info "Waiting 50 s for audit poll cycle and embedding pipeline …"
  sleep 50
  rag_find_source "corvette-iridescent-nebula-92k version one" \
    "$LIVE_NUX_UID" "nuxeo" "E1b" "Nuxeo live-test doc after create" \
    && E1B_PASS=true
else
  fail "E1: Failed to create live test document in Nuxeo"
fi

# E2: Update document content — new phrase should become searchable after the next audit poll.
if [ -n "$LIVE_NUX_UID" ]; then
  if update_nuxeo_text_document "$LIVE_NUX_UID" "nuxeo-live-test-v2-$TEST_RUN_TAG.txt" \
    "Live ingestion sentinel phrase: saffron-aurora-signal-17m version two. This document has been updated to verify audit-based re-indexing of modified Nuxeo content."; then
    pass "E2a: Nuxeo live test document content updated"
    info "Waiting 50 s for audit poll cycle to detect the update …"
    sleep 50
    rag_find_source "saffron-aurora-signal-17m version two" \
      "$LIVE_NUX_UID" "nuxeo" "E2b" "Nuxeo live-test doc after update" \
      && E2B_PASS=true
    [ "$E2B_PASS" = true ] && LIVE_DELETE_QUERY="saffron-aurora-signal-17m version two"
  else
    fail "E2: Failed to update Nuxeo live test document content"
  fi
fi

# E3: Delete the document — should disappear after the next audit poll.
# Only meaningful if E1b or E2b confirmed the document was indexed first.
if [ -n "$LIVE_NUX_UID" ]; then
  code=$(delete_nuxeo_doc "$LIVE_NUX_UID")
  if [ "$code" = "204" ] || [ "$code" = "200" ]; then
    pass "E3a: Nuxeo live test document deleted (HTTP $code)"
    if [ "$E1B_PASS" = true ] || [ "$E2B_PASS" = true ]; then
      info "Waiting 50 s for audit poll cycle to detect deletion …"
      sleep 50
      rag_absent_uid "$LIVE_DELETE_QUERY" "$LIVE_NUX_UID" "E3b" \
        "Nuxeo live-test doc after delete"
    else
      info "E3b: skipping — the live-test document was never confirmed in search"
    fi
  else
    fail "E3: Delete returned HTTP $code (expected 204 or 200)"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION F — Security Tests
# ═══════════════════════════════════════════════════════════════════════════════
section "F — Security Tests (Nuxeo mode)"

# F-N: Unauthenticated RAG requests must be rejected with HTTP 401
http_code_fn=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$RAG_URL/search/semantic" \
  -H 'Content-Type: application/json' \
  -d '{"query":"test","topK":1,"minScore":0.2}' 2>/dev/null || echo 000)
if [ "$http_code_fn" = "401" ]; then
  pass "F-N: Unauthenticated RAG request rejected (HTTP 401)"
else
  fail "F-N: Expected HTTP 401 for unauthenticated request, got HTTP $http_code_fn"
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION G — Permission Tests
# ═══════════════════════════════════════════════════════════════════════════════
section "G — Permission Tests"
info "Nuxeo ACLs are applied with Document.AddPermission / Document.RemovePermission."
info "Permission updates on existing documents rely on audit-driven ACL refresh; initial indexing uses configured batch sync."
info "Unlike Alfresco, Administrator visibility is asserted via explicit Administrator ACEs rather than a source-level bypass."

create_nuxeo_user "user-a"
create_nuxeo_user "user-b"

G_HR_QUERY="salary band confidential HR restricted access user-a $TEST_RUN_TAG"
G_TECH_QUERY="internal architecture restricted technical user-b access $TEST_RUN_TAG"
G_PUBLIC_QUERY="public company announcement everyone all staff general notice $TEST_RUN_TAG"

G_HR_UID=$(create_demo_file "Nuxeo Confidential HR $TEST_RUN_TAG" \
  "CONFIDENTIAL HR DOCUMENT. Restricted to HR and user-a only. Content: $G_HR_QUERY.")
if [ -n "$G_HR_UID" ]; then
  grant_nuxeo_read_aces "$G_HR_UID" true "Administrator" "user-a" \
    && pass "G1a: confidential HR document created and restricted to Administrator + user-a (uid=$G_HR_UID)" \
    || fail "G1a: Failed to apply ACL on confidential HR document"
else
  fail "G1a: Failed to create confidential HR document"
fi

G_TECH_UID=$(create_demo_file "Nuxeo Restricted Tech $TEST_RUN_TAG" \
  "RESTRICTED TECHNICAL DOCUMENT. Restricted to engineering and user-b only. Content: $G_TECH_QUERY.")
if [ -n "$G_TECH_UID" ]; then
  grant_nuxeo_read_aces "$G_TECH_UID" true "Administrator" "user-b" \
    && pass "G1b: restricted tech document created and restricted to Administrator + user-b (uid=$G_TECH_UID)" \
    || fail "G1b: Failed to apply ACL on restricted tech document"
else
  fail "G1b: Failed to create restricted tech document"
fi

G_PUBLIC_UID=$(create_demo_file "Nuxeo Public Announcement $TEST_RUN_TAG" \
  "PUBLIC COMPANY ANNOUNCEMENT. Available to all staff. Content: $G_PUBLIC_QUERY.")
if [ -n "$G_PUBLIC_UID" ]; then
  grant_nuxeo_read_aces "$G_PUBLIC_UID" true "Administrator" "Everyone" \
    && pass "G1c: public announcement created with Administrator + Everyone read access (uid=$G_PUBLIC_UID)" \
    || fail "G1c: Failed to apply ACL on public announcement"
else
  fail "G1c: Failed to create public announcement"
fi

run_nuxeo_sync_wait "G1d" "G1e" "Permission fixture sync"
info "Waiting 30 s for indexed ACLs to settle …"
sleep 30

[ -n "${G_HR_UID:-}" ]     && rag_find_source "$G_HR_QUERY"     "$G_HR_UID"     "nuxeo" "G2a" "Administrator sees confidential HR document"
[ -n "${G_TECH_UID:-}" ]   && rag_find_source "$G_TECH_QUERY"   "$G_TECH_UID"   "nuxeo" "G2b" "Administrator sees restricted tech document"
[ -n "${G_PUBLIC_UID:-}" ] && rag_find_source "$G_PUBLIC_QUERY" "$G_PUBLIC_UID" "nuxeo" "G2c" "Administrator sees public announcement"

[ -n "${G_HR_UID:-}" ]     && rag_find_source_as "$G_HR_QUERY"     "$G_HR_UID"     "nuxeo" "G3a" "user-a sees confidential HR document" "user-a:password"
[ -n "${G_TECH_UID:-}" ]   && rag_absent_uid_as "$G_TECH_QUERY"    "$G_TECH_UID"              "G3b" "user-a cannot see restricted tech document" "user-a:password"
[ -n "${G_PUBLIC_UID:-}" ] && rag_find_source_as "$G_PUBLIC_QUERY" "$G_PUBLIC_UID" "nuxeo" "G3c" "user-a sees public announcement" "user-a:password"

[ -n "${G_TECH_UID:-}" ]   && rag_find_source_as "$G_TECH_QUERY"   "$G_TECH_UID"   "nuxeo" "G4a" "user-b sees restricted tech document" "user-b:password"
[ -n "${G_HR_UID:-}" ]     && rag_absent_uid_as "$G_HR_QUERY"      "$G_HR_UID"                "G4b" "user-b cannot see confidential HR document" "user-b:password"
[ -n "${G_PUBLIC_UID:-}" ] && rag_find_source_as "$G_PUBLIC_QUERY" "$G_PUBLIC_UID" "nuxeo" "G4c" "user-b sees public announcement" "user-b:password"

if [ -n "${G_HR_UID:-}" ]; then
  if grant_nuxeo_read_aces "$G_HR_UID" true "Administrator" && set_nuxeo_ace "$G_HR_UID" "user-a" false false; then
    pass "G5: user-a access revoked from confidential HR document"
    info "Waiting 50 s for documentSecurityUpdated audit processing …"
    sleep 50
  else
    fail "G5: Failed to revoke user-a access from confidential HR document"
  fi
fi

[ -n "${G_HR_UID:-}" ] && rag_find_source "$G_HR_QUERY" "$G_HR_UID" "nuxeo" "G6a" "Administrator still sees confidential HR document after revocation"
[ -n "${G_HR_UID:-}" ] && rag_absent_uid_as "$G_HR_QUERY" "$G_HR_UID" "G6b" "user-a cannot see confidential HR document after revocation" "user-a:password"

G_PROP_FOLDER_NAME="nuxeo-perm-propagation-$TEST_RUN_TAG"
G_PROP_FOLDER_PATH=""
G_PROP_FOLDER_UID=$(create_nuxeo_folder "$NUXEO_INCLUDED_ROOT" "$G_PROP_FOLDER_NAME" "Nuxeo Permission Propagation $TEST_RUN_TAG")
if [ -n "$G_PROP_FOLDER_UID" ]; then
  G_PROP_FOLDER_PATH=$(nuxeo_doc_path "$G_PROP_FOLDER_UID")
  if [ -n "$G_PROP_FOLDER_PATH" ]; then
    pass "G7a: Permission propagation folder created (uid=$G_PROP_FOLDER_UID, path=$G_PROP_FOLDER_PATH)"
    grant_nuxeo_read_aces "$G_PROP_FOLDER_UID" true "Administrator" "Everyone" \
      && pass "G7b: Permission propagation folder initialized with Administrator + Everyone" \
      || fail "G7b: Failed to initialize folder ACL"
  else
    fail "G7a: Permission propagation folder created but path lookup failed (uid=$G_PROP_FOLDER_UID)"
  fi
else
  fail "G7a: Failed to create permission propagation folder under $NUXEO_INCLUDED_ROOT"
fi

G_INHERIT_QUERY="zephyr-indigo-kappa-fold inherited ACL propagation $TEST_RUN_TAG"
G_ISOLATED_QUERY="zephyr-indigo-kappa-isol isolated ACL no-inherit propagation $TEST_RUN_TAG"

if [ -n "${G_PROP_FOLDER_UID:-}" ]; then
  G_INHERIT_UID=$(create_nuxeo_text_document "$G_PROP_FOLDER_PATH" \
    "folder-child-inherit-$TEST_RUN_TAG.txt" \
    "Folder Child Inherit $TEST_RUN_TAG" \
    "Sentinel phrase: $G_INHERIT_QUERY. This file relies on the parent folder ACL.")
  [ -n "$G_INHERIT_UID" ] \
    && pass "G7c: folder-child-inherit created (uid=$G_INHERIT_UID)" \
    || fail "G7c: Failed to create folder-child-inherit"

  G_ISOLATED_UID=$(create_nuxeo_text_document "$G_PROP_FOLDER_PATH" \
    "folder-child-isolated-$TEST_RUN_TAG.txt" \
    "Folder Child Isolated $TEST_RUN_TAG" \
    "Sentinel phrase: $G_ISOLATED_QUERY. This file has inheritance blocked with a locally set ACL for user-b.")
  if [ -n "$G_ISOLATED_UID" ]; then
    grant_nuxeo_read_aces "$G_ISOLATED_UID" true "Administrator" "user-b" \
      && pass "G7d: folder-child-isolated created with Administrator + user-b only (uid=$G_ISOLATED_UID)" \
      || fail "G7d: Failed to apply isolated child ACL"
  else
    fail "G7d: Failed to create folder-child-isolated"
  fi
fi

run_nuxeo_sync_wait "G8a" "G8b" "Folder permission baseline sync"
info "Waiting 30 s for folder permission fixtures to index …"
sleep 30

[ -n "${G_INHERIT_UID:-}" ]  && rag_find_source "$G_INHERIT_QUERY"  "$G_INHERIT_UID"  "nuxeo" "G8c" "Administrator sees folder-child-inherit before folder ACL change"
[ -n "${G_ISOLATED_UID:-}" ] && rag_find_source "$G_ISOLATED_QUERY" "$G_ISOLATED_UID" "nuxeo" "G8d" "Administrator sees folder-child-isolated before folder ACL change"

if [ -n "${G_PROP_FOLDER_UID:-}" ]; then
  if remove_nuxeo_acl "$G_PROP_FOLDER_UID" "local" \
    && grant_nuxeo_read_aces "$G_PROP_FOLDER_UID" true "Administrator" "user-a"; then
    pass "G9a: Permission propagation folder restricted to Administrator + user-a"
    info "Waiting 50 s for folder ACL audit processing …"
    sleep 50
    run_nuxeo_sync_wait "G9b" "G9c" "Folder permission reconciliation sync"
    info "Waiting 30 s for descendant ACL state to settle …"
    sleep 30
  else
    fail "G9a: Failed to restrict permission propagation folder to Administrator + user-a"
  fi
fi

[ -n "${G_INHERIT_UID:-}" ]  && rag_find_source_as "$G_INHERIT_QUERY"  "$G_INHERIT_UID"  "nuxeo" "G10a" "user-a finds folder-child-inherit after folder ACL change" "user-a:password"
[ -n "${G_INHERIT_UID:-}" ]  && rag_absent_uid_as "$G_INHERIT_QUERY"   "$G_INHERIT_UID"              "G10b" "user-b cannot find folder-child-inherit after folder ACL change" "user-b:password"
[ -n "${G_INHERIT_UID:-}" ]  && rag_find_source    "$G_INHERIT_QUERY"   "$G_INHERIT_UID"  "nuxeo" "G10c" "Administrator finds folder-child-inherit after folder ACL change"
[ -n "${G_ISOLATED_UID:-}" ] && rag_find_source_as "$G_ISOLATED_QUERY" "$G_ISOLATED_UID" "nuxeo" "G10d" "user-b still finds folder-child-isolated after folder ACL change" "user-b:password"
[ -n "${G_ISOLATED_UID:-}" ] && rag_absent_uid_as  "$G_ISOLATED_QUERY" "$G_ISOLATED_UID"             "G10e" "user-a cannot find folder-child-isolated after folder ACL change" "user-a:password"
[ -n "${G_ISOLATED_UID:-}" ] && rag_find_source    "$G_ISOLATED_QUERY" "$G_ISOLATED_UID" "nuxeo" "G10f" "Administrator finds folder-child-isolated after folder ACL change"

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION H — Chunking Strategy
# ═══════════════════════════════════════════════════════════════════════════════
section "H — Chunking Strategy"

H_SHORT_QUERY="home office equipment allowance ergonomic chair five hundred pounds $TEST_RUN_ALPHA_TAG"
H_TECH_QUERY="password complexity incident response zero trust architecture $TEST_RUN_ALPHA_TAG"
H_FIN_QUERY="capital expenditure shareholder dividends free cash flow $TEST_RUN_ALPHA_TAG"
H_LONG_EARLY_QUERY="amber lantern forecast $TEST_RUN_ALPHA_TAG early section"
H_LONG_LATE_QUERY="cedar compass governance $TEST_RUN_ALPHA_TAG late section"

H_SHORT_UID=$(create_demo_file "Nuxeo H Short Memo $TEST_RUN_TAG" \
  "MEMORANDUM. Remote work policy for Nuxeo employees. Content: $H_SHORT_QUERY. This short document should remain easy to retrieve as a compact chunk.")
[ -n "$H_SHORT_UID" ] \
  && pass "H0a: Short memo fixture created (uid=$H_SHORT_UID)" \
  || fail "H0a: Failed to create short memo fixture"

H_TECH_UID=$(create_demo_file "Nuxeo H Tech Policy $TEST_RUN_TAG" \
  "INFORMATION SECURITY POLICY. Content: $H_TECH_QUERY. Multi-factor authentication, incident response, and privileged access controls apply.")
[ -n "$H_TECH_UID" ] \
  && pass "H0b: Tech policy fixture created (uid=$H_TECH_UID)" \
  || fail "H0b: Failed to create tech policy fixture"

H_FIN_UID=$(create_demo_file "Nuxeo H Finance Summary $TEST_RUN_TAG" \
  "FINANCIAL SUMMARY. Content: $H_FIN_QUERY. Capital expenditure remained within budget, dividends were approved, and free cash flow exceeded expectations.")
[ -n "$H_FIN_UID" ] \
  && pass "H0c: Finance summary fixture created (uid=$H_FIN_UID)" \
  || fail "H0c: Failed to create finance summary fixture"

H_LONG_PATH="$TMPDIR_DATA/nuxeo-long-report-$TEST_RUN_TAG.txt"
cat > "$H_LONG_PATH" <<'EOF'
ANNUAL FINANCIAL PERFORMANCE REPORT
FISCAL YEAR 2024
Prepared by: Group Finance | Approved by: Board of Directors

SECTION 1: EXECUTIVE SUMMARY

The fiscal year 2024 delivered outstanding results. Total consolidated revenue reached
two point four billion pounds, representing year-on-year growth of fifteen percent.
Adjusted EBITDA improved to four hundred and eighty million pounds, a margin of twenty
percent. Net profit after tax was two hundred and ten million pounds, up from one hundred
and seventy million in fiscal year 2023. The board has approved a final dividend of twelve
pence per ordinary share, bringing the full-year distribution to twenty pence per share.
Free cash flow generation was strong at three hundred and forty million pounds.
Sentinel phrase: amber lantern forecast __ALPHA_TAG__ early section.

SECTION 2: REVENUE ANALYSIS BY DIVISION

The Group operates four reporting divisions: Enterprise Software, Professional Services,
Managed Cloud, and Licensing. Enterprise Software remained the largest contributor,
generating nine hundred and sixty million pounds in the year, representing growth of
eighteen percent driven by new logo acquisition and strong renewal rates above ninety-two
percent. Professional Services revenue grew eleven percent to five hundred and forty
million pounds. Managed Cloud was the fastest growing division at thirty-one percent,
reaching four hundred and twenty million pounds. Licensing revenue declined five percent
to four hundred and eighty million as customers transitioned to subscription models.

SECTION 3: GROSS PROFIT AND MARGIN

Group gross profit was one point zero zero eight billion pounds, representing a gross
margin of forty-two percent, up from thirty-nine percent in the prior year. The margin
improvement reflects continued mix shift toward higher-margin cloud and software revenue,
partially offset by investment in professional services headcount to support growth.
Enterprise Software gross margin reached seventy-one percent. Managed Cloud gross margin
expanded by four percentage points to sixty-three percent as infrastructure unit costs
declined and utilisation rates improved.

SECTION 4: OPERATING EXPENSES

Research and development expenditure was two hundred and sixteen million pounds,
representing nine percent of revenue, in line with the board's commitment to invest a
minimum of eight to ten percent of revenue in product innovation. Sales and marketing
costs were three hundred and twelve million pounds, reflecting targeted investment in
demand generation in North America and the Asia-Pacific region. General and administrative
costs were held flat year-on-year at one hundred and forty-four million pounds despite
inflationary pressures, demonstrating effective cost discipline across central functions.

SECTION 5: EBITDA AND ADJUSTED EARNINGS

Reported EBITDA was four hundred and thirty-two million pounds. Adjusted EBITDA, excluding
share-based compensation charges of twenty-four million pounds, restructuring costs of
eighteen million pounds, and acquisition-related amortisation of six million pounds, was
four hundred and eighty million pounds. The adjusted EBITDA margin of twenty percent
represents the highest level achieved in the Group's history and reflects sustained
operational leverage as the business scales.

SECTION 6: CAPITAL EXPENDITURE AND FREE CASH FLOW

Capital expenditure for the year was sixty million pounds, comprising forty-two million
of investment in cloud infrastructure and eighteen million in facilities and equipment.
Capitalised development costs were ninety-six million pounds. Working capital improved
by thirty-six million pounds as a result of faster customer collections and extended
supplier payment terms negotiated during the year. Free cash flow conversion from
adjusted EBITDA was seventy-one percent, ahead of the sixty-five percent medium-term
target communicated at the Capital Markets Day in March 2023.

SECTION 7: NET DEBT AND BALANCE SHEET

Net debt at year end was one hundred and eighty million pounds, representing a leverage
ratio of zero point four times adjusted EBITDA, well within the board's two times
covenant. The revolving credit facility of three hundred and fifty million pounds was
undrawn. Total equity attributable to shareholders was one point two billion pounds.
Goodwill and intangible assets arising from acquisitions totalled eight hundred and
forty million pounds. The Group's capital allocation framework prioritises organic
investment first, followed by bolt-on acquisitions, then returns to shareholders through
dividends and buybacks.

SECTION 8: ACQUISITIONS AND INTEGRATION

During fiscal year 2024 the Group completed two bolt-on acquisitions. Datasync Limited was
acquired in July 2023 for an enterprise value of seventy-two million pounds and has been
fully integrated into the Enterprise Software division. Analytix Partners was acquired in
January 2024 for an enterprise value of one hundred and eight million pounds; integration
of the technology and go-to-market teams is proceeding to plan and is expected to complete
in the first half of fiscal year 2025. The combined contribution from acquisitions to
revenue in fiscal year 2024 was forty-eight million pounds.

SECTION 9: GEOGRAPHIC PERFORMANCE

The United Kingdom and Ireland remained the largest region, contributing nine hundred
million pounds in revenue, with growth of nine percent. North America was the fastest
growing region, delivering revenue of five hundred and forty million pounds, growth of
twenty-four percent, underpinned by strong new logo momentum and the Datasync acquisition.
Continental Europe contributed four hundred and eighty million pounds, growth of twelve
percent. Asia-Pacific and Rest of World contributed three hundred and sixty million pounds,
growth of twenty percent, reflecting early-stage market penetration investments.

SECTION 10: PEOPLE AND CULTURE

The Group ended the fiscal year with five thousand and four hundred full-time equivalent
employees, an increase of six hundred from the prior year. Employee engagement scores
remained above eighty percent in the annual survey. The voluntary attrition rate was
eleven percent, below the sector average of fourteen percent. The Group invested sixteen
million pounds in learning and development programmes. Female representation in senior
leadership roles increased from thirty-one to thirty-five percent.

SECTION 11: ENVIRONMENTAL, SOCIAL AND GOVERNANCE

The Group reduced absolute Scope 1 and Scope 2 greenhouse gas emissions by eighteen
percent year-on-year, ahead of the twenty percent five-year target set in the 2021
sustainability report. Renewable energy accounted for seventy-eight percent of total
electricity consumption across owned premises. The Group published its first TCFD-aligned
climate risk disclosure in October 2023. Supplier sustainability assessments were conducted
for the top two hundred suppliers by spend, representing eighty-five percent of total
procurement expenditure.

SECTION 12: OUTLOOK AND GUIDANCE

The Board is confident in the Group's ability to deliver continued profitable growth in
fiscal year 2025. The Group has strong forward visibility supported by a twelve-month
committed revenue backlog of one point eight billion pounds at the fiscal year end.
Revenue guidance for fiscal year 2025 is two point six to two point seven billion pounds,
representing growth of eight to thirteen percent. Adjusted EBITDA margin guidance is
maintained at twenty to twenty-one percent.

SECTION 13: PRINCIPAL RISKS

The principal risks identified by the Board include macroeconomic uncertainty affecting
customer spending, cybersecurity threats to systems and customer data, talent retention in
a competitive labour market, technology disruption from artificial intelligence, and
regulatory change including data protection and AI governance frameworks. Each risk is
managed through a dedicated mitigation programme overseen by the Audit and Risk Committee.

SECTION 14: CORPORATE GOVERNANCE

The Board comprises ten directors: four executive directors and six independent non-executive
directors. The Chair is independent. Board gender diversity is forty percent female.
Audit, Remuneration, and Nomination Committees met the recommended frequency. The Annual
General Meeting will be held on the fifteenth of June 2025 at the Group's registered office
in London.

SECTION 15: AUDIT CERTIFICATION AND REGULATORY COMPLIANCE FRAMEWORK

The financial statements have been prepared in accordance with UK-adopted International
Accounting Standards and the requirements of the Companies Act 2006. The independent
auditors, FinanceAudit LLP, have issued an unqualified opinion. The internal audit function
conducted forty-two reviews during the year and reported no material control deficiencies.
The Group is fully compliant with the UK Corporate Governance Code. All regulatory filings
were submitted within required deadlines. Sentinel phrase: cedar compass governance __ALPHA_TAG__ late section.
The compliance framework is subject to annual
independent review by external legal counsel.
EOF
sed -i.bak "s/__ALPHA_TAG__/$TEST_RUN_ALPHA_TAG/g" "$H_LONG_PATH" && rm -f "$H_LONG_PATH.bak"
H_LONG_UID=$(create_demo_file_from_file "Nuxeo H Long Report $TEST_RUN_TAG" "$H_LONG_PATH" "text/plain")
[ -n "$H_LONG_UID" ] \
  && pass "H0d: Long report fixture created (uid=$H_LONG_UID)" \
  || fail "H0d: Failed to create long report fixture"

run_nuxeo_sync_wait "H0e" "H0f" "Chunking fixture sync"
info "Waiting 30 s for chunking fixtures to embed …"
sleep 30

if [ -n "${H_SHORT_UID:-}" ]; then
  resp_h1=$(curl -sf -u "$NUXEO_AUTH" -X POST "$RAG_URL/search/semantic" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"$H_SHORT_QUERY\",\"topK\":5,\"minScore\":0.2}" \
    2>/dev/null || echo '{}')
  count_h1=$(echo "$resp_h1" | jq --arg id "$H_SHORT_UID" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)] | length' 2>/dev/null || echo 0)
  chunk_preview=$(echo "$resp_h1" | jq -r --arg id "$H_SHORT_UID" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)][0].chunkText // ""' 2>/dev/null | head -c 100)
  if [ "${count_h1:-0}" -gt 0 ]; then
    pass "H1: Short memo retrieved via its specific phrase (chunks in results: $count_h1)"
    info "    Chunk preview: ${chunk_preview}…"
  else
    fail "H1: Short memo NOT found — chunking or embedding may have failed"
  fi
fi

if [ -n "${H_LONG_UID:-}" ]; then
  resp_early=$(curl -sf -u "$NUXEO_AUTH" -X POST "$RAG_URL/search/semantic" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"$H_LONG_EARLY_QUERY\",\"topK\":5,\"minScore\":0.2}" \
    2>/dev/null || echo '{}')
  resp_late=$(curl -sf -u "$NUXEO_AUTH" -X POST "$RAG_URL/search/semantic" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"$H_LONG_LATE_QUERY\",\"topK\":5,\"minScore\":0.2}" \
    2>/dev/null || echo '{}')

  early_text=$(echo "$resp_early" | jq -r --arg id "$H_LONG_UID" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)][0].chunkText // ""' 2>/dev/null | head -c 80)
  late_text=$(echo "$resp_late" | jq -r --arg id "$H_LONG_UID" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)][0].chunkText // ""' 2>/dev/null | head -c 80)
  early_pg=$(echo "$resp_early" | jq -r --arg id "$H_LONG_UID" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)][0].chunkMetadata.page // "n/a"' 2>/dev/null)
  late_pg=$(echo "$resp_late" | jq -r --arg id "$H_LONG_UID" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)][0].chunkMetadata.page // "n/a"' 2>/dev/null)

  if [ -n "$early_text" ] && [ -n "$late_text" ] && [ "$early_text" != "$late_text" ]; then
    pass "H2: Long report yields different chunks for early vs late section queries"
    info "    Early (page=$early_pg): ${early_text}…"
    info "    Late  (page=$late_pg):  ${late_text}…"
  elif [ -n "$early_text" ] && [ "$early_text" = "$late_text" ]; then
    info "H2: Both long-report queries returned the same chunk text — may be a single large chunk"
  else
    fail "H2: Could not retrieve chunks from the long report for early/late queries"
  fi
fi

if [ -n "${H_SHORT_UID:-}" ] && [ -n "${H_TECH_UID:-}" ] && [ -n "${H_FIN_UID:-}" ]; then
  resp_fin=$(curl -sf -u "$NUXEO_AUTH" -X POST "$RAG_URL/search/semantic" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"$H_FIN_QUERY\",\"topK\":3,\"minScore\":0.4}" \
    2>/dev/null || echo '{}')
  top3_json=$(echo "$resp_fin" | jq -r '[.results[:3][]?.sourceDocument.nodeId] | join("\n")' 2>/dev/null || echo "")

  hr_in_top3=0
  tech_in_top3=0
  finance_in_top3=0
  if echo "$top3_json" | grep -q "${H_SHORT_UID:-__NONE__}"; then hr_in_top3=1; fi
  if echo "$top3_json" | grep -q "${H_TECH_UID:-__NONE__}"; then tech_in_top3=1; fi
  if echo "$top3_json" | grep -q "${H_FIN_UID:-__NONE__}"; then finance_in_top3=1; fi
  if [ -n "${H_LONG_UID:-}" ] && echo "$top3_json" | grep -q "${H_LONG_UID:-__NONE__}"; then finance_in_top3=1; fi

  if [ "$hr_in_top3" -eq 0 ] && [ "$tech_in_top3" -eq 0 ] && [ "$finance_in_top3" -eq 1 ]; then
    pass "H3: Finance query top-3 contains finance fixtures without HR or Tech bleed"
    info "    Top-3 nodeIds: $(echo "$top3_json" | head -3 | tr '\n' ' ')"
  else
    fail "H3: Finance query top-3 includes non-finance fixtures or missed the finance corpus"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION I — Scope Exclusion
# ═══════════════════════════════════════════════════════════════════════════════
section "I — Scope Exclusion"
info "Included root under test: $NUXEO_INCLUDED_ROOT"

I_IN_SCOPE_QUERY="nuxeo included root control document $TEST_RUN_TAG"
I_OUT_SCOPE_QUERY="nuxeo outside included root control document $TEST_RUN_TAG"
I_OUT_WORKSPACE="content-lake-out-of-scope-$TEST_RUN_TAG"
I_OUT_WORKSPACE_TITLE="Content Lake Out Of Scope $TEST_RUN_TAG"

I_IN_SCOPE_UID=$(create_demo_file "Nuxeo In-Scope Control $TEST_RUN_TAG" \
  "IN-SCOPE CONTROL DOCUMENT. Content: $I_IN_SCOPE_QUERY. This document lives under the configured included root.")
[ -n "$I_IN_SCOPE_UID" ] \
  && pass "I1: In-scope control document created under the included root (uid=$I_IN_SCOPE_UID)" \
  || fail "I1: Failed to create in-scope control document"

I_OUT_SCOPE_UID=$(create_demo_file "Nuxeo Out-Of-Scope Control $TEST_RUN_TAG" \
  "OUT-OF-SCOPE CONTROL DOCUMENT. Content: $I_OUT_SCOPE_QUERY. This document is intentionally outside the configured included root." \
  "$I_OUT_WORKSPACE" "$I_OUT_WORKSPACE_TITLE")
[ -n "$I_OUT_SCOPE_UID" ] \
  && pass "I2: Out-of-scope control document created in workspace $I_OUT_WORKSPACE (uid=$I_OUT_SCOPE_UID)" \
  || fail "I2: Failed to create out-of-scope control document"

run_nuxeo_sync_wait "I3" "I4" "Scope exclusion sync"
info "Waiting 30 s for scope exclusion results to settle …"
sleep 30

[ -n "${I_IN_SCOPE_UID:-}" ]  && rag_find_source "$I_IN_SCOPE_QUERY"  "$I_IN_SCOPE_UID"  "nuxeo" "I5" "In-scope control document remains indexed"
[ -n "${I_OUT_SCOPE_UID:-}" ] && rag_absent_uid  "$I_OUT_SCOPE_QUERY" "$I_OUT_SCOPE_UID"          "I6" "Out-of-scope control document stays absent from search"

# ═══════════════════════════════════════════════════════════════════════════════
#  Summary
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
printf "${B}══ Nuxeo Test Results ══${N}\n"
printf "${G}  Passed : %d${N}\n" "$PASS"
printf "${R}  Failed : %d${N}\n" "$FAIL"
printf "  Log    : %s\n" "$LOG"
echo ""

[ "$FAIL" -eq 0 ]
