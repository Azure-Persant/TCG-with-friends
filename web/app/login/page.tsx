'use client'

import { useState } from 'react'
import { createClient } from '@/lib/supabase/client'

/**
 * Magic-link sign in.
 *
 * No passwords, deliberately. Passwords mean reset flows, strength rules and
 * a credential worth stealing; for a small group of friends a link in an
 * inbox is both simpler to build and harder to get wrong.
 */
export default function LoginPage() {
  const [email, setEmail] = useState('')
  const [sent, setSent] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function signIn(e: React.FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)

    const supabase = createClient()
    const next = new URLSearchParams(window.location.search).get('next') ?? '/collection'

    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: {
        emailRedirectTo: `${window.location.origin}/auth/confirm?next=${encodeURIComponent(next)}`,
      },
    })

    setBusy(false)
    if (error) setError(error.message)
    else setSent(true)
  }

  return (
    <main className="mx-auto flex min-h-dvh max-w-md flex-col justify-center px-6">
      <h1 className="text-2xl font-semibold tracking-tight">Card inventory</h1>
      <p className="mt-2 text-sm text-neutral-500">
        Keep track of what you own, what you have lent out, and who still has it.
      </p>

      {sent ? (
        <div className="mt-8 rounded-lg border border-neutral-200 p-4 text-sm dark:border-neutral-800">
          <p className="font-medium">Check your email</p>
          <p className="mt-1 text-neutral-500">
            We sent a sign-in link to <span className="font-medium">{email}</span>. It expires in
            an hour.
          </p>
        </div>
      ) : (
        <form onSubmit={signIn} className="mt-8 flex flex-col gap-3">
          <label htmlFor="email" className="text-sm font-medium">
            Email
          </label>
          <input
            id="email"
            type="email"
            required
            autoComplete="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            placeholder="you@example.com"
            className="rounded-md border border-neutral-300 px-3 py-2 text-sm outline-none focus:border-neutral-900 dark:border-neutral-700 dark:bg-neutral-950 dark:focus:border-neutral-100"
          />
          <button
            type="submit"
            disabled={busy}
            className="rounded-md bg-neutral-900 px-3 py-2 text-sm font-medium text-white disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900"
          >
            {busy ? 'Sending…' : 'Email me a sign-in link'}
          </button>
          {error && <p className="text-sm text-red-600">{error}</p>}
        </form>
      )}
    </main>
  )
}
