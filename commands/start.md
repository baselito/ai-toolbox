# /start — Daily Entry Point

<!-- ask-headers: Unknown -- every AskUserQuestion this file instructs uses this header unless the line names its own (rules/autonomy.md) -->


The only command developers need to remember. Guides the user to the right workflow, routes automatically based on Jira ticket type, and ensures the project is configured before any work begins.

---

> **Edge cases:** If something goes wrong (service unreachable, empty results, user rejects, mid-workflow failure), follow the always-loaded general rules in `rules/edge-cases.md` and load the `edge-cases` skill for the scenario playbooks. Never fail silently — always offer alternatives.

## Trigger

- Run manually: `/start`
- This is the recommended daily entry point for all developers

---

## Behaviour

### Step 1 — Check PROJECT.md

The agent checks for `.claude/PROJECT.md` in the current project directory.

- **If not found (first time on this project):** Show this message before anything else:

```
👋 First time on this project!

No PROJECT.md found — this project hasn't been configured yet.
The agent will auto-detect your stack and methodology, then ask
a few quick setup questions (Jira, CI/CD, tracking).

This only happens once. After setup, /start goes straight to the menu.

Starting /init...
```

Then run `/init` automatically. After /init completes, continue to Step 2.

- **If found:** Read PROJECT.md and continue to Step 1.3.

### Step 1.3 — Toolbox Drift Check

Before anything else, verify that the installed toolbox (`~/.claude/commands/`, `agents/`, `skills/`, `rules/`) matches the repo snapshot. When a new command, agent, skill, or rule is added to the ai-engineering repo on main, users are silently out of sync until they re-run `scripts/install.sh`. Past incident: `/review-pr` was added in PR #7 (merged) but never propagated to `~/.claude/commands/`, so when an auto-poll cron fired `/review-pr 11`, every fire produced "Unknown command: /review-pr" silently.

Find the toolbox path from `~/.claude/memory.md` (saved by `/init` Step 13.5 in PR #10). If memory.md is missing or the path is unset, skip the check silently — the toolbox may not be installed yet.

```bash
TOOLBOX=$(awk '/^## Toolbox Path$/{getline; print}' "$HOME/.claude/memory.md" 2>/dev/null)
TOOLBOX="${TOOLBOX/#\~/$HOME}"

if [ -z "$TOOLBOX" ] || [ ! -d "$TOOLBOX" ]; then
  # No toolbox path saved, or path is stale — skip drift check
  : # silent skip
else
  MISSING=()
  for dir in commands agents skills rules; do
    if [ -d "$TOOLBOX/$dir" ]; then
      # Diff file lists: files in repo but not in install = drift
      while IFS= read -r f; do
        [ -n "$f" ] && MISSING+=("$dir/$f")
      done < <(comm -23 <(ls "$TOOLBOX/$dir/" 2>/dev/null | sort) <(ls "$HOME/.claude/$dir/" 2>/dev/null | sort))
    fi
  done

  if [ ${#MISSING[@]} -gt 0 ]; then
    echo
    echo "⚠️  Toolbox drift detected — your install is missing ${#MISSING[@]} file(s) from the repo:"
    for f in "${MISSING[@]}"; do
      echo "   - $f"
    done
    echo
    echo "   Fix: cd \"$TOOLBOX\" && ./scripts/install.sh"
    echo "   (Silent drift caused past failures where auto-poll crons fired slash commands that weren't installed.)"
    echo
  fi
fi
```

**Do NOT auto-install.** Auto-syncing `~/.claude/` without consent is invasive (could clobber local customisations). Warning + one-line fix command is enough — the user decides when to re-run install.

**Fast.** Under 500ms for a typical install (20 commands, 25 agents total, 48 skills total, 15 rules). Four `ls` pairs piped through `comm`. No network, no MCPs.

**Clean sessions print nothing.** If install and repo match (the common case immediately after `./scripts/install.sh`), Step 1.3 is silent.

### Step 1.4 — PR Review Activity Surface

**Scope: PR-review context only.** This surface exists specifically for the `/review-pr` + `/loop` workflow where the agent polls a PR for new reviewer comments in a separate session and the user can't see the activity in real time. It is NOT a general "everything the agent did while you were away" report.

Do NOT surface: autonomous commits on feature branches, general git activity, test runs, or any work where the user is the active author. When the user is mid-fix or starting new work, there is nothing to show — this step stays silent.

Gather two PR-scoped signals:

```bash
# a) /review-pr audit entries in the last 24h — only fires if /review-pr actually ran
if [ -f "$HOME/.claude/pr-review-actions.log" ]; then
  awk -v cutoff="$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)" \
    '$1 >= "["cutoff"]"' "$HOME/.claude/pr-review-actions.log" | tail -n 20
fi

# b) Active scheduled cron jobs whose reason mentions /review-pr or PR polling
#    (CronList tool — filter to entries whose reason contains "review-pr", "PR #", or "pr-poll")
```

If either signal has content, print a compact PR-focused block:

```
🔔 PR review activity since your last session:
  - 3 /review-pr actions on PR #[N] ([dismissed/fixed/flagged counts])
  - 1 active PR-polling cron: next fires [time]

Run `/status` for full detail. Start work without reviewing if you prefer.
```

If both signals are empty: **print nothing**. This is the common case — no clutter when the user is starting new work or mid-fix.

This check is fast (under 2 seconds) and read-only. It does NOT block the Jira fetch in Step 1.5 — that still fires in parallel. It does NOT block the user from ignoring PR comments and starting a new workflow.

### Toolbox self-maintenance exception

**Detection:** `git remote get-url origin` resolves to `baselito/ai-engineering`. This identifies the toolbox by the same owner/repo the merge repo-split uses — runtime detection lives in `commands/review-pr.md` Step 5.5 (`$OWNER == baselito && $REPO_NAME == ai-engineering`); the behaviour it gates is described in `rules/git-workflow.md` "Merge After Review Complete" (**ai-engineering (toolbox)** vs **All other repos (project repos)**).

When the repo IS the ai-engineering toolbox, `/start` does **not** look up or require a Jira ticket. Skip Steps 1.5, 2 (Jira board/menu), 2.5 (ticket selection), and 4 (ticket routing). Instead, ask the user directly: "What do you want to work on?" and route straight into `/flow`'s full orchestration — ticketless. Full orchestration still runs (Discovery, chief-of-staff, Opus subagent, code review, verification, PR). No Jira ticket is created, no phase comments are posted, and the confirmation summary omits `[1] Ticket`, `[4] Priority`, `[8] Integrations: Jira`, and `[9–10] Board/Columns` fields (replace with `Jira: n/a — toolbox self-change`).

All project-repo behaviour below is unchanged.

### Step 1.5 — Start Jira Ticket Fetch in Background

**If Jira is configured in PROJECT.md**, fire the ticket fetch immediately as a **background Bash task** — do NOT wait for it to complete. The other setup steps (Seq check, handover) run while this loads.

```bash
Bash(acli jira workitem search --jql "project = {PROJECT_KEY} AND status != Done ORDER BY status ASC, priority DESC, rank ASC" --fields "key,summary,issuetype,priority,status,assignee" --paginate --json > /tmp/jira-tickets-{PROJECT_KEY}.json 2>&1, run_in_background=true)
```

The results are read from the temp file later in Step 2.5. By the time the agent reaches Step 2.5, the fetch has already completed (~5 seconds) while the agent was doing Steps 1.6-2.

### Step 1.6 — Optional log connection check

Only check a log integration when PROJECT.md explicitly configures one. Use the
active provider's MCP connection status and discover available tools. Never
assume a local container name, port, checkout path, or redaction guarantee.
If unavailable, report once and continue using local logs or sanitized exports.

### Step 1.7 — Package feed health check

For .NET projects, inspect the project's solution and NuGet.config to identify
actual package sources. Run `dotnet restore` on the discovered solution/project
from its directory. If authentication fails, identify the failing feed and refer
to that feed provider's authentication instructions. Use the user's configured
tenant and credential provider; never log out, change tenant, or invent package
names automatically. Skip this check for projects without .NET sources.

### Step 2 — Select Board and Show Menu

**Multiple boards:** If PROJECT.md specifies a `jira_board`, use it. If not set (or the user has access to multiple boards), ask which board to use before showing the menu. Save the selection to PROJECT.md so it persists. The confirmation summary field [10] allows changing the board later — this refreshes the ticket list from the selected board.

The menu adapts based on the `jira_workflow` setting from `/init` (Q3). The default action changes depending on the mode.

**⛔ Use AskUserQuestion for the menu — split into 2 steps, header `Unknown` ⛔**
AskUserQuestion supports max 4 options. The menu has 10. Split into two questions:

**Step 2a — Main category (AskUserQuestion #1):**

```
What do you want to work on?
```
Options:
1. "Pick up a ticket" — pick from board or by ID (default)
2. "Bug or incident" — something is broken
3. "Other workflow" — review, refactor, security, perf, feedback
4. "Create a presentation" — toolbox PowerPoint deck
5. (Other — free text)

**Step 2b — Sub-option based on category (AskUserQuestion #2):**

If "Pick up a ticket":
1. "Pick up next ticket" — highest priority unassigned
2. "Pick a specific ticket" — enter ID or browse board
3. (Other)

If "Bug or incident":
1. "Bug" → routes to /bug
2. "Urgent hotfix" → routes to /hotfix
3. "Production is down" → routes to /incident
4. (Other)

If "Other workflow":
1. "Review existing code" → /review
2. "Clean up / refactor" → /refactor
3. "Security scan" → /security
4. "Create a presentation" → /presentation
5. (Other — for /perf, /feedback — user types it)

**Board-driven menu (reference — for routing logic):**
```
Full option list (implemented via the 2-step AskUserQuestion above):

Pick up a ticket:
  → Pick up next Jira ticket (highest priority unassigned)
  → Pick a specific ticket (enter ID or browse board)

Bug or incident:
  → Bug — /bug (creates Jira ticket automatically)
  → Urgent hotfix — /hotfix (fast-tracks CI/CD)
  → Production down — /incident (queries Seq immediately)

Other workflows:
  → Review existing code — /review (read-only, no PR)
  → Clean up / refactor — /refactor (no new features)
  → Security scan — /security (full OWASP report)
  → Performance investigation — /perf (not broken, just slow)
  → Find bugs or improvements — /ask (advisory discovery; approval before Jira)
  → Report feedback — /feedback (toolbox issues)
  → Create a presentation — /presentation (toolbox PowerPoint)
```

**Agent-first menu:**
```
What do you want to work on?

-> [ENTER] Describe what to build
   (the agent asks scoping questions, proposes a work
    breakdown, and creates Jira tickets if configured)

Or select:
 0) Pick up an existing Jira ticket
 1) Bug — something is broken
    -> Routes to /bug
 2) Something is broken and needs fixing urgently today
    -> Routes to /hotfix
 3) Production is down right now
    -> Routes to /incident
 4) Review existing code
    -> Routes to /review
 5) Clean up / modernise existing code
    -> Routes to /refactor
 6) Security scan
    -> Routes to /security
  7) Something is slow — performance investigation
    -> Routes to /perf
 8) Find bugs or improvements
    -> Routes to /ask + advisory discovery
 9) Report feedback or improvement
    -> Routes to /feedback
 10) Create a presentation
    -> Routes to /presentation
```

**Hybrid menu:**
```
What do you want to work on?

-> [ENTER] Pick up next epic/story from Jira board
   (the agent reads the ticket and proposes sub-task
    breakdown before starting work)

Or select:
 1) Pick up a specific ticket
 2) Bug — something is broken
    -> Routes to /bug
 3) Something is broken and needs fixing urgently today
    -> Routes to /hotfix
 4) Production is down right now
    -> Routes to /incident
 5) Review existing code
    -> Routes to /review
 6) Clean up / modernise existing code
    -> Routes to /refactor
 7) Security scan
    -> Routes to /security
  8) Something is slow — performance investigation
    -> Routes to /perf
 9) Find bugs or improvements
    -> Routes to /ask + advisory discovery
 10) Report feedback or improvement
    -> Routes to /feedback
 11) Create a presentation
    -> Routes to /presentation
```

**Default action (Enter):**

| Mode | What Enter does |
|---|---|
| Board-driven | Picks up the next highest priority ticket from the Jira board |
| Agent-first | Asks "What do you want to build?" and starts the `work-breakdown` skill |
| Hybrid | Picks up the next epic/story and runs the `work-breakdown` skill for sub-tasks |

**Changing the default:** The user can type `/start default` to select a new preferred default action, saved to `PROJECT.md`.

**If no Jira is configured:** Enter defaults to agent-first mode (describe what to build → `work-breakdown` → beads-only tracking).

**If the Jira board is empty (no tickets in Ready for Development or backlog):**

| Mode | What happens |
|---|---|
| Board-driven | Agent tells the user: "No tickets found on the board. You can: (1) pick a specific ticket by ID, (2) describe what to build (`/build`), or (3) check a different board column." |
| Agent-first | No issue — Enter asks "What do you want to build?" regardless of board state |
| Hybrid | Agent tells the user: "No epics or stories found on the board. You can: (1) pick a specific ticket by ID, (2) describe what to build (`/build`), or (3) check a different board column." |

The agent never fails silently on an empty board — it always offers alternatives.

### Step 2.5 — Ticket Selection UI

When the user picks option 1 (specific ticket) or Enter (next ticket), and the agent needs to show a ticket list, use the **AskUserQuestion** tool to present interactive selection buttons — not plain text. The format must be:

1. First button: "Let me browse the board" — agent fetches and shows the ticket list
2. Second button: "I have a ticket ID" — user enters a specific ID

**When showing the ticket list from the board:**

The agent uses a **two-phase approach** — tickets were already fetched in the background (Step 1.5), now just read and present.

**Phase 1 — Read pre-fetched tickets (instant):**

```bash
Bash(cat /tmp/jira-tickets-{PROJECT_KEY}.json)
```

The background fetch from Step 1.5 ran while the agent was doing Seq checks and handover reads. By this point (~5+ seconds later), the file is ready.

If the file doesn't exist or is empty (Jira not configured, or fetch failed), fall back to a direct call:
```bash
Bash(acli jira workitem search --jql "project = {PROJECT_KEY} AND status != Done ORDER BY status ASC, priority DESC, rank ASC" --fields "key,summary,issuetype,priority,status,assignee" --paginate --json)
```

Parse the JSON with `Bash(python3)` to group into the presentation format below.

If the query returns 0 results, try replacing status names with the board's actual column names. If still empty, follow the empty-board rules from the menu section.

**Present ALL tickets grouped smartly:**

```
DEV board 309 — 2 on board, 104 in backlog (106 total)

On the board:
| # | Key      | Type  | Title                          | Assignee       | Status    |
|---|----------|-------|--------------------------------|----------------|-----------|
| 1 | DEV-5650 | Story | Domain Knowledge MCP           | —              | Discovery |
| 2 | DEV-5661 | Bug   | sample application Property Info         | Alex Example   | Testing   |

Backlog — High (this repo):
| # | Key      | Type  | Title                          | Assignee       |
|---|----------|-------|--------------------------------|----------------|
| 3 | DEV-5275 | Story | LegacyConnector - BEACH WALK   | —              |
| 4 | DEV-5069 | Bug   | New email not shown            | —              |

Backlog — High (likely FE/Blazor — other repo):
| # | Key      | Type  | Title                          | Assignee       |
|---|----------|-------|--------------------------------|----------------|
| 5 | DEV-4824 | Task  | [Spike] HTML Editor for Blazor | —              |

Backlog — Medium (this repo):
[... all medium backend tickets ...]

Backlog — Medium (likely FE/Blazor — other repo):
[... all medium FE tickets ...]

Backlog — Low/Lowest:
[... all low tickets ...]

Epics (separate board):
[... all epics ...]

Notes:
- X tickets are assigned — pick up only if taking over.
- Ticket 1 is in Discovery — discovery-handling setting applies.

Type a number (1-106) or a ticket ID.
```

**Phase 2 — Full details (after user picks a ticket):**

Full ticket details are fetched only AFTER the user selects a specific ticket:

```bash
Bash(acli jira workitem view {TICKET_KEY} --fields summary,description,status,priority,assignee,comment,issuetype --json)
```

**Presentation rules (always follow these):**

- ALL tickets are loaded and shown in one pass — no lazy loading, no hiding
- Board tickets first (grouped by column), then backlog (grouped by priority)
- Within each priority, split into "this repo" and "likely FE/Blazor — other repo"
- Show all tickets including assigned ones — show assigned/unassigned counts in the summary, full assignee names when expanded

**When showing a priority group:**
- Group into "likely this repo" and "likely other repo (FE/Blazor)" for easier scanning
- Detect FE/Blazor tickets by summary keywords (component, page, Blazor, Radzen, HTML Editor, FE, UI, template, tooltip, breadcrumb, table component, skeleton, images)
- The "likely other repo" grouping is a HINT, not a filter — these tickets still appear, just grouped separately
- Show ALL tickets in the group — no skipping, no truncating

- **Epics:** Show as a separate group at the end with a note: "separate board"
- Table columns: #, Key, Type, Title, Assignee — that's it, nothing else
- Number the rows sequentially across all groups (1, 2, 3... not restarting per group)
- Show unassigned as `—`
- If a ticket is in Discovery, note that the `discovery-handling` setting from PROJECT.md applies (investigate and advance / ask first / skip)
- Let the user pick by row number or ticket ID

---

### Step 3 — Route Based on Selection

**Board-driven routing:**

| User selection | Routes to |
|---|---|
| Enter (default) | Read next Jira ticket → auto-route by ticket type |
| 1 — specific ticket | Ask for ticket ID/URL → read ticket → auto-route by type |
| 2 — Bug | `/bug` |
| 3 — Urgent fix | `/hotfix` |
| 4 — Production down | `/incident` |
| 5 — Review | `/review` |
| 6 — Clean up | `/refactor` |
| 7 — Security scan | `/security` |
| 8 — Performance | `/perf` |
| 9 — Find bugs or improvements | `/ask` |
| 10 — Feedback | `/feedback` |
| 11 — Presentation | `/presentation` |

**Agent-first routing:**

| User selection | Routes to |
|---|---|
| Enter (default) | `brainstorming` skill → `work-breakdown` skill → create beads + Jira tickets → `/flow` with first task |
| 0 — existing ticket | Ask for ticket ID/URL → read ticket → auto-route by type (same as board-driven) |
| 1-9 | Same as board-driven (shifted by one) |
| 10 — Presentation | `/presentation` |

**Hybrid routing:**

| User selection | Routes to |
|---|---|
| Enter (default) | Read next epic/story → `work-breakdown` skill for sub-tasks → `/flow` with first sub-task |
| 1 — specific ticket | Ask for ticket ID/URL → if epic/story: `work-breakdown` first. If task/bug: route directly. |
| 2-10 | Same as board-driven |
| 11 — Presentation | `/presentation` |

### Step 3.5 — Work Breakdown (agent-first and hybrid only)

**Agent-first flow (Enter):**
1. The agent asks "What do you want to build?"
2. `brainstorming` skill runs scoping questions (3-5 questions)
3. `work-breakdown` skill proposes the breakdown (epic → stories → tasks)
4. User approves, edits, or re-scopes
5. Beads created for all tasks. Jira tickets created if configured.
6. The agent suggests the logical first task and routes to `/flow`

**Hybrid flow (Enter or option 1 with epic/story):**
1. The agent reads the Jira epic or story
2. `work-breakdown` skill proposes sub-tasks underneath
3. User approves or edits
4. Beads created for all sub-tasks. Jira sub-tasks created under the parent.
5. The agent routes the first sub-task to `/flow`

**For board-driven:** This step is skipped entirely. Tickets are already sized and ready.

### Step 4 — Smart Ticket Routing (for board-driven Enter, option 1, and agent-first option 0)

When the agent reads a Jira ticket, it routes automatically based on ticket type:

| Jira ticket type | Routes to | Why |
|---|---|---|
| Story / Feature / Task | `/flow` | Planned development work (auto-detects Kanban vs Scrum) |
| Bug | `/bug` | Unexpected breakage, full workflow |
| Hotfix / Urgent | `/hotfix` | Same-day urgent fix |
| Incident / P1 | `/incident` | Production down, immediate response |
| Review / PR Review | `/review` | Code review, no new code written |
| Refactor / Tech Debt | `/refactor` | Cleanup, no new features |
| Security / Compliance | `/security` | Dedicated security scan |
| Performance | `/perf` | Slowness investigation |
| No ticket | `/build` | Ad-hoc, no Jira ticket needed |
| Unknown type | Ask one question to clarify, update Jira, then route | Agent clarifies then routes |

The routing decision is based on the methodology set in PROJECT.md:
- **Kanban** methodology → Story/Feature/Task routes to `/flow`
- **Scrum** methodology → Story/Feature/Task routes to `/flow` (which auto-detects Scrum and adds sprint planning + retrospective)
- **Ad-hoc** methodology → routes to `/build`

### Step 5 — Confirmation Summary

Before any work begins, the agent shows a confirmation summary. Showing it is mandatory — it is the report of what `/start` assembled.

The summary is also a **kickoff `Unknown` ask** (`rules/autonomy.md`), and that is the *only* reason it waits: which ticket, which workflow, which board and which target branch are not inferable from the goal, `~/.claude/memory.md`, `.claude/PROJECT.md` or the repo, so `/start` settles them once, here, instead of mid-flight. It is **not** a blanket permission gate on already-authorized work — the agent does not re-ask for consent it already has, and every field the summary can infer is shown as a stated default rather than a question.

**⛔ IMPORTANT: Use AskUserQuestion for confirmation — header `Unknown` ⛔**

After showing the summary text, the agent MUST use the **AskUserQuestion** tool to get the user's response. Do NOT rely on the user pressing Enter — some environments (e.g. Claude Code side panels in IDEs) only support clickable buttons. The AskUserQuestion must have these options:
- "Confirm and start" — proceed with the workflow
- "Edit field(s)" — user wants to change one or more fields (ask which numbers)
- "Quit" — cancel

**⛔ MANDATORY: Read board columns BEFORE showing the confirmation summary or the ticket table ⛔**

Run BOTH commands at the start of the workflow (after reading PROJECT.md):

```bash
# Get column names for [11] Columns field
Bash(bash ~/.claude/scripts/jira-board-columns.sh [BOARD_ID])
# Example output: Backlog → Discovery → Ready For Development → In Progress → Testing → Done

# Get status-to-column mapping for grouping tickets in the board table
Bash(bash ~/.claude/scripts/jira-board-columns.sh [BOARD_ID] --mapping)
# Example output: {"10000": "Backlog", "10503": "Discovery", "3": "In Progress", "10474": "Testing", ...}
```

Replace `[BOARD_ID]` with the board ID from PROJECT.md (`jira_board_id`). If PROJECT.md doesn't have `jira_board_id`, use the board ID from the board search earlier.

**Use the mapping to group tickets by column.** Each ticket has a `fields.status.id` — look it up in the mapping to find which board column it belongs to. Do NOT match column names by string-matching status names (e.g. `if 'test' in status_lower` is WRONG — use the status ID mapping instead).

If the script succeeds, the column list is used to populate the `jira_phase_map` (via the anchor questions in `/init` Sub-step 1e if not already set) and `jira_column_mapping` is cached for status-to-column lookups (so future sessions don't need to call the API again). The phase map itself is verified at every `/flow` Step 0 — see `docs/concepts/jira-phase-map.md`.

If the script fails, check PROJECT.md for saved values. If neither works, ask the user: "What are your board columns, left to right?"

**⛔ NEVER derive columns from ticket status names. Use the status ID → column mapping. ⛔**

**Note:** The confirmation summary is metadata only — which ticket, which workflow, which board. The agent does NOT need to have read the full ticket content at this stage, and should NOT suggest a branch yet. Ticket comprehension and scope decisions (code vs. no-code) happen at Step 2 (Assessment) of /flow.

**Board-driven confirmation:**
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
  [12] Mutation testing: <project default from PROJECT.md if set, else
                  Yes — auto-detect tool at verification (recommended)>
                  (Stryker — default ON for tickets that create unit
                  tests; auto-skips tickets that can't have unit tests;
                  edit to No to skip for this ticket)
-----------------------------------------
```
Then use AskUserQuestion with options: "Confirm and start", "Edit field(s)", "Quit".

**Rendering field [12]** (default-on model): The displayed value is resolved at render time. If no `mutation_testing` block exists in `.claude/PROJECT.md`, the field shows the **global default `Yes — auto-detect tool at verification (recommended)`**. If the block exists, the field shows the project override: `before_pr` → the project-configured `Yes — <tool>` value from `mutation_testing.tool` (pinned, no auto-detect) IF `tool` is set, otherwise `Yes — auto-detect tool at verification (recommended)` (a `before_pr` block without `tool` keeps auto-detect — `tool` is not required); `test_only_prs` → `No` at `/start` (ticket classification is not known yet) with the monotonic promotion to `Yes` at Verification if Assessment classifies the ticket as test-only; `manual` → `No` because that policy explicitly opts the project OUT of default-on. The example above uses `<project default ... else Yes — auto-detect ...>` to make this dynamic behaviour explicit in the prose.

**Field [12] — Mutation testing (default ON, context-gated):** Default is `Yes — auto-detect tool at verification (recommended)` when `.claude/PROJECT.md` has no `mutation_testing` block. When the block exists, the field defaults to the project value derived from `mutation_testing.when_to_run`:

- `before_pr` → `Yes` for EVERY ticket. If `mutation_testing.tool` is set, the field pins that tool (`Yes — <tool>`, skipping auto-detection); if `tool` is omitted, it falls back to `Yes — auto-detect tool at verification (recommended)` (same as the global default). `tool` is NOT required for `before_pr`. Confirmed at `/start`, runs at Verification.
- **`test_only_prs` → `No` at `/start` time (CONSERVATIVE default), promoted to `Yes` automatically at Verification IF Assessment classified this ticket as test-only.** (Shows `No` at `/start` because the classification isn't known until Assessment runs after `/start`; `/flow` Step 11b promotes it. A small note next to the field — "project uses test_only_prs policy — mutation testing activates at Verification if ticket is test-only" — tells the user what's happening. No silent flip from `Yes` to `No`.) The user can still edit the field to `Yes` at `/start` to force mutation testing regardless of classification.
- `manual` → `No` because the project explicitly opted OUT of default-on (manual-only invocation).

**The unit-test gate is what makes "default Yes" safe.** Showing `Yes` at `/start` is the default *intent*; the actual run at Verification is gated on whether this ticket created (or should have created) unit tests — the same TDD decision the agent makes during discovery/assessment/planning/implementation. A ticket that produces testable production code gets unit tests and Stryker validates them. A ticket that **cannot meaningfully have unit tests** (pure config, docs, infra/pipeline YAML, identifier renames, generated code) writes no unit tests, and `/flow` Step 11b **auto-skips** Stryker even though the field said `Yes`. So "default Yes" never wastes time on tickets with nothing to mutate — it just removes the friction of remembering to opt in on the tickets that DO warrant it. The user can always edit the field to `No` to skip a qualifying ticket, and `/hotfix` + `/incident` skip Stryker entirely to ship fast.

**No PROJECT.md edits required** — the global default covers the common case. The OPTIONAL `mutation_testing` block (see `examples/PROJECT.md.example`) only changes things for projects that want to pin a specific tool (`before_pr`), restrict to test-only PRs (`test_only_prs`), or opt OUT of default-on (`manual`). If a project has the block, this field shows the project override; the user can still edit it per-ticket.

**When the user edits field [12]**, use AskUserQuestion with these options:
- `Yes — auto-detect tool at verification (recommended)` (default) — at verification time, the toolbox scans the repo for supported stack signals: `*.csproj` (→ Stryker.NET), `package.json` with a supported test runner (→ Stryker.JS), `pom.xml` with Java source (→ PIT), or Scala source with `build.sbt` (→ Stryker for Scala). If multiple match or none match, the agent asks you to pick or records not-applicable at verification time.
- `No — skip mutation testing for this ticket`
- `Yes — Stryker.NET` — force the .NET path
- `Yes — Stryker.JS` — force the JS/TS path
- `Yes — Stryker for Scala` — force the Scala path

The 3 explicit Stryker tool picks plus auto-detect cover the supported mutation runners in the toolbox registry (`workflow-discipline` skill §1a). If the user picks an explicit tool on a project that doesn't match its stack signals, Step 11b surfaces the mismatch and asks them to re-pick rather than running the wrong tool.

**Natural-language shortcut:** because mutation testing is now ON by default, the opt-IN keywords (`use stryker`, `with stryker`, `run stryker`, `enable stryker`, `stryker on`, `use mutation testing`, `with mutation testing`, `run mutation testing`, `enable mutation testing` — case-insensitive verb-phrase substring match) mostly just reaffirm the default; they still pin field [12] to `Yes — auto-detect tool at verification (recommended)`. The more useful direction is **forcing it OFF**: if the user's invocation contains an opt-OUT phrase (`no stryker`, `skip stryker`, `without stryker`, `disable stryker`, the `... mutation testing` variants) OR a **negated opt-in** (an opt-in keyword preceded within 4 words by `don't` / `do not` / `not` / `never` / `no`, e.g. "don't run stryker"), pre-populate field [12] as `No` and surface it so the user can re-enable. This is the same closed keyword set documented in full in the `workflow-discipline` skill ("Mutation-testing keyword grammar") — bare `stryker` (single token without a verb prefix) triggers neither, to avoid false positives like "I found a stryker performance bug". Conjunctions like "also" and "and" are NOT verbs, so `also stryker` and `and stryker` are NOT keywords.

**What happens at Verification:** the field value is captured in the confirmation summary, saved to `.claude/handover.md` after `/start`, and read by `/flow` Step 11 (Verification Before Completion). When the value is **any affirmative `Yes` variant** — `Yes — auto-detect tool at verification (recommended)` OR an explicit `Yes — Stryker.NET` / `Yes — Stryker.JS` / `Yes — Stryker for Scala` — AND the ticket created unit tests, Stryker is invoked via the tool registry in the `workflow-discipline` skill §1a (auto-detect resolves the tool, or the explicit pick is used directly). Only a literal `No` skips. When the ticket created no unit tests (nothing to mutate), Step 11b auto-skips even on a `Yes` value.

**Why no feature-branch field?** The agent hasn't assessed whether code changes are needed yet. Proposing a feature branch name at this stage presumes code is needed — but many tickets don't need code (design, docs, verification-only, requirements). The feature branch is proposed at Step 2 of /flow ONLY after the Assessment confirms "Code changes needed: Yes", and created at Step 7.

**Target branch field (different from feature branch):** This is the PR base branch — which branch the eventual PR will merge INTO, not the feature branch name. The default is `main`. If the user states a branch constraint at any point during the session ("only net8", "target portal2"), the agent MUST set this field to the stated branch. If the user states a negative constraint ("don't merge to main"), ask which branch to target instead — don't set the negative as a value. The field is editable like any other field. This constraint is passed to `/flow` and enforced at PR creation time by the `finishing-a-development-branch` skill.

**Agent-first / hybrid confirmation** (after work-breakdown approval):

In agent-first/hybrid mode, the user already approved the work-breakdown which explicitly defined coding sub-tasks. The branch field IS shown because scope is known — these tasks were created as implementation work.

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
  [14] Mutation testing: <project default from PROJECT.md if set, else
                  Yes — auto-detect tool at verification (recommended)>
                  (Stryker — default ON for tickets that create unit
                  tests; auto-skips tickets that can't have unit tests;
                  edit to No to skip for this ticket)
-----------------------------------------
```
Then use AskUserQuestion with options: "Confirm and start first task", "Edit field(s)", "Quit".

**Field [14] follows the same semantics as field [12] in the board-driven summary** — see above for the AskUserQuestion options, natural-language shortcut, AND PROJECT.md-default rendering rule. The only difference is the field number, which shifts because agent-first/hybrid has an extra `[13] Breakdown` field.

**Default integrations vary by workflow:**

| Workflow | Default integrations | Why |
|---|---|---|
| `/flow`, `/build`, `/refactor` | Jira (acli), Beads | No log queries needed for feature work |
| `/bug`, `/hotfix` | Jira (acli), Seq, Beads | Seq for error investigation |
| `/incident` | Jira (acli), Seq, Beads | Seq queried immediately — speed priority |
| `/perf` | Jira (acli), Seq, Beads | Seq for response time analysis |
| `/review`, `/security` | Jira (acli), Beads | Read-only review, no log queries |

The agent sets the integration defaults based on the selected workflow. The user can always override via field [9].

**Editing fields:** The user picks "Edit field(s)", then types number(s) to change one or more fields simultaneously (e.g. `3 5` changes Type and Workflow at the same time). The summary refreshes with `<- changed` markers on every affected field. After editing, show the summary again and use AskUserQuestion for confirmation.

### Cascade Logic

When the user changes one field, the agent automatically updates all dependent fields. Every cascaded change is shown with `<- changed` so nothing is silently updated:

| If you change | Agent automatically updates |
|---|---|
| [1] Ticket | Title, Type, Priority, Workflow, Branch name, Skip list, Integrations recommendation, Columns |
| [2] Title | Branch name (slug generated from new title) |
| [3] Type | Workflow, Branch prefix, Skip list, Priority suggestion |
| [4] Priority | Nothing — priority is independent |
| [5] Workflow | Branch prefix, Skip list, Columns |
| [6] Branch name | Nothing — manual rename only |
| [7] Beads | Nothing — independent toggle |
| [8] Skip list | Nothing — manual override only |
| [9] Integrations | Nothing — independent selection |
| [10] Board | Ticket list refreshes to show tickets from the selected board |
| [11] Columns (board-driven) / [11] Columns (agent-first) | Nothing — derived from the unique non-null values in PROJECT.md `jira_phase_map` (in phase order: `discovery → ready_for_dev → in_progress → code_review → ready_for_release → done`, deduped). Falls back to `bash ~/.claude/scripts/jira-board-columns.sh [BOARD_ID] --json` if the phase map isn't set. NEVER derive from ticket statuses. If the user edits this field, only offer columns from the live board (script output). |
| [11] Target branch (board-driven) / [12] Target branch (agent-first) | Nothing — defaults to `main`. Updated when user states a branch constraint ("only net8", "target portal2", "don't merge to main"). Passed to `/flow` and enforced at PR creation. |
| [13] Breakdown (agent-first only) | Nothing — derived from work-breakdown |
| [12] Mutation testing (board-driven) / [14] Mutation testing (agent-first) | **Default ON: `Yes — auto-detect tool at verification (recommended)` when `.claude/PROJECT.md` has no `mutation_testing` block.** When the block exists it overrides: `before_pr` → `Yes — auto-detect ...` (pins the tool); `test_only_prs` → `No` at `/start`, promoted to `Yes` at Verification if the ticket is test-only; `manual` → `No` (project opted OUT of default-on). Independent of all other workflow fields. The displayed `Yes` is the default intent — Step 11b gates the actual run on whether the ticket created unit tests (auto-skips tickets that can't have unit tests). Editing opens an AskUserQuestion with **5 options**: `Yes — auto-detect tool at verification (recommended)` (default), `Yes — Stryker.NET`, `Yes — Stryker.JS`, `Yes — Stryker for Scala`, `No`. Natural-language opt-OUT phrases ("no stryker", "skip stryker", "without stryker", etc. — full grammar in the `workflow-discipline` skill) pre-populate this field as `No` for that ticket; opt-IN phrases reaffirm the `Yes` default. |

### Step 6 — Hand Off to Command

**⛔ MANDATORY HANDOFF — DO NOT SKIP ⛔**

After the user confirms, the agent MUST hand off to the selected command (`/flow`, `/build`, `/bug`, etc.) by loading and executing that command's skill file. The agent MUST NOT implement the ticket directly from `/start` — no coding, no branch creation, no Jira transitions beyond what `/start` specifies.

**Why this matters:** `/flow` contains the column transition logic (Backlog → Discovery → Ready for Dev → In Progress), the brainstorming gate, the implementation plan gate, and the PR approval gate. If `/flow` is skipped, none of these guardrails apply and the agent will jump straight to coding.

**How to hand off:** Use the Skill tool to invoke the target command (e.g. `Skill("flow")`). The confirmation summary data is passed along — the target command does not re-ask for it.

**The agent MUST NOT:**
- Start coding after the confirmation summary
- Create a branch from `/start`
- Move the ticket to In Progress from `/start`
- Skip `/flow` because the ticket "looks ready to code"
- Decide the ticket is "simple enough" to handle without `/flow`

---

## What Never Gets Skipped

Regardless of whether the user enters via `/start` or runs a command directly:
- `/init` (if project not configured)
- Confirmation summary
- Quality gates (TDD, code review)
- Security checks
- PR creation (where applicable)

---

## Notes

- `/start` adds 2 steps (menu + selection) compared to running a command directly — use direct commands when you already know which workflow you need
- The agent never starts work before the summary screen settles the genuinely-unknown fields (ticket, workflow, board, target branch) — that is a kickoff `Unknown` ask, not a blanket permission gate (`rules/autonomy.md`)
- All Jira interactions use `acli` via the `jira-workflow-steward` agent (Haiku) for status moves, branch naming, and comments
