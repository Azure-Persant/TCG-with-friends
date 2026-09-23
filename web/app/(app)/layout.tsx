import { redirect } from 'next/navigation'
import { headers } from 'next/headers'
import { createClient } from '@/lib/supabase/server'
import { TopNav } from '@/app/_components/top-nav'

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createClient()

  // getUser(), not getSession(): getUser revalidates the token with Supabase.
  // getSession trusts the cookie, which the client could have forged.
  const {
    data: { user },
  } = await supabase.auth.getUser()

  if (!user) redirect('/login')

  const { data: account } = await supabase
    .from('account')
    .select('display_name, username')
    .eq('id', user.id)
    .single()

  // A username is claimed once and everything else waits for it (33). Checked
  // in the layout so no page has to remember: a Google sign-in never asks, so
  // an account exists in this state for real users, not just in theory.
  //
  // /welcome is excluded or this would redirect to itself forever.
  const pathname = (await headers()).get('x-pathname') ?? ''
  if (account && !account.username && !pathname.startsWith('/welcome')) {
    redirect('/welcome')
  }

  const { count: pending } = await supabase
    .from('request')
    .select('id', { count: 'exact', head: true })
    .eq('recipient_account_id', user.id)
    .eq('status', 'pending')

  return (
    <div className="app-backdrop">
      <TopNav
        signedIn
        accountLabel={account?.username ? `@${account.username}` : (account?.display_name ?? user.email ?? '')}
        pending={pending ?? 0}
      />
      <main className="mx-auto max-w-7xl px-6 py-8 text-slate-100">{children}</main>
    </div>
  )
}
