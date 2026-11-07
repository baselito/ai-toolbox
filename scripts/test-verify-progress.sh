#!/usr/bin/env bash
# Regression test for progress output from long bounded verifier commands.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_SH="$SCRIPT_DIR/verify.sh"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
failed() { FAIL=$((FAIL + 1)); echo "  FAIL: $1${2:+ — $2}"; }

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$name"; else failed "$name" "missing '$needle'"; fi
}
PROGRESS_FILE=$(mktemp)
DONE_FILE=$(mktemp)
rm -f "$DONE_FILE"
(
  RBC_PROGRESS_INTERVAL_S=1 RBC_PROGRESS_LABEL=progress-fixture \
    bash -c 'VERIFY_LIB_ONLY=1 . "$1" || exit 97; run_bounded_capture 3 bash -c "sleep 2"' \
    _ "$VERIFY_SH" 2>"$PROGRESS_FILE" >/dev/null
  : > "$DONE_FILE"
) &
RUNNER_PID=$!
PROGRESS_BEFORE_DONE=0
for _ in $(seq 1 40); do
  if [[ -s "$PROGRESS_FILE" && ! -e "$DONE_FILE" ]]; then
    PROGRESS_BEFORE_DONE=1
    break
  fi
  [[ -e "$DONE_FILE" ]] && break
  sleep 0.1
done
wait "$RUNNER_PID"
RUNNER_RC=$?
if [[ "$PROGRESS_BEFORE_DONE" -eq 1 ]] && grep -q "progress-fixture" "$PROGRESS_FILE"; then
  pass "progress runner emits a phase label before completion"
else
  failed "progress runner emits a phase label before completion" \
    "progress was not observed before the bounded command exited (rc=$RUNNER_RC)"
fi
rm -f "$PROGRESS_FILE" "$DONE_FILE"

if [[ "$FAIL" -eq 0 ]]; then
  echo "verify-progress: $PASS passed, $FAIL failed"
  exit 0
fi
echo "verify-progress: $PASS passed, $FAIL failed"
exit 1
