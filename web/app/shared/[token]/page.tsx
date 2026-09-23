import { createClient } from '@/lib/supabase/server'
import { TopNav } from '@/app/_components/top-nav'
import { SharedGrid, type SharedRow } from './shared-grid'

export const dynamic = 'force-dynamic'

type Meta = {
  owner_name: string
  label: string | null
  created_at: string
  expires_at: string | null
}

/**
 * A public, read-only view of someone's collection (22) -- reachable by
 * anyone with the link, no account needed. Name, quantity, finish and
 * condition only: never a location, and copies out on loan show as their
 * own count rather than being folded into "owned" or naming who has them
 * (14's privacy rule applies here at least as strictly as it does to
 * friends).
 *
 * An unknown, revoked or expired token all render the same "this link
 * doesn't work" state -- shared_collection_meta returning no row is the
 * only signal, by design (see db/functions.sql).
 */
export default async function SharedCollectionPage({
  params,
}: {
  params: Promise<{ token: string }>
}) {
  const { token } = await params
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()

  let nav: React.ReactNode
  if (user) {
    const { data: account } = await supabase
      .from('account')
      .select('display_name, username')
      .eq('id', user.id)
      .single()
    const { count: pending } = await supabase
      .from('request')
      .select('id', { count: 'exact', head: true })
      .eq('recipient_account_id', user.id)
      .eq('status', 'pending')
    nav = (
      <TopNav
        signedIn
        accountLabel={account?.username ? `@${account.username}` : (account?.display_name ?? user.email ?? '')}
        pending={pending ?? 0}
      />
    )
  } else {
    nav = <TopNav signedIn={false} />
  }

  const [{ data: metaRows }, { data: rows }] = await Promise.all([
    supabase.rpc('shared_collection_meta', { p_token: token }),
    supabase.rpc('shared_collection', { p_token: token }),
  ])

  const meta = (metaRows as Meta[] | null)?.[0] ?? null

  return (
    <div className="app-backdrop text-slate-100">
      {nav}
      <div className="mx-auto flex max-w-7xl flex-col gap-6 px-6 py-8">
        {!meta ? (
          <div className="rounded-lg border border-dashed border-white/20 p-8 text-center">
            <p className="font-medium">This link doesn&apos;t work</p>
            <p className="mt-1 text-sm text-slate-400">
              It may have expired, been revoked, or never existed.
            </p>
          </div>
        ) : (
          <>
            <div>
              <h1 className="font-heading text-3xl font-bold text-white">
                {meta.label || `${meta.owner_name}'s collection`}
              </h1>
              <p className="mt-1 text-sm text-slate-400">Shared by {meta.owner_name}</p>
            </div>

            {(!rows || rows.length === 0) ? (
              <div className="rounded-lg border border-dashed border-white/20 p-8 text-center">
                <p className="font-medium">Nothing here yet</p>
              </div>
            ) : (
              <SharedGrid rows={(rows ?? []) as SharedRow[]} />
            )}
          </>
        )}
      </div>
    </div>
  )
}
