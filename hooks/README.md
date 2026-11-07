# Hooks — Safety Gates and Enforcement

This directory contains Claude Code hooks that enforce the Independence Principle and various safety rails. They are PreToolUse and PostToolUse hooks that load automatically via `hooks-config.json`.

## Files

| File | Type | Purpose |
|---|---|---|
| `hooks-config.json` | Config | Registers hooks with Claude Code. Merged into `~/.claude/settings.json` by `install.sh`. |
| `enforce-chief-of-staff.sh` | PreToolUse Agent | Blocks direct spawning of review agents without chief-of-staff orchestration |
| `enforce-skill-delegation.sh` | PreToolUse Skill | Blocks certain skills from running inline on the orchestrator (they must delegate to Opus subagents) |
| `enforce-transition-script.sh` | PreToolUse Bash | Enforces Jira transitions via the transition script, not raw `acli transition` |
| `enforce-pr-skill.sh` | PreToolUse Bash | Blocks `gh pr create` without the `finishing-a-development-branch` skill marker (`.pr-skill-invoked`; single-use, consumed on success by `consume-pr-markers.sh`, and expires after 3600s so a marker left behind by a denied attempt cannot open the gate later) |
| `enforce-codex-review.sh` | PreToolUse Bash | Blocks `gh pr create` until a Codex pre-PR review marker exists for the current HEAD — only when Codex is enabled (no-op otherwise) |
| `enforce-fable-review.sh` | PreToolUse Bash | Blocks `gh pr create` until a Fable pre-push adjudication marker exists for the current HEAD (`.fable-review-complete`, `reviewed <sha>` — the only accepted word). No outage escape by design: with no producer, an `unavailable` line would be the only path anyone wrote, so the gate ships strict and the first PR after install blocks loudly. ⛔ Nothing writes the marker yet — the deny message is currently the only producer spec |
| `enforce-jira-delegation.sh` | PreToolUse Bash | Blocks direct `acli` writes on the main orchestrator — forces delegation to `jira-workflow-steward` (Haiku) |
| `enforce-compliance-audit.sh` | PreToolUse Bash | Blocks `gh pr create` unless `.audit-complete` is keyed to the current HEAD (`AUDIT HEAD: <sha>` first line) AND its `AUDIT COMPLETE:` verdict is `PASSED` — a `BLOCKED` or unreadable verdict denies. Single-use, consumed on success by `consume-pr-markers.sh`, and expires after 3600s so a stale audit cannot satisfy a later PR |
| `enforce-workflow-start.sh` | PreToolUse Bash | Blocks `git checkout -b` with a Jira ticket-ID pattern unless the workflow-start marker exists (routes work through `/start`) |
| `enforce-auto-poll.sh` | PreToolUse Bash | After a PR is created/pushed, blocks subsequent Bash calls until the `/review-pr` auto-poll cron is set up (pairs with `auto-poll-after-pr.sh`) |
| `enforce-loop-bounds.sh` | PreToolUse CronCreate/Skill | Blocks a recurring `CronCreate` whose prompt has no registered self-termination; a `/goal` condition that sets a goal with no turn clause, no no-progress clause, or a number outside the `workflow-discipline` skill §1d ceilings; and a `/loop` Skill invocation failing the same two-clause check (including a bare `/loop` with no arguments). Guard 1 of the three loop guards — doctrine in the `loop-design` skill |
| `enforce-ask-budget.sh` | PreToolUse AskUserQuestion | Enforces the Ask Test in `rules/autonomy.md`: every question's `header` must begin with `Irreversible`, `Scope`, `Unknown`, `Conflict` or `Blocked`, else the ask is denied and the agent must decide, state it, and proceed. No-op unless `~/.claude/memory.md` carries a `- Autonomy: goal` line, so other toolbox users are unaffected. Fails closed on an unreadable payload; fails open on an unreadable memory.md (a broken opt-in read must not block every ask) |
| `enforce-standing-auth.sh` | PreToolUse Write/Edit/Bash | Compatibility-hygiene guard for accidental edits to the legacy `- Standing:` note in `memory.md`. It is not an authorization source: no merge path reads that note as consent. Actual no-prompt consent comes from the user-controlled host permission layer; unattended toolbox merging additionally requires the current GoalRun capability and live GitHub gate. |
| `workflow-auto-approve.sh` | PreToolUse Bash/Write/Edit | Auto-approves routine workflow operations (touch/rm of markers, writes to audit files) |
| `push-safety.sh` | PreToolUse Bash | Blocks `git push` to main/master without approval token; blocks force-push on all branches |
| `pr-action-safety.sh` | PreToolUse Bash | Always blocks `gh pr close`; gates `gh pr merge` — allows only the atomic gated form (`touch .pr-merge-gate-… && gh pr merge …`) with a live-verified OPEN/mergeable state, else blocks |
| `compliance-auditor.sh` | PostToolUse Skill | Audits whether chief-of-staff was used during code review |
| `auto-poll-after-pr.sh` | PostToolUse Bash | After `gh pr create` or a `git push` to a branch with an open PR, creates the auto-poll pending marker so `enforce-auto-poll.sh` requires host poll registration (Claude CronCreate or Codex Desktop heartbeat) |
| `consume-pr-markers.sh` | PostToolUse Bash | Consumes `.pr-skill-invoked` + `.audit-complete` only after a successful `gh pr create` (single-use enforcement moved out of the PreToolUse gates so a gate DENY is idempotent) |
| `audit-model-usage.sh` | PostToolUse Agent | Logs every Agent spawn (model + type) to `~/.claude/model-audit.log` — compliance trail, does not block |
| `pre-commit-check.sh` | Local pre-commit | Checks count references in docs match physical file counts |

## Installation

`install.sh` handles this automatically (Step 10.6):
- Copies the 19 Claude Code hook scripts to `~/.claude/hooks/` (`pre-commit-check.sh` is not copied — it runs locally in this repo only). The copies come from ONE name roster (`HOOK_FILES` in Step 10.6) in a loop that checks every `cp`'s exit status, so a failed or missing copy warns loudly instead of leaving a registered-but-absent hook that exits 127 and fails OPEN. Adding a hook means adding it to that roster; `TC-HI-1/2/3` assert the roster agrees with `hooks-config.json` and with `hooks/*.sh`, `TC-HI-4` asserts every registered hook resolves to an executable file, and `TC-HI-5/6/7` assert `uninstall.sh`'s three lists cover it
- Merges `hooks-config.json` into `~/.claude/settings.json`
- Makes all hooks executable

The provider-neutral `scripts/register-pr-poll.sh` helper is also installed to
`~/.claude/scripts/` and, when Codex is enabled, `~/.codex/bin/`. It records a
Claude cron ID or Codex heartbeat ID in the existing per-PR marker; it does not
weaken the hook gate or create background jobs by itself.

## Testing

Run `./scripts/verify-hooks.sh` — a behavioural regression harness that tests each hook against known bypass attempts. Every test case corresponds to a real bug that was found and fixed.

## Known residuals

`rules/security.md` item 7: prefer over-blocking to under-blocking, and **write the residual down — an unnamed residual reads as a guarantee.** Each one below is also named at its own site in the source; this is the index, not the argument.

| Residual | Where | Why it is open |
|---|---|---|
| A quote- or backtick-wrapped command NAME is not gated (`"gh" pr create`) | the four PR gates' detector | Putting `"` and `` ` `` in the boundary class would over-block ordinary markdown prose and `--body` strings. Irreducible without a shell parser; anyone who can run arbitrary Bash can delete the hook anyway |
| `env -C … gh pr create`, `git -C`, a variable-indirected interpreter path, a backslash-newline between the three tokens | the four PR gates' detector | Needs a shell-aware parser, not another boundary tweak. The detector has regressed twice from added cleverness |
| Inert prose mentioning the PR-create phrase is gated (over-block) | the four PR gates' detector | Deliberate and accepted — the safe direction. The deny names the Write-tool escape and says a heredoc retry cannot help |
| `gh api /repos/O/R/pulls` with no POST is gated (over-block on a read) | the four PR gates' detector | Requiring a method flag adds `-XPOST` / `--method post` spellings to chase; item 7 says take the over-block |
| A PR opened by a newly-recognised spelling (`gh --repo O/R pr create`, `gh api`) gets no auto-poll cron | `auto-poll-after-pr.sh` | It is a PostToolUse REACTION hook, not a gate, and `gh api` does not emit the PR URL its extractor reads |
| The codex-review skill's marker-write shape is not on the auto-poll allowlist | `enforce-auto-poll.sh` branch -1 | Not needed today — the Codex pass runs before the PR exists, so the pending marker cannot be armed. If that changes, transcribe that string too; do not widen the branch |
| Incidental prose counts as a declared bound (`"I gave up after 3 turns of this"`) | `enforce-loop-bounds.sh` `_clause_*` | The check is that a bound was written down, not that it was written in the right grammatical role. Separating those needs a parser, and the gap's failure direction is a loop carrying a number it did not mean, not a loop with no number |
| A `/goal` the USER types, and a loop launched by Bash or by an Agent prompt, are not observable | `enforce-loop-bounds.sh` | The hook is registered on `CronCreate` and `Skill` only. For those the bound stays `commands/flow.md` plus compliance check 14 |
| The `--repo` value in a registered cron prompt is an unconstrained `owner/repo` slug | `enforce-loop-bounds.sh` detector A | Inert as a loop — the scheduled command is still `/review-pr … --auto`, capped at 1 day. Constraining it means validating a GitHub owner/repo grammar in the registry |
| An unparseable payload reaches ALLOW in every PreToolUse gate; eleven get there by ABORTING (exit 5) rather than falling through | all PreToolUse hooks | Rests on the harness emitting well-formed input — an integrity assumption about our own runtime, not an adversary boundary. `TC-M2-1` pins that the direction is uniform; flipping it to deny is a change to make to all fourteen at once |
| `enforce-fable-review.sh` has NO producer — the marker is written by hand | `enforce-fable-review.sh` | Deliberate. The deny message is the producer spec, and the first PR after install blocks loudly. `unavailable` goes in the same change that adds a producer |

## Related files

- `rules/git-workflow.md` — Push safety rules that `push-safety.sh` enforces
- `docs/concepts/independence-principle.md` — Why these hooks exist and what they enforce
- `docs/how-to/agent-handover.md` — Handover file protocol
