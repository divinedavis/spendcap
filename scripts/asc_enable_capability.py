#!/usr/bin/env python3
"""Enable a capability on com.divinedavis.spendcap's App ID.

The generalised form of asc_enable_associated_domains.py, written when Sign in
with Apple was added (2026-08-08). Kept separate rather than folded into that
script because APPLE_ID_AUTH needs something no other capability here does:

    APPLE_ID_AUTH rejects a bare enable with 409 "Please select at least one
    configuration for Sign In with Apple." The POST body must also carry a
    settings array naming the app's consent role. PRIMARY_APP_CONSENT means
    this app stands on its own, rather than being grouped under another app's
    Apple ID relationship (which is what you want unless Spendcap is ever
    bundled with a sibling app that already owns the sign-in).

After this runs, Xcode's automatic provisioning picks the capability up on the
next build. The matching entitlement still has to exist in project.yml — the
App ID and the entitlement are two halves and a build fails if they disagree.

Usage:
    python3 scripts/asc_enable_capability.py APPLE_ID_AUTH
    python3 scripts/asc_enable_capability.py --list
"""
from __future__ import annotations

import argparse
import os
import pathlib
import sys
import time

import jwt
import requests

CONFIG_PATH = pathlib.Path(__file__).resolve().parent / "asc-config.env"
API_BASE = "https://api.appstoreconnect.apple.com/v1"

# Capabilities that need a `settings` block, keyed by capability type.
CAPABILITY_SETTINGS: dict[str, list[dict]] = {
    "APPLE_ID_AUTH": [
        {
            "key": "APPLE_ID_AUTH_APP_CONSENT",
            "options": [{"key": "PRIMARY_APP_CONSENT"}],
        }
    ],
}


def load_config() -> dict:
    cfg: dict = {}
    for line in CONFIG_PATH.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, _, value = line.partition("=")
        value = os.path.expandvars(value.strip().strip('"').strip("'"))
        cfg[key.strip()] = value
    return cfg


def make_token(cfg: dict) -> str:
    private_key = pathlib.Path(cfg["ASC_KEY_PATH"]).expanduser().read_text()
    now = int(time.time())
    payload = {
        "iss": cfg["ASC_ISSUER_ID"],
        "iat": now,
        "exp": now + 15 * 60,
        "aud": "appstoreconnect-v1",
    }
    headers = {"kid": cfg["ASC_KEY_ID"], "typ": "JWT"}
    return jwt.encode(payload, private_key, algorithm="ES256", headers=headers)


def find_bundle_id(token: str, bundle: str) -> str:
    r = requests.get(
        f"{API_BASE}/bundleIds",
        headers={"Authorization": f"Bearer {token}"},
        params={"filter[identifier]": bundle, "limit": 200},
        timeout=30,
    )
    r.raise_for_status()
    for row in r.json().get("data", []):
        if row.get("attributes", {}).get("identifier") == bundle:
            return row["id"]
    raise SystemExit(f"bundle id {bundle} not found via ASC API")


def existing_capabilities(token: str, bundle_id_pk: str) -> set[str]:
    r = requests.get(
        f"{API_BASE}/bundleIds/{bundle_id_pk}/bundleIdCapabilities",
        headers={"Authorization": f"Bearer {token}"},
        timeout=30,
    )
    r.raise_for_status()
    return {
        row["attributes"]["capabilityType"]
        for row in r.json().get("data", [])
        if row.get("attributes", {}).get("capabilityType")
    }


def enable_capability(token: str, bundle_id_pk: str, capability: str) -> None:
    attributes: dict = {"capabilityType": capability}
    if capability in CAPABILITY_SETTINGS:
        attributes["settings"] = CAPABILITY_SETTINGS[capability]
    body = {
        "data": {
            "type": "bundleIdCapabilities",
            "attributes": attributes,
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle_id_pk}}
            },
        }
    }
    r = requests.post(
        f"{API_BASE}/bundleIdCapabilities",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        json=body,
        timeout=30,
    )
    if r.status_code >= 300:
        sys.exit(f"capability enable failed: {r.status_code} {r.text}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("capability", nargs="?", help="e.g. APPLE_ID_AUTH")
    ap.add_argument("--list", action="store_true", help="show what is on")
    args = ap.parse_args()

    cfg = load_config()
    bundle = cfg["ASC_BUNDLE_ID"]
    token = make_token(cfg)
    pk = find_bundle_id(token, bundle)
    caps = existing_capabilities(token, pk)
    print(f"bundle {bundle} (pk={pk})")
    print(f"current capabilities: {sorted(caps)}")

    if args.list:
        return 0
    if not args.capability:
        ap.error("give a capability, or --list")
    if args.capability in caps:
        print(f"==> {args.capability} already on, nothing to do.")
        return 0

    enable_capability(token, pk, args.capability)
    print(f"==> {args.capability} enabled.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
