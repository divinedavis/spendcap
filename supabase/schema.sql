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
