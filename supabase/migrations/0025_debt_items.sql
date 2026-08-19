-- 0025_debt_items: the Debt tab — recurring obligations, itemised and grouped.
--
-- The budget already has a single "Debts" line, which answers "am I over on
-- debt this month" and nothing else. The question actually being asked is
-- "what am I paying, to whom, and how much does each bucket add up to" — the
-- spreadsheet Divine keeps by hand: a service per row, a note saying which
-- product it is, and a subtotal per group.
--
-- Two tables rather than a `group` text column on one, because the group is a
-- thing the user names, orders and keeps around even when it is empty; a text
-- column would delete the group the moment its last item went.
--
-- Design notes worth keeping:
--
-- * **No unique constraint on the item name.** "Google" is three separate
--   rows (YouTube TV, YouTube Premium, Workspace) at three different prices.
--   Uniqueness here would have made the real data unrepresentable. The `note`
--   is what tells them apart, and it is not required — an item with no note
--   is fine.
-- * **Matching is per item and independent of `category_rules`.** Debt items
--   describe obligations; category rules route money into budget lines. They
--   overlap but are not the same mapping — a BNPL charge belongs to the
--   Debts budget line AND to that lender's item, and forcing one table to do
--   both would mean one of the two screens lying.
-- * **Precedence copies 0021: amount-qualified beats unqualified, then the
--   longer match wins.** Without the amount tier the three Google rows would
--   be indistinguishable — every Google charge would pile onto whichever row
--   sorted first. With it, `GOOGLE` plus the exact price picks out one.
-- * A transaction is claimed by **at most one** item, so subtotals can be
--   added without double-counting.
-- * `match_value` is nullable and expected to be null for a while. Fidelity's
--   401k loan and a payroll-deducted repayment may never post through the
--   linked checking account at all; those items are planned-only, and the screen has
--   to say "not seen" rather than invent a $0 that reads as "not paid".
--
-- The outflow filter (`amount_cents > 0`, not removed, not a pending backfill)
-- is the same one `overspend_status()`, `monthly_spend()` and
-- `category_spend()` use. It must stay identical or the Debt tab and the
-- budget will disagree about the same charge.

create table if not exists public.debt_groups (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  name       text not null check (length(trim(name)) between 1 and 60),
  sort_order int  not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, name)
);

create index if not exists debt_groups_user_idx
  on public.debt_groups (user_id, sort_order);

create table if not exists public.debt_items (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  group_id      uuid not null references public.debt_groups(id) on delete cascade,
  name          text not null check (length(trim(name)) between 1 and 60),
  -- What the money buys ("youtube tv"). Optional, and the only thing telling
  -- three Google rows apart.
  note          text check (note is null or length(trim(note)) <= 80),
  planned_cents int  not null default 0 check (planned_cents >= 0),
  -- Case-insensitive substring of the transaction's display name. Null means
  -- "this obligation is not visible in the linked account" — planned only.
  match_value   text check (match_value is null or length(trim(match_value)) > 0),
  -- Optional exact-amount qualifier, same idea as category_rules.amount_cents.
  match_amount_cents int check (match_amount_cents is null or match_amount_cents > 0),
  sort_order    int  not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists debt_items_user_idx
  on public.debt_items (user_id, group_id, sort_order);

alter table public.debt_groups enable row level security;
alter table public.debt_items  enable row level security;

drop policy if exists "debt_groups self" on public.debt_groups;
create policy "debt_groups self" on public.debt_groups
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "debt_items self" on public.debt_items;
create policy "debt_items self" on public.debt_items
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Every new table needs its grants spelled out: anon gets write grants by
-- default on this project, and RLS alone is not where that should be caught.
revoke all on public.debt_groups from anon, public;
revoke all on public.debt_items  from anon, public;
grant select, insert, update, delete on public.debt_groups to authenticated;
grant select, insert, update, delete on public.debt_items  to authenticated;
grant all on public.debt_groups to service_role;
grant all on public.debt_items  to service_role;

-- One row per debt item, plus one item-less row per empty group so a group the
-- user made but has not filled still appears. `period` defaults to the current
-- month in the user's own timezone.
create or replace function public.debt_summary(period date default null)
returns table (
  group_id    uuid,
  group_name  text,
  group_sort  int,
  item_id     uuid,
  item_name   text,
  note        text,
  planned_cents int,
  paid_cents  bigint,
  txn_count   int,
  match_value text,
  match_amount_cents int,
  item_sort   int
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
    select date_trunc(
             'month',
             coalesce(period, (now() at time zone (select name from tz))::date)
           )::date as start
  ),
  txn as (
    select t.id,
           t.amount_cents,
           public.txn_display_name(t.name, t.merchant_name, t.category) as who
      from public.transactions t, bounds b
     where t.user_id = auth.uid()
       and t.is_removed = false
       and t.amount_cents > 0
       and not (t.pending and t.is_backfill)
       and t.date >= b.start
       and t.date < (b.start + interval '1 month')::date
  ),
  matched as (
    select x.id,
           x.amount_cents,
           (
             select d.id
               from public.debt_items d
              where d.user_id = auth.uid()
                and d.match_value is not null
                and x.who ilike '%' || d.match_value || '%'
                and (d.match_amount_cents is null
                     or d.match_amount_cents = x.amount_cents)
              -- Amount-qualified beats unqualified, then the longer string.
              -- The id tiebreak only exists so the choice is stable across
              -- reads; without it two equal-length rules could swap and the
              -- subtotals would flicker.
              order by (d.match_amount_cents is not null) desc,
                       length(d.match_value) desc,
                       d.sort_order,
                       d.id
              limit 1
           ) as item_id
      from txn x
  )
  select g.id,
         g.name,
         g.sort_order,
         i.id,
         i.name,
         i.note,
         i.planned_cents,
         coalesce(sum(m.amount_cents), 0)::bigint,
         count(m.id)::int,
         i.match_value,
         i.match_amount_cents,
         i.sort_order
    from public.debt_groups g
    left join public.debt_items i
      on i.group_id = g.id
     and i.user_id = g.user_id
    left join matched m
      on m.item_id = i.id
   where g.user_id = auth.uid()
   group by g.id, g.name, g.sort_order,
            i.id, i.name, i.note, i.planned_cents,
            i.match_value, i.match_amount_cents, i.sort_order
   order by g.sort_order, g.name, i.sort_order, i.name
$$;

comment on function public.debt_summary(date) is
  'Debt tab: every obligation with its planned monthly amount and what actually '
  'posted against it in `period` (default: this month, user timezone). Empty '
  'groups come back as a row with a null item_id. A transaction is claimed by '
  'at most one item.';

revoke execute on function public.debt_summary(date) from public, anon;
grant execute on function public.debt_summary(date) to authenticated, service_role;

-- The four buckets, no amounts — the app offers this once, when the screen is
-- empty. Deliberately server-side and idempotent so a double tap cannot
-- duplicate them, matching seed_starter_budget().
create or replace function public.seed_starter_debt()
returns int
language plpgsql
security invoker
set search_path = public
as $$
declare
  made int := 0;
begin
  if exists (select 1 from public.debt_groups where user_id = auth.uid()) then
    return 0;
  end if;

  insert into public.debt_groups (user_id, name, sort_order)
  values (auth.uid(), 'Subscriptions',  0),
         (auth.uid(), 'Personal loans', 1),
         (auth.uid(), 'BNPL',           2),
         (auth.uid(), 'Other',          3);

  get diagnostics made = row_count;
  return made;
end
$$;

revoke execute on function public.seed_starter_debt() from public, anon;
grant execute on function public.seed_starter_debt() to authenticated, service_role;

notify pgrst, 'reload schema';
