# db

The database is the application. Every rule that matters — who can see whose
cards, what a loan does to inventory, when a trade transfers ownership — lives
here, not in the front end.

That is deliberate. On Supabase the anon key ships to the browser and can reach
PostgREST directly, so any rule enforced only in the app is a rule that anyone
holding that key can skip.

## Applying it

**Local development and CI** build from empty with `apply.mjs`, below. **Any
database that holds data that matters** — which today means the live Supabase
project — goes through `supabase/migrations/` instead. See "Changing the
schema" further down; don't point `apply.mjs` at it.

### Local development and CI

```bash
npm install

# Local development — adds the auth shim
npm run apply:local -- --url "postgresql://localhost/fci"

# Local, and run the five test suites afterwards
npm test -- --url "postgresql://localhost/fci"

# Show the plan without changing anything
npm run apply:local -- --url "..." --dry-run

# Verify an existing install without changing anything
npm run apply:local -- --url "..." --check
```

`apply.mjs` refuses to run without `--local`, and refuses a `supabase.com`
host even with it — see "Changing the schema."

Applying always ends with a `--check` pass, so you get a verdict rather than
a guess. Every check corresponds to a way this can fail **silently** — an app
where everything is empty, or everything is visible — because those are the
failures worth a round-trip to rule out:

- all 25 tables present
- RLS enabled on every one of them
- every user-facing table has a policy (RLS on with no policy denies all)
- `catalog_sync_run` still has *no* policy — operational data stays closed
- the mutation functions installed
- `citext` operators resolve (they live in `extensions` on Supabase, not `public`)
- the signup trigger is on `auth.users`
- **every auth user has a matching account** — the one that matters most, since
  ids that do not line up mean `auth.uid()` matches nothing and every page comes
  back empty with no error at all

`$DATABASE_URL` is used when `--url` is omitted.

## The files, in the order they must be applied

| File | What | Re-runnable? |
|---|---|---|
| `schema.sql` | Tables, types, views | No — builds from empty |
| `local/auth_shim.sql` | **Local only.** Stands in for Supabase auth | Yes |
| `auth_bridge.sql` | An `account` row per `auth.users` row | Yes |
| `policies.sql` | Row Level Security | No — `CREATE POLICY` has no `IF NOT EXISTS` |
| `functions.sql` | Every mutation | Yes — all `CREATE OR REPLACE` |

Order is not a style preference. `policies.sql` calls helpers it expects to
exist, `functions.sql` references tables, and `auth_bridge.sql` puts a trigger
on a table `schema.sql` has to have created first. Applying them out of order
does not fail cleanly — it leaves a database that looks built and silently
returns nothing.

**Never apply `local/auth_shim.sql` to Supabase.** It fakes `auth.uid()` and an
`auth.users` table so the policies can be tested without a Supabase project. In
production it would shadow the real ones and every user would resolve to
nobody. `apply.mjs` refuses to do it.

## Changing the schema

Migrations, tracked by the Supabase CLI — see decision 32 in
`docs/design/friends-and-loans.md` for why. The live Supabase project is a
database that holds real accounts now, so `apply.mjs` and dropping/re-applying
are no longer options for it.

A schema change is two edits, not one:

1. Edit the file as always (`schema.sql`, `functions.sql`, `policies.sql` or
   `auth_bridge.sql`) — this stays the fast, from-empty path local dev and CI
   build against.
2. Add a migration carrying just the diff:

   ```bash
   npx supabase migration new <short_description>
   # write the ALTER/CREATE/DROP statements into the file it created
   ```

Nothing enforces that pairing beyond eyes on the PR — that's the main risk to
watch for.

To apply pending migrations to the real project:

```bash
npx supabase db push --db-url "postgresql://postgres.<ref>:PASSWORD@aws-0-<region>.pooler.supabase.com:5432/postgres"
```

Get that URL from the Supabase dashboard's green **Connect** button → **Session
pooler**. Two traps, same as ever:

- **Not Transaction pooler (6543).** Transaction mode does not keep a session
  between statements, which the CLI needs for the migration lock.
- **Session pooler rather than Direct connection**, unless only your own
  machine will ever use it. Supabase's direct connection is IPv6-only without
  the paid IPv4 add-on, and GitHub Actions runners are IPv4-only.

`supabase/migrations/` starts with one **baseline migration**: `schema.sql`,
`auth_bridge.sql`, `policies.sql` and `functions.sql`, concatenated in the
order above, as of the day migrations were adopted (2026-09-21).

The assumption going in was that the live project already had this schema, in
which case pushing the baseline would fail on "already exists" and the fix is
`npx supabase migration repair <version> --status applied --db-url "..."` —
marking it applied without re-running it. **That assumption turned out to be
wrong**: the project was actually running an unrelated app's schema (see
`HANDOFF.md`, "Where this lives"), so the real fix was dropping that schema
and pushing the baseline for real. Keep `migration repair` in mind if you ever
stand up a *second* Supabase project from a database that was hand-built
before migrations existed — this one didn't need it in the end.

After the baseline, `supabase db push` only ever applies migrations the target
doesn't have yet — safe to run again, and safe to run against a database that
has data in it. `supabase/migrations/20260922010000_username_and_unsorted_box.sql`
is the first real example: it ran against the live project on 2026-09-22
alongside real account rows, and nothing was lost.

**Retired rather than kept:** `apply.mjs`'s old remote mode (it applied
`schema.sql` straight to whatever `--url` pointed at — exactly the unmigrated
write this section replaces) and `--emit`/`dist/supabase-setup.sql` (a
one-paste SQL-editor bundle can't record itself in the migrations table, so
`db push` would try to re-run it next time and fail). `apply.mjs` now refuses
anything that isn't `--local`.

## Tests

Five suites, 68 assertions, all rolled back at the end so they change nothing:

| Suite | Covers |
|---|---|
| `tests/schema_smoke.sql` | Constraints and the shapes they forbid |
| `tests/rls_smoke.sql` | Row Level Security from three points of view |
| `tests/rpc_smoke.sql` | A whole loan lifecycle through the RPCs |
| `tests/request_smoke.sql` | Requests, trades, counter-offers, listings |
| `tests/auth_smoke.sql` | The `auth.users` → `account` bridge |

```bash
npm test -- --url "postgresql://localhost/fci"
```

They need `--local`: they create an unprivileged role and forge JWT claims, so
they only make sense against the shim.
