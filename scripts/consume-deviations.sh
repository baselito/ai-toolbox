#!/usr/bin/env bash

# =============================================================================
# scripts/consume-deviations.sh — the deterministic half of the toolbox
# self-improvement loop: surface, archive, dismiss, and build lessons
# candidates.
#
# WHY THIS SCRIPT EXISTS (issue #140):
# This behaviour used to live ENTIRELY in commands/review-pr.md Step 0.5 as
# English prose with illustrative shell fences. Prose has no compiler, and the
# consequences were measured over five review rounds on one branch:
#   - writers multiplied silently: five separate dismissal-log writers existed
#     where the design claimed exactly one;
#   - every test binding a prose rule was only as strong as a hand-written
#     needle. One round's needle was `>>.*dismissed`, which can only see
#     code-shaped appends — and the one writer that was never code-shaped
#     (English prose in `lessons-pr` step 7) passed straight through both the
#     fix and the test guarding the fix;
#   - five prose/comment-satisfiable assertions shipped before being caught.
# Severity fell every round; the CLASS did not converge. A script can be
# executed by a test, so a test can assert the BEHAVIOUR instead of asserting
# that a paragraph still says the right words.
#
# WHERE THE LINE IS DRAWN — read this before adding anything here.
# This script owns every operation that is DETERMINISTIC. It owns nothing that
# requires judgement.
#
# ⛔ THE STATE STORES, NAMED — "the four state stores" was this header's own
# false claim, and it is the exact defect class the script exists to remove: the
# file declares FIVE paths plus a pending glob, so "the four" was not even a
# determinate set, and a store nobody could name is a store nobody checks for a
# second writer. It is now a list, and the list is the claim:
#
#   WRITTEN ONLY HERE (no other file in the repo appends to or removes these):
#     ~/.claude/dismissed-deviations.log     `dismiss deviation`
#     ~/.claude/dismissed-lessons.log        `dismiss lesson`
#     ~/.claude/surfaced-deviations.log      `surface` (the reprint pointer)
#     ~/.claude/consumed-deviations/         `surface`/`archive` (the mv target)
#     ~/.claude/pending-lessons-deferred.jsonl  `defer` appends, `lessons` removes
#
#   WRITTEN ELSEWHERE, CONSUMED HERE — scripts/pr-postmerge-fold.sh creates both
#   pending families; this script only READS and RETIRES them:
#     ~/.claude/pending-deviations-<PR>.log     archived (moved) by `archive`
#     ~/.claude/pending-lessons-<PR>.jsonl      removed by `lessons` and `defer`
#
# Adding a write to any of the five above, anywhere else — including in a `.md`
# file as English — recreates the multiple-writer defect measured over five
# rounds. `defer` exists because two of those writers WERE English.
#
# Specifically:
#
#   IN  (here): enumerating snapshots, parsing JSONL, deriving and validating
#               hashes, the anchored dismissed/surfaced lookups, the surface
#               cap, the reprint pointer, the archive rule, the canonical
#               dismissal write, and the lessons candidate filter.
#   OUT (agent, and it MUST stay out): the interactive triage half — Step 7 and
#               Step 7b of commands/review-pr.md (`improve N`, `ignore N`,
#               `lessons-keep`, `lessons-drop`, `lessons-pr`). Those spawn
#               tasks, compose replies, scan UNTRUSTED bodies for prompt
#               injection, and run the AI+Codex consensus vote. Every one of
#               those is a judgement call on adversarial input; none of them
#               can be decided by a shell script, and pretending otherwise
#               would put a rubber stamp where a reader is required.
#
# THE AGENT CALLS THIS SCRIPT; IT DOES NOT REIMPLEMENT IT. If you find yourself
# writing a second copy of any rule below into a `.md` file, that is the exact
# defect this file exists to remove.
#
# CALLERS (all pass positional args; do NOT source this file):
#   commands/review-pr.md Step 0.5  — `surface`, then `lessons`
#   commands/review-pr.md Step 7    — `dismiss`, then `archive`
#   commands/review-pr.md Step 7b   — `dismiss` (with the `lesson` kind), and
#                                     `defer` for the `lessons-defer` reply
#
# -----------------------------------------------------------------------------
# INTERFACE
# -----------------------------------------------------------------------------
#   consume-deviations.sh surface OWNER REPO PR_NUMBER PR_STATE MODE
#       MODE is `attended` or `unattended` — see "ATTENDED vs UNATTENDED" below.
#       Surfaces undecided deviation records, archives fully-decided snapshots,
#       and maintains the reprint pointer.
#
#   consume-deviations.sh archive OWNER REPO
#       The archive rule ALONE, for the second call site: Step 7's cleanup
#       after a human triage reply appended dismissals. Runs the IDENTICAL
#       function `surface` runs — there is exactly one implementation of "may
#       this snapshot retire", because the previous arrangement (bash in
#       Step 0.5, English in Step 7) is precisely how the two halves drifted.
#
#   consume-deviations.sh dismiss KIND HASH_FULL < BODY
#       KIND is `deviation` or `lesson`. THE CANONICAL DISMISSAL WRITE — the
#       only writer of either dismissed log. The body is read from STDIN, never
#       from argv: it is untrusted multi-line text, argv is world-readable via
#       `ps`, and quoting it into a command line is the same shape of mistake
#       this loop keeps making. HASH_FULL is verified against the body before
#       anything is written (see the function for why).
#
#   consume-deviations.sh lessons OWNER REPO PR_NUMBER PR_STATE [REPO_ROOT]
#       Builds the deduplicated, not-yet-dismissed lessons candidate list and
#       prints it. Does NOT vote, does NOT decide — the AI+Codex consensus pass
#       and the injection scan are the agent's, and stay in review-pr.md.
#       Removes a per-PR snapshot only when THAT file was read in full, parsed
#       cleanly, and holds nothing undismissed. It is a DELETE, so read
#       `cmd_lessons`' accounting before changing anything near it.
#
#   consume-deviations.sh defer OWNER REPO PR_NUMBER
#       THE ONLY WRITER OF THE CROSS-PR DEFERRED QUEUE. Moves one PR's
#       undecided lessons records into ~/.claude/pending-lessons-deferred.jsonl
#       and removes the per-PR snapshot, so they resurface on a LATER merged PR.
#       Validates every record with the SAME validator `lessons` reads them
#       with — that is the whole point, see `lesson_record_hash`.
#
# ENVIRONMENT
#   HOME  — the ONLY environment input. The state directory is `$HOME/.claude`,
#           resolved once, below. `CLAUDE_HOME` is deliberately NOT consulted:
#           scripts/pr-postmerge-fold.sh WRITES the snapshots to a literal
#           `$HOME/.claude`, and scripts/verify.sh reads the backlog from the
#           same literal. A reader that honoured CLAUDE_HOME while the writer
#           did not would append human decisions to a file nothing consumes —
#           the stranded-queue failure this whole loop exists to end. Tests
#           redirect HOME; nothing else may redirect the state dir.
#
# EXIT CODES — deliberately only two, and here is why there is no third.
#   0  the run completed, INCLUDING a run that a gate refused (wrong repo, PR
#      not merged, symlinked state dir, missing jq/shasum). Callers must never
#      read a refusal as a failed step: scripts/pr-postmerge-fold.sh sets the
#      same precedent, and the Step 0.5 prose that preceded this script had a
#      real bug where a successful surface inherited exit 1 from a trailing
#      short-circuit test and looked like a failed step to its caller.
#   2  USAGE ERROR — a bad subcommand, a missing/invalid argument, a MODE that
#      is neither `attended` nor `unattended`, a malformed hash, or a dismissal
#      whose hash does not match its body. All of these are CALLER bugs, and
#      all of them are loud precisely because the alternative is guessing. A
#      usage error writes NOTHING.
#   There is no "work outstanding" exit code. Nothing would consume it,
#   scripts/selfimprovement-backlog.sh already reports the queue on every
#   verify.sh run, and an unused non-zero exit is a trap for the next caller.
#
# STDOUT CONTRACT
#   Human-readable text on stdout, warnings and refusals on stderr, and every
#   subcommand ends with ONE machine-readable summary line:
#       CONSUME-DEVIATIONS: <key>=<value> ...
#   That line is what a test (and the agent) binds to, so an assertion never
#   has to parse prose. `lessons` additionally prints each candidate as a
#   single `CANDIDATE <json>` line, so the agent gets structured records
#   without re-deriving them.
#
# `set -uo pipefail` (NOT `set -e`): every failure path below is handled
# explicitly, and a half-executed consumer is worse than a reported one.
# =============================================================================

set -uo pipefail

# ⛔ ONE SPELLING OF THE STATE DIRECTORY. ⛔ Everything below derives from this
# single definition, so a change here moves reader, writer and archive together.
# It must stay byte-identical in effect to scripts/pr-postmerge-fold.sh (which
# writes the snapshots) and scripts/verify.sh (which reads the backlog).
CLAUDE_DIR="$HOME/.claude"

DISMISSED_FILE="$CLAUDE_DIR/dismissed-deviations.log"
# SHOWN, not DECIDED — and the two logs authorize DIFFERENT things:
#   surfaced-deviations.log  → suppresses RE-PRINTING only (the resume pointer,
#                              so a capped run continues instead of reprinting
#                              its first 15 records forever).
#   dismissed-deviations.log → the ONLY thing that authorizes ARCHIVAL.
# Do NOT consult SURFACED_FILE in the archive pass. It used to be consulted,
# and that single `grep` was enough to declare the whole backlog drained with
# ZERO human decisions: a record printed once into an unattended cron session
# satisfied it, the snapshot was archived, and `dir_has_file "$CONSUMED_DIR"`
# then flipped DEV_LOOP_COMPLETED in scripts/selfimprovement-backlog.sh — so a
# queue nobody triaged reported as "no self-improvement backlog".
SURFACED_FILE="$CLAUDE_DIR/surfaced-deviations.log"
CONSUMED_DIR="$CLAUDE_DIR/consumed-deviations"
DISMISSED_LESSONS_LOG="$CLAUDE_DIR/dismissed-lessons.log"
DEFERRED_LESSONS="$CLAUDE_DIR/pending-lessons-deferred.jsonl"

# First-run cap. 57 unique records were queued when this was written; dumping
# all of them is not a triage prompt, it is a wall of text nobody answers.
SURFACE_CAP=15

# The one regex that says what a valid key looks like. Held in a variable
# because an unquoted `\.`/`{}` on the right of `=~` is not portable.
HASH_RE='^[0-9a-f]{64}$'
# The writer (scripts/pr-postmerge-fold.sh) only ever emits
# pending-deviations-<PR NUMBER>.log. Requiring digits costs nothing real and
# removes a whole class of escape — see `dev_enumerate_snapshots`.
DEVNAME_RE='^pending-deviations-[0-9]+\.log$'
# The lessons half needs the identical rule for the identical reason, and it went
# without one for four rounds: `scripts/pr-postmerge-fold.sh` only ever emits
# pending-lessons-<PR NUMBER>.jsonl, while the sweep filtered on `-f`/`! -L`
# alone. Verified before this line existed: a hand-maintained
# `pending-lessons-archive-2026-Q1-manual-notes.jsonl` was read as a snapshot and
# then DELETED — and deletion is the only unrecoverable operation in this file.
# The cross-PR deferred queue keeps its own exact-path handling; this regex
# excludes it too (`deferred` is not digits), which is why the explicit skip at
# the glob is documented there as defence in depth rather than the only thing
# keeping the two paths apart.
LESSONNAME_RE='^pending-lessons-[0-9]+\.jsonl$'

usage() {
  cat >&2 <<'USAGE'
usage:
  consume-deviations.sh surface OWNER REPO PR_NUMBER PR_STATE attended|unattended
  consume-deviations.sh archive OWNER REPO
  consume-deviations.sh dismiss deviation|lesson HASH_FULL   (body on stdin)
  consume-deviations.sh lessons OWNER REPO PR_NUMBER PR_STATE [REPO_ROOT]
  consume-deviations.sh defer OWNER REPO PR_NUMBER
USAGE
}

# Every subcommand ends with exactly one of these. Keeping the prefix in one
# function means a caller can grep for a single token.
summary() {
  printf 'CONSUME-DEVIATIONS: %s\n' "$*"
}

# --- shared guards -----------------------------------------------------------

# ⛔ SYMLINK DEFENSE ⛔ — state files live in ~/.claude/ (outside any repo), so
# a malicious PR branch cannot replace them with symlinks. We still check that
# ~/.claude/ itself is not one (rare, but possible if a user has linked their
# home config elsewhere): better to skip the self-improvement loop than risk
# clobbering unintended paths. Cheapest check, and it covers every `mkdir` and
# `touch` below, which is why it runs before all of them.
claude_dir_is_symlink() {
  [[ -L "$CLAUDE_DIR" ]]
}

# ⛔ REPO GATE ⛔ — snapshots are keyed by PR NUMBER ALONE with no owner/repo in
# the name, and only the toolbox fold writes them, so every
# pending-deviations-*.log in ~/.claude is a TOOLBOX snapshot. The passes that
# SWEEP their whole snapshot set rather than reading one PR's file make the
# shared key space a hard requirement rather than a per-PR coincidence: a run
# from a project repo would enumerate, surface and then archive away the ENTIRE
# toolbox queue. The `--auto` leg of the caller's condition has no repo gate of
# its own, so this is the only thing standing there.
#
# FOUR CALL SITES, AND ONE DELIBERATE EXEMPTION — the count is stated because an
# earlier version of this comment said "both consumers" while there were three:
#   `cmd_surface`, `cmd_archive`, `cmd_lessons`, `cmd_defer` — every pass that
#   enumerates, retires or deletes a file it did not name.
#   `cmd_dismiss` is EXEMPT and takes no owner/repo at all. See its header for
#   the compensating control; do not "fix" it by adding a gate.
is_toolbox_repo() {
  [[ "${1:-}" == "baselito" && "${2:-}" == "ai-engineering" ]]
}

# PRESERVE on a missing tool — silent data loss is worse than a visible
# message. The snapshots stay queued and the next run with the tool drains them.
#
# `shasum` is the sharper of the two, and it was unguarded for a long time: a
# missing shasum does not merely stop the run, it makes every
# `HASH=$(… | shasum …)` yield the EMPTY STRING, so the anchored pattern
# degrades to `^\[\] ` and every record collapses onto ONE key. Verified with
# shasum shadowed by a stub exiting 127: three snapshots holding three DISTINCT
# bodies surfaced 1 of 3 records and wrote `[] <ISO> | …` markers, after which a
# single dismissal in that shape archived ALL THREE — a silent mass-archive
# reached by a missing-tool accident with no attacker involved.
#
# ⛔ THIS IS THE ONE PLACE THE TOOL REQUIREMENT IS DECIDED — ALL FOUR PASSES CALL
# IT. ⛔ It had exactly ONE caller for three rounds while `surface` and `lessons`
# hand-rolled the same two `command -v` tests inline, so a third required tool
# added here would have guarded `archive` alone. The passes that need to name a
# DIFFERENT consequence per tool still run `command -v` — but only AFTER this
# function has already refused, and only to pick which message to print. Adding a
# tool here now refuses every pass; see those call sites for what a third tool
# still has to add.
have_tools() {
  command -v jq >/dev/null 2>&1 && command -v shasum >/dev/null 2>&1
}

# The FULL 64-character digest. The 8-character form derived from it is DISPLAY
# ONLY — something a human retypes. Keying anything on 8 hex characters (32
# bits) means one record's dismissal can retire a DIFFERENT record whose body
# merely shares a prefix.
body_hash() {
  printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

# The sanitizing pipeline, in the ONE place it now lives. Each stage earns its
# place, and neither substitutes for the other:
#   `tr '\n' ' '` keeps one decision on one LINE, so a multi-line body can never
#                 become two log records — any line after the first would start
#                 at column 1 and defeat the `^\[<hash>\] ` anchor outright.
#   `tr -d '[]'`  removes the raw material a forged marker needs, so a future
#                 format change cannot silently make the anchor the only defence.
#   `cut -c1-80`  only then truncates.
# Reproduced with NO attacker and nothing crafted: an engineer files a deviation
# ABOUT this loop whose body pastes the surfaced-log line it concerns, then does
# ONE ordinary `ignore` on the write-up.
#
# ⛔ WHICH STAGE DEFENDS, MEASURED — because this paragraph used to imply it was
# the truncation. ⛔ The hazard belongs to the PRE-FIX pipeline, i.e. a raw
# "first 80 characters" with NO `tr` stages in front of it: read line-oriented,
# `cut -c1-80` emitted a THREE-line entry whose second line was the full victim
# marker at column 1; read byte-oriented, `head -c 80` emitted `[<hash>] 20`, and
# eleven characters already suffice because the archive pass only needs
# `^\[<hash>\] ` to match. Either way the victim counted as decided and its
# snapshot was archived un-triaged.
#
# With `tr '\n' ' '` in place, cut-vs-head is UNOBSERVABLE — executed both ways
# against a write-up whose first bytes are the victim's marker: `victim marker
# forged at col1? -> 0`, `archived=0 still_queued=1` in both. So `tr '\n' ' '` is
# what defends, `tr -d '[]'` is what keeps the anchor from having to be perfect
# alone, and `cut -c1-80` is a display bound. Do not read the `cut` as a security
# control; do not remove either `tr` believing the `cut` covers it.
sanitize_excerpt() {
  printf '%s' "$1" | tr '\n' ' ' | tr -d '[]' | cut -c1-80
}

# ⛔ ONE DEFINITION OF "A LESSONS RECORD THIS LOOP CAN ACT ON", TWO CALL SITES. ⛔
# `.finding`, `.verdict` and `.origin` all present and non-null (`jq -er` fails on
# a missing key AND on a null value), plus a derivable, well-formed digest of the
# finding. Prints the FULL digest and returns 0; prints nothing and returns
# non-zero when the record is unusable.
#
# WHY IT IS A FUNCTION RATHER THAN TWO COPIES: `cmd_lessons` READS the deferred
# queue and `cmd_defer` WRITES to it. While the writer was English prose in
# commands/review-pr.md the record format was never stated at all, so the writer's
# idea of a valid record could not even be compared with the reader's — and a
# record the reader cannot parse raises `parse_failures`, which disables the only
# branch that can drain that file. A stranded queue, on the ordinary path, with
# nobody attacking anything. A writer that cannot be weaker than its reader is the
# whole point of collapsing them here.
#
# The digest is over `.finding` ALONE, deliberately: the same finding re-captured
# with a different verdict or origin is the same finding, and both the dedupe and
# the dismissed-log lookup must treat it that way.
lesson_record_hash() {
  local _rec="$1" _f _h
  _f=$(printf '%s' "$_rec" | jq -er '.finding' 2>/dev/null) || return 1
  printf '%s' "$_rec" | jq -er '.verdict' >/dev/null 2>&1 || return 1
  printf '%s' "$_rec" | jq -er '.origin'  >/dev/null 2>&1 || return 1
  _h=$(body_hash "$_f")
  # Validate the key before anything uses it as a key: on a shasum failure the
  # substitution yields the EMPTY STRING, the anchored lookup degrades to
  # `^\[\] `, and one marker in that shape suppresses every finding at once.
  [[ "$_h" =~ $HASH_RE ]] || return 1
  printf '%s' "$_h"
}

# ⛔ ANCHOR THE HASH TO ITS COLUMN — never a bare substring match. ⛔ Both logs
# are written as `[<hash>] <ISO> | <80-char excerpt>`, so the hash is a
# LINE-LEADING FIELD and the match must say so. The excerpt on that same line is
# UNTRUSTED body text, so an unanchored match lets one record's body forge
# another record's marker. No attacker is needed: deviations routinely discuss
# the toolbox, and any body quoting a hash in bracket form collides by accident.
# A false hit no longer merely skips a printout — it authorizes the `mv`.
# The interpolated value is validated against HASH_RE by every caller, so it
# carries no regex metacharacters.
hash_logged_in() {
  local hash="$1" file="$2"
  grep -qE "^\[$hash\] " "$file" 2>/dev/null
}

# Portable membership set. Deliberately NOT `declare -A`: this file has a
# `#!/usr/bin/env bash` shebang and stock macOS ships bash 3.2, where
# `declare -A` fails and `set[k]=1` silently creates an INDEXED array whose
# subscript arithmetic-evaluates to 0 — so every hash would collapse onto index
# 0 and the per-run dedupe would treat every record as already seen. The old
# in-markdown version ran in the agent's zsh and could get away with it; a real
# script cannot. Record counts here are in the dozens, so a linear scan costs
# nothing.
# ⛔ BOTH TAKE THE VARIABLE NAME, NEVER THE VALUE. ⛔ An API where one half takes
# a name and the other takes a value is a fail-OPEN trap on a fail-closed path:
# `set_has parse_fail_files "$x"` would compare against the literal string
# "parse_fail_files", never match, and the file would silently stop being
# excluded from the archive pass. Symmetry costs one `eval` and removes the
# whole class.
set_add() {  # set_add <setvar> <member>
  local _cur
  eval "_cur=\${$1}"
  eval "$1=\"\${_cur}|\$2|\""
}
set_has() {  # set_has <setvar> <member>
  local _cur
  eval "_cur=\${$1}"
  case "$_cur" in *"|$2|"*) return 0 ;; esac
  return 1
}

# =============================================================================
# ENUMERATION
# =============================================================================

# Populates ALL_DEV_SNAPSHOTS. Returns non-zero when nothing is queued, so a
# caller can test it directly.
#
# ⛔ SWEEP EVERY PENDING SNAPSHOT, not just one PR's. ⛔ Reading only the merging
# PR's own snapshot file was the bug that stranded this whole half of the loop:
# a snapshot written for PR #129 is only ever re-read by a run FOR #129, and
# once #129 merged nothing ever ran for it again. Measured consequence — 6
# snapshots / 75 records / 57 unique bodies sat unread in ~/.claude while
# dismissed-deviations.log stayed 0 bytes. Nothing failed; the loop simply never
# reached its last stage.
dev_enumerate_snapshots() {
  # `nullglob` so an unmatched glob expands to nothing instead of handing the
  # LITERAL pattern to the loop body.
  #
  # ⛔ WHAT IT ACTUALLY BUYS, MEASURED — the previous comment claimed more. ⛔ It
  # said removal makes the run "report nothing to triage on a full queue". Run
  # both ways, empty queue and full: the summary lines are BYTE-IDENTICAL,
  # because the `-f` filter one line below independently rejects the literal
  # pattern (no file is named `pending-deviations-*.log`). So this is tidiness and
  # defence in depth, not a live defect — the `-f` test is the load-bearing half.
  #
  # ⛔ NEVER RESTORED, AND THAT IS CURRENTLY HARMLESS. ⛔ `shopt -s nullglob` is
  # process-wide and nothing turns it back off; the same is true of the `shopt` in
  # `cmd_lessons`. Verified inert today: this file contains exactly two pathname
  # globs and both are inside these two functions. A glob added ANYWHERE after
  # either call inherits nullglob invisibly, so if you add one, say which
  # behaviour you are relying on.
  shopt -s nullglob
  ALL_DEV_SNAPSHOTS=()
  local _snap
  for _snap in "$CLAUDE_DIR"/pending-deviations-*.log; do
    # ⛔ REGULAR FILES ONLY, FILTERED AT THE SOURCE. ⛔ Two distinct escapes
    # close here, and both must be filtered before the ordering pass below so
    # the ordering pass inherits the filter:
    #  1. `! -L` here, not only in a later guard. A later guard walks the
    #     ALREADY-EXPANDED list, so a SYMLINKED DIRECTORY named
    #     pending-deviations-<n>.log had its ENTRIES expanded first and the
    #     per-file symlink test then saw only those entries — ordinary files,
    #     each passing — so the guard was bypassed by the thing it was meant to
    #     catch.
    #  2. `-f` at all. `ls -t` given a DIRECTORY lists its CONTENTS as bare
    #     basenames, which then resolve relative to CWD — the repo root — and
    #     get `mv`d out of the working tree. Verified against the pre-fix code.
    [[ -f "$_snap" && ! -L "$_snap" ]] || continue
    # ⛔ THE NAME MUST BE THE NAME THE WRITER WRITES. ⛔ Neither test above
    # constrains the name, and a regular file called
    # `pending-deviations-1 victim.log` passed both, then split into
    # `pending-deviations-1` and a bare `victim.log` resolved against CWD.
    [[ "$(basename "$_snap")" =~ $DEVNAME_RE ]] || continue
    ALL_DEV_SNAPSHOTS+=( "$_snap" )
  done

  # Most-recent-first, so a capped run shows the freshest deviations. `ls -t`
  # (mtime descending) is the only portable ordering available: `stat -f %m` is
  # macOS-only, `stat -c %Y` is GNU-only, and `find -printf` does not exist on
  # macOS while CI runs ubuntu. Sorting by FILENAME would be wrong twice over —
  # lexicographic puts `...-105` before `...-99`, and PR number is not recency.
  #
  # ⛔ A SORT MAY ONLY PERMUTE THE SET — IT MAY NEVER ADD TO IT. ⛔ The old form
  # was an UNQUOTED command substitution inside an array assignment, so the
  # output was subject to word splitting AND pathname expansion. Reading
  # line-oriented fixes the splitting and the globbing; the membership test
  # fixes the injection, because a permutation of a set cannot contain a
  # non-member.
  if [[ ${#ALL_DEV_SNAPSHOTS[@]} -gt 1 ]]; then
    local _sorted=() _line _cand _member
    while IFS= read -r _line; do
      [[ -z "$_line" ]] && continue
      _member=false
      for _cand in "${ALL_DEV_SNAPSHOTS[@]}"; do
        [[ "$_cand" == "$_line" ]] && { _member=true; break; }
      done
      [[ "$_member" == "true" ]] && _sorted+=( "$_line" )
    done < <(ls -t "${ALL_DEV_SNAPSHOTS[@]}" 2>/dev/null)
    # FAIL CLOSED ON A LOSSY ORDERING PASS: if the permutation did not return
    # exactly what went into it (an unreadable directory, a name holding a
    # literal newline, an `ls` failure), keep the UNSORTED validated set — a
    # dropped snapshot is a stranded record, whereas an unordered sweep costs
    # only recency in the surface listing.
    if [[ ${#_sorted[@]} -eq ${#ALL_DEV_SNAPSHOTS[@]} ]]; then
      ALL_DEV_SNAPSHOTS=( "${_sorted[@]}" )
    fi
  fi
  [[ ${#ALL_DEV_SNAPSHOTS[@]} -gt 0 ]]
}

# Any swept file that is itself a symlink. The sweep widened what gets opened,
# so it must widen what gets checked. (`dev_enumerate_snapshots` already
# excludes symlinks at the source; this is the second line of defence for
# anything that becomes one between the two passes.)
dev_symlink_in_set() {
  local f
  for f in ${ALL_DEV_SNAPSHOTS[@]+"${ALL_DEV_SNAPSHOTS[@]}"}; do
    [[ -L "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# ⛔ ONE PRECONDITION, TWO ENTRY POINTS — CALL IT, NEVER COPY IT. ⛔
# `surface` and `archive` both reach `dev_archive_pass`, which `mkdir`s,
# `touch`es and `mv`s inside the state dir. Only `surface` grew this check;
# `archive` was left with `claude_dir_is_symlink` alone, and the gap was
# reproduced on BYTE-IDENTICAL state, no attacker step in between:
#   - `consumed-deviations` pointed outside ~/.claude — `surface` refused and
#     kept the records queued, while `archive` reported archived=1 and landed
#     the snapshot OUTSIDE the state dir, where nothing ever reads it again;
#   - `dismissed-deviations.log` symlinked to an attacker-written file —
#     `surface` refused, while `archive` retired a snapshot no human had
#     triaged, on the strength of dismissals nobody made.
# A SECOND COPY of the checks is exactly how the archive rule itself drifted
# (see this file's header), so there is one implementation and both entry
# points call it.
#
# REQUIRES `dev_enumerate_snapshots` TO HAVE RUN — the per-snapshot leg reads
# ALL_DEV_SNAPSHOTS, so calling this before the enumeration would check an
# empty set and pass vacuously. Both call sites place it immediately after.
#
# Prints the offending path (or the literal `state` when the violation is one
# of the fixed paths rather than a swept file) and returns 0 WHEN VIOLATED, so
# a caller reads it as "there is a problem, and here it is".
#
# SURFACED_FILE is checked on the archive path too, even though `archive` never
# touches it, and that is deliberate rather than sloppy reuse: a symlink on any
# of the four is evidence the state dir has been tampered with, and refusing
# the whole run costs one DEFERRED archive that the next clean run performs —
# whereas archiving under tampered state destroys the queue's only record that
# the work was never triaged.
state_symlink_violation() {
  local sym=""
  sym=$(dev_symlink_in_set) || sym=""
  if [[ -n "$sym" || -L "$DISMISSED_FILE" || -L "$SURFACED_FILE" || -L "$CONSUMED_DIR" ]]; then
    printf '%s' "${sym:-state}"
    return 0
  fi
  return 1
}

# =============================================================================
# THE ARCHIVE RULE — ONE implementation, TWO call sites
#
# Archive (never delete) any snapshot whose EVERY record has been DECIDED — i.e.
# is present in dismissed-deviations.log. A file with even one undecided record
# stays queued, so a capped run cannot strand its tail.
#
# ⛔ "DECIDED", NOT "SEEN". ⛔ Do not add SURFACED_FILE to this test; see the
# SURFACED_FILE declaration above for what that cost.
#
# ⛔ THE ARCHIVE IS EARNED, NEVER DEFAULTED. ⛔ `_complete` used to start at
# `true`, so EVERY path that ran the loop body zero times concluded "all records
# decided" and reached the `mv`. Two shapes did exactly that, neither needing an
# attacker: a 0-BYTE snapshot (the fold's awk has emitted one, when a stray
# apostrophe truncated its single-quoted program) and a BLANK-LINES-ONLY
# snapshot. Archiving one destroys no records — it has none — but it DOES create
# a file in $CONSUMED_DIR, and `dir_has_file "$CONSUMED_DIR"` in
# scripts/selfimprovement-backlog.sh is completion evidence: one empty snapshot
# silently retires the "this loop has never completed a triage" warning for good.
# So the accounting is explicit rather than inferred: COUNT the records actually
# confirmed dismissed, COUNT the ones that block, and conclude "complete" only
# from those two numbers.
#
# WHY IT IS SELF-SUFFICIENT (no skip-list argument): every condition that used
# to be pre-computed by the surface pass and passed in as a skip list is
# re-derived here — unreadable, legacy-format, unparseable record, empty body,
# underivable hash. That is what lets Step 7's cleanup call the SAME function
# after a triage reply instead of following an English restatement of it. The
# two call sites cannot disagree, because there is only one of them.
#
# Sets ARCH_ARCHIVED (count) and prints one line per archived file.
# =============================================================================
dev_archive_pass() {
  ARCH_ARCHIVED=0
  local _snap _first _complete _decided _outstanding _record _body _phase _hash _dest _n
  for _snap in ${ALL_DEV_SNAPSHOTS[@]+"${ALL_DEV_SNAPSHOTS[@]}"}; do
    # FAIL CLOSED ON AN UNREADABLE SNAPSHOT. A file that cannot be opened runs
    # the loop body ZERO times, which is indistinguishable from "every record is
    # decided". Verified end-to-end with `chmod 000`: the snapshot was archived,
    # a success message was printed, and selfimprovement-backlog.sh then
    # reported ZERO backlog. No attacker required — a permissions accident, a
    # root-owned file, or a concurrent partial write is enough.
    [[ -f "$_snap" && -r "$_snap" && ! -L "$_snap" ]] || continue
    # Per-file legacy-format guard: a pre-JSONL snapshot is skipped, never
    # archived. With a sweep, one legacy file must not blind the run to the
    # others, and it must never be retired on the strength of records nothing
    # could read.
    _first=$(head -1 "$_snap" 2>/dev/null)
    if [[ -n "$_first" ]] && ! printf '%s' "$_first" | jq -e . >/dev/null 2>&1; then
      continue
    fi

    _complete=false
    _decided=0
    _outstanding=0
    # ⛔ RESET THE CARRY VARIABLE PER FILE. ⛔ The `|| [[ -n "$_record" ]]`
    # EOF-residue guard makes this loop read a variable nothing clears between
    # snapshots, so a `break` leaves the last record of file N in scope while
    # file N+1 is opened. One assignment removes a dependency on an untested
    # property of the current break set.
    _record=''
    # ⛔ `|| [[ -n "$_record" ]]` — PROCESS THE EOF RESIDUE. ⛔ `read` returns
    # non-zero at EOF without a delimiter, so a final JSON object with NO
    # TRAILING NEWLINE was read into the variable and then dropped: the loop
    # body never ran for it, the snapshot looked fully decided, and it was
    # archived with a live record inside. A truncated write, a `printf` without
    # `\n`, or an editor that strips the final newline is enough.
    while IFS= read -r _record || [[ -n "$_record" ]]; do
      # Blank lines are NOT records: skipping them must affect NEITHER tally.
      # Counting one as outstanding would strand a fully-decided queue forever,
      # which is the same failure as draining one that was not.
      [[ -z "$_record" ]] && continue
      _body=$(printf '%s' "$_record" | jq -er '.body' 2>/dev/null) \
        || { _outstanding=$((_outstanding+1)); break; }
      # ⛔ VALIDATE `.phase` TOO — THE TWO PASSES MUST AGREE ON WHAT A VALID
      # RECORD IS. ⛔ The surface pass requires BOTH `.body` and `.phase`
      # (`jq -er` fails on a missing key and on a null value). This pass once
      # checked only `.body`, so `{"body":"x"}` was judged a complete, decided
      # record here while the surface pass had refused to show it — the snapshot
      # could then be archived holding a record no human ever saw. The parsed
      # value is deliberately unused: the successful PARSE is the assertion.
      _phase=$(printf '%s' "$_record" | jq -er '.phase' 2>/dev/null) \
        || { _outstanding=$((_outstanding+1)); break; }
      # ⛔ AN EMPTY BODY FAILS CLOSED HERE — `continue` DOES NOT. ⛔ A bare
      # `continue` leaves the record uncounted in BOTH tallies, so a file whose
      # only other records were decided satisfies `_decided > 0 &&
      # _outstanding == 0` and archives anyway. Counting it as OUTSTANDING is
      # what actually holds the file.
      [[ -z "$_body" ]] && { _outstanding=$((_outstanding+1)); break; }
      _hash=$(body_hash "$_body")
      # Same validation as the surface pass, but note the DIFFERENT failure
      # action and do not "harmonise" them: here the fail-closed move counts the
      # record as OUTSTANDING and breaks. `continue` would skip it without
      # counting it either way, so an unhashable record among otherwise-decided
      # ones would leave `_outstanding` at 0 and AUTHORIZE the `mv`.
      [[ "$_hash" =~ $HASH_RE ]] || { _outstanding=$((_outstanding+1)); break; }
      hash_logged_in "$_hash" "$DISMISSED_FILE" \
        && { _decided=$((_decided+1)); continue; }
      _outstanding=$((_outstanding+1)); break
    done < "$_snap"

    # ⛔ TWO CONDITIONS, AND THE FIRST ONE IS THE LOAD-BEARING ONE. ⛔
    #   _decided > 0      — at least one record was READ and found in the
    #                       dismissed log. This is what makes a ZERO-RECORD
    #                       snapshot archive NOTHING: it produces no decisions,
    #                       so it can never be "complete". Without it an empty
    #                       file sails through on the vacuous truth that none of
    #                       its records are outstanding.
    #   _outstanding == 0 — nothing blocked.
    # Do NOT collapse this to a single boolean set inside the loop: a boolean's
    # initial value IS a decision about the zero-iteration case, and every
    # fail-open finding in this loop's history came from that initial value
    # being the permissive one.
    [[ "$_decided" -gt 0 && "$_outstanding" -eq 0 ]] && _complete=true
    [[ "$_complete" == "true" ]] || continue

    _dest="$CONSUMED_DIR/$(basename "$_snap")"
    # A later fold CAN regenerate a snapshot for an already-archived PR number:
    # its idempotency guard in scripts/pr-postmerge-fold.sh only checks the LIVE
    # path, not the archive. Never overwrite the evidence.
    #
    # ⛔ LOOP, don't test once. ⛔ A single `[[ -e ]] && _dest="$_dest.$(date
    # +%s)"` handles exactly ONE collision: once both `<name>` and
    # `<name>.<epoch>` were taken, `mv` OVERWROTE the second. `_n` disambiguates
    # within a second, which a bare epoch cannot. Bounded so a pathological
    # directory can never spin forever.
    _n=0
    while [[ -e "$_dest" && $_n -lt 100 ]]; do
      _n=$((_n+1))
      _dest="$CONSUMED_DIR/$(basename "$_snap").$(date -u +%s).$_n"
    done
    # printf, not echo, for all three messages: they interpolate a FILENAME.
    # Leaving the queue intact is always preferable to destroying an archived
    # record, so an exhausted suffix search refuses the move instead of
    # clobbering. NOTE: if ~/.claude and the archive dir ever straddle a mount,
    # `mv` degrades to copy+unlink and can fail mid-way; this branch fails safe
    # (the file stays queued and resurfaces).
    if [[ -e "$_dest" ]]; then
      printf 'WARN: could not find a free archive name for %s — left queued, will resurface.\n' "$_snap" >&2
    elif mv "$_snap" "$_dest" 2>/dev/null; then
      printf '  (archived fully-decided %s → %s/)\n' "$(basename "$_snap")" "$CONSUMED_DIR"
      ARCH_ARCHIVED=$((ARCH_ARCHIVED+1))
    else
      printf 'WARN: could not archive %s — left queued, will resurface.\n' "$_snap" >&2
    fi
  done
}

# =============================================================================
# SUBCOMMAND: surface
# =============================================================================
cmd_surface() {
  local owner="${1:-}" repo="${2:-}" pr="${3:-}" state="${4:-}" mode="${5:-}"
  if [[ -z "$owner" || -z "$repo" || -z "$pr" || -z "$state" || -z "$mode" ]]; then
    usage; exit 2
  fi
  # ⛔ ATTENDED vs UNATTENDED — PARSED STRICTLY, NEVER GUESSED. ⛔
  # An `--auto` cron fire prints into a session nobody is reading; a manual
  # `/review-pr <merged-pr>` prints to a human who asked for it. ONLY the second
  # kind may write or reset the reprint pointer, because the two mistakes are
  # not symmetric: wrongly writing a marker HIDES a record from every later run,
  # while wrongly omitting one only re-prints something the surface cap already
  # bounds.
  #
  # WHY IT IS AN EXPLICIT ARGUMENT rather than a flag the script infers: the
  # caller (commands/review-pr.md Step 0.5) knows whether `--auto` was passed;
  # this script does not and must not try to guess from the environment. An
  # unrecognised value is a CALLER bug and exits 2 having written nothing — the
  # loudest and cheapest failure available. Defaulting a typo to "attended"
  # would hide records permanently; defaulting it to "unattended" would hide the
  # typo instead. Refusing does neither.
  local attended
  case "$mode" in
    attended)   attended=true ;;
    unattended) attended=false ;;
    *) printf 'consume-deviations.sh: MODE must be `attended` or `unattended`, got %s\n' "$mode" >&2
       usage; exit 2 ;;
  esac

  if claude_dir_is_symlink; then
    printf 'Refusing to surface deviations: %s is a symlink. Exiting cleanly.\n' "$CLAUDE_DIR" >&2
    summary "surface refused=symlinked-state-dir"; return 0
  fi
  if ! is_toolbox_repo "$owner" "$repo"; then
    summary "surface refused=not-toolbox-repo repo=$owner/$repo"; return 0
  fi
  # Only a MERGED PR consumes snapshots — a CLOSED PR means the work did not
  # ship, so there is nothing to learn from.
  if [[ "$state" != "MERGED" ]]; then
    summary "surface refused=pr-not-merged state=$state"; return 0
  fi
  # ⛔ THE ENUMERATION HAPPENS HERE — behind the symlink gate, behind the repo
  # gate, behind the MERGED check. ⛔ It stats every glob match, so a run in ANY
  # project repo would otherwise read metadata for every toolbox snapshot before
  # anything had checked whether it had business looking at them.
  if ! dev_enumerate_snapshots; then
    summary "surface surfaced=0 remaining=0 parse_failures=0 unreadable=0 empty_snapshots=0 archived=0 still_queued=0 pointer_reset=no"
    return 0
  fi

  # Widened symlink guard — every swept file, not just one PR's. The sweep
  # widened what gets opened, so it must widen what gets checked. The test
  # itself lives in `state_symlink_violation` because `archive` needs the
  # identical one; see that function for what the copy cost while there were two.
  local sym=""
  if sym=$(state_symlink_violation); then
    printf 'Skipping deviation surface: a snapshot, the dismissed log, the surfaced log, or the archive dir is a symlink (%s).\n' "$sym" >&2
    summary "surface refused=symlinked-state-file"; return 0
  fi
  # ⛔ ONE DECISION (`have_tools`), TWO MESSAGES. ⛔ The `command -v` below does
  # NOT re-decide the gate — `have_tools` has already refused. It only picks which
  # consequence to name, because the two are not interchangeable: without jq
  # nothing can be parsed, while without shasum every record collapses onto ONE
  # empty key and a single dismissal in that shape archives the whole queue.
  # ⛔ A THIRD TOOL ADDED TO `have_tools` NEEDS ITS MESSAGE ADDED HERE. ⛔ The
  # `else` names shasum, so a third missing tool would be mislabelled — still a
  # refusal that preserves every snapshot, which is the direction that matters,
  # but the wrong instruction to the user.
  if ! have_tools; then
    if ! command -v jq >/dev/null 2>&1; then
      printf '⚠️  jq not installed — can'"'"'t parse deviation snapshots. %s snapshot(s) preserved in %s. Install jq (brew install jq / apt install jq) and re-run /review-pr on a merged toolbox PR.\n' \
        "${#ALL_DEV_SNAPSHOTS[@]}" "$CLAUDE_DIR" >&2
      summary "surface refused=no-jq snapshots=${#ALL_DEV_SNAPSHOTS[@]}"; return 0
    fi
    printf '⚠️  shasum not installed — can'"'"'t derive deviation hashes (every record would collapse onto one empty key). %s snapshot(s) preserved in %s. Install a shasum/sha256sum shim and re-run /review-pr on a merged toolbox PR.\n' \
      "${#ALL_DEV_SNAPSHOTS[@]}" "$CLAUDE_DIR" >&2
    summary "surface refused=no-shasum snapshots=${#ALL_DEV_SNAPSHOTS[@]}"; return 0
  fi

  mkdir -p "$CLAUDE_DIR" "$CONSUMED_DIR"
  touch "$DISMISSED_FILE" "$SURFACED_FILE"

  # ⛔ THE AUTHORIZING FILE'S READABILITY IS PART OF THE RUN'S STATUS. ⛔
  # `dismissed-deviations.log` is the ONLY thing that marks a record decided and
  # the only thing that authorizes archival, so a run that cannot read it can
  # neither recognise a decision nor retire anything. Verified at mode 000: the
  # surface REPRINTED an already-decided record while reporting `unreadable=0`,
  # and every re-dismissal of it appended to a file nothing can read. Failing
  # closed is right; asserting a clean run is not.
  #
  # It is a KEY, not a refusal: the run still surfaces (reprinting is the correct
  # fail-closed behaviour when decisions cannot be read) and the archive pass
  # still declines on its own account, because `hash_logged_in` cannot match in a
  # file it cannot open. This only stops the summary line from claiming otherwise.
  # `touch` above succeeds on a mode-000 file the caller owns, so this test is
  # about permissions, not existence.
  local dismissed_log_unreadable=no
  if [[ ! -r "$DISMISSED_FILE" ]]; then
    dismissed_log_unreadable=yes
    printf 'WARN: %s is not readable — no record can be confirmed decided this run, so already-decided records will reprint and nothing can be archived. Check permissions and ownership.\n' "$DISMISSED_FILE" >&2
  fi

  echo ""
  printf 'PR #%s merged. Surfacing captured deviations (%s snapshot(s), newest first):\n' "$pr" "${#ALL_DEV_SNAPSHOTS[@]}"
  echo ""

  local n=0 remaining=0 parse_failures=0 unreadable=0 surfaced_any=false
  # A snapshot with NO records is its own class — CLASSIFY it, do not INFER it.
  # Once the archive pass refuses to retire a record-less file (which it must),
  # that file becomes PERMANENTLY resident: it holds nothing to decide, so no
  # triage can ever drain it. Left unclassified the run printed "N snapshot(s)
  # still hold records nobody has decided ... they surface again on the next
  # run" — both halves false — and selfimprovement-backlog.sh warned about it
  # forever while telling the user to run the very command that cannot help.
  local empty_snapshots=0 empty_files="" parse_fail_files=""
  local seen_run_hashes="|" surfaced_records=()
  local _snap _first _record _body _phase _hash_full _hash _seen_in_file

  for _snap in "${ALL_DEV_SNAPSHOTS[@]}"; do
    # ⛔ UNREADABLE IS NOT EMPTY — FAIL CLOSED, AND SAY SO. ⛔ Checked FIRST,
    # ahead of the legacy guard, because every downstream read fails OPEN on an
    # unreadable file and the failures compound: `head -1` yields empty so the
    # legacy guard does not classify it; the `while … done < "$_snap"` redirect
    # fails so the loop body never runs and the file looks record-less. Recorded
    # so it is never archived AND counted, so the user is TOLD rather than
    # silently skipped.
    if [[ ! -f "$_snap" || ! -r "$_snap" ]]; then
      unreadable=$((unreadable+1)); set_add parse_fail_files "$_snap"
      printf '  (skipping %s — not readable; preserved, NOT archived — check permissions)\n' "$(basename "$_snap")"
      continue
    fi
    # Per-FILE legacy-format guard. The old single-key code checked ONE file's
    # first line and bailed out of the whole surface; with a sweep, one pre-JSONL
    # file must not blind the run to the other five.
    _first=$(head -1 "$_snap")
    if [[ -n "$_first" ]] && ! printf '%s' "$_first" | jq -e . >/dev/null 2>&1; then
      set_add parse_fail_files "$_snap"
      printf '  (skipping %s — not JSONL, likely a pre-migration snapshot; preserved for manual review)\n' "$(basename "$_snap")"
      continue
    fi

    # Snapshot format is JSONL — one JSON object per line, {ts, phase, body}.
    # Robust to multi-line deviations and to any dash/hyphen content; avoids the
    # `read -d '---'` pitfall, which splits on every `-`.
    _record=''
    # Per-file record tally, used below to classify a snapshot that yielded
    # nothing at all. Counts records that produced a usable body AND hash.
    _seen_in_file=0
    while IFS= read -r _record || [[ -n "$_record" ]]; do
      [[ -z "$_record" ]] && continue
      # A parse failure is NOT the same as "no deviations" — the record may hold
      # something real we cannot read yet, so its FILE is remembered and never
      # archived.
      _body=$(printf '%s' "$_record" | jq -er '.body' 2>/dev/null) \
        || { parse_failures=$((parse_failures+1)); set_add parse_fail_files "$_snap"; continue; }
      _phase=$(printf '%s' "$_record" | jq -er '.phase' 2>/dev/null) \
        || { parse_failures=$((parse_failures+1)); set_add parse_fail_files "$_snap"; continue; }
      # ⛔ AN EMPTY BODY IS A PARSE FAILURE, NOT A NON-RECORD. ⛔ A bare
      # `continue` silently drops a record `jq` parsed successfully, so
      # `{"ts":…,"phase":…,"body":""}` was never shown and never counted
      # anywhere, and the user was told nothing.
      if [[ -z "$_body" ]]; then
        parse_failures=$((parse_failures+1)); set_add parse_fail_files "$_snap"; continue
      fi
      _hash_full=$(body_hash "$_body")
      _hash=${_hash_full:0:8}
      # ⛔ VALIDATE THE KEY BEFORE USING IT AS A KEY. ⛔ On a shasum failure the
      # substitution yields the EMPTY STRING, the anchored pattern degrades to
      # `^\[\] `, and every record in every snapshot collapses onto ONE key —
      # after which a SINGLE dismissal in that shape archives the entire queue.
      # The `command -v shasum` guard above catches the missing-tool case; this
      # catches the rest (a shadowed/broken shasum, an exec failure under
      # resource pressure, a truncated pipe).
      [[ "$_hash_full" =~ $HASH_RE ]] \
        || { parse_failures=$((parse_failures+1)); set_add parse_fail_files "$_snap"; continue; }
      # ⛔ COUNTED HERE, NOT AFTER THE PRINT. ⛔ This tally answers "did this file
      # contain any records at all", which is a question about the FILE, not
      # about what this run chose to display. Every skip below it — already
      # dismissed, already surfaced, per-run duplicate, the cap — is a DISPLAY
      # decision on a record that demonstrably exists.
      _seen_in_file=$((_seen_in_file+1))
      hash_logged_in "$_hash_full" "$DISMISSED_FILE" && continue   # already DECIDED
      hash_logged_in "$_hash_full" "$SURFACED_FILE"  && continue   # already SHOWN
      # Per-run dedupe: several snapshots hold BYTE-IDENTICAL bodies, because
      # handover.md was never cleared between those merges. Without this the same
      # records surface several times in one run and eat the cap. Keyed on the
      # FULL digest for the same reason the log lookups are.
      set_has seen_run_hashes "$_hash_full" && continue
      set_add seen_run_hashes "$_hash_full"
      # Past the cap: count it, do NOT print it, and do NOT mark it surfaced —
      # an unshown record must stay queued for the next run.
      if [[ $n -ge $SURFACE_CAP ]]; then remaining=$((remaining+1)); continue; fi
      n=$((n+1)); surfaced_any=true
      # ⛔ FOLD PHASE TO ONE LINE — printf ALONE DOES NOT DO THIS. ⛔ PHASE is
      # `substr($0,4)` of a `## ` heading in handover.md, which anyone with repo
      # write access can write, and it is printed UNINDENTED, at column 1, where
      # the item headers live. A crafted value produced a COMPLETE counterfeit
      # item — header, indented body, and its own `(hash:)` line — pointing at a
      # record the reader was never shown as item 2, so a later `improve 3` could
      # target a different record than the one the user read.
      #
      # THE PRECISE CLAIM, because the comment that stood here made a wider one:
      # `printf` instead of `echo` fixes escape INTERPRETATION (some shells' `echo`
      # expands `\n` in its argument). It does NOT fix an embedded REAL newline,
      # and the forged item above was reproduced with `printf` in place. This
      # `tr` is what closes that, and it is defence in depth rather than a live
      # fix: the class is NOT reachable through today's writer, verified both
      # ways — `phase` is `substr($0,4)` of a newline-split awk record, so it
      # cannot hold a newline, and `json_escape` escapes the literal backslash
      # first, so a heading containing `\` `n` emits `\\n` and prints literally.
      # It is here because the two guards standing between that writer and this
      # print are in a different file, and BODY has carried the same protection
      # (the 4-space `sed` indent) all along.
      _phase=$(printf '%s' "$_phase" | tr '\n' ' ')
      printf '[%s] %s  — %s\n' "$n" "$_phase" "$(basename "$_snap")"
      printf '%s\n' "$_body" | sed 's/^/    /'
      printf '    (hash: %s)\n' "$_hash"
      echo ""
      surfaced_records+=( "$_hash_full|$_body" )
    done < "$_snap"

    # Zero PARSEABLE records in a file that was readable and not legacy — i.e. 0
    # bytes, or blank lines only. A file whose records were all skipped as parse
    # failures is NOT counted here: it is already named by parse_failures and is
    # genuinely outstanding work.
    if [[ "$_seen_in_file" -eq 0 ]] && ! set_has parse_fail_files "$_snap"; then
      empty_snapshots=$((empty_snapshots+1)); set_add empty_files "$_snap"
    fi
  done

  # ⛔ THE FULL DIGEST MUST REACH THE AGENT, NOT JUST THE 8-CHARACTER DISPLAY
  # FORM. ⛔ One `SURFACED <index> <64-hex digest>` line per record this run
  # DISPLAYED, in listing order, with the index matching the `[N]` the human saw.
  # This mirrors `CANDIDATE <json>` on the lessons half, which exists so the agent
  # resolves the SAME numbering the listing printed instead of re-deriving it.
  #
  # WHY IT IS NEEDED HERE: `ignore N` / `improve N` used to resolve a record from
  # a 32-bit prefix a human retyped, and `cmd_dismiss`'s hash-vs-body check is
  # STRUCTURALLY unable to catch a mis-resolution — the body it is handed is the
  # WRONG record's body, so the pair agrees and the write goes through.
  # Demonstrated end to end: a mis-resolved dismissal retired an untriaged victim
  # and the next surface printed `surfaced=0 still_queued=1`, so the victim was
  # permanently invisible while the queue reported work outstanding forever. What
  # drives this is not grinding (that needs the victim's exact body, which lives
  # in a local handover.md) but ordinary mis-resolution: a compaction, a forged
  # item header, or a retyping slip.
  #
  # The 8-character form stays exactly where it was: it is what a human reads off
  # the screen. This ADDS the machine-readable key rather than replacing the
  # human-readable one.
  local _si=0 _sr
  for _sr in ${surfaced_records[@]+"${surfaced_records[@]}"}; do
    _si=$((_si+1))
    printf 'SURFACED %s %s\n' "$_si" "${_sr%%|*}"
  done
  [[ $_si -gt 0 ]] && echo ""

  # Record what was SHOWN, so the NEXT ATTENDED run continues where this one
  # stopped instead of re-printing the same first 15 records forever.
  #
  # ⛔ ATTENDED RUNS ONLY. ⛔ A cron fire prints into a session with no reader, so
  # recording its output as "shown" is not a resume pointer — it is a delete key
  # with a delay. Unguarded, an unattended fire marked 15 records shown, no human
  # ever saw them, and they never appeared again while all six snapshots stayed
  # pending and the triage text promised they would resurface. READING the
  # pointer on a cron fire is still fine (skipping what a human already saw costs
  # nothing); WRITING it is what hides records.
  local _rec _h _b now_iso
  if [[ "$attended" == "true" && ${#surfaced_records[@]} -gt 0 ]]; then
    now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    for _rec in "${surfaced_records[@]}"; do
      _h=${_rec%%|*}; _b=${_rec#*|}
      printf '[%s] %s | %s\n' "$_h" "$now_iso" "$(sanitize_excerpt "$_b")" >> "$SURFACED_FILE"
    done
  fi

  dev_archive_pass

  # How many swept snapshots are STILL on disk after the archive pass. Any
  # survivor either holds at least one record that has NOT been decided — which
  # is precisely why the pass declined to retire it — or could not be read at
  # all. Either way it is outstanding work.
  #
  # ⛔ EXCLUDE THE RECORD-LESS CLASS. ⛔ `still_queued` drives the claim "these
  # hold records nobody has decided, so they surface again next run". A 0-byte or
  # blank-lines-only snapshot survives the archive pass by design, but it holds
  # no records and can never surface anything, so counting it here made the
  # message assert two things that were both false.
  local still_queued=0 _q
  for _q in "${ALL_DEV_SNAPSHOTS[@]}"; do
    [[ -e "$_q" ]] || continue
    set_has empty_files "$_q" && continue
    still_queued=$((still_queued+1))
  done

  local empty_basenames=""
  if [[ $empty_snapshots -gt 0 ]]; then
    for _q in "${ALL_DEV_SNAPSHOTS[@]}"; do
      set_has empty_files "$_q" && empty_basenames="$empty_basenames $(basename "$_q")"
    done
    empty_basenames=${empty_basenames# }
  fi

  if [[ "$surfaced_any" == "true" ]]; then
    echo "Triage options (reply with one per line or comma-separated):"
    echo "  improve N    — spawn a task that proposes a toolbox PR addressing deviation N"
    echo "  ignore N     — dismiss deviation N (hash appended to dismissed-deviations.log)"
    echo "  all-improve  — spawn tasks for all surfaced deviations"
    echo "  all-ignore   — dismiss all surfaced deviations"
    echo ""
    # The cap is not a silent throttle: uncapped records are counted here AND by
    # scripts/selfimprovement-backlog.sh on every verify.sh run.
    [[ $remaining -gt 0 ]] && printf '%s further deviation(s) not shown this run (cap %s) — they surface on the next merged-PR consumption, or on a manual /review-pr <merged-pr>.\n' "$remaining" "$SURFACE_CAP"
    [[ $parse_failures -gt 0 ]] && printf '(note: %s record(s) failed to parse — their snapshot(s) are preserved, NOT archived)\n' "$parse_failures"
    # `unreadable` is reported alongside `parse_failures`, never folded into it:
    # a parse failure means "we read a record and could not understand it", an
    # unreadable file means "we could not read it at all" and its record count is
    # UNKNOWN. Adding it to a record counter would invent a number.
    [[ $unreadable -gt 0 ]] && printf '(note: %s snapshot(s) could not be read — preserved, NOT archived; check permissions and ownership in %s)\n' "$unreadable" "$CLAUDE_DIR"
    # The record-less class needs saying MORE loudly than the others, because it
    # is the only class no triage can ever clear.
    [[ $empty_snapshots -gt 0 ]] && printf '(note: %s snapshot(s) hold NO records at all — nothing to triage, and no run can drain them: %s. They are preserved, not archived; remove them by hand once you are satisfied they are empty.)\n' "$empty_snapshots" "$empty_basenames"
  elif [[ $parse_failures -gt 0 || $unreadable -gt 0 || $empty_snapshots -gt 0 ]]; then
    printf '(no parseable deviations surfaced — %s record(s) failed to parse, %s snapshot(s) were unreadable and %s held no records; all preserved for manual review, none archived)\n' \
      "$parse_failures" "$unreadable" "$empty_snapshots"
    [[ $empty_snapshots -gt 0 ]] && printf '(the record-less snapshot(s): %s — no run can drain these; remove them by hand once you are satisfied they are empty.)\n' "$empty_basenames"
  else
    # Nothing is deleted here: the archive pass already moved whatever was fully
    # DECIDED, and anything still on disk is intentionally queued. Note the
    # deliberate asymmetry — a snapshot whose records were all merely SURFACED
    # (never decided) prints nothing new yet stays on disk. "Nothing new to
    # triage" therefore means "nothing new to PRINT", not "the queue is empty".
    echo "(all captured deviations were already surfaced or dismissed — nothing new to triage)"
  fi

  # ⛔ SELF-HEALING RESET OF THE REPRINT POINTER — BELOW THE CHAIN, NOT INSIDE
  # IT. ⛔ The condition that matters is "this attended run printed NOTHING while
  # snapshots still hold undecided records", and that state is reachable through
  # TWO of the three branches above, not one. It lived in the final `else` for a
  # round and was unreachable in the case it was added for: one snapshot that
  # stays unreadable (a `chmod 000` accident) plus every readable record already
  # surfaced means nothing prints, the middle branch is taken, and the reset
  # never ran — so the queue stayed buried permanently.
  #
  # Truncating is safe BECAUSE this file authorizes nothing: it gates printing,
  # never archival and never dismissal. The cost of clearing it is one repeated
  # printout; the cost of NOT clearing it is a queue invisible to its own
  # consumer. ATTENDED-ONLY for the mirror of the reason the write is: a cron
  # fire must not clear a pointer a human is mid-way through using.
  local pointer_reset=no
  if [[ "$attended" == "true" && $still_queued -gt 0 && "$surfaced_any" != "true" ]]; then
    : > "$SURFACED_FILE"
    pointer_reset=yes
    printf '(%s snapshot(s) still hold records nobody has decided — the reprint pointer has been reset, so they surface again on the next run instead of staying hidden. Nothing was archived or dismissed.)\n' "$still_queued"
  fi

  summary "surface surfaced=$n remaining=$remaining parse_failures=$parse_failures unreadable=$unreadable empty_snapshots=$empty_snapshots archived=$ARCH_ARCHIVED still_queued=$still_queued pointer_reset=$pointer_reset dismissed_log_unreadable=$dismissed_log_unreadable"
  return 0
}

# =============================================================================
# SUBCOMMAND: archive — the SECOND call site of the one archive rule.
#
# Step 7's cleanup, after a triage reply has appended dismissals. It used to be
# an English restatement of the Step 0.5 rule ("if EVERY record in it has been
# DECIDED"), which is VACUOUSLY TRUE of a file with no records — so after any
# unrelated decision, a 0-byte snapshot satisfied the instruction and the `mv`
# retired the never-completed warning with nobody having decided anything. There
# is now nothing to restate: this calls the same function.
# =============================================================================
cmd_archive() {
  local owner="${1:-}" repo="${2:-}"
  if [[ -z "$owner" || -z "$repo" ]]; then usage; exit 2; fi
  if claude_dir_is_symlink; then
    printf 'Refusing to archive deviations: %s is a symlink. Exiting cleanly.\n' "$CLAUDE_DIR" >&2
    summary "archive refused=symlinked-state-dir"; return 0
  fi
  if ! is_toolbox_repo "$owner" "$repo"; then
    summary "archive refused=not-toolbox-repo repo=$owner/$repo"; return 0
  fi
  if ! dev_enumerate_snapshots; then
    summary "archive archived=0 still_queued=0"; return 0
  fi
  # THE SAME PRECONDITION `surface` APPLIES, IN THE SAME POSITION — one
  # function, two call sites. This path is the one that actually performs the
  # `mv`, so it is the one where a symlinked archive dir or dismissed log does
  # the damage; it went unguarded while `surface` refused the identical state.
  local sym=""
  if sym=$(state_symlink_violation); then
    printf 'Refusing to archive deviations: a snapshot, the dismissed log, the surfaced log, or the archive dir is a symlink (%s).\n' "$sym" >&2
    summary "archive refused=symlinked-state-file"; return 0
  fi
  if ! have_tools; then
    printf '⚠️  jq or shasum not installed — refusing to archive (a snapshot whose records cannot be read must never be retired). %s snapshot(s) preserved.\n' "${#ALL_DEV_SNAPSHOTS[@]}" >&2
    summary "archive refused=missing-tools snapshots=${#ALL_DEV_SNAPSHOTS[@]}"; return 0
  fi
  mkdir -p "$CONSUMED_DIR"
  touch "$DISMISSED_FILE"
  # THE SAME KEY THE SURFACE PATH REPORTS, FOR THE SAME REASON — and on this path
  # the consequence is structural rather than cosmetic: that log is the only thing
  # that authorizes a retirement, so a run which cannot read it can NEVER drain
  # anything, and without this key it looks identical to a run with nothing to
  # drain. Verified at mode 000: `archived=0` with no warning of any kind.
  local dismissed_log_unreadable=no
  if [[ ! -r "$DISMISSED_FILE" ]]; then
    dismissed_log_unreadable=yes
    printf 'WARN: %s is not readable — no snapshot can be confirmed fully decided, so this run can archive nothing. Check permissions and ownership.\n' "$DISMISSED_FILE" >&2
  fi
  dev_archive_pass
  local still_queued=0 _q
  for _q in "${ALL_DEV_SNAPSHOTS[@]}"; do
    [[ -e "$_q" ]] && still_queued=$((still_queued+1))
  done
  summary "archive archived=$ARCH_ARCHIVED still_queued=$still_queued dismissed_log_unreadable=$dismissed_log_unreadable"
  return 0
}

# =============================================================================
# SUBCOMMAND: dismiss — THE CANONICAL DISMISSAL WRITE
#
# ⛔ THE ONLY WRITER OF EITHER DISMISSED LOG. ⛔ `~/.claude/dismissed-deviations.log`
# and `~/.claude/dismissed-lessons.log` are appended to HERE and nowhere else.
# There is no third destination.
#
# WHY THE COLLAPSE. This used to be four separate English specifications of the
# same append, three of which spelled out the sanitizing pipeline and one of
# which — `improve N` — said only "append the entry's hash". A handler that
# literally followed that either wrote a line the anchored reader could not match
# (so `improve` never actually dismissed anything and the record resurfaced
# forever) or invented its own format, re-opening the marker-forgery hole the
# other three had just closed. Three review rounds hardened three of the four and
# missed the fourth — and the collapse itself then missed a FIFTH, in `lessons-pr`,
# because that one was prose and the test's needle only saw shell appends. One
# writer cannot drift from itself, and a writer that is a SCRIPT can be executed
# by a test rather than described to one.
#
# WHY THIS IS THE HIGHEST-PRIVILEGE OPERATION IN THE LOOP: the deviation log's
# contents are the only thing that AUTHORIZES the archive pass to retire a
# snapshot, and the lessons log's contents permanently suppress a candidate
# finding.
#
# ⛔ NO REPO GATE HERE, AND THAT IS DELIBERATE — DO NOT ADD ONE. ⛔ Every other
# pass takes OWNER and REPO and refuses outside baselito/ai-engineering, because
# each of them enumerates, retires or deletes files it did not name. This one
# takes neither: it writes exactly the one record its caller hands it, keyed to a
# digest it re-derives from the body, so there is no set to sweep and nothing to
# retire. The compensating control is that pairing — a caller that cannot supply
# the matching body cannot write anything at all.
#
# It is also what makes the `--repo` fail-safe non-lossy. When the repo cannot be
# resolved, `archive` refuses (it is gated) while the DISMISSALS still record, so
# the human's decisions survive and the next run from the toolbox checkout drains
# the queue. A repo gate here would discard the decisions instead, which is the
# one thing in this loop that cannot be reconstructed.
# =============================================================================
cmd_dismiss() {
  local kind="${1:-}" hash_full="${2:-}" log body derived hash_rc
  case "$kind" in
    deviation) log="$DISMISSED_FILE" ;;
    lesson)    log="$DISMISSED_LESSONS_LOG" ;;
    *) printf 'consume-deviations.sh: KIND must be `deviation` or `lesson`, got %s\n' "${kind:-<empty>}" >&2
       usage; exit 2 ;;
  esac
  # A malformed key is a CALLER bug and must be loud: writing it would produce a
  # log line the anchored reader can never match, so the dismissal would silently
  # accomplish nothing and the record would resurface forever.
  if [[ ! "$hash_full" =~ $HASH_RE ]]; then
    printf 'consume-deviations.sh: HASH_FULL must be a 64-character sha256 digest, got %s\n' "${hash_full:-<empty>}" >&2
    exit 2
  fi
  # The body arrives on STDIN, never in argv: it is untrusted, frequently
  # multi-line, and argv is visible to any process that can run `ps`.
  body=$(cat)
  if [[ -z "$body" ]]; then
    printf 'consume-deviations.sh: refusing to dismiss %s with an EMPTY body on stdin — the body is the evidence for the hash, and a caller that omitted it probably resolved the record wrongly too. Nothing was written; the record stays undecided and resurfaces.\n' "${hash_full:0:8}" >&2
    exit 2
  fi
  # ⛔ THE HASH IS THE CALLER'S CLAIM; THE BODY IS THE EVIDENCE. REFUSE WHEN THEY
  # DISAGREE. ⛔ This guard did not exist while the write was prose, and it is the
  # one the prose could not have: Step 7 resolves a record from an 8-character
  # DISPLAY hash the user retyped, and is explicitly required to refuse an
  # ambiguous prefix. Verifying here means a mis-resolution cannot become a
  # dismissal — because a dismissal is what retires a snapshot, and retiring the
  # wrong one destroys the queue's only record that the work was never triaged.
  # Failing closed costs exactly one dismissal: the record is not marked decided,
  # so it surfaces again.
  # ⛔ THE TOOL GATE ITS SIBLINGS ALL HAVE. ⛔ This was the ONLY subcommand with
  # no `command -v` check, and the consequence was a MISLEADING DIAGNOSIS on the
  # ordinary path: with no shasum, `body_hash` yields an empty string, the
  # comparison below fails, and a perfectly valid dismissal exits 2 saying "the
  # supplied hash does not match the sha256 of the body … resolve the record
  # again" — blaming the caller for a missing tool, and sending them to
  # re-resolve a record that was resolved correctly. Every sibling returns 0 with
  # a `refused=` token instead.
  #
  # Gated on shasum ALONE rather than through `have_tools`, which also requires
  # jq: this subcommand never calls jq, and refusing a dismissal for the absence
  # of a tool it does not use would be a guard that fails in the wrong direction
  # for the wrong reason. Nothing is written either way — the record stays
  # undecided and resurfaces — so this changes the DIAGNOSIS and the exit code,
  # not the safety.
  if ! command -v shasum >/dev/null 2>&1; then
    printf 'WARN: dismissal NOT recorded — shasum is not installed, so the digest that keys this record cannot be derived. Nothing was written; the record stays undecided and will surface again.\n' >&2
    summary "dismiss refused=no-shasum kind=$kind"
    return 0
  fi
  derived=$(body_hash "$body")
  hash_rc=$?  # MUST be the very next statement — nothing may run between them.
  # ⛔ PRESENCE IS NOT USABILITY, AND THE COMMENT ABOVE USED TO CLAIM OTHERWISE.
  # ⛔ `command -v` answers one question — is there a shasum on PATH — and the
  # first version of this gate was described as handling a tool that was
  # "missing or broken". It handled absence only. A shasum that EXISTS and then
  # fails at runtime (a broken install, a stub on PATH, a read error) leaves
  # `body_hash` returning an empty or partial string, which flows straight into
  # the comparison below and produces the exact caller-blaming exit 2 the gate
  # was added to remove — measured, not reasoned: a `shasum` stub that exits 7
  # returned `rc=2` and "does not match the sha256 of the body".
  #
  # So TWO things are checked, because either alone leaves a hole:
  #
  #   the STATUS — `hash_rc`, captured immediately after the assignment and
  #     before anything else can overwrite `$?`. `set -o pipefail` is on at the
  #     top of this file, so a failing `shasum` propagates out of `body_hash`'s
  #     pipeline rather than being masked by the `awk` that follows it (verified
  #     by executing it: a stub exiting 7 gives `rc=7`, and the same run WITHOUT
  #     pipefail gives `rc=0` — so this check depends on that `set` line and
  #     would go quiet if it were ever removed).
  #   the SHAPE — `$HASH_RE`, the same 64-hex rule the caller's own hash is
  #     already held to.
  #
  # Status alone misses a shasum that exits 0 and prints something that is not a
  # digest. Shape alone misses a shasum that fails and still prints something
  # 64-hex-shaped. Neither output should ever reach the comparison below, so
  # both are refused as `refused=unusable-shasum`.
  #
  # ⛔ WHAT THIS DOES NOT COVER, stated because overclaiming here is what this
  # very fix is repairing: a shasum that EXITS 0 and returns a WELL-FORMED
  # 64-hex digest that is simply the wrong value — a hijacked binary, or one
  # computing a different algorithm that happens to be 256 bits — is
  # indistinguishable from a genuine caller mis-resolution, and still exits 2
  # blaming the caller. Nothing local can tell those apart, and the direction is
  # the safe one: refusing costs one dismissal, which resurfaces. Note the write
  # is gated on `derived == hash_full` regardless, so a failed tool cannot
  # persist a dismissal unless it reproduced the caller's independently-resolved
  # digest exactly — in which case the record really was resolved correctly.
  # What this check buys is the DIAGNOSIS: a broken tool is now reported as a
  # broken tool instead of reaching a comparison it has no business reaching.
  if [[ "$hash_rc" -ne 0 || ! "$derived" =~ $HASH_RE ]]; then
    printf 'WARN: dismissal NOT recorded — shasum failed (exit %s) or did not return a sha256 digest (got %s), so the key for this record cannot be derived. This is a TOOL failure, not a bad hash: nothing was written, the record stays undecided and will surface again.\n' "$hash_rc" "${derived:-<empty>}" >&2
    summary "dismiss refused=unusable-shasum kind=$kind"
    return 0
  fi
  if [[ "$derived" != "$hash_full" ]]; then
    printf 'consume-deviations.sh: refusing to dismiss — the supplied hash (%s…) does not match the sha256 of the body on stdin (%s…). Nothing was written; resolve the record again.\n' \
      "${hash_full:0:8}" "${derived:0:8}" >&2
    exit 2
  fi
  # ⛔ SYMLINK GUARD ON THE WRITE SIDE TOO. ⛔ This claimed to be the ONE
  # unguarded path, and the claim was false when it was written: `cmd_archive`
  # was unguarded too, and it is the path that performs the `mv` (closed now —
  # see `state_symlink_violation`). Every path in this loop carries an `-L` test
  # today, and this one matters because the asymmetry was worse than a plain
  # missing guard: since the READER refuses to read a symlinked dismissed log,
  # an append through a symlink would have gone somewhere arbitrary and
  # silently, with no compensating failure anywhere, and the queue would simply
  # never have archived. Failing closed costs exactly one dismissal.
  if [[ -L "$CLAUDE_DIR" || -L "$log" ]]; then
    printf 'WARN: dismissal NOT recorded — %s or the dismissed log is a symlink. The record stays undecided and will surface again.\n' "$CLAUDE_DIR" >&2
    summary "dismiss refused=symlink kind=$kind"
    return 0
  fi
  mkdir -p "$CLAUDE_DIR"
  # ⛔ THE APPEND'S STATUS IS THE THING BEING REPORTED. ⛔ This was an unchecked
  # `>>` followed by an unconditional `recorded=`, and the consequence was
  # measured at mode 444 and mode 555: `Permission denied` on stderr, then
  # `dismiss recorded=a05d1da2 …`, rc=0, and a log holding 0 bytes. On
  # `all-ignore` over 15 records the agent reports 15 dismissals, the user
  # believes the batch is decided, and the next run reprints all 15 with no
  # explanation — the stranded-queue failure, reached with nobody attacking
  # anything, on the operation this function's own header calls the
  # highest-privilege one in the loop. `dev_archive_pass` already branches on
  # `mv`'s status; this was the one unchecked destructive write left.
  #
  # THE SUBSHELL IS LOAD-BEARING: `2>/dev/null` on a simple command suppresses
  # the COMMAND's stderr, not the SHELL's own "Permission denied" from a
  # redirection it could not open — that message is printed by the shell in the
  # current process, so without the subshell it leaks past the redirect and the
  # caller sees a raw error next to a clean summary line.
  #
  # Failing closed costs exactly one dismissal: nothing is marked decided, so the
  # record surfaces again. That is why this is a refusal (exit 0 with a token)
  # and not a usage error — it mirrors the symlink branch immediately above.
  if ( printf '[%s] %s | %s\n' "$hash_full" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(sanitize_excerpt "$body")" >> "$log" ) 2>/dev/null; then
    # `digest=` carries the FULL 64 characters and is appended LAST, after the
    # keys a caller already binds to: `recorded=` stays the 8-character DISPLAY
    # form so existing assertions keep matching `recorded=<8> kind=<kind>` as one
    # string, and the auditable value is added rather than substituted. Without
    # it the only record of WHICH record was retired is a 32-bit prefix.
    summary "dismiss recorded=${hash_full:0:8} kind=$kind log=$(basename "$log") digest=$hash_full"
    return 0
  fi
  printf 'WARN: dismissal NOT recorded — could not append to %s. The record stays undecided and will surface again. Check permissions and ownership.\n' "$log" >&2
  summary "dismiss refused=write-failed kind=$kind log=$(basename "$log")"
  return 0
}

# =============================================================================
# SUBCOMMAND: lessons — the deterministic candidate filter.
#
# What is HERE: the sweep, the JSONL parse, the full-digest key, the anchored
# dismissed lookup, the per-run dedupe, and the delete-when-genuinely-drained
# rule. What is NOT here, and must not be: the AI+Codex consensus vote and the
# prompt-injection scan of untrusted finding bodies. Those are commands/review-pr.md
# Step 0.5's and Step 7b's, because both are judgements about adversarial text.
#
# The two halves of this machinery have already diverged twice — first the
# archive semantics, then the excerpt sanitization — each time because a fix
# landed on one side only. They share one file and one set of helpers now.
# =============================================================================
cmd_lessons() {
  local owner="${1:-}" repo="${2:-}" pr="${3:-}" state="${4:-}" repo_root="${5:-$PWD}"
  if [[ -z "$owner" || -z "$repo" || -z "$pr" || -z "$state" ]]; then usage; exit 2; fi

  if claude_dir_is_symlink; then
    printf 'Skipping lessons consolidation: %s is a symlink.\n' "$CLAUDE_DIR" >&2
    summary "lessons refused=symlinked-state-dir"; return 0
  fi
  if ! is_toolbox_repo "$owner" "$repo"; then
    summary "lessons refused=not-toolbox-repo repo=$owner/$repo"; return 0
  fi
  if [[ "$state" != "MERGED" ]]; then
    summary "lessons refused=pr-not-merged state=$state"; return 0
  fi

  local lessons_yml="${repo_root}/knowledge/toolbox-lessons.yml"
  # Same `nullglob`, same measured caveat, and the same never-restored note as
  # `dev_enumerate_snapshots` — read it there. The load-bearing filter here is the
  # `-f` test plus `LESSONNAME_RE` a few lines down, both of which reject the
  # literal pattern on their own.
  shopt -s nullglob
  local all_pending=() _snap
  for _snap in "$CLAUDE_DIR"/pending-lessons-*.jsonl; do
    # `pending-lessons-deferred.jsonl` matches this glob but is NOT a per-PR
    # snapshot — it is the cross-PR deferred queue, added to the read set on its
    # own path below. Without this skip every deferred record was counted twice
    # and the file was deleted by both paths.
    #
    # ⛔ NOW REDUNDANT WITH `LESSONNAME_RE`, AND THEREFORE UNPINNABLE — SAY SO
    # RATHER THAN LET SOMEBODY DISCOVER IT. ⛔ `deferred` is not digits, so the
    # name rule below already excludes this file: deleting THIS line changes no
    # observable behaviour and no test can go red for it (measured — the suite
    # stayed at its full pass count with the line removed). It stays because the
    # two read paths must be disjoint BY CONSTRUCTION rather than by a property
    # of the name rule: the deferred queue is appended to the read set
    # explicitly, so a later widening of `LESSONNAME_RE` would otherwise make
    # this file read twice and listed for deletion twice. That is the only thing
    # it buys, and it buys it for free.
    [[ "$_snap" == "$DEFERRED_LESSONS" ]] && continue
    [[ -f "$_snap" && ! -L "$_snap" ]] || continue
    # ⛔ THE NAME MUST BE THE NAME THE WRITER WRITES. ⛔ Same rule the deviation
    # half applies with DEVNAME_RE, and the operation downstream here is `rm -f`.
    # See the LESSONNAME_RE declaration for the file this destroyed.
    [[ "$(basename "$_snap")" =~ $LESSONNAME_RE ]] || continue
    all_pending+=( "$_snap" )
  done
  if [[ ${#all_pending[@]} -eq 0 ]] && [[ ! -s "$DEFERRED_LESSONS" ]]; then
    summary "lessons candidates=0 parse_failures=0 unreadable=0 snapshots=0 deleted=no"; return 0
  fi

  # ⛔ STATE FILES ONLY — `$lessons_yml` IS NOT ONE, AND TESTING IT WAS AN OFF
  # SWITCH. ⛔ This script never OPENS knowledge/toolbox-lessons.yml; its only
  # other use is the display string near the end of the listing. So an `-L` test
  # on it protected nothing and supplied only a way to stop the run — and that
  # path is GIT-TRACKED, while git stores symlinks natively (`120000 blob`). Any
  # merged PR, including one from an external fork, could therefore switch this
  # half of the loop off on every machine, forever, silently: exit 0,
  # `refused=symlinked-state-file`, snapshots preserved and accumulating,
  # indistinguishable from a genuine tamper refusal. Verified with an explicit
  # REPO_ROOT and with the `$PWD` default.
  #
  # The other three operands ARE state and stay. Removing the whole predicate
  # would re-open the sharper hole: a symlinked dismissed-lessons log is what
  # suppresses candidates, and a suppressed candidate is what authorizes the only
  # `rm` in this loop.
  local f pending_symlink=""
  for f in ${all_pending[@]+"${all_pending[@]}"}; do [[ -L "$f" ]] && pending_symlink="$f"; done
  if [[ -n "$pending_symlink" || -L "$DEFERRED_LESSONS" || -L "$DISMISSED_LESSONS_LOG" ]]; then
    printf 'Skipping lessons consolidation: a pending-lessons snapshot, the deferred queue, or the dismissed-lessons log is a symlink.\n' >&2
    summary "lessons refused=symlinked-state-file"; return 0
  fi
  # ONE DECISION, TWO MESSAGES — see the identical construction in `cmd_surface`
  # and the note on `have_tools` for why the inline `command -v` is a message
  # selector rather than the gate, and what a third tool has to add here.
  if ! have_tools; then
    if ! command -v jq >/dev/null 2>&1; then
      printf '⚠️  jq not installed — can'"'"'t consolidate lessons. %s snapshot(s) preserved in %s.\n' "${#all_pending[@]}" "$CLAUDE_DIR" >&2
      summary "lessons refused=no-jq snapshots=${#all_pending[@]}"; return 0
    fi
    # Without shasum every finding hash is the empty string, the anchored
    # dismissed-log lookup degrades to `^\[\] `, and one dismissal in that shape
    # would suppress every candidate — which is the state that authorizes the
    # only `rm` in this loop.
    printf '⚠️  shasum not installed — can'"'"'t derive finding hashes (every finding would collapse onto one empty key). %s snapshot(s) preserved in %s.\n' "${#all_pending[@]}" "$CLAUDE_DIR" >&2
    summary "lessons refused=no-shasum snapshots=${#all_pending[@]}"; return 0
  fi

  mkdir -p "$CLAUDE_DIR"
  touch "$DISMISSED_LESSONS_LOG"

  echo ""
  echo "--- Learned-lessons consolidation ---"
  printf 'PR #%s merged. Reading capture records for lessons triage…\n' "$pr"
  echo ""

  # ⛔ PER-FILE ACCOUNTING — NOT ONE RUN-WIDE COUNTER GATING A PER-FILE DELETE. ⛔
  # Every tally the delete keys on is kept about ONE file; the run-wide numbers
  # exist only for the summary line. The previous shape read the CONCATENATION of
  # every snapshot through a single `cat` in a process substitution and gated a
  # delete applied to ALL of them on two run-wide counters, which failed in both
  # directions at once — neither needing an attacker:
  #   - one malformed record in the deferred queue pinned a fully-drained
  #     pending-lessons-888.jsonl forever, and scripts/selfimprovement-backlog.sh
  #     then named the INNOCENT file (the deferred queue is excluded from its
  #     count), so the user was told to drain a file that was already drained, by
  #     a command that cannot drain it;
  #   - a file that could not be OPENED yielded neither a candidate nor a parse
  #     failure — `cat`'s error was suppressed and its exit status discarded,
  #     because nothing waits on a process substitution — so it satisfied BOTH
  #     halves of the delete condition and `rm -f` destroyed it unread, the
  #     cross-PR deferred queue included.
  # Reading each file with its OWN loop is what LOCALISES a read failure to one
  # file: behind a single `cat` over the concatenation, one bad file's effects
  # were indistinguishable from every other file's.
  #
  # ⛔ WHAT THE LOOP DOES NOT DO — AND THIS SENTENCE USED TO CLAIM OTHERWISE. ⛔
  # It said the per-file loop "makes a read error observable at all". It makes it
  # observABLE; the loop itself observes nothing. `while IFS= read -r` CANNOT
  # distinguish clean EOF from a mid-read I/O error: bash returns 1 for both.
  # Measured on the platform this runs on — GNU bash 3.2.57, the macOS system
  # bash — where even a `-t` timeout, the one case the manual documents as
  # returning >128, returns 1. So capturing `read`'s status buys nothing here,
  # and a file that opens fine and fails partway through yields an all-dismissed
  # PREFIX that satisfies every clause of the delete condition below.
  # That is the C-1 CRITICAL surviving in a narrower form: the `[[ ! -f || ! -r ]]`
  # pre-test catches "cannot open", and nothing caught "stopped reading partway".
  # What catches it is the confirming re-read at the delete decision — see the
  # block beside `delete_list` below, which is the only place it is needed
  # because it is the only unrecoverable operation here.
  # The deviation half (`cmd_surface`) has been per-file since the sweep landed,
  # for exactly the localisation reason above. It does NOT carry the confirming
  # re-read, deliberately: what it authorizes is an `mv` into
  # consumed-deviations/, so a file archived on a truncated prefix is still on
  # disk and still readable. Recoverable, and so not worth the extra pass.
  local candidate_count=0 parse_failures=0 unreadable=0 records_read=0
  local candidates=() seen="|" delete_list=() deleted=no
  local _file _record _finding _verdict _origin _hash_full
  local _f_records _f_failures _f_live
  # The files this run reads: every per-PR snapshot, plus the cross-PR deferred
  # queue when it exists. The deferred queue is in the SAME list deliberately —
  # it was `cat`'d and `rm`'d on exactly the same terms as the snapshots while
  # being covered by none of the same accounting, and it is the highest-value
  # file in the queue because its records are the ones a human explicitly held.
  local read_set=()
  read_set=( ${all_pending[@]+"${all_pending[@]}"} )
  [[ -e "$DEFERRED_LESSONS" ]] && read_set+=( "$DEFERRED_LESSONS" )

  for _file in ${read_set[@]+"${read_set[@]}"}; do
    # ⛔ UNREADABLE IS NOT DRAINED — FAIL CLOSED, AND SAY SO. ⛔ The same rule
    # `cmd_surface` has carried since the sweep landed. A file that cannot be
    # opened runs the loop body ZERO times, which is indistinguishable from
    # "every record in it is already dismissed" — and the operation downstream of
    # that conclusion is the only unrecoverable one in this file. Counted so the
    # summary cannot assert a clean run, and named so the user can fix it.
    if [[ ! -f "$_file" || ! -r "$_file" ]]; then
      unreadable=$((unreadable+1))
      printf '  (skipping %s — not readable; preserved, NOT deleted — check permissions and ownership in %s)\n' \
        "$(basename "$_file")" "$CLAUDE_DIR"
      continue
    fi
    _f_records=0; _f_failures=0; _f_live=0
    _record=''
    # `|| [[ -n "$_record" ]]`: same EOF-residue guard as the deviation loops. A
    # snapshot whose last line has no trailing newline leaves that record in the
    # variable with `read` returning non-zero, so the loop body never ran for it
    # and the finding was dropped without even being counted as a parse failure.
    while IFS= read -r _record || [[ -n "$_record" ]]; do
      [[ -z "$_record" ]] && continue
      # `lesson_record_hash` is the READER's half of the one definition the
      # `defer` writer also uses; see that function for why they must not be two
      # copies. A record it rejects is counted as a parse failure, which is the
      # fail-closed path here: a file with a counted failure is never deleted.
      _hash_full=$(lesson_record_hash "$_record") || { _f_failures=$((_f_failures+1)); continue; }
      _f_records=$((_f_records+1))
      hash_logged_in "$_hash_full" "$DISMISSED_LESSONS_LOG" && continue  # already dismissed or learned
      # ⛔ COUNTED AS LIVE BEFORE THE DEDUPE, NOT AFTER. ⛔ This tally answers
      # "does THIS file still hold an undismissed record", which is a question
      # about the file, not about what this run chose to display. A record the
      # per-run dedupe drops because another file was read first is still an
      # undismissed record in this one, and "another file came first" is not a
      # decision anybody made.
      _f_live=$((_f_live+1))
      # Per-run dedupe: the fold appends with `>>` across reruns and automated-review/Codex
      # contribute overlapping findings, so the same body can appear several times.
      set_has seen "$_hash_full" && continue
      set_add seen "$_hash_full"
      candidate_count=$((candidate_count+1))
      candidates+=( "$(printf '%s' "$_record" | jq -c --arg h "$_hash_full" '. + {hash:$h}' 2>/dev/null)" )
    done < "$_file"
    parse_failures=$((parse_failures+_f_failures))
    records_read=$((records_read+_f_records))
    # ⛔ THREE CONDITIONS, ALL THREE ABOUT THIS FILE ALONE. ⛔
    #   _f_records > 0   — at least one record was READ out of it. A file that
    #                      yielded nothing (0 bytes, blank lines only) can never
    #                      be "drained": it has produced no evidence of anything,
    #                      and inferring completion from an absence is what put
    #                      `_decided > 0` in `dev_archive_pass`.
    #   _f_failures == 0 — nothing in it was unparseable. A line nobody can parse
    #                      may hold a finding, so deleting it is the silent loss
    #                      this loop exists to end.
    #   _f_live == 0     — every record it holds is in dismissed-lessons.log.
    if [[ "$_f_records" -gt 0 && "$_f_failures" -eq 0 && "$_f_live" -eq 0 ]]; then
      # ⛔ A LOOP THAT ENDED CANNOT SAY WHY IT ENDED. CONFIRM THE READ BEFORE
      # AUTHORIZING THE DELETE. ⛔ Every clause above is satisfied by an
      # all-dismissed PREFIX of a file whose read failed partway through: the
      # records it did see were parseable and decided, and the loop ended the
      # same way a clean EOF ends it. The operation downstream is `rm`, which has
      # no undo — so the run must not infer "I saw the whole file" from "my loop
      # stopped".
      #
      # `cat`'s exit status DOES reflect a read error, which is the property
      # being used here — unlike the ancestor this file's comments criticise,
      # where `cat` sat inside a process substitution and nothing waited on it,
      # so its status was discarded. Checked, its status is the confirmation.
      #
      # Honest about its limits: this is a SECOND read, so it cannot see an error
      # that has already cleared, and a device failing intermittently could pass
      # it. It closes the persistent case, which is the one that would otherwise
      # destroy an unread remainder, and it costs one pass over a few-KB file on
      # the destructive path only. If `cat` is unavailable the check fails and
      # nothing is deleted — the same direction every other guard here fails in.
      if ( cat -- "$_file" >/dev/null ) 2>/dev/null; then
        delete_list+=( "$_file" )
      else
        # Counted as `unreadable`, which the run-wide gate below already turns
        # into "delete nothing this run" — the same fail-closed treatment the
        # pre-test gives a file that could not be opened, for the same reason:
        # the run's picture of the queue is provably incomplete.
        unreadable=$((unreadable+1))
        printf '  (skipping %s — it opened but could not be read through to the end, so the records after the failure point were never seen; preserved, NOT deleted — check the file and the device)\n' \
          "$(basename "$_file")"
      fi
    fi
  done

  # ⛔ A READ ERROR IS RUN-WIDE FAIL-CLOSED; A PARSE FAILURE IS NOT. DO NOT
  # "HARMONISE" THEM. ⛔ The two are not the same kind of ignorance:
  #   a parse failure is LOCALISED — the file was read, and the run knows exactly
  #   which record it could not understand, so its own file is pinned and every
  #   other file's accounting is unaffected (that is the whole point above);
  #   a read error is NOT localised — the content is entirely unknown, so the
  #   run's picture of the queue is provably incomplete, and the only operation
  #   downstream is the one with no undo.
  # So a single unreadable file suppresses EVERY deletion this run, which makes
  # `deleted=yes` alongside `unreadable>0` unreachable by construction rather
  # than merely unlikely. It costs one re-read on the next run once the
  # permissions are fixed, and it is reported rather than silent.
  #
  # ⛔ THE DELETE'S STATUS IS THE THING BEING REPORTED. ⛔ This was an unchecked
  # `rm -f` followed by an unconditional `deleted=yes` — the SAME defect this
  # branch already fixed for the dismissal append (C-2: `recorded=` reported
  # after a write that put nothing in the log). `rm -f` suppresses a MISSING
  # file, not a permission error: with $CLAUDE_DIR read-only every unlink fails,
  # the snapshots all survive, and the run still says `deleted=yes`. The caller
  # is then told a snapshot was retired while it is still queued, so the next
  # merge re-reads and re-filters the same records with no explanation — which
  # is exactly the stranded-queue failure C-2 was about.
  #
  # Per-file, because `rm -f` with a list is PARTIAL on failure: some names can
  # be unlinked while others are refused, and one status for the whole list
  # cannot say which. Each survivor is named on stderr so the person reading the
  # summary can fix the permission, and ANY survivor makes the run report
  # `deleted=no` — the honest direction, since the queue is not drained.
  #
  # `[[ -e ]]` after a zero exit is belt-and-braces: it costs one stat and it
  # closes the case where the unlink is reported successful and the name is
  # still there (a stale NFS handle is the textbook one).
  local delete_survivors=0 _del
  if [[ ${#delete_list[@]} -gt 0 && "$unreadable" -eq 0 ]]; then
    for _del in "${delete_list[@]}"; do
      if rm -f "$_del" 2>/dev/null && [[ ! -e "$_del" ]]; then
        continue
      fi
      delete_survivors=$((delete_survivors+1))
      printf 'WARN: could not remove %s — every record in it is already learned or dismissed, but the file survived, so it will be read and re-filtered on the next merge. Check permissions and ownership in %s.\n' \
        "$(basename "$_del")" "$CLAUDE_DIR" >&2
    done
    # `deleted=yes` only when EVERY authorized removal actually happened.
    [[ "$delete_survivors" -eq 0 ]] && deleted=yes
  fi

  if [[ "$candidate_count" -eq 0 ]] && [[ "$unreadable" -gt 0 || "$parse_failures" -gt 0 ]]; then
    # A malformed line may hold a finding we could not read, and an unreadable
    # file may hold anything at all; deleting either would drop it permanently
    # and the loss would be silent.
    printf '(no actionable candidates, but %s record(s) failed to parse and %s file(s) could not be read — preserved for manual review; nothing was deleted)\n' \
      "$parse_failures" "$unreadable"
  elif [[ "$candidate_count" -eq 0 ]]; then
    # ⛔ THE COUNT IS PRINTED, NOT ASSERTED — AND THAT IS WHY THERE IS NO SECOND
    # BRANCH HERE. ⛔ The unscoped ancestor of this line ("all capture records
    # already learned or dismissed") printed on a run that had opened NOTHING,
    # against a dismissed log holding zero entries — a claim falsifiable from the
    # script's own state, on the very run that deleted the files it described.
    # Interpolating the number the run actually read removes that class rather
    # than moving it: a record-less queue prints `0` and says so on its own,
    # instead of relying on a branch somebody has to remember to keep.
    printf '(no new lessons to propose — every one of the %s capture record(s) this run read is already learned or dismissed)\n' \
      "$records_read"
  else
    printf '%s new finding(s) to evaluate for lessons.\n' "$candidate_count"
    echo ""
    echo "Proposed findings for lessons PR:"
    local i=0 c
    for c in "${candidates[@]}"; do
      i=$((i+1))
      _finding=$(printf '%s' "$c" | jq -er '.finding' 2>/dev/null) || continue
      _verdict=$(printf '%s' "$c" | jq -er '.verdict' 2>/dev/null) || continue
      _origin=$(printf '%s' "$c" | jq -er '.origin' 2>/dev/null) || continue
      _hash_full=$(printf '%s' "$c" | jq -er '.hash' 2>/dev/null) || continue
      printf '[%s] origin=%s verdict=%s (hash: %s)\n' "$i" "$_origin" "$_verdict" "${_hash_full:0:8}"
      printf '    %s\n' "$(printf '%s' "$_finding" | tr '\n' ' ' | cut -c1-200)"
      echo ""
    done
    # Machine-readable, one line per candidate, so the agent's consensus pass and
    # Step 7b's `lessons-keep N` resolve the SAME numbering this listing printed
    # instead of re-deriving it from a different sweep.
    for c in "${candidates[@]}"; do
      printf 'CANDIDATE %s\n' "$c"
    done
    echo ""
    printf 'Existing lessons live in %s.\n' "$lessons_yml"
    # ⛔ NO COUNT HERE, DELIBERATELY. ⛔ Deletion is per-file now, so a run that
    # proposes candidates from one snapshot may legitimately have removed a
    # different, fully-drained one — `${#all_pending[@]}` would then name files
    # that are no longer on disk. The authoritative numbers are on the summary
    # line below, where `snapshots=` and `deleted=` are computed rather than
    # asserted.
    printf 'Snapshots holding an undecided finding are preserved in %s until you reply.\n' "$CLAUDE_DIR"
  fi

  summary "lessons candidates=$candidate_count parse_failures=$parse_failures unreadable=$unreadable snapshots=${#all_pending[@]} deleted=$deleted"
  return 0
}

# =============================================================================
# SUBCOMMAND: defer — THE ONLY WRITER OF THE CROSS-PR DEFERRED QUEUE
#
# ⛔ WHY THIS SUBCOMMAND EXISTS. ⛔ The pending-lessons store had THREE writers,
# two of them English prose in commands/review-pr.md, and ZERO tests:
#   - `lessons-pr` step 8 carried a SECOND deletion rule ("delete the snapshot if
#     all findings are handled") which disagreed with `cmd_lessons`';
#   - `lessons-defer` appended to this queue with a hand-described dedupe rule and
#     NEVER STATED THE RECORD FORMAT — while the reader requires `.finding`,
#     `.verdict` and `.origin` via `jq -er`. A record missing any of the three
#     raises `parse_failures`, and a parse failure preserves the file it is in
#     forever, so ONE prose-written record could strand the queue permanently.
#     Not an attack: the ordinary path, with the format simply unstated.
# `grep -n "lessons-defer\|pending-lessons-deferred\|deferred queue"` over the
# test suite returned NOTHING before this landed — the store with the most writers
# had the least coverage, which is the shape this whole script exists to remove.
#
# It writes through `lesson_record_hash`, the SAME validator the reader uses, so a
# record this appends is a record the reader can drain. That is the property a
# prose writer could not have.
# =============================================================================
cmd_defer() {
  local owner="${1:-}" repo="${2:-}" pr="${3:-}"
  if [[ -z "$owner" || -z "$repo" || -z "$pr" ]]; then usage; exit 2; fi
  # ⛔ THE PR NUMBER IS INTERPOLATED INTO A PATH THAT THIS SUBCOMMAND DELETES. ⛔
  # It is validated by BUILDING the name and holding it to `LESSONNAME_RE` — the
  # same rule the sweep applies — rather than by a second digits regex that could
  # drift from it. Without this, `defer baselito ai-engineering ../../victim`
  # resolves outside the state dir and reaches the `rm`.
  local snap_name="pending-lessons-$pr.jsonl"
  if [[ ! "$snap_name" =~ $LESSONNAME_RE ]]; then
    printf 'consume-deviations.sh: PR_NUMBER must be digits, got %s — it names the file in %s that this subcommand deletes.\n' "$pr" "$CLAUDE_DIR" >&2
    usage; exit 2
  fi
  if claude_dir_is_symlink; then
    printf 'Refusing to defer lessons: %s is a symlink. Exiting cleanly.\n' "$CLAUDE_DIR" >&2
    summary "defer refused=symlinked-state-dir"; return 0
  fi
  # THE REPO GATE, on a subcommand that deletes — the same reason `lessons` has
  # one: every pending-lessons-*.jsonl in ~/.claude is a TOOLBOX snapshot, so a
  # run from a project repo would append and then delete another repo's queue.
  if ! is_toolbox_repo "$owner" "$repo"; then
    summary "defer refused=not-toolbox-repo repo=$owner/$repo"; return 0
  fi
  local snap="$CLAUDE_DIR/$snap_name"
  # ⛔ SYMLINK GUARD BEFORE THE APPEND AND BEFORE THE DELETE. ⛔ An unguarded `>>`
  # through a symlinked queue is a path-traversal WRITE and an unguarded `rm`
  # through a symlinked snapshot is a path-traversal DELETE. The dismissed log is
  # in the test too: it is what decides which records are skipped below, so
  # reading it through a symlink lets an attacker-written file suppress records.
  if [[ -L "$DEFERRED_LESSONS" || -L "$snap" || -L "$DISMISSED_LESSONS_LOG" ]]; then
    printf 'WARN: defer blocked — the deferred queue, the per-PR snapshot or the dismissed-lessons log is a symlink. Nothing was appended and nothing was deleted; the records stay in the snapshot and resurface.\n' >&2
    summary "defer refused=symlinked-state-file"; return 0
  fi
  if [[ ! -f "$snap" ]]; then
    summary "defer refused=no-snapshot snapshot=$snap_name"; return 0
  fi
  # Unreadable is not empty, here as everywhere else in this file: a snapshot that
  # cannot be opened yields no records, and "no records" must never authorize the
  # delete.
  if [[ ! -r "$snap" ]]; then
    printf 'WARN: defer blocked — %s is not readable, so its records cannot be moved to the deferred queue. Preserved, NOT deleted; check permissions.\n' "$snap" >&2
    summary "defer refused=unreadable-snapshot snapshot=$snap_name"; return 0
  fi
  # PRESERVE on a missing tool, exactly as `archive` does — and through the same
  # helper, so a fourth required tool added to `have_tools` guards both.
  if ! have_tools; then
    printf '⚠️  jq or shasum not installed — refusing to defer (a record that cannot be validated must not be appended to a queue whose reader validates every record). %s preserved.\n' "$snap" >&2
    summary "defer refused=missing-tools snapshot=$snap_name"; return 0
  fi
  # A queue that EXISTS but cannot be READ is fail-closed too: the dedupe below is
  # the only thing bounding this file's growth, so appending without it would
  # duplicate every record on every rerun.
  if [[ -e "$DEFERRED_LESSONS" && ! -r "$DEFERRED_LESSONS" ]]; then
    printf 'WARN: defer blocked — %s is not readable, so already-deferred records cannot be recognised and every rerun would duplicate them. %s preserved.\n' "$DEFERRED_LESSONS" "$snap" >&2
    summary "defer refused=unreadable-queue snapshot=$snap_name"; return 0
  fi
  mkdir -p "$CLAUDE_DIR"
  touch "$DISMISSED_LESSONS_LOG"

  # ⛔ THE AUTHORIZING FILE'S READABILITY IS PART OF THIS RUN'S STATUS TOO. ⛔
  # `surface` and `archive` both report `dismissed_log_unreadable=`; `defer` was
  # the one pass that neither guarded nor reported it, and just let
  # `hash_logged_in` fail. The consequence is small and is stated rather than
  # inflated: already-decided findings silently re-enter the deferred queue, and
  # the next `lessons` read filters them out once the log is readable again, so
  # nothing is lost. What was wrong is the SILENCE — a summary line that looks
  # identical whether or not the file deciding what to skip could be opened.
  #
  # Reported, not blocking: the records still belong in the queue, and refusing
  # to defer them would strand the snapshot the user just asked to hold. This
  # only stops the summary claiming a clean run. `touch` above succeeds on a
  # mode-000 file the caller owns, so this test is about permissions rather than
  # existence — the same reasoning as its two siblings.
  #
  # Deliberately absent from the `refused=write-failed` return above: that run
  # has a more urgent cause to report, and it appended nothing, so what the
  # dedupe could or could not see did not affect its outcome.
  local dismissed_log_unreadable=no
  if [[ ! -r "$DISMISSED_LESSONS_LOG" ]]; then
    dismissed_log_unreadable=yes
    printf 'WARN: %s is not readable — findings already learned or dropped cannot be recognised this run, so they may be appended to the deferred queue again. Nothing is lost (the next lessons read filters them once the log is readable), but check permissions and ownership.\n' "$DISMISSED_LESSONS_LOG" >&2
  fi

  # The dedupe set: every finding digest ALREADY in the queue. A record in there
  # that the validator rejects is SKIPPED rather than fatal — it is already
  # written, refusing new work because of it would be the run-wide coupling
  # `cmd_lessons` just stopped doing, and `cmd_lessons` reports it as a parse
  # failure on its own account.
  local seen="|" _record _hash_full
  if [[ -f "$DEFERRED_LESSONS" ]]; then
    _record=''
    while IFS= read -r _record || [[ -n "$_record" ]]; do
      [[ -z "$_record" ]] && continue
      _hash_full=$(lesson_record_hash "$_record") || continue
      set_add seen "$_hash_full"
    done < "$DEFERRED_LESSONS"
  fi

  local appended=0 skipped=0 parse_failures=0 to_append=()
  _record=''
  # `|| [[ -n "$_record" ]]`: the same EOF-residue guard as every other read loop
  # in this file. A final record with no trailing newline would otherwise be
  # counted in NEITHER tally — and `appended + skipped > 0 && parse_failures == 0`
  # is what authorizes the delete, so the record would be destroyed unread.
  while IFS= read -r _record || [[ -n "$_record" ]]; do
    [[ -z "$_record" ]] && continue
    _hash_full=$(lesson_record_hash "$_record") || { parse_failures=$((parse_failures+1)); continue; }
    # Already decided: a finding that was learned or dropped must not come back
    # through the deferred queue. Counted as SKIPPED, which is a decision — so it
    # does not hold the snapshot.
    hash_logged_in "$_hash_full" "$DISMISSED_LESSONS_LOG" && { skipped=$((skipped+1)); continue; }
    set_has seen "$_hash_full" && { skipped=$((skipped+1)); continue; }
    set_add seen "$_hash_full"
    to_append+=( "$_record" )
  done < "$snap"

  # ⛔ ONE APPEND, AND ITS STATUS DECIDES WHETHER THE SNAPSHOT MAY GO. ⛔ Same
  # rule as the canonical dismissal write: an unchecked `>>` reports a success the
  # file never received, and here that report is what would authorize deleting the
  # only other copy of these records. The subshell is load-bearing — `2>/dev/null`
  # on a simple command does NOT suppress the SHELL's own "Permission denied" from
  # a redirection it could not open, because that message is printed by the shell
  # in the current process.
  #
  # A partial write IS possible (a full disk mid-append); what this branch
  # guarantees is that the snapshot survives it, so the records are still
  # recoverable. The reader counts the truncated line as a parse failure and
  # preserves the queue, which is the same fail-closed direction.
  local write_ok=true
  if [[ ${#to_append[@]} -gt 0 ]]; then
    if ( printf '%s\n' "${to_append[@]}" >> "$DEFERRED_LESSONS" ) 2>/dev/null; then
      appended=${#to_append[@]}
    else
      write_ok=false
      printf 'WARN: could not append to %s — nothing was recorded and %s was NOT deleted. The records stay in the snapshot and resurface on the next merge.\n' "$DEFERRED_LESSONS" "$snap" >&2
    fi
  fi
  if [[ "$write_ok" != "true" ]]; then
    summary "defer refused=write-failed snapshot=$snap_name appended=0 skipped=$skipped parse_failures=$parse_failures deleted=no"
    return 0
  fi

  # ⛔ DELETE ONLY WHEN EVERY RECORD IS ACCOUNTED FOR, AND ONLY IF THERE WAS ONE. ⛔
  #   parse_failures == 0     — a record the reader could not validate was NOT
  #                             appended, so the snapshot is its only copy.
  #   appended + skipped > 0  — at least one record was read and either written
  #                             to the queue or deliberately skipped. A snapshot
  #                             that yielded nothing has earned nothing, the same
  #                             `records > 0` rule the archive pass and the
  #                             lessons delete both carry.
  #
  # ⛔ AND THE DELETE'S STATUS IS REPORTED TOO. ⛔ Same defect as `cmd_lessons`'
  # `rm`, and as the unchecked append two blocks above (C-2): the unlink was
  # issued and `deleted=yes` followed unconditionally. `rm -f` hides a MISSING
  # file, not a refused one — with $CLAUDE_DIR read-only the snapshot survives
  # and the run still calls it retired.
  #
  # What that costs HERE is smaller than in `cmd_lessons`, and worth stating so
  # the guard is not mistaken for data-loss protection: the records are already
  # safely in the deferred queue by this point, and the dedupe above recognises
  # them, so a surviving snapshot re-defers nothing on the next run — it reports
  # them as `skipped` instead. The lie is in the STATUS, and that is enough: the
  # caller is told a snapshot is gone while it is still on disk, which is the
  # same false report C-2 was about.
  local deleted=no
  if [[ "$parse_failures" -eq 0 && $((appended+skipped)) -gt 0 ]]; then
    # `[[ -e ]]` after a zero exit for the same belt-and-braces reason as the
    # lessons delete: it closes the reported-successful-but-still-there case.
    if rm -f "$snap" 2>/dev/null && [[ ! -e "$snap" ]]; then
      deleted=yes
    else
      printf 'WARN: could not remove %s — its records ARE in %s and will not be deferred twice, but the snapshot survived and will be read again on the next merge. Check permissions and ownership in %s.\n' \
        "$snap_name" "$DEFERRED_LESSONS" "$CLAUDE_DIR" >&2
    fi
  fi

  printf '%s finding(s) deferred to %s' "$appended" "$DEFERRED_LESSONS"
  [[ "$skipped" -gt 0 ]] && printf ' (%s already deferred or already decided)' "$skipped"
  printf '.\n'
  [[ "$parse_failures" -gt 0 ]] && printf '(note: %s record(s) could not be validated — NOT appended, and %s is preserved so nothing is lost)\n' "$parse_failures" "$snap_name"
  summary "defer appended=$appended skipped=$skipped parse_failures=$parse_failures deleted=$deleted dismissed_log_unreadable=$dismissed_log_unreadable"
  return 0
}

# =============================================================================
# Dispatch
# =============================================================================
CMD="${1:-}"
shift || true
case "$CMD" in
  surface) cmd_surface "$@" ;;
  archive) cmd_archive "$@" ;;
  dismiss) cmd_dismiss "$@" ;;
  lessons) cmd_lessons "$@" ;;
  defer)   cmd_defer   "$@" ;;
  ""|-h|--help|help) usage; exit 2 ;;
  *) printf 'consume-deviations.sh: unknown subcommand %s\n' "$CMD" >&2; usage; exit 2 ;;
esac
exit 0
