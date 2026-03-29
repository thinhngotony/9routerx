# 9routerx

Automated local setup for:

1. Claude Code CLI
2. Antigravity CLI
3. GitHub Copilot CLI
4. Cursor IDE
5. 9router

Plus automatic sync of Claude settings whenever 9router tunnel/model routing changes.

## What this does

- Installs each tool only if it is missing.
- Supports macOS and Linux for CLI tools.
- Installs Cursor on macOS (GUI app install is best-effort on Linux).
- Adds a sync cron job to keep:
  - `ANTHROPIC_BASE_URL` aligned with current 9router tunnel URL
  - default Claude model aliases switched to working providers

## Quick start

```sh
curl -sfS https://raw.githubusercontent.com/thinhngotony/9routerx/master/install-universal.sh | sh
```

Installer supports mode selection:

```sh
# Local machine with Cursor IDE login
curl -sfS https://raw.githubusercontent.com/thinhngotony/9routerx/master/install-universal.sh | sh -s -- --local-cursor

# VPS gateway (headless, Cursor optional)
curl -sfS https://raw.githubusercontent.com/thinhngotony/9routerx/master/install-universal.sh | sh -s -- --vps-headless
```

Alternative (local clone):

```bash
cd /Users/tony/personal/9routerx
chmod +x scripts/install.sh scripts/sync/install_sync_cron.sh
./scripts/install.sh
```

### Fully automated VPS bootstrap (includes Cursor token transfer)

Run this from your local machine (where Cursor is already logged in):

```bash
cd /Users/tony/personal/9routerx
chmod +x scripts/bootstrap-vps.sh
./scripts/bootstrap-vps.sh root@YOUR_VPS_IP 22
```

Refresh only Cursor tokens (skip reinstall):

```bash
./scripts/bootstrap-vps.sh --sync-only root@YOUR_VPS_IP 22
```

This command:
- extracts `cursorAuth/*` tokens from your local Cursor DB
- transfers them to VPS over SSH (base64-encoded env vars)
- runs the remote installer with token seeding

Recommended flow:

```bash
# First-time VPS setup in headless mode
curl -sfS https://raw.githubusercontent.com/thinhngotony/9routerx/master/install-universal.sh | sh -s -- --vps-headless

# Later, sync Cursor tokens from your local machine (optional provider)
./scripts/bootstrap-vps.sh --sync-only root@YOUR_VPS_IP 22
```

### Health check (doctor)

```bash
cd /Users/tony/personal/9routerx
chmod +x scripts/doctor.sh

# Auto mode (Linux -> vps-headless, others -> local-cursor)
./scripts/doctor.sh

# Explicit mode
./scripts/doctor.sh --mode local-cursor
./scripts/doctor.sh --mode vps-headless
```

After `9router` install/login/setup is done by user, run:

```bash
python3 scripts/sync/9router_claude_sync.py
./scripts/sync/install_sync_cron.sh "$(pwd)/scripts/sync/9router_claude_sync.py" "$HOME/.9router/claude-sync.log"
```

## Notes

- Installer is idempotent: safe to rerun.
- `copilot` CLI requires user auth after install (`copilot auth login`).
- `9router` requires user/provider login in its own flow.
- Cron sync runs every minute and updates only when needed.
- Prefer `http://127.0.0.1:20128` over `http://localhost:20128` on laptops (some systems resolve `localhost` to IPv6 `::1` and the UI may hang).

## Vanity URL via Cloudflare Worker

This repo includes `worker.js` + `wrangler.toml` so you can expose one-command installs:

```sh
curl -sfS https://9routerx.hyberorbit.com/install | sh
```

### Deploy

```sh
npm install -g wrangler
cd /Users/tony/personal/9routerx
wrangler deploy
```

Then map your domain route (example):
- `9routerx.hyberorbit.com/*` -> Worker `9routerx`

Available endpoints:
- `/install`
- `/install.sh`
- `/sync.py`
- `/sync-cron.sh`

## Release workflow

Repo includes GitHub Actions workflow matching the `alias` pattern:

- Run CI on push/PR
- Create GitHub Release automatically on tags `v*`
- Release notes are extracted from `CHANGELOG.md`

Example release:

```bash
git tag v1.0.1
git push origin v1.0.1
```

