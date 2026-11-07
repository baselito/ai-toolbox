# /init — Project Configuration Wizard

<!-- ask-headers: Unknown -- every AskUserQuestion this file instructs uses this header unless the line names its own (rules/autonomy.md) -->


Configure this project for the agentic development workflow. Saves project-specific settings to `.claude/PROJECT.md` and personal defaults to `~/.claude/memory.md`.

---

## Trigger

- Run manually: `/init`
- Auto-triggered by `/start` (or any command) if `.claude/PROJECT.md` does not exist in the current project

---

## Behaviour

### Step 1 — Check for Existing Defaults

The agent reads the user's global memory file to check if they have configured any project before. **Important:** The file is `memory.md` (lowercase, not `MEMORY.md`). Use `Bash(cat "$HOME/.claude/memory.md" 2>/dev/null || echo "FILE_NOT_FOUND")` to read it. Do NOT use `Read memory.md` or `Read MEMORY.md` — these use relative paths and will fail.

- **If memory.md has saved values (not first time):** Use saved values as pre-filled DEFAULTS for each question, but still ask every question one at a time. Show the default and let the user confirm or change it.
- **If memory.md is blank or not found (first time):** Run auto-detection silently, then ask all 6 questions in order with no defaults.

### Step 2 — Ask Questions (first time only)

**⛔ HARD STOP RULE — READ THIS BEFORE DOING ANYTHING ELSE ⛔**

This is a conversational wizard. You MUST follow this exact pattern for EVERY question:

1. Show ONE question with its numbered options
2. End with: `Type a number and press Enter (or just Enter for the default).`
3. **STOP GENERATING.** Do not write another word. Do not show the next question. Do not summarise remaining questions. Your response ENDS here.
4. Wait for the user to type their answer.
5. After they answer, acknowledge it in one short line, then show the NEXT question only.
6. Repeat until all questions are asked.

**VIOLATIONS — any of these means you broke the rule:**
- Showing 2 or more questions in one message ❌
- Listing all questions as a summary or form ❌
- Saying "feel free to answer all at once" ❌
- Saying "here are the remaining questions" ❌
- Presenting questions as Q1/Q2/Q3 in a single block ❌
- Auto-answering based on detection without asking ❌

**CORRECT BEHAVIOUR — this is what one turn looks like:**
```
Q1 — Jira
Do you use Jira?

1) Yes — Jira Cloud
   -> Guided setup: install acli, create API token, connect
2) No — skip Jira integration
   -> Beads-only tracking.

Type a number and press Enter (or just Enter for the default).
```
Then STOP. Nothing else. Wait for the user.

**Auto-detection** is allowed but it is a DEFAULT, not a skip. Show it as: `Auto-detected: [value]. Press Enter to confirm or pick a different option.` — then STOP and wait.

**⛔ DEFAULTS FROM memory.md DO NOT SKIP QUESTIONS ⛔**
Even if memory.md has saved answers from a previous project, you MUST still show every question one at a time. Pre-fill the default from memory.md, but ALWAYS show the question and ALWAYS wait for the user to confirm or change it. NEVER batch defaults into a summary screen. NEVER show a "confirm all" table. The user decides — one question at a time.

**⛔ NEVER SHOW A CONFIGURATION SUMMARY SCREEN ⛔**
Do not show a table/form with all fields at once and ask the user to "type a number to change". This is ALWAYS wrong. Every field must be its own question, asked and answered individually.

---

#### Q0 — Tool *(no longer asked — set automatically)*

The toolbox supports Claude Code and Codex. `install.sh` records the primary
host in `memory.md`; the agent skips this question and goes straight to Q1.

---

#### Auto-Detected Settings *(saved silently to PROJECT.md — no questions asked)*

Before asking any questions, the agent silently detects and saves the following settings. These are never asked as questions — they are determined automatically from the project and the user's workflow.

| Setting | How it is detected | Saved to |
|---|---|---|
| **Stack** | Scans for `.sln`, `.csproj`, `package.json`, and known patterns (Gen1 references, Blazor components, Next.js config). Falls back to "Other" if no match. | PROJECT.md |
| **Methodology** | Detected from Jira board type (`"type": "kanban"` or `"type": "scrum"`). If no Jira configured, defaults to "Ad-hoc". | PROJECT.md |
| **Project Type** | Determined by which command the user runs: `/flow` = feature, `/bug` = bug fix, `/refactor` = legacy refactor, `/security` = security hardening, `/build` = greenfield or ad-hoc. Not saved during `/init` — resolved at runtime. | Not saved |
| **Security Sensitivity** | Determined by conditional agent rules based on files changed. Files touching `appsettings*`, `*auth*`, secrets, PII, or payment code trigger `security-engineer` (deep-reasoning tier — see `rules/performance.md`) + `security-reviewer` automatically. | Not saved |
| **Logging and Observability** | Optional user-managed MCP log connection. Discover available tools and verify redaction; otherwise use local logs. | PROJECT.md when configured |
| **Team Size** | Asked during sprint planning (Step 0 of `/flow` on Scrum boards) if needed for velocity calculations. Not needed for Kanban or ad-hoc workflows. | PROJECT.md (when asked) |

The agent logs what it detected in the Summary Screen so the user can see and override if needed.

---

#### Q1 — Jira *(saved to memory.md)*

**⛔ CHECK ACLI AUTH FIRST — SKIP SETUP IF ALREADY CONNECTED ⛔**

Before asking anything, check if acli is installed and authenticated:
```bash
Bash(acli jira auth status 2>&1)
```

**If already authenticated:** Jira is globally configured — no setup needed. Check memory.md for a saved project key and board:

- **If memory.md has a saved Jira project key + board:** Use it as default. Show:
  ```
  Jira connected as [name]. Using project [KEY], board [BOARD_ID] (from previous project).
  Press Enter to keep, or type a different project key.
  ```
  STOP. Wait for answer. If Enter, use the saved default — no further Jira questions.

- **If memory.md has no saved Jira settings (first project):** Ask:
  ```
  Jira is connected (logged in as [name] at [site]).

  What is the Jira project key for this repo? (e.g. DEV)
  ```
  STOP. Wait for answer. Then verify and detect board type. Save to memory.md for future projects.

Skip all other Jira setup sub-steps.

**If NOT authenticated (or acli not installed):** Ask the full setup question:

```
Do you use Jira?

1) Yes — Jira Cloud
2) No — skip Jira integration
   -> Beads-only tracking.
```

**If the user selects Yes, run the guided ACLI setup:**

The agent walks through each sub-step one at a time. Do NOT batch them. Each sub-step ends with STOP — wait for user.

**Sub-step 1a — Check if acli is installed:**
```
Bash(command -v acli)
```
- If found: "Atlassian CLI is installed. Continuing..."
- If not found: "Atlassian CLI (acli) is not installed. Install now?"
  ```
  1) Yes — install via Homebrew (recommended)
     -> Runs: brew tap atlassian/homebrew-acli && brew install acli
  2) No — I'll install it myself later
     -> Shows manual install URL and skips Jira setup
  ```

**Sub-step 1b — Collect credentials (ask one at a time):**
```
What is your Jira site URL?
(e.g. yourcompany.atlassian.net)
```
STOP. Wait for answer.

Then:
```
What is your Atlassian email?
(The email you use to log into Jira)
```
STOP. Wait for answer.

**Sub-step 1c — API token creation + login:**
```
You need an Atlassian API token. I'll open the page for you.
```
Run: `Bash(open "https://id.atlassian.com/manage-profile/security/api-tokens")` (macOS) or show the URL.

Then tell the user:
```
In the browser:
  1. Click "Create API token"
  2. Label it (e.g. "acli-claude")
  3. Copy the token

Then run this command in your terminal (paste your token when prompted):

  echo "YOUR_TOKEN" | acli jira auth login --site [their-site] --email [their-email] --token

Tell me when done.
```
STOP. Wait for confirmation.

After the user confirms, verify:
```
Bash(acli jira auth status 2>&1)
```
- If successful: "Connected to Jira as [name] ✓"
- If failed: "Connection failed. Check your token and try again, or type 'skip' to continue without Jira."

**Sub-step 1d — Project key (same as the fast path above):**
```
What is your Jira project key? (e.g. DEV)
```
STOP. Wait for answer.

After receiving the key, verify with a test query:
```
Bash(acli jira workitem search --jql "project = [KEY]" --fields key,summary --limit 1 --json 2>&1)
```
- If returns a ticket: "Project [KEY] found — [ticket count] tickets accessible ✓"
- If fails: "Project [KEY] not found. Check the key and try again."

The agent also asks for the board ID or URL so it can read the board directly. The agent detects the board type (Kanban/Scrum) using `Bash(acli jira board search --json)` and uses it to auto-detect methodology (saved to PROJECT.md).

**Sub-step 1e — Phase map (saved to PROJECT.md as `jira_phase_map`):**

The toolbox reasons in universal PHASES (Discovery, Implementation, Code Review, etc.) and projects to columns only at the API boundary. Per-team boards differ wildly — one team's "In Progress" is another team's "Doing"; one board has Discovery, another doesn't. So instead of asking "list your columns left to right" (the old approach, which broke when teams renamed columns), `/init` now asks **anchor questions per phase**: the user picks which column means each universal phase.

**Why this changed:** column names are a per-team UI choice and drift over time (renames, additions, removals). Phases are universal. Mapping phase→column once, with the user explicitly stating semantic intent, makes drift detection possible later — `/flow` validates the contract on every run.

**⛔ NEVER guess column names from ticket statuses. ALWAYS read the live board via the REST API. ⛔**

**Step 1e.1 — Read the live board's columns:**

```bash
Bash(bash ~/.claude/scripts/jira-board-columns.sh [BOARD_ID] --json)
```

Use `--json` mode (returns a JSON array of unique column names). Example output:
```json
["Backlog", "Selected for Development", "In Progress", "Ready for Release", "Done"]
```

This array is the **source of options** for the anchor questions below — the user only ever picks from real columns, never types free text.

If the script fails (token error, API down), fall back: ask the user to type the column names left-to-right, save those as the option list, and continue with the anchor questions below.

**Step 1e.2 — Ask anchor questions, ONE AT A TIME:**

Each question shows the live columns as options plus "(none — phase has no column on this board)". The user picks the column whose **semantic meaning** matches the phase. Use **AskUserQuestion** for each, header `Unknown`. STOP after each question and wait for the user.

The phase keys are fixed; the column values are picked by the user.

**Q1e-a — Discovery (optional phase):**
```
Does your board have a separate column where tickets get investigated
before development starts (e.g. "Discovery", "Triage", "Refinement")?

[1] Backlog
[2] Selected for Development
[3] In Progress
[4] Ready for Release
[5] Done
[6] (none — investigation happens in Backlog without a column move)
```
→ Saved as `jira_phase_map.discovery`. Most boards pick "(none)".

**Q1e-b — Ready for Development:**
```
Which column means "ready to start development" — planning is done,
the ticket is queued, but coding hasn't begun?

[1] Backlog
[2] Selected for Development
[3] In Progress
[4] Ready for Release
[5] Done
[6] (none — no separate "ready" column; goes straight from Backlog to In Progress)
```
→ Saved as `jira_phase_map.ready_for_dev`.

**Q1e-c — In Progress (development active):**
```
Which column does a ticket move to when DEVELOPMENT WORK STARTS
(branch created, first commit)?
```
(Same option list — pick one column.) → Saved as `jira_phase_map.in_progress`.

**Q1e-d — Code Review:**
```
Which column means "awaiting code review" (PR open, agents reviewing,
or human reviewer assigned)?

Pick the same column as In Progress if your team reviews inside In
Progress without a separate column.
```
(Same option list — pick one column. Reusing the In Progress column is the natural answer for boards with no "In Review" lane.) → Saved as `jira_phase_map.code_review`.

**Q1e-e — Ready for Release:**
```
Which column means "merged, awaiting deploy" (PR merged, code on main,
not yet on Stage/Prod)?

Pick "(none)" if your team merges directly to Done.
```
(Same option list.) → Saved as `jira_phase_map.ready_for_release`.

**Q1e-f — Done:**
```
Which column means "fully done" (deployed, tested, ticket closed)?
```
(Same option list — usually the last column.) → Saved as `jira_phase_map.done`.

**Step 1e.3 — Save to PROJECT.md:**

Write the answers to a YAML block under "### Jira Phase Map":

```yaml
jira_phase_map:
  discovery: null                          # if user picked "(none)"
  ready_for_dev: "Selected for Development"
  in_progress: "In Progress"
  code_review: "In Progress"               # same column reused — natural lump support
  ready_for_release: "Ready for Release"
  done: "Done"
```

**Also save the board ID** (used by `/flow` Step 0 drift validation):
```yaml
jira_board_id: 309
```

**⛔ The phase map is the source of truth for ALL commands. ⛔**
- `/flow` reads `jira_phase_map[phase]` to decide whether to transition or stay put; concise Jira comments are separate milestone updates
- Validation runs at the start of every `/flow` run — if a mapped column no longer exists on the live board, `/flow` pauses and surfaces drift before any phase fires
- The Columns field in the confirmation summary reads from the phase map, not a separate column list
- Jira column names and Jira status names can differ — always use column names for display, use transitions by name for moves
- If a column is renamed or removed, drift detection at `/flow` start prompts the user to remap. Manual `/init` re-runs are still supported for whole-board redesigns.

**Brainstorming, Planning, Verification:** these phases are not in the anchor questions because they are toolbox-internal work, not board columns. They require no routine Jira comment. PR Creation emits the standard short PR/milestone update.

**Migration from `jira_columns`:** if PROJECT.md still has the legacy `jira_columns` field from an older `/init` run, leave it — the next `/flow` Step 0 detects it, runs the anchor questions once, populates `jira_phase_map`, and removes the legacy field.

---

#### Q2 — CI/CD *(saved to memory.md)*

```
What CI/CD tool do you use?

1) GitHub Actions  <- default for toolbox
   -> GitHub CLI (gh) handles CI/CD; devops-automator reviews workflow YAML
2) Other
   -> The agent asks what tool you use
3) None
   -> CI/CD steps skipped in workflows
```

---

#### Q3 — Jira Workflow Direction *(only if Jira configured — saved to memory.md)*

```
How do tickets get into Jira?

1) Board-driven — your team puts tickets on the board,
   the agent picks them up
   -> The agent reads your board and works from
     existing tickets. Never creates tickets itself
     unless you explicitly ask.

2) Agent-first — the agent creates all tickets after
   asking you questions
   -> Good for solo devs or teams without a dedicated PM.
     The agent creates epics, stories and tasks in Jira,
     then immediately starts working from them.

3) Hybrid — your team creates epics and stories,
   the agent creates the technical sub-tasks underneath
   -> Good for teams where the PM owns the board.
     You or your PM create the high-level tickets.
     The agent reads your stories and breaks them into
     developer tasks automatically before building.
```

---

#### Q4 — Task Tracking *(only if Jira configured — saved to memory.md)*

```
How do you want to track tasks internally?

1) Jira + Beads  <- recommended
   -> Jira for your team's visibility, Beads for the
     agent's internal AI tracking across sessions.

2) Jira only
   -> Simpler setup but may lose task context if a
     session is interrupted.

3) Beads only
   -> Lightweight, no Jira needed. Good for solo work.
```

If no Jira is configured, Beads only is auto-selected and this question is skipped.

---

### Step 3 — Integrations Summary

After all questions are answered, show the integrations configuration:

```
-----------------------------------------
  Integrations — please confirm
-----------------------------------------
  Based on your selections:

  CLI TOOLS (0 MCP tools — runs via terminal)
  [checkmark] [1] Jira (acli)
         yourcompany.atlassian.net
         Auth: API token (verified)
         Reads/updates tickets, moves through
         columns, adds comments
  [checkmark] [2] GitHub (gh)
         Creates PRs, reads issues, searches
         code, manages branches

  MCP SERVERS
  [checkmark] [3] Seq
         Queries logs during /incident, /bug
         and /perf workflows

  PLUGINS
  [checkmark] [4] Beads
         Tracks tasks across sessions, files
         post-mortems, tracks sprint velocity

  ~MCP tools active: ~7 / 60 recommended limit
  (Jira via acli and GitHub via gh CLI add 0 MCP tools)

  Type number(s) to toggle on/off
  e.g. "3" to disable Seq
  [ENTER] Approve and continue to project summary
  [A]     Add a custom MCP
-----------------------------------------
```

**Tool count limits:**
- Under 60 tools = comfortable, recommended
- 60-80 tools = acceptable, monitor for slowdowns
- Over 80 tools = disable MCPs until back under 60
- If toggling a MCP on pushes the count over 60, warn the user and suggest which MCPs to consider disabling first
- Never add a new MCP without checking current count with `/mcp` first
- Jira via acli adds 0 MCP tools — it runs via Bash

**Adding a custom MCP — select [A]:** The agent asks for MCP name, install command or URL, and environment variables needed. Walks through setup and saves to `PROJECT.md` and `~/.claude.json`.

---

### Step 4 — Review before saving

After the last question is answered, show a brief recap of all answers:

```
Here's what I'll save:

  Stack:         C# Microservice (Gen1) — auto-detected
  Methodology:   Kanban — auto-detected from Jira board
  Tool:          Claude Code
  Jira:          your-team.atlassian.net / DEV
  CI/CD:         GitHub Actions
  Jira workflow: Board-driven
  Tracking:      Jira + Beads

Type "y" to save, or the name of a field to change it.
```

This is NOT a form — it is a read-only recap shown AFTER all questions are answered. It exists only so the user can double-check before saving.

---

### Step 5 — Save Configuration

On confirmation:

1. **Ensure `.claude/` is in `.gitignore`** — the agent creates per-session working files in `.claude/` (handover.md, .push-ready, and workflow markers). These are NOT code and must not be committed. If `.claude/` isn't gitignored, every session leaves untracked files that clutter `git status` and risk accidental commits of local config.

   The agent checks the repo's `.gitignore` and adds `.claude/` if missing:

   ```bash
   # Check if .gitignore exists and whether .claude/ is already covered.
   # The detection regex (^|/)\.claude/?$ catches all equivalent patterns:
   #   .claude, .claude/, /.claude, /.claude/, **/.claude/, foo/.claude/
   # CRLF handling: strip \r before grepping so Windows-edited .gitignores
   # (with \r\n line endings) don't produce false negatives that duplicate
   # the entry on every /init re-run.
   if [[ -f .gitignore ]]; then
     if tr -d '\r' < .gitignore | grep -qE "(^|/)\.claude/?$"; then
       # Already gitignored — skip
       :
     elif [[ -w .gitignore ]]; then
       # Append with a comment so future maintainers understand why
       printf '\n# Claude Code toolbox working files (session handover, markers, per-project config)\n.claude/\n' >> .gitignore
     else
       # .gitignore exists but is read-only (corp policy, locked checkout)
       # Don't fail silently — tell the user.
       echo "WARNING: .gitignore is not writable. Add '.claude/' to it manually, or the agent's per-session working files will show as untracked in git every session."
     fi
   else
     # No .gitignore — create one
     printf '# Claude Code toolbox working files (session handover, markers, per-project config)\n.claude/\n' > .gitignore
   fi
   ```

   **Edge cases:**
   - Repo has `.gitignore` with a pattern that already covers `.claude/` (e.g. `.claude`, `.claude/`, `/.claude/`, `**/.claude/`, `foo/.claude/`) — the regex `(^|/)\.claude/?$` detects all of these. CRLF-terminated files (Windows line endings) are handled by stripping `\r` before the check.
   - Repo has a comment-out line like `# .claude/` — the regex correctly does NOT match comments (because `#` is not `/` or line start followed by `.claude`), so the agent appends an active entry. Correct behaviour.
   - `.gitignore` exists but is not writable — the agent prints a WARNING rather than silently failing. User must add the entry manually.
   - Repo is in a git submodule or nested git dir — the agent updates the closest `.gitignore` to current working directory. If this is wrong for the project's layout, the user can remove the line manually.
   - Repo uses a shared `.gitignore` at the monorepo root — the agent still writes to the current directory. User may need to move the entry up or add it to the monorepo's root gitignore.

   **Why this is Step 5's first action:** Setting up gitignore before writing `PROJECT.md` ensures `PROJECT.md` is ignored from the moment it's created. git checks `.gitignore` on `git add`/`git status`, not on file creation, so the order doesn't strictly matter — but starting with gitignore reduces surprise for users who `git status` between steps.

   **Note on `settings.json`:** Teams that want to share MCP config across the team may commit `.claude/settings.json`. In that case, after adding `.claude/` to gitignore, add an exception: `!.claude/settings.json`. The default (gitignore everything) is zero-config and works for every team; the exception is opt-in.

   1b. **Add universal mutation-testing artifact patterns to `.gitignore`** — Stryker reports (HTML dashboards, JSON results, per-run output directories). These patterns are stack-agnostic: every project benefits from blocking them whether or not it has a Stryker variant installed today. Adding them pre-emptively means a developer who later runs a registered Stryker runner cannot accidentally commit gigabytes of binary artefacts. **Playwright is NOT covered** — `npm init playwright@latest` adds its own gitignore entries (`test-results/`, `playwright-report/`, `playwright/.cache/`, `.last-run.json`) as part of its installer, so the toolbox doesn't duplicate work the tool already handles. The toolbox principle: fill gaps that tools don't fill themselves.

   The agent appends the block ONLY if no pattern from the block is already present (idempotent — running `/init` twice doesn't duplicate entries):

   ```bash
   # Universal Stryker artifact patterns. Detection probe: look for any of
   # the patterns we'd add as an ACTIVE gitignore rule (not a comment, not
   # an unignore `!` rule), with the token matched as a complete path
   # segment — not a substring within an unrelated path.
   #
   # Why awk instead of grep: we need three conditions per line that grep
   # can't combine cleanly: (1) skip lines starting with `#` or `!`, (2)
   # match the token as a path component, not a substring within a longer
   # name (`backup/mutation-report.json.old` must NOT match), (3) match
   # the token at line-start OR after `/` OR after `**/`.
   #
   # Issues automated-review caught and this probe fixes:
   # - `# StrykerOutput goes here` (comment) → MUST NOT match
   # - `!StrykerOutput/` (unignore rule) → MUST NOT match
   # - `backup/mutation-report.json.old` (suffix) → MUST NOT match
   # - `StrykerOutput/`, `**/StrykerOutput/`, `/StrykerOutput/` → MUST match
   # - `stryker-results/`, `mutation-report.html` → MUST match
   # - `StrykerOutput/**`, `reports/mutation/**` (recursive-content
   #   glob form) → MUST match (PR #58 automated-review cycle 3 finding II:
   #   a `/**` suffix is a stronger "ignore everything beneath this
   #   directory" pattern. If a repo already declares this form AND
   #   pairs it with a `!reports/mutation/.gitkeep` exception, our
   #   shorter `reports/mutation/` append would reverse the exception
   #   via gitignore's "last rule wins" semantic. Treat the presence
   #   of a `/**` form on any of our tokens as "user has an opinion
   #   on this path", same as the unignore branches, and skip the
   #   block append entirely.)
   if [[ -f .gitignore ]] && [[ -w .gitignore ]]; then
     if ! tr -d '\r' < .gitignore | awk '
       # Skip blank lines and pure comments.
       /^[[:space:]]*$/ { next }
       /^[[:space:]]*#/ { next }
       # Unignore lines (`!pattern`) need SPECIAL handling, not
       # blanket skip: if the user has explicitly written
       # `!StrykerOutput/` they meant to override a parent .gitignore
       # — appending our `StrykerOutput/` later would REVERSE that
       # intent (gitignore "last rule wins"). Treat the presence of an
       # unignore rule targeting any of our tokens as "user has an
       # opinion on this path", and skip the whole block. This is
       # finding A from PR #58 automated-review cycle 2. The optional `/**`
       # suffix (`(\/\*\*|\/)?`) handles the `/**` recursive-content
       # glob form added in cycle 3 finding II.
       /^[[:space:]]*!(.*\/)?(StrykerOutput|stryker-results)(\/\*\*|\/)?[[:space:]]*$/ { found=1; exit }
       /^[[:space:]]*!(.*\/)?reports\/mutation(\/\*\*|\/)?[[:space:]]*$/ { found=1; exit }
       /^[[:space:]]*!(.*\/|\*\.)?mutation-report\.(html|json)[[:space:]]*$/ { found=1; exit }
       # Active ignore line: match StrykerOutput / stryker-results /
       # reports/mutation / target/stryker4s as complete
       # path segment. Token must be preceded by start-of-line, `/`, or
       # `**/`, and followed by `/`, `/**`, end-of-line, or whitespace.
       # The `(\/\*\*|\/)?` capture group is the cycle 3 finding II fix:
       # without it, `reports/mutation/**` slipped past the probe and
       # `/init` appended a stronger `reports/mutation/` rule that could
       # reverse a paired `!reports/mutation/.gitkeep` exception. The
       /(^|\/)(StrykerOutput|stryker-results)(\/\*\*|\/)?[[:space:]]*$/ { found=1; exit }
       /(^|\/)reports\/mutation(\/\*\*|\/)?[[:space:]]*$/ { found=1; exit }
       /(^|\/)target\/stryker4s(\/\*\*|\/)?[[:space:]]*$/ { found=1; exit }
       # Mutation-report files: match as exact filename, optionally
       # preceded by a path or by `*.` (the toolbox writes both forms).
       # No `/**` suffix variant — these are file patterns, not dirs.
       /(^|\/|\*\.)mutation-report\.(html|json)[[:space:]]*$/ { found=1; exit }
       END { exit !found }
     '; then
       cat >> .gitignore <<'__STRYKER_ARTIFACTS__'

# Mutation testing — reports, logs, and per-run output for all supported
# Stryker runners. Stryker.NET writes to StrykerOutput/<timestamp>/;
# Stryker.JS writes to reports/mutation/; Stryker4s writes to
# target/stryker4s/. These directories are binary blobs + HTML + JSON
# dashboards that must NEVER end up in a PR diff.
# Toolbox-installed by /init.
StrykerOutput/
stryker-results/
**/StrykerOutput/
**/stryker-results/
reports/mutation/
**/reports/mutation/
target/stryker4s/
**/target/stryker4s/
mutation-report.html
mutation-report.json
*.mutation-report.html
*.mutation-report.json
__STRYKER_ARTIFACTS__
     fi
   fi
   ```

   **Why universal:** these patterns block artefact output, not source code or config. A repo without any mutation-testing tool installed is unaffected. A repo that adopts any supported Stryker runner later gets coverage for free — the developer doesn't need to remember to edit gitignore. This is the foundation the per-project wizard (sub-step 1c) relies on: when the wizard tells a user "Output: `<output_dir>/` already gitignored by /init sub-step 1b", that claim must hold for every runner the wizard supports.

   **Why mutation-testing tools but not Playwright:** Stryker runners do NOT auto-add gitignore entries — they just dump output to a directory. A user who runs a registered Stryker command without prepping `.gitignore` first will get a PR diff full of binary HTML/JSON dashboards. Playwright is different: `npm init playwright@latest` adds its own gitignore entries (`test-results/`, `playwright-report/`, `playwright/.cache/`, `.last-run.json`) as part of installer setup, so the toolbox would just be duplicating work the tool already handles. The toolbox principle: fill gaps that tools don't fill themselves.

   **Edge cases:**
   - Repo already has SOME of these patterns on an active (non-comment) line (e.g. only `StrykerOutput/` from a prior manual edit) — the detection probe matches and skips the block. The user keeps their existing entries; no duplicates. If the user wants the FULL universal block, they delete their existing entry and re-run `/init`.
   - Repo has a comment-only mention like `# StrykerOutput goes elsewhere` — the awk script's `/^[[:space:]]*[#!]/ { next }` rule skips comment AND unignore lines before checking for matches, so the block IS appended. Comments document intent; they don't replace active rules.
   - Repo has Stryker outputs at a non-default path (e.g. `out/stryker/`) — `/init` does NOT cover that. The user must add the project-specific path themselves. The toolbox covers the defaults; non-defaults are the project's responsibility.
   - Repo uses Playwright but the developer skipped `npm init playwright@latest` — `/init` does NOT add Playwright gitignore entries for them. The developer must either run the Playwright installer (which adds the entries) or add `test-results/` / `playwright-report/` to `.gitignore` manually. This is consistent with the "tools own their own gitignore" principle: the toolbox doesn't second-guess Playwright's setup choices.
   - Read-only `.gitignore` — skipped silently, like the `.claude/` step. The user is already warned about read-only `.gitignore` in sub-step 1 above; no second warning needed.

1c. **Mutation-testing policy wizard (per-project override — OPTIONAL)** — most projects don't need this. Mutation testing is ON by default toolbox-wide: Stryker runs at Verification on every ticket that creates unit tests, and `/flow` Step 11b auto-skips tickets that can't have unit tests (config, docs, infra, renames). This wizard exists ONLY to DEVIATE from that default — to pin a specific tool (skip auto-detection), restrict mutation testing to test-only PRs, or opt the project OUT of default-on (for repos whose suite is too slow to mutate every ticket). A project that's happy with default-on should pick `Skip — keep default-on`.

   **Step 1 — Idempotency check (completeness-aware).** If `.claude/PROJECT.md` already contains a COMPLETE `mutation_testing:` block (all four required fields present), SKIP this entire sub-step. If the block is PARTIAL (block header present but some fields missing), RESUME the wizard with only the missing fields asked. This matches the `edge-cases` skill "PROJECT.md exists but is incomplete" — only ask about things that aren't already set.

   **Detection is a READ, not a parse. ⛔ Never write a shell/awk YAML parser here. ⛔**

   `/init` is a command file and this step is an INSTRUCTION the agent follows, not a script
   that must run standalone: open `.claude/PROJECT.md`, read it, and classify the block by the
   rules below. A bash/awk extraction used to sit here too, and it shared the defects that got
   the larger sub-step 1d parser deleted (see 1d's "Detection is a READ" note for the full
   history). Two of them reproduced verbatim in THIS sub-step: a comment line indented no
   deeper than the header (a column-0 `#` under a column-0 header) truncated the block, so a
   fully-configured block read as bare and
   every field was re-asked on every `/init` run; and a nested map's field
   (`mutation_testing:` → `  nested:` → `    tool: stryker.net`) counted as the block's own
   `tool`, so a block from which runtime resolves nothing was reported "already configured".
   **A future editor must not reintroduce a parser here** — read the YAML instead.

   Reading rules. Rules 1–3 mirror sub-step 1d's, with one deliberate difference in rule 1.
   1d's closed-set validation has NO counterpart here: this sub-step tests each field for a
   usable value only, and never checks that value against the option sets Step 2/Step 4 write
   from. That is pre-existing behaviour, unchanged by the parser removal — do not read "same
   rules as 1d" as implying validation this sub-step does not do.

   1. **The header may sit at ANY indentation here.** This sub-step's header anchor is
      deliberately LOOSER than 1d's column-0 rule; it is preserved as-is and was not changed
      by the parser removal. Two or more `mutation_testing:` keys → AMBIGUOUS: which one binds
      is YAML-parser dependent, so nothing about the block can be reported as configured and
      the Step 5 merge has no single block to target. This sub-step has no read-back, so the
      ambiguity is caught here or not at all.
   2. **A field belongs to the block only if it is a DIRECT child of the header** — one
      nesting level under it, never deeper — **and the block ENDS at the first later non-blank
      line indented no deeper than the header itself**, not at column 0. Both halves matter,
      because the header may be indented: a block that ran to column 0 would swallow its
      SIBLINGS' fields (under `loop:` → `  mutation_testing:` → `  unrelated_sibling:`, the
      sibling's `when_to_run:` / `config_path:` / `output_dir:` would all read as this
      block's), and a field of a nested map INSIDE the block belongs to that map, not to
      `mutation_testing`. Either error reports the block "already configured" with a policy
      nothing set — the unsafe direction, because over-claiming CONFIGURED hides a partial
      block the wizard then never repairs.
   3. **A comment line or a blank line does not end the block.** A `# …` line between the
      header and its fields is valid YAML, and the fields after it are still the block's.
   4. **All four required fields — `tool`, `config_path`, `when_to_run`, `output_dir` — are
      scalars, so each counts as present only with a value that is non-empty and not
      comment-only.** `  tool:` on its own, or `  tool: # TODO`, resolves to nothing at
      runtime, and reporting it as configured would hide a stub the wizard then never offers
      to repair: count it MISSING. A value with a TRAILING comment (`  tool: stryker.net`
      followed by `# pinned` on the same line) is a real value and counts as present.

   **Retained lesson — the `grep -c` exit-1 trap** (PR #61 automated-review round 2 finding
   3326891700). Recorded here because other toolbox scripts cite this file as where it is
   written down (`scripts/selfimprovement-backlog.sh` names the same trap and points here):
   `grep -c` prints `0` AND exits 1 when there are no matches, so `|| echo 0` after it appends
   a SECOND `0`, the variable becomes the two-line string `0\n0`, and any later numeric test
   mis-branches. The fix is `|| true` (drops the non-zero exit without writing anything) plus
   `${VAR:-0}`. Nothing in this sub-step shells out any more — this is a standing constraint
   on any shell a future change adds here, not a description of current code.

   Branch on the result:

   - **No header found** → proceed to Step 2 (full wizard).
   - **Two or more `mutation_testing:` headers** (AMBIGUOUS) → the file is ALREADY ambiguous, so nothing about it can be reported as configured and no automated merge is safe. Display the "two headers" message below, SKIP this sub-step — do not ask the Step 2 question and do not write.
   - **Header present AND all 4 required fields present as direct children, each with a usable value** → display the "already configured" message below and SKIP the wizard.
   - **Header present BUT one or more fields missing** — absent entirely, present only inside a nested map rather than as a direct child of the header, or typed with no usable value (a stubbed `  tool:` or a comment-only `  tool: # TODO` counts as MISSING, not present) → display the "partial block detected" message below, then RESUME the wizard, asking ONLY for the missing fields. Reuse the existing field values for the ones that ARE present. Write the merged block back (Step 5 update, not append).

   Display when the file has two headers:

   ```
   ⚠️  .claude/PROJECT.md has TWO `mutation_testing:` keys. Which one applies is
       YAML-parser dependent, so nothing can be reported as configured and no
       merge is safe. Delete the duplicate block, then re-run /init.
   ```

   Display when fully configured:

   ```
   ℹ️  Mutation testing already configured for this project:
       Tool: <tool from PROJECT.md>
       Policy: <when_to_run from PROJECT.md>
   To change, edit .claude/PROJECT.md directly.
   ```

   Display when partial:

   ```
   ⚠️  Mutation testing block is partial — missing: <list of missing fields>
       Resuming the wizard to fill in only the missing values. Existing
       values will be preserved; nothing will be overwritten without asking.
   ```

   This handles the "partial block" gap (PR #61 automated-review round 1 finding 3326820492): a hand-edited PROJECT.md containing only `mutation_testing:` with no fields, or a block missing one or two fields, would previously satisfy the simple grep and prevent `/init` from repairing it. Now `/init` detects the partial state, surfaces it, and runs only the missing-field portion of the wizard. The wizard does NOT overwrite existing values without asking — partial blocks are MERGED, not replaced.

   **Step 2 — Ask via AskUserQuestion** (single question, 4 options, default = Skip — keep default-on):

   ```
   Question: "Mutation testing is ON by default for tickets that create unit tests. Do you want to OVERRIDE that for this project? (Most projects keep the default and pick Skip.)"
   Header: "Mutation testing"
   Options:
     - "Skip — keep default-on (recommended)" — exit this sub-step, nothing written; default-on behaviour applies
     - "Pin a tool, run on every applicable ticket" — sets when_to_run: before_pr (same as default but pins the tool, skips auto-detect)
     - "Restrict to test-coverage PRs only" — sets when_to_run: test_only_prs
     - "Opt OUT — run only when I manually invoke" — sets when_to_run: manual
   ```

   If the user picks `Skip — keep default-on` → exit the wizard, write nothing, continue to sub-step 2.

   **Step 3 — Auto-detect the stack** (only runs if user picked any `Yes` option). Probe the working tree from repo root, depth ≤ 4. **Use these EXACT Bash commands — do NOT improvise** (the rest of `/init` uses precise Bash invocations; this wizard follows the same pattern so behavior is deterministic across agents):

   ```bash
   # Source-stack signals (NOT test projects). Exclude *Tests*.csproj /
   # *Test.csproj so we don't double-count a .NET test project as a source
   # stack signal — the test-project find happens later if user picks
   # stryker.net at Step 4.
   find . -maxdepth 4 -name "*.csproj" \
     ! -name "*Tests*.csproj" ! -name "*Test.csproj" \
     -not -path '*/node_modules/*' 2>/dev/null

   # JS/TS package signal
   find . -maxdepth 4 -name "package.json" \
     -not -path '*/node_modules/*' 2>/dev/null

   # Scala/SBT signal
   find . -maxdepth 4 -name "build.sbt" \
     -not -path '*/node_modules/*' 2>/dev/null

   # Scala source evidence (required before selecting scala-sbt)
   find . -maxdepth 4 -type f \( -name "*.scala" -o -name "*.sc" \) \
     -not -path '*/node_modules/*' 2>/dev/null
   ```

   For each found `package.json`, inspect devDeps + dependencies to confirm the JS stack:

   ```bash
   # Returns the list of devDep + dep names from package.json (use the
   # closest package.json to repo root; if multiple, take the one at
   # the shallowest depth)
   jq -r '(.devDependencies // {}) + (.dependencies // {}) | keys | .[]' \
     <path-to-package.json> 2>/dev/null
   ```

   Apply the detection rules to the find/inspect results:

   - `*.csproj` find returned ≥1 hit → candidate: `stryker.net`
   - `package.json` find returned ≥1 hit AND its devDeps include `typescript` OR a `tsconfig.json` is present at the same dir → candidate: `stryker.js`
   - `build.sbt` and at least one nearby `*.scala`/`*.sc` file found → candidate: `scala-sbt`
   - `package.json` find returned ≥1 hit AND its devDeps include any of: `vitest`, `jest`, `mocha`, `jasmine`, `karma`, `cucumber`, `@stryker-mutator/tap-runner` → candidate: `stryker.js`
   - `build.sbt` find returned ≥1 hit AND a Scala source file exists nearby → candidate: `scala-sbt`

   Collect the set of candidates. **Ambiguity rule**:
   - 0 candidates → fall through to Step 4 with NO auto-detect label on any option (user picks from the bare 3-option menu)
   - 1 candidate → that's the suggested pick (label it "(auto-detected)" in Step 4)
   - 2+ candidates (mixed-stack repo) → label EACH detected candidate "(auto-detected)" in Step 4; non-detected options are still shown (without the label) so the user can override. NEVER silently pick on multi-candidate — always ask.

   **Step 4 — Confirm tool via AskUserQuestion** (always asked, even with 1 candidate — auto-detect SUGGESTS, user CONFIRMS to prevent silent wrong-guess):

   ```
   Question: "Which mutation-testing tool? (auto-detected picks labelled below)"
   Header: "Tool"
   Options (always show all 3 in this order):
     - ".NET — Stryker.NET" → stryker.net           [add " (auto-detected)" suffix if .NET in Step 3 candidate set]
     - "TypeScript/JS — Stryker.JS" → stryker.js    [add " (auto-detected)" suffix if JS/TS in Step 3 candidate set]
     - "Scala/SBT — Stryker4s" → scala-sbt           [add " (auto-detected)" suffix if Scala/SBT in Step 3 candidate set]
   ```

   **Always display ALL 3 options.** The "(auto-detected)" suffix is purely informational — it tells the user which option(s) the toolbox thinks matches their project. The user CAN pick any option, even one without the label, to override (e.g. setting up Stryker for a stack the toolbox didn't detect, or forcing a specific tool on a multi-stack repo).

   For a multi-candidate result (e.g. mixed .NET + JS monorepo), MULTIPLE options carry the "(auto-detected)" label simultaneously. The user picks one — the wizard supports only ONE `mutation_testing` block per project. If the user truly needs both, they must set up the second tool manually or via a follow-up `/init` run (Step 1 idempotency would skip, but they can delete the existing block and re-run).

   **Step 5 — Write the `mutation_testing` block to `.claude/PROJECT.md`.** Two distinct paths based on Step 1's idempotency outcome:

   - **Fresh write (no existing block):** Append the full block to the end of `.claude/PROJECT.md`.
   - **Partial-block merge (Step 1 detected a header with at least one field missing):** Do NOT append a second block — that would leave two top-level `mutation_testing:` keys in the file, making downstream YAML parsing ambiguous (PR #61 automated-review round 2 finding 3326891715). Instead, MERGE the new field values into the existing block:
     1. Identify the line range of the existing `mutation_testing:` block (header line through the last direct-child field) **from the Step 1 read** — the agent has already read the file, so there is nothing to re-parse here. Do not reach for `awk`: Step 1 of this sub-step forbids a shell/awk YAML parser for exactly the reasons recorded there, and a merge that re-derives the range with a second, weaker parser inherits every defect that one was deleted for.
     2. For each of the four required fields, replace the existing line if present, or insert it under the header if absent. Existing values that the wizard didn't ask about (because Step 1 detected them as already present) are PRESERVED — never overwritten.
     3. Write the merged block back in place. The block remains a single top-level key.
     4. If the in-place replacement is too brittle on a particular PROJECT.md (e.g. the block has unusual comments or formatting that the merge can't preserve safely), surface a fallback message: "Could not safely merge the partial block — please edit `.claude/PROJECT.md` manually. The complete block should contain: tool=<X>, config_path=<Y>, when_to_run=<Z>, output_dir=<W>." This is a defensive fall-back, not the expected path.

   **Ordering note:** Sub-step 1c appears before sub-step 2 in the list, but the file write in this step must run AFTER sub-step 2 has created `.claude/PROJECT.md`. Execution order: (a) run Steps 2-4 of this wizard to collect user answers now, (b) continue to sub-step 2 (which creates PROJECT.md if it doesn't already exist; partial-block merge is the path for projects where PROJECT.md exists with an incomplete block), (c) execute the appropriate write path at that point. Hold the user's choices in the orchestrator's working context between collection and write — do not write to a file that doesn't exist yet. If sub-step 2 fails to create PROJECT.md (e.g. read-only filesystem), skip Step 5 and surface a warning: "Mutation testing answers collected but PROJECT.md could not be created. Add the `mutation_testing` block manually using `examples/PROJECT.md.example` as a template."

   Block format to append (verbatim, no string interpolation from external sources — values come from user choices captured in Steps 2 + 4, which are closed enum sets):

   ```yaml

   # Mutation testing — per-project override written via /init wizard. Edit
   # when_to_run to change the policy. Delete the entire block to revert to
   # the global default-on behaviour (Stryker runs on tickets that create
   # unit tests, no project config required).
   mutation_testing:
     tool: <user choice from Step 4>
     config_path: <tool-specific default — see below>
     when_to_run: <user choice from Step 2>
     output_dir: <tool default — see below>
     guardrail: "no production code changes"
   ```

   Tool-specific defaults (substitute these literal values based on Step 4 choice):

   | tool | config_path | output_dir |
   |---|---|---|
   | `stryker.net` | `stryker-config.json` | `StrykerOutput` |
   | `stryker.js` | `stryker.config.mjs` | `reports/mutation` |
   | `scala-sbt` | `build.sbt` | `target/stryker4s` |

   **Step 6 — Auto-generate the minimal config file at the project root** (skip if it already exists — never overwrite user content). Per-tool templates:

   **For `stryker.net` — write `stryker-config.json` at project root:**

   ```json
   {
     "stryker-config": {
       "test-runner": "dotnet",
       "reporters": ["html", "json", "progress"],
       "thresholds": { "high": 80, "low": 60, "break": 0 }
     }
   }
   ```

   **For `stryker.js` — write `stryker.config.mjs` at project root.** The template is ADAPTIVE — detect the test runner and package manager from the project before writing (mirrors `commands/flow.md` Step 11b Step 4 adaptive logic):

   - Read `package.json` `devDependencies` (or `dependencies`): if `vitest` present → `testRunner: 'vitest'`; if `jest` → `testRunner: 'jest'`; if `mocha` → `testRunner: 'mocha'`; same for `jasmine` / `karma` / `cucumber` / `@stryker-mutator/tap-runner`.
   - If multiple match (uncommon) → AskUserQuestion to pick one — never silently guess.
   - **If NO supported runner is found in devDeps** (the realistic case for: a root `package.json` that's only a workspace manifest in a Yarn/pnpm monorepo; a project using a runner not in the supported list like `ava`/`tap`/`uvu`; a brand-new project still being set up) → AskUserQuestion: "No supported test runner found in package.json devDeps. Which test runner does this project use?" with options: `jest`, `vitest`, `mocha`, `Other (skip auto-config — I'll configure stryker.config.mjs manually)`. If the user picks `Other`, SKIP the auto-generated config file (do not write `stryker.config.mjs` with an unresolved or guessed runner — that would create a broken-by-default state). Surface a note in Step 7 confirmation: "Auto-config file skipped — please create `stryker.config.mjs` manually. See https://stryker-mutator.io/docs/stryker-js/configuration/ for the supported testRunner values." Do NOT silently default to any runner — a wrong runner causes Stryker to fail immediately at run time, which is worse than no auto-config. (PR #61 automated-review round 1 finding 3326820500.)
   - For `packageManager`, check lockfiles at the current working directory **in this precedence order** (first match wins): `yarn.lock` → `'yarn'`; then `pnpm-lock.yaml` → `'pnpm'`; then `package-lock.json` → `'npm'`. Yarn wins over pnpm wins over npm because yarn.lock + package-lock.json sometimes coexist during migrations, and yarn.lock is the stronger signal of intentional yarn use.
   - **If NO lockfile is found at root** (common in mid-setup projects, or monorepos run from a workspace subdirectory where the lockfile is at the repo root one level up), do NOT silently default to npm — that would write the wrong `packageManager` for yarn/pnpm projects and Stryker would fail at runtime. Instead, AskUserQuestion: "No lockfile found at the current directory. Which package manager does this project use?" with options `npm` / `yarn` / `pnpm`. The default is `npm` (correct for the most-common case), but the user gets a chance to override.
   - **Monorepo caveat:** detection is root-only at the current working directory. If `/init` is run from a workspace subdirectory of a Yarn workspaces / pnpm workspaces monorepo, the root-level lockfile is one level up and won't be found by this check — the AskUserQuestion fallback above catches this. Same caveat applies to the rest of sub-step 1c's stack auto-detection (Step 3): root-only at depth ≤ 4. Users in deep monorepo nesting should run `/init` from the repo root.
   - Substitute `<RUNNER>` and `<PKGMGR>` placeholders in the template below before writing:

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

   **For `scala-sbt`** — keep the existing `build.sbt` and Stryker4s project configuration. The toolbox runs the registered `sbt stryker` task from the selected SBT project; it does not rewrite build files.

   **Scala/SBT safety condition:** if the user selects `scala-sbt` but Step 3 did not find an existing `build.sbt` and nearby Scala source evidence, do not write the `mutation_testing` block. Show this manual-setup warning instead:

   > Scala/SBT was selected, but no existing `build.sbt` with nearby Scala sources was found. I did not write a mutation-testing block that points at a missing build file. Add or select a valid SBT project, then rerun `/init`.

   **Step 7 — Confirmation message** showing what was set up (substitute the actual tool / policy / config-path / output-dir values from the user's choices):

   ```
   ✅ Mutation testing enabled for this project:
   - Tool: <pretty-name>, e.g. Stryker.NET (dotnet stryker)
   - Policy: <when_to_run>, e.g. test_only_prs (runs on test-coverage tickets only)
   - Config: <config_path> (created at project root — edit anytime)
   - Output: <output_dir>/ (already gitignored by /init sub-step 1b)

   Per-ticket override still works: the Mutation testing field in the
   confirmation summary will reflect this project's default policy
   (<when_to_run> from PROJECT.md). Individual tickets can still
   override the field per-ticket to opt out or change behaviour.

   You can edit .claude/PROJECT.md anytime to change the policy or remove
   the entire mutation_testing block (which reverts to the global
   default-on behaviour — Stryker runs by default on tickets that create
   unit tests, no project config required).
   ```

   **Note on the per-ticket field default:** mutation testing is ON by default toolbox-wide — with NO `mutation_testing` block, the `/start` / `/flow` field defaults to `Yes — auto-detect tool at verification (recommended)` and `/flow` Step 11b auto-skips tickets that can't have unit tests. How `/start` translates a PROJECT.md `when_to_run` value when the block IS present is documented in `commands/start.md` Field [12]/[14] section. Briefly: `when_to_run: before_pr` → `Yes` pinned to `mutation_testing.tool` if set (no auto-detect), else `Yes — auto-detect` (`tool` is optional); `test_only_prs` → `No` at `/start`, promoted to `Yes` at Verification if the ticket is test-only; `manual` → `No` (project explicitly opts OUT of default-on). Either way, the user can override per-ticket.

   **Edge cases:**

   - `.claude/PROJECT.md` not yet created at sub-step 1c time → sub-step 1c CAPTURES the user's answers but defers the append until after sub-step 2 has created the file. The append happens in the same `/init` run, just sequenced correctly.
   - User picks `Yes` but auto-detection finds 0 stack candidates (no `.csproj`, `package.json`, or `build.sbt`) → Step 4 still asks them to pick a tool (without auto-detect label). If they pick a tool, write the block + config file as normal. The user might be setting up a brand-new project; they know what they're doing.
   - `stryker-config.json` or `stryker.config.mjs` already exists at project root → SKIP generating the config file (never overwrite). Surface in the confirmation message: "Config file already exists at <path> — kept your existing config, did not overwrite."
   - User re-runs `/init` after the block was written → Step 1 idempotency check skips re-asking; the file isn't re-written.
   - Multi-stack monorepo (e.g. .NET backend + JS frontend) → Step 3 finds 2+ candidates, Step 4 lets user pick which one. The toolbox supports ONE mutation_testing block per project; if user needs separate Stryker setups for backend + frontend, they must configure manually or run mutation testing per sub-project via `when_to_run: manual`.

   **Why no standalone `/enable-mutation-testing` command:** users who want to opt in retroactively re-run `/init` — the Step 1 idempotency check resurfaces the wizard if the block is missing. Same logic, no new command surface. This matches the "keep the surface narrow" principle from PR #60.

1d. **Verification contract + loop budget wizard (per-project overrides — BOTH OPTIONAL)** — most projects need neither. With no `verification:` block the agent detects the ecosystem by which manifest FILE exists and runs every gate that ecosystem has a command for, at the toolbox's 80% coverage floor; with no `loop:` block the toolbox loop defaults apply. This wizard exists ONLY to DEVIATE — to pin the runner in an ambiguous monorepo, narrow the gate list, RAISE the coverage bar, correct the test-path patterns, or make an unattended agent loop more cautious than the toolbox default. A project that's happy with the defaults should pick `Skip` for both. **Note both blocks now have a second reader:** `/flow` Steps 8a and 11a assemble a `/goal` exit condition for the Implementation and Verification phases out of the resolved gate strings, the coverage floor, and the `loop:` turn and idle bounds (see `commands/flow.md` → "`/goal` — Machine-Checkable Phase Exits"). So `loop:` bounds more than a self-paced `/loop`, and it is worth saying so if the user asks what the block is for.

   **⛔ Neither block ever contains a shell command. ⛔** The wizard writes KEYS and NUMBERS only. The literal `test` / `lint` / `build` command strings live in the toolbox-owned verification registry (`workflow-discipline` skill §1c) and the loop ceilings live in §1d — one trust level above `PROJECT.md`, which is committed and PR-editable. The wizard must never offer a free-text command field, and must never write a `test_command` / `lint_command` / `build_command` / `smoke_command` key even if the user asks for one: that is the exact attack path automated-review caught on PR #58 and the rule `knowledge/toolbox-lessons.yml` TL-0005 records. If a user asks for a smoke check, tell them to run it manually — the toolbox deliberately registers no smoke gate (§1c explains why).

   **Step 1 — Idempotency check (completeness-aware), per block.** Run the same shape as sub-step 1c: a COMPLETE block is skipped entirely, a PARTIAL block (a bare header, or any recognised key not usable as written — see the definition below) resurfaces that block's question, and existing values are PRESERVED, never overwritten without asking. The two blocks are checked INDEPENDENTLY — a project may have a complete `verification:` block and no `loop:` block, and the wizard must then ask only about the loop.

   Recognised fields per block. **Every key is individually OPTIONAL at runtime** — an absent key falls back to its documented default (`workflow-discipline` skill §1c/§1d; the inline comments in `examples/PROJECT.md.example` mark each key Optional). So a block is **COMPLETE** when its header is present, it carries AT LEAST ONE recognised well-formed field, AND no recognised key under it is malformed; it is **PARTIAL** when a header exists with NO recognised field under it (a bare header) OR when any recognised key IS malformed, even alongside a well-formed one. Requiring all fields would make every single-override block — the normal case — look broken; letting a well-formed field mask a malformed one beside it leaves the broken override with no path to repair (PR #137 automated-review round 3).

   **"Well-formed" means the value resolves, not just that the key is typed.** A recognised key whose value is EMPTY (`  max_turns:` with nothing after it), or outside its Step 3 closed set / not a positive number (`  runner: unknown`, `  coverage_floor: high`, `  max_turns: 0`), does NOT count towards COMPLETE. At runtime an unknown `runner` fails CLOSED — `workflow-discipline` skill §1c has the agent run NO gate at all and report the unrecognised key — and §1d treats a zero or negative bound as ABSENT, so the toolbox default silently applies (a non-numeric bound has no defined clamp either, so it can only default too). Reporting such a block as "already configured" would hide a broken override the wizard then has no path to repair, so name the offending key AND its value in the warning and treat the block as PARTIAL: the question is re-asked and the answer merged.

   | Block | Recognised fields (each optional) |
   |---|---|
   | `verification:` | `runner`, `gates`, `coverage_floor`, `test_globs` |
   | `loop:` | `max_turns`, `no_progress_after`, `max_spend_usd` |

   **Detection is a READ, not a parse. ⛔ Never write a shell/awk YAML parser here. ⛔**

   `/init` is a command file and this step is an INSTRUCTION the agent follows, not a script
   that must run standalone: open `.claude/PROJECT.md`, read it, and classify each block by
   the rules below. A ~40-line bash/awk extraction used to sit here. It took FOUR fixes inside
   one PR (awk range semantics, value-presence + closed-set validation, duplicate-header
   ambiguity, quoted and empty list items) and automated-review then filed FIVE MORE defects against
   it, every one another YAML shape it read wrong: a nested map's field counted as the block's
   own, a column-0 comment truncating the block, nested list content marking `gates`
   configured, a blank line making a sequence look empty, and a valid field masking a
   malformed one beside it. The mechanism was the defect — a YAML parser of that size cannot
   be made correct in shell, and each patch bought another review round — so it was removed.
   **A future editor must not reintroduce one**: if this step needs to know what the YAML
   says, read the YAML.

   Classify `verification:` and `loop:` INDEPENDENTLY, applying ALL FIVE rules to each:

   1. **The header must be a top-level key, at column 0.** `verification:` and `loop:` are
      top-level PROJECT.md keys, so an indented (nested) header is NOT the contract runtime
      reads and counts as ABSENT — otherwise the wizard reports "already configured" off
      values nothing resolves, and the Step 4 read-back passes off a block the write never
      created. Two or more column-0 headers for the same block is AMBIGUOUS (outcomes table
      below).
   2. **A field belongs to the block only if it is a DIRECT child of the block header — one
      nesting level under it, never deeper.** `verification:` → `  unrelated:` →
      `    runner: dotnet` sets `unrelated.runner`: YAML resolves it there, runtime never
      sees it, so it does NOT count as this block's `runner`. The same holds for lists — a
      `- item` counts for `gates:` / `test_globs:` only when it is that key's own sequence
      item, never an item nested under some other key inside the block.
   3. **A comment line or a blank line does not end the block.** A column-0 `# …` between the
      header and its fields is valid YAML and everything after it still belongs to the block;
      the block ends at the next top-level KEY, or at end of file. A blank line inside a
      sequence does not end the sequence either: `gates:`, a blank line, then `  - test` is
      the list `[test]` — not an empty key.
   4. **A field is SET only when its value is PRESENT and matches the documented closed set or
      shape for that key.** A key typed with no value at all (`  runner:`, or `  gates:` /
      `  test_globs:` with no item under them), and a comment-only value (`  runner: # TODO`),
      resolve to nothing at runtime — record those as `<key>=(empty)`. Otherwise:
      - `runner` — exactly one of the 10 registry keys: `auto`, `dotnet`, `maven-wrapper`,
        `maven`, `gradle-wrapper`, `gradle`, `node-pnpm`, `node-yarn`, `node-npm`, `python`.
      - `gates` — a non-empty subset of `test` / `lint` / `build`, in EITHER flow form
        (`gates: [test, lint]`, what Step 4 writes) or block-sequence form (`gates:` then one
        `- test` per line). Both are the same YAML list. An item may be QUOTED in either form
        (`- "test"`, `["test", "lint"]`) and is the same value unquoted; an empty item
        (`["", test]`) is malformed, not silently dropped.
      - `test_globs` — SET when the key carries at least one sequence item (Step 4 writes it
        as a block sequence: `test_globs:` then one `- <pattern>` per line; items may be
        quoted). Its items are PATH patterns, not a closed set, so this step does NOT validate
        their content — the narrow-only clamp in the `workflow-discipline` skill §1c does that
        at match time. This asymmetry with `gates` is deliberate.
      - `coverage_floor` — a positive integer.
      - `max_turns`, `no_progress_after`, `max_spend_usd` — positive numbers.
      Anything else is MALFORMED, recorded with the key AND the value exactly as written.
      Why the closed set decides rather than key presence: an unrecognised `runner` fails
      CLOSED at runtime (`workflow-discipline` skill §1c has the agent run NO gate at all and
      report the unrecognised key), and §1d treats a zero or negative bound as ABSENT so the
      toolbox default silently applies — `max_turns: 0` is not a tighter cap and must never be
      reported back to the user as one.
   5. **A malformed field is NAMED even when other fields in the same block are well-formed —
      a valid field never masks it.** A `verification:` block holding `runner: dotnet` beside
      `coverage_floor: high` is NOT "already configured": the floor is ignored at runtime, and
      the deleted parser's "at least one well-formed field ⇒ configured" branch meant the user
      was never offered a repair (PR #137 automated-review round 3). One malformed key makes the whole
      block PARTIAL.

   The four outcomes those rules produce, one per block:

   | Outcome | When |
   |---|---|
   | **ABSENT** | no column-0 header for that block (an indented header included) |
   | **AMBIGUOUS** | two or more column-0 headers for that block |
   | **COMPLETE** | header present, at least one field SET, and no recognised key EMPTY or malformed |
   | **PARTIAL** | header present, and either no field SET or ANY recognised key EMPTY or malformed |

   Branch per block:

   - **ABSENT** (no column-0 header for that block — an indented/nested header counts as absent, because it is not the top-level key runtime reads) → ask that block's question in Step 2 and write a real top-level block. Never report a nested header as configured.
   - **AMBIGUOUS** (two or more column-0 headers for the same block) → the file is ALREADY ambiguous, so nothing about it can be reported as configured and no automated merge is safe. Surface it with the same message as the Step 4 read-back duplicate case below, tell the user to delete the duplicate, and SKIP that block — do not ask its question and do not write.
   - **COMPLETE** (at least one field SET and NO recognised key empty or malformed) → display "already configured", listing the fields that ARE set and naming the unset ones as "using the toolbox default"; skip that block.
   - **PARTIAL** (a bare header, or ANY recognised key empty / outside its closed set — including when a well-formed field sits right beside it) → display the repair banner below, naming EACH malformed key and its value, then ask that block's Step 2 question and MERGE the answers under the EXISTING header — never append a second header (two top-level keys of the same name make downstream YAML parsing ambiguous — the same defect PR #61 automated-review round 2 finding 3326891715 raised for `mutation_testing`).

   Display when the block is configured — only the keys actually present are listed, and a key
   the user never chose is shown as `default`, because its absence is the intended
   configuration rather than a gap:

   ```
   ℹ️  Verification contract already configured: runner=<runner>, gates=default, coverage floor=<floor>, test_globs=default
   ℹ️  Loop budget already configured: max_turns=<turns>, no_progress_after=default, max_spend_usd=<usd>
   To change either, edit .claude/PROJECT.md directly.
   ```

   Display when the block is PARTIAL — a bare header, or any recognised key not usable as
   written. The first line always appears; one `Not usable as written:` line follows PER
   malformed key, naming the key and its value so the user can see WHY a block they thought
   was configured is being re-asked. A bare header has no malformed key, so it shows the
   first line alone:

   ```
   ⚠️  <verification|loop> block needs repair — asking the block's question and
       merging under the existing header. Nothing is overwritten without asking.
       Not usable as written: <block>.<key> <is set to `<value>` | is typed with
       no value>, so it is not <a registry key | a subset of [test, lint, build]
       | a positive number | a non-empty list of path patterns>.
   ```

   Display when the same block has two top-level headers — one message, shared with the Step 4
   read-back duplicate case, because it is the same problem found at a different moment:

   ```
   ⚠️  .claude/PROJECT.md has TWO top-level `<verification|loop>:` keys. Which one
       applies is YAML-parser dependent, so nothing can be reported as configured
       and no merge is safe. Delete the duplicate block, then re-run /init.
   ```

   **Step 2 — Ask via AskUserQuestion.** Two questions, each defaulting to Skip. Ask the second only if Step 1 didn't already skip it.

   ```
   Question 1: "The agent can detect your test/lint/build commands automatically from your manifest files. Do you want to OVERRIDE that for this project? (Most projects keep auto-detection and pick Skip.)"
   Header: "Verification"
   Options:
     - "Skip — keep auto-detection (recommended)" — exit; nothing written
     - "Pin the runner (ambiguous monorepo)" — asks which registry key, then writes the block
     - "Raise the coverage floor above 80%" — asks for the integer, then writes the block
     - "Pin the runner AND raise the floor" — asks both
     - "Narrow the gate list" — asks which of test/lint/build
     - "Correct the test-path patterns" — asks for test_globs
   ```

   ```
   Question 2: "These numbers bound any unattended agent loop — a self-paced /loop tending your open PRs, and the /goal exit conditions /flow sets inside its Implementation and Verification phases. Do you want to bound them MORE TIGHTLY than the toolbox default (max 25 turns, stop after 2 idle iterations, $2.00 cap)?"
   Header: "Loop budget"
   Options:
     - "Skip — keep the toolbox defaults (recommended)" — exit; nothing written
     - "Tighter turn + spend cap" — asks for max_turns and max_spend_usd
     - "Stop sooner when idle" — asks for no_progress_after
     - "Set all three" — asks for all three
   ```

   **Step 3 — Constrain every answer to a closed set or a number. NO free text reaches the file.**

   - `runner:` — offer the registry keys as AskUserQuestion options, labelling any whose `detect:` manifest is present at the project root as "(auto-detected)". Valid options are exactly: `auto`, `dotnet`, `maven-wrapper`, `maven`, `gradle-wrapper`, `gradle`, `node-pnpm`, `node-yarn`, `node-npm`, `python`. Never accept a typed runner name that isn't on that list — an unknown key fails closed at runtime anyway, so writing one just produces a broken config.
   - `gates:` — a subset of `[test, lint, build]`, presented as options. Never a typed string.
   - `coverage_floor:` — an integer. **Tell the user the raise-only clamp before writing:** "The effective floor is max(80, your value) — `rules/testing.md` guarantees 80% toolbox-wide, so a lower number is kept in the file and ignored at runtime." If the user asks for a number below 80, write it if they insist but repeat the clamp, and do NOT pretend it will take effect.
   - `test_globs:` — offer the defaults for the resolved runner and let the user confirm or extend. These are PATHS, matched against changed files, never executed.
   - `max_turns` / `no_progress_after` / `max_spend_usd` — numbers. **Tell the user the tighten-only clamp before writing:** "The effective value is min(your value, toolbox ceiling) — the ceilings live in the `workflow-discipline` skill §1d, not in PROJECT.md, so a project can make a loop more cautious but can't raise its budget." A value at or below zero is treated as ABSENT at runtime (the default applies), so warn rather than writing `0`. **Be honest about what `max_spend_usd` reaches:** it binds through the native `--max-budget-usd`, which is set when a run is LAUNCHED as a loop. A `/goal` set inside an interactive `/flow` phase has no such flag, so there `max_turns` and `no_progress_after` are the only hard bounds — don't tell the user the dollar cap covers it.

   **Step 4 — Write the blocks to `.claude/PROJECT.md`, then READ THEM BACK.**

   Two write paths, matching sub-step 1c:

   - **Fresh write** (no existing header for that block) → append the block.
   - **Partial merge** (header present, fields missing) → identify the block's line range from the Step 1 read, replace present fields in place, insert absent ones under the header, and keep it a SINGLE top-level key. If the merge can't be done safely (unusual comments or formatting), surface the fallback: "Could not safely merge the partial `<block>` block — please edit `.claude/PROJECT.md` manually. The complete block should contain: `<field>=<value>` …".

   **⛔ Read-back verification is mandatory — do not assume the write landed. ⛔** Sub-step 1c has no read-back, and a silently failed write there looks identical to success: the wizard prints its confirmation, the user believes the project is configured, and the override quietly never applies. Re-run the Step 1 detection after writing and require EVERY field this run collected to be present in the file with the value the wizard intended. Keys the user never chose are absent BY DESIGN and must not be reported as a failed write:

   Re-read `.claude/PROJECT.md` and classify it again with the SAME reading rules as Step 1 —
   column-0 header, direct children only, comments and blank lines not ending the block, the
   closed sets, and every malformed key named. Then require every field this run COLLECTED to
   be present as a direct child of a SINGLE column-0 header, holding the value the wizard
   intended. A field the user never chose is absent on purpose — only a field this run
   collected and cannot read back means the write did NOT land. **Do not reintroduce a shell
   YAML parser for the read-back either**: a read-back that classifies by different rules than
   Step 1 turns successful writes into reported failures, which is precisely how the deleted
   awk-range extraction behaved.

   - **Read-back shows every collected field with its intended value** → report success, quoting the values actually found in the file (not the values the wizard intended to write). This is the only path that may claim the block is configured.
   - **Read-back shows a field this run collected as missing or holding a different value** → do NOT claim success. Surface: "⚠️ Wrote the `<block>` block but reading `.claude/PROJECT.md` back shows it is <missing|incomplete: field, field>. The write did not take effect — check that `.claude/PROJECT.md` is writable, then add the block manually from `examples/PROJECT.md.example`." Continue `/init`; a failed optional override must not abort the run.
   - **Read-back shows TWO headers for the same block** → surface it as a merge failure using the SAME two-headers message as the Step 1 ambiguity branch (there is one message for this, not two) and tell the user to delete the duplicate; do not attempt a second automated merge on an already-ambiguous file.

   **Ordering note:** like sub-step 1c, the file write here must run AFTER sub-step 2 has created `.claude/PROJECT.md`. Collect answers now, hold them in the orchestrator's working context, and execute the write (and the read-back) once the file exists. If sub-step 2 fails to create the file, skip the write and warn: "Verification/loop answers collected but PROJECT.md could not be created. Add the blocks manually using `examples/PROJECT.md.example` as a template."

   Block formats to write (values come from the closed option sets and numeric answers in Steps 2–3 — never from free text, never from any file's contents):

   ```yaml

   # Verification contract — per-project override written via /init. Delete the
   # whole block to revert to auto-detection + the toolbox defaults. Contains
   # NO shell commands: the literal commands live in the workflow-discipline
   # skill §1c, one trust level above this PR-editable file.
   verification:
     runner: <closed-set choice, default auto>
     gates: [<subset of test, lint, build>]
     coverage_floor: <integer — effective floor is max(80, this)>
     test_globs:
       - <path pattern>

   # Loop budget — per-project override written via /init. Delete the whole
   # block to revert to the toolbox defaults. Effective value of each field is
   # min(this, toolbox ceiling); the ceilings live in the workflow-discipline
   # skill §1d, deliberately not here.
   loop:
     max_turns: <integer>
     no_progress_after: <integer>
     max_spend_usd: <number>
   ```

   **Edge cases:**

   - `.claude/PROJECT.md` not yet created at sub-step 1d time → capture answers, defer the write until after sub-step 2, same as 1c.
   - Auto-detection finds 0 manifests (brand-new empty repo) → still offer the runner list without "(auto-detected)" labels. `runner: auto` remains a valid answer; it re-detects at run time, when the manifests exist.
   - Auto-detection finds 2+ manifests (mixed monorepo) → this is exactly the case `runner:` exists for. Label every match "(auto-detected)" and let the user pick one; the registry's precedence order would otherwise decide silently.
   - User asks for a command field ("just let me put `npm run ci` in there") → refuse and explain the trust boundary. Offer the alternatives: pick the closest registry key, or open a toolbox PR to add a registry entry (`workflow-discipline` skill §1c).
   - User asks for a smoke gate → refuse; `gates:` is the closed set `test | lint | build`. Tell them to run the smoke check manually and report the result (§1c has the rationale).
   - User re-runs `/init` after both blocks were written → Step 1 skips both; nothing is re-asked and nothing is re-written.
   - `.claude/PROJECT.md` is read-only → the write fails, the read-back catches it, and the warning above fires. `/init` continues.

   **Why no standalone `/configure-verification` command:** same reasoning as sub-step 1c — a user who wants to opt in later re-runs `/init`, and the Step 1 idempotency check resurfaces only the missing block. No new command surface.

2. **Save to `.claude/PROJECT.md`** — stack (auto-detected), methodology (auto-detected from Jira board type), jira_board, active MCPs, and any project-specific overrides
3. **Save to `~/.claude/memory.md`** — tool, cicd, tracking, jira_url, jira_workflow (personal defaults reused across projects)
4. **Save to `.claude/settings.json`** — `disabledMcpServers` array based on MCP screen selections, PLUS the full permissions array from global settings. **This is critical:** Claude Code has a confirmed bug (#17017) where project permissions REPLACE global permissions instead of merging. If the project settings.json has a permissions section, the global permissions are silently ignored. The project MUST include all permissions it needs:
   ```json
   {
     "permissions": {
       "allow": [
         "Bash",
         "Glob",
         "Read",
         "Write(.claude/**)",
         "Edit(.claude/**)",
         "Edit(.claude/handover.md)",
         "Write(.claude/handover.md)",
         "mcp__seq__*",
         "mcp__context7__*"
       ]
     }
   }
   ```
   Merge these into the existing permissions array — do not overwrite user-added permissions. If `.claude/settings.json` already exists, read it first, merge the `permissions.allow` array (add any entries that aren't already present), then write back.
   
   **Why all these permissions?** Project `permissions.allow` replaces (not merges with) global `permissions.allow`. Without duplicating, the agent loses Bash auto-approval, MCP access, and handover write permissions.

   **Hooks config:** Hooks are now installed globally by `install.sh` (merged into `~/.claude/settings.json`). Per-project hooks config in `.claude/settings.json` is no longer required — hooks are active in every project by default. If the project needs to override or disable specific hooks, it can add a `hooks` section to its `.claude/settings.json`.
5. **Initialize Beads (if selected):** If the user selected "Jira + Beads" or "Beads only" in Q4, check if `.beads/` exists:
   ```bash
   Bash(ls .beads/ 2>/dev/null && echo "ALREADY_INITIALIZED" || echo "NOT_INITIALIZED")
   ```
   - If NOT_INITIALIZED: run the `bd init` the gitignore pre-check script in the **`workflow-discipline` skill** (§ "Gitignore pre-check") (verify `.beads/`, `AGENTS.md`, `CLAUDE.md`, `.claude/`, `ai-engineering/` are in `.gitignore` AND none are already tracked by git). Only if the pre-check passes, run `Bash(bd init)` to create the `.beads/` directory. If the pre-check fails (missing `.gitignore` entries or tracked files found), warn the user and do NOT run `bd init` — for missing gitignore entries the pre-check adds them automatically; for tracked files the user must run `git rm --cached` first
   - If ALREADY_INITIALIZED: skip silently
   - If `bd` is not installed: warn "Beads CLI (bd) is not installed. Run `brew install beads` or see https://github.com/steveyegge/beads"

   **Configure local-only mode (default):** After `bd init`, disable remote backup and auto-push to keep beads purely local. This prevents the common "dolt auto-push failed: unknown push error" warnings on repos without a dolt remote configured:
   ```bash
   # Add backup-disabled config to .beads/config.yaml
   Bash(cat >> .beads/config.yaml << 'EOF'

# Local-only beads tracking — no remote sync, no backup warnings
backup:
  enabled: false
  git-push: false
EOF
   )

   # Remove any auto-created dolt remote (bd init may set origin from git)
   Bash(cd .beads/embeddeddolt/$(basename $(pwd) | tr '-' '_') && dolt remote remove origin 2>/dev/null; cd -)
   ```

   **If the user wants cross-machine sync:** They can enable it manually later by editing `.beads/config.yaml` and setting `backup.enabled: true` + `backup.git-push: true`. Default is local-only for zero-friction setup.
6. **⛔ Do NOT commit anything during `/init`. ⛔**

   `/init` writes files (`.gitignore` additions, `.beads/`, `.claude/PROJECT.md`) but never runs `git add`, `git commit`, or any other write operation against git history. Reasons:
   - Most files `/init` creates are gitignored (`.claude/`, often `.beads/`) so there's nothing meaningful to commit anyway
   - The `.gitignore` modifications themselves ARE meaningful, but `/init` doesn't know what branch the user is on. If they're on `main`, committing would violate `rules/git-workflow.md` "Never commit to main" — and `/init` is the toolbox itself, so the toolbox would be the rule violator
   - Uncommitted files in the working tree are picked up automatically by `/flow` Step 7 when it creates the feature branch from `origin/main` — they ride along onto the new branch and get committed in the first feature commit. No manual step needed.

   **Historical note:** Earlier versions of `/init` (and `/flow` Step 4) auto-committed `.beads/` to whatever branch was current. If the user was on `main`, that put a stray commit on local `main` ahead of `origin/main`, which then required manual cleanup. The current behaviour (write files, don't commit) avoids that.

8. **Print working-tree summary and final guidance:**

   Before printing the success message, run `git status --porcelain` and show the user what `/init` left behind so they can verify nothing unexpected ended up in the working tree:

   ```bash
   Bash(git status --porcelain 2>/dev/null | head -20)
   ```

   Then print the confirmation. If there were any modified or untracked files from `/init`, append the "Working tree" block; otherwise just print the success block.

```
[checkmark] Project configured.

Auto-detected:
  Stack:       Mixed (C# microservices + Blazor frontend)
  Methodology: Kanban -> your main command is /flow

Active agents: Senior PM, Jira Workflow Steward,
               DevOps Automator, Evidence Collector
               (mandatory for Blazor/Radzen UI changes),
               API Tester, Reality Checker,
               Security Engineer

Saved to: .claude/PROJECT.md

Working tree (uncommitted files left by /init):
  M  .gitignore
   ? .beads/                                 (gitignored or new — depends on team setup)
   ? .claude/PROJECT.md                      (gitignored — local config)

  These will be picked up automatically when /flow creates a feature branch
  (Step 7 branches from origin/main, uncommitted files ride along).
  Nothing is committed to main by /init.

Type /start to begin.
```

   The "Working tree" block is informational. The user does not need to run `git add` or `git commit` themselves — `/flow` handles it on the next feature branch. If the user explicitly wants to commit `.gitignore` changes separately (e.g. they're not yet ready to start a ticket), they can do so on a `chore/toolbox-setup` branch, but `/init` does not prompt for this — it stays out of the user's git workflow entirely.

---

## Board Mapping — Deferred Questions

The agent only asks about board mapping when it first needs a board for a specific command type. The answer is saved to `PROJECT.md` and never asked again for this project. Defaults from previous projects are pre-suggested.

**First time the user runs `/bug`:**
```
Where do bug tickets go in this project?
1) Same board as features (DEV board 309)
2) Different board — enter ID or URL
3) Don't use Jira for bugs — use Beads only
```

The same one-time question pattern applies for `/incident`, `/refactor`, and `/security`.

---

## Discovery Column Handling

If Q3 is Board-driven and the Jira board has a Discovery column, the agent asks the first time `/flow` encounters a Discovery ticket:

```
How should the agent handle tickets in your
Discovery column?

1) Investigate and advance  <- recommended
   -> The agent reads the ticket, investigates the
     codebase, writes findings back to the Jira ticket
     as a comment, recommends moving to Ready for
     Development, then starts building immediately
     if you approve.

2) Ask me first
   -> The agent flags Discovery tickets and waits
     for your go-ahead before investigating.

3) Skip Discovery
   -> The agent only picks up tickets in
     Ready for Development.
```

The answer is saved to `PROJECT.md`.

---

## Notes

- Discovery column handling is deferred — it is asked on the first Discovery ticket encountered, not during /init
- All relative dates in saved values must be converted to absolute dates
- The agent must never auto-select answers — always wait for user input
- If the user types `/init` on an already-configured project, ask every question one at a time with the current values shown as defaults. Never show a summary screen to confirm all values at once.
