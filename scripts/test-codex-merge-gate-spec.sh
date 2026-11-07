#!/usr/bin/env bash
set -euo pipefail

SPEC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/docs/superpowers/specs/2026-08-29-codex-ai-engineering-merge-gate-design.md"

for field in \
  'Codex-compatible hook logic' \
  'installation drift' \
  'CODEX_HOME/hooks/pr-action-safety.sh' \
  'same hook implementation' \
  'live PR-state verification'; do
  if ! grep -qF -- "$field" "$SPEC"; then
    echo "FAIL: spec does not document $field"
    exit 1
  fi
done

echo "PASS: spec documents the shared live-verification hook and Codex installation drift fix"

INSTALL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/install.sh"
for pattern in 'CODEX_HOME' 'CODEX_HOME/hooks' 'pr-action-safety.sh'; do
  if ! grep -qF -- "$pattern" "$INSTALL"; then
    echo "FAIL: installer does not synchronize Codex hook path ($pattern)"
    exit 1
  fi
done

echo "PASS: installer synchronizes the PR safety hook for Codex"

SYNC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/sync-codex-pr-action-hook.sh"
SOURCE_HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks/pr-action-safety.sh"
if [[ ! -x "$SYNC" ]]; then
  echo "FAIL: Codex hook synchronizer is missing or not executable"
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/codex/hooks"
printf '%s\n' 'protected target' > "$WORK/protected-target"
ln -s "$WORK/protected-target" "$WORK/codex/hooks/pr-action-safety.sh"

if ! bash "$SYNC" "$WORK/codex/hooks"; then
  echo "FAIL: Codex hook synchronizer failed for an existing hooks directory"
  exit 1
fi
if [[ -L "$WORK/codex/hooks/pr-action-safety.sh" ]] \
   || ! cmp -s "$SOURCE_HOOK" "$WORK/codex/hooks/pr-action-safety.sh" \
   || [[ "$(cat "$WORK/protected-target")" != 'protected target' ]]; then
  echo "FAIL: Codex hook synchronizer followed or preserved the destination symlink"
  exit 1
fi
if [[ ! -x "$WORK/codex/hooks/pr-action-safety.sh" ]]; then
  echo "FAIL: synchronized Codex hook is not executable"
  exit 1
fi
echo "PASS: Codex hook synchronization atomically replaces a malicious destination symlink"

MISSING="$WORK/missing/hooks"
if ! bash "$SYNC" "$MISSING"; then
  echo "FAIL: missing Codex hooks directory should be a no-op"
  exit 1
fi
if [[ -e "$MISSING" ]]; then
  echo "FAIL: synchronizer created an absent Codex hooks directory"
  exit 1
fi
echo "PASS: absent Codex hooks directory remains untouched"
