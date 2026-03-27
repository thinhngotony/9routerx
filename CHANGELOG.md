# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-03-27

### Added

- Idempotent bootstrap installer for Claude Code CLI, Antigravity CLI, Copilot CLI, Cursor, and 9router.
- Universal installer entrypoint `install-universal.sh` for one-command setup.
- Claude settings sync script that updates dynamic tunnel URL and auto-selects working model aliases.
- Cron installer for periodic self-healing sync.
- Cloudflare Worker routing for stable install endpoints (`/install`, `/install.sh`, `/sync.py`, `/sync-cron.sh`).
- CI workflow with shell linting, syntax checks, functional checks, and tag-driven GitHub release automation.

