-- 0004_pending_backfill: stop a bank's pending backlog counting as today.
--
-- Wells Fargo (and it is not alone) reports unposted transactions with no
-- authorized_date, so Plaid stamps them with the date they were *seen*. On the
-- very first sync of a new item that is the link date — which collapses days
-- or weeks of unposted purchases onto a single day. Observed live: linking on
-- 2026-08-01 produced 19 pending rows all dated 2026-08-01 totalling $428.38
-- against a $50 cap, and fired an "over" push 3 seconds after linking.
--
-- The date on such a row is not wrong so much as unknowable, and it corrects
-- itself: once the charge posts, Plaid supplies the real date and pending goes
-- false. So the fix is to not count a pending row we inherited at link time,
-- and let it start counting on its true day when it posts.

alter table public.transactions
  add column if not exists is_backfill boolean not null default false;

comment on column public.transactions.is_backfill is
  'True for rows first seen during an item''s initial sync. Combined with '
  'pending = true it marks a charge whose date is the link date rather than a '
  'real purchase date, so day totals must skip it until it posts.';

-- Day-total queries filter on (date, is_removed, pending, is_backfill).
create index if not exists transactions_day_totals_idx
  on public.transactions (user_id, date)
  where is_removed = false and amount_cents > 0;

-- ── existing data ───────────────────────────────────────────────────────────
-- Every row currently on file arrived in one initial sync, so every row still
-- pending is by definition inherited backlog. Posted rows carry real dates and
-- are left alone.
update public.transactions
   set is_backfill = true
 where pending = true
   and is_removed = false;

-- ── overspend_status: exclude inherited pending rows ────────────────────────
create or replace function public.overspend_status()
returns table (
  user_id uuid,
  local_date date,
  spent_cents bigint,
  limit_cents bigint,
  warn_pct int
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
  group by p.user_id, p.timezone, b.daily_limit_cents, b.warn_pct;
$$;
revoke execute on function public.overspend_status() from public, anon, authenticated;

notify pgrst, 'reload schema';
