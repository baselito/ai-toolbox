# /security — Dedicated Security Scan

Full OWASP security scan with severity-graded report. Use before releases, after dependency updates, or for dedicated security hardening. Fixes critical issues if found, creates PR only if fixes are made.

---

> **Edge cases:** If something goes wrong (service unreachable, empty results, user rejects, mid-workflow failure), follow the always-loaded general rules in `rules/edge-cases.md` and load the `edge-cases` skill for the scenario playbooks. Never fail silently — always offer alternatives.

## Trigger

- Run manually: `/security`
- Auto-routed from `/start` when the user picks "Security scan"
- Auto-routed from `/start` when Jira ticket type is Security / Compliance

---

## Prerequisites

- `.claude/PROJECT.md` must exist — if not, the agent runs `/init` automatically
- **First time running `/security`:** The agent asks where security tickets go (see `/init` — Board Mapping)

---

## Workflow

### Step 0 — Pre-flight (runs regardless of entry point)

This step runs every time `/security` is invoked — whether from `/start`, directly, or via `/security TASK-741`. It ensures the Jira lifecycle, branch naming, and Beads tracking are initialized even if `/start` was skipped.

0. **Workflow marker:** `touch ~/.claude/.workflow-started` — gates branch creation via `enforce-workflow-start.sh` hook.

1. **PROJECT.md check:** If `.claude/PROJECT.md` doesn't exist, run `/init` automatically.

2. **Ticket read (read-only):** If a Jira ticket ID was provided (e.g. `/security TASK-741`):
   - Read the ticket: `Bash(acli jira workitem view [TICKET] --json)` — note: `view` takes a positional key, NOT `--key`
   - Do NOT assign yet — assignment happens after scan scope confirmation (Step 2)
   - If assigned to someone else, warn before reassigning — a **Conflict** ask (header `Conflict`) after scan scope confirmation

3. **Phase-map validation:** If a ticket exists, read `jira_phase_map` from PROJECT.md. If not set, run the phase-map setup from `/init` Sub-step 1e. Validate mapped columns still exist on the live board (same drift check as `/flow` Step 0).

4. **Branch naming:** Branch is only created if fixes are needed (Step 6). At pre-flight, just validate the branch convention will be `security/[TICKET-ID]-[slug]` or `security/fix-critical-YYYY-MM-DD`.

5. **Discovery comment:** Deferred to Step 2 — posted after the user confirms scan scope, not during pre-flight. Pre-flight is read-only (no delegation token exists yet).

6. **Gitignore pre-check:** Verify toolbox files (`.beads/`, `AGENTS.md`, `CLAUDE.md`, `.claude/`, `ai-engineering/`) are in `.gitignore` and not already tracked by git. See the `workflow-discipline` skill (Rule 5 detail) for the full pre-check script. If any are tracked, run `git rm --cached -r <files>` before proceeding.

7. **Handover init:** Read `.claude/handover.md` if it exists (resuming interrupted work). If starting fresh, clear it and write the initial entry:
   ```
   ## Pre-flight — /security [TICKET]
   Completed: [timestamp]
   Status: PASSED
   ### What was done
   - Ticket read (not yet assigned), scan scope not yet set
   ```

After pre-flight completes, proceed to Step 1.

### Step 1 — Scan Scope

The agent asks what to scan:

```
What do you want to scan?

1) Full codebase — complete OWASP scan
2) A specific file or folder — enter path
3) Recent changes only — since last release tag
4) Dependency audit — check for known
   vulnerabilities in packages
```

### Step 2 — Confirmation Summary

```
-----------------------------------------
  Work Summary — please confirm
-----------------------------------------
  [1]  Scope:     Full codebase
  [2]  Type:      Security scan
  [3]  Workflow:  /security
  [4]  Skipping:  Branch creation (unless fixes needed)
  [5]  Integrations: GitHub

  [ENTER] Confirm and start
  [E]     Edit field(s)
  [Q]     Quit
-----------------------------------------
```

**After user confirms scan scope, if a Jira ticket was provided:**
- **Jira delegation token:** `touch ~/.claude/.jira-delegation-token` (session-level, valid for 3600 seconds, not consumed on use)
- If assigned to someone else, this is a **Conflict** ask (`rules/autonomy.md`) — taking a ticket another person holds collides with their claim on the work. Warn, then AskUserQuestion with header `Conflict`. Only proceed with assignment if the user confirms. If declined, continue without reassigning.
- If unassigned or reassignment approved, assign to current user: spawn `jira-workflow-steward` (Haiku)
- **Discovery comment:** Spawn `jira-workflow-steward` (Haiku) with `phase=discovery` to post the initial Jira comment with scan scope and security posture context.

If no Jira ticket was provided, skip all Jira operations and continue to Step 2.5.

### Step 2.5 — Execution Plan

**Agent:** `chief-of-staff` (deep-reasoning tier — see `rules/performance.md`)

Spawn chief-of-staff to create the execution plan — same as `/flow` Step 1.8. Chief-of-staff assigns agents and models for scan, review, fix, and PR phases.

### Step 3 — Security Engineer Scan

**Agent:** `security-engineer` (deep-reasoning tier — see `rules/performance.md`)

The Security Engineer runs a comprehensive scan:

1. **OWASP Top 10 compliance check** — full list in `rules/security.md`
2. **Architecture-level review** — IAM, zero-trust, OAuth/RBAC, secrets management, threat modelling
3. **Code-level scan** — hardcoded secrets, insecure direct object references, missing validation, unsafe deserialization, unprotected endpoints

**Jira comment:** If a ticket exists, spawn `jira-workflow-steward` (Haiku) with phase=`in_progress` and comment: "🔍 Security Engineer Scan — CRITICAL: [count]. HIGH: [count]. MEDIUM: [count]. LOW: [count]. OWASP categories checked: 10."

**Phase summary gate:** Include: findings by severity (CRITICAL/HIGH/MEDIUM/LOW), OWASP coverage, most concerning items. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`).

### Step 4 — Security Reviewer Scan

**Agent:** `security-reviewer` (Opus)

Runs after security-engineer (sequential — engineer first, reviewer second):
- Vulnerability pattern scanning
- Permission and injection risk analysis
- Dependency vulnerability check
- Configuration file audit

### Step 5 — Severity Report

```
-----------------------------------------
  Security Report
-----------------------------------------
  Scope:     Full codebase scan
  Date:      2026-03-17

  CRITICAL (must fix immediately):
  - SQL injection risk in UserController.cs
    line 87 — raw string concatenation in query

  HIGH (fix before next release):
  - API key exposed in appsettings.Development.json
  - Missing rate limiting on /api/auth/login

  MEDIUM (should fix):
  - CORS policy too permissive in Startup.cs
  - Session timeout set to 24h (recommend 1h)

  LOW (advisory):
  - Consider adding CSP headers
  - Audit log retention could be extended

  OWASP COMPLIANCE:
  [checkmark] Injection — 1 CRITICAL finding
  [checkmark] Authentication — PASS
  [checkmark] Sensitive Data — 1 HIGH finding
  [checkmark] XXE — PASS
  [checkmark] Access Control — PASS
  [checkmark] Misconfiguration — 1 MEDIUM finding
  [checkmark] XSS — PASS
  [checkmark] Deserialization — PASS
  [checkmark] Known Vulnerabilities — PASS
  [checkmark] Logging — 1 LOW finding
-----------------------------------------
```

**Jira comment:** If a ticket exists, spawn `jira-workflow-steward` (Haiku) with comment: "📋 Severity Report — CRITICAL: [count]. HIGH: [count]. MEDIUM: [count]. LOW: [count]. [summary of most urgent findings]."

**Phase summary gate:** Include: combined severity report, recommended fix order. Then proceed (autonomy rule); ask only on BLOCKED or a category question (`rules/autonomy.md`).

### Step 6 — Fix Critical Issues (if any)

If CRITICAL issues are found:

1. The agent asks the user for permission to fix them
2. Creates a branch: `security/fix-critical-YYYY-MM-DD`
3. `tdd-guide` (Opus) — write tests for each fix
4. Implement fixes
5. Invoke `code-review-orchestration` skill for review (do NOT spawn review agents directly)
Invoke via an Opus subagent with `[DELEGATED]` marker — see `/flow` Step 9.
6. `reality-checker` (Opus) signs off (selected by chief-of-staff via the skill)

**Jira comment:** If a ticket exists, spawn `jira-workflow-steward` (Haiku) with phase=`code_review` and comment: "🔍 Code Review — Grade [A-F]. Fixes: [CRITICAL count] CRITICAL issues resolved. Tests: [count] passing."

**Skill:** `verification-before-completion` — invoke via an Opus subagent with `[DELEGATED]` marker before PR creation.

**Jira comment (after the skill returns):** If a ticket exists, spawn `jira-workflow-steward` (Haiku) with comment: "✅ Verification — All fixes verified. Tests: [count] passing. No regressions."

### Step 6.5 — Compliance Audit

Before PR creation, run an independent compliance audit subagent — same as `/flow` Step 15 — the orchestrator spawns and AWAITS it; the PR-creation subagent must not spawn it (it cannot await a grandchild).

### Step 7 — PR (only if fixes were made)

**Skill:** `finishing-a-development-branch` (Opus)

If fixes were implemented:
- Creates PR with security report and fix details. If a Jira ticket was auto-created (no ticket was provided at start), pass structured content (Background, Scope, Acceptance Criteria) to `jira-workflow-steward`, which applies the Ticket Description Template (see `agents/jira-workflow-steward.md` → Ticket Description Template and `rules/agents.md` → Ticket Description Quality).

**Auto-poll:** schedule the `/review-pr` 1-minute cron and handle reviewer comments inline per `rules/git-workflow.md` "Auto-Poll After PR Creation" (cron is best-effort; inline handling is the reliable path). Applies to ALL commands that create PRs.
- `jira-workflow-steward` (Haiku) creates/updates security ticket and posts final comment: "🔗 PR — [link]. Fixed: [CRITICAL count] CRITICAL, [HIGH count] HIGH. Tests: [count] passing."
- If a ticket exists, transition ticket to `ready_for_release` via `jira-workflow-steward` (Haiku) with phase=`ready_for_release` (if the phase map has this column)
- Beads lifecycle:
  1. Check if `.beads/` exists. If NOT, run the `bd init` the gitignore pre-check script in the **`workflow-discipline` skill** (§ "Gitignore pre-check") (verify gitignore + no tracked files); only if the pre-check passes, run `Bash(bd init)`. If the pre-check fails, warn and continue without Beads. **If continuing without Beads, skip steps 2-4 entirely.**
  2. Create the issue: `Bash(bd create --title "Security fix [date]" --type task --priority 1 -d "[severity report summary]")`
  3. Update status: `Bash(bd update [BEAD_ID] --status in_progress)`
  4. Close after PR: `Bash(bd close [BEAD_ID])` with a summary of findings and fixes applied

If no fixes were made (report only), no PR is created. If Beads is enabled, still create and immediately close a Beads issue to record the scan: `bd create` then `bd close [ID]` with the report summary.

**Beads lifecycle:** Create + in_progress and close both happen at Step 7 (fixes are only known to exist by then). See `/flow` Step 4 for the full Beads command reference.

---

## Agent and Skill Usage

| Step | Agent/Skill | Model |
|---|---|---|
| Architecture scan | `security-engineer` | Deep-reasoning tier (see `rules/performance.md`) |
| Code scan | `security-reviewer` | Opus |
| TDD (if fixing) | `tdd-guide` | Opus |
| Code review (if fixing) | `code-reviewer` | Opus |
| Reality checker | `reality-checker` | Opus |
| PR creation (if fixing) | `finishing-a-development-branch` skill | Opus |
| Jira (if fixing) | `jira-workflow-steward` | Haiku |

---

## Notes

- `/security` can be run as a standalone scan (report only) or as a fix workflow (report + fix)
- The security-engineer (deep-reasoning tier) handles architecture-level analysis; security-reviewer (Opus) handles code-level scanning — they are complementary
- Use `/security` before major releases or after dependency updates
- For projects with "Security / compliance hardening" project type, `/security` should be run regularly
- The report can be exported or shared with the team via the Jira ticket
