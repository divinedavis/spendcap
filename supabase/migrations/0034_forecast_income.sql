-- 0034_forecast_income: the Forecast card's money in is last month's pay.
--
-- Until now the card projected money in from forecast_recurring's inflow rows:
-- anything that arrived most months on about the same day. On the real account
-- that swept in savings sweeps and round-up credits alongside payroll, and the
-- row read "Regular money in" for a figure that was mostly a paycheck. The ask
-- (2026-10-12) was a row called Income, priced from what the employer actually
-- paid last month — the paycheck amounts move with tax and benefit changes, so
-- last month is a better guess at this month than a three-month median.
--
-- A paycheck is a checking-account deposit Plaid files as INCOME whose
-- descriptor says payroll or direct deposit. Both halves matter: INCOME alone
-- includes tax refunds and interest ("NY STATE NYSTTAXRFD" is INCOME), and the
-- descriptor alone would match a transfer someone labelled "payroll". No
-- employer is named here — the repo is public and the rule is general.
--
-- One row per paycheck in the last complete month and the month in progress.
-- The client (ForecastMath) expects last month's paychecks again, in order,
-- minus the ones this month has already received.

create or replace function public.forecast_income()
returns table (
  period date,     -- first day of the month the paycheck landed in
  date   date,
  who    text,     -- txn_stable_name(name), so both months group alike
  cents  bigint    -- positive
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
    select date_trunc('month', (now() at time zone (select name from tz))::date)::date as this_month
  )
  select date_trunc('month', t.date)::date,
         t.date,
         public.txn_stable_name(t.name),
         (-t.amount_cents)::bigint
    from public.transactions t
    join public.accounts a on a.id = t.account_id
    cross join bounds b
   where t.user_id = auth.uid()
     and a.type = 'depository'
     and a.subtype = 'checking'
     and t.is_removed = false
     and not (t.pending and t.is_backfill)
     and t.amount_cents < 0
     and t.category = 'INCOME'
     and t.name ~* '(payroll|dir(ect)?[ .]?dep)'
     and t.date >= (b.this_month - interval '1 month')::date
     and t.date <  (b.this_month + interval '1 month')::date
   order by t.date, t.amount_cents;
$$;

comment on function public.forecast_income() is
  'Paychecks (INCOME deposits whose descriptor says payroll or direct deposit) '
  'on the caller''s checking accounts in the last complete month and the '
  'current one. The Forecast card expects last month''s again.';

revoke execute on function public.forecast_income() from public, anon;
grant execute on function public.forecast_income() to authenticated, service_role;

notify pgrst, 'reload schema';
