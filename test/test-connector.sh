#!/usr/bin/env bash
# test-connector.sh - end-to-end proof that a connector jar can ingest (#132).
#
# Builds the sample connector from ../content-lake-app/connector-archetype/examples, drops the jar into
# ./connectors, starts connector-batch-ingester on top of an already-running base stack, triggers a sync
# and asserts the fixture documents are retrievable through the RAG service.
#
# Opt-in, and deliberately not a phase of run-tests.sh: the 'connector' profile is opt-in like
# 'filesystem', and wiring it into every run would make the whole suite depend on a Maven build of an
# example project.
#
# Prerequisites:
#   - a base stack already up and healthy (make up-alfresco / up-nuxeo / up-full / up-demo)
#   - the AI backend on :12434, since ingestion embeds
#   - Docker, curl, jq
#
# Usage:
#   CONNECTOR_SYNC_USERNAME=admin CONNECTOR_SYNC_PASSWORD=admin \
#   RAG_AUTH=admin:admin ./test/test-connector.sh
#
# Environment variables:
#   CONNECTOR_SYNC_USERNAME / CONNECTOR_SYNC_PASSWORD  Sync API credentials (required, no defaults)
#   RAG_AUTH        Credentials for the RAG service, user:password (default: admin:admin)
#   HOST            Target host (default: localhost)
#   USE_HTTPS       "true" to use https and pass -k to curl (default: false)
#   APP_SOURCE      Path to the content-lake-app checkout (default: ../content-lake-app). Also becomes
#                   CONTENT_LAKE_GIT_CONTEXT, so the image is built from that checkout rather than from
#                   the GitHub default pinned in .env
#   POLL_DEADLINE_S Seconds to wait for a document to become retrievable (default: 60)
#   BASE_PROFILE    Base profile activated alongside 'connector', needed because the service declares
#                   depends_on hxpr-app (default: alfresco)
#   BUILD_JAR       "true" to rebuild the connector jar even when one exists (default: false)
#   KEEP_RUNNING    "true" to leave the service and the jar in place afterwards (default: false)

set -uo pipefail

HOST="${HOST:-localhost}"
USE_HTTPS="${USE_HTTPS:-false}"
RAG_AUTH="${RAG_AUTH:-admin:admin}"
APP_SOURCE="${APP_SOURCE:-../content-lake-app}"
POLL_DEADLINE_S="${POLL_DEADLINE_S:-60}"
KEEP_RUNNING="${KEEP_RUNNING:-false}"
# "true" rebuilds the connector jar even when one exists; see the build section for why that is opt-in.
BUILD_JAR="${BUILD_JAR:-false}"
SYNC_USER="${CONNECTOR_SYNC_USERNAME:?CONNECTOR_SYNC_USERNAME is required}"
SYNC_PASS="${CONNECTOR_SYNC_PASSWORD:?CONNECTOR_SYNC_PASSWORD is required}"
SYNC_AUTH="${SYNC_USER}:${SYNC_PASS}"

# The connector ingester is not behind the nginx proxy: it is opt-in, so no base deployment routes it.
if [ "${USE_HTTPS}" = "true" ]; then
  BASE="https://${HOST}"
  CURL_OPTS="-k"
else
  BASE="http://${HOST}"
  CURL_OPTS=""
fi
INGESTER="http://${HOST}:9096"
RAG_URL="${BASE}/api/rag"

# Held under its own name because .env is sourced later and would overwrite CONTENT_LAKE_GIT_CONTEXT.
LOCAL_APP_CONTEXT="${CONTENT_LAKE_GIT_CONTEXT:-$APP_SOURCE}"
EXAMPLE_DIR="${APP_SOURCE}/connector-archetype/examples/sample-directory-connector"
JAR_NAME="sample-directory-connector-1.0.0.jar"
SOURCE_TYPE="sample-directory"
FIXTURE_DIR="$(mktemp -d)"
LOG="test-results-connector-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

PASS=0; FAIL=0
G='\033[0;32m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
pass()    { printf "${G}[PASS]${N} %s\n" "$*"; PASS=$((PASS+1)); }
fail()    { printf "${R}[FAIL]${N} %s\n" "$*"; FAIL=$((FAIL+1)); }
info()    { printf "${C}[INFO]${N} %s\n" "$*"; }
section() { printf "\n${B}${C}--- %s ---${N}\n" "$*"; }

# Compose invocation matching the Makefile's env wiring. A base profile is always active alongside
# 'connector' because the service declares depends_on hxpr-app, and compose rejects a project whose
# dependency is enabled by no active profile.
BASE_PROFILE="${BASE_PROFILE:-alfresco}"
dc() {
  local env_args=()
  [ -f ./.env.local ] && env_args=(--env-file .env.local)
  docker compose "${env_args[@]}" --profile "$BASE_PROFILE" --profile connector "$@"
}

RAG_PINNED=0

cleanup() {
  rm -rf "$FIXTURE_DIR"
  # Always restore rag-service: the pin below disables Alfresco source-id auto-discovery, so leaving it
  # set would quietly narrow every other suite run against this stack.
  if [ "$RAG_PINNED" = "1" ]; then
    info "Restoring rag-service without a pinned rag.permission.source-ids"
    unset RAG_PERMISSION_SOURCE_IDS
    dc up -d --no-deps --no-build rag-service >/dev/null 2>&1
  fi
  if [ "$KEEP_RUNNING" = "true" ]; then
    info "KEEP_RUNNING=true: connector-batch-ingester and ./connectors/${JAR_NAME} left in place"
    return
  fi
  info "Removing the connector service and its jar"
  dc rm -sf connector-batch-ingester >/dev/null 2>&1
  rm -f "connectors/${JAR_NAME}"
}
trap cleanup EXIT

for tool in docker curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool"; exit 2; }
done
[ -d "$EXAMPLE_DIR" ] || { echo "Sample connector not found at $EXAMPLE_DIR (set APP_SOURCE)"; exit 2; }

# ── Fixtures ───────────────────────────────────────────────────────────────────
# Sentinel phrases scoped to this run, so an assertion cannot pass on a document a previous run left
# behind. Distinctive wording, because retrieval is semantic.
RUN_TAG="conn-$(date +%Y%m%d-%H%M%S)-$$"
section "Fixtures"
cat > "${FIXTURE_DIR}/quarterly-review.txt" <<EOF
Quarterly review ${RUN_TAG}.
The plugin connector pipeline moved eleven thousand crates of powdered ginger through the Rotterdam
depot in the period under review, against a forecast of nine thousand.
EOF
cat > "${FIXTURE_DIR}/incident-log.md" <<EOF
# Incident log ${RUN_TAG}

The pressure valve on compressor seven failed during the night shift and was replaced with a spare
from the Trondheim store before the morning run resumed.
EOF
mkdir -p "${FIXTURE_DIR}/nested"
cat > "${FIXTURE_DIR}/nested/travel-policy.txt" <<EOF
Travel policy ${RUN_TAG}.
Reimbursement for a journey by narrowboat requires the lock-keeper's countersignature and is capped at
forty pounds per day.
EOF
FIXTURE_COUNT=3
info "Created ${FIXTURE_COUNT} fixture documents in ${FIXTURE_DIR}"

# ── The connector jar, built only when there is not one ─────────────────────────
section "The sample connector jar"
# A jar is a build artefact: rebuilding it here (installing content-lake-spi into a container-local
# repository first, since the example depends on it as `provided` and is deliberately outside the
# reactor) costs two to four minutes per run to re-derive what `mvn package` produced. Build only when
# it is missing, and BUILD_JAR=true to force it when the connector's source has changed.
BUILT_JAR="${EXAMPLE_DIR}/target/${JAR_NAME}"
if [ "$BUILD_JAR" = "true" ] || [ ! -f "$BUILT_JAR" ]; then
  info "Building ${JAR_NAME} (no jar present, or BUILD_JAR=true)"
  # In a container, so the suite needs no host Maven or JDK 25.
  docker run --rm \
    -v "$(cd "$APP_SOURCE" && pwd):/src" \
    -v "connector-test-m2:/root/.m2" \
    -w /src maven:3.9.11-eclipse-temurin-25-alpine \
    sh -c "mvn -q -B -pl common/content-lake-spi -am install -DskipTests \
        && mvn -q -B -f connector-archetype/examples/sample-directory-connector/pom.xml package" \
    || { fail "T1: the sample connector failed to build"; exit 1; }
fi

if [ -f "$BUILT_JAR" ]; then
  pass "T1: ${JAR_NAME} is present, and builds against content-lake-spi alone"
else
  fail "T1: ${JAR_NAME} was not produced"
  exit 1
fi

cp "$BUILT_JAR" "connectors/${JAR_NAME}"
# The container runs as a non-root user and mounts this directory read-only.
chmod 644 "connectors/${JAR_NAME}"
pass "T2: jar copied into ./connectors"

# ── Start the ingester ─────────────────────────────────────────────────────────
section "Start connector-batch-ingester"
# The deployment's own configuration, which carries HXPR_REPOSITORY_ID and the hxpr credentials this
# service needs. Sourced HERE, and this run's settings re-applied AFTERWARDS: `set -a; . ./.env`
# assigns unconditionally, and .env holds empty CONNECTOR_SYNC_* placeholders plus a
# CONTENT_LAKE_GIT_CONTEXT pinned to GitHub, so anything exported before this point is silently
# overwritten -- the same trap run-tests.sh documents.
set -a
# shellcheck disable=SC1091
. ./.env
# shellcheck disable=SC1091
[ -f ./.env.local ] && . ./.env.local
set +a

export CONNECTOR_HOST_PATH="$FIXTURE_DIR"
export SAMPLE_DIRECTORY_ROOT_PATH="/data/connector"
export CONNECTOR_SYNC_USERNAME="$SYNC_USER"
export CONNECTOR_SYNC_PASSWORD="$SYNC_PASS"
# Build from the sibling checkout. Getting this wrong is invisible elsewhere in the suite -- it
# silently tests origin/main -- but here it cannot even build, since a module absent from the default
# branch is exactly what a local run is testing.
export CONTENT_LAKE_GIT_CONTEXT="${LOCAL_APP_CONTEXT}"
info "Building from CONTENT_LAKE_GIT_CONTEXT=${CONTENT_LAKE_GIT_CONTEXT}"

# Build and start as two steps, never `up --build`. `--build` applies to every service being started,
# dependencies included, so it rebuilds hxpr-app -- whose build clones the private ai-ready-index and
# needs HXPR_GIT_AUTH_TOKEN. `--no-deps` then starts only this service, since the base stack is
# already up and healthy.
if ! dc build connector-batch-ingester; then
  fail "T3: connector-batch-ingester image did not build"
  exit 1
fi
if ! dc up -d --no-deps connector-batch-ingester; then
  fail "T3: connector-batch-ingester did not start"
  exit 1
fi

# The service refuses to start without a connector, so a healthy container is itself evidence the jar
# was found, validated and built.
elapsed=0
health=""
while [ $elapsed -lt 180 ]; do
  health=$(curl -s -o /dev/null -w '%{http_code}' "${INGESTER}/actuator/health" 2>/dev/null || echo 000)
  [ "$health" = "200" ] && break
  sleep 5; elapsed=$((elapsed+5))
done
if [ "$health" = "200" ]; then
  pass "T3: the ingester came up with the connector loaded (${elapsed}s)"
else
  fail "T3: the ingester never became healthy (last HTTP ${health})"
  dc logs --tail 60 connector-batch-ingester
  exit 1
fi

# ── The connector is what the registry reports ──────────────────────────────────
section "Connector listing and schema"
listing=$(curl -sf -u "$SYNC_AUTH" "${INGESTER}/api/connectors" 2>/dev/null || echo '{}')
if [ "$(echo "$listing" | jq -r --arg t "$SOURCE_TYPE" '[.connectors[]? | select(.sourceType == $t)] | length')" = "1" ]; then
  pass "T4: ${SOURCE_TYPE} is listed at /api/connectors"
else
  fail "T4: ${SOURCE_TYPE} is not listed. Response: $(echo "$listing" | jq -c .)"
fi

origin=$(echo "$listing" | jq -r --arg t "$SOURCE_TYPE" '.connectors[]? | select(.sourceType == $t) | .origin')
if [ "$origin" = "$JAR_NAME" ]; then
  pass "T5: the listing names the jar it came from (${origin})"
else
  fail "T5: expected origin ${JAR_NAME}, got '${origin}'"
fi

if [ "$(echo "$listing" | jq -r '.problems | length')" = "0" ]; then
  pass "T6: no load problems reported"
else
  fail "T6: load problems reported: $(echo "$listing" | jq -c '.problems')"
fi

schema=$(curl -sf -u "$SYNC_AUTH" "${INGESTER}/api/connectors/schema" 2>/dev/null || echo '[]')
if [ "$(echo "$schema" | jq -r --arg f "${SOURCE_TYPE}.root-path" '[.[]?.fields[]? | select(.name == $f)] | length')" = "1" ]; then
  pass "T7: the schema publishes ${SOURCE_TYPE}.root-path"
else
  fail "T7: ${SOURCE_TYPE}.root-path missing from the schema: $(echo "$schema" | jq -c .)"
fi

# The API is guarded like every other ingester's: not readable without the configured credential.
code=$(curl -s -o /dev/null -w '%{http_code}' "${INGESTER}/api/connectors" 2>/dev/null || echo 000)
if [ "$code" = "401" ]; then
  pass "T8: /api/connectors is closed without credentials"
else
  fail "T8: expected 401 without credentials, got ${code}"
fi

# ── Ingest ─────────────────────────────────────────────────────────────────────
section "Sync"
job=$(curl -sf -u "$SYNC_AUTH" -X POST "${INGESTER}/api/sync/configured" 2>/dev/null || echo '{}')
job_id=$(echo "$job" | jq -r '.jobId // empty')
if [ -n "$job_id" ]; then
  pass "T9: sync started (job ${job_id})"
else
  fail "T9: sync did not start. Response: $(echo "$job" | jq -c .)"
  exit 1
fi

if [ "$(echo "$job" | jq -r '.sourceType')" = "$SOURCE_TYPE" ]; then
  pass "T10: the job reports the connector's source type"
else
  fail "T10: job sourceType is '$(echo "$job" | jq -r '.sourceType')', expected ${SOURCE_TYPE}"
fi

elapsed=0; status=""
while [ $elapsed -lt "$POLL_DEADLINE_S" ]; do
  status=$(curl -sf -u "$SYNC_AUTH" "${INGESTER}/api/sync/status/${job_id}" 2>/dev/null | jq -r '.status // "UNKNOWN"')
  case "$status" in
    COMPLETED|FAILED) break ;;
  esac
  sleep 5; elapsed=$((elapsed+5))
done
final=$(curl -sf -u "$SYNC_AUTH" "${INGESTER}/api/sync/status/${job_id}" 2>/dev/null || echo '{}')
if [ "$status" = "COMPLETED" ]; then
  pass "T11: the job completed in ${elapsed}s"
else
  fail "T11: job status is ${status} after ${elapsed}s: $(echo "$final" | jq -c .)"
  dc logs --tail 80 connector-batch-ingester
fi

discovered=$(echo "$final" | jq -r '.discoveredCount // 0')
synced=$(echo "$final" | jq -r '.syncedCount // 0')
failed=$(echo "$final" | jq -r '.failedCount // 0')
# The nested file is the one that matters: it proves the walk descends rather than listing one level.
if [ "$discovered" = "$FIXTURE_COUNT" ]; then
  pass "T12: discovery walked the whole tree (${discovered} documents, including the nested one)"
else
  fail "T12: discovered ${discovered}, expected ${FIXTURE_COUNT}"
fi
if [ "$synced" = "$FIXTURE_COUNT" ] && [ "$failed" = "0" ]; then
  pass "T13: every document synced with no failures"
else
  fail "T13: synced=${synced} failed=${failed}, expected ${FIXTURE_COUNT} and 0"
fi

# ── Retrievable, which is the whole point ──────────────────────────────────────
section "Retrieval"
# No pin. The permission filter builds one clause per source it can name, and since #133 it names every
# source in the index: it discovers them from a terms aggregation over cin_sourceId, whose values carry
# the source type. So a plugin connector gets a clause as ingested, with no configuration at all.
#
# This used to require pinning rag.permission.source-ids to the connector's source id, because the only
# sources rag-service could name were Alfresco and Nuxeo. On a stack whose other sources hold no documents
# (this one: Alfresco is up but empty, Nuxeo absent) nothing was resolved, the filter fell back to a source
# id matching nothing, and every query returned zero results -- correctly, since the absence of a decision
# must not become the absence of a filter, but for the wrong reason. Asserting retrievability unpinned is
# what keeps that regression visible; T19 below still covers the pinned path, which remains supported.

# Matched on chunkText and on the cin_sourceId prefix, which are the fields this endpoint actually
# returns: there is no sourceType on a semantic-search result, and the text field is chunkText.
find_document() {
  local query="$1" phrase="$2" label="$3" tid="$4"
  local waited=0 resp hits
  while [ $waited -lt "$POLL_DEADLINE_S" ]; do
    resp=$(curl $CURL_OPTS -sf -u "$RAG_AUTH" -X POST "${RAG_URL}/search/semantic" \
      -H 'Content-Type: application/json' \
      -d "{\"query\":\"${query}\",\"topK\":30,\"minScore\":0.2}" 2>/dev/null || echo '{}')
    hits=$(echo "$resp" | jq --arg src "${SOURCE_TYPE}:" --arg tag "$phrase" \
      '[.results[]? | select((.sourceDocument.sourceId // "") | startswith($src))
                    | select((.chunkText // "") | test($tag; "i"))] | length' \
      2>/dev/null || echo 0)
    if [ "${hits:-0}" -gt 0 ]; then
      pass "${tid}: ${label} is retrievable from source ${SOURCE_TYPE} (after ${waited}s)"
      return 0
    fi
    sleep 10; waited=$((waited+10))
  done
  fail "${tid}: ${label} not retrievable after ${waited}s"
  echo "    top results: $(echo "$resp" | jq -c '[.results[:3][]? | {id:.sourceDocument.nodeId, src:.sourceDocument.sourceId, score:.score}]')"
  return 1
}

find_document "How many crates of powdered ginger went through the Rotterdam depot?" \
  "$RUN_TAG" "quarterly-review.txt" "T14"
find_document "What was replaced on compressor seven during the night shift?" \
  "$RUN_TAG" "incident-log.md (markdown)" "T15"
find_document "What does a claim for travel by narrowboat require?" \
  "$RUN_TAG" "nested/travel-policy.txt (nested)" "T16"

# ── Idempotency ────────────────────────────────────────────────────────────────
section "Re-sync"
# #120: unchanged content is not re-chunked or re-embedded, so a second pass should skip rather than
# resync. This is also what proves the connector returns a stable modifiedAt.
job2=$(curl -sf -u "$SYNC_AUTH" -X POST "${INGESTER}/api/sync/configured" 2>/dev/null || echo '{}')
job2_id=$(echo "$job2" | jq -r '.jobId // empty')
elapsed=0; status=""
while [ $elapsed -lt "$POLL_DEADLINE_S" ]; do
  status=$(curl -sf -u "$SYNC_AUTH" "${INGESTER}/api/sync/status/${job2_id}" 2>/dev/null | jq -r '.status // "UNKNOWN"')
  case "$status" in COMPLETED|FAILED) break ;; esac
  sleep 5; elapsed=$((elapsed+5))
done
final2=$(curl -sf -u "$SYNC_AUTH" "${INGESTER}/api/sync/status/${job2_id}" 2>/dev/null || echo '{}')
skipped2=$(echo "$final2" | jq -r '.skippedCount // 0')
failed2=$(echo "$final2" | jq -r '.failedCount // 0')
if [ "$status" = "COMPLETED" ] && [ "$failed2" = "0" ]; then
  pass "T17: the second sync completed with no failures (skipped=${skipped2})"
else
  fail "T17: second sync status=${status} failed=${failed2}: $(echo "$final2" | jq -c .)"
fi

metric() {
  curl -sf -u "$SYNC_AUTH" "${INGESTER}/actuator/metrics/$1" 2>/dev/null \
    | jq -r '.measurements[0].value // 0' 2>/dev/null || echo 0
}

# #120 through this host, which is the question the job counters cannot answer: `skippedCount` counts
# metadata skips only, and a document whose content was reused still counts as synced. The counters behind
# these two metrics are the only place the distinction is visible.
short_circuits=$(metric contentlake.ingest.content.shortcircuits)
reprocesses=$(metric contentlake.ingest.content.reprocesses)
if [ "${short_circuits%.*}" -ge "$FIXTURE_COUNT" ]; then
  pass "T18: the second pass reused stored content for all ${FIXTURE_COUNT} documents (shortcircuits=${short_circuits}, reprocesses=${reprocesses})"
else
  fail "T18: content reuse did not short-circuit the second pass (shortcircuits=${short_circuits}, reprocesses=${reprocesses}, expected at least ${FIXTURE_COUNT})"
fi

# ── The pinned path still works ────────────────────────────────────────────────
section "Pinned permission sources"
# Pinning is still supported and still documented, for a deployment that must not have the set inferred.
# What it now costs is stated in docs/deployment-rag.md: a pin disables discovery, so a pin that omits an
# indexed source hides that source's documents.
info "Pinning rag.permission.source-ids=${SOURCE_TYPE} and recreating rag-service"
RAG_PINNED=1
RAG_PERMISSION_SOURCE_IDS="$SOURCE_TYPE" dc up -d --no-deps --no-build rag-service >/dev/null 2>&1
for _ in $(seq 1 24); do
  curl $CURL_OPTS -s -o /dev/null -u "$RAG_AUTH" "${RAG_URL}/health" && break
  sleep 5
done
if find_document "How many crates of powdered ginger went through the Rotterdam depot?" \
  "$RUN_TAG" "quarterly-review.txt with rag.permission.source-ids pinned" "T19"; then
  :
fi

# ── Summary ────────────────────────────────────────────────────────────────────
printf "\n${B}Connector suite: ${G}%d passed${N}, ${R}%d failed${N}\n" "$PASS" "$FAIL"
printf "Log: %s\n" "$LOG"
[ "$FAIL" -eq 0 ]
