#!/usr/bin/env bash
# Tests for `claudius agents`: which account owns each of Claude Code's background
# agents, and that every action on one goes through THAT account's config dir.
# The routing is the point — each config dir runs its own supervisor with its own
# sockets, so a stop or an attach sent through the wrong one either misses or, for
# attach, starts a worker on the wrong account.
#
# Everything happens under a throwaway HOME, and `claude` is a stub on PATH that
# serves a fixture listing and records how it was called. No real agent, no real
# supervisor, no API call. Platform: the credential file path, stated explicitly
# (keychain_available stubbed false) — the macOS Keychain branch of run_profile
# is tests/run-scope.sh's to cover.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/claudius"
ASDF_KEEP="${ASDF_DATA_DIR:-$HOME/.asdf}"
REAL_HOME="$HOME"
REAL_BEFORE="$(ls -A "$REAL_HOME/.claude-profiles" 2>/dev/null | sort)"
NOW="$(date +%s)"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/claudius-agents.XXXXXX")"
SLEEPER=""
trap '[[ -n "$SLEEPER" ]] && kill "$SLEEPER" 2>/dev/null; rm -rf "$T"' EXIT
H="$T/home"
BIN="$T/bin"
LOG="$T/claude.log"
mkdir -p "$BIN"

# Same shape as tests/share.sh — a plausible pool and stored profiles.
mkhome() {
  local h="$1"
  rm -rf "$h"; mkdir -p "$h/.claude"
  mkdir -p "$h/.claude/agents" "$h/.claude/projects/-repo-a" "$h/.claude/sessions" "$h/.claude/jobs"
  : > "$h/.claude/projects/-repo-a/aaa.jsonl"
  printf '{"claudeAiOauth":{"accessToken":"live","expiresAt":%s}}\n' "$(( (NOW + 3600) * 1000 ))" \
    > "$h/.claude/.credentials.json"
  printf '{}\n' > "$h/.claude/settings.json"
  printf '{"oauthAccount":{"emailAddress":"live@example.com"},"projects":{},"hasCompletedOnboarding":true}\n' \
    > "$h/.claude.json"
}
mkprofile() {
  local h="$1" name="$2" email="$3" u5="$4"
  local d="$h/.claude-profiles/$name"
  mkdir -p "$d"
  printf '{"claudeAiOauth":{"accessToken":"tok-%s","refreshToken":"rt","expiresAt":%s}}\n' \
    "$name" "$(( (NOW + 3600) * 1000 ))" > "$d/.credentials.json"
  printf '{"oauthAccount":{"emailAddress":"%s"},"hasCompletedOnboarding":true,"projects":{}}\n' \
    "$email" > "$d/.claude.json"
  printf '%s 10 %s - -\n' "$u5" "$NOW" > "$d/.usage"
}

# The stub: `agents --json --all` serves the fixture; anything else is logged as
# "<config dir or GLOBAL>|arg|arg|…" so the assertions can see both WHO was asked
# and the exact argv (a message with spaces must stay one argument).
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == agents && "${2:-}" == --json ]]; then cat "$FIXTURE"; exit 0; fi
if [[ "${1:-}" == --version ]]; then echo "2.1.286 (Claude Code)"; exit 0; fi
line="${CLAUDE_CONFIG_DIR:-GLOBAL}"
for a in "$@"; do line+="|$a"; done
printf '%s\n' "$line" >> "$CLAUDE_LOG"
SH
chmod +x "$BIN/claude"

inhome() {
  HOME="$H" ASDF_DATA_DIR="$ASDF_KEEP" PATH="$BIN:$PATH" FIXTURE="$T/fixture.json" CLAUDE_LOG="$LOG" \
    bash -c "source '$SCRIPT' help >/dev/null 2>&1; keychain_available() { return 1; }; init_colors; $*"
}
say() { inhome "$@" > "$T/out" 2> "$T/err"; echo $? > "$T/rc"; }
has()  { if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1  (no '$2' in $(basename "$3"))"; fi; }
hasnt(){ if grep -qF -- "$2" "$3"; then bad "$1  ('$2' in $(basename "$3"))"; else ok "$1"; fi; }
lastcall() { tail -n 1 "$LOG" 2>/dev/null; }
calls()    { [[ -f "$LOG" ]] && wc -l < "$LOG" | tr -d ' ' || echo 0; }

mkhome "$H"
# asdf also picks the ruby VERSION from ~/.tool-versions; section 5 cds into the
# fake home, where there would otherwise be none and `ruby` would vanish.
[[ -f "$REAL_HOME/.tool-versions" ]] && cp "$REAL_HOME/.tool-versions" "$H/.tool-versions"
mkprofile "$H" work "work@example.com" 10
mkprofile "$H" alt  "alt@example.com"  90
P="$H/.claude-profiles"

# A process standing in for an interactive session started by `claudius run alt`:
# its environment is the only place that says which account it is on.
CLAUDE_CONFIG_DIR="$P/alt" sleep 300 &
SLEEPER=$!

# A live supervisor (this shell) holding cccc3333 for alt, and a dead one that
# last held dddd4444 for work.
mkdir -p "$P/alt/daemon" "$P/work/daemon"
printf '{"proto":1,"supervisorPid":%s,"workers":{"cccc3333":{"pid":1}}}\n' "$$" > "$P/alt/daemon/roster.json"
printf '{"proto":1,"supervisorPid":999999,"workers":{"dddd4444":{"pid":1}}}\n' > "$P/work/daemon/roster.json"

job() {  # id state updatedAt-epoch config-dir-or-empty detail
  local d="$H/.claude/jobs/$1" penv='{}'
  mkdir -p "$d"
  [[ -n "$4" ]] && penv="{\"CLAUDE_CONFIG_DIR\":\"$4\"}"
  HOME="$REAL_HOME" ruby -rjson -rtime -e 'id, st, up, penv, det, d = ARGV
    File.write(File.join(d, "state.json"), JSON.generate(
      "state" => st, "detail" => det, "intent" => "intent of #{id}",
      "updatedAt" => Time.at(up.to_i).utc.iso8601, "providerEnv" => JSON.parse(penv)))' \
    "$1" "$2" "$3" "$penv" "$5" "$d"
}
job aaaa1111 idle    "$(( NOW - 60 ))"     "$P/work" "wrote the parser"
job bbbb2222 blocked "$(( NOW - 30 ))"     ""        "Is there a JIRA key?"
job cccc3333 busy    "$(( NOW - 10 ))"     ""        "running tests"
job eeee7777 done    "$(( NOW - 259200 ))" "$P/work" "shipped long ago"
job ffff8888 idle    "$(( NOW - 90 ))"     "$T/elsewhere" "hand-set config dir"
job aaaa9999 done    "$(( NOW - 120 ))"    "$P/alt"  "PR opened"
mkdir -p "$T/elsewhere"

ms() { echo $(( ($1) * 1000 )); }
cat > "$T/fixture.json" <<JSON
[
 {"pid":1,"id":"aaaa1111","cwd":"$H/repo","kind":"background","startedAt":$(ms NOW-600),"sessionId":"aaaa1111-0000-0000-0000-000000000001","name":"parser","status":"idle"},
 {"pid":1,"id":"bbbb2222","cwd":"$H/repo","kind":"background","startedAt":$(ms NOW-600),"sessionId":"bbbb2222-0000-0000-0000-000000000002","name":"jira","status":"idle","state":"blocked"},
 {"pid":1,"id":"cccc3333","cwd":"$H/repo","kind":"background","startedAt":$(ms NOW-600),"sessionId":"cccc3333-0000-0000-0000-000000000003","name":"tests","status":"busy"},
 {"pid":1,"id":"dddd4444","cwd":"$H/repo","kind":"background","startedAt":$(ms NOW-600),"sessionId":"dddd4444-0000-0000-0000-000000000004","name":"no record","status":"idle"},
 {"pid":$SLEEPER,"cwd":"$H/repo","kind":"interactive","startedAt":$(ms NOW-600),"sessionId":"55555555-0000-0000-0000-000000000005","name":"terminal on alt","status":"idle"},
 {"pid":999998,"cwd":"/somewhere","kind":"interactive","startedAt":$(ms NOW-600),"sessionId":"66666666-0000-0000-0000-000000000006","name":"terminal unknown","status":"idle"},
 {"id":"eeee7777","cwd":"$H/repo","kind":"background","startedAt":$(ms NOW-300000),"sessionId":"eeee7777-0000-0000-0000-000000000007","name":"old","status":"idle","state":"done"},
 {"pid":1,"id":"ffff8888","cwd":"$H/repo","kind":"background","startedAt":$(ms NOW-600),"sessionId":"ffff8888-0000-0000-0000-000000000008","name":"elsewhere","status":"idle"},
 {"id":"aaaa9999","cwd":"$H/repo","kind":"background","startedAt":$(ms NOW-600),"sessionId":"aaaa9999-0000-0000-0000-000000000009","name":"pr","status":"idle","state":"done"}
]
JSON

field() {  # id key — one field of one agent from the last --json output
  ruby -rjson -e 'a = JSON.parse(File.read(ARGV[0])).find { |r| r["id"] == ARGV[1] }
    v = a && a[ARGV[2]]; print(a.nil? ? "MISSING" : v.nil? ? "null" : v.to_s)' "$T/out" "$1" "$2"
}

# ── 1. ownership ──────────────────────────────────────────────────────────────
echo "1. which account owns each agent"
say 'cmd_agents --json --all'
check "job record names the profile"           '[[ "$(field aaaa1111 profile)" == work ]]'
check "empty providerEnv means ~/.claude"      '[[ "$(field bbbb2222 global)" == true && "$(field bbbb2222 profile)" == null ]]'
check "a live roster beats the job record"     '[[ "$(field cccc3333 profile)" == alt ]]'
check "no record: a dead roster still names it" '[[ "$(field dddd4444 profile)" == work ]]'
check "interactive: read from its environment" '[[ "$(field 55555555 profile)" == alt ]]'
check "nothing known: the global account"      '[[ "$(field 66666666 global)" == true ]]'
check "a hand-set dir is not passed off as a profile" \
  '[[ "$(field ffff8888 profile)" == null && "$(field ffff8888 global)" == false && "$(field ffff8888 config)" == "$T/elsewhere" ]]'
check "a dead interactive pid is not live"     '[[ "$(field 66666666 live)" == false ]]'

# ── 2. shape, order and the finished filter ───────────────────────────────────
echo "2. contract shape and order"
check "every field of the contract is present" \
  "ruby -rjson -e 'k = %w[id sid kind name state profile global config cwd short detail intent started updated pid live]
    exit(JSON.parse(File.read(ARGV[0])).all? { |r| (k - r.keys).empty? } ? 0 : 1)' '$T/out'"
check "needs-you first, then working"          "ruby -rjson -e 'a = JSON.parse(File.read(ARGV[0])); exit(a[0][%q(id)] == %q(bbbb2222) && a[1][%q(id)] == %q(cccc3333) ? 0 : 1)' '$T/out'"
check "finished ones sort last"                "ruby -rjson -e 'a = JSON.parse(File.read(ARGV[0])); exit(a.last(2).all? { |r| r[%q(state)] == %q(done) } ? 0 : 1)' '$T/out'"
check "detail comes from the job record"       '[[ "$(field bbbb2222 detail)" == "Is there a JIRA key?" ]]'
check "short writes \$HOME as ~"               '[[ "$(field aaaa1111 short)" == "~/repo" ]]'
say 'cmd_agents --json'
check "old finished agents are hidden by default" '[[ "$(field eeee7777 id)" == MISSING ]]'
check "recent finished ones are not"           '[[ "$(field aaaa9999 id)" == aaaa9999 ]]'
say 'agents_data tsv false'
has  "tsv says how many it hid"                $'#\x1f1' "$T/out"
hasnt "no credential reaches the listing"      'tok-' "$T/out"
say 'cmd_agents --json --all'
hasnt "nor the json"                           'tok-' "$T/out"
say 'cmd_agents </dev/null'
has  "non-tty prints a table"                  'needs you' "$T/out"
has  "with the owner"                          'alt' "$T/out"

# ── 3. control verbs go through the owner ─────────────────────────────────────
echo "3. stop / logs / rm through the owning config dir"
: > "$LOG"
say 'cmd_agents stop aaaa1111'
check "stop: the profile's config dir"         '[[ "$(lastcall)" == "$P/work|stop|aaaa1111" ]]'
say 'cmd_agents logs bbbb2222'
check "logs: a global agent via plain claude"  '[[ "$(lastcall)" == "GLOBAL|logs|bbbb2222" ]]'
say 'cmd_agents rm cccc'
check "rm: by prefix, via the live roster"     '[[ "$(lastcall)" == "$P/alt|rm|cccc3333" ]]'
say 'cmd_agents rm aaaa9999 --discard-unpushed abc@wt1'
check "rm passes its flags through"            '[[ "$(lastcall)" == "$P/alt|rm|aaaa9999|--discard-unpushed|abc@wt1" ]]'
say 'cmd_agents stop ffff8888'
check "a hand-set dir is still addressed"      '[[ "$(lastcall)" == "$T/elsewhere|stop|ffff8888" ]]'
n="$(calls)"
say 'cmd_agents stop aaaa'
check "an ambiguous prefix is refused"         '[[ "$(cat "$T/rc")" != 0 && "$(calls)" == "$n" ]]'
has  "and says so"                             'matches 2 agents' "$T/err"
say 'cmd_agents stop nope'
check "an unknown id is refused"               '[[ "$(cat "$T/rc")" != 0 && "$(calls)" == "$n" ]]'
say 'cmd_agents stop 55555555'
check "a terminal session is not stopped from here" '[[ "$(cat "$T/rc")" != 0 && "$(calls)" == "$n" ]]'
has  "and the page says where it lives"        'terminal that started it' "$T/err"

# ── 4. attach goes through run (credentials prepared) ─────────────────────────
echo "4. attach"
say 'cmd_agents attach aaaa1111'
check "attach: as the owning profile"          '[[ "$(lastcall)" == "$P/work|attach|aaaa1111" ]]'
check "via run — the profile got wired"        '[[ -L "$P/work/projects" ]]'
say 'cmd_agents attach bbbb2222'
check "attach a global agent: plain claude"    '[[ "$(lastcall)" == "GLOBAL|attach|bbbb2222" ]]'
n="$(calls)"
say 'cmd_agents attach ffff8888'
check "a dir claudius does not own: refused"   '[[ "$(cat "$T/rc")" != 0 && "$(calls)" == "$n" ]]'

# ── 5. new ────────────────────────────────────────────────────────────────────
echo "5. new"
mkdir -p "$H/repo" "$H/plain"
git -C "$H/repo" init -q 2>/dev/null
say 'cd "$HOME/plain" && cmd_agents_new --profile work "fix the login timeout"'
check "outside a repo: no worktree"            '[[ "$(lastcall)" == "$P/work|--bg|-n|fix the login timeout|fix the login timeout" ]]'
say 'cd "$HOME/repo" && cmd_agents_new --profile alt --name "Fix Login: Timeout!" "do it"'
check "in a repo: a worktree named after it"   '[[ "$(lastcall)" == "$P/alt|--bg|-n|Fix Login: Timeout!|-w|fix-login-timeout|do it" ]]'
say 'cd "$HOME/repo" && cmd_agents_new --profile alt --no-worktree "same checkout"'
check "--no-worktree shares the checkout"      '[[ "$(lastcall)" == "$P/alt|--bg|-n|same checkout|same checkout" ]]'
say 'cd "$HOME/plain" && cmd_agents_new "pick for me"'
check "auto: the account next ranks first"     '[[ "$(lastcall)" == "$P/work|--bg|-n|pick for me|pick for me" ]]'
printf '100 10 %s %s -\n' "$NOW" "$(( NOW + 3600 ))" > "$P/work/.usage"
printf '100 10 %s %s -\n' "$NOW" "$(( NOW + 7200 ))" > "$P/alt/.usage"
n="$(calls)"
say 'cd "$HOME/plain" && cmd_agents_new "nowhere to go"'
check "every account at its limit: refused"    '[[ "$(cat "$T/rc")" != 0 && "$(calls)" == "$n" ]]'
has  "and next says why"                       'Every account is at a limit' "$T/err"
say 'cmd_agents_new'
check "no message is a usage error"            '[[ "$(cat "$T/rc")" == 2 ]]'

# ── 6. the transcript view ────────────────────────────────────────────────────
echo "6. show: the conversation, readable"
TD="$H/.claude/projects/-repo-wt"
mkdir -p "$TD"
HOME="$REAL_HOME" ruby -rjson -e '
  big = "x" * 300_000
  rows = [
    { "type" => "user", "timestamp" => "2026-10-01T10:00:00Z", "message" => { "role" => "user", "content" => "fix the login timeout" } },
    { "type" => "user", "isMeta" => true, "timestamp" => "2026-10-01T10:00:01Z", "message" => { "content" => "META-SHOULD-NOT-SHOW" } },
    { "type" => "user", "timestamp" => "2026-10-01T10:00:02Z", "message" => { "content" => "<system-reminder>REMINDER-SHOULD-NOT-SHOW</system-reminder>" } },
    { "type" => "assistant", "timestamp" => "2026-10-01T10:00:03Z", "message" => { "content" => [
      { "type" => "thinking", "thinking" => "THINKING-SHOULD-NOT-SHOW" },
      { "type" => "text", "text" => "Looking at the auth module first." },
      { "type" => "tool_use", "name" => "Bash", "input" => { "command" => "npm test -- auth", "description" => "Run the auth specs" } },
      { "type" => "tool_use", "name" => "Read", "input" => { "file_path" => "/repo/src/auth.ts" } } ] } },
    { "type" => "user", "timestamp" => "2026-10-01T10:00:04Z", "message" => { "content" => [
      { "type" => "tool_result", "is_error" => true, "content" => "Exit code 1 timeout exceeded" },
      { "type" => "tool_result", "content" => "RESULT-SHOULD-NOT-SHOW" } ] } },
    { "type" => "user", "timestamp" => "2026-10-01T10:00:05Z", "message" => { "content" => [{ "type" => "tool_result", "content" => big }] } },
    { "type" => "assistant", "isSidechain" => true, "timestamp" => "2026-10-01T10:00:06Z", "message" => { "content" => [{ "type" => "text", "text" => "SIDECHAIN-SHOULD-NOT-SHOW" }] } },
    { "type" => "user", "timestamp" => "2026-10-01T10:00:07Z", "message" => { "content" => "<command-name>/compact</command-name>" } },
  ]
  File.write(ARGV[0], rows.map { |r| JSON.generate(r) }.join("\n") + "\nnot json at all\n")
' "$TD/aaaa1111-0000-0000-0000-000000000001.jsonl"
say 'cmd_agents show aaaa1111'
has   "your message, under 'you'"             'fix the login timeout' "$T/out"
has   "Claude's reply"                        'Looking at the auth module first.' "$T/out"
has   "a tool call as one line, by its description" '▸ Bash  Run the auth specs' "$T/out"
has   "a file tool by its path"               '▸ Read  /repo/src/auth.ts' "$T/out"
has   "a failed tool call is said"            '✗ Exit code 1 timeout exceeded' "$T/out"
has   "a slash command shows as itself"       '/compact' "$T/out"
for x in META REMINDER THINKING RESULT SIDECHAIN; do
  hasnt "skipped: $x"                         "$x-SHOULD-NOT-SHOW" "$T/out"
done
hasnt "a huge tool result is not dumped"      'xxxxxxxxxx' "$T/out"
hasnt "not a raw terminal capture"            $'\r' "$T/out"
hasnt "no colour into a pipe"                 $'\e[' "$T/out"
check "found in a worktree's project dir, by id" '[[ "$(cat "$T/rc")" == 0 ]]'
say 'cmd_agents show bbbb2222'
has   "no transcript yet: said, not an error" 'No transcript for session' "$T/out"

# ── 7. the real home ──────────────────────────────────────────────────────────
echo "7. the real profile root was never touched"
check "real ~/.claude-profiles unchanged" \
  '[[ "$(ls -A "$REAL_HOME/.claude-profiles" 2>/dev/null | sort)" == "$REAL_BEFORE" ]]'
check "no sandbox link into the real home" "[[ -z \"\$(find '$T' -lname '$REAL_HOME/.claude/*' 2>/dev/null)\" ]]"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
