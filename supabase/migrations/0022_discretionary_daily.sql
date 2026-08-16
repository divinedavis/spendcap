-- 0022_discretionary_daily: per-day discretionary outflow for one month.
--
-- "Free to spend this week" stopped being a month figure divided by four and
-- became a real weekly bucket that carries its leftover forward (see
-- WeekMath). Recutting the bucket every Monday needs to know what the
-- discretionary spend was *within* the month, day by day — and discretionary
-- is not something the client can work out. Whether a transaction is
-- discretionary depends on which budget line the rules route it into and what
-- kind that line carries, and the rules live in the database. The month
-- transactions Trends already fetches carry no resolved line at all.
--
-- So the server answers "how much discretionary money left the account on each
-- day", and the client — which is where the timezone and the user's week start
-- are known — does the calendar bucketing. Same split as monthly_spend() /
-- YearMath and DailySpend.weekday: aggregate where the rules are, resolve
-- weekdays where the timezone is.
--
-- The numbers must reconcile: summing every day this function returns has to
-- equal category_spend()'s discretionary total for the same month, or the
-- weekly card and the budget card disagree about the same money. That is why
-- the outflow filter and the whole rule-resolution block below are copied from
-- category_spend() verbatim rather than approximated.
--
-- NOTE: this is now the fourth copy of that rule-resolution subquery
-- (category_spend, category_transactions, month_activity, and here). They must
-- move together — changing precedence in one place and not the others silently
-- re-buckets history on one screen only.

create or replace function public.discretionary_daily(period date)
returns table (
  day         date,
  spent_cents bigint
)
language sql
stable
security invoker
set search_path = public
as $$
  with txn as (
    select t.id,
           t.date,
           t.amount_cents,
           public.txn_display_name(t.name, t.merchant_name, t.category) as who,
           t.category
      from public.transactions t
     where t.user_id = auth.uid()
       and t.is_removed = false
       and t.amount_cents > 0
       -- Same outflow filter as overspend_status(), monthly_spend() and
       -- category_spend().
       and not (t.pending and t.is_backfill)
       and t.date >= period
       and t.date < (period + interval '1 month')::date
  ),
  matched as (
    select x.*,
           (
             select r.category_id
               from public.category_rules r
              where r.user_id = auth.uid()
                and (r.amount_cents is null or r.amount_cents = x.amount_cents)
                and (
                     (r.match_type = 'merchant_contains' and x.who ilike '%' || r.match_value || '%')
                  or (r.match_type = 'plaid_category'    and x.category = r.match_value)
                )
              -- Most specific wins: a named merchant beats a whole Plaid
              -- category, an amount-qualified rule beats an unqualified one,
              -- and a longer merchant string beats a shorter one.
              order by (r.match_type = 'merchant_contains') desc,
                       (r.amount_cents is not null) desc,
                       length(r.match_value) desc
              limit 1
           ) as category_id
      from txn x
  )
  select m.date                      as day,
         sum(m.amount_cents)::bigint as spent_cents
    from matched m
    left join public.budget_categories c
      on c.id = m.category_id
     and c.user_id = auth.uid()
   -- Discretionary is everything not fenced off by a committed tag:
   --   * c.id is null   — Uncategorized. Unclaimed spending came out of the
   --                      free money, not out of rent. Matches
   --                      CategoryMonth.discretionarySpentCents, which counts
   --                      it in.
   --   * c.kind is null — untagged, and untagged is discretionary by default.
   --                      Committed is opted into by tagging, never guessed.
   -- The committed list is CategoryKind.isCommitted in Swift and must stay
   -- identical to it.
   where c.id is null
      or c.kind is null
      or c.kind not in ('rent', 'debt', 'transportation', 'savings', 'personal_care')
   group by m.date
   order by 1;
$$;

grant execute on function public.discretionary_daily(date) to authenticated, service_role;

notify pgrst, 'reload schema';
