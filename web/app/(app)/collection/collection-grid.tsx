'use client'

import { useState } from 'react'
import { CardTile } from '@/app/_components/card-tile'

export type Row = {
  qty: number
  condition: string
  finish: string
  cardName: string
  storageKey: string | null
}

export type Group = { name: string; isHolder: boolean; rows: Row[] }

/**
 * Client-side search, not a query param -- the whole collection is already
 * on the page (it's the caller's own data, not the ~4,900-edition catalog),
 * so filtering it again round-trip to the server would just be slower for
 * no reason. Location grouping (10) stays intact under the filter: a group
 * with nothing matching just doesn't render, rather than flattening
 * everything into one list the way the old app's ungrouped view did.
 */
export function CollectionGrid({ groups }: { groups: Group[] }) {
  const [query, setQuery] = useState('')
  const q = query.trim().toLowerCase()

  return (
    <div className="flex flex-col gap-8">
      <input
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        placeholder="Search your collection…"
        aria-label="Search your collection"
        className="rounded-md border border-slate-700 bg-slate-800 px-3 py-2 text-sm text-slate-100 outline-none focus:border-accent"
      />

      {groups.map((group) => {
        const rows = q ? group.rows.filter((r) => r.cardName.toLowerCase().includes(q)) : group.rows
        if (rows.length === 0) return null

        return (
          <section key={group.name}>
            <h2 className="flex items-baseline gap-2 text-sm font-semibold">
              {group.name}
              {group.isHolder && (
                <span className="rounded bg-amber-100 px-1.5 py-0.5 text-xs font-normal text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                  with someone else
                </span>
              )}
              <span className="ml-auto text-xs font-normal text-slate-400">
                {rows.reduce((n, r) => n + r.qty, 0)} cards
              </span>
            </h2>
            <div className="mt-2 grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6">
              {rows.map((row, i) => (
                <CardTile key={i} storageKey={row.storageKey} alt={row.cardName}>
                  <p className="truncate text-sm font-medium">{row.cardName}</p>
                  <p className="text-xs text-slate-400">
                    {row.finish === 'FOIL' ? 'Foil' : 'Nonfoil'} · {row.condition}
                  </p>
                  <span className="mt-auto inline-flex h-8 items-center justify-center rounded-md border border-cyan-500 text-xs font-medium text-cyan-400">
                    Total: {row.qty}
                  </span>
                </CardTile>
              ))}
            </div>
          </section>
        )
      })}
    </div>
  )
}
