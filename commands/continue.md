# /continue — Resume a Previous Session

Pick up where the previous Claude Code session left off.

> **Edge cases:** If something goes wrong (service unreachable, empty results, user rejects, mid-workflow failure), follow the always-loaded general rules in `rules/edge-cases.md` and load the `edge-cases` skill for the scenario playbooks. Never fail silently — always offer alternatives.

## Durable GoalRun integration

After the handover migration, /continue also checks for incomplete GoalRuns.
It reconciles journaled unknown actions and provider sessions before offering
the next bounded iteration. A corrupt state or unreconciled high-risk action
stops in durable HUMAN_ACTION_REQUIRED state for the user.

## What the agent does

### Step 2 — GoalRun recovery (after Step 1 migration cleanup)

Run the installed durable runtime's `recover-all` command against
`.claude/goal-runs` (or the configured state directory) before reading or
acting on `.claude/handover.md`. Report each recovered, corrupt, or
human-action-required run. A GoalRun is the source of truth for an interrupted
detailed goal; do not silently start duplicate work because a handover exists or
is absent.

If `recover-all` reports any recovered GoalRun, stop before reading the handover
or continuing the original workflow. Show the run IDs and states, then require
an explicit disposition for each run: resume it through the GoalRun runtime,
complete it, or abandon it with the user's decision recorded. Do not use the
handover as a second source of work while any recovered run remains undisposed.

### Step 1 — Migration cleanup (one-time, non-destructive backup)

**⛔ This runs FIRST — before reading the handover — because legacy files from old Antigravity installs may contain the only record of unfinished work.** Destroying them outright risks permanent data loss.

**We do NOT merge legacy content into `.claude/handover.md`.** Merging risks mixing unrelated tasks (e.g. if `.claude/handover.md` already has Task A from yesterday and `.claude/antigravity-handover.md` has stale Task X from months ago, a merge contaminates the active handover). Instead, we rename legacy files to timestamped backups so the user can review them manually and decide if anything needs migrating.

For each legacy file in [`.claude/antigravity-handover.md`, `.claude/backup-handover.md`]:

```
If the file exists AND is non-empty:
  1. Compute backup path: .claude/<legacy-filename>.legacy-<ISO timestamp>.backup
     (example: .claude/antigravity-handover.md.legacy-2026-04-23T16-45.backup)
  2. Rename (mv) the legacy file to the backup path.
  3. Tell the user: "Moved <legacy filename> to <backup path> for review.
     Review it manually — if it contains active work you want to continue,
     copy the relevant sections into .claude/handover.md yourself."

Else if the file exists AND is empty:
  Delete silently, no backup needed.

Else:
  No action.
```

**Why rename, not merge?** If `.claude/handover.md` already has an active task, merging stale legacy content contaminates it. The backup approach leaves both files intact — the active handover is untouched, and the legacy content is preserved at a distinct filename the user can open, review, and manually integrate (or discard) on their own terms.

**Why keep the backup forever?** Because we don't know how long the user needs to migrate. If they never get to it, it just sits there gitignored (the `.claude/` directory is gitignored, so backups don't pollute the repo). If they want to clean up later, `rm .claude/*.legacy-*.backup` handles it.

After Step 1, tell the user (only if any legacy file existed):

> Moved legacy handover file(s) from a previous toolbox version to `.claude/*.legacy-*.backup`. Review them manually if you had unfinished work in an Antigravity session. Single handover (`.claude/handover.md`) is the source of truth going forward.

### Step 2 — GoalRun recovery (after Step 1 migration cleanup)

Run the installed durable runtime's `recover-all` command against
`.claude/goal-runs` (or the configured state directory) before reading or
acting on `.claude/handover.md`. Report each recovered, corrupt, or
human-action-required run. A GoalRun is the source of truth for an interrupted
detailed goal; do not silently start duplicate work because a handover exists or
is absent.

### Step 3 — Check the handover

Read `.claude/handover.md`. This is the single handover file; it contains phase-by-phase findings from the previous session of the same task. (Legacy files, if any, were renamed to `.claude/*.legacy-*.backup` by Step 1 without being merged — the active handover is whatever was already in `.claude/handover.md`.)

If the file doesn't exist (or is empty): tell the user "No prior session handover found. Is this a fresh task? If yes, use `/start` or one of the workflow commands (`/flow`, `/bug`, etc.). If you had unfinished work in an Antigravity-era session, check `.claude/*.legacy-*.backup` — Step 1 may have moved it there for manual review."

### Step 4 — Determine state

From `.claude/handover.md`, find:
- The **last completed phase** (bottom-most entry)
- The **next phase** that should run (from the `## What the next phase needs to focus on` section)
- Any **blockers or concerns**
- Which **workflow** was running (e.g. /flow, /bug)
- Which **task/ticket** was being worked on

### Step 5 — Show the user a detailed work summary

Use this format so the user knows exactly where they are:

```
## Continuing: [ticket ID] — [short description]

**Workflow:** /[workflow name]

### What was completed

| Phase | What was done | Key findings |
|---|---|---|
| 1 — Understand | Read ticket, analysed requirements | [specific findings] |
| 2 — Design | Chose approach, documented in handover | [specific approach chosen] |
| 3 — Implement | Built [component/feature], [X] files changed | [files list] |
| 4 — Test | ❌ Not started | — |

### Files changed so far
- `src/Components/PaymentController.cs` — added bulk invite endpoint
- `src/Models/InviteRequest.cs` — new model
- `tests/PaymentControllerTests.cs` — 3 tests added (all passing)

### Uncommitted work
[output of git status — show what's staged, modified, stashed]

### Blockers or concerns
- [anything flagged in handover — e.g. "security review needed", "N+1 query risk in GetUsers"]

### Next up
**Phase [N] — [name]**: [what this phase does]
```

**Important:** Pull specific findings from each phase entry in the handover. Don't just say "Phase 2 completed" — say what was decided, what was built, what was found. The user needs to see the actual work, not just a checklist.

### Step 6 — Confirm and continue

Ask the user: "Should I continue from Phase [N] of the [workflow] workflow?"

- **If yes:** do NOT clear `.claude/handover.md` — this is a continuation. Append new findings from the next phase onwards.
- **If no:** ask the user what they'd like to do instead (pick a different task, start fresh, etc.).

### Step 7 — Continue the workflow

Follow the original workflow from the next incomplete phase. Use the conditional review table from the original workflow. Append new phase findings to `.claude/handover.md` as normal.

## Rules

- One handover file: `.claude/handover.md`. No other handover files exist post-migration.
- Do NOT clear the handover during continuation — this is a resume, not a restart.
- If the handover is from a different task than expected, confirm before proceeding.
- Follow the original workflow's review gates and quality standards.
