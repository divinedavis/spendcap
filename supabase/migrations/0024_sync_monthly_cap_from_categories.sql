-- 0024_sync_monthly_cap_from_categories: a line's planned amount moves the cap.
--
-- Trends' category card and Months' cap were two unrelated numbers. Divine's
-- lines planned $7,000 between them while `budgets.monthly_limit_cents` still
-- said $6,500 — set once, never revisited, and drifting further every time a
-- line was edited. Two screens describing the same month with different
-- budgets is the failure this repo keeps trying to avoid.
--
-- The rule Divine chose: **keep both, sync on edit.** The monthly cap stays a
-- real, editable setting — typing one in still holds — but any change to what
-- the lines plan overwrites it with the new total. So the cap follows the
-- budget by default and can still be overridden until the next line edit.
--
-- A trigger rather than a client call, because the planned amount is editable
-- from three places (the Trends widget, the full Budget screen, and
-- seed_starter_budget) and a rule enforced in one of them is a rule that
-- drifts. It fires on the planned amount specifically — renaming a line or
-- tagging its kind leaves the cap alone.
--
-- `nullif(..., 0)` matters: a null cap is "no monthly cap", which falls back to
-- daily x days in the month, while a zero cap would read as a $0 budget that
-- every month is instantly over. Deleting the last line therefore restores the
-- fallback rather than pinning the month to zero.
--
-- Nothing server-side reads monthly_limit_cents — check_overspend uses the
-- *daily* limit and is the only thing that pushes — so this changes what the
-- app displays and nothing about alerting.

create or replace function public.sync_monthly_cap_from_categories()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  uid   uuid := coalesce(new.user_id, old.user_id);
  total int;
begin
  select nullif(sum(planned_cents), 0)
    into total
    from public.budget_categories
   where user_id = uid;

  update public.budgets
     set monthly_limit_cents = total
   where user_id = uid
     and monthly_limit_cents is distinct from total;

  return null;   -- after trigger; the return value is discarded
end;
$$;

drop trigger if exists budget_categories_sync_cap on public.budget_categories;

create trigger budget_categories_sync_cap
after insert or delete or update of planned_cents
on public.budget_categories
for each row
execute function public.sync_monthly_cap_from_categories();

-- Bring every existing budget into line, so the rule starts from agreement
-- rather than waiting for the next edit to notice the drift.
update public.budgets b
   set monthly_limit_cents = c.total
  from (
    select user_id, nullif(sum(planned_cents), 0) as total
      from public.budget_categories
     group by user_id
  ) c
 where c.user_id = b.user_id
   and b.monthly_limit_cents is distinct from c.total;

notify pgrst, 'reload schema';
