-- Server-side catalog filtering for /cards and /add (issue #20). See
-- db/schema.sql for the full rationale comments.

CREATE VIEW card_filter_options AS
SELECT 'element' AS kind, c.attributes ->> 'element' AS value, count(DISTINCT c.id) AS count
  FROM card c
 WHERE c.attributes ->> 'element' IS NOT NULL
 GROUP BY c.attributes ->> 'element'
UNION ALL
SELECT 'type', t, count(DISTINCT c.id)
  FROM card c, jsonb_array_elements_text(coalesce(c.attributes -> 'types', '[]'::jsonb)) t
 GROUP BY t
UNION ALL
SELECT 'subtype', t, count(DISTINCT c.id)
  FROM card c, jsonb_array_elements_text(coalesce(c.attributes -> 'subtypes', '[]'::jsonb)) t
 GROUP BY t
UNION ALL
SELECT 'class', t, count(DISTINCT c.id)
  FROM card c, jsonb_array_elements_text(coalesce(c.attributes -> 'classes', '[]'::jsonb)) t
 GROUP BY t;

CREATE OR REPLACE FUNCTION search_card_editions(
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
  classes              text[]
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
    array(SELECT jsonb_array_elements_text(coalesce(c.attributes -> 'classes', '[]'::jsonb)))
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
