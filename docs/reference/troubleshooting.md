# Troubleshooting

Common problems and solutions for the AI Engineering toolbox.

**Scope:** this is the symptom/failure reference — a lookup table organized by problem area (install, MCP, tool count, agent activation), for when you already know roughly what's wrong. For the step-by-step remediation flow that starts with `verify.sh`, see [Troubleshooting How-To](../how-to/troubleshooting.md).

---

## When to Read This

- Something is not working after install or update
- An agent is not activating when expected
- MCP connections are failing
- You ran `verify.sh` and it reported errors

---

## Install Failures

| Problem | Solution |
|---|---|
| `install.sh: permission denied` | Run `chmod +x scripts/install.sh` then retry |
| `claude: command not found` | Install Claude Code CLI: `npm install -g @anthropic-ai/claude-code` |
| `npm: command not found` | Install Node.js first — Mac: `brew install node`, Windows: `winget install OpenJS.NodeJS` |
| `brew: command not found` (Mac) | Install Homebrew: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` |
| Install completes but verify.sh fails | Re-run `./scripts/install.sh` — some components may have been skipped due to network issues |
| Windows paths not found | Ensure `%APPDATA%\Claude\` exists — the installer should create it automatically |

---

## MCP Connection Issues

| Problem | Solution |
|---|---|
| MCP server not connecting | Check `~/.claude.json` for correct URLs and API keys |
| Seq queries returning nothing | Confirm Seq URL and API key in `~/.claude.json`. Test the URL in a browser first |
| Jira tickets not loading | API token may have expired. Regenerate at [id.atlassian.com](https://id.atlassian.com/manage-profile/security/api-tokens) and update `ATLASSIAN_API_TOKEN` in your shell profile (`~/.zshrc` or `~/.bashrc`). Restart your terminal or run `source ~/.zshrc`. |
| GitHub CLI (`gh`) failing | Run `gh auth status` to confirm GitHub CLI is authenticated. If expired, run `gh auth login` to re-authenticate. |
| MCP working in one project but not another | Check `.claude/settings.json` in the failing project — the MCP may be in `disabledMcpServers` |

---

## Tool Count Exceeding Limits

| Problem | Solution |
|---|---|
| Too many tools warning | Run `/mcp` to check the current count. Recommended: under 60, acceptable: 60-80, never exceed 80 |
| Over 80 tools | Disable MCPs not needed for this project in `.claude/settings.json` — add to `disabledMcpServers` array |
| Tool count keeps growing | New MCP servers may have been added. Review `~/.claude.json` for servers you did not install |

---

## Agent Not Activating

| Problem | Solution |
|---|---|
| Agent not running when expected | Check conditional activation rules — agents only run when relevant files are changed. See [Agents Concept](../concepts/agents.md) |
| Agent file not found | Run `./scripts/verify.sh` to confirm all agents are installed in `~/.claude/agents/` |
| Agent running on wrong model | Check the `model:` field in the agent's frontmatter. Model assignments should not be changed manually |
| `chief-of-staff` not orchestrating | Ensure the command you are running supports multi-agent orchestration (most do except `/init`) |
| `reality-checker` not running | It only runs as the last agent — check that preceding agents completed successfully |

---

## verify.sh Failures

| Problem | Solution |
|---|---|
| Missing agents | Re-run `./scripts/install.sh`. If specific agents are missing, copy them manually from `agents/` to `~/.claude/agents/` |
| Missing skills | Re-run install. Skills should be in `~/.claude/skills/`. Check that the skill directories (not just files) were copied |
| Missing rules | Re-run install. Rules should be in `~/.claude/rules/` |
| MCP config mismatch | Compare `~/.claude.json` with `mcp-configs/mcp-servers.json`. Re-run install to merge |
| Beads not found | Install Beads manually — Mac/Linux: `brew install beads`. Then install the plugin: `/plugin marketplace add steveyegge/beads` |
| ECC plugin not installed | Run `/plugin install everything-claude-code` inside Claude Code |
| `consume-deviations.sh ... DIFFERS from the repo copy` | Expected while you are editing that script, and it is an ERROR on purpose: `/review-pr` executes the INSTALLED copy, so while the two differ the self-improvement loop running on your machine is not the code in your checkout. Re-run `./scripts/install.sh`, then re-run verify. |

---

## update.sh Conflicts

`update.sh` copies only NEW upstream ECC rules we have no local copy of. The 7 existing ECC-origin rules, all Superpowers skills, and all Agency Agents files are LOCAL-OWNED (complete toolbox rewrites) and are never fetched or copied — upstream divergence on them is only reported for manual review. See the "LOCAL-OWNED Files" section in [Updating](../how-to/update.md) for the full manifest and rationale. It creates a review branch — never auto-applies.

| Problem | Solution |
|---|---|
| `update.sh` fails with dirty working tree | Commit or stash your changes first — update.sh requires a clean working tree |
| Agent files overwritten after update | This should not happen — all 8 Agency Agents files are LOCAL-OWNED and update.sh never fetches or copies them. If it does, restore from git history and file a bug |
| Merge conflicts in rule files | Resolve manually — keep our customisations, accept upstream additions that don't conflict |
| Custom commands or skills overwritten | This should not happen — update.sh never touches `commands/`, custom agents, custom skills, or the 5 LOCAL-OWNED Superpowers skills. If it does, restore from git history |
| Update branch already exists | Delete the old branch: `git branch -d update/ecc-YYYY-MM-DD` and re-run |

---

## Beads Issues

| Problem | Solution |
|---|---|
| Agent loses context between sessions | Confirm Beads plugin is active: `/plugin list` inside Claude Code |
| Beads not tracking tasks | Check PROJECT.md — tracking must be set to "Beads" or "Jira + Beads" |
| Beads database error | Run `beads init` to reinitialise the local database |
| Beads commands not found | Ensure the Beads CLI is on your PATH. Mac: check `brew list beads` |

---

## Related Docs

- [Getting Started](../getting-started.md) — installation walkthrough
- [Project Configuration](../how-to/project-config.md) — config file locations
- [MCP Connections](../concepts/mcp.md) — MCP setup and tool counts
- [Updating](../how-to/update.md) — update process and PR review
