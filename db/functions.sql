-- Mutation RPCs.
--
-- Every write to inventory and loans goes through a function here. The tables
-- themselves are SELECT-only to users (see db/policies.sql), because on
-- Supabase the client can always reach PostgREST directly -- a rule enforced
-- only in application code is bypassable by anyone holding the anon key.
--
-- These functions are the nine invariants listed at the bottom of
-- db/schema.sql, made executable. Parenthesised numbers cite decisions in
-- docs/design/friends-and-loans.md.
--
-- All are SECURITY DEFINER with a pinned search_path, and all authorise
-- against auth.uid() before touching anything.
--
--   psql -d fci -v ON_ERROR_STOP=1 -f db/functions.sql

-- ---------------------------------------------------------------------------
-- Internal helpers (not granted to users)
-- ---------------------------------------------------------------------------

/**
 * Adjust a holding bucket by a delta, creating or deleting the row as needed.
 *
 * This is the only place quantities change. It enforces the rule the smoke
 * test discovered the hard way: an emptied bucket is DELETED, never stored as
 * zero, because `qty > 0` rejects the update outright (8).
 */
CREATE OR REPLACE FUNCTION app_bucket_adjust(
  p_account   uuid,
  p_edition   uuid,
  p_finish    card_finish,
  p_location  uuid,
  p_condition card_condition,
  p_delta     integer
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_current integer;
BEGIN
  IF p_delta = 0 THEN RETURN; END IF;

  SELECT qty INTO v_current
    FROM holding
   WHERE account_id = p_account AND edition_id = p_edition AND finish = p_finish
     AND location_id = p_location AND condition = p_condition
     FOR UPDATE;

  v_current := coalesce(v_current, 0);

  IF v_current + p_delta < 0 THEN
    RAISE EXCEPTION 'not enough cards: bucket holds %, tried to remove %',
      v_current, -p_delta
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_current = 0 THEN
    INSERT INTO holding (account_id, edition_id, finish, location_id, condition, qty)
    VALUES (p_account, p_edition, p_finish, p_location, p_condition, p_delta);
  ELSIF v_current + p_delta = 0 THEN
    DELETE FROM holding
     WHERE account_id = p_account AND edition_id = p_edition AND finish = p_finish
       AND location_id = p_location AND condition = p_condition;
  ELSE
    UPDATE holding SET qty = qty + p_delta, updated_at = now()
     WHERE account_id = p_account AND edition_id = p_edition AND finish = p_finish
       AND location_id = p_location AND condition = p_condition;
  END IF;
END $$;

/** Find or create the caller's holder location for a person (3). */
CREATE OR REPLACE FUNCTION app_holder_location(
  p_owner          uuid,
  p_holder_account uuid,
  p_holder_name    text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF num_nonnulls(p_holder_account, p_holder_name) <> 1 THEN
    RAISE EXCEPTION 'specify exactly one of holder account or holder name';
  END IF;

  IF p_holder_account IS NOT NULL THEN
    SELECT id INTO v_id FROM location
     WHERE account_id = p_owner AND holder_account_id = p_holder_account;
    IF v_id IS NULL THEN
      INSERT INTO location (account_id, kind, holder_account_id)
      VALUES (p_owner, 'holder', p_holder_account) RETURNING id INTO v_id;
    END IF;
  ELSE
    SELECT id INTO v_id FROM location
     WHERE account_id = p_owner AND kind = 'holder'
       AND holder_account_id IS NULL AND lower(name) = lower(p_holder_name);
    IF v_id IS NULL THEN
      INSERT INTO location (account_id, kind, name)
      VALUES (p_owner, 'holder', p_holder_name) RETURNING id INTO v_id;
    END IF;
  END IF;

  RETURN v_id;
END $$;

/** Close the parent loan once its last line closes (11). */
CREATE OR REPLACE FUNCTION app_maybe_close_loan(p_loan uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM loan_line
     WHERE loan_id = p_loan AND status IN ('outstanding', 'in_transit')
  ) THEN
    UPDATE loan SET status = 'closed', closed_at = now()
     WHERE id = p_loan AND status <> 'closed';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION app_require_lender(p_loan uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM loan WHERE id = p_loan AND lender_account_id = auth.uid()) THEN
    RAISE EXCEPTION 'not your loan' USING ERRCODE = 'insufficient_privilege';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Inventory
-- ---------------------------------------------------------------------------

/** Add copies to one of your own physical locations. */
CREATE OR REPLACE FUNCTION app_add_cards(
  p_edition   uuid,
  p_finish    card_finish,
  p_location  uuid,
  p_condition card_condition,
  p_qty       integer
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF p_qty <= 0 THEN RAISE EXCEPTION 'qty must be positive'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM location
     WHERE id = p_location AND account_id = auth.uid() AND kind = 'physical'
  ) THEN
    RAISE EXCEPTION 'not your physical location'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  PERFORM app_bucket_adjust(auth.uid(), p_edition, p_finish, p_location, p_condition, p_qty);
END $$;

/**
 * Move copies between your own locations.
 *
 * Physical locations only. Cards reach a holder location by being loaned (10),
 * never by being filed there directly -- otherwise the holding and the loan
 * record could disagree about who has what.
 */
CREATE OR REPLACE FUNCTION app_move_cards(
  p_edition   uuid,
  p_finish    card_finish,
  p_from      uuid,
  p_to        uuid,
  p_condition card_condition,
  p_qty       integer
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF p_qty <= 0 THEN RAISE EXCEPTION 'qty must be positive'; END IF;
  IF p_from = p_to THEN RAISE EXCEPTION 'source and destination are the same'; END IF;

  IF (SELECT count(*) FROM location
       WHERE id IN (p_from, p_to) AND account_id = auth.uid() AND kind = 'physical') <> 2 THEN
    RAISE EXCEPTION 'both locations must be your own physical locations'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  PERFORM app_bucket_adjust(auth.uid(), p_edition, p_finish, p_from, p_condition, -p_qty);
  PERFORM app_bucket_adjust(auth.uid(), p_edition, p_finish, p_to,   p_condition,  p_qty);
END $$;

-- ---------------------------------------------------------------------------
-- Decks (issue #21)
--
-- Standard Constructed rules, from https://rules.gatcg.com/general-rules/
-- general-rules-format-conventions:
--   * Main deck: minimum 60 cards, max 4 copies of a card name.
--   * Material deck: max 12 cards, max 1 copy of a card name, needs a Level 0
--     champion. Only CHAMPION/REGALIA cards go here.
--   * Sideboard: max 15 cards AND max 15 points -- a main-deck-type card
--     costs 1, a Champion/Regalia card costs 3.
--   * A card whose attributes->legality->STANDARD->limit is 0 is banned; a
--     lower positive limit tightens the section's normal cap. This also
--     covers a future non-zero restricted-to-N list without a hardcoded name
--     list, since it reads the ingested catalog data rather than a fixed set.
--
-- Sideboard copies share the SAME copy-limit pool as their type: a Regalia in
-- the sideboard counts against the material 1-copy pool, everything else
-- against the main 4-copy pool (confirmed as the intended reading, since the
-- rules page does not spell this edge case out explicitly).
--
-- Only the upper bounds above are rejected outright. The 60-card minimum and
-- the champion requirement are never enforced here -- every deck starts at 0
-- cards, so a floor can only be a display-time "not yet legal" fact, never
-- something to reject a mutation over. See deck_summary for that.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app_create_deck(p_name text) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF btrim(coalesce(p_name, '')) = '' THEN
    RAISE EXCEPTION 'deck needs a name';
  END IF;

  INSERT INTO deck (account_id, name) VALUES (auth.uid(), btrim(p_name))
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION app_rename_deck(p_deck uuid, p_name text) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF btrim(coalesce(p_name, '')) = '' THEN
    RAISE EXCEPTION 'deck needs a name';
  END IF;

  UPDATE deck SET name = btrim(p_name), updated_at = now()
   WHERE id = p_deck AND account_id = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not your deck' USING ERRCODE = 'insufficient_privilege';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION app_delete_deck(p_deck uuid) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  DELETE FROM deck WHERE id = p_deck AND account_id = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not your deck' USING ERRCODE = 'insufficient_privilege';
  END IF;
END $$;

/**
 * Set the exact quantity of one (edition, section, finish) row in a deck,
 * inserting, updating or deleting as needed -- same "set an absolute value,
 * the function figures out insert/update/delete" shape as app_bucket_adjust,
 * except this takes the target qty directly rather than a delta, because a
 * deck builder UI sets "how many of this printing" rather than adding one at
 * a time.
 *
 * qty = 0 always succeeds and just removes the row: removing a card can never
 * break a rule, so it is never worth rejecting.
 */
CREATE OR REPLACE FUNCTION app_set_deck_card(
  p_deck    uuid,
  p_edition uuid,
  p_section deck_section,
  p_finish  card_finish,
  p_qty     integer
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_card_id          uuid;
  v_types            jsonb;
  v_is_material       boolean;
  v_limit            integer;
  v_pool_cap         integer;
  v_pool_other_qty   integer;
  v_material_other   integer;
  v_this_points      integer;
  v_sideboard_cards  integer;
  v_sideboard_points integer;
BEGIN
  IF p_qty < 0 THEN RAISE EXCEPTION 'qty cannot be negative'; END IF;

  -- Locks the deck row for the rest of this check-and-write, so two
  -- concurrent edits to the same deck cannot both pass the aggregate checks
  -- below and together exceed a limit neither alone would have.
  IF NOT EXISTS (SELECT 1 FROM deck WHERE id = p_deck AND account_id = auth.uid() FOR UPDATE) THEN
    RAISE EXCEPTION 'not your deck' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT c.id, c.attributes -> 'types',
         (c.attributes -> 'legality' -> 'STANDARD' ->> 'limit')::integer
    INTO v_card_id, v_types, v_limit
    FROM card_edition ce JOIN card c ON c.id = ce.card_id
   WHERE ce.id = p_edition;

  IF v_card_id IS NULL THEN
    RAISE EXCEPTION 'unknown edition';
  END IF;

  v_is_material := coalesce(v_types ?| array['CHAMPION', 'REGALIA'], false);

  IF p_qty = 0 THEN
    DELETE FROM deck_card
     WHERE deck_id = p_deck AND edition_id = p_edition AND section = p_section AND finish = p_finish;
    RETURN;
  END IF;

  IF p_section = 'material' AND NOT v_is_material THEN
    RAISE EXCEPTION 'only Champion or Regalia cards go in the material deck';
  END IF;
  IF p_section = 'main' AND v_is_material THEN
    RAISE EXCEPTION 'Champion and Regalia cards go in the material deck, not the main deck';
  END IF;

  IF v_limit IS NOT NULL AND v_limit <= 0 THEN
    RAISE EXCEPTION 'this card is not legal in Standard' USING ERRCODE = 'check_violation';
  END IF;

  v_pool_cap := CASE WHEN v_is_material THEN 1 ELSE 4 END;
  IF v_limit IS NOT NULL THEN
    v_pool_cap := LEAST(v_pool_cap, v_limit);
  END IF;

  -- Copy-limit pool: material-type cards pool material+sideboard rows of the
  -- same card name; everything else pools main+sideboard rows instead (18).
  SELECT coalesce(sum(dc.qty), 0) INTO v_pool_other_qty
    FROM deck_card dc JOIN card_edition ce2 ON ce2.id = dc.edition_id
   WHERE dc.deck_id = p_deck
     AND ce2.card_id = v_card_id
     AND NOT (dc.edition_id = p_edition AND dc.section = p_section AND dc.finish = p_finish)
     AND dc.section = ANY (CASE WHEN v_is_material THEN ARRAY['material', 'sideboard']::deck_section[]
                                 ELSE ARRAY['main', 'sideboard']::deck_section[] END);

  IF v_pool_other_qty + p_qty > v_pool_cap THEN
    RAISE EXCEPTION 'only % cop%s of this card allowed here (already have %)',
      v_pool_cap, (CASE WHEN v_pool_cap = 1 THEN '' ELSE 'ie' END), v_pool_other_qty
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_section = 'material' THEN
    SELECT coalesce(sum(qty), 0) INTO v_material_other
      FROM deck_card
     WHERE deck_id = p_deck AND section = 'material'
       AND NOT (edition_id = p_edition AND finish = p_finish);

    IF v_material_other + p_qty > 12 THEN
      RAISE EXCEPTION 'material deck cannot exceed 12 cards' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  IF p_section = 'sideboard' THEN
    v_this_points := CASE WHEN v_is_material THEN 3 ELSE 1 END;

    SELECT coalesce(sum(dc.qty), 0),
           coalesce(sum(dc.qty * (CASE WHEN c3.attributes -> 'types' ?| array['CHAMPION', 'REGALIA']
                                        THEN 3 ELSE 1 END)), 0)
      INTO v_sideboard_cards, v_sideboard_points
      FROM deck_card dc
        JOIN card_edition ce3 ON ce3.id = dc.edition_id
        JOIN card c3 ON c3.id = ce3.card_id
     WHERE dc.deck_id = p_deck AND dc.section = 'sideboard'
       AND NOT (dc.edition_id = p_edition AND dc.finish = p_finish);

    IF v_sideboard_cards + p_qty > 15 THEN
      RAISE EXCEPTION 'sideboard cannot exceed 15 cards' USING ERRCODE = 'check_violation';
    END IF;
    IF v_sideboard_points + (p_qty * v_this_points) > 15 THEN
      RAISE EXCEPTION 'sideboard cannot exceed 15 points' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  INSERT INTO deck_card (deck_id, edition_id, section, finish, qty)
  VALUES (p_deck, p_edition, p_section, p_finish, p_qty)
  ON CONFLICT (deck_id, edition_id, section, finish)
  DO UPDATE SET qty = EXCLUDED.qty;
END $$;

-- Read-only: legality is a display fact, not something any mutation is
-- gated on (see the comment above app_set_deck_card). No SECURITY DEFINER --
-- deck/deck_card's owner-only SELECT policies already restrict this to the
-- caller's own deck, so running as invoker is both simpler and correct.
CREATE OR REPLACE FUNCTION deck_summary(p_deck uuid)
RETURNS TABLE (
  material_count      integer,
  main_count           integer,
  sideboard_count      integer,
  sideboard_points     integer,
  has_level0_champion  boolean,
  is_legal             boolean
)
LANGUAGE sql STABLE AS $$
  WITH d AS (
    SELECT dc.section, dc.qty, c.attributes
      FROM deck_card dc
        JOIN card_edition ce ON ce.id = dc.edition_id
        JOIN card c ON c.id = ce.card_id
     WHERE dc.deck_id = p_deck
  ), agg AS (
    SELECT
      coalesce(sum(qty) FILTER (WHERE section = 'material'), 0)::integer AS material_count,
      coalesce(sum(qty) FILTER (WHERE section = 'main'), 0)::integer AS main_count,
      coalesce(sum(qty) FILTER (WHERE section = 'sideboard'), 0)::integer AS sideboard_count,
      coalesce(sum(qty * CASE WHEN attributes -> 'types' ?| array['CHAMPION', 'REGALIA'] THEN 3 ELSE 1 END)
               FILTER (WHERE section = 'sideboard'), 0)::integer AS sideboard_points,
      bool_or(section = 'material' AND attributes -> 'types' ? 'CHAMPION'
              AND (attributes ->> 'level')::numeric = 0) AS has_level0_champion
    FROM d
  )
  SELECT material_count, main_count, sideboard_count, sideboard_points, has_level0_champion,
         (main_count >= 60 AND has_level0_champion)
    FROM agg;
$$;

-- ---------------------------------------------------------------------------
-- Requests: the shared approval lifecycle (23)
-- ---------------------------------------------------------------------------
--
-- Every pending approval in the app is a `request` row. Creating one is
-- kind-specific (the payload differs); resolving one is not. app_accept_request
-- dispatches to a materialiser per kind, and that materialiser is the ONLY
-- thing that creates a friendship, loan, trade or transfer.

/** Guard: I am the recipient of this pending request. */
CREATE OR REPLACE FUNCTION app_require_recipient(p_request uuid)
RETURNS request
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE r request;
BEGIN
  SELECT * INTO r FROM request WHERE id = p_request FOR UPDATE;
  IF r IS NULL THEN RAISE EXCEPTION 'no such request'; END IF;
  IF r.status <> 'pending' THEN
    RAISE EXCEPTION 'request is already %', r.status;
  END IF;
  IF r.recipient_account_id <> auth.uid() THEN
    RAISE EXCEPTION 'that request is not addressed to you'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION app_open_request(
  p_kind      request_kind,
  p_recipient uuid,
  p_note      text DEFAULT NULL,
  p_supersedes uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF p_recipient = auth.uid() THEN
    RAISE EXCEPTION 'cannot send a request to yourself';
  END IF;

  INSERT INTO request (kind, proposer_account_id, recipient_account_id, note, supersedes_id)
  VALUES (p_kind, auth.uid(), p_recipient, p_note, p_supersedes)
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;

/**
 * Claim a username (33).
 *
 * Case-insensitive and unique: `Jon` and `jon` are the same handle, so the
 * second person to want it is told no rather than quietly getting a different
 * account than their friends will search for.
 */
CREATE OR REPLACE FUNCTION app_set_username(p_username text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_clean text := btrim(p_username);
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  IF v_clean !~ '^[A-Za-z0-9][A-Za-z0-9_-]{2,19}$' THEN
    RAISE EXCEPTION 'A username must be 3 to 20 characters, start with a letter or number, and contain only letters, numbers, hyphens and underscores.'
      USING ERRCODE = 'check_violation';
  END IF;

  UPDATE account SET username = v_clean::citext, updated_at = now()
   WHERE id = auth.uid();

EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'That username is taken.' USING ERRCODE = 'unique_violation';
END $$;

/**
 * Find someone to befriend, by username or by EXACT email address.
 *
 * Exists because account_self_or_friend deliberately hides strangers: without
 * this, there is no way to reach anyone you are not already connected to.
 *
 * BOTH are exact matches, and that is the privacy design rather than a
 * shortcut. `ilike '%jon%'` would turn this into a dump of every user in the
 * system. Requiring the whole handle or the whole address means you can only
 * find someone who has told you what it is -- which is exactly the situation
 * where you have standing to ask them.
 *
 * A username is the friendlier half of that: it is a thing you can say out
 * loud across a table, where an email address is not.
 *
 * Returns the relationship too, so the caller can say "already friends" or
 * "request pending" instead of offering a button that will fail.
 */
CREATE OR REPLACE FUNCTION app_find_account(p_query text)
RETURNS TABLE (
  id            uuid,
  username      text,
  display_name  text,
  is_self       boolean,
  is_friend     boolean,
  request_state text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_q text := btrim(p_query);
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF v_q = '' THEN RETURN; END IF;

  RETURN QUERY
  SELECT a.id,
         a.username::text,
         a.display_name,
         a.id = auth.uid(),
         app_is_friend(a.id),
         CASE
           WHEN EXISTS (SELECT 1 FROM request r
                         WHERE r.status = 'pending' AND r.kind = 'friend'
                           AND r.proposer_account_id = auth.uid()
                           AND r.recipient_account_id = a.id)
             THEN 'sent'
           WHEN EXISTS (SELECT 1 FROM request r
                         WHERE r.status = 'pending' AND r.kind = 'friend'
                           AND r.recipient_account_id = auth.uid()
                           AND r.proposer_account_id = a.id)
             THEN 'received'
           ELSE NULL
         END
    FROM account a
   -- An address always contains @ and a username never can, so the two can
   -- never collide and one input can safely mean either.
   WHERE a.email = v_q::citext
      OR a.username = v_q::citext;
END $$;

/** Be my friend (1). The only request kind that needs no prior relationship. */
CREATE OR REPLACE FUNCTION app_send_friend_request(p_to uuid, p_note text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF app_is_friend(p_to) THEN RAISE EXCEPTION 'already friends'; END IF;
  RETURN app_open_request('friend', p_to, p_note);
END $$;

/**
 * Offer to lend (2). Creates a request, NOT a loan -- an unaccepted loan has
 * no row anywhere, which is what makes "a pending loan moves nothing"
 * structural rather than a rule to remember.
 */
CREATE OR REPLACE FUNCTION app_offer_loan(
  p_lines jsonb, p_to uuid, p_note text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_req uuid; v_spec jsonb;
BEGIN
  IF NOT app_is_friend(p_to) THEN
    RAISE EXCEPTION 'you can only lend to an accepted friend'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_req := app_open_request('loan_offer', p_to, p_note);

  FOR v_spec IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    IF NOT EXISTS (
      SELECT 1 FROM location
       WHERE id = (v_spec->>'origin_location_id')::uuid
         AND account_id = auth.uid() AND kind = 'physical'
    ) THEN
      RAISE EXCEPTION 'origin must be your own physical location'
        USING ERRCODE = 'insufficient_privilege';
    END IF;

    INSERT INTO request_loan_item
      (request_id, edition_id, finish, condition, qty, origin_location_id)
    VALUES (v_req,
            (v_spec->>'edition_id')::uuid,
            (v_spec->>'finish')::card_finish,
            (v_spec->>'condition')::card_condition,
            coalesce((v_spec->>'qty')::integer, 1),
            (v_spec->>'origin_location_id')::uuid);
  END LOOP;

  RETURN v_req;
END $$;

/**
 * Ask to borrow (28). The mirror image of an offer: the borrower proposes and
 * the owner approves. No origin is given -- the borrower does not know, and has
 * no right to know, which box the card lives in (14). The owner picks it when
 * they accept.
 */
CREATE OR REPLACE FUNCTION app_request_borrow(
  p_lines jsonb, p_from uuid, p_note text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_req uuid; v_spec jsonb;
BEGIN
  IF NOT app_is_friend(p_from) THEN
    RAISE EXCEPTION 'you can only ask a friend'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_req := app_open_request('borrow_request', p_from, p_note);

  FOR v_spec IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    INSERT INTO request_loan_item (request_id, edition_id, finish, condition, qty)
    VALUES (v_req,
            (v_spec->>'edition_id')::uuid,
            (v_spec->>'finish')::card_finish,
            (v_spec->>'condition')::card_condition,
            coalesce((v_spec->>'qty')::integer, 1));
  END LOOP;

  RETURN v_req;
END $$;

/**
 * Propose a swap (24). `p_give` are cards the proposer hands over, `p_take` are
 * cards they want back. Nothing moves until the offer is accepted, and even
 * then only into transit.
 */
CREATE OR REPLACE FUNCTION app_offer_trade(
  p_give jsonb, p_take jsonb, p_to uuid,
  p_note text DEFAULT NULL, p_supersedes uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_req uuid; v_spec jsonb;
BEGIN
  IF NOT app_is_friend(p_to) THEN
    RAISE EXCEPTION 'you can only trade with an accepted friend'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF jsonb_array_length(coalesce(p_give, '[]'::jsonb)) = 0
     AND jsonb_array_length(coalesce(p_take, '[]'::jsonb)) = 0 THEN
    RAISE EXCEPTION 'a trade must move at least one card';
  END IF;

  v_req := app_open_request('trade_offer', p_to, p_note, p_supersedes);

  FOR v_spec IN SELECT * FROM jsonb_array_elements(coalesce(p_give, '[]'::jsonb)) LOOP
    INSERT INTO request_trade_item
      (request_id, from_proposer, edition_id, finish, condition, qty)
    VALUES (v_req, true, (v_spec->>'edition_id')::uuid,
            (v_spec->>'finish')::card_finish,
            (v_spec->>'condition')::card_condition,
            coalesce((v_spec->>'qty')::integer, 1));
  END LOOP;

  FOR v_spec IN SELECT * FROM jsonb_array_elements(coalesce(p_take, '[]'::jsonb)) LOOP
    INSERT INTO request_trade_item
      (request_id, from_proposer, edition_id, finish, condition, qty)
    VALUES (v_req, false, (v_spec->>'edition_id')::uuid,
            (v_spec->>'finish')::card_finish,
            (v_spec->>'condition')::card_condition,
            coalesce((v_spec->>'qty')::integer, 1));
  END LOOP;

  RETURN v_req;
END $$;

/**
 * Counter-offer (25): decline the original and open a fresh one that cites it.
 * Terms are never edited under a reader, so accepting always applies exactly
 * what was displayed.
 */
CREATE OR REPLACE FUNCTION app_counter_trade(
  p_request uuid, p_give jsonb, p_take jsonb, p_note text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE r request;
BEGIN
  r := app_require_recipient(p_request);
  IF r.kind <> 'trade_offer' THEN RAISE EXCEPTION 'not a trade offer'; END IF;

  UPDATE request SET status = 'superseded', resolved_at = now() WHERE id = p_request;

  -- Roles swap: the counter is proposed BY the original recipient.
  RETURN app_offer_trade(p_give, p_take, r.proposer_account_id, p_note, p_request);
END $$;

/** Ask the owner to let me pass this card on (18, 20). */
CREATE OR REPLACE FUNCTION app_request_sub_loan(
  p_line uuid, p_holder_account uuid DEFAULT NULL, p_holder_name text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_owner uuid; v_req uuid; v_status loan_line_status;
BEGIN
  IF NOT app_is_holder_of_line(p_line) THEN
    RAISE EXCEPTION 'you are not holding that card'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT ln.lender_account_id, ll.status INTO v_owner, v_status
    FROM loan_line ll JOIN loan ln ON ln.id = ll.loan_id WHERE ll.id = p_line;

  IF v_status <> 'outstanding' THEN
    RAISE EXCEPTION 'only an outstanding card can be passed on';
  END IF;

  -- "One transfer in flight per card" used to be a partial unique index. It
  -- spans request and request_sub_loan now, so no index can express it.
  IF EXISTS (
    SELECT 1 FROM request_sub_loan sl JOIN request r ON r.id = sl.request_id
     WHERE sl.loan_line_id = p_line AND r.status = 'pending'
  ) THEN
    RAISE EXCEPTION 'a transfer request for that card is already pending';
  END IF;

  v_req := app_open_request('sub_loan', v_owner);
  INSERT INTO request_sub_loan (request_id, loan_line_id, to_holder_account_id, to_holder_name)
  VALUES (v_req, p_line, p_holder_account, p_holder_name);

  RETURN v_req;
END $$;

-- ---------------------------------------------------------------------------
-- Resolving a request
-- ---------------------------------------------------------------------------

/**
 * Accept a request. Dispatches by kind; each branch is the only code path that
 * creates the thing it creates (23).
 *
 * p_data carries whatever the ACCEPTER must supply that the proposer could not:
 *   borrow_request -> {"origins": [{"edition_id":…, "finish":…,
 *                                   "origin_location_id":…}]}
 * Everything else ignores it.
 */
CREATE OR REPLACE FUNCTION app_accept_request(p_request uuid, p_data jsonb DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE r request;
BEGIN
  r := app_require_recipient(p_request);

  CASE r.kind
    WHEN 'friend'         THEN PERFORM app_materialise_friendship(r);
    WHEN 'loan_offer'     THEN PERFORM app_materialise_loan(r, r.proposer_account_id, NULL);
    WHEN 'borrow_request' THEN PERFORM app_materialise_loan(r, r.recipient_account_id, p_data);
    WHEN 'trade_offer'    THEN PERFORM app_materialise_trade(r);
    WHEN 'sub_loan'       THEN PERFORM app_materialise_sub_loan(r);
  END CASE;

  UPDATE request SET status = 'accepted', resolved_at = now() WHERE id = p_request;
END $$;

CREATE OR REPLACE FUNCTION app_decline_request(p_request uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  PERFORM app_require_recipient(p_request);
  UPDATE request SET status = 'declined', resolved_at = now() WHERE id = p_request;
END $$;

/** Withdraw something you proposed. */
CREATE OR REPLACE FUNCTION app_cancel_request(p_request uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM request
     WHERE id = p_request AND proposer_account_id = auth.uid() AND status = 'pending'
  ) THEN
    RAISE EXCEPTION 'no pending request of yours'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  UPDATE request SET status = 'cancelled', resolved_at = now() WHERE id = p_request;
END $$;

-- ---------------------------------------------------------------------------
-- Materialisers: the only creators of friendships, loans, trades, transfers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app_materialise_friendship(r request)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  INSERT INTO friendship (account_lo_id, account_hi_id, created_from_request_id)
  VALUES (least(r.proposer_account_id, r.recipient_account_id),
          greatest(r.proposer_account_id, r.recipient_account_id),
          r.id)
  ON CONFLICT DO NOTHING;
END $$;

/**
 * Turn an accepted loan_offer or borrow_request into a live loan.
 *
 * p_lender is whichever party owns the cards -- the proposer for an offer, the
 * recipient for a borrow request. From here on the two are indistinguishable,
 * which is the whole point of (28).
 */
CREATE OR REPLACE FUNCTION app_materialise_loan(r request, p_lender uuid, p_data jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_borrower uuid := CASE WHEN p_lender = r.proposer_account_id
                          THEN r.recipient_account_id ELSE r.proposer_account_id END;
  v_holder uuid;
  v_loan   uuid;
  it       record;
  v_origin uuid;
  i        integer;
BEGIN
  v_holder := app_holder_location(p_lender, v_borrower, NULL);

  INSERT INTO loan (lender_account_id, initial_holder_location_id, status,
                    created_from_request_id, note)
  VALUES (p_lender, v_holder, 'active', r.id, r.note)
  RETURNING id INTO v_loan;

  FOR it IN SELECT * FROM request_loan_item WHERE request_id = r.id LOOP
    v_origin := it.origin_location_id;

    -- A borrow request carries no origin; the owner supplies one on approval.
    IF v_origin IS NULL THEN
      SELECT (o->>'origin_location_id')::uuid INTO v_origin
        FROM jsonb_array_elements(coalesce(p_data->'origins', '[]'::jsonb)) o
       WHERE (o->>'edition_id')::uuid = it.edition_id
         AND (o->>'finish')::card_finish = it.finish
       LIMIT 1;
    END IF;

    IF v_origin IS NULL THEN
      RAISE EXCEPTION 'no origin location given for edition %', it.edition_id;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM location
       WHERE id = v_origin AND account_id = p_lender AND kind = 'physical'
    ) THEN
      RAISE EXCEPTION 'origin must be a physical location belonging to the lender';
    END IF;

    FOR i IN 1..it.qty LOOP
      INSERT INTO loan_line (loan_id, edition_id, finish, origin_location_id,
                             departure_condition, holder_location_id)
      VALUES (v_loan, it.edition_id, it.finish, v_origin, it.condition, v_holder);
    END LOOP;
  END LOOP;

  PERFORM app_move_to_holder(v_loan);
END $$;

/** Move every outstanding line out of its origin and into the holder bucket (10). */
CREATE OR REPLACE FUNCTION app_move_to_holder(p_loan uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_owner uuid; r record;
BEGIN
  SELECT lender_account_id INTO v_owner FROM loan WHERE id = p_loan;
  FOR r IN SELECT * FROM loan_line WHERE loan_id = p_loan AND status = 'outstanding' LOOP
    PERFORM app_bucket_adjust(v_owner, r.edition_id, r.finish,
                              r.origin_location_id, r.departure_condition, -1);
    PERFORM app_bucket_adjust(v_owner, r.edition_id, r.finish,
                              r.holder_location_id, r.departure_condition,  1);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION app_materialise_sub_loan(r request)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE sl record; ll record; v_to uuid;
BEGIN
  SELECT * INTO sl FROM request_sub_loan WHERE request_id = r.id;

  SELECT l.*, ln.lender_account_id INTO ll
    FROM loan_line l JOIN loan ln ON ln.id = l.loan_id WHERE l.id = sl.loan_line_id;

  IF ll.status <> 'outstanding' THEN
    RAISE EXCEPTION 'that card is no longer outstanding';
  END IF;

  v_to := app_holder_location(ll.lender_account_id, sl.to_holder_account_id, sl.to_holder_name);
  IF v_to = ll.holder_location_id THEN RAISE EXCEPTION 'that person already has it'; END IF;

  PERFORM app_bucket_adjust(ll.lender_account_id, ll.edition_id, ll.finish,
                            ll.holder_location_id, ll.departure_condition, -1);
  PERFORM app_bucket_adjust(ll.lender_account_id, ll.edition_id, ll.finish,
                            v_to, ll.departure_condition, 1);

  UPDATE loan_line SET holder_location_id = v_to WHERE id = sl.loan_line_id;

  -- Retained as the custody trail (19).
  INSERT INTO loan_transfer (loan_line_id, from_location_id, to_location_id,
                             initiated_by_account_id, approved_from_request_id)
  VALUES (sl.loan_line_id, ll.holder_location_id, v_to, r.proposer_account_id, r.id);
END $$;

/**
 * Start a trade settling (24). Each side's outgoing cards move into a holder
 * location naming the other party -- the same device a loan uses (10) -- so an
 * in-flight trade still reads as "with Sarah" rather than vanishing.
 *
 * Nothing lands in anyone's collection until they confirm receipt.
 */
CREATE OR REPLACE FUNCTION app_materialise_trade(r request)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_trade uuid;
  it      record;
  v_from  uuid; v_to uuid; v_holder uuid;
  i       integer;
BEGIN
  INSERT INTO trade (created_from_request_id, proposer_account_id, recipient_account_id)
  VALUES (r.id, r.proposer_account_id, r.recipient_account_id)
  RETURNING id INTO v_trade;

  FOR it IN SELECT * FROM request_trade_item WHERE request_id = r.id LOOP
    IF it.from_proposer THEN
      v_from := r.proposer_account_id; v_to := r.recipient_account_id;
    ELSE
      v_from := r.recipient_account_id; v_to := r.proposer_account_id;
    END IF;

    v_holder := app_holder_location(v_from, v_to, NULL);

    FOR i IN 1..it.qty LOOP
      -- Out of a physical bucket, into the sender's holder bucket. Picking the
      -- source bucket is deliberately strict: the sender must actually own a
      -- copy in the stated condition, or the trade cannot be accepted.
      PERFORM app_trade_reserve(v_from, it.edition_id, it.finish, it.condition, v_holder);

      INSERT INTO trade_item (trade_id, from_account_id, to_account_id, edition_id,
                              finish, departure_condition, holder_location_id)
      VALUES (v_trade, v_from, v_to, it.edition_id, it.finish, it.condition, v_holder);
    END LOOP;
  END LOOP;
END $$;

/** Take one copy out of any physical bucket and park it in the holder bucket. */
CREATE OR REPLACE FUNCTION app_trade_reserve(
  p_account uuid, p_edition uuid, p_finish card_finish,
  p_condition card_condition, p_holder uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_src uuid;
BEGIN
  SELECT h.location_id INTO v_src
    FROM holding h JOIN location l ON l.id = h.location_id
   WHERE h.account_id = p_account AND h.edition_id = p_edition
     AND h.finish = p_finish AND h.condition = p_condition
     AND l.kind = 'physical' AND h.qty > 0
   ORDER BY h.qty DESC
   LIMIT 1;

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'no % copy of that card in a physical location to trade away',
      p_condition USING ERRCODE = 'check_violation';
  END IF;

  PERFORM app_bucket_adjust(p_account, p_edition, p_finish, v_src, p_condition, -1);
  PERFORM app_bucket_adjust(p_account, p_edition, p_finish, p_holder, p_condition, 1);
END $$;

-- ---------------------------------------------------------------------------
-- Settling a trade (24)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app_trade_maybe_complete(p_trade uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM trade_item WHERE trade_id = p_trade AND status = 'in_transit'
  ) THEN
    UPDATE trade SET status = 'completed', completed_at = now()
     WHERE id = p_trade AND status = 'settling';
  END IF;
END $$;

/**
 * The RECEIVER confirms a card arrived and sets the condition it arrived in.
 *
 * This is the moment ownership actually transfers: the copy leaves the
 * sender's inventory entirely and appears in the receiver's. It is the only
 * operation in the app that writes holdings for two different accounts.
 */
CREATE OR REPLACE FUNCTION app_confirm_trade_item(
  p_item uuid, p_condition card_condition DEFAULT NULL, p_location uuid DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE it trade_item; v_cond card_condition; v_dest uuid;
BEGIN
  SELECT * INTO it FROM trade_item WHERE id = p_item FOR UPDATE;
  IF it IS NULL THEN RAISE EXCEPTION 'no such trade item'; END IF;
  IF it.to_account_id <> auth.uid() THEN
    RAISE EXCEPTION 'only the receiver confirms a trade item'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF it.status <> 'in_transit' THEN RAISE EXCEPTION 'already settled'; END IF;

  v_cond := coalesce(p_condition, it.departure_condition);
  v_dest := p_location;

  IF v_dest IS NULL THEN
    SELECT id INTO v_dest FROM location
     WHERE account_id = auth.uid() AND kind = 'physical'
     ORDER BY created_at LIMIT 1;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM location
     WHERE id = v_dest AND account_id = auth.uid() AND kind = 'physical'
  ) THEN
    RAISE EXCEPTION 'destination must be your own physical location';
  END IF;

  -- Gone from the sender, for good.
  PERFORM app_bucket_adjust(it.from_account_id, it.edition_id, it.finish,
                            it.holder_location_id, it.departure_condition, -1);
  -- Arrived, at whatever condition it actually turned up in.
  PERFORM app_bucket_adjust(auth.uid(), it.edition_id, it.finish,
                            v_dest, v_cond, 1);

  UPDATE trade_item
     SET status = 'received', received_condition = v_cond,
         received_location_id = v_dest, received_at = now()
   WHERE id = p_item;

  PERFORM app_trade_maybe_complete(it.trade_id);
END $$;

/**
 * The escape hatch for a half-settled trade -- the same problem (5) solves for
 * loans. The SENDER writes off a card that never arrived; it leaves their
 * inventory and joins nobody else's.
 */
CREATE OR REPLACE FUNCTION app_write_off_trade_item(p_item uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE it trade_item;
BEGIN
  SELECT * INTO it FROM trade_item WHERE id = p_item FOR UPDATE;
  IF it IS NULL THEN RAISE EXCEPTION 'no such trade item'; END IF;
  IF auth.uid() NOT IN (it.from_account_id, it.to_account_id) THEN
    RAISE EXCEPTION 'not your trade' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF it.status <> 'in_transit' THEN RAISE EXCEPTION 'already settled'; END IF;

  PERFORM app_bucket_adjust(it.from_account_id, it.edition_id, it.finish,
                            it.holder_location_id, it.departure_condition, -1);

  UPDATE trade_item SET status = 'written_off' WHERE id = p_item;
  PERFORM app_trade_maybe_complete(it.trade_id);
END $$;

-- ---------------------------------------------------------------------------
-- Listings: a signal, not a gate (27)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app_set_listing(
  p_edition uuid, p_finish card_finish,
  p_for_trade boolean, p_for_sale boolean, p_price numeric DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  -- A row offering nothing is clutter; unlisting deletes it.
  IF NOT (p_for_trade OR p_for_sale) THEN
    DELETE FROM listing
     WHERE account_id = auth.uid() AND edition_id = p_edition AND finish = p_finish;
    RETURN;
  END IF;

  INSERT INTO listing (account_id, edition_id, finish, for_trade, for_sale, asking_price)
  VALUES (auth.uid(), p_edition, p_finish, p_for_trade, p_for_sale, p_price)
  ON CONFLICT (account_id, edition_id, finish) DO UPDATE
     SET for_trade = excluded.for_trade,
         for_sale = excluded.for_sale,
         asking_price = excluded.asking_price,
         updated_at = now();
END $$;

/**
 * Which cards in this request were never offered (27)?
 *
 * Drives the warning on the owner's notification. It does NOT gate anything --
 * the request is valid either way; the owner just gets told they are being
 * asked for something off-menu.
 *
 * Only meaningful for requests that ask for the RECIPIENT's cards: a borrow
 * request, or the take-side of a trade offer.
 */
CREATE OR REPLACE FUNCTION app_request_unlisted(p_request uuid)
RETURNS TABLE (edition_id uuid, finish card_finish, qty integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE r request;
BEGIN
  SELECT * INTO r FROM request WHERE id = p_request;
  IF r IS NULL THEN RAISE EXCEPTION 'no such request'; END IF;
  IF auth.uid() NOT IN (r.proposer_account_id, r.recipient_account_id) THEN
    RAISE EXCEPTION 'not your request' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  WITH asked AS (
    SELECT i.edition_id, i.finish, i.qty
      FROM request_loan_item i
     WHERE i.request_id = r.id AND r.kind = 'borrow_request'
    UNION ALL
    SELECT i.edition_id, i.finish, i.qty
      FROM request_trade_item i
     WHERE i.request_id = r.id AND r.kind = 'trade_offer' AND i.from_proposer = false
  )
  SELECT a.edition_id, a.finish, a.qty
    FROM asked a
   WHERE NOT EXISTS (
     SELECT 1 FROM listing l
      WHERE l.account_id = r.recipient_account_id
        AND l.edition_id = a.edition_id
        AND l.finish = a.finish
        AND (l.for_trade OR l.for_sale)
   );
END $$;

/** Borrower sends a card back: outstanding -> in_transit (6). */
CREATE OR REPLACE FUNCTION app_mark_returned(p_line uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF NOT app_is_holder_of_line(p_line) THEN
    RAISE EXCEPTION 'you are not holding that card'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE loan_line SET status = 'in_transit', sent_at = now()
   WHERE id = p_line AND status = 'outstanding';

  IF NOT FOUND THEN RAISE EXCEPTION 'card is not outstanding'; END IF;
END $$;

/**
 * Lender confirms receipt and sets the condition it came back in (13).
 *
 * The card files into the bucket matching its RECEIVED condition, which may
 * differ from the one it left in -- that is the whole point of setting it here.
 * p_return_location defaults to the origin, which the UI pre-fills as a
 * suggestion the lender can override (10).
 */
CREATE OR REPLACE FUNCTION app_confirm_receipt(
  p_line             uuid,
  p_condition        card_condition DEFAULT NULL,
  p_return_location  uuid DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  r        record;
  v_cond   card_condition;
  v_dest   uuid;
BEGIN
  SELECT ll.*, ln.lender_account_id INTO r
    FROM loan_line ll JOIN loan ln ON ln.id = ll.loan_id
   WHERE ll.id = p_line;

  IF r IS NULL THEN RAISE EXCEPTION 'no such loan line'; END IF;
  PERFORM app_require_lender(r.loan_id);
  IF r.status NOT IN ('outstanding', 'in_transit') THEN
    RAISE EXCEPTION 'card is already settled';
  END IF;

  v_cond := coalesce(p_condition, r.departure_condition);
  v_dest := coalesce(p_return_location, r.origin_location_id);

  IF NOT EXISTS (
    SELECT 1 FROM location
     WHERE id = v_dest AND account_id = r.lender_account_id AND kind = 'physical'
  ) THEN
    RAISE EXCEPTION 'return destination must be your own physical location';
  END IF;

  -- Out of the holder bucket at its departure condition, into a physical
  -- bucket at whatever condition it actually came back in.
  PERFORM app_bucket_adjust(r.lender_account_id, r.edition_id, r.finish,
                            r.holder_location_id, r.departure_condition, -1);
  PERFORM app_bucket_adjust(r.lender_account_id, r.edition_id, r.finish,
                            v_dest, v_cond, 1);

  UPDATE loan_line
     SET status = 'returned', received_at = now(), received_condition = v_cond,
         return_location_id = v_dest, close_reason = 'returned_confirmed',
         closed_at = now()
   WHERE id = p_line;

  PERFORM app_maybe_close_loan(r.loan_id);
END $$;

/**
 * The lender's escape hatch (5), acting on ONE card (15).
 *
 * p_recovered = true means the card is physically back and files into
 * p_return_location; false writes it off as gone. Either way the line settles,
 * which is what releases the unfriend block.
 */
CREATE OR REPLACE FUNCTION app_force_close_line(
  p_line            uuid,
  p_recovered       boolean DEFAULT false,
  p_condition       card_condition DEFAULT NULL,
  p_return_location uuid DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  r      record;
  v_dest uuid;
  v_cond card_condition;
BEGIN
  SELECT ll.*, ln.lender_account_id INTO r
    FROM loan_line ll JOIN loan ln ON ln.id = ll.loan_id
   WHERE ll.id = p_line;

  IF r IS NULL THEN RAISE EXCEPTION 'no such loan line'; END IF;
  PERFORM app_require_lender(r.loan_id);
  IF r.status NOT IN ('outstanding', 'in_transit') THEN
    RAISE EXCEPTION 'card is already settled';
  END IF;

  -- Either way it leaves the holder's hands.
  PERFORM app_bucket_adjust(r.lender_account_id, r.edition_id, r.finish,
                            r.holder_location_id, r.departure_condition, -1);

  IF p_recovered THEN
    v_dest := coalesce(p_return_location, r.origin_location_id);
    v_cond := coalesce(p_condition, r.departure_condition);
    PERFORM app_bucket_adjust(r.lender_account_id, r.edition_id, r.finish,
                              v_dest, v_cond, 1);
    UPDATE loan_line
       SET status = 'returned', received_at = now(), received_condition = v_cond,
           return_location_id = v_dest, close_reason = 'force_closed_returned',
           closed_at = now()
     WHERE id = p_line;
  ELSE
    -- Written off: the copy is gone from the inventory entirely.
    UPDATE loan_line
       SET status = 'written_off', close_reason = 'force_closed_written_off',
           closed_at = now()
     WHERE id = p_line;
  END IF;

  PERFORM app_maybe_close_loan(r.loan_id);
END $$;

-- ---------------------------------------------------------------------------
-- Lending to someone who is not a user (3)
-- ---------------------------------------------------------------------------

/**
 * A loan to a bare name. No request, because a text name has nobody to accept
 * one -- this is the single path that creates a loan without going through the
 * request lifecycle, and (3) is why.
 */
CREATE OR REPLACE FUNCTION app_lend_to_name(
  p_lines jsonb, p_name text, p_note text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_holder uuid; v_loan uuid; v_spec jsonb; i integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  v_holder := app_holder_location(auth.uid(), NULL, p_name);

  INSERT INTO loan (lender_account_id, initial_holder_location_id, status, note)
  VALUES (auth.uid(), v_holder, 'active', p_note) RETURNING id INTO v_loan;

  FOR v_spec IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    IF NOT EXISTS (
      SELECT 1 FROM location
       WHERE id = (v_spec->>'origin_location_id')::uuid
         AND account_id = auth.uid() AND kind = 'physical'
    ) THEN
      RAISE EXCEPTION 'origin must be your own physical location';
    END IF;

    FOR i IN 1..coalesce((v_spec->>'qty')::integer, 1) LOOP
      INSERT INTO loan_line (loan_id, edition_id, finish, origin_location_id,
                             departure_condition, holder_location_id)
      VALUES (v_loan, (v_spec->>'edition_id')::uuid,
              (v_spec->>'finish')::card_finish,
              (v_spec->>'origin_location_id')::uuid,
              (v_spec->>'condition')::card_condition, v_holder);
    END LOOP;
  END LOOP;

  PERFORM app_move_to_holder(v_loan);
  RETURN v_loan;
END $$;

-- ---------------------------------------------------------------------------
-- Friendship
-- ---------------------------------------------------------------------------

/**
 * Unfriend, refused while either party still holds the other's cards (5),
 * checked in BOTH directions.
 */
CREATE OR REPLACE FUNCTION app_unfriend(p_other uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_me uuid := auth.uid(); v_open integer;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF v_me = p_other THEN RAISE EXCEPTION 'cannot unfriend yourself'; END IF;

  SELECT count(*) INTO v_open
    FROM loan_line ll
    JOIN loan ln  ON ln.id = ll.loan_id
    JOIN location loc ON loc.id = ll.holder_location_id
   WHERE ll.status IN ('outstanding', 'in_transit')
     AND (   (ln.lender_account_id = v_me    AND loc.holder_account_id = p_other)
          OR (ln.lender_account_id = p_other AND loc.holder_account_id = v_me));

  IF v_open > 0 THEN
    RAISE EXCEPTION
      'cannot unfriend: % card(s) still outstanding between you. Settle or force-close them first.',
      v_open
      USING ERRCODE = 'check_violation';
  END IF;

  -- A trade mid-flight is the same problem wearing a different hat.
  SELECT count(*) INTO v_open
    FROM trade_item ti
   WHERE ti.status = 'in_transit'
     AND ((ti.from_account_id = v_me AND ti.to_account_id = p_other)
       OR (ti.from_account_id = p_other AND ti.to_account_id = v_me));

  IF v_open > 0 THEN
    RAISE EXCEPTION
      'cannot unfriend: % card(s) still in transit between you from a trade.', v_open
      USING ERRCODE = 'check_violation';
  END IF;

  DELETE FROM friendship
   WHERE least(v_me, p_other) = account_lo_id
     AND greatest(v_me, p_other) = account_hi_id;
END $$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

DO $$
DECLARE fn text; r text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'app_add_cards(uuid,card_finish,uuid,card_condition,integer)',
    'app_move_cards(uuid,card_finish,uuid,uuid,card_condition,integer)',
    'app_send_friend_request(uuid,text)',
    'app_find_account(text)',
    'app_set_username(text)',
    'app_offer_loan(jsonb,uuid,text)',
    'app_request_borrow(jsonb,uuid,text)',
    'app_offer_trade(jsonb,jsonb,uuid,text,uuid)',
    'app_counter_trade(uuid,jsonb,jsonb,text)',
    'app_request_sub_loan(uuid,uuid,text)',
    'app_accept_request(uuid,jsonb)',
    'app_decline_request(uuid)',
    'app_cancel_request(uuid)',
    'app_request_unlisted(uuid)',
    'app_set_listing(uuid,card_finish,boolean,boolean,numeric)',
    'app_confirm_trade_item(uuid,card_condition,uuid)',
    'app_write_off_trade_item(uuid)',
    'app_lend_to_name(jsonb,text,text)',
    'app_mark_returned(uuid)',
    'app_confirm_receipt(uuid,card_condition,uuid)',
    'app_force_close_line(uuid,boolean,card_condition,uuid)',
    'app_unfriend(uuid)',
    'app_create_deck(text)',
    'app_rename_deck(uuid,text)',
    'app_delete_deck(uuid)',
    'app_set_deck_card(uuid,uuid,deck_section,card_finish,integer)',
    'deck_summary(uuid)'
  ] LOOP
    FOREACH r IN ARRAY ARRAY['authenticated', 'app_user'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', fn, r);
      END IF;
    END LOOP;
  END LOOP;
END $$;
