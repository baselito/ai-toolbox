# TDD — Test-Driven Development

The RED-GREEN-REFACTOR methodology, how the tdd-guide agent enforces it, and what it means for your workflow.

---

## When to Read This

- You want to understand how TDD works in this toolbox
- You want to know what the tdd-guide agent does
- You are wondering why a task was not marked done without tests

---

## What Is TDD?

Test-Driven Development is a methodology where you write tests before writing code:

1. **RED** — Write a failing test that describes the expected behaviour
2. **GREEN** — Write the minimum code to make the test pass
3. **REFACTOR** — Clean up the code while keeping tests green

---

## How It Works in This Toolbox

The `tdd-guide` agent (Opus) enforces TDD on every task that involves code changes. It:

- Writes failing tests first (RED)
- Implements code to pass them (GREEN)
- Refactors while maintaining passing tests (REFACTOR)
- Will not mark a task as done without passing tests
- Enforces minimum 80% test coverage (from the testing rule)

---

## When TDD Runs

TDD runs in every command that produces code changes:

| Command | TDD | Notes |
|---|---|---|
| `/flow` | Full TDD | Every implementation task (including per-ticket in Scrum sprints) |
| `/build` | Full TDD | Same enforcement |
| `/bug` | Full TDD | Failing test reproduces bug first |
| `/hotfix` | Full TDD | Same — not skipped for urgency |
| `/refactor` | Full TDD | Tests updated alongside refactoring |
| `/security` | TDD (if fixing) | Tests for each security fix |
| `/perf` | TDD | Performance test quantifies improvement |
| `/review` | No code changes | Read-only — no TDD needed |
| `/incident` | Minimal | Restore service first, then test |

---

## TDD and Bug Fixing

For `/bug` and `/hotfix`, TDD is especially valuable:

1. Write a test that reproduces the bug (RED)
2. Fix the bug so the test passes (GREEN)
3. The test now prevents the bug from recurring

This ensures every bug fix comes with a regression test.

---

## The tdd-workflow Skill

The `tdd-workflow` skill (from ECC) is a passive reference that the tdd-guide agent reads. It contains TDD methodology patterns and best practices. You do not invoke it directly — the agent uses it automatically.

---

## verification-before-completion

After TDD and code review, the `verification-before-completion` skill (from Superpowers) runs a final check to confirm the feature or fix works end-to-end — not just that it compiles and tests pass, but that it actually does what the ticket described.

This is different from TDD: TDD ensures code correctness at the unit/integration level; verification-before-completion ensures the whole feature works as intended.
