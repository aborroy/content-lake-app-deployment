#!/usr/bin/env bash
# Package Olmo 3 7B Instruct for Docker Model Runner with a working chat template.
#
# Every Olmo 3 GGUF on Hugging Face carries the upstream allenai chat template,
# which tests `tools is none`. When a request sends no tools, `tools` is
# undefined, not none, so the template calls `tools | tojson` on an undefined
# value. The llama.cpp in Docker Model Runner (b9879) aborts at model load with
# "Unknown (built-in) filter 'tojson' for type Undefined (hint: 'tools')", and
# every chat request returns 500.
#
# This script pulls the GGUF, rewrites the two `tools is [not] none` tests to
# plain truthiness tests, and packages the result as a local model. The weights
# are unchanged. Safe to re-run: an existing package is only smoke-tested.
#
# Usage: scripts/package-olmo3-local.sh [--force]
# local/olmo3-7b-instruct:Q4_K_M is the default LLM_MODEL in .env.

set -euo pipefail

SOURCE_MODEL="hf.co/unsloth/Olmo-3-7B-Instruct-GGUF:Q4_K_M"
TARGET_MODEL="local/olmo3-7b-instruct:Q4_K_M"
RUNNER_URL="${MODEL_RUNNER_HOST_URL:-http://localhost:12434}"
FORCE="${1:-}"

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
docker model list >/dev/null 2>&1 || {
  echo "Docker Model Runner is not available. Enable it in Docker Desktop." >&2
  exit 1
}

smoke_test() {
  echo "Smoke test: one chat completion against $RUNNER_URL (first load takes a few seconds)..."
  local body
  body=$(curl -s -m 180 "$RUNNER_URL/engines/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$TARGET_MODEL\",\"stream\":true,\"messages\":[{\"role\":\"system\",\"content\":\"Answer in one word.\"},{\"role\":\"user\",\"content\":\"Say hello\"}]}") || true
  if [[ "$body" == *'"choices"'* ]]; then
    echo "OK: $TARGET_MODEL answers"
  else
    echo "FAILED: $TARGET_MODEL did not answer. Response:" >&2
    echo "${body:0:500}" >&2
    echo "Check 'docker model logs' and that host TCP access is enabled on port 12434." >&2
    exit 1
  fi
}

if [[ "$FORCE" != "--force" ]] && docker model inspect "$TARGET_MODEL" >/dev/null 2>&1; then
  echo "$TARGET_MODEL already present (use --force to rebuild)"
  smoke_test
  exit 0
fi

if ! docker model inspect "$SOURCE_MODEL" >/dev/null 2>&1; then
  echo "Pulling $SOURCE_MODEL (about 4.2 GB)..."
  docker model pull "$SOURCE_MODEL"
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
TEMPLATE="$WORK_DIR/olmo3-chat-template.jinja"

docker model inspect "$SOURCE_MODEL" | python3 -c '
import json, sys
template = json.load(sys.stdin)["config"]["gguf"]["tokenizer.chat_template"]
fixed = (template
         .replace("if tools is not none", "if tools")
         .replace("if tools is none", "if not tools"))
if "tools is" in fixed:
    sys.exit("Unexpected chat template: a `tools is ...` test is still present")
if fixed == template:
    print("Note: the source template has no `tools is none` test; packaging it unchanged", file=sys.stderr)
open(sys.argv[1], "w").write(fixed)
' "$TEMPLATE"

echo "Packaging $TARGET_MODEL..."
# The package command prints a progress counter on one very long line.
docker model package --from "$SOURCE_MODEL" --chat-template "$TEMPLATE" "$TARGET_MODEL" \
  | tr '\r\033' '\n\n' | grep -vE '^(\[?K?Transferred.*|\[?K?)$' || true
docker model inspect "$TARGET_MODEL" >/dev/null 2>&1 || { echo "Packaging failed" >&2; exit 1; }

smoke_test
echo "$TARGET_MODEL is ready. Recreate rag-service if it is already running."
