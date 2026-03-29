#!/usr/bin/env bash
# run-tests.sh — Content Lake end-to-end test orchestrator.
#
# Runs from content-lake-app-deployment/:
#   ./test/run-tests.sh
#
# Phase 1: start Alfresco stack → run Alfresco tests → stop.
# Phase 2: start Nuxeo + content-lake → run Nuxeo tests → stop everything.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NUXEO_DIR="$(cd "$DEPLOY_DIR/../nuxeo-deployment" 2>/dev/null && pwd || true)"

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
banner() { printf "\n${B}${C}══════════════════════════════════════════════${N}\n${B}${C}  %s${N}\n${B}${C}══════════════════════════════════════════════${N}\n" "$*"; }
info()  { printf "${C}[INFO]${N} %s\n" "$*"; }
warn()  { printf "${Y}[WARN]${N} %s\n" "$*"; }
die()   { printf "${R}[FATAL]${N} %s\n" "$*" >&2; exit 1; }
ok()    { printf "${G}[OK]${N}   %s\n" "$*"; }

# ── Prerequisites ─────────────────────────────────────────────────────────────
banner "Checking prerequisites"
command -v docker >/dev/null 2>&1      || die "docker not found"
command -v jq     >/dev/null 2>&1      || die "jq not found  (brew install jq)"
command -v curl   >/dev/null 2>&1      || die "curl not found"
docker compose version >/dev/null 2>&1 || die "docker compose v2 not found"
ok "docker, jq, curl, docker-compose all present"

# ── Helpers ───────────────────────────────────────────────────────────────────
wait_for_url() {
  # wait_for_url <url> [auth] [max_tries=60] [interval_s=10]
  local url="$1" auth="${2:-}" max="${3:-60}" interval="${4:-10}"
  local curl_auth=()
  [ -n "$auth" ] && curl_auth=(-u "$auth")
  local i
  for i in $(seq 1 "$max"); do
    local code
    code=$(curl -sf -o /dev/null -w '%{http_code}' "${curl_auth[@]}" "$url" 2>/dev/null || echo 000)
    if [ "$code" = "200" ]; then return 0; fi
    printf '.'
    sleep "$interval"
  done
  echo; return 1
}

# ── Phase 1: Alfresco ─────────────────────────────────────────────────────────
banner "PHASE 1 — Alfresco + Content Lake"

cd "$DEPLOY_DIR"
info "Starting stack (STACK_MODE=alfresco) …"
STACK_MODE=alfresco make up

info "Waiting for Alfresco (up to 10 min) …"
wait_for_url \
  'http://localhost/alfresco/api/-default-/public/alfresco/versions/1/nodes/-root-/children' \
  'admin:admin' 60 10 \
  || die "Alfresco did not become ready within 10 minutes"
ok "Alfresco is up"

info "Waiting for RAG service (up to 3 min) …"
wait_for_url 'http://localhost/api/rag/health' '' 36 5 \
  || warn "RAG service health endpoint not returning 200; proceeding anyway"
ok "RAG service is up"

banner "Running Alfresco test suite"
ALFRESCO_RC=0
bash "$SCRIPT_DIR/test-alfresco.sh" || ALFRESCO_RC=$?

banner "Stopping Alfresco stack"
STACK_MODE=alfresco make down

# ── Phase 2: Nuxeo ────────────────────────────────────────────────────────────
banner "PHASE 2 — Nuxeo + Content Lake"

[ -d "$NUXEO_DIR" ] \
  || die "nuxeo-deployment not found at $NUXEO_DIR — clone it first:
       git clone https://github.com/aborroy/nuxeo-deployment.git ../nuxeo-deployment"

info "Starting nuxeo-deployment …"
(cd "$NUXEO_DIR" && docker compose up -d)

info "Waiting for Nuxeo (up to 8 min) …"
wait_for_url 'http://localhost:8081/nuxeo/api/v1/path/default-domain' \
  'Administrator:Administrator' 96 5 \
  || die "Nuxeo did not become ready within 8 minutes"
ok "Nuxeo is up"

info "Starting Content Lake Nuxeo services (STACK_MODE=nuxeo) …"
cd "$DEPLOY_DIR"
STACK_MODE=nuxeo make up

info "Waiting for HXPR / RAG service …"
wait_for_url 'http://localhost/api/rag/health' '' 36 5 \
  || warn "RAG service health endpoint not returning 200; proceeding anyway"
ok "RAG service is up"

info "Waiting 30 s for Nuxeo ingesters to initialise …"
sleep 30

banner "Running Nuxeo test suite"
NUXEO_RC=0
bash "$SCRIPT_DIR/test-nuxeo.sh" || NUXEO_RC=$?

# ── Teardown ──────────────────────────────────────────────────────────────────
banner "Stopping everything"
cd "$DEPLOY_DIR"
STACK_MODE=nuxeo make down
(cd "$NUXEO_DIR" && docker compose down)

# ── Final summary ─────────────────────────────────────────────────────────────
banner "TEST RUN COMPLETE"
if [ "$ALFRESCO_RC" -eq 0 ]; then
  printf "${G}  Alfresco suite : PASSED${N}\n"
else
  printf "${R}  Alfresco suite : FAILED (exit %d)${N}\n" "$ALFRESCO_RC"
fi
if [ "$NUXEO_RC" -eq 0 ]; then
  printf "${G}  Nuxeo suite    : PASSED${N}\n"
else
  printf "${R}  Nuxeo suite    : FAILED (exit %d)${N}\n" "$NUXEO_RC"
fi
echo ""
[ "$ALFRESCO_RC" -eq 0 ] && [ "$NUXEO_RC" -eq 0 ]
