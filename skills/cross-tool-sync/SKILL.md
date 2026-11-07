---
name: cross-tool-sync
description: Keep the Claude Code and Codex toolbox surfaces synchronized without maintaining duplicate provider mirrors.
---

# Cross-tool synchronization

Use this skill whenever the toolbox itself changes. The shared source of truth
is the provider-neutral runtime and its documented contract. Claude commands,
hooks, cron, and native agent spawning are host integrations; Codex uses the
shared runtime through its supported wrapper and installed skills.

## Change checklist

- Identify the runtime behavior and every installer or launcher that exposes it.
- Update both provider entry points when the behavior is intended to be shared.
- Keep host-only capabilities explicitly labelled rather than inventing parity.
- Update menus, command references, examples, and count-bearing documents.
- Search for stale paths, dead links, and old provider names.
- Run the retired editor-assistant integration check, focused tests, and `scripts/verify.sh`.

## Scope rule

Do not create or restore a second instruction-file mirror for another coding
assistant. If a provider cannot invoke a native feature, route it through the
shared bounded runtime or state the limitation in the provider adapter.
