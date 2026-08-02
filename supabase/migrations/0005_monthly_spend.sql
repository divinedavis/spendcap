-- 0005_monthly_spend: per-month spend totals for the Months tab.
--
-- The client needs 12 monthly totals, not 12 months of rows. Pulling the raw
-- transactions would mean thousands of rows over PostgREST's 1000-row default
-- cap and a client-side sum, so the aggregation happens here.
--
-- security invoker on purpose: transactions is RLS'd self-only, so the function
-- can only ever see the caller's rows. The redundant user_id = auth.uid()
-- predicate is there for the index, not for safety.
--
-- The outflow filter must mirror overspend_status() (0004) and the client's
-- BankTransaction.countsTowardDailyCap exactly — a month total that disagrees
-- with the day totals the pushes are built from would be worse than no total.

create or replace function public.monthly_spend(months_back int default 12)
returns table (
  period      date,     -- first day of the month, in the user's timezone
  spent_cents bigint,
  txn_count   int
)
language sql
stable
security invoker
set search_path = public
as $$
  with tz as (
    -- No profile row yet (first launch, before syncTimezone lands) falls back
    -- to UTC rather than returning nothing.
    select coalesce(max(p.timezone), 'UTC') as name
      from public.profiles p
     where p.user_id = auth.uid()
  ),
  bounds as (
    select date_trunc('month', (now() at time zone (select name from tz))::date)::date as this_month,
           least(greatest(coalesce(months_back, 12), 1), 36) as span
  ),
  months as (
    select generate_series(
             b.this_month - ((b.span - 1) || ' months')::interval,
             b.this_month,
             interval '1 month'
           )::date as period
      from bounds b
  )
  select m.period,
         coalesce(sum(t.amount_cents), 0)::bigint as spent_cents,
         count(t.id)::int                         as txn_count
    from months m
    left join public.transactions t
      on t.user_id = auth.uid()
     and t.is_removed = false
     and t.amount_cents > 0
     -- Pending rows inherited at link time carry the link date, not a purchase
     -- date (see 0004). They count on their real day once they post.
     and not (t.pending and t.is_backfill)
     and t.date >= m.period
     and t.date < (m.period + interval '1 month')::date
   group by m.period
   order by m.period;
$$;

comment on function public.monthly_spend(int) is
  'Outflow totals for the last N calendar months (default 12) in the caller''s '
  'timezone, one row per month including months with no activity. Mirrors the '
  'overspend_status() filter so month totals agree with day totals.';

revoke execute on function public.monthly_spend(int) from public, anon;
grant execute on function public.monthly_spend(int) to authenticated, service_role;

notify pgrst, 'reload schema';
