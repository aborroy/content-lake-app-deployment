#!/usr/bin/env bash
# run-phase1.sh — Alfresco-only e2e run with a STRICT readiness gate.
# Purpose: separate "services not ready yet" from "broken by code" when triaging Phase 1.
# Mirrors run-tests.sh env wiring; builds local-source images, waits for batch-ingester
# /status=200 AND rag health=UP before running test-alfresco.sh, then tears down.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

USE_LOCAL="${USE_LOCAL:-1}"
HOST="${HOST:-localhost}"
USE_HTTPS="${USE_HTTPS:-true}"
export HOST USE_HTTPS
export ALF_AUTH="${ALF_AUTH:-admin:admin}"
if [ "$USE_HTTPS" = "true" ]; then SCHEME="https"; CURL_TLS="-k"; else SCHEME="http"; CURL_TLS=""; fi
BASE="${SCHEME}://${HOST}"

export CONTENT_LAKE_GIT_CONTEXT="${CONTENT_LAKE_GIT_CONTEXT:-../content-lake-app}"
export CONTENT_LAKE_ACS_GIT_CONTEXT="${CONTENT_LAKE_ACS_GIT_CONTEXT:-../content-lake-app}"
export CONTENT_LAKE_UI_GIT_CONTEXT="${CONTENT_LAKE_UI_GIT_CONTEXT:-../alfresco-content-lake-ui}"
export CONTENT_LAKE_APP_UI_CONTEXT="${CONTENT_LAKE_APP_UI_CONTEXT:-../content-lake-app-ui}"

CL_APP_SERVICES_ALFRESCO="rag-service batch-ingester live-ingester"

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
banner(){ printf "\n${B}${C}==============================================${N}\n${B}${C}  %s${N}\n${B}${C}==============================================${N}\n" "$*"; }
info(){ printf "${C}[INFO]${N} %s\n" "$*"; }
warn(){ printf "${Y}[WARN]${N} %s\n" "$*"; }
die(){ printf "${R}[FATAL]${N} %s\n" "$*" >&2; exit 1; }
ok(){ printf "${G}[OK]${N}   %s\n" "$*"; }

dc(){
  ( cd "$DEPLOY_DIR" \
    && set -a && . ./.env && [ -f ./.env.local ] && . ./.env.local; set +a \
    && NGINX_SYNC_DEFAULT_BACKEND="${NGINX_SYNC_DEFAULT_BACKEND:-batch-ingester:9090}" \
       NGINX_ROOT_DIRECTIVE="${NGINX_ROOT_DIRECTIVE:-return 302 /aca/;}" \
       docker compose --env-file .env.local "$@" )
}

# wait_http_code <url> <expected_code> [auth] [max_tries] [interval_s]
wait_http_code(){
  local url="$1" want="$2" auth="${3:-}" max="${4:-60}" interval="${5:-10}"
  local curl_auth=(); [ -n "$auth" ] && curl_auth=(-u "$auth")
  local i code
  for i in $(seq 1 "$max"); do
    code=$(curl -s $CURL_TLS -o /dev/null -w '%{http_code}' "${curl_auth[@]}" "$url" 2>/dev/null || echo 000)
    [ "$code" = "$want" ] && return 0
    printf '.'; sleep "$interval"
  done
  echo; return 1
}

# wait_json_field <url> <jq_filter> <expected> [max_tries] [interval_s]
wait_json_field(){
  local url="$1" filter="$2" want="$3" max="${4:-60}" interval="${5:-10}"
  local i val
  for i in $(seq 1 "$max"); do
    val=$(curl -s $CURL_TLS "$url" 2>/dev/null | jq -r "$filter" 2>/dev/null || echo "")
    [ "$val" = "$want" ] && return 0
    printf '.'; sleep "$interval"
  done
  echo; return 1
}

stack_down(){ dc --profile '*' down; }

# Wipe all persisted state so every run starts from a CLEAN index. The Alfresco E2E suite is NOT
# idempotent across repeated runs on a never-wiped stack: prior-run docs accumulate and linger
# (e.g. cl:excludeFromLake scope docs), producing false failures (I8a/I8b and similar). See AGENTS.md
# ("Run the suites against a CLEAN index"). Removes compose volumes (down -v) plus any leftover
# content-lake-app_* named volumes from earlier profiles.
stack_clean(){
  info "Wiping persisted data (docker compose down -v + content-lake-app_* volumes) …"
  dc --profile '*' down -v 2>/dev/null || true
  local vols
  vols=$(docker volume ls -q 2>/dev/null | grep -E '^content-lake-app_' || true)
  if [ -n "$vols" ]; then
    # shellcheck disable=SC2086
    docker volume rm $vols >/dev/null 2>&1 || true
  fi
  ok "Persisted data wiped"
}

banner "Prerequisites"
command -v docker >/dev/null || die "docker missing"
command -v jq >/dev/null || die "jq missing"
curl -sf -m5 http://localhost:12434/engines/v1/models >/dev/null 2>&1 && ok "AI backend :12434 reachable" || warn "AI backend :12434 NOT reachable — RAG generation may fail"

banner "PHASE 1 — Alfresco + Content Lake (strict gate)"
# Guardrail: always start from a clean index (skip with KEEP_DATA=1).
if [ "${KEEP_DATA:-0}" = "1" ]; then
  warn "KEEP_DATA=1 — NOT wiping volumes; results may be affected by prior-run data"
else
  stack_clean
fi
if [ "$USE_LOCAL" = "1" ]; then
  info "Building local-source app images: $CL_APP_SERVICES_ALFRESCO"
  dc --profile alfresco build $CL_APP_SERVICES_ALFRESCO || die "local image build failed"
fi
dc --profile alfresco up -d || die "stack bring-up failed"

info "Waiting for Alfresco repo (up to 10 min) …"
wait_http_code "$BASE/alfresco/api/-default-/public/alfresco/versions/1/nodes/-root-/children" 200 'admin:admin' 60 10 \
  || { stack_down; die "Alfresco repo not ready"; }
ok "Alfresco repo ready"

info "Waiting for batch-ingester /api/sync/status = 200 (up to 5 min) …"
wait_http_code "$BASE/api/sync/status" 200 'admin:admin' 60 5 \
  || { warn "batch-ingester /status never returned 200"; docker logs --tail 80 content-lake-app-batch-ingester-1 2>&1 | tail -80 || true; }
ok "batch-ingester status probe done"

info "Waiting for RAG health status = UP (up to 5 min) …"
if wait_json_field "$BASE/api/rag/health" '.status' 'UP' 60 5; then
  ok "RAG service health = UP"
else
  warn "RAG health never reached UP; current payload:"
  curl -s $CURL_TLS "$BASE/api/rag/health" 2>/dev/null | jq . 2>/dev/null || true
  warn "rag-service recent logs:"
  docker logs --tail 120 content-lake-app-rag-service-1 2>&1 | tail -120 || true
fi

banner "Running Alfresco test suite"
ALFRESCO_RC=0
bash "$SCRIPT_DIR/test-alfresco.sh" || ALFRESCO_RC=$?

banner "Stopping Alfresco stack"
stack_down

banner "PHASE 1 COMPLETE (rc=$ALFRESCO_RC)"
exit "$ALFRESCO_RC"
