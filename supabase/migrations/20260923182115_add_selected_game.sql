-- Which game's nav/collection an account is currently looking at -- the
-- "Select Your Game" landing page. See db/schema.sql and db/auth_bridge.sql
-- for the full rationale comments.

ALTER TABLE account
  ADD COLUMN selected_game_id uuid REFERENCES game(id) ON DELETE SET NULL;

CREATE OR REPLACE FUNCTION app_provision_account()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  -- Defaults to whichever game was created first. There is only one today,
  -- so this is unambiguous; once a second exists, a new signup should
  -- presumably land on the game-selection landing page instead, not silently
  -- pick one -- revisit this the day that matters.
  INSERT INTO account (id, email, display_name, selected_game_id)
  VALUES (
    NEW.id,
    NEW.email,
    coalesce(
      nullif(btrim(NEW.raw_user_meta_data ->> 'display_name'), ''),
      nullif(btrim(NEW.raw_user_meta_data ->> 'full_name'), ''),
      nullif(btrim(NEW.raw_user_meta_data ->> 'name'), ''),
      nullif(split_part(coalesce(NEW.email, ''), '@', 1), ''),
      'Player'
    ),
    (SELECT id FROM game ORDER BY created_at LIMIT 1)
  )
  ON CONFLICT (id) DO NOTHING;

  -- Somewhere to put cards, from the first second (34). Without it the first
  -- thing a new user meets is "you need a box first", which is a chore standing
  -- between them and the thing they came to do.
  --
  -- Named rather than special: it is an ordinary physical location, so it can
  -- be renamed or deleted like any other.
  INSERT INTO location (account_id, kind, name)
  VALUES (NEW.id, 'physical', 'Unsorted')
  ON CONFLICT DO NOTHING;

  RETURN NEW;
END $$;

-- Every existing account predates this column -- give them the same default
-- a fresh signup gets, rather than leaving them stuck on the selection page.
UPDATE account SET selected_game_id = (SELECT id FROM game ORDER BY created_at LIMIT 1)
 WHERE selected_game_id IS NULL;

CREATE OR REPLACE FUNCTION app_set_selected_game(p_game uuid) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  IF NOT EXISTS (SELECT 1 FROM game WHERE id = p_game) THEN
    RAISE EXCEPTION 'unknown game';
  END IF;

  UPDATE account SET selected_game_id = p_game, updated_at = now()
   WHERE id = auth.uid();
END $$;

DO $$
DECLARE fn text; r text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'app_set_selected_game(uuid)'
  ] LOOP
    FOREACH r IN ARRAY ARRAY['authenticated', 'app_user'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', fn, r);
      END IF;
    END LOOP;
  END LOOP;
END $$;
