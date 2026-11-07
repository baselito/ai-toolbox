---
name: workflow-discipline
source: ECC (common/)
scope: always active
---

# Workflow Discipline

Universal directives for ALL commands and work — via `/start`, a shortcut command, or ad-hoc conversation. **Full grammar, scripts, rationale, and incident history live in the `workflow-discipline` skill — load it when you need the detail.**

## Rule 0 — Natural language routes to slash commands

When the user types a command name (slash optional), invoke the matching command. "start" = `/start`, "bug" = `/bug`.

| User says | Invoke |
|---|---|
| "start", "start working on X", "pick up X", "work on X", "let's do X" | `/start X` |
| "bug", "fix bug", "fix a bug in X", "there's a bug" | `/bug X` |
| "hotfix", "urgent fix", "emergency fix" | `/hotfix X` |
| "incident", "production down", "outage", "site is down" | `/incident` |
| "security", "security scan", "vulnerability", "security audit" | `/security X` |
| "perf", "performance", "it's slow", "optimize" | `/perf X` |
| "refactor", "clean up", "restructure" | `/refactor X` |
| "build", "build something", "create from scratch" | `/build` |
| "review", "review code", "code review" | `/review` |
| "advise", "what should we fix", "find improvements", "look for bugs", "what needs improvement" | `/ask` + `advisory-discovery` |
| "continue", "resume", "pick up where we left off" | `/continue` |
| "status", "what's going on" | `/status` |
| "flow" | `/flow X` |
| "presentation", "slides", "deck", "powerpoint", "pptx" | `/presentation X` |

If a ticket ID appears ("start on 756", "bug in TASK-741"), pass it as an argument. The agent does NOT get to treat natural language as "just a request" and bypass the command — the commands carry the guardrails. Enforced by `enforce-workflow-start.sh` (blocks `git checkout -b` with a Jira ticket-ID pattern unless the workflow marker exists).

**Mutation testing (Stryker) keywords:** ON by default for work that creates unit tests on `/start`, `/flow`, `/build`, `/bug`, `/refactor`, and GoalRun iterations. The user can force it off/on per ticket ("no stryker" / "use stryker"). `/hotfix` and `/incident` always skip it. The full keyword grammar (opt-in/opt-out/negation/incidental disambiguation) is in the `workflow-discipline` skill — load it when a Stryker keyword appears.

## Toolbox self-maintenance exception

**Detection:** repo is the ai-engineering toolbox when `git remote get-url origin` resolves to `baselito/ai-engineering`. This identifies the toolbox by the same owner/repo the merge repo-split uses — runtime detection lives in `commands/review-pr.md` Step 5.5 (`$OWNER == baselito && $REPO_NAME == ai-engineering`); the behaviour it gates is described in `rules/git-workflow.md` "Merge After Review Complete" (**ai-engineering (toolbox)** vs **All other repos (project repos)**).

**When the repo IS the ai-engineering toolbox:** `/flow` (and all other workflow commands) run their **full orchestration** — Discovery, chief-of-staff execution plan, Opus implementing subagent, code review, verification, PR — but create **no Jira ticket** and post **no Jira comments**. Phase summary cards still show at every gate; the card's `Jira:` line reads `n/a — toolbox self-change`. Step 0 (Phase-Map Drift Validation) is skipped entirely — the toolbox has no board and no phase map.

**Rationale:** the toolbox has no Jira board; toolbox changes are self-maintenance infrastructure. This is the same repo the existing merge repo-split already singles out.

**When the repo is NOT the ai-engineering toolbox:** Rules 1–3 below apply in full — Jira ticket and board-transition discipline are required; comments use the concise milestone policy in `rules/agents.md`.

## Rule 1 — All commands follow /start discipline

Every command that touches Jira follows the same enforcement as `/start` → `/flow`: one short Start, PR/milestone, and Completion update at those lifecycle milestones, exceptional Blocker updates only when justified, board transitions via `jira-workflow-steward` using phase keys, agents/models assigned by chief-of-staff, phase summary cards at every gate, and handover entries after every phase. (Detail: `rules/agents.md`, `rules/handover.md`.)

**Exception — toolbox self-maintenance:** see the "Toolbox self-maintenance exception" section above. Full orchestration still runs; Jira ticket and phase comments are skipped.

**Streamlined path is USER-INITIATED ONLY.** The `/start` confirmation offers it once at kickoff (header `Unknown`); the user picks it, or it does not happen. Record the choice in the handover.

⛔ **The agent never selects the streamlined path on its own assessment of the ticket.** An earlier revision of this line allowed "a standing autonomy declaration plus a matching ticket profile" to count. "Matching ticket profile" is the agent grading the ticket, which is precisely the "agent decided it was simple enough" move this rule exists to stop — the "/flow invented scope" incident class. A standing autonomy declaration removes *sequencing* asks; it does not let the agent skip brainstorming and planning.

The only non-user path is an OBJECTIVE one, decidable without judgement: `.claude/PROJECT.md` carries an explicit `streamlined_default: true`, which is the user's own recorded standing choice for the project rather than the agent's reading of a ticket. Absent that key, the kickoff offer is the only route.

Scope expansion remains a Scope ask — the agent never invents scope. Internal phase details stay in the handover; they do not create routine Jira comments.

Shortcut commands (`/bug`, `/security`, `/perf`, `/hotfix`, `/incident`, `/refactor`, `/build`, `/review`) are valid entry points but use the same Jira/agent/model infrastructure as `/start`.

## Rule 2 — Always ask about Jira before starting work

When you discover something to fix mid-conversation (bug, missing feature, config/pipeline issue, dead code, vulnerability), ASK before starting: "I found [X]. Create a Jira ticket before starting?" The user may want to track, defer, reassign, or skip it. **Exception:** if the user says "just fix it" / "don't bother with a ticket", proceed and note the decision in the handover.

**Exception — toolbox self-maintenance:** when the repo is `baselito/ai-engineering`, no Jira ticket is created and the agent does not ask the "create a ticket?" question — there is no board. The user-consent gate STANDS: the agent still confirms with the user before starting newly discovered work (only the ticket step is waived, not consent).

## Rule 3 — "Yes, work on it" routes through /start

When the user says yes to picking up a ticket (including "work on 756", "pick up 756", "let's do 756"), route through `/start` → `/flow`. Never bypass the orchestrated workflow. The agent does NOT decide a ticket is "too simple" — the streamlined path covers that. Enforced by `enforce-workflow-start.sh`.

**Exception — toolbox self-maintenance:** when the repo is `baselito/ai-engineering`, `/start` → `/flow` still runs the full orchestration but ticketless (no Jira ticket lookup or creation).

## Rule 4 — Auto-poll after every PR (1 minute, default on)

Every command that creates a PR registers a `/review-pr` auto-poll at `*/1 * * * *` when the active host supports recurring jobs. Claude Code uses CronCreate; Codex Desktop uses a heartbeat and `register-pr-poll.sh`. Either host is a **best-effort backstop**, not the reliable path: the agent handles reviewer comments inline (run `/review-pr --repo <owner>/<repo> <N>` at PR creation, on return to the PR, and before ending the session). ALL reviewer comments (human + bot) are processed automatically. Self-terminates on merge/close. If the host cannot schedule, the agent must report that polling is not active and use bounded `goal-loop watch` or a manual review. Only opt-out: `--no-poll` or `NO_AUTO_POLL=1`.

## Rule 5 — Gitignore pre-check before branching/committing in a project repo

Before creating any branch, running `bd init`, or the first commit in a project repo, verify toolbox files (`.beads/`, `AGENTS.md`, `CLAUDE.md`, `.claude/`, `ai-engineering/`) are gitignored AND not already tracked — gitignore alone does NOT stop already-tracked files; `git rm --cached` does. The exact pre-check script and the per-command timing table are in the `workflow-discipline` skill → "Gitignore pre-check".

## Rule 6 — Test-only PRs must not touch production code

When a ticket is test-only (`test_only: true`): the implementation subagent must not modify anything outside test directories (report + stop if it needs to); reality-checker verifies the diff; `finishing-a-development-branch` verifies before PR. Enforced at all three levels.

## Rule 7 — Production dependency changes require approval

Modifying a production `.csproj` (version bump or new package): show the user and get approval first — NEVER bump silently. Even patch bumps in a non-dependency PR get surfaced. In test-only PRs, production `.csproj` changes are blocked entirely (Rule 6).

## Rule 8 — Toolbox install/update is user-gated and docs-verified

When asked to install/update the toolbox itself (`scripts/install.sh` / `scripts/update.sh`): **(8a)** the agent MUST ask via AskUserQuestion (header `Unknown` — a data-sharing preference is not inferable from the repo, and Codex sends code to OpenAI) before running `install.sh` — it never decides Codex on the user's behalf (use `INSTALL_CODEX=1`/`0` on the agent path); **(8b)** verify docs are current (run `verify.sh` + the `docs-before-commit` checklist; Codex docs-freshness pass when enabled) before reporting done. Full procedure: `workflow-discipline` skill.

## Rule 9 — Every loop declares its bound, and three guards carry it

Any loop the agent creates — a `/loop` run, a recurring `CronCreate`, a `/goal` phase exit, a
stop-hook retry cycle — must declare a bound at the moment it is created. `--max-budget-usd`,
`CLAUDE_CODE_MAX_TURNS` and `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` are the harness's turn and spend
mechanisms; **the toolbox adds no turn counter and no spend ledger of its own — but it does
refuse to CREATE a loop that declares no bound** (`enforce-loop-bounds.sh`). The three guards are
how a bound gets carried, and **not every guard reaches every loop kind** — so each row below
says, per loop kind, whether the guard is enforced by the harness or a hook, invoked by the
caller, or does not apply at all. Where a guard does not reach, the guards that remain are the
whole bound.

| Guard | How it binds, per loop kind |
|---|---|
| **Iteration ceiling** | **Launched as a loop** — `scripts/loop-launch.sh` reads the numeric `loop:` values, applies the tighten-only ceiling, and sets `CLAUDE_CODE_MAX_TURNS` plus `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` before invoking the native Claude CLI. `/loop` creation remains hook-enforced on `Skill`; direct user `/goal` still relies on its condition clauses because the hook cannot observe that input path. **Recurring `CronCreate`** remains hook-enforced, including the registered `/review-pr … --auto` backstop. |
| **No-progress detector** | `~/.claude/scripts/loop-progress-signature.sh` — a normalised failure signature, **never file mtimes**: a loop rewriting the same failing file reads as healthy to an mtime detector forever. Exit 3 means stop and escalate. The native loop body still invokes it per iteration, and `/review-pr --auto` now invokes it after measuring the complete merge-gate state. A `/goal` condition must still name the clause because the evaluator cannot run tools; the hook enforces that clause where it can observe the goal. |
| **Spend cap** | `max_spend_usd` → `--max-budget-usd`, and **only a run launched as a loop is launched with the flag.** ⛔ Two kinds therefore have NO dollar bound. An interactive `/goal`: its turn and no-progress clauses are the whole budget, which is why guard 1 rejects a condition missing either. A **recurring cron fire: it has neither of those clauses either** — the registry admits nothing but `/review-pr` with `--auto`, `--repo <owner>/<repo>` and a bare PR number, so the prompt cannot carry a `/goal`; its bound is the 1-day cap, merge/close termination, 7-day backstop, and the auto-poll no-progress detector (the pre-check covers fires that would otherwise be skipped, while the full gate covers fires that continue). |

Clamps and ceilings: the `workflow-discipline` skill §1d (tighten-only, not settable from
`PROJECT.md`). **Load the `loop-design` skill** before creating any loop, before raising any
loop bound, and before registering a new self-terminating cron prompt — it carries the five
components, the verification ladder, the cost-per-accepted-change metric, and the
when-NOT-to-loop list (no verifiable end state; design/planning work; anything touching auth,
money or production).

## Applies To

All commands, agents, workflows — no exceptions. Rationale and incident histories: `workflow-discipline` skill.
