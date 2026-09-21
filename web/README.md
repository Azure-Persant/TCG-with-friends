# web

The Next.js front end. App Router, Supabase Auth, Tailwind.

## Running it

```bash
cp .env.local.example .env.local   # fill in from your Supabase project
npm install
npm run dev
```

## Setting up the database side

The live project's schema is applied through migrations now, not a direct
apply — see `../db/README.md`, "Changing the schema":

```bash
npx supabase db push --db-url "postgresql://postgres.YOURREF:PASSWORD@aws-0-REGION.pooler.supabase.com:5432/postgres"
```

Connection string: Supabase dashboard → green **Connect** button → **Session
pooler** (port 5432). Not Transaction pooler (6543), which does not hold a
session between statements.

In **Authentication → URL Configuration**, add `http://localhost:3000/**` to the
redirect allow-list, or the magic link will bounce.

## How auth works here

**Google sign-in**, with an emailed six-digit **code** as a fallback. No
passwords, so no reset flow and no credential worth stealing.

Google is the recommended route because it removes email from the critical
path: nothing is sent, so nothing can be scanned, rate-limited or filtered.

### Setting up Google sign-in

1. **Google Cloud Console** → create a project → **APIs & Services →
   Credentials → Create Credentials → OAuth client ID** → *Web application*.
2. Under **Authorised redirect URIs**, add the callback shown in Supabase →
   **Authentication → Sign In / Providers → Google**. It looks like
   `https://YOURREF.supabase.co/auth/v1/callback`. It is Supabase's URL, not
   your app's — a common thing to get wrong.
3. Copy the **Client ID** and **Client secret** into that Supabase Google
   provider page and enable it.
4. In Supabase → **Authentication → URL Configuration**, make sure your Vercel
   URL is the Site URL and is in the Redirect URLs list.

The app's own callback is `/auth/callback`, which exchanges the returned code
for a session cookie.

### The login screen offers a link *and* a code

Which one actually arrives depends on the email template, and **the template
cannot be edited until custom SMTP is configured** — Supabase's built-in email
service always sends its own stock template, which is link-only. So the screen
accepts either, and whichever the email contains is the one that works.

### If your mailbox scans links ⚠️

Microsoft Safe Links, Proofpoint URL Defense and similar pre-fetch every URL in
an incoming message. A magic link is a single-use token, so the scanner spends
it before you click and sign-in fails claiming the link is invalid. **No
application code can fix this** — any URL that authenticates by being visited
is a URL a scanner can spend.

The only fix is a code-only email, which means custom SMTP:

1. Set up an SMTP provider under **Project Settings → Authentication → SMTP**.
2. Then **Authentication → Emails → Magic Link** (and **Confirm signup**)
   becomes editable. The body must contain `{{ .Token }}` and must **not**
   contain `{{ .ConfirmationURL }}`.

A minimal template:

```html
<h2>Your sign-in code</h2>
<p>{{ .Token }}</p>
<p>It expires in an hour.</p>
```

The link must come out, not merely sit alongside the code: they are two
representations of the *same token*, so a scanner following the link
invalidates the code too — and that failure looks identical to having changed
nothing.

**Custom SMTP is needed before anyone else uses this regardless.** Supabase's
built-in email service is rate-limited to a handful of messages per hour and is
documented as being for testing only.

1. `app/login` calls `signInWithOtp`, which emails a code.
2. The user types it; `verifyOtp` exchanges it for a session cookie.
3. `proxy.ts` refreshes that cookie on every request and redirects signed-out
   visitors to `/login`.

`app/auth/confirm` still exists for link-style emails (an email-change
confirmation, say), but nothing routine goes through it any more. Next.js 16 renamed this file convention from
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
| `NEXT_PUBLIC_SUPABASE_URL` | Project URL — just `https://ref.supabase.co`, no path |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | anon / publishable key |

`lib/supabase/env.ts` normalises the URL (trailing slashes are stripped) and
refuses clearly on the mistakes it cannot fix — a URL with a path, or the
`service_role` key in a `NEXT_PUBLIC_` variable. Left unchecked, a trailing
slash produces `https://ref.supabase.co//auth/v1/otp` and Supabase answers
`Invalid path specified in request URL`, which names neither the setting nor
the slash.

**Environment variable changes do not apply to an existing deployment.** After
editing one, redeploy.

Then, in Supabase → Authentication → URL Configuration:

- **Site URL**: your production Vercel URL
- **Redirect URLs**: add `https://your-app.vercel.app/**` and, if you also run
  locally, `http://localhost:3000/**`

Sign-in links bounce without that allow-list entry. Preview deployments get
their own subdomain each time, so add `https://*-yourteam.vercel.app/**` too if
you want magic links to work on previews.

`emailRedirectTo` is built from `window.location.origin` rather than a
hardcoded URL, so localhost, previews and production all work off one build.

## Trying it before the catalog import

The Ingest catalog workflow fills the catalog from api.gatcg.com. Until it has
run there is nothing to search for, so `/add` will find nothing.

To try the UI now, paste `../db/sample_cards.sql` into the Supabase SQL editor.
It adds four obviously-fake cards in a set called "Sample Set (placeholder
data)" — deliberately not real card names, so nothing is mistaken for imported
catalog data. The file ends with the SQL to remove them again.

## What exists

- `/login` — magic-link sign in
- `/collection` — your holdings, grouped by where they are, with lent-out cards
  flagged
- `/add` — search the catalog and put copies in a box
- `/locations` — name the boxes you keep cards in
- `/inbox` — pending requests of all five kinds, accept or decline

Mutations go through the `app_*` RPCs. Nothing writes to a table directly,
because the tables reject it.
