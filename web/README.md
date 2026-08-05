# web

The Next.js front end. App Router, Supabase Auth, Tailwind.

## Running it

```bash
cp .env.local.example .env.local   # fill in from your Supabase project
npm install
npm run dev
```

## Setting up the database side

Apply these to your Supabase project, in order, from the SQL editor:

| Order | File | Why |
|---|---|---|
| 1 | `../db/schema.sql` | Tables, types, views |
| 2 | `../db/auth_bridge.sql` | Creates an `account` row per `auth.users` row |
| 3 | `../db/policies.sql` | Row Level Security |
| 4 | `../db/functions.sql` | Every mutation |

Do **not** apply `../db/local/auth_shim.sql` to Supabase. It fakes `auth.uid()`
and an `auth.users` table for local testing, and loading it in production would
shadow the real ones.

In **Authentication → URL Configuration**, add `http://localhost:3000/**` to the
redirect allow-list, or the magic link will bounce.

## How auth works here

Sign-in is a magic link — no passwords, so no reset flow and no credential
worth stealing.

1. `app/login` calls `signInWithOtp`, which emails a link.
2. The link lands on `app/auth/confirm`, which exchanges the token for a
   session cookie.
3. `proxy.ts` refreshes that cookie on every request and redirects signed-out
   visitors to `/login`. Next.js 16 renamed this file convention from
   `middleware` to `proxy` — most Supabase documentation still calls it
   `middleware.ts`, so if you are following a guide, `proxy.ts` is the file it
   means.

**The proxy is not the security boundary.** RLS in the database is.
Someone who bypasses the middleware reaches pages whose queries return nothing,
because every query is filtered by `auth.uid()` inside Postgres. The middleware
exists so signed-out users see a login screen instead of empty tables.

Two habits worth keeping:

- Use `supabase.auth.getUser()`, never `getSession()`, on the server.
  `getUser()` revalidates the token with Supabase; `getSession()` trusts a
  cookie the client could have forged.
- Do not add `.eq('account_id', user.id)` to queries. RLS already does it. A
  filter here implies the privacy rule lives in the page, and eventually
  someone deletes it as redundant.

## What exists

- `/login` — magic-link sign in
- `/collection` — your holdings, grouped by where they are, with lent-out cards
  flagged
- `/inbox` — pending requests of all five kinds, accept or decline

Mutations go through the `app_*` RPCs. Nothing writes to a table directly,
because the tables reject it.
