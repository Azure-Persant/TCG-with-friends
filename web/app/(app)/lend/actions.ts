'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'

export type Result = { ok: true; message: string } | { ok: false; error: string }

export type LineSpec = {
  edition_id: string
  finish: string
  condition: string
  origin_location_id: string
  qty: number
}

/**
 * Offer to lend (2).
 *
 * Creates a REQUEST, not a loan. Nothing leaves your boxes until the other
 * person accepts — and because an unaccepted loan has no row in `loan` at all
 * (23), there is nothing here that could move inventory early even by mistake.
 */
export async function offerLoan(formData: FormData): Promise<Result> {
  const to = String(formData.get('to') ?? '')
  const note = String(formData.get('note') ?? '').trim() || null
  const linesRaw = String(formData.get('lines') ?? '[]')

  if (!to) return { ok: false, error: 'Choose who you are lending to' }

  let lines: LineSpec[]
  try {
    lines = JSON.parse(linesRaw)
  } catch {
    return { ok: false, error: 'Could not read the card list' }
  }

  if (lines.length === 0) return { ok: false, error: 'Pick at least one card' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('app_offer_loan', {
    p_lines: lines,
    p_to: to,
    p_note: note,
  })

  if (error) return { ok: false, error: error.message }

  revalidatePath('/lend')
  revalidatePath('/collection')

  const total = lines.reduce((n, l) => n + l.qty, 0)
  return {
    ok: true,
    message: `Offered ${total} card${total === 1 ? '' : 's'}. Nothing moves until they accept.`,
  }
}
