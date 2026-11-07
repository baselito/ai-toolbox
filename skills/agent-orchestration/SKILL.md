---
name: agent-orchestration
description: The agent-selection reference behind the always-loaded agents rule — which conditional agents activate for which changed-file patterns, which agents run in parallel vs sequentially, and the fixed per-agent model assignments (Opus/Sonnet/Haiku). Load this when selecting which agents/models run at a workflow phase, or which review agents to run at code review (chief-of-staff reads this).
source: custom
---

# Agent Orchestration — selection reference

The orchestration directives live in the always-loaded `rules/agents.md` (four roles, chief-of-staff spawn points, the Iron Law that the orchestrator never selects agents or writes feature code inline). This skill carries the lookup tables chief-of-staff consults when deciding **which** agents run for a given diff and **how** they're sequenced. Load it on demand at agent-selection time; the directives that govern *who decides* stay always-loaded.

## Conditional Agents (based on files changed)

| Files changed | Agents activated | Execution |
|---|---|---|
| `*.razor`, `*.blazor`, `*.tsx`, `*.jsx`, `*.html` | `evidence-collector` + `accessibility-auditor` | Parallel with code-reviewer |
| `*Migration*`, `*DbContext*` | `database-reviewer` | Parallel with api-tester |
| `*Controller*`, `*Endpoint*` | `api-tester` + `security-reviewer` | api-tester parallel with database-reviewer; security-reviewer after |
| `appsettings*`, `*auth*`, secrets | `security-engineer` + `security-reviewer` | Sequential: engineer first |
| `*Pipeline*`, `*.yml` | `devops-automator` | After code-reviewer |
| Major architecture change | `architect` + `planner` | Before implementation |
| Any code | `doc-updater` | After all reviewers |
| Any task with Jira | `jira-workflow-steward` | Throughout |
| `/perf` workflow or performance tests | `performance-benchmarker` | After systematic-debugging |
| Library/framework usage questions | `docs-lookup` | On demand by any agent |

## Parallel Execution

- `code-reviewer` + `evidence-collector` + `accessibility-auditor` → run in parallel
- `database-reviewer` + `api-tester` → run in parallel
- `security-engineer` → `security-reviewer` → sequential (engineer first)
- `performance-benchmarker` → after systematic-debugging, before code-reviewer
- `reality-checker` → always last, waits for all others

## Model Assignments

Model assignments are fixed per agent. Do not override unless explicitly configured:
- Opus — deep reasoning: architect, security-engineer, chief-of-staff, planner
- Opus — review and execution: tdd-guide, code-reviewer, security-reviewer, database-reviewer, e2e-runner, refactor-cleaner, build-error-resolver, reality-checker, api-tester, devops-automator, incident-response-commander, project-manager-senior, accessibility-auditor, performance-benchmarker
- Sonnet — retrieval, capture and ops monitoring only: docs-lookup, evidence-collector, harness-optimizer, loop-operator
- Haiku: doc-updater, jira-workflow-steward

Frontmatter is authoritative for every NAMED agent — spawn by `subagent_type` and pass no
`model:`. Anonymous subagents (`general-purpose`, or no `subagent_type`) have no frontmatter and
MUST carry an explicit `model:`. `scripts/check-agent-tier-drift.py` fails the build if this list
ever drifts from the frontmatter, so update the agent file, not just this table.
