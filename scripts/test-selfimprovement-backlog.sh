#!/usr/bin/env bash
# test-selfimprovement-backlog.sh — Unit tests for scripts/selfimprovement-backlog.sh.
#
# WHY these test cases exist:
#   The self-improvement loop (capture -> fold -> surface -> human triage) ends
#   in a HUMAN-GATED step, and a human-gated step that nothing surfaces simply
#   does not happen. It already did not happen twice: 69 lessons findings sat
#   unread for four weeks, and 75 deviation records across 6 snapshots sat
#   unread for six, both while the loop reported no failure of any kind. The
#   backlog reporter exists to make that silence impossible.
#
#   A reporter has exactly two failure modes, and they pull in opposite
#   directions. It can under-report (the original bug, back again), or it can
#   cry wolf on a fresh install that has simply never had anything to triage —
#   and a warning that fires for everyone is a warning everyone learns to
#   ignore, which is the same silence by a different route. So the false
#   POSITIVE case is pinned here as tightly as the false negative.
#
#   The helper takes STATE_DIR as an argument precisely so this suite can drive
#   it against a temp directory. Testing through verify.sh instead would
#   recurse — verify.sh runs the test suites, and this suite would run
#   verify.sh.
#
# Test cases:
#   TC-SIB-1: empty state dir → ZERO `WARN:` lines and exactly one `OK:` line
#             (a fresh install must never WARN — it is not silent, and the old
#             wording "must be quiet" said something the test never asserted)
#   TC-SIB-2: one deviation snapshot → exactly one backlog warning, naming the
#              file, with a record count of 1
#   TC-SIB-3: oldest-by-MTIME, not by filename → with -99 older than -105 the
#              warning must name -99 (a `sort | head -1` would say -105)
#   TC-SIB-4: snapshot + EMPTY dismissed log → still warns "never completed"
#              (pins `-s` vs `-f`: the real dismissed log exists at 0 bytes)
#   TC-SIB-5: snapshot + NON-EMPTY dismissed log → backlog warning yes,
#              never-completed warning no
#   TC-SIB-6: pending-lessons-deferred.jsonl is excluded from the lessons count
#              (it is the cross-PR deferred queue, not a backlog item — same
#              exclusion the consumer in review-pr.md makes)
#   TC-SIB-7: nothing pending but an archived file present → ZERO warnings
#              (a drained loop is silent)
#   TC-SIB-8: a 0-RECORD snapshot beside populated ones → the reported record
#              count must still be the true total (pins the zero boundary: one
#              empty file must not blank the whole count)
#   TC-SIB-9: same boundary reached by a BLANK-LINES-ONLY file rather than a
#              0-byte one — stops an `-s`-only fix from looking complete
#   TC-SIB-10: the lessons half of the same boundary (its own call site passes
#              the deferred exclusion, so it needs its own case)
#   TC-SIB-11: END-TO-END — runs the REAL scripts/pr-postmerge-fold.sh over a
#              handover.md fixture, then the REAL reporter over the directory
#              the fold just wrote to, and requires the writer's count, the
#              reader's count and the fixture's known truth to be one number.
#              This is the only test that crosses the writer/reader seam, so it
#              is the only one that can catch a `wc -l` vs `grep -c` divergence
#              or a reader pointed at a different state dir than the writer
#   TC-SIB-12: an UNREADABLE (chmod 000) snapshot stays in the snapshot count
#              and in the report — a queued file must never go unmentioned.
#              Pins the readable-only record total exactly, with the known
#              accuracy gap recorded at the test
#   TC-SIB-14: an UNLISTABLE state dir (chmod 000, real snapshot inside) reports
#              UNKNOWN with a WARN naming the path, and NEVER "drained" — every
#              count comes from a `find` with `2>/dev/null`, so without the
#              explicit probe a queue it could not open reports as empty.
#   TC-SIB-15: a SURFACED-only queue is still "never completed" — being shown a
#              deviation is not deciding it, so surfaced-deviations.log must never
#              count as completion evidence
#   TC-SIB-16: an ARCHIVED snapshot DOES count as completion — the companion to
#              TC-SIB-15, so removing the surfaced signal cannot be achieved by
#              removing the completion test altogether
#   TC-SIB-17: verify.sh's CALL SITE (extracted from scripts/verify.sh and run
#              against a stub) warns when the reporter fails or prints nothing,
#              and its healthy path still increments the caller's WARNINGS counter
#              — pins both the exit-status check and the load-bearing process
#              substitution
#   TC-SIB-19: an EMPTY consumed-deviations/ is NOT completion evidence — the
#              consumer mkdir -p's that directory unconditionally, so a
#              presence-only test would silence the warning everywhere
#   TC-SIB-18: verify.sh RELAYS this suite's own SKIP lines (extracted block +
#              a stub suite emitting 2 PASS and 2 SKIP) — this file claims a skip
#              is "visible", and that claim is about the CALLER, which was
#              discarding them
#   TC-SIB-13: a MISSING state dir (distinct from TC-SIB-1's empty one) reports
#              "nothing captured" and NAMES the path, never "drained" — the
#              wording is the only thing that exposes a reader/writer path
#              mismatch
#
# Usage: ./scripts/test-selfimprovement-backlog.sh
# Exits 0 if all tests pass, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKLOG="$SCRIPT_DIR/selfimprovement-backlog.sh"
# A repo root is the helper's second argument (it reads knowledge/ for the
# lessons-loop-completed signal). Tests pass a temp dir so the real repo's
# knowledge file cannot influence a result.
PASS=0
FAIL=0
SKIP=0
FAILED_TESTS=()
SKIPPED_TESTS=()

# ---------------------------------------------------------------------------
# Are we root? Two fixtures in this file establish their premise with
# `chmod 000`, and root bypasses the permission bits entirely: the file stays
# readable, the directory stays traversable, and the case cannot be exercised at
# all. Those fixtures used to FAIL in that situation, which made the whole suite
# — and therefore `verify.sh`, which runs it — unpassable inside any root
# container or root CI job even when the code under test was perfectly correct.
# A test that cannot run is a SKIP, not a failure: it reports the missing
# coverage without inventing a defect.
#
# `EUID` is a bash builtin, so it is always set here (this script has a bash
# shebang); `id -u` is the fallback for any shell that lacks it.
IS_ROOT=false
[[ "${EUID:-$(id -u)}" -eq 0 ]] && IS_ROOT=true

pass_test() {
  PASS=$((PASS + 1))
  printf '  PASS: %s\n' "$1"
}

fail_test() {
  FAIL=$((FAIL + 1))
  FAILED_TESTS+=("$1: $2")
  printf '  FAIL: %s — %s\n' "$1" "$2"
}

# A case whose PREMISE cannot be established in this environment. Distinct from
# both PASS (nothing was verified) and FAIL (nothing is wrong with the code).
# Counted and listed in the summary so a permanently-skipping case is visible
# rather than quietly absent.
skip_test() {
  SKIP=$((SKIP + 1))
  SKIPPED_TESTS+=("$1: $2")
  printf '  SKIP: %s — %s\n' "$1" "$2"
}

# Run the helper against a temp state dir + temp repo root, capturing stdout.
# Asserts the always-exit-0 contract on every call: this reporter is
# INFORMATIONAL and must never fail a build, so a nonzero exit is itself a
# defect regardless of what was printed.
run_backlog() {
  local state_dir="$1" repo_root="$2"
  local out rc
  out=$(bash "$BACKLOG" "$state_dir" "$repo_root" 2>&1)
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    printf 'NONZERO_EXIT(%s)\n%s\n' "$rc" "$out"
  else
    printf '%s\n' "$out"
  fi
}

warn_count() { printf '%s\n' "$1" | grep -c '^WARN: ' || true; }

# Make a JSONL deviation snapshot with N records.
mk_dev_snapshot() {
  local path="$1" n="$2" i
  : > "$path"
  for (( i = 1; i <= n; i++ )); do
    printf '{"ts":"2026-01-01T00:00:00Z","phase":"P","body":"record %d"}\n' "$i" >> "$path"
  done
}

if [[ ! -f "$BACKLOG" ]]; then
  fail_test "TC-SIB-0: helper exists" "scripts/selfimprovement-backlog.sh not found at $BACKLOG"
  printf '\n  %d/%d tests FAILED:\n' "$FAIL" "$((PASS + FAIL))"
  printf '    - %s\n' "${FAILED_TESTS[@]}"
  exit 1
fi

# ---------------------------------------------------------------------------
# TC-SIB-1: a fresh install must never WARN.
#
# WHY: this is the cry-wolf case. Nothing has ever been captured, so there is
# nothing to triage and no triage has ever completed. Reporting "the loop has
# never completed a triage" here would fire on every clean machine forever, and
# a warning that always fires trains the reader to skip the whole section —
# re-creating the silence this check exists to break.
#
# ⛔ THE CONTRACT AND THE ASSERTION NOW MATCH. ⛔ This case was called "silent"
# and "completely quiet" while asserting only `WARN:` == 0 — and the helper
# deliberately DOES print on a fresh install (one `OK:` line, and TC-SIB-13
# asserts the missing-dir variant says what path it looked at, which requires
# output). So the claim was strictly stronger than the test, in the direction
# that lets real noise in: an unconditional `INFO:` added here would have kept
# the test green while making the fresh-install report chatty. The assertion is
# now the exact shape — no WARN, no INFO, exactly one OK — so the sentence above
# and the code below cannot disagree again.
#
# FALSIFYING EDITS: add any unconditional `WARN:` or `INFO:` line to the
# reporter (INFO count goes to 1); make the drained `OK:` line conditional on
# something an empty dir does not satisfy (OK count goes to 0).
# ---------------------------------------------------------------------------
TC="TC-SIB-1: empty state dir never warns, and says exactly one thing"
state=$(mktemp -d); repo=$(mktemp -d)
OUT=$(run_backlog "$state" "$repo")
W=$(warn_count "$OUT")
OKC=$(printf '%s\n' "$OUT" | grep -c '^OK: ' || true)
INFOC=$(printf '%s\n' "$OUT" | grep -c '^INFO: ' || true)
if [[ "$OUT" == NONZERO_EXIT* ]]; then
  fail_test "$TC" "helper exited nonzero: $OUT"
elif [[ "$W" -ne 0 ]]; then
  fail_test "$TC" "expected 0 warnings on a fresh install, got $W: $OUT"
elif [[ "$OKC" -ne 1 ]]; then
  fail_test "$TC" "expected exactly 1 'OK:' line on a fresh install, got $OKC — the fresh-install report is not silent by design (TC-SIB-13 depends on it saying something), so 0 means the report went mute and >1 means it got chatty: $OUT"
elif [[ "$INFOC" -ne 0 ]]; then
  fail_test "$TC" "expected 0 'INFO:' lines on a fresh install, got $INFOC — INFO lines exist to explain a WARN, and there is no WARN here: $OUT"
else
  pass_test "$TC (0 WARN, 0 INFO, exactly 1 OK)"
fi
rm -rf "$state" "$repo"

# ---------------------------------------------------------------------------
# TC-SIB-2: a real queue is reported, and reported specifically.
#
# WHY: "there is a backlog" is not actionable on its own. The reader needs to
# know how much and where, so the warning must carry the count and name a file.
# ---------------------------------------------------------------------------
TC="TC-SIB-2: one deviation snapshot warns, naming file and count"
state=$(mktemp -d); repo=$(mktemp -d)
mk_dev_snapshot "$state/pending-deviations-7.log" 1
OUT=$(run_backlog "$state" "$repo")
DEV_WARN=$(printf '%s\n' "$OUT" | grep '^WARN: ' | grep -c 'deviation' || true)
if [[ "$OUT" == NONZERO_EXIT* ]]; then
  fail_test "$TC" "helper exited nonzero: $OUT"
elif [[ "$DEV_WARN" -lt 1 ]]; then
  fail_test "$TC" "no deviation backlog warning emitted: $OUT"
elif ! printf '%s\n' "$OUT" | grep -q 'pending-deviations-7.log'; then
  fail_test "$TC" "warning does not name the queued file: $OUT"
elif ! printf '%s\n' "$OUT" | grep -qE '\b1 record'; then
  fail_test "$TC" "warning does not report a record count of 1: $OUT"
else
  pass_test "$TC (names pending-deviations-7.log, 1 record)"
fi
rm -rf "$state" "$repo"

# ---------------------------------------------------------------------------
# TC-SIB-3: "oldest" means oldest by MTIME, not first by filename.
#
# WHY: the lessons half of this check used `sort | head -1`, which is
# lexicographic — so `pending-...-105` sorts before `pending-...-99` and the
# report names the WRONG file as oldest. PR number is not recency either. This
# fixture is built so the two orderings disagree: -99 is older in time but
# later in lexicographic order. `touch -t` is used because its CCYYMMDDhhmm
# form is accepted by both BSD and GNU touch.
# ---------------------------------------------------------------------------
TC="TC-SIB-3: oldest is by mtime, not lexicographic filename"
state=$(mktemp -d); repo=$(mktemp -d)
mk_dev_snapshot "$state/pending-deviations-99.log" 1
mk_dev_snapshot "$state/pending-deviations-105.log" 1
touch -t 202601010000 "$state/pending-deviations-99.log"
touch -t 202606010000 "$state/pending-deviations-105.log"
OUT=$(run_backlog "$state" "$repo")
OLDEST_LINE=$(printf '%s\n' "$OUT" | grep '^WARN: ' | grep 'deviation' | head -1)
if [[ "$OUT" == NONZERO_EXIT* ]]; then
  fail_test "$TC" "helper exited nonzero: $OUT"
elif [[ -z "$OLDEST_LINE" ]]; then
  fail_test "$TC" "no deviation backlog warning emitted: $OUT"
elif printf '%s' "$OLDEST_LINE" | grep -q 'oldest: pending-deviations-99.log'; then
  pass_test "$TC (names -99, the mtime-oldest, not the lexicographically-first -105)"
else
  fail_test "$TC" "expected 'oldest: pending-deviations-99.log', got: $OLDEST_LINE"
fi
rm -rf "$state" "$repo"

# ---------------------------------------------------------------------------
# TC-SIB-4: an EMPTY dismissed log does not count as a completed triage.
#
# WHY this is the most important case in the file: ~/.claude/dismissed-deviations.log
# exists RIGHT NOW at 0 bytes, created by an unconditional `touch` that ran
# before any gate in the old consumer. A `-f` test would therefore conclude
# "this loop has completed a triage" on a machine where it never has, and the
# never-completed warning — the one that would have caught six weeks of data
# loss — would be suppressed on exactly the machine that needed it. Only `-s`
# distinguishes the two.
# ---------------------------------------------------------------------------
TC="TC-SIB-4: empty dismissed log still counts as never-completed"
state=$(mktemp -d); repo=$(mktemp -d)
mk_dev_snapshot "$state/pending-deviations-7.log" 1
: > "$state/dismissed-deviations.log"   # exists, zero bytes — the real-world state
OUT=$(run_backlog "$state" "$repo")
NEVER=$(printf '%s\n' "$OUT" | grep '^WARN: ' | grep -ci 'never completed' || true)
if [[ "$OUT" == NONZERO_EXIT* ]]; then
  fail_test "$TC" "helper exited nonzero: $OUT"
elif [[ "$NEVER" -lt 1 ]]; then
  fail_test "$TC" "a 0-byte dismissed log suppressed the never-completed warning (the -f vs -s trap): $OUT"
else
  pass_test "$TC (0-byte dismissed log does not count as a completion)"
fi
rm -rf "$state" "$repo"

# ---------------------------------------------------------------------------
# TC-SIB-5: a NON-EMPTY dismissed log does count, and only silences the
# never-completed half.
#
# WHY: the two warnings answer different questions — "is there a queue?" and
# "has this loop ever produced a decision?". Proving one goes quiet while the
# other stays loud is what shows they are independent rather than one warning
# printed twice.
# ---------------------------------------------------------------------------
TC="TC-SIB-5: non-empty dismissed log silences never-completed but not the backlog"
state=$(mktemp -d); repo=$(mktemp -d)
mk_dev_snapshot "$state/pending-deviations-7.log" 1
printf '[abc12345] 2026-01-01T00:00:00Z | some dismissed deviation\n' > "$state/dismissed-deviations.log"
OUT=$(run_backlog "$state" "$repo")
NEVER=$(printf '%s\n' "$OUT" | grep '^WARN: ' | grep -ci 'never completed' || true)
DEV_WARN=$(printf '%s\n' "$OUT" | grep '^WARN: ' | grep -c 'deviation snapshot' || true)
if [[ "$OUT" == NONZERO_EXIT* ]]; then
  fail_test "$TC" "helper exited nonzero: $OUT"
elif [[ "$NEVER" -ne 0 ]]; then
  fail_test "$TC" "never-completed warning still fired despite a non-empty dismissed log: $OUT"
elif [[ "$DEV_WARN" -lt 1 ]]; then
  fail_test "$TC" "the backlog warning was silenced too — a completed triage does not empty the queue: $OUT"
else
  pass_test "$TC (never-completed silenced, backlog still reported)"
fi
rm -rf "$state" "$repo"

# ---------------------------------------------------------------------------
# TC-SIB-15: SURFACING IS NOT DECIDING — surfaced-deviations.log must never
# count as a completed triage.
#
# WHY: the reporter treated a non-empty `surfaced-deviations.log` as completion
# evidence, which contradicts the invariant the whole consumer is built on.
# commands/review-pr.md refuses to let that file archive a snapshot, and says so
# in three places: it is the REPRINT POINTER, it records what was printed, and it
# authorizes nothing. Accepting it here meant the very FIRST surface — including
# an unattended `--auto` cron fire nobody read — permanently silenced the "never
# completed a triage" warning, on the machine where that warning was true. The
# queue then sat with a backlog warning and no indication that nothing had ever
# been decided about it.
#
# It is also unstable as evidence: an attended run that prints nothing while
# undecided records remain TRUNCATES the pointer on purpose (the anti-hiding
# reset), so this "evidence" could disappear and come back. Evidence does not do
# that; a decision does not un-happen.
#
# The fixture is deliberately the exact real-world shape: a queued snapshot, an
# EMPTY dismissed log (the state on this machine today), a NON-EMPTY surfaced log,
# and NO archive directory. The only completion signals that may count are the
# dismissed log being non-empty or a file existing in consumed-deviations/.
#
# FALSIFYING EDIT: re-add `[[ -s "$STATE_DIR/surfaced-deviations.log" ]] &&
# DEV_LOOP_COMPLETED=true` to scripts/selfimprovement-backlog.sh — the
# never-completed warning disappears and this test goes RED. (TC-SIB-4 does NOT
# catch it: TC-SIB-4's fixture writes no surfaced log at all, so the bad line
# never fires there.)
# ---------------------------------------------------------------------------
TC="TC-SIB-15: a surfaced-only queue is still 'never completed'"
state=$(mktemp -d); repo=$(mktemp -d)
mk_dev_snapshot "$state/pending-deviations-7.log" 2
: > "$state/dismissed-deviations.log"   # decided nothing — the real-world state
# Two markers in the pointer's real line shape: the records WERE shown.
printf '[%064d] 2026-01-01T00:00:00Z | record 1\n' 1 > "$state/surfaced-deviations.log"
printf '[%064d] 2026-01-01T00:00:01Z | record 2\n' 2 >> "$state/surfaced-deviations.log"
OUT=$(run_backlog "$state" "$repo")
NEVER=$(printf '%s\n' "$OUT" | grep '^WARN: ' | grep -ci 'never completed' || true)
DEV_WARN=$(printf '%s\n' "$OUT" | grep '^WARN: ' | grep -c 'deviation snapshot' || true)
if [[ "$OUT" == NONZERO_EXIT* ]]; then
  fail_test "$TC" "helper exited nonzero: $OUT"
elif [[ "$NEVER" -lt 1 ]]; then
  fail_test "$TC" "a non-empty surfaced-deviations.log suppressed the never-completed warning — being SHOWN a deviation is not DECIDING it, and the consumer refuses to let that file archive anything for exactly this reason: $OUT"
elif [[ "$DEV_WARN" -lt 1 ]]; then
  fail_test "$TC" "the backlog warning did not fire for a queued snapshot: $OUT"
elif printf '%s\n' "$OUT" | grep -qi 'ever been surfaced'; then
  # The wording is part of the fix, not decoration. This fixture is precisely the
  # state where the OLD text ("nothing has ever been surfaced, dismissed or
  # archived") is a FALSE STATEMENT: two records were surfaced. A reader relies on
  # this one message to know whether the loop works, so a claim it contradicts is
  # worse than no claim. FALSIFYING EDIT: restore the old wording in
  # scripts/selfimprovement-backlog.sh.
  fail_test "$TC" "the never-completed warning still claims nothing was ever SURFACED, in a fixture where two records demonstrably were — surfacing is no longer part of the condition, so it must not be part of the sentence: $OUT"
else
  pass_test "$TC (surfaced markers present, dismissed log empty — both warnings still fire, and the wording no longer claims nothing was surfaced)"
fi
rm -rf "$state" "$repo"

# ---------------------------------------------------------------------------
# TC-SIB-16: an ARCHIVED snapshot DOES count as a completed triage.
#
# WHY this sits beside TC-SIB-15: removing the surfaced-log signal must not be
# achieved by removing the completion test altogether. A snapshot only reaches
# consumed-deviations/ once every record in it was DISMISSED, so the archive
# directory is a terminal record of a human decision — and if it stopped counting,
# a fully-drained machine would be told forever that its loop has never completed
# anything, which is the cry-wolf failure this suite pins as tightly as the
# silent one.
#
# FALSIFYING EDIT: delete `dir_has_file "$STATE_DIR/consumed-deviations" &&
# DEV_LOOP_COMPLETED=true` from the reporter — this test goes RED while TC-SIB-15
# still passes, which is what makes the two independent.
# ---------------------------------------------------------------------------
TC="TC-SIB-16: an archived snapshot counts as a completed triage"
state=$(mktemp -d); repo=$(mktemp -d)
mk_dev_snapshot "$state/pending-deviations-8.log" 1
: > "$state/dismissed-deviations.log"   # empty: the ARCHIVE is the only signal
mkdir -p "$state/consumed-deviations"
mk_dev_snapshot "$state/consumed-deviations/pending-deviations-5.log" 1
OUT=$(run_backlog "$state" "$repo")
NEVER=$(printf '%s\n' "$OUT" | grep '^WARN: ' | grep -ci 'never completed' || true)
DEV_WARN=$(printf '%s\n' "$OUT" | grep '^WARN: ' | grep -c 'deviation snapshot' || true)
if [[ "$OUT" == NONZERO_EXIT* ]]; then
  fail_test "$TC" "helper exited nonzero: $OUT"
elif [[ "$NEVER" -ne 0 ]]; then
  fail_test "$TC" "an archived snapshot did not count as a completed triage — a snapshot only archives once every record was dismissed, so this is a terminal human decision: $OUT"
elif [[ "$DEV_WARN" -lt 1 ]]; then
  fail_test "$TC" "the still-queued snapshot stopped being reported — a past completion does not empty the current queue: $OUT"
else
  pass_test "$TC (archive counts as completion, remaining queue still reported)"
fi
rm -rf "$state" "$repo"

# ---------------------------------------------------------------------------
# TC-SIB-19: an EMPTY consumed-deviations/ is NOT a completed triage.
#
# WHY this is the most reachable regression in the whole reporter: the consumer
# runs `mkdir -p "$CLAUDE_DIR" "$CONSUMED_DIR"` unconditionally on the normal
# tools-present path, so the archive DIRECTORY exists — empty — on every machine
# that has ever run /review-pr. TC-SIB-16 establishes `dir + file → completion`
# but nothing established `dir, no file → NOT completion`, so weakening
# `dir_has_file` to a bare `[[ -d "$d" ]]` left the entire suite green while
# silencing the never-completed warning UNIVERSALLY — the exact six-week silent
# stall this branch exists to remove, reintroduced through the directory the
# consumer itself creates.
#
# FALSIFYING EDIT: change `dir_has_file` in scripts/selfimprovement-backlog.sh
# to test `[[ -d "$1" ]]` instead of looking for a file inside it.
# ---------------------------------------------------------------------------
TC="TC-SIB-19: an empty archive dir is not a completed triage"
state=$(mktemp -d); repo=$(mktemp -d)
mk_dev_snapshot "$state/pending-deviations-9.log" 1
: > "$state/dismissed-deviations.log"      # nothing decided
mkdir -p "$state/consumed-deviations"      # exists, EMPTY — the universal state
OUT=$(run_backlog "$state" "$repo")
NEVER=$(printf '%s\n' "$OUT" | grep '^WARN: ' | grep -ci 'never completed' || true)
if [[ "$OUT" == NONZERO_EXIT* ]]; then
  fail_test "$TC" "helper exited nonzero: $OUT"
elif [[ "$NEVER" -lt 1 ]]; then
  fail_test "$TC" "an EMPTY consumed-deviations/ suppressed the never-completed warning — the consumer creates that directory unconditionally, so this would silence the warning on every machine that has ever run /review-pr: $OUT"
else
  pass_test "$TC (empty archive dir does not count as completion — only a file in it does)"
fi
rm -rf "$state" "$repo"

# ---------------------------------------------------------------------------
# TC-SIB-6: pending-lessons-deferred.jsonl is NOT a backlog item.
#
# WHY: it matches the same glob as the per-PR lessons snapshots but is the
# cross-PR DEFERRED queue — records the user has already looked at and chosen to
# hold. The consumer in commands/review-pr.md skips it by name for that reason,
# and counting it here would report a backlog on a fully-triaged machine, which
# is the cry-wolf failure again.
# ---------------------------------------------------------------------------
TC="TC-SIB-6: deferred lessons queue is excluded from the count"
state=$(mktemp -d); repo=$(mktemp -d)
printf '{"finding":"real one","verdict":"v","origin":"o"}\n' > "$state/pending-lessons-9.jsonl"
printf '{"finding":"deferred a","verdict":"v","origin":"o"}\n{"finding":"deferred b","verdict":"v","origin":"o"}\n' \
  > "$state/pending-lessons-deferred.jsonl"
OUT=$(run_backlog "$state" "$repo")
LESSON_LINE=$(printf '%s\n' "$OUT" | grep '^WARN: ' | grep -i 'lesson' | head -1)
if [[ "$OUT" == NONZERO_EXIT* ]]; then
  fail_test "$TC" "helper exited nonzero: $OUT"
elif [[ -z "$LESSON_LINE" ]]; then
  fail_test "$TC" "no lessons backlog warning emitted: $OUT"
elif printf '%s' "$LESSON_LINE" | grep -q 'deferred'; then
  fail_test "$TC" "the deferred queue was named as a backlog item: $LESSON_LINE"
elif printf '%s' "$LESSON_LINE" | grep -qE '\b1 lessons snapshot|\b1 learned-lessons snapshot'; then
  pass_test "$TC (counts 1 snapshot, deferred queue excluded)"
else
  fail_test "$TC" "expected a count of exactly 1 snapshot (deferred excluded), got: $LESSON_LINE"
fi
rm -rf "$state" "$repo"

# ---------------------------------------------------------------------------
# TC-SIB-7: a drained loop is silent.
#
# WHY: the queue is empty and there IS evidence of a completed triage (an
# archived snapshot). That is the healthy steady state and it must produce no
# warning at all — otherwise the check punishes the exact behaviour it is
# trying to encourage.
# ---------------------------------------------------------------------------
TC="TC-SIB-7: drained loop with an archive is silent"
state=$(mktemp -d); repo=$(mktemp -d)
mkdir -p "$state/consumed-lessons"
printf '{"finding":"already folded","verdict":"v","origin":"o"}\n' > "$state/consumed-lessons/pending-lessons-105.jsonl"
OUT=$(run_backlog "$state" "$repo")
W=$(warn_count "$OUT")
if [[ "$OUT" == NONZERO_EXIT* ]]; then
  fail_test "$TC" "helper exited nonzero: $OUT"
elif [[ "$W" -ne 0 ]]; then
  fail_test "$TC" "expected 0 warnings for a drained loop, got $W: $OUT"
else
  pass_test "$TC (0 warnings)"
fi
rm -rf "$state" "$repo"

# ---------------------------------------------------------------------------
# TC-SIB-8: a ZERO-RECORD snapshot must not destroy the record count.
#
# WHY this is the case the rest of the file was missing: every fixture above
# uses a snapshot with at least one record, so nothing ever exercised the
# empty-file boundary. `count_records` sums with
#   total=$(( total + $(grep -c . "$f" 2>/dev/null || echo 0) ))
# and `grep -c .` on a file with zero NON-BLANK lines prints "0" while exiting
# 1 — so the `|| echo 0` fires ON TOP of grep's own output and the substitution
# yields the two-line string "0\n0". That is not an arithmetic expression, so
# the expansion fails; because the whole function runs inside a command
# substitution, the failure aborts that subshell before its closing `printf`,
# and the count comes back as the EMPTY STRING. The report then reads
# "~ record(s)" and every other file's records are lost with it — position in
# `find` order is irrelevant, one such file blanks the whole total.
#
# This is reachable from committed code, not just a hand-made fixture:
# scripts/pr-postmerge-fold.sh folds captures with
# `cat "$SRC" >> "$PENDING_LESSONS_FILE"`, and the `>>` redirect CREATES the
# target before `cat` runs — so the very branch that logs "could not fold …
# preserving capture file" leaves a 0-byte pending-lessons snapshot behind.
#
# The assertion is on the REPORTED NUMBER, not merely on "a warning appeared":
# the under-report here is silent, and a test that only counted warnings would
# stay green while the count itself went missing.
# ---------------------------------------------------------------------------
TC="TC-SIB-8: a 0-record deviation snapshot does not blank the record count"
state=$(mktemp -d); repo=$(mktemp -d)
mk_dev_snapshot "$state/pending-deviations-1.log" 0   # 0 records — the missing fixture
mk_dev_snapshot "$state/pending-deviations-2.log" 2
mk_dev_snapshot "$state/pending-deviations-3.log" 3
OUT=$(run_backlog "$state" "$repo")
DEV_LINE=$(printf '%s\n' "$OUT" | grep '^WARN: ' | grep 'deviation snapshot' | head -1)
# Pull the number the report actually printed out of "(~N record(s); …".
GOT_RECORDS=$(printf '%s' "$DEV_LINE" | sed -n 's/.*(~\([^ ]*\) record(s).*/\1/p')
if [[ "$OUT" == NONZERO_EXIT* ]]; then
  fail_test "$TC" "helper exited nonzero: $OUT"
elif [[ -z "$DEV_LINE" ]]; then
  fail_test "$TC" "no deviation backlog warning emitted at all: $OUT"
elif [[ "$GOT_RECORDS" != "5" ]]; then
  fail_test "$TC" "record count is '$GOT_RECORDS', expected 5 (0+2+3) — a zero-record snapshot blanked the total: $DEV_LINE"
elif printf '%s\n' "$OUT" | grep -qi 'syntax error'; then
  fail_test "$TC" "the helper leaked a shell diagnostic to stderr: $OUT"
else
  pass_test "$TC (reports 5 records across 3 snapshots, one of them empty)"
fi
rm -rf "$state" "$repo"

# ---------------------------------------------------------------------------
# TC-SIB-9: the same boundary reached by BLANK LINES rather than by 0 bytes.
#
# WHY a second fixture for one bug: the trigger is "zero NON-BLANK lines", not
# "zero bytes", and those are different files. A fix that special-cased empty
# files (`[[ -s "$f" ]] || continue`) would make TC-SIB-8 pass while this case
# still failed, so this is what stops the narrow fix from looking complete.
# `grep -c .` counts lines containing at least one character, so a file of
# three newlines prints 0 and exits 1 exactly as a 0-byte file does — verified:
# a 3-byte "\n\n\n" snapshot reproduces the blanked count.
# ---------------------------------------------------------------------------
TC="TC-SIB-9: a blank-lines-only snapshot does not blank the record count"
state=$(mktemp -d); repo=$(mktemp -d)
printf '\n\n\n' > "$state/pending-deviations-4.log"   # 3 bytes, zero records
mk_dev_snapshot "$state/pending-deviations-5.log" 4
OUT=$(run_backlog "$state" "$repo")
DEV_LINE=$(printf '%s\n' "$OUT" | grep '^WARN: ' | grep 'deviation snapshot' | head -1)
GOT_RECORDS=$(printf '%s' "$DEV_LINE" | sed -n 's/.*(~\([^ ]*\) record(s).*/\1/p')
if [[ "$OUT" == NONZERO_EXIT* ]]; then
  fail_test "$TC" "helper exited nonzero: $OUT"
elif [[ -z "$DEV_LINE" ]]; then
  fail_test "$TC" "no deviation backlog warning emitted at all: $OUT"
elif [[ "$GOT_RECORDS" != "4" ]]; then
  fail_test "$TC" "record count is '$GOT_RECORDS', expected 4 — a blank-lines-only snapshot blanked the total: $DEV_LINE"
else
  pass_test "$TC (reports 4 records; the whitespace-only snapshot contributes 0)"
fi
rm -rf "$state" "$repo"

# ---------------------------------------------------------------------------
# TC-SIB-10: the LESSONS half has the same boundary, and is the half a
# committed code path can actually reach.
#
# WHY both halves are pinned: `count_records` is shared, but the two callers
# pass different arguments (the lessons call passes the deferred-queue
# exclusion), so a fix applied to one call site would not necessarily cover the
# other. This fixture is the exact on-disk state that
# scripts/pr-postmerge-fold.sh's failed-fold branch leaves behind: a 0-byte
# pending-lessons-<PR>.jsonl created by the `>>` redirect next to a real one.
# ---------------------------------------------------------------------------
TC="TC-SIB-10: a 0-record lessons snapshot does not blank the lessons count"
state=$(mktemp -d); repo=$(mktemp -d)
: > "$state/pending-lessons-77.jsonl"                 # the failed-fold leftover
printf '{"finding":"a"}\n{"finding":"b"}\n' > "$state/pending-lessons-88.jsonl"
OUT=$(run_backlog "$state" "$repo")
LESSON_LINE=$(printf '%s\n' "$OUT" | grep '^WARN: ' | grep -i 'lessons snapshot' | head -1)
GOT_RECORDS=$(printf '%s' "$LESSON_LINE" | sed -n 's/.*(~\([^ ]*\) record(s).*/\1/p')
if [[ "$OUT" == NONZERO_EXIT* ]]; then
  fail_test "$TC" "helper exited nonzero: $OUT"
elif [[ -z "$LESSON_LINE" ]]; then
  fail_test "$TC" "no lessons backlog warning emitted at all: $OUT"
elif [[ "$GOT_RECORDS" != "2" ]]; then
  fail_test "$TC" "record count is '$GOT_RECORDS', expected 2 — a zero-record lessons snapshot blanked the total: $LESSON_LINE"
else
  pass_test "$TC (reports 2 records across 2 snapshots, one of them empty)"
fi
rm -rf "$state" "$repo"

# ---------------------------------------------------------------------------
# TC-SIB-11: END-TO-END — the WRITER's count and the READER's count agree
#
# WHY this is the most valuable case in either suite: every other test drives
# the fold OR the reporter, never both. scripts/pr-postmerge-fold.sh WRITES the
# snapshots and scripts/selfimprovement-backlog.sh READS them, and nothing
# anywhere held the two together. That seam is where this loop has failed
# repeatedly and silently:
#   - the writer's awk over-captured, so ~half of the 21 records in
#     pending-deviations-122.log were phase-card metadata rather than deviations
#     (fixed on this branch; TC-STL-25 pins the awk itself);
#   - reader and writer must agree on WHERE state lives — the whole reason
#     selfimprovement-backlog.sh defaults STATE_DIR to "$HOME/.claude" and not
#     to $CLAUDE_HOME is that reading a different directory than the writer
#     writes to reports zero forever while a real queue piles up next door;
#   - reader and writer must agree on what a RECORD is. The writer reports
#     `wc -l` (scripts/pr-postmerge-fold.sh) and the reader counts `grep -c .`
#     (non-blank lines). Those agree only while the format stays one record per
#     non-blank line; nothing but this test would notice if it stopped.
#
# So: run the REAL fold against a REAL handover.md fixture, then run the REAL
# reporter over the very directory the fold just wrote to, and require the
# writer's number, the reader's number and the fixture's known truth to be the
# same number. Nothing here is simulated except `gh`, stubbed to answer with a
# seconds-old merge so the test is offline and deterministic. The stub must
# ANSWER rather than fail: since issue #154 the fold reads the merge time to
# decide whether handover.md is this PR's work at all, and a failing stub would
# quietly convert this case into a test of the refusal path.
#
# The fixture is built so the count is only right if the writer is right: two
# real deviations (one of them multi-line, which must stay ONE record), a
# `- None observed.` section that must be skipped, and phase-card metadata
# bullets under a later `## ` heading that must NOT be captured. Truth = 3.
#
# PROVEN RED: reverting the writer's `inside=0` reset on `/^## /` makes the fold
# report 7 and the reporter report ~7 against the same fixture — the two still
# AGREE with each other, which is exactly why the known-truth assertion has to
# be here as well as the agreement assertion.
# ---------------------------------------------------------------------------
TC="TC-SIB-11: end-to-end — fold writes N, reporter reads the same N"
FOLD_SCRIPT="$SCRIPT_DIR/pr-postmerge-fold.sh"
if [[ ! -f "$FOLD_SCRIPT" ]]; then
  fail_test "$TC" "scripts/pr-postmerge-fold.sh not found at $FOLD_SCRIPT — the writer half of the loop is missing"
elif ! command -v git >/dev/null 2>&1; then
  fail_test "$TC" "git is not installed — the fold verifies the checkout's origin before reading handover.md, so this end-to-end case cannot run"
else
  e2e_home=$(mktemp -d); e2e_repo=$(mktemp -d); e2e_bin=$(mktemp -d); e2e_knowledge=$(mktemp -d)
  mkdir -p "$e2e_home/.claude" "$e2e_repo/.claude"
  # Offline `gh` stub: the fold reads the PR's merge time, head branch and
  # title/body from ONE `gh pr view`. A unit test must not depend on the network
  # or on an authed gh.
  #
  # ⛔ IT NO LONGER `exit 1`s, AND THE DIFFERENCE MATTERS. ⛔ The lessons half
  # tolerated a failing gh (`|| echo ''`), but the deviation half now REFUSES to
  # snapshot when it cannot establish that handover.md is this PR's work — and an
  # unreadable merge time is one of the two ways it cannot (issue #154; the gate
  # itself is pinned by TC-STL-74 in test-sync-toolbox-lessons.sh). A failing stub
  # would turn this end-to-end case into an assertion about the refusal path, and
  # the writer/reader agreement it exists to protect would stop being tested at
  # all. The stub answers with a merge seconds old — /merge-pr's at-merge call.
  e2e_merged_at=$(date -u -r "$(date -u +%s)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$(date -u +%s)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\t%%s\\t%%s\\n" "%s" "fixture/branch" "fixture PR title and body"\n' "$e2e_merged_at"
  } > "$e2e_bin/gh"; chmod +x "$e2e_bin/gh"
  # The fold refuses to read a handover.md from a checkout whose origin is not
  # baselito/ai-engineering, so the fixture repo has to carry that remote. No
  # network is touched — `git remote add` only writes .git/config.
  git -C "$e2e_repo" init -q >/dev/null 2>&1
  git -C "$e2e_repo" remote add origin https://github.com/baselito/ai-toolbox.git >/dev/null 2>&1

  # 3 real deviations. Everything else here is a decoy the writer must reject.
  cat > "$e2e_repo/.claude/handover.md" <<'E2E_HANDOVER'
## Discovery
- Agent: discovery (Opus)
- Jira: n/a — toolbox self-change

### Deviations
- Skipped the planner because the change looked like a one-liner.
  It was not; three callsites branched on the same axis.
- Posted the phase card before the Jira comment.

## Implementation

- Agent: implementation (Opus)
- Model: opus

### Deviations
- None observed.

## Verification
- Agent: verification

### Deviations
- Ran the suite once, not twice, after the fix.

## PR Creation
- Agent: pr (Opus)
E2E_HANDOVER

  E2E_TRUTH=3
  E2E_FOLD_OUT=$(PATH="$e2e_bin:$PATH" HOME="$e2e_home" bash "$FOLD_SCRIPT" baselito ai-engineering 4242 "$e2e_repo" 2>&1)
  E2E_FOLD_RC=$?
  E2E_SNAP="$e2e_home/.claude/pending-deviations-4242.log"
  # What the WRITER says it wrote.
  E2E_FOLD_N=$(printf '%s\n' "$E2E_FOLD_OUT" | sed -n 's/^Snapshotted \([0-9][0-9]*\) deviation(s).*/\1/p' | head -1)
  # What is ACTUALLY on disk (one JSONL record per line, blank lines excluded).
  E2E_FILE_N=$(grep -c . "$E2E_SNAP" 2>/dev/null || true)
  # What the READER reports, over the directory the fold just wrote to.
  E2E_REPORT=$(run_backlog "$e2e_home/.claude" "$e2e_knowledge")
  E2E_DEV_LINE=$(printf '%s\n' "$E2E_REPORT" | grep '^WARN: ' | grep 'deviation snapshot' | head -1)
  E2E_READ_N=$(printf '%s' "$E2E_DEV_LINE" | sed -n 's/.*(~\([^ ]*\) record(s).*/\1/p')
  E2E_SNAP_N=$(printf '%s' "$E2E_DEV_LINE" | sed -n 's/^WARN: \([0-9][0-9]*\) deviation snapshot.*/\1/p')

  E2E_FAILURES=()
  [[ "$E2E_FOLD_RC" -eq 0 ]] || E2E_FAILURES+=("fold exited $E2E_FOLD_RC — it is best-effort telemetry and must never fail its caller: $E2E_FOLD_OUT")
  [[ -f "$E2E_SNAP" ]] || E2E_FAILURES+=("fold wrote no snapshot at $E2E_SNAP — the reader has nothing to read: $E2E_FOLD_OUT")
  [[ "$E2E_FOLD_N" == "$E2E_TRUTH" ]] || E2E_FAILURES+=("the WRITER reported '${E2E_FOLD_N:-none}' deviation(s), fixture truth is $E2E_TRUTH — 'None observed.' and phase-card metabullets under a later '## ' heading must not be captured, and a multi-line deviation must stay ONE record")
  [[ "$E2E_FILE_N" == "$E2E_TRUTH" ]] || E2E_FAILURES+=("the snapshot on disk holds $E2E_FILE_N non-blank line(s), fixture truth is $E2E_TRUTH")
  [[ "$E2E_SNAP_N" == "1" ]] || E2E_FAILURES+=("the READER reports '${E2E_SNAP_N:-none}' snapshot(s), expected 1 — reader and writer disagree about the state directory")
  # The seam itself: writer's count == reader's count. This is the assertion
  # that fires if either side changes what it counts (wc -l vs grep -c) without
  # the other following.
  [[ -n "$E2E_READ_N" && "$E2E_READ_N" == "$E2E_FOLD_N" ]] || E2E_FAILURES+=("writer/reader COUNT DISAGREEMENT: fold said '${E2E_FOLD_N:-none}', reporter said '${E2E_READ_N:-none}' over the same file — the two halves no longer agree on what one record is")

  # Second leg: the writer's first-writer-wins guard, observed through the
  # reader. Both callers (/merge-pr at merge time, /review-pr's fallback later)
  # can fold the SAME PR, and by the second call handover.md may already belong
  # to a different task. Regenerating then would overwrite good telemetry with
  # someone else's. Rewrite the handover with five unrelated deviations, fold
  # the same PR again, and require the reported count to stay at the truth.
  cat > "$e2e_repo/.claude/handover.md" <<'E2E_STALE'
## A Later Unrelated Task
### Deviations
- stale one
- stale two
- stale three
- stale four
- stale five
E2E_STALE
  E2E_FOLD2_OUT=$(PATH="$e2e_bin:$PATH" HOME="$e2e_home" bash "$FOLD_SCRIPT" baselito ai-engineering 4242 "$e2e_repo" 2>&1)
  E2E_REPORT2=$(run_backlog "$e2e_home/.claude" "$e2e_knowledge")
  E2E_READ2_N=$(printf '%s\n' "$E2E_REPORT2" | grep '^WARN: ' | grep 'deviation snapshot' | head -1 | sed -n 's/.*(~\([^ ]*\) record(s).*/\1/p')
  [[ "$E2E_READ2_N" == "$E2E_TRUTH" ]] || E2E_FAILURES+=("after a SECOND fold of the same PR against a stale handover, the reporter says '${E2E_READ2_N:-none}' record(s) instead of $E2E_TRUTH — the idempotency guard stopped protecting the first writer's capture: $E2E_FOLD2_OUT")

  if [[ ${#E2E_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (fold wrote $E2E_FOLD_N, disk holds $E2E_FILE_N, reporter reads ~$E2E_READ_N across $E2E_SNAP_N snapshot(s); re-fold of a stale handover left it at $E2E_READ2_N)"
  else
    fail_test "$TC" "$(printf '%s; ' "${E2E_FAILURES[@]}")"
  fi
  rm -rf "$e2e_home" "$e2e_repo" "$e2e_bin" "$e2e_knowledge"
fi

# ---------------------------------------------------------------------------
# TC-SIB-12: an UNREADABLE snapshot must never vanish from the queue report
#
# WHY: `chmod 000` on a snapshot is not exotic — a root-owned file, a
# permissions accident, or a partial write by a racing fold all produce it, and
# it is the exact state that used to make the CONSUMER declare a file "fully
# decided" and archive it (commands/review-pr.md now fails closed and counts it;
# TC-STL-24 (9) pins that). The reporter's job is narrower but load-bearing: an
# unreadable file must still be COUNTED and NAMED, because the one thing that
# must never happen is a queued snapshot the report does not mention.
#
# ⛔ THE FORMER "KNOWN GAP" IS NOW CLOSED, AND (c) STILL PINS 4. ⛔ This test
# used to record a deliberate gap: the reported RECORD count was short by the
# unreadable file's records with NOTHING saying why, because `grep -c .` on an
# unreadable file prints nothing and its records silently became zero. That was
# a silent under-report from the script written to end silent under-reports.
#
# What changed: the reporter now skips unreadable files EXPLICITLY in
# count_records, counts them separately, and emits its own `WARN:` naming them
# and saying the record total is a FLOOR, not a count. What did NOT change is
# the number in (c): 4 is still correct, because the locked file's records are
# UNKNOWN, not 2 — the reporter cannot read them, and inventing 6 would be
# asserting a number nobody measured. So (c) stays at the readable-only total
# and (d) below asserts the UNKNOWN is declared rather than swallowed.
# ---------------------------------------------------------------------------
TC="TC-SIB-12: an unreadable snapshot is still counted and named, never silently dropped"
state=$(mktemp -d); repo=$(mktemp -d)
# 4 readable records + 2 locked away. Distinct counts, so an assertion can tell
# "the readable ones survived" from "everything was counted" from "a file was
# counted instead of its records".
mk_dev_snapshot "$state/pending-deviations-readable.log" 4
mk_dev_snapshot "$state/pending-deviations-locked.log" 2
chmod 000 "$state/pending-deviations-locked.log"
if [[ -r "$state/pending-deviations-locked.log" ]] && [[ "$IS_ROOT" == "true" ]]; then
  # ROOT: the permission bits are simply not enforced, so `chmod 000` cannot make
  # anything unreadable and the case has no premise. SKIP, do not fail — this
  # suite is run by verify.sh, and failing here made verify.sh unpassable in any
  # root container or root CI job even when the reporter was entirely correct.
  # The skip is reported, so the lost coverage is visible rather than silent.
  skip_test "$TC" "running as root (EUID 0) — chmod 000 is not enforced, so an unreadable snapshot cannot be created; run the suite as a non-root user to exercise this case"
elif [[ -r "$state/pending-deviations-locked.log" ]]; then
  # NOT root and STILL readable: the filesystem itself is ignoring mode bits
  # (some network/container mounts do). That is a real environment problem worth
  # a failure rather than a skip, because unlike the root case it is not the
  # expected, documented way to run this suite.
  fail_test "$TC" "could not make the fixture unreadable (chmod 000 still readable as a non-root user — a filesystem without mode enforcement); this case cannot be exercised here"
else
  OUT=$(run_backlog "$state" "$repo")
  DEV_LINE=$(printf '%s\n' "$OUT" | grep '^WARN: ' | grep 'deviation snapshot' | head -1)
  GOT_SNAPS=$(printf '%s' "$DEV_LINE" | sed -n 's/^WARN: \([0-9][0-9]*\) deviation snapshot.*/\1/p')
  GOT_RECORDS=$(printf '%s' "$DEV_LINE" | sed -n 's/.*(~\([^ ]*\) record(s).*/\1/p')
  if [[ "$OUT" == NONZERO_EXIT* ]]; then
    fail_test "$TC" "helper exited nonzero: $OUT"
  # (a) The unreadable file is still part of the queue. FALSIFYING EDIT: add
  # `-readable` to count_files' find, or skip unreadable files in the sweep —
  # the snapshot then disappears from the report entirely, which is the silent
  # under-report this whole script exists to end.
  elif [[ "$GOT_SNAPS" != "2" ]]; then
    fail_test "$TC" "reported '$GOT_SNAPS' snapshot(s), expected 2 — an unreadable snapshot must stay in the count, or a queued file goes unmentioned: $OUT"
  # (b) The count is still a NUMBER. FALSIFYING EDIT: drop the `${n:-0}` default
  # in count_records — an unreadable file makes `grep -c` print nothing, `n` is
  # then empty, `$(( total + ))` is a fatal arithmetic error, the subshell dies
  # before its closing printf, and the caller gets the EMPTY STRING: the report
  # reads "~ record(s)" and every other file's records vanish with it.
  elif ! printf '%s' "$GOT_RECORDS" | grep -qE '^[0-9]+$'; then
    fail_test "$TC" "record count is '$GOT_RECORDS', not a number — one unreadable file blanked the whole total: $DEV_LINE"
  # (c) EXACTLY the readable file's 4 records — no fewer (records lost), no more
  # (records invented), and not 2 (files counted instead of records).
  # FALSIFYING EDITS: replace `grep -c .` with a per-file constant (`n=1`) and
  # the total becomes 2; point it at a pattern the records do not match and it
  # becomes 0; teach the reporter to account for unreadable records and it
  # becomes 6 — in that last case the fix is to change this 4 to 6 AND delete
  # the known-gap paragraph above, not to loosen the assertion.
  elif [[ "$GOT_RECORDS" != "4" ]]; then
    fail_test "$TC" "record count is '$GOT_RECORDS', expected exactly 4 — the readable snapshot's records. The locked file's 2 are UNKNOWN, not 2 and not 0, so 6 would be an invented number: the count stays a floor and (d) below is what declares the unknown: $DEV_LINE"
  # (d) The UNKNOWN is DECLARED, not swallowed. A count that is short by an
  # unstated amount reads as complete, which is this script's own failure mode.
  # FALSIFYING EDITS: delete the `$DEV_UNREADABLE` WARN block from the reporter;
  # or fold the unreadable count into the record total instead of reporting it.
  elif ! printf '%s\n' "$OUT" | grep '^WARN: ' | grep -qi 'could not be read'; then
    fail_test "$TC" "no WARN says a snapshot could not be read — the record total is short by an UNKNOWN amount with nothing saying so, which reads as a complete count: $OUT"
  elif ! printf '%s\n' "$OUT" | grep '^WARN: ' | grep -q 'UNKNOWN'; then
    fail_test "$TC" "the unreadable-snapshot WARN does not say the count is UNKNOWN — 'never coerce an unreadable file to zero' has to be visible in the output, not just in a comment: $OUT"
  # (e) And it names the specific file, so a human can go fix it.
  # FALSIFYING EDIT: drop \$DEV_UNREADABLE_NAMES from the WARN line.
  elif ! printf '%s\n' "$OUT" | grep '^WARN: ' | grep -q 'pending-deviations-locked.log'; then
    fail_test "$TC" "the unreadable-snapshot WARN does not name pending-deviations-locked.log — an unreadable file nobody can identify cannot be fixed: $OUT"
  elif ! printf '%s\n' "$OUT" | grep -q 'pending-deviations-locked.log\|pending-deviations-readable.log'; then
    fail_test "$TC" "the report names no queued file at all: $OUT"
  else
    pass_test "$TC (2 snapshots counted including the unreadable one, count numeric and exactly 4 — the readable records are intact — and the unreadable file is named in a WARN declaring its records UNKNOWN)"
  fi
fi
chmod 644 "$state/pending-deviations-locked.log" 2>/dev/null || true
rm -rf "$state" "$repo"

# ---------------------------------------------------------------------------
# TC-SIB-13: a MISSING state dir is "nothing captured", not "drained"
#
# WHY this is distinct from TC-SIB-1 (an EMPTY state dir): both are quiet, so a
# warning count cannot tell them apart — the difference is entirely in what the
# report SAYS, and the difference matters. "no self-improvement backlog —
# deviations and lessons are both drained" asserts the loop ran and emptied
# itself. On a path that does not exist, nothing was ever captured and no loop
# ever ran, and the honest message names the path it looked at.
#
# The failure this protects against is not cosmetic. STATE_DIR is
# caller-supplied, and the reader/writer split is the documented hazard at the
# top of the helper: the writer writes literally to "$HOME/.claude" while
# verify.sh's CLAUDE_HOME can resolve elsewhere (APPDATA/Claude on Windows). If
# the reader is ever pointed at the wrong path, a "both drained" reply hides
# that completely, while "no state directory yet (<path>)" puts the wrong path
# on screen where a human can see it.
# ---------------------------------------------------------------------------
TC="TC-SIB-13: a missing state dir says 'nothing captured' and names the path"
missing=$(mktemp -d); rmdir "$missing"          # a path that definitely does not exist
repo=$(mktemp -d)
OUT=$(run_backlog "$missing" "$repo")
W=$(warn_count "$OUT")
if [[ "$OUT" == NONZERO_EXIT* ]]; then
  fail_test "$TC" "helper exited nonzero: $OUT"
elif [[ "$W" -ne 0 ]]; then
  fail_test "$TC" "expected 0 warnings for a path that does not exist, got $W: $OUT"
# FALSIFYING EDIT: delete the `[[ ! -d "$STATE_DIR" ]]` early return. The run
# then falls through to the normal report, finds nothing, and claims "no
# self-improvement backlog — deviations and lessons are both drained" — the two
# checks below are what tell those two states apart.
elif ! printf '%s\n' "$OUT" | grep -q 'state directory'; then
  fail_test "$TC" "the report does not distinguish 'no state directory' from a drained queue: $OUT"
# Bound to the `OK:` sign-off line for the same reason TC-SIB-14 is: "drained"
# is a claim only when the report ends on it, and an INFO line may legitimately
# use the word while explaining a hazard.
elif printf '%s\n' "$OUT" | grep '^OK: ' | grep -q 'drained'; then
  fail_test "$TC" "a nonexistent state dir was reported as DRAINED — that asserts a triage loop completed when nothing was ever captured: $OUT"
# FALSIFYING EDIT: drop "$STATE_DIR" from the message. The reader would then say
# a directory is missing without saying WHICH — the one datum that exposes a
# reader/writer path mismatch.
elif ! printf '%s\n' "$OUT" | grep -qF "$missing"; then
  fail_test "$TC" "the report does not name the path it checked ($missing) — a wrong STATE_DIR would be invisible: $OUT"
else
  pass_test "$TC (0 warnings, names the missing path, does not claim 'drained')"
fi
rm -rf "$repo"

# ---------------------------------------------------------------------------
# TC-SIB-14: an UNLISTABLE state dir is UNKNOWN, never "drained"
#
# WHY this is the sharpest case in the file: every count in the reporter comes
# from a `find` carrying `2>/dev/null`. That suppression is right for a missing
# file and catastrophic for a directory that cannot be traversed — `find` writes
# its error to the discarded stream, returns nothing, both halves count zero, and
# the script signs off "OK: no self-improvement backlog — deviations and lessons
# are both drained" over a queue holding real snapshots it never managed to open.
# A reporter written to end silent under-reporting would be printing SUCCESS on
# state it could not read. No attacker needed: a root-owned ~/.claude, a bad
# chmod, or a STATE_DIR the caller cannot traverse all produce it.
#
# The fixture puts a REAL snapshot inside before locking the directory, so
# "drained" would be a concrete lie rather than a technicality.
#
# FALSIFYING EDIT: delete the `[[ ! -r "$STATE_DIR" || ! -x "$STATE_DIR" ]]`
# probe from the reporter — the run then falls through, counts zero of
# everything, and prints the drained OK line.
# ---------------------------------------------------------------------------
TC="TC-SIB-14: an unlistable state dir reports UNKNOWN, never drained"
state=$(mktemp -d); repo=$(mktemp -d)
mk_dev_snapshot "$state/pending-deviations-42.log" 3
chmod 000 "$state"
if [[ -x "$state" && -r "$state" ]] && [[ "$IS_ROOT" == "true" ]]; then
  # ROOT: same reason as TC-SIB-12 — root traverses a 000 directory regardless of
  # the mode, so an unlistable directory cannot be created and the case has no
  # premise. SKIP so verify.sh stays passable in root CI; the mode is restored
  # first so the temp dir can be removed.
  chmod 755 "$state"
  skip_test "$TC" "running as root (EUID 0) — chmod 000 does not block traversal, so an unlistable state dir cannot be created; run the suite as a non-root user to exercise this case"
elif [[ -x "$state" && -r "$state" ]]; then
  # NOT root and still traversable: the filesystem is ignoring mode bits. Real
  # environment problem, so this stays a failure.
  chmod 755 "$state"
  fail_test "$TC" "could not make the fixture directory unlistable (chmod 000 still readable+searchable as a non-root user — a filesystem without mode enforcement); this case cannot be exercised here"
else
  OUT=$(run_backlog "$state" "$repo")
  chmod 755 "$state"
  W=$(warn_count "$OUT")
  if [[ "$OUT" == NONZERO_EXIT* ]]; then
    fail_test "$TC" "helper exited nonzero: $OUT — this is a reporter and must always exit 0, even when it can read nothing"
  # Matched on the `OK:` line specifically: "drained" is a CLAIM only when it is
  # the sign-off. A bare `grep -q 'drained'` also hit the INFO line that
  # EXPLAINS this hazard ("would otherwise report a full queue as drained"), so
  # the assertion failed on the reporter's own documentation of the bug it fixes.
  elif printf '%s\n' "$OUT" | grep '^OK: ' | grep -q 'drained'; then
    fail_test "$TC" "an unlistable state dir was reported as DRAINED — the report asserts the loop emptied itself over state it could not open, with 3 real records sitting inside: $OUT"
  elif [[ "$W" -lt 1 ]]; then
    fail_test "$TC" "no WARN for a state dir that cannot be listed — the condition would be entirely invisible: $OUT"
  elif ! printf '%s\n' "$OUT" | grep -q 'UNKNOWN'; then
    fail_test "$TC" "the WARN does not say the backlog is UNKNOWN — 'not zero' is the whole point of the message: $OUT"
  elif ! printf '%s\n' "$OUT" | grep -qF "$state"; then
    fail_test "$TC" "the report does not name the directory it could not list ($state) — a wrong or unreadable STATE_DIR would be unfixable: $OUT"
  else
    pass_test "$TC (exit 0, WARN naming the path, says UNKNOWN, never claims drained)"
  fi
fi
rm -rf "$state" "$repo"

# ---------------------------------------------------------------------------
# TC-SIB-17: verify.sh's CALL SITE must not swallow a broken reporter
#            (executed against the real block extracted from scripts/verify.sh)
#
# WHY: every test above proves the reporter reports. None of them prove anybody
# HEARS it. verify.sh consumes this helper through a process substitution with
# stderr sent to /dev/null, so a helper that could not run at all — deleted
# between the `-f` test and the call, a bad interpreter, a syntax error, an exec
# failure under memory pressure — produced no output and no complaint, and
# verify.sh then said nothing whatever about the backlog. "Said nothing" reads
# exactly like "no backlog": the silent stall this whole check exists to detect,
# recreated inside the detector. `$?` is unavailable after a process substitution,
# so the status has to be carried out of it deliberately.
#
# WHY THE PROCESS SUBSTITUTION MUST SURVIVE THE FIX, and why leg 1 pins it:
# `warn()` increments a GLOBAL counter that verify.sh's summary reads. A pipe
# would run the loop in a subshell and every increment would be lost, downgrading
# a real backlog from "N warning(s)" to "All checks passed" — measured directly:
# pipe form yields WARNINGS=0 where the shipped form yields 2. So leg 1 asserts
# the counter actually moved in the PARENT shell, which is the property a
# well-meaning "simplify to a pipe" refactor would silently destroy.
#
# HOW: the block is EXTRACTED from scripts/verify.sh and executed against a stub
# reporter, so it cannot drift from production the way a re-implementation would.
# REPO_ROOT is pointed at a temp tree whose scripts/selfimprovement-backlog.sh is
# the stub, which means the extracted code's own path construction and `-f` test
# run unmodified.
#
# FALSIFYING EDITS (each measured, with the leg that actually caught it):
#   - discard the exit status (`SIB_RC=0` instead of reading the rc file): leg 5
#     goes RED and ONLY leg 5 does. Measured: with legs 1-4 alone this mutation
#     left the suite fully green, because in those legs a nonzero exit always
#     coincides with zero output and the `SIB_LINES` branch covered it. Leg 5 (a
#     partial run) is the reason the status check is pinned at all.
#   - delete the `SIB_LINES -eq 0` check: leg 3 goes RED.
#   - change `< <(...)` to a pipe: RED either way, and which assertion fires
#     depends on how much of the block moves into the subshell. Loop only →
#     `SIB_LINES` is lost, so leg 1 trips the "UNKNOWN on the success path"
#     assertion. Loop AND the guards → every `warn` is lost too, and legs 1 and 2
#     both trip the WARNINGS-counter assertion (measured: COUNTERS|0|0). Both
#     shapes are caught; only the message differs.
#   - make the UNKNOWN warnings into `fail`/`info` instead of `warn`: legs 2-5 go
#     RED — this is a reporter, and a warning is the only correct volume.
# ---------------------------------------------------------------------------
TC="TC-SIB-17: verify.sh reports a broken backlog reporter instead of silence"
VERIFY_SH="$(cd "$SCRIPT_DIR/.." && pwd)/scripts/verify.sh"
# Anchors: the block starts at its own script-path assignment and ends at the
# line before verify.sh's next `# ---...` section separator. Both are structural
# features of verify.sh, not prose, so an edit that moves the block still finds
# it and an edit that DELETES it makes the extraction fail loudly below.
SIB17_LO=$(grep -nF 'SELFIMPROVEMENT_BACKLOG_SCRIPT="$REPO_ROOT/scripts/selfimprovement-backlog.sh"' "$VERIFY_SH" 2>/dev/null | head -1 | cut -d: -f1)
SIB17_HI=""
if [[ -n "$SIB17_LO" ]]; then
  SIB17_HI=$(awk -v s="$SIB17_LO" 'NR > s && /^# -{20,}$/ { print NR - 1; exit }' "$VERIFY_SH")
fi
if [[ ! -f "$VERIFY_SH" ]]; then
  fail_test "$TC" "cannot locate scripts/verify.sh ($VERIFY_SH)"
elif [[ -z "$SIB17_LO" || -z "$SIB17_HI" || "$SIB17_HI" -le "$SIB17_LO" ]]; then
  fail_test "$TC" "cannot delimit the backlog-reporting block in scripts/verify.sh (lo='$SIB17_LO', hi='$SIB17_HI') — the SELFIMPROVEMENT_BACKLOG_SCRIPT assignment and the following section separator are what this test extracts between"
else
  SIB17_BLOCK=$(sed -n "${SIB17_LO},${SIB17_HI}p" "$VERIFY_SH")
  A17_FAILURES=()

  # Build a runner: verify.sh's own reporting helpers (same WARNINGS counter
  # semantics), then the extracted block verbatim, then the counters so the test
  # can assert on the PARENT shell's state rather than only on printed text.
  sib17_run() {
    local stub_body="$1" home_dir out
    local root; root=$(mktemp -d)
    mkdir -p "$root/scripts"
    printf '%s\n' "$stub_body" > "$root/scripts/selfimprovement-backlog.sh"
    home_dir=$(mktemp -d)
    {
      printf 'ERRORS=0\nWARNINGS=0\n'
      printf 'ok()   { printf "OK|%%s\\n" "$1"; }\n'
      printf 'warn() { printf "WARN|%%s\\n" "$1"; WARNINGS=$((WARNINGS + 1)); }\n'
      printf 'fail() { printf "FAIL|%%s\\n" "$1"; ERRORS=$((ERRORS + 1)); }\n'
      printf 'info() { printf "INFO|%%s\\n" "$1"; }\n'
      printf 'REPO_ROOT="%s"\n' "$root"
      printf '%s\n' "$SIB17_BLOCK"
      printf 'printf "COUNTERS|%%s|%%s\\n" "$WARNINGS" "$ERRORS"\n'
    } > "$root/runner.sh"
    out=$(HOME="$home_dir" bash "$root/runner.sh" 2>&1)
    printf '%s\n' "$out"
    rm -rf "$root" "$home_dir"
  }
  sib17_warnings() { printf '%s\n' "$1" | sed -n 's/^COUNTERS|\([0-9]*\)|.*/\1/p' | head -1; }

  # --- leg 1: a healthy reporter. VACUITY GUARD + the process-substitution pin.
  A17_OUT1=$(sib17_run '#!/usr/bin/env bash
echo "WARN: 3 deviation snapshot(s) awaiting triage"
echo "INFO: explanatory line"
exit 0')
  A17_W1=$(sib17_warnings "$A17_OUT1")
  [[ "$A17_W1" == "1" ]] \
    || A17_FAILURES+=("leg 1: WARNINGS ended at '$A17_W1', expected 1 — a healthy reporter's WARN must reach the PARENT shell's counter. A pipe instead of the process substitution loses every increment and silently downgrades the summary to 'All checks passed': $A17_OUT1")
  printf '%s\n' "$A17_OUT1" | grep -q 'WARN|3 deviation snapshot' \
    || A17_FAILURES+=("leg 1 (vacuity guard): the extracted block did not relay the reporter's WARN line at all, so legs 2-4 would prove nothing: $A17_OUT1")
  printf '%s\n' "$A17_OUT1" | grep -qi 'UNKNOWN' \
    && A17_FAILURES+=("leg 1: a healthy reporter produced an UNKNOWN warning — the new guard is firing on the success path, which is the cry-wolf failure: $A17_OUT1")

  # --- leg 2: the reporter FAILS with no output (the silent-stall case) ---
  A17_OUT2=$(sib17_run '#!/usr/bin/env bash
exit 7')
  A17_W2=$(sib17_warnings "$A17_OUT2")
  printf '%s\n' "$A17_OUT2" | grep '^WARN|' | grep -qi 'UNKNOWN' \
    || A17_FAILURES+=("leg 2: a reporter exiting 7 with no output produced no UNKNOWN warning — verify.sh then says nothing about the backlog, which reads identically to 'no backlog': $A17_OUT2")
  [[ "${A17_W2:-0}" -ge 1 ]] \
    || A17_FAILURES+=("leg 2: WARNINGS ended at '$A17_W2' — a broken reporter must move the counter so the summary is not 'All checks passed': $A17_OUT2")
  printf '%s\n' "$A17_OUT2" | grep -q '^FAIL|' \
    && A17_FAILURES+=("leg 2: the call site FAILED the run — this is a reporter, not a gate; it must warn, never error: $A17_OUT2")

  # --- leg 3: a clean exit with NO output (a reporter that stopped reporting) ---
  A17_OUT3=$(sib17_run '#!/usr/bin/env bash
exit 0')
  printf '%s\n' "$A17_OUT3" | grep '^WARN|' | grep -qi 'UNKNOWN' \
    || A17_FAILURES+=("leg 3: a reporter that exited 0 printing NOTHING produced no warning — a helper that silently stops reporting is indistinguishable from a drained queue: $A17_OUT3")

  # --- leg 4: the reporter cannot even be PARSED (syntax error) ---
  # Distinct from leg 2: nothing inside the helper runs at all, and the complaint
  # goes to the stderr the substitution discards. This is the realistic shape of
  # the failure in this repo — verify.sh invokes the helper as `bash "$SCRIPT"`,
  # so the shebang is irrelevant and a hand-edit that unbalances a quote or a
  # `fi` is what actually produces "no output, nonzero exit, silent complaint".
  # (An earlier version of this leg used a nonexistent interpreter, which proved
  # nothing: `bash "$SCRIPT"` never consults the shebang, so the stub ran fine.)
  A17_OUT4=$(sib17_run '#!/usr/bin/env bash
if [ 1 -eq 1 ]; then
  echo "never printed"
# deliberately missing `fi` — bash exits nonzero with a parse error on stderr')
  printf '%s\n' "$A17_OUT4" | grep '^WARN|' | grep -qi 'UNKNOWN' \
    || A17_FAILURES+=("leg 4: a reporter that could not be PARSED produced no warning — its error went to the discarded stderr, so the condition was completely invisible: $A17_OUT4")

  # --- leg 5: a PARTIAL run — output produced, then a nonzero exit ---
  # ⛔ THIS LEG IS WHAT PINS THE EXIT-STATUS CHECK ON ITS OWN. ⛔ In legs 2, 3 and
  # 4 the failure coincides with zero output, so the `SIB_LINES -eq 0` branch
  # catches all three and the `$?` plumbing is redundant there — verified by
  # mutation: replacing `SIB_RC=$(cat "$SIB_RC_FILE")` with `SIB_RC=0` left the
  # whole suite green. This leg is the shape that only the status can catch: the
  # reporter emits a real line and THEN dies (it walks the deviation half before
  # the lessons half, so a mid-run failure produces exactly this), so the report
  # looks complete and is not. Without the status check the run would relay the
  # partial output and say nothing at all about the truncation.
  A17_OUT5=$(sib17_run '#!/usr/bin/env bash
echo "WARN: 2 deviation snapshot(s) awaiting triage"
exit 5')
  printf '%s\n' "$A17_OUT5" | grep '^WARN|' | grep -qi 'UNKNOWN' \
    || A17_FAILURES+=("leg 5: a reporter that printed one line and then exited 5 produced no UNKNOWN warning — a PARTIAL report reads as a complete one, and this is the only leg the \`SIB_LINES -eq 0\` branch cannot catch, so it is the one that pins the exit-status capture: $A17_OUT5")
  printf '%s\n' "$A17_OUT5" | grep -q 'WARN|2 deviation snapshot' \
    || A17_FAILURES+=("leg 5 (vacuity guard): the partial output was not relayed at all, so this leg is not exercising a partial run: $A17_OUT5")

  if [[ ${#A17_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (healthy reporter relayed its WARN and moved the parent counter to 1; nonzero exit, empty output, an unparseable helper and a PARTIAL run that printed then died each produced an UNKNOWN warning and never a failure)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A17_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-SIB-18: verify.sh RELAYS the suite's own SKIP lines
#
# WHY: TC-SIB-12 and TC-SIB-14 skip under root, and this file claims in three
# places that a skip is "visible" rather than silent. That claim is about the
# CALLER, and the caller falsified it: verify.sh's success branch reported only
# `grep -c 'PASS:'`, so a root run printed "15 checks" instead of 17 with nothing
# saying why. The two permission fixtures vanished at the one place a human reads
# the result — a test that quietly stops running is indistinguishable from one
# that never existed, which is precisely the invisible-gap failure the reporter
# under test exists to end.
#
# Driven against the REAL block extracted from scripts/verify.sh, same technique
# and same anchors as TC-SIB-17, so it cannot drift from production.
#
# FALSIFYING EDITS: delete the `SKIP:` relay loop from verify.sh's success branch
# (leg 1 goes RED); change its `< <(...)` to a pipe (leg 2 goes RED — the warn
# increments are lost to the subshell, which is the same trap the reporter call
# site 70 lines below was fixed for).
# ---------------------------------------------------------------------------
TC="TC-SIB-18: verify.sh relays the backlog suite's SKIP lines"
SIB18_LO=$(grep -nF 'TEST_BACKLOG_SCRIPT="$REPO_ROOT/scripts/test-selfimprovement-backlog.sh"' "$VERIFY_SH" 2>/dev/null | head -1 | cut -d: -f1)
SIB18_HI=""
if [[ -n "$SIB18_LO" ]]; then
  SIB18_HI=$(awk -v s="$SIB18_LO" 'NR > s && /^# -{20,}$/ { print NR - 1; exit }' "$VERIFY_SH")
fi
if [[ ! -f "$VERIFY_SH" ]]; then
  fail_test "$TC" "cannot locate scripts/verify.sh ($VERIFY_SH)"
elif [[ -z "$SIB18_LO" || -z "$SIB18_HI" || "$SIB18_HI" -le "$SIB18_LO" ]]; then
  fail_test "$TC" "cannot delimit the backlog-suite-invocation block in scripts/verify.sh (lo='$SIB18_LO', hi='$SIB18_HI')"
else
  SIB18_BLOCK=$(sed -n "${SIB18_LO},${SIB18_HI}p" "$VERIFY_SH")
  A18_FAILURES=()
  # Stub suite: exits 0, prints two PASS lines and two SKIP lines — the exact
  # shape a root run of the real suite produces.
  sib18_run() {
    local root; root=$(mktemp -d)
    mkdir -p "$root/scripts"
    cat > "$root/scripts/test-selfimprovement-backlog.sh" <<'STUB'
#!/usr/bin/env bash
echo "  PASS: TC-SIB-1: something"
echo "  PASS: TC-SIB-2: something else"
echo "  SKIP: TC-SIB-12: running as root (EUID 0) — chmod 000 is not enforced"
echo "  SKIP: TC-SIB-14: running as root (EUID 0) — chmod 000 does not block traversal"
exit 0
STUB
    {
      printf 'ERRORS=0\nWARNINGS=0\n'
      printf 'ok()   { printf "OK|%%s\\n" "$1"; }\n'
      printf 'warn() { printf "WARN|%%s\\n" "$1"; WARNINGS=$((WARNINGS + 1)); }\n'
      printf 'fail() { printf "FAIL|%%s\\n" "$1"; ERRORS=$((ERRORS + 1)); }\n'
      printf 'info() { printf "INFO|%%s\\n" "$1"; }\n'
      printf 'REPO_ROOT="%s"\n' "$root"
      printf '%s\n' "$SIB18_BLOCK"
      printf 'printf "COUNTERS|%%s|%%s\\n" "$WARNINGS" "$ERRORS"\n'
    } > "$root/runner.sh"
    bash "$root/runner.sh" 2>&1
    rm -rf "$root"
  }
  A18_OUT=$(sib18_run)
  A18_W=$(printf '%s\n' "$A18_OUT" | sed -n 's/^COUNTERS|\([0-9]*\)|.*/\1/p' | head -1)
  # (leg 1) Both skips must be surfaced by name.
  A18_SKIPS=$(printf '%s\n' "$A18_OUT" | grep -c 'SKIPPED' || true)
  [[ "$A18_SKIPS" -eq 2 ]] \
    || A18_FAILURES+=("leg 1: verify.sh surfaced $A18_SKIPS of 2 SKIP lines — a root run would report a lower check count with nothing saying which coverage was lost: $A18_OUT")
  printf '%s\n' "$A18_OUT" | grep -q 'TC-SIB-12' \
    || A18_FAILURES+=("leg 1: the relayed skip does not name the case (TC-SIB-12) — an unnamed skip is not visible coverage loss: $A18_OUT")
  # (leg 2) The relay must reach the PARENT counter, so a pipe cannot be
  # substituted for the process substitution.
  [[ "${A18_W:-0}" -eq 2 ]] \
    || A18_FAILURES+=("leg 2: WARNINGS ended at '$A18_W', expected 2 — the relay must increment the caller's counter, and a pipe instead of \`< <(...)\` discards every increment: $A18_OUT")
  # The success line must still be emitted; relaying skips must not replace it.
  printf '%s\n' "$A18_OUT" | grep -q '^OK|' \
    || A18_FAILURES+=("the success line disappeared — relaying skips must not turn a passing suite into a non-report: $A18_OUT")
  printf '%s\n' "$A18_OUT" | grep -q '^FAIL|' \
    && A18_FAILURES+=("a skipped case was escalated to a FAILURE — a skip is missing coverage, not a defect: $A18_OUT")

  if [[ ${#A18_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (both SKIP lines relayed by name as warnings, the caller's WARNINGS counter reached 2, the pass line survived, and nothing was escalated to a failure)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A18_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
TOTAL=$((PASS + FAIL))
# Skipped cases are listed whatever the outcome: a case that silently stops
# running is indistinguishable from one that never existed, which is the same
# invisible-gap problem the reporter under test exists to solve.
if [[ $SKIP -gt 0 ]]; then
  printf "  %d test(s) SKIPPED (premise not establishable in this environment):\n" "$SKIP"
  for t in "${SKIPPED_TESTS[@]}"; do
    printf "    - %s\n" "$t"
  done
fi
if [[ $FAIL -eq 0 ]]; then
  printf "  All %d tests passed.\n" "$TOTAL"
else
  printf "  %d/%d tests FAILED:\n" "$FAIL" "$TOTAL"
  for t in "${FAILED_TESTS[@]}"; do
    printf "    - %s\n" "$t"
  done
  exit 1
fi

exit 0
