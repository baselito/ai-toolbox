---
name: handover-protocol
description: The exact `.claude/handover.md` phase-entry template and the Deviations field guidance behind the always-loaded handover rule. Carries the full per-phase entry shape (agent/model used, what was done, what was found, files changed, what the next phase needs, deviations, blockers), the five deviation categories with worked examples, how to write an honest deviation entry, and what happens to captured deviations (now vs the future /learn loop). Load this when appending a phase entry to the handover file, when filling in the Deviations field, or when you need the rationale for why honest deviation reporting is explicitly safe. The Single-Writer Rule, the spawn cycle, and the phase append order stay in the always-loaded `rules/handover.md` and always apply.
---

# Handover Protocol — Detail

The always-loaded directives — the **Single-Writer Rule**, the spawn cycle, the phase append
order, and the append-never-overwrite rules — are in `rules/handover.md` and always apply. This
skill carries the formats and the guidance that are only needed at the moment you actually write
an entry.

## During Workflows

After completing each workflow phase, append your findings to `.claude/handover.md`. **Be specific** — if the session ends and resumes later, the next invocation needs to continue from this entry without any other context:

```
## [Phase Name] — [Workflow]
Completed: [timestamp or "just now"]
Status: PASSED / PASSED WITH NOTES / BLOCKED

### Agent and model used
- Agent: [which agent/skill ran this phase — e.g. "brainstorming skill", "planner agent", "code-reviewer agent"]
- Model: [actual] — Expected: [from phase table] → ✅ match / ❌ VIOLATION
- Independence: [Yes if different agent from implementation, No if same agent did both]

### What was done
- [specific actions: "Created PaymentController.cs with BulkInvite endpoint"]
- [specific actions: "Added InviteRequest model with Email, Role, TeamId fields"]
- [specific actions: "Wrote 3 unit tests in PaymentControllerTests.cs — all passing"]

### What was found
- [specific findings: "N+1 query risk in GetUsers — needs Include() for Teams"]
- [specific findings: "Auth middleware already handles role validation — no extra work needed"]

### Files changed
- [list every file created, modified, or deleted in this phase]

### What the next phase needs to focus on
- [specific guidance: "Run security review on SearchEndpoint — raw SQL concatenation on line 47"]

### Deviations (honest self-reflection)
- [deviation 1: "Skipped code-review-orchestration for instruction-file edits. Rule in rules/agents.md Iron Law says 'all code changes go through orchestration' — did not clearly include/exclude instruction files. Applied judgment: treated as doc changes. Effect: none observed this session. Proposed prevention: clarify Iron Law scope to name instruction files explicitly."]
- [deviation 2: "Used gh api string-escape on reply body without sanitizing for the trailing-newline edge case. Effect: reply posted correctly but 3 API calls showed stderr warnings. Proposed prevention: document the echo -n vs printf handling in respond-to-pr-reviews skill."]
- [if no deviations: "None observed."]

### Blockers (if any)
- [specific blockers or "None"]
```

**Important:** Don't write vague entries like "implemented the feature" or "reviewed the code". Write what was specifically done, what files were touched, and what was found.

## Deviations field — why it exists and how to fill it honestly

The `Deviations` field is the **seed for toolbox self-improvement**. It captures moments where the orchestrator (or a subagent) deviated from the prescribed process — whether or not the deviation affected the outcome. Accumulated entries feed future aggregation (see `docs/how-to/self-improvement.md` once PR 2 lands) into targeted toolbox updates.

**What counts as a deviation:**

| Category | Example |
|---|---|
| **Rule violation** | Iron Law requires code-review-orchestration; skipped it because "this was simple" |
| **Missing guidance** | Rule doesn't cover the situation; made a judgment call without a precedent to cite |
| **Ambiguous instruction** | Phase table says "Sonnet" but file-type table says "Opus" for the same work; picked one, documented which |
| **Tool brittleness** | Hook blocked a legitimate operation; worked around it by X instead of fixing the hook |
| **Context constraint** | Prescribed agent/skill was unavailable (delegated session, hook chain deadlock); substituted Y |

**How to write a good Deviation entry:**

- **Be specific.** Name the rule/instruction/phase that was deviated from. Not "some rule" — `rules/agents.md:42 Iron Law`.
- **State the judgment.** What you decided to do, and why that seemed right.
- **Note the effect.** None / minor / material. Honest.
- **Propose prevention.** A specific change: rule wording, new guard, better hook, or "unknown — needs investigation."

**Honest reporting is explicitly safe.** This field exists to improve the toolbox, not to blame the orchestrator. A handover with unreported deviations that surface later (via automated-review, compliance audit, or user correction) is worse than a handover with transparent ones. If the orchestrator self-reports a deviation, that's a signal the toolbox has an ambiguity or brittleness to fix — not a fault of the orchestrator.

**If there truly were no deviations,** write `None observed.` Short. Blank is not acceptable — it reads like "didn't bother."

**What happens to captured Deviations (current state vs future):**

- **Now:** Entries accumulate in `.claude/handover.md`, and when a toolbox PR merges the post-merge fold snapshots them to `~/.claude/pending-deviations-<PR>.log` — a snapshot rather than live handover, so a later task clearing handover.md cannot race the read. The snapshot is written only when the fold can establish that handover.md is *that PR's* work: its trailing `# ` task heading names the PR's branch as a WHOLE word, or an issue the PR actually CLOSES (a GitHub closing keyword — `closes`/`fixes`/`resolves`, including the cross-repo `owner/repo#N` form), or — when the heading names nothing identifiable — the merge is under an hour old. A merely *referenced* issue does NOT bind: a PR reading `Closes #154; follow-up #777` would otherwise claim #777 and file that task's deviations here. Otherwise the fold refuses, says which measurement refused, and leaves handover.md untouched; a run long after the merge would otherwise file the *next* task's deviations under the old PR (issue #154). The snapshot protects the READ from a racing task; this gate is what protects the WRITE. `/review-pr` on a merged toolbox PR then SWEEPS every queued snapshot (newest first, not just the merging PR's own), shows the ~15 newest with a count of the remainder, and offers `improve N` / `ignore N` per item. What a human was actually shown is recorded in `~/.claude/surfaced-deviations.log` so the next run resumes rather than repeating — an unattended cron fire records nothing, since a run with no reader has shown nobody anything, and an attended run that prints nothing while undecided records remain clears the marker so the queue comes back. A snapshot is archived to `~/.claude/consumed-deviations/` only once it holds at least one record AND every record in it has been **dismissed** — decided, not merely seen. The "at least one" is not padding: "every record decided" is vacuously true of a 0-byte or blank-lines-only snapshot, and archiving one would create the very evidence `verify.sh` reads as "a triage has completed on this machine". A record-less snapshot is reported as holding no records and removed by hand; a surfaced-but-undecided snapshot stays queued so an unattended cron fire cannot retire work nobody read. Nothing is deleted. Whatever is still queued is reported by `verify.sh` on every run, so a stalled queue cannot go unnoticed. **Triage itself is human-gated: the surface proposes, the user decides.**
- **A note on what the fold captures:** only bullets under a `### Deviations` heading, up to the end of that phase block. Bullets in a following `## ` phase block are not deviations and are not captured — so a deviation must live under its own heading to be surfaced at all. The one body it deliberately skips is the exact text `None observed.`, and only when that is the WHOLE bullet: a real deviation that quotes the phrase (a write-up about a review that was skipped, say) is still captured, because dropping it would lose the record with nothing anywhere saying so.
- **Phase 1 learning loop (live as of this PR):** Separately, review FINDINGS (from automated-review + Codex review rounds) are captured at review time and consolidated at merge time into candidate learned lessons. An AI+Codex consensus pass (R1) decides which to keep; the user triages kept findings via `lessons-keep/drop` commands; approved lessons land in `knowledge/toolbox-lessons.yml` via a human-gated PR (R2 — never auto-merges). The fast tier (`~/.claude/toolbox-knowledge/lessons.yml`) is then synced by `sync-toolbox-lessons.sh` and injected into future review prompts (advisory, untrusted). This addresses review-finding recurrence, not workflow-deviation recurrence — two complementary loops, separate machinery.
- **Next (PR 2, future):** A `/learn` command will aggregate the deviation entries above (from handover.md), identify repeated root causes, and draft a toolbox PR proposing the rule/skill update. The user reviews the draft before the PR is created. A configured reviewer reviews the PR. The user merges via `/merge-pr` once gates pass.
- **Never:** autonomous toolbox self-modification without a PR. Every change still flows through `/review-pr` → automated-review → branch-protection gates.

---

## Why the Deviations field is worth the effort

A handover with unreported deviations that surface later (via automated-review, a compliance audit, or a
user correction) is worse than one with transparent ones. A self-reported deviation is a signal
that the toolbox has an ambiguity or a brittleness to fix — it is not a fault of the orchestrator.
That is why honest reporting is explicitly safe, and why `None observed.` is acceptable but a
blank field is not.
