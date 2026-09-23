-- Enforced here as well as in app_set_display_name (40), same reasoning as
-- the username shape check below: a name is shown to friends often enough
-- that a blank or absurdly long one should be impossible to store.
ALTER TABLE account
  ADD CONSTRAINT account_display_name_shape CHECK (
    length(btrim(display_name)) BETWEEN 1 AND 60);

/**
 * Change your display name (40) -- unlike username (33), there is no
 * uniqueness rule and no one-time welcome-flow restriction; this is just
 * editing a value, so the function is nearly all validation.
 */
CREATE OR REPLACE FUNCTION app_set_display_name(p_display_name text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_clean text := btrim(p_display_name);
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  IF length(v_clean) NOT BETWEEN 1 AND 60 THEN
    RAISE EXCEPTION 'A display name must be 1 to 60 characters.'
      USING ERRCODE = 'check_violation';
  END IF;

  UPDATE account SET display_name = v_clean, updated_at = now()
   WHERE id = auth.uid();
END $$;

DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'app_user'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION app_set_display_name(text) TO %I', r);
    END IF;
  END LOOP;
END $$;

-- Dropped and recreated, not CREATE OR REPLACE: Postgres refuses to change
-- an existing function's RETURNS TABLE column list in place, and `restricted`
-- (39) is a new one.
DROP FUNCTION IF EXISTS search_card_editions(
  text, text[], text[], text[], text[], integer, integer, integer, integer, integer);

CREATE FUNCTION search_card_editions(
  p_query         text    DEFAULT NULL,
  p_elements      text[]  DEFAULT NULL,
  p_types         text[]  DEFAULT NULL,
  p_subtypes      text[]  DEFAULT NULL,
  p_classes       text[]  DEFAULT NULL,
  p_cost_memory_min  integer DEFAULT NULL,
  p_cost_memory_max  integer DEFAULT NULL,
  p_cost_reserve_min integer DEFAULT NULL,
  p_cost_reserve_max integer DEFAULT NULL,
  p_limit         integer DEFAULT 40
)
RETURNS TABLE (
  edition_id         uuid,
  collector_number    text,
  card_name           text,
  set_name            text,
  set_prefix          text,
  finishes             text[],
  image_storage_key    text,
  element              text,
  types                text[],
  subtypes             text[],
  classes              text[],
  restricted           boolean
)
LANGUAGE sql STABLE AS $$
  SELECT
    ce.id,
    ce.collector_number,
    c.name,
    cs.name,
    cs.prefix,
    array(SELECT f.finish::text FROM card_edition_finish f WHERE f.edition_id = ce.id),
    (SELECT ci.storage_key FROM card_image ci
      WHERE ci.edition_id = ce.id AND ci.variant = 'original' LIMIT 1),
    c.attributes ->> 'element',
    array(SELECT jsonb_array_elements_text(coalesce(c.attributes -> 'types', '[]'::jsonb))),
    array(SELECT jsonb_array_elements_text(coalesce(c.attributes -> 'subtypes', '[]'::jsonb))),
    array(SELECT jsonb_array_elements_text(coalesce(c.attributes -> 'classes', '[]'::jsonb))),
    -- Same field app_set_deck_card already enforces on (n. in the invariants
    -- list below) -- limit 0 is the only value seen in the live catalog today
    -- (see HANDOFF.md, #8), but this reads "= 0" rather than "IS NOT NULL" so
    -- a future non-zero restriction (fewer than 4 copies allowed, say) does
    -- not silently start showing the full-ban badge on a merely-limited card.
    (c.attributes -> 'legality' -> 'STANDARD' ->> 'limit') = '0'
  FROM card_edition ce
    JOIN card     c  ON c.id = ce.card_id
    JOIN card_set cs ON cs.id = ce.set_id
  WHERE (p_query IS NULL OR c.name ILIKE '%' || p_query || '%')
    AND (p_elements IS NULL OR (c.attributes ->> 'element') = ANY (p_elements))
    AND (p_types IS NULL OR EXISTS (
          SELECT 1 FROM jsonb_array_elements_text(coalesce(c.attributes -> 'types', '[]'::jsonb)) t
           WHERE t = ANY (p_types)))
    AND (p_subtypes IS NULL OR EXISTS (
          SELECT 1 FROM jsonb_array_elements_text(coalesce(c.attributes -> 'subtypes', '[]'::jsonb)) t
           WHERE t = ANY (p_subtypes)))
    AND (p_classes IS NULL OR EXISTS (
          SELECT 1 FROM jsonb_array_elements_text(coalesce(c.attributes -> 'classes', '[]'::jsonb)) t
           WHERE t = ANY (p_classes)))
    AND (p_cost_memory_min IS NULL OR (c.attributes ->> 'cost_memory')::numeric >= p_cost_memory_min)
    AND (p_cost_memory_max IS NULL OR (c.attributes ->> 'cost_memory')::numeric <= p_cost_memory_max)
    AND (p_cost_reserve_min IS NULL OR (c.attributes ->> 'cost_reserve')::numeric >= p_cost_reserve_min)
    AND (p_cost_reserve_max IS NULL OR (c.attributes ->> 'cost_reserve')::numeric <= p_cost_reserve_max)
  ORDER BY c.name, ce.collector_number
  LIMIT p_limit;
$$;

DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'app_user'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION search_card_editions TO %I', r);
    END IF;
  END LOOP;
END $$;
