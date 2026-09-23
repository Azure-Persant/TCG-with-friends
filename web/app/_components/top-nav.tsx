import Link from 'next/link'

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
 * "Browse" from inside the app (issue: visiting /cards while signed in used
 * to always render the anonymous "Sign in" header, which read as having been
 * logged out even though the session was untouched -- /cards is a public
 * path in proxy.ts, not an auth boundary). One component, one source of
 * truth for what the bar looks like, so the two states can't drift apart
 * again.
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
          <Link
            href={props.signedIn ? '/collection' : '/cards'}
            className="flex items-center gap-2 font-heading text-xl font-bold text-slate-900"
          >
            <LayersIcon />
            Card inventory
          </Link>

          {props.signedIn && (
            <nav className="hidden items-center gap-1 text-sm md:flex">
              <Link href="/collection" className={navLink}>
                Collection
              </Link>
              <Link href="/add" className={navLink}>
                Add cards
              </Link>
              <Link href="/cards" className={navLink}>
                Browse
              </Link>
              <Link href="/decks" className={navLink}>
                Decks
              </Link>
              <Link href="/lend" className={navLink}>
                Lend
              </Link>
              <Link href="/friends" className={navLink}>
                Friends
              </Link>
              <Link href="/locations" className={navLink}>
                Boxes
              </Link>
              <Link href="/inbox" className={navLink}>
                Inbox
                {props.pending ? (
                  <span className="ml-1.5 rounded-full bg-cyan-500 px-1.5 py-0.5 text-xs font-semibold text-white">
                    {props.pending}
                  </span>
                ) : null}
              </Link>
            </nav>
          )}
        </div>

        {props.signedIn ? (
          <form action="/auth/signout" method="post" className="flex items-center gap-3">
            <span className="hidden text-sm text-slate-500 sm:inline">{props.accountLabel}</span>
            <button type="submit" className="text-sm text-slate-500 hover:text-slate-900 hover:underline">
              Sign out
            </button>
          </form>
        ) : (
          <Link href="/login" className="text-sm font-medium text-slate-700 hover:text-cyan-700 hover:underline">
            Sign in
          </Link>
        )}
      </div>
    </header>
  )
}
