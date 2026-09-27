-- 0030_plaid_item_removal: disconnecting a bank (or deleting the account)
-- now ends the connection at Plaid, not just in our database.
--
-- Until now, "Disconnect" deleted the plaid_items row and "Delete Account"
-- deleted auth.users, and both cascaded away the access token — but nothing
-- ever called Plaid's /item/remove. The Item stayed live at Plaid (and at the
-- bank's consent screen) with nobody left holding its token, while the
-- privacy policy promised account deletion removed bank connections.
--
-- The primary path is the new `plaid_remove_item` edge function: the app calls
-- it for one item on Disconnect and for every item before delete_account(),
-- and it calls /item/remove FIRST, then marks the row 'removed' and deletes it.
--
-- This migration is the safety net for every delete that does not go through
-- that function — builds already in testers' hands still delete plaid_items
-- directly, and the auth.users cascade reaches plaid_items too. A BEFORE
-- DELETE trigger copies the access token into a service-only queue, and the
-- hourly `plaid_removal_cron` drains it. BEFORE DELETE on plaid_items is the
-- one place that works for all of those: row triggers fire on cascaded
-- deletes, and plaid_item_secrets (which cascades from plaid_items) is still
-- there to read, because the cascade to it runs after the parent row goes.
--
-- Rows the edge function already removed at Plaid carry status 'removed' and
-- are skipped; 'demo' rows (the App Review account) never had a real Item.

create table if not exists public.plaid_item_removals (
  id             bigint generated always as identity primary key,
  plaid_item_id  text not null,
  access_token   text not null,
  user_id        uuid,               -- no FK: the user may be gone by now
  queued_at      timestamptz not null default now(),
  attempts       int not null default 0,
  last_error     text,
  last_attempt_at timestamptz
);
alter table public.plaid_item_removals enable row level security;
-- No policies and no client grants: this holds access tokens, exactly like
-- plaid_item_secrets. service_role bypasses RLS.
revoke all on public.plaid_item_removals from public, anon, authenticated;
grant select, insert, update, delete on public.plaid_item_removals to service_role;

create or replace function public.queue_plaid_item_removal()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  tok text;
begin
  if old.status in ('removed', 'demo') then
    return old;
  end if;
  select access_token into tok from public.plaid_item_secrets where item_id = old.id;
  if tok is not null then
    insert into public.plaid_item_removals (plaid_item_id, access_token, user_id)
    values (old.plaid_item_id, tok, old.user_id);
  end if;
  return old;
end;
$$;
revoke execute on function public.queue_plaid_item_removal() from public, anon, authenticated;

drop trigger if exists plaid_items_queue_removal on public.plaid_items;
create trigger plaid_items_queue_removal
  before delete on public.plaid_items
  for each row execute function public.queue_plaid_item_removal();

-- :35 keeps it clear of the hourly transaction sync at :15. The x-cron-secret
-- value lives in Vault (name 'cron_secret'), as for the other two jobs.
select cron.unschedule('spendcap-plaid-removals')
 where exists (select 1 from cron.job where jobname = 'spendcap-plaid-removals');
select cron.schedule(
  'spendcap-plaid-removals',
  '35 * * * *',
  $$
  select net.http_post(
    url     := 'https://gmzzbslcsswqjjswoaen.supabase.co/functions/v1/plaid_removal_cron',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')
    ),
    body := '{}'::jsonb
  );
  $$
);
