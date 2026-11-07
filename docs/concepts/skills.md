# Skills

All 48 skills, what each does, passive vs active behaviour, and which commands use them.

---

## When to Read This

- You want to understand what skills are available
- You want to know which skills run in a specific command
- You want to understand the difference between passive and active skills

---

## What Is a Skill?

A skill is a methodology or pattern that the agent follows. Skills come in two types:

- **Active skills** — the agent explicitly invokes them during a workflow step (e.g. brainstorming asks you questions, systematic-debugging runs a 4-phase analysis)
- **Passive skills** — always in effect as reference material that guides the agent's behaviour (e.g. coding-standards, backend-patterns)

---

## Superpowers Skills (7) — from `obra/superpowers`

These are manually copied to `~/.claude/skills/`. The full Superpowers plugin is NOT installed — it enforces workflow control that conflicts with ECC's rules.

| Skill | Type | Used in | What it does |
|---|---|---|---|
| `brainstorming` | Active | /flow, /build | Socratic design refinement — clarifying questions before code, presents design in chunks for approval |
| `systematic-debugging` | Active | /bug, /perf, /hotfix | 4-phase root cause analysis for runtime bugs and performance issues |
| `using-git-worktrees` | Active | /flow | Creates parallel branch workspaces for independent tasks |
| `verification-before-completion` | Active | All commands | Confirms fix/feature works end-to-end, not just compiles |
| `finishing-a-development-branch` | Active | All commands | Presents merge/PR/keep/discard options, enforces clean branch closure |
| `test-driven-development` | Active | All commands with code | RED-GREEN-REFACTOR enforcement — write the failing test first, then the minimum code to pass |
| `receiving-code-review` | Active | Post-review phases | Technical verification of review feedback — distinguishes blocking from advisory comments |

---

## ECC Skills (18) — from `affaan-m/everything-claude-code`

| Skill | Type | Used in | What it does |
|---|---|---|---|
| `tdd-workflow` | Passive | All commands with code | TDD methodology reference — read by tdd-guide agent |
| `coding-standards` | Passive | Always on | Best practices, immutability, naming conventions |
| `backend-patterns` | Passive | Always on | API, DB, caching, repository patterns |
| `frontend-patterns` | Passive | Always on | React/Next.js patterns |
| `continuous-learning-v2` | Passive | Always on (hooks) | Extracts session patterns for improvement |
| `strategic-compact` | Passive | Always on (hooks) | Suggests context compaction when needed |
| `iterative-retrieval` | Passive | Subagent flows | Progressive context refinement |
| `security-review` | Active | /security, /flow, /review | OWASP checklist and vulnerability patterns |
| `verification-loop` | Active | Throughout | Continuous verification during development |
| `eval-harness` | Active | Verification steps | Checkpoint evaluation |
| `api-design` | Passive | /flow, /build | REST/GraphQL design patterns |
| `workflow-discovery` | Active | /refactor, /flow (legacy) | Discovers existing patterns and conventions |
| `deep-research` | Active | /flow (Discovery) | Multi-source research for complex problems |
| `e2e-testing` | Passive | /flow | E2E testing patterns |
| `blueprint` | Active | Greenfield /build, /flow | System design blueprints for new projects |
| `continuous-agent-loop` | Passive | /flow (long tasks) | Patterns for stable long-running sessions |
| `agent-harness-construction` | Passive | Background | Agent orchestration harness optimisation |
| `agentic-engineering` | Passive | Always on | Core principles for multi-agent engineering |

---

## Custom Skills (23) — from this repo

These live in `skills/` and ship with the ai-engineering install. They encode local methodology (code review orchestration, PR comment handling) and sample application domain patterns (Blazor/Radzen, EF migrations, event-driven messaging, monolith decomposition). See [docs/reference/skill-list.md](../reference/skill-list.md) for the full descriptions.

| Skill | Type | Used in | What it does |
|---|---|---|---|
| `code-review-orchestration` | Active | All commands with code | Single-entry-point for code review — spawns chief-of-staff (deep-reasoning tier) to pick reviewers; the orchestrator never picks reviewers directly |
| `discovery` | Active | /flow Phase 1, /bug | Ticket comprehension before any implementation — read the ticket, surface ambiguity, propose a hypothesis at the Investigation Gate |
| `work-breakdown` | Active | /build, /flow | Break large requests into independently shippable Jira tickets with effort estimates and dependencies |
| `advisory-discovery` | Active | /ask, /goal advise | Read-only evidence gathering and ranked improvement proposals; waits for approval before Jira or implementation |
| `respond-to-pr-reviews` | Active | /review-pr | Authoritative keyword table and LOC-tier rules for reviewer-comment responses (automated-review + human) |
| `microservice-patterns` | Active | Greenfield /build | Guides ASP.NET Core services using the actual project conventions |
| `blazor-radzen` | Passive (file-triggered) | Files matching `*.razor` | Blazor/Radzen component patterns, accessibility, parameter conventions |
| `ef-migration-management` | Passive (file-triggered) | Files matching `*Migration*`, `*DbContext*` | EF Core migration safety — backfill ordering, breaking-change detection, rollback windows |
| `event-driven-messaging` | Passive (file-triggered) | Files matching `*Consumer*`, `*Publisher*` | RabbitMQ/MassTransit consumer and publisher patterns, idempotency, retry topology |
| `monolith-decomposition` | Active | /refactor on legacy code | Identifies seams in the sample application monolith and proposes a decomposition order |
| `codex-review` | Active (Codex-gated) | Pre-PR when Codex enabled | Local Codex adversarial review of the diff before a PR is opened, seeded with automated-review's distilled knowledge |
| `workflow-discipline` | Active (on-demand) | Stryker keyword / pre-branch / toolbox install | On-demand detail behind the `workflow-discipline` rule — Stryker grammar, gitignore pre-check, install gating, incident histories |
| `pr-automation` | Active (on-demand) | PR creation / starved cron / merge-gate questions | On-demand detail behind the `git-workflow` auto-poll/merge-readiness directives — CronCreate construction, best-effort cron rationale, four-gate readiness logic, why autonomous self-merge is retired, incident histories |
| `edge-cases` | Active (on-demand) | Service down / empty result / rejection / invalid input / mid-workflow failure / handover / Scrum + kanban | The detailed response playbooks behind the `edge-cases` rule — exact wording and options per failure scenario; the six General Rules stay always-loaded |
| `cross-tool-sync` | Active (on-demand) | Editing the toolbox itself | Shared runtime/provider adapter propagation rules, count locations, dead-reference checks, and pre-commit verification |
| `agent-orchestration` | Active (on-demand) | Agent/model selection at a workflow phase; code-review agent selection | On-demand detail behind the `agents` rule — the Conditional Agents file-pattern→agent table, Parallel Execution order, and Model Assignments; chief-of-staff loads it to pick agents/reviewers |
| `subagent-liveness` | Retired | Legacy links only | Retired because mtime/`git log` polling can report activity while a worker is stuck rewriting the same failing file. Load `observed-work`, whose deterministic script records bounded probes and leaves completion to the orchestrator. |
| `handover-protocol` | Active (on-demand) | Appending a phase entry to `.claude/handover.md`; filling in the Deviations field | The exact phase-entry template and the Deviations guidance behind the `handover` rule — the five deviation categories with worked examples and what happens to captured deviations; the Single-Writer Rule and phase append order stay always-loaded |
| `loop-design` | Passive (on-demand doctrine) | Before creating any loop, cron, `/goal` condition or unattended run; before raising a loop bound; when a loop spins or spends without landing anything | The five components a loop needs, the verification ladder (rung 2 — file mtimes — is the trap), the three guards and which native primitive each uses (`CLAUDE_CODE_MAX_TURNS`, `loop-progress-signature.sh`, `--max-budget-usd`), cost-per-accepted-change as the metric, and the when-NOT-to-loop list. Guard 1 is hook-enforced by `enforce-loop-bounds.sh` on the paths a hook can see; guards 2 and 3 are a script the caller must invoke and a native flag only a launched loop carries. The numbers live in the `workflow-discipline` skill §1d |
| `flow-reference` | Active (on-demand) | Posting a `/flow` phase comment; a board missing a mapped column; composing a subagent spawn prompt during `/flow` | Reference material kept out of `commands/flow.md` so the command stays lean — per-phase Jira comment templates (standard + streamlined, with header-adaptation rules), phases-vs-columns worked examples, the phase-comment spawn mechanism, and per-phase subagent prompt templates |
| `presentation-master` | Active | `/presentation` and any deck request | PowerPoint generation/editing with an optional user template, portable paths, and validation |
| `mutation-testing` | Active | Normal verification for supported mutable stacks | Stryker-backed mutation testing with explicit evidence, thresholds, and production-code boundary |

---

## Skills by Command

| Command | Active Skills | Passive Skills (always on) |
|---|---|---|
| `/flow` | brainstorming, using-git-worktrees, verification-before-completion, finishing-a-development-branch, verification-loop, security-review (if needed) | tdd-workflow, coding-standards, backend/frontend-patterns, api-design, e2e-testing |
| `/flow` (Scrum) | Same as /flow + sprint planning per-ticket | Same as /flow |
| `/build` | brainstorming, verification-before-completion, finishing-a-development-branch, blueprint (greenfield) | tdd-workflow, coding-standards, backend/frontend-patterns, api-design |
| `/bug` | systematic-debugging, verification-before-completion, finishing-a-development-branch | tdd-workflow, coding-standards |
| `/hotfix` | systematic-debugging, verification-before-completion, finishing-a-development-branch | tdd-workflow, coding-standards |
| `/incident` | systematic-debugging | — |
| `/review` | security-review | coding-standards |
| `/refactor` | refactor-cleaner (agent, not a skill), verification-before-completion, finishing-a-development-branch | coding-standards |
| `/security` | security-review | coding-standards |
| `/perf` | systematic-debugging, verification-before-completion, finishing-a-development-branch | coding-standards |
