-- 0023_category_transactions_by_date: order a line's transactions newest first.
--
-- The edit-line sheet listed a budget line's spending biggest-first, which read
-- as arbitrary once the list was longer than a screen: an Aug 15 charge sat
-- five rows below an Aug 13 one because it was smaller, and there was no way to
-- see what had just landed without reading every date. Newest first is how the
-- same money is already listed on Activity (month_activity orders by date
-- desc), so the two screens now agree about what "top of the list" means.
--
-- Amount stays as the tie-break, which matters more here than it looks: bank
-- transactions carry a date and no time of day, so a busy day is a block of
-- rows with nothing to order them by. Biggest-first within the day keeps that
-- block stable and puts the charge worth noticing at its top.
--
-- Body is otherwise identical to 0021's — only the final ORDER BY changed. The
-- return type is untouched, so `create or replace` is safe here (a changed
-- return type would need a drop first, as 0012 did).

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
   order by m.date desc, m.amount_cents desc;
$$;

notify pgrst, 'reload schema';
