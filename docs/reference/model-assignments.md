# Model Assignments

Complete reference of which agent runs on which model, escalation rules, and the rationale for each tier.

---

## When to Read This

- You want to know which model an agent uses
- You need to understand why certain agents use Opus vs Sonnet
- You want to understand escalation rules

---

## Fable — Orchestrator (the thinker)

The persistent main Claude Code session agent. It coordinates phases, routes work, reads the handover, and spawns subagents — it never writes feature code. Its tier comes from `"model": "fable"` in `~/.claude/settings.json`, which is a **default the developer can override per session** with `/model`.

Everything below this tier is an ephemeral subagent. A **named** agent (spawned by `subagent_type`) takes its tier from its own frontmatter — never pass a `model:` that differs from it. An **anonymous** subagent (no `subagent_type`, or `general-purpose`) has no frontmatter to read, so it **must** carry an explicit `model:` or it inherits **whatever the active session model is** — Fable by default, but any tier the developer selected with `/model` — and runs execution work there.

---

## Opus — Deep-Reasoning Subagents

This tier is reserved for agents that require architectural thinking, complex decision-making, or security analysis. All four carry `model: opus` in frontmatter, and the orchestrator spawns them by `subagent_type` alone.

| Agent | Responsibility |
|---|---|
| `architect` | System design — evaluates patterns, proposes structures, identifies risks |
| `security-engineer` | Threat modelling, zero-trust architecture, IAM design |
| `chief-of-staff` | Agent orchestration — decides which agents run, builds execution plans |
| `planner` | Multi-file implementation plans with dependencies and phases |


### Review and execution (raised from Sonnet, July 2026)

Seven of these were vendored out of the ECC plugin so the tier survives plugin updates — see any
of their file banners in `agents/`.

| Agent | Responsibility | Source |
|---|---|---|
| `code-reviewer` | Quality review with A-F grading, OWASP compliance | vendored from ECC |
| `tdd-guide` | Enforces RED-GREEN-REFACTOR, test quality and coverage | vendored from ECC |
| `security-reviewer` | Code-level vulnerability scanning | vendored from ECC |
| `database-reviewer` | DB queries, schema, migrations, N+1 detection | vendored from ECC |
| `e2e-runner` | Generates and runs Playwright E2E tests | vendored from ECC |
| `refactor-cleaner` | Dead code removal, legacy pattern modernisation | vendored from ECC |
| `build-error-resolver` | Reads build errors, applies known fix patterns | vendored from ECC |
| `reality-checker` | Production readiness gate — final sign-off | Agency |
| `api-tester` | API endpoint validation — contracts, payloads, errors | Agency |
| `devops-automator` | CI/CD pipeline review and deployment coordination | Agency |
| `incident-response-commander` | Incident triage, Seq queries, post-mortem | Agency |
| `project-manager-senior` | Business requirements to tasks, sprint scope | Agency |
| `accessibility-auditor` | WCAG 2.2 AA/AAA audits | this repo |
| `performance-benchmarker` | Response times, load testing, Core Web Vitals | this repo |

Anonymous `[DELEGATED]` implementation, verification and PR-creation subagents also run here.

**Why this tier:** These tasks require reasoning across the entire system, weighing tradeoffs, and making decisions that affect the whole codebase. Cheaper models produce lower-quality architecture and miss subtle security risks. Canonical rule: `rules/performance.md` → "The four tiers".

---

## Sonnet — Retrieval, Capture and Ops Monitoring

Sonnet is no longer the review tier. What remains here is work with no code judgement in it:
looking something up, taking a screenshot, watching a loop. Review and execution moved to Opus
(see above); the reasoning for that, including the evidence against it, is in
`rules/performance.md` → "Why review runs on Opus".

| Agent | Responsibility |
|---|---|
| `docs-lookup` | Library and framework documentation queries via Context7 (effort: low) |
| `evidence-collector` | Screenshot-based visual QA for UI components (effort: low) |
| `harness-optimizer` | Monitors agent performance and context window (ECC) |
| `loop-operator` | Stabilises long-running agent loops (ECC) |

**Why Sonnet:** these agents fetch, capture or observe. None of them judges whether code is
correct, so the deeper reasoning the review tier now buys would be spent on nothing.

---

## Haiku — Fast, Low-Cost

Haiku handles high-frequency, low-complexity tasks where speed and cost matter more than deep reasoning.

| Agent | Responsibility |
|---|---|
| `doc-updater` | Keeps documentation in sync after code changes |
| `jira-workflow-steward` | Branch naming, Jira status transitions, traceability |

**Also used for:** Git commit messages, branch naming, Jira status moves.

**Why Haiku:** These tasks follow predictable patterns and do not require deep analysis. Running them on Haiku keeps latency low and avoids spending Opus/Sonnet tokens on mechanical work.

---

## Escalation Rules

Two agents can escalate from their default model to a higher tier when conditions require it.

**The mechanism, and its current gap.** An escalation is the ONE sanctioned case where a named agent is spawned off-frontmatter: that single spawn carries an explicit `model: "opus"` (`rules/performance.md` → "The two documented escalations"). Note both escalations are now moot in practice: `project-manager-senior` sits on Opus outright since the July 2026 review-tier change, so there is no lower tier to escalate FROM, and `systematic-debugging` is a skill with no spawn site of its own — the subagent invoking it already runs on Opus. The rows below are kept as policy for a future agent that genuinely starts lower.

### project-manager-senior

- **Current tier:** Opus (frontmatter) — the escalation target IS its default, so nothing escalates.
- **Retained policy, if it ever starts lower:** escalate to the deep-reasoning tier when the work
  spans multiple teams, dependencies, stakeholders, or conflicting priorities.
- **Why the policy exists:** sprint planning for a single team is straightforward; coordinating
  across teams with competing priorities requires deeper reasoning.

### systematic-debugging

- **Current tier:** Opus — this is a skill, not an agent. It has no spawn site of its own, and the
  subagent invoking it already runs on Opus, so there is no lower tier to escalate FROM.
- **Retained policy, if it ever starts lower:** escalate after 2 failed attempts on the same issue.
- **What to do instead when two attempts fail:** widen the investigation — system interactions,
  race conditions, subtle state. Do not wait for a model change that will not come.

---

## Model Assignment Rules

- Model assignments are fixed in agent frontmatter (`model:` field) and must not be changed
- The `update.sh` script never fetches or copies agent files — all 8 Agency Agents files are LOCAL-OWNED (complete toolbox rewrites with their own frontmatter schema), so model assignments can't be touched by a sync. See `docs/how-to/update.md` "LOCAL-OWNED Files"
- Escalation is handled by the `chief-of-staff` agent at runtime, not by changing the frontmatter

---

## Related Docs

- [Agent List](agent-list.md) — full agent details
- [Agents Concept](../concepts/agents.md) — orchestration and conditional activation
- [Updating](../how-to/update.md) — why agent files (and their model assignments) are LOCAL-OWNED and never touched by updates
