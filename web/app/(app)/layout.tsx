import Link from 'next/link'
import { redirect } from 'next/navigation'
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
    .select('display_name')
    .eq('id', user.id)
    .single()

  const { count: pending } = await supabase
    .from('request')
    .select('id', { count: 'exact', head: true })
    .eq('recipient_account_id', user.id)
    .eq('status', 'pending')

  return (
    <div className="mx-auto max-w-3xl px-6 py-8">
      <header className="flex items-baseline justify-between border-b border-neutral-200 pb-4 dark:border-neutral-800">
        <nav className="flex gap-5 text-sm">
          <Link href="/collection" className="font-medium hover:underline">
            Collection
          </Link>
          <Link href="/inbox" className="font-medium hover:underline">
            Inbox
            {pending ? (
              <span className="ml-1.5 rounded-full bg-neutral-900 px-1.5 py-0.5 text-xs text-white dark:bg-neutral-100 dark:text-neutral-900">
                {pending}
              </span>
            ) : null}
          </Link>
        </nav>
        <form action="/auth/signout" method="post" className="flex items-center gap-3">
          <span className="text-sm text-neutral-500">{account?.display_name ?? user.email}</span>
          <button type="submit" className="text-sm text-neutral-500 hover:underline">
            Sign out
          </button>
        </form>
      </header>
      <main className="py-8">{children}</main>
    </div>
  )
}
