---
name: presentation
description: Create or edit a PowerPoint presentation with an optional user-provided template
argument-hint: "[topic or requested deck]"
---

# /presentation — PowerPoint

Use `skills/presentation-master/SKILL.md` for presentation requests in either
provider. Plan one message per slide. If `PPTX_TEMPLATE` or a template path is
supplied, inspect its actual layouts and respect the user's design requirements.
Otherwise create a clean, unbranded deck. No proprietary font or template is
required. Save to `PPTX_OUTPUT` or a visible working-directory path.

Validate content, layout, links and the resulting PPTX. Render and visually
inspect when a renderer is available; disclose when visual QA is unavailable.
Follow the usual Jira workflow only if the user supplies a ticket. Apply the
normal mutation-testing policy to a testable generator, not to a deck-only output.
