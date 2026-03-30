#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OS="$(uname -s)"
MODE=""
INSTALL_CURSOR="auto"

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { printf "      ${GREEN}✓${NC} %s\n" "$*"; }
info() { printf "      ${DIM}→${NC} %s\n" "$*"; }
err()  { printf "      ${RED}✗${NC} %s\n" "$*" >&2; }
wrn()  { printf "      ${YELLOW}!${NC} %s\n" "$*" >&2; }
hdr()  { printf "\n  ${BOLD}%s${NC}\n\n" "$*"; }
sep()  { printf "${DIM}  ────────────────────────────────────────────────────────────────${NC}\n"; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --mode <local-cursor|vps-headless|remote-vps|auto>
  --local-cursor            Shortcut for --mode local-cursor
  --vps-headless            Shortcut for --mode vps-headless
  --remote-vps              Shortcut for --mode remote-vps
  --install-cursor          Force Cursor install attempt
  --skip-cursor-install     Skip Cursor install step
  -h, --help                Show this help message
EOF
}

# ── Arg parsing ──────────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)           MODE="${2:-}"; shift 2 ;;
      --local-cursor)   MODE="local-cursor"; shift ;;
      --vps-headless)   MODE="vps-headless"; shift ;;
      --remote-vps)     MODE="remote-vps"; shift ;;
      --install-cursor) INSTALL_CURSOR="yes"; shift ;;
      --skip-cursor-install) INSTALL_CURSOR="no"; shift ;;
      -h|--help)        usage; exit 0 ;;
      *)                err "Unknown option: $1"; usage; exit 1 ;;
    esac
  done
}

# ── Mode selection ───────────────────────────────────────────────────────────
choose_mode_if_needed() {
  [[ -n "$MODE" ]] && return

  if [[ -t 0 ]]; then
    sep
    hdr "Choose install mode"
    printf "      ${CYAN}1)${NC} local-cursor   ${DIM}This machine runs Cursor IDE${NC}\n"
    printf "      ${CYAN}2)${NC} vps-headless   ${DIM}Server-only, optional token sync${NC}\n"
    printf "      ${CYAN}3)${NC} remote-vps     ${DIM}Install on a remote VPS via SSH${NC}\n"
    printf "      ${CYAN}4)${NC} auto           ${DIM}Linux → vps-headless, others → local-cursor${NC}\n"
    printf "\n"
    printf "  Select ${DIM}[1/2/3/4, default=4]:${NC} "
    read -r choice
    case "${choice:-4}" in
      1) MODE="local-cursor" ;;
      2) MODE="vps-headless" ;;
      3) MODE="remote-vps" ;;
      4|"") MODE="auto" ;;
      *) err "Invalid choice: ${choice}"; exit 1 ;;
    esac
    return
  fi

  MODE="auto"
}

resolve_mode() {
  choose_mode_if_needed

  case "$MODE" in
    auto)
      if [[ "$OS" == "Linux" ]]; then
        MODE="vps-headless"
      else
        MODE="local-cursor"
      fi
      ;;
    local-cursor|vps-headless|remote-vps) ;;
    *) err "Invalid mode: $MODE"; usage; exit 1 ;;
  esac

  printf "\n"
  ok "Mode: ${BOLD}${MODE}${NC}"
}

# ── npm helpers ──────────────────────────────────────────────────────────────
npm_global_install() {
  local pkg="$1"

  # Fix npm cache permission issues before install
  npm cache verify >/dev/null 2>&1 || true

  local prefix
  prefix="$(npm config get prefix 2>/dev/null || echo "")"

  # Check if we can write to the global prefix
  if [[ -n "$prefix" ]] && [[ -w "$prefix/lib" ]] 2>/dev/null; then
    npm install -g "$pkg"
  elif [[ "$(id -u)" -eq 0 ]]; then
    npm install -g "$pkg"
  elif [[ "$OS" == "Linux" ]]; then
    sudo npm install -g "$pkg"
  else
    # macOS: try fixing prefix to user-writable location
    local user_prefix="$HOME/.npm-global"
    if [[ ! -d "$user_prefix" ]]; then
      mkdir -p "$user_prefix"
      npm config set prefix "$user_prefix"
      wrn "Set npm prefix to $user_prefix — add to PATH: export PATH=\"$user_prefix/bin:\$PATH\""
    fi
    npm install -g "$pkg"
  fi
}

# ── Install helpers ──────────────────────────────────────────────────────────
install_homebrew() {
  has_cmd brew && return
  info "Homebrew not found, installing"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
  ok "Homebrew installed"
}

install_node_if_missing() {
  if has_cmd node && has_cmd npm; then
    ok "Node.js found"
    return
  fi

  case "$OS" in
    Darwin)
      install_homebrew
      info "Installing Node.js via Homebrew"
      brew install node
      ;;
    Linux)
      if has_cmd apt-get; then
        info "Installing Node.js via apt"
        sudo apt-get update -qq
        sudo apt-get install -y -qq nodejs npm
      elif has_cmd dnf; then
        info "Installing Node.js via dnf"
        sudo dnf install -y -q nodejs npm
      elif has_cmd yum; then
        info "Installing Node.js via yum"
        sudo yum install -y -q nodejs npm
      else
        err "No supported package manager found for Node.js"
        exit 1
      fi
      ;;
    *) err "Unsupported OS: $OS"; exit 1 ;;
  esac
  ok "Node.js installed"
}

npm_pkg_outdated() {
  local pkg="$1"
  local installed latest
  installed="$(npm list -g "$pkg" --depth=0 --json 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('dependencies',{}).get('$pkg',{}).get('version',''))" 2>/dev/null || echo "")"
  [[ -z "$installed" ]] && return 0  # not installed = treat as outdated
  latest="$(npm view "$pkg" version 2>/dev/null || echo "")"
  [[ -z "$latest" ]] && return 1     # can't check = assume up to date
  [[ "$installed" != "$latest" ]]
}

install_or_update_npm_pkg() {
  local cmd="$1"
  local pkg="$2"

  if has_cmd "$cmd"; then
    if npm_pkg_outdated "$pkg"; then
      local cur latest
      cur="$(npm list -g "$pkg" --depth=0 2>/dev/null | grep "$pkg@" | sed 's/.*@//' || echo "?")"
      latest="$(npm view "$pkg" version 2>/dev/null || echo "?")"
      info "Updating $pkg ($cur → $latest)"
      npm_global_install "$pkg"
      ok "$pkg updated"
    else
      ok "$cmd up to date"
    fi
    return
  fi

  info "Installing $pkg"
  npm_global_install "$pkg"
  ok "$pkg installed"
}

install_claude_code() {
  install_or_update_npm_pkg claude "@anthropic-ai/claude-code"
}

install_antigravity() {
  if has_cmd antigravity-ide || npm list -g antigravity-ide --depth=0 >/dev/null 2>&1; then
    if npm_pkg_outdated "antigravity-ide"; then
      info "Updating antigravity-ide"
      npm_global_install antigravity-ide
      ok "antigravity-ide updated"
    else
      ok "antigravity-ide up to date"
    fi
    return
  fi
  info "Installing antigravity-ide"
  npm_global_install antigravity-ide
  ok "antigravity-ide installed"
}

install_copilot_cli() {
  if has_cmd gh; then
    if gh extension list 2>/dev/null | grep -q "github/gh-copilot"; then
      info "Upgrading GitHub Copilot CLI"
      gh extension upgrade github/gh-copilot 2>/dev/null || true
      ok "GitHub Copilot CLI up to date"
    else
      info "Installing GitHub Copilot CLI via gh"
      gh extension install github/gh-copilot 2>/dev/null || true
      ok "GitHub Copilot CLI installed"
    fi
  elif has_cmd npm; then
    install_or_update_npm_pkg copilot "@githubnext/github-copilot-cli"
  else
    wrn "gh or npm required for Copilot CLI"
  fi
}

install_cursor() {
  if [[ "$INSTALL_CURSOR" == "no" ]]; then
    info "Skipping Cursor install"
    return
  fi

  if has_cmd cursor; then
    # Cursor self-updates; just confirm it's present
    ok "Cursor found"
    return
  fi

  case "$OS" in
    Darwin)
      install_homebrew
      info "Installing Cursor via Homebrew"
      brew install --cask cursor
      ok "Cursor installed"
      ;;
    Linux)
      wrn "Cursor Linux install varies — visit cursor.com/downloads"
      ;;
    *) wrn "Unsupported OS for Cursor: $OS" ;;
  esac
}

install_9router() {
  install_or_update_npm_pkg 9router "9router"
}

install_9routerx_cli() {
  local bin_dir="$HOME/.local/bin"
  local src="$ROOT_DIR/scripts/9routerx"
  local dst="$bin_dir/9routerx"

  mkdir -p "$bin_dir"

  if [[ ! -f "$src" ]]; then
    wrn "9routerx CLI source not found at $src"
    return
  fi

  cp "$src" "$dst"
  chmod +x "$dst"

  if ! echo "$PATH" | tr ':' '\n' | grep -qx "$bin_dir"; then
    wrn "Add $bin_dir to PATH to use '9routerx' globally"
  fi
  ok "9routerx CLI installed"
}

# ── Headless Cursor DB ───────────────────────────────────────────────────────
init_cursor_state_db_headless() {
  local db1="$HOME/.config/Cursor/User/globalStorage/state.vscdb"
  local db2="$HOME/.config/cursor/User/globalStorage/state.vscdb"
  local db

  for db in "$db1" "$db2"; do
    mkdir -p "$(dirname "$db")"
    [[ -f "$db" ]] && continue

    python3 - <<PY
import sqlite3
db_path = r"""$db"""
conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute("CREATE TABLE IF NOT EXISTS ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
conn.commit()
conn.close()
PY
    ok "Created headless Cursor DB: ${DIM}$(basename "$(dirname "$(dirname "$(dirname "$db")")")")/.../state.vscdb${NC}"
  done

  if [[ -n "${CURSOR_ACCESS_TOKEN:-}" && -n "${CURSOR_REFRESH_TOKEN:-}" ]]; then
    for db in "$db1" "$db2"; do
      python3 - <<PY
import sqlite3
db_path = r"""$db"""
access = r"""${CURSOR_ACCESS_TOKEN}"""
refresh = r"""${CURSOR_REFRESH_TOKEN}"""
email = r"""${CURSOR_EMAIL:-}"""
conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute("CREATE TABLE IF NOT EXISTS ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
cur.execute("INSERT OR REPLACE INTO ItemTable(key, value) VALUES(?, ?)", ("cursorAuth/accessToken", access))
cur.execute("INSERT OR REPLACE INTO ItemTable(key, value) VALUES(?, ?)", ("cursorAuth/refreshToken", refresh))
if email:
    cur.execute("INSERT OR REPLACE INTO ItemTable(key, value) VALUES(?, ?)", ("cursorAuth/cachedEmail", email))
conn.commit()
conn.close()
PY
    done
    ok "Seeded Cursor auth tokens"
  else
    wrn "Cursor tokens not provided (set CURSOR_ACCESS_TOKEN/CURSOR_REFRESH_TOKEN)"
  fi
}

# ── 9router DB ───────────────────────────────────────────────────────────────
init_9router_db() {
  local dir="$HOME/.9router"
  local db="$dir/db.json"

  mkdir -p "$dir"

  if [[ -f "$db" ]]; then
    ok "~/.9router/db.json exists"
    return
  fi

  cat > "$db" <<'DBJSON'
{
  "providerConnections": [],
  "providerNodes": [],
  "proxyPools": [],
  "modelAliases": {},
  "mitmAlias": {},
  "combos": [],
  "apiKeys": [],
  "settings": {
    "cloudEnabled": false,
    "tunnelEnabled": true,
    "tunnelUrl": "",
    "stickyRoundRobinLimit": 3,
    "providerStrategies": {},
    "comboStrategy": "fallback",
    "comboStrategies": {},
    "requireLogin": false,
    "observabilityEnabled": true,
    "observabilityMaxRecords": 1000,
    "observabilityBatchSize": 20,
    "observabilityFlushIntervalMs": 5000,
    "observabilityMaxJsonSize": 1024,
    "outboundProxyEnabled": false,
    "outboundProxyUrl": "",
    "outboundNoProxy": ""
  },
  "pricing": {}
}
DBJSON
  ok "Created ~/.9router/db.json"
}

# ── Start daemon ─────────────────────────────────────────────────────────────
start_9router_daemon() {
  [[ "$OS" != "Linux" ]] && return

  local startup_log="$HOME/.9router/startup.log"
  local router_bin
  router_bin="$(command -v 9router || true)"

  if [[ -z "$router_bin" ]]; then
    wrn "9router binary not found in PATH"
    return
  fi

  if pgrep -f "$router_bin" >/dev/null 2>&1; then
    ok "9router already running"
    return
  fi

  touch "$startup_log"
  info "Starting 9router daemon (0.0.0.0:20128)"
  nohup "$router_bin" --no-browser --host 0.0.0.0 --port 20128 >> "$startup_log" 2>&1 &
  sleep 3

  if pgrep -f "$router_bin" >/dev/null 2>&1; then
    ok "9router started"
  else
    err "9router failed to start — see $startup_log"
  fi
}

# ── Remote VPS install ───────────────────────────────────────────────────────
read_cursor_auth_from_db() {
  python3 - <<'PY'
import os
import sqlite3
import sys

paths = [
    os.path.expanduser("~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"),
    os.path.expanduser("~/.config/Cursor/User/globalStorage/state.vscdb"),
    os.path.expanduser("~/.config/cursor/User/globalStorage/state.vscdb"),
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
    print("ERROR: Cursor tokens missing. Re-login Cursor first.", file=sys.stderr)
    sys.exit(3)

print(access)
print(refresh)
print(email)
PY
}

remote_vps_install() {
  sep
  hdr "Remote VPS Setup"

  # ── Gather connection details ──────────────────────────────────────────────
  printf "      VPS host ${DIM}(user@host):${NC} "
  read -r TARGET_HOST
  if [[ -z "${TARGET_HOST:-}" ]]; then
    err "Host is required"
    exit 1
  fi

  printf "      SSH port ${DIM}[22]:${NC} "
  read -r SSH_PORT
  SSH_PORT="${SSH_PORT:-22}"

  # ── Test SSH connectivity ──────────────────────────────────────────────────
  printf "\n"
  info "Testing SSH connection to ${TARGET_HOST}:${SSH_PORT}"
  if ! ssh -p "$SSH_PORT" -o ConnectTimeout=10 -o BatchMode=yes "$TARGET_HOST" "echo ok" >/dev/null 2>&1; then
    err "Cannot connect to ${TARGET_HOST}:${SSH_PORT}"
    printf "      ${DIM}Make sure SSH key auth is configured and the host is reachable.${NC}\n"
    exit 1
  fi
  ok "SSH connection verified"

  # ── Cursor token sync ─────────────────────────────────────────────────────
  SYNC_TOKENS="n"
  printf "\n"
  printf "      Sync Cursor tokens from this machine? ${DIM}[Y/n]:${NC} "
  read -r SYNC_TOKENS
  SYNC_TOKENS="${SYNC_TOKENS:-Y}"

  local ACCESS_B64="" REFRESH_B64="" EMAIL_B64=""

  if [[ "$SYNC_TOKENS" =~ ^[Yy]$ ]]; then
    info "Reading Cursor tokens from local database"
    local TOKENS
    mapfile -t TOKENS < <(read_cursor_auth_from_db)
    local CURSOR_ACCESS_TOKEN="${TOKENS[0]:-}"
    local CURSOR_REFRESH_TOKEN="${TOKENS[1]:-}"
    local CURSOR_EMAIL="${TOKENS[2]:-}"

    if [[ -z "$CURSOR_ACCESS_TOKEN" || -z "$CURSOR_REFRESH_TOKEN" ]]; then
      err "Could not extract Cursor tokens"
      exit 1
    fi

    ACCESS_B64="$(printf '%s' "$CURSOR_ACCESS_TOKEN" | base64 | tr -d '\n')"
    REFRESH_B64="$(printf '%s' "$CURSOR_REFRESH_TOKEN" | base64 | tr -d '\n')"
    EMAIL_B64="$(printf '%s' "$CURSOR_EMAIL" | base64 | tr -d '\n')"
    ok "Cursor tokens extracted (access=${#CURSOR_ACCESS_TOKEN} chars)"
  fi

  # ── Remote install ─────────────────────────────────────────────────────────
  sep
  hdr "Installing on ${TARGET_HOST}"

  ssh -p "$SSH_PORT" "$TARGET_HOST" \
    "CURSOR_ACCESS_TOKEN_B64='$ACCESS_B64' CURSOR_REFRESH_TOKEN_B64='$REFRESH_B64' CURSOR_EMAIL_B64='$EMAIL_B64' SYNC_TOKENS='$SYNC_TOKENS' bash -s" <<'REMOTE'
set -euo pipefail

decode_b64() {
  if base64 --help 2>/dev/null | grep -q -- '-d'; then
    printf '%s' "$1" | base64 -d
  else
    printf '%s' "$1" | base64 -D
  fi
}

# Run the headless installer
curl -sfS https://9routerx.hyberorbit.com/install | sh -s -- --vps-headless

# Sync tokens if requested
if [[ "${SYNC_TOKENS:-n}" =~ ^[Yy]$ ]] && [[ -n "${CURSOR_ACCESS_TOKEN_B64:-}" ]]; then
  export CURSOR_ACCESS_TOKEN="$(decode_b64 "${CURSOR_ACCESS_TOKEN_B64}")"
  export CURSOR_REFRESH_TOKEN="$(decode_b64 "${CURSOR_REFRESH_TOKEN_B64}")"
  export CURSOR_EMAIL="$(decode_b64 "${CURSOR_EMAIL_B64}")"

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
fi
REMOTE

  # ── Summary ────────────────────────────────────────────────────────────────
  local VPS_IP="${TARGET_HOST#*@}"
  sep
  printf "\n"
  printf "  ${GREEN}${BOLD}✓ Remote install complete${NC}\n"
  printf "\n"
  hdr "Next steps"
  printf "      ${CYAN}1.${NC} Open 9router UI: ${BOLD}http://${VPS_IP}:20128${NC}\n"
  printf "      ${CYAN}2.${NC} Complete provider logins (Claude, Copilot, Antigravity)\n"
  printf "      ${CYAN}3.${NC} Run sync:  ${DIM}ssh ${TARGET_HOST} 'python3 ~/.9routerx/scripts/sync/9router_claude_sync.py'${NC}\n"
  printf "\n"
  sep
  printf "\n"
}

# ── Summary for local installs ───────────────────────────────────────────────
print_local_summary() {
  sep
  printf "\n"
  printf "  ${GREEN}${BOLD}✓ Installation complete${NC}\n"
  printf "\n"
  hdr "Quick start"
  printf "      ${CYAN}9routerx${NC}             ${DIM}CLI for combos & models${NC}\n"
  printf "      ${CYAN}9routerx models${NC}      ${DIM}List available models${NC}\n"
  printf "      ${CYAN}9routerx combos${NC}      ${DIM}Manage virtual models${NC}\n"
  printf "\n"
  hdr "9router UI"

  if [[ "$MODE" == "vps-headless" ]]; then
    printf "      ${BOLD}http://YOUR_SERVER_IP:20128${NC}\n"
  else
    printf "      ${BOLD}http://127.0.0.1:20128${NC}\n"
    printf "      ${DIM}Run '9router' in terminal to start${NC}\n"
  fi
  printf "\n"
  hdr "Sync"
  printf "      ${DIM}python3 \"${ROOT_DIR}/scripts/sync/9router_claude_sync.py\"${NC}\n"
  printf "      ${DIM}\"${ROOT_DIR}/scripts/sync/install_sync_cron.sh\"${NC}\n"
  printf "\n"
  printf "  ${DIM}Mode: ${MODE}${NC}\n"
  printf "\n"
  sep
  printf "\n"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  resolve_mode

  # Remote VPS mode — handled entirely separately
  if [[ "$MODE" == "remote-vps" ]]; then
    remote_vps_install
    return
  fi

  # Mode defaults for Cursor
  if [[ "$INSTALL_CURSOR" == "auto" ]]; then
    if [[ "$MODE" == "vps-headless" ]]; then
      INSTALL_CURSOR="no"
    else
      INSTALL_CURSOR="yes"
    fi
  fi

  sep
  hdr "Installing dependencies"

  install_node_if_missing
  install_claude_code
  install_antigravity
  install_copilot_cli
  install_cursor
  install_9router
  install_9routerx_cli

  if [[ "$MODE" == "vps-headless" ]]; then
    sep
    hdr "Headless setup"
    init_cursor_state_db_headless
  fi

  sep
  hdr "Database"
  init_9router_db
  start_9router_daemon

  print_local_summary
}

main "$@"
