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
