#!/usr/bin/env bash
# Warn when LLM_MODEL is not a name the vLLM service in compose.ai.yaml answers to.
#
# vLLM accepts only its served model names (--served-model-name, or --model when that
# flag is absent), and rejects a chat request for any other name. The names are read
# from the rendered compose config, so variables in the vLLM command are resolved.
#
# Usage: scripts/check-vllm-model.sh   (reads LLM_MODEL from the environment)

set -euo pipefail

cd "$(dirname "$0")/.."

docker compose -f compose.ai.yaml config --format json | python3 -c '
import json, os, sys
cmd = json.load(sys.stdin)["services"]["vllm"].get("command") or []
if isinstance(cmd, str):
    cmd = cmd.split()

def values(flag):
    if flag not in cmd:
        return []
    out = []
    for arg in cmd[cmd.index(flag) + 1:]:
        if arg.startswith("--"):
            break
        out.append(arg)
    return out

names = values("--served-model-name") or values("--model")
model = os.environ.get("LLM_MODEL") or "<unset>"
if names and model not in names:
    served = ", ".join(names)
    print(f"WARNING: vLLM serves {served} but LLM_MODEL={model}.", file=sys.stderr)
    print(f"         Set LLM_MODEL={names[0]} in .env.local.", file=sys.stderr)
'
