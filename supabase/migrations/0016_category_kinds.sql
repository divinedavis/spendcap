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
      'rent', 'food', 'transportation', 'utilities', 'subscriptions',
      'entertainment', 'health', 'savings', 'other'
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
