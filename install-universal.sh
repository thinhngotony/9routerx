#!/bin/sh
set -eu

INSTALL_HOME="${HOME}/.9routerx"

# Resolve latest release tag; fallback to main for first-time setup.
VERSION=$(curl -sfS "https://api.github.com/repos/thinhngotony/9routerx/releases/latest" 2>/dev/null \
  | awk -F '"' '/tag_name/ {print $4; exit}' | sed 's/^v//')

if printf '%s' "${VERSION:-}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+'; then
  BASE_URL="https://raw.githubusercontent.com/thinhngotony/9routerx/v${VERSION}"
else
  BASE_URL="https://raw.githubusercontent.com/thinhngotony/9routerx/main"
fi

mkdir -p "${INSTALL_HOME}/scripts/sync"

download() {
  url="$1"
  dest="$2"
  tmp="${dest}.tmp"
  if ! curl -sfS "${url}" -o "${tmp}"; then
    rm -f "${tmp}" 2>/dev/null || true
    echo "Failed downloading ${url}" >&2
    exit 1
  fi
  mv "${tmp}" "${dest}"
}

echo "Installing 9routerx from ${BASE_URL}"

download "${BASE_URL}/scripts/install.sh" "${INSTALL_HOME}/scripts/install.sh"
download "${BASE_URL}/scripts/sync/9router_claude_sync.py" "${INSTALL_HOME}/scripts/sync/9router_claude_sync.py"
download "${BASE_URL}/scripts/sync/install_sync_cron.sh" "${INSTALL_HOME}/scripts/sync/install_sync_cron.sh"

chmod +x \
  "${INSTALL_HOME}/scripts/install.sh" \
  "${INSTALL_HOME}/scripts/sync/9router_claude_sync.py" \
  "${INSTALL_HOME}/scripts/sync/install_sync_cron.sh"

exec "${INSTALL_HOME}/scripts/install.sh"

