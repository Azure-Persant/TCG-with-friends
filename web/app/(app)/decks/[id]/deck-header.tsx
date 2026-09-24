'use client'

import { useState, useTransition } from 'react'
import { renameDeck } from './actions'
import { DeckArtPicker } from '../deck-art-picker'

type Summary = {
  material_count: number
  main_count: number
  sideboard_count: number
  sideboard_points: number
  has_level0_champion: boolean
  is_legal: boolean
}

export function DeckHeader({
  deckId,
  name,
  coverEditionId,
  summary,
  missingTotal,
}: {
  deckId: string
  name: string
  coverEditionId: string | null
  summary: Summary
  missingTotal: number
}) {
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
      <div className="flex gap-2">
        <input
          value={value}
          onChange={(e) => setValue(e.target.value)}
          onBlur={save}
          disabled={pending}
          aria-label="Deck name"
          className="min-w-0 flex-1 rounded-md border border-slate-700 bg-slate-800 px-3 py-2 font-heading text-2xl font-bold tracking-tight text-white outline-none focus:border-accent disabled:opacity-50"
        />
        <DeckArtPicker
          deckId={deckId}
          currentEditionId={coverEditionId}
          className="shrink-0 rounded-md border border-slate-700 px-3 text-sm text-slate-300 hover:bg-white/10"
        >
          Choose art
        </DeckArtPicker>
      </div>
      {error && <p className="text-sm text-red-400">{error}</p>}

      <div className="panel-solid flex flex-wrap items-center gap-x-8 gap-y-3 p-4">
        <Stat label="Material Deck" value={summary.material_count} target="12" ok />
        <Stat label="Main Deck" value={summary.main_count} target="min 60" ok={summary.main_count >= 60} />
        <div>
          <p className="text-xs tracking-wide text-slate-500 uppercase">Sideboard</p>
          <p className="text-xl font-bold text-white">
            {summary.sideboard_count}
            <span className="text-sm font-normal text-slate-500"> / 15 cards</span>
          </p>
          <p className="text-xs text-slate-500">{summary.sideboard_points} / 15 points</p>
        </div>

        <div className="hidden h-10 w-px bg-slate-700 sm:block" />

        <div>
          <p className="text-xs tracking-wide text-slate-500 uppercase">Missing from Inventory</p>
          <p className={`text-xl font-bold ${missingTotal > 0 ? 'text-amber-400' : 'text-green-400'}`}>
            {missingTotal}
          </p>
        </div>

        <div className="ml-auto">
          {summary.is_legal ? (
            <span className="inline-flex items-center gap-1 rounded-full bg-green-600/20 px-2.5 py-1 text-sm font-medium text-green-300">
              Deck is legal
            </span>
          ) : (
            <span
              className="inline-flex cursor-help items-center gap-1 rounded-full bg-amber-500/20 px-2.5 py-1 text-sm font-medium text-amber-300"
              title={issues.join('; ')}
            >
              {issues.length} rule issue{issues.length === 1 ? '' : 's'}
            </span>
          )}
        </div>
      </div>
    </div>
  )
}

function Stat({ label, value, target, ok }: { label: string; value: number; target: string; ok: boolean }) {
  return (
    <div>
      <p className="text-xs tracking-wide text-slate-500 uppercase">{label}</p>
      <p className={`text-xl font-bold ${ok ? 'text-white' : 'text-amber-400'}`}>
        {value}
        <span className="text-sm font-normal text-slate-500"> / {target}</span>
      </p>
    </div>
  )
}
