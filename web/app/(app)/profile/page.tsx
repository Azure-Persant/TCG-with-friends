import { createClient } from '@/lib/supabase/server'
import { ProfileForm } from './profile-form'

export const dynamic = 'force-dynamic'

/**
 * View and change your display name and username after the one-time
 * /welcome step (40) -- there was previously no way back to either.
 */
export default async function ProfilePage() {
  const supabase = await createClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()

  const { data: account } = await supabase
    .from('account')
    .select('display_name, username')
    .eq('id', user!.id)
    .single()

  return (
    <div className="mx-auto flex max-w-md flex-col gap-6">
      <div>
        <h1 className="font-heading text-2xl font-bold text-white">Profile</h1>
        <p className="mt-1 text-sm text-slate-400">Your name and handle, as friends see them.</p>
      </div>
      <div className="panel p-4">
        <ProfileForm
          email={user!.email ?? ''}
          initialDisplayName={account?.display_name ?? ''}
          initialUsername={account?.username ?? null}
        />
      </div>
    </div>
  )
}
