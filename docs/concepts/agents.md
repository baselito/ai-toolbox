# Agents

Who does what in this toolbox. Four roles, one coordinator, many specialists.

---

## When to Read This

- You want to understand the agent architecture
- You're wondering "who writes the code?" or "what does chief-of-staff actually do?"
- You need to pick the right agent for a new task
- You're debugging a handover / orchestration issue

---

## The Four Roles

Everything in the toolbox resolves to one of these four roles. If you understand these, the rest is detail.

| Role | Also called | Model | Lifetime | What it does |
|---|---|---|---|---|
| **Orchestrator** | "main agent", "coordinating agent", "main Claude Code session" | Fable (session default)¹ | **Persistent** — whole session | Coordinates the workflow, spawns subagents, writes `.claude/handover.md` |
| **Chief-of-staff** | "orchestration subagent" | Opus | **Ephemeral** — runs, returns a plan, dies | Decides WHICH agents + models run at each phase and for code review |
| **Implementing subagent** | "implementing agent", `[DELEGATED]` subagent | Opus | Ephemeral | Does the actual execution work: writes code, runs tests, reads files |
| **Review agents** | "reviewers", "specialists" | Opus | Ephemeral | Check the implementing subagent's work: code quality, security, tests, etc. |

¹ The orchestrator tier comes from `"model": "fable"` in `~/.claude/settings.json` — a default the developer can override per session with `/model`. A named subagent's tier comes from its frontmatter (no spawn-time override); an anonymous `general-purpose` subagent has none and must be given an explicit `model:` at spawn. Canonical rule: `rules/performance.md` ("The four tiers").

### What the orchestrator does NOT do

A common misreading: "the orchestrator writes the code." It does not. The orchestrator is a coordinator, not an executor. Per `commands/flow.md`:

> The orchestrator is a **COORDINATOR**, not a decision-maker.

The orchestrator:
- **Does**: read user input, coordinate phases, spawn subagents, invoke skills via the Skill tool, append phase summaries to `.claude/handover.md`, ask the user questions via `AskUserQuestion`
- **Does NOT**: write feature code inline, design the solution inline, pick reviewers directly, post Jira comments inline via `acli`, run skill *logic* inline on the orchestrator tier

**"Invokes skills" ≠ "runs skill logic inline."** The orchestrator DOES invoke skills via the Skill tool — that's how `code-review-orchestration`, `brainstorming`, `finishing-a-development-branch`, etc. are triggered. But when a skill is invoked, its logic runs in a spawned subagent (Opus for execution skills, the Opus deep-reasoning tier — for `code-review-orchestration`'s chief-of-staff spawn), not inline on the orchestrator. This delegation is enforced by `hooks/enforce-skill-delegation.sh` for the skills that require it.

When the orchestrator needs code written, it spawns an Opus subagent with the `[DELEGATED]` marker. When it needs a decision about which agents to run, it invokes `code-review-orchestration` → which spawns chief-of-staff. When it needs a Jira comment posted, it spawns `jira-workflow-steward` (Haiku) — direct `acli` writes on the orchestrator are blocked by `hooks/enforce-jira-delegation.sh`. <!-- tier-ok: chief-of-staff Opus + jira-workflow-steward Haiku, both correct -->

### Why this split exists

**Cost.** The orchestrator carries the whole session's context, so work done inline there is paid for repeatedly. The orchestrator stays in that context only for coordination (a few tool calls per phase); execution runs in fresh subagent contexts. Doing execution inline on the orchestrator — "inline wasting" — is blocked by the `enforce-skill-delegation.sh` hook.

**Independence.** The agent that wrote the code can't objectively review it — it has a blind spot about its own implementation choices. So code review runs on DIFFERENT agents than the implementing subagent, picked by chief-of-staff (a third agent that didn't see the code before it reads the diff). See `docs/concepts/independence-principle.md`.

**Context isolation.** Subagents run in fresh contexts. They don't inherit the orchestrator's conversation history. This forces explicit handoffs via prompt + handover file — which makes the workflow auditable.

---

## Chief-of-Staff — the decision-maker

Chief-of-staff is spawned exactly **twice** in a full `/flow` workflow:

### Spawn 1 — Step 1.8 (Execution Plan)

After Discovery finishes, chief-of-staff reads the ticket + discovery summary and returns a per-phase execution plan:

```
Phase 1 Discovery: Opus subagent via discovery skill ← already done
Phase 2 Assessment: orchestrator reads ticket; the steward is used only for a requested milestone or board transition
Phase 3 Brainstorming: Opus subagent via brainstorming skill
Phase 4 Planning: deep-reasoning-tier planner agent
Phase 5 Implementation: Opus subagent
Phase 6 Code Review: deferred — chief-of-staff will decide at Step 9
Phase 7 Verification: Opus subagent via verification-before-completion skill
Phase 8 PR Creation: Opus subagent via finishing-a-development-branch skill
```

Then chief-of-staff dies. The orchestrator executes this plan by spawning the right subagent at each phase.

### Spawn 2 — Step 9 (Code Review)

After implementation finishes, the orchestrator invokes the `code-review-orchestration` skill. The skill spawns chief-of-staff again. This time chief-of-staff reads the actual git diff and picks which review agents should run:

```
Always: tdd-guide + code-reviewer + reality-checker (last)
+ Conditional based on files changed:
    .razor/.tsx files → evidence-collector + accessibility-auditor
    *Controller*     → api-tester + security-reviewer
    *Migration*      → database-reviewer
    appsettings*     → security-engineer + security-reviewer
    ...
+ Always after all reviewers: doc-updater (Haiku) <!-- tier-ok: doc-updater is Haiku; the reviewer names above it are Opus, both correct -->
```

Then chief-of-staff dies again. The orchestrator spawns the selected reviewers.

### Why twice, not once?

Because the review plan can't be made before Discovery — chief-of-staff needs to know what the ticket actually involves before assigning models. And the code review plan can't be made before implementation — the diff doesn't exist yet. Each spawn makes a decision that requires state that only exists at that moment.

### Why chief-of-staff at all, instead of the orchestrator picking?

Because the orchestrator has a session-context bias. The orchestrator didn't write the code — the Opus implementing subagent did, in Phase 5 — but the orchestrator *witnessed* the implementation (saw what the subagent attempted, what it tried, what it skipped). That witness context biases reviewer selection: the orchestrator unconsciously picks reviewers that match what the subagent already covered, missing angles the subagent didn't consider. Chief-of-staff is a fresh subagent that reads only the git diff with no prior session context — it picks reviewers based on what the CODE looks like, not what the implementation felt like. This is structurally enforced by `hooks/enforce-chief-of-staff.sh` — the orchestrator physically cannot spawn review agents without a marker that chief-of-staff creates.

---

## The Implementing Subagent — who writes the code

Phase 5 (Implementation) spawns an Opus subagent with the `[DELEGATED]` prompt marker. That subagent:

- Reads relevant files
- Writes the feature code (edits existing files, creates new files)
- Runs the test suite
- Returns results (files changed, tests passing, observations) in its response message

The orchestrator receives those results, appends a phase summary to `.claude/handover.md`, and moves to the next phase.

**The implementing subagent does NOT write to `.claude/handover.md`.** That's the Single-Writer Rule — only the orchestrator appends to handover. Subagents return results in response messages; the orchestrator decides what to persist.

### Specialized code-writers for narrow tasks

For tasks too specific for a generic implementing subagent:

| Agent | Model | When it writes code |
|---|---|---|
| `build-error-resolver` | Opus | Build fails — minimal-diff fixes to get green |
| `refactor-cleaner` | Opus | `/refactor` — dead code removal, modernization |
| `go-build-resolver`, `rust-build-resolver`, `kotlin-build-resolver`, `java-build-resolver`, `cpp-build-resolver`, `pytorch-build-resolver` | Sonnet | Language-specific build/type errors |

These are spawned by the orchestrator instead of (or in addition to) the generic implementing subagent.

### Non-code artifacts have dedicated writers

Even when "writing" is involved, not everything goes through the implementing subagent:

| Artifact | Written by | Model |
|---|---|---|
| Feature code (the main thing) | Implementing subagent | Opus |
| Commit messages | Haiku (delegated by orchestrator) | Haiku |
| Jira comments | `jira-workflow-steward` subagent | Haiku |
| PR body | `finishing-a-development-branch` skill via subagent | Opus |
| Doc updates after review | `doc-updater` subagent | Haiku |
| `.claude/handover.md` | **Orchestrator only** (Single-Writer Rule, enforced) | Fable |

---

## Who Writes / Reviews / Decides — quick reference

```
User request
     │
     ▼
┌─────────────────────────────────────────────────────────┐
│          ORCHESTRATOR (Fable, persistent)               │
│  - coordinates phases                                   │
│  - writes handover.md                                   │
│  - spawns subagents                                     │
│  - NEVER writes feature code inline                     │
└─────────────────────────────────────────────────────────┘
     │          │          │          │          │
     ▼          ▼          ▼          ▼          ▼
 Discovery  Planning  Impl.   Review   PR Creation
 (Opus     (deep-    (Opus)   (reviewers (Opus
  subagent  reasoning subagent picked by  subagent
  via       planner   writes  chief-of-   via skill)
  skill)    subagent) code)   staff)
                               │
                               ▼
                    CHIEF-OF-STAFF
                   (Opus; ephemeral)
                    reads diff,
                    returns reviewer list,
                    dies
```

¹ See footnote in "The Four Roles" above and `rules/performance.md` ("The four tiers") for how tiers are assigned.

Chief-of-staff shows up twice in this flow: once at the start of the plan (Step 1.8) to decide per-phase agents, once at code review (Step 9) to decide reviewers. It doesn't execute anything — it only decides.

---

## How Orchestration Works (the hook-enforced version)

1. User types `/flow DEV-123`
2. Orchestrator runs Step 0 (preflight) and Step 1.5 (Discovery), spawning an Opus subagent for Discovery
3. Orchestrator reaches Step 1.8 — invokes the execution-plan phase, which spawns chief-of-staff
4. Chief-of-staff returns the per-phase plan, dies
5. Orchestrator executes the plan: for each phase, spawns the subagent / invokes the skill chief-of-staff specified
6. After Implementation (Phase 5), orchestrator invokes the `code-review-orchestration` skill
7. The skill spawns chief-of-staff AGAIN
8. Chief-of-staff reads the diff, returns the reviewer list, dies
9. Orchestrator creates `~/.claude/.review-orchestrated` marker, spawns the selected reviewers (in parallel where possible)
10. Each reviewer returns findings. Orchestrator consolidates into ONE handover entry
11. Orchestrator runs Verification (Phase 7), then PR Creation (Phase 8 — another skill-wrapped Opus subagent)
12. Cleanup: orchestrator removes markers

Hooks that enforce this architecture (from `docs/concepts/independence-principle.md`):

- `enforce-skill-delegation.sh` — blocks the orchestrator from running skills inline (must delegate to Opus subagents)
- `enforce-chief-of-staff.sh` — blocks direct spawn of review agents without chief-of-staff's marker
- `enforce-pr-skill.sh` — blocks `gh pr create` without the PR-skill marker
- `enforce-compliance-audit.sh` — blocks `gh pr create` without an audit-complete signature
- `enforce-jira-delegation.sh` — blocks direct `acli` writes on the orchestrator (Jira comments must go through `jira-workflow-steward`)

Without these hooks, architecture is prose. With them, it's structural — the orchestrator physically cannot take shortcuts.

---

## Always Run (every task with code changes)

These agents run on every code-change workflow, confirmed by chief-of-staff at Step 9:

- `tdd-guide` (Opus) — enforces RED-GREEN-REFACTOR
- `code-reviewer` (Opus) — quality review, A-F grading
- `reality-checker` (Opus) — production readiness gate, **always runs last**

---

## Conditional Activation (based on files changed)

Chief-of-staff adds these at Step 9 based on the actual diff. *(Non-authoritative summary — the authoritative table lives in the on-demand `agent-orchestration` skill; keep this in sync with it.)*

| Files changed | Agents activated |
|---|---|
| `*.razor`, `*.blazor`, `*.tsx`, `*.jsx`, `*.html` | `evidence-collector` (Sonnet) + `accessibility-auditor` (Opus) | <!-- tier-ok: evidence-collector Sonnet + accessibility-auditor Opus, both correct -->
| `*Controller*`, `*Endpoint*` | `api-tester` (Opus) + `security-reviewer` (Opus) |
| `*Migration*`, `*DbContext*` | `database-reviewer` (Opus) |
| `appsettings*`, `*auth*`, secrets | `security-engineer` + `security-reviewer` (Opus) |
| `*Pipeline*`, `*.yml` | `devops-automator` (Opus) |
| Major architecture change | `architect` + `planner` |
| `/perf` workflow or performance tests | `performance-benchmarker` (Opus) |
| Any code | `doc-updater` (Haiku) |
| Any task with Jira | `jira-workflow-steward` (Haiku) |
| Library/framework usage questions | `docs-lookup` (Sonnet) — on demand by any agent |

`security-engineer`, `architect`, and `planner` are Opus deep-reasoning agents (see the note at the top of "Full Agent List" and `rules/performance.md`) — their tier comes from frontmatter, with no spawn-time override.

---

## Parallel Execution Rules

- `code-reviewer` + `evidence-collector` + `accessibility-auditor` → run in parallel
- `database-reviewer` + `api-tester` → run in parallel
- `security-engineer` → `security-reviewer` → sequential (engineer first)
- `performance-benchmarker` → after systematic-debugging, before code-reviewer
- `reality-checker` → always last, waits for all others
- `doc-updater` → after all reviewers, before PR

---

## Full Agent List

**A note on "Opus" in the tables below:** `architect`, `planner`, `security-engineer`, and `chief-of-staff` are the four deep-reasoning-tier agents. The "Opus" shown in their Model column is their frontmatter value, and frontmatter is authoritative — the orchestrator spawns them by `subagent_type` alone and passes no `model:` argument. Fable sits one tier up, at the orchestrator itself. `rules/performance.md` ("The four tiers") is the canonical statement of this rule — this doc doesn't repeat the full rationale. <!-- tier-ok: names the four Opus deep-reasoning agents and contrasts them with Fable at the orchestrator tier — the contrast IS the point of the sentence -->

### ECC Agents (12) — from `affaan-m/everything-claude-code`

> **Tier attribution:** seven of these (`code-reviewer`, `tdd-guide`, `security-reviewer`, `database-reviewer`, `e2e-runner`, `refactor-cleaner`, `build-error-resolver`) are **vendored into this repo** at `agents/` and run on Opus. ECC's own copies remain `model: sonnet` in the plugin cache — the Opus tier is this repo's, not ECC's. Only the five still used as-is (`architect`, `planner`, `doc-updater`, `harness-optimizer`, `loop-operator`) run at ECC's tier. <!-- tier-ok: the contrast IS the content — these seven run at Opus here and remain Sonnet in ECC's plugin cache; stating both is the point -->

> **Note:** `chief-of-staff` used to be an ECC agent. Upstream repurposed theirs into a personal communications triage bot (email/Slack/LINE/Messenger) — a different system prompt entirely. This toolbox now vendors its own (`agents/chief-of-staff.md`, listed under Custom Agents below) so the orchestration role can't drift again.

| Agent | Model | What it does |
|---|---|---|
| `architect` | Opus | System design — evaluates patterns, proposes structures, identifies risks |
| `planner` | Opus | Implementation plans — exact file paths, phases, dependencies |
| `tdd-guide` | Opus | Enforces RED-GREEN-REFACTOR — no task done without passing tests |
| `code-reviewer` | Opus | Quality review — A-F grading, OWASP checks |
| `security-reviewer` | Opus | Vulnerability scanning — secrets, permissions, injection risks |
| `database-reviewer` | Opus | DB queries, schema, migrations, N+1 problems |
| `e2e-runner` | Opus | Generates and runs Playwright E2E tests |
| `refactor-cleaner` | Opus | Dead code removal, legacy pattern modernisation |
| `doc-updater` | Haiku | Keeps documentation in sync after reviews |
| `build-error-resolver` | Opus | Reads build errors, applies known fix patterns |
| `harness-optimizer` | Sonnet | Monitors agent performance and context window |
| `loop-operator` | Sonnet | Stabilises long-running agent loops |

### Agency Agents (8) — from `msitarzewski/agency-agents`

| Agent | Model | What it does | Why not in ECC |
|---|---|---|---|
| `project-manager-senior` | Opus | Business requirements → developer tasks, sprint planning | This repo's `chief-of-staff` handles agent orchestration, not business translation |
| `jira-workflow-steward` | Haiku | Branch discipline, Jira status transitions, traceability | No Jira workflow in ECC |
| `devops-automator` | Opus | CI/CD pipeline review and interaction | No DevOps agent in ECC |
| `incident-response-commander` | Opus | Full incident protocol — triage, Seq, post-mortem | No incident handling in ECC |
| `security-engineer` | Opus | Security architecture — IAM, zero-trust, threat modelling | ECC security-reviewer scans code; this designs architecture |
| `evidence-collector` | Sonnet | Screenshot QA for Blazor/Radzen components | ECC e2e-runner runs code tests; this does visual verification |
| `reality-checker` | Opus | Production readiness gate — validates before PR merge | No production gate in ECC |
| `api-tester` | Opus | API endpoint validation — contracts, payloads, errors | No dedicated API testing in ECC |

### Custom Agents (4) — built for this repo

| Agent | Model | What it does |
|---|---|---|
| `chief-of-staff` | Opus | **Decision-maker** — picks agents + models per phase, picks reviewers per diff. Ephemeral, spawned twice per workflow. |
| `accessibility-auditor` | Opus | WCAG 2.2 AA/AAA audits — keyboard nav, screen reader, contrast |
| `performance-benchmarker` | Opus | Performance measurement, Core Web Vitals, before/after benchmarks |
| `docs-lookup` | Sonnet | On-demand library/framework doc queries via Context7 MCP |

---

## Agent Handover

When a subagent finishes, it returns results in its response message. The **orchestrator** appends a structured phase entry to `.claude/handover.md` in the correct order. Subagents NEVER write to handover directly — their prompts include the explicit instruction to return results rather than write to files.

See `docs/how-to/agent-handover.md` for the full format and single-writer protocol.

---

## See Also

- `docs/concepts/independence-principle.md` — why the four-role split exists and how hooks enforce it
- `docs/how-to/agent-handover.md` — handover file format, Single-Writer Rule details
- `skills/agent-orchestration/SKILL.md` — model assignment table, phase-to-agent mapping, conditional agents + parallel execution (moved out of `rules/agents.md`)
- `rules/agents.md` — the always-loaded orchestration directives (four roles, Iron Law, phase summaries, Jira/handover)
- `commands/flow.md` — the canonical workflow that orchestrates all four roles
- `skills/code-review-orchestration/SKILL.md` — the skill that wraps chief-of-staff's second spawn
