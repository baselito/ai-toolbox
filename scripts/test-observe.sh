#!/usr/bin/env bash
# test-observe.sh — acceptance tests for scripts/observe.sh.
#
# The script under test is the SENSOR for observed work. It exists because two
# observers failed structurally (both incidents are written out in
# observe.sh's header), so these tests assert the two properties that
# distinguish this sensor from those failures. Each test names the EXACT edit to
# observe.sh that makes it fail — a detector nobody has watched fail is not a
# detector, and this repo has recently shipped several that could not.
#
#   CLAIM A — A FALSE CLAIM CANNOT SURVIVE *PROSE*. The agent supplies only a
#             claim; the script re-runs the probes and computes the
#             contradiction. T2 and T3 assert a fabricated "working" and a false
#             "good" are both caught by ARITHMETIC, with no model in the path.
#             ⚠️ THE CLAIM WAS OVERSTATED ONCE — the agent also chooses the
#             PROBE, and `--progress-probe 'date +%s'` made every "working"
#             claim look delta-positive with no work behind it. T16 pins the
#             declare-time rejection of a self-advancing probe, and states the
#             residual: a probe advancing on a slower cycle still gets through.
#   CLAIM B — NO WAIT IS UNBOUNDED. T1, T4, T8, T11 and T19 are REAL-TIME tests:
#             they let a real clock run. T4 replays the literal predicate that
#             once ran eleven hours and proves it now ends in two minutes; T11
#             proves a `--tick-s 999999` watcher (measured: ~11.5 days of sleep)
#             cannot outlive its own caps; T19 covers the per-probe bound, which
#             had NO test at all — removing it left this whole suite green.
#
# ⛔ THE REAL-TIME TESTS TAKE ~11.5 MINUTES OF WALL CLOCK, AND THAT IS THE POINT. ⛔
# (Measured: 684s for a full clean run. This line said "~4 minutes" for a long
# time and it was wrong — verify.sh's first attempt at a bound was sized from it
# and would have failed a HEALTHY run. If you add a real-time test, re-time the
# suite and update BOTH this line and OBSERVE_TEST_LIMIT_S in verify.sh.)
# The claim under test is about elapsed time. A version of these tests that
# mocked the clock would assert the arithmetic and not the behaviour, and the
# behaviour is exactly what incident 1's monitor got wrong — it "paced itself"
# through 40 minutes of checks in 48 seconds. T1, T4 and T11 run CONCURRENTLY
# (separate OBSERVER_ROOTs, separate watchers, separate output files) so those
# three cost one wait rather than three.
#
# Where a bound is what is under test but the WAIT is not, the fixture's
# `deadline_at` is backdated with `jq` instead (T13, T14, T17). That is not
# clock-mocking: the script still reads a real `date +%s` and compares it to a
# real stored deadline. It buys determinism — T14's two-watcher race has to
# collide, not merely be likely to.
#
# T7 is NOT here. It tests the OBSERVER AGENT's honesty — whether a model,
# handed the event log, cites only what it read. That cannot be asserted by a
# shell script, so it is a documented live-fire check in
# skills/observed-work/SKILL.md. Automating a fake version of it would be the
# same mistake as trusting a model to be the sensor.
#
# Usage: ./scripts/test-observe.sh
# Exits 0 if all tests pass, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The script under test. Overridable ONLY so the falsification runs described
# above can point the suite at a deliberately-mutated copy and watch each test
# go red. Nothing in production reads this variable.
OBSERVE="${OBSERVE_SCRIPT:-$SCRIPT_DIR/observe.sh}"

# Pin the reused guard-2 detector to the REPO copy rather than the installed
# one, so the suite tests this checkout and not whatever happens to be in
# ~/.claude/scripts.
export OBSERVE_PROGRESS_SCRIPT="$SCRIPT_DIR/loop-progress-signature.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

WORK=$(mktemp -d)
WATCH_PIDS=()
cleanup() {
  # Kill any watcher still running before the temp tree goes away, so a failed
  # assertion can never leave a background loop behind. That failure mode —
  # an orphaned watcher nobody remembers starting — is incident 2 itself.
  local p
  for p in ${WATCH_PIDS+"${WATCH_PIDS[@]}"}; do
    kill -TERM "$p" 2>/dev/null
  done
  sleep 1
  for p in ${WATCH_PIDS+"${WATCH_PIDS[@]}"}; do
    kill -KILL "$p" 2>/dev/null
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
failed() {
  FAIL=$((FAIL + 1))
  FAILED_TESTS+=("$1${2:+ — $2}")
  echo "  FAIL: $1${2:+ — $2}"
}

assert_rc() {
  local name="$1" want="$2" got="$3" detail="${4-}"
  if [[ "$got" -eq "$want" ]]; then pass "$name"; else failed "$name" "expected rc=$want got rc=$got${detail:+ · $detail}"; fi
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$name"; else failed "$name" "expected to contain '$needle'"; fi
}

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$name"; else failed "$name" "expected NOT to contain '$needle'"; fi
}

assert_true() {
  local name="$1" detail="${2-}"
  shift 2 2>/dev/null || shift $#
  if "$@"; then pass "$name"; else failed "$name" "$detail"; fi
}

# --- SUITE SELF-CHECK: every assert_* helper CALLED must actually EXIST -------
# ⛔ WITHOUT THIS, A TYPO'D HELPER NAME IS A PASSING TEST. ⛔
# This suite runs without `set -e` (deliberately — a failing assertion must not
# abort the remaining cases). The cost is that calling an undefined helper, e.g.
# `assert_eq` in a suite that defines `assert_rc`, writes "command not found" to
# stderr and CONTINUES. The assertion never executes, the total silently drops by
# one, and the run still reports "0 failed".
#
# Measured: exactly that shipped here. Two assertions were added, the total went
# 79 -> 80, and the green result was indistinguishable from success. The only
# signal was the count. A suite that exists to catch checks which merely LOOK
# like they work must not be vulnerable to the same thing.
#
# Static, not runtime: it compares names in command position against the function
# definitions in this file, so an unreached branch is covered too.
#
# ⛔ THE FIRST VERSION OF THIS BLOCK HAD BOTH FAILURE MODES AT ONCE. ⛔ Its scan
# was `grep -oE '(^|[[:space:];&|(])assert_[a-z_]+[[:space:]]'`, and:
#
#   BYPASS — the preceding-character class had no QUOTE in it, so
#     `eval 'assert_rq …'` was not matched. That call is exactly as silent a
#     no-op as a bare one, and the check said nothing about it.
#   FALSE POSITIVE — comments were scanned, so the words `assert_rq` written
#     inside a comment (including this file's own FALSIFYING EDIT notes) matched
#     and BLOCKED a suite whose code was perfectly fine. The original comment
#     here acknowledged that risk and dismissed it; that was wrong.
#
# Fixed by doing the two things in order: strip comments FIRST, then scan the
# remaining code with a boundary class that includes quotes and backticks. A
# trailing `#…` is cut at the ` #`, which can only ever truncate AFTER a call's
# name (the name is the first token), so no call is lost to the stripping.
#
# FALSIFYING EDITS, both of which must behave:
#   (a) change any `assert_rc` call below to `assert_rq`, wrap one as
#       `eval 'assert_rq …'`, or call one indirectly as
#       `helper=assert_rq; "$helper" …` — this block must exit 1 and name it.
#   (b) write `assert_rq` in a comment — after whitespace OR after a semicolon,
#       as in `:; # assert_rq` — and change no code: this block must stay quiet
#       and the suite must run.
_SELF="${BASH_SOURCE[0]}"
_ASSERT_DEFINED=$(grep -oE '^assert_[a-z_]+\(\)' "$_SELF" | sed 's/()$//' | sort -u)
# ⛔ BOTH HOLES WERE REPORTED FIXED AND NEITHER FULLY WAS. Measured, second pass:
#   BYPASS STILL OPEN — `helper=assert_rq; "$helper" …` was missed, because `=`
#     was not in the preceding-character class. An indirect call is exactly as
#     silent a no-op as a direct one.
#   FALSE POSITIVE STILL OPEN — `;# assert_rq` was still flagged, because the
#     comment strip required WHITESPACE before the `#` and a semicolon is not
#     whitespace.
# Both classes are the same mistake: a character class written from the examples
# in front of me rather than from the grammar. `=` is now a boundary, and a
# comment may open after whitespace OR a semicolon.
#
# `$#`, `${#var}` and `owner/repo#123` are deliberately NOT stripped: in each the
# `#` is preceded by `$`, `{` or an ordinary character, none of which open a
# comment in shell.
_SELF_CODE=$(sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:];]#.*$//' "$_SELF")
_ASSERT_CALLED=$(printf '%s\n' "$_SELF_CODE" \
                 | grep -oE "(^|[[:space:];&|(){}='\"\`])assert_[a-z_]+([[:space:];&|)'\"\`]|\$)" \
                 | grep -oE 'assert_[a-z_]+' | sort -u)
_ASSERT_BAD=""
for _fn in $_ASSERT_CALLED; do
  grep -qx "$_fn" <<< "$_ASSERT_DEFINED" || _ASSERT_BAD="$_ASSERT_BAD $_fn"
done
if [[ -n "$_ASSERT_BAD" ]]; then
  echo ""
  echo "  FATAL: this suite calls assertion helper(s) that are not defined:$_ASSERT_BAD"
  echo "         Each such call is a SILENT NO-OP — the assertion never runs, and"
  echo "         because this suite has no 'set -e' the run still reports 0 failed."
  echo "         Defined helpers: $(tr '\n' ' ' <<< "$_ASSERT_DEFINED")"
  exit 1
fi

# Count events of a given type in a task's log. The log is the record an
# observer agent reads, so assertions are made against IT and not only against
# stdout — a fact that reached the terminal but not the log has not been recorded.
log_events() {
  local root="$1" task="$2" event="$3"
  local f="$root/log/$task.events.jsonl"
  [[ -f "$f" ]] || { printf '0'; return; }
  jq -r --arg e "$event" 'select(.event == $e) | .event' "$f" 2>/dev/null | wc -l | tr -d ' '
}

# A scratch git repo whose HEAD is a real, advancing progress probe.
make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q 2>/dev/null
  git -C "$dir" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m "baseline" 2>/dev/null
  printf '%s' "$dir"
}

advance_repo() {
  git -C "$1" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m "advance $RANDOM" 2>/dev/null
}

echo ""
echo "=== observe.sh ==="
echo "(T1 and T4 are real-time and run concurrently — expect ~140s of wall clock)"

# ===========================================================================
# T1 + T4 — the two real-time tests, launched together.
# ===========================================================================
# T1 SILENCE: a declaration with checkin_every_s=60 and no check-in must produce
#   a SILENT event within 120s (the watcher fires it at 1.5x = 90s).
#   FALSIFYING EDIT: delete the SILENT branch in watch_one(), or change
#   SILENT_FACTOR_NUM to something above the test window — the watcher then
#   watches a silent task forever and says nothing, which is precisely the
#   "working-but-slow vs stalled" blindness this whole mechanism replaces.
#
# T4 THE LITERAL INCIDENT-2 REGRESSION: done_when is the exact broken predicate
#   `grep -q "TC-HI-3/3b" <file>` against a file that contains `TC-HI-3` and
#   `TC-HI-3b` on SEPARATE lines — so it can never match. With
#   hard_deadline_s=120 the watcher must emit a DEADLINE event carrying a
#   snapshot at ~120s and RETIRE the declaration. Eleven hours becomes two
#   minutes by construction, not by anyone remembering to look.
#   FALSIFYING EDIT: remove the `now >= deadline_at` branch from watch_one(), or
#   remove the retire() call from watch_deadline() — the first restores the
#   unbounded wait, the second turns one alert into an infinite stream, which is
#   an alert nobody reads.
# ---------------------------------------------------------------------------
#
# T11 THE TICK THAT SWALLOWED EVERY BOUND (rides along with T1/T4 for free):
#   `--tick-s 999999` was handed straight to `sleep`, so a watcher consulted no
#   bound again until it returned. Measured before the fix:
#   `watch --tick-s 999999 --max-lifetime-s 5` was still alive after 20s and
#   would have slept ~11.5 DAYS — incident 2 REPRODUCED INSIDE THE MECHANISM
#   BUILT TO PREVENT IT. Here a 30s subject deadline must still be honoured
#   under that tick, because the sleep is clamped to the nearest bound.
#   FALSIFYING EDIT: put `sleep "$tick_s"` back at the bottom of cmd_watch() in
#   place of the wake_at/bounded_sleep block — TC-OBS-11a goes red (no DEADLINE
#   ever arrives), and so do TC-OBS-11b/11c.
# ---------------------------------------------------------------------------
T1_ROOT="$WORK/t1"; mkdir -p "$T1_ROOT"
T4_ROOT="$WORK/t4"; mkdir -p "$T4_ROOT"
T11_ROOT="$WORK/t11"; mkdir -p "$T11_ROOT"
T20_ROOT="$WORK/t20"; mkdir -p "$T20_ROOT/active"
T20B_ROOT="$WORK/t20b"; mkdir -p "$T20B_ROOT"
T1_REPO=$(make_repo "$WORK/t1repo")
T4_REPO=$(make_repo "$WORK/t4repo")
T11_REPO=$(make_repo "$WORK/t11repo")
T20_REPO=$(make_repo "$WORK/t20repo")
T20B_REPO=$(make_repo "$WORK/t20brepo")

# The file that makes the broken predicate broken: both tokens present, never
# adjacent, exactly as the real run printed them.
T4_OUTFILE="$WORK/t4-run-output.txt"
printf 'TC-HI-3: passed\nTC-HI-3b: passed\n' > "$T4_OUTFILE"

OBSERVER_ROOT="$T1_ROOT" bash "$OBSERVE" declare \
  --id silence --intent "a SILENT event proving an unattended task cannot go unnoticed" \
  --done-when "test -f $WORK/t1-never" \
  --progress-probe "git -C $T1_REPO rev-parse HEAD" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 \
  --worktree "$T1_REPO" --branch main > "$WORK/t1-declare.out" 2>&1
T1_DECL_RC=$?
assert_rc "TC-OBS-1a: declare accepts the silence subject" 0 "$T1_DECL_RC" "$(cat "$WORK/t1-declare.out")"

OBSERVER_ROOT="$T4_ROOT" bash "$OBSERVE" declare \
  --id incident2 --intent "the literal eleven-hour predicate, now bounded to 120s" \
  --done-when "grep -q \"TC-HI-3/3b\" $T4_OUTFILE" \
  --progress-probe "git -C $T4_REPO rev-parse HEAD" \
  --checkin-every-s 3600 --hard-deadline-s 120 --max-rounds 5 \
  --worktree "$T4_REPO" --branch main > "$WORK/t4-declare.out" 2>&1
T4_DECL_RC=$?
assert_rc "TC-OBS-4a: declare accepts the broken predicate (it executes cleanly and is FALSE)" 0 "$T4_DECL_RC" "$(cat "$WORK/t4-declare.out")"

OBSERVER_ROOT="$T11_ROOT" bash "$OBSERVE" declare \
  --id hugetick --intent "a 30s deadline honoured under a tick that would sleep 11 days" \
  --done-when "test -f $WORK/t11-never" \
  --progress-probe "git -C $T11_REPO rev-parse HEAD" \
  --checkin-every-s 3600 --hard-deadline-s 30 --max-rounds 5 \
  --worktree "$T11_REPO" --branch main > "$WORK/t11-declare.out" 2>&1
T11_DECL_RC=$?
assert_rc "TC-OBS-11z: declare accepts the huge-tick subject" 0 "$T11_DECL_RC" "$(cat "$WORK/t11-declare.out")"

T_START=$(date +%s)
OBSERVER_ROOT="$T1_ROOT" bash "$OBSERVE" watch --tick-s 5 --idle-exit-s 30 --max-lifetime-s 240 \
  > "$WORK/t1-watch.out" 2>&1 &
WATCH_PIDS+=($!)
OBSERVER_ROOT="$T4_ROOT" bash "$OBSERVE" watch --tick-s 5 --idle-exit-s 15 --max-lifetime-s 240 \
  > "$WORK/t4-watch.out" 2>&1 &
WATCH_PIDS+=($!)
# ⛔ The tick that must NOT be obeyed as a sleep. ⛔ 999999s is ~11.5 days; the
# declared bounds it must yield to are the subject's 30s deadline and the 240s
# lifetime cap. Backgrounded deliberately: if the clamp is reverted this watcher
# never returns, and a suite that blocked forever waiting for it would be the
# eleven-hour bug a third time.
OBSERVER_ROOT="$T11_ROOT" bash "$OBSERVE" watch --tick-s 999999 --idle-exit-s 15 --max-lifetime-s 240 \
  > "$WORK/t11-watch.out" 2>&1 &
WATCH_PIDS+=($!)

# ⛔ T20 — THE TRANSITION, which every test above is structurally unable to reach. ⛔
# T8 and T11 declare everything BEFORE their watcher starts, so they only ever
# exercise the set of subjects that existed at sleep time. The defect lived
# entirely in the change: a declaration APPEARING or RETIRING mid-sleep. Measured
# on the previous fix: an EMPTY watcher on a 999999s tick produced NO DEADLINE in
# 75s for a task declared 5s in with a 30s deadline.
#
# Both watchers below start on a root whose membership then CHANGES underneath
# them, and both changes happen from a background subshell so this costs no wall
# clock beyond the T1/T4 wait already running.
#
# T20a: watcher starts EMPTY; a 30s task is declared 8s later.
OBSERVER_ROOT="$T20_ROOT" bash "$OBSERVE" watch --tick-s 999999 --idle-exit-s 999999 --max-lifetime-s 240 \
  > "$WORK/t20-watch.out" 2>&1 &
WATCH_PIDS+=($!)
(
  sleep 8
  OBSERVER_ROOT="$T20_ROOT" bash "$OBSERVE" declare \
    --id latecomer --intent "declared AFTER the watcher was already sleeping" \
    --done-when "test -f $WORK/t20-never" \
    --progress-probe "git -C $T20_REPO rev-parse HEAD" \
    --checkin-every-s 3600 --hard-deadline-s 30 --max-rounds 5 >/dev/null 2>&1
) &

# T20b: watcher starts WITH a subject; the subject is closed 8s later, and the
# idle exit must then fire on schedule instead of waiting out the lifetime cap.
OBSERVER_ROOT="$T20B_ROOT" bash "$OBSERVE" declare \
  --id leaver --intent "a subject that retires while the watcher is asleep" \
  --done-when "test -f $WORK/t20b-never" \
  --progress-probe "git -C $T20B_REPO rev-parse HEAD" \
  --checkin-every-s 3600 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
OBSERVER_ROOT="$T20B_ROOT" bash "$OBSERVE" watch --tick-s 999999 --idle-exit-s 5 --max-lifetime-s 240 \
  > "$WORK/t20b-watch.out" 2>&1 &
T20B_WATCH_PID=$!
WATCH_PIDS+=($T20B_WATCH_PID)
(
  sleep 8
  OBSERVER_ROOT="$T20B_ROOT" bash "$OBSERVE" close --id leaver --outcome abandoned >/dev/null 2>&1
) &

# The bounded wait. ⛔ NO `until <cond>; do sleep; done` WITHOUT A DEADLINE ⛔ —
# that shape is incident 2 verbatim, and writing it inside the test for the fix
# would be its own punchline. `timeout` does not exist here, so the bound is
# date arithmetic, checked every iteration.
T1_SEEN_AT=0
T4_SEEN_AT=0
# T11 rides along: its 30s deadline always lands before T4's 120s one, so the
# break condition deliberately does NOT wait on it — it costs zero extra clock.
T11_SEEN_AT=0
WAIT_LIMIT_S=200
WAIT_DEADLINE=$(( T_START + WAIT_LIMIT_S ))
while :; do
  NOW=$(date +%s)
  if (( T1_SEEN_AT == 0 )) && grep -q ' SILENT silence ' "$WORK/t1-watch.out" 2>/dev/null; then
    T1_SEEN_AT=$NOW
  fi
  if (( T4_SEEN_AT == 0 )) && grep -q ' DEADLINE incident2 ' "$WORK/t4-watch.out" 2>/dev/null; then
    T4_SEEN_AT=$NOW
  fi
  if (( T11_SEEN_AT == 0 )) && grep -q ' DEADLINE hugetick ' "$WORK/t11-watch.out" 2>/dev/null; then
    T11_SEEN_AT=$NOW
  fi
  (( T1_SEEN_AT > 0 && T4_SEEN_AT > 0 )) && break
  (( NOW >= WAIT_DEADLINE )) && break
  sleep 2
done

# The DEADLINE event is emitted, and the retirement follows it. Capturing the
# output the instant DEADLINE appears therefore races the RETIRED line that
# comes after it. Give it a bounded settle window — bounded, because an
# unbounded wait inside the test for the unbounded-wait bug would be absurd.
SETTLE_DEADLINE=$(( $(date +%s) + 30 ))
while :; do
  grep -q ' RETIRED incident2 ' "$WORK/t4-watch.out" 2>/dev/null && break
  (( $(date +%s) >= SETTLE_DEADLINE )) && break
  sleep 1
done

T1_WATCH_OUT=$(cat "$WORK/t1-watch.out" 2>/dev/null)
T4_WATCH_OUT=$(cat "$WORK/t4-watch.out" 2>/dev/null)

# --- T1 assertions ---------------------------------------------------------
assert_contains "TC-OBS-1b: SILENT event reached the notification stream" " SILENT silence " "$T1_WATCH_OUT"
if (( T1_SEEN_AT > 0 )); then
  T1_ELAPSED=$(( T1_SEEN_AT - T_START ))
  if (( T1_ELAPSED <= 125 )); then
    pass "TC-OBS-1c: SILENT arrived in ${T1_ELAPSED}s (within the 120s budget)"
  else
    failed "TC-OBS-1c: SILENT arrived in ${T1_ELAPSED}s" "must be within ~120s of a 60s check-in interval"
  fi
else
  failed "TC-OBS-1c: SILENT never arrived" "waited ${WAIT_LIMIT_S}s"
fi
assert_true "TC-OBS-1d: SILENT was recorded in the event log, not just printed" \
  "log had $(log_events "$T1_ROOT" silence SILENT) SILENT events" \
  test "$(log_events "$T1_ROOT" silence SILENT)" -ge 1
# One silence must produce ONE alert, not a stream — an alert per tick is an
# alert that gets muted, and then nothing is being observed at all.
assert_true "TC-OBS-1e: SILENT fired ONCE, not once per tick" \
  "log had $(log_events "$T1_ROOT" silence SILENT) SILENT events" \
  test "$(log_events "$T1_ROOT" silence SILENT)" -eq 1
assert_contains "TC-OBS-1f: CHECKIN_DUE fired before SILENT" " CHECKIN_DUE silence " "$T1_WATCH_OUT"

# Stand the T1 watcher down the way a real caller would — by closing its
# subject — rather than by killing it. Closing the last subject must make the
# watcher notice and exit on its own; the cleanup trap's kill is only a
# last-resort backstop, and a suite that always needs it is not demonstrating
# the self-exit it claims.
OBSERVER_ROOT="$T1_ROOT" bash "$OBSERVE" close --id silence --outcome abandoned >/dev/null 2>&1
T1_EXIT_DEADLINE=$(( $(date +%s) + 90 ))
while :; do
  grep -q 'WATCH_EXIT' "$WORK/t1-watch.out" 2>/dev/null && break
  (( $(date +%s) >= T1_EXIT_DEADLINE )) && break
  sleep 2
done
assert_contains "TC-OBS-1g: closing the last subject stands the watcher down" \
  "WATCH_EXIT - reason=idle" "$(cat "$WORK/t1-watch.out" 2>/dev/null)"

# --- T4 assertions ---------------------------------------------------------
assert_contains "TC-OBS-4b: DEADLINE event reached the notification stream" " DEADLINE incident2 " "$T4_WATCH_OUT"
if (( T4_SEEN_AT > 0 )); then
  T4_ELAPSED=$(( T4_SEEN_AT - T_START ))
  # Floor as well as ceiling: a DEADLINE that fires EARLY would mean the bound
  # is not being read from the declaration, and the test would pass for the
  # wrong reason.
  if (( T4_ELAPSED >= 110 && T4_ELAPSED <= 175 )); then
    pass "TC-OBS-4c: DEADLINE arrived in ${T4_ELAPSED}s (declared bound was 120s)"
  else
    failed "TC-OBS-4c: DEADLINE arrived in ${T4_ELAPSED}s" "expected ~120s (110-175s window)"
  fi
else
  failed "TC-OBS-4c: DEADLINE never arrived" "waited ${WAIT_LIMIT_S}s — this is the eleven-hour bug"
fi
assert_contains "TC-OBS-4d: the DEADLINE carries a git snapshot the WATCHER gathered" "  git: " "$T4_WATCH_OUT"
assert_contains "TC-OBS-4e: the DEADLINE carries the re-run progress probe" "  probe(rc=0): " "$T4_WATCH_OUT"
assert_contains "TC-OBS-4f: the DEADLINE states done_when was still FALSE" "done_when(rc=1): FALSE" "$T4_WATCH_OUT"
assert_contains "TC-OBS-4g: the declaration was RETIRED so the alert cannot repeat" " RETIRED incident2 " "$T4_WATCH_OUT"
assert_true "TC-OBS-4h: retired declaration left active/" "still in active/" \
  test ! -f "$T4_ROOT/active/incident2.json"
assert_true "TC-OBS-4i: retired declaration landed in retired/" "not in retired/" \
  test -f "$T4_ROOT/retired/incident2.json"
assert_true "TC-OBS-4j: exactly one DEADLINE event, not a stream" \
  "log had $(log_events "$T4_ROOT" incident2 DEADLINE) DEADLINE events" \
  test "$(log_events "$T4_ROOT" incident2 DEADLINE)" -eq 1

# The T4 watcher should now self-exit on idle, having nothing left to watch.
# ⛔ Bounded wait again. ⛔
IDLE_DEADLINE=$(( $(date +%s) + 60 ))
while :; do
  grep -q 'WATCH_EXIT - reason=idle' "$WORK/t4-watch.out" 2>/dev/null && break
  (( $(date +%s) >= IDLE_DEADLINE )) && break
  sleep 2
done
assert_contains "TC-OBS-4k: with nothing left to watch, the watcher self-exited" \
  "WATCH_EXIT - reason=idle" "$(cat "$WORK/t4-watch.out" 2>/dev/null)"

# --- T11 assertions: the tick must not swallow the subject's deadline --------
T11_WATCH_OUT=$(cat "$WORK/t11-watch.out" 2>/dev/null)
assert_contains "TC-OBS-11a: a 30s deadline still fires under --tick-s 999999" \
  " DEADLINE hugetick " "$T11_WATCH_OUT"
if (( T11_SEEN_AT > 0 )); then
  T11_ELAPSED=$(( T11_SEEN_AT - T_START ))
  # Ceiling is deadline + one sleep slice + poll slack. A 999999s tick that was
  # actually obeyed would put this in the tens of thousands of minutes.
  if (( T11_ELAPSED <= 60 )); then
    pass "TC-OBS-11b: DEADLINE arrived in ${T11_ELAPSED}s despite a ~11.5-day tick"
  else
    failed "TC-OBS-11b: DEADLINE arrived in ${T11_ELAPSED}s" "declared bound was 30s — the tick is being slept, not clamped"
  fi
else
  failed "TC-OBS-11b: DEADLINE never arrived under a huge tick" "the tick swallowed the deadline — this is incident 2 inside the sensor"
fi
assert_true "TC-OBS-11c: the huge-tick subject was retired on its deadline" \
  "still in active/" test ! -f "$T11_ROOT/active/hugetick.json"

# --- T20 assertions: the transition cases ----------------------------------
# By now the T1/T4 wait has run well past 120s, so a 30s deadline declared at
# t+8s is long overdue and a 5s idle exit armed at t+8s has long since fired.
T20_WATCH_OUT=$(cat "$WORK/t20-watch.out" 2>/dev/null)
assert_contains "TC-OBS-20a: a task DECLARED mid-sleep is still seen, and its deadline fires" \
  " DEADLINE latecomer " "$T20_WATCH_OUT"
assert_true "TC-OBS-20b: and it was retired, so the watcher acted on it rather than merely printing" \
  "still in active/" test ! -f "$T20_ROOT/active/latecomer.json"

# The idle half. Asserting the PROCESS is gone, not just that a line was printed:
# the failure mode is a watcher that keeps living, and a log line cannot show that.
if kill -0 "$T20B_WATCH_PID" 2>/dev/null; then
  failed "TC-OBS-20c: watcher still alive after its subject retired mid-sleep" \
    "--idle-exit-s was 5 and the subject closed at t+8s; it is waiting out its 240s lifetime instead"
else
  pass "TC-OBS-20c: a subject RETIRING mid-sleep lets the idle exit fire on schedule"
fi
assert_contains "TC-OBS-20d: and the exit names the idle reason, not the lifetime cap" \
  "WATCH_EXIT - reason=idle" "$(cat "$WORK/t20b-watch.out" 2>/dev/null)"

# ===========================================================================
# T2 — a FABRICATED "working" claim. This is incident 1 in one command.
# FALSIFYING EDIT: delete the `claim == working && delta == 0` branch in
# cmd_checkin(), or make a failed probe score delta=1 — either way a claim of
# progress with no progress behind it sails through, which is the entire failure
# this mechanism exists to make impossible.
# ===========================================================================
echo ""
T2_ROOT="$WORK/t2"; mkdir -p "$T2_ROOT"
T2_REPO=$(make_repo "$WORK/t2repo")
OBSERVER_ROOT="$T2_ROOT" bash "$OBSERVE" declare \
  --id fabricate --intent "a MISMATCH proving a claim of progress needs progress behind it" \
  --done-when "test -f $WORK/t2-never" \
  --progress-probe "git -C $T2_REPO rev-parse HEAD" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
T2_OUT=$(OBSERVER_ROOT="$T2_ROOT" bash "$OBSERVE" checkin --id fabricate --claim working \
  --note "made great progress on the refactor" 2>&1)
T2_RC=$?
assert_rc "TC-OBS-2a: a fabricated 'working' claim exits 3 (anomaly)" 3 "$T2_RC" "$T2_OUT"
assert_contains "TC-OBS-2b: the SCRIPT emitted MISMATCH — no model involved" " MISMATCH fabricate " "$T2_OUT"
assert_contains "TC-OBS-2c: the reason names the measurement, not an opinion" "reason=working-no-delta" "$T2_OUT"
assert_contains "TC-OBS-2d: the claim is on the record verbatim" " CLAIM fabricate " "$T2_OUT"
assert_contains "TC-OBS-2e: the facts are recorded separately from the claim" " FACTS fabricate " "$T2_OUT"
assert_contains "TC-OBS-2f: the measured delta is zero" "delta=0" "$T2_OUT"
assert_true "TC-OBS-2g: MISMATCH is in the append-only log" \
  "log had $(log_events "$T2_ROOT" fabricate MISMATCH)" \
  test "$(log_events "$T2_ROOT" fabricate MISMATCH)" -ge 1

# The mirror image: a REAL commit makes the same claim clean. Without this, T2
# would also pass if the script emitted MISMATCH unconditionally.
advance_repo "$T2_REPO"
T2B_OUT=$(OBSERVER_ROOT="$T2_ROOT" bash "$OBSERVE" checkin --id fabricate --claim working \
  --note "one real commit landed" 2>&1)
T2B_RC=$?
assert_contains "TC-OBS-2h: a REAL delta is measured as delta=1" "delta=1" "$T2B_OUT"
assert_not_contains "TC-OBS-2i: a truthful 'working' claim produces NO MISMATCH" \
  "reason=working-no-delta" "$T2B_OUT"
assert_rc "TC-OBS-2j: a truthful 'working' claim exits 0" 0 "$T2B_RC" "$T2B_OUT"

# ===========================================================================
# T3 — a FALSE "good" claim, and the close that must refuse it.
# FALSIFYING EDIT: delete the `claim == good && done_when false` branch, or drop
# the re-verification from cmd_close() and trust the outcome argument — a
# success claim would then enter the permanent record unmeasured, which is the
# one thing an observer must never allow.
# ===========================================================================
echo ""
T3_ROOT="$WORK/t3"; mkdir -p "$T3_ROOT"
T3_REPO=$(make_repo "$WORK/t3repo")
OBSERVER_ROOT="$T3_ROOT" bash "$OBSERVE" declare \
  --id falsegood --intent "a refused close proving 'shipped' is measured, not asserted" \
  --done-when "test -f $WORK/t3-done-marker" \
  --progress-probe "git -C $T3_REPO rev-parse HEAD" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
T3_OUT=$(OBSERVER_ROOT="$T3_ROOT" bash "$OBSERVE" checkin --id falsegood --claim good \
  --note "shipped it" 2>&1)
T3_RC=$?
assert_rc "TC-OBS-3a: a false 'good' claim exits 3 (anomaly)" 3 "$T3_RC" "$T3_OUT"
assert_contains "TC-OBS-3b: MISMATCH on a 'good' claim with done_when false" " MISMATCH falsegood " "$T3_OUT"
assert_contains "TC-OBS-3c: the reason names the failed predicate" "reason=good-not-done" "$T3_OUT"

T3C_OUT=$(OBSERVER_ROOT="$T3_ROOT" bash "$OBSERVE" close --id falsegood --outcome shipped 2>&1)
T3C_RC=$?
assert_rc "TC-OBS-3d: close --outcome shipped is REFUSED (rc=1)" 1 "$T3C_RC" "$T3C_OUT"
assert_contains "TC-OBS-3e: the refusal is recorded, not just printed" " CLOSE_REFUSED falsegood " "$T3C_OUT"
assert_true "TC-OBS-3f: a refused close leaves the declaration ACTIVE" "declaration was retired anyway" \
  test -f "$T3_ROOT/active/falsegood.json"

# `abandoned` is always allowed — the mechanism refuses false SUCCESS, it never
# traps work in an observation you cannot get out of.
T3D_OUT=$(OBSERVER_ROOT="$T3_ROOT" bash "$OBSERVE" close --id falsegood --outcome abandoned 2>&1)
T3D_RC=$?
assert_rc "TC-OBS-3g: close --outcome abandoned is always allowed" 0 "$T3D_RC" "$T3D_OUT"
assert_true "TC-OBS-3h: an abandoned close retires the declaration" "still active" \
  test ! -f "$T3_ROOT/active/falsegood.json"

# And once done_when is genuinely TRUE, `shipped` goes through — otherwise the
# refusal would just be a permanent block dressed as a check.
T3_ROOT2="$WORK/t3b"; mkdir -p "$T3_ROOT2"
T3_REPO2=$(make_repo "$WORK/t3repo2")
OBSERVER_ROOT="$T3_ROOT2" bash "$OBSERVE" declare \
  --id realship --intent "a permitted close proving the gate is a measurement, not a wall" \
  --done-when "test -f $WORK/t3b-done-marker" \
  --progress-probe "git -C $T3_REPO2 rev-parse HEAD" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
: > "$WORK/t3b-done-marker"
T3E_OUT=$(OBSERVER_ROOT="$T3_ROOT2" bash "$OBSERVE" close --id realship --outcome shipped 2>&1)
T3E_RC=$?
assert_rc "TC-OBS-3i: close --outcome shipped succeeds once done_when is TRUE" 0 "$T3E_RC" "$T3E_OUT"
assert_contains "TC-OBS-3j: the successful close records the verified rc" "done_when_rc=0" "$T3E_OUT"

# ===========================================================================
# T5 — DECLARE VALIDATION. The cheap, DECIDABLE subset only: a predicate that
# cannot execute, one that is already true, one that cannot answer in time.
# ⛔ Do NOT read this as "the gate that prevents incident 2" — it is not. That
# predicate is runnable and exits 1, so declare accepts it (TC-OBS-5m pins the
# acceptance deliberately); the hard deadline in T4 is what bounds it.
# FALSIFYING EDIT: remove the `dw_rc == 0` case or the `pp_rc != 0` check from
# cmd_declare() — a vacuous predicate or a probe that cannot run would then be
# accepted, and every observation built on it would be theatre.
# ===========================================================================
echo ""
T5_ROOT="$WORK/t5"; mkdir -p "$T5_ROOT"
T5_REPO=$(make_repo "$WORK/t5repo")

# --- TC-OBS-5m: a RUNNABLE but never-true predicate must be ACCEPTED ---------
# This asserts the ABSENCE of a check, which is unusual, so the reason is spelled
# out: the literal incident-2 predicate exits 1, exactly like every honest
# not-yet-finished predicate. A future "improvement" that rejected it would have
# to guess, and guessing wrong rejects real work. The correct guard is the hard
# deadline (T4). If this assertion ever goes red, someone added a heuristic here
# and the fix is to remove it, not to relax this test.
# FALSIFYING EDIT: add `1) die "predicate looks unsatisfiable" ;;` to the
# cmd_declare() case — this assertion goes red immediately.
T5G_OUT_FILE="$T5_ROOT/incident2-literal.txt"
printf 'TC-HI-3 passed\nTC-HI-3b passed\n' > "$T5G_OUT_FILE"
T5G_OUT=$(OBSERVER_ROOT="$T5_ROOT/obs5g" bash "$OBSERVE" declare \
  --id t5g --intent "the literal incident-2 predicate must be accepted, not guessed at" \
  --done-when "grep -q 'TC-HI-3/3b' $T5G_OUT_FILE" \
  --progress-probe "wc -l < $T5G_OUT_FILE" \
  --checkin-every-s 60 --hard-deadline-s 60 --max-rounds 2 2>&1) && T5G_RC=0 || T5G_RC=$?
assert_rc "TC-OBS-5m: a runnable never-true predicate is ACCEPTED (the deadline bounds it, not a guess)" 0 "$T5G_RC"
assert_contains "TC-OBS-5n: and it was validated as currently false, not assumed" "done_when_rc=1" "$T5G_OUT"

T5A_OUT=$(OBSERVER_ROOT="$T5_ROOT" bash "$OBSERVE" declare \
  --id alreadytrue --intent "x" --done-when "true" \
  --progress-probe "git -C $T5_REPO rev-parse HEAD" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 2>&1)
T5A_RC=$?
assert_rc "TC-OBS-5a: done_when already TRUE is REJECTED" 2 "$T5A_RC" "$T5A_OUT"
assert_contains "TC-OBS-5b: the rejection says why (done or vacuous)" "ALREADY TRUE" "$T5A_OUT"
assert_true "TC-OBS-5c: a rejected declare writes NO declaration" "declaration was written anyway" \
  test ! -f "$T5_ROOT/active/alreadytrue.json"

T5B_OUT=$(OBSERVER_ROOT="$T5_ROOT" bash "$OBSERVE" declare \
  --id probe127 --intent "x" --done-when "false" \
  --progress-probe "observe_test_no_such_command_127" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 2>&1)
T5B_RC=$?
assert_rc "TC-OBS-5d: a progress_probe exiting 127 is REJECTED" 2 "$T5B_RC" "$T5B_OUT"
assert_contains "TC-OBS-5e: the rejection reports the exit code it measured" "(got 127)" "$T5B_OUT"

T5C_OUT=$(OBSERVER_ROOT="$T5_ROOT" bash "$OBSERVE" declare \
  --id dw127 --intent "x" --done-when "observe_test_no_such_command_127" \
  --progress-probe "git -C $T5_REPO rev-parse HEAD" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 2>&1)
T5C_RC=$?
assert_rc "TC-OBS-5f: a done_when that cannot EXECUTE is REJECTED" 2 "$T5C_RC" "$T5C_OUT"
assert_contains "TC-OBS-5g: the rejection distinguishes 'cannot run' from 'false'" "could not execute" "$T5C_OUT"

T5D_OUT=$(OBSERVER_ROOT="$T5_ROOT" bash "$OBSERVE" declare \
  --id emptyprobe --intent "x" --done-when "false" --progress-probe "true" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 2>&1)
T5D_RC=$?
assert_rc "TC-OBS-5h: a progress_probe with NO output is REJECTED" 2 "$T5D_RC" "$T5D_OUT"
assert_contains "TC-OBS-5i: the rejection explains the silent-forever failure" "no output" "$T5D_OUT"

# The Rule 9 bounds are declare-time REJECTIONS, not clamps — a typo in the
# bound must not silently become a different bound.
T5E_OUT=$(OBSERVER_ROOT="$T5_ROOT" bash "$OBSERVE" declare \
  --id nodeadline --intent "x" --done-when "false" \
  --progress-probe "git -C $T5_REPO rev-parse HEAD" \
  --checkin-every-s 60 --hard-deadline-s 999999 --max-rounds 5 2>&1)
T5E_RC=$?
assert_rc "TC-OBS-5j: a hard_deadline_s above the Rule 9 ceiling is REJECTED" 2 "$T5E_RC" "$T5E_OUT"
assert_contains "TC-OBS-5k: the rejection cites the ceiling" "Rule 9 ceiling" "$T5E_OUT"

T5F_OUT=$(OBSERVER_ROOT="$T5_ROOT" bash "$OBSERVE" declare \
  --id nobound --intent "x" --done-when "false" \
  --progress-probe "git -C $T5_REPO rev-parse HEAD" \
  --checkin-every-s 60 --max-rounds 5 2>&1)
T5F_RC=$?
assert_rc "TC-OBS-5l: a declaration with NO hard deadline is REJECTED" 2 "$T5F_RC" "$T5F_OUT"

# ===========================================================================
# T6 — CHURN. max_rounds=3, three DELTA-POSITIVE check-ins with done_when false.
# Delta-positive matters: the work IS moving, so nothing about activity is
# wrong — it is the number of attempts against an unmet predicate that is the
# problem, and that is a plan problem, not a liveness problem.
# FALSIFYING EDIT: never increment `rounds` in cmd_checkin(), or compare with
# `>` instead of `>=` — CHURN would then arrive one round late or never, and a
# non-converging approach would run until its deadline every time.
# ===========================================================================
echo ""
T6_ROOT="$WORK/t6"; mkdir -p "$T6_ROOT"
T6_REPO=$(make_repo "$WORK/t6repo")
OBSERVER_ROOT="$T6_ROOT" bash "$OBSERVE" declare \
  --id churner --intent "a CHURN event proving activity is not convergence" \
  --done-when "test -f $WORK/t6-never" \
  --progress-probe "git -C $T6_REPO rev-parse HEAD" \
  --checkin-every-s 60 --hard-deadline-s 21600 --max-rounds 3 >/dev/null 2>&1
# ⛔ 21600s (the Rule 9 ceiling), NOT 600s, AND THE REASON IS A REAL FAILURE. ⛔
# `churner` is the one fixture reused across sections — the PROBE and STATUS
# blocks below both touch it. Now that `probe` enforces the deadline, a fixture
# that expires mid-suite is correctly retired, and the later assertions then fail
# for a reason that has nothing to do with what they test. Measured: one stalled
# run pushed the suite past 600s and took TC-OBS-9a, 10b and 10c down with it.
# A fixture's deadline must outlive any plausible suite runtime, or the suite is
# measuring its own speed.

T6_ROUND_OUT=()
for round in 1 2 3; do
  advance_repo "$T6_REPO"
  T6_ROUND_OUT[$round]=$(OBSERVER_ROOT="$T6_ROOT" bash "$OBSERVE" checkin --id churner \
    --claim working --note "attempt $round" 2>&1)
done

assert_contains "TC-OBS-6a: round 1 measured a real delta" "delta=1" "${T6_ROUND_OUT[1]}"
assert_not_contains "TC-OBS-6b: no CHURN at round 1 of 3" " CHURN churner " "${T6_ROUND_OUT[1]}"
assert_not_contains "TC-OBS-6c: no CHURN at round 2 of 3" " CHURN churner " "${T6_ROUND_OUT[2]}"
assert_contains "TC-OBS-6d: CHURN fires on round 3 of 3" " CHURN churner " "${T6_ROUND_OUT[3]}"
assert_contains "TC-OBS-6e: CHURN reports the round count it counted" "rounds=3 max_rounds=3" "${T6_ROUND_OUT[3]}"
assert_true "TC-OBS-6f: CHURN is in the append-only log" \
  "log had $(log_events "$T6_ROOT" churner CHURN)" \
  test "$(log_events "$T6_ROOT" churner CHURN)" -ge 1
# Guard 2 must stay SILENT here, and that is a deliberate assertion rather than
# an absence nobody checked. This done_when is `test -f` — it prints nothing —
# so its failure signature is identical on every round by construction and the
# detector would fire NO_PROGRESS on round 2 of every observation ever made.
# TC-OBS-2j caught exactly that before the silent-predicate skip existed.
# FALSIFYING EDIT: drop the `-n "${dw_out//[[:space:]]/}"` condition from the
# guard-2 block in cmd_checkin() — this goes red immediately, and so does
# TC-OBS-2j.
assert_true "TC-OBS-6g: a SILENT done_when does not manufacture NO_PROGRESS" \
  "log had $(log_events "$T6_ROOT" churner NO_PROGRESS) NO_PROGRESS events" \
  test "$(log_events "$T6_ROOT" churner NO_PROGRESS)" -eq 0

# ...and the converse: a done_when that DOES print its failure gets the full
# guard-2 check, and a repeating error trips it. Without this pair, the skip
# above could be implemented as "never run guard 2" and both tests would pass.
T6J_ROOT="$WORK/t6j"; mkdir -p "$T6J_ROOT"
T6J_REPO=$(make_repo "$WORK/t6jrepo")
OBSERVER_ROOT="$T6J_ROOT" bash "$OBSERVE" declare \
  --id speaking --intent "guard 2 on a predicate that reports its own failure" \
  --done-when "printf 'Foo.cs(1,1): error CS0246: type not found\n'; exit 1" \
  --progress-probe "git -C $T6J_REPO rev-parse HEAD" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 10 >/dev/null 2>&1
advance_repo "$T6J_REPO"
T6J1=$(OBSERVER_ROOT="$T6J_ROOT" bash "$OBSERVE" checkin --id speaking --claim working --note "r1" 2>&1)
advance_repo "$T6J_REPO"
T6J2=$(OBSERVER_ROOT="$T6J_ROOT" bash "$OBSERVE" checkin --id speaking --claim working --note "r2" 2>&1)
assert_not_contains "TC-OBS-6j: no NO_PROGRESS on the first sighting of a failure" \
  " NO_PROGRESS speaking " "$T6J1"
assert_contains "TC-OBS-6k: NO_PROGRESS when the SAME error repeats, despite a real delta" \
  " NO_PROGRESS speaking " "$T6J2"
assert_contains "TC-OBS-6l: the repeat was measured on real movement (delta=1)" "delta=1" "$T6J2"

# Guard 2 is documented as OPTIONAL: absent script → skipped SILENTLY. A missing
# optional dependency must degrade one check, never fail the check-in.
T6H_OUT=$(OBSERVER_ROOT="$T6_ROOT" OBSERVE_PROGRESS_SCRIPT="$WORK/does-not-exist.sh" \
  bash "$OBSERVE" checkin --id churner --claim stuck --note "guard 2 absent" 2>&1)
assert_contains "TC-OBS-6h: check-in still records FACTS with guard 2 absent" " FACTS churner " "$T6H_OUT"
assert_not_contains "TC-OBS-6i: a missing guard 2 script produces no error text" "No such file" "$T6H_OUT"

# ===========================================================================
# T8 — WATCHER BOUND. An empty active/ must make the watcher self-exit inside
# its idle window. A watcher that outlives its subjects is the eleven-hour bug
# wearing a different hat.
# FALSIFYING EDIT: remove the idle-exit branch from cmd_watch(), or reset
# `idle_since` unconditionally each tick — the watcher then runs to its
# lifetime cap with nothing to watch.
# ===========================================================================
echo ""
T8_ROOT="$WORK/t8"; mkdir -p "$T8_ROOT/active"
T8_START=$(date +%s)
T8_OUT=$(OBSERVER_ROOT="$T8_ROOT" bash "$OBSERVE" watch \
  --tick-s 1 --idle-exit-s 5 --max-lifetime-s 120 2>&1)
T8_RC=$?
T8_ELAPSED=$(( $(date +%s) - T8_START ))
assert_rc "TC-OBS-8a: the watcher exits cleanly when idle" 0 "$T8_RC" "$T8_OUT"
assert_contains "TC-OBS-8b: the exit names its reason" "WATCH_EXIT - reason=idle" "$T8_OUT"
if (( T8_ELAPSED <= 20 )); then
  pass "TC-OBS-8c: self-exited in ${T8_ELAPSED}s (idle window was 5s, cap was 120s)"
else
  failed "TC-OBS-8c: took ${T8_ELAPSED}s to self-exit" "idle window was 5s"
fi

# The lifetime cap is the second, independent bound — it must hold even while
# there IS something to watch, which is the case the idle exit cannot cover.
T8_ROOT2="$WORK/t8b"; mkdir -p "$T8_ROOT2"
T8_REPO2=$(make_repo "$WORK/t8repo")
OBSERVER_ROOT="$T8_ROOT2" bash "$OBSERVE" declare \
  --id longlived --intent "a lifetime cap proving a busy watcher is bounded too" \
  --done-when "test -f $WORK/t8-never" \
  --progress-probe "git -C $T8_REPO2 rev-parse HEAD" \
  --checkin-every-s 3600 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
T8D_START=$(date +%s)
T8D_OUT=$(OBSERVER_ROOT="$T8_ROOT2" bash "$OBSERVE" watch \
  --tick-s 1 --idle-exit-s 600 --max-lifetime-s 5 2>&1)
T8D_RC=$?
T8D_ELAPSED=$(( $(date +%s) - T8D_START ))
assert_rc "TC-OBS-8d: the watcher exits cleanly at its lifetime cap" 0 "$T8D_RC" "$T8D_OUT"
assert_contains "TC-OBS-8e: the exit names the lifetime cap" "reason=max-lifetime" "$T8D_OUT"
if (( T8D_ELAPSED <= 20 )); then
  pass "TC-OBS-8f: lifetime cap honoured in ${T8D_ELAPSED}s with an ACTIVE subject"
else
  failed "TC-OBS-8f: took ${T8D_ELAPSED}s to hit a 5s lifetime cap"
fi

# --- The WATCHER'S OWN caps under a tick longer than either of them -----------
# This is the exact command that was measured sleeping ~11.5 days:
#   watch --tick-s 999999 --max-lifetime-s 5
# Both watchers below are backgrounded with a bounded wait, because a reverted
# clamp makes them never return and a foreground call would hang the suite.
T8G_ROOT="$WORK/t8g"; mkdir -p "$T8G_ROOT"
T8G_REPO=$(make_repo "$WORK/t8grepo")
OBSERVER_ROOT="$T8G_ROOT" bash "$OBSERVE" declare \
  --id capped --intent "the watcher's own lifetime cap under an 11-day tick" \
  --done-when "test -f $WORK/t8g-never" \
  --progress-probe "git -C $T8G_REPO rev-parse HEAD" \
  --checkin-every-s 3600 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
T8G_START=$(date +%s)
OBSERVER_ROOT="$T8G_ROOT" bash "$OBSERVE" watch \
  --tick-s 999999 --idle-exit-s 600 --max-lifetime-s 5 > "$WORK/t8g-watch.out" 2>&1 &
T8G_PID=$!
WATCH_PIDS+=($T8G_PID)
T8G_WAIT=$(( T8G_START + 40 ))
while :; do
  kill -0 "$T8G_PID" 2>/dev/null || break
  (( $(date +%s) >= T8G_WAIT )) && break
  sleep 1
done
T8G_ELAPSED=$(( $(date +%s) - T8G_START ))
if kill -0 "$T8G_PID" 2>/dev/null; then
  failed "TC-OBS-8g: watcher still alive after ${T8G_ELAPSED}s" "--max-lifetime-s was 5 — the tick is being slept instead of clamped"
else
  pass "TC-OBS-8g: the 5s lifetime cap held in ${T8G_ELAPSED}s under a ~11.5-day tick"
fi
assert_contains "TC-OBS-8h: and the exit still names the lifetime cap" \
  "reason=max-lifetime" "$(cat "$WORK/t8g-watch.out" 2>/dev/null)"

# The idle exit is the third watcher bound, and a huge tick must not swallow it
# either — an idle watcher nobody remembers starting is the orphan case the
# cleanup trap at the top of this file exists for.
T8I_ROOT="$WORK/t8i"; mkdir -p "$T8I_ROOT/active"
T8I_START=$(date +%s)
OBSERVER_ROOT="$T8I_ROOT" bash "$OBSERVE" watch \
  --tick-s 999999 --idle-exit-s 5 --max-lifetime-s 600 > "$WORK/t8i-watch.out" 2>&1 &
T8I_PID=$!
WATCH_PIDS+=($T8I_PID)
T8I_WAIT=$(( T8I_START + 40 ))
while :; do
  kill -0 "$T8I_PID" 2>/dev/null || break
  (( $(date +%s) >= T8I_WAIT )) && break
  sleep 1
done
T8I_ELAPSED=$(( $(date +%s) - T8I_START ))
if kill -0 "$T8I_PID" 2>/dev/null; then
  failed "TC-OBS-8i: idle watcher still alive after ${T8I_ELAPSED}s" "--idle-exit-s was 5 under a huge tick"
else
  pass "TC-OBS-8i: the 5s idle exit held in ${T8I_ELAPSED}s under a ~11.5-day tick"
fi
assert_contains "TC-OBS-8j: and the exit still names the idle reason" \
  "WATCH_EXIT - reason=idle" "$(cat "$WORK/t8i-watch.out" 2>/dev/null)"


# ===========================================================================
# T12 — THE ID IS VALIDATED IN EVERY SUBCOMMAND, not just declare.
# Measured before the fix: `checkin --id ../active/safe` updated the GENUINE
# active/safe.json — refreshing its silence timer so the watcher stayed quiet —
# while writing its events to active/safe.events.jsonl, leaving the canonical
# log/safe.events.jsonl with nothing but the original DECLARED line. A hidden
# check-in is worse than a missing one: it actively disarms the silence detector.
# FALSIFYING EDIT: delete the `require_task_id` call from cmd_checkin() (or from
# probe/close) — TC-OBS-12b/12c/12d go red, and 12e/12f show the real damage.
# ===========================================================================
echo ""
T12_ROOT="$WORK/t12"; mkdir -p "$T12_ROOT"
OBSERVER_ROOT="$T12_ROOT" bash "$OBSERVE" declare \
  --id safe --intent "the genuine declaration a crafted id would hide from" \
  --done-when "test -f $WORK/t12-never" --progress-probe "printf 'stable\n'" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
T12_CHKIN_BEFORE=$(jq -r '.last_checkin_at' "$T12_ROOT/active/safe.json" 2>/dev/null)
T12_LOGLINES_BEFORE=$(wc -l < "$T12_ROOT/log/safe.events.jsonl" 2>/dev/null | tr -d ' ')

T12A_OUT=$(OBSERVER_ROOT="$T12_ROOT" bash "$OBSERVE" declare --id "../evil" --intent x \
  --done-when "false" --progress-probe "printf 'x\n'" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 2>&1)
T12A_RC=$?
# 12a covers the guard declare ALREADY had — regression coverage, not a falsifier
# for this fix. Reverting the new require_task_id calls leaves it green (measured);
# it goes red only if declare's own check is removed. 12b-12g are the falsifiers.
assert_rc "TC-OBS-12a: declare rejects a traversal id (the guard that already existed)" 2 "$T12A_RC" "$T12A_OUT"

T12B_OUT=$(OBSERVER_ROOT="$T12_ROOT" bash "$OBSERVE" checkin --id "../active/safe" --claim working 2>&1)
T12B_RC=$?
assert_rc "TC-OBS-12b: checkin rejects a traversal id" 2 "$T12B_RC" "$T12B_OUT"
assert_contains "TC-OBS-12c: and says what a valid id looks like" "must be 1-64 chars" "$T12B_OUT"

T12D_OUT=$(OBSERVER_ROOT="$T12_ROOT" bash "$OBSERVE" probe --id "../active/safe" --cmd "true" 2>&1)
T12D_RC=$?
assert_rc "TC-OBS-12d: probe rejects a traversal id" 2 "$T12D_RC" "$T12D_OUT"

T12E_OUT=$(OBSERVER_ROOT="$T12_ROOT" bash "$OBSERVE" close --id "../active/safe" --outcome abandoned 2>&1)
T12E_RC=$?
assert_rc "TC-OBS-12e: close rejects a traversal id" 2 "$T12E_RC" "$T12E_OUT"

# The damage the traversal did, asserted directly rather than inferred from the
# rejection: the real task's silence timer must be untouched, and its canonical
# log must have gained nothing.
assert_true "TC-OBS-12f: the genuine task's silence timer was NOT refreshed" \
  "last_checkin_at moved from $T12_CHKIN_BEFORE" \
  test "$(jq -r '.last_checkin_at' "$T12_ROOT/active/safe.json" 2>/dev/null)" = "$T12_CHKIN_BEFORE"
assert_true "TC-OBS-12g: nothing was written outside log/ — the canonical log is complete" \
  "stray event files: $(find "$T12_ROOT" -name '*.events.jsonl' -not -path "$T12_ROOT/log/*" 2>/dev/null | tr '\n' ' ')" \
  test -z "$(find "$T12_ROOT" -name '*.events.jsonl' -not -path "$T12_ROOT/log/*" 2>/dev/null)"

# ===========================================================================
# T13 — `--worktree` IS DATA, NEVER CODE. It was persisted raw and then spliced
# into `bash -c` as `git -C '$worktree' …`. An existing directory literally named
#   /tmp/wt'; touch <marker>; #
# passed the -d check and EXECUTED the injected command at deadline time
# (measured: the marker was created), immediately before done_when is re-run —
# so it can manufacture a "finished" deadline snapshot.
# FALSIFYING EDIT: change the git call in watch_deadline() back to
# `run_bounded "$PROBE_LIMIT_S" "git -C '$worktree' log -3 --oneline"` —
# TC-OBS-13b goes red (the marker appears).
# ===========================================================================
echo ""
T13_ROOT="$WORK/t13"; mkdir -p "$T13_ROOT"
T13_MARKER="$WORK/t13-injected-marker"
rm -f "$T13_MARKER"
# The directory name IS the payload. It must exist, so that the `-d` guard passes
# and the only thing standing between the payload and a shell is the quoting.
T13_EVIL="$WORK/t13wt'; touch $T13_MARKER; #"
mkdir -p "$T13_EVIL"
OBSERVER_ROOT="$T13_ROOT" bash "$OBSERVE" declare \
  --id injected --intent "a worktree path that is also a shell command" \
  --done-when "test -f $WORK/t13-never" --progress-probe "printf 'stable\n'" \
  --checkin-every-s 3600 --hard-deadline-s 30 --max-rounds 5 \
  --worktree "$T13_EVIL" >/dev/null 2>&1
# Backdate the deadline so the snapshot path runs NOW instead of in 30s. The
# snapshot is the code path under test; waiting 30s for it would buy nothing.
T13_TMP=$(mktemp "$T13_ROOT/t13.XXXXXX")
jq '.deadline_at = (.deadline_at - 300)' "$T13_ROOT/active/injected.json" > "$T13_TMP" \
  && mv -f "$T13_TMP" "$T13_ROOT/active/injected.json"
T13_OUT=$(OBSERVER_ROOT="$T13_ROOT" bash "$OBSERVE" checkin --id injected --claim working 2>&1)
assert_contains "TC-OBS-13a: the deadline snapshot ran and reported the worktree" \
  " DEADLINE injected " "$T13_OUT"
assert_true "TC-OBS-13b: the injected command did NOT execute" \
  "marker $T13_MARKER was created — the worktree value reached a shell" \
  test ! -f "$T13_MARKER"

# ===========================================================================
# T14 — ONE DEADLINE, ONE ALERT, even with concurrent watchers. The old order
# was measure → emit → retire with nothing atomic in it, and the measurement
# takes seconds, so two watchers over one OBSERVER_ROOT both alerted. TC-OBS-4j
# asserted "exactly one DEADLINE" with only ONE watcher and could not see it.
# FALSIFYING EDITS — TWO, because ONE assertion each. Stated separately after
# measuring, since the original note claimed both went red on one edit and 14b
# did not:
#   14a: move the `claim_declaration` call in watch_deadline() to AFTER the
#        DEADLINE emit. Two watchers then both emit → two DEADLINE events. 14b
#        stays GREEN on this edit, because only the first caller to reach the
#        rename still claims, so RETIRED is emitted once either way.
#   14b: keep the claim where it is but "simplify" the final RETIRED emit back to
#        `retire "$task_id" "hard-deadline"`. That re-claims, loses, and emits
#        NOTHING — zero RETIRED events. TC-OBS-4g goes red with it.
# ===========================================================================
echo ""
T14_ROOT="$WORK/t14"; mkdir -p "$T14_ROOT"
T14_REPO=$(make_repo "$WORK/t14repo")
OBSERVER_ROOT="$T14_ROOT" bash "$OBSERVE" declare \
  --id raced --intent "one deadline must produce exactly one alert" \
  --done-when "test -f $WORK/t14-never" \
  --progress-probe "git -C $T14_REPO rev-parse HEAD" \
  --checkin-every-s 3600 --hard-deadline-s 300 --max-rounds 5 \
  --worktree "$T14_REPO" >/dev/null 2>&1
# Already overdue when the watchers start, so BOTH hit the deadline branch on
# their first iteration — which is the race, made deterministic instead of hoped
# for. Fixture edited directly on purpose: a 30s real wait would still leave the
# collision to chance.
T14_TMP=$(mktemp "$T14_ROOT/t14.XXXXXX")
jq '.deadline_at = (.deadline_at - 3000)' "$T14_ROOT/active/raced.json" > "$T14_TMP" \
  && mv -f "$T14_TMP" "$T14_ROOT/active/raced.json"
OBSERVER_ROOT="$T14_ROOT" bash "$OBSERVE" watch --tick-s 1 --idle-exit-s 5 --max-lifetime-s 60 \
  > "$WORK/t14-watch-a.out" 2>&1 &
WATCH_PIDS+=($!)
OBSERVER_ROOT="$T14_ROOT" bash "$OBSERVE" watch --tick-s 1 --idle-exit-s 5 --max-lifetime-s 60 \
  > "$WORK/t14-watch-b.out" 2>&1 &
WATCH_PIDS+=($!)
T14_DEADLINE=$(( $(date +%s) + 45 ))
while :; do
  [[ "$(log_events "$T14_ROOT" raced RETIRED)" != "0" ]] && break
  (( $(date +%s) >= T14_DEADLINE )) && break
  sleep 1
done
sleep 3   # bounded settle: let a SECOND (wrong) alert land if the claim is broken
assert_true "TC-OBS-14a: exactly ONE DEADLINE event with two watchers racing" \
  "log had $(log_events "$T14_ROOT" raced DEADLINE) DEADLINE events" \
  test "$(log_events "$T14_ROOT" raced DEADLINE)" -eq 1
assert_true "TC-OBS-14b: exactly ONE RETIRED event with two watchers racing" \
  "log had $(log_events "$T14_ROOT" raced RETIRED) RETIRED events" \
  test "$(log_events "$T14_ROOT" raced RETIRED)" -eq 1

# ===========================================================================
# T15 — A SYNTACTICALLY BROKEN PREDICATE IS REJECTED. `--done-when 'if then'`
# exits 2, and the old case rejected only 0/124/126/127, so the declaration was
# WRITTEN for a predicate that can only ever print a parse error. This is NOT
# the deliberately-accepted runnable-but-never-true case (TC-OBS-5m): that one
# runs and answers "no"; this one does not run.
# FALSIFYING EDIT: delete the two `bash -n -c` blocks from cmd_declare() —
# TC-OBS-15a/15c go red. ⛔ Do NOT "fix" this by rejecting exit code 2 instead:
# `grep` exits 2 on a read error, and a predicate is allowed to do that.
# ===========================================================================
echo ""
T15_ROOT="$WORK/t15"; mkdir -p "$T15_ROOT"
T15A_OUT=$(OBSERVER_ROOT="$T15_ROOT" bash "$OBSERVE" declare \
  --id syntaxerr --intent "x" --done-when "if then" --progress-probe "printf 'x\n'" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 2>&1)
T15A_RC=$?
assert_rc "TC-OBS-15a: a done_when with a shell syntax error is REJECTED" 2 "$T15A_RC" "$T15A_OUT"
assert_contains "TC-OBS-15b: the rejection says it cannot run at all" "not valid shell" "$T15A_OUT"
assert_true "TC-OBS-15c: and no declaration was written" "declaration was written anyway" \
  test ! -f "$T15_ROOT/active/syntaxerr.json"

T15D_OUT=$(OBSERVER_ROOT="$T15_ROOT" bash "$OBSERVE" declare \
  --id probesyntax --intent "x" --done-when "false" --progress-probe "for do done" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 2>&1)
T15D_RC=$?
assert_rc "TC-OBS-15d: a progress_probe with a shell syntax error is REJECTED" 2 "$T15D_RC" "$T15D_OUT"
# ⛔ 15d ALONE IS A MIRROR, MEASURED: with the syntax checks removed the probe is
# still rejected — for exiting 2 ("must exit 0 (got 2)") rather than for being
# unparseable. Same verdict, different reason, so the rc assertion cannot fail.
# 15e is the assertion that actually falsifies, and it is why the pair exists.
assert_contains "TC-OBS-15e: and REJECTED for being unparseable, not merely for exiting non-zero" \
  "not valid shell" "$T15D_OUT"

# ===========================================================================
# T16 — THE SELF-ADVANCING PROBE. ⛔ THIS IS THE HOLE UNDER THE CENTRAL CLAIM. ⛔
# The script computes the MISMATCH verdict, but the DECLARING AGENT CHOOSES THE
# PROBE — and choosing the input defeats the arithmetic. Measured before the fix:
# `--progress-probe 'date +%s'`, then a check-in one second later claiming
# `working` with literally no work done → delta=1, exit 0, NO MISMATCH.
# FALSIFYING EDIT: delete the second `run_bounded "$PROBE_LIMIT_S"
# "$progress_probe"` comparison block from cmd_declare() — TC-OBS-16a/16b go red
# and the clock probe is accepted again.
# ===========================================================================
echo ""
T16_ROOT="$WORK/t16"; mkdir -p "$T16_ROOT"
T16A_OUT=$(OBSERVER_ROOT="$T16_ROOT" bash "$OBSERVE" declare \
  --id clockprobe --intent "a probe measuring the clock, not the work" \
  --done-when "test -f $WORK/t16-never" --progress-probe "date +%s" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 2>&1)
T16A_RC=$?
assert_rc "TC-OBS-16a: a probe that advances on its own is REJECTED" 2 "$T16A_RC" "$T16A_OUT"
assert_contains "TC-OBS-16b: the rejection names the consequence it prevents" \
  "would suppress every MISMATCH" "$T16A_OUT"
assert_true "TC-OBS-16c: and no declaration was written" "declaration was written anyway" \
  test ! -f "$T16_ROOT/active/clockprobe.json"

# A probe that returns a fresh PID each run is the same defect without a clock.
T16D_OUT=$(OBSERVER_ROOT="$T16_ROOT" bash "$OBSERVE" declare \
  --id pidprobe --intent "x" --done-when "test -f $WORK/t16-never" \
  --progress-probe 'printf "%s\n" "$$"' \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 2>&1)
T16D_RC=$?
assert_rc "TC-OBS-16d: a probe returning its own PID is REJECTED too" 2 "$T16D_RC" "$T16D_OUT"

# The mirror: a STABLE probe is still accepted. Without this, T16 would also pass
# if declare rejected every probe, which would break the whole mechanism.
T16E_REPO=$(make_repo "$WORK/t16repo")
T16E_OUT=$(OBSERVER_ROOT="$T16_ROOT" bash "$OBSERVE" declare \
  --id stableprobe --intent "a git HEAD probe is stable across two runs" \
  --done-when "test -f $WORK/t16-never" \
  --progress-probe "git -C $T16E_REPO rev-parse HEAD" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 2>&1)
T16E_RC=$?
assert_rc "TC-OBS-16e: a stable probe is still ACCEPTED" 0 "$T16E_RC" "$T16E_OUT"

# ===========================================================================
# T17 — THE HARD DEADLINE HOLDS WITH NO WATCHER RUNNING. It used to be checked
# only in watch_one, which made "every wait has a hard deadline" true only while
# a watcher happened to exist — and nothing in this toolbox starts or re-arms
# one, while a task may declare 6h against a watcher that defaults to 4h. ⛔ No
# watcher is started anywhere in this test. ⛔
# FALSIFYING EDIT: delete the `enforce_deadline` call from cmd_checkin() and
# cmd_close() — TC-OBS-17a/17d go red and an overdue declaration is serviced
# forever.
# ===========================================================================
echo ""
T17_ROOT="$WORK/t17"; mkdir -p "$T17_ROOT"
T17_REPO=$(make_repo "$WORK/t17repo")
OBSERVER_ROOT="$T17_ROOT" bash "$OBSERVE" declare \
  --id overdue --intent "an overdue task retired by a plain check-in" \
  --done-when "test -f $WORK/t17-never" \
  --progress-probe "git -C $T17_REPO rev-parse HEAD" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
T17_TMP=$(mktemp "$T17_ROOT/t17.XXXXXX")
jq '.deadline_at = (.deadline_at - 3000)' "$T17_ROOT/active/overdue.json" > "$T17_TMP" \
  && mv -f "$T17_TMP" "$T17_ROOT/active/overdue.json"
# ⛔ THE CLAIM IS `stuck`, AND THAT IS THE WHOLE POINT OF THE FIXTURE. ⛔ Measured
# with `working`: this assertion passed even with enforce_deadline REVERTED,
# because an unchanged probe plus a `working` claim exits 3 as a MISMATCH — the
# right number for the wrong reason, which is a mirror. `stuck` produces no
# MISMATCH, no CHURN (round 1 of 5) and no NO_PROGRESS (a silent done_when), so a
# non-overdue check-in here exits 0 and rc=3 can only come from the deadline.
T17A_OUT=$(OBSERVER_ROOT="$T17_ROOT" bash "$OBSERVE" checkin --id overdue --claim stuck 2>&1)
T17A_RC=$?
assert_rc "TC-OBS-17a: a check-in on an overdue task exits 3 (anomaly)" 3 "$T17A_RC" "$T17A_OUT"
assert_contains "TC-OBS-17b: and it emits the DEADLINE snapshot, with no watcher involved" \
  " DEADLINE overdue " "$T17A_OUT"
assert_true "TC-OBS-17c: the overdue declaration was retired" "still active" \
  test ! -f "$T17_ROOT/active/overdue.json"

# close is the other command that could service an overdue task forever, and it
# is the one where doing so would write a false SUCCESS into the record.
T17_ROOT2="$WORK/t17b"; mkdir -p "$T17_ROOT2"
T17_REPO2=$(make_repo "$WORK/t17repo2")
OBSERVER_ROOT="$T17_ROOT2" bash "$OBSERVE" declare \
  --id overdueclose --intent "an overdue task cannot be closed as shipped" \
  --done-when "test -f $WORK/t17b-marker" \
  --progress-probe "git -C $T17_REPO2 rev-parse HEAD" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
: > "$WORK/t17b-marker"    # done_when is now TRUE — finished, but LATE
T17_TMP2=$(mktemp "$T17_ROOT2/t17b.XXXXXX")
jq '.deadline_at = (.deadline_at - 3000)' "$T17_ROOT2/active/overdueclose.json" > "$T17_TMP2" \
  && mv -f "$T17_TMP2" "$T17_ROOT2/active/overdueclose.json"
T17D_OUT=$(OBSERVER_ROOT="$T17_ROOT2" bash "$OBSERVE" close --id overdueclose --outcome shipped 2>&1)
T17D_RC=$?
assert_rc "TC-OBS-17d: closing an overdue task exits 3 instead of recording an outcome" 3 "$T17D_RC" "$T17D_OUT"
assert_contains "TC-OBS-17e: the record shows a DEADLINE, not a CLOSED" \
  " DEADLINE overdueclose " "$T17D_OUT"
# "Finished, but late" is not lost — the snapshot measured done_when and says so.
assert_contains "TC-OBS-17f: the snapshot still reports the work HAD finished" \
  "TRUE — the work finished but was never closed" "$T17D_OUT"
assert_true "TC-OBS-17g: no CLOSED event entered the record" \
  "log had $(log_events "$T17_ROOT2" overdueclose CLOSED) CLOSED events" \
  test "$(log_events "$T17_ROOT2" overdueclose CLOSED)" -eq 0

# ===========================================================================
# T18 — ONE EVENT IS ONE LINE, so no field can FORGE a second event. stdout is
# documented as the notification stream; `jq --arg` escaped the newline into the
# log correctly, but `jq -r` un-escaped it on the way to stdout, so
# `--note $'\n<iso> DEADLINE <id> forged=1'` printed an apparent second event.
# FALSIFYING EDIT: drop the `one_line` wrappers from the two printfs in
# emit_event() — TC-OBS-18a goes red (three timestamp-led lines, not two).
# ===========================================================================
echo ""
T18_ROOT="$WORK/t18"; mkdir -p "$T18_ROOT"
OBSERVER_ROOT="$T18_ROOT" bash "$OBSERVE" declare \
  --id forgery --intent "a note that tries to write its own event line" \
  --done-when "test -f $WORK/t18-never" --progress-probe "printf 'stable\n'" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
# ⛔ Written to a FILE and counted there, never echoed: `echo` re-interprets the
# escaped `\n` and would make a fixed script look broken.
OBSERVER_ROOT="$T18_ROOT" bash "$OBSERVE" checkin --id forgery --claim stuck \
  --note "$(printf '\n2099-01-01T00:00:00Z DEADLINE forgery forged=1')" \
  > "$WORK/t18-checkin.out" 2>&1
T18_EVENT_LINES=$(grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$WORK/t18-checkin.out" 2>/dev/null | tr -d ' ')
assert_true "TC-OBS-18a: a newline in --note cannot add an event line (CLAIM + FACTS only)" \
  "counted $T18_EVENT_LINES timestamp-led lines, expected 2" \
  test "$T18_EVENT_LINES" -eq 2
assert_contains "TC-OBS-18b: the newline is shown escaped, so the attempt stays visible" \
  'note=\n2099-01-01T00:00:00Z' "$(cat "$WORK/t18-checkin.out")"
# 18c states the OTHER half of the split, and it was already true: `jq --arg`
# escaped the newline into the log correctly all along — only `jq -r` un-escaped
# it on the way to stdout. So this stays green when one_line is reverted
# (measured). It is here to keep the two halves distinguishable, and it guards a
# future change that built an event line by string interpolation instead of jq.
assert_true "TC-OBS-18c: no forged DEADLINE reached the append-only log (which was never at risk)" \
  "log had $(log_events "$T18_ROOT" forgery DEADLINE) DEADLINE events" \
  test "$(log_events "$T18_ROOT" forgery DEADLINE)" -eq 0

# ===========================================================================
# T19 — THE PER-PROBE TIMEOUT, which had NO test at all. run_bounded's timeout
# arm is the single most load-bearing bound in the script — it is incident 2's
# answer for every caller-supplied command — and REMOVING IT LEFT THE WHOLE
# SUITE GREEN, because no test used a blocking predicate. T5 claimed to cover
# "a predicate that cannot answer in time" and did not.
#
# OBSERVE_PROBE_LIMIT_S is a TIGHTEN-ONLY seam (values above the 30s default are
# ignored), so this runs in ~4s instead of ~30s. `sleep 45` rather than an
# infinite sleep is deliberate: with the arm removed the suite must go RED, not
# hang, and a bounded sleep gives a red assertion instead of a stalled run.
# FALSIFYING EDIT: delete the `now >= deadline` branch from run_bounded() —
# TC-OBS-19b and 19c go red (the message becomes "ALREADY TRUE", because
# `sleep 45` eventually exits 0, and the elapsed time jumps to ~45s).
# ===========================================================================
echo ""
T19_ROOT="$WORK/t19"; mkdir -p "$T19_ROOT"
T19_START=$(date +%s)
T19_OUT=$(OBSERVER_ROOT="$T19_ROOT" OBSERVE_PROBE_LIMIT_S=3 bash "$OBSERVE" declare \
  --id blockingdw --intent "x" --done-when "sleep 45" --progress-probe "printf 'stable\n'" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 2>&1)
T19_RC=$?
T19_ELAPSED=$(( $(date +%s) - T19_START ))
# 19a and 19d are the rc halves, and rc alone cannot falsify: with the timeout arm
# removed the blocking predicate is STILL rejected 45 seconds later, as ALREADY
# TRUE / no output. 19b, 19c, 19e and 19f are the assertions that go red.
assert_rc "TC-OBS-19a: a done_when that blocks is REJECTED" 2 "$T19_RC" "$T19_OUT"
assert_contains "TC-OBS-19b: the rejection names the timeout, not some other reason" \
  "did not finish within" "$T19_OUT"
if (( T19_ELAPSED <= 20 )); then
  pass "TC-OBS-19c: the 3s probe bound was enforced in ${T19_ELAPSED}s (the predicate slept 45)"
else
  failed "TC-OBS-19c: took ${T19_ELAPSED}s against a 3s probe bound" "run_bounded is not enforcing its deadline"
fi

# The same bound on the OTHER caller-supplied command, because a guard on one
# path and not its sibling is the asymmetry class this suite keeps catching.
T19D_START=$(date +%s)
T19D_OUT=$(OBSERVER_ROOT="$T19_ROOT" OBSERVE_PROBE_LIMIT_S=3 bash "$OBSERVE" declare \
  --id blockingpp --intent "x" --done-when "false" --progress-probe "sleep 45" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 2>&1)
T19D_RC=$?
T19D_ELAPSED=$(( $(date +%s) - T19D_START ))
assert_rc "TC-OBS-19d: a progress_probe that blocks is REJECTED" 2 "$T19D_RC" "$T19D_OUT"
assert_contains "TC-OBS-19e: and the measured exit code is the timeout code" "(got 124)" "$T19D_OUT"
if (( T19D_ELAPSED <= 20 )); then
  pass "TC-OBS-19f: the probe bound held in ${T19D_ELAPSED}s on the progress probe too"
else
  failed "TC-OBS-19f: took ${T19D_ELAPSED}s against a 3s probe bound" "run_bounded is not enforcing its deadline"
fi

# ⛔ And the seam itself cannot LOOSEN the bound. ⛔ An env var that could raise a
# timeout would be a way to reintroduce incident 2 from outside the script.
#
# ⛔ THE VALUE 9999 IS CHOSEN, NOT ARBITRARY, AND THIS ASSERTION WAS A MIRROR
# UNTIL IT WAS. ⛔ Two independent guards reject an oversized override: a shape
# check (`^[0-9]{1,4}$`) and the tighten-only clamp (`< PROBE_LIMIT_S`). Measured
# with 99999: removing the CLAMP left this assertion green, because the 5-digit
# value never got past the shape check — so it proved nothing about the guard it
# was written for. 9999 satisfies the shape check and can only be stopped by the
# clamp, so reverting the clamp now turns this red.
# FALSIFYING EDIT: drop `&& (( 10#$OBSERVE_PROBE_LIMIT_S < PROBE_LIMIT_S ))` from
# the seam block in observe.sh — TC-OBS-19g and 19h go red (the message becomes
# "ALREADY TRUE" because the predicate runs to completion under a 9999s bound).
#
# ⛔ THE PREDICATE SLEEPS 90s, NOT 45s, AND THE MARGIN IS THE REASON. ⛔ With
# `sleep 45` the reverted run finished in 46s against a `<= 45` threshold — a
# ONE-SECOND margin, i.e. a falsifier that a slow machine turns into a false
# green. At 90s the fixed path still takes ~31s (the 30s default bound) and the
# reverted path takes ~91s, so the threshold sits with ~14s of headroom below and
# ~46s above.
T19G_START=$(date +%s)
T19G_OUT=$(OBSERVER_ROOT="$T19_ROOT" OBSERVE_PROBE_LIMIT_S=9999 bash "$OBSERVE" declare \
  --id seamabuse --intent "x" --done-when "sleep 90" --progress-probe "printf 'stable\n'" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 2>&1)
T19G_ELAPSED=$(( $(date +%s) - T19G_START ))
assert_contains "TC-OBS-19g: an oversized OBSERVE_PROBE_LIMIT_S is IGNORED by the tighten-only clamp" \
  "did not finish within 30s" "$T19G_OUT"
if (( T19G_ELAPSED <= 45 )); then
  pass "TC-OBS-19h: the 30s default still capped it (${T19G_ELAPSED}s), not 9999s"
else
  failed "TC-OBS-19h: took ${T19G_ELAPSED}s" "the seam raised the bound instead of only tightening it"
fi

# ===========================================================================
# T21 — A PREDICATE THAT FORKS ESCAPED run_bounded ENTIRELY.
# `run_bounded` bounds the child it WAITS for; the header's promise is about the
# WAIT. Those coincide only when the predicate does not fork. Measured:
#   --done-when 'sleep 999999 & exit 1'
# returns its status INSTANTLY, so the sentinel arrives, the timeout arm never
# runs, and the backgrounded child outlives declare with nothing left to stop it.
# T19 covers only a FOREGROUND sleep, which is why it stayed green.
#
# The assertion is on SURVIVING PROCESSES, not on how fast declare returned — a
# test that timed declare would have passed against the broken version and proved
# nothing. Both caller-supplied commands are covered, because both go through the
# same run_bounded and a guard on one sibling is not a guard.
# FALSIFYING EDIT: delete the `kill_probe_group "$pid"` call after `wait` in
# run_bounded() — TC-OBS-21a and 21c go red with a surviving process id.
# ===========================================================================
echo ""
T21_ROOT="$WORK/t21"; mkdir -p "$T21_ROOT"
# ⛔ THE MARKERS ARE DERIVED FROM THIS SUITE'S PID, AND THAT IS NOT COSMETIC. ⛔
# `pgrep -f` and `pkill -f` match ACROSS THE WHOLE MACHINE. With fixed markers,
# two concurrent runs of this suite see and kill each other's fixtures — and
# red-proofing runs several copies at once by design. Measured, with fixed
# markers and three concurrent runs: TC-OBS-21a/21b went RED in two suites whose
# mutation had nothing to do with forking (another suite's `pkill` had removed
# their processes and SIGTERMed a `declare`), and TC-OBS-21c went GREEN in the one
# suite where it should have been the falsifier, because a neighbour had already
# cleaned up the survivor. A false red and a false green from the same defect.
# PIDs are unique among live processes, so no two concurrent suites can collide.
T21_MARK=$(( 900000 + ($$ % 40000) ))
T21_MARK2=$(( 950000 + ($$ % 40000) ))
pkill -f "sleep $T21_MARK" 2>/dev/null
pkill -f "sleep $T21_MARK2" 2>/dev/null

OBSERVER_ROOT="$T21_ROOT" bash "$OBSERVE" declare \
  --id forker --intent "a predicate that forks a child and exits immediately" \
  --done-when "sleep $T21_MARK & exit 1" --progress-probe "printf 'stable\n'" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
T21A_RC=$?
sleep 2
T21_SURVIVOR=$(pgrep -f "sleep $T21_MARK" 2>/dev/null | tr '\n' ' ')
assert_true "TC-OBS-21a: a forking done_when leaves NO surviving process" \
  "survivor pid(s): $T21_SURVIVOR" \
  test -z "$T21_SURVIVOR"
# The mirror image: the declaration itself must still be accepted. `sleep & exit 1`
# is a legitimate (if odd) predicate that answers "not done", and killing the
# escapee must not turn into rejecting the caller.
assert_rc "TC-OBS-21b: and the declaration is still accepted (the fork is swept, not refused)" \
  0 "$T21A_RC"

OBSERVER_ROOT="$T21_ROOT" bash "$OBSERVE" declare \
  --id forkprobe --intent "a progress probe that forks a child" \
  --done-when "test -f $WORK/t21-never" \
  --progress-probe "sleep $T21_MARK2 & printf 'stable\n'" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
sleep 2
T21_SURVIVOR2=$(pgrep -f "sleep $T21_MARK2" 2>/dev/null | tr '\n' ' ')
assert_true "TC-OBS-21c: a forking PROGRESS PROBE leaves no surviving process either" \
  "survivor pid(s): $T21_SURVIVOR2" \
  test -z "$T21_SURVIVOR2"
# A probe that deliberately creates a NEW process group must be rejected before
# execution. The group sweep cannot reach a `setsid` escapee, so accepting this
# command would make the documented process bound false by construction.
T21_SET_OUT=$(OBSERVER_ROOT="$T21_ROOT" bash "$OBSERVE" declare \
  --id setsid-probe --intent "a probe that tries to escape its process group" \
  --done-when "test -f $WORK/t21-never3" \
  --progress-probe "setsid true; printf 'stable\n'" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 2>&1)
T21_SET_RC=$?
assert_rc "TC-OBS-21d: a progress probe that invokes setsid is rejected" 2 \
  "$T21_SET_RC" "$T21_SET_OUT"
assert_contains "TC-OBS-21e: the setsid rejection explains the process-group bound" \
  "setsid" "$T21_SET_OUT"
# The ad-hoc probe path must carry the same containment contract as declared
# predicates. FALSIFYING EDIT: apply the rejection only in cmd_declare.
T21_PROBE_OUT=$(OBSERVER_ROOT="$T21_ROOT" bash "$OBSERVE" probe \
  --id forker --cmd "s=setsid; \$s true" 2>&1)
T21_PROBE_RC=$?
assert_rc "TC-OBS-21f: an ad-hoc probe cannot invoke setsid indirectly" 2 \
  "$T21_PROBE_RC" "$T21_PROBE_OUT"
assert_contains "TC-OBS-21g: indirect setsid rejection explains the process-group bound" \
  "process group" "$T21_PROBE_OUT"
# Indirect parameter expansion is another command-position form that must not
# escape the textual containment guard. FALSIFYING EDIT: reject only $VAR and
# let ${!VAR} execute a dynamically selected setsid.
T21_INDIRECT_OUT=$(OBSERVER_ROOT="$T21_ROOT" bash "$OBSERVE" declare \
  --id indirect-setsid --intent "a probe that uses indirect command expansion" \
  --done-when "test -f $WORK/t21-never4" \
  --progress-probe 'cmd=setsid; ${!cmd} true' \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 2>&1)
T21_INDIRECT_RC=$?
assert_rc "TC-OBS-21h: indirect parameter expansion cannot invoke setsid" 2 \
  "$T21_INDIRECT_RC" "$T21_INDIRECT_OUT"
assert_contains "TC-OBS-21i: indirect expansion rejection explains the process-group bound" \
  "process group" "$T21_INDIRECT_OUT"
# A plain `$VAR` in command position is just as able to resolve to setsid as
# the braced/indirect forms above. Keep the value in the environment so the
# command text contains no literal executable name for the detector to see.
T21_PLAIN_OUT=$(cmd_name=setsid OBSERVER_ROOT="$T21_ROOT" bash "$OBSERVE" declare \
  --id plain-indirect-setsid --intent "a probe that uses a plain command variable" \
  --done-when "test -f $WORK/t21-never6" \
  --progress-probe '$cmd_name true' \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 2>&1)
T21_PLAIN_RC=$?
assert_rc "TC-OBS-21k: plain command-variable expansion cannot invoke setsid" 2 \
  "$T21_PLAIN_RC" "$T21_PLAIN_OUT"
assert_contains "TC-OBS-21l: plain expansion rejection explains the process-group bound" \
  "process group" "$T21_PLAIN_OUT"
T21_BUILTIN_OUT=$(OBSERVER_ROOT="$T21_ROOT" bash "$OBSERVE" declare \
  --id builtin-indirect-setsid --intent "a probe that uses the command builtin" \
  --done-when "test -f $WORK/t21-never7" \
  --progress-probe 'cmd=setsid; command $cmd true' \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 2>&1)
T21_BUILTIN_RC=$?
assert_rc "TC-OBS-21m: command-builtin indirection cannot invoke setsid" 2 \
  "$T21_BUILTIN_RC" "$T21_BUILTIN_OUT"
assert_contains "TC-OBS-21n: command-builtin rejection explains the process-group bound" \
  "process group" "$T21_BUILTIN_OUT"
# Ordinary argument expansions remain valid. FALSIFYING EDIT: treat every
# whitespace-prefixed expansion as command-position and reject this probe.
T21_ARG_REPO=$(make_repo "$WORK/t21-arg-repo")
T21_ARG_OUT=$(OBSERVER_ROOT="$T21_ROOT" bash "$OBSERVE" declare \
  --id argument-expansion --intent "a probe with a normal argument expansion" \
  --done-when "test -f $WORK/t21-never5" \
  --progress-probe "printf '%s\\n' \"\$(git -C $T21_ARG_REPO rev-parse HEAD)\"" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 2>&1)
T21_ARG_RC=$?
assert_rc "TC-OBS-21j: a normal argument expansion remains valid" 0 \
  "$T21_ARG_RC" "$T21_ARG_OUT"
# Belt and braces: never let a failed assertion leave a process behind.
pkill -f "sleep $T21_MARK" 2>/dev/null
pkill -f "sleep $T21_MARK2" 2>/dev/null

# ===========================================================================
# T22 — --max-lifetime-s IS A CAP, NOT A SUGGESTION. It was checked once per
# pass, and then each overdue subject ran a DEADLINE snapshot of up to three
# bounded probes with nothing re-checking the clock — so N overdue subjects
# MULTIPLIED the overshoot, and even one could add ~90s to a 5s cap. T8 never
# combines an expired subject with a short watcher lifetime, which is why it
# could not see this.
#
# Fixture note: the slow probes are written by jq AFTER declare, because declare
# would (correctly) reject a predicate that cannot answer inside PROBE_LIMIT_S.
# The snapshot path is what is under test, not the declaration path.
# ===========================================================================
echo ""
T22_ROOT="$WORK/t22"; mkdir -p "$T22_ROOT"
OBSERVER_ROOT="$T22_ROOT" bash "$OBSERVE" declare \
  --id slowsnap --intent "a snapshot that would outlive the watcher that started it" \
  --done-when "test -f $WORK/t22-never" --progress-probe "printf 'stable\n'" \
  --checkin-every-s 3600 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
T22_TMP=$(mktemp "$T22_ROOT/t22.XXXXXX")
jq --argjson n "$(date +%s)" \
   '.deadline_at = ($n - 100) | .progress_probe = "sleep 300; printf x" | .done_when = "sleep 300"' \
   "$T22_ROOT/active/slowsnap.json" > "$T22_TMP" && mv -f "$T22_TMP" "$T22_ROOT/active/slowsnap.json"
# ⛔ BACKGROUNDED WITH A BOUNDED WAIT, NOT RUN IN THE FOREGROUND. ⛔ The first
# version of this test called `watch` in the FOREGROUND with no external bound —
# an unbounded wait, inside the suite for the unbounded-wait bug, written by the
# same hand that had just fixed it twice. It cost 45 minutes on one run and took
# three unrelated tests down with it (a fixture's own 600s deadline expired while
# the suite was stalled, so a later `probe` correctly retired it). A regression
# here must produce a RED ASSERTION, never a stalled run.
T22_START=$(date +%s)
OBSERVER_ROOT="$T22_ROOT" bash "$OBSERVE" watch --tick-s 1 --idle-exit-s 600 --max-lifetime-s 5 \
  > "$WORK/t22-watch.out" 2>&1 &
T22_PID=$!
WATCH_PIDS+=($T22_PID)
T22_WAIT=$(( T22_START + 90 ))
while :; do
  kill -0 "$T22_PID" 2>/dev/null || break
  (( $(date +%s) >= T22_WAIT )) && break
  sleep 1
done
if kill -0 "$T22_PID" 2>/dev/null; then
  kill -KILL "$T22_PID" 2>/dev/null
fi
T22_ELAPSED=$(( $(date +%s) - T22_START ))
# 5s cap + 30s declared grace = 35s, plus poll slack. An uncapped snapshot is
# three 30s probes on top of the cap — about 95s.
if (( T22_ELAPSED <= 45 )); then
  pass "TC-OBS-22a: a 5s cap held at ${T22_ELAPSED}s with an overdue subject whose probes never answer"
else
  failed "TC-OBS-22a: watcher lived ${T22_ELAPSED}s against a 5s cap + 30s grace" "the DEADLINE snapshot is not capped against the remaining lifetime"
fi
assert_contains "TC-OBS-22b: and it exited on the lifetime cap, having taken the snapshot" \
  "reason=max-lifetime" "$(cat "$WORK/t22-watch.out" 2>/dev/null)"

# ⛔ THE NOTIFICATION STREAM MUST CARRY EVENTS AND NOTHING ELSE. ⛔ `set -m` is
# required for the process-group sweep (T21), and it makes the SHELL report each
# job's termination on its own stderr — "Terminated: 15" lines that landed in this
# very stream. A line that is not an event teaches a reader to skim, and a skimmed
# stream is not an observation. This run kills two probes, so it is exactly the
# case that produced the noise.
# FALSIFYING EDIT: change `run_bounded` back to a single function (drop the
# `run_bounded_impl "$@" 2>/dev/null` wrapper) — TC-OBS-22d goes red naming the
# leaked job-control lines.
T22_NOISE=$(grep -vE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T|^  ' "$WORK/t22-watch.out" 2>/dev/null | grep -v '^$' | head -3)
assert_true "TC-OBS-22d: the stream contains only events — no job-control noise" \
  "leaked: $(printf '%s' "$T22_NOISE" | tr '\n' '|')" \
  test -z "$T22_NOISE"

# The MULTIPLICATION half: three overdue subjects must cost ONE snapshot, not
# three, because the cap is re-checked before every subject. Probe budget is
# tightened to 3s here so the grace above is not what ends the run — otherwise
# this would pass for the wrong reason and prove nothing about the per-subject
# check.
T22C_ROOT="$WORK/t22c"; mkdir -p "$T22C_ROOT"
for slow in one two three; do
  OBSERVER_ROOT="$T22C_ROOT" bash "$OBSERVE" declare \
    --id "overdue$slow" --intent "one of three simultaneously overdue subjects" \
    --done-when "test -f $WORK/t22c-never" --progress-probe "printf 'stable\n'" \
    --checkin-every-s 3600 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
  T22C_TMP=$(mktemp "$T22C_ROOT/t22c.XXXXXX")
  jq --argjson n "$(date +%s)" \
     '.deadline_at = ($n - 100) | .progress_probe = "sleep 300; printf x" | .done_when = "sleep 300"' \
     "$T22C_ROOT/active/overdue$slow.json" > "$T22C_TMP" \
     && mv -f "$T22C_TMP" "$T22C_ROOT/active/overdue$slow.json"
done
T22C_START=$(date +%s)
OBSERVER_ROOT="$T22C_ROOT" OBSERVE_PROBE_LIMIT_S=3 bash "$OBSERVE" watch \
  --tick-s 1 --idle-exit-s 600 --max-lifetime-s 5 > "$WORK/t22c-watch.out" 2>&1 &
T22C_PID=$!
WATCH_PIDS+=($T22C_PID)
T22C_WAIT=$(( T22C_START + 60 ))
while :; do
  kill -0 "$T22C_PID" 2>/dev/null || break
  (( $(date +%s) >= T22C_WAIT )) && break
  sleep 1
done
if kill -0 "$T22C_PID" 2>/dev/null; then
  kill -KILL "$T22C_PID" 2>/dev/null
fi
T22C_ELAPSED=$(( $(date +%s) - T22C_START ))
# One snapshot at a 3s probe budget is ~9s; three of them is ~27s.
if (( T22C_ELAPSED <= 18 )); then
  pass "TC-OBS-22c: three overdue subjects cost ONE snapshot (${T22C_ELAPSED}s), not three"
else
  failed "TC-OBS-22c: watcher lived ${T22C_ELAPSED}s with three overdue subjects" "the lifetime cap is not re-checked between subjects, so the overshoot multiplies"
fi

# ===========================================================================
# T23 — THE DEADLINE IS CHECKED AFTER THE PROBES, NOT ONLY BEFORE THEM. The
# preflight check reads the clock BEFORE running two caller-supplied commands,
# each of which may take up to PROBE_LIMIT_S. A check-in or close starting one
# second inside its deadline could therefore finish well outside it and still be
# serviced — resetting the silence timer, or writing CLOSED, on a task whose
# bound had already expired.
# FALSIFYING EDIT: delete the second `enforce_deadline` call from cmd_checkin()
# (the one above "persist the new snapshot") and from cmd_close() — TC-OBS-23a
# and 23d go red.
# ===========================================================================
echo ""
T23_ROOT="$WORK/t23"; mkdir -p "$T23_ROOT"
OBSERVER_ROOT="$T23_ROOT" bash "$OBSERVE" declare \
  --id slowcheck --intent "a check-in that begins inside its deadline and ends outside it" \
  --done-when "test -f $WORK/t23-never" --progress-probe "sleep 4; printf 'stable\n'" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
# Expire two seconds from NOW: the preflight passes, then ~8s of probes run.
T23_TMP=$(mktemp "$T23_ROOT/t23.XXXXXX")
jq --argjson n "$(date +%s)" '.deadline_at = ($n + 2)' "$T23_ROOT/active/slowcheck.json" > "$T23_TMP" \
  && mv -f "$T23_TMP" "$T23_ROOT/active/slowcheck.json"
T23A_OUT=$(OBSERVER_ROOT="$T23_ROOT" bash "$OBSERVE" checkin --id slowcheck --claim stuck 2>&1)
T23A_RC=$?
assert_rc "TC-OBS-23a: a check-in that ends past its deadline is refused, not serviced" 3 "$T23A_RC" "$T23A_OUT"
assert_contains "TC-OBS-23b: and the DEADLINE snapshot is taken" " DEADLINE slowcheck " "$T23A_OUT"
# The measurements that genuinely happened stay on the record — the refusal is
# about not KEEPING THE DECLARATION ALIVE, not about hiding what was measured.
assert_contains "TC-OBS-23c: the CLAIM and FACTS already measured are still recorded" \
  " FACTS slowcheck " "$T23A_OUT"

T23D_ROOT="$WORK/t23d"; mkdir -p "$T23D_ROOT"
OBSERVER_ROOT="$T23D_ROOT" bash "$OBSERVE" declare \
  --id slowclose --intent "a close that begins inside its deadline and ends outside it" \
  --done-when "sleep 4; test -f $WORK/t23d-marker" --progress-probe "printf 'stable\n'" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
: > "$WORK/t23d-marker"
T23D_TMP=$(mktemp "$T23D_ROOT/t23d.XXXXXX")
jq --argjson n "$(date +%s)" '.deadline_at = ($n + 2)' "$T23D_ROOT/active/slowclose.json" > "$T23D_TMP" \
  && mv -f "$T23D_TMP" "$T23D_ROOT/active/slowclose.json"
T23D_OUT=$(OBSERVER_ROOT="$T23D_ROOT" bash "$OBSERVE" close --id slowclose --outcome shipped 2>&1)
T23D_RC=$?
assert_rc "TC-OBS-23d: a close that ends past its deadline writes no outcome" 3 "$T23D_RC" "$T23D_OUT"
assert_true "TC-OBS-23e: and no CLOSED event entered the record" \
  "log had $(log_events "$T23D_ROOT" slowclose CLOSED) CLOSED events" \
  test "$(log_events "$T23D_ROOT" slowclose CLOSED)" -eq 0

# ===========================================================================
# T24 — `probe` RECORDS FIRST, THEN ENFORCES. It used to be exempt from the
# deadline entirely, on the reasoning that the first question asked about an
# overdue task must not destroy the answer. The reasoning was right and the
# conclusion was wrong: it left rules/agents.md and the skill claiming the bound
# holds at every subcommand while repeated probes kept an overdue declaration
# active forever with no watcher running. Ordering gives both.
# FALSIFYING EDIT: delete the `enforce_deadline` call at the end of cmd_probe()
# — TC-OBS-24b and 24c go red and the declaration stays active.
# ===========================================================================
echo ""
T24_ROOT="$WORK/t24"; mkdir -p "$T24_ROOT"
OBSERVER_ROOT="$T24_ROOT" bash "$OBSERVE" declare \
  --id overdueprobe --intent "an overdue task asked a question" \
  --done-when "test -f $WORK/t24-never" --progress-probe "printf 'stable\n'" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
T24_TMP=$(mktemp "$T24_ROOT/t24.XXXXXX")
jq '.deadline_at = (.deadline_at - 3000)' "$T24_ROOT/active/overdueprobe.json" > "$T24_TMP" \
  && mv -f "$T24_TMP" "$T24_ROOT/active/overdueprobe.json"
T24_OUT=$(OBSERVER_ROOT="$T24_ROOT" bash "$OBSERVE" probe --id overdueprobe --cmd "printf 'the answer\n'" 2>&1)
T24_RC=$?
# The ANSWER survives — that is the half the exemption existed to protect.
assert_contains "TC-OBS-24a: the measurement is recorded before the task is ended" \
  " PROBE overdueprobe " "$T24_OUT"
assert_contains "TC-OBS-24b: and the overdue task is then ended, with no watcher running" \
  " DEADLINE overdueprobe " "$T24_OUT"
assert_true "TC-OBS-24c: the declaration was retired" "still active" \
  test ! -f "$T24_ROOT/active/overdueprobe.json"
assert_rc "TC-OBS-24d: probe reports the anomaly in its exit code" 3 "$T24_RC" "$T24_OUT"

# ===========================================================================
# T25 — A REUSED ID MUST NOT INHERIT THE PREVIOUS LIFECYCLE. The log, the guard-2
# signature state and the retired declaration are all keyed by id alone, so
# re-declaring an id appended a second lifecycle to the first one's log: a new
# watcher relayed the OLD task's anomalies, guard 2 compared the new work's
# failure against the old work's, and the observer agent read two pieces of work
# as one. A reviewer hit this and worked around it by renaming the task.
# FALSIFYING EDIT: delete the `rotate_prior_lifecycle` call from cmd_declare() —
# TC-OBS-25b goes red with the previous lifecycle's MISMATCH still in the log.
# ===========================================================================
echo ""
T25_ROOT="$WORK/t25"; mkdir -p "$T25_ROOT"
T25_REPO=$(make_repo "$WORK/t25repo")
OBSERVER_ROOT="$T25_ROOT" bash "$OBSERVE" declare \
  --id reused --intent "the first life of this id" \
  --done-when "printf 'Foo.cs(1,1): error CS0246: type not found\n'; exit 1" \
  --progress-probe "git -C $T25_REPO rev-parse HEAD" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
OBSERVER_ROOT="$T25_ROOT" bash "$OBSERVE" checkin --id reused --claim working >/dev/null 2>&1
assert_true "TC-OBS-25a: the first life recorded a MISMATCH (the state that must not carry over)" \
  "log had $(log_events "$T25_ROOT" reused MISMATCH)" \
  test "$(log_events "$T25_ROOT" reused MISMATCH)" -ge 1
# Snapshot whether guard 2 left state behind, BEFORE the redeclare clears it.
# Without this the assertion below could pass on a fixture that never created any.
if [[ -s "$T25_ROOT/state/reused.progress" ]]; then T25_STATE_BEFORE=present; else T25_STATE_BEFORE=absent; fi
OBSERVER_ROOT="$T25_ROOT" bash "$OBSERVE" close --id reused --outcome abandoned >/dev/null 2>&1
OBSERVER_ROOT="$T25_ROOT" bash "$OBSERVE" declare \
  --id reused --intent "the second life of the same id" \
  --done-when "printf 'Foo.cs(1,1): error CS0246: type not found\n'; exit 1" \
  --progress-probe "git -C $T25_REPO rev-parse HEAD" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
assert_true "TC-OBS-25b: the second life starts with a CLEAN log — no inherited MISMATCH" \
  "log had $(log_events "$T25_ROOT" reused MISMATCH) MISMATCH events from the previous life" \
  test "$(log_events "$T25_ROOT" reused MISMATCH)" -eq 0
# Rotated, not deleted: the previous life is still auditable beside the new one.
assert_true "TC-OBS-25c: the previous life was ROTATED aside, not destroyed" \
  "no rotated log found in $T25_ROOT/log" \
  test -n "$(find "$T25_ROOT/log" -name 'reused.events.*.jsonl' 2>/dev/null)"
# Guard 2 keys its signature by id too, and a stale signature would make the new
# work's first check-in look like a repeat of the old work's last.
# ⛔ THIS ASSERTION WAS A MIRROR UNTIL THE PREDICATE ABOVE LEARNED TO SPEAK. ⛔
# Guard 2 is skipped when `done_when` prints nothing (a silent boolean has an
# identical failure signature every round, so feeding it one manufactures
# NO_PROGRESS — see TC-OBS-6g). The fixture used `test -f`, so no signature state
# was EVER created, so removing the cleanup left this green. It now uses a
# predicate that prints a compiler-style error, which is what makes the state
# exist and this assertion capable of failing.
assert_true "TC-OBS-25c2: the first life actually CREATED guard-2 state (else 25d proves nothing)" \
  "no progress state after a speaking predicate — 25d cannot falsify" \
  test "$T25_STATE_BEFORE" = "present"
assert_true "TC-OBS-25d: and the guard-2 signature state was cleared with it" \
  "stale progress state survived" \
  test ! -f "$T25_ROOT/state/reused.progress"

# ===========================================================================
# T26 — THE EXIT TRAP TOOK INTERPOLATED TEXT. `trap "rm -rf '$offsets_dir'" EXIT`
# spliced a TMPDIR-derived path into shell code that runs at watcher exit, so a
# TMPDIR containing a quote executed arbitrary commands. This is the `--worktree`
# defect in its sibling, found only because the fix for that one prompted a sweep.
# FALSIFYING EDIT: restore `trap "rm -rf '$offsets_dir'" EXIT` in cmd_watch() —
# TC-OBS-26a goes red with the marker created.
# ===========================================================================
echo ""
T26_ROOT="$WORK/t26"; mkdir -p "$T26_ROOT/active"
T26_MARKER="$WORK/t26-trap-marker"
rm -f "$T26_MARKER"
T26_EVIL="$WORK/t26tmp'; touch $T26_MARKER; #"
mkdir -p "$T26_EVIL"
TMPDIR="$T26_EVIL" OBSERVER_ROOT="$T26_ROOT" bash "$OBSERVE" watch \
  --tick-s 1 --idle-exit-s 3 --max-lifetime-s 30 >/dev/null 2>&1
assert_true "TC-OBS-26a: a hostile TMPDIR does not execute when the watcher exits" \
  "marker $T26_MARKER was created — the EXIT trap still interpolates" \
  test ! -f "$T26_MARKER"

# ===========================================================================
# T27 — THE SELF-ADVANCE CHECK WAS WEAKER THAN ITS OWN DOCUMENTATION. It read
# `if (( RB_RC == 0 )) && [[ hash != hash ]]`, so the comparison was SKIPPED
# whenever the second run exited non-zero: a stateful probe that changes output
# and fails once was accepted, and then produced a false delta=1 on every later
# check-in. The skill already claimed "rejects it if the output changed" — code
# weaker than its description is the overclaim class this branch corrected once.
# FALSIFYING EDIT: restore the `(( RB_RC == 0 )) &&` guard on the hash comparison
# in cmd_declare() — TC-OBS-27a goes red (the probe is accepted).
# ===========================================================================
echo ""
T27_ROOT="$WORK/t27"; mkdir -p "$T27_ROOT"
# A probe that changes its output every run AND exits non-zero on the second.
T27_PROBE="$WORK/t27-probe.sh"
{
  printf 'n=$(cat "$1" 2>/dev/null || echo 0)\n'
  printf 'n=$((n+1))\n'
  printf 'printf %%s "$n" > "$1"\n'
  printf 'printf "value-%%s\\\\n" "$n"\n'
  printf 'test "$n" != "2"\n'
} > "$T27_PROBE"
T27A_OUT=$(OBSERVER_ROOT="$T27_ROOT" bash "$OBSERVE" declare \
  --id stateful --intent "a probe that changes AND fails on its second run" \
  --done-when "test -f $WORK/t27-never" \
  --progress-probe "bash $T27_PROBE $WORK/t27-counter" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 2>&1)
T27A_RC=$?
assert_rc "TC-OBS-27a: a probe that is UNSTABLE across two runs is REJECTED" 2 "$T27A_RC" "$T27A_OUT"
assert_contains "TC-OBS-27b: the rejection names instability, not merely a changed output" \
  "UNSTABLE probe" "$T27A_OUT"

# ===========================================================================
# T28 — one_line HANDLED CR AND LF ONLY. VT, FF, NEL (U+0085), LINE SEPARATOR
# (U+2028) and PARAGRAPH SEPARATOR (U+2029) all survive `jq -r` into stdout,
# where a terminal or viewer may render any of them as a break — the same event
# forgery with a different byte. T18 tested LF only.
# FALSIFYING EDIT: remove the VT/FF/NEL/LS/PS replacements from one_line() —
# TC-OBS-28a goes red.
# ===========================================================================
echo ""
T28_ROOT="$WORK/t28"; mkdir -p "$T28_ROOT"
OBSERVER_ROOT="$T28_ROOT" bash "$OBSERVE" declare \
  --id separators --intent "a note built from every byte that renders as a break" \
  --done-when "test -f $WORK/t28-never" --progress-probe "printf 'stable\n'" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
OBSERVER_ROOT="$T28_ROOT" bash "$OBSERVE" checkin --id separators --claim stuck \
  --note "$(printf 'VT\013FF\014NEL\302\205LS\342\200\250PS\342\200\251end')" \
  > "$WORK/t28-checkin.out" 2>&1
T28_LEFTOVER=$(LC_ALL=C grep -c $'\013\|\014\|\302\205\|\342\200\250\|\342\200\251' "$WORK/t28-checkin.out" 2>/dev/null | tr -d ' ')
assert_true "TC-OBS-28a: no line-breaking byte survives into the notification stream" \
  "$T28_LEFTOVER line(s) still carry VT/FF/NEL/U+2028/U+2029" \
  test "$T28_LEFTOVER" = "0"
assert_contains "TC-OBS-28b: and the note is still readable — replaced, not deleted wholesale" \
  "note=VT FF NEL" "$(cat "$WORK/t28-checkin.out")"

# ⛔ SEPARATORS WERE ONLY HALF THE ATTACK. ⛔ Stripping line breaks stops forgery
# ACROSS lines; a terminal can be driven WITHIN one. Measured on a note before
# this: an ESC [ 2 K CR sequence reached stdout intact, and that sequence erases
# the line and redraws it, so `BEFORE<ESC>[2K<CR>FORGED-LINE` shows as `FORGED-LINE`
# alone. The same forgery the newline fix addressed, with a different byte.
# FALSIFYING EDIT: remove the `tr -d` control-byte strip from one_line() —
# TC-OBS-28c goes red with ESC and BEL still on stdout.
OBSERVER_ROOT="$T28_ROOT" bash "$OBSERVE" checkin --id separators --claim stuck \
  --note "$(printf 'BEFORE\033[2K\rFORGED-LINE\007')" \
  > "$WORK/t28-esc.out" 2>&1
T28_CTRL=$(LC_ALL=C tr -d '\011\012\040-\176' < "$WORK/t28-esc.out" 2>/dev/null | wc -c | tr -d ' ')
assert_true "TC-OBS-28c: no ESC, BEL or other control byte reaches the notification stream" \
  "$T28_CTRL control byte(s) survived — a terminal can still be driven within one line" \
  test "$T28_CTRL" -eq 0
# Stripped, not swallowed: the attempt must stay legible in the record.
assert_contains "TC-OBS-28d: and the attempt is still visible, not silently erased" \
  "BEFORE[2K FORGED-LINE" "$(cat "$WORK/t28-esc.out")"

# ===========================================================================
# T29 — A FALSE SUCCESS THROUGH A RACE. `close` re-runs `done_when` (up to
# PROBE_LIMIT_S), and a watcher can retire the declaration on its deadline inside
# that window. The postflight check then called `decl_get` on the now-absent
# active file, got an empty string, failed its numeric test and RETURNED CLEAN —
# so `close --outcome shipped` emitted CLOSED, exit 0, AFTER the deadline.
# Measured before the fix: a retirement two seconds into a six-second `done_when`
# produced `CLOSED racer outcome=shipped` and one CLOSED event in the log.
#
# This is the single thing the mechanism exists to make impossible, so it is
# guarded twice: the postflight now treats a MISSING active file as "someone else
# retired this", and the CLOSED emit is gated on winning the atomic claim — the
# same rename that makes DEADLINE single-fire.
# ⛔ 29a AND 29b ARE PROPERTY ASSERTIONS, NOT FALSIFIERS FOR EITHER GUARD, AND
# THAT IS MEASURED RATHER THAN ASSUMED. ⛔ The two guards are redundant for this
# scenario, so reverting EITHER alone leaves the suite green:
#   · remove the missing-file branch  -> the claim gate refuses (rc=1)  -> green
#   · remove the claim gate           -> the postflight refuses (rc=3)  -> green
#   · remove BOTH                     -> CLOSED racer outcome=shipped, rc=0, RED
# That is the right shape for the property the mechanism rests on, but it means
# neither mechanism is individually pinned by 29a/29b. TC-OBS-29e pins the
# postflight by asserting the exit code only IT produces.
#
# The claim gate cannot be isolated by this suite: it only acts in the window
# between the postflight and the emit, which is microseconds and not reachable
# without a test seam in production code. Recorded as a known gap rather than
# left to look like coverage.
# FALSIFYING EDITS: remove BOTH guards -> 29a/29b go red. Remove only the
# missing-file branch from enforce_deadline() -> 29e goes red.
# ===========================================================================
echo ""
T29_ROOT="$WORK/t29"; mkdir -p "$T29_ROOT"
OBSERVER_ROOT="$T29_ROOT" bash "$OBSERVE" declare \
  --id racer --intent "a close racing a watcher's retirement" \
  --done-when "sleep 6; test -f $WORK/t29-marker" --progress-probe "printf 'stable\n'" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
: > "$WORK/t29-marker"    # done_when will be TRUE — so only the race can refuse it
# Stand in for the watcher: retire the declaration while `close` is inside its
# six-second predicate. Doing it by hand rather than with a real watcher makes the
# collision certain instead of likely — the same reason T14 backdates a deadline.
( sleep 2; mv "$T29_ROOT/active/racer.json" "$T29_ROOT/retired/racer.json" 2>/dev/null ) &
T29_OUT=$(OBSERVER_ROOT="$T29_ROOT" bash "$OBSERVE" close --id racer --outcome shipped 2>&1)
T29_RC=$?
wait
assert_true "TC-OBS-29a: a close whose declaration was retired mid-flight does not succeed" \
  "close returned $T29_RC — it recorded an outcome after another process ended the task" \
  test "$T29_RC" -ne 0
assert_true "TC-OBS-29b: and NO CLOSED event entered the record" \
  "log had $(log_events "$T29_ROOT" racer CLOSED) CLOSED events" \
  test "$(log_events "$T29_ROOT" racer CLOSED)" -eq 0
# The two guards return DIFFERENT codes, which is what makes this one isolating:
# the postflight's missing-file branch returns 3, the claim gate returns 1. Pin 3.
assert_rc "TC-OBS-29e: the refusal came from the deadline postflight, not only the claim backstop" \
  3 "$T29_RC" "$T29_OUT"

# The mirror image, and it matters as much: an ordinary close must still work.
# Without this pair, refusing every close would pass the assertions above.
T29C_ROOT="$WORK/t29c"; mkdir -p "$T29C_ROOT"
OBSERVER_ROOT="$T29C_ROOT" bash "$OBSERVE" declare \
  --id clean --intent "an uncontended close still records its outcome" \
  --done-when "test -f $WORK/t29c-marker" --progress-probe "printf 'stable\n'" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
: > "$WORK/t29c-marker"
T29C_OUT=$(OBSERVER_ROOT="$T29C_ROOT" bash "$OBSERVE" close --id clean --outcome shipped 2>&1)
T29C_RC=$?
assert_rc "TC-OBS-29c: an uncontended close --outcome shipped still succeeds" 0 "$T29C_RC" "$T29C_OUT"
assert_contains "TC-OBS-29d: and still records CLOSED then RETIRED" " RETIRED clean " "$T29C_OUT"

# ===========================================================================
# T30 — A REDECLARE DURING A DEADLINE SNAPSHOT WROTE INTO THE NEW LIFECYCLE'S LOG.
# `rotate_prior_lifecycle` (T25) fixed the STALE half of id reuse. This is the
# CONCURRENT half: a watcher claims a declaration, spends seconds on its snapshot,
# the id is redeclared in that window, and the watcher appends DEADLINE and
# RETIRED into a log belonging to work it never observed. Measured before the fix:
# the new lifecycle's log went from 1 line (its own DECLARED) to 3.
#
# The skill claimed "nothing carries over" — true of state, false of concurrent
# writes — so this is a documented guarantee that was not one.
# FALSIFYING EDIT: delete the `lifecycle_is_current` check before the DEADLINE
# emit in watch_deadline() — TC-OBS-30a goes red with DEADLINE and RETIRED in the
# new lifecycle's log.
# ===========================================================================
echo ""
T30_ROOT="$WORK/t30"; mkdir -p "$T30_ROOT"
OBSERVER_ROOT="$T30_ROOT" bash "$OBSERVE" declare \
  --id lifecycle --intent "the first life, which will be redeclared mid-snapshot" \
  --done-when "test -f $WORK/t30-never" --progress-probe "printf 'stable\n'" \
  --checkin-every-s 3600 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
# Overdue, with probes slow enough that the redeclare lands inside the snapshot.
T30_TMP=$(mktemp "$T30_ROOT/t30.XXXXXX")
jq --argjson n "$(date +%s)" \
   '.deadline_at = ($n - 100) | .progress_probe = "sleep 20; printf x" | .done_when = "sleep 20"' \
   "$T30_ROOT/active/lifecycle.json" > "$T30_TMP" && mv -f "$T30_TMP" "$T30_ROOT/active/lifecycle.json"
OBSERVER_ROOT="$T30_ROOT" bash "$OBSERVE" watch --tick-s 1 --idle-exit-s 600 --max-lifetime-s 120 \
  > "$WORK/t30-watch.out" 2>&1 &
T30_PID=$!
WATCH_PIDS+=($T30_PID)
sleep 4    # the watcher has claimed and is inside its snapshot
OBSERVER_ROOT="$T30_ROOT" bash "$OBSERVE" declare \
  --id lifecycle --intent "the SECOND life, which must keep its own log" \
  --done-when "test -f $WORK/t30-marker2" --progress-probe "printf 'stable2\n'" \
  --checkin-every-s 3600 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
# Close the second life while the first life is still finishing its snapshot.
# This is the missing-file case: active/ is empty, but retired/ contains a
# different lifecycle. lifecycle_is_current must inspect that retired record,
# not treat the absent active record as proof that nobody took the id.
: > "$WORK/t30-marker2"
OBSERVER_ROOT="$T30_ROOT" bash "$OBSERVE" close --id lifecycle --outcome shipped \
  >/dev/null 2>&1
T30_WAIT=$(( $(date +%s) + 90 ))
while :; do
  kill -0 "$T30_PID" 2>/dev/null || break
  (( $(date +%s) >= T30_WAIT )) && break
  sleep 2
done
kill -KILL "$T30_PID" 2>/dev/null
# The whole point: the new lifecycle's log must contain ONLY its own DECLARED.
assert_true "TC-OBS-30a: the old snapshot did not write into the new lifecycle's log" \
  "new log holds: $(jq -r '.event' "$T30_ROOT/log/lifecycle.events.jsonl" 2>/dev/null | tr '\n' ' ')" \
  test "$(log_events "$T30_ROOT" lifecycle DEADLINE)" -eq 0
# Nothing is lost — the orphaned snapshot is still auditable, just elsewhere.
assert_true "TC-OBS-30b: and that snapshot was kept, in an orphan log" \
  "no orphan log under $T30_ROOT/log" \
  test -n "$(find "$T30_ROOT/log" -name 'lifecycle.events.orphaned-*.jsonl' 2>/dev/null)"
# The second life was deliberately closed before the old snapshot finished, so
# its terminal record must remain exactly one RETIRED event and stay retired.
assert_true "TC-OBS-30c: the closed second lifecycle was not reopened" \
  "retired lifecycle was reopened or missing" \
  test -f "$T30_ROOT/retired/lifecycle.json"
assert_true "TC-OBS-30d: the old snapshot did not append a second RETIRED event" \
  "retired log has $(log_events "$T30_ROOT" lifecycle RETIRED) RETIRED events" \
  test "$(log_events "$T30_ROOT" lifecycle RETIRED)" -eq 1

# ===========================================================================
# T31 — A CLOSE THAT COULD NOT WRITE ITS RECORD REPORTED SUCCESS. No race needed:
# any failed append — full disk, read-only volume, permissions accident — and
# `close` returned 0 with nothing durable, having already claimed the declaration
# out of active/. Measured with the log made unwritable:
#     close --outcome shipped -> rc=0, CLOSED events on disk: 0, task gone
# Third time this gate has reported a success that did not happen. Refusing while
# the predicate is false is worth nothing if it can ACCEPT while the record fails.
#
# The two failures must stay DISTINGUISHABLE — 1 means "refused, and the reason is
# on the record", 4 means "there is no record". Same exit code for both would make
# diagnosis guesswork.
# FALSIFYING EDIT: drop the `if !` around the CLOSED emit in cmd_close() and
# `return 0` unconditionally — TC-OBS-31a and 31c go red.
# ===========================================================================
echo ""
T31_ROOT="$WORK/t31"; mkdir -p "$T31_ROOT"
OBSERVER_ROOT="$T31_ROOT" bash "$OBSERVE" declare \
  --id unwritable --intent "a close whose terminal record cannot be written" \
  --done-when "test -f $WORK/t31-marker" --progress-probe "printf 'stable\n'" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
: > "$WORK/t31-marker"          # done_when TRUE — only the failed append can refuse
chmod 444 "$T31_ROOT/log/unwritable.events.jsonl" 2>/dev/null
T31_OUT=$(OBSERVER_ROOT="$T31_ROOT" bash "$OBSERVE" close --id unwritable --outcome shipped 2>&1)
T31_RC=$?
chmod 644 "$T31_ROOT/log/unwritable.events.jsonl" 2>/dev/null
assert_rc "TC-OBS-31a: a close that cannot write its record does NOT report success" 4 "$T31_RC" "$T31_OUT"
assert_true "TC-OBS-31b: and no CLOSED event is on disk to disagree with that" \
  "log had $(log_events "$T31_ROOT" unwritable CLOSED) CLOSED events" \
  test "$(log_events "$T31_ROOT" unwritable CLOSED)" -eq 0
# The task must not vanish: it was claimed out of active/ before the emit, so
# without a restore it would disappear from observation with no outcome anywhere.
assert_true "TC-OBS-31c: the declaration is restored, not left silently retired" \
  "declaration did not come back to active/" \
  test -f "$T31_ROOT/active/unwritable.json"

# ⛔ THE DIAGNOSES MUST NOT COLLIDE. ⛔ A predicate refusal and a write failure are
# opposite situations and used to be indistinguishable (0 vs 0).
T31D_ROOT="$WORK/t31d"; mkdir -p "$T31D_ROOT"
OBSERVER_ROOT="$T31D_ROOT" bash "$OBSERVE" declare \
  --id refused --intent "a close refused on its predicate, with the record intact" \
  --done-when "test -f $WORK/t31d-never" --progress-probe "printf 'stable\n'" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
OBSERVER_ROOT="$T31D_ROOT" bash "$OBSERVE" close --id refused --outcome shipped >/dev/null 2>&1
T31D_RC=$?
assert_rc "TC-OBS-31d: a predicate refusal still exits 1, not 4" 1 "$T31D_RC"
# And the mirror: an ordinary close must still succeed, or refusing everything
# would satisfy every assertion above.
T31E_ROOT="$WORK/t31e"; mkdir -p "$T31E_ROOT"
OBSERVER_ROOT="$T31E_ROOT" bash "$OBSERVE" declare \
  --id fine --intent "an ordinary close" --done-when "test -f $WORK/t31e-marker" \
  --progress-probe "printf 'stable\n'" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
: > "$WORK/t31e-marker"
OBSERVER_ROOT="$T31E_ROOT" bash "$OBSERVE" close --id fine --outcome shipped >/dev/null 2>&1
assert_rc "TC-OBS-31e: an ordinary close still exits 0" 0 "$?"

# ===========================================================================
# T32 — THE EMIT-FAILURE RESTORE COULD REOPEN A CLOSED LIFECYCLE. The restore
# asked `lifecycle_is_current`, which answers "has anyone taken this id?" and
# returns TRUE when NO active file exists — precisely the state a newer lifecycle
# leaves behind when it is CLOSED. Measured: L2 declared and closed as `shipped`,
# then L1's failed DEADLINE emit moved L2's retired JSON back into active/,
# presenting finished, shipped work as still running.
#
# The right question is "is the file I am about to move back the one I claimed?".
# FALSIFYING EDIT: change restore_claimed_declaration()'s lifecycle comparison
# back to `lifecycle_is_current "$task_id" "$mine"` — TC-OBS-32a goes red with
# L2's declaration reopened.
# ===========================================================================
echo ""
T32_ROOT="$WORK/t32"; mkdir -p "$T32_ROOT"
OBSERVER_ROOT="$T32_ROOT" bash "$OBSERVE" declare \
  --id relived --intent "L1" --done-when "test -f $WORK/t32-never" \
  --progress-probe "printf 'stable\n'" \
  --checkin-every-s 3600 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
# ⛔ THE SNAPSHOT IS MADE LONG ON PURPOSE, AND ONLY done_when IS SLOW. ⛔ The
# restore path this test drives runs ONLY if the log becomes unwritable BEFORE the
# watcher emits its DEADLINE, and the setup below (declare L2, close L2, chmod)
# has to fit inside the snapshot. The first version raced that: a 3s probe budget
# gave a snapshot of about 8s against a setup of about 7s. Measured here it passed
# with a ONE-TO-TWO SECOND margin; measured with 4s added to the setup it failed
# exactly as a reviewer saw it — 32b red, 32a green FOR THE WRONG REASON.
# A fast progress probe plus a done_when bounded at the default 30s puts the emit
# ~31s after the claim, so the setup has ~20s of slack instead of two.
T32_TMP=$(mktemp "$T32_ROOT/t32.XXXXXX")
jq --argjson n "$(date +%s)" \
   '.deadline_at = ($n - 100) | .progress_probe = "printf x" | .done_when = "sleep 300"' \
   "$T32_ROOT/active/relived.json" > "$T32_TMP" && mv -f "$T32_TMP" "$T32_ROOT/active/relived.json"
OBSERVER_ROOT="$T32_ROOT" bash "$OBSERVE" watch \
  --tick-s 1 --idle-exit-s 600 --max-lifetime-s 120 \
  > "$WORK/t32-watch.out" 2>&1 &
T32_PID=$!
WATCH_PIDS+=($T32_PID)

# ⛔ WAIT FOR THE OBSERVABLE, NOT FOR A GUESS. ⛔ `sleep 3` ASSUMED the watcher had
# claimed L1 by then; if it had not, the whole ordering this test depends on was
# wrong and the assertions below reported on something else entirely. The claim is
# observable — it renames the declaration out of active/ — so poll for that, with
# a deadline, exactly like every other wait in this suite.
T32_CLAIM_BY=$(( $(date +%s) + 30 ))
while [[ -f "$T32_ROOT/active/relived.json" ]]; do
  (( $(date +%s) >= T32_CLAIM_BY )) && break
  sleep 1
done
assert_true "TC-OBS-32z: the watcher claimed L1 before the redeclare (the ordering this test needs)" \
  "L1 was never claimed — everything below would be measuring a different scenario" \
  test ! -f "$T32_ROOT/active/relived.json"
OBSERVER_ROOT="$T32_ROOT" bash "$OBSERVE" declare \
  --id relived --intent "L2" --done-when "test -f $WORK/t32-marker2" \
  --progress-probe "printf 'stable2\n'" \
  --checkin-every-s 3600 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
: > "$WORK/t32-marker2"
OBSERVER_ROOT="$T32_ROOT" bash "$OBSERVE" close --id relived --outcome shipped >/dev/null 2>&1
# Force L1's DEADLINE append to fail, which is what triggers the restore path.
chmod 444 "$T32_ROOT/log/relived.events.jsonl" 2>/dev/null
# Poll for the MESSAGE with a deadline, rather than waiting for the watcher to
# exit and hoping the message arrived first.
T32_WAIT=$(( $(date +%s) + 90 ))
while :; do
  grep -q 'not the one this pass claimed' "$WORK/t32-watch.out" 2>/dev/null && break
  kill -0 "$T32_PID" 2>/dev/null || break
  (( $(date +%s) >= T32_WAIT )) && break
  sleep 1
done
kill -KILL "$T32_PID" 2>/dev/null
chmod 644 "$T32_ROOT/log/relived.events.jsonl" 2>/dev/null
# The strengthened lifecycle check routes this stale snapshot to an orphan log
# before emit_event runs, so the restore-on-append-failure branch is correctly
# not entered. The observable contract here is that the old snapshot is kept
# separate from the closed newer lifecycle.
assert_contains "TC-OBS-32b: the stale snapshot reports the redeclaration" \
  "redeclared while its deadline snapshot was running" "$(cat "$WORK/t32-watch.out" 2>/dev/null)"
assert_true "TC-OBS-32c: the stale snapshot was routed to an orphan log" \
  "no orphan log under $T32_ROOT/log" \
  test -n "$(find "$T32_ROOT/log" -name 'relived.events.orphaned-*.jsonl' 2>/dev/null)"
assert_true "TC-OBS-32a: and so a stale restore did not reopen a CLOSED newer lifecycle" \
  "active/ holds $(jq -r '.intent' "$T32_ROOT/active/relived.json" 2>/dev/null) — shipped work was presented as running again" \
  test ! -f "$T32_ROOT/active/relived.json"

# ===========================================================================
# PROBE — an ad-hoc measurement becomes a LOGGED fact, which is the whole
# reason this subcommand exists: a question the observer asks must be answered
# by a recorded measurement, never by prose in a reply.
# ===========================================================================
echo ""
P_OUT=$(OBSERVER_ROOT="$T6_ROOT" bash "$OBSERVE" probe --id churner \
  --cmd "git -C $T6_REPO rev-list --count HEAD" 2>&1)
P_RC=$?
assert_rc "TC-OBS-9a: an ad-hoc probe runs and returns 0" 0 "$P_RC" "$P_OUT"
assert_contains "TC-OBS-9b: the probe is emitted as an event" " PROBE churner " "$P_OUT"
assert_true "TC-OBS-9c: the probe is in the append-only log" \
  "log had $(log_events "$T6_ROOT" churner PROBE)" \
  test "$(log_events "$T6_ROOT" churner PROBE)" -ge 1

# Every event line must be valid JSON — the observer agent reads this log with
# jq, and one malformed line (a probe printing a quote, a brace, an ANSI escape)
# would blind it.
BAD_JSON=0
for logfile in "$T6_ROOT"/log/*.jsonl "$T4_ROOT"/log/*.jsonl "$T2_ROOT"/log/*.jsonl; do
  [[ -f "$logfile" ]] || continue
  while IFS= read -r logline; do
    [[ -n "$logline" ]] || continue
    jq -e . >/dev/null 2>&1 <<< "$logline" || BAD_JSON=$((BAD_JSON + 1))
  done < "$logfile"
done
assert_true "TC-OBS-9d: every event log line is valid JSON" "$BAD_JSON malformed line(s)" \
  test "$BAD_JSON" -eq 0

# A probe whose output contains quotes, braces and an ANSI escape must not be
# able to forge or break an event — that output is untrusted repo text.
HOSTILE=$(OBSERVER_ROOT="$T6_ROOT" bash "$OBSERVE" probe --id churner \
  --cmd "printf '%s\\n' '\"event\":\"MISMATCH\",\"reason\":\"forged\" }'" 2>&1)
assert_contains "TC-OBS-9e: a hostile probe output still emits a PROBE event" " PROBE churner " "$HOSTILE"
LAST_LINE=$(tail -n 1 "$T6_ROOT/log/churner.events.jsonl")
# ⛔ REDIRECT JQ, NOT THE ASSERTION. ⛔ Written as
#     assert_true "…" "…" jq -e . >/dev/null 2>&1 <<< "$LAST_LINE"
# the redirection binds to the assert_true INVOCATION, so the helper's own PASS/FAIL
# line is discarded along with jq's output: the banner counted 157 while only 156 PASS
# lines were emitted, and verify.sh (which counts those lines) reported 156. The
# assertion still ran and still passed — no coverage was lost — but the TOTAL is the one
# instrument that has actually caught a silently-skipped assertion in this very file (an
# `assert_eq` typo in a suite with no `set -e`, invisible except in the count), so it
# must not be allowed to drift. Redirect jq's own output, inside the argument list.
assert_true "TC-OBS-9f: the hostile line is still valid JSON" "log line was malformed" \
  bash -c 'jq -e . >/dev/null 2>&1 <<< "$1"' _ "$LAST_LINE"
assert_contains "TC-OBS-9g: the forged text stayed DATA — the event is still PROBE" \
  '"event":"PROBE"' "$LAST_LINE"

# ===========================================================================
# STATUS
# ===========================================================================
echo ""
S_OUT=$(OBSERVER_ROOT="$T6_ROOT" bash "$OBSERVE" status 2>&1)
S_RC=$?
assert_rc "TC-OBS-10a: status runs" 0 "$S_RC" "$S_OUT"
assert_contains "TC-OBS-10b: status lists the active task" "churner" "$S_OUT"
assert_contains "TC-OBS-10c: status shows the round count against its bound" "/3" "$S_OUT"

EMPTY_ROOT="$WORK/empty"; mkdir -p "$EMPTY_ROOT"
E_OUT=$(OBSERVER_ROOT="$EMPTY_ROOT" bash "$OBSERVE" status 2>&1)
assert_contains "TC-OBS-10d: status says so when nothing is being observed" \
  "(no active declarations)" "$E_OUT"


# ===========================================================================
# T33 — A DECLARE THAT COULD NOT WRITE ITS `DECLARED` RECORD REPORTED SUCCESS,
# AND LEFT THE DECLARATION BEHIND. Same class as T31 (close) and the `probe`
# append, and the last unchecked `emit_event` in the file: `cmd_declare` installed
# the declaration into active/ and then called `emit_event … DECLARED …` without
# looking at the result, so an unwritable or full log produced
#     declare -> rc=0, DECLARED events on disk: 0, active/<id>.json PRESENT
# — a task under observation whose own log has no record that it was ever
# declared. State and record must not be able to disagree, so the fix REMOVES the
# declaration it just installed and reports `RECORD_FAILED_RC` (4).
#
# ⛔ 4 IS THE RIGHT CODE HERE, AND THE REASON IS NARROW. ⛔ Exit 4 is documented as
# "the operation was performed but there is NO RECORD". On this path nothing
# durable was written AND the declaration is rolled back, so "there is no record"
# is exactly true — this is not another instance of issue #176 (a 4 returned where
# a record HAD been written).
#
# FALSIFYING EDIT: drop the `if !` around the DECLARED emit in cmd_declare() and
# `return 0` unconditionally — TC-OBS-33a and 33c go red.
# ===========================================================================
echo ""
T33_ROOT="$WORK/t33"; mkdir -p "$T33_ROOT/log"
# ⛔ THE T31/T32 FIXTURE DOES NOT WORK HERE, AND IT FAILS *SILENTLY*. ⛔ Those
# tests make the log FILE read-only (`chmod 444`), which is right for `close` and
# `checkin` — they append to a log that already exists. `declare` does not: it
# ROTATES a pre-existing log out of the way (reuse of an id is legitimate) and
# then appends to a FRESH file, which it creates with ordinary permissions. So a
# `chmod 444` file fixture here produces a perfectly successful append and the
# test asserts nothing. Measured before this comment existed: rc=0 with the
# DECLARED line present on disk. The DIRECTORY is what has to be unwritable, so
# neither the rotation nor the create can succeed.
chmod 555 "$T33_ROOT/log" 2>/dev/null
T33_OUT=$(OBSERVER_ROOT="$T33_ROOT" bash "$OBSERVE" declare \
  --id norecord --intent "a declare whose DECLARED record cannot be written" \
  --done-when "test -f $WORK/t33-marker" --progress-probe "printf 'stable\n'" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 2>&1)
T33_RC=$?
chmod 755 "$T33_ROOT/log" 2>/dev/null
assert_rc "TC-OBS-33a: a declare that cannot write its DECLARED record does NOT report success" \
  4 "$T33_RC" "$T33_OUT"
# FIXTURE VALIDITY, not the fix: if the append had actually succeeded, 33a and 33c
# would be asserting nothing at all. This is the check that the log really was
# unwritable for this user (it is vacuous under root, exactly as T31/T32 are).
assert_true "TC-OBS-33b: (fixture) the append really did fail — no DECLARED event on disk" \
  "log had $(log_events "$T33_ROOT" norecord DECLARED) DECLARED events" \
  test "$(log_events "$T33_ROOT" norecord DECLARED)" -eq 0
assert_true "TC-OBS-33c: and the declaration is NOT left installed with no record behind it" \
  "active/norecord.json survived a declare that recorded nothing" \
  test ! -f "$T33_ROOT/active/norecord.json"

# ===========================================================================
# T34 — A CHECK-IN THAT COULD NOT RECORD ITS `CLAIM` REPORTED SUCCESS. The CLAIM
# is the ONE thing the agent contributes and it is emitted FIRST, deliberately, so
# the log shows what was asserted and then what was true. That emit was unchecked
# while both terminal paths in `close` were checked, so an unwritable log gave
#     checkin --claim working -> rc=0, CLAIM events on disk: 0, checkins 0 -> 1
# — a check-in that counted, reset the silence timer, and left no trace of the
# claim it was supposed to pin. Reporting 4 here means "no record was written",
# which is what happened.
#
# FALSIFYING EDIT: drop the `if !` around the CLAIM emit in cmd_checkin() —
# TC-OBS-34a and 34c go red.
# ===========================================================================
echo ""
T34_ROOT="$WORK/t34"; mkdir -p "$T34_ROOT"
T34_REPO=$(make_repo "$WORK/t34-repo")
OBSERVER_ROOT="$T34_ROOT" bash "$OBSERVE" declare \
  --id claimless --intent "a check-in whose CLAIM record cannot be written" \
  --done-when "test -f $WORK/t34-marker" \
  --progress-probe "git -C $T34_REPO rev-parse HEAD" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
# A REAL delta, so nothing but the failed append can make this check-in non-clean:
# `working` with a moved probe is the case that returns 0 today.
advance_repo "$T34_REPO"
chmod 444 "$T34_ROOT/log/claimless.events.jsonl" 2>/dev/null
T34_OUT=$(OBSERVER_ROOT="$T34_ROOT" bash "$OBSERVE" checkin --id claimless --claim working 2>&1)
T34_RC=$?
chmod 644 "$T34_ROOT/log/claimless.events.jsonl" 2>/dev/null
assert_rc "TC-OBS-34a: a check-in that cannot record its CLAIM does NOT report success" \
  4 "$T34_RC" "$T34_OUT"
assert_true "TC-OBS-34b: (fixture) the append really did fail — no CLAIM event on disk" \
  "log had $(log_events "$T34_ROOT" claimless CLAIM) CLAIM events" \
  test "$(log_events "$T34_ROOT" claimless CLAIM)" -eq 0
# The snapshot must not be persisted either: a check-in nobody can find in the log
# must not have counted as one, or the silence timer restarts on an invisible event.
assert_true "TC-OBS-34c: and the unrecorded check-in did not count — checkins is still 0" \
  "checkins was $(jq -r '.checkins' "$T34_ROOT/active/claimless.json" 2>/dev/null)" \
  test "$(jq -r '.checkins' "$T34_ROOT/active/claimless.json" 2>/dev/null)" -eq 0


# ===========================================================================
# T35 — THE VERIFIER HAD NO BOUND ON THE SUITE IT RUNS. `scripts/verify.sh` ran
# this file as a bare command substitution:
#     OBSERVE_TEST_OUTPUT=$(bash "$TEST_OBSERVE_SCRIPT" 2>&1)
# so the ONE failure this suite exists to catch — a regression to an unbounded
# wait — HANGS THE VERIFIER instead of being reported by it. Incident 2 ran
# eleven hours; a verifier that inherits that wait is not a check, it is a second
# copy of the bug.
#
# `timeout`/`gtimeout` do not exist on this machine, so verify.sh now carries
# `run_bounded_capture` — the same shape as observe.sh's `run_bounded`: fork the
# child into its own process GROUP, poll a `date +%s` deadline, then TERM and KILL
# THE GROUP (a forking child survives a kill aimed only at the foreground child).
#
# ⛔ A TIMEOUT MUST NOT LOOK LIKE A TEST FAILURE. ⛔ "the suite hung" and "a test
# failed" are different defects with different fixes, so the helper reports
# `RBC_TIMED_OUT=1` separately from the exit code and verify.sh prints a distinct
# EXCEEDED-ITS-BOUND message.
#
# The production limit is 1800s, sized from a TIMED run (684s) rather than from
# this file's own prose — the first attempt used 600s taken from the stale
# "~4 minutes" claim above, which would have failed a healthy run. The case below
# uses a 3s bound so it costs seconds, not half an hour.
#
# WHY THIS TEST LIVES HERE: verify.sh has no test harness of its own. The helper
# is therefore exercised directly, by sourcing verify.sh with `VERIFY_LIB_ONLY=1`
# — a seam that defines the helpers and returns before any check runs. Sourcing
# happens inside a child `bash -c` so verify.sh's own shell settings cannot leak
# into this suite (which deliberately has no `set -e`).
#
# FALSIFYING EDIT: delete the timeout arm from run_bounded_capture, or restore the
# bare `$(bash "$TEST_OBSERVE_SCRIPT" 2>&1)` in verify.sh — TC-OBS-35a/b/c go red
# (35a/b immediately; 35c by hanging, which is the point).
# ===========================================================================
echo ""
T35_VERIFY="$SCRIPT_DIR/verify.sh"
# The stub forks a long sleep AND waits on it, so this also proves the GROUP kill:
# killing only the foreground child would leave the backgrounded sleep alive.
T35_STUB="$WORK/t35-stub.sh"
T35_PIDFILE="$WORK/t35-child.pid"
T35_SLEEP_MARK=$(( 900000 + ($$ % 40000) ))
cat > "$T35_STUB" <<STUBEOF
#!/usr/bin/env bash
sleep $T35_SLEEP_MARK &
printf '%s' "\$!" > "$T35_PIDFILE"
wait
STUBEOF
T35_LIB='VERIFY_LIB_ONLY=1 . "$1" || exit 97'

T35_START=$(date +%s)
T35_OUT=$(bash -c "$T35_LIB"'; run_bounded_capture 3 bash "$2"; printf "rc=%s timed_out=%s\n" "$RBC_RC" "$RBC_TIMED_OUT"' \
  _ "$T35_VERIFY" "$T35_STUB" 2>&1)
T35_ELAPSED=$(( $(date +%s) - T35_START ))
assert_contains "TC-OBS-35a: an over-running suite is reported as EXCEEDING ITS BOUND, not as a failure" \
  "timed_out=1" "$T35_OUT"
assert_contains "TC-OBS-35b: and it carries the conventional timeout exit code" "rc=124" "$T35_OUT"
# 3s bound + the group-kill grace: anything near 90 means the bound did not fire.
assert_true "TC-OBS-35c: and the runner returned inside its own bound (${T35_ELAPSED}s elapsed)" \
  "took ${T35_ELAPSED}s for a 3s bound — the bound did not fire" \
  test "$T35_ELAPSED" -lt 20
# The FORKED grandchild must be gone too — this is the half a foreground-only kill
# misses, and the half observe.sh's kill_probe_group exists for.
sleep 1
T35_CHILD=$(cat "$T35_PIDFILE" 2>/dev/null)
assert_true "TC-OBS-35d: the forked grandchild was killed too — the GROUP, not just the child" \
  "pid ${T35_CHILD:-?} was still alive after the bound fired" \
  bash -c '[[ -z "$2" ]] || ! pgrep -f "[s]leep $1" 2>/dev/null | grep -qx "$2"' _ \
    "$T35_SLEEP_MARK" "$T35_CHILD"

# CONTROL — without it, a helper that reported EVERYTHING as a timeout would pass
# the four assertions above. A command finishing inside the bound must keep its
# own exit code and its own output, and must NOT be flagged as a timeout.
T35_FAST=$(bash -c "$T35_LIB"'; run_bounded_capture 30 bash -c "printf hello; exit 7"; printf "rc=%s timed_out=%s out=[%s]\n" "$RBC_RC" "$RBC_TIMED_OUT" "$RBC_OUT"' \
  _ "$T35_VERIFY" 2>&1)
assert_contains "TC-OBS-35e: a command that finishes inside the bound keeps its exit code" "rc=7" "$T35_FAST"
assert_contains "TC-OBS-35f: and its output is captured, not discarded" "out=[hello]" "$T35_FAST"
assert_contains "TC-OBS-35g: and it is NOT reported as a timeout" "timed_out=0" "$T35_FAST"
T35_FAIL=$(bash -c "$T35_LIB"'; run_bounded_capture 30 bash -c "exit 23"; printf "rc=%s timed_out=%s\n" "$RBC_RC" "$RBC_TIMED_OUT"' \
  _ "$T35_VERIFY" 2>&1)
assert_contains "TC-OBS-35i: a nonzero child exit is recorded instead of misreported as a timeout" "rc=23 timed_out=0" "$T35_FAIL"
assert_true "TC-OBS-35h: the bounded runner sweeps the captured process group, not a reused pid" \
  "run_bounded_capture still passes the finished child pid to the group sweeper" \
  bash -c '! grep -Eq '\''_rbc_kill_group "\$pid"'\'' "$1"' _ "$T35_VERIFY"

# ==========================================================================
# T36 — EVENT NOTIFICATION IS BEST-EFFORT AFTER DURABLE APPEND. The event log is
# the record; stdout is only the human notification stream. If a caller closes
# stdout, a successful append must still make the operation succeed. Previously
# the final notification printf became emit_event's return status, so callers
# treated an already-recorded event as a persistence failure and took rollback
# paths against a durable log.
# ==========================================================================
echo ""
T36_ROOT="$WORK/t36"; mkdir -p "$T36_ROOT"
T36_REPO=$(make_repo "$WORK/t36-repo")
OBSERVER_ROOT="$T36_ROOT" bash "$OBSERVE" declare \
  --id closed-stdout --intent "an event whose notification stream is closed" \
  --done-when "test -f $WORK/t36-marker" \
  --progress-probe "git -C $T36_REPO rev-parse HEAD" \
  --checkin-every-s 60 --hard-deadline-s 600 --max-rounds 5 >/dev/null 2>&1
advance_repo "$T36_REPO"
T36_ERR="$WORK/t36.err"
if OBSERVER_ROOT="$T36_ROOT" bash "$OBSERVE" checkin --id closed-stdout --claim working \
  1>&- 2>"$T36_ERR"; then
  T36_RC=0
else
  T36_RC=$?
fi
assert_rc "TC-OBS-36a: a durable check-in succeeds when stdout is closed" 0 "$T36_RC" \
  "$(cat "$T36_ERR" 2>/dev/null)"
assert_true "TC-OBS-36b: the CLAIM was still appended before notification failed" \
  "no CLAIM event was recorded" \
  test "$(log_events "$T36_ROOT" closed-stdout CLAIM)" -eq 1

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "=== observe.sh: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
  echo ""
  echo "Failures:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - $t"
  done
  exit 1
fi
exit 0
