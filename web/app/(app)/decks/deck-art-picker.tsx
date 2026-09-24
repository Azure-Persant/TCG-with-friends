'use client'

import Image from 'next/image'
import { useEffect, useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { cardImageUrl } from '@/lib/images'
import { setDeckCover } from './actions'

type Option = {
  id: string
  collector_number: string | null
  card: { name: string } | null
  card_set: { prefix: string } | null
  card_image: { storage_key: string; variant: string }[] | null
}

type Group = { name: string; options: Option[] }

/**
 * Choose which printing's art represents a deck (#32). Options are every
 * printing of every card in the deck -- picking between alternate arts of
 * one card is as much the point as picking between cards -- matching the
 * rule app_set_deck_cover enforces.
 *
 * Loaded when opened, not with the page: a deck of 30 names has a few
 * hundred printings, and most visits to /decks never open this.
 */
export function DeckArtPicker({
  deckId,
  currentEditionId,
  className,
  children,
}: {
  deckId: string
  currentEditionId: string | null
  className?: string
  children: React.ReactNode
}) {
  const [open, setOpen] = useState(false)

  return (
    <>
      <button type="button" onClick={() => setOpen(true)} className={className} title="Choose deck art">
        {children}
      </button>
      {open && (
        <PickerDialog deckId={deckId} currentEditionId={currentEditionId} onClose={() => setOpen(false)} />
      )}
    </>
  )
}

function PickerDialog({
  deckId,
  currentEditionId,
  onClose,
}: {
  deckId: string
  currentEditionId: string | null
  onClose: () => void
}) {
  const router = useRouter()
  const [groups, setGroups] = useState<Group[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState<string | null>(null)
  const [, start] = useTransition()

  useEffect(() => {
    const supabase = createClient()
    let cancelled = false

    ;(async () => {
      const { data: inDeck, error: deckError } = await supabase
        .from('deck_card')
        .select('card_edition ( card_id )')
        .eq('deck_id', deckId)
        .returns<{ card_edition: { card_id: string } | null }[]>()
      if (cancelled) return
      if (deckError) return setError(deckError.message)

      const cardIds = [...new Set((inDeck ?? []).map((r) => r.card_edition?.card_id).filter(Boolean))] as string[]
      if (cardIds.length === 0) return setGroups([])

      const { data: printings, error: printingsError } = await supabase
        .from('card_edition')
        .select('id, collector_number, card ( name ), card_set ( prefix ), card_image ( storage_key, variant )')
        .in('card_id', cardIds)
        .order('collector_number')
        .returns<Option[]>()
      if (cancelled) return
      if (printingsError) return setError(printingsError.message)

      const byName = new Map<string, Option[]>()
      for (const p of printings ?? []) {
        const name = p.card?.name ?? 'Unknown card'
        byName.set(name, [...(byName.get(name) ?? []), p])
      }
      setGroups(
        [...byName.entries()]
          .sort(([a], [b]) => a.localeCompare(b))
          .map(([name, options]) => ({ name, options })),
      )
    })()

    return () => {
      cancelled = true
    }
  }, [deckId])

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  function choose(editionId: string | null) {
    setSaving(editionId ?? 'none')
    setError(null)
    const fd = new FormData()
    fd.set('deckId', deckId)
    if (editionId) fd.set('editionId', editionId)
    start(async () => {
      const r = await setDeckCover(fd)
      setSaving(null)
      if (!r.ok) return setError(r.error)
      router.refresh()
      onClose()
    })
  }

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="Choose the deck art"
      onClick={onClose}
      className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/80 p-4 py-10"
    >
      <div onClick={(e) => e.stopPropagation()} className="panel-solid w-full max-w-4xl p-5 text-slate-100">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h2 className="font-heading text-2xl font-bold text-white">Choose the deck art</h2>
            <p className="mt-1 text-sm text-slate-400">
              Every printing of every card in this deck, so alternate arts are here too.
            </p>
          </div>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close"
            className="shrink-0 rounded-md px-2 py-1 text-slate-400 hover:bg-white/10 hover:text-white"
          >
            ✕
          </button>
        </div>

        {error && <p className="mt-4 text-sm text-red-400">{error}</p>}

        {groups === null && !error && <p className="mt-6 text-sm text-slate-400">Loading…</p>}

        {groups?.length === 0 && (
          <p className="mt-6 text-sm text-slate-400">
            Add cards to the deck first — the art comes from the cards in it.
          </p>
        )}

        {groups && groups.length > 0 && (
          <div className="mt-5 flex flex-col gap-6">
            <button
              type="button"
              onClick={() => choose(null)}
              disabled={saving !== null || currentEditionId === null}
              className="self-start rounded-md border border-slate-600 px-3 py-1.5 text-sm text-slate-200 hover:bg-white/10 disabled:opacity-50"
            >
              Use no art
            </button>

            {groups.map((g) => (
              <section key={g.name}>
                <h3 className="mb-2 flex items-baseline gap-2 font-semibold text-white">
                  {g.name}
                  <span className="text-xs font-normal text-slate-500">
                    {g.options.length} printing{g.options.length === 1 ? '' : 's'}
                  </span>
                </h3>
                <div className="grid grid-cols-3 gap-3 sm:grid-cols-4 md:grid-cols-6">
                  {g.options.map((o) => {
                    const key = o.card_image?.find((i) => i.variant === 'original')?.storage_key
                    const selected = o.id === currentEditionId
                    return (
                      <button
                        key={o.id}
                        type="button"
                        onClick={() => choose(o.id)}
                        disabled={saving !== null || !key}
                        aria-pressed={selected}
                        className={`relative overflow-hidden rounded-lg border-2 text-left transition-colors disabled:cursor-default ${
                          selected ? 'border-cyan-400' : 'border-transparent hover:border-cyan-500/60'
                        }`}
                      >
                        <span className="relative block aspect-[2.5/3.5] bg-slate-800">
                          {key ? (
                            <Image src={cardImageUrl(key)} alt={g.name} fill sizes="160px" className="object-cover" />
                          ) : (
                            <span className="absolute inset-0 flex items-center justify-center p-1 text-center text-[10px] text-slate-500">
                              no image
                            </span>
                          )}
                          {saving === o.id && (
                            <span className="absolute inset-0 flex items-center justify-center bg-slate-950/60 text-xs">
                              Saving…
                            </span>
                          )}
                        </span>
                        <span className="block px-1.5 py-1 text-[11px] leading-tight text-slate-400">
                          {o.card_set?.prefix ?? '???'} {o.collector_number}
                          {selected ? ' · current' : ''}
                        </span>
                      </button>
                    )
                  })}
                </div>
              </section>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}
