# claudius — rules

Bash CLI + TUI for switching between Claude accounts, with a localhost dashboard.
Background and reasoning: `docs/internals.md`. Deferred work: `.scratch/`.

## Never touch the real account state

- Run every CLI invocation that mutates under a throwaway `HOME`:
  `HOME="$tmp" bash claudius …`. Never invoke `activate`, `refresh`, `add`,
  `remove`, `link` or `run` bare.
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
- `.usage` → `u5 u7 uts r5 r7`, space-separated. Write `-` for a missing window;
  never omit a field.
- `dashboard.html` → the sidecar substitutes `{{TOKEN}}` and `{{ROOT}}` only.
  Keep the file valid standalone HTML.
- Handle usage values above 100 and the case of no active profile. Both are real.

## Security

- Keep the dashboard bound to `127.0.0.1`. Never make the bind address
  configurable.
- Never put a token, credential or refresh token in an API response, log line,
  error message or test output.
- Require `X-CSRF-Token` on every mutating endpoint.
- Shell back into the bash CLI for mutations. Never reimplement `activate` or
  `refresh` in Ruby or JS.

## Dashboard

- Read the header comment in `dashboard.html` before editing it. Follow its
  design rules and the three traps it lists.
- Verify by serving the page, not by reading the diff:
  `ruby claude-dashboard.rb --port 8799 --root "$HOME/.claude-profiles" --script "$PWD/claudius"`
- Stop the server and confirm the port is closed when done.

## Tests

- Run `bash tests/share.sh` (94 assertions, ~20s) before any change to
  `wire_profile_sharing`, `merge_profile_settings`, `sync_profile_projects_key`,
  `link` or `run`.
- Verify TUI and dashboard changes by hand — there is no suite for either.
- Do not claim macOS behaviour works. It cannot be tested here; say so.

## Commits

- Commit one concern at a time. Split unrelated work.
- Write commit messages as prose: what changed, and why the alternative lost.
- Do not commit or push unless asked.
