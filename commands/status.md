---
name: status
description: Surfaces PR-review activity that happened outside the current session — active /review-pr polling crons, recent /review-pr actions from the audit log, and open PRs that may need attention. Scoped to the /review-pr + /loop workflow; does NOT surface general autonomous commits or active development work.
---

# /status — PR Review Activity Snapshot

Solves the "did /review-pr do anything while I wasn't watching?" problem. Cron jobs and `/loop` invocations fire in **separate sessions** — the session you're typing into cannot see them happen in real time. `/status` surfaces that PR-review activity on demand.

**Scope: PR review only.** This command exists to make `/review-pr` polling visible. It does NOT report:
- Commits you made in a prior working session — those are just git history
- Active work in progress on a feature branch — check `git status` or `.claude/handover.md`
- Test runs, build output, or general workflow state

If you're fixing a bug or building a feature, `/status` is usually empty and that is fine. You do not need to act on PR comments while you are mid-fix.

**Read-only. Never modifies state.** Safe to run anytime.

---

## Trigger

- `/status` — full report
- `/status --since 2h` — only activity in the last 2 hours (default: 24h)
- `/status --quiet` — one-line summary suitable for piping or status lines

---

## Workflow

### Step 1 — Active PR-polling scheduled jobs

```
CronList()
```

Show cron jobs whose reason mentions `/review-pr`, `pr-poll`, or a PR number. Other crons (unrelated scheduled tasks) are ignored — they are not PR-review activity. If none: "No active PR-polling jobs."

### Step 2 — Recent /review-pr actions

```bash
LOG="$HOME/.claude/pr-review-actions.log"
if [ -f "$LOG" ]; then
  # Parse --since into seconds offset (portable across BSD/macOS and GNU date).
  # Accepts formats: "Nh", "Nd", "N hours", "N days", "yesterday". Default: 24h.
  SINCE="${SINCE:-24h}"
  case "$SINCE" in
    *h)                     SECS=$(( ${SINCE%h} * 3600 )) ;;
    *d)                     SECS=$(( ${SINCE%d} * 86400 )) ;;
    *\ hour|*\ hours|*\ hours\ ago) SECS=$(( ${SINCE%% *} * 3600 )) ;;
    *\ day|*\ days|*\ days\ ago)    SECS=$(( ${SINCE%% *} * 86400 )) ;;
    yesterday)              SECS=86400 ;;
    *)                      SECS=86400 ;;  # fallback to 24h on anything unexpected
  esac

  # Epoch math works on both BSD/macOS and GNU. Avoid `date -v-24H` (BSD-only,
  # ignores $SINCE) and `date -d "24 hours ago"` (GNU-only).
  NOW=$(date -u +%s)
  CUTOFF_EPOCH=$((NOW - SECS))
  CUTOFF=$(date -u -r "$CUTOFF_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
           || date -u -d "@$CUTOFF_EPOCH" +%Y-%m-%dT%H:%M:%SZ)
  awk -v c="[$CUTOFF]" '$1 >= c' "$LOG" | tail -n 50
fi
```

Parse each entry (format: `[timestamp] PR #N comment #M by <author>: <action> | rationale: <why>`) and group by PR. Aggregate counts: dismissed / acknowledged / fixed / flagged.

### Step 3 — Open PRs with new reviewer activity

Goal: list PRs that need attention. A PR needs attention if **either**:
- Its review decision is `CHANGES_REQUESTED` (regardless of comment count), OR
- It has new **reviewer** comments since the last `/review-pr` run on that PR. "Reviewer" means anyone other than the current user — own replies don't count as new activity.

**Portable shell only.** macOS ships bash 3.2 which has no associative arrays (`declare -A`), so the implementation uses a plain temp file keyed on PR number. No bashisms later than 3.2 are required.

```bash
# Current user (used to filter own comments out of the reviewer-activity check).
ME=$(gh api user --jq .login)

# Compute "last /review-pr run timestamp per PR" from the audit log.
# Output format: PR_NUMBER|TIMESTAMP — latest per PR, via sort + awk (portable).
LAST_RUN_FILE=$(mktemp)
trap 'rm -f "$LAST_RUN_FILE"' EXIT
if [ -f "$HOME/.claude/pr-review-actions.log" ]; then
  sed -nE 's/^\[([^]]+)\] PR #([0-9]+).*/\2|\1/p' "$HOME/.claude/pr-review-actions.log" \
    | sort -t'|' -k1,1 -k2,2r \
    | awk -F'|' '!seen[$1]++' > "$LAST_RUN_FILE"
fi

# Fetch each comment with its author so we can filter to non-self reviewers.
# Requires .comments to include author.login (fetched via --json comments from gh).
gh pr list --author @me --state open \
  --json number,title,headRefName,updatedAt,reviewDecision,comments \
  | jq -c '.[]' \
  | while IFS= read -r pr_json; do
      pr=$(echo "$pr_json" | jq -r .number)
      decision=$(echo "$pr_json" | jq -r '.reviewDecision // "PENDING"')
      # Latest REVIEWER comment = latest comment whose author != ME.
      latest_reviewer=$(echo "$pr_json" \
        | jq -r --arg me "$ME" '[.comments[]? | select(.author.login != $me)]
                                 | sort_by(.createdAt) | last.createdAt // empty')
      # Lookup last /review-pr run for this PR in the temp file.
      last_run=$(awk -F'|' -v p="$pr" '$1 == p { print $2; exit }' "$LAST_RUN_FILE")

      show=false
      [ "$decision" = "CHANGES_REQUESTED" ] && show=true
      # Reviewer comment is "new" if it exists and is newer than last_run
      # (or there is no prior run yet). String comparison works on ISO timestamps.
      if [ -n "$latest_reviewer" ]; then
        if [ -z "$last_run" ] || [ "$latest_reviewer" \> "$last_run" ]; then
          show=true
        fi
      fi

      if [ "$show" = true ]; then
        title=$(echo "$pr_json" | jq -r .title)
        updated=$(echo "$pr_json" | jq -r .updatedAt)
        rcount=$(echo "$pr_json" | jq --arg me "$ME" '[.comments[]? | select(.author.login != $me)] | length')
        echo "PR #${pr} [${decision}] ${title} — last activity ${updated}, ${rcount} reviewer comment(s)"
      fi
    done
```

PRs are omitted when all three conditions hold: review decision is NOT `CHANGES_REQUESTED`, there are no reviewer comments at all, AND (if there are reviewer comments) none are newer than the last `/review-pr` run. This prevents two false-positive patterns: (1) own replies showing up as "new activity", (2) stale reviewer comments that have already been processed showing up again.

### Step 4 — Report

```
PR Review Activity Report — since [cutoff]

## Active /review-pr crons
[one-line per PR-polling cron, or "none"]

## /review-pr actions
[grouped by PR, counts of: dismissed / acknowledged / fixed / flagged, or "none"]

## Open PRs with reviewer activity
[PR list, or "none"]

## Suggestion
[one of:
 - "No PR review activity. Nothing to act on."
 - "PR #N has N new comments — run `/review-pr N` to process."
 - "Cron job [id] will next fire at [time] for PR #N."
]
```

---

## Rules

1. **Read-only.** Never writes to any file. Never moves tickets. Never posts to GitHub.
2. **Fast.** Target under 5 seconds. No background agent spawning, no MCP queries beyond `gh`.
3. **No orchestration.** `/status` does not invoke chief-of-staff or any reviewer agents — nothing to review.
4. **PR-review scope only.** Do NOT list autonomous commits, feature-branch state, test runs, or any non-PR activity. If there is no `/review-pr` activity and no PR-polling cron, the report is mostly empty — and that is correct.
5. **Handles missing data.** If the audit log does not exist yet, say so and carry on. If `gh` auth is stale, skip Step 3 with a note.
6. **Cutoff semantics.** `--since` accepts relative-time strings (`2h`, `3 days ago`, `yesterday`). Default is `24 hours ago`.

---

## When to use

- After running `/loop` or scheduling a PR-polling cron — confirm it is still active
- Returning to a session where you left `/review-pr` running — see what happened
- Before merging a PR — check if `/review-pr` caught any open comments you'd miss
- Suspicious silence — you asked the agent to poll but see no visible activity

## When NOT to use

- During active feature work (`/flow`, `/bug`, `/hotfix`) — it will usually be empty and add noise
- Inside a subagent — subagents do not share the parent's cron state
- To check general git history — use `git log` instead
- As a substitute for reading `.claude/handover.md` — that file is richer for in-workflow handovers

---

## Example output — PR review activity present

```
PR Review Activity Report — since 24h

## Active /review-pr crons
cron-7f3: polls PR #42 every 1min, next fires 2026-04-23T20:06:00Z

## /review-pr actions (last 24h)
PR #42: 2 dismissed, 1 fixed (commit a1b2c3d), 0 flagged

## Open PRs with reviewer activity
PR #42 [CHANGES_REQUESTED] feat(caching): ... — last activity 2026-04-23T19:58Z, 3 comment(s)

## Suggestion
PR #42 has 1 new automated-review comment since the last /review-pr run — run `/review-pr 42` to process.
```

## Example output — nothing to show (the common case when fixing things)

```
PR Review Activity Report — since 24h

## Active /review-pr crons
none

## /review-pr actions
none

## Open PRs with reviewer activity
none

## Suggestion
No PR review activity. Nothing to act on. Carry on with your current workflow.
```
