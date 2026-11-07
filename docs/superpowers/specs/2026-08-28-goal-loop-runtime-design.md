# Goal-loop runtime wiring

## Problem

The toolbox documents three loop guards, but two are caller obligations rather
than runtime behavior: no launcher reads the project `loop:` block to apply the
native Claude turn/spend limits, and the automated `/review-pr --auto` path does
not record repeated failures with `loop-progress-signature.sh`. Separately, the
merge safety hook depends on `gh` being discoverable in the hook subprocess and
can therefore block a valid, user-commanded merge when the interactive shell
has a different PATH. Installed hook copies can also drift from the repository
source without being reported.

## Design

1. Add a single, fail-closed `loop-launch.sh` entry point. It reads only the
   numeric `loop:` values from `.claude/PROJECT.md`, applies the toolbox
   tighten-only ceilings, and launches the native Claude CLI with
   `CLAUDE_CODE_MAX_TURNS`, `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`, and
   `--max-budget-usd`. It never evaluates project text as shell code and does
   not accept a project-provided command.
2. Add a deterministic auto-poll progress checkpoint around the existing
   `/review-pr --auto` gate. The checkpoint uses the same failing-gate signature
   as all other loops and stops/escalates after the configured threshold; it
   resets only when the PR gate converges or its failure changes.
3. Make the merge hook resolve `gh` through a small trusted fixed-location
   candidate list (including standard Homebrew/Linux and user-local locations),
   retaining fail-closed behavior when no executable can be found. Add a
   verification check that reports installed hook drift so source changes
   cannot silently leave the active safety gate stale.
4. Keep the existing safety boundaries: no autonomous merge/close, no force
   push, no auth/credential/production actions, no commands from `PROJECT.md`,
   and no retry on quota/auth failures. A loop may edit code, run gates, fix
   review findings, and push an authorized feature branch only.

## Verification

- New launcher tests cover defaults, tighten-only clamps, malformed config,
  argument forwarding, and missing CLI behavior without invoking a real agent.
- Hook tests cover `gh` resolution with restricted PATH and fail-closed absence.
- Existing progress-signature, hook, and full `scripts/verify.sh` suites remain
  required before a PR is opened.
