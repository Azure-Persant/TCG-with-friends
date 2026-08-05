-- Smoke test for db/schema.sql.
--
-- Walks a full loan lifecycle and asserts that the constraints actually
-- enforce the decisions in docs/design/friends-and-loans.md, rather than the
-- schema merely looking correct.
--
--   psql -d fci -v ON_ERROR_STOP=1 -f db/tests/schema_smoke.sql
--
-- Runs in a transaction and rolls back. Safe against a populated database.

BEGIN;
SET client_min_messages = notice;

-- Helper: assert that a statement fails, and fail loudly if it succeeds.
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

-- ---------------------------------------------------------------------------
-- Catalog fixtures
-- ---------------------------------------------------------------------------

INSERT INTO game (id, slug, name)
VALUES ('11111111-1111-1111-1111-111111111111', 'grand-archive', 'Grand Archive');

INSERT INTO card_set (id, game_id, external_id, prefix, name, release_date)
VALUES ('22222222-2222-2222-2222-222222222222',
        '11111111-1111-1111-1111-111111111111',
        '67uvnnrprp', 'HVN', 'Abyssal Heaven', '2025-03-07');

INSERT INTO card (id, game_id, external_uuid, slug, name, attributes)
VALUES ('33333333-3333-3333-3333-333333333333',
        '11111111-1111-1111-1111-111111111111',
        'card-uuid-1', 'arcane-blast', 'Arcane Blast',
        '{"classes":["MAGE"],"cost_reserve":11}');

-- Two printings of the same card: this is the case decision 21 exists for.
INSERT INTO card_edition (id, card_id, set_id, external_uuid, slug, collector_number)
VALUES ('44444444-4444-4444-4444-444444444444',
        '33333333-3333-3333-3333-333333333333',
        '22222222-2222-2222-2222-222222222222',
        'oydcc8dbgf', 'arcane-blast-hvn', '184'),
       ('55555555-5555-5555-5555-555555555555',
        '33333333-3333-3333-3333-333333333333',
        '22222222-2222-2222-2222-222222222222',
        'cddabb5ax4', 'arcane-blast-rec-hvf', '184b');

-- Edition 1 exists in both finishes; edition 2 is nonfoil only.
INSERT INTO card_edition_finish (edition_id, finish, label, population) VALUES
  ('44444444-4444-4444-4444-444444444444', 'NONFOIL', 'HVN Common',      115000),
  ('44444444-4444-4444-4444-444444444444', 'FOIL',    'HVN Common Foil',   1770),
  ('55555555-5555-5555-5555-555555555555', 'NONFOIL', 'HVN ReC x3',       54000);

-- ---------------------------------------------------------------------------
-- Accounts, friendship, sharing
-- ---------------------------------------------------------------------------

INSERT INTO account (id, email, display_name) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', 'owner@example.com',  'Owner'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'sarah@example.com',  'Sarah'),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'mike@example.com',   'Mike');

INSERT INTO friendship (account_lo_id, account_hi_id, status, requested_by_id, responded_at)
VALUES ('aaaaaaaa-0000-0000-0000-000000000001',
        'aaaaaaaa-0000-0000-0000-000000000002',
        'accepted', 'aaaaaaaa-0000-0000-0000-000000000001', now());

-- (1) Friendship is one row, canonically ordered — the reverse pair cannot exist.
SELECT pg_temp.must_fail($$
  INSERT INTO friendship (account_lo_id, account_hi_id, requested_by_id)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000002',
          'aaaaaaaa-0000-0000-0000-000000000001',
          'aaaaaaaa-0000-0000-0000-000000000002')
$$, '(1) reversed duplicate friendship');

-- (1) A pending friendship may not carry a response timestamp.
SELECT pg_temp.must_fail($$
  INSERT INTO friendship (account_lo_id, account_hi_id, requested_by_id, responded_at)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000001',
          'aaaaaaaa-0000-0000-0000-000000000003',
          'aaaaaaaa-0000-0000-0000-000000000001', now())
$$, '(1) pending friendship with responded_at');

-- (4) Owner shares Grand Archive with all friends.
INSERT INTO game_share (account_id, game_id)
VALUES ('aaaaaaaa-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111');

-- ---------------------------------------------------------------------------
-- Locations
-- ---------------------------------------------------------------------------

INSERT INTO location (id, account_id, kind, name) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'physical', 'Box A'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001', 'physical', 'Box B'),
  ('bbbbbbbb-0000-0000-0000-000000000009', 'aaaaaaaa-0000-0000-0000-000000000002', 'physical', 'Sarah Shelf');

-- Holder locations: one linked to an account, one a bare name (3).
INSERT INTO location (id, account_id, kind, holder_account_id) VALUES
  ('cccccccc-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'holder',
   'aaaaaaaa-0000-0000-0000-000000000002');
INSERT INTO location (id, account_id, kind, name) VALUES
  ('cccccccc-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001', 'holder',
   'Mike from work');

-- A holder is exactly one of account-linked or bare name, never both.
SELECT pg_temp.must_fail($$
  INSERT INTO location (account_id, kind, name, holder_account_id)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000001', 'holder', 'Both',
          'aaaaaaaa-0000-0000-0000-000000000003')
$$, 'holder location with both a name and an account');

-- A physical location cannot point at a person.
SELECT pg_temp.must_fail($$
  INSERT INTO location (account_id, kind, name, holder_account_id)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000001', 'physical', 'Box C',
          'aaaaaaaa-0000-0000-0000-000000000002')
$$, 'physical location with a holder account');

-- One holder bucket per person per owner.
SELECT pg_temp.must_fail($$
  INSERT INTO location (account_id, kind, holder_account_id)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000001', 'holder',
          'aaaaaaaa-0000-0000-0000-000000000002')
$$, 'duplicate holder location for the same person');

SELECT pg_temp.must_fail($$
  INSERT INTO location (account_id, kind, holder_account_id)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000001', 'holder',
          'aaaaaaaa-0000-0000-0000-000000000001')
$$, 'holder location pointing at yourself');

-- ---------------------------------------------------------------------------
-- Holdings — the worked example from decision 8
-- ---------------------------------------------------------------------------

INSERT INTO holding (account_id, edition_id, finish, location_id, condition, qty) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444',
   'NONFOIL', 'bbbbbbbb-0000-0000-0000-000000000001', 'NM', 3),
  ('aaaaaaaa-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444',
   'NONFOIL', 'bbbbbbbb-0000-0000-0000-000000000002', 'NM', 1),
  -- Same card, same box, different finish: a separate bucket (21).
  ('aaaaaaaa-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444',
   'FOIL',    'bbbbbbbb-0000-0000-0000-000000000001', 'NM', 1);

-- (21) A finish the printing was never issued in is unrecordable.
SELECT pg_temp.must_fail($$
  INSERT INTO holding (account_id, edition_id, finish, location_id, condition, qty)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000001', '55555555-5555-5555-5555-555555555555',
          'FOIL', 'bbbbbbbb-0000-0000-0000-000000000001', 'NM', 1)
$$, '(21) holding in a finish that printing does not exist in');

-- (8) Empty buckets are deleted, never stored as zero.
SELECT pg_temp.must_fail($$
  INSERT INTO holding (account_id, edition_id, finish, location_id, condition, qty)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000001', '55555555-5555-5555-5555-555555555555',
          'NONFOIL', 'bbbbbbbb-0000-0000-0000-000000000002', 'NM', 0)
$$, '(8) holding with qty 0');

-- You cannot file your cards into somebody else's location.
SELECT pg_temp.must_fail($$
  INSERT INTO holding (account_id, edition_id, finish, location_id, condition, qty)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000001', '55555555-5555-5555-5555-555555555555',
          'NONFOIL', 'bbbbbbbb-0000-0000-0000-000000000009', 'NM', 1)
$$, 'holding filed into another account''s location');

-- The bucket key is unique: same card+finish+location+condition cannot repeat.
SELECT pg_temp.must_fail($$
  INSERT INTO holding (account_id, edition_id, finish, location_id, condition, qty)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444',
          'NONFOIL', 'bbbbbbbb-0000-0000-0000-000000000001', 'NM', 1)
$$, '(8) duplicate bucket key');

-- ---------------------------------------------------------------------------
-- Loan lifecycle (2, 6, 10, 11, 13)
-- ---------------------------------------------------------------------------

INSERT INTO loan (id, lender_account_id, initial_holder_location_id, status)
VALUES ('dddddddd-0000-0000-0000-000000000001',
        'aaaaaaaa-0000-0000-0000-000000000001',
        'cccccccc-0000-0000-0000-000000000001', 'pending');

-- Two physical cards handed over together = two lines (11, 13).
INSERT INTO loan_line (id, loan_id, edition_id, finish, origin_location_id,
                       departure_condition, holder_location_id)
VALUES ('eeeeeeee-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000001',
        '44444444-4444-4444-4444-444444444444', 'NONFOIL',
        'bbbbbbbb-0000-0000-0000-000000000001', 'NM',
        'cccccccc-0000-0000-0000-000000000001'),
       ('eeeeeeee-0000-0000-0000-000000000002', 'dddddddd-0000-0000-0000-000000000001',
        '44444444-4444-4444-4444-444444444444', 'NONFOIL',
        'bbbbbbbb-0000-0000-0000-000000000001', 'NM',
        'cccccccc-0000-0000-0000-000000000001');

-- Borrower accepts (2); the quantity physically moves (10).
UPDATE loan SET status = 'active', accepted_at = now()
 WHERE id = 'dddddddd-0000-0000-0000-000000000001';

UPDATE holding SET qty = qty - 2
 WHERE account_id = 'aaaaaaaa-0000-0000-0000-000000000001'
   AND edition_id = '44444444-4444-4444-4444-444444444444'
   AND finish = 'NONFOIL'
   AND location_id = 'bbbbbbbb-0000-0000-0000-000000000001'
   AND condition = 'NM';

INSERT INTO holding (account_id, edition_id, finish, location_id, condition, qty)
VALUES ('aaaaaaaa-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444',
        'NONFOIL', 'cccccccc-0000-0000-0000-000000000001', 'NM', 2);

-- (7) The borrower files the card she is holding into her own location.
INSERT INTO loan_line_placement (loan_line_id, account_id, location_id)
VALUES ('eeeeeeee-0000-0000-0000-000000000001',
        'aaaaaaaa-0000-0000-0000-000000000002',
        'bbbbbbbb-0000-0000-0000-000000000009');

-- (7) ...but only into a location she owns.
SELECT pg_temp.must_fail($$
  INSERT INTO loan_line_placement (loan_line_id, account_id, location_id)
  VALUES ('eeeeeeee-0000-0000-0000-000000000002',
          'aaaaaaaa-0000-0000-0000-000000000002',
          'bbbbbbbb-0000-0000-0000-000000000001')
$$, '(7) borrower placing a card into the lender''s box');

-- (14) A friend sees 4 total with 2 on loan, and no location anywhere.
DO $$
DECLARE t bigint; l bigint; cols int;
BEGIN
  SELECT qty_total, qty_on_loan INTO t, l
    FROM friend_visible_holding
   WHERE account_id = 'aaaaaaaa-0000-0000-0000-000000000001'
     AND edition_id = '44444444-4444-4444-4444-444444444444'
     AND finish = 'NONFOIL' AND condition = 'NM';
  ASSERT t = 4, format('(14) expected qty_total 4, got %s', t);
  ASSERT l = 2, format('(14) expected qty_on_loan 2, got %s', l);

  SELECT count(*) INTO cols FROM information_schema.columns
   WHERE table_name = 'friend_visible_holding' AND column_name ILIKE '%location%';
  ASSERT cols = 0, '(14) friend-visible view must expose no location column';
  RAISE NOTICE 'ok  (14) friend sees 4 total / 2 on loan, no locations';
END $$;

-- (5) The unfriend block has something to trip on.
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM open_custody
   WHERE lender_account_id = 'aaaaaaaa-0000-0000-0000-000000000001'
     AND holder_account_id = 'aaaaaaaa-0000-0000-0000-000000000002';
  ASSERT n = 2, format('(5) expected 2 open custody rows, got %s', n);
  RAISE NOTICE 'ok  (5) open_custody blocks the unfriend while 2 cards are out';
END $$;

-- ---------------------------------------------------------------------------
-- Sub-loan: Sarah passes one card to Mike, owner approves (18, 19, 20)
-- ---------------------------------------------------------------------------

INSERT INTO loan_transfer (id, loan_line_id, from_location_id, to_location_id,
                           initiated_by_account_id)
VALUES ('ffffffff-0000-0000-0000-000000000001',
        'eeeeeeee-0000-0000-0000-000000000001',
        'cccccccc-0000-0000-0000-000000000001',
        'cccccccc-0000-0000-0000-000000000002',
        'aaaaaaaa-0000-0000-0000-000000000002');

-- Only one transfer may be in flight per card.
SELECT pg_temp.must_fail($$
  INSERT INTO loan_transfer (loan_line_id, from_location_id, to_location_id,
                             initiated_by_account_id)
  VALUES ('eeeeeeee-0000-0000-0000-000000000001',
          'cccccccc-0000-0000-0000-000000000001',
          'cccccccc-0000-0000-0000-000000000002',
          'aaaaaaaa-0000-0000-0000-000000000002')
$$, '(18) second pending transfer for the same card');

-- A transfer cannot be approved without the owner's approval (18).
SELECT pg_temp.must_fail($$
  UPDATE loan_transfer SET status = 'approved', resolved_at = now()
   WHERE id = 'ffffffff-0000-0000-0000-000000000001'
$$, '(18) transfer approved without owner_approved_at');

-- Owner approves: custody moves, previous holder is released (19).
UPDATE loan_transfer
   SET status = 'approved', owner_approved_at = now(),
       recipient_accepted_at = NULL, resolved_at = now()
 WHERE id = 'ffffffff-0000-0000-0000-000000000001';

UPDATE loan_line SET holder_location_id = 'cccccccc-0000-0000-0000-000000000002'
 WHERE id = 'eeeeeeee-0000-0000-0000-000000000001';

UPDATE holding SET qty = qty - 1
 WHERE location_id = 'cccccccc-0000-0000-0000-000000000001';
INSERT INTO holding (account_id, edition_id, finish, location_id, condition, qty)
VALUES ('aaaaaaaa-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444',
        'NONFOIL', 'cccccccc-0000-0000-0000-000000000002', 'NM', 1);

DO $$
DECLARE holders int; total bigint; onloan bigint;
BEGIN
  SELECT count(DISTINCT holder_location_id) INTO holders FROM open_custody
   WHERE lender_account_id = 'aaaaaaaa-0000-0000-0000-000000000001';
  ASSERT holders = 2, format('(19) expected 2 distinct holders, got %s', holders);

  -- The privacy guarantee survives the transfer: still 4 total, 2 out.
  SELECT qty_total, qty_on_loan INTO total, onloan FROM friend_visible_holding
   WHERE account_id = 'aaaaaaaa-0000-0000-0000-000000000001'
     AND edition_id = '44444444-4444-4444-4444-444444444444'
     AND finish = 'NONFOIL' AND condition = 'NM';
  ASSERT total = 4 AND onloan = 2,
    format('(14) after transfer expected 4/2, got %s/%s', total, onloan);
  RAISE NOTICE 'ok  (19) custody split across 2 holders, totals unchanged';
END $$;

-- ---------------------------------------------------------------------------
-- Return with a condition downgrade (6, 13)
-- ---------------------------------------------------------------------------

UPDATE loan_line SET status = 'in_transit', sent_at = now()
 WHERE id = 'eeeeeeee-0000-0000-0000-000000000002';

-- A closed line must record why it closed.
SELECT pg_temp.must_fail($$
  UPDATE loan_line SET status = 'returned', closed_at = now()
   WHERE id = 'eeeeeeee-0000-0000-0000-000000000002'
$$, '(6) line closed without a close_reason');

-- A confirmed return must say what came back and where it went.
SELECT pg_temp.must_fail($$
  UPDATE loan_line
     SET status = 'returned', closed_at = now(), close_reason = 'returned_confirmed'
   WHERE id = 'eeeeeeee-0000-0000-0000-000000000002'
$$, '(13) confirmed return without received_condition');

-- Lender confirms receipt and downgrades NM -> LP (13).
UPDATE loan_line
   SET status = 'returned', received_at = now(), received_condition = 'LP',
       return_location_id = 'bbbbbbbb-0000-0000-0000-000000000001',
       close_reason = 'returned_confirmed', closed_at = now()
 WHERE id = 'eeeeeeee-0000-0000-0000-000000000002';

-- Sarah's holder bucket held exactly this one card, so it empties. Buckets are
-- deleted rather than zeroed (8) — qty > 0 is enforced, so decrementing to 0
-- is rejected outright and the caller must delete instead.
DELETE FROM holding
 WHERE account_id = 'aaaaaaaa-0000-0000-0000-000000000001'
   AND location_id = 'cccccccc-0000-0000-0000-000000000001';

-- It files into the LP bucket, not the NM one it left (8, 13).
INSERT INTO holding (account_id, edition_id, finish, location_id, condition, qty)
VALUES ('aaaaaaaa-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444',
        'NONFOIL', 'bbbbbbbb-0000-0000-0000-000000000001', 'LP', 1);

-- A write-off must not claim the card was received.
SELECT pg_temp.must_fail($$
  UPDATE loan_line
     SET status = 'written_off', closed_at = now(),
         close_reason = 'force_closed_written_off',
         received_at = now(),
         return_location_id = 'bbbbbbbb-0000-0000-0000-000000000001'
   WHERE id = 'eeeeeeee-0000-0000-0000-000000000001'
$$, '(15) write-off claiming the card was received');

-- (15) Force-close acts on one line, leaving the other untouched.
UPDATE loan_line
   SET status = 'written_off', closed_at = now(),
       close_reason = 'force_closed_written_off'
 WHERE id = 'eeeeeeee-0000-0000-0000-000000000001';

DO $$
DECLARE dmg card_condition; n int;
BEGIN
  SELECT condition INTO dmg FROM holding
   WHERE location_id = 'bbbbbbbb-0000-0000-0000-000000000001'
     AND condition = 'LP';
  ASSERT dmg = 'LP', '(13) downgraded card must land in the LP bucket';

  SELECT count(*) INTO n FROM open_custody
   WHERE lender_account_id = 'aaaaaaaa-0000-0000-0000-000000000001';
  ASSERT n = 0, format('(5) expected 0 open custody rows after settling, got %s', n);
  RAISE NOTICE 'ok  (13) downgrade filed to LP; (5) unfriend now unblocked';
END $$;

DO $$ BEGIN RAISE NOTICE 'ALL ASSERTIONS PASSED'; END $$;

ROLLBACK;
