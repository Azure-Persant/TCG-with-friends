'use client'

import Image from 'next/image'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import Link from 'next/link'
import { cardImageUrl } from '@/lib/images'
import { createDeck, deleteDeck } from './actions'
import { DeckArtPicker } from './deck-art-picker'

export function NewDeck() {
  const [name, setName] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [pending, start] = useTransition()
  const router = useRouter()

  function submit(e: React.FormEvent) {
    e.preventDefault()
    setError(null)
    const fd = new FormData()
    fd.set('name', name)
    start(async () => {
      const r = await createDeck(fd)
      if (r.ok) router.push(`/decks/${r.id}`)
      else setError(r.error)
    })
  }

  return (
    <form onSubmit={submit} className="flex flex-col gap-2">
      <div className="flex gap-2">
        <input
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="New deck name"
          aria-label="New deck name"
          className="flex-1 rounded-md border border-slate-700 bg-slate-800 px-3 py-2 text-sm text-slate-100 outline-none focus:border-accent"
        />
        <button
          type="submit"
          disabled={pending || !name.trim()}
          className="rounded-md bg-accent px-3 py-2 text-sm font-medium text-white transition hover:opacity-90 disabled:opacity-50"
        >
          Create
        </button>
      </div>
      {error && (
        <p role="alert" className="text-sm text-red-400">
          {error}
        </p>
      )}
    </form>
  )
}

export type Deck = {
  id: string
  name: string
  updated_at: string
  cover_edition_id: string | null
  cover: {
    card: { name: string } | null
    card_image: { storage_key: string; variant: string }[] | null
  } | null
}

export function DeckList({ decks }: { decks: Deck[] }) {
  if (decks.length === 0) {
    return (
      <div className="rounded-lg border border-dashed border-white/20 p-8 text-center">
        <p className="font-medium">No decks yet</p>
        <p className="mt-1 text-sm text-slate-400">Create one above to start building.</p>
      </div>
    )
  }

  return (
    <div className="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
      {decks.map((d) => (
        <DeckCard key={d.id} deck={d} />
      ))}
    </div>
  )
}

function DeckCard({ deck }: { deck: Deck }) {
  const [pending, start] = useTransition()
  const [error, setError] = useState<string | null>(null)

  function remove() {
    if (!confirm(`Delete "${deck.name}"? This cannot be undone.`)) return
    setError(null)
    const fd = new FormData()
    fd.set('deckId', deck.id)
    start(async () => {
      const r = await deleteDeck(fd)
      if (!r.ok) setError(r.error)
    })
  }

  const coverKey = deck.cover?.card_image?.find((i) => i.variant === 'original')?.storage_key ?? null
  const coverName = deck.cover?.card?.name ?? null

  return (
    <div className="overflow-hidden panel transition-colors hover:border-cyan-500/60">
      {/* A portrait card cropped into a landscape tile: object-[center_30%]
          keeps the illustration, which sits in roughly the top two-thirds
          of the card, rather than the rules text. The art-picker button is a
          sibling of the link, not inside it -- a button nested in an anchor
          is invalid and swallows clicks. */}
      <div className="relative aspect-video overflow-hidden bg-slate-900">
        <Link
          href={`/decks/${deck.id}`}
          aria-label={`Open ${deck.name}`}
          className="group absolute inset-0 block outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-cyan-400"
        >
          {coverKey ? (
            <Image
              src={cardImageUrl(coverKey)}
              alt=""
              fill
              sizes="(min-width: 1024px) 33vw, (min-width: 768px) 50vw, 100vw"
              className="object-cover object-[center_30%] transition-transform duration-300 group-hover:scale-[1.03]"
            />
          ) : (
            <span className="absolute inset-0 flex items-center justify-center">
              <LayersIcon className="h-10 w-10 text-slate-700" />
            </span>
          )}
          <span className="absolute inset-x-0 bottom-0 bg-gradient-to-t from-slate-900 via-slate-900/80 to-transparent p-3 pt-8">
            <span className="block truncate text-lg font-bold text-white">{deck.name}</span>
            {coverName && <span className="block truncate text-xs text-slate-400">Art: {coverName}</span>}
          </span>
        </Link>
        <DeckArtPicker
          deckId={deck.id}
          currentEditionId={deck.cover_edition_id}
          className="absolute right-2 top-2 z-10 flex h-8 w-8 items-center justify-center rounded-md bg-slate-900/80 text-slate-200 hover:bg-slate-900 hover:text-white"
        >
          <ImageIcon className="h-4 w-4" />
          <span className="sr-only">Choose deck art</span>
        </DeckArtPicker>
      </div>

      <div className="flex flex-col gap-3 p-4">
        <div className="flex items-center gap-2 text-sm text-slate-500">
          <CalendarIcon className="h-4 w-4" />
          {new Date(deck.updated_at).toLocaleDateString()}
        </div>

        {error && <p className="text-xs text-red-400">{error}</p>}

        <div className="flex gap-2">
          <Link
            href={`/decks/${deck.id}`}
            className="flex flex-1 items-center justify-center gap-2 rounded-md bg-accent px-3 py-2 text-sm font-medium text-white transition hover:opacity-90"
          >
            <PencilIcon className="h-4 w-4" />
            Edit
          </Link>
          <button
            type="button"
            onClick={remove}
            disabled={pending}
            title={`Delete ${deck.name}`}
            className="rounded-md border border-slate-600 px-3 py-2 text-slate-300 transition hover:border-red-500/60 hover:bg-red-950 hover:text-red-300 disabled:opacity-50"
          >
            <TrashIcon className="h-4 w-4" />
          </button>
        </div>
      </div>
    </div>
  )
}

function LayersIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden>
      <polygon points="12 2 2 7 12 12 22 7 12 2" />
      <polyline points="2 17 12 22 22 17" />
      <polyline points="2 12 12 17 22 12" />
    </svg>
  )
}

function ImageIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden>
      <rect x="3" y="3" width="18" height="18" rx="2" />
      <circle cx="9" cy="9" r="2" />
      <path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21" />
    </svg>
  )
}

function CalendarIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden>
      <rect x="3" y="4" width="18" height="18" rx="2" />
      <line x1="16" y1="2" x2="16" y2="6" />
      <line x1="8" y1="2" x2="8" y2="6" />
      <line x1="3" y1="10" x2="21" y2="10" />
    </svg>
  )
}

function PencilIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden>
      <path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7" />
      <path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4Z" />
    </svg>
  )
}

function TrashIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden>
      <polyline points="3 6 5 6 21 6" />
      <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" />
    </svg>
  )
}
