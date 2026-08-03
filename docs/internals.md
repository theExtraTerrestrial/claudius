# Internals

Why claudius is built the way it is. `CLAUDE.md` states the rules; this document
is the reasoning behind them, for when a rule looks arbitrary or you are deciding
whether a new case falls under it.

`README.md` covers what the tool does from the outside.

## Why the sandbox rule is absolute

This repo's entire job is moving credentials, identity files and session state
between directories. That makes a careless invocation qualitatively different
from a careless invocation in most projects: the failure is not a red test, it is
your live session.

A bare `claudius activate` during development swaps the account under every
running `claude` — including the one you are working in. A bare `refresh` spends
a real API call and can rewrite a real token. `remove` deletes a profile
directory. None of these announce themselves as destructive at the call site.

So `tests/share.sh` builds a complete fake `HOME` — a plausible `~/.claude` pool,
profiles with fabricated tokens, a global identity file — and points claudius at
it. The last assertion in the suite exists purely to catch a leak: it checks that
no symlink anywhere in the sandbox resolves back into the real home. If you add
tests, keep that check last and keep it passing.

One wrinkle worth knowing: the `ruby` on the development machine is an asdf shim
that resolves its installation relative to `$HOME`, so a fake `HOME` breaks the
interpreter itself. The suite passes `ASDF_DATA_DIR` through to the real location
for that reason. On a system without asdf it is a harmless no-op.

## Why bash 3.2

Apple has shipped bash 3.2 since 2007 and will not ship a newer one for licensing
reasons. `install.sh` supports macOS, so the engine has to run there.

The constructs banned in `CLAUDE.md` are banned because their failures are quiet
rather than loud:

- `${var,,}` is a **syntax error** in 3.2, which takes down the whole file at
  parse time, not at the line that uses it.
- `read -t 0.05` fails with "invalid timeout specification" — which, in the TUI's
  escape-sequence reader, turns every arrow key into garbage. See
  `ESC_SEQ_TIMEOUT`: bash 4+ gets 0.05s, 3.2 falls back to 1s. That sounds bad
  but is not, because arrow-key sequences arrive as a burst already sitting in
  the tty buffer and so still read instantly; only a lone `ESC` waits.
- `sed -i` on BSD treats the next argument as a backup suffix, so
  `sed -i 's/a/b/' f` silently consumes the script as the suffix and then fails
  on a missing file operand.
- `stat -c`, `date -d`, `readlink -f` and `grep -P` simply do not exist on BSD.

When a task genuinely needs an associative array or structured parsing, that is
the signal to use Ruby rather than to write clever bash. The file already does
this in about a dozen places with a `ruby - "$arg" <<'RB'` heredoc.

## Why the engine must stay source-safe

`claudius` does not set `set -euo pipefail` or install an `EXIT` trap at the top
level. Both go inside `main()`.

This is not an oversight and should not be "fixed". The script can be sourced,
and `tests/share.sh` depends on that — it sources the file with a harmless `help`
argument to load the function definitions, then calls `wire_profile_sharing`,
`merge_profile_settings` and friends directly, which is the only way to test them
in isolation.

If the options were set at top level they would leak into the sourcing shell. For
the test suite that means one failed command aborts the run; for a user who has
sourced the script into an interactive shell, a later `exit` would close their
terminal.

## Why Ruby, and only Ruby

The original constraint was to avoid requiring both `python3` and `curl`, which
are inconsistently present across macOS and Linux distributions. Ruby ships with
macOS, is one `apt install` away on Linux, and its stdlib covers everything
needed: `json` for parsing, `net/http` for the OAuth refresh, `webrick` for the
dashboard, `securerandom` for the CSRF token.

`webrick` is the one thing that is not stdlib on Ruby 3.0+, where it was moved
out to a gem. It is required only by `claudius serve`, so it is checked at
runtime rather than at startup, and the error message names the install command.
Everything else must work with a bare interpreter.

## The three contracts

Each of these is read by code that does not live in the file that writes it, so a
change to shape breaks something silently rather than loudly.

**`claudius list --json`** (`list_profiles_json`) is what the dashboard consumes.
`r5` and `r7` — the reset epochs — were added after the original five fields, so
caches written by an older version lack them entirely. Anything reading them must
handle null rather than assuming a number.

**`.usage`** is written from two directions: `claudius refresh`, which costs a
Haiku call, and the status line, which gets the same figures free on every render
as a side effect of Claude Code handing them to it. Both must agree on the
format. The `-` placeholder matters more than it looks: the file is read with a
positional `read -r RU5 RU7 RUTS`, so omitting an absent window rather than
writing `-` would shift every later field one position left, silently turning a
timestamp into a usage percentage.

**`dashboard.html`** is served nearly byte-for-byte. The sidecar substitutes
`{{TOKEN}}` and `{{ROOT}}` and does nothing else — no templating engine, no
partials, no build step. This is deliberate: the page can be opened directly from
disk while working on it, and there is exactly one file to look at when
something renders wrong.

### Two states that look like bugs and are not

Real accounts report usage **above 100** — 102 and 103 have both been observed
live. Clamp for display, but do not treat the value as invalid or assume 100 is a
ceiling.

There may be **no active profile at all**, when the global `~/.claude` holds an
account that matches no stored profile. The dashboard must render that honestly
rather than promoting an arbitrary profile to "global account", which is a
straightforward lie about the system's state.

## Security posture

The dashboard serves account identity and usage, and shells into a CLI that can
switch credentials. Three properties keep that acceptable:

**It binds `127.0.0.1` only, and the bind address is not configurable.** Making
it configurable would be a one-line change and is exactly the wrong instinct —
the intended model is that each person runs their own instance locally.

**No token ever crosses the API boundary.** Responses carry identity (email, org,
subscription) and usage figures. The credential itself has no reason to leave the
filesystem, and the moment it appears in a response it also appears in logs and
in browser devtools.

**Both mutating endpoints require `X-CSRF-Token`**, matched against a token
generated fresh per run (`SecureRandom.hex(16)`) and injected into the page at
serve time. Without it, any page in the browser could POST to localhost and
switch the user's account.

Mutations shell back into the bash CLI rather than reimplementing the logic. The
alternative — a Ruby `activate` — would be a second implementation of the most
dangerous operation in the project, free to drift from the first.

## Testing reality

`tests/share.sh` covers the sharing and wiring logic, which is where the data-loss
risk lives: link targets, idempotence, the `settings.json` merge, the
`projects`-key sync, collision handling and refusals, and that `rm -rf` on a wired
profile leaves the shared pool intact.

Nothing covers the TUI or the dashboard. The TUI needs a pty and raw-mode input;
the dashboard needs a browser. Both are checked by hand, which means changes to
either deserve more scepticism, not less.

`tests/run-scope.sh` covers `run`'s macOS credential scoping: the per-config-dir
service name, the write-back sync, which scope `run_profile` picks, and the cases
it refuses. Both suites stub `security` rather than reach the real login Keychain —
`share.sh` via a file-backed stand-in on `PATH` (claudius invokes `security`
unqualified), `run-scope.sh` by overriding the bridge functions. Anything that
writes a real Keychain item does not belong in a test.

Beware the class of bug that hid in `share.sh` for a while: on a Mac,
`keychain_available()` is genuinely true, so tests written for the file path took
the Keychain branch and failed for reasons unrelated to what they meant to assert.
Tests touching credentials must state the platform they mean — stub
`keychain_available` explicitly rather than inheriting whatever the host is.

What is verified and what is not: the service-name scheme is confirmed, since the
name claudius derives for a profile dir matches a `Claude Code-credentials-<hash>`
item Claude Code created on its own. Two accounts running concurrently has NOT
been observed — it needs a second account. Describe that as reasoned, not verified.

## Sharing model

`run` points `CLAUDE_CONFIG_DIR` at a profile's own directory. A config dir is
normally a clean slate, which would mean no agents, no commands and no
conversation history — so `claude -c` and `--resume` would come up empty, which
makes the feature close to useless in practice.

So each profile is wired to share the global `~/.claude` as a single pool:
transcripts, prompt history, assets and session state are symlinked in, while
identity, token and settings stay the profile's own. Because the pool *is*
`~/.claude`, a plain `claude` session participates too — you can start work under
one account and resume it under another.

The share list is a **denylist**, not an allowlist: anything Claude Code adds to
`~/.claude` in future is shared automatically rather than silently missing. Two
things are merged rather than linked because they must remain per-profile files —
`settings.json` (global keys fill gaps, the profile's keys win, so each keeps its
own `statusLine`) and the `projects` key of `.claude.json` (per-repo trust and
`allowedTools`, so run sessions do not re-prompt).

A consequence worth knowing when working on `remove`: deleting a wired profile is
safer than it looks. The pooled directories are symlinks, so `rm -rf` on the
profile takes the links and leaves the pool intact. What is actually lost is the
profile's token and identity, and the account can be re-added.

## Credential scope on macOS

The token is not a file here — it is a login-Keychain item — and for a long time
that was taken to mean `run` could not work on macOS at all: `CLAUDE_CONFIG_DIR`
does not redirect the Keychain, so a session launched under a profile would
authenticate as whatever account was globally live. `run` refused rather than do
that silently.

That premise expired. Claude Code derives the Keychain **service name from the
config dir** — `Claude Code-credentials-<first 8 hex of sha256(dir)>`, and the bare
name only when no config dir is set. So the credential can be per-profile after
all, and `keychain_service_for_dir` reproduces that scheme.

`run` therefore picks a *credential scope*:

- **shared** when the profile is the live account. Both sessions use the one item,
  so an in-session refresh renews the credential instead of forking it. This is the
  important half: OAuth refresh tokens are single-use, so a run session refreshing
  its own private copy of the live account's chain logs the live session out. The
  empty string (not "unset") in `CLAUDE_SECURESTORAGE_CONFIG_DIR` selects it —
  the CLI reads unset and empty differently, and empty means "the default dir".
- **isolated** otherwise: the profile's own item, seeded from its
  `.credentials.json` before launch. Seeding is mandatory rather than an
  optimisation, because the Keychain is the primary store and a stale item left by
  an earlier session would shadow the credential just prepared.

Two consequences fall out of the CLI's storage layer being a composite — Keychain
primary, plaintext `.credentials.json` fallback:

1. A successful Keychain write **deletes the plaintext copy**. So a run session
   migrates the token out of the file claudius treats as its source of truth.
   `sync_profile_creds_from_keychain` brings it back, which is also why the
   isolated path does not `exec`: claudius has to outlive the session to run it.
   `activate` and the usage refresh call it too, so a profile is never left
   looking credential-less.
2. The fallback means a missing namespaced item degrades to reading the profile's
   own file rather than to reading the wrong account. That is the safety net if a
   future release changes the hash scheme, and the reason the version guard
   (`RUN_ISOLATION_MIN_VERSION`) is a refusal rather than a silent best-effort.

### The refresh lock follows the credential

The CLI serialises token refreshes with a lock at
`<credential storage dir>/.oauth_refresh.lock` — and that directory is the one
`CLAUDE_SECURESTORAGE_CONFIG_DIR` resolves, not the config dir. So the single
variable moves the credential *and* the lock together, which is what makes shared
scope safe rather than merely convenient: a run session on the live account takes
the same `~/.claude/.oauth_refresh.lock` a bare `claude` takes, so the two
serialise before either refreshes the credential they share. Two processes sharing
one credential but locking different files would both race to spend the same
single-use refresh token.

This is why the sharing denylist's `*.lock` pattern is load-bearing, not
housekeeping. If the pool's `.oauth_refresh.lock` were symlinked into a profile, an
isolated session would lock the LIVE lock file and contend with the live session
over an unrelated refresh chain. `tests/share.sh` asserts it stays unlinked.

When identities cannot be resolved, `run` refuses. Guessing has two failure modes —
running the wrong account, or logging the live session out — and neither is worth
trading for the convenience of proceeding.

The rejected alternative was `CLAUDE_CODE_OAUTH_TOKEN`, which short-circuits the
whole storage layer and is a documented env var. It hands over an access token with
no refresh token, so the session cannot renew and dies when the token expires a few
hours in. Fine for a `-p` one-shot, wrong for the interactive sessions `run` is for.

### Which Keychain item `add` reads

`cmd_add` runs the sign-in isolated — `CLAUDE_CONFIG_DIR=$dir claude auth login` —
so on a namespacing CLI the new account's token lands in THAT dir's item while the
shared item still holds the live account. `materialize_profile_credentials`
therefore reads the namespaced item first and only falls back to the shared one on
a CLI too old to namespace.

Reading the shared item first is the bug this replaced, and it was invisible:
the new profile would get a copy of the LIVE credential, `credentials_ready` would
pass (it only checks that some `accessToken` is present, never whose), `activate`
would succeed, and the account you actually signed into would be stranded in an
item claudius never read. When the namespaced item cannot be read on a modern CLI,
`add` now fails rather than falling back — a failed add is recoverable, a profile
silently bound to the wrong account is not.

The read there gets a 30s budget rather than the default 3s, because `add` is
interactive: if macOS raises a Keychain access prompt there is a human present to
answer it.
