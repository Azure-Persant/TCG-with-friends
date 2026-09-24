'use client'

import { useState, useTransition } from 'react'
import { CardTile } from '@/app/_components/card-tile'
import { EditHolding } from './edit-holding'
import { moveHolding } from './actions'

export type Row = {
  editionId: string
  locationId: string
  qty: number
  condition: string
  finish: string
  cardName: string
  storageKey: string | null
  restricted: boolean
  /** Finishes this printing actually comes in -- a nonfoil-only edition
   *  should not offer switching to foil (21), same reasoning as /add. */
  availableFinishes: string[]
}

export type Group = { name: string; isHolder: boolean; rows: Row[] }

/** A stable identity for a row across renders -- used both as the React key
 *  and as the selection-set key, since array index is neither (filtering by
 *  search changes which index a row sits at). */
function rowKey(row: Row): string {
  return `${row.editionId}:${row.locationId}:${row.finish}:${row.condition}`
}

/**
 * Client-side search, not a query param -- the whole collection is already
 * on the page (it's the caller's own data, not the ~4,900-edition catalog),
 * so filtering it again round-trip to the server would just be slower for
 * no reason. Location grouping (10) stays intact under the filter: a group
 * with nothing matching just doesn't render, rather than flattening
 * everything into one list the way the old app's ungrouped view did.
 */
export function CollectionGrid({
  groups,
  locations,
}: {
  groups: Group[]
  locations: { id: string; name: string | null }[]
}) {
  const [query, setQuery] = useState('')
  const q = query.trim().toLowerCase()

  // Bulk select-and-move (30) -- reuses app_move_cards per selected row,
  // called once per row from the client rather than needing a new bulk RPC.
  const [selecting, setSelecting] = useState(false)
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [target, setTarget] = useState(locations[0]?.id ?? '')
  const [pending, start] = useTransition()
  const [error, setError] = useState<string | null>(null)

  // A row keyed by its own current identity, so a move that changes a row's
  // location_id can't leave a stale entry selected under its old key.
  const byKey = new Map<string, Row>()
  for (const group of groups) for (const row of group.rows) byKey.set(rowKey(row), row)

  function toggleSelecting() {
    setSelecting((s) => !s)
    setSelected(new Set())
    setError(null)
  }

  function toggle(key: string) {
    setSelected((prev) => {
      const next = new Set(prev)
      if (next.has(key)) next.delete(key)
      else next.add(key)
      return next
    })
  }

  function moveSelected() {
    if (!target || selected.size === 0) return
    setError(null)

    const rows = [...selected].map((k) => byKey.get(k)).filter((r): r is Row => !!r)
    // Already in the target box -- nothing to move, and app_move_cards
    // rejects "source and destination are the same" outright.
    const toMove = rows.filter((r) => r.locationId !== target)

    start(async () => {
      const results = await Promise.all(
        toMove.map((row) => {
          const fd = new FormData()
          fd.set('editionId', row.editionId)
          fd.set('finish', row.finish)
          fd.set('condition', row.condition)
          fd.set('fromLocationId', row.locationId)
          fd.set('toLocationId', target)
          fd.set('qty', String(row.qty))
          return moveHolding(fd)
        }),
      )

      const failed = results.filter((r) => !r.ok).length
      if (failed > 0) {
        setError(`${failed} of ${toMove.length} card${toMove.length === 1 ? '' : 's'} could not be moved`)
      } else {
        setSelected(new Set())
        setSelecting(false)
      }
    })
  }

  return (
    <div className="flex flex-col gap-8">
      <div className="flex flex-wrap items-center gap-2">
        <input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search your collection…"
          aria-label="Search your collection"
          className="flex-1 rounded-md border border-slate-700 bg-slate-800 px-3 py-2 text-sm text-slate-100 outline-none focus:border-accent"
        />
        {locations.length > 1 && (
          <button
            type="button"
            onClick={toggleSelecting}
            className="rounded-md border border-slate-700 px-3 py-2 text-sm text-slate-300 hover:bg-white/10"
          >
            {selecting ? 'Cancel select' : 'Select'}
          </button>
        )}
      </div>

      {selecting && (
        <div className="flex flex-wrap items-center gap-2 panel p-3 text-sm">
          <span className="text-slate-300">
            {selected.size} selected
          </span>
          <select
            value={target}
            onChange={(e) => setTarget(e.target.value)}
            aria-label="Move to"
            className="rounded-md border border-slate-700 bg-slate-800 px-2 py-1 text-sm text-slate-100"
          >
            {locations.map((l) => (
              <option key={l.id} value={l.id}>
                {l.name ?? 'Unnamed'}
              </option>
            ))}
          </select>
          <button
            type="button"
            onClick={moveSelected}
            disabled={pending || selected.size === 0}
            className="rounded-md bg-accent px-3 py-1.5 text-sm font-medium text-white transition hover:opacity-90 disabled:opacity-50"
          >
            {pending ? 'Moving…' : 'Move'}
          </button>
          {error && <span className="text-red-400">{error}</span>}
        </div>
      )}

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
              {rows.map((row) => {
                const key = rowKey(row)
                return (
                  <CardTile
                    key={key}
                    storageKey={row.storageKey}
                    alt={row.cardName}
                    foil={row.finish === 'FOIL'}
                    restricted={row.restricted}
                  >
                    {selecting && !group.isHolder && (
                      <label className="flex items-center gap-1.5 text-xs text-slate-300">
                        <input
                          type="checkbox"
                          checked={selected.has(key)}
                          onChange={() => toggle(key)}
                        />
                        Select
                      </label>
                    )}
                    <p className="truncate text-sm font-medium">{row.cardName}</p>
                    <p className="text-xs text-slate-400">
                      {row.finish === 'FOIL' ? 'Foil' : 'Nonfoil'} · {row.condition}
                    </p>
                    <span className="mt-auto inline-flex h-8 items-center justify-center rounded-md border border-cyan-500 text-xs font-medium text-cyan-400">
                      Total: {row.qty}
                    </span>
                    {!group.isHolder && !selecting && (
                      <EditHolding
                        editionId={row.editionId}
                        finish={row.finish}
                        locationId={row.locationId}
                        condition={row.condition}
                        qty={row.qty}
                        availableFinishes={row.availableFinishes}
                        locations={locations}
                      />
                    )}
                  </CardTile>
                )
              })}
            </div>
          </section>
        )
      })}
    </div>
  )
}
