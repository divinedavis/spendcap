# Spendcap — Project Context & Rules

Context file for Claude (and humans) working on this repo. Read this before making changes.

## What this app is

iOS SwiftUI app that connects to the user's bank via **Plaid**, tracks daily
spending against a user-set **daily cap**, and sends an APNs push when spending
crosses 80% ("getting close") and 100% ("over cap") of the cap.

- **Platform:** iOS 17+, SwiftUI, Swift 5.10
- **Backend:** Supabase — ref `gmzzbslcsswqjjswoaen` (auth + Postgres + edge functions, all RLS-enforced)
- **Bank data:** Plaid `transactions` product. `PLAID_ENV=sandbox` until launch.
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
   (`SHIP_RUN_UI=1` to gate on UI tests too). Smoke-test launch in the
   simulator before shipping.
3. **Run `./scripts/run_tests.sh` before shipping.** Review whether each UI
   change needs a new XCUITest; note the decision in the commit message.
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
- `spendcap-test-account` — JSON `{email,password}` for XCUITest auto-sign-in
- `supabase-pat-clockin` — Supabase management API PAT

## Known quirks

- Plaid sandbox: use institution `ins_109508` ("First Platypus Bank"),
  credentials `user_good` / `pass_good`. Fire test transactions with
  `/sandbox/item/fire_webhook` or `sandbox/transactions/create`.
- Edge functions deployed with `--no-verify-jwt` (webhook + cron fns) are gated
  by secret headers instead; JWT-gated fns (`plaid_create_link_token`,
  `plaid_exchange_public_token`) authenticate the Supabase session user.
- pg_net response bloat: if disk IO spikes, `TRUNCATE net._http_response`
  (see memory playbook).
