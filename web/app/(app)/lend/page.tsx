import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { LendForm } from './lend-form'

export const dynamic = 'force-dynamic'

type HoldingRow = {
  qty: number
  condition: string
  finish: string
  edition_id: string
  location_id: string
  location: { id: string; name: string | null; kind: string } | null
  card_edition: { collector_number: string | null; card: { name: string } | null } | null
}

/**
 * Lend cards to a friend.
 *
 * Only cards in PHYSICAL locations can be offered. Anything already sitting in
 * a holder location is out on loan (10) -- you cannot lend what you are not
 * holding, and the sub-loan flow (18) is how it moves on from there.
 */
export default async function LendPage() {
  const supabase = await createClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()

  const { data: friendships } = await supabase
    .from('friendship')
    .select('account_lo_id, account_hi_id')

  const friendIds = (friendships ?? []).map((f) =>
    f.account_lo_id === user!.id ? f.account_hi_id : f.account_lo_id,
  )

  if (friendIds.length === 0) {
    return (
      <div className="rounded-lg border border-dashed border-neutral-300 p-8 text-center dark:border-neutral-700">
        <p className="font-medium">No friends to lend to yet</p>
        <p className="mt-1 text-sm text-neutral-500">
          Lending is only possible between accepted friends (2).
        </p>
        <Link
          href="/friends"
          className="mt-4 inline-block rounded-md bg-neutral-900 px-3 py-2 text-sm font-medium text-white dark:bg-neutral-100 dark:text-neutral-900"
        >
          Add a friend
        </Link>
      </div>
    )
  }

  const [{ data: friends }, { data: holdings }] = await Promise.all([
    supabase.from('account').select('id, display_name').in('id', friendIds),
    supabase
      .from('holding')
      .select(
        `qty, condition, finish, edition_id, location_id,
         location!inner ( id, name, kind ),
         card_edition ( collector_number, card ( name ) )`,
      )
      .eq('location.kind', 'physical'),
  ])

  const rows = (holdings ?? []) as unknown as HoldingRow[]

  if (rows.length === 0) {
    return (
      <div className="rounded-lg border border-dashed border-neutral-300 p-8 text-center dark:border-neutral-700">
        <p className="font-medium">Nothing to lend</p>
        <p className="mt-1 text-sm text-neutral-500">
          Cards already out on loan are not listed here — you cannot lend what you are not
          holding.
        </p>
        <Link
          href="/add"
          className="mt-4 inline-block rounded-md bg-neutral-900 px-3 py-2 text-sm font-medium text-white dark:bg-neutral-100 dark:text-neutral-900"
        >
          Add cards
        </Link>
      </div>
    )
  }

  return (
    <LendForm
      friends={friends ?? []}
      holdings={rows.map((h) => ({
        editionId: h.edition_id,
        locationId: h.location_id,
        locationName: h.location?.name ?? 'Unnamed',
        cardName: h.card_edition?.card?.name ?? 'Unknown card',
        collectorNumber: h.card_edition?.collector_number ?? null,
        finish: h.finish,
        condition: h.condition,
        available: h.qty,
      }))}
    />
  )
}
