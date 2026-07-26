# Spendcap

**iOS app that links your bank through Plaid and pushes you a notification the
moment the day's spending crosses your cap.**

Most budgeting apps tell you what you overspent on *last month*. Spendcap tells
you at 3pm today, while you can still do something about it.

You set one number — a daily spending cap. Spendcap mirrors your bank
transactions in the background and sends a push at **80%** ("getting close")
and again at **100%** ("over cap"), one of each per day, no nagging.

| | |
|---|---|
| **Platform** | iOS 17+, SwiftUI, Swift 5.10 |
| **Backend** | Supabase — Auth, Postgres (RLS on every table), Edge Functions |
| **Bank data** | Plaid `transactions` product |
| **Push** | APNs via a Supabase edge function |
| **Status** | TestFlight, Plaid sandbox |

## How it works

1. **Sign up** with email/password and set a daily cap (defaults to $50).
2. **Connect a bank** with Plaid Link. The public token is exchanged
   server-side by an edge function — the Plaid access token is written to a
   table only the service role can read, and never returned to the client.
3. **Transactions sync.** Plaid fires a `SYNC_UPDATES_AVAILABLE` webhook, which
   runs `/transactions/sync` and upserts the delta. An hourly `pg_cron` job is
   the fallback for missed webhooks.
4. **Overspend check.** After every sync, `check_overspend` totals the day's
   outflows *in the user's own timezone* (pending transactions included) and
   compares against the cap. Crossing a threshold sends one push, deduped per
   user/day/kind in `spend_alerts`.
5. **The app** shows a today ring (spent vs. cap), the day's transactions, and
   month-to-date pacing.

```
Plaid Link (LinkKit)
  ├─> plaid_create_link_token ────────── JWT-gated ──> link token
  └─> plaid_exchange_public_token ────── JWT-gated ──> access token
                                                       (service-role only)

Plaid webhook ─────> plaid_webhook ────┐
pg_cron (hourly) ──> sync_transactions ─┴─> /transactions/sync ──> upsert
                                             └─> check_overspend ──> APNs
```

## Security notes

This app touches bank data, so a few things are deliberate:

- **Plaid access tokens never reach the client.** They live in
  `plaid_item_secrets`, which has no `anon` or `authenticated` grants at all —
  only the service role, used by edge functions.
- **RLS on every table**, self-only, with explicit grants rather than inherited
  ones.
- **Threshold math is duplicated on purpose.** The server decides when to push;
  `BudgetMath` mirrors the same integer comparison client-side so the ring and
  the notification can never disagree. Unit tests pin them together.
- **Financial data is redacted in the app-switcher snapshot**, so balances
  don't leak into the multitasking view.
- **No secrets in this repo.** Credentials come from `Secrets.xcconfig`
  (gitignored) and the macOS keychain; Plaid keys are Supabase function secrets.

## Project layout

```
Spendcap/
  App/            app entry, settings
  Auth/           Supabase email auth
  Budget/         cap editing
  Dashboard/      today ring + transaction list
  Link/           Plaid Link (LinkKit) wrapper
  Notifications/  APNs registration + token upload
  Services/       spend queries, BudgetMath
  Supabase/       client
supabase/
  functions/      5 edge functions (Deno)
  migrations/     numbered SQL
  schema.sql      canonical schema
scripts/          generate, test, ship
```

## Building it yourself

Requires Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), a
Supabase project, and Plaid API keys.

```bash
cp Secrets.xcconfig.example Secrets.xcconfig   # add your Supabase URL + anon key
./scripts/generate.sh                          # generate the .xcodeproj
./scripts/run_tests.sh                         # unit + UI sweep
```

Apply `supabase/schema.sql` to your project, deploy the functions in
`supabase/functions/`, then store your Plaid keys in the keychain and run
`./scripts/set_plaid_keys.sh` to push them to Supabase.

`./scripts/ship.sh` bumps the build, archives, and uploads to TestFlight.

See [`CLAUDE.md`](CLAUDE.md) for full architecture notes and working rules.

## License

No license — all rights reserved. Public for reading, not for reuse.
