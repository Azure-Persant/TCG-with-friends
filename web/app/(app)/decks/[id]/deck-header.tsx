'use client'

import { useState, useTransition } from 'react'
import { renameDeck } from './actions'

type Summary = {
  material_count: number
  main_count: number
  sideboard_count: number
  sideboard_points: number
  has_level0_champion: boolean
  is_legal: boolean
}

export function DeckHeader({ deckId, name, summary }: { deckId: string; name: string; summary: Summary }) {
  const [value, setValue] = useState(name)
  const [pending, start] = useTransition()
  const [error, setError] = useState<string | null>(null)

  function save() {
    if (value.trim() === name || !value.trim()) return
    setError(null)
    const fd = new FormData()
    fd.set('deckId', deckId)
    fd.set('name', value)
    start(async () => {
      const r = await renameDeck(fd)
      if (!r.ok) setError(r.error)
    })
  }

  const issues: string[] = []
  if (summary.main_count < 60) issues.push(`main deck needs ${60 - summary.main_count} more card(s)`)
  if (!summary.has_level0_champion) issues.push('needs a Level 0 champion in the material deck')

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center gap-2">
        <input
          value={value}
          onChange={(e) => setValue(e.target.value)}
          onBlur={save}
          disabled={pending}
          className="flex-1 rounded-md border border-neutral-300 px-3 py-2 text-lg font-semibold tracking-tight outline-none focus:border-accent disabled:opacity-50 dark:border-neutral-700 dark:bg-neutral-950"
        />
      </div>
      {error && <p className="text-sm text-red-600">{error}</p>}

      <div className="flex flex-wrap items-center gap-3 text-xs text-neutral-500">
        <span>Material {summary.material_count}/12</span>
        <span>Main {summary.main_count}/60 min</span>
        <span>
          Sideboard {summary.sideboard_count}/15 cards · {summary.sideboard_points}/15 points
        </span>
        {summary.is_legal ? (
          <span className="rounded-full bg-green-100 px-2 py-0.5 font-medium text-green-800 dark:bg-green-950 dark:text-green-300">
            Legal
          </span>
        ) : (
          <span
            className="rounded-full bg-amber-100 px-2 py-0.5 font-medium text-amber-900 dark:bg-amber-950 dark:text-amber-200"
            title={issues.join('; ')}
          >
            Not yet legal
          </span>
        )}
      </div>
      {!summary.is_legal && issues.length > 0 && (
        <ul className="text-xs text-neutral-500">
          {issues.map((i) => (
            <li key={i}>· {i}</li>
          ))}
        </ul>
      )}
    </div>
  )
}
