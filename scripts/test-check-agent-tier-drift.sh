#!/usr/bin/env bash
# test-check-agent-tier-drift.sh
#
# Falsifiability harness for scripts/check-agent-tier-drift.py.
#
# WHY THIS FILE EXISTS
#   The gate it tests is a DETECTOR, and the only failure that matters for a
#   detector is silence. Reading one tells you nothing: a detector can look
#   correct, pass review, and match nothing. That is not hypothetical here —
#   TIER_GLOSS shipped INERT in one revision of this gate (it captured a whole
#   clause, then demanded an exact dictionary key, so it fired on nothing while
#   appearing complete), and the gloss-masking logic was twice "fixed" in a way
#   that opened a new false negative. Every one of those was caught by
#   deliberately re-introducing the shape, never by inspection.
#
#   So each detector class below is proved the only way a detector can be
#   proved: inject a line that MUST fail into a real repo file, assert the gate
#   exits 1 AND names that file:line, restore, assert it exits 0 again. A test
#   that only checks the clean tree is green would pass against a gate that does
#   nothing at all.
#
# WHERE THE INJECTIONS HAPPEN — a throwaway COPY of the repo, not your tree.
#   The gate globs its own repo root (REPO = __file__/../..), so the injections
#   must land in a real, fully-populated repo or they prove nothing. They do NOT
#   have to land in YOUR repo. This harness copies the working tree to a temp
#   directory once and injects there, which keeps the two properties that matter:
#     - the gate still walks a complete repo, re-rooted onto the copy, so glob
#       coverage, path-skip rules and fence scrubbing are all exercised for real;
#     - nothing can dirty the developer's tree. The previous revision injected
#       into tracked files and restored via `trap ... EXIT INT TERM`, which is
#       correct until the process dies in a way a trap cannot see (SIGKILL, an
#       OOM kill, a pulled plug) — and it left a window where a concurrent
#       `verify.sh` or a file watcher would observe deliberately-broken files.
#   The copy is seeded from the WORKING TREE, not from HEAD, so the baseline
#   check below still catches drift a developer has staged or left uncommitted —
#   which is exactly what verify.sh runs the gate against.
#
# TEST CASES — one per detector class, plus the regression shapes that six
# independent audit rounds constructed against this gate:
#   TC-TD-1   agent name + contradicting tier      ("code-reviewer runs on Sonnet")
#   TC-TD-2   tier-first ordering                  ("Sonnet powers the reality-checker")
#   TC-TD-3   role phrase                          ("a Sonnet implementing subagent")
#   TC-TD-4   skill name                           ("finishing-a-development-branch (Sonnet)")
#   TC-TD-5   phase row in a table                 ("| Verification | x | Sonnet |")
#   TC-TD-6   tier gloss                           ("Sonnet = quality execution")
#   TC-TD-7   work-type gloss                      ("Opus for doc updates")
#   TC-TD-8   no-op escalation, arrow separator    ("Opus -> Opus")
#   TC-TD-9   no-op escalation, slash separator    ("Opus/Opus")
#   TC-TD-10  stale cost rationale                 ("Sonnet because it is cheaper")
#   TC-TD-11  punctuation-hidden name              ("The Security Reviewer ... Sonnet")
#   TC-TD-12  mixed-tier swap                      (same tier SET, wrong pairing)
#   TC-TD-13  gloss entanglement                   ("Sonnet for retrieval by code-reviewer")
#   TC-TD-14  hook .sh spawn template              (the glob must reach hooks/)
#   TC-TD-15  gloss must not vouch for a neighbour ("Haiku for doc updates and code-reviewer (Haiku)")
#   TC-TD-16  a correct multi-gloss line still PASSES — the false-positive guard
#   TC-TD-17  hook deny TEMPLATE regressing to sonnet (the load-bearing string)
#   TC-TD-18  an unrelated html comment must not hide drift in agents/*.md
#   TC-TD-19  an inline tier-ok MUST still suppress inside agents/*.md
#   TC-TD-20  scripts/*.sh is globbed                (non-markdown coverage, part 2)
#   TC-TD-21  scripts/*.py is globbed                (non-markdown coverage, part 3)
#   TC-TD-22  KNOWN GAP — subject before the tier word
#   TC-TD-23  KNOWN GAP — subject in an adjacent table cell
#   TC-TD-24  KNOWN GAP — subject past a comma
#   TC-TD-25  KNOWN GAP — subject past the gloss capture's 40-char window
#   TC-TD-26  .git/ and .claude/ are skipped          (the skip rule, made executable)
#   TC-TD-27  the Fable tier word is checked          ("chief-of-staff runs on Fable")
#   TC-TD-28  the Fable tier gloss is checked         ("Opus = the orchestrator tier")
#   TC-TD-29  skills/*.md is globbed                  (spawn-decision-critical dir)
#   TC-TD-30  rules/*.md is globbed                   (the canonical tier table)
#   TC-TD-31  an UNTRACKED *.md is scanned            (the gate's documented contract)
#
# STILL UNPROBED, recorded so the next person does not have to rediscover it. Each
# of these is a gate behaviour a mutant can delete with this suite staying green:
#   - drift INSIDE a fenced code block. The gate blanks only fence delimiters and
#     adjudicates the content, which is exactly where docs put Agent(model: "…")
#     templates. Needs an offset-aware assert (the claim lands at line n-1, not
#     wc -l), so it is a helper change rather than one more case.
#   - the unbalanced-fence detector. It reports "❌ <rel>: unbalanced code fence"
#     with NO line number, so report_names structurally cannot assert it; it needs
#     its own small helper.
#   - the `if f.suffix == ".md"` guard that stops a ``` inside a .sh/.py deny
#     message from blanking the rest of the file.
#   - the adjacent-line agent carry used for box-drawing diagrams.
#
# TWO MATCHED PAIRS. Read each together; changing one half without re-running the
# other is how this gate regressed twice already.
#   15 + 16 — 15 is the recall hole a naive gloss fix opened; 16 is the correct
#             line that the over-strict fix for 15 then rejected.
#   18 + 19 — 18 is the hole where ANY html comment blanked a whole line in an
#             agent file (so a trailing note hid real drift); 19 is the documented
#             suppression that the obvious fix for 18 would otherwise destroy.
#             Both were found by an external reviewer on PR #133.
#
# THE KNOWN-GAP CASES (22-25) ARE STRICT XFAIL — read this before "fixing" one.
#   These four shapes are the residual false negatives that the masking block in
#   check-agent-tier-drift.py documents in prose. They are recorded there and
#   asserted here for the same reason: prose alone rots, and a gap nobody can
#   execute is a gap nobody will ever close. Each case injects a line the gate
#   SHOULD flag and asserts that it currently does NOT.
#
#   They are STRICT: if the gate starts catching one, this suite FAILS. That is
#   deliberate and it is good news, not a regression — a passing known-gap case
#   is this file asserting a false claim about the gate. The failure message tells
#   you the one-line promotion to make. A non-strict marker would flip silently
#   and leave the repo documenting a hole it had already fixed, which is the same
#   read-green-while-blind failure this whole harness exists to prevent.
#
#   Do NOT "fix" a gap by widening the mask window without re-running TC-TD-16
#   and TC-TD-19. The masking comment in the gate explains why widening is not
#   obviously correct: it trades these four misses for false positives on prose
#   that merely mentions an agent nearby.
#
# Run standalone. Exits non-zero on any failure. Never writes to the repo.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
GAPS=0

# ---------------------------------------------------------------------------
# Build the throwaway repo copy that every probe injects into.
# ---------------------------------------------------------------------------
# An unguarded `mktemp -d` is a footgun here: on failure it exits non-zero with
# EMPTY stdout, and `set -u` does not catch that because WORK *is* assigned, just
# empty. Every path below would then resolve to the filesystem root — `mkdir -p
# /docs/reference`, `cp ... /docs/reference/agent-list.md` — and the trap would
# become `rm -rf ""`. Check it explicitly instead.
# Named templates rather than a bare `mktemp -d`: a SIGKILL cannot run the cleanup
# trap, so killed runs DO leave a ~3 MB workspace behind. Naming them makes that
# residue self-identifying (`ls $TMPDIR/tierdrift-*`) instead of an anonymous tmp.*
# nobody can attribute. The explicit TMPDIR form works on both BSD and GNU mktemp.
# Deliberately NOT auto-reaping siblings — a test harness should not go deleting
# directories it cannot prove it owns.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tierdrift-work.XXXXXXXX")" ||
  { echo "  ❌ SETUP: mktemp -d failed"; exit 2; }
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "  ❌ SETUP: mktemp -d gave no usable dir"; exit 2; }
# Pristine snapshot of the injection targets, kept OUTSIDE $WORK so the gate never
# globs it as a second copy of the repo's markdown.
SNAP="$(mktemp -d "${TMPDIR:-/tmp}/tierdrift-snap.XXXXXXXX")" ||
  { echo "  ❌ SETUP: mktemp -d failed"; exit 2; }
[ -n "$SNAP" ] && [ -d "$SNAP" ] || { echo "  ❌ SETUP: mktemp -d gave no usable dir"; exit 2; }

# The developer's tree is never touched, so cleanup only has to remove temp dirs.
# INT/TERM must EXIT, not just clean up: this trap DESTROYS the workspace, and the
# old tracked-file version merely restored files, so falling through was harmless
# there and is not here. Without the explicit exit, bash runs the handler and then
# CONTINUES the script — every later probe would run against a deleted workspace,
# and because `assert_known_gap` passes on "gate did not flag it", all four gap
# cases would report "still blind" against a workspace that no longer exists.
cleanup() { rm -rf "$WORK" "$SNAP"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# Copy TRACKED files only, taken from the WORKING TREE.
#
# HONEST TRADEOFF, because the reason matters more than the rule: the gate does
# NOT limit itself to committed content. Its own docstring says it scans every
# *.md in the working tree including untracked scratch files, deliberately, on the
# grounds that a stale draft is still wrong. Reproducing that faithfully here would
# mean copying arbitrary local files — a developer's .env, a scratch dump of
# production data — into a temp dir that outlives a SIGKILL. That is not a trade a
# test harness should make, so this copy is tracked-files-only.
#
# The consequence is NOT that the untracked path goes unprobed. Copying none of the
# developer's untracked files does not stop us SYNTHESISING one inside the disposable
# copy, which is what TC-TD-31 does — see it for the full argument. Do NOT "simplify"
# the gate to tracked-only to match this copy strategy: scanning untracked files is
# documented behaviour of the gate, and TC-TD-31 is what holds it in place.
#
# Uncommitted EDITS to tracked files DO come along, because each file is copied
# from the working tree rather than from HEAD, so the baseline check below still
# refuses to run against a tree the developer has already broken.
#
# .git and .claude are skipped: the gate skips both by path anyway, and .claude can
# contain nested worktrees that would make the copy needlessly large. TC-TD-26
# below is what proves that omission has not disabled the gate's own skip rule.
_want=0
_got=0
while IFS= read -r -d '' _rel; do
  case "$_rel" in .git/*|.claude/*) continue ;; esac
  _want=$((_want + 1))
  # `dirname` rather than ${_rel%/*} — the parameter form silently yields the
  # FILENAME for a top-level path like README.md, which would scatter files.
  mkdir -p "$WORK/$(dirname "$_rel")" || continue
  cp "$REPO_ROOT/$_rel" "$WORK/$_rel" 2>/dev/null && _got=$((_got + 1))
done < <(cd "$REPO_ROOT" && git ls-files -z)

# Count the copy instead of spot-checking it. Every probe runs against this
# workspace, so a silently partial copy weakens all of them IN THE PASS DIRECTION
# while the suite still reports green — demonstrated in review by deleting two
# unrelated files and watching the suite stay at 22/22. Spot-checking the handful
# of files the probes target cannot see that; a count can. This also covers the
# symlink case (`cp` without -P dereferences, and a symlink-to-dir fails).
if [ "$_want" -ne "$_got" ]; then
  echo "  ❌ SETUP: copied only $_got of $_want tracked files — probes would be weakened"
  exit 2
fi
# `-ne` alone is vacuously satisfied at 0 == 0, so a `git ls-files` that returns
# nothing (not a repo, git missing, shadowed by a broken stub) would sail past it and
# then fail further down with a misleading "repo copy is incomplete".
if [ "$_want" -eq 0 ]; then
  echo "  ❌ SETUP: git ls-files listed no tracked files — is $REPO_ROOT a git repo?"
  exit 2
fi

# Give the workspace its own git index so "tracked" vs "untracked" is a REAL
# distinction inside it. Without this, $WORK has no .git at all, so a file created
# there is neither tracked nor untracked and TC-TD-31 could not tell the difference —
# it would pass against a gate that had started filtering by the git index.
# `git add -A` alone is enough: `git ls-files` reads the INDEX, so no commit (and no
# user identity config) is needed. Cheap — ~1s for the whole tree.
git init -q "$WORK" 2>/dev/null
git -C "$WORK" add -A 2>/dev/null
if ! git -C "$WORK" ls-files --error-unmatch "scripts/check-agent-tier-drift.py" >/dev/null 2>&1; then
  echo "  ❌ SETUP: could not build a git index in the workspace — TC-TD-31 would be vacuous"
  exit 2
fi

GATE="$WORK/scripts/check-agent-tier-drift.py"

# Files used as injection targets, as repo-relative paths — relative because the
# gate reports `❌ <relative path>:<line>` and the assertions below match that
# exact string. Basenames alone would be ambiguous across directories.
DOC="docs/reference/agent-list.md"
CMD="commands/flow.md"
HOOK="hooks/enforce-pr-skill.sh"
# agents/*.md takes a different scrub path (HTML-comment handling), so it
# needs its own target — bugs there are invisible via the doc targets.
AGENT="agents/api-tester.md"
# Non-markdown targets under scripts/. The gate globs scripts/*.sh and
# scripts/*.py as well as hooks/*.sh, but only the hooks glob was covered before,
# so a regression that dropped either scripts glob would have gone unnoticed.
SCRIPT_SH="scripts/verify.sh"
SCRIPT_PY="scripts/check-jira-comment-ordering.py"
# skills/ and rules/ are named in the gate's own docstring as files read AT THE
# SPAWN DECISION POINT, which makes stale tiers there more load-bearing than in
# reference docs — yet neither directory had a probe. Both are covered now: naming
# them together and then probing only one is how the previous revision of this
# comment ended up describing coverage it did not have.
SKILL="skills/agent-orchestration/SKILL.md"
# rules/performance.md specifically, because it holds the canonical four-tier table
# AND is always-loaded context — the single most load-bearing tier file in the repo.
RULE="rules/performance.md"

TARGETS="$DOC $CMD $HOOK $AGENT $SCRIPT_SH $SCRIPT_PY $SKILL $RULE"

# Snapshot the targets before any injection. Restoring from this snapshot rather
# than re-reading $REPO_ROOT makes the suite hermetic: a concurrent edit to one of
# these files during the ~35s run cannot shift the baseline mid-suite.
for _rel in $TARGETS; do
  mkdir -p "$SNAP/$(dirname "$_rel")"
  cp "$WORK/$_rel" "$SNAP/$_rel" 2>/dev/null
done

# A partial copy would weaken every probe below while still letting the baseline
# pass, so verify the copy is usable rather than trusting cp's exit code. Both the
# workspace AND the snapshot are checked: a missing snapshot makes restore() a
# silent no-op, which fails safe today but would be a confusing way to find out.
for _rel in $TARGETS; do
  if [ ! -f "$WORK/$_rel" ]; then
    echo "  ❌ SETUP: repo copy is incomplete — missing $_rel"
    exit 2
  fi
  if [ ! -f "$SNAP/$_rel" ]; then
    echo "  ❌ SETUP: snapshot is incomplete — missing $_rel (restore would no-op)"
    exit 2
  fi
  # Every probe appends a line and then uses `wc -l` as that line's number. A target
  # not ending in a newline would merge the payload into its last line, so the probe
  # would silently adjudicate a DIFFERENT string than the case claims to test.
  if [ -n "$(tail -c 1 "$WORK/$_rel")" ]; then
    echo "  ❌ SETUP: $_rel does not end in a newline — appended probes would merge"
    exit 2
  fi
done
if [ ! -f "$GATE" ]; then
  echo "  ❌ SETUP: repo copy is incomplete — missing scripts/check-agent-tier-drift.py"
  exit 2
fi

gate_rc() { python3 "$GATE" >/dev/null 2>&1; echo $?; }

# Capture the gate's REPORT, not just its exit code. automated-review on PR #133: the
# header claimed each case asserts the gate "names that file", and it did not —
# only the exit code was checked. That gap matters because these injections run
# against a real tree: a case could pass on a violation the gate found somewhere
# ELSE entirely, which is the same class of false confidence the gate exists to
# stop. Now the reported path must match the file we injected into.
gate_report() { python3 "$GATE" 2>&1; }

# Undo a probe by restoring from the pre-injection SNAPSHOT, not from $REPO_ROOT.
# Reading the live tree on every one of the ~25 probes would let a concurrent edit
# to a target file move the baseline halfway through the run.
restore() { cp "$SNAP/$1" "$WORK/$1"; }

# report_names <report> <rel> <line-number> — did the gate flag this exact spot?
# Escape dots so the path matches literally, and require a non-digit (or end of
# line) after the number so line 12 does not satisfy a check for line 1.
report_names() {
  local report="$1" rel="$2" want="$3"
  local rel_re="${rel//./\\.}"
  printf '%s' "$report" | grep -qE "❌ ${rel_re}:${want}([^0-9]|$)"
}

# assert_detects <id> <description> <target-rel> <line-to-append>
#
# The gate must exit 1 with the line present and 0 once it is removed. Checking
# BOTH directions is the point: a gate that always exits 1 would pass a
# one-directional test while being useless.
assert_detects() {
  local id="$1" desc="$2" rel="$3" line="$4"
  printf '%s\n' "$line" >> "$WORK/$rel"
  # The injected line is now the LAST line, so its number is the file's line
  # count. Assert that exact location, not just the path: automated-review's follow-up on
  # PR #133 pointed out that matching the path alone passes if the target file
  # already holds another violation, or if the gate reports a DIFFERENT line in
  # the same file — the appended shape could go undetected and the case would
  # still report green. That is the same false-confidence class twice over.
  local want; want=$(wc -l < "$WORK/$rel" | tr -d '[:space:]')
  local report; report=$(gate_report)
  local drift=$?
  local named="no"
  report_names "$report" "$rel" "$want" && named="yes"
  restore "$rel"
  local clean; clean=$(gate_rc)
  if [ "$drift" = "1" ] && [ "$named" = "yes" ] && [ "$clean" = "0" ]; then
    printf '  ✅ %-10s %s\n' "$id" "$desc"; PASS=$((PASS + 1))
  else
    printf '  ❌ %-10s %s (drift=%s want 1, named-%s=%s want yes, restored=%s want 0)\n' \
      "$id" "$desc" "$drift" "$rel" "$named" "$clean"; FAIL=$((FAIL + 1))
  fi
}

# assert_allows — a line that is CORRECT must not be flagged. Without this the
# obvious way to make every other test pass is to flag everything.
assert_allows() {
  local id="$1" desc="$2" rel="$3" line="$4"
  printf '%s\n' "$line" >> "$WORK/$rel"
  local rc; rc=$(gate_rc)
  restore "$rel"
  if [ "$rc" = "0" ]; then
    printf '  ✅ %-10s %s\n' "$id" "$desc"; PASS=$((PASS + 1))
  else
    printf '  ❌ %-10s %s (rc=%s want 0 — false positive)\n' "$id" "$desc" "$rc"
    FAIL=$((FAIL + 1))
  fi
}

# assert_known_gap <id> <description> <target-rel> <line-to-append>
#
# STRICT XFAIL — see "THE KNOWN-GAP CASES" in the header. Injects a line the gate
# SHOULD flag and asserts it currently does not. If the gate learns to catch it,
# this FAILS on purpose so the case gets promoted instead of silently rotting.
#
# The verdict keys off whether the gate named THIS file:line, not off the exit
# code: a gap case must not be able to pass just because the gate happened to
# find something unrelated elsewhere in the copy.
assert_known_gap() {
  local id="$1" desc="$2" rel="$3" line="$4"
  printf '%s\n' "$line" >> "$WORK/$rel"
  local want; want=$(wc -l < "$WORK/$rel" | tr -d '[:space:]')
  local report; report=$(gate_report)
  local rc=$?
  local named="no"
  report_names "$report" "$rel" "$want" && named="yes"
  restore "$rel"
  # Requiring rc=0 as well as "not named" is the fix for a false-green this helper
  # shipped with: keying on `named` ALONE cannot tell "the gate is blind to this
  # shape" from "the gate CRASHED on this input" or "the gate complained in a shape
  # report_names cannot match" (the unbalanced-fence path, for instance, prints no
  # line number). A gate mutant that raised only on the TC-TD-25 payload produced a
  # green 22/22 and a green verify.sh — the precise read-green-while-blind failure
  # this file exists to prevent, reintroduced by its newest helper.
  #
  # This cannot false-fail today: all four gap payloads leave the gate at rc=0,
  # verified against the real gate. A non-zero rc here means something changed that
  # the maintainer needs to look at, whether or not this shape was the cause.
  if [ "$named" = "no" ] && [ "$rc" = "0" ]; then
    printf '  ⚠️  %-10s KNOWN GAP still blind: %s\n' "$id" "$desc"
    GAPS=$((GAPS + 1))
  elif [ "$named" = "no" ]; then
    printf '  ❌ %-10s gate did NOT flag this line but exited %s: %s\n' "$id" "$rc" "$desc"
    printf '     Blind and broken are different outcomes. The gate errored, or it\n'
    printf '     reported drift in a shape/location this case cannot match, so the\n'
    printf '     known-gap claim is unproven rather than confirmed. Run the gate by\n'
    printf '     hand against the injected line before touching this case.\n'
    FAIL=$((FAIL + 1))
  else
    # This one line has to stand alone: verify.sh surfaces only lines containing
    # ❌, so the actionable instruction cannot live solely in the detail below.
    printf '  ❌ %-10s GAP CLOSED (good news) — promote it to assert_detects: %s\n' "$id" "$desc"
    printf '     The gate now DETECTS this shape — that is an improvement, not a bug.\n'
    printf '     Promote it: change assert_known_gap to assert_detects for %s, then\n' "$id"
    printf '     update ALL FIVE places that describe the gap — the case list and the\n'
    printf '     "KNOWN-GAP CASES" prose in this header, the inline block above these\n'
    printf '     cases (it claims all four positions are unseen), the residual-false-\n'
    printf '     negative note in check-agent-tier-drift.py, and the ✅ floor in\n'
    printf '     scripts/verify.sh (promotion moves a case from ⚠️ to ✅).\n'
    printf '     Re-run TC-TD-16 and TC-TD-19 before you trust the fix.\n'
    FAIL=$((FAIL + 1))
  fi
}

echo "======================================"
echo "check-agent-tier-drift falsifiability"
echo "======================================"

# Baseline first. If the copied tree is already failing, every assert_detects
# below would report a spurious pass, so refuse to run rather than report a
# green lie.
BASE_REPORT=$(gate_report)
BASE=$?
if [ "$BASE" != "0" ]; then
  echo "  ❌ SETUP: gate is not green on the current tree (rc=$BASE)."
  echo "     Fix the reported drift first — these tests cannot distinguish"
  echo "     'detector fired' from 'tree was already failing'."
  # Print what the gate actually said. Telling someone to "fix the reported drift"
  # while discarding the report leaves them to re-run the gate by hand, and an rc=2
  # crash in the gate reads identically to real drift without it.
  printf '%s\n' "$BASE_REPORT" | grep -E '❌|Traceback|Error' | head -10 |
    while IFS= read -r _l; do echo "     $_l"; done
  exit 1
fi
echo "  ✅ SETUP     gate green on clean tree (isolated copy)"
PASS=$((PASS + 1))

assert_detects TC-TD-1  "agent name + contradicting tier" "$DOC" \
  'code-reviewer runs on Sonnet.'
assert_detects TC-TD-2  "tier-first ordering" "$DOC" \
  'Sonnet powers the reality-checker.'
assert_detects TC-TD-3  "role phrase" "$DOC" \
  'Spawn a Sonnet implementing subagent.'
assert_detects TC-TD-4  "skill name" "$DOC" \
  'Skill: finishing-a-development-branch (Sonnet)'
assert_detects TC-TD-5  "phase row in a table" "$CMD" \
  '| Verification | some skill | Sonnet |'
assert_detects TC-TD-6  "tier gloss" "$DOC" \
  'Sonnet = quality execution across the board.'
assert_detects TC-TD-7  "work-type gloss" "$DOC" \
  'Use Opus for doc updates and Jira.'
assert_detects TC-TD-8  "no-op escalation (arrow)" "$DOC" \
  'Escalates Opus -> Opus when complex.'
assert_detects TC-TD-9  "no-op escalation (slash)" "$DOC" \
  'The tier column reads Opus/Opus here.'
assert_detects TC-TD-10 "stale cost rationale" "$DOC" \
  'The subagent uses Sonnet because it is cheaper.'
assert_detects TC-TD-11 "punctuation-hidden name" "$DOC" \
  'The Security Reviewer runs on Sonnet.'
assert_detects TC-TD-12 "mixed-tier swap" "$DOC" \
  'evidence-collector (Opus) and code-reviewer (Sonnet) both run.'
assert_detects TC-TD-13 "gloss entanglement" "$DOC" \
  'Sonnet for retrieval by code-reviewer on every diff.'
assert_detects TC-TD-14 "hook .sh spawn template" "$HOOK" \
  '# spawn a Sonnet implementing subagent'
assert_detects TC-TD-15 "gloss must not vouch for a neighbour" "$DOC" \
  'Haiku for doc updates and code-reviewer (Haiku) handle the tail.'

# TC-TD-17 — the hook deny TEMPLATES specifically. automated-review's point on PR #133:
# `permissionDecisionReason` is not prose, it is the concrete Agent(...) call the
# orchestrator is expected to copy when delegation is denied, and shipping
# `model: "sonnet"` there caused real downgrades. This asserts that a spawn template
# in a hook file is adjudicated at all, rather than only prose near it.
#
# Scope, honestly: detection here comes from the [DELEGATED] role phrase plus the
# tier word, NOT from the literal `"sonnet"` byte string — the backslashes below are
# shell escapes that survive into the file, so this fixture is not the exact quoted
# form a real deny message carries. It still pins the behaviour that matters (a hook
# spawn template with a stale tier fails the build); it just does not pin the quoting.
assert_detects TC-TD-17 "hook deny template regressing to sonnet" "$HOOK" \
  'reason: Agent(model: \"sonnet\", prompt: \"[DELEGATED] You are a subagent\")'

# TC-TD-18 — an UNRELATED html comment must not blank the line in agents/*.md.
# The old scrub() blanked the whole line on any comment, so a trailing note
# silently hid real drift; the tier-ok marker could never be honoured either.
assert_detects TC-TD-18 "unrelated html comment does not hide drift" "$AGENT" \
  'code-reviewer runs on Sonnet. <!-- an unrelated note -->'

# TC-TD-20 / TC-TD-21 — the remaining non-markdown globs. The gate deliberately
# scans scripts/*.sh and scripts/*.py too (it self-excludes only the gate and this
# harness, whose tier words are fixtures rather than claims). Until these cases
# existed, dropping either scripts glob broke nothing in this suite — the same
# silent-coverage-loss shape TC-TD-14 was added to close for hooks/.
assert_detects TC-TD-20 "scripts/*.sh is globbed" "$SCRIPT_SH" \
  '# note: reality-checker is a Haiku agent'
assert_detects TC-TD-21 "scripts/*.py is globbed" "$SCRIPT_PY" \
  '# note: code-reviewer runs on Sonnet.'

# TC-TD-29 — skills/ had no probe at all. The gate's docstring singles out skills/
# and rules/ as files consulted AT THE SPAWN DECISION POINT, which makes a stale
# tier there more directly harmful than one in a reference table, so "we cover
# docs/ and commands/" was not good enough.
assert_detects TC-TD-29 "skills/*.md is globbed" "$SKILL" \
  'code-reviewer runs on Sonnet.'

# TC-TD-30 — rules/*.md, the other half of the spawn-decision pair. Adding "rules/"
# to the gate's skip tuple left the suite at a fully green 26/26 before this case
# existed, which is the same mutant shape TC-TD-29 kills for skills/. rules/ matters
# more, not less: rules/performance.md is the canonical tier table and is always
# loaded, so a stale tier there is read on every single spawn decision.
assert_detects TC-TD-30 "rules/*.md is globbed" "$RULE" \
  'code-reviewer runs on Sonnet.'

# TC-TD-31 — the gate must scan an UNTRACKED markdown file.
#
# automated-review on PR #135 (🟡, this file:169). The gate's docstring commits to scanning
# every *.md in the working tree INCLUDING untracked scratch files — "a stale draft is
# still wrong". Moving injections into a tracked-files-only copy meant a regression
# that made the gate skip untracked files would read GREEN here, and verify.sh's direct
# gate run would not catch it either, because a clean tree has no untracked drift to
# find. Disclosed-but-unprobed is the same shape as TC-TD-30's, and disclosure is not
# coverage.
#
# The fix does NOT require copying the developer's untracked files. This creates a NEW
# file inside the disposable workspace, after `git add -A` built the index, so it is
# genuinely untracked in git's eyes while containing nothing but our own fixture. The
# leak concern was about copying arbitrary local files IN; synthesising one costs
# nothing.
_untracked="docs/tier-drift-untracked-probe.md"
printf 'code-reviewer runs on Sonnet.\n' > "$WORK/$_untracked"
# Prove the premise before trusting the probe: if this file were somehow tracked, the
# case would silently degrade into a duplicate of TC-TD-1.
if git -C "$WORK" ls-files --error-unmatch "$_untracked" >/dev/null 2>&1; then
  printf '  ❌ %-10s %s (fixture is TRACKED — case would be vacuous)\n' \
    "TC-TD-31" "untracked *.md is scanned"; FAIL=$((FAIL + 1))
else
  _u_report=$(gate_report)
  _u_rc=$?
  _u_named="no"
  report_names "$_u_report" "$_untracked" 1 && _u_named="yes"
  rm -f "$WORK/$_untracked"
  _u_clean=$(gate_rc)
  if [ "$_u_rc" = "1" ] && [ "$_u_named" = "yes" ] && [ "$_u_clean" = "0" ]; then
    printf '  ✅ %-10s %s\n' "TC-TD-31" "untracked *.md is scanned"; PASS=$((PASS + 1))
  else
    printf '  ❌ %-10s %s (drift=%s want 1, named=%s want yes, restored=%s want 0)\n' \
      "TC-TD-31" "untracked *.md is scanned" "$_u_rc" "$_u_named" "$_u_clean"
    FAIL=$((FAIL + 1))
  fi
fi

# TC-TD-27 / TC-TD-28 — the Fable tier had ZERO coverage. That matters more than a
# missing case normally would: TIER_WORDS gates `has_tier`, which gates EVERY
# detector branch, so dropping Fable from it silently disables all Fable checking
# at once. Both mutants (TIER_WORDS, and the orchestrator/thinker glosses) survived
# the suite before these existed.
assert_detects TC-TD-27 "Fable tier word is checked" "$DOC" \
  'chief-of-staff runs on Fable.'
assert_detects TC-TD-28 "Fable tier gloss is checked" "$DOC" \
  'Opus = the orchestrator tier.'

# The matched false-positive guard for TC-TD-15. Every tier here is correct and
# pinned to its own subject; the gate must stay quiet.
assert_allows  TC-TD-16 "correct multi-gloss line is allowed" "$DOC" \
  'Claude uses Opus for chief-of-staff, Opus for most reviewers, Haiku for doc updates.'

# TC-TD-19 — matched pair with TC-TD-18: fixing the blanking must not break the
# documented escape hatch. An inline tier-ok inside an agent file must suppress.
assert_allows  TC-TD-19 "inline tier-ok works inside agents/*.md" "$AGENT" \
  'code-reviewer runs on Sonnet. <!-- tier-ok: deliberate counter-example -->'

# TC-TD-26 — the gate's `.git/` and `.claude/` path skip.
#
# This exists because the header used to CLAIM the copy exercised "path-skip rules"
# and it did not: the copy omits those directories entirely, so there was nothing
# for the skip to act on and the rule was dead code from the harness's point of
# view. Review proved it — deleting the skip from the gate left the suite at a green
# 22/22 while the gate had genuinely regressed. Seeding decoys converts the claim
# into something executable, which is this file's whole design principle.
#
# The regression direction is false-POSITIVE (a dev machine with .claude worktrees
# full of markdown suddenly fails the build), which is why it is worth an assertion
# even though it cannot let real drift through.
mkdir -p "$WORK/.claude"
printf 'code-reviewer runs on Sonnet.\n' > "$WORK/.claude/decoy.md"
printf 'code-reviewer runs on Sonnet.\n' > "$WORK/.git/decoy.md"
_skip_rc=$(gate_rc)
# Remove the decoy FILES only. $WORK/.git holds the workspace's git index (built at
# setup so TC-TD-31 can distinguish tracked from untracked) — `rm -rf $WORK/.git`
# here would silently destroy it and make TC-TD-31 vacuous.
rm -rf "$WORK/.claude"
rm -f "$WORK/.git/decoy.md"
if [ "$_skip_rc" = "0" ]; then
  printf '  ✅ %-10s %s\n' "TC-TD-26" ".git/ and .claude/ are skipped"; PASS=$((PASS + 1))
else
  printf '  ❌ %-10s %s (rc=%s want 0 — the path skip regressed)\n' \
    "TC-TD-26" ".git/ and .claude/ are skipped" "$_skip_rc"; FAIL=$((FAIL + 1))
fi

# -------------------------------------------------------------------------
# KNOWN GAPS (strict xfail) — the four residual false negatives that the
# masking block in check-agent-tier-drift.py documents in prose.
#
# All four share one mechanism. "Sonnet for retrieval" is a CORRECT gloss, so the
# gate masks that span out of the line; the mask consumes the line's only tier
# word, and the wrong claim about code-reviewer (which is Opus) loses the tier it
# was contradicting. The entanglement guard that would catch this only inspects
# the remainder of the gloss's OWN capture group — at most 40 chars, terminated
# by ) , . | ; — so a subject placed outside that window survives.
#
# Each case below puts `code-reviewer` in one of the four positions the gate
# cannot see. If any starts failing, the gate improved: promote it.
# -------------------------------------------------------------------------
assert_known_gap TC-TD-22 "subject before the tier word" "$DOC" \
  'code-reviewer uses Sonnet for retrieval.'
assert_known_gap TC-TD-23 "subject in an adjacent table cell" "$DOC" \
  '| Sonnet for retrieval | code-reviewer |'
assert_known_gap TC-TD-24 "subject past a comma" "$DOC" \
  'Sonnet for retrieval, which is what code-reviewer does.'
assert_known_gap TC-TD-25 "subject past the 40-char capture window" "$DOC" \
  'Sonnet for retrieval and assorted lookup chores by code-reviewer.'

echo "======================================"
if [ "$GAPS" -gt 0 ]; then
  echo "Tier-drift tests: $PASS/$((PASS + FAIL)) passed, $GAPS known gap(s) still blind"
else
  echo "Tier-drift tests: $PASS/$((PASS + FAIL)) passed"
fi
echo "======================================"
[ "$FAIL" -eq 0 ]
