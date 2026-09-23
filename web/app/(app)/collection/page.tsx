import { createClient } from '@/lib/supabase/server'
import { CardTile } from '@/app/_components/card-tile'

export const dynamic = 'force-dynamic'

type Row = {
  qty: number
  condition: string
  finish: string
  location: { id: string; name: string | null; kind: string; holder_account_id: string | null } | null
  card_edition: {
    collector_number: string | null
    card: { name: string } | null
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
       card_edition ( collector_number, card ( name ), card_image ( storage_key, variant ) )`,
    )
    .order('qty', { ascending: false })

  if (error) {
    return <ErrorBox message={error.message} />
  }

  const rows = (data ?? []) as unknown as Row[]

  if (rows.length === 0) {
    return (
      <Empty
        title="Nothing here yet"
        body="Once you add cards they will show up grouped by where you keep them."
      />
    )
  }

  // Group by location. Holder locations are where lent-out cards live (10), so
  // they are listed separately -- those are yours but not in your hands.
  const groups = new Map<string, { name: string; isHolder: boolean; rows: Row[] }>()
  for (const row of rows) {
    const loc = row.location
    const key = loc?.id ?? 'unknown'
    if (!groups.has(key)) {
      groups.set(key, {
        name: loc?.name ?? (loc?.holder_account_id ? 'Lent out' : 'Unfiled'),
        isHolder: loc?.kind === 'holder',
        rows: [],
      })
    }
    groups.get(key)!.rows.push(row)
  }

  const sorted = [...groups.values()].sort(
    (a, b) => Number(a.isHolder) - Number(b.isHolder) || a.name.localeCompare(b.name),
  )

  return (
    <div className="flex flex-col gap-8">
      {sorted.map((group) => (
        <section key={group.name}>
          <h2 className="flex items-baseline gap-2 text-sm font-semibold">
            {group.name}
            {group.isHolder && (
              <span className="rounded bg-amber-100 px-1.5 py-0.5 text-xs font-normal text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                with someone else
              </span>
            )}
            <span className="ml-auto text-xs font-normal text-slate-400">
              {group.rows.reduce((n, r) => n + r.qty, 0)} cards
            </span>
          </h2>
          <div className="mt-2 grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6">
            {group.rows.map((row, i) => (
              <CardTile
                key={i}
                storageKey={
                  row.card_edition?.card_image?.find((im) => im.variant === 'original')?.storage_key ?? null
                }
                alt={row.card_edition?.card?.name ?? 'Unknown card'}
              >
                <p className="truncate text-sm font-medium">
                  <span className="tabular-nums text-slate-400">{row.qty}×</span>{' '}
                  {row.card_edition?.card?.name ?? 'Unknown card'}
                </p>
                <p className="text-xs text-slate-400">
                  {row.finish === 'FOIL' ? 'Foil' : 'Nonfoil'} · {row.condition}
                </p>
              </CardTile>
            ))}
          </div>
        </section>
      ))}
    </div>
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
