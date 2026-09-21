<!-- BEGIN:nextjs-agent-rules -->

# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` (resolved from this file's directory; in monorepos the `next` package may not be visible from the repo root) before writing any code. Heed deprecation notices.

This block is written and re-added by `next dev` — verify at `node_modules/next/dist/server/lib/generate-agent-files.js`. Removing it from a diff only re-creates the uncommitted change; committing it with your work keeps the tree clean.

<!-- END:nextjs-agent-rules -->

# Working in this app

Read `../docs/design/friends-and-loans.md` before changing behaviour. The
parenthesised numbers throughout this codebase — `(14)`, `(23)` — cite numbered
decisions in that document, and they are the reasons things are the way they
are.

## Two rules that are easy to break by tidying up

**Never add `.eq('account_id', user.id)` to a query.** Row Level Security in
Postgres already restricts every table to the caller. A filter in a page
implies the privacy rule lives in the page, and the next person removes it as
redundant — or worse, keeps it and stops thinking about RLS.

**Use `supabase.auth.getUser()`, never `getSession()`, on the server.**
`getUser()` revalidates the token with Supabase. `getSession()` trusts a cookie
the client controls.

## Mutations go through RPCs

Every write is an `app_*` function in `../db/functions.sql`, called with
`supabase.rpc(...)`. The tables reject direct writes, deliberately: on Supabase
the anon key reaches PostgREST directly, so any rule enforced only in this app
is a rule anyone holding that key can skip.

If a mutation needs new behaviour, it changes in `functions.sql` and gets a
test in `../db/tests/`. Not here. If that change touches the schema (a new
column, table, or anything else DDL), it also needs a file under
`../supabase/migrations/` — see `../db/README.md`, "Changing the schema" (32).
