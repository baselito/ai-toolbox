---
name: performance
source: ECC (common/)
scope: always active
---

# Performance Rules

Model routing, context window limits, and efficiency rules.

## The four tiers

| Tier | Model | Who runs here | Set by |
|---|---|---|---|
| **Orchestrator** (the thinker) | **Fable** | The persistent main session agent — coordinates phases, routes work, reads handover, spawns subagents. Writes no feature code. | `"model": "fable"` in `~/.claude/settings.json` |
| **Deep reasoning** | **Opus** | Ephemeral subagents doing architecture, multi-file planning, threat modelling, reviewer selection: `chief-of-staff`, `planner`, `security-engineer`, `architect` | Agent frontmatter `model: opus` |
| **Quality execution** | **Opus** | Review agents and implementing subagents — deliberately raised from Sonnet; see "Why review runs on Opus" below | Agent frontmatter `model: opus` | <!-- tier-ok: the Opus row's own text records that this tier was raised FROM Sonnet -->
| **Retrieval / capture** | **Sonnet** | Documentation lookup, screenshot capture, ops monitoring — no code judgement involved | Agent frontmatter `model: sonnet` |
| **Fast / mechanical** | **Haiku** | Jira transitions, commit messages, doc sync, liveness monitors | Agent frontmatter `model: haiku` |

**Why Fable orchestrates.** The orchestrator's job is judgment and routing across a long-lived session — deciding what runs next, reading results, keeping the workflow coherent. It is the one role that is continuously in context and never writes production code. The heavy lifting (implementation, review, planning) is delegated down to ephemeral subagents, which get fresh context per spawn. <!-- tier-ok: 'implementation, review, planning' names the work delegated AWAY from Fable, not tiers for it -->

**Why review runs on Opus.** Review and execution were on Sonnet until July 2026. They were
raised deliberately, and the honest case is mixed — record both halves so this is revisited on
evidence, not vibes:

- *For:* review's failure mode is the subtle miss, and misses did ship. In one toolbox session
  two unit tests passed for the wrong reason (a fixture writing a literal `\n`, and an assertion
  that would have accepted a `deny` where it required a fall-through). No Claude reviewer caught
  either; the external PR reviewer did. Catching that class is exactly what deeper reasoning buys.
- *Against:* in that same session the defects were authored by the ORCHESTRATOR running on the top
  tier at high effort, not by the Sonnet subagents of the time — and two of the blocks that caught them came from
  Sonnet compliance auditors. A higher tier is not what found the bugs; independent adversarial
  review from a different model family was.
- *Cost:* `code-reviewer`, `tdd-guide`, `security-reviewer` and `reality-checker` run on EVERY code
  change. Moving all four multiplies per-workflow review cost.

Retrieval and capture stayed on Sonnet (`docs-lookup`, `evidence-collector`) and mechanical work
stayed on Haiku, because nothing in the evidence implicates them.

**The orchestrator tier is a default, not a guarantee.** `settings.json` sets the session model; the developer can override it at any time with `/model`. Docs describe the intended default — they must not claim the orchestrator is *always* Fable.

## Model and Effort Assignment

Every agent declares two things **statically** in its frontmatter — they are never chosen at runtime:

- `model:` — the tier: `opus` (deep reasoning AND quality execution), `sonnet` (retrieval/capture), `haiku` (mechanical), or `fable` (orchestrator).
- `effort:` — the reasoning effort for that tier: `low`, `medium`, `high`, or `xhigh`. Optional; if omitted, the agent inherits the session default `effortLevel`; only if that is also unset does the model's built-in default apply.

**Frontmatter is the single source of truth for NAMED agents.** When the orchestrator spawns an agent that has its own file under `agents/` (or an ECC/plugin agent), it passes `subagent_type` and **no `model:` argument** — that agent's frontmatter decides its tier. Never pass a `model:` that differs from an agent's frontmatter; if a tier needs to change, change the frontmatter through a reviewed PR.

**The two documented escalations are the ONLY exception**, and they are bounded rules, not free choice: `project-manager-senior` (for complex cross-team work) and `systematic-debugging` (after 2 failed attempts) — see `docs/reference/model-assignments.md` → "Escalation Rules". When an escalation condition is met, that ONE spawn carries an explicit `model: "opus"`. Note `systematic-debugging` is a skill, not an agent: escalating it means the subagent invoking the skill is spawned on Opus. No other named agent is ever spawned off-frontmatter. (This replaces the former "Fable preferred, Opus fallback" spawn-time override, which existed only because Fable was temporarily available. Fable is now permanent and sits at the orchestrator tier, so the override is gone.) <!-- tier-ok: names the retired Fable-preferred mechanism as history, not a claim about project-manager-senior -->

**Anonymous subagents are the one place `model:` is required.** A spawn with no `subagent_type`, or with `subagent_type: "general-purpose"`, has no frontmatter to read — so it inherits the session model (Fable) unless told otherwise. These MUST carry an explicit `model:` (`opus` for implementation/verification/PR subagents — they do the same class of work as the review agents; `haiku` for liveness monitors and mechanical work), or the spawn silently inherits the orchestrator tier. This is not an override: there is nothing to override. <!-- tier-ok: names haiku for liveness monitors and opus for execution subagents, both correct -->

**Bare aliases resolve to the latest generation.** `model: opus` maps to the newest Opus available to your install, `sonnet` to the newest Sonnet, `haiku` to the newest Haiku, `fable` to the newest Fable. The toolbox pins NO model version — you get the current model automatically, without editing anything. There is no `model_routing` knob in PROJECT.md — model selection lives in agent frontmatter, not per-project config.

**These are static config, not runtime improvisation.** Each agent's `model` and `effort` live in its frontmatter and change only through a reviewed PR. `chief-of-staff` builds the per-phase plan by selecting *which* agents run — each agent brings its own frontmatter `model`/`effort`; chief-of-staff does not invent new tiers or rewrite frontmatter. An agent never self-selects its own tier or effort. The only runtime tier changes are the two pre-defined escalation rules (`project-manager-senior` and `systematic-debugging` → the deep-reasoning tier) documented in `docs/reference/model-assignments.md` — bounded rules, not free choice. Every spawn is logged by `audit-model-usage.sh`.

**Effort is tuned to the work, not blanket-applied.** `effort:` is optional — an agent with no `effort:` field inherits the session default (`effortLevel`, see below). This repo sets `effort:` explicitly only on the agents it owns (the files in `agents/`):

- `security-engineer` (Opus) → `high` — threat modelling is deep-reasoning work.
- `docs-lookup`, `evidence-collector` (Sonnet) → `low` — pure retrieval / screenshot capture, no multi-step reasoning.

Every other agent intentionally has NO `effort:` field and inherits the session default:

- The ECC-plugin agents we still use as-is (`architect`, `planner`, `doc-updater`, `harness-optimizer`, `loop-operator`) are not edited here — they live in the plugin cache and run at the session default. (`reality-checker` was previously listed here in error: it is one of the 8 LOCAL-OWNED Agency agents in this repo's `agents/`, not an ECC agent. The review agents `code-reviewer`, `tdd-guide`, `security-reviewer`, `database-reviewer`, `e2e-runner`, `refactor-cleaner` and `build-error-resolver` are now vendored here too, at Opus.)
- `chief-of-staff` is vendored in this repo's `agents/` directory (not ECC — see `agents/chief-of-staff.md` for why) but also intentionally carries no `effort:` field, for the same reason as the ECC deep-reasoning agents above: it inherits the session default.
- Every review/execution agent inherits the session default too — none carries an `effort:` pin. The four that used to pin `effort: medium` (`api-tester`, `devops-automator`, `accessibility-auditor`, `performance-benchmarker`) had it removed: pinning them BELOW the session default was silently capping the reasoning on checklist work that turned out to need it.
- Haiku agents (`jira-workflow-steward`, `doc-updater`, etc.) ignore effort — Haiku has no effort levels in the current generation.

To change the session-wide default, set `effortLevel` in `~/.claude/settings.json` (`low` / `medium` / `high` / `xhigh`) or run `/effort`. A per-agent `effort:` in frontmatter overrides the session default for that agent only (precedence: frontmatter `effort` → `effortLevel` → the model's built-in default).

## Context Window Limits

- Recommended: under 60 MCP tools active
- Acceptable: 60-80 tools
- Never exceed: 80 tools
- Check with `/mcp`

When context is under pressure:
- `strategic-compact` skill suggests compaction
- `harness-optimizer` (Sonnet) monitors usage
- Disable unused MCPs per project via `.claude/settings.json`

## Non-Negotiable Deep-Reasoning Costs (Opus tier)

Some deep-reasoning calls are mandatory regardless of ticket complexity. These agents carry `model: opus` in frontmatter and the orchestrator spawns them by name — no `model:` argument is passed:

| Agent | Why it's always deep-reasoning tier | Cost |
|---|---|---|
| `chief-of-staff` | Independent review orchestration — the orchestrator has session-level context about the implementation (what the subagent tried, what worked, what was hard) that biases reviewer selection. Chief-of-staff is a fresh subagent with no prior session context. | ~500 tokens per call |
| `planner` | Deep reasoning for multi-file plans — Sonnet plans miss dependencies | Varies |
| `security-engineer` | Threat modelling requires deep reasoning | Varies |
| `architect` | System design decisions | Varies |

**Chief-of-staff runs on the deep-reasoning tier even for "simple" tickets.** The ~500-token cost is non-negotiable overhead — the same way you always run tests even for "simple" changes. The orchestrator does NOT get to skip chief-of-staff to save tokens. Past incidents show the orchestrator missed agents (doc-updater, security-reviewer) when it picked reviewers itself — not because it wrote the code (the Opus implementing subagent did), but because the orchestrator had the full session context and unconsciously prioritised review angles that matched what the implementing subagent already handled, missing what it hadn't.

Note: all four agents in this table carry `model: opus` in frontmatter. The orchestrator spawns them by `subagent_type` alone — it passes no `model:` argument, so the frontmatter tier applies. Chief-of-staff's independence comes from being a **fresh ephemeral subagent** with no session context, not from which model it runs on.

## Efficiency

- Avoid unnecessary tool calls — plan before acting
- Use subagents for isolated tasks to keep the main context clean
- Haiku for all low-complexity operations: git commits, branch naming, Jira status moves, documentation updates
- Do not use Opus for tasks that Sonnet can handle — except the non-negotiable list above
- Do not use Sonnet for tasks that Haiku can handle

## Codex (optional cross-family collaborator — best-effort, never a blocker)

Codex (OpenAI's GPT-5.6 via the `@openai/codex` CLI) is an **optional** cross-family second
opinion for local pre-PR review, active only when the developer opted in at install AND `~/.claude/memory.md` contains
`- Codex: enabled`. Directives:

- **The local reviewer is review-only, at most one pass per task.** The pre-PR adversarial pass
  on the final diff is Codex's only routine use in this optional reviewer mode. A separately
  configured `GOAL_LOOP_CODEX_COMMAND` can run the shared bounded GoalRun workflow; it is a
  provider adapter, not a second copy of the planner or skills. (`codex:rescue` is a narrow
  exception for a genuinely stuck fix.) This distinction conserves a tight workspace spend cap.
- **The gate runs `gpt-5.6-terra` at `xhigh`** (floor `high` for light diffs; `ultra` only when
  RARE and user-confirmed; `low` for non-gate mechanical calls). `medium` and `max` are
  deliberately unused.
- **Never blocks and never waits.** If Codex is not installed, not enabled, spend-capped, or
  fails for any reason, the agent proceeds immediately on the Claude-only path, records the
  outage so it stops retrying, and lets configured reviewer review the PR. It does NOT stall the workflow
  or prompt the user to raise the cap mid-task.
- **Never authority.** Codex always runs `--sandbox read-only`; its output is advice the
  orchestrator verifies and decides on.
- **Don't** spend Codex on commit messages, branch names, status/polling, Jira transitions, or
  mechanical work (deterministic hook → Haiku → never Codex), and don't re-run it over an
  unchanged diff.

**Data boundary:** Codex sends prompts, selected code/diffs, and files it reads to OpenAI under
the user's configured data controls. Skip Codex for secrets, embargoed code, or data the project
is not allowed to share.

Full detail — the model pin-and-fallback contract, the per-effort rationale, the graceful-
degradation mechanics and the cause-based outage TTLs — lives in the **`codex-review` skill**.
Load it when running or debugging the review gate.

## Applies To

All agents, all model selection decisions, all tool usage.
