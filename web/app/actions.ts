'use server'

import { cookies } from 'next/headers'
import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'

/**
 * Picking a game on the "Select Your Game" landing page.
 *
 * Signed in: persisted server-side via app_set_selected_game, so it follows
 * the account across devices. Signed out: there's no account to persist it
 * on, so it's a cookie instead -- good enough to remember "I came here for
 * Grand Archive" through to /cards, and it's simply overwritten if they later
 * sign in and pick a game for real.
 */
export async function selectGame(formData: FormData): Promise<void> {
  const gameId = String(formData.get('gameId') ?? '')
  const gameSlug = String(formData.get('gameSlug') ?? '')
  if (!gameId || !gameSlug) return

  const supabase = await createClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()

  if (user) {
    await supabase.rpc('app_set_selected_game', { p_game: gameId })
    redirect('/collection')
  }

  const cookieStore = await cookies()
  cookieStore.set('selected_game', gameSlug, {
    maxAge: 60 * 60 * 24 * 365,
    sameSite: 'lax',
    path: '/',
  })
  redirect('/cards')
}
