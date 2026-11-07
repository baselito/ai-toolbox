# Mutation Testing and toolbox Presentation Support

## Status

Approved by the user for implementation as part of the GoalRun toolbox work.

## Context

The toolbox already documents mutation testing as default-on, but the runtime does
not yet expose a mutation verifier or a trustworthy result contract. The supplied
`presentation-master.skill` contains a reusable PowerPoint template and generic layout
and validation guidance, but it is currently available only as an external local
artifact and is written around Claude-specific paths.

The toolbox must keep Claude and Codex workflows aligned while preserving the
existing Jira steward, verifier, handover, and safety boundaries. Documentation,
menus, provider adapters, and installation paths must remain synchronized whenever
the implementation changes.

## Goals

1. Run mutation testing during normal development verification when a change
   contains testable production code and the repository uses a supported mutation
   ecosystem.
2. Use Stryker as the first-class mutation runner for JavaScript/TypeScript,
   .NET, and Scala, matching the ecosystems documented by Stryker. Unsupported
   ecosystems must receive an explicit `NOT_APPLICABLE` or configured-adapter
   result; they must never be reported as passing merely because no runner exists.
3. Keep project configuration data-only. Project files may select a registered
   ecosystem, config path, threshold, or policy, but may not provide shell commands.
4. Make surviving mutants actionable: the worker improves tests or records a
   production-boundary finding; it does not alter production behavior merely to
   make a mutant disappear. Repeated no-progress or tool failures go to the
   Sol/Fable advisor queue.
5. Package the toolbox PowerPoint skill and template in the toolbox, adapt its
   machine-specific paths to portable Claude/Codex resolution, and make it
   discoverable for every toolbox presentation request.
6. Keep the same role semantics in both providers: Sol/Fable plan and advise,
   Luna/Opus implement and review, and a lightweight model handles routine
   status/check-in work.
7. Support an advisory discovery mode in which the toolbox can inspect an
   explicitly scoped repository or goal, identify evidence-backed improvement
   opportunities, and propose—not silently create—new work.

## Non-goals

- Replacing Stryker's own mutation engine or duplicating its documentation.
- Automatically changing production code to kill a surviving mutant.
- Uploading presentation content, Jira data, or source code to a remote service.
- Making Codex or Claude authentication implicit or bypassing provider hooks.
- Auto-merging repositories other than the exact `baselito/ai-engineering`
  toolbox repository.
- Adding a generic PowerPoint command that ignores toolbox's supplied template and
  brand rules.

## Design

### 1. Mutation testing contract

Add a toolbox-owned mutation skill and registry-driven runtime verifier.

- Detection is based on manifest files and registered ecosystem keys, never on
  arbitrary commands from a project configuration file.
- Stryker mappings are fixed by the toolbox:
  - JS/TS: local Stryker CLI with the project test-runner plugin/config.
  - .NET: `dotnet stryker` from the configured test project or approved config.
  - Scala: the registered Stryker4s build-tool task.
- A local runner is used only when its executable/package is already available;
  the toolbox may offer the documented bootstrap command, but must not silently
  install dependencies or execute project-supplied shell text.
- Mutation verification runs after the ordinary test gate and is represented in
  GoalRun evidence with the current observed HEAD, runner, score, thresholds,
  surviving-mutant summary, and report path. A missing/failed runner is
  `UNAVAILABLE` or `FAIL`, not success.
- Docs/config-only changes and unsupported stacks produce an explicit,
  machine-readable `NOT_APPLICABLE` reason. Urgent incident/hotfix paths keep
  their existing fast-path exception and report that mutation testing was skipped.
- Thresholds are raise-only from the toolbox default. Stryker's report is the
  source of the score; the toolbox does not invent a score when the report is
  missing or malformed.

### 2. Mutation workflow behavior

The normal GoalRun sequence becomes:

```text
worker change -> ordinary tests/lint/build -> mutation verifier
              -> advisor evaluates failures/survivors
              -> worker improves tests or records boundary finding
              -> checkpoint with evidence
```

The verifier must be independently bound to the observed Git HEAD. A provider
result claiming a new SHA is advisory; the runtime reads `git rev-parse HEAD`
itself before and after verification. If a mutation report was generated for a
different SHA or worktree, the evidence is stale and the run cannot complete.

### 3. Presentation skill and assets

Add `skills/presentation-master/` containing:

- an adapted `SKILL.md` preserving the supplied toolbox layout, brand, font,
  content-boundary, and inline validation rules;
- `assets/template.pptx`, copied unchanged from the supplied package;
- a short portable path-resolution reference covering environment override,
  installed skill asset, and user-provided template paths.

The skill is implicit for requests containing presentation/deck/slide/PowerPoint/
pptx language in a toolbox context. It requires template inspection before slide
planning, uses `python-pptx`, validates the saved deck, and leaves the output at a
user-visible path. It must not assume `/mnt/skills/user`, `/home/claude`, or a
Claude-only output directory.

Add a `/presentation` command as a discoverable wrapper for the skill. The command
must route through the existing workflow discipline and verification rules while
allowing a presentation-only task to omit Jira when it is not tied to a project
ticket. The command menu, command reference, skill list, model assignments, and
getting-started documentation will all name the new skill/command.

### 4. Claude/Codex installation and synchronization

The repository remains the single source of truth. Installation copies the shared
skill and asset to the Claude skill root and, when Codex is enabled or its skill
root exists, to the Codex skill root. Copies are scoped to the toolbox-owned
directory and never wipe unrelated user skills. The install/update verification
checks both copies when present.

Codex and Claude use the same skill content and runtime contracts. Provider-specific
differences are limited to the existing adapter command and role assignment:
Claude uses Fable/Opus/Haiku defaults; Codex uses Sol/Luna/lightweight defaults.

### 5. Advisory discovery and Jira handoff

Advisory mode is a first-class GoalRun mode, separate from an implementation
goal. It accepts a scope such as a repository, module, PR, test report, or
question. The advisor/planner (Sol for Codex, Fable for Claude) gathers evidence
through approved read-only tools, classifies each opportunity as bug, feature,
refactor/tech debt, security, performance, or documentation drift, and returns
ranked proposals with:

- observed evidence and affected paths;
- user impact and risk;
- a proposed scope and explicit non-goals;
- acceptance criteria and verification/mutation-testing expectations;
- dependencies, priority rationale, and a recommended workflow command.

The advisor never invents a Jira key and never writes to Jira before the user
approves a proposal. After approval, the existing `jira-workflow-steward`
handles the complete Jira path: canonical summary/description, issue type and
priority, assignment, parent/linking when applicable, phase-map transition,
phase comments, and Beads pairing. The proposal is retained in GoalRun state so
the resulting Jira key and all later implementation evidence remain linked.

If Jira is unavailable or the user declines, the proposal remains actionable as
an explicit local/Beads item with a clear retry or user-action state. The
toolbox does not create duplicate tickets when resuming an interrupted handoff.

### 6. Documentation and menu synchronization

Update all of the following in the same change:

- `commands/` menu and `/presentation` command;
- `CLAUDE.md`, `README.md`, rules, model/skill references, and testing/GoalRun
  how-to docs;
- provider-neutral advisory/runtime surfaces for Claude and Codex;
- installation/update documentation and count/check references;
- the GoalRun design/spec and examples where old “never mutation test” or
  Claude-only presentation paths appear.

The implementation must include a verification check that the packaged template,
skill entrypoint, command entry, and menu/reference entries all exist together.

## Failure handling

- Missing mutation runner: record `UNAVAILABLE`, show the exact registered
  bootstrap/manual action, and keep the run resumable; never silently skip.
- Malformed mutation report: record `FAIL` with the report path and parser error.
- Surviving mutant requiring production changes: record a finding and continue
  only if all required gates otherwise pass; do not edit production code to game
  the score.
- Missing presentation template: stop before generation and ask for a path.
- Failed deck validation: keep the output for diagnosis, mark verification
  failed, and do not report the deck as ready.
- Provider unavailable: preserve the existing `HUMAN_ACTION_REQUIRED` state and
  do not pretend that Claude or Codex executed the work.

## Verification plan

- Unit tests for ecosystem detection, fixed mutation argv selection, explicit
  `NOT_APPLICABLE`, malformed/mismatched report evidence, threshold handling, and
  observed-HEAD binding.
- Installer/check tests for the presentation skill entrypoint and binary asset,
  with isolated temporary Claude/Codex roots.
- A static synchronization test that checks the command/menu/skill/docs mirrors.
- Existing GoalRun, hook, progress-signature, merge-gate, and repository
  verification suites remain green.
- Where Stryker itself is not installed in this toolbox checkout, validate the
  registry and adapter contract without claiming a real mutation score.

## Official reference

Stryker's official documentation identifies StrykerJS, Stryker.NET, and Stryker4s
as supported families and documents configuration, coverage analysis, concurrency,
and mutation-score thresholds:

- https://stryker-mutator.io/
- https://stryker-mutator.io/docs/stryker-js/config-file/
- https://stryker-mutator.io/docs/stryker-net/configuration/
