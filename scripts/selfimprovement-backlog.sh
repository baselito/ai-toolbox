#!/usr/bin/env bash

# =============================================================================
# scripts/selfimprovement-backlog.sh — report the self-improvement loop backlog
#
# WHY THIS EXISTS:
# The toolbox captures two kinds of telemetry about its own operation — process
# DEVIATIONS (from .claude/handover.md) and review LESSONS (from automated-review and
# Codex) — folds each into a per-PR snapshot in the state dir, and surfaces them
# for a human to triage when a PR merges. That last step is human-gated, and a
# human-gated step that nothing surfaces simply does not happen.
#
# It did not happen, twice. 69 lessons findings across 12 PRs sat unread for
# four weeks while knowledge/toolbox-lessons.yml stayed `lessons: []`. Then 75
# deviation records across 6 snapshots sat unread for six weeks while
# dismissed-deviations.log stayed at 0 bytes. Neither loop FAILED at any point;
# each simply never reached its last stage, and nothing anywhere said so.
#
# This script is the thing that says so. It is a REPORTER, not a gate:
#   - It always exits 0. A backlog means a human has not triaged yet, which is
#     not a defect and must never fail a build.
#   - It emits plain prefixed lines (`OK: `, `INFO: `, `WARN: `) on stdout and
#     owns no presentation: no colour, no counters, no exit semantics. The
#     caller (scripts/verify.sh) maps each prefix onto its own reporting
#     helpers so the warning count it prints in its summary stays accurate.
#
# WHY A SEPARATE SCRIPT rather than inline in verify.sh: the false-POSITIVE case
# needs a test — a warning that fires on every fresh install is a warning
# everyone learns to skip, which is the same silence by another route. A test
# that drove verify.sh would recurse, because verify.sh runs the test suites.
# Parameterising STATE_DIR makes the whole thing unit-testable against a temp
# directory with no HOME games. See scripts/test-selfimprovement-backlog.sh.
#
# Nothing at agent runtime calls this — only verify.sh does, and verify.sh only
# ever runs from the repo — so it deliberately has NO install.sh copy step.
#
# Usage: selfimprovement-backlog.sh [STATE_DIR] [REPO_ROOT]
#   STATE_DIR  — where the loop keeps its state. Default $HOME/.claude.
#   REPO_ROOT  — the toolbox checkout, used only to read knowledge/. Default the
#                parent of this script's directory.
# =============================================================================

# `set -uo pipefail` but NOT `-e`: every branch below is handled explicitly and
# the script must reach its end and exit 0 no matter what it finds.
set -uo pipefail

# ⛔ STATE_DIR defaults to $HOME/.claude, NOT to $CLAUDE_HOME. ⛔
# The WRITER (scripts/pr-postmerge-fold.sh) writes literally to "$HOME/.claude",
# and on Windows verify.sh's own CLAUDE_HOME resolves to APPDATA/Claude. Reading
# a different directory than the writer writes to is precisely how a backlog
# check reports zero forever while a real queue piles up next door — the failure
# class this script was added to end. Keep these two in agreement.
STATE_DIR="${1:-$HOME/.claude}"
REPO_ROOT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Count files matching a glob inside STATE_DIR, optionally excluding one
# basename. `find` rather than a shell glob: with no matches a glob yields the
# literal pattern, which would be counted as one file.
count_files() {
  local pattern="$1" exclude="${2:-}"
  local n
  if [[ -n "$exclude" ]]; then
    n=$(find "$STATE_DIR" -maxdepth 1 -name "$pattern" -type f ! -name "$exclude" 2>/dev/null | wc -l)
  else
    n=$(find "$STATE_DIR" -maxdepth 1 -name "$pattern" -type f 2>/dev/null | wc -l)
  fi
  printf '%s' "$(printf '%s' "$n" | tr -d '[:space:]')"
}

# Sum non-blank lines across the matching files — both snapshot kinds are JSONL,
# so one line is one record.
#
# (The previous version of this comment read "in both formats (deviation
# snapshots are JSONL, lessons snapshots are JSONL)" — it named JSONL twice to
# distinguish two things that are in fact the same format, which reads as an
# unfinished edit rather than a fact.)
count_records() {
  local pattern="$1" exclude="${2:-}"
  local total=0 f n
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ -n "$exclude" && "$(basename "$f")" == "$exclude" ]] && continue
    # ⛔ NEVER `|| echo 0` AFTER `grep -c`. ⛔
    # `grep -c .` on a file with zero NON-BLANK lines already PRINTS "0" and
    # THEN exits 1. An `|| echo 0` therefore appends a SECOND zero, the command
    # substitution yields the two-line string "0\n0", and `$(( ))` on that is a
    # fatal arithmetic error. Because count_records itself runs inside a command
    # substitution, that error kills the subshell before the closing `printf`,
    # so the caller receives the EMPTY STRING — not a wrong count, no count at
    # all — and every other file's records vanish with it. Reported as
    # "~ record(s)", with verify.sh swallowing the diagnostic via 2>/dev/null:
    # a silent under-report from the very script written to end silent
    # under-reports. The trigger is "zero non-blank lines", NOT "zero bytes", so
    # a 3-byte "\n\n\n" file detonates it too — do not "fix" this by skipping
    # empty files with `-s` (TC-SIB-9 pins that). Reachable from committed code:
    # scripts/pr-postmerge-fold.sh's failed-fold branch uses `>>`, which creates
    # a 0-byte pending-lessons snapshot before `cat` runs.
    # The same trap is recorded in two other places. Cited by ANCHOR, not by
    # line number, because the earlier line-number citations here (init.md
    # :627-636, test-sync-toolbox-lessons.sh:447) both rotted when the
    # surrounding text moved:
    #   - commands/init.md — the paragraph starting
    #     "Retained lesson — the `grep -c` exit-1 trap" (originating automated-review
    #     finding, PR #61)
    #   - scripts/test-sync-toolbox-lessons.sh — the comment
    #     "do NOT add `|| echo 0`" above the FB_LESSONS assignment
    # Those two state the trap; this block is the canonical form:
    #
    # ⛔ AN UNREADABLE FILE IS SKIPPED HERE ON PURPOSE, AND COUNTED ELSEWHERE. ⛔
    # `grep -c` on an unreadable file prints nothing, so it used to contribute
    # zero to this total with nothing anywhere saying so — a silent under-report
    # from the script written to end silent under-reports. It is skipped
    # explicitly now so the behaviour is a decision rather than an accident, and
    # count_unreadable() below counts the same files so the report can say the
    # total is a FLOOR. Never coerce an unreadable file's records to zero: zero
    # is a count, and we do not have one.
    [[ -r "$f" ]] || continue
    n=$(grep -c . "$f" 2>/dev/null || true)
    total=$(( total + ${n:-0} ))
  done < <(find "$STATE_DIR" -maxdepth 1 -name "$pattern" -type f 2>/dev/null)
  printf '%s' "$total"
}

# Basenames of matching files that cannot be READ, one per line. Their record
# counts are UNKNOWN — not zero — and the report has to say so, because a
# queued snapshot the report does not fully account for is the whole failure
# class this script exists to end.
unreadable_names() {
  local pattern="$1" exclude="${2:-}"
  local f
  while IFS= read -r -d '' f; do
    [[ -n "$exclude" && "$(basename "$f")" == "$exclude" ]] && continue
    [[ -r "$f" ]] && continue
    basename "$f"
  done < <(find "$STATE_DIR" -maxdepth 1 -name "$pattern" -type f -print0 2>/dev/null)
}

# How many of them there are. `grep -c .` on the (possibly empty) list, with no
# `|| echo 0` — see the canonical-form note in count_records above.
count_unreadable() {
  local n
  n=$(unreadable_names "$1" "${2:-}" | grep -c . || true)
  printf '%s' "${n:-0}"
}

# Basename of the OLDEST matching file, by MTIME.
#
# WHY `ls -t | tail -1` and not something tidier: `sort | head -1` is
# lexicographic, so `pending-...-105` sorts before `pending-...-99` and the
# report names the wrong file — and PR number is not recency in the first place.
# Of the mtime-aware alternatives, `stat -f %m` is macOS-only, `stat -c %Y` is
# GNU-only, and `find -printf` does not exist on macOS; CI runs ubuntu and
# developers run macOS, so `ls -t` is the one form that works on both.
oldest_file() {
  local pattern="$1" exclude="${2:-}"
  # NUL-delimited read, because `find` emits FULL PATHS — not basenames.
  #
  # The comment that used to sit here justified a newline-joined
  # `ls -t $(... | tr '\n' ' ')` by observing that "every name this matches is
  # `pending-<kind>-<digits>.<ext>` with no whitespace". That was true of the
  # BASENAMES and irrelevant to the actual hazard: the basenames were never the
  # part being split. STATE_DIR is caller-supplied (verify.sh passes $HOME/.claude,
  # tests pass a mktemp path, Windows resolves under "Application Support"), so a
  # single space anywhere in the DIRECTORY portion split the list into fragments
  # that do not exist, `ls -t` printed nothing, and the report silently degraded
  # to "oldest: unknown" — losing the one field that tells a human how long the
  # queue has been rotting. Reading NUL-delimited removes the class entirely.
  local files=() f
  while IFS= read -r -d '' f; do
    [[ -n "$exclude" && "$(basename "$f")" == "$exclude" ]] && continue
    files+=( "$f" )
  done < <(find "$STATE_DIR" -maxdepth 1 -name "$pattern" -type f -print0 2>/dev/null)
  [[ ${#files[@]} -eq 0 ]] && { printf 'unknown'; return; }
  local oldest
  oldest=$(ls -t "${files[@]}" 2>/dev/null | tail -1)
  [[ -z "$oldest" ]] && { printf 'unknown'; return; }
  basename "$oldest"
}

# Does the directory hold at least one regular file?
dir_has_file() {
  local d="$1"
  [[ -d "$d" ]] || return 1
  [[ -n "$(find "$d" -maxdepth 1 -type f 2>/dev/null | head -1)" ]]
}

if [[ ! -d "$STATE_DIR" ]]; then
  # No state dir at all is a fresh install, not a problem.
  echo "OK: no self-improvement state directory yet ($STATE_DIR) — nothing captured"
  exit 0
fi

# ⛔ AN UNSEARCHABLE STATE DIR IS UNKNOWN, NOT DRAINED. ⛔
# Every count below comes from a `find` with `2>/dev/null` on it, and that
# suppression is right for a missing file but catastrophic for a directory that
# cannot be listed: `find` prints its error to the discarded stream, returns
# nothing, both halves count zero, and the script signs off with
# "OK: no self-improvement backlog — deviations and lessons are both drained"
# over a queue it never managed to look at. That is this script's own failure
# mode — reporting silence as health — reached by a permissions accident, a
# root-owned directory, or a STATE_DIR pointing somewhere the caller cannot
# traverse. Probed explicitly, reported as UNKNOWN, and never as zero. Still
# exit 0: this is a reporter, and a warning is how it speaks.
if [[ ! -r "$STATE_DIR" || ! -x "$STATE_DIR" ]]; then
  echo "WARN: the self-improvement state directory exists but cannot be listed ($STATE_DIR) — the backlog is UNKNOWN, not zero"
  echo "INFO: every count in this check comes from a directory read, so an unlistable state dir would otherwise report a full queue as drained. Fix the permissions or ownership on $STATE_DIR (or point STATE_DIR at the directory the fold actually writes to) and re-run."
  exit 0
fi

# ---------------------------------------------------------------------------
# Deviations half
# ---------------------------------------------------------------------------
DEV_SNAPSHOTS=$(count_files 'pending-deviations-*.log')
DEV_RECORDS=$(count_records 'pending-deviations-*.log')
DEV_OLDEST=$(oldest_file 'pending-deviations-*.log')
DEV_UNREADABLE=$(count_unreadable 'pending-deviations-*.log')
DEV_UNREADABLE_NAMES=$(unreadable_names 'pending-deviations-*.log' | tr '\n' ' ')

# ---------------------------------------------------------------------------
# Lessons half
#
# `pending-lessons-deferred.jsonl` matches the same glob but is NOT a per-PR
# snapshot — it is the cross-PR DEFERRED queue, holding records a human has
# already seen and chosen to hold. Counting it would report a backlog on a
# fully-triaged machine. Same exclusion the consumer makes in
# scripts/consume-deviations.sh.
# ---------------------------------------------------------------------------
DEFERRED_NAME='pending-lessons-deferred.jsonl'
LESSON_SNAPSHOTS=$(count_files 'pending-lessons-*.jsonl' "$DEFERRED_NAME")
LESSON_RECORDS=$(count_records 'pending-lessons-*.jsonl' "$DEFERRED_NAME")
LESSON_OLDEST=$(oldest_file 'pending-lessons-*.jsonl' "$DEFERRED_NAME")
LESSON_UNREADABLE=$(count_unreadable 'pending-lessons-*.jsonl' "$DEFERRED_NAME")
LESSON_UNREADABLE_NAMES=$(unreadable_names 'pending-lessons-*.jsonl' "$DEFERRED_NAME" | tr '\n' ' ')

# ---------------------------------------------------------------------------
# Has either loop EVER completed a triage?
#
# ⛔ `-s` (non-empty), never `-f` (exists). ⛔
# ~/.claude/dismissed-deviations.log exists right now at 0 bytes, created by an
# unconditional `touch` that used to run before any gate in the consumer. A
# presence test would therefore read "a triage has completed" on a machine where
# none ever has, suppressing the never-completed warning on exactly the machine
# that needed it. Only emptiness distinguishes the two.
# ---------------------------------------------------------------------------
#
# ⛔ SURFACING IS NOT DECIDING — surfaced-deviations.log is NOT evidence. ⛔
# `[[ -s "$STATE_DIR/surfaced-deviations.log" ]] && DEV_LOOP_COMPLETED=true` used
# to be the third line here, and it contradicted the invariant the whole consumer
# is built on. That file is the REPRINT POINTER: it records what was printed, it
# authorizes nothing, and scripts/consume-deviations.sh refuses to let it archive a
# snapshot for exactly this reason. Treating it as completion evidence made the
# FIRST surface — including one nobody replied to — permanently silence the
# "this loop has never completed a triage" warning, on the machine where the
# warning was true. Worse, the pointer is self-healing: an attended run that
# prints nothing while work remains TRUNCATES it, so the evidence could vanish
# and reappear, which is not what evidence does.
#
# What DOES count: a dismissal was recorded (the only thing that authorizes
# archival), or a snapshot actually reached the archive. Both are terminal facts
# about a decision a human made.
DEV_LOOP_COMPLETED=false
[[ -s "$STATE_DIR/dismissed-deviations.log" ]] && DEV_LOOP_COMPLETED=true
dir_has_file "$STATE_DIR/consumed-deviations" && DEV_LOOP_COMPLETED=true

LESSONS_LOOP_COMPLETED=false
[[ -s "$STATE_DIR/dismissed-lessons.log" ]] && LESSONS_LOOP_COMPLETED=true
dir_has_file "$STATE_DIR/consumed-lessons" && LESSONS_LOOP_COMPLETED=true
# A populated knowledge file is the strongest completion signal of all: a lesson
# only lands there after a human approved it.
if [[ -f "$REPO_ROOT/knowledge/toolbox-lessons.yml" ]] \
   && grep -qE '^[[:space:]]*-[[:space:]]+id:' "$REPO_ROOT/knowledge/toolbox-lessons.yml" 2>/dev/null; then
  LESSONS_LOOP_COMPLETED=true
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
QUEUED_TOTAL=$(( DEV_SNAPSHOTS + LESSON_SNAPSHOTS ))
UNREADABLE_TOTAL=$(( DEV_UNREADABLE + LESSON_UNREADABLE ))

if [[ "$DEV_SNAPSHOTS" -gt 0 ]]; then
  echo "WARN: $DEV_SNAPSHOTS deviation snapshot(s) awaiting triage (~$DEV_RECORDS record(s); oldest: $DEV_OLDEST)"
  echo "INFO: These are process deviations captured post-merge from handover.md but not yet triaged."
  echo "INFO: Surface them by running /review-pr on a merged toolbox PR — it sweeps ALL snapshots, newest first, and archives each one only once every record in it has been DISMISSED. Being shown a deviation is not deciding it, so a surfaced-but-undecided snapshot stays queued and keeps being reported here."
fi

# ⛔ AN UNREADABLE SNAPSHOT MAKES THE RECORD COUNT A FLOOR, AND MUST SAY SO. ⛔
# The file itself is still in the snapshot count above (`find -type f` does not
# need to read it), but its records contribute nothing, so the "~N record(s)"
# figure is short by an UNKNOWN amount. Saying nothing here is the same defect
# in miniature as the one this script exists to end: a number that reads as
# complete while it is not. Reported separately from the count rather than folded
# into it, because folding would mean inventing a number we do not have.
if [[ "$DEV_UNREADABLE" -gt 0 ]]; then
  echo "WARN: $DEV_UNREADABLE deviation snapshot(s) could not be read — their record count is UNKNOWN, so the record total above is a FLOOR, not a count: $DEV_UNREADABLE_NAMES"
  echo "INFO: /review-pr refuses to archive a snapshot it cannot read, so nothing is being lost — but nothing is draining either. Check permissions and ownership in $STATE_DIR."
fi

if [[ "$LESSON_SNAPSHOTS" -gt 0 ]]; then
  echo "WARN: $LESSON_SNAPSHOTS lessons snapshot(s) awaiting consolidation (~$LESSON_RECORDS record(s); oldest: $LESSON_OLDEST)"
  echo "INFO: These are review findings captured post-merge but not yet folded into knowledge/toolbox-lessons.yml."
  echo "INFO: Consolidate via /review-pr on a merged toolbox PR, which sweeps ALL snapshots (not just that PR's)."
fi

if [[ "$LESSON_UNREADABLE" -gt 0 ]]; then
  echo "WARN: $LESSON_UNREADABLE lessons snapshot(s) could not be read — their record count is UNKNOWN, so the record total above is a FLOOR, not a count: $LESSON_UNREADABLE_NAMES"
  echo "INFO: Same shape as the deviation half. Check permissions and ownership in $STATE_DIR."
fi

# The never-completed warning is deliberately conditional on there being
# something queued. On a fresh install both halves are zero and there is nothing
# to complain about; firing here would make the warning permanent background
# noise on every clean machine.
if [[ "$QUEUED_TOTAL" -gt 0 ]]; then
  if [[ "$DEV_SNAPSHOTS" -gt 0 && "$DEV_LOOP_COMPLETED" != "true" ]]; then
    # Wording tracks the CONDITION exactly. "surfaced" was dropped from the list
    # when it was dropped from the evidence: a record can have been surfaced
    # (printed) many times without anyone deciding anything, and this warning is
    # about DECISIONS. Saying "nothing has ever been surfaced" while a surfaced
    # log sat on disk would be a false statement in the one message a reader
    # relies on to know whether the loop works.
    echo "WARN: the deviation triage loop has never completed a triage on this machine — records are being captured but nothing has ever been dismissed or archived (being shown a deviation is not deciding it, so a surfaced-but-undecided queue still counts as never completed)"
    echo "INFO: This is the shape of the six-week silent stall this check exists to catch. Run /review-pr on a merged toolbox PR to drain the queue."
  fi
  if [[ "$LESSON_SNAPSHOTS" -gt 0 && "$LESSONS_LOOP_COMPLETED" != "true" ]]; then
    echo "WARN: the lessons consolidation loop has never completed a fold on this machine — findings are being captured but none have reached knowledge/toolbox-lessons.yml"
    echo "INFO: Same failure shape as the deviation half. Run /review-pr on a merged toolbox PR to consolidate."
  fi
fi

# ⛔ NEVER CLAIM "DRAINED" OVER STATE THIS RUN COULD NOT READ. ⛔ An unreadable
# snapshot is already inside QUEUED_TOTAL (it is a file, countable without being
# readable), so this second term is belt-and-braces rather than the primary
# guard — but "drained" is an assertion that the loop emptied itself, and the one
# thing this script must never do is assert that over evidence it could not open.
# The unlistable-STATE_DIR case is handled earlier, before any counting.
if [[ "$QUEUED_TOTAL" -eq 0 && "$UNREADABLE_TOTAL" -eq 0 ]]; then
  echo "OK: no self-improvement backlog — deviations and lessons are both drained"
fi

# Always 0: this is a reporter, never a gate.
exit 0
