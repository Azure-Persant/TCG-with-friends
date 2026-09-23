'use client'

import { useState, useTransition } from 'react'
import Link from 'next/link'
import { createLocation, deleteLocation, renameLocation } from './actions'

type Location = { id: string; name: string | null; cards: number }

export function NewLocation() {
  const [name, setName] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [pending, start] = useTransition()

  function submit(e: React.FormEvent) {
    e.preventDefault()
    setError(null)
    const fd = new FormData()
    fd.set('name', name)
    start(async () => {
      const r = await createLocation(fd)
      if (r.ok) setName('')
      else setError(r.error)
    })
  }

  return (
    <form onSubmit={submit} className="flex flex-col gap-2">
      <div className="flex gap-2">
        <input
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="Deck box"
          aria-label="Name of the new box"
          className="flex-1 rounded-md border border-slate-700 bg-slate-800 px-3 py-2 text-sm text-slate-100 outline-none focus:border-accent"
        />
        <button
          type="submit"
          disabled={pending || !name.trim()}
          className="rounded-md bg-accent px-3 py-2 text-sm font-medium text-white transition hover:opacity-90 disabled:opacity-50"
        >
          Add
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

export function LocationList({ locations }: { locations: Location[] }) {
  if (locations.length === 0) {
    return (
      <div className="rounded-lg border border-dashed border-white/20 p-8 text-center">
        <p className="font-medium">No boxes yet</p>
        <p className="mt-1 text-sm text-slate-400">
          Add one above. You need at least one before you can add cards.
        </p>
      </div>
    )
  }

  return (
    <ul className="divide-y divide-white/10">
      {locations.map((l) => (
        <LocationRow key={l.id} location={l} />
      ))}
    </ul>
  )
}

function LocationRow({ location }: { location: Location }) {
  const [editing, setEditing] = useState(false)
  const [name, setName] = useState(location.name ?? '')
  const [error, setError] = useState<string | null>(null)
  const [pending, start] = useTransition()

  function run(action: (fd: FormData) => Promise<{ ok: boolean; error?: string }>, fd: FormData) {
    setError(null)
    start(async () => {
      const r = await action(fd)
      if (r.ok) setEditing(false)
      else setError(r.error ?? 'Something went wrong')
    })
  }

  return (
    <li className="py-3">
      {editing ? (
        <form
          onSubmit={(e) => {
            e.preventDefault()
            const fd = new FormData()
            fd.set('id', location.id)
            fd.set('name', name)
            run(renameLocation, fd)
          }}
          className="flex gap-2"
        >
          <input
            value={name}
            onChange={(e) => setName(e.target.value)}
            autoFocus
            aria-label="New name"
            className="flex-1 rounded-md border border-slate-700 bg-slate-800 px-3 py-1.5 text-sm text-slate-100"
          />
          <button
            type="submit"
            disabled={pending}
            className="rounded-md bg-accent px-3 py-1.5 text-sm text-white transition hover:opacity-90 disabled:opacity-50"
          >
            Save
          </button>
          <button
            type="button"
            onClick={() => {
              setEditing(false)
              setName(location.name ?? '')
              setError(null)
            }}
            className="rounded-md border border-slate-700 px-3 py-1.5 text-sm text-slate-300"
          >
            Cancel
          </button>
        </form>
      ) : (
        <div className="flex items-center gap-3">
          <Link
            href={`/locations/${location.id}`}
            className="flex-1 text-sm font-medium hover:underline"
          >
            {location.name ?? 'Unnamed'}
          </Link>
          <span className="text-xs text-slate-400">
            {location.cards === 0 ? 'empty' : `${location.cards} card${location.cards === 1 ? '' : 's'}`}
          </span>
          <button
            onClick={() => setEditing(true)}
            className="text-sm text-slate-400 hover:underline"
          >
            Rename
          </button>
          <button
            onClick={() => {
              const fd = new FormData()
              fd.set('id', location.id)
              run(deleteLocation, fd)
            }}
            disabled={pending}
            className="text-sm text-slate-400 hover:underline disabled:opacity-50"
          >
            Delete
          </button>
        </div>
      )}
      {error && (
        <p role="alert" className="mt-1.5 text-sm text-red-400">
          {error}
        </p>
      )}
    </li>
  )
}
