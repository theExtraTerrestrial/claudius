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
claudius statusline [--remove] enable (or remove) the shared status line
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
