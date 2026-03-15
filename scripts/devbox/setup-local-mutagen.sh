#!/usr/bin/env bash
set -euo pipefail

# Set up a Mutagen sync session for local->remote handoff (single-writer model).
# Git remains authoritative for .git/history; .git is excluded from sync.
#
# Usage: setup-local-mutagen.sh <local-path> <remote-endpoint>
# Example: setup-local-mutagen.sh "$HOME/src/grpc" "devbox-alias:/C:/dev/grpc"

SESSION_NAME="devbox-handoff"

LOCAL_PATH="${1:?local path required}"
REMOTE_ENDPOINT="${2:?remote endpoint required}"

if mutagen sync list 2>/dev/null | grep -qE "Name:\s*${SESSION_NAME}([[:space:]]|$)"; then
  echo "Error: Mutagen session '${SESSION_NAME}' already exists." >&2
  echo "Do not create it again. Use 'mutagen sync list' to check health, or 'mutagen sync terminate ${SESSION_NAME}' to remove it before recreating." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IGNORE_FILE="${SCRIPT_DIR}/mutagen.ignore"

IGNORE_ARGS=()
if [[ -f "$IGNORE_FILE" ]]; then
  while IFS= read -r line || [[ -n "${line:-}" ]]; do
    line="${line%%#*}"
    line="${line%"${line##*[![:space:]]}"}"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" ]] && continue
    IGNORE_ARGS+=(-i "$line")
  done < "$IGNORE_FILE"
fi

mutagen sync create \
  --name="${SESSION_NAME}" \
  --mode="two-way-safe" \
  --ignore-vcs \
  "${IGNORE_ARGS[@]}" \
  "$LOCAL_PATH" \
  "$REMOTE_ENDPOINT"
