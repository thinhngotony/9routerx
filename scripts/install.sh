#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OS="$(uname -s)"

log() { printf "[9routerx] %s\n" "$*"; }
warn() { printf "[9routerx][warn] %s\n" "$*" >&2; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

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
      warn "Cursor Linux install varies by distro. Install manually from cursor.com/downloads, then re-run."
      ;;
    *)
      warn "Unsupported OS for Cursor install: $OS"
      ;;
  esac
}

install_9router() {
  install_npm_pkg_if_missing 9router "9router"
}

main() {
  log "Starting bootstrap"
  install_node_if_missing
  install_claude_code
  install_antigravity
  install_copilot_cli
  install_cursor
  install_9router

  log "Bootstrap complete"
  cat <<EOF

Next:
1) Run 9router and complete provider logins (Claude, GitHub Copilot, Antigravity via Google OAuth):
   9router
2) Sync Claude config to current tunnel/models:
   python3 "$ROOT_DIR/scripts/sync/9router_claude_sync.py"
3) Install auto-sync cron (keeps config healthy after tunnel rotation):
   "$ROOT_DIR/scripts/sync/install_sync_cron.sh" "$ROOT_DIR/scripts/sync/9router_claude_sync.py" "\$HOME/.9router/claude-sync.log"

Note: Antigravity provider login is done via 9router web UI (Google OAuth) — not via CLI.

EOF
}

main "$@"

