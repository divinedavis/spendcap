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
- **Local path:** `~/Desktop/projects/Spendcap`
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
pg_cron daily  → statements_cron edge fn (x-cron-secret) — new statement PDFs
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

**Widget swap, 2026-08-12 (user request):** the **"By category" card lives on
Trends**, directly under the chart card, and the month **Breakdown card moved
to the bottom of Months**, always showing the current month (Months' own
`monthStats`, built from the same `MonthMath` the Trends chart uses). The
category card had been on Months since 2026-08-03, when an earlier prompt-card
version was removed from Trends; it is back on Trends now as the full widget.
The cap is still edited from Months, which is where the UI tests reach it.

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

**The rent reserve (2026-08-12).** Trends' chart card shows a "free to spend"
figure: `monthCapCents − $2,000 − spentCents` (`MonthStats.rentReserveCents`,
current month only). The $2,000 is a hardcoded reserve at the user's request, and the
subtraction is safe from double-counting for a data reason worth keeping: rent
is paid **outside** the linked checking account — no rent-sized transaction has
ever posted through it — so it can never also appear in `spentCents`. If a
rent payment ever starts flowing through the linked account, this math starts
double-counting and needs a paid-this-month check.

**Debt-tagged lines join the reserve (2026-08-12, same day).** A budget line
tagged `kind = 'debt'` (0017) also comes out of that figure. The label is
"free to spend" on purpose — it names the answer, not the formula, so it must
not regrow into "left excl. rent & debts & …" as kinds get excluded (it
briefly was exactly that, build 37). Debts are the opposite data situation
from rent: Best Egg, Liberty Mutual and
the rest post **through** the linked account, so the full plan cannot be
reserved — the paid part is already inside `spentCents`. Only the *unpaid
remainder* is: `debtReserveCents = max(0, debtPlanned − debtSpent)`, clamped so
debt paid beyond its plan is not handed back. The figures come from the same
`category_spend()` rollup the "By category" card reads
(`CategoryMonth.debtPlannedCents/-SpentCents` → set on `MonthStats` in
`TrendsViewModel.load`, current month only); a failed rollup read degrades the
figure to rent-only rather than blanking it. Only lines the user *tagged*
count — a line merely named "Debts" is untagged and does not qualify.

**Category budgets (0007).** `budget_categories` (a planned amount per line) +
`category_rules` (what routes into it) + `category_spend(months_back)` /
`category_transactions(category, period)` / `seed_starter_budget()`. The
inline widget is on Trends (since 2026-08-12); the full Budget screen opens
from the Months toolbar and Settings.

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
- **Each line can carry a `kind` tag (0016)** — rent, food, transportation, …
  — picked in the edit-line sheet next to the free-text name. The name is what
  the user calls the line; the kind is what it *is*, so "which line is rent"
  is a field, not a guess parsed from "Rent / Wifi / Utilities". The value set
  is closed (`budget_categories_kind_check` + `CategoryKind`); an unknown kind
  decodes as untagged rather than failing the rollup. Untagged (null) is a
  valid state, never defaulted. **No icon on the budget rows** — one shipped in
  build 35 and was removed the same day at the user's request; the tag is for
  finding lines by what they are, not decoration.

**Tapping a budget line edits its planned amount**, on the Trends widget and
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

**Checking balance card (0015, 2026-08-12).** Months also shows what each month
did to the checking balance: start of the 1st → end of the last day, and the
difference. `monthly_balances()` derives every boundary backwards from the
*current* balance using posted transactions only — which only works because
`sync.ts` refreshes `accounts.current_balance_cents` on every sync run via a
cached `/accounts/get` (one call per item per run, not the billed real-time
Balance product). Do not remove that refresh: the link-time balance was 11 days
stale when this shipped, and every derived boundary drifts by exactly the spend
since capture. `/transactions/sync`'s own `accounts` array cannot be the anchor
— it only carries accounts with updates in that page and is empty on an idle
sync (verified live). Months before the first transaction on record are omitted
entirely; their balances would be invented, not derived.

**Trends breakdown shows a Mon–Thu average, and deliberately no weekend row
(2026-08-12).** The Mon–Thu average replaced the old average-per-day/projection
row. A "Weekend spend" (Sat+Sun) row shipped in build 31 and was removed the
same day: **Wells Fargo dates every weekend purchase to Monday** — zero Sat/Sun
rows across 530 transactions, Monday carrying ~3× any other day — and
`authorized_date` is no escape hatch: it mirrors the post date on 525 of 530
rows, and the 5 that differ shift weekday→weekday, never onto a weekend. So a
literal weekend bucket always reads $0 and Monday quietly includes the weekend.
Don't reintroduce a weekend split without a bank whose data can actually
express one. Weekdays are resolved in `MonthMath` where the timezone is known
(`DailySpend.weekday`) — a display-time `Calendar.current` lookup can shift a
midnight bucket onto the wrong day of the week.

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
| `asc_enable_capability.py <CAP>` | Toggle an App ID capability (`--list` to inspect) |
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

## Account deletion — was broken from 0003 until 0014 (2026-08-08)

**"Delete Account" deleted nothing for every build in between.** 0003 put a
Storage cleanup inside the RPC:

```sql
delete from storage.objects where bucket_id = 'statements' and ...;
delete from auth.users where id = uid;
```

Supabase guards `storage.objects` with a BEFORE DELETE trigger
(`protect_objects_delete` → `storage.protect_delete`) that raises **42501** on
any direct delete. The function aborted, the transaction rolled back, and the
user survived. The button showed an error and changed nothing — an App Store
**5.1.1(v)** feature that silently did not work. It surfaced only when a
reported account deletion turned out to have left all 594 transactions, the
Plaid item and the PDFs intact.

The reasoning in 0003 was right and only the mechanism was wrong: storage
genuinely does not cascade from `auth.users`. So the cleanup moved to the
client, where the Storage API is the only supported route:

1. `SpendService.deleteStoredStatements()` — lists `<uid>/` in the `statements`
   bucket and removes it, under the `statements_objects_delete_self` policy
   that has existed since 0003.
2. `delete_account()` — now a single `delete from auth.users`, which cascades
   every public table.

**That order is load-bearing.** Deleting the user first revokes the JWT that
authorises the storage delete and strands the PDFs — full account numbers —
in the bucket forever, which is exactly what 0003 set out to prevent.

Verified two ways before shipping: a scratch user created and deleted through
the REST API (204, user gone, rows cascaded), and
`testDeleteAccountRemovesTheAccount` driving the real button. That test is
**opt-in** (`SPENDCAP_TEST_DESTRUCTIVE=1`) because it deletes for real, and it
makes its own throwaway account rather than using the shared test account. It
signs that account up through the **API, not the form** — in sign-up mode the
password field is `.newPassword`, so iOS offers a strong password and swallows
`typeText`, and the form path would be testing AutoFill.

Note it left two strays behind while it was being written: the account is
created before the UI half runs, so a failure mid-test leaks one. Sweep for
`spendcap-deletetest-` addresses if a run fails.

**WorkComp+ has the identical bug** in `supabase/migrations/0004_delete_account.sql`
and is not fixed.

## Sign-in: email, Apple, Google (2026-08-08)

Three ways in. Apple and Google both go through **`signInWithIdToken`** — the
native sheet hands over an ID token and the app exchanges it directly. No web
redirect, so neither needs a Services ID, a client secret, or anything in
`uri_allow_list`. Email/password stays: the real account uses it and the
XCUITest harness signs in with it.

| Piece | Where |
|---|---|
| Rules + nonce (pure, unit-tested) | `Spendcap/Auth/SocialIdentity.swift` |
| Apple sheet | `Spendcap/Auth/AppleSignInService.swift` |
| Google sheet | `Spendcap/Auth/GoogleSignInService.swift` |
| Sign-in / link / unlink | `AuthViewModel` |
| Link UI | Settings → Account |
| App ID capability | `scripts/asc_enable_capability.py APPLE_ID_AUTH` |

**Linking is not a nicety, it is what stops a second account existing.**
Supabase auto-links a provider onto an existing user only when the email
matches *and* the provider verified it. Apple's **Hide My Email** issues a
`@privaterelay.appleid.com` address that will never match, so signing in with
Apple on an account created by email mints a **new, empty user** — while the
real one keeps the transactions and the Plaid Item that permanently consumed
one of ten Trial slots. Settings therefore links providers onto the *current*
user with `linkIdentityWithIdToken`, and that is the route to use on any
account that already holds data.

**Unlinking the last identity is refused** (`IdentityRules.canUnlink`, and the
UI doesn't offer it). Supabase will happily do it, and the result is an account
holding real bank history that nobody can ever sign into again.

**The nonce goes in two forms and swapping them is silent.** Apple signs
`SHA-256(nonce)` into the token's `nonce` claim; Supabase re-hashes the raw
value we send and compares. So the *request* gets the hash and the *exchange*
gets the raw string. Getting it backwards fails with a bare "invalid token"
that mentions nothing about nonces. `AuthNonce` is pinned to known SHA-256
vectors so the encoding can't drift.

**But the token does not always carry the claim.** Build 28 failed on device
with GoTrue's:

> Passed nonce and nonce in id_token should either both exist or not.

We asked Apple for a nonce and sent the raw value, and the returned token had
no `nonce` claim at all. GoTrue rejects that pairing outright. So
`AuthViewModel.appleCredentials` reads the claim out of the token
(`IDToken.stringClaim`) and sends the nonce **only when the claim is there** —
when it is, the nonce is still sent and still verified, which is the case that
carries the replay protection. Do not "simplify" this back to always sending
it; that is the bug. The decoding is unit-tested against base64url payloads of
every padding length, since a claim that fails to decode reads as absent.

**Google's ID token carries an `at_hash`**, so the access token must be sent
alongside it or the exchange is rejected — again with an error that doesn't
say why.

Three server-side settings, all applied, none discoverable from the app:

- `APPLE_ID_AUTH` on App ID `G267D9N944`. It **409s unless the POST carries
  `APPLE_ID_AUTH_APP_CONSENT: PRIMARY_APP_CONSENT`** — the only capability here
  that needs a `settings` block.
- `external_apple_enabled` + `external_apple_client_id` = the **bundle id**
  (native flows use the bundle id as the audience, not a Services ID).
- **`security_manual_linking_enabled`** — off by default, and `linkIdentity`
  fails without it.

**Google went live 2026-08-08** with iOS OAuth client
`755017954208-ue9ff7ocfktp7d699m0gbuj722t6kfi1`. `GOOGLE_CLIENT_ID` and
`GOOGLE_REVERSED_CLIENT_ID` come from `Secrets.xcconfig` (gitignored, so a
fresh clone builds with the button hidden rather than broken — that fallback is
deliberate, don't "fix" it by hardcoding the id). The reversed value is just
the client id's dot-components reversed, which is what the console labels "iOS
URL scheme". It must never be **empty**: it becomes a `CFBundleURLSchemes`
entry and an empty scheme **fails App Store validation at upload**, so it falls
back to the bundle id.

`external_google_enabled` + `external_google_client_id` are set on Supabase
with **no secret** — an iOS OAuth client doesn't have one, and the id-token
grant doesn't want one.

To check a Google client id without a browser, hit the authorize endpoint twice
and compare: the reversed-scheme redirect lands on Google's real sign-in page,
while an `https://` redirect comes back `redirect_uri_mismatch`. Only
iOS/Android clients accept a custom scheme, so that pair distinguishes an iOS
client from a Web one — which otherwise compiles fine and fails at runtime.

The sheets leave the app's process, so **XCUITest cannot drive either flow**.
What is tested instead: the auth screen still exposes a hittable email submit
under the new buttons, and Settings' identity list actually loads.

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
| List + download + store | `_shared/statements.ts` |
| On tap, one user | `plaid_statements_sync` (JWT-gated) |
| Daily, every user | `statements_cron` (`x-cron-secret`, `--no-verify-jwt`) |
| Raw PDF fetch | `_shared/plaid.ts` → `plaidDownload` (the JSON `plaid()` helper throws on PDF bytes) |
| Schema + bucket | `0003_statements.sql`; cron in `0013_cron_statements.sql` |
| UI | `Spendcap/Statements/StatementsView.swift`, reached from Settings |

**Ingestion is automatic since 2026-08-08 (`spendcap-daily-statements`, 16:45
UTC).** Until then nothing fetched statements on its own: `plaid_statements_sync`
is JWT-gated and only fired when someone opened the Statements screen, so a new
statement sat unfetched until the next visit — the July cycle was pulled by hand
on 2026-08-03 and nothing had run since.

**Daily, not monthly**, because a statement cycle belongs to the bank, not the
calendar. Wells Fargo posts around the 8th; a second bank would post on its own
day, and either can move. A monthly job would have to guess the date and would
silently skip a cycle whenever the guess was wrong. Daily costs only the
`/statements/list` call — downloads are what Plaid bills per request, and
already-fetched statements are skipped, so the steady state is one download per
account per cycle.

**Plaid's list lags the bank.** The statement Wells Fargo emailed on 2026-08-08
was not yet in `/statements/list` that afternoon (24 listed, 24 already stored).
That lag is the reason the sweep repeats daily rather than firing once on the
day the email lands.

**Narrowing it to the first half of the month was considered and rejected**
(2026-08-08). Depository cycles do close near the month boundary — both current
accounts are Wells Fargo checking/savings — but **credit-card closing dates are
assigned at account opening and spread deliberately across the whole month**, so
a `1-15` window would go quietly wrong the day a card is linked, fetching that
statement on the 1st instead. It also saves almost nothing: the back half of the
month is `/statements/list` calls, and **list is not what Plaid bills —
downloads are**. Do not re-narrow this without a reason that survives both
points.

**Security posture — these are the most sensitive bytes the app stores** (full
account numbers, not the 4-digit `accounts.mask`):
- Bucket `statements` is private; objects are `<uid>/<plaid_statement_id>.pdf`
- Storage policies compare `(storage.foldername(name))[1]` to `auth.uid()`.
  A bucket-level policy would let any signed-in user read every statement.
- Reads go through short-lived signed URLs, minted per tap — never cached
- `public.statements` has **no anon grant**, unlike the 0001 tables
- `delete_account()` clears the bucket first; `storage.objects` does not
  cascade from `auth.users`, so deletion would otherwise orphan the PDFs

**Cost guard: two caps, and the difference is the point.** The tap allows 30
downloads a run — accounts × 24 months could otherwise fan out into hundreds of
paid calls from a single pull. The cron allows **6**: an unattended job should
pick up the cycle that just posted (two accounts = 2) with headroom to catch up
after an outage, and never backfill a year nobody asked for. Backfill stays
behind the pull-to-refresh, where the billing is a decision someone made.
Refs are sorted newest-first, which is what makes the small cap safe — the
month that just posted is the first thing a run reaches.

Runs are idempotent — already-fetched statements are skipped, so a second pull
picks up the remainder. A failed download still writes a row with a null
`storage_path` so the month shows as unavailable rather than silently vanishing.

**One item's failure must not end the sweep.** `syncAllStatements` catches per
item: a revoked bank would otherwise stop statements arriving for every other
user. `ADDITIONAL_CONSENT_REQUIRED` is counted as `awaitingConsent`, not an
error — an item linked for transactions only is a normal steady state, and
consent can only be granted from the app, so there is nothing for the cron to
alert about.

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
