#!/usr/bin/env bash
# test-loop-progress-signature.sh — Unit tests for scripts/loop-progress-signature.sh.
#
# The script under test is guard 2 of the three loop guards (the no-progress
# detector). Its whole value rests on two claims that are easy to assert and
# easy to get wrong, so each test below names the EXACT edit to the production
# script that makes it fail — an assertion nobody can falsify is not a test:
#
#   CLAIM A — churn immunity. Two iterations that fail the same gates with the
#             same error are the SAME signature even when their output differs
#             in timestamps, durations, absolute paths, ids and pids. This is
#             what an mtime-based detector gets wrong: a loop rewriting the same
#             failing file looks busy forever.
#   CLAIM B — real change is not swallowed. A different diagnostic code, or a
#             different set of failing gates, is a NEW signature and resets the
#             run length. Over-normalising would stop a loop that was moving.
#
# Usage: ./scripts/test-loop-progress-signature.sh
# Exits 0 if all tests pass, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DETECTOR="$SCRIPT_DIR/loop-progress-signature.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# run <state-file> <failing-gates> <threshold> [<output-file>]
# Sets RC and OUT.
run() {
  local state="$1" gates="$2" threshold="$3" outfile="${4-}"
  if [[ -n "$outfile" ]]; then
    OUT=$(bash "$DETECTOR" --state "$state" --failing-gates "$gates" --threshold "$threshold" --output "$outfile" 2>&1)
  else
    OUT=$(bash "$DETECTOR" --state "$state" --failing-gates "$gates" --threshold "$threshold" 2>&1)
  fi
  RC=$?
}

assert_rc() {
  local name="$1" want="$2"
  if [[ "$RC" -eq "$want" ]]; then
    PASS=$((PASS + 1)); echo "  PASS: $name"
  else
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name: expected rc=$want got rc=$RC — output: $OUT")
    echo "  FAIL: $name — expected rc=$want got rc=$RC"
  fi
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1)); echo "  PASS: $name"
  else
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name: expected to contain '$needle' — got: $haystack")
    echo "  FAIL: $name — missing '$needle'"
  fi
}

assert_equal() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    PASS=$((PASS + 1)); echo "  PASS: $name"
  else
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name: expected '$want' got '$got'")
    echo "  FAIL: $name — expected '$want' got '$got'"
  fi
}

fresh_state() { local p="$WORK/state.$RANDOM.$RANDOM"; rm -f "$p"; echo "$p"; }

echo ""
echo "=== loop-progress-signature.sh ==="

# ---------------------------------------------------------------------------
# TC-LPS-1 — a first failing iteration is progress, not a stop.
# FALSIFYING EDIT: change `COUNT=1` to `COUNT=$THRESHOLD` on the new-signature
# branch — the very first iteration would then exit 3 and abort every loop.
# ---------------------------------------------------------------------------
ST=$(fresh_state)
printf 'Foo.cs(1,1): error CS0246: type not found\n' > "$WORK/a1.txt"
run "$ST" "test" 2 "$WORK/a1.txt"
assert_rc "TC-LPS-1: first failing iteration returns 0 (keep going)" 0
assert_contains "TC-LPS-1b: first iteration reports a new signature" "progress: new failure signature" "$OUT"

# ---------------------------------------------------------------------------
# TC-LPS-2 — the same failure twice at threshold 2 stops the loop.
# FALSIFYING EDIT: change `if (( COUNT >= 10#$THRESHOLD ))` to `>` — the second
# identical iteration would return 0 and the guard would never fire at its own
# threshold.
# ---------------------------------------------------------------------------
run "$ST" "test" 2 "$WORK/a1.txt"
assert_rc "TC-LPS-2: second identical iteration returns 3 (stop and escalate)" 3
assert_contains "TC-LPS-2b: stop message names the run length and threshold" "2 consecutive iterations (threshold 2)" "$OUT"

# ---------------------------------------------------------------------------
# TC-LPS-3 (CLAIM A — the reason this is not mtime-based) — two iterations whose
# output differs ONLY in churn (timestamp, duration, absolute checkout path,
# uuid, hex address, pid) are the SAME signature and still stop the loop.
# This is the assertion an mtime detector cannot make: both iterations rewrote
# the same file and produced "activity" while fixing nothing.
# FALSIFYING EDIT: delete the `<dur>`, `<date>`, `<time>`, `<uuid>`, `<n>` or
# directory-prefix gsub from norm() — each of those alone makes the two
# signatures diverge, so this returns 0 instead of 3.
# ---------------------------------------------------------------------------
# ⛔ WHAT THIS TEST DOES **NOT** COVER — measured, not assumed. An earlier
# version of this comment claimed "delete ANY ONE of the normalisation rules and
# this fails". That was false: a rule-by-rule mutation sweep (delete one gsub,
# re-run the suite) found 9 of the 17 rules in norm() could be deleted with the
# whole suite still green. The overclaim mattered more than the gaps, because it
# was being read as proof of coverage that did not exist.
#
#   * `<addr>` and `<hex>` MASK EACH OTHER here — this fixture's addresses are
#     exactly 12 hex digits, so `[0-9a-f]{12,}` catches what `0x…` would have.
#     Deleting BOTH does fail this test; deleting either alone does not.
#   * `\r`, ANSI, whitespace-collapse and the two trims have no churn of their
#     kind in this fixture at all. ANSI is covered by TC-LPS-18b instead.
#   * the three line/column rules were entirely uncovered — now TC-LPS-18.
#
# Every churn token this test DOES rely on sits ON the selected error line. That
# placement is deliberate: if the churn sat on a neighbouring line, line
# selection and truncation would hide a regression and the test would pass for
# the wrong reason.
ST=$(fresh_state)
cat > "$WORK/b1.txt" <<'EOF'
build starting
/Users/alice/checkout/src/Foo.cs(12,7): error CS0246: not found [P.csproj] in 3.42 seconds at 0x7ffee3a1b2c0 pid 481920 run 3f2a1b9c-11de-4a55-9f3e-0a1b2c3d4e5f on 2026-08-22 10:11:12
EOF
cat > "$WORK/b2.txt" <<'EOF'
build starting
/home/bob/w/src/Foo.cs(12,7): error CS0246: not found [P.csproj] in 11.07 seconds at 0x7ffd0099aabb pid 774311 run aa11bb22-33cc-4dd5-9ee6-ff0011223344 on 2026-09-01 22:44:55
EOF
run "$ST" "test,build" 2 "$WORK/b1.txt"
assert_rc "TC-LPS-3a: churn iteration 1 returns 0" 0
run "$ST" "build,test" 2 "$WORK/b2.txt"
assert_rc "TC-LPS-3b: churn-only difference is the SAME signature — returns 3" 3

# ---------------------------------------------------------------------------
# TC-LPS-4 (CLAIM B) — a different diagnostic code is a NEW signature and
# resets the run length, so a loop that is genuinely moving is not stopped.
# FALSIFYING EDIT: remove `err=${ERROR_ID}` from SIG_INPUT — the identifier stops
# contributing and both iterations collapse to the gate set, returning 3.
#
# NOTE ON A WEAKER FALSIFIER: adding a blanket `gsub(/[0-9]+/, "<n>", s)` was
# previously named here, but it does NOT flip this rc assertion — the two
# fixtures also differ in prose ("not found [P.csproj]" vs "cannot convert"), so
# they stay distinct with every digit blanked. It only trips TC-LPS-4b, the
# message check. Measured, not assumed. The fixtures deliberately keep that prose
# difference because it is what a real second diagnostic looks like; TC-LPS-5 is
# where digit sensitivity is isolated.
# ---------------------------------------------------------------------------
printf '/Users/alice/checkout/src/Foo.cs(19,3): error CS1503: cannot convert\n' > "$WORK/b3.txt"
run "$ST" "build,test" 2 "$WORK/b3.txt"
assert_rc "TC-LPS-4: a different diagnostic code resets the run length" 0
assert_contains "TC-LPS-4b: the new code is reported" "error cs1503" "$OUT"

# ---------------------------------------------------------------------------
# TC-LPS-5 — short standalone numbers are KEPT, so an assertion whose expected
# value moved is real progress. This is the deliberate limit on normalisation,
# and it also proves the identifier is the whole selected LINE rather than the
# bare exception class.
# FALSIFYING EDIT: same blanket digit gsub as TC-LPS-4; lowering the
# `[0-9]{6,}` rule to `[0-9]+`; or reverting the identifier to the matched span
# (`substr(L[i], RSTART, RLENGTH)`), which would key on `assertionerror` alone
# and call this no progress.
# ---------------------------------------------------------------------------
ST=$(fresh_state)
printf 'AssertionError: expected 3 items, got 4\n' > "$WORK/c1.txt"
printf 'AssertionError: expected 3 items, got 5\n' > "$WORK/c2.txt"
run "$ST" "test" 2 "$WORK/c1.txt"
assert_rc "TC-LPS-5a: assertion iteration 1 returns 0" 0
run "$ST" "test" 2 "$WORK/c2.txt"
assert_rc "TC-LPS-5b: a changed assertion value is progress, not a stop" 0

# ---------------------------------------------------------------------------
# TC-LPS-6 — the failing-gate set is order-independent and de-duplicated.
# FALSIFYING EDIT: remove `LC_ALL=C sort -u` from the GATE_KEY pipeline.
# ---------------------------------------------------------------------------
ST=$(fresh_state)
printf 'error CS0246: nope\n' > "$WORK/d1.txt"
run "$ST" " build , test " 2 "$WORK/d1.txt"
assert_contains "TC-LPS-6a: gate set is normalised and sorted" "gates: build,test" "$OUT"
run "$ST" "test,build,test" 2 "$WORK/d1.txt"
assert_rc "TC-LPS-6b: reordered/duplicated gate list is the same signature" 3

# ---------------------------------------------------------------------------
# TC-LPS-7 — a CHANGED failing-gate set is progress even with an identical
# error identifier (the build stopped failing; only the tests still fail).
# FALSIFYING EDIT: drop the `gates=` term from SIG_INPUT.
# ---------------------------------------------------------------------------
ST=$(fresh_state)
run "$ST" "test,build" 2 "$WORK/d1.txt"
assert_rc "TC-LPS-7a: gate-change iteration 1 returns 0" 0
run "$ST" "test" 2 "$WORK/d1.txt"
assert_rc "TC-LPS-7b: a smaller failing-gate set is progress" 0

# ---------------------------------------------------------------------------
# TC-LPS-8 — an empty --failing-gates value means "nothing failed": it reports
# progress AND clears the state, so a later identical failure starts a fresh
# run rather than resuming the old count.
# FALSIFYING EDIT: remove `rm -f "$STATE_FILE"` from that branch — the third
# call below would then see count=2 and return 3.
# ---------------------------------------------------------------------------
ST=$(fresh_state)
run "$ST" "test" 2 "$WORK/d1.txt"
run "$ST" "" 2
assert_rc "TC-LPS-8a: empty gate list returns 0" 0
assert_contains "TC-LPS-8b: empty gate list reports the reset" "no failing gates — state reset" "$OUT"
run "$ST" "test" 2 "$WORK/d1.txt"
assert_rc "TC-LPS-8c: the reset really cleared the run length" 0

# ---------------------------------------------------------------------------
# TC-LPS-9 — `nosignal` is a signature, not an abstention: output with no
# extractable error still trips the threshold on the failing-gate set alone,
# and says so.
# FALSIFYING EDIT: make the no-match path exit 0 early (abstain) instead of
# printing "nosignal", or mix a per-run nonce into ERROR_ID.
# ---------------------------------------------------------------------------
ST=$(fresh_state)
printf 'nothing interesting here at all\n' > "$WORK/e1.txt"
run "$ST" "lint" 2 "$WORK/e1.txt"
assert_contains "TC-LPS-9a: unparseable output is marked degraded" "degraded" "$OUT"
run "$ST" "lint" 2 "$WORK/e1.txt"
assert_rc "TC-LPS-9b: repeated unparseable failure still stops the loop" 3

# ---------------------------------------------------------------------------
# TC-LPS-10 — a missing --output is not an error; it degrades to the gate set.
# FALSIFYING EDIT: add `[[ -n "$OUTPUT_SRC" ]] || die_usage "--output is required"`
# to the argument validation — this call then exits 2 instead of 0.
#
# NOTE: making read_output() exit non-zero does NOT falsify this, though an
# earlier version of this comment said it would. The ERROR_ID pipeline ends in
# `|| true` and awk still prints `nosignal` on empty input, so a failing
# read_output is swallowed and the script still exits 0. Measured, not assumed.
# ---------------------------------------------------------------------------
ST=$(fresh_state)
run "$ST" "test" 2
assert_rc "TC-LPS-10: no --output degrades instead of failing" 0

# ---------------------------------------------------------------------------
# TC-LPS-11 — the threshold is clamped to the toolbox ceiling, so a caller
# cannot buy a longer grind by passing a bigger number.
# FALSIFYING EDIT: delete the `if (( 10#$THRESHOLD > NO_PROGRESS_CEILING ))`
# clamp — iteration 5 below would return 0 instead of 3.
# ---------------------------------------------------------------------------
ST=$(fresh_state)
for i in 1 2 3 4; do
  run "$ST" "test" 99 "$WORK/d1.txt"
  assert_rc "TC-LPS-11a-$i: iteration $i under the clamped ceiling returns 0" 0
done
run "$ST" "test" 99 "$WORK/d1.txt"
assert_rc "TC-LPS-11b: iteration 5 hits the clamped ceiling and returns 3" 3
assert_contains "TC-LPS-11c: the clamp is announced" "exceeds the toolbox ceiling" "$OUT"

# ---------------------------------------------------------------------------
# TC-LPS-12 — a zero/garbage threshold falls back to the default of 2 rather
# than disabling the guard.
# FALSIFYING EDIT: change DEFAULT_THRESHOLD to 3, or make a non-numeric
# threshold an error instead of a fallback.
# ---------------------------------------------------------------------------
ST=$(fresh_state)
run "$ST" "test" 0 "$WORK/d1.txt"
assert_rc "TC-LPS-12a: threshold 0 falls back — iteration 1 returns 0" 0
run "$ST" "test" "banana" "$WORK/d1.txt"
assert_rc "TC-LPS-12b: non-numeric threshold falls back to 2 — iteration 2 returns 3" 3

# ---------------------------------------------------------------------------
# TC-LPS-13 — the registry picks the AUTHORITATIVE line, not the first line that
# merely says "failed". Both iterations below carry an unstable summary line
# first; the rust diagnostic under it is identical, so the loop must stop.
# FALSIFYING EDIT: delete the P2 rung from the awk END block — P4 then selects
# the "compiling failed for crate <x>" line, which differs between iterations,
# and this returns 0 instead of 3.
# ---------------------------------------------------------------------------
ST=$(fresh_state)
cat > "$WORK/f1.txt" <<'EOF'
compiling failed for crate alpha
error[E0382]: borrow of moved value
EOF
cat > "$WORK/f2.txt" <<'EOF'
compiling failed for crate zulu
error[E0382]: borrow of moved value
EOF
run "$ST" "build" 2 "$WORK/f1.txt"
assert_rc "TC-LPS-13a: rust iteration 1 returns 0" 0
run "$ST" "build" 2 "$WORK/f2.txt"
assert_rc "TC-LPS-13b: P2 selects the diagnostic line over an unstable 'failed' line" 3

# ---------------------------------------------------------------------------
# TC-LPS-13c/d — the same property for P1 (dotnet/tsc diagnostic code): an
# unstable restore/summary line must not be chosen over the diagnostic.
# FALSIFYING EDIT: delete the P1 rung — P4 selects the differing first line and
# this returns 0.
# ---------------------------------------------------------------------------
ST=$(fresh_state)
cat > "$WORK/g1.txt" <<'EOF'
restore failed for package alpha.core
Foo.cs(12,7): error CS0246: type not found
EOF
cat > "$WORK/g2.txt" <<'EOF'
restore failed for package zulu.core
Foo.cs(12,7): error CS0246: type not found
EOF
run "$ST" "build" 2 "$WORK/g1.txt"
assert_rc "TC-LPS-13c: dotnet iteration 1 returns 0" 0
run "$ST" "build" 2 "$WORK/g2.txt"
assert_rc "TC-LPS-13d: P1 selects the diagnostic line over an unstable 'failed' line" 3

# ---------------------------------------------------------------------------
# TC-LPS-13e/f — the same property for P3 (exception class): a pytest-style
# "FAIL <test id>" header that changes as the loop moves through tests must not
# be chosen over the exception line.
# FALSIFYING EDIT: delete the P3 rung — P4 selects the FAIL header and this
# returns 0.
# ---------------------------------------------------------------------------
ST=$(fresh_state)
cat > "$WORK/h1.txt" <<'EOF'
FAIL tests/test_alpha.py::test_one
AssertionError: widget was not registered
EOF
cat > "$WORK/h2.txt" <<'EOF'
FAIL tests/test_zulu.py::test_two
AssertionError: widget was not registered
EOF
run "$ST" "test" 2 "$WORK/h1.txt"
assert_rc "TC-LPS-13e: pytest iteration 1 returns 0" 0
run "$ST" "test" 2 "$WORK/h2.txt"
assert_rc "TC-LPS-13f: P3 selects the exception line over a changing FAIL header" 3

# ---------------------------------------------------------------------------
# TC-LPS-14 — a --state path that is a symlink is refused, and the symlink
# target is left untouched. Loop bookkeeping must not be redirectable into an
# arbitrary file.
# FALSIFYING EDIT: remove the `-L`/`! -f` state-path guard.
# ---------------------------------------------------------------------------
VICTIM="$WORK/victim.txt"
printf 'do-not-touch\n' > "$VICTIM"
ln -sf "$VICTIM" "$WORK/state-link"
run "$WORK/state-link" "test" 2 "$WORK/d1.txt"
assert_rc "TC-LPS-14a: symlink state path is refused with rc=2" 2
assert_equal "TC-LPS-14b: symlink target untouched" "do-not-touch" "$(cat "$VICTIM")"

# ---------------------------------------------------------------------------
# TC-LPS-14c/d — TC-LPS-14 guards the --state path, but the detector also
# writes a SIBLING temp file next to it. If that sibling's name is guessable,
# anything able to write the state DIRECTORY can pre-create it as a symlink and
# the detector's own write clobbers whatever it points at — the exact harm
# TC-LPS-14 exists to prevent, reached by the back door. Worse, `mv` then
# renames the symlink ONTO the state path, so every later run trips the
# regular-file guard and returns rc=2: guard 2 is wedged off permanently.
# The temp name must therefore be created by us, unpredictably, with O_EXCL.
#
# The spray runs in ONE python process on purpose: a shell loop of `ln -s`
# subprocesses burns the very PIDs the window is trying to cover, which is why
# a naive reproduction misses.
# FALSIFYING EDIT: change TMP_STATE back to "${STATE_FILE}.tmp.$$".
#
# ⛔ THE SETUP IS ASSERTED, NOT ASSUMED. This suite runs `set -uo pipefail`
# WITHOUT `set -e`, so a failing setup command does not stop it — and with no
# symlink planted, 14c/14d are VACUOUS: 14c re-reads a victim nothing pointed
# at, and 14d sees a state path that was never a symlink, so both pass against
# the very vulnerability they exist to catch. Measured, not assumed: with
# TMP_STATE reverted to "${STATE_FILE}.tmp.$$" (the vulnerable form) and
# python3 shimmed to `exit 1`, the suite reported 54/54 passed; with a working
# python3 the same detector correctly failed 14c and 14d. So an unplantable
# attack must FAIL LOUDLY rather than go green.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/sibling"
TMP_VICTIM="$WORK/sibling-victim.sh"
printf 'do-not-touch-either\n' > "$TMP_VICTIM"
SIB_STATE="$WORK/sibling/.loop-progress"
if ! python3 -c "
import os, sys
state, victim = sys.argv[1], sys.argv[2]
base = os.getpid()
for n in range(base + 1, base + 400):
    try:
        os.symlink(victim, '%s.tmp.%d' % (state, n))
    except FileExistsError:
        pass
" "$SIB_STATE" "$TMP_VICTIM"; then
  # Named separately from the count check below so the cause is visible: this
  # branch means the interpreter itself failed, not that symlinks were refused.
  FAIL=$((FAIL + 1))
  FAILED_TESTS+=("TC-LPS-14 setup: the symlink spray exited non-zero (python3 missing or broken) — 14c/14d cannot be trusted")
  echo "  FAIL: TC-LPS-14 setup — symlink spray exited non-zero" >&2
fi
# The count is the real gate: it catches a spray that "succeeded" while
# planting nothing (symlinks denied by the filesystem, every path pre-existing).
PLANTED=$(find "$WORK/sibling" -name '.loop-progress.tmp.*' -type l | wc -l | tr -d ' ')
assert_equal "TC-LPS-14 setup: temp-path symlinks were actually planted" "planted" \
  "$([[ "${PLANTED:-0}" -gt 0 ]] && echo planted || echo none)"
run "$SIB_STATE" "ci" 2 "$WORK/d1.txt"
# Without this, an rc=2 for an unrelated reason (the detector never reaching its
# state write at all) would also leave 14c/14d trivially satisfied.
assert_rc "TC-LPS-14e: the detector still runs normally under the spray" 0
assert_equal "TC-LPS-14c: a planted temp-path symlink does not clobber its target" "do-not-touch-either" "$(cat "$TMP_VICTIM")"
assert_equal "TC-LPS-14d: the state path is still a regular file, not a planted symlink" "regular" "$([[ -L "$SIB_STATE" ]] && echo symlink || echo regular)"

# ---------------------------------------------------------------------------
# TC-LPS-15 — usage errors are rc=2 (the caller must fall back to its turn
# bound, not treat silence as progress).
# FALSIFYING EDIT: remove the `--failing-gates is required` check, so a caller
# that forgets the flag gets a silent "no failing gates" pass.
# ---------------------------------------------------------------------------
OUT=$(bash "$DETECTOR" --state "$(fresh_state)" --threshold 2 2>&1); RC=$?
assert_rc "TC-LPS-15a: missing --failing-gates is rc=2" 2
OUT=$(bash "$DETECTOR" --state "$(fresh_state)" --failing-gates test --bogus x 2>&1); RC=$?
assert_rc "TC-LPS-15b: unknown argument is rc=2" 2

# The launcher exports LOOP_NO_PROGRESS_AFTER for loop bodies. When callers do
# not pass an explicit threshold, the detector consumes that bound; an explicit
# --threshold still wins and is clamped by the detector's own ceiling.
ENV_STATE=$(fresh_state)
export LOOP_NO_PROGRESS_AFTER=3
OUT=$(bash "$DETECTOR" --state "$ENV_STATE" --failing-gates stuck 2>&1); RC=$?
assert_rc "TC-LPS-15c: launcher threshold environment is consumed" 0
OUT=$(bash "$DETECTOR" --state "$ENV_STATE" --failing-gates stuck 2>&1); RC=$?
assert_rc "TC-LPS-15d: environment threshold repeats below bound" 0
OUT=$(bash "$DETECTOR" --state "$ENV_STATE" --failing-gates stuck 2>&1); RC=$?
assert_rc "TC-LPS-15e: environment threshold reaches STOP" 3
unset LOOP_NO_PROGRESS_AFTER

# ---------------------------------------------------------------------------
# TC-LPS-16 (DRIFT GATE) — the ceiling literal in the detector must equal the
# `no_progress_after` ceiling in the `workflow-discipline` skill §1d table,
# which is the documented source of truth. Two copies of a safety number drift
# silently; this makes the drift a build failure.
# FALSIFYING EDIT: change NO_PROGRESS_CEILING in the detector, or the **5** in
# the §1d table, without changing the other.
# FALSIFYING EDIT (16a/16b): delete BOTH the §1d table row and the detector's
# NO_PROGRESS_CEILING= line — two empty extractions compare equal, so 16 alone
# would still pass. 16a/16b are what makes that a failure.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# TC-LPS-17 — a per-test duration written with a BARE `s` unit is churn, not
# progress. This is the format `go test` (`(0.03s)`), `pytest -v`, jest and
# vitest all emit, and the original unit list matched none of them: a stuck loop
# re-running the same failing test got a fresh signature every iteration purely
# because the timing moved, so the guard could never trip. The single most
# likely real-world churn source, and it was uncovered.
# FALSIFYING EDIT: delete the `gsub(/[0-9]+[.,][0-9]+[ ]?s/, "<dur>", s)` rule.
# ---------------------------------------------------------------------------
ST=$(fresh_state)
printf 'FAIL TestFoo (0.03s): widget was not registered\n' > "$WORK/s1.txt"
printf 'FAIL TestFoo (0.04s): widget was not registered\n' > "$WORK/s2.txt"
run "$ST" "test" 2 "$WORK/s1.txt"
assert_rc "TC-LPS-17a: bare-'s' duration iteration 1 returns 0" 0
run "$ST" "test" 2 "$WORK/s2.txt"
assert_rc "TC-LPS-17b: a bare-'s' duration change alone is churn — returns 3" 3

# ---------------------------------------------------------------------------
# TC-LPS-17c — the bare-`s` rule must not OVER-match. Requiring a decimal is
# what keeps it from eating the "2 s" of "2 successes" and leaving
# "<dur>uccesses" — POSIX ERE has no word boundary to lean on, so the decimal IS
# the guard. Both directions of the predicate, per the review checklist.
# FALSIFYING EDIT: relax the rule to `gsub(/[0-9]+[ ]?s/, "<dur>", s)`.
# ---------------------------------------------------------------------------
ST=$(fresh_state)
printf 'error CS0246: 2 successes, 1 failure, 3 skipped\n' > "$WORK/s3.txt"
run "$ST" "test" 2 "$WORK/s3.txt"
assert_contains "TC-LPS-17c: plural words are not eaten as durations" "2 successes" "$OUT"

# ---------------------------------------------------------------------------
# TC-LPS-18 — line/column churn is normalised. When a loop edits a file, every
# diagnostic BELOW the edit shifts line number while being the same failure; if
# that shift changed the signature the guard would never trip on the one thing
# it most needs to catch. norm() has three rules for this — `(l,c)` for msbuild,
# `:l:c` and `:l` for everything else — and a mutation sweep showed ALL THREE
# could be deleted with the suite still green, because TC-LPS-3's fixtures use
# an IDENTICAL `(12,7)` in both iterations. This test is the missing coverage.
# FALSIFYING EDIT: delete the `(<l>,<c>)` gsub — that alone flips TC-LPS-18b
# from rc=3 to rc=0. Verified.
#
# ⛔ NOT EITHER COLON RULE — and an earlier version of this comment was WRONG to
# claim the `:<l>` gsub also flipped 18b. Measured: with `gsub(/:[0-9]+/, ...)`
# deleted from the detector the whole suite stays 54/54 green. The reason is
# line SELECTION, not normalisation — both fixtures lead with an msbuild
# diagnostic, P1 takes the FIRST line matching `error <code>` and exits, so the
# `src/Bar.ts:31:9` line never reaches the signature at all. TC-LPS-18 therefore
# pins the `(<l>,<c>)` rule and nothing else; the colon forms are pinned by
# TC-LPS-18e/f below, on fixtures that carry no msbuild diagnostic.
#
# `:<l>:<c>` stays unpinned on purpose: deleting it changes nothing, because the
# global `:[0-9]+` rule that follows normalises `:31:9` to `:<l>:<l>` on both
# iterations, which compares equal just as well. So `:<l>:<c>` is REDUNDANT for
# signature purposes; it survives only because `:<l>:<c>` reads better than
# `:<l>:<l>` in the `error:` line a human sees. Recorded here rather than
# asserted, because there is no behaviour to assert. Measured, not assumed.
# ---------------------------------------------------------------------------
ST=$(fresh_state)
printf 'Foo.cs(12,7): error CS0246: type not found\nsrc/Bar.ts:31:9 - error TS2304: cannot find name\n' > "$WORK/l1.txt"
printf 'Foo.cs(48,3): error CS0246: type not found\nsrc/Bar.ts:77:2 - error TS2304: cannot find name\n' > "$WORK/l2.txt"
run "$ST" "build" 2 "$WORK/l1.txt"
assert_rc "TC-LPS-18a: line/col iteration 1 returns 0" 0
run "$ST" "build" 2 "$WORK/l2.txt"
assert_rc "TC-LPS-18b: a shifted line:col alone is churn — returns 3" 3

# ---------------------------------------------------------------------------
# TC-LPS-18e/f — the COLON line form, ISOLATED. This is the coverage TC-LPS-18
# only appeared to give: its fixtures lead with an msbuild diagnostic that P1
# selects and stops on, so the `:<l>` rule was deletable with the suite green.
# These fixtures carry NO msbuild `(l,c)` diagnostic, so P1 selects the
# tsc-style line and a shifted `:line` is what the signature actually sees —
# the churn every non-msbuild toolchain emits when a loop edits a file above
# the failing line.
# FALSIFYING EDIT: delete the `gsub(/:[0-9]+/, ":<l>", s)` rule — 18f flips
# from rc=3 to rc=0. Verified (measured against a mutated copy of the detector).
# ---------------------------------------------------------------------------
ST=$(fresh_state)
printf 'src/Bar.ts:31 - error TS2304: cannot find name\n' > "$WORK/l3.txt"
printf 'src/Bar.ts:77 - error TS2304: cannot find name\n' > "$WORK/l4.txt"
run "$ST" "build" 2 "$WORK/l3.txt"
assert_rc "TC-LPS-18e: colon-form line iteration 1 returns 0" 0
run "$ST" "build" 2 "$WORK/l4.txt"
assert_rc "TC-LPS-18f: a shifted :line alone is churn — returns 3" 3

# ---------------------------------------------------------------------------
# TC-LPS-18c — ANSI colour churn is normalised. Also uncovered before now: a
# runner that colourises only when attached to a TTY produces two byte-different
# outputs for one identical failure.
# FALSIFYING EDIT: delete the `gsub(/\033\[[0-9;?]*[a-zA-Z]/, "", s)` rule.
# ---------------------------------------------------------------------------
ST=$(fresh_state)
printf '\033[1;31mFoo.cs(12,7): error CS0246: type not found\033[0m\n' > "$WORK/n1.txt"
printf 'Foo.cs(12,7): error CS0246: type not found\n' > "$WORK/n2.txt"
run "$ST" "build" 2 "$WORK/n1.txt"
assert_rc "TC-LPS-18c: ANSI iteration 1 returns 0" 0
run "$ST" "build" 2 "$WORK/n2.txt"
assert_rc "TC-LPS-18d: ANSI colour codes alone are churn — returns 3" 3

# ---------------------------------------------------------------------------
# TC-LPS-19 (CONTRACT PIN) — the QUIET path. `examples/loop.md.example` tells a
# PR-tending loop to report an idle iteration as a single synthetic gate
# ("no-change") so the constant signature accumulates and the guard trips. That
# is the loop's ONLY no-progress mechanism on its dominant case: an iteration
# with nothing landed and no gate failing. Empty gates must NOT be used there —
# empty means "converged", which resets the counter and can never trip.
#
# This pin PASSES today; it exists so a future change that stopped accumulating
# on a single synthetic gate, or that made a reset non-resetting, breaks here
# instead of silently disarming the quiet path in the loop template.
# FALSIFYING EDIT: make the no-failing-gates branch keep state instead of
# resetting (19c flips), or stop counting repeats of a one-gate signature
# (19b flips).
# ---------------------------------------------------------------------------
ST=$(fresh_state)
run "$ST" "no-change" 2
assert_rc "TC-LPS-19a: first idle iteration returns 0" 0
run "$ST" "no-change" 2
assert_rc "TC-LPS-19b: a second consecutive idle iteration returns 3" 3
run "$ST" "" 2
assert_rc "TC-LPS-19c: an iteration that landed something resets to 0" 0
run "$ST" "no-change" 2
assert_rc "TC-LPS-19d: idle after a reset starts counting again at 0" 0

SKILL_MD="$REPO_ROOT/skills/workflow-discipline/SKILL.md"
SKILL_CEILING=$(awk -F'|' '/`no_progress_after`/ && /\*\*/ { s = $4; gsub(/[^0-9]/, "", s); if (s != "") { print s; exit } }' "$SKILL_MD")
SCRIPT_CEILING=$(awk -F= '/^NO_PROGRESS_CEILING=/ { print $2; exit }' "$DETECTOR")
assert_equal "TC-LPS-16a: the §1d table yields a ceiling literal" "yes" "$([[ -n "$SKILL_CEILING" ]] && echo yes || echo no)"
assert_equal "TC-LPS-16b: the detector yields a ceiling literal" "yes" "$([[ -n "$SCRIPT_CEILING" ]] && echo yes || echo no)"
assert_equal "TC-LPS-16: detector ceiling matches workflow-discipline skill §1d" "$SKILL_CEILING" "$SCRIPT_CEILING"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
TOTAL=$((PASS + FAIL))
echo "Results: $PASS/$TOTAL passed"
if [[ "$FAIL" -gt 0 ]]; then
  echo "Failed tests:"
  for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
  exit 1
fi
exit 0
