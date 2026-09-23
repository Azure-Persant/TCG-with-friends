import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { isRestricted } from '@/lib/legality'
import { CollectionGrid, type Group } from './collection-grid'

export const dynamic = 'force-dynamic'

type HoldingRow = {
  qty: number
  condition: string
  finish: string
  location: { id: string; name: string | null; kind: string; holder_account_id: string | null } | null
  card_edition: {
    collector_number: string | null
    card: { name: string; attributes: Record<string, unknown> } | null
    card_image: { storage_key: string; variant: string }[] | null
  } | null
}

export default async function CollectionPage() {
  const supabase = await createClient()

  // No .eq('account_id', …) anywhere below. RLS already restricts this to the
  // caller's own rows; adding a filter here would imply the security lives in
  // this file, and someone would eventually "clean it up".
  const { data, error } = await supabase
    .from('holding')
    .select(
      `qty, condition, finish,
       location ( id, name, kind, holder_account_id ),
       card_edition ( collector_number, card ( name, attributes ), card_image ( storage_key, variant ) )`,
    )
    .order('qty', { ascending: false })

  if (error) {
    return <ErrorBox message={error.message} />
  }

  const holdings = (data ?? []) as unknown as HoldingRow[]

  if (holdings.length === 0) {
    return (
      <>
        <Header uniqueCards={0} totalCards={0} />
        <Empty
          title="Nothing here yet"
          body="Once you add cards they will show up grouped by where you keep them."
        />
      </>
    )
  }

  // Group by location. Holder locations are where lent-out cards live (10), so
  // they are listed separately -- those are yours but not in your hands.
  const groups = new Map<string, Group>()
  const uniqueCardNames = new Set<string>()
  let totalCards = 0

  for (const h of holdings) {
    const loc = h.location
    const key = loc?.id ?? 'unknown'
    if (!groups.has(key)) {
      groups.set(key, {
        name: loc?.name ?? (loc?.holder_account_id ? 'Lent out' : 'Unfiled'),
        isHolder: loc?.kind === 'holder',
        rows: [],
      })
    }
    const cardName = h.card_edition?.card?.name ?? 'Unknown card'
    groups.get(key)!.rows.push({
      qty: h.qty,
      condition: h.condition,
      finish: h.finish,
      cardName,
      storageKey: h.card_edition?.card_image?.find((im) => im.variant === 'original')?.storage_key ?? null,
      restricted: isRestricted(h.card_edition?.card?.attributes),
    })
    uniqueCardNames.add(cardName)
    totalCards += h.qty
  }

  const sorted = [...groups.values()].sort(
    (a, b) => Number(a.isHolder) - Number(b.isHolder) || a.name.localeCompare(b.name),
  )

  return (
    <div className="flex flex-col gap-8">
      <Header uniqueCards={uniqueCardNames.size} totalCards={totalCards} />
      <CollectionGrid groups={sorted} />
    </div>
  )
}

function Header({ uniqueCards, totalCards }: { uniqueCards: number; totalCards: number }) {
  return (
    <div className="flex flex-wrap items-start justify-between gap-4">
      <div>
        <h1 className="font-heading text-4xl font-bold text-white">My Collection</h1>
        <div className="mt-3 flex items-center gap-2 text-slate-300">
          <PackageIcon className="h-5 w-5 text-cyan-400" />
          <span>
            <span className="font-semibold text-white">{uniqueCards}</span> unique cards
          </span>
          <span className="text-slate-500">·</span>
          <span>
            <span className="font-semibold text-white">{totalCards}</span> total cards
          </span>
        </div>
      </div>
      <Link
        href="/add"
        className="flex items-center gap-2 rounded-md bg-accent px-4 py-2 text-sm font-medium text-white transition hover:opacity-90"
      >
        <PlusIcon className="h-4 w-4" />
        Add Cards
      </Link>
    </div>
  )
}

function PackageIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden>
      <path d="m7.5 4.27 9 5.15" />
      <path d="M21 8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16Z" />
      <path d="m3.3 7 8.7 5 8.7-5" />
      <path d="M12 22V12" />
    </svg>
  )
}

function PlusIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden>
      <line x1="12" y1="5" x2="12" y2="19" />
      <line x1="5" y1="12" x2="19" y2="12" />
    </svg>
  )
}

function Empty({ title, body }: { title: string; body: string }) {
  return (
    <div className="rounded-lg border border-dashed border-white/20 p-8 text-center">
      <p className="font-medium">{title}</p>
      <p className="mt-1 text-sm text-slate-400">{body}</p>
    </div>
  )
}

function ErrorBox({ message }: { message: string }) {
  return (
    <div className="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-200">
      <p className="font-medium">Could not load your collection</p>
      <p className="mt-1">{message}</p>
    </div>
  )
}
