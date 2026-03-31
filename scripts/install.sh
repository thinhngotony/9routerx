#!/usr/bin/env bash
# shellcheck disable=SC2059
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OS="$(uname -s)"
MODE=""
INSTALL_CURSOR="auto"
SYNC_TO=""
REMOTE_TARGET_HOST=""
REMOTE_SSH_PORT=""
SSH_CONTROL_PATH=""

# Isolate npm cache to avoid permission issues from previous installs
# (e.g. root-owned directories under ~/.npm/_cacache).
NINE_ROUTERX_NPM_CACHE="${NINE_ROUTERX_NPM_CACHE:-$HOME/.cache/9routerx-npm-cache}"
export NPM_CONFIG_CACHE="$NINE_ROUTERX_NPM_CACHE"
mkdir -p "$NPM_CONFIG_CACHE" 2>/dev/null || true

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

# ── TTY helpers ────────────────────────────────────────────────────────────────
tty_available() {
  [[ -e /dev/tty ]] && [[ -r /dev/tty ]] && [[ -w /dev/tty ]]
}

tty_read() {
  # Usage: tty_read "prompt" "default"
  local prompt="$1"
  local default="${2:-}"
  local input=""

  if tty_available; then
    if [[ -n "$default" ]]; then
      printf "%s%s [%s]:%s " "" "$prompt" "$default" "" > /dev/tty
    else
      printf "%s:%s " "$prompt" "" > /dev/tty
    fi
    if ! IFS= read -r input < /dev/tty; then
      input=""
    fi
  else
    if [[ -n "$default" ]]; then
      printf "%s%s [%s]:%s " "" "$prompt" "$default" "" 
    else
      printf "%s:%s " "$prompt" "" 
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

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --mode <local-cursor|vps-headless>
  --local-cursor              Shortcut for --mode local-cursor
  --vps-headless              Shortcut for --mode vps-headless
  --sync-to <user@host>      Sync Cursor tokens from this machine to remote VPS
  --ssh-port <port>          SSH port for --sync-to (default: 22)
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
      --sync-to)        SYNC_TO="${2:-}"; shift 2 ;;
      --ssh-port)       REMOTE_SSH_PORT="${2:-}"; shift 2 ;;
      # Back-compat / hidden options:
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

  if ! tty_available; then
    err "Interactive mode selection requires a TTY. Re-run with --mode <local-cursor|vps-headless> (advanced)."
    exit 1
  fi

  sep
  hdr "What do you want to do?"
  printf "      ${CYAN}1)${NC} Install 9routerx on ${BOLD}this machine${NC} ${DIM}(laptop or server)${NC}\n"
  printf "      ${CYAN}2)${NC} Sync Cursor tokens from ${BOLD}this machine${NC} to a ${BOLD}remote VPS${NC} ${DIM}(auto-install if needed)${NC}\n"
  printf "\n"

  local choice
  choice="$(tty_read "  Select [1/2]")"
  case "${choice:-}" in
    1)
      # Install on this machine. Internally choose mode by OS so we get the
      # right DB behavior, but the UX is a single \"install here\" option.
      if [[ "$OS" == "Linux" ]]; then
        MODE="vps-headless"
      else
        MODE="local-cursor"
      fi
      ;;
    2)
      MODE="remote-vps"
      ;;
    *)
      err "Invalid choice: ${choice}"
      exit 1
      ;;
  esac
}

resolve_mode() {
  choose_mode_if_needed

  if [[ "$MODE" == "auto" ]]; then
    # Preserve back-compat flag, but never silently guess.
    MODE=""
    choose_mode_if_needed
  fi

  case "$MODE" in
    local-cursor|vps-headless|remote-vps) ;;
    *) err "Invalid mode: $MODE"; usage; exit 1 ;;
  esac

  printf "\n"
  printf "      ${GREEN}✓${NC} Mode: ${BOLD}%s${NC}\n" "$MODE"
}

# ── npm helpers ──────────────────────────────────────────────────────────────
npm_global_install() {
  local pkg="$1"

  # Fix npm cache permission issues before install
  npm cache verify >/dev/null 2>&1 || true

  local prefix
  prefix="$(npm config get prefix 2>/dev/null || echo "")"
  local node_modules_dir=""
  if [[ -n "$prefix" ]]; then
    node_modules_dir="${prefix%/}/lib/node_modules"
  fi

  # Check if we can write to the global prefix
  if [[ -n "$prefix" ]] && [[ -n "$node_modules_dir" ]] && [[ -w "$node_modules_dir" ]] 2>/dev/null; then
    npm install -g "$pkg"
  elif [[ "$(id -u)" -eq 0 ]]; then
    npm install -g "$pkg"
  elif [[ "$OS" == "Linux" ]]; then
    sudo npm install -g "$pkg"
  else
    # macOS: force npm prefix to a user-writable location.
    # This avoids EACCES when npm is configured to write to /usr/local.
    local user_prefix="$HOME/.npm-global"
    mkdir -p "$user_prefix"
    # Force npm prefix for this command without mutating config files.
    # (Some systems lock down npm config locations.)
    export PATH="$user_prefix/bin:$PATH"
    NPM_CONFIG_PREFIX="$user_prefix" npm install -g "$pkg"
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
    # Skip silently when running from a standalone copy (e.g. remote VPS)
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
  fi
}

# ── 9router DB ───────────────────────────────────────────────────────────────
init_9router_db() {
  local dir="$HOME/.9router"
  local db="$dir/db.json"

  mkdir -p "$dir"

  if [[ -f "$db" ]]; then
    ok "\$HOME/.9router/db.json exists"
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

def get_value(key):
    row = cur.execute("SELECT value FROM ItemTable WHERE key = ?", (key,)).fetchone()
    if not row:
        return ""
    v = row[0]
    return v.decode("utf-8", errors="ignore") if isinstance(v, bytes) else str(v)

access = get_value("cursorAuth/accessToken")
refresh = get_value("cursorAuth/refreshToken")
email = get_value("cursorAuth/cachedEmail")
machine_id = get_value("storage.serviceMachineId") or get_value("storage.machineId") or get_value("telemetry.machineId")
conn.close()

if not access or not refresh:
    print("ERROR: Cursor tokens missing. Re-login Cursor first.", file=sys.stderr)
    sys.exit(3)

print(access)
print(refresh)
print(email)
print(machine_id)
PY
}

remote_vps_install() {
  sep
  hdr "Remote VPS Setup"

  # ── Gather connection details ──────────────────────────────────────────────
  if ! tty_available; then
    err "Remote VPS setup requires a TTY for interactive prompts."
    exit 1
  fi

  TARGET_HOST="${REMOTE_TARGET_HOST:-$(tty_read "      VPS host (user@host or ip)" "")}"
  if [[ -z "${TARGET_HOST:-}" ]]; then
    err "Host is required"
    exit 1
  fi

  SSH_PORT="${REMOTE_SSH_PORT:-$(tty_read "      SSH port" "22")}"

  # ── SSH ControlMaster (single password prompt for all operations) ──────────
  # Use /tmp with short name to stay under macOS 104-char Unix socket limit.
  # SSH_CONTROL_PATH is declared at script-level so the EXIT trap can access it.
  SSH_CONTROL_PATH="/tmp/.9rx-ssh-$$"
  local SSH_OPTS=(-o "ControlMaster=auto" -o "ControlPath=${SSH_CONTROL_PATH}" -o "ControlPersist=120")

  trap 'ssh -o "ControlPath=${SSH_CONTROL_PATH}" -O exit "${TARGET_HOST:-}" 2>/dev/null || true; rm -f "${SSH_CONTROL_PATH:-}"' EXIT

  # ── Test SSH connectivity (opens the master connection — single password prompt)
  printf "\n"
  info "Connecting to ${TARGET_HOST}:${SSH_PORT} (you may be prompted for password)"
  if ! ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" -o ConnectTimeout=10 "$TARGET_HOST" "echo ok" >/dev/null; then
    err "Cannot connect to ${TARGET_HOST}:${SSH_PORT}"
    printf "      ${DIM}Check IP/host, SSH port, and credentials (password or key).${NC}\n"
    exit 1
  fi
  ok "SSH connection verified"

  # ── Cursor token sync ─────────────────────────────────────────────────────
  printf "\n"

  local confirm
  confirm="$(tty_read "      Overwrite Cursor tokens on ${TARGET_HOST}? (y/N)" "N")"
  if ! [[ "$confirm" =~ ^[Yy]$ ]]; then
    err "Aborted token sync."
    exit 0
  fi

  local ACCESS_B64="" REFRESH_B64="" EMAIL_B64=""

  info "Reading Cursor tokens from local database"
  local CURSOR_ACCESS_TOKEN="" CURSOR_REFRESH_TOKEN="" CURSOR_EMAIL="" CURSOR_MACHINE_ID=""
  {
    IFS= read -r CURSOR_ACCESS_TOKEN
    IFS= read -r CURSOR_REFRESH_TOKEN
    IFS= read -r CURSOR_EMAIL
    IFS= read -r CURSOR_MACHINE_ID
  } < <(read_cursor_auth_from_db)

  if [[ -z "$CURSOR_ACCESS_TOKEN" || -z "$CURSOR_REFRESH_TOKEN" ]]; then
    err "Could not extract Cursor tokens"
    exit 1
  fi

  ACCESS_B64="$(printf '%s' "$CURSOR_ACCESS_TOKEN" | base64 | tr -d '\n')"
  REFRESH_B64="$(printf '%s' "$CURSOR_REFRESH_TOKEN" | base64 | tr -d '\n')"
  EMAIL_B64="$(printf '%s' "$CURSOR_EMAIL" | base64 | tr -d '\n')"
  MACHINE_ID_B64="$(printf '%s' "$CURSOR_MACHINE_ID" | base64 | tr -d '\n')"
  ok "Cursor tokens extracted (access=${#CURSOR_ACCESS_TOKEN} chars, machineId=${#CURSOR_MACHINE_ID} chars)"

  # ── Remote install ─────────────────────────────────────────────────────────
  sep
  hdr "Installing on ${TARGET_HOST}"

  # Upload install script directly (avoids DNS dependency on the remote VPS)
  info "Uploading installer to ${TARGET_HOST}"
  scp "${SSH_OPTS[@]}" -P "$SSH_PORT" "${ROOT_DIR}/scripts/install.sh" "${TARGET_HOST}:/tmp/9routerx-install.sh"

  ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$TARGET_HOST" \
    "CURSOR_ACCESS_TOKEN_B64='$ACCESS_B64' CURSOR_REFRESH_TOKEN_B64='$REFRESH_B64' CURSOR_EMAIL_B64='$EMAIL_B64' CURSOR_MACHINE_ID_B64='$MACHINE_ID_B64' bash -s" <<'REMOTE'
set -euo pipefail

decode_b64() {
  if base64 --help 2>/dev/null | grep -q -- '-d'; then
    printf '%s' "$1" | base64 -d
  else
    printf '%s' "$1" | base64 -D
  fi
}

# Run the headless installer from uploaded copy
bash /tmp/9routerx-install.sh --vps-headless
rm -f /tmp/9routerx-install.sh

# Sync Cursor tokens
if [[ -n "${CURSOR_ACCESS_TOKEN_B64:-}" ]]; then
  CURSOR_ACCESS_TOKEN="$(decode_b64 "${CURSOR_ACCESS_TOKEN_B64}")"
  CURSOR_REFRESH_TOKEN="$(decode_b64 "${CURSOR_REFRESH_TOKEN_B64}")"
  CURSOR_EMAIL="$(decode_b64 "${CURSOR_EMAIL_B64}")"
  CURSOR_MACHINE_ID="$(decode_b64 "${CURSOR_MACHINE_ID_B64:-}")"

  # Write tokens to Cursor state DB (for other tools that read it)
  export CURSOR_ACCESS_TOKEN CURSOR_REFRESH_TOKEN CURSOR_EMAIL CURSOR_MACHINE_ID
  mkdir -p "$HOME/.config/Cursor/User/globalStorage" "$HOME/.config/cursor/User/globalStorage"
  python3 - <<'PY'
import os
import sqlite3

access = os.environ.get("CURSOR_ACCESS_TOKEN", "")
refresh = os.environ.get("CURSOR_REFRESH_TOKEN", "")
email = os.environ.get("CURSOR_EMAIL", "")
machine_id = os.environ.get("CURSOR_MACHINE_ID", "")

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
    if machine_id:
        cur.execute("INSERT OR REPLACE INTO ItemTable(key, value) VALUES(?, ?)", ("storage.serviceMachineId", machine_id))
    conn.commit()
    conn.close()
print("Cursor token sync complete")
PY

  # Register Cursor provider in 9router via its import API
  if [[ -n "$CURSOR_ACCESS_TOKEN" && -n "$CURSOR_MACHINE_ID" ]]; then
    # Wait for 9router to be ready
    for _ in 1 2 3 4 5; do
      if curl -sf http://127.0.0.1:20128/api/providers >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done

    IMPORT_RESP="$(curl -sf -X POST http://127.0.0.1:20128/api/oauth/cursor/import \
      -H 'Content-Type: application/json' \
      -d "{\"accessToken\":\"${CURSOR_ACCESS_TOKEN}\",\"machineId\":\"${CURSOR_MACHINE_ID}\"}" 2>&1 || true)"

    if printf '%s' "$IMPORT_RESP" | grep -q '"success":true'; then
      echo "Cursor provider registered in 9router"
    else
      echo "Warning: Could not auto-register Cursor provider: ${IMPORT_RESP}" >&2
      echo "You can manually add it at http://YOUR_VPS_IP:20128/dashboard/providers" >&2
    fi
  else
    echo "Warning: Missing machineId — Cursor provider not auto-registered" >&2
    echo "Add it manually at http://YOUR_VPS_IP:20128/dashboard/providers" >&2
  fi
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
  printf "      ${CYAN}2.${NC} Cursor provider was auto-registered from synced tokens\n"
  printf "      ${CYAN}3.${NC} Add more providers if needed (Copilot, Antigravity, etc.)\n"
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
  if [[ -f "${ROOT_DIR}/scripts/sync/9router_claude_sync.py" ]]; then
    hdr "Sync"
    printf "      ${DIM}python3 \"${ROOT_DIR}/scripts/sync/9router_claude_sync.py\"${NC}\n"
    printf "      ${DIM}\"${ROOT_DIR}/scripts/sync/install_sync_cron.sh\"${NC}\n"
  fi
  printf "\n"
  printf "  ${DIM}Mode: ${MODE}${NC}\n"
  printf "\n"
  sep
  printf "\n"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"

  if [[ -n "${SYNC_TO:-}" ]]; then
    REMOTE_TARGET_HOST="$SYNC_TO"
    MODE="remote-vps"
    remote_vps_install
    return
  fi

  resolve_mode

  # Remote VPS mode — handled entirely separately (selected from menu or flags)
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
