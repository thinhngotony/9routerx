#!/usr/bin/env bash
# install_auto_update_cron.sh — install or update the 9router auto-update cron job.
#
# Usage:
#   install_auto_update_cron.sh <script_path> [log_path]
#
# Arguments:
#   script_path   Path to auto-update.py
#   log_path      Path to log file (default: ~/.9router/auto-update.log)
#
# The cron runs once daily at a random off-peak minute.
# If an entry for the same script already exists, it is replaced (idempotent).
set -euo pipefail

SCRIPT_PATH="${1:?Usage: $0 <script_path> [log_path]}"
LOG_PATH="${2:-$HOME/.9router/auto-update.log}"

PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "python3 is required but not found" >&2
  exit 1
fi

if [[ ! -f "$SCRIPT_PATH" ]]; then
  echo "auto-update script not found: $SCRIPT_PATH" >&2
  exit 1
fi

mkdir -p "$(dirname "$LOG_PATH")"

# Pick a stable daily minute based on machine-id (avoids thundering herd).
# Falls back to a fixed hour:minute if machine-id is unavailable.
if command -v python3 >/dev/null 2>&1; then
  HOUR="$(python3 -c 'import hashlib,os; m=os.environ.get("MACHINE_ID",""); h=int(hashlib.md5(m.encode()).hexdigest(),16)%24 if m else 3; print(h)')"
  MINUTE="$(python3 -c 'import hashlib,os; m=os.environ.get("MACHINE_ID",""); h=int(hashlib.md5((m+"min").encode()).hexdigest(),16)%60 if m else 17; print(h)')"
else
  HOUR=3
  MINUTE=17
fi

CRON_LINE="${MINUTE} ${HOUR} * * * $PYTHON_BIN \"$SCRIPT_PATH\" --quiet >> \"$LOG_PATH\" 2>&1"

# Read existing crontab, strip any previous entry for this script, then append new line.
tmp_cron="$(mktemp)"
trap 'rm -f "$tmp_cron"' EXIT

existing_cron="$(crontab -l 2>/dev/null || true)"

if printf '%s\n' "$existing_cron" | grep -qF "$SCRIPT_PATH"; then
  printf '%s\n' "$existing_cron" | grep -vF "$SCRIPT_PATH" > "$tmp_cron" || true
  printf "Updated cron entry\n"
else
  printf '%s\n' "$existing_cron" > "$tmp_cron" || true
  printf "Installed cron entry\n"
fi

echo "$CRON_LINE" >> "$tmp_cron"
crontab "$tmp_cron"

printf "Schedule: daily at %02d:%02d UTC\n" "$HOUR" "$MINUTE"
printf "Log:      %s\n" "$LOG_PATH"
