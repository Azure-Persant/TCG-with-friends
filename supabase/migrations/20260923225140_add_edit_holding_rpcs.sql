/**
 * Set one exact bucket's quantity directly (29) -- fixes a miscount, or
 * accounts for cards that left the system outside the loan/trade flow
 * (given away in person, lost, etc). Absolute, like app_set_deck_card, not
 * a delta: the caller states what the count should now be, and
 * app_bucket_adjust works out the insert/update/delete from there.
 *
 * qty = 0 deletes the row outright -- removing a holding can never break a
 * rule, so it is never worth rejecting, same reasoning as a deck card.
 */
CREATE OR REPLACE FUNCTION app_set_holding(
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
DECLARE v_current integer;
BEGIN
  IF p_qty < 0 THEN RAISE EXCEPTION 'qty cannot be negative'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM location
     WHERE id = p_location AND account_id = auth.uid() AND kind = 'physical'
  ) THEN
    RAISE EXCEPTION 'not your physical location'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT qty INTO v_current FROM holding
   WHERE account_id = auth.uid() AND edition_id = p_edition AND finish = p_finish
     AND location_id = p_location AND condition = p_condition;

  PERFORM app_bucket_adjust(auth.uid(), p_edition, p_finish, p_location, p_condition,
                            p_qty - coalesce(v_current, 0));
END $$;

/**
 * Recategorise copies from one condition to another, same card and same box
 * (29) -- "these five turned out to be Lightly Played, not Near Mint."
 * Deliberately the condition-axis sibling of app_move_cards above, not a
 * combined move-and-relabel: changing location too is a second, separate
 * call, matching the same one-axis-at-a-time shape.
 */
CREATE OR REPLACE FUNCTION app_set_condition(
  p_edition        uuid,
  p_finish         card_finish,
  p_location       uuid,
  p_from_condition card_condition,
  p_to_condition   card_condition,
  p_qty            integer
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF p_qty <= 0 THEN RAISE EXCEPTION 'qty must be positive'; END IF;
  IF p_from_condition = p_to_condition THEN
    RAISE EXCEPTION 'source and destination condition are the same';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM location
     WHERE id = p_location AND account_id = auth.uid() AND kind = 'physical'
  ) THEN
    RAISE EXCEPTION 'not your physical location'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  PERFORM app_bucket_adjust(auth.uid(), p_edition, p_finish, p_location, p_from_condition, -p_qty);
  PERFORM app_bucket_adjust(auth.uid(), p_edition, p_finish, p_location, p_to_condition,    p_qty);
END $$;

DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['authenticated', 'app_user'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION app_set_holding(uuid,card_finish,uuid,card_condition,integer) TO %I', r);
      EXECUTE format('GRANT EXECUTE ON FUNCTION app_set_condition(uuid,card_finish,uuid,card_condition,card_condition,integer) TO %I', r);
    END IF;
  END LOOP;
END $$;
