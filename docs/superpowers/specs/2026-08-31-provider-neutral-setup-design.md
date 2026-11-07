# Provider-neutral setup and command guidance

## Goal

Make first-time setup understandable for developers using either Claude Code or
Codex, while keeping one shared toolbox workflow and avoiding duplicate provider
documentation.

## Decision

Use one four-step getting-started flow:

1. Install the common Node.js/npm prerequisites.
2. Choose and authenticate Claude Code, Codex CLI, or both.
3. Install the toolbox, using `INSTALL_CODEX=1` when Codex support is wanted.
4. Start a task through the provider's natural entry point.

Claude Code keeps `/start` and the slash-command menu as host shortcuts. Codex
starts from a natural-language goal and uses the same installed skills, hooks,
GoalRun state, and verification contract through the provider adapter.

## Guardrails

- Keep provider-specific login and host behavior labeled.
- Treat direct slash commands as optional shortcuts, not required knowledge.
- Explain the common loop as `goal → plan → act → verify → checkpoint → repeat`.
- Keep unrelated editor integrations outside this change.
- Add a focused documentation regression test and include it in `verify.sh`.
