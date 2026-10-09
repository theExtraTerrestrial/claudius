# claudius — the full guide

Everything the [README](../README.md) leaves out: every command, how the
ranking and the burn rate are worked out, how sessions are shared between
accounts, the macOS Keychain story, the agents board and the status line.
Why it is built the way it is lives in [internals.md](internals.md).

## Commands

```
claudius                      launch the interactive TUI (default)
claudius list [--json]        list profiles + cached usage (+ active flag)
claudius status [--json]      show the active profile's live identity + usage
claudius next [--explain]     print the account with the most room left
claudius history [profile] [--json] [--points N]
                              usage over time: burn rate + when you hit a limit
claudius sessions [--json] [--limit N]
                              list the shared session pool, newest first
claudius agents [--json] [--all]
                              board of Claude Code's background agents across
                              every account: open, read, start, stop, remove
claudius agents new [--profile P|auto] [--name N] [--worktree W|--no-worktree] <msg>
                              start a background agent (default: the account
                              'next' picks, in a new worktree named after it)
claudius agents show <id>     what an agent did: the conversation, readable
claudius agents attach|logs|stop|rm <id>
                              the same, through the account that owns <id>
claudius refresh <profile>    renew token if needed & rewrite the usage cache
claudius activate <profile>   switch the global ~/.claude to <profile>
claudius run [profile] [args] open a session in <profile> without switching
                              the global account (no profile = pick one)
claudius link <profile>       (re)wire a profile for shared sessions only
claudius add [name] [--no-activate]
                              add a new profile (interactive browser login)
claudius relogin <profile>    sign in again into a profile whose token cannot be
                              renewed any more (keeps the profile and its history)
claudius remove <profile>     delete a stored profile (does not sign you out)
claudius serve [--port N] [--open]
                              run the localhost dashboard (browser tab)
claudius statusline [--remove] enable (or remove) the team status line in Claude Code
claudius help | -h            show this help
```

`--json` output is the stable contract the dashboard consumes.

## Which account now?

That is the question having several accounts creates, and `next` answers it in
one word, so it composes:

```bash
claudius run "$(claudius next)"      # open a session on whichever has most room
claudius next --explain              # the ranking, and why each account placed
```

Headroom is the **smaller** of the two windows: 4% left on the 7d is 4% left,
however empty the 5h looks. Accounts within five points of each other are
treated as equal — that difference is noise — and the tie goes to the fresher
reading, then the idler account, then the one already active, because not
switching is free. An account behind a window at 100% is not a candidate at
all; an imminent reset is deliberately not credited as headroom, since that
would hand `run` an account still walled off for the next few minutes. When
nothing is usable the answer is the wait, not a name: `next` exits 1 and says
on stderr which account clears first and when.

## Usage over time

`.usage` is one line, overwritten — a snapshot. `.usage.log` beside it is the
same reading appended over time, which is what makes a **burn rate** and a
projection possible:

```
client
    5h   67%  ▄▄▄▄▅▅▅▅▅                 +51.5%/h    → 100% around 01:20
    7d   21%  ▂▂▂▂▂▂▂▂▂                 too little history
```

It costs **no API calls**. The status line is handed this session's live limits
free on every render, so history accumulates while you work; a sample lands at
most every two minutes. The file is bounded without the appenders knowing how:
they only ever add a line, and the reader keeps the last six hours at full
resolution, thins anything older to one sample per quarter hour, and drops
everything past eight days.

A rate is measured over the **current** window only, identified by its reset
epoch — that value sits still inside a window and jumps when the window rolls,
so it separates them exactly, where guessing from a drop in utilization would
not. Nothing is claimed without enough history to divide by, and a ceiling that
lands after the window resets is not reported, because it is not a ceiling you
will hit.

## Several accounts at once (`run`)

`activate` switches the **one** global account that every `claude` then uses.
`run` leaves that alone and opens a session **in** a profile, so you can have
several accounts working at the same time in different terminals:

```bash
claudius run work                  # interactive session on the 'work' account
claudius run work --model sonnet    # extra args go straight to `claude`
claudius run                        # no name → pick from a list
```

It never touches the global `~/.claude` session, the active-profile marker, or
your live token. Under the hood it points `CLAUDE_CONFIG_DIR` at the profile's
own dir and `exec`s `claude`, so signals, exit codes and the TTY behave exactly
as they do for a bare `claude`. In the TUI, press **`o`** on a profile to do the
same thing.

### Your work follows you across accounts

A config dir is normally a clean slate — which would mean no agents, no slash
commands and, worse, **no conversation history**, so `claude -c` / `--resume`
would come up empty. So `run` wires each profile to **share your global
`~/.claude`** as one pool:

| shared (symlinked into the profile) | private to each profile |
| --- | --- |
| `projects/` — transcripts, so `-c`/`--resume` see sessions from **any** account | `.credentials.json` — the OAuth token |
| `history.jsonl` — one `↑` prompt history | `.claude.json` — the account identity |
| `agents/`, `commands/`, `skills/`, `CLAUDE.md`, `plugins/` | `settings.json` — merged, not linked (see below) |
| session state: `sessions/`, `file-history/`, `plans/`, `tasks/`, … | `.usage`, `backups/`, daemon/lock runtime files |

Because the pool **is** `~/.claude`, a session started by plain `claude`
participates too — start work under one account and resume it under another.

It's a denylist, so anything Claude Code adds to `~/.claude` in future is shared
automatically rather than silently missing. Two things are merged rather than
linked, because they must stay per-profile files:

- **`settings.json`** — global keys (permissions, hooks, env, model defaults)
  fill any gap on first wiring, while the profile's own keys win, so each keeps
  its own `statusLine`. Backed up once as `settings.json.claudius-bak`.
- **the `projects` key of `.claude.json`** — per-repo trust ("do you trust this
  folder?"), `allowedTools` and project MCP servers are copied across on every
  launch for paths the profile lacks, so run sessions don't re-prompt. Your
  `oauthAccount` is never touched.

Wiring happens on a profile's first `run` (and at `add` time for new profiles).
`claudius link <profile>` does it on demand and is idempotent. If a profile
already has its own `projects/` or `history.jsonl`, claudius folds it into the
pool **without asking**, sets the old copy aside as `<name>.pre-share.bak`, and
replaces it with a symlink, saying so in one line. Nothing is deleted, so there
is nothing to confirm.

A few files are never shared, because Claude Code keeps them per config dir:
`policy-limits.json` and `remote-settings.json` belong to the signed-in account's
organisation, and caches such as `gh-pr-status-cache.json` are rewritten in place,
which no symlink survives. A link an older claudius made to one of these is
removed on the next `run` (the link only; the pool's file stays). Any other file
that was shared once and comes back as a plain file is left the profile's own,
rather than being merged again every session.

Sharing is unconditional — there is no opt-out flag, because separating your
work is not what multiple accounts are for. If you need a genuinely private
config dir, point `CLAUDE_CONFIG_DIR` at a directory claudius doesn't manage.

### macOS

The OAuth token lives in the login Keychain rather than in a file, but Claude Code
**scopes that Keychain item per config dir** — the service name carries a hash of
the dir (`Claude Code-credentials-<8 hex>`). So `run` can hand a profile its own
credential, and concurrent accounts work here too, not just on Linux/WSL.

Which credential a run session gets depends on the account:

| the profile is… | credential | why |
| --- | --- | --- |
| the **live** account | the shared live item | one credential for both sessions, so a refresh renews rather than forks it — this is what stops a run session from rotating the live session's single-use refresh token and logging it out |
| a **different** account | the profile's own item, seeded from its `.credentials.json` | that account's refresh chain is independent, so the session can renew freely |

Two caveats worth knowing:

- It needs **claude 2.1.220 or newer**. Below that, `run` refuses a non-live
  profile and points you at `activate`, rather than opening the wrong account.
- If claudius cannot tell which account is live (`claude auth status` unavailable
  *and* no identity saved for the profile), it refuses rather than guess — the two
  ways of guessing wrong are "wrong identity" and "logged out".

Because the Keychain is the primary store and wins over the file, a run session's
refreshed token lands in the profile's own Keychain item and Claude Code deletes
the plaintext copy. claudius syncs it back when the session exits, and `activate`
and the usage refresh recover it too, so the profile is never left looking
credential-less.

## Parallel work (`agents`)

Claude Code runs agents in the background (`claude --bg`), each optionally in its
own git worktree, and lists them with `claude agents`. Because `run` shares
`sessions/` and `jobs/` across profiles, that one list already holds the agents of
**every** account — what it does not say is which account each runs on, and that
matters: every config dir has its own supervisor, so attaching, stopping or
reading an agent has to go through the account that owns it.

`claudius agents` is that list made account-aware, as a board:

```
  Agents   1 need you · 2 working · 3 idle · 4 finished  +6 older
  next account: personal — 82% left on the 7d
  ───────────────────────────────────────────────────────────────────
  ➜ 09161075 refund flow edge case             work*      needs you  44m
             ↳ Should partial refunds keep the original tax?
  ● 3f1c0a92 login timeout                      client     working     2m
             ↳ running the auth specs
  ✓ 0aef439b release notes for 4.2              client     done        1d
             ↳ PR is open and came through review clean
```

Agents that need you sort first; the second line is what the agent last reported,
so you can review it without opening it. `⏎` opens one (through its own account),
`n` starts a new one, `s` stops, `x` removes (and its worktree, when that is
safe), `a` shows the older finished ones. The board refreshes itself every few
seconds.

`l` reads what an agent did: its conversation from the transcript, your messages,
Claude's replies, one line per tool call and the ones that failed, opened at the
latest turn. It works for terminal sessions too, so you can catch up on one
without switching to it. (`claudius agents show <id>` prints the same;
`agents logs <id>` is Claude Code's raw terminal capture, which is not meant for
reading.)

`n` opens on the list of your profiles, with email and room left, in `next`'s
order with the cursor on the first; pick one with ↑↓ (an account at its limit is
dimmed but still yours to choose). Then type the task and a first message. The
last screen shows it all, with the account still changeable, and `w` decides
whether the agent gets **its own worktree** (the default inside a repo, named
after the task) or works in **this checkout** alongside whatever else is on that
branch. The same from a script:

```
claudius agents new "fix the login timeout"          # account: auto
claudius agents new --profile work --no-worktree "update the changelog"
```

claudius records nothing for this. Ownership is read back from Claude Code's own
files: a live supervisor's roster, the job's record of the config dir it was
dispatched from, an interactive session's environment. A `*` marks an agent on
the global `~/.claude`, which is whichever account is live. Interactive sessions
are listed too, marked `[terminal]`; they live in the terminal that started them
and are not opened from here.

## Dashboard

```bash
claudius serve --open
```

Serves a page on `127.0.0.1` **only** (never the LAN). Mutations shell back into
the CLI so the terminal and the dashboard always agree, and no account tokens are
ever included in any API response.

**The global account gets a hero.** Both windows at full size, its usage figure
and its reset time as equals — because at 12% the percentage is the story and at
100% only the reset is. The other profiles sit below as compact cards showing the
5h window plus a five-pip band for the 7d. Press **Use** on one and it flies into
the hero slot as the switch lands.

- **Usage and reset are one reading.** Each window shows both figures on one
  baseline, plus two lanes: how much you've used, and how far through the window
  you are. The gap between them is your burn rate. When a window hits its ceiling
  the block gives itself over to one fact — when it clears.
- **Every profile gets its own animated field**, one of eight pure-CSS
  backgrounds, and the page's ambient background takes the *active* profile's
  field. The motion is a reading, not decoration: it speeds up as a limit
  approaches and **stops dead** at the ceiling. Use the kebab to pin or shuffle a
  card's style if two land on the same one.
- **Reading live limits is not free.** Each one spends a small Haiku API call (and
  may renew a token); the price rides on the control that spends it, and the
  footer keeps a running tally. **Watch cache** only re-reads the local cache on a
  30-second ring — that part is free and never calls the API.
- **The burn rate is named, not just implied.** Under each window, the rate per
  hour and — when the ceiling arrives before the window clears — roughly when,
  reddening as it nears. A sparkline beside it carries the shape, on a fixed
  0–100 scale so a flat 3% week and a flat 90% week never draw the same line.
  With too little history to divide by, none of it is drawn: empty space beats a
  half-answer.
- **One card is chipped `use next`** — the account `claudius next` would pick,
  ranked by the same rules in the same place, so the page and the terminal can
  never disagree. When it is the account you are already on, it says so instead.
- **Adding an account happens here now.** A ghost slot under the cards takes a
  name, opens the Anthropic sign-in in a new tab, and takes a pasted code if the
  page shows you one. It runs the same `claudius add` — the sidecar just holds the
  door open, watches for the credentials to appear, and answers the trailing
  prompt for you. A sign-in you abandon is cleaned up after ten minutes, and
  unlike the terminal flow it leaves your global account alone unless you tick the
  box. The code you paste is written straight to the process and is never logged,
  echoed, or included in any response.
- **An expired account says so on its card, and offers the way back.** A lapsed
  token is routine — its refresh token usually still works — so the card first
  offers **Refresh**, with **Sign in again** beside it. Only once a refresh has
  actually failed does it call the account signed out and offer sign-in alone.
  That runs `claudius relogin` through the same panel the sign-in above uses.
  The profile keeps everything it had — its name, its card style, its usage
  history, its wiring — and only the credential is replaced. A relogin you
  cancel or abandon puts the old credential back: the opposite cleanup from an
  add, which removes what it made. Signing in again from inside Claude Code
  (`/login`) is picked up too: the live account's card does not read as
  expired, and the next refresh copies the new credential into the profile.
- **The tab title is a reading.** It shows the active account's 5h and 7d
  usage with a severity dot — `🟢 34% · 41% — work` — numbers first, because a
  crowded tab bar keeps only the start of a title. When a window is full it
  says when it clears instead: `⛔ 5h full · clears in 28m — research`.
- **Hover a countdown to see the date.** Every time on the page is relative —
  "resets in 3d 11h", "100% at 11:10" — which is the right reading at a glance
  and a poor one when you are planning around it, because "11:10" does not say
  which day. Hovering any of them gives the full date and time, with the
  countdown underneath. The same tooltip serves every control that has something
  to say about itself, in the page's own type rather than the browser's.
- **The palette** (the `GLOBAL ·` chip) is one place to switch accounts, read all
  limits, and set preferences: reset display (**countdown** / **clock** /
  **total**), colour bias, and contrast intensity. All three are remembered in
  the browser, along with the card styles, the watch toggle and the session
  filters.
- **The log** records everything the page did since you opened it —
  every live read with its result, every free cache re-read, every switch — each
  row priced, so the cost history sits beside the tally.
- The page markup lives in `dashboard.html` (edit it directly); the sidecar reads
  that file and injects only a CSRF token + the profile root at serve time. Fonts
  and icons come from Google Fonts, so the page wants a network connection. Its
  header comment carries the design rules — read them before editing.

The dashboard is a **monitor with a few actions**, not a full front-end: `remove`
and `statusline` stay CLI-only for now (`add` and `relogin` are not — both drive
their browser sign-in from the page). See `.scratch/front_end/`.

## Status line

Two windows of usage (5h/7d) with reset countdowns, right in your prompt — and a
free side effect: it **warms the usage cache** so the dashboard stays current with
**no extra API calls**. (`claudius refresh` costs one Haiku call per account;
Claude Code hands the status line this session's live limits for free on every
render.) Cache warming is keyed off each session's config dir, so parallel sessions
— the default `~/.claude` plus any `CLAUDE_CONFIG_DIR` profiles — each refresh
their own profile. Accounts with no open session still need a manual
`claudius refresh`.

**Option A — use the shared status line** (recommended). Shows `[model] · context ·
5h/7d`, and includes cache warming. It writes `statusLine` into your global
`~/.claude/settings.json` and every profile's `settings.json` (backing each up
once, preserving other keys):

```bash
claudius statusline           # enable    (or: bash ~/.claudius/install.sh --statusline)
claudius statusline --remove  # undo (only removes ours — never a status line you set)
```

**Option B — keep your own status line, take just the cache bonus.** Chain the
pass-through filter in front of it — it reads the status line JSON, writes the
cache, and re-emits the JSON unchanged, so you see no difference:

```json
{
  "statusLine": {
    "type": "command",
    "command": "node ~/.claudius/statusline-usage-cache.js | <your existing statusline command>"
  }
}
```

Both are best-effort and swallow all errors — cache writing can never slow or break
your status line. Node ships with Claude Code, so there's nothing to install. Cache
format is `u5 u7 uts r5 r7` in `~/.claude-profiles/<name>/.usage`, and each reading
is also appended to `.usage.log` as `ts u5 u7 r5 r7` (at most one sample every two
minutes) — that log is what `claudius history` and the dashboard's burn rate read.

## Files

- `claudius` — the CLI/TUI engine (Bash + embedded Ruby)
- `claude-dashboard.rb` — the localhost dashboard sidecar (Ruby stdlib only)
- `dashboard.html` — the dashboard page (HTML/CSS/JS), rendered by the sidecar
- `statusline.sh` — the shared status line (usage display + free cache warming)
- `statusline-usage-cache.js` — filter to warm the cache from your own status line
- `install.sh` — portable installer
- `docs/guide.md` — this guide; `docs/internals.md` — the reasoning behind it
- `docs/img/` — README screenshots, taken from invented demo accounts
- `tests/run-scope.sh` — `run`'s credential scoping and the Keychain bridge (stubbed)
- `tests/agents.sh` — the agents board, routed through a stub `claude`
- `tests/share.sh` — sandbox tests for the shared-session wiring (throwaway `HOME`)
- `tests/dashboard.sh` — the page's own logic, run under node against stubs
- `tests/dashboard-live.sh` — the page driven in a headless browser, read-only
- `tests/history.sh` — the burn-rate arithmetic and the ranking (throwaway `HOME`)
- `tests/add.sh` — the browser add flow, driven against a stub CLI (no real login)
