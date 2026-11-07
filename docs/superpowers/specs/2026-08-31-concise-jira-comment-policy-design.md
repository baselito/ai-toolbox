# Concise Jira Comment Policy

## Goal

Keep Jira useful as a ticket-level progress view without copying every internal workflow event into the comment stream.

## Design

Board-aware transitions and internal workflow phases remain unchanged. Jira comments become milestone-based:

1. One short start update when work begins.
2. One short milestone update when a PR or other reviewable deliverable is available.
3. One short completion update when the work is complete.
4. An additional short blocker update only when a human decision or visible ticket impact requires it. A separate resolution update is optional only when the ticket would otherwise appear blocked.

Phase summaries, detailed reasoning, test output, reviewer activity, polling, retries, provider changes, and installation work stay in the handover, PR, and tool logs. They are not routine Jira comments.

The Jira workflow steward remains the only writer for Jira operations. It owns status transitions through the live phase map and posts milestone comments when the orchestrator explicitly requests one. It does not infer a comment from every phase call.

## Verification

Add a deterministic policy test that checks the canonical flow instructions, global agent rules, steward guidance, and reference skill all describe milestone comments and no longer require eight phase comments. Keep the existing comment-ordering audit for compatibility with historical tickets, but do not use it as a requirement for new runs.
