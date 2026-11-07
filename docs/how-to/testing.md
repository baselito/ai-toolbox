# Testing — How It Works End-to-End

How the agent generates, runs, and validates tests during workflows.

---

## Overview

Testing is not a single step — it runs through multiple agents across the workflow. The `tdd-guide` enforces test-first development, the `e2e-runner` generates end-to-end tests, the `code-reviewer` checks test quality, and the `reality-checker` verifies everything passes before the PR is created.

---

## Agents Involved

| Agent | Model | Role in testing |
|---|---|---|
| `tdd-guide` | Opus | Enforces RED-GREEN-REFACTOR — writes failing tests first, then implementation |
| `e2e-runner` | Opus | Generates and runs Playwright E2E tests based on code changes |
| `code-reviewer` | Opus | Reviews test quality — flags weak coverage, missing edge cases |
| `reality-checker` | Opus | Final gate — verifies all tests pass, checks coverage against changes |

---

## How the Pipeline Flows

Here is the full sequence from code change to merged PR. Each step feeds into the next through the [agent handover](agent-handover.md) protocol.

```
You run /flow
        │
        ▼
┌─────────────────┐
│   tdd-guide     │  Writes failing unit test FIRST (RED)
│   (Opus)        │  → You write implementation (GREEN)
│                 │  → Agent refactors (REFACTOR)
│                 │  → Writes to handover: test names, coverage areas
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   e2e-runner    │  Reads handover + code diff
│   (Opus)        │  → Generates Playwright tests (happy + sad + edge)
│                 │  → Runs all tests headless
│                 │  → Writes to handover: pass/fail, report location, coverage summary
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  code-reviewer  │  Reads handover + test files + code diff
│   (Opus)        │  → Reviews test quality (coverage gaps, flaky patterns, weak assertions)
│                 │  → If tests are weak → loops back to e2e-runner with specific feedback
│                 │  → If tests pass review → writes approval to handover
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ reality-checker │  Reads ALL handover notes (always runs last)
│   (Opus)        │  → Re-runs full test suite to confirm everything passes
│                 │  → Checks: do tests actually cover what changed?
│                 │  → If anything fails → blocks PR, reports what broke
│                 │  → If all pass → greenlights PR creation
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   PR created    │  Test files committed alongside code
│                 │  → Beads logs task outcome (pass/fail, test count, coverage)
│                 │  → CI runs tests again (if configured)
│                 │  → You review and merge
└─────────────────┘
```

### What happens when tests fail

| Failure point | What happens | Who fixes it |
|---|---|---|
| `tdd-guide` RED phase | Test won't compile or has syntax errors | `tdd-guide` retries |
| `e2e-runner` test run | One or more E2E tests fail | `e2e-runner` reads error output, fixes test or flags code bug |
| `code-reviewer` review | Tests are too shallow or have flaky patterns | Loops back to `e2e-runner` with specific feedback |
| `reality-checker` final run | Tests that passed before now fail | Blocks PR — reports exact failure to handover, workflow stops |
| CI pipeline | Tests fail in CI but passed locally | Environment issue — check browser versions, deps, network |

The workflow does **not** silently skip failures. If `reality-checker` cannot get all tests green, the PR is not created and you see exactly what failed and why.

### How agents communicate about tests

Every agent writes structured notes to `.claude/handover.md`. Each note includes:

- **What was tested** — file names, test names, features covered
- **Results** — pass count, fail count, skipped count
- **Issues found** — specific test quality problems or code bugs
- **Recommendations** — what the next agent should look at

This means no agent re-does work. The `code-reviewer` doesn't re-run tests — it reads the results from `e2e-runner`'s handover notes. The `reality-checker` reads everything from all previous agents before doing its final verification.

---

## Beads — Test History and Tracking

[Beads](../concepts/beads.md) tracks every task across sessions. Test results are part of that tracking.

### What Beads records per task

- **Test outcome** — did all tests pass before PR was created?
- **Test count** — how many unit tests and E2E tests were generated
- **Coverage areas** — which features/files the tests cover
- **Failure history** — if tests failed and were fixed, that's recorded too
- **Time spent** — how long the testing phase took

### Why this matters

Over time, Beads builds a history of:

- Which features have strong test coverage vs weak
- Which types of tasks tend to have test failures
- How long testing takes relative to implementation
- Sprint velocity including test time

This feeds into `/flow` retrospectives (on Scrum boards). You can see patterns like "API endpoint tasks always need 2 rounds of test fixes" and adjust planning accordingly.

### Viewing test history

```bash
# Inside Claude Code, in your project
bd show                    # Current task details including test results
bd list                    # All tasks with outcomes
bd show <task-id>          # Specific task details
```

Beads data persists across sessions. If you close Claude Code and come back tomorrow, the test history is still there.

---

## What Gets Tested

### Unit Tests (tdd-guide)

The `tdd-guide` agent enforces TDD methodology:

1. **RED** — Write a failing test for the new behavior
2. **GREEN** — Write the minimum code to make it pass
3. **REFACTOR** — Clean up without changing behavior

This applies to every code change in `/flow`, `/build`, `/bug`, and `/hotfix`.

### End-to-End Tests (e2e-runner)

The `e2e-runner` generates Playwright tests based on what changed. It reads the task context and produces tests covering:

- **Happy path** — Feature works as expected with valid input
- **Sad path / negative tests** — Invalid input, missing required fields, unauthorized access attempts
- **Edge cases** — Empty states, boundary values, special characters, concurrent actions
- **Error states** — Network failures, API errors, timeouts, server error responses

The agent reasons about what can go wrong, not just what should work. If a form is added, it tests submission with valid data AND with missing fields, invalid formats, and duplicate entries.

### What Commands Trigger E2E Tests

| Command | Unit tests (tdd-guide) | E2E tests (e2e-runner) |
|---|---|---|
| `/flow` | ✅ | ✅ |
| `/build` | ✅ | ✅ |
| `/bug` | ✅ | ❌ (fix-focused) |
| `/hotfix` | ✅ | ❌ (speed-focused) |
| `/refactor` | ✅ | ❌ (no new behavior) |

---

## What You See

### During the workflow

- Test files appear in your project (e.g., `tests/`, `__tests__/`, or `e2e/`)
- Terminal output shows each test running with pass/fail status
- Failed tests show error messages, expected vs actual values

### In the PR

- Generated test files are committed alongside the code changes
- You review the tests like any other code in the PR
- The `code-reviewer` agent comments on test quality issues

### Playwright reports (E2E only)

Playwright can generate detailed reports:

- **HTML report** — `npx playwright show-report` after a run
- **Traces** — Step-by-step screenshots, DOM snapshots, network logs
- **Screenshots on failure** — Automatic screenshot when a test fails

---

## Configuring Playwright

The `e2e-runner` agent uses your project's Playwright config. If none exists, it creates a default one.

### Key settings in `playwright.config.ts`

```typescript
export default defineConfig({
  // Run tests without opening a browser window (default in CI)
  use: {
    headless: true,
    // Generate trace on failure for debugging
    trace: 'on-first-retry',
    // Screenshot on failure
    screenshot: 'only-on-failure',
  },
  // Browsers to test against
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'firefox', use: { ...devices['Desktop Firefox'] } },
  ],
});
```

### Running modes

| Mode | Command | What you see |
|---|---|---|
| Headless (default) | `npx playwright test` | Terminal output only — fastest |
| Headed | `npx playwright test --headed` | Browser window opens, watch tests execute |
| UI mode | `npx playwright test --ui` | Full dashboard — step through tests, view traces, DOM snapshots |
| Debug | `npx playwright test --debug` | Step through test line by line with inspector |

The agent runs headless by default. To watch tests visually, run them manually with `--headed` or `--ui` after the agent generates them.

---

## Reviewing Test Quality

The `code-reviewer` agent checks generated tests for:

- **Coverage gaps** — Did the tests cover the actual changes?
- **Missing negative tests** — Are error paths tested?
- **Flaky patterns** — Hard-coded timeouts, race conditions, order-dependent tests
- **Assertions** — Are assertions meaningful or just checking "page loaded"?

If tests are too shallow, `code-reviewer` flags them in the handover notes and the workflow loops back to fix them before the PR is created.

### What to look for yourself

Even with agent review, check that generated tests:

1. Actually test the behavior you changed (not just boilerplate)
2. Include at least one negative/error test per feature
3. Don't rely on specific data that might change
4. Have clear test names that describe what they verify
5. Would catch a regression if someone broke the feature later

---

## The Trust Model

Tests go through three layers of review before reaching your PR:

1. **`e2e-runner`** generates tests based on code context
2. **`code-reviewer`** reviews test quality and flags gaps
3. **`reality-checker`** (always last) verifies all tests actually pass

You are the final reviewer. The agents do the heavy lifting, but you approve the PR. If tests look weak or miss obvious cases, reject and tell the agent what to add.

---

## CI Integration (Optional)

By default, tests run locally on the developer's machine. To make test results visible to the whole team, add Playwright to your CI pipeline. This is optional — set it up per project when you're ready.

### Where reports go

| Setup | Who sees results | How |
|---|---|---|
| Local only (default) | Developer only | `npx playwright show-report` after a run |
| CI pipeline | Whole team | Reports published as build artifacts on every PR |

### GitHub Actions

Add this as `.github/workflows/e2e.yml`:

```yaml
name: E2E Tests
on: [pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20

      - run: npm ci
      - run: npx playwright install --with-deps
      - run: npx playwright test

      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: playwright-report
          path: playwright-report/
          retention-days: 14
```

Reports are available as downloadable artifacts on each PR's Actions tab.

### No CI yet?

That's fine. Tests still run locally during every `/flow` workflow. The agent generates tests, runs them, and reports pass/fail in the terminal. You can add CI later without changing any toolbox configuration.

---

## Mutation Testing (ON by default)

Mutation testing tools such as Stryker.NET, Stryker.JS, and Stryker for Scala deliberately corrupt the code in small ways and re-run the test suite. Each corruption is a "mutant" — a test that survives the corruption is a test that wasn't actually checking what it looked like it was checking. The "mutation score" measures how many mutants the test suite kills.

**Mutation testing is ON by default.** Whenever a ticket creates (or should create) unit tests — the normal TDD case for any testable production code — Stryker runs at the Verification phase to validate those tests. The `Mutation testing` field in `/start` / `/flow` defaults to `Yes — auto-detect tool at verification (recommended)`, and the toolbox auto-detects the stack (`*.csproj` → Stryker.NET, `package.json` + test runner → Stryker.JS, `pom.xml` + Java source → PIT, `*.scala` + `build.sbt` → Stryker for Scala). **The toolbox does NOT auto-install Stryker or project dependencies** — the selected runner must already be installed before verification.

**It auto-skips where it doesn't apply.** Tickets that can't have unit tests — pure config, docs, infra/pipeline YAML, identifier renames, generated code — write no unit tests, so `/flow` Step 11b skips Stryker for them (nothing to mutate). `/hotfix` and `/incident` skip it entirely to ship fast.

**To change the default:**

| Want | How |
|---|---|
| Skip Stryker on one ticket | Edit the `Mutation testing` field to `No`, or say "no stryker" / "skip stryker" in your invocation |
| Pin a specific tool (skip auto-detect) | Add a `mutation_testing` block with `when_to_run: before_pr` to `.claude/PROJECT.md` (run `/init` → `Yes`, or edit manually) |
| Run only on test-only PRs | `mutation_testing` block with `when_to_run: test_only_prs` |
| Opt the whole project OUT of default-on | `mutation_testing` block with `when_to_run: manual` — Stryker then runs only when explicitly requested per ticket |

### Tuning the project default (optional)

Most projects need no policy setup, but the selected Stryker runner and its project dependencies/configuration must already be installed. The toolbox does not install third-party runners during verification. If you want to deviate, run `/init` and pick a mutation-testing policy, or edit `.claude/PROJECT.md` directly (`examples/PROJECT.md.example` shows the block template). The wizard also generates the minimal config file (`stryker-config.json` / `stryker.config.mjs`). To return a project to plain default-on, delete the entire `mutation_testing` block.

**What `/init` ALSO sets up universally (regardless of per-ticket vs per-project choice):**

1. **Gitignore patterns** for Stryker reports (`StrykerOutput/`, `stryker-results/`, `reports/mutation/`, `mutation-report.html`, `mutation-report.json`, plus `**/`-prefixed variants for monorepos) — added to every project's `.gitignore` whether or not Stryker is installed today. Pre-emptive blocking so a future Stryker run can't accidentally commit gigabytes of binary HTML/JSON output. **Playwright is NOT covered** — `npm init playwright@latest` adds its own gitignore entries (`test-results/`, `playwright-report/`, `playwright/.cache/`, `.last-run.json`), so the toolbox doesn't duplicate work the tool already handles. The principle: fill gaps that tools don't fill themselves. See `commands/init.md` Step 5 sub-step 1b.

2. **A `mutation_testing` template** in `examples/PROJECT.md.example` showing the YAML block a project fills out when it wants to override the default-on behavior (pin a tool, restrict when it runs, or opt out via `manual`). The block names the tool, the config path, and a `when_to_run` policy. When the block is present in `.claude/PROJECT.md`, the agent reads it during `/flow`, `/bug`, `/build`, and `/review-pr` verification phases and invokes the tool according to the policy. The `/init` wizard automates filling out this template.

### Choosing a project policy (only if you deviate from default-on)

| Situation | `when_to_run` |
|---|---|
| Default-on is fine, but you want to pin a tool / skip auto-detect | `before_pr` |
| Only want mutation testing on test-coverage PRs | `test_only_prs` |
| Suite is too slow to mutate every ticket — opt out of default-on | `manual` (Stryker runs only when explicitly requested) |
| Project doesn't use mutation testing at all | `manual`, or just say "no stryker" per ticket |

### Always use the latest version

The toolbox-owned tool registry in the `workflow-discipline` skill (§1a) runs the appropriate registered runner before every invocation. For .NET it uses `dotnet stryker`; for JS it uses the project's Stryker executable through `npx --no-install`; and for Scala it uses `sbt stryker`. A fresh project gets the project-compatible runner rather than an unreviewed shell command from `PROJECT.md`.

### Why the block has no shell commands

`PROJECT.md` is committed to the repo and editable via PR. If we let projects supply `run_command` or `update_command` strings here, a malicious PR could replace `dotnet stryker` with arbitrary shell that the agent later executes during verification. Instead, the agent reads the `tool:` name from PROJECT.md and looks up the actual command from a registry in the `workflow-discipline` skill (§1a) — a toolbox-owned file that PRs to your project repo cannot modify. This trust boundary keeps `PROJECT.md` as data the project owner controls, while shell commands live one trust level above. Automated review caught this attack path during PR #58 review and the architecture is the response.

### Production code boundary (absolute)

If a surviving mutant can only be killed by changing production code, the mutant is **reported as a finding** — never an excuse to edit production. The toolbox enforces this through `rules/testing.md` ("Stryker Mutation Testing — Production Code Boundary"). Incident history: TASK-760 — agent reordered production guard clauses to kill mutants, shipped to a deploy queue, required a manual revert.

---

## Related

- [Agent List](../reference/agent-list.md) — Full agent details and model assignments
- [Commands](commands.md) — Which commands trigger which agents
- [Agent Handover](agent-handover.md) — How agents pass test results to each other
