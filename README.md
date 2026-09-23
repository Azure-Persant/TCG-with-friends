# TCG with Friends

A card inventory app for [Grand Archive](https://index.gatcg.com), built around
loaning cards to friends and tracking who has what.

**Start here: [`HANDOFF.md`](./HANDOFF.md)** — current state, the data model,
where this repo came from, and why it looks the way it does.

| | |
|---|---|
| [`HANDOFF.md`](./HANDOFF.md) | Orientation. Read this first. |
| [`docs/design/friends-and-loans.md`](./docs/design/friends-and-loans.md) | All 34 design decisions with rationale. |
| [`db/`](./db) | PostgreSQL schema, RLS policies, and tests. |
| [`supabase/migrations/`](./supabase/migrations) | Schema history, applied to the live project with the Supabase CLI. |
| [`web/`](./web) | The Next.js app itself: auth, collection, catalog browsing, a deck builder, friends, lending, inbox. |
| [`ingest/`](./ingest) | Grand Archive catalog and image worker. |

Status: database built, migrated and tested; catalog and images imported for
real; a Next.js app with working auth, collection management, a public
catalog browser with filters and a card detail view, a deck builder,
friends, lending, an inbox, and public collection sharing is live against a
real Supabase project.
