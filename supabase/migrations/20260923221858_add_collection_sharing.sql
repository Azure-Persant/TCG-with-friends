-- ---------------------------------------------------------------------------
-- Collection sharing: a read-only public link (22)
-- ---------------------------------------------------------------------------

-- An open link, not an invite: the token is the only credential. No
-- invited-email restriction (unlike the retired Softgen app's version of
-- this) -- the issue asked for a public link, and a signed-in-only
-- restriction is a different feature with its own auth questions, deferred
-- rather than guessed at.
--
-- One account may hold several of these (a "playgroup" link and a "for
-- sale" link, say) since nothing here scopes WHICH cards a share shows --
-- every share exposes the same view of the owner's whole physical
-- collection (see shared_collection below). Per-share scoping is exactly
-- the kind of unexercised, half-built option this project avoids adding
-- before there is a second use for it.
CREATE TABLE collection_share (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id  uuid NOT NULL REFERENCES account(id) ON DELETE CASCADE,

  -- Two random uuids, hyphens stripped: 64 hex characters, ~244 bits of
  -- entropy -- not enumerable. gen_random_uuid() rather than pgcrypto's
  -- gen_random_bytes, which is not in the default search_path on Supabase
  -- and would make this depend on where that extension happens to live.
  token       text NOT NULL UNIQUE DEFAULT
    replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),

  label       text,
  created_at  timestamptz NOT NULL DEFAULT now(),

  -- Both NULL by default: no expiry unless the owner sets one, live unless
  -- revoked. Revoked rather than deleted on the common path, so the row
  -- stays as a record of the grant; app_delete_collection_share still exists
  -- for actually removing it.
  expires_at  timestamptz,
  revoked_at  timestamptz
);

CREATE INDEX collection_share_account_idx ON collection_share (account_id);

ALTER TABLE collection_share ENABLE ROW LEVEL SECURITY;

-- SELECT only, same shape as deck_own: app_create/revoke/delete_collection_
-- share are the only way to write this table. A guest viewing a shared
-- collection never reads this table directly either -- shared_collection
-- and shared_collection_meta resolve the token through a SECURITY DEFINER
-- helper instead, so this policy only ever needs to answer for the owner.
CREATE POLICY collection_share_own ON collection_share
  FOR SELECT USING (account_id = auth.uid());

/**
 * Create a share link. Returns the whole row, including the token, so the
 * caller has the link immediately without a second read.
 */
CREATE OR REPLACE FUNCTION app_create_collection_share(
  p_label text DEFAULT NULL, p_expires_at timestamptz DEFAULT NULL
) RETURNS collection_share
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_row collection_share;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  INSERT INTO collection_share (account_id, label, expires_at)
  VALUES (auth.uid(), nullif(btrim(p_label), ''), p_expires_at)
  RETURNING * INTO v_row;

  RETURN v_row;
END $$;

/** Revoked rather than deleted by default (see the table comment): the row
 *  stays as a record of the grant, but the link stops working immediately. */
CREATE OR REPLACE FUNCTION app_revoke_collection_share(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  UPDATE collection_share SET revoked_at = now()
   WHERE id = p_id AND account_id = auth.uid();
  IF NOT FOUND THEN RAISE EXCEPTION 'no such share'; END IF;
END $$;

/** Actually removes the row, unlike revoke -- for tidying up old links. */
CREATE OR REPLACE FUNCTION app_delete_collection_share(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  DELETE FROM collection_share WHERE id = p_id AND account_id = auth.uid();
  IF NOT FOUND THEN RAISE EXCEPTION 'no such share'; END IF;
END $$;

/**
 * Resolve a token to a usable share, or nothing.
 *
 * Returns no row when the token is unknown, revoked or expired -- callers
 * cannot tell those apart, same discipline as app_require_recipient: a wrong
 * token and a dead one must look identical to whoever is guessing.
 *
 * Internal only -- not GRANTed. The two functions below are themselves
 * SECURITY DEFINER, so a nested call here runs as this function's owner
 * regardless of who is calling them.
 */
CREATE OR REPLACE FUNCTION app_resolve_collection_share(p_token text)
RETURNS collection_share
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT * FROM collection_share
   WHERE token = p_token
     AND revoked_at IS NULL
     AND (expires_at IS NULL OR expires_at > now())
  LIMIT 1;
$$;

/** Header information for a shared collection page. */
CREATE OR REPLACE FUNCTION shared_collection_meta(p_token text)
RETURNS TABLE (owner_name text, label text, created_at timestamptz, expires_at timestamptz)
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT a.display_name, s.label, s.created_at, s.expires_at
    FROM app_resolve_collection_share(p_token) s
    JOIN account a ON a.id = s.account_id;
$$;

/**
 * The shared holdings themselves -- name, quantity, finish and condition,
 * with copies out on loan broken out as their own count rather than folded
 * into the total. Never a location, and never who is holding a loaned
 * copy: (14)'s privacy rule applies here at least as strictly as it does to
 * friends.
 *
 * Grouped the same way friend_visible_holding is (by edition, finish and
 * condition, summed across every location of the relevant kind) -- this is
 * a public link rather than a friendship, so it is resolved by token
 * through app_resolve_collection_share instead of a friendship/game_share
 * join, but the privacy shape is identical. A holding row only ever exists
 * with qty > 0 (an invariant enforced elsewhere), so every group here is
 * guaranteed to have something in it -- no HAVING needed to hide empties.
 */
CREATE OR REPLACE FUNCTION shared_collection(p_token text)
RETURNS TABLE (
  edition_id        uuid,
  card_name         text,
  set_name          text,
  collector_number  text,
  image_storage_key text,
  finish            card_finish,
  condition         card_condition,
  qty_owned         integer,
  qty_on_loan       integer
)
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT
    h.edition_id,
    c.name,
    cs.name,
    ce.collector_number,
    (SELECT ci.storage_key FROM card_image ci
      WHERE ci.edition_id = h.edition_id AND ci.variant = 'original' LIMIT 1),
    h.finish,
    h.condition,
    coalesce(sum(h.qty) FILTER (WHERE l.kind = 'physical'), 0)::integer,
    coalesce(sum(h.qty) FILTER (WHERE l.kind = 'holder'),   0)::integer
  FROM app_resolve_collection_share(p_token) s
    JOIN holding      h  ON h.account_id = s.account_id
    JOIN location     l  ON l.id = h.location_id
    JOIN card_edition ce ON ce.id = h.edition_id
    JOIN card         c  ON c.id = ce.card_id
    JOIN card_set     cs ON cs.id = ce.set_id
  GROUP BY h.edition_id, c.name, cs.name, ce.collector_number, h.finish, h.condition
  ORDER BY c.name, ce.collector_number;
$$;

DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['authenticated', 'app_user'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION app_create_collection_share(text,timestamptz) TO %I', r);
      EXECUTE format('GRANT EXECUTE ON FUNCTION app_revoke_collection_share(uuid) TO %I', r);
      EXECUTE format('GRANT EXECUTE ON FUNCTION app_delete_collection_share(uuid) TO %I', r);
    END IF;
  END LOOP;
END $$;

DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'app_user'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION shared_collection_meta(text) TO %I', r);
      EXECUTE format('GRANT EXECUTE ON FUNCTION shared_collection(text) TO %I', r);
    END IF;
  END LOOP;
END $$;
