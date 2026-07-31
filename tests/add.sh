#!/usr/bin/env bash
# Tests for adding an account from the browser — the sidecar's job model.
#
# No real sign-in happens. The sidecar is started with --script pointing at a STUB
# that imitates `claudius add`: it prints the same sign-in URL and the same
# "Paste code here if prompted > " prompt (no trailing newline, exactly as the real
# flow leaves it), waits on stdin, and writes a credentials file. That is enough to
# drive every branch — the code channel, the newline the sidecar supplies itself
# when credentials appear, the reaper, and the cleanup after a failure — while the
# real `claude auth login` is never invoked and no account is ever touched.
#
# The suite is also where the security rules are enforced rather than merely
# stated: every response is checked for the pasted code and for the token the stub
# writes, and every mutating endpoint is checked for its CSRF guard.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIDECAR="$ROOT_DIR/claude-dashboard.rb"
PORT="${CLAUDIUS_TEST_PORT:-8796}"
ASDF_KEEP="${ASDF_DATA_DIR:-$HOME/.asdf}"
REAL_HOME="$HOME"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

ruby -e "require 'webrick'" 2>/dev/null || {
  printf 'skipped: webrick not available\n'; exit 0; }
if ruby -rsocket -e "TCPSocket.new('127.0.0.1', $PORT).close" 2>/dev/null; then
  printf 'skipped: port %s is already in use (set CLAUDIUS_TEST_PORT)\n' "$PORT"; exit 0
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/claudius-add.XXXXXX")"
H="$T/home"
mkdir -p "$H/.claude-profiles" "$H/.claude"
SECRET_TOKEN="stub-token-must-never-be-served"
CODE="paste-code-must-never-be-echoed"

# ── the stub CLI ──────────────────────────────────────────────────────────────
# Modes, via STUB_MODE:
#   code      — waits for a pasted code, then writes credentials (the paste variant)
#   callback  — writes credentials on its own after a beat (the browser variant)
#   fail      — never writes credentials and exits non-zero
#   hang      — prints the prompt and never does anything else (for the reaper)
cat > "$T/stub" <<'STUB'
#!/usr/bin/env bash
# Stands in for `add` ONLY. Every other subcommand goes to the real CLI (its path
# arrives in $REAL_CLI), so the read-only endpoints — and the profile list the page
# reloads on success — behave exactly as they do in production, under this suite's
# throwaway HOME. A quoted heredoc, so nothing below is expanded at write time.
if [[ "$1" != add ]]; then exec bash "$REAL_CLI" "$@"; fi
name=""; activate=true
for a in "$@"; do
  case "$a" in
    add) ;;
    --no-activate) activate=false ;;
    *) [[ -z "$name" ]] && name="$a" ;;
  esac
done
dir="$HOME/.claude-profiles/$name"
mkdir -p "$dir"
printf '%s\n' "$$" > "$HOME/stub-pid"
printf 'activate=%s\n' "$activate" > "$HOME/stub-args"
printf 'Opening browser to sign in…\n'
printf 'If the browser did not open, visit: https://claude.example.invalid/oauth?state=abc\n'
printf 'Paste code here if prompted > '
writecreds() { printf '{"claudeAiOauth":{"accessToken":"%s","expiresAt":9999999999999}}\n' \
  "$STUB_TOKEN" > "$dir/.credentials.json"; }
case "${STUB_MODE:-code}" in
  code)
    IFS= read -r code || exit 1
    [[ -n "$code" ]] || exit 1
    writecreds
    IFS= read -r _ignored          # the trailing "press enter"
    printf '\n✓ Created profile %s.\n' "$name"
    ;;
  callback)
    sleep 1
    writecreds
    IFS= read -r _ignored          # the trailing "press enter"
    printf '\n✓ Created profile %s.\n' "$name"
    ;;
  fail)
    IFS= read -r _code
    printf '\nClaude login did not complete; profile %s was not created.\n' "$name" >&2
    rmdir "$dir" 2>/dev/null
    exit 1
    ;;
  hang)
    # A child of its own, so the test can prove the whole process GROUP is
    # signalled — killing the stub alone would leave this behind.
    sleep 599 &
    printf '%s\n' "$!" > "$HOME/stub-child-pid"
    wait
    ;;
esac
STUB
chmod +x "$T/stub"

# ── an HTTP client, in Ruby (curl is not a claudius dependency) ────────────────
cat > "$T/req.rb" <<'RB'
require 'net/http'
require 'json'
method, path, token, body = ARGV[0], ARGV[1], ARGV[2].to_s, ARGV[3]
uri = URI("http://127.0.0.1:#{ENV['PORT']}#{path}")
req = (method == 'POST' ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
req['X-CSRF-Token'] = token unless token.empty?
req.body = body if body
res = Net::HTTP.start(uri.host, uri.port, read_timeout: 20) { |h| h.request(req) }
puts res.code
puts res.body
RB

start_sidecar() {
  HOME="$H" ASDF_DATA_DIR="$ASDF_KEEP" STUB_MODE="${1:-code}" STUB_TOKEN="$SECRET_TOKEN" \
    CLAUDIUS_ADD_DEADLINE="${2:-600}" REAL_CLI="$ROOT_DIR/claudius" \
    ruby "$SIDECAR" --port "$PORT" --root "$H/.claude-profiles" --script "$T/stub" \
    > "$T/sidecar.log" 2>&1 &
  SIDE=$!
  for _ in $(seq 1 60); do
    ruby -rsocket -e "TCPSocket.new('127.0.0.1', $PORT).close" 2>/dev/null && break
    sleep 0.25
  done
  # The page carries the token; read it back the way a browser would.
  TOKEN="$(PORT="$PORT" ruby "$T/req.rb" GET / | grep -o 'csrf-token" content="[a-f0-9]*"' \
    | head -1 | sed 's/.*content="//; s/"//')"
}
stop_sidecar() {
  [[ -n "${SIDE:-}" ]] && kill "$SIDE" 2>/dev/null
  wait "$SIDE" 2>/dev/null
  SIDE=""
}
trap 'stop_sidecar; rm -rf "$T"' EXIT

req()  { PORT="$PORT" ruby "$T/req.rb" "$@"; }
code() { req "$@" | head -1; }
body() { req "$@" | tail -n +2; }

# ── 1. the guards ─────────────────────────────────────────────────────────────
echo "1. what the endpoints refuse"
start_sidecar code
check "the sidecar came up"            "[[ -n \"\$TOKEN\" ]]"
check "GET /api/add is not allowed"    "[[ \"\$(code GET /api/add)\" == 405 ]]"
check "a POST without the CSRF token is refused" \
  "[[ \"\$(code POST '/api/add?profile=x')\" == 403 ]]"
check "so is the code channel"         "[[ \"\$(code POST /api/add/code)\" == 403 ]]"
check "and cancelling"                 "[[ \"\$(code POST /api/add/cancel)\" == 403 ]]"
check "a name with a slash is refused" \
  "[[ \"\$(code POST '/api/add?profile=a%2Fb' \"\$TOKEN\")\" == 400 ]]"
check "an empty name is refused" \
  "[[ \"\$(code POST '/api/add?profile=' \"\$TOKEN\")\" == 400 ]]"
mkdir -p "$H/.claude-profiles/taken"
check "a name already in use is refused" \
  "[[ \"\$(code POST '/api/add?profile=taken' \"\$TOKEN\")\" == 409 ]]"
check "status with no job is a 404"    "[[ \"\$(code GET /api/add/status)\" == 404 ]]"

# ── 2. the paste-a-code variant ───────────────────────────────────────────────
echo "2. the variant where the site shows you a code"
out="$(body POST "/api/add?profile=fresh" "$TOKEN")"
check "the job starts"                 "grep -q '\"ok\":true' <<< \"\$out\""
check "a second sign-in is refused while one runs" \
  "[[ \"\$(code POST '/api/add?profile=other' \"\$TOKEN\")\" == 409 ]]"
sleep 1
st="$(body GET /api/add/status)"
check "the sign-in URL is handed to the page" \
  "grep -q 'claude.example.invalid/oauth' <<< \"\$st\""
check "the page is told a code may be needed" "grep -q '\"needs_code\":true' <<< \"\$st\""
check "and it is still running"         "grep -q '\"state\":\"running\"' <<< \"\$st\""
check "--no-activate is passed by default" \
  "grep -q 'activate=false' '$H/stub-args'"

codeout="$(body POST /api/add/code "$TOKEN" "{\"code\":\"$CODE\"}")"
check "the code is accepted"            "grep -q '\"ok\":true' <<< \"\$codeout\""
check "and the response says nothing else" "[[ \"\$(tr -d ' \n' <<< \"\$codeout\")\" == '{\"ok\":true}' ]]"

for _ in $(seq 1 40); do
  st="$(body GET /api/add/status)"
  grep -q '"state":"done"' <<< "$st" && break
  sleep 0.25
done
check "the job completes"               "grep -q '\"state\":\"done\"' <<< \"\$st\""
check "the sidecar answered the trailing prompt itself" \
  "grep -q 'Created profile fresh' <<< \"\$st\""
check "the new profile is real"          "[[ -f '$H/.claude-profiles/fresh/.credentials.json' ]]"
check "and comes back with the real profile list" \
  "grep -q '\"profiles\":\[' <<< \"\$st\" && grep -q '\"active\":' <<< \"\$st\""

echo "3. nothing secret is ever served"
check "the pasted code is not in the status" "! grep -qF '$CODE' <<< \"\$st\""
check "nor is the token in the credentials file" "! grep -qF '$SECRET_TOKEN' <<< \"\$st\""
check "nor anywhere in the profile list"  "! req GET /api/profiles | grep -qF '$SECRET_TOKEN'"
check "nor in the sidecar's own output"   "! grep -qF '$CODE' '$T/sidecar.log'"
check "nor is the code left in the job"   "! grep -qF '$CODE' <<< \"\$(body GET /api/add/status)\""
stop_sidecar

# ── 4. the variant that needs no code ─────────────────────────────────────────
echo "4. the variant where the browser hands it over"
rm -rf "$H/.claude-profiles"; mkdir -p "$H/.claude-profiles"
start_sidecar callback
body POST "/api/add?profile=auto" "$TOKEN" > /dev/null
for _ in $(seq 1 60); do
  st="$(body GET /api/add/status)"
  grep -q '"state":"done"' <<< "$st" && break
  sleep 0.25
done
check "it finishes with no code posted"  "grep -q '\"state\":\"done\"' <<< \"\$st\""
check "because the credentials appearing is the signal" \
  "[[ -f '$H/.claude-profiles/auto/.credentials.json' ]]"
stop_sidecar

echo "5. activate is a choice, not a side effect"
rm -rf "$H/.claude-profiles"; mkdir -p "$H/.claude-profiles"
start_sidecar callback
body POST "/api/add?profile=switch&activate=1" "$TOKEN" > /dev/null
sleep 2
check "asking for it passes it through"  "grep -q 'activate=true' '$H/stub-args'"
stop_sidecar

# ── 6. failure leaves nothing behind ──────────────────────────────────────────
echo "6. a sign-in that does not complete"
rm -rf "$H/.claude-profiles"; mkdir -p "$H/.claude-profiles"
start_sidecar fail
body POST "/api/add?profile=doomed" "$TOKEN" > /dev/null
sleep 1
body POST /api/add/code "$TOKEN" '{"code":"whatever"}' > /dev/null
for _ in $(seq 1 40); do
  st="$(body GET /api/add/status)"
  grep -q '"state":"failed"' <<< "$st" && break
  sleep 0.25
done
check "the job reports failure"          "grep -q '\"state\":\"failed\"' <<< \"\$st\""
check "it says so in words"              "grep -q 'did not complete' <<< \"\$st\""
check "and no half-made profile remains" "[[ ! -e '$H/.claude-profiles/doomed' ]]"
stop_sidecar

# ── 7. the reaper ─────────────────────────────────────────────────────────────
echo "7. a sign-in nobody finishes"
rm -rf "$H/.claude-profiles"; mkdir -p "$H/.claude-profiles"
start_sidecar hang 2
body POST "/api/add?profile=abandoned" "$TOKEN" > /dev/null
for _ in $(seq 1 60); do
  st="$(body GET /api/add/status)"
  grep -q '"state":"expired"' <<< "$st" && break
  sleep 0.25
done
check "the deadline fires"               "grep -q '\"state\":\"expired\"' <<< \"\$st\""
check "the abandoned profile is removed" "[[ ! -e '$H/.claude-profiles/abandoned' ]]"
check "no stub process is left running" \
  "! kill -0 \"\$(cat '$H/stub-pid')\" 2>/dev/null"
check "and neither is its child" \
  "! kill -0 \"\$(cat '$H/stub-child-pid')\" 2>/dev/null"
check "and a new sign-in is allowed again" \
  "[[ \"\$(code POST '/api/add?profile=second' \"\$TOKEN\")\" == 200 ]]"
stop_sidecar

# ── 8. cancelling ─────────────────────────────────────────────────────────────
echo "8. cancelling one in flight"
rm -rf "$H/.claude-profiles"; mkdir -p "$H/.claude-profiles"
start_sidecar hang
body POST "/api/add?profile=nevermind" "$TOKEN" > /dev/null
sleep 1
check "the profile dir exists while it runs" "[[ -d '$H/.claude-profiles/nevermind' ]]"
out="$(body POST /api/add/cancel "$TOKEN")"
check "cancel is accepted"               "grep -q '\"ok\":true' <<< \"\$out\""
check "and the dir is cleaned up"        "[[ ! -e '$H/.claude-profiles/nevermind' ]]"
check "the code channel is closed after" \
  "[[ \"\$(code POST /api/add/code \"\$TOKEN\" '{\"code\":\"x\"}')\" == 409 ]]"

echo "9. the sidecar takes its children with it"
body POST "/api/add?profile=orphan" "$TOKEN" > /dev/null
sleep 1
stop_sidecar
sleep 1
check "no stub survives the shutdown" \
  "! kill -0 \"\$(cat '$H/stub-pid')\" 2>/dev/null"
check "nor does its child" \
  "! kill -0 \"\$(cat '$H/stub-child-pid')\" 2>/dev/null"
check "and its profile dir is gone"      "[[ ! -e '$H/.claude-profiles/orphan' ]]"

echo "10. the real profile root was never touched"
check "no profile from this suite is in it" \
  "[[ ! -e '$REAL_HOME/.claude-profiles/fresh' && ! -e '$REAL_HOME/.claude-profiles/doomed' ]]"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
