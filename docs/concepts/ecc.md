# ECC — Everything Claude Code

What ECC is, what it provides, and why it is the foundation of this toolbox.

---

## When to Read This

- You want to understand where most of the agents, skills, and rules come from
- You are troubleshooting ECC plugin issues
- You want to understand what ECC provides vs what the toolbox adds on top

---

## What Is ECC?

ECC (Everything Claude Code) is a comprehensive plugin by `affaan-m` that provides the foundational agents, skills, rules, and hooks for Claude Code. It is the base layer that this toolbox builds upon.

**Repo:** `affaan-m/everything-claude-code`

---

## What ECC Provides

### 12 Agents

> **Tier attribution:** seven of these (`code-reviewer`, `tdd-guide`, `security-reviewer`, `database-reviewer`, `e2e-runner`, `refactor-cleaner`, `build-error-resolver`) are **vendored into this repo** at `agents/` and run on Opus. ECC's own copies remain `model: sonnet` in the plugin cache — the Opus tier is this repo's, not ECC's. Only the five still used as-is (`architect`, `planner`, `doc-updater`, `harness-optimizer`, `loop-operator`) run at ECC's tier. <!-- tier-ok: the contrast IS the content — these seven run at Opus here and remain Sonnet in ECC's plugin cache; stating both is the point -->

> **Note:** ECC originally also provided `chief-of-staff` (Opus, agent orchestration). Upstream repurposed that agent into a personal communications triage bot (email/Slack/LINE/Messenger) — a different system prompt entirely. This toolbox now vendors its own `chief-of-staff` (`agents/chief-of-staff.md`, listed under Custom Agents) so the orchestration role can't silently drift again.

| Agent | Model | Role |
|---|---|---|
| `architect` | Opus | System design |
| `planner` | Opus | Implementation plans |
| `tdd-guide` | Opus | TDD enforcement |
| `code-reviewer` | Opus | Quality review |
| `security-reviewer` | Opus | Vulnerability scanning |
| `database-reviewer` | Opus | DB analysis |
| `e2e-runner` | Opus | Playwright E2E tests |
| `refactor-cleaner` | Opus | Dead code removal |
| `doc-updater` | Haiku | Documentation sync |
| `build-error-resolver` | Opus | Build error fixes |
| `harness-optimizer` | Sonnet | Performance monitoring |
| `loop-operator` | Sonnet | Loop stability |

### 18 Skills

Including tdd-workflow, coding-standards, backend-patterns, frontend-patterns, security-review, verification-loop, api-design, workflow-discovery, deep-research, e2e-testing, blueprint, and more.

### 7 Rules (common/ + typescript/ only)

- security.md
- coding-style.md
- testing.md
- git-workflow.md
- agents.md
- performance.md
- handover.md

Go/Python/Golang rules are not installed — they are not part of the toolbox stack.

### Hooks

ECC includes hooks for continuous learning and strategic compaction that run automatically.

---

## What This Toolbox Adds on Top

| Component | Source | Why |
|---|---|---|
| 7 additional skills | Superpowers (`obra/superpowers`) | Fills gaps: brainstorming, systematic debugging, worktrees, verification, branch finishing, test-driven-development, receiving-code-review |
| 23 custom skills | This repo | advisory-discovery, code-review-orchestration, discovery, work-breakdown, respond-to-pr-reviews, codex-review, workflow-discipline, pr-automation, edge-cases, cross-tool-sync, agent-orchestration, subagent-liveness, observed-work, handover-protocol, flow-reference, loop-design, mutation-testing, presentation-master, and 5 sample application-specific skills |
| 8 additional agents | Agency (`msitarzewski/agency-agents`) | Fills gaps: PM, Jira, DevOps, incident, security architecture, evidence collection, readiness gate, API testing |
| 4 custom agents | This repo | accessibility-auditor, performance-benchmarker, docs-lookup, chief-of-staff |
| 20 custom commands | This repo | Structured workflows not in ECC |
| 2 MCP connections + Jira via acli + GitHub via gh CLI | This repo | External service integration |

---

## Installation

ECC is installed as a full plugin by `install.sh`:

```bash
claude plugin marketplace add affaan-m/everything-claude-code
claude plugin install everything-claude-code@everything-claude-code
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| ECC plugin not found | Re-run both plugin commands above |
| ECC agents not available | Check that the plugin is installed: `claude plugin list` |
| Rules from wrong language | Only ECC common/ rules should be active (customized for toolbox) — check `~/.claude/rules/` for unexpected language-specific files |
