import Link from 'next/link'
import { redirect } from 'next/navigation'
import { headers } from 'next/headers'
import { createClient } from '@/lib/supabase/server'

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
    <div className="mx-auto max-w-3xl px-6 py-8">
      <header className="flex items-baseline justify-between border-b border-neutral-200 pb-4 dark:border-neutral-800">
        <div className="flex items-baseline gap-6">
          <Link href="/collection" className="text-lg font-semibold tracking-tight text-accent">
            Card inventory
          </Link>
          <nav className="flex gap-5 text-sm">
            <Link href="/collection" className="font-medium hover:text-accent">
              Collection
            </Link>
            <Link href="/add" className="font-medium hover:text-accent">
              Add cards
            </Link>
            <Link href="/cards" className="font-medium hover:text-accent">
              Browse
            </Link>
            <Link href="/lend" className="font-medium hover:text-accent">
              Lend
            </Link>
            <Link href="/friends" className="font-medium hover:text-accent">
              Friends
            </Link>
            <Link href="/locations" className="font-medium hover:text-accent">
              Boxes
            </Link>
            <Link href="/inbox" className="font-medium hover:text-accent">
              Inbox
              {pending ? (
                <span className="ml-1.5 rounded-full bg-accent px-1.5 py-0.5 text-xs text-white">
                  {pending}
                </span>
              ) : null}
            </Link>
          </nav>
        </div>
        <form action="/auth/signout" method="post" className="flex items-center gap-3">
          <span className="text-sm text-neutral-500">
            {account?.username ? `@${account.username}` : (account?.display_name ?? user.email)}
          </span>
          <button type="submit" className="text-sm text-neutral-500 hover:underline">
            Sign out
          </button>
        </form>
      </header>
      <main className="py-8">{children}</main>
    </div>
  )
}
