#!/usr/bin/env python3
"""Push App Privacy nutrition labels via Apple's private iris API.

fastlane's upload action is broken against the current iris schema
(it sends a `dataProtection.data.id = "DATA_LINKED_TO_YOU"` value
that Apple now rejects as "Unexpected or invalid value"). This
script bypasses fastlane and POSTs to the same endpoint directly,
using cookies extracted from the cached FASTLANE_SESSION in the
keychain.

Phases:
  1. Load the FASTLANE_SESSION YAML from keychain, extract cookies.
  2. Sanity-check auth by hitting an unrelated iris endpoint.
  3. GET existing /iris/v1/appDataUsages?filter[app]=… to learn the
     current schema (key names, accepted enum IDs).
  4. Iterate over PRIVACY_DATA_TYPES and POST one record per
     (data_protection × category × data_type × purpose) tuple.
  5. PATCH /iris/v1/appDataUsagesPublishState (if exposed) to
     publish, OR mark the version ready.

If the schema differs from what fastlane's source suggests, the
probe step in (3) prints the actual response so we can adjust.

Usage:
    python3 scripts/asc_push_privacy_iris.py [--probe-only] [--app-id 6792398287]
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import subprocess
import sys

import requests


ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG_PATH = ROOT / "scripts" / "asc-config.env"
KC_SERVICE = "fastlane-session"
KC_ACCOUNT = "divinejdavis@gmail.com"
IRIS_BASE = "https://appstoreconnect.apple.com/iris/v1"


# Apple's `appDataUsageCategories` enum is flat — each entry is a
# leaf data type (EMAIL_ADDRESS, NAME, COARSE_LOCATION, …), not the
# higher-level grouping the dashboard UI shows. fastlane's source
# treats CONTACT_INFO/USER_CONTENT/etc. as categories, which is
# wrong against the live iris schema. Only the leaf id matters.
#
# (category, linked, tracking, purposes)
PRIVACY_DATA_TYPES: list[tuple[str, bool, bool, list[str]]] = [
    # Spendcap: sign-in identity, the bank data Plaid mirrors, nothing else.
    # No analytics, no ads, no tracking. Bank transactions are declared as
    # both Purchase History and Other Financial Info, which is how Apple's
    # own examples classify transaction data from a linked account.
    ("EMAIL_ADDRESS",        True, False, ["APP_FUNCTIONALITY"]),
    ("NAME",                 True, False, ["APP_FUNCTIONALITY"]),
    ("OTHER_FINANCIAL_INFO", True, False, ["APP_FUNCTIONALITY"]),
    ("PURCHASE_HISTORY",     True, False, ["APP_FUNCTIONALITY"]),
    ("USER_ID",              True, False, ["APP_FUNCTIONALITY"]),
]


# ---- Helpers ----------------------------------------------------

def load_app_id() -> str:
    cfg = {}
    for line in CONFIG_PATH.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        k, _, v = line.partition("=")
        cfg[k.strip()] = os.path.expandvars(v.strip().strip('"').strip("'"))
    return cfg["ASC_APP_ID"]


SPACESHIP_COOKIE_FILE = (
    pathlib.Path.home() / ".fastlane" / "spaceship"
    / "divinejdavis@gmail.com" / "cookie"
)


def load_session_cookies() -> list[dict]:
    """Read fastlane Spaceship's on-disk cookie jar and extract
    {name, value, domain} for every cookie.

    fastlane writes this file every time spaceauth (or any
    Spaceship login) succeeds — it's the authoritative session
    store. The keychain copy of FASTLANE_SESSION is unreliable
    (the wrapper script previously captured shell echo output
    instead of the real value), so we go straight to the file.

    The YAML uses Ruby-specific `!ruby/object:HTTP::Cookie` tags
    that PyYAML can't decode, so we line-scan instead: each cookie
    is introduced by `- !ruby/object:HTTP::Cookie` and followed by
    indented `key: value` pairs."""
    if not SPACESHIP_COOKIE_FILE.exists():
        raise SystemExit(
            f"no Spaceship cookie at {SPACESHIP_COOKIE_FILE}. Run "
            "`fastlane spaceauth -u divinejdavis@gmail.com` to refresh."
        )
    raw = SPACESHIP_COOKIE_FILE.read_text()
    cookies: list[dict] = []
    cur: dict | None = None
    for line in raw.splitlines():
        if line.lstrip().startswith("- !ruby/object:"):
            if cur and cur.get("name") and cur.get("value"):
                cookies.append(cur)
            cur = {}
            continue
        if cur is None:
            continue
        stripped = line.strip()
        if ":" not in stripped:
            continue
        key, _, val = stripped.partition(":")
        key = key.strip()
        val = val.strip().strip('"').strip("'")
        if key in ("name", "value", "domain") and val:
            cur[key] = val
    if cur and cur.get("name") and cur.get("value"):
        cookies.append(cur)
    for c in cookies:
        c.setdefault("domain", "appstoreconnect.apple.com")
    if not cookies:
        raise SystemExit("parsed 0 cookies from spaceship file — format may have changed.")
    return cookies


def make_session() -> requests.Session:
    s = requests.Session()
    for c in load_session_cookies():
        s.cookies.set(c["name"], c["value"], domain=c["domain"])
    s.headers.update({
        "Accept": "application/vnd.api+json",
        "Content-Type": "application/vnd.api+json",
        "X-Requested-With": "XMLHttpRequest",
        # The web dashboard sends these — some endpoints check.
        "User-Agent": ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                       "AppleWebKit/605.1.15 (KHTML, like Gecko) "
                       "Version/17.0 Safari/605.1.15"),
        "Origin": "https://appstoreconnect.apple.com",
        "Referer": "https://appstoreconnect.apple.com/",
    })
    return s


def get_csrf_token(s: requests.Session, app_id: str) -> str | None:
    """Some POST endpoints require a CSRF token from a prior page
    load. Hit the privacy page first; if Apple sets a CSRF cookie
    or the response includes a token, return it."""
    r = s.get(f"https://appstoreconnect.apple.com/apps/{app_id}/distribution/privacy",
              timeout=20, allow_redirects=True)
    # Common ASC CSRF cookies: csrf, X-CSRF-Token, scnt
    for name in ("csrf", "scnt", "X-CSRF-Token"):
        if name in s.cookies:
            return s.cookies.get(name)
    return None


def show(label: str, r: requests.Response) -> None:
    body = r.text
    if r.headers.get("content-type", "").startswith("application/"):
        try:
            body = json.dumps(r.json(), indent=2)
        except Exception:
            pass
    print(f"\n──── {label} ────  HTTP {r.status_code}")
    print(body[:2000])


# ---- Probe / push ----------------------------------------------

def probe(s: requests.Session, app_id: str) -> None:
    """Read-only probes to learn the live schema."""
    # 1. Sanity: fetch our own app via iris.
    show("GET /iris/v1/apps/{id}",
         s.get(f"{IRIS_BASE}/apps/{app_id}", timeout=20))

    # 2. Existing data usages (likely empty).
    show("GET /iris/v1/appDataUsages?filter[app]=…",
         s.get(f"{IRIS_BASE}/appDataUsages",
               params={"filter[app]": app_id, "limit": 3}, timeout=20))

    # 3. Categories enum.
    show("GET /iris/v1/appDataUsageCategories?limit=5",
         s.get(f"{IRIS_BASE}/appDataUsageCategories",
               params={"limit": 5}, timeout=20))

    # 4. Data protections enum (the field that's failing).
    show("GET /iris/v1/appDataUsageDataProtections",
         s.get(f"{IRIS_BASE}/appDataUsageDataProtections", timeout=20))

    # 5. Purposes enum.
    show("GET /iris/v1/appDataUsagePurposes",
         s.get(f"{IRIS_BASE}/appDataUsagePurposes", timeout=20))


def push(s: requests.Session, app_id: str) -> None:
    posted = 0
    for category, linked, tracking, purposes in PRIVACY_DATA_TYPES:
        protection = "DATA_LINKED_TO_YOU" if linked else "DATA_NOT_LINKED_TO_YOU"
        if tracking:
            protection = "DATA_USED_TO_TRACK_YOU"
        for purpose in purposes:
            body = {
                "data": {
                    "type": "appDataUsages",
                    "relationships": {
                        "app": {
                            "data": {"type": "apps", "id": app_id},
                        },
                        "category": {
                            "data": {"type": "appDataUsageCategories", "id": category},
                        },
                        "dataProtection": {
                            "data": {"type": "appDataUsageDataProtections", "id": protection},
                        },
                        "purpose": {
                            "data": {"type": "appDataUsagePurposes", "id": purpose},
                        },
                    },
                },
            }
            r = s.post(f"{IRIS_BASE}/appDataUsages", data=json.dumps(body), timeout=30)
            if r.status_code >= 400:
                show(f"POST {category} / {protection} / {purpose} (FAILED)", r)
                raise SystemExit("aborting on first failure — adjust schema and retry")
            print(f"   ✓ {category} / {protection} / {purpose}")
            posted += 1
    print(f"\n✅ posted {posted} data usage records")

    # Publish so the records actually surface on the app's privacy
    # page. Without this PATCH the records stay in a draft state
    # and the dashboard still says "Get Started".
    print("→ publishing privacy details…")
    body = {
        "data": {
            "type": "appDataUsagesPublishState",
            "id": app_id,
            "attributes": {"published": True},
        },
    }
    r = s.patch(
        f"{IRIS_BASE}/appDataUsagesPublishState/{app_id}",
        data=json.dumps(body), timeout=30,
    )
    if r.status_code >= 400:
        show("PATCH publish state (FAILED)", r)
        raise SystemExit("records posted but publish failed; fix and re-run")
    print("   ✓ published")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-id", default=None)
    parser.add_argument("--probe-only", action="store_true",
                        help="Skip the upload; just dump live schema.")
    args = parser.parse_args()

    app_id = args.app_id or load_app_id()
    print(f"→ app id: {app_id}")

    s = make_session()
    csrf = get_csrf_token(s, app_id)
    if csrf:
        s.headers["X-CSRF-Token"] = csrf
        print(f"→ csrf token attached ({csrf[:12]}…)")

    print("→ probing iris schema…")
    probe(s, app_id)

    if args.probe_only:
        return 0

    print("\n→ posting privacy records…")
    push(s, app_id)
    return 0


if __name__ == "__main__":
    sys.exit(main())
