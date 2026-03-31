#!/usr/bin/env bash
# generate-api-key.sh — generate a 9router API key on a remote VPS and return it.
#
# Usage:
#   ./generate-api-key.sh <user@host> [ssh-port]
#
# This script:
#   1. SSHes to the VPS
#   2. Calls 9router's /api/keys endpoint to create a new key
#   3. Enables requireLogin if not already enabled
#   4. Returns the generated key to stdout
set -euo pipefail

HOST="${1:?Usage: $0 <user@host> [ssh-port]}"
PORT="${2:-22}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

printf "${BOLD}Generating 9router API key on %s${NC}\n\n" "$HOST"

API_KEY=$(ssh -p "$PORT" "$HOST" 'bash -s' <<'REMOTE'
set -euo pipefail

ROUTER_BASE="http://127.0.0.1:20128"

# Check if 9router is reachable
if ! curl -sf -m 3 "${ROUTER_BASE}/api/settings" >/dev/null 2>&1; then
  echo "ERROR: 9router not reachable at ${ROUTER_BASE}" >&2
  exit 1
fi

# Generate a new API key
KEY_RESP=$(curl -sf -X POST "${ROUTER_BASE}/api/keys" \
  -H "Content-Type: application/json" \
  -d '{"name":"client-setup-'$(date +%s)'","scopes":["read","write"]}' 2>&1)

API_KEY=$(printf '%s' "$KEY_RESP" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('key', ''))
except Exception:
    sys.exit(1)
")

if [[ -z "$API_KEY" ]]; then
  echo "ERROR: Failed to extract API key from response: $KEY_RESP" >&2
  exit 1
fi

# Enable requireLogin if not already enabled
SETTINGS=$(curl -sf "${ROUTER_BASE}/api/settings" 2>&1)
REQUIRE_LOGIN=$(printf '%s' "$SETTINGS" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('requireLogin', False))
" 2>/dev/null || echo "false")

if [[ "$REQUIRE_LOGIN" != "True" ]]; then
  curl -sf -X PATCH "${ROUTER_BASE}/api/settings" \
    -H "Content-Type: application/json" \
    -d '{"requireLogin":true}' >/dev/null 2>&1 || true
  echo "INFO: Enabled requireLogin on 9router" >&2
fi

printf '%s' "$API_KEY"
REMOTE
)

if [[ -z "${API_KEY:-}" ]]; then
  printf "${RED}✗${NC} Failed to generate API key\n" >&2
  exit 1
fi

printf "${GREEN}✓${NC} API key generated: ${DIM}%s${NC}\n" "$API_KEY"
printf "\n"
printf "Add this to ${BOLD}~/.claude/settings.json${NC}:\n"
printf '  "env": {\n'
printf '    "ANTHROPIC_AUTH_TOKEN": "%s"\n' "$API_KEY"
printf '  }\n'
printf "\n"
printf "%s\n" "$API_KEY"
