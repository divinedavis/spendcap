-- 0020_item_refresh_nudge: when a refresh was last requested from Plaid.
--
-- Plaid's background refresh of a Wells Fargo item silently stalled for 35
-- hours (2026-08-12/13): item healthy, webhook configured, /item/get showing
-- last_successful_update frozen — and a manual /transactions/refresh brought
-- three transactions (and a payroll deposit) in within two minutes. The
-- hourly cron now notices that staleness and requests a refresh itself.
--
-- This column is the cost bound: /transactions/refresh is a billed call, so
-- the cron asks at most once per 24h per item no matter how long the
-- staleness persists. (/item/get, which detects it, is free.)

alter table public.plaid_items
  add column if not exists last_refresh_requested_at timestamptz;
