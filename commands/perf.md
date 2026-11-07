# /perf — Performance Investigation

Investigate and fix performance issues — slow APIs, DB queries, pipelines, or frontend rendering. Not broken, just slow. Queries Seq for response time patterns, uses systematic debugging to trace root cause.

---

> **Edge cases:** If something goes wrong (service unreachable, empty results, user rejects, mid-workflow failure), follow the always-loaded general rules in `rules/edge-cases.md` and load the `edge-cases` skill for the scenario playbooks. Never fail silently — always offer alternatives.

## Trigger

- Run manually: `/perf`
- Auto-routed from `/start` when the user picks "Something is slow — performance investigation"
- Auto-routed from `/start` when Jira ticket type is Performance

---

## Prerequisites

- `.claude/PROJECT.md` must exist — if not, the agent runs `/init` automatically
- Seq should be configured for log and timing queries (optional but significantly improves diagnosis)

---

## Workflow

### Step 0 — Pre-flight (runs regardless of entry point)

This step runs every time `/perf` is invoked — whether from `/start`, directly, or via `/perf TASK-741`. It ensures the Jira lifecycle, branch naming, and Beads tracking are initialized even if `/start` was skipped.

0. **Workflow marker:** `touch ~/.claude/.workflow-started` — gates branch creation via `enforce-workflow-start.sh` hook.

1. **PROJECT.md check:** If `.claude/PROJECT.md` doesn't exist, run `/init` automatically.

1b. **Gitignore pre-check:** Verify toolbox files (`.beads/`, `AGENTS.md`, `CLAUDE.md`, `.claude/`, `ai-engineering/`) are in `.gitignore` and not already tracked by git. See `rules/workflow-discipline.md` Rule 5.

2. **Ticket read (read-only):** If a Jira ticket ID was provided (e.g. `/perf TASK-741`):
   - Read the ticket: `Bash(acli jira workitem view [TICKET] --json)` — note: `view` takes a positional key, NOT `--key`
   - Do NOT assign yet — assignment happens after confirmation (Step 2)
   - If assigned to someone else, warn before reassigning — a **Conflict** ask (header `Conflict`) after Step 2

3. **Phase-map validation:** If a ticket exists, read `jira_phase_map` from PROJECT.md. If not set, run the phase-map setup from `/init` Sub-step 1e. Validate mapped columns still exist on the live board (same drift check as `/flow` Step 0).

4. **Branch naming:** If the current branch is auto-generated (matches `claude/*` pattern), rename it to follow conventions:
   - `git branch -m perf/[TICKET-ID]-[slug-from-title]`
   - If no ticket, use descriptive slug: `perf/description-slug`

5. **Discovery comment:** Deferred to Step 2 — posted after the user confirms at the confirmation summary, not during pre-flight. Pre-flight is read-only (no delegation token exists yet).

6. **Handover init:** Read `.claude/handover.md` if it exists (resuming interrupted work). If starting fresh, clear it and write the initial entry:
   ```
   ## Pre-flight — /perf [TICKET]
   Completed: [timestamp]
   Status: PASSED
   ### What was done
   - Ticket read (not yet assigned)
   ```

After pre-flight completes, proceed to Step 1.

### Step 1 — Performance Intake

The agent asks the user to describe the issue:

```
What is running slow?

1) An API endpoint — enter the route or URL
2) Database queries — general slowness or specific query
3) Frontend rendering — specific page or component
4) CI/CD pipeline — builds taking too long
5) General — describe the issue
```

### Step 2 — Confirmation Summary

```
-----------------------------------------
  Work Summary — please confirm
-----------------------------------------
  [1]  Issue:     /api/users endpoint responding
                  in 3.2s (expected <500ms)
  [2]  Type:      Performance
  [3]  Workflow:  /perf
  [4]  Branch:    perf/api-users-slow-response
  [5]  Beads:     New issue created
  [6]  Integrations: Seq, GitHub, Beads

  [ENTER] Confirm and start
  [E]     Edit field(s)
  [Q]     Quit
-----------------------------------------
```

**After user confirms, if a Jira ticket was provided:**
- **Jira delegation token:** `touch ~/.claude/.jira-delegation-token` (session-level, valid for 3600 seconds, not consumed on use)
- If assigned to someone else, this is a **Conflict** ask (`rules/autonomy.md`) — taking a ticket another person holds collides with their claim on the work. Warn, then AskUserQuestion with header `Conflict`. Only proceed with assignment if the user confirms. If declined, continue without reassigning.
- If unassigned or reassignment approved, assign to current user: spawn `jira-workflow-steward` (Haiku)
- **Discovery comment:** Spawn `jira-workflow-steward` (Haiku) with `phase=discovery` to post the initial Jira comment with performance issue scope and target metrics.

If no Jira ticket was provided, skip all Jira operations and continue to Step 2.5.

### Step 2.5 — Execution Plan

**Agent:** `chief-of-staff` (deep-reasoning tier — see `rules/performance.md`)

Spawn chief-of-staff to create the execution plan — same as `/flow` Step 1.8. Chief-of-staff assigns agents and models for investigation, benchmarking, fix, review, and PR phases.

**Beads issue creation (after confirmation):**

If Beads tracking is enabled in PROJECT.md:

1. Check if `.beads/` exists. If NOT, run the `bd init` the gitignore pre-check script in the **`workflow-discipline` skill** (§ "Gitignore pre-check") (verify gitignore + no tracked files); only if the pre-check passes, run `Bash(bd init)` (automatic, don't ask). If the pre-check fails, warn the user and continue without Beads. If `bd init` itself fails, warn and continue without Beads. **If continuing without Beads, skip steps 2 and 3 entirely.**
2. Create the issue: `Bash(bd create --title "[description slug]" --type task --priority 2 -d "[performance issue description]")`
3. Update status: `Bash(bd update [BEAD_ID] --status in_progress)`

**Beads lifecycle:** Create + in_progress at Step 2, close at Step 11. See `/flow` Step 4 for the full Beads command reference.

### Step 3 — Seq Analysis

The agent queries Seq (user-configured MCP server) for performance patterns:

1. `seq_get_levels_summary` (fromMinutes: 60) — check for Warning/Error spikes that correlate with slowness
2. `seq_query_events` with filter on ElapsedMilliseconds or the affected endpoint — find slow request logs
3. `seq_group_errors` — check if errors are contributing to retries/timeouts
4. `seq_get_error_events` — drill into timeout/exception patterns if found

**What to look for:**
- Average response time for the affected endpoint/query
- Response time trends (getting worse? stable? intermittent?)
- Slow query logs (ElapsedMilliseconds)
- Error correlation with slowness
- Comparison with other endpoints/queries for baseline

If Seq is not configured or the Docker service is not running, the agent uses local profiling and asks the user for any available timing data.

**Jira comment:** If a ticket exists, spawn `jira-workflow-steward` (Haiku) with phase=`in_progress` and comment: "🔍 Seq Analysis — [performance pattern summary]. Baseline: [metrics]. Likely root cause direction: [summary]."

**Phase summary gate:** Include: Seq findings, response time patterns, root cause direction. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`).

### Step 4 — API Tester Validation

**Agent:** `api-tester` (Opus)

If the issue is an API endpoint:
- Validates current endpoint performance with test requests
- Measures response times under different conditions
- Identifies payload size or parameter patterns that trigger slowness

### Step 5 — Systematic Debugging

**Skill:** `systematic-debugging` (Opus — no escalation; the invoking subagent is already Opus — see `rules/performance.md`)

Root cause analysis for the performance issue:

1. **Gather evidence:** Seq data, profiling results, API tester findings
2. **Form hypotheses:** Missing index, N+1 query, unoptimised serialisation, missing cache, etc.
3. **Test hypotheses:** Profile specific code paths, run explain plans on queries
4. **Identify root cause:** Confirm with evidence

**Jira comment:** If a ticket exists, spawn `jira-workflow-steward` (Haiku) with comment: "🔍 Root Cause — [confirmed root cause]. Evidence: [key findings]. Expected improvement: [estimate]."

**Phase summary gate:** Include: root cause with evidence, eliminated alternatives, expected improvement. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`).

### Step 6 — DevOps Check (if pipeline performance)

**Agent:** `devops-automator` (Opus)

If the issue is CI/CD pipeline timing:
- Analyses pipeline configuration
- Identifies bottleneck stages
- Suggests parallelisation or caching improvements

### Step 6.5 — Performance Benchmarking

**Agent:** `performance-benchmarker` (Opus)

Before fixing anything, the performance benchmarker establishes baselines:
- Measures current response times (p50, p95, p99)
- Records throughput under expected load
- Captures Core Web Vitals if frontend performance is involved
- Documents the methodology so results are reproducible

These baselines are used for before/after comparison after the fix.

### Step 7 — Fix Implementation

Once root cause is identified:

1. `tdd-guide` (Opus) — write a performance test that quantifies the improvement
2. Implement the fix
3. `performance-benchmarker` (Opus) — re-run benchmarks to produce before/after comparison
4. Verify the improvement meets the target

**Jira comment:** If a ticket exists, spawn `jira-workflow-steward` (Haiku) with comment: "🚀 Fix implemented — [summary]. Before: [baseline metrics]. After: [improved metrics]. Target met: [yes/no]. Branch: [branch name]."

**Phase summary gate:** Include: before/after benchmarks, target met (yes/no), trade-offs. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`).

### Step 8 — Code Review (via `code-review-orchestration` skill)

Invoke the `code-review-orchestration` skill — do NOT spawn chief-of-staff or review agents directly. The skill handles orchestration (see `rules/agents.md` and `skills/code-review-orchestration/SKILL.md`).
Invoke via an Opus subagent with `[DELEGATED]` marker — see `/flow` Step 9.

Same conditional agent triggers and parallel execution rules as `/flow` — chief-of-staff decides which agents run based on files changed.

**Jira comment:** If a ticket exists, spawn `jira-workflow-steward` (Haiku) with phase=`code_review` and comment: "🔍 Code Review — Grade [A-F]. [key findings]. Agents run: [list]."

### Step 9 — Verification

**Skill:** `verification-before-completion`

Confirms:
- Performance is improved to target levels
- No regressions introduced
- All tests pass

**Jira comment:** If a ticket exists, spawn `jira-workflow-steward` (Haiku) with comment: "✅ Verification — All tests: [count] passing. Performance target: [met/not met]. No regressions."

**Phase summary gate:** Include: verification results, performance target met, regressions. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`).

### Step 10 — Reality Checker

**Agent:** `reality-checker` (Opus)

Signs off or blocks.

### Step 10.5 — Compliance Audit

Before PR creation, run an independent compliance audit subagent — same as `/flow` Step 15 — the orchestrator spawns and AWAITS it; the PR-creation subagent must not spawn it (it cannot await a grandchild).

### Step 11 — PR and Cleanup

**Skill:** `finishing-a-development-branch` (Opus)

**Auto-poll:** schedule the `/review-pr` 1-minute cron and handle reviewer comments inline per `rules/git-workflow.md` "Auto-Poll After PR Creation" (cron is best-effort; inline handling is the reliable path). Applies to ALL commands that create PRs.

- Creates PR with performance analysis, root cause, and before/after metrics
- If a ticket exists, `jira-workflow-steward` (Haiku) updates ticket and posts final comment: "🔗 PR — [link]. Root cause: [summary]. Before: [metrics]. After: [metrics]. Tests: [count] passing."
- If a ticket exists, transition ticket to `ready_for_release` via `jira-workflow-steward` (Haiku) with phase=`ready_for_release` (if the phase map has this column)
- Close the Beads issue: `Bash(bd close [BEAD_ID])` with a summary of root cause and before/after performance data

---

## Agent and Skill Usage

| Step | Agent/Skill | Model |
|---|---|---|
| Seq queries | Seq | — |
| API testing | `api-tester` | Opus |
| Systematic debugging | `systematic-debugging` skill | Opus |
| Performance benchmarking | `performance-benchmarker` | Opus |
| Pipeline analysis | `devops-automator` | Opus |
| TDD | `tdd-guide` + `test-driven-development` skill | Opus |
| Code review | `code-reviewer` | Opus |
| Database review (if DB) | `database-reviewer` | Opus |
| Accessibility (if UI) | `accessibility-auditor` | Opus |
| Verification | `verification-before-completion` skill | — |
| Reality checker | `reality-checker` | Opus |
| PR creation | `finishing-a-development-branch` skill | Opus |
| Jira cleanup | `jira-workflow-steward` | Haiku |
| Docs lookup (on demand) | `docs-lookup` | Sonnet |

---

## Notes

- `/perf` is for slowness, not breakage — use `/bug` if something is broken
- Seq integration makes diagnosis significantly faster — response time patterns often reveal the root cause before code analysis begins
- The API tester runs both before (to establish baseline) and after (to verify improvement) the fix
- For database performance issues, the database-reviewer checks for N+1 queries, missing indexes, and inefficient joins
- Performance tests written during the fix become part of the test suite to prevent future regressions
