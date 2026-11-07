# MCP List — Full Reference

All 2 default MCPs with purpose, tool count, setup instructions, and per-project activation. Jira uses acli (CLI) and GitHub uses `gh` CLI — neither is an MCP server.

---

## Jira via Atlassian CLI (acli) -- NOT an MCP

- **Source:** Atlassian CLI (`acli`) — installed locally
- **Tools:** 0 (CLI-based, not an MCP server — adds no MCP tools)
- **Purpose:** Read/write Jira tickets, move through columns, add comments
- **Active by default:** Yes (if Jira configured during `/init`)
- **What breaks without it:** No Jira ticket reading/updating, must manage tickets manually
- **Setup:** Configured during `/init` Q1 (Jira). Requires API token auth (no OAuth).
- **Used in:** `/flow`, `/bug`, `/hotfix`, `/incident`, `/refactor`, `/security`, `/perf`
- **Fallback:** If Jira stops working, regenerate your API token at id.atlassian.com and update `ATLASSIAN_API_TOKEN` in your shell profile. Or paste ticket details manually / continue with beads-only tracking.

### Jira Cloud Authentication
- API token auth via environment variables — no OAuth, no browser popups
- Generate a token at [id.atlassian.com/manage-profile/security/api-tokens](https://id.atlassian.com/manage-profile/security/api-tokens)
- Set `ATLASSIAN_EMAIL`, `ATLASSIAN_API_TOKEN`, and `ATLASSIAN_URL` in your shell profile

### Jira Server / Data Center Authentication
- Personal Access Token (PAT)
- Ask your Jira admin to confirm PATs and API access are enabled

### Why not an MCP?
The Atlassian Rovo MCP added 15-20 tools to the MCP tool count and required OAuth via mcp-remote (which caused frequent token expiry issues and stale proxy processes). acli provides the same Jira functionality with 0 MCP tools and simpler API token auth. Confluence access was dropped — open Confluence pages in your browser if needed.

---

## GitHub via CLI (`gh`) — NOT an MCP

- **Source:** GitHub CLI (`gh`) — installed locally
- **Tools:** 0 (CLI-based, not an MCP server — adds no MCP tools)
- **Purpose:** Create PRs, read issues, search code, manage branches
- **Active by default:** Always (if `gh` is installed and authenticated)
- **What breaks without it:** No PR creation, no issue management, no code search
- **Setup:** Install `gh` CLI, then authenticate with `gh auth login`.
- **Used in:** All commands that create PRs or interact with GitHub

### Why not an MCP?
The GitHub MCP added ~15-20 tools to the MCP tool count. The `gh` CLI provides the same functionality with 0 MCP tools and more reliable authentication. Same reasoning as the Jira/acli migration.

### GitHub Authentication Setup

1. **Install GitHub CLI**
   ```bash
   brew install gh        # macOS
   sudo apt install gh    # Linux (Debian/Ubuntu)
   winget install gh      # Windows
   ```

2. **Authenticate**
   ```bash
   gh auth login
   ```
   Follow the prompts to authenticate via browser or token.

3. **SSO-enabled organizations**
   - After authenticating, refresh SSO for each org:
   ```bash
   gh auth refresh -s read:org
   ```

4. **Verify the setup**
   ```bash
   gh auth status
   ```
   Confirm the output shows your account and the expected scopes.

---

## Seq

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
See [optional integrations](../how-to/optional-integrations.md) for details.

---

## Beads

- **Source:** `steveyegge/beads`
- **Integration:** Claude Code plugin (not MCP)
- **Purpose:** Track AI task state across sessions, file post-mortems, track sprint velocity
- **Active by default:** Always
- **What breaks without it:** Agent loses context between sessions — does not know what was done yesterday or what is blocked
- **Setup:** `install.sh` installs the Beads CLI + Claude Code plugin. No MCP server needed.
- **Used in:** All commands that track work across sessions

> **Why plugin instead of MCP?** The Beads CLI + plugin uses ~1-2k tokens per call. The `beads-mcp` server uses ~10-50k tokens for MCP schemas. For Claude Code, the plugin is the recommended integration.

### Manual Install (reference)

**CLI:** See [Beads installation docs](https://github.com/steveyegge/beads/blob/main/docs/INSTALLING.md) for all platforms.

**Plugin:**
```
/plugin marketplace add steveyegge/beads
/plugin install beads@beads-marketplace
```

---

## Tool Count Summary

Jira via acli and GitHub via `gh` CLI add 0 MCP tools. Previous counts included ~15-20 Atlassian Rovo MCP tools and ~15-20 GitHub MCP tools — both are now removed.

| Setup | ~Tools | Status |
|---|---|---|
| Seq + Context7 | ~7 | Default — minimal footprint |
| Context7 only | ~2 | Minimal footprint |

---

## Per-Project Activation

See [Per-Project Activation](../concepts/mcp.md#per-project-activation) for how to enable or disable MCPs per project using `.claude/settings.json`.

---

## Adding a Custom MCP

During `/init`, select `[A]` on the MCP Summary Screen. The agent walks through:
1. MCP name
2. Install command or URL
3. Environment variables

Always check tool count with `/mcp` before adding. If adding pushes over 60, the agent suggests which MCPs to disable.

Custom MCPs cover: PagerDuty, Sentry, Linear, Notion, Datadog, and any other tool with an MCP server available.
