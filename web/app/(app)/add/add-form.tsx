'use client'

import { useState, useTransition } from 'react'
import { addCards } from './actions'
import { CardTile } from '@/app/_components/card-tile'
import { CardDetailDialog } from '@/app/_components/card-detail-dialog'

/** Worst to best is the order people actually think in when grading. */
const CONDITIONS = ['MINT', 'NM', 'LP', 'MP', 'HP', 'DMG'] as const

export function AddForm({
  editionId,
  cardName,
  setName,
  collectorNumber,
  finishes,
  imageStorageKey,
  restricted,
  locations,
}: {
  editionId: string
  cardName: string
  setName: string | null
  collectorNumber: string | null
  finishes: string[]
  imageStorageKey: string | null
  restricted: boolean
  locations: { id: string; name: string | null }[]
}) {
  // A printing that exists only in foil should not offer nonfoil (21).
  const available = finishes.length > 0 ? finishes : ['NONFOIL']

  const [finish, setFinish] = useState(available[0]!)
  const [condition, setCondition] = useState<string>('NM')
  const [locationId, setLocationId] = useState(locations[0]?.id ?? '')
  const [qty, setQty] = useState(1)
  const [done, setDone] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [pending, start] = useTransition()
  const [detailOpen, setDetailOpen] = useState(false)

  function submit(e: React.FormEvent) {
    e.preventDefault()
    setError(null)
    setDone(null)

    const fd = new FormData()
    fd.set('editionId', editionId)
    fd.set('finish', finish)
    fd.set('condition', condition)
    fd.set('locationId', locationId)
    fd.set('qty', String(qty))
    fd.set('cardName', cardName)

    start(async () => {
      const r = await addCards(fd)
      if (r.ok) setDone(r.message)
      else setError(r.error)
    })
  }

  return (
    <>
      <CardTile
        storageKey={imageStorageKey}
        alt={cardName}
        foil={finish === 'FOIL'}
        restricted={restricted}
        onOpenDetail={() => setDetailOpen(true)}
      >
        <div>
          <p className="truncate text-sm font-medium">{cardName}</p>
          <p className="truncate text-xs text-slate-400">
            {setName ?? 'Unknown set'}
            {collectorNumber ? ` · #${collectorNumber}` : ''}
          </p>
        </div>

        <form onSubmit={submit} className="flex flex-col gap-1.5">
          <div className="grid grid-cols-2 gap-1.5">
            <select
              value={finish}
              onChange={(e) => setFinish(e.target.value)}
              aria-label="Finish"
              className="rounded-md border border-slate-700 bg-slate-800 px-1.5 py-1 text-xs text-slate-100"
            >
              {available.map((f) => (
                <option key={f} value={f}>
                  {f === 'FOIL' ? 'Foil' : 'Nonfoil'}
                </option>
              ))}
            </select>
            <select
              value={condition}
              onChange={(e) => setCondition(e.target.value)}
              aria-label="Condition"
              className="rounded-md border border-slate-700 bg-slate-800 px-1.5 py-1 text-xs text-slate-100"
            >
              {CONDITIONS.map((c) => (
                <option key={c} value={c}>
                  {c}
                </option>
              ))}
            </select>
          </div>

          <select
            value={locationId}
            onChange={(e) => setLocationId(e.target.value)}
            aria-label="Box"
            className="w-full rounded-md border border-slate-700 bg-slate-800 px-1.5 py-1 text-xs text-slate-100"
          >
            {locations.map((l) => (
              <option key={l.id} value={l.id}>
                {l.name ?? 'Unnamed'}
              </option>
            ))}
          </select>

          <div className="flex gap-1.5">
            <input
              type="number"
              min={1}
              max={999}
              value={qty}
              onChange={(e) => setQty(Math.max(1, Number(e.target.value) || 1))}
              aria-label="Quantity"
              className="w-12 rounded-md border border-slate-700 bg-slate-800 px-1.5 py-1 text-xs text-slate-100"
            />
            <button
              type="submit"
              disabled={pending}
              className="flex-1 rounded-md bg-accent px-2 py-1 text-xs font-medium text-white transition hover:opacity-90 disabled:opacity-50"
            >
              {pending ? 'Adding…' : 'Add'}
            </button>
          </div>
        </form>

        {done && <p className="text-xs text-green-400">{done}</p>}
        {error && (
          <p role="alert" className="text-xs text-red-400">
            {error}
          </p>
        )}
      </CardTile>
      {detailOpen && <CardDetailDialog editionId={editionId} onClose={() => setDetailOpen(false)} />}
    </>
  )
}
