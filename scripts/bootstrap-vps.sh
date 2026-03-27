#!/usr/bin/env bash
set -euo pipefail

MODE="install"
if [[ "${1:-}" == "--sync-only" ]]; then
  MODE="sync-only"
  shift
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 [--sync-only] <user@host> [ssh_port]"
  echo "Examples:"
  echo "  $0 root@203.0.113.10 22"
  echo "  $0 --sync-only root@203.0.113.10 22"
  exit 1
fi

TARGET_HOST="$1"
SSH_PORT="${2:-22}"

log() { printf "[9routerx-bootstrap] %s\n" "$*"; }
warn() { printf "[9routerx-bootstrap][warn] %s\n" "$*" >&2; }

read_cursor_auth_from_db() {
  python3 - <<'PY'
import os
import sqlite3
import sys

paths = [
    os.path.expanduser("~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"),  # macOS
    os.path.expanduser("~/.config/Cursor/User/globalStorage/state.vscdb"),  # Linux
    os.path.expanduser("~/.config/cursor/User/globalStorage/state.vscdb"),  # Linux lowercase
]

db_path = next((p for p in paths if os.path.exists(p)), None)
if not db_path:
    print("ERROR: Cursor database not found. Open Cursor IDE at least once.", file=sys.stderr)
    sys.exit(2)

conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute("CREATE TABLE IF NOT EXISTS ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")

def get_value(key: str) -> str:
    row = cur.execute("SELECT value FROM ItemTable WHERE key = ?", (key,)).fetchone()
    if not row:
        return ""
    v = row[0]
    if isinstance(v, bytes):
        return v.decode("utf-8", errors="ignore")
    return str(v)

access = get_value("cursorAuth/accessToken")
refresh = get_value("cursorAuth/refreshToken")
email = get_value("cursorAuth/cachedEmail")
conn.close()

if not access or not refresh:
    print("ERROR: Cursor tokens missing in local DB. Re-login Cursor first.", file=sys.stderr)
    sys.exit(3)

print(access)
print(refresh)
print(email)
PY
}

log "Extracting Cursor auth tokens from local Cursor DB"
mapfile -t TOKENS < <(read_cursor_auth_from_db)
CURSOR_ACCESS_TOKEN="${TOKENS[0]:-}"
CURSOR_REFRESH_TOKEN="${TOKENS[1]:-}"
CURSOR_EMAIL="${TOKENS[2]:-}"

if [[ -z "$CURSOR_ACCESS_TOKEN" || -z "$CURSOR_REFRESH_TOKEN" ]]; then
  warn "Could not extract required Cursor tokens"
  exit 1
fi

log "Extracted tokens (access=${#CURSOR_ACCESS_TOKEN} chars, refresh=${#CURSOR_REFRESH_TOKEN} chars)"

ACCESS_B64="$(printf '%s' "$CURSOR_ACCESS_TOKEN" | base64 | tr -d '\n')"
REFRESH_B64="$(printf '%s' "$CURSOR_REFRESH_TOKEN" | base64 | tr -d '\n')"
EMAIL_B64="$(printf '%s' "$CURSOR_EMAIL" | base64 | tr -d '\n')"

if [[ "$MODE" == "sync-only" ]]; then
  log "Connecting to ${TARGET_HOST} and refreshing Cursor tokens only"
else
  log "Connecting to ${TARGET_HOST} and running remote installer"
fi
ssh -p "$SSH_PORT" "$TARGET_HOST" \
  "CURSOR_ACCESS_TOKEN_B64='$ACCESS_B64' CURSOR_REFRESH_TOKEN_B64='$REFRESH_B64' CURSOR_EMAIL_B64='$EMAIL_B64' BOOTSTRAP_MODE='$MODE' bash -s" <<'REMOTE'
set -euo pipefail

decode_b64() {
  # GNU coreutils on Linux supports -d. Keep fallback for portability.
  if base64 --help 2>/dev/null | grep -q -- '-d'; then
    printf '%s' "$1" | base64 -d
  else
    printf '%s' "$1" | base64 -D
  fi
}

export CURSOR_ACCESS_TOKEN="$(decode_b64 "${CURSOR_ACCESS_TOKEN_B64}")"
export CURSOR_REFRESH_TOKEN="$(decode_b64 "${CURSOR_REFRESH_TOKEN_B64}")"
export CURSOR_EMAIL="$(decode_b64 "${CURSOR_EMAIL_B64}")"

if [[ "${BOOTSTRAP_MODE:-install}" == "sync-only" ]]; then
  mkdir -p "$HOME/.config/Cursor/User/globalStorage" "$HOME/.config/cursor/User/globalStorage"
  python3 - <<'PY'
import os
import sqlite3

access = os.environ.get("CURSOR_ACCESS_TOKEN", "")
refresh = os.environ.get("CURSOR_REFRESH_TOKEN", "")
email = os.environ.get("CURSOR_EMAIL", "")

paths = [
    os.path.expanduser("~/.config/Cursor/User/globalStorage/state.vscdb"),
    os.path.expanduser("~/.config/cursor/User/globalStorage/state.vscdb"),
]

for db_path in paths:
    os.makedirs(os.path.dirname(db_path), exist_ok=True)
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    cur.execute("CREATE TABLE IF NOT EXISTS ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
    cur.execute("INSERT OR REPLACE INTO ItemTable(key, value) VALUES(?, ?)", ("cursorAuth/accessToken", access))
    cur.execute("INSERT OR REPLACE INTO ItemTable(key, value) VALUES(?, ?)", ("cursorAuth/refreshToken", refresh))
    if email:
        cur.execute("INSERT OR REPLACE INTO ItemTable(key, value) VALUES(?, ?)", ("cursorAuth/cachedEmail", email))
    conn.commit()
    conn.close()
print("Cursor token sync complete")
PY
else
  curl -sfS https://9routerx.thinhngo-tony.workers.dev/install | sh -s -- --vps-headless
fi
REMOTE

if [[ "$MODE" == "sync-only" ]]; then
  log "Token sync complete on ${TARGET_HOST}"
else
  log "Bootstrap complete on ${TARGET_HOST}"
  log "Open: http://${TARGET_HOST#*@}:20128"
fi

