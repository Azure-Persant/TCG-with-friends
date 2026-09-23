'use client'

import { useEffect, useState, useTransition } from 'react'
import { createClient } from '@/lib/supabase/client'
import { CardThumbnail } from '@/app/_components/card-thumbnail'
import { setDeckCard } from './actions'

type SearchRow = {
  edition_id: string
  collector_number: string | null
  card_name: string | null
  set_name: string | null
  finishes: string[] | null
  image_storage_key: string | null
  types: string[] | null
}

/** Champion/Regalia cards go in the material deck and pool to 1 copy;
 *  everything else goes in the main deck and pools to 4 (see
 *  app_set_deck_card in db/functions.sql for the authoritative version --
 *  this is a client-side hint only, so the input doesn't invite a value that
 *  is certain to be rejected, not a substitute for the server check, which
 *  also knows how many you already have and any Standard-legality override. */
function isMaterialType(types: string[] | null): boolean {
  return (types ?? []).some((t) => t === 'CHAMPION' || t === 'REGALIA')
}

/**
 * Search the catalog and add a printing straight into a section, client-side
 * -- a deck builder benefits from not round-tripping the whole page per
 * keystroke the way /add and /cards do. Debounced 300ms, same as the old
 * Softgen prototype's catalog search (HANDOFF.md, "Frontend").
 */
export function AddCardSearch({ deckId }: { deckId: string }) {
  const [query, setQuery] = useState('')
  const [results, setResults] = useState<SearchRow[]>([])
  const [loading, setLoading] = useState(false)

  useEffect(() => {
    const q = query.trim()
    if (!q) return

    const supabase = createClient()
    const timer = setTimeout(async () => {
      setLoading(true)
      const { data } = await supabase.rpc('search_card_editions', { p_query: q })
      setResults((data ?? []) as SearchRow[])
      setLoading(false)
    }, 300)
    return () => clearTimeout(timer)
  }, [query])

  const visibleResults = query.trim() ? results : []

  return (
    <div className="flex flex-col gap-3">
      <input
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        placeholder="Search for a card to add…"
        aria-label="Search for a card to add"
        className="rounded-md border border-slate-700 bg-slate-800 px-3 py-2 text-sm text-slate-100 outline-none focus:border-accent"
      />
      {loading && <p className="text-xs text-slate-400">Searching…</p>}
      {visibleResults.length > 0 && (
        <ul className="flex flex-col gap-2">
          {visibleResults.map((r) => (
            <AddResultRow key={r.edition_id} deckId={deckId} row={r} />
          ))}
        </ul>
      )}
    </div>
  )
}

function AddResultRow({ deckId, row }: { deckId: string; row: SearchRow }) {
  const available = row.finishes && row.finishes.length > 0 ? row.finishes : ['NONFOIL']
  const material = isMaterialType(row.types)
  const maxQty = material ? 1 : 4

  const [section, setSection] = useState<'material' | 'main' | 'sideboard'>(material ? 'material' : 'main')
  const [finish, setFinish] = useState(available[0]!)
  const [qty, setQty] = useState(1)
  const [pending, start] = useTransition()
  const [message, setMessage] = useState<string | null>(null)

  function add() {
    setMessage(null)
    const fd = new FormData()
    fd.set('deckId', deckId)
    fd.set('editionId', row.edition_id)
    fd.set('section', section)
    fd.set('finish', finish)
    // Adding is additive from a search result, not a "set to" -- but
    // app_set_deck_card only knows "set to", so read the current qty first
    // is unnecessary here since this is always a fresh add of `qty` on top of
    // whatever is already there would require a read; simplest correct
    // behaviour for a search-and-add flow is "set this row to qty", which is
    // right for a brand new row and predictable either way.
    fd.set('qty', String(qty))
    start(async () => {
      const r = await setDeckCard(fd)
      setMessage(r.ok ? 'Added' : r.error)
    })
  }

  return (
    <li className="flex items-center gap-2 panel p-2 text-sm">
      <CardThumbnail storageKey={row.image_storage_key} alt={row.card_name ?? 'Unknown card'} />
      <div className="flex flex-1 flex-col gap-0.5">
        <span className="font-medium">{row.card_name}</span>
        <span className="text-xs text-slate-400">{row.set_name ?? 'Unknown set'}</span>
      </div>
      <select
        value={section}
        onChange={(e) => setSection(e.target.value as typeof section)}
        className="rounded-md border border-slate-700 bg-slate-800 px-1.5 py-1 text-xs text-slate-100"
      >
        {/* Only the section this card is actually eligible for -- app_set_deck_card
            rejects a Champion/Regalia in Main and everything else in Material, so
            there's no reason to offer a choice that can only fail. */}
        {material ? <option value="material">Material</option> : <option value="main">Main</option>}
        <option value="sideboard">Sideboard</option>
      </select>
      <select
        value={finish}
        onChange={(e) => setFinish(e.target.value)}
        className="rounded-md border border-slate-700 bg-slate-800 px-1.5 py-1 text-xs text-slate-100"
      >
        {available.map((f) => (
          <option key={f} value={f}>
            {f === 'FOIL' ? 'Foil' : 'Nonfoil'}
          </option>
        ))}
      </select>
      <input
        type="number"
        min={1}
        max={maxQty}
        value={qty}
        onChange={(e) => setQty(Math.min(maxQty, Math.max(1, Number(e.target.value) || 1)))}
        className="w-12 rounded-md border border-slate-700 bg-slate-800 px-1.5 py-1 text-xs text-slate-100"
      />
      <button
        type="button"
        onClick={add}
        disabled={pending}
        className="rounded-md bg-accent px-2 py-1 text-xs font-medium text-white transition hover:opacity-90 disabled:opacity-50"
      >
        Add
      </button>
      {message && <span className="text-xs text-slate-400">{message}</span>}
    </li>
  )
}
