#!/usr/bin/env python3
"""
auto-update.py — safe daily updater for 9router

Checks if a newer 9router version is available via npm.  If so, it reads
~/.9router/request-details.json to find the most recent proxy request and
only applies the update when the server has been idle for at least 1 hour
(no requests in that window).  This avoids restarting 9router mid-session
and disrupting active users.

Usage:
  python3 auto-update.py
  python3 auto-update.py --quiet
  python3 auto-update.py --help
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

REQUEST_DETAILS = os.path.expanduser("~/.9router/request-details.json")
IDLE_THRESHOLD_SECONDS = 60 * 60  # 1 hour


# ── Helpers ──────────────────────────────────────────────────────────────────

def _log(msg: str) -> None:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"[{ts}] {msg}", flush=True)


def _npm_global_json(pkg: str) -> dict:
    """Return the JSON output of `npm list -g <pkg> --depth=0 --json`."""
    r = subprocess.run(
        ["npm", "list", "-g", pkg, "--depth=0", "--json"],
        capture_output=True, text=True, timeout=30,
    )
    if r.returncode != 0:
        raise RuntimeError(f"npm list failed: {r.stderr.strip()}")
    return json.loads(r.stdout)


def _get_installed_version() -> str:
    """Return the installed 9router version string, e.g. '0.5.20'."""
    data = _npm_global_json("9router")
    return data.get("dependencies", {}).get("9router", {}).get("version", "")


def _get_latest_version() -> str:
    """Return the latest 9router version from the npm registry."""
    r = subprocess.run(
        ["npm", "view", "9router", "version"],
        capture_output=True, text=True, timeout=30,
    )
    if r.returncode != 0:
        raise RuntimeError(f"npm view failed: {r.stderr.strip()}")
    return r.stdout.strip()


def _last_request_time() -> datetime:
    """
    Return the most recent request timestamp from 9router's
    request-details.json.  Returns epoch (1970) if the file is missing,
    empty, or unparseable (meaning: safe to update).
    """
    epoch = datetime(1970, 1, 1, tzinfo=timezone.utc)
    if not os.path.exists(REQUEST_DETAILS):
        return epoch

    try:
        with open(REQUEST_DETAILS, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return epoch

    records = data.get("records", []) if isinstance(data, dict) else []
    if not records:
        return epoch

    latest = epoch
    for r in records:
        ts = r.get("timestamp", "")
        if not ts:
            continue
        try:
            dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
            if dt > latest:
                latest = dt
        except Exception:
            continue
    return latest


def _is_idle() -> bool:
    """Return True if no requests have been recorded in the last hour."""
    last = _last_request_time()
    now = datetime.now(timezone.utc)
    delta = (now - last).total_seconds()
    return delta >= IDLE_THRESHOLD_SECONDS


def _restart_service() -> bool:
    """Restart 9router via systemctl.  Returns True on success."""
    try:
        subprocess.run(
            ["systemctl", "restart", "9router"],
            capture_output=True, text=True, timeout=30, check=True,
        )
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


# ── Main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Safe auto-updater for 9router — only updates when idle.",
    )
    parser.add_argument("--quiet", action="store_true", help="Suppress non-error output")
    args = parser.parse_args()
    quiet = args.quiet

    # 1. Get current version
    try:
        current = _get_installed_version()
    except Exception as exc:
        _log(f"ERROR: cannot determine installed version — {exc}")
        return 1

    if not quiet:
        _log(f"Installed: {current}")

    # 2. Get latest version
    try:
        latest = _get_latest_version()
    except Exception as exc:
        _log(f"ERROR: cannot determine latest version — {exc}")
        return 1

    if not quiet:
        _log(f"Latest:    {latest}")

    if current == latest:
        if not quiet:
            _log("Already up to date — nothing to do")
        return 0

    _log(f"Update available: {current} → {latest}")

    # 3. Check idle
    if not _is_idle():
        _log("Skipping update — recent activity detected (last request < 1 hour ago)")
        return 0

    # 4. Apply update
    _log("Server idle — applying update")
    try:
        subprocess.run(
            ["npm", "install", "-g", "9router"],
            capture_output=True, text=True, timeout=120, check=True,
        )
    except subprocess.CalledProcessError as exc:
        _log(f"ERROR: npm install failed: {exc.stderr.strip()}")
        return 1

    _log(f"Updated to {latest}")

    # 5. Restart
    if _restart_service():
        _log("Restarted 9router via systemctl")
    else:
        _log("WARNING: could not restart via systemctl — restart 9router manually")

    return 0


if __name__ == "__main__":
    sys.exit(main())
