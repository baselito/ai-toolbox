---
name: subagent-liveness
description: RETIRED — superseded by the `observed-work` skill. The monitor design this skill used to carry made a MODEL the sensor, and it fabricated its measurements. Load `observed-work` instead whenever the orchestrator spawns a background subagent expected to run more than ~5 minutes, or starts any review-round sequence or loop.
source: custom
---

# Subagent Liveness — RETIRED, use `observed-work`

**→ Load the `observed-work` skill. The mechanism is `scripts/observe.sh`.**

## What this skill used to say, and why it is gone

This skill told the orchestrator to spawn a dedicated Haiku monitor agent
alongside every long background subagent, and gave it a prompt describing a
"bounded background poll loop" over worktree file mtimes and `git log`.
<!-- tier-ok: names Haiku only as the retired monitor design, not a current tier assignment -->

**It failed in production, and it failed structurally.** The monitor reported
"27 checks over 40 minutes, tdd-guide STALLED". Its own usage metadata showed
**48 seconds and 4 tool calls**, and it had mislabelled which agent was which.
It had been told to pace itself with a busy-loop that takes microseconds, so it
was asked for a measurement it had no way to take — and it produced a plausible
one instead of reporting that it could not comply.

**No prompt fixes that.** The design is retired rather than reworded, because
the root cause was the architecture: a model was made the sensor. Two things
were wrong with it, and they are independent:

1. **A model cannot be the sensor.** A language model asked for a measurement it
   cannot take will produce a believable one. Sensing has to be a script with a
   real clock, and the model's job has to be judgement over what that script
   recorded.
2. **mtimes are the wrong progress signal anyway.** An agent that rewrites the
   same failing file every cycle touches that file every cycle, so an
   mtime-keyed monitor calls it healthy forever — which is precisely the case a
   progress guard exists to catch. This is rung 2 of the verification ladder in
   the `loop-design` skill: "actively misleading".

## What replaces it

| Concern | Where it lives now |
|---|---|
| Declaring work before it starts, with a validated exit predicate and a mandatory hard deadline | `observed-work` skill → Step 1; `scripts/observe.sh declare` |
| Detecting that a subagent has gone quiet | `scripts/observe.sh watch` → `SILENT` at 1.5x the declared check-in interval, and `CHECKIN_DUE` at 1x |
| Catching a fabricated progress report | `scripts/observe.sh checkin` → `MISMATCH` (`working-no-delta`), computed from a re-run probe, not judged |
| Catching a false "it's done" | `MISMATCH` (`good-not-done`), and `close --outcome shipped` refuses while `done_when` is false |
| Bounding the wait | `hard_deadline_s`, per-probe execution bounds, and the watcher's own idle-exit + lifetime cap |
| Judgement about whether the work is on track | `agents/observer.md` — reads the log the script wrote; measures nothing |

The one thing worth carrying forward, restated because it still holds:
**completion is the ORCHESTRATOR's signal, not the observer's.** A subagent is
finished when its Agent-tool call returns to the orchestrator. The observer can
tell you a task is quiet, mismatched, churning or past its deadline; it cannot
tell you the subagent's process exited.

## Applies to

Nothing directly — this file exists so links and habits land somewhere useful.
Every caller that used to load `subagent-liveness` should load `observed-work`:
`commands/flow.md` (Phase 5 implementation), `commands/review-pr.md` (fix
agents), `rules/agents.md` → "Subagent Liveness", and
`skills/flow-reference/SKILL.md`.
