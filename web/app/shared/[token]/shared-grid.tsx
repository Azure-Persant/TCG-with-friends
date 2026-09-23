import { CardTile } from '@/app/_components/card-tile'

export type SharedRow = {
  edition_id: string
  card_name: string
  set_name: string | null
  collector_number: string | null
  image_storage_key: string | null
  finish: string
  condition: string
  qty_owned: number
  qty_on_loan: number
}

/**
 * The grid itself, split out from page.tsx only for readability -- unlike
 * /cards' CardsGrid, this needs no client state of its own. (Once #23's
 * card detail dialog merges, wiring an onOpenDetail here to reuse it would
 * be a cheap follow-up -- not done now so this stays independent of that
 * unmerged branch.)
 */
export function SharedGrid({ rows }: { rows: SharedRow[] }) {
  return (
    <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6">
      {rows.map((r) => (
        <CardTile
          key={`${r.edition_id}:${r.finish}:${r.condition}`}
          storageKey={r.image_storage_key}
          alt={r.card_name}
          foil={r.finish === 'FOIL'}
        >
          <p className="truncate text-sm font-medium">{r.card_name}</p>
          <p className="truncate text-xs text-slate-400">{r.set_name ?? 'Unknown set'}</p>
          <p className="text-xs text-slate-400">{r.condition}</p>
          <div className="mt-auto flex items-center gap-1.5 text-xs">
            {r.qty_owned > 0 && (
              <span className="rounded-md border border-cyan-500 px-1.5 py-0.5 font-medium text-cyan-400">
                {r.qty_owned} owned
              </span>
            )}
            {r.qty_on_loan > 0 && (
              <span className="rounded-md border border-amber-500 px-1.5 py-0.5 font-medium text-amber-400">
                {r.qty_on_loan} on loan
              </span>
            )}
          </div>
        </CardTile>
      ))}
    </div>
  )
}
