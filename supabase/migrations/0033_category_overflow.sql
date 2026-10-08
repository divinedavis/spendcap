-- 0033_category_overflow: a line can spill its overage into another line.
--
-- Divine asked (2026-10-08) that once Food hits its plan, further Food
-- spending count against Socializing — overspending on food means there is
-- that much less to go out with, and the budget card should say so instead of
-- showing Socializing with untouched room beside an over Food line.
--
-- `budget_categories.overflow_category_id` names the line that absorbs the
-- overage. Null (the default) is today's behavior: a line just goes over.
--
-- This is deliberately a *display* reallocation done by the client
-- (`CategoryMath`), not a re-routing of transactions. The rules still file
-- every transaction where they always did, so `category_transactions`,
-- `month_activity`, `discretionary_daily` and the debt functions are
-- untouched, and the five copies of the rule-resolution block stay identical.
-- The rollup only has to report the setting, so `category_spend` gains one
-- trailing column; its body is otherwise 0021's verbatim.
--
-- Same-user is enforced by a composite FK on (user_id, overflow_category_id),
-- so no row can point at another account's line. Deleting the target clears
-- only the overflow column (PG15+ column-list SET NULL); user_id is not null
-- and must not be touched.

alter table public.budget_categories
  add column if not exists overflow_category_id uuid;

alter table public.budget_categories
  drop constraint if exists budget_categories_user_id_id_key;
alter table public.budget_categories
  add constraint budget_categories_user_id_id_key unique (user_id, id);

alter table public.budget_categories
  drop constraint if exists budget_categories_overflow_fkey;
alter table public.budget_categories
  add constraint budget_categories_overflow_fkey
  foreign key (user_id, overflow_category_id)
  references public.budget_categories (user_id, id)
  on delete set null (overflow_category_id);

alter table public.budget_categories
  drop constraint if exists budget_categories_overflow_not_self;
alter table public.budget_categories
  add constraint budget_categories_overflow_not_self
  check (overflow_category_id is null or overflow_category_id <> id);

-- Return type changes, which `create or replace` refuses (42P13).
drop function if exists public.category_spend(int);

create function public.category_spend(months_back int default 2)
returns table (
  period               date,
  category_id          uuid,
  category_name        text,
  planned_cents        int,
  spent_cents          bigint,
  txn_count            int,
  sort_order           int,
  kind                 text,
  overflow_category_id uuid
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
         c.kind,
         c.overflow_category_id
    from months m
    cross join public.budget_categories c
    left join matched x
      on x.period = m.period
     and x.category_id = c.id
   where c.user_id = auth.uid()
   group by m.period, c.id, c.name, c.planned_cents, c.sort_order, c.kind,
            c.overflow_category_id

  union all

  select m.period,
         null::uuid,
         'Uncategorized',
         0,
         coalesce(sum(x.amount_cents), 0)::bigint,
         count(x.id)::int,
         2147483647,         -- always last
         null::text,         -- unclaimed spending has no kind by definition
         null::uuid          -- and nowhere to spill: it has no plan to exceed
    from months m
    left join matched x
      on x.period = m.period
     and x.category_id is null
   group by m.period

   order by 1 desc, 7, 3;
$$;

comment on function public.category_spend(int) is
  'Planned vs actual by category for the last N months (default 2), newest '
  'month first, plus an Uncategorized line. Rules apply at read time; kind is '
  'the line''s type tag; overflow_category_id is the line that absorbs this '
  'line''s overage on screen (client-side reallocation, not re-routing).';

revoke execute on function public.category_spend(int) from public, anon;
grant execute on function public.category_spend(int) to authenticated, service_role;

notify pgrst, 'reload schema';
