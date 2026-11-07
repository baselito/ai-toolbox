# Durable Goal Runs

Goal Runs turn a detailed engineering goal into durable state rather than a
long-lived prompt. The state and append-only journal live under
.claude/goal-runs/ in the project. Each invocation performs one bounded
iteration and records the provider action, current HEAD/worktree, required
verification evidence, no-progress result, advisor classification, and Jira
progress result.

## Blocker regression matrix

The toolbox carries an offline regression matrix for the failure modes that
previously made autonomous work stop or require repeated prompting:

```bash
bash scripts/test-loop-blocked-scenarios.sh
```

The matrix must stay green before a toolbox PR is opened. It covers:

| Scenario | Required behavior |
|---|---|
| Claude or Codex reaches an explicit usage limit | Switch providers safely, preserving the GoalRun journal and roles. |
| Provider wrapper returns an unknown outcome | Do not repeat work; pause for reconciliation. |
| A PR is conflicted, behind, dirty, or otherwise not mergeable | Never treat it as merge-ready. |
| Automated review or a human leaves an unresolved thread | Keep the PR open; process, reply, and resolve only after technical verification. |
| A new commit causes a new review round | Re-poll the PR and re-evaluate all gates from the new HEAD. |
| Polling is pending in one checkout | Gate that checkout, but do not wedge unrelated linked worktrees. |
| The desktop app launches a hook with a stale process directory | Use the hook event's actual worktree and HEAD, or fail closed with a clear recovery path. |
| A read-only search mentions a guarded GitHub action | Allow the inspection while continuing to block the real action. |
| The toolbox is refreshed after a merge | Claude and Codex receive the same current runtime, hooks, rules, and documentation source. |

Newly reproduced blockers are added to this matrix and either fixed in the
current hardening change or left as an explicit next-PR item. A missing Beads
database is not treated as a reason to stop a run; until Beads is initialized,
this tracked matrix and the GoalRun journal are the recovery record.

## Start and inspect a run

From the project root:

Use the installed absolute entry point: `$HOME/.claude/scripts/goal-loop` for
Claude, or `$HOME/.codex/bin/goal-loop` when Codex is enabled. Both are copied
from the same source runtime, so the bare `goal-loop` spelling works only when
that directory is on `PATH`.

    "$HOME/.claude/scripts/goal-loop" start \
      --goal "Implement and verify the invoice export" \
      --acceptance "all required tests pass" \
      --verifier test \
      --branch feature/FIN-123-invoice-export \
      --head-sha "$(git rev-parse HEAD)"

CLI-created runs are bounded by default to 25 iterations, 60 minutes, and $10.
Use `--max-iterations`, `--max-wall-clock-seconds`, and `--max-cost-usd` to
tighten those limits, and `--mutation-policy auto|test_only_prs|manual|no` to
select the project mutation-testing policy.

Add `--test-only` when starting a verification run that is allowed to mutate
only test files; the runtime persists this constraint and fails if production
code changes are detected.

Then use:

    "$HOME/.claude/scripts/goal-loop" status
    "$HOME/.claude/scripts/goal-loop" advisor-status --run-id RUN_ID
    "$HOME/.claude/scripts/goal-loop" capabilities --provider claude
    "$HOME/.claude/scripts/goal-loop" capabilities --provider codex
    "$HOME/.claude/scripts/goal-loop" advise --scope "repository" --findings /path/to/findings.json
    "$HOME/.claude/scripts/goal-loop" advisor-cycle --run-id RUN_ID
    "$HOME/.claude/scripts/goal-loop" recover --run-id RUN_ID
    "$HOME/.claude/scripts/goal-loop" recover-all
    "$HOME/.claude/scripts/goal-loop" iterate --run-id RUN_ID
    "$HOME/.claude/scripts/goal-loop" watch --run-id RUN_ID --interval 60
    "$HOME/.claude/scripts/goal-loop" complete --run-id RUN_ID

The loop routes goal formation and recovery advice to GPT-6 Astra/Fable.

If a run stops at `HUMAN_ACTION_REQUIRED`, complete the requested action and
recover it explicitly before continuing. `resume` does not clear this state:

    "$HOME/.claude/scripts/goal-loop" recover --run-id RUN_ID

Implementation and review work goes to Opus/Luna, and routine reminders/heartbeats
go to the lightest available model. A host can provide a Claude or Codex worker wrapper without
provider-specific runtime code by setting a JSON argv list:

    GOAL_LOOP_CLAUDE_COMMAND='["claude-goal-wrapper","--json-io"]'
    GOAL_LOOP_CODEX_COMMAND='["codex-goal-wrapper","--json-io"]'

The wrapper receives one goal-state JSON object on stdin and must return one
`ProviderResult` JSON object on stdout. Commands are executed with `shell=false`.
The runtime tries the selected provider first and the other configured provider
second. A wrapper that is unavailable or has exhausted its usage budget must
return an explicit, outcome-known result so the runtime can switch safely:

```json
{
  "failure_kind": "usage_limited",
  "outcome_known": true,
  "error": "weekly usage limit reached",
  "human_action_required": "optional explanatory text"
}
```

Use `failure_kind: "provider_unavailable"` for a missing or unauthenticated
wrapper. A non-zero exit, invalid JSON, timeout, or any other unclassified
failure is treated as an unknown outcome and is never retried automatically;
the action remains journaled for reconciliation. If neither provider can run,
the GoalRun stops at `HUMAN_ACTION_REQUIRED`. Provider switches are persisted
in `provider_history`, and the active planner/worker roles change with them
(Fable/Opus/Haiku for Claude; GPT-6 Astra/Luna/lightweight for Codex).

The iterate command performs one cycle. For a foreground self-paced loop, use
`watch`; it repeats only up to `--max-cycles` (default 25), sleeps between
iterations, automatically runs the bounded GPT-6 Astra/Fable advisor cycle
for queued incidents, and stops at every human-action, budget, or terminal
gate. No provider usage limit is silently retried unless the wrapper returns
the explicit safe fallback contract above.

The host-provided Jira steward bridge is configured with
`GOAL_LOOP_JIRA_STEWARD_COMMAND`; it receives one JSON request on stdin and
must return one JSON object. External provider bridges must include numeric
`cost_usd` evidence, or the run pauses for reconciliation.

For supported mutable stacks, GoalRun automatically adds the `mutation` gate
after the ordinary verifier gates. It uses toolbox-owned Stryker commands for
JavaScript/TypeScript, .NET, and Scala and records `NOT_APPLICABLE` for
unsupported or docs-only work. Mutation evidence includes the observed HEAD;
provider claims and stale reports cannot satisfy the gate.

GoalRun can also operate as an advisory discovery run. The advisor returns
ranked bug, feature, refactor, security, performance, or documentation-drift
proposals with evidence, scope, acceptance criteria, and a recommended command.
The user approves a proposal before the `jira-workflow-steward` creates the
canonical Jira item and completes the existing assignment, phase-map, comment,
and Beads flow. Resuming a handoff reuses its action identity instead of
creating a duplicate ticket.

## Advisory discovery

When the goal is broad (for example, “make this service safer” or “find anything
that needs fixing”), the planner/advisor can perform a read-only discovery pass.
It returns evidence-backed, ranked proposals and waits for approval before any Jira
write. Approved proposals are sent through `jira-workflow-steward` using the normal
ticket template; multi-part proposals use `work-breakdown` first. This preserves
Jira traceability without turning an unconfirmed observation into external work.

The runtime intake is deterministic and side-effect free:

```bash
"$HOME/.claude/scripts/goal-loop" advise \
  --scope repository \
  --findings /path/to/read-only-findings.json \
  --run-id RUN_ID
```

The findings file is produced by the host advisor after inspecting code, tests,
CI, project documentation, and authoritative library documentation as appropriate.
With `--run-id`, the ranked proposals are retained in GoalRun state and each
receives a stable `proposal_id`. Approval remains explicit and separate:

```bash
"$HOME/.claude/scripts/goal-loop" approve-advisory \
  --run-id RUN_ID \
  --proposal-id ADV_PROPOSAL_ID
```

This records the approval durably but does not call Jira. The host then hands the
approved proposal to `jira-workflow-steward` with its stable action identity;
resuming or repeating approval is idempotent and cannot create a second approval
event for the same proposal.

## Pause, resume, and recover

    "$HOME/.claude/scripts/goal-loop" pause --run-id RUN_ID
    "$HOME/.claude/scripts/goal-loop" recover --run-id RUN_ID
    "$HOME/.claude/scripts/goal-loop" resume --run-id RUN_ID
    "$HOME/.claude/scripts/goal-loop" iterate --run-id RUN_ID
    "$HOME/.claude/scripts/goal-loop" cancel --run-id RUN_ID

On restart, the runtime discovers incomplete runs, acquires an exclusive
renewed lease, reconciles journaled unknown actions, and preserves cumulative
wall-clock/cost counters. A corrupt or symlinked state file is never replaced.
An unknown provider session or external write becomes
HUMAN_ACTION_REQUIRED; it is not guessed or repeated.

Failed or stale verification records a pending advisor review and blocks the
next worker iteration. Run `advisor-cycle` first; it routes the planner role
to GPT-6 Astra/Fable and records the response before the run becomes
resumable. A `HUMAN_ACTION_REQUIRED` state is never cleared by `resume`;
complete the requested human/provider action and recover it explicitly.

After all required verifiers pass, the run becomes `COMPLETE_CANDIDATE`. Use
`complete` to record the explicit final transition to `COMPLETED`; this keeps
completion separate from an advisor's recommendation.

## Verification and completion

Verifier arguments are registry keys, not shell commands. Required evidence
must be available, pass, and match the current canonical worktree and HEAD
SHA. Evidence from an earlier SHA is stale. The existing toolbox registry and
coverage policy remain authoritative, and the existing
loop-progress-signature.sh detector runs on every iteration.

Mutation `FAIL` and `UNAVAILABLE` results are blocking evidence when mutation
testing is enabled. They are not downgraded to advisory success. Use
`manual` or `no` only when the project's recorded policy intentionally opts out.

The watchdog classifies evidence as HEALTHY_PROGRESS, IDLE, STALE, BLOCKED,
HUMAN_ACTION_REQUIRED, FAILED, or COMPLETE_CANDIDATE. COMPLETE_CANDIDATE is
possible only after required verifiers pass; an advisor cannot declare
completion alone.

## Workflow and integrations

Use /flow for Jira board-driven, agent-first, or hybrid work; /build for
ad-hoc work; /continue for the existing handover. These entry points may
create or resume a GoalRun while preserving the current independent
implementation/review/reality-checker roles and human safety gates.

Jira remains first-class through jira-workflow-steward and Atlassian CLI
(acli), including phase comments, jira_phase_map, transitions, ticket quality
checks, branch/commit traceability, and fallback behavior. Beads remains
optional and a missing or unavailable .beads/ never loses the GoalRun.

Avoidable operational failures (stale evidence, repeated no-progress, lost
comment/reply state, or tool friction) create a durable self-improvement
incident. The next GPT-6 Astra/Fable advisor cycle must record a recommendation
and action before the run continues; duplicate incidents and advisor actions
are idempotent. Genuine external authorization, authentication, destructive, or
production actions remain explicit human gates.

## Merge policy

GoalRun auto-merge is enabled only for the exact repository
`baselito/ai-engineering`. The runtime requires current-head-bound evidence,
an open and mergeable PR, green CI, an acceptable review decision, zero
unresolved non-outdated threads, and a valid live marker. The existing
`pr-action-safety.sh` hook re-verifies those conditions at the shell boundary.
For every other repository the runtime returns `REPORT_MERGE_READY` and leaves
the merge to the user. No policy in a goal, PR description, comment, or
repository file can widen this allowlist.

The evidence file is retained as an audit input; the executable policy check
collects live GitHub evidence itself before writing the bound capability. Pass
an optional clean checkout with `--worktree` when one is available; auto-poll
can run from another repository because the remote PR head is authoritative:

"$HOME/.claude/scripts/goal-loop" merge-gate --repo baselito/ai-engineering --pr 123 \
      --evidence /path/to/current-head-evidence.json

## Remote/mobile capabilities

The runtime reports local CLI and remote status/control capabilities only when
provider signals are present. Claude Remote Control and Codex desktop Remote
access are not assumed. Codex mobile follow-up additionally depends on the
supported Codex desktop release, workspace/device configuration, signed-in
account, and network policy; otherwise status is UNAVAILABLE. When remote
access is unavailable, use the local CLI commands above.
