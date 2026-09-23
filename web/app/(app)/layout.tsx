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
    <div className="app-backdrop">
      {/* Deliberately light, not themed -- see the note on globals.css.
          The old design this follows kept its header white in every mode so
          the brand mark stayed legible over a dark gradient body; a themed
          header would put white text on a white bar. */}
      <header className="sticky top-0 z-50 border-b border-slate-200 bg-white shadow-sm">
        <div className="mx-auto flex h-16 max-w-5xl items-center justify-between px-6">
          <div className="flex items-center gap-6">
            <Link href="/collection" className="font-heading text-lg font-bold text-slate-900">
              Card inventory
            </Link>
            <nav className="hidden items-center gap-1 text-sm md:flex">
              <Link href="/collection" className="rounded-md px-3 py-1.5 font-medium text-slate-700 hover:bg-slate-100 hover:text-cyan-700">
                Collection
              </Link>
              <Link href="/add" className="rounded-md px-3 py-1.5 font-medium text-slate-700 hover:bg-slate-100 hover:text-cyan-700">
                Add cards
              </Link>
              <Link href="/cards" className="rounded-md px-3 py-1.5 font-medium text-slate-700 hover:bg-slate-100 hover:text-cyan-700">
                Browse
              </Link>
              <Link href="/decks" className="rounded-md px-3 py-1.5 font-medium text-slate-700 hover:bg-slate-100 hover:text-cyan-700">
                Decks
              </Link>
              <Link href="/lend" className="rounded-md px-3 py-1.5 font-medium text-slate-700 hover:bg-slate-100 hover:text-cyan-700">
                Lend
              </Link>
              <Link href="/friends" className="rounded-md px-3 py-1.5 font-medium text-slate-700 hover:bg-slate-100 hover:text-cyan-700">
                Friends
              </Link>
              <Link href="/locations" className="rounded-md px-3 py-1.5 font-medium text-slate-700 hover:bg-slate-100 hover:text-cyan-700">
                Boxes
              </Link>
              <Link href="/inbox" className="rounded-md px-3 py-1.5 font-medium text-slate-700 hover:bg-slate-100 hover:text-cyan-700">
                Inbox
                {pending ? (
                  <span className="ml-1.5 rounded-full bg-cyan-500 px-1.5 py-0.5 text-xs font-semibold text-white">
                    {pending}
                  </span>
                ) : null}
              </Link>
            </nav>
          </div>
          <form action="/auth/signout" method="post" className="flex items-center gap-3">
            <span className="hidden text-sm text-slate-500 sm:inline">
              {account?.username ? `@${account.username}` : (account?.display_name ?? user.email)}
            </span>
            <button type="submit" className="text-sm text-slate-500 hover:text-slate-900 hover:underline">
              Sign out
            </button>
          </form>
        </div>
      </header>
      <main className="mx-auto max-w-5xl px-6 py-8 text-slate-100">{children}</main>
    </div>
  )
}
