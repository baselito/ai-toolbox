# Skills List — Full Reference

All 48 skills with source, purpose, which commands use them, and whether they are active or passive.

---

## Custom Skills (23) — from this repo

### advisory-discovery
- **Source:** this repo
- **Type:** Active
- **Purpose:** Read-only repository investigation that turns broad goals into ranked, evidence-backed bug, feature, refactor, security, performance, reliability, or documentation proposals before approval.
- **Used in:** `/ask`, GoalRun advisory discovery, and any “what should we fix?” request

### presentation-master
- **Source:** Generic presentation workflow maintained in this repository
- **Type:** Active
- **Purpose:** Creates and edits unbranded PowerPoint decks with an optional user template or a blank deck and content/layout validation. Uses portable Claude/Codex template and output paths.
- **Used in:** `/presentation` and any presentation request

### mutation-testing
- **Source:** this repo
- **Type:** Active
- **Purpose:** Runs and interprets mutation testing during normal development, using Stryker for supported JavaScript/TypeScript, .NET, and Scala stacks with explicit unavailable/not-applicable evidence and a production-code boundary.
- **Used in:** normal verification for `/flow`, `/build`, `/bug`, `/refactor`, and GoalRun iterations when a mutable supported stack is detected

### loop-design
- **Source:** this repo
- **Type:** Passive (doctrine — loaded on demand; it enforces nothing by itself)
- **Purpose:** How to design an agent loop that is safe to run unattended: the five components a loop needs, the verification ladder (and why an mtime-based progress signal is the trap), the three guards — iteration ceiling, no-progress detector, spend cap — including which native primitive each one uses, cost-per-accepted-change as the metric, and the list of work that must NOT be looped (no verifiable end state; design/planning; anything touching auth, money or production).
- **Used in:** before creating any loop, cron, `/goal` condition or unattended run; when raising a loop bound; when a loop is spinning or spending without landing anything; when registering a new self-terminating prompt in `hooks/enforce-loop-bounds.sh`

### codex-review
- **Source:** this repo
- **Type:** Active (optional — no-op unless Codex is enabled)
- **Purpose:** Local Codex (OpenAI GPT-5.6 Terra) adversarial review of the diff BEFORE a PR is opened, seeded with automated-review's distilled knowledge so it catches issues locally and shrinks post-PR reviewer rounds. Quota-aware — **review-only**: at most one review pass per task; Codex planning passes are NOT spent (planning is Claude-only), to conserve the spend cap. See `rules/performance.md` (Codex tier).
- **Used in:** `finishing-a-development-branch` (pre-PR review pass), toolbox self-improvement (review pass). Planning is Claude-only.

### work-breakdown
- **Source:** this repo
- **Type:** Active
- **Purpose:** Structured decomposition of work into epic → story → task hierarchy. Creates beads first (always), syncs to Jira if configured. Used in agent-first and hybrid workflow modes.
- **Used in:** `/flow`, `/build` (agent-first and hybrid modes)

### microservice-patterns
- **Source:** this repo
- **Type:** Passive
- **Purpose:** Public ASP.NET Core microservice guidance, dependency injection, authorization, and project-specific conventions. No internal packages required.
- **Used in:** `/flow`, `/build`, `/refactor`, `/bug` — activates when Gen1 patterns detected in project

### blazor-radzen
- **Source:** this repo
- **Type:** Passive
- **Purpose:** Blazor WebAssembly + Radzen component patterns for the sample application frontend. Covers modular RCL architecture, code-behind pattern, Radzen components, bUnit + Playwright testing, and Azure AD B2C auth.
- **Used in:** `/flow`, `/build`, `/refactor`, `/bug` — activates when `.razor` files are touched

### ef-migration-management
- **Source:** this repo
- **Type:** Passive
- **Purpose:** EF Core migration management for repos with long migration chains (50-329 migrations). Covers naming conventions, shared database warnings, squashing guidance, and cross-service impact checks.
- **Used in:** `/flow`, `/build`, `/refactor`, `/bug` — activates when migration files are touched

### event-driven-messaging
- **Source:** this repo
- **Type:** Passive
- **Purpose:** MassTransit pub/sub messaging patterns. Covers event publishing, consumer patterns, legacy sync subscribers, event naming, and idempotency. Used across 6 sample application microservices.
- **Used in:** `/flow`, `/build`, `/refactor`, `/bug` — activates when consumer/subscriber/event files are touched

### monolith-decomposition
- **Source:** this repo
- **Type:** Passive
- **Purpose:** Guidance for maintaining the sample-monolith monolith. Covers shared database rules, safe vs risky optimizations, cross-service impact checks, and the maintenance-first approach before full replacement.
- **Used in:** `/flow`, `/build`, `/refactor` — activates when working in sample-monolith repo

### code-review-orchestration
- **Source:** this repo
- **Type:** Active
- **Purpose:** Wraps chief-of-staff orchestration in a mandatory skill invocation. Ensures the orchestrator (main Claude Code agent) does not select review agents directly — chief-of-staff (Opus, ephemeral subagent) makes that decision based on the git diff. Enforced by PreToolUse hook (blocks direct agent spawns) and PostToolUse compliance audit.
- **Used in:** `/flow`, `/build`, `/bug`, `/hotfix`, `/refactor`, `/perf`, `/security` — mandatory at Step 9 (code review phase)

### discovery
- **Source:** this repo
- **Type:** Active
- **Purpose:** Codebase exploration and ticket investigation — wraps the Discovery phase in a delegated Opus subagent to enforce correct model routing. Reads affected files, checks git history, identifies risks, and produces a structured discovery summary.
- **Used in:** `/flow`, `/bug`, `/hotfix`, `/incident`, `/perf` — mandatory at Discovery phase (Step 1.5 of /flow)

### respond-to-pr-reviews
- **Source:** this repo
- **Type:** Active
- **Purpose:** Decision framework for evaluating PR review comments and responding appropriately. Encapsulates the agree-vs-disagree logic, the automated-review keyword protocol (`false positive` / `fixed in <sha>` / `@automated-review learn`), and escalation rules for human reviewers. Autonomously replies to comments and applies small fixes without waiting for user approval; flags large changes for user input.
- **Used in:** `/review-pr` — one-shot PR comment reader. Also referenced by any command that creates a PR.

### workflow-discipline
- **Source:** this repo
- **Type:** Active (on-demand)
- **Purpose:** On-demand detail behind the always-loaded `workflow-discipline` rule — the full Stryker/mutation-testing keyword grammar (opt-in/opt-out/negation/incidental disambiguation), the toolbox-owned verification command registry (§1c) and loop budget ceilings (§1d) that hold the literal commands and limits behind `PROJECT.md`'s keys-only `verification:` / `loop:` blocks, the gitignore pre-check script and its per-command timing, the toolbox install/update gating procedure (Codex opt-in + docs verification), and the incident histories. Keeps the rule itself terse (directives only) so it costs less context every session.
- **Used in:** Loaded on demand when a Stryker keyword appears, when resolving a project's `verification:` or `loop:` block to actual commands or limits, before branching/committing in a project repo, or when installing/updating the toolbox.

### pr-automation
- **Source:** this repo
- **Type:** Active (on-demand)
- **Purpose:** On-demand detail behind the always-loaded `git-workflow` auto-poll/merge-readiness directives — the exact CronCreate construction the orchestrator runs after PR creation (trust model + validated-argument pseudo-code), why the cron is best-effort (idle-only firing, session-only lifetime), the merge-readiness defense-in-depth and four-gate rationale, why autonomous self-merge is retired (auto-mode classifier), the untrusted-comment authority gap, manual cron cancellation, and the incident histories that justify the exact merge/push command forms. Keeps `rules/git-workflow.md` terse (directives + safety-critical exact strings only) so it costs less context every session.
- **Used in:** Loaded on demand when constructing the auto-poll CronCreate call at PR creation, diagnosing a starved cron or a merge-ready notification that didn't fire, or when reasoning about the merge gate.

### edge-cases
- **Source:** this repo
- **Type:** Active (on-demand)
- **Purpose:** The detailed edge-case response playbooks behind the always-loaded `edge-cases` rule — exact wording and options for when a service is down (Jira/acli, Seq, GitHub gh, Beads) or acli auth fails, a query returns nothing, the user rejects something, input is invalid, a step fails mid-workflow, session-resume/handover issues, bug-/incident-specific cases, and the Scrum-board (Step 0) + kanban column-transition cases. Keeps the rule terse (the six always-apply General Rules only) so the big tables don't cost context every session.
- **Used in:** Loaded on demand when one of those scenarios arises and the agent needs the standard handling.

### cross-tool-sync
- **Source:** this repo
- **Type:** Active (on-demand)
- **Purpose:** The detailed provider synchronization rules behind the always-loaded `cross-tool-sync` directives — shared runtime and host adapters, exact count locations, dead-reference checks, and the pre-commit check procedure. Applies only when editing the toolbox itself.
- **Used in:** Loaded on demand when adding/removing/renaming a toolbox file, changing a rule/skill/command/doc, or reconciling provider surfaces and counts.

### agent-orchestration
- **Source:** this repo
- **Type:** Active (on-demand)
- **Purpose:** The agent-selection reference behind the always-loaded `agents` rule — which conditional agents activate for which changed-file patterns, which agents run in parallel vs sequentially, and the fixed per-agent model assignments (Opus/Sonnet/Haiku). Keeps `rules/agents.md` terse (four-role directives + Iron Law only) so the lookup tables don't cost context every session.
- **Used in:** Loaded on demand when selecting which agents/models run at a workflow phase (chief-of-staff, Step 1.8), or which review agents to run at code review (chief-of-staff, Step 9).

### observed-work
- **Source:** this repo
- **Type:** Active (deterministic sensor)
- **Purpose:** Declares long-running or delegated work to a script-backed observer that detects stalls, false completion, and impossible predicates; it reports evidence while the orchestrator remains responsible for decisions.
- **Used in:** Before delegated work over approximately 5 minutes, review rounds, loops, and other work that needs an external progress predicate.

### subagent-liveness
- **Source:** this repo
- **Type:** RETIRED — pointer only
- **Purpose:** Retained as historical context only. Do not load or spawn a model-based liveness monitor; `observed-work` is the deterministic, script-backed sensor for delegated work.
- **Used in:** Not used for new work. See `observed-work` for the active monitoring contract.

---

### handover-protocol

- **Purpose:** The exact `.claude/handover.md` phase-entry template and the Deviations field guidance behind the always-loaded `handover` rule — the full per-phase entry shape, the five deviation categories with worked examples, how to write an honest deviation entry, and what happens to captured deviations. The Single-Writer Rule, the spawn cycle, and the phase append order stay always-loaded in `rules/handover.md`.
- **Used in:** Loaded on demand when appending a phase entry to the handover file or filling in the Deviations field.

### flow-reference

- **Purpose:** Reference material for the `/flow` ticket workflow that is only needed at specific moments, kept out of `commands/flow.md` so the command file stays lean — the full per-phase Jira comment templates (standard "work-starting" and streamlined "work-done" variants plus header-adaptation rules), the phases-vs-columns decoupling detail with worked examples, the phase-comment spawn mechanism, and the per-phase subagent prompt templates.
- **Used in:** Loaded on demand when posting a `/flow` phase comment, when a board is missing a mapped column, or when composing a subagent spawn prompt during `/flow`.

## Superpowers Skills (7) — from `obra/superpowers`

Manually copied to `~/.claude/skills/`. Full plugin is NOT installed.

### test-driven-development
- **Source:** `obra/superpowers`
- **Type:** Active
- **Purpose:** Strict RED-GREEN-REFACTOR enforcement with anti-rationalisation — prevents the agent from skipping steps or writing tests after code
- **Used in:** `/flow`, `/build`, `/bug`, `/hotfix`

### receiving-code-review
- **Source:** `obra/superpowers`
- **Type:** Active
- **Purpose:** Technical verification of review feedback — ensures the agent evaluates review comments critically instead of performatively agreeing
- **Used in:** `/flow`, `/build`

### brainstorming
- **Source:** `obra/superpowers`
- **Type:** Active
- **Purpose:** Socratic design refinement — asks clarifying questions before any code is written, presents design in chunks for user approval
- **Used in:** `/flow`, `/build`
- **Not used in:** `/hotfix` (skipped for speed), `/incident`, `/review`, `/refactor`

### systematic-debugging
- **Source:** `obra/superpowers`
- **Type:** Active
- **Purpose:** 4-phase root cause analysis for runtime bugs and performance issues. Covers all bugs — different from ECC's build-error-resolver which only handles compile errors
- **Used in:** `/bug`, `/perf`, `/hotfix`
- **Model:** Opus — the invoking subagent already runs there, so there is no escalation step

### using-git-worktrees
- **Source:** `obra/superpowers`
- **Type:** Active
- **Purpose:** Creates parallel branch workspaces so multiple independent tasks can be worked simultaneously without switching branches
- **Used in:** `/flow`

### verification-before-completion
- **Source:** `obra/superpowers`
- **Type:** Active
- **Purpose:** Confirms a fix or feature actually works end-to-end before marking done — not just "compiles without errors"
- **Used in:** All commands with code changes

### finishing-a-development-branch
- **Source:** `obra/superpowers`
- **Type:** Active
- **Purpose:** Presents merge/PR/keep/discard options at the end of work and enforces clean branch closure
- **Used in:** All commands that create branches

---

## ECC Skills (18) — from `affaan-m/everything-claude-code`

### tdd-workflow
- **Source:** ECC
- **Type:** Passive
- **Purpose:** TDD methodology reference — read by the tdd-guide agent
- **Used in:** `/flow`, `/build`, `/bug`, `/hotfix`

### coding-standards
- **Source:** ECC
- **Type:** Passive
- **Purpose:** Best practices, immutability, naming conventions
- **Used in:** Always on

### backend-patterns
- **Source:** ECC
- **Type:** Passive
- **Purpose:** API, DB, caching, repository patterns
- **Used in:** Always on (when backend files exist)

### frontend-patterns
- **Source:** ECC
- **Type:** Passive
- **Purpose:** React/Next.js patterns
- **Used in:** Always on (when frontend files exist)

### continuous-learning-v2
- **Source:** ECC
- **Type:** Passive
- **Purpose:** Extracts session patterns for continuous improvement
- **Used in:** Always on via hooks

### strategic-compact
- **Source:** ECC
- **Type:** Passive
- **Purpose:** Suggests context compaction when context window is under pressure
- **Used in:** Always on via hooks

### iterative-retrieval
- **Source:** ECC
- **Type:** Passive
- **Purpose:** Progressive context refinement for subagent flows
- **Used in:** Subagent flows

### security-review
- **Source:** ECC
- **Type:** Active
- **Purpose:** OWASP checklist and vulnerability patterns
- **Used in:** `/security`, `/flow`, `/review`

### verification-loop
- **Source:** ECC
- **Type:** Active
- **Purpose:** Continuous verification during development — different from verification-before-completion which is a one-time checkpoint
- **Used in:** Throughout all build commands

### eval-harness
- **Source:** ECC
- **Type:** Active
- **Purpose:** Checkpoint evaluation during verification steps
- **Used in:** Verification steps

### api-design
- **Source:** ECC
- **Type:** Passive
- **Purpose:** REST/GraphQL API design patterns and standards
- **Used in:** `/flow`, `/build`

### workflow-discovery
- **Source:** ECC
- **Type:** Active
- **Purpose:** Discovers existing patterns and conventions in a codebase
- **Used in:** `/refactor`, `/flow` (legacy projects)

### deep-research
- **Source:** ECC
- **Type:** Active
- **Purpose:** Multi-source research before making decisions on complex or unfamiliar problems
- **Used in:** `/flow` (Discovery phase)

### e2e-testing
- **Source:** ECC
- **Type:** Passive
- **Purpose:** End-to-end test generation patterns
- **Used in:** `/flow`

### blueprint
- **Source:** ECC
- **Type:** Active
- **Purpose:** System design blueprint generation for new projects
- **Used in:** Greenfield `/build`, `/flow`

### continuous-agent-loop
- **Source:** ECC
- **Type:** Passive
- **Purpose:** Patterns for stable long-running agent sessions
- **Used in:** `/flow` (long tasks)

### agent-harness-construction
- **Source:** ECC
- **Type:** Passive
- **Purpose:** Building and configuring agent orchestration harnesses
- **Used in:** Background (advanced use)

### agentic-engineering
- **Source:** ECC
- **Type:** Passive
- **Purpose:** Core principles for reliable multi-agent engineering
- **Used in:** All agentic workflows
