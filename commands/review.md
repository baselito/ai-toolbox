# /review — Code Quality and Security Review

Review existing code without making changes. Produces a quality and security report with severity grading. No PR created — this is read-only analysis.

---

> **Edge cases:** If something goes wrong (service unreachable, empty results, user rejects, mid-workflow failure), follow the always-loaded general rules in `rules/edge-cases.md` and load the `edge-cases` skill for the scenario playbooks. Never fail silently — always offer alternatives.

## Trigger

- Run manually: `/review`
- Auto-routed from `/start` when the user picks "Review existing code"
- Auto-routed from `/start` when Jira ticket type is Review / PR Review

---

## Prerequisites

- `.claude/PROJECT.md` must exist — if not, the agent runs `/init` automatically

---

## Workflow

### Step 1 — Review Scope

The agent asks what to review:

```
What do you want to review?

1) A pull request — enter PR number or URL
2) A specific file or folder — enter path
3) The whole codebase — full scan
4) Pre-release check — review everything
   changed since last release tag
```

### Step 2 — Confirmation Summary

```
-----------------------------------------
  Work Summary — please confirm
-----------------------------------------
  [1]  Scope:     PR #142 — Add loading spinner
  [2]  Type:      Review
  [3]  Workflow:  /review
  [4]  Skipping:  Branch creation, implementation,
                  PR creation
  [5]  Integrations: GitHub

  [ENTER] Confirm and start
  [E]     Edit field(s)
  [Q]     Quit
-----------------------------------------
```

### Step 3 — Code Review

**Skill:** `code-review-orchestration` — invoke the skill, which spawns chief-of-staff (deep-reasoning tier — see `rules/performance.md`) to decide which review agents run based on files in scope. Do NOT spawn `code-reviewer` or `security-reviewer` directly.

Chief-of-staff typically selects `code-reviewer` (Opus) and `security-reviewer` (Opus) to run in parallel, plus conditional agents based on file types (see table below).

**code-reviewer produces:**
- A-F quality grade
- Issues found (grouped by severity: critical, high, medium, low)
- Positive patterns noted
- Suggestions for improvement

**security-reviewer produces:**
- Vulnerability scan results
- OWASP compliance check
- Secrets exposure check
- Permission and injection risk analysis

**Conditional agents based on files in scope:**

| Files in review scope | Additional agents | Execution |
|---|---|---|
| `*.razor`, `*.blazor`, `*.tsx`, `*.jsx`, `*.html` | `evidence-collector` (Sonnet) + `accessibility-auditor` (Opus) | Parallel with code-reviewer | <!-- tier-ok: evidence-collector Sonnet + accessibility-auditor Opus, both correct -->
| `*Migration*`, `*DbContext*` | `database-reviewer` (Opus) | Parallel |
| `*Controller*`, `*Endpoint*` | `api-tester` (Opus) | Parallel |
| `appsettings*`, `*auth*` | `security-engineer` (deep-reasoning tier) | Before security-reviewer |

### Step 4 — Reality Checker

**Agent:** `reality-checker` (Opus)

Assesses overall readiness:
- Are the findings blocking or advisory?
- Is this code safe to ship as-is?
- What must be fixed before merging?

### Step 5 — Report

The agent presents a consolidated review report:

```
-----------------------------------------
  Review Report
-----------------------------------------
  Scope:     PR #142 — Add loading spinner
  Grade:     B+

  CRITICAL (must fix before merge):
  - None

  HIGH (should fix):
  - Missing null check in SpinnerComponent.razor
    line 42 — could throw if data is undefined

  MEDIUM (consider fixing):
  - CSS class naming inconsistent with project
    conventions (line 15, 23)

  LOW (optional):
  - Consider extracting spinner logic to shared
    component for reuse

  SECURITY:
  - No vulnerabilities found
  - OWASP compliance: PASS

  RECOMMENDATION: Safe to merge after fixing
  the HIGH issue.
-----------------------------------------
```

---

## Agent and Skill Usage

| Step | Agent/Skill | Model |
|---|---|---|
| Code review | `code-reviewer` | Opus |
| Security review | `security-reviewer` | Opus |
| Evidence collection (UI) | `evidence-collector` | Sonnet |
| Accessibility audit (UI) | `accessibility-auditor` | Opus |
| Database review (DB) | `database-reviewer` | Opus |
| API testing (API) | `api-tester` | Opus |
| Security architecture | `security-engineer` | Deep-reasoning tier (see `rules/performance.md`) |
| Readiness assessment | `reality-checker` | Opus |

---

## Notes

- `/review` never creates a PR or modifies code — it is strictly read-only analysis
- Use `/review` for PR reviews, pre-release checks, or reviewing a colleague's work
- The agent can review PRs from any branch, not just the current one
- If the review finds critical issues, the agent recommends specific fixes but does not implement them
- To review and then fix issues, run `/review` first, then `/refactor` or `/bug` for the fixes
