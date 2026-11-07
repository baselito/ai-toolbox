# Goal Loop Runtime Design

## Status and scope

This design describes the first production vertical slice for a durable,
goal-driven engineering loop in the AI Engineering toolbox. It covers
goal intake, durable state, one bounded worker iteration, verification,
watchdog/advisor assessment, Jira progress reporting, checkpointing, and
resume/recovery. It is intentionally provider-neutral and works with Claude
Code and Codex through adapters.

The runtime is a small Python 3 standard-library package exposed through a
local CLI. It is installed with the toolbox and stores state in the target
project's .claude/goal-runs/ directory, which is already project-local and
normally gitignored. It never replaces the existing Claude/Codex wrappers,
jira-workflow-steward, Atlassian CLI (acli), Beads, hooks, or verification
registry.

## Goals and non-goals

Goals:

* Preserve one detailed goal and acceptance criteria across sessions,
  compaction, provider changes, and process crashes.
* Make every external action recoverable and idempotent.
* Run one finite worker iteration at a time, with deterministic verification
  and a no-progress check on every iteration.
* Surface useful status without requiring the user to repeatedly ask, while
  stopping durably for blocked or human-gated work.
* Keep Jira first-class through the existing acli/steward path and keep Beads
  optional when .beads/ is absent or initialization fails.

Non-goals for this slice:

* Replacing acli with an MCP, implementing Jira API calls directly, or
  reimplementing phase-map transition policy.
* Autonomous merge, force-push, production, authentication, credential, or
  other actions already protected by hooks and human safety gates.
* Claiming universal Codex mobile access or implementing a cloud scheduler.
* Inventing provider credentials, bypassing provider permissions, or making a
  provider-specific execution protocol authoritative.
* Letting an advisor declare completion; required verifier evidence is the
  only completion authority.

## Components and boundaries

    goal CLI
      -> GoalStore (atomic state + append-only journal + lease)
      -> GoalLoop (one bounded iteration)
           -> ProviderAdapter (Claude/Codex wrapper contract)
           -> VerificationRunner (registry keys, HEAD-bound evidence)
           -> ProgressDetector (existing loop-progress-signature algorithm)
           -> Advisor (deterministic heartbeat first; lightweight evidence advisor second)
           -> JiraAdapter (steward/acli command contract, idempotent action records)
           -> optional BeadsAdapter (existing bd lifecycle, fallback-safe)
      -> checkpoint/resume decision

The runtime receives validated arguments and adapter implementations. It does
not execute arbitrary commands from PROJECT.md or goal text. Verification gate
keys resolve through the existing toolbox registry; provider adapters delegate
to the existing Claude/Codex wrappers and return a normalized session result.
The default Jira adapter invokes the established steward path, which is
responsible for delegation-token protection and jira_phase_map behavior.

## Versioned state schema

Each run is a JSON document with schema_version: 1. Unknown fields are
preserved on read/write where possible, and incompatible versions fail closed
with a human-needed state rather than being guessed or discarded.

Required fields:

    {
      "schema_version": 1,
      "run_id": "gr_20260829_...",
      "goal": "...",
      "acceptance_criteria": ["..."],
      "verifier_ids": ["test", "lint"],
      "repo": "/workspace/project",
      "worktree": "/workspace/project",
      "branch": "feature/PROJ-123-goal",
      "head_sha": "...",
      "current_phase": "implementation",
      "current_task": "...",
      "status": "RUNNING",
      "iteration_count": 0,
      "wall_clock_seconds": 0.0,
      "cost_usd": null,
      "last_action": null,
      "last_verification": null,
      "last_advisor_assessment": null,
      "pending_human_action": null,
      "next_action": "run worker iteration",
      "stop_reason": null,
      "provider": "claude",
      "provider_session_id": null,
      "jira": {"key": null, "phase": null, "action_ids": [], "last_result": null},
      "beads": {"enabled": false, "id": null, "last_result": null},
      "created_at": "...",
      "updated_at": "...",
      "checkpointed_at": null
    }

Statuses are RUNNING, PAUSED, RESUMABLE, HUMAN_ACTION_REQUIRED, BLOCKED,
FAILED, COMPLETE_CANDIDATE, COMPLETED, and CANCELLED. Legal transitions are centralized
and tested. COMPLETE_CANDIDATE requires a complete required verification set
and awaits the completion policy/checkpoint; the advisor may recommend it but
cannot create it without verifier evidence.

## Journal, atomicity, and recovery

Every action has a deterministic action_id derived from run ID, iteration,
action type, and stable payload. Before an external action the runtime appends
an INTENT record and fsyncs the journal. It then performs the action and
appends SUCCEEDED, FAILED, or UNKNOWN with sanitized result metadata. State
checkpoints use a temporary file in the same directory, flush + fsync, then
os.replace; the directory is fsynced where supported. State, journal, and
lease paths must be regular non-symlink files under the run directory.

On startup, recovery scans incomplete runs, acquires an exclusive lease, and
replays unknown intents. Before skipping a successful provider action, recovery
reconciles its journal payload into the checkpoint: iteration number, session
ID, changed flag, observed HEAD, and bounded result metadata are restored and a
`recovery.checkpoint_reconciled` event is written. If the journal lacks enough
information to reconstruct the provider result, recovery stops at
`HUMAN_ACTION_REQUIRED` rather than repeating work. Jira comments/transitions
use the recorded action ID and stable marker so recovery does not duplicate
them. Unknown provider sessions are queried via
the adapter; if they cannot be reconciled safely, the run becomes
HUMAN_ACTION_REQUIRED. A corrupt, symlinked, or schema-incompatible state file
is never overwritten and is escalated with its path and reason.

The lease has an owner, acquisition time, expiry, heartbeat, and monotonically
increasing fencing generation. A live lease blocks a second worker. Expired
leases are recoverable only after the prior owner is not renewing; renewal is
rejected once expiry has passed, and takeover increments the generation. Every
worker checks owner, token, generation, and expiry immediately before and after
provider, verification, Jira, and Beads actions. Lease-bound journal writes
hold the lease lock across the check and append, so a stale worker cannot write
an action result, mutate shared state, renew, release, or continue after
takeover. If the provider returned after fencing, the stale worker does not
write state; the still-pending intent is reconciled by the replacement worker
or escalated to a human.

External actions also carry their stable action id. The Jira steward is required
to treat that id as an idempotency key, and successful advisory creates are
checkpointed in GoalState, so a restart can reuse the recorded result while a
crash window is safely reconciled by the steward rather than creating a second
item. Toolbox merge capabilities carry the exact checked PR head and the live
hook passes it to GitHub's match-head-commit compare-and-swap; a moved head is
therefore rejected by GitHub instead of silently merging unverified changes.

The run directory and all of its descendants are also checked for symlinked
components before state, journal, or lease operations. A symlinked run path is
rejected rather than canonicalized into a different writable location.

## One iteration data flow

1. Load and validate state; acquire/renew the single-run lease.
2. Run deterministic heartbeat, budget, staleness, and pending-action checks.
3. Append worker intent, invoke the selected provider adapter for one bounded
   iteration, and persist the normalized result/session ID.
4. Read the resulting repository HEAD/worktree identity.
5. Resolve verifier IDs through the existing registry and run only approved
   literal registry entries with validated argument lists. Record per-gate
   status, output summary, exit code, duration, HEAD SHA, and worktree.
6. Invoke the existing loop-progress-signature algorithm on every iteration,
   recording its result; detector failure is evidence that the guard did not
   run and causes a bounded human-needed outcome.
7. Run the advisor only at an iteration boundary or after a deterministic
   heartbeat detects idle/stale/failed evidence. Persist one of
   HEALTHY_PROGRESS, IDLE, STALE, BLOCKED, HUMAN_ACTION_REQUIRED, FAILED, or
   COMPLETE_CANDIDATE with evidence.
8. Append an idempotent Jira progress intent through the steward path when a
   phase/iteration update is due; record action IDs/results and preserve
   fallback behavior if acli/Jira is unavailable.
9. Checkpoint state and journal, release the lease, and return a resume/stop
   decision. No single call runs an unbounded loop.

## Verification and evidence

The verification runner accepts gate keys, not shell commands. It resolves
keys through the existing registry and rejects unknown, unavailable, stale, or
failed required evidence. Evidence is bound to the current HEAD SHA, the
canonical real worktree path, and a SHA-256 fingerprint of tracked changes plus
standard untracked files. Evidence from another SHA, worktree, or dirty-state
fingerprint is stale even if its command passed. Gate output is structured and
bounded for state storage, with a path to a full log where appropriate.

The runner records PASS, FAIL, or UNAVAILABLE per required gate. All required
gates must be PASS at the same HEAD for completion candidacy. Coverage floors
and other existing registry policy remain authoritative. The runner does not
accept a verifier result asserted by the provider or advisor.

## Watchdog/advisor behavior

The deterministic watchdog runs first and is cheap: lease heartbeat, elapsed
time, budget totals, provider heartbeat, last-action age, verification age,
pending human action, and progress-detector result. It classifies clear cases
without a model call. A lightweight advisor is invoked only on iteration
boundaries or ambiguous/stale evidence and receives a compact evidence bundle,
never unrestricted repository authority.

The advisor emits a concise persisted assessment and a status notification
event. It may recommend the next action or escalation, but only the verifier
can supply completion evidence. IDLE and STALE stop repeated worker calls until
resumed or the next deterministic retry boundary; BLOCKED and
HUMAN_ACTION_REQUIRED persist the exact action needed. Repeated identical
failure evidence invokes the existing no-progress detector and stops at its
configured threshold.

## Jira and Beads

Jira remains a control plane, not a best-effort log. The adapter passes phase
keys and comments to jira-workflow-steward, preserving delegation-token
protection, board-driven/agent-first/hybrid modes, jira_phase_map, phase
comments, transitions, ticket quality checks, and Jira-key branch/commit
traceability. The runtime records Jira action IDs and stable markers in the
journal before calling out. A repeated action with the same marker is treated
as already applied when the steward/acli result confirms it; an uncertain
write is reconciled before retrying.

Beads is attempted only when enabled and initialized. Missing .beads/, failed
bd init, or unavailable bd records a fallback event and does not prevent a
Jira-backed or local run from continuing. Neither integration changes existing
human gates.

## Provider and remote capability layer

ProviderAdapter exposes start_iteration, resume_session, inspect_session, and
capabilities. Claude and Codex adapters call the repository's existing
wrappers, pass no invented credentials, and report permission/auth failures as
human-needed. A capability detector reports local CLI availability, desktop
remote availability, and Claude Remote Control only when its documented local
signals are present.

The status/control abstraction is provider-neutral: local_cli, remote_status,
remote_resume, and remote_pause are capabilities, not promises. The CLI always
remains available as fallback. Codex mobile access is not implied; availability
depends on the supported Codex desktop release, workspace/device
configuration, signed-in account, and network policy. The runtime documents
these prerequisites and reports UNAVAILABLE otherwise.

## Safety model

The runtime is bounded per iteration and carries cumulative wall-clock/cost
limits across every resume. It never broadens existing hook policy. Auth,
credentials, production, merge, force-push, and other high-risk actions enter
HUMAN_ACTION_REQUIRED with a durable reason. A pause/cancel is also journaled
and cannot be lost during restart. External comments/transitions are routine
only where the existing workflow already authorizes them.

## User-facing surface

Add a small goal-loop CLI with start, status, iterate, resume, pause, cancel,
advisor-status, and capabilities subcommands. Add/update the corresponding toolbox command
guidance so /flow, /build, and /continue can create or resume a GoalRun, and
/review-pr can report/watchdog its existing review loop without changing its
merge policy. Existing role assignments remain unchanged; the advisor is an
evidence assessor, not a replacement for chief-of-staff, implementer,
reviewer, or reality-checker.

## Test strategy

Tests are stdlib-only and run offline with fake adapters. Test-first slices
cover legal state transitions; atomic writes; corrupt/symlink rejection;
crash after Jira intent/action and idempotent recovery; stale/failed/idle
advisor decisions; progress-detector invocation; stale SHA rejection;
cumulative limits across resume; exclusive leases; human-action escalation;
Claude/Codex capability detection; and Jira/Beads fallback. Shell integration
tests retain coverage of existing hooks and the progress-signature script.

## Explicit follow-up work

The slice does not provide a hosted control plane, push notifications, a
provider protocol implementation beyond safe wrapper adapters, or autonomous
multi-iteration scheduling. Those can be added later behind the same journal,
lease, verifier, and capability contracts without changing the state schema
authority or Jira safety path.
