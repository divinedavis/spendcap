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
