#!/usr/bin/env bash
# Regression tests for the shared numeric loop configuration resolver.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/loop-config.sh"
PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

assert_value() {
  local name="$1" key="$2" want="$3"
  local got
  got=$(cd "$WORK/project" && bash "$CONFIG" --value "$key" 2>&1)
  local rc=$?
  if [[ "$rc" -eq 0 && "$got" == "$want" ]]; then
    PASS=$((PASS + 1)); echo "PASS: $name"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $name — expected [$want], got rc=$rc [$got]"
  fi
}

assert_failure() {
  local name="$1" key="$2"
  local got
  got=$(cd "$WORK/project" && bash "$CONFIG" --value "$key" 2>&1)
  local rc=$?
  if [[ "$rc" -ne 0 ]]; then
    PASS=$((PASS + 1)); echo "PASS: $name"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $name — expected non-zero, got [$got]"
  fi
}

mkdir -p "$WORK/project/.claude"
printf '%s\n' \
  'loop:' \
  '  max_turns: 7' \
  '  no_progress_after: 4' \
  '  max_spend_usd: 1.25' \
  > "$WORK/project/.claude/PROJECT.md"

assert_value "reads max_turns" max_turns 7
assert_value "reads no_progress_after" no_progress_after 4
assert_value "reads max_spend_usd" max_spend_usd 1.25

printf '%s\n' 'verification:' '  runner: auto' > "$WORK/project/.claude/PROJECT.md"
assert_value "missing loop block uses safe default" no_progress_after 2

printf '%s\n' \
  'loop:' \
  '  max_turns: 0' \
  '  no_progress_after: -1' \
  '  max_spend_usd: nope' \
  > "$WORK/project/.claude/PROJECT.md"
assert_value "invalid integer and spend values use defaults" max_turns 25
assert_value "invalid no-progress value uses default" no_progress_after 2
assert_value "invalid spend value uses default" max_spend_usd 2.00

printf '%s\n' \
  'loop:' \
  '  max_turns: 999 # clamp' \
  '  no_progress_after: 999' \
  '  max_spend_usd: 999.99' \
  > "$WORK/project/.claude/PROJECT.md"
assert_value "max_turns clamps independently" max_turns 60
assert_value "no-progress clamps independently" no_progress_after 5
assert_value "spend clamps independently" max_spend_usd 10.00

printf '%s\n' \
  'loop:' \
  '  max_turns: $(touch '"$WORK"'/executed)' \
  '  no_progress_after: `touch '"$WORK"'/executed`' \
  '  max_spend_usd: 1.25; touch '"$WORK"'/executed' \
  > "$WORK/project/.claude/PROJECT.md"
assert_value "PROJECT shell syntax remains inert data" max_turns 25
assert_value "hostile no-progress value remains inert" no_progress_after 2
assert_value "hostile spend value remains inert" max_spend_usd 2.00
if [[ ! -e "$WORK/executed" ]]; then
  PASS=$((PASS + 1)); echo "PASS: hostile PROJECT values did not execute"
else
  FAIL=$((FAIL + 1)); echo "FAIL: hostile PROJECT values executed shell code"
fi

rm -f "$WORK/project/.claude/PROJECT.md"
mkdir "$WORK/project/.claude/PROJECT.md"
assert_failure "non-regular PROJECT.md is rejected" max_turns
rm -rf "$WORK/project/.claude/PROJECT.md"
printf '%s\n' 'loop:' '  max_turns: 7' > "$WORK/project/.claude/PROJECT.md"
assert_failure "unknown value selector is rejected" not-a-loop-key

if [[ "$FAIL" -eq 0 ]]; then
  echo "All $PASS loop-config tests passed."
  exit 0
fi
echo "$FAIL loop-config tests failed."
exit 1
