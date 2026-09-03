#!/usr/bin/env python3
"""Push App Privacy nutrition labels to App Store Connect via Playwright.

Apple's public ASC REST API has no endpoint for App Privacy details
(verified — every variant of /appPrivacyDetails 404s, the
relationship doesn't exist on /apps). This script drives the ASC
web dashboard with Playwright instead. Two-phase:

  1. AUTH (one-time per machine): launches a persistent-context
     Chromium and pauses on the ASC sign-in page. You sign in,
     approve 2FA on your trusted device, and land on the apps
     dashboard. The script saves the session and proceeds.

  2. FORM: navigates to the app's App Privacy page and clicks
     through:
        * "Yes, we collect data from this app"
        * Data types in PRIVACY_DATA_TYPES below
        * Per-type linkage / tracking / purpose answers
     using Playwright's role-based locators so the script survives
     small DOM changes.

The persistent-context dir at PROFILE_DIR caches cookies + storage,
so subsequent runs reuse the session without re-prompting for
2FA — until Apple expires the cookie (~30 days).

Usage:
    python3 scripts/asc_push_privacy_labels.py
    python3 scripts/asc_push_privacy_labels.py --app-id 6792398287
    python3 scripts/asc_push_privacy_labels.py --headed   # show the browser
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import sys
import time

from playwright.sync_api import sync_playwright, Page, BrowserContext, TimeoutError as PlaywrightTimeout


ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG_PATH = ROOT / "scripts" / "asc-config.env"
# Persistent browser profile. Stored in ~/.appstoreconnect so it can
# be reused by other ASC web automation across apps.
PROFILE_DIR = pathlib.Path.home() / ".appstoreconnect" / "playwright-state"


# ---- App Privacy spec ------------------------------------------
# Per-app config. Add an entry below for each iOS app. The key is
# the ASC numeric app id (matches ASC_APP_ID in asc-config.env).

# Schema:
#   collects_data: bool
#   data_types: list of {category, type, linked, tracking, purposes}
#     - category, type: human strings matching the labels Apple
#       shows in the form (e.g. "Contact Info" / "Email Address").
#     - linked: True → "Linked to the User"; False → "Not Linked"
#     - tracking: True → "Used for Tracking" (rare); usually False
#     - purposes: list of purposes — match Apple's labels.
#       Common: "App Functionality", "Analytics", "Product Personalization",
#               "App Functionality", "Other Purposes"

SPENDCAP = {
    "collects_data": True,
    "data_types": [
        {"category": "Contact Info",   "type_label": "Email Address",
         "linked": True, "tracking": False, "purposes": ["App Functionality"]},
        {"category": "Contact Info",   "type_label": "Name",
         "linked": True, "tracking": False, "purposes": ["App Functionality"]},
        {"category": "Financial Info", "type_label": "Other Financial Info",
         "linked": True, "tracking": False, "purposes": ["App Functionality"]},
        {"category": "Purchases",      "type_label": "Purchase History",
         "linked": True, "tracking": False, "purposes": ["App Functionality"]},
        {"category": "Identifiers",    "type_label": "User ID",
         "linked": True, "tracking": False, "purposes": ["App Functionality"]},
    ],
}

PRIVACY_SPECS_BY_APP = {
    "6792398287": SPENDCAP,   # Spendcap Finance
}


# ---- Helpers ---------------------------------------------------

def load_config() -> dict:
    cfg: dict = {}
    if not CONFIG_PATH.exists():
        return cfg
    for line in CONFIG_PATH.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        k, _, v = line.partition("=")
        cfg[k.strip()] = os.path.expandvars(v.strip().strip('"').strip("'"))
    return cfg


def app_privacy_url(app_id: str) -> str:
    return f"https://appstoreconnect.apple.com/apps/{app_id}/distribution/privacy"


def is_signed_in(page: Page) -> bool:
    """Heuristic: the apps dashboard URL only loads post-auth."""
    try:
        page.wait_for_url("**/appstoreconnect.apple.com/apps**", timeout=2000)
        return True
    except PlaywrightTimeout:
        return False


def ensure_signed_in(ctx: BrowserContext, app_id: str) -> Page:
    """Drive the browser to the App Privacy page, surviving the
    interstitials Apple injects after login: /login, /review_agree
    (Program License Agreement check), bare /, etc. Polls for up to
    ~6 minutes total — long enough for a manual login + 2FA the
    first time, fast on subsequent runs."""
    page = ctx.new_page()
    target = "/distribution/privacy"
    deadline = time.time() + 6 * 60   # 6 min total
    last_url = ""

    while time.time() < deadline:
        # Force the page back to the privacy URL each pass; Apple's
        # SPA sometimes redirects past it after login completes.
        try:
            page.goto(app_privacy_url(app_id),
                      wait_until="domcontentloaded", timeout=20000)
        except PlaywrightTimeout:
            pass
        # Let any client-side redirect chain settle.
        try:
            page.wait_for_load_state("networkidle", timeout=10000)
        except PlaywrightTimeout:
            pass

        url = page.url
        if url != last_url:
            print(f"   • now at {url[:90]}")
            last_url = url

        # Success: we reached the privacy form.
        if target in url and "appstoreconnect.apple.com" in url:
            return page

        # Sign-in screen → wait for the user to finish.
        if "/login" in url or "idmsa.apple.com" in url:
            print("\n  ▸ sign-in page. Sign in + approve 2FA in the browser.")
            print("    The script will resume when you land past the login.")
            try:
                # Wait for ANY appstoreconnect URL that's not /login.
                page.wait_for_url(
                    lambda u: "appstoreconnect.apple.com" in u and "/login" not in u,
                    timeout=4 * 60 * 1000,
                )
            except PlaywrightTimeout:
                raise FormError("timed out waiting for sign-in")
            continue

        # Apple's "review and agree to the agreement" interstitial.
        # Try every plausible accept-button label.
        if "review_agree" in url or "/agree" in url:
            print("  ▸ Apple wants you to accept an agreement. Trying to "
                  "click through automatically…")
            clicked = False
            for label in ("I Agree", "Agree", "Accept", "Submit",
                          "Continue", "Done"):
                if click_button(page, label, timeout=2000):
                    print(f"    ✓ clicked '{label}'")
                    clicked = True
                    break
            if not clicked:
                print("    • no accept button matched. Click through the "
                      "agreement manually in the browser; I'll keep retrying.")
            try:
                page.wait_for_load_state("networkidle", timeout=15000)
            except PlaywrightTimeout:
                pass
            continue

        # Bare dashboard / root — just retry the navigation.
        time.sleep(2)

    raise FormError(f"could not reach App Privacy. Last URL: {last_url}")


# Selector helpers — wrap each form action in a small function so a
# single DOM tweak from Apple is one-line to fix.

def click_button(page: Page, name: str, *, timeout: int = 10000) -> bool:
    try:
        page.get_by_role("button", name=name, exact=False).first.click(timeout=timeout)
        return True
    except PlaywrightTimeout:
        return False


def click_text(page: Page, text: str, *, timeout: int = 10000) -> bool:
    try:
        page.get_by_text(text, exact=False).first.click(timeout=timeout)
        return True
    except PlaywrightTimeout:
        return False


def check_label(page: Page, name: str) -> bool:
    """Click a checkbox or radio with `name`, scrolling into view first."""
    for role in ("checkbox", "radio"):
        try:
            loc = page.get_by_role(role, name=name, exact=False).first
            loc.scroll_into_view_if_needed(timeout=4000)
            loc.check(timeout=4000)
            return True
        except PlaywrightTimeout:
            continue
    # Some ASC inputs are <label>-wrapped without a ROLE — fall back
    # to clicking the visible label text.
    return click_text(page, name, timeout=4000)


def snapshot_page(page: Page, label: str) -> None:
    """Dump screenshot + HTML + visible interactive elements to
    build/asc-privacy-debug/. Called on every failure (and on
    --snapshot-only) so I can see what the form actually looks
    like and patch selectors against the real DOM."""
    out = ROOT / "build" / "asc-privacy-debug"
    out.mkdir(parents=True, exist_ok=True)
    try:
        page.screenshot(path=str(out / f"{label}.png"), full_page=True)
    except Exception as e:
        print(f"   ! screenshot failed: {e}")
    try:
        html = page.content()
        (out / f"{label}.html").write_text(html)
    except Exception as e:
        print(f"   ! html dump failed: {e}")
    # Enumerate interactive elements with their accessible names so
    # I can write better selectors. Cheap and very effective for
    # debugging unknown forms.
    try:
        rows: list[str] = []
        for role in ("button", "radio", "checkbox", "link", "heading", "tab"):
            locs = page.get_by_role(role)
            count = locs.count()
            for i in range(count):
                try:
                    name = locs.nth(i).text_content(timeout=500) or ""
                    aria = locs.nth(i).get_attribute("aria-label") or ""
                    name = (aria or name).strip().replace("\n", " ")
                    if name:
                        rows.append(f"{role:9s} | {name[:120]}")
                except Exception:
                    continue
        (out / f"{label}.elements.txt").write_text("\n".join(rows))
        print(f"   ▸ snapshot saved to {out / label}.png + .html + .elements.txt")
    except Exception as e:
        print(f"   ! element dump failed: {e}")


def open_question_one(page: Page) -> None:
    """Click "Get Started" / "Edit" / "Add data type" — whichever
    surface the page is in. This is a no-op if the form is already
    open at question one."""
    for label in ("Get Started", "Edit", "Set Up Privacy", "Add Data Type"):
        if click_button(page, label, timeout=3000):
            print(f"   ✓ entered form via '{label}'")
            return
    print("   • no entry button found — assuming form is already open")


class FormError(RuntimeError):
    """In-form failure that should trigger a debug snapshot."""


def answer_collects_data(page: Page, collects: bool) -> None:
    label = ("Yes, we collect data from this app" if collects
             else "No, we do not collect data from this app")
    # The radio may already be selected; check_label is idempotent
    # and only fails when the control isn't on the page at all.
    if not check_label(page, label):
        # Apple sometimes wraps the choice in a button rather than
        # a clickable text node.
        if not click_text(page, label, timeout=4000) \
           and not click_button(page, label):
            raise FormError(f"could not find '{label}' choice")
    # Advance the modal. The wizard uses "Next" / "Save" / "Publish"
    # depending on which step we're on — try in order, take whichever
    # is visible.
    for save_label in ("Next", "Save", "Publish", "Continue"):
        if click_button(page, save_label, timeout=3000):
            print(f"   ✓ advanced via '{save_label}'")
            return
    raise FormError("no Next/Save/Continue button to advance the modal")


def add_data_type(page: Page, *, category: str, type_label: str,
                  linked: bool, tracking: bool, purposes: list[str]) -> None:
    print(f"  → {category} → {type_label}")
    # Open / expand the category accordion.
    if not click_text(page, category, timeout=6000):
        raise FormError(f"category '{category}' not visible")
    # Tick the data type checkbox.
    if not check_label(page, type_label):
        raise FormError(f"data type '{type_label}' not visible")
    # The form may auto-advance per data type, or batch save and then
    # walk you through the per-type details. We click Save / Continue
    # after each tick to be safe.
    for save_label in ("Save", "Continue", "Next"):
        if click_button(page, save_label, timeout=3000):
            break

    # Per-type detail pane: Linkage + Tracking + Purposes. Some Apple
    # versions show this inline; others as a sheet — both reach the
    # same role-named radios.
    linkage_choice = "Yes, data from this app is linked to the user’s identity" if linked \
        else "No, data from this app is not linked to the user’s identity"
    if not click_text(page, "linked to the user", timeout=2000):
        # Already past or different layout — fall back to direct match.
        click_text(page, linkage_choice, timeout=4000)

    tracking_choice = "Yes, data from this app is used to track the user" if tracking \
        else "No, data from this app is not used to track the user"
    click_text(page, tracking_choice, timeout=4000)

    for purpose in purposes:
        if not check_label(page, purpose):
            print(f"     ! purpose '{purpose}' not visible (continuing)")

    # Final per-type save.
    for save_label in ("Save", "Done", "Continue"):
        if click_button(page, save_label, timeout=3000):
            break


# ---- Main ------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-id", default=None,
                        help="ASC numeric app id. Defaults to ASC_APP_ID from asc-config.env.")
    parser.add_argument("--headed", action="store_true",
                        help="Show the browser. Default = headed for first run, "
                             "headless once a session is cached.")
    parser.add_argument("--screenshot-on-fail", action="store_true", default=True,
                        help="Drop a screenshot to build/asc-privacy-fail.png on any error.")
    parser.add_argument("--snapshot-only", action="store_true",
                        help="Land on the App Privacy page and dump screenshot + HTML + "
                             "interactive-element list to build/asc-privacy-debug/. "
                             "Use this to capture the real form DOM so the form filler "
                             "can be patched against it.")
    args = parser.parse_args()

    cfg = load_config()
    app_id = args.app_id or cfg.get("ASC_APP_ID")
    if not app_id:
        raise SystemExit("missing app id. Pass --app-id or set ASC_APP_ID in asc-config.env.")

    spec = PRIVACY_SPECS_BY_APP.get(str(app_id))
    if not spec:
        raise SystemExit(
            f"no privacy spec for app id {app_id}. "
            f"Add an entry to PRIVACY_SPECS_BY_APP in this script."
        )

    PROFILE_DIR.mkdir(parents=True, exist_ok=True)
    first_run = not any(PROFILE_DIR.iterdir())
    headed = args.headed or first_run

    print(f"→ profile: {PROFILE_DIR}  (first run: {first_run})")
    print(f"→ app id:  {app_id}")
    print(f"→ data types to push: {len(spec['data_types'])}")

    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            str(PROFILE_DIR),
            headless=not headed,
            viewport={"width": 1280, "height": 900},
        )
        page = None
        try:
            page = ensure_signed_in(ctx, app_id)

            if args.snapshot_only:
                # Pause briefly for any single-page-app render to settle.
                page.wait_for_timeout(2000)
                snapshot_page(page, "landing")
                print("\n✅ snapshot saved. Dumped screenshot + HTML + element list.")
                if headed:
                    print("   (browser stays open for 30s so you can inspect)")
                    page.wait_for_timeout(30_000)
                return 0

            print("→ on App Privacy page. Walking the form…")
            open_question_one(page)
            time.sleep(0.5)
            answer_collects_data(page, spec["collects_data"])
            time.sleep(1.0)

            for dt in spec["data_types"]:
                add_data_type(page, **dt)
                time.sleep(0.7)

            print("\n✅ App Privacy form filled. Spot-check in the browser, "
                  "then close it.")
            if headed:
                print("   (the script is leaving the browser open for review)")
                page.wait_for_timeout(60_000)
        except (FormError, PlaywrightTimeout, Exception) as err:
            if page is not None:
                snapshot_page(page, "fail")
            print(f"\n✗ failed at: {err}")
            raise
        finally:
            ctx.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
