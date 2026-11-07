#!/usr/bin/env bash
# Regression tests for the project-configured Claude loop launcher.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="$SCRIPT_DIR/loop-launch.sh"
PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail_test() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
pass_test() { PASS=$((PASS + 1)); echo "PASS: $1"; }

mkdir -p "$WORK/bin" "$WORK/project/.claude" \
  "$WORK/home/Library/Application Support/Claude/claude-code/test/claude.app/Contents/MacOS"
cat > "$WORK/bin/claude" <<'MALICIOUS'
#!/usr/bin/env bash
printf 'malicious-path-binary\n' > "$FAKE_CLAUDE_OUTPUT"
MALICIOUS
chmod +x "$WORK/bin/claude"
cat > "$WORK/home/Library/Application Support/Claude/claude-code/test/claude.app/Contents/MacOS/claude" <<'FAKE'
#!/usr/bin/env bash
printf 'turns=%s\nstop_cap=%s\nno_progress=%s\nargc=%s\narg1=<%s>\narg2=<%s>\narg3=<%s>\narg4=<%s>\n' \
  "${CLAUDE_CODE_MAX_TURNS-}" "${CLAUDE_CODE_STOP_HOOK_BLOCK_CAP-}" \
  "${LOOP_NO_PROGRESS_AFTER-}" "$#" "${1-}" "${2-}" "${3-}" "${4-}" \
  > "$FAKE_CLAUDE_OUTPUT"
FAKE
chmod +x "$WORK/home/Library/Application Support/Claude/claude-code/test/claude.app/Contents/MacOS/claude"

run_launcher() {
  (cd "$WORK/project" && \
    FAKE_CLAUDE_OUTPUT="$WORK/output" \
      PATH="$WORK/bin:/usr/bin:/bin" \
      HOME="$WORK/home" \
      bash "$LAUNCHER" "$@")
  RC=$?
  OUTPUT=$(cat "$WORK/output" 2>/dev/null || true)
}

printf '%s\n' \
  'loop:' \
  '  max_turns: 10' \
  '  no_progress_after: 3' \
  '  max_spend_usd: 1.50' \
  > "$WORK/project/.claude/PROJECT.md"

run_launcher --print 'work on the goal'
if [[ "$RC" -eq 0 && "$OUTPUT" == *"turns=10"* \
   && "$OUTPUT" == *"stop_cap=10"* \
   && "$OUTPUT" == *"no_progress=3"* \
   && "$OUTPUT" == *"argc=4"* \
   && "$OUTPUT" == *"arg1=<--max-budget-usd>"* \
   && "$OUTPUT" == *"arg2=<1.50>"* \
   && "$OUTPUT" == *"arg3=<--print>"* \
   && "$OUTPUT" == *"arg4=<work on the goal>"* ]]; then
  pass_test "project loop values reach native Claude limits with intact argv"
else
  fail_test "project loop values reach native Claude limits with intact argv (rc=$RC output=$OUTPUT)"
fi

printf '%s\n' \
  'loop:' \
  '  max_turns: 999' \
  '  no_progress_after: 999' \
  '  max_spend_usd: 999.99' \
  > "$WORK/project/.claude/PROJECT.md"
run_launcher --print bounded
if [[ "$RC" -eq 0 && "$OUTPUT" == *"turns=60"* \
   && "$OUTPUT" == *"stop_cap=60"* \
   && "$OUTPUT" == *"no_progress=5"* \
   && "$OUTPUT" == *"arg1=<--max-budget-usd>"* \
   && "$OUTPUT" == *"arg2=<10.00>"* \
   && "$OUTPUT" == *"arg3=<--print>"* \
   && "$OUTPUT" == *"arg4=<bounded>"* ]]; then
  pass_test "project loop values are tighten-only clamped"
else
  fail_test "project loop values are tighten-only clamped (rc=$RC output=$OUTPUT)"
fi

printf '%s\n' 'loop:' '  max_turns: nope' '  max_spend_usd: nope' \
  > "$WORK/project/.claude/PROJECT.md"
run_launcher --print defaults
if [[ "$RC" -eq 0 && "$OUTPUT" == *"turns=25"* \
   && "$OUTPUT" == *"stop_cap=25"* \
   && "$OUTPUT" == *"arg1=<--max-budget-usd>"* \
   && "$OUTPUT" == *"arg2=<2.00>"* \
   && "$OUTPUT" == *"arg3=<--print>"* \
   && "$OUTPUT" == *"arg4=<defaults>"* ]]; then
  pass_test "invalid numeric overrides fall back safely"
else
  fail_test "invalid numeric overrides fall back safely (rc=$RC output=$OUTPUT)"
fi

run_launcher --max-budget-usd 99 --print duplicate-budget
if [[ "$RC" -eq 2 ]]; then
  pass_test "caller cannot replace the project spend bound"
else
  fail_test "caller cannot replace the project spend bound (rc=$RC output=$OUTPUT)"
fi

run_launcher --max-budget-usd=99 --print duplicate-budget-equals
if [[ "$RC" -eq 2 ]]; then
  pass_test "caller cannot replace spend bound with equals syntax"
else
  fail_test "caller cannot replace spend bound with equals syntax (rc=$RC output=$OUTPUT)"
fi

run_launcher --max-turns 99 --print duplicate-turns
if [[ "$RC" -eq 2 ]]; then
  pass_test "caller cannot replace the project turn bound"
else
  fail_test "caller cannot replace the project turn bound (rc=$RC output=$OUTPUT)"
fi

run_launcher --max-turns=99 --print duplicate-turns-equals
if [[ "$RC" -eq 2 ]]; then
  pass_test "caller cannot replace turn bound with equals syntax"
else
  fail_test "caller cannot replace turn bound with equals syntax (rc=$RC output=$OUTPUT)"
fi

# A user-local npm installation must be preferred over a project-controlled
# PATH shim when no native app location exists.
PORTABLE_HOME="$WORK/portable-home"
mkdir -p "$PORTABLE_HOME/.local/bin" "$WORK/portable-project/.claude"
cp "$WORK/home/Library/Application Support/Claude/claude-code/test/claude.app/Contents/MacOS/claude" \
  "$PORTABLE_HOME/.local/bin/claude"
chmod +x "$PORTABLE_HOME/.local/bin/claude"
printf '%s\n' 'loop:' '  max_turns: 7' '  no_progress_after: 2' '  max_spend_usd: 0.75' \
  > "$WORK/portable-project/.claude/PROJECT.md"
(cd "$WORK/portable-project" && \
  FAKE_CLAUDE_OUTPUT="$WORK/portable-output" \
    PATH="$WORK/bin:/usr/bin:/bin" HOME="$PORTABLE_HOME" \
    bash "$LAUNCHER" --print portable)
RC=$?
OUTPUT=$(cat "$WORK/portable-output" 2>/dev/null || true)
if [[ "$RC" -eq 0 && "$OUTPUT" == *"turns=7"* && "$OUTPUT" == *"arg2=<0.75>"* ]]; then
  pass_test "user-local Claude installation works without trusting project PATH"
else
  fail_test "user-local Claude installation works without trusting project PATH (rc=$RC output=$OUTPUT)"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "All $PASS loop-launch tests passed."
  exit 0
fi
echo "$FAIL loop-launch tests failed."
exit 1
