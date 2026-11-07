#!/usr/bin/env bash
set -euo pipefail

# Synchronize the canonical PR-action safety hook into an already-installed
# Codex hooks directory. The destination may be a symlink left by another
# process, so never copy to or chmod the destination path directly.

CODEX_HOOKS_DIR="${1:?usage: sync-codex-pr-action-hook.sh CODEX_HOOKS_DIR}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$REPO_ROOT/hooks/pr-action-safety.sh"
DEST="$CODEX_HOOKS_DIR/pr-action-safety.sh"

[[ -d "$CODEX_HOOKS_DIR" ]] || exit 0
[[ -f "$SOURCE" ]] || {
  echo "source hook is missing: $SOURCE" >&2
  exit 1
}

# mktemp creates the temporary file without following a pre-existing symlink;
# rename then atomically replaces the final destination entry itself.
TMP="$(mktemp "$CODEX_HOOKS_DIR/.pr-action-safety.sh.XXXXXX")"
cleanup() {
  if [[ -n "${TMP:-}" && -e "$TMP" ]]; then
    rm -f "$TMP"
  fi
}
trap cleanup EXIT

umask 077
cp "$SOURCE" "$TMP"
chmod 755 "$TMP"
mv -f "$TMP" "$DEST"
TMP=""
trap - EXIT
