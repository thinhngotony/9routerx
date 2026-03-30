# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-03-30

### Added

- Remote VPS install mode (`--remote-vps` / option 3): install on a remote server via SSH from your local laptop.
- Cursor token sync during remote install: extracts tokens from local Cursor DB and injects into VPS.
- SSH connectivity test before remote install proceeds.
- Auto-update logic: re-running the installer now upgrades all npm packages (9router, Claude Code, Antigravity, Copilot CLI) to their latest versions instead of skipping if already installed.
- Beautiful CLI output with colors, checkmarks, section headers, and separators (inspired by Hyber Alias installer).
- `safe_download()` in universal installer: atomic temp-file downloads with error reporting.
- `npm_global_install()` helper: handles npm permission issues (EACCES/EEXIST) with cache verify, sudo fallback on Linux, and user-prefix fix on macOS.
- `/bootstrap` route in Cloudflare Worker for direct access to `bootstrap-vps.sh`.
- Additional scripts downloaded by universal installer: `doctor.sh`, `bootstrap-vps.sh`.

### Changed

- Redesigned `install-universal.sh` with branded header, system info display, and color-coded download progress.
- Redesigned `scripts/install.sh` with formatted output, section separators, and mode-specific summaries.
- Mode selector now shows 4 options: local-cursor, vps-headless, remote-vps, auto.
- `gh extension upgrade` used for Copilot CLI updates (instead of re-install).

### Deprecated

- `scripts/bootstrap-vps.sh` as standalone entry point — use `install.sh --remote-vps` instead (script kept for backward compatibility).

## [1.0.0] - 2026-03-27

### Added

- Idempotent bootstrap installer for Claude Code CLI, Antigravity CLI, Copilot CLI, Cursor, and 9router.
- Universal installer entrypoint `install-universal.sh` for one-command setup.
- Claude settings sync script that updates dynamic tunnel URL and auto-selects working model aliases.
- Cron installer for periodic self-healing sync.
- Cloudflare Worker routing for stable install endpoints (`/install`, `/install.sh`, `/sync.py`, `/sync-cron.sh`).
- CI workflow with shell linting, syntax checks, functional checks, and tag-driven GitHub release automation.
