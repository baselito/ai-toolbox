---
name: testing
source: this repo
scope: always active
---

# Testing Rules

Test-first development is required. These rules enforce testing standards across all code changes.

## Requirements

- Minimum 80% test coverage on all code changes. A project may RAISE this via the optional `verification.coverage_floor` in `.claude/PROJECT.md`, never lower it — the effective floor is `max(80, project value)`, so a smaller number is ignored at runtime. That block holds KEYS ONLY; the literal `test`/`lint`/`build` commands live in the toolbox-owned registry in the **`workflow-discipline` skill (§1c)**, because `PROJECT.md` is PR-editable and a command string there would be unreviewed code the agent executes. Load §1c when resolving a project's `verification:` block.
- Test-first (TDD) required — write the failing test before the implementation
- **The Iron Law:** no production code without a failing test first. Code written before its test must be deleted.
- No task is marked done without passing tests
- Tests must be deterministic — no flaky tests
- Test names must clearly describe what they verify
- Each test should verify one thing — "and" in the name means split it
- Use arrange-act-assert pattern
- Mock external dependencies, not internal code
- Integration tests must exist for critical paths

## TDD Workflow — RED-GREEN-REFACTOR

1. **RED** — Write a failing test that describes the expected behaviour. Verify it fails.
2. **GREEN** — Write the minimum code to make the test pass. Verify it passes.
3. **REFACTOR** — Clean up the code while keeping tests green. Never skip verification steps.

**Exception — adding tests for existing code:** When the ticket is specifically about adding test coverage for existing production code (no new features, no code changes), the RED phase doesn't apply — tests will pass immediately because the code already works. In this case: write the tests, verify they pass, verify they actually test the right thing (not just passing trivially). The Iron Law still applies to any NEW production code.

## Anti-Rationalisation

These excuses are not valid reasons to skip TDD:

| Excuse | Reality |
|---|---|
| "Too simple to test" | Simple code breaks. The test takes 30 seconds. |
| "I'll test after" | Tests that pass immediately prove nothing. |
| "The deadline is tight" | TDD is faster for non-trivial work. Debugging without tests is slow. |
| "Just this once" | Every shortcut becomes a habit. No exceptions. |
| "It's just a refactor" | Refactors break things. Tests catch what you missed. |

## Test Types

| Type | When required |
|---|---|
| Unit tests | Every code change |
| Integration tests | API endpoints, DB operations |
| E2E tests | User-facing features (use Playwright) |
| Performance tests | Performance fixes |

## What Happens on Violation

If tests are missing or failing:

1. Do not mark the task as done
2. Block the PR until tests pass — exception: after 2 consecutive blocks by reality-checker, the agent may offer to create the PR with blockers documented, but only with explicit user confirmation (see the `edge-cases` skill)
3. Flag it in the code review

## Stryker Mutation Testing — Production Code Boundary

When running Stryker mutation tests:

- If a mutant can only be killed by CHANGING PRODUCTION CODE (reordering logic, adding guards, modifying behaviour), do NOT change the production code
- Instead, document the surviving mutant as a finding: "Mutant survived at [file:line] — killing it requires production code change, out of scope for test-only PR"
- The test should verify existing behaviour, not reshape production code to be more testable
- If Stryker's initial threshold fails (>50% test failures), use `test-case-filter` in `stryker-config.json` to limit the initial test run — do NOT modify production code to make tests pass

**This boundary applies absolutely** — whether mutation testing ran automatically (default-on) or manually. Full implementation guidance (how default-on is gated, the PROJECT.md override, `config_path` validation, the tool registry) and incident history live in the **`workflow-discipline` skill** — load it when configuring or invoking mutation testing.

**Invoking mutation tools:** the tool command registry (per-tool bootstrap/run commands), the `config_path` security-validation checklist, and the "why the registry lives one trust level above PROJECT.md" rationale now live in the **`workflow-discipline` skill** (§1a) — load it when configuring or invoking mutation testing. This rule keeps the always-loaded directives above (TDD + the Production-Code-Boundary).
