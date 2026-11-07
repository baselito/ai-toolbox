# Testing Anti-Patterns

**Load this reference when:** writing or changing tests, adding mocks, or tempted to add test-only methods to production code.

Cherry-picked from Superpowers (obra/superpowers) `test-driven-development/testing-anti-patterns.md`
and adapted for this toolbox — the gate functions and anti-pattern catalogue below are not covered by
`SKILL.md` (which focuses on the RED-GREEN-REFACTOR cycle, not what happens when mocking goes wrong).

## Overview

Tests must verify real behaviour, not mock behaviour. Mocks are a means to isolate, not the thing
being tested.

**Core principle:** Test what the code does, not what the mocks do.

**Following strict TDD (see `SKILL.md`) prevents these anti-patterns** — writing the test first and
watching it fail against real code is what stops mocks from silently replacing the behaviour under test.

## Mocking Anti-Pattern Rules

(Not to be confused with **The Iron Law** in `rules/testing.md` / `SKILL.md` — no production code without a failing test first. The three rules below govern mocking discipline specifically.)

```
1. NEVER test mock behaviour
2. NEVER add test-only methods to production classes
3. NEVER mock without understanding dependencies
```

## Anti-Pattern 1: Testing Mock Behaviour

**The violation:**
```typescript
// BAD: Testing that the mock exists
test('renders sidebar', () => {
  render(<Page />);
  expect(screen.getByTestId('sidebar-mock')).toBeInTheDocument();
});
```

**Why this is wrong:**
- Verifies the mock works, not that the component works
- Passes when the mock is present, fails when it's not
- Tells you nothing about real behaviour

**The fix:**
```typescript
// GOOD: Test the real component, or don't mock it
test('renders sidebar', () => {
  render(<Page />);  // Don't mock sidebar
  expect(screen.getByRole('navigation')).toBeInTheDocument();
});
```

### Gate Function

```
BEFORE asserting on any mock element:
  Ask: "Am I testing real component behaviour or just mock existence?"

  IF testing mock existence:
    STOP — delete the assertion or unmock the component

  Test real behaviour instead
```

## Anti-Pattern 2: Test-Only Methods in Production

**The violation:**
```typescript
// BAD: destroy() only used in tests
class Session {
  async destroy() {  // Looks like a production API!
    await this._workspaceManager?.destroyWorkspace(this.id);
    // ... cleanup
  }
}

// In tests
afterEach(() => session.destroy());
```

**Why this is wrong:**
- Pollutes the production class with test-only code
- Dangerous if accidentally called in production
- Violates YAGNI and separation of concerns

**The fix:**
```typescript
// GOOD: test utilities handle test cleanup
// Session has no destroy() — it's stateless in production

// In test-utils/
export async function cleanupSession(session: Session) {
  const workspace = session.getWorkspaceInfo();
  if (workspace) {
    await workspaceManager.destroyWorkspace(workspace.id);
  }
}
```

### Gate Function

```
BEFORE adding any method to a production class:
  Ask: "Is this only used by tests?"

  IF yes:
    STOP — put it in test utilities instead

  Ask: "Does this class own this resource's lifecycle?"

  IF no:
    STOP — wrong class for this method
```

## Anti-Pattern 3: Mocking Without Understanding

**The violation:**
```typescript
// BAD: mock breaks the test's own logic
test('detects duplicate server', () => {
  // Mock prevents the config write the test depends on!
  vi.mock('ToolCatalog', () => ({
    discoverAndCacheTools: vi.fn().mockResolvedValue(undefined)
  }));

  await addServer(config);
  await addServer(config);  // Should throw — but won't!
});
```

**Why this is wrong:**
- The mocked method had a side effect the test depended on (writing config)
- Over-mocking "to be safe" breaks the actual behaviour under test
- The test passes for the wrong reason, or fails mysteriously

**The fix:**
```typescript
// GOOD: mock at the correct level
test('detects duplicate server', () => {
  vi.mock('MCPServerManager'); // Just mock the slow server startup

  await addServer(config);  // Config written
  await addServer(config);  // Duplicate detected correctly
});
```

### Gate Function

```
BEFORE mocking any method:
  STOP — don't mock yet

  1. Ask: "What side effects does the real method have?"
  2. Ask: "Does this test depend on any of those side effects?"
  3. Ask: "Do I fully understand what this test needs?"

  IF it depends on side effects:
    Mock at a lower level (the actual slow/external operation),
    NOT the high-level method the test depends on

  IF unsure what the test depends on:
    Run the test with the real implementation FIRST,
    observe what actually needs to happen,
    THEN add minimal mocking at the right level
```

## Anti-Pattern 4: Incomplete Mocks

**The violation:**
```typescript
// BAD: partial mock — only the fields you think you need
const mockResponse = {
  status: 'success',
  data: { userId: '123', name: 'Alice' }
  // Missing: metadata that downstream code uses
};
```

**Why this is wrong:**
- Partial mocks hide structural assumptions — you only mocked fields you know about
- Downstream code may depend on fields you didn't include, causing silent failures
- The test passes but real integration fails — false confidence

**The fix:** mock the complete data structure as it exists in reality, not just the fields your
immediate test uses.

### Gate Function

```
BEFORE creating a mock response:
  Check: "What fields does the real API response contain?"
  Include ALL fields the system might consume downstream.
  If uncertain: include all documented fields.
```

## Anti-Pattern 5: Integration Tests as an Afterthought

Testing is part of implementation, not an optional follow-up — the Iron Law in `SKILL.md` (no
production code without a failing test first) already blocks this, but it's worth naming
explicitly: "implementation complete, no tests written, ready for testing" means TDD was skipped.

## Warning Signs Mocks Have Gotten Too Complex

- Mock setup is longer than the test logic itself
- Mocking everything just to make the test pass
- Mocks are missing methods the real component has
- The test breaks whenever the mock changes

**Consider:** an integration test with real components is often simpler than a complex mock.

## Quick Reference

| Anti-Pattern | Fix |
|---|---|
| Assert on mock elements | Test the real component, or unmock it |
| Test-only methods in production | Move to test utilities |
| Mock without understanding | Understand dependencies first, mock minimally |
| Incomplete mocks | Mirror the real API completely |
| Tests as an afterthought | TDD — tests first |
| Over-complex mocks | Consider integration tests instead |

## Red Flags

- Assertions checking for `*-mock` test IDs
- Methods only ever called from test files
- Mock setup is more than half the test
- The test fails when you remove the mock
- Can't explain why a mock is needed
- Mocking "just to be safe"

## The Bottom Line

Mocks are tools to isolate, not things to test. If TDD reveals you're testing mock behaviour,
test real behaviour instead, or question why you're mocking at all.
