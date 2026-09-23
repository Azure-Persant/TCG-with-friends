'use client'

import { useState, useTransition } from 'react'
import { acceptRequest, declineRequest } from './actions'

export type BorrowItem = {
  id: string
  cardName: string
  finish: string
  qty: number
  /** A box that already holds this card, where one can be determined --
   *  otherwise the first box in the list. Always a real location id as long
   *  as the owner has at least one box (30's "you need a box first" gate
   *  guarantees that). */
  defaultLocationId: string
}

export function RequestCard({
  id,
  who,
  what,
  note,
  items,
  locations,
}: {
  id: string
  who: string
  what: string
  note: string | null
  /** null for every kind except borrow_request. */
  items: BorrowItem[] | null
  locations: { id: string; name: string | null }[]
}) {
  const [pending, startTransition] = useTransition()
  const [error, setError] = useState<string | null>(null)

  // One origin choice per card (12) -- a borrow request covering several
  // cards that genuinely live in different boxes needs to say so, rather
  // than forcing all of them out of whichever box is picked once for the
  // whole request.
  const [origins, setOrigins] = useState<Record<string, string>>(
    () => Object.fromEntries((items ?? []).map((it) => [it.id, it.defaultLocationId])),
  )

  const needsOrigin = items !== null && items.length > 0
  const allOriginsSet = !needsOrigin || items!.every((it) => origins[it.id])

  function run(action: (fd: FormData) => Promise<{ ok: boolean; error?: string }>) {
    setError(null)
    const fd = new FormData()
    fd.set('requestId', id)
    if (needsOrigin) {
      fd.set('origins', JSON.stringify(items!.map((it) => ({ id: it.id, locationId: origins[it.id] }))))
    }

    startTransition(async () => {
      const result = await action(fd)
      if (!result.ok) setError(result.error ?? 'Something went wrong')
    })
  }

  return (
    <li className="panel p-4">
      <p className="text-sm">
        <span className="font-medium">{who}</span> <span className="text-slate-400">{what}</span>
      </p>
      {note && <p className="mt-1 text-sm text-slate-400">“{note}”</p>}

      {needsOrigin && (
        <ul className="mt-3 flex flex-col gap-2">
          {items!.map((it) => (
            <li key={it.id} className="flex flex-wrap items-center gap-2 text-sm">
              <span className="text-slate-300">
                {it.qty}× {it.cardName}
                {it.finish === 'FOIL' ? ' (foil)' : ''}
              </span>
              <span className="ml-auto text-slate-400">Take from</span>
              <select
                value={origins[it.id] ?? ''}
                onChange={(e) => setOrigins((prev) => ({ ...prev, [it.id]: e.target.value }))}
                className="rounded-md border border-slate-700 bg-slate-800 px-2 py-1 text-sm text-slate-100"
              >
                {locations.map((l) => (
                  <option key={l.id} value={l.id}>
                    {l.name ?? 'Unnamed'}
                  </option>
                ))}
              </select>
            </li>
          ))}
        </ul>
      )}

      <div className="mt-3 flex gap-2">
        <button
          onClick={() => run(acceptRequest)}
          disabled={pending || !allOriginsSet}
          className="rounded-md bg-accent px-3 py-1.5 text-sm font-medium text-white transition hover:opacity-90 disabled:opacity-50"
        >
          Accept
        </button>
        <button
          onClick={() => run(declineRequest)}
          disabled={pending}
          className="rounded-md border border-slate-700 px-3 py-1.5 text-sm text-slate-300 disabled:opacity-50"
        >
          Decline
        </button>
      </div>

      {error && <p className="mt-2 text-sm text-red-400">{error}</p>}
    </li>
  )
}
