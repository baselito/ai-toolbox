# GPT-6 Astra Codex planner design

## Goal

Replace the active Codex GoalRun planner/advisor identity `sol` with
`gpt-6-astra`, while preserving the Claude/Fable path and all worker and
operations assignments.

## Scope

- Update the machine-readable planner policy and Codex planner routing.
- Update focused runtime tests to assert the new identity.
- Update active documentation that describes the Codex planner model.
- Historical design records are not rewritten.

## Behavior

`RoleRouter.planner_assignment("codex")` returns the strategic planner role
with identity `gpt-6-astra`. The planner policy accepts `gpt-6-astra` and
`fable`; `fable` remains the Claude planner. Worker routing remains
provider-specific (`opus` for Claude and `luna` for Codex).

## Decisions

- **No back-compat alias.** `RoleRouter.named_role("sol")` raises `ValueError`,
  pinned by a test. An alias would let a stale `sol` entry re-enter the policy
  surface unnoticed, so the rename is deliberately a hard break.
- **Persisted-state residual.** `GoalStore.load` applies no identity allow-list
  by design, so GoalRun state files written before this change keep the stale
  `sol` label until the next provider switch rewrites it. The value is
  display-only and is never fed back into routing.
- **`gpt-5.6-sol` is unchanged.** The occurrence in
  `skills/codex-review/SKILL.md` names the OpenAI GPT-5.6 model tier used by
  the review gate — a different referent from the GoalRun planner identity —
  and is deliberately left alone.
- **Historical design record unchanged.** The 2026-08-29 mutation and
  presentation design record still describes the Codex planner as Sol; dated
  design records document the state at the time they were written and are not
  rewritten.

## Verification

Tests were updated first and observed failing, then the four runtime edits were
applied. The change is verified by the focused runtime tests, the full
`python3 scripts/test_goal_loop_runtime.py` suite, and `./scripts/verify.sh`.

## Related

Jira: TASK-837
