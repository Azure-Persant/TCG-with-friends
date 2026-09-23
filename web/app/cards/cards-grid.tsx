'use client'

import { useState } from 'react'
import { CardTile } from '@/app/_components/card-tile'
import { CardDetailDialog } from '@/app/_components/card-detail-dialog'

export type SearchRow = {
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

/** A client component only for the detail dialog's open/closed state (23) --
 *  the search itself stays server-rendered in page.tsx. */
export function CardsGrid({ results }: { results: SearchRow[] }) {
  const [detailId, setDetailId] = useState<string | null>(null)

  return (
    <>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6">
        {results.map((ed) => (
          <CardTile
            key={ed.edition_id}
            storageKey={ed.image_storage_key}
            alt={ed.card_name ?? 'Unknown card'}
            foil={(ed.finishes ?? []).includes('FOIL')}
            restricted={ed.restricted ?? false}
            onOpenDetail={() => setDetailId(ed.edition_id)}
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
      <CardDetailDialog editionId={detailId} onClose={() => setDetailId(null)} />
    </>
  )
}
