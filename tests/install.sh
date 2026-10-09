#!/usr/bin/env bash
# Sandbox tests for `claudius update` and `claudius uninstall`. Everything happens
# under a throwaway HOME, against a throwaway git upstream built from the working
# tree's files — never this checkout's own remote, never the real ~/.claude. PATH
# is cut down to the sandbox bin plus ruby and the base system, so `claude` is
# absent: both commands must work without it (uninstall especially).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# `ruby` here is an asdf shim that resolves installs relative to $HOME; point it at
# the real data dir so the fake HOME does not break the interpreter itself.
ASDF_KEEP="${ASDF_DATA_DIR:-$HOME/.asdf}"
RUBY_DIR="$(dirname "$(command -v ruby)")"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
H="$T/home"; BIN="$T/bin"; UP="$T/upstream.git"; CO="$H/.claudius"
G() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@"; }
SBPATH="$BIN:$RUBY_DIR:/usr/bin:/bin"
cli() { HOME="$H" ASDF_DATA_DIR="$ASDF_KEEP" PATH="$SBPATH" bash "$@"; }

# A fresh upstream with the working tree's files in one commit, and a clone of it
# where the installer would put one.
mkrepo() {
  rm -rf "$T/src" "$UP" "$H" "$BIN"
  mkdir -p "$T/src" "$H/.claude" "$BIN"
  cp "$REPO"/{claudius,claude-dashboard.rb,dashboard.html,statusline.sh,install.sh} "$T/src/"
  ( cd "$T/src" && G init -q && G add -A && G commit -qm init ) >/dev/null
  G clone -q --bare "$T/src" "$UP"
  G clone -q "$UP" "$CO"
}
# Push one more commit to the upstream through a second clone.
upstream_commit() {
  rm -rf "$T/other"; G clone -q "$UP" "$T/other"
  echo "$1" >> "$T/other/NEWS"
  ( cd "$T/other" && G add NEWS && G commit -qm "$1" && G push -q ) >/dev/null 2>&1
}
head_of() { git -C "$1" rev-parse HEAD; }

echo "update"
mkrepo
out="$(cli "$CO/claudius" update 2>&1)"; rc=$?
check "an up-to-date checkout exits 0"            '[[ $rc == 0 ]]'
check "…and says so"                              '[[ "$out" == *"Already up to date"* ]]'

upstream_commit "second change"
before="$(head_of "$CO")"
out="$(cli "$CO/claudius" update --check 2>&1)"; rc=$?
check "--check exits 0 with an update waiting"    '[[ $rc == 0 ]]'
check "--check names the waiting commit"          '[[ "$out" == *"second change"* ]]'
check "--check moves nothing"                     '[[ "$(head_of "$CO")" == "$before" ]]'

out="$(cli "$CO/claudius" update 2>&1)"; rc=$?
check "update fast-forwards"                      '[[ $rc == 0 && "$(head_of "$CO")" == "$(git -C "$UP" rev-parse main)" ]]'
check "…and lists what it pulled"                 '[[ "$out" == *"second change"* ]]'

# Through the PATH symlink the installer makes: the checkout is still found.
ln -s "$CO/claudius" "$BIN/claudius"
upstream_commit "third change"
out="$(HOME="$H" ASDF_DATA_DIR="$ASDF_KEEP" PATH="$SBPATH" claudius update 2>&1)"; rc=$?
check "update works through the PATH symlink"     '[[ $rc == 0 && "$(head_of "$CO")" == "$(git -C "$UP" rev-parse main)" ]]'

upstream_commit "fourth change"
echo "# local edit" >> "$CO/statusline.sh"
before="$(head_of "$CO")"
out="$(cli "$CO/claudius" update 2>&1)"; rc=$?
check "a dirty checkout is refused"               '[[ $rc != 0 && "$out" == *"local changes"* ]]'
check "…and left exactly as it was"               '[[ "$(head_of "$CO")" == "$before" && "$(tail -1 "$CO/statusline.sh")" == "# local edit" ]]'
git -C "$CO" checkout -q -- statusline.sh

( cd "$CO" && echo x > MINE && G add MINE && G commit -qm mine ) >/dev/null
before="$(head_of "$CO")"
out="$(cli "$CO/claudius" update 2>&1)"; rc=$?
check "a diverged checkout is refused"            '[[ $rc != 0 && "$out" == *"cannot fast-forward"* ]]'
check "…and its commit survives"                  '[[ "$(head_of "$CO")" == "$before" ]]'

mkdir -p "$T/copy"; cp "$REPO/claudius" "$T/copy/"
out="$(cli "$T/copy/claudius" update 2>&1)"; rc=$?
check "a --copy install is refused, with a reason" '[[ $rc != 0 && "$out" == *"not a git checkout"* ]]'

echo "uninstall"
# A plausible installed state: a symlink on PATH, our status line globally and in
# one profile, a second profile with a status line of its own.
mkinstalled() {
  mkrepo
  ln -s "$CO/claudius" "$BIN/claudius"
  mkdir -p "$H/.claude-profiles/work" "$H/.claude-profiles/mine"
  printf '{"claudeAiOauth":{"accessToken":"live"}}\n' > "$H/.claude/.credentials.json"
  printf '{"statusLine":{"type":"command","command":"bash %s/statusline.sh"},"env":{"A":"1"}}\n' "$CO" \
    > "$H/.claude/settings.json"
  printf '{"statusLine":{"type":"command","command":"bash %s/statusline.sh"}}\n' "$CO" \
    > "$H/.claude-profiles/work/settings.json"
  printf '{"statusLine":{"type":"command","command":"my-own-line"}}\n' \
    > "$H/.claude-profiles/mine/settings.json"
  printf '{"claudeAiOauth":{"accessToken":"tok-work"}}\n' > "$H/.claude-profiles/work/.credentials.json"
}

mkinstalled
out="$(echo n | cli "$BIN/claudius" uninstall 2>&1)"; rc=$?
check "answering no cancels"                      '[[ $rc != 0 && -L "$BIN/claudius" ]]'
check "…and leaves the status line"               'grep -q statusline.sh "$H/.claude/settings.json"'
check "the prompt names the command it removes"   '[[ "$out" == *"$BIN/claudius"* ]]'

out="$(echo y | cli "$BIN/claudius" uninstall 2>&1)"; rc=$?
check "answering yes uninstalls"                  '[[ $rc == 0 ]]'
check "the PATH symlink is gone"                  '[[ ! -e "$BIN/claudius" && ! -L "$BIN/claudius" ]]'
check "our global status line is gone"            '! grep -q statusLine "$H/.claude/settings.json"'
check "…other global settings stay"               'grep -q "\"A\"" "$H/.claude/settings.json"'
check "our profile status line is gone"           '! grep -q statusLine "$H/.claude-profiles/work/settings.json"'
check "someone else's status line is kept"        'grep -q my-own-line "$H/.claude-profiles/mine/settings.json"'
check "profiles are kept without --purge"         '[[ -f "$H/.claude-profiles/work/.credentials.json" ]]'
check "…and the output says where"                '[[ "$out" == *"Profiles kept"* ]]'
check "the live sign-in is untouched"             '[[ -f "$H/.claude/.credentials.json" ]]'
check "the checkout is untouched"                 '[[ -f "$CO/claudius" && -d "$CO/.git" ]]'
check "no token in the output"                    '[[ "$out" != *tok-work* && "$out" != *live\"* ]]'

mkinstalled
out="$(cli "$BIN/claudius" uninstall --purge --yes 2>&1)"; rc=$?
check "--purge --yes needs no answer"             '[[ $rc == 0 && ! -L "$BIN/claudius" ]]'
check "--purge forgets the profiles"              '[[ ! -e "$H/.claude-profiles" ]]'
check "…but never the live sign-in"               '[[ -f "$H/.claude/.credentials.json" ]]'

# A --copy install: the script and its sidecars sit in the bin dir.
mkinstalled; rm "$BIN/claudius"
cp "$CO"/{claudius,claude-dashboard.rb,dashboard.html} "$BIN/"
out="$(cli "$BIN/claudius" uninstall -y 2>&1)"; rc=$?
check "a --copy install removes the copy"         '[[ $rc == 0 && ! -e "$BIN/claudius" ]]'
check "…and its sidecar files"                    '[[ ! -e "$BIN/claude-dashboard.rb" && ! -e "$BIN/dashboard.html" ]]'
check "…but not the checkout it came from"        '[[ -f "$CO/claude-dashboard.rb" && -f "$CO/dashboard.html" ]]'

mkinstalled
out="$(cli "$BIN/claudius" uninstall --bogus 2>&1)"; rc=$?
check "an unknown flag is a usage error"          '[[ $rc == 2 && -L "$BIN/claudius" ]]'

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
