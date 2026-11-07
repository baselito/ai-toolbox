#!/bin/bash
# review-pr-precheck.sh — Deterministic pre-check for /review-pr auto-poll cron fires.
#
# WHY THIS EXISTS:
#   Step 0.7 of commands/review-pr.md decides — on each auto-poll (--auto) cron fire —
#   whether to run the full comment-processing pipeline. Before this script existed,
#   that logic lived as agent-interpreted PROSE. After a context compaction, the agent
#   ran a simplified pre-check that only evaluated the merge-gate condition (b) and
#   DROPPED condition (a) — so new reviewer comments sat unprocessed for the life of
#   the cron. Moving the logic here makes it deterministic and immune to compaction.
#
# USAGE:
#   bash scripts/review-pr-precheck.sh <owner/repo> <pr-number>
#
# OUTPUT (stdout):
#   PROCESS          — full pipeline must run (new comments or merge gate might pass)
#   SKIP: <reason>   — no action needed this fire
#   STOP: <reason>   — the unchanged blocked state reached the no-progress threshold
#
# EXIT CODE: always 0 (caller inspects the first word of stdout, not the exit code).
#
# FAIL-OPEN DESIGN:
#   On ANY error (gh failure, jq missing, parse error, network timeout), this script
#   prints PROCESS. The harmful outcome is SKIPPING new comments — the opposite of
#   the hooks' fail-closed stance. An unnecessary full-pipeline run wastes a little
#   compute; a skipped reviewer comment wastes the reviewer's effort and delays the PR.
#
# COUNT FILE:
#   Path: ~/.claude/.pr-<owner>-<repo>-<N>-count (composite key — matches Step 0.1)
#   Metric: ISSUE_COUNT (paginated REST) + REVIEW_COUNT + INLINE_COUNT (paginated REST)
#   — matches Step 0.7/Step 1 of commands/review-pr.md exactly. Issue and inline
#   comments are counted via paginated REST endpoints; ONLY reviews come from
#   `gh pr view --json reviews` (GraphQL, capped at 100 — documented limitation,
#   same on both sides). Both sides of the comparison use the same metric; a stored
#   value from a previous full pipeline run is directly comparable to the current
#   fetched value.

set -uo pipefail

# This script may run from an arbitrary project checkout. Use fixed system
# helper locations so a checkout-controlled PATH cannot forge a SKIP decision.
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/snap/bin"
export PATH

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <owner/repo> <pr-number>" >&2
  # Fail-open: if caller omitted args, something is wrong upstream — run the pipeline.
  echo "PROCESS"
  exit 0
fi

OWNER_REPO="$1"
PR_NUMBER="$2"

# Validate format: owner/repo must contain exactly one slash.
if ! printf '%s' "$OWNER_REPO" | grep -qE '^[^/]+/[^/]+$'; then
  echo "review-pr-precheck: invalid repo format '$OWNER_REPO' (expected owner/repo)" >&2
  # Fail-open.
  echo "PROCESS"
  exit 0
fi

# Validate PR number is a positive integer.
if ! printf '%s' "$PR_NUMBER" | grep -qE '^[0-9]+$' || [[ "$PR_NUMBER" -eq 0 ]]; then
  echo "review-pr-precheck: invalid PR number '$PR_NUMBER'" >&2
  # Fail-open.
  echo "PROCESS"
  exit 0
fi

# Derive OWNER and REPO_NAME for the composite count file key (matches Step 0.1).
OWNER=$(printf '%s' "$OWNER_REPO" | cut -d/ -f1)
REPO_NAME=$(printf '%s' "$OWNER_REPO" | cut -d/ -f2)

# Guard HOME before using it — cron/non-login environments may not set HOME,
# and set -u would abort with an unbound-variable error (violating fail-open).
HOME_DIR="${HOME:-}"
if [[ -z "$HOME_DIR" ]]; then
  echo "review-pr-precheck: HOME not set — cannot locate count file; fail-open → PROCESS" >&2
  echo "PROCESS"
  exit 0
fi

# Resolve gh from trusted fixed locations only. A successful PATH shim can
# forge the PR metadata and make this optimization emit SKIP, which is the
# opposite of this script's fail-open contract. The per-user ~/.local/bin
# location is accepted because it is the user's native install area, not the
# current checkout or another project-controlled directory.
resolve_gh() {
  local candidate
  for candidate in \
    "$HOME_DIR/.local/bin/gh" \
    "/opt/homebrew/bin/gh" \
    "/usr/local/bin/gh" \
    "/usr/bin/gh" \
    "/snap/bin/gh"; do
    if [[ -x "$candidate" && ! -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}
GH_BIN="$(resolve_gh || true)"
if [[ -z "$GH_BIN" ]]; then
  echo "review-pr-precheck: no trusted gh installation found — fail-open → PROCESS" >&2
  echo "PROCESS"
  exit 0
fi

# Count file path: must match the composite key used in Step 0.1 of review-pr.md.
# Pattern: ~/.claude/.pr-${OWNER}-${REPO_NAME}-${PR_NUMBER}-count
COUNT_FILE="$HOME_DIR/.claude/.pr-${OWNER}-${REPO_NAME}-${PR_NUMBER}-count"

# ---------------------------------------------------------------------------
# Dependency check — jq
# ---------------------------------------------------------------------------
# Fail-open: if jq is missing, we can't parse the gh JSON response.
if ! command -v jq >/dev/null 2>&1; then
  echo "review-pr-precheck: jq not found — cannot parse gh output; fail-open → PROCESS" >&2
  echo "PROCESS"
  exit 0
fi

# ---------------------------------------------------------------------------
# Read the stored comment count from the previous full pipeline run.
# Default 0 if the file doesn't exist (first run or count file was cleaned up).
# ---------------------------------------------------------------------------
LAST_COUNT=0
if [[ -f "$COUNT_FILE" ]]; then
  # Read and sanitise: strip whitespace, ensure it's a non-negative integer.
  RAW=$(cat "$COUNT_FILE" 2>/dev/null | tr -d '[:space:]')
  if printf '%s' "$RAW" | grep -qE '^[0-9]+$'; then
    LAST_COUNT="$RAW"
  fi
  # If the file exists but holds garbage, treat as 0 (fail-open via LAST_COUNT=0
  # will trigger PROCESS on any non-zero count, which is the safe direction).
fi

# ---------------------------------------------------------------------------
# Fetch current PR state + comment counts.
# Uses the same gh commands as Step 0.7 of review-pr.md to ensure the metric
# is identical on both sides of the comparison.
# ---------------------------------------------------------------------------

# Single gh pr view call fetches all fields we need:
#   - reviews for REVIEW_COUNT (GraphQL, capped at 100 — documented limitation,
#     same cap on the writer side in Step 1; the fix if ever hit is the paginated
#     REST reviews endpoint)
#   - mergeStateStatus for the merge-gate check
#   - reviewDecision for the merge-gate check
#   - state to verify the PR is still open
#   - statusCheckRollup for the automated-review-recovery override (Finding C, below)
#
# ⛔ Issue comments are deliberately NOT counted from this call. `gh pr view
# --json comments` is GraphQL-backed and capped at 100 entries exactly like
# reviews — counting from it reproduces the "comments beyond a cap are silently
# dropped" failure class (Codex P1). Issue comments are counted below via the
# PAGINATED REST endpoint, mirroring the inline-comments fetch.
#
# The --repo flag ensures this always targets the correct repository regardless
# of the cwd from which the cron fires (mirrors Step 0.1's REPO_FLAG pattern).
PR_META=$("$GH_BIN" pr view "$PR_NUMBER" --repo "$OWNER_REPO" \
  --json reviews,mergeStateStatus,reviewDecision,state,statusCheckRollup 2>&1)
GH_EXIT=$?

if [[ $GH_EXIT -ne 0 ]]; then
  # gh failed (auth error, network timeout, PR not found, etc.) — fail-open.
  echo "review-pr-precheck: gh pr view failed (exit $GH_EXIT): $PR_META" >&2
  echo "PROCESS"
  exit 0
fi

# Parse REVIEW_COUNT: length(reviews). Matches Step 0.7/Step 1 of review-pr.md.
REVIEW_COUNT=$(printf '%s' "$PR_META" | jq -r '.reviews | length' 2>/dev/null)
if ! printf '%s' "$REVIEW_COUNT" | grep -qE '^[0-9]+$'; then
  echo "review-pr-precheck: could not parse review count from gh output" >&2
  echo "PROCESS"
  exit 0
fi

# Fetch issue (top-level) comment count — paginated REST, NOT the capped
# GraphQL field (see the ⛔ note above). Same fail-open discipline as the
# inline fetch below: capture the exit code BEFORE the awk pipe.
ISSUE_RAW=$("$GH_BIN" api "repos/$OWNER_REPO/issues/$PR_NUMBER/comments" --paginate --jq 'length' 2>/dev/null)
ISSUE_GH_EXIT=$?
if [[ $ISSUE_GH_EXIT -ne 0 ]]; then
  echo "review-pr-precheck: gh api issue comments failed (exit $ISSUE_GH_EXIT) — fail-open" >&2
  echo "PROCESS"
  exit 0
fi
# The awk sums across pages (each page returns a JSON array; jq emits one length per page).
ISSUE_COUNT=$(printf '%s' "$ISSUE_RAW" | awk '{s+=$1} END {print s+0}')
if ! printf '%s' "$ISSUE_COUNT" | grep -qE '^[0-9]+$'; then
  echo "review-pr-precheck: could not parse issue comment count — fail-open" >&2
  echo "PROCESS"
  exit 0
fi

# Fetch inline review comment count — separate API call, paginated.
# Mirrors Step 0.7's: gh api "repos/$OWNER_REPO/pulls/$PR_NUMBER/comments" --paginate
# ⛔ FAIL-OPEN: capture gh's exit code BEFORE the awk pipe. Without this, a failed
# `gh api` (rate limit / transient REST outage on the pulls/comments endpoint) is
# masked — awk still prints "0", which passes the integer guard below, silently
# undercounts, and can emit SKIP while new inline comments wait. That is the exact
# fail-CLOSED bug this script exists to prevent. (code-review HIGH finding)
INLINE_RAW=$("$GH_BIN" api "repos/$OWNER_REPO/pulls/$PR_NUMBER/comments" --paginate --jq 'length' 2>/dev/null)
INLINE_GH_EXIT=$?
if [[ $INLINE_GH_EXIT -ne 0 ]]; then
  echo "review-pr-precheck: gh api inline comments failed (exit $INLINE_GH_EXIT) — fail-open" >&2
  echo "PROCESS"
  exit 0
fi
# The awk sums across pages (each page returns a JSON array; jq emits one length per page).
INLINE_COUNT=$(printf '%s' "$INLINE_RAW" | awk '{s+=$1} END {print s+0}')
if ! printf '%s' "$INLINE_COUNT" | grep -qE '^[0-9]+$'; then
  echo "review-pr-precheck: could not parse inline comment count — fail-open" >&2
  echo "PROCESS"
  exit 0
fi

# Total current count: matches Step 0.7's CURRENT_COMMENT_COUNT.
CURRENT_COMMENT_COUNT=$(( ISSUE_COUNT + REVIEW_COUNT + INLINE_COUNT ))

# Parse merge-gate fields.
# NOTE the reviewDecision normalization: on a PR with no reviews yet, GitHub
# returns reviewDecision as the EMPTY STRING — and jq's `//` treats "" as
# truthy (only null/false are falsy), so `// "PENDING"` alone passes "" through
# and the [[ -z ]] parse guard below misfires, fail-opening EVERY cron fire on
# a review-less PR (observed live on PR #105's first fire). Map "" → PENDING
# explicitly; "" is not CHANGES_REQUESTED, so gate semantics are unchanged.
MERGE_STATE=$(printf '%s' "$PR_META" | jq -r '.mergeStateStatus // "UNKNOWN"' 2>/dev/null)
REVIEW_DECISION=$(printf '%s' "$PR_META" \
  | jq -r '(.reviewDecision // "PENDING") | if . == "" then "PENDING" else . end' 2>/dev/null)
PR_STATE=$(printf '%s' "$PR_META" | jq -r '.state // "UNKNOWN"' 2>/dev/null)

if [[ -z "$MERGE_STATE" || -z "$REVIEW_DECISION" || -z "$PR_STATE" ]]; then
  echo "review-pr-precheck: could not parse PR state fields from gh output" >&2
  echo "PROCESS"
  exit 0
fi

# ---------------------------------------------------------------------------
# Automated review-recovery override (Finding C).
#
# WHY: Step 5.4 of commands/review-pr.md re-triggers a FAILED automated-review check
# (transient auth/infra error, e.g. "Token revoked") a bounded number of
# times. A failed required automated-review check makes mergeStateStatus BLOCKED —
# which is neither CLEAN nor UNSTABLE, so the ordinary MERGE_GATE_MIGHT_PASS
# check below is always false for it. Before this override, a BLOCKED PR with
# no new comments always got SKIP from this precheck, so the full pipeline
# (and therefore Step 5.4's recovery) never ran — the failed check sat
# unrecovered until the 1-day auto-poll cap gave up.
#
# This reuses the SAME grouping semantics as Step 5.4's S54_LATEST and
# hooks/pr-action-safety.sh's MERGE-GATE-DEDUPE-JQ block (group by
# [__typename, name/context, workflowName, detailsUrl/targetUrl origin]; any
# in-flight entry blocks its group; otherwise resolve on the entries sharing
# the maximum timestamp — ties fail-closed), scoped STRICTLY to checks whose
# name starts with "automated-review" (case-insensitive) so a genuine non-automated-review CI
# failure is never auto-recovered by this override — it still correctly SKIPs
# via the ordinary logic and Step 5.4 never re-triggers non-automated-review checks.
#
# Fail-open: if jq errors on this expression for any reason, REVIEWER_FAILED
# stays 0 (via the `// 0` fallback) and the override simply does not fire —
# the script still falls through to the ordinary comment/merge-gate logic
# rather than crashing, consistent with this script's fail-open design.
#
# NOTE — deliberate divergence from the merge-gate dedupe transform (hooks/
# pr-action-safety.sh + review-pr.md Steps 5.4/5.5): those DROP "" (empty
# conclusion+state) from the in-flight set so a stale SUPERSEDED empty entry
# can't block the merge gate forever (PR #130). Here "" IS kept in-flight ON
# PURPOSE: this detector answers a different question — "is a automated-review check
# failed-TERMINAL so Step 5.4 should re-trigger it?" — and a status-less newest
# entry means "still in flight, wait", NOT "failed", so we must not trip
# recovery on it (TC-PCP-19b). This is the cost-optimization precheck (fail-open
# to PROCESS); its edge cases only change how often the full pipeline runs, never
# a merge or recovery decision — those are re-evaluated in the full pipeline.
# ---------------------------------------------------------------------------
REVIEWER_FAILED=$(printf '%s' "$PR_META" | jq '[ (.statusCheckRollup // [])
    | map(select(((.name // .context // "")|ascii_downcase|startswith("automated-review"))))
    | group_by([(.__typename // ""), (.name // .context // "unknown"), (.workflowName // ""),
                ((.detailsUrl // .targetUrl // "") | split("/")[0:3] | join("/"))])[]
    | (map(select((.conclusion // .state // "") as $c
          | $c=="" or $c=="PENDING" or $c=="IN_PROGRESS" or $c=="QUEUED" or $c=="EXPECTED")) | length) as $inflight
    | (max_by(.startedAt // .completedAt // .createdAt // "") | (.startedAt // .completedAt // .createdAt // "")) as $maxk
    | select($inflight == 0)
    | select([ .[] | select((.startedAt // .completedAt // .createdAt // "") == $maxk)
                   | select((.conclusion // .state // "") as $c
                       | $c != "SUCCESS" and $c != "SKIPPED" and $c != "NEUTRAL") ] | length > 0)
  ] | length' 2>/dev/null)
[[ "$REVIEWER_FAILED" =~ ^[0-9]+$ ]] || REVIEWER_FAILED=0

# ---------------------------------------------------------------------------
# Decision logic — mirrors Step 0.7 exactly.
#
# Three reasons to run the full pipeline:
#   (a) New comments: count increased since the last stored count.
#   (b) Merge gate MIGHT be ready: PR is OPEN, mergeStateStatus is CLEAN or
#       UNSTABLE, and reviewDecision is not CHANGES_REQUESTED.
#       Even with no new comments, CI can complete or a human can approve,
#       changing merge readiness without adding a comment. Step 5.5 must fire.
#   (c) A automated-review check is failed-terminal (see override above) — Step 5.4's
#       recovery needs the fire to let it re-trigger the check.
# ---------------------------------------------------------------------------

HAS_NEW_COMMENTS=false
if [[ "$CURRENT_COMMENT_COUNT" -gt "$LAST_COUNT" ]]; then
  HAS_NEW_COMMENTS=true
fi

MERGE_GATE_MIGHT_PASS=false
if [[ "$PR_STATE" == "OPEN" ]] \
   && { [[ "$MERGE_STATE" == "CLEAN" ]] || [[ "$MERGE_STATE" == "UNSTABLE" ]]; } \
   && [[ "$REVIEW_DECISION" != "CHANGES_REQUESTED" ]]; then
  MERGE_GATE_MIGHT_PASS=true
fi

REVIEWER_NEEDS_RECOVERY=false
if [[ "$PR_STATE" == "OPEN" && "$REVIEWER_FAILED" -gt 0 ]]; then
  REVIEWER_NEEDS_RECOVERY=true
fi

# ---------------------------------------------------------------------------
# No-progress checkpoint for fires that would otherwise be SKIP.
#
# The full /review-pr command has a richer checkpoint after it counts review
# threads. That checkpoint cannot run when this precheck returns SKIP, though,
# which used to let an unchanged blocked PR consume the entire auto-poll cap.
# Run the same deterministic detector here before emitting SKIP. Fires that
# process comments, automated-review recovery, or a potentially-ready gate continue to
# the full command and use its richer checkpoint instead.
# ---------------------------------------------------------------------------
run_skip_progress_guard() {
  local state_root progress_script progress_state stalled_file threshold
  local failing_gate progress_output progress_rc

  state_root="${CLAUDE_STATE_DIR:-$HOME_DIR/.claude}"
  # This is an optimization guard, so an unusable state root must fail open to
  # PROCESS. Never let a relative or missing root become a writable target.
  if [[ "$state_root" != /* || ! -d "$state_root" || ! -r "$state_root" || ! -x "$state_root" ]]; then
    echo "review-pr-precheck: progress state root is not a usable absolute directory — fail-open → PROCESS" >&2
    return 4
  fi

  # The helper is installed by the toolbox, so caller-controlled CLAUDE_HOME or
  # APPDATA must never be allowed to select executable review logic. The
  # installed helper lives in the user's home state root on macOS/Linux, or in
  # the standard home-relative Windows roaming path.
  progress_script=""
  case "${CLAUDE_PLATFORM:-$(/usr/bin/uname -s 2>/dev/null || echo unknown)}" in
    MINGW*|MSYS*|CYGWIN*|windows)
      progress_candidates=(
        "$HOME_DIR/AppData/Roaming/Claude/scripts/loop-progress-signature.sh"
        "$HOME_DIR/.claude/scripts/loop-progress-signature.sh"
      )
      ;;
    *)
      progress_candidates=(
        "$HOME_DIR/.claude/scripts/loop-progress-signature.sh"
        "$HOME_DIR/AppData/Roaming/Claude/scripts/loop-progress-signature.sh"
      )
      ;;
  esac
  for progress_candidate in "${progress_candidates[@]}"; do
    if [[ -f "$progress_candidate" ]]; then
      progress_script="$progress_candidate"
      break
    fi
  done
  if [[ -z "$progress_script" ]]; then
    echo "review-pr-precheck: loop-progress-signature.sh is not installed — fail-open → PROCESS" >&2
    return 4
  fi

  # This cron is intentionally cross-repository: its cwd is not a reliable
  # project checkout, so never read a repo-local PROJECT.md here. Interactive
  # loop-launch uses that project config; auto-poll uses this safe system bound.
  threshold=2
  [[ "$threshold" =~ ^[1-5]$ ]] || threshold=2

  progress_state="$state_root/.pr-${OWNER}-${REPO_NAME}-${PR_NUMBER}-loop-progress"
  stalled_file="$state_root/.pr-${OWNER}-${REPO_NAME}-${PR_NUMBER}-loop-stalled"
  if [[ "$PR_STATE" == "OPEN" ]]; then
    if [[ "$REVIEW_DECISION" == "CHANGES_REQUESTED" ]]; then
      failing_gate="review"
    else
      failing_gate="merge-gate"
    fi
  else
    # A merged/closed PR is normally handled by Step 0.5 before this script;
    # do not create a permanent failure signature if that ordering changes.
    failing_gate=""
  fi

  progress_output=$(printf '%s\n' "$PR_META" \
    | bash "$progress_script" --state "$progress_state" \
        --failing-gates "$failing_gate" --threshold "$threshold" --output - 2>&1)
  progress_rc=$?
  if [[ "$progress_rc" -eq 3 ]]; then
    echo "STOP: $progress_output"
    return 3
  elif [[ "$progress_rc" -ne 0 ]]; then
    echo "review-pr-precheck: progress guard failed (exit $progress_rc) — fail-open → PROCESS" >&2
    return 4
  fi

  rm -f "$stalled_file" 2>/dev/null || true
  return 0
}

# Output decision.
if [[ "$HAS_NEW_COMMENTS" == "true" ]]; then
  echo "PROCESS"
elif [[ "$MERGE_GATE_MIGHT_PASS" == "true" ]]; then
  echo "PROCESS"
elif [[ "$REVIEWER_NEEDS_RECOVERY" == "true" ]]; then
  echo "PROCESS"
else
  run_skip_progress_guard
  PROGRESS_RC=$?
  if [[ "$PROGRESS_RC" -eq 3 ]]; then
    exit 0
  elif [[ "$PROGRESS_RC" -ne 0 ]]; then
    echo "PROCESS"
  else
    echo "SKIP: no new comments (current=$CURRENT_COMMENT_COUNT, last=$LAST_COUNT) and merge gate not ready (state=$PR_STATE, mergeStateStatus=$MERGE_STATE, reviewDecision=$REVIEW_DECISION)"
  fi
fi

exit 0
