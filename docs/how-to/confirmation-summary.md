# Confirmation Summary

The summary shown before any work begins, cascade logic, and how to edit fields.

---

## When to Read This

- You want to understand what the confirmation summary shows
- You want to know how editing one field affects others
- You want to understand why the board-driven summary doesn't show a branch

---

## What Is the Confirmation Summary?

Before any work begins, every command shows a metadata summary. Nothing starts without your explicit confirmation. This is mandatory and cannot be skipped.

**The summary is metadata only** — which ticket, which workflow, which board. The agent does NOT assume what the ticket needs at this stage. Ticket comprehension and scope decisions happen at Step 2 (Assessment) of /flow.

---

## Board-driven summary (12 fields)

When the agent picks an existing ticket from the Jira board, the **feature branch name** is NOT proposed at this stage. The agent hasn't assessed whether code changes are needed — proposing a feature branch name at this stage would presume code is required, but many tickets don't need code (design, docs, verification-only, requirements). The **target branch** (i.e. which branch the PR will eventually merge INTO, default `main`) IS shown as field [11] — that's a different field, set early because the user may have a branch constraint ("only net8", "target portal2") that needs to be captured regardless of whether code will be written.

```
-----------------------------------------
  Work Summary — please confirm
-----------------------------------------
  [1]  Ticket:    DEV-5647
  [2]  Title:     Bulk Invite — show toast for
                  request response
  [3]  Type:      Feature
  [4]  Priority:  Medium
  [5]  Workflow:  /flow
  [6]  Beads:     New issue will be created
  [7]  Skipping:  Nothing — full workflow
  [8]  Integrations: Jira (acli), Beads
  [9]  Board:     DEV board 309
  [10] Columns:   Discovery → Ready for Dev →
                  In Progress → Testing → Done
                  (read from actual board)
  [11] Target branch: main
  [12] Mutation testing: Yes — auto-detect tool at verification (recommended)

  [ENTER] Confirm and start
  [E]     Edit field(s) — type number(s)
  [Q]     Quit
-----------------------------------------
```

---

## Agent-first / hybrid summary (14 fields)

When the ticket comes from a work-breakdown (explicit coding task), the branch IS shown because the scope is known — these tasks were created as implementation work.

```
-----------------------------------------
  Work Summary — please confirm
-----------------------------------------
  [1]  Ticket:    DEV-5647 (just created)
  [2]  Title:     Invite endpoint — request models
  [3]  Type:      Sub-task (1 of 7)
  [4]  Priority:  Medium
  [5]  Workflow:  /flow
  [6]  Branch:    feature/DEV-5647-invite-request-models
                  (PROPOSAL — created at Step 7)
  [7]  Beads:     Linked to existing bead
  [8]  Skipping:  Nothing — full workflow
  [9]  Integrations: Jira (acli), Beads
  [10] Board:     DEV board 309
  [11] Columns:   Discovery → Ready for Dev →
                  In Progress → Testing → Done
                  (read from actual board)
  [12] Target branch: main
  [13] Breakdown: 3 stories, 7 tasks (from work-breakdown)
  [14] Mutation testing: Yes — auto-detect tool at verification (recommended)
-----------------------------------------
```

---

## Editing Fields

Type number(s) to change one or more fields at the same time. For example:
- `3` — change Type
- `3 5` — change Type and Workflow simultaneously

After editing, the summary refreshes with `<- changed` markers on every affected field (including fields changed by cascade logic).

---

## Cascade Logic

When you change one field, the agent automatically updates all dependent fields. Every cascaded change is visible:

| If you change | Agent automatically updates |
|---|---|
| [1] Ticket | Title, Type, Priority, Workflow, Skip list, Integrations |
| [2] Title | (Agent-first only) Branch name (slug generated from new title) |
| [3] Type | Workflow, Skip list, Priority suggestion |
| [4] Priority | Nothing — priority is independent |
| [5] Workflow | Skip list |
| [6] Branch (agent-first only) | Nothing — manual rename only |
| Beads | Nothing — independent toggle |
| Skip list | Nothing — manual override only |
| Integrations | Nothing — independent selection |
| Board | Ticket list refreshes to show tickets from the selected board |

---

## What Never Gets Skipped

Regardless of how you enter a workflow (via `/start` or direct command):

- `/init` — if the project is not configured
- Confirmation summary — always shown
- Step 2 Assessment of /flow — agent presents what it understands from the ticket
- Quality gates — TDD, code review
- Security checks — based on project security level
- PR creation — where the workflow includes it

---

## Notes

- The confirmation summary is the last chance to change ticket selection or workflow before work begins
- After confirmation, the workflow runs to Step 2 where the agent presents ticket comprehension
- Ticket understanding is NOT shown in the confirmation summary — that's what Step 2 is for
- For board-driven tickets, the branch is never proposed at the summary stage — it's determined at Step 2 based on whether code is needed
