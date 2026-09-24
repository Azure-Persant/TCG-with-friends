'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'

export type Result = { ok: true } | { ok: false; error: string }

/**
 * Correct or remove a holding directly (29) -- absolute quantity, not a
 * delta. qty 0 deletes the row; the UI offers this as the same "Save"
 * action rather than a separate "Remove" RPC, matching app_set_holding.
 */
export async function setHoldingQty(formData: FormData): Promise<Result> {
  const editionId = String(formData.get('editionId') ?? '')
  const finish = String(formData.get('finish') ?? '')
  const locationId = String(formData.get('locationId') ?? '')
  const condition = String(formData.get('condition') ?? '')
  const qty = Number(formData.get('qty') ?? '')

  if (!editionId || !finish || !locationId || !condition || !Number.isFinite(qty)) {
    return { ok: false, error: 'Missing field' }
  }

  const supabase = await createClient()
  const { error } = await supabase.rpc('app_set_holding', {
    p_edition: editionId,
    p_finish: finish,
    p_location: locationId,
    p_condition: condition,
    p_qty: qty,
  })

  if (error) return { ok: false, error: error.message }

  revalidatePath('/collection')
  return { ok: true }
}

/** Recategorise a holding's condition in place (29), same box, same qty. */
export async function setHoldingCondition(formData: FormData): Promise<Result> {
  const editionId = String(formData.get('editionId') ?? '')
  const finish = String(formData.get('finish') ?? '')
  const locationId = String(formData.get('locationId') ?? '')
  const fromCondition = String(formData.get('fromCondition') ?? '')
  const toCondition = String(formData.get('toCondition') ?? '')
  const qty = Number(formData.get('qty') ?? '')

  if (!editionId || !finish || !locationId || !fromCondition || !toCondition || !Number.isFinite(qty)) {
    return { ok: false, error: 'Missing field' }
  }

  const supabase = await createClient()
  const { error } = await supabase.rpc('app_set_condition', {
    p_edition: editionId,
    p_finish: finish,
    p_location: locationId,
    p_from_condition: fromCondition,
    p_to_condition: toCondition,
    p_qty: qty,
  })

  if (error) return { ok: false, error: error.message }

  revalidatePath('/collection')
  return { ok: true }
}

/** Recategorise a holding's finish in place (29 follow-up), same box, same qty. */
export async function setHoldingFinish(formData: FormData): Promise<Result> {
  const editionId = String(formData.get('editionId') ?? '')
  const locationId = String(formData.get('locationId') ?? '')
  const condition = String(formData.get('condition') ?? '')
  const fromFinish = String(formData.get('fromFinish') ?? '')
  const toFinish = String(formData.get('toFinish') ?? '')
  const qty = Number(formData.get('qty') ?? '')

  if (!editionId || !locationId || !condition || !fromFinish || !toFinish || !Number.isFinite(qty)) {
    return { ok: false, error: 'Missing field' }
  }

  const supabase = await createClient()
  const { error } = await supabase.rpc('app_set_finish', {
    p_edition: editionId,
    p_location: locationId,
    p_condition: condition,
    p_from_finish: fromFinish,
    p_to_finish: toFinish,
    p_qty: qty,
  })

  if (error) return { ok: false, error: error.message }

  revalidatePath('/collection')
  return { ok: true }
}

/** Move a holding to a different box (29 follow-up), same finish/condition/qty. */
export async function moveHolding(formData: FormData): Promise<Result> {
  const editionId = String(formData.get('editionId') ?? '')
  const finish = String(formData.get('finish') ?? '')
  const condition = String(formData.get('condition') ?? '')
  const fromLocationId = String(formData.get('fromLocationId') ?? '')
  const toLocationId = String(formData.get('toLocationId') ?? '')
  const qty = Number(formData.get('qty') ?? '')

  if (!editionId || !finish || !condition || !fromLocationId || !toLocationId || !Number.isFinite(qty)) {
    return { ok: false, error: 'Missing field' }
  }

  const supabase = await createClient()
  const { error } = await supabase.rpc('app_move_cards', {
    p_edition: editionId,
    p_finish: finish,
    p_from: fromLocationId,
    p_to: toLocationId,
    p_condition: condition,
    p_qty: qty,
  })

  if (error) return { ok: false, error: error.message }

  revalidatePath('/collection')
  return { ok: true }
}
