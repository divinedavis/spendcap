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
