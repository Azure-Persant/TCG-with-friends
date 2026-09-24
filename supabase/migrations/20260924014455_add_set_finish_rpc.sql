/**
 * Recategorise copies from one finish to another, same card and same box
 * (29 follow-up) -- "these turned out to be foil, not nonfoil." The
 * finish-axis sibling of app_set_condition above and app_move_cards
 * further up: one axis moves per call, never two at once.
 *
 * The composite FK (edition_id, finish) -> card_edition_finish does the
 * validation here -- setting a finish the edition was never printed in
 * fails on that constraint, same as app_add_cards relies on it today.
 */
CREATE OR REPLACE FUNCTION app_set_finish(
  p_edition     uuid,
  p_location    uuid,
  p_condition   card_condition,
  p_from_finish card_finish,
  p_to_finish   card_finish,
  p_qty         integer
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF p_qty <= 0 THEN RAISE EXCEPTION 'qty must be positive'; END IF;
  IF p_from_finish = p_to_finish THEN
    RAISE EXCEPTION 'source and destination finish are the same';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM location
     WHERE id = p_location AND account_id = auth.uid() AND kind = 'physical'
  ) THEN
    RAISE EXCEPTION 'not your physical location'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  PERFORM app_bucket_adjust(auth.uid(), p_edition, p_from_finish, p_location, p_condition, -p_qty);
  PERFORM app_bucket_adjust(auth.uid(), p_edition, p_to_finish,   p_location, p_condition,  p_qty);
END $$;

DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['authenticated', 'app_user'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION app_set_finish(uuid,uuid,card_condition,card_finish,card_finish,integer) TO %I', r);
    END IF;
  END LOOP;
END $$;
