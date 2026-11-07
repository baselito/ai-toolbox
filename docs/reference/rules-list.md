# Rules List — Full Reference

All 15 rules that are always active in every session. These set the baseline that all agents operate within.

> **Count check:** If this heading says a different number than the sections below, one of them is wrong. Count the `### *.md` sections — there should be exactly 15.

---

## Source

15 rules total. Some are based on ECC (`affaan-m/everything-claude-code`) common rules (customized for the toolbox stack), others are custom rules built for this toolbox. All are copied to `~/.claude/rules/` during install.

---

## Rules

### communication.md
- **What it enforces:** Replies are short, clear, and simple by default — as little text as needed without hurting clarity. Lead with the answer; prefer lists/tables over prose; cut preamble and option-narration. Structured artifacts (phase cards, ticket templates, PR bodies) keep their full format.
- **When it runs:** Always active — every session, all conversational output
- **Impact:** Less reading fatigue; the agent does not pad responses

### security.md
- **What it enforces:** Never log sensitive data, always validate input, OWASP compliance required, no hardcoded secrets, secure defaults
- **When it runs:** Always active — every session, every agent
- **Impact:** All code changes must pass security baseline checks

### coding-style.md
- **What it enforces:** Consistent naming conventions, formatting standards, and code structure per the detected stack (TypeScript, C#, etc.)
- **When it runs:** Always active — every session, every agent
- **Impact:** All code changes must follow project conventions

### testing.md
- **What it enforces:** Minimum 80% test coverage, test-first required (TDD), no skipping tests, test files must exist for all code changes
- **When it runs:** Always active — every session, every agent
- **Impact:** No task is marked done without passing tests meeting coverage requirements

### git-workflow.md
- **What it enforces:** Commit message format, branch naming pattern (type/TICKET-ID-slug), PR description standards, clean git history, and where standing push/PR/merge consent is recorded
- **When it runs:** Always active — every session, every agent
- **Impact:** All git operations follow the defined conventions. The legacy `~/.claude/memory.md` standing note is informational and never grants consent. No-prompt consent comes from the user-controlled host permission layer, while the exact toolbox auto-merge path additionally requires a current GoalRun capability and live hook verification; `enforce-standing-auth.sh` remains only an accidental-edit hygiene guard.

### agents.md
- **What it enforces:** Agent invocation patterns, handover protocols, context management, the four-role orchestration model, and chief-of-staff spawn points. The file-pattern→agent table, parallel-vs-sequential execution order, and the fixed per-agent model table have moved to the on-demand `agent-orchestration` skill (loaded by chief-of-staff when selecting agents/models) — this rule keeps the always-loaded directives, the skill carries the lookup tables.
- **When it runs:** Always active — every session, every agent
- **Impact:** Agents follow orchestration rules and handover protocols

### performance.md
- **What it enforces:** Model routing rules (Opus/Sonnet/Haiku per agent), context window limits (60 tools recommended, 80 max), avoid unnecessary tool calls
- **When it runs:** Always active — every session, every agent
- **Impact:** Efficient model usage and context window management

### handover.md
- **What it enforces:** File-based handover protocol using `.claude/handover.md` — read before starting a phase, write before moving on, never delete previous entries, clear at the start of each new workflow run
- **When it runs:** Always active — every workflow and skill phase
- **Impact:** Structured data passing between workflow phases so the next session or subagent has the context it needs

### edge-cases.md
- **What it enforces:** Graceful handling of common failure scenarios — empty Jira boards, failed tests, rejected proposals, missing PROJECT.md, MCP connection failures, empty PR diffs
- **When it runs:** Always active — every command, every workflow
- **Impact:** The agent never fails silently; it offers alternatives when something goes wrong

### feedback-detection.md
- **What it enforces:** Detects when the user corrects the agent's approach (explicit corrections, style preferences, rejected outputs) and adjusts behaviour for the remainder of the session
- **When it runs:** Always active — every session
- **Impact:** The agent learns from corrections without the user repeating themselves

### cross-tool-sync.md
- **What it enforces:** When shared behavior changes, Claude and Codex surfaces, counts, links, and provider adapters must remain consistent. No dead references.
- **When it runs:** Always active — when modifying the ai-engineering repo
- **Impact:** Prevents drift between Claude Code and Codex

### development-workflow.md
- **What it enforces:** Feature implementation pipeline — research and reuse before coding, plan first, TDD approach (RED/GREEN/REFACTOR), code review, then commit
- **When it runs:** Always active — every feature implementation task
- **Impact:** No implementation starts without research and planning first

---

### docs-before-commit.md
- **What it enforces:** Before every commit, verify documentation reflects the changes — counts, names, command files, rule files, doc files, cross-tool equivalents, examples
- **When it runs:** Always active — every commit that changes behaviour
- **Impact:** No commit goes out with stale documentation

### workflow-discipline.md
- **What it enforces:** All commands follow `/start` Jira discipline (concise milestone updates, board transitions, correct agents/models), always ask about Jira before starting work, "yes work on it" routes through `/start` → `/flow`, auto-poll after every PR (1 min default), gitignore enforcement for toolbox files before any branch/commit
- **When it runs:** Always active — every command, every workflow
- **Impact:** No command bypasses Jira discipline, auto-poll, or gitignore enforcement — even shortcut commands like `/bug`, `/security`, `/refactor`

### autonomy.md
- **What it enforces:** The Ask Test — before any question (or any reply ending in a question or option list) the agent writes a header beginning with one of five accepted words: **Irreversible**, **Scope**, **Unknown**, **Conflict** or **Blocked**. The first four are the *categories* — they say why a wrong guess is expensive. **Blocked** is the fifth accepted header rather than a fifth category: it says the agent cannot proceed at all (a credential it does not have, a service that is down, a prerequisite nobody supplied), and it is the phase-card `BLOCKED` status carried into the header vocabulary. No accepted header means no ask: decide, state `Decided: <X> — <reason>.` in one line, and proceed. Sequencing, ordering, tool choice, retries, failure recovery and "shall I continue" are never asks. Adds the **Queue rule** (what to pick up at a pause, so the agent never asks "what next?") and the **State block** (one line per in-flight item plus a `Next:` line, so the user never has to type "status"). Foreseeable category asks are front-loaded once at kickoff; mid-flight asks are batched.
- **When it runs:** Always active — every session, every command, all conversational output
- **Impact:** The user sets the goal and the agent finds the way. Enforced by `enforce-ask-budget.sh` (PreToolUse on `AskUserQuestion`), which denies a question whose header does not begin with a category word — but only for a developer whose `~/.claude/memory.md` carries a `- Autonomy: goal` line, so it is a no-op for everyone else. Hook-enforced safety (push-safety, pr-action-safety, loop bounds) and destructive confirmations are untouched: consent removes prompts, never checks.

---

## Notes

- Rules are copied to `~/.claude/rules/` during installation
- They are always active — you cannot disable a rule for a specific project
- Rules apply to all agents equally — the tdd-guide follows security rules, the security-reviewer follows testing rules, etc.
- To modify a rule, edit the file in the `rules/` directory of this repo and re-run `install.sh`
