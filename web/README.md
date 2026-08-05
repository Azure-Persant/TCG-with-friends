# web

The Next.js front end. App Router, Supabase Auth, Tailwind.

## Running it

```bash
cp .env.local.example .env.local   # fill in from your Supabase project
npm install
npm run dev
```

## Setting up the database side

```bash
cd ../db && npm install
npm run apply -- --url "postgresql://postgres:PASSWORD@db.YOURREF.supabase.co:5432/postgres"
```

Connection string: Supabase dashboard → **Project Settings → Database →
Connection string → URI**. Use the **direct** connection on port 5432, not the
transaction pooler on 6543.

See `../db/README.md` for what it applies and why the order matters.

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

## Deploying to Vercel

The app lives in `web/`, not the repo root, and there is no root
`package.json`. Vercel cannot autodetect that, so **Root Directory must be set
to `web`** when importing the project — otherwise the build fails with no
framework detected.

Two environment variables, both from Supabase → Project Settings → Data API:

| Name | Value |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | Project URL |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | anon / publishable key |

Then, in Supabase → Authentication → URL Configuration:

- **Site URL**: your production Vercel URL
- **Redirect URLs**: add `https://your-app.vercel.app/**` and, if you also run
  locally, `http://localhost:3000/**`

Sign-in links bounce without that allow-list entry. Preview deployments get
their own subdomain each time, so add `https://*-yourteam.vercel.app/**` too if
you want magic links to work on previews.

`emailRedirectTo` is built from `window.location.origin` rather than a
hardcoded URL, so localhost, previews and production all work off one build.

## What exists

- `/login` — magic-link sign in
- `/collection` — your holdings, grouped by where they are, with lent-out cards
  flagged
- `/inbox` — pending requests of all five kinds, accept or decline

Mutations go through the `app_*` RPCs. Nothing writes to a table directly,
because the tables reject it.
