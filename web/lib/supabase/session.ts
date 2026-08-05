import { createServerClient } from '@supabase/ssr'
import { NextResponse, type NextRequest } from 'next/server'

/** Paths reachable without being signed in. */
const PUBLIC_PATHS = ['/login', '/auth']

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
  let response = NextResponse.next({ request })

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
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
    },
  )

  // Do not remove: this call is what refreshes an expired token. Without it
  // users are silently signed out whenever the access token lapses.
  const {
    data: { user },
  } = await supabase.auth.getUser()

  const { pathname } = request.nextUrl
  const isPublic = PUBLIC_PATHS.some((p) => pathname.startsWith(p))

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
