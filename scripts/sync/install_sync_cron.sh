#!/usr/bin/env bash
# install_sync_cron.sh — install or update the 9routerx sync cron job.
#
# Usage:
#   install_sync_cron.sh <script_path> [log_path] [extra_args...]
#
# Arguments:
#   script_path   Path to 9router_claude_sync.py
#   log_path      Path to log file (default: ~/.9router/claude-sync.log)
#   extra_args    Additional args forwarded to the sync script every run,
#                 e.g. "--router-url http://IP:20128 --sync-cursor --sync-shell"
#
# The cron runs every minute. If an entry for the same script already exists,
# it is replaced with the new line (idempotent update).
set -euo pipefail

SCRIPT_PATH="${1:?Usage: $0 <script_path> [log_path] [extra_args...]}"
LOG_PATH="${2:-$HOME/.9router/claude-sync.log}"
# Everything after arg 2 is passed through to the sync script
shift 2 2>/dev/null || shift "$#" 2>/dev/null || true
EXTRA_ARGS="${*:-}"

PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "python3 is required but not found" >&2
  exit 1
fi

if [[ ! -f "$SCRIPT_PATH" ]]; then
  echo "sync script not found: $SCRIPT_PATH" >&2
  exit 1
fi

mkdir -p "$(dirname "$LOG_PATH")"

CRON_LINE="*/1 * * * * $PYTHON_BIN \"$SCRIPT_PATH\" ${EXTRA_ARGS:+$EXTRA_ARGS }--quiet >> \"$LOG_PATH\" 2>&1"

# Read existing crontab, strip any previous entry for this script, then append new line.
tmp_cron="$(mktemp)"
trap 'rm -f "$tmp_cron"' EXIT

existing_cron="$(crontab -l 2>/dev/null || true)"

if printf '%s\n' "$existing_cron" | grep -qF "$SCRIPT_PATH"; then
  # Replace existing entry
  printf '%s\n' "$existing_cron" | grep -vF "$SCRIPT_PATH" > "$tmp_cron" || true
  echo "Updated existing cron entry for $SCRIPT_PATH"
else
  printf '%s\n' "$existing_cron" > "$tmp_cron" || true
  echo "Installing new cron entry for $SCRIPT_PATH"
fi

echo "$CRON_LINE" >> "$tmp_cron"
crontab "$tmp_cron"

echo ""
echo "Active cron line:"
echo "  $CRON_LINE"
