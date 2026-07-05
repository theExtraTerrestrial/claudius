# claudius

Manage & monitor multiple Claude accounts from one CLI — list profiles and their
5h/7d usage, switch the active account, and open a localhost dashboard in your
browser. Standardized on **Ruby** (the only non-Bash dependency) so there's no
`python3`/`curl` requirement.

## Install

Clone the repo and run the installer (macOS + Linux):

```bash
git clone https://github.com/OWNER/claudius.git ~/.claudius && bash ~/.claudius/install.sh
```

> Replace `https://github.com/OWNER/claudius.git` with the real repo URL.

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
per account: identity, subscription badge, 5h/7d usage bars, cache age, and
per-card **Refresh** / **Activate** buttons. Mutations shell back into the CLI so
the terminal and the dashboard always agree. No account tokens are ever included
in any API response.

## Files

- `claudius` — the CLI/TUI engine (Bash + embedded Ruby)
- `claude-dashboard.rb` — the localhost dashboard sidecar (Ruby stdlib only)
- `install.sh` — portable installer
