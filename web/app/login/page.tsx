'use client'

import { Suspense, useState } from 'react'
import { useRouter, useSearchParams } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'

const LINK_FAILED =
  'That sign-in link did not work. It may have expired or already been used — request a new code below.'

const OAUTH_FAILED =
  'Google sign-in did not complete. Try again, or use your email below.'

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
 * Sign in with Google, or by email (30).
 *
 * Google is offered first and is the recommended path, because it removes
 * email from the critical path entirely: nothing is sent, so nothing can be
 * scanned, rate-limited or filtered. The OAuth code travels from Google to the
 * browser that began the sign-in and is bound to a verifier only that browser
 * holds -- there is no URL in an inbox for a filter to spend.
 *
 * A CODE, not a link, and that distinction is load-bearing. Corporate mail
 * filters -- Microsoft Safe Links, Proofpoint URL Defense and friends --
 * pre-fetch every URL in an incoming message to check it is safe. A magic link
 * is a single-use token, so the scanner spends it before the recipient ever
 * clicks, and sign-in fails with no way for either side to tell why. A number
 * typed by hand cannot be consumed by a machine following a URL.
 *
 * The catch is that the code path needs a template change, and Supabase only
 * allows editing templates once custom SMTP is configured. Until then the
 * stock template sends a link and nothing else. So this screen offers BOTH and
 * lets whichever the email actually contains be the one that works.
 *
 * For a scanned mailbox the link path cannot be rescued: the template must
 * send {{ .Token }} and must NOT contain {{ .ConfirmationURL }}, because both
 * are the same token and a scanner following the link spends the code too.
 * That needs SMTP. See web/README.md.
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
  const router = useRouter()

  const [step, setStep] = useState<'email' | 'code'>('email')
  const [email, setEmail] = useState('')
  const [code, setCode] = useState('')
  const [submitError, setSubmitError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  // /auth/confirm bounces here with ?error=link when a token will not verify.
  // Derived during render rather than set in an effect: a value that is a pure
  // function of the URL is not state, and treating it as state means rendering
  // once with the wrong answer.
  const urlError = params.get('error')
  const error =
    submitError ??
    (urlError === 'link' ? LINK_FAILED : urlError === 'oauth' ? OAUTH_FAILED : null)

  async function signInWithGoogle() {
    setBusy(true)
    setSubmitError(null)

    const supabase = createClient()
    const next = params.get('next') ?? '/collection'

    const { error } = await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: {
        redirectTo: `${window.location.origin}/auth/callback?next=${encodeURIComponent(next)}`,
      },
    })

    // On success the browser is already navigating to Google, so there is
    // nothing to do; only a failure to even start comes back here.
    if (error) {
      setBusy(false)
      setSubmitError(error.message)
    }
  }

  async function sendCode(e: React.FormEvent) {
    e.preventDefault()
    setBusy(true)
    setSubmitError(null)

    const supabase = createClient()

    // emailRedirectTo is set because the STOCK Supabase template sends only a
    // link -- editing templates requires custom SMTP, which a new project does
    // not have. So the email may contain a link, a code, or both depending on
    // configuration, and the UI below offers both. See web/README.md.
    const next = params.get('next') ?? '/collection'
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: {
        emailRedirectTo: `${window.location.origin}/auth/confirm?next=${encodeURIComponent(next)}`,
      },
    })

    setBusy(false)
    if (error) setSubmitError(explain(error.message))
    else setStep('code')
  }

  async function verifyCode(e: React.FormEvent) {
    e.preventDefault()
    setBusy(true)
    setSubmitError(null)

    const supabase = createClient()

    // 'email' covers an existing user. A brand new account is confirmed under
    // 'signup', and the caller cannot know which they are, so try the second
    // if the first is rejected. Getting this wrong strands the very first
    // person to sign up -- which, here, is the owner of the app.
    let { error } = await supabase.auth.verifyOtp({ email, token: code, type: 'email' })
    if (error) {
      const retry = await supabase.auth.verifyOtp({ email, token: code, type: 'signup' })
      if (!retry.error) error = null
    }

    setBusy(false)

    if (error) {
      setSubmitError(
        error.message.toLowerCase().includes('expired')
          ? 'That code has expired. Request a new one.'
          : 'That code was not accepted. Check the digits and try again.',
      )
      return
    }

    // refresh() so the server re-renders with the new session cookie; push()
    // alone would navigate with the old, signed-out render still cached.
    const next = params.get('next') ?? '/collection'
    router.refresh()
    router.push(next.startsWith('/') && !next.startsWith('//') ? next : '/collection')
  }

  if (step === 'code') {
    return (
      <Shell>
        <form onSubmit={verifyCode} className="mt-8 flex flex-col gap-3">
          <p className="text-sm font-medium">Check your email</p>
          <p className="-mt-1 text-sm text-neutral-500">
            We sent a message to <span className="font-medium">{email}</span>. Click the sign-in
            link in it — or, if it contains a numeric code, type that here instead.
          </p>
          <label htmlFor="code" className="mt-2 text-sm font-medium">
            Sign-in code
          </label>
          <input
            id="code"
            inputMode="numeric"
            autoComplete="one-time-code"
            pattern="[0-9]*"
            required
            autoFocus
            value={code}
            onChange={(e) => setCode(e.target.value.replace(/\D/g, '').slice(0, 8))}
            placeholder="123456"
            className="rounded-md border border-neutral-300 px-3 py-2 text-center text-lg tracking-[0.4em] outline-none focus:border-neutral-900 dark:border-neutral-700 dark:bg-neutral-950 dark:focus:border-neutral-100"
          />
          <button
            type="submit"
            disabled={busy || code.length < 6}
            className="rounded-md bg-neutral-900 px-3 py-2 text-sm font-medium text-white disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900"
          >
            {busy ? 'Checking…' : 'Sign in'}
          </button>
          {error && (
            <p role="alert" className="text-sm text-red-600">
              {error}
            </p>
          )}
          <button
            type="button"
            onClick={() => {
              setStep('email')
              setCode('')
              setSubmitError(null)
            }}
            className="mt-1 text-left text-sm text-neutral-500 underline"
          >
            Use a different email
          </button>
        </form>
      </Shell>
    )
  }

  return (
    <Shell>
      <button
        type="button"
        onClick={signInWithGoogle}
        disabled={busy}
        className="mt-8 flex w-full items-center justify-center gap-3 rounded-md border border-neutral-300 px-3 py-2.5 text-sm font-medium hover:bg-neutral-50 disabled:opacity-50 dark:border-neutral-700 dark:hover:bg-neutral-900"
      >
        <GoogleMark />
        Continue with Google
      </button>

      <div className="mt-6 flex items-center gap-3" aria-hidden="true">
        <span className="h-px flex-1 bg-neutral-200 dark:bg-neutral-800" />
        <span className="text-xs text-neutral-500">or</span>
        <span className="h-px flex-1 bg-neutral-200 dark:bg-neutral-800" />
      </div>

      <form onSubmit={sendCode} className="mt-6 flex flex-col gap-3">
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
          {busy ? 'Sending…' : 'Email me a sign-in code'}
        </button>
        {error && (
          <p role="alert" className="text-sm text-red-600">
            {error}
          </p>
        )}
      </form>
    </Shell>
  )
}

/** Google's mark, inline: a strict CSP and no external hosts (17). */
function GoogleMark() {
  return (
    <svg width="16" height="16" viewBox="0 0 48 48" aria-hidden="true">
      <path
        fill="#EA4335"
        d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"
      />
      <path
        fill="#4285F4"
        d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"
      />
      <path
        fill="#FBBC05"
        d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"
      />
      <path
        fill="#34A853"
        d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"
      />
    </svg>
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
