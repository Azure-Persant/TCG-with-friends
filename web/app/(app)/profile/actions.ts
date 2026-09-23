'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'

export type Result = { ok: true } | { ok: false; error: string }

/**
 * Change your display name (40). Same shape as /welcome's setUsername --
 * the database owns the rules and its messages are written to be read by a
 * person, so they pass straight through.
 */
export async function setDisplayName(formData: FormData): Promise<Result> {
  const displayName = String(formData.get('displayName') ?? '').trim()
  if (!displayName) return { ok: false, error: 'A display name cannot be empty' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('app_set_display_name', { p_display_name: displayName })

  if (error) return { ok: false, error: error.message }

  revalidatePath('/', 'layout')
  return { ok: true }
}

/**
 * Change your username. /welcome's setUsername only ever runs once, at
 * onboarding -- this is the same RPC, reachable again afterward (40).
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
