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

The OAuth token lives in the shared login Keychain, and `CLAUDE_CONFIG_DIR` does
**not** redirect it — so a session launched there would use whichever account is
globally live, not the one you named. Rather than silently run the wrong account,
`run` refuses when the profile isn't the live one and points you at `activate`.
Concurrent accounts therefore work on Linux/WSL, not on macOS.

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
- **The palette** (the `GLOBAL ·` chip) is one place to switch accounts, read all
  limits, and set preferences: reset display (**countdown** / **clock** /
  **total**), grey bias, and severity intensity. Reset display is remembered in
  the browser.
- **The session log** records everything the page did since you opened it —
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
format is `u5 u7 uts r5 r7` in `~/.claude-profiles/<name>/.usage`.

## Files

- `claudius` — the CLI/TUI engine (Bash + embedded Ruby)
- `claude-dashboard.rb` — the localhost dashboard sidecar (Ruby stdlib only)
- `dashboard.html` — the dashboard page (HTML/CSS/JS), rendered by the sidecar
- `statusline.sh` — the shared status line (usage display + free cache warming)
- `statusline-usage-cache.js` — filter to warm the cache from your own status line
- `install.sh` — portable installer
- `tests/share.sh` — sandbox tests for the shared-session wiring (throwaway `HOME`)
