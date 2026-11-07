---
name: presentation-master
description: >
  Create or edit PowerPoint presentations with an optional user-provided template.
  Use for slide decks, presentations, PowerPoint, or pptx requests. Includes a
  portable starter, slide planning, layout inspection, and validation guidance.
---

# Presentation master

Build clear, editable presentations for the intended audience. No corporate
assets, proprietary fonts, account access, or organization-specific layouts are
required. Respect user-provided brand requirements when applicable.

## Resolve inputs and output

- An explicitly supplied template path takes precedence; otherwise read
  `PPTX_TEMPLATE`, then the bundled `assets/template.pptx`. Both are optional;
  with neither, create a blank presentation.
- If a configured template is missing or unreadable, report the error instead of
  silently substituting another design. Accept `.pptx` input for the starter.
- Use the requested output path, or `PPTX_OUTPUT`, or `./output.pptx` in that order.
  Expand home-directory paths and report the final absolute path.
- Keep source templates unchanged. Never overwrite an existing file unless the
  user has authorized replacing it.
- For editing, retain existing slides, speaker notes, masters, and relevant
  content. For a new deck based on a template, inspect its example slides and
  deliberately decide which to reuse or remove; do not blindly delete them.

Use a Python environment containing `python-pptx`. If unavailable, install it in
an approved project environment or use the host's presentation tools. No fixed
host paths are assumed. The starter below can be saved as a local build script.

## Inspect and plan

Inspect existing slides and enumerate every master and layout, including
placeholder types and names. Do not assume layout names, master indices,
placeholder indices, colors, or fonts are shared between templates.

```python
for master in prs.slide_masters:
    for layout in master.slide_layouts:
        print(layout.name, [
            (ph.name, str(ph.placeholder_format.type))
            for ph in layout.placeholders
        ])
```

Before building, plan each slide's headline, supporting evidence, and visual
structure. Prefer one message per slide. Choose tables for comparisons, diagrams
for processes, charts for quantitative evidence, and short lists when appropriate.
Keep source attribution with externally sourced claims and images. Use actual
slide dimensions for placement and preserve the source aspect ratio when editing.

## Portable starter

This example adds a single text slide. A supplied template's existing slides are
retained. It selects the layout with the fewest placeholders across all masters;
inspect inherited backgrounds and graphics before using that layout for a real
deck. The blank fallback needs no external template or named font.

```python
import os
from pathlib import Path
from pptx import Presentation
from pptx.util import Inches, Pt

template_value = os.environ.get("PPTX_TEMPLATE", "").strip()
template = Path(template_value).expanduser().resolve() if template_value else None
output = Path(os.environ.get("PPTX_OUTPUT") or "./output.pptx").expanduser().resolve()
if template is not None and not template.is_file():
    raise FileNotFoundError(f"Template not found: {template}")
if output.exists():
    raise FileExistsError(f"Choose a new output path: {output}")

prs = Presentation(str(template)) if template is not None else Presentation()
if template is None:
    prs.slide_width = Inches(13.333)
    prs.slide_height = Inches(7.5)

layouts = [layout for master in prs.slide_masters for layout in master.slide_layouts]
if not layouts:
    raise ValueError("The presentation has no usable slide layouts")
layout = min(layouts, key=lambda item: len(item.placeholders))
slide = prs.slides.add_slide(layout)
# Remove only this new slide's copied placeholders; keep masters and source slides.
for placeholder in list(slide.placeholders):
    element = placeholder._element
    element.getparent().remove(element)

width, height = prs.slide_width, prs.slide_height

def text_box(text, x, y, w, h, size, bold=False):
    box = slide.shapes.add_textbox(
        int(width*x), int(height*y), int(width*w), int(height*h)
    )
    box.text_frame.word_wrap = True
    paragraph = box.text_frame.paragraphs[0]
    run = paragraph.add_run()
    run.text = text
    run.font.size = Pt(size)
    run.font.bold = bold
    # Font family and text color inherit from the presentation theme.
    return box

text_box("A clear headline states the main point", .06, .07, .88, .18, 30, True)
text_box("Replace this example with concise supporting evidence.",
         .06, .30, .88, .50, 22)
output.parent.mkdir(parents=True, exist_ok=True)
prs.save(str(output))
check = Presentation(str(output))
assert len(check.slides) == len(prs.slides)
print(output)
```

Adapt the content and design to the user's request; the example text is not a
finished deliverable. Inherit a provided template's theme where useful. Check
that its fonts exist in the rendering environment and use an available substitute
if needed, explaining substitutions that materially change the appearance.

## Verify and deliver

1. Reopen the saved file, check expected slide count, and inspect extracted text
   for missing content, unfilled placeholders, and accidental sample text.
2. Check all shapes against slide bounds, allowing deliberate background bleed.
   Inspect charts, image crops, hyperlinks, notes, and preserved template content.
   Avoid relying on color alone to convey meaning.
3. Render the deck with an available PowerPoint-compatible renderer and inspect
   every slide for overflow, overlap, contrast, font substitution, and readability.
   Fix defects and render again. A successful save or XML parse does not prove
   visual correctness. If rendering is unavailable, state that limitation.
4. Provide the final file path, summarize what was built, and disclose any
   dependencies or unresolved fidelity issues. Do not claim visual verification
   when only structural checks were possible.

Templates are optional user configuration. Supply `PPTX_TEMPLATE` only when a
particular theme is required, and ensure any template or images are authorized
for the intended use. The skill ships no binary template or logo assets.
