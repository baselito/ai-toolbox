#!/usr/bin/env bash
# Verify the retired editor-assistant integration has no remaining surface.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1${2:+ — $2}"; }

assert_contains() {
  local path="$1"
  local pattern="$2"
  if grep -Fq -- "$pattern" "$ROOT/$path" 2>/dev/null; then
    pass "migration guard present: $pattern"
  else
    fail "migration guard missing: $pattern"
  fi
}

assert_not_contains() {
  local path="$1"
  local pattern="$2"
  if grep -Fq -- "$pattern" "$ROOT/$path" 2>/dev/null; then
    fail "unexpected broad migration pattern: $pattern"
  else
    pass "migration cleanup is narrow: $pattern"
  fi
}

assert_absent() {
  local path="$1"
  if [[ ! -e "$ROOT/$path" && ! -L "$ROOT/$path" ]] \
    || [[ -d "$ROOT/$path" && -z "$(find "$ROOT/$path" -type f -print -quit 2>/dev/null)" ]]; then
    pass "absent: $path"
  else
    fail "present: $path"
  fi
}

assert_present() {
  local path="$1"
  if [[ -e "$ROOT/$path" ]]; then
    pass "preserved: $path"
  else
    fail "missing: $path"
  fi
}

assert_command_table_unique() {
  local duplicate
  duplicate=$(awk -F'|' '/^\| `\// {gsub(/[[:space:]]/, "", $2); print $2}' "$ROOT/CLAUDE.md" \
    | sort | uniq -d | head -1)
  if [[ -z "$duplicate" ]]; then
    pass "CLAUDE.md command table has unique entries"
  else
    fail "CLAUDE.md command table has duplicate entry" "$duplicate"
  fi
}

echo ""
echo "=== retired editor-assistant integration ==="

for path in \
  ".github/copilot-instructions.md" \
  ".github/instructions/ai-engineering" \
  ".github/scripts/sync-ai-instructions.sh" \
  ".github/sync-repos.txt" \
  ".github/workflows/sync-ai-instructions.yml" \
  "commands/install-copilot.md" \
  "scripts/install-copilot.sh" \
  "docs/how-to/copilot-integration.md"; do
  assert_absent "$path"
done

if ! command -v rg >/dev/null 2>&1; then
  fail "reference scan unavailable" "rg is required to prove no retired integration references remain"
else
  if REFERENCES=$(rg -n -i 'copilot' "$ROOT" \
      --hidden \
      --glob '!.git/**' \
      --glob '!.git' \
      --glob '!scripts/install.sh' \
      --glob '!scripts/test-removed-assistant.sh' \
      --glob '!.Codex/**' 2>/dev/null); then
    RG_STATUS=0
  else
    RG_STATUS=$?
  fi
  if [[ "$RG_STATUS" -eq 1 ]]; then
    pass "no retired integration references remain"
  elif [[ "$RG_STATUS" -eq 0 ]]; then
    fail "retired integration references remain" "$(printf '%s' "$REFERENCES" | head -20 | tr '\n' ' ')"
  else
    fail "reference scan failed" "rg exited with status $RG_STATUS"
  fi
fi

assert_contains "scripts/install.sh" "RETIRED_ASSISTANT_ITEMS"
assert_contains "scripts/install.sh" "RETIRED_ASSISTANT_FILENAMES"
assert_contains "scripts/install.sh" "sync-ai-instructions.yml"
assert_contains "scripts/install.sh" "rm -f \"\${RETIRED_ASSISTANT_ITEMS[@]}\""
assert_not_contains "scripts/install.sh" 'find "$PWD/.github/instructions/ai-engineering" -type f -name '\''*.instructions.md'\'''
assert_command_table_unique

for path in \
  "commands/goal.md" \
  "scripts/goal-loop" \
  "hooks/auto-poll-after-pr.sh" \
  "docs/how-to/goal-runs.md"; do
  assert_present "$path"
done

echo ""
echo "=== retired editor-assistant integration: $PASS passed, $FAIL failed ==="
(( FAIL == 0 ))
