#!/usr/bin/env bash
# test-nuxeo.sh — Nuxeo end-to-end test suite.
# Sections: health checks, D (batch ingestion), E (live ingestion).
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_SCRIPT="$SCRIPT_DIR/../scripts/create-nuxeo-demo-file.sh"

PASS=0; FAIL=0
LOG="test-results-nuxeo-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
pass()    { printf "${G}[PASS]${N} %s\n" "$*"; PASS=$((PASS+1)); }
fail()    { printf "${R}[FAIL]${N} %s\n" "$*"; FAIL=$((FAIL+1)); }
info()    { printf "${C}[INFO]${N} %s\n" "$*"; }
section() { printf "\n${B}${C}─── %s ───${N}\n" "$*"; }

# ── Test helpers ──────────────────────────────────────────────────────────────

# run_nuxeo_sync_wait — triggers Nuxeo configured sync, waits up to 5 min for COMPLETED
run_nuxeo_sync_wait() {
  local resp job_id status
  resp=$(curl -sf -u "$NUXEO_AUTH" -X POST "$SYNC_URL/configured" 2>/dev/null || echo '{}')
  job_id=$(echo "$resp" | jq -r '.jobId // empty')

  if [ -z "$job_id" ]; then
    fail "D3: Sync trigger returned no jobId (response: $resp)"
    return 1
  fi
  pass "D3: Nuxeo sync triggered — jobId=$job_id"

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
        pass "D4: Nuxeo sync COMPLETED (discoveredCount=$discovered, syncedCount=$synced)"
        return 0
        ;;
      FAILED|ERROR)
        fail "D4: Nuxeo sync job FAILED"
        return 1
        ;;
    esac
    sleep 10; elapsed=$((elapsed+10))
  done
  fail "D4: Nuxeo sync job timed out after 5 min (last status=$status)"
  return 1
}

# rag_find_source <query> <uid> <source_type> <test_id> <label>
# Returns 0 if found, 1 if not found.
rag_find_source() {
  local query="$1" uid="$2" src_type="$3" tid="$4" label="$5"
  local resp found
  resp=$(curl -sf -X POST "$RAG_URL/search/semantic" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"$query\",\"topK\":10,\"minScore\":0.2}" 2>/dev/null || echo '{}')
  found=$(echo "$resp" | jq --arg id "$uid" --arg src "$src_type" \
    '[.results[]? | select(
        .cin_ingestProperties.source_nodeId == $id and
        .cin_ingestProperties.source_type   == $src
      )] | length' 2>/dev/null || echo 0)
  if [ "${found:-0}" -gt 0 ]; then
    pass "$tid: $label found in search (uid=$uid, source_type=$src_type)"
    return 0
  else
    fail "$tid: $label NOT found (uid=$uid, source_type=$src_type, query='$query')"
    echo "    top results: $(echo "$resp" | jq -c '[.results[:2][]? | {id:.cin_ingestProperties.source_nodeId, src:.cin_ingestProperties.source_type, score:.score}]')"
    return 1
  fi
}

# rag_absent_uid <query> <uid> <test_id> <label>
rag_absent_uid() {
  local query="$1" uid="$2" tid="$3" label="$4"
  local resp found
  resp=$(curl -sf -X POST "$RAG_URL/search/semantic" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"$query\",\"topK\":10,\"minScore\":0.1}" 2>/dev/null || echo '{}')
  found=$(echo "$resp" | jq --arg id "$uid" \
    '[.results[]? | select(.cin_ingestProperties.source_nodeId == $id)] | length' 2>/dev/null || echo 0)
  if [ "${found:-0}" -eq 0 ]; then
    pass "$tid: $label correctly absent from search"
  else
    fail "$tid: $label still appears in search (uid=$uid)"
  fi
}

# create_demo_file <title> <text> — returns the Nuxeo UID or empty
create_demo_file() {
  local title="$1" text="$2"
  local output
  output=$(bash "$DEMO_SCRIPT" --title "$title" --text "$text" 2>/dev/null) || { echo ""; return; }
  echo "$output" | grep '^UID:' | awk '{print $2}'
}

# delete_nuxeo_doc <uid>
delete_nuxeo_doc() {
  curl -sf -o /dev/null -w '%{http_code}' -u "$NUXEO_AUTH" -X DELETE \
    "$NUXEO_BASE/id/$1" 2>/dev/null || echo 000
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

HR_UID=$(create_demo_file "Nuxeo HR Remote Work Policy" \
  "Remote work eligibility criteria for Nuxeo employees. Work from home three days per week is permitted with manager approval. Home office equipment allowance applies.")
SEC_UID=$(create_demo_file "Nuxeo IT Security Policy" \
  "Information security policy for Nuxeo platform. Password complexity requirements, access control, data classification scheme, and incident response procedures.")
ROAD_UID=$(create_demo_file "Nuxeo Product Roadmap 2025" \
  "Product roadmap Q3 delivery milestones. Mobile-first strategy, AI feature integration, open API platform, developer portal launch planned for fiscal year 2025.")
FIN_UID=$(create_demo_file "Nuxeo Financial Summary Q4" \
  "Quarterly financial results. Revenue growth fifteen percent, EBITDA margin twenty percent, capital expenditure within budget, free cash flow exceeds target.")

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
[ -n "${HR_UID:-}" ]   && rag_find_source "remote work eligibility home three days" \
  "$HR_UID"   "nuxeo" "D5" "Nuxeo HR policy"
[ -n "${SEC_UID:-}" ]  && rag_find_source "information security policy password complexity access control" \
  "$SEC_UID"  "nuxeo" "D6" "Nuxeo IT security policy"
[ -n "${ROAD_UID:-}" ] && rag_find_source "product roadmap Q3 mobile AI open API platform" \
  "$ROAD_UID" "nuxeo" "D7" "Nuxeo product roadmap"
[ -n "${FIN_UID:-}" ]  && rag_find_source "revenue growth EBITDA margin free cash flow" \
  "$FIN_UID"  "nuxeo" "D8" "Nuxeo financial summary"

# D9: Idempotency re-run
info "Re-running Nuxeo sync for idempotency check …"
curl -sf -u "$NUXEO_AUTH" -X POST "$SYNC_URL/configured" >/dev/null 2>&1 || true
sleep 10
if [ -n "${HR_UID:-}" ]; then
  resp=$(curl -sf -X POST "$RAG_URL/search/semantic" \
    -H 'Content-Type: application/json' \
    -d '{"query":"remote work eligibility Nuxeo","topK":20,"minScore":0.2}' 2>/dev/null || echo '{}')
  count=$(echo "$resp" | jq --arg id "$HR_UID" \
    '[.results[]? | select(.cin_ingestProperties.source_nodeId == $id)] | length' 2>/dev/null || echo 0)
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

# E1: Create a new document — should appear after one audit poll cycle
LIVE_NUX_UID=$(create_demo_file "Nuxeo Live Test V1" \
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

# E2: Delete the document — should disappear after the next audit poll.
# Only meaningful if E1b confirmed the document was indexed first.
if [ -n "$LIVE_NUX_UID" ]; then
  code=$(delete_nuxeo_doc "$LIVE_NUX_UID")
  if [ "$code" = "204" ] || [ "$code" = "200" ]; then
    pass "E2a: Nuxeo live test document deleted (HTTP $code)"
    if [ "$E1B_PASS" = true ]; then
      info "Waiting 50 s for audit poll cycle to detect deletion …"
      sleep 50
      rag_absent_uid "corvette-iridescent-nebula-92k" "$LIVE_NUX_UID" "E2b" \
        "Nuxeo live-test doc after delete"
    else
      info "E2b: skipping — E1b did not pass, document was never indexed"
    fi
  else
    fail "E2: Delete returned HTTP $code (expected 204)"
  fi
fi

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
