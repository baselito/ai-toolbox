# MCP — Model Context Protocol

What MCPs are, what each one enables, and how to manage tool counts.

---

## When to Read This

- You want to understand what MCPs do and why they matter
- You are configuring MCPs for a new project
- You are troubleshooting an MCP connection
- You want to add a custom MCP

---

## What Is an MCP?

MCPs (Model Context Protocol) connect the agent to external tools and services. Without them, the agent can only read and write files on your machine. With MCPs, the agent can:

- Read and update Jira tickets
- Create pull requests on GitHub
- Query live logs in Seq
- Track tasks across sessions with Beads
- Trigger and monitor CI/CD pipelines

Each MCP server exposes multiple **tools** — individual capabilities the agent can use. For example, the Seq MCP exposes tools for querying production logs, getting level summaries, and grouping errors.

---

## Installed MCPs

| MCP | ~Tools | Purpose | Default |
|---|---|---|---|
| **Seq** | ~5 | Live log queries for incidents, bugs, perf | Yes (if Seq selected) |
| **Context7** | ~2 | Library and framework documentation lookup | Always active |

> **GitHub** uses the `gh` CLI, not an MCP server. It adds 0 MCP tools. PRs, issues, code search, branches — all via terminal.
>
> **Jira** uses the Atlassian CLI (`acli`), not an MCP server. It adds 0 MCP tools. See [Jira Integration](../how-to/jira-integration.md) for setup.
>
> **Beads** uses the Claude Code plugin (not MCP) for task tracking across sessions. The plugin uses ~1-2k tokens per call vs ~10-50k for the MCP approach. See [Beads](beads.md) for details.

---

## Tool Count Limits

The agent's performance degrades when too many tools are active. Limits:

- **Under 60 tools** — comfortable, recommended
- **60-80 tools** — acceptable, monitor for slowdowns
- **Over 80 tools** — disable MCPs until back under 60

Check your current tool count: `/mcp`

**Approximate counts by configuration:**

Jira via acli and GitHub via gh CLI add 0 MCP tools (CLI-based, not MCP servers).

| Setup | ~Tools | Status |
|---|---|---|
| Seq + Context7 | ~7 | Default — minimal footprint |
| Context7 only | ~2 | Minimal footprint |

---

## Per-Project Activation

MCPs are installed globally by `install.sh` but activated per project based on `/init` answers.

Controlled by `.claude/settings.json` in each project:

```json
{
  "disabledMcpServers": ["seq"]
}
```

(The example above disables Seq — useful for projects that don't use Seq for logging. Adjust to the MCP you want to disable.)

---

## Adding a Custom MCP

During `/init`, select `[A]` on the MCP Summary Screen. The agent asks for:

1. MCP name
2. Install command or URL
3. Environment variables needed

The agent walks through setup and saves to `PROJECT.md` and `~/.claude.json`.

This covers any tool not in the default list — PagerDuty, Sentry, Linear, Notion, and others. Always check tool count with `/mcp` before adding.

---

## What Breaks Without Each MCP

| Tool | What breaks if disabled |
|---|---|
| Jira (acli) | No Jira ticket reading/updating, must manage tickets manually |
| GitHub | No PR creation, no issue management, no code search — significant limitation |
| Seq | No live log queries during /incident, /bug, /perf — falls back to local logs only |
| Context7 | `docs-lookup` agent falls back to training data (may be outdated) — no live documentation queries |

> **Jira (acli)** is a CLI tool, not an MCP. If acli is not installed or API token is missing, the agent falls back to beads-only tracking.
>
> **Beads** is a plugin, not an MCP. If the Beads CLI or plugin is missing, the agent loses context between sessions.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Jira (acli) not working | API token expired — regenerate at id.atlassian.com and update `ATLASSIAN_API_TOKEN` in your shell profile |
| Seq MCP not connecting | Check API key at your Seq instance → Settings → API Keys |
| Tool count over 60 | Run `/mcp`, add `disabledMcpServers` to `.claude/settings.json` |
| Context window shrinking | Check tool count with `/mcp`, disable unused MCPs |

See `docs/how-to/troubleshooting.md` for more.
