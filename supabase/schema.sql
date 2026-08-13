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
-- which is exactly the data we least want to keep. That cleanup happens in the
-- CLIENT, immediately before this runs; it cannot happen here (0014).
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
  -- No storage.objects delete here: Supabase's protect_delete trigger raises
  -- 42501 on any direct delete, which aborted this whole function and rolled
  -- the account deletion back (0014). The PDFs are removed client-side via the
  -- Storage API *before* this is called — SpendService.deleteStoredStatements.
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

-- 0006_monthly_cap: a monthly budget cap of its own, separate from the daily one.
--
-- Until now a "month cap" was derived — daily_limit_cents × days in the month.
-- That is the wrong number to judge a month by: the daily cap is a nudge
-- threshold sized for a single day's discretionary spending, so rent, a card
-- payoff, or an annual bill lands on one day and drags the whole month red.
--
-- Null keeps the old derived behaviour, so existing users see no change until
-- they set one. The daily cap is untouched and still drives check_overspend and
-- the pushes; this column is read by the app's Months screen only.

alter table public.budgets
  add column if not exists monthly_limit_cents int;

comment on column public.budgets.monthly_limit_cents is
  'Optional whole-month spending cap in cents. Null means fall back to '
  'daily_limit_cents x days in the month. Independent of the daily cap: this '
  'one is not a push threshold.';

alter table public.budgets
  drop constraint if exists budgets_monthly_limit_cents_positive;
alter table public.budgets
  add constraint budgets_monthly_limit_cents_positive
  check (monthly_limit_cents is null or monthly_limit_cents > 0);

notify pgrst, 'reload schema';

-- 0007_category_budgets: planned-vs-actual by category, the spreadsheet model.
--
-- A single monthly cap says whether the month went wrong, not where. This adds
-- the budget-line view: a set of user-defined categories with a planned amount
-- each, rules that route transactions into them, and a rollup that answers
-- "am I over on Food this month" for as many months back as asked for.
--
-- Design notes worth keeping:
--
-- * Rules live in the database, not in app code, because the mapping is
--   personal. Plaid's personal_finance_category is a decent first pass and a
--   bad final answer — this account has a steakhouse filed under
--   GENERAL_SERVICES and $5.7k of Airbnb under TRAVEL.
-- * Merchant rules beat category rules, and the longest merchant match wins,
--   so "Peter Luger" can be pulled into Food without disturbing the rest of
--   GENERAL_SERVICES.
-- * Anything unmatched is reported as an explicit Uncategorized line rather
--   than dropped. A budget that quietly ignores a third of the spending is
--   worse than one that admits it.

create table if not exists public.budget_categories (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  name          text not null check (length(trim(name)) between 1 and 60),
  planned_cents int  not null default 0 check (planned_cents >= 0),
  sort_order    int  not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (user_id, name)
);

create index if not exists budget_categories_user_idx
  on public.budget_categories (user_id, sort_order);

create table if not exists public.category_rules (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  category_id uuid not null references public.budget_categories(id) on delete cascade,
  -- 'plaid_category' matches transactions.category exactly (Plaid's
  -- personal_finance_category primary); 'merchant_contains' is a
  -- case-insensitive substring of the merchant or description.
  match_type  text not null check (match_type in ('plaid_category', 'merchant_contains')),
  match_value text not null check (length(trim(match_value)) > 0),
  created_at  timestamptz not null default now(),
  -- One home per rule value: without this a merchant could land in two
  -- categories and the totals would double-count.
  unique (user_id, match_type, match_value)
);

create index if not exists category_rules_user_idx
  on public.category_rules (user_id, match_type);

alter table public.budget_categories enable row level security;
alter table public.category_rules    enable row level security;

drop policy if exists "budget_categories self" on public.budget_categories;
create policy "budget_categories self" on public.budget_categories
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "category_rules self" on public.category_rules;
create policy "category_rules self" on public.category_rules
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

grant select, insert, update, delete on public.budget_categories to authenticated;
grant select, insert, update, delete on public.category_rules to authenticated;
grant all on public.budget_categories, public.category_rules to service_role;

-- ── rollup ──────────────────────────────────────────────────────────────────
-- One row per (month, category) for the last N months, including categories
-- with no spending and a synthetic Uncategorized line per month.

create or replace function public.category_spend(months_back int default 2)
returns table (
  period        date,
  category_id   uuid,
  category_name text,
  planned_cents int,
  spent_cents   bigint,
  txn_count     int,
  sort_order    int
)
language sql
stable
security invoker
set search_path = public
as $$
  with tz as (
    select coalesce(max(p.timezone), 'UTC') as name
      from public.profiles p
     where p.user_id = auth.uid()
  ),
  bounds as (
    select date_trunc('month', (now() at time zone (select name from tz))::date)::date as this_month,
           least(greatest(coalesce(months_back, 2), 1), 24) as span
  ),
  months as (
    select generate_series(
             b.this_month - ((b.span - 1) || ' months')::interval,
             b.this_month,
             interval '1 month'
           )::date as period
      from bounds b
  ),
  txn as (
    select t.id,
           date_trunc('month', t.date)::date as period,
           t.amount_cents,
           coalesce(nullif(trim(t.merchant_name), ''), t.name) as who,
           t.category
      from public.transactions t
     where t.user_id = auth.uid()
       and t.is_removed = false
       and t.amount_cents > 0
       -- Same outflow filter as overspend_status() and monthly_spend().
       and not (t.pending and t.is_backfill)
       and t.date >= (select min(period) from months)
  ),
  matched as (
    select x.*,
           (
             select r.category_id
               from public.category_rules r
              where r.user_id = auth.uid()
                and (
                     (r.match_type = 'merchant_contains' and x.who ilike '%' || r.match_value || '%')
                  or (r.match_type = 'plaid_category'    and x.category = r.match_value)
                )
              -- Most specific wins: a named merchant beats a whole Plaid
              -- category, and a longer merchant string beats a shorter one.
              order by (r.match_type = 'merchant_contains') desc,
                       length(r.match_value) desc
              limit 1
           ) as category_id
      from txn x
  )
  select m.period,
         c.id                                     as category_id,
         c.name                                   as category_name,
         c.planned_cents,
         coalesce(sum(x.amount_cents), 0)::bigint as spent_cents,
         count(x.id)::int                         as txn_count,
         c.sort_order
    from months m
    cross join public.budget_categories c
    left join matched x
      on x.period = m.period
     and x.category_id = c.id
   where c.user_id = auth.uid()
   group by m.period, c.id, c.name, c.planned_cents, c.sort_order

  union all

  select m.period,
         null::uuid,
         'Uncategorized',
         0,
         coalesce(sum(x.amount_cents), 0)::bigint,
         count(x.id)::int,
         2147483647          -- always last
    from months m
    left join matched x
      on x.period = m.period
     and x.category_id is null
   group by m.period

   order by 1 desc, 7, 3;
$$;

comment on function public.category_spend(int) is
  'Planned vs actual by category for the last N months (default 2), newest '
  'month first. Emits every category each month plus an Uncategorized line, '
  'so unmapped spending is visible rather than silently dropped.';

revoke execute on function public.category_spend(int) from public, anon;
grant execute on function public.category_spend(int) to authenticated, service_role;

-- ── what a merchant is doing in a category ──────────────────────────────────
-- Backs the drill-down: which transactions landed in this category this month,
-- which is also how a miscategorised merchant gets noticed.

create or replace function public.category_transactions(
  category uuid,
  period   date
)
returns table (
  id            uuid,
  date          date,
  name          text,
  merchant_name text,
  amount_cents  bigint,
  pending       boolean
)
language sql
stable
security invoker
set search_path = public
as $$
  with txn as (
    select t.id, t.date, t.name, t.merchant_name, t.amount_cents, t.pending,
           coalesce(nullif(trim(t.merchant_name), ''), t.name) as who,
           t.category as plaid_category
      from public.transactions t
     where t.user_id = auth.uid()
       and t.is_removed = false
       and t.amount_cents > 0
       and not (t.pending and t.is_backfill)
       and t.date >= period
       and t.date < (period + interval '1 month')::date
  ),
  matched as (
    select x.*,
           (
             select r.category_id
               from public.category_rules r
              where r.user_id = auth.uid()
                and (
                     (r.match_type = 'merchant_contains' and x.who ilike '%' || r.match_value || '%')
                  or (r.match_type = 'plaid_category'    and x.plaid_category = r.match_value)
                )
              order by (r.match_type = 'merchant_contains') desc,
                       length(r.match_value) desc
              limit 1
           ) as category_id
      from txn x
  )
  select m.id, m.date, m.name, m.merchant_name, m.amount_cents::bigint, m.pending
    from matched m
   where m.category_id is not distinct from category
   order by m.amount_cents desc;
$$;

revoke execute on function public.category_transactions(uuid, date) from public, anon;
grant execute on function public.category_transactions(uuid, date) to authenticated, service_role;

-- ── starter budget ──────────────────────────────────────────────────────────
-- Seeds a first set of categories and rules for the caller. No-op once any
-- category exists, so it can't clobber an edited budget.

create or replace function public.seed_starter_budget()
returns int
language plpgsql
security invoker
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  created int := 0;
  cat_id uuid;
  seed record;
begin
  if uid is null then
    raise exception 'not authenticated';
  end if;

  if exists (select 1 from public.budget_categories where user_id = uid) then
    return 0;
  end if;

  for seed in
    select * from (values
      ('Food',                       60000, 1,
        array['FOOD_AND_DRINK'],                            array[]::text[]),
      ('Socializing / Shopping',     60000, 2,
        array['ENTERTAINMENT','GENERAL_MERCHANDISE'],       array[]::text[]),
      ('Haircuts',                   40000, 3,
        array['PERSONAL_CARE'],                             array[]::text[]),
      ('Rent / Wifi / Utilities',   350000, 4,
        array['RENT_AND_UTILITIES'],                        array[]::text[]),
      ('Transport',                  30000, 5,
        array['TRANSPORTATION'],                            array[]::text[]),
      ('Cash Savings',               50000, 6,
        array[]::text[],                                    array['SAVE AS YOU GO','SAVINGS TRANSFER']),
      ('Debts',                     150000, 7,
        array['LOAN_PAYMENTS','BANK_FEES'],                 array[]::text[]),
      ('VGT',                        10000, 8,
        array[]::text[],                                    array['VGT','VANGUARD']),
      ('401k',                       48000, 9,
        array[]::text[],                                    array[]::text[])
    ) as t(name, planned_cents, sort_order, plaid_categories, merchants)
  loop
    insert into public.budget_categories (user_id, name, planned_cents, sort_order)
    values (uid, seed.name, seed.planned_cents, seed.sort_order)
    returning id into cat_id;
    created := created + 1;

    insert into public.category_rules (user_id, category_id, match_type, match_value)
    select uid, cat_id, 'plaid_category', unnest(seed.plaid_categories)
    on conflict do nothing;

    insert into public.category_rules (user_id, category_id, match_type, match_value)
    select uid, cat_id, 'merchant_contains', unnest(seed.merchants)
    on conflict do nothing;
  end loop;

  return created;
end;
$$;

comment on function public.seed_starter_budget() is
  'Creates a starter set of budget categories and Plaid-category rules for the '
  'caller. Returns 0 and changes nothing if they already have categories.';

revoke execute on function public.seed_starter_budget() from public, anon;
grant execute on function public.seed_starter_budget() to authenticated;

notify pgrst, 'reload schema';

-- 0008_transaction_detail: enough of a transaction to explain itself.
--
-- The category drill-down listed a merchant, a date and an amount, which is
-- enough to spot a wrong line but not enough to judge it. "Amazon $5.00" could
-- be anything; the raw bank description, the account it came from, and whether
-- it has actually posted are what settle it.
--
-- The return type changes, so the old signature is dropped rather than
-- replaced — create or replace refuses to change a function's output columns.

drop function if exists public.category_transactions(uuid, date);

create or replace function public.category_transactions(
  category uuid,
  period   date
)
returns table (
  id             uuid,
  date           date,
  authorized_date date,
  name           text,
  merchant_name  text,
  plaid_category text,
  amount_cents   bigint,
  pending        boolean,
  is_backfill    boolean,
  account_name   text,
  account_mask   text
)
language sql
stable
security invoker
set search_path = public
as $$
  with txn as (
    select t.id, t.date, t.authorized_date, t.name, t.merchant_name,
           t.category as plaid_category, t.amount_cents, t.pending, t.is_backfill,
           a.name as account_name, a.mask as account_mask,
           coalesce(nullif(trim(t.merchant_name), ''), t.name) as who
      from public.transactions t
      left join public.accounts a on a.id = t.account_id
     where t.user_id = auth.uid()
       and t.is_removed = false
       and t.amount_cents > 0
       and not (t.pending and t.is_backfill)
       and t.date >= period
       and t.date < (period + interval '1 month')::date
  ),
  matched as (
    select x.*,
           (
             select r.category_id
               from public.category_rules r
              where r.user_id = auth.uid()
                and (
                     (r.match_type = 'merchant_contains' and x.who ilike '%' || r.match_value || '%')
                  or (r.match_type = 'plaid_category'    and x.plaid_category = r.match_value)
                )
              order by (r.match_type = 'merchant_contains') desc,
                       length(r.match_value) desc
              limit 1
           ) as category_id
      from txn x
  )
  select m.id, m.date, m.authorized_date, m.name, m.merchant_name,
         m.plaid_category, m.amount_cents::bigint, m.pending, m.is_backfill,
         m.account_name, m.account_mask
    from matched m
   where m.category_id is not distinct from category
   order by m.amount_cents desc;
$$;

revoke execute on function public.category_transactions(uuid, date) from public, anon;
grant execute on function public.category_transactions(uuid, date) to authenticated, service_role;

notify pgrst, 'reload schema';

-- 0009_month_activity: every transaction in a month, with its budget line.
--
-- The Activity screen lists a whole month rather than a single category, so it
-- needs the same rich columns category_transactions() returns plus the line
-- each row resolves to — otherwise the screen would have to fetch every
-- category and match client-side.
--
-- Unlike every other rollup here this one does NOT filter to outflows. Money
-- in is activity: a refund or a paycheck landing is exactly the kind of thing
-- someone scanning a month wants to see, and hiding it would make the list
-- disagree with the bank statement it is meant to mirror. The budget rollups
-- keep their outflow-only filter, so totals are unaffected.

create or replace function public.month_activity(period date)
returns table (
  id              uuid,
  date            date,
  authorized_date date,
  name            text,
  merchant_name   text,
  plaid_category  text,
  amount_cents    bigint,
  pending         boolean,
  is_backfill     boolean,
  account_name    text,
  account_mask    text,
  category_name   text
)
language sql
stable
security invoker
set search_path = public
as $$
  with txn as (
    select t.id, t.date, t.authorized_date, t.name, t.merchant_name,
           t.category as plaid_category, t.amount_cents, t.pending, t.is_backfill,
           a.name as account_name, a.mask as account_mask,
           coalesce(nullif(trim(t.merchant_name), ''), t.name) as who
      from public.transactions t
      left join public.accounts a on a.id = t.account_id
     where t.user_id = auth.uid()
       and t.is_removed = false
       and t.date >= period
       and t.date < (period + interval '1 month')::date
  ),
  matched as (
    select x.*,
           (
             select r.category_id
               from public.category_rules r
              where r.user_id = auth.uid()
                and (
                     (r.match_type = 'merchant_contains' and x.who ilike '%' || r.match_value || '%')
                  or (r.match_type = 'plaid_category'    and x.plaid_category = r.match_value)
                )
              order by (r.match_type = 'merchant_contains') desc,
                       length(r.match_value) desc
              limit 1
           ) as category_id
      from txn x
  )
  select m.id, m.date, m.authorized_date, m.name, m.merchant_name,
         m.plaid_category, m.amount_cents::bigint, m.pending, m.is_backfill,
         m.account_name, m.account_mask,
         -- Money in is never "in" a budget line, so it is not mislabelled as
         -- Uncategorized, which on this screen would read as a gap to fix.
         case
           when m.amount_cents <= 0 then null
           else coalesce(c.name, 'Uncategorized')
         end as category_name
    from matched m
    left join public.budget_categories c on c.id = m.category_id
   order by m.date desc, abs(m.amount_cents) desc;
$$;

comment on function public.month_activity(date) is
  'Every transaction in a calendar month, newest first, with the budget line '
  'it resolves to. Includes money in, unlike the budget rollups.';

revoke execute on function public.month_activity(date) from public, anon;
grant execute on function public.month_activity(date) to authenticated, service_role;

notify pgrst, 'reload schema';

-- ==========================================================================
-- 0010_trips.sql
-- ==========================================================================

-- 0010_trips: trips and events — a named budget with its own line items, and
-- the real transactions that belong to it.
--
-- A trip is planned *and* actual. `trip_lines` holds what you expect to spend
-- ("Flight, $420, Mar 3"); `trip_transactions` records which real rows you
-- assigned to the trip, and optionally to a line. The screen shows both, so a
-- trip you haven't taken still totals up and one you're on shows the drift.
--
-- THE LOAD-BEARING RULE: assignment is explicit and per-transaction. A trip's
-- dates never exclude anything by themselves. Trip-assigned spending drops out
-- of the daily cap (a $780 hotel would fire an over-cap push that tells the
-- user nothing), so a date range that excluded rows automatically would
-- silently switch off the app's whole reason to exist for the length of a
-- holiday — the days you are most likely to overspend. Every excluded row is
-- one the user tapped.
--
-- Months, Trends and Activity are unaffected: they report what actually left
-- the account, and hiding trip spending there would make the app disagree with
-- the bank statement it mirrors.

-- ── trips ───────────────────────────────────────────────────────────────────
create table if not exists public.trips (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  name       text not null check (length(btrim(name)) > 0),
  kind       text not null default 'trip' check (kind in ('trip', 'event')),
  starts_on  date,
  ends_on    date,
  -- Optional. Null means "no budget set" and the planned lines are the budget;
  -- 0 would read as "budgeted nothing", which is a different statement.
  budget_cents bigint check (budget_cents is null or budget_cents >= 0),
  created_at timestamptz not null default now(),
  constraint trips_dates_ordered
    check (starts_on is null or ends_on is null or ends_on >= starts_on)
);
create index if not exists trips_user_starts on public.trips (user_id, starts_on desc);
alter table public.trips enable row level security;

drop policy if exists trips_select_self on public.trips;
create policy trips_select_self on public.trips
  for select to authenticated using (auth.uid() = user_id);
drop policy if exists trips_insert_self on public.trips;
create policy trips_insert_self on public.trips
  for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists trips_update_self on public.trips;
create policy trips_update_self on public.trips
  for update to authenticated using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
drop policy if exists trips_delete_self on public.trips;
create policy trips_delete_self on public.trips
  for delete to authenticated using (auth.uid() = user_id);

-- ── trip_lines ──────────────────────────────────────────────────────────────
-- One planned cost inside a trip: flight, hotel, food, or anything the user
-- adds. `occurs_on` is the flight's date; null for a line that has no single
-- day, like food across the whole week.
create table if not exists public.trip_lines (
  id            uuid primary key default gen_random_uuid(),
  trip_id       uuid not null references public.trips(id) on delete cascade,
  user_id       uuid not null references auth.users(id) on delete cascade,
  name          text not null check (length(btrim(name)) > 0),
  symbol        text,                       -- SF Symbol name, chosen client-side
  planned_cents bigint not null default 0 check (planned_cents >= 0),
  occurs_on     date,
  sort_order    int not null default 0,
  created_at    timestamptz not null default now()
);
create index if not exists trip_lines_trip on public.trip_lines (trip_id, sort_order, created_at);
alter table public.trip_lines enable row level security;

drop policy if exists trip_lines_select_self on public.trip_lines;
create policy trip_lines_select_self on public.trip_lines
  for select to authenticated using (auth.uid() = user_id);
drop policy if exists trip_lines_insert_self on public.trip_lines;
create policy trip_lines_insert_self on public.trip_lines
  for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists trip_lines_update_self on public.trip_lines;
create policy trip_lines_update_self on public.trip_lines
  for update to authenticated using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
drop policy if exists trip_lines_delete_self on public.trip_lines;
create policy trip_lines_delete_self on public.trip_lines
  for delete to authenticated using (auth.uid() = user_id);

-- ── trip_transactions ───────────────────────────────────────────────────────
-- transaction_id is the primary key, not a pair: a transaction belongs to at
-- most one trip. Without that a row could be excluded from the daily cap twice
-- over and counted in two trips' totals, and there is no sane answer to "which
-- trip was this hotel on".
create table if not exists public.trip_transactions (
  transaction_id uuid primary key references public.transactions(id) on delete cascade,
  trip_id        uuid not null references public.trips(id) on delete cascade,
  -- Null is a normal state: assigned to the trip, not yet filed under a line.
  line_id        uuid references public.trip_lines(id) on delete set null,
  user_id        uuid not null references auth.users(id) on delete cascade,
  created_at     timestamptz not null default now()
);
create index if not exists trip_transactions_trip on public.trip_transactions (trip_id);
create index if not exists trip_transactions_user on public.trip_transactions (user_id);
alter table public.trip_transactions enable row level security;

drop policy if exists trip_transactions_select_self on public.trip_transactions;
create policy trip_transactions_select_self on public.trip_transactions
  for select to authenticated using (auth.uid() = user_id);
drop policy if exists trip_transactions_insert_self on public.trip_transactions;
create policy trip_transactions_insert_self on public.trip_transactions
  for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists trip_transactions_update_self on public.trip_transactions;
create policy trip_transactions_update_self on public.trip_transactions
  for update to authenticated using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
drop policy if exists trip_transactions_delete_self on public.trip_transactions;
create policy trip_transactions_delete_self on public.trip_transactions
  for delete to authenticated using (auth.uid() = user_id);

-- Grants. RLS default-denies, so an anon select grant is harmless and matches
-- the 0001 tables; the write grants are what `authenticated` actually needs.
grant select on public.trips, public.trip_lines, public.trip_transactions to anon;
grant select, insert, update, delete
  on public.trips, public.trip_lines, public.trip_transactions to authenticated;
grant all on public.trips, public.trip_lines, public.trip_transactions to service_role;

-- ── trip_totals ─────────────────────────────────────────────────────────────
-- One row per trip for the list screen: planned, actually spent, how many rows
-- back that up. Aggregated here so the list is a single request no matter how
-- many transactions a trip collects.
--
-- The outflow filter mirrors overspend_status() / monthly_spend() /
-- BankTransaction.countsTowardDailyCap. A trip total built on a different
-- definition of "spent" than the rest of the app would be indefensible.
create or replace function public.trip_totals()
returns table (
  trip_id       uuid,
  name          text,
  kind          text,
  starts_on     date,
  ends_on       date,
  budget_cents  bigint,
  planned_cents bigint,
  spent_cents   bigint,
  txn_count     int,
  line_count    int
)
language sql
stable
security invoker
set search_path = public
as $$
  select t.id,
         t.name,
         t.kind,
         t.starts_on,
         t.ends_on,
         t.budget_cents,
         coalesce(l.planned_cents, 0) as planned_cents,
         coalesce(s.spent_cents, 0)   as spent_cents,
         coalesce(s.txn_count, 0)     as txn_count,
         coalesce(l.line_count, 0)    as line_count
    from public.trips t
    left join lateral (
      select sum(tl.planned_cents)::bigint as planned_cents,
             count(*)::int                 as line_count
        from public.trip_lines tl
       where tl.trip_id = t.id
    ) l on true
    left join lateral (
      select sum(tx.amount_cents)::bigint as spent_cents,
             count(*)::int                as txn_count
        from public.trip_transactions tt
        join public.transactions tx on tx.id = tt.transaction_id
       where tt.trip_id = t.id
         and tx.is_removed = false
         and tx.amount_cents > 0
         and not (tx.pending and tx.is_backfill)
    ) s on true
   where t.user_id = auth.uid()
   order by coalesce(t.starts_on, t.created_at::date) desc, t.created_at desc;
$$;
revoke execute on function public.trip_totals() from public, anon;
grant execute on function public.trip_totals() to authenticated, service_role;

-- ── trip_line_spend ─────────────────────────────────────────────────────────
-- The inside of one trip: every line with what was planned and what has landed
-- against it. Rows assigned to the trip but not to a line come back as a
-- single null-id row, so the screen can show "unfiled" without a second query
-- and the line totals plus that row always reconcile to trip_totals.
create or replace function public.trip_line_spend(trip uuid)
returns table (
  line_id       uuid,
  name          text,
  symbol        text,
  planned_cents bigint,
  occurs_on     date,
  sort_order    int,
  spent_cents   bigint,
  txn_count     int
)
language sql
stable
security invoker
set search_path = public
as $$
  with owned as (
    select id from public.trips where id = trip and user_id = auth.uid()
  ),
  spend as (
    select tt.line_id,
           sum(tx.amount_cents)::bigint as spent_cents,
           count(*)::int                as txn_count
      from public.trip_transactions tt
      join public.transactions tx on tx.id = tt.transaction_id
     where tt.trip_id = (select id from owned)
       and tx.is_removed = false
       and tx.amount_cents > 0
       and not (tx.pending and tx.is_backfill)
     group by tt.line_id
  )
  select tl.id,
         tl.name,
         tl.symbol,
         tl.planned_cents,
         tl.occurs_on,
         tl.sort_order,
         coalesce(s.spent_cents, 0) as spent_cents,
         coalesce(s.txn_count, 0)   as txn_count
    from public.trip_lines tl
    left join spend s on s.line_id = tl.id
   where tl.trip_id = (select id from owned)
  union all
  -- Assigned to the trip, filed under no line.
  select null::uuid,
         null::text,
         null::text,
         0::bigint,
         null::date,
         2147483647,       -- sorts last
         s.spent_cents,
         s.txn_count
    from spend s
   where s.line_id is null
   order by sort_order, name nulls last;
$$;
revoke execute on function public.trip_line_spend(uuid) from public, anon;
grant execute on function public.trip_line_spend(uuid) to authenticated, service_role;

-- ── trip_candidates ─────────────────────────────────────────────────────────
-- What the user is offered when filing a trip: transactions inside the trip's
-- dates that are not already assigned to some trip. This *suggests*; nothing
-- here assigns anything.
--
-- A trip with no dates returns nothing rather than the user's entire history —
-- offering every transaction they have ever made is not a useful review queue.
create or replace function public.trip_candidates(trip uuid, max_rows int default 200)
returns table (
  transaction_id uuid,
  date           date,
  name           text,
  merchant_name  text,
  amount_cents   bigint,
  pending        boolean
)
language sql
stable
security invoker
set search_path = public
as $$
  with owned as (
    select id, starts_on, ends_on
      from public.trips
     where id = trip and user_id = auth.uid()
       and starts_on is not null and ends_on is not null
  )
  select tx.id,
         tx.date,
         tx.name,
         tx.merchant_name,
         tx.amount_cents,
         tx.pending
    from public.transactions tx
    join owned o on tx.date between o.starts_on and o.ends_on
   where tx.user_id = auth.uid()
     and tx.is_removed = false
     and tx.amount_cents > 0
     and not (tx.pending and tx.is_backfill)
     and not exists (
       select 1 from public.trip_transactions tt where tt.transaction_id = tx.id
     )
   order by tx.date desc, tx.amount_cents desc
   limit least(greatest(coalesce(max_rows, 200), 1), 500);
$$;
revoke execute on function public.trip_candidates(uuid, int) from public, anon;
grant execute on function public.trip_candidates(uuid, int) to authenticated, service_role;

-- ── trip_assigned ───────────────────────────────────────────────────────────
-- The transactions already on a trip, for the detail screen and for unfiling.
create or replace function public.trip_assigned(trip uuid)
returns table (
  transaction_id uuid,
  line_id        uuid,
  date           date,
  name           text,
  merchant_name  text,
  amount_cents   bigint,
  pending        boolean
)
language sql
stable
security invoker
set search_path = public
as $$
  select tx.id,
         tt.line_id,
         tx.date,
         tx.name,
         tx.merchant_name,
         tx.amount_cents,
         tx.pending
    from public.trip_transactions tt
    join public.transactions tx on tx.id = tt.transaction_id
    join public.trips t on t.id = tt.trip_id
   where tt.trip_id = trip
     and t.user_id = auth.uid()
     and tx.is_removed = false
   order by tx.date desc;
$$;
revoke execute on function public.trip_assigned(uuid) from public, anon;
grant execute on function public.trip_assigned(uuid) to authenticated, service_role;

-- ── overspend_status: trip spending leaves the daily cap ────────────────────
-- Identical to 0004 but for the trip_transactions exclusion. A hotel or a
-- flight is not a failure of today's discretionary budget, and an over-cap
-- push on the day of a booking is noise the user cannot act on — which is how
-- an alert stops being read at all.
--
-- Only explicitly assigned rows drop out. See the header of this file.
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
   -- A pending row inherited at link time has the link date, not a purchase
   -- date. Skip it; it counts on its real day once it posts.
   and not (t.pending and t.is_backfill)
   -- Assigned to a trip: budgeted there, not against today's cap.
   and not exists (
     select 1 from public.trip_transactions tt where tt.transaction_id = t.id
   )
  group by p.user_id, p.timezone, b.daily_limit_cents, b.warn_pct;
$$;
revoke execute on function public.overspend_status() from public, anon, authenticated;

notify pgrst, 'reload schema';

-- ==========================================================================
-- 0011_revoke_anon_writes.sql
-- ==========================================================================

-- 0011_revoke_anon_writes: take INSERT/UPDATE/DELETE away from `anon`.
--
-- Found while adding the trip tables: every table in `public` carried anon
-- write grants, including `transactions` and `plaid_items`. That is not
-- something 0001–0010 did — it is Supabase's stock
-- `alter default privileges ... grant all on tables to anon`, which applies to
-- every table created in the schema, so each migration silently re-acquired it.
--
-- Nothing was exploitable: RLS is enabled on all twelve tables and every policy
-- keys off `user_id = auth.uid()`, which is NULL for an anon caller, so writes
-- were already refused. This removes the second half of the defence — a table
-- shipped one day with RLS off, or a policy written `using (true)` for a
-- genuinely public read, would otherwise be world-writable through the Data API
-- rather than merely world-readable.
--
-- SELECT is deliberately left alone. RLS default-denies it and 0001 grants it
-- on purpose.
--
-- Nothing in the app writes as `anon`: the client only reaches the Data API
-- after sign-in (role `authenticated`), sign-up goes through GoTrue rather than
-- a table write, `profiles` rows come from the `handle_new_user` trigger which
-- is security definer, and the edge functions use the service-role key.

revoke insert, update, delete on all tables in schema public from anon;

-- And stop the next migration from re-granting them by default.
alter default privileges in schema public revoke insert, update, delete on tables from anon;
alter default privileges for role postgres in schema public
  revoke insert, update, delete on tables from anon;

notify pgrst, 'reload schema';

-- ==========================================================================
-- 0012_trip_line_settled.sql
-- ==========================================================================

-- 0012_trip_line_settled: tick a trip's cost line off as paid or done.
--
-- A trip line is half budget, half checklist: "Flights, $800, Sep 2" is
-- something you plan *and* something you eventually book. Plenty of it gets
-- paid on a card the app can't see, months ahead, or by someone else — so
-- "handled" cannot be inferred from the transactions we mirror. It has to be
-- something the user asserts.
--
-- A timestamp rather than a boolean: "when did I pay this" is free, and it
-- reads unambiguously (null = outstanding). Nothing derives money from it.
--
-- Deliberately NOT wired into any total. Ticking a line does not add to the
-- trip's spend: that number means "money we watched leave the account", and
-- letting a checkbox inflate it would make the one honest figure on the screen
-- a mix of fact and intention. The count of ticked lines is shown separately.

alter table public.trip_lines
  add column if not exists settled_at timestamptz;

comment on column public.trip_lines.settled_at is
  'When the user ticked this line off as paid/done. Null = outstanding. '
  'Never feeds a spend total — see 0012.';

-- trip_line_spend gains settled_at. Otherwise identical to 0010: the outflow
-- filter still mirrors overspend_status(), and the unfiled row is still the
-- synthetic null-id row that makes the lines reconcile to trip_totals.
--
-- Dropped first, not `create or replace`: adding an OUT column changes the
-- function's return type, which Postgres refuses to replace in place
-- (42P13). The drop and create run in one statement batch, so PostgREST never
-- sees a window without it.
drop function if exists public.trip_line_spend(uuid);
create or replace function public.trip_line_spend(trip uuid)
returns table (
  line_id       uuid,
  name          text,
  symbol        text,
  planned_cents bigint,
  occurs_on     date,
  sort_order    int,
  spent_cents   bigint,
  txn_count     int,
  settled_at    timestamptz
)
language sql
stable
security invoker
set search_path = public
as $$
  with owned as (
    select id from public.trips where id = trip and user_id = auth.uid()
  ),
  spend as (
    select tt.line_id,
           sum(tx.amount_cents)::bigint as spent_cents,
           count(*)::int                as txn_count
      from public.trip_transactions tt
      join public.transactions tx on tx.id = tt.transaction_id
     where tt.trip_id = (select id from owned)
       and tx.is_removed = false
       and tx.amount_cents > 0
       and not (tx.pending and tx.is_backfill)
     group by tt.line_id
  )
  select tl.id,
         tl.name,
         tl.symbol,
         tl.planned_cents,
         tl.occurs_on,
         tl.sort_order,
         coalesce(s.spent_cents, 0) as spent_cents,
         coalesce(s.txn_count, 0)   as txn_count,
         tl.settled_at
    from public.trip_lines tl
    left join spend s on s.line_id = tl.id
   where tl.trip_id = (select id from owned)
  union all
  -- Assigned to the trip, filed under no line. Never settleable: it is a
  -- rollup, not something anyone created.
  select null::uuid,
         null::text,
         null::text,
         0::bigint,
         null::date,
         2147483647,       -- sorts last
         s.spent_cents,
         s.txn_count,
         null::timestamptz
    from spend s
   where s.line_id is null
   order by sort_order, name nulls last;
$$;
revoke execute on function public.trip_line_spend(uuid) from public, anon;
grant execute on function public.trip_line_spend(uuid) to authenticated, service_role;

-- ==========================================================================
-- 0013_cron_statements.sql
-- ==========================================================================

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

notify pgrst, 'reload schema';

-- ============================================================
-- 0015_monthly_balances.sql
-- ============================================================

-- 0015_monthly_balances: start/end checking balance per month for the Months tab.
--
-- The bank reports one balance — now. Every month boundary is derived from it
-- by walking the posted transactions backwards: the balance at the end of a
-- month is today's balance plus every outflow (minus every inflow) dated after
-- it. That derivation only involves transactions AFTER the boundary, so missing
-- history older than a boundary cannot corrupt it — which is why months before
-- the first transaction on record are omitted entirely rather than shown with
-- an invented balance.
--
-- Checking accounts only (type depository/checking): a savings balance mixed in
-- would make "what my checking did this month" unanswerable, and cards don't
-- have a balance in this sense at all.
--
-- Posted transactions only (pending = false). A statement's start/end balances
-- are posted figures, and Plaid's `current` balance tracks posted activity;
-- mixing pending rows in would double-count them the day they post.
--
-- Depends on sync.ts refreshing accounts.current_balance_cents on every sync
-- (shipped alongside this migration). A link-time balance plus post-link
-- transactions would disagree by every dollar spent since linking.
--
-- security invoker on purpose, like monthly_spend(): accounts and transactions
-- are RLS'd self-only, so the function only ever sees the caller's rows.

create or replace function public.monthly_balances(months_back int default 12)
returns table (
  period      date,     -- first day of the month, in the user's timezone
  start_cents bigint,   -- balance going into the month
  end_cents   bigint    -- balance leaving it (current month: balance now)
)
language sql
stable
security invoker
set search_path = public
as $$
  with tz as (
    select coalesce(max(p.timezone), 'UTC') as name
      from public.profiles p
     where p.user_id = auth.uid()
  ),
  checking as (
    select a.id, a.current_balance_cents
      from public.accounts a
     where a.user_id = auth.uid()
       and a.type = 'depository'
       and a.subtype = 'checking'
       and a.current_balance_cents is not null
  ),
  anchor as (
    select sum(c.current_balance_cents)::bigint as cents,
           count(*)                             as accounts
      from checking c
  ),
  txns as (
    -- Net movement, not the outflow filter the spend rollups share: a balance
    -- moves on money in as much as money out. amount_cents > 0 is money out
    -- (Plaid convention), so later transactions are ADDED back when deriving
    -- an earlier balance.
    select t.date, t.amount_cents
      from public.transactions t
      join checking c on c.id = t.account_id
     where t.user_id = auth.uid()
       and t.is_removed = false
       and t.pending = false
  ),
  bounds as (
    select date_trunc('month', (now() at time zone (select name from tz))::date)::date as this_month,
           least(greatest(coalesce(months_back, 12), 1), 36) as span
  ),
  first_month as (
    select date_trunc('month', min(x.date))::date as m from txns x
  ),
  months as (
    select generate_series(
             greatest((b.this_month - ((b.span - 1) || ' months')::interval)::date, f.m),
             b.this_month,
             interval '1 month'
           )::date as period
      from bounds b, first_month f
     where f.m is not null
  )
  select m.period,
         (select a.cents from anchor a)
           + coalesce((select sum(x.amount_cents) from txns x
                        where x.date >= m.period), 0)                          as start_cents,
         (select a.cents from anchor a)
           + coalesce((select sum(x.amount_cents) from txns x
                        where x.date >= (m.period + interval '1 month')::date), 0) as end_cents
    from months m
   where (select a.accounts from anchor a) > 0
   order by m.period;
$$;

comment on function public.monthly_balances(int) is
  'Checking-account balance at the start and end of each of the last N calendar '
  'months (default 12) in the caller''s timezone, derived from the current '
  'balance and posted transactions. Months before the first transaction on '
  'record are omitted — their balances would be invented, not derived.';

revoke execute on function public.monthly_balances(int) from public, anon;
grant execute on function public.monthly_balances(int) to authenticated, service_role;

notify pgrst, 'reload schema';

-- ============================================================
-- 0016_category_kinds.sql
-- ============================================================

-- 0016_category_kinds: a fixed type tag per budget line.
--
-- "Which line is rent?" was answerable only by reading the names the user
-- happened to type ("Rent/Wifi/Utilities"), which nothing can build on. The
-- tag is a field with a closed set of values, picked in the edit-line sheet
-- alongside the free-text name — the name stays whatever the user wants to
-- call it, the kind says what it *is*.
--
-- Nullable on purpose: untagged is a valid state, not a default guess.

alter table public.budget_categories
  add column if not exists kind text;

alter table public.budget_categories
  drop constraint if exists budget_categories_kind_check;

alter table public.budget_categories
  add constraint budget_categories_kind_check check (
    kind is null or kind in (
      -- 'debt' added in 0017, 'personal_care' in 0019: committed money the
      -- client fences off from the discretionary free-to-spend budget.
      'rent', 'debt', 'food', 'transportation', 'utilities', 'subscriptions',
      'entertainment', 'health', 'savings', 'personal_care', 'other'
    )
  );

-- category_spend() grows a `kind` column, which changes its return type —
-- Postgres refuses create-or-replace over that (42P13), so drop first, in the
-- same batch so PostgREST never sees a gap (the 0012 lesson). Grants do not
-- survive the drop and are re-applied below.
drop function if exists public.category_spend(int);

create function public.category_spend(months_back int default 2)
returns table (
  period        date,
  category_id   uuid,
  category_name text,
  planned_cents int,
  spent_cents   bigint,
  txn_count     int,
  sort_order    int,
  kind          text
)
language sql
stable
security invoker
set search_path = public
as $$
  with tz as (
    select coalesce(max(p.timezone), 'UTC') as name
      from public.profiles p
     where p.user_id = auth.uid()
  ),
  bounds as (
    select date_trunc('month', (now() at time zone (select name from tz))::date)::date as this_month,
           least(greatest(coalesce(months_back, 2), 1), 24) as span
  ),
  months as (
    select generate_series(
             b.this_month - ((b.span - 1) || ' months')::interval,
             b.this_month,
             interval '1 month'
           )::date as period
      from bounds b
  ),
  txn as (
    select t.id,
           date_trunc('month', t.date)::date as period,
           t.amount_cents,
           coalesce(nullif(trim(t.merchant_name), ''), t.name) as who,
           t.category
      from public.transactions t
     where t.user_id = auth.uid()
       and t.is_removed = false
       and t.amount_cents > 0
       -- Same outflow filter as overspend_status() and monthly_spend().
       and not (t.pending and t.is_backfill)
       and t.date >= (select min(period) from months)
  ),
  matched as (
    select x.*,
           (
             select r.category_id
               from public.category_rules r
              where r.user_id = auth.uid()
                and (
                     (r.match_type = 'merchant_contains' and x.who ilike '%' || r.match_value || '%')
                  or (r.match_type = 'plaid_category'    and x.category = r.match_value)
                )
              -- Most specific wins: a named merchant beats a whole Plaid
              -- category, and a longer merchant string beats a shorter one.
              order by (r.match_type = 'merchant_contains') desc,
                       length(r.match_value) desc
              limit 1
           ) as category_id
      from txn x
  )
  select m.period,
         c.id                                     as category_id,
         c.name                                   as category_name,
         c.planned_cents,
         coalesce(sum(x.amount_cents), 0)::bigint as spent_cents,
         count(x.id)::int                         as txn_count,
         c.sort_order,
         c.kind
    from months m
    cross join public.budget_categories c
    left join matched x
      on x.period = m.period
     and x.category_id = c.id
   where c.user_id = auth.uid()
   group by m.period, c.id, c.name, c.planned_cents, c.sort_order, c.kind

  union all

  select m.period,
         null::uuid,
         'Uncategorized',
         0,
         coalesce(sum(x.amount_cents), 0)::bigint,
         count(x.id)::int,
         2147483647,         -- always last
         null::text          -- unclaimed spending has no kind by definition
    from months m
    left join matched x
      on x.period = m.period
     and x.category_id is null
   group by m.period

   order by 1 desc, 7, 3;
$$;

comment on function public.category_spend(int) is
  'Planned vs actual per budget line for the last N calendar months (default '
  '2), newest first, one Uncategorized row per month for unclaimed spending. '
  'Rules apply at read time; kind is the line''s fixed type tag (rent, food, '
  '...) or null when untagged.';

revoke execute on function public.category_spend(int) from public, anon;
grant execute on function public.category_spend(int) to authenticated, service_role;

notify pgrst, 'reload schema';

-- ==========================================================================
-- 0018_overdraft_fee_names.sql
-- ==========================================================================

-- 0018_overdraft_fee_names: a bank fee never wears a merchant's name.
--
-- Wells Fargo names an overdraft fee after the purchase that overdrew the
-- account ("OVERDRAFT FEE FOR A TRANSACTION POSTED ON 07/27 $50.50
-- AFFIRM.COM ..."), and Plaid extracts that merchant into merchant_name — so
-- a $35 fee masquerades as an Affirm charge. Twice Plaid went further and
-- rewrote the *name* to just "Lyft", leaving BANK_FEES as the only signal.
-- The rollups' display/matching string (`who`) took merchant_name first, so
-- fees displayed as the merchant AND merchant rules claimed them: two Lyft
-- fees were filed under Transport, an Apple one under Debts via the "Apple"
-- rule.
--
-- Fix: BANK_FEES rows resolve to 'Overdraft fee' (when the bank's own text
-- says so) or 'Bank fee' (when Plaid erased it — never guess "overdraft"
-- from the category alone, a monthly service fee is BANK_FEES too). One
-- helper, used by every rollup, mirrored exactly by TransactionNaming in
-- Swift — the string the screen shows is the string rules match, so
-- reassigning an "Overdraft fee" row writes a rule that actually fires.
--
-- Consequence for matching precedence: fee rows can no longer be claimed by
-- the overdrawing merchant's rules; they fall through to any plaid_category
-- BANK_FEES rule (currently → Debts) or to Uncategorized.

create or replace function public.txn_display_name(
  name          text,
  merchant_name text,
  category      text
)
returns text
language sql
immutable
as $$
  select case
    when category = 'BANK_FEES' then
      case when name ilike '%overdraft fee%' then 'Overdraft fee'
           else 'Bank fee' end
    else coalesce(nullif(trim(merchant_name), ''), name)
  end
$$;

comment on function public.txn_display_name(text, text, text) is
  'How a transaction introduces itself everywhere: merchant name, falling '
  'back to the bank''s text — except BANK_FEES rows, which never take the '
  'overdrawing merchant''s name. Mirrored by TransactionNaming in the app.';

revoke execute on function public.txn_display_name(text, text, text) from public, anon;
grant execute on function public.txn_display_name(text, text, text) to authenticated, service_role;

-- The three rollups swap their inline `who` for the helper. Return types are
-- unchanged, so create-or-replace is safe and grants survive.

create or replace function public.category_spend(months_back int default 2)
returns table (
  period        date,
  category_id   uuid,
  category_name text,
  planned_cents int,
  spent_cents   bigint,
  txn_count     int,
  sort_order    int,
  kind          text
)
language sql
stable
security invoker
set search_path = public
as $$
  with tz as (
    select coalesce(max(p.timezone), 'UTC') as name
      from public.profiles p
     where p.user_id = auth.uid()
  ),
  bounds as (
    select date_trunc('month', (now() at time zone (select name from tz))::date)::date as this_month,
           least(greatest(coalesce(months_back, 2), 1), 24) as span
  ),
  months as (
    select generate_series(
             b.this_month - ((b.span - 1) || ' months')::interval,
             b.this_month,
             interval '1 month'
           )::date as period
      from bounds b
  ),
  txn as (
    select t.id,
           date_trunc('month', t.date)::date as period,
           t.amount_cents,
           public.txn_display_name(t.name, t.merchant_name, t.category) as who,
           t.category
      from public.transactions t
     where t.user_id = auth.uid()
       and t.is_removed = false
       and t.amount_cents > 0
       -- Same outflow filter as overspend_status() and monthly_spend().
       and not (t.pending and t.is_backfill)
       and t.date >= (select min(period) from months)
  ),
  matched as (
    select x.*,
           (
             select r.category_id
               from public.category_rules r
              where r.user_id = auth.uid()
                and (
                     (r.match_type = 'merchant_contains' and x.who ilike '%' || r.match_value || '%')
                  or (r.match_type = 'plaid_category'    and x.category = r.match_value)
                )
              -- Most specific wins: a named merchant beats a whole Plaid
              -- category, and a longer merchant string beats a shorter one.
              order by (r.match_type = 'merchant_contains') desc,
                       length(r.match_value) desc
              limit 1
           ) as category_id
      from txn x
  )
  select m.period,
         c.id                                     as category_id,
         c.name                                   as category_name,
         c.planned_cents,
         coalesce(sum(x.amount_cents), 0)::bigint as spent_cents,
         count(x.id)::int                         as txn_count,
         c.sort_order,
         c.kind
    from months m
    cross join public.budget_categories c
    left join matched x
      on x.period = m.period
     and x.category_id = c.id
   where c.user_id = auth.uid()
   group by m.period, c.id, c.name, c.planned_cents, c.sort_order, c.kind

  union all

  select m.period,
         null::uuid,
         'Uncategorized',
         0,
         coalesce(sum(x.amount_cents), 0)::bigint,
         count(x.id)::int,
         2147483647,         -- always last
         null::text          -- unclaimed spending has no kind by definition
    from months m
    left join matched x
      on x.period = m.period
     and x.category_id is null
   group by m.period

   order by 1 desc, 7, 3;
$$;

create or replace function public.category_transactions(
  category uuid,
  period   date
)
returns table (
  id             uuid,
  date           date,
  authorized_date date,
  name           text,
  merchant_name  text,
  plaid_category text,
  amount_cents   bigint,
  pending        boolean,
  is_backfill    boolean,
  account_name   text,
  account_mask   text
)
language sql
stable
security invoker
set search_path = public
as $$
  with txn as (
    select t.id, t.date, t.authorized_date, t.name, t.merchant_name,
           t.category as plaid_category, t.amount_cents, t.pending, t.is_backfill,
           a.name as account_name, a.mask as account_mask,
           public.txn_display_name(t.name, t.merchant_name, t.category) as who
      from public.transactions t
      left join public.accounts a on a.id = t.account_id
     where t.user_id = auth.uid()
       and t.is_removed = false
       and t.amount_cents > 0
       and not (t.pending and t.is_backfill)
       and t.date >= period
       and t.date < (period + interval '1 month')::date
  ),
  matched as (
    select x.*,
           (
             select r.category_id
               from public.category_rules r
              where r.user_id = auth.uid()
                and (
                     (r.match_type = 'merchant_contains' and x.who ilike '%' || r.match_value || '%')
                  or (r.match_type = 'plaid_category'    and x.plaid_category = r.match_value)
                )
              order by (r.match_type = 'merchant_contains') desc,
                       length(r.match_value) desc
              limit 1
           ) as category_id
      from txn x
  )
  select m.id, m.date, m.authorized_date, m.name, m.merchant_name,
         m.plaid_category, m.amount_cents::bigint, m.pending, m.is_backfill,
         m.account_name, m.account_mask
    from matched m
   where m.category_id is not distinct from category
   order by m.amount_cents desc;
$$;

create or replace function public.month_activity(period date)
returns table (
  id              uuid,
  date            date,
  authorized_date date,
  name            text,
  merchant_name   text,
  plaid_category  text,
  amount_cents    bigint,
  pending         boolean,
  is_backfill     boolean,
  account_name    text,
  account_mask    text,
  category_name   text
)
language sql
stable
security invoker
set search_path = public
as $$
  with txn as (
    select t.id, t.date, t.authorized_date, t.name, t.merchant_name,
           t.category as plaid_category, t.amount_cents, t.pending, t.is_backfill,
           a.name as account_name, a.mask as account_mask,
           public.txn_display_name(t.name, t.merchant_name, t.category) as who
      from public.transactions t
      left join public.accounts a on a.id = t.account_id
     where t.user_id = auth.uid()
       and t.is_removed = false
       and t.date >= period
       and t.date < (period + interval '1 month')::date
  ),
  matched as (
    select x.*,
           (
             select r.category_id
               from public.category_rules r
              where r.user_id = auth.uid()
                and (
                     (r.match_type = 'merchant_contains' and x.who ilike '%' || r.match_value || '%')
                  or (r.match_type = 'plaid_category'    and x.plaid_category = r.match_value)
                )
              order by (r.match_type = 'merchant_contains') desc,
                       length(r.match_value) desc
              limit 1
           ) as category_id
      from txn x
  )
  select m.id, m.date, m.authorized_date, m.name, m.merchant_name,
         m.plaid_category, m.amount_cents::bigint, m.pending, m.is_backfill,
         m.account_name, m.account_mask,
         -- Money in is never "in" a budget line, so it is not mislabelled as
         -- Uncategorized, which on this screen would read as a gap to fix.
         case
           when m.amount_cents <= 0 then null
           else coalesce(c.name, 'Uncategorized')
         end as category_name
    from matched m
    left join public.budget_categories c on c.id = m.category_id
   order by m.date desc, abs(m.amount_cents) desc;
$$;

notify pgrst, 'reload schema';

-- ==========================================================================
-- 0020_item_refresh_nudge.sql
-- ==========================================================================

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

-- ==========================================================================
-- 0021_amount_qualified_rules.sql
-- ==========================================================================

-- 0021_amount_qualified_rules: a rule can require an exact amount.
--
-- An Apple Cash descriptor never names the recipient — every send reads
-- "MONEY TRANSFER AUTHORIZED ON <date> APPLE CASH SENT MO …" — so no string
-- rule can tell a haircut from anything else sent by Apple Cash. The amount
-- can: every $100 send in the history (six, since May) was Divine's haircut,
-- and no other Apple Cash amount is $100. `category_rules.amount_cents`
-- (null = any amount, the existing behavior) lets a rule say both things at
-- once: match the phrase AND the exact amount.
--
-- Precedence gains a middle tier: merchant beats category, an
-- amount-qualified rule beats an unqualified one, longer match beats
-- shorter. Without that middle tier the broad one-shot strings (97 chars)
-- would outrank the qualified rule on length alone.
--
-- The unique constraint stays (user_id, match_type, match_value) — shipped
-- clients upsert against exactly those columns. Consequence: one match_value
-- can carry at most one amount qualifier. Fine until someone needs two.

alter table public.category_rules
  add column if not exists amount_cents int;

create or replace function public.category_spend(months_back int default 2)
returns table (
  period        date,
  category_id   uuid,
  category_name text,
  planned_cents int,
  spent_cents   bigint,
  txn_count     int,
  sort_order    int,
  kind          text
)
language sql
stable
security invoker
set search_path = public
as $$
  with tz as (
    select coalesce(max(p.timezone), 'UTC') as name
      from public.profiles p
     where p.user_id = auth.uid()
  ),
  bounds as (
    select date_trunc('month', (now() at time zone (select name from tz))::date)::date as this_month,
           least(greatest(coalesce(months_back, 2), 1), 24) as span
  ),
  months as (
    select generate_series(
             b.this_month - ((b.span - 1) || ' months')::interval,
             b.this_month,
             interval '1 month'
           )::date as period
      from bounds b
  ),
  txn as (
    select t.id,
           date_trunc('month', t.date)::date as period,
           t.amount_cents,
           public.txn_display_name(t.name, t.merchant_name, t.category) as who,
           t.category
      from public.transactions t
     where t.user_id = auth.uid()
       and t.is_removed = false
       and t.amount_cents > 0
       -- Same outflow filter as overspend_status() and monthly_spend().
       and not (t.pending and t.is_backfill)
       and t.date >= (select min(period) from months)
  ),
  matched as (
    select x.*,
           (
             select r.category_id
               from public.category_rules r
              where r.user_id = auth.uid()
                and (r.amount_cents is null or r.amount_cents = x.amount_cents)
                and (
                     (r.match_type = 'merchant_contains' and x.who ilike '%' || r.match_value || '%')
                  or (r.match_type = 'plaid_category'    and x.category = r.match_value)
                )
              -- Most specific wins: a named merchant beats a whole Plaid
              -- category, an amount-qualified rule beats an unqualified one,
              -- and a longer merchant string beats a shorter one.
              order by (r.match_type = 'merchant_contains') desc,
                       (r.amount_cents is not null) desc,
                       length(r.match_value) desc
              limit 1
           ) as category_id
      from txn x
  )
  select m.period,
         c.id                                     as category_id,
         c.name                                   as category_name,
         c.planned_cents,
         coalesce(sum(x.amount_cents), 0)::bigint as spent_cents,
         count(x.id)::int                         as txn_count,
         c.sort_order,
         c.kind
    from months m
    cross join public.budget_categories c
    left join matched x
      on x.period = m.period
     and x.category_id = c.id
   where c.user_id = auth.uid()
   group by m.period, c.id, c.name, c.planned_cents, c.sort_order, c.kind

  union all

  select m.period,
         null::uuid,
         'Uncategorized',
         0,
         coalesce(sum(x.amount_cents), 0)::bigint,
         count(x.id)::int,
         2147483647,         -- always last
         null::text          -- unclaimed spending has no kind by definition
    from months m
    left join matched x
      on x.period = m.period
     and x.category_id is null
   group by m.period

   order by 1 desc, 7, 3;
$$;

create or replace function public.category_transactions(
  category uuid,
  period   date
)
returns table (
  id             uuid,
  date           date,
  authorized_date date,
  name           text,
  merchant_name  text,
  plaid_category text,
  amount_cents   bigint,
  pending        boolean,
  is_backfill    boolean,
  account_name   text,
  account_mask   text
)
language sql
stable
security invoker
set search_path = public
as $$
  with txn as (
    select t.id, t.date, t.authorized_date, t.name, t.merchant_name,
           t.category as plaid_category, t.amount_cents, t.pending, t.is_backfill,
           a.name as account_name, a.mask as account_mask,
           public.txn_display_name(t.name, t.merchant_name, t.category) as who
      from public.transactions t
      left join public.accounts a on a.id = t.account_id
     where t.user_id = auth.uid()
       and t.is_removed = false
       and t.amount_cents > 0
       and not (t.pending and t.is_backfill)
       and t.date >= period
       and t.date < (period + interval '1 month')::date
  ),
  matched as (
    select x.*,
           (
             select r.category_id
               from public.category_rules r
              where r.user_id = auth.uid()
                and (r.amount_cents is null or r.amount_cents = x.amount_cents)
                and (
                     (r.match_type = 'merchant_contains' and x.who ilike '%' || r.match_value || '%')
                  or (r.match_type = 'plaid_category'    and x.plaid_category = r.match_value)
                )
              order by (r.match_type = 'merchant_contains') desc,
                       (r.amount_cents is not null) desc,
                       length(r.match_value) desc
              limit 1
           ) as category_id
      from txn x
  )
  select m.id, m.date, m.authorized_date, m.name, m.merchant_name,
         m.plaid_category, m.amount_cents::bigint, m.pending, m.is_backfill,
         m.account_name, m.account_mask
    from matched m
   where m.category_id is not distinct from category
   order by m.amount_cents desc;
$$;

create or replace function public.month_activity(period date)
returns table (
  id              uuid,
  date            date,
  authorized_date date,
  name            text,
  merchant_name   text,
  plaid_category  text,
  amount_cents    bigint,
  pending         boolean,
  is_backfill     boolean,
  account_name    text,
  account_mask    text,
  category_name   text
)
language sql
stable
security invoker
set search_path = public
as $$
  with txn as (
    select t.id, t.date, t.authorized_date, t.name, t.merchant_name,
           t.category as plaid_category, t.amount_cents, t.pending, t.is_backfill,
           a.name as account_name, a.mask as account_mask,
           public.txn_display_name(t.name, t.merchant_name, t.category) as who
      from public.transactions t
      left join public.accounts a on a.id = t.account_id
     where t.user_id = auth.uid()
       and t.is_removed = false
       and t.date >= period
       and t.date < (period + interval '1 month')::date
  ),
  matched as (
    select x.*,
           (
             select r.category_id
               from public.category_rules r
              where r.user_id = auth.uid()
                and (r.amount_cents is null or r.amount_cents = x.amount_cents)
                and (
                     (r.match_type = 'merchant_contains' and x.who ilike '%' || r.match_value || '%')
                  or (r.match_type = 'plaid_category'    and x.plaid_category = r.match_value)
                )
              order by (r.match_type = 'merchant_contains') desc,
                       (r.amount_cents is not null) desc,
                       length(r.match_value) desc
              limit 1
           ) as category_id
      from txn x
  )
  select m.id, m.date, m.authorized_date, m.name, m.merchant_name,
         m.plaid_category, m.amount_cents::bigint, m.pending, m.is_backfill,
         m.account_name, m.account_mask,
         -- Money in is never "in" a budget line, so it is not mislabelled as
         -- Uncategorized, which on this screen would read as a gap to fix.
         case
           when m.amount_cents <= 0 then null
           else coalesce(c.name, 'Uncategorized')
         end as category_name
    from matched m
    left join public.budget_categories c on c.id = m.category_id
   order by m.date desc, abs(m.amount_cents) desc;
$$;

notify pgrst, 'reload schema';
