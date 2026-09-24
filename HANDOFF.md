# Handoff

Everything established so far, for whoever picks this up next — including a
future me.

**Status:** design settled, database built, migrated and tested, all mutations
implemented as Postgres functions, catalog **imported for real** (63 sets,
~2,500 cards, ~4,900 editions) with images backfilled to Supabase Storage, and
a Next.js app covering sign-in, a public catalog browser with filters, your
collection (with per-card editing and bulk moves), the request inbox, the
friends/lending UI, a deck builder, a card detail view, and public
collection sharing — all live in production.

Loans, borrows, trades, friend requests and sub-loans are all implemented and
tested, reachable from the app rather than only from the RPCs. Everyone gets a
username (33) and a default "Unsorted" box (34) on signup.

The visual design was redone to match the retired Softgen prototype's actual
look (§8) after the first pass fell short of it twice, and the nav/landing
page were restructured around a "Select Your Game" page and a per-account
`selected_game_id` (§9) — the first place the app itself is aware of the
game axis that was always latent in the schema. A card detail dialog (§10,
issue #23) and a public, token-based collection share link (§11, issue #22)
followed, both read-only additions against the existing catalog/holding
model with no data-model rework needed.

Stack decisions made: **Supabase** (managed Postgres), **Next.js App Router**,
**mobile-first responsive web**, **magic link + Google** sign-in, and
**invariants enforced in Postgres RPC** rather than app code.

---

## How work gets done here

The working agreement with the owner, settled over many PRs — follow it
unless told otherwise:

1. **One issue (or a tight follow-up) per branch and PR**, branched from an
   up-to-date `main`. Never stack a PR on another unmerged branch; if a new
   feature would reuse something still in review, keep it independent and
   note the follow-up instead.
2. **Verify before pushing.** Web: `tsc --noEmit`, `eslint`, `next build`.
   Database changes additionally: all test suites against a throwaway local
   Postgres (`npm test` in `db/`), each new assertion's `NOTICE` checked
   directly, and the drift guard reproduced locally (§7).
3. **Any DB change ships as a migration the owner applies by hand.** Paste
   the migration's SQL in chat for them to run in the Supabase SQL editor.
   Never handle database credentials or run `db push` against the live
   project yourself.
4. **The owner verifies signed-in pages on the Vercel preview** (get its URL
   from the PR's deployment status via `gh api .../deployments`); verify
   public pages (`/cards`, `/shared/...`) yourself in the browser. Remember
   the preview, not production, is where an unmerged PR's UI lives — running
   the SQL alone changes nothing visible.
5. **Merge only on an explicit "merge it"**, then close the linked issue
   with a comment pointing at the PR and delete the branch.
6. **Scope questions get asked, not guessed** — when an answer widens an
   issue, file the extra work as its own issue rather than bundling it in
   (#47 and #48 came out of #22 this way).
7. Keep this file and the READMEs current as work lands.

---

## Where this lives

**This repo — `Azure-Persant/TCG-with-friends` — is the only live, updated
copy.** It didn't start that way, and the history is worth knowing before you
go looking for something in the wrong place.

The design and database were built in a different repo,
`JonCorrea/friends-card-inventory`. Separately, an earlier prototype of this
same idea had been built with a tool called Softgen, in a repo the tool
auto-named `sg-e300915b-f09d-430b-87c3-1c85baec61a4-1777483298` under a
`Azure-Persant` account — different codebase (Next.js Pages Router), different
generated schema, but pointed at the *same* Supabase project
(`wtifzovtlxttovnguhgo`) as this one would later use.

That went unnoticed until 2026-09-21, while adopting migrations for issue #14:
the live Supabase project turned out to be running the Softgen app's 11-table
schema (`cards`, `decks`, `profiles`, `sets`, `user_collections`, …), not this
project's — nothing from `db/schema.sql` had ever actually been deployed.
Decided to retire the Softgen app rather than run two apps off one project: its
tables, functions and signup trigger were dropped, and this project's schema
was applied for the first time as the migration baseline (decision 32).

The Softgen repo was then renamed to `TCG-with-friends`, and on 2026-09-22
became this repo's actual content: `JonCorrea/friends-card-inventory`'s full
history was pushed here, replacing the Softgen code entirely, and a branch of
real unmerged work from that repo (the friends/lending UI, usernames, a
default box — decisions 33 and 34) was reconciled in on top. Both repos'
stale branches were deleted. `JonCorrea/friends-card-inventory` is now
archived — read-only, kept around only until it's deleted outright.

**The Softgen *app*, however, is still actively useful — as a design
reference, not as code to run.** A local clone of it (the same repo the
paragraph above describes as retired) sits at
`/Users/jon.correa/Projects/sg-e300915b-f09d-430b-87c3-1c85baec61a4-1777483298`,
outside this repo, and turned out to have real design/UX maturity this
project's own rebuild hadn't reached yet — a polished dark/purple visual
theme, a filterable catalog browser, and a deck builder UI, among other
things. §8 and §9 below, and issues #25 and #32–#41, all came from reading
its actual source (components, pages, Tailwind config) rather than
re-guessing from memory or screenshots. Its *data model* is not a reference —
its single-user, no-real-lending schema is exactly what decision 32 replaced,
and its numeric deck-legality rules turned out to be unsourced guesses (§9.1)
— but its UI/UX choices are worth reading before building anything this
project doesn't have yet.

---

## 1. What this is

A card inventory app for [Grand Archive](https://index.gatcg.com), built around
one feature that shapes everything else: **you can loan cards to friends, and
the app tracks who has what.**

That single requirement is why the data model looks the way it does. A loan has
to point at a stable identity rather than a typed-in name, which is what forced
friendship to be a mutual, accepted relationship instead of a follow or a share
link. Almost every other decision follows from there.

---

## 2. The model in one page

Three axes, deliberately never collapsed into each other:

| Axis | Example | Who defines it | Drives |
|---|---|---|---|
| **Game / IP** | Grand Archive | The catalog | Sharing |
| **Location** | Box A, Binder 1 — *or a person* | The user | Physical custody |
| **Condition** | NM, LP, … | The user, per holding | Value, bucket identity |

A **holding** is a quantity bucket:

```
(account, edition, finish, location, condition) → qty
```

There are no per-copy records anywhere. 2 Near Mint in Box A and 1 Lightly
Played in Box A are simply two rows.

### The one idea worth understanding

**A location is either a place or a person**, and "on loan" is not a status —
it's derived from a holding sitting in a `holder`-kind location.

| Location | Kind | Condition | Qty |
|---|---|---|---|
| Box A | physical | NM | 2 |
| Box B | physical | NM | 1 |
| Sarah | holder | NM | 1 |

Four copies owned, one on loan, and *the schema didn't need a loan flag to say
so.* Three separate rules collapse into this:

1. **Multiple borrowers disambiguate themselves.** A single shared "On loan"
   bucket with qty 2 can't express "Sarah has one, Mike has the other." Two
   holder locations can.
2. **Loans to non-users stop being a second model.** A non-user is just a
   holder location carrying a name with no linked account.
3. **The privacy rule comes free.** Friends never see locations. If the holder
   *is* a location, then "a friend can see how many cards are on loan but not
   to whom" needs no special-casing at all.

This was the user's idea, not the original design, and it deleted more
complexity than anything else in the project.

---

## 3. Decisions you'd otherwise re-litigate

Full list of all 34 with rationale: **`docs/design/friends-and-loans.md`**.
The ones most likely to look wrong without context:

**Loans require the borrower to accept, and unfriending is blocked while a
loan is open — but the lender can unilaterally force-close.**
Those first two rules deadlock on their own: a borrower who simply never taps
*confirm* keeps the loan open forever and traps you in the relationship. The
force-close is the escape hatch, and it acts on individual cards, not a whole
loan, so you can write off the 2 that never came back without falsifying the 58
that did.

**A loan is a batch going out, but returns are per-card.**
Lending a deck is one hand-off, one acceptance, one notification. Cards come
back individually, so a partial return is a normal state rather than an error.

**`loan_line` holds exactly one physical card — no quantity column.**
This falls out of "the lender sets condition at receipt." Two copies lent
together can come back in different shape, so a line with qty 2 would need a
condition breakdown inside itself. A 60-card deck is 60 lines. It does *not*
contradict the no-instances rule: a loan line is a **custody** record that
closes when the card comes home; a holding is an **inventory** record.

**Holdings are keyed by edition *and* finish.**
A foil Abyssal Heaven printing is a different holding from the non-foil and
from the same card in another set. Foils are worth many times the base card, so
aggregating them makes every value total wrong. The cost is a wide bucket key —
see the traps section.

**Sub-loans are allowed, gated on owner approval.**
A borrower can pass a card onward to anyone, including a non-user. Approval is
the real protection, so requiring mutual friendship on top would only block the
common case. Approval fully transfers responsibility — the card returns
directly to the owner — while the transfer history is retained, because knowing
who had a card when it came back damaged is the entire point.

---

## 4. Three bugs the tests caught

All recorded because they'd be easy to reintroduce, and none of them are
visible by reading any single file.

### The privacy rule nearly destroyed the feature it qualifies

`friend_visible_holding` computes `qty_on_loan` by joining `location` and
counting holder-kind rows. But friends are forbidden from reading the owner's
locations — that's the rule hiding *who* has a card.

Run the view with the caller's privileges and those two facts collide: the join
matches nothing, every row disappears, and **a friend sees an empty
inventory.** Caught by `db/tests/rls_smoke.sql`, which asserted 4-total /
1-on-loan and got back nothing.

The view now runs with its owner's rights and does its own friendship check in
its `WHERE` clause. **That clause is the entire access control for the view.**
Keep it in sync with the friendship and sharing rules.

### RLS policies can chase each other into infinite recursion

The policy on `loan` needed to ask "is the caller a borrower on any of its
lines?", so it queried `loan_line`. The policy on `loan_line` needed to ask "is
the caller the lender?", so it queried `loan`. Postgres aborts the whole query
with `infinite recursion detected in policy for relation "loan"`.

Caught by `db/tests/rpc_smoke.sql` the first time a test read a loan back.
Nothing in the schema or the policies looks wrong in isolation — the cycle only
exists between them.

**The fix, and the rule:** any policy that needs to consult another RLS-guarded
table must do it through a `SECURITY DEFINER` helper (`app_is_lender_of_loan`,
`app_is_borrower_on_loan`, `app_is_holder_of_line`, `app_is_lender_of_line`).
Those run with the definer's rights, so the inner query skips RLS and the cycle
breaks. Do not inline those `EXISTS` clauses back into a policy.

### The auth shim had never been tested against real auth

Every policy and function was written against `auth.uid()`, but the local
`auth_shim.sql` implemented that as a read of a bespoke `app.current_user_id`
setting. Supabase reads the `sub` claim out of `request.jwt.claims`. So the
project's entire privacy model had been proven against a function that did not
resemble the one it would run against.

The shim now implements the real formula, and all seven suites drive it through
forged JWT claims. Everything still passed — but that was a coin-flip, not a
result, and it is the sort of gap that surfaces in production as "why is
everything empty".

**Still untested:** whether Supabase actually sets those claims the way this
assumes. That needs a real project, and it is the first thing to check once
one exists (see below).

### One request table, or five copies of the same flow

Friend requests, loan acceptances and sub-loan transfers were each built with
their own table and their own accept/decline path. Adding trades and borrows
would have made five — five inbox surfaces, five notification paths, five sets
of expiry rules, all of which must behave identically to a user.

They are now one `request` table with a `kind` (23). Only the approval
lifecycle is shared; the payload and the effect of accepting stay per-kind, in
tables that point back at the request.

**The refactor paid for itself immediately.** Because a request now owns the
pending state, `loan` no longer has one: an unaccepted loan has no row in
`loan` at all. Invariant (b) — "a pending loan moves no inventory" — stopped
being a rule anyone can break and became a fact about the schema. The same
applies to `loan_transfer`, which is now purely the custody trail (19) rather
than a workflow with a status column.

**What it cost:** every existing test had to be rewritten, and one rule got
weaker. "At most one transfer in flight per card" used to be a partial unique
index; it now spans `request` and `request_sub_loan`, which no index can
express, so `app_request_sub_loan()` enforces it instead. A rule enforced in a
function is a rule that can be bypassed by a new code path — that one needs
watching.

### Empty buckets must be deleted, not zeroed

`qty > 0` is enforced, so decrementing a bucket to zero is rejected outright.
The caller has to delete instead. This was implicit in the design and only
became explicit when the smoke test tripped over it on a final return.

---

## 5. What exists

| Path | What |
|---|---|
| `docs/design/friends-and-loans.md` | All 34 decisions with rationale. The source of truth. |
| `db/schema.sql` | 26 tables. Portable Postgres, no Supabase dependency. |
| `db/policies.sql` | Row Level Security. **Required on Supabase.** |
| `db/functions.sql` | Every mutation, as `SECURITY DEFINER` RPCs. |
| `db/local/auth_shim.sql` | Local stand-in for `auth.uid()`. Never load on Supabase. |
| `db/tests/schema_smoke.sql` | Full loan lifecycle + 21 constraint rejections. |
| `db/tests/rls_smoke.sql` | Owner / friend / stranger visibility, as an unprivileged role. |
| `db/tests/rpc_smoke.sql` | Full loan lifecycle through the RPCs, as an unprivileged role. |
| `db/tests/request_smoke.sql` | Requests, trades, counter-offers, listings. |
| `db/tests/auth_smoke.sql` | The auth.users -> account bridge. |
| `db/tests/deck_smoke.sql` | Deck copy limits, section caps, the Standard-legality check, RLS (§8). |
| `db/tests/collection_share_smoke.sql` | Share tokens: create/revoke/delete, and guest resolution with no `auth.uid()` at all (§11). |
| `db/auth_bridge.sql` | Provisions an account per auth user (31), defaults `selected_game_id` (§9.2). |
| `db/apply.mjs` | Builds a throwaway local/CI database from the files above. |
| `supabase/migrations/` | The deployable history. Applied to the live project with `supabase db push` (32). |
| `web/app/page.tsx` | "Select Your Game" landing page (§9.2). |
| `web/app/cards/page.tsx` | Public catalog browser with filters — no account needed. |
| `web/app/(app)/decks/`, `.../decks/[id]/` | The deck builder (§8). |
| `web/app/_components/top-nav.tsx`, `nav-menu.tsx` | The shared nav bar and its hand-rolled dropdowns (§9.3). |
| `web/app/_components/card-tile.tsx`, `card-thumbnail.tsx` | The two card-art shapes: grid tile vs. row thumbnail. |
| `web/app/_components/card-detail-dialog.tsx` | Full card text/stats plus a printings switcher (§10, issue #23). |
| `web/app/_components/filter-bar.tsx` | The `/cards`+`/add` element/type/subtype/class/cost filter UI. |
| `web/app/(app)/collection/edit-holding.tsx`, `collection-grid.tsx` | Per-tile edit (qty/condition/finish/box) and bulk select-and-move (§12). |
| `web/app/(app)/collection/share/` | Create/revoke/delete public share links (§11, issue #22). |
| `web/app/shared/[token]/` | The public, read-only page a share link opens — no account needed. |
| `.github/workflows/ingest.yml` | Populate the catalog from the Actions tab. |
| `.github/workflows/ci.yml` | Tests, plus the schema-files-vs-migrations drift guard (§7). |
| `.claude/skills/` | Matt Pocock's skills, installed as editable copies. |
| `ingest/` | GATCG catalog + image worker. TypeScript, one dependency (`pg`). Already run for real — see §6. |
| `docs/data/editions_missing_circulation.csv` | The 636 editions with no upstream finish data. |

Verified against PostgreSQL 16: schema applies clean, all seven test suites
pass, the migration-vs-schema-files drift guard is clean, and the ingest has
run end-to-end against the real live database (not just a test one) — catalog
and images are both populated for real, not placeholder data.

### Running it

Local/CI database (throwaway, built from empty — see `db/README.md`):

```bash
cd db && npm install
npm run apply:local -- --url "postgresql://localhost/fci"
npm test -- --url "postgresql://localhost/fci"
```

The live Supabase project instead takes migrations — `supabase/migrations/`,
applied with `npx supabase db push`. See `db/README.md`, "Changing the
schema," before touching it.

```bash
cd ingest && npm install && cp .env.example .env
npm run catalog    # ~90 seconds
npm run images     # ~19 minutes, 0.76 GB
```

---

## 6. Upstream: api.gatcg.com

Measured against the live API, not documentation — there isn't any.

| | |
|---|---|
| Catalog | **2,240 cards → 4,504 editions** (~2.0 printings per card) |
| Search | `GET /cards/search?page=N&page_size=50` |
| Images | `GET /cards/images/{edition_uuid}.jpg`, 165 KB mean |
| Full mirror | **0.76 GB**, ~19 minutes at a polite 4 requests/second |

### Gotchas that will cost you an afternoon

- **`page_size` silently caps at 50.** Asking for 500 returns 50.
- **`total_cards` and `total_pages` lie.** `total_cards` reports `1` when
  `page_size=1`. Always paginate on `has_more`.
- **No bulk endpoint.** `/bulk`, `/cards`, `/sets` all 404.
- **Finishes are only ever `FOIL` / `NONFOIL`**, mapping 1:1 to the `foil`
  boolean on `circulationTemplates`.
- **14.1% of editions (636) have no circulation data at all**, so their
  finishes are unknown. The gaps are not random — they cluster hard in promo
  and special sets (`PP1`, `P26`, `RDOA`, `ReC-AUR`, `PRXY` are 100% missing;
  `RDOPD` is 91%). Those are exactly where foil-only printings are most likely,
  so guessing per set would be wrong more often than seeding both. The ingest
  seeds **both** finishes and flags them `is_seeded = true`; a strict foreign
  key would otherwise make one card in seven impossible to add to an inventory.

Mirroring the images is consistent with what shoutyourdeck.com,
fractalofin.site and silvie.gg already do. The reason we self-host isn't legal
anyway — it's not hitting their servers on every page view.

---

## 7. Traps for whoever builds the app

**RLS is not optional on Supabase.** Clients talk straight to Postgres through
PostgREST. The views control the *shape* of what a friend sees; RLS controls
whether they can read the underlying tables at all. Without `db/policies.sql`,
anyone with the anon key reads every holding, location and loan in the
database.

**The bucket key is wide, and the entry UI is where that bites.** Someone with
4 copies of one card can legitimately have 4 holdings — different printings,
finishes, boxes, conditions. That's correct for storage and hostile for data
entry. Plan on card-level display rows that expand into printings, not raw
buckets on screen.

**Nine invariants live in application code, not in constraints.** They're
listed at the bottom of `db/schema.sql` with decision references. Each needs a
test. The ones easiest to get wrong: a pending loan must move no inventory
until it's accepted, and an unfriend must be refused while `open_custody` joins
the two accounts in either direction.

**Borrowed cards are read-only shadows.** They're excluded from the borrower's
collection counts and value totals. The borrower may assign one of their own
locations to a card they're holding — that placement is their data; everything
else about the card is the lender's.

**The migration drift guard checks text, not just behavior.** CI's "Migrations
match the schema files" job (`.github/workflows/ci.yml`) builds one database
from `schema.sql`+friends and another from `supabase/migrations/`, then diffs
`pg_dump --schema-only` of both. Postgres stores a function's body as the
literal source text, so a comment present in `functions.sql` but missing from
the migration's copy of that same `CREATE OR REPLACE FUNCTION` is a real,
CI-failing diff — not a cosmetic nit. Copy function bodies into a migration
verbatim, comments included, or verify locally before pushing (§8's commits
show the exact local reproduction: apply both paths to throwaway databases,
`pg_dump` both, `diff`).

**PostgREST has no good operator for "OR within a jsonb array, AND across
several."** `ov`/`cs` (overlap/contains) only work on native Postgres array
and range columns, not on values inside a `jsonb` column — which is where
this project's per-game card attributes deliberately live (16), since a
second game's stat line needs no migration. `search_card_editions` and
`app_set_deck_card`'s legality checks (§8) both exist because of this: once
the filtering logic needs real boolean combinations over jsonb array
membership, it has to be a Postgres function, not a PostgREST embedded-table
query.

**Forcing a permanently-dark Tailwind v4 theme is a two-line, whole-app
lever.** `@custom-variant dark (&:where(.dark, .dark *));` in `globals.css`
plus `className="dark"` on `<html>` in `app/layout.tsx` makes every `dark:`
utility already written throughout the app (from when it followed the OS
preference) apply unconditionally. If this app ever needs a light theme back,
that pair of lines is where to start un-forcing it — not a rewrite of every
page's classes.

**A dropdown's own "close on click" can race a native form's submission.**
The account menu's Sign out button lived inside a wrapper `<div
onClick={() => setOpen(false)}>`. Clicking it fired that handler synchronously
on the bubbled click, unmounting the whole open dropdown — the `<form>`
included — before the browser's native form submission (a plain POST, no JS)
had fired. The click registered and did nothing. The fix was simply not
closing the menu by hand there: the form's own `action` navigates the page
away regardless, so there was nothing to close. Any native `<form>` (not a
`next/link` or a client-side handler) inside conditionally-rendered UI is
worth checking for this.

**A blank-looking screenshot isn't proof of a bug.** A grid of card images
once rendered as flat slate rectangles in one screenshot and correctly in the
next, with nothing in between but a `wait`. Before treating that as a real
issue, check the DOM directly (`naturalWidth`, `complete`, computed
`opacity`/`position`) — it was a browser paint-timing artifact in the
screenshot tool, not a rendering bug, and the DOM was correct the whole time.

**A reference app's own doc comment about privacy is not proof its code
does that.** While designing collection sharing (§11), the retired Softgen
app's `shared_collection()` SQL function was read directly rather than
trusted from its TypeScript type's comment ("no locations and no borrower
names"). The function actually **returns** `personal_location`,
`sale_location` and `loaned_to` — the frontend simply never rendered those
columns. Reading a reference's UI/UX is fine and encouraged (§9.1); trusting
its privacy *claims* without reading the query that backs them is not — this
project's own `shared_collection` was written to actually omit those columns
from its `RETURNS TABLE`, not merely to not display them.

---

## 8. Deck builder (#21, closed)

Not a port of the Softgen prototype's deck tables. That schema (`decks`,
`deck_cards`) was never enforced at the database level — legality was
computed for display only, and the numeric rules behind it (12/60/15/4/1)
weren't cited to anything. This project's version is built against its own
`card`/`card_edition`/`holding` model, with rules sourced from the official
[Standard Constructed rules](https://rules.gatcg.com/general-rules/general-rules-format-conventions):

- **Main deck**: minimum 60 cards, max 4 copies of a card name
- **Material deck**: max 12 cards, max 1 copy of a card name, needs a Level 0
  champion — only Champion/Regalia cards go here
- **Sideboard**: max 15 cards **and** max 15 points (1pt main-type, 3pt
  Champion/Regalia)
- Sideboard copies pool with their type's copy limit — confirmed with the
  user as the intended reading, since the rules page itself doesn't spell out
  this specific edge case
- A card whose `attributes->legality->STANDARD->limit` is `0` is banned —
  read live from the ingested catalog (the shape was confirmed against real
  data: 149 of ~2,500 cards carry a `STANDARD` override today, all `limit: 0`
  — no partial-restriction values exist yet) rather than a hardcoded name
  list, so this stays correct if the restricted list ever gains a non-zero
  entry without anyone touching this code

**Enforcement split, decided deliberately, not a shortcut:** only the upper
bounds above (`app_set_deck_card` in `db/functions.sql`) are rejected
outright. The 60-card minimum and the champion requirement are *never*
enforced by any mutation — every deck starts at 0 cards, so a floor can only
ever be a display fact (`deck_summary`'s "Legal" / "N rule issues" badge),
never something to reject a write over. Removing a card (`qty = 0`) always
succeeds, unconditionally — there's no legitimate reason to ever block that.

`db/tests/deck_smoke.sql` exercises every rule above end to end, as an
unprivileged role, with every assertion's `NOTICE` output inspected directly
(not just the suite's overall pass/fail) before being trusted.

**Deferred, filed as their own issues rather than half-built here:**
deck cover art (#32), decklist paste/export (#33), public deck showcase
(#34), deck sharing via link (#35), deck duplication (#36), per-deck-card
foil/printing swap (#37), the foil shimmer visual treatment anywhere in the
app (#38), and surfacing the restricted-card badge in the UI (#39) — the
retired Softgen prototype had all of these; this project's deck builder
intentionally shipped without them so the legality engine could be gotten
right first. #38 and #39 have since shipped (app-wide, via `CardTile`'s
`foil`/`restricted` props and `FoilOverlay`); #32–#37 remain open.

## 9. Visual design, navigation and game selection

### 9.1 The visual redesign took three passes to actually land

Worth recording because the shape of the miss is more useful than the
outcome: **two rounds of user feedback each caught something the previous
round missed**, and both misses came from working off *memory of screenshots*
rather than the reference's *actual source code*.

1. First pass: matched colors/fonts/gradient from general impression. User's
   reaction: "still not completely as it was before."
2. Asked a direct yes/no ("is it the grid layout you're missing?") — correct
   guess, but only because it was asked rather than assumed. Converted
   `/cards`, `/add`, `/collection` from row lists to a responsive grid of
   card-art tiles.
3. User sent an actual screenshot of the reference's `/collection`. That
   surfaced a "Total: N" / Edit-button tile footer and a stats-row page
   header that a general design pass had no way to know about, because
   they're specific, small UI facts, not a "vibe."

**The lesson, acted on for #25/#32–#41:** when doing feature-parity or visual
work against a reference app, read its actual component source
(`Navigation.tsx`, the real Tailwind classes, the real DOM structure) before
building — not a description of it, not a screenshot glanced at once. A
dedicated research pass reading the reference's real files (§"Where this
lives") caught the nav bar's exact structure, the collection tile's full
footer, the deck list's big-art card shape, and `DeckSummaryBar`'s layout in
one pass, each ported with the real classNames rather than approximated.

**Real functionality gaps got filed as issues, not faked as UI.** The
reference's collection tile has a bulk-select checkbox and a working Edit
button; at the time this app had **no way to reduce or delete a holding**
at all (only `app_add_cards` and `app_move_cards`, same quantity, existed).
Rather than add a checkbox/button that went nowhere, that gap became #29
(edit/remove a holding) and #30 (bulk-select + move) — both since built as
real RPCs and UI (§12).

**This app is now permanently dark** (see the new trap above, §7) — a
deliberate simplification from following the OS preference, since the
reference itself never had a light mode either.

### 9.2 "Select Your Game" and `account.selected_game_id`

The game axis (12, 16) was always in the schema via `card.game_id`, but
nothing in the *app* was aware of it until now — there is exactly one game
(Grand Archive), so nothing needed to ask. Added ahead of an actual second
game existing, at the user's explicit request ("I will want to incorporate
other games later on"):

- `account.selected_game_id` (nullable FK to `game`, `ON DELETE SET NULL`) —
  persisted server-side via `app_set_selected_game(uuid)`. New signups and
  every pre-existing account default to whichever game was created first
  (`app_provision_account`'s backfill), so nobody is ever stuck in a null
  state today.
- `/` is now "Select Your Game" — a page, not just a redirect — reachable
  **signed in or out** ("if someone comes to the website for one game, I
  want them to be able to choose that game instead of being thrown into
  another game completely," direct quote). Signed out, the choice is a
  cookie (`web/app/actions.ts`), since there's no account to persist it on.
- `proxy.ts`'s session check needed a second, *exact-match* public-paths list
  (`PUBLIC_EXACT_PATHS = ['/']`) — `/` cannot go in the existing
  prefix-matched list, since every path starts with `/` and that would make
  the whole app public.
- The nav's logo now always links to `/`, not straight into `/collection` or
  `/cards` — clicking it is how you get back to pick a different game, once
  a second one exists.

**Not built, deliberately:** actually filtering any query (holdings, decks,
catalog search) by `selected_game_id`. With one game in the catalog, every
query is implicitly single-game already, so wiring in a filter now would be
untestable, unexercised code — the definition of the "no half-finished
implementations" rule this project holds itself to. Revisit the day a second
game's catalog is actually ingested.

### 9.3 Nav restructure

The flat link row became dropdown-based, via a small hand-rolled `NavMenu`
component (`web/app/_components/nav-menu.tsx` — click-to-open, click-outside
and Escape to close, no Radix in this codebase):

- **Collection** (dropdown): Collection, Add Cards, Boxes, Lend, Share (§11)
- **Browse Cards** (renamed from "Browse")
- **Decks**
- **Friends** (dropdown): Friends, Lend — Lend is reachable from both
  Collection and Friends on purpose, since it's equally an inventory action
  and a relationship action
- The signed-in **account menu** (username, top right): Inbox (with the
  pending-request badge), Friends, Profile (#40), Game Selection, then Sign
  out below a divider — Inbox dropped off the top-level bar entirely

`/cards` is reachable both signed in and signed out, which resurfaced a bug
worth remembering: it used to always render the anonymous header regardless
of session state, because the page never checked `auth.getUser()` — reading
as "visiting Browse Cards logs you out," when the session was never actually
touched. Fixed by extracting `TopNav` into one shared component both
`/cards` and the `(app)` layout render from the same auth check, so the two
surfaces can't drift apart again.

## 10. Card detail view (#23, closed)

The lightbox added for #19 only enlarged the art. `CardTile` now takes an
optional `onOpenDetail`, which — when passed — replaces that lightbox with
`CardDetailDialog`: cost, element, type/subtype/class, whichever of
power/life/durability/speed/level a card actually has (most cards have none
of these — `null`, not `0`, and the dialog only renders the ones that are
non-null), the rules text (`effect_raw`, plain text — not `effect_html`,
which is safe HTML from the ingest but not worth `dangerouslySetInnerHTML`
for a field with no editorial review between the API and the page),
illustrator, a "Restricted" badge (39), and a switcher across every other
printing of the same card.

Fetched **client-side on open**, not server-rendered: it opens from a click
on an already-rendered grid, not a fresh page load, and catalog tables are
world-readable (RLS `USING (true)`) so no auth is needed either. No RPC or
schema changes — every field lives in `card.attributes` or a `card_edition`
column already; confirmed by querying a handful of live cards directly
before writing any component, rather than assuming the shape from the
schema comment alone.

Wired into `/cards` and `/add` only, per the issue's own scope. `/collection`
and the deck builder keep their plain art-only lightbox for now — nothing
stops `onOpenDetail` reaching them later, it just wasn't asked for here.

## 11. Collection sharing (#22, closed)

A public, read-only link to your collection — reachable by anyone who has
the URL, no account needed, generated from `/collection/share` and opened at
`/shared/[token]`.

**What a share shows, and why:** name, quantity, finish and condition per
`(edition, finish, condition)` group, with copies out on loan broken out as
their own count (`qty_on_loan`) rather than folded into "owned" — **never a
location, and never who is holding a loaned copy.** (14)'s privacy rule
applies here at least as strictly as it does to friends visiting
`friend_visible_holding`; `shared_collection`'s `RETURNS TABLE` simply has no
column that could carry either. This was a real design question resolved
with the user before writing any schema, not assumed — see the trap in §7
about the retired Softgen app's own version of this getting it wrong despite
its type's own doc comment claiming otherwise.

**Open link only, no invited-email restriction.** The retired Softgen
app's `collection_shares` could also restrict a token to one signed-in
address; this project's issue asked specifically for a *public* link, so
that mode was deliberately left out rather than guessed at — an
invited-email restriction is its own feature with its own auth questions
(checking the viewer's JWT email against the share), not a natural
extension of an open token.

**One flat share, not scoped buckets.** The reference app let an owner
toggle personal/for-sale/loaned-out visibility per share. This project's
holdings have no such three-way split to begin with, so `collection_share`
carries no scoping flags at all — every share of an account shows the same
view of that account's whole physical collection. An account may still hold
several share rows (different labels, different expiries), since nothing
about *what* a share shows varies between them; only revocation and expiry
do.

**Resolution follows the request/loan pattern exactly.** `token ->
collection_share` goes through `app_resolve_collection_share`, an internal,
ungranted `SECURITY DEFINER` helper — never called by a client directly,
only by `shared_collection` and `shared_collection_meta` — that returns no
row for an unknown, revoked, or expired token, indistinguishably, same
discipline as `app_require_recipient` elsewhere in this codebase. A guest
viewer never touches `collection_share`'s RLS policy at all; the table's
own policy (`collection_share_own`, SELECT-only) only ever has to answer for
the owner.

**Filed separately rather than bundled in, because they turned out not to
be this issue:** the owner's first answer on scope pulled in showing this
same finish/condition detail to *friends* (not just guests with a public
link), and letting friends request to borrow or buy directly from a listed
card. Both are real, separate pieces of work — #47 (friend-visible
finish/condition — a UI change against the already-computed
`friend_visible_holding` view) and #48 (a listing UI: `listing` and
`app_set_listing` have existed since (27), but nothing in `web/app` has ever
called `app_set_listing`, confirmed by grep, so there is no way today to
even mark a card for trade or sale, let alone request one). Resist the pull
to build those inside this issue's schema — they don't share one.

---

## 12. Editing holdings and bulk moves (#29, #30, closed)

Each physical-box tile on `/collection` has an **Edit** control; lent-out
("with someone else") tiles don't, since none of these RPCs accept a holder
location. A **Select** toggle swaps the Edit controls for checkboxes and a
"move N cards to box X" bar.

**Four single-axis primitives, never one combined edit:**

| Change | RPC | Notes |
|---|---|---|
| Quantity | `app_set_holding` | Absolute set on one bucket, like `app_set_deck_card`. `qty = 0` deletes (UI confirms first). |
| Condition | `app_set_condition` | Moves the tile's whole qty to another condition, same box. |
| Finish | `app_set_finish` | Same shape. The composite FK to `card_edition_finish` rejects a finish the printing doesn't have; the UI only offers valid ones anyway. |
| Box | `app_move_cards` | Pre-existing — reused, not duplicated. |

Why not one "edit everything" RPC: if a single submit changed quantity *and*
condition from "5 NM" to "3 LP", it would have to guess between "move 3,
keep 2 NM" and "throw away 2, relabel the rest". Each dropdown instead acts
immediately on the current quantity, so no action is ambiguous. The first
cut shipped only quantity and condition; the owner asked for box and finish
on top (#51) — that's why they arrived as a follow-up PR.

Bulk move (#30) needed no new RPC: it calls `app_move_cards` once per
selected tile (`Promise.all`), skips tiles already in the target box, and
reports partial failures by count. Selection keys off
`(editionId, locationId, finish, condition)`, not array index, because the
search filter reorders rows.

**Trap worth knowing before touching `db/tests/rpc_smoke.sql`:** that file is
one long running story, and its last assertion checks the owner's *total*
card count exactly (it expects 3, after one write-off). Any new test that adds
or removes cards without putting them back breaks that assertion far
downstream of the actual change. The #29 tests therefore work on buckets
nothing else in the file reads (Box A's FOIL copy, Box B's NONFOIL copy) and
restore them afterward. Check `grep qty_at`/`sum(qty)` in that file before
adding to it — or write a separate suite.

---

## 13. Next steps

Done: auth wiring, catalog import + images + filters, inventory entry
(`/add`, `/locations`), loan flows (`/lend`, `/friends`), a deck builder
(§8), the visual redesign + game-selection landing page (§9), letting the
owner pick a box per card on borrow approval (#12), a card detail view
(§10, #23), a profile page for display name/username (#40), the foil
shimmer treatment and a restricted-card badge (#38, #39), public collection
sharing (§11, #22), and editing/bulk-moving holdings (§12, #29, #30) — all
merged and live in production.

**Open work is tracked as GitHub issues, not in this file.** As of
2026-09-24, all open:

*Carried over, blocked on the user's own credentials/inbox, not code:*
- **#13** — verify email-code sign-in works for a brand new account
  (needs a real signup against a real inbox — deferred until done together)
- **#14** — set up custom SMTP before inviting anyone (needs an SMTP
  provider account and API key only the user can create — deferred)

*Softgen-parity work, filed after reading its actual source (§9.1):*
- **#32**–**#37** — deck cover art, decklist import/export, public deck
  showcase, deck sharing via link, deck duplication, per-deck-card foil/
  printing swap (all detailed in §8). These were the next batch in progress
  when this was written, planned in dependency order: #32 → #33 → #37 →
  #34 + #35 together (they share "a deck readable by a non-owner"
  groundwork, and #35 should copy §11's token pattern) → #36 (needs a deck
  someone else can legitimately read first).
- **#41** — choose which printing represents a card on the collection grid
  (low priority; deliberately deferred until #23's printing-merge behavior
  actually lands on `/collection` — today each holding row is already one
  specific printing, so there is nothing yet for this to disambiguate)

*Grew out of scoping #22, filed separately rather than bundled in (§11):*
- **#47** — show finish and condition in friend-visible holdings, not just
  the aggregate totals `friend_visible_holding` exposes today
- **#48** — a UI for the existing `listing` table / `app_set_listing` RPC
  (27), plus letting a friend request to borrow or buy a listed card

**Notifications** are still the largest gap **not yet filed as an issue** —
(23) already gives it the right shape: one `request` table to watch, one
place to emit from, rather than five. Every flow assumes something tells the
other person; nothing does yet. Worth its own issue before anyone relies on
this with a friend who isn't checking the inbox proactively.

**The app never touches money (29 — the *design decision*, not GitHub issue
#29 above; the numbers collide by coincidence).** A sale listing is an intent
marker with an optional asking price; people settle via PayPal, Zelle, Venmo
or cash on their own. Do not add orders, payments or a sold state — that
turns this into a marketplace, which owes users dispute handling, refunds,
chargeback exposure and money-transmission compliance, none of which makes
knowing where your cards are work any better.

**Pricing**, if it ever comes — `card_edition_finish` is the natural hook,
since it's already keyed the way prices are quoted.

Nothing is blocked. There are no open design questions about the loan model
itself (docs/design/friends-and-loans.md's own open questions, noted at its
top, are pre-existing and unrelated to anything in this session). The deck
sharing/showcase issues (#34, #35) do share groundwork worth designing
together rather than separately — see the cross-reference in each.
