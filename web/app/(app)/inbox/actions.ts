'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'

export type ActionResult = { ok: true } | { ok: false; error: string }

/**
 * Accept a pending request.
 *
 * Note how little this does. Authorisation, the friendship/loan/trade it
 * creates, and every inventory move all happen inside app_accept_request (23).
 * If this file did any of that, the same rules would need enforcing again for
 * every other client -- and on Supabase the anon key reaches PostgREST
 * directly, so "every other client" includes anyone with the key.
 */
export async function acceptRequest(formData: FormData): Promise<ActionResult> {
  const requestId = String(formData.get('requestId') ?? '')
  const originLocationId = String(formData.get('originLocationId') ?? '')
  if (!requestId) return { ok: false, error: 'Missing request' }

  const supabase = await createClient()

  // A borrow request carries no origin -- the borrower does not know which box
  // the card is in, and (14) says they must not. The owner supplies it here.
  let data: unknown = null
  if (originLocationId) {
    const { data: items, error } = await supabase
      .from('request_loan_item')
      .select('edition_id, finish')
      .eq('request_id', requestId)

    if (error) return { ok: false, error: error.message }

    data = {
      origins: (items ?? []).map((i) => ({
        edition_id: i.edition_id,
        finish: i.finish,
        origin_location_id: originLocationId,
      })),
    }
  }

  const { error } = await supabase.rpc('app_accept_request', {
    p_request: requestId,
    p_data: data,
  })

  if (error) return { ok: false, error: error.message }

  revalidatePath('/inbox')
  revalidatePath('/collection')
  return { ok: true }
}

export async function declineRequest(formData: FormData): Promise<ActionResult> {
  const requestId = String(formData.get('requestId') ?? '')
  if (!requestId) return { ok: false, error: 'Missing request' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('app_decline_request', { p_request: requestId })

  if (error) return { ok: false, error: error.message }

  revalidatePath('/inbox')
  return { ok: true }
}
