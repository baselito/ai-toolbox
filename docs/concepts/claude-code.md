# Claude Code

What Claude Code is, how it works, and how this toolbox extends it.

---

## When to Read This

- You are new to Claude Code and want to understand the basics
- You want to understand the difference between Claude Code CLI and the IDE extension
- You want to understand how this toolbox builds on top of Claude Code

---

## What Is Claude Code?

Claude Code is an AI coding assistant built by Anthropic. It runs as a CLI tool in any terminal — standalone, or inside the terminal pane of any IDE (VS Code, Cursor, Zed, etc.). Claude Desktop wraps the same CLI in a native app.

The agent reads your code, understands your project, and can write code, run commands, create PRs, and interact with external services through MCP connections.

---

## How This Toolbox Extends It

Out of the box, Claude Code is a general-purpose coding assistant. This toolbox adds:

- **20 slash commands** — structured workflows for every type of development work
- **25 specialised agents** — each with a defined role, model assignment, and orchestration rules
- **48 skills** — methodologies and patterns the agent follows (TDD, brainstorming, debugging, code-review-orchestration, discovery, advisory discovery, mutation testing, and presentation support) — 30 in this repo (23 custom + 7 from Superpowers) + 18 from ECC
- **15 always-active rules** — agents, autonomy, coding-style, communication, cross-tool-sync, development-workflow, docs-before-commit, edge-cases, feedback-detection, git-workflow, handover, performance, security, testing, workflow-discipline (see `rules/`)
- **2 MCP connections** — Seq, Context7 (Jira uses acli CLI, GitHub uses gh CLI — neither is MCP)
- **Agent orchestration** — the chief-of-staff decides which agents run per task

The result is a fully orchestrated development workflow where the agent handles design, implementation, testing, code review, and PR creation — pulling you in only for approvals and decisions.

---

## Key Concepts

### Slash Commands
Type `/command` to trigger a workflow. Example: `/flow` runs the full Kanban ticket workflow.

### Agents — four roles

- **Orchestrator** — the main Claude Code agent (Fable, per `~/.claude/settings.json`). Persistent for the whole session. Coordinates phases, writes `.claude/handover.md`, spawns subagents. Does NOT write feature code inline — spawns Opus subagents for that.
- **Chief-of-staff** (Opus, ephemeral) — decision-maker subagent. Spawned twice per `/flow`: once to pick per-phase agents (Step 1.8), once to pick reviewers (Step 9). Returns a plan, dies.
- **Implementing subagent** (Opus, ephemeral) — writes feature code in Phase 5.
- **Review agents** (Opus mostly, ephemeral) — code-reviewer, reality-checker, security-reviewer, etc. Read the diff, return findings.

See `docs/concepts/agents.md` for the full architecture.

### Skills
Methodologies and patterns. Some are active (brainstorming asks you questions), some are passive (coding-standards is always in effect).

### Rules
Always-active constraints. Security, testing, coding style — the baseline every agent operates within.

### MCP Connections
External service integrations. Jira, GitHub, Seq, Beads.

---

## CLI — works the same everywhere

Claude Code is always the same CLI. What changes is where you type it:

| Where you open it | Feels like |
|---|---|
| Standalone terminal | Pure terminal session — fastest to launch |
| VS Code / Cursor / Zed / any IDE's terminal pane | Terminal inside your editor — diffs open inline in the editor |
| Claude Desktop | Native app window with the CLI experience built in |

The toolbox is identical in all of them — the commands, agents, and workflows don't change based on where Claude runs.
