---
name: agents
source: ECC (common/)
scope: always active
---

# Agent Rules

Agent invocation patterns, handover protocols, and context management rules.

## Orchestration — four roles

This toolbox splits agent responsibilities across four distinct roles. See `docs/concepts/agents.md` for the full explanation; below is the rule summary.

| Role | Model | Lifetime | What it does |
|---|---|---|---|
| **Orchestrator** (main Claude Code agent) | Fable (session default — `rules/performance.md`) | Persistent | Coordinates phases, writes `.claude/handover.md`, spawns subagents. Does NOT write feature code inline. |
| **Chief-of-staff** (subagent) | Opus (frontmatter — `rules/performance.md`) | Ephemeral | Decides which agents + models run at each phase (Step 1.8) and for code review (Step 9). Does not execute anything. |
| **Implementing subagent** | Opus | Ephemeral | Writes feature code in Phase 5 (Implementation). Spawned by orchestrator with `[DELEGATED]` marker. |
| **Review agents** (code-reviewer, reality-checker, etc.) | Opus mostly | Ephemeral | Read the diff after implementation. Return findings. Never write production code. |

### Chief-of-staff spawn points

Chief-of-staff is spawned **twice** per workflow:

1. **Step 1.8 (Execution Plan)** — After Discovery, chief-of-staff reads the ticket and produces a per-phase plan assigning the correct agent + model
2. **Step 9 (Code Review)** — Via the `code-review-orchestration` skill, chief-of-staff reads the git diff and picks which review agents run

Not all agents run on every task — chief-of-staff activates only the relevant ones. Each agent runs on its own model (Opus/Sonnet/Haiku) — chief-of-staff assigns, the orchestrator does not override. <!-- tier-ok: generic tier enumeration, not a per-agent claim -->

**⛔ The orchestrator is a COORDINATOR, not a decision-maker or a code writer. ⛔**

The orchestrator follows the execution plan from chief-of-staff. It does NOT:
- Decide which agents or models run at any phase → `chief-of-staff` decides at Step 1.8
- Decide which review agents to run → `chief-of-staff` decides again at Step 9
- Write feature code inline → spawn an Opus **implementing subagent** (Phase 5)
- Run skills inline on the orchestrator → create `~/.claude/.skill-delegation-token` then spawn an Opus subagent with the `[DELEGATED]` marker (enforced by `enforce-skill-delegation.sh`)
- Decide design approach → `brainstorming` skill explores
- Write the implementation plan → `planner` agent (deep-reasoning tier) creates
- Post Jira comments directly → `jira-workflow-steward` (Haiku) handles
- Decide whether to skip a step → a Scope ask, unless pre-authorized at kickoff.

If the orchestrator bypasses a designated agent and does the work inline, that is a compliance violation — even if the result is correct. The process exists for:
- **Cost control** — right model for right task (work done inline on the orchestrator costs far more than the same work in an Opus subagent)
- **Independence** — independent review chain (chief-of-staff picks reviewers without writer bias)
- **Auditability** — handover trail shows who did what

**Compliance logging.** Every Agent spawn is logged by the `audit-model-usage.sh` PostToolUse hook to `~/.claude/model-audit.log` (timestamp + agent name + model). This creates an external compliance trail independent of the handover file — even if a handover entry omits the model, the audit log has it. The log is the authoritative source for verifying that the right model was used per phase (chief-of-staff on the model the tier prescribes — see `rules/performance.md`; jira-workflow-steward on Haiku; etc.). See `docs/concepts/independence-principle.md` for the full deterrent rationale.

Terminology note: older docs sometimes use "implementing agent" to mean the orchestrator (coordinator role) or the Opus subagent (code writer) depending on context. Going forward:
- **"Orchestrator"** = main Claude Code agent (orchestrator tier — Fable, persistent, coordinator)
- **"Implementing subagent"** = Phase 5 Opus subagent (writes code)
- **"Chief-of-staff"** = deep-reasoning-tier decision-maker subagent (ephemeral)

## Phase Summaries (global rule)

After completing each workflow phase (discovery, ticket assessment, brainstorming, planning, implementation, code review, verification, PR creation), the agent MUST do ALL FOUR:
1. **Append to `.claude/handover.md`** — write what was done, found, and what the next phase needs. Do this FIRST.
2. Present a **phase summary card** to the user (see format below)
3. Give the **agent's honest opinion** — concerns, suggestions, or agreement (mandatory even if no concerns: "No concerns — this looks straightforward")
4. **Proceed.** The card is a window, not a gate: show it and continue. Ask only if Status is
   BLOCKED or a category question arose (see `rules/autonomy.md`).

### Phase summary card format (MANDATORY at every gate)

Every phase summary shown to the user MUST include this metadata block:

```
-----------------------------------------
  Phase: [phase name, e.g. Discovery, Brainstorming, Implementation]
  Status: [PASSED / PASSED WITH NOTES / BLOCKED]
-----------------------------------------
  Agent:  [which agent ran — e.g. "planner", "code-reviewer", "tdd-guide"]
  Model:  [actual] — Expected: [tier for this phase] → ✅ match / ❌ VIOLATION
  Skill:  [which skill was invoked, or "none" if direct agent]
  Rules:  [key rules that applied — e.g. "TDD enforcement", "security review"]
-----------------------------------------
  Summary:
  - [specific action 1]
  - [specific action 2]
  - [specific finding or decision]

  Jira:   [comment posted ✅ / failed ⚠️ / unreachable ⚠️ / not configured — / n/a — toolbox self-change]
  Opinion: [agent's honest assessment — concerns, risks, or "No concerns"]

  Next: [next phase name] — [brief description]
  (At the final phase: "Next: Done — workflow complete")

  Proceeding to [next phase]. (Interrupt to revise or stop.)
-----------------------------------------
```

**This card is shown to the user, not just written to handover.** The user must see which model, agent, skill, and rules were used at every step. This provides transparency and lets the user catch model/agent mismatches (e.g. Opus running where Sonnet should, or a required agent being skipped).

**⛔ MANDATORY: Apply any requested Jira transition or milestone update BEFORE showing the phase card ⛔**

**Exception — toolbox self-maintenance:** when the repo is `baselito/ai-engineering`, skip step 3 (Jira has no project ticket); in step 4 show the card with `Jira: n/a — toolbox self-change`.

The phase summary card is the gate between phases. A Jira transition or requested milestone update is part of that gate; an internal phase alone is not a Jira-writing event. The sequence is:

1. Phase work completes → subagent returns results
2. Orchestrator appends to handover.md
3. **Orchestrator invokes jira-workflow-steward (Haiku) only for the required transition or concise milestone update** — this happens NOW, before the card
4. Orchestrator shows phase summary card to user (includes the Jira result when an update or transition was requested)
5. Proceed to next phase (autonomy rule).

If Jira is unreachable during a requested transition or milestone update, show "Jira: unreachable ⚠️ — retry when available" in the card and continue. Never block the workflow for Jira, but never silently hide a requested update.

The phase card template above includes a `Jira:` status line. If this line is missing from a phase card, the orchestrator violated this rule. For an internal phase with no Jira action, use `Jira: no update — internal phase`.

**Incident history:** TASK-742 and TASK-747 had incomplete Jira traceability because writes were blocked or forgotten. The milestone policy keeps meaningful updates visible without copying every internal phase into Jira.

**Write for beginners and testers** — explain technical terms on first use, say what things do (not just tool names), use plain language for opinions. Jira comments follow the same rule. Keep summaries scannable in 10 seconds.

**Code comments are mandatory** — see `rules/coding-style.md` for the comment guidelines (file/class purpose, section purpose, non-obvious logic, why not just what).

**⛔ DO NOT SKIP PHASE SUMMARIES FOR "SIMPLE" TICKETS ⛔**

Every phase gets a summary card — the user decides whether to speed up, not the agent. At every gate: say what you think, show what you considered and dismissed, flag discrepancies, volunteer opinions about the ticket scope.

## Jira Comments (global rule)

**Toolbox self-maintenance exception:** when `git remote get-url origin` resolves to
`baselito/ai-engineering`, Jira comments and transitions are skipped because the toolbox has no
project ticket. Full orchestration still runs. Every project repo follows the concise rule below.

**Jira updates are milestone-based.** A normal run posts only short, useful updates:

- **Start:** one sentence when work begins.
- **PR/milestone:** one sentence when a reviewable deliverable or PR is available.
- **Completion:** one sentence when the work is complete.
- **Blocker (exception):** one short sentence only when a human decision or visible ticket impact requires it. A separate resolution comment is optional only if the ticket would otherwise still look blocked.

Routine phase summaries, brainstorming, planning detail, reviewer activity, polling, retries,
provider switches, installation, and test output belong in the handover, PR, or tool logs — not
in Jira comments. Board transitions still use `jira-workflow-steward` and the live phase map;
the comment policy does not change where a ticket moves.

The steward posts a milestone comment only when the orchestrator explicitly requests one. It
does not post a comment for every phase or infer a comment from an internal phase handover.
Ticket descriptions must still say why the work matters, not only what changes.

**Delegation token.** The `enforce-jira-delegation` hook blocks direct `acli jira` writes
(comment, assign, transition) unless a valid token exists. The orchestrator creates it ONCE per
workflow: `touch ~/.claude/.jira-delegation-token` — session-level, valid 3600s, NOT consumed on
use, so one token covers every steward spawn. Read-only operations (view, search, board, auth),
clean standalone project list/view, and introspection flags (`--help`, `--version`) are exempt.

## Ticket Description Quality (global rule)

Every Jira ticket the toolbox CREATES must use the structured description template in
`agents/jira-workflow-steward.md` → "Ticket Description Template". This applies to ALL
ticket-creating paths: `/flow` agent-first mode, `/build`, `/bug`, `/security`, and the
`work-breakdown` skill.

- **`## Summary` and `## Acceptance Criteria` are MANDATORY** — the steward runs a pre-create
  self-check and MUST NOT create a ticket without both. A ticket without Acceptance Criteria is
  not ready for development.
- All ticket creation goes through `jira-workflow-steward` (Haiku) using `--description-file`,
  never a one-paragraph `--description` string.
- The full section list (mandatory, recommended, optional) and the self-check are in the
  steward agent file — do not maintain a second copy here.

## Beads Continuity (global rule)

When picking up a ticket, ALWAYS check for an existing Beads issue before creating a new one:

1. `Bash(bd ready --json)` — is there already an open issue for this ticket?
2. Found → `bd update [ID] --status in_progress` (continue where it left off)
3. Not found → `bd create` + `bd update [ID] --status in_progress`
4. NEVER create a duplicate Beads issue for a ticket that already has one

This covers next-day continuation, interrupted sessions (rate limit, compaction), and
`/continue` resumption.

**⛔ Before running `bd init` in any project repo, run the toolbox-gitignore pre-check. ⛔**
Verify `.beads/`, `AGENTS.md`, `CLAUDE.md`, `.claude/` and `ai-engineering/` are gitignored AND
not already tracked — gitignore alone does NOT stop already-tracked files; `git rm --cached`
does. If anything is already tracked, STOP and untrack it before `bd init`, or the leak gets
worse. The exact pre-check script is in the **`workflow-discipline` skill** → "Toolbox gitignore
pre-check". (Production incident: PR #100 on e2e-tests shipped 22 toolbox files in the diff.)

## CLI Command Verification (global rule)

Before using any CLI tool (acli, gh, bd, docker, etc.) in documentation or agent code:

1. **Verify syntax with `--help`** — never write a command from memory. Run `<tool> <subcommand> --help` and confirm every flag exists.
2. **Test the command** — if writing a command that will be used in production, run it (or a safe variant like `--help`) to verify it works before committing.
3. **Update all references** — when a command syntax is corrected, grep the entire repo for the old pattern and fix every occurrence in the same commit.
4. **Keep the canonical reference in sync** — the `jira-workflow-steward` agent's "EXACT SYNTAX" block (`agents/jira-workflow-steward.md`) is the single authoritative acli command reference. Any acli syntax change must update that block — do not maintain a second copy here.

## Jira Phase-Map Transitions (global rule)

The toolbox reasons in **universal phases** (Discovery, Implementation, Code Review, …) and
projects to **per-board columns** only at the API boundary, via `jira_phase_map` in PROJECT.md.
Treat the phase map as a contract verified at workflow start, not assumed — boards drift.

1. **Validate the phase map at workflow start (Step 0).** Read `jira_phase_map` + `jira_board_id`
   from PROJECT.md, fetch live columns via `bash ~/.claude/scripts/jira-board-columns.sh
   $board_id --json`, and compare. If a mapped column no longer exists, pause and surface the
   drift with a best-guess remap. **Never silently retarget.**
2. **First actions on any ticket** are read-only: READ the ticket, investigate, present findings
   at the Investigation Gate. Only AFTER the user approves: create the delegation token
   (`touch ~/.claude/.jira-delegation-token`), assign the ticket, then run `phase=discovery`
   via `jira-workflow-steward`.
3. **Pass phase keys, never column names.** Valid keys: `discovery`, `ready_for_dev`,
   `in_progress`, `code_review`, `ready_for_release`, `done`. The orchestrator NEVER hardcodes a
   column name — that puts board-specific knowledge in the wrong place and breaks on rename.
4. **The steward applies 3-branch logic** (transition / already-in-place / no-transition) based on
   the phase map. The full logic, the "why three branches" rationale, and the `jira_columns`
   migration are in `agents/jira-workflow-steward.md` → "Phase Map — 3-Branch Logic".
5. **Re-read the ticket before every phase-map call** to detect external changes (assignee,
   priority, status moved by someone else). Surface any warnings to the user before continuing.
6. **Never run fallible checks in parallel with Jira calls** — a failing check (e.g. `ls .beads/`
   returning 1) cancels the batch. Run it sequentially first.
7. **Columns ≠ statuses.** Phase-map values are board column names, never status names.
8. **Post-merge transitions are repo-dependent and never automatic.** During the development
   workflow the agent advances to `in_progress` and stays there. It may auto-merge only the
   `baselito/ai-engineering` toolbox through the scoped GoalRun/live-hook gate; it never
   transitions post-merge: ai-engineering is ticketless; for project repos the user owns the
   full post-merge lifecycle. When a `done` transition IS performed via the human-triggered
   `/flow` Step 16 path, it follows the same 3-branch logic as every other phase key.

Applies to `/flow`, `/bug`, `/hotfix`, `/incident`, `/refactor`, `/security`, `/perf`,
`/review-pr`, and any other command that touches Jira tickets. Concept doc:
`docs/concepts/jira-phase-map.md`.

## Invoke Designated Skills and Agents (global rule)

When a workflow step names a specific skill or agent, the agent MUST invoke that skill/agent — not do the work inline. The designated tools exist for three reasons:

1. **Cost** — Haiku tasks done inline on the orchestrator cost far more. Every acli call, commit message, and doc update done inline instead of via Haiku subagent wastes budget.
2. **Quality** — Independent agents provide fresh perspectives. If the same agent writes code and reviews it, there's no independent review chain.
3. **Context isolation** — Subagents return summaries and free context. Inline work grows the main context until it degrades.

**Do NOT substitute inline work for:**
- `brainstorming` skill — invoke it, don't write your own analysis
- `planner` agent (deep-reasoning tier) — spawn it, don't write the plan yourself
- `code-review-orchestration` skill — invoke it at Step 9, don't spawn review agents directly
- `finishing-a-development-branch` skill — invoke it for PR creation
- `verification-before-completion` skill — invoke it, don't just run tests manually
- Haiku for commit messages — use model routing, don't write commits yourself
- `jira-workflow-steward` (Haiku) — spawn it for ALL Jira operations (transitions, comments, assignments), don't run acli inline on the orchestrator

**⛔ The orchestrator does NOT select which review agents run. ⛔**
Only the `chief-of-staff` (deep-reasoning tier) selects agents — and chief-of-staff is invoked via the `code-review-orchestration` skill, not spawned directly. The orchestrator's job is to invoke the skill. The skill spawns chief-of-staff, which reads the diffs and decides which agents to activate.

The orchestrator MUST NOT:
- Spawn chief-of-staff directly (invoke the `code-review-orchestration` skill instead)
- Spawn review agents directly (tdd-guide, code-reviewer, reality-checker, etc.)
- Skip the skill because "the ticket is simple" or "I already know which agents are needed"

**⛔ Skills are TEMPLATE LOADERS, not confirmation dialogs. ⛔** "User already confirmed" is NOT a reason to skip — confirmation is about the DECISION, the skill handles the EXECUTION (loads templates, checklists, structured content). Without the skill, subagents write PR bodies from memory with factually wrong content (observed in production).

**Enforcement (3 layers):** (1) PreToolUse hook blocks direct review agent spawns, (2) `code-review-orchestration` skill makes the correct path atomic, (3) PostToolUse compliance audit verifies chief-of-staff was used.

## Handover Protocol

Handover is orchestrator-written only — see `rules/handover.md` for the single-writer rule (subagents return results in their response; only the orchestrator appends to `.claude/handover.md`). Status values: PASSED, PASSED WITH NOTES, BLOCKED.

## Conditional Agents (based on files changed)

The file-pattern→agent table now lives in the on-demand **`agent-orchestration` skill** — load it when selecting which conditional agents activate for a diff.

## Parallel Execution

The parallel-vs-sequential execution order now lives in the on-demand **`agent-orchestration` skill** — load it when sequencing agent runs.

## Model Assignments

The fixed per-agent model table now lives in the on-demand **`agent-orchestration` skill** — load it when confirming which model tier an agent runs on. Kept here: the always-loaded orchestration directives above (four roles, chief-of-staff spawn points, the Iron Law).

## Tool Compatibility

See `rules/cross-tool-sync.md` (core directives) and load the `cross-tool-sync` skill when changing provider parity or installer surfaces.

## Context Management

- Use subagents for task execution to prevent context contamination
- Each subagent gets a fresh context for its specific task
- `harness-optimizer` (Sonnet) monitors context window usage
- `strategic-compact` skill suggests compaction when needed

## Observed Work (long background subagents, review rounds, loops)

**DECLARE the work to a script BEFORE starting it.** When the orchestrator spawns a background subagent expected to run more than ~5 minutes (Phase 5 implementation, PR-review fix agents, large ports/migrations, long test suites), begins a review-round sequence, or starts any loop, it first runs `bash "${CLAUDE_HOME:-$HOME/.claude}/scripts/observe.sh" declare …` (the `CLAUDE_HOME` form, not a hardcoded `~/.claude`, so a Windows install under `%APPDATA%\Claude` resolves too) — see the **`observed-work` skill** for the exact commands. `declare` REJECTS a broken exit predicate (not valid shell, cannot execute, already true, or too slow to answer), REJECTS a progress probe that advances on its own or answers unstably across two immediate runs, and REQUIRES a `hard_deadline_s`. That deadline is enforced by `checkin`, `close` and `probe` — before *and* after their own probes run — so the next command to touch an overdue task retires it with a snapshot and an observation cannot outlive its bound with no watcher running. (`status` is exempt: read-only.) Nothing in this toolbox starts a watcher for you.

**⛔ No model is in the sensing path, and every wait has a hard deadline. ⛔** Both are non-negotiable, and both are there because the two previous attempts failed structurally, not for want of a better prompt:

- A **Haiku monitor agent FABRICATED its report** — "27 checks over 40 minutes, tdd-guide STALLED" while its own usage metadata showed 48 seconds and 4 tool calls, with the agents mislabelled. A model was made the sensor and asked for a measurement it could not take. `scripts/observe.sh` now takes every measurement; the agent supplies only a one-word CLAIM and the script COMPUTES the contradiction (`MISMATCH`). ⚠️ State the scope honestly: prose cannot produce a false `MISMATCH`, but the agent still CHOOSES the probe, and a probe measuring the clock suppressed every one (measured). `declare` now rejects a probe whose output changes across two back-to-back runs; a slower-cycling one still gets through. See the `observed-work` skill's guarantee table. <!-- tier-ok: describes the retired Haiku monitor incident, not a current tier assignment -->
- An unbounded `until grep -q …; do sleep 5; done` ran **eleven hours** on a string that never appears. `timeout`/`gtimeout` do not exist on this machine, so every bound in `observe.sh` is `date +%s` arithmetic: a declare-time deadline enforced by `checkin`/`close`/`probe`, per-probe execution bounds, and a watcher bounded three ways (tick, idle exit, lifetime cap) with `--tick-s` clamped to the 5s rescan slice. ⚠️ The bound has been broken twice by its own fixes — a clamped sleep that never rescanned `active/`, and a forking predicate that escaped `run_bounded` because it bounds the WAIT and a fork does not wait. A probe that calls `setsid` is rejected at declaration time because it would escape the process-group sweep; one in-flight DEADLINE snapshot may still exceed the watcher lifetime by up to 30s.

**The observer AGENT judges; it never measures.** `agents/observer.md` (Fable) reads the declaration and the full append-only event log every turn, cites the event lines it relied on, and answers "not measured — declare a probe" rather than estimating. Summon it with `SendMessage` carrying only the task id and the claim — **never the facts**, because facts in the message would make its judgement depend on the observed agent's own summary. Its toolset is `Read`, `Grep`, `Glob` — no write tools and **no `Bash`**, so it cannot run the work, cannot run `observe.sh` (not even `probe`, which appends to the log), and its read-only contract is enforced by the toolset rather than by prose asking it to behave.

**`subagent-liveness` is RETIRED** — that skill now points at `observed-work`. Its mtime-keyed monitor was the wrong progress signal as well as the wrong architecture: an agent rewriting the same failing file touches it every cycle and reads as healthy forever (`loop-design` skill, rung 2). Session crons remain no substitute either — they fire only while the REPL is idle, which is exactly when a busy subagent most needs watching.

## Applies To

All agents and all orchestration decisions.
