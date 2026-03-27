#!/usr/bin/env python3
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from typing import Dict, List, Optional


NINE_ROUTER_STATE = os.path.expanduser("~/.9router/tunnel/state.json")
CLAUDE_SETTINGS = os.path.expanduser("~/.claude/settings.json")
LOCAL_ROUTER_BASE = "http://127.0.0.1:20128"


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


def read_json_file(path: str) -> Dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def write_json_file(path: str, data: Dict) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def extract_tunnel_url() -> str:
    state = read_json_file(NINE_ROUTER_STATE)
    tunnel_url = state.get("tunnelUrl", "").strip()
    if not tunnel_url:
        raise RuntimeError(f"No tunnelUrl found in {NINE_ROUTER_STATE}")
    return tunnel_url.rstrip("/")


def request_json(
    url: str,
    method: str = "GET",
    headers: Optional[Dict[str, str]] = None,
    body: Optional[Dict] = None,
) -> Dict:
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url=url, method=method, headers=headers or {}, data=data)
    with urllib.request.urlopen(req, timeout=12) as resp:
        payload = resp.read().decode("utf-8")
    return json.loads(payload) if payload else {}


def model_works(api_key: str, model: str) -> bool:
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    body = {
        "model": model,
        "max_tokens": 32,
        "stream": False,
        "messages": [{"role": "user", "content": "ping"}],
    }
    try:
        request_json(f"{LOCAL_ROUTER_BASE}/v1/messages", method="POST", headers=headers, body=body)
        return True
    except urllib.error.HTTPError:
        return False
    except Exception:
        return False


def pick_working_model(api_key: str, candidates: List[str], current: str) -> str:
    if current and model_works(api_key, current):
        return current
    for candidate in candidates:
        if model_works(api_key, candidate):
            return candidate
    return current


def sync_once(verbose: bool = True) -> int:
    if not os.path.exists(NINE_ROUTER_STATE):
        print(f"Missing {NINE_ROUTER_STATE}", file=sys.stderr)
        return 1
    if not os.path.exists(CLAUDE_SETTINGS):
        print(f"Missing {CLAUDE_SETTINGS}", file=sys.stderr)
        return 1

    settings = read_json_file(CLAUDE_SETTINGS)
    env = settings.setdefault("env", {})

    tunnel_url = extract_tunnel_url()
    desired_base = f"{tunnel_url}/v1"
    old_base = env.get("ANTHROPIC_BASE_URL", "")
    changed = False

    if old_base != desired_base:
        env["ANTHROPIC_BASE_URL"] = desired_base
        changed = True
        if verbose:
            print(f"Updated ANTHROPIC_BASE_URL: {old_base} -> {desired_base}")

    api_key = env.get("ANTHROPIC_AUTH_TOKEN", "").strip()
    if not api_key:
        print("ANTHROPIC_AUTH_TOKEN missing in ~/.claude/settings.json", file=sys.stderr)
    else:
        for env_key, candidates in MODEL_CANDIDATES.items():
            current = env.get(env_key, "")
            chosen = pick_working_model(api_key, candidates, current)
            if chosen and chosen != current:
                env[env_key] = chosen
                changed = True
                if verbose:
                    print(f"Updated {env_key}: {current} -> {chosen}")

    if changed:
        write_json_file(CLAUDE_SETTINGS, settings)
        if verbose:
            print("Saved ~/.claude/settings.json")
    else:
        if verbose:
            print("No changes needed")

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Sync Claude settings with current 9router tunnel and working model aliases."
    )
    parser.add_argument(
        "--watch",
        action="store_true",
        help="Run forever and sync every interval seconds.",
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

    if not args.watch:
        return sync_once(verbose=not args.quiet)

    while True:
        rc = sync_once(verbose=not args.quiet)
        if rc != 0:
            return rc
        time.sleep(max(5, args.interval))


if __name__ == "__main__":
    sys.exit(main())

