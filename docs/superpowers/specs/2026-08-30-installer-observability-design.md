# Installer and Verifier Observability Design

## Goal

Make the two repository-level issues found during the TASK-831 toolbox run
explicit and testable: installer help must be safe to query, and long bounded
verification must report that it is still active while clock-based fixtures
run.

## Scope

- Add `--help` and `-h` handling to `scripts/install.sh` before any filesystem,
  package-manager, or provider setup work.
- Reject unknown installer arguments with usage on stderr and a non-zero exit.
- Add a bounded-run progress message to `scripts/verify.sh` on stderr at a
  configurable interval, with a meaningful phase label at each call site.
- Add shell regression tests and wire them into the repository health gate.
- Synchronize count-bearing documentation for the new design and test files.

## Approach

1. Add failing fixtures for installer help and bounded-run progress.
2. Add early installer argument parsing and a read-only usage function.
3. Add opt-in progress reporting to the existing bounded process-group runner;
   preserve captured child output and timeout/error semantics.
4. Run targeted tests, then the full bounded verifier and installed-surface
   checks.

## Safety and Failure Handling

- Help exits before the installer can clean directories, write memory, alter
  MCP configuration, or run verification.
- Progress is informational stderr output only; it cannot make a run appear
  complete and does not alter the deadline or process-group cleanup.
- The progress interval is validated and can be shortened in tests without
  making production verification noisy.

## Acceptance Criteria

- `bash scripts/install.sh --help` and `-h` exit 0, print usage, and leave a
  temporary HOME unchanged.
- An unknown installer argument exits non-zero without side effects.
- A deliberately long bounded command emits progress before its deadline.
- Existing timeout, failure, and success results remain unchanged.
- `scripts/verify.sh` runs both new regression suites and exits 0.
