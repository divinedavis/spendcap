# Reply to App Review — Guideline 3.2.1(viii), submission a443b3fb (1.0 build 51)

Rejected 2026-09-16: "The account that submits the app must be enrolled in the
Apple Developer Program as an organization, and not as an individual."

Paste the text below into App Store Connect → the submission → Reply to App
Review. It argues the app performs no financial service itself; if Apple holds,
the only other path is converting the developer account to an organization
(D-U-N-S + legal entity, ~3–5 weeks), see the bottom of this file.

---

Hello,

Thank you for the review. I would like to ask you to reconsider the 3.2.1(viii)
classification, because Spendcap does not perform any financial service.

Guideline 3.2.1(viii) covers apps "used for financial trading, investing, or
money management," which "should be submitted by the financial institution
performing such services." Spendcap performs no such services and is not a
financial institution:

- It cannot move money. There is no payment, transfer, deposit, withdrawal,
  bill pay, card issuing, or peer-to-peer feature anywhere in the app, and no
  code path that initiates a transaction of any kind.
- It offers no lending, credit, investing, trading, brokerage, crypto, or
  insurance product, and gives no financial advice or recommendations.
- It holds no customer funds and opens no accounts.
- It is free, with no in-app purchases, subscriptions, or fees.

What the app actually does is read-only: with the user's explicit consent in
Plaid Link, it mirrors that user's own transaction history and shows it back to
them (this month's spending, the last twelve months, a self-set category
budget), and sends the user a push notification when the day's spending crosses
a daily cap the user typed in themselves. The bank relationship stays entirely
between the user, their bank, and Plaid; Spendcap never receives the user's
banking credentials, and the Plaid token is held server-side where the app
itself cannot read it.

On responsible data handling, which I understand is the concern behind the
guideline: every table is row-level-locked to the signed-in user, there are no
ads, no analytics SDKs and no third-party data sharing of any kind, financial
figures are hidden in the app switcher, and Settings > Delete account removes
the account and all of its data immediately.

If, having considered this, App Review still requires an organization
enrollment for this app, please confirm that explicitly and I will begin the
individual-to-organization conversion with Apple Developer Support rather than
resubmit.

Thank you,
Divine Davis

---

## If Apple holds (the organization path)

1. Form the legal entity (LLC/corp) — Apple verifies a real legal entity, not a
   DBA. NY LLCs carry the newspaper publication requirement; Delaware or NJ is
   cheaper if the entity does not have to be a NY one.
2. Free D-U-N-S via Apple's own look-up tool:
   https://developer.apple.com/enroll/duns-lookup/ — 1–5 business days. Do not
   pay D&B for expedited service.
3. Request the conversion (founder/co-founder only, keeps the existing account
   and its apps): https://developer.apple.com/contact/request/migrate-individual-account
   Apple phones to verify; allow up to three weeks.
4. Note Apple's warning: the vendor-name change resets `identifierForVendor`
   for existing users. Spendcap has no App Store users yet, so this costs
   nothing if it happens before release.
5. On the resubmission, re-run `scripts/seed_demo_account.py` first so the demo
   account's data reaches the new review date.

Worth doing either way, since the reviewer read the app as a financial-services
product: drop "Finance" from the App Store name ("Spendcap" alone was taken —
"Spendcap Budget" is the obvious replacement) and give the app its own domain
for the support and privacy URLs instead of divinedavis.com/spendcap/.
