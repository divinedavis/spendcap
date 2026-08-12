-- 0017_debt_kind: 'debt' joins the closed set of budget-line kinds.
--
-- Debt payments (loans, insurance, card paydowns) are committed money the same
-- way rent is — but unlike rent they post *through* the linked checking
-- account, so Trends can't reserve the full planned amount without counting
-- the already-paid portion twice. The kind tag is what lets the client tell a
-- debt line apart from discretionary spending and reserve only the unpaid
-- remainder. No function change: category_spend() already returns `kind`.

alter table public.budget_categories
  drop constraint if exists budget_categories_kind_check;

alter table public.budget_categories
  add constraint budget_categories_kind_check check (
    kind is null or kind in (
      'rent', 'debt', 'food', 'transportation', 'utilities', 'subscriptions',
      'entertainment', 'health', 'savings', 'other'
    )
  );
