# Troubleshooting

Common issues and how to fix them. Run `./scripts/verify.sh` first — it identifies most problems and gives fix instructions.

**Scope:** this is the remediation *flow* — start here, run `verify.sh`, then work through the issue-specific fixes below in order. For a symptom/failure lookup table instead (searchable by error message), see [Troubleshooting Reference](../reference/troubleshooting.md).

---

## When to Read This

- Something is not working as expected
- verify.sh reported errors
- An MCP connection is failing
- The agent is behaving unexpectedly

---

## First Step — Always

```bash
cd ai-engineering
./scripts/verify.sh
```

This checks all components and tells you exactly what is broken and how to fix it.

---

## Common Issues

### Jira (acli) not connecting

**Cause:** API token expired or environment variables not set.

**Fix:** Regenerate your API token at [id.atlassian.com/manage-profile/security/api-tokens](https://id.atlassian.com/manage-profile/security/api-tokens) and update your shell profile:
```bash
export ATLASSIAN_EMAIL="your-email@example.com"
export ATLASSIAN_API_TOKEN="your-new-token"
export ATLASSIAN_URL="https://your-domain.atlassian.net"
```
Then restart your terminal or run `source ~/.zshrc`.

### Jira Server connection failing

**Cause:** Personal Access Tokens or API access may be disabled on the server.

**Fix:** Ask your Jira admin to confirm that PATs and API access are enabled.

### Seq MCP not connecting

**Cause:** API key expired or misconfigured.

**Fix:** Check your Seq instance → Settings → API Keys → create a new key if expired. Run `/init` to update.

### Agent not found

**Cause:** Agent files missing from `~/.claude/agents/`.

**Fix:** Run `ls ~/.claude/agents/` to check. If missing, re-run `./scripts/install.sh`.

### Commands not working

**Cause:** Command files missing from `~/.claude/commands/`.

**Fix:** Run `ls ~/.claude/commands/` to check. If missing, re-run `./scripts/install.sh`.

### Tool count over 60

**Cause:** Too many MCPs active for this project.

**Fix:** Run `/mcp` to see active tools. Add unused MCPs to `disabledMcpServers` in `.claude/settings.json`:

```json
{
  "disabledMcpServers": ["seq"]
}
```

### /init not saving PROJECT.md

**Cause:** Write permission issue on the `.claude/` folder.

**Fix:** Check permissions: `ls -la .claude/`. Create the directory if missing: `mkdir -p .claude`.

### Context window shrinking noticeably

**Cause:** Too many MCP tools consuming context.

**Fix:** Check tool count with `/mcp`. Disable unused MCPs per project via `settings.json`.

### Agent loses context between sessions

**Cause:** Beads MCP not active.

**Fix:** Run `claude mcp list` to check. If Beads is not listed, re-run `./scripts/install.sh`.

### ECC plugin not found after install

**Cause:** Plugin installation did not complete.

**Fix:** Run both commands:
```bash
claude plugin marketplace add affaan-m/everything-claude-code
claude plugin install everything-claude-code@everything-claude-code
```

---

## verify.sh Output Guide

| Output | Meaning |
|---|---|
| All green checkmarks | Everything is healthy |
| Red X on agents | Agent files missing — re-run install.sh |
| Red X on skills | Skill directories missing — re-run install.sh |
| Red X on commands | Command files missing — re-run install.sh |
| Red X on rules | Rule files missing — re-run install.sh |
| Red X on ECC plugin | Plugin not installed — run plugin commands |
| Red X on Beads | Beads not installed — follow Beads install steps |
| Red X on MCP config | ~/.claude.json missing — re-run install.sh |
| Red X saying a test suite **EXCEEDED ITS BOUND** | The suite did not finish and was killed — this is NOT a failing assertion. It means a wait somewhere lost its bound, which is the exact regression the observe.sh suite exists to catch. Re-run the named suite with an external deadline (`timeout 1800 bash scripts/test-observe.sh` on Linux, or `gtimeout 1800 bash scripts/test-observe.sh` on macOS with coreutils installed) and inspect the last diagnostics; never run the suite without an outer bound. |
| Yellow warning on upstream | ai-engineering itself has unpulled commits on `origin/main` — `git pull` in the ai-engineering repo, then re-run `install.sh` (this is about THIS repo's own origin, not the ECC/Superpowers upstreams — `update.sh` is the separate tool for those) |

---

## Getting Help

If verify.sh passes but something still is not working:

1. Check the specific command documentation in `commands/`
2. Check the relevant concept doc in `docs/concepts/`
3. Ask in the team Slack channel
4. File an issue on the ai-engineering repo
