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
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM friendship f
     WHERE f.status = 'accepted'
       AND least(auth.uid(), other) = f.account_lo_id
       AND greatest(auth.uid(), other) = f.account_hi_id
  );
$$;

-- Has `owner` shared the game that this edition belongs to? (4)
CREATE OR REPLACE FUNCTION app_shares_edition(owner uuid, edition uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
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
SET search_path = public
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
CREATE POLICY account_self_or_friend ON account
  FOR SELECT USING (id = auth.uid() OR app_is_friend(id));

CREATE POLICY account_update_self ON account
  FOR UPDATE USING (id = auth.uid()) WITH CHECK (id = auth.uid());

-- Both parties can see the friendship, pending or accepted (1).
CREATE POLICY friendship_visible ON friendship
  FOR SELECT USING (auth.uid() IN (account_lo_id, account_hi_id));

CREATE POLICY friendship_request ON friendship
  FOR INSERT WITH CHECK (
    requested_by_id = auth.uid() AND auth.uid() IN (account_lo_id, account_hi_id));

-- Accepting or declining. The unfriend block (5) is enforced in application
-- code against the open_custody view, not here -- a DELETE policy cannot
-- express "unless the lender force-closes first".
CREATE POLICY friendship_respond ON friendship
  FOR UPDATE USING (auth.uid() IN (account_lo_id, account_hi_id));

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
CREATE POLICY location_own ON location
  FOR ALL USING (account_id = auth.uid()) WITH CHECK (account_id = auth.uid());

CREATE POLICY holding_own ON holding
  FOR ALL USING (account_id = auth.uid()) WITH CHECK (account_id = auth.uid());

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
-- Loans
-- ---------------------------------------------------------------------------

ALTER TABLE loan                ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_line           ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_line_placement ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_transfer       ENABLE ROW LEVEL SECURITY;

-- Is the current user the borrower on this loan line?
CREATE OR REPLACE FUNCTION app_is_holder_of_line(line uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM loan_line ll
      JOIN location loc ON loc.id = ll.holder_location_id
     WHERE ll.id = line AND loc.holder_account_id = auth.uid()
  );
$$;

CREATE POLICY loan_lender ON loan
  FOR ALL USING (lender_account_id = auth.uid()) WITH CHECK (lender_account_id = auth.uid());

-- The borrower sees the loan they are on, so they can accept it (2).
CREATE POLICY loan_borrower_read ON loan
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM location loc
       WHERE loc.id = loan.initial_holder_location_id
         AND loc.holder_account_id = auth.uid())
    OR EXISTS (
      SELECT 1 FROM loan_line ll
       WHERE ll.loan_id = loan.id AND app_is_holder_of_line(ll.id))
  );

CREATE POLICY loan_line_lender ON loan_line
  FOR ALL USING (
    EXISTS (SELECT 1 FROM loan ln WHERE ln.id = loan_line.loan_id
             AND ln.lender_account_id = auth.uid()))
  WITH CHECK (
    EXISTS (SELECT 1 FROM loan ln WHERE ln.id = loan_line.loan_id
             AND ln.lender_account_id = auth.uid()));

-- The borrower reads the lines they hold, and may mark them returned (6).
-- Everything else about the card stays the lender's data (7).
CREATE POLICY loan_line_holder_read ON loan_line
  FOR SELECT USING (app_is_holder_of_line(id));

CREATE POLICY loan_line_holder_return ON loan_line
  FOR UPDATE USING (app_is_holder_of_line(id)) WITH CHECK (app_is_holder_of_line(id));

-- Placement is the borrower's own data (7).
CREATE POLICY placement_own ON loan_line_placement
  FOR ALL USING (account_id = auth.uid()) WITH CHECK (account_id = auth.uid());

-- Both the current holder (who proposes) and the owner (who approves) need
-- access to a transfer (18).
CREATE POLICY transfer_visible ON loan_transfer
  FOR ALL USING (
    app_is_holder_of_line(loan_line_id)
    OR EXISTS (
      SELECT 1 FROM loan_line ll JOIN loan ln ON ln.id = ll.loan_id
       WHERE ll.id = loan_transfer.loan_line_id AND ln.lender_account_id = auth.uid())
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
