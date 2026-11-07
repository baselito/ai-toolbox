# Agents List — Full Reference

All 25 agents with source, model, what they do, when they run, what they produce, and who they hand off to.

---

## Agent Type Reference — `subagent_type` values

When spawning agents via `Agent(subagent_type: "...")`, use the correct prefix:

⛔ **Seven review/execution agents were VENDORED into this repo and now use the BARE
name.** They were `everything-claude-code:`-prefixed until the Opus review-tier change.
Spawning the prefixed name still resolves — to the ECC plugin's Sonnet copy — so using the
old string silently gets you the wrong tier with no error. This is the same failure mode
that sent 104 spawns to the wrong `chief-of-staff` for five weeks. Use the bare name.

⚠️ **A newly-installed agent NAME is not spawnable until you start a new Claude Code session.**
The agent registry is snapshotted at session start, so `install.sh` adding a new agent file
mid-session does not register it — spawning it hard-errors with "Agent type not found".
(Existing names DO pick up file changes, which is why a tier change to an already-registered
agent takes effect immediately.) If you just ran `install.sh`, restart before spawning any of
the agents below by bare name. `install.sh` warns when it adds a new name.

**Vendored agents** (in this repo, Opus) — **no prefix**:

| Agent | `subagent_type` value |
|---|---|
| tdd-guide | `tdd-guide` |
| code-reviewer | `code-reviewer` |
| security-reviewer | `security-reviewer` |
| database-reviewer | `database-reviewer` |
| build-error-resolver | `build-error-resolver` |
| refactor-cleaner | `refactor-cleaner` |
| e2e-runner | `e2e-runner` |

**Still ECC** — use the `everything-claude-code:` prefix:

| Agent | `subagent_type` value |
|---|---|
| architect | `everything-claude-code:architect` |
| planner | `everything-claude-code:planner` |
| harness-optimizer | `everything-claude-code:harness-optimizer` |
| loop-operator | `everything-claude-code:loop-operator` |
| doc-updater | `everything-claude-code:doc-updater` |

**Custom agents** (from this repo + Agency Agents) use **no prefix**:

| Agent | `subagent_type` value |
|---|---|
| chief-of-staff | `chief-of-staff` |
| reality-checker | `reality-checker` |
| api-tester | `api-tester` |
| security-engineer | `security-engineer` |
| accessibility-auditor | `accessibility-auditor` |
| devops-automator | `devops-automator` |
| evidence-collector | `evidence-collector` |
| docs-lookup | `docs-lookup` |
| incident-response-commander | `incident-response-commander` |
| jira-workflow-steward | `jira-workflow-steward` |
| performance-benchmarker | `performance-benchmarker` |
| project-manager-senior | `project-manager-senior` |

**Built-in agent types** (no prefix, always available):

| Agent | `subagent_type` value |
|---|---|
| General-purpose | `general-purpose` |
| Explore (fast search) | `Explore` |
| Plan (architect) | `Plan` |

**Rule:** If an agent spawn fails with "unknown agent type", check this table. Do NOT retry with a guessed prefix — look up the correct value.

---

## ECC Agents (12) — from `affaan-m/everything-claude-code`

> **Tier attribution:** seven of these (`code-reviewer`, `tdd-guide`, `security-reviewer`, `database-reviewer`, `e2e-runner`, `refactor-cleaner`, `build-error-resolver`) are **vendored into this repo** at `agents/` and run on Opus. ECC's own copies remain `model: sonnet` in the plugin cache — the Opus tier is this repo's, not ECC's. Only the five still used as-is (`architect`, `planner`, `doc-updater`, `harness-optimizer`, `loop-operator`) run at ECC's tier. <!-- tier-ok: the contrast IS the content — these seven run at Opus here and remain Sonnet in ECC's plugin cache; stating both is the point -->

### architect
- **Model:** Opus
- **What it does:** System design decisions — evaluates architecture patterns, proposes structures, identifies risks before implementation
- **When it runs:** Greenfield `/flow`, `/build`; major architecture changes
- **What it produces:** Architecture decision records, system design proposals
- **Hands off to:** `planner`

### planner
- **Model:** Opus
- **What it does:** Creates detailed implementation plans with exact file paths, phases, dependencies, and verification steps
- **When it runs:** `/flow`, `/build`
- **What it produces:** Step-by-step implementation plan with file paths and dependencies
- **Hands off to:** Subagents for execution

### tdd-guide
- **Model:** Opus
- **What it does:** Enforces RED-GREEN-REFACTOR. Will not mark a task done without passing tests
- **When it runs:** Every command with code changes
- **What it produces:** Tests (failing first, then passing), test coverage report
- **Hands off to:** `code-reviewer`

### code-reviewer
- **Model:** Opus
- **What it does:** Code quality review — A-F grading, issue identification, OWASP compliance checks
- **When it runs:** `/flow`, `/build`, `/review`, `/hotfix`, `/refactor`
- **What it produces:** Quality grade (A-F), issue list by severity, suggestions
- **Hands off to:** `reality-checker` or conditional agents

### security-reviewer
- **Model:** Opus
- **What it does:** Vulnerability scanning — secrets exposure, permission issues, injection risks
- **When it runs:** `/review`, `/security`, `/flow` (when API/auth files changed)
- **What it produces:** Vulnerability report, OWASP compliance status
- **Hands off to:** `reality-checker`

### database-reviewer
- **Model:** Opus
- **What it does:** Reviews DB queries, schema design, migrations, N+1 problems, index usage
- **When it runs:** `/flow`, `/bug` (when DB files touched)
- **What it produces:** DB analysis report, query optimisation suggestions
- **Hands off to:** `reality-checker`

### e2e-runner
- **Model:** Opus
- **What it does:** Generates and runs end-to-end tests using Playwright
- **When it runs:** `/flow`
- **What it produces:** E2E test suite, test results
- **Hands off to:** `code-reviewer`

### refactor-cleaner
- **Model:** Opus
- **What it does:** Identifies dead code, legacy patterns, modernisation opportunities without adding new features
- **When it runs:** `/refactor`
- **What it produces:** Refactoring plan, cleaned code
- **Hands off to:** `code-reviewer`

### doc-updater
- **Model:** Haiku
- **What it does:** Keeps documentation in sync after code changes
- **When it runs:** `/flow` (after all reviewers)
- **What it produces:** Updated documentation files
- **Hands off to:** `finishing-a-development-branch` skill

### build-error-resolver
- **Model:** Opus
- **What it does:** Reads build/compile error output and applies known fix patterns
- **When it runs:** On build errors during any command
- **What it produces:** Error fix applied to code
- **Hands off to:** Resumes current workflow

### harness-optimizer
- **Model:** Sonnet
- **What it does:** Monitors agent performance and context window usage
- **When it runs:** Background, throughout long workflows
- **What it produces:** Performance metrics, compaction suggestions
- **Hands off to:** N/A (background monitoring)

### loop-operator
- **Model:** Sonnet
- **What it does:** Stabilises long-running autonomous agent loops
- **When it runs:** `/flow` (long tasks)
- **What it produces:** Loop stability monitoring
- **Hands off to:** N/A (stability monitoring)

---

## Agency Agents (8) — from `msitarzewski/agency-agents`

### project-manager-senior
- **Model:** Opus
- **What it does:** Converts business requirements to developer tasks with effort estimates, sprint scope, dependencies
- **When it runs:** `/flow` (on Scrum boards)
- **What it produces:** Sprint plan, task breakdown, effort estimates, retrospective
- **Hands off to:** Per-ticket `/flow` execution

### jira-workflow-steward
- **Model:** Haiku
- **What it does:** Enforces branch-per-ticket discipline, branch naming, Jira status transitions via acli, traceability
- **When it runs:** `/flow`, `/bug`, `/hotfix` (any command with Jira)
- **What it produces:** Branch creation, Jira status moves (via acli CLI), comments, PR links
- **Hands off to:** Next agent in workflow

### devops-automator
- **Model:** Opus
- **What it does:** Reviews and interacts with CI/CD pipelines — GitHub Actions (via `gh` CLI and local YAML parsing)
- **When it runs:** `/flow`, `/hotfix`, `/perf` (when `.github/workflows/*.yml` files changed or fast-track needed)
- **What it produces:** Pipeline review, deployment coordination, fast-track queue priority
- **Hands off to:** `reality-checker`

### incident-response-commander
- **Model:** Opus
- **What it does:** Full incident response protocol — triage, severity classification, Seq log queries, coordination, post-mortem
- **When it runs:** `/incident`
- **What it produces:** Incident timeline, root cause analysis, post-mortem report
- **Hands off to:** `devops-automator` (for deployment fix)

### security-engineer
- **Model:** Opus
- **What it does:** Designs security architecture — IAM, zero-trust, OAuth/RBAC, threat modelling
- **When it runs:** `/security`, `/flow` (when security-sensitive files changed), `/hotfix`
- **What it produces:** Security architecture review, threat model, OWASP compliance report
- **Hands off to:** `security-reviewer` (sequential)

### evidence-collector
- **Model:** Sonnet
- **What it does:** Screenshot-based visual QA — critical for Blazor/Radzen components
- **When it runs:** `/flow`, `/review`, `/refactor` (when UI files touched)
- **What it produces:** Screenshots, visual comparison, rendering verification
- **Hands off to:** `reality-checker`

### reality-checker
- **Model:** Opus
- **What it does:** Production readiness gate — validates all reviewers signed off, tests pass, deployment ready
- **When it runs:** `/flow`, `/hotfix`, `/review`, `/security` — always last
- **What it produces:** Readiness assessment — signs off or blocks
- **Hands off to:** `finishing-a-development-branch` skill (if passed)

### api-tester
- **Model:** Opus
- **What it does:** Dedicated API endpoint validation — tests contracts, payloads, error handling, performance
- **When it runs:** `/perf`, `/flow` (when API endpoints touched)
- **What it produces:** API test results, endpoint validation report
- **Hands off to:** `reality-checker`

---

## Custom Agents (5) — built for this toolbox

### chief-of-staff
- **Model:** Opus
- **Role:** Decision-maker subagent (ephemeral — runs, returns a plan, dies). NOT the persistent orchestrator.
- **Spawned by:** The main orchestrator (main Claude Code agent) at two specific points per `/flow`:
  1. **Step 1.8 — Execution Plan:** reads the ticket + discovery summary, returns a per-phase agent + model plan
  2. **Step 9 — Code Review:** reads the git diff, returns which review agents should run
- **What it produces:** A plan (list of agents + models + execution order) in its response message
- **What it does NOT do:** Write code, execute phases, run commands. It only decides — the orchestrator executes.
- **Why it's separate from the orchestrator:** The orchestrator manages the workflow but can't objectively pick reviewers for code written during the session. Chief-of-staff reads the diff with no prior context, making an independent decision. See `docs/concepts/independence-principle.md`.
- **Why it's vendored here, not from ECC:** Upstream ECC repurposed their `chief-of-staff` agent into a personal communications triage bot (email/Slack/LINE/Messenger). We vendor our own (`agents/chief-of-staff.md`) so the orchestration role can't drift out from under us again.
- **Hands off to:** The orchestrator (who spawns the selected agents per the plan)

### accessibility-auditor
- **Model:** Opus
- **What it does:** WCAG 2.2 AA compliance auditing — keyboard navigation, screen reader support, contrast ratios, form labels
- **When it runs:** `/flow`, `/review` (when UI files touched: `*.razor`, `*.tsx`, `*.jsx`, `*.html`)
- **What it produces:** WCAG compliance report with severity grades and specific fix instructions
- **Hands off to:** `reality-checker`

### performance-benchmarker
- **Model:** Opus
- **What it does:** Before/after performance benchmarks — p50/p95/p99 response times, Core Web Vitals, throughput, capacity planning
- **When it runs:** `/perf`, `/flow` (when performance tests modified or after systematic-debugging finds a performance root cause)
- **What it produces:** Benchmark report with baseline vs after comparison, root cause, fix applied, capacity headroom
- **Hands off to:** `reality-checker`

### observer
- **Model:** Fable
- **Role:** Judgement over MEASURED facts. It reads the declaration and the full append-only event log that `scripts/observe.sh` wrote, and says whether the declared work is on track.
- **What it does NOT do:** Measure anything. Its toolset is `Read`, `Grep`, `Glob` — **no `Bash`**, so the read-only guarantee is structural rather than a prose promise (it was previously granted Bash with a prose prohibition only; the sensing path excludes the model deterministically, and the judge now does too). It cannot run `observe.sh probe` either — that appends to the log — so it requests probes from the observed agent by name.
- **Spawned by:** The orchestrator, via `SendMessage`, after an `observe.sh checkin`. The message carries only a task id and a claim — **never the facts**, because facts in the message would make the judgement depend on the observed agent's own summary.
- **What it produces:** A fixed shape — `VERDICT: ON_TRACK | MISMATCH | CHURNING | STUCK-PLAN | ESCALATE`, then `Facts cited:` (event lines it read this turn), then `Judgment:`, then exactly ONE question or ONE instruction. An `ESCALATE` carries the exact user-facing text to surface verbatim.
- **Why it refuses to estimate:** Asked something the log does not contain, it must answer `not measured — declare a probe`. The predecessor design made a MODEL the sensor and it fabricated a report — "27 checks over 40 minutes" against usage metadata showing 48 seconds and 4 tool calls. All sensing now lives in `scripts/observe.sh`; this agent only judges.
- **Hands off to:** The orchestrator (which acts on the verdict per the `observed-work` skill)

### docs-lookup
- **Model:** Sonnet
- **What it does:** Queries up-to-date library and framework documentation via Context7 MCP — fetches current API signatures, config examples, migration guides
- **When it runs:** On demand by any agent when library/framework questions arise
- **What it produces:** Relevant documentation excerpts with version-specific details
- **Hands off to:** Requesting agent (returns context, does not produce deliverables)
