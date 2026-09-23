'use client'

import Image from 'next/image'
import { useState } from 'react'
import { cardImageUrl } from '@/lib/images'

/**
 * A card whose image is missing (still backfilling, or the edition's source
 * had none) gets the same dashed-border placeholder language used elsewhere
 * for empty states, not a broken-image icon.
 */
export function CardThumbnail({ storageKey, alt }: { storageKey: string | null; alt: string }) {
  const [failed, setFailed] = useState(false)

  if (!storageKey || failed) {
    return (
      <div
        aria-hidden
        className="flex h-16 w-12 shrink-0 items-center justify-center rounded border border-dashed border-neutral-300 text-[10px] text-neutral-400 dark:border-neutral-700 dark:text-neutral-600"
      >
        no image
      </div>
    )
  }

  return (
    <Image
      src={cardImageUrl(storageKey)}
      alt={alt}
      width={48}
      height={64}
      className="h-16 w-12 shrink-0 rounded object-cover"
      onError={() => setFailed(true)}
    />
  )
}
