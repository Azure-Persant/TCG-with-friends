// Next 16 renamed the `middleware` file convention to `proxy`. Most Supabase
// documentation still says middleware.ts -- this file is that file.
import { type NextRequest } from 'next/server'
import { updateSession } from '@/lib/supabase/session'

export async function proxy(request: NextRequest) {
  return await updateSession(request)
}

export const config = {
  matcher: [
    // Everything except static assets and images.
    '/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)',
  ],
}
