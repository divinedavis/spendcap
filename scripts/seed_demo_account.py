#!/usr/bin/env python3
"""Seed the App Review demo account with a synthetic bank connection.

Why this exists: Plaid runs in production, and production has no test bank.
An App Store reviewer cannot link an account, so without this the demo login
opens onto five empty tabs and the app looks like it does nothing. This gives
that account a fake institution, two accounts, four months of realistic
transactions, and a Debt tab with items that match them — the screens then
read exactly as they do on a real account.

What it must not do:

* **Reach Plaid.** The item is inserted with `status = 'demo'`, and both crons
  (`sync_transactions`, `statements_cron`) select `status = 'active'` only, so
  they never look for an access token that does not exist. Settings shows a
  small "Demo" tag beside the institution, which is accurate.
* **Touch any other user.** Everything is keyed on the one user whose email is
  in the `spendcap-test-account` keychain item, and the delete step only
  removes rows whose `plaid_item_id` starts with `demo-`.
* **Drift between runs.** The generator is seeded, so re-running produces the
  same history up to today; new days are appended as the calendar moves.

Idempotent: the previous demo item (and its accounts + transactions, via
cascade) and the demo debt groups are dropped and rebuilt on every run. The
budget lines and category rules on the account are left alone — the UI tests
own those.

    python3 scripts/seed_demo_account.py            # apply
    python3 scripts/seed_demo_account.py --dry-run  # print the SQL only

Needs `psql` and the `spendcap-supabase-db-password` keychain item.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import random
import subprocess
import sys

DB_HOST = "aws-0-us-east-1.pooler.supabase.com"
DB_USER = "postgres.gmzzbslcsswqjjswoaen"
INSTITUTION = "First Demo Bank"
SEED = 20260718  # the day the account was created


def keychain(service: str) -> str:
    out = subprocess.run(["security", "find-generic-password", "-s", service, "-w"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit(f"keychain item {service!r} not found")
    return out.stdout.strip()


def q(s: str | None) -> str:
    return "null" if s is None else "'" + s.replace("'", "''") + "'"


# ---------------------------------------------------------------------------
# Transaction generator. Amounts in cents; positive = money out (Plaid's sign).
# Categories are Plaid primary personal-finance categories, which is what the
# account's category_rules route on.
# ---------------------------------------------------------------------------

def month_days(year: int, month: int) -> int:
    nxt = dt.date(year + (month == 12), month % 12 + 1, 1)
    return (nxt - dt.date(year, month, 1)).days


def generate(start: dt.date, today: dt.date) -> list[dict]:
    rng = random.Random(SEED)
    rows: list[dict] = []
    seq = 0

    def add(date: dt.date, name: str, merchant: str | None, category: str,
            cents: int, pending: bool = False) -> None:
        nonlocal seq
        seq += 1
        rows.append({
            "id": f"demo-txn-{seq:05d}",
            "date": date, "authorized_date": date,
            "name": name, "merchant": merchant, "category": category,
            "cents": cents, "pending": pending,
        })

    d = start
    while d <= today:
        wd = d.weekday()  # Mon=0
        last_day = d.day == month_days(d.year, d.month)

        # --- Monthly fixed items -------------------------------------------
        if d.day == 1:
            add(d, "RENT PAYMENT CLINTON HILL PROPERTIES LLC", None, "RENT_AND_UTILITIES", 295000)
        if d.day == 1:
            add(d, "Netflix", "Netflix", "ENTERTAINMENT", 1799)
        if d.day == 2:
            add(d, "AFFIRM.COM PAYMENTS", "Affirm", "LOAN_PAYMENTS", 5820)
        if d.day == 12:
            add(d, "Spotify USA", "Spotify", "ENTERTAINMENT", 1199)
        if d.day == 14:
            add(d, "CONED CONSOLIDATED EDISON BILL PAY", "Con Edison", "RENT_AND_UTILITIES",
                rng.randint(6400, 9800))
        if d.day == 15:
            add(d, "SOFI LENDING STUDENT LN PMT", "SoFi", "LOAN_PAYMENTS", 31200)
        if d.day == 20:
            add(d, "VERIZON FIOS AUTOPAY", "Verizon", "RENT_AND_UTILITIES", 7999)
        if d.day == 22:
            add(d, "CHASE CARD PAYMENT AUTOPAY", "Chase", "LOAN_PAYMENTS", 45000)
        if d.day == 3:
            add(d, "CITI BIKE MEMBERSHIP", "Citi Bike", "TRANSPORTATION", 1900)
        # Payroll: 15th and last day, money in.
        if d.day == 15 or last_day:
            add(d, "PAYROLL DIRECT DEP ACME DESIGN CO", None, "INCOME", -315000)

        # --- Weekly rhythm -------------------------------------------------
        if wd == 0:  # Monday: savings sweep
            add(d, "SAVINGS TRANSFER TO XXXXXX4410", None, "TRANSFER_OUT", 12500)
        if wd == 5:  # Saturday: groceries
            add(d, "TRADER JOE'S #542 BROOKLYN NY", "Trader Joe's", "FOOD_AND_DRINK",
                rng.randint(4200, 8800))
        if wd == 6 and rng.random() < 0.8:  # Sunday: delivery
            add(d, "UBER EATS", "Uber Eats", "FOOD_AND_DRINK", rng.randint(2200, 4600))
        if wd in (1, 3) and rng.random() < 0.85:  # weekday lunches
            spot = rng.choice([("SWEETGREEN FLATIRON", "Sweetgreen", 1450, 1900),
                               ("CHIPOTLE 2331", "Chipotle", 1180, 1620),
                               ("JOE'S PIZZA BROADWAY", "Joe's Pizza", 650, 1400)])
            add(d, spot[0], spot[1], "FOOD_AND_DRINK", rng.randint(spot[2], spot[3]))
        if wd < 5 and rng.random() < 0.6:  # coffee
            add(d, "BLUE BOTTLE COFFEE", "Blue Bottle Coffee", "FOOD_AND_DRINK", rng.randint(525, 825))
        if wd < 5:  # subway, both ways most days
            for _ in range(2 if rng.random() < 0.85 else 1):
                add(d, "MTA*NYCT PAYGO NEW YORK NY", "MTA", "TRANSPORTATION", 290)
        if wd in (4, 5) and rng.random() < 0.5:
            add(d, "LYFT RIDE", "Lyft", "TRANSPORTATION", rng.randint(1400, 3200))

        # --- Occasional ----------------------------------------------------
        if rng.random() < 0.10:
            add(d, "AMAZON.COM*MKTPL", "Amazon", "GENERAL_MERCHANDISE", rng.randint(1800, 7500))
        if rng.random() < 0.06:
            add(d, "TARGET T-2183 BROOKLYN", "Target", "GENERAL_MERCHANDISE", rng.randint(3000, 9000))
        if rng.random() < 0.03:
            add(d, "AMC THEATRES ONLINE", "AMC Theatres", "ENTERTAINMENT", 1900)
        if wd == 2 and (d.toordinal() // 7) % 2 == 0:  # every other Wednesday
            add(d, "FELLOW BARBER FORT GREENE", "Fellow Barber", "PERSONAL_CARE", 4500)

        d += dt.timedelta(days=1)

    # A couple of pending charges for today, so the top of Activity looks live.
    add(today, "PURCHASE PENDING WHOLEFDS BKN", "Whole Foods", "FOOD_AND_DRINK", 2340, pending=True)
    add(today, "MTA*NYCT PAYGO NEW YORK NY", "MTA", "TRANSPORTATION", 290, pending=True)
    return rows


def build_sql(email: str, rows: list[dict], today: dt.date) -> str:
    out: list[str] = []
    out.append("begin;")
    out.append(f"""
create temp table demo_ctx as
  select id as user_id from auth.users where email = {q(email)};
do $$ begin
  if (select count(*) from demo_ctx) <> 1 then
    raise exception 'demo account % not found', {q(email)};
  end if;
end $$;
""")
    # Wipe the previous demo item; accounts + transactions cascade.
    out.append("""
delete from public.plaid_items
 where user_id = (select user_id from demo_ctx) and plaid_item_id like 'demo-%';
delete from public.debt_groups where user_id = (select user_id from demo_ctx);
""")
    out.append(f"""
insert into public.plaid_items (user_id, plaid_item_id, institution_name, status, last_synced_at)
select user_id, 'demo-item-' || user_id, {q(INSTITUTION)}, 'demo', now() from demo_ctx;

insert into public.accounts (user_id, item_id, plaid_account_id, name, mask, type, subtype, current_balance_cents)
select user_id, (select id from public.plaid_items where plaid_item_id = 'demo-item-' || user_id),
       'demo-acct-checking-' || user_id, 'Everyday Checking', '4821', 'depository', 'checking', 284512
  from demo_ctx;
insert into public.accounts (user_id, item_id, plaid_account_id, name, mask, type, subtype, current_balance_cents)
select user_id, (select id from public.plaid_items where plaid_item_id = 'demo-item-' || user_id),
       'demo-acct-savings-' || user_id, 'Rainy Day Savings', '4410', 'depository', 'savings', 612000
  from demo_ctx;
""")
    values = []
    for r in rows:
        values.append(
            f"({q(r['id'])}, date '{r['date']}', date '{r['authorized_date']}', {q(r['name'])}, "
            f"{q(r['merchant'])}, {q(r['category'])}, {r['cents']}, {'true' if r['pending'] else 'false'})")
    out.append("""
insert into public.transactions
  (user_id, account_id, plaid_transaction_id, date, authorized_date, name, merchant_name,
   category, amount_cents, pending)
select c.user_id,
       (select id from public.accounts where plaid_account_id = 'demo-acct-checking-' || c.user_id),
       v.plaid_transaction_id || '-' || c.user_id, v.date, v.authorized_date, v.name, v.merchant_name,
       v.category, v.amount_cents, v.pending
  from demo_ctx c,
       (values
""" + ",\n".join(values) + """
       ) as v(plaid_transaction_id, date, authorized_date, name, merchant_name, category, amount_cents, pending);
""")
    # Debt tab: groups + items whose match values hit the seeded charges.
    out.append("""
insert into public.debt_groups (user_id, name, sort_order)
select user_id, g.name, g.ord from demo_ctx,
  (values ('Loans', 0), ('Buy now, pay later', 1), ('Subscriptions', 2)) as g(name, ord);

insert into public.debt_items (user_id, group_id, name, note, planned_cents, match_value, sort_order)
select c.user_id, g.id, i.name, i.note, i.planned, i.match, i.ord
  from demo_ctx c
  join (values
    ('Loans', 'SoFi student loan', 'Undergrad, 2029 payoff', 31200, 'SOFI', 0),
    ('Loans', 'Chase Sapphire', 'Card payment', 45000, 'CHASE CARD', 1),
    ('Buy now, pay later', 'Affirm', 'Standing desk, 4 of 12', 5820, 'AFFIRM', 0),
    ('Subscriptions', 'Netflix', null, 1799, 'NETFLIX', 0),
    ('Subscriptions', 'Spotify', null, 1199, 'SPOTIFY', 1)
  ) as i(grp, name, note, planned, match, ord) on true
  join public.debt_groups g on g.user_id = c.user_id and g.name = i.grp;
""")
    out.append("commit;")
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--start", default="2026-05-01")
    args = ap.parse_args()

    creds = json.loads(keychain("spendcap-test-account"))
    email = creds["email"]
    today = dt.date.today()
    start = dt.date.fromisoformat(args.start)
    rows = generate(start, today)
    sql = build_sql(email, rows, today)
    if args.dry_run:
        print(sql)
        return 0

    password = keychain("spendcap-supabase-db-password")
    conn = f"host={DB_HOST} port=5432 dbname=postgres user={DB_USER} sslmode=require"
    r = subprocess.run(["psql", conn, "-v", "ON_ERROR_STOP=1", "-q"], input=sql,
                       capture_output=True, text=True, env={"PGPASSWORD": password, "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"})
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        return 1
    outflow = sum(x["cents"] for x in rows if x["cents"] > 0) / 100
    print(f"seeded {len(rows)} transactions ({start} → {today}) for the demo account; "
          f"${outflow:,.0f} out over the period")
    return 0


if __name__ == "__main__":
    sys.exit(main())
