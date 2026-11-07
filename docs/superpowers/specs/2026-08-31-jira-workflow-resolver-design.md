# Jira Workflow Resolver Design

## Status

Approved for implementation under TASK-833.

## Goal

Make Jira phase decisions deterministic across boards with different column names, status IDs, and workflow shapes, while keeping the implementation small and avoiding extra live API calls during normal phase handling.

## Design

Add a pure `jira-phase-resolver.sh` helper. It receives a JSON input document containing the universal phase, the current board column, the configured phase map, the live board columns, and optionally the currently available transition targets. It returns one JSON decision:

- `transition` with the mapped target column;
- `comment_only` when the phase is explicitly unmapped (`null`);
- `in_place` when the mapped target is already the current column; or
- `blocked` when the phase key is missing, the mapped column is stale, or the target is not an allowed transition.

The helper will compare column names case-insensitively but will never derive a column from a Jira status name, walk columns by ordinal position, or silently guess a replacement. The existing live board reader remains the source of status-ID-to-column data; the phase map remains the explicit semantic contract.

The workflow documentation and Jira steward instructions will call the resolver before a phase transition and explain that planning/brainstorming are comment-only phases. The resolver itself will remain network-free so fixture tests are deterministic; live board discovery and Jira transition permissions stay at the API/CLI boundary.

## Error handling

Invalid JSON, missing required fields, unknown phases, stale mappings, and disallowed targets return a structured `blocked` decision and a nonzero exit code. The caller must preserve the ticket’s current state and surface the reason.

## Verification

Fixture tests will cover the TBR board shape, a board without Discovery, a lumped Code Review/In Progress column, a simplified board, stale mappings, missing phases, disallowed transitions, and malformed input. Documentation synchronization checks will include the new helper and test in the installer/verifier surfaces.
