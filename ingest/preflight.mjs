/**
 * Check the connection string before doing any work, and say something useful
 * when it is wrong.
 *
 * This is Node rather than shell on purpose. It began as a bash `if` block in
 * the workflow, which failed instantly on a self-hosted WINDOWS runner --
 * PowerShell is the default shell there, and it parsed `if [ -z "$X" ]` as a
 * syntax error. Node runs identically on every runner the project might ever
 * use, and the ingest already depends on it.
 */

import pg from 'pg'

const url = process.env.DATABASE_URL

function fail(title, ...lines) {
  // ::error:: turns the first line into a GitHub annotation, so the cause is
  // visible on the run summary without opening the log.
  console.log(`::error::${title}`)
  for (const line of lines) console.log(line)
  process.exit(1)
}

if (!url) {
  fail(
    'DATABASE_URL secret is not set.',
    'Add it under Settings -> Secrets and variables -> Actions.',
    'Value: Supabase dashboard -> green "Connect" button -> Session pooler.',
  )
}

let parsed
try {
  parsed = new URL(url)
} catch {
  fail('DATABASE_URL is not a valid connection string.', 'Expected postgresql://user:password@host:port/database')
}

if (parsed.port === '6543') {
  fail(
    'That is the Transaction pooler (port 6543).',
    'Transaction mode does not keep a session between statements, and the',
    'ingest needs one. Use the Session pooler instead — also port 5432.',
  )
}

// db.<ref>.supabase.co is the DIRECT connection. Supabase serves it over IPv6
// only unless the paid IPv4 add-on is enabled, so on an IPv4-only runner it
// fails to resolve at all -- "getaddrinfo ENOTFOUND", which names DNS and not
// the actual mistake. Catch it here while there is still room to explain.
if (/^db\.[a-z0-9]+\.supabase\.co$/i.test(parsed.hostname)) {
  fail(
    'That is the Direct connection, which will not work from a CI runner.',
    '',
    `  host: ${parsed.hostname}`,
    '',
    'Supabase serves the direct connection over IPv6 only, unless you have',
    'bought the IPv4 add-on. Most runners are IPv4-only, so the hostname does',
    'not resolve and you get "ENOTFOUND" — which blames DNS rather than the',
    'setting.',
    '',
    'Use the SESSION POOLER instead:',
    '  Supabase dashboard -> green "Connect" button -> Session pooler',
    '',
    'It looks like this — note the different host and the username:',
    '  postgresql://postgres.<ref>:<password>@aws-0-<region>.pooler.supabase.com:5432/postgres',
  )
}

// Prove it actually connects, rather than discovering it three steps later.
const client = new pg.Client({
  connectionString: url,
  ssl: /supabase\.(co|com|net)/.test(url) ? { rejectUnauthorized: false } : undefined,
})

try {
  await client.connect()
  const { rows } = await client.query('SELECT current_database() AS db')
  console.log(`Connected to ${rows[0].db} at ${parsed.hostname}`)
} catch (err) {
  const hint =
    err.code === 'ENOTFOUND'
      ? ['', 'The hostname did not resolve. Check it against the Connect panel.']
      : err.message.includes('password')
        ? ['', 'Check the password — the Connect panel shows a placeholder, not the real one.', 'Reset it under Project Settings -> Database if you do not have it.']
        : []
  fail(`Could not connect: ${err.message}`, ...hint)
} finally {
  await client.end().catch(() => {})
}
