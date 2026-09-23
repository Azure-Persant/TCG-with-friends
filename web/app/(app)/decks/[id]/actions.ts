'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'

export type Result = { ok: true } | { ok: false; error: string }

/**
 * Set the exact quantity of one printing in one section of a deck.
 *
 * Goes through app_set_deck_card, which owns every legality rule (copy
 * limits, section caps, the Standard-legality check) -- see db/functions.sql.
 * qty = 0 removes the row and always succeeds; nothing else is guaranteed to.
 */
export async function setDeckCard(formData: FormData): Promise<Result> {
  const deckId = String(formData.get('deckId') ?? '')
  const editionId = String(formData.get('editionId') ?? '')
  const section = String(formData.get('section') ?? '')
  const finish = String(formData.get('finish') ?? 'NONFOIL')
  const qty = Number(formData.get('qty') ?? 0)

  if (!deckId || !editionId || !section) return { ok: false, error: 'Missing card' }
  if (!Number.isInteger(qty) || qty < 0) return { ok: false, error: 'Quantity must be 0 or more' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('app_set_deck_card', {
    p_deck: deckId,
    p_edition: editionId,
    p_section: section,
    p_finish: finish,
    p_qty: qty,
  })

  if (error) return { ok: false, error: error.message }

  revalidatePath(`/decks/${deckId}`)
  return { ok: true }
}

export async function renameDeck(formData: FormData): Promise<Result> {
  const deckId = String(formData.get('deckId') ?? '')
  const name = String(formData.get('name') ?? '').trim()
  if (!deckId || !name) return { ok: false, error: 'Give it a name' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('app_rename_deck', { p_deck: deckId, p_name: name })
  if (error) return { ok: false, error: error.message }

  revalidatePath(`/decks/${deckId}`)
  revalidatePath('/decks')
  return { ok: true }
}
