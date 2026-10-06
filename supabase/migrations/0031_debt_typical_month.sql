-- 0031_debt_typical_month: the monthly figure on a tracked Debt row is worked
-- out from its charges, and every Debt read can be pointed at a past month.
--
-- The typed plan was the weakest number on the tab. Against the account this
-- was built on, 17 of 39 tracked rows had a plan of $0 while charging every
-- month, and the ones that had a plan were stale: "Claude $100" charges ~$131,
-- "Digital Ocean $100" charged $75 last month. The tab already knew the truth —
-- it shows paid beside planned — and was still asking the user to type it.
--
-- **Typical = the median of the three full months before the viewed month,
-- zeros included.** Not the last month alone: an annual-ish or late bill
-- (YouTube Premium skipped September and charged on 1 October) would read as
-- $0. Not the mean: one $1,350 Best Buy payment would make a $450/mo row out
-- of a single purchase. The median of three with zeros counted says "this
-- charges in most months, and about this much"; a one-off charge in one month
-- of three comes out $0, which is the honest monthly figure for a one-off —
-- unless that one month is the last one, which is what a subscription that has
-- just started looks like, so then its single bill is the figure.
-- Only full months, so the figure does not wobble day to day as the current
-- month fills in.
--
-- `months_seen` is how many of those three months charged at all. The app uses
-- the typical figure when it is > 0 and falls back to the typed plan when it
-- is 0 — a row added today for a bill that has not posted yet, or one paid
-- outside the linked account, still needs a number.
--
-- History months use the exact matching subquery the paid figure uses, so a
-- charge is claimed by the same item in every month it is counted.
--
-- Both functions change signature (a new column; a new `period` argument), so
-- they are dropped first. The new arguments all default, so a client that
-- still sends the old named arguments resolves to the new function rather than
-- to an ambiguous pair of overloads (PGRST203).

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
  -- The viewed month plus the three full months before it, in one pass, so
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
       and t.date >= (b.start - interval '3 months')::date
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
  -- Every tracked item × each of the three prior months, zero-filled, so a
  -- month with no charge counts as $0 in the median rather than vanishing.
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
          from generate_series(1, 3) n
      ) h
     where i.user_id = auth.uid()
       and i.match_value is not null
  ),
  typical as (
    select h.item_id,
           case
             -- Only last month charged: a subscription that has just started,
             -- not a one-off from two months ago. Its one bill is the best
             -- figure there is; the median of (0, 0, x) would say $0.
             when count(*) filter (where h.cents > 0) = 1
              and max(h.cents) filter (where h.month = (b.start - interval '1 month')::date) > 0
               then max(h.cents) filter (where h.month = (b.start - interval '1 month')::date)
             else percentile_disc(0.5) within group (order by h.cents)
           end::bigint as cents,
           count(*) filter (where h.cents > 0)::int as seen
      from history h, bounds b
     group by h.item_id, b.start
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
  '`period` (default: this month, user timezone), and typical_cents — the '
  'median of the three full months before `period`, zeros included — with '
  'months_seen saying how many of those three charged. Empty groups come back '
  'as a row with a null item_id. A transaction is claimed by at most one item.';

revoke execute on function public.debt_summary(date) from public, anon;
grant execute on function public.debt_summary(date) to authenticated, service_role;

-- The charges behind a row, now anchored on a month other than this one so the
-- previous-month view opens onto that month's charges. `months` still counts
-- back inclusive from the anchor month; the matching subquery is unchanged
-- from 0028 and must stay identical to debt_summary's.
drop function if exists public.debt_item_transactions(uuid[], int);
drop function if exists public.debt_item_transactions(uuid[], int, date);

create function public.debt_item_transactions(
  items  uuid[],
  months int  default 1,
  period date default null
)
returns table (
  item_id        uuid,
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
  with tz as (
    select coalesce(max(p.timezone), 'UTC') as name
      from public.profiles p
     where p.user_id = auth.uid()
  ),
  anchor as (
    select date_trunc(
             'month',
             coalesce(period, (now() at time zone (select name from tz))::date)
           )::date as start
  ),
  span as (
    select (a.start - ((least(greatest(coalesce(months, 1), 1), 24) - 1) || ' months')::interval)::date as start,
           (a.start + interval '1 month')::date as stop
      from anchor a
  ),
  -- The outflow filter is the one every rollup uses. It must stay identical
  -- or this list and the row that opened it will disagree about a charge.
  txn as (
    select t.id, t.date, t.authorized_date, t.name, t.merchant_name,
           t.category as plaid_category, t.amount_cents, t.pending, t.is_backfill,
           a.name as account_name, a.mask as account_mask,
           public.txn_display_name(t.name, t.merchant_name, t.category) as who
      from public.transactions t
      left join public.accounts a on a.id = t.account_id,
           span s
     where t.user_id = auth.uid()
       and t.is_removed = false
       and t.amount_cents > 0
       and not (t.pending and t.is_backfill)
       and t.date >= s.start
       and t.date < s.stop
  ),
  matched as (
    select x.*,
           (
             select d.id
               from public.debt_items d
              where d.user_id = auth.uid()
                and d.match_value is not null
                and x.who ilike '%' || d.match_value || '%'
                and (d.match_amount_cents is null
                     or d.match_amount_cents = x.amount_cents)
              order by (d.match_amount_cents is not null) desc,
                       length(d.match_value) desc,
                       d.sort_order,
                       d.id
              limit 1
           ) as item_id
      from txn x
  )
  select m.item_id, m.id, m.date, m.authorized_date, m.name, m.merchant_name,
         m.plaid_category, m.amount_cents::bigint, m.pending, m.is_backfill,
         m.account_name, m.account_mask
    from matched m
   where m.item_id = any(items)
   order by m.date desc, m.amount_cents desc;
$$;

comment on function public.debt_item_transactions(uuid[], int, date) is
  'The individual charges claimed by one or more debt items over `months` '
  'months ending with the month of `period` (default: this month). Same '
  'matching precedence as debt_summary(), so the rows sum to the paid figure '
  'that opened them.';

revoke execute on function public.debt_item_transactions(uuid[], int, date) from public, anon;
grant execute on function public.debt_item_transactions(uuid[], int, date) to authenticated, service_role;

notify pgrst, 'reload schema';
