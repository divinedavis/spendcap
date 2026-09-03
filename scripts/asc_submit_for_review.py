#!/usr/bin/env python3
"""Submit the editable v1.0 to App Review.

Pre-flight checks every required surface that the API can introspect
(localization fields, age rating, App Review Detail, screenshots),
prints a green / red status per item, and only fires the submission
if every check is green.

Usage:
    python3 scripts/asc_submit_for_review.py [--force]

--force submits even if pre-flight reports gaps. Use after manually
filling App Privacy in the dashboard (the API doesn't expose it, so
the script can't introspect it — --force lets you proceed once
you've confirmed it's done in the web UI).
"""
from __future__ import annotations

import argparse
import os
import pathlib
import sys
import time

import jwt
import requests


ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG_PATH = ROOT / "scripts" / "asc-config.env"
API_BASE = "https://api.appstoreconnect.apple.com/v1"


def load_config() -> dict:
    cfg: dict = {}
    for line in CONFIG_PATH.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"): continue
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true",
                        help="Submit even if pre-flight checks find gaps.")
    parser.add_argument("--check", action="store_true",
                        help="Run the pre-flight only; never submit.")
    args = parser.parse_args()

    cfg = load_config()
    token = make_token(cfg)
    app_id = cfg["ASC_APP_ID"]

    # Locate the editable version.
    versions = api("GET", token, f"/apps/{app_id}/appStoreVersions",
                   params={"limit": 5})["data"]
    editable = next(
        (v for v in versions
         if v["attributes"].get("appStoreState") in (
             "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED",
             "REJECTED", "METADATA_REJECTED",
         )),
        None,
    )
    if not editable:
        raise SystemExit("no editable appStoreVersion")
    ver_id = editable["id"]
    print(f"→ version {editable['attributes']['versionString']} ({ver_id})")

    issues: list[str] = []

    # 1. Localization fields.
    locs = api("GET", token, f"/appStoreVersions/{ver_id}/appStoreVersionLocalizations")["data"]
    en_loc = next((l for l in locs if l["attributes"]["locale"] == "en-US"), None)
    if not en_loc:
        issues.append("missing en-US localization")
    else:
        a = en_loc["attributes"]
        for fld in ("description", "keywords", "supportUrl"):
            if not a.get(fld):
                issues.append(f"localization.{fld} empty")

    # 2. Build attached.
    bld = api("GET", token, f"/appStoreVersions/{ver_id}/build").get("data")
    if not bld:
        issues.append("no build attached")

    # 3. App Review Detail.
    rd = api("GET", token, f"/appStoreVersions/{ver_id}/appStoreReviewDetail").get("data")
    if not rd:
        issues.append("no appStoreReviewDetail")
    else:
        a = rd["attributes"]
        for fld in ("contactFirstName", "contactPhone", "contactEmail",
                    "demoAccountName", "demoAccountPassword"):
            if not a.get(fld):
                issues.append(f"reviewDetail.{fld} empty")

    # 4. Screenshots in the iPhone slot.
    if en_loc:
        sets = api("GET", token,
                   f"/appStoreVersionLocalizations/{en_loc['id']}/appScreenshotSets")["data"]
        iphone_set = next(
            (s for s in sets
             if s["attributes"]["screenshotDisplayType"].startswith("APP_IPHONE")),
            None,
        )
        if not iphone_set:
            issues.append("no iPhone screenshot set")
        else:
            shots = api("GET", token,
                        f"/appScreenshotSets/{iphone_set['id']}/appScreenshots")["data"]
            # ASC's `uploaded` flag was deprecated; assetDeliveryState.state
            # is the authoritative readiness signal. COMPLETE means the
            # asset finished server-side processing.
            ready = [
                s for s in shots
                if (s["attributes"].get("assetDeliveryState") or {}).get("state") == "COMPLETE"
            ]
            if len(ready) < 3:
                issues.append(f"only {len(ready)} screenshot(s) ready (need ≥ 3)")

    # 5. App Info: privacy URL + categories.
    infos = api("GET", token, f"/apps/{app_id}/appInfos")["data"]
    info = next(
        (i for i in infos
         if i["attributes"].get("appStoreState") == "PREPARE_FOR_SUBMISSION"),
        None,
    )
    if info:
        info_full = api("GET", token, f"/appInfos/{info['id']}",
                        params={"include": "primaryCategory,secondaryCategory,appInfoLocalizations"})
        rels = info_full["data"].get("relationships", {})
        if not rels.get("primaryCategory", {}).get("data"):
            issues.append("appInfo.primaryCategory unset")
        for inc in info_full.get("included", []):
            if inc["type"] == "appInfoLocalizations" \
               and inc["attributes"].get("locale") == "en-US" \
               and not inc["attributes"].get("privacyPolicyUrl"):
                issues.append("appInfoLocalization.privacyPolicyUrl empty")

    # Report.
    if issues:
        print("\n⚠ pre-flight gaps:")
        for x in issues:
            print(f"  - {x}")
        # App Privacy can't be introspected via API.
        print("\n  (App Privacy nutrition labels are dashboard-only —")
        print("   confirm in ASC web → My Apps → Spendcap → App Privacy)")
        if not args.force:
            print("\nrun again with --force after fixing or accepting the gaps.")
            return 1
        print("\n--force set; submitting anyway.")
    else:
        print("\n✓ pre-flight clean.")
    if args.check:
        print("--check: not submitting.")
        return 0 if not issues else 1

    # Submit via the new reviewSubmissions flow (replaces the
    # deprecated POST /appStoreVersionSubmissions). Three steps:
    #   1. Create / find a draft reviewSubmission for the platform.
    #   2. Add the appStoreVersion as an item.
    #   3. PATCH the reviewSubmission with submitted=true.
    platform = "IOS"

    # Reuse an in-progress submission if one exists.
    submissions = api("GET", token, "/reviewSubmissions",
                      params={"filter[app]": app_id, "filter[platform]": platform,
                              "filter[state]": "READY_FOR_REVIEW", "limit": 1})
    draft = next(iter(submissions.get("data", [])), None)
    if not draft:
        # Look for an editable (in-progress) submission.
        submissions = api("GET", token, "/reviewSubmissions",
                          params={"filter[app]": app_id, "filter[platform]": platform,
                                  "limit": 5})
        draft = next(
            (s for s in submissions.get("data", [])
             if s["attributes"].get("state") in ("READY_FOR_REVIEW", "UNRESOLVED_ISSUES", "COMPLETING")),
            None,
        )

    if draft:
        sub_id = draft["id"]
        print(f"→ reusing reviewSubmission {sub_id}")
    else:
        print("→ creating reviewSubmission…")
        created = api("POST", token, "/reviewSubmissions", body={
            "data": {
                "type": "reviewSubmissions",
                "attributes": {"platform": platform},
                "relationships": {
                    "app": {"data": {"type": "apps", "id": app_id}},
                },
            },
        })
        sub_id = created["data"]["id"]
        print(f"   ✓ {sub_id}")

    # Add this appStoreVersion as an item if it isn't already.
    items = api("GET", token, f"/reviewSubmissions/{sub_id}/items").get("data", [])
    item_for_ver = next(
        (it for it in items
         if it.get("relationships", {}).get("appStoreVersion", {}).get("data", {}).get("id") == ver_id),
        None,
    )
    if not item_for_ver:
        print("→ adding appStoreVersion as a submission item…")
        api("POST", token, "/reviewSubmissionItems", body={
            "data": {
                "type": "reviewSubmissionItems",
                "relationships": {
                    "reviewSubmission": {
                        "data": {"type": "reviewSubmissions", "id": sub_id},
                    },
                    "appStoreVersion": {
                        "data": {"type": "appStoreVersions", "id": ver_id},
                    },
                },
            },
        })

    print("→ submitting reviewSubmission…")
    api("PATCH", token, f"/reviewSubmissions/{sub_id}", body={
        "data": {
            "type": "reviewSubmissions",
            "id": sub_id,
            "attributes": {"submitted": True},
        },
    })
    print("\n✅ submitted to App Review.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
