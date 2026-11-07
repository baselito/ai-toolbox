# The Independence Principle

The core rule that shapes the entire toolbox: **no agent verifies its own work.**

---

## When to Read This

- You want to understand why the workflow has so many separate agents
- You want to know which agent/skill is responsible for each verification
- You're designing a new workflow and wondering if a step can self-verify
- You want to understand why the hooks block what they block

---

## The Principle

**An agent cannot grade, review, or verify work that it performed itself.**

This applies at every level:

| Work performed by | Verified by | Never verified by |
|---|---|---|
| Implementing agent | chief-of-staff + review agents | Implementing agent itself |
| Review agents | reality-checker | Same review agents |
| Orchestrator (whole workflow) | compliance-audit subagent | Orchestrator itself |
| jira-workflow-steward (Jira writes) | acli success response | jira-workflow-steward claiming success |
| PR body content | finishing-a-development-branch skill template | Agent writing PR inline |

The pattern: every verification is done by a **different agent or skill** than the one that did the work being verified.

---

## Why This Matters

### The incentive problem

An agent grading its own work has every incentive to report ✅. Past test sessions proved this:
- Compliance self-check claimed all 14 items ✅ when reality was 3-4 violations
- PR template compliance claimed ✅ when the agent had written the PR inline
- Test coverage claims matched the agent's own narrative, not the evidence

### The blind spot problem

Two forms of blind spot to defend against:

**Form 1 — Direct: the implementing subagent cannot review its own code.** It already decided "this approach is correct" while writing. It will not catch:
- Edge cases it didn't think of during implementation
- Security issues it didn't consider during design
- Code quality issues that look normal to the author but weird to a reviewer

**Form 2 — Indirect: the orchestrator has session-context bias even though it didn't write the code itself.** The orchestrator coordinated the implementing subagent and received its results. It knows what the subagent tried, what it struggled with, what it skipped. If the orchestrator picked reviewers, it would unconsciously prioritise angles that match what the subagent already covered — missing what the subagent didn't consider.

Chief-of-staff has neither blind spot. It's a fresh Opus deep-reasoning subagent (see `rules/performance.md` "The four tiers") spawned just to read the git diff and return a reviewer list. No implementation history, no witness context. Independent by construction — the independence comes from the **fresh spawn**, not from which model it runs on.

### The compounding problem

Without independence, errors compound. If the implementing subagent self-reviews and misses a bug, the bug ships. If the orchestrator self-audits and misses a compliance violation, that violation becomes a pattern. Independence breaks the chain by introducing a fresh-context reviewer-selector (chief-of-staff) and fresh-context reviewers (never the writer, never the coordinator).

---

## The Separation Model

### Level 1 — Implementation separated from review

```
Implementing subagent (Opus, spawned by the orchestrator in Phase 5)
   │ writes the code
   ▼
[IMPLEMENTATION COMPLETE — subagent returns results]
   │
   ▼
Orchestrator receives results. Cannot review own-session's code.
Can only REQUEST review via a skill.
   │
   ▼
Orchestrator invokes: Skill("code-review-orchestration")
   │
   ▼
code-review-orchestration skill
   │ spawns a NEW deep-reasoning-tier subagent
   ▼
chief-of-staff (Opus; ephemeral) ─────────────────────────── INDEPENDENT reviewer-selector
   │
   │ Reads file diffs fresh. Decides who reviews based on files changed.
   │ NOT the implementing subagent. NOT the orchestrator.
   │ NOT biased by implementation decisions — hasn't seen the code.
   ▼
Returns reviewer list, dies. Orchestrator spawns the reviewers:
   ├── tdd-guide ─────── test quality
   ├── code-reviewer ── A-F grading, OWASP
   ├── reality-checker ─ production readiness (always LAST)
   └── conditional agents based on file patterns
```

**Three different agents handled the code at this point:** the implementing subagent wrote it, chief-of-staff picked the reviewers, and the reviewers read it. None of them can self-approve. That's the principle.

### Level 2 — Review separated from acceptance

```
Review agents return findings
   │
   ▼
reality-checker ─── independent "production ready?" gate
   │
   │ Not the same agent as code-reviewer or tdd-guide.
   │ Its job is to verify the REVIEWERS signed off — not to review the code.
   ▼
If all reviewers PASSED → proceed
If any BLOCKED → escalate to user (never auto-override)
```

### Level 3 — Workflow separated from audit

```
Orchestrator completes all phases
   │
   ▼
[WORKFLOW COMPLETE]
   │
   │ Cannot audit own workflow. Must spawn independent auditor.
   ▼
Spawns: compliance-audit subagent (Opus, general-purpose)
   │
   │ Fresh context. No investment in looking good.
   │ Reads handover.md from scratch.
   │ Evidence-based checks (grep, bd show, acli view) — not claims.
   ▼
Returns findings with ✅/❌/⚠️ per item
   │
   ▼
If PASS → proceed to PR creation
If FAIL → user decides whether to override
```

---

## How Enforcement Works

The Independence Principle is enforced by PreToolUse and PostToolUse hooks — structural gates the agent cannot bypass. `hooks/` holds 21 shell files: **20** Claude Code hooks plus the local-only `pre-commit-check.sh`, which `install.sh` does not copy. The table below gives a row to **15** of them.

### Hooks that enforce independence

**`~/.claude` in this table means the RESOLVED state root**, not a literal path — the marker path is `${CLAUDE_STATE_DIR:-$HOME/.claude}`. **Twelve** of the hooks below are STATE-ROOT GATES: `enforce-auto-poll`, `enforce-chief-of-staff`, `enforce-codex-review`, `enforce-compliance-audit`, `enforce-fable-review`, `enforce-jira-delegation`, `enforce-pr-skill`, `enforce-skill-delegation`, `enforce-transition-script`, `enforce-workflow-start`, `pr-action-safety` and `push-safety`. Each of those refuses to run at all unless the resolved root is absolute, an existing directory, readable and searchable, and spelled with characters the gate can safely print in its own remedy — because a non-existent or relative root used to slip the emptiness check and then read a marker that could never be there, which is a fail-OPEN, and an unpasteable root turned the printed remedy into something that executes or expands instead of naming a directory. Each gate's deny prints the root it actually resolved, so the remedy it hands you is followable under an override.

The other five rows are deliberately NOT in that set, and the earlier wording here ("every gate below reads its marker from ...") hid the difference: `auto-poll-after-pr` and `consume-pr-markers` resolve the same root but are the PostToolUse writer and consumer rather than gates, so they carry no guard; `enforce-loop-bounds` decides from the tool payload and `audit-model-usage` only appends to a log, so neither reads the state root at all; and `enforce-standing-auth` resolves the root but does not gate on it, because its primary test is the file NAME (`memory.md`) rather than a marker under the root — an unresolvable root degrades it from two detection rules to one instead of blinding it, so refusing to run would trade a partial detector for none at all. **Two of the twelve gates have no row in the table below**: `enforce-auto-poll` and `enforce-codex-review`. They carry the guard and behave exactly as the twelve are described here; the omission is in the table, not in the enforcement. Named rather than left to be reconciled, because counting the rows against the list above is how a reader concludes two hooks are unguarded when they are not.

`TC-DOC-SR-1`/`TC-DOC-SR-2` in `scripts/verify-hooks.sh` derive both the list and the count above from the hooks themselves, so this paragraph cannot drift back.

The `enforce-standing-auth.sh` row was intentionally removed from the table because it is not a
state-root gate, but it remains an independence security control: it prevents Write, Edit, and
Bash changes to the standing-consent record, so an agent cannot grant itself authority. The
remaining “other five rows” wording above is historical count language; it does not mean that
hook has a table entry or grants consent.

| Hook | What it blocks | Independence it enforces |
|---|---|---|
| `enforce-chief-of-staff.sh` | Direct review agent spawns without active `~/.claude/.review-orchestrated` marker | Implementer can't select own reviewers — marker proves chief-of-staff ran for THIS review cycle |
| `enforce-fable-review.sh` | `gh pr create` without a `~/.claude/.fable-review-complete` line keyed to the current HEAD sha (`reviewed <sha>` — the only accepted word) | The pre-push adjudication — reading the final diff and judging it against what the ticket asked for — can't be skipped or satisfied by a review of an earlier commit. **No outage escape, deliberately.** The `unavailable <sha>` line this shipped with was copied from the Codex gate, where the escape is bounded by a fact outside the agent (CLI down, spend cap) and written by a producer only after a real attempt. Neither holds here: there is no state of the world in which an orchestrator executing Bash cannot read its own diff, and there is no producer — so `unavailable` would be the ONLY path, hand-written every time because it is one word shorter than the honest one. An escape hatch with no other path through it is a hole with a label on it. The word goes in the same change that adds a producer. ⛔ **Not yet self-serving:** nothing in the toolbox writes the marker, so the deny message is currently the only producer spec, and the first PR after install blocks loudly by design. (`install.sh` now copies the hook in the checked form — issue #160, pinned by `TC-EFR-8`) |
| `enforce-pr-skill.sh` | `gh pr create` without active `~/.claude/.pr-skill-invoked` marker (single-use, consumed on success by `consume-pr-markers.sh`, expires after 3600s) | Agent can't write PR body inline — template must load via skill for every PR |
| `enforce-compliance-audit.sh` | `gh pr create` unless `~/.claude/.audit-complete` (a) is keyed to the current HEAD via a first-line `AUDIT HEAD: <full sha>` and (b) ends with an `AUDIT COMPLETE:` line whose verdict is `PASSED`. A `BLOCKED` verdict denies and the deny quotes the audit's own summary line; a verdict the hook cannot read denies too (unknown input is not consent). Single-use, consumed on success by `consume-pr-markers.sh`, expires after 3600s — each PR needs a fresh audit | Agent can't self-grade compliance — the audit subagent must produce a report with content, bound to the commit it read, whose stated conclusion is the one the gate acts on. Until issue #153 the hook read the signature line and never the verdict, so an audit ending `BLOCKED` opened the PR anyway (confirmed live twice, 2026-08-26) |
| `consume-pr-markers.sh` | (PostToolUse on Bash) Consumes `.pr-skill-invoked` and `.audit-complete` ONLY after a `gh pr create` whose stdout contains a PR URL — proving the PR was actually created | Prevents "gates fail in rotation" deadlock: PreToolUse gates no longer delete their marker on allow (a DENY from another gate would have consumed a passed gate's marker, forcing needless re-invoke/re-audit on retry) |
| `enforce-jira-delegation.sh` | Direct `acli` writes without a valid `~/.claude/.jira-delegation-token` (< 3600s old, session-level — not consumed on use) | The orchestrator tier can't do Haiku's job — it creates the token once per workflow before the first jira-workflow-steward spawn |
| `enforce-skill-delegation.sh` | Direct Skill invocation on orchestrator | The orchestrator can't run delegated (Opus) skills itself |
| `enforce-transition-script.sh` | Bare `acli transition` commands without a valid delegation token or `python3` wrapper | Forces transitions through jira-workflow-steward — token check (does not consume) or python3 wrapper |
| `push-safety.sh` | Force-push on ANY branch (`--force`, `-f`, `--force-with-lease`), any `git push` while on main/master (including chained commands), plus explicit pushes to main/master from any branch | User must approve for main/master pushes; force-push is always blocked (the `/review-pr` "never force-push" rail) — `--dry-run` exempted |
| `pr-action-safety.sh` | `gh pr merge` and `gh pr close` (any PR, any flags) | Autonomous agents cannot merge or close a PR — both are human-only actions per the `/review-pr` safety rail |
| `enforce-workflow-start.sh` | `git checkout -b` with a Jira ticket-ID pattern (e.g. `TASK-756`, `DEV-5647`) without active `~/.claude/.workflow-started` marker | Agent can't skip `/start` → `/flow` and jump straight to branch creation — natural language like "start working on X" must route through the workflow |
| `auto-poll-after-pr.sh` + `enforce-auto-poll.sh` | (PostToolUse + PreToolUse pair) After `gh pr create` or `git push` to a branch with an open PR, creates a pending marker. PreToolUse blocks subsequent Bash calls until auto-poll cron is set up. | Agent can't forget auto-poll — structural two-part gate covers both PR creation and subsequent pushes (configured reviewer reviews new commits too) |
| `enforce-ask-budget.sh` | (PreToolUse on AskUserQuestion) A question whose `header` does not begin with `Irreversible`, `Scope`, `Unknown`, `Conflict` or `Blocked` — and EVERY question in the payload must qualify, so bundling one real category ask with three "shall I continue" ones does not launder the three | An agent can't spend the user's attention without naming why. It is the mirror image of the other gates: those stop the agent doing too much on its own, this one stops it doing too little. **Opt-in** — a no-op unless `~/.claude/memory.md` carries `- Autonomy: goal`, so no other developer's prompting changes. Fail directions are deliberately opposite: an unreadable **payload** fails **closed** (no readable headers must not read as "the categories are fine" — stricter than its neighbours here), while an unreadable **memory.md** fails **open**, because that file is the opt-in switch and denying there would block every ask in the session, including the Irreversible ones. Residual: it checks that a category was NAMED, never that the claim is honest, and it cannot see a question the agent merely writes in prose. Doctrine: `rules/autonomy.md` |
| `enforce-loop-bounds.sh` | (PreToolUse on CronCreate + Skill) A recurring `CronCreate` whose prompt is not in the hook's registry of self-terminating prompts; a `/goal` condition that sets a goal without a turn clause, without a no-progress clause, or with a number outside the `workflow-discipline` skill §1d ceilings; and (issue #146) a `/loop` Skill invocation whose arguments fail the same two-clause check — including a bare `/loop` with no arguments, the self-pacing form, which is the most unbounded shape there is | An agent can't grant itself an unbounded unattended loop **on the paths this hook sees** — which, since #146, includes `/loop`, the harness's own primitive. That one matters most: `CLAUDE_CODE_MAX_TURNS` and `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` are unset and set by no toolbox script, so before this detector a `/loop` carried no ceiling from any layer. The bound is declared where the loop is created and checked against a toolbox-owned registry, not asserted at the call site. Fails **closed** on every *semantic* ambiguity in a well-formed payload; a payload that is not a readable JSON OBJECT does not block — but NOT uniformly, and the difference matters: measured across the 15 registered gates, **11 ABORT** under `set -euo pipefail` on an unguarded `jq` read (exit 5, no JSON) and only **4 fall through**. Either way nothing denies, so the call proceeds. This line used to say it was "the behaviour of every PreToolUse gate" — that was never measured and is false by eleven. Separately, an absent or renamed `tool_name` makes all **15** silent no-ops, which is quieter still. Both rest on an integrity assumption about our own runtime rather than a boundary defended against an adversary — the only adversary-controlled field is `tool_input.command`, a JSON string the serialiser escapes (verified against six payloads built to break a naive serialiser: all produced valid JSON, zero aborts). Tracked as issue #165. Registered on `CronCreate` and `Skill` only: Bash is deliberately not a matcher so quoting a `/goal` example in a file is never blocked, and a `/goal` the **user** types is therefore not observable here — that bound rests on `commands/flow.md` plus compliance check 14. Doctrine: the `loop-design` skill |
| `audit-model-usage.sh` | (PostToolUse on Agent — does NOT block; logs only) Appends every Agent spawn to `~/.claude/model-audit.log` with timestamp, agent type, model, and description | Self-reported model compliance is not independently verifiable — TASK-760 had a handover claiming "✅ match" while the orchestrator ran a skill inline on Opus. The log is the external audit trail. Inspect with: `tail ~/.claude/model-audit.log` |

**Per-cycle enforcement (not per-session).** The markers are single-use: `consume-pr-markers.sh` (PostToolUse) deletes `.pr-skill-invoked` and `.audit-complete` only after a `gh pr create` whose stdout contains a PR URL — proving the create actually succeeded. A second PR in the same session therefore requires fresh skill invocation and a fresh audit. This is intentional — session-wide opt-in is incompatible with the Independence Principle. The PostToolUse placement (rather than the old PreToolUse delete-on-allow) also eliminates the "gates fail in rotation" deadlock where a DENY from one gate consumed another gate's marker, forcing needless retries.

Without these hooks, the principles would be documentation — which the agent can ignore. With them, the principles are architectural — the agent physically cannot violate them.

---

## What Agents CAN Self-Do (limited cases)

Independence doesn't mean every action needs a separate agent. Some things are inherent to the work:

| Action | Who does it | Why self-allowed |
|---|---|---|
| Read files for Discovery | Discovery subagent itself | Reading is research, not verification |
| Run tests during Implementation | Implementation subagent | Running is part of TDD cycle |
| Update handover.md | Orchestrator ONLY | Single writer is the rule (see handover.md) |
| Report progress to user | Orchestrator | Not verification — just status |

The rule is: **verification requires separation, execution does not.** An agent can write code, run commands, and update its own progress tracking. But the moment it needs to validate that work was done correctly, a different agent steps in.

---

## Common Violations (now prevented)

These patterns showed up in test sessions before the hooks were added:

### "I already know which agents to run"
```
Old: Implementer directly spawned Agent(subagent_type: "code-reviewer")
New: BLOCKED by enforce-chief-of-staff.sh for EVERY review agent spawn —
     must invoke code-review-orchestration skill, which creates a fresh
     ~/.claude/.review-orchestrated marker. One marker per review cycle.
```

### "I already invoked the skill earlier in this session — I can spawn reviewers now"
```
Old: Transcript fallback allowed this — once "code-review-orchestration"
     appeared in the transcript, all future spawns passed silently
New: BLOCKED — marker file is the only gate. Each review cycle must
     invoke the skill fresh. (Closed April 2026 — see hooks commit log.)
```

### "I'll just write the PR body inline — the skill is overkill for this"
```
Old: Implementer ran gh pr create with inline body text
New: BLOCKED by enforce-pr-skill.sh — must invoke finishing-a-development-branch
     skill, which creates ~/.claude/.pr-skill-invoked. Marker is deleted
     on first allow, so a second PR in the same session requires a
     fresh skill invocation (and a fresh template load).
```

### "I verified everything during implementation — no need for compliance check"
```
Old: Self-check claimed all ✅, PR created
New: BLOCKED by enforce-compliance-audit.sh — independent audit subagent must run first
```

### "acli is just a Bash command — I can run it directly"
```
Old: the orchestrator ran the Jira comment write inline (30x the cost of Haiku)
New: BLOCKED by enforce-jira-delegation.sh — must spawn jira-workflow-steward (Haiku)
```

---

## Applies To

This principle is universal across the toolbox. When adding new workflow steps, new skills, or new agents, ask:

1. **Who does the work?** (implementer, specialist agent, skill)
2. **Who verifies it was done correctly?** (must be different from #1)
3. **Is there a hook that enforces the separation?** (if not, add one)

If #1 and #2 are the same, the design is wrong. Split them.

---

## See Also

- [agents.md](agents.md) — the full list of agents and their roles
- [skills.md](skills.md) — skills that wrap verification patterns
- [mcp.md](mcp.md) — MCP connections that provide independent data sources (Seq, Context7)
- [flow.md](../../commands/flow.md) — the full workflow with all enforcement points
