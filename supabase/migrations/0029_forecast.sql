-- 0029_forecast: what the checking account will have left at the end of the
-- month, from what usually happens in one.
--
-- The question the Forecast card answers is "given what is in checking right
-- now, and what normally comes in and goes out before the month ends, where
-- will the balance land?" Three server-side pieces feed it:
--
--   txn_stable_name(text)           the descriptor with its per-transaction
--                                   churn stripped, so this month's payroll
--                                   groups with last month's
--   forecast_recurring(months_back) every name that recurred across the last
--                                   N complete months, with how often, on
--                                   which days, for how much, and what it has
--                                   already done this month
--   forecast_flows(months_back)     the month totals the everyday run-rate is
--                                   cut from, plus the balance the forecast
--                                   starts at and the pending rows against it
--
-- The server aggregates where the names and the rows are; the client decides
-- what counts as a bill and projects the calendar (ForecastMath, unit-tested).
-- Same split as monthly_spend()/YearMath and discretionary_daily()/WeekMath.
--
-- Checking accounts only, like monthly_balances(): the forecast is a balance
-- forecast, and mixing a savings account's sweeps in would predict money the
-- checking account never sees.

-- ---------------------------------------------------------------------------
-- txn_stable_name: server-side mirror of TransactionNaming.stableMatchValue.
--
-- Bank-transfer descriptors carry a date and a reference code that change on
-- every occurrence ("ACME PAYROLL DD 260515 E123456 Jane Doe",
-- "ZELLE TO CARLO CHAMAINE ON 07/30 REF # WFCT22GS4599"), so grouping on the
-- display name alone would see eight different payrolls instead of one that
-- recurs twice a month. This keeps the longest run of tokens that are not
-- volatile — dates, 5+-digit numbers, mixed letter-digit codes of 6+, $/#
-- tokens — trims a trailing connective, and falls back to the whole string
-- under 8 characters.
--
-- The Swift copy is the one the app writes category rules from; the two must
-- agree or a name the forecast shows will not be the name a rule matches.
-- TransactionNamingTests pins the Swift side; the same vectors are checked
-- against this function in the migration's verification queries.
-- ---------------------------------------------------------------------------

create or replace function public.txn_stable_name(descriptor text)
returns text
language plpgsql
immutable
as $$
declare
  tokens      text[];
  tok         text;
  run         text[] := '{}';
  best        text[] := '{}';
  candidate   text;
begin
  if descriptor is null then
    return null;
  end if;

  -- Swift's split(separator: " ") drops empty pieces; so does this.
  tokens := array_remove(regexp_split_to_array(descriptor, ' '), '');

  foreach tok in array tokens loop
    if tok ~ '^\d{1,2}/\d{1,2}(/\d{2,4})?$'                       -- 07/09, 07/30/26
       or tok ~ '^\d{5,}$'                                         -- 260805, account refs
       or (length(tok) >= 6 and tok ~ '\d' and tok ~ '[[:alpha:]]') -- S466190338974488, IB0Z59K433
       or left(tok, 1) in ('$', '#')                               -- amounts, bare ref markers
    then
      if length(array_to_string(run, ' ')) > length(array_to_string(best, ' ')) then
        best := run;
      end if;
      run := '{}';
    else
      run := run || tok;
    end if;
  end loop;
  if length(array_to_string(run, ' ')) > length(array_to_string(best, ' ')) then
    best := run;
  end if;

  -- A run often ends on the connective that introduced the volatile bit
  -- ("… ON 07/30", "… REF #…"); the connective carries no identity.
  while cardinality(best) > 0
        and upper(best[cardinality(best)]) in ('ON', 'REF', 'TO', 'FROM') loop
    best := best[1:cardinality(best) - 1];
  end loop;

  candidate := array_to_string(best, ' ');
  return case when length(candidate) >= 8 then candidate else descriptor end;
end
$$;

comment on function public.txn_stable_name(text) is
  'The recurring part of a bank descriptor: dates, long numbers, reference '
  'codes and amounts stripped, longest stable phrase kept. Mirrors '
  'TransactionNaming.stableMatchValue in the app exactly.';

grant execute on function public.txn_stable_name(text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- forecast_recurring: every stable name seen in at least two of the last N
-- complete months, with the shape of its month.
--
-- One row per (name, direction). The per-rank arrays describe a typical
-- month for that name: rank_months[r] is how many of the window months had at
-- least r occurrences, rank_day[r] the median day-of-month of the r-th
-- occurrence, rank_cents[r] the median amount of it. A twice-monthly payroll
-- comes back as rank_months = {4,4}, rank_day = {15,31}; a monthly bill as
-- {4}, {17}; a name charged fifteen times a month runs out of ranks at the
-- cap of 6 and is left for the client to treat as everyday spending.
--
-- Ranks rather than gaps because bank posting dates are calendar-shaped, not
-- interval-shaped: "the 15th and the last day" is not "every 15 days", and
-- Wells Fargo moves a weekend bill to Monday, which a gap-stepping model
-- would carry forward as drift.
--
-- Bank fees are never offered as a recurring line. Three overdraft fees a
-- month is a true statement about the history, but a forecast that budgets
-- for them presents a consequence of running dry as a fixed cost. They still
-- sit in forecast_flows' totals, so the everyday run-rate remembers them.
-- ---------------------------------------------------------------------------

create or replace function public.forecast_recurring(months_back int default 3)
returns table (
  who              text,      -- txn_stable_name(txn_display_name(...))
  is_inflow        boolean,   -- money in (amount_cents < 0) grouped apart from money out
  months_seen      int,       -- complete window months with >= 1 occurrence
  window_count     int,       -- occurrences across the window months
  window_cents     bigint,    -- their total, always positive
  rank_months      int[],     -- [r] = window months with >= r occurrences (r <= 6)
  rank_day         int[],     -- [r] = median day-of-month of the r-th occurrence
  rank_cents       bigint[],  -- [r] = median amount of the r-th occurrence, positive
  this_month_count int,       -- occurrences so far in the current month (pending included)
  this_month_cents bigint     -- their total, positive
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
           least(greatest(coalesce(months_back, 3), 1), 12) as span
  ),
  checking as (
    select a.id
      from public.accounts a
     where a.user_id = auth.uid()
       and a.type = 'depository'
       and a.subtype = 'checking'
  ),
  txn as (
    -- Direction-aware: the same filter every rollup shares minus the
    -- outflow-only clause, because a balance forecast needs the money in.
    -- Pending rows count (a pending charge will post) except the link-time
    -- pending rows whose date is the link date, as everywhere else.
    select public.txn_stable_name(
             public.txn_display_name(t.name, t.merchant_name, t.category)) as who,
           (t.amount_cents < 0)                                             as is_inflow,
           abs(t.amount_cents)::bigint                                      as cents,
           t.date,
           date_trunc('month', t.date)::date                                as period,
           extract(day from t.date)::int                                    as day
      from public.transactions t
      join checking c on c.id = t.account_id
      cross join bounds b
     where t.user_id = auth.uid()
       and t.is_removed = false
       and not (t.pending and t.is_backfill)
       and t.category is distinct from 'BANK_FEES'
       and t.date >= (b.this_month - (b.span || ' months')::interval)::date
       and t.date <  (b.this_month + interval '1 month')::date
  ),
  ranked as (
    select x.*,
           row_number() over (partition by x.who, x.is_inflow, x.period
                              order by x.date, x.cents desc) as rank
      from txn x
  ),
  window_rows as (
    select r.* from ranked r, bounds b where r.period < b.this_month
  ),
  per_rank as (
    select w.who, w.is_inflow, w.rank,
           count(*)::int                                                          as months,
           round(percentile_cont(0.5) within group (order by w.day))::int          as day,
           round(percentile_cont(0.5) within group (order by w.cents))::bigint     as cents
      from window_rows w
     where w.rank <= 6
     group by w.who, w.is_inflow, w.rank
  ),
  per_name as (
    select w.who, w.is_inflow,
           count(distinct w.period)::int as months_seen,
           count(*)::int                 as window_count,
           sum(w.cents)::bigint          as window_cents
      from window_rows w
     group by w.who, w.is_inflow
    having count(distinct w.period) >= 2
  ),
  this_month as (
    select r.who, r.is_inflow, count(*)::int as n, sum(r.cents)::bigint as cents
      from ranked r, bounds b
     where r.period = b.this_month
     group by r.who, r.is_inflow
  )
  select n.who,
         n.is_inflow,
         n.months_seen,
         n.window_count,
         n.window_cents,
         (select array_agg(p.months order by p.rank) from per_rank p
           where p.who = n.who and p.is_inflow = n.is_inflow)  as rank_months,
         (select array_agg(p.day    order by p.rank) from per_rank p
           where p.who = n.who and p.is_inflow = n.is_inflow)  as rank_day,
         (select array_agg(p.cents  order by p.rank) from per_rank p
           where p.who = n.who and p.is_inflow = n.is_inflow)  as rank_cents,
         coalesce(m.n, 0)                                       as this_month_count,
         coalesce(m.cents, 0)                                   as this_month_cents
    from per_name n
    left join this_month m on m.who = n.who and m.is_inflow = n.is_inflow
   order by n.window_cents desc, n.who;
$$;

comment on function public.forecast_recurring(int) is
  'Stable names seen in at least two of the last N complete months (default 3) '
  'on the caller''s checking accounts, with per-rank median day and amount '
  'describing a typical month, and what has posted so far this month. Bank '
  'fees excluded. The client decides which rows are bills (ForecastMath).';

revoke execute on function public.forecast_recurring(int) from public, anon;
grant execute on function public.forecast_recurring(int) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- forecast_flows: the month totals behind the everyday run-rate, and the
-- balance the forecast starts from.
--
-- One row per month from the oldest window month through the current one.
-- balance_cents is the same on every row — it is the anchor, the sum of the
-- checking accounts' current balances as sync.ts last refreshed them (posted
-- money, Plaid's `current`). pending_out/in_cents are only non-zero on the
-- current month's row: charges the bank has authorised but not posted, which
-- the balance does not yet reflect and the forecast must.
--
-- Bank fees are included here on purpose (they are excluded from
-- forecast_recurring): the run-rate is history, and the fees happened.
-- ---------------------------------------------------------------------------

create or replace function public.forecast_flows(months_back int default 3)
returns table (
  period            date,     -- first day of the month
  outflow_cents     bigint,   -- money out, posted + pending, positive
  inflow_cents      bigint,   -- money in, positive
  txn_count         int,
  pending_out_cents bigint,   -- current month only, else 0
  pending_in_cents  bigint,   -- current month only, else 0
  balance_cents     bigint    -- checking balance now; identical on every row
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
           least(greatest(coalesce(months_back, 3), 1), 12) as span
  ),
  checking as (
    select a.id, a.current_balance_cents
      from public.accounts a
     where a.user_id = auth.uid()
       and a.type = 'depository'
       and a.subtype = 'checking'
  ),
  anchor as (
    select coalesce(sum(c.current_balance_cents), 0)::bigint as cents,
           count(*) filter (where c.current_balance_cents is not null) as accounts
      from checking c
  ),
  months as (
    select generate_series(
             (b.this_month - (b.span || ' months')::interval)::date,
             b.this_month,
             interval '1 month'
           )::date as period
      from bounds b
  ),
  txn as (
    select date_trunc('month', t.date)::date as period, t.amount_cents, t.pending
      from public.transactions t
      join checking c on c.id = t.account_id
      cross join bounds b
     where t.user_id = auth.uid()
       and t.is_removed = false
       and not (t.pending and t.is_backfill)
       and t.date >= (b.this_month - (b.span || ' months')::interval)::date
       and t.date <  (b.this_month + interval '1 month')::date
  )
  select m.period,
         coalesce(sum(x.amount_cents) filter (where x.amount_cents > 0), 0)::bigint  as outflow_cents,
         coalesce(-sum(x.amount_cents) filter (where x.amount_cents < 0), 0)::bigint as inflow_cents,
         count(x.amount_cents)::int                                                  as txn_count,
         coalesce(sum(x.amount_cents) filter
                  (where x.pending and x.amount_cents > 0 and m.period = b.this_month), 0)::bigint as pending_out_cents,
         coalesce(-sum(x.amount_cents) filter
                  (where x.pending and x.amount_cents < 0 and m.period = b.this_month), 0)::bigint as pending_in_cents,
         (select a.cents from anchor a)                                              as balance_cents
    from months m
    cross join bounds b
    left join txn x on x.period = m.period
   where (select a.accounts from anchor a) > 0
   group by m.period, b.this_month
   order by m.period;
$$;

comment on function public.forecast_flows(int) is
  'Per-month checking totals for the last N complete months (default 3) plus '
  'the current month, with the pending rows of the current month and the '
  'checking balance now on every row. Empty when no checking account has a '
  'balance on record.';

revoke execute on function public.forecast_flows(int) from public, anon;
grant execute on function public.forecast_flows(int) to authenticated, service_role;

notify pgrst, 'reload schema';
