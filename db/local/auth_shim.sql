-- Local-only stand-in for Supabase's auth schema.
--
-- Supabase provides auth.uid() from the request JWT. Plain Postgres does not,
-- so db/policies.sql cannot be applied or tested locally without this. Load it
-- BEFORE db/policies.sql when running against a local database. Never load it
-- on Supabase -- it would shadow the real function.
--
--   psql -d fci -f db/schema.sql
--   psql -d fci -f db/local/auth_shim.sql
--   psql -d fci -f db/policies.sql
--
-- Set the acting user in a session with:
--   SET LOCAL app.current_user_id = '<uuid>';

CREATE SCHEMA IF NOT EXISTS auth;

CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT nullif(current_setting('app.current_user_id', true), '')::uuid;
$$;
