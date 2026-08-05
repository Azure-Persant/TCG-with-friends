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
SET search_path = public
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
SET search_path = public
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
SET search_path = public
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
SET search_path = public
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
SET search_path = public
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
SET search_path = public
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
-- Loans
-- ---------------------------------------------------------------------------

/**
 * Propose a loan. Nothing moves yet (2).
 *
 * p_lines is [{"edition_id":…, "finish":…, "origin_location_id":…,
 *              "condition":…, "qty":n}]; each qty is expanded into that many
 * single-card lines, because condition is set per card at receipt (13).
 *
 * A loan to an account requires an accepted friendship (1). A loan to a bare
 * name does not, and skips acceptance entirely (3).
 */
CREATE OR REPLACE FUNCTION app_create_loan(
  p_lines          jsonb,
  p_holder_account uuid DEFAULT NULL,
  p_holder_name    text DEFAULT NULL,
  p_note           text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner  uuid := auth.uid();
  v_holder uuid;
  v_loan   uuid;
  v_spec   jsonb;
  i        integer;
BEGIN
  IF v_owner IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'p_lines must be a non-empty array';
  END IF;

  IF p_holder_account IS NOT NULL AND NOT app_is_friend(p_holder_account) THEN
    RAISE EXCEPTION 'you can only lend to an accepted friend'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_holder := app_holder_location(v_owner, p_holder_account, p_holder_name);

  -- A text loan has nobody to accept it, so it starts active (3).
  INSERT INTO loan (lender_account_id, initial_holder_location_id, status, accepted_at, note)
  VALUES (v_owner, v_holder,
          CASE WHEN p_holder_account IS NULL
               THEN 'active'::loan_status ELSE 'pending'::loan_status END,
          CASE WHEN p_holder_account IS NULL THEN now() ELSE NULL END,
          p_note)
  RETURNING id INTO v_loan;

  FOR v_spec IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    IF NOT EXISTS (
      SELECT 1 FROM location
       WHERE id = (v_spec->>'origin_location_id')::uuid
         AND account_id = v_owner AND kind = 'physical'
    ) THEN
      RAISE EXCEPTION 'origin must be your own physical location'
        USING ERRCODE = 'insufficient_privilege';
    END IF;

    FOR i IN 1..coalesce((v_spec->>'qty')::integer, 1) LOOP
      INSERT INTO loan_line (loan_id, edition_id, finish, origin_location_id,
                             departure_condition, holder_location_id)
      VALUES (v_loan,
              (v_spec->>'edition_id')::uuid,
              (v_spec->>'finish')::card_finish,
              (v_spec->>'origin_location_id')::uuid,
              (v_spec->>'condition')::card_condition,
              v_holder);
    END LOOP;
  END LOOP;

  -- A text loan is live immediately, so its cards move now.
  IF p_holder_account IS NULL THEN
    PERFORM app_move_to_holder(v_loan);
  END IF;

  RETURN v_loan;
END $$;

/** Move every line's card out of its origin and into the holder bucket (10). */
CREATE OR REPLACE FUNCTION app_move_to_holder(p_loan uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner uuid;
  r       record;
BEGIN
  SELECT lender_account_id INTO v_owner FROM loan WHERE id = p_loan;

  FOR r IN SELECT * FROM loan_line WHERE loan_id = p_loan AND status = 'outstanding' LOOP
    PERFORM app_bucket_adjust(v_owner, r.edition_id, r.finish,
                              r.origin_location_id, r.departure_condition, -1);
    PERFORM app_bucket_adjust(v_owner, r.edition_id, r.finish,
                              r.holder_location_id, r.departure_condition,  1);
  END LOOP;
END $$;

/** Borrower accepts. Only now does inventory move (2). */
CREATE OR REPLACE FUNCTION app_accept_loan(p_loan uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM loan ln JOIN location loc ON loc.id = ln.initial_holder_location_id
     WHERE ln.id = p_loan AND ln.status = 'pending'
       AND loc.holder_account_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'no pending loan addressed to you'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE loan SET status = 'active', accepted_at = now() WHERE id = p_loan;
  PERFORM app_move_to_holder(p_loan);
END $$;

/** Borrower declines. Nothing ever moved, so nothing unwinds (2). */
CREATE OR REPLACE FUNCTION app_decline_loan(p_loan uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM loan ln JOIN location loc ON loc.id = ln.initial_holder_location_id
     WHERE ln.id = p_loan AND ln.status = 'pending' AND loc.holder_account_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'no pending loan addressed to you'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE loan SET status = 'declined', closed_at = now() WHERE id = p_loan;
  UPDATE loan_line SET status = 'written_off', close_reason = 'force_closed_written_off',
                       closed_at = now()
   WHERE loan_id = p_loan;
END $$;

/** Borrower sends a card back: outstanding -> in_transit (6). */
CREATE OR REPLACE FUNCTION app_mark_returned(p_line uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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
SET search_path = public
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
SET search_path = public
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
-- Sub-loans (18, 19, 20)
-- ---------------------------------------------------------------------------

/** The current holder proposes passing a card on. Recipient may be anyone (20). */
CREATE OR REPLACE FUNCTION app_request_transfer(
  p_line           uuid,
  p_holder_account uuid DEFAULT NULL,
  p_holder_name    text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r      record;
  v_to   uuid;
  v_id   uuid;
BEGIN
  IF NOT app_is_holder_of_line(p_line) THEN
    RAISE EXCEPTION 'you are not holding that card'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT ll.*, ln.lender_account_id INTO r
    FROM loan_line ll JOIN loan ln ON ln.id = ll.loan_id
   WHERE ll.id = p_line;

  IF r.status <> 'outstanding' THEN
    RAISE EXCEPTION 'only an outstanding card can be passed on';
  END IF;

  -- The holder location belongs to the OWNER's namespace, since it is the
  -- owner's inventory that records who has the card.
  v_to := app_holder_location(r.lender_account_id, p_holder_account, p_holder_name);
  IF v_to = r.holder_location_id THEN
    RAISE EXCEPTION 'that person already has it';
  END IF;

  INSERT INTO loan_transfer (loan_line_id, from_location_id, to_location_id,
                             initiated_by_account_id)
  VALUES (p_line, r.holder_location_id, v_to, auth.uid())
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;

/**
 * The owner approves. Responsibility transfers in full (19): the new holder
 * owns the card's return, the previous holder is released, and the transfer
 * row remains as the custody trail.
 */
CREATE OR REPLACE FUNCTION app_approve_transfer(p_transfer uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  t record;
  r record;
BEGIN
  SELECT * INTO t FROM loan_transfer WHERE id = p_transfer AND status = 'pending';
  IF t IS NULL THEN RAISE EXCEPTION 'no pending transfer'; END IF;

  SELECT ll.*, ln.lender_account_id INTO r
    FROM loan_line ll JOIN loan ln ON ln.id = ll.loan_id
   WHERE ll.id = t.loan_line_id;

  PERFORM app_require_lender(r.loan_id);

  PERFORM app_bucket_adjust(r.lender_account_id, r.edition_id, r.finish,
                            t.from_location_id, r.departure_condition, -1);
  PERFORM app_bucket_adjust(r.lender_account_id, r.edition_id, r.finish,
                            t.to_location_id,   r.departure_condition,  1);

  UPDATE loan_line SET holder_location_id = t.to_location_id WHERE id = t.loan_line_id;

  UPDATE loan_transfer
     SET status = 'approved', owner_approved_at = now(), resolved_at = now()
   WHERE id = p_transfer;
END $$;

CREATE OR REPLACE FUNCTION app_reject_transfer(p_transfer uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  t record;
  r record;
BEGIN
  SELECT * INTO t FROM loan_transfer WHERE id = p_transfer AND status = 'pending';
  IF t IS NULL THEN RAISE EXCEPTION 'no pending transfer'; END IF;

  SELECT ll.loan_id INTO r FROM loan_line ll WHERE ll.id = t.loan_line_id;
  PERFORM app_require_lender(r.loan_id);

  UPDATE loan_transfer SET status = 'rejected', resolved_at = now() WHERE id = p_transfer;
END $$;

-- ---------------------------------------------------------------------------
-- Friendship
-- ---------------------------------------------------------------------------

/**
 * Unfriend, refused while either party still holds the other's cards (5).
 *
 * Checked in BOTH directions: you cannot walk away from someone holding your
 * cards, nor from someone whose cards you are holding. Force-close is the way
 * out of the first case; returning is the way out of the second.
 */
CREATE OR REPLACE FUNCTION app_unfriend(p_other uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_me    uuid := auth.uid();
  v_open  integer;
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

  DELETE FROM friendship
   WHERE least(v_me, p_other) = account_lo_id
     AND greatest(v_me, p_other) = account_hi_id;
END $$;

-- ---------------------------------------------------------------------------
-- Grants
--
-- Helpers stay internal; only the operations a signed-in user should be able
-- to invoke are exposed. Supabase's roles are `authenticated` and `anon`.
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  fn text;
  r  text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'app_add_cards(uuid,card_finish,uuid,card_condition,integer)',
    'app_move_cards(uuid,card_finish,uuid,uuid,card_condition,integer)',
    'app_create_loan(jsonb,uuid,text,text)',
    'app_accept_loan(uuid)',
    'app_decline_loan(uuid)',
    'app_mark_returned(uuid)',
    'app_confirm_receipt(uuid,card_condition,uuid)',
    'app_force_close_line(uuid,boolean,card_condition,uuid)',
    'app_request_transfer(uuid,uuid,text)',
    'app_approve_transfer(uuid)',
    'app_reject_transfer(uuid)',
    'app_unfriend(uuid)'
  ] LOOP
    FOREACH r IN ARRAY ARRAY['authenticated', 'app_user'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', fn, r);
      END IF;
    END LOOP;
  END LOOP;
END $$;
