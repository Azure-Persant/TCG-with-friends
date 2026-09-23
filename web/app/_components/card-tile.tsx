'use client'

import Image from 'next/image'
import { useState } from 'react'
import { cardImageUrl } from '@/lib/images'
import { Lightbox } from './card-thumbnail'
import { FoilOverlay } from './foil-overlay'

/**
 * The art-forward grid tile used by /cards, /add and /collection -- a real
 * card's aspect ratio (2.5:3.5), filling the top of a panel, with whatever
 * the caller passes as `children` (name, set, controls, ...) below it. This
 * is the shape the old Softgen prototype's collection/cards grids used; the
 * row-shaped CardThumbnail stays for places like the deck builder where a
 * qty stepper needs to sit beside the art instead of under it.
 */
export function CardTile({
  storageKey,
  alt,
  foil = false,
  restricted = false,
  onOpenDetail,
  children,
}: {
  storageKey: string | null
  alt: string
  /** Plays the shimmer treatment over the art (38). */
  foil?: boolean
  /** Standard-format restricted badge (39) -- attributes->legality->STANDARD->limit = 0. */
  restricted?: boolean
  /**
   * When given, clicking the art opens a full card detail view (23) instead
   * of the plain enlarge-the-art lightbox below -- the detail dialog already
   * shows the art large, so the two are alternatives, not layers. Unlike the
   * lightbox, this stays clickable even with no image: there is still text
   * and stats to show.
   */
  onOpenDetail?: () => void
  children?: React.ReactNode
}) {
  const [failed, setFailed] = useState(false)
  const [enlarged, setEnlarged] = useState(false)
  const hasImage = storageKey && !failed
  const clickable = onOpenDetail ? true : hasImage

  function handleClick() {
    if (onOpenDetail) onOpenDetail()
    else if (hasImage) setEnlarged(true)
  }

  return (
    <div className="panel flex flex-col overflow-hidden">
      <button
        type="button"
        onClick={handleClick}
        disabled={!clickable}
        aria-label={onOpenDetail ? `View ${alt}` : hasImage ? `Enlarge ${alt}` : alt}
        className="group relative block aspect-[2.5/3.5] w-full overflow-hidden bg-slate-800 outline-none focus-visible:ring-2 focus-visible:ring-cyan-400 focus-visible:ring-inset disabled:cursor-default"
      >
        {hasImage ? (
          <Image
            src={cardImageUrl(storageKey)}
            alt={alt}
            fill
            sizes="(min-width: 1280px) 16vw, (min-width: 768px) 22vw, 45vw"
            className="object-cover transition-transform group-hover:scale-105"
            onError={() => setFailed(true)}
          />
        ) : (
          <span className="absolute inset-0 flex items-center justify-center px-2 text-center text-xs text-slate-500">
            {alt}
          </span>
        )}

        {foil && <FoilOverlay />}

        {foil && (
          <span className="absolute left-1 top-1 rounded bg-slate-950/80 px-1.5 py-0.5 text-[10px] font-semibold text-cyan-200">
            Foil
          </span>
        )}

        {restricted && (
          <span className="absolute bottom-1 left-1 rounded bg-red-600 px-1.5 py-0.5 text-[10px] font-semibold text-white">
            Restricted
          </span>
        )}
      </button>
      {children && <div className="flex flex-1 flex-col gap-2 p-2.5">{children}</div>}
      {enlarged && hasImage && (
        <Lightbox src={cardImageUrl(storageKey)} alt={alt} onClose={() => setEnlarged(false)} />
      )}
    </div>
  )
}
