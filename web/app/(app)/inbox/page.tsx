import { createClient } from '@/lib/supabase/server'
import { RequestCard } from './request-card'

export const dynamic = 'force-dynamic'

const KIND_LABEL: Record<string, string> = {
  friend: 'wants to be friends',
  loan_offer: 'is offering to lend you cards',
  borrow_request: 'would like to borrow',
  trade_offer: 'proposes a trade',
  sub_loan: 'wants to pass a card on',
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

  // Only needed for borrow requests, where the owner picks which box the
  // cards come out of. Fetched once rather than per card.
  const { data: locations } = await supabase
    .from('location')
    .select('id, name')
    .eq('kind', 'physical')
    .order('name')

  if (!requests || requests.length === 0) {
    return (
      <div className="rounded-lg border border-dashed border-neutral-300 p-8 text-center dark:border-neutral-700">
        <p className="font-medium">Nothing waiting on you</p>
        <p className="mt-1 text-sm text-neutral-500">
          Friend requests, loans, borrows and trades all land here.
        </p>
      </div>
    )
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
            needsOrigin={r.kind === 'borrow_request'}
            locations={locations ?? []}
          />
        )
      })}
    </ul>
  )
}
