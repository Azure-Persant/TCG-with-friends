'use client'

import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { setDisplayName, setUsername, type Result } from './actions'

/**
 * Two independent fields, two independent forms -- a failed username change
 * (taken, say) should not roll back an already-valid display name edit, and
 * vice versa.
 */
export function ProfileForm({
  email,
  initialDisplayName,
  initialUsername,
}: {
  email: string
  initialDisplayName: string
  initialUsername: string | null
}) {
  return (
    <div className="flex flex-col gap-6">
      <Field
        label="Display name"
        help="Shown to friends throughout the app -- on the welcome header, in the friends list."
        initialValue={initialDisplayName}
        placeholder="Jon"
        action={setDisplayName}
        fieldName="displayName"
        looksValid={(v) => v.trim().length >= 1 && v.trim().length <= 60}
      />
      <Field
        label="Username"
        help="How friends add you -- something you can say out loud rather than spelling out an email address. 3–20 characters. Letters, numbers, hyphens and underscores. Not case-sensitive."
        initialValue={initialUsername ?? ''}
        placeholder="jon"
        action={setUsername}
        fieldName="username"
        looksValid={(v) => /^[A-Za-z0-9][A-Za-z0-9_-]{2,19}$/.test(v)}
      />
      <div>
        <label className="text-sm font-medium text-slate-300">Email</label>
        <p className="mt-1 text-sm text-slate-400">{email}</p>
        <p className="mt-1 text-xs text-slate-500">
          How you sign in. There is no way to change this here.
        </p>
      </div>
    </div>
  )
}

function Field({
  label,
  help,
  initialValue,
  placeholder,
  action,
  fieldName,
  looksValid,
}: {
  label: string
  help: string
  initialValue: string
  placeholder: string
  action: (fd: FormData) => Promise<Result>
  fieldName: string
  looksValid: (v: string) => boolean
}) {
  const router = useRouter()
  const [value, setValue] = useState(initialValue)
  const [error, setError] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)
  const [pending, start] = useTransition()

  function submit(e: React.FormEvent) {
    e.preventDefault()
    setError(null)
    setSaved(false)
    const fd = new FormData()
    fd.set(fieldName, value)
    start(async () => {
      const r = await action(fd)
      if (r.ok) {
        setSaved(true)
        router.refresh()
      } else {
        setError(r.error)
      }
    })
  }

  return (
    <form onSubmit={submit} className="flex flex-col gap-2">
      <label htmlFor={fieldName} className="text-sm font-medium text-slate-300">
        {label}
      </label>
      <div className="flex gap-2">
        <input
          id={fieldName}
          value={value}
          onChange={(e) => {
            setValue(e.target.value)
            setSaved(false)
          }}
          autoComplete="off"
          placeholder={placeholder}
          className="flex-1 rounded-md border border-slate-700 bg-slate-800 px-3 py-2 text-sm text-slate-100 outline-none focus:border-accent"
        />
        <button
          type="submit"
          disabled={pending || !looksValid(value) || value === initialValue}
          className="rounded-md bg-accent px-3 py-2 text-sm font-medium text-white transition hover:opacity-90 disabled:opacity-50"
        >
          {pending ? 'Saving…' : 'Save'}
        </button>
      </div>
      <p className="text-xs text-slate-400">{help}</p>
      {error && (
        <p role="alert" className="text-sm text-red-400">
          {error}
        </p>
      )}
      {saved && <p className="text-sm text-green-400">Saved.</p>}
    </form>
  )
}
