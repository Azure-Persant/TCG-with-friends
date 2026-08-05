-- Local-only stand-in for Supabase's auth schema.
--
-- Supabase provides auth.uid() and an auth.users table. Plain Postgres does
-- not, so db/policies.sql cannot be applied or tested locally without this.
-- Load it BEFORE db/policies.sql when running against a local database. Never
-- load it on Supabase -- it would shadow the real objects.
--
--   psql -d fci -f db/schema.sql
--   psql -d fci -f db/local/auth_shim.sql
--   psql -d fci -f db/policies.sql
--
-- Set the acting user in a session with:
--   SELECT auth.act_as('<uuid>');
--
-- FIDELITY
--
-- auth.uid() below is Supabase's real implementation, not a convenience
-- stand-in. It reads the `sub` claim out of the `request.jwt.claims` GUC that
-- PostgREST sets from the bearer token, exactly as production does.
--
-- This matters more than it sounds. The previous version of this file read a
-- bespoke `app.current_user_id` setting, which meant every RLS policy and
-- every SECURITY DEFINER function in this project had only ever been proven
-- against a function that did not resemble the one it will actually run
-- against. The source of the value, its NULL behaviour for an anonymous
-- request, and the cast all differed. Now the only thing being faked is who
-- sets the claims.

CREATE SCHEMA IF NOT EXISTS auth;

/**
 * The current user id, taken from the request JWT.
 *
 * Returns NULL for an anonymous request -- both when no claims are set at all
 * and when the claims carry no `sub`. Policies lean on that NULL: for an
 * anonymous caller `auth.uid() = account_id` evaluates to NULL rather than
 * true, and RLS treats anything that is not true as a denial.
 *
 * Both spellings are checked because PostgREST has used both over its life:
 * the flattened `request.jwt.claim.sub`, and the whole claims object as JSON.
 */
CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT nullif(
    coalesce(
      nullif(current_setting('request.jwt.claim.sub', true), ''),
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
    ), ''
  )::uuid;
$$;

/** Test helper: act as a user, by forging the claims PostgREST would set. */
CREATE OR REPLACE FUNCTION auth.act_as(who uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', who, 'role', 'authenticated')::text,
                     true);
END $$;

/** Test helper: go back to being an anonymous request. */
CREATE OR REPLACE FUNCTION auth.act_as_anon()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);
END $$;

-- ---------------------------------------------------------------------------
-- A stand-in for auth.users
-- ---------------------------------------------------------------------------
--
-- Only the columns db/auth_bridge.sql actually reads. Supabase's real table
-- has many more; depending on any of them here would mean depending on
-- something this file cannot honestly reproduce.

CREATE TABLE IF NOT EXISTS auth.users (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email              text UNIQUE,
  raw_user_meta_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at         timestamptz NOT NULL DEFAULT now()
);

-- An unprivileged role standing in for Supabase's `authenticated`. RLS does
-- not apply to superusers or table owners, so the tests must run as this role
-- for their assertions to mean anything.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN
    CREATE ROLE app_user NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA public, auth TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user;
GRANT EXECUTE ON FUNCTION auth.uid(), auth.act_as(uuid), auth.act_as_anon() TO app_user;

-- Deliberately NOT granted: a signed-in user has no business reading the auth
-- table directly, and Supabase does not grant it either.
REVOKE ALL ON auth.users FROM app_user;
