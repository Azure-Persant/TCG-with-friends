# db

The database is the application. Every rule that matters — who can see whose
cards, what a loan does to inventory, when a trade transfers ownership — lives
here, not in the front end.

That is deliberate. On Supabase the anon key ships to the browser and can reach
PostgREST directly, so any rule enforced only in the app is a rule that anyone
holding that key can skip.

## Applying it

```bash
npm install

# Supabase (or any remote Postgres)
npm run apply -- --url "postgresql://postgres:PASSWORD@db.YOURREF.supabase.co:5432/postgres"

# Local development — adds the auth shim
npm run apply:local -- --url "postgresql://localhost/fci"

# Local, and run the five test suites afterwards
npm test -- --url "postgresql://localhost/fci"

# Show the plan without changing anything
npm run apply -- --url "..." --dry-run

# Verify an existing install without changing anything
npm run apply -- --url "..." --check
```

Applying always ends with the `--check` pass, so you get a verdict rather than
a guess. Every check corresponds to a way this can fail **silently** — an app
where everything is empty, or everything is visible — because those are the
failures worth a round-trip to rule out:

- all 23 tables present
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

### Getting the connection string

Supabase dashboard → **Project Settings → Database → Connection string → URI**.

Use the **direct connection on port 5432**, not the transaction pooler on 6543.
The pooler does not hold a session between statements, and these scripts need
one. The script refuses a 6543 URL rather than half-applying against it.

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

There is no migration system yet, because there is no data worth preserving
yet. Changing the schema means dropping the database and re-applying.

When real data exists, that stops being acceptable and this needs proper
migrations — most likely the Supabase CLI's, which timestamps files in
`supabase/migrations/` and tracks what has been applied. Worth doing **before**
the first person other than you puts cards in.

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
