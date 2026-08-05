# Friends, Loans & Inventory — Decision Record

Status: **in progress.** Captures decisions made during design review. Open
questions at the bottom are not yet decided and should not be implemented
around until they are.

## Core model

Three independent axes, deliberately not collapsed into each other:

| Axis | What it is | Who defines it | Drives |
|---|---|---|---|
| **Game / IP** | Pokémon, Magic, a sports league | The catalog | Sharing |
| **Location** | Box A, Binder 1, Safe deposit | The user | Physical storage |
| **Condition** | NM, LP, … | The user, per holding | Value, bucket identity |

A **holding** is the tuple `(card, location, condition, qty)`. There are no
individually tracked copy records — see (8).

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

### 4. Visibility is opt-in per game, globally across friends

Cards are private by default. The owner switches a **game** to friend-visible
— "my Pokémon is shared, my Magic is private" — and that setting applies to
every friend equally. There is no per-friend variation.

Note that a game is an attribute the card already carries from the catalog,
not a grouping the user builds. Sharing therefore needs no grouping table of
its own, and cannot drift out of sync with storage.

**Exception:** a borrower can always see the card they are currently holding,
regardless of that game's visibility setting.

### 5. Unfriending is blocked while a loan is open — but the lender can force-close

An open loan blocks the unfriend. To avoid trapping a lender with a borrower
who simply never responds, the lender can **unilaterally** mark a loan
*returned* or *written off*. The borrower is notified, not consulted. Settling
the loan this way unblocks the unfriend.

**Why the escape hatch:** without it, "borrower must accept" (2) plus "blocked
until settled" deadlocks — a non-responsive or hostile borrower could keep a
loan open forever and hold the relationship hostage over a low-value card.

### 6. Return flow: borrower sends, lender confirms

1. Borrower marks a card **returned** → it enters **in-transit**
2. Lender confirms **receipt** → that card is **closed**

Mirrors the acceptance flow in (2) and survives mail delays, where a card has
left one person's hands but not yet reached the other's. The lender's
force-close from (5) can short-circuit this from any state.

### 7. Borrowed cards are read-only shadows, but the borrower files them

A borrowed card appears in the borrower's app under a **Borrowed** section. It
is:

- excluded from their collection counts
- excluded from their collection value totals
- not editable by them — condition, quantity and card details stay the
  lender's data

The borrower **does** assign it one of their own locations, so they can
actually find a card they are responsible for. The location is the borrower's
data; everything else about the card is the lender's.

### 8. Holdings are quantity buckets keyed by condition — no instance records

A holding is `(card, location, condition, qty)`. Nothing ever promotes a copy
to individually tracked status: 2 Near Mint in Box A and 1 Lightly Played in
Box A are simply two buckets. One uniform shape, no split logic anywhere in
the codebase.

Worked example — a user owns 4 copies of one card:

| Location | Condition | Qty |
|---|---|---|
| Box A | NM | 2 |
| Box B | NM | 1 |
| On loan | NM | 1 |
| **Total** | | **4** |

### 9. Locations are a flat, user-named list

"Box A", "Binder 1", "Safe deposit". No container→slot hierarchy, no nesting.

### 10. "On loan" is a virtual location that remembers where the card came from

- Loaning a card **automatically** moves it out of Box A into the system
  **On loan** bucket, so counts always match physical reality.
- The origin location is stored on the loan.
- On return, the origin is **suggested** as the destination and pre-filled —
  but the user confirms or overrides it. The re-file is never automatic.

### 11. A loan is a batch in, but returns are per-card

Lending a 60-card deck is **one** loan: one hand-off, one acceptance, one
notification. Cards are then checked back in **individually** as they come
back, so a partial return (58 of 60) is a first-class state rather than an
error.

This means a loan has a status *and* each card line within it has a status.

### 12. Cards come from a shared catalog, imported per game

Users add holdings against real catalog entries (name, set, number, image) and
never invent cards. This is what makes search, images, cross-user comparison,
and later pricing possible.

**Cost:** an import pipeline is required per game before that game is usable.

### 13. The lender sets condition at receipt

The loan records the condition each card was in when it left. At receipt
confirmation (6) the lender confirms that condition or downgrades it, and the
card files into the matching bucket.

**Why:** condition is part of the bucket key (8), so a card returned in worse
shape genuinely does not belong in the bucket it left. Recording the departure
condition on the loan also means damage shows up as visible history rather
than a silent edit.

### 14. Friends see cards and quantities, never locations

For a game shared under (4), a friend sees which cards you own, how many, and
in what condition — aggregated across your locations. They never see *where*
anything is stored.

Quantities are the part that matters for deciding what to ask to borrow.
Locations are security-sensitive and stay private even from friends.

### 15. Force-close is per card

The lender's escape hatch (5) settles **individual outstanding cards**, not a
whole loan. This matches per-card returns (11): write off the 2 cards that
never came back without falsifying the 58 that did.

## Open questions

Blocking further schema work.

1. **Which game does the catalog pipeline target first?** Not Magic, Pokémon,
   or sports — an IP still to be named. (12) needs at least one real import
   pipeline before any game is usable, and catalog data quality varies wildly
   between IPs.
2. **Are cards currently on loan shown to friends?** A friend browsing a shared
   game sees quantities (14). Does a copy that's out on loan still count toward
   the number they see, and is its loaned status visible to them?
3. **Can a borrower loan onward?** If someone borrows your deck, can they lend
   one of its cards to a third person? Almost certainly no — but it should be
   an explicit rule, since the borrower does hold the card.
