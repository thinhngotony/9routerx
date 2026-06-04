# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

9routerx is a multi-provider AI gateway installer that deploys and manages Claude Code, Antigravity, GitHub Copilot CLI, Cursor IDE, and 9router on local machines or remote VPS servers. It provides a unified routing layer that combines multiple AI providers into virtual models with fallback or round-robin strategies.

## Common Commands

### Installation
```bash
# Local installation (interactive)
./scripts/install.sh

# Install on remote VPS from local machine
./scripts/install.sh --sync-to root@YOUR_VPS_IP --ssh-port 22

# Specific modes
./scripts/install.sh --local-cursor    # Local with Cursor
./scripts/install.sh --vps-headless    # Headless VPS with systemd
./scripts/install.sh --remote-vps      # Remote VPS install via SSH
```

### Health Checks
```bash
# Interactive mode selection
./scripts/doctor.sh

# Non-interactive
./scripts/doctor.sh --mode local-cursor
./scripts/doctor.sh --mode vps-headless

# Auto-fix issues (prompts before changes)
./scripts/doctor.sh --mode vps-headless --fix
./scripts/doctor.sh --mode vps-headless --fix --yes  # unattended
```

### Combo/Model Management
```bash
# Browse available models
9routerx models

# List existing combos
9routerx combos list

# Create a combo (interactive wizard)
9routerx combos create

# Delete a combo
9routerx combos delete <name>

# Non-interactive combo creation
python3 scripts/combo.py create --name opus-4-6 --models cc/claude-opus-4-6,gh/claude-opus-4.5 --strategy fallback --validate
```

### Token Sync
```bash
# Run sync manually
python3 scripts/sync/9router_claude_sync.py

# Install sync cron job
./scripts/sync/install_sync_cron.sh "$(pwd)/scripts/sync/9router_claude_sync.py" "$HOME/.9router/claude-sync.log"

# Point clients to a router URL
9routerx point-to http://YOUR_VPS_IP:20128
9routerx point-to http://YOUR_VPS_IP:20128 --only claude  # specific target
```

### Cloudflare Worker
```bash
# Deploy worker
npm install -g wrangler
wrangler deploy
```

### Testing / CI
```bash
# Lint shell scripts
shellcheck -s sh install-universal.sh
shellcheck -s bash scripts/install.sh
shellcheck -s bash scripts/doctor.sh

# Syntax checks
sh -n install-universal.sh
bash -n scripts/install.sh
python3 -m py_compile scripts/combo.py

# Run functional test assertions
# See .github/workflows/ci.yml for all validation checks
```

## Architecture

### Components

1. **Cloudflare Worker** (`worker.js`) - Routes vanity URLs to raw GitHub content:
   - `/install` → `install-universal.sh`
   - `/install.sh` → `scripts/install.sh`
   - `/bootstrap` → `scripts/bootstrap-vps.sh`
   - `/sync.py` → `scripts/sync/9router_claude_sync.py`
   - `/sync-cron.sh` → `scripts/sync/install_sync_cron.sh`

2. **Universal Installer** (`install-universal.sh`) - POSIX shell entry point that downloads and delegates to install.sh

3. **Core Installer** (`scripts/install.sh`) - Supports three modes:
   - `local-cursor`: Installs on local machine with Cursor IDE
   - `vps-headless`: Headless VPS install with systemd service
   - `remote-vps`: SSH-based install from local machine to remote VPS

4. **Health Checker** (`scripts/doctor.sh`) - Verifies all components and offers auto-remediation

5. **CLI Tool** (`scripts/9routerx`) - Wrapper around combo.py for interactive model/combo management

6. **Combo Engine** (`scripts/combo.py`) - Creates virtual models that route to multiple providers with fallback or round-robin strategies

7. **Sync Script** (`scripts/sync/9router_claude_sync.py`) - Keeps Claude Code settings aligned with 9router's current state

### Data Flow

```
User runs installer → 9router deployed on VPS/local
                                   ↓
                    9router exposes REST API on port 20128
                                   ↓
         9routerx CLI → combo.py → 9router API → creates combos in db.json
                                   ↓
        sync script → reads 9router state → updates Claude Code settings.json
```

### Database

9router stores configuration in `~/.9router/db.json` with these top-level keys:
- `providers`: Configured AI providers
- `combos`: Virtual model definitions
- `modelAliases`: Model name mappings
- `settings`: Configuration including `comboStrategy`

## Key Implementation Details

- Uses SSH ControlMaster for single-password remote installs
- Extracts Cursor tokens from local `cursorAuth/*` SQLite and injects into remote VPS
- Systemd service uses `--tray --no-browser --host 0.0.0.0 --port 20128 --skip-update`
- Always use `127.0.0.1` instead of `localhost` to avoid IPv6 resolution issues
- npm cache isolated to `~/.cache/9routerx-npm-cache` to avoid permission conflicts

## Troubleshooting Patterns

- **9router not running**: Run `./scripts/doctor.sh --mode vps-headless --fix`
- **localhost hangs but 127.0.0.1 works**: IPv6 trap — always use `127.0.0.1:20128`
- **Token sync failed**: Re-run `./scripts/install.sh --sync-to root@YOUR_VPS_IP --ssh-port 22`
- **Worker routing 404**: Check that the route matches `/install`, `/install.sh`, etc.