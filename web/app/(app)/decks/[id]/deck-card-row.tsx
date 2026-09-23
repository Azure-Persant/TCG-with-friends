'use client'

import Image from 'next/image'
import { useState, useTransition } from 'react'
import { cardImageUrl } from '@/lib/images'
import { FoilOverlay } from '@/app/_components/foil-overlay'
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
  restricted: boolean
}

/**
 * A deck-section grid tile: the art with a quantity badge overlaid on it
 * (bottom-right, matching the reference's ViewCard), a missing-from-
 * inventory warning badge (top-right) when short, and a compact stepper
 * below -- the reference's own view is read-only there, but this page
 * doubles as the editor, so the stepper has to stay.
 */
export function DeckCardRow({ row }: { row: Row }) {
  const [qty, setQty] = useState(row.qty)
  const [pending, start] = useTransition()
  const [error, setError] = useState<string | null>(null)
  const [imgFailed, setImgFailed] = useState(false)

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
  const hasImage = row.imageStorageKey && !imgFailed

  return (
    <div className="panel overflow-hidden">
      <div className="relative aspect-[2.5/3.5] w-full bg-slate-800">
        {hasImage ? (
          <Image
            src={cardImageUrl(row.imageStorageKey!)}
            alt={row.cardName}
            fill
            sizes="(min-width: 1280px) 12vw, (min-width: 768px) 18vw, 40vw"
            className="object-cover"
            onError={() => setImgFailed(true)}
          />
        ) : (
          <span className="absolute inset-0 flex items-center justify-center px-2 text-center text-xs text-slate-500">
            {row.cardName}
          </span>
        )}

        {row.finish === 'FOIL' && <FoilOverlay />}

        {row.finish === 'FOIL' && (
          <span className="absolute left-1 top-1 rounded bg-slate-950/80 px-1.5 py-0.5 text-[10px] font-semibold text-cyan-200">
            Foil
          </span>
        )}

        {missing > 0 && (
          <span
            title={`Missing ${missing} from your collection`}
            className="absolute right-1 top-1 rounded bg-amber-500 px-1 py-0.5 text-[10px] font-semibold text-slate-900 shadow"
          >
            !
          </span>
        )}

        {row.restricted && (
          <span className="absolute bottom-1 left-1 rounded bg-red-600 px-1.5 py-0.5 text-[10px] font-semibold text-white">
            Restricted
          </span>
        )}

        <span className="absolute bottom-1 right-1 rounded bg-slate-950/85 px-1.5 py-0.5 text-xs font-semibold text-white">
          {qty}
        </span>
      </div>

      <div className="flex flex-col gap-1 p-1.5">
        <p className="truncate text-center text-xs font-medium" title={row.cardName}>
          {row.cardName}
        </p>
        <div className="flex items-center justify-center gap-1.5">
          <button
            type="button"
            onClick={() => commit(qty - 1)}
            disabled={pending || qty <= 0}
            className="h-6 w-6 rounded border border-slate-700 text-xs text-slate-300 disabled:opacity-50"
            aria-label={`Remove one ${row.cardName}`}
          >
            –
          </button>
          <span className="w-5 text-center text-xs tabular-nums">{qty}</span>
          <button
            type="button"
            onClick={() => commit(qty + 1)}
            disabled={pending}
            className="h-6 w-6 rounded border border-slate-700 text-xs text-slate-300 disabled:opacity-50"
            aria-label={`Add one ${row.cardName}`}
          >
            +
          </button>
        </div>
        {error && <p className="text-center text-[10px] text-red-400">{error}</p>}
      </div>
    </div>
  )
}
