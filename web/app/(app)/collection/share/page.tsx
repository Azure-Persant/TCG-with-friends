import { createClient } from '@/lib/supabase/server'
import { ShareManager, type Share } from './share-ui'

export const dynamic = 'force-dynamic'

/**
 * Manage public, read-only share links for your collection (22). Mutations
 * go through app_create/revoke/delete_collection_share -- this table has no
 * direct-write policy, only SELECT (see db/policies.sql).
 */
export default async function SharePage() {
  const supabase = await createClient()

  const { data, error } = await supabase
    .from('collection_share')
    .select('id, token, label, created_at, expires_at, revoked_at')
    .order('created_at', { ascending: false })

  if (error) {
    return (
      <div className="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-200">
        <p className="font-medium">Could not load your share links</p>
        <p className="mt-1">{error.message}</p>
      </div>
    )
  }

  return (
    <div className="mx-auto flex max-w-2xl flex-col gap-6">
      <div>
        <h1 className="font-heading text-2xl font-bold text-white">Share your collection</h1>
      </div>
      <div className="panel p-4">
        <ShareManager shares={(data ?? []) as Share[]} />
      </div>
    </div>
  )
}
