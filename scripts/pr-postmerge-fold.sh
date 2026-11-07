#!/usr/bin/env bash

# =============================================================================
# scripts/pr-postmerge-fold.sh — Shared post-merge fold for the ai-engineering
# toolbox (deviation snapshot + automated-review/Codex lessons fold).
#
# WHY THIS SCRIPT EXISTS (automated-review finding, PR #127):
# The fold used to live ONLY inline in commands/merge-pr.md Step 2.5 — it ran
# whenever a toolbox PR was merged via /merge-pr. But ai-engineering PRs can
# also be merged through the GitHub UI or a bare `gh pr merge` (the docs offer
# this path too), which never touches /merge-pr. When that happened the fold
# never ran, so pending-deviations-<PR>.log and pending-lessons-<PR>.jsonl
# were never written — and /review-pr Step 0.5 (the reader) had nothing to
# consume. Deviation/lessons telemetry was silently lost for every PR merged
# outside /merge-pr.
#
# Extracting the fold into this ONE script and calling it from BOTH merge
# paths — /merge-pr Step 2.5 (at merge time, handover.md still fresh) AND
# /review-pr Step 0.5's MERGED fallback (whenever a merge is discovered, no
# matter how it happened) — means the fold runs regardless of how the PR
# merged.
#
# CALLERS (both pass positional args, do NOT source this file):
#   commands/merge-pr.md   Step 2.5 — after a confirmed /merge-pr merge
#   commands/review-pr.md  Step 0.5 — MERGED fallback for UI/gh-merged PRs
#
# Usage: pr-postmerge-fold.sh OWNER REPO_NAME PR_NUMBER [REPO_ROOT]
#   OWNER      — repo owner, e.g. "baselito"
#   REPO_NAME  — repo name, e.g. "ai-engineering"
#   PR_NUMBER  — the PR that just merged
#   REPO_ROOT  — absolute path to the local git checkout, or empty/omitted if
#                unavailable. Used only to locate handover.md for the
#                deviation snapshot; the lessons fold does not need it.
#
# Caller responsibilities (NOT duplicated here — see rules/git-workflow.md
# "Auto-Merge After Review Complete" + commands/merge-pr.md Step 2.5 +
# commands/review-pr.md Step 0.5 for the full context):
#   - Confirm the PR is actually MERGED before calling this script. Both
#     callers do their own state read-back (merge-pr.md's Step 2 read-back +
#     inline FOLD_STATE gate; review-pr.md's PR_STATE == "MERGED" check).
#     This script does NOT re-verify merge state itself.
#   - This script does NOT merge anything and NEVER fails the caller's
#     workflow — it is best-effort telemetry capture, not a gate.
#
# `set -uo pipefail` (NOT `set -e`): this script must never abort partway
# through — every failure path below is handled explicitly, and the script
# always exits 0 so it can never make a caller's workflow look broken.
# =============================================================================

set -uo pipefail

OWNER="${1:-}"
REPO_NAME="${2:-}"
PR_NUMBER="${3:-}"
REPO_ROOT="${4:-}"

if [[ -z "$OWNER" || -z "$REPO_NAME" || -z "$PR_NUMBER" ]]; then
  echo "pr-postmerge-fold.sh: usage: pr-postmerge-fold.sh OWNER REPO_NAME PR_NUMBER [REPO_ROOT]" >&2
  exit 0
fi

# ⛔ TOOLBOX SELF-GATE (defense in depth) ⛔ — only the ai-engineering toolbox
# has the deviation/lessons machinery (no Jira board; ticketless self-
# maintenance — see rules/workflow-discipline.md "Toolbox self-maintenance
# exception"). Both callers already gate on this before invoking the script,
# but the script must be safe to run standalone too — never fold telemetry
# for a project repo.
if [[ "$OWNER" != "baselito" || "$REPO_NAME" != "ai-engineering" ]]; then
  echo "pr-postmerge-fold.sh: not the ai-engineering toolbox ($OWNER/$REPO_NAME) — nothing to fold." >&2
  exit 0
fi

REPO_FLAG="--repo ${OWNER}/${REPO_NAME}"

# =============================================================================
# PR METADATA — read ONCE, used by both halves below.
#
# `@tsv` keeps the whole answer on ONE line even when the body contains newlines
# (jq escapes \n, \t, \r and \\ inside a TSV field), so `cut -f N` is a safe
# split. `// ""` on every field so a null (e.g. mergedAt on an unmerged PR, or an
# empty body) yields an empty column instead of the string "null", which would
# otherwise parse as a timestamp/branch name and be silently wrong.
#
# This read used to be a `--json headRefName` call further down, for the lessons
# half alone. It moved up here because the deviation gate below needs `mergedAt`
# and the PR's own issue references from the SAME PR — one call answering both is
# one fewer place for the two halves to disagree about which PR they are folding.
#
# Every consumer treats an empty answer as "unknown", never as a benign default:
# the deviation gate fails CLOSED on an unknown merge time (see the window
# rationale below), and the lessons half keeps its pre-existing behaviour of
# computing an empty branch key.
# =============================================================================
PR_META=$(gh pr view "$PR_NUMBER" $REPO_FLAG \
  --json mergedAt,headRefName,title,body \
  --jq '[(.mergedAt // ""), (.headRefName // ""), ((.title // "") + " " + (.body // ""))] | @tsv' \
  2>/dev/null | head -1 || echo '')
PR_MERGED_AT=$(printf '%s' "$PR_META" | cut -f1)
PR_HEAD_REF=$(printf '%s' "$PR_META" | cut -f2)
PR_TITLE_BODY=$(printf '%s' "$PR_META" | cut -f3)

# ⛔ THE FRESHNESS WINDOW — A MEASUREMENT, NOT A CADENCE NOTE. ⛔
# How long after a merge handover.md can still be assumed to hold THAT merge's
# work, when nothing in the file says which work it holds.
#
# WHY 1 HOUR. The two producers of this call are (a) /merge-pr Step 2.5, which
# runs seconds after the merge it just performed, and (b) /review-pr Step 0.5's
# fallback, which discovers a UI/`gh`-merged PR on a poll. Both land inside an
# hour when they land at all, and an hour is comfortably shorter than "a new task
# has started in this session" — which is the event that makes handover.md stop
# belonging to the merged PR. The number lives here, next to the comparison that
# uses it, because the value IS the policy; a comment elsewhere describing a
# cron's typical cadence is not a bound (issue #154).
#
# It is a BACKSTOP, not the primary check. `fold_handover_belongs_to_pr` below
# prefers positive BINDING — the handover naming this PR's own branch or an issue
# this PR references — and only falls back to the clock when the handover names
# nothing at all. A bound handover is snapshotted however old the merge is.
FOLD_FRESHNESS_WINDOW_SECONDS=3600

# ISO-8601 Z timestamp -> epoch seconds, on both `date` dialects: GNU takes
# `-d <string>`, BSD/macOS takes `-j -f <format>`. Returns non-zero (and prints
# nothing) when the input is empty or neither dialect can parse it — callers MUST
# treat that as "unknown", never as 0, or an unparseable timestamp becomes 1970
# and every merge reads as ancient.
fold_iso_to_epoch() {
  local _iso="$1" _e
  [[ -z "$_iso" ]] && return 1
  _e=$(date -u -d "$_iso" +%s 2>/dev/null) && [[ -n "$_e" ]] && { printf '%s' "$_e"; return 0; }
  _e=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$_iso" +%s 2>/dev/null) && [[ -n "$_e" ]] && { printf '%s' "$_e"; return 0; }
  return 1
}

# =============================================================================
# fold_handover_belongs_to_pr — the gate in front of the deviation snapshot.
#
# ⛔ WHAT THIS FUNCTION DOES, STATED AS NARROWLY AS IT IS TRUE. ⛔ It decides
# whether $SNAPSHOT_HANDOVER can be attributed to PR #$PR_NUMBER, using two
# measurements and nothing else:
#   BINDING  — the trailing `# ` heading of handover.md (a task boundary: the
#              file is a sequence of them, and the LAST one names the work the
#              file currently holds). If that heading names this PR's head branch,
#              or an issue number that also appears in this PR's own number,
#              title or body, the handover provably belongs to this PR's work.
#              If it names some OTHER issue number, it provably does not. If it
#              names nothing identifiable, this measurement abstains.
#   RECENCY  — now minus the PR's `mergedAt`, compared against
#              FOLD_FRESHNESS_WINDOW_SECONDS above. Used ONLY when BINDING
#              abstains.
# It returns 0 (snapshot may proceed) when BINDING says bound, or when BINDING
# abstains AND the merge is inside the window. Otherwise it prints why and
# returns 1.
#
# ⛔ WHAT IT DOES NOT DO. ⛔ It does not verify that the deviations INSIDE
# handover.md were written during this PR's work — only that the file as a whole
# is attributable to it. A handover carrying an earlier task's blocks under one
# trailing marker still snapshots them all; that is the awk's `## ` scoping
# problem (TC-STL-25), not this gate's. It also cannot detect a handover whose
# trailing marker is WRONG — a marker naming this PR while the content belongs
# elsewhere reads as bound. Both are stated because the guard this replaced
# claimed more than it checked, which is the defect class (TL-0019) that produced
# issue #154 in the first place.
#
# ⛔ IT FAILS CLOSED. ⛔ An unreadable merge time (no `gh`, network down, a
# timestamp neither `date` dialect parses) is UNKNOWN, not fresh — with nothing
# binding the handover either, the run refuses and says so. Losing one snapshot
# is recoverable (handover.md is untouched and a later in-window run still folds
# it); filing another task's deviations under this PR is not, because the surface
# that reads them cannot tell they are misattributed.
# =============================================================================
fold_handover_belongs_to_pr() {
  local _marker _marker_nums _pr_nums _n _p
  local _binding=indeterminate
  local _freshness=unknown _now _merged _age=""

  # --- BINDING -------------------------------------------------------------
  _marker=$(awk '/^# / { m = $0 } END { print m }' "$SNAPSHOT_HANDOVER" 2>/dev/null)
  _marker_nums=$(printf '%s' "$_marker" | grep -oE '#[0-9]+' | tr -d '#' | sort -u)

  # The PR's identity set is deliberately GENEROUS — its own number plus every
  # `#N` in its title and body (which is where `Closes #N` lives). A too-narrow
  # set produces false REFUSALS, and a refusal silently loses telemetry, which is
  # the worse of the two failures here.
  # ⛔ ONLY CLOSING REFERENCES COUNT, NOT EVERY `#N` MENTIONED. ⛔
  # This used to take every `#N` in the title/body. A PR reading
  # `Closes #154; follow-up #140` therefore claimed #140 as well, and bound a stale
  # handover headed `# NEW TASK — issue #140` — snapshotting another task's
  # deviations under this PR, which is the precise harm this gate exists to stop.
  # A mention is not a claim of ownership. Only GitHub's closing keywords are.
  # `|| true` here is DEFENSIVE, not load-bearing — and the distinction matters,
  # because a reviewer raised it as a crash and it does not reproduce.
  # The claim was: grep exits 1 on no match, `set -euo pipefail` propagates that
  # through the assignment, the fold aborts, an ordinary chore PR captures nothing.
  # MEASURED AGAINST THIS EXACT STRUCTURE: it does not. The grep chain sits inside a
  # NESTED command substitution supplying an ARGUMENT to `printf`; the assignment's
  # status is `printf | sort`, which succeeds. Verified:
  #   set -euo pipefail; v=$(printf '%s\n%s\n' 42 "$(... | grep -oE '#[0-9]+' ...)" | sort -u)
  #   -> reached, v=[42]
  # A first attempt at confirming the report reconstructed the line with the grep as
  # the OUTERMOST command, where it DOES abort — and then reported that as the real
  # behaviour. Measuring a reconstruction instead of the code is the error, not the
  # reviewer's report.
  # The guard stays because it costs nothing and the nesting is not obviously
  # load-bearing to the next reader: promote that grep to the outer position and the
  # abort becomes real. It is a guard against a future edit, not a present bug.
  # ⛔ TWO MORE THINGS THIS PATTERN HAD WRONG. ⛔
  # (a) NO LEFT WORD BOUNDARY: `Discloses #777` contains `closes #777`, so a PR that
  #     merely DISCLOSED something claimed to close it. `(^|[^[:alnum:]])` fixes it.
  # (b) CROSS-REPO REFERENCES DROPPED: GitHub honours
  #     `Fixes octo-org/octo-repo#100`, and the old pattern captured no number from
  #     it — so a correctly-bound handover was REFUSED and its deviations lost. That
  #     is the false-negative direction, which loses telemetry silently rather than
  #     mis-filing it loudly. An optional `owner/repo` segment is now allowed before
  #     the `#`.
  _pr_nums=$(printf '%s\n%s\n' "$PR_NUMBER" \
    "$(printf '%s' "$PR_TITLE_BODY" \
       | grep -oiE '(^|[^[:alnum:]])(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]*:?[[:space:]]*([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)?#[0-9]+' \
       | grep -oE '#[0-9]+' | tr -d '#' || true)" | sort -u)

  # ⛔ THE BRANCH MUST MATCH AS A WHOLE NAME, NOT AS A SUBSTRING. ⛔
  # `*"$PR_HEAD_REF"*` meant PR branch `feature/payments` bound a handover headed
  # `# NEW TASK — branch feature/payments-v2`: a DIFFERENT task, accepted as this
  # one, recency then bypassed because binding outranks the clock. The mechanism
  # built to stop cross-task capture was itself performing it.
  # ⛔ THE DELIMITER IS WHITESPACE, NOT "NOT-A-BRANCH-CHARACTER". ⛔
  # A first fix excluded the characters a branch name may contain (`/ - . _`) and
  # treated everything else as a delimiter. But `@ + = ! , %` are ALSO legal in git
  # refs, so `feature/payments` still bound `feature/payments@v2` — the same
  # cross-task capture, one character class over. Enumerating what a ref may contain
  # is the losing shape; the marker is a HEADING, so the real delimiter is
  # whitespace-or-edge, which needs no knowledge of git's ref grammar at all.
  if [[ -n "$PR_HEAD_REF" ]] && printf '%s' "$_marker" \
       | grep -qE "(^|[[:space:]])$(printf '%s' "$PR_HEAD_REF" | sed 's/[][\.^$*+?(){}|/-]/\\&/g')([[:space:]]|\$)"; then
    _binding=bound
  elif [[ -n "$_marker_nums" ]]; then
    _binding=mismatch
    for _n in $_marker_nums; do
      for _p in $_pr_nums; do
        [[ "$_n" == "$_p" ]] && _binding=bound
      done
    done
  fi

  # --- RECENCY (only consulted when BINDING abstains) ----------------------
  _now=$(date -u +%s 2>/dev/null || echo '')
  _merged=$(fold_iso_to_epoch "$PR_MERGED_AT" || echo '')
  if [[ -n "$_now" && -n "$_merged" ]]; then
    _age=$(( _now - _merged ))
    # A NEGATIVE age (clock skew, or a timestamp in the future) is not fresh —
    # it is a measurement we cannot trust, so it takes the closed branch.
    if [[ "$_age" -ge 0 && "$_age" -le "$FOLD_FRESHNESS_WINDOW_SECONDS" ]]; then
      _freshness=fresh
    else
      _freshness=stale
    fi
  fi

  if [[ "$_binding" == "bound" ]]; then
    return 0
  fi
  if [[ "$_binding" == "mismatch" ]]; then
    echo "Skipping deviation snapshot: handover.md's trailing task heading names other work — [$_marker] (issue reference(s): $(printf '%s' "$_marker_nums" | tr '\n' ' ')), which does not match PR #${PR_NUMBER}, its branch (${PR_HEAD_REF:-unknown}) or any issue it references. Snapshotting it would file another task's deviations under this PR (issue #154). handover.md is untouched." >&2
    return 1
  fi
  if [[ "$_freshness" == "fresh" ]]; then
    return 0
  fi
  if [[ "$_freshness" == "stale" ]]; then
    echo "Skipping deviation snapshot: handover.md's trailing task heading — [${_marker:-<none>}] — names no issue or branch this fold can match against PR #${PR_NUMBER}, and the merge is ${_age}s old (window: ${FOLD_FRESHNESS_WINDOW_SECONDS}s). Neither binding nor recency establishes that this handover is PR #${PR_NUMBER}'s work. handover.md is untouched." >&2
    return 1
  fi
  echo "Skipping deviation snapshot: could not read PR #${PR_NUMBER}'s merge time (mergedAt=[${PR_MERGED_AT}] — is gh reachable?), and handover.md's trailing task heading — [${_marker:-<none>}] — names nothing to bind against. Refusing rather than assuming the handover is this PR's work. handover.md is untouched." >&2
  return 1
}

# --- Post-merge: Deviation snapshot ---
# Snapshot Deviations from handover.md while it's fresh — ideally called
# immediately after merge, same session that did the work. The next
# /review-pr fire's Step 0.5 reads from this snapshot, not live handover.md —
# avoids the race where a new task clears handover before we surface.
#
# ⛔ SYMLINK DEFENSE ⛔ — state files live in ~/.claude/ (outside the repo), so
# a malicious PR branch cannot replace them with symlinks. We still guard: the
# handover we read is in the local checkout's .claude/ — check it for symlinks.
SNAPSHOT_CLAUDE_DIR="$HOME/.claude"
SNAPSHOT_HANDOVER="$REPO_ROOT/.claude/handover.md"
SNAPSHOT_FILE_POST_MERGE="$SNAPSHOT_CLAUDE_DIR/pending-deviations-${PR_NUMBER}.log"

# This script now has TWO callers, and both may run for the SAME PR (at-merge
# time via /merge-pr, then again via /review-pr's fallback). handover.md is
# only meaningful when it belongs to the merged repo — verify the checkout's
# origin matches before reading it, and never skip silently (edge-cases
# General Rule 1). ANCHORED match, not substring: normalize the origin URL to
# its last two path segments (works for https and ssh forms, strips .git) and
# compare exactly — a bare substring test would accept
# baselito/ai-engineering-fork or not-baselito/ai-engineering (security-
# reviewer finding).
LOCAL_ORIGIN=$(git -C "${REPO_ROOT:-.}" remote get-url origin 2>/dev/null || echo "")
LOCAL_SLUG=$(printf '%s' "$LOCAL_ORIGIN" | sed -e 's#\.git$##' -e 's#/*$##' | awk -F'[/:]' 'NF>=2 {print $(NF-1)"/"$NF}')

if [[ -L "$SNAPSHOT_CLAUDE_DIR" || -L "$SNAPSHOT_HANDOVER" || -L "$SNAPSHOT_FILE_POST_MERGE" ]]; then
  echo "Skipping deviation snapshot: ~/.claude/, handover.md, or snapshot path is a symlink (possible malicious PR)." >&2
elif [[ -f "$SNAPSHOT_FILE_POST_MERGE" && -s "$SNAPSHOT_FILE_POST_MERGE" ]]; then
  # ⛔ IDEMPOTENCY GUARD ⛔ — needed because this script now has TWO callers for
  # the same PR: /merge-pr calls it at merge time with FRESH handover.md;
  # /review-pr's fallback may call it again later (e.g. the PR merged via the
  # GitHub UI, so /merge-pr's call never happened, or it did happen and this
  # is a harmless repeat). By the time a second call happens, handover.md may
  # already be stale or cleared for a new task — overwriting a good snapshot
  # with an empty/wrong one would destroy real telemetry. First writer
  # (freshest) wins: never regenerate an existing non-empty snapshot.
  echo "Deviation snapshot for PR #$PR_NUMBER already exists and is non-empty at $SNAPSHOT_FILE_POST_MERGE — not regenerating (first writer wins; a later caller's handover.md may be stale)."
elif [[ -z "$REPO_ROOT" ]]; then
  echo "Skipping deviation snapshot: not inside a git checkout (handover.md unavailable). Lessons fold below still runs (reads ~/.claude only)." >&2
elif [[ "$LOCAL_SLUG" != "$OWNER/$REPO_NAME" ]]; then
  echo "Skipping deviation snapshot: local checkout origin ($LOCAL_ORIGIN → $LOCAL_SLUG) is not $OWNER/$REPO_NAME — the fold was invoked from outside the merged repo, so its handover.md is a different repo's. Lessons fold below still runs (reads ~/.claude only)." >&2
elif [[ ! -f "$SNAPSHOT_HANDOVER" ]]; then
  # No handover.md in a matching checkout — say so rather than silently doing
  # nothing (edge-cases General Rule 1). This used to be the trailing `else` of
  # this chain; it moved up so the attribution gate below sits LAST, immediately
  # in front of the write it guards, with the file it reads already proven to
  # exist.
  echo "No handover.md found at $SNAPSHOT_HANDOVER — no deviations to snapshot for PR #$PR_NUMBER." >&2
elif ! fold_handover_belongs_to_pr; then
  # ⛔ THE ATTRIBUTION GATE (issue #154). ⛔ handover.md exists and belongs to
  # this repo, but nothing establishes that it belongs to THIS PR's work. The
  # function has already printed which measurement refused and why — do not
  # restate it here, and do NOT weaken this to a warning that falls through: the
  # whole failure being fixed is a snapshot written on an assumption.
  :
else
  # Ensure the target dir exists before the redirect — a missing ~/.claude
  # would make the awk redirection fail (see the write-failure guard below).
  mkdir -p "$SNAPSHOT_CLAUDE_DIR" 2>/dev/null || true
  # Format: JSONL — one JSON object per line with {ts, phase, body}.
  # JSONL is robust to arbitrary content in the deviation body: no
  # multi-char record-separator pitfalls (the previous `---\n` approach
  # was broken by `read -d '---'` which splits on every `-`).
  # Multi-line deviation entries (bullet + indented continuation) are
  # preserved as \n-escaped strings in the JSON body field.
  # ⛔ STRIP NUL BEFORE ANY awk SEES IT — AND CHECK THAT THE STRIP WORKED. ⛔
  # The C0 table below covers 0x01-0x1F. `index()` is 1-based, so position 0 is
  # unrepresentable and a NUL would fall through to the pass-through branch and be
  # copied out RAW, producing a snapshot jq cannot parse — the permanent stranding
  # this function exists to prevent.
  #
  # This is NOT theoretical-only, and the earlier comment here was too confident
  # about it: on the macOS system awk an input record is TRUNCATED at the first
  # NUL, so json_escape never receives one (measured: `printf 'A\000B\n' | awk
  # '{print length($0)}'` prints 1). But this script calls bare `awk`, and gawk on
  # Linux CAN carry a NUL through a record. Reviewer raised this five times on
  # PR #162 and was right to.
  #
  # Doing it here rather than inside awk makes the behaviour IDENTICAL on every awk
  # implementation, which is the property the rest of this function is written for.
  # Measured with BSD tr: `printf 'A\000B\nC\001D\n'` goes 8 bytes -> 7, the NUL
  # is gone, 0x01 SURVIVES to be escaped normally, and awk then reports length 2
  # for line 1 instead of truncating at 1.
  #
  # NOTE ON THE CLAIM: NUL is REMOVED, not escaped. A handover containing a NUL is
  # already corrupt — it is a text file — so dropping the byte is the honest repair
  # and the PR title says "no C0 byte reaches the snapshot raw" rather than
  # "escapes every C0 byte", which would be false of 0x00.
  #
  # The exit status is checked because a silently-failed strip yields an EMPTY
  # input, and empty input reads as "no deviations" — the under-capture failure
  # this pipeline's other guards already exist to stop. On failure, take the same
  # path as an awk failure: warn loudly and capture nothing rather than pretend.
  # ⛔ mktemp, NOT A FIXED NAME — THIS FILE MUST NOT BE GUESSABLE OR SHARED. ⛔
  # A first version used "$SNAPSHOT_FILE_POST_MERGE.nulfree", which was wrong twice
  # over, and both were caught by review rather than by me:
  #   * PREDICTABLE PATH -> SYMLINK FOLLOWING. `>` follows symlinks, so a symlink
  #     pre-planted at that guessable name redirects the entire handover into an
  #     arbitrary file. This script ALREADY rejects a symlinked claude dir, handover
  #     and snapshot near the top — the file I added simply was not covered by that
  #     defence. A guard present on every sibling path and absent on the new one.
  #   * CONCURRENT FOLDS SHARE IT. Two folds running at once write the same path and
  #     clobber each other's input.
  # `mktemp` closes both: it creates with O_EXCL, so it cannot follow or clobber an
  # existing symlink, and the random suffix removes the collision. Its own failure is
  # checked too — an unwritable state dir must not silently become "no deviations".
  SNAPSHOT_NUL_FREE=$(mktemp "${SNAPSHOT_FILE_POST_MERGE}.nulfree.XXXXXX" 2>/dev/null || echo "")
  if [[ -z "$SNAPSHOT_NUL_FREE" ]]; then
    echo "WARN: could not create a temporary file for the NUL pre-strip next to $SNAPSHOT_FILE_POST_MERGE for PR #$PR_NUMBER — deviations were NOT captured for this merge. Investigate rather than assuming there were none." >&2
    AWK_RC=1
  elif ! tr -d '\000' < "$SNAPSHOT_HANDOVER" > "$SNAPSHOT_NUL_FREE" 2>/dev/null; then
    rm -f "$SNAPSHOT_NUL_FREE"
    echo "WARN: could not pre-strip NUL bytes from $SNAPSHOT_HANDOVER for PR #$PR_NUMBER — deviations were NOT captured for this merge (no partial file left behind). Investigate rather than assuming there were none." >&2
    # Reuse the EXISTING write-failure guard below rather than adding a second
    # exit path: a failed strip must not abort the LESSONS half of this fold.
    AWK_RC=1
  else
  awk -v ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    # ⛔ JSON FORBIDS EVERY RAW C0 BYTE, NOT JUST THE FIVE WITH SHORT FORMS. ⛔
    # This function used to escape only backslash, double quote, tab, CR and LF,
    # so every other control byte in 0x01-0x1F was copied into the JSON string
    # RAW. That is invalid JSON per spec, and jq enforces the spec:
    #   jq: parse error: Invalid string: control characters from U+0000 through
    #       U+001F must be escaped
    # No attacker is required to produce one: pasting colourised terminal output
    # into a `## ` phase heading in handover.md leaves a raw ESC (0x1B) there,
    # and the heading is copied straight into the phase field.
    # The consequence was worse than a parse error, because two guards each
    # declined the record and neither handed it on. The /review-pr Step 0.5
    # consumer failed its `jq -er .phase`, so the snapshot was counted as a parse
    # failure and never archived and never surfaced (correct fail-closed
    # behaviour on its own); and the legacy-format guard inspects only line 1,
    # which the offending line usually is not, so the file was not classified
    # legacy either. Net: one stray ESC pinned the snapshot forever, re-reported
    # on every run, with no path to resolution offered anywhere. Issue #155;
    # TC-STL-74 in scripts/test-sync-toolbox-lessons.sh pins both directions.
    #
    # WHAT IS COVERED: bytes 0x01-0x1F. Three of them — tab, LF and CR — keep
    # the short forms above; the other 28 get the long \uXXXX form below.
    # (The other two short forms, for backslash and double quote, are not
    # control bytes at all.) NUL (0x00) is NOT in the table: index() is 1-based,
    # so a 1..31 lookup string cannot represent position 0.
    #
    # ⛔ THE NUL RESIDUAL, STATED AT THE WIDTH IT WAS ACTUALLY MEASURED. ⛔ An
    # earlier draft of this comment claimed flatly that "awk cannot hold a NUL
    # inside a string". That is TRUE of the awk this was measured on — the macOS
    # system awk (version 20200816), where an input record is TRUNCATED at the
    # first NUL, so json_escape is never handed one — but it is NOT a property of
    # every awk. This script calls bare `awk`, so on Linux/CI it is usually gawk
    # or mawk, and gawk can carry a NUL through a record. There, a NUL in
    # handover.md would reach json_escape, find no match in c0_chars, and be
    # copied out raw — reproducing the very stranding this function exists to
    # prevent, one byte lower down.
    #
    # It is left UNFIXED and written down rather than papered over, because a
    # cross-implementation NUL escape cannot be honestly tested from a machine
    # that has only the truncating awk (untested awk written against a byte the
    # author cannot produce is the guess the gsub-vs-walk note below already
    # argues against). What is claimed here is exactly what was measured;
    # NOTE: no apostrophes in this awk block — it is a single-quoted shell
    # string, and one would end it. That is why this reads "the note below"
    # rather than naming it possessively.
    # a fix belongs in a change that can run under gawk and mawk and prove it.
    #
    # DEL (0x7F) and the C1 range are legal unescaped in JSON and are left alone.
    function json_escape(s,   r) {
      r = s;
      # ⛔ THE LITERAL BACKSLASH STAYS FIRST. ⛔ Every pass below WRITES
      # backslashes; running the backslash pass after any of them would double
      # the backslashes those passes just produced, so `\t` would reach the file
      # as `\\t` and decode back to two literal characters instead of a tab.
      gsub(/\\/, "\\\\", r);
      gsub(/"/, "\\\"", r);
      gsub(/\t/, "\\t", r);
      gsub(/\r/, "\\r", r);
      gsub(/\n/, "\\n", r);
      # ⛔ AND THE C0 PASS STAYS LAST, for the same reason. ⛔ It writes
      # backslashes of its own, so an earlier position would have them doubled
      # by the backslash pass and a raw ESC would decode to the six literal
      # characters of the escape sequence rather than back to the byte.
      return c0_escape(r);
    }

    # The 31 bytes 0x01-0x1F as one string, so index() doubles as the ord() awk
    # does not have: the character at position i IS the byte whose value is i.
    # Built once and cached in globals, because json_escape runs twice per
    # record. Tab, CR and LF are in the table but can never be found there by the
    # time it is consulted — json_escape has already replaced them with their
    # short forms. They stay in it so the table is a plain 1..31 range rather
    # than a hand-pruned list that a future edit could get wrong; if one ever did
    # survive, its long-form escape is still valid JSON.
    function c0_init(   i) {
      if (c0_ready) return;
      c0_chars = "";
      for (i = 1; i < 32; i++) c0_chars = c0_chars sprintf("%c", i);
      c0_ready = 1;
    }

    # Rebuild s with every remaining C0 byte written as its \u00XX escape.
    # WHY A CHARACTER WALK RATHER THAN gsub: the replacement argument of gsub
    # has its own backslash semantics, which differ between awk implementations,
    # and this script must behave identically under BSD awk on stock macOS and
    # under gawk/mawk in CI. sprintf and concatenation have no such ambiguity.
    # Non-control characters are copied through untouched, so ordinary text —
    # multi-byte UTF-8 included — round-trips byte for byte.
    function c0_escape(s,   out, i, n, ch, p) {
      c0_init();
      out = "";
      n = length(s);
      for (i = 1; i <= n; i++) {
        ch = substr(s, i, 1);
        p = index(c0_chars, ch);
        if (p > 0) out = out sprintf("\\u%04x", p);
        else out = out ch;
      }
      return out;
    }
    # ⛔ THE BASELINE SENTINEL IS AN EXACT BODY, NOT A SUBSTRING. ⛔
    # This was `buf ~ /None observed\./`, a regex SEARCH, so any deviation whose
    # text happened to contain the sentinel phrase was silently discarded. It is
    # not an exotic body: a deviation about review discipline reads
    # `The checklist said "None observed." before we skipped review.` and that is
    # precisely the kind of process failure this loop exists to capture. The
    # dropped record produced no warning, no count and no snapshot line — an
    # UNDER-capture, which is the worst failure this pipeline has, because the
    # backlog reporter can only count what reached a snapshot. Compare only the
    # whole body, with surrounding whitespace trimmed: `-   None observed.  ` is
    # a formatting variant of the sentinel, not a deviation, and no genuine
    # deviation is whitespace plus that phrase and nothing else. Trimming cannot
    # over-match the way the old regex did, because it still compares the ENTIRE
    # body. TC-STL-25 pins both directions.
    function emit(   b) {
      b = buf;
      sub(/^[[:space:]]+/, "", b);
      sub(/[[:space:]]+$/, "", b);
      if (buf == "" || b == "None observed.") { buf=""; return; }
      printf("{\"ts\":\"%s\",\"phase\":\"%s\",\"body\":\"%s\"}\n",
        ts, json_escape(phase), json_escape(buf));
      buf="";
    }
    # A new h2 phase block ENDS the Deviations section of the block before it.
    # NOTE: no apostrophes anywhere in this awk program — it is wrapped in a
    # single-quoted shell string, so one apostrophe silently truncates it.
    # inside=0 here is load-bearing: without it, entering the Deviations
    # section of ANY phase left the flag set for the rest of the file, so every
    # plain `- ` bullet that a LATER `## ` block opens with (phase-card
    # metadata: which agent ran, the Jira n/a line, the PR link) was captured
    # as a deviation. Measured: roughly half the 21 records in
    # pending-deviations-122.log were metadata, not deviations, and they
    # crowded the real ones out of the triage surface. The `if (buf) emit()`
    # still flushes a deviation left pending when the block ends. TC-STL-25
    # pins this.
    /^## / { if (buf) emit(); inside=0; phase=substr($0, 4) }
    /^### Deviations/ { if (buf) emit(); inside=1; next }
    /^### / { if (buf) emit(); inside=0 }
    inside && /^- / { if (buf) emit(); buf=substr($0, 3) }
    inside && /^  [^ ]/ && buf { buf=buf "\n" $0 }   # indented continuation
    inside && /^$/ { if (buf) emit() }
    END { if (buf) emit() }
  ' "$SNAPSHOT_NUL_FREE" > "$SNAPSHOT_FILE_POST_MERGE.tmp"
  AWK_RC=$?
  rm -f "$SNAPSHOT_NUL_FREE"
  fi

  # ⛔ ATOMIC WRITE + WRITE-FAILURE GUARD ⛔ — awk writes to a .tmp scratch file,
  # never directly to the path the reader (/review-pr Step 0.5) consumes. Then:
  #   - awk FAILED (unwritable/missing ~/.claude, disk full, mid-stream error):
  #     rm the (possibly truncated) .tmp and WARN. The reader never sees a
  #     partial/garbled snapshot, and the failure is surfaced rather than
  #     silently treated as "no deviations" (automated-review findings, PR #127).
  #   - awk SUCCEEDED + non-empty: mv the .tmp into place atomically — a reader
  #     can never observe a half-written snapshot.
  #   - awk SUCCEEDED + empty: genuinely no deviations → rm the empty .tmp.
  if [[ "$AWK_RC" -ne 0 ]]; then
    rm -f "$SNAPSHOT_FILE_POST_MERGE.tmp"
    echo "WARN: deviation snapshot write FAILED (awk exit $AWK_RC) for PR #$PR_NUMBER — ~/.claude may be unwritable or the disk full. Deviations for this merge were NOT captured (no partial file left behind); investigate rather than assume none existed." >&2
  elif [[ -s "$SNAPSHOT_FILE_POST_MERGE.tmp" ]]; then
    if mv -f "$SNAPSHOT_FILE_POST_MERGE.tmp" "$SNAPSHOT_FILE_POST_MERGE" 2>/dev/null; then
      echo "Snapshotted $(wc -l < "$SNAPSHOT_FILE_POST_MERGE" | tr -d ' ') deviation(s) to $SNAPSHOT_FILE_POST_MERGE for post-merge triage."
    else
      # mv failed — clean up ONLY our own .tmp. Do NOT touch the real snapshot
      # path: the idempotency guard at the top of this block already returned
      # early whenever a non-empty real snapshot exists, so reaching here means
      # THIS invocation is not responsible for any real file present — and a real
      # file could only have appeared via a CONCURRENT fold run for the same PR
      # (between that guard and here). Unconditionally rm-ing it would delete
      # that concurrent run's valid snapshot (automated-review finding, PR #127). Leaving
      # it is safe: cross-PR staleness is impossible (per-PR filename), and any
      # real file present is the other run's correct capture.
      rm -f "$SNAPSHOT_FILE_POST_MERGE.tmp"
      echo "WARN: could not move the deviation snapshot into place for PR #$PR_NUMBER (mv failed) — nothing captured; investigate." >&2
    fi
  else
    # awk succeeded + empty → genuinely no deviations. Clean up ONLY our own
    # .tmp; do NOT touch the real snapshot path (same reasoning as the mv-fail
    # branch above — the idempotency guard means we only get here when no
    # non-empty real snapshot existed at check time, so any real file present is
    # a concurrent fold's valid capture, not stale data to clear). automated-review PR #127.
    rm -f "$SNAPSHOT_FILE_POST_MERGE.tmp"
  fi
fi

# --- Post-merge: Fold review capture files into pending-lessons snapshot ---
# Combines the automated-review JSONL capture file (written in /review-pr Step 4) and
# the Codex learnings file (written by skills/codex-review/SKILL.md Step 4)
# into a single pending-lessons file. /review-pr Step 0.5 MERGED reads this
# file to run the AI+Codex consensus and propose the learned-lessons PR.
#
# ⛔ SYMLINK DEFENSE ⛔ — same pattern as deviation snapshot above.
#
# WHY branch-keyed Codex file (not SHA-keyed): codex-review writes the
# capture file BEFORE the PR is opened, keyed by the sanitized feature-branch
# name. At merge time HEAD points at main (or the merge commit), not the
# feature branch — so a SHA-keyed lookup would NEVER find the file written
# pre-PR. Resolving the branch name via `gh pr view --json headRefName` at
# merge time recovers the stable key that was used at write time. The automated-review
# capture is keyed by PR_NUMBER (written during review, PR is already open) —
# no change needed for that file.
#
# ⛔ SHARED SANITIZER CONTRACT ⛔ — the automated-review capture filename MUST be
# recomputed here byte-identically to the WRITER in commands/review-pr.md
# Step 4 (search "FILENAME-CONTRACT"). Earlier this fold used the RAW
# ${OWNER}/${REPO_NAME} while the writer used SANITIZED identifiers, so the
# two filenames never matched and every automated-review capture was silently dropped
# instead of folded into pending-lessons. Both sites now sanitize with
# `printf '%s'` (NOT `echo`, which appends a '\n' that `tr -c` turns into a
# trailing '_').
#
# ⛔ SAFE_PR_BRANCH sanitizer contract ⛔ — this MUST also stay byte-identical
# to skills/codex-review/SKILL.md's SAFE_BRANCH (search "SHARED SANITIZER
# CONTRACT" there), or the post-merge read computes a different filename and
# silently drops every Codex capture.
SAFE_OWNER=$(printf '%s' "$OWNER" | tr -c 'A-Za-z0-9._-' '_')
SAFE_REPO_NAME=$(printf '%s' "$REPO_NAME" | tr -c 'A-Za-z0-9._-' '_')
LEARNINGS_FILE="$HOME/.claude/.pr-learnings-${SAFE_OWNER}-${SAFE_REPO_NAME}-${PR_NUMBER}.jsonl"
# $PR_HEAD_REF comes from the ONE metadata read at the top of this script (it
# used to be fetched again right here). Same value, same failure mode: an
# unreachable `gh` leaves it empty and SAFE_PR_BRANCH empty with it, which is the
# pre-existing behaviour — an empty branch key simply finds no Codex capture.
# Codex branch-key sanitizer: MUST match skills/codex-review/SKILL.md byte-for-byte.
# `printf '%s'` (NOT `echo`) for the same trailing-'_' reason as above.
SAFE_PR_BRANCH=$(printf '%s' "$PR_HEAD_REF" | tr -c 'A-Za-z0-9._-' '_')
CODEX_LEARNINGS_FILE="$HOME/.claude/.codex-learnings-${SAFE_PR_BRANCH}.jsonl"
PENDING_LESSONS_FILE="$HOME/.claude/pending-lessons-${PR_NUMBER}.jsonl"
if [[ -L "$LEARNINGS_FILE" || -L "$CODEX_LEARNINGS_FILE" || -L "$PENDING_LESSONS_FILE" ]]; then
  echo "Skipping lessons fold: a capture file or pending-lessons file is a symlink." >&2
else
  # Combine: cat both files (whichever exist) into the pending snapshot.
  # Use >> so a partially written file from a previous interrupted run is
  # extended, not replaced (idempotent at the record level since Step 0.5
  # deduplicates by hash).
  # Only delete the source AFTER a SUCCESSFUL append. Previously the append
  # swallowed errors (|| true) and then unconditionally rm'd the source — a
  # permission/full-disk/bad-path failure would lose the captured findings
  # permanently. Gate the rm on the append's exit status; warn + preserve on failure.
  if [[ -f "$LEARNINGS_FILE" && -s "$LEARNINGS_FILE" ]]; then
    if cat "$LEARNINGS_FILE" >> "$PENDING_LESSONS_FILE" 2>/dev/null; then
      rm -f "$LEARNINGS_FILE"  # consumed — clean up only on successful fold
    else
      echo "WARN: could not fold $LEARNINGS_FILE into $PENDING_LESSONS_FILE — preserving capture file." >&2
    fi
  fi
  if [[ -f "$CODEX_LEARNINGS_FILE" && -s "$CODEX_LEARNINGS_FILE" ]]; then
    if cat "$CODEX_LEARNINGS_FILE" >> "$PENDING_LESSONS_FILE" 2>/dev/null; then
      rm -f "$CODEX_LEARNINGS_FILE"  # consumed — clean up only on successful fold
    else
      echo "WARN: could not fold $CODEX_LEARNINGS_FILE into $PENDING_LESSONS_FILE — preserving capture file." >&2
    fi
  fi
  if [[ -f "$PENDING_LESSONS_FILE" && -s "$PENDING_LESSONS_FILE" ]]; then
    echo "Folded $(wc -l < "$PENDING_LESSONS_FILE" | tr -d ' ') capture record(s) into $PENDING_LESSONS_FILE for post-merge lessons triage."
  fi
fi

# --- Post-merge Jira transition: SKIPPED (repo-based, ticketless toolbox) ---
# This script only ever reaches here for ai-engineering (gated above). The
# toolbox is ticketless by REPO (PR #95 exception): no Jira board, no ticket —
# so there is nothing to transition, REGARDLESS of branch name. A toolbox
# branch named with a [A-Z]+-[0-9]+ Jira-style token must NOT trigger a
# transition against a board that does not exist (automated-review finding, PR #95).
echo "Post-merge: ai-engineering toolbox is ticketless (no Jira board) — no ready_for_release/Done transition. Deviation snapshot handled above."

exit 0
