#!/usr/bin/env python3
from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import json
import os
import sys
import uuid
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional, Tuple


NINE_ROUTER_DB = os.path.expanduser("~/.9router/db.json")
NINE_ROUTER_API = os.environ.get("NINE_ROUTER_API", "http://127.0.0.1:20128").rstrip("/")


def utc_now_iso() -> str:
    return dt.datetime.now(dt.UTC).isoformat().replace("+00:00", "Z")


def read_json(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def write_json(path: str, data: Dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def http_json(url: str, method: str = "GET", headers: Optional[Dict[str, str]] = None, body: Optional[Dict[str, Any]] = None) -> Any:
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url=url, method=method, headers=headers or {}, data=data)
    with urllib.request.urlopen(req, timeout=10) as resp:
        raw = resp.read().decode("utf-8")
    return json.loads(raw) if raw else None


def fetch_models(api_base: str, api_key: Optional[str]) -> List[str]:
    # /api/v1/models requires auth; /api/v1/models is local internal list.
    headers: Dict[str, str] = {}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    try:
        payload = http_json(f"{api_base}/api/v1/models", headers=headers)
        return [m["id"] for m in payload.get("data", []) if isinstance(m, dict) and "id" in m]
    except Exception:
        # Fall back to public-ish endpoint list if auth missing.
        payload = http_json(f"{api_base}/api/v1/models")
        if isinstance(payload, dict) and "data" in payload:
            return [m["id"] for m in payload.get("data", []) if isinstance(m, dict) and "id" in m]
        return []


@dataclasses.dataclass(frozen=True)
class Combo:
    id: str
    name: str
    models: List[str]
    createdAt: str
    updatedAt: str


def ensure_db_shape(db: Dict[str, Any]) -> None:
    db.setdefault("combos", [])
    db.setdefault("modelAliases", {})
    db.setdefault("settings", {})
    settings = db["settings"]
    if not isinstance(settings, dict):
        db["settings"] = {}
        settings = db["settings"]
    settings.setdefault("comboStrategy", "fallback")
    settings.setdefault("comboStrategies", {})


def normalize_strategy(s: str) -> str:
    s = s.strip().lower().replace("_", "-")
    if s in {"fallback", "failover"}:
        return "fallback"
    if s in {"round-robin", "roundrobin", "rr"}:
        return "round-robin"
    raise ValueError("strategy must be 'fallback' or 'round-robin'")


def upsert_combo(db: Dict[str, Any], combo_name: str, models: List[str], strategy: str) -> Combo:
    ensure_db_shape(db)

    now = utc_now_iso()
    combos: List[Dict[str, Any]] = db.get("combos", [])
    existing = next((c for c in combos if c.get("name") == combo_name), None)
    if existing:
        existing["models"] = models
        existing["updatedAt"] = now
        combo_id = existing["id"]
        created_at = existing.get("createdAt") or now
    else:
        combo_id = str(uuid.uuid4())
        created_at = now
        combos.append(
            {
                "id": combo_id,
                "name": combo_name,
                "models": models,
                "createdAt": created_at,
                "updatedAt": now,
            }
        )
        db["combos"] = combos

    # Per-combo strategy (stored in settings.comboStrategies map).
    db["settings"].setdefault("comboStrategies", {})
    db["settings"]["comboStrategies"][combo_id] = strategy

    # Make combo appear as a model id for selection clients.
    # This mirrors how 9router exposes combos as model IDs in /api/v1/models.
    # No modelAliases entry required (combos are first-class), but keeping it empty is fine.

    return Combo(id=combo_id, name=combo_name, models=models, createdAt=created_at, updatedAt=now)


def list_combos(db: Dict[str, Any]) -> List[Combo]:
    ensure_db_shape(db)
    combos: List[Dict[str, Any]] = db.get("combos", [])
    out: List[Combo] = []
    for c in combos:
        out.append(
            Combo(
                id=str(c.get("id", "")),
                name=str(c.get("name", "")),
                models=list(c.get("models", [])),
                createdAt=str(c.get("createdAt", "")),
                updatedAt=str(c.get("updatedAt", "")),
            )
        )
    return out


def delete_combo(db: Dict[str, Any], name: str) -> bool:
    ensure_db_shape(db)
    combos: List[Dict[str, Any]] = db.get("combos", [])
    before = len(combos)
    kept: List[Dict[str, Any]] = [c for c in combos if c.get("name") != name]
    if len(kept) == before:
        return False
    removed = [c for c in combos if c.get("name") == name]
    db["combos"] = kept

    # Remove per-combo strategy entries for deleted combos.
    strategies = db.get("settings", {}).get("comboStrategies", {})
    if isinstance(strategies, dict):
        for c in removed:
            cid = c.get("id")
            if cid in strategies:
                del strategies[cid]
    return True


def parse_models_arg(models_arg: str) -> List[str]:
    models = [m.strip() for m in models_arg.split(",") if m.strip()]
    if len(models) < 2:
        raise ValueError("provide at least 2 models for a combo")
    return models


def get_active_api_key_from_db(db: Dict[str, Any]) -> Optional[str]:
    keys = db.get("apiKeys", [])
    if not isinstance(keys, list):
        return None
    active = next((k for k in keys if isinstance(k, dict) and k.get("isActive") is True), None)
    if not active:
        active = next((k for k in keys if isinstance(k, dict)), None)
    if not active:
        return None
    return active.get("key")


def cmd_models(args: argparse.Namespace) -> int:
    if not os.path.exists(NINE_ROUTER_DB):
        print(f"Missing {NINE_ROUTER_DB}", file=sys.stderr)
        return 1
    db = read_json(NINE_ROUTER_DB)
    api_key = args.api_key or get_active_api_key_from_db(db)
    models = fetch_models(args.api or NINE_ROUTER_API, api_key)
    for m in models:
        print(m)
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    if not os.path.exists(NINE_ROUTER_DB):
        print(f"Missing {NINE_ROUTER_DB}", file=sys.stderr)
        return 1
    db = read_json(NINE_ROUTER_DB)
    combos = list_combos(db)
    if not combos:
        print("No combos configured.")
        return 0
    strategies = db.get("settings", {}).get("comboStrategies", {}) or {}
    for c in combos:
        strat = strategies.get(c.id, db.get("settings", {}).get("comboStrategy", "fallback"))
        print(f"{c.name}\t{strat}\t{','.join(c.models)}")
    return 0


def cmd_create(args: argparse.Namespace) -> int:
    if not os.path.exists(NINE_ROUTER_DB):
        print(f"Missing {NINE_ROUTER_DB}", file=sys.stderr)
        return 1
    db = read_json(NINE_ROUTER_DB)

    strategy = normalize_strategy(args.strategy)
    models = parse_models_arg(args.models)

    # Optional validation: ensure model ids exist in current router inventory.
    if args.validate:
        api_key = args.api_key or get_active_api_key_from_db(db)
        known = set(fetch_models(args.api or NINE_ROUTER_API, api_key))
        missing = [m for m in models if m not in known]
        if missing:
            print("Unknown model ids (not in /api/v1/models):", file=sys.stderr)
            for m in missing:
                print(f"- {m}", file=sys.stderr)
            return 2

    combo = upsert_combo(db, combo_name=args.name, models=models, strategy=strategy)
    write_json(NINE_ROUTER_DB, db)

    print(f"Created combo: {combo.name}")
    print(f"- id: {combo.id}")
    print(f"- strategy: {strategy}")
    print(f"- models: {', '.join(combo.models)}")
    print()
    print("Use this virtual model id in clients:")
    print(f"- model: {combo.name}")
    return 0


def cmd_delete(args: argparse.Namespace) -> int:
    if not os.path.exists(NINE_ROUTER_DB):
        print(f"Missing {NINE_ROUTER_DB}", file=sys.stderr)
        return 1
    db = read_json(NINE_ROUTER_DB)
    ok = delete_combo(db, args.name)
    if not ok:
        print(f"Combo not found: {args.name}", file=sys.stderr)
        return 2
    write_json(NINE_ROUTER_DB, db)
    print(f"Deleted combo: {args.name}")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description="Manage 9router model combos (virtual models with fallback/round-robin).")
    p.add_argument("--api", default=NINE_ROUTER_API, help="9router base URL (default: http://127.0.0.1:20128)")
    p.add_argument("--api-key", default=None, help="9router API key (defaults to active key in ~/.9router/db.json)")

    sub = p.add_subparsers(dest="cmd", required=True)

    sp_models = sub.add_parser("models", help="List available model ids from 9router.")
    sp_models.set_defaults(func=cmd_models)

    sp_list = sub.add_parser("list", help="List configured combos.")
    sp_list.set_defaults(func=cmd_list)

    sp_create = sub.add_parser("create", help="Create or update a combo.")
    sp_create.add_argument("--name", required=True, help="Virtual model name (example: opus-4-6)")
    sp_create.add_argument(
        "--models",
        required=True,
        help="Comma-separated model ids in priority order (example: cc/claude-opus-4-6,gh/claude-opus-4.5)",
    )
    sp_create.add_argument("--strategy", default="fallback", help="fallback or round-robin (default: fallback)")
    sp_create.add_argument("--validate", action="store_true", help="Validate model ids exist in /api/v1/models")
    sp_create.set_defaults(func=cmd_create)

    sp_delete = sub.add_parser("delete", help="Delete a combo by name.")
    sp_delete.add_argument("--name", required=True, help="Combo name to delete")
    sp_delete.set_defaults(func=cmd_delete)

    args = p.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())

