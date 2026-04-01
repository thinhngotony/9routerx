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

# Fallback candidates when live model discovery fails or 9router is unreachable.
# These are probed in order; first working model wins.
STATIC_MODEL_CANDIDATES = {
    "ANTHROPIC_DEFAULT_SONNET_MODEL": [
        "gh/claude-sonnet-4.6",
        "cc/claude-sonnet-4-6",
        "gh/claude-sonnet-4.5",
        "cc/claude-sonnet-4-5-20250929",
    ],
    "ANTHROPIC_DEFAULT_OPUS_MODEL": [
        "gh/claude-opus-4.6",
        "cc/claude-opus-4-6",
        "gh/claude-opus-4.5",
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


def _extract_version(model_id: str) -> tuple:
    """
    Extract version tuple from model ID for sorting.
    Examples:
      cc/claude-sonnet-4-6       → (4, 6, 0)
      gh/claude-sonnet-4.7       → (4, 7, 0)
      cc/claude-haiku-4-5-20251001 → (4, 5, 20251001)
    Returns (0, 0, 0) if no version pattern found.
    """
    import re
    match = re.search(r"(\d+)[.-](\d+)(?:[.-](\d+))?", model_id)
    if not match:
        return (0, 0, 0)
    major = int(match.group(1))
    minor = int(match.group(2))
    patch = int(match.group(3)) if match.group(3) else 0
    return (major, minor, patch)


def fetch_combos(router_base: str, api_key: str = "") -> List[Dict]:
    """
    Fetch all combos currently configured on the 9router server.
    Returns a list of combo dicts: {id, name, models, strategy}.
    Falls back to reading the local db.json if the API call fails.
    """
    headers: Dict[str, str] = {}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    try:
        data = request_json(f"{router_base}/api/combos", headers=headers, timeout=8)
        combos = data if isinstance(data, list) else data.get("combos", [])
        return [c for c in combos if isinstance(c, dict) and c.get("name")]
    except Exception:
        pass
    # Fallback: read local db directly
    db_path = os.path.expanduser("~/.9router/db.json")
    if os.path.exists(db_path):
        try:
            db = read_json_file(db_path)
            strategies = db.get("settings", {}).get("comboStrategies", {})
            out = []
            for c in db.get("combos", []):
                if c.get("name"):
                    c["strategy"] = strategies.get(c.get("id", ""), "fallback")
                    out.append(c)
            return out
        except Exception:
            pass
    return []


def _tier_of(model_id: str) -> str:
    """Return 'sonnet', 'opus', 'haiku', or '' for a model/combo name."""
    m = model_id.lower()
    if "sonnet" in m:
        return "sonnet"
    if "opus" in m:
        return "opus"
    if "haiku" in m:
        return "haiku"
    return ""


def _combos_by_tier(combos: List[Dict]) -> Dict[str, List[str]]:
    """
    Group combo names by the tier most of their member models belong to.
    A combo whose name contains sonnet/opus/haiku is assigned to that tier.
    Unclassified combos are offered as candidates for all three tiers (as
    generic fallbacks) so they still get picked up when no tier-specific
    combo exists.
    """
    by_tier: Dict[str, List[str]] = {"sonnet": [], "opus": [], "haiku": [], "_unclassified": []}
    for c in combos:
        name = c.get("name", "")
        tier = _tier_of(name)
        if tier:
            by_tier[tier].append(name)
        else:
            # Inspect member models for a majority tier
            member_tiers = [_tier_of(m) for m in c.get("models", [])]
            counts = {t: member_tiers.count(t) for t in ("sonnet", "opus", "haiku")}
            best = max(counts, key=lambda t: counts[t])
            if counts[best] > 0:
                by_tier[best].append(name)
            else:
                by_tier["_unclassified"].append(name)
    return by_tier


def discover_model_candidates(
    router_base: str,
    api_key: str = "",
    use_combos: bool = False,
) -> Dict[str, List[str]]:
    """
    Query 9router for candidate model IDs.

    When use_combos=True, we fetch server combos and prefer combo names first.
    Otherwise we use raw provider model candidates (legacy behavior) and static
    fallbacks.
    """
    combos: List[Dict] = []
    combo_by_tier: Dict[str, List[str]] = {}
    unclassified: List[str] = []

    if use_combos:
        combos = fetch_combos(router_base, api_key)
        combo_by_tier = _combos_by_tier(combos) if combos else {}
        unclassified = combo_by_tier.get("_unclassified", []) if combo_by_tier else []

    try:
        data = request_json(f"{router_base}/api/providers", timeout=8)
        connections = data.get("connections", [])

        all_models = set()
        for conn in connections:
            if not conn.get("isActive"):
                continue
            provider = conn.get("provider", "")
            # Extract models from testStatus or provider-specific data
            # For now, construct provider/model-id from known patterns.
            # 9router exposes available models via provider connections.
            # We build synthetic model IDs: <provider-prefix>/claude-<tier>-<version>
            prefix_map = {
                "cursor": "cc",
                "github": "gh",
                "claude": "cc",  # claude provider → cc prefix
                "antigravity": "ag",
            }
            prefix = prefix_map.get(provider, provider[:2])

            # Heuristic: assume each active connection supports the standard
            # Claude model tiers. In practice, 9router's model registry should
            # expose this explicitly; for now we probe known patterns.
            # This is a transitional implementation — ideally 9router would
            # return a /api/models endpoint listing all <provider>/<model-id>.
            base_models = [
                f"{prefix}/claude-sonnet-4-6",
                f"{prefix}/claude-sonnet-4.7",
                f"{prefix}/claude-opus-4-6",
                f"{prefix}/claude-opus-4.7",
                f"{prefix}/claude-haiku-4-5-20251001",
            ]
            all_models.update(base_models)

        # Partition by tier
        sonnet = sorted(
            [m for m in all_models if "sonnet" in m.lower()],
            key=_extract_version,
            reverse=True,
        )
        opus = sorted(
            [m for m in all_models if "opus" in m.lower()],
            key=_extract_version,
            reverse=True,
        )
        haiku = sorted(
            [m for m in all_models if "haiku" in m.lower()],
            key=_extract_version,
            reverse=True,
        )

        def _prepend_combos(tier: str, raw: List[str]) -> List[str]:
            tier_combos = combo_by_tier.get(tier, []) + unclassified if combo_by_tier else []
            # Deduplicate while preserving order (combos first)
            seen: set = set()
            out = []
            for m in tier_combos + raw:
                if m not in seen:
                    seen.add(m)
                    out.append(m)
            return out

        discovered = {
            "ANTHROPIC_DEFAULT_SONNET_MODEL": _prepend_combos("sonnet", sonnet) if sonnet or combo_by_tier.get("sonnet") else STATIC_MODEL_CANDIDATES["ANTHROPIC_DEFAULT_SONNET_MODEL"],
            "ANTHROPIC_DEFAULT_OPUS_MODEL": _prepend_combos("opus", opus) if opus or combo_by_tier.get("opus") else STATIC_MODEL_CANDIDATES["ANTHROPIC_DEFAULT_OPUS_MODEL"],
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": _prepend_combos("haiku", haiku) if haiku or combo_by_tier.get("haiku") else STATIC_MODEL_CANDIDATES["ANTHROPIC_DEFAULT_HAIKU_MODEL"],
        }
        return discovered
    except Exception:
        # Network error, 9router down, or API schema change — fall back
        # Still prepend any locally-fetched combos so they are not lost.
        if combo_by_tier:
            def _prepend_static(tier: str, key: str) -> List[str]:
                tier_combos = combo_by_tier.get(tier, []) + unclassified
                seen: set = set()
                out = []
                for m in tier_combos + STATIC_MODEL_CANDIDATES[key]:
                    if m not in seen:
                        seen.add(m)
                        out.append(m)
                return out
            return {
                "ANTHROPIC_DEFAULT_SONNET_MODEL": _prepend_static("sonnet", "ANTHROPIC_DEFAULT_SONNET_MODEL"),
                "ANTHROPIC_DEFAULT_OPUS_MODEL": _prepend_static("opus", "ANTHROPIC_DEFAULT_OPUS_MODEL"),
                "ANTHROPIC_DEFAULT_HAIKU_MODEL": _prepend_static("haiku", "ANTHROPIC_DEFAULT_HAIKU_MODEL"),
            }
        return STATIC_MODEL_CANDIDATES


# ── Sync: Claude Code ──────────────────────────────────────────────────────────

def sync_claude_code(router_base: str, use_combos: bool, verbose: bool) -> bool:
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

    # Auto-discover available models from 9router (combos first, then raw
    # provider models, then static fallback).
    model_candidates = discover_model_candidates(router_base, api_key, use_combos=use_combos)

    # Log which combos were found on the server
    if verbose:
        combos = fetch_combos(router_base, api_key)
        if combos:
            names = ", ".join(c.get("name", "") for c in combos)
            print(f"Server combos: {names}")
        else:
            print("Server combos: none configured")

    for env_key, candidates in model_candidates.items():
        current = env.get(env_key, "")
        chosen = pick_working_model(router_base, candidates, current, api_key)
        if chosen and chosen != current:
            env[env_key] = chosen
            changed = True
            if verbose:
                src = "combo" if not any(c in chosen for c in ["/", "-"]) else "model"
                print(f"Claude Code  {env_key}: {current!r} → {chosen!r}  [{src}]")

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
    use_combos: bool,
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
    changed |= sync_claude_code(router_base, use_combos, verbose)

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
        "--use-combos",
        action="store_true",
        help="Prefer server combos when choosing ANTHROPIC_DEFAULT_*_MODEL (opt-in).",
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
            use_combos=args.use_combos,
            shell_profiles=args.shell_profiles,
            verbose=verbose,
        )

    while True:
        rc = sync_once(
            router_url=args.router_url,
            sync_cursor=args.sync_cursor,
            sync_shell=args.sync_shell,
            use_combos=args.use_combos,
            shell_profiles=args.shell_profiles,
            verbose=verbose,
        )
        if rc != 0:
            return rc
        time.sleep(max(5, args.interval))


if __name__ == "__main__":
    sys.exit(main())
