-- 0010_trips: trips and events — a named budget with its own line items, and
-- the real transactions that belong to it.
--
-- A trip is planned *and* actual. `trip_lines` holds what you expect to spend
-- ("Flight, $420, Mar 3"); `trip_transactions` records which real rows you
-- assigned to the trip, and optionally to a line. The screen shows both, so a
-- trip you haven't taken still totals up and one you're on shows the drift.
--
-- THE LOAD-BEARING RULE: assignment is explicit and per-transaction. A trip's
-- dates never exclude anything by themselves. Trip-assigned spending drops out
-- of the daily cap (a $780 hotel would fire an over-cap push that tells the
-- user nothing), so a date range that excluded rows automatically would
-- silently switch off the app's whole reason to exist for the length of a
-- holiday — the days you are most likely to overspend. Every excluded row is
-- one the user tapped.
--
-- Months, Trends and Activity are unaffected: they report what actually left
-- the account, and hiding trip spending there would make the app disagree with
-- the bank statement it mirrors.

-- ── trips ───────────────────────────────────────────────────────────────────
create table if not exists public.trips (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  name       text not null check (length(btrim(name)) > 0),
  kind       text not null default 'trip' check (kind in ('trip', 'event')),
  starts_on  date,
  ends_on    date,
  -- Optional. Null means "no budget set" and the planned lines are the budget;
  -- 0 would read as "budgeted nothing", which is a different statement.
  budget_cents bigint check (budget_cents is null or budget_cents >= 0),
  created_at timestamptz not null default now(),
  constraint trips_dates_ordered
    check (starts_on is null or ends_on is null or ends_on >= starts_on)
);
create index if not exists trips_user_starts on public.trips (user_id, starts_on desc);
alter table public.trips enable row level security;

drop policy if exists trips_select_self on public.trips;
create policy trips_select_self on public.trips
  for select to authenticated using (auth.uid() = user_id);
drop policy if exists trips_insert_self on public.trips;
create policy trips_insert_self on public.trips
  for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists trips_update_self on public.trips;
create policy trips_update_self on public.trips
  for update to authenticated using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
drop policy if exists trips_delete_self on public.trips;
create policy trips_delete_self on public.trips
  for delete to authenticated using (auth.uid() = user_id);

-- ── trip_lines ──────────────────────────────────────────────────────────────
-- One planned cost inside a trip: flight, hotel, food, or anything the user
-- adds. `occurs_on` is the flight's date; null for a line that has no single
-- day, like food across the whole week.
create table if not exists public.trip_lines (
  id            uuid primary key default gen_random_uuid(),
  trip_id       uuid not null references public.trips(id) on delete cascade,
  user_id       uuid not null references auth.users(id) on delete cascade,
  name          text not null check (length(btrim(name)) > 0),
  symbol        text,                       -- SF Symbol name, chosen client-side
  planned_cents bigint not null default 0 check (planned_cents >= 0),
  occurs_on     date,
  sort_order    int not null default 0,
  created_at    timestamptz not null default now()
);
create index if not exists trip_lines_trip on public.trip_lines (trip_id, sort_order, created_at);
alter table public.trip_lines enable row level security;

drop policy if exists trip_lines_select_self on public.trip_lines;
create policy trip_lines_select_self on public.trip_lines
  for select to authenticated using (auth.uid() = user_id);
drop policy if exists trip_lines_insert_self on public.trip_lines;
create policy trip_lines_insert_self on public.trip_lines
  for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists trip_lines_update_self on public.trip_lines;
create policy trip_lines_update_self on public.trip_lines
  for update to authenticated using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
drop policy if exists trip_lines_delete_self on public.trip_lines;
create policy trip_lines_delete_self on public.trip_lines
  for delete to authenticated using (auth.uid() = user_id);

-- ── trip_transactions ───────────────────────────────────────────────────────
-- transaction_id is the primary key, not a pair: a transaction belongs to at
-- most one trip. Without that a row could be excluded from the daily cap twice
-- over and counted in two trips' totals, and there is no sane answer to "which
-- trip was this hotel on".
create table if not exists public.trip_transactions (
  transaction_id uuid primary key references public.transactions(id) on delete cascade,
  trip_id        uuid not null references public.trips(id) on delete cascade,
  -- Null is a normal state: assigned to the trip, not yet filed under a line.
  line_id        uuid references public.trip_lines(id) on delete set null,
  user_id        uuid not null references auth.users(id) on delete cascade,
  created_at     timestamptz not null default now()
);
create index if not exists trip_transactions_trip on public.trip_transactions (trip_id);
create index if not exists trip_transactions_user on public.trip_transactions (user_id);
alter table public.trip_transactions enable row level security;

drop policy if exists trip_transactions_select_self on public.trip_transactions;
create policy trip_transactions_select_self on public.trip_transactions
  for select to authenticated using (auth.uid() = user_id);
drop policy if exists trip_transactions_insert_self on public.trip_transactions;
create policy trip_transactions_insert_self on public.trip_transactions
  for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists trip_transactions_update_self on public.trip_transactions;
create policy trip_transactions_update_self on public.trip_transactions
  for update to authenticated using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
drop policy if exists trip_transactions_delete_self on public.trip_transactions;
create policy trip_transactions_delete_self on public.trip_transactions
  for delete to authenticated using (auth.uid() = user_id);

-- Grants. RLS default-denies, so an anon select grant is harmless and matches
-- the 0001 tables; the write grants are what `authenticated` actually needs.
grant select on public.trips, public.trip_lines, public.trip_transactions to anon;
grant select, insert, update, delete
  on public.trips, public.trip_lines, public.trip_transactions to authenticated;
grant all on public.trips, public.trip_lines, public.trip_transactions to service_role;

-- ── trip_totals ─────────────────────────────────────────────────────────────
-- One row per trip for the list screen: planned, actually spent, how many rows
-- back that up. Aggregated here so the list is a single request no matter how
-- many transactions a trip collects.
--
-- The outflow filter mirrors overspend_status() / monthly_spend() /
-- BankTransaction.countsTowardDailyCap. A trip total built on a different
-- definition of "spent" than the rest of the app would be indefensible.
create or replace function public.trip_totals()
returns table (
  trip_id       uuid,
  name          text,
  kind          text,
  starts_on     date,
  ends_on       date,
  budget_cents  bigint,
  planned_cents bigint,
  spent_cents   bigint,
  txn_count     int,
  line_count    int
)
language sql
stable
security invoker
set search_path = public
as $$
  select t.id,
         t.name,
         t.kind,
         t.starts_on,
         t.ends_on,
         t.budget_cents,
         coalesce(l.planned_cents, 0) as planned_cents,
         coalesce(s.spent_cents, 0)   as spent_cents,
         coalesce(s.txn_count, 0)     as txn_count,
         coalesce(l.line_count, 0)    as line_count
    from public.trips t
    left join lateral (
      select sum(tl.planned_cents)::bigint as planned_cents,
             count(*)::int                 as line_count
        from public.trip_lines tl
       where tl.trip_id = t.id
    ) l on true
    left join lateral (
      select sum(tx.amount_cents)::bigint as spent_cents,
             count(*)::int                as txn_count
        from public.trip_transactions tt
        join public.transactions tx on tx.id = tt.transaction_id
       where tt.trip_id = t.id
         and tx.is_removed = false
         and tx.amount_cents > 0
         and not (tx.pending and tx.is_backfill)
    ) s on true
   where t.user_id = auth.uid()
   order by coalesce(t.starts_on, t.created_at::date) desc, t.created_at desc;
$$;
revoke execute on function public.trip_totals() from public, anon;
grant execute on function public.trip_totals() to authenticated, service_role;

-- ── trip_line_spend ─────────────────────────────────────────────────────────
-- The inside of one trip: every line with what was planned and what has landed
-- against it. Rows assigned to the trip but not to a line come back as a
-- single null-id row, so the screen can show "unfiled" without a second query
-- and the line totals plus that row always reconcile to trip_totals.
create or replace function public.trip_line_spend(trip uuid)
returns table (
  line_id       uuid,
  name          text,
  symbol        text,
  planned_cents bigint,
  occurs_on     date,
  sort_order    int,
  spent_cents   bigint,
  txn_count     int
)
language sql
stable
security invoker
set search_path = public
as $$
  with owned as (
    select id from public.trips where id = trip and user_id = auth.uid()
  ),
  spend as (
    select tt.line_id,
           sum(tx.amount_cents)::bigint as spent_cents,
           count(*)::int                as txn_count
      from public.trip_transactions tt
      join public.transactions tx on tx.id = tt.transaction_id
     where tt.trip_id = (select id from owned)
       and tx.is_removed = false
       and tx.amount_cents > 0
       and not (tx.pending and tx.is_backfill)
     group by tt.line_id
  )
  select tl.id,
         tl.name,
         tl.symbol,
         tl.planned_cents,
         tl.occurs_on,
         tl.sort_order,
         coalesce(s.spent_cents, 0) as spent_cents,
         coalesce(s.txn_count, 0)   as txn_count
    from public.trip_lines tl
    left join spend s on s.line_id = tl.id
   where tl.trip_id = (select id from owned)
  union all
  -- Assigned to the trip, filed under no line.
  select null::uuid,
         null::text,
         null::text,
         0::bigint,
         null::date,
         2147483647,       -- sorts last
         s.spent_cents,
         s.txn_count
    from spend s
   where s.line_id is null
   order by sort_order, name nulls last;
$$;
revoke execute on function public.trip_line_spend(uuid) from public, anon;
grant execute on function public.trip_line_spend(uuid) to authenticated, service_role;

-- ── trip_candidates ─────────────────────────────────────────────────────────
-- What the user is offered when filing a trip: transactions inside the trip's
-- dates that are not already assigned to some trip. This *suggests*; nothing
-- here assigns anything.
--
-- A trip with no dates returns nothing rather than the user's entire history —
-- offering every transaction they have ever made is not a useful review queue.
create or replace function public.trip_candidates(trip uuid, max_rows int default 200)
returns table (
  transaction_id uuid,
  date           date,
  name           text,
  merchant_name  text,
  amount_cents   bigint,
  pending        boolean
)
language sql
stable
security invoker
set search_path = public
as $$
  with owned as (
    select id, starts_on, ends_on
      from public.trips
     where id = trip and user_id = auth.uid()
       and starts_on is not null and ends_on is not null
  )
  select tx.id,
         tx.date,
         tx.name,
         tx.merchant_name,
         tx.amount_cents,
         tx.pending
    from public.transactions tx
    join owned o on tx.date between o.starts_on and o.ends_on
   where tx.user_id = auth.uid()
     and tx.is_removed = false
     and tx.amount_cents > 0
     and not (tx.pending and tx.is_backfill)
     and not exists (
       select 1 from public.trip_transactions tt where tt.transaction_id = tx.id
     )
   order by tx.date desc, tx.amount_cents desc
   limit least(greatest(coalesce(max_rows, 200), 1), 500);
$$;
revoke execute on function public.trip_candidates(uuid, int) from public, anon;
grant execute on function public.trip_candidates(uuid, int) to authenticated, service_role;

-- ── trip_assigned ───────────────────────────────────────────────────────────
-- The transactions already on a trip, for the detail screen and for unfiling.
create or replace function public.trip_assigned(trip uuid)
returns table (
  transaction_id uuid,
  line_id        uuid,
  date           date,
  name           text,
  merchant_name  text,
  amount_cents   bigint,
  pending        boolean
)
language sql
stable
security invoker
set search_path = public
as $$
  select tx.id,
         tt.line_id,
         tx.date,
         tx.name,
         tx.merchant_name,
         tx.amount_cents,
         tx.pending
    from public.trip_transactions tt
    join public.transactions tx on tx.id = tt.transaction_id
    join public.trips t on t.id = tt.trip_id
   where tt.trip_id = trip
     and t.user_id = auth.uid()
     and tx.is_removed = false
   order by tx.date desc;
$$;
revoke execute on function public.trip_assigned(uuid) from public, anon;
grant execute on function public.trip_assigned(uuid) to authenticated, service_role;

-- ── overspend_status: trip spending leaves the daily cap ────────────────────
-- Identical to 0004 but for the trip_transactions exclusion. A hotel or a
-- flight is not a failure of today's discretionary budget, and an over-cap
-- push on the day of a booking is noise the user cannot act on — which is how
-- an alert stops being read at all.
--
-- Only explicitly assigned rows drop out. See the header of this file.
create or replace function public.overspend_status()
returns table (
  user_id     uuid,
  local_date  date,
  spent_cents bigint,
  limit_cents bigint,
  warn_pct    int
)
language sql
security definer set search_path = public
as $$
  select p.user_id,
         (now() at time zone p.timezone)::date as local_date,
         coalesce(sum(t.amount_cents), 0)      as spent_cents,
         b.daily_limit_cents                   as limit_cents,
         b.warn_pct
  from public.profiles p
  join public.budgets b on b.user_id = p.user_id
  left join public.transactions t
    on t.user_id = p.user_id
   and t.is_removed = false
   and t.amount_cents > 0
   and t.date = (now() at time zone p.timezone)::date
   -- A pending row inherited at link time has the link date, not a purchase
   -- date. Skip it; it counts on its real day once it posts.
   and not (t.pending and t.is_backfill)
   -- Assigned to a trip: budgeted there, not against today's cap.
   and not exists (
     select 1 from public.trip_transactions tt where tt.transaction_id = t.id
   )
  group by p.user_id, p.timezone, b.daily_limit_cents, b.warn_pct;
$$;
revoke execute on function public.overspend_status() from public, anon, authenticated;

notify pgrst, 'reload schema';
