import { type EmailOtpType } from '@supabase/supabase-js'
import { type NextRequest, NextResponse } from 'next/server'
import { createClient } from '@/lib/supabase/server'

/**
 * Where a link-style email lands.
 *
 * Sign-in is code-based now (30), so nothing routine arrives here -- the email
 * templates send a code, not a URL. This stays for the cases that are still
 * links by nature: an email-change confirmation, or a template someone edits
 * back to {{ .ConfirmationURL }} later.
 *
 * Worth knowing if you ever do re-enable links: a corporate mail scanner that
 * pre-fetches URLs will hit this route before the human does and spend the
 * token, and the human then sees "link did not work".
 */
export async function GET(request: NextRequest) {
  const { searchParams } = new URL(request.url)
  const token_hash = searchParams.get('token_hash')
  const type = searchParams.get('type') as EmailOtpType | null
  const next = searchParams.get('next') ?? '/collection'

  // Never redirect to an absolute URL from a query parameter -- that is an
  // open redirect. Only same-origin paths are allowed through.
  const safeNext = next.startsWith('/') && !next.startsWith('//') ? next : '/collection'

  if (token_hash && type) {
    const supabase = await createClient()
    const { error } = await supabase.auth.verifyOtp({ type, token_hash })
    if (!error) {
      return NextResponse.redirect(new URL(safeNext, request.url))
    }
  }

  return NextResponse.redirect(new URL('/login?error=link', request.url))
}
