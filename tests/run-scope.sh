#!/usr/bin/env bash
# Sandbox tests for `run`'s macOS credential scoping: the per-config-dir Keychain
# service name, the write-back sync, and which scope run_profile picks. Everything
# happens under a throwaway HOME, and every `security` call is stubbed out — no
# real Keychain item is ever read or written, and the real ~/.claude is untouched.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/claudius"
# `ruby` here is an asdf shim that resolves installs relative to $HOME; point it at
# the real data dir so the fake HOME does not break the interpreter itself.
ASDF_KEEP="${ASDF_DATA_DIR:-$HOME/.asdf}"
PASS=0; FAIL=0; SKIP=0

ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  \033[33m-\033[0m %s \033[2m(%s)\033[0m\n' "$1" "$2"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

# A few assertions are written against BSD userland and only mean anything on a
# Mac — they use `stat -f %Lp`, which on GNU coreutils is "stat the FILE SYSTEM"
# and prints an unrelated block report. Run them only where they belong rather
# than teaching every one of them to speak both dialects.
IS_MACOS=false
[[ "$(uname -s)" == "Darwin" ]] && IS_MACOS=true
check_macos(){
  if [[ "$IS_MACOS" == true ]]; then check "$1" "$2"; else skip "$1" "macOS only"; fi
}

# Same sandbox shape as tests/share.sh.
mkhome() {
  local h="$1"
  rm -rf "$h"; mkdir -p "$h/.claude"
  mkdir -p "$h/.claude/agents" "$h/.claude/commands" "$h/.claude/skills"
  mkdir -p "$h/.claude/projects/-repo-a" "$h/.claude/plans" "$h/.claude/tasks"
  mkdir -p "$h/.claude/sessions" "$h/.claude/shell-snapshots" "$h/.claude/file-history"
  mkdir -p "$h/.claude/plugins" "$h/.claude/statsig"
  : > "$h/.claude/CLAUDE.md"
  : > "$h/.claude/projects/-repo-a/aaa.jsonl"
  printf '{"display":"global one"}\n' > "$h/.claude/history.jsonl"
  printf '{"claudeAiOauth":{"accessToken":"live","expiresAt":%s}}\n' "$(( ($(date +%s) + 3600) * 1000 ))" \
    > "$h/.claude/.credentials.json"
  printf '{"permissions":{"allow":["Bash"]}}\n' > "$h/.claude/settings.json"
  cat > "$h/.claude.json" <<'JSON'
{"oauthAccount":{"emailAddress":"live@example.com"},"hasCompletedOnboarding":true,"projects":{}}
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
  printf '{"oauthAccount":{"emailAddress":"%s"},"hasCompletedOnboarding":true,"projects":{}}\n' \
    "$email" > "$d/.claude.json"
}

# Run a snippet with claudius's functions loaded under the fake HOME. PRELUDE is
# injected after sourcing so a test can stub out the Keychain and `claude` itself.
inhome() {
  local h="$1"; shift
  HOME="$h" ASDF_DATA_DIR="$ASDF_KEEP" PATH="$h/bin:$PATH" \
    bash -c "source '$SCRIPT' help >/dev/null 2>&1; ${PRELUDE:-:}; $*"
}

# Pretend we are on macOS with a working Keychain, and record every write instead
# of performing one. $STUBLOG collects "write <service>" lines.
kc_stub() {
  cat <<'STUB'
keychain_available() { return 0; }
keychain_account() { printf 'tester'; }
write_keychain_creds() { printf 'write %s\n' "${2:-DEFAULT}" >> "$STUBLOG"; return 0; }
read_keychain_creds() { printf 'read %s\n' "${1:-DEFAULT}" >> "$STUBLOG"; cat "$KCFILE" 2>/dev/null; }
read_keychain_creds_guarded() { printf 'read %s\n' "${1:-DEFAULT}" >> "$STUBLOG"; cat "$KCFILE" 2>/dev/null; }
STUB
}

# A fake `claude` on PATH that records the credential-scope env vars it was given.
mkfakeclaude() {
  local h="$1"
  mkdir -p "$h/bin"
  cat > "$h/bin/claude" <<'SH'
#!/usr/bin/env bash
# Version probes come from claudius's own startup migration, not from a session —
# answer them without polluting the launch log the assertions read.
if [[ "${1:-}" == "--version" ]]; then echo "2.1.220 (Claude Code)"; exit 0; fi
if [[ "${1:-}" == "auth" ]]; then exit 1; fi
{
  printf 'CONFIG_DIR=%s\n' "${CLAUDE_CONFIG_DIR-unset}"
  printf 'SECURESTORAGE=%s\n' "${CLAUDE_SECURESTORAGE_CONFIG_DIR-unset}"
  printf 'ARGS=%s\n' "$*"
} >> "$FAKELOG"
exit 0
SH
  chmod +x "$h/bin/claude"
}

T="$(mktemp -d "${TMPDIR:-/tmp}/claudius-runscope.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# ── 1. service name derivation ────────────────────────────────────────────────
echo "1. Keychain service name per config dir"
H="$T/h1"; mkhome "$H"
PRELUDE=""
# One name per line: the service names contain a space, so any field-splitting
# extraction would silently compare the word "Claude" against itself.
a="$(inhome "$H" 'keychain_service_for_dir "/tmp/one"')"
b="$(inhome "$H" 'keychain_service_for_dir "/tmp/one"')"
c="$(inhome "$H" 'keychain_service_for_dir "/tmp/two"')"
d="$(inhome "$H" 'keychain_service_for_dir ""')"
check "default (empty arg) is the shared item" '[[ "$d" == "Claude Code-credentials" ]]'
check "namespaced name has an 8-hex suffix"    '[[ "$a" =~ ^Claude\ Code-credentials-[0-9a-f]{8}$ ]]'
check "stable for the same dir"                '[[ "$a" == "$b" ]]'
check "differs for a different dir"            '[[ "$a" != "$c" ]]'
# Golden vectors over synthetic paths — never a real dir, so nothing about the
# machine this runs on ends up in the suite. These pin the exact algorithm the CLI
# uses (first 8 hex of sha256 of the NFC-normalised dir path); if a future release
# changes it, these fail and run_profile's version guard needs revisiting.
out="$(inhome "$H" 'keychain_service_for_dir "/fixture/profiles/acct-one"')"
check "golden vector 1"                        '[[ "$out" == "Claude Code-credentials-67e28535" ]]'
out="$(inhome "$H" 'keychain_service_for_dir "/fixture/profiles/acct-two"')"
check "golden vector 2"                        '[[ "$out" == "Claude Code-credentials-1f3c5654" ]]'

# ── 2. creds_expires_at ───────────────────────────────────────────────────────
echo "2. creds_expires_at"
H="$T/h2"; mkhome "$H"; mkprofile "$H" work "work@example.com"
printf 'not json' > "$H/junk.json"
out="$(inhome "$H" '
  echo "good=$(creds_expires_at "$HOME/.claude-profiles/work/.credentials.json")"
  echo "junk=$(creds_expires_at "$HOME/junk.json")"
  echo "gone=$(creds_expires_at "$HOME/nope.json")"')"
check "reads expiresAt"          '[[ "$out" =~ good=[0-9]{10,} ]]'
check "unparseable → 0"          '[[ "$out" == *"junk=0"* ]]'
check "missing file → 0"         '[[ "$out" == *"gone=0"* ]]'

# ── 3. sync_profile_creds_from_keychain ───────────────────────────────────────
echo "3. write-back sync from the profile's own Keychain item"
H="$T/h3"; mkhome "$H"; mkprofile "$H" work "work@example.com"
P="$H/.claude-profiles/work"
PRELUDE="$(kc_stub)"

# a) newer credential in the Keychain → adopted
newer=$(( ($(date +%s) + 99999) * 1000 ))
printf '{"claudeAiOauth":{"accessToken":"from-keychain","refreshToken":"rt2","expiresAt":%s}}' "$newer" > "$T/kc-newer.json"
out="$(KCFILE="$T/kc-newer.json" STUBLOG="$T/log3a" inhome "$H" 'sync_profile_creds_from_keychain work; echo "rc=$?"')"
check "adopts a newer credential"        '[[ "$out" == *"rc=0"* ]] && grep -q "from-keychain" "'"$P"'/.credentials.json"'
check "reads the NAMESPACED service"     'grep -q "read Claude Code-credentials-" "'"$T"'/log3a"'
check "never reads the shared item"      '! grep -q "read DEFAULT" "'"$T"'/log3a" && ! grep -qx "read Claude Code-credentials" "'"$T"'/log3a"'
check_macos "file kept at 0600"          '[[ "$(stat -f %Lp "'"$P"'/.credentials.json")" == "600" ]]'

# b) older credential in the Keychain → file left alone
mkprofile "$H" work "work@example.com"
older=$(( ($(date +%s) - 99999) * 1000 ))
printf '{"claudeAiOauth":{"accessToken":"stale-keychain","expiresAt":%s}}' "$older" > "$T/kc-older.json"
out="$(KCFILE="$T/kc-older.json" STUBLOG="$T/log3b" inhome "$H" 'sync_profile_creds_from_keychain work; echo "rc=$?"')"
check "refuses an older credential"      '[[ "$out" == *"rc=1"* ]] && grep -q "tok-work" "'"$P"'/.credentials.json"'

# c) unparseable Keychain payload → file left alone
printf 'garbage' > "$T/kc-junk.json"
out="$(KCFILE="$T/kc-junk.json" STUBLOG="$T/log3c" inhome "$H" 'sync_profile_creds_from_keychain work; echo "rc=$?"')"
check "refuses garbage"                  '[[ "$out" == *"rc=1"* ]] && grep -q "tok-work" "'"$P"'/.credentials.json"'

# d) plaintext deleted by the CLI's composite store → recovered
rm -f "$P/.credentials.json"
out="$(KCFILE="$T/kc-newer.json" STUBLOG="$T/log3d" inhome "$H" 'sync_profile_creds_from_keychain work; echo "rc=$?"')"
check "recovers a deleted plaintext copy" '[[ "$out" == *"rc=0"* ]] && grep -q "from-keychain" "'"$P"'/.credentials.json"'

# ── 4. scope choice: same account as live → shared ────────────────────────────
echo "4. run of the LIVE account shares the live credential"
H="$T/h4"; mkhome "$H"; mkprofile "$H" live "live@example.com"; mkfakeclaude "$H"
PRELUDE="$(kc_stub); live_account_email() { printf 'live@example.com'; }; claude_version_at_least() { return 0; }"
FAKELOG="$T/fake4"; : > "$FAKELOG"
out="$(FAKELOG="$FAKELOG" KCFILE=/dev/null STUBLOG="$T/log4" inhome "$H" 'run_profile live --print hi; echo "rc=$?"')"
check "launches"                          "grep -q 'ARGS=--print hi' '$FAKELOG'"
check "CLAUDE_CONFIG_DIR is the profile"  "grep -q 'CONFIG_DIR=$H/.claude-profiles/live' '$FAKELOG'"
check "securestorage forced EMPTY"        "grep -qx 'SECURESTORAGE=' '$FAKELOG'"
check "no Keychain item seeded"           "[[ ! -s '$T/log4' ]]"
check "token file untouched (no rotation)" "grep -q 'tok-live' '$H/.claude-profiles/live/.credentials.json'"

# ── 5. scope choice: different account → isolated ─────────────────────────────
echo "5. run of a DIFFERENT account gets its own credential"
H="$T/h5"; mkhome "$H"; mkprofile "$H" other "other@example.com"; mkfakeclaude "$H"
PRELUDE="$(kc_stub); live_account_email() { printf 'live@example.com'; }; claude_version_at_least() { return 0; }"
FAKELOG="$T/fake5"; : > "$FAKELOG"
D="$H/.claude-profiles/other"
out="$(FAKELOG="$FAKELOG" KCFILE=/dev/null STUBLOG="$T/log5" inhome "$H" 'run_profile other; echo "rc=$?"')"
check "launches"                          "grep -q 'CONFIG_DIR=$D' '$FAKELOG'"
check "securestorage = the profile dir"   "grep -qx 'SECURESTORAGE=$D' '$FAKELOG'"
check "seeds the namespaced item"         "grep -q 'write Claude Code-credentials-' '$T/log5'"
check "never writes the shared item"      "! grep -q 'write DEFAULT' '$T/log5' && ! grep -qx 'write Claude Code-credentials' '$T/log5'"
check "syncs back after the session"      "grep -q 'read Claude Code-credentials-' '$T/log5'"
check "reports isolation to the user"     '[[ "$out" == *"own credential"* ]]'
check "propagates the exit code"          '[[ "$out" == *"rc=0"* ]]'
check "live ~/.claude untouched"          "grep -q '\"live\"' '$H/.claude/.credentials.json'"

# ── 6. refusals ───────────────────────────────────────────────────────────────
echo "6. refusals when the scope cannot be chosen safely"
H="$T/h6"; mkhome "$H"; mkprofile "$H" other "other@example.com"; mkfakeclaude "$H"

# a) live account unknown
PRELUDE="$(kc_stub); live_account_email() { printf ''; }; claude_version_at_least() { return 0; }"
FAKELOG="$T/fake6a"; : > "$FAKELOG"
out="$(FAKELOG="$FAKELOG" KCFILE=/dev/null STUBLOG="$T/log6a" inhome "$H" 'run_profile other 2>&1; echo "rc=$?"')"
check "refuses when live account unknown" '[[ "$out" == *"refusing to guess"* && "$out" == *"rc=1"* ]]'
check "did not launch claude"             "[[ ! -s '$FAKELOG' ]]"

# b) profile identity unknown
rm -f "$H/.claude-profiles/other/.claude.json"
PRELUDE="$(kc_stub); live_account_email() { printf 'live@example.com'; }; claude_version_at_least() { return 0; }"
FAKELOG="$T/fake6b"; : > "$FAKELOG"
out="$(FAKELOG="$FAKELOG" KCFILE=/dev/null STUBLOG="$T/log6b" inhome "$H" 'run_profile other 2>&1; echo "rc=$?"')"
check "refuses when profile identity unknown" '[[ "$out" == *"no identity saved"* && "$out" == *"rc=1"* ]]'
check "did not launch claude"                 "[[ ! -s '$FAKELOG' ]]"

# c) CLI too old to namespace the Keychain item
H="$T/h6c"; mkhome "$H"; mkprofile "$H" other "other@example.com"; mkfakeclaude "$H"
PRELUDE="$(kc_stub); live_account_email() { printf 'live@example.com'; }; claude_version_at_least() { return 1; }; claude_version() { printf '2.1.100'; }"
FAKELOG="$T/fake6c"; : > "$FAKELOG"
out="$(FAKELOG="$FAKELOG" KCFILE=/dev/null STUBLOG="$T/log6c" inhome "$H" 'run_profile other 2>&1; echo "rc=$?"')"
check "refuses on an old CLI"              '[[ "$out" == *"cannot scope the login Keychain"* && "$out" == *"rc=1"* ]]'
check "names the minimum version"          '[[ "$out" == *"2.1.220"* ]]'
check "did not launch claude"              "[[ ! -s '$FAKELOG' ]]"

# ── 7. non-macOS path is unchanged ────────────────────────────────────────────
echo "7. off macOS nothing is scoped"
H="$T/h7"; mkhome "$H"; mkprofile "$H" work "work@example.com"; mkfakeclaude "$H"
PRELUDE="keychain_available() { return 1; }"
FAKELOG="$T/fake7"; : > "$FAKELOG"
out="$(FAKELOG="$FAKELOG" inhome "$H" 'run_profile work; echo "rc=$?"')"
check "launches with CLAUDE_CONFIG_DIR"    "grep -q 'CONFIG_DIR=$H/.claude-profiles/work' '$FAKELOG'"
check "securestorage left unset"           "grep -qx 'SECURESTORAGE=unset' '$FAKELOG'"

# ── 8. run_prepare_token honours the scope ────────────────────────────────────
# The macOS half of token prep (tests/share.sh section 7 owns the file path). The
# distinction that matters: under shared scope the CLI keeps the live credential
# fresh and rotating it here would log the live session out, so prep must be a
# no-op even for an expired file; under isolated scope the profile's own file seeds
# the session, so an expired one MUST be renewed.
echo "8. run_prepare_token scope handling (macOS)"
H="$T/h8"; mkhome "$H"
mkprofile "$H" liveacct "live@example.com" expired
mkprofile "$H" otheracct "other@example.com" expired
PRELUDE="$(kc_stub)"

out="$(KCFILE=/dev/null STUBLOG="$T/log8a" inhome "$H" 'run_prepare_token liveacct shared; echo "rc=$?"' 2>&1)"
check "shared scope: no-op on expired"   '[[ "$out" == *"rc=0"* && "$out" != *"refreshing"* ]]'
check "shared scope: no rotation"        "grep -q 'tok-liveacct' '$H/.claude-profiles/liveacct/.credentials.json'"

PRELUDE="$(kc_stub); oauth_refresh_creds() { printf '{\"claudeAiOauth\":{\"accessToken\":\"ROTATED\",\"expiresAt\":99999999999999}}' > \"\$1\"; return 0; }"
out="$(KCFILE=/dev/null STUBLOG="$T/log8b" inhome "$H" 'run_prepare_token otheracct isolated; echo "rc=$?"' 2>&1)"
check "isolated scope: renews expired"   '[[ "$out" == *"rc=0"* && "$out" == *"refreshing"* ]]'
check "isolated scope: rotation stored"  "grep -q ROTATED '$H/.claude-profiles/otheracct/.credentials.json'"

PRELUDE="$(kc_stub); oauth_refresh_creds() { return 1; }"
mkprofile "$H" dead "dead@example.com" expired
out="$(KCFILE=/dev/null STUBLOG="$T/log8c" inhome "$H" 'run_prepare_token dead isolated; echo "rc=$?"' 2>&1)"
check "isolated scope: fails loudly"     '[[ "$out" == *"rc=1"* && "$out" == *"Sign in again"* ]]'

# ── 9. add captures the account that just signed in ───────────────────────────
# `cmd_add` runs `CLAUDE_CONFIG_DIR=$dir claude auth login`, so on a namespacing CLI
# the new account's token lands in THAT dir's Keychain item while the shared item
# still holds the live account. Reading the shared one would silently hand the new
# profile a copy of the live credential — and credentials_ready cannot catch it,
# because it only checks that some accessToken is present.
echo "9. materialize_profile_credentials reads the right item"
H="$T/h9"; mkhome "$H"
D="$H/.claude-profiles/fresh"; mkdir -p "$D"
printf '{"claudeAiOauth":{"accessToken":"LIVE-ACCOUNT","expiresAt":99999999999999}}' > "$T/kc-shared.json"
printf '{"claudeAiOauth":{"accessToken":"NEW-ACCOUNT","expiresAt":99999999999999}}' > "$T/kc-namespaced.json"

# Stub that answers per-service, so a read of the wrong item is detectable.
# Single-quoted assignment, not a heredoc in a command substitution: the latter is
# parsed by the outer `set -u` shell and trips over the stub's own expansions.
PER_SVC='keychain_available() { return 0; }
keychain_account() { printf "tester"; }
read_keychain_creds() { printf "read SHARED\n" >> "$STUBLOG"; cat "$KC_SHARED" 2>/dev/null; }
read_keychain_creds_guarded() {
  printf "read %s\n" "${1:-DEFAULT}" >> "$STUBLOG"
  case "$1" in
    *-????????) [[ "${KC_NS_PRESENT:-1}" == 1 ]] && cat "$KC_NAMESPACED" 2>/dev/null ;;
  esac
}'

PRELUDE="$PER_SVC; claude_version_at_least() { return 0; }"
out="$(KC_SHARED="$T/kc-shared.json" KC_NAMESPACED="$T/kc-namespaced.json" STUBLOG="$T/log9a" \
  inhome "$H" 'materialize_profile_credentials "$HOME/.claude-profiles/fresh"; echo "rc=$?"')"
check "captures the NEW account"          '[[ "$out" == *"rc=0"* ]] && grep -q "NEW-ACCOUNT" "'"$D"'/.credentials.json"'
check "never the live account"            '! grep -q "LIVE-ACCOUNT" "'"$D"'/.credentials.json"'
check "read the namespaced item"          'grep -q "read Claude Code-credentials-" "'"$T"'/log9a"'
check "never read the shared item"        '! grep -q "read SHARED" "'"$T"'/log9a"'
check_macos "file at 0600"                '[[ "$(stat -f %Lp "'"$D"'/.credentials.json")" == "600" ]]'

# Modern CLI, namespaced item absent → must NOT silently grab the live credential.
rm -f "$D/.credentials.json"
out="$(KC_NS_PRESENT=0 KC_SHARED="$T/kc-shared.json" KC_NAMESPACED="$T/kc-namespaced.json" STUBLOG="$T/log9b" \
  inhome "$H" 'materialize_profile_credentials "$HOME/.claude-profiles/fresh"; echo "rc=$?"')"
check "modern CLI: fails rather than guess" '[[ "$out" == *"rc=1"* ]] && [[ ! -f "'"$D"'/.credentials.json" ]]'

# Old CLI, namespaced item absent → the shared item IS the new account there.
PRELUDE="$PER_SVC; claude_version_at_least() { return 1; }"
out="$(KC_NS_PRESENT=0 KC_SHARED="$T/kc-shared.json" KC_NAMESPACED="$T/kc-namespaced.json" STUBLOG="$T/log9c" \
  inhome "$H" 'materialize_profile_credentials "$HOME/.claude-profiles/fresh"; echo "rc=$?"')"
check "old CLI: falls back to shared"     '[[ "$out" == *"rc=0"* ]] && grep -q "LIVE-ACCOUNT" "'"$D"'/.credentials.json"'

# An existing file is never overwritten (Linux path, and re-runs).
printf '{"claudeAiOauth":{"accessToken":"ALREADY-THERE"}}' > "$D/.credentials.json"
out="$(KC_SHARED="$T/kc-shared.json" KC_NAMESPACED="$T/kc-namespaced.json" STUBLOG="$T/log9d" \
  inhome "$H" 'materialize_profile_credentials "$HOME/.claude-profiles/fresh"; echo "rc=$?"')"
check "existing file left alone"          '[[ "$out" == *"rc=0"* ]] && grep -q "ALREADY-THERE" "'"$D"'/.credentials.json"'
check "no Keychain read at all"           '[[ ! -f "'"$T"'/log9d" ]]'

# ── 10. the real ~/.claude was never touched ──────────────────────────────────
echo "10. sandbox containment"
check "no profile dir created in real HOME" "[[ ! -d '$HOME/.claude-profiles/other' ]]"

printf '\n%s passed, %s failed' "$PASS" "$FAIL"
[[ "$SKIP" -gt 0 ]] && printf ', %s skipped (macOS only)' "$SKIP"
printf '\n'
[[ "$FAIL" -eq 0 ]]
