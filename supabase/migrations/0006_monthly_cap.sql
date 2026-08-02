-- 0006_monthly_cap: a monthly budget cap of its own, separate from the daily one.
--
-- Until now a "month cap" was derived — daily_limit_cents × days in the month.
-- That is the wrong number to judge a month by: the daily cap is a nudge
-- threshold sized for a single day's discretionary spending, so rent, a card
-- payoff, or an annual bill lands on one day and drags the whole month red.
--
-- Null keeps the old derived behaviour, so existing users see no change until
-- they set one. The daily cap is untouched and still drives check_overspend and
-- the pushes; this column is read by the app's Months screen only.

alter table public.budgets
  add column if not exists monthly_limit_cents int;

comment on column public.budgets.monthly_limit_cents is
  'Optional whole-month spending cap in cents. Null means fall back to '
  'daily_limit_cents x days in the month. Independent of the daily cap: this '
  'one is not a push threshold.';

alter table public.budgets
  drop constraint if exists budgets_monthly_limit_cents_positive;
alter table public.budgets
  add constraint budgets_monthly_limit_cents_positive
  check (monthly_limit_cents is null or monthly_limit_cents > 0);

notify pgrst, 'reload schema';
