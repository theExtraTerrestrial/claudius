#!/usr/bin/env bash
# Tests for the usage history and the "which account next" ranking — the two
# places claudius does arithmetic on a reading rather than just printing it.
# Everything happens under a throwaway HOME, so the real ~/.claude-profiles is
# never read from or written to, and no API call is ever made: every sample here
# is written by the test, in the exact format the status line appends.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/claudius"
# `ruby` here is an asdf shim that resolves installs relative to $HOME; point it at
# the real data dir so the fake HOME does not break the interpreter itself.
ASDF_KEEP="${ASDF_DATA_DIR:-$HOME/.asdf}"
REAL_HOME="$HOME"
NOW="$(date +%s)"
# A snapshot of the real profile root, so the last section can prove the suite
# never wrote to it. Taken before anything else runs. `ls` rather than `find
# -lname`, which is a GNU extension.
REAL_BEFORE="$(ls -A "$REAL_HOME/.claude-profiles" 2>/dev/null | sort)"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/claudius-hist.XXXXXX")"
trap 'rm -rf "$T"' EXIT
H="$T/home"
mkdir -p "$H/.claude-profiles" "$H/.claude"

cli() { HOME="$H" ASDF_DATA_DIR="$ASDF_KEEP" bash "$SCRIPT" "$@"; }
rb()  { HOME="$H" ASDF_DATA_DIR="$ASDF_KEEP" ruby "$@"; }

# Output goes to a file and assertions grep it. Interpolating a JSON payload full
# of quotes into an `eval`d [[ =~ ]] does not survive contact with real output.
say()  { cli "$@" > "$T/j" 2> "$T/err"; }
jhas() { if grep -qF -- "$2" "$T/j"; then ok "$1"; else bad "$1  (no '$2')"; fi; }
jno()  { if grep -qF -- "$2" "$T/j"; then bad "$1  ('$2' present)"; else ok "$1"; fi; }
ehas() { if grep -qF -- "$2" "$T/err"; then ok "$1"; else bad "$1  (no '$2')"; fi; }

# A profile with a history. `shape` is a ruby expression in i (0…n-1) giving the
# 5h utilization; the 7d is held flat so each window can be checked on its own.
# Samples land `step` seconds apart with the last one now — the same shape the
# status line's own appends leave behind.
mkprof() {
  local name="$1" shape="$2" n="$3" step="$4" u7="$5" r5="$6" r7="$7"
  local d="$H/.claude-profiles/$name"
  mkdir -p "$d"
  printf '{"claudeAiOauth":{"accessToken":"t","refreshToken":"r","expiresAt":%s}}\n' \
    "$(( (NOW + 3600) * 1000 ))" > "$d/.credentials.json"
  printf '{"oauthAccount":{"emailAddress":"%s@example.com"}}\n' "$name" > "$d/.claude.json"
  rb - "$d" "$shape" "$n" "$step" "$u7" "$r5" "$r7" "$NOW" <<'RB'
dir, shape, n, step, u7, r5, r7, now = ARGV
n = n.to_i; step = step.to_i; now = now.to_i
lines = (0...n).map do |i|
  "#{now - (n - 1 - i) * step} #{eval(shape.gsub('i', i.to_s))} #{u7} #{r5} #{r7}"
end
File.write(File.join(dir, '.usage.log'), lines.join("\n") + "\n") if n > 0
last = n.zero? ? nil : lines.last.split
File.write(File.join(dir, '.usage'),
  n.zero? ? "- - #{now} - -\n"
          : "#{last[1]} #{last[2]} #{last[0]} #{last[3]} #{last[4]}\n")
RB
}

wipe() { rm -rf "$H/.claude-profiles"; mkdir -p "$H/.claude-profiles"; }

# ── 1. a rate is only claimed when there is something to divide by ────────────
echo "1. a rate needs history behind it"
# 0 → 60% over an hour: 60%/h, and at 60% with the window three hours off, the
# ceiling arrives long before the reset does.
mkprof climbing 'i * 2' 31 120 40 "$((NOW + 10800))" "$((NOW + 400000))"
mkprof flat     '7'     31 120 12 "$((NOW + 10800))" "$((NOW + 400000))"
mkprof brandnew '5'      1 120 12 "$((NOW + 10800))" "$((NOW + 400000))"
mkprof empty    '0'      0 120 12 "$((NOW + 10800))" "$((NOW + 400000))"
say history climbing --json
jhas "the climb is measured"           '"rate5":60.0'
jno  "and a ceiling is projected"      '"eta5":null'
say history flat --json
jhas "a flat account has no trend"     '"rate5":0.0'
jhas "so nothing is projected"         '"eta5":null'
say history brandnew --json
jhas "one sample is not a rate"        '"rate5":null'
jhas "nor a projection"                '"eta5":null'
say history empty --json
jhas "no log at all is not an error"   '"n":0'
jhas "and reports no samples"          '"samples":[]'
say history brandnew
jhas "the report says so in words"     'no history yet'

# ── 2. the window a rate belongs to ───────────────────────────────────────────
echo "2. a reset ends the window, and the rate with it"
# Two windows in one file: an old one that ran to 90%, then a fresh one at 4%.
# Measuring across the boundary would report a large NEGATIVE rate. The reset
# epoch is what keeps them apart — it sits still inside a window and jumps when
# the window rolls, so it identifies the window exactly.
D="$H/.claude-profiles/rolled"; mkdir -p "$D"
printf '{"claudeAiOauth":{"accessToken":"t","expiresAt":%s}}\n' "$(( (NOW + 3600) * 1000 ))" \
  > "$D/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"rolled@example.com"}}\n' > "$D/.claude.json"
: > "$D/.usage.log"
for i in $(seq 0 20); do
  printf '%s %s 30 %s %s\n' "$(( NOW - 9000 + i * 120 ))" "$(( 50 + i * 2 ))" \
    "$(( NOW - 6000 ))" "$(( NOW + 400000 ))" >> "$D/.usage.log"
done
# 40 minutes of the new window, 0 → 4%: 6%/h.
for i in $(seq 0 20); do
  printf '%s %s 30 %s %s\n' "$(( NOW - 2400 + i * 120 ))" "$(( i / 5 ))" \
    "$(( NOW + 10800 ))" "$(( NOW + 400000 ))" >> "$D/.usage.log"
done
printf '4 30 %s %s %s\n' "$NOW" "$(( NOW + 10800 ))" "$(( NOW + 400000 ))" > "$D/.usage"
say history rolled --json
jno  "the rate is not negative"        '"rate5":-'
jhas "it reflects only this window"    '"rate5":6.0'
check "both windows are still on disk" "[[ \"\$(wc -l < '$D/.usage.log')\" -eq 42 ]]"

# ── 3. a projection past the reset is not a projection ────────────────────────
echo "3. a ceiling the window clears first is no ceiling"
# 60%/h with 60 points still to go needs an hour; the window resets in fifteen
# minutes, so there is nothing to warn about.
mkprof sprinter 'i' 41 60 12 "$((NOW + 900))" "$((NOW + 400000))"
say history sprinter --json
jhas "the rate is still reported"      '"rate5":60.0'
jhas "but no ceiling is claimed"       '"eta5":null'
say history sprinter
jhas "the report says which won"       'clears first'

# ── 4. pruning ────────────────────────────────────────────────────────────────
echo "4. the file is bounded without the appenders knowing"
D="$H/.claude-profiles/verbose"; mkdir -p "$D"
printf '{"claudeAiOauth":{"accessToken":"t","expiresAt":%s}}\n' "$(( (NOW + 3600) * 1000 ))" \
  > "$D/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"v@example.com"}}\n' > "$D/.claude.json"
# 12 days at a sample every two minutes, plus a torn line and a junk line: a
# killed append must not take the history down with it.
rb - "$D" "$NOW" <<'RB'
dir, now = ARGV[0], ARGV[1].to_i
n = 12 * 24 * 30
rows = (0...n).map { |i| "#{now - (n - 1 - i) * 120} #{i % 90} 30 #{now + 10_800} #{now + 400_000}" }
File.write(File.join(dir, '.usage.log'), rows.join("\n") + "\nnot a sample\n0 1 2\n")
File.write(File.join(dir, '.usage'), "#{(n - 1) % 90} 30 #{now} #{now + 10_800} #{now + 400_000}\n")
RB
before="$(wc -l < "$D/.usage.log")"
cli history verbose --json > /dev/null
after="$(wc -l < "$D/.usage.log")"
check "an oversized log is thinned"    "[[ '$after' -lt '$before' && '$after' -gt 100 ]]"
check "nothing older than 8 days survives" \
  "[[ \"\$(head -1 '$D/.usage.log' | cut -d' ' -f1)\" -ge \$(( NOW - 8 * 86400 - 1000 )) ]]"
fine="$(rb -e 'n=ARGV[0].to_i; puts File.readlines(ARGV[1]).count{|l| l.split[0].to_i > n - 21_600}' \
  "$NOW" "$D/.usage.log")"
check "the last 6 hours keep full resolution" "[[ '$fine' -gt 150 ]]"
cli history verbose --json > /dev/null
check "a second read changes nothing"  "[[ \"\$(wc -l < '$D/.usage.log')\" -eq '$after' ]]"
check "the log stays private"          "[[ \"\$(ls -l '$D/.usage.log' | cut -c1-10)\" == '-rw-------' ]]"
check "torn and junk lines are gone"   "! grep -q 'not a sample' '$D/.usage.log'"
check "no temp file is left behind"    "[[ ! -e '$D/.usage.log.tmp' ]]"

# ── 5. the ranking ────────────────────────────────────────────────────────────
echo "5. which account next"
wipe
mkprof roomy  '6'  31 120 10  "$((NOW + 10800))" "$((NOW + 400000))"
mkprof tight  '80' 31 120 44  "$((NOW + 10800))" "$((NOW + 400000))"
mkprof walled '3'  31 120 100 "$((NOW + 3600))"  "$((NOW + 200000))"
echo "tight" > "$H/.claude-profiles/.active_profile"
check "the account with room wins"     "[[ \"\$(cli next)\" == 'roomy' ]]"
check "being active does not save a tight one" "[[ \"\$(cli next)\" != 'tight' ]]"
say next --json
jhas "the walled account is ranked too" '"name":"walled"'
jhas "but not as a candidate"          '"eligible":false'
jhas "the pick comes with its reason"  '"reason":"90% left on the 7d"'
jhas "and the wait is not reported while something is usable" '"blocked_until":null'
say next --explain
jhas "--explain marks the pick"        '→ roomy'
jhas "and shows the burn column"       'burn'

echo "6. the smaller window is the one that counts"
wipe
# 3% used on the 5h is not headroom when the 7d sits at 96%.
mkprof looksfree '3'  31 120 96 "$((NOW + 10800))" "$((NOW + 400000))"
mkprof honest    '30' 31 120 30 "$((NOW + 10800))" "$((NOW + 400000))"
check "the fuller 7d loses"            "[[ \"\$(cli next)\" == 'honest' ]]"
say next --json
jhas "and the binding window is named" '"binding":"7d"'

echo "7. nothing usable is an answer, not a crash"
wipe
mkprof done1 '100' 31 120 100 "$((NOW + 3600))" "$((NOW + 200000))"
mkprof done2 '100' 31 120 100 "$((NOW + 7200))" "$((NOW + 300000))"
say next
check "it exits non-zero"              "! cli next >/dev/null 2>&1"
check "and names no account on stdout" "[[ ! -s '$T/j' ]]"
ehas "the wait is reported instead"    'first to clear is done1'
say next --json
jhas "the JSON says who clears first"  '"first_to_clear":"done1"'

echo "8. no profiles at all"
wipe
check "history says so plainly"        "[[ \"\$(cli history)\" == 'No profiles found.' ]]"
check "next declines quietly"          "[[ -z \"\$(cli next 2>/dev/null)\" ]]"

echo "9. the real profile root was never touched"
REAL_AFTER="$(ls -A "$REAL_HOME/.claude-profiles" 2>/dev/null | sort)"
check "its contents are unchanged"      '[[ "$REAL_BEFORE" == "$REAL_AFTER" ]]'
check "and none of these profiles is in it" "[[ ! -e '$REAL_HOME/.claude-profiles/roomy' ]]"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
