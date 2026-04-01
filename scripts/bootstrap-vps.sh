#!/usr/bin/env bash
# bootstrap-vps.sh — thin wrapper used by the Cloudflare Worker / curl-pipe installs.
# Delegates to install.sh in headless VPS mode.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/install.sh" --vps-headless "$@"
