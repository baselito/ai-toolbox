---
name: receiving-code-review
source: Superpowers (obra/superpowers)
description: Use when receiving code review feedback — requires technical verification, not performative agreement
---

# Code Review Reception

Evaluate review feedback with technical rigor. Verify before implementing. Push back when wrong.

## The Response Pattern

When receiving code review feedback:

1. **READ** — complete feedback without reacting
2. **UNDERSTAND** — restate the requirement in your own words (or ask)
3. **VERIFY** — check against codebase reality
4. **EVALUATE** — technically sound for THIS codebase?
5. **RESPOND** — technical acknowledgment or reasoned pushback
6. **IMPLEMENT** — one item at a time, test each

## Forbidden Responses

Never write:
- "You're absolutely right!"
- "Great point!" / "Excellent feedback!"
- "Let me implement that now" (before verification)
- "Thanks for catching that!" or any gratitude expression

Instead: restate the technical requirement, ask clarifying questions, push back with reasoning if wrong, or just start working. Actions speak — the code itself shows you heard the feedback.

## Source-Specific Handling

### From the user (human partner)
- Trusted — implement after understanding
- Still ask if scope is unclear
- Skip to action or technical acknowledgment

### From external reviewers (PR comments, automated tools)
Before implementing, check:
1. Technically correct for THIS codebase?
2. Breaks existing functionality?
3. Reason for current implementation?
4. Works on all platforms/versions?
5. Does reviewer understand full context?

If suggestion seems wrong — push back with technical reasoning.
If conflicts with user's prior decisions — stop and discuss with the user first.

## YAGNI Check

If a reviewer suggests "implementing properly":
- Search the codebase for actual usage
- If unused: suggest removing (YAGNI)
- If used: then implement properly

## Implementation Order

For multi-item feedback:
1. Clarify anything unclear FIRST
2. Then implement in order:
   - Blocking issues (breaks, security)
   - Simple fixes (typos, imports)
   - Complex fixes (refactoring, logic)
3. Test each fix individually
4. Verify no regressions

## When to Push Back

Push back when:
- Suggestion breaks existing functionality
- Reviewer lacks full context
- Violates YAGNI (unused feature)
- Technically incorrect for this stack
- Legacy/compatibility reasons exist
- Conflicts with user's architectural decisions

How: use technical reasoning, not defensiveness. Ask specific questions. Reference working tests/code. Involve the user if architectural.

## Acknowledging Correct Feedback

When feedback IS correct:
- "Fixed. [Brief description of what changed]"
- "Good catch — [specific issue]. Fixed in [location]."
- Or just fix it and show in the code

## Common Mistakes

| Mistake | Fix |
|---|---|
| Performative agreement | State requirement or just act |
| Blind implementation | Verify against codebase first |
| Batch without testing | One at a time, test each |
| Assuming reviewer is right | Check if it breaks things |
| Avoiding pushback | Technical correctness > comfort |
| Partial implementation | Clarify all items first |

## Applies To

All agents that receive review feedback — especially during Step 8 (Agent Orchestration) when `code-reviewer`, `security-reviewer`, and conditional reviewers produce findings that other agents act on.
