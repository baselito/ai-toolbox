# Project Configuration

How PROJECT.md, memory.md, and settings.json work together. Per-project vs global config.

---

## When to Read This

- You want to understand where configuration is stored
- You want to know what is per-project vs global
- You need to manually check or fix configuration files
- You want to declare this project's test/lint/build gates, or bound a self-paced `/loop`

---

## Configuration Files

| File | Location | Scope | Contains | Committed? |
|---|---|---|---|---|
| `memory.md` | `~/.claude/memory.md` | Global (your machine) | Personal defaults: tool, methodology, Jira URL, CI/CD, team size | Never |
| `PROJECT.md` | `.claude/PROJECT.md` | This project only | Stack, project type, security level, Jira board, active MCPs, board mappings | No (gitignored) |
| `settings.json` | `.claude/settings.json` | This project only | Active/disabled MCPs | Optional |
| `handover.md` | `.claude/handover.md` | This session only | Agent-to-agent handover notes | No (gitignored) |
| `loop.md` | `.claude/loop.md` | This project only | The body a bare self-paced `/loop` runs — PR tending, bounded and non-merging | No (gitignored) |

---

## memory.md — Personal Defaults

Created by `install.sh` as a blank template. Filled by `/init` the first time you set up a project. Values are reused across all projects as pre-filled defaults.

**Contains:**
- Tool (Claude Code or Codex, depending on the active host)
- Methodology (Kanban / Scrum / Ad-hoc)
- Logging (optional user-managed log connection)
- Team size
- CI/CD (GitHub Actions / etc.)
- Tracking (Jira + Beads / Jira only / Beads only)
- Jira URL and workflow direction

**Never edit manually** — `/init` manages it.

---

## PROJECT.md — Per-Project Config

Created by `/init` for each project. Stores settings specific to this project that may differ from your defaults.

**Contains:**
- Stack (Next.js / NestJS / C# Blazor / Mixed / Other)
- Project type (New feature / Greenfield / Legacy / Bug fixing / Security)
- Security sensitivity (Internal / Customer-facing / Financial)
- Jira board ID/URL
- Board mappings (which board for bugs, incidents, etc.)
- Discovery column handling preference
- Active MCPs for this project
- Optional `verification:` block (which gates make up "done") and `loop:` block (how far one unattended loop run may go) — see below
- Any project-specific overrides

---

## `verification:` and `loop:` — the machine-readable definition of done

Two optional blocks in `PROJECT.md`. Both are **override-only**: with neither block
present, everything still works — the agent detects your ecosystem from your manifest
files and the toolbox loop defaults apply. Add a block only to deviate.

`/init` sub-step 1d offers both, defaulting to Skip, and reads the file back after
writing so a failed write surfaces instead of being assumed. The full templates with
inline comments are in `examples/PROJECT.md.example`.

### `verification:` — which gates make up "done"

| Key | Value | Notes |
|---|---|---|
| `runner` | An ecosystem key, default `auto` | `auto` detects by which manifest FILE exists. Explicit values must be a registry key exactly; an unknown key fails closed. |
| `gates` | A subset of `test`, `lint`, `build` | Action names only. Any other value is refused. A gate the runner has no command for is reported UNAVAILABLE — never silently passed. |
| `coverage_floor` | An integer | **Raise-only:** the effective floor is `max(80, your value)`. |
| `test_globs` | Path patterns | Used for the test-only PR boundary. Matched against changed files; never executed. **Narrow-only:** a pattern is discarded before matching unless one of the seven literals `test`, `tests`, `spec`, `specs`, `e2e`, `fixture`, `fixtures` appears as a delimited path **segment** — not merely as a substring. A delimiter is the start/end of the pattern, or one of exactly five characters: `/` `.` `_` `-` `,` — **nothing else delimits**, not a letter or digit, not a Unicode letter (`caféspec/**` and `Ωtest/**` are discarded), and not `*` or `?`, because a wildcard absorbs arbitrary characters including letters. So `tests/**`, `**/Tests/**`, `**/*.Tests/**` and `**/*.Tests.cs` keep, while `latest/**`, `src/inspector/**`, `**/*test*/**`, `*test/**` and the .NET `*Tests` suffix shapes `**/*Tests/**` and `**/*Tests.cs` are all discarded — the last two because they match `src/LatestTests/` and `src/LatestTests.cs`. A pattern containing `..`, `{`/`}`, `[`/`]`, or `(`/`)`/`|`, or beginning with `!`, is discarded outright, before the delimiter test — extglob alternation and pattern negation hide their own match from it (`!(tests)/**` expands to every top-level entry except tests; `@(tests|src)/**` is `{tests,src}/**` respelled). Every discard is reported by name and replaced by the agent's own judgement of which paths are tests. Full rule, and the cost of discarding the `*Tests` convention: the `workflow-discipline` skill §1c. |

### `loop:` — how far one unattended loop run may go

| Key | Value | Notes |
|---|---|---|
| `max_turns` | Integer | **Tighten-only:** `min(your value, toolbox ceiling)`. Belongs on the native `CLAUDE_CODE_MAX_TURNS` — see the note below on who sets it. |
| `no_progress_after` | Integer | Consecutive iterations with the SAME failure before the loop stops and escalates. Compared by `~/.claude/scripts/loop-progress-signature.sh`, which keys on a normalised failure signature — deliberately not on file mtimes, because a loop rewriting the same failing file looks healthy to an mtime detector forever. |
| `max_spend_usd` | Number | Belongs on the native `--max-budget-usd`. The toolbox adds no spend ledger of its own. |

The supported launcher reads these values and applies them to the native Claude run:

```bash
bash ~/.claude/scripts/loop-launch.sh --print
```

It sets `CLAUDE_CODE_MAX_TURNS`, `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`,
`--max-budget-usd`, and passes the clamped `no_progress_after` value to loop
callers through the shared resolver. It never evaluates project text as shell
code. A `/goal` created inside an interactive `/flow` session still has no
native dollar flag; its turn and no-progress clauses remain the hard bounds for
that session.

The detector clamps a too-large `--threshold` down to the toolbox ceiling on its own,
and `enforce-loop-bounds.sh` rejects an out-of-range bound in a `/goal` condition.
The launcher uses the project resolver for interactive loop runs, so a project value
cannot widen a bound or silently fail to tighten one. The cross-repository auto-poll
cron uses its own safe default threshold because its working directory is not
guaranteed to be the project checkout.

### What reads these two blocks

Five things, and it is worth knowing which, because it explains why the values are shaped
the way they are.

| Reader | What it uses |
|---|---|
| Any phase that runs gates | `runner` + `gates` resolved through the toolbox registry, to know which literal commands make up "done" here. |
| The test-only PR boundary | `test_globs`, matched against the changed-file list. |
| `/flow` Steps 8a and 11a — the `/goal` phase exits | All of it across the two: the resolved gate strings become the *evidence* both conditions name, `coverage_floor` becomes the number **Step 11a** compares against, and `loop.max_turns` / `loop.no_progress_after` become the mandatory bound clauses in both. |
| `hooks/enforce-loop-bounds.sh` | Nothing from `PROJECT.md` — it holds the §1d **ceilings** as literals and denies a `/goal` condition or a recurring cron that exceeds them, or that omits a bound clause entirely. It is the reason those clauses are enforced rather than merely expected. |
| `scripts/loop-progress-signature.sh` | `no_progress_after` as its threshold, clamped again on its own side because it is the thing that actually decides to stop. |

That last row is why `PROJECT.md` holding commands would matter so much more than it looks.
A `/goal` condition is evaluated after every turn by a model with **no tools** — it can only
judge what the agent printed — so the condition has to name real command strings and real exit
codes. If those strings came out of `PROJECT.md`, a project PR could rewrite what the agent
runs unattended in a loop. They come out of the toolbox registry instead, and `PROJECT.md`
contributes only the keys and the numbers. See `commands/flow.md` →
"`/goal` — Machine-Checkable Phase Exits".

### Why neither block holds a command

**`PROJECT.md` contains no shell commands, and adding one is not a shortcut — it is
the attack path.** The file is committed and editable through a PR, so a command
string in it would be unreviewed code the agent later executes. There is deliberately
no `test_command`, `lint_command`, `build_command`, or `smoke_command` field.

The literal commands live one trust level up, in the toolbox-owned verification
registry in the `workflow-discipline` skill (§1c) — a file a project PR cannot modify
without going through the toolbox's own review. This is the same boundary the
`mutation_testing` block already uses; automated-review caught the attack path on PR #58, and
`knowledge/toolbox-lessons.yml` TL-0005 states the general rule: detect which manifest
FILE exists, then run a fixed command for that ecosystem — the file's presence is the
signal, its contents are never a command.

All three clamps exist for one reason — a file every contributor can edit through a
PR must not be able to retire a toolbox-wide guarantee — but they take three different
shapes, so knowing the direction of one tells you nothing about the others.

- `coverage_floor` is **raise-only** (`max(80, your value)`), because 80% is a
  toolbox-wide guarantee in the always-loaded `rules/testing.md`, and a PR setting
  `coverage_floor: 10` would retire it with nothing in the diff that looks like a
  policy change.
- The `loop:` fields are **tighten-only** (`min(your value, ceiling)`) — the opposite
  direction, same reason: they bound unattended behaviour and spend, and
  `rules/performance.md` already sets the precedent of keeping behaviour-critical knobs
  out of `PROJECT.md`.
- `test_globs` has no direction to clamp, because it is a pattern rather than a number.
  It is **narrow-only**: an over-broad pattern is discarded outright before matching —
  one that names no test path segment, one that reaches back out through `..`, or one
  that smuggles in a match the segment test cannot see, via brace alternation
  (`{tests,src}/**` widens to `src`) or a character class (`src/[test]/**` accepts
  `src/t/**`, because `[test]` matches one character rather than the word). A wildcard
  adjacent to the keyword does not delimit it on either side, so `*test/**` and
  `**/*test*/**` are discarded along with the .NET `*Tests` suffix shapes — that last
  discard is a genuine cost, spelled out in the skill. It is the only project-supplied
  input to the test-only PR boundary (`rules/workflow-discipline.md` Rule 6), so
  `- "**/*"` would classify every changed file as a test and empty that boundary at all
  three of its enforcement points. Discarding costs extra scrutiny (the agent reports
  the pattern by name and judges those paths itself); honouring it would cost the
  guarantee.

A value on the wrong side of its clamp is kept in the file and ignored at runtime —
failing the run instead would let one bad line block every workflow. The clamp table
lives in the `workflow-discipline` skill (§1c/§1d).

**There is no smoke gate at all.** A smoke check is inherently project-specific, which
makes it neither registrable (no generic string to register) nor a `PROJECT.md` field
(the forbidden shape). Run it manually and tell the agent the result. The registry
does not register a generic smoke command, so project-specific smoke checks are
manual and fail-closed.

---

## `loop.md` — the autonomous loop body

A bare self-paced `/loop` (no interval) reads `.claude/loop.md` and runs it instead of
the built-in maintenance prompt. Project level beats user level, the file is re-read at
the start of every iteration — so editing it steers a running loop — and it is
truncated past 25,000 bytes.

The toolbox's version tends open PRs it authored: unresolved review threads, failing
CI, merge conflicts, stale rebases. It **proposes and fixes** and may auto-merge
only the `baselito/ai-engineering` toolbox after its scoped GoalRun/live-hook
gate passes; project-repo merging remains user-commanded through `/merge-pr`.

### Installation

```bash
cp ~/your-repos/ai-engineering/examples/loop.md.example .claude/loop.md
# then, in the project:
/loop
```

Nothing installs this for you. `install.sh` does not copy `examples/`, and `.claude/`
is gitignored, so the loop body is per-developer and per-project by design — a standing
instruction to act unattended should be an explicit local choice, not something an
install script grants. Edit the copy freely; the example is a starting point, not a
contract.

### Three trigger tiers

Something has to bring the agent back to the PR. There are three ways, and they are
not equivalent.

| Tier | What it is | Survives the session? | Standing |
|---|---|---|---|
| **1. In-session driver** | `.claude/loop.md` driven by a bare self-paced `/loop`, widening its interval when PRs are quiet and tightening when they are active | No | The reliable path while a session is open |
| **2. Durable trigger** | A Desktop scheduled task (local, 1-minute floor) or GitHub Actions for repo-side checks | **Yes** | What actually makes tending survive the session |
| **3. The `*/1` cron** | The `CronCreate` scheduled at PR creation, running `/review-pr --auto` | No | Redundant backstop, best-effort only |

**Tier 3 is a backstop, not the mechanism.** Session crons fire only while the REPL is
idle — precisely when a busy agent has comments waiting. They are session-only with
nothing written to disk, so they vanish when the session ends. And the toolbox stops one
long before any runtime cap: `/review-pr` Step 0.5 self-terminates the cron 1 day after
it was created, which leaves CronCreate's 7-day runtime cap as an outer backstop only —
for legacy crons created before that age check existed. `durable: true` is a documented
no-op; the live schema says so outright, so a cron cannot be made to survive by asking
it to.

**Cloud Routines are the wrong tier-2 choice:** no access to local files, so they
cannot read the loop body, and a 1-hour floor. Use a local scheduled task, or GitHub
Actions for anything that only needs the repo.

### Which is authoritative

**The agent running `/review-pr` inline when it returns to a PR is the reliable path,
regardless of which tier fired** — that is what has actually been working. The tiers
only ensure the agent comes back; the inline run does the work once it is there. Run
`/review-pr` at PR creation, whenever you return to a PR you authored, and once before
ending a session with open PRs. Never assume a tier did it for you.

> **Where else this is stated:** `skills/pr-automation/SKILL.md` and
> `rules/git-workflow.md` carry the full description — best-effort, idle-only,
> session-only, self-terminated after 1 day with the 7-day runtime cap as the outer
> backstop, and `durable: true` a no-op — and both point here for the tiers.
> `commands/review-pr.md` states the same two lifetime bounds where it implements them
> (Step 0.5, the 86400-second age check, and the legacy-cron note above it) but does
> not discuss idle-only, session-only or `durable: true` at all — do not cite it for
> those. This section and `examples/loop.md.example` remain the canonical description
> of the tiers themselves.

---

## settings.json — MCP Control

Controls which MCPs are active for this project:

```json
{
  "disabledMcpServers": ["seq"]
}
```

The example above disables Seq for a project that doesn't use Seq for logging. Adjust to the MCP you want to disable per project.

---

## How They Work Together

1. You run `/start` on a new project
2. `/init` runs automatically (PROJECT.md does not exist yet)
3. `/init` reads `memory.md` for your personal defaults
4. You adjust what is different for this project
5. `/init` saves project-specific values to `PROJECT.md`
6. `/init` saves any new personal defaults to `memory.md`
7. `/init` saves MCP selections to `settings.json`

On subsequent projects, `/init` pre-fills everything from `memory.md` — you only change what is different.

---

## Switching Projects

Each project has its own `PROJECT.md`. When you switch projects:

```bash
cd ~/your-repos/other-project
claude
/start
```

The agent reads that project's `PROJECT.md` automatically. No re-configuration needed unless something has changed.
