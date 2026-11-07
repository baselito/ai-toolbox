# Beads — AI Task Tracking

What Beads is, why it exists alongside Jira, and how to use it.

---

## When to Read This

- You want to understand what Beads does
- You are wondering why both Jira and Beads exist
- You need to query Beads for task status
- Beads is not working and you need to troubleshoot

---

## What Is Beads?

Beads is a structured task database for AI agents. It stores tasks locally in an embedded dolt database (`.beads/embeddeddolt/`) so the agent can query work state across multiple sessions without losing context.

**Default configuration:** Beads is configured for local-only mode by `/init` — data lives on your machine, no remote sync, no backup warnings. If you need cross-machine sync (team sharing or switching between laptops), enable JSONL backup or a dolt remote manually via `.beads/config.yaml`.

---

## Why It Exists

Without Beads, the agent loses all context when a session ends. It does not know what was done yesterday, what is blocked, or where it left off.

With Beads, the agent knows exactly what was done in previous sessions and picks up where it left off — even on multi-day tasks.

---

## Beads as a Planning Layer

Beads is not just for tracking completed work. In agent-first and hybrid modes, beads are created during the planning phase — before any code is written.

When the `work-breakdown` skill decomposes work into an epic → story → task hierarchy, it creates a bead for each task immediately. This means:

- **The agent has a structured task list even without Jira.** Solo devs using beads-only tracking get the same structured planning that Jira teams get.
- **Jira sync is layered on top.** Beads are created first (always works, no MCP needed). Jira tickets are created second (optional, requires acli CLI). If Jira is down or not configured, the beads still exist.
- **Beads survive across sessions on the same machine.** The beads database is local — any Claude Code session on the same machine can read it. For cross-machine continuity, enable JSONL backup in `.beads/config.yaml`.

This makes beads the single source of truth for the agent across all three workflow modes:

| Mode | Beads role |
|---|---|
| Board-driven | Tracking only — created when work starts |
| Agent-first | Planning + tracking — created during `work-breakdown`, before any code |
| Hybrid | Planning + tracking — sub-task beads created during `work-breakdown` |

---

## Beads vs Jira

They serve different audiences:

| | Beads | Jira |
|---|---|---|
| **Audience** | The agent | Your team |
| **Purpose** | Internal AI tracking across sessions | Team visibility and project management |
| **Data** | Structured JSONL — task state, context, dependencies | Human-readable tickets and boards |
| **Persistence** | Checked into git | Cloud-hosted |

You can use both (recommended), Jira only, or Beads only. Configured during `/init`.

---

## Installation

Beads is installed automatically by `./scripts/install.sh`.

For reference, manual installation:

**Mac:**
```bash
brew install beads
```

**Linux:**
```bash
curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash
```
Or with Go: `go install github.com/steveyegge/beads/cmd/bd@latest`

**Windows (requires Go):**
```bash
go install -tags gms_pure_go github.com/steveyegge/beads/cmd/bd@latest
```

Then install the Beads plugin in Claude Code:
```
/plugin marketplace add steveyegge/beads
/plugin install beads@beads-marketplace
```

> **Note:** The Beads CLI + plugin is the recommended integration for Claude Code. The `beads-mcp` server exists for MCP-only environments (like Claude Desktop) and is not needed here — using the plugin saves significant tokens.

See [Beads installation docs](https://github.com/steveyegge/beads/blob/main/docs/INSTALLING.md) for all platform options.

---

## How the Agent Uses Beads

The agent automatically:
- Creates a Beads issue when starting a task (linked to Jira ticket if available)
- Updates the issue as work progresses
- Closes the issue when the task is complete
- Files post-mortems after `/incident` resolution
- Tracks sprint velocity data during `/flow` (on Scrum boards)

---

## Querying Beads

You can query Beads directly:

```bash
beads list --status in-progress
beads list --status blocked
beads show bd-123
```

Or in plain English to the agent:
- "Give me a status report of all active Beads issues"
- "What was I working on yesterday?"
- "Show me all blocked tasks"

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Agent loses context between sessions | Confirm Beads plugin is active — `/plugin list` in Claude Code |
| Beads not tracking tasks | Check if tracking is set to "Beads" or "Jira + Beads" in PROJECT.md |
| Beads database error | Run `beads init` to reinitialise |
