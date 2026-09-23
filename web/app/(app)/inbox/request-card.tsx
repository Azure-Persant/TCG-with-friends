'use client'

import { useState, useTransition } from 'react'
import { acceptRequest, declineRequest } from './actions'

export function RequestCard({
  id,
  who,
  what,
  note,
  needsOrigin,
  locations,
}: {
  id: string
  who: string
  what: string
  note: string | null
  needsOrigin: boolean
  locations: { id: string; name: string | null }[]
}) {
  const [pending, startTransition] = useTransition()
  const [error, setError] = useState<string | null>(null)
  const [origin, setOrigin] = useState(locations[0]?.id ?? '')

  function run(action: (fd: FormData) => Promise<{ ok: boolean; error?: string }>) {
    setError(null)
    const fd = new FormData()
    fd.set('requestId', id)
    if (needsOrigin && origin) fd.set('originLocationId', origin)

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
        <label className="mt-3 flex items-center gap-2 text-sm">
          <span className="text-slate-400">Take from</span>
          <select
            value={origin}
            onChange={(e) => setOrigin(e.target.value)}
            className="rounded-md border border-slate-700 bg-slate-800 px-2 py-1 text-sm text-slate-100"
          >
            {locations.map((l) => (
              <option key={l.id} value={l.id}>
                {l.name ?? 'Unnamed'}
              </option>
            ))}
          </select>
        </label>
      )}

      <div className="mt-3 flex gap-2">
        <button
          onClick={() => run(acceptRequest)}
          disabled={pending || (needsOrigin && !origin)}
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
