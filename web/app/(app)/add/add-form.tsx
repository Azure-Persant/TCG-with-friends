'use client'

import { useState, useTransition } from 'react'
import { addCards } from './actions'
import { CardThumbnail } from '@/app/_components/card-thumbnail'

/** Worst to best is the order people actually think in when grading. */
const CONDITIONS = ['MINT', 'NM', 'LP', 'MP', 'HP', 'DMG'] as const

export function AddForm({
  editionId,
  cardName,
  setName,
  collectorNumber,
  finishes,
  imageStorageKey,
  locations,
}: {
  editionId: string
  cardName: string
  setName: string | null
  collectorNumber: string | null
  finishes: string[]
  imageStorageKey: string | null
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
    <li className="panel p-4">
      <div className="flex items-center gap-3">
        <CardThumbnail storageKey={imageStorageKey} alt={cardName} />
        <div className="flex flex-col gap-0.5">
          <span className="font-medium">{cardName}</span>
          <span className="text-xs text-slate-400">
            {setName ?? 'Unknown set'}
            {collectorNumber ? ` · #${collectorNumber}` : ''}
          </span>
        </div>
      </div>

      <form onSubmit={submit} className="mt-3 flex flex-wrap items-end gap-2">
        <Field label="Finish">
          <select
            value={finish}
            onChange={(e) => setFinish(e.target.value)}
            className="rounded-md border border-slate-700 bg-slate-800 px-2 py-1.5 text-sm text-slate-100"
          >
            {available.map((f) => (
              <option key={f} value={f}>
                {f === 'FOIL' ? 'Foil' : 'Nonfoil'}
              </option>
            ))}
          </select>
        </Field>

        <Field label="Condition">
          <select
            value={condition}
            onChange={(e) => setCondition(e.target.value)}
            className="rounded-md border border-slate-700 bg-slate-800 px-2 py-1.5 text-sm text-slate-100"
          >
            {CONDITIONS.map((c) => (
              <option key={c} value={c}>
                {c}
              </option>
            ))}
          </select>
        </Field>

        <Field label="Box">
          <select
            value={locationId}
            onChange={(e) => setLocationId(e.target.value)}
            className="rounded-md border border-slate-700 bg-slate-800 px-2 py-1.5 text-sm text-slate-100"
          >
            {locations.map((l) => (
              <option key={l.id} value={l.id}>
                {l.name ?? 'Unnamed'}
              </option>
            ))}
          </select>
        </Field>

        <Field label="Qty">
          <input
            type="number"
            min={1}
            max={999}
            value={qty}
            onChange={(e) => setQty(Math.max(1, Number(e.target.value) || 1))}
            className="w-16 rounded-md border border-slate-700 bg-slate-800 px-2 py-1.5 text-sm text-slate-100"
          />
        </Field>

        <button
          type="submit"
          disabled={pending}
          className="rounded-md bg-accent px-3 py-1.5 text-sm font-medium text-white transition hover:opacity-90 disabled:opacity-50"
        >
          {pending ? 'Adding…' : 'Add'}
        </button>
      </form>

      {done && <p className="mt-2 text-sm text-green-700 dark:text-green-400">{done}</p>}
      {error && (
        <p role="alert" className="mt-2 text-sm text-red-400">
          {error}
        </p>
      )}
    </li>
  )
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="flex flex-col gap-1">
      <span className="text-xs text-slate-400">{label}</span>
      {children}
    </label>
  )
}
