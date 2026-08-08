-- 0013_cron_statements: daily statement ingestion via pg_cron + pg_net.
--
-- Statements had no automatic path at all: plaid_statements_sync is JWT-gated
-- and only ran when someone opened the Statements screen, so a new statement
-- sat unfetched until the next visit. statements_cron is the unattended half.
--
-- Daily, not monthly, because a statement cycle belongs to the bank, not the
-- calendar — pinning a day of the month would miss any cycle the bank moved.
-- Only /statements/list runs on that cadence; the per-request-billed download
-- fires once per account per cycle because fetched statements are skipped, and
-- statements_cron caps a run at 6 downloads besides.
--
-- 16:45 UTC keeps it clear of the hourly transaction sync at :15. The
-- x-cron-secret value lives in Vault (name 'cron_secret'), created out-of-band
-- — never in a committed migration.

create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule(
  'spendcap-daily-statements',
  '45 16 * * *',
  $$
  select net.http_post(
    url     := 'https://gmzzbslcsswqjjswoaen.supabase.co/functions/v1/statements_cron',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')
    ),
    body := '{}'::jsonb
  );
  $$
);
