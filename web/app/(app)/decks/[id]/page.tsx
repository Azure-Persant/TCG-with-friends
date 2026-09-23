import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { isRestricted } from '@/lib/legality'
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
    card: { name: string; attributes: Record<string, unknown> } | null
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
           card ( name, attributes ),
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
    restricted: isRestricted(c.card_edition?.card?.attributes),
  }))

  const missingTotal = rows.reduce((n, r) => n + Math.max(0, r.qty - r.owned), 0)

  return (
    <div className="flex flex-col gap-8">
      <DeckHeader deckId={id} name={deck.name} summary={summary} missingTotal={missingTotal} />

      <section>
        <h2 className="mb-2 text-sm font-semibold text-white">Add cards</h2>
        <AddCardSearch deckId={id} />
      </section>

      {SECTIONS.map(({ key, label }) => {
        const sectionRows = rows.filter((r) => r.section === key)
        return (
          <section key={key} className="panel-solid p-3">
            <div className="mb-2 flex items-center justify-between px-1">
              <h2 className="font-heading text-lg font-bold text-white">{label}</h2>
              <span className="text-sm text-slate-400">
                {sectionRows.reduce((n, r) => n + r.qty, 0)} cards
              </span>
            </div>
            {sectionRows.length === 0 ? (
              <p className="px-1 py-2 text-sm text-slate-400">Nothing here yet.</p>
            ) : (
              <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-7 2xl:grid-cols-8">
                {sectionRows.map((r) => (
                  <DeckCardRow key={`${r.editionId}:${r.section}:${r.finish}`} row={r} />
                ))}
              </div>
            )}
          </section>
        )
      })}
    </div>
  )
}
