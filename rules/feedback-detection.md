---
name: feedback-detection
source: This repo
scope: always active
---

# Feedback Detection

Passively monitor workflows for issues worth reporting. Never interrupt — suggest at natural pause points.

## What to Detect

| Pattern | How to spot it | Suggested feedback type |
|---|---|---|
| **Token-heavy agent** | An agent ran but produced no actionable findings (empty handover, "nothing to report") | Token waste |
| **Duplicate findings** | Two agents in the same workflow report the same issue in their handover entries | Overlap/conflict |
| **Skipped agent** | Agent was triggered by file patterns but its review section is empty or trivially "all clear" for 3+ consecutive runs | Token waste |
| **MCP failure** | An MCP tool call fails, times out, or returns an error during a workflow | Bug |
| **Rule conflict** | Two rules give contradictory guidance for the same file or pattern | Overlap/conflict |
| **Missing trigger** | A file was changed that doesn't match any conditional agent trigger but looks like it should (e.g. a UI file with an unusual extension) | Improvement |
| **Repeated build error** | `build-error-resolver` encounters the same error pattern in 3+ separate sessions | Bug |

## Behaviour Rules

1. **Never interrupt the current step** — finish the step first, then mention the observation
2. **Suggest at natural pause points** — between workflow steps, after a review completes, or at the end of the workflow
3. **Keep it brief** — one sentence explaining what was noticed, one question asking if the user wants to log it
4. **Pre-fill context** — if the user says yes, route to `/feedback` with the type, component, and details pre-filled from the workflow context
5. **Maximum 2 suggestions per session** — after 2, stop suggesting even if more issues are detected. The user can always run `/feedback` manually.
6. **If user says no** — continue silently. Do not mention the same issue again in this session.
7. **Never auto-log** — always ask the user first. Feedback is the user's decision.

## Suggestion Format

```
[at a natural pause point in the workflow]

Noticed: [brief observation — one sentence].
Want me to log this as feedback? (y/n)
```

Examples:

```
Noticed: evidence-collector and accessibility-auditor both flagged the same
missing alt text in Header.tsx. This might indicate overlap between the two agents.
Want me to log this as feedback? (y/n)
```

```
Noticed: database-reviewer ran on this task but produced no findings — the only
DB-related change was a comment in the migration file. The trigger pattern might
be too broad for comment-only changes.
Want me to log this as feedback? (y/n)
```

## What This Rule Does NOT Do

- Does not slow down workflows — detection reads existing handover entries, no extra work
- Does not create feedback entries without user confirmation
- Does not override agent selection or orchestration decisions
- Does not run any additional agents or tools
- Does not track or remember detections across sessions (each session starts fresh)

## Applies To

All workflows that use agent orchestration: `/flow`, `/build`, `/bug`, `/hotfix`, `/incident`, `/review`, `/refactor`, `/security`, `/perf`.

Does not apply to: `/init`, `/start`, `/continue`, `/feedback`.
