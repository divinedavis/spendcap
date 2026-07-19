#!/usr/bin/env python3
"""Register the Spendcap bundle ID, enable Push Notifications, and create the
App Store Connect app record — all via the ASC API.

Idempotent. Re-run safely; each step looks up the existing resource before
creating. Reads credentials from scripts/asc-config.env and writes the
resulting ASC app id back to the same file.

App Store names are globally unique, so app creation walks NAME_CANDIDATES
until one sticks.

Usage:
    python3 scripts/register_in_asc.py
"""
from __future__ import annotations

import os
import re
import time
import pathlib

import jwt
import requests


CONFIG_PATH = pathlib.Path(__file__).resolve().parent / "asc-config.env"
API_BASE = "https://api.appstoreconnect.apple.com/v1"

NAME_CANDIDATES = [
    "Spendcap",
    "Spendcap: Daily Spending Cap",
    "Spendcap — Daily Budget Alerts",
]


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


def write_config_value(key: str, value: str) -> None:
    text = CONFIG_PATH.read_text()
    pattern = re.compile(rf"^{re.escape(key)}=.*$", re.MULTILINE)
    # The env file is `source`d by ship.sh — quote anything with spaces.
    if any(c in value for c in ' \t"'):
        value = '"' + value.replace('"', '\\"') + '"'
    new_line = f"{key}={value}"
    if pattern.search(text):
        text = pattern.sub(new_line, text)
    else:
        text = text.rstrip() + f"\n{new_line}\n"
    CONFIG_PATH.write_text(text)


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


def api(token: str, method: str, path: str, params=None, body=None, ok_statuses=()) -> tuple[int, dict]:
    r = requests.request(
        method,
        f"{API_BASE}{path}",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        params=params or {},
        json=body,
        timeout=30,
    )
    if r.status_code >= 400 and r.status_code not in ok_statuses:
        raise SystemExit(f"{method} {path} -> {r.status_code}\n{r.text}")
    return r.status_code, (r.json() if r.text else {})


def register_bundle_id(token: str, identifier: str, name: str) -> str:
    _, res = api(token, "GET", "/bundleIds", params={"filter[identifier]": identifier, "limit": 1})
    data = res.get("data", [])
    if data:
        print(f"   bundle id already registered (resource id {data[0]['id']})")
        return data[0]["id"]
    body = {
        "data": {
            "type": "bundleIds",
            "attributes": {"identifier": identifier, "name": name, "platform": "IOS"},
        }
    }
    _, res = api(token, "POST", "/bundleIds", body=body)
    rid = res["data"]["id"]
    print(f"   registered bundle id (resource id {rid})")
    return rid


def add_capability(token: str, bundle_resource_id: str, capability_type: str) -> None:
    _, res = api(token, "GET", f"/bundleIds/{bundle_resource_id}/bundleIdCapabilities")
    if any(e.get("attributes", {}).get("capabilityType") == capability_type for e in res.get("data", [])):
        print(f"   capability {capability_type} already enabled")
        return
    body = {
        "data": {
            "type": "bundleIdCapabilities",
            "attributes": {"capabilityType": capability_type},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle_resource_id}}},
        }
    }
    api(token, "POST", "/bundleIdCapabilities", body=body)
    print(f"   enabled capability {capability_type}")


def create_app(token: str, *, identifier: str, sku: str, bundle_resource_id: str) -> tuple[str, str]:
    _, res = api(token, "GET", "/apps", params={"filter[bundleId]": identifier, "limit": 1})
    data = res.get("data", [])
    if data:
        name = data[0]["attributes"]["name"]
        print(f"   app already exists in App Store Connect (id {data[0]['id']}, name {name!r})")
        return data[0]["id"], name
    for name in NAME_CANDIDATES:
        body = {
            "data": {
                "type": "apps",
                "attributes": {"bundleId": identifier, "name": name, "primaryLocale": "en-US", "sku": sku},
                "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle_resource_id}}},
            }
        }
        status, res = api(token, "POST", "/apps", body=body, ok_statuses=(409,))
        if status < 400:
            app_id = res["data"]["id"]
            print(f"   created app (id {app_id}, name {name!r})")
            return app_id, name
        errors = " ".join(e.get("detail", "") for e in res.get("errors", []))
        print(f"   name {name!r} rejected: {errors.strip() or status}")
    raise SystemExit("all name candidates rejected — pick a new name and re-run")


def main() -> None:
    cfg = load_config()
    bundle = cfg["ASC_BUNDLE_ID"]

    print(f"==> using key {cfg['ASC_KEY_ID']} for issuer {cfg['ASC_ISSUER_ID']}")
    token = make_token(cfg)

    print(f"==> registering bundle id {bundle}")
    bundle_resource_id = register_bundle_id(token, bundle, "Spendcap")

    print("==> ensuring Push Notifications capability")
    add_capability(token, bundle_resource_id, "PUSH_NOTIFICATIONS")

    print("==> creating App Store Connect app record")
    app_id, name = create_app(token, identifier=bundle, sku="spendcap-001", bundle_resource_id=bundle_resource_id)

    write_config_value("ASC_APP_ID", app_id)
    write_config_value("ASC_APP_NAME", name)
    print(f"==> saved ASC_APP_ID={app_id} to scripts/asc-config.env")


if __name__ == "__main__":
    main()
