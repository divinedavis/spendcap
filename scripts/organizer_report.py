#!/usr/bin/env python3
"""Xcode Organizer numbers before a ship (2026-10-04, ported from Marracat): what real phones on
recent Spendcap builds reported to Apple — the data behind Xcode > Organizer >
Launches, Hangs, Memory, Disk Writes — from the App Store Connect API.
Read-only, so it is safe to run any time.

  * perfPowerMetrics for the app (and any regression Apple has flagged)
  * diagnosticSignatures (hang / disk-write / launch) for the newest builds

Report only: a new build needs days of real use before Apple has anything, so
a ship is never blocked on it. Exit 2 only when the API cannot be reached, so a
dead key is still noticed.

  ~/.venvs/spendcap/bin/python scripts/organizer_report.py [--builds 3]
"""
import argparse, os, pathlib, sys, time
import jwt, requests

API = "https://api.appstoreconnect.apple.com/v1"
HERE = pathlib.Path(__file__).resolve().parent
WANT = ("LAUNCH", "HANG", "MEMORY", "DISK", "TERMINATION")


def config():
    cfg = {}
    for line in (HERE / "asc-config.env").read_text().splitlines():
        s = line.strip()
        if s and not s.startswith("#") and "=" in s:
            k, _, v = s.partition("=")
            cfg[k.strip()] = os.path.expandvars(v.strip().strip('"').strip("'"))
    return cfg


def session(cfg):
    now = int(time.time())
    key = pathlib.Path(cfg["ASC_KEY_PATH"]).expanduser().read_text()
    tok = jwt.encode({"iss": cfg["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                     key, algorithm="ES256", headers={"kid": cfg["ASC_KEY_ID"], "typ": "JWT"})
    s = requests.Session()
    s.headers["Authorization"] = f"Bearer {tok}"
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--builds", type=int, default=3)
    a = ap.parse_args()
    cfg = config()
    try:
        s = session(cfg)
        app = cfg["ASC_APP_ID"]
        r = s.get(f"{API}/apps/{app}/perfPowerMetrics", headers={"Accept": "application/vnd.apple.xcode-metrics+json"}, timeout=60)
        builds = s.get(f"{API}/builds", params={"filter[app]": app, "sort": "-uploadedDate", "limit": a.builds,
                                                "fields[builds]": "version,uploadedDate"}, timeout=60)
        builds.raise_for_status()
    except (requests.RequestException, KeyError, OSError) as e:
        print(f"organizer report: App Store Connect unreachable ({e})", file=sys.stderr)
        return 2

    print("Xcode Organizer — field metrics:")
    lines = []
    if r.status_code == 200:
        body = r.json()
        lines += [f"  REGRESSION: {i.get('summaryString') or i}" for i in body.get("insights", {}).get("regressions", [])]
        for prod in body.get("productData", []):
            for cat in prod.get("metricCategories", []):
                if not any(w in cat.get("identifier", "") for w in WANT):
                    continue
                for m in cat.get("metrics", []):
                    for ds in m.get("datasets", [])[:1]:
                        pts = ds.get("points", [])[-3:]
                        if pts:
                            vals = ", ".join(f"{p.get('version')}: {p.get('value')}" for p in pts)
                            lines.append(f"  {cat['identifier']:<12} {m.get('identifier', ''):<28} {vals} {(m.get('unit') or {}).get('displayName', '')}")
    else:
        lines.append(f"  perfPowerMetrics: HTTP {r.status_code}")
    print("\n".join(lines) or "  (no field data yet — Apple needs days of real use per version)")

    print("Xcode Organizer — diagnostic signatures by build:")
    for b in builds.json().get("data", []):
        print(f"  build {b['attributes']['version']} (uploaded {b['attributes']['uploadedDate'][:10]})")
        d = s.get(f"{API}/builds/{b['id']}/diagnosticSignatures", params={"limit": 10}, timeout=60)
        if d.status_code == 404:
            print("    no reports yet"); continue
        if d.status_code != 200:
            print(f"    diagnosticSignatures: HTTP {d.status_code}"); continue
        rows = d.json().get("data", [])
        for x in rows:
            at = x["attributes"]
            print(f"    {at.get('diagnosticType', ''):<12} {at.get('weight', 0):>5.1f}%  {(at.get('signature') or '')[:110]}")
        if not rows:
            print("    no hang/disk/launch signatures")
    return 0


if __name__ == "__main__":
    sys.exit(main())
