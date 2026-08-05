import { createServerClient } from '@supabase/ssr'
import { cookies } from 'next/headers'
import { supabaseEnv } from './env'

/**
 * Supabase client for Server Components, Server Actions and Route Handlers.
 *
 * Always create it per-request. Caching one across requests would leak one
 * user's session into another's, which in this app means leaking their
 * collection.
 */
export async function createClient() {
  const cookieStore = await cookies()
  const { url, anonKey } = supabaseEnv()

  return createServerClient(url, anonKey, {
    cookies: {
      getAll() {
        return cookieStore.getAll()
      },
      setAll(cookiesToSet) {
        try {
          cookiesToSet.forEach(({ name, value, options }) =>
            cookieStore.set(name, value, options),
          )
        } catch {
          // Called from a Server Component, where cookies are read-only.
          // Harmless: proxy.ts refreshes the session on every request, so the
          // write this drops has already happened there.
        }
      },
    },
  })
}
