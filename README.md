<p align="center">
  <img src="https://img.shields.io/badge/platforms-Linux%20%7C%20macOS-blue" alt="Platforms">
  <img src="https://img.shields.io/badge/install-one--command-brightgreen" alt="One-command install">
  <img src="https://img.shields.io/badge/self--healing-systemd%20auto--restart-orange" alt="Self-healing">
  <img src="https://img.shields.io/github/license/thinhngotony/9routerx" alt="License">
  <img src="https://img.shields.io/badge/PRs-welcome-brightgreen" alt="PRs Welcome">
</p>

<h1 align="center">9routerx</h1>

<p align="center">
  <strong>One command. Multi-provider AI gateway. Everywhere.</strong>
</p>

<p align="center">
  Installs and manages the full AI routing stack — Claude Code, Antigravity,<br>
  GitHub Copilot CLI, Cursor IDE, and 9router — on any machine or VPS.
</p>

---

## Quick Start

**Install on this machine (macOS or Linux):**

```sh
curl -sfS https://9routerx.hyberorbit.com/install | sh
```

**Install in a specific mode:**

```sh
# Local machine with Cursor IDE login
curl -sfS https://9routerx.hyberorbit.com/install | sh -s -- --local-cursor

# VPS / headless server (no GUI, systemd auto-start included)
curl -sfS https://9routerx.hyberorbit.com/install | sh -s -- --vps-headless

# Sync Cursor tokens from this machine to a remote VPS (auto-installs if needed)
curl -sfS https://9routerx.hyberorbit.com/install | sh -s -- --sync-to root@YOUR_VPS_IP --ssh-port 22
```

**From a local clone:**

```bash
chmod +x scripts/install.sh
./scripts/install.sh
```

> After VPS install, 9router starts automatically and survives reboots via a systemd service. Open `http://YOUR_VPS_IP:20128` in your browser.

---

## Why 9routerx?

| Feature | Description |
| --- | --- |
| **One-command install** | Installs Claude Code, Antigravity, Copilot CLI, Cursor, and 9router in a single run |
| **Idempotent** | Safe to re-run — skips what is already installed and up to date |
| **VPS-ready** | Headless install with systemd service for auto-restart and boot persistence |
| **Self-healing** | Post-install doctor verifies every component; `--fix` remediates issues automatically |
| **Token sync** | Extracts Cursor auth tokens from your local machine and injects them into a remote VPS over SSH |
| **Virtual models** | Combine multiple providers into a single model name with fallback or round-robin routing |
| **Auto-sync** | Cron job keeps `ANTHROPIC_BASE_URL` and model aliases aligned with live 9router state |
| **Remote verify** | After every VPS install, installer SSHes back, runs health checks, and offers to fix issues |

---

## How It Works

```
1. Installer detects OS and mode (local-cursor or vps-headless)
2. Installs missing tools: node, claude, antigravity-ide, gh, cursor, 9router
3. On VPS: creates systemd service for auto-restart and boot persistence
4. Initialises Cursor state DB and 9router database
5. Syncs Cursor tokens from local machine to VPS over SSH (mode 2)
6. Registers Cursor provider in 9router automatically
7. Runs doctor.sh remotely to verify every component
8. Reports issues and offers auto-remediation — asks before touching anything
```

---

## Install Modes

### Mode 1 — Local machine (interactive)

Run the installer with no flags. It detects your OS and guides you:

```sh
./scripts/install.sh
```

Select **1** to install on this machine. On macOS, installs Cursor IDE via Homebrew. On Linux, runs headless setup.

### Mode 2 — Remote VPS (SSH sync)

Run from your **local machine** where Cursor is already logged in:

```sh
./scripts/install.sh --sync-to root@YOUR_VPS_IP --ssh-port 22
```

This single command:

1. Opens one SSH ControlMaster connection (single password prompt)
2. Extracts `cursorAuth/*` tokens from your local Cursor database
3. Uploads and runs the headless installer on the remote VPS
4. Injects Cursor tokens into the remote Cursor state DB
5. Auto-registers the Cursor provider in 9router
6. **Runs `doctor.sh` remotely and verifies the install**
7. If issues are found, asks whether to fix them automatically

---

## Health Check

`doctor.sh` checks every component and reports pass / warn / fail for each:

```bash
# Interactive mode selection
./scripts/doctor.sh

# Non-interactive (safe for CI and remote runs)
./scripts/doctor.sh --mode local-cursor
./scripts/doctor.sh --mode vps-headless

# Check and fix issues automatically (prompts before making changes)
./scripts/doctor.sh --mode vps-headless --fix

# Unattended fix — no prompts (used by installer after remote VPS setup)
./scripts/doctor.sh --mode vps-headless --fix --yes
```

**What it checks:**

| Check | local-cursor | vps-headless |
| --- | :---: | :---: |
| Node.js, npm, Python 3 | ✓ | ✓ |
| Claude Code CLI | ✓ | ✓ |
| 9router binary | ✓ | ✓ |
| GitHub CLI, antigravity-ide | ✓ | ✓ |
| 9router database | ✓ | ✓ |
| 9router process running | ✓ | ✓ |
| 9router HTTP health | ✓ | ✓ |
| IPv6 localhost trap | ✓ | ✓ |
| systemd service (active + enabled) | — | ✓ |
| Cursor IDE / CLI | ✓ | — |
| Cursor state.vscdb | ✓ | ✓ |

**Auto-fix actions (vps-headless + `--fix`):**

- Installs and enables the systemd service if missing
- Restarts a crashed systemd service
- Starts 9router via `nohup` when systemd is unavailable
- Waits for 9router HTTP to be ready and confirms recovery

---

## Virtual Models (Combos)

Create a virtual model name that routes across multiple providers with fallback or round-robin:

**Interactive CLI (recommended):**

```bash
9routerx models               # browse all available model IDs
9routerx combos list          # list existing virtual models
9routerx combos create        # guided creation wizard
9routerx combos delete <name> # remove a virtual model
```

**Non-interactive (scripting / CI):**

```bash
python3 scripts/combo.py create \
  --name opus-4-6 \
  --models cc/claude-opus-4-6,gh/claude-opus-4.5 \
  --strategy fallback \
  --validate
```

Then set your Claude Code default model to the combo name:

```bash
claude config set model opus-4-6
```

---

## Token Sync (Cron)

Keep `ANTHROPIC_BASE_URL` and model aliases aligned with live 9router state automatically:

```bash
# Run once manually
python3 scripts/sync/9router_claude_sync.py

# Install as a cron job (runs every minute, updates only when state changes)
./scripts/sync/install_sync_cron.sh \
  "$(pwd)/scripts/sync/9router_claude_sync.py" \
  "$HOME/.9router/claude-sync.log"
```

---

## Cloudflare Worker (Vanity URLs)

This repo ships a Cloudflare Worker that exposes clean install URLs:

| URL | Description |
| --- | --- |
| `https://9routerx.hyberorbit.com/install` | Universal installer |
| `https://9routerx.hyberorbit.com/install.sh` | Installer (explicit `.sh`) |
| `https://9routerx.hyberorbit.com/sync.py` | Sync script |
| `https://9routerx.hyberorbit.com/sync-cron.sh` | Cron installer |

**Deploy:**

```bash
npm install -g wrangler
wrangler deploy
```

Then map your domain route: `9routerx.hyberorbit.com/*` → Worker `9routerx`.

---

## Release Workflow

Releases follow the same CI/CD pattern as the `alias` project:

```bash
# Tag a release — GitHub Actions builds, tests, and publishes automatically
git tag v1.0.1
git push origin v1.0.1
```

Release notes are extracted from `CHANGELOG.md` automatically.

---

## Directory Structure

```
9routerx/
├── install-universal.sh          # Entry point — downloads scripts and hands off to install.sh
├── scripts/
│   ├── install.sh                # Core installer (local-cursor, vps-headless, remote-vps modes)
│   ├── doctor.sh                 # Health checker and auto-remediator
│   ├── 9routerx                  # CLI for combo / model management
│   ├── combo.py                  # Combo builder (create, list, delete via 9router API)
│   └── sync/
│       ├── 9router_claude_sync.py    # Syncs ANTHROPIC_BASE_URL and model aliases
│       └── install_sync_cron.sh     # Installs the sync cron job
├── worker.js                     # Cloudflare Worker for vanity install URLs
└── wrangler.toml                 # Cloudflare Worker config
```

---

## Requirements

| Platform | Requirements |
| --- | --- |
| macOS | Bash or Zsh, `curl`, Homebrew (auto-installed if missing) |
| Linux | Bash, `curl`, `python3`, `sudo` (for systemd service install) |

---

## Troubleshooting

<details>
<summary><strong>9router is not running after VPS install</strong></summary>

SSH into your VPS and run the doctor:

```bash
./scripts/doctor.sh --mode vps-headless --fix
```

Or check the startup log directly:

```bash
cat ~/.9router/startup.log
```

If the systemd service was not installed, create it manually:

```bash
ROUTER_BIN=$(command -v 9router)
cat > /etc/systemd/system/9router.service <<EOF
[Unit]
Description=9router AI gateway
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=root
# --tray suppresses the interactive TUI picker that hijacks the terminal.
# --skip-update prevents the auto-updater from restarting outside systemd.
# StandardInput=null ensures no TTY is inherited.
ExecStart=${ROUTER_BIN} --no-browser --tray --host 0.0.0.0 --port 20128 --skip-update
Restart=on-failure
RestartSec=5
StandardInput=null
StandardOutput=append:/root/.9router/startup.log
StandardError=append:/root/.9router/startup.log
Environment=NO_COLOR=1
Environment=TERM=dumb

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now 9router
```

</details>

<details>
<summary><strong>Cloudflare Tunnel keeps retrying</strong></summary>

The tunnel connects to 9router's local HTTP server. If the tunnel is retrying, 9router is either not running or not ready. Check:

```bash
curl -sf http://127.0.0.1:20128/api/providers
systemctl status 9router
```

Start or restart 9router, then the tunnel will reconnect automatically.

</details>

<details>
<summary><strong>500 errors on the 9router dashboard</strong></summary>

Next.js static assets return 500 when the Node.js server process has crashed or is starting up. Wait 10–15 seconds after starting 9router, or restart the service:

```bash
systemctl restart 9router
```

</details>

<details>
<summary><strong>localhost:20128 hangs but 127.0.0.1:20128 works</strong></summary>

Your system resolves `localhost` to `::1` (IPv6) but 9router only listens on IPv4. Use `http://127.0.0.1:20128` in all configurations, including `ANTHROPIC_BASE_URL`.

The doctor will flag this automatically:

```bash
./scripts/doctor.sh --mode vps-headless
```

</details>

<details>
<summary><strong>Cursor tokens not synced / provider not auto-registered</strong></summary>

Re-run the sync from your local machine (where Cursor is logged in):

```bash
./scripts/install.sh --sync-to root@YOUR_VPS_IP --ssh-port 22
```

Or manually register via the 9router API:

```bash
curl -X POST http://127.0.0.1:20128/api/oauth/cursor/import \
  -H 'Content-Type: application/json' \
  -d '{"accessToken":"YOUR_TOKEN","machineId":"YOUR_MACHINE_ID"}'
```

</details>

<details>
<summary><strong>Clean reinstall</strong></summary>

```bash
# Stop the service
systemctl stop 9router
systemctl disable 9router
rm -f /etc/systemd/system/9router.service
systemctl daemon-reload

# Re-run the installer
curl -sfS https://9routerx.hyberorbit.com/install | sh -s -- --vps-headless
```

</details>

---

## Security

**API Key Authentication:**

When running 9router on a VPS accessible from the internet, **enable `requireLogin`** and use real API keys. The client-setup flow (`--client-setup`, option 3) automatically:

1. SSHes to the VPS
2. Calls `POST /api/keys` to generate a secure key
3. Enables `requireLogin: true` in 9router settings
4. Writes the key to local `~/.claude/settings.json`

**Never use dummy tokens like `"9router"` on public VPS instances** — anyone can consume your provider quotas.

Manually generate a key:

```bash
ssh root@YOUR_VPS_IP
curl -X POST http://127.0.0.1:20128/api/keys \
  -H 'Content-Type: application/json' \
  -d '{"name":"my-client","scopes":["read","write"]}'

# Enable auth
curl -X PATCH http://127.0.0.1:20128/api/settings \
  -H 'Content-Type: application/json' \
  -d '{"requireLogin":true}'
```

Then add the returned key to `~/.claude/settings.json`:

```json
{
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "9r_xxxxxxxxxxxxxx"
  }
}
```

---

## Notes

- Installer is idempotent — safe to re-run at any time.
- `copilot` CLI requires user auth after install: `copilot auth login`
- `9router` requires provider login in its own UI flow at `http://YOUR_IP:20128`
- Cron sync runs every minute and updates only when 9router state has changed.
- Always prefer `http://127.0.0.1:20128` over `http://localhost:20128` to avoid IPv6 resolution issues.

---

## Contributing

Contributions are welcome. Please open an issue before submitting large changes.

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-feature`
3. Commit your changes: `git commit -m 'feat: add your feature'`
4. Push and open a Pull Request

---

## License

MIT License — see [LICENSE](LICENSE) for details.

---

<p align="center">
  <sub>Built with care by <a href="https://hyberorbit.com">Hyber Orbit</a></sub>
</p>
