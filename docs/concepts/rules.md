# Rules

> What rules are, why they exist, and how they work.

**Read this when:** You want to understand what rules enforce and why they are always active.

---

## What Are Rules?

Rules are always-active instructions that the agent follows in every session, every command, and every project. They are not optional — they run automatically in the background and enforce baseline quality standards across all work.

15 rules total — some based on **ECC** (Everything Claude Code) common rules (customized for the toolbox stack), others custom-built for this toolbox. All 15 are copied to `~/.claude/rules/` during install and apply globally.

> **Note on size:** rules load into context every session, so they are kept terse. Bulk detail (grammars, scripts, incident histories) lives in on-demand **skills** that load only when a task needs them — e.g. `workflow-discipline.md` holds only its directives, while the `workflow-discipline` skill holds the full Stryker keyword grammar and pre-check scripts.

---

## How Rules Work

- Rules are loaded automatically when the agent starts a session.
- They do not need to be invoked — they are always active.
- They apply to every command (`/flow`, `/build`, `/bug`, `/hotfix`, etc.).
- They cannot be disabled per project. If a rule exists in `~/.claude/rules/`, it is enforced.
- The agent follows rules silently — you will not see explicit "rule applied" messages unless a rule triggers a correction.

---

## What Rules Enforce

This toolbox includes **15 rules**:

| Rule | What it enforces |
|---|---|
| `communication.md` | Communication style — replies short, clear, and simple by default |
| `security.md` | Security best practices — input validation, auth checks, secrets handling |
| `coding-style.md` | Code quality — naming, immutability, consistent patterns |
| `testing.md` | Test coverage — TDD compliance, test quality, edge cases |
| `git-workflow.md` | Git discipline — branch naming, commit messages, PR standards |
| `agents.md` | Agent behaviour — handover protocol, model usage, orchestration rules |
| `performance.md` | Performance — efficient queries, caching, avoiding N+1, bundle size |
| `handover.md` | Handover protocol — read before starting, write before moving on |
| `edge-cases.md` | Error handling — empty boards, failed tests, rejected proposals, missing config |
| `feedback-detection.md` | Feedback detection — recognizes user corrections and adjusts behaviour |
| `cross-tool-sync.md` | Cross-tool sync — when one tool is updated, the others must be updated too |
| `development-workflow.md` | Development pipeline — research, planning, TDD, code review, then git |
| `docs-before-commit.md` | Documentation — verify docs are up to date before every commit |
| `workflow-discipline.md` | Workflow discipline — all commands follow `/start` Jira discipline, auto-poll, gitignore enforcement |
| `autonomy.md` | Autonomy — decide, state, proceed; a question is spent only on the four categories (Irreversible / Scope / Unknown / Conflict), plus a `Blocked` header when the agent cannot proceed at all |

For the full detail on what each rule contains, see [Rules List (Reference)](../reference/rules-list.md).

---

## Where Rules Live

| Location | Purpose |
|---|---|
| `rules/` (this repo) | Source of truth — 7 ECC-based (customized) + 8 custom |
| `~/.claude/rules/` | Installed location — copied by `install.sh` |

---

## Updating Rules

Rules are updated when `update.sh` pulls the latest from the ECC upstream repo. Only `common/` rule files are pulled and compared — no other ECC rules are used. Our versions are customized (e.g. coding-style adds C#/Blazor conventions), so updates require manual review.

See [How to Update](../how-to/update.md) for the full update workflow.
