#!/usr/bin/env bash
# loop-progress-signature.sh — guard 2 of three: the no-progress detector.
#
# Answers ONE question, deterministically: "has this loop's failure changed
# since last iteration, or is it grinding on the same thing?" It returns a
# distinct exit code when the SAME normalised failure signature has survived
# `--threshold` consecutive iterations, which is the mechanism behind the
# no-progress clause every `/goal` condition is required to carry
# (`commands/flow.md` Steps 8a/11a) and the no-progress rule in
# `examples/loop.md.example`. Doctrine for all three guards: the `loop-design`
# skill.
#
# ⛔ WHY THIS IS NOT KEYED ON FILE mtimes ⛔
#   The mtime-based liveness monitor that `skills/subagent-liveness` used to
#   carry (now RETIRED in favour of `skills/observed-work`) answered a different
#   question — "is this agent alive?" — and it is the WRONG signal for
#   progress. An agent that rewrites the same failing file every iteration
#   touches that file every iteration, so an mtime detector reports it healthy
#   forever. That is the exact failure a no-progress guard exists to catch, so
#   this detector keys on the FAILURE instead of on the activity: the sorted set
#   of failing gate names plus the top error identifier from their output. Two
#   iterations that fail the same gates with the same error made no progress, no
#   matter how many files they wrote.
#
# USAGE
#   bash loop-progress-signature.sh --state <file> --failing-gates <csv> \
#        [--threshold <N>] [--output <file|->]
#
#   --state          Where the previous iteration's signature and run length are
#                    kept. One file per loop run; delete it to start over.
#   --failing-gates  Comma-separated names of the gates that FAILED this
#                    iteration ("test,build"). EMPTY means nothing failed — the
#                    state is reset and the caller told it is making progress.
#                    The caller supplies this because the caller ran the gates;
#                    guessing which gates failed by parsing output would make
#                    the signature depend on a log format instead of on a fact.
#   --threshold      Consecutive identical iterations that mean "stop". Defaults
#                    to 2 and is clamped to at most the toolbox ceiling below,
#                    matching `loop.no_progress_after` in the `workflow-discipline`
#                    skill §1d. Zero or negative is treated as absent, not as
#                    "never stop" — a typo must not silently disable the guard.
#   --output         The combined gate output to mine for the error identifier.
#                    A file path, or `-` for stdin. Omitted/unreadable/empty is
#                    not an error: the identifier becomes `nosignal`, which is
#                    itself a signature value (see below).
#
# EXIT CODES  (the whole caller-facing contract)
#   0  Keep going. Either the signature CHANGED (real progress) or it repeated
#      but has not yet reached the threshold. stdout says which.
#   3  STOP AND ESCALATE. The same signature has now survived `--threshold`
#      consecutive iterations. Per `examples/loop.md.example`, escalating here is
#      a success condition, not a failure.
#   2  Usage or environment error. The caller must treat this as "the detector
#      did not run" and fall back to its turn/spend bound.
#
# `nosignal` IS A SIGNATURE, NOT AN ABSTENTION. When no error identifier can be
# extracted, the signature still records the failing-gate set, so the same gates
# failing unreadably twice in a row still trips the threshold. Abstaining
# instead would mean a loop with unparseable output could never trip this guard
# at all, leaving the turn cap as its only stop — which is precisely the
# situation the guard exists to improve on. stdout marks these runs `degraded`
# so a reader can tell a confident stop from a shape-only one.
#
# The gate output is UNTRUSTED input (it contains compiler messages, test names
# and file paths from the repo under test). It is only ever normalised and
# hashed by awk/sed — never evaluated, never used to build a command, never
# interpolated into one.

set -uo pipefail

# Toolbox-owned ceiling. MUST stay equal to `loop.no_progress_after` in the
# `workflow-discipline` skill §1d, which is the documented source of truth;
# scripts/test-loop-progress-signature.sh cross-checks the two so a drift fails
# the build instead of quietly widening the bound.
NO_PROGRESS_CEILING=5
DEFAULT_THRESHOLD=2

die_usage() {
  echo "loop-progress-signature: $1" >&2
  echo "usage: $0 --state <file> --failing-gates <csv> [--threshold <N>] [--output <file|->]" >&2
  exit 2
}

STATE_FILE=""
FAILING_GATES=""
GATES_SET=false
THRESHOLD=""
OUTPUT_SRC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state)         [[ $# -ge 2 ]] || die_usage "--state needs a value"; STATE_FILE="$2"; shift 2 ;;
    # --failing-gates "" is MEANINGFUL (nothing failed), so record that the flag
    # was seen separately from whether its value is empty.
    --failing-gates) [[ $# -ge 2 ]] || die_usage "--failing-gates needs a value"; FAILING_GATES="$2"; GATES_SET=true; shift 2 ;;
    --threshold)     [[ $# -ge 2 ]] || die_usage "--threshold needs a value"; THRESHOLD="$2"; shift 2 ;;
    --output)        [[ $# -ge 2 ]] || die_usage "--output needs a value"; OUTPUT_SRC="$2"; shift 2 ;;
    *)               die_usage "unknown argument: $1" ;;
  esac
done

[[ -n "$STATE_FILE" ]] || die_usage "--state is required"
[[ "$GATES_SET" == true ]] || die_usage "--failing-gates is required (pass an empty value when nothing failed)"

# ---------------------------------------------------------------------------
# Threshold: default when absent/blank/non-numeric-or-zero, then clamp.
# Clamping here as well as at the call site is deliberate defence in depth —
# this script is the thing that actually decides to stop, so it must not depend
# on the caller having applied §1d's tighten-only clamp correctly.
# ---------------------------------------------------------------------------
if [[ ! "$THRESHOLD" =~ ^[0-9]{1,9}$ ]] || (( 10#${THRESHOLD:-0} < 1 )); then
  THRESHOLD="${LOOP_NO_PROGRESS_AFTER:-$DEFAULT_THRESHOLD}"
fi
if [[ ! "$THRESHOLD" =~ ^[0-9]{1,9}$ ]] || (( 10#${THRESHOLD:-0} < 1 )); then
  THRESHOLD=$DEFAULT_THRESHOLD
fi
if (( 10#$THRESHOLD > NO_PROGRESS_CEILING )); then
  echo "loop-progress-signature: threshold $THRESHOLD exceeds the toolbox ceiling $NO_PROGRESS_CEILING — clamped (workflow-discipline skill §1d)" >&2
  THRESHOLD=$NO_PROGRESS_CEILING
fi

# ---------------------------------------------------------------------------
# State-file safety. Refuse anything that is not a regular file BEFORE writing:
# a symlink here would let a loop's bookkeeping append into an arbitrary host
# file, and a FIFO would hang the loop. Same stance as the .gitignore guard in
# the `workflow-discipline` skill, kept simple because this path is chosen by
# the toolbox, not by repo content.
# ---------------------------------------------------------------------------
if [[ -e "$STATE_FILE" || -L "$STATE_FILE" ]]; then
  if [[ -L "$STATE_FILE" || ! -f "$STATE_FILE" ]]; then
    echo "loop-progress-signature: --state path is not a regular file (symlink, FIFO, device or directory): $STATE_FILE" >&2
    exit 2
  fi
fi
STATE_DIR_PATH=$(dirname "$STATE_FILE")
[[ -d "$STATE_DIR_PATH" ]] || die_usage "--state directory does not exist: $STATE_DIR_PATH"

# ---------------------------------------------------------------------------
# Nothing failed → the loop converged (or at least moved). Reset and report.
# ---------------------------------------------------------------------------
if [[ -z "${FAILING_GATES// /}" ]]; then
  rm -f "$STATE_FILE" 2>/dev/null || true
  echo "progress: no failing gates — state reset"
  exit 0
fi

# ---------------------------------------------------------------------------
# Term 1 of the signature: the failing-gate set, order-independent.
# Sorted and de-duplicated so "build,test" and "test,build,test" are the same
# failure shape — the caller must not have to remember an ordering.
# ---------------------------------------------------------------------------
GATE_KEY=$(tr ',' '\n' <<< "$FAILING_GATES" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
  | grep -v '^$' \
  | LC_ALL=C sort -u \
  | paste -sd, - 2>/dev/null || true)
GATE_KEY="${GATE_KEY//$'\n'/}"
[[ -n "$GATE_KEY" ]] || GATE_KEY="unnamed"

# ---------------------------------------------------------------------------
# Term 2: the top error identifier, normalised.
#
# NORMALISATION, in this fixed order. Every rule removes a source of
# iteration-to-iteration churn that is NOT progress; nothing else is touched,
# because over-normalising would merge two genuinely different failures into
# one signature and stop a loop that was actually moving.
#
#   1  strip carriage returns and ANSI colour sequences
#   2  lowercase
#   3  uuids, hex addresses and long hex runs (object ids, hashes)
#   4  dates and clock times
#   5  durations with an explicit unit (seconds/minutes/ms/us/ns)
#   6  directory prefixes — keep the basename, drop the checkout path
#   7  `(line,col)` (msbuild) and `:line:col` / `:line` (everything else)
#   8  digit runs of six or more (pids, byte offsets, epochs)
#   9  collapse whitespace
#
# SHORT STANDALONE NUMBERS ARE DELIBERATELY KEPT. "expected 3, got 4" becoming
# "expected 3, got 5" is real movement, and blanking every digit would hide it.
# The cost is the opposite residual, stated plainly: a failure that differs ONLY
# in a short number that IS churn (a flaky count) reads as two different
# signatures and the guard will not trip on it.
#
# THE REGISTRY SELECTS A LINE; IT DOES NOT SHORTEN THE IDENTITY. The identifier
# is the SELECTED LINE, normalised and truncated — not just the matched code.
# Keying on the bare code instead (`error cs0246`, `error[e0382]`) was tried and
# is wrong: a loop that fixes the first CS0246 and now trips a differently
# worded one has moved, and a code-only identifier would call that no progress
# and stop it. What the registry buys is choosing the RIGHT line when a log
# prints an unstable summary line ("compiling failed for crate <x>") before the
# authoritative one.
#
#   P1  a line carrying `error <code>`   dotnet / tsc / msvc (cs0246, ts2304)
#   P2  a line carrying `error[e####]`   rust
#   P3  a line carrying an exception class token (`<name>error`, `<name>exception`)
#   P4  the first line containing "error" or "fail"
# No match at all → `nosignal` (see the header: still a signature).
# ---------------------------------------------------------------------------
read_output() {
  if [[ "$OUTPUT_SRC" == "-" ]]; then
    cat
  elif [[ -n "$OUTPUT_SRC" && -r "$OUTPUT_SRC" && -f "$OUTPUT_SRC" ]]; then
    cat -- "$OUTPUT_SRC"
  else
    : # no output available — identifier will be `nosignal`
  fi
}

NORMALISE_AND_EXTRACT='
function norm(s) {
  gsub(/\r/, "", s)
  gsub(/\033\[[0-9;?]*[a-zA-Z]/, "", s)
  s = tolower(s)
  gsub(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/, "<uuid>", s)
  gsub(/0x[0-9a-f]+/, "<addr>", s)
  gsub(/[0-9a-f]{12,}/, "<hex>", s)
  gsub(/[0-9]{4}-[0-9]{2}-[0-9]{2}/, "<date>", s)
  gsub(/[0-9]{1,2}:[0-9]{2}:[0-9]{2}([.,][0-9]+)?/, "<time>", s)
  # Units longest-first so a leftmost-longest engine cannot stop at "sec"
  # inside "seconds" and leave a stray "onds" behind.
  gsub(/[0-9]+([.,][0-9]+)?[ ]?(seconds|second|secs|sec|minutes|minute|mins|min|ms|us|ns)/, "<dur>", s)
  # Bare `s`, and ONLY with a decimal point: `(0.03s)`, `1.234 s`. This is the
  # dominant PER-TEST duration format and the unit list above misses every
  # instance of it — `go test` prints `--- FAIL: TestX (0.03s)`, and pytest -v,
  # jest ("Time: 1.234 s") and vitest all do the same. The effect was not
  # cosmetic: two iterations of `FAIL TestFoo (0.03s)` then `(0.04s)` scored as
  # a NEW signature every time, so a genuinely stuck loop never reached the
  # threshold. Covered by TC-LPS-17.
  #
  # The decimal is REQUIRED deliberately. A bare `[0-9]+s` would eat the leading
  # "2 s" of "2 successes" and leave "<dur>uccesses" — POSIX ERE has no word
  # boundary to stop it. Requiring the decimal makes the match unambiguous, at
  # the cost of one residual stated plainly: a whole-number duration with a bare
  # unit ("ran in 12s") still churns. Every runner named above prints a decimal.
  gsub(/[0-9]+[.,][0-9]+[ ]?s/, "<dur>", s)
  gsub(/([a-z0-9_.@~+-]+\/)+/, "", s)
  gsub(/\([0-9]+,[0-9]+\)/, "(<l>,<c>)", s)
  gsub(/:[0-9]+:[0-9]+/, ":<l>:<c>", s)
  gsub(/:[0-9]+/, ":<l>", s)
  gsub(/[0-9]{6,}/, "<n>", s)
  gsub(/[ \t]+/, " ", s)
  sub(/^ /, "", s)
  sub(/ $/, "", s)
  return s
}
{
  n++
  L[n] = norm($0)
}
END {
  # Each rung SELECTS a line; the identifier is that whole normalised line,
  # truncated. See the header comment for why the bare code is not enough.
  for (i = 1; i <= n; i++)                                   # P1 dotnet / tsc / msvc
    if (L[i] ~ /error [a-z]{1,5}[0-9]{2,5}/) { print substr(L[i], 1, 160); exit }
  for (i = 1; i <= n; i++)                                   # P2 rust
    if (L[i] ~ /error\[e[0-9]{3,4}\]/) { print substr(L[i], 1, 160); exit }
  for (i = 1; i <= n; i++)                                   # P3 exception class token
    if (L[i] ~ /[a-z][a-z0-9_.]*(error|exception)/) { print substr(L[i], 1, 160); exit }
  for (i = 1; i <= n; i++)                                   # P4 anything error/fail
    if (L[i] ~ /error|fail/) { print substr(L[i], 1, 160); exit }
  print "nosignal"
}'

ERROR_ID=$(read_output | awk "$NORMALISE_AND_EXTRACT" 2>/dev/null || true)
ERROR_ID="${ERROR_ID//$'\n'/ }"
[[ -n "${ERROR_ID// /}" ]] || ERROR_ID="nosignal"

# ---------------------------------------------------------------------------
# Hash the two terms together. sha256 via whichever tool this platform ships.
# The hash is for compact, safe comparison only — it carries no secret, so a
# missing hasher falls back to the raw key rather than failing the loop.
# ---------------------------------------------------------------------------
SIG_INPUT="gates=${GATE_KEY}|err=${ERROR_ID}"
if command -v shasum >/dev/null 2>&1; then
  SIGNATURE=$(awk 'BEGIN{ printf "%s", ARGV[1] }' "$SIG_INPUT" | shasum -a 256 | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
  SIGNATURE=$(awk 'BEGIN{ printf "%s", ARGV[1] }' "$SIG_INPUT" | sha256sum | awk '{print $1}')
else
  SIGNATURE=$(sed -e 's/[^A-Za-z0-9<>|=_.,-]/_/g' <<< "$SIG_INPUT")
fi
[[ -n "$SIGNATURE" ]] || SIGNATURE="unhashed"

# ---------------------------------------------------------------------------
# Compare with the previous iteration and update the state atomically.
# State format mirrors the `.codex-unavailable` marker shape used by
# `skills/codex-review` — a leading token, greppable, one fact per line:
#     sig <signature>
#     count <consecutive iterations with that signature>
# ---------------------------------------------------------------------------
PREV_SIG=""
PREV_COUNT=0
if [[ -f "$STATE_FILE" ]]; then
  PREV_SIG=$(awk '$1 == "sig"   { print $2; exit }' "$STATE_FILE" 2>/dev/null || true)
  PREV_COUNT=$(awk '$1 == "count" { print $2; exit }' "$STATE_FILE" 2>/dev/null || true)
  [[ "$PREV_COUNT" =~ ^[0-9]{1,9}$ ]] || PREV_COUNT=0
fi

if [[ "$SIGNATURE" == "$PREV_SIG" ]]; then
  COUNT=$(( 10#$PREV_COUNT + 1 ))
else
  COUNT=1
fi

# The temp path must be UNPREDICTABLE and created with O_EXCL, not
# "${STATE_FILE}.tmp.$$". A PID-derived name is guessable and `>` follows
# symlinks, so anything able to write this directory could pre-create that
# path pointing elsewhere and have this write clobber that file — and then
# `mv` installs the symlink AT the state path, defeating the regular-file
# guard above and wedging every later run into rc=2. mktemp creates the file
# itself with O_EXCL, so a pre-created path (symlink or FIFO) loses.
TMP_STATE=$(mktemp "${STATE_FILE}.tmp.XXXXXX") \
  || { echo "loop-progress-signature: cannot create temp state next to: $STATE_FILE" >&2; exit 2; }
{
  echo "sig $SIGNATURE"
  echo "count $COUNT"
} > "$TMP_STATE" || { echo "loop-progress-signature: cannot write state: $STATE_FILE" >&2; rm -f "$TMP_STATE"; exit 2; }
mv -f "$TMP_STATE" "$STATE_FILE" || { echo "loop-progress-signature: cannot replace state: $STATE_FILE" >&2; rm -f "$TMP_STATE"; exit 2; }

DEGRADED=""
[[ "$ERROR_ID" == "nosignal" ]] && DEGRADED=" (degraded: no error identifier found — signature is the failing-gate set only)"

if (( COUNT >= 10#$THRESHOLD )); then
  echo "no-progress: same signature for $COUNT consecutive iterations (threshold $THRESHOLD) — stop and escalate${DEGRADED}"
  echo "  gates: $GATE_KEY"
  echo "  error: $ERROR_ID"
  exit 3
fi

if (( COUNT > 1 )); then
  echo "same: signature repeated $COUNT/$THRESHOLD consecutive iterations${DEGRADED}"
else
  echo "progress: new failure signature${DEGRADED}"
fi
echo "  gates: $GATE_KEY"
echo "  error: $ERROR_ID"
exit 0
