# Commands — Full Reference

All commands with descriptions, when to use each, and what they do. Claude Code exposes these as slash-command shortcuts; Codex uses the same intent through natural-language goals and the shared skills/runtime. You can also type `/commands` in Claude Code for a quick reference without leaving your session.

---

## When to Read This

- You want a quick overview of all available commands
- You are unsure which command to use
- You want to understand the difference between similar commands

---

## The One Command You Need

**`/start`** — if you only remember one Claude Code command, remember this. It guides you to the right workflow every time. In Codex, state the goal instead, for example: `Start the next Jira ticket and follow the toolbox workflow.`

---

## Entry Points

| Command | When to use | What it does |
|---|---|---|
| `/start` | Daily — starting your day, or not sure what to do | Shows a menu, routes you to the right command based on what you select or your Jira ticket type |
| `/init` | Once per project — project setup | Configures methodology, stack, Jira, MCPs. Runs automatically via /start if PROJECT.md is missing |

---

## /start vs Direct Commands

### Claude Code command menu

The menu and direct commands below are optional shortcuts for Claude Code. Codex users can describe the same intent in plain language; both providers use the same goal loop: `goal → plan → act → verify → checkpoint → repeat`.

| Path | Steps | Use when |
|---|---|---|
| `/start` | Menu → select → summary → confirm → work | Not sure which command fits, prefer guidance |
| Direct (e.g. `/flow`) | Summary → confirm → work | You already know what type of work this is — saves 2 steps |

**What never gets skipped:** /init (if not configured), confirmation summary, quality gates, TDD, security checks, PR creation.

For a detailed feature-by-feature breakdown of what each command does and doesn't do, see [Command Comparison](command-comparison.md).

---

## Planned Work

| Command | When to use | What it does |
|---|---|---|
| `/flow` | Kanban or Scrum ticket | Reads Jira board, picks up ticket, full build workflow from design to PR. Scrum boards get sprint planning + retrospective automatically |
| `/build` | No Jira ticket needed | Ad-hoc work — prototype, experiment, quick feature. No Jira overhead |
| `/presentation` | Create or edit a deck | Loads the shared PowerPoint skill/template for Claude or Codex, validates the deck, and reports a visible output path |
| `/goal` | A goal must survive sessions or compaction | Durable GoalRun state, GPT-6 Astra/Fable advice, Opus/Luna worker iterations, verifier evidence, self-improvement incidents, status, pause/resume/cancel; toolbox-only auto-merge |

---

## Bugs and Fixes

| Command | When to use | What it does |
|---|---|---|
| `/bug` | Something broke, not urgent | Investigates root cause with systematic debugging, fixes, creates PR. Auto-creates Jira ticket |
| `/hotfix` | Needs fixing today | Same as /bug but skips brainstorming, full planning, extended docs. Fast-tracks CI/CD deployment |
| `/incident` | Production is down right now | Queries Seq immediately, restores service, files post-mortem automatically |

---

## Code Quality

| Command | When to use | What it does |
|---|---|---|
| `/review` | Review without changes | Code quality + security report. No PR created — read-only |
| `/refactor` | Clean up existing code | No new features. Tech debt, dead code, modernisation. PR created |
| `/security` | Dedicated security scan | Full OWASP scan with severity report. Fixes CRITICALs if found |
| `/perf` | Something is slow | Investigates slow APIs, DB queries, pipelines, frontend. Not broken, just slow |

---

## Utilities

| Command | When to use | What it does |
|---|---|---|
| `/commands` | Quick reference | Lists all commands with examples — without leaving the terminal |
| `/ask` | Questions, issue reports, or “what should we improve?” | Answers from docs, performs read-only advisory discovery, ranks evidence-backed proposals, and creates approved fix branches |
| `/feedback` | Report toolbox issues or suggest improvements | Logs bugs, token waste, overlaps, feature requests. Saves locally and optionally pushes to Jira for team visibility |
| `/continue` | Resuming after a session break | Reads `.claude/handover.md`, shows what was done previously, and picks up from the next phase or incomplete GoalRun |
| `/review-pr` | Autonomous PR comment handling | Reads unread comments on a PR (yours or specified), decides agreement, replies or applies fixes autonomously. Claude uses CronCreate; Codex Desktop uses a heartbeat registered with `register-pr-poll.sh`; both use the shared provider-neutral poll state |
| `/merge-pr` | Merge PRs you name | `/merge-pr 862 863` — merges the listed PRs (any repo) without you opening a terminal. Reuses the `pr-action-safety.sh` live gate; refuses any PR not open/mergeable/CI-green/threads-resolved |
| `/status` | PR review activity snapshot | Lists active `/review-pr` crons, recent actions, open PRs with new comments. Read-only |

---

## Confirmation Summary

Every command shows a confirmation summary before work begins. Nothing starts without your explicit approval. You can edit any field before confirming.

**Board-driven mode (12 fields):** the **feature branch name** is NOT proposed yet — the agent hasn't assessed whether code is needed (that happens at Step 2 of /flow). The **target branch** (PR base, default `main`) IS shown as [11] — that captures branch constraints ("only net8", "target portal2") early. The two are different fields with different purposes.

```
  [1]  Ticket         [2]  Title             [3]  Type
  [4]  Priority       [5]  Workflow          [6]  Beads
  [7]  Skipping       [8]  Integrations      [9]  Board
  [10] Columns        [11] Target branch     [12] Mutation testing
```

**Agent-first / hybrid mode (14 fields):** branch IS shown because the work-breakdown already confirmed these are coding tasks.

See `docs/how-to/confirmation-summary.md` for full layout, cascade logic, and editing details.

---

## Smart Ticket Routing

When the agent reads a Jira ticket, it routes automatically:

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
| No ticket | `/build` |
