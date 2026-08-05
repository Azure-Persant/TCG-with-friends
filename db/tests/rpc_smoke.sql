-- RPC smoke test for db/functions.sql.
--
-- Drives a complete loan lifecycle entirely through the mutation functions,
-- as an unprivileged role, and asserts that the nine application invariants
-- actually hold. Also proves the tables reject direct writes, which is what
-- makes the functions authoritative rather than merely convenient.
--
--   psql -d fci -v ON_ERROR_STOP=1 -f db/tests/rpc_smoke.sql
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
BEGIN PERFORM set_config('app.current_user_id', who::text, true); END $$;

/**
 * Quantity in one bucket, 0 if the bucket has been deleted.
 *
 * Finish is part of the key (21), so it must be specified -- location plus
 * condition alone can match two buckets. Defaults to NONFOIL, which is what
 * most assertions below are about.
 */
CREATE OR REPLACE FUNCTION pg_temp.qty_at(
  loc uuid, cond card_condition, fin card_finish DEFAULT 'NONFOIL'
) RETURNS integer LANGUAGE sql STABLE AS $$
  SELECT coalesce((SELECT qty FROM holding
                    WHERE location_id = loc AND condition = cond AND finish = fin), 0);
$$;

-- ---------------------------------------------------------------------------
-- Fixtures (as owner; RLS bypassed)
-- ---------------------------------------------------------------------------

INSERT INTO game (id, slug, name)
VALUES ('a0000000-0000-0000-0000-000000000001', 'rpc-game', 'RPC Game');
INSERT INTO card_set (id, game_id, external_id, prefix, name)
VALUES ('a0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001',
        'rs1', 'RS1', 'RPC Set');
INSERT INTO card (id, game_id, external_uuid, slug, name)
VALUES ('a0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001',
        'rpcc1', 'rpc-card', 'RPC Card');
INSERT INTO card_edition (id, card_id, set_id, external_uuid, slug, collector_number)
VALUES ('a0000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000003',
        'a0000000-0000-0000-0000-000000000002', 'rpce1', 'rpc-ed', '1');
INSERT INTO card_edition_finish (edition_id, finish) VALUES
  ('a0000000-0000-0000-0000-000000000004', 'NONFOIL'),
  ('a0000000-0000-0000-0000-000000000004', 'FOIL');

-- Owner, Sarah (friend), Mike (NOT a friend of Owner -- see decision 20)
INSERT INTO account (id, email, display_name) VALUES
  ('b0000000-0000-0000-0000-000000000001', 'rpc-owner@example.com', 'Owner'),
  ('b0000000-0000-0000-0000-000000000002', 'rpc-sarah@example.com', 'Sarah'),
  ('b0000000-0000-0000-0000-000000000003', 'rpc-mike@example.com',  'Mike');

INSERT INTO friendship (account_lo_id, account_hi_id)
VALUES (least('b0000000-0000-0000-0000-000000000001'::uuid, 'b0000000-0000-0000-0000-000000000002'::uuid),
        greatest('b0000000-0000-0000-0000-000000000001'::uuid, 'b0000000-0000-0000-0000-000000000002'::uuid));

INSERT INTO location (id, account_id, kind, name) VALUES
  ('c0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', 'physical', 'Box A'),
  ('c0000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000001', 'physical', 'Box B'),
  ('c0000000-0000-0000-0000-000000000009', 'b0000000-0000-0000-0000-000000000002', 'physical', 'Sarah Shelf');

SET LOCAL ROLE app_user;
SELECT pg_temp.act_as('b0000000-0000-0000-0000-000000000001');

-- ---------------------------------------------------------------------------
-- Tables reject direct writes (this is what makes the RPCs authoritative)
-- ---------------------------------------------------------------------------

SELECT pg_temp.must_fail($$
  INSERT INTO holding (account_id, edition_id, finish, location_id, condition, qty)
  VALUES ('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000004',
          'NONFOIL', 'c0000000-0000-0000-0000-000000000001', 'NM', 99)
$$, 'direct INSERT into holding');

SELECT pg_temp.must_fail($$
  INSERT INTO location (account_id, kind, holder_account_id)
  VALUES ('b0000000-0000-0000-0000-000000000001', 'holder',
          'b0000000-0000-0000-0000-000000000003')
$$, 'hand-made holder location');

-- Note the different assertion shape. RLS refuses a DELETE by matching zero
-- rows, not by raising -- so the statement "succeeds" while deleting nothing.
-- Checking for an exception here would pass for the wrong reason; check that
-- the row survived instead.
DELETE FROM friendship;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM friendship) = 1,
    '(5) direct DELETE must not remove a friendship -- app_unfriend is the only way out';
  RAISE NOTICE 'ok  (blocked) direct DELETE of a friendship removed nothing';
END $$;

-- ---------------------------------------------------------------------------
-- Inventory
-- ---------------------------------------------------------------------------

SELECT app_add_cards('a0000000-0000-0000-0000-000000000004', 'NONFOIL',
                     'c0000000-0000-0000-0000-000000000001', 'NM', 3);
SELECT app_add_cards('a0000000-0000-0000-0000-000000000004', 'FOIL',
                     'c0000000-0000-0000-0000-000000000001', 'NM', 1);
SELECT app_move_cards('a0000000-0000-0000-0000-000000000004', 'NONFOIL',
                      'c0000000-0000-0000-0000-000000000001',
                      'c0000000-0000-0000-0000-000000000002', 'NM', 1);

DO $$ BEGIN
  -- Box A: 2 NONFOIL NM + 1 FOIL NM. Two buckets, three cards.
  ASSERT (SELECT sum(qty) FROM holding
           WHERE location_id = 'c0000000-0000-0000-0000-000000000001') = 3,
         'Box A should hold 3 cards across two finish buckets';
  ASSERT (SELECT count(*) FROM holding
           WHERE location_id = 'c0000000-0000-0000-0000-000000000001') = 2,
         '(21) finish must split Box A into two buckets';
  RAISE NOTICE 'ok  add/move; (21) foil and nonfoil are separate buckets';
END $$;

SELECT pg_temp.must_fail($$
  SELECT app_move_cards('a0000000-0000-0000-0000-000000000004', 'NONFOIL',
                        'c0000000-0000-0000-0000-000000000001',
                        'c0000000-0000-0000-0000-000000000002', 'NM', 99)
$$, 'moving more cards than the bucket holds');

SELECT pg_temp.must_fail($$
  SELECT app_add_cards('a0000000-0000-0000-0000-000000000004', 'NONFOIL',
                       'c0000000-0000-0000-0000-000000000009', 'NM', 1)
$$, 'adding cards to someone else''s location');

-- ---------------------------------------------------------------------------
-- (a) Lending requires an accepted friendship
-- ---------------------------------------------------------------------------

SELECT pg_temp.must_fail($$
  SELECT app_offer_loan(
    '[{"edition_id":"a0000000-0000-0000-0000-000000000004","finish":"NONFOIL",
       "origin_location_id":"c0000000-0000-0000-0000-000000000001",
       "condition":"NM","qty":1}]'::jsonb,
    'b0000000-0000-0000-0000-000000000003')
$$, '(1) lending to a non-friend');

-- ---------------------------------------------------------------------------
-- (b, j) An unaccepted loan is a request, and has no loan row at all
-- ---------------------------------------------------------------------------

CREATE TEMP TABLE t AS
SELECT app_offer_loan(
  '[{"edition_id":"a0000000-0000-0000-0000-000000000004","finish":"NONFOIL",
     "origin_location_id":"c0000000-0000-0000-0000-000000000001",
     "condition":"NM","qty":2}]'::jsonb,
  'b0000000-0000-0000-0000-000000000002') AS request_id;

DO $$
DECLARE v_req uuid; n int;
BEGIN
  SELECT request_id INTO v_req FROM t;

  ASSERT (SELECT status FROM request WHERE id = v_req) = 'pending', 'request should be pending';

  -- The strongest form of invariant (2): there is nothing that COULD move.
  SELECT count(*) INTO n FROM loan;
  ASSERT n = 0, format('(2,23) an unaccepted offer must create no loan row, found %s', n);

  ASSERT pg_temp.qty_at('c0000000-0000-0000-0000-000000000001', 'NM') = 2,
    '(2) an unaccepted offer must move no inventory';

  RAISE NOTICE 'ok  (2,23) offer is a request: no loan row, no inventory moved';
END $$;

-- A second identical offer is refused while the first is pending.
SELECT pg_temp.must_fail($$
  SELECT app_offer_loan(
    '[{"edition_id":"a0000000-0000-0000-0000-000000000004","finish":"NONFOIL",
       "origin_location_id":"c0000000-0000-0000-0000-000000000001",
       "condition":"NM","qty":1}]'::jsonb,
    'b0000000-0000-0000-0000-000000000002')
$$, '(23) duplicate pending request of the same kind');

-- Only the addressee may accept.
SELECT pg_temp.must_fail($$
  SELECT app_accept_request((SELECT request_id FROM t))
$$, '(23) proposer accepting their own request');

-- ---------------------------------------------------------------------------
-- (c) Accepting moves inventory into the holder bucket
-- ---------------------------------------------------------------------------

SELECT pg_temp.act_as('b0000000-0000-0000-0000-000000000002');
SELECT app_accept_request((SELECT request_id FROM t));

-- Back to the owner before asserting. Inventory assertions run under RLS, so
-- checking them as Sarah would read zeros for everything -- and pass for
-- entirely the wrong reason.
SELECT pg_temp.act_as('b0000000-0000-0000-0000-000000000001');

DO $$
DECLARE v_holder uuid; n int;
BEGIN
  SELECT id INTO v_holder FROM location
   WHERE account_id = 'b0000000-0000-0000-0000-000000000001'
     AND holder_account_id = 'b0000000-0000-0000-0000-000000000002';

  SELECT count(*) INTO n FROM loan_line;
  ASSERT n = 2, format('(13) qty 2 must expand to 2 single-card lines, got %s', n);

  ASSERT pg_temp.qty_at('c0000000-0000-0000-0000-000000000001', 'NM') = 0,
    'Box A NONFOIL bucket should be emptied and deleted';
  ASSERT pg_temp.qty_at(v_holder, 'NM') = 2,
    format('(10) holder bucket should hold 2, has %s', pg_temp.qty_at(v_holder, 'NM'));
  ASSERT (SELECT count(*) FROM holding
           WHERE location_id = 'c0000000-0000-0000-0000-000000000001'
             AND condition = 'NM' AND finish = 'NONFOIL') = 0,
    '(8) emptied bucket must be deleted, not zeroed';

  RAISE NOTICE 'ok  (10,13) accept created the loan, moved 2, split into 2 lines';
END $$;

-- ---------------------------------------------------------------------------
-- (d) Unfriend is blocked while cards are out -- in BOTH directions
-- ---------------------------------------------------------------------------

-- Each block states its actor explicitly rather than inheriting the previous
-- one, so reordering a section cannot silently change who is asserting.
SELECT pg_temp.act_as('b0000000-0000-0000-0000-000000000002');
SELECT pg_temp.must_fail($$
  SELECT app_unfriend('b0000000-0000-0000-0000-000000000001')
$$, '(5) borrower unfriending the lender while holding cards');

SELECT pg_temp.act_as('b0000000-0000-0000-0000-000000000001');
SELECT pg_temp.must_fail($$
  SELECT app_unfriend('b0000000-0000-0000-0000-000000000002')
$$, '(5) lender unfriending the borrower while cards are out');

-- ---------------------------------------------------------------------------
-- (g) Sub-loan to a non-friend of the owner, gated on owner approval
-- ---------------------------------------------------------------------------

SELECT pg_temp.act_as('b0000000-0000-0000-0000-000000000002');
CREATE TEMP TABLE tr AS
SELECT app_request_sub_loan(
  (SELECT id FROM loan_line WHERE status = 'outstanding' ORDER BY id LIMIT 1),
  'b0000000-0000-0000-0000-000000000003') AS request_id;

-- One transfer in flight per card. This used to be a partial unique index;
-- it now spans two tables, so app_request_sub_loan() carries it instead.
SELECT pg_temp.must_fail($$
  SELECT app_request_sub_loan(
    (SELECT loan_line_id FROM request_sub_loan LIMIT 1),
    'b0000000-0000-0000-0000-000000000003')
$$, '(18) second pending transfer request for the same card');

-- The borrower cannot approve their own request; only the owner can.
SELECT pg_temp.must_fail($$
  SELECT app_accept_request((SELECT request_id FROM tr))
$$, '(18) borrower approving their own transfer');

SELECT pg_temp.act_as('b0000000-0000-0000-0000-000000000001');
SELECT app_accept_request((SELECT request_id FROM tr));

DO $$
DECLARE v_sarah uuid; v_mike uuid;
BEGIN
  SELECT id INTO v_sarah FROM location
   WHERE account_id = 'b0000000-0000-0000-0000-000000000001'
     AND holder_account_id = 'b0000000-0000-0000-0000-000000000002';
  SELECT id INTO v_mike FROM location
   WHERE account_id = 'b0000000-0000-0000-0000-000000000001'
     AND holder_account_id = 'b0000000-0000-0000-0000-000000000003';

  ASSERT pg_temp.qty_at(v_sarah, 'NM') = 1, 'Sarah should be down to 1';
  ASSERT pg_temp.qty_at(v_mike, 'NM') = 1, 'Mike should now hold 1';
  ASSERT (SELECT count(*) FROM loan_transfer) = 1,
    '(19) the transfer row must survive as custody history';

  RAISE NOTICE 'ok  (18,19,20) sub-loan to a non-friend, split 1/1, history kept';
END $$;

-- ---------------------------------------------------------------------------
-- (6,13) Return with a condition downgrade
-- ---------------------------------------------------------------------------

SELECT pg_temp.act_as('b0000000-0000-0000-0000-000000000002');

-- Exactly the query Sarah's own screen would run: no join to `location`,
-- because she cannot read the lender's locations (14). RLS narrows loan_line
-- to the lines she is holding, so Mike's card is invisible to her here.
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM loan_line WHERE status = 'outstanding';
  ASSERT n = 1, format('(14) Sarah should see only her own held line, saw %s', n);
  RAISE NOTICE 'ok  (14) borrower sees only the card she holds, not Mike''s';
END $$;

SELECT app_mark_returned((SELECT id FROM loan_line WHERE status = 'outstanding' LIMIT 1));

SELECT pg_temp.act_as('b0000000-0000-0000-0000-000000000001');
SELECT app_confirm_receipt(
  (SELECT id FROM loan_line WHERE status = 'in_transit' LIMIT 1),
  'LP', NULL);

DO $$
DECLARE v_sarah uuid;
BEGIN
  SELECT id INTO v_sarah FROM location
   WHERE account_id = 'b0000000-0000-0000-0000-000000000001'
     AND holder_account_id = 'b0000000-0000-0000-0000-000000000002';

  ASSERT pg_temp.qty_at(v_sarah, 'NM') = 0, 'Sarah''s bucket should be empty';
  ASSERT pg_temp.qty_at('c0000000-0000-0000-0000-000000000001', 'LP') = 1,
    '(13) the card must file into the LP bucket it came back in';
  ASSERT pg_temp.qty_at('c0000000-0000-0000-0000-000000000001', 'NM') = 0,
    '(13) it must NOT return to the NM bucket it left';

  RAISE NOTICE 'ok  (6,13) return downgraded NM -> LP, filed to the origin box';
END $$;

-- ---------------------------------------------------------------------------
-- (e,h) Force-close the last card, which closes the loan
-- ---------------------------------------------------------------------------

SELECT app_force_close_line(
  (SELECT id FROM loan_line WHERE status = 'outstanding' LIMIT 1), false);

DO $$
DECLARE v_loan uuid;
BEGIN
  SELECT id INTO v_loan FROM loan LIMIT 1;
  ASSERT (SELECT status FROM loan WHERE id = v_loan) = 'closed',
    '(11) a loan must close when its last line closes';
  ASSERT (SELECT count(*) FROM open_custody) = 0, 'no custody should remain open';
  ASSERT (SELECT coalesce(sum(qty), 0) FROM holding
           WHERE account_id = 'b0000000-0000-0000-0000-000000000001') = 3,
    'owner should be down to 3 cards after writing one off';

  RAISE NOTICE 'ok  (15) per-card force-close; (11) loan auto-closed; write-off lost 1 copy';
END $$;

-- ---------------------------------------------------------------------------
-- (d) With everything settled, the unfriend now succeeds
-- ---------------------------------------------------------------------------

SELECT app_unfriend('b0000000-0000-0000-0000-000000000002');

DO $$ BEGIN
  ASSERT (SELECT count(*) FROM friendship) = 0, '(5) friendship should be gone';
  RAISE NOTICE 'ok  (5) unfriend succeeds once nothing is outstanding';
END $$;

RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'ALL RPC ASSERTIONS PASSED'; END $$;

ROLLBACK;
