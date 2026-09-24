-- Deck builder smoke test (issue #21): app_create_deck, app_rename_deck,
-- app_delete_deck, app_set_deck_card, deck_summary, and the RLS on deck /
-- deck_card, driven entirely through the RPCs as an unprivileged role.
--
--   psql -d fci -v ON_ERROR_STOP=1 -f db/tests/deck_smoke.sql
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
VALUES ('d0000000-0000-0000-0000-000000000001', 'deck-game', 'Deck Game');
INSERT INTO card_set (id, game_id, external_id, prefix, name)
VALUES ('d0000000-0000-0000-0000-000000000002', 'd0000000-0000-0000-0000-000000000001',
        'ds1', 'DS1', 'Deck Set');

-- A Level 0 champion, two printings of it (to prove the copy-limit pools by
-- card name across editions, not just within one edition).
INSERT INTO card (id, game_id, external_uuid, slug, name, attributes) VALUES
  ('d0000000-0000-0000-0000-000000000011', 'd0000000-0000-0000-0000-000000000001',
   'champ', 'the-champ', 'The Champ',
   '{"types":["CHAMPION"],"level":0,"cost_memory":0}'::jsonb);
INSERT INTO card_edition (id, card_id, set_id, external_uuid, slug, collector_number) VALUES
  ('d0000000-0000-0000-0000-000000000021', 'd0000000-0000-0000-0000-000000000011',
   'd0000000-0000-0000-0000-000000000002', 'champ-ed1', 'the-champ-1', '001'),
  ('d0000000-0000-0000-0000-000000000022', 'd0000000-0000-0000-0000-000000000011',
   'd0000000-0000-0000-0000-000000000002', 'champ-ed2', 'the-champ-2', '001a');
INSERT INTO card_edition_finish (edition_id, finish) VALUES
  ('d0000000-0000-0000-0000-000000000021', 'NONFOIL'),
  ('d0000000-0000-0000-0000-000000000022', 'NONFOIL');

-- A Regalia (material-eligible, not a champion).
INSERT INTO card (id, game_id, external_uuid, slug, name, attributes) VALUES
  ('d0000000-0000-0000-0000-000000000012', 'd0000000-0000-0000-0000-000000000001',
   'regalia', 'a-regalia', 'A Regalia', '{"types":["REGALIA","ITEM"],"cost_memory":1}'::jsonb);
INSERT INTO card_edition (id, card_id, set_id, external_uuid, slug, collector_number) VALUES
  ('d0000000-0000-0000-0000-000000000023', 'd0000000-0000-0000-0000-000000000012',
   'd0000000-0000-0000-0000-000000000002', 'regalia-ed1', 'a-regalia-1', '002');
INSERT INTO card_edition_finish (edition_id, finish) VALUES
  ('d0000000-0000-0000-0000-000000000023', 'NONFOIL');

-- A main-deck card, plentiful copies allowed.
INSERT INTO card (id, game_id, external_uuid, slug, name, attributes) VALUES
  ('d0000000-0000-0000-0000-000000000013', 'd0000000-0000-0000-0000-000000000001',
   'bolt', 'a-bolt', 'A Bolt', '{"types":["ACTION"],"cost_reserve":1}'::jsonb);
INSERT INTO card_edition (id, card_id, set_id, external_uuid, slug, collector_number) VALUES
  ('d0000000-0000-0000-0000-000000000024', 'd0000000-0000-0000-0000-000000000013',
   'd0000000-0000-0000-0000-000000000002', 'bolt-ed1', 'a-bolt-1', '003');
INSERT INTO card_edition_finish (edition_id, finish) VALUES
  ('d0000000-0000-0000-0000-000000000024', 'NONFOIL');

-- A card banned from Standard (limit 0), same shape as "Nameless Champion" in
-- the live catalog.
INSERT INTO card (id, game_id, external_uuid, slug, name, attributes) VALUES
  ('d0000000-0000-0000-0000-000000000014', 'd0000000-0000-0000-0000-000000000001',
   'banned', 'a-banned-card', 'A Banned Card',
   '{"types":["ACTION"],"cost_reserve":1,"legality":{"STANDARD":{"limit":0}}}'::jsonb);
INSERT INTO card_edition (id, card_id, set_id, external_uuid, slug, collector_number) VALUES
  ('d0000000-0000-0000-0000-000000000025', 'd0000000-0000-0000-0000-000000000014',
   'd0000000-0000-0000-0000-000000000002', 'banned-ed1', 'a-banned-card-1', '004');
INSERT INTO card_edition_finish (edition_id, finish) VALUES
  ('d0000000-0000-0000-0000-000000000025', 'NONFOIL');

INSERT INTO account (id, email, display_name) VALUES
  ('e0000000-0000-0000-0000-000000000001', 'deck-owner@example.com', 'Owner'),
  ('e0000000-0000-0000-0000-000000000002', 'deck-mike@example.com',  'Mike');

SET LOCAL ROLE app_user;
SELECT pg_temp.act_as('e0000000-0000-0000-0000-000000000001');

-- ---------------------------------------------------------------------------
-- Tables reject direct writes
-- ---------------------------------------------------------------------------

SELECT pg_temp.must_fail($$
  INSERT INTO deck (account_id, name) VALUES
    ('e0000000-0000-0000-0000-000000000001', 'Direct Insert')
$$, 'direct INSERT into deck');

-- ---------------------------------------------------------------------------
-- Create + basic ownership
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_deck uuid;
BEGIN
  v_deck := app_create_deck('My Fire Deck');
  PERFORM set_config('pg_temp.deck', v_deck::text, false);
END $$;

SELECT pg_temp.must_fail($$SELECT app_create_deck('')$$, 'empty deck name');

-- Mike cannot see or touch Owner's deck.
SELECT pg_temp.act_as('e0000000-0000-0000-0000-000000000002');
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM deck WHERE id = current_setting('pg_temp.deck')::uuid) = 0,
    '(RLS) a stranger must not see this deck';
  RAISE NOTICE 'ok  (blocked) stranger cannot read the deck';
END $$;
SELECT pg_temp.must_fail(
  format($$SELECT app_rename_deck('%s'::uuid, 'Stolen')$$, current_setting('pg_temp.deck')),
  'stranger renaming a deck they do not own');
SELECT pg_temp.must_fail(
  format($$SELECT app_delete_deck('%s'::uuid)$$, current_setting('pg_temp.deck')),
  'stranger deleting a deck they do not own');
SELECT pg_temp.act_as('e0000000-0000-0000-0000-000000000001');

-- ---------------------------------------------------------------------------
-- Material deck: 1-copy limit, pooled across editions of the same card
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_deck uuid := current_setting('pg_temp.deck')::uuid;
BEGIN
  PERFORM app_set_deck_card(v_deck, 'd0000000-0000-0000-0000-000000000021',
                             'material', 'NONFOIL', 1);
END $$;

-- A second copy of the SAME card name via a DIFFERENT edition must still hit
-- the 1-copy material limit -- this is the whole reason the pool sums by
-- card_id, not edition_id.
SELECT pg_temp.must_fail(
  format($$SELECT app_set_deck_card('%s'::uuid, 'd0000000-0000-0000-0000-000000000022'::uuid,
                                     'material', 'NONFOIL', 1)$$, current_setting('pg_temp.deck')),
  '2nd material copy of the same card name (different printing)');

-- A main-deck-type card cannot go in the material section.
SELECT pg_temp.must_fail(
  format($$SELECT app_set_deck_card('%s'::uuid, 'd0000000-0000-0000-0000-000000000024'::uuid,
                                     'material', 'NONFOIL', 1)$$, current_setting('pg_temp.deck')),
  'main-deck card placed in material section');

-- ---------------------------------------------------------------------------
-- Main deck: 4-copy limit
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_deck uuid := current_setting('pg_temp.deck')::uuid;
BEGIN
  PERFORM app_set_deck_card(v_deck, 'd0000000-0000-0000-0000-000000000024',
                             'main', 'NONFOIL', 4);
END $$;

SELECT pg_temp.must_fail(
  format($$SELECT app_set_deck_card('%s'::uuid, 'd0000000-0000-0000-0000-000000000024'::uuid,
                                     'main', 'FOIL', 1)$$, current_setting('pg_temp.deck')),
  '5th copy of a card across finishes in the main deck');

-- A material-type card cannot go in the main section.
SELECT pg_temp.must_fail(
  format($$SELECT app_set_deck_card('%s'::uuid, 'd0000000-0000-0000-0000-000000000021'::uuid,
                                     'main', 'NONFOIL', 1)$$, current_setting('pg_temp.deck')),
  'material card placed in main section');

-- ---------------------------------------------------------------------------
-- A banned card (legality.STANDARD.limit = 0) is rejected outright
-- ---------------------------------------------------------------------------

SELECT pg_temp.must_fail(
  format($$SELECT app_set_deck_card('%s'::uuid, 'd0000000-0000-0000-0000-000000000025'::uuid,
                                     'main', 'NONFOIL', 1)$$, current_setting('pg_temp.deck')),
  'a card banned from Standard');

-- ---------------------------------------------------------------------------
-- Sideboard: shares the copy-limit pool, plus its own 15-card / 15-point caps
-- ---------------------------------------------------------------------------

-- Already 4 copies of "A Bolt" in main -- a 5th in the sideboard must also
-- be rejected, because the sideboard pools with main for non-material cards.
SELECT pg_temp.must_fail(
  format($$SELECT app_set_deck_card('%s'::uuid, 'd0000000-0000-0000-0000-000000000024'::uuid,
                                     'sideboard', 'NONFOIL', 1)$$, current_setting('pg_temp.deck')),
  '5th copy of a main card, this time via the sideboard');

-- Already 1 copy of "The Champ" in material -- a Regalia is a different card
-- name, so it is unaffected, but the champ itself cannot go in the sideboard
-- too without exceeding its own 1-copy pool.
SELECT pg_temp.must_fail(
  format($$SELECT app_set_deck_card('%s'::uuid, 'd0000000-0000-0000-0000-000000000021'::uuid,
                                     'sideboard', 'NONFOIL', 1)$$, current_setting('pg_temp.deck')),
  'champion already at its 1-copy limit, added to sideboard too');

-- A Regalia is a fresh card name (its own 1-copy pool, separate from the
-- champion's), but it is STILL material-type, so 4 copies in the sideboard
-- must hit that same 1-copy cap even though the sideboard's own 15-card /
-- 15-point ceiling would have allowed it.
SELECT pg_temp.must_fail(
  format($$SELECT app_set_deck_card('%s'::uuid, 'd0000000-0000-0000-0000-000000000023'::uuid,
                                     'sideboard', 'NONFOIL', 4)$$, current_setting('pg_temp.deck')),
  '4 copies of a 1-copy-limit Regalia in the sideboard');

-- One copy fits, and costs 3 of the sideboard's 15 points.
DO $$
DECLARE v_deck uuid := current_setting('pg_temp.deck')::uuid;
BEGIN
  PERFORM app_set_deck_card(v_deck, 'd0000000-0000-0000-0000-000000000023',
                             'sideboard', 'NONFOIL', 1);
END $$;

-- ---------------------------------------------------------------------------
-- qty = 0 always succeeds, even though it never re-checks any limit
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_deck uuid := current_setting('pg_temp.deck')::uuid;
BEGIN
  PERFORM app_set_deck_card(v_deck, 'd0000000-0000-0000-0000-000000000023',
                             'sideboard', 'NONFOIL', 0);
  ASSERT NOT EXISTS (
    SELECT 1 FROM deck_card
     WHERE deck_id = v_deck AND edition_id = 'd0000000-0000-0000-0000-000000000023'
       AND section = 'sideboard' AND finish = 'NONFOIL'
  ), 'qty = 0 must delete the row';
  RAISE NOTICE 'ok  qty = 0 deletes the deck_card row';
END $$;

-- ---------------------------------------------------------------------------
-- deck_summary: a display fact, never a gate. Main deck has 4 cards (well
-- under the 60 minimum) and does have a Level 0 champion -- so is_legal must
-- be false purely on the count, and the champion flag must still read true.
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_deck uuid := current_setting('pg_temp.deck')::uuid;
  r record;
BEGIN
  SELECT * INTO r FROM deck_summary(v_deck);

  ASSERT r.material_count = 1, format('material_count should be 1, got %s', r.material_count);
  ASSERT r.main_count = 4, format('main_count should be 4, got %s', r.main_count);
  ASSERT r.has_level0_champion, 'the deck has a Level 0 champion in material';
  ASSERT NOT r.is_legal, 'main deck has only 4 of 60 required cards -- must not read legal';

  RAISE NOTICE 'ok  deck_summary: material=% main=% champion=% legal=%',
    r.material_count, r.main_count, r.has_level0_champion, r.is_legal;
END $$;

-- Mike's deck_summary for Owner's deck ID must come back empty/zeroed, not
-- leak Owner's card counts -- deck_summary has no SECURITY DEFINER, so this
-- is just RLS on deck/deck_card doing its job.
SELECT pg_temp.act_as('e0000000-0000-0000-0000-000000000002');
DO $$
DECLARE
  v_deck uuid := current_setting('pg_temp.deck')::uuid;
  r record;
BEGIN
  SELECT * INTO r FROM deck_summary(v_deck);
  ASSERT r.main_count = 0, 'a stranger must not see this deck''s card counts';
  RAISE NOTICE 'ok  (blocked) stranger''s deck_summary of Owner''s deck is empty';
END $$;
SELECT pg_temp.act_as('e0000000-0000-0000-0000-000000000001');

-- ---------------------------------------------------------------------------
-- Cover art (#32): any printing of a card in the deck, or NULL
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_deck uuid := current_setting('pg_temp.deck')::uuid;
  v_before timestamptz;
BEGIN
  SELECT updated_at INTO v_before FROM deck WHERE id = v_deck;

  -- Both printings of The Champ qualify, whichever one the deck holds.
  PERFORM app_set_deck_cover(v_deck, 'd0000000-0000-0000-0000-000000000021');
  PERFORM app_set_deck_cover(v_deck, 'd0000000-0000-0000-0000-000000000022');
  ASSERT (SELECT cover_edition_id FROM deck WHERE id = v_deck)
         = 'd0000000-0000-0000-0000-000000000022',
    '(32) any printing of a card in the deck should be accepted as the cover';
  ASSERT (SELECT updated_at FROM deck WHERE id = v_deck) = v_before,
    '(32) choosing a cover must not bump updated_at (it reorders /decks)';
  RAISE NOTICE 'ok  (32) cover can be any printing of a card in the deck';

  PERFORM app_set_deck_cover(v_deck, NULL);
  ASSERT (SELECT cover_edition_id FROM deck WHERE id = v_deck) IS NULL,
    '(32) NULL should clear the cover';
  RAISE NOTICE 'ok  (32) a NULL cover clears it';
END $$;

-- The banned card was rejected from the deck earlier, so it is not in it.
SELECT pg_temp.must_fail(
  format($$SELECT app_set_deck_cover('%s'::uuid, 'd0000000-0000-0000-0000-000000000025'::uuid)$$,
         current_setting('pg_temp.deck')),
  '(32) a cover from a card that is not in the deck');

SELECT pg_temp.act_as('e0000000-0000-0000-0000-000000000002');
SELECT pg_temp.must_fail(
  format($$SELECT app_set_deck_cover('%s'::uuid, NULL)$$, current_setting('pg_temp.deck')),
  '(32) stranger setting the cover of a deck they do not own');
SELECT pg_temp.act_as('e0000000-0000-0000-0000-000000000001');

-- ---------------------------------------------------------------------------
-- Rename + delete
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_deck uuid := current_setting('pg_temp.deck')::uuid;
BEGIN
  PERFORM app_rename_deck(v_deck, 'Renamed Deck');
  ASSERT (SELECT name FROM deck WHERE id = v_deck) = 'Renamed Deck', 'rename must take effect';
  RAISE NOTICE 'ok  app_rename_deck';

  PERFORM app_delete_deck(v_deck);
  ASSERT NOT EXISTS (SELECT 1 FROM deck WHERE id = v_deck), 'delete must take effect';
  ASSERT NOT EXISTS (SELECT 1 FROM deck_card WHERE deck_id = v_deck),
    'deleting a deck must cascade to its deck_card rows';
  RAISE NOTICE 'ok  app_delete_deck cascades to deck_card';
END $$;

RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'ALL DECK ASSERTIONS PASSED'; END $$;

ROLLBACK;
