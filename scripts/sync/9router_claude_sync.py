#!/usr/bin/env python3
"""
9router_claude_sync.py

Syncs local AI tool configuration with the active 9router instance.

Sync targets:
  Claude Code   ~/.claude/settings.json    env.ANTHROPIC_BASE_URL
  Cursor        <Cursor settings.json>     openai.baseUrl
  Shell profile ~/.bashrc, ~/.zshrc        export ANTHROPIC_BASE_URL

Usage:
  # Local mode — reads active tunnel URL from ~/.9router/tunnel/state.json
  python3 9router_claude_sync.py

  # Remote VPS mode — queries 9router API directly, resolves tunnel URL if active
  python3 9router_claude_sync.py --router-url http://42.96.13.174:20128

  # Sync all targets
  python3 9router_claude_sync.py --router-url http://IP:20128 --sync-cursor --sync-shell

  # Watch mode — re-sync every N seconds
  python3 9router_claude_sync.py --router-url http://IP:20128 --sync-cursor --sync-shell --watch
"""

import argparse
import json
import os
import platform
import sys
import time
import urllib.error
import urllib.request
from typing import Dict, List, Optional


# ── Paths ─────────────────────────────────────────────────────────────────────

NINE_ROUTER_STATE  = os.path.expanduser("~/.9router/tunnel/state.json")
CLAUDE_SETTINGS    = os.path.expanduser("~/.claude/settings.json")
SHELL_MARKER       = "# managed by 9routerx"

CURSOR_SETTINGS_CANDIDATES = [
    os.path.expanduser("~/Library/Application Support/Cursor/User/settings.json"),
    os.path.expanduser("~/.config/Cursor/User/settings.json"),
    os.path.expanduser("~/.config/cursor/User/settings.json"),
]

SHELL_PROFILE_CANDIDATES = [
    os.path.expanduser("~/.bashrc"),
    os.path.expanduser("~/.zshrc"),
    os.path.expanduser("~/.bash_profile"),
    os.path.expanduser("~/.profile"),
]

# ── Model alias candidates ─────────────────────────────────────────────────────

MODEL_CANDIDATES = {
    "ANTHROPIC_DEFAULT_SONNET_MODEL": [
        "gh/claude-sonnet-4.5",
        "gh/claude-sonnet-4.6",
        "cc/claude-sonnet-4-6",
        "cc/claude-sonnet-4-5-20250929",
    ],
    "ANTHROPIC_DEFAULT_OPUS_MODEL": [
        "gh/claude-opus-4.5",
        "gh/claude-opus-4.6",
        "cc/claude-opus-4-6",
    ],
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": [
        "gh/claude-haiku-4.5",
        "cc/claude-haiku-4-5-20251001",
    ],
}


# ── JSON helpers ───────────────────────────────────────────────────────────────

def read_json_file(path: str) -> Dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def write_json_file(path: str, data: Dict) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


# ── HTTP helper ────────────────────────────────────────────────────────────────

def request_json(
    url: str,
    method: str = "GET",
    headers: Optional[Dict[str, str]] = None,
    body: Optional[Dict] = None,
    timeout: int = 12,
) -> Dict:
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url=url, method=method, headers=headers or {}, data=data
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        payload = resp.read().decode("utf-8")
    return json.loads(payload) if payload else {}


# ── URL resolution ─────────────────────────────────────────────────────────────

def _extract_local_tunnel_url() -> str:
    """Read active tunnel URL from the local 9router state file."""
    if not os.path.exists(NINE_ROUTER_STATE):
        raise RuntimeError(f"State file not found: {NINE_ROUTER_STATE}")
    state = read_json_file(NINE_ROUTER_STATE)
    url = state.get("tunnelUrl", "").strip().rstrip("/")
    if not url:
        raise RuntimeError(f"No tunnelUrl in {NINE_ROUTER_STATE}")
    return url


def get_effective_base_url(router_url: Optional[str]) -> str:
    """
    Return the 9router base URL to use (without /v1).

    - router_url given  → query remote 9router /api/settings for active tunnel URL;
                          fall back to the direct URL if tunnel is inactive.
    - router_url absent → read local ~/.9router/tunnel/state.json (legacy behaviour).
    """
    if router_url:
        base = router_url.rstrip("/")
        try:
            data = request_json(f"{base}/api/settings", timeout=8)
            tunnel_url = data.get("tunnelUrl", "").strip().rstrip("/")
            if data.get("tunnelEnabled") and tunnel_url:
                return tunnel_url
        except Exception:
            pass
        return base
    else:
        return _extract_local_tunnel_url()


# ── Model probe ────────────────────────────────────────────────────────────────

def _model_works(router_base: str, model: str, api_key: str = "") -> bool:
    """
    Probe whether `model` is reachable via the 9router proxy.

    9router does not enforce authentication — it acts as a local proxy and
    accepts any non-empty Bearer token.  We use the caller-supplied key when
    available, and fall back to a sentinel value so the HTTP header is always
    well-formed.  This means model probing works correctly even before the
    user has set ANTHROPIC_AUTH_TOKEN.
    """
    token = api_key.strip() or "9router"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    body = {
        "model": model,
        "max_tokens": 32,
        "stream": False,
        "messages": [{"role": "user", "content": "ping"}],
    }
    try:
        request_json(
            f"{router_base}/v1/messages",
            method="POST",
            headers=headers,
            body=body,
            timeout=10,
        )
        return True
    except Exception:
        return False


def pick_working_model(
    router_base: str, candidates: List[str], current: str, api_key: str = ""
) -> str:
    if current and _model_works(router_base, current, api_key):
        return current
    for candidate in candidates:
        if _model_works(router_base, candidate, api_key):
            return candidate
    return current


# ── Sync: Claude Code ──────────────────────────────────────────────────────────

def sync_claude_code(router_base: str, verbose: bool) -> bool:
    """
    Update ~/.claude/settings.json:
      env.ANTHROPIC_BASE_URL → <router_base>/v1
      env.ANTHROPIC_DEFAULT_*_MODEL → first working model alias
    Returns True if the file was modified.
    """
    if not os.path.exists(CLAUDE_SETTINGS):
        if verbose:
            print(f"Claude Code settings not found: {CLAUDE_SETTINGS}", file=sys.stderr)
        return False

    settings = read_json_file(CLAUDE_SETTINGS)
    env = settings.setdefault("env", {})
    changed = False

    desired_base_url = f"{router_base}/v1"
    if env.get("ANTHROPIC_BASE_URL") != desired_base_url:
        old = env.get("ANTHROPIC_BASE_URL", "(unset)")
        env["ANTHROPIC_BASE_URL"] = desired_base_url
        changed = True
        if verbose:
            print(f"Claude Code  ANTHROPIC_BASE_URL: {old!r} → {desired_base_url!r}")

    # Use the stored token if present; the proxy accepts any non-empty value so
    # model probing works even on a fresh install before the user sets a token.
    api_key = env.get("ANTHROPIC_AUTH_TOKEN", "").strip()

    for env_key, candidates in MODEL_CANDIDATES.items():
        current = env.get(env_key, "")
        chosen = pick_working_model(router_base, candidates, current, api_key)
        if chosen and chosen != current:
            env[env_key] = chosen
            changed = True
            if verbose:
                print(f"Claude Code  {env_key}: {current!r} → {chosen!r}")

    if changed:
        write_json_file(CLAUDE_SETTINGS, settings)
        if verbose:
            print(f"Saved {CLAUDE_SETTINGS}")
    elif verbose:
        print("Claude Code: no changes needed")

    return changed


# ── Sync: Cursor ───────────────────────────────────────────────────────────────

def _find_cursor_settings() -> Optional[str]:
    for path in CURSOR_SETTINGS_CANDIDATES:
        if os.path.exists(path):
            return path
    # Not found — return preferred platform default (will be created)
    return (
        CURSOR_SETTINGS_CANDIDATES[0]  # macOS
        if platform.system() == "Darwin"
        else CURSOR_SETTINGS_CANDIDATES[1]  # Linux
    )


def sync_cursor_settings(router_base: str, verbose: bool) -> bool:
    """
    Update Cursor's settings.json:
      openai.baseUrl → <router_base>/v1
    Returns True if the file was modified.
    """
    path = _find_cursor_settings()
    if path is None:
        if verbose:
            print("Cursor settings.json not found — skipping", file=sys.stderr)
        return False

    os.makedirs(os.path.dirname(path), exist_ok=True)

    settings: Dict = {}
    if os.path.exists(path):
        try:
            settings = read_json_file(path)
        except Exception:
            settings = {}

    desired = f"{router_base}/v1"
    if settings.get("openai.baseUrl") == desired:
        if verbose:
            print("Cursor: no changes needed")
        return False

    old = settings.get("openai.baseUrl", "(unset)")
    settings["openai.baseUrl"] = desired
    write_json_file(path, settings)
    if verbose:
        print(f"Cursor  openai.baseUrl: {old!r} → {desired!r}")
        print(f"Saved {path}")
    return True


# ── Sync: shell profiles ───────────────────────────────────────────────────────

def _update_shell_profile(path: str, router_base: str, verbose: bool) -> bool:
    """
    Write / update `export ANTHROPIC_BASE_URL=...` in one shell profile.
    Uses a marker comment for idempotent updates.
    Returns True if the file was modified.
    """
    export_line = f'export ANTHROPIC_BASE_URL="{router_base}/v1"  {SHELL_MARKER}'

    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    for i, line in enumerate(lines):
        if SHELL_MARKER in line and "ANTHROPIC_BASE_URL" in line:
            if line.rstrip("\n") == export_line:
                return False  # already correct
            lines[i] = export_line + "\n"
            with open(path, "w", encoding="utf-8") as f:
                f.writelines(lines)
            if verbose:
                print(f"Shell profile updated: {path}")
            return True

    # Marker not found — append
    with open(path, "a", encoding="utf-8") as f:
        f.write(f"\n{export_line}\n")
    if verbose:
        print(f"Shell profile updated: {path}")
    return True


def sync_shell_profiles(
    router_base: str,
    profiles: Optional[List[str]],
    verbose: bool,
) -> bool:
    """
    Update ANTHROPIC_BASE_URL export in shell profile(s).
    Falls back to auto-detected profiles when `profiles` is None or empty.
    Returns True if any file was modified.
    """
    targets = profiles if profiles else [
        p for p in SHELL_PROFILE_CANDIDATES if os.path.isfile(p)
    ]
    if not targets:
        if verbose:
            print("No shell profiles found — skipping")
        return False

    changed = False
    for path in targets:
        changed |= _update_shell_profile(path, router_base, verbose)
    if not changed and verbose:
        print("Shell profiles: no changes needed")
    return changed


# ── Orchestration ──────────────────────────────────────────────────────────────

def sync_once(
    router_url: Optional[str],
    sync_cursor: bool,
    sync_shell: bool,
    shell_profiles: Optional[List[str]],
    verbose: bool,
) -> int:
    try:
        router_base = get_effective_base_url(router_url)
    except RuntimeError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    if verbose:
        print(f"9router base URL: {router_base}")

    changed = False
    changed |= sync_claude_code(router_base, verbose)

    if sync_cursor:
        changed |= sync_cursor_settings(router_base, verbose)

    if sync_shell:
        changed |= sync_shell_profiles(router_base, shell_profiles, verbose)

    if not changed and verbose:
        print("All targets up to date — no changes made")

    return 0


# ── CLI ────────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Sync Claude Code, Cursor, and shell profile with the active 9router instance."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Local mode (reads ~/.9router/tunnel/state.json)
  python3 9router_claude_sync.py

  # Remote VPS — resolves tunnel URL automatically
  python3 9router_claude_sync.py --router-url http://42.96.13.174:20128

  # Sync all targets
  python3 9router_claude_sync.py --router-url http://IP:20128 --sync-cursor --sync-shell

  # Watch mode — keep syncing every 30 s
  python3 9router_claude_sync.py --router-url http://IP:20128 --sync-cursor --sync-shell --watch
""",
    )

    parser.add_argument(
        "--router-url",
        metavar="URL",
        default=None,
        help="9router base URL (e.g. http://42.96.13.174:20128). "
             "When omitted, reads from ~/.9router/tunnel/state.json.",
    )
    parser.add_argument(
        "--sync-cursor",
        action="store_true",
        help="Also update Cursor settings.json (openai.baseUrl).",
    )
    parser.add_argument(
        "--sync-shell",
        action="store_true",
        help="Also update shell profiles (~/.bashrc, ~/.zshrc) with ANTHROPIC_BASE_URL.",
    )
    parser.add_argument(
        "--shell-profile",
        metavar="PATH",
        action="append",
        dest="shell_profiles",
        default=None,
        help="Shell profile to update (repeatable). Defaults to ~/.bashrc and ~/.zshrc.",
    )
    parser.add_argument(
        "--watch",
        action="store_true",
        help="Run continuously, re-syncing every --interval seconds.",
    )
    parser.add_argument(
        "--interval",
        type=int,
        default=30,
        help="Watch interval in seconds (default: 30).",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress non-error output.",
    )

    args = parser.parse_args()
    verbose = not args.quiet

    if not args.watch:
        return sync_once(
            router_url=args.router_url,
            sync_cursor=args.sync_cursor,
            sync_shell=args.sync_shell,
            shell_profiles=args.shell_profiles,
            verbose=verbose,
        )

    while True:
        rc = sync_once(
            router_url=args.router_url,
            sync_cursor=args.sync_cursor,
            sync_shell=args.sync_shell,
            shell_profiles=args.shell_profiles,
            verbose=verbose,
        )
        if rc != 0:
            return rc
        time.sleep(max(5, args.interval))


if __name__ == "__main__":
    sys.exit(main())
