import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { CardThumbnail } from '@/app/_components/card-thumbnail'
import { FilterBar, readFilterValues, hasAnyFilter, type FilterOption } from '@/app/_components/filter-bar'

export const dynamic = 'force-dynamic'

type Search = Record<string, string | string[] | undefined>

type SearchRow = {
  edition_id: string
  collector_number: string | null
  card_name: string | null
  set_name: string | null
  set_prefix: string | null
  finishes: string[] | null
  image_storage_key: string | null
  element: string | null
  types: string[] | null
  subtypes: string[] | null
  classes: string[] | null
}

/** number() -> undefined for '' or garbage, never NaN reaching Postgres. */
function toInt(v: string): number | undefined {
  if (v.trim() === '') return undefined
  const n = Number(v)
  return Number.isFinite(n) ? Math.trunc(n) : undefined
}

/**
 * Browse the catalog without an account. No box, no quantity, no add action
 * beyond a link into the (authed) /add flow -- this route exists so a visitor
 * can see what the app is about before deciding to sign in.
 *
 * Filtering (issue #20) goes through search_card_editions, a Postgres
 * function, rather than PostgREST embedding -- see db/schema.sql for why
 * jsonb attribute filtering doesn't fit PostgREST's operator set cleanly.
 */
export default async function CardsPage({ searchParams }: { searchParams: Promise<Search> }) {
  const sp = await searchParams
  const values = readFilterValues(sp)
  const supabase = await createClient()

  const { data: options } = await supabase.from('card_filter_options').select('kind, value, count')

  let results: SearchRow[] = []
  let searchError: string | null = null

  if (hasAnyFilter(values)) {
    const { data, error } = await supabase.rpc('search_card_editions', {
      p_query: values.q.trim() || undefined,
      p_elements: values.elements.length ? values.elements : undefined,
      p_types: values.types.length ? values.types : undefined,
      p_subtypes: values.subtypes.length ? values.subtypes : undefined,
      p_classes: values.classes.length ? values.classes : undefined,
      p_cost_memory_min: toInt(values.memMin),
      p_cost_memory_max: toInt(values.memMax),
      p_cost_reserve_min: toInt(values.resMin),
      p_cost_reserve_max: toInt(values.resMax),
    })

    if (error) searchError = error.message
    else results = (data ?? []) as SearchRow[]
  }

  return (
    <div className="app-backdrop text-slate-100">
      <div className="mx-auto flex max-w-3xl flex-col gap-6 px-6 py-8">
        <header className="flex items-baseline justify-between border-b border-white/10 pb-4">
          <h1 className="font-heading text-lg font-bold tracking-tight text-accent">Card inventory</h1>
          <Link href="/login" className="text-sm font-medium hover:text-accent hover:underline">
            Sign in
          </Link>
        </header>

        <FilterBar values={values} options={(options ?? []) as FilterOption[]} />

        {searchError && <p className="text-sm text-red-400">Search failed: {searchError}</p>}

        {!hasAnyFilter(values) && (
          <p className="text-sm text-slate-400">
            Type part of a card&apos;s name, or use the filters above, to browse the catalog.{' '}
            <Link href="/login" className="underline">
              Sign in
            </Link>{' '}
            to track your own collection and lend cards to friends.
          </p>
        )}

        {hasAnyFilter(values) && results.length === 0 && !searchError && (
          <div className="rounded-lg border border-dashed border-white/20 p-8 text-center">
            <p className="font-medium">Nothing matched those filters</p>
          </div>
        )}

        <ul className="flex flex-col gap-3">
          {results.map((ed) => (
            <li
              key={ed.edition_id}
              className="flex items-center gap-3 panel p-4 transition hover:border-white/20"
            >
              <CardThumbnail storageKey={ed.image_storage_key} alt={ed.card_name ?? 'Unknown card'} />
              <div className="flex flex-col gap-1">
                <div className="flex items-baseline gap-2">
                  <span className="font-medium">{ed.card_name ?? 'Unknown card'}</span>
                  <span className="text-xs text-slate-400">
                    {ed.set_name ?? 'Unknown set'}
                    {ed.collector_number ? ` · #${ed.collector_number}` : ''}
                  </span>
                </div>
                <span className="text-xs text-slate-400">
                  {ed.element ? `${ed.element} · ` : ''}
                  {(ed.finishes ?? []).join(', ') || 'NONFOIL'}
                </span>
              </div>
            </li>
          ))}
        </ul>
      </div>
    </div>
  )
}
