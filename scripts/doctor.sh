#!/usr/bin/env bash
# shellcheck disable=SC2059
set -euo pipefail

MODE=""
FIX=0
YES=0          # --yes: skip confirmation prompt inside --fix (for unattended remote runs)
OS="$(uname -s)"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# Structured issue flags consumed by run_fix()
NEED_START_ROUTER=0
NEED_INSTALL_SERVICE=0
NEED_RESTART_SERVICE=0

# ── Output helpers ────────────────────────────────────────────────────────────
pass() { printf "  ${GREEN}✓${NC} %s\n" "$*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf "  ${RED}✗${NC} %s\n" "$*"; FAIL_COUNT=$((FAIL_COUNT  + 1)); }
warn() { printf "  ${YELLOW}!${NC} %s\n" "$*"; WARN_COUNT=$((WARN_COUNT + 1)); }
info() { printf "  ${DIM}→${NC} %s\n" "$*"; }
hdr()  { printf "\n  ${BOLD}%s${NC}\n\n" "$*"; }
sep()  { printf "${DIM}  ────────────────────────────────────────────────────────────────${NC}\n"; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# ── TTY helpers ───────────────────────────────────────────────────────────────
tty_available() {
  [[ -e /dev/tty ]] && [[ -r /dev/tty ]] && [[ -w /dev/tty ]]
}

tty_read() {
  local prompt="$1" default="${2:-}" input=""
  if tty_available; then
    if [[ -n "$default" ]]; then
      printf "%s [%s]: " "$prompt" "$default" > /dev/tty
    else
      printf "%s: " "$prompt" > /dev/tty
    fi
    IFS= read -r input < /dev/tty || input=""
  else
    if [[ -n "$default" ]]; then
      printf "%s [%s]: " "$prompt" "$default"
    else
      printf "%s: " "$prompt"
    fi
    IFS= read -r input || input=""
  fi
  printf "%s" "${input:-$default}"
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --mode <local-cursor|vps-headless>  Run checks for a specific mode
  --fix                               After reporting issues, prompt to auto-remediate
  --yes                               Skip confirmation prompts (use with --fix for unattended runs)
  -h, --help                          Show this help message
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)    MODE="${2:-}"; shift 2 ;;
      --fix)     FIX=1;  shift ;;
      --yes)     YES=1;  shift ;;
      -h|--help) usage;  exit 0 ;;
      *) printf "Unknown option: %s\n" "$1" >&2; usage; exit 1 ;;
    esac
  done
}

# ── Mode selection ────────────────────────────────────────────────────────────
choose_mode_if_needed() {
  [[ -n "$MODE" ]] && return

  if ! tty_available; then
    printf "Interactive mode selection requires a TTY.\n" >&2
    printf "Re-run with --mode <local-cursor|vps-headless>\n" >&2
    exit 1
  fi

  sep
  hdr "9routerx Doctor"
  printf "  Choose the mode for this machine:\n\n"
  printf "      ${CYAN}1)${NC} local-cursor   ${DIM}(Cursor IDE installed and logged in)${NC}\n"
  printf "      ${CYAN}2)${NC} vps-headless   ${DIM}(server / headless install)${NC}\n\n"

  local sel
  sel="$(tty_read "  Select [1/2]" "")"
  case "${sel:-}" in
    1) MODE="local-cursor" ;;
    2) MODE="vps-headless" ;;
    *) printf "Invalid selection: %s\n" "${sel:-}" >&2; exit 1 ;;
  esac
}

# ── Checks ────────────────────────────────────────────────────────────────────
check_cmd() {
  local cmd="$1" label="$2"
  if has_cmd "$cmd"; then
    pass "$label"
  else
    fail "$label — ${BOLD}${cmd}${NC} not found in PATH"
  fi
}

check_file() {
  local path="$1" label="$2"
  if [[ -f "$path" ]]; then
    pass "$label"
  else
    fail "$label — ${DIM}${path}${NC} missing"
  fi
}

check_9router_process() {
  local router_bin
  router_bin="$(command -v 9router 2>/dev/null || echo "")"

  if [[ -z "$router_bin" ]]; then
    fail "9router process — binary not in PATH"
    NEED_START_ROUTER=1
    return
  fi

  if pgrep -f "$router_bin" >/dev/null 2>&1; then
    pass "9router process running"
  else
    fail "9router process not running"
    NEED_START_ROUTER=1
  fi
}

check_9router_http() {
  local code
  code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:20128/api/providers 2>/dev/null || echo "000")"
  case "$code" in
    200|401|403) pass "9router HTTP health ${DIM}(${code})${NC}" ;;
    000)         fail "9router HTTP unreachable ${DIM}(connection refused — is the process running?)${NC}" ;;
    *)           warn "9router HTTP unexpected status ${DIM}(${code})${NC}" ;;
  esac
}

check_localhost_ipv6_trap() {
  local code_v4 code_lh
  code_v4="$(curl -sS -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:20128/api/providers 2>/dev/null || echo "000")"
  code_lh="$(curl -sS -m 3 -o /dev/null -w '%{http_code}' http://localhost:20128/api/providers  2>/dev/null || echo "000")"

  if [[ "$code_v4" =~ ^(200|401|403)$ ]] && ! [[ "$code_lh" =~ ^(200|401|403)$ ]]; then
    warn "localhost resolves to IPv6 (::1) on this host — use http://127.0.0.1:20128 in all configs"
  fi
}

check_systemd_service() {
  # Systemd checks are Linux-only
  [[ "$OS" != "Linux" ]] && return

  if ! has_cmd systemctl; then
    warn "systemd not available — 9router has no auto-restart or boot persistence"
    NEED_INSTALL_SERVICE=1
    return
  fi

  if ! systemctl status >/dev/null 2>&1 && ! systemctl is-system-running >/dev/null 2>&1; then
    warn "systemd is not active as PID 1 — 9router has no auto-restart or boot persistence"
    return
  fi

  local svc_active=0 svc_enabled=0
  systemctl is-active  --quiet 9router 2>/dev/null && svc_active=1  || true
  systemctl is-enabled --quiet 9router 2>/dev/null && svc_enabled=1 || true

  if [[ "$svc_active" -eq 1 && "$svc_enabled" -eq 1 ]]; then
    pass "9router systemd service active and enabled on boot"
  elif [[ "$svc_active" -eq 1 && "$svc_enabled" -eq 0 ]]; then
    warn "9router systemd service is active but NOT enabled — will not start on reboot"
    NEED_RESTART_SERVICE=1
  elif [[ "$svc_active" -eq 0 && "$svc_enabled" -eq 1 ]]; then
    fail "9router systemd service is enabled but not active — likely crashed"
    NEED_RESTART_SERVICE=1
  else
    fail "9router systemd service not installed — process will not restart on reboot or crash"
    NEED_INSTALL_SERVICE=1
  fi
}

check_common() {
  hdr "Binaries"
  check_cmd node           "Node.js"
  check_cmd npm            "npm"
  check_cmd python3        "Python 3"
  check_cmd claude         "Claude Code CLI"
  check_cmd 9router        "9router"
  check_cmd gh             "GitHub CLI"
  check_cmd antigravity-ide "antigravity-ide"

  hdr "9router"
  check_file "$HOME/.9router/db.json" "9router database"
  check_9router_process
  check_9router_http
  check_localhost_ipv6_trap

  if [[ "$OS" == "Linux" ]]; then
    hdr "Service"
    check_systemd_service
  fi
}

check_local_cursor() {
  hdr "Cursor"
  local db_macos="$HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
  local db_linux1="$HOME/.config/Cursor/User/globalStorage/state.vscdb"
  local db_linux2="$HOME/.config/cursor/User/globalStorage/state.vscdb"

  if has_cmd cursor; then
    pass "Cursor CLI"
  else
    warn "Cursor CLI not found ${DIM}(desktop app may still work)${NC}"
  fi

  if [[ -f "$db_macos" ]] || [[ -f "$db_linux1" ]] || [[ -f "$db_linux2" ]]; then
    pass "Cursor state.vscdb"
  else
    fail "Cursor state.vscdb missing — open Cursor IDE and sign in at least once"
  fi
}

check_client_config() {
  hdr "API routing (local tools → 9router)"

  # ── Claude Code ───────────────────────────────────────────────────────────────
  local claude_settings="$HOME/.claude/settings.json"
  if [[ -f "$claude_settings" ]]; then
    local claude_url
    claude_url="$(python3 - <<PY 2>/dev/null || echo ""
import json, sys
with open("${claude_settings}") as f:
    d = json.load(f)
print(d.get("env", {}).get("ANTHROPIC_BASE_URL", ""))
PY
)"
    if [[ -n "$claude_url" ]]; then
      pass "Claude Code  ANTHROPIC_BASE_URL=${DIM}${claude_url}${NC}"
    else
      warn "Claude Code  ANTHROPIC_BASE_URL not set in ~/.claude/settings.json"
    fi
  else
    warn "Claude Code  settings.json not found"
  fi

  # ── Shell env ──────────────────────────────────────────────────────────────────
  if [[ -n "${ANTHROPIC_BASE_URL:-}" ]]; then
    pass "Shell env    ANTHROPIC_BASE_URL=${DIM}${ANTHROPIC_BASE_URL}${NC}"
  else
    warn "Shell env    ANTHROPIC_BASE_URL not set ${DIM}(reload shell after running --sync-shell)${NC}"
  fi

  # ── Cursor settings ───────────────────────────────────────────────────────────
  local cursor_settings=""
  local candidate
  for candidate in \
    "$HOME/Library/Application Support/Cursor/User/settings.json" \
    "$HOME/.config/Cursor/User/settings.json" \
    "$HOME/.config/cursor/User/settings.json"
  do
    [[ -f "$candidate" ]] && cursor_settings="$candidate" && break
  done

  if [[ -n "$cursor_settings" ]]; then
    local cursor_url
    cursor_url="$(python3 - <<PY 2>/dev/null || echo ""
import json
with open("${cursor_settings}") as f:
    d = json.load(f)
print(d.get("openai.baseUrl", ""))
PY
)"
    if [[ -n "$cursor_url" ]]; then
      pass "Cursor       openai.baseUrl=${DIM}${cursor_url}${NC}"
    else
      warn "Cursor       openai.baseUrl not set in settings.json"
    fi
  else
    warn "Cursor       settings.json not found"
  fi

  # ── Connectivity check against wherever Claude Code is pointing ───────────────
  local target_base="${ANTHROPIC_BASE_URL:-}"
  # Strip trailing /v1 to get the 9router base for the health probe
  target_base="${target_base%/v1}"
  if [[ -n "$target_base" ]]; then
    local http_code
    http_code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "${target_base}/api/providers" 2>/dev/null || echo "000")"
    case "$http_code" in
      200|401|403) pass "9router reachable at ${DIM}${target_base}${NC}" ;;
      000)         fail "9router not reachable at ${DIM}${target_base}${NC} ${DIM}(connection refused)${NC}" ;;
      *)           warn "9router unexpected status ${DIM}(${http_code})${NC} at ${target_base}" ;;
    esac
  fi
}

check_vps_headless() {
  hdr "Headless Cursor DB"
  local db1="$HOME/.config/Cursor/User/globalStorage/state.vscdb"
  local db2="$HOME/.config/cursor/User/globalStorage/state.vscdb"

  if [[ -f "$db1" ]]; then
    pass "state.vscdb ${DIM}(~/.config/Cursor/...)${NC}"
  else
    warn "state.vscdb missing at ~/.config/Cursor/ ${DIM}(run install.sh to create)${NC}"
  fi

  if [[ -f "$db2" ]]; then
    pass "state.vscdb ${DIM}(~/.config/cursor/...)${NC}"
  else
    warn "state.vscdb missing at ~/.config/cursor/ ${DIM}(run install.sh to create)${NC}"
  fi

  if [[ -f "$HOME/.9router/startup.log" ]]; then
    local last_lines
    last_lines="$(tail -3 "$HOME/.9router/startup.log" 2>/dev/null || echo "(empty)")"
    if [[ -n "$last_lines" ]]; then
      info "Last startup log entries:"
      while IFS= read -r line; do
        printf "        ${DIM}%s${NC}\n" "$line"
      done <<< "$last_lines"
    fi
  fi
}

# ── Fix ───────────────────────────────────────────────────────────────────────
run_fix() {
  local total_issues=$((NEED_START_ROUTER + NEED_INSTALL_SERVICE + NEED_RESTART_SERVICE))
  [[ "$total_issues" -eq 0 ]] && return 0

  sep
  hdr "Issues to remediate"

  [[ "$NEED_START_ROUTER"    -eq 1 ]] && printf "  ${RED}•${NC} 9router is not running\n"
  [[ "$NEED_INSTALL_SERVICE" -eq 1 ]] && printf "  ${RED}•${NC} systemd service not installed (no auto-restart / boot persistence)\n"
  [[ "$NEED_RESTART_SERVICE" -eq 1 ]] && printf "  ${RED}•${NC} systemd service installed but not active\n"
  printf "\n"

  # Require explicit confirmation unless --yes was passed
  if [[ "$YES" -eq 0 ]]; then
    if ! tty_available; then
      printf "  ${YELLOW}!${NC} TTY not available — cannot prompt. Re-run with --yes to auto-fix without prompting.\n\n"
      return 0
    fi
    local confirm
    confirm="$(tty_read "  Apply these fixes now? (y/N)" "N")"
    if ! [[ "$confirm" =~ ^[Yy]$ ]]; then
      info "No changes made."
      return 0
    fi
  fi

  sep
  hdr "Applying fixes"

  local router_bin
  router_bin="$(command -v 9router 2>/dev/null || echo "")"
  if [[ -z "$router_bin" ]]; then
    printf "  ${RED}✗${NC} 9router binary not found — run the installer first\n"
    return 1
  fi

  local startup_log="$HOME/.9router/startup.log"
  mkdir -p "$HOME/.9router"
  touch "$startup_log"

  local run_as_root=0
  [[ "$(id -u)" -eq 0 ]] && run_as_root=1

  _systemctl() {
    if [[ "$run_as_root" -eq 1 ]]; then
      systemctl "$@"
    elif has_cmd sudo; then
      sudo systemctl "$@"
    else
      printf "  ${YELLOW}!${NC} sudo not available — cannot manage systemd service\n"
      return 1
    fi
  }

  # Fix: install systemd service ───────────────────────────────────────────────
  if [[ "$NEED_INSTALL_SERVICE" -eq 1 ]] && has_cmd systemctl; then
    local run_user="${SUDO_USER:-$USER}"
    local tmp_unit
    tmp_unit="$(mktemp /tmp/9router-XXXXXX.service)"

    cat > "$tmp_unit" <<UNIT
[Unit]
Description=9router AI gateway
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=${run_user}
ExecStart=${router_bin} --no-browser --tray --host 0.0.0.0 --port 20128 --skip-update
Restart=on-failure
RestartSec=5
StandardInput=null
StandardOutput=append:${startup_log}
StandardError=append:${startup_log}
Environment=NO_COLOR=1
Environment=TERM=dumb

[Install]
WantedBy=multi-user.target
UNIT

    if [[ "$run_as_root" -eq 1 ]]; then
      mv "$tmp_unit" /etc/systemd/system/9router.service
    elif has_cmd sudo; then
      sudo mv "$tmp_unit" /etc/systemd/system/9router.service
    else
      rm -f "$tmp_unit"
      printf "  ${YELLOW}!${NC} Cannot write /etc/systemd/system/ — no sudo. Falling back to nohup.\n"
      NEED_INSTALL_SERVICE=0
      NEED_START_ROUTER=1
    fi

    if [[ "$NEED_INSTALL_SERVICE" -eq 1 ]]; then
      _systemctl daemon-reload
      _systemctl enable --now 9router >/dev/null 2>&1
      printf "  ${GREEN}✓${NC} systemd service installed, enabled, and started\n"
    fi

  # Fix: restart crashed systemd service ────────────────────────────────────────
  elif [[ "$NEED_RESTART_SERVICE" -eq 1 ]] && has_cmd systemctl; then
    _systemctl enable 9router >/dev/null 2>&1 || true
    _systemctl restart 9router
    printf "  ${GREEN}✓${NC} systemd service enabled and restarted\n"

  # Fix: start via nohup (no systemd available) ─────────────────────────────────
  fi

  if [[ "$NEED_START_ROUTER" -eq 1 ]]; then
    NO_COLOR=1 TERM=dumb nohup "$router_bin" --no-browser --tray --host 0.0.0.0 --port 20128 --skip-update < /dev/null >> "$startup_log" 2>&1 &
    printf "  ${GREEN}✓${NC} 9router started ${DIM}(nohup — add @reboot cron for persistence)${NC}\n"
  fi

  # Verify recovery ─────────────────────────────────────────────────────────────
  printf "\n"
  info "Waiting for 9router to be ready…"
  local i code
  for i in 1 2 3 4 5 6 7 8 9 10; do
    code="$(curl -sS -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:20128/api/providers 2>/dev/null || echo "000")"
    if [[ "$code" =~ ^(200|401|403)$ ]]; then
      printf "  ${GREEN}✓${NC} 9router is up at ${BOLD}http://127.0.0.1:20128${NC}\n"
      return 0
    fi
    sleep 2
  done
  printf "  ${RED}✗${NC} 9router did not respond after fix — check ${DIM}%s${NC}\n" "$startup_log"
  return 1
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
  sep
  printf "\n"
  printf "  ${BOLD}Summary${NC}   "
  printf "${GREEN}%d passed${NC}" "$PASS_COUNT"
  if [[ "$WARN_COUNT" -gt 0 ]]; then
    local w_label="warnings"; [[ "$WARN_COUNT" -eq 1 ]] && w_label="warning"
    printf "   ${YELLOW}%d %s${NC}" "$WARN_COUNT" "$w_label"
  fi
  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    local f_label="failed"; [[ "$FAIL_COUNT" -eq 1 ]] && f_label="failed"
    printf "   ${RED}%d %s${NC}" "$FAIL_COUNT" "$f_label"
  fi
  printf "\n\n"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  choose_mode_if_needed

  sep
  printf "\n"
  printf "  ${BOLD}⎯ 9routerx Doctor${NC}   ${DIM}mode: %s${NC}\n" "$MODE"

  check_common

  case "$MODE" in
    local-cursor)
      check_local_cursor
      check_client_config
      ;;
    vps-headless) check_vps_headless ;;
    *) printf "Invalid mode: %s\n" "$MODE" >&2; exit 1 ;;
  esac

  print_summary

  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    if [[ "$FIX" -eq 1 ]]; then
      if [[ "$MODE" == "vps-headless" ]]; then
        run_fix
      else
        printf "  ${DIM}--fix is only supported in vps-headless mode${NC}\n\n"
      fi
    else
      printf "  ${DIM}Re-run with ${NC}${CYAN}--fix${NC}${DIM} to attempt auto-remediation${NC}\n\n"
    fi
    exit 1
  fi
}

main "$@"
