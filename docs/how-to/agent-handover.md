# Agent Handover

How agents hand off context to each other within a workflow, where notes are stored, and how the handover file survives across sessions.

---

## When to Read This

- You want to understand how agents communicate between workflow phases
- A handover note is missing or seems incomplete
- You want to understand what gets posted to Jira and Beads

---

## The single handover file

There's one handover file: **`.claude/handover.md`**.

- **Owner:** the main Claude Code orchestrator (one writer — see Single-Writer Rule below)
- **Scope:** one task per file (typically one Jira ticket or one `/build` session)
- **Gitignored:** never committed. Each task generates a fresh log.

Previous versions of this toolbox also had `.claude/antigravity-handover.md` and `.claude/backup-handover.md` for cross-tool sync. Those legacy files are removed by the next `./scripts/install.sh` run.

---

## Single-Writer Rule

Only the main orchestrator writes to `.claude/handover.md`. Subagents return findings in their response messages; the orchestrator appends them to the file in the correct phase order.

**Why:** without this rule, subagents writing concurrently produce out-of-order entries and duplicate runs (the reality-checker has appended its entry before Assessment in the past; full test suite ran 3× in one workflow because subagents couldn't see the handover state).

**How it's enforced:** The Single-Writer Rule is defined in `rules/handover.md`. Subagent prompts include the explicit instruction "Return your results in your response message. Do NOT write to .claude/handover.md — the orchestrator handles that."

---

## How handover works within a workflow

When one phase finishes, the orchestrator appends a structured entry to `.claude/handover.md`. The next phase reads this entry (and all prior entries) before starting — so it doesn't repeat work or miss context.

### Phase append order

Regardless of the order subagents return in, the orchestrator appends entries in this order:

```
1. Discovery
2. Execution Plan (chief-of-staff)
3. Assessment
4. Brainstorming
5. Planning
6. Implementation
7. Code Review (tdd-guide + code-reviewer + reality-checker findings consolidated into ONE entry)
8. Verification
9. PR Creation
```

### Handover entry format

```markdown
## [Phase Name] — [Workflow]
Completed: [timestamp]
Status: PASSED / PASSED WITH NOTES / BLOCKED

### Agent and model used
- Agent: [which agent/skill ran this phase]
- Model: [actual] — Expected: [from phase table] → match / VIOLATION
- Independence: Yes (different agent from implementation) / No

### What was done
- [specific actions — not vague summaries]

### What was found
- [specific findings, issues, decisions]

### Files changed
- [every file created, modified, deleted]

### What the next phase needs to focus on
- [specific guidance]

### Blockers (if any)
- [specific blockers or "None"]
```

### Status values

| Status | Meaning |
|---|---|
| PASSED | Work completed successfully, no issues |
| PASSED WITH NOTES | Work completed but there are observations for the next phase |
| BLOCKED | Work cannot continue — the next phase or user needs to resolve something |

### Where handover notes go

1. **`.claude/handover.md`** — the single in-repo handover file (gitignored)
2. **Jira comment** — a human-readable summary is posted to the Jira ticket by the `jira-workflow-steward` subagent (Haiku)
3. **Beads update** — structured data is updated in Beads for cross-session tracking

---

## Switching between Claude and Codex

Claude and Codex use the same durable GoalRun state and the same concise
handover file. The orchestrator remains the single writer; whichever provider
continues the run reads the last verified phase and next action. Native host
features are used only when available, while the shared runtime preserves the
workflow contract across providers.

---

## Example chain

For a typical `/flow` task on a Blazor component:

```
Discovery phase (Opus subagent via discovery skill)
  → returns findings in response
  → orchestrator appends to handover.md

Execution Plan (Opus chief-of-staff)
  → returns per-phase agent assignments
  → orchestrator appends to handover.md

Assessment
  → append

Brainstorming
  → append

Planning (Opus planner)
  → append

Implementation (Opus implementing subagent — spawned by orchestrator, writes the feature code)
  → implementing subagent returns results (files changed, tests passing, observations)
  → orchestrator appends phase entry to handover.md

Code Review (orchestrator invokes code-review-orchestration skill)
  → skill spawns chief-of-staff (Opus, ephemeral)
  → chief-of-staff reads diff, returns reviewer list, dies
  → orchestrator spawns reviewers: code-reviewer + reality-checker + conditional agents
  → each reviewer returns findings in response
  → orchestrator consolidates into ONE code review entry
  → appends to handover.md

Verification (Opus, via verification-before-completion skill)
  → returns findings
  → append

PR Creation (Opus, via finishing-a-development-branch skill)
  → returns PR URL + merge status
  → append

[task complete — handover.md persisted for /continue]
```

---

## What happens if a handover is missing

If `.claude/handover.md` is missing or empty when `/continue` or a workflow expects it:
- The agent tells the user "No prior handover found — treating as a fresh task"
- Normal operation: starting a genuinely new task begins with an empty handover file
- Unexpected operation (e.g. `/continue` expected to find context): the user is asked whether to start fresh or describe what they were working on

---

## Gitignore

`.claude/handover.md` is gitignored. It's ephemeral — each task generates a fresh log. Never commit it.

---

## Template

See `examples/handover.md.example` for the full template.
