#!/usr/bin/env python3
"""Enable the Associated Domains capability on com.divinedavis.spendcap.

The ASC API exposes bundle-id capability toggles via the
`bundleIdCapabilities` resource. We:
  1. Look up the bundle id record for the configured bundle.
  2. Check whether ASSOCIATED_DOMAINS is already enabled.
  3. POST to enable it if not.

After this runs, Xcode's automatic provisioning regenerates the
profile on the next build with Associated Domains included.

Usage:
    python3 scripts/asc_enable_associated_domains.py
"""
from __future__ import annotations

import os
import sys
import time
import pathlib
import jwt
import requests


CONFIG_PATH = pathlib.Path(__file__).resolve().parent / "asc-config.env"
API_BASE = "https://api.appstoreconnect.apple.com/v1"
CAPABILITY = "ASSOCIATED_DOMAINS"


def load_config() -> dict:
    cfg: dict = {}
    for line in CONFIG_PATH.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, _, value = line.partition("=")
        value = value.strip().strip('"').strip("'")
        value = os.path.expandvars(value)
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
    rows = r.json().get("data", [])
    for row in rows:
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
    out: set[str] = set()
    for row in r.json().get("data", []):
        cap = row.get("attributes", {}).get("capabilityType")
        if cap:
            out.add(cap)
    return out


def enable_capability(token: str, bundle_id_pk: str) -> None:
    body = {
        "data": {
            "type": "bundleIdCapabilities",
            "attributes": {"capabilityType": CAPABILITY},
            "relationships": {
                "bundleId": {
                    "data": {"type": "bundleIds", "id": bundle_id_pk}
                }
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
    cfg = load_config()
    bundle = cfg["ASC_BUNDLE_ID"]
    token = make_token(cfg)
    pk = find_bundle_id(token, bundle)
    print(f"bundle {bundle} (pk={pk})")
    caps = existing_capabilities(token, pk)
    print(f"current capabilities: {sorted(caps)}")
    if CAPABILITY in caps:
        print(f"==> {CAPABILITY} already on, nothing to do.")
        return 0
    enable_capability(token, pk)
    print(f"==> {CAPABILITY} enabled.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
