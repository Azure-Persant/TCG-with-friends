-- Deck builder (issue #21). See db/schema.sql and db/functions.sql for the
-- full rationale comments.

CREATE TYPE deck_section AS ENUM ('material', 'main', 'sideboard');

CREATE TABLE deck (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id  uuid NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  name        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX deck_account_idx ON deck (account_id);

CREATE TABLE deck_card (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  deck_id     uuid NOT NULL REFERENCES deck(id) ON DELETE CASCADE,
  edition_id  uuid NOT NULL REFERENCES card_edition(id) ON DELETE RESTRICT,
  section     deck_section NOT NULL,
  finish      card_finish NOT NULL DEFAULT 'NONFOIL',
  qty         integer NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT deck_card_qty_positive CHECK (qty > 0),

  FOREIGN KEY (edition_id, finish)
    REFERENCES card_edition_finish (edition_id, finish) ON DELETE RESTRICT,

  UNIQUE (deck_id, edition_id, section, finish)
);

CREATE INDEX deck_card_deck_idx    ON deck_card (deck_id);
CREATE INDEX deck_card_edition_idx ON deck_card (edition_id);

ALTER TABLE deck      ENABLE ROW LEVEL SECURITY;
ALTER TABLE deck_card ENABLE ROW LEVEL SECURITY;

CREATE POLICY deck_own ON deck
  FOR SELECT USING (account_id = auth.uid());

CREATE POLICY deck_card_own ON deck_card
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM deck d WHERE d.id = deck_card.deck_id AND d.account_id = auth.uid())
  );

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

DO $$
DECLARE fn text; r text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
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
