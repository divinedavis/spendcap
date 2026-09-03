#!/usr/bin/env python3
"""Write the App Store listing for Spendcap through the API.

Everything App Store Connect accepts over its API lives here, so the listing
is a file in the repo rather than a memory of which boxes were ticked in a web
form: categories, subtitle, description, keywords, URLs, copyright, the age
rating questionnaire, the review contact + demo account + notes, and the price.

Idempotent — every call is a PATCH or an upsert, so re-running after an edit
just re-states the listing.

    python3 scripts/asc_metadata.py            # apply
    python3 scripts/asc_metadata.py --show     # print what is there now

Two things Apple does NOT expose over the public API:

  * App Privacy (the data-collection questionnaire) — see
    scripts/asc_push_privacy_labels.py, which drives the web form.
  * Submitting for review — scripts/asc_submit_for_review.py uses the
    reviewSubmissions resource, which does work.

The demo account is the XCUITest account (`spendcap-test-account` in the
keychain), which scripts/seed_demo_account.py fills with a synthetic bank so a
reviewer sees real screens without being able to link a bank in production.
The review contact's phone number is a real person's, and this repo is public,
so it comes from the gitignored asc-config.env:
    ASC_CONTACT_FIRST_NAME / ASC_CONTACT_LAST_NAME
    ASC_CONTACT_PHONE      / ASC_CONTACT_EMAIL
"""
from __future__ import annotations

import json
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from asc import ASC, load_config  # noqa: E402

API = "https://api.appstoreconnect.apple.com/v1"

SUBTITLE = "Daily spending cap alerts"                 # <= 30 characters
KEYWORDS = ("budget,spending,daily budget,bank,plaid,overspending,"
            "money,expense tracker,cap,alerts,finance")   # <= 100 characters
PROMO = ("Set one number for the day. Spendcap watches your bank and taps you on "
         "the shoulder at 80% and 100%, while there is still time to stop.")
SITE = "https://divinedavis.com/spendcap/support/"
PRIVACY = "https://divinedavis.com/spendcap/privacy/"
COPYRIGHT = "2026 Divine Davis"
PRIMARY_CATEGORY = "FINANCE"
SECONDARY_CATEGORY = "PRODUCTIVITY"

DESCRIPTION = """Most budgeting apps tell you what you overspent on last month. Spendcap tells you at 3pm today, while you can still do something about it.

ONE NUMBER
Set a daily cap. Connect your bank. Spendcap mirrors your transactions in the background and sends a notification when the day reaches 80% of the cap ("getting close") and again at 100% ("over cap"). One of each per day, never more.

YOUR BANK, SECURELY
Banks connect through Plaid, the same service used by thousands of financial apps. Your online banking login goes to Plaid, never to Spendcap. The credentials Plaid issues are held server-side in a place the app itself can never read.

THE MONTH AT A GLANCE
- Trends: this month's spending day by day, a category budget with a planned amount per line, and rules that file each merchant where you want it. Move one transaction and the app remembers for next time.
- Activity: every transaction this month, newest first, money in and money out.
- Months: twelve months of totals, the change from the month before, what each month did to your checking balance, and the bank statement behind each one.
- Debt: every recurring obligation as its own row, grouped and subtotalled, with what actually posted against it this month beside what you planned. Tap a row to see the charges.
- Trips: a named budget for a holiday or an event with its own cost lines. Spending you assign to a trip leaves the daily cap, so a hotel booking cannot fire an over-cap alert you can do nothing about.

BUILT FOR REAL BANK DATA
Bank data settles over hours, and some banks date every weekend purchase to Monday. Spendcap is designed around that: it checks for new transactions every hour and whenever your bank reports a change, and it never presents a partial figure as a final one.

PRIVATE BY DESIGN
No ads, no analytics, no data brokers. Every table is locked to your own account. Financial figures are hidden from the app switcher. Delete your account and everything with it from Settings, any time.

Sign in with Apple, Google, or an email address.
"""

REVIEW_NOTES = """WHAT THE APP DOES
Spendcap connects to a user's bank account through Plaid and sends a push notification when the day's spending crosses a cap the user set. The tabs show this month's spending, every transaction, twelve months of totals, recurring obligations, and trip budgets.

DEMO ACCOUNT - PLEASE READ
Plaid is running in PRODUCTION mode, which has no test institutions, so a reviewer cannot link a bank during review. The demo account above is therefore pre-populated with a synthetic bank connection ("First Demo Bank", tagged "Demo" under Settings > Linked accounts) carrying five months of realistic transactions, a category budget, and Debt tab items. Every screen shows real data on that account with nothing to set up.

Sign in with "Continue with email" on the first screen using the demo credentials. Sign in with Apple and Google also work but would create a fresh, empty account.

Settings > "Connect a bank" opens the real Plaid Link flow; without real bank credentials it cannot complete, which is expected. The demo account already has its bank connected.

NOTIFICATIONS
The 80% / 100% alerts fire from the server when new transactions post, so they will not appear on demand during a short session. The threshold logic is visible on Months ("Adjust cap") and the daily cap on the demo account is $50.

ACCOUNT DELETION
Settings > Delete account removes the account and all of its data immediately (Guideline 5.1.1). Deleting the demo account would wipe the demo data, so please test that on an account you create rather than the demo login.

CONTACT
Any question at all: the email and phone number above.
"""

# Nothing in a personal-finance app is age-gated. Apple's newer questionnaire
# fields (advertising, messagingAndChat, userGeneratedContent, ...) are
# BOOLEANs; the older content fields are three-value enums. Sending "NONE" to a
# boolean field fails with ENTITY_ERROR.ATTRIBUTE.TYPE, and omitting any field
# fails with ATTRIBUTE.REQUIRED. All of them go in one PATCH.
AGE_RATING = {
    "alcoholTobaccoOrDrugUseOrReferences": "NONE",
    "contests": "NONE",
    "gamblingSimulated": "NONE",
    "gunsOrOtherWeapons": "NONE",
    "horrorOrFearThemes": "NONE",
    "matureOrSuggestiveThemes": "NONE",
    "medicalOrTreatmentInformation": "NONE",
    "profanityOrCrudeHumor": "NONE",
    "sexualContentGraphicAndNudity": "NONE",
    "sexualContentOrNudity": "NONE",
    "violenceCartoonOrFantasy": "NONE",
    "violenceRealistic": "NONE",
    "violenceRealisticProlongedGraphicOrSadistic": "NONE",
    "advertising": False,
    "ageAssurance": False,
    "gambling": False,
    "healthOrWellnessTopics": False,
    "lootBox": False,
    "messagingAndChat": False,
    "parentalControls": False,
    "unrestrictedWebAccess": False,
    "userGeneratedContent": False,
    "ageRatingOverride": "NONE",
}

EDITABLE_STATES = ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED",
                   "REJECTED", "METADATA_REJECTED")


def demo_account() -> tuple[str, str]:
    """The XCUITest account's email + password, from the keychain (JSON)."""
    out = subprocess.run(
        ["security", "find-generic-password", "-s", "spendcap-test-account", "-w"],
        capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit("no keychain item 'spendcap-test-account'")
    creds = json.loads(out.stdout.strip())
    return creds["email"], creds["password"]


def resolve(asc: ASC, app_id: str) -> dict:
    info = asc.get(f"/apps/{app_id}/appInfos")["data"][0]
    versions = asc.get(f"/apps/{app_id}/appStoreVersions", limit=10)["data"]
    editable = [v for v in versions if v["attributes"]["appStoreState"] in EDITABLE_STATES]
    if not editable:
        raise SystemExit("no editable App Store version — every version is already submitted")
    version = editable[0]
    return {
        "info": info["id"],
        "info_loc": asc.get(f"/appInfos/{info['id']}/appInfoLocalizations")["data"][0]["id"],
        "version": version["id"],
        "version_string": version["attributes"]["versionString"],
        "version_loc": asc.get(
            f"/appStoreVersions/{version['id']}/appStoreVersionLocalizations")["data"][0]["id"],
    }


def apply(asc: ASC, cfg: dict) -> None:
    assert len(SUBTITLE) <= 30, "subtitle over 30 chars"
    assert len(KEYWORDS) <= 100, "keywords over 100 chars"
    assert len(PROMO) <= 170, "promotional text over 170 chars"
    assert len(DESCRIPTION) <= 4000, "description over 4000 chars"

    app_id = cfg["ASC_APP_ID"]
    ids = resolve(asc, app_id)
    print(f"==> version {ids['version_string']}")

    asc.patch(f"/apps/{app_id}", {"data": {
        "type": "apps", "id": app_id,
        "attributes": {"contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"}}})
    print("    content rights")

    asc.patch(f"/appInfos/{ids['info']}", {"data": {
        "type": "appInfos", "id": ids["info"], "relationships": {
            "primaryCategory": {"data": {"type": "appCategories", "id": PRIMARY_CATEGORY}},
            "secondaryCategory": {"data": {"type": "appCategories", "id": SECONDARY_CATEGORY}}}}})
    print(f"    categories {PRIMARY_CATEGORY} / {SECONDARY_CATEGORY}")

    asc.patch(f"/appInfoLocalizations/{ids['info_loc']}", {"data": {
        "type": "appInfoLocalizations", "id": ids["info_loc"],
        "attributes": {"subtitle": SUBTITLE, "privacyPolicyUrl": PRIVACY}}})
    print("    subtitle + privacy policy URL")

    asc.patch(f"/appStoreVersionLocalizations/{ids['version_loc']}", {"data": {
        "type": "appStoreVersionLocalizations", "id": ids["version_loc"],
        "attributes": {"description": DESCRIPTION, "keywords": KEYWORDS,
                       "promotionalText": PROMO, "supportUrl": SITE,
                       "marketingUrl": "https://divinedavis.com/portfolio.html"}}})
    print("    description, keywords, URLs")

    asc.patch(f"/appStoreVersions/{ids['version']}", {"data": {
        "type": "appStoreVersions", "id": ids["version"],
        "attributes": {"copyright": COPYRIGHT, "usesIdfa": False}}})
    print("    copyright, IDFA declaration")

    asc.patch(f"/ageRatingDeclarations/{ids['info']}", {"data": {
        "type": "ageRatingDeclarations", "id": ids["info"], "attributes": AGE_RATING}})
    print("    age rating (4+)")

    detail = asc.get(f"/appStoreVersions/{ids['version']}/appStoreReviewDetail").get("data")
    missing = [k for k in ("ASC_CONTACT_FIRST_NAME", "ASC_CONTACT_LAST_NAME",
                           "ASC_CONTACT_PHONE", "ASC_CONTACT_EMAIL") if not cfg.get(k)]
    if missing:
        raise SystemExit("asc-config.env is missing: " + ", ".join(missing))
    email, password = demo_account()
    attributes = {
        "contactFirstName": cfg["ASC_CONTACT_FIRST_NAME"],
        "contactLastName": cfg["ASC_CONTACT_LAST_NAME"],
        "contactPhone": cfg["ASC_CONTACT_PHONE"],
        "contactEmail": cfg["ASC_CONTACT_EMAIL"],
        "demoAccountName": email, "demoAccountPassword": password,
        "demoAccountRequired": True, "notes": REVIEW_NOTES,
    }
    if detail:
        asc.patch(f"/appStoreReviewDetails/{detail['id']}", {"data": {
            "type": "appStoreReviewDetails", "id": detail["id"], "attributes": attributes}})
    else:
        asc.post("/appStoreReviewDetails", {"data": {
            "type": "appStoreReviewDetails", "attributes": attributes,
            "relationships": {"appStoreVersion": {
                "data": {"type": "appStoreVersions", "id": ids["version"]}}}}})
    print("    review contact + demo account + notes")

    # Free, USA as the base territory. An existing schedule is left alone —
    # replacing it would reset any scheduled price change.
    # A schedule object can exist with a base territory and NO prices (this
    # app had exactly that, and Apple refused the submission with
    # APP_PRICING_REQUIRED), so check the prices, not the schedule.
    existing = asc.s.get(f"{API}/appPriceSchedules/{app_id}/manualPrices", timeout=30)
    if existing.status_code == 200 and existing.json().get("data"):
        print("    price schedule already set — left alone")
        return
    points = asc.get(f"/apps/{app_id}/appPricePoints",
                     **{"filter[territory]": "USA", "limit": 200})["data"]
    free = next(p for p in points if float(p["attributes"]["customerPrice"]) == 0.0)
    asc.post("/appPriceSchedules", {
        "data": {"type": "appPriceSchedules", "relationships": {
            "app": {"data": {"type": "apps", "id": app_id}},
            "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
            "manualPrices": {"data": [{"type": "appPrices", "id": "${free}"}]}}},
        "included": [{"type": "appPrices", "id": "${free}", "attributes": {"startDate": None},
                      "relationships": {"appPricePoint": {
                          "data": {"type": "appPricePoints", "id": free["id"]}}}}]})
    print("    price: free")


def show(asc: ASC, cfg: dict) -> None:
    app_id = cfg["ASC_APP_ID"]
    ids = resolve(asc, app_id)
    loc = asc.get(f"/appStoreVersionLocalizations/{ids['version_loc']}")["data"]["attributes"]
    info_loc = asc.get(f"/appInfoLocalizations/{ids['info_loc']}")["data"]["attributes"]
    version = asc.get(f"/appStoreVersions/{ids['version']}")["data"]["attributes"]
    detail = asc.get(f"/appStoreVersions/{ids['version']}/appStoreReviewDetail").get("data")
    build = asc.get(f"/appStoreVersions/{ids['version']}/build").get("data")
    print(f"version {version['versionString']}  {version['appStoreState']}")
    print(f"  subtitle     {info_loc['subtitle']}")
    print(f"  description  {len(loc['description'] or '')} chars")
    print(f"  keywords     {loc['keywords']}")
    print(f"  support      {loc['supportUrl']}")
    print(f"  privacy      {info_loc['privacyPolicyUrl']}")
    print(f"  copyright    {version['copyright']}")
    print(f"  build        {build['attributes']['version'] if build else '(none attached)'}")
    print(f"  review info  {'set' if detail else 'MISSING'}")


def main() -> None:
    cfg = load_config()
    asc = ASC(cfg)
    (show if "--show" in sys.argv else apply)(asc, cfg)


if __name__ == "__main__":
    main()
