#!/usr/bin/env bash
# Download a Hugging Face model into a Hugging Face cache directory with curl.
#
# From some AWS hosts the Hugging Face CDN drops about one connection in three.
# huggingface_hub (and so vLLM and TEI) hangs on such a connection and never
# recovers. curl resumes, detects a stalled transfer, and retries. The result
# is the normal cache layout (blobs, snapshots, refs), so vLLM finds the model
# with no download. Safe to re-run: complete files are skipped.
#
# Usage: scripts/fetch-hf-weights.sh <repo> [cache_dir]
# Example: sudo scripts/fetch-hf-weights.sh allenai/Olmo-3-7B-Instruct /opt/models
# Set HF_TOKEN to lift the anonymous rate limit.

set -euo pipefail

REPO="${1:?usage: $0 <repo> [cache_dir]}"
CACHE="${2:-$HOME/.cache/huggingface}"
command -v curl >/dev/null && command -v python3 >/dev/null && command -v sha256sum >/dev/null || {
  echo "curl, python3 and sha256sum are required" >&2; exit 1
}

AUTH=()
[[ -n "${HF_TOKEN:-}" ]] && AUTH=(-H "Authorization: Bearer $HF_TOKEN")
API="https://huggingface.co/api/models/$REPO"

REV=$(curl -sf "${AUTH[@]}" -m 30 "$API" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])')
MODEL_DIR="$CACHE/hub/models--${REPO//\//--}"
mkdir -p "$MODEL_DIR/blobs" "$MODEL_DIR/refs" "$MODEL_DIR/snapshots/$REV"

# One line per file: path, size, blob name, "lfs" or "git".
curl -sf "${AUTH[@]}" -m 30 "$API/tree/$REV?recursive=true" | python3 -c '
import json, sys
for f in json.load(sys.stdin):
    if f["type"] != "file":
        continue
    lfs = f.get("lfs")
    print(f["path"], f["size"], lfs["oid"] if lfs else f["oid"], "lfs" if lfs else "git")
' | while read -r path size blob kind; do
  target="$MODEL_DIR/blobs/$blob"
  if [[ "$(stat -c %s "$target" 2>/dev/null || echo -1)" != "$size" ]]; then
    part="$target.curl"
    for n in $(seq 1 200); do
      curl -sL -C - "${AUTH[@]}" --connect-timeout 10 --speed-limit 20000 --speed-time 30 \
        -o "$part" "https://huggingface.co/$REPO/resolve/$REV/$path" || true
      have=$(stat -c %s "$part" 2>/dev/null || echo 0)
      [[ "$have" == "$size" ]] && break
      echo "  $path: $have of $size bytes, retry $n" >&2
      sleep 3
    done
    [[ "$(stat -c %s "$part" 2>/dev/null || echo 0)" == "$size" ]] || { echo "Gave up on $path" >&2; exit 1; }
    if [[ "$kind" == lfs ]]; then
      echo "$blob  $part" | sha256sum -c --quiet - || { echo "SHA-256 mismatch on $path" >&2; rm -f "$part"; exit 1; }
    fi
    mv "$part" "$target"
  fi
  link="$MODEL_DIR/snapshots/$REV/$path"
  mkdir -p "$(dirname "$link")"
  ln -sfn "$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))' "$target" "$link")" "$link"
  echo "ok  $path"
done

printf '%s' "$REV" > "$MODEL_DIR/refs/main"
du -sh "$MODEL_DIR"
