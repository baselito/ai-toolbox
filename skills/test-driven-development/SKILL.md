---
name: test-driven-development
source: Superpowers (obra/superpowers)
description: Use when implementing any feature or bugfix — enforces strict RED-GREEN-REFACTOR with anti-rationalization
---

# Test-Driven Development (TDD)

Write the test first. Watch it fail. Write minimal code to pass.

**Core principle:** If you didn't watch the test fail, you don't know if it tests the right thing.

## When to Use

**Always:**
- New features
- Bug fixes
- Refactoring
- Behaviour changes

**Exceptions (ask the user):**
- Throwaway prototypes
- Generated code
- Configuration files

Thinking "skip TDD just this once"? Stop. That's rationalisation.

## The Iron Law

```
NO PRODUCTION CODE WITHOUT A FAILING TEST FIRST
```

Write code before the test? Delete it. Start over.

**No exceptions:**
- Don't keep it as "reference"
- Don't "adapt" it while writing tests
- Don't look at it
- Delete means delete

Implement fresh from tests. Period.

## Red-Green-Refactor

### RED — Write Failing Test

Write one minimal test showing what should happen.

**Requirements:**
- One behaviour per test
- Clear name that describes what it verifies
- Real code (no mocks unless unavoidable)
- "and" in the test name? Split it into two tests

### Verify RED — Watch It Fail

**MANDATORY. Never skip.**

Run the test. Confirm:
- Test fails (not errors — a test error means broken setup, not a valid RED)
- Failure message matches what you expect
- Fails because the feature is missing (not because of typos or import errors)

**Test passes immediately?** You're testing existing behaviour. Fix the test.

### GREEN — Minimal Code

Write the simplest code to pass the test.

- Don't add features beyond what the test requires
- Don't refactor other code
- Don't "improve" beyond what the test checks
- If you're writing more than a few lines, the test probably covers too much — split it

### Verify GREEN — Watch It Pass

**MANDATORY.**

Run the test. Confirm:
- The new test passes
- All existing tests still pass
- Output is clean (no errors, warnings, deprecation notices)

**New test fails?** Fix the code, not the test.
**Other tests fail?** Fix them now — don't move on with broken tests.

### REFACTOR — Clean Up

After green only:
- Remove duplication
- Improve names
- Extract helpers
- Simplify logic

Keep all tests green throughout. Don't add new behaviour during refactor.

### Repeat

Next failing test for the next piece of behaviour.

## Common Rationalisations

| Excuse | Reality |
|---|---|
| "Too simple to test" | Simple code breaks. The test takes 30 seconds to write. |
| "I'll test after" | Tests that pass immediately prove nothing — you never saw them fail. |
| "Tests after achieve the same goals" | No. You can't verify the test catches the bug if you never saw it fail. |
| "Just this once" | Every shortcut becomes a habit. No exceptions. |
| "I know this works" | Then prove it with a failing test. Takes seconds if you're right. |
| "The deadline is tight" | TDD is faster for anything non-trivial. Debugging without tests is what's slow. |
| "It's just a refactor" | Refactors break things. Tests catch what you missed. |
| "I need to see the shape first" | Write a spike, delete it, then TDD the real implementation. |
| "Mocking is too hard" | If it's hard to test, the design needs improvement. Testability = good design. |

## Red Flags — STOP and Start Over

If any of these happen, delete the code and restart with TDD:

- Code was written before its test
- Test was added after implementation
- Test passes immediately on first run
- Can't explain why a test failed
- Tests were added "later" to hit coverage
- Rationalising "just this once"
- Test names don't describe behaviour
- Multiple behaviours in one test

## Testing Anti-Patterns

When adding mocks or test utilities, read [testing-anti-patterns.md](testing-anti-patterns.md) —
cherry-picked from upstream Superpowers, it covers pitfalls this file doesn't: testing mock
behaviour instead of real behaviour, adding test-only methods to production classes, and mocking
without understanding dependencies.

## Bug Fix Integration

Bug found? Follow this exact sequence:

1. **Write a failing test** that reproduces the bug
2. **Verify RED** — confirm the test fails for the right reason
3. **Fix the bug** — minimal code to make the test pass
4. **Verify GREEN** — test passes, all other tests still pass
5. **Refactor** if needed

Never fix bugs without a test. The test proves the fix works and prevents regression.

## Verification Checklist

Before marking work complete:

- [ ] Every new function/method has a test
- [ ] Watched each test fail before implementing
- [ ] Each test failed for the expected reason (feature missing, not typo)
- [ ] Wrote minimal code to pass each test
- [ ] All tests pass
- [ ] Output is clean (no errors, warnings)
- [ ] Tests use real code (mocks only if unavoidable)
- [ ] Edge cases and error paths covered

Can't check all boxes? You skipped TDD. Start over.

## Applies To

The `tdd-guide` agent (Opus) enforces these rules during every implementation phase. All agents that write code must follow this discipline. The `testing.md` rule sets the coverage threshold (80%); this skill defines the methodology.
