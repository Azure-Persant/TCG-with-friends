import { type EmailOtpType } from '@supabase/supabase-js'
import { type NextRequest, NextResponse } from 'next/server'
import { createClient } from '@/lib/supabase/server'

/**
 * Where the magic link lands. Exchanges the one-time token for a session
 * cookie, then forwards to wherever the user was originally headed.
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
