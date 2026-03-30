#!/bin/sh
# shellcheck disable=SC2059
set -eu

INSTALL_HOME="${HOME}/.9routerx"

# ── Colors (POSIX compatible) ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# ── Version detection ────────────────────────────────────────────────────────
VERSION=$(curl -sfS "https://api.github.com/repos/thinhngotony/9routerx/releases/latest" 2>/dev/null \
  | awk -F '"' '/tag_name/ {print $4; exit}' | sed 's/^v//')

if printf '%s' "${VERSION:-}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+'; then
  BASE_URL="https://raw.githubusercontent.com/thinhngotony/9routerx/v${VERSION}"
else
  VERSION="dev"
  BASE_URL="https://raw.githubusercontent.com/thinhngotony/9routerx/master"
fi

# ── Detect OS ────────────────────────────────────────────────────────────────
detect_os() {
  case "$(uname -s)" in
    Darwin*) echo "macos" ;;
    Linux*)  echo "linux" ;;
    *)       echo "unknown" ;;
  esac
}

OS=$(detect_os)

# ── Safe download helper ─────────────────────────────────────────────────────
safe_download() {
  _url="$1"
  _dest="$2"
  _label="$3"

  _dest_dir=$(dirname "$_dest")
  _tmp=$(mktemp "$_dest_dir/.dl.XXXXXX") || {
    printf "      ${RED}✗${NC} Failed to create temp file for %s\n" "$_label"
    return 1
  }

  if curl -sfS --proto '=https' "$_url" -o "$_tmp" 2>/dev/null && [ -s "$_tmp" ]; then
    mv "$_tmp" "$_dest"
    printf "      ${GREEN}✓${NC} %s\n" "$_label"
    return 0
  else
    rm -f "$_tmp" 2>/dev/null
    printf "      ${RED}✗${NC} Failed to download %s\n" "$_label"
    return 1
  fi
}

# ── Header ───────────────────────────────────────────────────────────────────
printf "\n"
printf "                       ${BOLD}⚡ 9routerx${NC} ${DIM}v%s${NC}\n" "$VERSION"
printf "              ${DIM}Multi-provider AI gateway installer${NC}\n"
printf "\n"
printf "${DIM}  ────────────────────────────────────────────────────────────────${NC}\n"
printf "\n"
printf "  ${BOLD}System${NC}\n"
printf "\n"
printf "      OS         ${BOLD}%s${NC}\n" "$OS"
printf "      Home       ${DIM}%s${NC}\n" "$INSTALL_HOME"
printf "\n"
printf "${DIM}  ────────────────────────────────────────────────────────────────${NC}\n"
printf "\n"
printf "  ${BOLD}Downloading${NC}\n"
printf "\n"

# ── Create directories ───────────────────────────────────────────────────────
mkdir -p "${INSTALL_HOME}/scripts/sync"
printf "      ${GREEN}✓${NC} Created ${DIM}~/.9routerx${NC}\n"

# ── Download scripts ─────────────────────────────────────────────────────────
FAIL=0

safe_download "${BASE_URL}/scripts/install.sh"                    "${INSTALL_HOME}/scripts/install.sh"                    "install.sh"                    || FAIL=1
safe_download "${BASE_URL}/scripts/9routerx"                      "${INSTALL_HOME}/scripts/9routerx"                      "9routerx CLI"                  || FAIL=1
safe_download "${BASE_URL}/scripts/combo.py"                      "${INSTALL_HOME}/scripts/combo.py"                      "combo.py"                      || FAIL=1
safe_download "${BASE_URL}/scripts/doctor.sh"                     "${INSTALL_HOME}/scripts/doctor.sh"                     "doctor.sh"                     || true
safe_download "${BASE_URL}/scripts/bootstrap-vps.sh"              "${INSTALL_HOME}/scripts/bootstrap-vps.sh"              "bootstrap-vps.sh"              || true
safe_download "${BASE_URL}/scripts/sync/9router_claude_sync.py"   "${INSTALL_HOME}/scripts/sync/9router_claude_sync.py"   "9router_claude_sync.py"        || FAIL=1
safe_download "${BASE_URL}/scripts/sync/install_sync_cron.sh"     "${INSTALL_HOME}/scripts/sync/install_sync_cron.sh"     "install_sync_cron.sh"          || true

if [ "$FAIL" -eq 1 ]; then
  printf "\n"
  printf "  ${RED}${BOLD}✗ Critical download(s) failed${NC}\n"
  printf "  ${DIM}Check your network and try again.${NC}\n"
  printf "\n"
  exit 1
fi

# ── Set permissions ──────────────────────────────────────────────────────────
chmod +x \
  "${INSTALL_HOME}/scripts/install.sh" \
  "${INSTALL_HOME}/scripts/9routerx" \
  "${INSTALL_HOME}/scripts/sync/9router_claude_sync.py" \
  "${INSTALL_HOME}/scripts/sync/install_sync_cron.sh" \
  2>/dev/null || true

[ -f "${INSTALL_HOME}/scripts/doctor.sh" ]        && chmod +x "${INSTALL_HOME}/scripts/doctor.sh"
[ -f "${INSTALL_HOME}/scripts/bootstrap-vps.sh" ]  && chmod +x "${INSTALL_HOME}/scripts/bootstrap-vps.sh"

printf "\n"
printf "${DIM}  ────────────────────────────────────────────────────────────────${NC}\n"
printf "\n"
printf "  ${BOLD}Running installer${NC} ${DIM}→${NC}\n"
printf "\n"

# ── Hand off to install.sh ───────────────────────────────────────────────────
exec "${INSTALL_HOME}/scripts/install.sh" "$@"
