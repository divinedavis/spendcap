-- 0032_debt_usual_is_last_month: "usually" on the Debt tab is what was paid
-- the month before, not a three-month median.
--
-- 0031 measured each item's usual amount as the median of the three full
-- months before the viewed one. The owner reads "usually $X" as "what this
-- cost me last month" and asked for exactly that. Only the `typical` CTE and
-- the history window change; the matching subquery, the outflow filter and
-- the return shape are 0031's, so the app reads it unchanged.

drop function if exists public.debt_summary(date);

create function public.debt_summary(period date default null)
returns table (
  group_id    uuid,
  group_name  text,
  group_sort  int,
  item_id     uuid,
  item_name   text,
  note        text,
  planned_cents int,
  paid_cents  bigint,
  txn_count   int,
  match_value text,
  match_amount_cents int,
  item_sort   int,
  typical_cents bigint,
  months_seen int
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
    select date_trunc(
             'month',
             coalesce(period, (now() at time zone (select name from tz))::date)
           )::date as start
  ),
  -- The viewed month plus the month before it, in one pass, so
  -- history and paid are matched by the same subquery over the same rows.
  txn as (
    select t.id,
           t.amount_cents,
           date_trunc('month', t.date)::date as month,
           public.txn_display_name(t.name, t.merchant_name, t.category) as who
      from public.transactions t, bounds b
     where t.user_id = auth.uid()
       and t.is_removed = false
       and t.amount_cents > 0
       and not (t.pending and t.is_backfill)
       and t.date >= (b.start - interval '1 month')::date
       and t.date < (b.start + interval '1 month')::date
  ),
  matched as (
    select x.id,
           x.amount_cents,
           x.month,
           (
             select d.id
               from public.debt_items d
              where d.user_id = auth.uid()
                and d.match_value is not null
                and x.who ilike '%' || d.match_value || '%'
                and (d.match_amount_cents is null
                     or d.match_amount_cents = x.amount_cents)
              -- Amount-qualified beats unqualified, then the longer string.
              -- The id tiebreak only exists so the choice is stable across
              -- reads; without it two equal-length rules could swap and the
              -- subtotals would flicker.
              order by (d.match_amount_cents is not null) desc,
                       length(d.match_value) desc,
                       d.sort_order,
                       d.id
              limit 1
           ) as item_id
      from txn x
  ),
  -- Every tracked item × the month before the viewed one, zero-filled, so a
  -- month with no charge reads $0 rather than vanishing.
  history as (
    select i.id as item_id,
           h.month,
           coalesce((select sum(m.amount_cents)
                       from matched m
                      where m.item_id = i.id and m.month = h.month), 0) as cents
      from public.debt_items i
      cross join bounds b
      cross join lateral (
        select (b.start - (n || ' months')::interval)::date as month
          from generate_series(1, 1) n
      ) h
     where i.user_id = auth.uid()
       and i.match_value is not null
  ),
  -- "Usually" is last month's paid figure, exactly (owner, 2026-10-06:
  -- "usually should mean what I paid the previous month"). Not a median:
  -- the owner reads the word as "what this cost me last month".
  typical as (
    select h.item_id,
           h.cents::bigint as cents,
           (h.cents > 0)::int as seen
      from history h, bounds b
     where h.month = (b.start - interval '1 month')::date
  ),
  paid as (
    select m.item_id, sum(m.amount_cents)::bigint as cents, count(*)::int as n
      from matched m, bounds b
     where m.month = b.start
       and m.item_id is not null
     group by m.item_id
  )
  select g.id,
         g.name,
         g.sort_order,
         i.id,
         i.name,
         i.note,
         i.planned_cents,
         coalesce(p.cents, 0)::bigint,
         coalesce(p.n, 0)::int,
         i.match_value,
         i.match_amount_cents,
         i.sort_order,
         ty.cents,
         coalesce(ty.seen, 0)::int
    from public.debt_groups g
    left join public.debt_items i
      on i.group_id = g.id
     and i.user_id = g.user_id
    left join paid p on p.item_id = i.id
    left join typical ty on ty.item_id = i.id
   where g.user_id = auth.uid()
   order by g.sort_order, g.name, i.sort_order, i.name
$$;

comment on function public.debt_summary(date) is
  'Debt tab: every obligation with its typed plan, what posted against it in '
  '`period` (default: this month, user timezone), and typical_cents — what '
  'posted against it in the month before `period` (months_seen 1 if anything '
  'did). Empty groups come back as a row with a null item_id. A transaction '
  'is claimed by at most one item.';

revoke execute on function public.debt_summary(date) from public, anon;
grant execute on function public.debt_summary(date) to authenticated, service_role;

notify pgrst, 'reload schema';
