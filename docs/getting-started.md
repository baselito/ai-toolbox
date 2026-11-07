# Getting Started

Full setup walkthrough for new developers joining the team. Claude Code and Codex use the same toolbox and guardrails; Codex's durable goal workflow additionally requires a configured provider adapter.

---

## When to Read This

- You are setting up your machine for the first time
- A new team member is onboarding
- You want the long-form version of the README's Getting Started

---

## Prerequisites

### Common prerequisites

1. **Install Node.js**
   - Mac: `brew install node`
   - Windows: `winget install OpenJS.NodeJS`
   - Linux: `sudo apt install nodejs npm`

2. **Install a package manager** (if not already installed)
   - Mac: [Homebrew](https://brew.sh) — `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`
   - Windows: winget is built in
   - Linux: apt/dnf/pacman are built in

Node.js and npm are needed for the provider CLIs and toolbox installer. If your provider is already installed, keep it and continue.

### Choose a provider

Install and authenticate Claude Code, Codex CLI, or both.

**Claude Code**

```bash
npm install -g @anthropic-ai/claude-code
claude login
```

Select **Claude.ai Subscription** when prompted if you use the company Team/Enterprise account.

**Codex CLI**

```bash
npm install -g @openai/codex@latest
codex login
codex login status
```

The final command is a read-only login check.

### Install the toolbox

Clone the toolbox outside your project directories, then run:

```bash
mkdir -p ~/tools
cd ~/tools
git clone https://github.com/baselito/ai-toolbox.git
cd ai-engineering
./scripts/install.sh
```

The default command keeps the optional Codex reviewer choice neutral. Use `INSTALL_CODEX=1 ./scripts/install.sh` to enable Codex explicitly or `INSTALL_CODEX=0 ./scripts/install.sh` to disable the optional reviewer. The installer is safe to re-run after a toolbox update.

If you chose Codex above, use the explicit enablement command so a fresh Codex home receives the shared toolbox:

```bash
INSTALL_CODEX=1 ./scripts/install.sh
```

If you chose Claude Code only, use `INSTALL_CODEX=0 ./scripts/install.sh` for a deterministic no-Codex install. The bare command remains interactive and may accept Codex if you answer yes.

### Start working

In Claude Code, open a project and type `/start`:

```bash
cd ~/your-project && claude
```

In Codex, open the same project and state the goal:

```bash
cd ~/your-project && codex
```

For example: `Start the next Jira ticket and follow the toolbox workflow.`
Claude's slash commands are shortcuts; Codex uses the same installed skills and can use the durable GoalRun runtime when `GOAL_LOOP_CODEX_COMMAND` is configured. The common loop is:

`goal → plan → act → verify → checkpoint → repeat`

The agent defines the outcome, takes one bounded action, checks it, saves a short checkpoint, and continues from the last verified result after a recoverable failure. For the Codex wrapper contract, see [Goal Runs](how-to/goal-runs.md); for provider switching, see [Token Management](how-to/token-management.md).

The Codex CLI can handle ordinary goal prompts after login. A durable GoalRun additionally needs a team-provided JSON wrapper, configured as `GOAL_LOOP_CODEX_COMMAND='["codex-goal-wrapper","--json-io"]'`. If that wrapper is unavailable, the agent reports the durable capability as unavailable rather than treating an ordinary prompt as resumable state.

---

## What the installer does

The installer:
1. Detects your OS (Mac, Windows, Linux)
2. Ensures package manager and Node.js are installed
3. Installs the ECC plugin
4. Copies agents, skills, commands, and rules to `~/.claude/`
5. Installs Beads for AI task tracking
6. Configures MCP connections in `~/.claude.json`
7. Creates `~/.claude/memory.md` template
8. Runs a verification check
9. Prints "Ready — type /start" for Claude Code

With `INSTALL_CODEX=1`, it also installs or refreshes the optional Codex reviewer and shared Codex skills, hook registration, and provider-neutral runtime files. The installer does not create a team-specific JSON provider wrapper; configure `GOAL_LOOP_CODEX_COMMAND` separately when durable Codex GoalRuns are needed. If a Codex home already exists, shared Codex surfaces may also be refreshed when the reviewer is disabled; `INSTALL_CODEX=0` disables the optional reviewer, not every existing Codex file.

---

## Optional — Seq Log Queries

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
See [optional integrations](how-to/optional-integrations.md) for details.

---

## After Setup — Leave This Folder

The `ai-engineering` folder is a **toolbox, not a project**. Once `install.sh` finishes, you are done here. Claude files are copied to `~/.claude/`; shared Codex files are copied to the Codex home when Codex is enabled or already present.

**Do not open `ai-engineering` as your working project.** Navigate to your actual project repo instead.

You only come back to `ai-engineering` to:
- Run `./scripts/update.sh` — pulls and diffs ECC rules for new or improved standards. Superpowers skills and Agency Agents files are LOCAL-OWNED toolbox rewrites and are never fetched. Creates a branch with the changes for you to review. Never auto-applies.
- Run `./scripts/verify.sh` — health check that confirms all agents, skills, commands, rules, MCPs, and plugins are installed correctly.
- Modify commands, agents, or skills in the toolbox itself

---

## Opening an Existing Project

If you already have a project repo cloned on your machine:

**Claude Code (standalone or IDE terminal pane):**
```bash
cd ~/your-repos/your-existing-project
claude
/start
```

**Codex CLI:**

```bash
cd ~/your-repos/your-existing-project
codex
# State the goal, for example: Start the next Jira ticket and follow the toolbox workflow.
```

Since this is your first time using the toolbox in this project, the agent runs `/init` automatically. It auto-detects your stack and methodology from the codebase, then walks you through a few setup questions:

**Auto-detected (no questions asked):**
- Stack (from `.sln`, `.csproj`, `package.json`, and known patterns)
- Methodology (from Jira board type — Kanban or Scrum)
- Security sensitivity, logging, project type, team size (detected at runtime)

**Questions asked:**
1. Jira (Cloud / Server / None)
2. CI/CD (GitHub Actions / Other / None)
3. Jira workflow direction (Board-driven / Agent-first / Hybrid) — only if Jira configured
4. Task tracking (Jira + Beads / Jira only / Beads only) — only if Jira configured

Your answers are saved to two places:
- **Personal defaults** → `~/.claude/memory.md` (reused across all projects)
- **Project config** → `.claude/PROJECT.md` (specific to this project)

The first project asks all 5 questions. Every project after that shows a pre-filled summary — just press Enter to confirm, or edit what is different.

### Start Working

After configuration, Claude Code shows a menu:

```
What do you want to work on?
-> [ENTER] Pick up next Jira ticket
```

Press Enter to pick up the next ticket, or select a specific type of work. In Codex, state the equivalent goal in plain language. The agent handles the configured workflow from there.

---

## Starting a New Project

If you are creating a brand new repo:

```bash
mkdir ~/your-repos/new-project
cd ~/your-repos/new-project
git init
claude
/start
```

With Codex, run `codex` in the new repository and state the same goal instead of using `/start`.

The agent runs `/init` and configures the project. Select **Project type: Greenfield** during setup — this tells the agent to use the `architect` (Opus) and `blueprint` skill for initial system design before writing code.

---

## Switching Between Projects

Each project gets its own `.claude/PROJECT.md`. When you switch projects, open the new folder and run `/start` in Claude Code or `codex` and state the goal in Codex — the agent reads the correct config automatically. No re-configuration needed.

```bash
cd ~/your-repos/other-project
claude
/start
```

Codex equivalent: `cd ~/your-repos/other-project && codex`, then state the goal.

The agent picks up that project's config automatically — no re-configuration.

---

## Working on Legacy Repos

The toolbox works on any repo. For legacy codebases, select **Project type: Legacy refactor / modernisation** during `/init`. This tells the agent to analyse the codebase structure first (the `refactor-cleaner` agent, using the `workflow-discovery` skill) before touching any code.

---

## Verifying Your Installation

Run the health check at any time:

```bash
cd ai-engineering
./scripts/verify.sh
```

It checks all agents, skills, commands, rules, plugins, MCPs, and Beads. Silent when everything is healthy.

---

## Next Steps

- Read `docs/how-to/commands.md` for a full command reference
- Read `docs/concepts/mcp.md` to understand MCP connections
- Read `docs/concepts/agents.md` to understand how agents work together
