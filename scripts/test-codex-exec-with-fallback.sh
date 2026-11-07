#!/usr/bin/env bash
# test-codex-exec-with-fallback.sh — Unit tests for scripts/codex-exec-with-fallback.sh.
#
# Tests the pinned-model retry contract of the codex-review gate (see
# skills/codex-review/SKILL.md Step 3) with a fake `codex` executable on PATH,
# so no real Codex CLI, network, or quota is touched. The contract under test
# (flagged as mechanically-testable-but-untested by the Terra pre-PR review of
# PR #124):
#   1. model-specific error (both orderings + the CLI version-gate error)
#      → exactly ONE retry, without -m (unpinned, config default model)
#   2. spend-cap / network / timeout / other failures → NO retry (outage path)
#   3. success → NO retry
#   4. the retry OVERWRITES the out-file (the caller greps the FINAL attempt's
#      output for the spend-cap outage signal)
#   5. CODEX_MODEL="" (explicit empty) → unpinned single attempt, never retries
#
# Usage: ./scripts/test-codex-exec-with-fallback.sh
# Exits 0 if all tests pass, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FALLBACK="$SCRIPT_DIR/codex-exec-with-fallback.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

# Run the production script inside an environment where `codex` is a fake
# executable on PATH — same portable stub approach as test-review-pr-precheck.sh
# (exported bash functions are not reliably inherited on all platforms).
#
# Args: <out1> <rc1> <out2> <rc2> [<model>] [<effort>]
#   <out1>/<rc1> — what the fake codex prints / exits with on invocation 1
#   <out2>/<rc2> — same for invocation 2 (used only if the script retries)
#   <model>      — CODEX_MODEL for the run. Use literal __unset__ to not set it
#                  (script default applies) or empty string "" for unpinned mode.
#   <effort>     — CODEX_EFFORT for the run (default: unset → script default).
#
# Exposes results via globals:
#   RESULT_RC   — the production script's exit code
#   CALL_COUNT  — how many times the fake codex was invoked
#   CALL1/CALL2 — the argv line of each invocation ("" if not invoked)
#   OUT_CONTENT — final content of the out-file
run_fallback() {
  local out1="$1" rc1="$2" out2="$3" rc2="$4"
  # ${5-...} (no colon): an explicitly EMPTY 5th arg means CODEX_MODEL="" (unpinned
  # mode) and must NOT collapse to __unset__ — mirrors the production script's
  # own ${CODEX_MODEL-default} set-vs-empty semantics.
  local model="${5-__unset__}" effort="${6-__unset__}"

  local tmp_dir
  tmp_dir=$(mktemp -d)
  local trap_tmp_dir="$tmp_dir"
  trap "rm -rf '$trap_tmp_dir'" RETURN

  # Scripted responses for the fake codex, keyed by invocation number.
  printf '%s' "$out1" > "$tmp_dir/out.1"
  printf '%s' "$rc1"  > "$tmp_dir/rc.1"
  printf '%s' "$out2" > "$tmp_dir/out.2"
  printf '%s' "$rc2"  > "$tmp_dir/rc.2"
  : > "$tmp_dir/calls.log"

  # The fake codex: log argv, consume stdin (like the real `codex exec -`),
  # replay the scripted output + exit code for this invocation number.
  local fake_bin="$tmp_dir/bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/codex" <<'FAKE'
#!/usr/bin/env bash
cat > /dev/null                       # consume the prompt from stdin
echo "$*" >> "$FAKE_CODEX_DIR/calls.log"
N=$(grep -c '' "$FAKE_CODEX_DIR/calls.log")
cat "$FAKE_CODEX_DIR/out.$N" 2>/dev/null
exit "$(cat "$FAKE_CODEX_DIR/rc.$N" 2>/dev/null || echo 0)"
FAKE
  chmod +x "$fake_bin/codex"

  local prompt_file="$tmp_dir/prompt"
  local out_file="$tmp_dir/codex-out"
  echo "review this diff" > "$prompt_file"

  # Build the env for the child run. CODEX_MODEL uses set-vs-empty semantics
  # in the script (${VAR-default}), so "__unset__" must genuinely not set it.
  local env_args=(PATH="$fake_bin:$PATH" FAKE_CODEX_DIR="$tmp_dir")
  [ "$model" != "__unset__" ] && env_args+=(CODEX_MODEL="$model")
  [ "$effort" != "__unset__" ] && env_args+=(CODEX_EFFORT="$effort")

  env "${env_args[@]}" bash "$FALLBACK" "$prompt_file" "$out_file"
  RESULT_RC=$?

  CALL_COUNT=$(grep -c '' "$tmp_dir/calls.log")
  CALL1=$(sed -n '1p' "$tmp_dir/calls.log")
  CALL2=$(sed -n '2p' "$tmp_dir/calls.log")
  OUT_CONTENT=$(cat "$out_file" 2>/dev/null)
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1)); echo "PASS: $desc"
  else
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("$desc")
    echo "FAIL: $desc — expected [$expected], got [$actual]"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1)); echo "PASS: $desc"
  else
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("$desc")
    echo "FAIL: $desc — [$needle] not found in [$haystack]"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("$desc")
    echo "FAIL: $desc — [$needle] unexpectedly found in [$haystack]"
  else
    PASS=$((PASS + 1)); echo "PASS: $desc"
  fi
}

if [ ! -f "$FALLBACK" ]; then
  echo "FAIL: codex-exec-with-fallback.sh not found at $FALLBACK"
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Model error, CLI ordering ("Unknown model `x`") → exactly one unpinned retry
#    This exact ordering is what the real CLI binary emits — `model.*unknown`
#    alone misses it (the Terra finding on PR #124).
# ---------------------------------------------------------------------------
run_fallback 'ERROR: Unknown model `gpt-5.6-terra`' 1 'no P0/P1.' 0
assert_eq       "unknown-model (CLI ordering): retries exactly once" "2" "$CALL_COUNT"
assert_contains "unknown-model: first call is pinned" "-m gpt-5.6-terra" "$CALL1"
assert_not_contains "unknown-model: retry is unpinned (no -m)" " -m " " $CALL2 "
# The retry must preserve effort AND the safety flags — a regression that drops
# them would weaken review quality or relax execution constraints exactly on
# the model-error rescue path (automated-review finding, PR #124).
assert_contains "unknown-model: retry preserves effort" "model_reasoning_effort=xhigh" "$CALL2"
assert_contains "unknown-model: retry preserves read-only sandbox" "--sandbox read-only" "$CALL2"
assert_contains "unknown-model: retry preserves skip-git-repo-check" "--skip-git-repo-check" "$CALL2"
assert_eq       "unknown-model: final RC is the retry's RC" "0" "$RESULT_RC"
assert_eq       "unknown-model: out-file holds the retry output" "no P0/P1." "$OUT_CONTENT"

# ---------------------------------------------------------------------------
# 2. Model error, API ordering ("model … requires a newer version") → retry.
#    Observed live 2026-07-10: outdated CLI 0.141.0 + pinned gpt-5.6-terra
#    returned HTTP 400 with this message.
# ---------------------------------------------------------------------------
run_fallback "ERROR: The 'gpt-5.6-terra' model requires a newer version of Codex. Please upgrade to the latest app or CLI and try again." 1 'no P0/P1.' 0
assert_eq "version-gate error: retries exactly once" "2" "$CALL_COUNT"
assert_eq "version-gate error: final RC is the retry's RC" "0" "$RESULT_RC"

# ---------------------------------------------------------------------------
# 3. Model error, generic ordering ("model … not found") → retry.
# ---------------------------------------------------------------------------
run_fallback 'error: model gpt-5.6-terra not found' 1 'no P0/P1.' 0
assert_eq "model-not-found: retries exactly once" "2" "$CALL_COUNT"

# ---------------------------------------------------------------------------
# 4. Spend cap → NO retry (must take the caller's outage path, not burn quota).
# ---------------------------------------------------------------------------
run_fallback 'You hit your spend cap set by the owner of your workspace. Ask an owner to increase your spend cap to continue.' 1 'MUST NOT BE REACHED' 0
assert_eq "spend-cap: no retry" "1" "$CALL_COUNT"
assert_eq "spend-cap: non-zero RC preserved" "1" "$RESULT_RC"
assert_contains "spend-cap: out-file keeps the cap message for the caller's outage grep" "spend cap" "$OUT_CONTENT"

# ---------------------------------------------------------------------------
# 5. Credits exhausted → NO retry.
# ---------------------------------------------------------------------------
run_fallback 'Your workspace is out of credits. Add credits to continue.' 1 'MUST NOT BE REACHED' 0
assert_eq "out-of-credits: no retry" "1" "$CALL_COUNT"

# ---------------------------------------------------------------------------
# 6. Network error → NO retry.
# ---------------------------------------------------------------------------
run_fallback 'error sending request: connection refused' 1 'MUST NOT BE REACHED' 0
assert_eq "network error: no retry" "1" "$CALL_COUNT"

# ---------------------------------------------------------------------------
# 7. Timeout → NO retry, and the non-standard RC is preserved.
# ---------------------------------------------------------------------------
run_fallback 'request timed out' 124 'MUST NOT BE REACHED' 0
assert_eq "timeout: no retry" "1" "$CALL_COUNT"
assert_eq "timeout: RC 124 preserved" "124" "$RESULT_RC"

# ---------------------------------------------------------------------------
# 8. Success → NO retry, RC 0, output kept.
# ---------------------------------------------------------------------------
run_fallback 'no P0/P1.' 0 'MUST NOT BE REACHED' 0
assert_eq "success: no retry" "1" "$CALL_COUNT"
assert_eq "success: RC 0" "0" "$RESULT_RC"
assert_eq "success: out-file holds the review output" "no P0/P1." "$OUT_CONTENT"

# ---------------------------------------------------------------------------
# 9. Model error on attempt 1, retry ALSO fails (e.g. hits the cap) → the
#    out-file must hold the RETRY's output so the caller's spend-cap grep sees it.
# ---------------------------------------------------------------------------
run_fallback 'ERROR: Unknown model `gpt-5.6-terra`' 1 'You hit your spend cap set by the owner of your workspace.' 1
assert_eq       "retry-fails: exactly two calls (no third attempt)" "2" "$CALL_COUNT"
assert_eq       "retry-fails: final RC is the retry's failure" "1" "$RESULT_RC"
assert_contains "retry-fails: out-file overwritten with the retry's cap message" "spend cap" "$OUT_CONTENT"

# ---------------------------------------------------------------------------
# 10. A model error whose text ALSO cannot re-trigger on the unpinned attempt:
#     if the RETRY returns a model error too, there is still no third call.
# ---------------------------------------------------------------------------
run_fallback 'ERROR: Unknown model `gpt-5.6-terra`' 1 'ERROR: Unknown model `whatever-config-default`' 1
assert_eq "retry-model-error: exactly two calls (one-shot, never loops)" "2" "$CALL_COUNT"

# ---------------------------------------------------------------------------
# 11. CODEX_MODEL="" (explicit empty) → unpinned single attempt; a model error
#     must NOT retry (there is no pin to fall back from).
# ---------------------------------------------------------------------------
run_fallback 'ERROR: Unknown model `whatever`' 1 'MUST NOT BE REACHED' 0 ""
assert_eq           "unpinned mode: single attempt only" "1" "$CALL_COUNT"
assert_not_contains "unpinned mode: no -m flag" " -m " " $CALL1 "

# ---------------------------------------------------------------------------
# 12. Defaults and passthrough: default model pin, default effort xhigh,
#     custom CODEX_EFFORT honored, sandbox/read-only flags always present.
# ---------------------------------------------------------------------------
run_fallback 'no P0/P1.' 0 '' 0
assert_contains "defaults: pinned to gpt-5.6-terra" "-m gpt-5.6-terra" "$CALL1"
assert_contains "defaults: effort xhigh" "model_reasoning_effort=xhigh" "$CALL1"
assert_contains "defaults: read-only sandbox" "--sandbox read-only" "$CALL1"
assert_contains "defaults: skip-git-repo-check" "--skip-git-repo-check" "$CALL1"

run_fallback 'no P0/P1.' 0 '' 0 "__unset__" "high"
assert_contains "custom effort: model_reasoning_effort=high passed through" "model_reasoning_effort=high" "$CALL1"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed tests:"
  for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
  exit 1
fi
exit 0
