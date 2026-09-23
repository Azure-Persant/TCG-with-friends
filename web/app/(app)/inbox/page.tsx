import { createClient } from '@/lib/supabase/server'
import { RequestCard, type BorrowItem } from './request-card'

export const dynamic = 'force-dynamic'

const KIND_LABEL: Record<string, string> = {
  friend: 'wants to be friends',
  loan_offer: 'is offering to lend you cards',
  borrow_request: 'would like to borrow',
  trade_offer: 'proposes a trade',
  sub_loan: 'wants to pass a card on',
}

type BorrowItemRow = {
  id: string
  request_id: string
  edition_id: string
  finish: string
  qty: number
  card_edition: { card: { name: string } | null } | null
}

export default async function InboxPage() {
  const supabase = await createClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()

  const { data: requests, error } = await supabase
    .from('request')
    .select(
      `id, kind, note, created_at,
       proposer:account!request_proposer_account_id_fkey ( display_name )`,
    )
    .eq('status', 'pending')
    .eq('recipient_account_id', user!.id)
    .order('created_at', { ascending: false })

  if (error) {
    return (
      <div className="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-200">
        <p className="font-medium">Could not load your inbox</p>
        <p className="mt-1">{error.message}</p>
      </div>
    )
  }

  if (!requests || requests.length === 0) {
    return (
      <div className="rounded-lg border border-dashed border-white/20 p-8 text-center">
        <p className="font-medium">Nothing waiting on you</p>
        <p className="mt-1 text-sm text-slate-400">
          Friend requests, loans, borrows and trades all land here.
        </p>
      </div>
    )
  }

  const borrowRequestIds = requests.filter((r) => r.kind === 'borrow_request').map((r) => r.id)

  // Only fetched when there is a borrow request to show -- the owner picks a
  // box per card (12), not one box for the whole request, so this needs both
  // the full box list and, per card, a sensible default box to preselect.
  let locations: { id: string; name: string | null }[] = []
  let itemsByRequest = new Map<string, BorrowItem[]>()

  if (borrowRequestIds.length > 0) {
    const [{ data: locs }, { data: items }, { data: holdings }] = await Promise.all([
      supabase.from('location').select('id, name').eq('kind', 'physical').order('name'),
      supabase
        .from('request_loan_item')
        .select('id, request_id, edition_id, finish, qty, card_edition ( card ( name ) )')
        .in('request_id', borrowRequestIds)
        .returns<BorrowItemRow[]>(),
      // Where this same card already lives, so the box selector can default
      // to a box that actually has it rather than just the first box
      // alphabetically -- "sensibly," per the issue.
      supabase
        .from('holding')
        .select('edition_id, finish, qty, location_id, location:location_id!inner(kind)')
        .eq('location.kind', 'physical')
        .order('qty', { ascending: false }),
    ])

    locations = locs ?? []

    const defaultLocationFor = new Map<string, string>()
    for (const h of holdings ?? []) {
      const key = `${h.edition_id}:${h.finish}`
      if (!defaultLocationFor.has(key)) defaultLocationFor.set(key, h.location_id)
    }

    itemsByRequest = new Map()
    for (const it of items ?? []) {
      const key = `${it.edition_id}:${it.finish}`
      const list = itemsByRequest.get(it.request_id) ?? []
      list.push({
        id: it.id,
        cardName: it.card_edition?.card?.name ?? 'Unknown card',
        finish: it.finish,
        qty: it.qty,
        defaultLocationId: defaultLocationFor.get(key) ?? locations[0]?.id ?? '',
      })
      itemsByRequest.set(it.request_id, list)
    }
  }

  return (
    <ul className="flex flex-col gap-3">
      {requests.map((r) => {
        const proposer = Array.isArray(r.proposer) ? r.proposer[0] : r.proposer
        return (
          <RequestCard
            key={r.id}
            id={r.id}
            who={proposer?.display_name ?? 'Someone'}
            what={KIND_LABEL[r.kind] ?? 'sent you a request'}
            note={r.note}
            items={r.kind === 'borrow_request' ? (itemsByRequest.get(r.id) ?? []) : null}
            locations={locations}
          />
        )
      })}
    </ul>
  )
}
