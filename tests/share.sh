#!/usr/bin/env bash
# Sandbox tests for claudius's shared-session wiring. Everything happens under a
# throwaway HOME, so the real ~/.claude is never read from or written to.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/claudius"
# `ruby` here is an asdf shim that resolves installs relative to $HOME; point it at
# the real data dir so the fake HOME does not break the interpreter itself.
ASDF_KEEP="${ASDF_DATA_DIR:-$HOME/.asdf}"
# Captured before anything overrides HOME — the last check asserts no sandbox
# symlink resolves back into it.
REAL_HOME="$HOME"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

# Build a fake HOME with a plausible ~/.claude pool and one stored profile.
mkhome() {
  local h="$1"
  rm -rf "$h"; mkdir -p "$h/.claude"
  # shared: assets + session data
  mkdir -p "$h/.claude/agents" "$h/.claude/commands" "$h/.claude/skills"
  mkdir -p "$h/.claude/projects/-repo-a" "$h/.claude/plans" "$h/.claude/tasks"
  mkdir -p "$h/.claude/sessions" "$h/.claude/shell-snapshots" "$h/.claude/file-history"
  mkdir -p "$h/.claude/plugins" "$h/.claude/statsig"
  : > "$h/.claude/CLAUDE.md"
  : > "$h/.claude/projects/-repo-a/aaa.jsonl"
  printf '{"display":"global one"}\n{"display":"global two"}\n' > "$h/.claude/history.jsonl"
  # isolated: identity, token, settings, claudius state, runtime
  printf '{"claudeAiOauth":{"accessToken":"live","expiresAt":%s}}\n' "$(( ($(date +%s) + 3600) * 1000 ))" \
    > "$h/.claude/.credentials.json"
  printf '{"permissions":{"allow":["Bash"]},"env":{"FOO":"1"},"statusLine":{"command":"global-sl"}}\n' \
    > "$h/.claude/settings.json"
  mkdir -p "$h/.claude/backups" "$h/.claude/ide" "$h/.claude/daemon"
  : > "$h/.claude/daemon.log"; : > "$h/.claude/daemon.lock"; : > "$h/.claude/foo.lock"
  # The CLI's OAuth refresh lock lives in the credential-storage dir. If the
  # pool's copy were linked into a profile, an isolated run session would lock the
  # LIVE lock file and contend with the live session over one refresh chain.
  : > "$h/.claude/.oauth_refresh.lock"
  # global identity file
  cat > "$h/.claude.json" <<'JSON'
{"oauthAccount":{"emailAddress":"live@example.com"},
 "projects":{"/repo/a":{"hasTrustDialogAccepted":true},"/repo/b":{"allowedTools":["Read"]}},
 "hasCompletedOnboarding":true}
JSON
}

mkprofile() {
  local h="$1" name="$2" email="$3" exp="${4:-future}"
  local d="$h/.claude-profiles/$name"
  mkdir -p "$d"
  local at
  if [[ "$exp" == future ]]; then at=$(( ($(date +%s) + 3600) * 1000 )); else at=$(( ($(date +%s) - 3600) * 1000 )); fi
  printf '{"claudeAiOauth":{"accessToken":"tok-%s","refreshToken":"rt","expiresAt":%s}}\n' "$name" "$at" \
    > "$d/.credentials.json"
  printf '{"oauthAccount":{"emailAddress":"%s"},"hasCompletedOnboarding":true,"projects":{"/repo/a":{"mine":true}}}\n' \
    "$email" > "$d/.claude.json"
}

# Run a snippet with claudius's functions loaded under the fake HOME. Sourcing with
# `help` keeps main()'s set -e / traps inside its own subshell.
inhome() {
  local h="$1"; shift
  HOME="$h" ASDF_DATA_DIR="$ASDF_KEEP" bash -c "source '$SCRIPT' help >/dev/null 2>&1; $*"
}

T="$(mktemp -d "${TMPDIR:-/tmp}/claudius-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# ── 1. clean wiring ───────────────────────────────────────────────────────────
echo "1. clean wiring (nothing in the way)"
H="$T/h1"; mkhome "$H"; mkprofile "$H" work "work@example.com"
out="$(inhome "$H" 'wire_profile_sharing work false; echo "rc=$?"')"
P="$H/.claude-profiles/work"
check "returns 0"                      '[[ "$out" == *"rc=0"* ]]'
for e in agents commands skills CLAUDE.md projects plans tasks sessions \
         shell-snapshots file-history plugins statsig history.jsonl; do
  check "linked: $e"                   "[[ -L '$P/$e' && \"\$(readlink '$P/$e')\" == '$H/.claude/$e' ]]"
done
for e in .credentials.json settings.json backups ide daemon daemon.log daemon.lock foo.lock \
         .oauth_refresh.lock; do
  check "NOT linked: $e"               "[[ ! -L '$P/$e' ]]"
done
check "identity still a real file"     "[[ -f '$P/.claude.json' && ! -L '$P/.claude.json' ]]"
check "token still the profile's own"  "grep -q 'tok-work' '$P/.credentials.json'"
check "resume sees pooled transcript"  "[[ -f '$P/projects/-repo-a/aaa.jsonl' ]]"

# ── 2. idempotence ────────────────────────────────────────────────────────────
echo "2. idempotent re-run"
# Compare names + link targets, not `ls -la` — timestamps in that output make the
# assertion flake across a minute boundary.
snapshot() { ( cd "$1" && find . -maxdepth 1 -printf '%p -> %l\n' | sort ); }
before="$(snapshot "$P")"
inhome "$H" 'wire_profile_sharing work false' >/dev/null
after="$(snapshot "$P")"
check "no change on second run"         '[[ "$before" == "$after" ]]'
check "no .pre-share.bak created"       "[[ -z \"\$(ls -d '$P'/*.pre-share* 2>/dev/null)\" ]]"

# ── 3. settings merge ─────────────────────────────────────────────────────────
echo "3. settings.json merge"
H="$T/h3"; mkhome "$H"; mkprofile "$H" work "work@example.com"
printf '{"statusLine":{"command":"claudius-sl"}}\n' > "$H/.claude-profiles/work/settings.json"
inhome "$H" 'merge_profile_settings work' >/dev/null
S="$H/.claude-profiles/work/settings.json"
check "profile statusLine wins"         "grep -q 'claudius-sl' '$S'"
check "global permissions merged in"    "grep -q 'permissions' '$S'"
check "global env merged in"            "grep -q 'FOO' '$S'"
check "backup taken once"               "[[ -f '$S.claudius-bak' ]]"
check "settings.json not a symlink"     "[[ ! -L '$S' ]]"
# second run must not re-backup or change anything
cp "$S" "$T/s-snap"
inhome "$H" 'merge_profile_settings work' >/dev/null
check "settings merge idempotent"       "cmp -s '$S' '$T/s-snap'"

# ── 4. projects-key sync ──────────────────────────────────────────────────────
echo "4. projects key sync (trust / allowedTools)"
inhome "$H" 'sync_profile_projects_key work' >/dev/null
I="$H/.claude-profiles/work/.claude.json"
check "profile keeps its own /repo/a"   "ruby -rjson -e 'exit JSON.parse(File.read(ARGV[0]))[\"projects\"][\"/repo/a\"][\"mine\"] ? 0 : 1' '$I'"
check "global /repo/b copied in"        "ruby -rjson -e 'exit JSON.parse(File.read(ARGV[0]))[\"projects\"].key?(\"/repo/b\") ? 0 : 1' '$I'"
check "oauthAccount untouched"          "grep -q 'work@example.com' '$I'"

# ── 5. collision: real data in the profile ────────────────────────────────────
echo "5. collision handling"
H="$T/h5"; mkhome "$H"; mkprofile "$H" work "work@example.com"
P="$H/.claude-profiles/work"
mkdir -p "$P/projects/-repo-z"; : > "$P/projects/-repo-z/zzz.jsonl"
mkdir -p "$P/projects/-repo-a"; : > "$P/projects/-repo-a/own.jsonl"
printf '{"display":"global one"}\n{"display":"profile only"}\n' > "$P/history.jsonl"

out="$(inhome "$H" 'wire_profile_sharing work false; echo "rc=$?"' 2>&1)"
check "non-interactive refuses"         '[[ "$out" == *"rc=1"* ]]'
check "refusal names the fix"           '[[ "$out" == *"link work"* ]]'
check "nothing moved on refusal"        "[[ -d '$P/projects/-repo-z' && ! -L '$P/projects' ]]"
check "plan lists the entries"          '[[ "$out" == *projects* && "$out" == *history.jsonl* ]]'

out="$(inhome "$H" 'printf "n\n" | wire_profile_sharing work true; echo "rc=$?"' 2>&1)"
check "declining leaves data alone"     "[[ \"\$out\" == *'rc=1'* && -d '$P/projects/-repo-z' ]]"

out="$(inhome "$H" 'printf "y\n" | wire_profile_sharing work true; echo "rc=$?"' 2>&1)"
check "confirming succeeds"             '[[ "$out" == *"rc=0"* ]]'
check "projects now a symlink"          "[[ -L '$P/projects' ]]"
check "own slug folded into pool"       "[[ -f '$H/.claude/projects/-repo-z/zzz.jsonl' ]]"
check "pool's own slug not clobbered"   "[[ -f '$H/.claude/projects/-repo-a/aaa.jsonl' && ! -f '$H/.claude/projects/-repo-a/own.jsonl' ]]"
check "old copy set aside"              "[[ -d '$P/projects.pre-share.bak' ]]"
check "set-aside copy still has data"   "[[ -f '$P/projects.pre-share.bak/-repo-z/zzz.jsonl' ]]"
check "history.jsonl linked"            "[[ -L '$P/history.jsonl' ]]"
n_dup="$(grep -c 'global one' "$H/.claude/history.jsonl")"
check "history dedup (no double line)"  '[[ "$n_dup" == 1 ]]'
check "history unique line appended"    "grep -q 'profile only' '$H/.claude/history.jsonl'"

# a second collision round must not overwrite the first .bak
mkdir -p "$P/plans2"; : > "$P/plans2/x"   # unrelated, just to re-dirty
rm "$P/projects"; mkdir -p "$P/projects/-repo-q"; : > "$P/projects/-repo-q/q.jsonl"
inhome "$H" 'printf "y\n" | wire_profile_sharing work true' >/dev/null 2>&1
check "second .bak gets a new name"     "[[ -d '$P/projects.pre-share.bak' && -d '$P/projects.pre-share.2.bak' ]]"

# ── 6. stale symlink repointed ────────────────────────────────────────────────
echo "6. stale symlink repair"
H="$T/h7"; mkhome "$H"; mkprofile "$H" work "work@example.com"
P="$H/.claude-profiles/work"
mkdir -p "$T/elsewhere"; ln -s "$T/elsewhere" "$P/agents"
inhome "$H" 'wire_profile_sharing work false' >/dev/null
check "repointed at the pool"           "[[ \"\$(readlink '$P/agents')\" == '$H/.claude/agents' ]]"
check "no .bak for a mere symlink"      "[[ ! -e '$P/agents.pre-share.bak' ]]"

# ── 7. token prep ─────────────────────────────────────────────────────────────
echo "7. token preparation (Linux path)"
H="$T/h8"; mkhome "$H"; mkprofile "$H" work "work@example.com"
out="$(inhome "$H" 'keychain_available() { return 1; }; run_prepare_token work; echo "rc=$?"')"
check "fresh token: no-op, rc=0"        '[[ "$out" == *"rc=0"* && "$out" != *"refreshing"* ]]'

# expired token belonging to the live account → adopt live creds, never rotate
mkprofile "$H" live "live@example.com" expired
out="$(inhome "$H" 'keychain_available() { return 1; }; run_prepare_token live; echo "rc=$?"')"
check "adopts live creds, no rotation"  '[[ "$out" == *"rc=0"* && "$out" != *"refreshing"* ]]'
check "profile now holds live token"    "grep -q '\"live\"' '$H/.claude-profiles/live/.credentials.json'"

# expired token for a different account → would refresh over the network; assert
# only that it does not adopt the live token (offline, so the refresh must fail)
mkprofile "$H" other "other@example.com" expired
out="$(inhome "$H" 'keychain_available() { return 1; }; oauth_refresh_creds() { return 1; }; run_prepare_token other; echo "rc=$?"' 2>&1)"
check "unrenewable token fails loudly"  '[[ "$out" == *"rc=1"* ]]'
check "tells you how to fix it"         '[[ "$out" == *"add other"* || "$out" == *"Sign in again"* ]]'
check "did not steal the live token"    "grep -q 'tok-other' '$H/.claude-profiles/other/.credentials.json'"

# Same account as the live session AND both expired: rotating the profile's
# refresh token staleds the global copy, so the new credential must be pushed
# back to ~/.claude — otherwise a bare `claude` would need to re-login.
printf '{"claudeAiOauth":{"accessToken":"stale-live","refreshToken":"rt","expiresAt":1}}\n' \
  > "$H/.claude/.credentials.json"
mkprofile "$H" live2 "live@example.com" expired
inhome "$H" 'keychain_available() { return 1; }; oauth_refresh_creds() { printf "{\"claudeAiOauth\":{\"accessToken\":\"ROTATED\",\"expiresAt\":99999999999999}}\n" > "$1"; return 0; }; run_prepare_token live2' >/dev/null 2>&1
check "rotated token written to profile" "grep -q ROTATED '$H/.claude-profiles/live2/.credentials.json'"
check "live session kept in step"        "grep -q ROTATED '$H/.claude/.credentials.json'"
# A DIFFERENT account's rotation must never overwrite the live credential.
printf '{"claudeAiOauth":{"accessToken":"stale-live","refreshToken":"rt","expiresAt":1}}\n' \
  > "$H/.claude/.credentials.json"
mkprofile "$H" other2 "other@example.com" expired
inhome "$H" 'keychain_available() { return 1; }; oauth_refresh_creds() { printf "{\"claudeAiOauth\":{\"accessToken\":\"OTHERTOK\",\"expiresAt\":99999999999999}}\n" > "$1"; return 0; }; run_prepare_token other2' >/dev/null 2>&1
check "other account left live alone"   "grep -q 'stale-live' '$H/.claude/.credentials.json'"

# ── 8. plan is read-only ──────────────────────────────────────────────────────
echo "8. share_plan does not mutate"
H="$T/h9"; mkhome "$H"; mkprofile "$H" work "work@example.com"
snap_before="$(cd "$H" && find . | sort)"
inhome "$H" 'share_plan "$PROFILE_ROOT/work" false; echo "${#SHARE_PLAN_LINK[@]} to link"'
snap_after="$(cd "$H" && find . | sort)"
check "no filesystem change"            '[[ "$snap_before" == "$snap_after" ]]'

# ── 9. run_profile guards ────────────────────────────────────────────────────
echo "9. run_profile guards"
H="$T/h10"; mkhome "$H"
out="$(inhome "$H" 'run_profile nope; echo "rc=$?"' 2>&1)"
check "unknown profile rejected"        '[[ "$out" == *"does not exist"* && "$out" == *"rc=1"* ]]'
mkdir -p "$H/.claude-profiles/creds-less"
out="$(inhome "$H" 'run_profile creds-less; echo "rc=$?"' 2>&1)"
check "credential-less profile refused" '[[ "$out" == *"no saved credentials"* && "$out" == *"rc=1"* ]]'
# macOS branch. A profile != the live account now gets its OWN Keychain credential
# rather than being refused (see run_profile's credential scoping, and
# tests/run-scope.sh which owns that behaviour). What must still refuse here is the
# case where the scope cannot be chosen safely: too old a CLI to namespace the
# Keychain item, or an unresolvable identity. Both return before launching claude,
# so these need no stub on PATH.
mkprofile "$H" mac "mac@example.com"
out="$(inhome "$H" 'keychain_available() { return 0; }; live_account_email() { printf live@example.com; }; claude_version_at_least() { return 1; }; claude_version() { printf 2.1.100; }; run_profile mac; echo "rc=$?"' 2>&1)"
check "macOS + old CLI refuses"         '[[ "$out" == *"Keychain"* && "$out" == *"rc=1"* ]]'
check "old-CLI refusal offers activate" '[[ "$out" == *"activate mac"* ]]'
out="$(inhome "$H" 'keychain_available() { return 0; }; live_account_email() { printf ""; }; run_profile mac; echo "rc=$?"' 2>&1)"
check "unknown live account refuses"    '[[ "$out" == *"refusing to guess"* && "$out" == *"rc=1"* ]]'
check "refusal offers activate"         '[[ "$out" == *"activate mac"* ]]'

# ── 10. CLI surface ───────────────────────────────────────────────────────────
echo "10. CLI surface"
H="$T/h11"; mkhome "$H"; mkprofile "$H" work "work@example.com"
out="$(HOME="$H" ASDF_DATA_DIR="$ASDF_KEEP" bash "$SCRIPT" link work 2>&1)"; rc=$?
check "link succeeds"                   '[[ $rc -eq 0 ]]'
check "link reports what it did"        '[[ "$out" == *"shared sessions"* ]]'
check "link created the symlinks"       "[[ -L '$H/.claude-profiles/work/projects' ]]"
out="$(HOME="$H" ASDF_DATA_DIR="$ASDF_KEEP" bash "$SCRIPT" link work 2>&1)"
check "link is idempotent"              '[[ "$out" == *"already wired"* ]]'
out="$(HOME="$H" ASDF_DATA_DIR="$ASDF_KEEP" bash "$SCRIPT" link 2>&1)"; rc=$?
check "link without name → usage"       '[[ $rc -eq 2 && "$out" == *"usage:"* ]]'
out="$(HOME="$H" ASDF_DATA_DIR="$ASDF_KEEP" bash "$SCRIPT" run 2>&1 </dev/null)"; rc=$?
check "run w/o profile, no tty → usage" '[[ $rc -eq 2 && "$out" == *"usage:"* ]]'
out="$(HOME="$H" ASDF_DATA_DIR="$ASDF_KEEP" bash "$SCRIPT" help 2>&1)"
check "help documents run"              '[[ "$out" == *"run [profile]"* ]]'
check "help documents the sharing"      '[[ "$out" == *"SHARE"* ]]'
check "help warns about macOS"          '[[ "$out" == *"Keychain"* ]]'

# ── 11. end-to-end `run` with a stub claude ───────────────────────────────────
# Exercises the whole CLI path (main's set -euo pipefail included) and proves the
# exec hands `claude` the profile's config dir plus any extra args verbatim.
echo "11. end-to-end run (stub claude)"
H="$T/h14"; mkhome "$H"; mkprofile "$H" work "work@example.com"
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then echo "2.1.220 (Claude Code)"; exit 0; fi
echo "STUB-CLAUDE cfg=[${CLAUDE_CONFIG_DIR:-unset}] sec=[${CLAUDE_SECURESTORAGE_CONFIG_DIR-unset}] args=[$*]"
STUB
chmod +x "$BIN/claude"

# A file-backed stand-in for /usr/bin/security. On macOS keychain_available() is
# genuinely true, so without this the run path would reach the REAL login Keychain —
# both non-hermetic and forbidden. claudius invokes `security` unqualified, so a
# PATH entry shadows it, and this section then exercises the true macOS credential
# path (per-dir service names, seeding, write-back) against a fake store. On Linux
# keychain_available() stays false regardless and the file path is exercised instead.
export FAKE_KEYCHAIN="$T/fake-keychain"
mkdir -p "$FAKE_KEYCHAIN"
cat > "$BIN/security" <<'STUB'
#!/usr/bin/env bash
store="${FAKE_KEYCHAIN:?fake keychain store not set}"
mkdir -p "$store"
cmd="${1:-}"; shift || true
svc=""; val=""; want_secret=false
while (( $# )); do
  case "$1" in
    -s) svc="${2:-}"; shift 2 ;;
    -a) shift 2 ;;
    -w) if [[ "$cmd" == add-generic-password ]]; then val="${2:-}"; shift 2; else want_secret=true; shift; fi ;;
    *)  shift ;;
  esac
done
key="$(printf '%s' "$svc" | tr -c 'a-zA-Z0-9-' '_')"
case "$cmd" in
  find-generic-password)
    [[ -f "$store/$key" ]] || exit 44          # errSecItemNotFound, as the real one
    $want_secret && cat "$store/$key"
    exit 0 ;;
  add-generic-password)
    printf '%s' "$val" > "$store/$key"; exit 0 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$BIN/security"

out="$(HOME="$H" ASDF_DATA_DIR="$ASDF_KEEP" PATH="$BIN:$PATH" bash "$SCRIPT" run work --model sonnet -p hi 2>&1)"
rc=$?
check "run exits cleanly"               '[[ $rc -eq 0 ]]'
check "claude got the profile cfg dir"  "[[ \"\$out\" == *\"cfg=[$H/.claude-profiles/work]\"* ]]"
check "extra args passed verbatim"      '[[ "$out" == *"args=[--model sonnet -p hi]"* ]]'
check "banner names the profile"        '[[ "$out" == *"work@example.com"* ]]'
check "wired on first run"              "[[ -L '$H/.claude-profiles/work/projects' ]]"
check "global account NOT switched"     "[[ ! -f '$H/.claude-profiles/.active_profile' ]]"
check "global creds untouched"          "grep -q '\"live\"' '$H/.claude/.credentials.json'"

out="$(HOME="$H" ASDF_DATA_DIR="$ASDF_KEEP" PATH="$BIN:$PATH" bash "$SCRIPT" run work 2>&1)"
check "run with no args works"          "[[ \"\$out\" == *'args=[]'* ]]"
out="$(HOME="$H" ASDF_DATA_DIR="$ASDF_KEEP" PATH="$BIN:$PATH" bash "$SCRIPT" open work 2>&1)"
check "'open' alias works"              '[[ "$out" == *"STUB-CLAUDE"* ]]'

# An expired token that cannot be renewed must abort BEFORE launching claude.
mkprofile "$H" stale "stale@example.com" expired
out="$(HOME="$H" ASDF_DATA_DIR="$ASDF_KEEP" PATH="$BIN:$PATH" bash "$SCRIPT" run stale 2>&1)"; rc=$?
check "unrenewable token: no launch"    '[[ $rc -ne 0 && "$out" != *"STUB-CLAUDE"* ]]'

# ── 12. removing a wired profile must not touch the pool ──────────────────────
# The scariest interaction in the whole feature: remove_profile does `rm -rf` on a
# dir that is now full of symlinks pointing at your real ~/.claude. If rm followed
# them, `claudius remove` would destroy every account's history.
echo "12. remove a wired profile (rm -rf vs symlinks)"
H="$T/h15"; mkhome "$H"; mkprofile "$H" work "work@example.com"
inhome "$H" 'wire_profile_sharing work false' >/dev/null 2>&1
check "wired (precondition)"            "[[ -L '$H/.claude-profiles/work/projects' ]]"
inhome "$H" 'remove_profile work' >/dev/null 2>&1
check "profile dir gone"                "[[ ! -d '$H/.claude-profiles/work' ]]"
check "pool transcripts SURVIVE"        "[[ -f '$H/.claude/projects/-repo-a/aaa.jsonl' ]]"
check "pool history SURVIVES"           "[[ -s '$H/.claude/history.jsonl' ]]"
check "pool agents SURVIVE"             "[[ -d '$H/.claude/agents' ]]"
check "pool CLAUDE.md SURVIVES"         "[[ -f '$H/.claude/CLAUDE.md' ]]"
check "global creds SURVIVE"            "[[ -f '$H/.claude/.credentials.json' ]]"

# ── 13. real ~/.claude untouched ──────────────────────────────────────────────
echo "13. the real ~/.claude was never touched"
check "no test symlinks into real home" "[[ -z \"\$(find '$T' -lname '$REAL_HOME/.claude/*' 2>/dev/null)\" ]]"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
