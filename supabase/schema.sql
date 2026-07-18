-- 0001_init: Spendcap core schema
-- Tables mirror Plaid objects; amount_cents > 0 = money out (Plaid convention).
-- Access tokens live in plaid_item_secrets, which no client role can read.

create extension if not exists pgcrypto;

-- ── profiles ────────────────────────────────────────────────────────────────
create table public.profiles (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  timezone   text not null default 'America/New_York',
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
create policy profiles_self on public.profiles
  for all to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ── budgets ─────────────────────────────────────────────────────────────────
create table public.budgets (
  user_id          uuid primary key references auth.users(id) on delete cascade,
  daily_limit_cents bigint not null default 5000 check (daily_limit_cents > 0),
  warn_pct         int    not null default 80 check (warn_pct between 1 and 100),
  updated_at       timestamptz not null default now()
);
alter table public.budgets enable row level security;
create policy budgets_self on public.budgets
  for all to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ── plaid_items (user-visible connection metadata) ──────────────────────────
create table public.plaid_items (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users(id) on delete cascade,
  plaid_item_id    text not null unique,
  institution_name text,
  status           text not null default 'active',
  sync_cursor      text,
  last_synced_at   timestamptz,
  created_at       timestamptz not null default now()
);
alter table public.plaid_items enable row level security;
create policy plaid_items_select_self on public.plaid_items
  for select to authenticated using (auth.uid() = user_id);
create policy plaid_items_delete_self on public.plaid_items
  for delete to authenticated using (auth.uid() = user_id);
-- inserts/updates come from edge functions via service_role only

-- ── plaid_item_secrets (Plaid access tokens — SERVER ONLY) ──────────────────
create table public.plaid_item_secrets (
  item_id      uuid primary key references public.plaid_items(id) on delete cascade,
  access_token text not null,
  created_at   timestamptz not null default now()
);
alter table public.plaid_item_secrets enable row level security;
-- No policies: only service_role (bypasses RLS) can touch this table.

-- ── accounts ────────────────────────────────────────────────────────────────
create table public.accounts (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references auth.users(id) on delete cascade,
  item_id               uuid not null references public.plaid_items(id) on delete cascade,
  plaid_account_id      text not null unique,
  name                  text not null,
  mask                  text,
  type                  text,
  subtype               text,
  current_balance_cents bigint,
  iso_currency          text not null default 'USD',
  created_at            timestamptz not null default now()
);
alter table public.accounts enable row level security;
create policy accounts_select_self on public.accounts
  for select to authenticated using (auth.uid() = user_id);

-- ── transactions ────────────────────────────────────────────────────────────
create table public.transactions (
  id                   uuid primary key default gen_random_uuid(),
  user_id              uuid not null references auth.users(id) on delete cascade,
  account_id           uuid not null references public.accounts(id) on delete cascade,
  plaid_transaction_id text not null unique,
  date                 date not null,
  authorized_date      date,
  name                 text not null default '',
  merchant_name        text,
  category             text,
  amount_cents         bigint not null,
  pending              boolean not null default false,
  is_removed           boolean not null default false,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create index transactions_user_date on public.transactions (user_id, date desc);
alter table public.transactions enable row level security;
create policy transactions_select_self on public.transactions
  for select to authenticated using (auth.uid() = user_id);

-- ── device_push_tokens ──────────────────────────────────────────────────────
create table public.device_push_tokens (
  device_token text primary key,
  user_id      uuid not null references auth.users(id) on delete cascade,
  platform     text not null default 'ios',
  updated_at   timestamptz not null default now()
);
alter table public.device_push_tokens enable row level security;
create policy device_push_tokens_self on public.device_push_tokens
  for all to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ── spend_alerts (dedupe log: one warn + one over per user per local day) ───
create table public.spend_alerts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  local_date  date not null,
  kind        text not null check (kind in ('warn', 'over')),
  spent_cents bigint not null,
  limit_cents bigint not null,
  sent_at     timestamptz not null default now(),
  unique (user_id, local_date, kind)
);
alter table public.spend_alerts enable row level security;
create policy spend_alerts_select_self on public.spend_alerts
  for select to authenticated using (auth.uid() = user_id);

-- ── auto-provision profile + budget on signup ───────────────────────────────
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (user_id) values (new.id) on conflict do nothing;
  insert into public.budgets (user_id) values (new.id) on conflict do nothing;
  return new;
end;
$$;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ── overspend status (service_role only; edge fn calls this after sync) ─────
create or replace function public.overspend_status()
returns table (
  user_id     uuid,
  local_date  date,
  spent_cents bigint,
  limit_cents bigint,
  warn_pct    int
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
  group by p.user_id, p.timezone, b.daily_limit_cents, b.warn_pct;
$$;
revoke execute on function public.overspend_status() from public, anon, authenticated;

-- ── account deletion (App Store 5.1.1) ──────────────────────────────────────
create or replace function public.delete_account()
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  delete from auth.users where id = auth.uid();
end;
$$;
revoke execute on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;

-- ── explicit grants (Supabase drops implicit public-schema grants 2026-10-30)
grant usage on schema public to anon, authenticated, service_role;
grant select, insert, update, delete on public.profiles, public.budgets, public.device_push_tokens to authenticated;
grant select, delete on public.plaid_items to authenticated;
grant select on public.accounts, public.transactions, public.spend_alerts to authenticated;
grant select on public.profiles, public.budgets, public.plaid_items, public.accounts,
  public.transactions, public.spend_alerts, public.device_push_tokens to anon;
grant all on all tables in schema public to service_role;

-- plaid_item_secrets: strip every client grant (incl. any default-privilege
-- auto-grant). The app never queries it, so a 42501 here is a feature.
revoke all on public.plaid_item_secrets from anon, authenticated;

notify pgrst, 'reload schema';
-- 0002_cron_sync: hourly fallback sync via pg_cron + pg_net.
-- Plaid webhooks are the primary trigger; this catches missed webhooks.
-- The x-cron-secret value lives in Vault (name 'cron_secret'), created
-- out-of-band — never in a committed migration.

create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule(
  'spendcap-hourly-sync',
  '15 * * * *',
  $$
  select net.http_post(
    url     := 'https://gmzzbslcsswqjjswoaen.supabase.co/functions/v1/sync_transactions',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')
    ),
    body := '{}'::jsonb
  );
  $$
);
