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
claudius add [name]           add a new profile (interactive browser login)
claudius serve [--port N] [--open]
                              run the localhost dashboard (browser tab)
claudius help | -h            show this help
```

`--json` output is the stable contract the dashboard consumes.

## Dashboard

```bash
claudius serve --open
```

Serves a self-contained page on `127.0.0.1` **only** (never the LAN) with a card
per account: identity, subscription badge, 5h/7d usage bars, **reset times**,
cache age, and per-card **Refresh** / **Activate** buttons. Mutations shell back
into the CLI so the terminal and the dashboard always agree. No account tokens are
ever included in any API response.

- **Reset times** show under each usage bar. Click any reset line (or the
  **reset:** button in the toolbar) to cycle how it is displayed: live
  **countdown** → absolute **clock** → **total** remaining. The choice is
  remembered in the browser.
- **Refresh is not free.** Each **Refresh** / **Refresh all** spends a small Haiku
  API call (and may renew a token) to read live limits — the dashboard says so.
  **Auto-poll** only re-reads the local cache, which is free; it never refreshes on
  a timer.
- The page markup lives in `dashboard.html` (edit it directly); the sidecar reads
  that file and injects only a CSRF token + the profile root at serve time.

## Keeping usage fresh for free (optional)

`claudius refresh` costs one Haiku call per account. But Claude Code already hands
your **status line** this session's live rate limits for free, on every render.
`statusline-usage-cache.js` mirrors those into claudius's cache
(`~/.claude-profiles/<name>/.usage`, format `u5 u7 uts r5 r7`) so any account you
have a **live session** open for keeps its own dashboard card current with **no
extra API calls**. It's keyed off each session's config dir, so parallel sessions
(the default `~/.claude` plus any `CLAUDE_CONFIG_DIR` profiles) each refresh their
own profile. Accounts with no open session still need a manual `claudius refresh`.

It's a **pass-through filter**: it reads the status line JSON, writes the cache,
and re-emits the JSON unchanged — so you chain it in front of your existing status
line and see no difference. Enable it in `settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "node ~/.claudius/statusline-usage-cache.js | <your existing statusline command>"
  }
}
```

If you have no status line yet, just the left side works (it warms the cache and
echoes the JSON). Node ships with Claude Code, so there's nothing to install. The
filter is best-effort and swallows all errors — it can never slow or break your
status line.

## Files

- `claudius` — the CLI/TUI engine (Bash + embedded Ruby)
- `claude-dashboard.rb` — the localhost dashboard sidecar (Ruby stdlib only)
- `dashboard.html` — the dashboard page (HTML/CSS/JS), rendered by the sidecar
- `statusline-usage-cache.js` — optional status-line filter that warms the cache free
- `install.sh` — portable installer
