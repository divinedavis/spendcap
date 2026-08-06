#!/usr/bin/env python3
"""Attach the newest processed build to the App Store version.

Why this exists: App Store Connect draws the app's header icon from the build
attached to its App Store *version*, not from whatever was last uploaded to
TestFlight. Spendcap had 22 TestFlight builds, every one of them carrying an
app icon, and the ASC page still showed the grey placeholder grid — because
version 1.0 had no build selected.

This only sets the version's build relationship. It does **not** submit
anything for review, and it is reversible by attaching a different build.

Usage:
    python3 scripts/attach_build.py             # attach newest VALID build
    python3 scripts/attach_build.py --dry-run   # report only
    python3 scripts/attach_build.py --build 23  # attach a specific build
"""
from __future__ import annotations

import argparse
import os
import pathlib
import time

import jwt
import requests

CONFIG_PATH = pathlib.Path(__file__).resolve().parent / "asc-config.env"
API_BASE = "https://api.appstoreconnect.apple.com/v1"
# Only a version still being prepared may have its build swapped; anything in
# review or already released must not be touched by a script.
EDITABLE_STATES = {
    "PREPARE_FOR_SUBMISSION",
    "DEVELOPER_REJECTED",
    "REJECTED",
    "METADATA_REJECTED",
    "INVALID_BINARY",
}


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        raise SystemExit(f"missing {CONFIG_PATH}")
    cfg: dict = {}
    for line in CONFIG_PATH.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            cfg[key.strip()] = value.strip().strip('"').strip("'")
    return cfg


def token(cfg: dict) -> str:
    key_path = pathlib.Path(os.path.expandvars(cfg["ASC_KEY_PATH"])).expanduser()
    return jwt.encode(
        {"iss": cfg["ASC_ISSUER_ID"], "exp": int(time.time()) + 900, "aud": "appstoreconnect-v1"},
        key_path.read_text(),
        algorithm="ES256",
        headers={"kid": cfg["ASC_KEY_ID"], "typ": "JWT"},
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--build", help="build number to attach (default: newest VALID)")
    args = parser.parse_args()

    cfg = load_config()
    headers = {"Authorization": f"Bearer {token(cfg)}"}
    app_id = cfg["ASC_APP_ID"]

    versions = requests.get(
        f"{API_BASE}/apps/{app_id}/appStoreVersions",
        headers=headers,
        params={"limit": 5, "fields[appStoreVersions]": "versionString,appStoreState"},
    )
    versions.raise_for_status()
    editable = [
        v for v in versions.json()["data"]
        if v["attributes"].get("appStoreState") in EDITABLE_STATES
    ]
    if not editable:
        print("no editable App Store version — nothing to attach to")
        return 1
    version = editable[0]
    version_id = version["id"]
    version_string = version["attributes"]["versionString"]

    current = requests.get(f"{API_BASE}/appStoreVersions/{version_id}/build",
                           headers=headers, params={"fields[builds]": "version"})
    current_build = (current.json().get("data") or {}).get("attributes", {}).get("version") \
        if current.ok else None
    print(f"version {version_string} ({version['attributes']['appStoreState']}) "
          f"currently has build: {current_build or 'NONE'}")

    builds = requests.get(
        f"{API_BASE}/builds",
        headers=headers,
        params={"filter[app]": app_id, "limit": 20, "sort": "-version",
                "fields[builds]": "version,processingState,expired"},
    )
    builds.raise_for_status()
    usable = [
        b for b in builds.json()["data"]
        if b["attributes"]["processingState"] == "VALID" and not b["attributes"]["expired"]
    ]
    if args.build:
        usable = [b for b in usable if b["attributes"]["version"] == str(args.build)]
        if not usable:
            print(f"build {args.build} is not a processed, unexpired build")
            return 1
    if not usable:
        print("no VALID unexpired build to attach — is one still processing?")
        return 1

    target = usable[0]
    target_number = target["attributes"]["version"]
    if current_build == target_number:
        print(f"build {target_number} is already attached — nothing to do")
        return 0
    if args.dry_run:
        print(f"would attach build {target_number} to version {version_string}")
        return 0

    patch = requests.patch(
        f"{API_BASE}/appStoreVersions/{version_id}/relationships/build",
        headers={**headers, "Content-Type": "application/json"},
        json={"data": {"type": "builds", "id": target["id"]}},
    )
    if not patch.ok:
        print(f"attach failed: {patch.status_code} {patch.text}")
        return 1
    print(f"attached build {target_number} to version {version_string}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
