-- Usernames (33), and a default "Unsorted" box for everyone (34).
--
-- Safe to run more than once: every statement checks first. Safe to run on a
-- database with data: nothing here drops or rewrites a row.

-- ---------------------------------------------------------------------------
-- account.username (33)
-- ---------------------------------------------------------------------------

ALTER TABLE account ADD COLUMN IF NOT EXISTS username citext;

DO $$ BEGIN
  ALTER TABLE account ADD CONSTRAINT account_username_key UNIQUE (username);
EXCEPTION WHEN duplicate_table OR duplicate_object THEN
  NULL;
END $$;

DO $$ BEGIN
  ALTER TABLE account ADD CONSTRAINT account_username_shape CHECK (
    username IS NULL OR username ~ '^[A-Za-z0-9][A-Za-z0-9_-]{2,19}$');
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;

-- Deliberately NOT backfilled from the email local part.
--
-- A username is a public handle people will type at each other, and one
-- derived from an email address leaks the address and is rarely what the
-- person would have chosen. Existing accounts keep NULL, and the app asks
-- them to pick one on next sign-in.

-- ---------------------------------------------------------------------------
-- Everyone gets somewhere to put cards (34)
-- ---------------------------------------------------------------------------

-- Only for accounts with NO physical location at all. Someone who already
-- named their own boxes does not want an empty "Unsorted" appearing among
-- them.
INSERT INTO location (account_id, kind, name)
SELECT a.id, 'physical', 'Unsorted'
  FROM account a
 WHERE NOT EXISTS (
   SELECT 1 FROM location l
    WHERE l.account_id = a.id AND l.kind = 'physical'
 );

-- ---------------------------------------------------------------------------
-- The functions and trigger that keep both true going forward
-- ---------------------------------------------------------------------------
--
-- CREATE OR REPLACE / DROP + CREATE, so this half is safe to re-run too, and
-- matches db/functions.sql and db/auth_bridge.sql exactly -- see decision 33
-- and 34 in docs/design/friends-and-loans.md, and db/README.md, "Changing the
-- schema" for why both a migration and the schema files carry this.

CREATE OR REPLACE FUNCTION app_provision_account()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  INSERT INTO account (id, email, display_name)
  VALUES (
    NEW.id,
    NEW.email,
    coalesce(
      nullif(btrim(NEW.raw_user_meta_data ->> 'display_name'), ''),
      nullif(btrim(NEW.raw_user_meta_data ->> 'full_name'), ''),
      nullif(btrim(NEW.raw_user_meta_data ->> 'name'), ''),
      nullif(split_part(coalesce(NEW.email, ''), '@', 1), ''),
      'Player'
    )
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

-- ---------------------------------------------------------------------------
-- Did it work?
-- ---------------------------------------------------------------------------

SELECT * FROM (
  SELECT 1 AS n, 'username column exists' AS check_name,
         CASE WHEN EXISTS (
           SELECT 1 FROM information_schema.columns
            WHERE table_name = 'account' AND column_name = 'username')
         THEN 'PASS' ELSE 'FAIL' END AS result,
         '' AS detail

  UNION ALL
  SELECT 2, 'usernames are unique and case-insensitive',
         CASE WHEN EXISTS (
           SELECT 1 FROM pg_constraint
            WHERE conname = 'account_username_key' AND contype = 'u')
         THEN 'PASS' ELSE 'FAIL' END,
         'citext, so Jon and jon cannot both be claimed'

  UNION ALL
  SELECT 3, 'every account can file a card',
         CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
         CASE WHEN count(*) = 0 THEN 'all have somewhere to put cards'
              ELSE count(*) || ' account(s) still have no physical location' END
    FROM account a
   WHERE NOT EXISTS (SELECT 1 FROM location l
                      WHERE l.account_id = a.id AND l.kind = 'physical')

  UNION ALL
  SELECT 4, 'accounts still needing a username',
         'INFO',
         count(*) || ' — they will be asked on next sign-in'
    FROM account WHERE username IS NULL
) checks
ORDER BY n;
