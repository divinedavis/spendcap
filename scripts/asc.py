#!/usr/bin/env python3
"""App Store Connect helper.

Registers the bundle id (with Sign in with Apple), creates the app record, and
reports TestFlight build state — all through the API rather than the dashboard,
so shipping is repeatable and does not depend on anyone clicking through a web
form correctly at 1am.

Idempotent: every step looks the resource up before creating it, so a re-run
after a partial failure resumes rather than duplicating.

    python3 scripts/asc.py status      # what exists right now
    python3 scripts/asc.py setup       # register bundle id + create app record
    python3 scripts/asc.py builds      # TestFlight build processing state
    python3 scripts/asc.py attach 39   # point the App Store version at a build
"""
from __future__ import annotations

import os
import pathlib
import sys
import time

import jwt
import requests

CONFIG_PATH = pathlib.Path(__file__).resolve().parent / "asc-config.env"
API = "https://api.appstoreconnect.apple.com/v1"

# App Store display names are globally unique across every developer, so a
# plain "Spendcap" may well be taken. Fall through candidates rather than failing.
NAME_CANDIDATES = [
    "Spendcap",
    "Spendcap — Dry Cleaning",
    "Spendcap: Dry Cleaning Delivery",
]


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        raise SystemExit(f"missing {CONFIG_PATH} — copy asc-config.env.example")
    cfg: dict = {}
    for line in CONFIG_PATH.read_text().splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        k, _, v = s.partition("=")
        cfg[k.strip()] = os.path.expandvars(v.strip().strip('"').strip("'"))
    return cfg


def write_config_value(key: str, value: str) -> None:
    lines = CONFIG_PATH.read_text().splitlines()
    for i, line in enumerate(lines):
        if line.strip().startswith(f"{key}="):
            lines[i] = f"{key}={value}"
            break
    else:
        lines.append(f"{key}={value}")
    CONFIG_PATH.write_text("\n".join(lines) + "\n")


def token(cfg: dict) -> str:
    key = pathlib.Path(cfg["ASC_KEY_PATH"]).read_text()
    now = int(time.time())
    return jwt.encode(
        # 20 minutes is Apple's maximum; anything longer is rejected outright.
        {"iss": cfg["ASC_ISSUER_ID"], "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": cfg["ASC_KEY_ID"], "typ": "JWT"},
    )


class ASC:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.s = requests.Session()
        self.s.headers["Authorization"] = f"Bearer {token(cfg)}"

    def get(self, path: str, **params):
        r = self.s.get(f"{API}{path}", params=params, timeout=30)
        r.raise_for_status()
        return r.json()

    def post(self, path: str, payload: dict):
        r = self.s.post(f"{API}{path}", json=payload, timeout=30)
        if r.status_code >= 400:
            raise RuntimeError(f"{r.status_code} {r.text[:500]}")
        return r.json()

    # --- bundle id ---------------------------------------------------------
    def find_bundle_id(self, identifier: str):
        data = self.get("/bundleIds", **{"filter[identifier]": identifier, "limit": 200})["data"]
        return next((b for b in data if b["attributes"]["identifier"] == identifier), None)

    def create_bundle_id(self, identifier: str, name: str):
        return self.post(
            "/bundleIds",
            {
                "data": {
                    "type": "bundleIds",
                    "attributes": {"identifier": identifier, "name": name, "platform": "IOS"},
                }
            },
        )["data"]

    def enable_capability(self, bundle_id_ref: str, capability: str):
        """Sign in with Apple must be on the App ID, not just in the entitlements.

        Adding it after a profile is issued forces regeneration, so it goes on
        at registration time.

        APPLE_ID_AUTH is not a bare toggle: Apple rejects it with 409
        "Please select at least one configuration for Sign In with Apple"
        unless a consent setting is supplied. PRIMARY_APP_CONSENT is the right
        one for a standalone app that is not grouped with others.
        """
        attributes: dict = {"capabilityType": capability}
        if capability == "APPLE_ID_AUTH":
            attributes["settings"] = [
                {
                    "key": "APPLE_ID_AUTH_APP_CONSENT",
                    "options": [{"key": "PRIMARY_APP_CONSENT"}],
                }
            ]
        try:
            self.post(
                "/bundleIdCapabilities",
                {
                    "data": {
                        "type": "bundleIdCapabilities",
                        "attributes": attributes,
                        "relationships": {
                            "bundleId": {"data": {"type": "bundleIds", "id": bundle_id_ref}}
                        },
                    }
                },
            )
            return True
        except RuntimeError as e:
            # Only an actual duplicate counts as success. Treating every
            # ENTITY_ERROR as "already enabled" hid a real 409 here and
            # reported Sign in with Apple as on when it was not — which would
            # have surfaced as a broken sign-in button in a TestFlight build.
            if "already exists" in str(e).lower() or "duplicate" in str(e).lower():
                return True
            raise

    # --- app record --------------------------------------------------------
    def find_app(self, bundle_id: str):
        data = self.get("/apps", **{"filter[bundleId]": bundle_id, "limit": 200})["data"]
        return next((a for a in data if a["attributes"]["bundleId"] == bundle_id), None)

    def create_app(self, bundle_id_ref: str, name: str, sku: str):
        return self.post(
            "/apps",
            {
                "data": {
                    "type": "apps",
                    "attributes": {
                        "name": name,
                        "sku": sku,
                        "primaryLocale": "en-US",
                        "bundleId": self.cfg["ASC_BUNDLE_ID"],
                    },
                    "relationships": {
                        "bundleId": {"data": {"type": "bundleIds", "id": bundle_id_ref}}
                    },
                }
            },
        )["data"]

    def patch(self, path: str, payload: dict):
        r = self.s.patch(f"{API}{path}", json=payload, timeout=30)
        if r.status_code >= 400:
            raise RuntimeError(f"{r.status_code} {r.text[:400]}")
        return r

    def attach_build(self, version_id: str, build_id: str):
        """Point an App Store version at a build.

        Until this is set the version has no artwork of its own, so App Store
        Connect shows the placeholder grid next to the app name even though
        the uploaded build carries a perfectly good icon. The icon in the
        header comes from the version, not from TestFlight.
        """
        return self.patch(
            f"/appStoreVersions/{version_id}/relationships/build",
            {"data": {"type": "builds", "id": build_id}},
        )

    def builds(self, app_id: str):
        """Every build ASC knows about, newest first — including processing ones.

        Not `/builds?filter[app]`: that query omits a build entirely until
        Apple finishes processing it, so a fresh upload reads as "never
        arrived" for the twenty minutes to an hour it sits in the queue. The
        prerelease version's own relationship lists it from the moment the
        upload lands, with processingState PROCESSING.
        """
        versions = self.get(
            "/preReleaseVersions", **{"filter[app]": app_id, "limit": 50}
        )["data"]
        out: list = []
        for v in versions:
            out += self.get(f"/preReleaseVersions/{v['id']}/builds", limit=50)["data"]
        out.sort(key=lambda b: b["attributes"].get("uploadedDate") or "", reverse=True)
        return out


def cmd_status(asc: ASC, cfg: dict):
    bundle = asc.find_bundle_id(cfg["ASC_BUNDLE_ID"])
    print(f"bundle id {cfg['ASC_BUNDLE_ID']}: {'registered' if bundle else 'NOT REGISTERED'}")
    if bundle:
        caps = asc.get(f"/bundleIds/{bundle['id']}/bundleIdCapabilities").get("data", [])
        names = sorted(c["attributes"]["capabilityType"] for c in caps)
        print(f"  capabilities: {', '.join(names) or 'none'}")

    app = asc.find_app(cfg["ASC_BUNDLE_ID"])
    print(f"app record: {'exists — ' + app['id'] if app else 'NOT CREATED'}")
    if app:
        print(f"  name: {app['attributes']['name']}")
        if cfg.get("ASC_APP_ID") != app["id"]:
            write_config_value("ASC_APP_ID", app["id"])
            print("  (saved ASC_APP_ID to config)")


def cmd_setup(asc: ASC, cfg: dict):
    bundle = asc.find_bundle_id(cfg["ASC_BUNDLE_ID"])
    if bundle:
        print(f"bundle id already registered: {bundle['id']}")
    else:
        bundle = asc.create_bundle_id(cfg["ASC_BUNDLE_ID"], cfg["ASC_APP_NAME"])
        print(f"registered bundle id: {bundle['id']}")

    asc.enable_capability(bundle["id"], "APPLE_ID_AUTH")
    caps = asc.get(f"/bundleIds/{bundle['id']}/bundleIdCapabilities").get("data", [])
    enabled = {c["attributes"]["capabilityType"] for c in caps}
    if "APPLE_ID_AUTH" not in enabled:
        raise SystemExit("Sign in with Apple did not stick — the app cannot sign anyone in")
    print(f"capabilities: {', '.join(sorted(enabled))}")

    app = asc.find_app(cfg["ASC_BUNDLE_ID"])
    if not app:
        # Apple does not expose app-record creation through the API: /apps is
        # GET/UPDATE only. This one step genuinely has to happen in the
        # dashboard, so say so precisely rather than failing with a 403.
        print()
        print("app record: must be created in the App Store Connect UI —")
        print("  Apple's API allows GET and UPDATE on /apps, but not CREATE.")
        print()
        print("  My Apps -> + -> New App")
        print(f"    Platform     iOS")
        print(f"    Name         {cfg['ASC_APP_NAME']}  (globally unique; try a suffix if taken)")
        print(f"    Bundle ID    {cfg['ASC_BUNDLE_ID']}  (now registered, so it will appear)")
        print(f"    SKU          spendcap-001")
        print(f"    User Access  Full Access")
        print()
        print("  Then re-run: python3 scripts/asc.py status")
        return

    print(f"app record exists: {app['id']} ({app['attributes']['name']})")
    write_config_value("ASC_APP_ID", app["id"])
    print(f"ASC_APP_ID={app['id']} saved")


def cmd_builds(asc: ASC, cfg: dict):
    app_id = cfg.get("ASC_APP_ID")
    if not app_id:
        app = asc.find_app(cfg["ASC_BUNDLE_ID"])
        if not app:
            raise SystemExit("no app record yet — run: python3 scripts/asc.py setup")
        app_id = app["id"]
    builds = asc.builds(app_id)
    if not builds:
        print("  no builds yet — Apple takes a few minutes to ingest an upload")
        return
    for b in builds:
        a = b["attributes"]
        print(f"  build {a.get('version')}  {a.get('processingState')}  uploaded {a.get('uploadedDate')}")


def cmd_attach(asc: ASC, cfg: dict):
    """Attach a build to the editable App Store version.

        python3 scripts/asc.py attach        # newest VALID build
        python3 scripts/asc.py attach 39     # that build number, and no other

    Prefer naming the build. A freshly uploaded one takes minutes to finish
    processing, and "newest VALID" during that window is the *previous* build
    — which then ships under this version's release notes.
    """
    app_id = cfg["ASC_APP_ID"]
    wanted = sys.argv[2] if len(sys.argv) > 2 else None
    builds = [b for b in asc.builds(app_id) if b["attributes"].get("processingState") == "VALID"]
    if wanted:
        builds = [b for b in builds if b["attributes"]["version"] == wanted]
        if not builds:
            raise SystemExit(f"build {wanted} is not VALID yet — check: python3 scripts/asc.py builds")
    if not builds:
        raise SystemExit("no VALID build yet — check: python3 scripts/asc.py builds")
    build = builds[0]

    versions = asc.get(f"/apps/{app_id}/appStoreVersions", **{"limit": 10})["data"]
    editable = [v for v in versions
                if v["attributes"]["appStoreState"] in
                ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED")]
    if not editable:
        raise SystemExit("no editable App Store version to attach a build to")
    version = editable[0]

    asc.attach_build(version["id"], build["id"])
    print(f"attached build {build['attributes']['version']} to version "
          f"{version['attributes']['versionString']}")
    print("the placeholder icon in App Store Connect should now be the real one")


def main():
    cfg = load_config()
    asc = ASC(cfg)
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    {"status": cmd_status, "setup": cmd_setup, "builds": cmd_builds,
     "attach": cmd_attach}[cmd](asc, cfg)


if __name__ == "__main__":
    main()
