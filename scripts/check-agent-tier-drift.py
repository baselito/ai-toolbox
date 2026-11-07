#!/usr/bin/env python3
"""Fail if a doc pairs an agent with a tier that contradicts its frontmatter.

Scans every *.md in the working tree except .git/, .claude/, and generated
worktrees under .worktrees/ — untracked scratch files included. That is deliberate
(a stale draft is still wrong) but it means an uncommitted scratch note can fail
the build.

WHY THIS EXISTS
---------------
The toolbox names model tiers inline in prose and tables — "code-reviewer (Sonnet)",
"| reality-checker | Sonnet |". One frontmatter tier change invalidates all of them,
and the stale copies are not inert: `agents/chief-of-staff.md`,
`skills/agent-orchestration/SKILL.md` and `skills/code-review-orchestration/SKILL.md`
are read AT THE SPAWN DECISION POINT. A stale "(Sonnet)" there can make chief-of-staff
name Sonnet for an Opus agent, which the orchestrator may mirror into an explicit
`model:` argument — a SILENT downgrade, no error.

DESIGN: LOUD AND SUPPRESSIBLE, NOT CLEVER
-----------------------------------------
An earlier version tried to infer which pairings were *claims* — proximity windows,
tier-first lists, heading scopes. Five iterations, ~180 lines, and a reviewer measured
it at roughly HALF recall on a real frontmatter flip: every heuristic added to suppress
false positives created a new blind spot, and each blind spot was found by a reviewer
rather than by the gate. The stated priority was "a miss is worse than a false
positive" while the design optimised for the opposite.

So this version is deliberately dumb and strict:

  * ANY line where a checkable SUBJECT and a tier word co-occur, and the tier is not
    that subject's real tier, is a violation. A subject is an agent name (frontmatter
    is truth), a role phrase, a skill name, or a phase — see the vocabularies below.
  * ONE narrowing, and it is deliberately span-scoped: a tier word followed by a
    correct definition OF that tier ("Haiku for doc updates") is masked out of the
    line before matching, because it explains itself. The mask covers only the tier
    word and the matched gloss key — an earlier version blanked the whole greedy
    capture and thereby hid agent names sitting beside the gloss.
  * Legitimate pairings are suppressed EXPLICITLY, one of two ways:
      - put `<!-- tier-ok: reason -->` on the line (the reason is required), or
      - add a `path:line` entry to TIER_OK_ALLOWLIST below with a reason.

That turns every exception into something a reader can see and a reviewer can argue
with, instead of an emergent property of three regexes. The allowlist doubles as an
inventory of "places an agent name legitimately sits beside another tier word".

KNOWN FALSE POSITIVE
--------------------
Two entangled glosses of DIFFERENT tiers on one line trip the deliberate mixed-tier
refusal, even when the prose is correct. It fails safe and is clearable with an
inline `tier-ok`, but it is a real behaviour change introduced alongside the
entanglement check — recorded here because the commit that added it did not say so.

KNOWN LIMITATION — read before trusting a green run
---------------------------------------------------
Only agents with LOCAL frontmatter under `agents/` are checked. The ECC-plugin agents
(`architect`, `planner`, `doc-updater`, `harness-optimizer`, `loop-operator`) have no
local file, so this gate says nothing about them — roughly 68 doc lines are
structurally unreachable. That is intentional (the repo does not own those tiers) but
it means a green run is NOT a claim about those five.

Run standalone, or via verify.sh.
"""

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
TIER_WORDS = ("Opus", "Sonnet", "Haiku", "Fable")

# A fence is a line that is ONLY a fence (optionally with a language tag). Matching a
# bare prefix instead flipped parity on wrapped prose beginning with a backtick-run,
# which BLANKED the tail of two files — including a spawn-decision one — so the gate
# was green because it had stopped looking.
FENCE_RE = re.compile(r"\s*(?:`{3,}|~{3,})\s*[\w+.-]*\s*$")

# Requires a reason: "<!-- tier-ok: why -->". A bare marker is rejected so a
# suppression always carries its justification (Codex P2).
INLINE_OK_RE = re.compile(r"<!--\s*tier-ok:\s*\S.*?-->")

# ROLE-level claims. The gate originally keyed only on agent NAMES, so lines like
# "spawn a Sonnet implementing subagent" were invisible — and TWO hand sweeps in a
# row claimed "zero remain" while a from-scratch grep found dozens. Roles have
# known sanctioned tiers, so they are mechanically checkable too. Ordered
# longest-first so the more specific phrase wins.
ROLE_TIERS = {
    "compliance audit subagent": "Opus",
    "implementing subagent": "Opus",
    "implementation subagent": "Opus",
    "verification subagent": "Opus",
    "brainstorming subagent": "Opus",
    "PR creation subagent": "Opus",
    "PR-creation subagent": "Opus",
    "discovery subagent": "Opus",
    "Explore subagent": "Opus",
    "liveness monitor": "Haiku",
    "[DELEGATED]": "Opus",
}

# SKILL-level claims — the THIRD blind spot, found by Codex after roles were closed.
# A line naming a skill and a tier ("**Skill:** `finishing-a-development-branch`
# (Sonnet)") was invisible: the gate knew agent names and role phrases, but not skill
# names. Eight such lines were live across six commands and a how-to while the gate
# read green. Each skill below always executes inside a `[DELEGATED]` subagent, so its
# tier is knowable — same contract as a role. Keep this list to skills whose execution
# tier is actually fixed; a skill that can legitimately run at more than one tier
# belongs in neither map.
SKILL_TIERS = {
    "finishing-a-development-branch": "Opus",
    "verification-before-completion": "Opus",
    "code-review-orchestration": "Opus",
    "brainstorming": "Opus",
    "discovery": "Opus",
}

# PHASE-level claims — the natural 4th vocabulary after names, roles and skills.
# Command files overwhelmingly express tiers as `| <Phase> | <agent/skill> | <Tier> |`
# rows and phase diagrams, which named none of the first three vocabularies. An
# independent audit of the lines this gate could NOT adjudicate found this shape
# accounted for 14 of 39 live drift lines. `Assessment` is deliberately absent: its
# tier is legitimately the session model, so it has no fixed answer.
PHASE_TIERS = {
    "systematic debugging": "Opus",
    "compliance audit": "Opus",
    "code review": "Opus",
    "implementation": "Opus",
    "verification": "Opus",
    "pr creation": "Opus",
    "planning": "Opus",
}

# TIER GLOSS — a tier word immediately followed by a definition of what that tier
# IS. These are the most dangerous drift of all: `rules/performance.md` is always
# loaded, and its `model:` gloss still called Sonnet "quality execution" thirty
# lines under a table that says Opus. A per-line agent check can never see this,
# because the line names no agent — it defines the tier itself.
TIER_GLOSS = {
    "quality execution": "Opus", "execution/review": "Opus", "deep reasoning": "Opus",
    "retrieval": "Sonnet", "capture": "Sonnet", "retrieval/capture": "Sonnet",
    "ops monitoring": "Sonnet",
    "mechanical": "Haiku",
    "doc updates": "Haiku", "doc update": "Haiku", "documentation": "Haiku",
    "jira": "Haiku", "commits": "Haiku", "jira/commits": "Haiku",
    "branch naming": "Haiku",
    "most reviewers": "Opus", "reviewers": "Opus", "review": "Opus",
    "orchestrator": "Fable", "thinker": "Fable",
}
GLOSS_KEYS: tuple = ()   # populated below, longest-first so the specific phrase wins
GLOSS_RE = re.compile(
    r"(?<![\w-])(Opus|Sonnet|Haiku|Fable)[\s]*(?:\(|=|—|–|\bfor\b|\bis\b)[\s]*([^),.|;]{3,40})", re.I)

# NO-OP ESCALATION — "Opus → Opus", "Opus (Opus for complex work)". Both ends now
# name the same tier, so the sentence describes a step that does not exist. This is
# the signature artefact of a blanket Sonnet->Opus substitution, and eleven such
# lines survived two hand sweeps precisely because each reads as normal prose.
NOOP_ESCALATION_RES = (
    # `/` included: a blanket substitution turns "Sonnet/Opus" into "Opus/Opus",
    # which is the same dead escalation written with a different separator. The
    # backreference means a genuine enumeration ("Opus/Sonnet/Haiku") never matches.
    # DO NOT add `|` to this set. It looks like the natural next separator, but
    # `agents/security-engineer.md:46` and `agents/evidence-collector.md:28` are
    # legitimate two-column comparison tables where the same tier can correctly
    # appear either side of a cell boundary.
    re.compile(r"(?<![\w-])(Opus|Sonnet|Haiku|Fable)\s*(?:->|→|/|\bto\b)\s*\1(?![\w-])", re.I),
    re.compile(r"(?<![\w-])(Opus|Sonnet|Haiku|Fable)\s*\(\s*\1(?![\w-])", re.I),
)

# COST-RATIONALE CLAUSE — "the subagent uses Sonnet (cheaper)". Haiku is the only
# cheap tier, so a thrift justification attached to any other tier is stale. Sweeps
# reliably leave this behind because it reads as rationale rather than as a claim.
COST_RE = re.compile(
    r"(?<![\w-])(Opus|Sonnet|Fable)(?![\w-])[^.|;\n]{0,60}?"
    # A trailing comparative ("cheaper THAN Opus", "cheap VS Haiku") states a true
    # fact about the tiers; the drift shape is thrift offered as the REASON for a
    # choice ("uses Sonnet because it is cheaper"). Codex P2 on this branch.
    r"\b(cheap|cheaper|cheapest|cost-effective|low-cost|to save|30x)\b"
    r"(?!\s+(?:than|vs\.?|versus|compared)\b)", re.I)


GLOSS_KEYS = tuple(sorted(TIER_GLOSS, key=len, reverse=True))


def norm(text: str) -> str:
    """Fold hyphens/underscores to spaces so punctuation cannot hide a name.

    `compliance-audit subagent` and `Security Reviewer` both escaped the earlier
    exact-match vocabularies on nothing but a hyphen.
    """
    return re.sub(r"[-_\s]+", " ", text.lower())


# Legitimate agent/tier pairings, each with a reason. `path:line` — line numbers shift,
# so prefer the inline marker for anything inside a file that changes often.
TIER_OK_ALLOWLIST: dict[str, str] = {
    # YAML frontmatter — an inline HTML comment would corrupt the description
    # field. The line names chief-of-staff beside the generic "Opus/Sonnet/Haiku"
    # enumeration, which describes the tier system, not this agent.
    "skills/agent-orchestration/SKILL.md:3": "generic tier enumeration in YAML frontmatter",
    # Same constraint: YAML frontmatter, no inline comment possible. The line pairs
    # the word "implementation" (as an example of what gets watched) with the Haiku
    # monitor that watches it — two different subjects, both correctly tiered.
    "skills/subagent-liveness/SKILL.md:3": "Haiku monitor watching an Opus subagent — two subjects, both correct",
}


def agent_tiers() -> dict[str, str]:
    tiers = {}
    for f in sorted((REPO / "agents").glob("*.md")):
        m = re.search(r"^model:\s*(\S+)", f.read_text(), re.M)
        if m:
            tiers[f.stem] = m.group(1).strip().capitalize()
    return tiers


def scrub(lines: list[str], in_agents_dir: bool) -> tuple[list[str], bool]:
    """Blank fenced blocks, and HTML comments in an agent's own file (its banner).

    Returns (lines, fence_balanced, fenced_flags). Unbalanced fences are reported, never ignored —
    silently blanking a file tail is the exact failure this replaced.
    """
    out = list(lines)
    flags = [False] * len(out)
    fenced = False
    for i, ln in enumerate(out):
        if FENCE_RE.match(ln):
            fenced = not fenced
            out[i] = ""
            continue
        flags[i] = fenced
    balanced = not fenced

    if in_agents_dir:
        # Agent files open with a vendoring banner in an HTML comment that names
        # tiers, so comment CONTENT must not be adjudicated. The previous version
        # blanked the entire LINE, which had two consequences a reviewer caught:
        #   1. the documented `<!-- tier-ok: ... -->` suppression could never be
        #      honoured here, because it was erased before INLINE_OK_RE ran; and
        #   2. worse, ANY unrelated trailing comment silently hid real drift —
        #      "code-reviewer runs on Sonnet. <!-- note -->" was skipped entirely
        #      while the same line without the comment was correctly flagged.
        # Strip only the comment SPANS and keep the prose around them.
        inc = False
        for i, ln in enumerate(out):
            if not inc and INLINE_OK_RE.search(ln):
                continue          # a suppression marker must survive to be honoured
            buf, j = [], 0
            while j < len(ln):
                if not inc:
                    k = ln.find("<!--", j)
                    if k < 0:
                        buf.append(ln[j:])
                        break
                    buf.append(ln[j:k])
                    j, inc = k + 4, True
                else:
                    k = ln.find("-->", j)
                    if k < 0:
                        j = len(ln)
                        break
                    j, inc = k + 3, False
            out[i] = "".join(buf)
    return out, balanced, flags


def main() -> int:
    tiers = agent_tiers()
    if not tiers:
        print("  ⚠️  no agents found — nothing to check")
        return 0

    # Word-bounded and case-insensitive: sentence-initial "Code-reviewer" must match,
    # and `security-reviewer` must not be found inside a longer token.
    names = sorted(tiers, key=len, reverse=True)
    # Built over NORMALISED keys and run against the NORMALISED line, so a hyphen
    # or title-casing cannot hide a name (`Security Reviewer` == `security-reviewer`).
    agent_re = re.compile(
        r"(?<![\w])(" + "|".join(re.escape(norm(n)) for n in names) + r")(?![\w])")
    phase_re = re.compile(
        r"(?<![\w])(" + "|".join(re.escape(p) for p in sorted(PHASE_TIERS, key=len, reverse=True))
        + r")(?![\w])")
    norm_to_agent = {norm(n): n for n in names}
    tier_re = re.compile(r"(?<![\w-])(" + "|".join(TIER_WORDS) + r")(?![\w-])", re.I)
    # Word-bounded like agent names: hyphenated skill names must not match inside a
    # longer token, and "Discovery" at the start of a phase row must still match.
    skill_re = re.compile(
        r"(?<![\w])(" + "|".join(re.escape(norm(s)) for s in sorted(SKILL_TIERS, key=len, reverse=True))
        + r")(?![\w])")
    norm_to_skill = {norm(k): k for k in SKILL_TIERS}

    violations: list[tuple[str, int, str, str, str, str]] = []
    unbalanced: list[str] = []
    # Coverage accounting. THREE separate times a vocabulary gap (names, then roles,
    # then skills) let live drift read green, and twice a commit of mine claimed
    # "zero remain" on the strength of it. The gate cannot enumerate every phrasing,
    # so it must instead be honest about how much it did NOT adjudicate — a green run
    # is a claim about the covered subset only, and now says so out loud.
    tier_lines = 0
    adjudicable = 0
    unchecked: list[tuple[str, int, str]] = []

    # Scanning *.md ONLY was the gate's largest structural hole. The hooks that
    # ENFORCE delegation embed spawn templates in their deny messages — literally
    # `Agent(model: "sonnet", ...)` — and that text is handed to the agent at the
    # moment it is told what to spawn. It is not documentation; it is the
    # instruction. Four hooks carried stale tiers there, invisible to this gate,
    # which is exactly the silent-downgrade failure its own docstring describes.
    targets = [f for f in REPO.rglob("*.md")]
    targets += [f for f in (REPO / "hooks").glob("*.sh")]
    targets += [f for f in (REPO / "scripts").glob("*.sh")]
    targets += [f for f in (REPO / "scripts").glob("*.py")]

    for f in sorted(set(targets)):
        rel = f.relative_to(REPO).as_posix()
        if rel.startswith((".git/", ".claude/", ".worktrees/")):
            continue
        # Self-reference. This file DEFINES the vocabularies and its test harness
        # is made of deliberate violations, so every tier word in both is a literal
        # fixture rather than a claim about anything. Scanning them makes the gate
        # fail on its own test data — which surfaced the moment the glob was widened
        # to scripts/*.sh.
        if rel in ("scripts/check-agent-tier-drift.py",
                   "scripts/test-check-agent-tier-drift.sh"):
            continue

        raw = f.read_text(errors="ignore").split("\n")
        # Fence scrubbing is a markdown concept. In a shell or python file the whole
        # body is prose-equivalent, and a ``` inside a deny message would otherwise
        # flip parity and blank the rest of the file — the exact silent-blanking bug
        # that once made this gate green by accident.
        if f.suffix == ".md":
            lines, balanced, fenced_flags = scrub(raw, f.parent.name == "agents")
        else:
            lines, balanced, fenced_flags = list(raw), True, [False] * len(raw)
        if not balanced:
            unbalanced.append(rel)

        recent_agent = None      # (name, lines_ago) — for adjacent-line diagrams
        recent_age = 0
        for lineno, line in enumerate(lines, 1):
            if not line or INLINE_OK_RE.search(line):
                recent_agent, recent_age = None, 0
                continue
            if TIER_OK_ALLOWLIST.get(f"{rel}:{lineno}"):
                continue

            # Glosses are resolved BEFORE anything else, and a CORRECT one is masked
            # out of the line rather than added to `expected`.
            #
            # The `expected |= gloss_ok` version of this shipped and INVERTED the gate
            # at the very line it was written to protect: one correct gloss vouched for
            # every subject on the line, so "Haiku for chief-of-staff, Opus for most
            # reviewers, Haiku for doc updates" passed — chief-of-staff is Opus. It
            # traded one false positive for three false negatives, and the commit that
            # introduced it claimed "both directions verified". Masking scopes each
            # gloss to its OWN span: the clause it explains is consumed, and whatever
            # tier words remain must still be justified by a subject actually named
            # among them.
            gloss_bad = []
            _mask = list(line)
            for _m in GLOSS_RE.finditer(line):
                _g = re.sub(r"^(?:the|a|an)\s+", "", norm(_m.group(2)).strip())
                _key = next((k for k in GLOSS_KEYS if _g == k or _g.startswith(k + " ")), None)
                _said = _m.group(1).capitalize()
                if _key and TIER_GLOSS[_key] != _said:
                    gloss_bad.append((_said, _key, TIER_GLOSS[_key]))
                elif _key:
                    # Mask ONLY as far as the matched key. group(2) is greedy up to 40
                    # chars, so blanking the whole match erased any agent name — and
                    # its wrong tier — that happened to sit inside that window:
                    # "Haiku for doc updates and code-reviewer (Haiku)" went silent.
                    # Seven such false negatives, six of which fired before masking
                    # existed. Walk the raw capture until its normalised prefix equals
                    # the key, and stop there.
                    _cut = len(_m.group(2))
                    for _j in range(1, len(_m.group(2)) + 1):
                        _cand = re.sub(r"^(?:the|a|an)\s+", "",
                                       norm(_m.group(2)[:_j]).strip())
                        if _cand == _key:
                            _cut = _j
                            break
                    # A gloss only self-explains when ITS OWN CLAUSE names nothing
                    # else. "Sonnet for retrieval" is a definition; "Sonnet for
                    # retrieval by code-reviewer" attributes that tier to an agent, and
                    # masking it removed the line's only tier word so the claim went
                    # silent.
                    #
                    # SCOPE, precisely: this inspects the remainder of the GLOSS's own
                    # capture group — at most 40 chars, terminated by ) , . | ; — not
                    # the whole line. A subject sitting before the tier word, in an
                    # adjacent table cell, past a comma, or past 40 chars is invisible
                    # here, and those are the four residual false negatives audit 6
                    # constructed. They are latent: instrumenting the real repo shows
                    # the mask fires on 15 lines, exactly one loses all its tier words
                    # with a subject still present, and that line's claim is correct.
                    # Widening the window is not obviously right — it would trade these
                    # misses for false positives on prose that merely mentions an agent
                    # nearby — so this is recorded rather than "fixed" in a hurry.
                    #
                    # All four are EXECUTABLE, not just described: scripts/test-check-
                    # agent-tier-drift.sh pins them as TC-TD-22..25 (subject before the
                    # tier word / adjacent table cell / past a comma / past 40 chars).
                    # Those cases are strict xfail — they assert the gate is still blind,
                    # so if you close one here the suite FAILS until it is promoted to
                    # assert_detects. That is deliberate: a prose-only gap list rots, and
                    # a silently-flipping marker would leave this comment claiming a hole
                    # that no longer exists. Re-run TC-TD-16 and TC-TD-19 before trusting
                    # any widening — they are the false-positive guards it would break.
                    _rest = norm(_m.group(2)[_cut:])
                    _entangled = (agent_re.search(_rest) or skill_re.search(_rest)
                                  or phase_re.search(_rest)
                                  or any(norm(_r) in _rest for _r in ROLE_TIERS))
                    if not _entangled:
                        for _i in range(_m.start(), _m.start(2) + _cut):
                            _mask[_i] = " "
            line_m = "".join(_mask)      # line with correctly-glossed spans blanked

            nline = norm(line_m)
            found_agents = {norm_to_agent[m.group(1)] for m in agent_re.finditer(nline)}
            if found_agents:
                recent_agent, recent_age = sorted(found_agents)[-1], 0
            elif recent_agent is not None and fenced_flags[lineno - 1]:
                recent_age += 1
                if recent_age > 2:
                    recent_agent = None
                elif tier_re.search(line_m) and re.match(r"\s*[\u2502\u250c\u2514\u251c\u2506|+]", line):
                    # A tier on its own line directly under an agent name, INSIDE a
                    # box-drawn diagram. Restricted to box-drawing characters: without
                    # that, the carry also bled across fenced list items where
                    # consecutive lines name different agents.
                    found_agents = {recent_agent}
            found_roles = {r for r in ROLE_TIERS if norm(r) in nline}
            found_skills = {norm_to_skill[m.group(1)] for m in skill_re.finditer(nline)}
            found_phases = {m.group(1) for m in phase_re.finditer(nline)}
            # Coverage is counted on the RAW line (a glossed tier word is still a
            # tier word the gate looked at); adjudication runs on the masked one.
            has_tier = bool(tier_re.search(line))
            if has_tier:
                tier_lines += 1

            # No-op escalation and stale thrift rationale are self-contained: they
            # need no subject at all, because the defect IS the phrasing.
            if has_tier:
                if any(r.search(line) for r in NOOP_ESCALATION_RES):
                    violations.append((rel, lineno, "(no-op escalation)", "one tier, not two",
                                       "same tier on both sides", line.strip()[:100]))
                    adjudicable += 1
                    continue
                if COST_RE.search(line):
                    violations.append((rel, lineno, "(cost rationale)", "Haiku is the cheap tier",
                                       "thrift claim on a non-Haiku tier", line.strip()[:100]))
                    adjudicable += 1
                    continue
                # PREFIX match, not exact (computed above). "Sonnet = quality
                # execution across the board" captures the whole clause, so demanding
                # an exact dictionary key silently matched nothing — that detector
                # looked correct and was inert until a falsifiability test fired it.
                if gloss_bad:
                    said, g, real = gloss_bad[0]
                    violations.append((rel, lineno, f"(tier gloss: {g!r})", real, said,
                                       line.strip()[:100]))
                    adjudicable += 1
                    continue

            if not found_agents and not found_roles and not found_skills and not found_phases:
                if has_tier:
                    unchecked.append((rel, lineno, line.strip()[:90]))
                continue
            if has_tier:
                adjudicable += 1
            found_tiers = {m.group(1).capitalize() for m in tier_re.finditer(line_m)}
            if not found_tiers:
                continue

            expected = {tiers[a] for a in found_agents if a in tiers}
            expected |= {ROLE_TIERS[r] for r in found_roles}
            expected |= {SKILL_TIERS[s] for s in found_skills}
            expected |= {PHASE_TIERS[p] for p in found_phases}

            # Set comparison alone lets a SWAP through: "evidence-collector (Opus)
            # + accessibility-auditor (Sonnet)" has the SAME tier set as the correct
            # ordering, so the difference is empty and it passes (Codex). When a line
            # mixes agents of different tiers AND carries more than one tier word,
            # attribution needs guessing — and guessing is what produced five
            # iterations of blind spots. Refuse, and require explicit suppression.
            if len(expected) > 1 and len(found_tiers) > 1:
                violations.append((rel, lineno, ", ".join(sorted(found_agents | found_roles | found_skills | found_phases)),
                                   ", ".join(sorted(expected)),
                                   "ambiguous — mixed tiers on one line, cannot attribute",
                                   line.strip()[:100]))
                continue

            stray = found_tiers - expected
            if stray:
                violations.append((rel, lineno, ", ".join(sorted(found_agents | found_roles | found_skills | found_phases)),
                                   ", ".join(sorted(expected)), ", ".join(sorted(stray)),
                                   line.strip()[:100]))

    for rel in unbalanced:
        print(f"  ❌ {rel}: unbalanced code fence — the file tail was not checked")

    pct = 100 * adjudicable // max(tier_lines, 1)
    gap = tier_lines - adjudicable

    def coverage() -> None:
        print(f"  Coverage: {adjudicable}/{tier_lines} tier-word lines adjudicated ({pct}%). "
              f"{gap} name a tier")
        print("  without naming a checkable agent, role or skill — this run says nothing "
              "about those.")
        if "--list-unchecked" in sys.argv:
            for rel, lineno, text in unchecked:
                print(f"     ~ {rel}:{lineno}  {text}")
        else:
            print("  Re-run with --list-unchecked to review them by hand.")

    if not violations and not unbalanced:
        print(f"  ✅ No agent tier drift in the {adjudicable} lines this gate can adjudicate")
        coverage()
        return 0

    for rel, lineno, agents, expected, stray, text in violations:
        print(f"  ❌ {rel}:{lineno}")
        print(f"     names [{agents}] (tier: {expected}) alongside [{stray}]")
        print(f"     {text}")

    total = len(violations) + len(unbalanced)
    print(f"\n  {total} issue(s). Fix the doc, fix the frontmatter, or — if the pairing is")
    print("  legitimate — put <!-- tier-ok: your reason --> on the line, or add it to")
    print("  TIER_OK_ALLOWLIST")
    print("  with a reason. Suppressions are meant to be visible and reviewable.")
    coverage()
    return 1


if __name__ == "__main__":
    sys.exit(main())
