'use client'

import { useEffect, useRef, useState } from 'react'
import Link from 'next/link'

export type NavMenuItem = {
  label: string
  href: string
  badge?: number
}

/**
 * A click-to-open dropdown for the nav bar (the Collection/Friends menus and
 * the account menu). No Radix in this codebase -- this is deliberately small:
 * open state, click-outside-to-close, Escape-to-close, nothing more.
 */
export function NavMenu({
  trigger,
  items,
  align = 'left',
  footer,
}: {
  trigger: React.ReactNode
  items: NavMenuItem[]
  align?: 'left' | 'right'
  /** Rendered after the items, below a divider -- e.g. a Sign out form,
   *  which is a submit button rather than a Link. */
  footer?: React.ReactNode
}) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return

    function onPointerDown(e: PointerEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false)
    }
    function onKeyDown(e: KeyboardEvent) {
      if (e.key === 'Escape') setOpen(false)
    }
    document.addEventListener('pointerdown', onPointerDown)
    document.addEventListener('keydown', onKeyDown)
    return () => {
      document.removeEventListener('pointerdown', onPointerDown)
      document.removeEventListener('keydown', onKeyDown)
    }
  }, [open])

  return (
    <div ref={ref} className="relative">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-haspopup="menu"
        aria-expanded={open}
        className="flex items-center gap-1 rounded-md px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-100 hover:text-slate-900"
      >
        {trigger}
        <ChevronDownIcon className="h-3.5 w-3.5" />
      </button>
      {open && (
        <div
          role="menu"
          className={`absolute top-full z-50 mt-1 w-48 rounded-md border border-slate-200 bg-white py-1 shadow-lg ${
            align === 'right' ? 'right-0' : 'left-0'
          }`}
        >
          {items.map((item) => (
            <Link
              key={item.href + item.label}
              href={item.href}
              role="menuitem"
              onClick={() => setOpen(false)}
              className="flex items-center justify-between px-3 py-2 text-sm text-slate-700 hover:bg-slate-100 hover:text-slate-900"
            >
              {item.label}
              {item.badge ? (
                <span className="ml-1.5 rounded-full bg-cyan-500 px-1.5 py-0.5 text-xs font-semibold text-white">
                  {item.badge}
                </span>
              ) : null}
            </Link>
          ))}
          {footer && (
            <div className="mt-1 border-t border-slate-200 pt-1" onClick={() => setOpen(false)}>
              {footer}
            </div>
          )}
        </div>
      )}
    </div>
  )
}

function ChevronDownIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden>
      <polyline points="6 9 12 15 18 9" />
    </svg>
  )
}
