#!/usr/bin/env bash
set -euo pipefail

MODE=""
OS="$(uname -s)"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() { printf "${GREEN}PASS${NC} %s\n" "$*"; }
fail() { printf "${RED}FAIL${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}WARN${NC} %s\n" "$*"; }

usage() {
  cat <<EOF
Usage: $0 [--mode <local-cursor|vps-headless>]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

tty_available() {
  [[ -e /dev/tty ]] && [[ -r /dev/tty ]] && [[ -w /dev/tty ]]
}

tty_read() {
  local prompt="$1"
  local default="${2:-}"
  local input=""

  if tty_available; then
    if [[ -n "$default" ]]; then
      printf "%s [%s]: " "$prompt" "$default" > /dev/tty
    else
      printf "%s: " "$prompt" > /dev/tty
    fi
    if ! IFS= read -r input < /dev/tty; then
      input=""
    fi
  else
    if [[ -n "$default" ]]; then
      printf "%s [%s]: " "$prompt" "$default"
    else
      printf "%s: " "$prompt"
    fi
    if ! IFS= read -r input; then
      input=""
    fi
  fi

  if [[ -z "${input:-}" ]]; then
    printf "%s" "$default"
  else
    printf "%s" "$input"
  fi
}

if [[ -z "$MODE" ]]; then
  if ! tty_available; then
    echo "Interactive mode selection requires a TTY. Re-run with --mode <local-cursor|vps-headless>." >&2
    exit 1
  fi

  echo "9routerx doctor"
  echo
  echo "Choose mode for this machine (source of checks):"
  echo "  1) local-cursor   (this machine runs Cursor IDE)"
  echo "  2) vps-headless   (server/headless install)"
  sel="$(tty_read "Select [1/2]" "")"
  case "${sel:-}" in
    1) MODE="local-cursor" ;;
    2) MODE="vps-headless" ;;
    *) echo "Invalid selection: ${sel}" >&2; exit 1 ;;
  esac
fi

echo "mode: $MODE"
echo

check_cmd() {
  local cmd="$1"
  local label="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    pass "$label ($cmd found)"
  else
    fail "$label ($cmd missing)"
  fi
}

check_file() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    pass "$label ($path)"
  else
    fail "$label ($path missing)"
  fi
}

check_9router_health() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:20128 || true)"
  if [[ "$code" =~ ^(200|307|401|403)$ ]]; then
    pass "9router HTTP health (status $code)"
  else
    warn "9router HTTP health unknown/unhealthy (status ${code:-n/a})"
  fi
}

check_localhost_resolution_trap() {
  # Many systems resolve localhost -> ::1 first. If 9router only listens on IPv4,
  # http://localhost:20128 can hang while 127.0.0.1 works.
  local code_localhost code_ipv4
  code_ipv4="$(curl -sS -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:20128/login || true)"
  code_localhost="$(curl -sS -m 2 -o /dev/null -w '%{http_code}' http://localhost:20128/login || true)"

  if [[ "$code_ipv4" =~ ^(200|307|401|403)$ ]] && [[ ! "$code_localhost" =~ ^(200|307|401|403)$ ]]; then
    warn "localhost may resolve to IPv6 (::1); prefer http://127.0.0.1:20128"
  fi
}

check_common() {
  check_cmd node "Node.js"
  check_cmd npm "npm"
  check_cmd python3 "Python 3"
  check_cmd claude "Claude Code CLI"
  check_cmd 9router "9router CLI"
  check_cmd gh "GitHub CLI (recommended for Copilot extension)"
  check_cmd antigravity-ide "antigravity-ide CLI"
  check_file "$HOME/.9router/db.json" "9router database"
  check_9router_health
  check_localhost_resolution_trap
}

check_local_cursor() {
  local db_macos="$HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
  local db_linux1="$HOME/.config/Cursor/User/globalStorage/state.vscdb"
  local db_linux2="$HOME/.config/cursor/User/globalStorage/state.vscdb"

  if command -v cursor >/dev/null 2>&1; then
    pass "Cursor CLI installed"
  else
    warn "Cursor CLI not found (can still work if desktop app exists)"
  fi

  if [[ -f "$db_macos" || -f "$db_linux1" || -f "$db_linux2" ]]; then
    pass "Cursor state.vscdb exists"
  else
    fail "Cursor state.vscdb missing (open Cursor IDE and sign in)"
  fi
}

check_vps_headless() {
  local db1="$HOME/.config/Cursor/User/globalStorage/state.vscdb"
  local db2="$HOME/.config/cursor/User/globalStorage/state.vscdb"
  local startup_log="$HOME/.9router/startup.log"

  check_file "$db1" "Headless Cursor DB (uppercase path)"
  check_file "$db2" "Headless Cursor DB (lowercase path)"

  if pgrep -f "$(command -v 9router || echo 9router)" >/dev/null 2>&1; then
    pass "9router process running"
  else
    fail "9router process not running"
  fi

  if [[ -f "$startup_log" ]]; then
    pass "9router startup log exists"
  else
    warn "No startup log yet ($startup_log)"
  fi

  warn "Cursor provider on VPS is optional; use install.sh --sync-to <user@host> for token refresh."
}

check_common
echo
if [[ "$MODE" == "local-cursor" ]]; then
  check_local_cursor
elif [[ "$MODE" == "vps-headless" ]]; then
  check_vps_headless
else
  fail "Invalid mode: $MODE"
  exit 1
fi

