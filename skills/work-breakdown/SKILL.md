---
name: work-breakdown
type: active
source: this repo
description: Decomposes user descriptions or existing Jira epics into epic → story → task hierarchy. Creates beads first, syncs to Jira if configured.
used_in: /flow, /build
---

# Work Breakdown

A structured decomposition skill that breaks work into an epic → story → task hierarchy. Always creates beads first (local, works without Jira). Syncs to Jira as a second step when configured.

## When to Use

- **Agent-first mode:** The user describes what to build. The agent scopes it, proposes a breakdown, and creates everything.
- **Hybrid mode:** Epics and stories already exist in Jira. The agent reads them and proposes sub-tasks underneath.
- On demand from any command when the user asks the agent to break work down.

## When to Skip

- **Board-driven mode** — tickets already exist and are sized. No breakdown needed.
- Trivial single-task work where a breakdown adds no value.
- `/hotfix` and `/incident` — urgency means skipping planning.

## Process

### Phase 1 — Scope

Determine what needs to be built and where the boundaries are.

**Agent-first:** Read the user's description. Ask 3-5 scoping questions:
- What is the goal?
- Who uses it?
- What systems does it touch?
- Any constraints or deadlines?
- How big — single task or multi-story?

**Hybrid:** Read the existing Jira epic or story. Understand the acceptance criteria, linked tickets, and comments. Identify what sub-tasks are needed to complete it.

### Phase 2 — Decompose

Propose a hierarchy:

- **Epic** (one, if creating from scratch) — the high-level objective
- **Stories** (2-6 typically) — user-visible slices of functionality
- **Tasks** (1-4 per story) — developer-sized implementation units

Each task must have:
- A title
- Structured description content (not a one-liner) — `## Summary`, optional Problem/Background and Proposed Scope when they add value, and `## Acceptance Criteria`. The `jira-workflow-steward` (Haiku) formats this into the full Ticket Description Template at create time (see `agents/jira-workflow-steward.md` → "Ticket Description Template" and `rules/agents.md` → "Ticket Description Quality").
- Dependencies on other tasks (if any)

**Minimum content per task (enforced by jira-workflow-steward pre-create check):**
- `## Summary` — what this task delivers and why it matters (1–2 sentences)
- `## Acceptance Criteria` — at least one `- [ ]` verifiable, testable condition

**Hybrid constraint:** Never create epics or stories — only sub-tasks under what already exists. If a new story is needed, recommend it to the user but do not create it.

### Phase 3 — Present and Approve

Show the breakdown to the user. Nothing is created until the user explicitly approves.

**Agent-first display:**
```
-----------------------------------------
  Work Breakdown — please approve
-----------------------------------------
  Epic: Bulk tenant invite system

  Stories:
  1. Invite endpoint (API)
     1.1 Request/response models
     1.2 Validation + auth
     1.3 Unit tests
  2. Email notification
     2.1 Email template
     2.2 Queue integration
  3. Admin UI
     3.1 Invite form component
     3.2 Status tracking view

  Total: 7 tasks across 3 stories

  [ENTER] Approve — create beads + Jira tickets
  [E]     Edit — add/remove/rename tasks
  [R]     Re-scope — start over
  [Q]     Cancel
-----------------------------------------
```

**Hybrid display:**
```
-----------------------------------------
  Sub-Task Breakdown — please approve
-----------------------------------------
  Story: DEV-5644 — Add loading spinner

  Sub-tasks:
  1. Create spinner component
  2. Add to API call handlers
  3. Loading state management
  4. Unit tests

  Total: 4 tasks

  [ENTER] Approve — create beads + Jira sub-tasks
  [E]     Edit — add/remove/rename tasks
  [Q]     Cancel
-----------------------------------------
```

The user can:
- **Approve** — proceed to creation
- **Edit** — add, remove, rename, or reorder tasks
- **Re-scope** (agent-first only) — go back to Phase 1 with new direction
- **Cancel** — abort the breakdown entirely

### Phase 4 — Create

On approval:

**Step 1 — Create beads (always):**
- One bead per task
- Link beads to parent stories via dependency fields
- If an epic was created, link all story beads to the epic bead

**Step 2 — Sync to Jira (if configured):**

| Mode | What gets created in Jira |
|---|---|
| Agent-first (Jira + Beads) | Epic + stories + tasks — full hierarchy |
| Agent-first (Beads only) | Nothing — beads are the only tracking layer |
| Hybrid | Sub-tasks under existing stories only |

The `jira-workflow-steward` agent (Haiku) handles all Jira ticket creation:
- Applies the Ticket Description Template (see `agents/jira-workflow-steward.md` → "Ticket Description Template") — structured markdown with Summary, Background, Scope, and Acceptance Criteria, passed via `--description-file`
- Runs the pre-create self-check: stops if Summary or Acceptance Criteria is missing
- Links sub-tasks to parent stories
- Links stories to parent epic
- Sets priority based on task order

**Step 3 — Return task list:**
- Return the ordered list of tasks (with bead IDs and optional Jira keys) to the calling command
- The calling command uses this list to execute tasks in order via `/flow`

## Agents Involved

| Agent | Role |
|---|---|
| `project-manager-senior` (Opus) | Drives decomposition logic and effort estimates |
| `jira-workflow-steward` (Haiku) | Creates Jira tickets and links |
| `brainstorming` skill | Runs before work-breakdown in agent-first mode when scope is unclear |

## Rules

- Never create Jira tickets without user approval of the breakdown
- Always create beads first, Jira second
- Hybrid mode never creates epics or stories — only sub-tasks under existing ones
- Agent-first mode creates the full hierarchy (epic, stories, tasks)
- If Jira is not configured, beads-only is used silently (no error, no warning)
- Each task must be small enough to complete in a single `/flow` run
- Present the breakdown once — do not re-ask unless the user requests changes
