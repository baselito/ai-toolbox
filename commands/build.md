# /build — Ad-Hoc Build Workflow

Lighter version of `/flow` for ad-hoc work without a Jira ticket. Good for prototypes, experiments, or quick features that don't need full Jira tracking.

---

> **Edge cases:** If something goes wrong (service unreachable, empty results, user rejects, mid-workflow failure), follow the always-loaded general rules in `rules/edge-cases.md` and load the `edge-cases` skill for the scenario playbooks. Never fail silently — always offer alternatives.

## Durable GoalRun integration

For a detailed ad-hoc goal that must survive compaction or a closed session,
/build may create or resume a GoalRun. It runs one bounded iteration at a time,
uses registry verifier keys, records advisor/watchdog evidence, and keeps
Beads optional. It does not weaken the existing TDD, review, or human safety
gates.

## Trigger

- Run manually: `/build`
- Auto-routed from `/start` when no Jira ticket is associated or methodology is Ad-hoc

---

## Prerequisites

- **Workflow marker:** `touch ~/.claude/.workflow-started` — gates branch creation via `enforce-workflow-start.sh` hook.
- `.claude/PROJECT.md` must exist — if not, the agent runs `/init` automatically
- **Gitignore pre-check:** Verify toolbox files (`.beads/`, `AGENTS.md`, `CLAUDE.md`, `.claude/`, `ai-engineering/`) are in `.gitignore` and not already tracked by git. See `rules/workflow-discipline.md` Rule 5.
- **Handover:** Read `.claude/handover.md` at start; append after each phase per `rules/handover.md`. All entries must include the `### Deviations` field.

---

## What Is Different from /flow

| Step | /flow | /build |
|---|---|---|
| Jira ticket | Required (reads from board) | Not required — optional with agent-first |
| Beads tracking | Always (if enabled) | Optional — agent asks (or auto-created by work-breakdown) |
| Branch creation | From Jira ticket ID | User provides name or agent suggests |
| Work breakdown | Agent-first/hybrid: runs `work-breakdown` | Agent-first: runs `work-breakdown` if multi-task |
| Brainstorming | Full Socratic design | Full Socratic design |
| Implementation plan | Full (deep-reasoning tier) | Full (deep-reasoning tier) |
| TDD | Enforced | Enforced |
| Code review | Full | Full |
| Conditional agents | All apply | All apply |
| Reality checker | Full | Full |
| Jira status moves | Yes | Skipped unless agent-first creates tickets |
| PR creation | Yes | Yes |

---

## Workflow

### Step 1 — Describe and Confirm

The agent asks the user to describe what they want to build.

**Single-task work** (small, no breakdown needed):
```
-----------------------------------------
  Work Summary — please confirm
-----------------------------------------
  [1]  Task:      User-provided description
  [2]  Type:      Feature / Prototype / Experiment
  [3]  Branch:    feature/description-slug
  [4]  Beads:     [Y/N] — track this in Beads?
  [5]  Skipping:  Jira integration
  [6]  Integrations: GitHub, Beads (if enabled)

  [ENTER] Confirm and start
  [E]     Edit field(s)
  [Q]     Quit
-----------------------------------------
```

**Multi-task work** (agent-first mode active, or user describes something large):

If `jira_workflow` is set to "Agent-first" and the work sounds like more than a single task, the agent runs the `work-breakdown` skill between description and confirmation:

1. `brainstorming` skill runs scoping questions
2. `work-breakdown` skill proposes the breakdown
3. User approves the breakdown
4. Beads created for all tasks. Jira tickets created if Jira is configured. When creating tickets, pass structured content (Problem, Scope, Acceptance Criteria) to `jira-workflow-steward`, which applies the Ticket Description Template (see `agents/jira-workflow-steward.md` → Ticket Description Template and `rules/agents.md` → Ticket Description Quality).
5. Modified confirmation summary:

```
-----------------------------------------
  Work Summary — please confirm
-----------------------------------------
  [1]  Task:      Invite endpoint — request models
                  (1 of 7 from work breakdown)
  [2]  Type:      Feature
  [3]  Branch:    feature/invite-request-models
  [4]  Beads:     Linked to existing bead
  [5]  Jira:      DEV-5647 (just created)
  [6]  Integrations: GitHub, Jira (acli), Beads
  [7]  Breakdown: 3 stories, 7 tasks

  [ENTER] Confirm and start first task
  [E]     Edit field(s)
  [Q]     Quit
-----------------------------------------
```

If `jira_workflow` is "Board-driven" or "Hybrid", `/build` behaves as single-task (no breakdown). Hybrid does not apply to `/build` because hybrid requires existing Jira epics/stories.

### Step 1.5 — Execution Plan

**Agent:** `chief-of-staff` (deep-reasoning tier — see `rules/performance.md`)

After the user confirms, spawn chief-of-staff to create the execution plan — same as `/flow` Step 1.8. Chief-of-staff assigns agents and models for each phase (brainstorming, planning, implementation, code review, verification, PR). The orchestrator follows this plan.

### Step 2 — Brainstorming

**BRAINSTORMING IS MANDATORY — THE AGENT CANNOT SKIP IT.** Even for tasks that seem simple or well-defined, the brainstorming skill must run. The agent does not get to decide that brainstorming is unnecessary. If the user wants to skip it, the user must explicitly say so.

**Skill:** `brainstorming` (Opus)

Same as `/flow` — Socratic design refinement, and clarifying questions only where the answer is genuinely not inferable (**Unknown**). The agent recommends one direction and proceeds on it (autonomy rule); it waits only where the choice crosses a category or the phase is BLOCKED (`rules/autonomy.md`).

**For greenfield projects** (project type is "Greenfield" in PROJECT.md):
- **Skill:** `blueprint` is also activated for system design blueprint generation
- **Agent:** `architect` (deep-reasoning tier) runs to evaluate architecture patterns before implementation

**Phase summary gate:** Include: design decisions, constraints, trade-offs. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`).

### Step 3 — Implementation Plan

**Agent:** `planner` (deep-reasoning tier — see `rules/performance.md`)

Same as `/flow` — detailed implementation plan with file paths, phases, dependencies. The plan is presented and proceeded on (autonomy rule); it waits only where the plan itself crosses a category or the phase is BLOCKED (`rules/autonomy.md`).

**Phase summary gate:** Include: plan scope, phases, dependencies. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`).

### Step 4 — Execution

Same as `/flow` Steps 6-13:
- Git worktrees if applicable
- Subagent execution with TDD enforcement
- Code review via `code-review-orchestration` skill (do NOT spawn chief-of-staff directly)
Invoke all skills via an Opus subagent with `[DELEGATED]` marker — see `/flow` for the delegation pattern.
- All conditional agents based on files changed (chief-of-staff decides)
- Verification via `verification-before-completion` skill
- Reality checker (always last)
- DevOps check (if pipeline files changed)
- Doc updater

**Phase summary gate:** Include: review grades, test coverage, reality checker verdict. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`).

### Step 4.5 — Compliance Audit

Before PR creation, run an independent compliance audit subagent — same as `/flow` Step 15 — the orchestrator spawns and AWAITS it; the PR-creation subagent must not spawn it (it cannot await a grandchild).

### Step 5 — Finishing the Branch

**Skill:** `finishing-a-development-branch`

**Auto-poll:** schedule the `/review-pr` 1-minute cron and handle reviewer comments inline per `rules/git-workflow.md` "Auto-Poll After PR Creation" (cron is best-effort; inline handling is the reliable path). Applies to ALL commands that create PRs.

Same as `/flow` — merge / PR / keep / discard options. The agent waits for the user's decision.

### Step 6 — Beads Cleanup (if tracking was enabled)

If the user opted into Beads tracking in Step 1:

**Beads issue creation (after confirmation in Step 1):**

1. Check if `.beads/` exists. If NOT, run the `bd init` the gitignore pre-check script in the **`workflow-discipline` skill** (§ "Gitignore pre-check") (verify gitignore + no tracked files); only if the pre-check passes, run `Bash(bd init)` (automatic, don't ask). If the pre-check fails, warn the user and continue without Beads. If `bd init` itself fails, warn and continue without Beads. **If continuing without Beads, skip steps 2 and 3 entirely.**
2. Create the issue: `Bash(bd create --title "[description slug]" --type task --priority 2 -d "[task description]")`
3. Update status: `Bash(bd update [BEAD_ID] --status in_progress)`

**Beads close (after PR in Step 5):**

Close the Beads issue: `Bash(bd close [BEAD_ID])` with a summary of the work done.

**Beads lifecycle:** Create + in_progress at Step 1, close at Step 5. See `/flow` Step 4 for the full Beads command reference.

---

## Agent and Skill Usage

| Step | Agent/Skill | Model |
|---|---|---|
| Brainstorming | `brainstorming` skill | Opus |
| Architecture (greenfield) | `architect` | Deep-reasoning tier |
| Blueprint (greenfield) | `blueprint` skill | — |
| Implementation plan | `planner` | Deep-reasoning tier |
| TDD enforcement | `tdd-guide` | Opus |
| Code review | `code-reviewer` | Opus |
| Conditional agents | Same as `/flow` | Same as `/flow` |
| Reality checker | `reality-checker` | Opus |
| Doc sync | `doc-updater` | Haiku |
| Git commits | — | Haiku |
| Branch finishing | `finishing-a-development-branch` skill | Opus |

---

## Notes

- `/build` is the go-to command when you want to build something without Jira overhead
- All quality gates still apply — TDD, code review, security checks, reality checker
- The only things skipped vs `/flow` are Jira-specific steps (ticket reading, status moves, board mapping)
- Beads tracking is optional but recommended for anything that might span multiple sessions
- **Agent-first with Jira:** If `jira_workflow` is "Agent-first" and Jira is configured, `/build` creates Jira tickets during `work-breakdown`. This transforms `/build` from a "no Jira" command into a "Jira-optional" command — the user gets the lightweight entry point of `/build` with full Jira integration when configured.
- **Multi-task looping:** When `work-breakdown` creates multiple tasks, `/build` loops through them like `/flow` does with Scrum boards — completing each task via the full workflow (Steps 2-5), showing progress between tasks, and allowing the user to skip or stop.
