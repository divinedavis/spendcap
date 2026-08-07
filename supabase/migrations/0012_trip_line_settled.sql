-- 0012_trip_line_settled: tick a trip's cost line off as paid or done.
--
-- A trip line is half budget, half checklist: "Flights, $800, Sep 2" is
-- something you plan *and* something you eventually book. Plenty of it gets
-- paid on a card the app can't see, months ahead, or by someone else — so
-- "handled" cannot be inferred from the transactions we mirror. It has to be
-- something the user asserts.
--
-- A timestamp rather than a boolean: "when did I pay this" is free, and it
-- reads unambiguously (null = outstanding). Nothing derives money from it.
--
-- Deliberately NOT wired into any total. Ticking a line does not add to the
-- trip's spend: that number means "money we watched leave the account", and
-- letting a checkbox inflate it would make the one honest figure on the screen
-- a mix of fact and intention. The count of ticked lines is shown separately.

alter table public.trip_lines
  add column if not exists settled_at timestamptz;

comment on column public.trip_lines.settled_at is
  'When the user ticked this line off as paid/done. Null = outstanding. '
  'Never feeds a spend total — see 0012.';

-- trip_line_spend gains settled_at. Otherwise identical to 0010: the outflow
-- filter still mirrors overspend_status(), and the unfiled row is still the
-- synthetic null-id row that makes the lines reconcile to trip_totals.
--
-- Dropped first, not `create or replace`: adding an OUT column changes the
-- function's return type, which Postgres refuses to replace in place
-- (42P13). The drop and create run in one statement batch, so PostgREST never
-- sees a window without it.
drop function if exists public.trip_line_spend(uuid);
create or replace function public.trip_line_spend(trip uuid)
returns table (
  line_id       uuid,
  name          text,
  symbol        text,
  planned_cents bigint,
  occurs_on     date,
  sort_order    int,
  spent_cents   bigint,
  txn_count     int,
  settled_at    timestamptz
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
         coalesce(s.txn_count, 0)   as txn_count,
         tl.settled_at
    from public.trip_lines tl
    left join spend s on s.line_id = tl.id
   where tl.trip_id = (select id from owned)
  union all
  -- Assigned to the trip, filed under no line. Never settleable: it is a
  -- rollup, not something anyone created.
  select null::uuid,
         null::text,
         null::text,
         0::bigint,
         null::date,
         2147483647,       -- sorts last
         s.spent_cents,
         s.txn_count,
         null::timestamptz
    from spend s
   where s.line_id is null
   order by sort_order, name nulls last;
$$;
revoke execute on function public.trip_line_spend(uuid) from public, anon;
grant execute on function public.trip_line_spend(uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
