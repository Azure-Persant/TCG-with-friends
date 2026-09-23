import { createServerClient } from '@supabase/ssr'
import { NextResponse, type NextRequest } from 'next/server'
import { supabaseEnv } from './env'

/** Paths reachable without being signed in. */
const PUBLIC_PATHS = ['/login', '/auth', '/cards']

/**
 * Exact-match public paths -- "/" cannot go in PUBLIC_PATHS above, since that
 * list is matched with startsWith and every path starts with "/". "/" is now
 * the "Select Your Game" landing page, reachable signed out (a visitor should
 * be able to pick their game before being asked to sign in, not after).
 */
const PUBLIC_EXACT_PATHS = ['/']

/**
 * Refresh the session cookie and bounce anonymous users to /login.
 *
 * Called from proxy.ts (what Next.js called middleware before 16).
 *
 * This is NOT the security boundary -- RLS in the database is. Someone who
 * defeats this sees pages that fetch nothing, because every query is filtered
 * by auth.uid() server-side. This exists so signed-out users get a login
 * screen instead of a page of empty tables.
 */
export async function updateSession(request: NextRequest) {
  // Server Components cannot see the current path. The username gate in the
  // app layout needs it to avoid redirecting /welcome to itself, so it is
  // forwarded as a header.
  request.headers.set('x-pathname', request.nextUrl.pathname)

  let response = NextResponse.next({ request })

  const { url: supabaseUrl, anonKey } = supabaseEnv()

  const supabase = createServerClient(supabaseUrl, anonKey, {
    cookies: {
      getAll() {
        return request.cookies.getAll()
      },
      setAll(cookiesToSet) {
        cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value))
        response = NextResponse.next({ request })
        cookiesToSet.forEach(({ name, value, options }) =>
          response.cookies.set(name, value, options),
        )
      },
    },
  })

  // Do not remove: this call is what refreshes an expired token. Without it
  // users are silently signed out whenever the access token lapses.
  const {
    data: { user },
  } = await supabase.auth.getUser()

  const { pathname } = request.nextUrl
  const isPublic =
    PUBLIC_PATHS.some((p) => pathname.startsWith(p)) || PUBLIC_EXACT_PATHS.includes(pathname)

  if (!user && !isPublic) {
    const url = request.nextUrl.clone()
    url.pathname = '/login'
    // Come back here once they are signed in.
    url.searchParams.set('next', pathname)
    return NextResponse.redirect(url)
  }

  if (user && pathname === '/login') {
    const url = request.nextUrl.clone()
    url.pathname = '/collection'
    url.search = ''
    return NextResponse.redirect(url)
  }

  return response
}
