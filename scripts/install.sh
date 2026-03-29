#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OS="$(uname -s)"
MODE=""
INSTALL_CURSOR="auto"

log() { printf "[9routerx] %s\n" "$*"; }
warn() { printf "[9routerx][warn] %s\n" "$*" >&2; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --mode <local-cursor|vps-headless|auto>   Install strategy.
  --local-cursor                             Shortcut for --mode local-cursor.
  --vps-headless                             Shortcut for --mode vps-headless.
  --install-cursor                           Force Cursor install attempt.
  --skip-cursor-install                      Skip Cursor install step.
  -h, --help                                 Show this help message.
EOF
}

install_9routerx_cli() {
  local bin_dir="$HOME/.local/bin"
  local src="$ROOT_DIR/scripts/9routerx"
  local dst="$bin_dir/9routerx"

  mkdir -p "$bin_dir"

  if [[ ! -f "$src" ]]; then
    warn "9routerx CLI source not found at $src"
    return
  fi

  cp "$src" "$dst"
  chmod +x "$dst"

  if ! echo "$PATH" | tr ':' '\n' | grep -qx "$bin_dir"; then
    warn "Add $bin_dir to PATH to use '9routerx' globally"
  fi
  log "Installed 9routerx CLI: $dst"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        MODE="${2:-}"
        shift 2
        ;;
      --local-cursor)
        MODE="local-cursor"
        shift
        ;;
      --vps-headless)
        MODE="vps-headless"
        shift
        ;;
      --install-cursor)
        INSTALL_CURSOR="yes"
        shift
        ;;
      --skip-cursor-install)
        INSTALL_CURSOR="no"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        warn "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done
}

choose_mode_if_needed() {
  if [[ -n "$MODE" ]]; then
    return
  fi

  # For interactive terminals, let user choose explicitly.
  if [[ -t 0 ]]; then
    echo
    echo "Choose install mode:"
    echo "  1) local-cursor  (this machine runs Cursor IDE login)"
    echo "  2) vps-headless  (server gateway, optional token sync from local machine)"
    echo "  3) auto          (Linux -> vps-headless, others -> local-cursor)"
    printf "Select [1/2/3, default=3]: "
    read -r choice
    case "${choice:-3}" in
      1) MODE="local-cursor" ;;
      2) MODE="vps-headless" ;;
      3|"") MODE="auto" ;;
      *)
        warn "Invalid choice: ${choice}"
        exit 1
        ;;
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
    local-cursor|vps-headless)
      ;;
    *)
      warn "Invalid mode: $MODE"
      usage
      exit 1
      ;;
  esac

  log "Resolved mode: $MODE"
}

install_homebrew() {
  if has_cmd brew; then
    return
  fi
  log "Homebrew not found, installing"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}

install_node_if_missing() {
  if has_cmd node && has_cmd npm; then
    log "Node.js already installed"
    return
  fi

  case "$OS" in
    Darwin)
      install_homebrew
      log "Installing Node.js via Homebrew"
      brew install node
      ;;
    Linux)
      if has_cmd apt-get; then
        log "Installing Node.js via apt"
        sudo apt-get update
        sudo apt-get install -y nodejs npm
      elif has_cmd dnf; then
        log "Installing Node.js via dnf"
        sudo dnf install -y nodejs npm
      elif has_cmd yum; then
        log "Installing Node.js via yum"
        sudo yum install -y nodejs npm
      else
        warn "No supported package manager found for Node.js install"
        exit 1
      fi
      ;;
    *)
      warn "Unsupported OS: $OS"
      exit 1
      ;;
  esac
}

install_npm_pkg_if_missing() {
  local cmd="$1"
  local pkg="$2"
  if has_cmd "$cmd"; then
    log "$cmd already installed"
    return
  fi
  log "Installing $pkg"
  npm install -g "$pkg"
}

install_claude_code() {
  install_npm_pkg_if_missing claude "@anthropic-ai/claude-code"
}

install_antigravity() {
  # antigravity-ide is the npm workspace CLI (skills/rules/workflows).
  # The Antigravity AI provider (Google Cloud OAuth) is configured inside
  # 9router's web UI — it does not require an npm package.
  if has_cmd antigravity-ide || npm list -g antigravity-ide --depth=0 >/dev/null 2>&1; then
    log "antigravity-ide already installed"
    return
  fi
  log "Installing antigravity-ide"
  npm install -g antigravity-ide
}

install_copilot_cli() {
  # gh extension is the recommended Copilot CLI install path.
  if has_cmd gh && gh extension list 2>/dev/null | grep -q "github/gh-copilot"; then
    log "GitHub Copilot CLI already installed"
    return
  fi

  if has_cmd gh; then
    log "Installing GitHub Copilot CLI via gh extension"
    gh extension install github/gh-copilot 2>/dev/null || true
  elif has_cmd npm; then
    if has_cmd copilot; then
      log "copilot already installed"
      return
    fi
    log "Installing GitHub Copilot CLI via npm"
    npm install -g @githubnext/github-copilot-cli
  else
    warn "gh or npm required for Copilot CLI install"
  fi
}

install_cursor() {
  if [[ "$INSTALL_CURSOR" == "no" ]]; then
    log "Skipping Cursor install by flag"
    return
  fi

  if has_cmd cursor; then
    log "Cursor CLI already installed"
    return
  fi

  case "$OS" in
    Darwin)
      install_homebrew
      log "Installing Cursor via Homebrew cask"
      brew install --cask cursor
      ;;
    Linux)
      warn "Cursor Linux install varies by distro. Install manually from cursor.com/downloads if needed."
      ;;
    *)
      warn "Unsupported OS for Cursor install: $OS"
      ;;
  esac
}

install_9router() {
  install_npm_pkg_if_missing 9router "9router"
}

init_cursor_state_db_headless() {
  # 9router tries to read Cursor's local sqlite state DB.
  # On headless VPS this file does not exist, so create a minimal compatible DB.
  local db1="$HOME/.config/Cursor/User/globalStorage/state.vscdb"
  local db2="$HOME/.config/cursor/User/globalStorage/state.vscdb"
  local db

  # Prefer canonical Cursor path but populate both casings for compatibility.
  for db in "$db1" "$db2"; do
    mkdir -p "$(dirname "$db")"
    if [[ -f "$db" ]]; then
      continue
    fi

    python3 - <<PY
import sqlite3
db_path = r"""$db"""
conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute("CREATE TABLE IF NOT EXISTS ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
conn.commit()
conn.close()
PY
    log "Created headless Cursor state DB: $db"
  done

  # Optional: seed real Cursor auth tokens for VPS auto-import.
  # Export these before install if you want Cursor provider to work headless:
  #   CURSOR_ACCESS_TOKEN=... CURSOR_REFRESH_TOKEN=...
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
      log "Seeded Cursor auth tokens into: $db"
    done
  else
    warn "Cursor auth tokens not provided (CURSOR_ACCESS_TOKEN/CURSOR_REFRESH_TOKEN). Cursor auto-import may show 'manual paste' prompt on VPS."
  fi
}

init_9router_db() {
  local dir="$HOME/.9router"
  local db="$dir/db.json"

  mkdir -p "$dir"

  if [[ -f "$db" ]]; then
    log "~/.9router/db.json already exists"
    return
  fi

  log "Seeding ~/.9router/db.json (first-time init)"
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
  log "Created ~/.9router/db.json"
}

start_9router_daemon() {
  # On Linux headless (VPS), start 9router in background with no-browser flag.
  # On macOS, skip — user opens it manually or via tray.
  if [[ "$OS" != "Linux" ]]; then
    return
  fi

  local startup_log="$HOME/.9router/startup.log"
  local router_bin
  router_bin="$(command -v 9router || true)"

  if [[ -z "$router_bin" ]]; then
    warn "9router binary not found in PATH after install"
    return
  fi

  # Match the actual binary path to avoid false positives.
  if pgrep -f "$router_bin" >/dev/null 2>&1; then
    log "9router already running ($router_bin)"
    return
  fi

  touch "$startup_log"
  log "Starting 9router daemon (no-browser, host 0.0.0.0, port 20128)"
  nohup "$router_bin" --no-browser --host 0.0.0.0 --port 20128 >> "$startup_log" 2>&1 &
  sleep 3

  if pgrep -f "$router_bin" >/dev/null 2>&1; then
    log "9router started — open http://YOUR_SERVER_IP:20128 in your browser"
  else
    warn "9router failed to start — inspect $startup_log"
  fi
}

main() {
  parse_args "$@"
  resolve_mode

  # Mode defaults for Cursor installation behavior.
  if [[ "$INSTALL_CURSOR" == "auto" ]]; then
    if [[ "$MODE" == "vps-headless" ]]; then
      INSTALL_CURSOR="no"
    else
      INSTALL_CURSOR="yes"
    fi
  fi

  log "Starting bootstrap"
  install_node_if_missing
  install_claude_code
  install_antigravity
  install_copilot_cli
  install_cursor
  install_9router
  install_9routerx_cli
  if [[ "$MODE" == "vps-headless" ]]; then
    init_cursor_state_db_headless
  fi
  init_9router_db
  start_9router_daemon

  log "Bootstrap complete"
  cat <<EOF

Next:
1) Open 9router UI and complete provider logins (Claude, GitHub Copilot, Antigravity via Google OAuth):
   - Local:     http://127.0.0.1:20128  (avoid localhost -> ::1 issues)
   - Linux VPS: http://YOUR_SERVER_IP:20128
   - macOS:     run '9router' in terminal
2) Sync Claude config to current tunnel/models:
   python3 "$ROOT_DIR/scripts/sync/9router_claude_sync.py"
3) Install auto-sync cron (keeps config healthy after tunnel rotation):
   "$ROOT_DIR/scripts/sync/install_sync_cron.sh" "$ROOT_DIR/scripts/sync/9router_claude_sync.py" "\$HOME/.9router/claude-sync.log"

Mode: $MODE

Notes:
- Antigravity provider login is done via 9router web UI (Google OAuth) — not via CLI.
- Cursor provider on VPS is optional; use scripts/bootstrap-vps.sh to sync tokens from local Cursor login.
- Use ./scripts/9routerx combos create to create virtual models (fallback/round-robin).

EOF
}

main "$@"

