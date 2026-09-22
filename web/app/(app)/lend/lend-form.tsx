'use client'

import { useMemo, useState, useTransition } from 'react'
import { offerLoan } from './actions'

type Holding = {
  editionId: string
  locationId: string
  locationName: string
  cardName: string
  collectorNumber: string | null
  finish: string
  condition: string
  available: number
}

/** One bucket is uniquely a card, in a finish, in a condition, in a box (8, 21). */
function keyOf(h: Holding) {
  return `${h.editionId}|${h.finish}|${h.condition}|${h.locationId}`
}

export function LendForm({
  friends,
  holdings,
}: {
  friends: { id: string; display_name: string }[]
  holdings: Holding[]
}) {
  const [to, setTo] = useState(friends[0]?.id ?? '')
  const [note, setNote] = useState('')
  const [picked, setPicked] = useState<Record<string, number>>({})
  const [filter, setFilter] = useState('')
  const [done, setDone] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [pending, start] = useTransition()

  const visible = useMemo(() => {
    const q = filter.trim().toLowerCase()
    const list = q
      ? holdings.filter((h) => h.cardName.toLowerCase().includes(q))
      : holdings
    return [...list].sort(
      (a, b) => a.cardName.localeCompare(b.cardName) || a.locationName.localeCompare(b.locationName),
    )
  }, [holdings, filter])

  const total = Object.values(picked).reduce((n, q) => n + q, 0)

  function setQty(h: Holding, qty: number) {
    const key = keyOf(h)
    setDone(null)
    setPicked((prev) => {
      const copy = { ...prev }
      // Clamp to what is actually in the box: offering more than you hold
      // would be rejected by the database anyway, and later — after the other
      // person has already been told about the offer.
      const clamped = Math.max(0, Math.min(qty, h.available))
      if (clamped === 0) delete copy[key]
      else copy[key] = clamped
      return copy
    })
  }

  function submit(e: React.FormEvent) {
    e.preventDefault()
    setError(null)
    setDone(null)

    const lines = holdings
      .filter((h) => picked[keyOf(h)])
      .map((h) => ({
        edition_id: h.editionId,
        finish: h.finish,
        condition: h.condition,
        origin_location_id: h.locationId,
        qty: picked[keyOf(h)]!,
      }))

    const fd = new FormData()
    fd.set('to', to)
    fd.set('note', note)
    fd.set('lines', JSON.stringify(lines))

    start(async () => {
      const r = await offerLoan(fd)
      if (r.ok) {
        setDone(r.message)
        setPicked({})
        setNote('')
      } else {
        setError(r.error)
      }
    })
  }

  return (
    <form onSubmit={submit} className="flex flex-col gap-6">
      <section className="flex flex-col gap-3">
        <label className="flex flex-col gap-1">
          <span className="text-sm font-medium">Lend to</span>
          <select
            value={to}
            onChange={(e) => setTo(e.target.value)}
            className="rounded-md border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-950"
          >
            {friends.map((f) => (
              <option key={f.id} value={f.id}>
                {f.display_name}
              </option>
            ))}
          </select>
        </label>

        <label className="flex flex-col gap-1">
          <span className="text-sm font-medium">Note (optional)</span>
          <input
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder="For the tournament on Saturday"
            className="rounded-md border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-950"
          />
        </label>
      </section>

      <section>
        <div className="flex items-baseline justify-between">
          <h2 className="text-sm font-semibold">Pick cards</h2>
          <span className="text-xs text-neutral-500">
            {total === 0 ? 'none picked' : `${total} picked`}
          </span>
        </div>

        <input
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
          placeholder="Filter by name…"
          aria-label="Filter your cards"
          className="mt-2 w-full rounded-md border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-950"
        />

        <ul className="mt-2 divide-y divide-neutral-100 dark:divide-neutral-900">
          {visible.map((h) => {
            const key = keyOf(h)
            const qty = picked[key] ?? 0
            return (
              <li key={key} className="flex items-center gap-3 py-2 text-sm">
                <span className="flex-1">
                  <span className="font-medium">{h.cardName}</span>{' '}
                  <span className="text-xs text-neutral-500">
                    {h.finish === 'FOIL' ? 'Foil' : 'Nonfoil'} · {h.condition} · {h.locationName}
                  </span>
                </span>
                <span className="text-xs text-neutral-500">{h.available} held</span>
                <input
                  type="number"
                  min={0}
                  max={h.available}
                  value={qty}
                  onChange={(e) => setQty(h, Number(e.target.value) || 0)}
                  aria-label={`How many ${h.cardName} to lend`}
                  className="w-16 rounded-md border border-neutral-300 px-2 py-1 text-sm dark:border-neutral-700 dark:bg-neutral-950"
                />
              </li>
            )
          })}
        </ul>

        {visible.length === 0 && (
          <p className="mt-3 text-sm text-neutral-500">Nothing matches “{filter}”.</p>
        )}
      </section>

      <div className="flex items-center gap-3">
        <button
          type="submit"
          disabled={pending || total === 0}
          className="rounded-md bg-neutral-900 px-4 py-2 text-sm font-medium text-white disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900"
        >
          {pending ? 'Sending…' : 'Send offer'}
        </button>
        <span className="text-sm text-neutral-500">
          Nothing leaves your boxes until they accept.
        </span>
      </div>

      {done && <p className="text-sm text-green-700 dark:text-green-400">{done}</p>}
      {error && (
        <p role="alert" className="text-sm text-red-600">
          {error}
        </p>
      )}
    </form>
  )
}
