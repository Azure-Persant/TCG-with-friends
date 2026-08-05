-- Links Supabase Auth to our own `account` table.
--
--   psql -d fci -v ON_ERROR_STOP=1 -f db/auth_bridge.sql
--
-- Load AFTER schema.sql. On Supabase this runs against the real auth.users;
-- locally it runs against the stand-in in db/local/auth_shim.sql, which is why
-- it only touches the three columns both versions genuinely share.
--
-- WHY THIS FILE EXISTS
--
-- Every policy in this project compares something to auth.uid(), which returns
-- the id of a row in auth.users. Every one of those comparisons is against an
-- account_id. So `account.id` MUST equal `auth.users.id` -- not "should", or
-- the entire privacy model silently matches nothing and every friend list,
-- every inventory and every inbox comes back empty.
--
-- That is a single point of failure with no natural error message, so it gets
-- its own file, its own trigger and its own test.

-- ---------------------------------------------------------------------------
-- Provisioning
-- ---------------------------------------------------------------------------

/**
 * Create the app-side account when someone signs up.
 *
 * Display name falls back through the metadata a provider might supply, then
 * to the local part of the email. It is NOT NULL in the schema and users see
 * each other by it, so it can never be left empty -- an account with a blank
 * name is invisible in a friend list.
 */
CREATE OR REPLACE FUNCTION app_provision_account()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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

  RETURN NEW;
END $$;

/**
 * Keep the email in step if the user changes it in Supabase Auth.
 *
 * Only the email. display_name is the user's to edit in the app, and
 * overwriting their chosen name with provider metadata on every auth update
 * would quietly undo it.
 */
CREATE OR REPLACE FUNCTION app_sync_account_email()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.email IS DISTINCT FROM OLD.email AND NEW.email IS NOT NULL THEN
    UPDATE account SET email = NEW.email, updated_at = now() WHERE id = NEW.id;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION app_provision_account();

DROP TRIGGER IF EXISTS on_auth_user_email_changed ON auth.users;
CREATE TRIGGER on_auth_user_email_changed
  AFTER UPDATE OF email ON auth.users
  FOR EACH ROW EXECUTE FUNCTION app_sync_account_email();

-- ---------------------------------------------------------------------------
-- What happens when an auth user is deleted
-- ---------------------------------------------------------------------------
--
-- Nothing, deliberately. There is NO foreign key from account.id to
-- auth.users.id, and no delete trigger.
--
-- A cascade would be the obvious thing to write and it would be wrong. Account
-- deletion would tear through friendship, location, holding and loan, and (5)
-- exists precisely to stop a relationship being dissolved while cards are
-- still outstanding between two people. A cascade drives straight past that
-- check: your friend deletes their login and the record of who has your cards
-- goes with it.
--
-- So an orphaned account row is the intended outcome. It keeps the loan
-- history intact for the person still owed cards. Reaping those rows is a
-- deliberate operation for later, and it must refuse while custody is open --
-- the same rule app_unfriend() already enforces.

-- ---------------------------------------------------------------------------
-- Backfill
-- ---------------------------------------------------------------------------
--
-- Idempotent, so this file stays safe to re-apply. Also covers anyone who
-- signed up between the project starting and this trigger existing.

INSERT INTO account (id, email, display_name)
SELECT u.id,
       u.email,
       coalesce(
         nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''),
         nullif(btrim(u.raw_user_meta_data ->> 'full_name'), ''),
         nullif(btrim(u.raw_user_meta_data ->> 'name'), ''),
         nullif(split_part(coalesce(u.email, ''), '@', 1), ''),
         'Player')
  FROM auth.users u
 WHERE u.email IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM account a WHERE a.id = u.id)
   AND NOT EXISTS (SELECT 1 FROM account a WHERE a.email = u.email);
