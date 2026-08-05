# friends-card-inventory

A card inventory app for [Grand Archive](https://index.gatcg.com), built around
loaning cards to friends and tracking who has what.

**Start here: [`HANDOFF.md`](./HANDOFF.md)** — current state, the data model,
and why it looks the way it does.

| | |
|---|---|
| [`HANDOFF.md`](./HANDOFF.md) | Orientation. Read this first. |
| [`docs/design/friends-and-loans.md`](./docs/design/friends-and-loans.md) | All 22 design decisions with rationale. |
| [`db/`](./db) | PostgreSQL schema, RLS policies, and tests. |
| [`ingest/`](./ingest) | Grand Archive catalog and image worker. |

Status: design settled, database built and tested, catalog ingest working. No
application code yet.
