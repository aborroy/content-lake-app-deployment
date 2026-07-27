#!/usr/bin/env bash
# test-rag-advisor.sh — Sprint 0 (Architecture Foundation) E2E suite.
#
# Exercises the RagService -> Spring AI Advisor pipeline refactor end-to-end against a
# running full stack. Verifies that, after moving retrieve -> rerank -> augment -> generate
# behind a single ChatClient + ContentLakeRetrievalAdvisor:
#   - the synchronous /api/rag/prompt path still returns a grounded answer with sources,
#   - the LLM is actually invoked when context exists (model != the no-context sentinel),
#   - the streaming /api/rag/chat/stream SSE contract is preserved (token, metadata, done),
#   - the empty-context short-circuit still returns the fallback answer WITHOUT calling the LLM.
#
# Requires: a full (or alfresco) stack reachable at http://localhost, curl, jq.
# Auth uses the built-in admin account; the fixture is seeded in Alfresco.

set -uo pipefail

# Honour the same HOST/USE_HTTPS/ALF_AUTH contract as the other suites (run-tests.sh exports them).
HOST="${HOST:-localhost}"
USE_HTTPS="${USE_HTTPS:-false}"
ALF_AUTH="${ALF_AUTH:-admin:admin}"
if [ "$USE_HTTPS" = "true" ]; then
  BASE="https://${HOST}"; CURL_TLS="-k"
else
  BASE="http://${HOST}"; CURL_TLS=""
fi

ALF_BASE="${BASE}/alfresco/api/-default-/public/alfresco/versions/1"
SYNC_URL="${BASE}/api/sync"
RAG_URL="${BASE}/api/rag"

PASS=0; FAIL=0
TMPDIR_DATA="$(mktemp -d)"
TEST_RUN_TAG="$(date +%Y%m%d-%H%M%S)-$$"
LOG="test-results-rag-advisor-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
pass()    { printf "${G}[PASS]${N} %s\n" "$*"; PASS=$((PASS+1)); }
fail()    { printf "${R}[FAIL]${N} %s\n" "$*"; FAIL=$((FAIL+1)); }
info()    { printf "${C}[INFO]${N} %s\n" "$*"; }
section() { printf "\n${B}${C}--- %s ---${N}\n" "$*"; }

cleanup() { rm -rf "$TMPDIR_DATA"; }
trap cleanup EXIT

json_escape() { jq -Rn --arg value "$1" '$value'; }

create_alfresco_folder() {
  local name="$1" resp http_code body
  resp=$(curl $CURL_TLS -s -w '\n%{http_code}' -u "$ALF_AUTH" -X POST \
    "$ALF_BASE/nodes/-my-/children" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"$name\",\"nodeType\":\"cm:folder\"}" 2>/dev/null)
  http_code=$(printf '%s' "$resp" | tail -1)
  body=$(printf '%s' "$resp" | sed '$d')
  if [ "$http_code" = "201" ]; then
    printf '%s' "$body" | jq -r '.entry.id // empty'
  elif [ "$http_code" = "409" ]; then
    curl $CURL_TLS -sf -u "$ALF_AUTH" \
      "$ALF_BASE/nodes/-my-/children?fields=id,name&maxItems=500" 2>/dev/null \
      | jq -r --arg n "$name" '.list.entries[]? | select(.entry.name==$n) | .entry.id' | head -1
  else
    echo ""
  fi
}

upload_alfresco_file() {
  local parent="$1" path="$2" name="$3" resp http_code body
  resp=$(curl $CURL_TLS -s -w '\n%{http_code}' -u "$ALF_AUTH" -X POST \
    "$ALF_BASE/nodes/$parent/children" \
    -F "filedata=@${path};type=text/plain" \
    -F "name=$name" 2>/dev/null)
  http_code=$(printf '%s' "$resp" | tail -1)
  body=$(printf '%s' "$resp" | sed '$d')
  if [ "$http_code" = "201" ]; then
    printf '%s' "$body" | jq -r '.entry.id // empty'
  elif [ "$http_code" = "409" ]; then
    curl $CURL_TLS -sf -u "$ALF_AUTH" \
      "$ALF_BASE/nodes/$parent/children?fields=id,name&maxItems=500" 2>/dev/null \
      | jq -r --arg n "$name" '.list.entries[]? | select(.entry.name==$n) | .entry.id' | head -1
  else
    echo ""
  fi
}

run_alfresco_sync_wait() {
  local folder_id="$1" resp job_id status elapsed=0
  resp=$(curl $CURL_TLS -sf -u "$ALF_AUTH" -X POST "$SYNC_URL/batch?sourceType=alfresco" \
    -H 'Content-Type: application/json' \
    -d "{\"folders\":[\"$folder_id\"],\"recursive\":true,\"types\":[\"cm:content\"]}" \
    2>/dev/null || echo '{}')
  job_id=$(printf '%s' "$resp" | jq -r '.jobId // empty')
  [ -z "$job_id" ] && { fail "S1: Alfresco sync trigger returned no jobId (response: $resp)"; return 1; }
  pass "S1: Alfresco sync triggered (jobId=$job_id)"
  while [ $elapsed -lt 300 ]; do
    status=$(curl $CURL_TLS -sf -u "$ALF_AUTH" "$SYNC_URL/status/$job_id?sourceType=alfresco" 2>/dev/null \
      | jq -r '.status // "UNKNOWN"')
    case "$status" in
      COMPLETED) pass "S2: Alfresco sync completed"; return 0 ;;
      FAILED|ERROR) fail "S2: Alfresco sync failed ($status)"; return 1 ;;
    esac
    sleep 10; elapsed=$((elapsed+10))
  done
  fail "S2: Alfresco sync timed out after 5 minutes"; return 1
}

# /api/rag/prompt uses the field name "question" (distinct from the search endpoints' "query").
# Generous -m 120: local LLM generation routinely takes 8-15s and cold starts longer.
rag_prompt() {
  local auth="$1" question="$2" extra="${3:-}"
  curl $CURL_TLS -sf -m 120 -u "$auth" -X POST "$RAG_URL/prompt" \
    -H 'Content-Type: application/json' \
    -d "{\"question\":$(json_escape "$question"),\"topK\":5,\"includeContext\":true${extra}}" 2>/dev/null || echo '{}'
}

wait_for_prompt_grounded() {
  # Poll /prompt until the answer cites some grounded source (sources > 0), up to 3 min.
  # Emits ONLY the final JSON response on stdout (progress goes to stderr) so callers can
  # capture it cleanly via command substitution without swallowing log lines.
  local auth="$1" question="$2" attempt resp sources
  for attempt in $(seq 1 18); do
    resp=$(rag_prompt "$auth" "$question")
    sources=$(printf '%s' "$resp" | jq -r '(.sources // []) | length' 2>/dev/null || echo 0)
    if [ "${sources:-0}" -gt 0 ]; then
      printf '%s' "$resp"
      return 0
    fi
    sleep 10
  done
  printf '%s' "$resp"
  return 1
}

# ── A — Smoke ───────────────────────────────────────────────────────────────
section "A — Smoke"
code=$(curl $CURL_TLS -sf -o /dev/null -w '%{http_code}' "$RAG_URL/health" 2>/dev/null || echo 000)
[ "$code" = "200" ] && pass "A1: RAG service /health is UP" || fail "A1: RAG /health returned HTTP $code"

# ── B — Fixture ─────────────────────────────────────────────────────────────
section "B — Fixture"
SENTINEL="advisor sentinel helios-${TEST_RUN_TAG}"
ANSWER_FACT="The Sprint 0 advisor pipeline routes retrieval through a single ChatClient."
FOLDER_ID=$(create_alfresco_folder "content-lake-advisor-$TEST_RUN_TAG")
[ -n "$FOLDER_ID" ] && pass "B1: Alfresco test folder ready (nodeId=$FOLDER_ID)" \
                     || fail "B1: Failed to create Alfresco test folder"

DOC_PATH="$TMPDIR_DATA/advisor-$TEST_RUN_TAG.txt"
cat > "$DOC_PATH" <<EOF
SPRINT 0 ADVISOR PIPELINE TEST DOCUMENT

Unique search phrase: $SENTINEL.
$ANSWER_FACT
Retrieval, reranking and context assembly are composed as a Spring AI advisor.
EOF

NODE_ID=""
if [ -n "${FOLDER_ID:-}" ]; then
  NODE_ID=$(upload_alfresco_file "$FOLDER_ID" "$DOC_PATH" "advisor-$TEST_RUN_TAG.txt")
  [ -n "$NODE_ID" ] && pass "B2: Alfresco fixture uploaded (nodeId=$NODE_ID)" \
                    || fail "B2: Failed to upload Alfresco fixture"
fi

# ── C — Indexing ────────────────────────────────────────────────────────────
section "C — Indexing"
[ -n "${FOLDER_ID:-}" ] && run_alfresco_sync_wait "$FOLDER_ID"

# ── D — Advisor synchronous path (/prompt) ──────────────────────────────────
section "D — Advisor synchronous path (/api/rag/prompt)"
PROMPT_RESP=$(wait_for_prompt_grounded "$ALF_AUTH" "What does the $SENTINEL document say about the advisor pipeline?")
d1_sources=$(printf '%s' "$PROMPT_RESP" | jq -r '(.sources // []) | length' 2>/dev/null || echo 0)
[ "${d1_sources:-0}" -gt 0 ] && pass "D1: /prompt returned grounded sources (sources=$d1_sources)" \
                             || fail "D1: /prompt returned no grounded sources within 3 minutes"

answer=$(printf '%s' "$PROMPT_RESP" | jq -r '.answer // empty' 2>/dev/null || echo "")
model=$(printf '%s' "$PROMPT_RESP" | jq -r '.model // empty' 2>/dev/null || echo "")
retrieval_query=$(printf '%s' "$PROMPT_RESP" | jq -r '.retrievalQuery // empty' 2>/dev/null || echo "")
ctx_len=$(printf '%s' "$PROMPT_RESP" | jq -r '(.context // []) | length' 2>/dev/null || echo 0)

[ -n "$answer" ] && pass "D2: /prompt returned a non-empty answer" \
                 || fail "D2: /prompt returned an empty answer"

# When context exists the advisor must NOT short-circuit — the LLM runs, so model is a real
# model id, never the "none (no context available)" sentinel.
if [ -n "$model" ] && [ "$model" != "none (no context available)" ] && [ "$model" != "error" ]; then
  pass "D3: LLM was invoked via ChatClient (model=$model)"
else
  fail "D3: expected a real model id, got '$model'"
fi

[ -n "$retrieval_query" ] && pass "D4: response carries retrievalQuery ('$retrieval_query')" \
                          || fail "D4: response missing retrievalQuery"

[ "${ctx_len:-0}" -gt 0 ] && pass "D5: includeContext returned $ctx_len context chunk(s)" \
                          || fail "D5: includeContext returned no context chunks"

# ── E — Advisor streaming path (/chat/stream SSE) ───────────────────────────
section "E — Advisor streaming path (/api/rag/chat/stream)"
STREAM_OUT="$TMPDIR_DATA/stream.sse"
curl $CURL_TLS -sf -m 120 -u "$ALF_AUTH" -N -X POST "$RAG_URL/chat/stream" \
  -H 'Content-Type: application/json' \
  -H 'Accept: text/event-stream' \
  -d "{\"question\":$(json_escape "Summarize the $SENTINEL document."),\"topK\":5}" \
  >"$STREAM_OUT" 2>/dev/null || true

if grep -q '^event:token' "$STREAM_OUT" || grep -q '"token"' "$STREAM_OUT"; then
  pass "E1: stream emitted token event(s)"
else
  fail "E1: stream emitted no token events"
  info "stream head: $(head -c 300 "$STREAM_OUT" | tr '\n' ' ')"
fi

grep -q '^event:metadata' "$STREAM_OUT" && pass "E2: stream emitted metadata event" \
                                        || fail "E2: stream emitted no metadata event"
grep -q '^event:done' "$STREAM_OUT" && pass "E3: stream emitted done event" \
                                    || fail "E3: stream emitted no done event"

# The metadata event payload must carry the preserved response contract (sources array).
meta_line=$(grep -A1 '^event:metadata' "$STREAM_OUT" | grep '^data:' | head -1 | sed 's/^data://')
meta_sources=$(printf '%s' "$meta_line" | jq -r '(.sources // []) | length' 2>/dev/null || echo 0)
[ "${meta_sources:-0}" -gt 0 ] && pass "E4: metadata event carries $meta_sources source(s)" \
                               || fail "E4: metadata event carried no sources"

# ── F — Empty-context short-circuit (fallback without LLM) ──────────────────
section "F — Empty-context short-circuit"
# A filter that matches no document forces zero retrieved chunks, so the advisor must
# short-circuit and return the fixed fallback answer instead of calling the LLM.
NO_MATCH_FILTER=",\"filter\":\"cin_id = 'no-such-node-${TEST_RUN_TAG}'\""
FALLBACK_RESP=$(rag_prompt "$ALF_AUTH" "Anything about $SENTINEL?" "$NO_MATCH_FILTER")
fb_answer=$(printf '%s' "$FALLBACK_RESP" | jq -r '.answer // empty' 2>/dev/null || echo "")
fb_sources=$(printf '%s' "$FALLBACK_RESP" | jq -r '(.sources // []) | length' 2>/dev/null || echo 0)
fb_model=$(printf '%s' "$FALLBACK_RESP" | jq -r '.model // empty' 2>/dev/null || echo "")

if printf '%s' "$fb_answer" | grep -qi "couldn't find any relevant documents"; then
  pass "F1: empty-context returns the fallback answer"
else
  fail "F1: expected fallback answer, got '$fb_answer'"
fi
[ "${fb_sources:-0}" -eq 0 ] && pass "F2: fallback response has zero sources" \
                             || fail "F2: fallback response unexpectedly had $fb_sources sources"
if [ "$fb_model" = "none (no context available)" ]; then
  pass "F3: fallback did not invoke the LLM (model='$fb_model')"
else
  fail "F3: expected no-context sentinel model, got '$fb_model'"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
section "Summary"
printf "Passed: %d | Failed: %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
