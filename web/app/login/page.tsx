'use client'

import { Suspense, useState } from 'react'
import { useSearchParams } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'

const LINK_FAILED =
  'That sign-in link did not work. It may have expired or already been used — request a new one below.'

/**
 * Supabase's gateway answers this when the request path matches no route,
 * which in practice always means NEXT_PUBLIC_SUPABASE_URL is malformed -- a
 * trailing slash, or a whole endpoint pasted where the project URL belongs.
 * The message names neither the setting nor the mistake, so say it here.
 */
function explain(message: string): string {
  if (message.toLowerCase().includes('invalid path specified')) {
    return (
      `${message} — this almost always means NEXT_PUBLIC_SUPABASE_URL is wrong. ` +
      'It should be exactly https://YOURREF.supabase.co with no trailing slash ' +
      'and no path. Fix it in Vercel, then redeploy: env changes do not affect ' +
      'a deployment that is already running.'
    )
  }
  return message
}

/**
 * Magic-link sign in.
 *
 * No passwords, deliberately. Passwords mean reset flows, strength rules and
 * a credential worth stealing; for a small group of friends a link in an
 * inbox is both simpler to build and harder to get wrong.
 */
export default function LoginPage() {
  // useSearchParams needs a Suspense boundary, because it forces this subtree
  // to wait for request-time information that prerendering does not have.
  return (
    <Suspense fallback={<Shell />}>
      <LoginForm />
    </Suspense>
  )
}

function LoginForm() {
  const params = useSearchParams()
  const [email, setEmail] = useState('')
  const [sent, setSent] = useState(false)
  const [submitError, setSubmitError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  // /auth/confirm bounces here with ?error=link when a token will not verify.
  // Derived during render rather than set in an effect: a value that is a pure
  // function of the URL is not state, and treating it as state means rendering
  // once with the wrong answer.
  //
  // A submit error supersedes it -- once you have tried again, the message
  // about the old link is stale.
  const error = submitError ?? (params.get('error') === 'link' ? LINK_FAILED : null)

  async function signIn(e: React.FormEvent) {
    e.preventDefault()
    setBusy(true)
    setSubmitError(null)

    const supabase = createClient()
    const next = params.get('next') ?? '/collection'

    // window.location.origin, not a hardcoded URL: this has to be right on
    // localhost, on Vercel previews and in production without a rebuild.
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: {
        emailRedirectTo: `${window.location.origin}/auth/confirm?next=${encodeURIComponent(next)}`,
      },
    })

    setBusy(false)
    if (error) setSubmitError(explain(error.message))
    else setSent(true)
  }

  return (
    <Shell>
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
          {error && (
            <p role="alert" className="text-sm text-red-600">
              {error}
            </p>
          )}
        </form>
      )}
    </Shell>
  )
}

function Shell({ children }: { children?: React.ReactNode }) {
  return (
    <main className="mx-auto flex min-h-dvh max-w-md flex-col justify-center px-6">
      <h1 className="text-2xl font-semibold tracking-tight">Card inventory</h1>
      <p className="mt-2 text-sm text-neutral-500">
        Keep track of what you own, what you have lent out, and who still has it.
      </p>
      {children}
    </main>
  )
}
