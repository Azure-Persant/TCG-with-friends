-- Row Level Security policies.
--
-- REQUIRED on Supabase. The client talks straight to Postgres through
-- PostgREST using the anon key, so without these policies every holding,
-- location and loan in the database is world-readable. The views in
-- schema.sql control the *shape* of what a friend sees; RLS controls whether
-- they may read the underlying tables at all. Both are needed.
--
-- Assumes Supabase auth: auth.uid() returns the signed-in account's id, and
-- account.id is the same uuid as auth.users.id.
--
--   psql -d fci -v ON_ERROR_STOP=1 -f db/policies.sql
--
-- The ingest worker connects with the service-role key, which bypasses RLS
-- entirely -- that is how the catalog gets written despite the read-only
-- policies below.

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Is the current user in an accepted friendship with `other`?
-- SECURITY DEFINER so it can read friendship rows the caller cannot select.
CREATE OR REPLACE FUNCTION app_is_friend(other uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  -- No status filter: every row in `friendship` is an accepted friendship
  -- now that pending lives in `request` (23).
  SELECT EXISTS (
    SELECT 1 FROM friendship f
     WHERE least(auth.uid(), other) = f.account_lo_id
       AND greatest(auth.uid(), other) = f.account_hi_id
  );
$$;

-- Payload tables are guarded by their parent request. SECURITY DEFINER for the
-- usual reason: an inline EXISTS against `request` would re-enter request's own
-- policy from a child table's policy.
CREATE OR REPLACE FUNCTION app_can_see_request(p_request uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1 FROM request r
     WHERE r.id = p_request
       AND auth.uid() IN (r.proposer_account_id, r.recipient_account_id)
  );
$$;

-- Is there a live request between me and `other`, in either direction?
CREATE OR REPLACE FUNCTION app_has_pending_request_with(other uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1 FROM request r
     WHERE r.status = 'pending'
       AND (   (r.proposer_account_id = auth.uid() AND r.recipient_account_id = other)
            OR (r.recipient_account_id = auth.uid() AND r.proposer_account_id = other))
  );
$$;

-- Has `owner` shared the game that this edition belongs to? (4)
CREATE OR REPLACE FUNCTION app_shares_edition(owner uuid, edition uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM card_edition e
      JOIN card c ON c.id = e.card_id
      JOIN game_share gs ON gs.game_id = c.game_id AND gs.account_id = owner
     WHERE e.id = edition
  );
$$;

-- Is the current user holding this specific card right now? Borrowers can see
-- a card they hold regardless of game sharing -- the exception in (4).
CREATE OR REPLACE FUNCTION app_holds_edition(owner uuid, edition uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM loan_line ll
      JOIN loan ln ON ln.id = ll.loan_id
      JOIN location loc ON loc.id = ll.holder_location_id
     WHERE ln.lender_account_id = owner
       AND ll.edition_id = edition
       AND ll.status IN ('outstanding', 'in_transit')
       AND loc.holder_account_id = auth.uid()
  );
$$;

-- ---------------------------------------------------------------------------
-- Catalog: readable by everyone, writable only by the ingest (12)
-- ---------------------------------------------------------------------------

ALTER TABLE game                ENABLE ROW LEVEL SECURITY;
ALTER TABLE card_set            ENABLE ROW LEVEL SECURITY;
ALTER TABLE card                ENABLE ROW LEVEL SECURITY;
ALTER TABLE card_edition        ENABLE ROW LEVEL SECURITY;
ALTER TABLE card_edition_finish ENABLE ROW LEVEL SECURITY;
ALTER TABLE card_image          ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog_sync_run    ENABLE ROW LEVEL SECURITY;

CREATE POLICY catalog_read_game   ON game                FOR SELECT USING (true);
CREATE POLICY catalog_read_set    ON card_set            FOR SELECT USING (true);
CREATE POLICY catalog_read_card   ON card                FOR SELECT USING (true);
CREATE POLICY catalog_read_ed     ON card_edition        FOR SELECT USING (true);
CREATE POLICY catalog_read_finish ON card_edition_finish FOR SELECT USING (true);
CREATE POLICY catalog_read_image  ON card_image          FOR SELECT USING (true);
-- catalog_sync_run gets no policy at all: operational data, service-role only.

-- ---------------------------------------------------------------------------
-- Accounts and friendship
-- ---------------------------------------------------------------------------

ALTER TABLE account    ENABLE ROW LEVEL SECURITY;
ALTER TABLE friendship ENABLE ROW LEVEL SECURITY;
ALTER TABLE game_share ENABLE ROW LEVEL SECURITY;

-- You can see yourself, and anyone you are already friends with. Finding new
-- people to befriend goes through a SECURITY DEFINER search function, not by
-- opening the whole account table to enumeration.
-- Also visible while a request is in flight between you. Without this clause
-- an incoming friend request from someone you do not know yet renders with no
-- display name -- the recipient cannot read the proposer's account row,
-- because they are not friends. That is the whole point of the request.
CREATE POLICY account_self_or_friend ON account
  FOR SELECT USING (
    id = auth.uid()
    OR app_is_friend(id)
    OR app_has_pending_request_with(id));

CREATE POLICY account_update_self ON account
  FOR UPDATE USING (id = auth.uid()) WITH CHECK (id = auth.uid());

-- Both parties can see the friendship. SELECT only, and deliberately so:
-- a friendship is created by accepting a `request` (23) and removed only by
-- app_unfriend(), which refuses while cards are outstanding (5).
CREATE POLICY friendship_visible ON friendship
  FOR SELECT USING (auth.uid() IN (account_lo_id, account_hi_id));

CREATE POLICY game_share_own ON game_share
  FOR ALL USING (account_id = auth.uid()) WITH CHECK (account_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Inventory
-- ---------------------------------------------------------------------------

ALTER TABLE location ENABLE ROW LEVEL SECURITY;
ALTER TABLE holding  ENABLE ROW LEVEL SECURITY;

-- Locations are private, full stop -- including holder locations, which is
-- what stops a friend from seeing WHO has your card (14). No friend-visible
-- policy exists here on purpose.
-- Users manage their own PHYSICAL locations directly -- naming a box is
-- harmless. Holder locations are created only by the loan functions, so a
-- holding and its loan record can never disagree about who has a card.
CREATE POLICY location_own_read ON location
  FOR SELECT USING (account_id = auth.uid());

CREATE POLICY location_own_write ON location
  FOR ALL USING (account_id = auth.uid() AND kind = 'physical')
  WITH CHECK (account_id = auth.uid() AND kind = 'physical');

-- SELECT only. Every quantity change goes through db/functions.sql, which is
-- what makes the invariants enforceable rather than advisory: on Supabase the
-- client can always reach PostgREST directly.
CREATE POLICY holding_own ON holding
  FOR SELECT USING (account_id = auth.uid());

-- A friend may read holdings only for a shared game (4), or for a card they
-- are currently holding. They still cannot read `location`, so they can count
-- what is on loan without learning where anything is.
CREATE POLICY holding_friend_read ON holding
  FOR SELECT USING (
    account_id <> auth.uid()
    AND (
      (app_is_friend(account_id) AND app_shares_edition(account_id, edition_id))
      OR app_holds_edition(account_id, edition_id)
    )
  );

-- ---------------------------------------------------------------------------
-- Decks (issue #21)
-- ---------------------------------------------------------------------------

ALTER TABLE deck      ENABLE ROW LEVEL SECURITY;
ALTER TABLE deck_card ENABLE ROW LEVEL SECURITY;

-- SELECT only, same reasoning as holding: the copy-limit and section-size
-- math in app_set_deck_card only means something if it is the only way in.
-- No sharing policy yet -- see issue #22, deliberately separate.
CREATE POLICY deck_own ON deck
  FOR SELECT USING (account_id = auth.uid());

-- deck_card has no account_id of its own; deck_card -> deck is the only
-- direction this policy reads in (deck's own policy never reads deck_card),
-- so a plain EXISTS is safe here -- it is the loan/loan_line cycle (see
-- HANDOFF.md) that requires a SECURITY DEFINER helper instead, not this.
CREATE POLICY deck_card_own ON deck_card
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM deck d WHERE d.id = deck_card.deck_id AND d.account_id = auth.uid())
  );

-- ---------------------------------------------------------------------------
-- Loans
-- ---------------------------------------------------------------------------

ALTER TABLE loan                ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_line           ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_line_placement ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_transfer       ENABLE ROW LEVEL SECURITY;

-- Cross-table policy checks MUST go through SECURITY DEFINER helpers.
--
-- A policy on `loan` that inline-queries `loan_line` triggers loan_line's own
-- policy, which inline-queries `loan`, and Postgres aborts with "infinite
-- recursion detected in policy for relation loan". These helpers run with the
-- definer's rights, so the inner query bypasses RLS and the cycle is broken.
-- Do not inline these EXISTS clauses back into the policies.

-- Is the current user the borrower on this loan line?
CREATE OR REPLACE FUNCTION app_is_holder_of_line(line uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1 FROM loan_line ll
      JOIN location loc ON loc.id = ll.holder_location_id
     WHERE ll.id = line AND loc.holder_account_id = auth.uid()
  );
$$;

CREATE OR REPLACE FUNCTION app_is_lender_of_loan(p_loan uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1 FROM loan WHERE id = p_loan AND lender_account_id = auth.uid()
  );
$$;

CREATE OR REPLACE FUNCTION app_is_lender_of_line(p_line uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1 FROM loan_line ll JOIN loan ln ON ln.id = ll.loan_id
     WHERE ll.id = p_line AND ln.lender_account_id = auth.uid()
  );
$$;

-- Addressee of the original hand-off, or current holder of any line on it (2).
CREATE OR REPLACE FUNCTION app_is_borrower_on_loan(p_loan uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1 FROM loan ln JOIN location loc ON loc.id = ln.initial_holder_location_id
     WHERE ln.id = p_loan AND loc.holder_account_id = auth.uid()
  ) OR EXISTS (
    SELECT 1 FROM loan_line ll JOIN location loc ON loc.id = ll.holder_location_id
     WHERE ll.loan_id = p_loan AND loc.holder_account_id = auth.uid()
  );
$$;

-- Loans are SELECT-only here; every mutation goes through db/functions.sql.
CREATE POLICY loan_lender ON loan
  FOR SELECT USING (lender_account_id = auth.uid());

-- The borrower sees the loan they are on, so they can accept it (2).
CREATE POLICY loan_borrower_read ON loan
  FOR SELECT USING (app_is_borrower_on_loan(id));

CREATE POLICY loan_line_lender ON loan_line
  FOR SELECT USING (app_is_lender_of_loan(loan_id));

-- The borrower reads the lines they hold; marking one returned goes through
-- app_mark_returned() (6). Everything else about the card stays the lender's
-- data (7), which a direct UPDATE policy could not express.
CREATE POLICY loan_line_holder_read ON loan_line
  FOR SELECT USING (app_is_holder_of_line(id));

-- Placement is the borrower's own data (7), so it stays directly writable.
CREATE POLICY placement_own ON loan_line_placement
  FOR ALL USING (account_id = auth.uid()) WITH CHECK (account_id = auth.uid());

-- Both the current holder (who proposes) and the owner (who approves) need to
-- see a transfer (18). Approval itself goes through app_approve_transfer().
CREATE POLICY transfer_visible ON loan_transfer
  FOR SELECT USING (
    app_is_holder_of_line(loan_line_id) OR app_is_lender_of_line(loan_line_id)
  );

-- ---------------------------------------------------------------------------
-- Views
--
-- open_custody is a lender-side tool: it reads the lender's own loans, lines
-- and holder locations, all of which their own policies already permit. So it
-- runs as the caller and is filtered by RLS like any other query.
-- ---------------------------------------------------------------------------

ALTER VIEW open_custody SET (security_invoker = true);

-- friend_visible_holding CANNOT run as the caller, and this is subtle enough
-- to be worth spelling out.
--
-- The view derives qty_on_loan by joining `location` and counting the rows
-- whose kind is 'holder'. But a friend is forbidden from reading the owner's
-- locations -- that is exactly the rule that hides WHO has a card (14). Under
-- security_invoker the join therefore matches nothing, every row disappears,
-- and a friend sees an empty inventory. The privacy rule would silently
-- destroy the feature it is meant to qualify.
--
-- So the view runs with its owner's rights and performs its own access check
-- in the WHERE clause below. That clause is the entire access control for this
-- view: it must stay in sync with the friendship and sharing rules.
CREATE OR REPLACE VIEW friend_visible_holding AS
SELECT
  h.account_id,
  c.game_id,
  e.card_id,
  h.edition_id,
  h.finish,
  h.condition,
  sum(h.qty)                                               AS qty_total,
  coalesce(sum(h.qty) FILTER (WHERE l.kind = 'holder'), 0) AS qty_on_loan
FROM holding h
  JOIN location     l  ON l.id = h.location_id
  JOIN card_edition e  ON e.id = h.edition_id
  JOIN card         c  ON c.id = e.card_id
  JOIN game_share   gs ON gs.account_id = h.account_id AND gs.game_id = c.game_id
-- Your own row (so the app can show "here is how friends see you"), or a
-- friend's. The game_share join above already restricts this to shared games.
WHERE h.account_id = auth.uid() OR app_is_friend(h.account_id)
GROUP BY h.account_id, c.game_id, e.card_id, h.edition_id, h.finish, h.condition;

ALTER VIEW friend_visible_holding SET (security_invoker = false);

-- ---------------------------------------------------------------------------
-- Requests, listings and trades (23, 24, 27)
-- ---------------------------------------------------------------------------

ALTER TABLE request            ENABLE ROW LEVEL SECURITY;
ALTER TABLE request_loan_item  ENABLE ROW LEVEL SECURITY;
ALTER TABLE request_trade_item ENABLE ROW LEVEL SECURITY;
ALTER TABLE request_sub_loan   ENABLE ROW LEVEL SECURITY;
ALTER TABLE listing            ENABLE ROW LEVEL SECURITY;
ALTER TABLE trade              ENABLE ROW LEVEL SECURITY;
ALTER TABLE trade_item         ENABLE ROW LEVEL SECURITY;

-- Both parties see the request; nobody writes one directly (23).
CREATE POLICY request_visible ON request
  FOR SELECT USING (
    auth.uid() IN (proposer_account_id, recipient_account_id));

CREATE POLICY request_loan_item_visible ON request_loan_item
  FOR SELECT USING (app_can_see_request(request_id));

CREATE POLICY request_trade_item_visible ON request_trade_item
  FOR SELECT USING (app_can_see_request(request_id));

CREATE POLICY request_sub_loan_visible ON request_sub_loan
  FOR SELECT USING (app_can_see_request(request_id));

-- Listings carry no cross-account invariant -- they are a signal, not a gate
-- (27) -- so unlike holdings they stay directly writable by their owner.
CREATE POLICY listing_own ON listing
  FOR ALL USING (account_id = auth.uid()) WITH CHECK (account_id = auth.uid());

-- A friend sees a listing only for a game you share (4), same rule as holdings.
CREATE POLICY listing_friend_read ON listing
  FOR SELECT USING (
    account_id <> auth.uid()
    AND app_is_friend(account_id)
    AND app_shares_edition(account_id, edition_id));

CREATE POLICY trade_visible ON trade
  FOR SELECT USING (auth.uid() IN (proposer_account_id, recipient_account_id));

CREATE POLICY trade_item_visible ON trade_item
  FOR SELECT USING (auth.uid() IN (from_account_id, to_account_id));
