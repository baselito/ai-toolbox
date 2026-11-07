# Development Workflow

> This file extends [common/git-workflow.md](./git-workflow.md) with the full feature development process that happens before git operations.

The Feature Implementation Workflow describes the development pipeline: research, planning, TDD, code review, and then committing to git.

## Feature Implementation Workflow

0. **Research & Reuse** _(mandatory before any new implementation)_
   - **GitHub code search first:** Run `gh search repos` and `gh search code` to find existing implementations, templates, and patterns before writing anything new.
   - **Library docs second:** Use Context7 or primary vendor docs to confirm API behavior, package usage, and version-specific details before implementing.
   - **Web search when the first two are insufficient:** Use web search (via MCP or browser) for broader research after GitHub search and primary docs. Context7 MCP is available for library docs; for general web research, use the tools available in your session.
   - **Check package registries:** Search npm, PyPI, crates.io, and other registries before writing utility code. Prefer battle-tested libraries over hand-rolled solutions.
   - **Search for adaptable implementations:** Look for open-source projects that solve 80%+ of the problem and can be forked, ported, or wrapped.
   - Prefer adopting or porting a proven approach over writing net-new code when it meets the requirement.

1. **Plan First**
   - Use **planner** agent to create implementation plan
   - Generate planning docs before coding: PRD, architecture, system_design, tech_doc, task_list
   - Identify dependencies and risks
   - Break down into phases

1a. **Streamlined-plus scope expansion check** _(when planner is skipped — small correctness-sensitive changes)_
   - **When this applies:** The streamlined path is chosen (brainstorming skipped, planner skipped or reused) and the change touches a discrete "axis" — a variable, env key, feature flag, status enum value, config name, status-table column, role/permission, or identifier rename.
   - **Why it exists:** The full deep-reasoning-tier planner (see `rules/performance.md`) spends ~5 minutes (~$0.10+) to surface cross-file callsites that branch on the same axis. For config additions and similar small changes, the same value is obtainable with a 30-second `rg`/`grep`. Skipping the planner is the right call ROI-wise; skipping the grep is not — latent ternary fall-throughs and missed switch cases ship to PR.
   - **What to do:** Run `rg -n "<axis>"` (or `grep -rn "<axis>"`) for the axis identifier across the repo. Surface ALL callsites that branch on the same axis to the user — not just the originally-modified file. Apply the stated default (out of scope — file the followup), list the callsites and followup ID in the State block; ask only if a callsite makes the change wrong as shipped (Scope).
   - **Hard rule — orchestrator inline only, NO agent.** Spawning an agent (Opus planner, code-reviewer, search-specialist) defeats the point. Total cost target: <30 seconds + ~500 tokens.
   - **Hard rule — do NOT skip silently.** If the change fits any axis pattern, the orchestrator MUST run the grep. The orchestrator does NOT get to decide "this looks safe without grep." The grep IS the safety net for skipping the planner.
   - **Default decision is "Out of scope — file followup."** Step 1a surfaces the latent class without forcing scope creep. The orchestrator does NOT push the user toward "In scope."
   - **Origin:** TASK-738 retrospective. A 6-line config change had 3 latent ternary fall-throughs in cleanup scripts that a 30-second grep would have caught — but the planner agent was skipped (correctly) because brainstorming/planner ROI was bad for the scope. See `commands/flow.md` Step 6.5 for the full step-by-step process and axis-pattern table.

2. **TDD Approach**
   - Use **tdd-guide** agent
   - Write tests first (RED)
   - Implement to pass tests (GREEN)
   - Refactor (IMPROVE)
   - Verify 80%+ coverage

3. **Test What You Write**
   - After writing any CLI command, API call, or integration code — **run it** to verify it works before committing
   - Do not assume syntax is correct — test the exact command first
   - If writing commands for a tool (acli, gh, docker, etc.) — verify the syntax with `--help` before using it
   - If a command fails, fix it before proceeding — do not commit broken commands

4. **Code Review**
   - Invoke the **`code-review-orchestration` skill** — do NOT spawn review agents (code-reviewer, tdd-guide, etc.) directly. The skill routes through chief-of-staff which selects the appropriate reviewers.
   - Address CRITICAL and HIGH issues
   - Fix MEDIUM issues when possible

5. **Commit & Push**
   - Detailed commit messages
   - Follow conventional commits format
   - See [git-workflow.md](./git-workflow.md) for commit message format and PR process
