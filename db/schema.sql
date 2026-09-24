-- friends-card-inventory — PostgreSQL schema (draft)
--
-- Implements docs/design/friends-and-loans.md. Parenthesised numbers in
-- comments — e.g. (14) — refer to numbered decisions in that document.
--
-- Requires PostgreSQL 13+ (uses gen_random_uuid, num_nonnulls, FILTER).

-- On Supabase these are usually already installed, into the `extensions`
-- schema rather than public. IF NOT EXISTS makes that a no-op, and every
-- SECURITY DEFINER function pins `search_path = public, extensions` so their
-- operators still resolve. Do not narrow that back to `public` alone --
-- citext comparisons inside those functions would stop resolving, and the
-- failure looks like a type error a long way from here.
CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS pg_trgm;   -- fuzzy card-name search
CREATE EXTENSION IF NOT EXISTS citext;    -- case-insensitive email

-- ---------------------------------------------------------------------------
-- Enums

-- ---------------------------------------------------------------------------

-- Physical grading scale. Part of the holding bucket key (8).
CREATE TYPE card_condition AS ENUM ('MINT', 'NM', 'LP', 'MP', 'HP', 'DMG');

-- Verified against api.gatcg.com: circulationTemplates.kind is only ever
-- FOIL or NONFOIL, mapping 1:1 to the boolean `foil` flag (21).
CREATE TYPE card_finish AS ENUM ('NONFOIL', 'FOIL');

-- A location is either somewhere you keep cards, or somebody who has them.
-- "On loan" is NOT a value here — it is derived from kind = 'holder'.
CREATE TYPE location_kind AS ENUM ('physical', 'holder');

-- Every pending approval in the app is a `request` row (23). Friendship,
-- loans, borrows, trades and sub-loan transfers all share this one lifecycle.
CREATE TYPE request_kind AS ENUM (
  'friend',          -- be my friend (1)
  'loan_offer',      -- I am lending you these (2)
  'borrow_request',  -- may I borrow these? (28)
  'trade_offer',     -- swap these for those (24)
  'sub_loan'         -- may I pass this on to someone else? (18)
);

CREATE TYPE request_status AS ENUM (
  'pending',
  'accepted',
  'declined',
  'cancelled',    -- withdrawn by the proposer
  'superseded'    -- replaced by a counter-offer (25)
);

-- Note the absence of 'pending' and 'declined'. A loan that has not been
-- accepted yet is a request, not a loan -- it has no row here at all, which is
-- what makes "a pending loan moves no inventory" (2) structurally true rather
-- than a rule someone has to remember to enforce.
CREATE TYPE loan_status AS ENUM ('active', 'cancelled', 'closed');

CREATE TYPE trade_status AS ENUM ('settling', 'completed', 'closed');

-- A trade moves one physical card between two accounts (24).
CREATE TYPE trade_item_status AS ENUM ('in_transit', 'received', 'written_off');

CREATE TYPE loan_line_status AS ENUM ('outstanding', 'in_transit', 'returned', 'written_off');

CREATE TYPE loan_close_reason AS ENUM (
  'returned_confirmed',        -- normal two-step return (6)
  'force_closed_returned',     -- lender's escape hatch, card is back (5, 15)
  'force_closed_written_off'   -- lender's escape hatch, card is gone (5, 15)
);

CREATE TYPE sync_status AS ENUM ('running', 'succeeded', 'failed');

-- A deck's three lists (issue #21), per the Standard Constructed rules at
-- https://rules.gatcg.com/general-rules/general-rules-format-conventions.
CREATE TYPE deck_section AS ENUM ('material', 'main', 'sideboard');

-- ===========================================================================
-- CATALOG (12, 16)
--
-- Global and shared. Users never write here; they reference it. Ingested per
-- game from an upstream source — Grand Archive via api.gatcg.com first.
-- ===========================================================================

CREATE TABLE game (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug        text NOT NULL UNIQUE,          -- 'grand-archive'
  name        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE card_set (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  game_id       uuid NOT NULL REFERENCES game(id) ON DELETE CASCADE,
  external_id   text NOT NULL,               -- GATCG set.id
  prefix        text NOT NULL,               -- 'HVN'
  name          text NOT NULL,               -- 'Abyssal Heaven'
  language      text NOT NULL DEFAULT 'EN',
  release_date  date,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (game_id, external_id)
);

-- The abstract card: rules text, name, stats. Printing-independent.
CREATE TABLE card (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  game_id        uuid NOT NULL REFERENCES game(id) ON DELETE CASCADE,
  external_uuid  text NOT NULL,              -- GATCG card.uuid
  slug           text NOT NULL,
  name           text NOT NULL,
  -- Game-specific fields live here rather than as columns, so a second game
  -- with a different stat line needs no migration. For Grand Archive:
  -- element, elements, classes, types, subtypes, cost_memory, cost_reserve,
  -- level, power, life, durability, speed, effect_raw, effect_html, legality.
  attributes     jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (game_id, external_uuid),
  UNIQUE (game_id, slug)
);

CREATE INDEX card_name_trgm_idx ON card USING gin (lower(name) gin_trgm_ops);
CREATE INDEX card_attributes_idx ON card USING gin (attributes);

-- A specific printing. GATCG averages ~2.86 of these per card (16, 21).
CREATE TABLE card_edition (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  card_id            uuid NOT NULL REFERENCES card(id) ON DELETE CASCADE,
  set_id             uuid NOT NULL REFERENCES card_set(id) ON DELETE RESTRICT,
  external_uuid      text NOT NULL UNIQUE,   -- GATCG edition.uuid, also the image key
  slug               text NOT NULL,          -- 'arcane-blast-hvn'
  collector_number   text NOT NULL,          -- text: leading zeros and suffixes exist
  rarity             smallint,
  illustrator        text,
  orientation        text,
  configuration      text,
  source_image_path  text,                   -- '/cards/images/{uuid}.jpg' upstream
  attributes         jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (card_id, slug)
);

CREATE INDEX card_edition_card_idx ON card_edition (card_id);
CREATE INDEX card_edition_set_idx  ON card_edition (set_id);

-- Which finishes actually exist for a printing, from circulationTemplates.
--
-- INGEST RULE: ~13% of editions (72 of 538 sampled) return no circulation
-- templates at all. The ingest MUST seed a NONFOIL row for those, otherwise
-- the composite FK below makes their cards impossible to add to an inventory.
CREATE TABLE card_edition_finish (
  edition_id           uuid NOT NULL REFERENCES card_edition(id) ON DELETE CASCADE,
  finish               card_finish NOT NULL,
  external_uuid        text,                 -- circulationTemplate.uuid
  label                text,                 -- 'HVN Common Foil'
  population           bigint,
  population_operator  text,                 -- '≈'
  is_seeded            boolean NOT NULL DEFAULT false,  -- true = inferred, not upstream
  PRIMARY KEY (edition_id, finish)
);

-- Self-hosted images (17, 22). Pre-fetched in full at ingest: ~6,400 editions,
-- ~1.3 GB. The app never links to gatcg.com at runtime.
CREATE TABLE card_image (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  edition_id       uuid NOT NULL REFERENCES card_edition(id) ON DELETE CASCADE,
  variant          text NOT NULL,            -- 'original' | 'thumb' | ...
  storage_key      text NOT NULL UNIQUE,
  content_type     text NOT NULL,
  byte_size        bigint NOT NULL,
  width            integer,
  height           integer,
  source_url       text NOT NULL,
  checksum_sha256  text,
  fetched_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (edition_id, variant)
);

-- Ingest observability. Paginate on has_more, NEVER total_pages: the upstream
-- reports total_cards incorrectly at small page sizes, and silently caps
-- page_size at 50 (16).
CREATE TABLE catalog_sync_run (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  game_id           uuid NOT NULL REFERENCES game(id) ON DELETE CASCADE,
  status            sync_status NOT NULL DEFAULT 'running',
  started_at        timestamptz NOT NULL DEFAULT now(),
  finished_at       timestamptz,
  pages_fetched     integer NOT NULL DEFAULT 0,
  cards_upserted    integer NOT NULL DEFAULT 0,
  editions_upserted integer NOT NULL DEFAULT 0,
  images_fetched    integer NOT NULL DEFAULT 0,
  error             text,
  CONSTRAINT sync_run_finished CHECK ((status = 'running') = (finished_at IS NULL))
);

-- ===========================================================================
-- ACCOUNTS & SOCIAL (1, 4)
-- ===========================================================================

CREATE TABLE account (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email         citext NOT NULL UNIQUE,
  display_name  text NOT NULL,

  -- Enforced here as well as in app_set_display_name (40), same reasoning as
  -- the username shape check below: a name is shown to friends often enough
  -- that a blank or absurdly long one should be impossible to store.
  CONSTRAINT account_display_name_shape CHECK (
    length(btrim(display_name)) BETWEEN 1 AND 60),

  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),

  -- The handle you give someone so they can add you (33). NULL until chosen:
  -- a Google sign-in never asks for one, so the app has to, and an account
  -- exists for the moment between signing in and picking it.
  --
  -- citext, so Jon and jon are the same person and cannot both be claimed.
  --
  -- Placed last, not with the other columns above: ALTER TABLE ADD COLUMN
  -- always appends physically, and this column arrived that way in migration
  -- 20260922010000 on every database that already existed. Declaring it here
  -- in a different position would make a from-empty build's column order
  -- permanently disagree with a migrated database's -- harmless to Postgres,
  -- but it is exactly what db/README.md's drift guard exists to catch.
  username      citext UNIQUE,

  -- Enforced here as well as in app_set_username, because a username is
  -- public and permanent enough that a bad one should be impossible to store
  -- rather than merely discouraged.
  CONSTRAINT account_username_shape CHECK (
    username IS NULL OR username ~ '^[A-Za-z0-9][A-Za-z0-9_-]{2,19}$'),

  -- Which game's nav/collection you're currently looking at (the game axis
  -- was always in the schema via card.game_id -- this is the first place the
  -- app itself is aware of it). ON DELETE SET NULL, not RESTRICT: a game
  -- being removed should not make an account row un-deletable-adjacent.
  -- Defaulted at signup to whatever game exists (app_provision_account) since
  -- there is only one today; nothing about this column assumes that stays
  -- true.
  selected_game_id uuid REFERENCES game(id) ON DELETE SET NULL
);

-- Friendship is mutual and accepted (1), so it is ONE row, not two.
-- The pair is stored in a canonical order to make that structurally true:
-- (a,b) and (b,a) cannot both exist. Direction lives in requested_by_id.
-- An ACCEPTED friendship. There is no pending state here any more -- a
-- friend request is a `request` row (23), and this row is created the moment
-- it is accepted. Every row in this table is a live friendship, which is why
-- app_is_friend() no longer has to filter on status.
CREATE TABLE friendship (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_lo_id    uuid NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  account_hi_id    uuid NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  -- Which request created it, kept so "friends since" can cite the exchange.
  created_from_request_id uuid,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT friendship_ordered CHECK (account_lo_id < account_hi_id),
  UNIQUE (account_lo_id, account_hi_id)
);

CREATE INDEX friendship_hi_idx ON friendship (account_hi_id);

-- Visibility is opt-in per game and global across friends (4).
-- Row present = that game is friend-visible. Absent = private.
-- No per-friend column, deliberately: that was considered and rejected.
CREATE TABLE game_share (
  account_id  uuid NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  game_id     uuid NOT NULL REFERENCES game(id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, game_id)
);

-- ===========================================================================
-- INVENTORY (8, 9, 21)
-- ===========================================================================

-- Flat, user-named (9) — no nesting, no container→slot.
--
-- The load-bearing decision of the whole model: a location is either a place
-- ('physical') or a person ('holder'). A card is on loan precisely when its
-- quantity sits in a holder location. This is why multiple borrowers
-- disambiguate themselves, why loans to non-users are not a second model (3),
-- and why "friends see how many are on loan but not to whom" needs no special
-- casing — the holder IS a location, and locations are never shared (14).
CREATE TABLE location (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id         uuid NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  kind               location_kind NOT NULL,
  -- For 'physical': the box name. For a text-name holder: the person's name.
  -- NULL for an account-linked holder, where the label resolves through
  -- holder_account_id so it tracks their display name rather than going stale.
  name               text,
  holder_account_id  uuid REFERENCES account(id) ON DELETE RESTRICT,
  archived_at        timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT location_physical_shape CHECK (
    kind <> 'physical' OR (holder_account_id IS NULL AND name IS NOT NULL)),
  -- A holder is exactly one of: a linked account, or a bare name (3).
  CONSTRAINT location_holder_shape CHECK (
    kind <> 'holder' OR num_nonnulls(holder_account_id, name) = 1),
  CONSTRAINT location_not_self CHECK (holder_account_id IS DISTINCT FROM account_id),

  -- Lets holding and placement prove same-owner via composite FK (below).
  UNIQUE (id, account_id)
);

CREATE UNIQUE INDEX location_physical_name_key
  ON location (account_id, lower(name))
  WHERE kind = 'physical' AND archived_at IS NULL;

-- One holder location per person, per owner — so Sarah is a single bucket
-- however many separate loans she is holding.
CREATE UNIQUE INDEX location_holder_account_key
  ON location (account_id, holder_account_id)
  WHERE holder_account_id IS NOT NULL;

CREATE UNIQUE INDEX location_holder_name_key
  ON location (account_id, lower(name))
  WHERE kind = 'holder' AND holder_account_id IS NULL;

-- A quantity bucket. There are no per-copy records anywhere in this schema (8).
--
-- The bucket key is (edition, finish, location, condition) (21). One person
-- owning 4 copies of a card can therefore legitimately have 4 holdings. That
-- is correct for storage and hostile for data entry, so the UI is expected to
-- present card-level rows that expand into printings.
CREATE TABLE holding (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id  uuid NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  edition_id  uuid NOT NULL REFERENCES card_edition(id) ON DELETE RESTRICT,
  finish      card_finish NOT NULL,
  location_id uuid NOT NULL,
  condition   card_condition NOT NULL,
  qty         integer NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT holding_qty_positive CHECK (qty > 0),  -- empty buckets are deleted

  -- The location must belong to the same account as the holding.
  FOREIGN KEY (location_id, account_id)
    REFERENCES location (id, account_id) ON DELETE RESTRICT,
  -- You cannot record a finish that printing was never issued in.
  FOREIGN KEY (edition_id, finish)
    REFERENCES card_edition_finish (edition_id, finish) ON DELETE RESTRICT,

  UNIQUE (account_id, edition_id, finish, location_id, condition)
);

CREATE INDEX holding_account_edition_idx ON holding (account_id, edition_id);
CREATE INDEX holding_location_idx        ON holding (location_id);

-- ===========================================================================
-- DECKS (issue #21)
--
-- Unlike a holding, a deck row is scoped by PRINTING (edition_id), not just
-- card, so the builder can pick specific art -- but the Standard Constructed
-- copy limits (4 per name in main+sideboard, 1 in material+sideboard) are per
-- CARD NAME, summed across every edition and finish of it. That sum has to be
-- computed, so it lives in app_set_deck_card (db/functions.sql), not a CHECK
-- constraint -- Postgres CHECK constraints see one row at a time.
-- ===========================================================================

CREATE TABLE deck (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id  uuid NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  name        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),

  -- The printing whose art represents the deck on /decks (#32). NULL means
  -- no art chosen -- the tile falls back to an icon. SET NULL, not
  -- RESTRICT: a catalog edition disappearing should cost the deck its
  -- picture, not block the ingest. Last in the table because it arrived
  -- via ALTER TABLE ADD COLUMN (see the drift-guard note on account.username).
  cover_edition_id uuid REFERENCES card_edition(id) ON DELETE SET NULL
);

CREATE INDEX deck_account_idx ON deck (account_id);

-- No qty-positive-or-deleted convention here (8) -- app_set_deck_card deletes
-- the row itself on qty = 0, same idea, enforced the same way holding is.
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

-- ===========================================================================
-- LOANS (2, 3, 5, 6, 7, 10, 11, 13, 15, 18, 19, 20)
-- ===========================================================================

-- The batch envelope (11): one hand-off, one acceptance, one notification.
-- Per-card state lives on loan_line.
CREATE TABLE loan (
  id                         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lender_account_id          uuid NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  -- Who it was handed to originally. Individual lines may since have moved on
  -- to other holders via approved transfers (18, 19).
  initial_holder_location_id uuid NOT NULL REFERENCES location(id) ON DELETE RESTRICT,
  status                     loan_status NOT NULL DEFAULT 'active',
  -- The request that was accepted to create this loan. NULL for a loan to a
  -- bare name, which has nobody to accept it and so skips requests entirely (3).
  created_from_request_id    uuid,
  note                       text,
  created_at                 timestamptz NOT NULL DEFAULT now(),
  closed_at                  timestamptz,
  CONSTRAINT loan_closed CHECK ((status = 'closed') = (closed_at IS NOT NULL))
);

CREATE INDEX loan_lender_idx ON loan (lender_account_id, status);
CREATE INDEX loan_initial_holder_idx ON loan (initial_holder_location_id);

-- ONE PHYSICAL CARD PER ROW — deliberately, and not in conflict with (8).
--
-- Decision 13 has the lender set condition at receipt, per card. Two copies
-- lent together can come back in different conditions, so a line cannot carry
-- a quantity without needing a condition breakdown inside it. A 60-card deck
-- is therefore 60 lines. This is a custody record, not an inventory instance:
-- it exists only while a card is out, and closes when the card comes home.
CREATE TABLE loan_line (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  loan_id             uuid NOT NULL REFERENCES loan(id) ON DELETE CASCADE,
  edition_id          uuid NOT NULL REFERENCES card_edition(id) ON DELETE RESTRICT,
  finish              card_finish NOT NULL,

  -- Where it came from, so the return can suggest it (10). Suggested, never
  -- applied automatically — the lender confirms or overrides.
  origin_location_id  uuid NOT NULL REFERENCES location(id) ON DELETE RESTRICT,
  -- Condition when it left, so a downgrade at receipt is visible history (13).
  departure_condition card_condition NOT NULL,

  -- Current custody. Changes on an approved transfer (18, 19).
  holder_location_id  uuid NOT NULL REFERENCES location(id) ON DELETE RESTRICT,

  status              loan_line_status NOT NULL DEFAULT 'outstanding',
  sent_at             timestamptz,          -- borrower marked returned (6)
  received_at         timestamptz,          -- lender confirmed receipt (6)
  received_condition  card_condition,       -- lender's call at receipt (13)
  return_location_id  uuid REFERENCES location(id) ON DELETE RESTRICT,
  close_reason        loan_close_reason,
  closed_at           timestamptz,

  FOREIGN KEY (edition_id, finish)
    REFERENCES card_edition_finish (edition_id, finish) ON DELETE RESTRICT,

  CONSTRAINT loan_line_in_transit CHECK (status <> 'in_transit' OR sent_at IS NOT NULL),
  CONSTRAINT loan_line_closed     CHECK (
    (status IN ('returned', 'written_off')) = (closed_at IS NOT NULL)),
  CONSTRAINT loan_line_reason     CHECK ((closed_at IS NULL) = (close_reason IS NULL)),
  -- A normal confirmed return must say what came back and where it went.
  CONSTRAINT loan_line_receipt    CHECK (
    close_reason <> 'returned_confirmed'
    OR (received_at IS NOT NULL
        AND received_condition IS NOT NULL
        AND return_location_id IS NOT NULL)),
  -- A write-off means the card never came back.
  CONSTRAINT loan_line_write_off  CHECK (
    close_reason <> 'force_closed_written_off'
    OR (received_at IS NULL AND return_location_id IS NULL))
);

CREATE INDEX loan_line_loan_idx   ON loan_line (loan_id);
CREATE INDEX loan_line_holder_idx ON loan_line (holder_location_id)
  WHERE status IN ('outstanding', 'in_transit');

-- Where the *borrower* filed a card they are holding (7). Their location,
-- their data — everything else about the card belongs to the lender. Keyed by
-- account rather than sitting on loan_line so it survives a transfer: Mike
-- files it in his own box without disturbing Sarah's historical placement.
CREATE TABLE loan_line_placement (
  loan_line_id  uuid NOT NULL REFERENCES loan_line(id) ON DELETE CASCADE,
  account_id    uuid NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  location_id   uuid NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (loan_line_id, account_id),
  FOREIGN KEY (location_id, account_id)
    REFERENCES location (id, account_id) ON DELETE RESTRICT
);

-- Sub-loans (18, 19, 20). The borrower initiates; the owner must approve.
-- The recipient may be anyone — the owner's friend, the borrower's friend, or
-- a text-name non-user — because owner approval is the actual gate (20).
--
-- Approval is a full transfer of responsibility (19): loan_line.holder_location_id
-- moves, the previous holder is released, and the card returns directly to the
-- owner. These rows are the retained custody trail.
CREATE TABLE loan_transfer (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  loan_line_id             uuid NOT NULL REFERENCES loan_line(id) ON DELETE CASCADE,
  from_location_id         uuid NOT NULL REFERENCES location(id) ON DELETE RESTRICT,
  to_location_id           uuid NOT NULL REFERENCES location(id) ON DELETE RESTRICT,
  initiated_by_account_id  uuid NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  -- Which request the owner approved to allow this. NULL only for transfers
  -- the owner performs directly on their own loan.
  approved_from_request_id uuid,
  approved_at              timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT transfer_distinct CHECK (from_location_id <> to_location_id)
);

-- This table is now APPROVED transfers only -- it is the custody trail (19),
-- not a workflow. A transfer awaiting approval is a pending `request` (23).

-- "At most one transfer in flight per card" used to be a partial unique index
-- here. It cannot be, now that pending lives in `request`: the rule spans two
-- tables, which no single index can express. app_request_transfer() enforces
-- it instead, and db/tests/request_smoke.sql holds it honest.
CREATE INDEX loan_transfer_line_idx ON loan_transfer (loan_line_id);

-- ---------------------------------------------------------------------------
-- Requests: one lifecycle for every pending approval (23)
-- ---------------------------------------------------------------------------

CREATE TABLE request (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind                 request_kind NOT NULL,
  proposer_account_id  uuid NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  recipient_account_id uuid NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  status               request_status NOT NULL DEFAULT 'pending',
  note                 text,
  -- A counter-offer is a NEW request that supersedes the one it replaces (25),
  -- so the accepted terms are always exactly the terms that were displayed.
  supersedes_id        uuid REFERENCES request(id) ON DELETE SET NULL,
  created_at           timestamptz NOT NULL DEFAULT now(),
  resolved_at          timestamptz,

  CONSTRAINT request_distinct CHECK (proposer_account_id <> recipient_account_id),
  CONSTRAINT request_resolved CHECK ((status = 'pending') = (resolved_at IS NULL))
);

-- At most one pending request of a kind between the same two people in the
-- same direction. Without this, tapping "add friend" twice creates two
-- inbox entries that both resolve to the same friendship.
CREATE UNIQUE INDEX request_one_pending
  ON request (kind, proposer_account_id, recipient_account_id)
  WHERE status = 'pending';

CREATE INDEX request_inbox ON request (recipient_account_id, status, created_at DESC);
CREATE INDEX request_outbox ON request (proposer_account_id, status, created_at DESC);

-- Cards attached to a loan_offer or borrow_request.
CREATE TABLE request_loan_item (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id         uuid NOT NULL REFERENCES request(id) ON DELETE CASCADE,
  edition_id         uuid NOT NULL REFERENCES card_edition(id) ON DELETE RESTRICT,
  finish             card_finish NOT NULL,
  condition          card_condition NOT NULL,
  qty                integer NOT NULL,
  -- Which box the cards come out of. Set on a loan_offer, where the lender is
  -- proposing. NULL on a borrow_request: the borrower is asking for a card and
  -- has no idea (and no right to know) which box it lives in (14). The owner
  -- picks the origin when they approve.
  origin_location_id uuid REFERENCES location(id) ON DELETE RESTRICT,

  CONSTRAINT request_loan_item_qty CHECK (qty > 0)
);

CREATE INDEX request_loan_item_req ON request_loan_item (request_id);

-- Cards attached to a trade_offer, on both sides of the swap.
CREATE TABLE request_trade_item (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id    uuid NOT NULL REFERENCES request(id) ON DELETE CASCADE,
  -- true  = the proposer is giving this away
  -- false = the proposer is asking for it
  from_proposer boolean NOT NULL,
  edition_id    uuid NOT NULL REFERENCES card_edition(id) ON DELETE RESTRICT,
  finish        card_finish NOT NULL,
  condition     card_condition NOT NULL,
  qty           integer NOT NULL,

  CONSTRAINT request_trade_item_qty CHECK (qty > 0)
);

CREATE INDEX request_trade_item_req ON request_trade_item (request_id);

-- The target of a sub-loan request (18, 20).
CREATE TABLE request_sub_loan (
  request_id            uuid PRIMARY KEY REFERENCES request(id) ON DELETE CASCADE,
  loan_line_id          uuid NOT NULL REFERENCES loan_line(id) ON DELETE CASCADE,
  to_holder_account_id  uuid REFERENCES account(id) ON DELETE CASCADE,
  to_holder_name        text,

  CONSTRAINT sub_loan_target CHECK (num_nonnulls(to_holder_account_id, to_holder_name) = 1)
);

-- ---------------------------------------------------------------------------
-- Listings: a signal, not a gate (27)
-- ---------------------------------------------------------------------------

-- Keyed on (account, edition, finish) and deliberately NOT on a holding.
-- Holdings are split by location and condition; tying a listing to one would
-- mean moving a card between boxes silently drops its listing. Location is
-- also private (14), so listing data must not hang off a location-keyed row.
CREATE TABLE listing (
  account_id    uuid NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  edition_id    uuid NOT NULL REFERENCES card_edition(id) ON DELETE CASCADE,
  finish        card_finish NOT NULL,
  for_trade     boolean NOT NULL DEFAULT false,
  for_sale      boolean NOT NULL DEFAULT false,
  -- Intent only. There is no in-app payment, order or sold state -- see the
  -- open question in docs/design/friends-and-loans.md.
  asking_price  numeric(10,2),
  updated_at    timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (account_id, edition_id, finish),
  -- A row that offers nothing is just clutter; delete it instead.
  CONSTRAINT listing_offers_something CHECK (for_trade OR for_sale),
  CONSTRAINT listing_price_sane CHECK (asking_price IS NULL OR asking_price >= 0)
);

CREATE INDEX listing_by_edition ON listing (edition_id, finish) WHERE for_trade OR for_sale;

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

-- ---------------------------------------------------------------------------
-- Trades: the only thing that moves cards between accounts (24)
-- ---------------------------------------------------------------------------

CREATE TABLE trade (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_from_request_id uuid NOT NULL REFERENCES request(id) ON DELETE RESTRICT,
  proposer_account_id  uuid NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  recipient_account_id uuid NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  status               trade_status NOT NULL DEFAULT 'settling',
  created_at           timestamptz NOT NULL DEFAULT now(),
  completed_at         timestamptz,

  CONSTRAINT trade_distinct CHECK (proposer_account_id <> recipient_account_id),
  CONSTRAINT trade_completed CHECK ((status = 'settling') = (completed_at IS NULL))
);

-- One physical card in transit between two accounts.
--
-- One row per card, for the same reason loan_line is one row per card (13):
-- the RECEIVER sets the condition on arrival, and two copies sent together can
-- arrive in different shape.
CREATE TABLE trade_item (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trade_id             uuid NOT NULL REFERENCES trade(id) ON DELETE CASCADE,
  from_account_id      uuid NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  to_account_id        uuid NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  edition_id           uuid NOT NULL REFERENCES card_edition(id) ON DELETE RESTRICT,
  finish               card_finish NOT NULL,
  departure_condition  card_condition NOT NULL,
  -- Where the card sits in the SENDER's inventory while in transit: a holder
  -- location naming the receiver, exactly as a loan would use (10). This is
  -- why an in-flight trade still shows up as "with Sarah" rather than
  -- vanishing from the sender's collection.
  holder_location_id   uuid NOT NULL REFERENCES location(id) ON DELETE RESTRICT,
  status               trade_item_status NOT NULL DEFAULT 'in_transit',
  received_condition   card_condition,
  received_location_id uuid REFERENCES location(id) ON DELETE RESTRICT,
  received_at          timestamptz,

  CONSTRAINT trade_item_distinct CHECK (from_account_id <> to_account_id),
  CONSTRAINT trade_item_received CHECK (
    (status = 'received') =
    (received_at IS NOT NULL AND received_condition IS NOT NULL
     AND received_location_id IS NOT NULL))
);

CREATE INDEX trade_item_trade ON trade_item (trade_id);
CREATE INDEX trade_item_inbound ON trade_item (to_account_id, status);

-- Back-references to the request that created each of these. Added here
-- because `request` is defined after the tables that point at it.
ALTER TABLE friendship
  ADD CONSTRAINT friendship_from_request
  FOREIGN KEY (created_from_request_id) REFERENCES request(id) ON DELETE SET NULL;

ALTER TABLE loan
  ADD CONSTRAINT loan_from_request
  FOREIGN KEY (created_from_request_id) REFERENCES request(id) ON DELETE SET NULL;

ALTER TABLE loan_transfer
  ADD CONSTRAINT transfer_from_request
  FOREIGN KEY (approved_from_request_id) REFERENCES request(id) ON DELETE SET NULL;

-- ===========================================================================
-- VIEWS

-- ===========================================================================

-- What a friend is allowed to see for a shared game (14): cards, quantities,
-- conditions — and how many are out on loan, but never where or with whom.
--
-- Note there is no location column. That absence is the privacy rule.
CREATE VIEW friend_visible_holding AS
SELECT
  h.account_id,
  c.game_id,
  e.card_id,
  h.edition_id,
  h.finish,
  h.condition,
  sum(h.qty)                                            AS qty_total,
  coalesce(sum(h.qty) FILTER (WHERE l.kind = 'holder'), 0) AS qty_on_loan
FROM holding h
  JOIN location     l  ON l.id = h.location_id
  JOIN card_edition e  ON e.id = h.edition_id
  JOIN card         c  ON c.id = e.card_id
  JOIN game_share   gs ON gs.account_id = h.account_id AND gs.game_id = c.game_id
GROUP BY h.account_id, c.game_id, e.card_id, h.edition_id, h.finish, h.condition;

-- Every card currently in someone else's hands, with both parties resolved.
-- Backs the unfriend block (5): a friendship may not be dissolved while any
-- row here joins the two accounts.
CREATE VIEW open_custody AS
SELECT
  ll.id              AS loan_line_id,
  ln.id              AS loan_id,
  ln.lender_account_id,
  loc.id             AS holder_location_id,
  loc.holder_account_id,
  loc.name           AS holder_name,
  ll.edition_id,
  ll.finish,
  ll.departure_condition,
  ll.status
FROM loan_line ll
  JOIN loan     ln  ON ln.id = ll.loan_id
  JOIN location loc ON loc.id = ll.holder_location_id
WHERE ll.status IN ('outstanding', 'in_transit');

-- Populates the /cards and /add filter bar from one query, same shape as the
-- old Softgen prototype's card_filter_options (see issue #20). Grand
-- Archive-specific attribute names (element/types/subtypes/classes) live in
-- card.attributes (jsonb) rather than as columns (16), so this unnests them.
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

-- ===========================================================================
-- FUNCTIONS (read-only, not mutations -- see db/functions.sql for those)
-- ===========================================================================

-- Server-side catalog search for /cards and /add (issue #20). A plain SQL
-- function rather than a PostgREST embedded-table query, because filtering on
-- card.attributes (jsonb arrays) with "OR within a control, AND across
-- controls" semantics has no clean PostgREST operator -- ov/cs only cover
-- native array/range columns, not jsonb. NULL means "no filter on this
-- control": every predicate below is `p_x IS NULL OR ...`, not an empty-array
-- check, so "no elements selected" and "filter by these elements" are
-- distinguishable.
--
-- No SECURITY DEFINER: catalog tables are already world-readable (RLS
-- `USING (true)`), so this runs with the caller's own rights.
--
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

-- ===========================================================================
-- INVARIANTS ENFORCED IN APPLICATION CODE
--
-- Recorded here so they are not lost. Each needs a test.
--
--  a. (2)  Creating a loan against an account-linked holder requires an
--          accepted friendship. Sub-loan recipients are exempt (20).
--  b. (2)  STRUCTURAL NOW, not enforced: an unaccepted loan has no `loan` row
--          at all, only a pending `request`, so there is nothing that could
--          move a holding. Kept listed because the guarantee still matters.
--  c. (10) Accepting a loan moves qty from the origin physical bucket into the
--          holder bucket. Confirming receipt moves it back — to the suggested
--          origin unless the lender overrides.
--  d. (5)  An unfriend is refused while open_custody joins the two accounts,
--          in either direction. Force-close is the escape hatch.
--  e. (15) Force-close acts on individual lines, never a whole loan at once.
--  f. (7)  Borrowed cards are excluded from the borrower's collection counts
--          and value totals, and are read-only to them apart from placement.
--  g. (19) Approving a transfer updates holder_location_id, moves the holding
--          between holder buckets, and leaves the loan_transfer row as history.
--  h. (11) A loan closes when its last line closes.
--  i. (12) Catalog tables are written only by the ingest, never by users.
--  j. (23) Every pending approval is a `request` row. Accepting one is the
--          only thing that creates a loan, friendship, trade or transfer.
--  k. (25) Accepting a request applies exactly the terms it carries. A change
--          supersedes it with a new request rather than editing in place.
--  l. (24) A trade moves cards between two ACCOUNTS — the only operation that
--          does. Each side settles independently; neither moves on acceptance.
--  m. (27) A listing never gates a request. It only decides whether the
--          owner's notification carries an "not offered" warning.
--  n. (21) Deck copy limits (4 main, 1 material, both pooled with sideboard
--          rows of the same card and tightened by attributes->legality-
--          >STANDARD->limit) and section caps (12 material, 15 sideboard
--          cards/points) are rejected outright in app_set_deck_card. The
--          60-card main-deck minimum and the Level 0 champion requirement are
--          never enforced -- see the comment above app_set_deck_card for why
--          a floor can only ever be a display fact (deck_summary), not
--          something a mutation can be rejected over.
-- ===========================================================================
