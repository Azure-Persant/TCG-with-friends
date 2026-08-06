import { type NextRequest, NextResponse } from 'next/server'
import { createClient } from '@/lib/supabase/server'

/**
 * Where Google (or any OAuth provider) sends the user back.
 *
 * Exchanges the one-time authorisation code for a session cookie. Unlike a
 * magic link this cannot be spent by a mail scanner, because it never travels
 * through email -- the code is handed straight from the provider to the
 * browser that started the sign-in, and is bound to a verifier only that
 * browser holds.
 */
export async function GET(request: NextRequest) {
  const { searchParams, origin } = new URL(request.url)
  const code = searchParams.get('code')
  const next = searchParams.get('next') ?? '/collection'

  // Never redirect to an absolute URL from a query parameter -- that is an
  // open redirect. Same-origin paths only.
  const safeNext = next.startsWith('/') && !next.startsWith('//') ? next : '/collection'

  if (!code) {
    return NextResponse.redirect(`${origin}/login?error=oauth`)
  }

  const supabase = await createClient()
  const { error } = await supabase.auth.exchangeCodeForSession(code)

  if (error) {
    return NextResponse.redirect(`${origin}/login?error=oauth`)
  }

  // Behind Vercel's proxy `origin` is the internal host, not the one the user
  // typed. Redirecting to it drops them on a URL that is not theirs and,
  // worse, one the session cookie is not scoped to. x-forwarded-host is the
  // public hostname.
  const forwardedHost = request.headers.get('x-forwarded-host')
  const isLocal = process.env.NODE_ENV === 'development'

  if (!isLocal && forwardedHost) {
    return NextResponse.redirect(`https://${forwardedHost}${safeNext}`)
  }

  return NextResponse.redirect(`${origin}${safeNext}`)
}
