import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { CardTile } from '@/app/_components/card-tile'
import { TopNav } from '@/app/_components/top-nav'
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
  restricted: boolean | null
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

  // Signed-in visitors reach /cards too -- it's the "Browse" link in the
  // authenticated nav, not just the pre-login route -- so the header has to
  // know which one it is rather than always rendering the anonymous one.
  const {
    data: { user },
  } = await supabase.auth.getUser()

  let nav: React.ReactNode
  if (user) {
    const { data: account } = await supabase
      .from('account')
      .select('display_name, username')
      .eq('id', user.id)
      .single()
    const { count: pending } = await supabase
      .from('request')
      .select('id', { count: 'exact', head: true })
      .eq('recipient_account_id', user.id)
      .eq('status', 'pending')
    nav = (
      <TopNav
        signedIn
        accountLabel={account?.username ? `@${account.username}` : (account?.display_name ?? user.email ?? '')}
        pending={pending ?? 0}
      />
    )
  } else {
    nav = <TopNav signedIn={false} />
  }

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
      {nav}
      <div className="mx-auto flex max-w-7xl flex-col gap-6 px-6 py-8">
        <FilterBar values={values} options={(options ?? []) as FilterOption[]} />

        {searchError && <p className="text-sm text-red-400">Search failed: {searchError}</p>}

        {!hasAnyFilter(values) && (
          <p className="text-sm text-slate-400">
            Type part of a card&apos;s name, or use the filters above, to browse the catalog.
            {!user && (
              <>
                {' '}
                <Link href="/login" className="underline">
                  Sign in
                </Link>{' '}
                to track your own collection and lend cards to friends.
              </>
            )}
          </p>
        )}

        {hasAnyFilter(values) && results.length === 0 && !searchError && (
          <div className="rounded-lg border border-dashed border-white/20 p-8 text-center">
            <p className="font-medium">Nothing matched those filters</p>
          </div>
        )}

        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6">
          {results.map((ed) => (
            <CardTile
              key={ed.edition_id}
              storageKey={ed.image_storage_key}
              alt={ed.card_name ?? 'Unknown card'}
              foil={(ed.finishes ?? []).includes('FOIL')}
              restricted={ed.restricted ?? false}
            >
              <p className="truncate text-sm font-medium">{ed.card_name ?? 'Unknown card'}</p>
              <p className="truncate text-xs text-slate-400">
                {ed.set_name ?? 'Unknown set'}
                {ed.collector_number ? ` · #${ed.collector_number}` : ''}
              </p>
              <p className="truncate text-xs text-slate-400">
                {ed.element ? `${ed.element} · ` : ''}
                {(ed.finishes ?? []).join(', ') || 'NONFOIL'}
              </p>
            </CardTile>
          ))}
        </div>
      </div>
    </div>
  )
}
