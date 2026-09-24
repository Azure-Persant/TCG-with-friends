'use client'

import { useState, useTransition } from 'react'
import { setHoldingQty, setHoldingCondition, setHoldingFinish, moveHolding } from './actions'

/** Worst to best, same order used everywhere else a condition is picked. */
const CONDITIONS = ['MINT', 'NM', 'LP', 'MP', 'HP', 'DMG'] as const

/**
 * Inline correct-or-remove control per collection tile (29). Quantity,
 * condition, finish and location are each edited independently rather than
 * combined into one submit: changing any one of the three "which bucket is
 * this" dimensions immediately recategorises/moves the CURRENT quantity,
 * so there's never a submit that has to guess what a simultaneous "qty 3,
 * condition LP" from a "qty 5, NM" starting point was supposed to mean --
 * move 3 and leave 2, or discard 2 and relabel the rest? Four small,
 * unambiguous actions instead of one that has to guess.
 */
export function EditHolding({
  editionId,
  finish,
  locationId,
  condition,
  qty,
  availableFinishes,
  locations,
}: {
  editionId: string
  finish: string
  locationId: string
  condition: string
  qty: number
  availableFinishes: string[]
  locations: { id: string; name: string | null }[]
}) {
  const [open, setOpen] = useState(false)
  const [qtyValue, setQtyValue] = useState(String(qty))
  const [pending, start] = useTransition()
  const [error, setError] = useState<string | null>(null)

  function saveQty() {
    const next = Number(qtyValue)
    if (!Number.isFinite(next) || next < 0) {
      setError('Enter a quantity of 0 or more')
      return
    }
    if (next === 0 && !window.confirm('Remove this holding entirely?')) return
    setError(null)
    const fd = new FormData()
    fd.set('editionId', editionId)
    fd.set('finish', finish)
    fd.set('locationId', locationId)
    fd.set('condition', condition)
    fd.set('qty', String(next))
    start(async () => {
      const r = await setHoldingQty(fd)
      if (!r.ok) setError(r.error)
      else setOpen(false)
    })
  }

  function changeCondition(toCondition: string) {
    if (toCondition === condition) return
    setError(null)
    const fd = new FormData()
    fd.set('editionId', editionId)
    fd.set('finish', finish)
    fd.set('locationId', locationId)
    fd.set('fromCondition', condition)
    fd.set('toCondition', toCondition)
    fd.set('qty', String(qty))
    start(async () => {
      const r = await setHoldingCondition(fd)
      if (!r.ok) setError(r.error)
      else setOpen(false)
    })
  }

  function changeFinish(toFinish: string) {
    if (toFinish === finish) return
    setError(null)
    const fd = new FormData()
    fd.set('editionId', editionId)
    fd.set('locationId', locationId)
    fd.set('condition', condition)
    fd.set('fromFinish', finish)
    fd.set('toFinish', toFinish)
    fd.set('qty', String(qty))
    start(async () => {
      const r = await setHoldingFinish(fd)
      if (!r.ok) setError(r.error)
      else setOpen(false)
    })
  }

  function changeLocation(toLocationId: string) {
    if (toLocationId === locationId) return
    setError(null)
    const fd = new FormData()
    fd.set('editionId', editionId)
    fd.set('finish', finish)
    fd.set('condition', condition)
    fd.set('fromLocationId', locationId)
    fd.set('toLocationId', toLocationId)
    fd.set('qty', String(qty))
    start(async () => {
      const r = await moveHolding(fd)
      if (!r.ok) setError(r.error)
      else setOpen(false)
    })
  }

  if (!open) {
    return (
      <button
        type="button"
        onClick={() => setOpen(true)}
        className="mt-auto rounded-md border border-slate-700 px-2 py-1 text-xs text-slate-300 hover:bg-white/10"
      >
        Edit
      </button>
    )
  }

  return (
    <div className="mt-auto flex flex-col gap-1.5" onClick={(e) => e.stopPropagation()}>
      <div className="flex gap-1">
        <select
          value={finish}
          onChange={(e) => changeFinish(e.target.value)}
          disabled={pending || availableFinishes.length < 2}
          aria-label="Finish"
          className="flex-1 rounded-md border border-slate-700 bg-slate-800 px-1.5 py-1 text-xs text-slate-100 disabled:opacity-50"
        >
          {(availableFinishes.length > 0 ? availableFinishes : [finish]).map((f) => (
            <option key={f} value={f}>
              {f === 'FOIL' ? 'Foil' : 'Nonfoil'}
            </option>
          ))}
        </select>
        <select
          value={condition}
          onChange={(e) => changeCondition(e.target.value)}
          disabled={pending}
          aria-label="Condition"
          className="flex-1 rounded-md border border-slate-700 bg-slate-800 px-1.5 py-1 text-xs text-slate-100 disabled:opacity-50"
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
        onChange={(e) => changeLocation(e.target.value)}
        disabled={pending || locations.length < 2}
        aria-label="Box"
        className="w-full rounded-md border border-slate-700 bg-slate-800 px-1.5 py-1 text-xs text-slate-100 disabled:opacity-50"
      >
        {locations.map((l) => (
          <option key={l.id} value={l.id}>
            {l.name ?? 'Unnamed'}
          </option>
        ))}
      </select>
      <div className="flex gap-1">
        <input
          type="number"
          min={0}
          value={qtyValue}
          onChange={(e) => setQtyValue(e.target.value)}
          aria-label="Quantity"
          className="w-14 rounded-md border border-slate-700 bg-slate-800 px-1.5 py-1 text-xs text-slate-100"
        />
        <button
          type="button"
          onClick={saveQty}
          disabled={pending}
          className="flex-1 rounded-md bg-accent px-2 py-1 text-xs font-medium text-white transition hover:opacity-90 disabled:opacity-50"
        >
          {pending ? 'Saving…' : 'Save qty'}
        </button>
        <button
          type="button"
          onClick={() => {
            setQtyValue(String(qty))
            setError(null)
            setOpen(false)
          }}
          disabled={pending}
          className="rounded-md border border-slate-700 px-2 py-1 text-xs text-slate-300 disabled:opacity-50"
        >
          Close
        </button>
      </div>
      {error && (
        <p role="alert" className="text-[10px] text-red-400">
          {error}
        </p>
      )}
    </div>
  )
}
