# Handover Protocol

Before starting any work, check for handover context from the previous session.

## ⛔ SINGLE-WRITER RULE — ONLY THE ORCHESTRATOR WRITES TO HANDOVER ⛔

The handover file has ONE writer: the main orchestrating agent. Subagents NEVER write to `.claude/handover.md` directly. This prevents two problems:

1. **Ordering chaos** — when subagents write independently, their entries land in whatever order they complete, not in workflow order. The reality-checker once wrote its entry directly and pushed the Assessment entry out of order.
2. **Duplicate runs** — when subagents don't receive prior context, they redo work already in the handover (full test suite ran 3× in one workflow because subagents couldn't see that implementation already ran it).

### The correct cycle

```
1. Orchestrator reads handover.md          (knows what's done so far)
2. Orchestrator spawns subagent             (passes relevant prior context in prompt)
3. Subagent does its work                   (does NOT write to handover)
4. Subagent returns results in response     (in its final message)
5. Orchestrator appends results to handover (in the correct phase order)
6. Orchestrator spawns next subagent        (passes what it needs from steps 1-5)
```

### Subagent prompts MUST include this instruction

Every subagent spawn prompt must include:

```
Return your results in your response message.
Do NOT write to .claude/handover.md — the orchestrator handles that.
```

This instruction-based enforcement replaces the previous `enforce-handover-writer.sh` hook approach. The hook was removed because it required a write-token on every handover write, creating friction in every workflow. The Single-Writer Rule is now enforced by this prompt instruction — subagents that follow instructions will not write directly. Subagents can still read the handover file freely for context.

### Phase append order (orchestrator follows this regardless of completion order)

```
1. Discovery
2. Execution Plan (chief-of-staff)
3. Assessment
4. Brainstorming
5. Planning
6. Implementation
7. Code Review (includes tdd-guide, code-reviewer, reality-checker findings consolidated)
8. Verification
9. PR Creation
```

The orchestrator reads subagent results from response messages and appends to handover in this order — even if subagents return out of sequence.

## On Every Task Start

1. Read `.claude/handover.md` if it exists — previous phase findings from this or prior sessions.
2. If the file is absent, this is a fresh task — proceed normally.

There is only one handover file. Tool-switching handover files (antigravity-handover.md, backup-handover.md) have been removed as part of dropping Antigravity support. If a developer opens a project that has stale copies of those files from an older install, the next run of `install.sh` auto-deletes them during the migration-cleanup step.

## Switching between providers

Claude and Codex use the same durable GoalRun state and handover file. The
orchestrator remains the single writer; the provider continuing the run reads
the last verified phase and next action. Native host features are used only
when available, while the shared runtime preserves the workflow contract.

## During Workflows

After completing each workflow phase, append your findings to `.claude/handover.md`. **Be
specific** — if the session ends and resumes later, the next invocation must be able to continue
from this entry with no other context. Vague entries like "implemented the feature" or "reviewed
the code" are not acceptable; name the files touched, what was found, and what the next phase
needs.

Every entry carries: phase name, completion status (PASSED / PASSED WITH NOTES / BLOCKED), the
agent and model that ran it, what was done, what was found, files changed, what the next phase
should focus on, **Deviations**, and blockers.

**The `Deviations` field is mandatory and is the seed for toolbox self-improvement.** Record any
point where the prescribed process was not followed — rule violation, missing guidance, ambiguous
instruction, tool brittleness, or a context constraint — whether or not it affected the outcome.
Name the specific rule, state the judgment you made, note the effect, and propose a prevention.
Honest reporting is explicitly safe: a self-reported deviation signals a toolbox ambiguity to fix,
not a fault. If there genuinely were none, write `None observed.` — blank is not acceptable.

The **exact entry template**, the five deviation categories with worked examples, and what happens
to captured deviations are in the **`handover-protocol` skill**. Load it when writing an entry.

## Rules

- **Append, never overwrite** — each phase adds to `.claude/handover.md`. Never delete previous entries within an active task.
- **New task = clear the file** — when starting a genuinely new task (not a continuation), clear `.claude/handover.md` and start fresh.
- **Single writer** — only the main orchestrator writes. Subagents return findings; the orchestrator appends them in phase order.
