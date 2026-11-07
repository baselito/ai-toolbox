# /bug — Bug Investigation and Fix

Full bug workflow: investigate root cause, fix, verify, and create PR. Creates a Jira ticket automatically if one doesn't exist. Uses systematic debugging for thorough root cause analysis.

---

> **Edge cases:** If something goes wrong (service unreachable, empty results, user rejects, mid-workflow failure), follow the always-loaded general rules in `rules/edge-cases.md` and load the `edge-cases` skill for the scenario playbooks. Never fail silently — always offer alternatives.

## Trigger

- Run manually: `/bug`
- Auto-routed from `/start` when the user picks "Bug — something is broken"
- Auto-routed from `/start` when Jira ticket type is Bug

---

## Prerequisites

- `.claude/PROJECT.md` must exist — if not, the agent runs `/init` automatically
- **First time running `/bug`:** The agent asks where bug tickets go (see `/init` — Board Mapping)

---

## Workflow

The workflow is split into two phases. Phase A is read-only investigation — no branches, no tickets, no Jira writes. Phase B is action — only after the user approves the investigation findings.

**⛔ DO NOT create branches, assign tickets, or post Jira comments during Phase A. These are Phase B actions that require user approval at the Investigation Gate (Step 1.6).**

### Phase A — Investigation (no side effects)

### Step 0 — Pre-flight (runs regardless of entry point)

This step runs every time `/bug` is invoked — whether from `/start`, directly, or via `/bug TASK-741`. It ensures the project config and phase map are ready.

0. **Workflow marker:** `touch ~/.claude/.workflow-started` — gates branch creation (Step 3) via `enforce-workflow-start.sh` hook.

1. **PROJECT.md check:** If `.claude/PROJECT.md` doesn't exist, run `/init` automatically.

2. **Gitignore pre-check:** Verify toolbox files (`.beads/`, `AGENTS.md`, `CLAUDE.md`, `.claude/`, `ai-engineering/`) are in `.gitignore` and not already tracked by git. See `rules/workflow-discipline.md` Rule 5 for the full script. If any are tracked, run `git rm --cached -r <files>` before proceeding.

3. **Ticket read (read-only):** If a Jira ticket ID was provided (e.g. `/bug TASK-741`):
   - Read the ticket: `Bash(acli jira workitem view [TICKET] --json)` — note: `view` takes a positional key, NOT `--key`
   - Do NOT assign yet — assignment happens in Phase B after the investigation gate
   - If assigned to someone else, note this for later (warn at investigation gate)

4. **Phase-map validation:** Read `jira_phase_map` from PROJECT.md. If not set, run the phase-map setup from `/init` Sub-step 1e. Validate mapped columns still exist on the live board (same drift check as `/flow` Step 0).

5. **Handover init:** Read `.claude/handover.md` if it exists (resuming interrupted work). If starting fresh, clear it and write the initial entry:
   ```
   ## Pre-flight — /bug [TICKET]
   Completed: [timestamp]
   Status: PASSED
   ### What was done
   - Project config verified, ticket read (not yet assigned)
   ```

   All handover entries must include the `### Deviations` field per `rules/handover.md`. Write `None observed.` if no deviations occurred.

After pre-flight completes, proceed to Step 1.

### Step 1 — Bug Intake

The agent asks the user to describe the bug:
- What is happening?
- What should be happening?
- When did it start? (if known)
- Any error messages or logs?

If routed from `/start` with a Jira ticket, the agent reads the ticket instead of asking.

### Step 1.5 — Systematic Investigation

**Skill:** `systematic-debugging` (Opus — no escalation; the invoking subagent is already Opus — see `rules/performance.md`)

The systematic debugging skill runs a 4-phase root cause analysis:

1. **Gather evidence:** Read error logs, stack traces, reproduction steps
2. **Form hypotheses:** Based on evidence, list possible root causes
3. **Test hypotheses:** Systematically verify or eliminate each hypothesis
4. **Identify root cause:** Confirm the actual cause with evidence

**Seq integration:** If Seq is configured (user-configured MCP server), the agent queries logs using:
- `seq_group_errors` — find error groups matching the bug description, ranked by priority
- `seq_get_error_events` — drill into the top match for timeline with context
- `seq_query_events` with filter — search for specific patterns or correlate across services

**No escalation:** the subagent invoking this skill already runs on Opus, so there is no lower tier to escalate from. If two attempts fail, widen the investigation — do not expect a model change.

**No Jira writes during this step.** Investigation is read-only. Findings are presented at the investigation gate.

### Step 1.6 — Investigation Gate

**⛔ MANDATORY GATE — the agent MUST stop here and present findings before any action.**

Present the investigation findings to the user via AskUserQuestion with header `Scope` — this is a front-loaded **kickoff** ask (`rules/autonomy.md`): it settles what the fix covers before any write happens. It is the only gate that waits on *every* `/bug` run; the one other gate, the **`Conflict`** ask at Step 2 before reassigning a ticket another person holds, waits only when that condition actually occurs:

```
-----------------------------------------
  Investigation Findings
-----------------------------------------
  Root cause:   [summary of what was found]
  Evidence:     [key findings, log entries, code references]
  Confidence:   [high / medium / low]
  Scope:        [estimated size of fix — small/medium/large]
  Risk:         [regression risk assessment]
  Files:        [list of files likely to change]
-----------------------------------------

  Options:
  [A] Create ticket and start fixing — full /bug workflow continues
  [B] Just create a ticket (defer fix) — ticket created, no code changes
  [C] No ticket needed — this is expected behaviour / already fixed / not a bug
  [D] Keep investigating — go back to Step 1.5 with new direction
-----------------------------------------
```

- **Option A:** Proceed to Phase B (Step 2 onwards)
- **Option B:** `touch ~/.claude/.jira-delegation-token`, then create Jira ticket via jira-workflow-steward, post findings as comment, stop
- **Option C:** Stop. No side effects.
- **Option D:** Loop back to Step 1.5. The agent asks: "What should I investigate next?"

**Phase summary gate:** Follow `rules/agents.md` Phase Summaries. Include: evidence gathered, root cause identified/not, Seq findings, confidence level.

---

### Phase B — Action (only after user approves at Investigation Gate)

### Step 2 — Ticket Setup and Assignment

The Jira delegation token is session-level — create it once at the start of Phase B with `touch ~/.claude/.jira-delegation-token` (valid for 3600 seconds, not consumed on use).

If no Jira ticket exists:
- Spawn `jira-workflow-steward` (Haiku) to create a Bug ticket in Jira on the configured bug board. Pass structured content (Root Cause, Scope, Acceptance Criteria) to `jira-workflow-steward`, which applies the Ticket Description Template (see `agents/jira-workflow-steward.md` → Ticket Description Template and `rules/agents.md` → Ticket Description Quality).
- Sets priority based on investigation findings
- Posts investigation findings as the first comment

If a Jira ticket already exists:
- If assigned to someone else, this is a **Conflict** ask (`rules/autonomy.md`) — taking a ticket another person holds collides with their claim on the work. Warn, then AskUserQuestion with header `Conflict`. Only proceed with assignment if the user confirms. If declined, continue without reassigning.
- If unassigned or reassignment approved, assign to current user: spawn `jira-workflow-steward` (Haiku) with `acli jira workitem assign --key [TICKET] --assignee @me -y`
- Post investigation findings as a comment via a second `jira-workflow-steward` (Haiku) spawn

**⛔ BLOCKING — before proceeding to Step 2.5:**
1. Ticket created or assigned
2. Investigation findings posted as Jira comment
3. Handover entry written
4. Phase summary shown to user

### Step 2.5 — Branch Creation

Create the branch AFTER the ticket exists:
- `git checkout -b bugfix/[TICKET-ID]-[slug-from-title]`
- If no ticket, use descriptive slug: `bugfix/description-slug`
- If the current branch is auto-generated (matches `claude/*` pattern), rename it: `git branch -m bugfix/[TICKET-ID]-[slug-from-title]`

### Step 2.6 — Discovery Comment

Spawn `jira-workflow-steward` (Haiku) with `phase=discovery` to post the Jira comment with scope and investigation plan. This is the formal "investigation started" marker on the board.

**⛔ BLOCKING — before proceeding to Step 2.7:**
1. Discovery phase comment posted via jira-workflow-steward
2. Handover entry for discovery written
3. Phase summary shown to user

### Step 2.7 — Execution Plan

**Agent:** `chief-of-staff` (deep-reasoning tier — see `rules/performance.md`)

After discovery, spawn chief-of-staff to create the execution plan — same as `/flow` Step 1.8. Chief-of-staff reads the ticket and investigation findings, then assigns agents and models for each remaining phase (implementation, code review, verification, PR creation). The orchestrator follows this plan — it does NOT select agents or models itself.

**Phase summary gate:** Include: execution plan, agent assignments, model routing. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`).

### Step 2.8 — Streamlined-plus Scope Expansion

Since `/bug` skips brainstorming and full planning, the streamlined-plus scope expansion check applies. Run `rg -n "<axis>"` for any discrete axis the fix touches (env key, config name, status enum, feature flag, etc.) to surface cross-file callsites. Treat ripgrep exit code 1 (no matches) as a valid outcome, not a failure — it means no additional callsites exist for this axis. See `/flow` Step 6.5 and `rules/development-workflow.md` Step 1a for the full process.

**Hard rule:** orchestrator inline only (grep, then the stated default — out of scope, file the followup — reported in the State block), NO agent spawn. Total cost target: <30 seconds. Ask only if a callsite makes the fix wrong as shipped (**Scope**).

### Step 3 — Beads Issue

If Beads tracking is enabled in PROJECT.md, create a new Beads issue linked to the Jira ticket:

1. Check if `.beads/` exists. If NOT, run the `bd init` the gitignore pre-check script in the **`workflow-discipline` skill** (§ "Gitignore pre-check") (verify gitignore + no tracked files). Only if the pre-check passes, run `Bash(bd init)` (automatic, don't ask). If the pre-check or `bd init` fails, warn the user and continue without Beads — **skip steps 2 and 3 entirely**.
2. Create the issue: `Bash(bd create --title "[TICKET] [title]" --type bug --priority 2 -d "[description]")`
3. Update status: `Bash(bd update [BEAD_ID] --status in_progress)`

**Beads lifecycle:** Create + in_progress at Step 3, close at Step 10 (PR). See `/flow` Step 4 for the full Beads command reference.

### Step 4 — Confirmation Summary

```
-----------------------------------------
  Work Summary — please confirm
-----------------------------------------
  [1]  Ticket:    DEV-5680 (auto-created)
  [2]  Title:     Auth redirect loop on login
  [3]  Type:      Bug
  [4]  Priority:  High
  [5]  Workflow:  /bug
  [6]  Branch:    bugfix/DEV-5680-auth-redirect-loop
  [7]  Beads:     New issue created
  [8]  Skipping:  Brainstorming, full planning
  [9]  Integrations: Jira (acli), Seq, Beads
  [10] Board:     DEV board 309

  [ENTER] Confirm and start
  [E]     Edit field(s)
  [Q]     Quit
-----------------------------------------
```

### Step 5 — Fix Implementation

Once root cause is identified:

1. **`tdd-guide` (Opus):** Write a failing test that reproduces the bug (RED)
2. **Implement the fix** (GREEN)
3. **Refactor if needed** (REFACTOR)

**Jira comment (if ticket exists):** Spawn `jira-workflow-steward` (Haiku) with phase=`in_progress` and comment: "🚀 Fix implemented — [summary of fix]. Tests: [count] passing. Branch: [branch name]."

**⛔ BLOCKING — before proceeding to Step 6:**
1. Jira comment for implementation phase posted via jira-workflow-steward
2. Handover entry for this phase written
3. Phase summary shown to user
4. Gate resolved — a category-ask answer OR `auto-continued under autonomy rule`, recorded in the handover (both are valid evidence)

**Phase summary gate:** Include: fix summary, test coverage, regression risk. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`).

### Step 6 — Code Review (via `code-review-orchestration` skill)

Invoke the `code-review-orchestration` skill — do NOT spawn chief-of-staff or review agents directly. The skill handles orchestration (see `rules/agents.md` and `skills/code-review-orchestration/SKILL.md`).
Invoke via an Opus subagent with `[DELEGATED]` marker — see `/flow` Step 9 for the delegation pattern.

Same conditional agent triggers and parallel execution rules as `/flow` — chief-of-staff decides which agents run based on files changed.

**Jira comment (if ticket exists):** Spawn `jira-workflow-steward` (Haiku) with phase=`code_review` and comment: "🔍 Code Review — Grade [A-F]. [key findings]. Agents run: [list]."

**⛔ BLOCKING — before proceeding to Step 7:**
1. Jira comment for code review phase posted via jira-workflow-steward
2. Handover entry for this phase written
3. Phase summary shown to user
4. Gate resolved — a category-ask answer OR `auto-continued under autonomy rule`, recorded in the handover (both are valid evidence)

**Phase summary gate:** Include: agents run, grades, findings. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`).

### Step 7 — Verification Before Completion

**Skill:** `verification-before-completion`

Confirms the fix actually resolves the bug end-to-end:
- Original reproduction steps no longer reproduce the bug
- No regression in related functionality
- All tests pass

**Jira comment (if ticket exists):** Spawn `jira-workflow-steward` (Haiku) with comment: "✅ Verification — Bug reproduction test: [pass/fail]. All tests: [count] passing. No regressions."

**⛔ BLOCKING — before proceeding to Step 8:**
1. Jira comment for verification phase posted via jira-workflow-steward
2. Handover entry for this phase written
3. Phase summary shown to user
4. Gate resolved — a category-ask answer OR `auto-continued under autonomy rule`, recorded in the handover (both are valid evidence)

**Phase summary gate:** Include: verification results, reproduction test outcome. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`).

### Step 8 — Reality Checker

**Agent:** `reality-checker` (Opus)

Production readiness gate. Signs off or blocks.

**Phase summary gate:** Include: reality checker verdict, blockers. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`).

### Step 8.5 — Compliance Audit

Before PR creation, run an independent compliance audit subagent — same as `/flow` Step 15 — the orchestrator spawns and AWAITS it; the PR-creation subagent must not spawn it (it cannot await a grandchild). The audit verifies: phase comments posted, handover entries written, model routing followed, code review via skill (not inline). The audit must pass before `finishing-a-development-branch` proceeds.

### Step 9 — PR Creation and Stop

**Skill:** `finishing-a-development-branch` (Opus)

**Auto-poll:** schedule the `/review-pr` 1-minute cron and handle reviewer comments inline per `rules/git-workflow.md` "Auto-Poll After PR Creation" (cron is best-effort; inline handling is the reliable path). Applies to ALL commands that create PRs.

Push and PR creation require consent — standing or per-action (`rules/git-workflow.md` → "Pull Requests"). Under standing consent, push and create the PR and report it in the State block. Otherwise ask ONCE per branch via AskUserQuestion (header `Irreversible`) with options:
- "Push and create PR"
- "Let me review first"
- "Keep branch"
- "Discard"

If the user confirms:
- Creates PR with bug description, root cause analysis, and fix summary

If a Jira ticket exists (session-level token — no re-touch needed if still valid):
- `jira-workflow-steward` (Haiku) links the PR to the ticket and posts final comment: "🔗 PR — [link]. Root cause: [summary]. Fix: [summary]. Tests: [count] passing."
- Transition ticket to `ready_for_release` via `jira-workflow-steward` (Haiku) with `phase=ready_for_release` (if the phase map has this column). The agent stops at Ready for Release — Done is a human step (stage deploy + manual testing) the user handles after manually merging the PR.
- Close the Beads issue: `Bash(bd close [BEAD_ID])` with a summary of the root cause and fix

**The agent stops here.** Offer to pick up the next ticket.

---

## Agent and Skill Usage

| Step | Agent/Skill | Model |
|---|---|---|
| Systematic investigation | `systematic-debugging` skill | Opus |
| Seq log queries | Seq | — |
| Jira ticket creation | `jira-workflow-steward` | Haiku |
| TDD enforcement | `tdd-guide` | Opus |
| Code review | `code-reviewer` | Opus |
| Conditional agents | Same rules as `/flow` | Same as `/flow` |
| Verification | `verification-before-completion` skill | — |
| Reality checker | `reality-checker` | Opus |
| PR creation | `finishing-a-development-branch` skill | Opus |
| Jira link PR | `jira-workflow-steward` | Haiku |
| Git commits | — | Haiku |

---

## Notes

- `/bug` includes full root-cause investigation and verification; `/hotfix` shortens it further — for urgent fixes, use `/hotfix` instead
- The systematic debugging skill is different from ECC's `build-error-resolver` — systematic-debugging handles runtime bugs; build-error-resolver handles compile errors
- Seq queries are automatic if Seq is configured — the agent does not need to be told to check logs
- The agent creates the Jira ticket automatically at Step 2 — but only AFTER investigation findings are approved at Step 1.6
- The Jira delegation token is session-level — create it once at the start of Phase B with `touch ~/.claude/.jira-delegation-token` (valid for 3600 seconds, not consumed on use). Subsequent jira-workflow-steward spawns within the same workflow do not need to re-create it.
