import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { AddForm } from './add-form'

export const dynamic = 'force-dynamic'

type Search = { q?: string }

/**
 * Find a card and put copies in a box.
 *
 * Search is server-side on purpose: the catalog is ~6,400 editions and belongs
 * in the database, not shipped to the browser. Results are per EDITION, not per
 * card, because a holding is keyed by edition and finish (21) -- which printing
 * you own is part of what you own.
 */
export default async function AddPage({ searchParams }: { searchParams: Promise<Search> }) {
  const { q } = await searchParams
  const query = (q ?? '').trim()
  const supabase = await createClient()

  const { data: locations } = await supabase
    .from('location')
    .select('id, name')
    .eq('kind', 'physical')
    .order('name')

  if (!locations || locations.length === 0) {
    return (
      <div className="rounded-lg border border-dashed border-neutral-300 p-8 text-center dark:border-neutral-700">
        <p className="font-medium">You need a box first</p>
        <p className="mt-1 text-sm text-neutral-500">
          Cards have to live somewhere. Add a box, then come back.
        </p>
        <Link
          href="/locations"
          className="mt-4 inline-block rounded-md bg-neutral-900 px-3 py-2 text-sm font-medium text-white dark:bg-neutral-100 dark:text-neutral-900"
        >
          Add a box
        </Link>
      </div>
    )
  }

  let results: Edition[] = []
  let searchError: string | null = null

  if (query) {
    const { data, error } = await supabase
      .from('card_edition')
      // card!inner, not card: filtering on an embedded table without an inner
      // join returns EVERY edition, with `card` set to null on the ones that
      // did not match. That reads as "the search is broken" rather than as a
      // join problem, so the join type is doing real work here.
      .select(
        `id, collector_number,
         card!inner ( name ),
         card_set ( name, prefix ),
         card_edition_finish ( finish )`,
      )
      .ilike('card.name', `%${query}%`)
      .limit(40)

    if (error) searchError = error.message
    else results = (data ?? []) as unknown as Edition[]
  }

  return (
    <div className="flex flex-col gap-6">
      <form method="get" className="flex gap-2">
        <input
          name="q"
          defaultValue={query}
          placeholder="Search for a card…"
          aria-label="Card name"
          className="flex-1 rounded-md border border-neutral-300 px-3 py-2 text-sm outline-none focus:border-neutral-900 dark:border-neutral-700 dark:bg-neutral-950 dark:focus:border-neutral-100"
        />
        <button
          type="submit"
          className="rounded-md bg-neutral-900 px-4 py-2 text-sm font-medium text-white dark:bg-neutral-100 dark:text-neutral-900"
        >
          Search
        </button>
      </form>

      {searchError && (
        <p className="text-sm text-red-600">Search failed: {searchError}</p>
      )}

      {!query && (
        <p className="text-sm text-neutral-500">
          Type part of a card&apos;s name. Each printing is listed separately, because which one
          you own is part of what you own.
        </p>
      )}

      {query && results.length === 0 && !searchError && (
        <div className="rounded-lg border border-dashed border-neutral-300 p-8 text-center dark:border-neutral-700">
          <p className="font-medium">Nothing matched “{query}”</p>
          <p className="mt-1 text-sm text-neutral-500">
            If the catalog has not been imported yet, there is nothing to find — run the Ingest
            catalog workflow first.
          </p>
        </div>
      )}

      <ul className="flex flex-col gap-3">
        {results.map((ed) => (
          <AddForm
            key={ed.id}
            editionId={ed.id}
            cardName={ed.card?.name ?? 'Unknown card'}
            setName={ed.card_set?.name ?? null}
            collectorNumber={ed.collector_number}
            finishes={(ed.card_edition_finish ?? []).map((f) => f.finish)}
            locations={locations}
          />
        ))}
      </ul>
    </div>
  )
}

type Edition = {
  id: string
  collector_number: string | null
  card: { name: string } | null
  card_set: { name: string; prefix: string } | null
  card_edition_finish: { finish: string }[] | null
}
