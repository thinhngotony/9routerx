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
curl -sfS https://9routerx.hyberorbit.com/install | sh
```

Installer supports mode selection:

```sh
# Local machine with Cursor IDE login
curl -sfS https://9routerx.hyberorbit.com/install | sh -s -- --local-cursor

# VPS gateway (headless, Cursor optional)
curl -sfS https://9routerx.hyberorbit.com/install | sh -s -- --vps-headless

# Sync Cursor tokens from this machine to a remote VPS (auto-installs if needed)
curl -sfS https://9routerx.hyberorbit.com/install | sh -s -- --sync-to root@YOUR_VPS_IP --ssh-port 22
```

Alternative (local clone):

```bash
chmod +x scripts/install.sh scripts/sync/install_sync_cron.sh
./scripts/install.sh
```

### Sync Cursor tokens to VPS (auto-installs on first run)

Run this from your local machine (where Cursor is already logged in):

```bash
./scripts/install.sh --sync-to root@YOUR_VPS_IP --ssh-port 22
```

This command:
- extracts `cursorAuth/*` tokens from your local Cursor DB
- transfers them to VPS over SSH (base64-encoded env vars)
- runs the remote installer with token seeding

### Health check (doctor)

```bash
./scripts/doctor.sh

# Explicit mode (non-interactive safe)
./scripts/doctor.sh --mode local-cursor
./scripts/doctor.sh --mode vps-headless
```

### Virtual models (combos) for fallback / load balancing

Create a virtual model name that routes to multiple upstream providers/models.

Interactive CLI (recommended):

```bash
9routerx models
9routerx combos create
9routerx combos list
9routerx combos delete <name>
```

Non-interactive (advanced):

```bash
python3 scripts/combo.py create \
  --name opus-4-6 \
  --models cc/claude-opus-4-6,gh/claude-opus-4.5 \
  --strategy fallback \
  --validate
```

Then in Claude Code, set your default model to the **combo name** (virtual model id), e.g. `opus-4-6`.

After `9router` install/login/setup is done, run the sync:

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

