#!/bin/bash
# workflow-auto-approve.sh
#
# PreToolUse hook that auto-approves operations on toolbox-managed files
# so the user doesn't get prompted every time the agent writes to them.
#
# Covers:
#   Write/Edit on handover file:
#     - .claude/handover.md
#
#   Bash operations on workflow marker files (touch, rm):
#     - ~/.claude/.review-orchestrated (code-review-orchestration skill)
#     - ~/.claude/.pr-skill-invoked (finishing-a-development-branch skill)
#
#   Bash operations on parameterised /review-pr state files (touch, rm, echo > / >>):
#     - ~/.claude/.pr-merge-gate-<owner>-<repo>-<N>   (/merge-pr gate marker)
#     - ~/.claude/.pr-<owner>-<repo>-<N>-cron-id      (saved cron ID for self-termination)
#     - ~/.claude/.pr-<owner>-<repo>-<N>-seen          (processed-comment IDs)
#     - ~/.claude/.pr-<owner>-<repo>-<N>-count         (comment count for pre-check)
#     Legacy patterns (backward compat, will be removed after transition):
#     - ~/.claude/.pr-reviews-seen-<N>
#     - ~/.claude/.pr-<N>-cron-id
#     - ~/.claude/.pr-<N>-repo
#     - ~/.claude/.pr-comment-count-<N>
#
# Why: These files are part of the toolbox workflow mechanism. The agent
# creates/updates them as part of normal operation. Prompting the user
# for each one creates workflow friction. Suffix matching works with any
# repo, cwd, or path format (absolute/relative).
#
# Note: ~/.claude/.push-ready is NOT auto-approved — that one requires
# explicit user approval via AskUserQuestion (push-safety protocol).
#
# Safety rationale for the /review-pr markers:
# - .pr-merge-gate: forging it triggers pr-action-safety's Layer 2 live
#   re-verification via gh, so a forged marker on a non-ready PR is
#   rejected anyway. Auto-approving the create/delete is safe.
# - .pr-<owner>-<repo>-<N>-seen (and legacy .pr-reviews-seen-<N>): append-only
#   log of already-processed comment IDs. Worst case a forgery hides a comment;
#   doesn't enable any action.
# - .pr-<owner>-<repo>-<N>-cron-id (and legacy .pr-<N>-cron-id): just stores
#   a cron ID string. Forged ID passed to CronDelete is a no-op on an invalid
#   ID. No security impact.
# - .pr-<owner>-<repo>-<N>-count (and legacy .pr-comment-count-<N>): stores a
#   comment count integer for pre-check optimization. No security impact.

set -euo pipefail

# Guard: ensure jq is available
if ! command -v jq &>/dev/null; then
  exit 0
fi

# Read hook input from stdin
HOOK_DATA=$(cat)

TOOL_NAME=$(echo "$HOOK_DATA" | jq -r '.tool_name // empty')

# ---------------------------------------------------------------------
# Write/Edit: auto-approve handover files
# ---------------------------------------------------------------------
if [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]]; then
  FILE_PATH=$(echo "$HOOK_DATA" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")

  if [[ -n "$FILE_PATH" ]]; then
    # Handover file — append-only narrative record written by the orchestrator
    HANDOVER_FILES=(
      ".claude/handover.md"
    )

    for handover in "${HANDOVER_FILES[@]}"; do
      if [[ "$FILE_PATH" == *"$handover" ]]; then
        jq -n '{
          "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": "Auto-approved: handover file (toolbox workflow mechanism)."
          }
        }'
        exit 0
      fi
    done

    # Content-bearing marker files — the compliance audit subagent writes
    # its full report to this file (not just touch). The enforce-compliance-audit
    # hook now requires content with an "AUDIT COMPLETE:" signature line.
    # Matches both ~/.claude/ and $HOME/.claude/ absolute paths.
    CONTENT_MARKER_FILES=(
      ".claude/.audit-complete"
    )

    for marker in "${CONTENT_MARKER_FILES[@]}"; do
      if [[ "$FILE_PATH" == *"$marker" ]]; then
        jq -n '{
          "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": "Auto-approved: content-bearing workflow marker (audit subagent writes findings here)."
          }
        }'
        exit 0
      fi
    done
  fi

  # Not a handover file — fall through to normal permission check
  exit 0
fi

# ---------------------------------------------------------------------
# Bash: auto-approve touch/rm on workflow marker files
# ---------------------------------------------------------------------
if [[ "$TOOL_NAME" == "Bash" ]]; then
  COMMAND=$(echo "$HOOK_DATA" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")

  if [[ -z "$COMMAND" ]]; then
    exit 0
  fi

  # FAST PATH — skip ~15 grep forks for commands that cannot possibly match.
  #
  # Every auto-approve pattern below (marker touch/rm, the review-pr state files,
  # the `cat > .audit-complete` form, and the echo>/echo>> forms) requires the
  # literal substring `.claude` in the command: each is anchored on
  # ANY_CLAUDE_PREFIX, which ends in `\.claude`. So "command contains .claude" is
  # a NECESSARY condition for every branch — a command without it can never be
  # auto-approved, and falling through here reaches the same `exit 0` (defer to
  # the normal permission check) that a no-match would.
  #
  # WHY it matters: this hook runs on EVERY Bash tool call. Each `grep -qE` is a
  # fork+exec (~6 ms), and a benign command like `ls -la` was paying for all of
  # them — measured 101 ms, a third of the entire 10-hook PreToolUse chain. The
  # test below is a bash builtin, so it forks nothing.
  #
  # This is a pure short-circuit: it can only skip work that was guaranteed to
  # find no match. It never widens what gets auto-approved.
  if [[ "$COMMAND" != *".claude"* ]]; then
    exit 0
  fi

  # Workflow marker files (not .push-ready — that one requires explicit user approval).
  # State files now live in ~/.claude/ (home directory, outside any repo) to
  # avoid worktree and gitignore issues. Match both ~/.claude/ and $HOME/.claude/
  # expansions in commands.
  #
  # ANY_CLAUDE_PREFIX matches any path ending in /.claude — handles:
  #   ~/.claude/         (tilde form)
  #   $HOME/.claude/     (env var form — unexpanded in command text)
  #   /Users/x/.claude/  (fully expanded absolute path)
  #   .claude/           (legacy relative form — backward compat)
  #
  # ⛔ PATH_SAFE excludes shell metacharacters — only safe path chars
  # allowed. This prevents command substitution ($(), backticks), glob
  # expansion, and other shell tricks from being auto-approved.
  PATH_SAFE='[A-Za-z0-9._/~$-]'
  ANY_CLAUDE_PREFIX="(${PATH_SAFE}*/)?\.claude"

  MARKER_SUFFIXES=(
    ".review-orchestrated"
    ".pr-skill-invoked"
    ".audit-complete"
    ".skill-delegation-token"
    # NOTE: .push-ready is deliberately ABSENT from this list.
    # It gates git push, which has no second control — push-safety.sh allows
    # a push purely on the token existing. Auto-approving the touch would let
    # an agent forge the push token silently, bypassing the AskUserQuestion
    # approval gate. The legitimate compound form
    #   touch ~/.claude/.push-ready && git push -u origin HEAD
    # does not match this hook's $-anchored single-op regex (the && tail
    # breaks the anchor), so it falls through correctly to push-safety.sh
    # CHECK 0.5 which recognises the compound pattern explicitly.
    ".jira-delegation-token"
  )

  # Auto-approve heredoc content writes to .audit-complete.
  # The audit subagent uses `cat > ~/.claude/.audit-complete <<EOF ... EOF`
  # to write its findings. This is the Bash-tool equivalent of Write.
  # All detectors below match with here-strings (`<<<`), never `echo | grep`:
  # under `set -euo pipefail` the pipe form can SIGPIPE (141) on large multiline
  # input and make a legit auto-approve fall through to a manual prompt — and
  # the idiom is banned file-wide so a future deny-side detector cannot inherit
  # the vulnerable form (static guard: TC-WAA-27).
  if grep -qE "^cat[[:space:]]+>[[:space:]]*${ANY_CLAUDE_PREFIX}/\.audit-complete[[:space:]]*(<<|$)" <<< "$COMMAND"; then
    jq -n '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "permissionDecisionReason": "Auto-approved: audit subagent writing findings to .audit-complete."
      }
    }'
    exit 0
  fi

  # Check if the command is a simple touch/rm/mkdir on a marker file
  # Patterns: "touch ~/.claude/.marker", "rm -f ~/.claude/.marker", "mkdir -p ~/.claude && touch ..."
  for suffix in "${MARKER_SUFFIXES[@]}"; do
    # Match touch on the marker (with optional mkdir prefix)
    if grep -qE "^(mkdir -p ${PATH_SAFE}+ && )?touch[[:space:]]+${ANY_CLAUDE_PREFIX}/${suffix}[[:space:]]*$" <<< "$COMMAND"; then
      jq -n '{
        "hookSpecificOutput": {
          "hookEventName": "PreToolUse",
          "permissionDecision": "allow",
          "permissionDecisionReason": "Auto-approved: workflow marker file (toolbox hook mechanism)."
        }
      }'
      exit 0
    fi

    # Match rm -f on the marker
    if grep -qE "^rm[[:space:]]+(-f[[:space:]]+)?${ANY_CLAUDE_PREFIX}/${suffix}[[:space:]]*$" <<< "$COMMAND"; then
      jq -n '{
        "hookSpecificOutput": {
          "hookEventName": "PreToolUse",
          "permissionDecision": "allow",
          "permissionDecisionReason": "Auto-approved: workflow marker cleanup (toolbox hook mechanism)."
        }
      }'
      exit 0
    fi
  done

  # ---------------------------------------------------------------------
  # Parameterised /review-pr markers — created per PR, so we match by
  # pattern instead of literal name.
  #
  # Matched marker-name patterns (inside .claude/):
  #   Composite keys (current):
  #     .pr-merge-gate-<owner>-<repo>-<N>
  #     .pr-<owner>-<repo>-<N>-cron-id
  #     .pr-<owner>-<repo>-<N>-seen
  #     .pr-<owner>-<repo>-<N>-count
  #   Legacy keys (backward compat):
  #     .pr-reviews-seen-<N>
  #     .pr-<N>-cron-id
  #     .pr-<N>-repo
  #     .pr-comment-count-<N>
  #
  # Matched commands (single-op only — no shell chaining):
  #   touch  .claude/<marker>                     (with optional mkdir prefix)
  #   rm -f  .claude/<marker>
  #   echo  "..."  >   .claude/<marker>           (truncate write — cron ID store)
  #   echo  "..."  >>  .claude/<marker>           (append — seen file)
  # ---------------------------------------------------------------------
  # The marker-name patterns themselves. Uses ANY_CLAUDE_PREFIX (defined above)
  # to match ~/.claude/, $HOME/.claude/, or any absolute path ending in /.claude.
  #
  # Composite: .pr-<owner>-<repo>-<N>-<suffix> where suffix is cron-id|seen|count
  # Composite: .pr-merge-gate-<owner>-<repo>-<N> (merge gate, unchanged)
  # Legacy: .pr-reviews-seen-<N>, .pr-<N>-cron-id, .pr-<N>-repo, .pr-comment-count-<N>
  REVIEW_PR_MARKER_PATTERN="${ANY_CLAUDE_PREFIX}/(\\.pr-merge-gate-[A-Za-z0-9._-]+-[A-Za-z0-9._-]+-[0-9]+|\\.pr-[A-Za-z0-9._-]+-[A-Za-z0-9._-]+-[0-9]+-(cron-id|seen|count)|\\.pr-reviews-seen-[0-9]+|\\.pr-[0-9]+-cron-id|\\.pr-[0-9]+-repo|\\.pr-comment-count-[0-9]+)"

  # Each pattern below uses a STRICT trailing `[[:space:]]*$` and path-safe
  # character class in every prefix/suffix slot. Rules match exactly one
  # single-op invocation per command; any shell metacharacter fails the match.

  # touch (with optional `mkdir -p <path> && ` prefix).
  if grep -qE "^(mkdir -p ${PATH_SAFE}+ && )?touch[[:space:]]+${REVIEW_PR_MARKER_PATTERN}[[:space:]]*\$" <<< "$COMMAND"; then
    jq -n '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "permissionDecisionReason": "Auto-approved: /review-pr parameterised marker (touch) — gate enforced by pr-action-safety live re-verify."
      }
    }'
    exit 0
  fi

  # rm -f on the parameterised marker. `-f` is REQUIRED (not optional) —
  # keeps the allowlist tight to the exact documented form.
  if grep -qE "^rm[[:space:]]+-f[[:space:]]+${REVIEW_PR_MARKER_PATTERN}[[:space:]]*\$" <<< "$COMMAND"; then
    jq -n '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "permissionDecisionReason": "Auto-approved: /review-pr parameterised marker cleanup."
      }
    }'
    exit 0
  fi

  # echo "<token>" >> marker  (append). The echo payload must be a single
  # simple token — alphanumeric + underscore + hyphen, optionally wrapped
  # in matching double or single quotes. No shell metacharacters ($, `,
  # parentheses, braces, etc.) allowed in the payload, which prevents
  # command substitution and other expansion tricks.
  SAFE_TOKEN='("[A-Za-z0-9_-]+"|'"'"'[A-Za-z0-9_-]+'"'"'|[A-Za-z0-9_-]+)'
  if grep -qE "^echo[[:space:]]+${SAFE_TOKEN}[[:space:]]*>>[[:space:]]*${REVIEW_PR_MARKER_PATTERN}[[:space:]]*\$" <<< "$COMMAND"; then
    jq -n '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "permissionDecisionReason": "Auto-approved: /review-pr append to seen-comments marker."
      }
    }'
    exit 0
  fi

  # echo "<token>" > marker  (truncate write — cron-id store). Same
  # SAFE_TOKEN restriction as append. Use `[[:space:]]>` then `[^>]` to
  # ensure it's a single > not a >> (the append case).
  if grep -qE "^echo[[:space:]]+${SAFE_TOKEN}[[:space:]]*>[[:space:]]*${REVIEW_PR_MARKER_PATTERN}[[:space:]]*\$" <<< "$COMMAND"; then
    jq -n '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "permissionDecisionReason": "Auto-approved: /review-pr cron-id store (truncate write)."
      }
    }'
    exit 0
  fi

  # Not a marker file command — fall through to normal permission check
  exit 0
fi

# Other tools — fall through
exit 0
