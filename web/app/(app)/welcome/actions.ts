'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'

export type Result = { ok: true } | { ok: false; error: string }

/**
 * Claim a username (32).
 *
 * The database owns the rules -- shape, case-insensitive uniqueness -- and its
 * messages are written to be read by a person, so they pass straight through.
 */
export async function setUsername(formData: FormData): Promise<Result> {
  const username = String(formData.get('username') ?? '').trim()
  if (!username) return { ok: false, error: 'Pick a username' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('app_set_username', { p_username: username })

  if (error) return { ok: false, error: error.message }

  revalidatePath('/', 'layout')
  return { ok: true }
}
