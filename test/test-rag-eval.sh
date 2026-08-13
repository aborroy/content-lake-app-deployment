#!/usr/bin/env bash
# test-rag-eval.sh -- retrieval-quality regression gate.
#
# Wraps the content-lake-eval harness (../content-lake-eval) so a drop in retrieval quality fails
# the deployment suite instead of shipping silently. The other suites assert that a document can be
# found at all; this one asserts that retrieval is not getting worse.
#
# Runs tier 0 (deterministic retrieval metrics) and tier 1 (latency) only. The LLM-as-judge tier
# needs an API key and costs money per run, so it stays out of the automated suite and is invoked
# by hand per sprint.
#
# Inherits HOST, USE_HTTPS, ALF_AUTH and NUXEO_AUTH from run-tests.sh.
#
# Standalone:
#   ./test/test-rag-eval.sh
#
# Exit codes: 0 pass, 1 regression or harness failure, 2 prerequisites missing (skipped).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EVAL_DIR="$(cd "$DEPLOY_DIR/../content-lake-eval" 2>/dev/null && pwd || true)"

HOST="${HOST:-localhost}"
USE_HTTPS="${USE_HTTPS:-true}"
export HOST USE_HTTPS
export ALF_AUTH="${ALF_AUTH:-admin:admin}"
export NUXEO_AUTH="${NUXEO_AUTH:-Administrator:Administrator}"
if [ "$USE_HTTPS" = "true" ]; then SCHEME="https"; CURL_TLS="-k"; else SCHEME="http"; CURL_TLS=""; fi
BASE="${SCHEME}://${HOST}"

CONFIG="${CLEVAL_CONFIG:-config/baseline.yaml}"
BASELINE="${CLEVAL_BASELINE:-runs/baseline}"

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
banner() { printf "\n${B}${C}--- %s${N}\n" "$*"; }
info() { printf "${C}[INFO]${N} %s\n" "$*"; }
warn() { printf "${Y}[WARN]${N} %s\n" "$*"; }
fail() { printf "${R}[FAIL]${N} %s\n" "$*"; }
ok()   { printf "${G}[OK]${N}   %s\n" "$*"; }

skip() { warn "$*"; warn "Skipping the retrieval-quality gate."; exit 2; }

banner "Retrieval quality gate (content-lake-eval)"

# -- Prerequisites -------------------------------------------------------------
[ -n "$EVAL_DIR" ] || skip "../content-lake-eval not found"
command -v uv >/dev/null 2>&1 || skip "uv not found (brew install uv)"

if ! curl -sf $CURL_TLS -m 10 "$BASE/api/rag/health" >/dev/null 2>&1; then
  skip "rag-service health endpoint not reachable at $BASE/api/rag/health"
fi
ok "rag-service reachable at $BASE"

cd "$EVAL_DIR" || skip "cannot enter $EVAL_DIR"

if [ ! -f "$BASELINE/metrics.json" ]; then
  skip "no committed baseline at $EVAL_DIR/$BASELINE/metrics.json -- capture one first: \
uv run cleval ingest --config $CONFIG --clean && uv run cleval run --config $CONFIG --tier 0,1"
fi

# A baseline carrying an INVALID marker measures a corpus that cannot express a quality difference,
# so comparing against it would pass every change at +0.0000 and report that as a green gate.
if [ -f "$BASELINE/INVALID.md" ]; then
  skip "the baseline at $EVAL_DIR/$BASELINE is marked INVALID (see $BASELINE/INVALID.md) -- \
capture a replacement once the corpus clears 'uv run cleval difficulty'"
fi

info "Syncing harness dependencies"
uv sync --quiet || { fail "uv sync failed"; exit 1; }

# -- Ingest --------------------------------------------------------------------
# The gate compares against a baseline captured on this exact corpus, so the corpus must be
# present and the index must hold no stale copies of it. ingest --clean refuses to run against a
# dirty index rather than producing numbers that are not comparable.
banner "Ingesting the fixture corpus"
if ! uv run cleval ingest --config "$CONFIG" --clean; then
  fail "corpus ingest failed; the gate cannot run against a partial or duplicated index"
  exit 1
fi
ok "corpus ingested and every document verified retrievable"

# -- Difficulty floors ---------------------------------------------------------
# Runs after ingest because it probes the live index for the per-document chunk count. A corpus
# small enough that topK returns most of it, or questions that repeat their source document's
# wording, score near the ceiling however retrieval ranks -- so a green gate would mean nothing.
banner "Checking corpus difficulty floors"
if ! uv run cleval difficulty --config "$CONFIG"; then
  fail "the corpus cannot measure a retrieval improvement (see the floors above)"
  exit 1
fi
ok "difficulty floors are low enough for the gate to mean something"

# -- Measure -------------------------------------------------------------------
banner "Running tier 0 and tier 1"
if ! uv run cleval run --config "$CONFIG" --tier 0,1; then
  fail "measurement run failed"
  exit 1
fi
RUN_ID="$(cat runs/LATEST 2>/dev/null || true)"
[ -n "$RUN_ID" ] || { fail "no runs/LATEST written"; exit 1; }
ok "run $RUN_ID complete"

# -- Gate ----------------------------------------------------------------------
banner "Comparing against $BASELINE"
if uv run cleval compare "$BASELINE" "runs/$RUN_ID"; then
  ok "no retrieval regression"
  exit 0
fi
fail "retrieval regression against $BASELINE (see the delta table above)"
fail "If the change is a deliberate improvement, re-capture the baseline and commit it."
exit 1
