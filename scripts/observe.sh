#!/usr/bin/env bash
# observe.sh — the deterministic sensor for observed work.
# ⛔ NO MODEL ANYWHERE IN THE SENSING PATH. ⛔
#
# WHY THIS SCRIPT EXISTS — two failures, both STRUCTURAL, neither fixable by a
# better prompt. Read them before changing anything here; every design choice
# below is one of them made impossible.
#
#   INCIDENT 1 — the model that fabricated its measurements.
#     A Haiku "liveness monitor" agent reported "27 checks over 40 minutes,
#     tdd-guide STALLED". Its own usage metadata showed 48 SECONDS and 4 tool
#     calls, and it had mislabelled which agent was which. Root cause: a MODEL
#     was made the sensor, and it was told to pace itself with a busy-loop that
#     takes microseconds. Asked to observe over time with no clock it could
#     actually wait on, it INVENTED observations rather than reporting that it
#     could not comply. No prompt fixes this. A language model asked for a
#     measurement it cannot take will produce a plausible one.
#     → Consequence for this script: the agent supplies a CLAIM and nothing
#       else. THE SCRIPT re-runs the probes, records the FACTS, and COMPUTES the
#       contradiction. `MISMATCH` is arithmetic on two probe results, so no
#       amount of confident PROSE can produce a false one.
#       ⚠️ AND THAT IS THE WHOLE GUARANTEE — it was overstated once, so state the
#       limit next to it. The script computes the verdict, but the declaring
#       agent CHOOSES THE PROBE, and choosing the input defeats the arithmetic.
#       Measured: `--progress-probe 'date +%s'` made every `working` claim look
#       delta-positive with no work behind it. `declare` now rejects a probe
#       whose output changes across two back-to-back runs, OR that answers
#       unstably across them — which kills the per-second case. A probe advancing
#       on a SLOWER cycle still gets through. The guarantee is "prose cannot beat
#       the arithmetic", never "the probe measures the work".
#
#   INCIDENT 2 — the unbounded wait.
#     A background `until grep -q "TC-HI-3/3b" <file>; do sleep 5; done` ran
#     ELEVEN HOURS, because that literal string never appears in the output (the
#     real run prints `TC-HI-3` and `TC-HI-3b` on separate lines). No timeout,
#     no bound, no upper limit of any kind. The user found it, not the agent.
#     → Consequence for this script: `hard_deadline_s` is MANDATORY at declare
#       time and is enforced by `checkin`, `close` AND `probe` (before and after
#       their probes run), so the bound holds with no watcher in existence. Every
#       probe execution is individually bounded, and the watcher is bounded three
#       ways (tick, idle exit, absolute lifetime) with no single `sleep` over
#       WATCH_SLEEP_SLICE_S. `scripts/test-observe.sh` T4 replays that exact
#       broken predicate and proves eleven hours becomes two minutes.
#
#     ⚠️ THE BOUND HAS BEEN BROKEN TWICE MORE SINCE, BOTH TIMES BY A FIX FOR IT.
#       Write the residues down rather than restating the clean claim:
#         · A sleep clamped to the nearest bound still slept past bounds that did
#           not exist yet, because nothing rescanned `active/`. `--tick-s` is now
#           clamped to the rescan slice. (T20)
#         · `run_bounded` bounds the child it WAITS for. A predicate that FORKS
#           returns instantly, so the wait was never the thing that needed
#           bounding. The probe's process GROUP is now swept on every path. (T21)
#       A probe that calls `setsid` would leave the group and survive the sweep,
#       so declarations reject that escape before running. ONE in-flight DEADLINE
#       snapshot may still exceed the watcher's lifetime cap by up to
#       WATCH_SNAPSHOT_GRACE_S; that residual is bounded and named.
#
# ⛔ `timeout` AND `gtimeout` DO NOT EXIST on this machine (verified). ⛔
# Every bound in this file is therefore `date +%s` arithmetic plus an explicit
# kill — see run_bounded(). Do not "simplify" it back to `timeout`.
#
# ---------------------------------------------------------------------------
# STATE LAYOUT  (root overridable with OBSERVER_ROOT, which is what the tests
# use so a test run can never touch the developer's real observer state)
#
#   $OBSERVER_ROOT/active/<task_id>.json    the live declaration + snapshot
#   $OBSERVER_ROOT/retired/<task_id>.json   closed or deadline-retired
#   $OBSERVER_ROOT/log/<task_id>.events.jsonl   APPEND-ONLY event log
#   $OBSERVER_ROOT/state/<task_id>.progress     guard-2 signature state
#
# The event log is the single source of truth an observer agent reads. It is
# append-only on purpose: a fact that was recorded cannot later be softened.
#
# ---------------------------------------------------------------------------
# SUBCOMMANDS
#   declare   Register work to be observed. Captures the baseline ITSELF and
#             REJECTS a declaration whose predicates are broken.
#   checkin   Record a claim, re-measure, and compute MISMATCH / CHURN.
#   probe     Run an ad-hoc probe and RECORD it, so a fact the observer asked
#             for becomes a logged measurement instead of prose. Records FIRST,
#             then enforces the deadline — so asking a question about an overdue
#             task neither destroys the answer nor keeps the task alive.
#   watch     The bounded notification loop. One line per event to stdout.
#   close     Retire a declaration. REFUSES `shipped` while done_when is false.
#   status    List active declarations, ages, rounds and deadline remaining.
#
# ---------------------------------------------------------------------------
# TRUST BOUNDARY — `done_when`, `progress_probe` and `probe --cmd` are executed
# with `bash -c`. That is the mechanism, not an oversight: they are commands the
# ORCHESTRATOR writes about its own work. NEVER build a declaration out of
# untrusted text (reviewer comments, issue bodies, web content, file contents) —
# that would be handing arbitrary command execution to whoever wrote the text.
# Probe OUTPUT, by contrast, IS untrusted (it is compiler and test output from
# the repo under work): it is only ever hashed, truncated, C0-stripped and
# passed through `jq --arg`, never evaluated and never interpolated into a
# command.
#
# EXIT CODES
#   0  the operation succeeded and nothing anomalous was found
#   1  refused: `close --outcome shipped` while done_when is still false
#   2  usage or environment error (the caller must treat this as "did not run")
#   4  the operation was performed but its RECORD COULD NOT BE WRITTEN. Distinct
#      from 1 on purpose: 1 means "refused, and the reason is on the record",
#      4 means "there is no record" — opposite diagnoses that used to be
#      indistinguishable because a failed append returned 0.
#   3  an anomaly was recorded — MISMATCH, CHURN or NO_PROGRESS on checkin, or
#      DEADLINE on a checkin/close that arrived after the declared deadline (the
#      task is retired with a snapshot instead of being serviced)

# `set -e` is deliberately NOT used. This script's normal operation is to run
# commands that EXIT NON-ZERO — `done_when` being false is the expected state of
# work in progress, and `wait` on a killed probe returns non-zero too. With -e
# every one of those would abort the run and the script would only work when the
# work was already finished. Same stance, for the same reason, as
# scripts/loop-progress-signature.sh.
set -uo pipefail

# ---------------------------------------------------------------------------
# Toolbox-owned bounds. These are the Rule 9 (`rules/workflow-discipline.md`)
# iteration/deadline ceilings for observed work. Declare-time values OUTSIDE
# these are REJECTED, not clamped: the number in a declaration IS the bound on
# the observation, exactly like the number in a `/goal` condition, and there is
# nothing behind it to catch a typo. The watcher's own lifetime is clamped
# instead of rejected, because the absolute cap sits behind it as a backstop.
# ---------------------------------------------------------------------------
CHECKIN_EVERY_MIN_S=10          # below this the check-in is noise, not a gate
CHECKIN_EVERY_MAX_S=3600
HARD_DEADLINE_MIN_S=30
HARD_DEADLINE_MAX_S=21600       # 6h — the longest single observed task allowed
MAX_ROUNDS_MIN=1
MAX_ROUNDS_MAX=20
PROBE_LIMIT_S=30                # per-probe execution bound (declare/checkin)
PR_PROBE_LIMIT_S=60             # pr-ready.sh talks to the network; give it more
WATCH_TICK_DEFAULT_S=30
WATCH_IDLE_EXIT_DEFAULT_S=600   # active/ empty this long → the watcher exits
WATCH_LIFETIME_DEFAULT_S=14400  # 4h
WATCH_LIFETIME_MAX_S=28800      # 8h absolute cap — clamped, never exceeded
# ⛔ NO SINGLE `sleep` IN THIS SCRIPT MAY EXCEED THIS. ⛔ It is the granularity at
# which every watcher bound is re-checked, and therefore the WORST-CASE overshoot
# of any bound the watcher declares. Measured before this existed:
# `watch --tick-s 999999 --max-lifetime-s 5` slept ~11.5 DAYS — incident 2
# reproduced inside the mechanism built to prevent it, because the tick was
# handed straight to `sleep` and no bound was consulted again until it returned.
WATCH_SLEEP_SLICE_S=5
# The DECLARED overshoot allowance for ONE in-flight DEADLINE snapshot. The cap
# check happens between subjects, but a snapshot already under way runs three
# bounded probes (progress, done_when, optionally pr-ready.sh) and cannot be
# abandoned without losing the very record the deadline exists to produce. So the
# overshoot is bounded and NAMED rather than left implicit, and each probe inside
# a snapshot is additionally capped to the time remaining before this grace ends.
#
# 30s is deliberately SHORTER than one worst-case snapshot (three probes at
# PROBE_LIMIT_S, plus a 60s pr-ready.sh call). That is the point: a grace long
# enough to contain any snapshot would never truncate one, and a bound that never
# binds is not a bound. A snapshot started near the cap gets whatever time is
# left, and reports what it managed to measure.
WATCH_SNAPSHOT_GRACE_S=30
# Set by cmd_watch to (lifetime cap + grace). 0 means "no watcher lifetime in
# play" — the checkin/close/probe paths, which have no watcher to outlive.
WATCH_HARD_EXPIRE_AT=0
SILENT_FACTOR_NUM=3             # SILENT fires at 1.5x checkin_every_s,
SILENT_FACTOR_DEN=2             # expressed as a fraction (bash has no floats)
EVENT_TEXT_MAX=400              # truncation for probe output inside an event
BASELINE_TEXT_MAX=2000

# ⛔ SET BY cmd_watch AND CLEANED BY A TRAP THAT TAKES NO INTERPOLATED TEXT. ⛔
# The trap used to be built as `trap "rm -rf '$offsets_dir'" EXIT`, splicing a
# TMPDIR-derived path into shell code that runs at exit — so
# TMPDIR="/tmp/x'; touch /tmp/pwned; #" executed on watcher exit. Exactly the
# `--worktree` defect, in its sibling. A trap that names a FUNCTION interpolates
# nothing; the function reads the path from this variable at run time.
# Set ONLY by watch_deadline, and only when it has lost its id to a newer
# declaration. Empty means "write to the live log", which is every other caller.
EMIT_LOG_PATH=""

OBSERVE_OFFSETS_DIR=""
cleanup_offsets() {
  [[ -n "$OBSERVE_OFFSETS_DIR" ]] && rm -rf "$OBSERVE_OFFSETS_DIR"
  return 0
}

# ⛔ RESOLVE THE INSTALL ROOT THE SAME WAY install.sh DOES. ⛔ This file used to
# hardcode `$HOME/.claude`, while `scripts/install.sh` Step 5 puts a WINDOWS
# install in `%APPDATA%\Claude`. Windows is a supported target (README documents
# `%APPDATA%\Claude\`), and `CLAUDE_HOME` is not persisted for later
# invocations — so on an ordinary Windows install this script looked for its
# state, and for the two scripts it reuses, in a directory the installer had
# never written to. Not a degraded feature: observed-work simply did not work
# there, and nothing said so.
#
# Order matches install.sh: an explicit CLAUDE_HOME wins; then a real
# %APPDATA%\Claude (the `-d` test is what keeps a stray APPDATA on mac/linux from
# redirecting anything); otherwise ~/.claude.
observe_claude_home() {
  if [[ -n "${CLAUDE_HOME:-}" ]]; then printf '%s' "$CLAUDE_HOME"; return 0; fi
  if [[ -n "${APPDATA:-}" && -d "$APPDATA/Claude" ]]; then printf '%s' "$APPDATA/Claude"; return 0; fi
  printf '%s' "$HOME/.claude"
}
OBSERVE_CLAUDE_HOME=$(observe_claude_home)

OBSERVER_ROOT="${OBSERVER_ROOT:-$OBSERVE_CLAUDE_HOME/observer}"
ACTIVE_DIR="$OBSERVER_ROOT/active"
RETIRED_DIR="$OBSERVER_ROOT/retired"
LOG_DIR="$OBSERVER_ROOT/log"
STATE_DIR="$OBSERVER_ROOT/state"

# Reused rather than reimplemented. Both are optional: absence degrades a
# feature, it never fails a run (see the calls for what each absence costs).
PROGRESS_SIGNATURE_SCRIPT="${OBSERVE_PROGRESS_SCRIPT:-$OBSERVE_CLAUDE_HOME/scripts/loop-progress-signature.sh}"
PR_READY_SCRIPT="${OBSERVE_PR_READY_SCRIPT:-$OBSERVE_CLAUDE_HOME/scripts/pr-ready.sh}"

RECORD_FAILED_RC=4              # a terminal record could not be appended
TIMEOUT_RC=124                  # mirrors GNU timeout, for readability in logs

# TEST SEAM FOR THE PER-PROBE BOUND — TIGHTEN-ONLY.
# run_bounded's timeout arm is the single most load-bearing bound in this file
# (it is incident 2's answer for every caller-supplied command), and it had NO
# regression test: removing the arm left the whole suite green, because no test
# used a blocking predicate. A test that exercised the real 30s bound would add
# 30s per case to the suite, so this seam lets the suite use a 3s bound instead.
#
# ⛔ It can only make the bound TIGHTER. ⛔ A value above PROBE_LIMIT_S is
# ignored, so nothing reachable from this variable can lengthen a wait — the one
# thing an environment variable must never be able to do here.
if [[ -n "${OBSERVE_PROBE_LIMIT_S:-}" ]] \
   && [[ "${OBSERVE_PROBE_LIMIT_S}" =~ ^[0-9]{1,4}$ ]] \
   && (( 10#$OBSERVE_PROBE_LIMIT_S >= 1 )) \
   && (( 10#$OBSERVE_PROBE_LIMIT_S < PROBE_LIMIT_S )); then
  PROBE_LIMIT_S=$(( 10#$OBSERVE_PROBE_LIMIT_S ))
  (( PR_PROBE_LIMIT_S > PROBE_LIMIT_S )) && PR_PROBE_LIMIT_S=$PROBE_LIMIT_S
fi

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

die() { printf 'observe: %s\n' "$1" >&2; exit "${2:-2}"; }

usage() {
  cat <<'USAGE'
observe.sh — deterministic sensor for observed work (no model in the sensing path)

  observe.sh declare --id <task_id> --intent <one sentence: the DELIVERABLE>
                     --done-when <cmd exiting 0 when DONE>
                     --progress-probe <cmd whose output changes iff progress happened>
                     --checkin-every-s <N> --hard-deadline-s <N> --max-rounds <N>
                     [--worktree <path>] [--branch <name>] [--pr <owner/repo#N>]

  observe.sh checkin --id <task_id> --claim good|working|stuck [--note "..."]
  observe.sh probe   --id <task_id> --cmd "..."
  observe.sh watch   [--tick-s N] [--idle-exit-s N] [--max-lifetime-s N]
  observe.sh close   --id <task_id> --outcome shipped|abandoned
  observe.sh status

Exit codes (every code this script can return — see the EXIT CODES block in the
header for the full rationale):
  0  clean: the operation succeeded and nothing anomalous was found
  1  refused: `close --outcome shipped` while done_when is still false
  2  usage or environment error — treat as "did not run"
  3  an anomaly was recorded (MISMATCH / CHURN / NO_PROGRESS / DEADLINE)
  4  the operation ran but its RECORD COULD NOT BE WRITTEN
USAGE
}

iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
epoch_now() { date +%s; }

# Portable mtime. macOS `stat` speaks -f, GNU speaks -c, and neither knows the
# other's flag — probe both rather than assuming a platform.
file_mtime() {
  local f="$1" m=""
  m=$(stat -c %Y -- "$f" 2>/dev/null) || m=""
  [[ -n "$m" ]] || m=$(stat -f %m -- "$f" 2>/dev/null) || m=""
  printf '%s' "${m:-0}"
}

# Strip C0 control bytes except tab and newline. jq --arg escapes control
# characters correctly, so this is not a JSON-correctness fix — it is to keep
# terminal escape sequences and stray control bytes out of a log a human reads
# and out of the one-line stdout notification stream.
sanitise_text() {
  tr -d '\000-\010\013\014\016-\037' 2>/dev/null || cat
}

# Content hash used for the progress delta. Whichever hasher this platform
# ships; no secret is involved, so a missing hasher degrades to the raw text
# rather than failing the run.
text_hash() {
  local text="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$text" | shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$text" | sha256sum 2>/dev/null | awk '{print $1}'
  else
    printf '%s' "$text" | sed -e 's/[^A-Za-z0-9._-]/_/g' | cut -c1-64
  fi
}

truncate_text() {
  local text="$1" limit="$2"
  if (( ${#text} > limit )); then
    printf '%s…[truncated]' "${text:0:$limit}"
  else
    printf '%s' "$text"
  fi
}

first_line() { head -n 1 <<< "$1"; }

# Render text as EXACTLY ONE line, with newlines shown as a literal `\n`.
#
# ⛔ stdout IS THE NOTIFICATION STREAM, so an event that can contain a newline is
# an event that can FORGE another one. ⛔ Measured:
#   checkin --note $'\n2099-01-01T00:00:00Z DEADLINE <id> forged=1'
# printed what looked like a second, later event. The JSONL was never at risk —
# `jq --arg` escapes the newline correctly — but `jq -r` UN-escapes it on the way
# to stdout, and a terminal cannot tell a real event line from an injected one.
# Escaping rather than deleting keeps the forgery attempt visible in the record.
one_line() {
  local text="$1"
  # ⛔ CR AND LF ARE NOT THE ONLY BYTES THAT BREAK A LINE. ⛔ The first version
  # handled those two, and VT (0x0B), FF (0x0C), NEL (U+0085), LINE SEPARATOR
  # (U+2028) and PARAGRAPH SEPARATOR (U+2029) all survived `jq -r` into stdout,
  # where a terminal or log viewer may render any of them as a break — the same
  # forgery with a different byte. `sanitise_text` strips VT/FF from probe OUTPUT,
  # but a `--note` never passes through it, so this is where they must be caught.
  text="${text//$'\r'/ }"
  text="${text//$'\013'/ }"
  text="${text//$'\014'/ }"
  text="${text//$'\xc2\x85'/ }"
  text="${text//$'\xe2\x80\xa8'/ }"
  text="${text//$'\xe2\x80\xa9'/ }"
  # LF stays visible as a literal \n so a forgery attempt remains legible in the
  # record rather than silently vanishing.
  text="${text//$'\n'/\\n}"
  # ⛔ AND EVERY REMAINING CONTROL BYTE GOES, ESC AND BEL ESPECIALLY. ⛔ Stripping
  # line separators only stops forgery ACROSS lines; a terminal can be driven
  # WITHIN one. Measured on a `--note`: `\033[2K\r` reached stdout intact, and
  # that sequence erases the line and redraws it — so `BEFORE<ESC>[2K<CR>FORGED`
  # displays as `FORGED` alone. Same attack as the newline forgery already fixed
  # here, a different byte, and fixing one without the other left the notification
  # stream forgeable by anyone who could set a note. `sanitise_text` does this for
  # probe OUTPUT; a note never passes through it, which is why it must happen here.
  # Tab survives — it is layout, not control.
  text=$(printf '%s' "$text" | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' 2>/dev/null)
  printf '%s' "$text"
}

# require_task_id <id> <subcommand>
#
# ⛔ VALIDATED IN EVERY SUBCOMMAND, NOT JUST declare. ⛔ The id is interpolated
# into FOUR paths (active/, retired/, log/, state/), so a guard on one entry
# point is not a guard at all — it is the asymmetry class this repo keeps
# shipping. Measured before this existed:
#   checkin --id ../active/safe
# updated the GENUINE active/safe.json (refreshing its silence timer, so the
# watcher stayed quiet) while writing its events to active/safe.events.jsonl —
# leaving the canonical log/safe.events.jsonl the observer reads with nothing in
# it but the original DECLARED line. A hidden check-in is worse than a missing
# one: the silence detector was actively disarmed by it.
#
# The pattern also excludes traversal by construction: `..` cannot start an id
# (it must begin alphanumeric) and `/` is not in the character class.
require_task_id() {
  local task_id="$1" where="$2"
  [[ "$task_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] \
    || die "$where: --id must be 1-64 chars of [A-Za-z0-9._-] starting alphanumeric, got: $task_id"
}

# require_int <value> <name> <min> <max> — REJECT (never clamp) out of range.
require_int() {
  local value="$1" name="$2" min="$3" max="$4"
  [[ "$value" =~ ^[0-9]{1,9}$ ]] || die "$name must be a positive integer, got: $value"
  (( 10#$value >= min )) || die "$name must be >= $min (Rule 9 bound), got: $value"
  (( 10#$value <= max )) || die "$name must be <= $max (Rule 9 ceiling), got: $value"
}

# reject_process_group_escape <field> <command> — caller-supplied shell must not
# be able to move a probe out of the process group that run_bounded can sweep.
# A literal `setsid` is the obvious spelling, but command-position expansion can
# assemble the same executable without that token (`s=setsid; $s ...` or
# `s=setsid; ${!name} ...`). Reject those dynamic command-position forms, plus
# source/eval, before either declared or ad-hoc probes run. Variable expansion
# used as an argument remains allowed; the check is deliberately about the
# command position after a shell boundary.
reject_process_group_escape() {
  local field="$1" command="$2"
  # Only command-position expansions are dangerous here. A plain whitespace
  # boundary is not enough: it also precedes ordinary argument expansions such
  # as `printf '%s' "$(git rev-parse HEAD)"` and `echo "$HOME"`.
  local command_boundary_re=$'(^|[;|&(){}\n])[[:space:]]*'
  local dynamic_sub_re="${command_boundary_re}\"?\\$\\("
  local dynamic_var_re="${command_boundary_re}\"?\\$\\{!?[A-Za-z_]"
  local dynamic_plain_var_re="${command_boundary_re}\"?\\\$[A-Za-z_][A-Za-z0-9_]*"
  local dynamic_builtin_re="${command_boundary_re}(command|builtin)[[:space:]]+\"?\\\$"
  local backtick=$'\x60'
  local dynamic_backtick_re="${command_boundary_re}\"?${backtick}"
  if [[ "$command" =~ (^|[^[:alnum:]_])setsid([^[:alnum:]_]|$) ]] \
     || [[ "$command" =~ $dynamic_sub_re ]] \
     || [[ "$command" =~ $dynamic_var_re ]] \
     || [[ "$command" =~ $dynamic_plain_var_re ]] \
     || [[ "$command" =~ $dynamic_builtin_re ]] \
     || [[ "$command" =~ $dynamic_backtick_re ]] \
     || [[ "$command" =~ (^|[[:space:];|&])(eval|source)([[:space:];|&]|$) ]] \
     || [[ "$command" =~ (^|[[:space:];|&])\.([[:space:];|&]|$) ]]; then
    die "$field may not use an uncontainable command form that escapes the bounded process group (setsid, dynamic command-position expansion, source, or eval): $command"
  fi
}

# ---------------------------------------------------------------------------
# kill_probe_group <pgid> — TERM then KILL an entire probe process GROUP.
#
# ⛔ THE GROUP, NOT THE FOREGROUND CHILD. ⛔ `run_bounded` bounds the child it
# WAITS for, and the header's promise is about the WAIT. Those two coincide only
# when the predicate does not fork. Measured:
#   --done-when 'sleep 999999 & exit 1'
# returns its status INSTANTLY, so the sentinel arrives, the timeout arm never
# runs, and the backgrounded child outlives declare — forever. `pkill -P` cannot
# reach it either: its parent (`bash -c`) has exited, so it is reparented and no
# longer anyone's child. Process GROUP membership survives reparenting, which is
# why the group is the thing to signal.
#
# ⚠️ RESIDUE, STATED RATHER THAN GLOSSED: a probe that calls `setsid` (or otherwise
# leaves the group) escapes this too. Bash's `&` does not, so ordinary forking
# predicates are covered — but the guarantee is "no process left in the probe's
# process group", not "no descendant anywhere".
kill_probe_group() {
  local pgid="$1"
  [[ "$pgid" =~ ^[0-9]+$ ]] || return 0
  # Fast path: an empty group needs no signals, and this keeps the common case
  # (a probe that forked nothing) from paying the grace sleep below on every run.
  if command -v pgrep >/dev/null 2>&1 && ! pgrep -g "$pgid" >/dev/null 2>&1; then
    return 0
  fi
  kill -TERM "-$pgid" 2>/dev/null
  # pkill -P is kept as a fallback for the case where the group could not be
  # established (no job control): it reaches direct children only, which is
  # exactly the subset the group kill would otherwise have covered.
  command -v pkill >/dev/null 2>&1 && pkill -TERM -P "$pgid" 2>/dev/null
  sleep 1
  kill -KILL "-$pgid" 2>/dev/null
  command -v pkill >/dev/null 2>&1 && pkill -KILL -P "$pgid" 2>/dev/null
  return 0
}

# run_bounded <limit_s> <command> [<arg>…]  →  sets RB_RC and RB_OUT
#
# Trailing args are passed to `bash -c` as $1, $2, … so a PATH can be handed to a
# command as DATA. ⛔ NEVER interpolate a path into the command string. ⛝ The
# `--worktree` value used to be spliced in as `git -C '$worktree' …`, and an
# existing directory literally named  /tmp/wt'; touch /tmp/pwned; #  passed the
# `-d` check and then EXECUTED the injected command at deadline time — measured,
# /tmp/pwned was created. That is arbitrary execution reachable from a
# declaration field, and worse, it runs just before `done_when` is re-run, so it
# can manufacture a "finished" deadline snapshot.
#
# THE PORTABLE DEADLINE. This is the answer to incident 2 and it is the only
# way this script ever runs a caller-supplied command. `timeout`/`gtimeout` are
# absent on this machine, so the bound is: fork, poll `kill -0` against a
# `date +%s` deadline, then TERM and KILL. RB_RC is 124 on timeout, mirroring
# GNU timeout so the log reads the way a reader expects.
#
# A 1-second poll is deliberate. The pacing MUST come from a real clock —
# incident 1's monitor was told to pace itself and its "40 minutes" of checks
# took 48 seconds, because nothing in its loop actually waited.
# ---------------------------------------------------------------------------
RB_RC=0
RB_OUT=""

# ⛔ THE WHOLE IMPLEMENTATION'S stderr IS DISCARDED, DELIBERATELY. ⛔
# `set -m` (needed for the process group — see kill_probe_group) makes the shell
# REPORT each job's termination on its OWN stderr: lines like
#   observe.sh: line N: 46835 Terminated: 15   { bash -c "$cmd" … }
# Those come from the SHELL, about the job, asynchronously, at whatever command
# boundary it next notices — so neither a per-command `2>/dev/null` nor a braced
# group around the kill and the wait catches them reliably (both were tried and
# measured leaking). They landed in the watcher's output, which is the documented
# NOTIFICATION STREAM: a line there that is not an event teaches a reader to skim,
# and a skimmed stream is not an observation.
#
# Discarding is safe because run_bounded never intentionally writes to stderr —
# every diagnostic it produces goes into RB_OUT, and the probe's own stderr is
# already redirected into the output file. A redirection on a FUNCTION CALL does
# not fork a subshell, so RB_RC and RB_OUT are still set in the caller.
run_bounded() {
  run_bounded_impl "$@" 2>/dev/null
}

run_bounded_impl() {
  local limit="$1" cmd="$2"
  shift 2
  local out_file rc_file pid deadline now
  RB_RC=0
  RB_OUT=""

  out_file=$(mktemp "${TMPDIR:-/tmp}/observe.probe.XXXXXX" 2>/dev/null) || {
    RB_RC=126
    RB_OUT="observe: cannot create a temp file for probe output"
    return
  }
  rc_file="${out_file}.rc"

  # The child records its OWN exit status into a sentinel file, and the poll
  # waits for that file rather than for the process to disappear.
  # ⛔ `kill -0 "$pid"` is the obvious implementation and it is WRONG: a child
  # that has exited but not yet been reaped is a ZOMBIE, and `kill -0` reports a
  # zombie as alive. The poll would then spin all the way to the deadline for a
  # command that finished instantly — turning every bounded probe into a
  # full-length wait, which is incident 2 in miniature.
  # `observe-probe` is $0 for the child, so a caller's arg is $1 — see the header.
  #
  # `set -m` is what gives the job its OWN process group (pgid == $!), so the
  # group can be signalled without signalling this script. Monitor mode is
  # restored to whatever it was, because turning it on permanently would change
  # job-control behaviour for everything else in the run.
  local had_monitor=0
  case "$-" in *m*) had_monitor=1 ;; esac
  set -m
  { bash -c "$cmd" observe-probe "$@" >"$out_file" 2>&1; printf '%s' "$?" > "$rc_file"; } &
  pid=$!
  (( had_monitor )) || set +m
  deadline=$(( $(epoch_now) + limit ))

  while :; do
    if [[ -s "$rc_file" ]]; then
      RB_RC=$(cat "$rc_file" 2>/dev/null)
      [[ "$RB_RC" =~ ^[0-9]{1,3}$ ]] || RB_RC=1
      break
    fi
    now=$(epoch_now)
    if (( now >= deadline )); then
      kill -TERM "$pid" 2>/dev/null
      kill_probe_group "$pid"
      RB_RC=$TIMEOUT_RC
      break
    fi
    sleep 1
  done

  wait "$pid" 2>/dev/null
  # ⛔ SWEEP ON EVERY PATH, NOT ONLY ON TIMEOUT. ⛔ This is the line that closes
  # the fork escape: a command that RETURNED normally can still have left
  # background children behind, and before this sweep existed the timeout arm was
  # the only kill path — so a predicate that exits instantly left its children
  # running with nothing to stop them. The fast path in kill_probe_group makes
  # this free for the overwhelmingly common case of a probe that forked nothing.
  kill_probe_group "$pid"
  RB_OUT=$(sanitise_text < "$out_file" 2>/dev/null)
  rm -f "$out_file" "$rc_file"
}

# ---------------------------------------------------------------------------
# Event log. Every event is built with `jq -n --arg` — never string
# interpolation, so no probe output can forge a field or break a line.
#
# emit_event <task_id> <EVENT> <extra-json-object> [<continuation line>...]
# Appends one JSONL line and prints ONE LINE to stdout (plus any indented
# continuation lines, the way loop-progress-signature.sh prints its detail).
# ---------------------------------------------------------------------------
emit_notification() {
  # Run the write in a child that ignores SIGPIPE. A broken pipe otherwise kills
  # the whole observer before `|| :` can handle printf's non-zero status.
  (trap '' PIPE; printf '%s\n' "$1" 2>/dev/null || :)
}

emit_event() {
  local task_id="$1" event="$2" extra="${3:-}"
  shift 3 2>/dev/null || shift $#
  local line summary
  [[ -n "$extra" ]] || extra='{}'

  line=$(jq -c -n \
    --argjson ts "$(epoch_now)" \
    --arg iso "$(iso_now)" \
    --arg task_id "$task_id" \
    --arg event "$event" \
    --argjson extra "$extra" \
    '{ts: $ts, iso: $iso, task_id: $task_id, event: $event} + $extra' 2>/dev/null) || {
      printf 'observe: could not encode event %s for %s\n' "$event" "$task_id" >&2
      return 1
    }

  # EMIT_LOG_PATH lets a caller redirect its events AWAY from the live log. The
  # only user is watch_deadline, when it discovers mid-snapshot that a NEW
  # declaration has taken over the id — see lifecycle_is_current.
  printf '%s\n' "$line" >> "${EMIT_LOG_PATH:-$LOG_DIR/$task_id.events.jsonl}" || {
    printf 'observe: could not append to the event log for %s\n' "$task_id" >&2
    return 1
  }

  # One-line stdout rendering: <iso> <EVENT> <task_id> <k=v …>. Greppable, and
  # the whole line fits a notification.
  # one_line is what keeps "one line per event" TRUE. `jq -r` un-escapes the
  # newline that `jq --arg` correctly escaped into the log, so without this a
  # `--note` containing a newline prints an apparent second event line.
  summary=$(jq -r '[to_entries[] | select(.key | . != "ts" and . != "iso" and . != "task_id" and . != "event")
                    | "\(.key)=\(.value|tostring)"] | join(" ")' <<< "$line" 2>/dev/null)
  # The append above is the durable operation. stdout is only a notification
  # stream and may be closed by a caller or watcher pipe; notification failure
  # must not turn a successfully recorded event into a persistence failure.
  emit_notification "$(iso_now) $event $task_id $(one_line "$summary")"
  local cont
  for cont in "$@"; do
    emit_notification "  $(one_line "$cont")"
  done
  return 0
}

json_obj() {
  # json_obj k v k v … — build a flat JSON object with every value as a string,
  # safely. Numeric-looking values stay strings; readers use tostring anyway.
  local args=() filter="{" first=1 k v
  while (( $# >= 2 )); do
    k="$1"; v="$2"; shift 2
    args+=(--arg "$k" "$v")
    if (( first )); then first=0; else filter+=", "; fi
    filter+="\"$k\": \$$k"
  done
  filter+="}"
  jq -c -n "${args[@]}" "$filter" 2>/dev/null || printf '{}'
}

decl_path() { printf '%s/%s.json' "$ACTIVE_DIR" "$1"; }

decl_get() {
  # decl_get <field> <file>
  jq -r --arg k "$1" '.[$k] // "" | tostring' "$2" 2>/dev/null
}

# decl_set <file> <k> <v> [<k> <v> …] — atomic update via mktemp + mv, so a
# concurrent reader never sees a half-written declaration.
decl_set() {
  local file="$1"; shift
  local args=() filter="." k v tmp
  while (( $# >= 2 )); do
    k="$1"; v="$2"; shift 2
    args+=(--arg "$k" "$v")
    filter+=" | .[\"$k\"] = \$$k"
  done
  tmp=$(mktemp "${file}.tmp.XXXXXX" 2>/dev/null) || return 1
  if jq "${args[@]}" "$filter" "$file" > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    mv -f "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}

ensure_dirs() {
  mkdir -p "$ACTIVE_DIR" "$RETIRED_DIR" "$LOG_DIR" "$STATE_DIR" 2>/dev/null \
    || die "cannot create the observer state directories under $OBSERVER_ROOT"
}

require_jq() {
  command -v jq >/dev/null 2>&1 \
    || die "jq is required (every event is built with jq --arg, never string interpolation)"
}

# claim_declaration <task_id> — atomically TAKE OWNERSHIP of an active
# declaration by renaming it out of active/. rename(2) is atomic, so exactly one
# caller can win; every loser gets a non-zero return and must do nothing.
#
# ⛔ THIS IS WHAT MAKES THE DEADLINE ALERT SINGLE-FIRE. ⛔ The old order was
# measure → emit DEADLINE → retire, with nothing atomic anywhere in it. Two
# `watch` processes over the same OBSERVER_ROOT both saw the same overdue
# declaration, both spent seconds gathering a snapshot, and both emitted a
# DEADLINE before either retired it. Two alerts for one deadline is how an alert
# stream starts getting muted, and a muted alert is incident 2 with extra steps.
# TC-OBS-4j asserted "exactly one DEADLINE" with only ONE watcher running, so it
# could not see this.
claim_declaration() {
  local task_id="$1" file
  file=$(decl_path "$task_id")
  [[ -f "$file" ]] || return 1
  mv "$file" "$RETIRED_DIR/$task_id.json" 2>/dev/null && return 0
  # The rename failed. If the file is GONE, a concurrent caller claimed it and we
  # lost — do nothing. If it is STILL THERE the failure was environmental
  # (permissions, full disk), and removing it is the lesser evil: a declaration
  # nobody can retire re-fires its alert on every single tick.
  [[ -f "$file" ]] || return 1
  # Still there → the failure was environmental (permissions, full disk).
  # ⛔ NEVER just delete it. ⛔ An earlier version did, which destroyed the
  # declaration — its intent, its predicates and its bounds — to avoid a repeating
  # alert. Copy the content to retired/ FIRST, and remove the original only once
  # the copy is safely in place; if the copy fails, keep the declaration and let
  # the alert repeat, because a noisy alert is recoverable and a deleted
  # declaration is not.
  if cp "$file" "$RETIRED_DIR/$task_id.json" 2>/dev/null; then
    rm -f "$file" 2>/dev/null && return 0
  fi
  return 1
}

# retire <task_id> <reason> — claim the declaration, then record the retirement.
# This is what stops a deadline from becoming a spam loop.
retire() {
  local task_id="$1" reason="$2"
  claim_declaration "$task_id" || return 0
  # The emit result is CHECKED, not discarded: a retirement nobody can read about
  # is a bound that fired silently.
  emit_event "$task_id" "RETIRED" "$(json_obj reason "$reason")" || {
    printf 'observe: %s was retired (%s) but the RETIRED event could not be written\n' \
      "$task_id" "$reason" >&2
    return 1
  }
  return 0
}

# rotate_prior_lifecycle <task_id> <stamp> — a REUSED id must not inherit the
# previous lifecycle.
#
# ⛔ The log, the guard-2 signature state and the retired declaration are all
# keyed by id alone. ⛔ Re-declaring an id therefore appended a second lifecycle
# to the first one`s log: a new watcher relayed the OLD task`s MISMATCH events,
# guard 2 compared the new work`s failure signature against the old work`s, and
# the observer agent read two separate pieces of work as one. (This is why a
# reviewer re-declared `pr166-threads` as `pr166-threads-v2` rather than reuse
# the id — a workaround for a defect, not a convention.)
#
# Rotated rather than refused: reuse is legitimate (re-declaring after a failed
# attempt is the normal case), and history is preserved beside the fresh log
# instead of being deleted or silently merged.
rotate_prior_lifecycle() {
  local task_id="$1" stamp="$2"
  local log="$LOG_DIR/$task_id.events.jsonl"
  local state="$STATE_DIR/$task_id.progress"
  local retired="$RETIRED_DIR/$task_id.json"
  if [[ -f "$log" ]]; then
    mv -f "$log" "$LOG_DIR/$task_id.events.$stamp.jsonl" 2>/dev/null \
      || printf 'observe: could not rotate the prior event log for %s\n' "$task_id" >&2
  fi
  # Guard 2 state carries the PREVIOUS work`s failure signature. Kept, it would
  # make the new work`s first check-in look like a repeat of the old work`s last.
  [[ -f "$state" ]] && rm -f "$state" 2>/dev/null
  [[ -f "$retired" ]] && mv -f "$retired" "$RETIRED_DIR/$task_id.$stamp.json" 2>/dev/null
  return 0
}

# enforce_deadline <file> <task_id> <where> — return 0 if the declaration is
# still inside its deadline; otherwise take the DEADLINE snapshot, retire it, and
# return non-zero so the caller refuses the operation.
#
# ⛔ THE DEADLINE IS ENFORCED AT EVERY COMMAND, NOT ONLY BY THE WATCHER. ⛔
# It used to be checked in ONE place — watch_one — which made "every wait has a
# hard deadline" true only *while a watcher happened to be running*. And nothing
# in this toolbox starts or re-arms one: `rules/agents.md` mandates `declare`
# only, no command or hook launches `watch`, and the default watcher exits after
# 4h while a declaration may legitimately declare 6h. A declaration could
# therefore sit in active/ past its own bound indefinitely, with `checkin` and
# `close` happily servicing it — which is the bound not existing. Enforcing it
# here means the bound holds with NO watcher at all: the next command to touch
# the task is the one that ends it.
enforce_deadline() {
  local file="$1" task_id="$2" where="$3"
  local deadline_at now
  # ⛔ A MISSING ACTIVE FILE IS NOT "NOTHING TO ENFORCE". ⛔
  # It reads as clean only if you assume the file can only be gone because THIS
  # process consumed it. It can also be gone because a WATCHER retired it on its
  # deadline while we were running `done_when` — and then `decl_get` on the absent
  # file returned empty, the regex below failed, and this function reported the
  # task healthy. Measured: a watcher retiring `racer` two seconds into a `close`
  # produced `CLOSED racer outcome=shipped`, exit 0, appended AFTER the deadline —
  # walking straight past the one gate that exists to stop a false success.
  if [[ ! -f "$file" ]]; then
    printf 'observe: %s was retired by another process while %s was running — refusing to act on it\n' \
      "$task_id" "$where" >&2
    return 3
  fi
  deadline_at=$(decl_get deadline_at "$file")
  [[ "$deadline_at" =~ ^[0-9]+$ ]] || return 0
  now=$(epoch_now)
  (( now >= 10#$deadline_at )) || return 0
  watch_deadline "$file" "$task_id" "$now"
  printf 'observe: %s is PAST its declared hard deadline (%ss overdue) — RETIRED, not %sed\n' \
    "$task_id" "$(( now - 10#$deadline_at ))" "$where" >&2
  return 3
}

# ===========================================================================
# declare
# ===========================================================================
cmd_declare() {
  local task_id="" intent="" done_when="" progress_probe=""
  local checkin_every_s="" hard_deadline_s="" max_rounds=""
  local worktree="" branch="" pr=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)              [[ $# -ge 2 ]] || die "--id needs a value";              task_id="$2"; shift 2 ;;
      --intent)          [[ $# -ge 2 ]] || die "--intent needs a value";          intent="$2"; shift 2 ;;
      --done-when)       [[ $# -ge 2 ]] || die "--done-when needs a value";       done_when="$2"; shift 2 ;;
      --progress-probe)  [[ $# -ge 2 ]] || die "--progress-probe needs a value";  progress_probe="$2"; shift 2 ;;
      --checkin-every-s) [[ $# -ge 2 ]] || die "--checkin-every-s needs a value"; checkin_every_s="$2"; shift 2 ;;
      --hard-deadline-s) [[ $# -ge 2 ]] || die "--hard-deadline-s needs a value"; hard_deadline_s="$2"; shift 2 ;;
      --max-rounds)      [[ $# -ge 2 ]] || die "--max-rounds needs a value";      max_rounds="$2"; shift 2 ;;
      --worktree)        [[ $# -ge 2 ]] || die "--worktree needs a value";        worktree="$2"; shift 2 ;;
      --branch)          [[ $# -ge 2 ]] || die "--branch needs a value";          branch="$2"; shift 2 ;;
      --pr)              [[ $# -ge 2 ]] || die "--pr needs a value";              pr="$2"; shift 2 ;;
      -h|--help)         usage; exit 0 ;;
      *) die "declare: unknown argument: $1" ;;
    esac
  done

  # --- shape validation -----------------------------------------------------
  [[ -n "$task_id" ]] || die "declare: --id is required"
  # The task id becomes a filename, so constrain it rather than sanitising it —
  # a rejected id is a typo the caller fixes, a silently rewritten one is a
  # declaration nobody can find again. Same check in EVERY subcommand; see
  # require_task_id for the check-in that hid itself from the canonical log.
  require_task_id "$task_id" declare
  [[ -n "$intent" ]] || die "declare: --intent is required (one sentence naming the DELIVERABLE, not the activity)"
  [[ -n "$done_when" ]] || die "declare: --done-when is required (a command exiting 0 when the work is DONE)"
  [[ -n "$progress_probe" ]] || die "declare: --progress-probe is required (a command whose output changes iff progress happened)"
  require_int "$checkin_every_s" "--checkin-every-s" "$CHECKIN_EVERY_MIN_S" "$CHECKIN_EVERY_MAX_S"
  require_int "$hard_deadline_s" "--hard-deadline-s" "$HARD_DEADLINE_MIN_S" "$HARD_DEADLINE_MAX_S"
  require_int "$max_rounds" "--max-rounds" "$MAX_ROUNDS_MIN" "$MAX_ROUNDS_MAX"

  # `pr` is passed as arguments to pr-ready.sh, so it must be a shape, not free
  # text. Reject anything else outright.
  if [[ -n "$pr" ]]; then
    [[ "$pr" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\#[0-9]{1,9}$ ]] \
      || die "declare: --pr must look like owner/repo#123, got: $pr"
  fi

  ensure_dirs
  [[ -f "$(decl_path "$task_id")" ]] \
    && die "declare: $task_id is already active — close it first (observe.sh close --id $task_id --outcome abandoned)"

  # --- PREDICATE VALIDATION -------------------------------------------------
  # ⛔ THIS IS *NOT* WHAT CATCHES INCIDENT 2, AND THE COMMENT HERE USED TO SAY IT
  # WAS. Incident 2's predicate — `grep -q "TC-HI-3/3b" <file>` — RUNS FINE and
  # exits 1, which is indistinguishable from an honest "not done yet". Measured:
  # declare ACCEPTS it (done_when_rc=1, exit 0). Telling "never true" apart from
  # "not true yet" is the halting problem, and a heuristic that guessed would
  # reject legitimate work — so accepting it is correct, and `hard_deadline_s`
  # (mandatory, no default) is the guard that actually ends it. TC-OBS-5m pins
  # this so nobody "fixes" the acceptance into a rejection.
  #
  # What this block DOES catch is the cheap, decidable subset — two failures that
  # are visible in one execution:
  #
  #   done_when cannot EXECUTE (127 command not found, 126 not executable) →
  #     the predicate can never fire, so the observation would run to its
  #     deadline every single time.
  #   done_when is ALREADY TRUE → either the work is finished (nothing to
  #     observe) or the predicate is vacuous (it would report success
  #     immediately, which is worse than not observing at all).
  # ---------------------------------------------------------------------------
  # A SHELL SYNTAX ERROR is the third decidable failure, and it was being missed.
  # `--done-when 'if then'` exits 2, and the case below rejects only 0/124/126/127
  # — so the declaration was WRITTEN (measured) for a predicate that can never do
  # anything but print a parse error. That is NOT the deliberately-accepted
  # runnable-but-never-true case: this one does not run at all.
  #
  # `bash -n -c` PARSES WITHOUT EXECUTING (verified), so unlike an exit-code
  # heuristic it cannot be confused by a predicate that legitimately exits 2 —
  # `grep` does that on a read error.
  local syn_err
  reject_process_group_escape "declare: --done-when" "$done_when"
  reject_process_group_escape "declare: --progress-probe" "$progress_probe"
  if ! syn_err=$(bash -n -c "$done_when" 2>&1); then
    die "declare: --done-when is not valid shell (it cannot run at all, so it can never fire): $(one_line "${syn_err:-syntax error}") — $done_when"
  fi
  if ! syn_err=$(bash -n -c "$progress_probe" 2>&1); then
    die "declare: --progress-probe is not valid shell (it cannot run at all, so it can never show a delta): $(one_line "${syn_err:-syntax error}") — $progress_probe"
  fi

  run_bounded "$PROBE_LIMIT_S" "$done_when"
  local dw_rc="$RB_RC" dw_out="$RB_OUT"
  case "$dw_rc" in
    127) die "declare: --done-when could not execute (127 command not found): $done_when" ;;
    126) die "declare: --done-when could not execute (126 not executable): $done_when" ;;
    "$TIMEOUT_RC") die "declare: --done-when did not finish within ${PROBE_LIMIT_S}s — a predicate that cannot answer quickly cannot gate an observation: $done_when" ;;
    0) die "declare: --done-when is ALREADY TRUE. The work is either done, or the predicate is vacuous. Either way there is nothing to observe: $done_when" ;;
  esac

  run_bounded "$PROBE_LIMIT_S" "$progress_probe"
  local pp_rc="$RB_RC" pp_out="$RB_OUT"
  if (( pp_rc != 0 )); then
    die "declare: --progress-probe must exit 0 (got $pp_rc) — a probe that cannot run cannot detect progress: $progress_probe"
  fi
  [[ -n "${pp_out//[[:space:]]/}" ]] \
    || die "declare: --progress-probe produced no output — an empty probe reads as 'no delta' forever: $progress_probe"

  # --- THE SELF-ADVANCING PROBE ---------------------------------------------
  # ⛔ THIS IS THE HOLE UNDER THE WHOLE "A FALSE CLAIM CANNOT SURVIVE" CLAIM. ⛔
  # The script computes the MISMATCH verdict, but the DECLARING AGENT CHOOSES THE
  # INPUT to that computation — and choosing the input is enough to defeat it.
  # Measured: `--progress-probe 'date +%s'`, then a check-in one second later
  # claiming `working` with literally no work done → delta=1, exit 0, NO
  # MISMATCH. `printf "%s\n" "$$"` does the same, since each `bash -c` is a new
  # PID. Nothing about the probe was invalid; it simply measured something other
  # than the work.
  #
  # Run it TWICE with nothing in between. If the output changed, the probe is
  # measuring the passage of time (or a counter of its own invocations) rather
  # than the work, so REJECT it. The explicit `sleep 1` is what makes a
  # second-granularity clock probe detectable: without it the two runs can land
  # inside the same second and `date +%s` slips through.
  #
  # ⚠️ HONEST LIMIT, and the skill says so too: this catches a probe that
  # advances EVERY SECOND. A probe on a slower cycle — `date +%H`, a log file
  # something else appends to, a counter that ticks once a minute — still
  # advances without the work advancing, and this check will not see it. The
  # guarantee is "the probe was stable across two consecutive runs at declare
  # time", not "the probe measures the work".
  sleep 1
  run_bounded "$PROBE_LIMIT_S" "$progress_probe"
  # ⛔ THE rc CHECK IS A SEPARATE REJECTION, NOT A GUARD ON THE COMPARISON. ⛔
  # This block first read `if (( RB_RC == 0 )) && [[ hash != hash ]]`, which made
  # the whole check skippable: a STATEFUL probe that changes its output and exits
  # NON-ZERO on the second run was accepted, and then produced a false delta=1 on
  # every later check-in. The documentation already claimed "rejects it if the
  # output changed", so the code was weaker than its own description — the exact
  # overclaim this branch corrected once already.
  if (( RB_RC != 0 )); then
    die "declare: --progress-probe exited 0 on its first run and $RB_RC on an immediate second run with no work in between — an UNSTABLE probe cannot be a progress signal: $progress_probe"
  fi
  if [[ "$(text_hash "$RB_OUT")" != "$(text_hash "$pp_out")" ]]; then
    die "declare: --progress-probe output CHANGED between two back-to-back runs with NO work in between — it is measuring the clock or its own invocations, not the work, and would suppress every MISMATCH: $progress_probe"
  fi

  # --- write the declaration ------------------------------------------------
  local now baseline baseline_hash deadline_at
  now=$(epoch_now)
  # ⛔ EVERY DECLARATION CARRIES A UNIQUE LIFECYCLE ID. ⛔ An id can legitimately
  # be reused, so "which declaration is this?" cannot be answered by the id alone.
  # A process that claimed the PREVIOUS declaration and is still working (a
  # DEADLINE snapshot runs for seconds) needs to be able to tell that the id it
  # holds is no longer the one in active/ — see lifecycle_is_current.
  local lifecycle="${now}-$$-${RANDOM}"

  # Before anything is written under this id, move any PRIOR lifecycle aside.
  rotate_prior_lifecycle "$task_id" "$now"
  baseline=$(truncate_text "$pp_out" "$BASELINE_TEXT_MAX")
  baseline_hash=$(text_hash "$pp_out")
  deadline_at=$(( now + 10#$hard_deadline_s ))

  local tmp
  tmp=$(mktemp "$ACTIVE_DIR/.$task_id.XXXXXX" 2>/dev/null) \
    || die "declare: cannot stage the declaration under $ACTIVE_DIR"
  jq -n \
    --arg task_id "$task_id" \
    --arg intent "$intent" \
    --arg done_when "$done_when" \
    --arg progress_probe "$progress_probe" \
    --argjson checkin_every_s "$((10#$checkin_every_s))" \
    --argjson hard_deadline_s "$((10#$hard_deadline_s))" \
    --argjson max_rounds "$((10#$max_rounds))" \
    --arg worktree "$worktree" \
    --arg branch "$branch" \
    --arg pr "$pr" \
    --argjson declared_at "$now" \
    --argjson deadline_at "$deadline_at" \
    --arg baseline "$baseline" \
    --arg baseline_hash "$baseline_hash" \
    --arg lifecycle "$lifecycle" \
    '{task_id: $task_id, intent: $intent, done_when: $done_when,
      progress_probe: $progress_probe, checkin_every_s: $checkin_every_s,
      hard_deadline_s: $hard_deadline_s, max_rounds: $max_rounds,
      worktree: $worktree, branch: $branch, pr: $pr,
      declared_at: $declared_at, deadline_at: $deadline_at,
      baseline: $baseline, baseline_hash: $baseline_hash,
      last_probe_hash: $baseline_hash, last_probe_at: $declared_at,
      last_checkin_at: $declared_at, checkins: 0, rounds: 0,
      lifecycle: $lifecycle,
      silent_notified: "0", due_notified_at: "0"}' > "$tmp" 2>/dev/null \
    || { rm -f "$tmp"; die "declare: could not encode the declaration for $task_id"; }
  mv -f "$tmp" "$(decl_path "$task_id")" \
    || { rm -f "$tmp"; die "declare: could not install the declaration for $task_id"; }

  # The baseline is recorded from what THE SCRIPT ran, so it cannot be faked by
  # the declaring agent — that is the whole reason declare captures it here
  # rather than accepting a --baseline argument.
  # ⛔ CHECKED, AND ON FAILURE THE DECLARATION IS REMOVED AGAIN. ⛔ This was the
  # last unchecked `emit_event` in the file, and it had the same shape as the
  # `close` and `probe` bugs before them: the declaration was already installed in
  # active/, so an unwritable or full log left a task UNDER OBSERVATION whose own
  # log has no record that it was ever declared — and `declare` said 0. Measured:
  #   declare -> rc=0, DECLARED events on disk 0, active/<id>.json present
  # State and record must not be able to disagree, so the install is rolled back
  # rather than merely reported: a declaration with no DECLARED line is a task the
  # observer agent cannot read the terms of, and `close` would later re-run a
  # `done_when` nobody can see was validated.
  #
  # 4 (`RECORD_FAILED_RC`), matching cmd_probe and cmd_close rather than `die`ing
  # with 2: 2 means "did not run", and this DID run — the probes were executed and
  # the predicate validated. 4 means "there is no record", which is precisely the
  # state left behind here (issue #176 is about a 4 returned where a record HAD
  # been written; this path writes nothing and rolls back, so it does not add to
  # that class).
  if ! emit_event "$task_id" "DECLARED" "$(json_obj \
      intent "$intent" \
      done_when "$done_when" \
      done_when_rc "$dw_rc" \
      progress_probe "$progress_probe" \
      baseline_hash "$baseline_hash" \
      checkin_every_s "$checkin_every_s" \
      hard_deadline_s "$hard_deadline_s" \
      deadline_at "$deadline_at" \
      max_rounds "$max_rounds" \
      worktree "$worktree" branch "$branch" pr "$pr" \
      lifecycle "$lifecycle")" \
    "baseline: $(truncate_text "$(first_line "$pp_out")" 160)" \
    "done_when currently FALSE (rc=$dw_rc) — validated, not assumed" \
    "$( [[ -n "${dw_out//[[:space:]]/}" ]] && printf 'done_when said: %s' "$(truncate_text "$(first_line "$dw_out")" 160)" || printf 'done_when produced no output' )"; then
    # ⛔ REMOVE ONLY IF IT IS STILL OURS. ⛔ `decl_path` is a PATH, and a path is
    # not an identity: the id can be redeclared inside the window this emit spent
    # failing, and an unconditional `rm` would then delete the WINNER's live
    # declaration as the loser's cleanup — a worse bug than the one being fixed,
    # and the same class TC-OBS-30c pins for the close path's restore.
    if lifecycle_is_current "$task_id" "$lifecycle"; then
      rm -f "$(decl_path "$task_id")"
      printf 'observe: %s was NOT declared — the DECLARED record could not be written, so the declaration was removed\n' \
        "$task_id" >&2
    else
      printf 'observe: %s was NOT declared — the DECLARED record could not be written, and the id has since been redeclared, so nothing was removed\n' \
        "$task_id" >&2
    fi
    return "$RECORD_FAILED_RC"
  fi
  return 0
}

# ===========================================================================
# checkin
# ===========================================================================
cmd_checkin() {
  local task_id="" claim="" note=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)    [[ $# -ge 2 ]] || die "--id needs a value";    task_id="$2"; shift 2 ;;
      --claim) [[ $# -ge 2 ]] || die "--claim needs a value"; claim="$2"; shift 2 ;;
      --note)  [[ $# -ge 2 ]] || die "--note needs a value";  note="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "checkin: unknown argument: $1" ;;
    esac
  done
  [[ -n "$task_id" ]] || die "checkin: --id is required"
  require_task_id "$task_id" checkin
  case "$claim" in
    good|working|stuck) : ;;
    "") die "checkin: --claim is required (good|working|stuck)" ;;
    *) die "checkin: --claim must be one of good|working|stuck, got: $claim" ;;
  esac

  ensure_dirs
  local file; file=$(decl_path "$task_id")
  [[ -f "$file" ]] || die "checkin: no active declaration for $task_id (declare it first)"

  enforce_deadline "$file" "$task_id" checkin || return 3

  local done_when progress_probe max_rounds rounds checkins last_hash lifecycle
  # ⛔ WHICH DECLARATION AM I SERVICING? ⛔ Captured now, checked before the write.
  # `$file` is a PATH, and a path is not an identity: an id can be redeclared
  # while this check-in is inside its probes, and every field read below would
  # then be persisted onto a DIFFERENT declaration that happens to share the id.
  lifecycle=$(decl_get lifecycle "$file")
  done_when=$(decl_get done_when "$file")
  progress_probe=$(decl_get progress_probe "$file")
  max_rounds=$(decl_get max_rounds "$file")
  rounds=$(decl_get rounds "$file")
  checkins=$(decl_get checkins "$file")
  last_hash=$(decl_get last_probe_hash "$file")

  # The CLAIM is recorded first and verbatim. It is the only thing the agent
  # contributes, and it goes on the record BEFORE the measurement so the log
  # shows what was asserted and then what was true — never the other way round.
  #
  # ⛔ CHECKED, LIKE THE TERMINAL PATHS. ⛔ This append was the only unchecked one
  # left on the check-in path, and an unchecked one here is worse than most: the
  # CLAIM is the ONE thing the agent contributes, so a check-in that loses it
  # records the measurements with nothing to measure them AGAINST. Measured with
  # the log unwritable: rc=0, CLAIM events on disk 0, and `checkins` advanced 0->1
  # — a check-in that counted and restarted the silence timer on an event nobody
  # can find. Returning before the probes run also means the snapshot below is not
  # persisted, so the declaration stays exactly as it was.
  if ! emit_event "$task_id" "CLAIM" "$(json_obj claim "$claim" note "$note")"; then
    printf 'observe: the check-in for %s was NOT recorded — its CLAIM could not be written\n' \
      "$task_id" >&2
    return "$RECORD_FAILED_RC"
  fi

  # --- THE SCRIPT RE-RUNS THE PROBES ITSELF ---------------------------------
  run_bounded "$PROBE_LIMIT_S" "$progress_probe"
  local pp_rc="$RB_RC" pp_out="$RB_OUT" new_hash delta
  new_hash=$(text_hash "$pp_out")
  if (( pp_rc != 0 )); then
    # A probe that failed is NOT evidence of progress. Record the failure and
    # score the delta as zero — leaning the other way would let a broken probe
    # launder a false "working" claim past the MISMATCH check.
    delta=0
    new_hash="probe-failed-rc$pp_rc"
  elif [[ "$new_hash" == "$last_hash" ]]; then
    delta=0
  else
    delta=1
  fi

  run_bounded "$PROBE_LIMIT_S" "$done_when"
  local dw_rc="$RB_RC" dw_out="$RB_OUT" done_state
  if (( dw_rc == 0 )); then done_state="true"; else done_state="false"; fi

  emit_event "$task_id" "FACTS" "$(json_obj \
      probe_rc "$pp_rc" \
      probe_hash "$new_hash" \
      delta "$delta" \
      done_when_rc "$dw_rc" \
      done "$done_state" \
      round "$(( 10#$rounds + ( dw_rc == 0 ? 0 : 1 ) ))" \
      max_rounds "$max_rounds")" \
    "probe: $(truncate_text "$(first_line "$pp_out")" 160)" \
    "done_when: rc=$dw_rc $(truncate_text "$(first_line "$dw_out")" 120)"

  # ⛔ THE DEADLINE IS RE-CHECKED AFTER THE PROBES, NOT ONLY BEFORE THEM. ⛔
  # The preflight check at the top of this function reads the clock BEFORE running
  # two caller-supplied commands, each of which may take up to PROBE_LIMIT_S. A
  # check-in that started a second inside its deadline could therefore finish a
  # minute outside it and still be serviced — persisting a snapshot and resetting
  # the silence timer on a task whose bound had already expired. The CLAIM and
  # FACTS events above stay on the record either way: they are measurements that
  # genuinely happened. What must not happen is the declaration being kept alive.
  if enforce_deadline "$file" "$task_id" checkin; then
    :
  else
    return 3
  fi

  # Same window, different failure: the id may have been REDECLARED rather than
  # retired. Persisting here would stamp this check-in's counters onto work that
  # has not started.
  if ! lifecycle_is_current "$task_id" "$lifecycle"; then
    printf 'observe: %s was redeclared while this check-in was running — its snapshot was not persisted\n' \
      "$task_id" >&2
    return 3
  fi

  # --- persist the new snapshot BEFORE deciding ------------------------------
  local now new_rounds
  now=$(epoch_now)
  # A round is a check-in that did not find the work finished. CHURN therefore
  # bounds ATTEMPTS, not movement: a task whose files change every round and still
  # is not done after max_rounds IS churning — endless movement without completion
  # is the case the bound exists for. (A no-progress round is a different signal
  # and is reported separately as MISMATCH / NO_PROGRESS.) Do not "fix" this into
  # a delta-gated counter — TC-OBS-6a/6d pin delta-positive rounds reaching CHURN,
  # and gating on delta would delete the attempts bound and leave only the deadline.
  if (( dw_rc == 0 )); then new_rounds=$(( 10#$rounds )); else new_rounds=$(( 10#$rounds + 1 )); fi
  decl_set "$file" \
    last_probe_hash "$new_hash" \
    last_probe_at "$now" \
    last_checkin_at "$now" \
    checkins "$(( 10#$checkins + 1 ))" \
    rounds "$new_rounds" \
    silent_notified "0" \
    due_notified_at "0" \
    || die "checkin: could not update the declaration for $task_id"

  # --- THE VERDICTS, computed and not judged --------------------------------
  # Both MISMATCH rules are arithmetic on measurements this script just took.
  # No model is consulted, so a confidently-worded claim cannot survive one.
  local anomaly=0

  if [[ "$claim" == "working" ]] && (( delta == 0 )); then
    emit_event "$task_id" "MISMATCH" "$(json_obj \
        reason "working-no-delta" claim "$claim" delta "0" probe_rc "$pp_rc")" \
      "claimed 'working' but the progress probe output is UNCHANGED since the last check-in" \
      "probe: $progress_probe"
    anomaly=1
  fi

  if [[ "$claim" == "good" ]] && [[ "$done_state" == "false" ]]; then
    emit_event "$task_id" "MISMATCH" "$(json_obj \
        reason "good-not-done" claim "$claim" done_when_rc "$dw_rc")" \
      "claimed 'good' but done_when is still FALSE (rc=$dw_rc)" \
      "done_when: $done_when"
    anomaly=1
  fi

  # --- guard 2, reused ------------------------------------------------------
  # scripts/loop-progress-signature.sh answers a DIFFERENT question from the
  # delta above: "is the same FAILURE repeating?" rather than "did anything
  # move?". A round can be delta-positive (files changed) and still be the same
  # failure, which is exactly the case an mtime-style signal misses. Absent
  # script → skipped silently, as the spec requires; its absence costs the
  # signature check only, never the run.
  #
  # ⛔ SKIPPED WHEN done_when IS SILENT, and this is not an optimisation. ⛔
  # The detector's signature is (failing-gate set + top error identifier). Here
  # the gate set is the constant single gate `done_when`, so when the predicate
  # prints NOTHING the identifier is `nosignal` and the signature is IDENTICAL
  # on every check-in by construction — the detector would report no-progress on
  # the second round of every observation, including ones making obvious
  # progress. Measured: a `test -f <marker>` predicate with a real new commit
  # each round fired NO_PROGRESS anyway (caught by TC-OBS-2j before this guard
  # existed). `nosignal` being a signature rather than an abstention is CORRECT
  # in the detector's own context — a varying gate set failing unreadably twice
  # is real information — but with a fixed one-gate set it carries none, so
  # feeding it a silent predicate produces noise and noise gets muted. A
  # predicate that prints its failure (a test or build command) gets the full
  # check; a silent boolean is bounded by the round counter and CHURN instead.
  if [[ "$done_state" == "false" && -n "${dw_out//[[:space:]]/}" && -f "$PROGRESS_SIGNATURE_SCRIPT" ]]; then
    local sig_out_file sig_rc sig_out
    sig_out_file=$(mktemp "${TMPDIR:-/tmp}/observe.sig.XXXXXX" 2>/dev/null) || sig_out_file=""
    if [[ -n "$sig_out_file" ]]; then
      printf '%s\n' "$dw_out" > "$sig_out_file"
      sig_out=$(bash "$PROGRESS_SIGNATURE_SCRIPT" \
        --state "$STATE_DIR/$task_id.progress" \
        --failing-gates "done_when" \
        --output "$sig_out_file" 2>&1)
      sig_rc=$?
      rm -f "$sig_out_file"
      if (( sig_rc == 3 )); then
        emit_event "$task_id" "NO_PROGRESS" "$(json_obj \
            reason "signature-repeat" detail "$(truncate_text "$(first_line "$sig_out")" 200)")" \
          "the done_when failure signature has not changed across consecutive check-ins"
        anomaly=1
      fi
    fi
  fi

  # --- CHURN ---------------------------------------------------------------
  # Rounds counts check-ins where done_when was FALSE. Reaching max_rounds means
  # the work has had its declared number of attempts and is not done — that is a
  # plan problem, and it is reported as one rather than allowed to keep going.
  if (( new_rounds >= 10#$max_rounds )) && [[ "$done_state" == "false" ]]; then
    emit_event "$task_id" "CHURN" "$(json_obj \
        rounds "$new_rounds" max_rounds "$max_rounds" claim "$claim")" \
      "round $new_rounds of $max_rounds with done_when still FALSE — the approach is not converging"
    anomaly=1
  fi

  (( anomaly == 0 )) || return 3
  return 0
}

# ===========================================================================
# probe — an ad-hoc measurement that gets RECORDED
# ===========================================================================
cmd_probe() {
  local task_id="" cmd=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)  [[ $# -ge 2 ]] || die "--id needs a value";  task_id="$2"; shift 2 ;;
      --cmd) [[ $# -ge 2 ]] || die "--cmd needs a value"; cmd="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "probe: unknown argument: $1" ;;
    esac
  done
  [[ -n "$task_id" ]] || die "probe: --id is required"
  require_task_id "$task_id" probe
  [[ -n "$cmd" ]] || die "probe: --cmd is required"
  reject_process_group_escape "probe: --cmd" "$cmd"

  ensure_dirs
  # An ad-hoc probe is allowed against a RETIRED task too — a post-mortem
  # measurement is still a measurement, and refusing it would push the answer
  # back into prose, which is what this subcommand exists to prevent.
  #
  # ⛔ THIS COMMENT USED TO SAY `probe` DOES NOT CALL enforce_deadline. IT DOES —
  # see the record-then-enforce block at the end of this function. ⛔
  # That exemption was real once and was removed deliberately, because it left the
  # docs claiming the bound held at "every subcommand" while repeated probes could
  # keep an overdue declaration alive forever. The comment was not updated with the
  # code, so for one round it asserted the OPPOSITE of what ran.
  #
  # Worth naming, because it is the fourth correction to this one description and
  # the first in this direction: every previous fix here moved the DOCS toward the
  # CODE, and this one had to move a comment that the code had already left behind.
  # A description of enforcement that lives in four places drifts in whichever
  # place is not being edited.
  #
  # What survives of the original point: `status` is the sole exemption, because
  # it is read-only and must not mutate state at all.
  [[ -f "$(decl_path "$task_id")" || -f "$RETIRED_DIR/$task_id.json" || -f "$LOG_DIR/$task_id.events.jsonl" ]] \
    || die "probe: no declaration or event log for $task_id"

  run_bounded "$PROBE_LIMIT_S" "$cmd"
  local rc="$RB_RC" out="$RB_OUT"
  # Same class as close, and named here because `probe` EXISTS to turn a fact into
  # a record — "a fact the observer asked for becomes a logged measurement instead
  # of prose". A probe that returns 0 having recorded nothing is that promise
  # inverted, so the append is checked here too.
  if ! emit_event "$task_id" "PROBE" "$(json_obj \
      cmd "$cmd" rc "$rc" output "$(truncate_text "$out" "$EVENT_TEXT_MAX")")" \
    "rc=$rc $(truncate_text "$(first_line "$out")" 200)"; then
    printf 'observe: the probe for %s ran but its measurement could not be recorded\n' "$task_id" >&2
    return "$RECORD_FAILED_RC"
  fi

  # ⛔ RECORD FIRST, THEN ENFORCE — the ORDER is the whole design. ⛔
  # An earlier version exempted `probe` from the deadline entirely, reasoning that
  # the first question asked about an overdue task must not destroy the answer.
  # That reasoning was right and the conclusion was wrong: it left `rules/agents.md`
  # and the skill claiming the bound holds at "every subcommand" while repeated
  # probes could keep an overdue declaration active forever with no watcher
  # running. Recording the measurement BEFORE retiring gives both — the fact is
  # kept, and the task still ends. `status` remains the sole exemption, because it
  # is read-only and must not mutate state at all.
  local pfile; pfile=$(decl_path "$task_id")
  if [[ -f "$pfile" ]]; then
    enforce_deadline "$pfile" "$task_id" probe || return 3
  fi
  return 0
}

# ===========================================================================
# watch — the bounded notification loop
# ===========================================================================
# Rule 9 (`rules/workflow-discipline.md`) applies to this loop, and all three
# guards are named here explicitly rather than assumed:
#
#   Iteration ceiling  — TWO of them, because one is not enough for a watcher.
#                        `--max-lifetime-s` is an absolute wall-clock cap
#                        (clamped to WATCH_LIFETIME_MAX_S), and `--idle-exit-s`
#                        exits as soon as there is nothing left to watch. A
#                        watcher that outlives its subjects is incident 2 again.
#                        ⛔ AND BOTH ARE ONLY REAL BECAUSE OF bounded_sleep. ⛔
#                        A cap re-read once per `sleep "$tick_s"` is a cap the
#                        tick can jump over; see bounded_sleep for the measured
#                        11.5-day overshoot that shape produced.
#   No-progress        — the watcher does not need its own: it does no work to
#                        make progress ON. The observed WORK's no-progress guard
#                        is the signature check in checkin (guard 2, reused),
#                        and the watcher surfaces its NO_PROGRESS events.
#   Spend cap          — zero. This is a bash loop, not an agent: it spends no
#                        tokens and calls no model. That is the point of the
#                        whole design, and it is why this watcher is allowed to
#                        run for hours where a model-driven one is not.
#
# Every declaration additionally carries its own `hard_deadline_s`, so even an
# unbounded-looking watch retires each subject on schedule.
#
# ---------------------------------------------------------------------------
# bounded_sleep <want_s> <hard_stop_epoch>
#
# ⛔ THE ONLY WAY THIS SCRIPT IS ALLOWED TO SLEEP FOR A CALLER-SUPPLIED TIME. ⛔
# `sleep "$tick_s"` was the original code, and it was incident 2 rebuilt: the
# tick is caller-supplied and unbounded relative to the watcher's own caps, so
# `watch --tick-s 999999 --max-lifetime-s 5` slept ~11.5 days and observed
# NEITHER cap. A bound that is only read before a sleep is not a bound.
#
# Two properties make it one:
#   1. the sleep is CLAMPED to hard_stop_epoch, so it cannot end after the cap;
#   2. it is served in slices of at most WATCH_SLEEP_SLICE_S, so the caps are
#      re-read at most that far apart even if the arithmetic above were wrong.
# Property 2 is deliberate redundancy: the clamp is the fix, the slicing is what
# keeps a future arithmetic mistake from becoming another eleven hours.
# ---------------------------------------------------------------------------
bounded_sleep() {
  local want="$1" hard_stop="$2" now end slice
  [[ "$want" =~ ^-?[0-9]+$ ]] || want=1
  (( want >= 1 )) || want=1
  now=$(epoch_now)
  end=$(( now + want ))
  (( end > hard_stop )) && end=$hard_stop
  # Already at or past the hard stop: sleep the minimum quantum and return, so
  # the caller's loop reaches its own exit check instead of spinning on the CPU.
  if (( end <= now )); then sleep 1; return 0; fi
  while :; do
    now=$(epoch_now)
    (( now >= end )) && return 0
    slice=$(( end - now ))
    (( slice > WATCH_SLEEP_SLICE_S )) && slice=$WATCH_SLEEP_SLICE_S
    sleep "$slice"
  done
}

cmd_watch() {
  local tick_s="$WATCH_TICK_DEFAULT_S"
  local idle_exit_s="$WATCH_IDLE_EXIT_DEFAULT_S"
  local max_lifetime_s="$WATCH_LIFETIME_DEFAULT_S"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tick-s)         [[ $# -ge 2 ]] || die "--tick-s needs a value";         tick_s="$2"; shift 2 ;;
      --idle-exit-s)    [[ $# -ge 2 ]] || die "--idle-exit-s needs a value";    idle_exit_s="$2"; shift 2 ;;
      --max-lifetime-s) [[ $# -ge 2 ]] || die "--max-lifetime-s needs a value"; max_lifetime_s="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "watch: unknown argument: $1" ;;
    esac
  done

  [[ "$tick_s" =~ ^[0-9]{1,6}$ ]] && (( 10#$tick_s >= 1 )) || die "watch: --tick-s must be a positive integer"
  # ⛔ THE TICK IS CLAMPED TO THE RESCAN SLICE, AND THIS IS THE FIX FOR THE THIRD
  # SIGHTING OF INCIDENT 2. ⛔ The first fix clamped each SLEEP to the nearest
  # bound — but the bounds were computed from the set of declarations present
  # BEFORE the sleep, and nothing rescanned `active/` until the sleep ended.
  # Measured on that version: an EMPTY watcher started
  # `--tick-s 999999 --idle-exit-s 999999 --max-lifetime-s 28800` slept toward its
  # 8h cap; a task declared five seconds later with a 30s deadline produced NO
  # DEADLINE in 75 seconds. A task RETIRING mid-sleep delays idle exit the same
  # way. The whole defect lives in the transition, which is why T8/T11 — which
  # declare everything before the watcher starts — could not see it.
  #
  # A tick longer than the rescan interval is therefore not a cadence preference:
  # it is a window in which a declaration can appear, expire, and go unnoticed.
  # Clamped LOUDLY rather than silently honoured, the same stance as
  # --max-lifetime-s. Ticks at or below the slice are untouched.
  if (( 10#$tick_s > WATCH_SLEEP_SLICE_S )); then
    printf 'observe: --tick-s %s exceeds the rescan slice %ss — clamped (a longer tick is a window in which a new or retired declaration goes unnoticed)\n' \
      "$tick_s" "$WATCH_SLEEP_SLICE_S" >&2
    tick_s=$WATCH_SLEEP_SLICE_S
  fi
  [[ "$idle_exit_s" =~ ^[0-9]{1,7}$ ]] && (( 10#$idle_exit_s >= 1 )) || die "watch: --idle-exit-s must be a positive integer"
  [[ "$max_lifetime_s" =~ ^[0-9]{1,7}$ ]] && (( 10#$max_lifetime_s >= 1 )) || die "watch: --max-lifetime-s must be a positive integer"
  # Clamped rather than rejected: unlike a declaration's deadline, this bound has
  # a hard toolbox cap standing behind it, so tightening is safe and loud.
  if (( 10#$max_lifetime_s > WATCH_LIFETIME_MAX_S )); then
    printf 'observe: --max-lifetime-s %s exceeds the toolbox cap %s — clamped\n' \
      "$max_lifetime_s" "$WATCH_LIFETIME_MAX_S" >&2
    max_lifetime_s=$WATCH_LIFETIME_MAX_S
  fi

  ensure_dirs

  # Per-instance log offsets, so anomalies recorded by `checkin` reach this
  # stdout stream too. Starting from offset 0 means a watcher started AFTER a
  # MISMATCH still reports it — missing an anomaly is the worse failure, and a
  # restarted watcher replaying one is merely noisy.
  local offsets_dir
  offsets_dir=$(mktemp -d "${TMPDIR:-/tmp}/observe.watch.XXXXXX" 2>/dev/null) \
    || die "watch: cannot create a scratch directory for log offsets"
  OBSERVE_OFFSETS_DIR="$offsets_dir"
  trap cleanup_offsets EXIT

  local started_at expire_at idle_since now
  started_at=$(epoch_now)
  expire_at=$(( started_at + 10#$max_lifetime_s ))
  # The DECLARED hard ceiling, including the one-snapshot grace. Every probe run
  # inside a DEADLINE snapshot is capped against this, so the watcher's total life
  # is bounded by (cap + grace) rather than by (cap + however long the probes take).
  WATCH_HARD_EXPIRE_AT=$(( expire_at + WATCH_SNAPSHOT_GRACE_S ))
  idle_since=$started_at

  printf '%s WATCH_START - tick_s=%s idle_exit_s=%s max_lifetime_s=%s root=%s\n' \
    "$(iso_now)" "$tick_s" "$idle_exit_s" "$max_lifetime_s" "$OBSERVER_ROOT"

  while :; do
    now=$(epoch_now)

    if (( now >= expire_at )); then
      printf '%s WATCH_EXIT - reason=max-lifetime lived_s=%s\n' "$(iso_now)" "$(( now - started_at ))"
      return 0
    fi

    # `nearest_deadline` is read BEFORE watch_one runs, because watch_one may
    # retire the declaration and take the file with it.
    local active_count=0 file nearest_deadline=0 dl
    for file in "$ACTIVE_DIR"/*.json; do
      [[ -f "$file" ]] || continue
      # ⛔ THE LIFETIME CAP IS RE-CHECKED BEFORE EVERY SUBJECT. ⛔ Checking it only
      # at the top of the pass meant N overdue subjects multiplied the overshoot:
      # each one runs a snapshot of up to three bounded probes. Breaking here caps
      # the overshoot at ONE snapshot, and snapshot_limit below caps that snapshot
      # against WATCH_HARD_EXPIRE_AT so even the one in flight is bounded.
      if (( $(epoch_now) >= expire_at )); then break; fi
      active_count=$(( active_count + 1 ))
      dl=$(decl_get deadline_at "$file")
      if [[ "$dl" =~ ^[0-9]+$ ]] && (( nearest_deadline == 0 || 10#$dl < nearest_deadline )); then
        nearest_deadline=$(( 10#$dl ))
      fi
      watch_one "$file" "$offsets_dir" "$now"
    done

    # If the pass broke out on the lifetime cap, go straight back to the top so
    # the cap check there ends the run — a partial enumeration must never be read
    # as "nothing left to watch".
    if (( $(epoch_now) >= expire_at )); then continue; fi

    if (( active_count == 0 )); then
      if (( now - idle_since >= 10#$idle_exit_s )); then
        printf '%s WATCH_EXIT - reason=idle idle_s=%s lived_s=%s\n' \
          "$(iso_now)" "$(( now - idle_since ))" "$(( now - started_at ))"
        return 0
      fi
    else
      idle_since=$now
    fi

    # --- THE SLEEP IS WHERE EVERY BOUND IS EITHER HONOURED OR LOST ------------
    # Wake at the EARLIEST of: the next tick, the watcher's own lifetime cap, the
    # nearest subject's hard deadline, and the idle exit. The tick is already
    # clamped to WATCH_SLEEP_SLICE_S at validation, so this loop re-enumerates
    # `active/` at least that often — which is what makes a declaration that
    # appears or retires DURING a sleep visible. The minimum below only ever
    # shortens that further.
    #
    # Check-in nags (CHECKIN_DUE / SILENT) are deliberately NOT in this minimum:
    # they are reminders, and their own state guards keep them from repeating on
    # every pass. The DEADLINE is a bound, so it IS in the minimum.
    local wake_at want
    now=$(epoch_now)
    wake_at=$(( now + 10#$tick_s ))
    (( wake_at > expire_at )) && wake_at=$expire_at
    if (( nearest_deadline > now && nearest_deadline < wake_at )); then
      wake_at=$nearest_deadline
    fi
    # The idle exit is the watcher's third bound, so it goes in the minimum too:
    # with a long tick and nothing left to watch, the watcher would otherwise sit
    # until its lifetime cap — alive, useless, and exactly the orphaned-watcher
    # shape the cleanup trap in test-observe.sh calls incident 2 itself.
    if (( active_count == 0 )); then
      local idle_at=$(( idle_since + 10#$idle_exit_s ))
      if (( idle_at > now && idle_at < wake_at )); then wake_at=$idle_at; fi
    fi
    want=$(( wake_at - now ))
    bounded_sleep "$want" "$expire_at"
  done
}

# watch_one <declaration file> <offsets dir> <now>
watch_one() {
  local file="$1" offsets_dir="$2" now="$3"
  local task_id checkin_every_s last_checkin_at deadline_at silent_notified due_notified_at
  task_id=$(decl_get task_id "$file")
  [[ -n "$task_id" ]] || return 0
  # The id comes out of a FILE here, not off the command line, so it gets the
  # same shape check — a declaration hand-written into active/ must not be able
  # to steer the watcher's log and state writes somewhere else. Skipped loudly
  # rather than fatally: one malformed declaration must not stop the watcher
  # observing every other subject.
  if [[ ! "$task_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
    printf 'observe: skipping %s — its task_id is not a valid id: %s\n' "$file" "$task_id" >&2
    return 0
  fi
  checkin_every_s=$(decl_get checkin_every_s "$file")
  last_checkin_at=$(decl_get last_checkin_at "$file")
  deadline_at=$(decl_get deadline_at "$file")
  silent_notified=$(decl_get silent_notified "$file")
  due_notified_at=$(decl_get due_notified_at "$file")
  [[ "$checkin_every_s" =~ ^[0-9]+$ ]] || return 0
  [[ "$last_checkin_at" =~ ^[0-9]+$ ]] || return 0
  [[ "$deadline_at" =~ ^[0-9]+$ ]] || return 0
  [[ "$silent_notified" =~ ^[0-9]+$ ]] || silent_notified=0
  [[ "$due_notified_at" =~ ^[0-9]+$ ]] || due_notified_at=0

  # 1. Relay anomalies recorded by checkin (MISMATCH / CHURN / NO_PROGRESS).
  #    stdout is the notification stream, so an anomaly that only reached the
  #    log has not been reported.
  relay_log "$task_id" "$offsets_dir"

  # 2. DEADLINE takes precedence over everything, and retires the subject.
  if (( now >= 10#$deadline_at )); then
    watch_deadline "$file" "$task_id" "$now"
    return 0
  fi

  local quiet_s silent_at
  quiet_s=$(( now - 10#$last_checkin_at ))
  silent_at=$(( (10#$checkin_every_s * SILENT_FACTOR_NUM) / SILENT_FACTOR_DEN ))

  # 3. SILENT at 1.5x the declared interval — once per silence, re-armed by the
  #    next check-in (which resets silent_notified).
  if (( quiet_s >= silent_at )); then
    if (( 10#$silent_notified == 0 )); then
      emit_event "$task_id" "SILENT" "$(json_obj \
          quiet_s "$quiet_s" checkin_every_s "$checkin_every_s" threshold_s "$silent_at")" \
        "no check-in for ${quiet_s}s (1.5x the declared ${checkin_every_s}s interval) — summon a check-in"
      decl_set "$file" silent_notified "1"
    fi
    return 0
  fi

  # 4. CHECKIN_DUE at 1x — repeated at most once per interval so a slow task
  #    produces a reminder cadence rather than a line every tick.
  if (( quiet_s >= 10#$checkin_every_s )); then
    if (( 10#$due_notified_at == 0 || now - 10#$due_notified_at >= 10#$checkin_every_s )); then
      emit_event "$task_id" "CHECKIN_DUE" "$(json_obj \
          quiet_s "$quiet_s" checkin_every_s "$checkin_every_s" \
          deadline_in_s "$(( 10#$deadline_at - now ))")" \
        "check-in due: observe.sh checkin --id $task_id --claim <good|working|stuck>"
      decl_set "$file" due_notified_at "$now"
    fi
  fi
}

# relay_log <task_id> <offsets dir> — print anomaly events appended since the
# last tick. Offsets are line counts, which is safe because the log is
# append-only.
relay_log() {
  local task_id="$1" offsets_dir="$2"
  local log="$LOG_DIR/$task_id.events.jsonl"
  [[ -f "$log" ]] || return 0
  local off_file="$offsets_dir/$task_id.offset" seen=0 total
  [[ -f "$off_file" ]] && seen=$(cat "$off_file" 2>/dev/null)
  [[ "$seen" =~ ^[0-9]+$ ]] || seen=0
  total=$(wc -l < "$log" 2>/dev/null | tr -d ' ')
  [[ "$total" =~ ^[0-9]+$ ]] || return 0
  if (( total > seen )); then
    tail -n "$(( total - seen ))" "$log" 2>/dev/null \
      | jq -r 'select(.event == "MISMATCH" or .event == "CHURN" or .event == "NO_PROGRESS")
               | "\(.iso) \(.event) \(.task_id) relayed=1 reason=\(.reason // "-")"' 2>/dev/null
    printf '%s\n' "$total" > "$off_file"
  fi
}

# lifecycle_is_current <task_id> <lifecycle> — is the declaration we are holding
# still the one this id refers to?
#
# ⛔ AN ID IS NOT AN IDENTITY, BECAUSE IDS ARE REUSABLE. ⛔ `rotate_prior_lifecycle`
# fixed the STALE half of reuse (a new declaration inheriting the old log and
# guard-2 state). This is the CONCURRENT half: a watcher claims a declaration and
# spends seconds on its DEADLINE snapshot, the id is redeclared in that window,
# and the watcher then appends its `DEADLINE` and `RETIRED` into the log of a
# lifecycle it never observed. Measured: the new lifecycle's log went from 1 line
# (its own DECLARED) to 3 — DECLARED, DEADLINE, RETIRED — with the last two
# belonging to work that had already ended. Worse, the emit-failure path would
# `mv` the old declaration back over the NEW one.
#
# Returns 0 when the active or retired declaration is ours. A missing active
# declaration is not enough to return success: a newer lifecycle may have
# already closed and moved its record to retired/.
lifecycle_is_current() {
  local task_id="$1" mine="$2" file retired cur
  [[ -n "$mine" ]] || return 0          # pre-lifecycle declaration: nothing to compare
  file=$(decl_path "$task_id")
  if [[ -f "$file" ]]; then
    cur=$(decl_get lifecycle "$file")
    [[ -z "$cur" || "$cur" == "$mine" ]]
    return
  fi
  retired="$RETIRED_DIR/$task_id.json"
  [[ -f "$retired" ]] || return 1
  cur=$(decl_get lifecycle "$retired")
  [[ "$cur" == "$mine" ]]
}

# restore_claimed_declaration <task_id> <lifecycle> — put a claimed declaration
# back in active/ so the operation that failed to record can be retried.
#
# ⛔ ONLY IF THE RETIRED FILE IS DEMONSTRABLY OURS. ⛔ The previous predicate was
# `lifecycle_is_current`, which answers a DIFFERENT question — "has anyone taken
# this id?" — and returns TRUE when no active file exists. That is exactly the
# state left behind by a newer lifecycle being CLOSED, so a stale restore walked
# straight into it. Measured: L2 declared and closed as `shipped`, then L1's
# failed DEADLINE emit moved L2's retired JSON back into active/ — REOPENING a
# closed, shipped lifecycle and presenting finished work as still running.
#
# The right question is "is the file I am about to move back the one I claimed?",
# and the lifecycle recorded IN that file answers it. An exact match is required;
# anything else refuses. (Two pre-lifecycle declarations both carry an empty
# lifecycle and so still compare equal — that legacy pair is the one case this
# cannot separate, and this version cannot create it.)
restore_claimed_declaration() {
  local task_id="$1" mine="$2" retired active cur
  retired="$RETIRED_DIR/$task_id.json"
  active=$(decl_path "$task_id")
  [[ -f "$retired" ]] || return 1
  [[ -e "$active" ]] && return 1        # never overwrite a live declaration
  cur=$(decl_get lifecycle "$retired")
  [[ "$cur" == "$mine" ]] || return 1   # not ours — leave it retired
  mv "$retired" "$active" 2>/dev/null
}

# snapshot_limit <wanted_seconds> — cap a DEADLINE-snapshot probe to the time
# left before WATCH_HARD_EXPIRE_AT. Returns <wanted> unchanged when no watcher
# lifetime is in play (the checkin / close / probe paths), so those keep the full
# probe budget: they have no watcher to outlive.
snapshot_limit() {
  local want="$1" remaining
  if (( WATCH_HARD_EXPIRE_AT <= 0 )); then printf '%s' "$want"; return 0; fi
  remaining=$(( WATCH_HARD_EXPIRE_AT - $(epoch_now) ))
  (( remaining < 1 )) && remaining=1
  (( remaining < want )) && want=$remaining
  printf '%s' "$want"
}

# watch_deadline <file> <task_id> <now>
# THE SNAPSHOT IS GATHERED BY THIS SCRIPT, not asked of an agent. Incident 1 was
# a model asked to summarise a situation it had not measured; here the watcher
# measures first and the snapshot is what it measured.
watch_deadline() {
  local file="$1" task_id="$2" now="$3"
  local intent worktree branch pr progress_probe done_when hard_deadline_s deadline_at log lifecycle
  intent=$(decl_get intent "$file")
  # Captured with everything else, BEFORE the claim, because it is the only way to
  # tell later whether this id still refers to the declaration we are holding.
  lifecycle=$(decl_get lifecycle "$file")
  worktree=$(decl_get worktree "$file")
  branch=$(decl_get branch "$file")
  pr=$(decl_get pr "$file")
  progress_probe=$(decl_get progress_probe "$file")
  done_when=$(decl_get done_when "$file")
  hard_deadline_s=$(decl_get hard_deadline_s "$file")
  # Captured BEFORE the claim below — after it, `$file` no longer exists.
  deadline_at=$(decl_get deadline_at "$file")
  [[ "$deadline_at" =~ ^[0-9]+$ ]] || deadline_at=$now
  log="$LOG_DIR/$task_id.events.jsonl"

  # ⛔ CLAIM FIRST, THEN MEASURE. ⛔ The snapshot below takes seconds (three
  # bounded probes and possibly a network call), and that window is exactly where
  # a second watcher used to slip in and produce a duplicate alert. Claiming
  # first means the loser returns here having emitted nothing.
  claim_declaration "$task_id" || return 0

  local -a lines=()
  lines+=("intent: $(truncate_text "$intent" 200)")

  # git log -3, when a worktree was declared.
  local git_out="not declared"
  if [[ -n "$worktree" ]]; then
    if [[ -d "$worktree" ]]; then
      # The path is an ARGUMENT ($1), never part of the command string.
      run_bounded "$(snapshot_limit "$PROBE_LIMIT_S")" 'git -C "$1" log -3 --oneline' "$worktree"
      if (( RB_RC == 0 )); then git_out="$RB_OUT"; else git_out="git log failed rc=$RB_RC"; fi
    else
      git_out="declared worktree does not exist: $worktree"
    fi
  fi
  local gl
  while IFS= read -r gl; do
    [[ -n "$gl" ]] && lines+=("git: $gl")
  done <<< "$git_out"

  # The progress probe, re-run now.
  run_bounded "$(snapshot_limit "$PROBE_LIMIT_S")" "$progress_probe"
  local probe_rc="$RB_RC" probe_out="$RB_OUT"
  lines+=("probe(rc=$probe_rc): $(truncate_text "$(first_line "$probe_out")" 200)")

  # done_when, re-run now — the answer to "was it actually finished?".
  run_bounded "$(snapshot_limit "$PROBE_LIMIT_S")" "$done_when"
  local dw_rc="$RB_RC"
  lines+=("done_when(rc=$dw_rc): $( (( dw_rc == 0 )) && printf 'TRUE — the work finished but was never closed' || printf 'FALSE — the work did not finish inside its declared deadline' )")

  # PR state, reusing pr-ready.sh — it already does the sha-addressed
  # reviewer-run query correctly, and reimplementing that is how a false
  # merge-ready claim gets made. Absent script → one line saying so.
  if [[ -n "$pr" ]]; then
    if [[ -f "$PR_READY_SCRIPT" ]]; then
      local owner_repo pr_num
      owner_repo="${pr%%#*}"
      pr_num="${pr##*#}"
      # Same rule as the worktree above: script path, owner, repo and number are
      # all ARGUMENTS. `--pr` is shape-validated at declare time and
      # PR_READY_SCRIPT comes from the environment, but a guard that depends on
      # validation elsewhere is the asymmetry class again.
      run_bounded "$(snapshot_limit "$PR_PROBE_LIMIT_S")" 'bash "$1" "$2" "$3" "$4"' \
        "$PR_READY_SCRIPT" "${owner_repo%%/*}" "${owner_repo##*/}" "$pr_num"
      lines+=("pr($pr) rc=$RB_RC: $(truncate_text "$(first_line "$RB_OUT")" 200)")
    else
      lines+=("pr($pr): pr-ready.sh not installed — PR state not measured")
    fi
  fi

  lines+=("event log: $log (last written $(( now - $(file_mtime "$log") ))s ago)")

  # ⛔ DID WE STILL OWN THIS ID WHILE WE WERE MEASURING? ⛔ The snapshot above took
  # seconds. If the id was redeclared in that window, these events belong to a
  # lifecycle that no longer exists and must NOT be appended to the live log — a
  # reader would attribute a finished task's DEADLINE to work that just started.
  # They are written to an orphan log instead: nothing is lost, and the new
  # lifecycle's record stays clean.
  if ! lifecycle_is_current "$task_id" "$lifecycle"; then
    EMIT_LOG_PATH="$LOG_DIR/$task_id.events.orphaned-${lifecycle:-unknown}.jsonl"
    printf 'observe: %s was redeclared while its deadline snapshot was running — that snapshot went to %s\n' \
      "$task_id" "$EMIT_LOG_PATH" >&2
  fi

  # ⛔ THE EMIT RESULT IS CHECKED, AND FAILURE RESTORES THE DECLARATION. ⛔ The
  # claim above already moved the declaration out of active/. If the log cannot be
  # written, discarding it anyway would retire a task with NO DEADLINE event and
  # no retry — a bound that fired silently, which is worse than one that fires
  # late. Putting it back means the next pass (or the next command to touch it)
  # tries again.
  if ! emit_event "$task_id" "DEADLINE" "$(json_obj \
      hard_deadline_s "$hard_deadline_s" \
      overdue_s "$(( now - 10#$deadline_at ))" \
      done_when_rc "$dw_rc" \
      probe_rc "$probe_rc" \
      branch "$branch" pr "$pr")" \
    "hard deadline of ${hard_deadline_s}s reached — snapshot taken, then RETIRED" \
    "${lines[@]}"; then
    # ⛔ RESTORE ONLY IF THE ID IS STILL OURS. ⛔ Restoring unconditionally would
    # `mv` a finished declaration back over a NEWER one that legitimately holds
    # the id — destroying live work to retry dead work.
    if restore_claimed_declaration "$task_id" "$lifecycle"; then
      printf 'observe: could not record the DEADLINE for %s — declaration restored so the next pass retries\n' \
        "$task_id" >&2
    else
      printf 'observe: could not record the DEADLINE for %s, and the retired file is not the one this pass claimed — not restored\n' \
        "$task_id" >&2
    fi
    EMIT_LOG_PATH=""
    return 1
  fi

  # The declaration was already claimed above, so this only RECORDS the
  # retirement. Recording it is what stops a reached deadline from re-firing
  # every tick — an alert that repeats forever is ignored, and then it is
  # incident 2 with extra steps.
  emit_event "$task_id" "RETIRED" "$(json_obj reason "hard-deadline")" \
    || printf 'observe: %s was retired on its deadline but the RETIRED event could not be written\n' \
         "$task_id" >&2
  EMIT_LOG_PATH=""
  return 0
}

# ===========================================================================
# close
# ===========================================================================
cmd_close() {
  local task_id="" outcome=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)      [[ $# -ge 2 ]] || die "--id needs a value";      task_id="$2"; shift 2 ;;
      --outcome) [[ $# -ge 2 ]] || die "--outcome needs a value"; outcome="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "close: unknown argument: $1" ;;
    esac
  done
  [[ -n "$task_id" ]] || die "close: --id is required"
  require_task_id "$task_id" close
  case "$outcome" in
    shipped|abandoned) : ;;
    "") die "close: --outcome is required (shipped|abandoned)" ;;
    *) die "close: --outcome must be shipped or abandoned, got: $outcome" ;;
  esac

  ensure_dirs
  local file; file=$(decl_path "$task_id")
  [[ -f "$file" ]] || die "close: no active declaration for $task_id"

  # An overdue task is retired with a DEADLINE snapshot rather than closed with an
  # outcome. The snapshot states whether done_when is NOW true, so "finished, but
  # late" is still recorded — it is recorded as a measurement instead of as the
  # caller's chosen outcome.
  enforce_deadline "$file" "$task_id" close || return 3

  local done_when lifecycle
  done_when=$(decl_get done_when "$file")
  # Captured for the same reason as in checkin — the claim below is atomic on the
  # FILE, but the file at that path may by then belong to a newer declaration.
  lifecycle=$(decl_get lifecycle "$file")

  # RE-VERIFY. A close is the last place a false success claim can enter the
  # record, so `shipped` is a measurement here, never an assertion.
  run_bounded "$PROBE_LIMIT_S" "$done_when"
  local dw_rc="$RB_RC" dw_out="$RB_OUT"

  # Postflight, for the same reason as checkin: `done_when` just ran and may have
  # taken up to PROBE_LIMIT_S. A `close --outcome shipped` that began inside its
  # deadline must not write CLOSED after it.
  enforce_deadline "$file" "$task_id" close || return 3

  if [[ "$outcome" == "shipped" ]] && (( dw_rc != 0 )); then
    emit_event "$task_id" "CLOSE_REFUSED" "$(json_obj \
        outcome "$outcome" done_when_rc "$dw_rc" \
        detail "$(truncate_text "$(first_line "$dw_out")" 200)")" \
      "REFUSED: done_when is still FALSE (rc=$dw_rc) — this is not shipped" \
      "done_when: $done_when" \
      "close it as abandoned, or finish the work and close again"
    return 1
  fi

  # ⛔ CLAIM BEFORE EMITTING, EXACTLY AS watch_deadline DOES. ⛔ The order used to
  # be emit CLOSED then `retire`, so a concurrent retirement produced a CLOSED
  # record with no retirement behind it — and, because `retire` fails quietly when
  # the file is already gone, no sign that anything had gone wrong. Winning the
  # atomic rename is now the PERMISSION to write the outcome, which makes exactly
  # one process able to record a terminal state for a declaration.
  #
  # Read before the claim: after it, "$file" no longer exists.
  if ! lifecycle_is_current "$task_id" "$lifecycle"; then
    printf 'observe: %s was redeclared while this close was running — no outcome was written\n' \
      "$task_id" >&2
    return 3
  fi

  local c_rounds c_checkins
  c_rounds=$(decl_get rounds "$file")
  c_checkins=$(decl_get checkins "$file")

  if ! claim_declaration "$task_id"; then
    emit_event "$task_id" "CLOSE_REFUSED" "$(json_obj \
        outcome "$outcome" reason "already-retired" done_when_rc "$dw_rc")" \
      "REFUSED: another process retired $task_id while this close was running" \
      "its terminal record is already in this log — this close wrote no outcome" \
      || printf 'observe: %s refused this close, and the refusal could not be recorded\n' "$task_id" >&2
    return 1
  fi

  # ⛔ A FAILED TERMINAL APPEND IS A FAILED CLOSE. ⛔ Both emits below used to be
  # unchecked — CLOSED's result discarded entirely, RETIRED's downgraded to a
  # diagnostic — and the function returned 0 regardless. So a full disk, a
  # read-only volume or a permissions accident produced a REPORTED SUCCESS WITH
  # NOTHING ON DISK. Measured, with the log made unwritable:
  #     close --outcome shipped  ->  rc=0, CLOSED events on disk: 0
  # and the declaration already claimed, so the task had vanished from active/
  # too. No race needed. This is the third time this gate has been able to report
  # a success that did not happen, and refusing while the predicate is false is
  # worth nothing if it can ACCEPT while the record fails to write.
  if ! emit_event "$task_id" "CLOSED" "$(json_obj \
      outcome "$outcome" done_when_rc "$dw_rc" \
      rounds "$c_rounds" checkins "$c_checkins")" \
    "done_when rc=$dw_rc at close — verified, not assumed"; then
    # Nothing durable was written, so the task must go back to being observed
    # rather than silently disappearing into retired/ with no outcome.
    if restore_claimed_declaration "$task_id" "$lifecycle"; then
      printf 'observe: %s was NOT closed — the CLOSED record could not be written, declaration restored\n' \
        "$task_id" >&2
    else
      printf 'observe: %s was NOT closed — the CLOSED record could not be written, and the declaration could not be restored\n' \
        "$task_id" >&2
    fi
    return "$RECORD_FAILED_RC"
  fi

  # RETIRED failing is a LESSER failure and gets a different answer: CLOSED is
  # already durable, so the outcome happened and restoring would contradict the
  # record that now exists. The caller is still told, because an incomplete
  # terminal record is not a clean close.
  if ! emit_event "$task_id" "RETIRED" "$(json_obj reason "closed-$outcome")"; then
    printf 'observe: %s was closed but the RETIRED event could not be written — the record is incomplete\n' \
      "$task_id" >&2
    return "$RECORD_FAILED_RC"
  fi
  return 0
}

# ===========================================================================
# status
# ===========================================================================
cmd_status() {
  ensure_dirs
  local now file count=0
  now=$(epoch_now)

  printf 'observer root: %s\n' "$OBSERVER_ROOT"
  printf '%-24s %8s %10s %8s %10s  %s\n' "TASK" "AGE" "LAST-CHKIN" "ROUNDS" "DEADLINE" "INTENT"

  for file in "$ACTIVE_DIR"/*.json; do
    [[ -f "$file" ]] || continue
    count=$(( count + 1 ))
    local task_id declared_at last_checkin_at rounds max_rounds deadline_at intent
    task_id=$(decl_get task_id "$file")
    declared_at=$(decl_get declared_at "$file")
    last_checkin_at=$(decl_get last_checkin_at "$file")
    rounds=$(decl_get rounds "$file")
    max_rounds=$(decl_get max_rounds "$file")
    deadline_at=$(decl_get deadline_at "$file")
    intent=$(decl_get intent "$file")
    # Same file-sourced id check as watch_one. status only PRINTS, so a bad id
    # cannot redirect a write here — it is validated anyway so the listing never
    # shows a task name that no other subcommand would accept.
    if [[ ! "$task_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
      printf '%-24s %7s %9s %8s %9s  %s\n' "(invalid id)" "-" "-" "-" "-" "$file"
      continue
    fi
    [[ "$declared_at" =~ ^[0-9]+$ ]] || declared_at=$now
    [[ "$last_checkin_at" =~ ^[0-9]+$ ]] || last_checkin_at=$now
    [[ "$deadline_at" =~ ^[0-9]+$ ]] || deadline_at=$now
    printf '%-24s %7ss %9ss %8s %9ss  %s\n' \
      "$task_id" \
      "$(( now - 10#$declared_at ))" \
      "$(( now - 10#$last_checkin_at ))" \
      "$rounds/$max_rounds" \
      "$(( 10#$deadline_at - now ))" \
      "$(truncate_text "$intent" 70)"
  done

  if (( count == 0 )); then
    printf '(no active declarations)\n'
  fi
  return 0
}

# ===========================================================================
# main
# ===========================================================================
require_jq

SUBCOMMAND="${1:-}"
[[ $# -gt 0 ]] && shift

case "$SUBCOMMAND" in
  declare) cmd_declare "$@" ;;
  checkin) cmd_checkin "$@" ;;
  probe)   cmd_probe "$@" ;;
  watch)   cmd_watch "$@" ;;
  close)   cmd_close "$@" ;;
  status)  cmd_status "$@" ;;
  -h|--help|help) usage; exit 0 ;;
  "") usage >&2; exit 2 ;;
  *) die "unknown subcommand: $SUBCOMMAND (declare|checkin|probe|watch|close|status)" ;;
esac
