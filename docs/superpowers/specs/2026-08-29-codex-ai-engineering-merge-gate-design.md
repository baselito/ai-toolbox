# Codex GitHub merge-gate compatibility for ai-engineering

## Goal

Allow Codex to execute the existing guarded merge workflow for exactly
`baselito/ai-engineering`, while leaving Claude behavior and merge protection
unchanged for every other repository.

## Constraints and non-goals

- GitHub authentication remains the local authenticated `gh` session; Claude
  credentials are not used.
- The implementation must not use a browser, raw GraphQL mutation, hidden
  subprocess, or another path that evades the merge gate.
- The existing checks remain authoritative whenever the runtime can execute the
  verifier: the PR must be open, mergeable, CI-clean/unstable-without-failures,
  not `CHANGES_REQUESTED`, and have no unresolved non-outdated threads.
- No hook behavior changes for repositories other than
  `baselito/ai-engineering`.

## Design

The repository already contains the Codex-compatible hook logic. The defect was
installation drift: Claude had the current `pr-action-safety.sh`, while Codex
was running an older copy. `scripts/install.sh` will therefore synchronize the
canonical hook to `$CODEX_HOME/hooks/pr-action-safety.sh` whenever that existing
Codex hooks directory is present. The synchronization uses a securely-created
temporary file followed by an atomic rename, so a pre-existing destination
symlink is replaced rather than followed. It will not create or alter a Codex
setup that is not installed.

Claude and Codex will run the same hook implementation, including the same
normalized command checks, marker binding, flag allowlist, trusted `gh`
resolution, and live PR-state verification. The exact merge target remains
bound by the explicit repository and PR number in the guarded command. No
adapter response or local state snapshot is trusted in place of GitHub’s live
state.

This change only synchronizes the hook installation; it does not change merge
behavior for other repositories or weaken the global safety control.

## Testing

Add regression coverage for:

1. The installer recognizes an existing Codex hooks directory and synchronizes
   the canonical `pr-action-safety.sh` there.
2. A malicious destination symlink is replaced without modifying its target.
3. An absent Codex hooks directory is left untouched.
4. Claude behavior and the existing command/marker/flag protections remain
   unchanged.

Run the focused hook tests, the full hook verification suite, and the repository
verification suite before committing or opening a PR.

## Runtime prerequisite

Codex must be restarted after installation so it reloads the synchronized hook
copy. The hook continues to fail closed if `gh` cannot perform live
verification; authentication alone is not treated as proof that a merge is
safe.
