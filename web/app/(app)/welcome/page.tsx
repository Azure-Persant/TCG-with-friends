import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { UsernameForm } from './username-form'

export const dynamic = 'force-dynamic'

/**
 * Pick a username, once.
 *
 * A Google sign-in never asks for one, so the app has to, and this is the only
 * screen a signed-in user can be forced onto. Everything else is reachable
 * only after it is done -- see the layout.
 */
export default async function WelcomePage() {
  const supabase = await createClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()

  const { data: account } = await supabase
    .from('account')
    .select('username, display_name')
    .eq('id', user!.id)
    .single()

  // Nothing to do here once it is set; arriving by hand should not offer to
  // change it as if that were the purpose of the page.
  if (account?.username) redirect('/collection')

  return (
    <main className="mx-auto flex max-w-md flex-col justify-center py-12">
      <h1 className="text-xl font-semibold tracking-tight">
        Welcome{account?.display_name ? `, ${account.display_name}` : ''}
      </h1>
      <p className="mt-2 text-sm text-slate-400">
        Pick a username. It is how friends add you — something you can say out loud rather
        than spelling out an email address.
      </p>
      <div className="mt-6">
        <UsernameForm suggestion={suggest(account?.display_name ?? '')} />
      </div>
    </main>
  )
}

/** A starting point, not a decision — the field stays editable. */
function suggest(displayName: string): string {
  const base = displayName
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '')
    .slice(0, 20)
  return base.length >= 3 ? base : ''
}
