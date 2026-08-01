-- 0003_statements: Plaid Statements — metadata in Postgres, PDF bytes in a
-- private Storage bucket.
--
-- Statement PDFs are the most sensitive thing this app has ever stored: they
-- carry full account numbers, not the 4-digit mask in public.accounts. So the
-- bucket is private (no public URL, reads go through a short-lived signed URL),
-- objects are namespaced under the owner's uid, and every policy is scoped to
-- auth.uid() rather than relying on the bucket being "not public".

-- ── statements (metadata only — never the file itself) ──────────────────────
create table public.statements (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users(id) on delete cascade,
  item_id            uuid not null references public.plaid_items(id) on delete cascade,
  account_id         uuid references public.accounts(id) on delete set null,
  plaid_statement_id text not null unique,
  period_start       date,
  period_end         date,
  -- Denormalised for cheap "past year, newest first" ordering without
  -- date_part() on every row.
  year               int  not null,
  month              int  not null check (month between 1 and 12),
  -- Object key inside the 'statements' bucket: "<uid>/<statement_id>.pdf".
  -- Null until the download succeeds, so a failed fetch leaves a visible row
  -- rather than silently vanishing.
  storage_path       text,
  byte_size          bigint,
  fetched_at         timestamptz,
  created_at         timestamptz not null default now()
);
create index statements_user_period_idx
  on public.statements (user_id, year desc, month desc);

alter table public.statements enable row level security;
create policy statements_select_self on public.statements
  for select to authenticated using (auth.uid() = user_id);
create policy statements_delete_self on public.statements
  for delete to authenticated using (auth.uid() = user_id);
-- inserts/updates come from the edge function via service_role only

-- ── private bucket ──────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('statements', 'statements', false, 52428800, array['application/pdf'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Objects live at "<uid>/<plaid_statement_id>.pdf". Comparing the first path
-- segment to auth.uid() is what actually enforces per-user isolation — a
-- bucket-wide policy would let any signed-in user read every statement.
create policy statements_objects_select_self on storage.objects
  for select to authenticated
  using (
    bucket_id = 'statements'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy statements_objects_delete_self on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'statements'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
-- No insert/update policy: only the edge function (service_role) writes here.

-- ── account deletion must take the PDFs with it ─────────────────────────────
-- public.statements cascades from auth.users, but storage.objects does not —
-- deleting the account would otherwise orphan the PDFs in the bucket forever,
-- which is exactly the data we least want to keep. Clean them up first.
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
  delete from storage.objects
   where bucket_id = 'statements'
     and (storage.foldername(name))[1] = uid::text;
  delete from auth.users where id = uid;
end;
$$;
revoke execute on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;

-- ── explicit grants (Supabase drops implicit public-schema grants 2026-10-30)
grant select, delete on public.statements to authenticated;
grant all on public.statements to service_role;
-- Deliberately no anon grant. 0001 hands anon a blanket select on the other
-- tables and leans on RLS to return zero rows; that is one policy mistake away
-- from leaking, and this is the table holding statement locations. Anon has no
-- reason to see it at all, so the grant simply never exists.
revoke all on public.statements from anon;

notify pgrst, 'reload schema';
