import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { CardThumbnail } from '@/app/_components/card-thumbnail'

export const dynamic = 'force-dynamic'

type Search = { q?: string }

type Edition = {
  id: string
  collector_number: string | null
  card: { name: string } | null
  card_set: { name: string; prefix: string } | null
  card_edition_finish: { finish: string }[] | null
  card_image: { storage_key: string; variant: string }[] | null
}

/**
 * Browse the catalog without an account. No box, no quantity, no add action
 * beyond a link into the (authed) /add flow -- this route exists so a visitor
 * can see what the app is about before deciding to sign in.
 */
export default async function CardsPage({ searchParams }: { searchParams: Promise<Search> }) {
  const { q } = await searchParams
  const query = (q ?? '').trim()
  const supabase = await createClient()

  let results: Edition[] = []
  let searchError: string | null = null

  if (query) {
    const { data, error } = await supabase
      .from('card_edition')
      // card!inner, not card: see the same note in app/(app)/add/page.tsx.
      .select(
        `id, collector_number,
         card!inner ( name ),
         card_set ( name, prefix ),
         card_edition_finish ( finish ),
         card_image ( storage_key, variant )`,
      )
      .ilike('card.name', `%${query}%`)
      .limit(40)

    if (error) searchError = error.message
    else results = (data ?? []) as unknown as Edition[]
  }

  return (
    <div className="mx-auto flex max-w-3xl flex-col gap-6 px-6 py-8">
      <header className="flex items-baseline justify-between border-b border-neutral-200 pb-4 dark:border-neutral-800">
        <h1 className="text-lg font-semibold tracking-tight text-accent">Card inventory</h1>
        <Link href="/login" className="text-sm font-medium hover:text-accent hover:underline">
          Sign in
        </Link>
      </header>

      <form method="get" className="flex gap-2">
        <input
          name="q"
          defaultValue={query}
          placeholder="Search for a card…"
          aria-label="Card name"
          className="flex-1 rounded-md border border-neutral-300 px-3 py-2 text-sm outline-none focus:border-accent dark:border-neutral-700 dark:bg-neutral-950"
        />
        <button
          type="submit"
          className="rounded-md bg-accent px-4 py-2 text-sm font-medium text-white transition hover:opacity-90"
        >
          Search
        </button>
      </form>

      {searchError && <p className="text-sm text-red-600">Search failed: {searchError}</p>}

      {!query && (
        <p className="text-sm text-neutral-500">
          Type part of a card&apos;s name to browse the catalog.{' '}
          <Link href="/login" className="underline">
            Sign in
          </Link>{' '}
          to track your own collection and lend cards to friends.
        </p>
      )}

      {query && results.length === 0 && !searchError && (
        <div className="rounded-lg border border-dashed border-neutral-300 p-8 text-center dark:border-neutral-700">
          <p className="font-medium">Nothing matched “{query}”</p>
        </div>
      )}

      <ul className="flex flex-col gap-3">
        {results.map((ed) => (
          <li
            key={ed.id}
            className="flex items-center gap-3 rounded-lg border border-neutral-200 p-4 transition hover:border-neutral-300 dark:border-neutral-800 dark:hover:border-neutral-700"
          >
            <CardThumbnail
              storageKey={ed.card_image?.find((i) => i.variant === 'original')?.storage_key ?? null}
              alt={ed.card?.name ?? 'Unknown card'}
            />
            <div className="flex flex-col gap-1">
              <div className="flex items-baseline gap-2">
                <span className="font-medium">{ed.card?.name ?? 'Unknown card'}</span>
                <span className="text-xs text-neutral-500">
                  {ed.card_set?.name ?? 'Unknown set'}
                  {ed.collector_number ? ` · #${ed.collector_number}` : ''}
                </span>
              </div>
              <span className="text-xs text-neutral-500">
                {(ed.card_edition_finish ?? []).map((f) => f.finish).join(', ') || 'NONFOIL'}
              </span>
            </div>
          </li>
        ))}
      </ul>
    </div>
  )
}
