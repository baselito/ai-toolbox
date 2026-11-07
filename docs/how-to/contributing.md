# Contributing

How to add or update commands, agents, and skills in this repo.

---

## When to Read This

- You want to add a new command
- You want to modify an existing agent or skill
- You want to understand the repo conventions

---

## General Rules

1. **Never invent model assignments** — use the model specified in CLAUDE.md for each agent
2. **Use "the agent" throughout** — never "Claude" or "Claude Code" except as a product name
3. **Cross-reference both source documents** — README.md for human-readable descriptions, CLAUDE.md for technical detail
4. **Run verify.sh after changes** — confirms nothing is broken
5. **Do not add components that conflict with the existing stack** — check for overlaps with ECC, Superpowers, and Agency agents

---

## Adding a New Command

1. Create a new `.md` file in `commands/`
2. Follow the format of existing commands:
   - Title and description
   - Trigger section (when it runs)
   - Prerequisites
   - Step-by-step workflow
   - Agent and skill usage table with model assignments
   - Notes
3. Include the confirmation summary step
4. Reference correct agents, skills, and models
5. Include conditional logic where applicable
6. Update `docs/how-to/commands.md` with the new command
7. Update `scripts/verify.sh` to check for the new command file

---

## Modifying an Agent

Agent files live in `agents/`. Each has frontmatter with a `model:` field.

1. Edit the agent file in `agents/`
2. **Do not change the model assignment** unless explicitly approved
3. Test that the agent still works in its associated commands
4. Update `docs/reference/agent-list.md` if the description changed
5. Run verify.sh

---

## Modifying a Skill

Skill files live in `skills/` as directories (each skill is a directory with files inside).

1. Edit the skill files in `skills/[skill-name]/`
2. Test that the skill works in its associated commands
3. Update `docs/reference/skill-list.md` if the description changed
4. Run verify.sh

---

## Modifying a Rule

Rule files live in `rules/`. These are always active in every session.

1. Edit the rule file in `rules/`
2. Be careful — rules affect all agents in all commands
3. Update `docs/reference/rules-list.md` if the description changed
4. Run verify.sh

---

## Adding an MCP Config

MCP configs live in `mcp-configs/`.

1. Create a new `.json` file for the MCP
2. Add the MCP to `mcp-configs/mcp-servers.json` (master config)
3. Update `scripts/install.sh` if the MCP needs special installation steps
4. Update `docs/reference/mcp-list.md` with the new MCP
5. Update `docs/concepts/mcp.md` with tool count impact
6. Run verify.sh

---

## Branch and PR Process

1. Create a feature branch: `feature/add-[component-name]`
2. Make your changes
3. Run `./scripts/verify.sh` to confirm everything passes
4. Push and create a PR
5. Get review from repository maintainers (write access)
6. Merge after approval

---

## Repo Access

- **All toolbox teams** — read access
- **repository maintainers** — write access
