'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'

export type Result = { ok: true; id?: string } | { ok: false; error: string }

export async function createDeck(formData: FormData): Promise<Result> {
  const name = String(formData.get('name') ?? '').trim()
  if (!name) return { ok: false, error: 'Give it a name' }

  const supabase = await createClient()
  const { data, error } = await supabase.rpc('app_create_deck', { p_name: name })
  if (error) return { ok: false, error: error.message }

  revalidatePath('/decks')
  return { ok: true, id: data as string }
}

export async function deleteDeck(formData: FormData): Promise<Result> {
  const deckId = String(formData.get('deckId') ?? '')
  if (!deckId) return { ok: false, error: 'Missing deck' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('app_delete_deck', { p_deck: deckId })
  if (error) return { ok: false, error: error.message }

  revalidatePath('/decks')
  return { ok: true }
}
