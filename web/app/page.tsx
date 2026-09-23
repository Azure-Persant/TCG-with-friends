import { cookies } from 'next/headers'
import { createClient } from '@/lib/supabase/server'
import { TopNav } from '@/app/_components/top-nav'
import { selectGame } from './actions'

export const dynamic = 'force-dynamic'

/**
 * "Select Your Game" -- the landing page every visitor reaches from "/" and
 * from clicking the nav logo, signed in or not. There is only one game
 * (Grand Archive) today, but the page and the selected_game_id column both
 * exist so a second game has somewhere to land rather than needing this
 * whole page invented later.
 */
export default async function GameSelectPage() {
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()

  const { data: games } = await supabase.from('game').select('id, slug, name').order('created_at')

  let selectedGameId: string | null = null
  let nav: React.ReactNode

  if (user) {
    const [{ data: account }, { count: pending }] = await Promise.all([
      supabase.from('account').select('display_name, username, selected_game_id').eq('id', user.id).single(),
      supabase
        .from('request')
        .select('id', { count: 'exact', head: true })
        .eq('recipient_account_id', user.id)
        .eq('status', 'pending'),
    ])
    selectedGameId = account?.selected_game_id ?? null
    nav = (
      <TopNav
        signedIn
        accountLabel={account?.username ? `@${account.username}` : (account?.display_name ?? user.email ?? '')}
        pending={pending ?? 0}
      />
    )
  } else {
    const cookieStore = await cookies()
    const selectedSlug = cookieStore.get('selected_game')?.value
    selectedGameId = games?.find((g) => g.slug === selectedSlug)?.id ?? null
    nav = <TopNav signedIn={false} />
  }

  return (
    <div className="app-backdrop text-slate-100">
      {nav}
      <div className="mx-auto max-w-5xl px-6 py-16 text-center">
        <h1 className="font-heading text-4xl font-bold text-white">Select Your Game</h1>
        <p className="mt-2 text-slate-400">More games are coming soon.</p>

        <div className="mt-10 grid grid-cols-1 gap-6 sm:grid-cols-2 md:grid-cols-3">
          {(games ?? []).map((g) => (
            <form key={g.id} action={selectGame}>
              <input type="hidden" name="gameId" value={g.id} />
              <input type="hidden" name="gameSlug" value={g.slug} />
              <button
                type="submit"
                className={`panel flex aspect-video w-full flex-col items-center justify-center gap-2 overflow-hidden text-left transition hover:border-cyan-500/60 ${
                  g.id === selectedGameId ? 'ring-2 ring-cyan-400' : ''
                }`}
              >
                <span className="font-heading text-xl font-bold text-white">{g.name}</span>
                {g.id === selectedGameId && (
                  <span className="rounded-full bg-cyan-600/20 px-2.5 py-0.5 text-xs font-medium text-cyan-300">
                    Currently selected
                  </span>
                )}
              </button>
            </form>
          ))}
        </div>
      </div>
    </div>
  )
}
