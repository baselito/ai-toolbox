---
name: edge-cases
source: this repo
scope: always active
---

# Edge Case Handling

Standard responses for when something goes wrong or input is missing — the agent never fails silently or leaves the user stuck. The six General Rules below always apply; the detailed per-scenario response tables are lazy-loaded in the **`edge-cases` skill**.

## General Rules (always apply)

1. **Never fail silently.** Always tell the user what went wrong and offer options. Telling is not
   asking — surface it in the State block and keep moving.
2. **Never block on optional services.** Jira, Seq, Beads are all optional. Work continues without them.
3. **Pick the best recovery and take it**, stating the choice and the rejected alternative in one
   line. Present alternatives instead of acting only when every recovery path is itself a category
   ask (`rules/autonomy.md`).
4. **Respect user decisions.** If they reject a fix or proposal, document it and move on.
5. **Save progress before risky operations.** Commit work before rebasing, merging, or discarding.
6. **Confirm before destructive actions.** Discarding work, reverting, force pushing — always ask first.

## Specific playbooks → load the `edge-cases` skill

The exact wording and options per scenario live in the **`edge-cases` skill**. **Load it when you hit one of these** and need the standard handling:

- An external service is down (Jira/acli, Seq, GitHub `gh`, Beads), or acli auth fails
- A query returns nothing (empty Jira board, no Seq logs, no test failures, no review issues, no matching tickets)
- The user rejects something (confirmation, work breakdown, design, plan, a fix, security fix, PR creation)
- Invalid input (bad ticket ID, bad branch name, vague task, wrong project/board, missing file path)
- A mid-workflow failure (tests fail, build fails, context pressure, push rejected, Jira move fails, review grade low, reality-checker blocks, regression)
- Session resume / handover issues (empty/corrupted handover, stale handover files, diverged codebase, discard request)
- Bug-specific, incident-specific, Scrum-board (Step 0), or kanban column-transition edge cases
- A `/start` or project-setup snag (ran `/start` in the wrong directory or inside the toolbox repo, `PROJECT.md` incomplete, the ticket is already In Progress/Done, multiple Jira boards configured, or team capacity not set)

Applying the General Rules above is mandatory regardless; the skill carries the exact response per scenario.

## Applies To

All commands and workflows. The General Rules are always in effect; the `edge-cases` skill is loaded on demand when a specific scenario arises.
