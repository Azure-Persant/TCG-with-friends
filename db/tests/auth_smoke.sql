-- Auth bridge smoke test.
--
-- Proves the single assumption every RLS policy in this project rests on:
-- that account.id equals auth.users.id, so auth.uid() actually matches
-- something. If this file fails, nothing else in the app works and the
-- symptom is not an error -- it is every list coming back empty.
--
--   psql -d fci -v ON_ERROR_STOP=1 -f db/tests/auth_smoke.sql
--
-- Requires schema.sql, auth_shim.sql, auth_bridge.sql, policies.sql,
-- functions.sql. Runs in a transaction and rolls back.

BEGIN;
SET client_min_messages = notice;

CREATE OR REPLACE FUNCTION pg_temp.must_fail(stmt text, label text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE stmt;
  EXCEPTION WHEN others THEN
    RAISE NOTICE 'ok  (rejected) %', label; RETURN;
  END;
  RAISE EXCEPTION 'FAILED: % was allowed but must not be', label;
END $$;

-- ---------------------------------------------------------------------------
-- Signing up provisions an account with the SAME id
-- ---------------------------------------------------------------------------

INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('11111111-1111-1111-1111-111111111111', 'jon@example.com',
        '{"display_name":"Jon"}'::jsonb);

DO $$
DECLARE a account;
BEGIN
  SELECT * INTO a FROM account WHERE id = '11111111-1111-1111-1111-111111111111';

  ASSERT a.id IS NOT NULL, 'signing up must create an account row';
  ASSERT a.email = 'jon@example.com', 'email should carry over';
  ASSERT a.display_name = 'Jon', 'display_name should come from user metadata';
  RAISE NOTICE 'ok  signup provisions an account sharing the auth user id';
END $$;

-- The whole point: auth.uid() must resolve to a real account.
SELECT auth.act_as('11111111-1111-1111-1111-111111111111');
DO $$ BEGIN
  ASSERT auth.uid() = '11111111-1111-1111-1111-111111111111', 'auth.uid() should read the JWT sub';
  ASSERT EXISTS (SELECT 1 FROM account WHERE id = auth.uid()),
    'auth.uid() must match an account -- every policy in the app depends on it';
  RAISE NOTICE 'ok  auth.uid() resolves to an account row';
END $$;

-- ---------------------------------------------------------------------------
-- Display name fallbacks: it is NOT NULL and users are found by it
-- ---------------------------------------------------------------------------

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('22222222-2222-2222-2222-222222222222', 'sarah@example.com',
   '{"full_name":"Sarah Lee"}'::jsonb),
  ('33333333-3333-3333-3333-333333333333', 'mike@example.com',
   '{"name":"Mike"}'::jsonb),
  ('44444444-4444-4444-4444-444444444444', 'nometa@example.com', '{}'::jsonb),
  ('55555555-5555-5555-5555-555555555555', 'blank@example.com',
   '{"display_name":"   "}'::jsonb);

DO $$ BEGIN
  ASSERT (SELECT display_name FROM account WHERE id = '22222222-2222-2222-2222-222222222222')
         = 'Sarah Lee', 'should fall back to full_name';
  ASSERT (SELECT display_name FROM account WHERE id = '33333333-3333-3333-3333-333333333333')
         = 'Mike', 'should fall back to name';
  ASSERT (SELECT display_name FROM account WHERE id = '44444444-4444-4444-4444-444444444444')
         = 'nometa', 'should fall back to the local part of the email';
  ASSERT (SELECT display_name FROM account WHERE id = '55555555-5555-5555-5555-555555555555')
         = 'blank', 'whitespace-only metadata is not a name';
  RAISE NOTICE 'ok  display_name falls back through metadata, then email, never empty';
END $$;

-- ---------------------------------------------------------------------------
-- Changing your email in Supabase Auth keeps the app in step
-- ---------------------------------------------------------------------------

UPDATE account SET display_name = 'Jonathan'
 WHERE id = '11111111-1111-1111-1111-111111111111';

UPDATE auth.users SET email = 'jon.new@example.com'
 WHERE id = '11111111-1111-1111-1111-111111111111';

DO $$
DECLARE a account;
BEGIN
  SELECT * INTO a FROM account WHERE id = '11111111-1111-1111-1111-111111111111';
  ASSERT a.email = 'jon.new@example.com', 'email change should sync through';
  -- The important half: syncing email must not clobber a chosen name.
  ASSERT a.display_name = 'Jonathan',
    'an auth email change must not overwrite the name the user picked';
  RAISE NOTICE 'ok  email syncs on change; a user-chosen display_name survives it';
END $$;

-- ---------------------------------------------------------------------------
-- Deleting an auth user leaves the account (and the loan history) standing
-- ---------------------------------------------------------------------------

DELETE FROM auth.users WHERE id = '33333333-3333-3333-3333-333333333333';

DO $$ BEGIN
  ASSERT EXISTS (SELECT 1 FROM account WHERE id = '33333333-3333-3333-3333-333333333333'),
    'deleting an auth user must NOT cascade -- (5) exists to stop custody records vanishing';
  RAISE NOTICE 'ok  auth deletion orphans the account rather than erasing custody history';
END $$;

-- ---------------------------------------------------------------------------
-- Re-applying the bridge is safe
-- ---------------------------------------------------------------------------

INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('66666666-6666-6666-6666-666666666666', 'later@example.com', '{}'::jsonb);
DELETE FROM account WHERE id = '66666666-6666-6666-6666-666666666666';

-- The backfill clause out of db/auth_bridge.sql, run again.
INSERT INTO account (id, email, display_name)
SELECT u.id, u.email,
       coalesce(nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''),
                nullif(split_part(coalesce(u.email, ''), '@', 1), ''), 'Player')
  FROM auth.users u
 WHERE u.email IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM account a WHERE a.id = u.id)
   AND NOT EXISTS (SELECT 1 FROM account a WHERE a.email = u.email);

DO $$
DECLARE n int;
BEGIN
  ASSERT EXISTS (SELECT 1 FROM account WHERE id = '66666666-6666-6666-6666-666666666666'),
    'backfill should pick up an account that went missing';
  SELECT count(*) INTO n FROM account;
  ASSERT n = 6, format('backfill must not duplicate anyone, got %s accounts', n);
  RAISE NOTICE 'ok  backfill is idempotent and creates no duplicates';
END $$;

-- ---------------------------------------------------------------------------
-- An anonymous request is nobody
-- ---------------------------------------------------------------------------

SELECT auth.act_as_anon();
DO $$ BEGIN
  ASSERT auth.uid() IS NULL, 'no claims must mean no user';
  RAISE NOTICE 'ok  an anonymous request has a NULL auth.uid()';
END $$;

-- Claims present but carrying no `sub` -- a malformed token, not a valid one.
SELECT set_config('request.jwt.claims', '{"role":"authenticated"}', true);
DO $$ BEGIN
  ASSERT auth.uid() IS NULL, 'claims without a sub must not resolve to a user';
  RAISE NOTICE 'ok  a token with no subject resolves to nobody, not an error';
END $$;

-- ---------------------------------------------------------------------------
-- RLS still denies the anonymous caller
-- ---------------------------------------------------------------------------

SET LOCAL ROLE app_user;
SELECT auth.act_as_anon();

DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM account;
  ASSERT n = 0, format('an anonymous caller must see no accounts, saw %s', n);
  RAISE NOTICE 'ok  anonymous sees nothing: NULL = anything is never true';
END $$;

-- A signed-in user has no business reading the auth table.
SELECT auth.act_as('11111111-1111-1111-1111-111111111111');
SELECT pg_temp.must_fail($$ SELECT count(*) FROM auth.users $$,
  'a signed-in user reading auth.users directly');

DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM account;
  ASSERT n = 1, format('a signed-in user with no friends should see only themselves, saw %s', n);
  RAISE NOTICE 'ok  signed in, sees exactly themselves';
END $$;

RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'ALL AUTH ASSERTIONS PASSED'; END $$;

ROLLBACK;
