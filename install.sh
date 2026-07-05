#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Installer for the `claudius` CLI (macOS + Linux).
#
# Run this from a checkout of the repo:
#     git clone https://github.com/theExtraTerrestrial/claudius.git ~/.claudius && bash ~/.claudius/install.sh
#
# By default it SYMLINKS `claudius` into a bin dir on your PATH, pointing at this
# checkout — so a later `git pull` updates the command with no reinstall. Use
# --copy for a standalone copy. Re-runnable / idempotent; undo with --uninstall.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CLI_NAME="claudius"
DEFAULT_PREFIX="${HOME}/.local/bin"

usage() {
  cat <<EOF
Install the ${CLI_NAME} CLI (macOS + Linux).

usage: $(basename "$0") [--prefix DIR] [--name NAME] [--copy] [--uninstall]

  --prefix DIR   bin dir to install into   (default: ${DEFAULT_PREFIX})
  --name NAME    command name to install   (default: ${CLI_NAME})
  --copy         copy files into DIR instead of symlinking to this checkout
                 (use when this checkout might move or be deleted)
  --uninstall    remove the installed command (and copied dashboard, if any)
  -h, --help     show this help
EOF
}

PREFIX="$DEFAULT_PREFIX"
NAME="$CLI_NAME"
COPY=false
UNINSTALL=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)    PREFIX="${2:?--prefix needs a value}"; shift 2 ;;
    --name)      NAME="${2:?--name needs a value}"; shift 2 ;;
    --copy)      COPY=true; shift ;;
    --uninstall) UNINSTALL=true; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Resolve the directory THIS installer lives in (following symlinks), so it finds
# the CLI + dashboard sitting beside it regardless of where it's run from.
# Portable: does not rely on GNU `readlink -f` (absent on stock macOS).
resolve_dir() {
  local src="${BASH_SOURCE[0]}" dir
  while [[ -h "$src" ]]; do
    dir="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd
}
SRC_DIR="$(resolve_dir)"
CLI_SRC="$SRC_DIR/claudius"
DASH_SRC="$SRC_DIR/claude-dashboard.rb"
HTML_SRC="$SRC_DIR/dashboard.html"
TARGET="$PREFIX/$NAME"

if [[ "$UNINSTALL" == true ]]; then
  removed=false
  [[ -e "$TARGET" || -L "$TARGET" ]] && { rm -f "$TARGET"; echo "Removed $TARGET"; removed=true; }
  # Remove sidecar files copied by a --copy install (never symlink sources).
  for extra in claude-dashboard.rb dashboard.html; do
    if [[ -f "$PREFIX/$extra" && ! -L "$PREFIX/$extra" ]]; then
      rm -f "$PREFIX/$extra"; echo "Removed $PREFIX/$extra"; removed=true
    fi
  done
  [[ "$removed" == true ]] || echo "Nothing to remove at $TARGET"
  exit 0
fi

# ── Preconditions ─────────────────────────────────────────────────────────────
for f in "$CLI_SRC" "$DASH_SRC" "$HTML_SRC"; do
  [[ -f "$f" ]] || { echo "error: missing file: $f" >&2; exit 1; }
done
if ! command -v ruby >/dev/null 2>&1; then
  echo "warning: ruby not found on PATH — install it before running ${NAME}." >&2
  echo "         e.g. 'sudo apt install ruby' (Linux) or 'brew install ruby' (macOS)." >&2
fi

mkdir -p "$PREFIX"
chmod +x "$CLI_SRC" 2>/dev/null || true

# ── Install ───────────────────────────────────────────────────────────────────
if [[ "$COPY" == true ]]; then
  cp "$CLI_SRC" "$TARGET"
  # Sidecar files must sit next to $TARGET so the CLI/dashboard find them by name.
  cp "$DASH_SRC" "$PREFIX/claude-dashboard.rb"
  cp "$HTML_SRC" "$PREFIX/dashboard.html"
  chmod +x "$TARGET"
  echo "Installed (copy):    $TARGET"
  echo "                     $PREFIX/claude-dashboard.rb"
  echo "                     $PREFIX/dashboard.html"
else
  ln -sfn "$CLI_SRC" "$TARGET"
  echo "Installed (symlink): $TARGET -> $CLI_SRC"
fi

# ── PATH wiring ───────────────────────────────────────────────────────────────
case ":$PATH:" in
  *":$PREFIX:"*)
    echo "PATH:                $PREFIX already on PATH ✓"
    ;;
  *)
    # Pick the shell rc to update. Prefer the login shell in $SHELL (zsh on modern
    # macOS, usually bash on Linux); if that's unset/unrecognized, fall back to
    # whichever rc already exists — zsh first, since macOS defaults to zsh.
    rc=""
    case "$(basename "${SHELL:-}")" in
      zsh)  rc="$HOME/.zshrc" ;;
      bash) [[ "$(uname)" == "Darwin" ]] && rc="$HOME/.bash_profile" || rc="$HOME/.bashrc" ;;
      *)
        if   [[ -f "$HOME/.zshrc" ]];        then rc="$HOME/.zshrc"
        elif [[ -f "$HOME/.bashrc" ]];       then rc="$HOME/.bashrc"
        elif [[ -f "$HOME/.bash_profile" ]]; then rc="$HOME/.bash_profile"
        elif [[ "$(uname)" == "Darwin" ]];   then rc="$HOME/.zshrc"   # mac default shell
        else rc="$HOME/.profile"
        fi
        ;;
    esac
    line="export PATH=\"$PREFIX:\$PATH\""
    if [[ -n "$rc" ]]; then
      if [[ -f "$rc" ]] && grep -qF "$PREFIX" "$rc"; then
        echo "PATH:                $rc already references $PREFIX ✓"
      else
        printf '\n# added by %s installer\n%s\n' "$NAME" "$line" >> "$rc"
        echo "PATH:                added $PREFIX to $rc"
        echo "                     run 'source $rc' or open a new terminal"
      fi
    else
      echo "PATH:                add this line to your shell profile:"
      echo "                       $line"
    fi
    ;;
esac

echo
echo "Done. Try:  $NAME help"
