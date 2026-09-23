'use client'

import Image from 'next/image'
import { useEffect, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import { cardImageUrl } from '@/lib/images'
import { isRestricted } from '@/lib/legality'

type Printing = {
  id: string
  collector_number: string | null
  rarity: number | null
  illustrator: string | null
  card_set: { name: string; prefix: string } | null
  card_edition_finish: { finish: string }[] | null
  card_image: { storage_key: string; variant: string }[] | null
}

type CardData = {
  name: string
  attributes: Record<string, unknown>
}

/** A stat that is genuinely absent (most cards have no `power`, say) is
 *  `null` from Postgres, not `0` -- distinguishing the two matters, since a
 *  0-power ally is a real, meaningful stat line. */
function stat(attributes: Record<string, unknown>, key: string): string | null {
  const v = attributes[key]
  return v === null || v === undefined ? null : String(v)
}

function list(attributes: Record<string, unknown>, key: string): string[] {
  const v = attributes[key]
  return Array.isArray(v) ? v.map(String) : []
}

/**
 * Full card text and stats (23) -- the lightbox added in #19 only enlarged
 * the art. Fetched client-side on open, not server-rendered, since it opens
 * from a click on an already-rendered grid (/cards, /add) rather than a
 * fresh page load; catalog tables are world-readable (RLS `USING (true)`),
 * so no auth is needed either.
 *
 * Also doubles as the "other printings of this card" browser the retired
 * Softgen app's dialog had -- same card_id, different card_edition rows.
 */
export function CardDetailDialog({
  editionId,
  onClose,
}: {
  /** null closes the dialog. */
  editionId: string | null
  onClose: () => void
}) {
  if (!editionId) return null
  // Keyed by editionId so switching cards mounts a fresh instance instead of
  // resetting state by hand inside an effect (the state below always starts
  // clean for the card it was created for).
  return <CardDetailDialogContent key={editionId} editionId={editionId} onClose={onClose} />
}

function CardDetailDialogContent({
  editionId,
  onClose,
}: {
  editionId: string
  onClose: () => void
}) {
  const [card, setCard] = useState<CardData | null>(null)
  const [printings, setPrintings] = useState<Printing[]>([])
  const [selectedId, setSelectedId] = useState<string | null>(editionId)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    const supabase = createClient()
    let cancelled = false

    ;(async () => {
      const { data: edition, error: editionError } = await supabase
        .from('card_edition')
        .select('card_id')
        .eq('id', editionId)
        .single()

      if (cancelled) return
      if (editionError || !edition) {
        setError(editionError?.message ?? 'That card could not be found')
        return
      }

      const [{ data: cardRow, error: cardError }, { data: siblings, error: siblingsError }] =
        await Promise.all([
          supabase.from('card').select('name, attributes').eq('id', edition.card_id).single(),
          supabase
            .from('card_edition')
            .select(
              `id, collector_number, rarity, illustrator,
               card_set ( name, prefix ),
               card_edition_finish ( finish ),
               card_image ( storage_key, variant )`,
            )
            .eq('card_id', edition.card_id)
            .order('collector_number')
            .returns<Printing[]>(),
        ])

      if (cancelled) return
      if (cardError || siblingsError) {
        setError((cardError ?? siblingsError)?.message ?? 'That card could not be loaded')
        return
      }
      setCard(cardRow)
      setPrintings(siblings ?? [])
    })()

    return () => {
      cancelled = true
    }
  }, [editionId])

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  const current = printings.find((p) => p.id === selectedId) ?? printings[0] ?? null
  const storageKey = current?.card_image?.find((i) => i.variant === 'original')?.storage_key ?? null
  const attributes = card?.attributes ?? {}
  const restricted = isRestricted(attributes)

  const stats: [string, string | null][] = [
    ['Level', stat(attributes, 'level')],
    ['Power', stat(attributes, 'power')],
    ['Life', stat(attributes, 'life')],
    ['Durability', stat(attributes, 'durability')],
    ['Speed', stat(attributes, 'speed')],
  ].filter(([, v]) => v !== null) as [string, string][]

  const costMemory = stat(attributes, 'cost_memory')
  const costReserve = stat(attributes, 'cost_reserve')
  const types = list(attributes, 'types')
  const subtypes = list(attributes, 'subtypes')
  const classes = list(attributes, 'classes')
  const element = stat(attributes, 'element')
  const effect = stat(attributes, 'effect_raw')

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label={card?.name ?? 'Card detail'}
      onClick={onClose}
      className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/80 p-4 py-10 sm:items-center"
    >
      <div
        onClick={(e) => e.stopPropagation()}
        className="panel-solid w-full max-w-3xl p-5 text-slate-100"
      >
        <div className="flex items-start justify-between gap-3">
          <div className="flex flex-wrap items-center gap-2">
            <h2 className="font-heading text-2xl font-bold text-white">
              {card?.name ?? 'Loading…'}
            </h2>
            {restricted && (
              <span className="rounded bg-red-600 px-1.5 py-0.5 text-xs font-semibold text-white">
                Restricted
              </span>
            )}
            {printings.length > 1 && (
              <span className="rounded border border-cyan-500 px-1.5 py-0.5 text-xs font-medium text-cyan-400">
                {printings.length} printings
              </span>
            )}
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

        {!error && (
          <div className="mt-4 grid grid-cols-1 gap-6 sm:grid-cols-2">
            <div className="flex flex-col gap-3">
              <div className="relative mx-auto aspect-[2.5/3.5] w-full max-w-[320px] overflow-hidden rounded-lg bg-slate-800 shadow-2xl">
                {storageKey ? (
                  <Image
                    src={cardImageUrl(storageKey)}
                    alt={card?.name ?? ''}
                    fill
                    sizes="320px"
                    className="object-cover"
                  />
                ) : (
                  <span className="absolute inset-0 flex items-center justify-center px-2 text-center text-xs text-slate-500">
                    {card?.name}
                  </span>
                )}
              </div>

              {printings.length > 1 && (
                <select
                  value={selectedId ?? ''}
                  onChange={(e) => setSelectedId(e.target.value)}
                  aria-label="Printing"
                  className="rounded-md border border-slate-700 bg-slate-800 px-2 py-1.5 text-sm text-slate-100"
                >
                  {printings.map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.card_set?.name ?? 'Unknown set'}
                      {p.collector_number ? ` · #${p.collector_number}` : ''}
                      {p.rarity ? ` · rarity ${p.rarity}` : ''}
                    </option>
                  ))}
                </select>
              )}
            </div>

            <div className="flex flex-col gap-3">
              {(costMemory || costReserve) && (
                <Field label="Cost">
                  {costMemory ? `${costMemory} Memory` : `${costReserve} Reserve`}
                </Field>
              )}
              {element && <Field label="Element">{element}</Field>}
              {types.length > 0 && <Field label="Type">{types.join(', ')}</Field>}
              {subtypes.length > 0 && <Field label="Subtype">{subtypes.join(', ')}</Field>}
              {classes.length > 0 && <Field label="Class">{classes.join(', ')}</Field>}

              {stats.length > 0 && (
                <div className="grid grid-cols-3 gap-3">
                  {stats.map(([label, value]) => (
                    <Field key={label} label={label}>
                      {value}
                    </Field>
                  ))}
                </div>
              )}

              {effect && (
                <Field label="Effect">
                  <p className="whitespace-pre-wrap text-sm font-normal leading-relaxed text-slate-200">
                    {effect}
                  </p>
                </Field>
              )}

              {current?.illustrator && (
                <Field label="Illustrator">
                  <span className="italic">{current.illustrator}</span>
                </Field>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  )
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <h3 className="text-xs font-semibold uppercase tracking-wide text-slate-400">{label}</h3>
      <div className="text-sm font-medium text-slate-100">{children}</div>
    </div>
  )
}
