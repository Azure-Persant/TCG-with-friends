-- Request, trade and listing smoke test (23, 24, 25, 26, 27, 28).
--
-- Covers the flows added after the loan model settled: the shared approval
-- lifecycle, two-phase trade settlement, counter-offers, and listings as a
-- warning rather than a gate.
--
--   psql -d fci -v ON_ERROR_STOP=1 -f db/tests/request_smoke.sql
--
-- Requires schema.sql, auth_shim.sql, policies.sql and functions.sql loaded.
-- Runs in a transaction and rolls back.

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

CREATE OR REPLACE FUNCTION pg_temp.act_as(who uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN PERFORM set_config('app.current_user_id', who::text, true); END $$;

/** Total copies of an edition an account owns, anywhere. */
CREATE OR REPLACE FUNCTION pg_temp.owned(acct uuid, ed uuid)
RETURNS integer LANGUAGE sql STABLE AS $$
  SELECT coalesce((SELECT sum(qty)::integer FROM holding
                    WHERE account_id = acct AND edition_id = ed), 0);
$$;

/** Copies sitting in a physical location (i.e. actually in hand). */
CREATE OR REPLACE FUNCTION pg_temp.in_hand(acct uuid, ed uuid)
RETURNS integer LANGUAGE sql STABLE AS $$
  SELECT coalesce((SELECT sum(h.qty)::integer FROM holding h
                     JOIN location l ON l.id = h.location_id
                    WHERE h.account_id = acct AND h.edition_id = ed
                      AND l.kind = 'physical'), 0);
$$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

INSERT INTO game (id, slug, name)
VALUES ('e0000000-0000-0000-0000-000000000001', 'req-game', 'Req Game');
INSERT INTO card_set (id, game_id, external_id, prefix, name)
VALUES ('e0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000001',
        'qs1', 'QS1', 'Req Set');
INSERT INTO card (id, game_id, external_uuid, slug, name) VALUES
  ('e0000000-0000-0000-0000-000000000003', 'e0000000-0000-0000-0000-000000000001',
   'qc1', 'req-card-1', 'Req Card One'),
  ('e0000000-0000-0000-0000-000000000004', 'e0000000-0000-0000-0000-000000000001',
   'qc2', 'req-card-2', 'Req Card Two');
INSERT INTO card_edition (id, card_id, set_id, external_uuid, slug, collector_number) VALUES
  ('e1000000-0000-0000-0000-000000000001', 'e0000000-0000-0000-0000-000000000003',
   'e0000000-0000-0000-0000-000000000002', 'qe1', 'req-ed-1', '1'),
  ('e1000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000004',
   'e0000000-0000-0000-0000-000000000002', 'qe2', 'req-ed-2', '2');
INSERT INTO card_edition_finish (edition_id, finish) VALUES
  ('e1000000-0000-0000-0000-000000000001', 'NONFOIL'),
  ('e1000000-0000-0000-0000-000000000002', 'NONFOIL');

INSERT INTO account (id, email, display_name) VALUES
  ('f0000000-0000-0000-0000-000000000001', 'req-owner@example.com', 'Owner'),
  ('f0000000-0000-0000-0000-000000000002', 'req-sarah@example.com', 'Sarah');

INSERT INTO game_share (account_id, game_id) VALUES
  ('f0000000-0000-0000-0000-000000000001', 'e0000000-0000-0000-0000-000000000001'),
  ('f0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000001');

INSERT INTO location (id, account_id, kind, name) VALUES
  ('f1000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000001', 'physical', 'Box A'),
  ('f1000000-0000-0000-0000-000000000002', 'f0000000-0000-0000-0000-000000000002', 'physical', 'Shelf');

SET LOCAL ROLE app_user;

-- ---------------------------------------------------------------------------
-- (23) A friend request is a request row, and creates the friendship
-- ---------------------------------------------------------------------------

SELECT pg_temp.act_as('f0000000-0000-0000-0000-000000000001');

CREATE TEMP TABLE fr AS
SELECT app_send_friend_request('f0000000-0000-0000-0000-000000000002', 'hi') AS id;

DO $$ BEGIN
  ASSERT (SELECT count(*) FROM friendship) = 0,
    '(23) a pending friend request must not create a friendship yet';
  RAISE NOTICE 'ok  (23) friend request pending, no friendship yet';
END $$;

-- The recipient must be able to read the proposer's name, despite not being a
-- friend yet. Without the pending-request clause in account_self_or_friend,
-- an incoming request renders with no name on it.
SELECT pg_temp.act_as('f0000000-0000-0000-0000-000000000002');
DO $$
DECLARE v_name text;
BEGIN
  SELECT display_name INTO v_name FROM account
   WHERE id = 'f0000000-0000-0000-0000-000000000001';
  ASSERT v_name = 'Owner',
    '(23) recipient must see the proposer''s name on a pending request';
  RAISE NOTICE 'ok  (23) a stranger''s request still shows who it is from';
END $$;

SELECT app_accept_request((SELECT id FROM fr));

DO $$ BEGIN
  ASSERT (SELECT count(*) FROM friendship) = 1, '(23) accepting must create the friendship';
  ASSERT (SELECT status FROM request WHERE id = (SELECT id FROM fr)) = 'accepted',
    'request should be accepted';
  RAISE NOTICE 'ok  (23) accept created the friendship';
END $$;

-- ---------------------------------------------------------------------------
-- Stock both sides
-- ---------------------------------------------------------------------------

SELECT pg_temp.act_as('f0000000-0000-0000-0000-000000000001');
SELECT app_add_cards('e1000000-0000-0000-0000-000000000001', 'NONFOIL',
                     'f1000000-0000-0000-0000-000000000001', 'NM', 3);
SELECT app_add_cards('e1000000-0000-0000-0000-000000000002', 'NONFOIL',
                     'f1000000-0000-0000-0000-000000000001', 'NM', 1);

SELECT pg_temp.act_as('f0000000-0000-0000-0000-000000000002');
SELECT app_add_cards('e1000000-0000-0000-0000-000000000002', 'NONFOIL',
                     'f1000000-0000-0000-0000-000000000002', 'NM', 2);

-- ---------------------------------------------------------------------------
-- (27) Listings warn, they do not gate
-- ---------------------------------------------------------------------------

SELECT pg_temp.act_as('f0000000-0000-0000-0000-000000000001');
SELECT app_set_listing('e1000000-0000-0000-0000-000000000001', 'NONFOIL', true, false, NULL);

-- Sarah asks for BOTH: one listed, one not. (26) says both are allowed.
SELECT pg_temp.act_as('f0000000-0000-0000-0000-000000000002');
CREATE TEMP TABLE br AS
SELECT app_request_borrow(
  '[{"edition_id":"e1000000-0000-0000-0000-000000000001","finish":"NONFOIL","condition":"NM","qty":1},
    {"edition_id":"e1000000-0000-0000-0000-000000000002","finish":"NONFOIL","condition":"NM","qty":1}]'::jsonb,
  'f0000000-0000-0000-0000-000000000001', 'can I borrow these?') AS id;

SELECT pg_temp.act_as('f0000000-0000-0000-0000-000000000001');
DO $$
DECLARE n int; warned uuid;
BEGIN
  SELECT count(*) INTO n FROM app_request_unlisted((SELECT id FROM br));
  ASSERT n = 1, format('(27) exactly one requested card is unlisted, got %s', n);

  SELECT edition_id INTO warned FROM app_request_unlisted((SELECT id FROM br));
  ASSERT warned = 'e1000000-0000-0000-0000-000000000002',
    '(27) the warning must name the card that was never offered';

  RAISE NOTICE 'ok  (26,27) both cards requestable; only the unlisted one warns';
END $$;

-- (28) Approving supplies the origin the borrower could not know (14).
SELECT app_accept_request((SELECT id FROM br),
  '{"origins":[
     {"edition_id":"e1000000-0000-0000-0000-000000000001","finish":"NONFOIL",
      "origin_location_id":"f1000000-0000-0000-0000-000000000001"},
     {"edition_id":"e1000000-0000-0000-0000-000000000002","finish":"NONFOIL",
      "origin_location_id":"f1000000-0000-0000-0000-000000000001"}]}'::jsonb);

DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM loan_line WHERE status = 'outstanding';
  ASSERT n = 2, format('(28) approving a borrow must create 2 outstanding lines, got %s', n);
  ASSERT pg_temp.in_hand('f0000000-0000-0000-0000-000000000001',
                         'e1000000-0000-0000-0000-000000000001') = 2,
    '(28) one copy left Box A';
  -- Still owned: a loan never changes ownership, only location.
  ASSERT pg_temp.owned('f0000000-0000-0000-0000-000000000001',
                       'e1000000-0000-0000-0000-000000000001') = 3,
    '(28) a loan must not change what the owner owns';
  RAISE NOTICE 'ok  (28) borrow approved: owner picked the origin, cards moved, ownership unchanged';
END $$;

-- ---------------------------------------------------------------------------
-- (25) A counter-offer supersedes rather than edits
-- ---------------------------------------------------------------------------

SELECT pg_temp.act_as('f0000000-0000-0000-0000-000000000001');
CREATE TEMP TABLE t1 AS
SELECT app_offer_trade(
  '[{"edition_id":"e1000000-0000-0000-0000-000000000001","finish":"NONFOIL","condition":"NM","qty":1}]'::jsonb,
  '[{"edition_id":"e1000000-0000-0000-0000-000000000002","finish":"NONFOIL","condition":"NM","qty":2}]'::jsonb,
  'f0000000-0000-0000-0000-000000000002', 'two of yours for one of mine') AS id;

-- Sarah thinks that is greedy and counters.
SELECT pg_temp.act_as('f0000000-0000-0000-0000-000000000002');
CREATE TEMP TABLE t2 AS
SELECT app_counter_trade((SELECT id FROM t1),
  '[{"edition_id":"e1000000-0000-0000-0000-000000000002","finish":"NONFOIL","condition":"NM","qty":1}]'::jsonb,
  '[{"edition_id":"e1000000-0000-0000-0000-000000000001","finish":"NONFOIL","condition":"NM","qty":1}]'::jsonb,
  'one for one') AS id;

DO $$ BEGIN
  ASSERT (SELECT status FROM request WHERE id = (SELECT id FROM t1)) = 'superseded',
    '(25) the original must be superseded, not edited';
  ASSERT (SELECT supersedes_id FROM request WHERE id = (SELECT id FROM t2))
         = (SELECT id FROM t1),
    '(25) the counter must cite what it replaces';
  ASSERT (SELECT proposer_account_id FROM request WHERE id = (SELECT id FROM t2))
         = 'f0000000-0000-0000-0000-000000000002',
    '(25) roles swap: the counter is proposed by the original recipient';
  RAISE NOTICE 'ok  (25) counter-offer superseded the original and swapped roles';
END $$;

-- The superseded offer is dead and cannot be accepted.
SELECT pg_temp.act_as('f0000000-0000-0000-0000-000000000002');
SELECT pg_temp.must_fail($$
  SELECT app_accept_request((SELECT id FROM t1))
$$, '(25) accepting a superseded offer');

-- ---------------------------------------------------------------------------
-- (24) Two-phase settlement: the only thing that moves cards between accounts
-- ---------------------------------------------------------------------------

SELECT pg_temp.act_as('f0000000-0000-0000-0000-000000000001');
SELECT app_accept_request((SELECT id FROM t2));

DO $$ BEGIN
  ASSERT (SELECT count(*) FROM trade_item WHERE status = 'in_transit') = 2,
    '(24) both sides should be in transit';

  -- Each side has parted with a copy, but neither has received one.
  ASSERT pg_temp.in_hand('f0000000-0000-0000-0000-000000000001',
                         'e1000000-0000-0000-0000-000000000001') = 1,
    '(24) Owner''s traded copy left their hands';
  ASSERT pg_temp.owned('f0000000-0000-0000-0000-000000000002',
                       'e1000000-0000-0000-0000-000000000001') = 0,
    '(24) accepting must NOT hand the card over yet';

  RAISE NOTICE 'ok  (24) acceptance moved both sides into transit, ownership unchanged';
END $$;

-- The sender cannot confirm their own shipment as received.
SELECT pg_temp.must_fail($$
  SELECT app_confirm_trade_item(
    (SELECT id FROM trade_item
      WHERE from_account_id = 'f0000000-0000-0000-0000-000000000001' LIMIT 1))
$$, '(24) sender confirming receipt of their own card');

-- Owner receives Sarah's card, in worse shape than it left.
SELECT app_confirm_trade_item(
  (SELECT id FROM trade_item WHERE to_account_id = 'f0000000-0000-0000-0000-000000000001' LIMIT 1),
  'LP', 'f1000000-0000-0000-0000-000000000001');

DO $$ BEGIN
  ASSERT pg_temp.owned('f0000000-0000-0000-0000-000000000001',
                       'e1000000-0000-0000-0000-000000000002') = 2,
    '(24) Owner should now own 2 of card two (1 original + 1 traded in)';
  ASSERT (SELECT qty FROM holding
           WHERE account_id = 'f0000000-0000-0000-0000-000000000001'
             AND edition_id = 'e1000000-0000-0000-0000-000000000002'
             AND condition = 'LP') = 1,
    '(24,13) it must file at the condition it ARRIVED in, not the one it left in';
  ASSERT (SELECT status FROM trade WHERE id =
           (SELECT trade_id FROM trade_item LIMIT 1)) = 'settling',
    '(24) one half settled is not a completed trade';
  RAISE NOTICE 'ok  (24,13) half-settled: card changed hands and downgraded NM -> LP';
END $$;

-- A trade in flight blocks unfriending, exactly as an open loan does (5).
SELECT pg_temp.must_fail($$
  SELECT app_unfriend('f0000000-0000-0000-0000-000000000002')
$$, '(5,24) unfriending with a trade still in transit');

-- Sarah receives hers, which completes the trade.
SELECT pg_temp.act_as('f0000000-0000-0000-0000-000000000002');
SELECT app_confirm_trade_item(
  (SELECT id FROM trade_item WHERE to_account_id = 'f0000000-0000-0000-0000-000000000002' LIMIT 1),
  'NM', 'f1000000-0000-0000-0000-000000000002');

DO $$ BEGIN
  ASSERT pg_temp.owned('f0000000-0000-0000-0000-000000000002',
                       'e1000000-0000-0000-0000-000000000001') = 1,
    '(24) Sarah should now own the card she traded for';
  ASSERT pg_temp.owned('f0000000-0000-0000-0000-000000000001',
                       'e1000000-0000-0000-0000-000000000001') = 2,
    '(24) Owner should be down one -- ownership genuinely transferred';
  ASSERT (SELECT status FROM trade LIMIT 1) = 'completed',
    '(24) both halves settled completes the trade';
  RAISE NOTICE 'ok  (24) trade completed; cards moved BETWEEN accounts, both ways';
END $$;

-- ---------------------------------------------------------------------------
-- (24) The half-settled escape hatch
-- ---------------------------------------------------------------------------

SELECT pg_temp.act_as('f0000000-0000-0000-0000-000000000002');
CREATE TEMP TABLE t3 AS
SELECT app_offer_trade(
  '[{"edition_id":"e1000000-0000-0000-0000-000000000002","finish":"NONFOIL","condition":"NM","qty":1}]'::jsonb,
  '[]'::jsonb,
  'f0000000-0000-0000-0000-000000000001', 'a gift') AS id;

SELECT pg_temp.act_as('f0000000-0000-0000-0000-000000000001');
SELECT app_accept_request((SELECT id FROM t3));

DO $$
DECLARE v_item uuid; v_before int;
BEGIN
  SELECT id INTO v_item FROM trade_item WHERE status = 'in_transit' LIMIT 1;
  v_before := pg_temp.owned('f0000000-0000-0000-0000-000000000002',
                            'e1000000-0000-0000-0000-000000000002');

  PERFORM app_write_off_trade_item(v_item);

  ASSERT (SELECT status FROM trade_item WHERE id = v_item) = 'written_off',
    'item should be written off';
  ASSERT pg_temp.owned('f0000000-0000-0000-0000-000000000002',
                       'e1000000-0000-0000-0000-000000000002') = v_before - 1,
    '(24) a written-off card leaves the sender and joins nobody';
  RAISE NOTICE 'ok  (24) lost-in-post write-off settles the half without inventing a card';
END $$;

-- ---------------------------------------------------------------------------
-- Trading away something you do not have
-- ---------------------------------------------------------------------------

SELECT pg_temp.act_as('f0000000-0000-0000-0000-000000000002');
CREATE TEMP TABLE t4 AS
SELECT app_offer_trade(
  '[{"edition_id":"e1000000-0000-0000-0000-000000000002","finish":"NONFOIL","condition":"MINT","qty":1}]'::jsonb,
  '[]'::jsonb, 'f0000000-0000-0000-0000-000000000001', 'mint copy') AS id;

SELECT pg_temp.act_as('f0000000-0000-0000-0000-000000000001');
SELECT pg_temp.must_fail($$
  SELECT app_accept_request((SELECT id FROM t4))
$$, '(24) accepting a trade whose sender has no such copy');

DO $$ BEGIN
  ASSERT (SELECT status FROM request WHERE id = (SELECT id FROM t4)) = 'pending',
    'a failed acceptance must leave the request pending, not half-resolved';
  RAISE NOTICE 'ok  (24) a trade that cannot be honoured rolls back cleanly';
END $$;

RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'ALL REQUEST/TRADE ASSERTIONS PASSED'; END $$;

ROLLBACK;
