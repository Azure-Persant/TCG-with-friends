/**
 * Read and sanity-check the Supabase connection settings.
 *
 * These are pasted by hand into a Vercel settings box, which makes them the
 * likeliest thing in the whole app to be subtly wrong -- and the failures are
 * unhelpful. A trailing slash produces `https://ref.supabase.co//auth/v1/otp`,
 * and Supabase's gateway answers "Invalid path specified in request URL",
 * which names neither the setting nor the slash.
 *
 * So normalise what can be normalised, and refuse clearly on what cannot.
 */

function readUrl(): string {
  const raw = process.env.NEXT_PUBLIC_SUPABASE_URL?.trim()

  if (!raw) {
    throw new Error(
      'NEXT_PUBLIC_SUPABASE_URL is not set. Add it in Vercel under ' +
        'Settings -> Environment Variables, then redeploy — env changes do not ' +
        'apply to an existing deployment.',
    )
  }

  let parsed: URL
  try {
    parsed = new URL(raw)
  } catch {
    throw new Error(
      `NEXT_PUBLIC_SUPABASE_URL is not a valid URL: "${raw}". ` +
        'It should look like https://abcdefgh.supabase.co',
    )
  }

  if (parsed.protocol !== 'https:' && parsed.hostname !== 'localhost') {
    throw new Error(
      `NEXT_PUBLIC_SUPABASE_URL must start with https:// (got "${parsed.protocol}//")`,
    )
  }

  // The common paste error: copying a REST or auth endpoint rather than the
  // project URL. Worth naming, because the resulting gateway error does not.
  const path = parsed.pathname.replace(/\/+$/, '')
  if (path) {
    throw new Error(
      `NEXT_PUBLIC_SUPABASE_URL should have no path, but has "${path}". ` +
        `Use just https://${parsed.host} — the project URL from ` +
        'Supabase -> Project Settings -> Data API.',
    )
  }

  // A trailing slash is harmless to fix and fatal to ignore.
  return `${parsed.protocol}//${parsed.host}`
}

function readKey(): string {
  const raw = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY?.trim()

  if (!raw) {
    throw new Error(
      'NEXT_PUBLIC_SUPABASE_ANON_KEY is not set. Add it in Vercel under ' +
        'Settings -> Environment Variables, then redeploy.',
    )
  }

  // The service_role key bypasses Row Level Security entirely. In a
  // NEXT_PUBLIC_ variable it ships to every browser, handing every visitor
  // full read and write on every table. Refuse outright.
  if (raw.includes('service_role')) {
    throw new Error(
      'NEXT_PUBLIC_SUPABASE_ANON_KEY appears to hold the service_role key. ' +
        'That key bypasses Row Level Security and must never reach a browser. ' +
        'Use the anon / publishable key instead.',
    )
  }

  return raw
}

export function supabaseEnv() {
  return { url: readUrl(), anonKey: readKey() }
}
