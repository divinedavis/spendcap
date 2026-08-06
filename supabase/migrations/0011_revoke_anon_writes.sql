-- 0011_revoke_anon_writes: take INSERT/UPDATE/DELETE away from `anon`.
--
-- Found while adding the trip tables: every table in `public` carried anon
-- write grants, including `transactions` and `plaid_items`. That is not
-- something 0001–0010 did — it is Supabase's stock
-- `alter default privileges ... grant all on tables to anon`, which applies to
-- every table created in the schema, so each migration silently re-acquired it.
--
-- Nothing was exploitable: RLS is enabled on all twelve tables and every policy
-- keys off `user_id = auth.uid()`, which is NULL for an anon caller, so writes
-- were already refused. This removes the second half of the defence — a table
-- shipped one day with RLS off, or a policy written `using (true)` for a
-- genuinely public read, would otherwise be world-writable through the Data API
-- rather than merely world-readable.
--
-- SELECT is deliberately left alone. RLS default-denies it and 0001 grants it
-- on purpose.
--
-- Nothing in the app writes as `anon`: the client only reaches the Data API
-- after sign-in (role `authenticated`), sign-up goes through GoTrue rather than
-- a table write, `profiles` rows come from the `handle_new_user` trigger which
-- is security definer, and the edge functions use the service-role key.

revoke insert, update, delete on all tables in schema public from anon;

-- And stop the next migration from re-granting them by default.
alter default privileges in schema public revoke insert, update, delete on tables from anon;
alter default privileges for role postgres in schema public
  revoke insert, update, delete on tables from anon;

notify pgrst, 'reload schema';
