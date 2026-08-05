# Friends & Loans — Decision Record

Status: **in progress.** Captures decisions made during design review. Open
questions at the bottom are not yet decided and should not be implemented
around until they are.

## Decided

### 1. Friendship is a mutual, accepted relationship

Not a one-way follow, not a share link. A friendship exists only after both
parties agree.

**Why:** a loan needs to point at a stable identity, so that a "loaned" tag is
associated with a real account rather than a typed-in name. That requirement
is what makes friendship structural rather than cosmetic.

**Implies:** friend requests have a pending state, and requests can be
declined, cancelled, and (presumably) re-sent.

### 2. Loans require borrower acceptance

A loan is a two-sided transaction. It sits **pending** until the friend
confirms, at which point it shows as *loaned out* on the lender's side and
*borrowed* on the borrower's side. Both inventories agree because both parties
signed off.

### 3. Loans to non-users are allowed, as free-text names

Not every borrower will be on the app. A loan may instead record a plain name
string.

Two flavors of loan therefore exist, and every screen and query must handle
both:

| | Friend loan | Text loan |
|---|---|---|
| Points at | account id | name string |
| Borrower confirms | yes | no |
| Visible to borrower | yes | n/a |
| Return flow | two-step (see 6) | lender marks returned |

### 4. Friend visibility is opt-in per collection

Cards are private by default. The owner marks collections as friend-visible.
Accepting a friend request grants no blanket read access.

**Exception:** a borrower can always see the card they are currently holding,
regardless of the collection's visibility setting.

### 5. Unfriending is blocked while a loan is open — but the lender can force-close

An open loan blocks the unfriend. To avoid trapping a lender with a borrower
who simply never responds, the lender can **unilaterally** mark a loan
*returned* or *written off*. The borrower is notified, not consulted. Settling
the loan this way unblocks the unfriend.

**Why the escape hatch:** without it, "borrower must accept" (2) plus "blocked
until settled" deadlocks — a non-responsive or hostile borrower could keep a
loan open forever and hold the relationship hostage over a low-value card.

### 6. Return flow: borrower sends, lender confirms

1. Borrower marks the card **returned** → loan enters **in-transit**
2. Lender confirms **receipt** → loan **closed**

Mirrors the acceptance flow in (2) and survives mail delays, where the card has
left one person's hands but not yet reached the other's. The lender's
force-close from (5) can short-circuit this from any state.

### 7. Borrowed cards are read-only shadows for the borrower

A borrowed card appears in the borrower's app under a **Borrowed** section. It
is:

- excluded from their collection counts
- excluded from their collection value totals
- not editable by them

This keeps a hard line between *owned* and *merely held*.

### 8. Card identity: hybrid, with location as a first-class part of inventory

A card is neither purely a catalog row with a count, nor purely a set of
individually tracked physical copies. Holdings are tracked per **location**,
and a loan is one of the places a copy can be.

Worked example — a user owns 4 copies of one card:

| Location | Qty |
|---|---|
| Box A | 2 |
| Box B | 1 |
| On loan | 1 |
| **Total** | **4** |

## Open questions

Blocking further schema work.

1. **Is "on loan" literally a location bucket?** Leading option: a virtual
   location that remembers the copy came from Box A, so confirming the return
   re-files it automatically. Alternatives: no memory (re-file by hand on
   return), or purely derived from the loan table (but then Box A's stored
   count includes cards that aren't physically in Box A).
2. **Is a collection the same thing as a location?** (4) shares per
   *collection*, (8) stores per *location*. Either they're one concept — share
   per location, fewer moving parts, but sharing is tied to physical storage —
   or two, with curated collections spanning locations.
3. **How are locations structured?** Flat user-named list ("Box A", "Binder 1",
   "Safe deposit"), two levels (container → slot), or arbitrary nesting.
4. **In the hybrid model, what promotes a copy to individual tracking?**
   Leading option: nothing does — make condition part of the bucket key, so a
   holding is `(card, location, condition, qty)` and there is only ever one
   shape. Alternatives: grading promotes a copy to its own record, or a manual
   pin does.
