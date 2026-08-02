-- 0001_init: Spendcap core schema
-- Tables mirror Plaid objects; amount_cents > 0 = money out (Plaid convention).
-- Access tokens live in plaid_item_secrets, which no client role can read.

create extension if not exists pgcrypto;

-- ── profiles ────────────────────────────────────────────────────────────────
create table public.profiles (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  timezone   text not null default 'America/New_York',
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
create policy profiles_self on public.profiles
  for all to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ── budgets ─────────────────────────────────────────────────────────────────
create table public.budgets (
  user_id          uuid primary key references auth.users(id) on delete cascade,
  daily_limit_cents bigint not null default 5000 check (daily_limit_cents > 0),
  warn_pct         int    not null default 80 check (warn_pct between 1 and 100),
  updated_at       timestamptz not null default now()
);
alter table public.budgets enable row level security;
create policy budgets_self on public.budgets
  for all to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ── plaid_items (user-visible connection metadata) ──────────────────────────
create table public.plaid_items (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users(id) on delete cascade,
  plaid_item_id    text not null unique,
  institution_name text,
  status           text not null default 'active',
  sync_cursor      text,
  last_synced_at   timestamptz,
  created_at       timestamptz not null default now()
);
alter table public.plaid_items enable row level security;
create policy plaid_items_select_self on public.plaid_items
  for select to authenticated using (auth.uid() = user_id);
create policy plaid_items_delete_self on public.plaid_items
  for delete to authenticated using (auth.uid() = user_id);
-- inserts/updates come from edge functions via service_role only

-- ── plaid_item_secrets (Plaid access tokens — SERVER ONLY) ──────────────────
create table public.plaid_item_secrets (
  item_id      uuid primary key references public.plaid_items(id) on delete cascade,
  access_token text not null,
  created_at   timestamptz not null default now()
);
alter table public.plaid_item_secrets enable row level security;
-- No policies: only service_role (bypasses RLS) can touch this table.

-- ── accounts ────────────────────────────────────────────────────────────────
create table public.accounts (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references auth.users(id) on delete cascade,
  item_id               uuid not null references public.plaid_items(id) on delete cascade,
  plaid_account_id      text not null unique,
  name                  text not null,
  mask                  text,
  type                  text,
  subtype               text,
  current_balance_cents bigint,
  iso_currency          text not null default 'USD',
  created_at            timestamptz not null default now()
);
alter table public.accounts enable row level security;
create policy accounts_select_self on public.accounts
  for select to authenticated using (auth.uid() = user_id);

-- ── transactions ────────────────────────────────────────────────────────────
create table public.transactions (
  id                   uuid primary key default gen_random_uuid(),
  user_id              uuid not null references auth.users(id) on delete cascade,
  account_id           uuid not null references public.accounts(id) on delete cascade,
  plaid_transaction_id text not null unique,
  date                 date not null,
  authorized_date      date,
  name                 text not null default '',
  merchant_name        text,
  category             text,
  amount_cents         bigint not null,
  pending              boolean not null default false,
  is_removed           boolean not null default false,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create index transactions_user_date on public.transactions (user_id, date desc);
alter table public.transactions enable row level security;
create policy transactions_select_self on public.transactions
  for select to authenticated using (auth.uid() = user_id);

-- ── device_push_tokens ──────────────────────────────────────────────────────
create table public.device_push_tokens (
  device_token text primary key,
  user_id      uuid not null references auth.users(id) on delete cascade,
  platform     text not null default 'ios',
  updated_at   timestamptz not null default now()
);
alter table public.device_push_tokens enable row level security;
create policy device_push_tokens_self on public.device_push_tokens
  for all to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ── spend_alerts (dedupe log: one warn + one over per user per local day) ───
create table public.spend_alerts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  local_date  date not null,
  kind        text not null check (kind in ('warn', 'over')),
  spent_cents bigint not null,
  limit_cents bigint not null,
  sent_at     timestamptz not null default now(),
  unique (user_id, local_date, kind)
);
alter table public.spend_alerts enable row level security;
create policy spend_alerts_select_self on public.spend_alerts
  for select to authenticated using (auth.uid() = user_id);

-- ── auto-provision profile + budget on signup ───────────────────────────────
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (user_id) values (new.id) on conflict do nothing;
  insert into public.budgets (user_id) values (new.id) on conflict do nothing;
  return new;
end;
$$;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ── overspend status (service_role only; edge fn calls this after sync) ─────
create or replace function public.overspend_status()
returns table (
  user_id     uuid,
  local_date  date,
  spent_cents bigint,
  limit_cents bigint,
  warn_pct    int
)
language sql
security definer set search_path = public
as $$
  select p.user_id,
         (now() at time zone p.timezone)::date as local_date,
         coalesce(sum(t.amount_cents), 0)      as spent_cents,
         b.daily_limit_cents                   as limit_cents,
         b.warn_pct
  from public.profiles p
  join public.budgets b on b.user_id = p.user_id
  left join public.transactions t
    on t.user_id = p.user_id
   and t.is_removed = false
   and t.amount_cents > 0
   and t.date = (now() at time zone p.timezone)::date
  group by p.user_id, p.timezone, b.daily_limit_cents, b.warn_pct;
$$;
revoke execute on function public.overspend_status() from public, anon, authenticated;

-- ── account deletion (App Store 5.1.1) ──────────────────────────────────────
create or replace function public.delete_account()
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  delete from auth.users where id = auth.uid();
end;
$$;
revoke execute on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;

-- ── explicit grants (Supabase drops implicit public-schema grants 2026-10-30)
grant usage on schema public to anon, authenticated, service_role;
grant select, insert, update, delete on public.profiles, public.budgets, public.device_push_tokens to authenticated;
grant select, delete on public.plaid_items to authenticated;
grant select on public.accounts, public.transactions, public.spend_alerts to authenticated;
grant select on public.profiles, public.budgets, public.plaid_items, public.accounts,
  public.transactions, public.spend_alerts, public.device_push_tokens to anon;
grant all on all tables in schema public to service_role;

-- plaid_item_secrets: strip every client grant (incl. any default-privilege
-- auto-grant). The app never queries it, so a 42501 here is a feature.
revoke all on public.plaid_item_secrets from anon, authenticated;

notify pgrst, 'reload schema';
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

-- 0003_statements: Plaid Statements — metadata in Postgres, PDF bytes in a
-- private Storage bucket.
--
-- Statement PDFs are the most sensitive thing this app has ever stored: they
-- carry full account numbers, not the 4-digit mask in public.accounts. So the
-- bucket is private (no public URL, reads go through a short-lived signed URL),
-- objects are namespaced under the owner's uid, and every policy is scoped to
-- auth.uid() rather than relying on the bucket being "not public".

-- ── statements (metadata only — never the file itself) ──────────────────────
create table public.statements (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users(id) on delete cascade,
  item_id            uuid not null references public.plaid_items(id) on delete cascade,
  account_id         uuid references public.accounts(id) on delete set null,
  plaid_statement_id text not null unique,
  period_start       date,
  period_end         date,
  -- Denormalised for cheap "past year, newest first" ordering without
  -- date_part() on every row.
  year               int  not null,
  month              int  not null check (month between 1 and 12),
  -- Object key inside the 'statements' bucket: "<uid>/<statement_id>.pdf".
  -- Null until the download succeeds, so a failed fetch leaves a visible row
  -- rather than silently vanishing.
  storage_path       text,
  byte_size          bigint,
  fetched_at         timestamptz,
  created_at         timestamptz not null default now()
);
create index statements_user_period_idx
  on public.statements (user_id, year desc, month desc);

alter table public.statements enable row level security;
create policy statements_select_self on public.statements
  for select to authenticated using (auth.uid() = user_id);
create policy statements_delete_self on public.statements
  for delete to authenticated using (auth.uid() = user_id);
-- inserts/updates come from the edge function via service_role only

-- ── private bucket ──────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('statements', 'statements', false, 52428800, array['application/pdf'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Objects live at "<uid>/<plaid_statement_id>.pdf". Comparing the first path
-- segment to auth.uid() is what actually enforces per-user isolation — a
-- bucket-wide policy would let any signed-in user read every statement.
create policy statements_objects_select_self on storage.objects
  for select to authenticated
  using (
    bucket_id = 'statements'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy statements_objects_delete_self on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'statements'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
-- No insert/update policy: only the edge function (service_role) writes here.

-- ── account deletion must take the PDFs with it ─────────────────────────────
-- public.statements cascades from auth.users, but storage.objects does not —
-- deleting the account would otherwise orphan the PDFs in the bucket forever,
-- which is exactly the data we least want to keep. Clean them up first.
create or replace function public.delete_account()
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'not authenticated';
  end if;
  delete from storage.objects
   where bucket_id = 'statements'
     and (storage.foldername(name))[1] = uid::text;
  delete from auth.users where id = uid;
end;
$$;
revoke execute on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;

-- ── explicit grants (Supabase drops implicit public-schema grants 2026-10-30)
grant select, delete on public.statements to authenticated;
grant all on public.statements to service_role;
-- Deliberately no anon grant. 0001 hands anon a blanket select on the other
-- tables and leans on RLS to return zero rows; that is one policy mistake away
-- from leaking, and this is the table holding statement locations. Anon has no
-- reason to see it at all, so the grant simply never exists.
revoke all on public.statements from anon;

notify pgrst, 'reload schema';

-- 0004_pending_backfill: stop a bank's pending backlog counting as today.
--
-- Wells Fargo (and it is not alone) reports unposted transactions with no
-- authorized_date, so Plaid stamps them with the date they were *seen*. On the
-- very first sync of a new item that is the link date — which collapses days
-- or weeks of unposted purchases onto a single day. Observed live: linking on
-- 2026-08-01 produced 19 pending rows all dated 2026-08-01 totalling $428.38
-- against a $50 cap, and fired an "over" push 3 seconds after linking.
--
-- The date on such a row is not wrong so much as unknowable, and it corrects
-- itself: once the charge posts, Plaid supplies the real date and pending goes
-- false. So the fix is to not count a pending row we inherited at link time,
-- and let it start counting on its true day when it posts.

alter table public.transactions
  add column if not exists is_backfill boolean not null default false;

comment on column public.transactions.is_backfill is
  'True for rows first seen during an item''s initial sync. Combined with '
  'pending = true it marks a charge whose date is the link date rather than a '
  'real purchase date, so day totals must skip it until it posts.';

-- Day-total queries filter on (date, is_removed, pending, is_backfill).
create index if not exists transactions_day_totals_idx
  on public.transactions (user_id, date)
  where is_removed = false and amount_cents > 0;

-- ── existing data ───────────────────────────────────────────────────────────
-- Every row currently on file arrived in one initial sync, so every row still
-- pending is by definition inherited backlog. Posted rows carry real dates and
-- are left alone.
update public.transactions
   set is_backfill = true
 where pending = true
   and is_removed = false;

-- ── overspend_status: exclude inherited pending rows ────────────────────────
create or replace function public.overspend_status()
returns table (
  user_id uuid,
  local_date date,
  spent_cents bigint,
  limit_cents bigint,
  warn_pct int
)
language sql
security definer set search_path = public
as $$
  select p.user_id,
         (now() at time zone p.timezone)::date as local_date,
         coalesce(sum(t.amount_cents), 0)      as spent_cents,
         b.daily_limit_cents                   as limit_cents,
         b.warn_pct
  from public.profiles p
  join public.budgets b on b.user_id = p.user_id
  left join public.transactions t
    on t.user_id = p.user_id
   and t.is_removed = false
   and t.amount_cents > 0
   and t.date = (now() at time zone p.timezone)::date
   -- A pending row inherited at link time has the link date, not a purchase
   -- date. Skip it; it counts on its real day once it posts.
   and not (t.pending and t.is_backfill)
  group by p.user_id, p.timezone, b.daily_limit_cents, b.warn_pct;
$$;
revoke execute on function public.overspend_status() from public, anon, authenticated;

notify pgrst, 'reload schema';

-- 0005_monthly_spend: per-month spend totals for the Months tab.
--
-- The client needs 12 monthly totals, not 12 months of rows. Pulling the raw
-- transactions would mean thousands of rows over PostgREST's 1000-row default
-- cap and a client-side sum, so the aggregation happens here.
--
-- security invoker on purpose: transactions is RLS'd self-only, so the function
-- can only ever see the caller's rows. The redundant user_id = auth.uid()
-- predicate is there for the index, not for safety.
--
-- The outflow filter must mirror overspend_status() (0004) and the client's
-- BankTransaction.countsTowardDailyCap exactly — a month total that disagrees
-- with the day totals the pushes are built from would be worse than no total.

create or replace function public.monthly_spend(months_back int default 12)
returns table (
  period      date,     -- first day of the month, in the user's timezone
  spent_cents bigint,
  txn_count   int
)
language sql
stable
security invoker
set search_path = public
as $$
  with tz as (
    -- No profile row yet (first launch, before syncTimezone lands) falls back
    -- to UTC rather than returning nothing.
    select coalesce(max(p.timezone), 'UTC') as name
      from public.profiles p
     where p.user_id = auth.uid()
  ),
  bounds as (
    select date_trunc('month', (now() at time zone (select name from tz))::date)::date as this_month,
           least(greatest(coalesce(months_back, 12), 1), 36) as span
  ),
  months as (
    select generate_series(
             b.this_month - ((b.span - 1) || ' months')::interval,
             b.this_month,
             interval '1 month'
           )::date as period
      from bounds b
  )
  select m.period,
         coalesce(sum(t.amount_cents), 0)::bigint as spent_cents,
         count(t.id)::int                         as txn_count
    from months m
    left join public.transactions t
      on t.user_id = auth.uid()
     and t.is_removed = false
     and t.amount_cents > 0
     -- Pending rows inherited at link time carry the link date, not a purchase
     -- date (see 0004). They count on their real day once they post.
     and not (t.pending and t.is_backfill)
     and t.date >= m.period
     and t.date < (m.period + interval '1 month')::date
   group by m.period
   order by m.period;
$$;

comment on function public.monthly_spend(int) is
  'Outflow totals for the last N calendar months (default 12) in the caller''s '
  'timezone, one row per month including months with no activity. Mirrors the '
  'overspend_status() filter so month totals agree with day totals.';

revoke execute on function public.monthly_spend(int) from public, anon;
grant execute on function public.monthly_spend(int) to authenticated, service_role;

notify pgrst, 'reload schema';
