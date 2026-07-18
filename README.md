# Spendcap

iOS app that connects to your bank via Plaid and pushes you a notification when
you're spending too much in a day.

- **Platform:** iOS 17+, SwiftUI
- **Backend:** Supabase (auth + Postgres + edge functions, RLS-enforced)
- **Bank data:** Plaid (`transactions` product, sandbox until launch)
- **Bundle ID:** `com.divinedavis.spendcap`
- **Supabase ref:** `gmzzbslcsswqjjswoaen`

## How it works

1. Sign up (email/password, Supabase Auth), set a **daily spending cap**.
2. Connect a bank with **Plaid Link**. The public token is exchanged server-side
   (edge function); the access token never touches the client.
3. Plaid webhooks (`SYNC_UPDATES_AVAILABLE`) hit the `plaid_webhook` edge
   function, which runs `/transactions/sync` and upserts transactions. An hourly
   pg_cron job is the fallback sync.
4. After every sync, `check_overspend` totals today's outflows in the user's
   timezone. Crossing 80% of the cap sends a "getting close" push; crossing 100%
   sends an "over budget" push (one of each per day, deduped in `spend_alerts`).
5. The app shows a today ring (spent vs cap), the day's transactions, and
   month-to-date pacing.

## Development

```bash
./scripts/generate.sh     # regenerate Spendcap.xcodeproj from project.yml
./scripts/run_tests.sh    # unit + UI test sweep (gates every ship)
./scripts/ship.sh         # bump build, archive, upload to TestFlight
```

Secrets live in `Secrets.xcconfig` (gitignored, copy from `.example`) and the
macOS keychain (`spendcap-*` services). Plaid keys are Supabase function
secrets — set with `./scripts/set_plaid_keys.sh` after storing them in the
keychain.

See `CLAUDE.md` for working rules and full architecture notes.
