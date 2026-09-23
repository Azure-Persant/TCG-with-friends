import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { DeckHeader } from './deck-header'
import { AddCardSearch } from './add-card-search'
import { DeckCardRow, type Row } from './deck-card-row'

export const dynamic = 'force-dynamic'

type DeckCardQuery = {
  id: string
  section: 'material' | 'main' | 'sideboard'
  finish: string
  qty: number
  edition_id: string
  card_edition: {
    collector_number: string | null
    card: { name: string } | null
    card_set: { name: string } | null
    card_image: { storage_key: string; variant: string }[] | null
  } | null
}

const SECTIONS: { key: Row['section']; label: string }[] = [
  { key: 'material', label: 'Material deck' },
  { key: 'main', label: 'Main deck' },
  { key: 'sideboard', label: 'Sideboard' },
]

export default async function DeckPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  const supabase = await createClient()

  // No .eq('account_id', ...) -- deck's RLS policy already restricts this to
  // the caller's own decks (see web/AGENTS.md). A deck that does not exist or
  // is not the caller's own returns no row either way -- the two cases are
  // deliberately indistinguishable, same reasoning as the sharing functions
  // in the retired Softgen app's HANDOFF (issue #22 will need the same care).
  const { data: deck } = await supabase.from('deck').select('id, name').eq('id', id).maybeSingle()
  if (!deck) notFound()

  const [{ data: cards }, { data: summaryRows }, { data: holdings }] = await Promise.all([
    supabase
      .from('deck_card')
      .select(
        `id, section, finish, qty, edition_id,
         card_edition ( collector_number,
           card ( name ),
           card_set ( name ),
           card_image ( storage_key, variant ) )`,
      )
      .eq('deck_id', id)
      .returns<DeckCardQuery[]>(),
    supabase.rpc('deck_summary', { p_deck: id }),
    supabase
      .from('holding')
      .select('edition_id, finish, qty, location:location_id!inner(kind)')
      .eq('location.kind', 'physical'),
  ])

  const summary = summaryRows?.[0] ?? {
    material_count: 0,
    main_count: 0,
    sideboard_count: 0,
    sideboard_points: 0,
    has_level0_champion: false,
    is_legal: false,
  }

  const owned = new Map<string, number>()
  for (const h of holdings ?? []) {
    const key = `${h.edition_id}:${h.finish}`
    owned.set(key, (owned.get(key) ?? 0) + h.qty)
  }

  const rows: Row[] = (cards ?? []).map((c) => ({
    deckId: id,
    editionId: c.edition_id,
    section: c.section,
    finish: c.finish,
    qty: c.qty,
    cardName: c.card_edition?.card?.name ?? 'Unknown card',
    setName: c.card_edition?.card_set?.name ?? null,
    collectorNumber: c.card_edition?.collector_number ?? null,
    imageStorageKey:
      c.card_edition?.card_image?.find((i) => i.variant === 'original')?.storage_key ?? null,
    owned: owned.get(`${c.edition_id}:${c.finish}`) ?? 0,
  }))

  return (
    <div className="flex flex-col gap-8">
      <DeckHeader deckId={id} name={deck.name} summary={summary} />

      <section>
        <h2 className="mb-2 text-sm font-semibold">Add cards</h2>
        <AddCardSearch deckId={id} />
      </section>

      {SECTIONS.map(({ key, label }) => {
        const sectionRows = rows.filter((r) => r.section === key)
        return (
          <section key={key}>
            <h2 className="text-sm font-semibold">
              {label}
              <span className="ml-2 text-xs font-normal text-neutral-500">
                {sectionRows.reduce((n, r) => n + r.qty, 0)} cards
              </span>
            </h2>
            {sectionRows.length === 0 ? (
              <p className="mt-2 text-sm text-neutral-500">Nothing here yet.</p>
            ) : (
              <ul className="mt-2 divide-y divide-neutral-100 dark:divide-neutral-900">
                {sectionRows.map((r) => (
                  <DeckCardRow key={`${r.editionId}:${r.section}:${r.finish}`} row={r} />
                ))}
              </ul>
            )}
          </section>
        )
      })}
    </div>
  )
}
