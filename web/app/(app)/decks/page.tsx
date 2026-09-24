import { createClient } from '@/lib/supabase/server'
import { NewDeck, DeckList, type Deck } from './deck-ui'

export const dynamic = 'force-dynamic'

export default async function DecksPage() {
  const supabase = await createClient()

  // No .eq('account_id', ...) -- deck's RLS policy already restricts this to
  // the caller's own decks (see web/AGENTS.md).
  // The FK hint is required, not decoration: deck also reaches card_edition
  // through deck_card, so a bare card_edition(...) embed is ambiguous.
  const { data, error } = await supabase
    .from('deck')
    .select(
      `id, name, updated_at, cover_edition_id,
       cover:card_edition!deck_cover_edition_id_fkey ( card ( name ), card_image ( storage_key, variant ) )`,
    )
    .order('updated_at', { ascending: false })
    .returns<Deck[]>()

  return (
    <div className="flex flex-col gap-6">
      <h1 className="font-heading text-4xl font-bold text-white">My Decks</h1>
      <NewDeck />
      {error && <p className="text-sm text-red-400">Could not load decks: {error.message}</p>}
      <DeckList decks={data ?? []} />
    </div>
  )
}
