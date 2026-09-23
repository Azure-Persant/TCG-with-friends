'use client'

import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import Link from 'next/link'
import { createDeck, deleteDeck } from './actions'

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

type Deck = { id: string; name: string; updated_at: string }

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
    <ul className="flex flex-col gap-2">
      {decks.map((d) => (
        <DeckRow key={d.id} deck={d} />
      ))}
    </ul>
  )
}

function DeckRow({ deck }: { deck: Deck }) {
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

  return (
    <li className="flex items-center justify-between panel p-4">
      <Link href={`/decks/${deck.id}`} className="font-medium hover:text-accent hover:underline">
        {deck.name}
      </Link>
      <div className="flex items-center gap-3">
        {error && <span className="text-xs text-red-400">{error}</span>}
        <button
          type="button"
          onClick={remove}
          disabled={pending}
          className="text-sm text-slate-400 hover:text-red-400 disabled:opacity-50"
        >
          Delete
        </button>
      </div>
    </li>
  )
}
