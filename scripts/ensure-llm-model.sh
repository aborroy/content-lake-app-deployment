#!/usr/bin/env bash
# Make sure LLM_MODEL is present in Docker Model Runner before a stack starts.
#
# The default, local/olmo3-7b-instruct:Q4_K_M, is a local package that no registry
# serves, so a fresh machine has to build it once with package-olmo3-local.sh.
# An ai/* model is pulled when it is missing. Any other name is left alone: it is
# served by something else, such as the vLLM stack in compose.ai.yaml.
#
# Fast when the model is already present: one `docker model inspect`, no smoke test.
#
# Usage: scripts/ensure-llm-model.sh   (reads LLM_MODEL from the environment)

set -euo pipefail

OLMO_MODEL="local/olmo3-7b-instruct:Q4_K_M"
MODEL="${LLM_MODEL:-$OLMO_MODEL}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

case "$MODEL" in
  "$OLMO_MODEL"|ai/*) ;;
  *) exit 0 ;;
esac

if ! docker model list >/dev/null 2>&1; then
  echo "WARNING: Docker Model Runner is not available, cannot check LLM_MODEL=$MODEL." >&2
  echo "         Enable it in Docker Desktop, or set LLM_MODEL to the model your backend serves." >&2
  exit 0
fi

if docker model inspect "$MODEL" >/dev/null 2>&1; then
  exit 0
fi

if [ "$MODEL" = "$OLMO_MODEL" ]; then
  echo "-> $MODEL is missing, packaging it once (downloads about 4.2 GB)..."
  "$SCRIPT_DIR/package-olmo3-local.sh"
else
  echo "-> $MODEL is missing, pulling it..."
  docker model pull "$MODEL"
fi
