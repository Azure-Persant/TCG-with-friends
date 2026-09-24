-- The printing whose art represents the deck on /decks (#32). NULL means
-- no art chosen -- the tile falls back to an icon. SET NULL, not
-- RESTRICT: a catalog edition disappearing should cost the deck its
-- picture, not block the ingest.
ALTER TABLE deck
  ADD COLUMN cover_edition_id uuid REFERENCES card_edition(id) ON DELETE SET NULL;

/**
 * Pick the printing whose art represents the deck (#32), or NULL to clear it.
 *
 * Any printing of any card currently in the deck is allowed -- choosing
 * between alternate arts of one card is as much the point as choosing
 * between cards. Checked by card, not by the exact edition in the deck.
 *
 * Only checked at the moment of choosing: removing that card from the deck
 * later leaves the cover in place rather than silently clearing it. Leaves
 * updated_at alone, since /decks sorts by it and a new picture is not a
 * change to the deck itself.
 */
CREATE OR REPLACE FUNCTION app_set_deck_cover(p_deck uuid, p_edition uuid) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM deck WHERE id = p_deck AND account_id = auth.uid()) THEN
    RAISE EXCEPTION 'not your deck' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_edition IS NOT NULL AND NOT EXISTS (
    SELECT 1
      FROM deck_card dc
      JOIN card_edition in_deck ON in_deck.id = dc.edition_id
      JOIN card_edition chosen  ON chosen.card_id = in_deck.card_id
     WHERE dc.deck_id = p_deck AND chosen.id = p_edition
  ) THEN
    RAISE EXCEPTION 'the cover must be a printing of a card in this deck';
  END IF;

  UPDATE deck SET cover_edition_id = p_edition WHERE id = p_deck;
END $$;

DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['authenticated', 'app_user'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION app_set_deck_cover(uuid,uuid) TO %I', r);
    END IF;
  END LOOP;
END $$;
