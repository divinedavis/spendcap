-- 0002_cron_sync: hourly fallback sync via pg_cron + pg_net.
-- Plaid webhooks are the primary trigger; this catches missed webhooks.
-- The x-cron-secret value lives in Vault (name 'cron_secret'), created
-- out-of-band — never in a committed migration.

create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule(
  'spendcap-hourly-sync',
  '15 * * * *',
  $$
  select net.http_post(
    url     := 'https://gmzzbslcsswqjjswoaen.supabase.co/functions/v1/sync_transactions',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')
    ),
    body := '{}'::jsonb
  );
  $$
);
