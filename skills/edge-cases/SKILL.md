---
name: edge-cases
description: The detailed edge-case response playbooks behind the always-loaded edge-cases rule — exact wording and options for when an external service is down (Jira/acli, Seq, GitHub gh, Beads) or acli auth fails, when a query returns nothing, when the user rejects something, when input is invalid, when a step fails mid-workflow (tests/build/push/Jira/review/reality-checker/regression), session-resume and handover issues, bug-specific and incident-specific cases, the Scrum-board (Step 0) + kanban column-transition cases, and /start and project-setup cases (wrong directory, incomplete PROJECT.md, ticket already In Progress/Done, multiple Jira boards, team capacity). Load this when you hit one of those scenarios and need the standard handling. The six General Rules (never fail silently, never block on optional services, pick the best recovery and state it, respect user decisions, save before risky ops, confirm before destructive) stay in the always-loaded rule and always apply.
source: this repo
---

# Edge Case Handling — Detailed Playbooks

The six always-apply General Rules live in the always-loaded `rules/edge-cases.md`. This skill carries the per-scenario response tables. Load it on demand when you hit one of these situations and need the exact wording.

**Read every row through `rules/autonomy.md`.** Most of these rows describe a **decision the agent takes and states in one line**, not a question it puts to the user — General Rule 3 is "pick the best recovery and take it". Every remaining genuine ask names its header explicitly in the row; a row that cannot name one is written as a stated decision instead. The accepted headers are the four categories — **Irreversible / Scope / Unknown / Conflict** — plus **Blocked**, for the rows where the agent genuinely cannot proceed at all. `hooks/enforce-ask-budget.sh` sees the header and nothing else, so an uncategorised ask from any row below would be denied.

## MCP / Service Down

When any external service is unreachable (Jira, Seq, GitHub, Beads):

| Service | What to do |
|---|---|
| **Jira (acli)** | State it and continue on beads-only tracking: `Decided: continuing without Jira — unreachable (auth status shows why). (Say "switch" to change.)` Never block, and never ask which option. |
| **Seq MCP** | State it and continue with local analysis: `Decided: searching the codebase for likely causes — Seq unreachable. (Paste logs to add them.)` |
| **GitHub CLI (`gh`)** | State it and continue with local work: `Decided: continuing locally — gh is failing (check gh auth status); the PR will need a manual push.` |
| **Beads** | State it and proceed: `Decided: proceeding without beads — unavailable, so work is not tracked across sessions.` |

**Rule:** Never block a workflow because an optional service is down. Pick the fallback, state it in one line, and keep moving — an optional service being down is never a category ask (`rules/autonomy.md`).

## ACLI Authentication Issues

If acli was working but suddenly returns auth errors:

1. Check status: `acli jira auth status`
2. If token expired or revoked:
   a. Open https://id.atlassian.com/manage-profile/security/api-tokens
   b. Create a new token
   c. Re-authenticate: `echo "NEW_TOKEN" | acli jira auth login --site [site] --email [email] --token`
3. If the site URL is wrong: re-run `acli jira auth login` with the correct site
4. If acli is not installed: `brew tap atlassian/homebrew-acli && brew install acli`

**Do not** attempt to use MCP tools for Jira. All Jira operations use acli via Bash.

## Empty Results

When a query returns nothing:

| Scenario | What to do |
|---|---|
| **Jira board is empty** | An **`Unknown`** ask (header `Unknown`) — what to work on is not inferable from an empty board. "No tickets found on the board. You can: (1) pick a specific ticket by ID, (2) describe what to build (`/build`), or (3) check a different board column." |
| **Seq returns no logs** | State it and take the fallback — no ask: `Decided: searching the codebase for likely causes — no Seq logs for that time period. (Paste logs or describe what happened to narrow it.)` |
| **No test failures found** | "All tests pass. No issues to investigate." — continue workflow. |
| **Code review finds no issues** | "Grade: A — No issues found. Code is production-ready." — continue workflow. |
| **Search returns no matching tickets** | An **`Unknown`** ask (header `Unknown`) — which ticket was meant is not inferable. "No matching tickets found. Did you mean [similar IDs]? Or would you like to search by title?" |

## User Rejects Something

When the user says no, rejects a proposal, or wants to change direction:

| What they reject | What to do |
|---|---|
| **Confirmation summary** | Header `Unknown` — what they want changed is not inferable. Ask: "What would you like to change?" Show field numbers. If they say "cancel", that second question is header **`Irreversible`**: "Discard this work, or save it for later?" |
| **Work breakdown** | Header **`Scope`** — the rejection is about how much work the goal covers. Ask: "What should change? Start smaller? Combine tasks? Remove scope?" Re-run `work-breakdown` with new constraints. After 2 rejections, ask (still `Scope`): "Should we try a completely different approach?" |
| **Brainstorming design** | Header `Unknown` — the design the user wants instead is not inferable. Ask: "What should we change?" Loop back to brainstorming with new constraints. After 2 rejections, ask (header `Scope`): "Should we pick a different ticket or pause this one?" |
| **Implementation plan** | Header `Unknown` — what is wrong with the plan is not inferable. Ask: "What's wrong with the plan?" Adjust and re-present. Do not resume implementation on a plan the user has just rejected — re-present the revised one first. |
| **Code review fix** | Accept the rejection. Document the decision: "User declined fix for [reason]." Move on. |
| **Security fix** | If CRITICAL: warn strongly but respect the decision. Document in a security exception note. If HIGH/MEDIUM/LOW: accept and move on. |
| **PR creation** | Header **`Irreversible`** — one option discards work. Ask: "Keep the branch for later? Or discard the changes?" |

**Rule:** Never force the user to accept something. These rows stay genuine asks — a rejection the user has just voiced IS an open conversation, and the follow-up question is what closes it. After 2 rejections of the same thing, suggest a different approach entirely.

## Invalid Input

When the user provides something that doesn't work:

| Input | What to do |
|---|---|
| **Invalid Jira ticket ID** | Header `Unknown` — which ticket was meant is not inferable. "DEV-5999 not found. Did you mean one of these: [list similar]. Or search by title?" |
| **Invalid branch name** | Auto-clean it and state the result — a branch name is reversible, so no approval: `Decided: branch feature/caching-layer — cleaned from "feature/add caching layer". (Say "switch" to change.)` |
| **Vague task description** | Run `brainstorming` skill to ask clarifying questions — those are `Unknown` asks (the goal itself is not inferable), so they carry header `Unknown`. Never start building from "make it better" or "improve everything." |
| **Wrong project/board** | Header `Unknown` — which board the user intends is not inferable. "This ticket is from board [X] but your project is configured for board [Y]. Should I switch boards or use this ticket anyway?" |
| **File path that doesn't exist** | Header `Unknown` — which file was meant is not inferable. "File [path] doesn't exist in the current branch. Review the last version from git? Or pick a different file?" |

## Mid-Workflow Failures

When something breaks during execution:

| Failure | What to do |
|---|---|
| **Tests fail (external reason)** | Retry once, then continue past it, stating both: `Decided: continuing — [test] fails on [external reason], not on this change; retried once. (Say "switch" to change.)` Which recovery to take is never an ask. |
| **Tests fail (code bug)** | Fix it and say so: `Decided: fixing [specific error] — the test is right. (Interrupt to review the error first.)` |
| **Build fails** | `build-error-resolver` attempts auto-fix. If it can't: show the error and take the next step without asking — `Decided: searching for a known fix — build error [error] resisted auto-fix.` A build still broken after that is a **Blocked** ask. |
| **Context window pressure** | `harness-optimizer` detects high usage. Agent saves progress to handover, commits work, and states: `Decided: saving progress here — context is large; resume with /continue.` |
| **PR push rejected** | Take the non-destructive path and state it: `Decided: pull --rebase then re-push — push rejected ([reason]); not force-pushing.` Force-push stays an **Irreversible** ask, and only if the rebase itself fails. |
| **Jira status move fails** | State it and continue — Jira is optional (General Rule 2): `Decided: continuing; ticket not moved to [status] — Jira down or transition not allowed.` |
| **Code review grade below B** | Fix them first and say so: `Decided: fixing [list] before the PR — review grade [D/F].` |
| **Reality checker blocks** | Fix and re-check: `Decided: fixing [reasons] and re-checking — not production-ready.` After 2 consecutive blocks, creating the PR with blockers documented needs explicit user confirmation (`rules/testing.md`) — that one IS a Scope ask. Discarding is **Irreversible**. |
| **Fix introduces regression** | Adjust the fix and state it: `Decided: adjusting the fix — it breaks [existing test].` Changing the existing test instead is a **Scope** ask (it redefines agreed behaviour); reverting is **Irreversible**. |

## Session Resume / Handover

When resuming work across sessions:

| Scenario | What to do |
|---|---|
| **Handover file is empty or corrupted** | Check git log for the last commit message. If that's clear, use it and state it — no ask. Otherwise it is an `Unknown` ask (header `Unknown`): "Handover is empty. Can you describe what you were working on?" |
| **Stale Antigravity handover files from an older install** | Silently delete `.claude/antigravity-handover.md` and `.claude/backup-handover.md` and tell the user: "Removed stale handover files from a previous toolbox version. Single handover (`.claude/handover.md`) is now the source of truth." |
| **Codebase changed since last session** | Rebase onto main and state it — reversible, so no ask: `Decided: rebasing onto main first — the branch has diverged.` |
| **User wants to discard previous work** | Header **`Irreversible`** (General Rule 6). Confirm: "Discard all changes from the prior session? This resets to the branch point." Require explicit "yes" before any destructive action. |

## Bug-Specific Edge Cases

| Scenario | What to do |
|---|---|
| **Bug can't be reproduced** | Header `Unknown` — reproduction detail nobody has supplied. "I can't reproduce this bug. Is it still happening? When was it last seen? Should I check git logs for recent changes that might have fixed it?" |
| **Bug is in a dependency** | Header **`Scope`** — upgrading a production dependency grows the change beyond the agreed fix (`rules/workflow-discipline.md` Rule 7). "This bug is in [package]. Should I: (1) upgrade the package, (2) apply a workaround in our code, or (3) report upstream?" |
| **Debugging exhausts all attempts** | Header **`Blocked`** — the agent cannot proceed without something it does not have. After repeated debugging attempts fail: "Root cause still unclear. Should I: (1) add more logging to narrow it down, (2) ask the team for input, or (3) mark as known issue?" |
| **Duplicate bug ticket exists** | Before creating a Jira ticket, search for existing ones. Reuse the match and state it — no ask: `Decided: continuing on DEV-5700 — same issue; not creating a duplicate. (Say "switch" to file a new one.)` |

## Incident-Specific Edge Cases

| Scenario | What to do |
|---|---|
| **Rollback not safe (DB migration)** | "Rollback not safe — a database migration was applied. Proceeding with forward fix instead." |
| **Fix deployed but service still down** | Header **`Irreversible`** — two of the three options touch production. "Service still down after fix. Should I: (1) query Seq again for new errors, (2) revert the fix, or (3) escalate to human on-call?" |
| **Post-mortem has timeline gaps** | Header `Unknown` — nothing in the repo or logs supplies it. "I'm missing what happened between [time A] and [time B]. Can you fill in that gap?" |

## Scrum Board Edge Cases (Step 0 of /flow)

These apply when `/flow` detects a Scrum board and runs sprint planning.

| Scenario | What to do |
|---|---|
| **Ticket was closed externally mid-sprint** | Before executing each ticket, verify it hasn't been moved to Done by someone else. If so, skip it. |
| **Sprint falls behind schedule** | Between tickets, show progress in the State block and keep going in priority order — that is sequencing, never an ask. **Dropping** an agreed ticket, or ending the sprint early, IS a **Scope** ask. |
| **User ends sprint early** | Header **`Irreversible`** — closing a sprint in Jira is an outward-facing change others see. "Save incomplete tickets to backlog? Close the sprint in Jira?" |
| **Velocity data unavailable** | If Beads is down: "Velocity tracking unavailable. Generating retrospective from completed/incomplete counts only." |

## Column Transition Edge Cases (/flow kanban lifecycle)

These apply when `/flow` moves a ticket through kanban columns (Discovery → Ready for Dev → In Progress → In Review → Testing → Done).

| Scenario | What to do |
|---|---|
| **Ticket moved externally mid-workflow** | Before each column transition, re-read the ticket. If someone moved it to a different column, that is a **`Conflict`** ask (header `Conflict`) — another person has acted on the same work: "This ticket was moved to [column] by [person]. Should I: (1) continue from the current step (ignore the external move), (2) jump to the step matching the new column, or (3) stop and pick a different ticket?" |
| **Ticket closed externally while working** | Header **`Conflict`** — someone else closed the work mid-flight (option 3 is additionally `Irreversible`). "This ticket was moved to Done by [person] while you were working on it. Should I: (1) continue and create the PR anyway (the work is still valuable), (2) keep the branch for later, or (3) discard the work?" |
| **Ticket reassigned externally** | A **Conflict** ask (header `Conflict`) — another person now has a claim on this work. "This ticket was reassigned to [person] since you started. Should I: (1) continue anyway — you may have been pair-programming or helping, (2) stop and hand over (commit + push what you have), or (3) pick a different ticket?" |
| **Column doesn't exist on the board** | If the board doesn't have a Discovery, Testing, or other expected column, skip that transition silently and map to the closest available column. Never fail because a column is missing. |
| **Jira transition not allowed** | State it and continue — Jira is optional (General Rule 2), so this is never an ask: `Decided: trying the intermediate columns, then continuing regardless — Jira refused [current] to [target]. (Board config may need a look.)` |
| **Priority changed externally** | Inform: "Priority changed from [old] to [new] by [person]. This may affect work order." Continue unless the user stops. |
| **New comments from team during workflow** | Show it in the State block — `New comment from [person]: [summary]` — and continue. Pause only if the comment changes the agreed goal (**Scope**). |
| **Discovery phase takes too long** | If discovery has been running for more than 10 minutes of agent time, wrap up and move on, stating it: `Decided: moving to development with current findings — discovery is over its 10-minute budget.` |
| **Multiple external changes at once** | Show all changes in a single summary rather than asking about each one separately. If any of them needs an answer, batch them into ONE **`Conflict`** ask (header `Conflict`) rather than one ask per change. |

## /start-Specific Edge Cases

| Scenario | What to do |
|---|---|
| **User types invalid menu input** | "That's not one of the options. Type a number (1-9) or press Enter for the default action." Show the menu again. |
| **ACLI auth error** (acli installed but auth fails) | State it and continue — Jira is optional (General Rule 2), so this is not an ask: `Decided: continuing without Jira — auth failed; run the acli Jira auth-status command to diagnose, or paste a ticket ID to work from.` |
| **User is in the wrong directory** (not a project repo, e.g. home directory) | Header **`Blocked`** — there is no repo to work in, so nothing can start. "This doesn't look like a project directory — no `.git` folder or source code found. Did you mean to `cd` into your project first?" |
| **User runs /start inside the ai-engineering repo** | Header **`Blocked`** if the user meant project work — there is no project here. "This is the toolbox repo itself, not a project. `cd` into your actual project directory and run `/start` there." (If they meant toolbox self-maintenance, that is the documented ticketless path — proceed, do not ask.) |
| **PROJECT.md exists but is incomplete** (missing required fields) | Run the missing `/init` questions only (header `Unknown` — config nobody has supplied) — don't re-ask questions that already have answers. Tell the user: "Your project config is missing [fields]. Let me ask a few quick questions to fill in the gaps." |
| **Ticket is already In Progress** | Header `Unknown` if it is the user's own ticket, **`Conflict`** if someone else holds it. "This ticket is already In Progress. Should I: (1) continue working on it (pick up where it left off), (2) pick a different ticket, or (3) restart this ticket from scratch?" |
| **Ticket is already Done** | Header `Unknown` — which ticket to work on instead is not inferable. "This ticket is marked as Done. Should I: (1) pick the next ticket instead, (2) reopen it and continue, or (3) pick a specific ticket by ID?" |
| **Multiple Jira boards configured** | Use the board set in PROJECT.md. If none is set, ask with header `Unknown`: "Which board should I read from? [list boards]." Save the choice to PROJECT.md. |
| **Scrum planning — team capacity not set** (Step 0 of /flow on Scrum boards) | Header `Unknown` — team size is not inferable from the repo. "I need to know your team size to estimate scope. How many developers are working on this? (e.g. 1, 2-4, 5+)" Save to PROJECT.md for future use. |

## General Rules (also in the always-loaded rule — repeated here for completeness)

1. **Never fail silently.** Always tell the user what went wrong and offer options. Telling is not asking — surface it in the State block and keep moving.
2. **Never block on optional services.** Jira, Seq, Beads are all optional. Work continues without them.
3. **Pick the best recovery and take it**, stating the choice and the rejected alternative in one line. Present alternatives instead of acting only when every recovery path is itself a category ask (`rules/autonomy.md`).
4. **Respect user decisions.** If they reject a fix or proposal, document it and move on.
5. **Save progress before risky operations.** Commit work before rebasing, merging, or discarding.
6. **Confirm before destructive actions.** Discarding work, reverting, force pushing — always ask first.
