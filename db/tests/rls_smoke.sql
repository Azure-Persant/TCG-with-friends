-- RLS smoke test for db/policies.sql.
--
-- Asserts that the privacy decisions are enforced against an unprivileged
-- role, not merely expressed. Setup runs as the owner (who bypasses RLS);
-- assertions run as app_user (who does not).
--
--   psql -d fci -f db/schema.sql
--   psql -d fci -f db/local/auth_shim.sql
--   psql -d fci -f db/policies.sql
--   psql -d fci -v ON_ERROR_STOP=1 -f db/tests/rls_smoke.sql

BEGIN;
SET client_min_messages = notice;

-- app_user and its grants are created by db/local/auth_shim.sql.

-- ---------------------------------------------------------------------------
-- Fixtures (as owner, RLS bypassed)
-- ---------------------------------------------------------------------------

INSERT INTO game (id, slug, name) VALUES
  ('10000000-0000-0000-0000-000000000001', 'rls-shared',  'Shared Game'),
  ('10000000-0000-0000-0000-000000000002', 'rls-private', 'Private Game');

INSERT INTO card_set (id, game_id, external_id, prefix, name) VALUES
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 's1', 'S1', 'Set One'),
  ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 's2', 'S2', 'Set Two');

INSERT INTO card (id, game_id, external_uuid, slug, name) VALUES
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'rc1', 'rls-card-1', 'Shared Card'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'rc2', 'rls-card-2', 'Private Card');

INSERT INTO card_edition (id, card_id, set_id, external_uuid, slug, collector_number) VALUES
  ('40000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000001', 're1', 'rls-ed-1', '1'),
  ('40000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000002', 're2', 'rls-ed-2', '2');

INSERT INTO card_edition_finish (edition_id, finish) VALUES
  ('40000000-0000-0000-0000-000000000001', 'NONFOIL'),
  ('40000000-0000-0000-0000-000000000002', 'NONFOIL');

-- owner, friend, stranger
INSERT INTO account (id, email, display_name) VALUES
  ('50000000-0000-0000-0000-000000000001', 'rls-owner@example.com',    'RLS Owner'),
  ('50000000-0000-0000-0000-000000000002', 'rls-friend@example.com',   'RLS Friend'),
  ('50000000-0000-0000-0000-000000000003', 'rls-stranger@example.com', 'RLS Stranger');

INSERT INTO friendship (account_lo_id, account_hi_id)
VALUES ('50000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002');

-- Owner shares only the first game (4).
INSERT INTO game_share (account_id, game_id)
VALUES ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');

INSERT INTO location (id, account_id, kind, name) VALUES
  ('60000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001', 'physical', 'RLS Box A');
INSERT INTO location (id, account_id, kind, holder_account_id) VALUES
  ('60000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000001', 'holder',
   '50000000-0000-0000-0000-000000000002');

-- 3 of the shared card in the box, 1 out with the friend; 5 of the private card.
INSERT INTO holding (account_id, edition_id, finish, location_id, condition, qty) VALUES
  ('50000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001',
   'NONFOIL', '60000000-0000-0000-0000-000000000001', 'NM', 3),
  ('50000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001',
   'NONFOIL', '60000000-0000-0000-0000-000000000002', 'NM', 1),
  ('50000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000002',
   'NONFOIL', '60000000-0000-0000-0000-000000000001', 'NM', 5);

-- ---------------------------------------------------------------------------
-- As the FRIEND
-- ---------------------------------------------------------------------------

SET LOCAL ROLE app_user;
SELECT auth.act_as('50000000-0000-0000-0000-000000000002');

DO $$
DECLARE n bigint; total bigint; onloan bigint;
BEGIN
  -- (14) Can read holdings for the shared game.
  SELECT count(*) INTO n FROM holding
   WHERE account_id = '50000000-0000-0000-0000-000000000001'
     AND edition_id = '40000000-0000-0000-0000-000000000001';
  ASSERT n = 2, format('(14) friend should read 2 shared holdings, saw %s', n);

  -- (4) Cannot read holdings for the unshared game.
  SELECT count(*) INTO n FROM holding
   WHERE edition_id = '40000000-0000-0000-0000-000000000002';
  ASSERT n = 0, format('(4) friend must not read unshared-game holdings, saw %s', n);

  -- (14) Cannot read the owner's locations at all -- this is what hides both
  -- "Box A" and the fact that the holder is this friend.
  SELECT count(*) INTO n FROM location
   WHERE account_id = '50000000-0000-0000-0000-000000000001';
  ASSERT n = 0, format('(14) friend must not read owner locations, saw %s', n);

  -- (14) The aggregate must still report 4 total with 1 on loan.
  SELECT qty_total, qty_on_loan INTO total, onloan
    FROM friend_visible_holding
   WHERE account_id = '50000000-0000-0000-0000-000000000001'
     AND edition_id = '40000000-0000-0000-0000-000000000001';
  ASSERT total = 4, format('(14) friend should see qty_total 4, saw %s', total);
  ASSERT onloan = 1, format('(14) friend should see qty_on_loan 1, saw %s', onloan);

  RAISE NOTICE 'ok  (14) friend sees 4 total / 1 on loan, and zero locations';
END $$;

-- ---------------------------------------------------------------------------
-- As a STRANGER
-- ---------------------------------------------------------------------------

SELECT auth.act_as('50000000-0000-0000-0000-000000000003');

DO $$
DECLARE n bigint;
BEGIN
  SELECT count(*) INTO n FROM holding
   WHERE account_id = '50000000-0000-0000-0000-000000000001';
  ASSERT n = 0, format('(4) stranger must read no holdings, saw %s', n);

  SELECT count(*) INTO n FROM friend_visible_holding
   WHERE account_id = '50000000-0000-0000-0000-000000000001';
  ASSERT n = 0, format('(4) stranger must see nothing in the shared view, saw %s', n);

  SELECT count(*) INTO n FROM location;
  ASSERT n = 0, format('stranger must read no locations, saw %s', n);

  RAISE NOTICE 'ok  (4) stranger sees nothing at all';
END $$;

-- ---------------------------------------------------------------------------
-- As the OWNER
-- ---------------------------------------------------------------------------

SELECT auth.act_as('50000000-0000-0000-0000-000000000001');

DO $$
DECLARE n bigint;
BEGIN
  SELECT count(*) INTO n FROM holding WHERE account_id = '50000000-0000-0000-0000-000000000001';
  ASSERT n = 3, format('owner should read all 3 own holdings, saw %s', n);

  SELECT count(*) INTO n FROM location WHERE account_id = '50000000-0000-0000-0000-000000000001';
  ASSERT n = 2, format('owner should read own 2 locations, saw %s', n);

  RAISE NOTICE 'ok  owner reads their own inventory in full';
END $$;

RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'ALL RLS ASSERTIONS PASSED'; END $$;

ROLLBACK;
