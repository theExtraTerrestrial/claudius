# claudius

Manage & monitor multiple Claude accounts from one CLI — list profiles and their
5h/7d usage, switch the active account, and open a localhost dashboard in your
browser. Standardized on **Ruby** (the only non-Bash dependency) so there's no
`python3`/`curl` requirement.

## Install

Clone the repo and run the installer (macOS + Linux):

```bash
git clone https://github.com/theExtraTerrestrial/claudius.git ~/.claudius && bash ~/.claudius/install.sh
```

Then start a new shell (or `source` your rc) and run `claudius help`.

The installer symlinks `claudius` into `~/.local/bin` (override with `--prefix`)
and adds that dir to your `PATH` if needed. Because it's a symlink to the clone,
**updates are just a `git pull`** — no reinstall:

```bash
git -C ~/.claudius pull
```

Uninstall:

```bash
bash ~/.claudius/install.sh --uninstall
```

## Requirements

- **Ruby** ≥ 2.5 (`sudo apt install ruby` / `brew install ruby`)
- The **`claude`** CLI on your `PATH`
- For `claudius serve`: the **`webrick`** gem (`gem install webrick` — it's a
  separate gem on Ruby 3.0+)

## Usage

```
claudius                      launch the interactive TUI (default)
claudius list [--json]        list profiles + cached usage (+ active flag)
claudius status [--json]      show the active profile's live identity + usage
claudius next [--explain]     print the account with the most room left
claudius history [profile] [--json] [--points N]
                              usage over time: burn rate + when you hit a limit
claudius refresh <profile>    renew token if needed & rewrite the usage cache
claudius activate <profile>   switch the global ~/.claude to <profile>
claudius run [profile] [args] open a claude session in <profile> WITHOUT
                              switching the global account (no name = pick)
claudius link <profile>       (re)wire a profile for shared sessions, no launch
claudius add [name]           add a new profile (interactive browser login)
claudius serve [--port N] [--open]
                              run the localhost dashboard (browser tab)
claudius statusline [--remove] enable (or remove) the shared status line
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
erhards2
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
already has its own `projects/` or `history.jsonl`, claudius **asks first**, then
folds it into the pool, sets the old copy aside as `<name>.pre-share.bak`, and
replaces it with a symlink — nothing is deleted, and a non-interactive run
refuses rather than moving data unasked.

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

The dashboard is a **monitor with a few actions**, not a full front-end: `add`,
`remove` and `statusline` stay CLI-only for now. See `.scratch/front_end/`.

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
- `tests/share.sh` — sandbox tests for the shared-session wiring (throwaway `HOME`)
- `tests/dashboard.sh` — the page's own logic, run under node against stubs
- `tests/dashboard-live.sh` — the page driven in a headless browser, read-only
- `tests/history.sh` — the burn-rate arithmetic and the ranking (throwaway `HOME`)
