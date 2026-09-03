#!/usr/bin/env python3
"""Upload generated ASC screenshots to App Store Connect.

Uploads every PNG under build/asc-screenshots/ to the en-US locale
of the editable v1.0 version, in the 6.9" iPhone display slot
(IPHONE_69 / "Apple iPhone 17 Pro Max"). The flow per file:

  1. Find or create the appScreenshotSet for the locale + display.
  2. POST appScreenshots reservation → returns chunked upload ops.
  3. PUT each chunk to its operations URL.
  4. PATCH appScreenshots to commit (uploaded=true + sourceFileChecksum).

Existing files in the set are left alone (idempotent enough for
re-runs) — pass --replace to clear the set first.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import sys
import time

import jwt
import requests

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCREENSHOTS_DIR = ROOT / "build" / "asc-screenshots"
CONFIG_PATH = ROOT / "scripts" / "asc-config.env"
API_BASE = "https://api.appstoreconnect.apple.com/v1"

# 6.7" slot is the largest iPhone screenshot bucket Apple's API
# currently exposes (covers Pro Max devices). Canvas must be
# 1290x2796.
DISPLAY_TYPE = "APP_IPHONE_67"


def load_config() -> dict:
    cfg: dict = {}
    for line in CONFIG_PATH.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        k, _, v = line.partition("=")
        cfg[k.strip()] = os.path.expandvars(v.strip().strip('"').strip("'"))
    return cfg


def make_token(cfg: dict) -> str:
    key = pathlib.Path(cfg["ASC_KEY_PATH"]).expanduser().read_text()
    now = int(time.time())
    return jwt.encode(
        {"iss": cfg["ASC_ISSUER_ID"], "iat": now, "exp": now + 900,
         "aud": "appstoreconnect-v1"},
        key, algorithm="ES256",
        headers={"kid": cfg["ASC_KEY_ID"], "typ": "JWT"},
    )


def api(method: str, token: str, path: str, *, body=None, params=None) -> dict:
    headers = {"Authorization": f"Bearer {token}"}
    if body is not None:
        headers["Content-Type"] = "application/json"
    r = requests.request(method, f"{API_BASE}{path}",
                         headers=headers, json=body, params=params, timeout=30)
    if r.status_code >= 400:
        sys.stderr.write(f"{method} {path} → {r.status_code}\n{r.text}\n")
        r.raise_for_status()
    return r.json() if r.text else {}


def find_editable_version(token: str, app_id: str) -> str:
    versions = api("GET", token, f"/apps/{app_id}/appStoreVersions",
                   params={"limit": 5})["data"]
    for v in versions:
        state = v["attributes"].get("appStoreState")
        if state in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED",
                     "REJECTED", "METADATA_REJECTED"):
            return v["id"]
    raise SystemExit("no editable appStoreVersion")


def find_locale(token: str, ver_id: str, locale: str) -> str:
    locs = api("GET", token, f"/appStoreVersions/{ver_id}/appStoreVersionLocalizations")["data"]
    for l in locs:
        if l["attributes"]["locale"] == locale:
            return l["id"]
    raise SystemExit(f"no {locale} appStoreVersionLocalization")


def find_or_create_screenshot_set(token: str, loc_id: str, display: str) -> str:
    sets = api("GET", token,
               f"/appStoreVersionLocalizations/{loc_id}/appScreenshotSets")["data"]
    for s in sets:
        if s["attributes"]["screenshotDisplayType"] == display:
            return s["id"]
    created = api("POST", token, "/appScreenshotSets", body={
        "data": {
            "type": "appScreenshotSets",
            "attributes": {"screenshotDisplayType": display},
            "relationships": {
                "appStoreVersionLocalization": {
                    "data": {"type": "appStoreVersionLocalizations", "id": loc_id},
                },
            },
        },
    })
    return created["data"]["id"]


def clear_screenshot_set(token: str, set_id: str) -> None:
    shots = api("GET", token, f"/appScreenshotSets/{set_id}/appScreenshots")["data"]
    for s in shots:
        api("DELETE", token, f"/appScreenshots/{s['id']}")


def upload_screenshot(token: str, set_id: str, png: pathlib.Path) -> None:
    data = png.read_bytes()
    size = len(data)
    # 1. Reservation. ASC chunks the upload server-side; we PUT to
    #    each returned operation URL.
    reservation = api("POST", token, "/appScreenshots", body={
        "data": {
            "type": "appScreenshots",
            "attributes": {
                "fileName": png.name,
                "fileSize": size,
            },
            "relationships": {
                "appScreenshotSet": {
                    "data": {"type": "appScreenshotSets", "id": set_id},
                },
            },
        },
    })["data"]
    shot_id = reservation["id"]
    operations = reservation["attributes"]["uploadOperations"]

    # 2. PUT each chunk.
    for op in operations:
        offset = int(op["offset"])
        length = int(op["length"])
        chunk = data[offset:offset + length]
        url = op["url"]
        method = op["method"]
        hdrs = {h["name"]: h["value"] for h in op["requestHeaders"]}
        r = requests.request(method, url, headers=hdrs, data=chunk, timeout=120)
        if r.status_code >= 400:
            raise SystemExit(f"chunk PUT failed: {r.status_code} {r.text}")

    # 3. Commit.
    md5 = hashlib.md5(data).hexdigest()
    api("PATCH", token, f"/appScreenshots/{shot_id}", body={
        "data": {
            "type": "appScreenshots",
            "id": shot_id,
            "attributes": {
                "uploaded": True,
                "sourceFileChecksum": md5,
            },
        },
    })


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--replace", action="store_true",
                        help="Delete existing screenshots in the slot first.")
    parser.add_argument("--display", default=DISPLAY_TYPE)
    args = parser.parse_args()

    cfg = load_config()
    token = make_token(cfg)
    app_id = cfg["ASC_APP_ID"]

    ver_id = find_editable_version(token, app_id)
    loc_id = find_locale(token, ver_id, "en-US")
    set_id = find_or_create_screenshot_set(token, loc_id, args.display)
    print(f"→ set: {set_id}  display: {args.display}")

    if args.replace:
        print("→ clearing existing screenshots…")
        clear_screenshot_set(token, set_id)

    pngs = sorted(SCREENSHOTS_DIR.glob("*.png"))
    pngs = [p for p in pngs if not p.name.startswith("_")]
    if not pngs:
        raise SystemExit(f"no PNGs in {SCREENSHOTS_DIR} — run asc_make_screenshots.py first")

    for png in pngs:
        print(f"→ uploading {png.name} ({png.stat().st_size // 1024}KB)…")
        upload_screenshot(token, set_id, png)
        print(f"   ✓ {png.name}")

    print(f"\n✅ {len(pngs)} screenshot(s) uploaded to {args.display} en-US")
    return 0


if __name__ == "__main__":
    sys.exit(main())
