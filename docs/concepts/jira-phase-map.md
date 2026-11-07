# The Jira Phase Map

The toolbox reasons in **universal phases** (Discovery, Implementation, Code Review) and projects to **per-board columns** only at the API boundary. The mapping between the two is the **phase map** — a contract verified at workflow start, not assumed.

---

## When to Read This

- You're setting up a project on a board with non-default column names
- Your team renamed or restructured the Jira board and `/flow` started behaving oddly
- You're writing a new command that needs to interact with Jira tickets
- You want to understand why `/flow` calls `phase=in_progress` instead of `column=In Progress`

---

## The Two Things You're Mapping

| Concept | Origin | Stable across teams? |
|---|---|---|
| **Phase** (Discovery, In Progress, Code Review, …) | Toolbox-internal — the workflow always runs through these | Yes — same on every team |
| **Column** ("Selected for Development", "Doing", "On Stage", …) | Per-team Jira board configuration | No — every team picks different names |

The toolbox cares about phases (universal). Jira cares about columns (per-board). The phase map is the lookup table that resolves one to the other.

---

## What `jira_phase_map` Looks Like

In `.claude/PROJECT.md`:

```yaml
jira_phase_map:
  discovery: null                          # null = no transition; comments are optional
  ready_for_dev: "Selected for Development"
  in_progress: "In Progress"
  code_review: "In Progress"               # same column reused — natural lump support
  ready_for_release: "Ready for Release"
  done: "Done"
```

Six phase keys, each mapping to either a column name (string) or `null`. Semantics:

- **Quoted column name** → ticket transitions to that column when the phase runs.
- **`null`** → no transition; the phase runs internally and does not create a routine Jira comment. An explicitly requested milestone may mention the current column.
- **Same column reused across keys** → ticket stays put; no routine comment is added. This is how "lump" boards work — Code Review on most boards has no separate column, so `code_review` reuses the `in_progress` column.
- **Missing key entirely** → that phase doesn't execute on this board. Defensive — better to skip than mistransition.

Phases without a key (Brainstorming, Planning, Verification, PR Creation) are internal work — they do not require Jira comments or transitions.

---

## How `/flow` Uses the Map

Every phase that needs Jira interaction passes a phase key (not a column name) to `jira-workflow-steward`:

```
orchestrator: jira-workflow-steward(ticket=DEV-XXXX, phase="in_progress", milestone_body=...)
```

The steward applies 3-branch logic:

```python
target_col  = phase_map.get(phase)         # may be None or missing
current_col = read_current_column(ticket)

if target_col is None or phase not in phase_map:
    no_transition()                         # branch 1: no board move
elif target_col.lower() == current_col.lower():
    no_transition()                         # branch 2: already in target column
else:
    transition(target_col)
    # A Jira comment is separate and only posted for a requested milestone/blocker.
```

The orchestrator never reads the column directly — that puts board-specific knowledge in the wrong place.

---

## Drift Validation at Workflow Start

Boards drift. Teams rename "Selected for Development" → "Refined", drop steps, or add new stages ("Awaiting Stakeholder"). A phase map locked in at `/init` and never re-checked WILL silently fail when columns drift — and the failure mode is "first transition mid-flow fails with 'no such column'" by which point the agent has already started building on a stale assumption.

`/flow` Step 0 verifies the contract:

1. Read `jira_phase_map` and `jira_board_id` from PROJECT.md.
2. Fetch live columns: `bash ~/.claude/scripts/jira-board-columns.sh $board_id --json`
3. Compare every non-null mapped column against the live list.
4. If a mapped column is GONE → pause and surface drift to the user with a best-guess remap (Levenshtein/substring match). Save the user's choice back to PROJECT.md.
5. If a NEW column exists that's not mapped → log informationally, do NOT force remap. Most new columns are workflow extensions the toolbox doesn't need (legal review, stakeholder sign-off).

One acli call per `/flow` run. ~200 ms cached, ~1 s cold. Trivial vs the 15-30 minute workflow Step 0 gates.

### What drift validation catches

| Scenario | Without Step 0 | With Step 0 |
|---|---|---|
| Column renamed | First transition fails mid-flow with "no such column"; agent improvises or aborts | Step 0 detects, user remaps once, /flow proceeds |
| Column deleted | Silent failure mid-flow | Step 0 detects, user picks null or alternative |
| Column added | Tool unaware; ignored | Logged informationally; no action unless user wants to map |
| Whole board redesigned | User must re-run /init manually | Step 0 detects multiple breaks, recommends `/init` |
| Column reordered (no rename) | No effect (phase map keys by name, not position) | Same — invisible to /flow |

---

## Anchor Questions at /init

`/init` Sub-step 1e populates the phase map by asking **anchor questions** — one per phase, with the live column list as options. The user picks which column means each phase. Examples:

- "Which column does a ticket move to when DEVELOPMENT WORK STARTS?" → `in_progress`
- "Which column means 'awaiting human review' (PR open)?" → `code_review` (often the same column as in_progress)
- "Which column means 'merged, awaiting deploy'?" → `ready_for_release` (or `(none)`)

Anchor questions ask for **semantic intent**, not column ordering. A question like "list your columns left to right" doesn't tell the toolbox which column means which phase — anchor questions do.

---

## Migration from `jira_columns`

Older projects saved a flat ordered list to `jira_columns`. The toolbox no longer reasons in column ordinals, so this field is deprecated.

Migration is automatic: `/flow` Step 0 detects PROJECT.md files that have `jira_columns` but no `jira_phase_map`, runs the anchor questions once, populates the map, and removes the legacy field.

If you see `jira_columns: ...` in your PROJECT.md, leave it — the next `/flow` run migrates it.

---

## Why This Design

**Old design (column-keyed):** the orchestrator knew which Jira column meant "do work A vs do work B." Three problems:
1. Column names varied per team — every command had a "what if their column is named differently?" branch.
2. Lump boards (Code Review inside In Progress) needed special-case logic everywhere.
3. Column drift over time silently broke the workflow.

**New design (phase-keyed):** the orchestrator knows phases (universal). The phase map (per-board) lives in PROJECT.md. The 3-branch logic lives in one agent (`jira-workflow-steward`). Drift validation lives in one step (`/flow` Step 0). Each board-specific concern is in exactly one place.

Two user-named principles encoded by this design:

- **"The toolbox should fit the team, not the other way around."** Every team has different column names, and that's fine — the phase map adapts to whatever they use. No team has to rename their board to match toolbox expectations.
- **"Treat the phase map as a contract that's verified, not assumed."** A configuration file is a snapshot in time. Boards change. Verifying the contract once per workflow run (one acli call) trades trivial cost for resilience to drift.

---

## Generalization

The pattern (validate at workflow start, prompt to fix when stale, save fix back to config) generalizes beyond Jira columns. Equivalent drift problems exist for:

- GitHub reviewers list — saved at /init, verified before requesting reviews
- Repo branch protection rules — saved at /init, verified before pushing
- MCP server endpoints — saved in settings.json, verified before tool calls
- Beads issue templates — saved in .beads/, verified before creating issues

Out of scope for the current implementation. Worth noting because the same architecture (one config slot, one validation step, one self-healing UX) applies cleanly to each.

---

## See Also

- `commands/init.md` — Sub-step 1e (how anchor questions populate the map)
- `commands/flow.md` — Step 0 (drift validation) and the FULL TICKET LIFECYCLE table (phase-keyed)
- `agents/jira-workflow-steward.md` — the 3-branch logic implementation
- `scripts/jira-board-columns.sh` — the script that reads live columns from the Jira REST API (used by both /init and /flow Step 0)
- `rules/agents.md` — "Jira Phase-Map Transitions (global rule)" — applies to every command that touches Jira
