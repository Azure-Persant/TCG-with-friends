#!/usr/bin/env node
//
// Applies the database files, in the one order that works, to any Postgres.
//
//   node db/apply.mjs --url "postgresql://..."      # Supabase
//   node db/apply.mjs --url "..." --local           # local dev (adds the shim)
//   node db/apply.mjs --url "..." --local --tests   # ...and run the suites
//   node db/apply.mjs --url "..." --dry-run         # just show the plan
//
// DATABASE_URL is used if --url is omitted.
//
// WHY THIS EXISTS
//
// The files must be applied in order: policies.sql references helper functions,
// functions.sql references tables, auth_bridge.sql triggers on a table
// schema.sql must already have created. Get the order wrong and you do not get
// a clean failure -- you get a partly-built database that looks fine until
// something silently returns nothing.
//
// It also stops one specific mistake. db/local/auth_shim.sql fakes auth.uid()
// and auth.users for local testing. Applying it to Supabase would shadow the
// real ones, and every user would resolve to nobody. It is opt-in behind
// --local, and refuses to run against a supabase.com host at all.

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import pg from 'pg'

const HERE = dirname(fileURLToPath(import.meta.url))

/** Order matters. See the comment above. */
const SCHEMA_FILES = [
  ['schema.sql', 'Tables, types and views'],
  ['local/auth_shim.sql', 'LOCAL ONLY: stands in for Supabase auth', { localOnly: true }],
  ['auth_bridge.sql', 'Provisions an account per auth user'],
  ['policies.sql', 'Row Level Security', { notIdempotent: true }],
  ['functions.sql', 'Every mutation'],
]

const TEST_FILES = [
  'tests/schema_smoke.sql',
  'tests/rls_smoke.sql',
  'tests/rpc_smoke.sql',
  'tests/request_smoke.sql',
  'tests/auth_smoke.sql',
]

function parseArgs(argv) {
  const args = {
    url: process.env.DATABASE_URL,
    local: false,
    tests: false,
    dryRun: false,
    check: false,
  }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--url') args.url = argv[++i]
    else if (a === '--local') args.local = true
    else if (a === '--tests') args.tests = true
    else if (a === '--dry-run') args.dryRun = true
    else if (a === '--check') args.check = true
    else if (a === '--help' || a === '-h') args.help = true
    else {
      console.error(`Unknown argument: ${a}`)
      process.exit(2)
    }
  }
  return args
}

const USAGE = `
Apply the database files in order.

  node db/apply.mjs --url "postgresql://..."     Supabase or any Postgres
  node db/apply.mjs --local                      add the local auth shim
  node db/apply.mjs --local --tests              ...and run the test suites
  node db/apply.mjs --dry-run                    show the plan, change nothing
  node db/apply.mjs --check                      verify an install, change nothing

Falls back to $DATABASE_URL when --url is omitted.

Get the Supabase URL from: Project Settings -> Database -> Connection string.
Use the DIRECT connection (port 5432), not the transaction pooler (6543) --
the pooler does not keep a session, and these scripts rely on one.
`

function plan(args) {
  return SCHEMA_FILES.filter(([, , opts]) => !opts?.localOnly || args.local)
}

async function runFile(client, relPath, label) {
  const sql = readFileSync(join(HERE, relPath), 'utf8')
  const started = Date.now()
  try {
    await client.query(sql)
    console.log(`  ok    ${relPath.padEnd(22)} ${label ?? ''} (${Date.now() - started}ms)`)
    return true
  } catch (err) {
    console.error(`  FAIL  ${relPath}`)
    console.error(`        ${err.message}`)
    if (err.position) {
      // Turn a byte offset into something a human can find.
      const upto = sql.slice(0, Number(err.position))
      const line = upto.split('\n').length
      console.error(`        at ${relPath}:${line}`)
    }
    if (err.hint) console.error(`        hint: ${err.hint}`)

    // By far the most common confusion: pointing this at a database that
    // already has the schema. Say so plainly instead of leaving a bare
    // "already exists" to be interpreted.
    if (err.code === '42710' || err.code === '42P07' || err.code === '42723') {
      console.error(
        '\n        This database already has the schema.\n' +
          '        schema.sql builds from empty -- it is not a migration and cannot\n' +
          '        be re-run over itself. Either use a fresh database, or apply only\n' +
          '        the file you changed. functions.sql alone IS safe to re-run.',
      )
    }
    return false
  }
}

/**
 * Verify an install rather than trusting that it worked.
 *
 * Every check here corresponds to a way this can fail SILENTLY -- no error,
 * just an app where everything is empty or everything is visible. Those are
 * the failures worth spending a round-trip to rule out.
 */
async function verify(client, { isSupabase }) {
  const checks = []
  const add = (ok, label, detail) => checks.push({ ok, label, detail })

  const tables = await client.query(`
    SELECT c.relname, c.relrowsecurity,
           (SELECT count(*) FROM pg_policy p WHERE p.polrelid = c.oid) AS policies
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind = 'r'
     ORDER BY c.relname`)

  add(tables.rowCount === 23, `23 tables present`, `found ${tables.rowCount}`)

  const noRls = tables.rows.filter((r) => !r.relrowsecurity).map((r) => r.relname)
  add(
    noRls.length === 0,
    'Row Level Security on every table',
    noRls.length ? `UNPROTECTED: ${noRls.join(', ')}` : undefined,
  )

  // RLS enabled with no policy denies everything. For catalog_sync_run that is
  // the intent -- ingest bookkeeping, service-role only. For anything else it
  // means a table nobody can read, which is a bug that presents as an empty
  // screen. So both directions are asserted.
  const DELIBERATELY_DENY_ALL = new Set(['catalog_sync_run'])

  const noPolicy = tables.rows
    .filter((r) => Number(r.policies) === 0 && !DELIBERATELY_DENY_ALL.has(r.relname))
    .map((r) => r.relname)
  add(
    noPolicy.length === 0,
    'every user-facing table has a policy',
    noPolicy.length ? `no policy, so denies all: ${noPolicy.join(', ')}` : undefined,
  )

  const leaked = tables.rows
    .filter((r) => Number(r.policies) > 0 && DELIBERATELY_DENY_ALL.has(r.relname))
    .map((r) => r.relname)
  add(
    leaked.length === 0,
    'operational tables stay closed',
    leaked.length ? `now readable by users: ${leaked.join(', ')}` : undefined,
  )

  const fns = await client.query(`
    SELECT count(*)::int AS n FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname LIKE 'app\\_%'`)
  add(fns.rows[0].n >= 30, 'mutation functions installed', `found ${fns.rows[0].n}`)

  // citext lives in `extensions` on Supabase. If a SECURITY DEFINER function
  // cannot resolve its operators, comparisons fail far from the cause.
  try {
    const r = await client.query(`SELECT ('A'::citext = 'a'::citext) AS ok`)
    add(r.rows[0].ok === true, 'citext operators resolve')
  } catch (err) {
    add(false, 'citext operators resolve', err.message)
  }

  const trg = await client.query(`
    SELECT tgname FROM pg_trigger
     WHERE tgrelid = 'auth.users'::regclass AND NOT tgisinternal`)
  const names = trg.rows.map((r) => r.tgname)
  add(
    names.includes('on_auth_user_created'),
    'signup provisions an account',
    names.length ? `triggers: ${names.join(', ')}` : 'no triggers on auth.users',
  )

  // The one that matters most: ids that do not line up mean auth.uid() matches
  // nothing, and every page in the app comes back empty with no error.
  const orphans = await client.query(`
    SELECT count(*)::int AS n FROM auth.users u
     WHERE u.email IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM account a WHERE a.id = u.id)`)
  add(
    orphans.rows[0].n === 0,
    'every auth user has a matching account',
    orphans.rows[0].n ? `${orphans.rows[0].n} user(s) with no account row` : undefined,
  )

  const uid = await client.query(`SELECT to_regprocedure('auth.uid()') IS NOT NULL AS ok`)
  add(uid.rows[0].ok, 'auth.uid() exists')

  console.log('Checking:')
  let failed = 0
  for (const c of checks) {
    if (!c.ok) failed++
    const mark = c.ok ? 'ok  ' : 'FAIL'
    console.log(`  ${mark}  ${c.label}${c.detail ? ` -- ${c.detail}` : ''}`)
  }

  if (!failed && isSupabase) {
    console.log('\nLooks good. Sign in through the app and confirm an account row appears.')
  }
  return failed
}

async function main() {
  const args = parseArgs(process.argv.slice(2))

  if (args.help) {
    console.log(USAGE)
    return 0
  }

  if (!args.url) {
    console.error('No connection string. Pass --url "postgresql://..." or set DATABASE_URL.')
    console.error(USAGE)
    return 2
  }

  const isSupabase = /supabase\.(co|com|net)/.test(args.url)

  // The one mistake worth making impossible rather than merely documenting.
  if (isSupabase && args.local) {
    console.error('Refusing to apply the local auth shim to Supabase.')
    console.error('It would shadow the real auth.uid(), and every user would resolve to nobody.')
    return 2
  }

  if (isSupabase && /:6543\//.test(args.url)) {
    console.error('That looks like the transaction pooler (port 6543).')
    console.error('Use the direct connection on port 5432 -- these scripts need a real session.')
    return 2
  }

  // The suites create an app_user role and forge JWT claims; against real
  // Supabase they would fail for reasons that have nothing to do with the
  // code under test.
  if (args.tests && !args.local) {
    console.error('--tests needs --local. The suites depend on the local auth shim.')
    return 2
  }

  const files = plan(args)

  console.log(`\nTarget: ${args.url.replace(/:[^:@/]+@/, ':****@')}`)
  console.log(`Mode:   ${args.local ? 'local (with auth shim)' : 'remote (real Supabase auth)'}\n`)

  if (args.dryRun) {
    console.log('Would apply, in this order:')
    for (const [f, label] of files) console.log(`  ${f.padEnd(22)} ${label}`)
    if (args.tests) {
      console.log('\nThen run:')
      for (const t of TEST_FILES) console.log(`  ${t}`)
    }
    console.log('\n(--dry-run: nothing was changed)\n')
    return 0
  }

  const client = new pg.Client({
    connectionString: args.url,
    // Supabase terminates TLS with its own CA; node-postgres does not ship it.
    ssl: isSupabase ? { rejectUnauthorized: false } : undefined,
  })

  try {
    await client.connect()
  } catch (err) {
    console.error(`Could not connect: ${err.message}`)
    return 1
  }

  if (args.check) {
    const failed = await verify(client, { isSupabase })
    await client.end()
    console.log('')
    return failed ? 1 : 0
  }

  console.log('Applying:')
  for (const [file, label, opts] of files) {
    const ok = await runFile(client, file, label)
    if (!ok) {
      if (opts?.notIdempotent) {
        console.error(
          '\npolicies.sql is not re-runnable: CREATE POLICY has no IF NOT EXISTS.\n' +
            'If the policies already exist, this failure is expected and harmless.',
        )
      }
      await client.end()
      return 1
    }
  }

  if (args.tests) {
    console.log('\nTesting:')
    let failed = 0
    for (const t of TEST_FILES) {
      // Every suite ends in ROLLBACK, so running them changes nothing.
      const ok = await runFile(client, t)
      if (!ok) failed++
    }
    if (failed) {
      console.error(`\n${failed} suite(s) failed.\n`)
      await client.end()
      return 1
    }
  }

  console.log('')
  const failed = await verify(client, { isSupabase })

  if (isSupabase) {
    // PostgREST caches the schema. Without this the new RPCs 404 for a while
    // after applying, which reads exactly like "the functions did not install".
    await client.query(`NOTIFY pgrst, 'reload schema'`)
    console.log('\nAsked PostgREST to reload its schema cache.')
  }

  await client.end()
  if (failed) {
    console.error(`\n${failed} check(s) failed. The database is applied but not right.\n`)
    return 1
  }
  console.log('\nDone.\n')
  return 0
}

main().then((code) => process.exit(code))
