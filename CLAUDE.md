# Spendcap — Project Context & Rules

Context file for Claude (and humans) working on this repo. Read this before making changes.

## What this app is

iOS SwiftUI app that connects to the user's bank via **Plaid**, tracks daily
spending against a user-set **daily cap**, and sends an APNs push when spending
crosses 80% ("getting close") and 100% ("over cap") of the cap.

- **Platform:** iOS 17+, SwiftUI, Swift 5.10
- **Backend:** Supabase — ref `gmzzbslcsswqjjswoaen` (auth + Postgres + edge functions, all RLS-enforced)
- **Bank data:** Plaid `transactions` product. **`PLAID_ENV=production` since
  2026-08-01** — real banks, real money, Trial plan (10 Production Items).
- **Local path:** `~/Desktop/Spendcap`
- **Bundle ID:** `com.divinedavis.spendcap`, team `CG89RY4W6R`
- **APNs:** reusable team key `NVH34S83TM` (`~/.appstoreconnect/private_keys/AuthKey_NVH34S83TM.p8`)

## Architecture

### Data flow

```
Plaid Link (iOS, LinkKit) 
  → plaid_create_link_token   edge fn (JWT-gated) → link token
  → onSuccess(public_token)
  → plaid_exchange_public_token edge fn (JWT-gated)
      → /item/public_token/exchange → access token stored in plaid_item_secrets
        (service-role only — NEVER granted to authenticated/anon)
      → /accounts/get → accounts rows
      → initial /transactions/sync
Plaid webhook (SYNC_UPDATES_AVAILABLE)
  → plaid_webhook edge fn (secret-gated) → sync_transactions logic
pg_cron hourly → sync_transactions edge fn (x-cron-secret) — fallback sync
after every sync → check_overspend:
  today's outflow total (user's timezone, positive amounts, pending included)
  vs budgets.daily_limit_cents → 80% warn push / 100% over push,
  deduped per (user, day, kind) in spend_alerts
```

### Tables (all RLS, self-only)

- `profiles` — timezone (IANA), created on first sign-in
- `plaid_items` — user-visible connection metadata + sync cursor
- `plaid_item_secrets` — Plaid access tokens; **service_role only, no client grants**
- `accounts`, `transactions` — Plaid mirrors; `amount_cents > 0` = money out
- `budgets` — daily_limit_cents (default $50), thresholds
- `device_push_tokens` — APNs tokens, self-only
- `spend_alerts` — alert dedupe log
- `delete_account()` RPC — App Store 5.1.1 account deletion

## Working rules — READ THESE

1. **Push to GitHub after every change.** Build first
   (`xcodebuild ... CODE_SIGNING_ALLOWED=NO`), commit only if green, `git add`
   specific files (never `-A` blindly), verify no secret files staged, push.
2. **Ship TestFlight after every app-code change** — `./scripts/ship.sh`
   (`SHIP_RUN_UI=1` to gate on UI tests too). ship.sh now runs
   `./scripts/smoke_test.sh` itself, so the launch gate is automatic
   (`SHIP_SKIP_SMOKE=1` to escape it when no simulator is free).
3. **Run `./scripts/run_tests.sh` before shipping.** Review whether each UI
   change needs a new XCUITest; note the decision in the commit message.
   Filters: `run_tests.sh unit MonthMathTests`,
   `run_tests.sh ui SpendcapUITests/testHomeAndTrendsTabs`.
4. **Never commit secrets.** Gitignored: `Secrets.xcconfig`,
   `scripts/asc-config.env`, `scripts/asc_api_key.p8`, `supabase/.env`.
   Scan staged files before every push.
5. **DB changes** go in `supabase/schema.sql` (canonical) AND a numbered file in
   `supabase/migrations/`, applied via the management API
   (`POST /v1/projects/gmzzbslcsswqjjswoaen/database/query`, PAT from keychain
   `supabase-pat-clockin`, non-default User-Agent or Cloudflare 403s, then
   `notify pgrst, 'reload schema'`).
6. **Every new table needs explicit GRANTs** (`authenticated` +
   `service_role`; `anon` select is fine — RLS default-denies).
7. **Regenerate the Xcode project after adding files:** `./scripts/generate.sh`.
   Never hand-edit `project.pbxproj`.
8. **Plaid access tokens live server-side only.** Any new table/view/function
   touching them must be service-role only; audit for the updatable-view RLS
   bypass before granting anything.

## Keychain entries

- `spendcap-supabase-db-password` — Postgres password
- `spendcap-supabase-anon` — anon key (also in `Secrets.xcconfig`)
- `spendcap-supabase-service-role` — service-role key (server-side only)
- `spendcap-plaid-client-id` / `spendcap-plaid-secret` — Plaid sandbox creds
  (pushed to Supabase function secrets via `./scripts/set_plaid_keys.sh`)
- `spendcap-plaid-secret-production` / `spendcap-plaid-redirect-uri` — the
  production half of the above; **both present and live since 2026-08-01**.
  `set_plaid_keys.sh production` reads these; the sandbox secret is untouched,
  so switching back is `./scripts/set_plaid_keys.sh sandbox`.
- `spendcap-test-account` — JSON `{email,password}` for XCUITest auto-sign-in
- `supabase-pat-clockin` — Supabase management API PAT

## Harness

| Script | What it does |
|---|---|
| `generate.sh` | Regenerate `.xcodeproj` from `project.yml` (run after adding files) |
| `run_tests.sh [unit\|ui\|all] [Class[/test]]` | Full sweep; gates every ship |
| `smoke_test.sh` | Build → install → cold-launch in a sim; proves the app starts |
| `capture_screenshots.sh` | Signed-in App Store / portfolio PNGs from XCUITest |
| `ship.sh` | tests → smoke → bump build → archive → TestFlight → verify testers |
| `register_in_asc.py` / `configure_internal_testers.py` | ASC bootstrap + tester group |
| `set_plaid_keys.sh` | Push keychain Plaid creds to Supabase function secrets |

### UI-test gotchas (both cost real debugging time — don't rediscover them)

- **Tab taps need `app.tapTab(_:in:)`**, not `tabBars.buttons[x].tap()`. On
  iOS 26's floating tab bar a plain `.tap()` reports success but does not
  change the selection. The helper in `UITestSupport.swift` falls back to a
  coordinate tap and confirms via `isSelected`.
- **`simctl launch` needs `ENABLE_DEBUG_DYLIB=NO`.** The default Xcode 26 Debug
  build makes a stub + `.debug.dylib` that `simctl` refuses with "denied by
  service delegate (SBMainWorkspace)" — which reads as a crash and isn't one.
- iOS may raise a **"Save Password?"** sheet after sign-in that swallows the
  next tap; `dismissSavePasswordPromptIfPresent()` clears it. It is
  intermittent, so it can't be reproduced on demand.

## Plaid OAuth (real banks)

Every major US bank — Chase, BofA, Wells Fargo, Capital One, US Bank, Schwab,
PNC — uses OAuth, which needs a `redirect_uri` that is both registered with
Plaid **and** a working iOS universal link. Built 2026-07-26; **fully live
since 2026-08-01** — nothing outstanding.

Redirect URI: **`https://divinedavis.com/spendcap/oauth/`** (trailing slash —
without it nginx 301s, and a redirect on the redirect URI is trouble).

| Piece | Where | State |
|---|---|---|
| AASA entry | `Personal-Website/.well-known/apple-app-site-association` → `/var/www/divinedavis` on 159.203.110.79 | done — **shared with Hidden Gems, merge never overwrite** |
| Landing page | `Personal-Website/spendcap/oauth/index.html` | done (200, no redirect) |
| Entitlement | `project.yml` → `applinks:divinedavis.com` | done |
| App ID capability | `scripts/asc_enable_associated_domains.py` | done (ASSOCIATED_DOMAINS on) |
| `redirect_uri` in link token | `plaid_create_link_token`, from `PLAID_REDIRECT_URI` | done — **secret set 2026-08-01** |
| Cold-launch resume | `PlaidLinkStore` + `resumeAfterTermination(from:)` | done |
| Register URI in Plaid dashboard | dashboard-only | done 2026-08-01 |

Plaid rejects an *unregistered* redirect URI with `INVALID_FIELD ... must be
configured in the developer dashboard`, which breaks bank linking *entirely*,
not just OAuth banks — verified live. So `redirect_uri` is sent only when
`PLAID_REDIRECT_URI` exists, and the URI must be registered at
dashboard.plaid.com → Developers → API → Allowed redirect URIs **first**. It is
now, for both environments.

```bash
./scripts/set_oauth_redirect.sh on     # sets it, verifies, auto-reverts on failure
./scripts/set_oauth_redirect.sh test   # check link-token creation any time
```

Verified live 2026-08-01: `/institutions/search` returns `ins_127991` Wells
Fargo with `oauth: true`, and `plaid_create_link_token` issues a
`link-production-…` token with the redirect attached.

Cold-launch resume matters because iOS can terminate the app during the bank
hand-off. LinkKit resumes on its own if the app survived; if not, it needs a
*new* handler built from the **same** link token followed by
`resumeAfterTermination(from:)` — hence the token in UserDefaults.

## Production — LIVE since 2026-08-01

Cutover done. `PLAID_ENV=production`, production secret in Supabase, all five
edge functions redeployed, redirect URI registered and on. Verified by the live
`plaid_create_link_token` returning a `link-production-…` token.

This team was created 2026-07-18, i.e. after the 2026-04-15 cutoff, so that
flow lands on a **Trial plan**: free, real production data, real production
keys, most OAuth institutions (Chase, BofA, Wells Fargo), and `transactions`
bundled along with seven other products. The cap is **10 Production Items,
consumed permanently** — deleting an Item does *not* give the slot back, so
never burn one on a throwaway test. Upgrading to a paid plan starts the
per-Item monthly subscription billing for `transactions`, and only the
products named in the Production request form carry over.

What the cutover ran (2026-08-01), in order — repeat this shape if the team
ever moves again:

1. `security add-generic-password -a divinedavis -s spendcap-plaid-secret-production -w '<secret>' -U`
2. Registered `https://divinedavis.com/spendcap/oauth/` under Developers > API
   in the Plaid dashboard, then stored it as `spendcap-plaid-redirect-uri`. The
   `applinks:divinedavis.com` AASA already publishes `/spendcap/oauth*` for
   `CG89RY4W6R.com.divinedavis.spendcap`.
3. `./scripts/set_plaid_keys.sh production` — preflights both the credentials
   and the redirect URI against `production.plaid.com` before writing anything.
4. Redeployed all five edge functions (the command is printed by step 3);
   `_shared/plaid.ts` reads `PLAID_ENV` at module load, so a running function
   keeps the old host until it is replaced.
5. `./scripts/set_oauth_redirect.sh on`.

**Still open after the cutover:**

- **Sandbox rows are orphaned.** `plaid_items`, `plaid_item_secrets`,
  `accounts`, `transactions`, `spend_alerts` still hold the First Platypus
  Bank item. Sandbox access tokens are meaningless in production, so
  `sync_transactions` will error on every one of them forever. Delete them.
- **No real bank linked yet.** Linking one spends 1 of the 10 Trial Items
  *permanently* — deleting the Item does not return the slot — so link the
  account you actually intend to keep, never a throwaway.

## Statements (shipped build 8, 2026-08-01)

Past-year statement PDFs, behind their own Plaid consent. `statements` is
bundled into the Trial plan, so there is no separate add-on cost.

**Consent is the whole story.** Statements is a distinct product from
transactions and the bank approves it separately — `/statements/list` against
an item linked for transactions only answers `ADDITIONAL_CONSENT_REQUIRED`. It
cannot be granted server-side. The user must go back through Link in **update
mode**: `access_token` + `products: ["statements"]` on `/link/token/create`
re-asks the bank against the *existing* item.

**Never exchange the public token in consent mode.** Update mode still hands
one back, and exchanging it mints a second Item — permanently consuming
another of the Trial plan's 10 slots. `PlaidLinkFlow.Mode.statementsConsent`
drops it deliberately and calls `syncStatements()` instead.

| Piece | Where |
|---|---|
| Consent token | `plaid_create_update_link_token` |
| List + download + store | `plaid_statements_sync` |
| Raw PDF fetch | `_shared/plaid.ts` → `plaidDownload` (the JSON `plaid()` helper throws on PDF bytes) |
| Schema + bucket | `0003_statements.sql` |
| UI | `Spendcap/Statements/StatementsView.swift`, reached from Settings |

**Security posture — these are the most sensitive bytes the app stores** (full
account numbers, not the 4-digit `accounts.mask`):
- Bucket `statements` is private; objects are `<uid>/<plaid_statement_id>.pdf`
- Storage policies compare `(storage.foldername(name))[1]` to `auth.uid()`.
  A bucket-level policy would let any signed-in user read every statement.
- Reads go through short-lived signed URLs, minted per tap — never cached
- `public.statements` has **no anon grant**, unlike the 0001 tables
- `delete_account()` clears the bucket first; `storage.objects` does not
  cascade from `auth.users`, so deletion would otherwise orphan the PDFs

**Cost guard:** `MAX_DOWNLOADS_PER_RUN = 30`. Plaid bills statements per
request, and accounts × 24 months could fan out into hundreds of paid calls
from a single tap. Runs are idempotent — already-fetched statements are
skipped, so a second pull picks up the remainder. A failed download still
writes a row with a null `storage_path` so the month shows as unavailable
rather than silently vanishing.

Still worth doing before this is a public feature: a retention policy and a
privacy-policy line covering stored statement PDFs.

## Known quirks

- Plaid sandbox: use institution `ins_109508` ("First Platypus Bank"),
  credentials `user_good` / `pass_good`. Fire test transactions with
  `/sandbox/item/fire_webhook` or `sandbox/transactions/create`.
- Plaid's returning-user phone screen (the first thing Link shows) **rejects
  real phone numbers in Sandbox** — a real number gives "Invalid phone number",
  which looks like an app bug but is not. Use a seeded test number:
  `415-555-0010` (new user) or `415-555-0011` (returning user), OTP `123456`.
  In **production** a real mobile works, but VoIP and landline numbers are
  still rejected — use a number that actually receives SMS.
  Nothing in our code sends `user.phone_number`; the screen comes from Link's
  returning-user experience, toggled in the Plaid dashboard's Link
  customization, not from `/link/token/create`.
- Edge functions deployed with `--no-verify-jwt` (webhook + cron fns) are gated
  by secret headers instead; JWT-gated fns (`plaid_create_link_token`,
  `plaid_exchange_public_token`) authenticate the Supabase session user.
- pg_net response bloat: if disk IO spikes, `TRUNCATE net._http_response`
  (see memory playbook).
