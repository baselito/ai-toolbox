---
name: workflow-discipline
description: Full detail behind the always-loaded workflow-discipline directives — the Stryker/mutation-testing keyword grammar (opt-in/opt-out/negation/incidental disambiguation), the universal gitignore pre-check script and its per-command timing, the toolbox-owned verification command registry (the literal test/lint/build commands behind PROJECT.md's keys-only `verification:` block, the raise-only coverage-floor clamp, and why there is no smoke gate), the loop budget ceilings behind the tighten-only `loop:` block, the toolbox install/update gating procedure (8a Codex opt-in, 8b docs verification), and the incident histories that justify each rule. Load this when handling a Stryker or "mutation testing" keyword, resolving a project's `verification:` or `loop:` block to actual commands or limits, running the gitignore pre-check before branching/committing in a project repo, installing or updating the ai-engineering toolbox itself, or when you need the rationale/incident history behind a workflow-discipline rule.
source: custom
---

<!-- ask-headers: Unknown -- every AskUserQuestion this file instructs uses this header unless the line names its own (rules/autonomy.md) -->


# Workflow Discipline — Detail

The terse directives live in the always-loaded `rules/workflow-discipline.md`. This skill carries the bulk that does **not** need to be in context every session: the Stryker keyword grammar, the verification command registry and loop budget ceilings (§1c, §1d — the toolbox-owned literals behind `PROJECT.md`'s keys-only `verification:` and `loop:` blocks), the gitignore pre-check script, the toolbox install/update procedure, and the incident histories. Load it on demand when a task hits one of those.

---

## 1. Mutation-testing (Stryker) per-ticket keyword grammar

**Mutation testing is ON by default** for every ticket that creates (or should create) unit tests. Tickets that can't have unit tests (config, docs, infra/pipeline YAML, identifier renames, generated code) are auto-skipped at `/flow` Step 11b, and `/hotfix` + `/incident` skip it entirely. See §1a below and `commands/flow.md` Step 11b. These keywords let the user FORCE the field on or off for a single ticket:

| User says | Effect |
|---|---|
| **Opt-IN** (reaffirms the default): "use stryker", "with stryker", "run stryker", "enable stryker", "stryker on", "use mutation testing", "with mutation testing", "run mutation testing", "enable mutation testing" | Pin the Mutation testing field in the `/start` Step 5 confirmation summary (and the `/flow` Step 3 summary that re-uses it) to `Yes — auto-detect tool at verification (recommended)`. Mostly redundant now that Yes is the default, but harmless. |
| **Opt-OUT** (forces off): "no stryker", "skip stryker", "without stryker", "disable stryker", "no mutation testing", "skip mutation testing", "without mutation testing", "disable mutation testing" | Pre-populate the Mutation testing field as `No` for this ticket, overriding the default-on behaviour. The user can still edit the field back to Yes. |

Matching is **case-insensitive** and matches as a substring (the keyword may appear anywhere in the user's message). Both lists are intentionally closed sets of verb-phrase variants — bare `"stryker"` as a single token triggers neither (it would false-positive against incidental references like "I found a stryker performance bug"). An opt-in keyword must include one of the verb prefixes (`use` / `with` / `run` / `enable`) or the `on` suffix; an opt-out keyword must include one of (`no` / `skip` / `without` / `disable`). **Conjunctions like `also` and `and` do NOT qualify** — they're not verbs, and `also stryker` / `and stryker` would false-positive on sentences like "update Jest and Stryker config" or "there is also Stryker output in this repo".

**Disambiguation — opt-out vs incidental mention.** Two phrase classes look similar but mean different things; the negation markers route to the **opt-OUT** table above (force `No`) rather than merely suppressing an opt-in, but a genuine intent-to-skip must still be told apart from an incidental negated mention:

1. **Opt-out routing** — set the field to `No` when the message expresses intent to skip mutation testing for THIS ticket. This covers two forms:
   - The explicit opt-out phrases (`no stryker`, `skip stryker`, `without stryker`, `disable stryker`, and the `... mutation testing` variants): "skip stryker on this one", "no stryker for this ticket", "without stryker".
   - **A negated opt-in phrase** — an opt-in keyword (`run stryker`, `use stryker`, `enable stryker`, `run mutation testing`, etc.) preceded within 4 words by a negation marker (`don't`, `dont`, `do not`, `not`, `never`, `no`): "don't run stryker on this ticket", "do not use mutation testing", "never run stryker here". The negation flips the opt-in to an opt-OUT → force `No`. (This is the critical case: without it, "don't run stryker" contains the opt-in substring `run stryker` and would wrongly resolve to `Yes`.)
2. **Incidental-mention rejection** (set NEITHER on nor off — leave at whatever value the field already had) — if any of these context phrases appears within 4 words BEFORE the matched keyword (same sentence), the mention is about debugging/fixing Stryker itself, not a request to enable or disable it for the ticket: `issue with`, `bug in`, `problem with`, `error in`, `investigate`, `debug`, `output of`, `output in`, `config for`, `config in`, `debug the`, `investigate the`, `troubleshoot the`. (`fix the` is deliberately NOT in this list — it would suppress legitimate opt-ins like "fix the auth bug with stryker".) Leave the field unchanged. Examples that change NOTHING:
   - "investigate issue with stryker output" (`issue with` — debugging Stryker, not disabling it)
   - "debug the stryker config on the CI runner" (`debug the` — maintenance context)
   - "config in stryker.config.mjs is wrong" (`config in` — describing a config bug)

If a sentence contains BOTH an opt-out phrase AND an incidental-context phrase in a way that's genuinely ambiguous, surface it and ask via AskUserQuestion: "I see `<phrase>` — disable mutation testing for this ticket, or leave it on?" with options No / Yes.

**Resolution rule (merged):** evaluate in this order — (a) if a message contains BOTH a genuine opt-in and a genuine opt-out in different clauses and the intent is ambiguous, surface it and ask via AskUserQuestion: "I see both `<opt-in phrase>` and `<opt-out phrase>` — run mutation testing on this ticket, or skip it?" with options Yes / No (default to the global default-on if the user doesn't pick); (b) else if an **opt-out** keyword OR a **negated opt-in** matches → force the field to `No` (an explicit "do not run stryker" wins even if a word like `debug`/`investigate` appears earlier in the sentence); (c) else if an incidental-context phrase precedes a bare opt-in keyword → change nothing (leave the field at its current value); (d) else if an **opt-in** keyword matches → pin the field to `Yes`. The incidental guard only suppresses a *bare* opt-in (the "debug the stryker config" case) — it never overrides an explicit opt-out.

Examples:

- "start working on TASK-756" → invoke `/start TASK-756`; mutation testing defaults to **Yes** and runs at Verification if the ticket creates unit tests
- "start TASK-756, no stryker" → invoke `/start TASK-756`, pre-populate mutation testing as **No** for that single ticket
- "skip stryker on this one" → if already in `/start` or `/flow` for a specific ticket, set the field to `No` for that ticket. Does NOT persist beyond the current ticket.

**No session-level persistence.** A keyword (opt-in or opt-out) applies to the SINGLE ticket being processed RIGHT NOW. There is no sticky "stryker off" mode across tickets — the next `/start` or `/flow` invocation reverts to the default-on behaviour. To skip Stryker on multiple consecutive tickets, the user must say so each time.

**Supported entry points:** `/start` and `/flow` expose the `Mutation testing`
field and keyword overrides in their confirmation summary. `/build`, `/bug`,
and `/refactor` use the same registry automatically when their workflow is
represented by a GoalRun; direct legacy paths without a GoalRun report that
mutation testing was not run rather than claiming a score.

**Behaviour on non-GoalRun commands** (`/security`, `/perf`, and any direct
legacy `/bug`, `/build`, or `/refactor` path): these do not expose the field or
run the registry today. If the user includes a stryker keyword in one of these,
surface a warning at the confirmation-summary step:

> "Mutation testing is not active on this direct path. Continue through `/start` or `/flow`, or resume the work as a GoalRun, where the registry runs by default. Continuing without mutation testing for now."

Continue the workflow without mutation testing — do not stop. **Future
extension:** direct paths can gain the same field later; GoalRun remains the
canonical durable path.

**What "auto-detect at verification" means:** at `/flow` Step 11b, after the unit-test gate passes, scan the repo for supported stack signals (`*.csproj` → Stryker.NET, `package.json` with vitest/jest/mocha/jasmine/karma/cucumber/tap → Stryker.JS, `pom.xml` with Java source → PIT, `*.scala` with `build.sbt` → Stryker for Scala). One match → use it. Multiple/none → AskUserQuestion to pick or record not-applicable. Invoke via the registry in §1a below — no per-project setup.

**Skip on urgent paths:** `/hotfix` and `/incident` do NOT run mutation testing (they skip verification to ship fast). If a user passes a stryker keyword, note: "Mutation testing is skipped for urgent fixes — run it manually after the fix lands if you want coverage feedback."

**Incident history:** none yet. Per-ticket Stryker opt-in shipped 2026-05-29; default-on shipped 2026-06-16.

---

## 1a. Mutation-testing tool registry — full implementation guidance

`rules/testing.md` "Stryker Mutation Testing" keeps the compact, always-loaded directives (the production-code boundary and a pointer to this section). This section now holds the canonical tool registry, the `config_path` security-validation checklist, and the trust-boundary rationale, plus the walkthrough and incident history behind them — load it when configuring `mutation_testing` in a project's `PROJECT.md` or debugging why the agent refused a `config_path`.

### Tool command registry (canonical)

The toolbox does NOT auto-install mutation tools; each project picks one supported Stryker runner (Stryker.NET / Stryker.JS / Stryker for Scala). **Mutation testing is ON by default** for any ticket that creates unit tests — gated on unit-test applicability, auto-skipped for config/docs/infra-only tickets, and always skipped on `/hotfix` and `/incident`. See `commands/start.md` Step 5, `commands/flow.md` Step 11b, and `rules/workflow-discipline.md` Rule 0 for the per-ticket keyword overrides. An optional `mutation_testing` block in `PROJECT.md` (documented in `examples/PROJECT.md.example`) lets a project pin a supported tool or opt out via `when_to_run: manual` — **it never contains shell commands**; the agent only ever runs the fixed commands in the registry below, keyed by the resolved `tool:` value.

**Security boundary (always enforced, never skip):** before using any PROJECT.md-supplied `config_path`, the agent validates EVERY check below — each retains its exact form because paraphrasing them is how bypasses re-enter (PR #58 findings III/IV):

- **Relative only** — reject if it starts with `/` (absolute Unix), matches `^[A-Za-z]:[\\/]` (absolute Windows drive), or starts with `~` (home expansion). UNC paths (`\\server\share\…`) start with backslash and are caught by the metacharacter check below, not this rule.
- **No traversal** — reject if any path SEGMENT equals `..` after splitting on `/` (a substring test for ".." is not equivalent).
- **No shell metacharacters or control chars** — reject on the literal class `[;&|\`$<>(){}*?[\]\\\n\r\0]` (the explicit `\0` stays: YAML parsers usually strip null bytes, but the explicit reject removes ambiguity).
- **Never `.git`** — after `readlink -f`, reject when the resolved parent directory is EXACTLY `<repo_root>/.git` OR starts with `<repo_root>/.git/`. Both forms are required: `config_path: ".git/config"` resolves to exactly `<repo_root>/.git` with no trailing slash, which a prefix-only check misses. Atomic form: `(resolved + "/").startswith(repo_root + "/.git/")`.
- **Inside the repo** — the `readlink -f`-resolved path must be exactly `<repo_root>` or start with `<repo_root>/` (trailing-slash-anchored — a naive `startswith(repo_root)` accepts sibling dirs like `/work/repo-malicious`). Symlink chains that escape the repo at any hop are rejected (resolve first, then boundary-check the final path).

The agent never appends `config_path` or any other PROJECT.md field into a shell command — it `cd`s to the validated directory and runs the registry's literal `run:` string. **Unsupported `tool:` or `when_to_run` values fail closed** — the agent refuses to invoke the tool and tells the user to run it manually or file a toolbox PR to extend the registry. Implementation walkthrough with worked pseudo-code and the full PR #58 automated-review finding history: §1a below.

#### Tool command registry

```yaml
tool_registry:
  stryker.net:
    bootstrap: []
    run: "dotnet stryker"
    default_output_dir: "StrykerOutput"

  stryker.js:
    bootstrap: []
    run: "npx --no-install stryker run"
    default_output_dir: "reports/mutation"

  scala-sbt:
    bootstrap: []
    run: "sbt stryker"
    default_output_dir: "target/stryker4s"

```

**Why the registry lives here, not in PROJECT.md:** this file goes through the toolbox's own review + human-gated merge; PROJECT.md is editable by every contributor via a project PR. The registry sits one trust level above PROJECT.md so the agent never executes shell that crossed the project's review boundary.

### How the agent uses a registry entry

1. Resolve `config_path` from PROJECT.md to its **directory** (parent path).
2. **Validate** `config_path` is safe to use:
   - **Must be relative** — reject if it starts with `/` (absolute Unix), matches `^[A-Za-z]:[\\/]` (absolute Windows with drive letter), or starts with `~` (home expansion). UNC paths (`\\server\share\...`) start with backslash and are caught by the shell-metacharacter check below, not this rule. Automated review finding C: a malicious PR could otherwise set `config_path: "/tmp/evil/stryker.conf.json"` and `cd` outside the repo.
   - **No path traversal** — reject if any segment is `..` (after splitting on `/`).
   - **No shell metacharacters or control chars** — reject if it matches `[;&|\`$<>(){}*?[\]\\\n\r\0]` (the `\0` explicit reject was added per security-reviewer round-2 hardening note; YAML parsers usually strip null bytes but explicit reject removes any ambiguity).
   - **Must NOT target `.git`** — even though `.git/` is technically inside the repo, the agent refuses any `config_path` whose resolved directory is exactly `<repo_root>/.git` OR starts with `<repo_root>/.git/`. **Both forms must be rejected.** A `config_path: ".git/config"` resolves to a parent directory of exactly `<repo_root>/.git` (no trailing slash) — a naive "starts with `<repo_root>/.git/`" check would let this slip through, because the resolved string has no trailing slash to satisfy the prefix (PR #58 automated-review cycle 3 finding III). The simplest implementation (in pseudo-code; adapt for your language): normalize by appending `/` to the resolved directory and check `(resolved + "/").startswith(repo_root + "/.git/")` — that handles both the exact-match and proper-prefix cases atomically. **Note:** this check, like the boundary check below, must run on the **`readlink -f` resolved** directory (security-reviewer round-3 hardening note) — a symlink whose name does not contain `.git` but which resolves into `.git/` would otherwise slip a pre-resolution string check. Running a mutation tool inside the git internals directory is never the user's intent; rejecting protects against PR-set `config_path: ".git/config"` style least-privilege violations.
   - **Must resolve inside the repo** — after computing the parent directory, the agent verifies the resolved absolute path (with all symlinks followed via `readlink -f` or equivalent) is either exactly `<repo_root>` OR starts with `<repo_root>/` (note the explicit trailing-slash separator). **A naive `startswith(<repo_root>)` string check is insufficient** — a sibling path like `/work/repo-malicious/subdir` starts with `/work/repo` as a string yet is outside `/work/repo` (PR #58 automated-review cycle 3 finding IV). The trailing-slash separator anchors the prefix at a path-component boundary; without it, any directory whose name is a prefix of the repo root would silently be accepted. The simplest implementation (in pseudo-code; adapt for your language): normalize by appending `/` to BOTH the resolved path and the repo root before comparing, or check `resolved == repo_root || resolved.startswith(repo_root + "/")`. Symlink chains that escape outside the repo at any hop are rejected (the `readlink -f` step resolves them; the boundary check on the final resolved path is what catches sibling-prefix bypass).
3. `cd` to that validated directory, then run the literal `run:` string from the registry. No string interpolation — the agent never appends `config_path` (or any other PROJECT.md field) to the command. Tools read their config from the current working directory or via a constant flag, both of which are captured in the registry entry.

### Registry entry rationale (why each command looks the way it does)

- **`stryker.net`** — runs the locally available `dotnet stryker` command from the selected test-project directory. The verifier does not install or update the global tool; a missing runner is `UNAVAILABLE` with a manual setup action. Stryker.NET reads its config from the current working directory.
- **`stryker.js`** — uses the project's checked-in Stryker executable through `npx --no-install`, so the verifier never downloads or silently changes dependencies. A missing local runner is `UNAVAILABLE` with a manual install action. Reads the Stryker config from the selected project directory; no `config_path` interpolation occurs in the command.
- **`scala-sbt`** — invokes the checked-in Stryker4s SBT task with `sbt stryker`. The verifier does not rewrite `build.sbt` or install the plugin; missing SBT/plugin support is `UNAVAILABLE`.

**Unsupported tool name** — if `tool:` in PROJECT.md isn't in the registry, the agent refuses to autonomously invoke the tool: "Mutation testing requested but tool '<name>' isn't in the toolbox registry. Run the tool yourself, or update the registry in the `workflow-discipline` skill §1a to add the entry (toolbox PR)." This keeps the agent's execution surface bounded to a known-good set.

**Unsupported `when_to_run` value** — same fail-closed policy; if it's not one of `test_only_prs` / `manual` / `before_pr`, the agent refuses to invoke the tool and tells the user the value is unrecognised.

**Incident history:** TASK-760 — agent reordered guard clauses in `UnitLeasePeriod.cs` to kill Stryker mutants. This triggered a release bot deploy notification. Production code was shipped when the user explicitly said "no production code changes." This is why the production-code boundary in `rules/testing.md` is a hard rule, not a preference.

---

## 1b. Mutation testing — the Step 11b procedure (`/flow`)

This is the full execution detail for `commands/flow.md` Step 11b, which carries only the
trigger, the unit-test gate, and the Production-Code Boundary. Load this when Step 11b fires.

**Trigger:** the orchestrator reads the Mutation testing field from the confirmation summary (saved to `.claude/handover.md` after `/start` Step 5 or `/flow` Step 3). If the field is `No`, SKIP this entire sub-step. If `Yes` (the default), apply the **unit-test gate** below before running.

**⛔ Unit-test gate (the context-based decision) — check FIRST, before resolving any tool.** Mutation testing only makes sense where there are unit tests to mutate. Before running Stryker, confirm this ticket actually created (or should have created) unit tests:
- Read the Implementation handover entry. If it recorded unit tests written for this ticket (the normal TDD case for testable production code) → **proceed** to tool resolution below. This includes **test-only tickets that add or strengthen unit tests for existing production code** — those have plenty to mutate (the existing production code under test) and are exactly where Stryker is most valuable, so they always proceed.
- If the ticket was classified as **no testable code AND no new/changed unit tests** — pure config, docs, infra/pipeline YAML, identifier renames, generated code — then there is nothing to mutate → **SKIP** with a one-line note: "Mutation testing skipped — this ticket has no unit tests and no production code to mutate." This is the context-based skip the team's policy calls for: Stryker runs whenever unit tests can and should be created (or were added against existing code), and is skipped only when there is genuinely nothing to mutate. The decision follows the same TDD judgement made across discovery/assessment/planning/implementation — it is not re-litigated here.

**Handover format (mandatory verbatim line):** the confirmation-summary handover entry MUST include the line `Mutation testing: <value>` verbatim — e.g. `Mutation testing: Yes — auto-detect tool at verification (recommended)`, `Mutation testing: Yes — Stryker.NET`, `Mutation testing: No`. Step 11b reads the field by grep-matching `^Mutation testing: ` in the handover. Free-form prose like "the user wants stryker" does NOT set the field — only the explicit line does. This keeps the decision visible to anyone reading the handover later (post-mortem, ticket review, etc.).

**Exit-code handling for the grep:** a literal `grep '^Mutation testing: ' .claude/handover.md` exits 1 if no matching line exists, which happens for legacy tickets, incomplete handovers, or tickets where the user skipped /start (e.g. direct `/flow TASK-XXX`). When the field is missing (grep exit 1, empty output, or missing handover file), Step 11b first consults `.claude/PROJECT.md` `mutation_testing.when_to_run` to honour any project override, then applies the global default:
- `manual` → treat the missing field as `No` (project opted OUT of default-on) → skip.
- `test_only_prs` → run ONLY if Assessment classified this ticket as test-only; otherwise treat as `No` (skip). This preserves the documented test-only-PR restriction even when the confirmation field is absent.
- `before_pr` → treat as `Yes`; if `mutation_testing.tool` is set, pin it (skip auto-detection), otherwise fall back to auto-detection AND surface a one-line note: "PROJECT.md has `when_to_run: before_pr` but no `mutation_testing.tool` — using auto-detection; pin `tool` if you need a specific runner." (`tool` is optional, but the note prevents silently running an unintended tool in multi-runner repos.)
- No block / any other value → apply the **global default `Yes — auto-detect tool at verification (recommended)`**.
Then apply the unit-test gate above. Exit codes other than 0 or 1 (e.g. grep failed for OS-level reasons) should log a warning and default to skip — never error out the workflow.

Mutation testing runs by default on every ticket that produces unit tests (see `rules/workflow-discipline.md` Rule 0 and `rules/testing.md`). The two guards that keep it from wasting time: the unit-test gate above (tickets with nothing to mutate are skipped), and the urgent-path exclusion — `/hotfix` and `/incident` skip Step 11b entirely to ship fast.

**Step-by-step:**

1. **Resolve the tool** (only reached after the unit-test gate passes) — branches:
   - User picked an explicit tool at confirmation (`Yes — Stryker.NET`, `Yes — Stryker.JS`, or `Yes — Stryker for Scala`) → use that tool, skip auto-detection.
   - Field was missing on a `before_pr` project with `mutation_testing.tool` set → use that pinned tool, skip auto-detection (per the exit-code handling above). If `tool` is omitted, fall through to auto-detection and surface the "no `tool` pinned — using auto-detection" note so the chosen runner is never silent in a multi-runner repo.
   - Field is `Yes — auto-detect tool at verification (recommended)`, OR field was missing and defaulted to it → run auto-detection (next step).
   - Field is `No` (explicit, or missing on a `manual` project, or missing on a `test_only_prs` project for a non-test-only ticket) → skip (already handled by the trigger; listed here for completeness).

2. **Auto-detect the tool** (only if not explicitly picked) — scan the repo from the working tree root:
   - `find . -maxdepth 4 -name '*.csproj' -not -path '*/node_modules/*'` returns any → candidate: `stryker.net`
   - `find . -maxdepth 4 -name 'package.json' -not -path '*/node_modules/*'` returns any AND the package.json has a test-runner devDep (`vitest`, `jest`, `mocha`, `jasmine`, `karma`, `cucumber`, `@stryker-mutator/tap-runner`) → candidate: `stryker.js`
   - `find . -maxdepth 4 -name 'build.sbt' -not -path '*/node_modules/*'` returns any AND a Scala source file exists nearby → candidate: `scala-sbt`
   - **One candidate** → use it.
   - **Multiple candidates** (mono-repo with mixed stacks) → AskUserQuestion to pick.
   - **No candidates** → tell the user: "Mutation testing was requested but no supported stack was detected. Skipping." Do NOT block the workflow.

3. **Resolve the working directory** — Stryker runs from the test project directory, not the repo root:
   - `stryker.net`: find a likely test project using a closed set of common test-project naming patterns (case-insensitive, all matched as `.csproj` filename suffixes): `*.Tests.csproj`, `*.Test.csproj`, `*IntegrationTests.csproj`, `*IntegrationTest.csproj`, `*UnitTests.csproj`, `*UnitTest.csproj`, `*FunctionalTests.csproj`, `*FunctionalTest.csproj`. This explicit list covers both plural and singular conventions (e.g. `Example.ApiTests.csproj`, `Foo.Test.csproj`, `Bar.IntegrationTests.csproj`) WITHOUT over-matching helper projects like `TestUtilities.csproj`, `Testing.Common.csproj`, `TestSupport.csproj`, or `MyTesting.csproj` (which contain "Test" or "Testing" in the name but are non-runnable support libraries, not test projects). One match → cd to its directory. Multiple → AskUserQuestion to pick. No matches → fall back to repo root and warn: "No likely test-project `.csproj` found (looked for `.Tests`, `.Test`, `IntegrationTests`, `UnitTests`, `FunctionalTests` suffixes); running Stryker from repo root. If this fails, point me at the test project explicitly." (PR #60 automated-review finding R4 — original `*Test*.csproj` glob was too broad.)
   - `stryker.js`: cd to the directory containing `package.json` (the closest one to repo root). For monorepos with multiple package.json, AskUserQuestion to pick.
   - `scala-sbt`: cd to the directory containing `build.sbt`. For monorepos with multiple SBT projects, AskUserQuestion to pick.

4. **Prepare config** (per tool):
   - `stryker.net`: NO config needed for most .NET Core projects. Stryker auto-detects the source project. Skip config generation.
   - `stryker.js`: requires `stryker.config.mjs` at the project root. Check if it exists. If NOT, generate a minimal config (see template below) and tell the user: "Generated minimal stryker.config.mjs at <path>. You can customise it later — Stryker will use it for now."
   - `scala-sbt`: use the existing Stryker4s configuration in `build.sbt`; do not rewrite the build file or generate a second config.

   **Minimal `stryker.config.mjs` template** (for stryker.js, when generating) — the agent MUST adapt `testRunner` and `packageManager` to the detected stack BEFORE writing the file. Reading `package.json` `devDependencies` (or `dependencies`):
   - `vitest` present → `testRunner: 'vitest'`
   - `jest` present → `testRunner: 'jest'`
   - `mocha` present → `testRunner: 'mocha'`
   - `jasmine` or `karma` or `cucumber` or `@stryker-mutator/tap-runner` present → use the matching runner name
   - None detected unambiguously → AskUserQuestion to pick rather than guess
   - For `packageManager`: `yarn.lock` present → `'yarn'`, `pnpm-lock.yaml` → `'pnpm'`, otherwise `'npm'`

   Template (with `<RUNNER>` and `<PKGMGR>` substituted before writing):
   ```javascript
   // @ts-check
   /** @type {import('@stryker-mutator/api/core').PartialStrykerOptions} */
   const config = {
     packageManager: '<PKGMGR>',
     reporters: ['html', 'json', 'progress'],
     testRunner: '<RUNNER>',
     coverageAnalysis: 'perTest',
     thresholds: { high: 80, low: 60, break: 0 }
   };
   export default config;
   ```

   If the user later wants a different runner (e.g. picked `vitest` but actually uses `jest`), they can edit `stryker.config.mjs` directly — the toolbox-generated file is a viable starting point, not a frozen artifact.

5. **Invoke the tool** via the registry in the `workflow-discipline` skill §1a:
   - cd to the resolved directory (from Step 3)
   - Run the `bootstrap:` commands from the registry (if any). The supported Stryker entries currently have empty bootstrap arrays: the verifier does not silently install tools or dependencies.
   - Run the `run:` command verbatim from the registry. Do NOT interpolate any PROJECT.md fields into the command (the registry exists precisely so the agent never executes shell strings that came from PR-editable files).
   - Stream stdout/stderr so the user can watch progress.

6. **Parse the output — Stryker schema:** read the structured JSON report produced by the resolved Stryker runner:

   - **`stryker.net` / `stryker.js`** — read `mutation-report.json` from the most-recent surviving candidate (per the failure-mode discovery flow). Schema:
     - Mutation score: top-level `.score` if present (Stryker.JS exposes this directly). Otherwise compute from `killed / (killed + survived + timedOut + noCoverage)` (Stryker.NET). The `noCoverage` count is included in the denominator so uncovered mutants don't inflate the score — a mutant with no test coverage is a real gap, not an irrelevant entry. Express as a percentage rounded to 1 decimal place.
     - Surviving mutants: filter `.files[].mutants[]` where `.status == "Survived"`. Group by file + line.
   - **`scala-sbt` / Stryker4s** — use the JSON reporter configured by the Stryker4s project (normally `mutation-report.json` or the configured `reports` path). Accept its documented `mutationScore`/`score` metric and mutant entries, normalize `Survived`/`Killed` status names, and never parse a .NET/JS-only `.files[].mutants[]` shape as Scala evidence. If the configured Stryker4s reporter is absent or malformed, report `FAIL` with the runner output.
   - **All supported Stryker runners:** Express the final score as a percentage rounded to 1 decimal. Surviving mutants are reported as `<file>:<line>` in the phase summary, using the runner-specific schema above.
   - **Schema mismatch fallback:** if the resolved tool's expected schema doesn't match the found report (e.g. configured tool is `stryker.js` but the surviving candidate is a `mutations.xml`), surface a SECURITY finding: "Mutation report `<path>` doesn't match the expected schema for tool `<tool>`. A malicious branch may have planted a forged report from a different tool. Skipping parse." Then skip score extraction.
   - Counts: killed / survived / timedOut / no-coverage / error.

7. **Report in the phase summary card** — append to the Verification card a section like:

   ```
   Mutation testing: <tool> ran on <test-project-dir>
   - Score: 78.4% (above the high-water mark of 80? No, below — see surviving mutants)
   - Killed: 145 / Survived: 38 / TimedOut: 2 / No coverage: 5 / Error: 0
   - HTML report: <output-dir>/mutation-report.html (gitignored; open locally to inspect)
   - Surviving mutants requiring attention: 38 — see below
   ```

8. **Apply the production code boundary** — per `rules/testing.md`:
   - Surviving mutants that can be killed by adding/strengthening TEST code → propose those as follow-ups (or, if `test_only_prs` was specified, propose them as the next ticket's scope).
   - Surviving mutants that can ONLY be killed by changing PRODUCTION code (reordering logic, adding guards, modifying behaviour) → **DO NOT change production code**. Document each as a finding with file:line and the mutant operator. These become follow-up tickets or "known mutation gaps".
   - This boundary is the lesson from TASK-760 — the agent must not silently edit production code to game mutation scores.

9. **Move on** — mutation testing does NOT block the PR. A low score or surviving mutants are FINDINGS, not blockers. The user decides whether to address them now or file follow-ups. Continue to Step 12 (Reality Checker).

**Failure modes (handled gracefully):**

The detailed discovery record below preserves historical Automated review findings for
auditability. Its older non-Stryker examples are archival only; the canonical
runtime registry above supports Stryker.NET, Stryker.JS, and Stryker4s.

| What goes wrong | Response |
|---|---|
| Stryker.NET fails because no `*Tests*.csproj` found | Warn, offer "pick a directory manually", or skip with a finding "Stryker.NET requires a test project. Add one or set up `dotnet stryker` config manually." |
| Stryker.JS fails because no test runner is configured | Surface the error message + a link to https://stryker-mutator.io/docs/stryker-js/configuration/ . Skip without blocking. |
| Tool registry's run command exits non-zero for unrelated reasons (network, disk full) | Surface stdout/stderr. Record mutation evidence as `UNAVAILABLE`/`FAIL` according to the registry policy; do not claim a score. The ordinary test gates may still pass when mutation testing is advisory. |
| `mutation-report.json` not found after the run | The selected Stryker runner must produce a fresh structured JSON report under its registered output directory. A missing or malformed report is `FAIL`, never a passing score; bind the evidence to the observed HEAD/worktree and surface the runner output so the user can fix configuration or install the local runner. |

**Cost note:** Stryker can take **minutes to hours** depending on suite size + project size. Surface this in the phase summary card BEFORE running so the user knows what they signed up for: "Mutation testing — this can take a while. Estimated based on test suite size: ~X minutes." If the suite is huge (>1000 tests), warn even more strongly and offer "skip this time" as an option.


---

## 1c. Verification command registry — the machine-readable definition of done

`examples/PROJECT.md.example` carries an optional `verification:` block. That block holds
**keys and non-executable data only**. This section is where the literal commands live, and
it exists for exactly one reason: a command STRING in `PROJECT.md` would be an unreviewed
code-execution path into the agent's environment. This file sits one trust level above
`PROJECT.md` — it changes only through the toolbox's own review and human-gated merge.

**Be precise about WHY `PROJECT.md` is the lower trust level**, because the usual shorthand
for it — "`PROJECT.md` is PR-editable" — is not actually true of the default setup, and
repeating a wrong reason invites someone to "correct" it by relaxing the rule. `/init`
gitignores `.claude/`, so `PROJECT.md` is normally **untracked and local** (see the key-files
table in `CLAUDE.md`). That makes the trust argument *stronger*, not weaker, and it holds in
both directions:

- **Untracked (the default)** — the file is reviewed by nobody, ever. Anything that can write
  to the working tree can put a command there: a tool, an agent, a script, a stale `/init`
  answer. There is no diff for a human to catch it in.
- **Tracked (some teams commit it deliberately)** — the file is editable by any contributor
  through a PR, and a command string is then reviewed only as attentively as any other line
  in a config diff.

Neither case gives a command string in `PROJECT.md` the review a code-execution path needs, so
the keys-only boundary is right either way. The "PR-editable" phrasing appears in several other
files as shorthand for the tracked case; read it as "outside the toolbox's trust boundary",
which is the property that matters.

Same boundary, same rationale, and the same enforcement shape as the mutation-testing
registry in §1a. `knowledge/toolbox-lessons.yml` TL-0005 states the general rule the design
follows: **select a command by detecting which manifest FILE EXISTS, then run a fixed command
for that ecosystem — the file's presence is the signal, its contents are never a command.**
`agents/tdd-guide.md` carries the same prohibition inline because that file is a live
execution prompt; `docs/how-to/testing.md` records the rejected design. Automated review first caught
this attack path on PR #58.

### What lives where

| Thing | Home | Why there |
|---|---|---|
| `runner`, `gates`, `coverage_floor`, `test_globs` | `.claude/PROJECT.md` | Per-project data. Keys and numbers, never shell. |
| The literal `test` / `lint` / `build` command strings | This section | One trust level above a PR-editable file. |
| Ecosystem detection order | This section | Detection reads file EXISTENCE only. |
| The `coverage_floor` lower bound (80) | `rules/testing.md` (always loaded) | A toolbox-wide guarantee, so a project must not be able to lower it. |
| Loop budget ceilings | §1d below | Behaviour-critical safety knobs; see §1d for the precedent. |

### Command registry (canonical)

Every string below is a fixed literal. The agent runs it verbatim from the validated working
directory. **Nothing from `PROJECT.md` is ever appended to, substituted into, or formatted
against these strings** — same no-interpolation rule as §1a.

**What this boundary does NOT buy — honest scope.** Every command below executes the project's
own build logic: `./mvnw` and `./gradlew` are repo-committed scripts, `mvn`/`gradle` run
`pom.xml`/`build.gradle` plugins, `npm test` runs `scripts.test`, `pytest` imports
`conftest.py`, `dotnet` runs MSBuild targets. Running a gate on an untrusted branch therefore
runs attacker-controlled code — the same property §1a records for mutation testing. What the
registry protects is **which command is selected**: that choice is made here, one trust level
above `PROJECT.md`, so a lower-trust file cannot redirect the agent to a command of its
choosing. It does not, and cannot, make the selected command's execution safe. This applies
with full force to the `/goal` consumer below, which runs these gates unattended in a loop.

```yaml
verification_registry:
  # `detect:` lists MANIFEST FILENAMES. The agent checks whether the file
  # EXISTS. It never opens the file to decide what to run — see TL-0005.
  # Order below IS the auto-detection precedence (first match wins).

  dotnet:
    detect: ["*.sln", "*.csproj"]
    test: "dotnet test"
    lint: "dotnet format --verify-no-changes"
    build: "dotnet build"

  # Wrapper-first, then bare tool. A committed wrapper pins the build-tool
  # version; the system `mvn`/`gradle` can silently build against a different
  # toolchain. The wrapper is chosen because the FILE is present — and the
  # wrapper script itself is project-controlled code. That is inside the
  # accepted scope stated above the fence (`mvn test` against a
  # project-controlled `pom.xml` is equally arbitrary), not an exception to it.
  maven-wrapper:
    detect: ["mvnw"]
    test: "./mvnw test"
    build: "./mvnw -DskipTests package"
    # NOTE: no `lint:` key — deliberate. There is no single Maven lint goal
    # that is correct across projects (checkstyle/spotless/pmd are all
    # opt-in plugins). An entry without a key is UNAVAILABLE for that gate,
    # never silently passed. Same fail-closed shape as an unsupported runner's missing
    # `run:` key in §1a.

  maven:
    detect: ["pom.xml"]
    test: "mvn test"
    build: "mvn -DskipTests package"

  gradle-wrapper:
    detect: ["gradlew"]
    test: "./gradlew test"
    build: "./gradlew assemble"

  gradle:
    detect: ["build.gradle", "build.gradle.kts"]
    test: "gradle test"
    build: "gradle assemble"

  # Lockfile before package.json: a repo with pnpm-lock.yaml AND package.json
  # must use pnpm, and package.json alone is the npm fallback.
  node-pnpm:
    detect: ["pnpm-lock.yaml"]
    test: "pnpm test"
    lint: "pnpm run lint"
    build: "pnpm run build"

  node-yarn:
    detect: ["yarn.lock"]
    test: "yarn test"
    lint: "yarn run lint"
    build: "yarn run build"

  node-npm:
    detect: ["package.json"]
    test: "npm test"
    lint: "npm run lint"
    build: "npm run build"

  python:
    detect: ["pyproject.toml"]
    test: "pytest"
    lint: "ruff check ."
    # NOTE: no `build:` key — deliberate. A Python library or app commonly has
    # no build step at all, and `python -m build` is wrong for the majority.
    # UNAVAILABLE, not passed.
```

**A missing script is UNAVAILABLE, not a failure.** The Node entries run the fixed
`<pm> run lint` / `<pm> run build` strings without first checking whether the project defines
those scripts — checking would mean opening `package.json` to reason about its contents, which
is the seam this design closes. So when the package manager reports the script is missing, the
agent records that gate as **unavailable** and moves on. Only a script that EXISTS and exits
non-zero is a gate failure. Without this rule the agent would report a red build on every
repo that simply has no lint script.

### How the agent uses the block

1. **Resolve the runner.**
   - `runner: auto` (the default, and the behaviour when the block is absent entirely) →
     walk the registry in the order above and take the first key whose `detect:` list has a
     file present at the project root. The order is most-specific-signal-first (wrappers
     before bare tools, lockfiles before `package.json`), which is a heuristic, not a
     truth: a POLYGLOT root — say `pyproject.toml` beside a tooling-only `package.json`
     — resolves to whichever key comes first and may well be the wrong one. Detection is
     also root-only. Either case (polyglot root, or manifests down in sub-packages) is
     exactly what an explicit `runner:` is for; pin it, or run the gates per package.
   - An explicit `runner:` value → must be a registry key exactly.
   - **Unknown key fails CLOSED.** The agent runs nothing and reports: "`verification.runner`
     is `<value>`, which is not in the toolbox verification registry. Run the gates yourself,
     or open a toolbox PR to add the entry (`workflow-discipline` skill §1c)." Same policy as
     an unsupported `tool:` in §1a.
   - **No match under `auto` also fails closed** — the agent asks which gates to run rather
     than guessing a command.
2. **Resolve the gate list.** `gates:` may contain only `test`, `lint`, `build`. Any other
   value fails closed for that entry (the named gate is refused; the recognised ones still
   run) and is surfaced to the user. An absent `gates:` key means "every gate the resolved
   runner has a command for".
3. **Run each gate's literal string** from the project root. Report per gate: passed, failed,
   or unavailable.
4. **Apply the coverage floor.** `coverage_floor` is an integer compared against whatever
   coverage figure the runner already reports. **It is never turned into a command-line flag,
   never interpolated, and never used to pick a command.** The effective floor is
   `max(80, coverage_floor)` — see the clamp below. **A runner that reports no coverage figure
   makes the floor UNAVAILABLE — exactly like a gate the registry has no command for.** Every
   registry `test` string is bare, so a figure appears only when the project itself wired
   coverage into its own test script or config; adding a coverage flag to the command is
   forbidden by the no-interpolation rule above. UNAVAILABLE is never silently treated as met:
   the agent reports the floor **by name** as "coverage floor <N>% — UNAVAILABLE,
   `<resolved test command>` reports no coverage figure", and the human at the phase gate
   decides. A figure that IS reported and is below the effective floor is a failure, not an
   unavailable.
5. **Use `test_globs` for matching only.** They are path patterns matched against the set of
   changed files to decide whether a PR is test-only (`rules/workflow-discipline.md` Rule 6).
   They are never executed, never passed to a shell, and never expanded by a shell. When the
   key is absent the agent falls back to its own judgement of which paths are tests.
   - **NARROW-ONLY CLAMP.** These patterns may NAME unusual test paths; they may never make
     Rule 6 vacuous. Rule 6 is a toolbox-wide guarantee (test-only PR ⇒ no production code
     touched), and `test_globs` is its only project-supplied input: a single line reading
     `- "**/*"` would classify every changed file as a test and empty the boundary at all
     three enforcement points, with nothing in the diff that looks like a policy change.
     Same reasoning as the raise-only `coverage_floor` clamp — a file outside the toolbox
     trust boundary must not be able to retire a toolbox-wide guarantee. So **before
     matching, DISCARD** any pattern that:
     - **contains `[` or `]`.** Character-class syntax is NOT honoured, and this clause is
       applied **before** the boundary test below, because a character class hides its own
       match from that test: `[test]` reads to the boundary test as the keyword `test`
       wrapped in two delimiters, but as a GLOB it matches exactly ONE character — `t`, `e`
       or `s` — so `src/[test]/**` would clear the boundary test and then accept the
       production path `src/t/**`. `src/[s]pec/**` is the same trick spelled differently.
       Rejected for the same reason as brace alternation below: the construct smuggles in a
       match the literal test cannot see; or
     - **contains `{` or `}`.** Brace alternation is NOT honoured, because it smuggles a
       production path in beside a test one: `{tests,src}/**` clears the boundary test on
       its `tests` occurrence, yet as a glob it widens to `src`; or
     - **contains `(`, `)` or `|`, or begins with `!`.** Extglob alternation/repetition and
       pattern negation are NOT honoured, for exactly the reason the two clauses above
       exist — the construct hides its own match from the literal test. Measured under
       `bash -O extglob`: `!(tests)/**` expands to `app src`, i.e. every top-level entry
       EXCEPT tests, and `@(tests|src)/**` expands to `src tests` — that second one is
       `{tests,src}/**` spelled with different punctuation, so excluding braces while
       admitting `@(…)` would be an arbitrary distinction. `+(test)/**`, `*(spec)/**` and
       `?(test)/**` are the same family (`*(…)` can even match zero-width). A LEADING `!`
       is pattern negation in minimatch and gitignore syntax, so `!tests/**` means "every
       path that is NOT under tests" and `!**/*.Tests.cs` inverts the same way.
       ⛔ This is the clause most likely to fire by ACCIDENT rather than by attack: a Node
       developer writing `!tests/**` means "exclude tests" and would silently get the whole
       production tree classified as tests. It is also the one that FAILS OPEN if omitted —
       `(`, `)`, `|` and `!` are all non-alphanumeric, so under the negative delimiter
       definition in step 3 they all *clear* the boundary rather than being caught by it; or
     - **contains `..`**, which lets a test-named prefix reach back out into production code
       (`tests/../src/**`); or
     - **names no test path SEGMENT.** This is a SEGMENT test, never a substring test —
       a keyword buried inside an ordinary production word does not count. Apply it
       mechanically, so every agent reaches the same verdict on the same pattern:
       1. Lower-case the whole pattern.
       2. Find every occurrence of every one of these seven literals: `test`, `tests`,
          `spec`, `specs`, `e2e`, `fixture`, `fixtures`.
       3. An occurrence **clears the boundary** only when BOTH sides are delimiters, and
          the SAME definition of delimiter applies to both sides. A side is a delimiter if
          the occurrence starts the pattern (left) or ends it (right), or if the single
          character on that side is one of exactly these five: `/` `.` `_` `-` `,`.
          **Nothing else delimits.** Any other character — an ASCII letter or digit, a
          Unicode letter, `*`, `?`, or any punctuation not in that list — is
          NON-delimiting, so an occurrence touching it does not clear.
       3z. **⛔ THE LIST IS CLOSED, AND THAT IS THE POINT — IT USED TO BE OPEN ⛔** This
          was a NEGATIVE definition ("anything that is not an ASCII letter or digit
          delimits"), with the five characters given as illustrations. A negative
          definition over an open character set cannot be audited, and it leaked twice
          before this was flipped:
          - `(`, `)`, `|` and `!` are not ASCII alphanumerics, so they DELIMITED — which
            is how extglob and pattern negation cleared the boundary until the clause
            above began rejecting them outright.
          - A UNICODE letter is not an ASCII letter either, so it delimited too:
            `caféspec/**` cleared on its `spec` (preceded by `é`) and `Ωtest/**` cleared
            on its `test`, both ordinary production names. Verified by executing the rule
            as written.
          Both are the same defect — an open-ended "not X" over a character set nobody can
          enumerate. A closed allowlist is auditable: to widen it you must name the
          character and say why, and anything nobody thought of fails CLOSED instead of
          clearing. Do not turn this back into a "not …" definition, and do not add a
          character to the list without checking it against the accept table above.
       3a. **⛔ WHY A WILDCARD NEVER DELIMITS — ON EITHER SIDE ⛔** — `*` and `?` absorb
          arbitrary characters, letters included, and that is precisely what defeats a
          delimiter test. Whichever side it sits on, a wildcard turns the keyword back into
          a substring match one layer down and launders in exactly what step 3 exists to
          reject — the production trees the seven literals were written to exclude:
          - **Trailing:** `**/*test*/**` clears a naive both-sides test (its neighbours are
            both `*`), but as a GLOB it matches `src/latest/`, `src/contest/` and
            `app/attestation/`. `*spec*`, `**/*Tests*/**` and `prod/**/*.spec*/**` launder
            the same way.
          - **Leading — and this is the case an earlier version of this rule got wrong:**
            `*test/**` matches `latest/`, `**/*test/**` matches `src/contest/`,
            `**/*Tests/**` matches `src/LatestTests/`, and `**/*Tests.cs` matches
            `src/LatestTests.cs`. That earlier version asserted a leading wildcard was safe
            "because the keyword still has to appear anchored to whatever follows it".
            **That claim is false.** Anchoring the RIGHT side constrains nothing on the
            left, and the left wildcard is free to swallow `la`, `con` or `at`, which is
            the whole laundering move. Automated review filed it as CRITICAL on the third review
            round of this one rule; the asymmetry it was defending is gone.

          Note `*_test_*` still clears, correctly: its delimiters are the two literal `_`
          characters, not the wildcards beyond them, so the pattern demands a literal
          `_test_` somewhere in the path — which `latest` and `contest` do not contain.
       4. **KEEP** the pattern if at least one occurrence of at least one literal clears
          the boundary on both sides. **DISCARD** it if none does.

       Accept — each of these has one occurrence that clears both sides:

       | Pattern | Why it clears |
       |---|---|
       | `tests/**`, `test/**` | starts the pattern; `/` follows |
       | `spec/**`, `specs/**`, `e2e/**`, `fixture/**`, `fixtures/**` | starts the pattern; `/` follows |
       | `__tests__/**` | `_` before, `_` after |
       | `**/Tests/**` | lower-cases to `tests`; `/` before, `/` after |
       | `Tests/Unit/**` | starts the pattern; `/` follows |
       | `src/**/*.test.ts` | `.` before, `.` after |
       | `**/*.spec.tsx` | `.` before, `.` after |
       | `*.test.*` | `.` before, `.` after |
       | `**/*.Tests/**` | `.` before, `/` after — the .NET `Foo.Tests` project-directory shape |
       | `**/*.Tests.cs` | `.` before, `.` after |
       | `**/*_test.py` | `_` before, `.` after |

       Reject — no occurrence clears both sides (or a syntax clause fired first), so each
       of these is discarded. The first block is the wildcard-laundering shape, the second
       is character classes, and the third is pure production paths a plain substring check
       would have let through as "test" paths:

       | Pattern | Why it fails |
       |---|---|
       | `*test/**`, `**/*test/**`, `*test/` | `*` immediately before `test` — no delimiter; as a glob these match `latest/` |
       | `**/*Tests/**` | `*` immediately before `tests`; as a glob it matches `src/LatestTests/` |
       | `**/*Tests.cs` | `*` immediately before `tests`; as a glob it matches `src/LatestTests.cs` |
       | `**/*test*/**`, `*spec*` | wildcard on both sides |
       | `src/[test]/**`, `src/[s]pec/**` | character class — discarded by the `[`/`]` clause before the boundary test runs |
       | `latest/**`, `src/latest/**` | `test` has `a` before it |
       | `contest/**` | `test` has `n` before it |
       | `attestation/**` | `test` has `t` before and `a` after |
       | `src/inspector/**` | `spec` has `n` before it |
       | `app/Specifications/**` | `spec` clears the left side (`/`) but has `i` after it |
       | `src/respec/**` | `spec` has `e` before it |

       The catch-alls `*`, `**`, `**/*`, `/**` and `**/*.*` contain no literal at all, so
       this clause discards them too; they are called out because they are the obvious
       shape of the attack.
   - **Two classes of legitimate test path are discarded, and both costs are real.**
     - *Names none of the seven literals.* `unit/**`, `testing/**`, `TestUtils/**` and
       Perl's `t/**` all fail the segment test. The only loosening that would admit
       `testing/**` or `TestUtils/**` is letting a letter or digit FOLLOW the keyword — and
       that same loosening re-admits `app/Specifications/**` from the reject table above,
       along with shapes like `TESTAMENT/**` that the table does not list: a production tree
       reclassified as tests, which is the bypass this clamp exists to close. (`unit/**` and
       `t/**` contain none of the seven literals at all, so no boundary wording admits
       them.)
     - *Uses the `*Tests` suffix convention.* `**/*Tests.cs` and `**/*Tests/**` are genuinely
       common in .NET, and both are now discarded. State it plainly rather than burying it:
       this is a widely-used convention, and an earlier version of this rule accepted it.
       It cannot be kept, because it is the SAME SHAPE as the laundering it enables — a
       wildcard sitting directly against the keyword. `**/*Tests.cs` matches
       `src/LatestTests.cs`; `**/*Tests/**` matches `src/LatestTests/`. Any wording that admits
       the convention admits the bypass with it. The surviving forms are directory-level —
       `**/*.Tests/**` (a `Foo.Tests` project directory) and `**/Tests/**` (a directory
       named exactly `Tests`) — plus `**/*.Tests.cs` for a file whose name carries a literal
       `.Tests.`. That last one does NOT cover `CustomerServiceTests.cs`, and no surviving
       file-level form does; in the standard .NET layout that file sits inside a test
       project directory, so a directory-level glob covers it instead.
     Neither cost is paid in silence. Both are handled by the reporting path below, so the
     user learns the pattern was not applied and can switch to a surviving form, rename the
     directory to a `tests` / `spec` / `e2e` / `fixture` segment, or leave it and accept the
     fallback.
   - **Report each discarded pattern by name** — one line per pattern, quoting the pattern
     as written and naming which of the five clauses discarded it — and fall back to the
     agent's own test-path judgement for the files it would have covered. A silent drop is
     not acceptable: a pattern that was configured and then ignored has to be visible at
     the phase gate. A wrongly-discarded pattern therefore costs extra scrutiny, never a
     missed production-code change — fail-closed, the same direction as an UNAVAILABLE
     gate. As with the other clamps, the pattern stays in the file and is ignored at
     runtime rather than failing the run.

### The registry's second consumer — `/goal` phase exits

`/flow` Steps 8a and 11a turn a resolved gate set into a `/goal` condition — a session-scoped
exit condition evaluated after every turn so the fix-and-re-run cycle inside those two phases
does not need a human watching it. That consumer sharpens two things about this section.

**It raises the stakes on the trust boundary rather than changing it.** The `/goal` evaluator
has no tools; it judges only what the agent printed. So the condition must name literal
command strings and literal exit codes to be checkable at all. Those strings come from the
table above — never from `PROJECT.md` — because a condition assembled from a PR-editable file
would let a project rewrite what the agent runs unattended, in a loop, with nobody reading.
Same rule as always, with a larger blast radius if it were broken.

**UNAVAILABLE has to survive into the condition.** A gate the resolved runner has no command
for is unavailable, and the condition must say so **by name**. Otherwise a met verdict can
quietly mean "two of the three gates passed and the third was forgotten" — the exact
fail-open this section's missing-key rule exists to prevent, re-introduced one level up.

The condition templates, the worked examples, and the one-goal-per-session and
`/goal`-unavailable rules live in `commands/flow.md` → "`/goal` — Machine-Checkable Phase
Exits". This section stays the only home of the command strings.

### The three clamps

| Field | Clamp | Why the clamp exists |
|---|---|---|
| `verification.coverage_floor` | **Raise-only** — effective value is `max(80, project)` | The 80% minimum is asserted in the always-loaded `rules/testing.md` and mirrored for the in-editor advisor. A project PR that set `coverage_floor: 10` would otherwise silently retire a toolbox-wide guarantee, and nothing in the diff would look like a policy change. A project may hold itself to a HIGHER bar. |
| `verification.test_globs` | **Narrow-only** — an over-broad pattern is discarded before matching (step 5 above) | Same shape again, on a pattern instead of a number: `test_globs` is the only project-supplied input to Rule 6's test-only boundary, so `- "**/*"` would classify every changed file as a test and empty that boundary at all three enforcement points. A project may NAME unusual test paths; it can never make Rule 6 vacuous. |
| `loop.max_turns`, `loop.no_progress_after`, `loop.max_spend_usd` | **Tighten-only** — effective value is `min(project, ceiling)` (§1d) | Same shape, opposite direction: these bound autonomous behaviour and spend. A project may make a loop more cautious; it must not be able to buy itself more turns or more money by editing a file every contributor can edit. |

A value on the wrong side of its clamp is **not an error** — the file keeps it and the runtime
ignores it. Failing the run instead would let one bad line in `PROJECT.md` block every
workflow, and the clamp already guarantees the safe outcome.

### Why there is deliberately no `smoke_command`

A smoke check is inherently project-specific — start this service, hit this endpoint, expect
this string. That makes it:

- **not registrable** — there is no generic string to put in the table above, so it cannot
  live at this trust level; and
- **not a `PROJECT.md` field** — a command string there is exactly the forbidden shape.

So the toolbox registers no smoke gate at all, and `verification.gates` cannot name one
(`test | lint | build` is the closed set). The registry contains no generic smoke runner,
so the agent refuses to invoke a project-supplied smoke command autonomously. **A project
that needs a smoke check runs it manually and tells the agent the result.** That is a
deliberate capability gap, not an oversight — treat a request to "just let PROJECT.md hold
the smoke command" as the attack path TL-0005 describes.

---

## 1d. Loop budget ceilings (toolbox-owned)

An optional `loop:` block in `PROJECT.md` bounds one self-paced `/loop` run (the loop body
itself is `examples/loop.md.example`). The block holds **numbers only** — never a command,
never a value interpolated into one. The ceilings below are toolbox-owned and are **not
settable from `PROJECT.md`**.

**Why the ceilings live here.** `rules/performance.md` keeps model and effort out of
`PROJECT.md` for the same reason — a behaviour-critical knob must not be raisable by a file
that any contributor can change through a project PR. Turn count, idle tolerance and spend cap
bound how long an agent runs unattended and how much it costs; a PR that raised them would be
buying autonomy and money without a toolbox review.

| Field | Toolbox default (no block) | Toolbox ceiling | What it bounds |
|---|---|---|---|
| `max_turns` | 25 | **60** | Iterations in one loop run. Maps to the native `CLAUDE_CODE_MAX_TURNS`. |
| `no_progress_after` | 2 | **5** | Consecutive iterations that changed nothing before the loop stops and escalates. |
| `max_spend_usd` | 2.00 | **10.00** | Spend for one loop run. Maps to the native `--max-budget-usd`. |

Effective value is `min(project, ceiling)`; a project value above the ceiling is ignored, not
rejected. A project value of zero or a negative number is treated as **absent** (the default
applies) rather than as "never run" — a typo should not silently disable the loop.

**These numbers also bound a `/goal` phase exit — and there they are the ONLY bound.**
`/flow` Steps 8a and 11a write the clamped `max_turns` and `no_progress_after` into the
`/goal` condition text ("…or stop after 25 turns", "…if the same failure survives 2
consecutive iterations"). That is not decoration: `/goal` carries **no turn cap of its own**,
so a condition without those clauses is an unbounded loop.

Be precise about `max_spend_usd` in that setting. It reaches a run through the native
`--max-budget-usd`, which is set when the run was **launched as a loop**. A `/goal` set inside
an interactive `/flow` session has no such flag, so the two clauses above are the whole budget
of an interactive goal loop. Do not describe the spend cap as covering it.

**Both limits are enforced by the native primitives, not by toolbox accounting.** The toolbox
adds no turn counter and no spend ledger of its own; it passes the clamped numbers to
`CLAUDE_CODE_MAX_TURNS` and `--max-budget-usd` and lets the harness enforce them. A
toolbox-side counter would be a second source of truth that drifts.

### The three ceilings' other consumers

The numbers above are read in three more places, and two of them are mechanical:

- **`hooks/enforce-loop-bounds.sh`** copies `max_turns` (60) and `no_progress_after` (5) as
  literals and rejects a `/goal` condition or a recurring `CronCreate` that exceeds them.
  `scripts/verify-hooks.sh` TC-ELB-21/22 cross-check those literals against the table above, so
  a drift in either direction fails the build rather than quietly widening a bound.
- **`scripts/loop-progress-signature.sh`** copies `no_progress_after` (5) as its threshold
  ceiling and clamps a larger caller value down to it — defence in depth, because it is the
  thing that actually decides to stop. `scripts/test-loop-progress-signature.sh` TC-LPS-16
  cross-checks that literal too.
- **The `loop-design` skill** is the doctrine these two enforce: the five components a loop
  needs, the verification ladder, the three guards, and the when-NOT-to-loop list. Load it
  before creating a loop or raising a bound; this section stays the only home of the numbers.

**Note the asymmetry with the clamp above.** A `PROJECT.md` value on the wrong side of its
clamp is kept and ignored, because the clamp sits behind it. The number written into a `/goal`
condition IS the bound — nothing sits behind it — so `enforce-loop-bounds.sh` rejects an
out-of-range value there rather than silently clamping it.

---

## 2. Gitignore pre-check (Rule 5 detail)

**Before creating any branch, running `bd init`, or making the first commit in any project repo**, verify toolbox files are not tracked by git. Protected patterns: `.beads/`, `AGENTS.md`, `CLAUDE.md`, `.claude/`, `ai-engineering/`.

**This is the canonical pre-check script** — `rules/agents.md` (Beads Continuity) points here for it, so a script fix only needs to land in one place. Run it exactly as written:

```bash
# 1. Verify gitignore covers toolbox files.
#
# The append is done with O_NOFOLLOW|O_APPEND in ONE syscall, not shell `>>`.
# WHY: a shell `[ -L .gitignore ]` guard followed by `echo >> .gitignore` is a
# TOCTOU race — on an untrusted branch .gitignore can be swapped for a symlink
# between the check and the write, and `>>` follows it, appending toolbox
# patterns into an arbitrary host file. O_NOFOLLOW makes the kernel refuse at
# open() time, so there is no window to race (automated-review PR #132, two rounds:
# the first fix added the guard, this one closed the race the guard left open).
python3 - <<'GITIGNORE_EOF'
import os, stat, sys

PATTERNS = ['.beads/', 'AGENTS.md', 'CLAUDE.md', '.claude/', 'ai-engineering/']
def open_guarded(extra_flags, mode=0o644):
    """Open .gitignore, refusing symlinks and any non-regular file, without hanging.

    O_NOFOLLOW rejects symlinks at open(). O_NONBLOCK stops a FIFO from blocking
    the open forever (a reader-side FIFO open with no writer would otherwise hang
    here — which is exactly what happened before this guard covered the READ path
    too, not just the write). fstat is done on the RETURNED DESCRIPTOR, never a
    second stat of the path, so there is no window to swap the file underneath us.
    """
    flags = extra_flags | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0)
    fd = os.open('.gitignore', flags, mode)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        sys.exit("BLOCKED: .gitignore is not a regular file (symlink, FIFO, device, "
                 "or directory) — refusing to touch it. Inspect it before continuing.")
    return fd

try:
    rfd = open_guarded(os.O_RDONLY)
except FileNotFoundError:
    existing = ''
except OSError as e:
    sys.exit(f"BLOCKED: cannot read .gitignore ({e}). It may be a symlink, a FIFO, "
             "or another special file — inspect it before continuing.")
else:
    with os.fdopen(rfd, 'r') as fh:
        existing = fh.read()

missing = [p for p in PATTERNS if p not in existing]
if not missing:
    sys.exit(0)

# O_NOFOLLOW blocks symlinks but NOT other non-regular files: a FIFO would make
# open() hang forever, and a device node would happily accept the write. So also
# add O_NONBLOCK (a writer-side FIFO open with no reader then fails ENXIO instead
# of hanging) and fstat the OPENED DESCRIPTOR. fstat on the fd — never a second
# stat on the path — because re-stating the path is exactly the TOCTOU this
# rewrite exists to remove (automated-review PR #132, rounds 2 and 3).
try:
    fd = open_guarded(os.O_WRONLY | os.O_APPEND | os.O_CREAT)
except OSError as e:
    sys.exit(f"BLOCKED: refusing to append to .gitignore ({e}). It may be a symlink, "
             "a FIFO, or another special file — inspect it before continuing.")

with os.fdopen(fd, 'a') as fh:
    if existing and not existing.endswith('\n'):
        fh.write('\n')
    for p in missing:
        print(f"{p} missing from .gitignore — adding it")
        fh.write(p + '\n')
GITIGNORE_EOF
if [ $? -ne 0 ]; then exit 1; fi

# 2. Verify none of these are already tracked by git
TRACKED=$(git ls-files .beads/ AGENTS.md CLAUDE.md .claude/ ai-engineering/ 2>/dev/null)
if [[ -n "$TRACKED" ]]; then
  echo "BLOCKED: These toolbox files are already tracked by git:"
  echo "$TRACKED"
  echo "Run: git rm --cached -r <files> before proceeding"
  exit 1  # Do NOT proceed — bd init would make the leak worse
fi

# 3. Pre-check passed — safe to run bd init
bd init
```

The gitignore alone is not enough if files were tracked before the entry was added — `git rm --cached` is required. Always run both checks.

| Command | When the check runs |
|---|---|
| `/start` / `/flow` | Step 0 — before creating the feature branch |
| `/bug` / `/hotfix` / `/incident` / `/refactor` / `/security` / `/perf` / `/build` | Step 0 — pre-flight |
| `/init` | During project setup (already present) |

**Incident history:** PR #100 and PR #104 (e2e-tests) had `.beads/`, `AGENTS.md`, `CLAUDE.md` in the diff because `bd init` ran before gitignore entries took effect and `git rm --cached` was not run.

---

## 3. Toolbox install/update gating (Rule 8 detail)

Applies when the user asks the agent to install or update the **ai-engineering toolbox itself** — `scripts/install.sh` (install) or `scripts/update.sh` (upstream-pull). NOT about `/init`, which configures a project and never installs the toolbox.

**Scope split:** `update.sh` only pulls upstream changes into a branch for review — no Codex logic, never honours `INSTALL_CODEX`. So **8a (Codex gating) applies to `install.sh` only**; **8b (docs verification) applies to both**.

### 8a — Always ask before the agent runs the installer (`install.sh` only)

The Codex opt-in question inside `install.sh` is printed only on an **interactive terminal** (`elif [ -t 0 ]`). When the agent runs the installer non-interactively (Claude Desktop, CLI agent, CI), that branch is skipped and Codex is silently left as-is — the user never gets to choose. Codex is the only opt-in component; everything else installs unconditionally.

So the agent MUST NOT run `install.sh` directly. It FIRST asks via **AskUserQuestion**, offering exactly:

1. **"I'll run it myself in my terminal"** — agent prints `bash scripts/install.sh` and does NOT run it. The user gets the native interactive Codex `[y/N]` prompt.
2. **"Agent installs WITH Codex"** — agent runs `INSTALL_CODEX=1 bash scripts/install.sh`.
3. **"Agent installs WITHOUT Codex"** — agent runs `INSTALL_CODEX=0 bash scripts/install.sh`.

The agent never silently picks. `INSTALL_CODEX=1`/`0` are the only ways to set Codex on the non-interactive path; a bare agent-run install leaves Codex unchanged and does NOT count as asking.

**Why:** a shell `read` prompt cannot appear when the agent runs the installer (no TTY), so the choice must be surfaced in chat *before* the run. Incident: the user installed from Claude Desktop, saw no Codex question, and reasonably asked whether the agent had silently installed Codex. It hadn't — but the silence was the problem.

### 8b — Verify documentation is current (both scripts)

Applies only when the AGENT runs install/update (8a paths 2/3, and any agent-run `update.sh`). On 8a path 1 (user runs it themselves) the agent has no access to the output, so it does NOT claim to have verified — it tells the user: "`install.sh` runs `verify.sh` Part 2 itself; confirm it reported no doc-consistency failures, and note your Codex choice."

When the agent runs install/update, before reporting completion it verifies docs freshness with BOTH reviewers:

- **Claude/Codex side:** run the `docs-before-commit` checklist plus `verify.sh` Part 2 (counts, internal links, command→agent/skill references, and provider-surface consistency). `install.sh` already runs this; `update.sh` does NOT (only a narrow README-count check) — so the agent MUST run `bash scripts/verify.sh` itself before reporting an update complete. Report pass/fail.
- **Codex side (when enabled):** run a docs-freshness pass via the `codex-review` skill — a semantic check that `README.md`, `CLAUDE.md`, and `docs/` describe the toolbox's ACTUAL current behaviour. Skip silently when Codex is disabled.

Surface both results. If either finds drift, offer to fix it before declaring done.

**Enforcement:** agent rule plus the `verify.sh` Documentation Consistency stage. No hook gate.

---

## 3b. Ask headers in this skill

Every `AskUserQuestion` this skill instructs -- the Stryker opt-in/opt-out ambiguity, the
mutation-tool pick, the test-project pick, the package-manager pick, the `install.sh` Codex
choice -- carries the header `Unknown`. All of them are the same thing: a fact not inferable
from the goal, `~/.claude/memory.md`, `.claude/PROJECT.md`, the ticket or the repo, which is what
`Unknown` covers in `rules/autonomy.md`. An uncategorised ask is denied outright for a developer
who has opted into the Ask Test, so an ask instructed here without a header would simply fail to
fire.

## 4. Incident histories (rationale)

- **Rule 0 / Rule 3 — natural language must route through commands.** 2026-05-25: user said "start working on 756"; the agent treated it as a freeform instruction, ran `git checkout -b bugfix/TASK-756-*`, and started editing pipeline YAML — no `/start`, `/flow`, discovery, chief-of-staff, or phase comments. User required a full revert.
- **Rule 1 — streamlined path is user-initiated only.** Earlier wording let the orchestrator auto-select "simple"; this caused "/flow invented scope" incidents (built the wrong thing). Only the user has the context to call a ticket simple.
- **Rule 5 — gitignore pre-check.** PR #100 and PR #104 (e2e-tests): 22 toolbox files in the diff. PR #104: auto-poll also wasn't set up, so the user had to manually request automated-review handling.
- **TASK-753:** no phase comments, no chief-of-staff, no code-review orchestration — direct implementation bypassed the entire workflow.
