-- ===========================================================================
-- Friends Card Inventory -- complete Supabase setup
--
-- GENERATED FILE. Do not edit. Regenerate with:
--   node db/apply.mjs --emit dist/supabase-setup.sql
--
-- Paste the whole thing into the Supabase SQL editor and press Run. It is
-- every file in db/ concatenated in the one order that works, minus the
-- local auth shim, which must never reach Supabase.
--
-- Runs on an EMPTY database. It creates tables and policies, so re-running
-- it over itself will fail on the first thing that already exists.
-- ===========================================================================


-- ===========================================================================
-- schema.sql -- Tables, types and views
-- ===========================================================================

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
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
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
-- ===========================================================================


-- ===========================================================================
-- auth_bridge.sql -- Provisions an account per auth user
-- ===========================================================================

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
SET search_path = public, extensions
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


-- ===========================================================================
-- policies.sql -- Row Level Security
-- ===========================================================================

-- Row Level Security policies.
--
-- REQUIRED on Supabase. The client talks straight to Postgres through
-- PostgREST using the anon key, so without these policies every holding,
-- location and loan in the database is world-readable. The views in
-- schema.sql control the *shape* of what a friend sees; RLS controls whether
-- they may read the underlying tables at all. Both are needed.
--
-- Assumes Supabase auth: auth.uid() returns the signed-in account's id, and
-- account.id is the same uuid as auth.users.id.
--
--   psql -d fci -v ON_ERROR_STOP=1 -f db/policies.sql
--
-- The ingest worker connects with the service-role key, which bypasses RLS
-- entirely -- that is how the catalog gets written despite the read-only
-- policies below.

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Is the current user in an accepted friendship with `other`?
-- SECURITY DEFINER so it can read friendship rows the caller cannot select.
CREATE OR REPLACE FUNCTION app_is_friend(other uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  -- No status filter: every row in `friendship` is an accepted friendship
  -- now that pending lives in `request` (23).
  SELECT EXISTS (
    SELECT 1 FROM friendship f
     WHERE least(auth.uid(), other) = f.account_lo_id
       AND greatest(auth.uid(), other) = f.account_hi_id
  );
$$;

-- Payload tables are guarded by their parent request. SECURITY DEFINER for the
-- usual reason: an inline EXISTS against `request` would re-enter request's own
-- policy from a child table's policy.
CREATE OR REPLACE FUNCTION app_can_see_request(p_request uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1 FROM request r
     WHERE r.id = p_request
       AND auth.uid() IN (r.proposer_account_id, r.recipient_account_id)
  );
$$;

-- Is there a live request between me and `other`, in either direction?
CREATE OR REPLACE FUNCTION app_has_pending_request_with(other uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1 FROM request r
     WHERE r.status = 'pending'
       AND (   (r.proposer_account_id = auth.uid() AND r.recipient_account_id = other)
            OR (r.recipient_account_id = auth.uid() AND r.proposer_account_id = other))
  );
$$;

-- Has `owner` shared the game that this edition belongs to? (4)
CREATE OR REPLACE FUNCTION app_shares_edition(owner uuid, edition uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM card_edition e
      JOIN card c ON c.id = e.card_id
      JOIN game_share gs ON gs.game_id = c.game_id AND gs.account_id = owner
     WHERE e.id = edition
  );
$$;

-- Is the current user holding this specific card right now? Borrowers can see
-- a card they hold regardless of game sharing -- the exception in (4).
CREATE OR REPLACE FUNCTION app_holds_edition(owner uuid, edition uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM loan_line ll
      JOIN loan ln ON ln.id = ll.loan_id
      JOIN location loc ON loc.id = ll.holder_location_id
     WHERE ln.lender_account_id = owner
       AND ll.edition_id = edition
       AND ll.status IN ('outstanding', 'in_transit')
       AND loc.holder_account_id = auth.uid()
  );
$$;

-- ---------------------------------------------------------------------------
-- Catalog: readable by everyone, writable only by the ingest (12)
-- ---------------------------------------------------------------------------

ALTER TABLE game                ENABLE ROW LEVEL SECURITY;
ALTER TABLE card_set            ENABLE ROW LEVEL SECURITY;
ALTER TABLE card                ENABLE ROW LEVEL SECURITY;
ALTER TABLE card_edition        ENABLE ROW LEVEL SECURITY;
ALTER TABLE card_edition_finish ENABLE ROW LEVEL SECURITY;
ALTER TABLE card_image          ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog_sync_run    ENABLE ROW LEVEL SECURITY;

CREATE POLICY catalog_read_game   ON game                FOR SELECT USING (true);
CREATE POLICY catalog_read_set    ON card_set            FOR SELECT USING (true);
CREATE POLICY catalog_read_card   ON card                FOR SELECT USING (true);
CREATE POLICY catalog_read_ed     ON card_edition        FOR SELECT USING (true);
CREATE POLICY catalog_read_finish ON card_edition_finish FOR SELECT USING (true);
CREATE POLICY catalog_read_image  ON card_image          FOR SELECT USING (true);
-- catalog_sync_run gets no policy at all: operational data, service-role only.

-- ---------------------------------------------------------------------------
-- Accounts and friendship
-- ---------------------------------------------------------------------------

ALTER TABLE account    ENABLE ROW LEVEL SECURITY;
ALTER TABLE friendship ENABLE ROW LEVEL SECURITY;
ALTER TABLE game_share ENABLE ROW LEVEL SECURITY;

-- You can see yourself, and anyone you are already friends with. Finding new
-- people to befriend goes through a SECURITY DEFINER search function, not by
-- opening the whole account table to enumeration.
-- Also visible while a request is in flight between you. Without this clause
-- an incoming friend request from someone you do not know yet renders with no
-- display name -- the recipient cannot read the proposer's account row,
-- because they are not friends. That is the whole point of the request.
CREATE POLICY account_self_or_friend ON account
  FOR SELECT USING (
    id = auth.uid()
    OR app_is_friend(id)
    OR app_has_pending_request_with(id));

CREATE POLICY account_update_self ON account
  FOR UPDATE USING (id = auth.uid()) WITH CHECK (id = auth.uid());

-- Both parties can see the friendship. SELECT only, and deliberately so:
-- a friendship is created by accepting a `request` (23) and removed only by
-- app_unfriend(), which refuses while cards are outstanding (5).
CREATE POLICY friendship_visible ON friendship
  FOR SELECT USING (auth.uid() IN (account_lo_id, account_hi_id));

CREATE POLICY game_share_own ON game_share
  FOR ALL USING (account_id = auth.uid()) WITH CHECK (account_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Inventory
-- ---------------------------------------------------------------------------

ALTER TABLE location ENABLE ROW LEVEL SECURITY;
ALTER TABLE holding  ENABLE ROW LEVEL SECURITY;

-- Locations are private, full stop -- including holder locations, which is
-- what stops a friend from seeing WHO has your card (14). No friend-visible
-- policy exists here on purpose.
-- Users manage their own PHYSICAL locations directly -- naming a box is
-- harmless. Holder locations are created only by the loan functions, so a
-- holding and its loan record can never disagree about who has a card.
CREATE POLICY location_own_read ON location
  FOR SELECT USING (account_id = auth.uid());

CREATE POLICY location_own_write ON location
  FOR ALL USING (account_id = auth.uid() AND kind = 'physical')
  WITH CHECK (account_id = auth.uid() AND kind = 'physical');

-- SELECT only. Every quantity change goes through db/functions.sql, which is
-- what makes the invariants enforceable rather than advisory: on Supabase the
-- client can always reach PostgREST directly.
CREATE POLICY holding_own ON holding
  FOR SELECT USING (account_id = auth.uid());

-- A friend may read holdings only for a shared game (4), or for a card they
-- are currently holding. They still cannot read `location`, so they can count
-- what is on loan without learning where anything is.
CREATE POLICY holding_friend_read ON holding
  FOR SELECT USING (
    account_id <> auth.uid()
    AND (
      (app_is_friend(account_id) AND app_shares_edition(account_id, edition_id))
      OR app_holds_edition(account_id, edition_id)
    )
  );

-- ---------------------------------------------------------------------------
-- Loans
-- ---------------------------------------------------------------------------

ALTER TABLE loan                ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_line           ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_line_placement ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_transfer       ENABLE ROW LEVEL SECURITY;

-- Cross-table policy checks MUST go through SECURITY DEFINER helpers.
--
-- A policy on `loan` that inline-queries `loan_line` triggers loan_line's own
-- policy, which inline-queries `loan`, and Postgres aborts with "infinite
-- recursion detected in policy for relation loan". These helpers run with the
-- definer's rights, so the inner query bypasses RLS and the cycle is broken.
-- Do not inline these EXISTS clauses back into the policies.

-- Is the current user the borrower on this loan line?
CREATE OR REPLACE FUNCTION app_is_holder_of_line(line uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1 FROM loan_line ll
      JOIN location loc ON loc.id = ll.holder_location_id
     WHERE ll.id = line AND loc.holder_account_id = auth.uid()
  );
$$;

CREATE OR REPLACE FUNCTION app_is_lender_of_loan(p_loan uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1 FROM loan WHERE id = p_loan AND lender_account_id = auth.uid()
  );
$$;

CREATE OR REPLACE FUNCTION app_is_lender_of_line(p_line uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1 FROM loan_line ll JOIN loan ln ON ln.id = ll.loan_id
     WHERE ll.id = p_line AND ln.lender_account_id = auth.uid()
  );
$$;

-- Addressee of the original hand-off, or current holder of any line on it (2).
CREATE OR REPLACE FUNCTION app_is_borrower_on_loan(p_loan uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1 FROM loan ln JOIN location loc ON loc.id = ln.initial_holder_location_id
     WHERE ln.id = p_loan AND loc.holder_account_id = auth.uid()
  ) OR EXISTS (
    SELECT 1 FROM loan_line ll JOIN location loc ON loc.id = ll.holder_location_id
     WHERE ll.loan_id = p_loan AND loc.holder_account_id = auth.uid()
  );
$$;

-- Loans are SELECT-only here; every mutation goes through db/functions.sql.
CREATE POLICY loan_lender ON loan
  FOR SELECT USING (lender_account_id = auth.uid());

-- The borrower sees the loan they are on, so they can accept it (2).
CREATE POLICY loan_borrower_read ON loan
  FOR SELECT USING (app_is_borrower_on_loan(id));

CREATE POLICY loan_line_lender ON loan_line
  FOR SELECT USING (app_is_lender_of_loan(loan_id));

-- The borrower reads the lines they hold; marking one returned goes through
-- app_mark_returned() (6). Everything else about the card stays the lender's
-- data (7), which a direct UPDATE policy could not express.
CREATE POLICY loan_line_holder_read ON loan_line
  FOR SELECT USING (app_is_holder_of_line(id));

-- Placement is the borrower's own data (7), so it stays directly writable.
CREATE POLICY placement_own ON loan_line_placement
  FOR ALL USING (account_id = auth.uid()) WITH CHECK (account_id = auth.uid());

-- Both the current holder (who proposes) and the owner (who approves) need to
-- see a transfer (18). Approval itself goes through app_approve_transfer().
CREATE POLICY transfer_visible ON loan_transfer
  FOR SELECT USING (
    app_is_holder_of_line(loan_line_id) OR app_is_lender_of_line(loan_line_id)
  );

-- ---------------------------------------------------------------------------
-- Views
--
-- open_custody is a lender-side tool: it reads the lender's own loans, lines
-- and holder locations, all of which their own policies already permit. So it
-- runs as the caller and is filtered by RLS like any other query.
-- ---------------------------------------------------------------------------

ALTER VIEW open_custody SET (security_invoker = true);

-- friend_visible_holding CANNOT run as the caller, and this is subtle enough
-- to be worth spelling out.
--
-- The view derives qty_on_loan by joining `location` and counting the rows
-- whose kind is 'holder'. But a friend is forbidden from reading the owner's
-- locations -- that is exactly the rule that hides WHO has a card (14). Under
-- security_invoker the join therefore matches nothing, every row disappears,
-- and a friend sees an empty inventory. The privacy rule would silently
-- destroy the feature it is meant to qualify.
--
-- So the view runs with its owner's rights and performs its own access check
-- in the WHERE clause below. That clause is the entire access control for this
-- view: it must stay in sync with the friendship and sharing rules.
CREATE OR REPLACE VIEW friend_visible_holding AS
SELECT
  h.account_id,
  c.game_id,
  e.card_id,
  h.edition_id,
  h.finish,
  h.condition,
  sum(h.qty)                                               AS qty_total,
  coalesce(sum(h.qty) FILTER (WHERE l.kind = 'holder'), 0) AS qty_on_loan
FROM holding h
  JOIN location     l  ON l.id = h.location_id
  JOIN card_edition e  ON e.id = h.edition_id
  JOIN card         c  ON c.id = e.card_id
  JOIN game_share   gs ON gs.account_id = h.account_id AND gs.game_id = c.game_id
-- Your own row (so the app can show "here is how friends see you"), or a
-- friend's. The game_share join above already restricts this to shared games.
WHERE h.account_id = auth.uid() OR app_is_friend(h.account_id)
GROUP BY h.account_id, c.game_id, e.card_id, h.edition_id, h.finish, h.condition;

ALTER VIEW friend_visible_holding SET (security_invoker = false);

-- ---------------------------------------------------------------------------
-- Requests, listings and trades (23, 24, 27)
-- ---------------------------------------------------------------------------

ALTER TABLE request            ENABLE ROW LEVEL SECURITY;
ALTER TABLE request_loan_item  ENABLE ROW LEVEL SECURITY;
ALTER TABLE request_trade_item ENABLE ROW LEVEL SECURITY;
ALTER TABLE request_sub_loan   ENABLE ROW LEVEL SECURITY;
ALTER TABLE listing            ENABLE ROW LEVEL SECURITY;
ALTER TABLE trade              ENABLE ROW LEVEL SECURITY;
ALTER TABLE trade_item         ENABLE ROW LEVEL SECURITY;

-- Both parties see the request; nobody writes one directly (23).
CREATE POLICY request_visible ON request
  FOR SELECT USING (
    auth.uid() IN (proposer_account_id, recipient_account_id));

CREATE POLICY request_loan_item_visible ON request_loan_item
  FOR SELECT USING (app_can_see_request(request_id));

CREATE POLICY request_trade_item_visible ON request_trade_item
  FOR SELECT USING (app_can_see_request(request_id));

CREATE POLICY request_sub_loan_visible ON request_sub_loan
  FOR SELECT USING (app_can_see_request(request_id));

-- Listings carry no cross-account invariant -- they are a signal, not a gate
-- (27) -- so unlike holdings they stay directly writable by their owner.
CREATE POLICY listing_own ON listing
  FOR ALL USING (account_id = auth.uid()) WITH CHECK (account_id = auth.uid());

-- A friend sees a listing only for a game you share (4), same rule as holdings.
CREATE POLICY listing_friend_read ON listing
  FOR SELECT USING (
    account_id <> auth.uid()
    AND app_is_friend(account_id)
    AND app_shares_edition(account_id, edition_id));

CREATE POLICY trade_visible ON trade
  FOR SELECT USING (auth.uid() IN (proposer_account_id, recipient_account_id));

CREATE POLICY trade_item_visible ON trade_item
  FOR SELECT USING (auth.uid() IN (from_account_id, to_account_id));


-- ===========================================================================
-- functions.sql -- Every mutation
-- ===========================================================================

-- Mutation RPCs.
--
-- Every write to inventory and loans goes through a function here. The tables
-- themselves are SELECT-only to users (see db/policies.sql), because on
-- Supabase the client can always reach PostgREST directly -- a rule enforced
-- only in application code is bypassable by anyone holding the anon key.
--
-- These functions are the nine invariants listed at the bottom of
-- db/schema.sql, made executable. Parenthesised numbers cite decisions in
-- docs/design/friends-and-loans.md.
--
-- All are SECURITY DEFINER with a pinned search_path, and all authorise
-- against auth.uid() before touching anything.
--
--   psql -d fci -v ON_ERROR_STOP=1 -f db/functions.sql

-- ---------------------------------------------------------------------------
-- Internal helpers (not granted to users)
-- ---------------------------------------------------------------------------

/**
 * Adjust a holding bucket by a delta, creating or deleting the row as needed.
 *
 * This is the only place quantities change. It enforces the rule the smoke
 * test discovered the hard way: an emptied bucket is DELETED, never stored as
 * zero, because `qty > 0` rejects the update outright (8).
 */
CREATE OR REPLACE FUNCTION app_bucket_adjust(
  p_account   uuid,
  p_edition   uuid,
  p_finish    card_finish,
  p_location  uuid,
  p_condition card_condition,
  p_delta     integer
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_current integer;
BEGIN
  IF p_delta = 0 THEN RETURN; END IF;

  SELECT qty INTO v_current
    FROM holding
   WHERE account_id = p_account AND edition_id = p_edition AND finish = p_finish
     AND location_id = p_location AND condition = p_condition
     FOR UPDATE;

  v_current := coalesce(v_current, 0);

  IF v_current + p_delta < 0 THEN
    RAISE EXCEPTION 'not enough cards: bucket holds %, tried to remove %',
      v_current, -p_delta
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_current = 0 THEN
    INSERT INTO holding (account_id, edition_id, finish, location_id, condition, qty)
    VALUES (p_account, p_edition, p_finish, p_location, p_condition, p_delta);
  ELSIF v_current + p_delta = 0 THEN
    DELETE FROM holding
     WHERE account_id = p_account AND edition_id = p_edition AND finish = p_finish
       AND location_id = p_location AND condition = p_condition;
  ELSE
    UPDATE holding SET qty = qty + p_delta, updated_at = now()
     WHERE account_id = p_account AND edition_id = p_edition AND finish = p_finish
       AND location_id = p_location AND condition = p_condition;
  END IF;
END $$;

/** Find or create the caller's holder location for a person (3). */
CREATE OR REPLACE FUNCTION app_holder_location(
  p_owner          uuid,
  p_holder_account uuid,
  p_holder_name    text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF num_nonnulls(p_holder_account, p_holder_name) <> 1 THEN
    RAISE EXCEPTION 'specify exactly one of holder account or holder name';
  END IF;

  IF p_holder_account IS NOT NULL THEN
    SELECT id INTO v_id FROM location
     WHERE account_id = p_owner AND holder_account_id = p_holder_account;
    IF v_id IS NULL THEN
      INSERT INTO location (account_id, kind, holder_account_id)
      VALUES (p_owner, 'holder', p_holder_account) RETURNING id INTO v_id;
    END IF;
  ELSE
    SELECT id INTO v_id FROM location
     WHERE account_id = p_owner AND kind = 'holder'
       AND holder_account_id IS NULL AND lower(name) = lower(p_holder_name);
    IF v_id IS NULL THEN
      INSERT INTO location (account_id, kind, name)
      VALUES (p_owner, 'holder', p_holder_name) RETURNING id INTO v_id;
    END IF;
  END IF;

  RETURN v_id;
END $$;

/** Close the parent loan once its last line closes (11). */
CREATE OR REPLACE FUNCTION app_maybe_close_loan(p_loan uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM loan_line
     WHERE loan_id = p_loan AND status IN ('outstanding', 'in_transit')
  ) THEN
    UPDATE loan SET status = 'closed', closed_at = now()
     WHERE id = p_loan AND status <> 'closed';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION app_require_lender(p_loan uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM loan WHERE id = p_loan AND lender_account_id = auth.uid()) THEN
    RAISE EXCEPTION 'not your loan' USING ERRCODE = 'insufficient_privilege';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Inventory
-- ---------------------------------------------------------------------------

/** Add copies to one of your own physical locations. */
CREATE OR REPLACE FUNCTION app_add_cards(
  p_edition   uuid,
  p_finish    card_finish,
  p_location  uuid,
  p_condition card_condition,
  p_qty       integer
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF p_qty <= 0 THEN RAISE EXCEPTION 'qty must be positive'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM location
     WHERE id = p_location AND account_id = auth.uid() AND kind = 'physical'
  ) THEN
    RAISE EXCEPTION 'not your physical location'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  PERFORM app_bucket_adjust(auth.uid(), p_edition, p_finish, p_location, p_condition, p_qty);
END $$;

/**
 * Move copies between your own locations.
 *
 * Physical locations only. Cards reach a holder location by being loaned (10),
 * never by being filed there directly -- otherwise the holding and the loan
 * record could disagree about who has what.
 */
CREATE OR REPLACE FUNCTION app_move_cards(
  p_edition   uuid,
  p_finish    card_finish,
  p_from      uuid,
  p_to        uuid,
  p_condition card_condition,
  p_qty       integer
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF p_qty <= 0 THEN RAISE EXCEPTION 'qty must be positive'; END IF;
  IF p_from = p_to THEN RAISE EXCEPTION 'source and destination are the same'; END IF;

  IF (SELECT count(*) FROM location
       WHERE id IN (p_from, p_to) AND account_id = auth.uid() AND kind = 'physical') <> 2 THEN
    RAISE EXCEPTION 'both locations must be your own physical locations'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  PERFORM app_bucket_adjust(auth.uid(), p_edition, p_finish, p_from, p_condition, -p_qty);
  PERFORM app_bucket_adjust(auth.uid(), p_edition, p_finish, p_to,   p_condition,  p_qty);
END $$;

-- ---------------------------------------------------------------------------
-- Requests: the shared approval lifecycle (23)
-- ---------------------------------------------------------------------------
--
-- Every pending approval in the app is a `request` row. Creating one is
-- kind-specific (the payload differs); resolving one is not. app_accept_request
-- dispatches to a materialiser per kind, and that materialiser is the ONLY
-- thing that creates a friendship, loan, trade or transfer.

/** Guard: I am the recipient of this pending request. */
CREATE OR REPLACE FUNCTION app_require_recipient(p_request uuid)
RETURNS request
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE r request;
BEGIN
  SELECT * INTO r FROM request WHERE id = p_request FOR UPDATE;
  IF r IS NULL THEN RAISE EXCEPTION 'no such request'; END IF;
  IF r.status <> 'pending' THEN
    RAISE EXCEPTION 'request is already %', r.status;
  END IF;
  IF r.recipient_account_id <> auth.uid() THEN
    RAISE EXCEPTION 'that request is not addressed to you'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION app_open_request(
  p_kind      request_kind,
  p_recipient uuid,
  p_note      text DEFAULT NULL,
  p_supersedes uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF p_recipient = auth.uid() THEN
    RAISE EXCEPTION 'cannot send a request to yourself';
  END IF;

  INSERT INTO request (kind, proposer_account_id, recipient_account_id, note, supersedes_id)
  VALUES (p_kind, auth.uid(), p_recipient, p_note, p_supersedes)
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;

/** Be my friend (1). The only request kind that needs no prior relationship. */
CREATE OR REPLACE FUNCTION app_send_friend_request(p_to uuid, p_note text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF app_is_friend(p_to) THEN RAISE EXCEPTION 'already friends'; END IF;
  RETURN app_open_request('friend', p_to, p_note);
END $$;

/**
 * Offer to lend (2). Creates a request, NOT a loan -- an unaccepted loan has
 * no row anywhere, which is what makes "a pending loan moves nothing"
 * structural rather than a rule to remember.
 */
CREATE OR REPLACE FUNCTION app_offer_loan(
  p_lines jsonb, p_to uuid, p_note text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_req uuid; v_spec jsonb;
BEGIN
  IF NOT app_is_friend(p_to) THEN
    RAISE EXCEPTION 'you can only lend to an accepted friend'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_req := app_open_request('loan_offer', p_to, p_note);

  FOR v_spec IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    IF NOT EXISTS (
      SELECT 1 FROM location
       WHERE id = (v_spec->>'origin_location_id')::uuid
         AND account_id = auth.uid() AND kind = 'physical'
    ) THEN
      RAISE EXCEPTION 'origin must be your own physical location'
        USING ERRCODE = 'insufficient_privilege';
    END IF;

    INSERT INTO request_loan_item
      (request_id, edition_id, finish, condition, qty, origin_location_id)
    VALUES (v_req,
            (v_spec->>'edition_id')::uuid,
            (v_spec->>'finish')::card_finish,
            (v_spec->>'condition')::card_condition,
            coalesce((v_spec->>'qty')::integer, 1),
            (v_spec->>'origin_location_id')::uuid);
  END LOOP;

  RETURN v_req;
END $$;

/**
 * Ask to borrow (28). The mirror image of an offer: the borrower proposes and
 * the owner approves. No origin is given -- the borrower does not know, and has
 * no right to know, which box the card lives in (14). The owner picks it when
 * they accept.
 */
CREATE OR REPLACE FUNCTION app_request_borrow(
  p_lines jsonb, p_from uuid, p_note text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_req uuid; v_spec jsonb;
BEGIN
  IF NOT app_is_friend(p_from) THEN
    RAISE EXCEPTION 'you can only ask a friend'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_req := app_open_request('borrow_request', p_from, p_note);

  FOR v_spec IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    INSERT INTO request_loan_item (request_id, edition_id, finish, condition, qty)
    VALUES (v_req,
            (v_spec->>'edition_id')::uuid,
            (v_spec->>'finish')::card_finish,
            (v_spec->>'condition')::card_condition,
            coalesce((v_spec->>'qty')::integer, 1));
  END LOOP;

  RETURN v_req;
END $$;

/**
 * Propose a swap (24). `p_give` are cards the proposer hands over, `p_take` are
 * cards they want back. Nothing moves until the offer is accepted, and even
 * then only into transit.
 */
CREATE OR REPLACE FUNCTION app_offer_trade(
  p_give jsonb, p_take jsonb, p_to uuid,
  p_note text DEFAULT NULL, p_supersedes uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_req uuid; v_spec jsonb;
BEGIN
  IF NOT app_is_friend(p_to) THEN
    RAISE EXCEPTION 'you can only trade with an accepted friend'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF jsonb_array_length(coalesce(p_give, '[]'::jsonb)) = 0
     AND jsonb_array_length(coalesce(p_take, '[]'::jsonb)) = 0 THEN
    RAISE EXCEPTION 'a trade must move at least one card';
  END IF;

  v_req := app_open_request('trade_offer', p_to, p_note, p_supersedes);

  FOR v_spec IN SELECT * FROM jsonb_array_elements(coalesce(p_give, '[]'::jsonb)) LOOP
    INSERT INTO request_trade_item
      (request_id, from_proposer, edition_id, finish, condition, qty)
    VALUES (v_req, true, (v_spec->>'edition_id')::uuid,
            (v_spec->>'finish')::card_finish,
            (v_spec->>'condition')::card_condition,
            coalesce((v_spec->>'qty')::integer, 1));
  END LOOP;

  FOR v_spec IN SELECT * FROM jsonb_array_elements(coalesce(p_take, '[]'::jsonb)) LOOP
    INSERT INTO request_trade_item
      (request_id, from_proposer, edition_id, finish, condition, qty)
    VALUES (v_req, false, (v_spec->>'edition_id')::uuid,
            (v_spec->>'finish')::card_finish,
            (v_spec->>'condition')::card_condition,
            coalesce((v_spec->>'qty')::integer, 1));
  END LOOP;

  RETURN v_req;
END $$;

/**
 * Counter-offer (25): decline the original and open a fresh one that cites it.
 * Terms are never edited under a reader, so accepting always applies exactly
 * what was displayed.
 */
CREATE OR REPLACE FUNCTION app_counter_trade(
  p_request uuid, p_give jsonb, p_take jsonb, p_note text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE r request;
BEGIN
  r := app_require_recipient(p_request);
  IF r.kind <> 'trade_offer' THEN RAISE EXCEPTION 'not a trade offer'; END IF;

  UPDATE request SET status = 'superseded', resolved_at = now() WHERE id = p_request;

  -- Roles swap: the counter is proposed BY the original recipient.
  RETURN app_offer_trade(p_give, p_take, r.proposer_account_id, p_note, p_request);
END $$;

/** Ask the owner to let me pass this card on (18, 20). */
CREATE OR REPLACE FUNCTION app_request_sub_loan(
  p_line uuid, p_holder_account uuid DEFAULT NULL, p_holder_name text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_owner uuid; v_req uuid; v_status loan_line_status;
BEGIN
  IF NOT app_is_holder_of_line(p_line) THEN
    RAISE EXCEPTION 'you are not holding that card'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT ln.lender_account_id, ll.status INTO v_owner, v_status
    FROM loan_line ll JOIN loan ln ON ln.id = ll.loan_id WHERE ll.id = p_line;

  IF v_status <> 'outstanding' THEN
    RAISE EXCEPTION 'only an outstanding card can be passed on';
  END IF;

  -- "One transfer in flight per card" used to be a partial unique index. It
  -- spans request and request_sub_loan now, so no index can express it.
  IF EXISTS (
    SELECT 1 FROM request_sub_loan sl JOIN request r ON r.id = sl.request_id
     WHERE sl.loan_line_id = p_line AND r.status = 'pending'
  ) THEN
    RAISE EXCEPTION 'a transfer request for that card is already pending';
  END IF;

  v_req := app_open_request('sub_loan', v_owner);
  INSERT INTO request_sub_loan (request_id, loan_line_id, to_holder_account_id, to_holder_name)
  VALUES (v_req, p_line, p_holder_account, p_holder_name);

  RETURN v_req;
END $$;

-- ---------------------------------------------------------------------------
-- Resolving a request
-- ---------------------------------------------------------------------------

/**
 * Accept a request. Dispatches by kind; each branch is the only code path that
 * creates the thing it creates (23).
 *
 * p_data carries whatever the ACCEPTER must supply that the proposer could not:
 *   borrow_request -> {"origins": [{"edition_id":…, "finish":…,
 *                                   "origin_location_id":…}]}
 * Everything else ignores it.
 */
CREATE OR REPLACE FUNCTION app_accept_request(p_request uuid, p_data jsonb DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE r request;
BEGIN
  r := app_require_recipient(p_request);

  CASE r.kind
    WHEN 'friend'         THEN PERFORM app_materialise_friendship(r);
    WHEN 'loan_offer'     THEN PERFORM app_materialise_loan(r, r.proposer_account_id, NULL);
    WHEN 'borrow_request' THEN PERFORM app_materialise_loan(r, r.recipient_account_id, p_data);
    WHEN 'trade_offer'    THEN PERFORM app_materialise_trade(r);
    WHEN 'sub_loan'       THEN PERFORM app_materialise_sub_loan(r);
  END CASE;

  UPDATE request SET status = 'accepted', resolved_at = now() WHERE id = p_request;
END $$;

CREATE OR REPLACE FUNCTION app_decline_request(p_request uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  PERFORM app_require_recipient(p_request);
  UPDATE request SET status = 'declined', resolved_at = now() WHERE id = p_request;
END $$;

/** Withdraw something you proposed. */
CREATE OR REPLACE FUNCTION app_cancel_request(p_request uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM request
     WHERE id = p_request AND proposer_account_id = auth.uid() AND status = 'pending'
  ) THEN
    RAISE EXCEPTION 'no pending request of yours'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  UPDATE request SET status = 'cancelled', resolved_at = now() WHERE id = p_request;
END $$;

-- ---------------------------------------------------------------------------
-- Materialisers: the only creators of friendships, loans, trades, transfers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app_materialise_friendship(r request)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  INSERT INTO friendship (account_lo_id, account_hi_id, created_from_request_id)
  VALUES (least(r.proposer_account_id, r.recipient_account_id),
          greatest(r.proposer_account_id, r.recipient_account_id),
          r.id)
  ON CONFLICT DO NOTHING;
END $$;

/**
 * Turn an accepted loan_offer or borrow_request into a live loan.
 *
 * p_lender is whichever party owns the cards -- the proposer for an offer, the
 * recipient for a borrow request. From here on the two are indistinguishable,
 * which is the whole point of (28).
 */
CREATE OR REPLACE FUNCTION app_materialise_loan(r request, p_lender uuid, p_data jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_borrower uuid := CASE WHEN p_lender = r.proposer_account_id
                          THEN r.recipient_account_id ELSE r.proposer_account_id END;
  v_holder uuid;
  v_loan   uuid;
  it       record;
  v_origin uuid;
  i        integer;
BEGIN
  v_holder := app_holder_location(p_lender, v_borrower, NULL);

  INSERT INTO loan (lender_account_id, initial_holder_location_id, status,
                    created_from_request_id, note)
  VALUES (p_lender, v_holder, 'active', r.id, r.note)
  RETURNING id INTO v_loan;

  FOR it IN SELECT * FROM request_loan_item WHERE request_id = r.id LOOP
    v_origin := it.origin_location_id;

    -- A borrow request carries no origin; the owner supplies one on approval.
    IF v_origin IS NULL THEN
      SELECT (o->>'origin_location_id')::uuid INTO v_origin
        FROM jsonb_array_elements(coalesce(p_data->'origins', '[]'::jsonb)) o
       WHERE (o->>'edition_id')::uuid = it.edition_id
         AND (o->>'finish')::card_finish = it.finish
       LIMIT 1;
    END IF;

    IF v_origin IS NULL THEN
      RAISE EXCEPTION 'no origin location given for edition %', it.edition_id;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM location
       WHERE id = v_origin AND account_id = p_lender AND kind = 'physical'
    ) THEN
      RAISE EXCEPTION 'origin must be a physical location belonging to the lender';
    END IF;

    FOR i IN 1..it.qty LOOP
      INSERT INTO loan_line (loan_id, edition_id, finish, origin_location_id,
                             departure_condition, holder_location_id)
      VALUES (v_loan, it.edition_id, it.finish, v_origin, it.condition, v_holder);
    END LOOP;
  END LOOP;

  PERFORM app_move_to_holder(v_loan);
END $$;

/** Move every outstanding line out of its origin and into the holder bucket (10). */
CREATE OR REPLACE FUNCTION app_move_to_holder(p_loan uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_owner uuid; r record;
BEGIN
  SELECT lender_account_id INTO v_owner FROM loan WHERE id = p_loan;
  FOR r IN SELECT * FROM loan_line WHERE loan_id = p_loan AND status = 'outstanding' LOOP
    PERFORM app_bucket_adjust(v_owner, r.edition_id, r.finish,
                              r.origin_location_id, r.departure_condition, -1);
    PERFORM app_bucket_adjust(v_owner, r.edition_id, r.finish,
                              r.holder_location_id, r.departure_condition,  1);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION app_materialise_sub_loan(r request)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE sl record; ll record; v_to uuid;
BEGIN
  SELECT * INTO sl FROM request_sub_loan WHERE request_id = r.id;

  SELECT l.*, ln.lender_account_id INTO ll
    FROM loan_line l JOIN loan ln ON ln.id = l.loan_id WHERE l.id = sl.loan_line_id;

  IF ll.status <> 'outstanding' THEN
    RAISE EXCEPTION 'that card is no longer outstanding';
  END IF;

  v_to := app_holder_location(ll.lender_account_id, sl.to_holder_account_id, sl.to_holder_name);
  IF v_to = ll.holder_location_id THEN RAISE EXCEPTION 'that person already has it'; END IF;

  PERFORM app_bucket_adjust(ll.lender_account_id, ll.edition_id, ll.finish,
                            ll.holder_location_id, ll.departure_condition, -1);
  PERFORM app_bucket_adjust(ll.lender_account_id, ll.edition_id, ll.finish,
                            v_to, ll.departure_condition, 1);

  UPDATE loan_line SET holder_location_id = v_to WHERE id = sl.loan_line_id;

  -- Retained as the custody trail (19).
  INSERT INTO loan_transfer (loan_line_id, from_location_id, to_location_id,
                             initiated_by_account_id, approved_from_request_id)
  VALUES (sl.loan_line_id, ll.holder_location_id, v_to, r.proposer_account_id, r.id);
END $$;

/**
 * Start a trade settling (24). Each side's outgoing cards move into a holder
 * location naming the other party -- the same device a loan uses (10) -- so an
 * in-flight trade still reads as "with Sarah" rather than vanishing.
 *
 * Nothing lands in anyone's collection until they confirm receipt.
 */
CREATE OR REPLACE FUNCTION app_materialise_trade(r request)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_trade uuid;
  it      record;
  v_from  uuid; v_to uuid; v_holder uuid;
  i       integer;
BEGIN
  INSERT INTO trade (created_from_request_id, proposer_account_id, recipient_account_id)
  VALUES (r.id, r.proposer_account_id, r.recipient_account_id)
  RETURNING id INTO v_trade;

  FOR it IN SELECT * FROM request_trade_item WHERE request_id = r.id LOOP
    IF it.from_proposer THEN
      v_from := r.proposer_account_id; v_to := r.recipient_account_id;
    ELSE
      v_from := r.recipient_account_id; v_to := r.proposer_account_id;
    END IF;

    v_holder := app_holder_location(v_from, v_to, NULL);

    FOR i IN 1..it.qty LOOP
      -- Out of a physical bucket, into the sender's holder bucket. Picking the
      -- source bucket is deliberately strict: the sender must actually own a
      -- copy in the stated condition, or the trade cannot be accepted.
      PERFORM app_trade_reserve(v_from, it.edition_id, it.finish, it.condition, v_holder);

      INSERT INTO trade_item (trade_id, from_account_id, to_account_id, edition_id,
                              finish, departure_condition, holder_location_id)
      VALUES (v_trade, v_from, v_to, it.edition_id, it.finish, it.condition, v_holder);
    END LOOP;
  END LOOP;
END $$;

/** Take one copy out of any physical bucket and park it in the holder bucket. */
CREATE OR REPLACE FUNCTION app_trade_reserve(
  p_account uuid, p_edition uuid, p_finish card_finish,
  p_condition card_condition, p_holder uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_src uuid;
BEGIN
  SELECT h.location_id INTO v_src
    FROM holding h JOIN location l ON l.id = h.location_id
   WHERE h.account_id = p_account AND h.edition_id = p_edition
     AND h.finish = p_finish AND h.condition = p_condition
     AND l.kind = 'physical' AND h.qty > 0
   ORDER BY h.qty DESC
   LIMIT 1;

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'no % copy of that card in a physical location to trade away',
      p_condition USING ERRCODE = 'check_violation';
  END IF;

  PERFORM app_bucket_adjust(p_account, p_edition, p_finish, v_src, p_condition, -1);
  PERFORM app_bucket_adjust(p_account, p_edition, p_finish, p_holder, p_condition, 1);
END $$;

-- ---------------------------------------------------------------------------
-- Settling a trade (24)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app_trade_maybe_complete(p_trade uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM trade_item WHERE trade_id = p_trade AND status = 'in_transit'
  ) THEN
    UPDATE trade SET status = 'completed', completed_at = now()
     WHERE id = p_trade AND status = 'settling';
  END IF;
END $$;

/**
 * The RECEIVER confirms a card arrived and sets the condition it arrived in.
 *
 * This is the moment ownership actually transfers: the copy leaves the
 * sender's inventory entirely and appears in the receiver's. It is the only
 * operation in the app that writes holdings for two different accounts.
 */
CREATE OR REPLACE FUNCTION app_confirm_trade_item(
  p_item uuid, p_condition card_condition DEFAULT NULL, p_location uuid DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE it trade_item; v_cond card_condition; v_dest uuid;
BEGIN
  SELECT * INTO it FROM trade_item WHERE id = p_item FOR UPDATE;
  IF it IS NULL THEN RAISE EXCEPTION 'no such trade item'; END IF;
  IF it.to_account_id <> auth.uid() THEN
    RAISE EXCEPTION 'only the receiver confirms a trade item'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF it.status <> 'in_transit' THEN RAISE EXCEPTION 'already settled'; END IF;

  v_cond := coalesce(p_condition, it.departure_condition);
  v_dest := p_location;

  IF v_dest IS NULL THEN
    SELECT id INTO v_dest FROM location
     WHERE account_id = auth.uid() AND kind = 'physical'
     ORDER BY created_at LIMIT 1;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM location
     WHERE id = v_dest AND account_id = auth.uid() AND kind = 'physical'
  ) THEN
    RAISE EXCEPTION 'destination must be your own physical location';
  END IF;

  -- Gone from the sender, for good.
  PERFORM app_bucket_adjust(it.from_account_id, it.edition_id, it.finish,
                            it.holder_location_id, it.departure_condition, -1);
  -- Arrived, at whatever condition it actually turned up in.
  PERFORM app_bucket_adjust(auth.uid(), it.edition_id, it.finish,
                            v_dest, v_cond, 1);

  UPDATE trade_item
     SET status = 'received', received_condition = v_cond,
         received_location_id = v_dest, received_at = now()
   WHERE id = p_item;

  PERFORM app_trade_maybe_complete(it.trade_id);
END $$;

/**
 * The escape hatch for a half-settled trade -- the same problem (5) solves for
 * loans. The SENDER writes off a card that never arrived; it leaves their
 * inventory and joins nobody else's.
 */
CREATE OR REPLACE FUNCTION app_write_off_trade_item(p_item uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE it trade_item;
BEGIN
  SELECT * INTO it FROM trade_item WHERE id = p_item FOR UPDATE;
  IF it IS NULL THEN RAISE EXCEPTION 'no such trade item'; END IF;
  IF auth.uid() NOT IN (it.from_account_id, it.to_account_id) THEN
    RAISE EXCEPTION 'not your trade' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF it.status <> 'in_transit' THEN RAISE EXCEPTION 'already settled'; END IF;

  PERFORM app_bucket_adjust(it.from_account_id, it.edition_id, it.finish,
                            it.holder_location_id, it.departure_condition, -1);

  UPDATE trade_item SET status = 'written_off' WHERE id = p_item;
  PERFORM app_trade_maybe_complete(it.trade_id);
END $$;

-- ---------------------------------------------------------------------------
-- Listings: a signal, not a gate (27)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app_set_listing(
  p_edition uuid, p_finish card_finish,
  p_for_trade boolean, p_for_sale boolean, p_price numeric DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  -- A row offering nothing is clutter; unlisting deletes it.
  IF NOT (p_for_trade OR p_for_sale) THEN
    DELETE FROM listing
     WHERE account_id = auth.uid() AND edition_id = p_edition AND finish = p_finish;
    RETURN;
  END IF;

  INSERT INTO listing (account_id, edition_id, finish, for_trade, for_sale, asking_price)
  VALUES (auth.uid(), p_edition, p_finish, p_for_trade, p_for_sale, p_price)
  ON CONFLICT (account_id, edition_id, finish) DO UPDATE
     SET for_trade = excluded.for_trade,
         for_sale = excluded.for_sale,
         asking_price = excluded.asking_price,
         updated_at = now();
END $$;

/**
 * Which cards in this request were never offered (27)?
 *
 * Drives the warning on the owner's notification. It does NOT gate anything --
 * the request is valid either way; the owner just gets told they are being
 * asked for something off-menu.
 *
 * Only meaningful for requests that ask for the RECIPIENT's cards: a borrow
 * request, or the take-side of a trade offer.
 */
CREATE OR REPLACE FUNCTION app_request_unlisted(p_request uuid)
RETURNS TABLE (edition_id uuid, finish card_finish, qty integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE r request;
BEGIN
  SELECT * INTO r FROM request WHERE id = p_request;
  IF r IS NULL THEN RAISE EXCEPTION 'no such request'; END IF;
  IF auth.uid() NOT IN (r.proposer_account_id, r.recipient_account_id) THEN
    RAISE EXCEPTION 'not your request' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  WITH asked AS (
    SELECT i.edition_id, i.finish, i.qty
      FROM request_loan_item i
     WHERE i.request_id = r.id AND r.kind = 'borrow_request'
    UNION ALL
    SELECT i.edition_id, i.finish, i.qty
      FROM request_trade_item i
     WHERE i.request_id = r.id AND r.kind = 'trade_offer' AND i.from_proposer = false
  )
  SELECT a.edition_id, a.finish, a.qty
    FROM asked a
   WHERE NOT EXISTS (
     SELECT 1 FROM listing l
      WHERE l.account_id = r.recipient_account_id
        AND l.edition_id = a.edition_id
        AND l.finish = a.finish
        AND (l.for_trade OR l.for_sale)
   );
END $$;

/** Borrower sends a card back: outstanding -> in_transit (6). */
CREATE OR REPLACE FUNCTION app_mark_returned(p_line uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF NOT app_is_holder_of_line(p_line) THEN
    RAISE EXCEPTION 'you are not holding that card'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE loan_line SET status = 'in_transit', sent_at = now()
   WHERE id = p_line AND status = 'outstanding';

  IF NOT FOUND THEN RAISE EXCEPTION 'card is not outstanding'; END IF;
END $$;

/**
 * Lender confirms receipt and sets the condition it came back in (13).
 *
 * The card files into the bucket matching its RECEIVED condition, which may
 * differ from the one it left in -- that is the whole point of setting it here.
 * p_return_location defaults to the origin, which the UI pre-fills as a
 * suggestion the lender can override (10).
 */
CREATE OR REPLACE FUNCTION app_confirm_receipt(
  p_line             uuid,
  p_condition        card_condition DEFAULT NULL,
  p_return_location  uuid DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  r        record;
  v_cond   card_condition;
  v_dest   uuid;
BEGIN
  SELECT ll.*, ln.lender_account_id INTO r
    FROM loan_line ll JOIN loan ln ON ln.id = ll.loan_id
   WHERE ll.id = p_line;

  IF r IS NULL THEN RAISE EXCEPTION 'no such loan line'; END IF;
  PERFORM app_require_lender(r.loan_id);
  IF r.status NOT IN ('outstanding', 'in_transit') THEN
    RAISE EXCEPTION 'card is already settled';
  END IF;

  v_cond := coalesce(p_condition, r.departure_condition);
  v_dest := coalesce(p_return_location, r.origin_location_id);

  IF NOT EXISTS (
    SELECT 1 FROM location
     WHERE id = v_dest AND account_id = r.lender_account_id AND kind = 'physical'
  ) THEN
    RAISE EXCEPTION 'return destination must be your own physical location';
  END IF;

  -- Out of the holder bucket at its departure condition, into a physical
  -- bucket at whatever condition it actually came back in.
  PERFORM app_bucket_adjust(r.lender_account_id, r.edition_id, r.finish,
                            r.holder_location_id, r.departure_condition, -1);
  PERFORM app_bucket_adjust(r.lender_account_id, r.edition_id, r.finish,
                            v_dest, v_cond, 1);

  UPDATE loan_line
     SET status = 'returned', received_at = now(), received_condition = v_cond,
         return_location_id = v_dest, close_reason = 'returned_confirmed',
         closed_at = now()
   WHERE id = p_line;

  PERFORM app_maybe_close_loan(r.loan_id);
END $$;

/**
 * The lender's escape hatch (5), acting on ONE card (15).
 *
 * p_recovered = true means the card is physically back and files into
 * p_return_location; false writes it off as gone. Either way the line settles,
 * which is what releases the unfriend block.
 */
CREATE OR REPLACE FUNCTION app_force_close_line(
  p_line            uuid,
  p_recovered       boolean DEFAULT false,
  p_condition       card_condition DEFAULT NULL,
  p_return_location uuid DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  r      record;
  v_dest uuid;
  v_cond card_condition;
BEGIN
  SELECT ll.*, ln.lender_account_id INTO r
    FROM loan_line ll JOIN loan ln ON ln.id = ll.loan_id
   WHERE ll.id = p_line;

  IF r IS NULL THEN RAISE EXCEPTION 'no such loan line'; END IF;
  PERFORM app_require_lender(r.loan_id);
  IF r.status NOT IN ('outstanding', 'in_transit') THEN
    RAISE EXCEPTION 'card is already settled';
  END IF;

  -- Either way it leaves the holder's hands.
  PERFORM app_bucket_adjust(r.lender_account_id, r.edition_id, r.finish,
                            r.holder_location_id, r.departure_condition, -1);

  IF p_recovered THEN
    v_dest := coalesce(p_return_location, r.origin_location_id);
    v_cond := coalesce(p_condition, r.departure_condition);
    PERFORM app_bucket_adjust(r.lender_account_id, r.edition_id, r.finish,
                              v_dest, v_cond, 1);
    UPDATE loan_line
       SET status = 'returned', received_at = now(), received_condition = v_cond,
           return_location_id = v_dest, close_reason = 'force_closed_returned',
           closed_at = now()
     WHERE id = p_line;
  ELSE
    -- Written off: the copy is gone from the inventory entirely.
    UPDATE loan_line
       SET status = 'written_off', close_reason = 'force_closed_written_off',
           closed_at = now()
     WHERE id = p_line;
  END IF;

  PERFORM app_maybe_close_loan(r.loan_id);
END $$;

-- ---------------------------------------------------------------------------
-- Lending to someone who is not a user (3)
-- ---------------------------------------------------------------------------

/**
 * A loan to a bare name. No request, because a text name has nobody to accept
 * one -- this is the single path that creates a loan without going through the
 * request lifecycle, and (3) is why.
 */
CREATE OR REPLACE FUNCTION app_lend_to_name(
  p_lines jsonb, p_name text, p_note text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_holder uuid; v_loan uuid; v_spec jsonb; i integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  v_holder := app_holder_location(auth.uid(), NULL, p_name);

  INSERT INTO loan (lender_account_id, initial_holder_location_id, status, note)
  VALUES (auth.uid(), v_holder, 'active', p_note) RETURNING id INTO v_loan;

  FOR v_spec IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    IF NOT EXISTS (
      SELECT 1 FROM location
       WHERE id = (v_spec->>'origin_location_id')::uuid
         AND account_id = auth.uid() AND kind = 'physical'
    ) THEN
      RAISE EXCEPTION 'origin must be your own physical location';
    END IF;

    FOR i IN 1..coalesce((v_spec->>'qty')::integer, 1) LOOP
      INSERT INTO loan_line (loan_id, edition_id, finish, origin_location_id,
                             departure_condition, holder_location_id)
      VALUES (v_loan, (v_spec->>'edition_id')::uuid,
              (v_spec->>'finish')::card_finish,
              (v_spec->>'origin_location_id')::uuid,
              (v_spec->>'condition')::card_condition, v_holder);
    END LOOP;
  END LOOP;

  PERFORM app_move_to_holder(v_loan);
  RETURN v_loan;
END $$;

-- ---------------------------------------------------------------------------
-- Friendship
-- ---------------------------------------------------------------------------

/**
 * Unfriend, refused while either party still holds the other's cards (5),
 * checked in BOTH directions.
 */
CREATE OR REPLACE FUNCTION app_unfriend(p_other uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_me uuid := auth.uid(); v_open integer;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF v_me = p_other THEN RAISE EXCEPTION 'cannot unfriend yourself'; END IF;

  SELECT count(*) INTO v_open
    FROM loan_line ll
    JOIN loan ln  ON ln.id = ll.loan_id
    JOIN location loc ON loc.id = ll.holder_location_id
   WHERE ll.status IN ('outstanding', 'in_transit')
     AND (   (ln.lender_account_id = v_me    AND loc.holder_account_id = p_other)
          OR (ln.lender_account_id = p_other AND loc.holder_account_id = v_me));

  IF v_open > 0 THEN
    RAISE EXCEPTION
      'cannot unfriend: % card(s) still outstanding between you. Settle or force-close them first.',
      v_open
      USING ERRCODE = 'check_violation';
  END IF;

  -- A trade mid-flight is the same problem wearing a different hat.
  SELECT count(*) INTO v_open
    FROM trade_item ti
   WHERE ti.status = 'in_transit'
     AND ((ti.from_account_id = v_me AND ti.to_account_id = p_other)
       OR (ti.from_account_id = p_other AND ti.to_account_id = v_me));

  IF v_open > 0 THEN
    RAISE EXCEPTION
      'cannot unfriend: % card(s) still in transit between you from a trade.', v_open
      USING ERRCODE = 'check_violation';
  END IF;

  DELETE FROM friendship
   WHERE least(v_me, p_other) = account_lo_id
     AND greatest(v_me, p_other) = account_hi_id;
END $$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

DO $$
DECLARE fn text; r text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'app_add_cards(uuid,card_finish,uuid,card_condition,integer)',
    'app_move_cards(uuid,card_finish,uuid,uuid,card_condition,integer)',
    'app_send_friend_request(uuid,text)',
    'app_offer_loan(jsonb,uuid,text)',
    'app_request_borrow(jsonb,uuid,text)',
    'app_offer_trade(jsonb,jsonb,uuid,text,uuid)',
    'app_counter_trade(uuid,jsonb,jsonb,text)',
    'app_request_sub_loan(uuid,uuid,text)',
    'app_accept_request(uuid,jsonb)',
    'app_decline_request(uuid)',
    'app_cancel_request(uuid)',
    'app_request_unlisted(uuid)',
    'app_set_listing(uuid,card_finish,boolean,boolean,numeric)',
    'app_confirm_trade_item(uuid,card_condition,uuid)',
    'app_write_off_trade_item(uuid)',
    'app_lend_to_name(jsonb,text,text)',
    'app_mark_returned(uuid)',
    'app_confirm_receipt(uuid,card_condition,uuid)',
    'app_force_close_line(uuid,boolean,card_condition,uuid)',
    'app_unfriend(uuid)'
  ] LOOP
    FOREACH r IN ARRAY ARRAY['authenticated', 'app_user'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', fn, r);
      END IF;
    END LOOP;
  END LOOP;
END $$;


-- ===========================================================================
-- Did it work?
--
-- The results pane below should show every row saying PASS. Anything else
-- means the database is applied but not right -- send it back rather than
-- carrying on.
-- ===========================================================================

WITH t AS (
  SELECT c.relname, c.relrowsecurity,
         (SELECT count(*) FROM pg_policy p WHERE p.polrelid = c.oid) AS policies
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind = 'r'
)
SELECT * FROM (
  SELECT 1 AS n, 'tables present' AS check_name,
         CASE WHEN count(*) = 23 THEN 'PASS' ELSE 'FAIL' END AS result,
         count(*) || ' of 23' AS detail
    FROM t

  UNION ALL
  SELECT 2, 'row level security on every table',
         CASE WHEN count(*) FILTER (WHERE NOT relrowsecurity) = 0 THEN 'PASS' ELSE 'FAIL' END,
         coalesce(string_agg(relname, ', ') FILTER (WHERE NOT relrowsecurity),
                  'all protected')
    FROM t

  UNION ALL
  -- RLS on with no policy denies everything. Intended for catalog_sync_run,
  -- a bug anywhere else -- it shows up as a permanently empty screen.
  SELECT 3, 'every user-facing table has a policy',
         CASE WHEN count(*) FILTER (
                WHERE policies = 0 AND relname <> 'catalog_sync_run') = 0
              THEN 'PASS' ELSE 'FAIL' END,
         coalesce(string_agg(relname, ', ') FILTER (
                    WHERE policies = 0 AND relname <> 'catalog_sync_run'),
                  'all readable')
    FROM t

  UNION ALL
  SELECT 4, 'operational tables stay closed',
         CASE WHEN count(*) FILTER (
                WHERE policies > 0 AND relname = 'catalog_sync_run') = 0
              THEN 'PASS' ELSE 'FAIL' END,
         'catalog_sync_run is service-role only'
    FROM t

  UNION ALL
  SELECT 5, 'mutation functions installed',
         CASE WHEN count(*) >= 30 THEN 'PASS' ELSE 'FAIL' END,
         count(*) || ' app_* functions'
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname LIKE 'app\_%'

  UNION ALL
  -- citext lives in the extensions schema on Supabase, not public.
  SELECT 6, 'citext operators resolve',
         CASE WHEN ('A'::citext = 'a'::citext) THEN 'PASS' ELSE 'FAIL' END,
         'case-insensitive email comparison'

  UNION ALL
  SELECT 7, 'signup creates an account',
         CASE WHEN count(*) FILTER (WHERE tgname = 'on_auth_user_created') = 1
              THEN 'PASS' ELSE 'FAIL' END,
         coalesce(string_agg(tgname, ', '), 'NO TRIGGER on auth.users')
    FROM pg_trigger
   WHERE tgrelid = 'auth.users'::regclass AND NOT tgisinternal

  UNION ALL
  -- The one that matters most. If these ids do not line up, auth.uid() matches
  -- nothing and every page in the app is empty, with no error anywhere.
  SELECT 8, 'every signed-up user has an account row',
         CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
         CASE WHEN count(*) = 0 THEN 'ids line up'
              ELSE count(*) || ' auth user(s) with no account' END
    FROM auth.users u
   WHERE u.email IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.account a WHERE a.id = u.id)
) checks
ORDER BY n;
