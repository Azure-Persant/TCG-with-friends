# Friends, Loans & Inventory — Decision Record

Status: **in progress.** Captures decisions made during design review. Open
questions at the bottom are not yet decided and should not be implemented
around until they are.

## Core model

A **holding** is the tuple `(card, location, condition, qty)`, sitting across
three independent axes that are deliberately not collapsed into each other:

| Axis | What it is | Who defines it | Drives |
|---|---|---|---|
| **Game / IP** | Grand Archive (first), others later | The catalog | Sharing |
| **Location** | Box A, Binder 1 — *or a person* | The user | Physical custody |
| **Condition** | NM, LP, … | The user, per holding | Value, bucket identity |

There are no individually tracked copy records — see (8).

### Locations have a kind

| Kind | Example | Meaning |
|---|---|---|
| `physical` | Box A, Binder 1, Safe deposit | You have it |
| `holder` | Sarah (account), "Mike from work" (text) | Someone else has it |

**"On loan" is not a location — it is derived.** Any quantity sitting in a
`holder` location is on loan. This is the single most load-bearing decision in
the model, because three other rules collapse into it:

- **Multiple borrowers disambiguate themselves.** A single shared "On loan"
  bucket holding qty 2 cannot express "Sarah has one, Mike has the other". Two
  holder locations can.
- **Loans to non-users stop being a separate flavor** (3). A non-user is just a
  holder location carrying a name with no linked account.
- **The privacy rule is already implied** (14). Friends see quantities but
  never locations; if the holder *is* a location, "friends can see how many
  cards are on loan but not to whom" requires no special-casing.

Holder locations are created implicitly by the loan flow. Users never
hand-manage them, and they do not appear in the ordinary "move card" picker.

## Decided

### 1. Friendship is a mutual, accepted relationship

Not a one-way follow, not a share link. A friendship exists only after both
parties agree.

**Why:** a loan needs to point at a stable identity, so that a "loaned" tag is
associated with a real account rather than a typed-in name. That requirement
is what makes friendship structural rather than cosmetic.

**Implies:** friend requests have a pending state, and can be declined,
cancelled, and re-sent.

### 2. Loans require borrower acceptance

A loan is a two-sided transaction. It sits **pending** until the friend
confirms, at which point it shows as *loaned out* on the lender's side and
*borrowed* on the borrower's side. Both inventories agree because both parties
signed off.

### 3. Loans to non-users are allowed, as free-text names

Not every borrower will be on the app. A loan may instead name a person with no
account — represented as a holder location with a name and no `account_id`.

The difference reduces to two behaviours rather than two models:

| | Friend loan | Text loan |
|---|---|---|
| Holder location links to | account | name only |
| Borrower confirms | yes | no (lender acts alone) |
| Visible to borrower | yes | n/a |

### 4. Visibility is opt-in per game, globally across friends

Cards are private by default. The owner switches a **game** to friend-visible
— "my Grand Archive is shared" — and that setting applies to every friend
equally. There is no per-friend variation.

A game is an attribute the card already carries from the catalog, not a
grouping the user builds. Sharing therefore needs no grouping table of its own
and cannot drift out of sync with storage.

**Exception:** a borrower can always see the card they are currently holding,
regardless of that game's visibility setting.

### 5. Unfriending is blocked while a loan is open — but the lender can force-close

An open loan blocks the unfriend. To avoid trapping a lender with a borrower
who simply never responds, the lender can **unilaterally** mark a card
*returned* or *written off*. The borrower is notified, not consulted. Settling
this way unblocks the unfriend.

**Why the escape hatch:** without it, "borrower must accept" (2) plus "blocked
until settled" deadlocks — a non-responsive or hostile borrower could keep a
loan open forever and hold the relationship hostage over a low-value card.

### 6. Return flow: borrower sends, lender confirms

1. Borrower marks a card **returned** → it enters **in-transit**
2. Lender confirms **receipt** → that card is **closed**

Mirrors the acceptance flow in (2) and survives mail delays, where a card has
left one person's hands but not yet reached the other's. Force-close (5) can
short-circuit this from any state.

### 7. Borrowed cards are read-only shadows, but the borrower files them

A borrowed card appears in the borrower's app under a **Borrowed** section. It
is excluded from their collection counts and value totals, and they cannot edit
condition, quantity, or card details — that stays the lender's data.

The borrower **does** assign it one of their own locations, so they can find a
card they are responsible for. The location is the borrower's data; everything
else about the card is the lender's.

### 8. Holdings are quantity buckets keyed by condition — no instance records

Nothing ever promotes a copy to individually tracked status: 2 Near Mint in Box
A and 1 Lightly Played in Box A are simply two buckets. One uniform shape, no
split logic anywhere in the codebase.

Worked example — a user owns 4 copies of one card:

| Location | Kind | Condition | Qty |
|---|---|---|---|
| Box A | physical | NM | 2 |
| Box B | physical | NM | 1 |
| Sarah | holder | NM | 1 |
| **Total** | | | **4** |

A friend viewing this sees *4 copies, 1 on loan* — never Box A, Box B, or
Sarah.

### 9. Locations are a flat, user-named list

"Box A", "Binder 1", "Safe deposit". No container→slot hierarchy, no nesting.

### 10. Loans remember their origin and suggest it on return

- Loaning **automatically** moves the quantity out of Box A into the borrower's
  holder location, so counts always match physical reality.
- The origin location is stored on the loan.
- On return, the origin is **suggested** and pre-filled — the user confirms or
  overrides. The re-file is never automatic.

### 11. A loan is a batch in, but returns are per-card

Lending a deck is **one** loan: one hand-off, one acceptance, one notification.
Cards are checked back in **individually**, so a partial return is a
first-class state rather than an error.

A loan therefore has a status *and* each card line within it has a status.

### 12. Cards come from a shared catalog, imported per game

Users add holdings against real catalog entries and never invent cards. This is
what makes search, images, cross-user comparison, and later pricing possible.

**Cost:** an import pipeline is required per game before that game is usable.

### 13. The lender sets condition at receipt

The loan records the condition each card was in when it left. At receipt
confirmation (6) the lender confirms that condition or downgrades it, and the
card files into the matching bucket.

**Why:** condition is part of the bucket key (8), so a card returned in worse
shape genuinely does not belong in the bucket it left. Recording departure
condition also makes damage visible history rather than a silent edit.

### 14. Friends see cards and quantities, never locations

For a shared game, a friend sees which cards you own, how many, and in what
condition — aggregated across locations. They never see *where* anything is.

They **can** see how many copies are currently on loan, because that is derived
from holder locations. They **cannot** see who holds them, because that is the
location itself.

### 15. Force-close is per card

The lender's escape hatch (5) settles **individual outstanding cards**, not a
whole loan. This matches per-card returns (11): write off the 2 cards that
never came back without falsifying the 58 that did.

### 16. First catalog: Grand Archive, via api.gatcg.com

Verified against the live API:

| | |
|---|---|
| Catalog size | 2,240 cards → ~6,400 editions (2.86 printings/card) |
| Search | `GET /cards/search`, paginated |
| Page size | silently caps at **50** — 45 pages for a full crawl |
| Bulk export | none. `/bulk`, `/cards`, `/sets` all 404 |
| Images | `GET /cards/images/{edition_uuid}.jpg`, 65KB–440KB each |
| Card fields | name, slug, uuid, element(s), classes, types, subtypes, cost, level, power, life, durability, speed, effect (raw + html), legality |
| Edition fields | uuid, slug, collector_number, rarity, illustrator, image, orientation, circulations, set (name, prefix, release_date, language) |

**Ingest gotcha:** `total_cards` is unreliable at small page sizes — it
returned `1` for `page_size=1`. Paginate on `has_more`, never on
`total_pages`.

### 17. Card images are served from our own storage, not hot-linked

The app must not hit gatcg.com on every card view. Images are copied into our
own storage and served from there.

Full-resolution mirror is roughly **1.3 GB** at current catalog size.

### 18. Borrowers may loan onward, with owner approval

A borrower can lend a card they are holding to someone else, but the **owner
must approve** the transfer of borrower status before it takes effect.

Under the holder-location model this is a clean operation: the quantity moves
from one holder location to another inside the owner's inventory, so the
owner's view always answers "who has my card right now".

### 19. A sub-loan fully transfers borrower status, but history is retained

Once the owner approves Sarah → Mike:

- Mike becomes the borrower; Sarah is released from responsibility
- The card returns **directly to the owner**, not back through Sarah
- The loan history still records that it passed through Sarah

Keeping the custody trail matters for the case the whole feature exists to
handle: knowing who had a card when it came back damaged or never came back at
all.

### 20. A sub-loan may go to anyone — owner approval is the gate

The borrower may pass a card to their own friend or to a text-name non-user.
The recipient need not be the owner's friend.

**Why:** the owner approves every transfer regardless (18), so approval is the
real protection. Requiring mutual friendship as well would block the ordinary
case where a friend's playgroup needs a card, without adding any safety the
approval step doesn't already provide.

Note this is the one place a `holder` location may point at an account the
owner has no friendship with.

### 21. A holding is keyed by edition and finish

The full bucket key is:

```
(edition, finish, location, condition, qty)
```

A foil Abyssal Heaven printing is a different holding from the non-foil, and
from the same card printed in another set. GATCG exposes editions and tracks
foil/non-foil circulations separately, so this data is available for free at
ingest.

**Why not card-level:** foils routinely carry many times the value of the same
card, and collectors care which set a copy came from. Aggregating them would
make every value total wrong.

Card-level *display* (one row per card, expandable to printings) is a UI
concern layered on top of edition-level storage.

### 22. All images are pre-fetched at ingest

One backfill job pulls all ~6,400 images (~1.3 GB) into our storage. No runtime
dependency on gatcg.com, no first-viewer latency, predictable cost. The job
re-runs when new sets release.

## Open questions

1. **Confirm GATCG's terms permit mirroring their card images** before running
   the full backfill (22). Self-hosting is the right architecture regardless;
   this is about whether redistribution is permitted, and is worth a direct ask
   to the maintainers.

## Implementation

- **`db/schema.sql`** — PostgreSQL schema implementing every decision above.
  Comments cite decision numbers.
- **`db/tests/schema_smoke.sql`** — walks a full loan lifecycle (loan → accept
  → sub-loan transfer → return with condition downgrade → force-close) and
  asserts that the constraints reject the things they are supposed to reject.
  Runs in a transaction and rolls back.

```
createdb fci
psql -d fci -v ON_ERROR_STOP=1 -f db/schema.sql
psql -d fci -v ON_ERROR_STOP=1 -f db/tests/schema_smoke.sql
```

### One rule the schema discovered

`loan_line` holds **exactly one physical card** — no quantity column. That
falls directly out of (13): if the lender sets condition at receipt, and two
copies lent together can come back in different conditions, then a line
carrying qty > 1 would need a condition breakdown inside itself. A 60-card deck
is 60 lines.

This does not contradict (8). A loan line is a *custody* record that exists
only while a card is away and closes when it comes home; a holding is an
*inventory* record. Only the latter is a bucket.

## Still to design

- Authentication and session handling
- The GATCG ingest worker itself (paginated crawl + image backfill)
- Notifications for loan requests, returns, and transfer approvals
- Pricing, if it ever comes — `card_edition_finish` is the natural hook
