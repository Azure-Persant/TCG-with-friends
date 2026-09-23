import { createClient } from '@/lib/supabase/server'
import { AddFriend, FriendRow, GameShares, OutgoingRow } from './friends-ui'

export const dynamic = 'force-dynamic'

/**
 * Friends, and what they can see.
 *
 * Game sharing lives on this page rather than in settings on purpose. A
 * friendship on its own shows nothing (4) -- both people see empty collections
 * until a game is shared -- which is baffling unless the two are presented
 * together.
 */
export default async function FriendsPage() {
  const supabase = await createClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()

  const [{ data: friendships }, { data: outgoing }, { data: games }, { data: shares }] =
    await Promise.all([
      supabase.from('friendship').select('id, account_lo_id, account_hi_id, created_at'),
      supabase
        .from('request')
        .select('id, created_at, recipient:account!request_recipient_account_id_fkey ( display_name )')
        .eq('kind', 'friend')
        .eq('status', 'pending')
        .eq('proposer_account_id', user!.id),
      supabase.from('game').select('id, name').order('name'),
      supabase.from('game_share').select('game_id'),
    ])

  // friendship stores the pair canonically ordered, so which column holds the
  // other person depends on how the two ids sort.
  const friendIds = (friendships ?? []).map((f) =>
    f.account_lo_id === user!.id ? f.account_hi_id : f.account_lo_id,
  )

  const { data: friendAccounts } = friendIds.length
    ? await supabase.from('account').select('id, display_name').in('id', friendIds)
    : { data: [] }

  const sharedGameIds = new Set((shares ?? []).map((s) => s.game_id))

  return (
    <div className="flex flex-col gap-10">
      <section>
        <h2 className="text-sm font-semibold">Add a friend</h2>
        <p className="mt-1 text-sm text-slate-400">
          Their username, or their exact email address. Both must be typed in full: partial
          search is deliberately not possible, because it would turn this into a directory of
          everyone using the app.
        </p>
        <div className="mt-4">
          <AddFriend />
        </div>
      </section>

      <section>
        <h2 className="text-sm font-semibold">Friends</h2>
        {friendAccounts && friendAccounts.length > 0 ? (
          <ul className="mt-2 divide-y divide-white/10">
            {friendAccounts.map((f) => (
              <FriendRow key={f.id} id={f.id} name={f.display_name} />
            ))}
          </ul>
        ) : (
          <p className="mt-2 text-sm text-slate-400">Nobody yet.</p>
        )}
      </section>

      {outgoing && outgoing.length > 0 && (
        <section>
          <h2 className="text-sm font-semibold">Waiting on them</h2>
          <ul className="mt-2 divide-y divide-white/10">
            {outgoing.map((r) => {
              const who = Array.isArray(r.recipient) ? r.recipient[0] : r.recipient
              return (
                <OutgoingRow key={r.id} id={r.id} name={who?.display_name ?? 'Someone'} />
              )
            })}
          </ul>
        </section>
      )}

      <section>
        <h2 className="text-sm font-semibold">What friends can see</h2>
        <p className="mt-1 text-sm text-slate-400">
          Per game, and the same for every friend. A friend sees nothing of yours until you
          share the game — they never see which box a card is in (14).
        </p>
        <div className="mt-3">
          <GameShares
            games={games ?? []}
            shared={(games ?? []).filter((g) => sharedGameIds.has(g.id)).map((g) => g.id)}
          />
        </div>
      </section>
    </div>
  )
}
