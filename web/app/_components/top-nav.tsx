import Link from 'next/link'
import { NavMenu } from './nav-menu'

const navLink = 'rounded-md px-3 py-1.5 font-medium text-slate-700 hover:bg-slate-100 hover:text-slate-900'

/** The reference app's brand mark -- a stack of layers, in its cyan-600. */
function LayersIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={2}
      strokeLinecap="round"
      strokeLinejoin="round"
      className="h-6 w-6 shrink-0 text-cyan-600"
      aria-hidden
    >
      <polygon points="12 2 2 7 12 12 22 7 12 2" />
      <polyline points="2 17 12 22 22 17" />
      <polyline points="2 12 12 17 22 12" />
    </svg>
  )
}

type Props =
  | { signedIn: false }
  | {
      signedIn: true
      accountLabel: string
      pending: number
    }

/**
 * The nav bar for every page, signed in or not -- including /cards, which is
 * reachable both by anonymous visitors AND by a signed-in user clicking
 * "Browse Cards" from inside the app (issue: visiting /cards while signed in
 * used to always render the anonymous "Sign in" header, which read as having
 * been logged out even though the session was untouched -- /cards is a
 * public path in proxy.ts, not an auth boundary). One component, one source
 * of truth for what the bar looks like, so the two states can't drift apart
 * again.
 *
 * The logo always links to "/" -- the "Select Your Game" landing page, not
 * straight into /collection -- since that page is also where a future
 * second game gets chosen.
 *
 * Deliberately light, not themed -- see the note on globals.css. The old
 * design this follows kept its header white in every mode so the brand mark
 * stayed legible over a dark gradient body; a themed header would put white
 * text on a white bar.
 */
export function TopNav(props: Props) {
  return (
    <header className="sticky top-0 z-50 border-b border-slate-200 bg-white shadow-sm">
      <div className="mx-auto flex h-16 max-w-7xl items-center justify-between px-6">
        <div className="flex items-center gap-6">
          <Link href="/" className="flex items-center gap-2 font-heading text-xl font-bold text-slate-900">
            <LayersIcon />
            Card inventory
          </Link>

          {props.signedIn && (
            <nav className="hidden items-center gap-1 text-sm md:flex">
              <NavMenu
                trigger="Collection"
                items={[
                  { label: 'Collection', href: '/collection' },
                  { label: 'Add Cards', href: '/add' },
                  { label: 'Boxes', href: '/locations' },
                  { label: 'Lend', href: '/lend' },
                  { label: 'Share', href: '/collection/share' },
                ]}
              />
              <Link href="/cards" className={navLink}>
                Browse Cards
              </Link>
              <Link href="/decks" className={navLink}>
                Decks
              </Link>
              <NavMenu
                trigger="Friends"
                items={[
                  { label: 'Friends', href: '/friends' },
                  { label: 'Lend', href: '/lend' },
                ]}
              />
            </nav>
          )}
        </div>

        {props.signedIn ? (
          <NavMenu
            align="right"
            trigger={props.accountLabel}
            items={[
              { label: 'Inbox', href: '/inbox', badge: props.pending },
              { label: 'Friends', href: '/friends' },
              { label: 'Profile', href: '/profile' },
              { label: 'Game Selection', href: '/' },
            ]}
            footer={
              <form action="/auth/signout" method="post">
                <button
                  type="submit"
                  className="w-full px-3 py-2 text-left text-sm text-slate-700 hover:bg-slate-100 hover:text-slate-900"
                >
                  Sign out
                </button>
              </form>
            }
          />
        ) : (
          <Link href="/login" className="text-sm font-medium text-slate-700 hover:text-cyan-700 hover:underline">
            Sign in
          </Link>
        )}
      </div>
    </header>
  )
}
