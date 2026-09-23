'use client'

import { useState, useTransition } from 'react'
import { createShare, revokeShare, deleteShare } from './actions'

export type Share = {
  id: string
  token: string
  label: string | null
  created_at: string
  expires_at: string | null
  revoked_at: string | null
}

const EXPIRY_PRESETS = [
  { label: '24 hours', hours: '24' },
  { label: '7 days', hours: String(24 * 7) },
  { label: '30 days', hours: String(24 * 30) },
  { label: 'No expiry', hours: 'never' },
]

function isLive(share: Share): boolean {
  return !share.revoked_at && (!share.expires_at || new Date(share.expires_at) > new Date())
}

function statusLabel(share: Share): string {
  if (share.revoked_at) return 'revoked'
  if (!share.expires_at) return 'no expiry'
  const when = new Date(share.expires_at)
  return when > new Date() ? `expires ${when.toLocaleDateString()}` : `expired ${when.toLocaleDateString()}`
}

export function ShareManager({ shares }: { shares: Share[] }) {
  const [label, setLabel] = useState('')
  const [expiryHours, setExpiryHours] = useState('never')
  const [pending, start] = useTransition()
  const [error, setError] = useState<string | null>(null)
  const [copiedId, setCopiedId] = useState<string | null>(null)

  function shareUrl(token: string): string {
    return `${window.location.origin}/shared/${token}`
  }

  async function copy(share: Share) {
    const url = shareUrl(share.token)
    try {
      await navigator.clipboard.writeText(url)
      setCopiedId(share.id)
      setTimeout(() => setCopiedId(null), 2000)
    } catch {
      // Clipboard access can be blocked without a user gesture in some
      // browsers; showing the URL means it can still be copied by hand
      // rather than failing with nothing to show for it.
      window.prompt('Copy this link', url)
    }
  }

  function create(e: React.FormEvent) {
    e.preventDefault()
    setError(null)
    const fd = new FormData()
    fd.set('label', label)
    fd.set('expiryHours', expiryHours)
    start(async () => {
      const r = await createShare(fd)
      if (r.ok) setLabel('')
      else setError(r.error)
    })
  }

  function act(action: (fd: FormData) => Promise<{ ok: boolean; error?: string }>, id: string) {
    setError(null)
    const fd = new FormData()
    fd.set('id', id)
    start(async () => {
      const r = await action(fd)
      if (!r.ok) setError(r.error ?? 'Something went wrong')
    })
  }

  return (
    <div className="flex flex-col gap-4">
      <p className="text-sm text-slate-400">
        Anyone with the link can view a read-only page listing your cards, quantities, finishes
        and conditions -- no location, and copies out on loan show only as a count, never who has
        them. No account needed to view it.
      </p>

      <form onSubmit={create} className="flex flex-wrap items-end gap-2">
        <div className="flex-1 min-w-[10rem]">
          <label htmlFor="share-label" className="text-xs font-medium text-slate-300">
            Name (optional)
          </label>
          <input
            id="share-label"
            value={label}
            onChange={(e) => setLabel(e.target.value)}
            placeholder="Sale list, Playgroup…"
            className="mt-1 w-full rounded-md border border-slate-700 bg-slate-800 px-2 py-1.5 text-sm text-slate-100 outline-none focus:border-accent"
          />
        </div>
        <div>
          <label htmlFor="share-expiry" className="text-xs font-medium text-slate-300">
            Expires
          </label>
          <select
            id="share-expiry"
            value={expiryHours}
            onChange={(e) => setExpiryHours(e.target.value)}
            className="mt-1 rounded-md border border-slate-700 bg-slate-800 px-2 py-1.5 text-sm text-slate-100"
          >
            {EXPIRY_PRESETS.map((p) => (
              <option key={p.hours} value={p.hours}>
                {p.label}
              </option>
            ))}
          </select>
        </div>
        <button
          type="submit"
          disabled={pending}
          className="rounded-md bg-accent px-3 py-1.5 text-sm font-medium text-white transition hover:opacity-90 disabled:opacity-50"
        >
          Create link
        </button>
      </form>

      {error && <p className="text-sm text-red-400">{error}</p>}

      {shares.length > 0 && (
        <ul className="flex flex-col gap-2">
          {shares.map((share) => {
            const live = isLive(share)
            return (
              <li
                key={share.id}
                className="flex flex-wrap items-center gap-2 rounded-md border border-slate-700 bg-slate-900/60 p-2 text-sm"
              >
                <span className="font-medium text-white">{share.label || 'Untitled'}</span>
                <span className={live ? 'text-slate-400' : 'text-red-400'}>{statusLabel(share)}</span>
                <div className="ml-auto flex items-center gap-1.5">
                  {live && (
                    <>
                      <button
                        type="button"
                        onClick={() => copy(share)}
                        className="rounded-md px-2 py-1 text-xs text-cyan-400 hover:bg-white/10"
                      >
                        {copiedId === share.id ? 'Copied' : 'Copy link'}
                      </button>
                      <button
                        type="button"
                        onClick={() => act(revokeShare, share.id)}
                        disabled={pending}
                        className="rounded-md px-2 py-1 text-xs text-amber-400 hover:bg-white/10 disabled:opacity-50"
                      >
                        Revoke
                      </button>
                    </>
                  )}
                  <button
                    type="button"
                    onClick={() => act(deleteShare, share.id)}
                    disabled={pending}
                    className="rounded-md px-2 py-1 text-xs text-red-400 hover:bg-white/10 disabled:opacity-50"
                  >
                    Delete
                  </button>
                </div>
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}
