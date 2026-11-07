# /incident — Production Incident Response

Emergency workflow for when production is actively down. Queries Seq logs immediately, runs full incident response protocol, restores service, and files a post-mortem automatically.

---

> **Edge cases:** If something goes wrong (service unreachable, empty results, user rejects, mid-workflow failure), follow the always-loaded general rules in `rules/edge-cases.md` and load the `edge-cases` skill for the scenario playbooks. Never fail silently — always offer alternatives.

## Trigger

- Run manually: `/incident`
- Auto-routed from `/start` when the user picks "Production is down right now"
- Auto-routed from `/start` when Jira ticket type is Incident / P1

---

## Prerequisites

- `.claude/PROJECT.md` must exist — if not, the agent runs `/init` automatically
- Seq should be configured for log queries (the agent can still operate without it but log analysis is limited to local files)
- **Gitignore pre-check:** Verify toolbox files (`.beads/`, `AGENTS.md`, `CLAUDE.md`, `.claude/`, `ai-engineering/`) are in `.gitignore` and not already tracked by git. See the `workflow-discipline` skill (Rule 5 detail) for the full pre-check script. If any are tracked, run `git rm --cached -r <files>` before proceeding.

---

## Workflow

### Step 0 — Pre-flight (runs regardless of entry point)

This step runs every time `/incident` is invoked. Despite the urgency, pre-flight ensures coordination works.

0. **Workflow marker:** `touch ~/.claude/.workflow-started` — gates branch creation via `enforce-workflow-start.sh` hook.

1. **PROJECT.md check:** If `.claude/PROJECT.md` doesn't exist, run `/init` automatically.

2. **Phase-map validation:** If a ticket exists or will be created, read `jira_phase_map` from PROJECT.md. If not set, run the phase-map setup from `/init` Sub-step 1e. Validate mapped columns still exist on the live board (same drift check as `/flow` Step 0).

3. **Jira delegation token:** `touch ~/.claude/.jira-delegation-token` — session-level, valid for 3600 seconds, not consumed on use. Required before any jira-workflow-steward spawn.

4. **Handover init:** Read `.claude/handover.md` if it exists (resuming interrupted work). If starting fresh, clear it and write the initial entry. All entries must include the `### Deviations` field per `rules/handover.md`.

After pre-flight completes, proceed to Step 1.

### Step 1 — Immediate Triage

**Agent:** `incident-response-commander` (Opus)

The Incident Response Commander takes control immediately:

1. **Acknowledge:** Confirm the incident with the user
2. **Classify severity:** P1 (service down), P2 (degraded), P3 (partial impact)
3. **Start timeline:** Begin recording all actions with timestamps

### Step 2 — Seq Log Query

Use a configured, user-managed Seq MCP server only after checking its tools and redaction policy. Otherwise inspect local logs or sanitized exports.

**Query sequence (3 calls in order):**

1. **Health check:** `seq_get_levels_summary` (fromMinutes: 30) — quick count of Warning/Error/Fatal in the last 30 minutes
2. **Triage:** `seq_group_errors` (fromMinutes: 60) — errors ranked by priority (level × environment × count). Identifies the top error groups to investigate.
3. **Drill-down:** `seq_get_error_events` (eventType: top error's @i hex ID, contextMinutes: 5) — fetches error occurrences with surrounding context timeline

**Optional:**
- `seq_query_events` with a filter expression for cross-service correlation
- `seq_get_signals` to discover existing saved filters in Seq

If Seq is not configured or the Docker service is not running, the agent reads local log files and asks the user for any available error output.

### Step 3 — Confirmation (brief)

```
-----------------------------------------
  Incident Response — confirm
-----------------------------------------
  Severity:   P1 — service down
  First seen: 14:23 UTC (Seq)
  Errors:     NullReferenceException in
              PaymentController.Process()
  Likely:     Recent deployment (14:15 UTC)
  Branch:     incident/P1-payment-service-down

  [ENTER] Proceed with investigation
  [R]     Rollback immediately (if recent deploy)
  [Q]     Cancel
-----------------------------------------
```

If the user selects `[R]` (rollback), the `devops-automator` (Opus) triggers an immediate rollback to the previous deployment and the agent monitors for recovery.

### Step 3.5 — Execution Plan

**Agent:** `chief-of-staff` (deep-reasoning tier — see `rules/performance.md`)

Even in incident response, chief-of-staff creates the execution plan — assigning agents and models for investigation, fix, verification, and PR phases. The orchestrator follows this plan. Speed is still the priority, but the plan prevents the orchestrator from skipping review agents or using wrong models under time pressure.

### Step 4 — Root Cause Investigation

**Skill:** `systematic-debugging` (Opus — no escalation; the invoking subagent is already Opus — see `rules/performance.md`)

Combined with continuous Seq monitoring:
- Correlate error patterns with recent changes
- Identify the specific commit or configuration change that caused the issue
- Trace the error path through the system

**Jira comment:** If a ticket exists, spawn `jira-workflow-steward` (Haiku) with phase=`in_progress` and comment: "🔍 Investigation — Root cause: [summary]. Evidence: [key findings]. Confidence: [level]."

**Phase summary gate:** Follow `rules/agents.md` phase summary card format, then continue with the fix — restoring service is the goal, and choosing to proceed is not an ask. **Escalating to a human on-call IS an ask** (`Blocked`), and so is any fix step touching production data (`Irreversible`).

### Step 5 — Fix and Restore Service

Priority is restoring service, not writing perfect code:

1. Implement the minimal fix to restore service
2. `tdd-guide` (Opus) — write a test that reproduces the failure
3. Verify service is restored (health checks, Seq error rate dropping)

**Jira comment:** If a ticket exists, spawn `jira-workflow-steward` (Haiku) with comment: "🚀 Fix implemented — [summary]. Service status: [restored/partial]. Tests: [count] passing."

**Phase summary gate:** Include: fix summary, service status, test results. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`).

### Step 5.5 — Code Review (via `code-review-orchestration` skill)

Even emergency fixes go through code review. Invoke the `code-review-orchestration` skill via an Opus subagent with `[DELEGATED]` marker — do NOT spawn review agents directly. Chief-of-staff decides which agents run.

**Jira comment:** If a ticket exists, spawn `jira-workflow-steward` (Haiku) with phase=`code_review` and comment: "🔍 Code Review — Grade [A-F]. [key findings]. Agents run: [list]."

### Step 6 — Verification

**Skill:** `verification-before-completion` — invoke via an Opus subagent with `[DELEGATED]` marker, same as every other sibling command (`/bug`, `/hotfix`, `/perf`, `/refactor`). Incident speed does not exempt this step — the skill confirms the fix actually resolves the incident end-to-end (not just that code compiles), which matters more, not less, under time pressure.

**Agent:** `reality-checker` (Opus)

Confirms:
- Service is restored and healthy
- Error rates have returned to baseline
- No collateral damage to other services

**Jira comment (after both the skill and reality-checker return):** If a ticket exists, spawn `jira-workflow-steward` (Haiku) with comment: "✅ Verification — Service restored. Error rates at baseline. No collateral damage. All tests: [count] passing."

**Phase summary gate:** Include: verification results, service health. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`).

### Step 7 — DevOps Coordination

**Agent:** `devops-automator` (Opus)

- Coordinates the deployment of the fix
- Monitors the deployment for success
- Confirms pipeline passes

### Step 8 — Post-Mortem

The `incident-response-commander` (Opus) generates a structured post-mortem:

```
-----------------------------------------
  Post-Mortem — [INCIDENT-ID]
-----------------------------------------
  Severity:    P1
  Duration:    47 minutes
  Impact:      Payment processing unavailable
  Root cause:  Null reference in PaymentController
               after deploy at 14:15 UTC
  Fix:         Null check added, deployed at 15:02 UTC
  Timeline:
    14:15  Deploy triggered
    14:23  First errors in Seq
    14:35  Incident reported
    14:42  Root cause identified
    14:55  Fix implemented and tested
    15:02  Fix deployed, service restored

  Follow-up actions:
  1. Add integration test for payment null case
  2. Add deployment canary for payment service
  3. Review deploy rollback automation
-----------------------------------------
```

The post-mortem is:
- Filed to Beads:
  1. Check if `.beads/` exists. If NOT, run the `bd init` the gitignore pre-check script in the **`workflow-discipline` skill** (§ "Gitignore pre-check") (verify gitignore + no tracked files); only if the pre-check passes, run `Bash(bd init)` (automatic, don't ask). If the pre-check fails, warn the user and continue without Beads. If `bd init` itself fails, warn and continue without Beads. **If continuing without Beads, skip steps 2 and 3 entirely.**
  2. Create the issue: `Bash(bd create --title "[INCIDENT-ID] [summary]" --type bug --priority 1 -d "[post-mortem summary]")`
  3. Update status: `Bash(bd update [BEAD_ID] --status in_progress)`
- Added as a Jira comment (if Jira configured)
- Presented to the user for review

**Beads lifecycle:** Create + in_progress at Step 8, close at Step 9. See `/flow` Step 4 for the full Beads command reference.

### Step 8.5 — Compliance Audit

Before PR creation, run an independent compliance audit subagent — same as `/flow` Step 15. The audit verifies Jira milestone policy, handover entries, model routing, and code review via skill. The orchestrator spawns and AWAITS it; the PR-creation subagent must not spawn it (it cannot await a grandchild).

### Step 9 — PR Creation

**Skill:** `finishing-a-development-branch` (Opus)

**Auto-poll:** schedule the `/review-pr` 1-minute cron and handle reviewer comments inline per `rules/git-workflow.md` "Auto-Poll After PR Creation" (cron is best-effort; inline handling is the reliable path). Applies to ALL commands that create PRs.

Push and PR creation require consent — standing or per-action (`rules/git-workflow.md` → "Pull Requests"). Under standing consent, push and create the PR and report it in the State block. Otherwise ask ONCE per branch via AskUserQuestion (header `Irreversible`) with options:
- "Push and create PR"
- "Let me review first"
- "Keep branch"
- "Discard"

If the user confirms:
- Creates PR with incident description and fix summary
- `jira-workflow-steward` (Haiku) links the PR and post-mortem to the ticket
- Transition ticket to `ready_for_release` via `jira-workflow-steward` (Haiku) with `phase=ready_for_release` (if the phase map has this column). The agent stops at Ready for Release — Done is a human step.
- Close the Beads issue (only if Beads was initialized in Step 8): `Bash(bd close [BEAD_ID])` with a summary of the incident timeline and resolution. If the workflow continued without Beads, skip this step.

**The ticket moves to Ready for Release (or stays in In Progress if the board has no Ready for Release column).** Done is a human step (stage deploy + manual testing).

**The agent stops here.** Offer to pick up the next ticket.

---

## Agent and Skill Usage

| Step | Agent/Skill | Model |
|---|---|---|
| Pre-flight (Step 0) | orchestrator | Orchestrator tier (Fable by default) |
| Incident command (Step 1) | `incident-response-commander` | Opus |
| Seq queries (Step 2) | Seq | — |
| Execution plan (Step 3.5) | `chief-of-staff` | Deep-reasoning tier |
| Systematic debugging (Step 4) | `systematic-debugging` skill | Opus |
| Jira transitions and requested milestone updates (Steps 4–6) | `jira-workflow-steward` | Haiku |
| TDD (Step 5) | `tdd-guide` | Opus |
| Code review (Step 5.5) | `code-review-orchestration` skill | Opus (chief-of-staff: deep-reasoning tier) |
| Verification (Step 6) | `verification-before-completion` skill — via an Opus subagent with `[DELEGATED]` marker | Opus |
| Reality checker (Step 6) | `reality-checker` | Opus |
| Deployment (Step 7) | `devops-automator` | Opus |
| Post-mortem (Step 8) | `incident-response-commander` | Opus |
| Compliance audit (Step 8.5) | compliance audit subagent | Opus |
| PR creation (Step 9) | `finishing-a-development-branch` skill | Opus |
| Jira link PR / transition (Step 9) | `jira-workflow-steward` | Haiku |

---

## Notes

- `/incident` is for production-down situations — use `/hotfix` for urgent but not production-down issues
- The agent queries Seq before asking the user any questions — speed is the priority
- Rollback option is always available if the incident correlates with a recent deployment
- Post-mortem is generated automatically — the user does not need to write it
- Follow-up action items from the post-mortem can be turned into Jira tickets with user approval
