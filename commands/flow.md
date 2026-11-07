# /flow — Ticket Workflow

Full build workflow for a Jira ticket. Reads the ticket from the board, runs the complete development pipeline from design to PR, with all quality gates and agent orchestration. Works with both Kanban and Scrum boards — the agent auto-detects the board type via `Bash(acli jira board search --json)` and adjusts accordingly (Scrum boards get sprint planning and retrospective).

## Durable GoalRun integration

When the user supplies a detailed goal with acceptance criteria, /flow may
persist it as a GoalRun. Each worker iteration is bounded and records verifier,
watchdog, and Jira progress evidence; /flow resumes the same run after a
session break instead of starting duplicate work. Jira still uses
jira-workflow-steward, its delegation-token protection, jira_phase_map, and
the normal board transitions plus concise milestone updates.

## Phases (universal) and Phase Map (per-board)

The 8 workflow phases are **universal** — every team's `/flow` runs through them. Whether a phase produces a Jira column transition depends on the board's **phase map** (`jira_phase_map` in PROJECT.md), not on the phase itself. This is the central design rule: **the toolbox should fit the team, not the other way around**.

| # | Phase | Phase-map key | What the agent does | Agent opinion example |
|---|---|---|---|---|
| 1 | Discovery | `discovery` | Reads ticket, explores codebase, identifies affected files and risks | "This touches 3 services — consider splitting" |
| 1.8 | **Execution Plan** | (no transition) | **Chief-of-staff (Opus deep-reasoning tier) assigns agents and models for all phases** | "Simple test ticket — standard agents, no security-engineer needed" |
| 2 | Ticket Assessment | (no transition) | Determines if code is needed, identifies scope | "Ticket is vague — brainstorming will clarify" |
| 3 | Brainstorming | (no transition) | Explores approaches, discusses trade-offs with user | "Approach A is safer, I'd recommend it" |
| 4 | Planning | `ready_for_dev` | Creates implementation plan with exact files and phases | "Larger than it looks — 8 files across 2 services" |
| 4.5 | **Streamlined-plus Scope Expansion** *(conditional)* | (no transition) | **Orchestrator inline grep on the change's axis. No agent. <30 seconds.** Only runs when Brainstorming or Planning was skipped — see Step 6.5 | "3 callsites also branch on TEST_ENVIRONMENT — file followup or extend?" |
| 5 | Implementation | `in_progress` | Creates branch, writes tests, writes code | "All pass but existing code has no null handling" |
| 6 | Code Review | `code_review` (often == `in_progress`) | Runs code-reviewer agent, grades the code | "Grade A, but XML docs would help maintainability" |
| 7 | Verification | (no transition) | Maps every acceptance criterion to the test covering it, re-runs the new tests, reality checker — re-runs every configured gate only if this phase modified a file (Step 11a) | "All green, CI will cover integration tests" |
| 8 | PR Creation | `ready_for_release` (optional) | Pushes branch, creates PR (after user approves) | "Clean PR, ready for developer review" |
| — | **Agent stops** | — | Offers to pick next ticket | — |
| — | Done | `done` (post-merge — user-driven for project repos; ai-engineering is the scoped GoalRun exception) | ai-engineering: ticketless self-maintenance (no Jira board) — the GoalRun auto-poll may merge only after all live gates pass; there is no post-merge ticket transition. Other repos: user merges the PR and manages the ticket lifecycle — the agent does NOT move the ticket to Done. See `rules/git-workflow.md` "Merge After Review Complete". | — |

**Reading the table:** the **Phase-map key** column names which entry in `jira_phase_map` controls this phase's column transition.

- **Quoted column name** in the map → ticket transitions to that column when the phase runs.
- **`null`** in the map → phase has no board transition on this board. A milestone update is still optional.
- **Same column reused across keys** → ticket stays put for both phases; no routine comment is added. (Common for boards where Code Review happens inside In Progress.)
- **Missing key entirely** → phase doesn't execute on this board. Defensive — better to skip than mistransition.

**Phases marked "(no transition)"** never produce a column move on any board — they are toolbox-internal work (planning, brainstorming, verification, scope expansion) that doesn't correspond to a place a ticket sits. Their detail belongs in the handover and phase card, not a routine Jira comment. The normal Jira update milestones are Start, PR/milestone, and Completion; a short Blocker update is exceptional and only used when a human decision or visible ticket impact requires it.

After every phase 1–8, the agent presents a specific summary + its opinion, then **proceeds** (autonomy rule); it asks only on BLOCKED or a category question (`rules/autonomy.md`). The card is reporting, not a question — the user interrupts to revise or stop.

**⛔ PHASE-MAP PRE-CONDITION — `/flow` Step 0 verifies the contract before any phase fires ⛔**

The phase map (`jira_phase_map` in PROJECT.md) is verified at the start of every `/flow` run against the live board. See **Step 0 — Phase-Map Drift Validation** below. If a mapped column no longer exists, the run pauses for user remap before any board transition or requested milestone update.

Once Step 0 passes, each phase consults the phase map at execution time:

```
phase_key   = "in_progress"           # one of: discovery, ready_for_dev, in_progress, code_review, ready_for_release, done
current_col = read_current_column(ticket)

# Missing key ≠ explicit null. Missing means PROJECT.md drift; surface it.
if phase_key not in phase_map:
    raise ValueError(f"phase_map missing '{phase_key}' — run /flow Step 0 to repair")

target_col = phase_map[phase_key]    # may be a column name OR explicit null

if target_col is None:
    # explicit no-transition phase on this board (null in map)
    no_transition()
elif target_col == current_col:
    # ticket stays put; no routine Jira update
    no_transition()
else:
    transition(target_col)

# A Jira comment is separate from the transition and is only requested for a milestone/blocker.
```

The orchestrator passes the phase key to `jira-workflow-steward`; the agent applies the 3-branch logic. Never read the column directly in the orchestrator — that puts board-specific knowledge in the wrong place.

### Deterministic phase decision preflight

The steward performs a network-free preflight with the installed
`jira-phase-resolver.sh` before any phase transition. The input includes the
ticket's current status ID, the live status-ID-to-column mapping returned by
`jira-board-columns.sh --mapping`, the live column list, the explicit
`jira_phase_map`, and Jira's currently allowed transition targets from the
live transition API response. The resolver returns one of:

- `transition`: move to the mapped live column; add a milestone update only when explicitly requested;
- `no_transition`: the phase is explicitly `null` on this board;
- `in_place`: the mapped target is already the current column; or
- `blocked`: the phase key, mapping, live board, or transition permission is
  inconsistent.

`blocked` is fail-closed: keep the ticket where it is and surface the exact
reason. Missing or malformed transition permissions are also `blocked`; never
proceed on an absent permission list. Never infer a column from a status name,
guess a renamed column, or walk columns by ordinal position. The helper is
network-free so fixture tests remain deterministic; live board reads and Jira
permissions stay at the CLI/API boundary.

**Phase 4.5 (Streamlined-plus) note:** This phase has no phase-map key — it never produces a column transition. It runs inline in whatever column the ticket occupies (typically the `ready_for_dev` column) and only activates when the streamlined path was chosen (Brainstorming or Planning skipped).

**⛔ AGENT/SKILL PRE-CONDITION — VERIFY CORRECT TOOLS FOR EACH PHASE ⛔**

Before starting any phase, verify the correct agent, skill, and model are being used. Do NOT run a phase with the wrong model — this wastes budget and reduces quality.

| Phase | Required agent/skill | Model | What goes WRONG if skipped |
|---|---|---|---|
| 1 Discovery | **Opus subagent** invokes `discovery` **skill** (not inline on the orchestrator) | **Opus** | Running it inline on the orchestrator wastes budget; PreToolUse hook blocks direct invocation |
| 2 Assessment | Main agent (the orchestrator) — classification only, does NOT explore code | **Orchestrator tier** (whatever the session model is — Fable by default) | N/A — orchestrator-native step, no wrong-model path exists |
| 3 Brainstorming | **Opus subagent** invokes `brainstorming` **skill** (not inline on the orchestrator) | **Opus** | Running it inline on the orchestrator wastes budget; skill's Socratic process gets shortcut |
| 4 Planning | `planner` **agent** (spawn, not inline) | **Opus deep-reasoning tier** (`rules/performance.md`) | Sonnet plans are shallower, miss dependencies | <!-- tier-ok: the trailing 'Sonnet plans are shallower' is the rationale for NOT using Sonnet here -->
| 4.5 Streamlined-plus scope expansion (only when Brainstorming or Planning was skipped or abbreviated) | **Orchestrator inline** — `rg`/`grep` on the change's axis, then apply the stated default (out of scope — file the followup) and report the callsites in the State block. **NO agent.** | **No model — bash, no question in the normal case** | Spawning an agent defeats the purpose; latent cross-file bugs (ternary fall-through, missed switch case) ship to PR |
| 5 Implementation | **Opus subagent** (spawn, not inline on the orchestrator) | **Opus** | Inline orchestrator work costs far more for execution work |
| 6 Code Review | `code-review-orchestration` **skill** (invoke, not inline) → chief-of-staff (Opus deep-reasoning tier) orchestrates → review agents | **Deep-reasoning tier** orchestrates, **Opus** reviews | No independent review if same agent writes + reviews; PreToolUse hook blocks direct agent spawns |
| 7 Verification | `verification-before-completion` **skill** + `reality-checker` **agent** | Opus | Manual test runs miss skill's additional checks |
| 8 PR Creation | `finishing-a-development-branch` **skill** | Opus | Manual PR misses skill's structured options |
| All Jira ops | `jira-workflow-steward` **agent** (spawn for acli calls) | **Haiku** | The orchestrator doing acli calls costs far more |
| All commits | Model-routed commit messages | **Haiku** | The orchestrator writing commit messages wastes budget |
| All handover | Append via Edit tool | — | Write tool overwrites previous entries |

**At every phase handover, verify:**
1. Am I using the right model for this phase? (Check table above)
2. Am I invoking the designated skill/agent, or doing it inline? (Inline = wrong)
3. Am I spawning subagents where required, or bloating the main context?

If any answer is wrong, correct it before proceeding.

---

> **Edge cases:** If something goes wrong (Jira unreachable, empty results, user rejects, mid-workflow failure), follow the always-loaded general rules in `rules/edge-cases.md` and load the `edge-cases` skill for the scenario playbooks. Never fail silently — always offer alternatives.

## Trigger

- Run manually: `/flow`
- Auto-routed from `/start` when ticket type is Story/Feature/Task (any methodology)

---

## Prerequisites

- `.claude/PROJECT.md` must exist — if not, the agent runs `/init` automatically before continuing
- Jira must be configured (if not, the agent operates without Jira — branch naming and Beads tracking still apply)

---

## Jira Update Policy — short milestones, not every phase

**Toolbox self-maintenance exception:** when the repo is `baselito/ai-engineering`, Jira
comments and transitions are skipped because the toolbox has no project ticket. Phases still run
and phase cards still show, with the card's `Jira:` line reading `n/a — toolbox self-change`.

For project repos, Jira updates are milestone-based:

- **Start:** one short sentence when work begins.
- **PR/milestone:** one short sentence when a reviewable deliverable or PR is available.
- **Completion:** one short sentence when the work is complete.
- **Blocker (exception):** one short sentence only when a human decision or visible ticket impact
  requires it. Add a resolution comment only if the ticket would otherwise still appear blocked.

Do not post routine comments for assessment, brainstorming, planning, code review, verification,
polling, retries, provider switches, installation, or test output. Keep those details in the
handover, PR, and tool logs. Board transitions still run through `jira-workflow-steward` using
the live phase map, whether or not a comment is posted.

The full phase cards remain internal workflow evidence. The `flow-reference` skill retains legacy
phase-comment templates only for interpreting older tickets; it is not a reason to create a
comment for every phase in a new run.

## Phases vs Columns — THEY ARE DECOUPLED

**⛔ CRITICAL RULE: Phases always happen. Columns adapt to what the board has. ⛔**

The 8 workflow phases are internal work stages. Board columns are how YOUR team visualises
progress. The **phase map** (`jira_phase_map` in PROJECT.md) maps between them, set at `/init` and
verified at the start of every `/flow` run (Step 0 below).

**Principle: the phase is the WORK; the column is WHERE THE TICKET SITS.** If the mapped column
doesn't exist or already matches the current column, the ticket doesn't move. The phase work,
phase card, and handover still happen; a Jira comment is only posted for an explicit milestone
or exceptional blocker. `jira-workflow-steward` applies the board transition logic; the
orchestrator passes a **phase key**, never a column name.

When an explicitly requested milestone has no dedicated column on this board, its text can mention
the current column for context. The legacy header-adaptation forms are in the **`flow-reference`
skill**; transition logic is in `agents/jira-workflow-steward.md`.

## Step 0 — Phase-Map Drift Validation

**Workflow marker:** Create the workflow-started marker immediately. This marker is checked by `enforce-workflow-start.sh` — it gates branch creation for ticket branches (Step 7) to ensure the agent went through `/start` → `/flow` instead of jumping straight to implementation.

```bash
touch ~/.claude/.workflow-started
```

**Toolbox self-maintenance exception:** if `git remote get-url origin` resolves to `baselito/ai-engineering`, **skip Step 0 entirely** — the toolbox has no Jira board and no phase map. Proceed directly to Step 1. All other steps run normally; Jira comments and transitions are skipped throughout (see "Jira Comment Requirements" below).

**⛔ MANDATORY first step on every `/flow` run, BEFORE any board transition or requested milestone update. ⛔**

The phase map is a contract between toolbox-internal phase names and the live board's column names. Boards drift — teams rename columns, add stages, drop steps. A phase map locked in at `/init` and never re-checked WILL silently fail when columns drift, and the failure mode is "first transition mid-flow fails with 'no such column'" — by which point the agent has already started building a feature on a stale assumption.

**Treat the phase map as a contract that's verified at workflow start, not assumed.**

### What Step 0 does (one acli call, ~200 ms cached, ~1 s cold)

**Optional `intermediate_comments` parameter** — do not populate this for routine pass-through
columns. Use it only for an explicitly requested milestone or a visible blocker. Default is `{}`.

```bash
# 1. Read the phase map and board id from PROJECT.md
phase_map = read_yaml(.claude/PROJECT.md → jira_phase_map)
board_id  = read_yaml(.claude/PROJECT.md → jira_board_id)

# 2. Read live board columns
live_cols = bash(~/.claude/scripts/jira-board-columns.sh $board_id --json)
# → ["Backlog", "Selected for Development", "In Progress", "Ready for Release", "Done"]

# 3. Compare mapped (non-null) values against live list
missing = []
for phase, target in phase_map.items():
    if target is None:
        continue                                # no transition target to validate
    if target not in live_cols:
        missing.append((phase, target))         # mapped column no longer exists

# 4. Identify new columns (informational only — never force remap)
mapped_cols = {v for v in phase_map.values() if v is not None}
new_cols    = [c for c in live_cols if c not in mapped_cols]

# 5. Decide
if missing:
    surface_drift_to_user(missing, live_cols)   # see "Self-healing UX" below
elif new_cols:
    log_info(f"ℹ️ New columns on board: {new_cols} — no phase mapped, no action needed.")
    proceed_to_step_1()
else:
    proceed_silently()                          # phase map matches live board — no output
```

### Self-healing UX when drift is detected

When a mapped column is missing, surface drift to the user with best-guess remap and clear options. **NEVER silently remap** — a renamed column might encode a real semantic change. Always confirm.

```
⚠️  Board layout has changed since /init was last run

Phase map references columns that no longer exist on the board:
  ready_for_dev → "Selected for Development"  ❌ NOT FOUND

Live columns currently on board 309:
  Backlog
  Refined                                      ← did "Selected for Development" become this?
  In Progress
  Ready for Release
  Done

Best guess: ready_for_dev → "Refined"

[1] Accept best guess
[2] Pick a different column
[3] Set ready_for_dev to null (no transition for this phase)
[4] Quit and re-run /init
```

**Best-guess heuristic:** simple substring/Levenshtein match between the missing column name and live column names. Pick the closest single match if it shares ≥ 50% of characters or one is a substring of the other; otherwise present the live list without a guess and let the user pick. The match is a hint, not a decision.

After the user picks an option, **save the new mapping back to PROJECT.md** under `jira_phase_map`, then continue to Step 1. The fix is one-time per drift event — subsequent `/flow` runs proceed silently.

### Migration: legacy `jira_columns` → `jira_phase_map`

If PROJECT.md has `jira_columns` but no `jira_phase_map`:

1. Show: "Your project was set up before phase-mapping. Running anchor questions once to migrate."
2. Run the anchor questions from `/init` Sub-step 1e (Q1e-a through Q1e-f), seeded with the live column list.
3. Save the new `jira_phase_map`. Remove the legacy `jira_columns` field.
4. Tell the user the migration is complete; continue to Step 1.

This keeps existing projects working without forcing a manual re-run of `/init`.

Cost: one `jira-board-columns.sh --json` call (~200 ms cached, ~1 s cold). Catches column renames, deletions, and full board redesigns before any board transition fires.

---

## Jira Update Mechanism

Jira transitions and explicitly requested milestone updates are handled by spawning
`jira-workflow-steward` (Haiku). The orchestrator creates the delegation token once per workflow
(`touch ~/.claude/.jira-delegation-token`) and never calls `acli` itself.

**Transition phases pass a phase key — never a column name.** Valid keys: `discovery`,
`ready_for_dev`, `in_progress`, `code_review`, `ready_for_release`, `done`. PR Creation uses
`ready_for_release` even on boards that map it to null.

**Non-transition phases pass NO key — internal only.** Assessment, Brainstorming and Verification
have no phase key and do not create routine Jira comments. If a milestone or exceptional blocker
needs recording, request one short standalone update through the steward.

Short milestone examples are in the **`flow-reference` skill**; the old per-phase templates are
retained there only for interpreting existing ticket histories.

## Phase Summaries and User Decision Points

**⛔ MANDATORY AFTER EVERY PHASE ⛔**

After completing each phase, the agent MUST do ALL FOUR — not just the summary:

1. **Append to `.claude/handover.md`** — first phase: **Write** to create it. Every later phase:
   **Edit** to append at the end (NOT Write, which overwrites). Never delete previous entries.
   This happens FIRST, before showing the card.
2. **Present the phase summary card** — the canonical template is in `rules/agents.md` →
   "Phase summary card format", which is always loaded. Do not keep a second copy here.
3. **Give the agent's opinion** — mandatory even when there are no concerns ("No concerns — this
   looks straightforward"). The user should never wonder whether the agent held something back.
4. **Proceed** (autonomy rule); ask only on BLOCKED or a category question. The card is a window,
   not a gate — showing it IS the handoff, and the user interrupts to revise or stop.

The agent MUST NOT silently move from one phase to the next — the card is what makes the move
non-silent. Showing the card and continuing is compliant; moving on without a card is not.

**⛔ The Model line is MANDATORY — compare actual vs expected. ⛔** Report it as
`Model: <actual> — Expected: <from the phase table> → ✅ match` or `→ ❌ VIOLATION — <what
happened>`. On a violation, explain it; never report the model and move on.

**⛔ The Jira line is MANDATORY — every phase records whether a Jira action was needed. ⛔** It is
the orchestrator's checklist that transitions and requested milestone updates were handled.
Status values:

- `transitioned ✅` — steward moved the ticket successfully
- `milestone posted ✅` — steward posted the requested concise update
- `no update — internal phase` — no ticket-visible milestone or transition was needed
- `failed ⚠️ — [reason]` — requested action failed (continue but flag)
- `unreachable ⚠️ — retry when available` — Jira/acli unavailable (continue, retry later)
- `not configured —` — no Jira ticket for this work (e.g. `/build` without a ticket)
- `n/a — toolbox self-change` — repo is `baselito/ai-engineering`

The phase card still contains the detailed internal handover; it does not turn that detail into a
Jira comment. The line exists so a missing requested action is visible without requiring a comment
for every phase.

**Be specific, and write for a beginner or a tester** — name the files, the counts, and the
reasoning, not "explored the codebase". Explain a technical term the first time it appears, say
what something does rather than only how, and keep it concise. Worked good/bad examples for each
phase are in the **`flow-reference` skill**.

## External Change Detection

Before every column transition, the agent re-reads the Jira ticket to detect changes made by other team members since the last check:

| What changed | Agent behaviour |
|---|---|
| **Assignee changed** | A **Conflict** ask — someone else now has a claim on this work, and the agent cannot resolve whose it is by guessing. AskUserQuestion, header `Conflict`: "This ticket was reassigned to [person] since you started. Continue anyway, or hand it over?" |
| **Priority changed** | Report it in the State block and continue on the current ticket — work order is sequencing, never an ask: `Priority [old]→[new] by [person]. Decided: finishing this ticket first.` |
| **New comments from team** | Lead the next reply with the comment summary and continue. Pause only if the comment changes the agreed goal (**Scope**). |
| **Status changed externally** | A **Conflict** ask, for the same reason as the row above — another person is acting on this ticket. AskUserQuestion, header `Conflict`: "This ticket was moved to [status] by someone else. Should I continue from [current step], or re-read the ticket?" |
| **Ticket deleted or closed** | Stop: "This ticket was closed/deleted externally. Pick another ticket or end the workflow." |

If no changes are detected, the agent proceeds silently — no confirmation needed for clean transitions.

---

## Subagent Prompts MUST Include Prior Context

**Every subagent spawn prompt must carry the prior context that subagent needs**, because
subagents get a fresh context and cannot see the handover or the session history. A spawn that
omits it causes duplicate work — in one recorded workflow the full test suite ran three times
because successive subagents could not see that implementation had already run it.

Every spawn prompt MUST include:
1. What phase this is and what already happened (summarised from the handover).
2. The specific inputs this subagent needs (files, findings, decisions).
3. The line: `Return your results in your response message. Do NOT write to
   .claude/handover.md — the orchestrator handles that.` (Single-Writer Rule, `rules/handover.md`.)

Worked per-phase prompt templates showing exactly what prior context each phase needs are in the
**`flow-reference` skill**.

## `/goal` — Machine-Checkable Phase Exits

Two phases in this workflow have an exit condition a machine can check: **Implementation**
(Step 8) and **Verification** (Step 11). Both end in the same shape of work — run the
gates, read the failure, fix, run them again — and that cycle is the one part of `/flow`
where a human is doing nothing but watching. `/goal` closes it.

`/goal <condition>` is session-scoped and prompt-based. After every turn the condition plus
the conversation is handed to a small, fast evaluator model, which returns one of three
verdicts, each with a short reason: **not yet met**, **met**, or **impossible**. Evaluation
tokens are negligible; the condition may be up to 4,000 characters.

**⛔ `/goal` removes no human gate. ⛔** Every phase summary card and every remaining
category ask in this file stays exactly as it is. `/goal` shortens the *inside* of a
phase — the fix-and-re-run cycle — and hands control back at the same point as before.
(What removed the *per-phase* ask is `rules/autonomy.md`, not `/goal`; the two are
independent, and neither touches the hook-enforced safety checks.)

### Two properties that decide how a condition must be written

- **The evaluator has NO TOOLS.** It cannot run a command, read a file, or check a coverage
  report. It judges only what the agent already surfaced in the transcript. So a condition
  must name its own proof — "the test gate exited 0 and its output shows 0 failures", never
  "the tests are fine" or "the code is good". The corollary binds the phase, not just the
  condition: **if the phase does not print the evidence, a met condition is unprovable** and
  the loop keeps spending turns on work that is already done.
- **`/goal` carries no turn cap of its own.** The bound has to be written into the condition
  text ("…or stop after 25 turns"). It comes from the `loop:` block in `.claude/PROJECT.md`,
  clamped as the `workflow-discipline` skill §1d describes — never from a number invented at
  the point of use.

**Both clauses are ENFORCED for the goals this workflow sets, not just expected.**
`hooks/enforce-loop-bounds.sh` denies a `/goal` that sets a condition with no turn clause, no
no-progress clause, or a number outside the §1d ceilings. Know the edge of that: the hook is
registered on `CronCreate` and `Skill`, which covers a phase setting its own goal — it does
**not** see a `/goal` the user types directly, and there the bound rests on this section plus
compliance check 14's audit of the recorded bound. Note the asymmetry with `PROJECT.md`: a value on the wrong side of its clamp
there is kept and ignored, because the clamp sits behind it — the number in a condition IS the
bound, so an out-of-range one is rejected rather than clamped. And the no-progress clause has
a runtime mechanism behind it, `scripts/loop-progress-signature.sh`, which compares a
normalised failure signature (sorted failing gate names plus the top error identifier) rather
than file mtimes — an mtime detector reports a loop rewriting the same failing file as healthy
forever. Full doctrine for all three loop guards: the **`loop-design` skill**.

### Where the condition comes from

Resolve the `verification:` block in `.claude/PROJECT.md` through the registry in the
`workflow-discipline` skill §1c. The `runner` key (or, under `auto`, detection by which
manifest FILE exists) selects the ecosystem; the **registry** supplies the literal gate
strings; `gates:` narrows which of `test | lint | build` count here; `coverage_floor` gives
the number to compare against, effective value `max(80, project)`.

**⛔ Never lift a command out of `PROJECT.md`. ⛔** That file holds keys and numbers only.
A command string there would be an unreviewed code-execution path into the agent's
environment — the attack path `knowledge/toolbox-lessons.yml` TL-0005 describes and automated-review
caught on PR #58. The condition is assembled from registry strings and `PROJECT.md` numbers,
in that division, always.

A gate the resolved runner has no registry command for is **UNAVAILABLE**. Name it as
unavailable in the condition rather than dropping it, so a met verdict cannot quietly mean
"two of three gates passed and the third was forgotten".

### Two hard constraints on every condition

1. **It stops at the phase boundary.** The condition names evidence *this phase* produces and
   nothing past it. A condition reaching further ("…until the PR is open", "…until review
   passes") would let the loop drive straight through a human decision point — the one thing
   this must not do.
2. **It is cleared when the phase exits**, whichever way it exits. Run `/goal clear` (aliases:
   `stop`, `off`, `reset`, `none`, `cancel`). A goal left active carries into the next phase,
   where its condition is already satisfied and the evaluator will say so on every single
   turn. Note that a bare `/goal` **reports status — it does not clear**; and `/clear` clears
   the goal along with everything else.

### One goal per session — what a phase must check first

The platform allows exactly **one active goal per session, and setting a new one silently
replaces the active one.** So before setting a goal, the phase runs a bare `/goal` to read
the status, and then:

| Status | What the phase does |
|---|---|
| No active goal | Set the phase condition. |
| The active goal is the one an earlier phase of this run set and did not clear | Clear it, note the missed clear in the handover as a deviation, then set the phase condition. |
| The active goal is **anyone else's** — the user's, or a `/loop` body's | **Do not replace it.** Say so once, run the phase attended (the fallback below), and let the phase's existing gate end it. A user's goal outranks a phase's convenience. |

A goal is also auto-cleared when its condition is met, when it is ruled impossible, and on
unrecoverable errors (auth failure, no credit, context overflow, evaluator model
unavailable). Treat every one of those as "the phase is now attended" and continue at the
existing gate — never as a reason to re-set the goal and try again.

### When `/goal` is unavailable — fall back, never stall

`/goal` is part of the hooks system, so it is unavailable when hooks are: `disableAllHooks`
is `true`, `allowManagedHooksOnly` is set in managed settings, the workspace is not trusted
for settings-file hooks, or the runtime simply does not provide the command.

**The phase then runs exactly as it does today** — the agent drives the fix cycle itself and
stops at the phase summary card. **Fail OPEN to the human gate.** Do
not stall waiting for a goal that cannot be set, do not ask the user to enable hooks
mid-phase, and do not skip the phase because its loop is unavailable. Record one handover
line — `/goal: unavailable — <reason>; phase ran attended` — so the pre-PR compliance audit
(check 14) knows to expect the attended shape rather than a bounded iteration set.

### Unattended operation, and what actually bounds the spend

A goal **does not change the permission mode.** In manual mode the agent still asks before
each tool call, so an unattended goal loop stalls on the first prompt and nothing is gained.
Auto mode removes the per-tool prompt; `/goal` removes the per-turn prompt; the two together
are what lets the cycle run with nobody watching — which is precisely the situation the
`loop:` block's `max_spend_usd` exists for.

Be exact about what binds, though. `max_spend_usd` reaches a run through the native
`--max-budget-usd`, which is set when the run was **launched as a loop**. A `/goal` set
inside an interactive `/flow` session has no such flag, so **its only hard bound is the turn
clause in the condition text.** That is why the turn clause is mandatory rather than
decorative, and why the no-progress clause (from `no_progress_after`) is in every condition
below: those two clauses are the whole budget of an interactive goal loop.

### Two behaviours worth knowing before you trust the loop

- **Background work defers evaluation.** While a subagent or a background command is running,
  the turn is skipped and evaluation resumes when the background work finishes. In `/flow`
  that is the behaviour you want: a `[DELEGATED]` subagent is judged on what it *returned*,
  not on a half-finished transcript, so the loop's unit of iteration is one subagent
  round-trip.
- **Resuming a session restores an active goal but resets its turn count and timer.** The
  turn clause therefore bounds each resumed stretch, not the run total. Clearing at the phase
  exit is what keeps that from mattering.

### Recording it, so the compliance audit can grade it

A phase that ran under a goal writes these four things into its `.claude/handover.md` entry.
Check 14 of the pre-PR compliance audit reads them, and without them a bounded loop is
indistinguishable from redundant work:

- the exact condition string that was set;
- the effective `max_turns` and `no_progress_after` after clamping;
- how many iterations it actually took;
- the FINAL gate result per gate — passed, failed, or unavailable.

---

## Workflow

**⛔⛔⛔ CRITICAL — READ BEFORE EXECUTING ANY STEP ⛔⛔⛔**

**The orchestrator is a COORDINATOR, not a decision-maker.** Chief-of-staff (deep-reasoning tier — see `rules/performance.md`) decides which agents run and on which models. The orchestrator follows the execution plan — it does NOT:
- Select which agents or models run at any phase (chief-of-staff decides at Step 1.8)
- Select which review agents run (chief-of-staff decides again at Step 9)
- Write brainstorming analysis inline (brainstorming skill does it, on Opus)
- Write implementation plans inline (planner agent does it, on the deep-reasoning tier)
- Run acli commands directly (jira-workflow-steward does it, on Haiku)
- Write commit messages (Haiku does it)
- Decide a ticket is "too simple" for any step
- Override chief-of-staff's execution plan

**DO NOT create a git branch** until Step 7. The branch name shown in the confirmation summary is a PROPOSAL — it is not authorization to create it. Many tickets do not need a branch at all (design, requirements, verification, documentation).

**DO NOT move the ticket to In Progress** until Step 7. The ticket stays in its current column during Steps 2-6 (reading, assessment, brainstorming, planning).

**Steps 1, 1.5, and the Investigation Gate run before Step 2.** The ticket is READ (not assigned) in Step 1, investigated in Step 1.5, and the user approves findings at the Investigation Gate (Step 1.7) BEFORE assignment and Jira writes happen. Step 2 (Read and Understand Ticket) is the first post-gate user-facing assessment — it presents whether code is needed and the scope. Exception: in agent-first mode when no Jira ticket exists yet, Step 1 replaces the Step 2 gate.

**DO NOT explore the codebase or invent work** at any step. The ticket and the user define the scope. Codebase exploration happens only during Discovery (Step 1.5), Implementation Planning (Step 6), and the Streamlined-plus scope expansion grep (Step 6.5, conditional), not between other steps.

**Execution order is strict:** Step 1 (read ticket, no assign) → Step 1.5 (investigate if discovery enabled) → **Step 1.7 (Investigation Gate — user approves findings)** → Step 1.8 (assign ticket + move to Discovery + chief-of-staff creates execution plan) → Step 2 (read + assess) → user responds → Step 3 (confirmation — user confirms) → Step 4 (move to Ready for Dev) → Step 5 (brainstorm — user decides) → Step 6 (plan — user approves) → **Step 6.5 (streamlined-plus scope expansion grep — only if Step 5 or Step 6 was skipped/abbreviated)** → Step 7 (ONLY NOW create branch + move to In Progress).

**⛔ FIRST ACTIONS when a ticket is selected (before anything else): ⛔**
1. **Validate the phase map** (Step 0 above) if not already done this run — drift detection runs once per `/flow`, idempotently.
2. **Read the ticket (read-only):** `Bash(acli jira workitem view [TICKET] --json)` — note: `view` takes a positional key, NOT `--key`. Do NOT assign yet. Assignment happens at Step 1.8, after the user approves investigation findings at the Investigation Gate (Step 1.7).
3. Then proceed to Step 1.5 (Discovery investigation). For **Investigate and advance**, the discovery investigation runs as a READ-ONLY operation — no Jira writes, no assignment. After findings are presented at the Investigation Gate (Step 1.7) and the user approves, Step 1.8 assigns the ticket and applies the mapped Discovery transition. For **Skip Discovery**, the read-only investigation and gate are skipped entirely; the phase card and handover record the skip (see Step 1.5 below).

**NEVER commit directly to main.** All code changes go through a feature branch + PR. Do NOT offer "commit on main", "push to main directly", or "skip the branch" as options. The only path is: create branch → commit → push → PR. If the user explicitly asks to commit to main, warn that it bypasses code review and ask for confirmation.

**When an ask IS warranted, it MUST use the AskUserQuestion tool.** Do NOT rely on the user pressing Enter or typing free text, and never end a reply with a bare question — some environments (e.g. Claude Code side panels in IDEs) only support clickable button responses, and routing every real ask through the tool is also what lets `enforce-ask-budget.sh` see it. This governs the *form* of an ask, not *whether* to ask: `rules/autonomy.md` decides that, and most confirmations, approvals and skip/continue choices are no longer asks at all. Every remaining ask carries its category (`Irreversible` / `Scope` / `Unknown` / `Conflict` / `Blocked`) as the question header.

---

### Step 0 — Sprint Planning (Scrum boards only)

**Skip this step** if the board is Kanban or the methodology is ad-hoc. The agent detects this automatically via `Bash(acli jira board search --json)`.

**Agent:** `project-manager-senior` (Opus)

When the agent detects a Scrum board, it facilitates sprint planning before individual ticket work begins. The process varies by `jira_workflow` mode:

- **Board-driven:** Reads the backlog, estimates effort, proposes sprint scope based on team capacity (from PROJECT.md), presents the plan for user approval.
- **Agent-first:** Asks sprint goals, runs `brainstorming` + `work-breakdown` per goal, presents combined sprint plan for approval. On approval, creates beads + Jira tickets.
- **Hybrid:** Reads epics/stories from the backlog, runs `work-breakdown` to propose sub-tasks, presents plan for approval. On approval, creates sub-task beads + Jira sub-tasks.

**No escalation:** `project-manager-senior` sits on Opus outright, so complex cross-team dependency analysis needs no tier change.

After sprint planning is approved, the agent executes each ticket through Steps 1-15 below, showing progress between tickets:

```
Sprint progress: 2/4 tickets complete
  ✅ DEV-5644  Add loading spinner       PR #142
  ✅ DEV-5645  Bulk invite toast          PR #143
  → DEV-5646  Fix auth redirect          starting...
  [ ] DEV-5647  Update pipeline config

Report progress and continue in priority order — no ask. Dropping an agreed ticket, or ending
the sprint early, is a Scope ask.
```

### Step 1 — Select Task

How the agent gets its first task depends on the `jira_workflow` setting from `/init` (Q3).

### Step 1.3 — Retry Detection (after ticket selected, before Discovery)

**⛔ MANDATORY — Check if this ticket is a retry of recent work ⛔**

After the ticket is selected but BEFORE Discovery runs, check if this is a retry of a recently completed ticket. A retry reuses prior findings instead of rediscovering everything, saving ~2 minutes per run.

**How to detect a retry:**

1. **Check handover.md for recent similar tickets** (last 7 days):
   ```bash
   Bash(grep -B1 -A10 "## Discovery" .claude/handover.md | head -100)
   ```
   Look for prior tickets with similar scope — same files, same description, same acceptance criteria.

2. **Check the current ticket for retry markers:**
   - Title contains "retry of DEV-XXXX" or "redo of DEV-XXXX"
   - Description references a prior ticket (e.g. "same as DEV-5676 but...")
   - Ticket was created <7 days after a closed one with matching title
   - PR blocked/declined on a prior ticket with same scope

3. **Check Beads for related closed issues:**
   ```bash
   Bash(bd list --status closed --json | jq '.[] | select(.title | contains("[keywords]"))')
   ```

**If a retry is detected:**

Present findings to the user:
```
⚠️ RETRY DETECTED

DEV-XXXX appears to be a retry of DEV-YYYY (closed 2026-04-11).
  Prior scope: [summary from handover]
  Prior files: [files from handover]
  Prior findings: [risks, patterns identified]

Reuse prior findings?
  [E]nter — Reuse — skip Discovery, Brainstorming, Planning re-runs.
                    Verify files unchanged (git log), then proceed to
                    Implementation with prior plan.
  [F]ull  — Run full workflow — treat as a new ticket
  [P]artial — Reuse Discovery only, re-do Brainstorming and Planning
```

**If user chooses Reuse:**
- Skip Discovery (use prior findings from handover as [PRIOR CONTEXT])
- Skip Brainstorming (reuse prior approach)
- Skip Planning (reuse prior plan — planner agent VALIDATES it's still current, doesn't regenerate)
- **Run Step 6.5 (streamlined-plus scope expansion grep)** — Reuse counts as the streamlined path, so the 30-second axis grep applies before branch creation
- Go to Step 7 (Create Branch)

**If files have changed since prior ticket:**
- Warn: "Files changed since DEV-YYYY: [list]. Prior findings may be stale."
- Offer to re-run Discovery for the changed files only.

**If user chooses Full:**
- Standard workflow, no shortcuts.

**Savings on retry tickets:** ~2 minutes (Discovery ~30s, Brainstorming ~45s, Planning ~30s, plus user wait time on gates).

#### Board-driven (default)

The agent reads the Jira board configured in PROJECT.md.

- **If routed from `/start` with a specific ticket:** Use that ticket directly — skip the selection below.
- **If run directly as `/flow`:** Use **AskUserQuestion**, header `Unknown` (which ticket the user means is not inferable), to show interactive selection buttons — "Let me browse the board" or "I have a ticket ID". Then follow the same ticket presentation and JQL query rules as `/start` Step 2.5. Use `Bash(acli jira workitem search --jql "..." --fields "key,summary,issuetype,assignee,priority,status" --json)` to query tickets. The `--fields` parameter works correctly with acli — use a single query sorted by `priority DESC` with `--limit 50`. Table columns: #, Key, Type, Title, Assignee only. All priorities shown, all ticket types shown (never filter out Sub-tasks, Tests, Preconditions, or any type), grouped by board column then backlog by priority, sequential row numbers, repo mismatch notes. Epics excluded from "On the board" section (they live on separate Epic boards); shown in backlog with a note instead.
  - **If the board is empty:** Tell the user "No tickets found in Ready for Development. You can: (1) pick a specific ticket by ID, (2) switch to `/build` (no ticket needed), or (3) check a different board column." Never fail silently.

**Discovery column handling:**
- If the ticket is in a Discovery column and discovery handling has not been configured, the agent asks the Discovery question (see `/init` — Discovery Column Handling) and saves the answer to PROJECT.md.
- If discovery is set to "Investigate and advance": the agent investigates the codebase **read-only** (no Jira write), presents findings at the Investigation Gate (Step 1.7), and only after the user approves does Step 1.8 assign the ticket and apply the Discovery transition. A Jira comment is optional unless this is an explicit milestone or blocker. See Step 1.5 for the full read-only → gate → Step 1.8 sequence.
- If discovery is set to "Ask me first": the agent flags the ticket and waits for user go-ahead.
- If discovery is set to "Skip Discovery": the agent skips the Discovery column and moves the ticket directly to Ready for Development, then proceeds to Step 2. It does NOT skip the ticket entirely.

#### Agent-first

- **If routed from `/start` with a breakdown:** The agent receives the ordered task list from the `work-breakdown` skill. It picks the first task and proceeds to Step 2. The bead already exists — the agent reads it instead of creating a new one.
- **If run directly as `/flow`:** The agent asks "What do you want to build?", runs `brainstorming` for scoping, then `work-breakdown` for the breakdown. After user approval, beads and optional Jira tickets are created. The agent proceeds with the first task. When creating tickets, pass structured content (Problem, Scope, Acceptance Criteria) to `jira-workflow-steward`, which applies the Ticket Description Template (see `agents/jira-workflow-steward.md` → Ticket Description Template and `rules/agents.md` → Ticket Description Quality).

#### Hybrid

- **If routed from `/start` with a breakdown:** The agent receives the sub-task list from the `work-breakdown` skill. It picks the first sub-task and proceeds to Step 2. The bead already exists.
- **If run directly as `/flow`:** Use **AskUserQuestion**, header `Unknown`, with options: "Take next ticket from board", "Enter a specific ticket ID", "Browse the board". If the ticket is an Epic or Story type, the agent runs `work-breakdown` to propose sub-tasks. After user approval, sub-task beads and Jira sub-tasks are created. The agent proceeds with the first sub-task.
- **If the ticket is already a Task or Sub-task:** No breakdown needed — proceeds directly as in board-driven mode.

### Step 1.5 — Discovery Phase (optional)

**Column pre-condition:** None — do NOT move the ticket to Discovery before this step. Investigation is **read-only** and runs from whatever column the ticket is currently in (Backlog, Selected, etc.). The transition to the Discovery column happens at Step 1.8, only after the user approves at the Investigation Gate (Step 1.7).

This step runs for EVERY ticket that passes through Discovery — including tickets picked from Backlog. The ticket stays in its entry column throughout the read-only investigation; it is moved to Discovery at Step 1.8.

**Discovery column handling** (from PROJECT.md `discovery_handling` setting):

- **Investigate and advance** (default): Discovery investigation is **READ-ONLY** — the agent explores the codebase, reads related code and docs, and investigates the requirements, posting **no Jira comment and performing no transition or assignment** during Step 1.5. After the user approves findings at the Investigation Gate (Step 1.7), Step 1.8 assigns the ticket and applies the Discovery transition when mapped. Findings stay in the handover unless an explicit milestone or blocker update is requested.
- **Ask me first**: The agent flags the ticket — "This ticket is in Discovery. Should I investigate, or skip to Ready for Development?"
- **Skip Discovery**: The agent skips directly to Step 2 without a routine Jira comment or transition. The phase card and handover record the decision.

**⛔ INVOKE the `discovery` skill — do NOT explore the codebase inline ⛔**

**Skill:** `discovery` (Opus) — **PreToolUse hook blocks direct invocation**

The orchestrating agent MUST NOT do Discovery inline or invoke the discovery skill directly. Spawn an Opus subagent with the `[DELEGATED]` marker:

```
Agent(model: "opus", prompt: "[DELEGATED] You are a discovery subagent for DEV-XXXX. Invoke the discovery skill and follow its full process. Ticket: [title]. Description: [summary]. Explore the codebase, check history, identify risks, write findings.

Return your results in your response message. Do NOT write to .claude/handover.md — the orchestrator handles that.")
```

The `enforce-skill-delegation` hook blocks direct `Skill("discovery")` invocation via the same delegation-token requirement used for brainstorming, verification, and PR creation. One difference: those three also require chief-of-staff to have already run in the session; discovery does not, because Step 1.5 (Discovery) runs strictly before Step 1.8 (chief-of-staff's execution plan) — requiring chief-of-staff first would make that documented order unreachable. Discovery still cannot run inline — the valid-token requirement is unconditional. No text-only gaps remain.

**What the subagent does during discovery (following the discovery skill):**
1. Read the ticket description and any linked tickets
2. Explore the codebase for affected areas (grep for related functions, models, endpoints)
3. Check git history for recent changes in the affected area
4. Identify unknowns or risks that need clarification
5. Return a structured findings block to the orchestrator (this becomes the body of the Step 1.8 `phase=discovery` steward call, posted only after Investigation Gate approval — the subagent does NOT post to Jira directly, the orchestrator does via `jira-workflow-steward`):
   ```
   🔍 Discovery — Agent investigation

   **Scope:** [files, services, components affected]
   **Related code:** [key functions, classes, endpoints found]
   **Risks:** [unknowns, dependencies, potential conflicts]
   **Recommendation:** [ready for development / needs clarification on X]
   ```

**Orchestrator sequence for Investigate and advance:**

Discovery investigation is **READ-ONLY**. No `phase=discovery` call, no transition, and no assignment happen in Step 1.5 — every Jira write is deferred to Step 1.8, which runs only after the user approves at the Investigation Gate (Step 1.7). This is the no-side-effects-before-approval guarantee the gate exists to enforce, and it matches `rules/agents.md` "Jira Phase-Map Transitions" Rule 2.

1. Record `discovery_start_col` = the ticket's current column from the Step 1 read. **No Jira write.**
2. Spawn the discovery subagent (above).
3. Receive the findings block in the subagent's response. Save the findings to `.claude/handover.md`.
4. Present the findings at the **Investigation Gate (Step 1.7)** via AskUserQuestion (header `Scope`). Do NOT post to Jira yet — the gate is the mandatory stop before any write, and it is a genuine Scope ask, not a per-phase one.
5. **On Option A (user approves), proceed to Step 1.8.** Step 1.8 performs the assignment and applies the mapped Discovery transition. Findings remain in the handover unless an explicit milestone or blocker update is requested. On Option B loop back to Step 1.5; on Option C stop.

**External change detection (runs at the start of Step 1.8, before the `phase=discovery` write):** Re-read the ticket's current column via `acli jira workitem view`. The hazard being guarded against is a *backward* transition — firing `phase=discovery` when the ticket has been moved *forward or elsewhere* would yank it back to Discovery. So compare the current column against both `discovery_start_col` and the mapped Discovery column:

- **Current column == `discovery_start_col`** (no external move) OR **current column == the mapped Discovery column** (someone or automation already moved it into Discovery during the read-only investigation window) → apply `phase=discovery` normally. Both are safe: the first transitions to Discovery; the second needs no move. A comment is separate and optional.
- **Current column is some OTHER column** (moved to In Progress, Done, etc. — firing `phase=discovery` would trigger a backward move) → do NOT fire `phase=discovery`. Surface the external change and use the `edge-cases` Conflict decision before continuing. Do not create a routine findings comment.

This same external-change check also runs before the next phase-map call (Step 4 — `phase=ready_for_dev`): the check above covers the investigation window specifically; the Step 4 check covers changes between Discovery and Ready for Dev.

### Step 1.7 — Investigation Gate

**⛔ MANDATORY GATE — the agent MUST stop here and present findings before any Jira writes or ticket assignment.**

**Skip Discovery exception:** When `discovery_handling` is set to "Skip Discovery" in PROJECT.md, the Investigation Gate is skipped — proceed directly to Step 1.8. The phase card and handover record the skip; no routine Jira update is needed.

After Discovery investigation completes (Step 1.5), present findings to the user via AskUserQuestion with header `Scope` — a front-loaded **kickoff** ask (`rules/autonomy.md`): it settles what the work covers before the first Jira write, and it is one of only two gates in `/flow` that waits (the other is the confirmation summary):

```
-----------------------------------------
  Discovery Findings — [TICKET-ID]
-----------------------------------------
  Scope:        [files, services, components affected]
  Related code: [key functions, classes, endpoints found]
  Risks:        [unknowns, dependencies, potential conflicts]
  Recommendation: [ready for development / needs clarification on X]
-----------------------------------------

  Options:
  [A] Proceed — assign ticket, move to Discovery, continue workflow
  [B] Keep investigating — go back to Step 1.5 with new direction
  [C] Skip this ticket — pick a different one
-----------------------------------------
```

- **Option A:** Proceed to Step 1.8 (assign ticket, apply the mapped transition, create execution plan)
- **Option B:** Loop back to Step 1.5. The agent asks: "What should I investigate next?"
- **Option C:** Stop work on this ticket. Pick next ticket or end.

**Why this gate exists:** In previous sessions the agent assigned tickets, created branches, and posted Jira comments before the user saw any investigation findings. This gate ensures the user sees what was found and decides whether to proceed — no side effects until they approve.

**⛔ BLOCKING — before proceeding to Step 1.8:**
1. Investigation findings presented to user
2. User responded via AskUserQuestion with Option A
3. Handover entry for Discovery phase written

### Step 1.8 — Assign, Discovery Transition, and Execution Plan

**⛔ MANDATORY — runs only AFTER the Investigation Gate (Step 1.7) is passed ⛔**

**Part 1 — Assign and apply the Discovery transition:**

**Jira delegation token:** `touch ~/.claude/.jira-delegation-token`

**Skip Discovery exception:** when `discovery_handling` is "Skip Discovery", there was no read-only investigation. Do NOT run the Discovery transition; only assign the ticket, then proceed to Part 2.

1. **External change detection (before any write):** re-read the ticket's current column via `acli jira workitem view` and apply Step 1.5's "External change detection" rule. If the ticket is still in `discovery_start_col` or has been moved into the mapped Discovery column, continue to step 2 and apply the transition if needed. If it was moved elsewhere, run the **Conflict** decision before continuing; do not post a routine findings comment.
2. **Assign the ticket** to the current user: spawn `jira-workflow-steward` (Haiku) with `acli jira workitem assign --key [TICKET] --assignee @me -y`
3. **Apply Discovery transition:** spawn `jira-workflow-steward` (Haiku) with `phase=discovery`. Pass a milestone body only if the orchestrator explicitly requests one.

**Part 2 — Chief-of-staff execution plan:**

**Agent:** `chief-of-staff` (Opus deep-reasoning tier, from frontmatter — see rules/performance.md) — spawn with `subagent_type: "chief-of-staff"` and **no `model:` argument**. This is our own vendored agent (`agents/chief-of-staff.md`) — not the upstream ECC agent, which was repurposed into a comms-triage bot.

After assignment and the mapped Discovery transition, spawn chief-of-staff to produce the **execution plan** for this ticket. Chief-of-staff reads the ticket context and Discovery findings, then assigns the correct agent and model for every phase.

```
Agent(
  subagent_type: "chief-of-staff",
  prompt: "You are the chief-of-staff for DEV-XXXX. Create an execution plan for this ticket.

Ticket: [title and description]
Discovery findings: [summary from Step 1.5, or 'Discovery skipped']
Files likely affected: [from Discovery, or 'TBD']

Produce an execution plan assigning the correct agent and model for each phase.
Use this reference for agent/model assignments:

FIXED ASSIGNMENTS (every ticket):
- Discovery: Explore subagent (Opus)
- Assessment: Main agent (orchestrator tier — whatever the session model is)
- Brainstorming: brainstorming skill via an Opus subagent [DELEGATED]
- Planning: planner agent (Opus deep-reasoning tier, from frontmatter — no spawn-time model argument)
- Implementation: Opus subagent
- Verification: verification-before-completion skill via an Opus subagent [DELEGATED]
- PR Creation: finishing-a-development-branch skill via an Opus subagent [DELEGATED]
- Jira ops: jira-workflow-steward (Haiku) — ALL acli commands
- Commits: Haiku
- Doc updates: doc-updater (Haiku)

CONDITIONAL ASSIGNMENTS (based on files changed) — REVIEW-RELEVANT SUBSET;
the authoritative 10-row table is in the agent-orchestration skill,
"Conditional Agents" (also covers: major architecture change → architect +
planner; /perf workflow → performance-benchmarker; library/framework
questions → docs-lookup; any Jira task → jira-workflow-steward). Read it
before finalizing the plan:
- *.razor, *.blazor, *.tsx, *.jsx, *.html → evidence-collector (Sonnet) + accessibility-auditor (Opus) <!-- tier-ok: evidence-collector Sonnet + accessibility-auditor Opus, both correct -->
- *Migration*, *DbContext* → database-reviewer (Opus)
- *Controller*, *Endpoint* → api-tester (Opus) + security-reviewer (Opus)
- appsettings*, *auth*, secrets → security-engineer (deep-reasoning tier) + security-reviewer (Opus)
- *Pipeline*, *.yml → devops-automator (Opus)

ALWAYS RUN AT CODE REVIEW:
- tdd-guide (Opus)
- code-reviewer (Opus)
- reality-checker (Opus) — always last

Return the plan as a numbered list with agent and model for each phase.
Flag any phases that should be SKIPPED for this ticket and why.
Flag any ADDITIONAL agents needed beyond the fixed list."
)
```

**The execution plan is the single source of truth for this workflow run.** The orchestrator follows it exactly — no overrides, no shortcuts, no "this ticket is simple enough to skip X."

Chief-of-staff's plan may differ from the static table when:
- A phase should be skipped (e.g., "no code changes needed → skip implementation")
- Additional agents are needed (e.g., "auth code changed → add security-engineer")
- The ticket is an epic requiring architect (deep-reasoning tier) before planning

**Save the execution plan** to `.claude/handover.md` under `## Execution Plan — /flow [TICKET]`. The compliance check at Step 15 verifies each phase was executed according to this plan.

**Cost:** ~500 tokens on the deep-reasoning tier. This is non-negotiable overhead — the same way you always run tests even for "simple" changes. Chief-of-staff is spawned again at Step 9 (code review) to select review agents based on actual file changes.

**⛔ MANDATORY GATE — phase summary card before Step 2 ⛔**

Step 1.8 is a phase like any other (see "Phase Summaries and User Decision Points" above) — it does not get to hand off to Step 2 silently just because it produced a plan instead of a Jira transition. Append the Execution Plan entry to `.claude/handover.md` first, then show the card. What is mandatory is the **card**, not a question: under `rules/autonomy.md` the agent shows it and proceeds unless the plan raised a category question (or Status is BLOCKED).

```
-----------------------------------------
  Phase: Execution Plan
  Status: PASSED / PASSED WITH NOTES / BLOCKED
-----------------------------------------
  Agent:  chief-of-staff
  Model:  Opus (deep-reasoning tier) — Expected: Opus (chief-of-staff frontmatter) → match/VIOLATION
  Skill:  none — chief-of-staff is spawned directly at this step (see rules/agents.md "Chief-of-staff spawn points")
  Rules:  rules/agents.md "Orchestration — four roles"; rules/performance.md "The four tiers"
-----------------------------------------
  Summary:
  - [phases chief-of-staff assigned agents/models for, and any deviations from the static table]
  - [additional agents flagged, e.g. "auth code changed → add security-engineer"]
  - [any phases flagged for skip, and why]

  Jira:   [comment posted ✅ / n/a — toolbox self-change] — this phase has no jira_phase_map key of its own
          (phase-map key is "(no transition)"); the Jira write already happened as part of
          Step 1.8 Part 1's phase=discovery comment, which covers assignment + the execution plan handoff.
  Opinion: [agent's honest assessment of the plan — concerns, risks, or "No concerns"]

  Next: Step 2 — Read and Understand Ticket

  Proceeding to Step 2. (Interrupt to revise or stop.)
-----------------------------------------
```

Show the card, then proceed to Step 2. This closes the exact gap that Step 1's Investigation Gate (Step 1.7) and Step 2's own gate bracket — without this card, the execution plan the rest of the workflow treats as "the single source of truth" would be the only phase artifact the user never actually **sees**.

**⛔ BLOCKING — before proceeding to Step 2:**
1. Execution Plan phase card presented to user
2. **Append that gate evidence to the `## Execution Plan` handover entry** (e.g. "Execution Plan phase summary card presented to user")
3. The gate resolved — either the user answered a category ask, or the agent auto-continued under the autonomy rule
4. **Append how it resolved to the `## Execution Plan` handover entry** — EITHER `User approved via AskUserQuestion — Option 1 Continue` OR `auto-continued under autonomy rule` (`rules/autonomy.md`). **Both are valid gate evidence**, and Step 15's compliance check (item 2, Plan compliance) accepts either. What the audit requires is that the card was shown and the outcome recorded; it does NOT require that a question was asked. Recording nothing is still a FAIL — a correctly-run autonomous gate must say so in one line, so the audit has something to read back.

### Step 2 — Read and Understand Ticket

**Column pre-condition:** Ticket MUST be in **Discovery** (Step 1.8 moved it there after the Investigation Gate) or **Ready for Development** (if Discovery was skipped). Verify with `acli jira workitem view [TICKET] --fields status --json`. If wrong, move it first.

**⛔ RULE: READING THE TICKET IS THE FIRST PRIORITY ⛔**

The agent MUST read and understand the ticket context before taking ANY action — no branch, no status transition, no Jira comment, no brainstorming. Many tickets do not need code: design tickets, business logic clarifications, requirements, verification-only tickets, documentation requests. The agent cannot know this without reading the ticket first.

**Note:** Ticket assignment already happened at Step 1.8 (after the Investigation Gate). If for some reason it didn't, assign now: `Bash(acli jira workitem assign --key DEV-XXXX --assignee @me -y)`

**⛔ MANDATORY — Read the full ticket ⛔**

1. **Fetch the full ticket** via `Bash(acli jira workitem view DEV-XXXX --json)` — description, comments, linked tickets, acceptance criteria. Note: `view` takes a positional key, NOT `--key`.
2. **Understand the context** — what is being asked, what files/services are involved, what the acceptance criteria are
3. **Decide if code is needed** — not all tickets require code. Examples of no-code tickets:
   - Verification/test tickets (acceptance criteria already met)
   - Design or UX tickets (Figma/Miro deliverables, not code)
   - Business logic clarifications (answer goes in a Jira comment, not a branch)
   - Requirement/discovery tickets (research output, not implementation)
   - Documentation tickets (Confluence/wiki updates, not code changes)

**⛔ MANDATORY GATE — Present ticket assessment before proceeding ⛔**

After reading the ticket, the agent MUST present its assessment to the user. This applies EVERY time — not just when no code is needed. **Showing it is the requirement; waiting is not.** The assessment is a window into what the agent understood, and reporting it is what lets the user interrupt on a misread. Step 2 below says when this becomes an actual ask: only when code is NOT needed (or that is unclear), which is a **Scope** question. Otherwise show the assessment and proceed to Step 3.

(This paragraph used to require a response every time, which contradicted Step 2's "proceed to Step 3" two screens down. The agent cannot obey both, and under `rules/autonomy.md` the ask has no category — the ticket already defines the scope.)

The agent MUST follow these steps in order:

1. Present the assessment:
   ```
   Ticket Assessment — DEV-XXXX

   What's being asked: [1-2 sentence summary of the requirement]
   Acceptance criteria: [list from ticket, or "None specified"]
   Files/services likely affected: [list, or "TBD — will identify during design"]
   Code changes needed: Yes / No — [brief reason]
   Proposed branch: feature/DEV-XXXX-slug-from-title (only if code needed)
                    N/A — no branch needed (if design/docs/verification only)
   ```

**Branch proposal:** This is where the agent FIRST proposes a branch — not in the /start confirmation summary. The branch is proposed HERE because this is where the agent has read the ticket and decided whether code is needed. The branch is still not created — that happens at Step 7.

**Test-Only Classification:** If the ticket is about adding test coverage for existing code (no new features, no bug fixes, no refactoring), set `test_only: true` in the workflow context and show in the assessment: "Type: Test-only (no production code changes allowed)". This flag restricts what files can be modified during Implementation and what the PR can contain. Indicators: ticket title mentions "add tests", "test coverage", "unit tests for"; no new features or behaviour changes described; ticket explicitly says "no production code changes". The user says "we don't want to release any production code" or similar.

2. **If code IS needed:** show the assessment and **proceed to Step 3** (autonomy rule) — the ticket already defines the scope, so there is nothing here the user has to decide. Ask only if the assessment itself surfaced a category question.

3. **If code is NOT needed (or unclear):** this IS a category ask (**Scope** — the agreed goal may not be the work), so use **AskUserQuestion** with header `Scope` and options:
   - "Run brainstorming" — explore what this ticket actually needs before deciding
   - "Move to Done" — mark as complete without any further work
   - "Pick a different ticket"

   The default is "Run brainstorming". Brainstorming is valuable even for non-coding tickets — it clarifies scope, asks what "verify" or "investigate" means, and prevents the agent from guessing.

   **⛔ THE AGENT MUST NOT INVENT SCOPE ⛔** If the ticket description does not contain specific instructions, the agent MUST ask the user (via brainstorming) what to do. The agent MUST NOT explore the codebase looking for things to improve, create test files, refactor code, or invent work that the ticket did not ask for. The ticket and the user define the scope — not the agent.

**⛔ When an ask IS warranted it MUST use the AskUserQuestion tool ⛔** — do NOT rely on the user pressing Enter or typing free text. Some environments (e.g. Claude Code side panels in IDEs) only support clickable button responses, and the tool is also where `enforce-ask-budget.sh` can see the ask. Whether to ask at all is decided by `rules/autonomy.md`.

**The agent MUST NOT do any of the following until the assessment is shown:**
- Create a branch
- Move the ticket to any column (no Jira transition)
- Add a Jira comment (except the assignment + discovery comment already done at Step 1.8)
- Start brainstorming or planning
- Proceed to Step 3 (Confirmation Summary)

The branch name from `/start`'s confirmation summary is a **proposal** — not authorization to create it. Branch creation happens at Step 7.

### Step 3 — Confirmation Summary

**If routed from `/start`:** The user already confirmed the summary in `/start` Step 5. Skip showing it again — proceed directly to Step 4. Do NOT silently skip without mentioning it — say "Confirmation already done in /start, proceeding to Ready for Development."

**If run directly as `/flow`:** Show the confirmation summary (see `/start` — Step 5). The summary includes a Columns field showing the kanban lifecycle path for this ticket.

**⛔ The Columns field MUST be derived from PROJECT.md `jira_phase_map` — NEVER hardcode or guess column names. ⛔**

Show the columns this ticket will pass through, derived from the phase map: take the unique non-null values from `jira_phase_map` in phase order (`discovery → ready_for_dev → in_progress → code_review → ready_for_release → done`) and dedupe (so a board where Code Review reuses In Progress shows In Progress only once). If `jira_phase_map` is not set, run Step 0 first (which migrates legacy `jira_columns` if present, or runs anchor questions). If the user edits the Columns field, only offer the columns currently in the phase map — never offer made-up columns like "In Review" if they don't exist on the board.

**This is the ONE front-loaded kickoff ask** (`rules/autonomy.md` → Front-load and batch): use **AskUserQuestion** with header `Scope` and options "Confirm and proceed", "Edit summary", "Cancel", and wait for the answer. Every foreseeable category question belongs HERE and nowhere later — target branch if the user has not stated one, the scope boundary, the streamlined-path offer, and any irreversible step the plan already contains. Later phases show cards and proceed.

The agent generates:
- Proposed branch name from ticket: `feature/DEV-XXXX-slug-from-title` (branch is NOT created yet — just proposed)
- Beads issue (if tracking enabled)
- Skip list based on ticket type and workflow

**After user confirms:** Proceed to Step 4. (Ticket assignment already happened at Step 1.8.)

### Step 4 — Ready for Development transition

**Jira delegation token:** `touch ~/.claude/.jira-delegation-token`

**Phase-map handling:** spawn `jira-workflow-steward` with `phase=ready_for_dev` when the board
transition is needed. The steward looks up `jira_phase_map.ready_for_dev` and applies the live
board mapping. Do not attach a routine phase comment; the implementation Start milestone is
posted once, when work actually begins.
- **No branch is created at this step** — branches are created at Step 7 (In Progress) when actual coding begins
- **Board-driven:** If Beads is enabled in PROJECT.md, create a Beads issue:
  1. Check if `.beads/` exists. If NOT, run the `bd init` the gitignore pre-check script in the **`workflow-discipline` skill** (§ "Gitignore pre-check") (verify gitignore + no tracked files); only if the pre-check passes, run `Bash(bd init)` (automatic, don't ask). If the pre-check fails, warn the user and continue without Beads — **skip steps 2-5 entirely**.
  2. **⛔ Do NOT commit `.beads/` here — Step 4 happens BEFORE Step 7 (branch creation), so the current branch is still `main` (or whatever the user was on when they ran `/flow`). Committing now would put the `.beads/` directory on `main` ahead of `origin/main`, which violates `rules/git-workflow.md` "Never commit to main". ⛔** The `.beads/` directory stays uncommitted in the working tree until Step 7. When Step 7 creates the feature branch from `origin/main`, uncommitted files travel into the new branch and get committed in the first feature commit. If the working tree already had uncommitted files from `/init` (for example `.gitignore` changes), they ride along the same way.
  3. Check for existing issue: `Bash(bd ready --json)` — if one exists for this ticket, use it instead of creating a duplicate.
  4. Create the issue (if no existing): `Bash(bd create --title "[TICKET] [title]" --type task --priority 2 -d "[description]")`
  5. Update status: `Bash(bd update [BEAD_ID] --status in_progress)`

  **⛔ Beads command reference (do NOT guess flags): ⛔**
  - `bd init` — initialize `.beads/` in project
  - `bd create --title "..." --type task --priority 2 -d "..."` — create issue (NO `--status` flag on create)
  - `bd update [ID] --status [open|in_progress|done]` — change status
  - `bd close [ID]` — close issue
  - `bd ready` — list unblocked issues
  - `bd show [ID]` — view issue details

  **⛔ Beads lifecycle — update at each milestone, not just create: ⛔**
  - **Step 4 (Ready for Dev):** `bd create` + `bd update [ID] --status in_progress`
  - **Step 7 (In Progress):** no Beads action needed (already in_progress)
  - **Step 15 (PR created):** `bd close [ID]` with a summary of what was done
  - If the session is interrupted before PR, leave the issue open — next session picks it up via `bd ready`
  - **Use `bd remember` for cross-session insights** — observations like "this ticket duplicates DEV-XXXX", "PR #43 is blocked", or "integration tests require external API" should be saved with `bd remember` so future sessions don't rediscover them

  **⛔ Do NOT run `.beads/` check in parallel with Jira transitions. Run sequentially: check → init → create → then continue with Jira. ⛔**
- **Agent-first / hybrid:** The bead already exists (created during `work-breakdown`). The agent reads the existing bead and updates its status to in-progress.

### Step 5 — Brainstorming

**Column pre-condition:** Ticket MUST be in **Ready for Development**. Verify before starting.

**⛔ INVOKE the `brainstorming` skill — do NOT do brainstorming inline ⛔**

**Skill:** `brainstorming` (Opus)

**⛔ MODEL ROUTING: Brainstorming MUST run on an Opus subagent, not inline on the orchestrator ⛔**

The orchestrating agent MUST NOT invoke the brainstorming skill directly — a **PreToolUse hook blocks it**. Instead, spawn an Opus subagent with the `[DELEGATED]` marker:

```
Agent(model: "opus", prompt: "[DELEGATED] You are a brainstorming subagent for DEV-XXXX. Invoke the brainstorming skill and follow its FULL Socratic process: ask clarifying questions first, then present design decisions in chunks. Do not skip any steps.

Return your results in your response message. Do NOT write to .claude/handover.md — the orchestrator handles that.")
```

**The `[DELEGATED]` marker is required.** The PreToolUse hook checks for this marker to distinguish subagent invocations (allowed) from direct orchestrator invocations (blocked). Without the marker, the hook blocks the skill.

The agent MUST invoke the brainstorming skill, not write its own brainstorming analysis. The skill has a specific Socratic design refinement process that MUST be followed in full:
1. **Ask clarifying questions** about the ticket requirements (do NOT skip this — even if the ticket seems clear)
2. Presents design decisions in chunks for user approval
3. Does not write any code yet — this is design only
- Present the design direction, then **proceed to Step 6** (autonomy rule) — the user interrupts to revise or start over. The skill's own clarifying questions still run in full: those are Unknown asks about what the ticket means, which is exactly what a category ask is for

**⛔ DO NOT SHORTCUT THE SOCRATIC PROCESS ⛔**
The brainstorming skill requires clarifying questions BEFORE presenting approaches. Skipping straight to "Here are two approaches:" is a violation — even if the ticket seems well-understood from Discovery. The skill's own anti-pattern table warns: *"'Simple' projects are where unexamined assumptions cause the most wasted work."*

**⛔ BRAINSTORMING IS MANDATORY — THE AGENT CANNOT SKIP IT ⛔**
The agent MUST run brainstorming for every ticket that reaches this step. The agent does NOT get to decide a ticket is "trivial" — only the user can skip brainstorming. That offer is a **kickoff** ask, front-loaded once at `/start` (`rules/workflow-discipline.md` Rule 1): **AskUserQuestion** with header `Scope` and options "Run brainstorming", "Skip brainstorming — I know what I want". The default is "Run brainstorming".

⛔ **A standing autonomy declaration does NOT count as the user having chosen the streamlined path, and neither does the agent judging the ticket a good fit.** This line used to say it did, which contradicted `rules/workflow-discipline.md` Rule 1 — and the command is what executes, so the contradiction reintroduced the "/flow invented scope" path the rule exists to close. The only non-user route is an explicit `streamlined_default: true` in `.claude/PROJECT.md`, which is the user's own recorded standing choice rather than the agent's reading of a ticket. Record which route applied in the handover.

### Step 6 — Implementation Plan

**Column pre-condition:** Ticket MUST be in **Ready for Development**. Verify before starting.

**⛔ SPAWN the `planner` agent (deep-reasoning tier) — do NOT write the plan inline ⛔**

**Agent:** `planner` (Opus deep-reasoning tier, from frontmatter — see rules/performance.md) — spawn with `subagent_type: "everything-claude-code:planner"` and **no `model:` argument**

The planner agent MUST be spawned to create the implementation plan. The orchestrator must not write the plan itself — the planner runs on the deep-reasoning tier and has a specific planning methodology:
- Exact file paths to create or modify
- Phases with dependencies (what must be done before what)
- Verification steps for each phase
- Estimated number of subagent tasks

The plan is presented to the user, then the agent **starts on it** (autonomy rule) — the user interrupts to revise or pick a different approach. Ask only if the plan needs work the agreed goal does not cover (**Scope**) or names something irreversible.

### Step 6.5 — Streamlined-plus Scope Expansion Check

**Conditional:** This step runs ONLY when the streamlined path was chosen — i.e., the user skipped brainstorming at Step 5 ("Skip brainstorming — I know what I want") OR planning was reused/abbreviated (retry-detected reuse, no full planner agent run). If the full path was taken (full brainstorming + deep-reasoning-tier planner), skip Step 6.5 entirely — the planner already surfaces cross-file callsites that branch on the same axis.

**Purpose:** Catch the latent-bug class on small correctness-sensitive changes without paying for the deep-reasoning-tier planner. The full planner spends ~5 minutes (~$0.10+ in deep-reasoning-tier tokens) to surface cross-file callsites that branch on the same axis as the change. For config additions, env keys, feature flags, enum values, and status columns, the same value can be obtained with a 30-second grep.

**Cost:** <30 seconds — bash plus one State-block line. **NOT an agent invocation, and normally not a question either.**

**Why this exists (TASK-738 retrospective):** A 6-line config change (adding `net8` to a feature-flag environment map) had 3 latent callsites in cleanup scripts (`stale-board-members.ts`, `stale-scheduled-emails.ts`, `stale-signatures.ts`) where `env === 'dev' ? portal-dev : portal-stage` ternaries silently fell through to portal-stage on `net8`. Streamlined was the right path — full /flow would have spent ~25 minutes on brainstorming/planning/multi-agent-review for what was essentially a config addition. But the planner WOULD have caught those 3 callsites with a `grep -rn "TEST_ENVIRONMENT"`. Step 6.5 captures that 30-second grep without paying for the planner.

#### Process

1. **Identify the change's axis** — the variable, env key, feature flag, status enum, or config name being added or modified. The orchestrator does this inline using the ticket description and Assessment summary as context. Examples:

   | Change type | Axis to grep |
   |---|---|
   | Adding new env (e.g. `net8`) to a config map | The env-key variable (e.g. `TEST_ENVIRONMENT`) **AND** the new env value as a string literal (e.g. `'net8'`) |
   | Adding a feature flag | The flag name **AND** the flag-config map type/interface name |
   | Adding a status enum value | The enum name **AND** status-comparison sites (e.g. `=== 'StatusName'`, `switch (status)`) |
   | Adding a column to a status table | The column name **AND** any select/insert/update queries referencing that table |
   | Adding a config key | The config object/interface name **AND** the config-key string |
   | Adding a new role/permission | The role/permission constant **AND** access-check call patterns |
   | Renaming an identifier | The OLD name (callsites still using it) **AND** the NEW name (verify no collisions) |

   If the change does not fit any pattern above (e.g. pure refactor, new isolated file, doc-only), the orchestrator MAY skip Step 6.5 — but it MUST tell the user it skipped and why ("No axis to grep — this change adds an isolated file with no cross-file branching"). The orchestrator does NOT silently bypass the step.

2. **Run the grep** — prefer ripgrep (`rg`) if available, fall back to `grep -rn`:

   ```bash
   # Detect ripgrep, fall back to grep. Use -F (fixed-string) to avoid
   # regex metacharacter issues with axis values containing . + ? [ ] etc.
   # Exit code 1 = no matches found — this is a NORMAL outcome (no callsites),
   # not an error. Only exit code >= 2 indicates an actual grep failure
   # (permission denied, invalid args, etc.) and must be reported.
   #
   # The `|| GREP_RC=$?` pattern is set -e safe: if the command succeeds
   # (exit 0), GREP_RC stays 0; if it fails (exit 1 or 2+), the || clause
   # runs and captures the actual exit code without aborting the script.
   GREP_RC=0
   if command -v rg &>/dev/null; then
     rg -nF "<axis-pattern>" --hidden -g '!node_modules' -g '!.git' -g '!dist' -g '!build' -g '!*.lock' -g '!*.min.*' . || GREP_RC=$?
   else
     grep -rnF "<axis-pattern>" \
       --exclude-dir=node_modules --exclude-dir=.git \
       --exclude-dir=dist --exclude-dir=build . || GREP_RC=$?
   fi
   # Exit code 0 = matches found, 1 = no matches (both normal).
   # Exit code >= 2 = actual grep failure — warn the user.
   if [[ $GREP_RC -ge 2 ]]; then
     echo "⚠️ grep failed with exit code $GREP_RC — check permissions or command syntax"
   fi
   ```

   Replace `<axis-pattern>` with the axis identifier. Use `-F` for fixed-string matching. Run grep for each axis if multiple were identified. Time-box to 30 seconds. Exit code 0 = matches found, 1 = no matches (normal — nothing to report), ≥ 2 = actual failure (warn user).

3. **Summarise callsites** to the user — list every file:line that references the axis, NOT just the originally-modified file. Highlight callsites that look like ternaries, switches, equality checks, or conditional logic — those are the candidates for latent bugs.

   Example summary (TASK-738 style):
   ```
   Streamlined-plus scope expansion — axis: TEST_ENVIRONMENT

   Originally-modified file (in PR scope):
   - e2e/helpers/feature-flags.helper.ts:42 — adding 'net8' entry to env map ✅

   Other callsites that branch on TEST_ENVIRONMENT:
   - e2e/cleanup/stale-board-members.ts:18 — ternary: env === 'dev' ? portal-dev : portal-stage
   - e2e/cleanup/stale-scheduled-emails.ts:22 — same pattern
   - e2e/cleanup/stale-signatures.ts:15 — same pattern

   ⚠️ These 3 callsites silently fall through to portal-stage on the new 'net8' env.
   Likely class: latent ternary fall-through.
   ```

4. **Apply the stated default — do NOT ask** (`rules/development-workflow.md` Step 1a, `rules/autonomy.md`): **"Out of scope — file followup"**. Surfacing the latent class without forcing scope creep is the safest default, and picking it is the agent's call. Report the callsites and the followup ID in the State block.

   Ask (header `Scope`) in exactly one case: a callsite makes the change **wrong as shipped**, so the original PR cannot land correctly without it. Then the three options are:
   - **"In scope — extend this PR"** — extend the implementation to cover the additional callsites in this branch
   - **"Out of scope — file followup"** — keep this PR strictly to the original change; the orchestrator files a local Beads issue for the additional callsites (and, if Beads is unavailable, records the followup in the handover rather than opening a Jira ticket)
   - **"Skip — intentionally different"** — the additional callsites are intentionally different from this change (no action, no followup; record reason in handover)

5. **Apply the decision** before proceeding to Step 7:

   - **Out of scope (the default, and the normal path):** Create a **Beads** issue capturing the latent callsites with `file:line` references — Beads is local, so filing one is not an outward-facing act. Beads issue title format: `Followup from [TICKET-ID]: align <axis> branching across <N> callsites`. Body lists the callsites and links the original ticket (the PR doesn't exist yet — Step 6.5 runs before branch creation at Step 7). Use `Bash(bd create ...)`. **If Beads is unavailable, do NOT auto-create a Jira ticket** — record the followup in `.claude/handover.md` and surface the callsites in the State block instead. A Jira issue is an outward-facing artifact other people see, so it is created only on an explicit instruction, via `jira-workflow-steward` (Haiku). Then proceed to Step 7.
   - **In scope:** Add the additional callsites to the Assessment + handover. Update the proposed file list. Then proceed to Step 7. Implementation will cover them.
   - **Skip:** Record in handover ("Step 6.5: User declared the additional callsites intentionally different — no followup needed. Reason: [user's reason if given]"). Then proceed to Step 7.

6. **Append Step 6.5 outcome to handover** — single line under the existing Planning entry:
   ```
   ### Step 6.5 — Streamlined-plus Scope Expansion
   - Axis: <axis>
   - Callsites found: <N> (originally-scoped: 1, additional: N-1)
   - Decision: In scope / Out of scope (Beads BD-XXX) / Skip
   ```

#### Hard rules

**⛔ DO NOT spawn an agent for Step 6.5 ⛔**
The whole point is cheap. Spawning any agent (Opus planner, code-reviewer, search-specialist) defeats the purpose. The orchestrator runs grep inline, summarises, and **states the decision** — it does not ask one as a matter of course (step 4 above). Total cost target: <30 seconds + ~500 tokens.

**⛔ DO NOT skip Step 6.5 silently ⛔**
If the streamlined path was chosen and the change fits any axis pattern (config, env key, feature flag, enum value, status column, role/permission, identifier rename), the orchestrator MUST run the grep. The orchestrator does NOT get to decide "this looks safe without grep." The grep IS the entire safety net for skipping the planner — without it, latent-bug classes ship to PR.

**⛔ Step 6.5 is NOT a license to scope-creep ⛔**
The default decision is "Out of scope — file followup", and the orchestrator applies it. What the orchestrator must NOT do is talk itself into "In scope" — widening the PR is the move this guard exists to stop, and that one goes to the user as a **Scope** ask (step 4). The asymmetry is deliberate: the agent may pick the narrow default alone; it may not pick the wide one alone.

**Exit:** Decision applied — the default, or the user's answer to the Scope ask if step 4's one condition was met. Local Beads followup created if applicable (never an auto-created Jira ticket). Handover updated. Proceed to Step 7.

### Step 7 — Create Branch and Start Implementation

**Jira delegation token:** `touch ~/.claude/.jira-delegation-token`

**Phase-map handling:** spawn `jira-workflow-steward` with `phase=in_progress`. The agent applies
the live board mapping. Post the single concise Start milestone here if it has not already been
posted; otherwise perform only the requested transition.

**External change detection:** Runs before this phase-map call (the agent re-reads the ticket inside `jira-workflow-steward`).

- **Branch from `origin/main`, not from local `main`.** Local `main` may be ahead of `origin/main` (e.g. an old `/init` run that auto-committed setup files there — pre-fix behaviour). Branching from local `main` would carry those orphan commits into the feature branch and mix toolbox setup with the feature change in the PR. Branching from `origin/main` keeps the feature branch clean.
  ```bash
  Bash(git fetch origin --quiet)
  Bash(git checkout -b feature/DEV-XXXX-slug-from-title origin/main)
  ```
  **Working-tree handling:** `git checkout -b <new> origin/main` keeps uncommitted files in the working tree — they're not on any branch yet, so they ride along onto the new branch. Setup files left over from `/init` (`.beads/`, `.gitignore` changes) are picked up in the first feature commit. Nothing is committed to `main`.
  **If local `main` is ahead of `origin/main`:** That's a sign of a previous violation (likely an old `/init` or `/flow` Step 4 commit before this fix landed). Tell the user: "Your local `main` has N commit(s) ahead of `origin/main`. Branching from `origin/main` so this PR stays clean. Resolve the orphan commit(s) on `main` separately — likely candidates: revert with `git reset --hard origin/main`, or move them onto a `chore/toolbox-setup` branch with `git branch chore/toolbox-setup` then `git reset --hard origin/main`."
- Optional Start milestone: `Started: implementation of <ticket objective>.`
  Keep the Jira text to one short sentence; branch, files, TDD details, and plan remain in the
  handover and PR.

### Step 7.5 — Git Worktrees (if applicable)

**Skill:** `using-git-worktrees` (when multiple independent tasks exist)

If the implementation plan has multiple independent tasks that can be parallelised, the agent decides and states it — parallel-vs-sequential is sequencing, never an ask: `Decided: [N] parallel worktrees for [N] independent tasks. (Say "switch" to run them sequentially.)` Worktrees are cheap and removable, so no approval is needed; the State block carries one line per worktree.

If parallel worktrees are selected:
- Each worktree gets its own subagent
- Dependent tasks remain sequential

If all tasks are sequential, this step is skipped.

### Step 8 — Subagent Execution

**Column pre-condition:** Ticket MUST be in **In Progress**. Verify before starting.

**⛔ Implementation MUST be executed by Opus subagents — NOT inline by the orchestrating agent. ⛔**

Spawn subagents to execute the implementation plan tasks. This is mandatory even for single-file changes — the subagent runs on Opus and keeps the orchestrating agent's context clean.

For each task:
1. Implement the code changes
2. `tdd-guide` (Opus) enforces RED -> GREEN -> REFACTOR — no task completes without passing tests
3. Return results in response message — the orchestrator appends to `.claude/handover.md` (Single-Writer Rule)

**Skills active during execution:**
- `test-driven-development` — strict RED-GREEN-REFACTOR with anti-rationalisation
- `receiving-code-review` — technical evaluation of review feedback (no performative agreement)
- `tdd-workflow` — TDD methodology reference
- `coding-standards` — best practices, immutability
- `backend-patterns` — API, DB, caching, repository patterns (if backend files touched)
- `frontend-patterns` — React/Next.js patterns (if frontend files touched)
- `verification-loop` — continuous verification during development
- `api-design` — REST/GraphQL patterns (if API files touched)
- `e2e-testing` — E2E testing patterns
- `continuous-agent-loop` — manages long-running loops (if task is complex)

**Agent available on demand:**
- `docs-lookup` (Sonnet) — any agent can invoke this to query library documentation via Context7 MCP instead of relying on training data

#### Step 8a — `/goal` on the implementation gate cycle

The exit condition of this phase is machine-checkable: the plan's tasks are implemented and
the project's gates come back green. Set a `/goal` at the START of the phase so the
fix-and-re-run cycle does not need a human watching it. **Read the
"`/goal` — Machine-Checkable Phase Exits" section above first** — it carries the
one-goal-per-session check, the `/goal clear` obligation, the unavailable-fall-back, and why
the turn clause is mandatory. All of it applies here unchanged.

**Resolve the gates first.** `verification.runner` + the registry in the
`workflow-discipline` skill §1c give the literal strings; `verification.gates` says which
count. Never read a command from `PROJECT.md`. `<resolved gate list>` is the literal registry
command for each gate `verification.gates` names — no gate the project did not configure, and
none of its configured gates dropped.

**The condition template.** Substitute the resolved gate strings and the clamped `loop:`
numbers — nothing else:

```
/goal Every task in the approved implementation plan is implemented, and this conversation
shows each gate in `<resolved gate list>` run by its literal command to completion with
exit code 0, and — when `test` is among them — the test gate's own output showing 0
failures. Any gate in that list the toolbox verification registry has no command for is
named as UNAVAILABLE by name rather than omitted. Not met while any gate in the list is
absent from this conversation, stale, or non-zero. Stop and report
as impossible if the same failure survives <no_progress_after> consecutive iterations with
no change in the gate output, or after <max_turns> turns.
```

**Worked example** — a `dotnet` runner with `gates: [test, build]` and the toolbox loop
defaults (`max_turns: 25`, `no_progress_after: 2`):

```
/goal Every task in the approved implementation plan is implemented, and this conversation
shows each of `dotnet test` and `dotnet build` run to completion with exit code 0, with the
`dotnet test` output showing 0 failures. Any gate the toolbox verification registry has no
command for is named as UNAVAILABLE by name rather than omitted. Not met while any gate's
output is absent, stale, or non-zero. Stop and report as impossible if the same failure
survives 2 consecutive iterations with no change in the gate output, or after 25 turns.
```

A `node-npm` runner with `gates: [test, lint]` substitutes "each of `npm test` and `npm run
lint`" into the same sentence — no build clause, because the project did not configure that
gate. The list drives the sentence; the sentence never drives the list.

**Why the condition names commands and exit codes rather than outcomes.** The evaluator has
no tools — "the tests pass" is not something it can check, but "this transcript contains
`dotnet test` followed by exit code 0 and 0 failures" is. The subagent must therefore
**print the gate command and its exit status**, not summarise it as "all green". A phase that
reports outcomes instead of evidence will loop to its turn bound with the work already
finished.

**What this does NOT change.** The phase still ends at its phase summary card. `tdd-guide` still enforces RED → GREEN → REFACTOR, and a goal condition is
not a licence to write code before its failing test — the Iron Law in `rules/testing.md`
outranks a green gate. The condition may not name anything past this phase.

**On exit:** `/goal clear`, then record the four handover fields listed in the `/goal`
section above (condition, clamped bounds, iteration count, final per-gate result).

### Step 9 — Agent Orchestration (chief-of-staff)

**Column pre-condition:** Ticket MUST be in **In Progress**. No column transition — stays in In Progress. The review is part of the implementation phase, not a separate board state. The agent never moves the ticket past In Progress — Testing and Done are human steps. *(Toolbox self-maintenance exception: when the repo is `baselito/ai-engineering` there is no ticket and no board — this column pre-condition is n/a; the review phase runs with no Jira ticket/column state at all.)*

No routine Jira comment is posted for code review. The phase card and handover record the review
evidence. If review exposes a human decision or visible ticket impact, request one short Blocker
milestone through `jira-workflow-steward`.

**⛔ INVOKE the `code-review-orchestration` skill — do NOT orchestrate review agents inline ⛔**

**Skill:** `code-review-orchestration`

The orchestrator MUST invoke this skill. Do NOT spawn chief-of-staff directly. Do NOT spawn review agents (tdd-guide, code-reviewer, reality-checker, etc.) directly. Invoke the skill — it handles everything.

This is the same pattern as brainstorming (Step 5) and verification-before-completion (Step 11). The skill:
1. Collects file diffs and ticket context
2. Spawns chief-of-staff (Opus deep-reasoning tier) to decide which agents run
3. Executes the agents in the correct order
4. Returns a consolidated review summary

**Enforcement (3 layers — the agent cannot bypass all three):**
1. **PreToolUse hook** — a hook on the Agent tool blocks any direct spawn of review agents unless chief-of-staff was already invoked. This is a hard technical gate.
2. **This skill** — makes the correct path atomic (same pattern that worked for brainstorming)
3. **PostToolUse compliance audit** — an independent hook verifies chief-of-staff was used after the review completes

**If the orchestrator spawns review agents directly — the PreToolUse hook BLOCKS the tool call.** Even if the agent picks the "right" agents, the decision must come from chief-of-staff via this skill. The orchestrator has a blind spot (e.g. it missed doc-updater in previous runs).

The skill internally spawns chief-of-staff (Opus deep-reasoning tier), which reads the file diffs and builds an execution plan selecting only relevant agents:

**Always run (NO exceptions, even for test-only or single-file changes):**
- `tdd-guide` (Opus) — validates test quality and coverage
- `code-reviewer` (Opus) — quality review, A-F grading
- `reality-checker` (Opus) — production readiness gate, always runs last

**Which agents activate for which changed-file patterns, and their parallel/sequential execution order, is the authoritative lookup table in the `agent-orchestration` skill ("Conditional Agents" and "Parallel Execution" sections) — chief-of-staff consults it directly. This file does not keep its own copy, to avoid the two drifting apart.**

**If security sensitivity is "Financial or sensitive data" (from PROJECT.md):**
- `security-engineer` (Opus deep-reasoning tier) runs on every task, not just when security files are touched

### Step 10 — Agent Handover Chain

**Column pre-condition:** Ticket MUST be in **In Progress**. Verify before starting.

Each agent writes a structured handover note to `.claude/handover.md`. The next agent reads it before starting.

Handover format (must match the template in `rules/handover.md`):
```
## Handover Log — [TICKET-ID]

### [from-agent] -> [to-agent]
Completed: [timestamp]
Status: [PASSED / PASSED WITH NOTES / BLOCKED]

### Agent and model used
- Agent: [which agent/skill ran this phase]
- Model: [actual] — Expected: [from phase table] → ✅ match / ❌ VIOLATION
- Independence: [Yes if different agent from implementation, No if same]

What was done:
-

What was found:
-

What was fixed:
-

Files changed:
-

What the next agent needs to focus on:
-

Blockers (if any):
-
```

Handover notes are also:
- Added as comments on the Jira ticket (human-readable summary)
- Updated in Beads (structured AI tracking)

### Step 11 — Verification Before Completion

**Column pre-condition:** Ticket MUST be in **In Progress**. No column transition — stays in In Progress. Testing is a human step that happens after PR merge.

No routine Jira comment is posted before verification. The phase card, handover, and verification
output record the evidence; use the PR/milestone update when a reviewable result exists.

**⛔ MANDATORY — DO NOT SKIP VERIFICATION ⛔**

**Skill:** `verification-before-completion` — **PreToolUse hook blocks direct invocation**

The orchestrator MUST NOT invoke this skill directly. Spawn an Opus subagent with the `[DELEGATED]` marker:

```
Agent(model: "opus", prompt: "[DELEGATED] You are a verification subagent for DEV-XXXX. Invoke the verification-before-completion skill.

[PRIOR CONTEXT FROM HANDOVER]
- Implementation phase: [orchestrator fills in test results, e.g. '217 passed, 143 failed (pre-existing). New tests: 27/27 passing']
- Code review phase: [orchestrator fills in grade + findings]

[WHAT NOT TO REDO]
- The two cases below are exclusive — read which one you are in before running anything:
  - If you modify NO file during this phase: do NOT re-run the full test suite — the results
    above are authoritative. Run only the new tests (the resolved test command filtered to
    them — on a `dotnet` runner, dotnet test --filter '[test class name]') to confirm they
    still pass, and quote the results above for every other gate
  - If you modify ANY file during this phase (a new test, or a production tweak to close an
    unmapped criterion): the results above describe a tree that no longer exists. Re-run EVERY
    configured gate (the test gate, and lint/build where the resolved runner has a command for
    them) once after your last edit, and report those runs as this phase's gate evidence in
    place of the quotes (Step 11a)
- Focus on mapping acceptance criteria to specific tests

Return your results in your response message. Do NOT write to .claude/handover.md — the orchestrator handles that.")
```

Confirms the fix or feature actually works end-to-end — not just "compiles without errors". Re-runs the NEW tests and validates the feature against the original ticket requirements, reusing the implementation phase's full-suite result rather than re-running it (the prompt above says so, and check 14 of the pre-PR audit treats a fresh full-suite run here as redundant work) — unless this phase modifies a file, in which case every quoted gate result is stale and one fresh run of EVERY configured gate after the last edit is mandated, not redundant (Step 11a). Running tests manually is NOT a substitute — the skill performs additional checks.

#### Step 11a — `/goal` on the verification gate cycle

This phase's exit condition is machine-checkable too, but it is a **different** condition
from Step 8a's, because a phase that modifies nothing deliberately does not re-run the full
suite — the implementation phase's results are authoritative and the subagent prompt above
says so for exactly that case. What loops here is the narrower cycle: an acceptance criterion
has no test covering it, so write one, run the filtered tests, check again. Writing that test
is itself a modification, which is what puts the gate re-run back in scope — see "The quote is
only valid while the tree is unchanged" below.

**Read the "`/goal` — Machine-Checkable Phase Exits" section above first.** In particular:
Step 8a set a goal and should have cleared it. Run a bare `/goal` to confirm nothing is
active before setting this one, and follow that section's table if something is.

**The condition template.** The gate list comes from `verification.gates` resolved through the
`workflow-discipline` skill §1c registry; the coverage number is `max(80, coverage_floor)`;
the bounds are the clamped `loop:` values:

```
/goal Every acceptance criterion in <TICKET> is named in this conversation next to the
specific test that covers it, no criterion is left unmapped, and the new tests were re-run
here with their command and exit code 0 shown. If this phase modified any file, every gate
in <resolved gate list> that the registry has a command for was re-run here after the last
modification, with each command and its exit code 0 shown.
Each gate in <resolved gate list> is reported by name with the result it produced in this
run, and every reported result is either passed or UNAVAILABLE — and the coverage floor is
reported either as a stated figure at or above <effective coverage floor>%, or by name as
UNAVAILABLE because the resolved test command reports no coverage figure. Not met while any
criterion is unmapped, any gate is unreported, any gate is reported as failed, the coverage
floor is neither stated as a figure nor named as UNAVAILABLE, or any gate result shown here
predates a file this phase modified. Stop and report as impossible if the same gap survives
<no_progress_after> consecutive iterations with no change, or after <max_turns> turns.
```

**Worked example** — a `dotnet` runner, `gates: [test, lint, build]`, `coverage_floor: 85`,
loop defaults:

```
/goal Every acceptance criterion in DEV-1234 is named in this conversation next to the
specific test that covers it, no criterion is left unmapped, and the new tests were re-run
here with their command and exit code 0 shown. If this phase modified any file, each of
`dotnet test`, `dotnet format --verify-no-changes` and `dotnet build` was re-run here after
the last modification, with each command and its exit code 0 shown.
Each of `dotnet test`, `dotnet format --verify-no-changes` and `dotnet build` is reported by
name with the result it produced in this run, and every reported result is either passed or
UNAVAILABLE — and the coverage floor is reported either as a stated figure at or above 85%,
or by name as UNAVAILABLE because `dotnet test` reports no coverage figure. Not met while any
criterion is unmapped, any gate is unreported, any gate is reported as failed, the coverage
floor is neither stated as a figure nor named as UNAVAILABLE, or any gate result shown here
predates a file this phase modified. Stop and report as impossible if the same gap survives 2
consecutive iterations with no change, or after 25 turns.
```

**"Reported", not "re-run" — the distinction is load-bearing.** The condition asks for each
gate to be *reported with the result it produced in this run of the workflow*, which a phase
that modified nothing satisfies by quoting the implementation phase's recorded output plus the
filtered re-run of the new tests. From a phase that changed nothing it deliberately does not
ask for a fresh full-suite execution: that would contradict the "do NOT re-run the full test
suite" instruction in the subagent prompt above, and it is the exact redundancy the pre-PR
compliance audit's check 14 exists to catch. A `/goal` condition must never be the reason a
phase does work another phase already did.
Requiring the reported result to be *passed or UNAVAILABLE* does not reintroduce the re-run:
Step 8a's own exit already demanded exit code 0, so the quoted result is green in any
well-behaved run. A gate quoted here as failed means the earlier evidence is no longer valid
— the phase re-enters the fix cycle rather than exiting on it.

**The quote is only valid while the tree is unchanged.** Quoting the implementation phase's
result is sound only when this phase modified nothing. The moment this phase writes a test or
touches production code to close an unmapped criterion, every quoted gate result describes a
tree that no longer exists — and "check for regressions" has nothing behind it. So: if this
phase modified ANY file, re-run EVERY gate in the resolved list once after the last
modification and report each run's command and exit code as this phase's gate evidence,
replacing the quotes. A gate the registry has no command for stays UNAVAILABLE — there is
nothing to re-run for it. Those re-runs are mandated, not redundant — they are not check 14
case (c), because no earlier phase ever converged on this tree.

**Why every gate and not only the test suite.** The gates are separate literal commands, not
one command: `dotnet` resolves to `dotnet test`, `dotnet format --verify-no-changes` and
`dotnet build`; `node-npm` to `npm test`, `npm run lint` and `npm run build`. A green re-run of
the test gate is therefore evidence about the test gate alone. Re-running only the suite would
let a new test file that fails the formatter, or an edit that breaks the build, satisfy every
clause of the condition — the gate is "reported" from the implementation phase's quote and no
clause notices that the quote predates the edit.

**UNAVAILABLE covers coverage too.** The registry test strings collect no coverage, so on a
project that has not wired coverage into its own test command the figure does not exist; the
condition must let the phase say so by name rather than sit unsatisfiable until the
no-progress clause rules it impossible. Naming it is not passing it — it surfaces at the
phase gate for the human, which is why rung 5 keeps that gate.

**What this does NOT change.** The `verification-before-completion` skill still runs inside the
`[DELEGATED]` subagent. The phase still ends at its phase summary card, and
Step 12's reality-checker still runs afterwards regardless of what the
evaluator said — a met goal is evidence the phase converged, not a sign-off.

**On exit:** `/goal clear`, then record the four handover fields listed in the `/goal`
section above. Clearing here matters more than anywhere else: the next gate is PR creation,
and a stale goal sitting on the compliance audit would keep firing turns against a condition
that is already met.

#### Step 11b — Mutation testing (default ON, gated on unit-test applicability)

**Trigger:** read the `Mutation testing:` line from the confirmation-summary handover entry. It is
ON by default for any ticket that creates unit tests; the user can force it off/on per ticket
("no stryker" / "use stryker"). `/hotfix` and `/incident` always skip it.

**Unit-test gate — check FIRST.** If the ticket produced no unit tests, skip Step 11b entirely
regardless of the field. Mutation testing has nothing to mutate against without unit tests.

**⛔ Production-Code Boundary (absolute).** If a mutant can only be killed by CHANGING PRODUCTION
CODE, do NOT change it. Record the surviving mutant as a finding instead: "Mutant survived at
[file:line] — killing it requires a production code change, out of scope." This applies whether
mutation testing ran automatically or was requested. See `rules/testing.md`.

**Cost:** Stryker can take minutes to hours depending on suite size. Report the run as a finding,
never block the workflow on it.

The full step-by-step procedure — the handover-line format and its grep exit-code handling, the
per-tool bootstrap/run command registry, `config_path` validation, and the graceful failure modes
— is in the **`workflow-discipline` skill** (§1 keyword grammar, §1a tool registry, §1b this
procedure). Load it when Step 11b actually fires. The `test-case-filter` threshold workaround and
the Production-Code Boundary are in the always-loaded `rules/testing.md`.

### Step 12 — Reality Checker

**Column pre-condition:** Ticket MUST be in **In Progress**. Verify before starting.

**⛔ MANDATORY — ALWAYS RUNS, NO EXCEPTIONS ⛔**

**Agent:** `reality-checker` (Opus)

Production readiness gate. The reality-checker:
- Validates all tests pass
- Confirms all reviewer agents have signed off (or notes their findings)
- Checks deployment readiness
- Signs off or blocks the PR

If blocked, the agent fixes and re-runs — that is the recovery, not a question: `Decided: fixing [blockers] and re-running verification.` The ask survives only for the one option that is not the agent's to take: **"Override and proceed to PR"** with blockers unresolved, which is an `Irreversible` AskUserQuestion (and after 2 consecutive reality-checker blocks, the path `rules/testing.md` allows only with explicit user confirmation).

### Step 13 — DevOps Check (conditional)

**Column pre-condition:** Ticket MUST be in **In Progress**. Verify before starting.

**Agent:** `devops-automator` (Opus)

Only runs if CI/CD configuration files were changed. Reviews pipeline changes and validates deployment configuration.

### Step 14 — Documentation Sync

**Column pre-condition:** Ticket MUST be in **In Progress**. Verify before starting.

**Agent:** `doc-updater` (Haiku)

Syncs documentation with code changes. Updates any affected docs, README sections, or inline documentation.

### Step 15 — Push and Create PR

**Column pre-condition:** Ticket MUST be in **In Progress**. Verify before starting. Ticket stays in In Progress after PR creation.

**⛔ INVOKE the `finishing-a-development-branch` skill — do NOT create PR manually ⛔**

**Skill:** `finishing-a-development-branch` — **PreToolUse hook blocks direct invocation**

**⛔ PUSH AND PR CREATION REQUIRE CONSENT — STANDING OR PER-ACTION ⛔**

The rule is `rules/git-workflow.md` → "Pull Requests". Standing no-prompt consent comes only from the user-controlled host permission layer, or an explicit user instruction naming this repo in the current task. The tracked table is a historical mirror and never grants consent.

**A `- Autonomy: goal` declaration is NOT consent here, and neither is a generic "run to the goal".** Both are repo-agnostic, so treating either as authorization would grant push and PR-create in every repo the developer opens. See the ⛔ paragraph in `rules/git-workflow.md` → "Pull Requests"; this line used to contradict it.

- **Under host permission consent:** push, create the PR, and report it in the State block. Do not ask. The token flow and `push-safety.sh` / `pr-action-safety.sh` verification are unchanged — consent removes the prompt, never the check.
- **Otherwise:** ask ONCE per branch, via **AskUserQuestion** with header `Irreversible`, options:
  - "Push and create PR" — push branch, create PR (ticket stays in In Progress)
  - "Let me review first" — show the diff, wait for user to approve
  - "Keep branch" — keep the branch open for more work
  - "Discard" — abandon the branch

Do NOT offer "Merge directly" or "Commit on main" — all code goes through PR. "Discard" stays a destructive option and always requires an explicit confirmation.

**⛔ ORDER OF OPERATIONS — audit BEFORE PR delegation (RC1 fix) ⛔**

Once push+PR consent is in hand — standing or given per-action (see the gate above) — the ORCHESTRATOR must follow this exact sequence:

1. **(a) The ORCHESTRATOR spawns AND AWAITS the compliance-audit subagent** (see "INDEPENDENT COMPLIANCE AUDIT" section immediately below). The audit subagent writes `.audit-complete`. The orchestrator presents the findings to the user.
2. **(b) ONLY AFTER the audit completes** does the ORCHESTRATOR delegate PR creation to the Opus `[DELEGATED]` subagent (see "Spawn the PR-creation subagent" section after the audit). Because `.audit-complete` already exists, the `enforce-compliance-audit.sh` gate does not block `gh pr create`, and the PR-creation subagent never needs to spawn the audit grandchild.

Why the ordering matters: the compliance-audit subagent creates the `.audit-complete` marker. The PR-creation subagent hits the `enforce-compliance-audit` PreToolUse gate when it runs `gh pr create`. If the audit ran AFTER (the old order), the PR-creation subagent would be blocked and forced to spawn the audit itself — but a subagent cannot reliably await a grandchild, producing a deadlock (RC1 root cause). Running the audit FIRST means the marker is already present when `gh pr create` fires.

---

**⛔ INDEPENDENT COMPLIANCE AUDIT — NOT SELF-GRADING ⛔**

The orchestrator CANNOT grade its own compliance. Past sessions showed the agent marking all 14 items ✅ when reality was:
- Jira comments claimed 5, actual was 5 but expected 8 (missing 3)
- finishing-a-development-branch skill claimed invoked, actual was inline script
- Plan compliance claimed match, actual had user-approved deviations not noted

**This is the same anti-pattern as "the implementing subagent reviews its own code."** The rules explicitly prevent that (chief-of-staff selects independent reviewers). The compliance check must follow the same principle.

### Spawn the compliance-audit subagent (Opus, general-purpose)

```
Agent(
  subagent_type: "general-purpose",
  model: "opus",
  prompt: "[DELEGATED] You are the compliance auditor for DEV-XXXX. Verify the workflow was followed. Do NOT trust the orchestrator's claims — verify each item with concrete evidence.

Read .claude/handover.md and check each of these 14 items. For each, output:
✅ PASS — with specific evidence (grep match, file path, line number)
❌ FAIL — with specific evidence of the violation
⚠️ WARNING — partial/noted deviation

⚠️ This audit runs at the PR-creation gate, BEFORE the PR exists. The following are EXPECTED to be pending and MUST be graded ⚠️ (pending — posted after this gate), NOT ❌: the 🔗 PR Created comment (check 5), the `finishing-a-development-branch` skill invocation (check 10), and the PR Creation handover entry (check 3). Do not FAIL the audit for their absence.

The 14 verifiable checks:

1. **Execution plan exists** — grep handover.md for '## Execution Plan'. Must match.
2. **Plan compliance** — read execution plan, list phases, compare to actual phase entries in handover. Flag any missing phases or wrong models. Also verify the Execution Plan phase itself was gated like every other phase: the handover entry for '## Execution Plan' must show the phase summary card was presented AND how the gate resolved — **either** an AskUserQuestion response **or** the line `auto-continued under autonomy rule` — before Step 2 started (same evidence bar as any other phase gate). **A recorded auto-continue is valid gate evidence and PASSES**; requiring a user answer would fail a correctly-run autonomous gate, which is the defect this check used to have. Missing gate evidence entirely is a FAIL, not a warning — it means the plan the rest of the workflow treats as "the single source of truth" was never shown to the user.
3. **Handover phase order** — list all '## ' headings in handover.md in file order. Compare to canonical order: Discovery → Execution Plan → Assessment → Brainstorming → Planning → Implementation → Code Review → Verification → PR Creation.
4. **Beads lifecycle** — run `bd show [ID]` and verify status is 'closed' with close reason set.
5. **Jira update policy** — verify at most one short Start, PR/milestone, and Completion update, plus exceptional Blocker updates only when justified. Do not fail the audit because internal phases have no Jira comments.
6. **Phase-map adherence** — parse handover for `phase=` entries (the orchestrator passes a phase key to `jira-workflow-steward`). For each requested transition, verify the target is in `jira_phase_map` and the result is transition, already-in-place, or no-transition. Sequential ordering of column transitions is NOT a requirement on lump boards (Code Review reusing In Progress means no transition there); missing routine comments are not errors.
7. **Phase summaries** — for each phase, verify handover entry has 'What was done' + 'Agent opinion' sections.
8. **Warnings surfaced** — grep handover.md for 'Warning' or 'warning' entries with user-facing context.
9. **Chief-of-staff review** — grep handover.md Code Review section for 'chief-of-staff' or 'code-review-orchestration'. Must appear.
10. **Skills invoked** — grep handover.md for evidence of each required skill: 'brainstorming', 'planner', 'code-review-orchestration', 'verification-before-completion', 'finishing-a-development-branch'. Each should be mentioned in its phase.
11. **External change detection** — grep handover.md for 'External change' or 'Re-read ticket' entries before each column transition.
12. **Model routing** — grep handover.md for 'Model:' lines. For each, check if the model matches the expected model per phase table. Flag any ❌ VIOLATION markers present.
13. **Subagent context passing** — check transcript for Agent tool calls. Count how many include '[PRIOR CONTEXT]' section. If any subagent spawns lack it, report as violation.
14. **Redundant work** — count full test-suite runs PER PHASE, not in total, and grade the phase boundaries. The defect this check was written for is a LATER phase re-running a suite an EARLIER phase already ran, because it could not see the earlier result. That is still a violation: if two phases each ran the full suite from scratch, flag it, and name both phases.

    **A bounded `/goal` iteration set counts as ONE logical suite run.** A phase that ran under a `/goal` condition (Step 8a Implementation, Step 11a Verification) records four things in its handover entry: the condition string, the effective clamped `max_turns` and `no_progress_after`, the iteration count, and the FINAL per-gate result. Those N iterations are one convergence on one gate result — running the suite every iteration IS the mechanism, not waste — so grade the phase on its final recorded gate result and report the iteration count alongside it. Do NOT multiply the phase's suite count by its iterations, and do NOT flag a phase for iterating.

    **What the exemption does NOT cover — each of these is still a finding:**
    (a) a `/goal` run whose handover entry records no turn bound. `/goal` has no built-in cap, so an unbounded loop is a finding regardless of how few iterations it happened to take.
    (b) an iteration count above the effective `max_turns` from the clamped `loop:` block, or a same-failure streak longer than `no_progress_after` — the bound was written into the condition and then not honoured.
    (c) a LATER phase re-running a suite an earlier phase already converged on. The exemption is per-phase and never crosses a phase boundary — that crossing is the original defect and no `/goal` condition licenses it. Step 11a is specified NOT to re-run the full suite in a phase that modified nothing; a Verification entry showing a fresh full-suite run while recording no file modified in the phase is exactly case (c). A Verification entry that re-ran the suite AND records a file it modified during the phase is the mandated staleness re-run from Step 11a, not case (c) — look for that record before flagging.
    (d) a phase whose handover says `/goal: unavailable — <reason>; phase ran attended`. Expect the attended shape there: one suite run for that phase, no iteration set. Two suite runs in an attended phase is a violation as it always was.

    Report as: `Suite runs: <N> phases × 1 logical run each; /goal iterations: <phase>=<k> (bound <max_turns>), ...; cross-phase re-runs: none | <list>`.

Return a table with all 14 items, evidence for each, and overall verdict:
- PASS if all 14 are ✅
- PASS WITH NOTES if some ⚠️
- FAIL if any ❌

When done, write your full findings to the CONFIGURED state root's `.audit-complete` file (not just `touch` it — the hook rejects empty files).

**Which directory that is, and why this is not just `~/.claude`.** `enforce-compliance-audit.sh` reads the marker from `${CLAUDE_STATE_DIR:-$HOME/.claude}`. These instructions used to say `~/.claude` unconditionally, so on any install that sets `CLAUDE_STATE_DIR` the audit was written to a directory the gate never reads — the audit ran, passed, and PR creation stayed blocked with nothing in the report to explain it. Resolve the root the same way the hook does:

- `CLAUDE_STATE_DIR` set → write to `$CLAUDE_STATE_DIR/.audit-complete`.
- otherwise → write to `~/.claude/.audit-complete`.

The gate's own deny message now prints the resolved path, so if you are ever unsure, trip it once and copy the path it names.

Format: a binding line, then one line per check with emoji and evidence, then a summary line carrying the VERDICT.

- **First line — `AUDIT HEAD: <full 40-char sha>`.** Bind the report to the commit you audited, via `git rev-parse HEAD`. An audit certifies the commit it read; without this line the hook cannot tell which change the report covers, and it denies.
- **Last line — `AUDIT COMPLETE: [N]/[M] items verified — PASSED|BLOCKED`.** The verdict must be the FINAL token, separated by the `—`.

Example:
```
Bash(cat > "${CLAUDE_STATE_DIR:-$HOME/.claude}/.audit-complete" <<'EOF'
AUDIT HEAD: 4f21c0b9e7d6a3158c2fbb04ee9d7a3b6c118e52
1. Execution plan exists — ✅ PASS — grep matched '## Execution Plan' at line 42
2. Plan compliance — ✅ PASS — all 9 phases present, models match
...
14. Redundant work — ✅ PASS — Suite runs: 2 phases × 1 logical run each; /goal iterations: Implementation=4 (bound 25), Verification=1 (bound 25); cross-phase re-runs: none

AUDIT COMPLETE: 14/14 items verified — PASSED
EOF
)
```

The hook requires the file to exist, be non-empty, be keyed to the current HEAD, and end with an `AUDIT COMPLETE:` line whose verdict is `PASSED`. An empty `touch` does not satisfy the check — that was a deliberate bypass hole closed in April 2026.

**Report the verdict you actually reached.** Until issue #153 the hook read only the signature line and never the verdict, so an audit ending `BLOCKED` opened the PR anyway — that happened live, twice, on 2026-08-26. It no longer does: `BLOCKED` denies, and so does any verdict the hook cannot read. `BLOCKED` is a valid and expected outcome — do NOT write `PASSED` to get past the gate.

Do NOT grade leniently. Do NOT trust claims without evidence. Return your results in your response message. Do NOT write to handover.md.")
```

The orchestrator presents the audit subagent's findings to the user verbatim. No summarisation, no "actually we did that." The evidence is in the file — the audit reads it fresh.

### Why this is different from self-grading

| Self-check (old) | Independent audit (new) |
|---|---|
| Same agent that did the work grades it | Fresh subagent with no investment in looking good |
| Subjective interpretation ("I think we covered this") | Evidence-based (grep match or no match) |
| Incentive to report green | No incentive — subagent just reports what it finds |
| Post-hoc rationalization possible | Evidence-based verification — can't rationalize grep results |

The audit subagent is essentially "the chief-of-staff pattern" applied to the compliance check — independent verification by a separate agent, not self-grading.

### What the user sees

```
Compliance Audit — DEV-XXXX (by independent subagent)

✅ Execution plan exists — found at handover.md:12
✅ Plan compliance — 8/8 phases match, 0 deviations
✅ Handover phase order — correct sequence
✅ Beads closed — bd show confirms status=closed
✅ Jira update policy — milestone updates are concise; internal phase comments are not required
✅ Phase-map adherence — 8/8 phases consulted phase map; 3 transitions fired, 5 no-op or milestone-independent phases
... (14 items total)

Verdict: PASS WITH NOTES (3 missing Jira comments)
```

**⛔ THIS AUDIT IS MANDATORY — EVEN IF THE USER DISCARDS THE WORK ⛔**
If the user discards, cancels, or abandons the workflow early, STILL spawn the audit subagent. The audit exists to build process discipline — skipping it on discards defeats the purpose.

---

**⛔ FULL TICKET + GIT LIFECYCLE — PHASE-KEYED, NOT COLUMN-KEYED ⛔**

The phase progression below is universal. The Jira-state column shows what `jira-workflow-steward` does when it consults the phase map — the actual column names that fire come from `jira_phase_map` in PROJECT.md, not from this table.

| Step | Action | Phase-map call | Git |
|---|---|---|---|
| Ticket picked up | Read ticket, read-only Discovery investigation, user approves at Investigation Gate | `phase=discovery` fires at Step 1.8 *after* gate approval when a transition is needed | Nothing yet |
| Brainstorming + planning | Design decisions, plan approved | `phase=ready_for_dev` when a board transition is needed | Nothing yet |
| Implementation starts | Create branch, start coding | `phase=in_progress` (almost always a real transition) | Branch created locally |
| Coding + TDD | Write tests, implement, commit | (no phase-map call) | Commits locally |
| Code review + quality gates | Agent reviews pass | `phase=code_review` (commonly == in_progress on lump boards → comment in place) | Nothing pushed yet |
| Verification + reality check | Final checks pass | No routine Jira update | Nothing pushed yet |
| Push + create PR | Push branch, create PR (user approves first) | `phase=ready_for_release` when a transition is needed; post the short PR milestone | Branch pushed, PR created |
| **Agent stops here** | Agent offers to pick next ticket | — | PR open, awaiting human review |
| Human developer reviews PR | Approves or requests changes | — | PR approved |
| PR approved → merge to Stage | Deploy to staging environment | (human moves ticket — agent never moves to Testing) | PR merged to stage branch |
| Manual testing on Stage | Human tests the deployed feature in portal/staging | — | — |
| Testing passes | Human confirms feature works in staging | (human moves ticket to Done) | Merged to main |

The orchestrator does NOT walk a column ordinal list — `jira-workflow-steward` looks up `phase_map[key]` and applies the board mapping per requested transition. If a phase's column is missing from the map, the phase doesn't transition; if it equals the current column, no move; if it's different, transition. Comments are separate and milestone-based.

**After the user approves "Push and create PR":**
- The agent first runs the compliance audit (see ORDER OF OPERATIONS above)
- Then delegates PR creation to the Opus subagent below

### Spawn the PR-creation subagent

The orchestrator MUST NOT invoke `finishing-a-development-branch` directly. Spawn an Opus subagent with the `[DELEGATED]` marker **after the compliance audit has completed and `.audit-complete` exists**:

```
Agent(model: "opus", prompt: "[DELEGATED] You are a PR creation subagent for DEV-XXXX on branch feature/DEV-XXXX-slug. Invoke the finishing-a-development-branch skill. Present options to the user: push and create PR, review first, keep branch, or discard.

The orchestrator has ALREADY run the independent compliance audit (the `.audit-complete` marker exists). Do NOT spawn the compliance audit yourself — you cannot await a grandchild subagent. Just invoke finishing-a-development-branch and create the PR.

[PRIOR CONTEXT FROM HANDOVER]
- Implementation: [files changed, test count]
- Code review: [grade, key findings]
- Verification: [acceptance criteria mapping, final status]

Return your results in your response message. Do NOT write to .claude/handover.md — the orchestrator handles that.")
```

**After the PR is created:**
- Links the Jira ticket in the PR description
- Requests appropriate reviewers based on files changed
- **Ticket stays in In Progress** — do NOT move to Testing. Testing happens after a human approves the PR and deploys to Stage.
- **Jira delegation token:** `touch ~/.claude/.jira-delegation-token`
- `jira-workflow-steward` (Haiku) adds the concise PR milestone:
  ```
  PR ready: [link].
  ```

**Auto-poll (schedule it; it is a best-effort backstop):** After the skill returns `pr_number` and `is_draft`, the orchestrator MUST schedule the `/review-pr` auto-poll cron at 1-minute intervals — but the cron can starve (it fires only while the REPL is idle and is session-only), so the **reliable path is the agent handling reviewer comments inline** (`/review-pr --repo <owner>/<repo> <N>` at PR creation, whenever you return to the PR, and before ending the session). The exact `CronCreate` construction is in the **`pr-automation` skill**; `rules/git-workflow.md` "Auto-Poll After PR Creation" has the directive. Applies to ALL commands that create PRs, not just `/flow`.

**⛔ THE AGENT'S JOB ENDS HERE ⛔**

After creating the PR, the agent tells the user:
```
PR #XX created and linked to DEV-XXXX.
Ticket stays in In Progress — awaiting developer review on the PR.

What happens next (human steps):
1. A developer reviews and approves the PR
2. PR is merged and deployed to Stage → ticket moves to Testing
3. Manual testing on Stage environment → ticket moves to Done

Want to pick up the next ticket?
```

Do not ask "what next?" — apply the **Queue rule** (`rules/autonomy.md`): open PRs with unresolved
reviewer threads (oldest first), then a finished branch without a PR, then unpushed commits, then
new work in the order the user gave it. State which item you picked and why in one line.

### Step 16 — Testing and Done (human-triggered, not agent-triggered)

**⛔ THE AGENT NEVER MOVES A TICKET TO TESTING OR DONE ⛔**

The remaining lifecycle is fully human-driven:

| What happens | Who does it | Jira transition |
|---|---|---|
| Developer reviews PR | Human reviewer | Stays in **In Progress** |
| PR approved + merged to Stage | Human / CI pipeline | Move to **Testing** |
| Manual testing on Stage environment | Human tester (logged into portal, checks feature) | Stays in **Testing** |
| Testing passes | Human confirms | Move to **Done** |

The agent does NOT perform any of these steps. If the user explicitly asks the agent to move a ticket to Testing or Done, the agent verifies the PR state first:

```bash
Bash(gh pr view PR_NUMBER --json state --jq '.state')
```

- Moving to **Testing**: only if PR state is `MERGED` (deployed to Stage)
- Moving to **Done**: only if user confirms manual testing passed on Stage
- If PR is `OPEN`: refuse — "PR hasn't been approved and merged yet. Ticket stays in In Progress."

**External change detection:** Runs before moving to Done.

**Agent:** `jira-workflow-steward` (Haiku)

**Board-driven (only runs if user explicitly asks AND PR is verified as MERGED):**
- Moves the Jira ticket to Done
- Links the PR to the Jira ticket
- Adds a final Jira comment summarising the full lifecycle:
  ```
  ✅ Completed — [ticket title]

  **Branch:** feature/DEV-XXXX-slug
  **PR:** [link]
  **What was delivered:** [1-2 sentence summary]
  **Tests:** [pass count], [coverage %]
  **Reviews:** Code [grade], Security [grade]
  ```
- Closes the Beads issue

**Agent-first:**
- Closes this task's bead and moves the Jira sub-task to Done
- If this was the last task in a story: closes the story bead and moves the Jira story to Done
- If this was the last story in the epic: closes the epic bead and moves the Jira epic to Done
- Shows progress: "Task 3/7 complete. Next: DEV-5650 — Validation + auth." Then continues to the next task (autonomy rule) — the user interrupts to skip or stop

**Hybrid:**
- Closes this sub-task's bead and moves the Jira sub-task to Done
- When all sub-tasks under a story are done, the agent asks whether to move the parent story to Done
- Shows progress: "Sub-task 2/4 complete. Next: DEV-5646 — Loading state management." Then continues to the next sub-task (autonomy rule) — the user interrupts to skip or stop

### Step 17 — Sprint Retrospective (Scrum boards only)

**Skip this step** if the board is Kanban or this was a single-ticket run.

**Agent:** `project-manager-senior` (Opus)

After all sprint tickets are complete (or the sprint is ended early), the agent generates a retrospective covering: story points completed vs planned, velocity compared to previous sprints, what went well, what slowed things down, and suggestions for the next sprint.

Sprint data is stored in Beads for cross-session persistence. The agent posts a sprint summary comment to Jira if configured.

---

## Error Handling

- **Build errors during execution:** `build-error-resolver` (Opus) reads the error output and applies known fix patterns. If still unresolved after 2 attempts, the agent cannot proceed — raise an AskUserQuestion with header `Blocked` (`rules/autonomy.md`), quoting the exact error and the two fixes already attempted, and offering the concrete next moves (e.g. supply the missing dependency/credential, point at the right build command, or park the branch). `Blocked` is the accepted header for an inability to continue — do not ask uncategorised, and do not loop a third attempt.
- **Agent launch failure (529, timeout, overload):** If a subagent fails to launch, the agent MUST NOT silently do the work itself. The agent that wrote the code must not review its own code — that defeats the purpose of the review chain. Retry the agent — a retry is never an ask — up to 3 times, stating each attempt. Only **skipping** a review step is an ask (`Blocked`), because it removes the independent review the workflow depends on. If the code-reviewer specifically fails, warn: "Code review could not run — the PR will not have an independent review."
- **Agent blocked:** If any agent reports BLOCKED in the handover, this is the one phase-card status that still stops (`rules/agents.md` step 4) — use **AskUserQuestion** with header `Blocked`. The chief-of-staff presents the block to the user via **AskUserQuestion**: "Attempt automatic resolution", "I'll handle this manually", "Skip this check and proceed". The agent MUST NOT route around blocks autonomously.
- **Context window pressure:** `harness-optimizer` (Sonnet) monitors context usage. `strategic-compact` skill suggests compaction when needed.

### Orchestrator Context Bloat — Mitigation

The orchestrator (Fable) carries heavy context throughout a workflow:
- `/start` skill text (~5K tokens)
- `/flow` skill text (~15K tokens)
- All 15 rules (terse directives; bulk detail moved to on-demand skills)
- 50-137 Jira tickets from board query (~5-10K tokens)
- Every phase summary (~2-3K tokens each, 8 phases)
- Every subagent response (~5-10K tokens each)

**A single `/flow` run can push the orchestrator to 200-400K input tokens.** At orchestrator-tier pricing that is several dollars per run in orchestrator context alone.

**Mitigations (the agent MUST apply these):**

1. **Trim Jira ticket list after selection.** Once the user picks a ticket, discard the other 99 tickets from context. Use `Bash(acli jira workitem view [TICKET] --json)` to fetch only the chosen ticket.

2. **Compact phase summaries in handover.** Phase summaries in `.claude/handover.md` should be terse (3-5 lines each), not verbatim conversation logs. The compliance audit subagent reads the handover — it doesn't need essays.

3. **Use `strategic-compact` skill at natural boundaries.** After Step 8 (Implementation complete) and again after Step 11 (Verification complete), evaluate context usage. If > 100K tokens, invoke `strategic-compact` to summarise prior phases.

4. **Subagent responses are processed, not retained verbatim.** When a subagent returns 10K tokens of output, the orchestrator should extract the key findings (2K tokens) and write those to handover — then let the full response drop out of active context after the next tool call.

5. **Don't re-read skill text mid-workflow.** If the agent has already read `/flow` at Step 1, it doesn't need to re-read it at Step 9. Skill text should load once per session.

**Compliance check item 15 verifies this:** after the workflow, the audit subagent can check the context trajectory — did the orchestrator compact at boundaries, or did it accumulate everything?

---

## Notes

- The agent pulls the user in for: ticket assessment (Step 2 — always), **confirmation summary (Step 3 — always)**, discovery findings approval (Investigation Gate — Step 1.7), execution plan approval (Step 1.8's phase-card gate — always), brainstorming (Step 5 — mandatory, user decides to skip or run), implementation plan approval (Step 6), critical blockers, external change warnings (priority changes, new comments), worktree decision (Step 7.5), branch decision (Step 15), **the agent never moves a project ticket to Done — Done follows the user's merge and testing; the ticketless toolbox may be auto-merged by the scoped GoalRun gate**, and **any agent BLOCKED status**
- Jira column transitions, ticket assignments, and Jira comments run automatically — they do not require user confirmation. All other automation is governed by the per-step gates above
- Column transitions are best-effort: if Jira is down or the transition isn't allowed, the agent warns and continues without blocking
- External change detection adds minimal overhead — it's a single Jira read before each column transition
- `loop-operator` (Sonnet) monitors long-running tasks for stability
- Git commits use Haiku for message generation
- Branch naming uses Haiku via jira-workflow-steward
