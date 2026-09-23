-- Collection sharing smoke test (issue #22): app_create_collection_share,
-- app_revoke_collection_share, app_delete_collection_share,
-- shared_collection_meta, shared_collection, and the RLS on
-- collection_share -- driven entirely through the RPCs as an unprivileged
-- role, exactly as a real guest (no account, no auth.uid()) would reach them.
--
--   psql -d fci -v ON_ERROR_STOP=1 -f db/tests/collection_share_smoke.sql
--
-- Requires schema.sql, auth_shim.sql, policies.sql and functions.sql loaded.
-- Runs in a transaction and rolls back.

BEGIN;
SET client_min_messages = notice;

CREATE OR REPLACE FUNCTION pg_temp.must_fail(stmt text, label text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE stmt;
  EXCEPTION WHEN others THEN
    RAISE NOTICE 'ok  (rejected) %', label;
    RETURN;
  END;
  RAISE EXCEPTION 'FAILED: % was allowed but must not be', label;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.act_as(who uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN PERFORM auth.act_as(who); END $$;

-- ---------------------------------------------------------------------------
-- Fixtures (as owner; RLS bypassed)
-- ---------------------------------------------------------------------------

INSERT INTO game (id, slug, name)
VALUES ('c0000000-0000-0000-0000-000000000001', 'share-game', 'Share Game');
INSERT INTO card_set (id, game_id, external_id, prefix, name)
VALUES ('c0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000001',
        'cs1', 'CS1', 'Share Set');

INSERT INTO card (id, game_id, external_uuid, slug, name) VALUES
  ('c0000000-0000-0000-0000-000000000011', 'c0000000-0000-0000-0000-000000000001',
   'shared-card', 'a-shared-card', 'A Shared Card');
INSERT INTO card_edition (id, card_id, set_id, external_uuid, slug, collector_number) VALUES
  ('c0000000-0000-0000-0000-000000000021', 'c0000000-0000-0000-0000-000000000011',
   'c0000000-0000-0000-0000-000000000002', 'shared-ed1', 'a-shared-card-1', '001');
INSERT INTO card_edition_finish (edition_id, finish) VALUES
  ('c0000000-0000-0000-0000-000000000021', 'NONFOIL'),
  ('c0000000-0000-0000-0000-000000000021', 'FOIL');

INSERT INTO account (id, email, display_name) VALUES
  ('c0000000-0000-0000-0000-000000000031', 'share-owner@example.com',  'Sharon'),
  ('c0000000-0000-0000-0000-000000000032', 'share-mike@example.com',   'Mike');

INSERT INTO location (id, account_id, kind, name) VALUES
  ('c0000000-0000-0000-0000-000000000041', 'c0000000-0000-0000-0000-000000000031',
   'physical', 'Sharon Box A');
-- A holder location naming Mike -- his identity must never leak through a
-- share, only the fact that some copies are out (14).
INSERT INTO location (id, account_id, kind, holder_account_id) VALUES
  ('c0000000-0000-0000-0000-000000000042', 'c0000000-0000-0000-0000-000000000031',
   'holder', 'c0000000-0000-0000-0000-000000000032');

-- 3 NM in the box, 2 LP foil out with Mike.
INSERT INTO holding (account_id, edition_id, finish, location_id, condition, qty) VALUES
  ('c0000000-0000-0000-0000-000000000031', 'c0000000-0000-0000-0000-000000000021',
   'NONFOIL', 'c0000000-0000-0000-0000-000000000041', 'NM', 3),
  ('c0000000-0000-0000-0000-000000000031', 'c0000000-0000-0000-0000-000000000021',
   'FOIL', 'c0000000-0000-0000-0000-000000000042', 'LP', 2);

-- ---------------------------------------------------------------------------
-- As the OWNER: creating a share, and that the row is not writable directly
-- ---------------------------------------------------------------------------

SET LOCAL ROLE app_user;
SELECT auth.act_as('c0000000-0000-0000-0000-000000000031');

SELECT pg_temp.must_fail(
  $$ INSERT INTO collection_share (account_id) VALUES (auth.uid()) $$,
  'inserting a share row directly, bypassing the RPC');

DO $$
DECLARE v_token text;
BEGIN
  SELECT token INTO v_token FROM app_create_collection_share('For sale', NULL);
  ASSERT v_token IS NOT NULL AND length(v_token) = 64,
    'a created share should carry a 64-character token';
  PERFORM set_config('pg_temp.share_token', v_token, false);
  RAISE NOTICE 'ok  (22) creating a share returns a usable token';
END $$;

DO $$ BEGIN
  ASSERT (SELECT count(*) FROM collection_share) = 1,
    'the share should be visible to its own owner';
  RAISE NOTICE 'ok  (22) collection_share is readable by its own owner';
END $$;

RESET ROLE;

-- ---------------------------------------------------------------------------
-- As a GUEST -- no account, no auth.uid() at all
-- ---------------------------------------------------------------------------

SET LOCAL ROLE app_user;
SELECT auth.act_as(NULL);

DO $$ BEGIN
  ASSERT (SELECT count(*) FROM collection_share) = 0,
    'a guest with no auth.uid() must not be able to read collection_share directly';
  RAISE NOTICE 'ok  (22) collection_share is not directly readable by a guest';
END $$;

DO $$
DECLARE v_meta record;
BEGIN
  SELECT * INTO v_meta FROM shared_collection_meta(current_setting('pg_temp.share_token'));
  ASSERT v_meta.owner_name = 'Sharon', 'the owner''s display name should come back';
  ASSERT v_meta.label = 'For sale', 'the share''s own label should come back';
  RAISE NOTICE 'ok  (22) shared_collection_meta resolves a live token';
END $$;

DO $$
DECLARE v_row record; v_count int;
BEGIN
  SELECT count(*) INTO v_count FROM shared_collection(current_setting('pg_temp.share_token'));
  ASSERT v_count = 2, 'the nonfoil-owned and foil-loaned groups should both come back';

  SELECT * INTO v_row FROM shared_collection(current_setting('pg_temp.share_token'))
   WHERE finish = 'NONFOIL';
  ASSERT v_row.card_name = 'A Shared Card', 'the card name should come back';
  ASSERT v_row.condition = 'NM', 'condition should come back';
  ASSERT v_row.qty_owned = 3, 'the 3 in-hand copies should count as owned';
  ASSERT v_row.qty_on_loan = 0, 'the nonfoil group has none on loan';
  RAISE NOTICE 'ok  (22) shared_collection reports name/finish/condition/qty correctly';
END $$;

-- The loaned foil copies must appear as their own group with qty_on_loan
-- set and qty_owned at 0 -- never silently merged into the owned total, and
-- shared_collection's own column list (edition_id, card_name, set_name,
-- collector_number, image_storage_key, finish, condition, qty_owned,
-- qty_on_loan) has no field that could name Mike or the box either way.
DO $$
DECLARE v_row record;
BEGIN
  SELECT * INTO v_row FROM shared_collection(current_setting('pg_temp.share_token'))
   WHERE finish = 'FOIL';
  ASSERT v_row.qty_owned = 0, 'a fully-loaned-out group should show 0 owned';
  ASSERT v_row.qty_on_loan = 2, 'the 2 loaned foil copies should count as on loan';
  ASSERT v_row.condition = 'LP', 'condition should still come back for a loaned group';
  RAISE NOTICE 'ok  (22) loaned-out copies are broken out as their own count, per (14)';
END $$;

DO $$ BEGIN
  ASSERT (SELECT count(*) FROM shared_collection_meta('not-a-real-token')) = 0,
    'an unknown token must resolve to nothing';
  ASSERT (SELECT count(*) FROM shared_collection('not-a-real-token')) = 0,
    'an unknown token must show no holdings either';
  RAISE NOTICE 'ok  (22) an unknown token resolves to nothing, not an error';
END $$;

RESET ROLE;

-- ---------------------------------------------------------------------------
-- Revoke and expiry -- a revoked or expired share must look identical to an
-- unknown one, never a distinguishable "this one used to work."
-- ---------------------------------------------------------------------------

SET LOCAL ROLE app_user;
SELECT auth.act_as('c0000000-0000-0000-0000-000000000031');

DO $$
DECLARE v_id uuid; v_token text;
BEGIN
  SELECT id, token INTO v_id, v_token FROM app_create_collection_share('Revoke me', NULL);
  PERFORM set_config('pg_temp.revoke_token', v_token, false);
  PERFORM app_revoke_collection_share(v_id);
END $$;

SELECT pg_temp.must_fail(
  $$ SELECT app_revoke_collection_share(gen_random_uuid()) $$,
  'revoking a share id that does not exist or is not yours');

SELECT auth.act_as(NULL);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM shared_collection_meta(current_setting('pg_temp.revoke_token'))) = 0,
    'a revoked token must resolve to nothing';
  RAISE NOTICE 'ok  (22) a revoked share stops working immediately';
END $$;

SELECT auth.act_as('c0000000-0000-0000-0000-000000000031');
DO $$
DECLARE v_token text;
BEGIN
  SELECT token INTO v_token
    FROM app_create_collection_share('Expires immediately', now() - interval '1 minute');
  PERFORM set_config('pg_temp.expired_token', v_token, false);
END $$;

SELECT auth.act_as(NULL);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM shared_collection_meta(current_setting('pg_temp.expired_token'))) = 0,
    'an already-expired share must resolve to nothing';
  RAISE NOTICE 'ok  (22) an expired share stops working without needing a revoke';
END $$;

-- ---------------------------------------------------------------------------
-- Delete actually removes the row (unlike revoke)
-- ---------------------------------------------------------------------------

SELECT auth.act_as('c0000000-0000-0000-0000-000000000031');
DO $$
DECLARE v_id uuid; v_before int; v_after int;
BEGIN
  SELECT count(*) INTO v_before FROM collection_share;
  SELECT id INTO v_id FROM app_create_collection_share('Delete me', NULL);
  PERFORM app_delete_collection_share(v_id);
  SELECT count(*) INTO v_after FROM collection_share;
  ASSERT v_after = v_before, 'deleting a share should leave the count where it started';
  RAISE NOTICE 'ok  (22) deleting a share actually removes the row';
END $$;

RESET ROLE;

DO $$ BEGIN RAISE NOTICE 'ALL COLLECTION SHARE ASSERTIONS PASSED'; END $$;

ROLLBACK;
