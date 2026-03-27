#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${1:-$HOME/9router_claude_sync.py}"
LOG_PATH="${2:-$HOME/.9router/claude-sync.log}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "python3 is required but not found"
  exit 1
fi

if [[ ! -f "$SCRIPT_PATH" ]]; then
  echo "sync script not found: $SCRIPT_PATH"
  exit 1
fi

mkdir -p "$(dirname "$LOG_PATH")"

CRON_LINE="*/1 * * * * $PYTHON_BIN \"$SCRIPT_PATH\" --quiet >> \"$LOG_PATH\" 2>&1"

tmp_cron="$(mktemp)"
if crontab -l >/dev/null 2>&1; then
  crontab -l > "$tmp_cron"
fi

if grep -Fq "$SCRIPT_PATH" "$tmp_cron"; then
  echo "cron entry already exists for $SCRIPT_PATH"
  rm -f "$tmp_cron"
  exit 0
fi

echo "$CRON_LINE" >> "$tmp_cron"
crontab "$tmp_cron"
rm -f "$tmp_cron"

echo "installed cron:"
echo "$CRON_LINE"

