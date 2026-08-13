-- 0018_overdraft_fee_names: a bank fee never wears a merchant's name.
--
-- Wells Fargo names an overdraft fee after the purchase that overdrew the
-- account ("OVERDRAFT FEE FOR A TRANSACTION POSTED ON 07/27 $50.50
-- AFFIRM.COM ..."), and Plaid extracts that merchant into merchant_name — so
-- a $35 fee masquerades as an Affirm charge. Twice Plaid went further and
-- rewrote the *name* to just "Lyft", leaving BANK_FEES as the only signal.
-- The rollups' display/matching string (`who`) took merchant_name first, so
-- fees displayed as the merchant AND merchant rules claimed them: two Lyft
-- fees were filed under Transport, an Apple one under Debts via the "Apple"
-- rule.
--
-- Fix: BANK_FEES rows resolve to 'Overdraft fee' (when the bank's own text
-- says so) or 'Bank fee' (when Plaid erased it — never guess "overdraft"
-- from the category alone, a monthly service fee is BANK_FEES too). One
-- helper, used by every rollup, mirrored exactly by TransactionNaming in
-- Swift — the string the screen shows is the string rules match, so
-- reassigning an "Overdraft fee" row writes a rule that actually fires.
--
-- Consequence for matching precedence: fee rows can no longer be claimed by
-- the overdrawing merchant's rules; they fall through to any plaid_category
-- BANK_FEES rule (currently → Debts) or to Uncategorized.

create or replace function public.txn_display_name(
  name          text,
  merchant_name text,
  category      text
)
returns text
language sql
immutable
as $$
  select case
    when category = 'BANK_FEES' then
      case when name ilike '%overdraft fee%' then 'Overdraft fee'
           else 'Bank fee' end
    else coalesce(nullif(trim(merchant_name), ''), name)
  end
$$;

comment on function public.txn_display_name(text, text, text) is
  'How a transaction introduces itself everywhere: merchant name, falling '
  'back to the bank''s text — except BANK_FEES rows, which never take the '
  'overdrawing merchant''s name. Mirrored by TransactionNaming in the app.';

revoke execute on function public.txn_display_name(text, text, text) from public, anon;
grant execute on function public.txn_display_name(text, text, text) to authenticated, service_role;

-- The three rollups swap their inline `who` for the helper. Return types are
-- unchanged, so create-or-replace is safe and grants survive.

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

notify pgrst, 'reload schema';
