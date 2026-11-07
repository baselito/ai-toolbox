#!/usr/bin/env bash
# sync-toolbox-lessons.sh
#
# Installs the durable toolbox-lessons knowledge pack into ~/.claude/toolbox-knowledge/.
#
# WHY this script exists:
#   The merge-time self-improvement loop (Phase 1) collects review findings from
#   automated-review and Codex, has an AI+Codex consensus decide which to keep, and
#   appends the kept lessons to knowledge/toolbox-lessons.yml (via a human-gated
#   PR). This script makes those lessons available to review agents at runtime —
#   the same principle as sync-codex-knowledge.sh, but the source is IN-REPO
#   (no network needed).
#
# What it produces in ~/.claude/toolbox-knowledge/:
#   - toolbox-lessons.yml   (SLOW tier — full copy; all lessons including superseded)
#   - lessons.yml           (FAST tier — active-only, sorted by occurrences desc
#                            then last_seen desc, TRUNCATED at 8 KB cap, with the
#                            `sources:` provenance list PROJECTED AWAY)
#   - lessons-decisions.tsv (DECISION MANIFEST — one row per lesson block the
#                            capping pass considered; see below)
#   - README.md             (explains the pack to anyone who opens the directory)
#
# ⛔ ONE PARSER. THE GENERATOR EMITS ITS DECISIONS; NOTHING ELSE RE-DERIVES THEM. ⛔
#   Every silent-eviction bug this file has had came from the same shape: a bash
#   check re-deriving in grep/awk what the python pass had already computed in
#   `re`, and diverging from it. Three rounds re-transcribed those regexes more
#   carefully and each round a new divergence turned up, in BOTH directions —
#   a `status:` written across two lines is active to python and invisible to a
#   single-line grep (issue #151 P0-2), while `priority: -high` is ordinary to
#   python and HIGH to a leading-punctuation-stripping awk. So the python pass
#   now WRITES DOWN what it decided, per lesson: id, resolved priority, resolved
#   status, occurrences, projected bytes, and whether the block was kept, evicted
#   at the cap, or excluded as non-active. Everything downstream — this script's
#   own guards and the unit-test harness alike — reads THAT file. There is no
#   second regex over `priority:` or `status:` anywhere outside the python pass,
#   and adding one would reopen the whole class.
#
#   Format: TAB-separated, one row per lesson block in SOURCE order, opened by a
#   `#run\t<tag>` line naming the run that wrote it and terminated by a `#END`
#   sentinel. `#`-initial lines are metadata, skipped by every row reader. The
#   two markers answer different questions ABOUT THE RECORD, and both are
#   compared rather than merely stored: `#END` says the record is COMPLETE, and
#   `#run` says THIS RECORD was written by this run rather than by a concurrent
#   sync that replaced it at the shared path. A missing sentinel or a foreign tag
#   sends the run to exit 4, not to a silent 0.
#   ⛔ NEITHER MARKER SAYS ANYTHING ABOUT THE FAST TIER BESIDE THE RECORD. ⛔ The
#   tier is still a shared fixed name, so a peer can replace it independently of
#   the record; binding the two needs a lock or a generation marker and remains a
#   documented residual (see the atomic-write note and the pack README below).
#   The reader takes ONE copy of the file and answers BOTH questions from it:
#   validating the tag from one open and counting rows from another would let a
#   peer swap the record in between, so the tag would pass and the rows would
#   still be someone else's. Columns:
#     1 id  2 priority(high|normal)  3 status(as resolved; empty if none)
#     4 occurrences  5 projected bytes  6 disposition(kept|evicted|excluded)
#   TSV is safe by construction here: python captures ids as [\w.-]+ and status
#   as \w+, neither of which can contain a tab.
#
#   WHY IT LIVES IN THE PACK DIRECTORY and not in a mktemp file: the caller has
#   to be able to read it AFTER this script exits. The previous eviction manifest
#   was a mktemp file removed by the EXIT trap, so nothing outside the run could
#   ever see it. The pack directory is per-HOME (a test harness pointing HOME at
#   a temp dir gets its own copy and never touches the developer's ~/.claude), it
#   already holds the two tiers this file describes, and it is rewritten every
#   run. To keep a PRIOR run's manifest from ever reading as this one's, the file
#   is deleted before the python pass starts.
#
# Exit codes:
#   0  pack written, every active lesson reached the fast tier (or only
#      ordinary-priority lessons were evicted, and each one was reported)
#   3  pack written but the FAST TIER IS EMPTY while the source declares active
#      lessons — agents read NOTHING
#   4  the run COULD NOT CONFIRM that every
#      `priority: high` lesson reached the fast tier. That has FIVE causes and the
#      exit code does not distinguish them — only the stderr does. Note that (d)
#      and (e) describe a record that is PRESENT AND WELL-FORMED, which is the
#      state a reader is least likely to guess escalates:
#        a. one was evicted at the cap (it is named on stderr), or
#        b. the decision manifest was missing, truncated, or not TERMINATED by
#           its `#END` sentinel, so no eviction could be ruled out and the guard
#           reported rather than stayed silent, or
#        c. the capping pass recorded its decisions IN FULL and then exited
#           non-zero. Its verdicts are readable, so every eviction IS named on
#           this path — the escalation is because the tier on disk is not
#           guaranteed to match the record, not because nothing could be read, or
#        d. the record is complete but carries ANOTHER run's `#run` tag — a
#           concurrent sync sharing this HOME replaced it mid-run. Its verdicts
#           describe that run's fast tier, so nothing in them rules out an
#           eviction here. Detected, not prevented: the syncs are not serialised.
#        e. a READER of the record failed (a count, or the eviction extractor).
#           The record may be perfect and still unreadable by this run; an empty
#           eviction list from a failed read is not the same as nothing evicted.
#      ⛔ 4 does NOT mean "a high lesson was definitely dropped". ⛔ Cases (b) and
#      (c) are BOTH reachable with no high-priority lesson in the source at all,
#      and the unit suite produces exactly that state, so any message asserting a
#      high eviction outright is false there. Nor does 4 mean "nothing could be
#      named": (a) and (c) name every eviction; only (b) cannot. And 4 does NOT
#      promise a usable fast tier — on (c) the pass can land its manifest and
#      then die before replacing the tier, leaving NO lessons.yml at all on a
#      fresh HOME. The slow tier is the only thing 4 guarantees is on disk.
#   Callers (install.sh, update.sh) map 3 and 4 to their own messages and
#   continue: neither aborts the install, because the SLOW tier — the full
#   lesson set — is written before either condition can arise.
#
# Fail-soft semantics (mirroring sync-codex-knowledge.sh lines ~35-56):
#   If the in-repo source is missing or unreadable, WARN and leave any existing
#   pack intact. Never clobber a good pack with nothing.
#
# Source override for testing:
#   Set SOURCE_OVERRIDE=/path/to/file.yml to point at an alternative source.
#   Tests use this to inject temp files without rewriting SCRIPT_DIR logic.
#
# Usage:
#   bash scripts/sync-toolbox-lessons.sh            # full output
#   bash scripts/sync-toolbox-lessons.sh --quiet    # suppress info lines
#
# Dependencies:
#   - python3 (preferred, for YAML-aware sort/filter/cap)
#
# 8 KB fast-tier cap rationale:
#   Review prompts already carry automated-review memories (~12 KB) + distilled concepts
#   + diff content. Lessons are advisory context, not the primary signal. Capping
#   at 8 KB keeps total prompt size manageable while still injecting the most
#   frequently-seen, most-recently-reinforced lessons. Lessons beyond the cap
#   remain fully intact in the slow tier.
#
# ⛔ FAST TIER IS NEVER UNCAPPED ⛔
#   Consumers (skills/code-review-orchestration/SKILL.md, skills/codex-review/
#   SKILL.md) inject the fast tier into review prompts ASSUMING it is ≤ 8 KB. If
#   the python3 capping cannot run (python3 absent, or the python pass fails), we
#   must NOT `cp` the full slow tier verbatim as the fast tier — that produces an
#   UNCAPPED file that blows the prompt budget. Instead the fallback either
#   PRESERVES a previously-built (already-capped) fast tier, or emits a
#   HEADER-ONLY/EMPTY fast tier. See fast_tier_fallback() below.

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
QUIET=false
[[ "${1:-}" == "--quiet" ]] && QUIET=true
info() { [[ "$QUIET" == "true" ]] || printf 'ℹ️  %s\n' "$1"; }
warn() { printf '⚠️  %s\n' "$1" >&2; }

# ---------------------------------------------------------------------------
# fast_tier_fallback — safe degraded fast tier when python3 capping is unavailable.
#
# WHY this exists (P1-B fix): the previous fallback `cp "$SLOW_DEST" "$FAST_DEST"`
# copied the FULL slow tier verbatim, producing an UNCAPPED fast tier. Consumers
# (code-review-orchestration / codex-review skills) inject the fast tier assuming
# it is ≤ 8 KB, so an uncapped copy silently blows the review-prompt budget.
#
# Safe degradation, in priority order:
#   1. If a previously-built fast tier already exists at $FAST_DEST, PRESERVE it
#      untouched (it was capped by a prior successful python run) and WARN. Stale
#      lessons are advisory and degrade gracefully; an uncapped file does not.
#   2. Otherwise emit a HEADER-ONLY / EMPTY fast tier (schema_version + empty
#      lessons list) so consumers get a valid, bounded file with zero lessons.
#
# NEVER writes an uncapped copy of the slow tier. The caller passes a human-
# readable reason describing why capping was skipped (for the WARN message).
#
# ⛔ "PRIOR" IN BRANCH 1 IS KNOWN, NOT INFERRED FROM A FILE BEING THERE. ⛔ It
# used to be inferred, and it was wrong: python wrote $FAST_DEST and only then
# wrote its manifest, so a pass that failed AFTER the tier write left a file that
# this branch found, called a prior capped tier, and preserved — while the whole
# eviction-report block was skipped because it sat in the `else` of the failure
# test. Measured on a fresh HOME where no tier had ever existed: exit 0, 2 of 3
# high lessons present, zero eviction lines on stderr (issue #151 P0-1).
#
# What decides it now is $PRIOR_FAST — a copy this script takes of $FAST_DEST
# before anything can touch it. Non-empty means a tier really did predate this
# run; empty means any file at $FAST_DEST is this run's own, whatever failed
# afterwards and whoever removed what. That holds for a pass killed mid-write,
# a manifest deleted underneath the run, or any other state, because it is a
# fact recorded up front rather than a deduction from the aftermath.
# ---------------------------------------------------------------------------
fast_tier_fallback() {
  local reason="$1"
  # ⛔ THE SNAPSHOT MUST STILL BE THERE, NOT JUST NAMED. ⛔ This was
  # `[[ -n "$PRIOR_FAST" ]]` — a STRING test on the path, which is set as soon as a
  # prior tier existed. If the file itself had gone (a peer run's trap used to
  # delete it by fixed name), the `cp` below failed and `set -euo pipefail` killed
  # the script at exit 1: an undocumented code, no message, on the one path that
  # exists to KEEP lessons when capping fails. Testing the file means a vanished
  # snapshot degrades to the branches below instead of destroying the run.
  if [[ -n "$PRIOR_FAST" && -f "$PRIOR_FAST" ]]; then
    # A prior capped fast tier existed when this run started, and $PRIOR_FAST is
    # this script's own copy of it taken before anything could touch it. Copy it
    # back rather than just leaving $FAST_DEST alone: the file sitting there may
    # be this run's output, and the snapshot is the only version we can vouch for
    # as both capped and complete. When nothing overwrote it the copy is a no-op.
    cp "$PRIOR_FAST" "$FAST_DEST"
    warn "Fast-tier capping unavailable ($reason) — restored the capped fast tier that existed before this run at $FAST_DEST (NOT overwriting with uncapped slow tier)."
  elif [[ -f "$FAST_DEST" ]]; then
    # No prior tier was snapshotted, yet a file is here — so THIS run wrote it and
    # then the pass failed. It is capped (the capping pass produced it) but the
    # pass did not finish, so nothing about its completeness can be vouched for.
    #
    # This branch used to be the one above, calling the file a prior capped tier
    # and exiting 0. On a fresh HOME with no prior tier at all that claim was
    # simply false, and it swallowed the whole eviction report with it: exit 0,
    # 2 of 3 high lessons present, zero eviction lines (issue #151 P0-1).
    #
    # The CONTENT is kept rather than replaced with an empty tier, because losing
    # real lessons is the harm this file exists to prevent and a capped file of
    # genuine lessons still serves a review prompt; the uncertainty is carried by
    # the exit code instead, which is the channel that survives `--quiet
    # 2>/dev/null`.
    warn "Fast-tier capping unavailable ($reason) and no fast tier existed before this run — the file now at $FAST_DEST is THIS run's own output from the failed pass, not a prior capped tier."
    warn "   Its lessons are kept (they are capped, and discarding them helps nobody), but the pass did not finish, so this run cannot confirm which lessons reached it or whether any 'priority: high' lesson is missing."
    warn "   Re-run 'bash scripts/sync-toolbox-lessons.sh' (without --quiet) to rebuild it and see the real list."
    # Fail toward reporting: escalate through the exit code rather than let an
    # unverifiable tier report as healthy, which is the silence the whole
    # eviction-report block exists to end.
    HIGH_EVICTED=1
  else
    # No prior fast tier — emit a valid header-only/empty one. WHY a header-only
    # file (not skipping the write): consumers grep for `schema_version:` and
    # `lessons:` to confirm a valid pack; a missing file would break that check.
    warn "Fast-tier capping unavailable ($reason) and no prior fast tier exists — emitting header-only EMPTY fast tier (NOT an uncapped copy of the slow tier)."
    cat > "$FAST_DEST" <<'EMPTYFAST'
# lessons.yml -- Fast tier (active only, capped at 8 KB).
# Generated by sync-toolbox-lessons.sh.
# WARN: fast-tier capping was UNAVAILABLE on this run (python3 missing or failed).
# Emitting an EMPTY fast tier rather than an uncapped copy of the slow tier — an
# uncapped file would blow the review-prompt budget that consumers assume is ≤8KB.
# The full lesson set remains intact in toolbox-lessons.yml (slow tier).
schema_version: 1
lessons:
EMPTYFAST
    # Same signal as the parse-succeeded-but-empty case: the pack is written but the
    # fast tier holds nothing, so agents read no lessons. Without this the callers
    # print success over an empty tier whenever python3 is missing or the capping
    # pass fails — the audit reproduced it two ways (python3 stub exiting 1, and PATH
    # stripped of python*). Pre-existing on main rather than introduced here, but it
    # is one line and it is the exact hole this branch exists to close.
    EMPTY_FAST_TIER=3
  fi
}

# ---------------------------------------------------------------------------
# Locate source: support SOURCE_OVERRIDE env var (used by tests) OR
# derive from the script's own directory (production path).
# ---------------------------------------------------------------------------
if [[ -n "${SOURCE_OVERRIDE:-}" ]]; then
  # Test injection: use the caller-supplied path.
  SRC="$SOURCE_OVERRIDE"
else
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  SRC="$REPO_ROOT/knowledge/toolbox-lessons.yml"
fi

# ---------------------------------------------------------------------------
# Fail-soft: if source is missing, warn and preserve any existing pack.
# WHY: A temporarily absent source (mid-install, partial checkout, worktree
# without the knowledge/ dir) must not silently destroy an already-synced pack
# that review agents are relying on. Mirror sync-codex-knowledge.sh ~lines 51-55.
# ---------------------------------------------------------------------------
if [[ ! -f "$SRC" ]]; then
  warn "Toolbox lessons source not found at $SRC — leaving any existing pack intact."
  exit 0
fi

if [[ ! -r "$SRC" ]]; then
  warn "Toolbox lessons source at $SRC is not readable — leaving any existing pack intact."
  exit 0
fi

# ---------------------------------------------------------------------------
# Destination directory
# ---------------------------------------------------------------------------
PACK_DIR="${HOME}/.claude/toolbox-knowledge"
mkdir -p "$PACK_DIR"

SLOW_DEST="$PACK_DIR/toolbox-lessons.yml"
FAST_DEST="$PACK_DIR/lessons.yml"
# The decision manifest — the python pass's written-down record of what it
# decided per lesson. Durable (survives this script's exit) so callers and the
# unit-test harness can read it; see the ONE PARSER note in the file header.
DECISION_MANIFEST="$PACK_DIR/lessons-decisions.tsv"

# The per-run tag for every scratch file this run owns in the SHARED pack
# directory. Defined here because the prior-tier snapshot below is the first
# thing to need it. It must not be a fixed name and the trap must not remove a
# fixed name: those are two halves of the same collision, and the snapshot is
# the one file the prior-vs-own-output distinction rests on.
RUN_TAG="$$"

# ⛔ SNAPSHOT ANY PRIOR FAST TIER BEFORE ANYTHING CAN TOUCH IT. ⛔ fast_tier_fallback
# has to distinguish "a capped tier from an earlier successful run" from "the
# output this run just wrote before failing", and inferring that from the mere
# presence of $FAST_DEST is what made it call the second one the first. Copying
# the file aside up front turns the inference into knowledge: a non-empty
# $PRIOR_FAST means a tier predated this run, full stop.
PRIOR_FAST=""
if [[ -f "$FAST_DEST" ]]; then
  PRIOR_FAST="$PACK_DIR/.lessons.yml.$RUN_TAG.prior"
  cp "$FAST_DEST" "$PRIOR_FAST"
fi

# ⛔ DELETE ANY PRIOR MANIFEST BEFORE THE PASS RUNS. ⛔ The manifest is durable —
# it lives in the pack directory so callers can read it after this script exits —
# so one left by an EARLIER run would otherwise be indistinguishable from one
# this run wrote. Removing it up front makes "present, with a #END sentinel" mean
# "written by THIS run, completely". Done here rather than inside the python
# branch so it also covers the python-absent path, where no manifest is written
# at all and a stale one would otherwise outlive the tier it describes.
rm -f "$DECISION_MANIFEST"

# One trap for every temp artefact this script can leave behind, registered here
# so it covers BOTH the python-available and python-absent paths. PYTHON_TMPFILE
# is seeded empty and expanded conditionally so `set -u` cannot trip on it before
# the python branch assigns it.
PYTHON_TMPFILE=""
# ⛔ THE TRAP REMOVES ONLY THIS RUN'S SCRATCH FILES, BY EXACT NAME. ⛔ $RUN_TAG is
# generated here and passed to the python pass, so BOTH sides know the suffix and
# the trap can name the two files this run owns. It must not be a wildcard: giving
# the scratch a per-process name exists so concurrent syncs stop sharing one temp,
# and a glob hands that straight back — whichever run exits first would delete
# every other run's in-flight scratch, including one a live run is about to
# os.replace (automated-review, PR #152).
#
# Scratch left by an OLDER version of this script (fixed names, no tag) is
# deliberately NOT swept here: this run cannot tell a stale leftover from a
# concurrent old-version run's live temp, and deleting a live one is the very
# failure this exact-naming exists to prevent. A stale dotfile is harmless.
trap 'rm -f ${PYTHON_TMPFILE:+"$PYTHON_TMPFILE"} "$PACK_DIR/.lessons.yml.$RUN_TAG.tmp" "$PACK_DIR/.lessons-decisions.tsv.$RUN_TAG.tmp" "$PACK_DIR/.lessons.yml.$RUN_TAG.prior"' EXIT

# ---------------------------------------------------------------------------
# SLOW TIER: full copy — all lessons including superseded.
# WHY: The slow tier is the immutable history record. Superseded lessons must
# stay here for audit trails, PR provenance, and future reference. Review
# agents only read the fast tier; the slow tier is the source of truth.
# ---------------------------------------------------------------------------
cp "$SRC" "$SLOW_DEST"
info "Copied full toolbox-lessons.yml to slow tier: $SLOW_DEST"

# ---------------------------------------------------------------------------
# FAST TIER: active-only, sorted, capped at 8 KB.
# WHY: Injected into review prompts as advisory context. We keep only
# status==active entries (superseded guidance is stale), sort by occurrences
# desc then last_seen desc (most-reinforced and most-recently-seen first), and
# truncate at 8 KB to keep total prompt size bounded.
#
# PROVENANCE IS PROJECTED AWAY. Each lesson's `sources:` list records which PR
# raised the finding, which reviewer, the verdict and a timestamp. No review agent
# reads any of it — both consumers (skills/code-review-orchestration/SKILL.md,
# skills/codex-review/SKILL.md) cat this file into a prompt as advisory prose —
# and the slow tier is already declared the immutable provenance record above, so
# nothing is lost by leaving it there. Measured on the 19-lesson file that
# motivated this: provenance was 4408 of 18417 lesson bytes, and dropping it from
# the fast tier lifted membership from 7 lessons to 10, which is what finally let
# the two most-recurring patterns (TL-0008 at 7 occurrences, TL-0001 at 6) reach
# a review prompt at all. The projection is a fast-tier concern only; the
# human-gated source file is not edited.
#
# Implementation: prefer python3 (stdlib re — no external deps).
# If python3 is absent, degrade via fast_tier_fallback() (never an uncapped copy).
# ---------------------------------------------------------------------------
FAST_CAP_BYTES=8192  # 8 KB fast-tier cap

# ⛔ INITIALISE THE STATUS FLAGS BEFORE EITHER PATH, NOT INSIDE THE PYTHON ONE. ⛔
# These decide the exit code at the bottom of the file, and they used to be set
# only inside the `command -v python3` branch. On the python-ABSENT path they were
# therefore never reset, and the final `${HIGH_EVICTED:-0}` fell through to
# whatever the CALLER had exported — a fourth route to exit 4 belonging to none of
# the three documented causes, decided by the environment rather than by the run.
# Setting them here makes the exit code a property of this run in every path.
EMPTY_FAST_TIER=0
HIGH_EVICTED=0

if command -v python3 >/dev/null 2>&1; then
  # Use python3 stdlib only (no PyYAML). WHY: PyYAML is an external package
  # that lives in user-site-packages (e.g. ~/Library/Python/3.9/...). When this
  # script is called with a different HOME (e.g. test harnesses that set HOME to
  # a temp directory for output isolation), Python's user-site path changes and
  # the PyYAML import fails — even though PyYAML is installed for the real user.
  # Using re + stdlib makes the script work regardless of HOME or user env.
  #
  # WHY write to a temp .py file rather than using a heredoc on stdin:
  # When this script is invoked as `bash "$SCRIPT"` (e.g. from test harnesses),
  # the calling shell's stdin is inherited. A `python3 - <<'PYEOF'` heredoc
  # writes the Python source to the child process's stdin — but if the parent
  # shell has already consumed or redirected stdin, the heredoc arrives empty
  # (confirmed: `len(sys.stdin.read()) == 0`). Writing to a mktemp file avoids
  # the stdin-inheritance problem entirely.
  #
  # mktemp requires XXXXXX at the END of the template on macOS (BSD mktemp does
  # not support --suffix; a `.py` extension after XXXXXX prevents template
  # expansion and creates a literal "sync-lessons-XXXXXX.py" file instead).
  # Python does not require a .py extension to run — omit it here.
  #
  # The python3 block:
  #   1. Split source file into lesson blocks (each starts with "  - id:")
  #   2. Filter to blocks where status line says "active"
  #   3. Sort by priority, then occurrences desc, then last_seen desc
  #   4. Project each block to its fast-tier form (drop `sources:` provenance)
  #   5. Accumulate projected blocks until the 8 KB cap
  #   6. Write header + kept lesson blocks to FAST_DEST
  #   7. Write the DECISION MANIFEST — one row for every block considered, with
  #      the priority and status this pass resolved and what it did with the
  #      block — so bash can report the evictions and escalate on a dropped
  #      `priority: high` without re-deriving any of it

  # Write the python script to a mode-600 temp file (no stdin involved).
  PYTHON_TMPFILE=$(mktemp "${TMPDIR:-/tmp}/sync-lessons-XXXXXX")
  chmod 600 "$PYTHON_TMPFILE"

  # WHY printf not a cat heredoc: when this script is invoked as `bash "$SCRIPT"`
  # (e.g. from test harnesses that themselves use heredocs), the calling shell's
  # stdin is inherited. A `cat > file << 'EOF'` heredoc writes via stdin — and if
  # the parent shell's stdin has been consumed or redirected, the heredoc arrives
  # empty. Using printf avoids the stdin-inheritance problem entirely.
  printf '%s\n' 'import sys, re, os' > "$PYTHON_TMPFILE"
  printf '%s\n' 'src_path  = sys.argv[1]' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'cap_bytes = int(sys.argv[2])' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'dest_path = sys.argv[3]' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'manifest_path = sys.argv[4] if len(sys.argv) > 4 else ""' >> "$PYTHON_TMPFILE"
  # The scratch-file tag, supplied by BASH so the EXIT trap can name this run's
  # temp files exactly instead of globbing (see the trap). Falls back to this
  # process's pid if a caller omits it, which keeps the write atomic either way.
  printf '%s\n' 'run_tag = sys.argv[5] if len(sys.argv) > 5 else str(os.getpid())' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'try:' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    with open(src_path, "r", encoding="utf-8") as f:' >> "$PYTHON_TMPFILE"
  printf '%s\n' '        content = f.read()' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'except Exception as e:' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    sys.stderr.write("read error: " + str(e) + "\n")' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    sys.exit(1)' >> "$PYTHON_TMPFILE"
  # Split into lesson blocks. Each lesson block starts with "  - id:".
  # We keep the raw YAML text of each block intact so we can re-emit it
  # verbatim (no serialization needed — preserves original formatting).
  printf '%s\n' '# Split file into lesson blocks. Lessons start with "  - id:" at column 0+2.' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'raw_blocks = re.split(r"\n(?=  - id:)", content)' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'lesson_blocks = []' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'for block in raw_blocks:' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    if re.match(r"  - id:", block):' >> "$PYTHON_TMPFILE"
  printf '%s\n' '        lesson_blocks.append(block)' >> "$PYTHON_TMPFILE"
  # Filter: keep only blocks where status line contains "active".
  # Match lines like: `    status: "active"` or `    status: active`
  # Helper functions use only \w and \d patterns to avoid quote-within-quote
  # problems. get_last_seen uses a date-shaped pattern (YYYY-MM-DD) to avoid
  # single-quote characters in the regex string (which would conflict with the
  # outer printf single-quote delimiter).
  # get_status: match "    status: active" or '    status: "active"'
  # Use \W* to skip optional quote chars, then capture the word (active/superseded/etc).
  printf '%s\n' 'def get_status(block):' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    m = re.search(r"\n\s+status:\s+\W*(\w+)", block)' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    return m.group(1) if m else ""' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'def get_lesson_id(block):' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    m = re.search(r"  - id:\s*[\x22\x27]?([\w.-]+)", block)' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    return m.group(1) if m else "?"' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'def get_int_field(block, field):' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    m = re.search(r"\n\s+" + field + r":\s*(\d+)", block)' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    return int(m.group(1)) if m else 0' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'def get_last_seen(block):' >> "$PYTHON_TMPFILE"
  # Match YYYY-MM-DD, tolerating an optional surrounding quote — a value written
  # as last_seen: "2026-06-30" must still match (get_status already tolerates
  # quotes; this keeps recency sorting correct for quoted dates). \x22 = " and
  # \x27 = ' as regex hex escapes (avoids bash/python quote-nesting issues).
  printf '%s\n' '    m = re.search(r"\n\s+last_seen:\s*[\x22\x27]?(\d{4}-\d{2}-\d{2})", block)' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    return m.group(1) if m else ""' >> "$PYTHON_TMPFILE"
  # Carry each block's SOURCE INDEX alongside it from here on. The sort below
  # reorders the active set, and the decision manifest has to say which of the
  # ORIGINAL blocks each verdict belongs to — an index is the only key that
  # survives both the reorder and two identical lesson bodies.
  printf '%s\n' 'indexed = list(enumerate(lesson_blocks))' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'active = [t for t in indexed if get_status(t[1]) == "active"]' >> "$PYTHON_TMPFILE"
  # Sort: occurrences desc, then last_seen desc.
  # ISO date strings (YYYY-MM-DD) sort correctly as strings; negate via trick:
  # prepend a tilde (~) which sorts after all printable ASCII, then negate
  # occurrences. Actually simplest: sort ascending then reverse is wrong for
  # two-key. Use a proper tuple: (-occurrences, inverted_date).
  # Invert date: subtract each character's ordinal from a large value so that
  # a larger date (more recent) becomes a smaller tuple element (sorts first).
  # Simplest correct approach: sort by (-occurrences, -ord_sum) where ord_sum
  # of the date string approximates the date value as an int via int().
  printf '%s\n' 'def date_to_int(d):' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    return int(d.replace("-", "")) if d else 0' >> "$PYTHON_TMPFILE"
  # PRIORITY OUTRANKS FREQUENCY. Sorting on occurrences alone meant the 8 KB cap
  # dropped whichever lessons had been seen fewest times — which, the first time
  # this file was populated, was the two SECURITY lessons — a prose-as-command-source
  # code-execution path (TL-0005, 1 record) and cross-repo state collision
  # (TL-0006, 3 records) — while a stale-doc-count lesson with 6 was kept.
  # (Counts restated from the file after provenance was rebuilt from the records;
  # the earlier "both seen twice" was true when written and went stale a commit later.)
  # how badly it hurts. `priority: high` now sorts first; anything else keeps the
  # previous frequency-then-recency order, so untagged lessons behave exactly as before.
  printf '%s\n' 'def get_priority_rank(block):' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    m = re.search(r"\n\s+priority:\s*[\x22\x27]?(\w+)", block)' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    return 0 if (m and m.group(1).lower() == "high") else 1' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'active.sort(key=lambda t: (get_priority_rank(t[1]), -get_int_field(t[1], "occurrences"), -date_to_int(get_last_seen(t[1]))))' >> "$PYTHON_TMPFILE"
  # FAST-TIER PROJECTION. Remove the `sources:` provenance list from each block.
  # The key is anchored at EXACTLY four spaces because that is the schema's field
  # indent (see the field list in knowledge/toolbox-lessons.yml) — matching any
  # indentation would let a `sources:`-shaped line inside a `lesson:` block scalar
  # (indent 6) be mistaken for the key and take real text with it.
  # Everything indented DEEPER than the key is part of its value, so the scan
  # stops at the first line at or above indent 4. That is an indent scan rather
  # than a delete-to-end-of-block precisely because `sources:` is not always the
  # last field — the test fixtures put it mid-block, and a to-end-of-block delete
  # would silently swallow occurrences/first_seen/last_seen/status with it.
  # Blank lines encountered INSIDE the provenance list are consumed along with it;
  # they carry no data and the block is rstripped before emission anyway.
  printf '%s\n' 'def strip_sources(block):' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    lines = block.split("\n")' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    out = []' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    i = 0' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    n = len(lines)' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    while i < n:' >> "$PYTHON_TMPFILE"
  printf '%s\n' '        line = lines[i]' >> "$PYTHON_TMPFILE"
  printf '%s\n' '        if re.match(r"^    sources:", line):' >> "$PYTHON_TMPFILE"
  printf '%s\n' '            i += 1' >> "$PYTHON_TMPFILE"
  printf '%s\n' '            while i < n:' >> "$PYTHON_TMPFILE"
  printf '%s\n' '                nxt = lines[i]' >> "$PYTHON_TMPFILE"
  printf '%s\n' '                if nxt.strip() == "":' >> "$PYTHON_TMPFILE"
  printf '%s\n' '                    i += 1' >> "$PYTHON_TMPFILE"
  printf '%s\n' '                    continue' >> "$PYTHON_TMPFILE"
  printf '%s\n' '                if len(nxt) - len(nxt.lstrip()) <= 4:' >> "$PYTHON_TMPFILE"
  printf '%s\n' '                    break' >> "$PYTHON_TMPFILE"
  printf '%s\n' '                i += 1' >> "$PYTHON_TMPFILE"
  printf '%s\n' '            continue' >> "$PYTHON_TMPFILE"
  printf '%s\n' '        out.append(line)' >> "$PYTHON_TMPFILE"
  printf '%s\n' '        i += 1' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    return "\n".join(out)' >> "$PYTHON_TMPFILE"
  # FAIL TOWARD KEEPING CONTENT: the projection exists to save bytes, so on any
  # doubt it returns the ORIGINAL block — a fast tier that is larger than it
  # needed to be still injects correct lessons, whereas one missing `lesson:` or
  # emptied entirely injects damage. An exception, a vanished `lesson:` field or a
  # blank result all take that path; this is the default because losing lesson
  # text is strictly worse than losing the byte saving.
  printf '%s\n' 'def project(block):' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    try:' >> "$PYTHON_TMPFILE"
  printf '%s\n' '        p = strip_sources(block)' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    except Exception:' >> "$PYTHON_TMPFILE"
  printf '%s\n' '        return block' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    if not p.strip():' >> "$PYTHON_TMPFILE"
  printf '%s\n' '        return block' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    if "lesson:" in block and "lesson:" not in p:' >> "$PYTHON_TMPFILE"
  printf '%s\n' '        return block' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    return p' >> "$PYTHON_TMPFILE"
  # Build the fast-tier output with header + kept lesson blocks.
  printf '%s\n' 'header = "# lessons.yml -- Fast tier (active only, capped at 8 KB).\n"' >> "$PYTHON_TMPFILE"
  # The wording deliberately avoids writing the field name with its colon: the
  # fast tier is asserted to contain no `sources:` key ANYWHERE (TC-STL-35 leg 1),
  # and a blunt file-wide assertion is worth more than a header that spells the
  # key out and forces the test to special-case its own generator's prose.
  printf '%s\n' 'header += "# Per-lesson provenance (the sources list) is omitted here -- see toolbox-lessons.yml.\n"' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'header += "# Generated by sync-toolbox-lessons.sh. Edit knowledge/toolbox-lessons.yml to change.\n"' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'header += "schema_version: 1\nlessons:\n"' >> "$PYTHON_TMPFILE"
  # Accumulate lessons until cap.
  printf '%s\n' 'accumulated = header' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'kept = 0' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'projected = [(t[0], t[1], project(t[1])) for t in active]' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'for idx in range(len(projected)):' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    block = projected[idx][2]' >> "$PYTHON_TMPFILE"
  # Ensure block ends with a newline before appending.
  printf '%s\n' '    candidate = accumulated + block.rstrip() + "\n"' >> "$PYTHON_TMPFILE"
  # WHY `kept > 0` guard: always include at least the first lesson even when it
  # alone exceeds the byte cap. Without this guard, a single lesson larger than
  # the cap would produce an empty fast tier — every subsequent read from agents
  # would see no lessons at all. One oversized lesson is better than none.
  # NOTE: this single-oversized-first-lesson overshoot is ACCEPTED DESIGN, not a
  # bug — it is the one intentional way the fast tier may exceed 8 KB. The
  # fallback path (python3 unavailable/failed) is a different case entirely and
  # must never produce an uncapped file (see fast_tier_fallback).
  printf '%s\n' '    if len(candidate.encode("utf-8")) > cap_bytes and kept > 0:' >> "$PYTHON_TMPFILE"
  # Selection stays a PREFIX of the sorted order (break, not continue) — the same
  # contract the cap has always had, so reporting evictions does not also reshuffle
  # which lessons win. `kept` is therefore the split point: projected[:kept] made
  # it in and projected[kept:] did not, which is why the eviction list is derived
  # from `kept` below rather than assembled here.
  printf '%s\n' '        break' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    accumulated = candidate' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    kept += 1' >> "$PYTHON_TMPFILE"
  # ---------------------------------------------------------------------
  # DECISION MANIFEST — the generator writing down what it decided.
  #
  # One row per lesson block IN SOURCE ORDER, so a human reading the file sees
  # it in the same order as the YAML, and a row exists even for blocks the
  # capping pass never considered. `kept` is the split point in the sorted
  # active list; everything not in that list at all is `excluded` (its status
  # did not resolve to "active", so it was never a candidate for the fast tier).
  # ---------------------------------------------------------------------
  printf '%s\n' 'disposition = {}' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'for t in indexed:' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    disposition[t[0]] = "excluded"' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'for t in projected[:kept]:' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    disposition[t[0]] = "kept"' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'for t in projected[kept:]:' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    disposition[t[0]] = "evicted"' >> "$PYTHON_TMPFILE"
  # The `#` prefix on both non-data lines is what lets every reader skip them
  # with one rule. The `#END` sentinel is required before bash trusts the list,
  # so a truncated or unwritten manifest is DISTINGUISHABLE from "nothing was
  # evicted" rather than silently reading as the latter.
  # The record NAMES THE RUN THAT WROTE IT. The manifest lives at a fixed shared
  # path so the caller can read it after this script exits — and that same choice
  # lets a CONCURRENT sync replace it between this run's manifest write and its
  # tier write, after which this run would read a peer's verdicts, find no
  # eviction in them, and exit 0 while its own tier is missing a high lesson. The
  # tag does not serialise the two runs; it makes the mismatch DETECTABLE, so the
  # fail-toward-reporting default covers this state like every other unprovable
  # one. `#`-prefixed, so every existing reader already skips it.
  printf '%s\n' 'mrows = ["#run\t" + run_tag, "#id\tpriority\tstatus\toccurrences\tbytes\tdisposition"]' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'for t in indexed:' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    b = t[1]' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    pri = "high" if get_priority_rank(b) == 0 else "normal"' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    nbytes = len(project(b).rstrip().encode("utf-8")) + 1' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    mrows.append("%s\t%s\t%s\t%d\t%d\t%s" % (get_lesson_id(b), pri, get_status(b), get_int_field(b, "occurrences"), nbytes, disposition[t[0]]))' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'mrows.append("#END")' >> "$PYTHON_TMPFILE"
  # ---------------------------------------------------------------------
  # ATOMIC WRITES, MANIFEST FIRST.
  #
  # Both outputs go to a dot-prefixed temp file in their own directory and are
  # renamed into place; os.replace is atomic within a filesystem, and the temp
  # file is a sibling so there is only one filesystem involved. A failure part
  # way through therefore leaves the OLD file, never a truncated new one.
  #
  # The ORDER is load-bearing, not incidental: the manifest lands first, so a
  # pass that dies part way through can never have replaced the fast tier without
  # also having recorded what it put there. That is what lets bash report a
  # failed-but-recorded run's evictions instead of discarding them — before this,
  # python wrote the tier first and its decisions second, so a pass that died in
  # between left a new tier that nothing could describe (issue #151 P0-1).
  #
  # This covers failures INSIDE the pass. It says nothing about a manifest
  # removed by something else afterwards; that case is covered separately, by the
  # $PRIOR_FAST snapshot bash takes before the pass runs.
  # ---------------------------------------------------------------------
  printf '%s\n' 'def write_atomic(path, text):' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    d = os.path.dirname(path) or "."' >> "$PYTHON_TMPFILE"
  # PER-RUN TEMP NAME. The temp was a FIXED sibling (".lessons.yml.tmp"), so two
  # syncs sharing one HOME wrote the same scratch file and could truncate or
  # replace each other's half-written output before either os.replace ran — which
  # makes the "atomic" write atomic only against itself (automated-review, PR #152).
  # The tag comes from BASH ($RUN_TAG, argv[5]) rather than os.getpid() so the
  # EXIT trap can name these files exactly; a trap that had to guess would need a
  # wildcard, and a wildcard would delete other runs' scratch — reopening the very
  # collision this fixes. This does NOT serialise the two runs against each other:
  # pairing one run's manifest with another's tier needs a lock or a generation
  # marker, a documented residual. It removes the shared-scratch collision only.
  printf '%s\n' '    tmp = os.path.join(d, "." + os.path.basename(path) + "." + run_tag + ".tmp")' >> "$PYTHON_TMPFILE"
  # newline="\n" PINS THE LINE ENDING. Text mode translates "\n" to the
  # platform's ending, so on a CRLF platform every row — and the sentinel —
  # would be written with a trailing CR. Bash then reads `evicted\r` in the
  # disposition column, matches no eviction, and reports nothing. Pinning it here
  # is the ONE-PARSER fix: the generator owns the format, so no reader has to
  # guess at it. (The readers still tolerate a stray CR, for a file something
  # else rewrote — but they never have to for a manifest this pass produced.)
  printf '%s\n' '    with open(tmp, "w", encoding="utf-8", newline="\n") as f:' >> "$PYTHON_TMPFILE"
  printf '%s\n' '        f.write(text)' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    os.replace(tmp, path)' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'if manifest_path:' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    try:' >> "$PYTHON_TMPFILE"
  printf '%s\n' '        write_atomic(manifest_path, "\n".join(mrows) + "\n")' >> "$PYTHON_TMPFILE"
  printf '%s\n' '    except Exception as e:' >> "$PYTHON_TMPFILE"
  # Deliberately NOT sys.exit(1): the fast tier is about to be written correctly,
  # so failing here would discard a good pack over a reporting problem. The absent
  # sentinel is the signal, and bash escalates on it.
  printf '%s\n' '        sys.stderr.write("decision manifest write failed: " + str(e) + "\n")' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'write_atomic(dest_path, accumulated)' >> "$PYTHON_TMPFILE"
  printf '%s\n' 'sys.exit(0)' >> "$PYTHON_TMPFILE"

  # Capture exit code without triggering set -e.
  # WHY: With set -euo pipefail, a bare `python3 ...` will terminate the script
  # immediately if python3 returns nonzero — set -e fires before `PYTHON_RC=$?`
  # can execute. The `|| PYTHON_RC=$?` idiom captures the nonzero exit code
  # while suppressing the set -e exit, so the fallback cp path below still runs.
  PYTHON_RC=0
  python3 "$PYTHON_TMPFILE" "$SRC" "$FAST_CAP_BYTES" "$FAST_DEST" "$DECISION_MANIFEST" "$RUN_TAG" 2>/dev/null || PYTHON_RC=$?

  # Did THIS run leave a complete decision manifest? The stale one was deleted
  # before the pass started and the sentinel is written last, so "terminated by
  # #END" means "this run, in full" — the only state in which the pass's own
  # verdicts can be read back.
  #
  # ⛔ THE SENTINEL MUST TERMINATE THE RECORD, NOT MERELY APPEAR IN IT. ⛔ This
  # was `grep -q '^#END$'`, which accepts the sentinel ANYWHERE — so a manifest
  # whose rows follow its `#END` read as complete and its rows were consumed. The
  # sentinel's entire job is to tell a complete record from a truncated one, and
  # a position-blind check cannot do that: it would have stayed green even if the
  # generator emitted the sentinel FIRST. Reading the last non-empty line is what
  # makes "complete" mean "every row this run intended to write is above this
  # line". Blank trailing lines are tolerated (`NF` skips them) because a stray
  # newline is not a truncation.
  #
  # ⛔ TIGHTENING A PREDICATE HAS TWO DIRECTIONS. ⛔ Two of them bit here:
  #   - A trailing CR is stripped before comparing. The `grep -q '^#END$'` this
  #     replaced MATCHED a `#END\r` line; a bare `== "#END"` does not, so on any
  #     platform whose python writes CRLF every HEALTHY sync would have started
  #     escalating to exit 4 forever. Measured on the identical fixture, not
  #     reasoned about: grep said match, the bare comparison said no.
  #   - The READ has to succeed, not just produce the right text. `grep -q`
  #     decided on its exit STATUS, so a broken reader failed closed; deciding on
  #     captured stdout instead would believe an awk that prints `#END` and then
  #     dies. Swapping a status test for a text test must not move the failure
  #     direction from closed to open, so both are required here.
  # ⛔ READ THE RECORD ONCE. ⛔ Every check below works from $MANIFEST_TEXT, this
  # one in-memory copy — never by re-opening $DECISION_MANIFEST. The file sits at
  # a fixed shared path, so a concurrent sync can replace it BETWEEN two reads:
  # validating the run tag from one open and then counting rows from another lets
  # a peer swap the record in the gap, and this run would validate its own tag and
  # then report the peer's verdicts. One read makes every check below describe one
  # state of the file, whatever happens to it afterwards.
  MANIFEST_COMPLETE=0
  MANIFEST_TEXT=""
  MANIFEST_READ_RC=0
  if [[ -f "$DECISION_MANIFEST" ]]; then
    MANIFEST_TEXT=$(cat "$DECISION_MANIFEST" 2>/dev/null) || MANIFEST_READ_RC=$?
    if [[ "$MANIFEST_READ_RC" -eq 0 ]]; then
      # The reader's exit status still has to be captured, for the same reason it
      # was when this read the file directly: deciding on captured stdout alone
      # believes a reader that prints the right text and then dies. Dropping the
      # guard here also lets `set -e` kill the script outright on a failing awk —
      # exit 2, undocumented — instead of degrading to cannot-confirm.
      MANIFEST_LAST=""
      MANIFEST_LAST=$(awk 'NF{last=$0} END{sub(/\r$/,"",last); print last}' \
        <<<"$MANIFEST_TEXT" 2>/dev/null) || MANIFEST_READ_RC=$?
      if [[ "$MANIFEST_READ_RC" -eq 0 && "$MANIFEST_LAST" == "#END" ]]; then
        MANIFEST_COMPLETE=1
      fi
    fi
  fi

  # ⛔ AND IT MUST BE **THIS** RUN'S RECORD. ⛔ Complete is not the same as ours.
  # The manifest sits at a fixed shared path so the caller can read it after this
  # script exits; the cost is that a CONCURRENT sync can replace it between this
  # run's manifest write and its tier write. This run would then read a peer's
  # verdicts, find no eviction among them, and exit 0 while its OWN fast tier is
  # missing an evicted `priority: high` lesson — the issue #144/#151 invariant,
  # broken silently, on a window this file opened when the manifest stopped being
  # a per-run mktemp. Comparing the recorded tag does not serialise the runs and
  # does not make this run's report correct; it makes the mismatch VISIBLE, which
  # drops it into the same cannot-confirm branch as a missing or truncated record
  # instead of letting it read as success.
  if [[ "$MANIFEST_COMPLETE" -eq 1 ]]; then
    MANIFEST_RUN=""
    MANIFEST_RUN=$(awk -F'\t' '/^#run\t/ { sub(/\r$/, "", $2); print $2; exit }' \
      <<<"$MANIFEST_TEXT") || MANIFEST_RUN=""
    if [[ "$MANIFEST_RUN" != "$RUN_TAG" ]]; then
      warn "The decision manifest at $DECISION_MANIFEST is tagged to run '${MANIFEST_RUN:-<untagged>}', not this run ('$RUN_TAG') — another sync sharing this HOME replaced it while this one was working."
      warn "   Its verdicts describe that run's fast tier, not the one this run just wrote, so nothing in it can rule out an eviction here."
      MANIFEST_COMPLETE=0
    fi
  fi

  if [[ $PYTHON_RC -ne 0 && $MANIFEST_COMPLETE -eq 0 ]]; then
    # The pass failed before it recorded anything, so it never replaced the fast
    # tier either (the manifest is renamed into place first — see the python
    # block). Degrade SAFELY: never write an uncapped copy. Restore the tier
    # $PRIOR_FAST recorded before this run started — which is what makes it a
    # KNOWN prior tier rather than a guess — else emit an empty one.
    fast_tier_fallback "python3 fast-tier build failed (rc=$PYTHON_RC)"
  else
    # A pass that exited non-zero but still landed a complete manifest got as far
    # as deciding and recording; its verdicts are readable and are reported below.
    # What it did NOT do is finish cleanly, so the tier on disk is not guaranteed
    # to match the record — hence the escalation, on the same fail-toward-reporting
    # default as the missing-manifest branch: with the two possibly out of step we
    # cannot prove no high-priority lesson is missing, and staying quiet about that
    # is the exact silent drop this block exists to end.
    if [[ $PYTHON_RC -ne 0 ]]; then
      warn "The fast-tier capping pass exited non-zero (rc=$PYTHON_RC) AFTER recording its decisions — the decisions below are the pass's own and are reported, but the fast tier on disk may not match them, so this is escalated rather than trusted."
      HIGH_EVICTED=1
    fi

    # The one thing measured from the OUTPUT rather than the record: how many
    # lesson blocks actually reached the fast tier. Counting the file is what
    # makes the empty-tier guard below a check on reality instead of on the
    # pass's self-report — a pass that claims 10 kept and writes none must still
    # be caught. It counts emitted block starts; it does not read any lesson field.
    FAST_KEPT=$(grep -c '^  - id:' "$FAST_DEST" 2>/dev/null || true)
    FAST_KEPT=${FAST_KEPT:-0}

    if [[ $MANIFEST_COMPLETE -eq 1 ]]; then
      # ⛔ EVERY COUNT BELOW COMES FROM THE MANIFEST. ⛔ These used to be greps
      # over the SOURCE YAML, re-deriving what the pass had already resolved, and
      # they diverged: `SRC_ACTIVE`'s single-line grep could not see a `status:`
      # whose value sits on the next line, which python's `\s+`-spanning regex
      # reads as active — so SRC_ACTIVE came back 0 on a perfectly valid file and
      # the fail-toward-reporting branch below could never fire (issue #151 P0-2).
      # Reading the pass's own resolved status removes the second derivation
      # rather than making it more careful, which is the only move that ends the
      # class — three rounds of making it more careful did not.
      # ⛔ EVERY READER OF THE RECORD CAPTURES ITS STATUS. ⛔ The sentinel and tag
      # probes already did; these did not, so under `set -euo pipefail` a failing
      # awk here killed the script at exit 2 — undocumented, silent, and two lines
      # after the same broken reader would have produced an orderly
      # cannot-confirm. A count this run could not take is a count it cannot vouch
      # for, which is the state exit 4 exists for.
      # SEPARATE status per reader. Sharing one variable meant a COUNT failure
      # left it non-zero and the eviction guard downstream blamed a reader that
      # had run perfectly — right escalation, wrong culprit (automated-review, PR #152).
      ROW_READ_RC=0
      EVICT_READ_RC=0
      SRC_BLOCKS=$(awk -F'\t' '{ sub(/\r$/, "") } !/^#/ { n++ } END { print n+0 }' <<<"$MANIFEST_TEXT" 2>/dev/null) || ROW_READ_RC=$?
      SRC_ACTIVE=$(awk -F'\t' '{ sub(/\r$/, "") } !/^#/ && $3 == "active" { n++ } END { print n+0 }' <<<"$MANIFEST_TEXT" 2>/dev/null) || ROW_READ_RC=$?
      SRC_SUPERSEDED=$(awk -F'\t' '{ sub(/\r$/, "") } !/^#/ && $3 == "superseded" { n++ } END { print n+0 }' <<<"$MANIFEST_TEXT" 2>/dev/null) || ROW_READ_RC=$?
      SRC_BLOCKS=${SRC_BLOCKS:-0}; SRC_ACTIVE=${SRC_ACTIVE:-0}; SRC_SUPERSEDED=${SRC_SUPERSEDED:-0}

      # Capturing the status is only half of it — it has to CHANGE something, or
      # it is a variable nobody reads (the inert-guard shape, TL-0002). A count
      # this run could not take makes every number below unvouched-for, so the
      # run escalates and says so rather than reporting figures it did not
      # actually compute.
      if [[ "$ROW_READ_RC" -ne 0 ]]; then
        warn "A reader of the decision manifest at $DECISION_MANIFEST failed (rc=$ROW_READ_RC) — the record is present and complete, but this run could not finish counting it."
        warn "   The figures below are therefore incomplete, and no eviction can be ruled out; escalating rather than reporting numbers this run did not compute."
        HIGH_EVICTED=1
      fi

      # SILENT-EMPTY GUARD. The capping pass can succeed while emitting ZERO
      # lessons — it parses lesson blocks by structure, so one malformed or
      # missing field (a dropped `status: active`, say) yields no "active" blocks
      # and a technically valid, entirely empty fast tier. That happened during
      # development: an edit stripped `status:` from all twelve lessons, the fast
      # tier came back at 171 bytes with nothing in it, and NOTHING failed — this
      # script reported success, the sync unit tests passed (they use their own
      # fixtures), and verify.sh passed. The agent would simply have read no
      # lessons, exactly the month-long outage this pipeline was repaired for.
      #
      # The fast tier is active-ONLY by design, so a source whose lessons have all
      # been retired legitimately produces an empty tier; warning there would cry
      # wolf on a valid configuration and exit 3 would make every install report a
      # problem (automated-review, PR #134). Telling the two apart needs to know whether
      # each block carries a RECOGNISED status at all:
      #   all superseded        -> STATUS_LINES == SRC_BLOCKS, nothing active. Correct, silent.
      #   status unresolvable   -> STATUS_LINES <  SRC_BLOCKS. Malformed, warn.
      #   active but none kept  -> SRC_ACTIVE > 0 with FAST_KEPT == 0. Something ate them, warn.
      STATUS_LINES=$(( SRC_ACTIVE + SRC_SUPERSEDED ))
      if [[ "$FAST_KEPT" -eq 0 && "$SRC_ACTIVE" -gt 0 ]]; then
        warn "Fast tier is EMPTY but the capping pass resolved $SRC_ACTIVE lesson(s) in $SRC as active — the agent will read no lessons."
        warn "The capping pass kept nothing despite active lessons. Re-run without --quiet to see why."
        EMPTY_FAST_TIER=3
      elif [[ "$FAST_KEPT" -eq 0 && "$SRC_BLOCKS" -gt 0 && "$STATUS_LINES" -lt "$SRC_BLOCKS" ]]; then
        warn "Fast tier is EMPTY and $(( SRC_BLOCKS - STATUS_LINES )) of $SRC_BLOCKS lesson(s) in $SRC carry no recognised status — the agent will read no lessons."
        warn "Every lesson needs 'status: active' or 'status: superseded'. Fix the source and re-run."
        # EXIT CODE, not just a warning. Both automated callers run this as
        # `... --quiet 2>/dev/null`, so a stderr message is discarded and the
        # caller then prints its own unconditional success. The audit proved it:
        # replicating both call forms against a broken source printed green while
        # the fast tier was 171 bytes with zero lessons. A signal that only
        # survives a manual run is not a signal — 3 is distinct from the generic
        # failure paths so callers can name the cause.
        EMPTY_FAST_TIER=3
      else
        info "Fast tier built (active-only, ≤ ${FAST_CAP_BYTES}B): $FAST_DEST — $FAST_KEPT of $SRC_ACTIVE active lesson(s) kept${SRC_SUPERSEDED:+, $SRC_SUPERSEDED superseded}"
      fi

      # ---------------------------------------------------------------------
      # EVICTION REPORT. The cap is not the defect — the SILENCE was. Before this,
      # the script sorted, filled until full, stopped, printed success and exited 0,
      # so a lesson that reached no review prompt looked exactly like one that did.
      # Measured on the 19-lesson file: 7 kept, 12 evicted, one of them tagged
      # `priority: high`, and nothing anywhere said so (issue #144).
      #
      # Every eviction goes to stderr — including on --quiet, because "you are not
      # getting all your lessons" is a degradation notice, not chatter, and the two
      # automated callers discard stderr anyway so it cannot become install noise.
      # An evicted `priority: high` lesson additionally raises the exit code, since
      # the exit code is the only channel that survives `--quiet 2>/dev/null`.
      #
      # The rows are the pass's own verdicts, so "evicted" here means the block was
      # a candidate that did not fit — never a block the pass excluded for being
      # non-active, which was never going to reach the fast tier in the first place.
      # ---------------------------------------------------------------------
      EVICTED_ROWS=$(awk -F'\t' '{ sub(/\r$/, "") } !/^#/ && $6 == "evicted" { printf "%s\t%s\t%s\t%s\n", $1, $2, $4, $5 }' <<<"$MANIFEST_TEXT" 2>/dev/null) || EVICT_READ_RC=$?
      # ⛔ CHECKED HERE, NOT ONLY ABOVE. ⛔ This reader assigns to $ROW_READ_RC, but
      # the guard on it sits ~60 lines EARLIER, so its failure was recorded and
      # never acted on: a reader that dies produces no rows, the eviction report
      # finds nothing to print, HIGH_EVICTED is never raised, and the run exits 0
      # over an evicted `priority: high` lesson. Measured — exit 0, zero eviction
      # lines, TL-H3 gone. That is the silent drop this whole file exists to end,
      # reintroduced by a guard placed before the thing it guards, which is the
      # inert-guard shape (TL-0002) the earlier comment names and then fell into
      # (automated-review, PR #152).
      if [[ "$EVICT_READ_RC" -ne 0 ]]; then
        warn "The eviction reader for $DECISION_MANIFEST failed (rc=$EVICT_READ_RC) — the record is complete, but this run could not extract the evicted rows from it."
        warn "   An empty eviction list from a FAILED read is not the same as nothing having been evicted, so no dropped 'priority: high' lesson can be ruled out here."
        HIGH_EVICTED=1
      fi
      if [[ -n "$EVICTED_ROWS" ]]; then
        EVICTED_N=$(printf '%s\n' "$EVICTED_ROWS" | grep -c '.' || true)
        warn "Fast tier evicted ${EVICTED_N:-0} lesson(s) at the ${FAST_CAP_BYTES}B cap — each stays in the slow tier but reaches NO review prompt:"
        # Here-string, not a pipe: the loop must run in THIS shell or the
        # HIGH_EVICTED it sets would be discarded with the subshell.
        ESCALATING_IDS=""
        while IFS=$'\t' read -r EV_ID EV_PRI EV_OCC EV_BYTES; do
          [[ -z "$EV_ID" ]] && continue
          warn "  evicted: $EV_ID (priority=${EV_PRI:-unknown}, occurrences=${EV_OCC:-?}, ${EV_BYTES:-?}B)"
          # Anything not positively identified as ordinary priority escalates —
          # same fail-toward-reporting default as the missing-manifest branch
          # below. The python pass writes only "high" or "normal", so in practice
          # this is the high rows; the `!=` spelling is what keeps an unreadable
          # third value from being waved through as ordinary.
          if [[ "$EV_PRI" != "normal" ]]; then
            HIGH_EVICTED=1
            ESCALATING_IDS="${ESCALATING_IDS}${ESCALATING_IDS:+, }$EV_ID"
          fi
        done <<< "$EVICTED_ROWS"
        if [[ -n "$ESCALATING_IDS" ]]; then
          # Gated on ESCALATING_IDS, not on HIGH_EVICTED. HIGH_EVICTED is also
          # raised by the two cannot-confirm branches, and neither of those has a
          # lesson to name — printing this text there would assert an eviction
          # that did not happen. The ids are NAMED rather than described, so the
          # message stays true whether the priority column read "high" or
          # something unreadable, and it makes no claim about WHICH exit code is
          # returned, because the empty-fast-tier condition outranks it below.
          warn "⛔ Evicted with a priority above ordinary: $ESCALATING_IDS"
          warn "   'priority: high' marks a severe consequence — code execution, data loss, a"
          warn "   silent-failure class — so that lesson now reaches no review prompt at all."
          warn "   Either shorten lesson bodies in knowledge/toolbox-lessons.yml, retire a"
          warn "   superseded lesson, or accept the loss deliberately. This is escalated through"
          warn "   the exit code so it survives --quiet and a discarded stderr."
        fi
      fi
    else
      # FAIL TOWARD REPORTING. The pass exited 0 but left no complete decision
      # manifest, so nothing about this run can be confirmed: not how many lessons
      # the source declared active, not which were evicted, not whether any of them
      # was tagged high. The default has to be the loud branch, because the
      # alternative default is exactly the silent drop this whole block exists to
      # end. Nothing here re-derives the answer from the source YAML — a second
      # parser is what produced the divergences in the first place, and a guess
      # dressed as a count is worse than an admitted unknown.
      warn "The fast-tier capping pass left no complete decision manifest at $DECISION_MANIFEST — cannot confirm which lessons were evicted, or whether any of them was 'priority: high', so reporting as if one was."
      warn "   Every lesson remains in the slow tier at $SLOW_DEST. The fast tier currently holds $FAST_KEPT lesson(s)."
      warn "   Re-run 'bash scripts/sync-toolbox-lessons.sh' (without --quiet) to rebuild the manifest and see the real list."
      HIGH_EVICTED=1
      if [[ "$FAST_KEPT" -eq 0 ]]; then
        # Reported, but NOT escalated to 3: exit 3 asserts the source declares
        # active lessons, and with no manifest that is precisely the claim that
        # cannot be substantiated. The cannot-confirm code (4) already set above
        # is the honest one, so this adds the observation without the assertion.
        warn "   The fast tier is also EMPTY — whether that is correct depends on the source, which this run could not resolve."
      fi
    fi
  fi

else
  # python3 not available — degrade SAFELY. The earlier behavior here copied the
  # slow tier verbatim, which produced an UNCAPPED fast tier that consumers
  # (code-review-orchestration / codex-review skills) inject assuming ≤ 8 KB.
  # fast_tier_fallback preserves any prior capped fast tier or emits an empty one;
  # it NEVER writes an uncapped copy. The full lesson set stays in the slow tier.
  fast_tier_fallback "python3 not available"
fi

# ---------------------------------------------------------------------------
# Pack README (orients anyone who opens the directory)
# ---------------------------------------------------------------------------
cat > "$PACK_DIR/README.md" <<'README'
# Toolbox lessons pack

Advisory learned lessons from review findings (automated-review + Codex), assembled by
`ai-engineering/scripts/sync-toolbox-lessons.sh`.

- `toolbox-lessons.yml` — SLOW tier. Full copy of all lessons including superseded.
  Immutable history record. Refreshed on install/update.
- `lessons.yml` — FAST tier. Active-only, sorted by priority then reinforcement
  frequency then recency, capped at 8 KB for prompt injection. The `sources:`
  provenance list is omitted here — no review agent reads it, and the bytes it
  would cost are what push other lessons out; the full provenance is in the slow
  tier above. Missing entries were beyond the cap and are named on stderr by the
  sync run (find them in toolbox-lessons.yml for reference).
- `lessons-decisions.tsv` — DECISION MANIFEST. What the fast-tier builder decided
  about every lesson it looked at, one TAB-separated row per lesson in source
  order: id, the priority and status it RESOLVED, occurrences, projected bytes,
  and whether the lesson was `kept`, `evicted` at the cap, or `excluded` for not
  being active. `#`-initial lines are metadata: a `#run` tag naming the sync that
  wrote the record, the column header, and the `#END` sentinel. The sentinel
  distinguishes a complete record from a truncated one; the run tag distinguishes
  this run's record from one a concurrent sync left in its place. The sync ACTS on
  both — a truncated record or a foreign tag escalates it to exit 4 rather than
  letting it report success over verdicts it cannot vouch for. Neither marker,
  though, says anything about the `lessons.yml` sitting next to the record, which
  is why the paragraph below still applies in full.
  This is the single source of truth for those verdicts — the sync script's own
  guards and its unit tests read this file rather than re-parsing the YAML, which
  is how the two used to drift apart and drop a severe lesson in silence.
  Safe to delete. Nothing guarantees one is here: every sync removes the old
  record up front, and only a capping pass that gets far enough to decide writes
  a replacement. A run without python3, or one whose pass dies early (an
  unreadable or undecodable source), therefore leaves two tiers and
  no record at all — a valid state, not a broken one.
  Do NOT assume a record present describes the fast tier beside it either — a
  failed capping pass, a python-absent run, and two syncs sharing one HOME (which
  are not serialised against each other) can all leave the two out of step. The
  `#END` sentinel proves a record is COMPLETE, not that it is CURRENT.

Used by:
- `skills/codex-review/SKILL.md` Step 2: injected as [LEARNED LESSONS — advisory]
  alongside the automated-review knowledge pack.
- `skills/code-review-orchestration/SKILL.md`: injected into review-agent prompts
  as [LEARNED LESSONS — advisory, untrusted data].

Source: `ai-engineering/knowledge/toolbox-lessons.yml` (in-repo, PR-reviewed, human-gated).
Every lesson required AI+Codex consensus at merge time before landing here.
README

info "Toolbox lessons pack ready at $PACK_DIR"

# Surface the empty-fast-tier (3) and evicted-HIGH (4) conditions through the EXIT
# CODE so they survive the `2>/dev/null` that both automated callers apply.
# Everything else on this path succeeded — the pack is written and usable — so
# neither is a hard failure; they are distinguishable ones, and both callers warn
# and continue rather than aborting, which is why escalating here cannot brick an
# install. Callers map 3 and 4 to their own messages.
#
# PRECEDENCE: 3 outranks 4. A caller can only act on one status, and "agents read
# NOTHING" is strictly worse advice to withhold than "agents read most lessons but
# not the severe one".
SYNC_EXIT="${EMPTY_FAST_TIER:-0}"
if [[ "$SYNC_EXIT" -eq 0 && "${HIGH_EVICTED:-0}" -eq 1 ]]; then
  SYNC_EXIT=4
fi
exit "$SYNC_EXIT"
