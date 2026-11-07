---
name: flow-reference
description: Reference material for the /flow ticket workflow that is only needed at specific moments, kept out of commands/flow.md so the command file stays lean. Carries the full per-phase Jira comment templates (standard "work-starting" and streamlined "work-done" variants, plus the header-adaptation rules for boards missing a column), the phases-vs-columns decoupling detail with worked examples, the phase-comment spawn mechanism, and the per-phase subagent prompt templates showing what prior context each phase must pass. Load this when posting a /flow phase comment, when a board is missing a mapped column, or when composing a subagent spawn prompt during /flow. The directives themselves stay in commands/flow.md and rules/agents.md.
---

# /flow Reference — templates and worked detail

The directives live in `commands/flow.md` (the workflow spine) and `rules/agents.md` (the
always-loaded Jira/phase-summary rules). This skill holds the material you only need at the
moment you post a comment or compose a spawn prompt.

---

## Jira Update Policy — milestone comments

**Toolbox self-maintenance exception:** when `git remote get-url origin` resolves to `baselito/ai-engineering`, Jira comments and transitions are skipped because the toolbox has no project ticket. Phases still run and phase cards still show, with the card's `Jira:` line reading `n/a — toolbox self-change`.

For project repos, Jira updates are milestone-based and concise:

- **Start:** one short sentence when work begins.
- **PR/milestone:** one short sentence when a reviewable deliverable or PR is available.
- **Completion:** one short sentence when the work is complete.
- **Blocker (exception):** one short sentence only when a human decision or visible ticket impact requires it. Add a resolution sentence only if the ticket would otherwise still appear blocked.

Do not post routine updates for internal phases, reviewer activity, polling, retries, provider
switches, installation, or test output. Keep those details in the handover, PR, and tool logs.
Board transitions still go through `jira-workflow-steward` and the live phase map, whether or not
a comment is posted.

| Milestone | Example | When posted |
|---|---|---|---|
| Start | `Started: <what is being done>.` | Once, when work begins |
| PR/milestone | `PR ready: <link>.` | Once, when a reviewable result exists |
| Completion | `Complete: <what changed>.` | Once, when the work is complete |
| Blocker | `Blocked: <decision or ticket impact>.` | Only when human action or visible impact requires it |

The comment count is intentionally small and depends on meaningful milestones, not the number of
internal phases or board columns. Phase cards and handover entries retain the detailed workflow
trace for developers and reviewers.

The **enforce-jira-delegation hook** blocks direct `acli jira workitem comment create` calls on the
main agent — requested milestone or blocker updates still go through `jira-workflow-steward`.

### Streamlined Path Comment Templates (legacy reference)

The standard templates above describe work **about to start** — `🚀 In Progress — Implementation started`, `🔍 Discovery — Agent investigation`. They make sense when the column transition happens BEFORE the work runs.

The streamlined path inverts this. The orchestrator does the work on a feature branch FIRST, then transitions the ticket out of Backlog and posts comments AFTER each phase completes. With the standard templates, the audit trail reads `🚀 Implementation started` on a comment that actually describes finished work — emoji and tense disagree.

**Use the streamlined variant when ALL of these are true:**
- The phase's work has already finished before the column transition fires
- The comment is being posted AT or AFTER the work completes
- The temporal frame is past, not future

| Phase | Standard (work-starting) | Streamlined (work-done) |
|---|---|---|
| 1 Discovery | `🔍 Discovery — Agent investigation\nScope: ...` | `✅ Discovery — Investigation complete\nScope: <files read>\nFindings: <what was found>\nRecommendation: ready for dev` |
| 2 Assessment | `📖 Assessment — Reading ticket` | `✅ Assessment — Ticket read\nCode needed: yes/no — <reason>\nFiles affected: <list>` |
| 3 Brainstorming | `💡 Brainstorming — Exploring approaches` | `✅ Brainstorming — Approach chosen\nApproach: <one-liner>\nWhy: <one sentence>` |
| 4 Planning | `📋 Ready for Development\nApproach: ...\nPlan: ...` | `✅ Ready for Development — Plan finalised\nFiles: <list>\nKey decisions: <list>\nEstimated scope: small/medium/large` |
| 5 Implementation | `🚀 In Progress — Implementation started\nBranch: ...\nTests first: TDD` | `✅ In Progress — Implementation complete\nBranch: <name>\nFiles changed: <list>\nTests: <count> passing` |
| 6 Code Review | `🔍 Code Review Started (still In Progress)` | `✅ Code Review Complete\nGrade: <A-F>\nFindings: <none / list>\nAgents run: <list>` |
| 7 Verification | `✅ Verification — Running tests` | `✅ Verification Complete\nTests: <count> passing\nNo regressions in <count> existing tests\nReady for PR` |
| 8 PR Created | `🔗 PR Created` | `✅ PR Created\nPR: <link>\nBase: main\n<count> tests passing on the branch` |

**The visual marker (`✅`) replaces the starting marker (`🔍/📖/💡/📋/🚀`) in the streamlined variant** — when a reviewer scrolls the ticket, the trail of `✅` marks visually communicates "everything past this point already happened" without each comment having to spell that out.

For Phase 7 Verification, the standard and streamlined templates both use `✅` because verification is a completion phase by definition. The body changes; the emoji doesn't.

The orchestrator decides path-streamlined-vs-standard at workflow start. Once chosen, the choice applies to ALL phase comments in that workflow run — never mix the two.

---


---

## Phases vs Columns — THEY ARE DECOUPLED

**⛔ CRITICAL RULE: Phases always happen. Columns adapt to what the board has. ⛔**

The 8 workflow phases (Discovery, Assessment, Brainstorming, Planning, Implementation, Code Review, Verification, PR Creation) are internal work stages. The columns on a Jira board are separate — they're how YOUR team visualises progress. Mapping between the two is the **phase map** (`jira_phase_map` in PROJECT.md), set by the user at `/init` and verified at the start of every `/flow` run.

**Different teams have different boards.** Some have Discovery. Some have QA. Some have UAT. Some just have "To Do → In Progress → Done". The workflow adapts via the phase map.

### What happens for each phase, given the phase map

| Phase | If `phase_map[key]` is null or missing | If column == current column | If column != current |
|---|---|---|---|
| Discovery | Discovery phase runs in current column; no routine comment | Discovery runs in place; no routine comment | Transition; milestone comment remains optional |
| Code Review (often == in_progress) | Review runs in current column; no routine comment | Review runs in place; no routine comment | Transition; milestone comment remains optional |
| Any phase | Phase work always runs; Jira update is optional | — | — |

**Principle:** The phase is the WORK. The column is WHERE THE TICKET SITS. If the column doesn't exist or matches the current one, the ticket doesn't move. The phase card and handover retain the detail; a Jira milestone comment is optional.

### Comment headers self-describe column context

When an explicitly requested milestone has no dedicated column on this board, its text can mention the current column so PMs are not confused by the ticket's status:

```
🔍 Discovery (in Backlog — board has no Discovery column)

Scope: ...
Risks: ...
```

When the phase shares a column with a previous phase (e.g. Code Review reusing In Progress), no special header — the comment posts plainly because the ticket genuinely sat in In Progress for both phases.

### Legacy Phase Comment Headers Adapt to Board Columns (Fix A)

When auditing an older phase-comment run, if a phase comment posts but its semantically-matching column doesn't exist on the board, the comment's header MUST be rewritten to reflect the actual current column. New runs use the concise milestone policy instead.

**Standard form** (board has the canonical column for this phase):
```
<phase-emoji> <Phase Name> — <one-line summary>

<body…>
```

Example: `🔍 Discovery — Agent investigation`

**Adapted form** (board does NOT have the canonical column — the comment lands in whatever column the ticket currently sits in):
```
<phase-emoji> <actual current column> — <Phase Name> <verb> (board has no <canonical-column> column)

<body…>
```

Example: `🔍 Backlog — Discovery investigation (board has no Discovery column)`

The phase emoji stays. The header swaps the canonical column name for the actual current column and adds the parenthetical so a reviewer immediately understands why the comment looks "off-column". The body is unchanged.

**How the orchestrator decides which form to use:**
1. Read `jira_phase_map` from `.claude/PROJECT.md`.
2. For each phase the orchestrator posts a comment for, check whether the phase has a mapped column in `jira_phase_map` (non-null value).
3. If yes → standard form. If no → adapted form, populated from the ticket's current `status.name`.

| Phase | Canonical column | If missing, body verb |
|---|---|---|
| 1 Discovery | Discovery (or "Investigation") | "investigation" |
| 2 Assessment | Discovery / Ready for Dev | "assessment" |
| 3 Brainstorming | Ready for Dev / Selected for Development | "brainstorming" |
| 4 Planning | Ready for Dev / Selected for Development | "planning" |
| 5 Implementation | In Progress / Doing | "implementation" |
| 6 Code Review | In Progress / Code Review / In Review | "review" |
| 7 Verification | In Progress / Testing | "verification" |
| 8 PR Created | In Progress / Code Review / In Review | "PR creation" |

This works alongside Fix C's `intermediate_comments` map — when the streamlined path passes through a column whose phase is also non-existent on the board, both the intermediate comment AND the eventual phase comment use the adapted form.

> **Forward compatibility note:** A separate task (Jira column aliasing layer) is in flight that adds explicit column-equivalence mapping (e.g. "Doing" ≡ "In Progress"). When that lands, the existence check above flips from a phase-map null check to an alias-aware lookup. The header rewrite logic is unchanged — it still triggers when the canonical column has no match (alias-resolved or otherwise) on the current board.

### Milestone updates are independent of column structure

Even if the board only has 3 columns (Backlog → In Progress → Done), the same short milestone
policy applies. A team member sees the important ticket updates while the full workflow trace
remains in the handover and phase cards.

### Example: minimal board (Backlog → In Progress → Done)

```yaml
jira_phase_map:
  discovery: null
  ready_for_dev: null
  in_progress: "In Progress"
  code_review: "In Progress"   # same column as in_progress
  ready_for_release: null
  done: "Done"
```

```
Phase 1 Discovery:     Work: ✅  Column: stays in "Backlog"     Comment: no routine update
Phase 2 Assessment:    Work: ✅  Column: stays in "Backlog"     Comment: no routine update
Phase 3 Brainstorming: Work: ✅  Column: stays in "Backlog"     Comment: no routine update
Phase 4 Planning:      Work: ✅  Column: stays in "Backlog"     Comment: no routine update
Phase 5 Implementation: Work: ✅ Column: moves to "In Progress" Comment: optional Start update
Phase 6 Code Review:   Work: ✅  Column: stays in "In Progress" Comment: no routine update
Phase 7 Verification:  Work: ✅  Column: stays in "In Progress" Comment: no routine update
Phase 8 PR Created:    Work: ✅  Column: stays in "In Progress" Comment: optional PR/milestone update
```

The ticket only moves once (Backlog → In Progress). The team gets the full workflow trace from
phase cards and handover entries, with only meaningful milestones copied to Jira.

---


---

## Jira Update Mechanism

Every Jira transition or explicitly requested milestone update goes via
`jira-workflow-steward` (Haiku). The 3-branch phase-map logic still decides the transition; a
phase call does not automatically create a comment. For milestones without a phase key, pass a
short standalone update request. **PR Creation uses key `ready_for_release`** when a board
transition is needed.

**If any transition fails:** retry once, then post a short blocker update only if the ticket's
visible state or a human decision is affected. Jira is an optional service and choosing a recovery
is never an ask (`rules/edge-cases.md` General Rules 2 and 3): `Blocked: ticket not moved after one retry.`

### When to populate `intermediate_comments`

When a transition passes through columns en route to the target, do not post routine pass-through
comments. Use `intermediate_comments` only for an exceptional milestone or blocker that changes
the ticket's visible meaning.

| Scenario | Skip intermediate? | Why |
|---|---|---|
| Streamlined path traverses "Selected for Development" without a formal Planning phase | ❌ Add `'Selected for Development': '📋 Streamlined path...'` | The column is normally the home of the 📋 Planning comment; without one, a reviewer scrolling the ticket sees an unexplained gap |
| Full `/flow` path moves into "Selected for Development" and stops there for Planning | ✅ Skip — the regular Planning phase will post the 📋 comment when it transitions to that column as the *target* | The normal phase comment covers it |
| Board has a "Code Review" column and Phase 6 moves into it | ✅ Skip — Phase 6 posts its own 🔍 comment when "Code Review" is the *target* | Same as above |
| Board has a transition-only column like "QA Triage" with no phase work | ❌ Add a one-line `'QA Triage': '⏭️ Transit-only — no QA work performed by the agent.'` | Otherwise the column is silent |

The map is column-name keyed (case-sensitive, matching phase-map column values). Empty-string and missing-key columns are no-ops — safe to over-populate without spamming the ticket.

**Note:** On the default **Investigate and advance** path, ticket assignment happens at Step 1.8 — AFTER the user approves investigation findings at the Investigation Gate (Step 1.7). Step 1 only READS the ticket; Discovery investigation (Step 1.5) is read-only, so no assignment, transition, or Jira comment happens before the gate. **Skip Discovery** records the skip internally and does not create a routine Jira update. See the "FIRST ACTIONS" block in the execution order section.

---


---

## Subagent Prompts MUST Include Prior Context

**⛔ MANDATORY — Every subagent spawn prompt MUST include `[PRIOR CONTEXT]` from handover.md ⛔**

The handover file records what each phase did and found. Subagents spawned in later phases are isolated contexts — they do NOT automatically see the handover. If the orchestrator doesn't pass prior findings explicitly, subagents redo work that's already done.

Observed waste: the full test suite ran 3-4 times in one workflow (implementation, reality-checker, verification) because each subagent ran `dotnet test` independently. Same 217 passed / 143 failed result computed repeatedly.

### The rule

Before spawning any subagent, the orchestrator MUST:

1. **Read `.claude/handover.md`** to get findings from prior phases
2. **Extract relevant entries** for the subagent's phase
3. **Include them in the prompt** as a `[PRIOR CONTEXT]` section
4. **Tell the subagent explicitly what NOT to redo**

### Template for subagent prompts

**Model argument — named vs anonymous.** The template below is the ANONYMOUS form
(`general-purpose` / no `subagent_type`), which has no frontmatter and therefore MUST carry an
explicit `model:`. When spawning a NAMED agent, drop the `model:` entirely — its frontmatter is
authoritative. See `rules/performance.md` → "The four tiers".

```
Agent(model: "opus", prompt: "[DELEGATED] [TASK DESCRIPTION]

[PRIOR CONTEXT FROM HANDOVER]
- Discovery phase: [summary of key findings — file names, patterns, risks]
- Implementation phase: [what was built, test results — e.g. 'Full suite: 217 passed, 143 failed (pre-existing SQL Server). New tests: 27/27 passing']
- [Other phases as relevant]

[WHAT NOT TO REDO]
- Do NOT re-run the full test suite to reproduce the results above — they are
  authoritative for the tree they ran on. They stop being evidence the moment that
  tree changes: if you modify ANY file in this phase, re-run every configured gate
  (the test gate, plus lint/build where the resolved runner has a command for them)
  once after your last edit and report those runs in place of the quotes. Stale is
  not authoritative — but this is not licence to re-run a gate your edits did not
  invalidate (`commands/flow.md` Step 11a states this predicate for Verification)
- Do NOT re-read source files already covered in Discovery
- Do NOT re-explore reference patterns already identified

[YOUR TASK]
[Specific instructions for THIS subagent's work]

[IF THE PREMISE IS WRONG]
If you discover this brief's premise is wrong — the bug is elsewhere, the case is
already fixed, the ground truth differs from what is stated here — STOP and report
that instead of implementing against the wrong premise. Evidence-backed push-back
is rewarded, never penalised.

[REPORT BACK]
- Files changed, each with a one-line rationale
- Test count before → after, and the exact command you ran
- Anything you deliberately did NOT do, and why
- Anything that surprised you or contradicts this brief
Do NOT claim success on anything you did not personally re-run in this session.")
```

**Observation:** if the implementation subagent is spawned `run_in_background: true` and is expected to run more than ~5 minutes, DECLARE the work to `scripts/observe.sh` **before spawning it** — see the **`observed-work` skill** (and `rules/agents.md` "Observed Work"). The script validates the exit predicate, requires a hard deadline, and computes `MISMATCH` from re-run probes; the `observer` agent judges the log it wrote. Session crons are NOT a substitute (idle-only), and neither is a monitor agent — `subagent-liveness` is retired because a model as sensor fabricated its measurements.

### Examples

**Code reviewer subagent (Step 9):**
```
[PRIOR CONTEXT FROM HANDOVER]
- Implementation ran the full suite: 217 passed, 143 failed (pre-existing)
- 27 new tests added for WorkOrderSeverityExtensions, all passing
- tdd-guide already validated coverage — focus on quality only

[WHAT NOT TO REDO]
- Do NOT re-run the test suite — results above are authoritative. The unconditional
  form is safe HERE only because a review agent writes no production code
  (`rules/agents.md` → four roles), so this phase leaves the tree the results
  describe intact. If a review ever does edit a file, the staleness clause in the
  generic template above applies to it too
- Do NOT re-verify test counts — tdd-guide already confirmed 27 tests

[YOUR TASK]
Review the new file WorkOrderSeverityExtensionsTests.cs for code quality,
A-F grade, OWASP issues, and idiomatic patterns.
```

**Verification subagent (Step 11):**
```
[PRIOR CONTEXT FROM HANDOVER]
- Implementation: 27 tests added, all passing
- Code review: Grade A, no findings
- Full suite: 217 passed, 143 failed (pre-existing, SQL Server missing)

[WHAT NOT TO REDO]
- The two cases below are exclusive — read which one you are in before running anything:
  - You modify NO file this phase: do NOT re-run the full suite — the results above are
    authoritative and the same pre-existing failures would just reappear. Run only the
    new tests to confirm they still pass, and quote the results above for every other gate
  - You modify ANY file this phase (a new test written to close an unmapped criterion, or
    a production tweak): the results above describe a tree that no longer exists. Re-run
    EVERY configured gate the resolved runner has a command for (the test gate, plus
    lint/build) once after your last edit and report those runs as this phase's gate
    evidence in place of the quotes; a gate with no command stays UNAVAILABLE — there is
    nothing to re-run for it (`commands/flow.md` Step 11a)
- Focus on acceptance criteria — test re-execution beyond what your case above puts in
  scope is not the goal

[YOUR TASK]
Invoke verification-before-completion skill. Verify each acceptance
criterion from the ticket is met by a specific test (map criterion → test).
Run the tests your case above puts in scope, showing each command and its exit code.
```

### Why this matters

| Without prior context | With prior context |
|---|---|
| Each subagent re-runs full test suite (~15s × 3 = 45s) | Full suite runs once per tree (~15s); subagents that change nothing verify targeted tests (<1s each), and one that edits a file re-runs the gates on the tree it created (Step 11a) |
| Discovery re-reads same files across retry tickets | Prior discovery findings reused, verification takes 3s |
| Planning re-analyses codebase already mapped | Previous plan validated, not regenerated |
| Subagents duplicate each other's work | Each subagent does ONLY its specific task |

**Net saving:** ~2 minutes per workflow for retry tickets, ~45 seconds for first-time tickets —
figures for a run where no later phase edits a file. A phase that does edit one gives back one
gate re-run, and that re-run is mandated rather than waste (Step 11a).

### Compliance check

The compliance self-check at Step 15 now verifies this:
- "Did subagent prompts include [PRIOR CONTEXT] sections?"
- "Were redundant test runs avoided via context passing?"

---


---

## Phase summaries — worked examples

The MANDATORY four steps and the phase summary card template are in the always-loaded
`rules/agents.md` → "Phase Summaries" / "Phase summary card format". That is the single
canonical copy — `commands/flow.md` points there, and this skill deliberately does NOT
restate it. What follows is only the material that is genuinely reference: worked
good/bad examples of the specificity the card demands.

**Specificity rules — be detailed, not vague:**

Bad: "Explored the codebase and found relevant files"
Good: "Read WorkOrderSeverityExtensions.cs (3 methods: ToAxonString, ToWorkOrderSeverity, ToDisplayString). Found zero test coverage. Similar file WorkOrderStatusExtensions has full tests — can follow that pattern."

Bad: "27 tests written (happy path, error handling, round-trip)"
Good:
```
Tests cover:
  ToAxonString()        — 5 happy path + 1 invalid enum
  ToWorkOrderSeverity() — 5 happy path + 4 invalid strings
  ToDisplayString()     — 5 happy path + 1 fallback
  Round-trip            — 5 enum→string→enum consistency
All 27 passing, 0.7 seconds
```

Bad: "Brainstorming complete — decided on approach A"
Good: "Considered two approaches: (A) add tests following existing StatusExtensions pattern, (B) refactor the class first then add tests. Chose A because the class is stable and well-structured — refactoring would add risk without benefit."

**The user should be able to understand what was done and why without reading the code.** Write phase summaries so that a beginner developer or a tester can follow along. This means:
- **Explain technical terms** the first time they appear — one short phrase, not a paragraph (e.g. "Theory tests (same test, different inputs)" not a 3-sentence explanation of parameterised testing)
- **Say what, not just how** (e.g. "Tests verify all 5 severity levels convert correctly" not just "[Theory] with [InlineData]")
- **Use plain language for the agent opinion** — "I think this is safe because..." not "No regressions detected in the dependency graph"
- **Jira comments follow the same rule** — team members who aren't developers will read them

**Keep it concise.** Explain enough to understand, then stop. Not too much, not too little:
- Bad (too little): "26 tests pass"
- Bad (too much): "26 tests pass. These tests use the xUnit testing framework which is a popular open-source unit testing tool for .NET. Each test method is decorated with attributes that tell the test runner..."
- Good: "26 tests pass — covers all 5 severity levels (happy path), 4 kinds of bad input (error handling), and round-trip consistency"

Then close with `Proceeding to [next phase]. (Interrupt to revise or stop.)` and **continue** —
the card is a window, not a gate (`rules/agents.md` phase-card step 4, `rules/autonomy.md`). Ask
only when Status is BLOCKED or the phase raised a category question.

**⛔ When an ask IS warranted, it uses the AskUserQuestion tool with its category as the header**
(`Irreversible` / `Scope` / `Unknown` / `Conflict` / `Blocked`) — that is what `enforce-ask-budget.sh`
checks. **If you recommend a specific option, it MUST be the FIRST option in the list** and have
"(Recommended)" at the end of the label. Do not list the recommended option second or third — the
AskUserQuestion tool docs require it to be first.

**Phase-by-phase requirements:**

The last column is what the user CAN redirect by interrupting — not a question the agent puts to
them. The agent takes the first option in each row and says so; the others are what an interruption
can still change.

| Phase | Summary must include | Agent opinion examples | User can redirect to |
|---|---|---|---|
| **Discovery** | Which files read, what was found, risks identified, dependencies | "This ticket touches 3 services — consider breaking it up" / "Simple change, low risk" | Continue, keep investigating, or skip |
| **Ticket Assessment** | What's being asked, code needed (yes/no), specific files affected | "Ticket is vague — brainstorming will help clarify scope" / "Clear requirements, ready to plan" | Proceed, edit scope, or pick different ticket |
| **Brainstorming** | Approaches considered, trade-offs for each, chosen approach and why | "Approach B is safer but slower — I'd recommend A for this scope" / "Both approaches are valid, user preference" | Approve design, revise, or start over |
| **Planning** | Exact file paths, phases with dependencies, estimated scope (small/medium/large) | "This is larger than it looks — 8 files across 2 services" / "Straightforward, single file change" | Approve plan, revise, or pick different approach |
| **Implementation** | Files created/modified, each method/scenario tested (not just counts), test results | "All tests pass but I noticed the existing code doesn't handle null — worth a follow-up ticket?" | Continue to review, make changes, or stop |
| **Code Review** | Grade (A-F), each finding with severity and file/line, specific suggestions | "Grade A but the public API could use XML docs for maintainability" | Fix issues, skip non-blocking, or stop |
| **Verification** | Each test suite result, coverage percentage, reality checker findings | "All green but integration tests weren't run — CI will cover those" | Continue to PR, fix issues, or stop |
| **PR Creation** | PR number+link, CI check results, ticket status, branch name | "PR is clean. 5/5 CI checks passed. Ready for human review." | Pick next ticket, stay on ticket, or end session |

---
