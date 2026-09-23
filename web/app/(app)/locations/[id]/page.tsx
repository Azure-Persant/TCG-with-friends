import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'

export const dynamic = 'force-dynamic'

type Row = {
  qty: number
  condition: string
  finish: string
  card_edition: {
    collector_number: string | null
    card: { name: string } | null
    card_set: { name: string } | null
  } | null
}

/**
 * What is actually in one box.
 *
 * RLS restricts `location` to the caller, so a bad or someone else's id
 * returns no row and this 404s -- the privacy check and the not-found check
 * are the same check, which is why there is no ownership test here.
 */
export default async function LocationPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  const supabase = await createClient()

  const { data: location } = await supabase
    .from('location')
    .select('id, name, kind, holder_account_id')
    .eq('id', id)
    .maybeSingle()

  if (!location) notFound()

  const { data, error } = await supabase
    .from('holding')
    .select(
      `qty, condition, finish,
       card_edition ( collector_number, card ( name ), card_set ( name ) )`,
    )
    .eq('location_id', id)

  const rows = (data ?? []) as unknown as Row[]
  const total = rows.reduce((n, r) => n + r.qty, 0)

  // One bucket per condition and finish (8, 21), so the same card can appear
  // more than once. Sorting by name keeps those copies adjacent.
  const sorted = [...rows].sort((a, b) => {
    const an = a.card_edition?.card?.name ?? ''
    const bn = b.card_edition?.card?.name ?? ''
    return an.localeCompare(bn) || a.finish.localeCompare(b.finish) || a.condition.localeCompare(b.condition)
  })

  return (
    <div className="flex flex-col gap-4">
      <div>
        <Link href="/locations" className="text-sm text-slate-400 hover:underline">
          ← All boxes
        </Link>
        <h2 className="mt-2 flex items-baseline gap-2 text-lg font-semibold">
          {location.name ?? 'Unnamed'}
          {location.kind === 'holder' && (
            <span className="rounded bg-amber-100 px-1.5 py-0.5 text-xs font-normal text-amber-900 dark:bg-amber-950 dark:text-amber-200">
              with someone else
            </span>
          )}
        </h2>
        <p className="text-sm text-slate-400">
          {total === 0
            ? 'Empty'
            : `${total} card${total === 1 ? '' : 's'} in ${rows.length} ${
                rows.length === 1 ? 'grouping' : 'groupings'
              }`}
        </p>
      </div>

      {error && (
        <p className="text-sm text-red-400">Could not load this box: {error.message}</p>
      )}

      {sorted.length === 0 ? (
        <div className="rounded-lg border border-dashed border-white/20 p-8 text-center">
          <p className="font-medium">Nothing in here</p>
          <p className="mt-1 text-sm text-slate-400">
            Add cards and choose this box, and they will show up here.
          </p>
          <Link
            href="/add"
            className="mt-4 inline-block rounded-md bg-accent px-3 py-2 text-sm font-medium text-white transition hover:opacity-90"
          >
            Add cards
          </Link>
        </div>
      ) : (
        <ul className="divide-y divide-white/10">
          {sorted.map((r, i) => (
            <li key={i} className="flex items-baseline gap-3 py-2 text-sm">
              <span className="w-8 tabular-nums text-slate-400">{r.qty}×</span>
              <span className="flex-1">
                <span className="font-medium">
                  {r.card_edition?.card?.name ?? 'Unknown card'}
                </span>
                <span className="ml-2 text-xs text-slate-400">
                  {r.card_edition?.card_set?.name ?? 'Unknown set'}
                  {r.card_edition?.collector_number ? ` · #${r.card_edition.collector_number}` : ''}
                </span>
              </span>
              <span className="text-xs text-slate-400">
                {r.finish === 'FOIL' ? 'Foil' : 'Nonfoil'} · {r.condition}
              </span>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
