'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'

export type Result = { ok: true; message: string } | { ok: false; error: string }

/**
 * Add copies to one of your boxes.
 *
 * Goes through app_add_cards rather than inserting into `holding` directly.
 * That function owns the bucket rule (8) -- notably that an emptied bucket is
 * deleted rather than stored as zero -- and the tables reject direct writes so
 * that rule cannot be sidestepped by any client, including this one.
 */
export async function addCards(formData: FormData): Promise<Result> {
  const editionId = String(formData.get('editionId') ?? '')
  const finish = String(formData.get('finish') ?? 'NONFOIL')
  const condition = String(formData.get('condition') ?? 'NM')
  const locationId = String(formData.get('locationId') ?? '')
  const qty = Number(formData.get('qty') ?? 1)
  const cardName = String(formData.get('cardName') ?? 'card')

  if (!editionId) return { ok: false, error: 'Missing card' }
  if (!locationId) return { ok: false, error: 'Choose a box to put it in' }
  if (!Number.isInteger(qty) || qty < 1) return { ok: false, error: 'Quantity must be at least 1' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('app_add_cards', {
    p_edition: editionId,
    p_finish: finish,
    p_location: locationId,
    p_condition: condition,
    p_qty: qty,
  })

  if (error) return { ok: false, error: error.message }

  revalidatePath('/collection')
  return {
    ok: true,
    message: `Added ${qty} × ${cardName}${finish === 'FOIL' ? ' (foil)' : ''} in ${condition}`,
  }
}
