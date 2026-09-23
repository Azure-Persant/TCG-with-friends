'use client'

import { useState, useTransition } from 'react'
import { CardThumbnail } from '@/app/_components/card-thumbnail'
import { setDeckCard } from './actions'

export type Row = {
  deckId: string
  editionId: string
  section: 'material' | 'main' | 'sideboard'
  finish: string
  qty: number
  cardName: string
  setName: string | null
  collectorNumber: string | null
  imageStorageKey: string | null
  owned: number
}

export function DeckCardRow({ row }: { row: Row }) {
  const [qty, setQty] = useState(row.qty)
  const [pending, start] = useTransition()
  const [error, setError] = useState<string | null>(null)

  function commit(next: number) {
    const clamped = Math.max(0, next)
    setQty(clamped)
    setError(null)
    const fd = new FormData()
    fd.set('deckId', row.deckId)
    fd.set('editionId', row.editionId)
    fd.set('section', row.section)
    fd.set('finish', row.finish)
    fd.set('qty', String(clamped))
    start(async () => {
      const r = await setDeckCard(fd)
      if (!r.ok) {
        setError(r.error)
        setQty(row.qty) // roll back to the last confirmed value
      }
    })
  }

  const missing = Math.max(0, qty - row.owned)

  return (
    <li className="flex items-center gap-3 py-2 text-sm">
      <CardThumbnail storageKey={row.imageStorageKey} alt={row.cardName} />
      <div className="flex flex-1 flex-col gap-0.5">
        <div className="flex items-baseline gap-2">
          <span className="font-medium">{row.cardName}</span>
          <span className="text-xs text-slate-400">
            {row.setName ?? 'Unknown set'}
            {row.collectorNumber ? ` · #${row.collectorNumber}` : ''}
            {row.finish === 'FOIL' ? ' · Foil' : ''}
          </span>
        </div>
        {missing > 0 && (
          <span className="text-xs text-amber-700 dark:text-amber-400">
            Missing {missing} from your collection
          </span>
        )}
        {error && <span className="text-xs text-red-400">{error}</span>}
      </div>
      <div className="flex items-center gap-2">
        <button
          type="button"
          onClick={() => commit(qty - 1)}
          disabled={pending || qty <= 0}
          className="h-7 w-7 rounded-md border border-slate-700 text-sm text-slate-300 disabled:opacity-50"
          aria-label={`Remove one ${row.cardName}`}
        >
          –
        </button>
        <span className="w-6 text-center tabular-nums">{qty}</span>
        <button
          type="button"
          onClick={() => commit(qty + 1)}
          disabled={pending}
          className="h-7 w-7 rounded-md border border-slate-700 text-sm text-slate-300 disabled:opacity-50"
          aria-label={`Add one ${row.cardName}`}
        >
          +
        </button>
      </div>
    </li>
  )
}
