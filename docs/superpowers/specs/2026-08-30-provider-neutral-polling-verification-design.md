# Provider-Neutral Polling Verification Design

## Goal

Keep the provider-neutral PR poll registrar regression suite attached to the
toolbox health gate so Claude and Codex marker behavior cannot silently drift
out of verification.

## Scope

The existing `scripts/test-register-pr-poll.sh` fixture exercises both provider
values, the shared state-root override, missing and bound pending markers,
worktree ownership, and invalid input rejection. This change adds only the
missing synchronization contract: `scripts/verify.sh` must execute that suite
with the other loop-runtime tests.

No production polling behavior, provider routing, or installer behavior changes
are required.

## Approach

1. Extend the registrar suite with a static assertion that the verifier invokes
   it.
2. Run the suite before changing `verify.sh` and record the expected failure.
3. Add the registrar filename to the existing bounded loop-test list in
   `verify.sh`.
4. Run the suite again, then run the full verifier and targeted provider/state
   fixtures.

## Failure and Recovery Coverage

- Invalid repository and poll identifiers fail closed.
- A missing marker is recreated by registration.
- A pending marker for another PR is preserved.
- A legacy marker is not consumed without proof of worktree ownership.
- Claude and Codex write the same marker format under the shared state root.
- The verifier remains bounded by its existing process-group timeout path.

## Acceptance Criteria

- The registrar suite fails when its verifier wiring is removed.
- The registrar suite passes after the wiring is restored.
- The full verifier executes the registrar suite and exits 0.
- The diff is limited to the test synchronization assertion, verifier wiring,
  and this design record.
