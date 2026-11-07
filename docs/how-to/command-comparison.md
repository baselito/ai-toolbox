# Command Comparison — What Each Command Does and Doesn't Do

A side-by-side comparison of `/start`, `/init`, and the direct work commands. Use this to understand exactly what happens when you run each command, and what gets skipped.

---

## When to Read This

- You want to understand the difference between running `/start` and running a command directly
- You want to know which features (brainstorming, debugging, planning) apply to which commands
- You want to understand why some commands skip certain steps

---

## How `/start` Works

`/start` is a router — it does three things on its own, then hands off to a direct command:

1. **Show menu** — lets you pick what to do (or press Enter for the default)
2. **Read board + route** — reads your Jira ticket and picks the right command based on ticket type

Everything else — brainstorming, debugging, agents, tests, PRs — happens inside whichever command `/start` routes you to. The result is identical whether you typed `/start` and pressed Enter, or typed `/flow` directly. The only thing you lose by going direct is the menu.

See [how routing works](../../commands/start.md#step-3--route-based-on-selection) for the full routing table.

---

## Why Run One Command Over Another

Every work command can be reached through `/start`. So why would you ever type a direct command instead? And why would you run `/init` on its own when `/start` includes it? This section explains the reasoning.

| Command | Why run this directly instead of going through `/start` |
|---|---|
| **`/start`** | You don't need a reason — this is the default. Run `/start` when you're beginning your day, coming back from a break, or not sure what to do next. It shows the menu and routes you to the right command. If you only remember one command, this is it. |
| **`/init`** | On a brand new project, you never need to type `/init` yourself — `/start` (and every other command) checks for `PROJECT.md` and runs `/init` automatically if it's missing. So your first time on any project, just type `/start` and the setup wizard appears before anything else. **When you would run `/init` directly:** after you've already gone through the setup once (either by running `/init` or because `/start` triggered it for you) and you need to change something later. For example: you moved to a different Jira board, you want to change your CI/CD tool, or you added a new MCP and need to activate it. Running `/init` on an already-configured project skips the setup questions and shows a summary screen with your current settings — you type a number to edit just the field you want to change, press Enter to save. |
| **`/flow`** | You already know the ticket you want to work on and you know it's a feature or story. Typing `/flow` skips the `/start` menu and goes straight to the confirmation summary. You save two steps (menu + selection) but get exactly the same workflow. Good for when you're mid-sprint and know what's next. |
| **`/build`** | You want to build something that doesn't have a Jira ticket — a prototype, an experiment, a quick internal tool. There's no ticket to route from, so `/start` would just add an extra step. `/build` asks what you want to build and gets straight to work. |
| **`/bug`** | You already know something is broken and you want to jump straight into debugging. Going through `/start` would show you the menu, you'd pick option 2, and you'd end up at `/bug` anyway. Running `/bug` directly saves that step. |
| **`/hotfix`** | Something is broken **and it needs to ship today**. Speed matters, so every skipped step counts. `/hotfix` runs the same root cause analysis as `/bug` but skips brainstorming, full planning, and extended documentation. It also tells CI/CD to fast-track the deployment so your fix reaches production faster. If the issue can wait until tomorrow, use `/bug` instead. |

**The short version:** `/start` is always safe to run. Direct commands are shortcuts for when you already know what type of work you're doing and don't need the menu.

---

## Key Terms Used in This Table

If any term is unfamiliar, follow the link to the page that explains it:

| Term | What it means | Where to learn more |
|---|---|---|
| Board-driven / agent-first / hybrid | Three workflow modes that control how tickets get into Jira and how `/start` behaves | [Jira integration guide](jira-integration.md) |
| Chief-of-staff | The orchestrator agent that decides which specialist agents to activate based on what files you changed | [How orchestration works](../concepts/agents.md) |
| Beads | AI task tracking that persists across sessions — if you close your laptop and come back, the agent knows where you left off | [What is Beads?](../concepts/beads.md) |
| Seq | A log server used during incidents and performance investigations to query live production logs | [Seq log queries](incident-response.md) |
| RED-GREEN-REFACTOR | The TDD cycle: write a failing test (red), write code to make it pass (green), clean up (refactor). The agent enforces this order. | [What is TDD?](../concepts/tdd.md) |
| Opus / Sonnet / Haiku | AI model tiers. Fable = the orchestrator (the session agent itself). Opus = deep reasoning (used for architecture, security). Sonnet = retrieval and capture. Haiku = fast and cheap (docs, Jira moves). | [Model assignments](../reference/model-assignments.md) |
| Work-breakdown | A skill that decomposes a goal into epic, stories, and tasks — so the agent builds in manageable pieces | [Work breakdown skill](../../skills/work-breakdown/SKILL.md) |
| Branch naming (slug) | The agent creates branches like `feature/DEV-5680-auth-redirect`. The slug is the short description at the end. | [Git workflow rules](../../rules/git-workflow.md) |
| Scrum vs Kanban | Two board types in Jira. The agent auto-detects which one you use. Scrum boards get sprint planning; Kanban boards don't. | [Sprint planning in /flow](../../commands/flow.md) |
| Confirmation summary | A summary shown before any work starts — you approve, edit fields, or cancel. `/flow` shows 12 fields including the kanban column path. Nothing happens without your explicit approval. | [Confirmation summary details](confirmation-summary.md) |

---

## Full Comparison Table

| Feature | What it does | `/start` | `/init` | `/flow` | `/build` | `/bug` | `/hotfix` |
|---|---|---|---|---|---|---|---|
| **Check PROJECT.md** | Ensures project is configured before work begins — runs `/init` automatically if missing | Yes | This IS the setup | Yes | Yes | Yes | Yes |
| **Show menu** | Interactive menu to pick what you want to do — adapts to your [workflow mode](jira-integration.md) (board-driven / agent-first / hybrid) | Yes — this is `/start`'s main job | No | No — you already chose | No — you already chose | No — you already chose | No — you already chose |
| **Read Jira board** | Fetches tickets from your Jira board to pick or route work. Shows interactive buttons ("Let me browse the board" / "I have a ticket ID"). Board view shows all columns first (Discovery, To Do, In Progress), then backlog — grouped by priority. All priorities and assigned tickets are shown so you can take over someone's work if needed. | Yes — lists tickets and routes by type | Reads board type only (Kanban vs Scrum) | Yes — same interactive ticket selection as `/start` ("Let me browse the board" / "I have a ticket ID") | No — you describe what to build | No — you describe the bug | No — you describe the issue |
| **Route by ticket type** | Reads the Jira ticket type and picks the right command automatically (Story→`/flow`, Bug→`/bug`, Hotfix→`/hotfix`, etc.) | Yes — this is `/start`'s [routing](../../commands/start.md) job | No | No — already in `/flow` | No — no ticket | No — already in `/bug` | No — already in `/hotfix` |
| **[Confirmation summary](confirmation-summary.md)** | Shows a summary of what the agent will do before starting — you approve, edit fields, or cancel. Fields vary by command — `/flow` shows methodology, agents, Jira mapping, column lifecycle; `/bug` and `/hotfix` show priority, skipping, MCPs instead. Fewer fields when there's less context (e.g. `/build` has no ticket or board). | Yes — shown by whichever command `/start` routes to. Fields depend on that command. | Config summary only (4 setup questions + auto-detected settings, not a work summary) | Yes — 12 fields: ticket, title, type, workflow, methodology, branch, agents, Jira mapping, beads, security level, board, columns (see [mock-up below](#what-flow-looks-like)) | Yes — 5-7 fields: no ticket or board fields since there's no Jira ticket. Includes scope, branch name, and beads. | Yes — 10 fields: ticket, title, type, priority, workflow, branch, beads, skipping, MCPs, board | Yes — 10 fields: ticket, title, type, priority, workflow, branch, beads, skipping, MCPs, board. Also lists which steps are skipped for speed. |
| **Create [beads](../concepts/beads.md)** | Creates AI task tracking entries so work persists across sessions and tool switches | Yes — created by whichever command `/start` routes to | No | Yes | Yes, but optional for single-task (agent asks if you want tracking) | Yes | Yes |
| **Move Jira tickets** | Moves tickets through Jira columns via the [jira-workflow-steward](../reference/agent-list.md) agent. `/flow` follows the full kanban lifecycle: Discovery (optional) → Ready for Dev → In Progress → In Review → Testing → Done, with a Jira comment at every transition. | Yes — handled by whichever command `/start` routes to. Only moves if that command has a Jira ticket. | No | Yes — full kanban column lifecycle with comments at every transition | Only if [agent-first mode](jira-integration.md) created tickets during work-breakdown | Yes — also auto-creates a Bug ticket if you described the bug instead of providing a ticket | Yes — auto-creates a ticket with Critical priority if none exists |
| **Discovery phase** | Optional investigation phase before development — the agent explores the codebase, reads related tickets, and writes findings as a Jira comment before moving to Ready for Development | Yes if routed to `/flow` and the ticket is in Discovery or the user opts in. No for `/bug`, `/hotfix`. | No | Yes — optional, controlled by `discovery_handling` in PROJECT.md (investigate and advance / ask first / skip) | No — you describe what to build | No — the problem already exists | No — the fix needs to ship today |
| **External change detection** | Before every Jira column transition, re-reads the ticket to detect changes by other team members (assignee, priority, new comments, status) | Yes if routed to `/flow`. No for other commands. | No | Yes — runs before every column transition | No — no Jira column tracking | No | No |
| **[Brainstorming](../../skills/brainstorming/SKILL.md)** | Asks 3-5 scoping questions to refine design before coding — prevents building the wrong thing | Yes if routed to `/flow` or `/build`. No if routed to `/bug` or `/hotfix` — those go straight to debugging instead. | No | Yes — you're building something new, design matters | Yes — you're building something new, design matters | No — the problem already exists, no design needed, the agent goes straight to root cause analysis | No — the problem already exists, no design needed, the agent goes straight to root cause analysis and the fix needs to ship today |
| **[Opus](../reference/model-assignments.md) planning** | Deep implementation plan by the planner agent (Opus tier) — multi-file architecture decisions | Yes if routed to `/flow` or `/build` (full plan). Minimal if routed to `/hotfix`. No if routed to `/bug`. | No | Yes — full implementation plan | Yes — full implementation plan | No — the fix is usually scoped to one area and doesn't need architecture planning | Minimal plan only — just enough to fix safely, full planning would waste time on an urgent fix |
| **[Systematic debugging](../../skills/systematic-debugging/SKILL.md)** | 4-phase root cause analysis with [Seq](incident-response.md) log queries — runs on [Opus](../reference/model-assignments.md) after 2 failed attempts | Yes if routed to `/bug` or `/hotfix`. No if routed to `/flow` or `/build`. | No | No — nothing is broken, you're building new functionality | No — nothing is broken, you're building new functionality | Yes — this is the core of `/bug`, finds the root cause before any code is written | Yes — runs the full root cause analysis before fixing, then fast-tracks the deployment |
| **[TDD](../concepts/tdd.md) enforcement** | The [tdd-guide](../reference/agent-list.md) agent enforces the RED-GREEN-REFACTOR cycle — blocks completion if tests are missing or written after code | Yes — enforced by every work command that `/start` routes to | No | Yes — write tests before code | Yes — write tests before code | Yes — write a failing test that reproduces the bug first, then write the fix to make it pass | Yes — write a failing test that reproduces the bug first, then write the fix to make it pass |
| **Run [agents](../concepts/agents.md) / quality gates** | The [chief-of-staff](../concepts/agents.md) agent selects specialist agents based on files changed — code review, security, accessibility, DB review, API testing, etc. Never skipped, even for urgent fixes. | Yes — run by whichever command `/start` routes to. The agents are identical regardless of entry point. | No | Yes — full agent orchestration | Yes — full agent orchestration | Yes — full agent orchestration | Yes — full agent orchestration, quality gates are never skipped even when speed matters |
| **Create branch + PR** | Creates a named branch, does the work, opens a PR with linked Jira ticket and summary. See [branch naming rules](../../rules/git-workflow.md). | Yes — created by whichever command `/start` routes to. Branch naming depends on the command. | No | Yes — `feature/DEV-XXX-description` | Yes — you name the branch yourself | Yes — `bugfix/DEV-XXX-description` | Yes — `hotfix/DEV-XXX-description` |
| **[Scrum](../../commands/flow.md) sprint planning** | If your board is Scrum (auto-detected from Jira), runs sprint planning (team capacity, velocity) before work and a retrospective after. Kanban boards skip this. | Yes if routed to `/flow` and board is Scrum. No for all other commands — sprint planning only makes sense for planned feature work. | No | Yes — Scrum boards only, Kanban boards skip this | No — no Jira board involved | No — bug fixes don't need sprint planning | No — urgent fixes don't need sprint planning |
| **Fast-track CI/CD** | Tells the [devops-automator](../reference/agent-list.md) agent to prioritise this deployment in the pipeline queue — jumps ahead of normal builds | Yes only if routed to `/hotfix`. No for all other commands — normal deployment priority is fine for non-urgent work. | No | No — normal deployment priority | No — normal deployment priority | No — normal deployment priority | Yes — the fix needs to reach production today, so it jumps the deployment queue |

---

## When Are Jira Tickets and Beads Created?

Whether Jira tickets are created or read depends on how you got to the command and whether Jira is configured:

| Scenario | Jira ticket | Beads |
|---|---|---|
| `/start` → picks a ticket from the board | **Read** from Jira, updated with notes | **Created** new, linked to the existing ticket |
| `/bug` or `/hotfix` typed directly, no ticket | **Created** automatically by the agent | **Created** new, linked to the new ticket |
| `/build` typed directly, no Jira configured | No Jira ticket | **Created** on its own for session tracking |
| Any command, Jira is down or not configured | No Jira ticket — agent uses [beads-only tracking](../concepts/beads.md) | **Created** on its own for session tracking |

---

## The `/start` Menu

When you run `/start`, you see this menu (board-driven mode shown):

```
What do you want to work on?

-> [ENTER] Pick up next Jira ticket  (your default)

Or select:
 1) Pick up a specific ticket
 2) Bug — something is broken
 3) Something is broken and needs fixing urgently today
 4) Production is down right now
 5) Review existing code
 6) Clean up / modernise existing code
 7) Security scan
 8) Something is slow — performance investigation
 9) Report feedback or improvement
```

- **Enter** — the agent picks the next highest priority ticket from the board automatically
- **1** — shows interactive buttons: "Let me browse the board" or "I have a ticket ID"
  - **Browse the board** — fetches tickets and shows a numbered table grouped by priority (High → Medium → Low). All priorities are included — nothing is filtered out. Pick by row number or ticket ID.
  - **I have a ticket ID** — type a ticket ID like `DEV-5680` and the agent reads it
- **2-9** — routes directly to the matching command

After the agent picks or reads a ticket, the [confirmation summary](confirmation-summary.md) is shown. You can edit any field (including changing the ticket) or cancel before work starts. Nothing is committed until you approve.

The menu looks different in [agent-first and hybrid modes](jira-integration.md) — the default Enter action changes, but the numbered options are the same.

---

## The `/init` Setup Flow

When you type `/start` (or any command) in a new project for the first time, the agent won't find a `PROJECT.md` file. It shows this message:

```
👋 First time on this project!

No PROJECT.md found — this project hasn't been configured yet.
The agent will auto-detect your stack and methodology, then ask
a few quick setup questions (Jira, CI/CD, tracking).

This only happens once. After setup, /start goes straight to the menu.
```

Then it runs `/init`. The agent first auto-detects your stack and methodology from the codebase and Jira board type, then asks up to 4 setup questions one at a time. Each question has numbered options — you type a number and press Enter.

**Auto-detected (no questions asked):** Stack (from project files), Methodology (from Jira board type), Security sensitivity (from conditional agent rules), Logging (detected when needed), Project type (determined by command), Team size (asked during sprint planning if needed).

Here are the questions in order:

```
Q1  — Do you use Jira?
       1) Yes — Jira Cloud
       2) Yes — Jira Server / Data Center
       3) No — skip Jira integration

Q2  — What CI/CD tool do you use?
       1) GitHub Actions  <- default for toolbox
       2) Other
       3) None

Q3  — How do tickets get into Jira?
       (only shown if Jira configured)
       1) Board-driven — your team puts tickets on the
          board, the agent picks them up
       2) Agent-first — the agent creates all tickets
          after asking you questions
       3) Hybrid — your team creates epics and stories,
          the agent creates technical sub-tasks

Q4  — How do you want to track tasks internally?
       (only shown if Jira configured)
       1) Jira + Beads  <- recommended
       2) Jira only
       3) Beads only
```

After all questions, the agent shows an MCP configuration screen (which tools are active/disabled), then a final summary screen showing both auto-detected settings and your answers — you can edit any field before saving.

On repeat runs, `/init` skips the questions and shows the summary screen directly with your previous answers pre-filled. You edit only what changed.

See the [full /init command](../../commands/init.md) for details on each question, auto-detection, and the MCP configuration screen.

---

## What `/flow` Looks Like

When you run `/flow` directly, you first see a ticket selection prompt:

```
Pick a ticket:

-> [ENTER] Pick up next ticket from the board
    1) Pick a specific ticket (enter ID or URL)
```

- **Enter** — the agent picks the next highest priority ticket from the board automatically
- **1** — you type a ticket ID (like `DEV-5680`) or paste a URL, and the agent reads that specific ticket

If `/start` routed you here with a ticket already selected, this prompt is skipped.

After a ticket is selected, the agent shows the confirmation summary:

```
-----------------------------------------
  Work Summary — please confirm
-----------------------------------------
  [1]  Ticket:       DEV-5680
  [2]  Title:        Auth redirect loop on login
  [3]  Type:         Story
  [4]  Workflow:     /flow
  [5]  Methodology:  Kanban
  [6]  Branch:       feature/DEV-5680-auth-redirect
                    (proposed — created at Step 7, not now)
  [7]  Agents:       tdd-guide, code-reviewer,
                     security-reviewer, reality-checker
  [8]  Jira:         Ready for Dev → In Progress →
                     In Review → Done
  [9]  Beads:        New issue created
  [10] Security:     Customer-facing (scan after feature)
  [11] Board:        DEV board 309
  [12] Columns:      Ready for Dev → In Progress →
                     In Review → Done

  [ENTER] Confirm and start
  [E]     Edit field(s)
  [Q]     Quit
-----------------------------------------
```

Type a number to edit any field, Enter to start, or Q to cancel. The agent won't write any code until you approve.

---

## What `/build` Looks Like

When you run `/build`, the agent asks what you want to build, then shows:

```
-----------------------------------------
  Work Summary — please confirm
-----------------------------------------
  [1]  Task:      User-provided description
  [2]  Type:      Feature / Prototype / Experiment
  [3]  Branch:    feature/description-slug
  [4]  Beads:     [Y/N] — track this in Beads?
  [5]  Skipping:  Jira integration
  [6]  MCPs:      Beads (if enabled)

  [ENTER] Confirm and start
  [E]     Edit field(s)
  [Q]     Quit
-----------------------------------------
```

Fewer fields than `/flow` because there's no Jira ticket or board involved.

---

## What `/bug` Looks Like

When you run `/bug`, the agent asks you to describe the bug (or reads the Jira ticket if routed from `/start`), then shows:

```
-----------------------------------------
  Work Summary — please confirm
-----------------------------------------
  [1]  Ticket:    DEV-5680 (auto-created)
  [2]  Title:     Auth redirect loop on login
  [3]  Type:      Bug
  [4]  Priority:  High
  [5]  Workflow:  /bug
  [6]  Branch:    bugfix/DEV-5680-auth-redirect-loop
  [7]  Beads:     New issue created
  [8]  Skipping:  Brainstorming, full planning
  [9]  MCPs:      Jira (acli), Seq, Beads
  [10] Board:     DEV board 309

  [ENTER] Confirm and start
  [E]     Edit field(s)
  [Q]     Quit
-----------------------------------------
```

Notice field [8] — it tells you brainstorming and full planning are skipped because the agent goes straight to root cause analysis instead.

---

## What `/hotfix` Looks Like

When you run `/hotfix`, it looks almost identical to `/bug` but with more items skipped:

```
-----------------------------------------
  Work Summary — please confirm
-----------------------------------------
  [1]  Ticket:    DEV-5690
  [2]  Title:     Payment redirect failing
  [3]  Type:      Hotfix
  [4]  Priority:  Critical
  [5]  Workflow:  /hotfix
  [6]  Branch:    hotfix/DEV-5690-payment-redirect
  [7]  Beads:     New issue created
  [8]  Skipping:  Brainstorming, full planning,
                  extended docs
  [9]  MCPs:      Jira (acli), Seq, Beads
  [10] Board:     DEV board 309

  [ENTER] Confirm and start
  [E]     Edit field(s)
  [Q]     Quit
-----------------------------------------
```

Field [4] is always Critical (hotfixes are urgent by definition). Field [8] shows more items skipped than `/bug` — extended documentation is also skipped to save time. The CI/CD deployment is fast-tracked after the fix is ready.

---

## Plugin Commands vs Our Commands

When you type `/` in the chat, you'll see 150+ commands. Most are from plugins (ECC and Beads), not from us. Here's how to tell them apart and what to use.

**Quick rule:** If you recognise the command name (`/start`, `/flow`, `/bug`, etc.) — use it. If it has a `/beads:` prefix — safe to use. Everything else — ignore it unless you've checked the list below.

For the full reference of every external command with descriptions, see [External Commands Reference](../reference/external-commands.md).

### External commands recommended for use

These are plugin commands that provide useful functionality our workflows don't cover:

| Command | What it does | When to use |
|---|---|---|
| `/beads:list` | List all beads in the current project | When you want to see all tracked tasks |
| `/beads:show` | Show details of a specific bead | When you want to inspect a specific task |
| `/beads:stats` | Show bead statistics (active, blocked, completed) | When you want a quick overview of project status |
| `/beads:search` | Search beads by keyword | When looking for a specific task |
| `/beads:blocked` | List blocked beads | When you want to see what's stuck |
| `/strategic-compact` | Smart context compaction strategy | When context window is filling up mid-workflow |
| `/deep-research` | Multi-pass research workflow | When you need to understand a complex topic before building |
| `/release-notes` | Generate release notes from commits | After merging a PR or finishing a sprint |
| `/pr-comments` | Handle PR comment discussions | When reviewing PRs with team feedback |
| `/heapdump` | Memory/heap analysis | When debugging memory leaks |
| `/exa-search` | Web search powered by Exa | When researching during debugging or design |
| `/prompt-optimizer` | Refine and optimise prompts | When building prompt-based features |

### External commands to avoid (conflict with ours)

These do similar things to our commands but without the full orchestration, Jira, beads, or quality gates. Our versions are better — always use ours instead.

| Don't use this | Use this instead | Why ours is better |
|---|---|---|
| `/debug` | `/bug` | Ours runs 4-phase root cause analysis with Seq logs, on Opus |
| `/security-review` | `/security` | Ours runs full OWASP scan with `security-engineer` (Opus) + severity grading |
| `/security-scan` | `/security` | Ours runs full OWASP scan with `security-engineer` (Opus) + severity grading |
| `/tdd-workflow` | `/flow`, `/build`, `/bug` | Ours enforces TDD as part of every workflow automatically via the `tdd-guide` agent |
| `/e2e-testing` | `/flow`, `/build` | Ours runs E2E as part of the quality gate chain |
| `/documentation-lookup` | `/ask` | Our `docs-lookup` agent uses Context7 MCP for live documentation |
| `/database-migrations` | `/ef-migration-management` | Our skill is EF-specific and tailored to our stack |
| `/api-design` | `/flow`, `/build` | Our `api-tester` agent runs API testing as part of the review chain |
| `/architecture-decision-records` | `/flow` | Our `architect` agent (Opus) generates ADRs within the workflow |
| `/backend-patterns` | `/flow`, `/build` | Our patterns are stack-specific (C#/Blazor/Next.js) |
| `/frontend-patterns` | `/flow`, `/build` | Our patterns are stack-specific (Blazor/Radzen/React) |
| `/deployment-patterns` | `/hotfix` | Our `devops-automator` agent handles deployment as part of the workflow |
| `/everything-claude-code:code-review` | `/review` | Ours runs the full agent orchestration — code review + conditional reviews based on files changed |
| `/everything-claude-code:refactor-clean` | `/refactor` | Ours runs analysis, plan approval, TDD, full review chain, and PR creation |
| `/everything-claude-code:tdd` | `/flow`, `/build`, `/bug` | Ours enforces TDD as part of every workflow automatically |
| `/everything-claude-code:plan` | `/flow`, `/build` | Ours uses the `planner` agent (Opus) with full context from brainstorming |
| `/everything-claude-code:verify` | `/flow`, `/build` | Ours runs `verification-before-completion` + `reality-checker` as part of the workflow |
| `/everything-claude-code:security` | `/security` | Ours runs full OWASP audit, auto-fixes CRITICALs, creates a PR |

### Everything else in the / list

The remaining 90+ commands are ECC skills for languages we don't use (Django, Laravel, Kotlin, Rust, Swift, etc.) or industries we don't work in (logistics, energy, manufacturing). They're not harmful — just noise. If toolbox expands to a new stack or domain, check the [full external commands reference](../reference/external-commands.md) — the skill you need might already be installed.
