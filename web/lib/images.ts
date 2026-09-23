import { supabaseEnv } from './supabase/env'

/**
 * Must match `SUPABASE_STORAGE_BUCKET` (default) in `ingest/src/config.ts` and
 * the bucket created for it in Supabase Storage.
 */
const BUCKET = 'card-images'

/** Public URL for a `card_image.storage_key`. The bucket must be public (17, 22). */
export function cardImageUrl(storageKey: string): string {
  return `${supabaseEnv().url}/storage/v1/object/public/${BUCKET}/${storageKey}`
}
