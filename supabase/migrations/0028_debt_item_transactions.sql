-- 0028_debt_item_transactions: the charges behind a Debt row.
--
-- The Debt tab asserts "$174.22 paid · 4 charges" against an item and, until
-- now, gave no way to see the four. That is the figure most likely to be
-- wrong — a match string is a substring, so a row can quietly be claiming a
-- charge that belongs to something else, and a usage-priced service can drift
-- past its plan for a reason only the individual debits explain. A total with
-- no way to open it is a number the user has to take on faith.
--
-- The matching subquery is copied verbatim from `debt_summary` and must stay
-- identical: the same amount-qualified-then-longest-match precedence, and the
-- same at-most-one-item claim. If the two ever drift, the drill-down would
-- list charges that do not add up to the row that opened it — worse than not
-- shipping it, because the disagreement looks like a data bug.
--
-- Takes an array of items rather than one, because the screen now groups a
-- company's products together (three Google rows are one Google) and opening
-- the company has to show all of its charges in a single round trip, labelled
-- with which product claimed each.
--
-- `months` counts back from the current month inclusive: 1 is this month, the
-- period the row's paid figure describes. A longer window is what answers
-- "has this actually been charging?" for a row sitting at zero, so the sheet
-- can widen without a second RPC. Clamped to 24 so a typo cannot ask for a
-- decade of rows.

create or replace function public.debt_item_transactions(
  items  uuid[],
  months int default 1
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
  span as (
    select (date_trunc('month', (now() at time zone (select name from tz))::date)
            - ((least(greatest(coalesce(months, 1), 1), 24) - 1) || ' months')::interval)::date as start,
           (date_trunc('month', (now() at time zone (select name from tz))::date)
            + interval '1 month')::date as stop
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

comment on function public.debt_item_transactions(uuid[], int) is
  'The individual charges claimed by one or more debt items over the last '
  '`months` months (1 = this month). Same matching precedence as '
  'debt_summary(), so the rows sum to the paid figure that opened them.';

revoke execute on function public.debt_item_transactions(uuid[], int) from public, anon;
grant execute on function public.debt_item_transactions(uuid[], int) to authenticated, service_role;

notify pgrst, 'reload schema';
