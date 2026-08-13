-- 0021_amount_qualified_rules: a rule can require an exact amount.
--
-- An Apple Cash descriptor never names the recipient — every send reads
-- "MONEY TRANSFER AUTHORIZED ON <date> APPLE CASH SENT MO …" — so no string
-- rule can tell a haircut from anything else sent by Apple Cash. The amount
-- can: every $100 send in the history (six, since May) was Divine's haircut,
-- and no other Apple Cash amount is $100. `category_rules.amount_cents`
-- (null = any amount, the existing behavior) lets a rule say both things at
-- once: match the phrase AND the exact amount.
--
-- Precedence gains a middle tier: merchant beats category, an
-- amount-qualified rule beats an unqualified one, longer match beats
-- shorter. Without that middle tier the broad one-shot strings (97 chars)
-- would outrank the qualified rule on length alone.
--
-- The unique constraint stays (user_id, match_type, match_value) — shipped
-- clients upsert against exactly those columns. Consequence: one match_value
-- can carry at most one amount qualifier. Fine until someone needs two.

alter table public.category_rules
  add column if not exists amount_cents int;

create or replace function public.category_spend(months_back int default 2)
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
   order by m.amount_cents desc;
$$;

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
           public.txn_display_name(t.name, t.merchant_name, t.category) as who
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

notify pgrst, 'reload schema';
