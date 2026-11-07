# Agentic Coding Toolbox

An agentic coding toolbox — AI agents that autonomously handle coding tasks — turning Claude Code and Codex into a full development workflow, from picking up a Jira ticket to opening a pull request. Clone this repo, run the installer, and open your actual project repos. Everything installs globally on your machine and works everywhere.

### Why use this?

- **One simple entry point.** In Claude Code, type `/start`; in Codex, describe the goal. Both use the same toolbox contract and quality gates; Codex's durable GoalRun path additionally needs a configured provider wrapper. You don't manage agents or configure anything after setup for ordinary tasks.
- **25 specialist agents review your code automatically.** Security scanning, database review, accessibility checks, screenshot-based UI review, performance benchmarks — triggered by what files you change, not by you remembering to run them.
- **Consistent quality across the team.** Same coding standards, same TDD enforcement, same review gates — regardless of who's prompting. Junior devs get senior-level quality gates for free.
- **Connected to your tools.** Jira tickets move through columns automatically. Seq logs are queried during incidents. GitHub PRs are created with linked tickets, and GitHub Actions pipelines are reviewed via local YAML parsing. No copy-pasting between tools. *(Jira is optional — `/build`, `/bug`, `/hotfix` work without tickets.)*
- **Tracks work across sessions.** Hit a rate limit or close your laptop — the agent picks up exactly where it left off via the durable GoalRun state and `.claude/handover.md`. Claude and Codex can continue the same bounded run when the other provider is unavailable.
- **Advises when the next change is unclear.** Ask what should be fixed or improved; the planner performs a read-only evidence pass, ranks proposals, checks for duplicate Jira/Beads work, and creates a detailed Jira item only after approval.

---

## Table of Contents

- [Getting Started](#getting-started)
- [What You Need to Know](#what-you-need-to-know)
- [Commands](#commands)
  - [Full command reference](docs/how-to/commands.md)
  - [Command comparison — what each command does and doesn't do](docs/how-to/command-comparison.md)
  - [Durable Goal Runs](docs/how-to/goal-runs.md)
- [Workflow Modes](#workflow-modes--board-driven-agent-first-hybrid)
  - [Full examples and Jira integration](docs/how-to/jira-integration.md)
- [Provider usage limits](#provider-usage-limits)
  - [Token management and provider fallback](docs/how-to/token-management.md)
- [Scripts](#scripts)
  - [Update workflow](docs/how-to/update.md)
- [Troubleshooting](#troubleshooting)
- [Reference](#reference)
  - [What Gets Installed](#what-gets-installed)
  - [Agents](#agents) · [Full agent list](docs/reference/agent-list.md)
  - [MCP Connections](#mcp-connections) (Model Context Protocol — connects AI to external tools) · [Full MCP reference](docs/concepts/mcp.md)
  - [Built From](#built-from)
  - [Repo Structure](#repo-structure)
  - [All docs index](#reference-docs)

---

## Getting Started

Four steps: install a provider, authenticate it, install the toolbox, and start working. The workflow is provider-neutral; the entry command depends on whether you use Claude Code or Codex.

### Step 0 — Install Node.js (if you don't have it)

- Mac: `brew install node`
- Windows: `winget install OpenJS.NodeJS`
- Linux: `sudo apt install nodejs npm`

Node.js and npm are used to install the provider CLIs and the toolbox dependencies. If your provider is already installed, keep the existing installation and continue.

### Step 1 — Install and authenticate one provider

Choose the provider you want to use. You can install and authenticate both; they share the same toolbox state and workflow.

**Claude Code**

```bash
npm install -g @anthropic-ai/claude-code
claude login
```

When prompted, select **Claude.ai Subscription** for the company Team/Enterprise account. Do not select Anthropic Console or Bedrock/Foundry/Vertex unless you intentionally use direct API billing.

**Codex CLI**

```bash
npm install -g @openai/codex@latest
codex login
codex login status
```

The last command is a read-only check that confirms the Codex login. If Codex is already installed, the toolbox installer only refreshes it when you opt in.

### Step 2 — Install the toolbox

Clone the toolbox **outside** your project directories (e.g. a shared tools folder), then run the installer:

```bash
mkdir -p ~/tools
cd ~/tools  # or any non-project directory
git clone https://github.com/baselito/ai-toolbox.git
cd ai-engineering
./scripts/install.sh
```

> **Why outside your project?** The installer copies everything to `~/.claude/` (machine-global). If you clone inside a project repo, you'll have a nested git repo that could accidentally get committed. The clone location doesn't affect what gets installed — it works from anywhere.

The installer:

1. Copies agents, skills, commands, rules, and hooks to `~/.claude/` (machine-global)
2. Merges hooks config into `~/.claude/settings.json` — hooks are active immediately
3. Installs the ECC plugin and Beads (task tracking)
4. Merges MCP configs into `~/.claude.json`
5. Runs a health check

The default command keeps the optional local Codex reviewer choice neutral. In an interactive terminal, answer the Codex question when prompted. For an explicit choice, use `INSTALL_CODEX=1 ./scripts/install.sh` to enable Codex or `INSTALL_CODEX=0 ./scripts/install.sh` to disable the optional reviewer. The installer is safe to re-run after a toolbox update.

If you chose Codex in Step 1, use the explicit enablement command so a fresh Codex home receives the shared toolbox:

```bash
INSTALL_CODEX=1 ./scripts/install.sh
```

If you chose Claude Code only, use `INSTALL_CODEX=0 ./scripts/install.sh` for a deterministic no-Codex install. The bare command remains interactive and may accept Codex if you answer yes.

**Hooks are global.** Hook scripts and their configuration are installed into `~/.claude/` by `install.sh` — they're active in every project immediately after install. No extra setup needed. Per-project overrides are possible via `.claude/settings.json` in individual repos. When `~/.codex/` exists, the same managed hook roster is refreshed into `~/.codex/hooks/` and `~/.codex/hooks.json`; this is independent of the optional Codex reviewer. A provider ownership manifest records which hooks the toolbox may remove; if it is missing or empty, refresh and uninstall preserve existing Codex hooks and registrations because ownership cannot be proven safely. Config symlinks are followed only within the Codex config directory.

### Step 3 — Open your provider and start

Both providers work from a project directory. Pick the matching entry path:

| Provider | How to start |
|---|---|
| Claude Code | `cd ~/your-project && claude` → type `/start` |
| Codex CLI | `cd ~/your-project && codex` → describe the goal, for example: `Start the next Jira ticket and follow the toolbox workflow.` |

Claude Code's slash commands are shortcuts for the shared workflow. Codex uses the same installed skills and can use the durable GoalRun runtime when `GOAL_LOOP_CODEX_COMMAND` is configured; state the same intent in plain language for ordinary tasks.

For a durable Codex GoalRun, configure the host wrapper as a JSON argv list, for example `GOAL_LOOP_CODEX_COMMAND='["codex-goal-wrapper","--json-io"]'`. The wrapper contract is documented in [Goal Runs](docs/how-to/goal-runs.md). If no wrapper is configured, the agent reports that capability as unavailable instead of pretending the run is durable.

### The common goal loop

The toolbox keeps work small and recoverable:

`goal → plan → act → verify → checkpoint → repeat`

In simple terms: define the outcome, make a plan, take one bounded action, check the result, save a short progress checkpoint, and repeat until the acceptance criteria are met. If a provider or command fails, diagnose it and resume from the last verified checkpoint.

#### What to expect the first time

When you start in a new project for the first time, the agent won't find a `PROJECT.md` file — that's normal. It will tell you:

```
👋 First time on this project!

No PROJECT.md found — this project hasn't been configured yet.
The agent will auto-detect your stack and methodology, then ask
a few quick setup questions (Jira, CI/CD, tracking).

This only happens once. After setup, `/start` goes straight to the menu in Claude Code; Codex can continue by stating the next goal.
```

Setup takes about 2 minutes. The agent auto-detects your stack and methodology from the codebase, then asks a few questions about Jira, CI/CD, and task tracking. Your answers are saved to `.claude/PROJECT.md` (per project) and `~/.claude/memory.md` (personal defaults reused across all future projects).

**After the first time:** `/start` skips setup entirely and goes straight to the menu where you pick a ticket or choose a command. Codex can start the same work from a short natural-language goal.

#### Other ways to start

**Don't have a Jira ticket?** Type `/build` instead — same quality gates, no ticket needed.

**Want to see all commands?** Type `/commands` inside any session for a quick reference with examples.

**Have a question or found an issue?** Type `/ask` — the agent reads the docs and answers your question. If it finds something wrong, it offers to create a fix branch in the toolbox repo for you to review.

---

## What You Need to Know

Before diving into the docs, here's what matters on day one:

**You just start with one goal every morning.** In Claude Code, type `/start`; in Codex, describe what you want done. The agent reads your Jira board and routes you to the right workflow. You don't pick agents, manage skills, or configure anything after the first setup.

**25 agents work automatically** — 20 shipped by this repo plus 5 from the ECC plugin. A `chief-of-staff` agent (a decision-maker subagent that picks which specialists to activate — not the orchestrator itself) selects agents based on what files you change. Touch a `.razor` file? The accessibility auditor and `evidence-collector` (screenshot-based visual QA) activate. Touch a migration? The database reviewer runs. You never call agents directly — they're triggered behind the scenes.

**Beads = AI memory across sessions.** Beads tracks what the agent did, what changed, and what's left. If you hit a rate limit and come back later, or switch tools, the agent picks up exactly where it left off. You don't interact with Beads directly — it runs in the background.

**Your project repos stay clean.** The toolbox adds only `.claude/PROJECT.md` (your project config) and other explicitly configured local state. Hooks, agents, skills, commands, and rules live on your machine at `~/.claude/` or the Codex skill directory.

**The agent never fails silently.** If something goes wrong — Jira is down, the board is empty, tests fail, you reject a proposal — the agent tells you what happened and offers alternatives. It won't leave you stuck. See [Edge Case Handling](rules/edge-cases.md) for the general rules; the full per-scenario playbooks load on demand via the `edge-cases` skill.

When Codex is installed, its provider surface lives under `~/.codex/` alongside
the Claude surface under `~/.claude/`. Both are refreshed from the same toolbox
source; Claude-only slash commands and CronCreate remain host-specific.

**This works with any tech stack.** Node, Python, .NET, Go, Java — all workflows and quality gates apply universally. Some skills are specific to the sample application stack (toolbox's property management platform — Blazor, MassTransit, EF migrations) but they only activate when the agent detects those patterns. They automatically skip in other repos.

**Want to go deeper?** [Beads](docs/concepts/beads.md) · [Agents](docs/concepts/agents.md) · [MCP connections](docs/concepts/mcp.md) · [Skills](docs/concepts/skills.md)

---

## Commands

**99% of the time, use the default entry point.** In Claude Code, type `/start` and press Enter. In Codex, describe the goal in plain language. The agent reads your Jira board and picks the right workflow for you.

### Claude Code command menu

The menu and direct commands below are Claude Code slash-command shortcuts. They are optional: Codex users can describe the same intent in a prompt, and both providers use the same skills, guardrails, verification contract, and GoalRun state.

```
/start ── [Enter] ── Pick up next Jira ticket
  │                    └── Agent reads ticket type:
  │                          Story/Feature/Task → /flow
  │                          Bug               → /bug
  │                          Hotfix/Urgent      → /hotfix
  │                          Incident/P1        → /incident
  │                          Review/PR Review   → /review
  │                          Refactor/Tech Debt → /refactor
  │                          Security           → /security
  │                          Performance        → /perf
  │                          No ticket          → /build
  │
  ├── [1] Pick up a specific ticket → same routing as above
  ├── [2] Bug                       → /bug
  ├── [3] Urgent fix                → /hotfix
  ├── [4] Production is down        → /incident
  ├── [5] Review existing code      → /review
  ├── [6] Clean up / refactor       → /refactor
  ├── [7] Security scan             → /security
  ├── [8] Performance investigation → /perf
  ├── [9] Report feedback            → /feedback
  └── [10] Make a presentation       → /presentation
```

### Direct commands — optional shortcuts

```
/flow           ← I have a Jira ticket, build it
/build          ← No ticket, just build something
/bug            ← Something is broken, investigate + fix
/hotfix         ← Urgent, needs to ship today
/incident       ← Production is down right now
/review         ← Review code without changing anything
/review-pr      ← Auto-respond to PR comments
/goal           ← Durable goal state: status, iterate, pause, resume, cancel
/ask            ← Ask questions or discover evidence-backed improvements
/refactor       ← Cleanup only, no new features
/security       ← OWASP security scan
/perf           ← Something is slow
/presentation   ← Create or edit a PowerPoint deck
```

### What's included in each path

| Step | `/start` | Direct command (e.g. `/bug`) |
|---|---|---|
| Project setup (`/init`) | ✅ Auto — runs if not configured | ✅ Auto — runs if not configured |
| Menu + ticket routing | ✅ Shows menu, reads Jira ticket | ❌ Skipped — you already chose |
| Jira ticket reading | ✅ Reads ticket and routes by type | ⚠️ Asks you to describe or paste a ticket |
| Confirmation summary | ✅ Shown before work starts | ✅ Shown before work starts |
| Beads tracking | ✅ Creates beads if enabled | ✅ Creates beads if enabled |
| Jira status moves | ✅ Moves tickets if Jira configured | ✅ Moves tickets if Jira configured |
| Agents + quality gates | ✅ All agents run based on files changed | ✅ All agents run based on files changed |

**Bottom line:** Direct commands skip the Claude Code menu — everything else is identical. Use them only when you already know which workflow you want.

### Utility commands

| Command | When to use |
|---|---|
| `/commands` | Quick list of all commands with examples — without leaving the terminal |
| `/ask` | Ask any question about the toolbox, or report an issue — can diagnose and create a fix branch for you |
| `/init` | Change project config (stack, Jira, methodology, MCPs) after first setup |
| `/continue` | Resume work after switching tools or a session break |

Each command triggers a multi-agent workflow — not just a single action. For example, `/flow` orchestrates architect → tdd-guide → code-reviewer → reality-checker and more. See [Commands Reference](docs/how-to/commands.md) for full workflows.

### `/flow` Phases and Jira Column Mapping

The main workflow (`/flow`) moves a ticket through 8 phases. After each phase, the agent presents a summary with its opinion and waits for the user to approve before continuing.

| Jira column | # | Phase | What the agent does |
|---|---|---|---|
| **Discovery** | 1 | Discovery | Reads ticket, explores codebase, identifies affected files and risks |
| **Ready for Dev** | 2 | Ticket Assessment | Determines if code is needed, identifies scope |
| **Ready for Dev** | 3 | Brainstorming | Explores approaches, discusses trade-offs with user |
| **Ready for Dev** | 4 | Planning | Creates implementation plan with exact files and phases |
| **Ready for Dev** | 4.5 | Streamlined-plus Scope Expansion *(conditional)* | When Brainstorming or Planning was skipped, runs a 30-second `rg`/`grep` on the change's axis (variable, env key, flag, enum) to surface latent cross-file callsites. Orchestrator inline — no agent. |
| **In Progress** | 5 | Implementation | Creates branch, writes tests, writes code. Can close its own fix-and-re-run cycle with a `/goal` exit condition |
| **In Progress** | 6 | Code Review | Runs code-reviewer agent, grades the code |
| **In Progress** | 7 | Verification | Maps every acceptance criterion to a named test, re-runs the new tests, reality checker. Reuses phase 5's full-suite result rather than re-running it |
| **In Progress** | 8 | PR Creation | Pushes branch, creates PR (after user approves) |
| **In Progress** | — | **Agent stops** | Offers to pick next ticket |
| **Testing** | — | Human step | PR approved, merged to Stage, manual testing on portal |
| **Done** | — | Human step | Manual testing passed |

Phases 5 and 7 have an exit condition a machine can check, so each can set a session-scoped `/goal` — a condition re-evaluated after every turn — and iterate on its own until the project's gates come back green. **That removes the babysitting inside a phase, not a single gate between phases:** every phase summary and every approval prompt above is unchanged, and when `/goal` is unavailable (hooks disabled, or a runtime without it) the phase simply runs attended as before.

### Workflow Guardrails

These rules are enforced globally across all workflows through **structural hooks** (20 PreToolUse/PostToolUse hooks), not just documented guidelines. The orchestrator (main Claude Code agent) cannot decide what's needed or self-verify — designated agents and skills make decisions at each phase, and an **independent compliance audit subagent** verifies the entire workflow before PR creation.

**The core principle: no agent verifies its own work.** The same rule that applies to code review (chief-of-staff selects independent reviewers) now applies to every verification step: PR creation (enforced skill), Jira writes (Haiku jira-workflow-steward), compliance auditing (independent subagent). See [Independence Principle](docs/concepts/independence-principle.md) for the full separation-of-duties model.

| Rule | What it prevents |
|---|---|
| **Sequential column transitions** | Tickets must move through every Jira column in order (Backlog → Discovery → Ready for Dev → In Progress). Never skip columns. First action on any ticket: read the ticket (read-only), investigate, present findings at the Investigation Gate. Only after user approval: assign + move to Discovery. |
| **Phase summaries with agent opinion** | After every phase, the agent presents what was done, gives its honest opinion (concerns/suggestions), and proceeds — the card is a window, not a gate. It stops to ask only when the phase is BLOCKED or hit a category question (`rules/autonomy.md`); interrupt any time to revise or stop. |
| **Brainstorming is mandatory** | Only the user can skip brainstorming — the agent cannot decide a ticket is "trivial". |
| **Never commit to main** | All code goes through feature branch + PR. The agent never offers "commit to main" as an option. |
| **Never auto-create PR** | The agent must ask the user before pushing or creating a PR — even if all tests pass. |
| **Agent stops at PR creation** | Testing (Stage deploy) and Done (manual testing) are human steps. The agent only moves tickets past In Progress if the user explicitly asks AND the PR is verified as merged. |
| **Mandatory /start → /flow handoff** | After `/start` confirms a ticket, it MUST hand off to `/flow`. The agent cannot skip `/flow` and start coding directly. |
| **docs-before-commit** | Every commit must verify documentation is up to date. Commit message ends with `Docs: updated [files]` or `Docs: verified — no updates needed`. |
| **test-what-you-write** | After writing any CLI command or integration code, run it to verify it works before committing. |
| **Columns from actual board** | The Columns field MUST show columns read from the actual Jira board via the column discovery script. Never hardcode or guess column names. |
| **Jira comments stay concise** | Post one short Start, PR/milestone, and Completion update; add a short Blocker only for a human decision or visible ticket impact. Keep phase, review, polling, retry, install, and test details in the handover, PR, or tool logs. |
| **Beads continuity** | Before creating a Beads issue, check if one already exists for this ticket (`bd ready`). Continue existing issues, never create duplicates. Handles next-day resumption and session interruptions. |
| **Model routing per phase** | Each phase must use the correct model and designated skill/agent. Fable orchestrates the session, Opus for deep-reasoning subagents (planning, architecture, threat modelling, reviewer selection), Opus for execution/review too, Haiku for Jira/commits. Verify at every phase handover. | <!-- tier-ok: enumerates the whole routing table — Fable/Opus/Haiku each correctly attached to their own scope -->

### Jira Integration (acli)

Jira operations use the [Atlassian CLI (acli)](https://developer.atlassian.com/cloud/acli/) — not an MCP. This gives:

- **API token auth** — no OAuth expiry, no stale mcp-remote processes
- **No result caps** — `--paginate` fetches all tickets (MCP was limited to 100)
- **0 MCP tools** — reduces context window pressure
- **Background fetch** — tickets load during `/start` setup, ready instantly when needed

Setup: `install.sh` handles installation across Mac, Linux, and Windows. Then `/init` guides through authentication. Credentials are global — only the project key is per-project.

### Beads Integration

[Beads](https://github.com/steveyegge/beads) tracks AI tasks across sessions. `/init` runs `bd init` when Beads is selected. All commands auto-initialize `.beads/` if missing — no user prompt needed.

---

## Workflow Modes — Board-Driven, Agent-First, Hybrid

During `/init`, the agent asks: **"How do tickets get into Jira?"** Your answer sets the workflow mode.

| | Board-driven | Agent-first | Hybrid |
|---|---|---|---|
| **Who creates tickets** | Your team / PM | The agent | Team creates epics/stories, agent creates sub-tasks |
| **Best for** | Teams with a PM | Solo devs or small teams | Teams where PM owns the board |
| **Default in `/start`** | Pick up next ticket | Describe what to build | Pick up next epic/story |
| **Jira required** | Yes | Optional (beads-only works) | Yes |

**Board-driven:** Your PM puts tickets on the board. You run `/start`, press Enter, the agent picks up the next ticket and runs `/flow`.

**Agent-first:** You describe what to build. The agent asks scoping questions, proposes a work breakdown (epic → stories → tasks), you approve, and it creates beads + Jira tickets automatically.

**Hybrid:** Your PM creates epics/stories. The agent reads them, proposes sub-tasks, you approve, and it creates sub-task beads + Jira sub-tasks.

**How to read the work breakdown:**

The agent organises work into three levels:

| Level | What it means | Example |
|---|---|---|
| **Epic** | The overall goal — what you're building | "Bulk tenant invite system" |
| **Story** | A user-visible slice — works on its own | "Invite endpoint (API)" |
| **Task** | A developer-sized piece — one focused coding session | "Request/response models" |

The agent builds each task one at a time using `/flow` (design → code → test → review → PR). You approve or skip each task as it completes.

Change the mode anytime: run `/init` and change Q3. See [Workflow Modes](docs/how-to/jira-integration.md#workflow-modes--board-driven-agent-first-hybrid) for full examples.

---

## Provider usage limits

Claude and Codex are supported execution providers for the same durable GoalRun. When one provider reports an explicit usage limit or is unavailable, the run can continue with the other provider while preserving leases, evidence, Jira identities, and the action journal. Unknown outcomes remain pending until reconciled. See [Token management](docs/how-to/token-management.md).

PR polling is provider-neutral as well. Claude records its CronCreate id and
Codex records its desktop heartbeat through `register-pr-poll.sh`; both use
`${AI_ENGINEERING_STATE_DIR:-${CLAUDE_STATE_DIR:-$HOME/.claude}}` so a pending
PR cannot be stranded in one provider's state directory.

---

## Scripts

| Script | When to run | What it does |
|---|---|---|
| `install.sh` | Once per machine | Copies shared agents/skills/runtime, refreshes Claude and Codex provider surfaces when available, merges their hook configs, merges MCP configs, and installs ECC/Beads. |
| `uninstall.sh` | Before switching to another toolbox (e.g. ECC) | Removes all toolbox files from `~/.claude/` — hooks, agents, skills, commands, rules, MCP entries. Leaves Claude Code itself and system tools (acli, gh) untouched. Prompts before doing anything. |
| `update.sh` | When upstream repos have updates | Creates a review branch with upstream changes. You review, merge, then re-run `install.sh`. |
| `verify.sh` | After install/update, or when something feels off | Health check — confirms everything is installed correctly. |
| `loop-progress-signature.sh` | Called by a loop or a `/goal` phase, once per iteration | The no-progress guard. Compares a normalised failure signature (sorted failing gate names + top error identifier) against the previous iteration and exits 3 when it has not changed for `no_progress_after` iterations. Deliberately NOT keyed on file mtimes — a loop rewriting the same failing file looks healthy to an mtime detector forever. See the [`loop-design` skill](skills/loop-design/SKILL.md). |

See [Updating](docs/how-to/update.md) for the full update workflow.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `claude: command not found` | Run `npm install -g @anthropic-ai/claude-code` |
| `install.sh: permission denied` | Run `chmod +x scripts/install.sh` then retry |
| `/start` says "not configured" | Run `/init` manually to set up this project |
| MCP connection failing | Check `~/.claude.json` for correct URLs and API keys |
| Jira was working but stopped | API token may have expired — regenerate at id.atlassian.com and update `ATLASSIAN_API_TOKEN` in your shell profile. |
| Agent not activating | Run `./scripts/verify.sh` to check installed agents |
| Beads not tracking | Confirm Beads plugin: `/plugin list` inside Claude Code |
| Too many MCP tools | Run `/mcp` to check count — keep under 60, never exceed 80 |
| Windows paths wrong | Ensure `%APPDATA%\Claude\` exists — installer should create it |

See [Troubleshooting Reference](docs/reference/troubleshooting.md) for more details.

---

## Reference

Everything below is reference material. You don't need to read it to get started — it's here for when you want to understand how the toolbox works under the hood.

### What Gets Installed

| Component | Count | Source breakdown | Details |
|---|---|---|---|
| Agents | 25 total (20 in repo + 5 ECC) | 8 from Agency Agents + 5 from this repo + 7 vendored from ECC (Opus review tier) + 5 still from ECC plugin | [Agent list](docs/reference/agent-list.md) |
| Skills | 48 total (30 in repo + 18 ECC) | 7 from Superpowers + 23 from this repo + 18 from ECC plugin | [Skill list](docs/reference/skill-list.md) |
| Commands | 20 | All from this repo | [Commands reference](docs/how-to/commands.md) |
| Rules | 15 | 7 ECC-based (customized) + 8 custom | [Rules concept](docs/concepts/rules.md) |
| Hooks | 20 PreToolUse/PostToolUse + 1 standalone | All from this repo (`hooks/`) — installed globally via `~/.claude/settings.json` | [Independence principle](docs/concepts/independence-principle.md) |
| MCP connections | 2 | Seq, Context7 (Jira uses acli CLI, GitHub uses gh CLI — neither is MCP) | [MCP concept](docs/concepts/mcp.md) |
| Beads | CLI + plugin | Beads | [Beads concept](docs/concepts/beads.md) |

> **Note:** The ECC agents and skills are not stored in this repo — they are installed via the ECC plugin during `install.sh`. The counts above reflect what's available after installation. Only the custom agents and skills (from this repo, Superpowers, and Agency Agents) are versioned here.

#### sample application Portal Skills

sample application is toolbox's property management platform. Five custom skills activate only when the agent detects sample application-specific patterns. They automatically skip in other repos.

| Skill | Activates when | What it does |
|---|---|---|
| **microservice-patterns** | ASP.NET Core service projects | Public ASP.NET Core patterns, validation, authorization, and existing-project conventions |
| **blazor-radzen** | `.razor` files touched | Blazor WASM + Radzen: modular RCL, code-behind, bUnit + Playwright, Azure AD B2C |
| **ef-migration-management** | Migration or DbContext files | Migration chain guidance for 50-329 migrations, shared DB impact checks, squashing |
| **event-driven-messaging** | Consumer/subscriber/event files | MassTransit pub/sub patterns across 6 repos, consumer idempotency, legacy sync |
| **monolith-decomposition** | Working in sample-monolith | Maintenance-first: safe optimizations vs risky changes, shared DB rules |

### Agents

25 agents handle different parts of the workflow — 20 from this repo, 5 from the ECC plugin. The `chief-of-staff` decides which run per task — you never manage them directly.

> **Rule counts may change.** Agents and the 5 superpowers skills are LOCAL-OWNED toolbox rewrites — `update.sh` never touches them. Only ECC rules are synced (diff-gated); run `update.sh` to check for new upstream rules.

#### Leadership (Opus — deep reasoning)

| Agent | Source | What it does |
|---|---|---|
| `chief-of-staff` | This repo | Decides which agents to run, builds execution plans |
| `architect` | ECC | System design — evaluates patterns, proposes structures, identifies risks |
| `planner` | ECC | Step-by-step implementation plans with file paths and dependencies |
| `security-engineer` | Agency | Security architecture — IAM, zero-trust, OAuth/RBAC, threat modelling |

#### Execution and review (Opus — raised from Sonnet, July 2026)

| Agent | Source | What it does |
|---|---|---|
| `tdd-guide` | ECC | Enforces RED-GREEN-REFACTOR — no task done without passing tests |
| `code-reviewer` | ECC | Code quality review — A-F grading, issues, suggestions |
| `security-reviewer` | ECC | Vulnerability scanning — secrets, permissions, injection risks |
| `database-reviewer` | ECC | DB queries, schema, migrations, N+1, index usage |
| `api-tester` | Agency | API endpoint validation — contracts, payloads, errors, performance |
| `accessibility-auditor` | This repo | WCAG 2.2 AA — keyboard nav, screen reader, contrast |
| `performance-benchmarker` | This repo | Before/after benchmarks — p50/p95/p99, Core Web Vitals |
| `devops-automator` | Agency | CI/CD pipeline review — GitHub Actions |
| `incident-response-commander` | Agency | Full incident protocol — triage, Seq logs, post-mortem |
| `reality-checker` | Agency | Production readiness gate — always last, signs off or blocks |
| `project-manager-senior` | Agency | Business requirements to tasks with estimates |
| `e2e-runner` | ECC | End-to-end tests using Playwright |
| `refactor-cleaner` | ECC | Dead code and legacy patterns without new features |
| `build-error-resolver` | ECC | Reads build errors, applies known fix patterns |

#### Retrieval and support (Sonnet for lookup/capture, Haiku for mechanical)

| Agent | Source | What it does |
|---|---|---|
| `harness-optimizer` | ECC | Monitors agent performance and context window |
| `loop-operator` | ECC | Stabilises long-running agent loops |
| `evidence-collector` | Agency | Screenshot-based visual QA for Blazor/Radzen/React |
| `docs-lookup` | This repo | Live library docs via Context7 MCP |
| `doc-updater` | ECC | Keeps docs in sync after code changes |
| `jira-workflow-steward` | Agency | Branch naming, Jira status transitions, PR links |

#### How agents are triggered

Not every agent runs on every task. The `chief-of-staff` selects based on files changed:

| Files changed | Agents triggered |
|---|---|
| Any code | `tdd-guide` + `code-reviewer` + `reality-checker` (always) |
| `*.razor`, `*.blazor`, `*.tsx`, `*.jsx`, `*.html` | + `evidence-collector` + `accessibility-auditor` |
| `*Migration*`, `*DbContext*` | + `database-reviewer` |
| `*Controller*`, `*Endpoint*` | + `api-tester` + `security-reviewer` |
| `appsettings*`, `*auth*`, secrets | + `security-engineer` + `security-reviewer` |
| `*Pipeline*`, `*.yml` | + `devops-automator` |
| `/perf` workflow or performance tests | + `performance-benchmarker` |
| Major architecture change | + `architect` + `planner` |
| Any Jira-linked task | + `jira-workflow-steward` |
| Library/framework questions | `docs-lookup` (on demand) |

See [Agent List](docs/reference/agent-list.md) for full details and [Model Assignments](docs/reference/model-assignments.md) for the Fable/Opus/Sonnet/Haiku breakdown.

> **Source key:** ECC = [Everything Claude Code](https://github.com/affaan-m/everything-claude-code) plugin, Agency = [Agency Agents](https://github.com/msitarzewski/agency-agents), This repo = custom agents.

### MCP Connections

| Connection | What it does | Why it matters |
|---|---|---|
| **Jira (acli)** | Read/update Jira tickets via Atlassian CLI | Agent reads acceptance criteria before coding, moves tickets through the board. CLI with API token auth — not an MCP. |
| **GitHub (gh CLI)** | PRs, issues, code search, branches | Entire PR workflow without leaving the terminal. CLI — not an MCP. |
| **Seq** | Live structured log queries (PII sanitized) | `/incident`, `/bug`, `/perf` query production logs directly. See [Seq Setup](#seq-setup) below. MCP server. |
| **Context7** | Up-to-date library/framework docs | `docs-lookup` fetches current API signatures instead of stale training data. MCP server. |

> **Beads** uses the Claude Code plugin, not MCP. See [Beads](docs/concepts/beads.md).

See [MCP Connections](docs/concepts/mcp.md) for setup details and per-project activation.

### Seq Setup

Seq integration is optional and is not installed by default. This repository does
not ship a log server or assume access to a private service. Without one, use
local log files or sanitized exports; `/build` and the other workflows still work.

To enable live queries, deploy an MCP server you control, configure read-only
access to your Seq instance, and verify its redaction policy. Sanitization is a
property of your chosen server, not a guarantee provided by this toolbox.
Use `mcp-configs/seq.json` as a connection example: replace the URL with your
server's actual endpoint and supply `SEQ_MCP_API_KEY` through your host's secret
configuration. Add that entry to the MCP configuration of the active provider;
check which tools the server exposes before running any query. The documented
`seq_*` names are an optional adapter contract, not tools bundled in this repo.
See [optional integrations](docs/how-to/optional-integrations.md) for details.

### Built From

This toolbox combines open-source agentic coding projects with our own orchestration layer:

- **[Everything Claude Code (ECC)](https://github.com/affaan-m/everything-claude-code)** — Full plugin: 12 agents, 18 skills, rules, hooks. Code review, TDD, refactoring, documentation, build error resolution. (`chief-of-staff` used to be an ECC agent — it's vendored into this repo now, see `agents/chief-of-staff.md`, after upstream repurposed theirs into a comms-triage agent.)
- **[Superpowers](https://github.com/obra/superpowers)** (v5.0.7) — 7 skills: brainstorming (with visual companion), systematic debugging (with companion docs), git worktrees, verification-before-completion, branch finishing, test-driven-development (RED-GREEN-REFACTOR), receiving-code-review. Plus 23 custom skills we built (including advisory-discovery, work-breakdown, code-review-orchestration, discovery, respond-to-pr-reviews, codex-review, workflow-discipline, pr-automation, edge-cases, cross-tool-sync, agent-orchestration, subagent-liveness, observed-work, handover-protocol, flow-reference, loop-design, mutation-testing, presentation-master, and 5 sample application-specific skills).
- **[Agency Agents](https://github.com/msitarzewski/agency-agents)** — 8 agents: security, DevOps, incident response, API testing, Jira. Plus 4 custom agents we built.
- **[Beads](https://github.com/steveyegge/beads)** — AI task tracking across sessions via Claude Code plugin.
- **This repo** — 20 slash commands, MCP configs, install/update scripts, 46 docs. The orchestration glue.

### Repo Structure

```
ai-engineering/
├── agents/                          → 20 agents: 8 Agency + 5 custom + 7 vendored from ECC (+ 5 more from ECC after install)
├── skills/                          → 30 skills (+ 18 more added from ECC after install; shared with Codex when enabled)
├── commands/                        → 20 slash commands
├── rules/                           → ECC rules + custom rules
├── mcp-configs/                     → MCP server configurations
├── scripts/                         → install.sh, uninstall.sh, update.sh, verify.sh (+ loop-progress-signature.sh, consume-deviations.sh and sync/test utility scripts)
├── docs/                            → 46 documentation files
├── examples/                        → PROJECT.md.example, handover.md.example, settings.json.example (reference hooks template), loop.md.example
├── knowledge/                       → learned-lessons knowledge file (toolbox-lessons.yml), human-gated, synced to ~/.claude by sync-toolbox-lessons.sh
├── .github/                         → GitHub metadata and repository workflows
├── CLAUDE.md                        → Agent instructions for this repo
└── README.md                        → This file
```

> After install, `~/.claude/` also contains agents, skills, hooks, and rules from the ECC plugin. See [Agent List](docs/reference/agent-list.md) and [Skill List](docs/reference/skill-list.md) for the complete set.

### Reference Docs

All detailed documentation lives in `docs/`. Start with [Getting Started](docs/getting-started.md).

#### Concepts

| Doc | What it covers |
|---|---|
| [Agents](docs/concepts/agents.md) | How agents work, orchestration, handover |
| [Skills](docs/concepts/skills.md) | What skills are, the 7 Superpowers skills |
| [MCP](docs/concepts/mcp.md) | MCP connections, tool counts, per-project activation |
| [Beads](docs/concepts/beads.md) | AI task tracking across sessions |
| [Rules](docs/concepts/rules.md) | Always-active rules, what they enforce |
| [Claude Code](docs/concepts/claude-code.md) | What Claude Code provides as the primary tool |
| [ECC](docs/concepts/ecc.md) | Everything Claude Code plugin — foundation layer |
| [Git Worktrees](docs/concepts/git-worktrees.md) | Parallel task execution with isolated branches |
| [OWASP](docs/concepts/owasp.md) | OWASP security scanning methodology |
| [TDD](docs/concepts/tdd.md) | Test-driven development enforcement |

#### How-To Guides

| Doc | What it covers |
|---|---|
| [Commands](docs/how-to/commands.md) | Full command reference with workflows |
| [Command Comparison](docs/how-to/command-comparison.md) | Side-by-side: what each command does and doesn't do |
| [Agent Handover](docs/how-to/agent-handover.md) | How agents pass context to each other |
| [Confirmation Summary](docs/how-to/confirmation-summary.md) | The 12-14 field confirmation before work starts (varies by workflow mode) |
| [Project Config](docs/how-to/project-config.md) | PROJECT.md, memory.md, per-project vs global |
| [Jira Integration](docs/how-to/jira-integration.md) | Jira workflow, board-driven vs agent-first |
| [Security Workflows](docs/how-to/security-workflows.md) | OWASP scans, security levels, threat modelling |
| [Incident Response](docs/how-to/incident-response.md) | Production down workflow, Seq, post-mortem |
| [Git Worktrees](docs/how-to/git-worktrees.md) | Parallel task execution with worktrees |
| [Updating](docs/how-to/update.md) | Weekly check, update.sh, PR review process |
| [Testing](docs/how-to/testing.md) | How tests are generated, run, and reviewed |
| [Token Management](docs/how-to/token-management.md) | Claude/Codex provider fallback and usage-limit handling |
| [Contributing](docs/how-to/contributing.md) | How to add commands, agents, or skills |

#### Reference

| Doc | What it covers |
|---|---|
| [Agent List](docs/reference/agent-list.md) | All agents with model assignments |
| [Skill List](docs/reference/skill-list.md) | All skills with descriptions |
| [MCP List](docs/reference/mcp-list.md) | All MCP servers with connection details |
| [Rules List](docs/reference/rules-list.md) | All rules with full contents |
| [Model Assignments](docs/reference/model-assignments.md) | Fable / Opus / Sonnet / Haiku breakdown |
| [External Commands](docs/reference/external-commands.md) | All ECC and Beads plugin commands — what to use, what to ignore |
| [Troubleshooting](docs/reference/troubleshooting.md) | Extended troubleshooting guide |

#### Reference Repos

| Repo | What we use |
|---|---|
| [affaan-m/everything-claude-code](https://github.com/affaan-m/everything-claude-code) | Full plugin + rules |
| [obra/superpowers](https://github.com/obra/superpowers) | 7 skills |
| [msitarzewski/agency-agents](https://github.com/msitarzewski/agency-agents) | 8 agents |
| [steveyegge/beads](https://github.com/steveyegge/beads) | AI task tracking plugin |
