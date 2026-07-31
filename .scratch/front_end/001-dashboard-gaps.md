# 001 — Dashboard: capabilities the CLI has and the page doesn't

**Status:** open · **Opened:** 2026-07-31 · **Area:** `dashboard.html`, `claude-dashboard.rb`

The redesigned dashboard covers monitoring plus three actions: switch account,
read live limits, copy a run command. Four CLI capabilities had no route in the
sidecar and no control on the page — deliberately, since each needed design work
the redesign didn't include, but it meant the page was knowingly not a full
front-end and someone would eventually ask why.

**`add` is now done** (see below). The other three stand.

Each remaining item needs **both** a new endpoint in `claude-dashboard.rb` and a
control on the page. The sidecar shells back into the CLI for all mutations, so
the CLI side already exists in each case.

## Blocked on a real design problem

### ~~`add` — cannot complete inside a POST~~ **CLOSED 2026-08-01**
The job model won, not the punt. Two facts made it worth building rather than
avoiding, and both were unknown when this was written:

1. `claude auth login` does **not** need a TTY. Given a pipe on stdin it prints
   its sign-in URL to stdout and carries on — so the page can hand you the link
   without a terminal emulator anywhere in the picture. (Probed directly; the
   process was killed before any sign-in could complete.)
2. Both upstream variants — the browser handing the terminal the login, and the
   site showing a code to paste — end at the same trailing "press enter". So
   watching the FILESYSTEM for the credentials to appear, and supplying that
   newline from the sidecar, collapses them into one code path. The page needs
   exactly one interactive element, the code field, and it is optional.

What killed the punt: it is the same amount of page for strictly less. The panel
had to exist either way.

Two bugs worth remembering, both found by `tests/add.sh` rather than by reading:
`trap('TERM', &lambda)` never fires (trap passes the signal number, a nil-arity
lambda raises, and the error is swallowed — the sidecar simply stopped shutting
down), and publishing a terminal state before cleanup finished let the page
reload the profile list while a half-made profile was still on disk.

Still deliberately out: `--json` on `add`, and any reuse of the job model for a
second command. One job at a time, one command, until there is a second need.

### `remove` — destructive, needs a confirmation design
`claudius remove` deletes a profile directory. The page has no confirmation
pattern, and the obvious ones are bad: a red button is one misclick from data
loss, and the red→green two-click toggle was already tried and rejected during
the redesign. Note that removal is *safe with respect to the shared pool* — the
profile's `projects/`, `history.jsonl` and assets are symlinks into `~/.claude`,
and `tests/share.sh` §12 proves `rm -rf` on a wired profile leaves the pool
intact. So the real risk is narrower than it looks: what is lost is the profile's
token and identity, and it can be re-added. Say that in the confirmation rather
than making it scary.

## Straightforward, just not done

### `statusline` — enable / remove the shared status line
`claudius statusline [--remove]`. Two-state, idempotent, non-destructive (it only
ever removes a status line it installed). Belongs in the palette under
appearance. The one wrinkle: it writes to the global `settings.json` **and**
every profile's, so the page should report what it touched rather than just
going green.

### `open profile folder`
Wants a `POST /api/reveal`. Worth thinking about whether the sidecar should be
able to launch a file manager at all — it is a localhost service, but "open an
arbitrary path in the desktop shell" is a bigger capability than anything else
it currently has. Lowest value of the four; possibly just drop it.

## Smaller, accepted for now

- **In-flight read has no card indicator.** `readLive` puts its spinner on
  `button[data-live]`, which now only exists inside the kebab — and picking the
  item closes the menu. The card still runs the `reading` pulse and the log
  records the call, so it isn't silent, but there is no explicit busy state on
  the surface itself.
- **Material Symbols degrades to words, not to nothing.** If Google Fonts is
  unreachable the icons render as their ligature text — `more_vert`,
  `content_copy` — which reads as a bug rather than a missing font. Accepted
  because Claude is an online-only service, but a fallback rule would be cheap.
- **Reduced-motion drops the escalation.** `prefers-reduced-motion` disables the
  field animations, so "motion is the reading" silently doesn't apply for those
  users. The numbers still carry it, so this is correct behaviour rather than a
  defect — noted so it isn't rediscovered as one.

## Deferred indefinitely

**Cross-surface consistency** between the TUI and the dashboard. Raised during
the redesign and explicitly deferred: they are different media with different
affordances, and forcing them to match would make both worse.
