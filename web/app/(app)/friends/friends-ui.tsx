'use client'

import { useState, useTransition } from 'react'
import {
  cancelRequest,
  findAccount,
  sendFriendRequest,
  setGameShare,
  unfriend,
  type Found,
} from './actions'

export function AddFriend() {
  const [query, setQuery] = useState('')
  const [found, setFound] = useState<Found | null | undefined>(undefined)
  const [error, setError] = useState<string | null>(null)
  const [sent, setSent] = useState(false)
  const [pending, start] = useTransition()

  function search(e: React.FormEvent) {
    e.preventDefault()
    setError(null)
    setSent(false)
    const fd = new FormData()
    fd.set('query', query)
    start(async () => {
      const r = await findAccount(fd)
      if (r.ok) setFound(r.data ?? null)
      else {
        setFound(undefined)
        setError(r.error)
      }
    })
  }

  function send() {
    if (!found) return
    setError(null)
    const fd = new FormData()
    fd.set('to', found.id)
    start(async () => {
      const r = await sendFriendRequest(fd)
      if (r.ok) setSent(true)
      else setError(r.error)
    })
  }

  return (
    <div className="flex flex-col gap-3">
      <form onSubmit={search} className="flex gap-2">
        <input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="username or friend@example.com"
          aria-label="Their username or email address"
          className="flex-1 rounded-md border border-neutral-300 px-3 py-2 text-sm outline-none focus:border-neutral-900 dark:border-neutral-700 dark:bg-neutral-950 dark:focus:border-neutral-100"
        />
        <button
          type="submit"
          disabled={pending || !query.trim()}
          className="rounded-md bg-neutral-900 px-3 py-2 text-sm font-medium text-white disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900"
        >
          {pending ? 'Looking…' : 'Look up'}
        </button>
      </form>

      {found === null && (
        <p className="text-sm text-neutral-500">
          No match. Usernames and email addresses must be typed in full — searching by part of
          a name is deliberately not possible. They also need to have signed in at least once.
        </p>
      )}

      {found && (
        <div className="flex items-center gap-3 rounded-lg border border-neutral-200 p-3 dark:border-neutral-800">
          <span className="flex-1 text-sm">
            <span className="font-medium">{found.display_name}</span>
            {found.username && (
              <span className="ml-1.5 text-neutral-500">@{found.username}</span>
            )}
          </span>
          {found.is_self ? (
            <span className="text-sm text-neutral-500">That is you</span>
          ) : found.is_friend ? (
            <span className="text-sm text-neutral-500">Already friends</span>
          ) : sent || found.request_state === 'sent' ? (
            <span className="text-sm text-neutral-500">Request sent</span>
          ) : found.request_state === 'received' ? (
            <span className="text-sm text-neutral-500">
              They already asked you — check your inbox
            </span>
          ) : (
            <button
              onClick={send}
              disabled={pending}
              className="rounded-md bg-neutral-900 px-3 py-1.5 text-sm font-medium text-white disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900"
            >
              Send request
            </button>
          )}
        </div>
      )}

      {error && (
        <p role="alert" className="text-sm text-red-600">
          {error}
        </p>
      )}
    </div>
  )
}

export function FriendRow({ id, name }: { id: string; name: string }) {
  const [error, setError] = useState<string | null>(null)
  const [pending, start] = useTransition()

  return (
    <li className="py-3">
      <div className="flex items-center gap-3">
        <span className="flex-1 text-sm font-medium">{name}</span>
        <button
          onClick={() => {
            setError(null)
            const fd = new FormData()
            fd.set('other', id)
            start(async () => {
              const r = await unfriend(fd)
              if (!r.ok) setError(r.error)
            })
          }}
          disabled={pending}
          className="text-sm text-neutral-500 hover:underline disabled:opacity-50"
        >
          Unfriend
        </button>
      </div>
      {/* app_unfriend refuses while cards are outstanding (5) and its message
          says how many and what to do, so it is shown verbatim. */}
      {error && (
        <p role="alert" className="mt-1.5 text-sm text-red-600">
          {error}
        </p>
      )}
    </li>
  )
}

export function OutgoingRow({ id, name }: { id: string; name: string }) {
  const [error, setError] = useState<string | null>(null)
  const [pending, start] = useTransition()

  return (
    <li className="py-3">
      <div className="flex items-center gap-3">
        <span className="flex-1 text-sm">
          <span className="font-medium">{name}</span>
          <span className="text-neutral-500"> hasn&apos;t answered yet</span>
        </span>
        <button
          onClick={() => {
            setError(null)
            const fd = new FormData()
            fd.set('requestId', id)
            start(async () => {
              const r = await cancelRequest(fd)
              if (!r.ok) setError(r.error)
            })
          }}
          disabled={pending}
          className="text-sm text-neutral-500 hover:underline disabled:opacity-50"
        >
          Withdraw
        </button>
      </div>
      {error && (
        <p role="alert" className="mt-1.5 text-sm text-red-600">
          {error}
        </p>
      )}
    </li>
  )
}

export function GameShares({
  games,
  shared,
}: {
  games: { id: string; name: string }[]
  shared: string[]
}) {
  const [on, setOn] = useState<Set<string>>(new Set(shared))
  const [error, setError] = useState<string | null>(null)
  const [pending, start] = useTransition()

  if (games.length === 0) {
    return <p className="text-sm text-neutral-500">No games in the catalog yet.</p>
  }

  function toggle(gameId: string, next: boolean) {
    setError(null)
    // Optimistic: the checkbox should move under the finger, not half a second
    // later. Rolled back below if the write fails.
    setOn((prev) => {
      const copy = new Set(prev)
      if (next) copy.add(gameId)
      else copy.delete(gameId)
      return copy
    })

    const fd = new FormData()
    fd.set('gameId', gameId)
    fd.set('share', String(next))

    start(async () => {
      const r = await setGameShare(fd)
      if (!r.ok) {
        setError(r.error)
        setOn((prev) => {
          const copy = new Set(prev)
          if (next) copy.delete(gameId)
          else copy.add(gameId)
          return copy
        })
      }
    })
  }

  return (
    <div className="flex flex-col gap-2">
      {games.map((g) => (
        <label key={g.id} className="flex items-center gap-2 text-sm">
          <input
            type="checkbox"
            checked={on.has(g.id)}
            disabled={pending}
            onChange={(e) => toggle(g.id, e.target.checked)}
            className="h-4 w-4"
          />
          <span>{g.name}</span>
          {!on.has(g.id) && (
            <span className="text-xs text-neutral-500">— friends see none of these</span>
          )}
        </label>
      ))}
      {error && (
        <p role="alert" className="text-sm text-red-600">
          {error}
        </p>
      )}
    </div>
  )
}
