# claudius — rules

Bash CLI + TUI for switching between Claude accounts, with a localhost dashboard.
Background and reasoning: `docs/internals.md`. Deferred work: `.scratch/`.

## Never touch the real account state

- Run every CLI invocation that mutates under a throwaway `HOME`:
  `HOME="$tmp" bash claudius …`. Never invoke `activate`, `refresh`, `add`,
  `remove`, `link` or `run` bare.
- Never `source claudius` under the real `HOME` either, not even to poke at one
  function. Sourcing runs `main` — with no args that is the TUI, which reads the
  real Keychain and can raise an access prompt. Source it the way the tests do,
  with a throwaway `HOME` and a `help` argument.
- Never run `security` against the real login Keychain from a test, script or
  experiment. Stub it: a fake `security` on `PATH` (claudius calls it unqualified),
  or override `keychain_available` / `read_keychain_creds` / `write_keychain_creds`.
- Copy the sandbox pattern in `tests/share.sh` (`mkhome`); do not invent another.
- `list`, `status` and `GET /api/profiles` are read-only — those are safe bare.
- Never write to `~/.claude`, `~/.claude.json` or `~/.claude-profiles` from a
  test, script or experiment.

## Portability

- Target bash 3.2 and BSD userland (macOS), not just GNU/Linux.
- Do not use: `mapfile`, `readarray`, `declare -A`, `${var,,}`, `${var^^}`,
  fractional `read -t`, `sed -i` without an argument, `grep -P`, `stat -c`,
  `date -d`, `readlink -f`.
- Drop into Ruby (`ruby - "$arg" <<'RB'`) when bash 3.2 makes it awkward.
- Keep `set -euo pipefail` and traps inside `main()` — never at top level. The
  file must stay safe to `source`.

## Dependencies

- Add no dependency beyond Ruby. No `python3`, `curl`, `jq`, or npm packages.
- Use Ruby stdlib only. `webrick` is the sole exception and is guarded at runtime.

## Contracts — extend additively, never reorder or rename

- `claudius list --json` → `{name, email, org, sub, active, u5, u7, uts, r5, r7}`.
  Tolerate null `r5`/`r7`.
- `claudius sessions --json` →
  `[{id, cwd, short, exists, dirkey, label, lsrc, branch, mts, size}]`, newest
  first. `cwd`, `short`, `exists`, `label`, `lsrc` and `branch` are nullable — a
  transcript need not carry any of them. `lsrc` says where `label` came from
  (`title`/`slug`/`prompt`/`last`/`command`); treat an unknown value as a title.
  `short` is `cwd` with `$HOME` written as `~`; `exists` is whether the directory
  is still there. `--limit 0` means the whole pool and is not a mistake.
  Never decode a path from `dirkey`; that encoding is lossy.
- `.usage` → `u5 u7 uts r5 r7`, space-separated. Write `-` for a missing window;
  never omit a field.
- `.usage.log` → one sample per line, `ts u5 u7 r5 r7`, timestamp FIRST (a log is
  read in time order), same `-` discipline. Appenders only ever append one line,
  throttled to 120s, and never rewrite the file — `usage_history_json` is the
  single place its shape is decided, so pruning rules live there and nowhere else.
  Tolerate a torn or junk line: a killed append must not cost the history.
- `claudius history --json` →
  `[{name, n, first, last, rate5, eta5, rate7, eta7, samples:[[ts,u5,u7]…]}]`.
  `rate` is % per hour over the **current** window (segmented by reset epoch, not
  guessed from a drop in utilization) and null when there is too little history to
  divide by. `eta` is null both when the rate is unknown and when the ceiling
  lands after the window resets — null means "nothing to warn about". `--points 0`
  omits `samples` and is a summary-only shape.
- `claudius next --json` → `{pick, reason, blocked_until, first_to_clear, ranked}`.
  `pick` is null when nothing is usable; bare `next` then exits 1 and explains on
  **stderr**, so `$(claudius next)` stays empty instead of feeding `run` a
  sentence. The ranking rules are documented above `next_json` — change them
  there, never in the page, or the terminal and the dashboard will start
  recommending different accounts.
- `POST /api/add` starts a background job; `GET /api/add/status` reports
  `{state, url, needs_code, log, error, profiles?}` where state is
  `running`/`stopping`/`done`/`failed`/`expired`/`cancelled`. Publish a terminal
  state LAST, after cleanup — the page reloads the profile list the moment it sees
  one, and a half-made profile still on disk would read as a real account.
  `stopping` is not terminal and blocks a new job. Success is decided from the
  FILESYSTEM (credentials appearing), never by scraping the child's output.
- `POST /api/add/code` is write-only. The authorization code goes to the child's
  stdin and must never reach a response, a log line or the page — it arrives in
  the request BODY, not the query string, and is scrubbed from the log tail.
- `dashboard.html` → the sidecar substitutes `{{TOKEN}}` and `{{ROOT}}` only.
  Keep the file valid standalone HTML.
- Handle usage values above 100 and the case of no active profile. Both are real.

## Security

- Keep the dashboard bound to `127.0.0.1`. Never make the bind address
  configurable.
- Never put a token, credential or refresh token in an API response, log line,
  error message or test output.
- Require `X-CSRF-Token` on every mutating endpoint.
- Shell back into the bash CLI for mutations. Never reimplement `activate`,
  `refresh` or `add` in Ruby or JS.
- Spawn a long-running child in its OWN process group and signal the group.
  `claudius add` runs `claude auth login` as a child; killing only the bash pid
  leaves that child alive holding the stdin pipe.
- A pipe on the child's stdin, never a pty: a pty echoes, which would put a pasted
  authorization code into the log the page displays. `claude auth login` needs no
  TTY — verified — so there is no reason to reach for one.

## Dashboard

- Read the header comment in `dashboard.html` before editing it. Follow its
  design rules and the three traps it lists.
- Verify by serving the page, not by reading the diff:
  `ruby claude-dashboard.rb --port 8799 --root "$HOME/.claude-profiles" --script "$PWD/claudius"`
- Stop the server and confirm the port is closed when done. Check for a dashboard
  already running on another port first and leave it alone — it is probably the
  user's.
- **Look at the page.** Chromium ships with Playwright's cache; a visual change is
  not verified until it has been seen:
  ```
  CHROME=~/.cache/ms-playwright/chromium-*/chrome-linux64/chrome
  $CHROME --headless=new --disable-gpu --no-sandbox --hide-scrollbars \
    --window-size=1320,1500 --virtual-time-budget=6000 \
    --screenshot=/tmp/dash.png http://127.0.0.1:8799/
  convert /tmp/dash.png -crop 1100x360+110+640 +repage -resize 150% /tmp/crop.png
  ```
  Crop to the region under review — full-page shots are too coarse to judge
  spacing. Bar fills animate, so a shot taken under a short virtual-time budget
  can show them empty; that is the screenshot, not the page.
- To photograph a state that needs interaction (a filled search box, an open
  filter), copy `claude-dashboard.rb` and the page to a scratch directory, seed the
  state in the copy, and serve that on another port. Never edit the real page to
  take a picture.

## Tests

- Run `bash tests/share.sh` (97 assertions, ~20s) before any change to
  `wire_profile_sharing`, `merge_profile_settings`, `sync_profile_projects_key`,
  `link` or `run`.
- Run `bash tests/run-scope.sh` (53 assertions) before any change to `run`'s
  credential scoping, the Keychain bridge, `run_prepare_token`, or
  `materialize_profile_credentials`.
- A test that touches credentials must state its platform — stub
  `keychain_available` explicitly. On a Mac it is true by default, so a test
  written for the file path silently takes the Keychain branch instead.
- Two accounts running concurrently on macOS is observed working on claude
  2.1.220. Still unobserved, so describe as reasoned: the fallback for a CLI too
  old to namespace the Keychain item, and the refusal paths.
- Run `bash tests/dashboard.sh` (143 assertions, ~1s) after any change to
  `dashboard.html`. It slices the page's `<script>` blocks by their `═══ banner ═══`
  section comments and runs the pure logic under node against stubbed storage and
  DOM. Renaming a banner breaks extraction loudly and on purpose — fix the test's
  `want` list rather than letting it test nothing. node is not a claudius
  dependency: the suite skips when it is absent.
- Run `bash tests/dashboard-live.sh` (28 assertions, ~25s) for anything touching the
  session panel, the filters or the keyboard. It starts its own sidecar and a
  headless Chromium and drives the real page over the DevTools protocol — the layer
  that caught a `cd` into the wrong directory and an encoded path leaking on screen.
  Read-only: it never clicks anything that mutates. It skips when node or Chromium
  is missing, when its port is taken (probably the user's dashboard), and
  per-assertion when the pool lacks the shape being checked.
- Run `bash tests/add.sh` (45 assertions, ~60s) after any change to the add job
  model, its endpoints or `cmd_add`. It starts a real sidecar whose `--script` is a
  stub standing in for `add` alone (everything else goes to the real CLI), so every
  branch — the code channel, the newline the sidecar supplies itself, the reaper,
  cancellation, shutdown — is driven without a real sign-in. It is also where the
  security rules are enforced rather than merely stated: every response is checked
  for the pasted code and for a token. Skips when the port is taken.
- Run `bash tests/history.sh` (40 assertions, ~15s) after any change to the
  `.usage.log` format, `usage_history_json` or `next_json`. Throwaway `HOME`,
  every sample written by the test, no API call — the rate segmentation and the
  pruning rules are the parts that would otherwise fail silently and slowly.
- Verify TUI changes by hand — there is no suite for the TUI. It shows no
  burn rate and no recommendation; that is a gap, not a decision.
- Do not claim macOS behaviour works. It cannot be tested here; say so.

## Commits

- Commit one concern at a time. Split unrelated work.
- Write commit messages as prose: what changed, and why the alternative lost.
- Do not commit or push unless asked.
