import { createClient } from '@/lib/supabase/server'
import { LocationList, NewLocation } from './location-ui'

export const dynamic = 'force-dynamic'

/**
 * Your boxes (9): a flat, user-named list. No nesting, no types -- "Deck box",
 * "Binder", "Long box in the closet" are all just names.
 *
 * Only physical locations appear. Holder locations exist too, but they are
 * created by lending and represent someone else having your cards (10), so
 * they are not yours to rename or delete.
 */
export default async function LocationsPage() {
  const supabase = await createClient()

  // Counting in the query rather than fetching every holding: a box with a
  // few thousand cards should still render a one-line summary cheaply.
  const { data, error } = await supabase
    .from('location')
    .select('id, name, holding ( qty )')
    .eq('kind', 'physical')
    .order('name')

  if (error) {
    return (
      <div className="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-200">
        <p className="font-medium">Could not load your boxes</p>
        <p className="mt-1">{error.message}</p>
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-8">
      <section>
        <h2 className="text-sm font-semibold">Where you keep cards</h2>
        <p className="mt-1 text-sm text-neutral-500">
          Boxes, binders, shelves — whatever you actually use. Friends never see these, only
          what you own (14).
        </p>
        <div className="mt-4">
          <NewLocation />
        </div>
      </section>

      <LocationList
        locations={(data ?? []).map((l) => ({
          id: l.id,
          name: l.name,
          cards: (l.holding ?? []).reduce((n: number, h: { qty: number }) => n + h.qty, 0),
        }))}
      />
    </div>
  )
}
