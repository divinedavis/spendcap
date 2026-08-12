-- 0015_monthly_balances: start/end checking balance per month for the Months tab.
--
-- The bank reports one balance — now. Every month boundary is derived from it
-- by walking the posted transactions backwards: the balance at the end of a
-- month is today's balance plus every outflow (minus every inflow) dated after
-- it. That derivation only involves transactions AFTER the boundary, so missing
-- history older than a boundary cannot corrupt it — which is why months before
-- the first transaction on record are omitted entirely rather than shown with
-- an invented balance.
--
-- Checking accounts only (type depository/checking): a savings balance mixed in
-- would make "what my checking did this month" unanswerable, and cards don't
-- have a balance in this sense at all.
--
-- Posted transactions only (pending = false). A statement's start/end balances
-- are posted figures, and Plaid's `current` balance tracks posted activity;
-- mixing pending rows in would double-count them the day they post.
--
-- Depends on sync.ts refreshing accounts.current_balance_cents on every sync
-- (shipped alongside this migration). A link-time balance plus post-link
-- transactions would disagree by every dollar spent since linking.
--
-- security invoker on purpose, like monthly_spend(): accounts and transactions
-- are RLS'd self-only, so the function only ever sees the caller's rows.

create or replace function public.monthly_balances(months_back int default 12)
returns table (
  period      date,     -- first day of the month, in the user's timezone
  start_cents bigint,   -- balance going into the month
  end_cents   bigint    -- balance leaving it (current month: balance now)
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
  checking as (
    select a.id, a.current_balance_cents
      from public.accounts a
     where a.user_id = auth.uid()
       and a.type = 'depository'
       and a.subtype = 'checking'
       and a.current_balance_cents is not null
  ),
  anchor as (
    select sum(c.current_balance_cents)::bigint as cents,
           count(*)                             as accounts
      from checking c
  ),
  txns as (
    -- Net movement, not the outflow filter the spend rollups share: a balance
    -- moves on money in as much as money out. amount_cents > 0 is money out
    -- (Plaid convention), so later transactions are ADDED back when deriving
    -- an earlier balance.
    select t.date, t.amount_cents
      from public.transactions t
      join checking c on c.id = t.account_id
     where t.user_id = auth.uid()
       and t.is_removed = false
       and t.pending = false
  ),
  bounds as (
    select date_trunc('month', (now() at time zone (select name from tz))::date)::date as this_month,
           least(greatest(coalesce(months_back, 12), 1), 36) as span
  ),
  first_month as (
    select date_trunc('month', min(x.date))::date as m from txns x
  ),
  months as (
    select generate_series(
             greatest((b.this_month - ((b.span - 1) || ' months')::interval)::date, f.m),
             b.this_month,
             interval '1 month'
           )::date as period
      from bounds b, first_month f
     where f.m is not null
  )
  select m.period,
         (select a.cents from anchor a)
           + coalesce((select sum(x.amount_cents) from txns x
                        where x.date >= m.period), 0)                          as start_cents,
         (select a.cents from anchor a)
           + coalesce((select sum(x.amount_cents) from txns x
                        where x.date >= (m.period + interval '1 month')::date), 0) as end_cents
    from months m
   where (select a.accounts from anchor a) > 0
   order by m.period;
$$;

comment on function public.monthly_balances(int) is
  'Checking-account balance at the start and end of each of the last N calendar '
  'months (default 12) in the caller''s timezone, derived from the current '
  'balance and posted transactions. Months before the first transaction on '
  'record are omitted — their balances would be invented, not derived.';

revoke execute on function public.monthly_balances(int) from public, anon;
grant execute on function public.monthly_balances(int) to authenticated, service_role;

notify pgrst, 'reload schema';
