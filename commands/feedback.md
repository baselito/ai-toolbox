# /feedback — Report Toolbox Issues and Improvements

Report bugs, improvements, token waste, overlaps, documentation gaps, or feature requests for the Agentic Coding Toolbox. Feedback is always saved locally and optionally pushed to Jira for team visibility.

---

## Trigger

- Run manually: `/feedback`
- Auto-routed from `/start` when the user picks "Report feedback or improvement"
- Auto-suggested by the `feedback-detection` rule when the agent spots an issue during a workflow

---

## Prerequisites

- `~/.claude/toolbox-feedback.log` is created automatically on first use
- `.claude/PROJECT.md` is optional — if it exists, the agent reads feedback destination config. If not, feedback is saved locally only.

---

## Workflow

### Step 1 — Feedback Type

```
What kind of feedback?

1) Bug — something is broken or not working as expected
2) Improvement — something works but could be better
3) Token waste — an agent, skill, or MCP is consuming too many tokens
4) Overlap/conflict — two components do the same thing or conflict
5) Documentation — something is missing, unclear, or wrong
6) Feature request — something new that should be added
```

If the agent auto-detected the issue and pre-routed here, it pre-selects the type and explains why.

### Step 2 — Details

The agent asks for:

- **What happened?** — free text description of the issue or suggestion
- **Where?** — which component is affected (command, agent, skill, rule, MCP, workflow). The agent suggests from current context if available (e.g. "You were running `/flow` — is this about the flow workflow?")
- **Severity:**
  - Low — nice-to-have, no urgency
  - Medium — causes friction, slows work down
  - High — blocks work or produces wrong results
- **Reproduction** (for bugs) — steps to reproduce. For improvements, an example scenario.

If the feedback was auto-detected, the agent pre-fills what it can from the workflow context (which command was running, which agents were active, what files were being worked on).

### Step 3 — First-Time Destination Setup

On the first `/feedback` run in a project, the agent asks:

```
Where should team-visible feedback go?

1) Jira — create tickets on a feedback board
   (requires Jira (acli) to be configured)
2) Local only — save to ~/.claude/toolbox-feedback.log
   (no team visibility, but always works)
```

The answer is saved to `.claude/PROJECT.md` under `feedback_destination`. If neither integration is configured, the agent defaults to local only and tells the user.

This question is only asked once per project. The answer can be changed later by editing PROJECT.md or running `/init`.

### Step 4 — Confirmation Summary

```
-----------------------------------------
  Feedback Summary — please confirm
-----------------------------------------
  [1]  Type:       Improvement
  [2]  Component:  accessibility-auditor agent
  [3]  Severity:   Medium
  [4]  Summary:    Agent triggers on *.html files but
                   misses *.cshtml Razor views
  [5]  Save to:    Local + Jira
  [6]  Reporter:   [git config user.name]

  [ENTER] Submit
  [E]     Edit field(s)
  [Q]     Cancel
-----------------------------------------
```

Wait for explicit user confirmation before saving.

### Step 5 — Save

1. **Always:** Append entry to `~/.claude/toolbox-feedback.log`
2. **If Jira configured:** Create a ticket on the configured feedback board via `jira-workflow-steward` (Haiku)
   - Type: Bug (for bugs) or Task (for everything else)
   - Labels: `toolbox-feedback`, component name
   - Description: full details from Step 2

### Step 6 — Confirm

Show the user what was saved:

```
Feedback submitted:

  Local: ~/.claude/toolbox-feedback.log (entry #12)
  Jira:  https://your-team.atlassian.net/browse/FEEDBACK-123

  Type:     Improvement
  Summary:  Agent triggers on *.html but misses *.cshtml

Thank you — this helps improve the toolbox for the whole team.
```

---

## Local Feedback Log Format

File: `~/.claude/toolbox-feedback.log`

Each entry is appended to the file. Never overwrite existing entries.

```markdown
---

## [2026-03-19T14:30:00] Improvement — accessibility-auditor agent
**Reporter:** basel.altishe
**Project:** api-gateway
**Severity:** Medium
**Summary:** Agent triggers on *.html files but misses *.cshtml Razor views
**Details:** When working on a Razor view (Pages/Settings.cshtml), the accessibility-auditor didn't activate even though the file contains HTML with interactive elements. The trigger pattern should include *.cshtml.
**Reproduction:** Run /flow on a ticket that modifies a .cshtml file — accessibility-auditor is not in the agent list.
**Context:** Running /flow for DEV-1234 on branch feature/DEV-1234-settings-page
**Status:** Open
**Jira:** https://your-team.atlassian.net/browse/FEEDBACK-123

---
```

Fields:
- **Reporter:** from `git config user.name`
- **Project:** from current working directory name or PROJECT.md
- **Status:** always "Open" when created — updated manually or by toolbox maintainers
- **Jira:** link to the ticket if one was created, otherwise "Local only"

---

## Agent and Skill Usage

| Step | Agent/Skill | Model |
|---|---|---|
| Feedback intake | — (main agent) | Current model |
| Jira ticket | `jira-workflow-steward` | Haiku |

---

## Notes

- `/feedback` never modifies code or interrupts workflows — it is a reporting tool only
- The local log persists across projects at `~/.claude/toolbox-feedback.log` — all feedback from all projects is in one place
- Feedback collected outside the toolbox cannot create Jira tickets directly. Route it through `/feedback` so the configured provider can validate and log it formally.
- The `feedback-detection` rule passively monitors workflows and suggests feedback at natural pause points — it never interrupts mid-step
- Maximum 2 auto-detection suggestions per session to avoid feedback fatigue
- The reporter name comes from `git config user.name` — no need to ask
