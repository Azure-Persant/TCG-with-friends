'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'

export type Result = { ok: true } | { ok: false; error: string }

export async function createShare(formData: FormData): Promise<Result> {
  const label = String(formData.get('label') ?? '').trim() || null
  const expiryHours = String(formData.get('expiryHours') ?? '')

  const expiresAt =
    expiryHours && expiryHours !== 'never'
      ? new Date(Date.now() + Number(expiryHours) * 3600_000).toISOString()
      : null

  const supabase = await createClient()
  const { error } = await supabase.rpc('app_create_collection_share', {
    p_label: label,
    p_expires_at: expiresAt,
  })

  if (error) return { ok: false, error: error.message }

  revalidatePath('/collection/share')
  return { ok: true }
}

export async function revokeShare(formData: FormData): Promise<Result> {
  const id = String(formData.get('id') ?? '')
  if (!id) return { ok: false, error: 'Missing share' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('app_revoke_collection_share', { p_id: id })

  if (error) return { ok: false, error: error.message }

  revalidatePath('/collection/share')
  return { ok: true }
}

export async function deleteShare(formData: FormData): Promise<Result> {
  const id = String(formData.get('id') ?? '')
  if (!id) return { ok: false, error: 'Missing share' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('app_delete_collection_share', { p_id: id })

  if (error) return { ok: false, error: error.message }

  revalidatePath('/collection/share')
  return { ok: true }
}
