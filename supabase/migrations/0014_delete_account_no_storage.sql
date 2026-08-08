-- ── delete_account() could never delete an account ──────────────────────────
--
-- 0003 added a storage cleanup to the top of the function:
--
--   delete from storage.objects where bucket_id = 'statements' and ...;
--   delete from auth.users where id = uid;
--
-- The reasoning was right — storage.objects does NOT cascade from auth.users,
-- so deleting the user would orphan the statement PDFs, which are the most
-- sensitive bytes the app stores (full account numbers). The mechanism was
-- not: Supabase puts a BEFORE DELETE trigger on storage.objects
-- (protect_objects_delete → storage.protect_delete) that raises 42501 on any
-- direct delete. The function therefore aborted, the transaction rolled back,
-- and the user was never deleted.
--
-- Net effect: "Delete Account" showed an error and changed nothing, for every
-- build since 0003 — an App Store 5.1.1(v) feature that silently did not work.
-- Found 2026-08-08 when a reported account deletion turned out to have left
-- all 594 transactions, the Plaid item and the storage objects intact.
--
-- The fix is to take the storage delete out of SQL entirely. The PDFs are
-- removed client-side through the Storage API *before* this is called, which
-- is the only supported way to delete them; the policy that permits it
-- (statements_objects_delete_self, 0003) already exists.
--
-- The ordering matters and is the client's job: storage first, then this.
-- Deleting the user first would revoke the JWT that authorises the storage
-- delete and strand the PDFs permanently — the exact outcome 0003 was
-- written to prevent.

create or replace function public.delete_account()
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'not authenticated';
  end if;
  -- Deliberately no storage.objects delete here; see the note above. Every
  -- public table cascades from auth.users, so this one statement is the whole
  -- server-side deletion.
  delete from auth.users where id = uid;
end;
$$;

revoke execute on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;
