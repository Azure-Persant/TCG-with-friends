'use client'

import Image from 'next/image'
import { useEffect, useState } from 'react'
import { cardImageUrl } from '@/lib/images'

/**
 * A card whose image is missing (still backfilling, or the edition's source
 * had none) gets the same dashed-border placeholder language used elsewhere
 * for empty states, not a broken-image icon.
 */
export function CardThumbnail({ storageKey, alt }: { storageKey: string | null; alt: string }) {
  const [failed, setFailed] = useState(false)
  const [enlarged, setEnlarged] = useState(false)

  if (!storageKey || failed) {
    return (
      <div
        aria-hidden
        className="flex h-24 w-[68px] shrink-0 items-center justify-center rounded-md border border-dashed border-white/20 text-[10px] text-slate-500"
      >
        no image
      </div>
    )
  }

  return (
    <>
      <button
        type="button"
        onClick={() => setEnlarged(true)}
        className="shrink-0 cursor-zoom-in rounded-md ring-offset-2 ring-offset-slate-900 outline-none transition hover:scale-[1.03] focus-visible:ring-2 focus-visible:ring-cyan-400"
        aria-label={`Enlarge ${alt}`}
      >
        <Image
          src={cardImageUrl(storageKey)}
          alt={alt}
          width={68}
          height={95}
          className="h-24 w-[68px] rounded-md object-cover shadow-md ring-1 ring-white/10"
          onError={() => setFailed(true)}
        />
      </button>
      {enlarged && <Lightbox src={cardImageUrl(storageKey)} alt={alt} onClose={() => setEnlarged(false)} />}
    </>
  )
}

export function Lightbox({ src, alt, onClose }: { src: string; alt: string; onClose: () => void }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label={alt}
      onClick={onClose}
      className="fixed inset-0 z-50 flex cursor-zoom-out items-center justify-center bg-black/80 p-6"
    >
      <Image
        src={src}
        alt={alt}
        width={480}
        height={670}
        className="max-h-[85vh] w-auto rounded-lg object-contain shadow-2xl"
        priority
      />
    </div>
  )
}
