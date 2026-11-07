# Automated review concepts — distilled (false-positive suppression patterns)

This is a **distilled summary** of automated-review's `knowledge/concepts.yml` (522 learned
entries, ~188 KB). It is committed to the toolbox so local Codex pre-PR reviews can
review *like automated-review* without dragging the full 188 KB into every review (your Codex
quota is limited — see the "Codex (optional cross-family reviewer)" section of `rules/performance.md`).

**What this is:** automated-review accumulated 522 patterns of findings it learned were
**false positives** — i.e. things a reviewer should NOT flag. The single meta-lesson
underneath nearly all of them:

> **VERIFY before flagging. Do not raise a finding from shape, naming, or the
> apparent absence of a check at the call site. Read the actual implementation,
> trace the real code path, check downstream layers, and confirm the design intent
> first.**

When Codex reviews a diff, it should treat the categories below as **known
false-positive classes** — only raise a finding in one of these areas if it has
concretely verified the issue is real (not pattern-matched).

The full, always-current learned lessons live in `memories.yml` (synced live by
`scripts/sync-codex-knowledge.sh`); this file is the slower-changing thematic
backbone. Re-distill periodically with that script's `--distill` note.

## The recurring false-positive categories (by frequency across 522 entries)

1. **Date / timezone / build-time values (~96).** Build-date, CI timestamp, or
   format-only date extraction from trusted CI output flagged as a timezone or
   runtime-date bug. Build-time constants are not runtime bugs.

2. **Spec / contract alignment treated as regression (~79).** A change that
   restores or aligns with an external spec (HTTP Retry-After, API contract,
   protocol standard) is intentional — not a regression — even when observable
   behavior changes.

3. **CI/CD workflow concerns (~59).** `continue-on-error` on informational/coverage
   jobs flagged as a quality gate; `secrets:inherit` / fork-PR secret exposure
   flagged on a **private or org-internal repo** where fork PRs are not a
   contribution path; broad triggers flagged without checking the called reusable
   workflow's `author_association`/visibility gating.

4. **Graceful degradation / partial success (~54).** Fallback, partial success, or
   backward-compat (single-workspace) modes flagged as a regression when the design
   intent allows partial failure.

5. **Test coverage — impossible / redundant / wrong layer (~45).** Requesting
   coverage that is structurally impossible (module-level env constants that can't
   be re-evaluated), combinatorial tests where one suffices, coverage for invalid
   inputs that can never reach a downstream consumer (validation lives at the
   boundary), or coverage that an existing `toHaveBeenCalled`-style assertion
   already provides.

6. **Regex / parser narrowing (~37).** A regex character-class narrowing flagged as
   a behavioral regression without accounting for case-insensitive modifiers
   (`[a-z]` under `/i` already covers `[A-Za-z]`); a deliberately simplified
   parser/filter flagged for not handling cases outside its stated class.

7. **UI state / rendering (~35).** Stale UI state flagged without checking whether
   conditional rendering or visibility logic already handles it.

8. **Downstream layer already handles it (~27).** Missing auth check / validation /
   error handler flagged at a call site when middleware, a global filter, a reusable
   workflow, or the invoked service already performs the check.

9. **Error propagation not traced (~21).** "Error handling is missing / propagation
   is broken" claimed without tracing the actual path — whether an intermediate
   layer catches, wraps, rethrows, or swallows, and where the intended error
   boundary is.

10. **Behavioral change as breaking without checking callers (~16).** A change
    flagged as breaking/regression without verifying the actual callers tolerate it.

11. **Shape / naming without reading the implementation (~7).** A pattern flagged as
    a bug from naming or shape alone (e.g. an in-memory lock helper flagged for
    filesystem risk; a git-scoped class flagged for missing untracked-file coverage).

12. **Validation already upstream (~7).** Missing checks flagged at a lower layer for
    inputs an upstream regex/schema validation has already constrained.

## How Codex should use this

- Before raising a finding, ask: *does it fall into one of the 12 categories above?*
  If yes, raise it ONLY with concrete evidence from the actual code (line, caller,
  downstream function) — never on shape/naming/absence alone.
- Prefer **fewer, higher-confidence** findings. A false positive wastes the author's
  time and trains the reviewer wrong; automated-review learned these 522 the hard way.
- This is suppression knowledge, not a ceiling: genuinely new bug classes outside
  these categories should still be flagged.
