-- 0027_debt_items_from_budget: a borrowing charge filed into a debt budget
-- line becomes a Debt item on its own.
--
-- The Debt tab and the budget's debt-kind lines describe the same money from
-- two directions, and keeping them in step by hand means typing every new
-- lender twice. This closes that: a transaction that resolves to a budget line
-- tagged `debt` and that nothing on the Debt tab already claims gets an item in
-- a "From budget" group, with a $0 plan for the user to fill in.
--
-- **Why `loans_only` defaults to true.** A debt-kind budget line is not
-- necessarily full of debts. On the account this was built against, the
-- "Debts" line carried 27 merchant rules — a dry cleaner, a plant shop, and a
-- dozen developer SaaS subscriptions among them — because it had become the
-- home for recurring bills generally. Syncing everything filed there would
-- have added ~20 subscription rows to the Debt tab and inflated the paid
-- figure on its total card. Requiring Plaid's LOAN_PAYMENTS category as well
-- narrows it to actual borrowing: BNPL, personal loans, cash-advance apps,
-- card payments. Pass false to take everything on a debt line.
--
-- Four more things this has to get right, each a bug if it does not:
--
-- * **A deleted item must stay deleted.** `debt_auto_skips` records every
--   match value that must never be auto-added again. The app writes to it when
--   the user deletes an item, and this function writes to it when it creates
--   one. Without it, deleting a row the bank still charges is an argument the
--   user cannot win — it returns on the next load, forever.
-- * **Only merchants with a real name.** A transaction whose `merchant_name`
--   is empty falls back to the bank's raw descriptor, which carries a date and
--   a reference code ("PAYPAL INST XFER 260805 …") and would mint a fresh junk
--   item every month. Skipped; the user can add those by hand with a stable
--   match string.
-- * **Bank fees are not obligations.** An overdraft fee resolves to a debt
--   line through a BANK_FEES rule and `txn_display_name()` renames it to
--   "Overdraft fee", which would become a recurring item for something neither
--   recurring nor owed.
-- * **Bounded.** At most `max_new` per call, so a broad rule cannot turn one
--   sync into a hundred rows.
--
-- The rule-resolution block below is the fifth copy (category_spend,
-- category_transactions, month_activity, discretionary_daily, here). They move
-- together.

create table if not exists public.debt_auto_skips (
  user_id     uuid not null references auth.users(id) on delete cascade,
  match_value text not null,
  created_at  timestamptz not null default now(),
  primary key (user_id, match_value)
);

alter table public.debt_auto_skips enable row level security;

drop policy if exists "debt_auto_skips self" on public.debt_auto_skips;
create policy "debt_auto_skips self" on public.debt_auto_skips
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

revoke all on public.debt_auto_skips from anon, public;
grant select, insert, delete on public.debt_auto_skips to authenticated;
grant all on public.debt_auto_skips to service_role;

comment on table public.debt_auto_skips is
  'Match values that must never be auto-added to the Debt tab again: written '
  'when the user deletes an item, and when the sync creates one. A tombstone, '
  'not a cache — it is never cleaned up.';

create or replace function public.sync_debt_items_from_budget(
  months_back int     default 3,
  max_new     int     default 20,
  loans_only  boolean default true
)
returns int
language plpgsql
security invoker
set search_path = public
as $$
declare
  landing_group uuid;
  next_order    int;
  made          int := 0;
begin
  create temp table if not exists _debt_candidates (who text primary key) on commit drop;
  delete from _debt_candidates;

  insert into _debt_candidates (who)
  with tz as (
    select coalesce(max(p.timezone), 'UTC') as name
      from public.profiles p
     where p.user_id = auth.uid()
  ),
  bounds as (
    select (date_trunc('month', (now() at time zone (select name from tz))::date)
            - ((least(greatest(coalesce(months_back, 3), 1), 24) - 1) || ' months')::interval)::date as start
  ),
  txn as (
    select t.id,
           t.amount_cents,
           public.txn_display_name(t.name, t.merchant_name, t.category) as who,
           t.category
      from public.transactions t, bounds b
     where t.user_id = auth.uid()
       and t.is_removed = false
       and t.amount_cents > 0
       -- Same outflow filter as category_spend().
       and not (t.pending and t.is_backfill)
       and t.date >= b.start
       and coalesce(trim(t.merchant_name), '') <> ''
       and coalesce(t.category, '') <> 'BANK_FEES'
       and (not coalesce(loans_only, true) or t.category = 'LOAN_PAYMENTS')
  ),
  matched as (
    select x.who,
           (
             select r.category_id
               from public.category_rules r
              where r.user_id = auth.uid()
                and (r.amount_cents is null or r.amount_cents = x.amount_cents)
                and (
                     (r.match_type = 'merchant_contains' and x.who ilike '%' || r.match_value || '%')
                  or (r.match_type = 'plaid_category'    and x.category = r.match_value)
                )
              order by (r.match_type = 'merchant_contains') desc,
                       (r.amount_cents is not null) desc,
                       length(r.match_value) desc
              limit 1
           ) as category_id
      from txn x
  )
  select distinct m.who
    from matched m
    join public.budget_categories c
      on c.id = m.category_id
     and c.user_id = auth.uid()
     and c.kind = 'debt'
   where not exists (
           select 1 from public.debt_auto_skips s
            where s.user_id = auth.uid()
              and lower(s.match_value) = lower(m.who)
         )
     -- Nothing on the Debt tab may already claim this charge, or the same
     -- money would be counted twice.
     and not exists (
           select 1 from public.debt_items i
            where i.user_id = auth.uid()
              and i.match_value is not null
              and m.who ilike '%' || i.match_value || '%'
         )
   limit greatest(coalesce(max_new, 20), 0);

  if not exists (select 1 from _debt_candidates) then
    return 0;
  end if;

  -- Auto-added rows get their own group so they are obviously machine-made and
  -- easy to review, rename, move or delete, leaving hand-arranged groups alone.
  select id into landing_group
    from public.debt_groups
   where user_id = auth.uid() and name = 'From budget';

  if landing_group is null then
    insert into public.debt_groups (user_id, name, sort_order)
    values (auth.uid(), 'From budget',
            coalesce((select max(sort_order) + 1 from public.debt_groups
                       where user_id = auth.uid()), 0))
    returning id into landing_group;
  end if;

  select coalesce(max(sort_order) + 1, 0) into next_order
    from public.debt_items
   where user_id = auth.uid() and group_id = landing_group;

  insert into public.debt_items
    (user_id, group_id, name, note, planned_cents, match_value, sort_order)
  select auth.uid(), landing_group, c.who, 'from your budget', 0, c.who,
         next_order + (row_number() over (order by c.who))::int - 1
    from _debt_candidates c;

  get diagnostics made = row_count;

  -- Ledger them immediately: created once, never re-created, so deleting one
  -- removes it for good.
  insert into public.debt_auto_skips (user_id, match_value)
  select auth.uid(), c.who from _debt_candidates c
  on conflict do nothing;

  return made;
end
$$;

comment on function public.sync_debt_items_from_budget(int, int, boolean) is
  'Creates a Debt item for each borrowing merchant filed into a debt-kind '
  'budget line that nothing on the Debt tab claims yet. Tombstoned in '
  'debt_auto_skips so a deleted item is never recreated. Returns how many were '
  'added.';

revoke execute on function public.sync_debt_items_from_budget(int, int, boolean) from public, anon;
grant execute on function public.sync_debt_items_from_budget(int, int, boolean) to authenticated, service_role;

notify pgrst, 'reload schema';
