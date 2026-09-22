'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'

export type Found = {
  id: string
  username: string | null
  display_name: string
  is_self: boolean
  is_friend: boolean
  request_state: 'sent' | 'received' | null
}

export type Result<T = undefined> = { ok: true; data?: T } | { ok: false; error: string }

/**
 * Look someone up by username or by exact email (32).
 *
 * Both are exact, never partial — see app_find_account. RLS hides strangers,
 * so this RPC is the only way to reach someone you are not connected to, and
 * requiring the whole handle or address is what stops it becoming a directory
 * of everyone using the app.
 */
export async function findAccount(formData: FormData): Promise<Result<Found | null>> {
  const query = String(formData.get('query') ?? '').trim()
  if (!query) return { ok: false, error: 'Enter a username or email address' }

  const supabase = await createClient()
  const { data, error } = await supabase.rpc('app_find_account', { p_query: query })

  if (error) return { ok: false, error: error.message }
  return { ok: true, data: (data?.[0] as Found) ?? null }
}

export async function sendFriendRequest(formData: FormData): Promise<Result> {
  const to = String(formData.get('to') ?? '')
  const note = String(formData.get('note') ?? '').trim() || null
  if (!to) return { ok: false, error: 'Missing recipient' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('app_send_friend_request', { p_to: to, p_note: note })

  if (error) {
    return {
      ok: false,
      // The partial unique index on pending requests is doing its job here.
      error: error.code === '23505' ? 'You have already asked them.' : error.message,
    }
  }

  revalidatePath('/friends')
  revalidatePath('/inbox')
  return { ok: true }
}

/**
 * Unfriending refuses while cards are outstanding in either direction (5).
 * That refusal is the feature, so pass its message straight through — it names
 * how many cards and what to do about them.
 */
export async function unfriend(formData: FormData): Promise<Result> {
  const other = String(formData.get('other') ?? '')
  if (!other) return { ok: false, error: 'Missing friend' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('app_unfriend', { p_other: other })

  if (error) return { ok: false, error: error.message }

  revalidatePath('/friends')
  revalidatePath('/collection')
  return { ok: true }
}

export async function cancelRequest(formData: FormData): Promise<Result> {
  const requestId = String(formData.get('requestId') ?? '')
  const supabase = await createClient()
  const { error } = await supabase.rpc('app_cancel_request', { p_request: requestId })
  if (error) return { ok: false, error: error.message }
  revalidatePath('/friends')
  return { ok: true }
}

/**
 * Share a game, or stop sharing it (4).
 *
 * Sharing is per game and global across friends — there is no per-friend
 * sharing, deliberately. Without a share row a friend sees nothing of yours,
 * which is the single most confusing thing about this app if you have not been
 * told: you can be friends and still both see empty collections.
 */
export async function setGameShare(formData: FormData): Promise<Result> {
  const gameId = String(formData.get('gameId') ?? '')
  const share = String(formData.get('share') ?? '') === 'true'

  const supabase = await createClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) return { ok: false, error: 'Not signed in' }

  const { error } = share
    ? await supabase.from('game_share').upsert({ account_id: user.id, game_id: gameId })
    : await supabase.from('game_share').delete().eq('account_id', user.id).eq('game_id', gameId)

  if (error) return { ok: false, error: error.message }

  revalidatePath('/friends')
  return { ok: true }
}
