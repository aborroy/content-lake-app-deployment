#!/usr/bin/env bash

set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost/nuxeo}"
NUXEO_USERNAME="${NUXEO_USERNAME:-Administrator}"
NUXEO_PASSWORD="${NUXEO_PASSWORD:-Administrator}"
WORKSPACE_PARENT_PATH="/default-domain/workspaces"
WORKSPACE_NAME="content-lake-demo"
WORKSPACE_TITLE="Content Lake Demo"
TITLE=""
FILENAME=""
TEXT=""
INPUT_FILE=""
MIME_TYPE="text/plain"

usage() {
  cat <<'EOF'
Usage: create-nuxeo-demo-file.sh [options]

Create a demo Nuxeo File document through the working automation blob-attach path.

Options:
  --title TEXT             Document title
  --filename NAME          Blob filename stored in Nuxeo
  --text TEXT              Inline text content to upload
  --input-file PATH        Upload content from a local file
  --mime-type TYPE         Blob MIME type (default: text/plain)
  --workspace-name NAME    Workspace name under /default-domain/workspaces
  --workspace-title TEXT   Workspace title
  --base-url URL           Nuxeo base URL (default: http://localhost/nuxeo)
  --username NAME          Nuxeo username (default: Administrator)
  --password TEXT          Nuxeo password (default: Administrator)
  --help                   Show this help

Examples:
  ./scripts/create-nuxeo-demo-file.sh
  ./scripts/create-nuxeo-demo-file.sh --title "Quarterly Notes" --text $'Line 1\nLine 2'
  ./scripts/create-nuxeo-demo-file.sh --input-file README.md --mime-type text/markdown
EOF
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

slugify() {
  local input="$1"
  printf '%s' "$input" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cs 'a-z0-9' '-' \
    | sed 's/^-//; s/-$//'
}

json_field() {
  local file_path="$1"
  local field_expr="$2"
  python3 - "$file_path" "$field_expr" <<'PY'
import json
import sys

file_path, field_expr = sys.argv[1], sys.argv[2]
with open(file_path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

value = data
for part in field_expr.split("."):
    if not part:
        continue
    value = value[part]

print(value)
PY
}

request_json() {
  local output_file="$1"
  shift
  curl -sS \
    -u "${NUXEO_USERNAME}:${NUXEO_PASSWORD}" \
    -o "$output_file" \
    -w '%{http_code}' \
    "$@"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)
      TITLE="$2"
      shift 2
      ;;
    --filename)
      FILENAME="$2"
      shift 2
      ;;
    --text)
      TEXT="$2"
      shift 2
      ;;
    --input-file)
      INPUT_FILE="$2"
      shift 2
      ;;
    --mime-type)
      MIME_TYPE="$2"
      shift 2
      ;;
    --workspace-name)
      WORKSPACE_NAME="$2"
      shift 2
      ;;
    --workspace-title)
      WORKSPACE_TITLE="$2"
      shift 2
      ;;
    --base-url)
      BASE_URL="$2"
      shift 2
      ;;
    --username)
      NUXEO_USERNAME="$2"
      shift 2
      ;;
    --password)
      NUXEO_PASSWORD="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

require_cmd curl
require_cmd mktemp
require_cmd python3

[[ -n "$INPUT_FILE" && -n "$TEXT" ]] && fail "Use either --input-file or --text, not both"
[[ -n "$INPUT_FILE" && ! -f "$INPUT_FILE" ]] && fail "Input file not found: $INPUT_FILE"

BASE_URL="${BASE_URL%/}"

if [[ -z "$TITLE" ]]; then
  TITLE="Demo $(date -u +'%Y-%m-%d %H:%M:%S UTC')"
fi

if [[ -n "$INPUT_FILE" ]]; then
  CONTENT_FILE="$INPUT_FILE"
  if [[ -z "$FILENAME" ]]; then
    FILENAME="$(basename "$INPUT_FILE")"
  fi
else
  CONTENT_FILE="$(mktemp)"
  if [[ -n "$TEXT" ]]; then
    printf '%s' "$TEXT" >"$CONTENT_FILE"
  else
    printf 'Content Lake demo created at %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" >"$CONTENT_FILE"
  fi
fi

cleanup() {
  if [[ -n "${CONTENT_FILE:-}" && "${INPUT_FILE:-}" != "$CONTENT_FILE" && -f "$CONTENT_FILE" ]]; then
    rm -f "$CONTENT_FILE"
  fi
  rm -f "${WORKSPACE_RESPONSE:-}" "${DOCUMENT_RESPONSE:-}" "${ATTACH_RESPONSE:-}" "${VERIFY_RESPONSE:-}"
}
trap cleanup EXIT

if [[ -z "$FILENAME" ]]; then
  base_name="$(slugify "$TITLE")"
  [[ -z "$base_name" ]] && base_name="demo-file"
  FILENAME="${base_name}.txt"
fi

WORKSPACE_PATH="${WORKSPACE_PARENT_PATH%/}/${WORKSPACE_NAME}"
WORKSPACE_RESPONSE="$(mktemp)"
DOCUMENT_RESPONSE="$(mktemp)"
ATTACH_RESPONSE="$(mktemp)"
VERIFY_RESPONSE="$(mktemp)"

workspace_status="$(request_json "$WORKSPACE_RESPONSE" "${BASE_URL}/api/v1/path${WORKSPACE_PATH}")"
case "$workspace_status" in
  200)
    ;;
  404)
    workspace_payload="$(
      WORKSPACE_NAME="$WORKSPACE_NAME" WORKSPACE_TITLE="$WORKSPACE_TITLE" python3 - <<'PY'
import json
import os

print(json.dumps({
    "entity-type": "document",
    "name": os.environ["WORKSPACE_NAME"],
    "type": "Workspace",
    "properties": {
        "dc:title": os.environ["WORKSPACE_TITLE"],
    },
}))
PY
    )"
    workspace_status="$(
      request_json \
        "$WORKSPACE_RESPONSE" \
        -X POST \
        "${BASE_URL}/api/v1/path${WORKSPACE_PARENT_PATH}" \
        -H 'Content-Type: application/json' \
        --data "$workspace_payload"
    )"
    [[ "$workspace_status" == "201" ]] || fail "Workspace creation failed (HTTP ${workspace_status}): $(cat "$WORKSPACE_RESPONSE")"
    ;;
  *)
    fail "Workspace lookup failed (HTTP ${workspace_status}): $(cat "$WORKSPACE_RESPONSE")"
    ;;
esac

document_payload="$(
  TITLE="$TITLE" FILENAME="$FILENAME" python3 - <<'PY'
import json
import os

print(json.dumps({
    "entity-type": "document",
    "name": os.environ["FILENAME"],
    "type": "File",
    "properties": {
        "dc:title": os.environ["TITLE"],
    },
}))
PY
)"
document_status="$(
  request_json \
    "$DOCUMENT_RESPONSE" \
    -X POST \
    "${BASE_URL}/api/v1/path${WORKSPACE_PATH}" \
    -H 'Content-Type: application/json' \
    --data "$document_payload"
)"
[[ "$document_status" == "201" ]] || fail "Document creation failed (HTTP ${document_status}): $(cat "$DOCUMENT_RESPONSE")"

DOCUMENT_UID="$(json_field "$DOCUMENT_RESPONSE" "uid")"
DOCUMENT_PATH="$(json_field "$DOCUMENT_RESPONSE" "path")"

automation_params="$(
  DOCUMENT_UID="$DOCUMENT_UID" python3 - <<'PY'
import json
import os

print(json.dumps({
    "params": {
        "document": os.environ["DOCUMENT_UID"],
        "save": True,
        "xpath": "file:content",
    }
}))
PY
)"
attach_status="$(
  request_json \
    "$ATTACH_RESPONSE" \
    -X POST \
    "${BASE_URL}/api/v1/automation/Blob.AttachOnDocument" \
    -F "params=${automation_params};type=application/json" \
    -F "input=@${CONTENT_FILE};filename=${FILENAME};type=${MIME_TYPE}"
)"
[[ "$attach_status" == "200" ]] || fail "Blob attach failed (HTTP ${attach_status}): $(cat "$ATTACH_RESPONSE")"

verify_status="$(request_json "$VERIFY_RESPONSE" "${BASE_URL}/api/v1/id/${DOCUMENT_UID}?properties=*")"
[[ "$verify_status" == "200" ]] || fail "Document verification failed (HTTP ${verify_status}): $(cat "$VERIFY_RESPONSE")"

BLOB_LENGTH="$(json_field "$VERIFY_RESPONSE" "properties.file:content.length")"
BLOB_DIGEST="$(json_field "$VERIFY_RESPONSE" "properties.file:content.digest")"

cat <<EOF
Created Nuxeo demo document.
Workspace: ${WORKSPACE_PATH}
UID: ${DOCUMENT_UID}
Path: ${DOCUMENT_PATH}
Blob filename: ${FILENAME}
Blob MIME type: ${MIME_TYPE}
Blob length: ${BLOB_LENGTH}
Blob digest: ${BLOB_DIGEST}

Trigger sync:
curl -u ${NUXEO_USERNAME}:${NUXEO_PASSWORD} -X POST '${BASE_URL%/nuxeo}/api/sync/configured?sourceType=nuxeo'
EOF
