#!/usr/bin/env python3
"""Ensure an internal TestFlight group with automatic build distribution
is set up for Spendcap, and that the account holder is a member.

Idempotent. Re-running:
  - reuses an existing internal group if one is already set up for the app
  - flips `hasAccessToAllBuilds` to true if it isn't already
  - adds the account holder as a tester if they aren't already

Why this script exists:
  Internal-tester TestFlight builds become available without a review
  step — but only if the group has "automatic distribution" turned on.
  Otherwise each new build has to be manually added to the group via
  the ASC UI. Turning on hasAccessToAllBuilds removes that step.

Usage:
    python3 scripts/configure_internal_testers.py
"""
from __future__ import annotations

import os
import pathlib
import sys
import time

import jwt
import requests


CONFIG_PATH = pathlib.Path(__file__).resolve().parent / "asc-config.env"
API_BASE = "https://api.appstoreconnect.apple.com/v1"
GROUP_NAME = "Internal Testers"


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        raise SystemExit(f"missing {CONFIG_PATH}")
    cfg: dict = {}
    for line in CONFIG_PATH.read_text().splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        k, _, v = s.partition("=")
        v = os.path.expandvars(v.strip().strip('"').strip("'"))
        cfg[k.strip()] = v
    return cfg


def make_token(cfg: dict) -> str:
    key_path = pathlib.Path(cfg["ASC_KEY_PATH"]).expanduser()
    private_key = key_path.read_text()
    now = int(time.time())
    payload = {
        "iss": cfg["ASC_ISSUER_ID"],
        "iat": now,
        "exp": now + 15 * 60,
        "aud": "appstoreconnect-v1",
    }
    headers = {"kid": cfg["ASC_KEY_ID"], "typ": "JWT"}
    return jwt.encode(payload, private_key, algorithm="ES256", headers=headers)


def api(token: str, method: str, path: str, params=None, body=None, ok=(200, 201, 204)) -> dict:
    r = requests.request(
        method,
        f"{API_BASE}{path}",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        params=params or {},
        json=body,
        timeout=30,
    )
    if r.status_code not in ok:
        raise SystemExit(f"{method} {path} -> {r.status_code}\n{r.text}")
    return r.json() if r.text else {}


def list_internal_groups(token: str, app_id: str) -> list[dict]:
    res = api(token, "GET", f"/apps/{app_id}/betaGroups", params={"limit": 200})
    groups = res.get("data", [])
    return [g for g in groups if g.get("attributes", {}).get("isInternalGroup")]


def create_internal_group(token: str, app_id: str, name: str) -> dict:
    body = {
        "data": {
            "type": "betaGroups",
            "attributes": {
                "name": name,
                "isInternalGroup": True,
                "hasAccessToAllBuilds": True,
                "publicLinkEnabled": False,
            },
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        }
    }
    res = api(token, "POST", "/betaGroups", body=body)
    return res["data"]


def set_access_to_all_builds(token: str, group_id: str, enabled: bool) -> None:
    body = {
        "data": {
            "id": group_id,
            "type": "betaGroups",
            "attributes": {"hasAccessToAllBuilds": enabled},
        }
    }
    api(token, "PATCH", f"/betaGroups/{group_id}", body=body)


def find_user(token: str, email: str) -> dict | None:
    res = api(token, "GET", "/users", params={"filter[username]": email, "limit": 1})
    data = res.get("data", [])
    return data[0] if data else None


def list_group_user_ids(token: str, group_id: str) -> set[str]:
    """Return the ASC user IDs already linked to this internal beta group."""
    res = api(token, "GET", f"/betaGroups/{group_id}/relationships/betaTesters", params={"limit": 200}, ok=(200, 204))
    return {entry["id"] for entry in res.get("data", [])}


def list_users_with_app_access(token: str, app_id: str) -> list[dict]:
    """All ASC users who have visibility to the app — these are the
    candidate internal testers."""
    res = api(token, "GET", "/users", params={"limit": 200})
    return [
        u for u in res.get("data", [])
        if any(
            entry.get("id") == app_id
            for entry in (u.get("relationships", {}).get("visibleApps", {}).get("data") or [])
        )
        or u.get("attributes", {}).get("allAppsVisible")
    ]


def main() -> None:
    cfg = load_config()
    app_id = cfg.get("ASC_APP_ID")
    if not app_id:
        raise SystemExit("ASC_APP_ID missing — run scripts/register_in_asc.py first")
    tester_email = "divinejdavis@gmail.com"

    token = make_token(cfg)

    print(f"==> looking up internal beta groups for app {app_id}")
    groups = list_internal_groups(token, app_id)
    if groups:
        group = groups[0]
        group_id = group["id"]
        print(f"   reusing existing internal group '{group['attributes']['name']}' ({group_id})")
        if not group["attributes"].get("hasAccessToAllBuilds"):
            print(f"   enabling automatic build distribution")
            set_access_to_all_builds(token, group_id, True)
        else:
            print(f"   automatic build distribution already on")
    else:
        print(f"==> creating internal group '{GROUP_NAME}' with automatic distribution")
        group = create_internal_group(token, app_id, GROUP_NAME)
        group_id = group["id"]
        print(f"   created group ({group_id})")

    print(f"==> verifying {tester_email} can access internal builds for the app")
    user = find_user(token, tester_email)
    if not user:
        print(f"   warning: no ASC user found with username {tester_email}")
    else:
        attrs = user.get("attributes", {})
        all_visible = attrs.get("allAppsVisible", False)
        visible_app_ids = {
            e.get("id") for e in (user.get("relationships", {}).get("visibleApps", {}).get("data") or [])
        }
        if all_visible or app_id in visible_app_ids:
            print(f"   {tester_email} has access to this app via their ASC role ({attrs.get('roles')})")
        else:
            print(f"   warning: {tester_email} is an ASC user but does not have this app visible — add it under ASC → Users and Access")

    candidates = list_users_with_app_access(token, app_id)
    print(f"==> {len(candidates)} ASC user(s) can see app {app_id} and are eligible internal testers:")
    for u in candidates:
        a = u.get("attributes", {})
        print(f"   - {a.get('username')} ({', '.join(a.get('roles') or [])})")

    print(f"==> done. New builds for app {app_id} will be auto-distributed to internal group {group_id} ('{group['attributes'].get('name')}').")


if __name__ == "__main__":
    main()
