# /goal — Durable GoalRun control

Use the installed goal-loop CLI when a goal should survive session changes,
compaction, or a closed laptop. It runs one bounded worker iteration at a time,
records verifier evidence and advisor/watchdog state, and stops durably when a
human action is required.

## Commands

From the project root:

The installed Claude path is `$HOME/.claude/scripts/goal-loop`; when Codex is
enabled, the equivalent is `$HOME/.codex/bin/goal-loop`. If either directory is
on `PATH`, the shorter `goal-loop` spelling is also valid.

    "$HOME/.claude/scripts/goal-loop" start --goal "..." --acceptance "..." --verifier test \
      --branch feature/PROJ-123-goal --head-sha "$(git rev-parse HEAD)"

Every CLI-started run receives bounded defaults (25 iterations, 60 minutes, and
$10). Override them explicitly with `--max-iterations`,
`--max-wall-clock-seconds`, and `--max-cost-usd`; choose mutation behavior with
`--mutation-policy auto|test_only_prs|manual|no`.

Add `--test-only` to persist a test-only mutation-verification constraint; the
loop then fails if production code is included in the changed files.
    "$HOME/.claude/scripts/goal-loop" status
    "$HOME/.claude/scripts/goal-loop" status --run-id RUN_ID
    "$HOME/.claude/scripts/goal-loop" advisor-status --run-id RUN_ID
    "$HOME/.claude/scripts/goal-loop" capabilities --provider claude
    "$HOME/.claude/scripts/goal-loop" capabilities --provider codex
    "$HOME/.claude/scripts/goal-loop" advise --scope "repository" --findings /path/to/findings.json
    "$HOME/.claude/scripts/goal-loop" advise --scope "repository" --findings /path/to/findings.json --run-id RUN_ID
    "$HOME/.claude/scripts/goal-loop" approve-advisory --run-id RUN_ID --proposal-id ADV_PROPOSAL_ID
    "$HOME/.claude/scripts/goal-loop" advisor-cycle --run-id RUN_ID
    "$HOME/.claude/scripts/goal-loop" recover --run-id RUN_ID
    "$HOME/.claude/scripts/goal-loop" recover-all
    "$HOME/.claude/scripts/goal-loop" iterate --run-id RUN_ID
    "$HOME/.claude/scripts/goal-loop" watch --run-id RUN_ID --interval 60
    "$HOME/.claude/scripts/goal-loop" pause --run-id RUN_ID
    "$HOME/.claude/scripts/goal-loop" resume --run-id RUN_ID
    "$HOME/.claude/scripts/goal-loop" resume --run-id RUN_ID --resolve-human-action "access approved"
    "$HOME/.claude/scripts/goal-loop" cancel --run-id RUN_ID
    "$HOME/.claude/scripts/goal-loop" complete --run-id RUN_ID

iterate is exactly one worker/verify/advisor/checkpoint cycle. `watch` repeats
that bounded cycle with a persisted checkpoint between iterations and stops on
any human/advisor gate, terminal state, or cycle ceiling. It never creates
an unbounded loop. Claude and Codex share the same runtime state and fallback
chain: a provider may hand off only for an explicit, outcome-known
`provider_unavailable` or `usage_limited` result. A failed or stale verifier blocks the next worker call until
advisor-cycle records the bounded advisor response. recover reconciles unknown
external actions before resuming. `resume` makes a paused or advisor-stopped run
resumable; it refuses to clear `HUMAN_ACTION_REQUIRED` until the human/provider
action has been completed and explicitly acknowledged. Use /flow for Jira ticket workflows, /build for ad-hoc
work, and /continue for the existing handover workflow; all three may resume
an incomplete GoalRun instead of creating duplicate work.

When resolving a missing-cost gate, include `--cost-usd <amount>` with the
human-action acknowledgement so the consumed usage is recorded before resume.

`complete` is an explicit final transition from `COMPLETE_CANDIDATE` to
`COMPLETED`; the runtime never treats an advisor's recommendation alone as
completion.

Normal GoalRun verification automatically adds the mutation gate when the
toolbox detects a mutable supported stack. Stryker is used for JavaScript/
TypeScript, .NET, and Scala; unsupported or docs-only work records an explicit
not-applicable result. Mutation `FAIL` and `UNAVAILABLE` results block
completion when enabled; they are not silently treated as advisory success.

Advisory discovery can rank read-only findings into proposals.

GPT-6 Astra/Fable owns the recommendation; use `--run-id` to retain proposals
in the GoalRun, then approve an exact `proposal_id` before the existing
jira-workflow-steward creates and enriches the Jira work item, assigns it,
applies the phase map, posts comments, and links Beads. No Jira write happens
from an unapproved advisory result.

Jira progress goes through jira-workflow-steward and acli with the existing
delegation-token, jira_phase_map, phase comment, and transition policy. Beads
is optional. Auth, production, merge, force-push, and other high-risk actions
remain human-gated.

Remote status/control is reported only when the configured Claude Remote
Control or supported Codex desktop remote capability is detected. Codex
mobile access is not universal: it depends on supported desktop/workspace,
device, account, and network prerequisites. The local CLI is always the
fallback.

The host must configure `GOAL_LOOP_CLAUDE_COMMAND` and/or
`GOAL_LOOP_CODEX_COMMAND` as JSON argv wrappers. Expected provider limits must
be returned as JSON with `failure_kind` set to `usage_limited` or
`provider_unavailable` and `outcome_known: true`; arbitrary failures are
reconciled instead of retried.
