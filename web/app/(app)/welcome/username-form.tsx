'use client'

import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { setUsername } from './actions'

export function UsernameForm({ suggestion }: { suggestion: string }) {
  const router = useRouter()
  const [value, setValue] = useState(suggestion)
  const [error, setError] = useState<string | null>(null)
  const [pending, start] = useTransition()

  // Mirrors the database's CHECK, so the button is not offered for something
  // that cannot succeed. The database remains the authority.
  const looksValid = /^[A-Za-z0-9][A-Za-z0-9_-]{2,19}$/.test(value)

  function submit(e: React.FormEvent) {
    e.preventDefault()
    setError(null)
    const fd = new FormData()
    fd.set('username', value)
    start(async () => {
      const r = await setUsername(fd)
      if (r.ok) {
        router.refresh()
        router.push('/collection')
      } else {
        setError(r.error)
      }
    })
  }

  return (
    <form onSubmit={submit} className="flex flex-col gap-3">
      <label htmlFor="username" className="text-sm font-medium">
        Username
      </label>
      <input
        id="username"
        value={value}
        onChange={(e) => setValue(e.target.value)}
        autoFocus
        autoComplete="off"
        placeholder="jon"
        className="rounded-md border border-slate-700 bg-slate-800 px-3 py-2 text-sm text-slate-100 outline-none focus:border-accent"
      />
      <p className="text-xs text-slate-400">
        3–20 characters. Letters, numbers, hyphens and underscores. Not case-sensitive, so{' '}
        <span className="font-medium">Jon</span> and <span className="font-medium">jon</span> are
        the same name.
      </p>
      <button
        type="submit"
        disabled={pending || !looksValid}
        className="rounded-md bg-accent px-3 py-2 text-sm font-medium text-white transition hover:opacity-90 disabled:opacity-50"
      >
        {pending ? 'Claiming…' : 'Continue'}
      </button>
      {error && (
        <p role="alert" className="text-sm text-red-400">
          {error}
        </p>
      )}
    </form>
  )
}
