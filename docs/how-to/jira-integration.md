# Jira Integration

How Jira connects to the toolbox — ticket routing, status transitions, board management, and Beads pairing.

---

## When to Read This

- You want to understand how the agent interacts with Jira
- You are setting up Jira for the first time with `/init`
- Jira status transitions are not working as expected
- You want to understand how Beads and Jira work together

---

## Jira Access via Atlassian CLI (acli)

Jira access is provided by the Atlassian CLI (`acli`), a command-line tool that runs locally. It enables:

- **Reading tickets** — summary, description, acceptance criteria, priority, assignee
- **Status transitions** — moving tickets through workflow columns
- **Adding comments** — progress updates, PR links, blockers

### Concise Jira Updates

Use one short Start update, one PR/milestone update, and one Completion update. Add a short
Blocker only when a human decision or visible ticket impact requires it. Internal phase summaries,
reviewer activity, polling, retries, installation, and test output stay in the handover, PR, or
tool logs. Board transitions still follow the live phase map.

Confluence access is not available via acli. If you need Confluence docs, open them in your browser.

The CLI is configured during install. It adds 0 MCP tools — all Jira operations go through shell commands.

### Authentication

acli uses API token authentication. No OAuth, no browser popups, no mcp-remote proxy.

1. Go to [id.atlassian.com/manage-profile/security/api-tokens](https://id.atlassian.com/manage-profile/security/api-tokens)
2. Create an API token (label it `claude-code` or similar)
3. Set environment variables in your shell profile (`~/.zshrc` or `~/.bashrc`):
   ```bash
   export ATLASSIAN_EMAIL="your-email@example.com"
   export ATLASSIAN_API_TOKEN="your-token-here"
   export ATLASSIAN_URL="https://your-domain.atlassian.net"
   ```

**If Jira stops working:** Regenerate your API token at id.atlassian.com and update `ATLASSIAN_API_TOKEN` in your shell profile. Restart your terminal or run `source ~/.zshrc`.

---

## The jira-workflow-steward Agent

The `jira-workflow-steward` agent (Haiku) enforces discipline throughout every Jira-connected workflow:

- **Branch naming** — creates branches matching the ticket key (e.g. `feature/PROJ-101-login-page`)
- **Status transitions** — translates phase keys (e.g. `phase=in_progress`) into board-specific column moves via the `jira_phase_map` in PROJECT.md (set during `/init`, validated at `/flow` Step 0). See `docs/concepts/jira-phase-map.md`.
- **Ticket creation** — applies the canonical Ticket Description Template (Background, Scope, Acceptance Criteria) passed via `--description-file`, with the ticket Summary provided separately via `--summary`. Runs a pre-create self-check: Summary and Acceptance Criteria are mandatory; Background and Scope are included when they add value. See `agents/jira-workflow-steward.md` → Ticket Description Template.
- **Comments** — posts only explicitly requested milestone or blocker updates, such as a short
  Start or PR link
- **Traceability** — ensures every commit references a ticket key

This agent runs on Haiku for speed and low cost — it activates on every command that involves a Jira ticket.

---

## Ticket Routing from /start

When you run `/start`, the agent reads your Jira board and routes tickets automatically:

| Jira ticket type | Routes to |
|---|---|
| Story / Feature / Task | `/flow` |
| Bug | `/bug` |
| Hotfix / Urgent | `/hotfix` |
| Incident / P1 | `/incident` |
| Review / PR Review | `/review` |
| Refactor / Tech Debt | `/refactor` |
| Security / Compliance | `/security` |
| Performance | `/perf` |

You can override the routing by selecting a different command from the `/start` menu.

---

## Workflow Modes — Board-Driven, Agent-First, Hybrid

The `jira_workflow` setting from `/init` (Q3) controls how tickets flow between the agent and Jira. All three modes use the same agents and quality gates — only the starting point differs.

### Board-driven (default)

Your team creates tickets in Jira. The agent reads the board and picks up tickets.

- When browsing the board, the agent shows interactive buttons ("Let me browse the board" / "I have a ticket ID"), then presents tickets from all board columns first (Discovery, To Do, In Progress, In Review), then backlog — grouped by priority within each section. All priorities and all assigned tickets are shown — nothing is filtered out. Assigned tickets are noted so you can take over if someone is unavailable.
- Agent never creates tickets unless explicitly asked
- Works best for teams with a PM who manages the board
- The agent reads acceptance criteria, priority, and type from the ticket

### Agent-first

The agent creates all Jira tickets after a conversation with the developer.

1. Developer describes what they want to build
2. Agent runs `brainstorming` skill for scoping questions
3. Agent runs `work-breakdown` skill to propose the hierarchy (epic → stories → tasks)
4. Developer approves or edits the breakdown
5. Beads created for all tasks (always — works without Jira)
6. Jira tickets created if Jira is configured (epic, stories, sub-tasks with proper linking)
7. Agent starts working from the first task

Works best for solo devs or small teams without a dedicated PM. Also works without Jira — beads-only tracking is fully supported.

### Hybrid

Your team creates epics and stories in Jira. The agent breaks stories into developer-sized sub-tasks.

1. Agent reads the next epic or story from the board
2. Agent runs `work-breakdown` skill to propose sub-tasks
3. Developer approves or edits the sub-task list
4. Sub-task beads created. Jira sub-tasks created under the parent.
5. Agent starts working from the first sub-task

The agent never creates epics or stories in hybrid mode — only sub-tasks. If a new story is needed, the agent recommends it but the PM creates it.

Works best for teams where the PM owns the high-level board and the developer owns the implementation details.

## Advisory discovery and ticket creation

Use advisory discovery when you know the outcome you want but not the exact bug,
feature, refactor, or improvement to pursue. The advisor performs a read-only
repository review, consults authoritative documentation when needed, checks for
existing Jira/Beads work, and returns ranked proposals with evidence, confidence,
impact, scope, risk, and acceptance criteria.

The advisor does not create a ticket or modify code during discovery. After you
approve a proposal, it delegates the Jira operation to `jira-workflow-steward`.
The steward applies the canonical ticket template, chooses the issue type and
priority, links existing work, applies the project's phase map, creates/updates
Beads, and records an idempotent action so a resumed run cannot create a duplicate.
Multi-part proposals go through `work-breakdown` first; single changes go directly
to the appropriate workflow such as `/bug`, `/refactor`, `/security`, `/perf`, or
`/flow`.

For a GoalRun, the provider-specific planner (Fable for Claude or GPT-6 Astra for
Codex) owns synthesis and approval preparation, the worker (Opus or Luna)
implements, and the lightweight monitor reports status. `goal-loop advise --scope
<scope> --findings <file.json> --run-id <run-id>` is the runtime intake for ranked
findings. It persists stable proposal IDs in GoalRun state; `goal-loop
approve-advisory --run-id <run-id> --proposal-id <id>` records explicit approval
before the host hands the approved item to the steward. The approval command itself
has no Jira side effect.
The same advisor skill and Jira boundary are used by Claude and Codex.

### Choosing a mode

| Question | Board-driven | Agent-first | Hybrid |
|---|---|---|---|
| Does your team have a PM? | Yes | No | Yes |
| Who sizes tickets? | PM or team | Agent proposes, dev approves | Agent proposes sub-tasks |
| Does the agent create Jira tickets? | Never (unless asked) | Yes — full hierarchy | Yes — sub-tasks only |
| Can it work without Jira? | Needs Jira | Yes (beads-only) | Needs Jira |

The mode is set during `/init` (Q3) and stored in `~/.claude/memory.md` as `jira_workflow`. Run `/init` again to change it.

---

## Status Transitions

The agent moves tickets through your Jira workflow automatically:

| Event | Jira transition |
|---|---|
| Work starts | To Do → In Progress |
| PR created | In Progress → In Review |
| PR merged | In Review → Done |
| Work blocked | In Progress → Blocked (if column exists) |
| Ticket abandoned | Returns to original column |

Transition names are matched to your board's column names. If your board uses different names, the agent adapts during `/init` setup.

Before a transition, the workflow runs the installed deterministic phase
resolver with the live status-ID-to-column mapping, current ticket state,
phase map, and available transition targets. It returns transition,
comment-only, in-place, or blocked. A blocked result leaves the ticket in its
current column and reports the reason; the agent never guesses from status
names or column order.

---

## Beads + Jira Pairing

When both Beads and Jira are active (the recommended configuration):

| Action | Jira | Beads |
|---|---|---|
| Task starts | Ticket moves to In Progress | Beads issue created, linked to Jira key |
| Progress update | Comment on ticket | Beads issue updated with context |
| Task completes | Ticket moves to Done | Beads issue closed |
| Cross-session resume | Ticket stays in current column | Beads provides full context from previous sessions |

Jira gives your team visibility. Beads gives the agent memory across sessions. Together they ensure nothing is lost.

---

## Configuration

Jira settings are stored in two places:

- **`~/.claude/memory.md`** — your Jira URL and default workflow direction (global)
- **`.claude/PROJECT.md`** — board ID, board mappings, column names (per project)

Both are managed by `/init`. Manual editing is not recommended.

---

## Related Docs

- [Beads — AI Task Tracking](../concepts/beads.md)
- [Project Configuration](project-config.md)
- [Commands Reference](commands.md) — `/start` routing and `/flow` workflow
- [Agent List](../reference/agent-list.md) — `jira-workflow-steward`
- [MCP Connections](../concepts/mcp.md) — MCP setup and tool counts
