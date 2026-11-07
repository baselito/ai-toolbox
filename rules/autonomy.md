# Autonomy — Decide, State, Proceed

The user sets the goal; the agent finds the way. A question is spent only where a wrong guess
cannot be cheaply undone. Everything else the agent decides, states in one line, and proceeds on.

## The Ask Test

Before any `AskUserQuestion` — **or any reply that ends in a question or an option list** — name
the category. **No category → no ask: decide, state it, proceed.** There are four, and only four:

| Category | What it covers |
|---|---|
| **Irreversible** | A merge on a non-toolbox repo, deleting or discarding work, force-push, anything touching production, spend, or data loss. **Also an effect that lands on someone else, cannot be silently retracted, and was not already part of the work the user asked for** — a push or PR-create on a repo with no recorded standing consent (`rules/git-workflow.md` → "Standing authorization"), or a message sent outside the agreed workflow. |
| **Scope** | The work would grow beyond the agreed goal, or two agreed goals conflict such that one must be **DROPPED** — not merely ordered. |
| **Unknown** | Something not inferable from the goal, `~/.claude/memory.md`, `.claude/PROJECT.md`, the ticket, or the repo — e.g. a target branch the user never stated. |
| **Conflict** | The action would contradict a standing user instruction, **or collide with another person's claim on the same work** — taking a ticket currently assigned to someone else, or continuing one that was reassigned or moved by someone else mid-flight. |

⛔ **`Blocked` is the FIFTH accepted header and NOT a fifth category — the distinction is the
point.** Five headers, four categories: that asymmetry is deliberate, and it is the whole content of
this paragraph. `hooks/enforce-ask-budget.sh` accepts a header beginning `Irreversible`, `Scope`,
`Unknown`, `Conflict` **or `Blocked`**. The four above say *why a wrong guess is expensive*;
`Blocked` says the agent **cannot proceed at all** — a credential it does not have, a service that
is down, a prerequisite nobody has supplied. It is the phase-card `BLOCKED` status that
`rules/agents.md` step 4 still allows a gate to stop on, carried into the header vocabulary so
that a genuinely stopped agent has a legal way to say so.

Keeping it out of the table is deliberate: a *reason to ask* and an *inability to continue* are
different claims, and merging them would let any mid-flight "shall I continue" wear the word. But
the enforcement and the documentation must agree on **what the hook accepts**, and until now they
did not — every doc listing "four categories" as the accepted headers was describing a gate
stricter than the one that actually runs. Where a document tells an agent *what to write*, it
lists all five words. Where it explains *why an ask is warranted*, it names the four.

**Why those two cells read wider than their names.** `Irreversible` is not only about what cannot
be undone *technically* — a push can be reverted and a PR closed. It is about what cannot be undone
*unseen*: once someone else can observe it, the retraction is itself an event. `Conflict` is not
only about contradicting the user — a second person acting on the same ticket is a conflicting
claim, and the agent cannot resolve it by guessing which of them should own the work.

⛔ **And the limit on `Irreversible`, which matters as much as its reach.** "…was not already part
of the work the user asked for" is load-bearing, not hedging. An earlier revision of this cell said
"any outward send", which swallows every Jira comment the workflow is *defined* to post — all 8
phase comments, the ticket assignment, every status transition. That reading would stop the agent
at each one and re-create the ask-everything problem under a new name. Running `/flow TASK-123` IS
the consent for that ticket's documented Jira lifecycle; those writes are the work, not a departure
from it. What stays `Irreversible` is a send the user did not ask for — and taking a ticket someone
ELSE holds is already `Conflict`, gated separately.

These are the only two widenings, and they are deliberately concrete: they name the triggers rather
than adding a residual "anything that feels risky", which would readmit every ask this rule exists
to remove.

**Never an ask:** sequencing, ordering, which-first, tool choice, retries, how to recover from a
failure, whether the ticket is "simple enough", or "shall I continue". Those are the agent's job.

## Decide-and-state format

One line, never a question:

```
Decided: <X> — <reason>. (Say "switch" to change.)
```

A stated reversible decision needs **no pre-approval**. Interruption is the gate: the user can
always stop or redirect, and that is cheaper for them than being asked.

## Front-load and batch

Foreseeable category asks happen **ONCE at kickoff** — target branch, scope boundary, and any
irreversible step the plan already contains. Mid-flight, **batch**: finish every piece of
independent work first, then ask once for everything still genuinely unknown. Never interleave
work and asks.

**A kickoff ask is still a categorised ask.** "It is kickoff" is a statement about *timing*, not a
licence to omit the header — `enforce-ask-budget.sh` sees the header and nothing else, so an
uncategorised kickoff ask is denied like any other. In practice kickoff asks are **`Unknown`**:
setting the goal, picking the board or the ticket, confirming the assembled workflow summary, and
writing project configuration are all things not inferable from the goal, `~/.claude/memory.md`,
`.claude/PROJECT.md`, the ticket or the repo — which is exactly what `Unknown` covers, and why the
category's worked example ("a target branch the user never stated") is one of those very fields.

`/start` and `/init` are therefore **`Unknown` throughout**; each command file
states this once at the top rather than repeating it per question.

There is deliberately no `Kickoff` or `Setup` category. The four categories say *why* a wrong guess
is expensive; a fifth saying *when* would be a word that any mid-flight "shall I continue" could
wear. (`Blocked` survives that test precisely because it does not say *when* — it says the work
cannot continue on any path, which a "shall I continue" cannot honestly claim.)

## Queue rule — replaces asking "what next?"

At every natural pause, act on the top item that applies. Do not ask which:

1. An open PR with unresolved reviewer threads — oldest first.
2. A finished branch without a PR.
3. Unpushed commits.
4. New work, in the order the user gave it.

## State block — replaces the user asking "status"

While more than one work item is in flight, **every reply ends with one line per item** (max 7)
plus a mandatory `Next:` line. State changes — a PR merged, new reviewer comments, CI gone red —
**lead** the next reply rather than waiting to be discovered.

If the user has to type "status", this rule was violated.

## Unchanged by this rule

- **Hook-enforced safety stands** — `push-safety.sh`, `pr-action-safety.sh`, `enforce-loop-bounds.sh`
  and the rest. Consent removes *prompts*, never *checks*.
- **Destructive confirmations stand** — see `rules/edge-cases.md` General Rule 6.
- **Phase cards still show at every gate** (`rules/agents.md`) — as **reporting**, not as questions.

## Applies To

All agents, all commands, all conversational output. The `enforce-ask-budget.sh` hook enforces the
Ask Test for any developer whose `~/.claude/memory.md` carries a `- Autonomy: goal` line.
