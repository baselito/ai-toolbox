---
name: docs-before-commit
source: Custom
scope: always active — applies to every commit in every project
---

# Documentation Must Reflect Changes

Before every commit and push, verify that documentation is up to date with the changes being committed. This is a pre-commit checklist, not an afterthought.

## Pre-Commit Documentation Checklist

Before running `git commit`, check each item. **README.md is a priority** — it's the first thing people read. If a feature, workflow, guardrail, integration, or count changed, the README likely needs updating too.

1. **README.md** — Do any tables, feature lists, setup instructions, workflow descriptions, guardrails, or repo structure descriptions need updating? **Always check this — not just internal docs.**
2. **CLAUDE.md** — Do any counts, component names, install steps, or architecture descriptions need updating?
3. **Command files** (`commands/`)  — If behaviour changed, does the command file reflect it?
4. **Rule files** (`rules/`) — If a rule was added, changed, or removed, do other rules that reference it need updating?
5. **Doc files** (`docs/`) — Do any concept pages, how-to guides, or reference lists need updating?
6. **Provider parity** — If shared behavior changed, do both the Claude host surface and the Codex runtime/installer surface still describe and expose it correctly?
7. **Counts** — If files were added or removed, do all files mentioning counts (CLAUDE.md, README.md, plugin.json, docs/) reflect the new numbers?
8. **Examples** (`examples/`) — Do example files still match reality?

## When to Apply

- **Every commit that changes behaviour** — not cosmetic fixes or typos
- **Especially after**: adding/removing files, changing command flows, updating integrations, modifying rules, changing agent orchestration

## Automatic Verification (agent decides — no user prompt needed)

The agent MUST run documentation verification automatically after every behavioural change. This is not a suggestion — it's a mandatory step the agent performs on its own without waiting to be asked.

**Verification steps (run these, don't just think about them):**

1. `grep -rn "old-name-or-count" --include="*.md" --include="*.json"` after any rename, flag change, or count change
2. For every changed file, grep for its name, its key functions/flags/patterns across all `.md` files to find references that need updating
3. When changing CLI commands or flags: run `<tool> --help` to verify the exact syntax before writing it into documentation. Never document a flag from memory — always verify first.
4. Read the diff: for every changed file, ask "does any documentation describe this?"

**The agent decides autonomously** whether docs need updating based on the verification results. If they do, update them in the same commit. If they don't, note it in the commit message. Do not ask the user "should I update docs?" — just do it.

## Commit Message Requirement

Every commit message MUST end with a documentation status line:

- **If docs were updated:** `Docs: updated [list files changed]`
- **If no docs needed updating:** `Docs: verified — no updates needed`

**⛔ DO NOT claim docs are updated without verifying. ⛔** Before writing "Docs: updated", re-read the files you changed to confirm the edits are actually there. Before writing "Docs: verified — no updates needed", actually run the checklist above — do not assume. A false "verified" claim is worse than no claim at all.

## What NOT to Do

- Do not create new documentation files unless explicitly asked
- Do not add docstrings or comments to code you didn't change
- Do not update documentation speculatively — only update what the current change affects
