# /hotfix — Urgent Same-Day Fix

Fast-path bug fix for issues that need resolving today. Skips brainstorming, full planning, and extended documentation to save time. All quality gates still run. Tells CI/CD to prioritise this deployment.

---

> **Edge cases:** If something goes wrong (service unreachable, empty results, user rejects, mid-workflow failure), follow the always-loaded general rules in `rules/edge-cases.md` and load the `edge-cases` skill for the scenario playbooks. Never fail silently — always offer alternatives.

## Trigger

- Run manually: `/hotfix`
- Auto-routed from `/start` when the user picks "Something is broken and needs fixing urgently today"
- Auto-routed from `/start` when Jira ticket type is Hotfix / Urgent

---

## Prerequisites

- `.claude/PROJECT.md` must exist — if not, the agent runs `/init` automatically

---

## What Is Skipped vs /bug

| Step | /bug | /hotfix |
|---|---|---|
| Brainstorming | Full Socratic design | Skipped |
| Full planning (deep-reasoning tier) | Yes | Skipped — minimal plan only |
| Extended documentation | Yes | Skipped — minimal docs only |
| TDD | Enforced | Enforced |
| Security checks | Full | Full |
| Code review | Full | Full |
| Reality checker | Full | Full |
| CI/CD priority | Normal queue | Fast-tracked |

---

## Workflow

### Step 0 — Pre-flight (runs regardless of entry point)

This step runs every time `/hotfix` is invoked — whether from `/start`, directly, or via `/hotfix TASK-741`. It ensures the Jira lifecycle, branch naming, and Beads tracking are initialized even if `/start` was skipped.

0. **Workflow marker:** `touch ~/.claude/.workflow-started` — gates branch creation via `enforce-workflow-start.sh` hook.

1. **PROJECT.md check:** If `.claude/PROJECT.md` doesn't exist, run `/init` automatically.

2. **Gitignore pre-check:** Verify toolbox files (`.beads/`, `AGENTS.md`, `CLAUDE.md`, `.claude/`, `ai-engineering/`) are in `.gitignore` and not already tracked by git. See `rules/workflow-discipline.md` Rule 5 for the full script. If any are tracked, run `git rm --cached -r <files>` before proceeding.

3. **Ticket read (read-only):** If a Jira ticket ID was provided (e.g. `/hotfix TASK-741`):
   - Read the ticket: `Bash(acli jira workitem view [TICKET] --json)` — note: `view` takes a positional key, NOT `--key`
   - Do NOT assign yet — assignment happens after the investigation gate (Step 3.5)
   - If assigned to someone else, note this for later (warn at investigation gate)

4. **Phase-map validation:** If a ticket exists, read `jira_phase_map` from PROJECT.md. If not set, run the phase-map setup from `/init` Sub-step 1e. Validate mapped columns still exist on the live board (same drift check as `/flow` Step 0).

5. **Branch naming (decide only):** Determine the conventional branch name now — `hotfix/[TICKET-ID]-[slug-from-title]`. If no ticket was provided, the name is finalized at Step 3.5: the steward creates the ticket there FIRST, so the branch still gets a real ticket ID (`hotfix/description-slug` applies only when Jira isn't configured or the user declines a ticket). Do NOT create or rename any branch yet — branch creation happens at Step 3.5, after the user confirms. (Exception: if the session is already on an auto-generated `claude/*` branch, renaming it in place at Step 3.5 is the correct move, not a new branch.)

6. **Discovery comment:** Deferred to Step 3.5 — posted after the user confirms at the investigation gate, not during pre-flight. Pre-flight is read-only.

7. **Handover init:** Read `.claude/handover.md` if it exists (resuming interrupted work). If starting fresh, clear it and write the initial entry:
   ```
   ## Pre-flight — /hotfix [TICKET]
   Completed: [timestamp]
   Status: PASSED
   ### What was done
   - Project config verified, ticket read (not yet assigned)
   ```

After pre-flight completes, proceed to Step 1.

### Step 1 — Hotfix Intake

Same as `/bug` Step 1 — the agent asks the user to describe the issue, or reads the Jira ticket if routed from `/start`.

### Step 2 — Beads Issue (preview only, no Jira writes yet)

If Beads tracking is enabled in PROJECT.md, create a Beads issue to track the hotfix locally — this does not require the Jira delegation token:

1. Check if `.beads/` exists. If NOT, run the `bd init` the gitignore pre-check script in the **`workflow-discipline` skill** (§ "Gitignore pre-check"); only if the pre-check passes, run `Bash(bd init)` (automatic, don't ask). If the pre-check fails, stop and warn the user instead of running `bd init`. If `bd init` fails, warn and continue without Beads. **If continuing without Beads, skip steps 2 and 3 entirely.**
2. Create the issue: `Bash(bd create --title "[TICKET or description] [title]" --type bug --priority 1 -d "[description]")`
3. Update status: `Bash(bd update [BEAD_ID] --status in_progress)`

**Beads lifecycle:** Create + in_progress at Step 2, close at Step 9. See `/flow` Step 4 for the full Beads command reference.

**Jira ticket creation/update and branch creation are deferred to Step 3.5** — after the user confirms at Step 3 and the delegation token exists. Pre-flight and this step are read-only with respect to Jira.

### Step 3 — Confirmation Summary

```
-----------------------------------------
  Work Summary — please confirm
-----------------------------------------
  [1]  Ticket:    DEV-5690
  [2]  Title:     Payment redirect failing
  [3]  Type:      Hotfix
  [4]  Priority:  Critical
  [5]  Workflow:  /hotfix
  [6]  Branch:    hotfix/DEV-5690-payment-redirect
  [7]  Beads:     New issue created
  [8]  Skipping:  Brainstorming, full planning,
                  extended docs
  [9]  Integrations: Jira (acli), Seq, Beads
  [10] Board:     DEV board 309

  [ENTER] Confirm and start
  [E]     Edit field(s)
  [Q]     Quit
-----------------------------------------
```

### Step 3.5 — Investigation Gate, Ticket Creation, and Branch

**⛔ MANDATORY GATE — create the delegation token, then create/update the ticket, assign, branch, and post the discovery comment — all only after the user confirms.**

After the user confirms at Step 3:
- **Jira delegation token:** `touch ~/.claude/.jira-delegation-token` (session-level, valid for 3600 seconds, not consumed on use)
- **Agent:** `jira-workflow-steward` (Haiku) creates or updates the Jira ticket with Hotfix priority (if one wasn't already provided)
- If assigned to someone else, this is a **Conflict** ask (`rules/autonomy.md`) — taking a ticket another person holds collides with their claim on the work. Warn, then AskUserQuestion with header `Conflict`. Only proceed with assignment if the user confirms. If declined, continue without reassigning.
- If unassigned or reassignment approved, assign to current user: spawn `jira-workflow-steward` (Haiku) with `acli jira workitem assign --key [TICKET] --assignee @me -y`
- Creates branch: `hotfix/DEV-XXXX-slug` (use `hotfix/description-slug` ONLY when no ticket exists at branch-creation time — i.e. Jira isn't configured or the user declined a ticket)
- Post discovery comment: spawn `jira-workflow-steward` (Haiku) with `phase=discovery` to post the initial Jira comment with scope and urgency assessment.

If no Jira ticket was provided, the steward CREATES one here FIRST (first bullet — urgent fixes still get tracked), then uses that NEW ticket's ID for the branch name and all Jira updates — the ticket exists before the branch, so the `hotfix/[TICKET-ID]-slug` convention holds on the no-ticket entry path too. Jira operations are skipped ONLY when Jira isn't configured for the project or the user explicitly declined a ticket at the Step 3 confirmation; only in those two cases does the branch use `hotfix/description-slug`. Then continue to Step 3.6.

### Step 3.6 — Execution Plan

**Agent:** `chief-of-staff` (deep-reasoning tier — see `rules/performance.md`)

Spawn chief-of-staff to create the execution plan — same as `/flow` Step 1.8. Even for hotfixes, chief-of-staff assigns agents and models for each phase. The orchestrator follows this plan.

### Step 3.7 — Streamlined-plus Scope Expansion

Since `/hotfix` skips brainstorming and full planning, the streamlined-plus scope expansion check applies. Run `rg -n "<axis>"` for any discrete axis the fix touches. Treat ripgrep exit code 1 (no matches) as a valid outcome, not a failure. See `/flow` Step 6.5 and `rules/development-workflow.md` Step 1a. Orchestrator inline only, NO agent spawn.

### Step 4 — Systematic Debugging

**Skill:** `systematic-debugging` (Opus — no escalation; the invoking subagent is already Opus — see `rules/performance.md`)

Same 4-phase root cause analysis as `/bug`. Seq queried if configured.

**Jira comment:** If a ticket exists, spawn `jira-workflow-steward` (Haiku) with phase=`in_progress` and comment: "🔍 Investigation — [root cause summary]. Evidence: [key findings]. Confidence: [high/medium/low]. Urgency: [assessment]."

**Phase summary gate:** Include: root cause, confidence, urgency. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`).

### Step 5 — Minimal Plan and Fix

Instead of the full deep-reasoning-tier planner, the agent creates a minimal fix plan:
- What file(s) to change
- What the fix is
- Quick user approval, then implements

TDD enforced: `tdd-guide` (Opus) writes a failing test first, then the fix makes it pass.

**Jira comment:** If a ticket exists, spawn `jira-workflow-steward` (Haiku) with comment: "🚀 Hotfix implemented — [summary of fix]. Tests: [count] passing. Branch: [branch name]."

**Phase summary gate:** Include: fix summary, test coverage, scope. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`).

### Step 6 — Code Review (via `code-review-orchestration` skill)

Invoke the `code-review-orchestration` skill — do NOT spawn chief-of-staff or review agents directly. The skill handles orchestration (see `rules/agents.md` and `skills/code-review-orchestration/SKILL.md`).
Invoke via an Opus subagent with `[DELEGATED]` marker — see `/flow` Step 9 for the delegation pattern.

Same conditional agent triggers and parallel execution rules as `/flow` — chief-of-staff decides which agents run based on files changed.

**Jira comment:** If a ticket exists, spawn `jira-workflow-steward` (Haiku) with phase=`code_review` and comment: "🔍 Code Review — Grade [A-F]. [key findings]. Agents run: [list]."

**Phase summary gate:** Include: agents run, grades, findings. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`).

### Step 7 — Verification

**Skill:** `verification-before-completion`

Confirms the fix resolves the issue. All tests pass.

**Jira comment:** If a ticket exists, spawn `jira-workflow-steward` (Haiku) with comment: "✅ Verification — All tests: [count] passing. No regressions. Fix confirmed."

**Phase summary gate:** Include: verification results, regressions. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`).

### Step 8 — Reality Checker

**Agent:** `reality-checker` (Opus)

Signs off or blocks.

**Phase summary gate:** Include: reality checker verdict, blockers. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`).

### Step 8.5 — Compliance Audit

Before PR creation, run an independent compliance audit subagent — same as `/flow` Step 15 — the orchestrator spawns and AWAITS it; the PR-creation subagent must not spawn it (it cannot await a grandchild).

### Step 9 — PR Creation and Stop

**Skill:** `finishing-a-development-branch` (Opus)

**Auto-poll:** schedule the `/review-pr` 1-minute cron and handle reviewer comments inline per `rules/git-workflow.md` "Auto-Poll After PR Creation" (cron is best-effort; inline handling is the reliable path). Applies to ALL commands that create PRs.

Push and PR creation require consent — standing or per-action (`rules/git-workflow.md` → "Pull Requests"). Under standing consent, push and create the PR and report it in the State block. Otherwise ask ONCE per branch via AskUserQuestion (header `Irreversible`) with options:
- "Push and create PR"
- "Let me review first"
- "Keep branch"
- "Discard"

If the user confirms:
- Creates PR with hotfix description
- **`devops-automator` (Opus)** — tells CI/CD to prioritise this deployment over the normal queue
- If a ticket exists, `jira-workflow-steward` (Haiku) links the PR to the ticket and posts final comment: "🔗 PR — [link]. Root cause: [summary]. Fix: [summary]. Tests: [count] passing."
- If a ticket exists, transition ticket to `ready_for_release` via `jira-workflow-steward` (Haiku) with phase=`ready_for_release` (if the phase map has this column)
- Close the Beads issue: `Bash(bd close [BEAD_ID])` with a summary of the fix

**The ticket stays in Ready for Release (or In Progress if the board has no Ready for Release column).** Testing and Done are human steps. The agent does not move tickets to Done.

**The agent stops here.** Offer to pick up the next ticket.

---

## Agent and Skill Usage

| Step | Agent/Skill | Model |
|---|---|---|
| Jira ticket | `jira-workflow-steward` | Haiku |
| Systematic debugging | `systematic-debugging` skill | Opus |
| TDD | `tdd-guide` | Opus |
| Code review | `code-reviewer` | Opus |
| Conditional agents | Same rules as `/flow` | Same as `/flow` |
| Verification | `verification-before-completion` skill | — |
| Reality checker | `reality-checker` | Opus |
| CI/CD fast-track | `devops-automator` | Opus |
| PR creation | `finishing-a-development-branch` skill | Opus |
| Jira link PR | `jira-workflow-steward` | Haiku |

---

## Notes

- Use `/hotfix` when the fix is needed today — not just "important" but "urgent"
- For production-down situations, use `/incident` instead — it queries Seq immediately and focuses on restoring service
- Quality gates (TDD, security, code review, reality checker) are never skipped — only design and documentation steps are shortened
- The devops-automator actively tells the CI/CD pipeline to move this deployment to the front of the queue
- The Jira delegation token is session-level — create it once at Step 3.5 with `touch ~/.claude/.jira-delegation-token` (valid for 3600 seconds, not consumed on use). Subsequent jira-workflow-steward spawns within the same workflow do not need to re-create it.
