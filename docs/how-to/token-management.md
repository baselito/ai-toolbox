# Token Management — Claude/Codex Provider Fallback

The toolbox treats Claude and Codex as peer providers for durable GoalRuns.
The active provider runs first; an explicit usage-limit or unavailable result
allows the other configured provider to continue the same run.

## What persists

Provider switches preserve GoalRun state, leases, verification evidence, Jira
action identities, provider history, and the append-only action journal. An
unknown result remains pending until reconciled, so work is not blindly retried
after it may already have happened.

| Provider | Role | Setup |
|---|---|---|
| Claude Code | Native host features plus full GoalRun execution | Install the Claude Code CLI and authenticate with the team account |
| Codex | Shared GoalRun execution through the configured wrapper and skills | Authenticate Codex and configure `GOAL_LOOP_CODEX_COMMAND` |

The same 25 specialist agents remain available through the Claude/ECC install
stack; provider switching changes the execution host, not the toolbox's role
model or verification contract.

## Switching providers

Normally, start with the single goal entry point in the active tool. If the
provider reaches its usage limit, resume the same GoalRun with the other
provider; do not copy the prompt into a new ad-hoc session. The worker reports
the provider change in the status checkpoint and continues from the next
verified action.

Claude slash commands and CronCreate remain Claude host features. The managed
guardrails are installed for both hosts: Claude uses `~/.claude/settings.json`,
while Codex uses `~/.codex/hooks.json`; both receive the same hook scripts,
skills, bounded runtime, and provider-neutral PR registrar. Codex uses its
desktop heartbeat for PR polling instead of CronCreate, and the GoalRun runtime
maps the same planner/worker roles through the configured Codex wrapper.

## Handover and recovery

The orchestrator writes `.claude/handover.md` at phase boundaries. The durable
GoalRun state is authoritative for resumable work; the handover is the concise
human-readable context. Use `/continue` or the GoalRun resume operation after a
session break. If a provider fails after an external action may have happened,
reconcile the action journal before retrying.

## Usage monitoring

- Check the provider's own subscription or team usage dashboard.
- Keep the GoalRun checkpoint short: current phase, last verified result, next
  action, and blocker if any.
- After a toolbox merge, refresh the installed toolbox before starting the next
  task so the provider adapters and runtime are current.

## Common failure handling

- **Explicit usage limit:** switch providers if configured and continue.
- **Provider unavailable:** switch only when the result is known; otherwise
  reconcile first.
- **Both providers unavailable:** preserve the checkpoint and report the exact
  resume action; do not claim progress that has not been verified.
- **Native host feature unavailable:** use the shared runtime equivalent or
  record the limitation; never silently fall back to an untracked workflow.
