-- 0019_personal_care_kind: 'personal_care' joins the budget-line kinds.
--
-- Divine's free-to-spend model needs hair money to count as committed, the
-- same way rent/debt/transport/savings do — the tag is what lets the client
-- tell "spending that comes out of the $1,200 discretionary budget" from
-- spending that was always spoken for. Named for Plaid's PERSONAL_CARE
-- category rather than "hair" so the kind stays a category, not one person's
-- line name.

alter table public.budget_categories
  drop constraint if exists budget_categories_kind_check;

alter table public.budget_categories
  add constraint budget_categories_kind_check check (
    kind is null or kind in (
      'rent', 'debt', 'food', 'transportation', 'utilities', 'subscriptions',
      'entertainment', 'health', 'savings', 'personal_care', 'other'
    )
  );
