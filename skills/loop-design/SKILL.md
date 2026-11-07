---
name: loop-design
description: How to design an agent loop that is safe to run with nobody watching — the five components a loop needs, the verification ladder that says how strong its proof of progress is, the three guards every loop must carry (iteration ceiling, no-progress detector, spend cap), cost-per-accepted-change as the metric to judge it by, and the list of work that must NOT be looped. Load this before creating any loop, cron, `/goal` condition or unattended run; before raising a loop bound; when a loop is spinning, stalling or spending without landing anything; or when adding a new self-terminating prompt to the enforce-loop-bounds registry.
source: custom
---

# Loop Design — what makes an unattended loop safe

## Why this skill exists

The toolbox had the pieces and no class. `commands/review-pr.md` carried
`MAX_RETRIES=2`/`COOLDOWN=300`, the auto-poll cron carried a 1-day cap,
`skills/codex-review` carried a spend cap — three one-off bounds, each invented
where it was needed. Nothing generalised them, so every new loop either
reinvented a bound or shipped without one, and "it will stop eventually" was an
assumption rather than a mechanism.

This skill is the generalisation. Be precise about how much of it is mechanical:
guard 1 is **hook-enforced on the paths a hook can see**, guard 2 is a **runtime
detector invoked by the loop body** (the toolbox wires it into the registered
`/review-pr --auto` loop, while custom bodies must still call it), and guard 3
is a **native flag that only a run launched as a loop carries**.
The rest is doctrine. Where the harness already ships a primitive, the doctrine
says to use it rather than rebuild it.

---

## 1. The five components

A loop that is safe to run with nobody watching has all five. Missing any one of
them, it is not a loop — it is an unattended process with a hopeful comment.

| # | Component | What it means concretely | Where the toolbox puts it |
|---|---|---|---|
| 1 | **A machine-checkable goal** | An exit condition a *reader with no tools* could verify from the transcript alone. Names commands and exit codes, never outcomes. | `/goal` conditions — `commands/flow.md` → "`/goal` — Machine-Checkable Phase Exits" |
| 2 | **A bounded body** | One iteration does a fixed, finite amount of work and PRINTS its own evidence. An iteration that reports "all green" without showing the gate output makes component 1 unverifiable. | `examples/loop.md.example`; the per-phase templates in `commands/flow.md` |
| 3 | **A verifier the loop does not control** | The pass/fail signal comes from outside the agent's own judgement — the project's declared gates, resolved through the toolbox-owned registry, never from a string the loop could rewrite. | `verification:` block in `PROJECT.md` (keys and numbers only) resolved through the `workflow-discipline` skill §1c |
| 4 | **The three guards** | Iteration ceiling, no-progress detector, spend cap. Section 3 below. | `hooks/enforce-loop-bounds.sh`, `scripts/loop-progress-signature.sh`, `--max-budget-usd` |
| 5 | **An escalation path** | Where the loop hands off when it stops — a human gate, a handover entry, one notification. A loop that stops silently has failed even when its reason for stopping was right. | The escalation table in `examples/loop.md.example`; the phase card + AskUserQuestion in `commands/flow.md` |

**Component 1 has a corollary that gets missed.** The `/goal` evaluator has no
tools: it cannot run a command, read a file or open a coverage report. So a
condition must name its own proof ("`dotnet test` ran to completion with exit
code 0 and its output shows 0 failures"), and the body must actually print that
proof. A body that summarises instead of showing evidence will loop to its turn
bound with the work already finished.

---

## 2. The verification ladder

"Did this iteration make progress?" has five possible answers, and they are not
equally worth anything. Every loop should be able to say which rung it stands
on, out loud.

| Rung | The proof | Worth |
|---|---|---|
| 1 | The agent says so. | Nothing. This is the loop grading its own homework. |
| 2 | A file changed (mtime moved). | **Actively misleading.** See the warning below. |
| 3 | Some command exited 0. | Real but partial — a green subset hides a red whole. |
| 4 | The full declared gate set exited 0, with its output printed. | The working minimum for unattended operation. |
| 5 | Rung 4, plus the coverage floor where the runner reports a figure (UNAVAILABLE by name where it does not), plus a human gate at the phase boundary. | What `/flow` ships. |

**⛔ Rung 2 is the trap, and it is the reason guard 2 exists. ⛔** An
mtime-keyed detector reports a loop that rewrites the same failing file every
iteration as healthy *forever* — the file is being touched, so there is
"activity", and the one situation a no-progress guard exists to catch is the one
it cannot see. `skills/subagent-liveness` was mtime-based, and it is now RETIRED in
favour of `skills/observed-work`, whose progress signal is a declared probe
whose OUTPUT must change — not a file whose mtime moved. Do not reach for an
mtime as a progress signal.

**Rung 4 is the floor for anything unattended.** Below it, the loop cannot tell
converged from stuck, so its bound becomes its exit condition and it will always
spend the whole budget.

---

## 3. The three guards

### Guard 1 — iteration ceiling (hook-enforced where a hook can see it: `hooks/enforce-loop-bounds.sh`)

**Every loop carries an explicit bound, declared where the loop is created.**

| Loop shape | The bound | Native primitive |
|---|---|---|
| A run launched as a loop | `max_turns` from the `loop:` block, clamped | `CLAUDE_CODE_MAX_TURNS` |
| A `/goal` inside an interactive session | The turn clause in the condition text | **none — see the gap in guard 3** |
| A recurring `CronCreate` | A registered self-termination story | n/a |
| A stop-hook loop | Block cap, default 8 | `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` |
| Subagent fan-out | 200 per session | `CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION` |

Use the primitive wherever one exists. The toolbox deliberately keeps **no turn
counter and no spend ledger of its own** — a second source of truth drifts from
the first, and the drifted copy is always the one that is trusted.

`hooks/enforce-loop-bounds.sh` closes the two paths where no primitive applies:

- a **recurring `CronCreate`** whose prompt is not in the hook's registry of
  self-terminating prompts is denied. Registered today: `/review-pr … --auto`
  (the 1-day cap in `/review-pr` Step 0.5, plus merge/close self-termination).
  A genuine JSON boolean `recurring: false` skips **only** the registry check — one
  run is bounded by construction — but it is NOT waved through: the prompt still goes
  to the `/goal` check below, so a single fire carrying an unbounded `/goal` condition
  is still denied. The value must be the JSON boolean; the *string* `"false"` and any
  other type fall through to the registry check, because a runtime that treats the
  non-empty string `"false"` as truthy could schedule as recurring what the hook read
  as one-shot. **Adding an entry means implementing the termination first,
  then registering it in a toolbox PR** — the registry records a reviewed bound,
  not a promise made at the call site.
- a **`/goal` condition** with no turn clause, no no-progress clause, or a
  number outside the `workflow-discipline` skill §1d ceilings is denied. Note
  the asymmetry with `PROJECT.md`: a `PROJECT.md` value on the wrong side of its
  clamp is kept and ignored, because the clamp is behind it. The number in a
  `/goal` condition IS the bound — there is nothing behind it — so an
  out-of-range value is rejected rather than silently clamped.

The hook fails **closed** on every *semantic* ambiguity in a well-formed
payload — an unreadable cron prompt, an unregistered recurring prompt, a `/goal`
whose bounds do not parse — and is registered on `CronCreate` and `Skill` only.
One exception, stated in the hook's own header: input that is not parseable JSON
at all falls through to **allow**, because both `jq` reads yield empty strings
and neither detector then has anything left to match. That is the behaviour of
every PreToolUse gate in `hooks/`, and it rests on the harness emitting
well-formed hook input — an integrity assumption about our own runtime, not a
boundary defended against an adversary. Changing it is a one-line edit that
belongs in all of those gates at once, not in this one alone.

It does not see a `/goal` the user types, and Bash is deliberately excluded so
that reading or editing a file which merely quotes a `/goal` example is never
blocked. For the paths it cannot see, the bound remains
`commands/flow.md`'s requirement and compliance check 14's audit of the recorded
bound in the handover entry.

### Guard 2 — no-progress detector (`scripts/loop-progress-signature.sh`)

**Stop when the failure stops changing, not when the files stop changing.**

The detector keys on a **normalised failure signature**: the sorted set of
failing gate names plus the top error identifier from their output. Two
iterations that fail the same gates with the same error made no progress no
matter how many files they wrote. It returns exit code **3** once that signature
has survived `no_progress_after` consecutive iterations, **0** while the loop is
still moving (or has not yet reached the threshold), and **2** if it could not
run — which the caller must treat as "the detector did not run", falling back to
its turn bound rather than reading silence as progress.

```bash
bash ~/.claude/scripts/loop-progress-signature.sh \
  --state .claude/.loop-progress --failing-gates "test,build" \
  --threshold 2 --output /tmp/gates.log
```

Three properties worth knowing before you trust it, all covered by
`scripts/test-loop-progress-signature.sh`:

- **Churn is normalised away, on purpose.** Timestamps, durations, absolute
  checkout paths, line/column positions, uuids, addresses and long digit runs
  are all folded out, so the same failure reported twice is one signature even
  when every incidental number differs.
- **Short standalone numbers are kept, also on purpose.** `expected 3, got 4`
  becoming `expected 3, got 5` is real movement. Blanking every digit would
  merge two genuinely different failures and stop a loop that was working.
- **`nosignal` is a signature, not an abstention.** When no error identifier can
  be extracted, the failing-gate set alone still trips the threshold, and the
  output is marked `degraded`. Abstaining instead would leave a loop with
  unreadable output permanently exempt from the one guard aimed at it.

This is the mechanism behind the no-progress clause every `/goal` condition is
required to carry. The clause is what a reader sees; this is what makes it true —
**but only when the loop body actually calls it.** The registered auto-poll body
now makes that call; custom loop bodies remain responsible for invoking the
installed detector. No hook can observe arbitrary body internals, so the
condition still has to name the no-progress clause.

### Guard 3 — spend cap (native: `--max-budget-usd`)

**A loop's budget is money, and the harness already meters it.** Spend from
subagents counts toward the parent's budget, and background subagents are killed
at the cap — so there is nothing to add and nothing to reimplement.

`max_spend_usd` in the `loop:` block reaches a run through `--max-budget-usd`
when the run is **launched as a loop**, clamped tighten-only to
`min(project, ceiling)` per the `workflow-discipline` skill §1d.

**⛔ The interactive gap, stated plainly. ⛔** A `/goal` set inside an
interactive `/flow` session was never launched with that flag, so **it has no
dollar bound at all.** Its turn clause and its no-progress clause are the entire
budget. That is exactly why guard 1 rejects a condition missing either clause,
and why the two clauses are mandatory rather than decorative. Do not describe
the spend cap as covering an interactive goal loop — it does not.

The shape to copy for a **non-monetary** cap (a tool that is externally rate- or
quota-limited) is the one `skills/codex-review` already uses: a state file in
`~/.claude` holding a **cause token**, with the suppression TTL chosen by that
cause — `spendcap` earns a 24-hour window because a daily cap resets daily,
anything else gets one hour so a blip does not disable the tool all day, and an
unknown cause is treated as transient so the failure leans toward re-probing
sooner. Reuse that shape; do not invent a second one.

---

## 4. The metric — cost per accepted change

Judge a loop by **spend for the run ÷ changes that survived review.** Not
iterations, not turns, not wall-clock, and above all not "did it finish".

- A loop that converges in 3 iterations and gets its work rejected cost more
  than one that took 12 and landed.
- A loop that never escalates is not efficient, it is unsupervised: the
  interruptions it avoided are the cheapest part of the whole system.
- A falling iteration count with a flat accepted-change count means the loop is
  getting better at giving up, not better at the work.

The corollary for guard sizing: **raising a bound is a change to this metric and
has to be argued on it.** "It ran out of turns" is not a reason to raise
`max_turns` — the usual cause is a rung-3-or-below verifier (section 2) letting
the loop iterate without knowing whether it is closer.

---

## 5. When NOT to loop

A loop is the wrong tool here, and the answer is not a tighter bound:

| Do not loop | Why |
|---|---|
| **No verifiable end state** | With no rung-4 verifier the bound becomes the exit condition, so the loop always spends the full budget and its output is graded by nobody. |
| **Design, planning, brainstorming, architecture** | Judgement work does not converge — it explores. Iterating on it produces confident output that was never checked against anything. These stay attended: the `brainstorming` skill and the planning agent, with a human at the gate. |
| **Anything touching auth, credentials, money, or production** | The blast radius of a wrong unattended action is not recoverable by the next iteration. `examples/loop.md.example` classifies these as escalate-always. GoalRuns must never auto-merge changes touching auth, credentials, money, or production; those changes always require a human merge. |
| **Anything whose failure is invisible in the transcript** | The `/goal` evaluator has no tools. A failure it cannot see is a loop that will report success. |
| **A first attempt at an unfamiliar problem** | Run it attended once. A loop amplifies whatever the first iteration got wrong. |

**A bounded loop over unbounded work is still unbounded work.** The bound limits
the bill, not the wrongness.

---

## 6. Checklist before starting a loop

1. Which rung of the verification ladder does this stand on? Below 4 → do not
   run it unattended.
2. Is the exit condition checkable by a reader with no tools, and does the body
   print that evidence?
3. Turn bound: which primitive enforces it, or which clause carries it?
4. No-progress: is `loop-progress-signature.sh` wired in, with a state file per
   run, or is the clause merely written down?
5. Spend: launched as a loop (so `--max-budget-usd` applies), or interactive
   (so the two clauses are the whole budget)?
6. Where does it escalate, and to whom?
7. Does the work appear in section 5?

Any "no" is a reason to run the work attended, not a reason to loosen a bound.
