'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'

export type Result = { ok: true } | { ok: false; error: string }

/**
 * Locations are written directly rather than through an RPC, unlike holdings.
 *
 * That is not an oversight. A location carries no invariant that spans rows --
 * naming a box cannot make an inventory wrong. RLS already restricts writes to
 * your own PHYSICAL locations (9, 14), which is the whole rule. Holder
 * locations are created by the loan functions and are not editable here.
 */
export async function createLocation(formData: FormData): Promise<Result> {
  const name = String(formData.get('name') ?? '').trim()
  if (!name) return { ok: false, error: 'Give it a name' }

  const supabase = await createClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) return { ok: false, error: 'Not signed in' }

  const { error } = await supabase
    .from('location')
    .insert({ account_id: user.id, kind: 'physical', name })

  if (error) {
    return {
      ok: false,
      error: error.code === '23505' ? 'You already have a box with that name' : error.message,
    }
  }

  revalidatePath('/locations')
  revalidatePath('/add')
  return { ok: true }
}

export async function renameLocation(formData: FormData): Promise<Result> {
  const id = String(formData.get('id') ?? '')
  const name = String(formData.get('name') ?? '').trim()
  if (!id || !name) return { ok: false, error: 'Give it a name' }

  const supabase = await createClient()
  const { error } = await supabase.from('location').update({ name }).eq('id', id)

  if (error) return { ok: false, error: error.message }

  revalidatePath('/locations')
  revalidatePath('/collection')
  return { ok: true }
}

/**
 * Deleting a box that still holds cards would lose the record of where they
 * are, so the schema's ON DELETE RESTRICT refuses it. Translate that into
 * something a person can act on.
 */
export async function deleteLocation(formData: FormData): Promise<Result> {
  const id = String(formData.get('id') ?? '')
  if (!id) return { ok: false, error: 'Missing location' }

  const supabase = await createClient()
  const { error } = await supabase.from('location').delete().eq('id', id)

  if (error) {
    return {
      ok: false,
      error:
        error.code === '23503'
          ? 'That box still has cards in it. Move them somewhere else first.'
          : error.message,
    }
  }

  revalidatePath('/locations')
  revalidatePath('/collection')
  return { ok: true }
}
