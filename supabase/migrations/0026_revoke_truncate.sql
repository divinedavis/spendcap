-- 0026_revoke_truncate: take TRUNCATE (and TRIGGER/REFERENCES) off the client
-- roles on every public table.
--
-- Found while checking the grants on 0025's new tables: `anon` and
-- `authenticated` hold TRUNCATE on every table in the schema, from Supabase's
-- default privileges rather than from anything this project wrote. **TRUNCATE
-- is not subject to row-level security** — one statement would empty a table
-- for every user on the project, RLS policies and all.
--
-- It is not reachable today: those roles are only ever assumed by PostgREST,
-- which has no TRUNCATE verb, and no client holds a Postgres password. This is
-- defence in depth — it removes the grant so that a future security-definer
-- function running dynamic SQL, or any direct-connection path, cannot reach it.
-- TRIGGER and REFERENCES go with it for the same reason: no client needs to
-- attach a trigger or a foreign key to these tables.
--
-- SELECT / INSERT / UPDATE / DELETE are deliberately untouched. Those are what
-- the app uses and what RLS is there to scope.

do $$
declare
  t record;
begin
  for t in
    select tablename
      from pg_tables
     where schemaname = 'public'
  loop
    execute format(
      'revoke truncate, trigger, references on public.%I from anon, authenticated',
      t.tablename);
  end loop;
end
$$;

-- And stop the defaults from handing it back to every table added later.
alter default privileges in schema public
  revoke truncate, trigger, references on tables from anon, authenticated;

notify pgrst, 'reload schema';
