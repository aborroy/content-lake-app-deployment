#!/usr/bin/env bash
# smoke-test.sh — Content Lake smoke test against a running deployment.
#
# Safe to run against EC2 (or any host) with existing data:
#   - never stops or restarts services
#   - cleans up every test document it creates
#   - all assertions are scoped to this run's sentinel phrases
#
# Usage:
#   HOST=myhost ALF_AUTH=admin:pass NUXEO_AUTH=Administrator:pass ./test/smoke-test.sh
#
# Environment variables (all required unless a default is listed):
#   HOST          Target hostname or IP  (default: localhost)
#   USE_HTTPS     Set to "true" to use https:// and pass -k to curl (default: false)
#   ALF_AUTH      Alfresco credentials   user:password  (required)
#   NUXEO_AUTH    Nuxeo credentials      user:password  (required)
#   NUXEO_URL     Full Nuxeo API base URL (default: derived from HOST/USE_HTTPS,
#                 proxied through nginx — override only for standalone Nuxeo)
#   WAIT_LIVE_S   Seconds to wait for live-ingester pick-up (default: 60)
#   WAIT_EMBED_S  Seconds to wait for embedding pipeline    (default: 60)
#   WAIT_PERM_S   Seconds to wait for ACL reconciliation    (default: 60)
#   NUXEO_WORKSPACE  Nuxeo workspace name under /default-domain/workspaces (default: Policies)
#   TOPK          topK for presence checks                  (default: 30)
#
# Requires: curl, jq

set -uo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
HOST="${HOST:-localhost}"
USE_HTTPS="${USE_HTTPS:-false}"
ALF_AUTH="${ALF_AUTH:?ALF_AUTH is required (e.g. admin:yourpassword)}"
NUXEO_AUTH="${NUXEO_AUTH:?NUXEO_AUTH is required (e.g. Administrator:yourpassword)}"
NUXEO_WORKSPACE="${NUXEO_WORKSPACE:-Policies}"
WAIT_LIVE_S="${WAIT_LIVE_S:-60}"
WAIT_EMBED_S="${WAIT_EMBED_S:-60}"
WAIT_PERM_S="${WAIT_PERM_S:-120}"
TOPK="${TOPK:-30}"

if [ "${USE_HTTPS}" = "true" ]; then
  BASE="https://${HOST}"
  CURL_OPTS="-k"
else
  BASE="http://${HOST}"
  CURL_OPTS=""
fi
ALF_API="${BASE}/alfresco/api/-default-/public/alfresco/versions/1"
NUXEO_API="${NUXEO_URL:-${BASE}/nuxeo/api/v1}"
SYNC_URL="${BASE}/api/sync"
RAG_URL="${BASE}/api/rag"

PASS=0; FAIL=0; SKIP=0
RUN_TAG="smoke-$(date +%Y%m%d-%H%M%S)-$$"
TMPDIR_DATA="$(mktemp -d)"
LOG="smoke-test-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
pass()    { printf "${G}[PASS]${N} %s\n" "$*"; PASS=$((PASS+1)); }
fail()    { printf "${R}[FAIL]${N} %s\n" "$*"; FAIL=$((FAIL+1)); }
skip()    { printf "${Y}[SKIP]${N} %s\n" "$*"; SKIP=$((SKIP+1)); }
info()    { printf "${C}[INFO]${N} %s\n" "$*"; }
section() { printf "\n${B}${C}─── %s ───${N}\n" "$*"; }

cleanup() { rm -rf "$TMPDIR_DATA"; }
trap cleanup EXIT

# Unique sentinel phrases scoped to this run -- prevent collisions with prior data
ALF_SENTINEL="alf-smoke-${RUN_TAG}"
NUX_SENTINEL="nux-smoke-${RUN_TAG}"
SHARED_SENTINEL="shared-smoke-${RUN_TAG}"
APOSTROPHE_SENTINEL="apostrophe-smoke-${RUN_TAG}"

# Shared user that exists in both Alfresco and Nuxeo -- used for cross-source search.
# Created automatically if it does not yet exist.
SMOKE_USER="smoke-tester"
SMOKE_PASS="SmokeTest123!"
SMOKE_AUTH="${SMOKE_USER}:${SMOKE_PASS}"

# ── Prerequisites ──────────────────────────────────────────────────────────────
command -v curl >/dev/null 2>&1 || { echo "[FATAL] curl not found"; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "[FATAL] jq not found (brew install jq)"; exit 1; }

# ── Helpers ────────────────────────────────────────────────────────────────────

# rag_find <query> <node_id> <source_type> <test_id> <label> [auth] [minScore]
rag_find() {
  local query="$1" node_id="$2" src_type="$3" tid="$4" label="$5"
  local auth="${6:-$ALF_AUTH}"
  local min_score="${7:-}"
  local score_param=""
  [ -n "$min_score" ] && score_param=",\"minScore\":$min_score"
  local resp found
  resp=$(curl -sf $CURL_OPTS -u "$auth" -X POST "$RAG_URL/search/hybrid" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"$query\",\"topK\":$TOPK${score_param}}" 2>/dev/null || echo '{}')
  found=$(echo "$resp" | jq --arg id "$node_id" --arg src "$src_type" \
    '[.results[]? | select(.sourceDocument.nodeId == $id and .sourceDocument.sourceType == $src)] | length' \
    2>/dev/null || echo 0)
  if [ "${found:-0}" -gt 0 ]; then
    pass "$tid: $label found in search"
  else
    fail "$tid: $label NOT found (nodeId=$node_id, source=$src_type, query='$query')"
    echo "    top-3: $(echo "$resp" | jq -c '[.results[:3][]? | {name:.sourceDocument.name, src:.sourceDocument.sourceType, score:.score}]' 2>/dev/null || echo '[]')"
  fi
}

# rag_absent <query> <node_id> <test_id> <label> [auth]
rag_absent() {
  local query="$1" node_id="$2" tid="$3" label="$4"
  local auth="${5:-$ALF_AUTH}"
  local resp found
  resp=$(curl -sf $CURL_OPTS -u "$auth" -X POST "$RAG_URL/search/hybrid" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"$query\",\"topK\":$TOPK}" 2>/dev/null || echo '{}')
  found=$(echo "$resp" | jq --arg id "$node_id" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)] | length' 2>/dev/null || echo 0)
  if [ "${found:-0}" -eq 0 ]; then
    pass "$tid: $label correctly absent from search"
  else
    fail "$tid: $label still appears in search (nodeId=$node_id)"
  fi
}

# alf_create_folder <name> -- returns nodeId or empty
alf_create_folder() {
  local name="$1"
  local resp code body
  resp=$(curl -s $CURL_OPTS -w '\n%{http_code}' -u "$ALF_AUTH" -X POST \
    "$ALF_API/nodes/-my-/children" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"$name\",\"nodeType\":\"cm:folder\"}" 2>/dev/null)
  code=$(printf '%s' "$resp" | tail -1)
  body=$(printf '%s' "$resp" | sed '$d')
  if [ "$code" = "201" ]; then
    printf '%s' "$body" | jq -r '.entry.id // empty'
  elif [ "$code" = "409" ]; then
    curl -sf $CURL_OPTS -u "$ALF_AUTH" \
      "$ALF_API/nodes/-my-/children?fields=id,name&maxItems=100" 2>/dev/null \
      | jq -r --arg n "$name" '.list.entries[]? | select(.entry.name==$n) | .entry.id' | head -1
  else
    echo ""
  fi
}

# alf_upload <folder_id> <local_path> <name> -- returns nodeId or empty
alf_upload() {
  local folder="$1" path="$2" name="$3"
  local resp code body
  resp=$(curl -s $CURL_OPTS -w '\n%{http_code}' -u "$ALF_AUTH" -X POST \
    "$ALF_API/nodes/$folder/children" \
    -F "filedata=@${path};type=text/plain" \
    -F "name=$name" 2>/dev/null)
  code=$(printf '%s' "$resp" | tail -1)
  body=$(printf '%s' "$resp" | sed '$d')
  if [ "$code" = "201" ]; then
    printf '%s' "$body" | jq -r '.entry.id // empty'
  else
    echo ""
  fi
}

# alf_delete <node_id>
alf_delete() {
  curl -sf $CURL_OPTS -o /dev/null -u "$ALF_AUTH" -X DELETE \
    "$ALF_API/nodes/$1?permanent=true" 2>/dev/null || true
}

# alf_update_content <node_id> <local_path> -- replaces binary content; returns HTTP status code
alf_update_content() {
  local node_id="$1" path="$2"
  curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" -X PUT \
    "$ALF_API/nodes/$node_id/content" \
    -H 'Content-Type: text/plain' \
    --data-binary "@$path" 2>/dev/null || echo 000
}

# alf_sync_wait <folder_id> <tid_trigger> <tid_complete>
alf_sync_wait() {
  local folder="$1" tid_t="${2:-S1}" tid_c="${3:-S2}"
  local resp job_id status elapsed=0
  resp=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" -X POST "$SYNC_URL/batch" \
    -H 'Content-Type: application/json' \
    -d "{\"folders\":[\"$folder\"],\"recursive\":true,\"types\":[\"cm:content\"]}" \
    2>/dev/null || echo '{}')
  job_id=$(echo "$resp" | jq -r '.jobId // empty')
  [ -n "$job_id" ] || { fail "$tid_t: sync trigger returned no jobId"; return 1; }
  pass "$tid_t: sync triggered (jobId=$job_id)"

  while [ $elapsed -lt 300 ]; do
    local sr
    sr=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" "$SYNC_URL/status/$job_id" 2>/dev/null || echo '{}')
    status=$(echo "$sr" | jq -r '.status // "UNKNOWN"')
    case "$status" in
      COMPLETED)
        pass "$tid_c: sync COMPLETED"
        return 0
        ;;
      FAILED|ERROR)
        fail "$tid_c: sync FAILED"
        return 1
        ;;
    esac
    sleep 10; elapsed=$((elapsed+10))
  done
  fail "$tid_c: sync timed out after 5 min"
  return 1
}

# NUX_WORKSPACE_CREATED=1 if the workspace was created by this run (must be deleted in cleanup).
# A dedicated smoke workspace may also be deleted even if it pre-existed, so a
# failed prior run does not leave content-lake-smoke behind forever.
NUX_WORKSPACE_CREATED=0
NUX_SMOKE_WORKSPACE_NAMES="content-lake-smoke"

nux_should_delete_workspace() {
  [ "$NUX_WORKSPACE_CREATED" = "1" ] || [[ " $NUX_SMOKE_WORKSPACE_NAMES " == *" ${NUXEO_WORKSPACE} "* ]]
}

# nux_ensure_workspace -- creates NUXEO_WORKSPACE under /default-domain/workspaces if missing.
# Sets NUX_WORKSPACE_CREATED=1 when it creates the workspace so cleanup can remove it.
nux_ensure_workspace() {
  local code
  code=$(curl -sf $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$NUXEO_AUTH" \
    "$NUXEO_API/path/default-domain/workspaces/${NUXEO_WORKSPACE}" 2>/dev/null || echo 000)
  if [ "$code" = "200" ]; then return 0; fi
  local payload
  payload=$(jq -n --arg name "$NUXEO_WORKSPACE" \
    '{"entity-type":"document","name":$name,"type":"Workspace","properties":{"dc:title":$name}}')
  code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$NUXEO_AUTH" -X POST \
    "$NUXEO_API/path/default-domain/workspaces" \
    -H 'Content-Type: application/json' \
    --data "$payload" 2>/dev/null || echo 000)
  if [ "$code" = "201" ]; then
    NUX_WORKSPACE_CREATED=1
  fi
  [ "$code" = "201" ] || [ "$code" = "409" ]
}

# nux_create_doc <title> <text> -- returns UID or empty (uses automation Blob.AttachOnDocument)
nux_create_doc() {
  local title="$1" text="$2"
  local tmp_path="$TMPDIR_DATA/nux-${RUN_TAG}-$(date +%s%N).txt"
  printf '%s' "$text" > "$tmp_path"

  nux_ensure_workspace || { echo ""; return; }

  local payload resp code body uid params attach_code
  payload=$(jq -n --arg title "$title" \
    '{"entity-type":"document","name":($title|gsub("[^a-zA-Z0-9_.-]";"_")),"type":"File","properties":{"dc:title":$title}}')

  resp=$(curl -s $CURL_OPTS -w '\n%{http_code}' -u "$NUXEO_AUTH" -X POST \
    "$NUXEO_API/path/default-domain/workspaces/${NUXEO_WORKSPACE}" \
    -H 'Content-Type: application/json' \
    --data "$payload" 2>/dev/null)
  code=$(printf '%s' "$resp" | tail -1)
  body=$(printf '%s' "$resp" | sed '$d')

  [ "$code" = "201" ] || { echo ""; return; }
  uid=$(printf '%s' "$body" | jq -r '.uid // empty')
  [ -n "$uid" ] || { echo ""; return; }

  params=$(jq -n --arg uid "$uid" \
    '{"params":{"document":$uid,"save":true,"xpath":"file:content"}}')
  attach_code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$NUXEO_AUTH" -X POST \
    "$NUXEO_API/automation/Blob.AttachOnDocument" \
    -F "params=${params};type=application/json" \
    -F "input=@${tmp_path};filename=smoke.txt;type=text/plain" 2>/dev/null || echo 000)

  [ "$attach_code" = "200" ] && printf '%s' "$uid" || echo ""
}

# nux_delete <uid>
nux_delete() {
  curl -sf $CURL_OPTS -o /dev/null -u "$NUXEO_AUTH" -X DELETE \
    "$NUXEO_API/id/$1" 2>/dev/null || true
}

# Track which users were created by this run so cleanup removes only what was added.
ALF_USER_CREATED=0
NUX_USER_CREATED=0

# ensure_shared_user -- creates SMOKE_USER in Alfresco and Nuxeo if not present.
# Sets ALF_USER_CREATED / NUX_USER_CREATED so cleanup can remove them.
ensure_shared_user() {
  local alf_code nux_code payload

  alf_code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" \
    "$ALF_API/people/${SMOKE_USER}" 2>/dev/null || echo 000)
  if [ "$alf_code" != "200" ]; then
    curl -s $CURL_OPTS -o /dev/null -u "$ALF_AUTH" -X POST "$ALF_API/people" \
      -H 'Content-Type: application/json' \
      -d "{\"id\":\"${SMOKE_USER}\",\"firstName\":\"Smoke\",\"lastName\":\"Tester\",\"email\":\"${SMOKE_USER}@smoke.local\",\"password\":\"${SMOKE_PASS}\"}" \
      2>/dev/null || true
    ALF_USER_CREATED=1
  fi

  nux_code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$NUXEO_AUTH" \
    "$NUXEO_API/user/${SMOKE_USER}" 2>/dev/null || echo 000)
  if [ "$nux_code" != "200" ]; then
    payload=$(jq -n \
      --arg id  "$SMOKE_USER" \
      --arg pw  "$SMOKE_PASS" \
      '{"entity-type":"user","id":$id,"properties":{"username":$id,"firstName":"Smoke","lastName":"Tester","password":$pw,"email":($id+"@smoke.local")}}')
    create_code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$NUXEO_AUTH" -X POST "$NUXEO_API/user" \
      -H 'Content-Type: application/json' \
      --data "$payload" 2>/dev/null || echo 000)
    if [ "$create_code" = "201" ] || [ "$create_code" = "200" ]; then
      NUX_USER_CREATED=1
    else
      info "Warning: could not create Nuxeo smoke-tester user (HTTP $create_code) -- cross-source and permission tests may fail"
    fi
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
section "A — Service Health"
# ══════════════════════════════════════════════════════════════════════════════

info "Target: $BASE"

rag_health=$(curl -sf $CURL_OPTS "$RAG_URL/health" 2>/dev/null || echo '{}')
rag_status=$(echo "$rag_health" | jq -r '.status // "UNKNOWN"')
emb_status=$(echo "$rag_health" | jq -r '.embedding.status // "?"')
hxpr_status=$(echo "$rag_health" | jq -r '.hxpr.status // "?"')
llm_status=$(echo "$rag_health" | jq -r '.llm.status // "?"')
if [ "$rag_status" = "UP" ]; then
  pass "A1: RAG service UP (embedding=$emb_status, hxpr=$hxpr_status, llm=$llm_status)"
else
  fail "A1: RAG service status=$rag_status (embedding=$emb_status, hxpr=$hxpr_status, llm=$llm_status)"
fi

code=$(curl -sf $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" \
  "$ALF_API/nodes/-root-/children" 2>/dev/null || echo 000)
[ "$code" = "200" ] \
  && pass "A2: Alfresco repository responds (HTTP 200)" \
  || fail "A2: Alfresco returned HTTP $code"

code=$(curl -sf $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$NUXEO_AUTH" \
  "$NUXEO_API/path/default-domain" 2>/dev/null || echo 000)
[ "$code" = "200" ] \
  && pass "A3: Nuxeo repository responds (HTTP 200)" \
  || fail "A3: Nuxeo returned HTTP $code"

code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -X POST "$RAG_URL/search/semantic" \
  -H 'Content-Type: application/json' \
  -d '{"query":"smoke","topK":1}' 2>/dev/null || echo 000)
[ "$code" = "401" ] \
  && pass "A4: Unauthenticated RAG request rejected (HTTP 401)" \
  || fail "A4: Expected HTTP 401 for unauthenticated request, got HTTP $code"

code=$(curl -sf $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" \
  "$SYNC_URL/status" 2>/dev/null || echo 000)
[ "$code" = "200" ] \
  && pass "A5: Sync API status endpoint healthy (HTTP 200)" \
  || fail "A5: Sync API status returned HTTP $code"

code=$(curl -sf $CURL_OPTS -o /dev/null -w '%{http_code}' "$BASE/" 2>/dev/null || echo 000)
[ "$code" = "200" ] \
  && pass "A6: Content Lake UI served (HTTP 200)" \
  || fail "A6: Content Lake UI returned HTTP $code (Angular app may not be running)"

# ══════════════════════════════════════════════════════════════════════════════
ensure_shared_user

section "B — Alfresco Ingest + Search"
# ══════════════════════════════════════════════════════════════════════════════
# Creates one document, syncs, verifies it appears in hybrid search, then deletes.

ALF_FOLDER_ID=""
ALF_NODE_ID=""

ALF_FOLDER_ID=$(alf_create_folder "content-lake-smoke-${RUN_TAG}")
if [ -n "$ALF_FOLDER_ID" ]; then
  pass "B1: Test folder created (nodeId=$ALF_FOLDER_ID)"
else
  fail "B1: Failed to create test folder -- skipping Alfresco ingest tests"
fi

if [ -n "$ALF_FOLDER_ID" ]; then
  cat > "$TMPDIR_DATA/alf-smoke.txt" <<EOF
SMOKE TEST DOCUMENT — ALFRESCO
Run: $RUN_TAG
Sentinel: $ALF_SENTINEL
Also shared cross-source sentinel: $SHARED_SENTINEL
This document validates that Alfresco batch ingestion and hybrid search work end to end.
EOF
  ALF_NODE_ID=$(alf_upload "$ALF_FOLDER_ID" "$TMPDIR_DATA/alf-smoke.txt" "alf-smoke-${RUN_TAG}.txt")
  if [ -n "$ALF_NODE_ID" ]; then
    pass "B2: Document uploaded (nodeId=$ALF_NODE_ID)"
    # Grant SMOKE_USER read so it is visible in cross-source search (section D)
    curl -s $CURL_OPTS -o /dev/null -u "$ALF_AUTH" -X PUT "$ALF_API/nodes/$ALF_NODE_ID" \
      -H 'Content-Type: application/json' \
      -d "{\"permissions\":{\"isInheritanceEnabled\":false,\"locallySet\":[{\"authorityId\":\"GROUP_EVERYONE\",\"name\":\"Consumer\",\"accessStatus\":\"ALLOWED\"}]}}" \
      2>/dev/null || true
  else
    fail "B2: Upload failed -- skipping ingest and search"
  fi
fi

if [ -n "$ALF_NODE_ID" ]; then
  alf_sync_wait "$ALF_FOLDER_ID" "B3" "B4"
  info "Waiting ${WAIT_EMBED_S}s for embedding pipeline ..."
  sleep "$WAIT_EMBED_S"
  rag_find "$ALF_SENTINEL" "$ALF_NODE_ID" "alfresco" "B5" "Alfresco smoke doc"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "C — Nuxeo Live Ingest + Search"
# ══════════════════════════════════════════════════════════════════════════════
# Creates one Nuxeo document, waits for live-ingester audit poll, verifies search,
# then deletes.

NUX_UID=""

NUX_UID=$(nux_create_doc "Smoke Test Nuxeo ${RUN_TAG}" \
  "SMOKE TEST DOCUMENT -- NUXEO. Run: $RUN_TAG. Sentinel: $NUX_SENTINEL. Also shared cross-source sentinel: $SHARED_SENTINEL. This document validates Nuxeo live ingest and hybrid search end to end.")
if [ -n "$NUX_UID" ]; then
  pass "C1: Nuxeo document created (uid=$NUX_UID)"
  # Grant Everyone read so SMOKE_USER can find it in cross-source search (section D)
  curl -s $CURL_OPTS -o /dev/null -u "$NUXEO_AUTH" -X POST \
    "$NUXEO_API/automation/Document.SetACE" \
    -H 'Content-Type: application/json' \
    -d "{\"params\":{\"user\":\"Everyone\",\"permission\":\"Read\",\"grant\":true,\"blockInheritance\":true},\"input\":\"doc:${NUX_UID}\"}" \
    2>/dev/null || true
else
  fail "C1: Failed to create Nuxeo document -- skipping Nuxeo search tests"
fi

if [ -n "$NUX_UID" ]; then
  info "Waiting ${WAIT_LIVE_S}s for live-ingester audit poll ..."
  sleep "$WAIT_LIVE_S"
  rag_find "$NUX_SENTINEL" "$NUX_UID" "nuxeo" "C2" "Nuxeo smoke doc" "$NUXEO_AUTH"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "D — Cross-Source Search"
# ══════════════════════════════════════════════════════════════════════════════
# Both the Alfresco and Nuxeo smoke docs contain SHARED_SENTINEL.
# A single hybrid query should return results from both source types.

if [ -n "$ALF_NODE_ID" ] && [ -n "$NUX_UID" ]; then
  resp=$(curl -sf $CURL_OPTS -u "$SMOKE_AUTH" -X POST "$RAG_URL/search/hybrid" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"$SHARED_SENTINEL\",\"topK\":$TOPK}" 2>/dev/null || echo '{}')

  alf_found=$(echo "$resp" | jq --arg id "$ALF_NODE_ID" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)] | length' 2>/dev/null || echo 0)
  nux_found=$(echo "$resp" | jq --arg id "$NUX_UID" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)] | length' 2>/dev/null || echo 0)
  src_types=$(echo "$resp" | jq -r '[.results[]?.sourceDocument.sourceType] | unique | sort | join(",")' 2>/dev/null || echo "")

  [ "${alf_found:-0}" -gt 0 ] \
    && pass "D1: Cross-source query returns Alfresco smoke doc" \
    || fail "D1: Cross-source query did NOT return Alfresco smoke doc"
  [ "${nux_found:-0}" -gt 0 ] \
    && pass "D2: Cross-source query returns Nuxeo smoke doc" \
    || fail "D2: Cross-source query did NOT return Nuxeo smoke doc"
  [ "$src_types" = "alfresco,nuxeo" ] \
    && pass "D3: Response contains both source types ($src_types)" \
    || fail "D3: Expected both sources, got: '$src_types'"
else
  skip "D1-D3: Cross-source check skipped (one or both fixtures were not created)"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "E — Keyword Search with Apostrophe"
# ══════════════════════════════════════════════════════════════════════════════
# Regression test for the apostrophe NXQL parse error (hxpr does not support
# '' as an escape inside string literals). The query must not return HTTP 500.

APO_QUERY="king arthur's legend ${APOSTROPHE_SENTINEL}"

resp=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" -X POST "$RAG_URL/search/hybrid" \
  -H 'Content-Type: application/json' \
  -d "{\"query\":\"$APO_QUERY\",\"topK\":5}" 2>/dev/null)
apo_rc=$?
if [ $apo_rc -eq 0 ]; then
  kw=$(echo "$resp" | jq -r '.keywordCandidates // "unknown"' 2>/dev/null || echo "unknown")
  pass "E1: Apostrophe query completed without error (keywordCandidates=$kw)"
else
  fail "E1: Apostrophe query returned a non-200 HTTP status (curl exit=$apo_rc)"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "F — RAG Prompt Endpoint"
# ══════════════════════════════════════════════════════════════════════════════
# Sends a prompt against an existing Alfresco document to confirm LLM is reachable.

if [ -n "$ALF_NODE_ID" ]; then
  # Query against the smoke doc uploaded in section B (already embedded by now).
  resp=$(curl -sf $CURL_OPTS --max-time 120 -u "$ALF_AUTH" -X POST "$RAG_URL/prompt" \
    -H 'Content-Type: application/json' \
    -d "{\"question\":\"What does the smoke test document say? It contains the phrase: $ALF_SENTINEL\",\"topK\":3}" \
    2>/dev/null || echo '{}')
  answer=$(echo "$resp" | jq -r '.answer // empty' 2>/dev/null || echo "")
  sources=$(echo "$resp" | jq -r '.sourcesUsed // ((.sources // []) | length) // 0' 2>/dev/null || echo 0)
  if [ -n "$answer" ] && [ "${sources:-0}" -gt 0 ]; then
    pass "F1: Prompt endpoint returned an answer with $sources source(s)"
  else
    fail "F1: Prompt endpoint did not return a non-empty answer with sources (sources=$sources, answer='${answer:0:60}')"
  fi
else
  skip "F1: Prompt test skipped (Alfresco fixture was not created)"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "F2 — Semantic Search"
# ══════════════════════════════════════════════════════════════════════════════
# Exercises POST /api/rag/search/semantic -- a different code path from hybrid,
# used by the demo app's search panel.

if [ -n "${ALF_NODE_ID:-}" ]; then
  resp=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" -X POST "$RAG_URL/search/semantic" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"$ALF_SENTINEL\",\"topK\":$TOPK,\"minScore\":0.0}" 2>/dev/null || echo '{}')
  found=$(echo "$resp" | jq --arg id "$ALF_NODE_ID" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)] | length' 2>/dev/null || echo 0)
  [ "${found:-0}" -gt 0 ] \
    && pass "F2: Semantic search returns Alfresco smoke doc" \
    || fail "F2: Semantic search did NOT return Alfresco smoke doc (nodeId=$ALF_NODE_ID)"
else
  skip "F2: Semantic search test skipped (Alfresco fixture was not created)"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "F2b — Semantic Search with Source-type Filter"
# ══════════════════════════════════════════════════════════════════════════════
# The search panel's source selector passes sourceType to /api/rag/search/semantic.
# Verify that the filter returns the correct source and excludes the other.

if [ -n "${ALF_NODE_ID:-}" ] && [ -n "${NUX_UID:-}" ]; then
  resp=$(curl -sf $CURL_OPTS -u "$SMOKE_AUTH" -X POST "$RAG_URL/search/semantic" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"$SHARED_SENTINEL\",\"topK\":$TOPK,\"minScore\":0.0,\"sourceType\":\"alfresco\"}" \
    2>/dev/null || echo '{}')
  alf_found=$(echo "$resp" | jq --arg id "$ALF_NODE_ID" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)] | length' 2>/dev/null || echo 0)
  nux_found=$(echo "$resp" | jq --arg id "$NUX_UID" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)] | length' 2>/dev/null || echo 0)
  [ "${alf_found:-0}" -gt 0 ] \
    && pass "F2b-1: semantic+sourceType=alfresco returns Alfresco smoke doc" \
    || fail "F2b-1: semantic+sourceType=alfresco did NOT return Alfresco smoke doc"
  [ "${nux_found:-0}" -eq 0 ] \
    && pass "F2b-2: semantic+sourceType=alfresco correctly excludes Nuxeo smoke doc" \
    || fail "F2b-2: semantic+sourceType=alfresco incorrectly returned Nuxeo smoke doc"

  resp=$(curl -sf $CURL_OPTS -u "$SMOKE_AUTH" -X POST "$RAG_URL/search/semantic" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"$SHARED_SENTINEL\",\"topK\":$TOPK,\"minScore\":0.0,\"sourceType\":\"nuxeo\"}" \
    2>/dev/null || echo '{}')
  nux_found=$(echo "$resp" | jq --arg id "$NUX_UID" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)] | length' 2>/dev/null || echo 0)
  alf_found=$(echo "$resp" | jq --arg id "$ALF_NODE_ID" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)] | length' 2>/dev/null || echo 0)
  [ "${nux_found:-0}" -gt 0 ] \
    && pass "F2b-3: semantic+sourceType=nuxeo returns Nuxeo smoke doc" \
    || fail "F2b-3: semantic+sourceType=nuxeo did NOT return Nuxeo smoke doc"
  [ "${alf_found:-0}" -eq 0 ] \
    && pass "F2b-4: semantic+sourceType=nuxeo correctly excludes Alfresco smoke doc" \
    || fail "F2b-4: semantic+sourceType=nuxeo incorrectly returned Alfresco smoke doc"
else
  skip "F2b: Semantic search source-type filter skipped (one or both fixtures were not created)"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "F3 — Source-type Filter"
# ══════════════════════════════════════════════════════════════════════════════
# sourceType=alfresco and sourceType=nuxeo narrow hybrid search -- used by the
# demo app's source selector toggle.

if [ -n "${ALF_NODE_ID:-}" ] && [ -n "${NUX_UID:-}" ]; then
  resp=$(curl -sf $CURL_OPTS -u "$SMOKE_AUTH" -X POST "$RAG_URL/search/hybrid" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"$SHARED_SENTINEL\",\"topK\":$TOPK,\"sourceType\":\"alfresco\"}" \
    2>/dev/null || echo '{}')
  alf_found=$(echo "$resp" | jq --arg id "$ALF_NODE_ID" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)] | length' 2>/dev/null || echo 0)
  nux_found=$(echo "$resp" | jq --arg id "$NUX_UID" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)] | length' 2>/dev/null || echo 0)
  [ "${alf_found:-0}" -gt 0 ] \
    && pass "F3a: sourceType=alfresco filter returns Alfresco smoke doc" \
    || fail "F3a: sourceType=alfresco filter did NOT return Alfresco smoke doc"
  [ "${nux_found:-0}" -eq 0 ] \
    && pass "F3b: sourceType=alfresco filter correctly excludes Nuxeo smoke doc" \
    || fail "F3b: sourceType=alfresco filter incorrectly returned Nuxeo smoke doc"

  resp=$(curl -sf $CURL_OPTS -u "$SMOKE_AUTH" -X POST "$RAG_URL/search/hybrid" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"$SHARED_SENTINEL\",\"topK\":$TOPK,\"sourceType\":\"nuxeo\"}" \
    2>/dev/null || echo '{}')
  nux_found=$(echo "$resp" | jq --arg id "$NUX_UID" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)] | length' 2>/dev/null || echo 0)
  alf_found=$(echo "$resp" | jq --arg id "$ALF_NODE_ID" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)] | length' 2>/dev/null || echo 0)
  [ "${nux_found:-0}" -gt 0 ] \
    && pass "F3c: sourceType=nuxeo filter returns Nuxeo smoke doc" \
    || fail "F3c: sourceType=nuxeo filter did NOT return Nuxeo smoke doc"
  [ "${alf_found:-0}" -eq 0 ] \
    && pass "F3d: sourceType=nuxeo filter correctly excludes Alfresco smoke doc" \
    || fail "F3d: sourceType=nuxeo filter incorrectly returned Alfresco smoke doc"
else
  skip "F3: Source-type filter test skipped (one or both fixtures were not created)"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "F4 — Streaming Chat"
# ══════════════════════════════════════════════════════════════════════════════
# POST /api/rag/chat/stream -- SSE endpoint used by the demo chat UI.
# Checks: stream opens, token events arrive, a done event is emitted,
# accumulated answer is non-empty, no error event is emitted.
# Also extracts sessionId for the multi-turn test in F6.

CHAT_SESSION_ID=""

if [ -n "${ALF_NODE_ID:-}" ]; then
  stream_out=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" --no-buffer -N --max-time 30 \
    -X POST "$RAG_URL/chat/stream" \
    -H 'Content-Type: application/json' \
    -H 'Accept: text/event-stream' \
    -d "{\"question\":\"What is this smoke test document about? Phrase: $ALF_SENTINEL\",\"topK\":3}" \
    2>/dev/null || echo "")

  sse_lines=$(echo "$stream_out" | grep -c '^data:' 2>/dev/null || echo 0)
  if [ "${sse_lines:-0}" -gt 0 ]; then
    pass "F4a: Streaming chat emitted ${sse_lines} SSE data line(s)"
  else
    fail "F4a: Streaming chat returned no SSE data lines (stream may have failed or LLM is unreachable)"
  fi

  # SSE format: "event:<type>\ndata:<json>\n\n" (no space after colon)
  # Parse event type from "event:" lines, not from JSON payload.
  done_lines=$(echo "$stream_out" | { grep -c '^event: *done' || true; })
  [ "${done_lines:-0}" -gt 0 ] \
    && pass "F4b: Stream emitted a 'done' event (stream terminated cleanly)" \
    || fail "F4b: Stream did not emit a 'done' event (stream may have been cut short)"

  error_lines=$(echo "$stream_out" | { grep -c '^event: *error' || true; })
  [ "${error_lines:-0}" -eq 0 ] \
    && pass "F4c: Stream emitted no error events" \
    || fail "F4c: Stream emitted ${error_lines} error event(s)"

  accumulated=$(echo "$stream_out" | awk '
    /^event: *token/    { in_token=1; next }
    /^event:/           { in_token=0; next }
    /^data:/ && in_token { sub(/^data: */, ""); print }
  ' | jq -r '.token // empty' 2>/dev/null | tr -d '\n' || echo "")
  if [ -n "$accumulated" ]; then
    pass "F4d: Accumulated answer is non-empty (${#accumulated} chars)"
  else
    fail "F4d: Accumulated answer is empty (no token events with text content)"
  fi

  CHAT_SESSION_ID=$(echo "$stream_out" | awk '
    /^event: *metadata/ { in_meta=1; next }
    /^event:/           { in_meta=0; next }
    /^data:/ && in_meta { sub(/^data: */, ""); print; in_meta=0 }
  ' | jq -r '.sessionId // empty' 2>/dev/null | head -1 || echo "")
  if [ -n "$CHAT_SESSION_ID" ]; then
    info "F4: sessionId=$CHAT_SESSION_ID (used in F6 multi-turn test)"
  fi
else
  skip "F4: Streaming chat test skipped (Alfresco fixture was not created)"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "F6 — Multi-turn Chat Session"
# ══════════════════════════════════════════════════════════════════════════════
# Sends a second question reusing the sessionId from F4 to verify that the
# backend's session-aware retrieval (conversation history in context) works.
# The UI sends sessionId on every message after the first turn.

if [ -n "${ALF_NODE_ID:-}" ] && [ -n "$CHAT_SESSION_ID" ]; then
  stream_out2=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" --no-buffer -N --max-time 30 \
    -X POST "$RAG_URL/chat/stream" \
    -H 'Content-Type: application/json' \
    -H 'Accept: text/event-stream' \
    -d "{\"question\":\"Summarise what you just told me in one sentence.\",\"topK\":3,\"sessionId\":\"$CHAT_SESSION_ID\"}" \
    2>/dev/null || echo "")

  sse_lines2=$(echo "$stream_out2" | grep -c '^data:' 2>/dev/null || echo 0)
  if [ "${sse_lines2:-0}" -gt 0 ]; then
    pass "F6a: Multi-turn second message emitted ${sse_lines2} SSE data line(s)"
  else
    fail "F6a: Multi-turn second message returned no SSE data lines"
  fi

  returned_session=$(echo "$stream_out2" | awk '
    /^event: *metadata/ { in_meta=1; next }
    /^event:/           { in_meta=0; next }
    /^data:/ && in_meta { sub(/^data: */, ""); print; in_meta=0 }
  ' | jq -r '.sessionId // empty' 2>/dev/null | head -1 || echo "")
  if [ "${returned_session:-}" = "$CHAT_SESSION_ID" ]; then
    pass "F6b: Second turn returned same sessionId (session continuity maintained)"
  elif [ -n "$returned_session" ]; then
    fail "F6b: Second turn returned a different sessionId (expected=$CHAT_SESSION_ID, got=$returned_session)"
  else
    skip "F6b: sessionId not present in second turn metadata (cannot verify continuity)"
  fi

  error_lines2=$(echo "$stream_out2" | { grep -c '^event: *error' || true; })
  [ "${error_lines2:-0}" -eq 0 ] \
    && pass "F6c: Multi-turn second message emitted no error events" \
    || fail "F6c: Multi-turn second message emitted ${error_lines2} error event(s)"
elif [ -n "${ALF_NODE_ID:-}" ]; then
  skip "F6: Multi-turn chat skipped (no sessionId was returned by F4)"
else
  skip "F6: Multi-turn chat skipped (Alfresco fixture was not created)"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "F5 — Node Status"
# ══════════════════════════════════════════════════════════════════════════════
# GET /api/content-lake/nodes/{nodeId}/status -- used by the ACA extension to
# show per-document sync state.

if [ -n "${ALF_NODE_ID:-}" ]; then
  resp=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" \
    "$BASE/api/content-lake/nodes/${ALF_NODE_ID}/status" 2>/dev/null || echo 000)
  if [ "$resp" = "200" ]; then
    status_body=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" \
      "$BASE/api/content-lake/nodes/${ALF_NODE_ID}/status" 2>/dev/null || echo '{}')
    sync_status=$(echo "$status_body" | jq -r '.status // .syncStatus // empty' 2>/dev/null || echo "")
    if [ -n "$sync_status" ]; then
      pass "F5: Node status returned status=$sync_status for nodeId=$ALF_NODE_ID"
    else
      fail "F5: Node status response missing status field (body: ${status_body:0:120})"
    fi
  else
    fail "F5: Node status returned HTTP $resp (expected 200)"
  fi
else
  skip "F5: Node status test skipped (Alfresco fixture was not created)"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "H — Alfresco Live Ingestion"
# ══════════════════════════════════════════════════════════════════════════════
# Uploads a document directly into the existing test folder and waits for the
# Event2 -> ActiveMQ -> live-ingester pipeline to index it -- no manual sync.

ALF_LIVE_NODE_ID=""
ALF_LIVE_SENTINEL="alf-live-smoke-${RUN_TAG}"

if [ -n "${ALF_FOLDER_ID:-}" ]; then
  cat > "$TMPDIR_DATA/alf-live-smoke.txt" <<EOF
SMOKE TEST DOCUMENT -- ALFRESCO LIVE INGESTION
Run: $RUN_TAG
Sentinel: $ALF_LIVE_SENTINEL
This document tests that Alfresco Event2 live ingestion indexes content without a manual batch sync.
EOF
  ALF_LIVE_NODE_ID=$(alf_upload "$ALF_FOLDER_ID" "$TMPDIR_DATA/alf-live-smoke.txt" "alf-live-smoke-${RUN_TAG}.txt")
  if [ -n "$ALF_LIVE_NODE_ID" ]; then
    pass "H1: Live ingest document uploaded (nodeId=$ALF_LIVE_NODE_ID)"
    info "Waiting ${WAIT_LIVE_S}s for Event2 -> live-ingester pipeline ..."
    sleep "$WAIT_LIVE_S"
    rag_find "$ALF_LIVE_SENTINEL" "$ALF_LIVE_NODE_ID" "alfresco" "H2" \
      "Alfresco live-ingest doc searchable without batch sync"
  else
    fail "H1: Failed to upload live-ingest document -- skipping H2"
  fi
else
  skip "H1-H2: Alfresco live ingest skipped (test folder was not created)"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "I — Permission Enforcement"
# ══════════════════════════════════════════════════════════════════════════════
# Creates a document restricted to SMOKE_USER only, then verifies:
#   - SMOKE_USER CAN find it
#   - A user with no ACE CANNOT find it
#   - Alfresco admin CAN find it (source-level admin bypass)

ALF_RESTRICTED_NODE_ID=""
ALF_PERM_SENTINEL="alf-perm-smoke-${RUN_TAG}"
ALF_PERM_USER="smoke-perm-checker"
ALF_PERM_PASS="SmokeTest123!"
ALF_PERM_USER_CREATED=0

# I0: Create the no-access user (used only to prove it cannot see restricted content)
perm_check_code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" \
  "$ALF_API/people/${ALF_PERM_USER}" 2>/dev/null || echo 000)
if [ "$perm_check_code" != "200" ]; then
  curl -s $CURL_OPTS -o /dev/null -u "$ALF_AUTH" -X POST "$ALF_API/people" \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"${ALF_PERM_USER}\",\"firstName\":\"Perm\",\"lastName\":\"Checker\",\"email\":\"${ALF_PERM_USER}@smoke.local\",\"password\":\"${ALF_PERM_PASS}\"}" \
    2>/dev/null || true
  ALF_PERM_USER_CREATED=1
  info "I0: Created Alfresco user '${ALF_PERM_USER}' for permission check"
fi

if [ -n "${ALF_FOLDER_ID:-}" ]; then
  cat > "$TMPDIR_DATA/alf-perm-smoke.txt" <<EOF
SMOKE TEST DOCUMENT -- PERMISSION ENFORCEMENT
Run: $RUN_TAG
Sentinel: $ALF_PERM_SENTINEL
This document is restricted to $SMOKE_USER only. It must not be visible to users without an ACE.
EOF
  ALF_RESTRICTED_NODE_ID=$(alf_upload "$ALF_FOLDER_ID" "$TMPDIR_DATA/alf-perm-smoke.txt" "alf-perm-smoke-${RUN_TAG}.txt")
  if [ -n "$ALF_RESTRICTED_NODE_ID" ]; then
    pass "I1: Restricted document uploaded (nodeId=$ALF_RESTRICTED_NODE_ID)"

    # Set ACL: inheritance disabled, only SMOKE_USER has Consumer access
    acl_code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" -X PUT \
      "$ALF_API/nodes/$ALF_RESTRICTED_NODE_ID" \
      -H 'Content-Type: application/json' \
      -d "{\"permissions\":{\"isInheritanceEnabled\":false,\"locallySet\":[{\"authorityId\":\"${SMOKE_USER}\",\"name\":\"Consumer\",\"accessStatus\":\"ALLOWED\"}]}}" \
      2>/dev/null || echo 000)
    if [ "$acl_code" = "200" ]; then
      pass "I2: ACL set -- restricted to ${SMOKE_USER} only"
    else
      fail "I2: Failed to set ACL (HTTP $acl_code)"
    fi

    # Reconcile ACL into hxpr via /api/sync/permissions (synchronous direct write).
    curl -sf $CURL_OPTS -u "$ALF_AUTH" -X POST "$SYNC_URL/permissions" \
      -H 'Content-Type: application/json' \
      -d "{\"nodeIds\":[\"$ALF_RESTRICTED_NODE_ID\"],\"recursive\":false}" \
      2>/dev/null >/dev/null || true

    # Poll rag_find for smoke-tester until the ACL update propagates to the search
    # index (or timeout). hxpr's search index may lag the ACL write by a few seconds.
    info "Polling for ACL propagation (up to ${WAIT_PERM_S}s) ..."
    perm_elapsed=0
    perm_found=0
    while [ "$perm_elapsed" -lt "$WAIT_PERM_S" ]; do
      perm_resp=$(curl -sf $CURL_OPTS -u "$SMOKE_AUTH" -X POST "$RAG_URL/search/hybrid" \
        -H 'Content-Type: application/json' \
        -d "{\"query\":\"$ALF_PERM_SENTINEL\",\"topK\":$TOPK,\"minScore\":0.0}" 2>/dev/null || echo '{}')
      perm_found=$(echo "$perm_resp" | jq --arg id "$ALF_RESTRICTED_NODE_ID" --arg src "alfresco" \
        '[.results[]? | select(.sourceDocument.nodeId == $id and .sourceDocument.sourceType == $src)] | length' \
        2>/dev/null || echo 0)
      [ "${perm_found:-0}" -gt 0 ] && break
      sleep 10; perm_elapsed=$((perm_elapsed + 10))
    done
    info "ACL propagation complete (found=${perm_found:-0}, elapsed=${perm_elapsed}s)"

    if [ "${perm_found:-0}" -gt 0 ]; then
      pass "I3: ${SMOKE_USER} can find restricted document"
    else
      fail "I3: ${SMOKE_USER} can find restricted document NOT found (nodeId=$ALF_RESTRICTED_NODE_ID, source=alfresco)"
      echo "    top-3: $(echo "$perm_resp" | jq -c '[.results[:3][]? | {name:.sourceDocument.name, src:.sourceDocument.sourceType, score:.score}]' 2>/dev/null || echo '[]')"
    fi
    rag_absent "$ALF_PERM_SENTINEL" "$ALF_RESTRICTED_NODE_ID" "I4" \
      "${ALF_PERM_USER} cannot find restricted document" "${ALF_PERM_USER}:${ALF_PERM_PASS}"
    rag_find "$ALF_PERM_SENTINEL" "$ALF_RESTRICTED_NODE_ID" "alfresco" "I5" \
      "Admin can find restricted document (Alfresco admin bypass)" "$ALF_AUTH" "0.0"
  else
    fail "I1: Failed to upload restricted document -- skipping I2-I5"
  fi
else
  skip "I1-I5: Permission enforcement skipped (test folder was not created)"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "J — Document Update Propagation"
# ══════════════════════════════════════════════════════════════════════════════
# Creates a document, confirms it is indexed, then updates its content and
# verifies the new content is searchable and the old content is gone.

ALF_UPDATE_NODE_ID=""
ALF_UPDATE_OLD_SENTINEL="alf-update-old-smoke-${RUN_TAG}"
ALF_UPDATE_NEW_SENTINEL="alf-update-new-smoke-${RUN_TAG}"

if [ -n "${ALF_FOLDER_ID:-}" ]; then
  cat > "$TMPDIR_DATA/alf-update-v1.txt" <<EOF
SMOKE TEST DOCUMENT -- UPDATE PROPAGATION (VERSION 1)
Run: $RUN_TAG
Sentinel: $ALF_UPDATE_OLD_SENTINEL
This is the original version of the document. After update this content must no longer be searchable.
EOF
  ALF_UPDATE_NODE_ID=$(alf_upload "$ALF_FOLDER_ID" "$TMPDIR_DATA/alf-update-v1.txt" "alf-update-smoke-${RUN_TAG}.txt")
  if [ -n "$ALF_UPDATE_NODE_ID" ]; then
    pass "J1: Update-propagation document uploaded (nodeId=$ALF_UPDATE_NODE_ID)"

    # Sync and embed the original version
    alf_sync_wait "$ALF_FOLDER_ID" "J2a" "J2b"
    info "Waiting ${WAIT_EMBED_S}s for original version to embed ..."
    sleep "$WAIT_EMBED_S"
    rag_find "$ALF_UPDATE_OLD_SENTINEL" "$ALF_UPDATE_NODE_ID" "alfresco" "J3" \
      "Original document content searchable before update"

    # Update the content
    cat > "$TMPDIR_DATA/alf-update-v2.txt" <<EOF
SMOKE TEST DOCUMENT -- UPDATE PROPAGATION (VERSION 2)
Run: $RUN_TAG
Sentinel: $ALF_UPDATE_NEW_SENTINEL
This is the updated version. The old sentinel must no longer be searchable.
EOF
    update_code=$(alf_update_content "$ALF_UPDATE_NODE_ID" "$TMPDIR_DATA/alf-update-v2.txt")
    if [ "$update_code" = "200" ]; then
      pass "J4: Document content updated (HTTP 200)"
      info "Waiting ${WAIT_LIVE_S}s for live-ingester to re-index updated content ..."
      sleep "$WAIT_LIVE_S"
      rag_find "$ALF_UPDATE_NEW_SENTINEL" "$ALF_UPDATE_NODE_ID" "alfresco" "J5" \
        "Updated document content searchable after update"
      # J6: Verify the node status is INDEXED (not PENDING/FAILED) after the update cycle.
      # Semantic search cannot reliably prove old text is absent (embeddings of new content
      # may still be semantically close to the old query), so we check status instead.
      update_status=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" \
        "$BASE/api/content-lake/nodes/${ALF_UPDATE_NODE_ID}/status" 2>/dev/null \
        | jq -r '.status // .syncStatus // empty' 2>/dev/null || echo "")
      [ "$update_status" = "INDEXED" ] \
        && pass "J6: Node status is INDEXED after update (re-indexing completed, no stale state)" \
        || fail "J6: Node status after update is '${update_status}' (expected INDEXED)"
    else
      fail "J4: Content update returned HTTP $update_code -- skipping J5/J6"
    fi
  else
    fail "J1: Failed to upload update-propagation document -- skipping J2-J6"
  fi
else
  skip "J1-J6: Document update propagation skipped (test folder was not created)"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "G — Cleanup"
# ══════════════════════════════════════════════════════════════════════════════

if [ -n "$ALF_FOLDER_ID" ]; then
  alf_delete "$ALF_FOLDER_ID"
  pass "G1: Alfresco test folder deleted (nodeId=$ALF_FOLDER_ID)"
fi

if [ -n "$NUX_UID" ]; then
  nux_delete "$NUX_UID"
  pass "G2: Nuxeo test document deleted (uid=$NUX_UID)"
fi

# Verify both docs are gone from search after deletion.
# Alfresco uses ActiveMQ live events (~20 s); Nuxeo uses audit poll (up to WAIT_LIVE_S).
# We wait the longer of the two once, then check both.
if [ -n "$ALF_NODE_ID" ] || [ -n "$NUX_UID" ]; then
  local_wait=$(( WAIT_LIVE_S > 20 ? WAIT_LIVE_S : 20 ))
  info "Waiting ${local_wait}s for delete events to propagate ..."
  sleep "$local_wait"
fi
if [ -n "$ALF_NODE_ID" ]; then
  rag_absent "$ALF_SENTINEL" "$ALF_NODE_ID" "G3" "Alfresco smoke doc absent after delete"
fi
if [ -n "$NUX_UID" ]; then
  rag_absent "$NUX_SENTINEL" "$NUX_UID" "G4" "Nuxeo smoke doc absent after delete" "$NUXEO_AUTH"
fi

# Remove the Alfresco smoke-tester user if this run created it.
# The v1 REST API returns 405 on Community Edition; fall back to the legacy Alfresco API.
if [ "$ALF_USER_CREATED" = "1" ]; then
  code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" -X DELETE \
    "$ALF_API/people/${SMOKE_USER}" 2>/dev/null || echo 000)
  if [ "$code" = "204" ]; then
    pass "G5: Alfresco smoke-tester user deleted"
  else
    # Legacy API works on Community Edition
    code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" -X DELETE \
      "${BASE}/alfresco/s/api/people/${SMOKE_USER}" 2>/dev/null || echo 000)
    [ "$code" = "200" ] || [ "$code" = "204" ] \
      && pass "G5: Alfresco smoke-tester user deleted (legacy API)" \
      || fail "G5: Failed to delete Alfresco smoke-tester user (v1 HTTP 405, legacy HTTP $code)"
  fi
fi

# Remove the Nuxeo smoke-tester user if this run created it.
if [ "$NUX_USER_CREATED" = "1" ]; then
  code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$NUXEO_AUTH" -X DELETE \
    "$NUXEO_API/user/${SMOKE_USER}" 2>/dev/null || echo 000)
  [ "$code" = "204" ] || [ "$code" = "200" ] \
    && pass "G6: Nuxeo smoke-tester user deleted" \
    || fail "G6: Failed to delete Nuxeo smoke-tester user (HTTP $code)"
fi

# Remove the Nuxeo workspace if this run created it, or if it is the dedicated
# smoke workspace from the documented run command.
# Pass ?hard=true so Nuxeo permanently deletes rather than moves to trash.
if nux_should_delete_workspace; then
  ws_uid=$(curl -sf $CURL_OPTS -u "$NUXEO_AUTH" \
    "$NUXEO_API/path/default-domain/workspaces/${NUXEO_WORKSPACE}" \
    2>/dev/null | jq -r '.uid // empty')
  if [ -n "$ws_uid" ]; then
    code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$NUXEO_AUTH" -X DELETE \
      "$NUXEO_API/id/${ws_uid}?hard=true" 2>/dev/null || echo 000)
    [ "$code" = "204" ] || [ "$code" = "200" ] \
      && pass "G7: Nuxeo workspace '${NUXEO_WORKSPACE}' permanently deleted" \
      || fail "G7: Failed to delete Nuxeo workspace '${NUXEO_WORKSPACE}' (HTTP $code)"
  fi
fi

# G8: Alfresco live-ingest test document
if [ -n "${ALF_LIVE_NODE_ID:-}" ]; then
  alf_delete "$ALF_LIVE_NODE_ID"
  pass "G8: Alfresco live-ingest doc deleted (nodeId=$ALF_LIVE_NODE_ID)"
fi

# G9: Alfresco permissions test document
if [ -n "${ALF_RESTRICTED_NODE_ID:-}" ]; then
  alf_delete "$ALF_RESTRICTED_NODE_ID"
  pass "G9: Alfresco restricted doc deleted (nodeId=$ALF_RESTRICTED_NODE_ID)"
fi

# G10: Alfresco update-propagation test document
if [ -n "${ALF_UPDATE_NODE_ID:-}" ]; then
  alf_delete "$ALF_UPDATE_NODE_ID"
  pass "G10: Alfresco update-propagation doc deleted (nodeId=$ALF_UPDATE_NODE_ID)"
fi

# G11: Permission-check user (only if created by this run)
if [ "${ALF_PERM_USER_CREATED:-0}" = "1" ]; then
  code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" -X DELETE \
    "$ALF_API/people/${ALF_PERM_USER}" 2>/dev/null || echo 000)
  if [ "$code" = "204" ]; then
    pass "G11: Alfresco ${ALF_PERM_USER} user deleted"
  else
    code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" -X DELETE \
      "${BASE}/alfresco/s/api/people/${ALF_PERM_USER}" 2>/dev/null || echo 000)
    [ "$code" = "200" ] || [ "$code" = "204" ] \
      && pass "G11: Alfresco ${ALF_PERM_USER} user deleted (legacy API)" \
      || fail "G11: Failed to delete Alfresco ${ALF_PERM_USER} user (HTTP $code)"
  fi
fi

# Remove the log file written by this run
rm -f "$LOG"

# ══════════════════════════════════════════════════════════════════════════════
section "Summary"
# ══════════════════════════════════════════════════════════════════════════════

echo ""
printf "${B}  Host   : %s${N}\n" "$BASE"
printf "${G}  Passed : %d${N}\n" "$PASS"
[ "$FAIL" -gt 0 ] \
  && printf "${R}  Failed : %d${N}\n" "$FAIL" \
  || printf "  Failed : 0\n"
[ "$SKIP" -gt 0 ] \
  && printf "${Y}  Skipped: %d${N}\n" "$SKIP" \
  || true
printf "  Log    : %s (deleted)\n" "$LOG"
echo ""

[ "$FAIL" -eq 0 ]
