# Handoff

Everything established so far, for whoever picks this up next — including a
future me.

**Status:** design settled, database built and tested, catalog ingest working.
**No application code exists yet.** This branch is deliberately all foundation.

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

Full list of all 22 with rationale: **`docs/design/friends-and-loans.md`**.
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

## 4. Two bugs the tests caught

Both are recorded because they'd be easy to reintroduce.

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

### Empty buckets must be deleted, not zeroed

`qty > 0` is enforced, so decrementing a bucket to zero is rejected outright.
The caller has to delete instead. This was implicit in the design and only
became explicit when the smoke test tripped over it on a final return.

---

## 5. What exists

| Path | What |
|---|---|
| `docs/design/friends-and-loans.md` | All 22 decisions with rationale. The source of truth. |
| `db/schema.sql` | 16 tables, 2 views. Portable Postgres, no Supabase dependency. |
| `db/policies.sql` | Row Level Security. **Required on Supabase.** |
| `db/local/auth_shim.sql` | Local stand-in for `auth.uid()`. Never load on Supabase. |
| `db/tests/schema_smoke.sql` | Full loan lifecycle + 21 constraint rejections. |
| `db/tests/rls_smoke.sql` | Owner / friend / stranger visibility, as an unprivileged role. |
| `ingest/` | GATCG catalog + image worker. TypeScript, one dependency (`pg`). |
| `docs/data/editions_missing_circulation.csv` | The 636 editions with no upstream finish data. |

Verified against PostgreSQL 16: schema applies clean, both test suites pass,
and the ingest ran end-to-end against a real database.

### Running it

```bash
createdb fci
psql -d fci -v ON_ERROR_STOP=1 -f db/schema.sql
psql -d fci -v ON_ERROR_STOP=1 -f db/local/auth_shim.sql   # local only
psql -d fci -v ON_ERROR_STOP=1 -f db/policies.sql
psql -d fci -v ON_ERROR_STOP=1 -f db/tests/schema_smoke.sql
psql -d fci -v ON_ERROR_STOP=1 -f db/tests/rls_smoke.sql

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

---

## 8. Next steps

1. **Auth wiring** — Supabase auth, with `account.id` mirroring
   `auth.users.id`, which is what every policy in `db/policies.sql` assumes.
2. **Inventory entry** — the first real test of the wide bucket key.
3. **Loan flows** — request, accept, return, force-close, transfer approval.
4. **Notifications** — loan requests, returns, transfer approvals. No design
   exists yet.
5. **Pricing**, if it ever comes — `card_edition_finish` is the natural hook,
   since it's already keyed the way prices are quoted.

Nothing is blocked. There are no open design questions.
