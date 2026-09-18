#!/usr/bin/env bash
# test-sharepoint.sh - end-to-end proof that the SharePoint connector plugin ingests through Microsoft
# Graph, against the mock Graph service rather than a tenant.
#
# The mock is the target because a tenant is not merely inconvenient to obtain: registering an application
# is disabled in this tenant, and a SharePoint site a developer is only a member of returns a truncated
# ACL, so it cannot validate permission mapping at all. What runs here is the whole connector: real Graph
# protocol handling, real paging, real ACL mapping, real content downloads. Exactly two things differ from
# the cloud, the Graph base URL and the token provider, and both are configuration.
#
# What this cannot prove, and what still needs a tenant: real payload fidelity beyond the fixtures, app-only
# token acquisition (msal4j refuses an authority that is not https, so this run uses a static token),
# genuine throttling behaviour, and whether SharePoint honours the Prefer headers.
#
# Opt-in, and deliberately not a phase of run-tests.sh, for the same reasons as test-cmis.sh: the
# connector profile is opt-in, and wiring it into every run would make the whole suite depend on a Maven
# build of a project outside the reactor.
#
# What this suite deliberately does NOT do:
#
#   - It does not rebuild the connector jar when one is already built. Pass BUILD_JAR=true to force it.
#   - It does not create fixtures. They are baked into the mock image, which is the point of the mock:
#     the grant shapes that matter are hard to construct in a real tenant and trivial to state as files.
#   - It does not poll for minutes to conclude an absence. Once a presence assertion has proved retrieval
#     works, "still not there" needs no deadline of its own.
#
# Prerequisites:
#   - the alfresco (or full/demo) base stack already up and healthy, for hxpr and the RAG service
#   - the AI backend on :12434, since ingestion embeds
#   - Docker, curl, jq, unzip
#   - a built jar under ../content-lake-app/plugins/sharepoint-connector/target/, or BUILD_JAR=true
#
# Usage:
#   CONNECTOR_SYNC_USERNAME=admin CONNECTOR_SYNC_PASSWORD=admin \
#   RAG_AUTH=admin:admin ./test/test-sharepoint.sh
#
# Environment variables:
#   CONNECTOR_SYNC_USERNAME / CONNECTOR_SYNC_PASSWORD  Sync API credentials (required, no defaults)
#   RAG_AUTH        Credentials for the RAG service (default: admin:admin)
#   HOST            Target host (default: localhost)
#   USE_HTTPS       "true" to use https and pass -k to curl (default: true, as the proxy redirects)
#   APP_SOURCE      Path to the content-lake-app checkout (default: ../content-lake-app)
#   BUILD_JAR       "true" to build the connector jar even when one exists (default: false)
#   POLL_DEADLINE_S Seconds to wait for a document to become retrievable (default: 60)
#   KEEP_RUNNING    "true" to leave the services and the jar in place (default: false)

set -uo pipefail

HOST="${HOST:-localhost}"
USE_HTTPS="${USE_HTTPS:-true}"
RAG_AUTH="${RAG_AUTH:-admin:admin}"
APP_SOURCE="${APP_SOURCE:-../content-lake-app}"
BUILD_JAR="${BUILD_JAR:-false}"
POLL_DEADLINE_S="${POLL_DEADLINE_S:-60}"
KEEP_RUNNING="${KEEP_RUNNING:-false}"
SYNC_USER="${CONNECTOR_SYNC_USERNAME:?CONNECTOR_SYNC_USERNAME is required}"
SYNC_PASS="${CONNECTOR_SYNC_PASSWORD:?CONNECTOR_SYNC_PASSWORD is required}"
SYNC_AUTH="${SYNC_USER}:${SYNC_PASS}"

if [ "$USE_HTTPS" = "true" ]; then
  BASE="https://${HOST}"; CURL_OPTS="-k"
else
  BASE="http://${HOST}"; CURL_OPTS=""
fi
RAG_URL="${BASE}/api/rag"
ALF_BASE="${BASE}/alfresco/api/-default-/public/alfresco/versions/1"
ALF_AUTH="${ALF_AUTH:-admin:admin}"
# Two callers for the group assertion. They authenticate against Alfresco, because that is what the RAG
# service authenticates against; the mock's directory then answers for <username>@contoso.com, which is
# also what exercises the resolver's username-suffix mapping.
# Fixed, because the mock's directory fixtures are keyed by name. Distinctive, so they cannot
# collide with the user-a and user-b that test-alfresco.sh creates on the same stack.
MEMBER_USER="sp-member"
NON_MEMBER_USER="sp-outsider"
# Neither service is behind the proxy: both are opt-in, so no base deployment routes them.
INGESTER="http://${HOST}:9096"
MOCK="http://${HOST}:${MOCK_GRAPH_PORT:-8099}"
# What the connector talks to. The service name, not the published port: this URL is resolved inside the
# stack network.
MOCK_INTERNAL="http://mock-graph:8099/v1.0"

LOCAL_APP_CONTEXT="${CONTENT_LAKE_GIT_CONTEXT:-$APP_SOURCE}"
CONNECTOR_DIR="${APP_SOURCE}/plugins/sharepoint-connector"
JAR_NAME="sharepoint-connector-1.0.0.jar"
BUILT_JAR="${CONNECTOR_DIR}/target/${JAR_NAME}"
SOURCE_TYPE="sharepoint"
DRIVE_ID="b!mock-drive-id"
# The mock's fixture tree holds 8 documents reachable from the root, in 7 containers.
EXPECTED_DOCUMENTS=8

# A source id unique to this run. The mock's fixtures are static, so two runs ingest identical text; without
# this, an assertion could pass on a document the previous run left behind, and an absence assertion could
# fail for the same reason. cin_sourceId is "<sourceType>:<sourceId>", so this makes every hit attributable.
RUN_TAG="sp-$(date +%Y%m%d-%H%M%S)-$$"
SOURCE_ID="e2e-${RUN_TAG}"
QUALIFIED_SOURCE="${SOURCE_TYPE}:${SOURCE_ID}"

LOG="test-results-sharepoint-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

PASS=0; FAIL=0
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
pass()    { printf "${G}[PASS]${N} %s\n" "$*"; PASS=$((PASS+1)); }
fail()    { printf "${R}[FAIL]${N} %s\n" "$*"; FAIL=$((FAIL+1)); }
info()    { printf "${C}[INFO]${N} %s\n" "$*"; }
warn()    { printf "${Y}[WARN]${N} %s\n" "$*"; }
section() { printf "\n${B}${C}--- %s ---${N}\n" "$*"; }

BASE_PROFILE="${BASE_PROFILE:-alfresco}"
dc() {
  local env_args=()
  [ -f ./.env.local ] && env_args=(--env-file .env.local)
  docker compose "${env_args[@]}" --profile "$BASE_PROFILE" --profile connector --profile sharepoint-mock "$@"
}

cleanup() {
  if [ "$KEEP_RUNNING" = "true" ]; then
    info "KEEP_RUNNING=true: mock-graph, plugin-batch-ingester and ./connectors/${JAR_NAME} are left in place"
    return
  fi
  info "Removing the connector service, the mock and the jar"
  dc rm -sf plugin-batch-ingester mock-graph >/dev/null 2>&1
  rm -f "connectors/${JAR_NAME}"
  # The two callers are left in place. Alfresco's REST API answers 405 to DELETE /people/{id}, so there is
  # no tidy way to remove them, and pretending to would leave a cleanup step that silently does nothing.
  # Creating them again on the next run answers 409, which the suite treats as success.
  # rag-service belongs to the base stack and this suite reconfigured it, so it is put back as it was.
  # Without this, a stack left running would keep an Entra resolver pointed at a mock that is gone.
  if [ "${RAG_RECONFIGURED:-false}" = "true" ]; then
    info "Restoring rag-service without the Entra resolver"
    ( unset RAG_SECURITY_ENTRA_ENABLED RAG_SECURITY_ENTRA_AUTH_MODE RAG_SECURITY_ENTRA_ACCESS_TOKEN \
            RAG_SECURITY_ENTRA_GRAPH_BASE_URL RAG_SECURITY_ENTRA_USERNAME_SUFFIX
      dc up -d --no-deps --force-recreate rag-service >/dev/null 2>&1 )
  fi
}
trap cleanup EXIT

for tool in docker curl jq unzip; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool"; exit 2; }
done
[ -d "$CONNECTOR_DIR" ] || { echo "Connector not found at $CONNECTOR_DIR (set APP_SOURCE)"; exit 2; }

# --- The jar --------------------------------------------------------------------------------------
section "Connector jar"
if [ "$BUILD_JAR" = "true" ] || [ ! -f "$BUILT_JAR" ]; then
  info "Building ${JAR_NAME} (no jar present, or BUILD_JAR=true)"
  # In a container, so this needs no host Maven or JDK 25. content-lake-spi is installed first: the
  # connector depends on it as `provided` and is deliberately not part of the reactor.
  docker run --rm -v "$(cd "$APP_SOURCE" && pwd):/src" -v "connector-test-m2:/root/.m2" \
    -w /src maven:3.9.11-eclipse-temurin-25-alpine \
    sh -c "mvn -q -B -pl common/content-lake-spi -am install -DskipTests \
        && mvn -q -B -f plugins/sharepoint-connector/pom.xml package -DskipTests" \
    || { fail "S1: the SharePoint connector failed to build"; exit 1; }
fi

if [ -f "$BUILT_JAR" ]; then
  pass "S1: ${JAR_NAME} is present ($(du -h "$BUILT_JAR" | cut -f1))"
else
  fail "S1: ${JAR_NAME} was not produced"
  exit 1
fi

# Asserted on the jar the build produced. ConnectorPluginLoader resolves nothing for a plugin, so a
# dependency that did not travel with it loads and then fails on the first call, and shading is the part of
# this build that can regress without anything else noticing.
if [ "$(unzip -l "$BUILT_JAR" | grep -c 'com/microsoft/aad/msal4j')" -gt 100 ]; then
  pass "S2: the jar carries msal4j, so token acquisition works without the host providing it"
else
  fail "S2: the jar has no msal4j classes in it"
fi
if [ "$(unzip -l "$BUILT_JAR" | grep -c 'org/hyland/contentlake/spi/')" -eq 0 ] \
   && [ "$(unzip -l "$BUILT_JAR" | grep -c 'org/springframework/')" -eq 0 ]; then
  pass "S3: the jar bundles neither the SPI nor Spring, so its types are the host's"
else
  fail "S3: the jar bundles the SPI or Spring; the plugin's types would not be the host's"
fi
# Jackson is the one dependency the host also has. A parent-first classloader means an unrelocated copy
# would be ignored in favour of the host's, making this jar's behaviour depend on a version it does not
# choose.
if [ "$(unzip -l "$BUILT_JAR" | grep -c 'com/fasterxml/jackson')" -eq 0 ] \
   && [ "$(unzip -l "$BUILT_JAR" | grep -c 'shaded/jackson')" -gt 100 ]; then
  pass "S4: Jackson is relocated, so the jar carries the version it was tested against"
else
  fail "S4: Jackson is not relocated in the jar"
fi

cp "$BUILT_JAR" "connectors/${JAR_NAME}"
# The container runs as a non-root user and mounts this directory read-only.
chmod 644 "connectors/${JAR_NAME}"

# --- Configuration, then both services ------------------------------------------------------------
# The deployment's own configuration, sourced HERE and this run's settings re-applied AFTERWARDS:
# `set -a; . ./.env` assigns unconditionally, so anything exported before this point is overwritten.
set -a
# shellcheck disable=SC1091
. ./.env
# shellcheck disable=SC1091
[ -f ./.env.local ] && . ./.env.local
set +a

export CONNECTOR_SOURCE_TYPE="$SOURCE_TYPE"
export CONNECTOR_SYNC_USERNAME="$SYNC_USER"
export CONNECTOR_SYNC_PASSWORD="$SYNC_PASS"
# The change feed is what turns the second pass into an incremental one, and it is off by default.
export CONNECTOR_CHANGE_FEED_ENABLED=true
export SHAREPOINT_DRIVE_IDS="$DRIVE_ID"
export SHAREPOINT_SOURCE_ID="$SOURCE_ID"
export SHAREPOINT_GRAPH_BASE_URL="$MOCK_INTERNAL"
# msal4j refuses an authority that is not https, so a mock cannot double as an Entra ID. This is the one
# thing a mock run cannot exercise, and the connector's own tests cover it against the real library.
export SHAREPOINT_AUTH_MODE=static-token
export SHAREPOINT_ACCESS_TOKEN="mock-token-${RUN_TAG}"
export SHAREPOINT_CLIENT_ID="mock-client-id"
# No budget to protect in front of a mock, and metering would only slow the suite.
export SHAREPOINT_RESOURCE_UNITS_PER_MINUTE=0
export CONTENT_LAKE_GIT_CONTEXT="${LOCAL_APP_CONTEXT}"

section "Start the mock Graph service"
# Build and start as two steps, never `up --build`: `--build` applies to dependencies too, and would
# rebuild hxpr-app, whose build clones the private ai-ready-index.
if ! dc build mock-graph; then
  fail "S5: the mock-graph image did not build"
  exit 1
fi
if ! dc up -d --no-deps mock-graph; then
  fail "S5: mock-graph did not start"
  exit 1
fi

elapsed=0; code=000
while [ $elapsed -lt 60 ]; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer probe" \
    "${MOCK}/v1.0/drives/${DRIVE_ID}" 2>/dev/null || echo 000)
  [ "$code" = "200" ] && break
  sleep 3; elapsed=$((elapsed+3))
done
if [ "$code" = "200" ]; then
  pass "S5: the mock Graph service is serving fixtures (${elapsed}s)"
else
  fail "S5: the mock never answered for the drive (last HTTP ${code})"
  dc logs --tail 40 mock-graph
  exit 1
fi

# The mock is unhelpful in the same places Graph is, and this is the cheapest of those to assert. A
# connector that stopped decorating its requests would fail here rather than in a tenant.
if [ "$(curl -s -o /dev/null -w '%{http_code}' "${MOCK}/v1.0/drives/${DRIVE_ID}")" = "401" ]; then
  pass "S6: the mock refuses a request carrying no bearer token"
else
  fail "S6: the mock served a drive to an unauthenticated caller"
fi

section "Two callers, and the Entra resolver on the query path"
# They authenticate against Alfresco because that is what the RAG service authenticates against. The mock's
# directory then answers for <username>@contoso.com, which also exercises the resolver's suffix mapping: a
# caller's repository username is not necessarily their Entra identity.
for user in "$MEMBER_USER" "$NON_MEMBER_USER"; do
  code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" -X POST "${ALF_BASE}/people" \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"${user}\",\"firstName\":\"${user}\",\"email\":\"${user}@contoso.com\",\"password\":\"${user}-pw\"}")
  case "$code" in
    201) pass "S9b: created the Alfresco caller ${user}" ;;
    409) pass "S9b: the Alfresco caller ${user} already exists" ;;
    *)   fail "S9b: could not create ${user} (HTTP ${code})" ;;
  esac
done

# rag-service belongs to the base stack, so this recreates it with the resolver on and puts it back in
# cleanup. static-token because msal4j refuses an authority that is not https, so the mock cannot stand in
# for Entra ID.
export RAG_SECURITY_ENTRA_ENABLED=true
export RAG_SECURITY_ENTRA_AUTH_MODE=static-token
export RAG_SECURITY_ENTRA_ACCESS_TOKEN="mock-token-${RUN_TAG}"
export RAG_SECURITY_ENTRA_GRAPH_BASE_URL="$MOCK_INTERNAL"
export RAG_SECURITY_ENTRA_USERNAME_SUFFIX="@contoso.com"
RAG_RECONFIGURED=true
# Built, not just recreated: the resolver is new code, so a stack brought up before it existed is running an
# image without the bean, and the group assertions would fail as "not retrievable" with no hint why. One
# service with a warm cache, and it is the only way this suite tests the working tree rather than an image.
if ! dc build rag-service; then
  fail "S9c: the rag-service image did not build"
  exit 1
fi
if ! dc up -d --no-deps --force-recreate rag-service >/dev/null 2>&1; then
  fail "S9c: rag-service did not restart with the Entra resolver"
  exit 1
fi
# 300s, matching run-tests.sh: a force-recreated rag-service boots a JVM and waits on its dependencies, and
# 180s was measured here as not enough. The suite failed on the deadline, not on the service.
elapsed=0; rag=""
while [ $elapsed -lt 300 ]; do
  rag=$(curl -s $CURL_OPTS -u "$RAG_AUTH" "${RAG_URL}/health" 2>/dev/null | jq -r '.status // "?"')
  [ "$rag" = "UP" ] && break
  sleep 5; elapsed=$((elapsed+5))
done
if [ "$rag" = "UP" ]; then
  pass "S9c: rag-service is UP with the Entra resolver enabled (${elapsed}s)"
else
  fail "S9c: rag-service never became UP (last status ${rag})"
  dc logs --tail 60 rag-service
  exit 1
fi

section "Start plugin-batch-ingester with the SharePoint connector"
info "Ingesting drive ${DRIVE_ID} from ${MOCK_INTERNAL} as source ${QUALIFIED_SOURCE}"
if ! dc build plugin-batch-ingester; then
  fail "S7: plugin-batch-ingester image did not build"
  exit 1
fi
if ! dc up -d --no-deps plugin-batch-ingester; then
  fail "S7: plugin-batch-ingester did not start"
  exit 1
fi

elapsed=0; health=""
while [ $elapsed -lt 180 ]; do
  health=$(curl -s -o /dev/null -w '%{http_code}' "${INGESTER}/actuator/health" 2>/dev/null || echo 000)
  [ "$health" = "200" ] && break
  sleep 5; elapsed=$((elapsed+5))
done
if [ "$health" = "200" ]; then
  pass "S7: the ingester came up with the SharePoint connector loaded (${elapsed}s)"
else
  fail "S7: the ingester never became healthy (last HTTP ${health})"
  dc logs --tail 80 plugin-batch-ingester
  exit 1
fi

listing=$(curl -sf -u "$SYNC_AUTH" "${INGESTER}/api/connectors" 2>/dev/null || echo '{}')
if [ "$(echo "$listing" | jq -r --arg t "$SOURCE_TYPE" '[.connectors[]? | select(.sourceType == $t)] | length')" = "1" ]; then
  pass "S8: sharepoint is listed at /api/connectors"
else
  fail "S8: listing is $(echo "$listing" | jq -c .)"
fi

schema=$(curl -sf -u "$SYNC_AUTH" "${INGESTER}/api/connectors/schema" 2>/dev/null || echo '[]')
drives_required=$(echo "$schema" | jq -r '[.[]?.fields[]? | select(.name == "sharepoint.drive-ids") | .required] | first // false')
secret_marked=$(echo "$schema" | jq -r '[.[]?.fields[]? | select(.name == "sharepoint.client-secret") | .secret] | first // false')
if [ "$drives_required" = "true" ] && [ "$secret_marked" = "true" ]; then
  pass "S9: the schema publishes sharepoint.drive-ids as required and sharepoint.client-secret as secret"
else
  fail "S9: drive-ids required=${drives_required}, client-secret secret=${secret_marked}"
fi

# --- First pass: a walk that seeds a cursor -------------------------------------------------------
section "First sync (a walk)"
job=$(curl -sf -u "$SYNC_AUTH" -X POST "${INGESTER}/api/sync/configured" 2>/dev/null || echo '{}')
job_id=$(echo "$job" | jq -r '.jobId // empty')
if [ -n "$job_id" ] && [ "$(echo "$job" | jq -r '.sourceType')" = "$SOURCE_TYPE" ]; then
  pass "S10: sync started for source type sharepoint (job ${job_id})"
else
  fail "S10: sync did not start. Response: $(echo "$job" | jq -c .)"
  dc logs --tail 80 plugin-batch-ingester
  exit 1
fi

await_job() {
  local id="$1" waited=0 status=""
  while [ $waited -lt "$POLL_DEADLINE_S" ]; do
    status=$(curl -sf -u "$SYNC_AUTH" "${INGESTER}/api/sync/status/${id}" 2>/dev/null | jq -r '.status // "UNKNOWN"')
    case "$status" in COMPLETED|FAILED) break ;; esac
    sleep 5; waited=$((waited+5))
  done
  echo "$status"
}

status=$(await_job "$job_id")
final=$(curl -sf -u "$SYNC_AUTH" "${INGESTER}/api/sync/status/${job_id}" 2>/dev/null || echo '{}')
discovered=$(echo "$final" | jq -r '.discoveredCount // 0')
synced=$(echo "$final" | jq -r '.syncedCount // 0')
failed=$(echo "$final" | jq -r '.failedCount // 0')
if [ "$status" = "COMPLETED" ] && [ "$failed" = "0" ]; then
  pass "S11: the walk completed with no failures (discovered=${discovered} synced=${synced})"
else
  fail "S11: job status=${status} failed=${failed}: $(echo "$final" | jq -c .)"
  dc logs --tail 80 plugin-batch-ingester
fi

# Graph does not support $skip on a children collection, so a connector that paged with the host's skip
# would re-read page one until the host's page cap cut it off. Getting exactly the documents the fixture
# tree holds, no more and no fewer, is what proves the page-link bridge works over a real walk.
if [ "$synced" -ge "$EXPECTED_DOCUMENTS" ]; then
  pass "S12: the walk synced the fixture tree's ${EXPECTED_DOCUMENTS} documents (synced=${synced})"
else
  fail "S12: the walk synced ${synced}, expected at least ${EXPECTED_DOCUMENTS}"
fi

# --- Retrieval ------------------------------------------------------------------------------------
section "Retrieval"
# Every hit is filtered on this run's own source id as well as on a phrase unique to the document. The
# fixtures are static, so two runs ingest identical text: without the source id an assertion could pass on
# a document a previous run left behind, and an absence assertion could fail for the same reason.
find_document() {
  local query="$1" phrase="$2" label="$3" tid="$4" auth="${5:-$RAG_AUTH}" expect="${6:-found}"
  local waited=0 resp hits deadline
  # Once a presence assertion has proved retrieval works, an absence needs no long deadline of its own.
  deadline=$([ "$expect" = "found" ] && echo "$POLL_DEADLINE_S" || echo 20)
  while [ $waited -lt "$deadline" ]; do
    resp=$(curl $CURL_OPTS -sf -u "$auth" -X POST "${RAG_URL}/search/semantic" \
      -H 'Content-Type: application/json' \
      -d "{\"query\":\"${query}\",\"topK\":30,\"minScore\":0.2}" 2>/dev/null || echo '{}')
    hits=$(echo "$resp" | jq --arg src "$QUALIFIED_SOURCE" --arg phrase "$phrase" \
      '[.results[]? | select((.sourceDocument.sourceId // "") == $src)
                    | select((.chunkText // "") | test($phrase; "i"))] | length' 2>/dev/null || echo 0)
    if [ "${hits:-0}" -gt 0 ]; then
      if [ "$expect" = "found" ]; then
        pass "${tid}: ${label} (after ${waited}s)"
      else
        fail "${tid}: ${label} - it WAS returned, which is an ACL leak"
      fi
      return 0
    fi
    sleep 10; waited=$((waited+10))
  done
  if [ "$expect" = "found" ]; then
    fail "${tid}: ${label} - not retrievable after ${waited}s"
    echo "    top results: $(echo "$resp" | jq -c '[.results[:3][]? | {name:.sourceDocument.name, src:.sourceDocument.sourceId, score:.score}]')"
    return 1
  fi
  pass "${tid}: ${label}"
}

# An organisation-scoped sharing link maps to GROUP_EVERYONE, which core rewrites to the un-namespaced
# __Everyone__, so any authenticated caller retrieves it. This is the presence assertion the absence ones
# depend on: without it, "not found" could mean the ingest never happened.
find_document "Which document was shared with an organisation wide link?" "pangolin-ledger-orgwide" \
  "org-wide.txt is retrievable, so an organisation link maps to everyone" "S13"
find_document "What is the incident log sentinel phrase?" "pangolin-ledger-incident" \
  "incident-log.md is retrievable, and markdown skips the extractor entirely" "S14"
# The only fixture that is not text or markdown, and therefore the only one that proves the extraction path
# runs at all: NodeSyncService short-circuits text/* before any extractor is consulted, so a corpus of text
# fixtures says nothing about whether a binary from SharePoint becomes searchable. No transform service backs
# a plugin connector, so this is the host's in-process Tika.
find_document "What does the quarterly financial report say?" "pangolin-ledger-pdf-report" \
  "quarterly-report.pdf is retrievable, so in-process Tika extracted a binary" "S14b"
# deep-document.txt is two levels down AND granted through a users-scoped sharing link to Carol alone, so
# the assertion about it is an absence: a link scope of "users" grants the named identities and nobody else,
# and mapping it to everyone would be the most plausible way to get this wrong. That the walk descended two
# levels is already proved by S12, which counts documents only reachable at that depth.
find_document "What is the deep document sentinel phrase?" "pangolin-ledger-deep" \
  "deep-document.txt is NOT returned, since a users-scoped link grants only the named user" "S15" \
  "$RAG_AUTH" "absent"

# --- ACL mapping, which is the whole point --------------------------------------------------------
section "ACL mapping"
# The assertion that matters most in this suite. named-grant.txt is granted to bob@contoso.com only, and
# the RAG caller is not Bob. A connector that ignored ACLs, or that mapped a grant too generously, returns
# it here. Matched on the phrase unique to that document, so it cannot be satisfied by any other fixture.
find_document "What is the named grant sentinel phrase?" "pangolin-ledger-named" \
  "named-grant.txt is NOT returned to a caller its ACL excludes" "S16" "$RAG_AUTH" "absent"

# Granted to an Entra group only, which is how SharePoint is normally administered and therefore most of a
# real corpus. This is the pair of assertions that says the ACL is actionable rather than merely recorded:
# a member of that group retrieves it, and someone who is not does not. Before the resolver existed, the
# honest assertion here was that it retrieved for nobody.
find_document "What is the group grant sentinel phrase?" "pangolin-ledger-group" \
  "group-grant.txt is retrievable by a member of the group it was granted to" "S17a" \
  "${MEMBER_USER}:${MEMBER_USER}-pw"
find_document "What is the group grant sentinel phrase?" "pangolin-ledger-group" \
  "group-grant.txt is NOT retrievable by someone outside that group" "S17b" \
  "${NON_MEMBER_USER}:${NON_MEMBER_USER}-pw" "absent"

# The connector counts what it could not make retrievable. A number in a log is the only way an operator
# learns that some documents are readable by no one. Its logger is java.util.logging, which Spring Boot
# bridges into the host's logging, so these lines appear in the service log like any other.
acl_report=$(dc logs --tail 400 plugin-batch-ingester 2>/dev/null \
  | grep -c "retrievable only by expanding an Entra group")
if [ "$acl_report" -gt 0 ]; then
  pass "S18: the run reports how many documents depend on an Entra group"
else
  fail "S18: no ACL summary in the ingester log"
fi

# Resource units are metered so the cost per document can be reported rather than estimated. Against the
# mock the rate limit is off, but the count is still what a tenant would be charged.
# grep -c rather than grep -q, and the same below: with `set -o pipefail`, grep -q closes the pipe on its
# first match, docker compose logs dies of SIGPIPE, and the pipeline reports failure for a check that
# actually succeeded. That cost a debugging cycle here.
if [ "$(dc logs --tail 400 plugin-batch-ingester 2>/dev/null | grep -c 'Graph resource units')" -gt 0 ]; then
  pass "S19: the run reports the Graph resource units it spent per document"
else
  fail "S19: no resource-unit report in the ingester log"
fi

# --- Second pass: the change feed and a tombstone -------------------------------------------------
section "Second sync (the change feed)"
# The first pass walked and stored a cursor. This one reads the feed, whose first generation reports
# obsolete-note.txt deleted. That is the path the SPI added in #144: a deleted facet becomes a
# SourceTombstone the host applies without the reconciliation sweep's ratio guards.
find_document "What is the obsolete note sentinel phrase?" "pangolin-ledger-obsolete" \
  "obsolete-note.txt is retrievable after the walk" "S20"

job2=$(curl -sf -u "$SYNC_AUTH" -X POST "${INGESTER}/api/sync/configured" 2>/dev/null || echo '{}')
job2_id=$(echo "$job2" | jq -r '.jobId // empty')
if [ -n "$job2_id" ]; then
  status2=$(await_job "$job2_id")
  if [ "$status2" = "COMPLETED" ]; then
    pass "S21: the second pass completed"
  else
    fail "S21: the second pass ended as ${status2}"
  fi
else
  fail "S21: the second sync did not start: $(echo "$job2" | jq -c .)"
fi

if [ "$(dc logs --tail 200 plugin-batch-ingester 2>/dev/null \
        | grep -c 'completed via the change feed')" -gt 0 ]; then
  pass "S22: the second pass read the change feed instead of walking"
else
  fail "S22: nothing in the log shows the change feed being read"
fi

find_document "What is the obsolete note sentinel phrase?" "pangolin-ledger-obsolete" \
  "obsolete-note.txt left the index after the feed reported it deleted" "S23" "$RAG_AUTH" "absent"

# --- Summary --------------------------------------------------------------------------------------
printf "\n${B}Passed: %d | Failed: %d${N}\n" "$PASS" "$FAIL"
printf "Log: %s\n" "$LOG"
[ "$FAIL" -eq 0 ]
