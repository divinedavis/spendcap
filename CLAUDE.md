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

### Tabs

**Trends · Activity · Months · Trips · Settings.** Trips arrived 2026-08-06
(see below). Home was removed 2026-08-03 — its
hero card, today's activity list and suggested-actions carousel are gone, and
Trends took the landing slot. **Connecting a bank moved to Settings** in the
same change: Home held the only entry into Plaid Link, so deleting it without
that would have left no way to add an account.

**Trends' period chip filters three months** — this one and the previous two
(`TrendsPeriod`, 2026-08-05). Three, not twelve, because Months already owns
the year and the bank rarely shares much more history than this. The whole
period resolves to one reference date that drives both the fetch and the math,
so the rows pulled and the days charted cannot describe different months. A
finished month is read as of its **last day**, not today, or `MonthMath` would
stop the series mid-month and report a July that ended on the 5th. The month
walk steps back a day at a time rather than adding `-1 month`, which has to
clamp on the 31st.

The category-budget prompt card that sat under the chart was removed
2026-08-03 at the user's request; the cap is still edited from Months, which is
where the UI tests reach it.

**Activity** is the month, transaction by transaction, from
`month_activity(period)` (0009). It is the one rollup that does *not* filter to
outflows — money in is activity, and hiding a refund would make the list
disagree with the statement it mirrors. Inflows carry a null `category_name`
rather than "Uncategorized", which on that screen would read as a gap to fix.

Previously:

**Home · Trends · Months · Settings.** The **Today** tab (the daily ring) was
removed 2026-08-02: bank data settles over hours to days, so "spent today" was
always a partial figure presented as a live one. The daily cap itself is
untouched — it still drives `check_overspend`, the 80/100% pushes, and the Home
hero card. `BudgetMath` and its tests stay as the mirror of the server math.

**Months** is the 12-month view. Totals come from `monthly_spend(months_back)`
(0005), a `security invoker` SQL function that aggregates in Postgres — a year
of rows would blow past PostgREST's 1000-row default cap, and the client only
needs twelve sums. Its outflow filter must stay identical to
`overspend_status()` and `BankTransaction.countsTowardDailyCap`; month totals
that disagree with the day totals behind the pushes are worse than no totals.
`YearMath.stats` adds what only the client knows (per-month cap, change,
partial current month) and is unit-tested in `YearMathTests`.

**Two caps, two jobs (0006).** `budgets.daily_limit_cents` is the push
threshold and is the only one `check_overspend` reads.
`budgets.monthly_limit_cents` is optional, nullable, and read by the app only —
it is what a whole month is judged against on Months and Trends. Null falls
back to daily × days in the month, which is the wrong yardstick the moment rent
or an annual bill lands on one day and turns every month red. Both screens must
resolve it through `Budget.capCents(daysInMonth:)` / `MonthStats.monthCapCents`
so they can never disagree. Nothing pushes on the monthly cap yet — that would
need a server-side counterpart in `check_overspend`.

**Category budgets (0007).** `budget_categories` (a planned amount per line) +
`category_rules` (what routes into it) + `category_spend(months_back)` /
`category_transactions(category, period)` / `seed_starter_budget()`. Reached
from Months → Budget by category.

- **Rules live in the database, not in Swift.** The mapping is personal and
  wrong out of the box: this account has a steakhouse under `GENERAL_SERVICES`
  and $5.7k of Airbnb under `TRAVEL`. Plaid's `personal_finance_category` is
  the first pass, merchant rules are the correction.
- **Precedence: merchant beats category, longer match beats shorter.** Changing
  that ordering silently re-buckets months of history.
- **Unmatched spending is an explicit Uncategorized line**, never dropped. It
  is excluded from the planned total (it has no plan) and included in the spent
  total (the money left the account). Getting that backwards makes the budget
  look either bigger or cheaper than it is.
- `seed_starter_budget()` is a no-op once any category exists, so a double tap
  cannot duplicate the budget.
- Every rollup here reuses the same outflow filter as `overspend_status()`.

**Tapping a budget line edits its planned amount**, on the Months widget and
on the Budget screen. If a tap there ever seems to do nothing in a UI test,
suspect the layout rather than the control: the widget appears only once the
category rollup lands, and a touch dispatched while the card is still being
laid out arrives where the row *used* to be. Wait for the row's frame to stop
moving before tapping. Several entry points were wrongly diagnosed as dead
buttons before this was understood.

**Reassigning a merchant is in the app** (Budget > a line > tap a transaction).
It writes a `merchant_contains` rule, upserted on `(user_id, match_type,
match_value)` so a merchant can only ever have one home. Rules are applied at
*read* time by the rollups, so a reassignment re-buckets every month on record
— that is intended: a merchant filed wrongly was filed wrongly in April too.

Still to build: per-category push alerts.

Anything that opens `BudgetView` must pass the **real** `Budget` row, never one
rebuilt from stats: saving a reconstructed one resets `warn_pct` and wipes the
monthly cap, since `updateBudget` upserts every column.

Two rules that shaped that screen and are easy to undo by accident:

- **A month with no rows is not a month with no spending.** Plaid only shares
  history back to what the bank gives (this account: ~3 months), so months
  before the first transaction on record are drawn as "no data", never as $0.
- **Months never calls Plaid.** It reads the `statements` table to link a month
  to its PDF, but fetching statements stays on the Statements screen, where the
  per-request Plaid billing is behind a deliberate tap.

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
5. **DB changes** go in `supabase/schema.sql` (canonical — it had drifted to
   0002 and was brought back in sync through 0005 on 2026-08-02) AND a
   numbered file in
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

## Trips and events (0010, shipped 2026-08-06)

A fifth tab. A trip is a named budget with its own cost lines — flights, hotel,
food, anything the user adds — that is **planned and actual at once**:
`trip_lines` holds what you expect to spend, `trip_transactions` records which
real rows you put on the trip, and the screen shows the drift between them.

**Trip spending leaves the daily cap.** `overspend_status()` skips any
transaction assigned to a trip. A $780 hotel would blow any daily cap and fire
an over-cap push the user can do nothing about, and an alert that fires on
unactionable news stops being read. The trip is judged against its own budget
instead: an explicit `budget_cents` if set, otherwise the sum of the planned
lines, and **nil when neither exists** — "no budget" is not "0% of zero".

**Assignment is explicit, per transaction, and that is load-bearing.** A trip's
dates only *suggest* (`trip_candidates`); they never claim. Excluding a date
range automatically would silently switch the app's core feature off for the
length of a holiday — precisely the days most likely to overspend. Every
excluded row is one the user tapped. `trip_transactions.transaction_id` is the
primary key, so a row can be on at most one trip and cannot leave the cap twice.

**Months, Trends and Activity are unaffected** and still count trip spending.
They report what left the account; hiding it there would make the app disagree
with the bank statement it mirrors. This is the one place the "identical outflow
filter" rule bends, and only for `overspend_status()` — the filter itself
(`is_removed = false`, `amount_cents > 0`, `not (pending and is_backfill)`) is
still shared by every trip rollup.

**Ticking a line off as paid (0012).** `trip_lines.settled_at` — a timestamp,
null = outstanding. A trip line is half budget, half checklist, and plenty of it
gets paid on a card the app can't see, months ahead, or by someone else, so
"handled" cannot be inferred from the transactions we mirror; the user asserts
it. It **never feeds a total**: the trip's spend still means "money we watched
leave the account", and letting a checkbox inflate it would make the one honest
figure on the screen a mix of fact and intention. The count is shown separately
("1 of 5 done"). The unfiled rollup row is not settleable — nobody created it.

Two things this cost, worth not rediscovering:
- `settled_at` made `trip_line_spend` change its return type, which Postgres
  refuses to `create or replace` (42P13). Migration 0012 drops it first, in the
  same batch so PostgREST never sees a gap.
- PostgREST returns `timestamptz` as `2026-08-07T18:50:51.08808+00:00` —
  **five** fractional digits and a `+00:00` offset. `ISO8601DateFormatter` with
  `.withFractionalSeconds` wants exactly three and returns nil, and Postgres
  trims trailing zeroes so the count varies row to row. `TripDecoding.timestamp`
  strips the fraction and retries; `TripMathTests` pins the real wire string.
  Getting this wrong makes every ticked line silently read as unticked.

Deleting a trip, or a line, never deletes money that was spent: the trip's
charges go back to counting against the daily cap, and a deleted line's charges
fall into the trip's unfiled row (`line_id` nulls via the FK).

Verified live end-to-end before shipping, on seeded data: $780 hotel + $6 coffee
against a $50 cap → assign the hotel → `overspend_status()` reports $6 and no
push fires; unassigning and deleting the trip each restore it.

**No edge-function redeploy was needed for the exclusion.** `checkOverspend` in
`_shared/sync.ts` calls `rpc("overspend_status")`, so replacing the SQL function
changes the push path immediately — unlike `PLAID_ENV`, which is read at module
load and does need a redeploy.

**0011 revoked `anon` INSERT/UPDATE/DELETE across `public`.** Supabase's stock
`alter default privileges` grants `all` to `anon` on every new table, so all
twelve had them. Nothing was exploitable — RLS is on everywhere and every policy
is `user_id = auth.uid()`, which is NULL for anon — but the grant layer should
not be the only thing behind RLS. `select` is left alone.

## Brand mark

Three spending bars rising toward a hard cap rule — green bars (the
AccentColor), amber rule (the 80% warn colour), near-black field. It replaced
the needle gauge on 2026-08-06; the gauge depicted the Today ring, which came
out of the app in build 10.

The mark exists **twice on purpose**: `scripts/make_icon.py` rasterises it to
the app icon and `marketing/`, and `SpendcapMark` redraws it as SwiftUI vectors
for the sign-in screen and the Settings footer. `make_icon.py --check` compares
the two sets of numbers and `run_tests.sh` runs it, so editing one and not the
other fails the sweep instead of shipping two different logos. Never hand-edit
`icon-1024.png` — regenerate it.

**The launch screen is deliberately unbranded.** `UILaunchScreen`'s
`UIImageName` scales its image to fill the screen rather than centring it at a
natural size, so it cannot be matched to `LaunchPlaceholderView` — and those
two disagreeing is the exact flash the cold-start work removed.

**The ASC header icon comes from the build attached to the App Store version**,
not from TestFlight uploads. Twenty-two TestFlight builds all carried an icon
and appstoreconnect.apple.com still showed the placeholder grid, because
version 1.0 had no build selected. Uploading is not enough:

```bash
python3 scripts/attach_build.py            # newest VALID build -> version 1.0
python3 scripts/attach_build.py --dry-run  # just report what is attached now
```

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
| `make_icon.py [--check]` | Redraw the logo (app icon + `marketing/`); `--check` gates `run_tests.sh` |
| `run_tests.sh [unit\|ui\|all] [Class[/test]]` | Full sweep; gates every ship |
| `smoke_test.sh` | Build → install → cold-launch in a sim; proves the app starts |
| `capture_screenshots.sh` | Signed-in App Store / portfolio PNGs from XCUITest |
| `ship.sh` | tests → smoke → bump build → archive → TestFlight → verify testers |
| `register_in_asc.py` / `configure_internal_testers.py` | ASC bootstrap + tester group |
| `attach_build.py` | Attach the newest build to the App Store version (drives the ASC icon) |
| `apply_migration.py [--verify]` | Apply a migration via the management API, then reload PostgREST |
| `set_plaid_keys.sh` | Push keychain Plaid creds to Supabase function secrets |

### UI-test gotchas (both cost real debugging time — don't rediscover them)

- **An accessibility identifier on a row overwrites its children's.** SwiftUI
  pushes a container's identifier down onto every descendant, so
  `.accessibilityIdentifier("trip.line")` on a `List` row renamed the paid
  checkbox inside it from `trip.lineCheck` to `trip.line` and made it
  unfindable — the control was on screen and tappable the whole time. Put
  identifiers on the controls, not the row.
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
- **A coordinate tap opens a Button but never a SwiftUI `Menu`.** This inverts
  the workaround above, so it is easy to "fix" backwards. Measured on the
  Trends period chip: the coordinate tap lands and nothing opens — no menu
  anywhere in the app's *or* SpringBoard's hierarchy. Only a real `.tap()`
  opens one, and `.tap()` checks hittability first, which flickers while the
  landing tab's chart lays out. Settle the frame, real-tap, retry.
- **The navigation bar's scroll-edge effect eats touches at the top of a
  `ScrollView`.** On iOS 26 it reaches past the bar's own frame into the first
  ~12pt of content. Trends' chips row sat flush against it and its new period
  menu was untappable — by XCUITest *and* by a finger — until the content got
  `.padding(.top, 12)`. Nothing up there had been interactive before, so
  nothing had caught it. Suspect this for any control in that strip.

### Cold start

The app must never show the sign-in screen to someone who is already signed in.
Two things keep that true and both are load-bearing:

- `AuthViewModel.init` seeds `session` from `client.auth.currentSession`, which
  is a synchronous read of local storage, so the first frame already knows.
- The client sets **`emitLocalSessionAsInitialSession: true`**. Without it the
  SDK refreshes the (hour-long) access token over the network *before* emitting
  `.initialSession` — so on nearly every cold start the app spent a round trip
  believing it was signed out. The refresh still happens in the background, and
  requests await a valid token anyway; a session the server has actually killed
  still lands on sign-in via the cleanup `.signedOut`.

`AuthPhase` makes the third state explicit: `restoring` is not `signedOut`, and
it draws `LaunchPlaceholderView`, which is deliberately identical to the launch
screen so there is nothing to flash.

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
