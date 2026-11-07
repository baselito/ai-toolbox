# /refactor — Code Cleanup and Modernisation

Clean up or modernise existing code without adding new features. Analyses the codebase, proposes changes, and creates a PR. The refactor-cleaner agent is active throughout.

---

> **Edge cases:** If something goes wrong (service unreachable, empty results, user rejects, mid-workflow failure), follow the always-loaded general rules in `rules/edge-cases.md` and load the `edge-cases` skill for the scenario playbooks. Never fail silently — always offer alternatives.

## Trigger

- Run manually: `/refactor`
- Auto-routed from `/start` when the user picks "Clean up / modernise existing code"
- Auto-routed from `/start` when Jira ticket type is Refactor / Tech Debt

---

## Prerequisites

- `.claude/PROJECT.md` must exist — if not, the agent runs `/init` automatically
- **First time running `/refactor`:** The agent asks where refactor tickets go (see `/init` — Board Mapping)

---

## What Is Different from /flow

| Step | /flow | /refactor |
|---|---|---|
| Brainstorming | Full Socratic design | Skipped — goes straight to analysis |
| Analysis phase | Not included | `refactor-cleaner` agent analyses the codebase |
| New features | Yes | No — cleanup only |
| refactor-cleaner agent | Not active | Active throughout |
| Evidence collector | If UI touched | Mandatory if UI touched |

---

## Workflow

### Step 0 — Pre-flight (runs regardless of entry point)

This step runs every time `/refactor` is invoked — whether from `/start`, directly, or via `/refactor TASK-741`. It ensures the Jira lifecycle, branch naming, and Beads tracking are initialized even if `/start` was skipped.

0. **Workflow marker:** `touch ~/.claude/.workflow-started` — gates branch creation via `enforce-workflow-start.sh` hook.

1. **PROJECT.md check:** If `.claude/PROJECT.md` doesn't exist, run `/init` automatically.

2. **Ticket read (read-only):** If a Jira ticket ID was provided (e.g. `/refactor TASK-741`):
   - Read the ticket: `Bash(acli jira workitem view [TICKET] --json)` — note: `view` takes a positional key, NOT `--key`
   - Do NOT assign yet — assignment happens after analysis gate (Step 2)
   - If assigned to someone else, warn before reassigning — a **Conflict** ask (header `Conflict`) after the analysis gate

3. **Phase-map validation:** If a ticket exists, read `jira_phase_map` from PROJECT.md. If not set, run the phase-map setup from `/init` Sub-step 1e. Validate mapped columns still exist on the live board (same drift check as `/flow` Step 0).

4. **Branch naming:** If the current branch is auto-generated (matches `claude/*` pattern), rename it to follow conventions:
   - `git branch -m refactor/[TICKET-ID]-[slug-from-title]`
   - If no ticket, use descriptive slug: `refactor/description-slug`

5. **Discovery comment:** Deferred to Step 2 — posted after the analysis gate has been SHOWN, not during pre-flight. Pre-flight is read-only (no delegation token exists yet).

6. **Gitignore pre-check:** Verify toolbox files (`.beads/`, `AGENTS.md`, `CLAUDE.md`, `.claude/`, `ai-engineering/`) are in `.gitignore` and not already tracked by git. See `rules/workflow-discipline.md` Rule 5 for the full script. If any are tracked, run `git rm --cached -r <files>` before proceeding.

7. **Handover init:** Read `.claude/handover.md` if it exists (resuming interrupted work). If starting fresh, clear it and write the initial entry:
   ```
   ## Pre-flight — /refactor [TICKET]
   Completed: [timestamp]
   Status: PASSED
   ### What was done
   - Ticket read (not yet assigned)
   ```

After pre-flight completes, proceed to Step 1.

### Step 1 — Refactor Scope

The agent asks what to refactor:

```
What do you want to clean up?

1) A specific file or folder — enter path
2) A specific pattern — e.g. "remove all deprecated API calls"
3) Full tech debt scan — the agent analyses the
   whole codebase and proposes a plan
```

### Step 2 — Codebase Analysis

**Agent:** `refactor-cleaner` (Opus) — performs the codebase analysis, identifying dead code, legacy patterns, and modernisation opportunities. There are no separate analysis skills — `refactor-cleaner` runs the analysis itself using its own tooling (knip, depcheck, ts-prune, and repo search).

The agent analyses the codebase to understand:
- Current code structure and patterns
- Tech debt hotspots
- Dead code
- Legacy patterns that can be modernised
- Repeated code that could be abstracted

**Phase summary gate:** Include: hotspots, dead code, legacy patterns, tech debt severity. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`). (No Jira write yet — the delegation token is created in the block below, after the gate has been shown.)

**After the analysis gate has been shown, if a Jira ticket was provided:**
- **Jira delegation token:** `touch ~/.claude/.jira-delegation-token` (session-level, valid for 3600 seconds, not consumed on use)
- If assigned to someone else, this is a **Conflict** ask (`rules/autonomy.md`) — taking a ticket another person holds collides with their claim on the work. Warn, then AskUserQuestion with header `Conflict`. Only proceed with assignment if the user confirms. If declined, continue without reassigning.
- If unassigned or reassignment approved, assign to current user: spawn `jira-workflow-steward` (Haiku) with `acli jira workitem assign --key [TICKET] --assignee @me -y`
- **Discovery comment (first — the initial Jira comment):** Spawn `jira-workflow-steward` (Haiku) with `phase=discovery` to post the initial Jira comment with refactor scope and rationale.
- **Analysis comment (second — preserves phase order):** Spawn `jira-workflow-steward` (Haiku) with phase=`in_progress` and comment: "🔍 Analysis — [tech debt summary]. Hotspots: [list]. Dead code: [count files]. Legacy patterns: [count]."

If no Jira ticket was provided, skip all Jira operations and continue to Step 2.5.

### Step 2.5 — Execution Plan

**Agent:** `chief-of-staff` (deep-reasoning tier — see `rules/performance.md`)

Spawn chief-of-staff to create the execution plan — same as `/flow` Step 1.8. Chief-of-staff assigns agents and models for refactor phases.

### Step 3 — Refactor Plan

The agent presents a refactor plan for approval:

```
-----------------------------------------
  Refactor Plan — please approve
-----------------------------------------
  Scope: Remove deprecated API v1 endpoints

  Changes:
  1. Remove 3 deprecated controller files
  2. Update 7 references in service layer
  3. Remove 2 unused middleware files
  4. Update API documentation

  Files affected: 12
  Tests affected: 5 (will be updated)

  Risk: Low — deprecated endpoints have zero
  traffic in the last 30 days (Seq)

  [ENTER] Approve and start
  [E]     Edit scope
  [Q]     Cancel
-----------------------------------------
```

The user must approve before any changes are made.

### Step 4 — Implementation

The `refactor-cleaner` (Opus) agent leads implementation:

1. Apply changes per the approved plan
2. `tdd-guide` (Opus) — update affected tests, ensure all pass
3. No new features — strictly cleanup

**Jira comment:** If a ticket exists, spawn `jira-workflow-steward` (Haiku) with comment: "🚀 Refactor implemented — [summary of changes]. Files changed: [count]. Tests updated: [count] passing. Branch: [branch name]."

**Phase summary gate:** Include: changes applied, tests updated, plan deviations. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`).

### Step 5 — Code Review (via `code-review-orchestration` skill)

Invoke the `code-review-orchestration` skill — do NOT spawn chief-of-staff or review agents directly. The skill handles orchestration (see `rules/agents.md` and `skills/code-review-orchestration/SKILL.md`).
Invoke via an Opus subagent with `[DELEGATED]` marker — see `/flow` Step 9.

Same conditional agent triggers and parallel execution rules as `/flow` — chief-of-staff decides which agents run based on files changed.

**Jira comment:** If a ticket exists, spawn `jira-workflow-steward` (Haiku) with phase=`code_review` and comment: "🔍 Code Review — Grade [A-F]. [key findings]. Agents run: [list]."

### Step 6 — Verification

**Skill:** `verification-before-completion`

Confirms:
- All tests pass
- No regressions introduced
- Refactored code behaves identically to the original

**Jira comment:** If a ticket exists, spawn `jira-workflow-steward` (Haiku) with comment: "✅ Verification — All tests: [count] passing. No regressions. Behavioural equivalence confirmed."

**Phase summary gate:** Include: verification results, behavioural equivalence. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`).

### Step 7 — Reality Checker

**Agent:** `reality-checker` (Opus)

Production readiness gate. Signs off or blocks.

**Phase summary gate:** Include: reality checker verdict, blockers. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`).

### Step 7.5 — Compliance Audit

Before PR creation, run an independent compliance audit subagent — same as `/flow` Step 15 — the orchestrator spawns and AWAITS it; the PR-creation subagent must not spawn it (it cannot await a grandchild).

### Step 8 — PR and Cleanup

**Skill:** `finishing-a-development-branch` (Opus)

- Creates PR with refactor description and before/after summary

**Auto-poll:** schedule the `/review-pr` 1-minute cron and handle reviewer comments inline per `rules/git-workflow.md` "Auto-Poll After PR Creation" (cron is best-effort; inline handling is the reliable path). Applies to ALL commands that create PRs.

- `doc-updater` (Haiku) syncs documentation if affected
- If a ticket exists, `jira-workflow-steward` (Haiku) updates ticket and posts final comment: "🔗 PR — [link]. Refactor: [summary]. Files changed: [count]. Tests: [count] passing."
- If a ticket exists, transition ticket to `ready_for_release` via `jira-workflow-steward` (Haiku) with phase=`ready_for_release` (if the phase map has this column)
- Close the Beads issue: `Bash(bd close [BEAD_ID])` with a summary of what was refactored

**Beads lifecycle:** Create + in_progress after Step 3 approval, close at Step 8. See `/flow` Step 4 for the full Beads command reference.

---

## Agent and Skill Usage

| Step | Agent/Skill | Model |
|---|---|---|
| Codebase analysis | `refactor-cleaner` | Opus |
| Refactor execution | `refactor-cleaner` | Opus |
| TDD enforcement | `tdd-guide` | Opus |
| Code review | `code-reviewer` | Opus |
| Evidence collection (UI) | `evidence-collector` | Sonnet |
| Conditional agents | Same rules as `/flow` | Same as `/flow` |
| Verification | `verification-before-completion` skill | — |
| Reality checker | `reality-checker` | Opus |
| Doc sync | `doc-updater` | Haiku |
| PR creation | `finishing-a-development-branch` skill | Opus |

---

## Notes

- `/refactor` never adds new features — it only cleans up, removes, or modernises existing code
- The refactor-cleaner agent is specifically designed for this — it is not used in other workflows
- Evidence collector is mandatory for UI refactoring to ensure visual regression does not occur
- For legacy codebases, `/refactor` pairs well with the "Legacy refactor / modernisation" project type set in `/init`
