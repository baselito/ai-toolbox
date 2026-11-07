#!/usr/bin/env bash
# test-sync-toolbox-lessons.sh
#
# Unit tests for scripts/sync-toolbox-lessons.sh.
#
# WHY these test cases exist:
#   The sync script is the install-time and update-time step that makes learned
#   lessons available to review agents and Codex. Getting it wrong means agents
#   silently miss lessons (fast-tier cap wrong, superseded lessons sneak through)
#   or the slow tier is clobbered on source-missing runs. Tests prove the four
#   invariants the production merge path depends on.
#
# Test cases:
#   TC-STL-1: Missing source → existing pack is preserved unchanged (fail-soft)
#   TC-STL-2: Size cap → lessons beyond 8 KB are dropped from fast tier
#              but ALL lessons are kept in slow tier
#   TC-STL-3: status:superseded → excluded from fast tier, kept in slow tier
#   TC-STL-4: empty lessons list (lessons: []) → valid empty fast tier produced
#   TC-STL-5: single lesson whose BODY ALONE exceeds 8 KB → fast tier still
#              contains exactly that one lesson (documents the accepted kept>0
#              overshoot; must not crash; must be valid YAML)
#   TC-STL-6: python3 unavailable/failed fallback → fast tier is EMPTY/header-only
#              (or a prior fast tier is preserved), NEVER an uncapped slow-tier copy
#   TC-STL-7: filename CONTRACT → the automated-review capture WRITER filename
#              (commands/review-pr.md Step 4) and the post-merge FOLD-read
#              filename (scripts/pr-postmerge-fold.sh) are byte-identical for
#              the same OWNER/REPO/PR (guards the FIX-1 sanitizer-mismatch
#              regression; the fold was extracted into a shared script so it
#              runs from both /merge-pr Step 2.5 and /review-pr Step 0.5's
#              MERGED fallback — automated-review finding, PR #127)
#   TC-STL-8: /review-pr Step 0.5's MERGED fallback fold is present, gated on
#              MERGED + the toolbox repo and NOT on HAS_AUTO_FLAG (issue #154
#              retired that term — the real freshness gate is measured inside
#              pr-postmerge-fold.sh, see TC-STL-74), and ordered BEFORE the
#              deviation SWEEP — the structural guarantee that UI/gh-merged PRs
#              get their snapshot written before it is consumed (automated-review
#              finding, PR #127). Also pins that the sweep is nullglob-guarded
#              and that no single-key per-PR read has crept back, so the
#              re-anchor cannot pass against a commented-out sweep
#   TC-STL-24: EXECUTES scripts/consume-deviations.sh to pin the consumer's
#              structural invariants — it SWEEPS every pending-deviations-*.log
#              rather than reading the merging PR's, refuses a project repo, a
#              non-MERGED PR, a symlinked state dir and a symlinked snapshot
#              (with a positive control proving the identical fixture DOES
#              archive), archives byte-identically instead of deleting, exits 2
#              without writing on an unparseable attended/unattended MODE, and
#              resolves its state dir to the same $HOME/.claude the fold writes.
#              Every assertion here used to be a scan over commands/review-pr.md,
#              because the consumer WAS commands/review-pr.md — see the test's
#              own header for why that could not be made to hold (issue #140)
#   TC-STL-25: the fold's awk STOPS extracting deviations at the next `## `
#              phase block, so phase-card metadata bullets from LATER blocks are
#              never mis-captured as deviations (measured: ~half of the 21
#              records in pending-deviations-122.log were metadata) — and, in the
#              other direction, that the `None observed.` baseline filter compares
#              the WHOLE body instead of searching for the phrase, so a genuine
#              deviation that merely QUOTES it is not silently dropped
#   TC-STL-26: EXECUTES the deviation consumer against a temp state dir to pin
#              the invariant TC-STL-24 can only approximate: SURFACING a record
#              leaves its snapshot queued, and ONLY a dismissal retires it. Runs
#              the block four times — surface, re-surface, re-surface with the
#              surfaced markers backdated 26 years (age is not a decision), then
#              dismiss — and proves nothing is archived until the dismissed log
#              names every record in the file
#   TC-STL-27: EXECUTES the consumer to prove the dismissed-log WRITE is
#              sanitized: dismissing ONE deviation whose body merely QUOTES
#              another record's log line must not retire the quoted record's
#              snapshot. Leg A (raw 80-char slice) is the vacuity guard and
#              requires the victim to be archived; leg B writes what
#              commands/review-pr.md actually SPECIFIES, so a spec that
#              regresses to a raw slice turns this test red
#   TC-STL-28: EXECUTES the consumer with shasum broken, absent, and broken only
#              BETWEEN the two passes, proving an underivable hash never becomes
#              a shared empty key that one `[] …` dismissal can use to retire
#              the whole queue
#   TC-STL-29: EXECUTES the consumer six times to pin the reprint pointer's
#              lifecycle: an unattended (`--auto`) run must record NOTHING (a
#              cron fire has no reader, so marking its output "shown" hides
#              records forever), an attended run records and resumes, an
#              unattended run must not clear an attended pointer, and an attended
#              run that prints nothing while undecided records remain queued
#              RESETS the pointer and says so
#   TC-STL-30: EXECUTES the consumer over two snapshots that used to lose a
#              record silently — a final JSON object with no trailing newline
#              (dropped by `read` in BOTH loops, so the file archived with a live
#              record inside) and a `"body":""` record — proving each blocks
#              archival and is reported instead of vanishing
#   TC-STL-31: EXECUTES the consumer from a working tree holding a `victim.log`,
#              with a decoy snapshot named `pending-deviations-1 victim.log` in
#              the state dir, proving the sweep never relocates a repo file. Leg A
#              reproduces the unquoted-`ls -t` word split in isolation so leg B's
#              "nothing moved" cannot pass vacuously
#   TC-STL-32: EXECUTES the consumer against snapshots holding NO records — a
#              0-byte one and a blank-lines-only one — proving neither is
#              archived, since archiving an empty file creates
#              `consumed-deviations/` evidence that the backlog reporter reads as
#              "a triage completed here". Leg 3 is a positive control (a genuinely
#              fully-decided snapshot must still retire, so the fail-closed
#              default cannot be bought by breaking archival); leg 4 requires the
#              record-less file to be NAMED and the false "they surface again"
#              claim to be gone; leg 5 requires an already-SURFACED snapshot NOT
#              to be misclassified as record-less
#   TC-STL-33: EXECUTES the sync to prove a cap eviction is REPORTED and that an
#              evicted `priority: high` lesson escalates to exit 4 — the silence
#              was the defect, not the cap (issue #144). Leg C is a control (a
#              source that fits entirely must stay at exit 0 with no eviction
#              report) and leg D pins exit 4 to the HIGH tag rather than to any
#              eviction, so TC-STL-2's exit-0-on-capped-input contract still
#              holds. Leg F drops the manifest argument via a `python3` shim to
#              prove the fail-open branch escalates when the eviction list cannot
#              be read at all. Leg E is a SOURCE-STRUCTURE assertion (labelled as
#              such in place) that both callers map exit 4 to their own branch
#   TC-STL-34: EXECUTES the sync against the REAL knowledge/toolbox-lessons.yml,
#              because the defect was a property of the actual byte budget: every
#              active `priority: high` lesson must reach the fast tier or be named
#              at exit 4, TL-0008 (7 occurrences) and TL-0001 (6) must reach it,
#              and the TL-0005/TL-0006 security lessons must not be traded away to
#              get them there
#   TC-STL-35: EXECUTES the sync to prove the fast tier drops the `sources:`
#              provenance list and keeps every reviewer-facing field — the
#              projection that freed the byte budget TC-STL-34 depends on. Leg 2
#              uses a provenance list that is NOT the last field, which a
#              delete-to-end-of-block stripper would silently swallow real fields
#              with; leg 3 is a control proving the slow tier still holds it
#   TC-STL-36: EXECUTES the sync to prove it resolves every `priority: high`
#              spelling it accepts — bare, double-quoted, single-quoted,
#              UPPERCASE and trailing-comment — and does not resolve a `normal`
#              or a superseded lesson as an active high one
#   TC-STL-37: EXECUTES the sync to prove the priority/status it RECORDS is the
#              one it acts on, at the position it reads them from. Legs 9 and 10
#              pin the two inputs that broke the old arrangement: `priority:
#              -high` (ordinary to the generator) and a `status:` whose value
#              sits on the following line (active to it)
#   TC-STL-38: EXECUTES the sync to prove it EMITS its decisions — a durable,
#              sentinel-terminated manifest with one row per lesson block — and
#              that a prior run's manifest is never read as this run's
#   TC-STL-39: EXECUTES the sync under a capping pass that fails AFTER writing,
#              to prove the eviction is still reported and that the run does not
#              call its own output a prior capped tier (issue #151 P0-1)
#   TC-STL-20: `priority: high` outranks occurrences in the fast-tier sort
#   TC-STL-21: an empty fast tier is REPORTED when blocks exist but none is kept,
#              and stays silent on a source that is legitimately empty
#   TC-STL-22: the empty-tier signal survives `2>/dev/null` (it is the exit code,
#              not the stderr, that both automated callers can act on)
#   TC-STL-23: an all-superseded source is silent — retired lessons are not a
#              malformation (these four predate PR #152 and were never listed)
#   TC-STL-40: EXECUTES the sync over a source whose `status:` values sit on the
#              following line, to prove the guards still see them (issue #151
#              P0-2 — the input that made the fail-toward-reporting guard inert)
#   TC-STL-41: EXECUTES the sync in the two states that reach exit 4, to prove
#              the message names an evicted high lesson only when there is one
#   TC-STL-42: the exit-4 documentation enumerates every cause it actually has,
#              a manifest whose `#END` precedes its rows is refused, and both the
#              pack README and the file-header Format note describe the record
#              that is really written (the guard-prose-overclaims class, TL-0019)
#   TC-STL-43: the record's READERS obey one contract — CRLF accepted, a reader
#              that prints the right text and then dies refused, the exit code
#              independent of the environment, the scratch and prior-tier files
#              per-run, the record read ONCE, and every reader's failure both
#              escalating and naming ITSELF rather than a reader that worked
#   TC-STL-45: EXECUTES the canonical dismissal write — one bracket-stripped,
#              newline-folded, 80-char anchored line per decision; refusals with
#              exit 2 and NO append on a mismatched hash, an empty body, an
#              8-char display key or an unknown kind; the lesson kind hitting
#              only the lessons log; no write through a symlinked log; and a
#              REPO-WIDE scan proving scripts/consume-deviations.sh is the only
#              writer of either log, in any shape, with exactly 2 destinations
#   TC-STL-46: EXECUTES the lessons half through the SAME forged-marker scenario
#              the deviation half gets, plus the per-run dedupe, the anchored
#              dismissed-lessons lookup (leg 2c carries a fixture the 80-char
#              truncation cannot save, so the anchor is pinned behaviourally for
#              BOTH halves), and the only branch in the loop that deletes files
#   TC-STL-47: EXECUTES the `archive` subcommand — Step 7's cleanup route — to
#              prove a record-less snapshot retires NOTHING after an unrelated
#              dismissal, that a genuinely decided one still retires, and that
#              both call sites agree; and asserts commands/review-pr.md CALLS
#              surface/lessons/archive/dismiss while restating none of the
#              algorithm
#   TC-STL-48: EXECUTES the `archive` subcommand to pin the three guards standing
#              in front of the `mv` that the suite could not see — each was
#              removed from the script and the whole suite stayed green: the
#              `.phase` validation (a record the SURFACE pass refuses to display
#              must not be archivable), the empty-body guard (fail-closed, not a
#              `continue` that leaves the record uncounted in both tallies), and
#              the symlink precondition on the `archive` ENTRY POINT, which
#              `surface` had and `archive` did not — reproduced on byte-identical
#              state, where `surface` refused and `archive` archived. Leg (2) is a
#              CONTROL (a well-formed decided snapshot must still retire)
#   TC-STL-44: EXECUTES TWO REAL SYNCS against one HOME, so the peer's decision
#              record is one an actual sync wrote rather than a hand-built
#              stand-in, and proves the victim run neither exits 0 nor stays
#              silent when it finds a record it did not write (automated-review + Codex,
#              PR #152 — measured at 20791b5: exit 0 with EMPTY stderr, while
#              origin/main exits 4 on the identical interleaving)
#   TC-STL-49: EXECUTES the SURFACE entry point's own gates — the mirror of
#              TC-STL-48, because 906a6c3 closed an archive/surface asymmetry
#              and pinned only the archive half: a phase-less record is never
#              displayed, a symlinked surfaced log / dismissed log / archive dir
#              are each refused by the guard's own token, a jq-less run is
#              refused up front rather than attempted, and a body duplicated
#              across two snapshots surfaces once
#   TC-STL-50: EXECUTES `cmd_lessons`' gates — the only subcommand that DELETES
#              and the least-exercised half of the consumer. Symlinked state
#              dir, non-MERGED PR, symlinked dismissed-lessons log, symlinked
#              deferred queue, absent jq and absent shasum each refuse and each
#              leave the queue on disk; plus the EOF-residue guard. Leg 9 is a
#              live control. (The deferred-queue skip was listed here too and is
#              NOT covered — C-6's name rule retired that pin mid-round; see the
#              fourth entry in the deliberately-unpinned list above.)
#   TC-STL-51: EXECUTES `archive` under a FIXED-EPOCH `date` so the archive-name
#              suffix space is genuinely exhaustible — no test had ever created a
#              collision. With all 100 taken the run refuses, warns, leaves the
#              snapshot queued and leaves the last archived file byte-identical;
#              one collision still retires. Also `archive`'s symlink and
#              have_tools gates
#   TC-STL-52: EXECUTES the sweep with `ls` STUBBED, to pin the enumeration's
#              three layers: the `-f` source filter, the filename regex, and an
#              ordering pass that may only PERMUTE. The injected set keeps the
#              same cardinality as the real one on purpose, or the fail-closed
#              count check rejects it before the membership test matters
#   TC-STL-53: EXECUTES every exit path — eleven caller bugs exit 2 leaving both
#              dismissed logs non-existent, nine gate refusals across all four
#              subcommands exit 0 carrying their own token, and the ordinary
#              runs still exit 0. Nothing had ever asserted that a refusal exits
#              0, which is the entire point of having two codes
#   TC-STL-54 … TC-STL-64: THE RED BLOCK — the round-2 fix list, written before
#              the production fixes with the expected direction of each recorded
#              in a table at the top of that block. Nine must FAIL at 906a6c3
#              and two must PASS; the two PASS rows are what stops the C-1 fix
#              being "achieved" by disabling the cleanup and the C-2 fix by
#              never reporting success
#   TC-STL-74: EXECUTES the fold over a handover.md holding raw C0 control
#              bytes — the shape a pasted line of colourised terminal output
#              leaves in a `## ` heading — to prove every one of them is
#              escaped, so the record parses through the consumer's OWN
#              `jq -er` call instead of stranding its snapshot as an
#              unarchivable, re-reported parse failure forever (issue #155).
#              Legs B and C are the inverse (TL-0011): ordinary text and a
#              multi-byte em dash round-trip byte-identically, and a literal
#              backslash, double quote and tab still decode back to exactly
#              those — which also pins the backslash pass to FIRST position
#   TC-STL-79: EXECUTES scripts/pr-postmerge-fold.sh to pin that the deviation
#              snapshot is gated on MEASURED freshness and task binding rather
#              than on a caller flag (issue #154). A 9.4h-old merge whose
#              handover names a different issue writes nothing and says which
#              issue; a same-age merge BOUND to its handover still snapshots
#              (binding outranks the clock); a 30s-old merge with an unmarked
#              handover still snapshots — that leg is /merge-pr's at-merge path
#              AND the vacuity guard; and the same unmarked handover 9.4h later,
#              or an unreadable merge time, are each refused out loud without
#              leaving a snapshot, a .tmp or a damaged handover behind
#   TC-STL-75: the merge-authority decision (issue #143) is recorded in
#              rules/git-workflow.md with a date and a repo scope, and every gate
#              that decision rests on is BOTH named in the record and performed
#              on a code line in hooks/pr-action-safety.sh — the TL-0019 half.
#              Legs 1 and 3 are PROSE assertions, labelled as such in place.
#              Legs 4 and 5 are controls: the R2 lessons carve-out survives and
#              commands/review-pr.md still keeps project and lessons paths
#              notification/manual, while the toolbox path is explicitly gated,
#              so a documentation correction cannot quietly widen authority
#
# ⛔ FOUR GUARDS ARE DELIBERATELY NOT PINNED, AND HERE IS WHY. ⛔ A mutation
# sweep listed 24 unpinned guards in this script; 20 are pinned by the tests
# above. The remaining four were each mutated and the suite did NOT move, and
# in every case that is a property of the guard, not a gap in the test:
#   * `state_symlink_violation`'s `-n "$sym"` term (a symlinked file IN the swept
#     set). `dev_enumerate_snapshots` excludes symlinks AT THE SOURCE, so within
#     one process ALL_DEV_SNAPSHOTS can never hold one. The term guards a TOCTOU
#     window between the two passes; no deterministic fixture reaches it.
#   * `dev_archive_pass`'s per-snapshot `-f && -r && ! -L`. The two-counter
#     accounting (`_decided > 0 && _outstanding == 0`) already refuses a file
#     whose loop body ran zero times, and symlinks are excluded at enumeration —
#     so removing the test changes no observable behaviour.
#   * `cut -c1-80` vs `head -c 80` in `sanitize_excerpt`. With the `tr '\n' ' '`
#     stage in front of it the two are behaviourally indistinguishable, which
#     also makes that function's own comment an over-claim: it describes the
#     PRE-FIX pipeline without saying so.
#   * The deferred-queue skip in `cmd_lessons`' pending glob. This one BECAME
#     unpinnable DURING the fix round rather than starting that way, and the
#     direction matters: `LESSONNAME_RE` (added for C-6) already excludes
#     `pending-lessons-deferred.jsonl` because `deferred` is not digits, so the
#     skip is now redundant and a test that used to redden on its removal no
#     longer can. Re-measured against this HEAD: line removed, suite still
#     `All 67 tests passed`. The line stays because the two read paths must be
#     disjoint BY CONSTRUCTION rather than by a property of the name rule — see
#     the comment at its own site in `consume-deviations.sh`.
#     ⛔ A COUNT IS A CLAIM. This entry exists because a fix in the same round
#     silently retired another guard's pin, and the header still said "21 of 24"
#     afterwards. TL-0019 is prose drifting from code in exactly this way, so
#     re-measure this list whenever a guard is added or removed — do not carry
#     the number forward on trust.
#     ⛔ AND THE "24 / 20" ABOVE IS ITSELF STALE — READ IT AS HISTORY, NOT AS A
#     CURRENT MEASUREMENT. ⛔ Guards have been ADDED to consume-deviations.sh in
#     both review rounds on this branch since that sweep ran (the per-file
#     unlink checks pinned by TC-STL-65/66, the confirmed-read gate pinned by
#     TC-STL-67, defer's dismissed-log reporting pinned by TC-STL-69, and the
#     digest-shape check pinned by TC-STL-73), and no sweep has been re-run over
#     the result. Each of those NEW guards was individually executed RED against
#     its pre-fix commit, so they are pinned; what is unknown is whether any of
#     them retired an EXISTING pin the way the deferred-queue skip did. A
#     corrected pair of numbers is not written here because inventing one would
#     be the same defect this paragraph is about: the next mutation sweep
#     replaces this note with a measurement.
# Recording them here rather than writing a leg that cannot fail: a guard test
# that passes for a reason unrelated to the guard is the inert-detector shape
# this whole file is arranged against (TL-0002).
#
# ⛔ NOTE ON READING THE PASS/FAIL COUNT ⛔ Several TCs call pass_test more than
# once, so the suite total is larger than the number of TC ids. The expected
# total is `EXPECTED_TOTAL` in the Summary block at the BOTTOM of this file, and
# it is an executable comparison that exits 1 on drift — not a number quoted in
# this paragraph.
#
# ⛔ THIS PARAGRAPH USED TO BE THE ONLY "CHECK". ⛔ It said the total was the
# backstop that caught four prior guard mutations, and it was prose addressed to
# a human: `51` appeared exactly once in the whole file, in this comment, and no
# comparison against it existed anywhere. Falsified twice — a whole test case
# whose assertion called a NON-EXISTENT helper, written in the
# `$( … 2>/dev/null )` idiom this suite uses everywhere, printed
# `All 52 tests passed.` and exited 0 with nothing on stderr. (Why it PASSES
# rather than errors: the substitution yields the empty string and
# `[[ "" -eq 0 ]]` arithmetic-evaluates the empty string as 0, so the comparison
# is TRUE. A typo'd helper name is a vacuous PASS, not a failure.) Twenty-four
# unpinned guards passed underneath that paragraph. So, stated without
# overclaiming, what the check at the bottom actually does:
#   IT DOES     detect that the NUMBER of pass_test/fail_test calls changed in
#               either direction — coverage added without EXPECTED_TOTAL being
#               updated (so a human must look at the new assertion), and an
#               assertion that stopped running (a TC skipped by a missing
#               fixture, a `pass_test` deleted, a block that exits early).
#   IT DOES NOT see an assertion added INSIDE an existing multi-leg TC: those
#               share one pass_test call, so the total does not move. Nor does
#               it say anything about whether an assertion that ran is
#               falsifiable — a tautology and a real assertion both count 1.
#               Only a mutation run proves a guard is pinned (TL-0002).
#
# Usage:
#   ./scripts/test-sync-toolbox-lessons.sh
# Exits 0 if all tests pass, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/sync-toolbox-lessons.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

pass_test() {
  local name="$1"
  PASS=$((PASS + 1))
  printf '  PASS: %s\n' "$name"
}

fail_test() {
  local name="$1"
  local reason="$2"
  FAIL=$((FAIL + 1))
  FAILED_TESTS+=("$name: $reason")
  printf '  FAIL: %s — %s\n' "$name" "$reason"
}

# ---------------------------------------------------------------------------
# Shared SOURCE SCANNERS — the one way this suite reads a source file
#
# ⛔ NEVER `grep` A SOURCE FILE DIRECTLY TO PROVE CODE EXISTS. ⛔ Four assertions
# on this branch shipped satisfiable by a COMMENT or by prose, and each was found
# by a test-quality review rather than by a regression. The pattern is always the
# same: the repo REQUIRES comments explaining a defect by name, so the comment
# beside a construct contains the same words the construct does, and a plain
# `grep` cannot tell "the code is here" from "the code is discussed here". A
# commented-out line satisfies the anchor while doing nothing at all.
#
# These helpers exclude `#`-initial lines, so an assertion built on them fails
# when the construct is commented out — which is the only reason to have them.
# TC-STL-24 defines `a24_*` wrappers that delegate here, so both tests read
# source the same way.
#
# Note markdown prose is NOT excluded — only comment lines. That is deliberate:
# in a `.md` command file an English instruction to the agent IS the code, so a
# Step 7 paragraph telling the agent to read one file is a real defect.
code_lines_in() {
  local file="$1"
  CL_NEEDLE="$2" awk '!/^[[:space:]]*#/ && index($0, ENVIRON["CL_NEEDLE"]) { print NR }' "$file"
}

# Same, for an ERE needle (passed via ENVIRON so backslashes reach awk intact).
code_re_lines_in() {
  local file="$1"
  CL_RE="$2" awk '!/^[[:space:]]*#/ && $0 ~ ENVIRON["CL_RE"] { print NR }' "$file"
}

# The matching CODE lines THEMSELVES (not their numbers), for callers that need
# to pull text out of them — e.g. extracting a filename template to compare
# across two files.
code_text_in() {
  local file="$1"
  CL_RE="$2" awk '!/^[[:space:]]*#/ && $0 ~ ENVIRON["CL_RE"]' "$file"
}

# How many of the line numbers on stdin fall within [lo, hi].
lines_between() {
  local lo="$1" hi="$2" n=0 l
  while IFS= read -r l; do
    [[ -z "$l" ]] && continue
    [[ "$l" -ge "$lo" && "$l" -le "$hi" ]] && n=$((n + 1))
  done
  printf '%s' "$n"
}


# Shared helpers for every EXECUTED consumer test below (TC-STL-24, 26-32,
# 45-47).
#
# ⛔ THESE USED TO EXTRACT SHELL OUT OF A MARKDOWN FENCE. THEY NOW RUN THE REAL
# SCRIPT. ⛔ Until issue #140 the consumer lived entirely in commands/review-pr.md
# Step 0.5 as prose with illustrative fences, so a behavioural test had to cut a
# line range out of the `.md`, inject the five variables the surrounding scope
# would have set, and run THAT — a reconstruction, not the artifact. Everything
# that made the reconstruction necessary is gone:
#   - the injected `CLAUDE_DIR`/`PR_STATE`/`IS_TOOLBOX_REPO`/`HAS_AUTO_FLAG`
#     variables are now ARGUMENTS and GATES inside the script, so a test can no
#     longer accidentally hand the consumer a state it could never reach in
#     production (and, conversely, the gates are now testable at all);
#   - the marker-comment line range is gone, so renaming a comment can no longer
#     silently reduce a behavioural test to running an empty string;
#   - `consumer_pick_shell` is gone. It existed because the extracted block used
#     `declare -A`, which needs bash 4+ or zsh, and the obvious probe SELECTS
#     bash 3.2 (there `_t[k]=1` creates an INDEXED array whose subscript
#     arithmetic-evaluates to 0, so a single-key round-trip agrees with itself
#     and every hash would collapse onto index 0). The script carries a
#     `#!/usr/bin/env bash` shebang and stock macOS ships bash 3.2, so it uses a
#     portable string set instead and runs anywhere.
CONSUMER_MD="$(cd "$(dirname "$0")/.." && pwd)/commands/review-pr.md"
CONSUMER_SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/consume-deviations.sh"

# Run the REAL surface pass against a throwaway HOME. $1 is the HOME (its
# `.claude` subdirectory is the state dir the script derives); $2 is
# `attended` or `unattended`. stdout and stderr are merged, because several
# assertions below look for guard messages that go to stderr.
#
# HOME is the ONLY thing redirected, and that is deliberate: the script resolves
# its state directory as `$HOME/.claude` with no override, exactly as
# scripts/pr-postmerge-fold.sh writes it and scripts/verify.sh reads it. A test
# that could point the state dir somewhere else would not be testing the
# production resolution — which is the one thing a reader/writer split would
# break silently.
consumer_run() {
  HOME="$1" bash "$CONSUMER_SCRIPT" surface baselito ai-engineering 4242 MERGED "$2" 2>&1
}

# Record a dismissal through the canonical write, deriving the digest the same
# way the script does. Takes the BODY, not a hash, because the script refuses a
# hash that does not match its body — so a test that hand-built a mismatched
# line would be testing its own fixture rather than the writer.
consumer_dismiss() {
  local home="$1" kind="$2" body="$3" h
  h=$(printf '%s' "$body" | shasum -a 256 | awk '{print $1}')
  printf '%s' "$body" | HOME="$home" bash "$CONSUMER_SCRIPT" dismiss "$kind" "$h" 2>&1
}

consumer_archived() { find "$1/consumed-deviations" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' '; }
consumer_queued()   { find "$1" -maxdepth 1 -type f -name 'pending-deviations-*.log' 2>/dev/null | wc -l | tr -d ' '; }

# Build a PATH directory holding a symlink to every external tool the consumer
# calls EXCEPT the ones named, so `command -v <tool>` fails INSIDE the script
# without removing anything else it needs. Returns non-zero if any tool cannot be
# resolved, so a caller reports a SETUP failure rather than asserting against a
# run that died for an unrelated reason (the shape TC-STL-28 leg 2 established).
#
# The interpreter is NOT one of these tools and must be invoked by absolute path
# with the script as its argument — putting bash on the stripped PATH would let
# the shebang re-resolve through it, and running the script by path would too.
consumer_minbin_without() {  # consumer_minbin_without <dir> <tool-to-omit>...
  local dir="$1"; shift
  local omit="|" t p
  for t in "$@"; do omit="$omit$t|"; done
  mkdir -p "$dir" || return 1
  # Every external command `scripts/consume-deviations.sh` invokes. `rm` is on
  # the list because `cmd_lessons` deletes with it; omitting it would make a
  # jq-absent leg fail for a reason that has nothing to do with jq.
  for t in awk basename cat cut date grep head jq ls mkdir mv rm sed shasum touch tr; do
    case "$omit" in *"|$t|"*) continue ;; esac
    p=$(command -v "$t" 2>/dev/null) || return 1
    [[ -n "$p" ]] || return 1
    ln -sf "$p" "$dir/$t" || return 1
  done
  return 0
}

# The number of files left in a lessons queue (per-PR snapshots + the deferred
# queue), for the legs that assert `cmd_lessons` deleted nothing.
consumer_lessons_queued() { find "$1" -maxdepth 1 -type f -name 'pending-lessons-*.jsonl' 2>/dev/null | wc -l | tr -d ' '; }

# ⛔ A chmod-BASED FIXTURE IS VACUOUS FOR root. ⛔ Several tests below depend on
# a file genuinely being unreadable (`chmod 000`) or unwritable (`chmod 444`).
# Running as root, or on a filesystem that ignores permission bits, silently
# turns every one of those into a test of the ordinary path — passing for a
# reason that has nothing to do with the guard. Probe it, and report a SETUP
# failure rather than a pass.
perms_are_enforced() {
  local f; f=$(mktemp) || return 1
  printf 'x' > "$f"
  chmod 000 "$f" 2>/dev/null || { rm -f "$f"; return 1; }
  if cat "$f" >/dev/null 2>&1; then chmod 644 "$f" 2>/dev/null; rm -f "$f"; return 1; fi
  chmod 644 "$f" 2>/dev/null
  printf 'x' > "$f"
  chmod 444 "$f" 2>/dev/null || { rm -f "$f"; return 1; }
  # ⛔ THE SUBSHELL IS LOAD-BEARING. ⛔ `2>/dev/null` on a simple command
  # suppresses the COMMAND's stderr, not the SHELL's own "Permission denied"
  # from a redirection it could not open — that message is printed by the shell
  # in the current process and leaked onto this suite's stderr three times.
  if ( printf 'y' >> "$f" ) 2>/dev/null; then chmod 644 "$f" 2>/dev/null; rm -f "$f"; return 1; fi
  chmod 644 "$f" 2>/dev/null; rm -f "$f"
  return 0
}

# ⛔ THE SIBLING PROBE FOR A FAILING UNLINK. ⛔ `perms_are_enforced` probes FILE
# modes; deleting a file is governed by the mode of its DIRECTORY, which is a
# different bit and can be enforced differently (root, and some mounts, ignore
# it). A test that means to exercise a refused `rm` needs to know its fixture
# really refuses one — otherwise it silently becomes a test of the ordinary
# delete and passes for a reason unrelated to the guard.
dir_unlink_is_blocked() {
  local d f; d=$(mktemp -d) || return 1
  f="$d/probe"
  printf 'x' > "$f" 2>/dev/null || { rm -rf "$d"; return 1; }
  chmod 555 "$d" 2>/dev/null || { chmod 755 "$d" 2>/dev/null; rm -rf "$d"; return 1; }
  if rm -f "$f" 2>/dev/null && [[ ! -e "$f" ]]; then
    chmod 755 "$d" 2>/dev/null; rm -rf "$d"; return 1   # unlink succeeded => NOT blocked
  fi
  chmod 755 "$d" 2>/dev/null; rm -rf "$d"
  return 0
}

# ---------------------------------------------------------------------------

# Create a minimal valid toolbox-lessons.yml with N active lessons.
# Each lesson body is padded to approximately `body_size` bytes so we can
# craft scenarios that straddle the 8 KB fast-tier cap.
make_lessons_yml() {
  local dest="$1"
  local n_lessons="${2:-2}"
  local body_size="${3:-50}"         # approximate bytes per lesson body
  local include_superseded="${4:-no}" # "yes" to include one superseded entry

  # Header the sync script must survive (schema_version + lessons list)
  cat > "$dest" <<'HEADER'
# toolbox-lessons.yml — Durable learned lessons from review findings.
# Human-gated (PR-reviewed, human-approved before any lesson lands here).
# Advisory knowledge only — never executable.
schema_version: 1
lessons:
HEADER

  # Active lessons
  local i
  for i in $(seq 1 "$n_lessons"); do
    # Pad body to requested size so we can craft cap scenarios.
    local pad
    # Generate a deterministic padding string of body_size chars.
    pad=$(printf '%*s' "$body_size" "" | tr ' ' 'x')
    cat >> "$dest" <<LESSON
  - id: "TL-$(printf '%04d' "$i")"
    category: "test-coverage"
    lesson: "Lesson $i body: $pad"
    guidance: "Guidance for lesson $i."
    sources:
      - pr: "inherited-history#1"
        origin: "automated-review"
        verdict: "fixed"
        ts: "2026-01-01T00:00:00Z"
    occurrences: $i
    first_seen: "2026-01-01"
    last_seen: "2026-01-$(printf '%02d' "$i")"
    status: "active"
LESSON
  done

  # Optional superseded entry
  if [[ "$include_superseded" == "yes" ]]; then
    cat >> "$dest" <<'SUPERSEDED'
  - id: "TL-SUPR"
    category: "cross-file-consistency"
    lesson: "This lesson was superseded and should NOT appear in the fast tier."
    guidance: "Use TL-0001 instead."
    sources: []
    occurrences: 1
    first_seen: "2025-01-01"
    last_seen: "2025-01-01"
    status: "superseded"
    superseded_by: "TL-0001"
SUPERSEDED
  fi
}

# ---------------------------------------------------------------------------
# TC-STL-1: Missing source → existing pack preserved
#
# WHY: The sync script must behave like sync-codex-knowledge.sh on source
# absence: warn and leave the existing ~/.claude/toolbox-knowledge/ intact.
# Silent data loss (clobbering a good pack because the source file was
# temporarily missing) is strictly worse than a no-op.
# ---------------------------------------------------------------------------
echo ""
echo "=== sync-toolbox-lessons.sh ==="
echo ""

TC="TC-STL-1: missing source → existing pack preserved"
tmp_home=$(mktemp -d)
trap "rm -rf '$tmp_home'" EXIT

# Seed an existing pack so we can verify it survives.
mkdir -p "$tmp_home/.claude/toolbox-knowledge"
echo "pre-existing-fast" > "$tmp_home/.claude/toolbox-knowledge/lessons.yml"
echo "pre-existing-slow" > "$tmp_home/.claude/toolbox-knowledge/toolbox-lessons.yml"

# Point the sync script at a non-existent source (no knowledge/ dir, no yml).
# We do this by running in a temp repo_root that has NO knowledge/toolbox-lessons.yml.
fake_repo=$(mktemp -d)
# The script locates the source relative to its own SCRIPT_DIR; we pass an
# env override SOURCE_OVERRIDE to tell the script where to look.
OUTPUT=$(HOME="$tmp_home" SOURCE_OVERRIDE="$fake_repo/knowledge/toolbox-lessons.yml" \
  bash "$SYNC_SCRIPT" --quiet 2>&1 || true)

# Verify the existing pack is unchanged.
if [[ -f "$tmp_home/.claude/toolbox-knowledge/lessons.yml" ]] && \
   grep -q "pre-existing-fast" "$tmp_home/.claude/toolbox-knowledge/lessons.yml"; then
  pass_test "$TC (fast tier preserved)"
else
  fail_test "$TC" "fast tier was overwritten or deleted when source was missing"
fi

if [[ -f "$tmp_home/.claude/toolbox-knowledge/toolbox-lessons.yml" ]] && \
   grep -q "pre-existing-slow" "$tmp_home/.claude/toolbox-knowledge/toolbox-lessons.yml"; then
  pass_test "$TC (slow tier preserved)"
else
  fail_test "$TC" "slow tier was overwritten or deleted when source was missing"
fi

rm -rf "$fake_repo" "$tmp_home"

# ---------------------------------------------------------------------------
# TC-STL-2: Size cap → lowest-value lessons dropped from fast tier, kept in slow
#
# WHY: The 8 KB fast-tier cap keeps review-prompt injections bounded. Lessons
# beyond the cap must NOT silently vanish from the slow tier — they are still
# the authoritative record; only the realtime injection is trimmed.
# We create enough large-body lessons to exceed 8 KB combined, then verify
# the slow tier has all of them and the fast tier is ≤ 8 KB.
# ---------------------------------------------------------------------------
TC="TC-STL-2: size cap enforced"
tmp_home=$(mktemp -d)
trap "rm -rf '$tmp_home'" EXIT

fake_repo=$(mktemp -d)
mkdir -p "$fake_repo/knowledge"

# 30 lessons × ~400-byte body ≈ ~12 KB total — exceeds the 8 KB fast-tier cap.
make_lessons_yml "$fake_repo/knowledge/toolbox-lessons.yml" 30 400

OUTPUT=$(HOME="$tmp_home" SOURCE_OVERRIDE="$fake_repo/knowledge/toolbox-lessons.yml" \
  bash "$SYNC_SCRIPT" --quiet 2>&1) && SYNC_RC=0 || SYNC_RC=$?
# A valid capped input must exit 0 — install.sh/update.sh treat a non-zero sync
# as a failure, so a regression to non-zero here must fail this test (it didn't
# before: `|| true` masked the exit code).
if [[ "${SYNC_RC:-1}" -eq 0 ]]; then
  pass_test "$TC (sync exits 0 on valid capped input)"
else
  fail_test "$TC" "sync exited ${SYNC_RC} on valid input (install.sh/update.sh would treat this as a failure)"
fi

SLOW_FILE="$tmp_home/.claude/toolbox-knowledge/toolbox-lessons.yml"
FAST_FILE="$tmp_home/.claude/toolbox-knowledge/lessons.yml"

# Slow tier: all 30 lessons present.
SLOW_COUNT=$(grep -c '^  - id:' "$SLOW_FILE" 2>/dev/null || echo 0)
if [[ "$SLOW_COUNT" -eq 30 ]]; then
  pass_test "$TC (slow tier has all 30 lessons)"
else
  fail_test "$TC" "slow tier has $SLOW_COUNT lessons, expected 30"
fi

# Fast tier: must exist and be ≤ 8192 bytes.
if [[ -f "$FAST_FILE" ]]; then
  FAST_SIZE=$(wc -c < "$FAST_FILE" | tr -d ' ')
  if [[ "$FAST_SIZE" -le 8192 ]]; then
    pass_test "$TC (fast tier ≤ 8 KB: ${FAST_SIZE} bytes)"
  else
    fail_test "$TC" "fast tier is ${FAST_SIZE} bytes > 8192 bytes"
  fi
else
  fail_test "$TC" "fast tier file not produced"
fi

rm -rf "$fake_repo" "$tmp_home"

# ---------------------------------------------------------------------------
# TC-STL-3: status:superseded excluded from fast tier, kept in slow tier
#
# WHY: Superseded lessons must not pollute review prompts with stale guidance.
# But they must remain in the slow tier as the immutable history record (needed
# for PR audit trails and future provenance checks).
# ---------------------------------------------------------------------------
TC="TC-STL-3: superseded excluded from fast tier"
tmp_home=$(mktemp -d)
trap "rm -rf '$tmp_home'" EXIT

fake_repo=$(mktemp -d)
mkdir -p "$fake_repo/knowledge"

# 2 active lessons + 1 superseded. Total is small so cap doesn't interfere.
make_lessons_yml "$fake_repo/knowledge/toolbox-lessons.yml" 2 50 "yes"

OUTPUT=$(HOME="$tmp_home" SOURCE_OVERRIDE="$fake_repo/knowledge/toolbox-lessons.yml" \
  bash "$SYNC_SCRIPT" --quiet 2>&1 || true)

SLOW_FILE="$tmp_home/.claude/toolbox-knowledge/toolbox-lessons.yml"
FAST_FILE="$tmp_home/.claude/toolbox-knowledge/lessons.yml"

# Slow tier: must contain the superseded lesson (id TL-SUPR).
if grep -q "TL-SUPR" "$SLOW_FILE" 2>/dev/null; then
  pass_test "$TC (slow tier retains superseded lesson)"
else
  fail_test "$TC" "slow tier is missing TL-SUPR (superseded lesson should be kept)"
fi

# Fast tier: must NOT contain TL-SUPR.
if grep -q "TL-SUPR" "$FAST_FILE" 2>/dev/null; then
  fail_test "$TC" "fast tier contains TL-SUPR (superseded lessons must be excluded)"
else
  pass_test "$TC (fast tier excludes superseded lesson)"
fi

# Fast tier: active lessons (TL-0001, TL-0002) must still be present.
if grep -q "TL-0001" "$FAST_FILE" 2>/dev/null && grep -q "TL-0002" "$FAST_FILE" 2>/dev/null; then
  pass_test "$TC (fast tier retains active lessons)"
else
  fail_test "$TC" "fast tier is missing active lessons TL-0001 or TL-0002"
fi

rm -rf "$fake_repo" "$tmp_home"

# ---------------------------------------------------------------------------
# TC-STL-4: empty lessons list → valid empty fast tier produced
#
# WHY: An empty list is a valid source state (the file starts with no lessons).
# The sync script must produce an empty (or header-only) fast tier without
# crashing. A crash here would block install.sh from completing.
# ---------------------------------------------------------------------------
TC="TC-STL-4: empty lessons list produces valid empty fast tier"
tmp_home=$(mktemp -d)
trap "rm -rf '$tmp_home'" EXIT

fake_repo=$(mktemp -d)
mkdir -p "$fake_repo/knowledge"

cat > "$fake_repo/knowledge/toolbox-lessons.yml" <<'EMPTY'
# toolbox-lessons.yml — empty initial state (seeded at first install).
schema_version: 1
lessons: []
EMPTY

OUTPUT=$(HOME="$tmp_home" SOURCE_OVERRIDE="$fake_repo/knowledge/toolbox-lessons.yml" \
  bash "$SYNC_SCRIPT" --quiet 2>&1 || true)

FAST_FILE="$tmp_home/.claude/toolbox-knowledge/lessons.yml"
SLOW_FILE="$tmp_home/.claude/toolbox-knowledge/toolbox-lessons.yml"

# Both files must exist (fast tier may be empty or header-only).
if [[ -f "$FAST_FILE" ]]; then
  pass_test "$TC (fast tier file created)"
else
  fail_test "$TC" "fast tier file was not created from empty source"
fi

if [[ -f "$SLOW_FILE" ]]; then
  pass_test "$TC (slow tier file created)"
else
  fail_test "$TC" "slow tier file was not created from empty source"
fi

# The fast tier must structurally look like valid YAML — check for the
# required schema keys using grep (stdlib, always available), mirroring how
# the prod script itself validates without PyYAML. Avoids depending on an
# optional third-party library (PyYAML) in the test suite when the production
# code deliberately avoids it too.
if grep -q 'schema_version:' "$FAST_FILE" && grep -q 'lessons:' "$FAST_FILE"; then
  pass_test "$TC (fast tier is valid YAML structure)"
else
  fail_test "$TC" "fast tier is missing schema_version or lessons keys"
fi

rm -rf "$fake_repo" "$tmp_home"

# ---------------------------------------------------------------------------
# TC-STL-5: single lesson whose body ALONE exceeds 8 KB → kept anyway (kept>0)
#
# WHY: The python capping loop has an intentional `kept > 0` guard so the first
# lesson is always included even if it alone exceeds the cap — one oversized
# lesson is better than an empty fast tier. This test documents that accepted
# behavior: confirm the single lesson survives, the script does not crash, and
# the fast tier is structurally valid YAML. This is the ONE intentional way the
# fast tier may exceed 8 KB; the fallback path (TC-STL-6) must NOT.
# ---------------------------------------------------------------------------
TC="TC-STL-5: single oversized lesson is kept (accepted kept>0 overshoot)"
tmp_home=$(mktemp -d)
trap "rm -rf '$tmp_home'" EXIT

fake_repo=$(mktemp -d)
mkdir -p "$fake_repo/knowledge"

# 1 lesson with a ~10 KB body (single lesson alone > 8 KB cap).
make_lessons_yml "$fake_repo/knowledge/toolbox-lessons.yml" 1 10240

OUTPUT=$(HOME="$tmp_home" SOURCE_OVERRIDE="$fake_repo/knowledge/toolbox-lessons.yml" \
  bash "$SYNC_SCRIPT" --quiet 2>&1)
RC=$?
FAST_FILE="$tmp_home/.claude/toolbox-knowledge/lessons.yml"

# Must not crash.
if [[ $RC -eq 0 ]]; then
  pass_test "$TC (script exits 0, no crash)"
else
  fail_test "$TC" "script crashed with exit code $RC"
fi

# Fast tier must contain exactly the one oversized lesson (TL-0001).
FAST_LESSON_COUNT=$(grep -c '^  - id:' "$FAST_FILE")  # grep -c prints 0 on no match
if [[ "$FAST_LESSON_COUNT" -eq 1 ]] && grep -q "TL-0001" "$FAST_FILE" 2>/dev/null; then
  pass_test "$TC (fast tier has exactly the one oversized lesson)"
else
  fail_test "$TC" "fast tier has $FAST_LESSON_COUNT lessons (expected exactly 1: TL-0001)"
fi

# Fast tier must still be structurally valid YAML.
if grep -q 'schema_version:' "$FAST_FILE" 2>/dev/null && grep -q 'lessons:' "$FAST_FILE" 2>/dev/null; then
  pass_test "$TC (fast tier is valid YAML structure)"
else
  fail_test "$TC" "fast tier is missing schema_version or lessons keys"
fi

rm -rf "$fake_repo" "$tmp_home"

# ---------------------------------------------------------------------------
# TC-STL-6: python3 unavailable/failed → fast tier EMPTY/header-only, NOT uncapped
#
# WHY (P1-B fix): when the python capping pass cannot run, the script must NOT
# `cp` the full slow tier verbatim as the fast tier — that produces an UNCAPPED
# file that consumers inject assuming ≤ 8 KB. The safe fallback emits a
# header-only/empty fast tier (or preserves a prior capped one).
#
# We simulate "python3 unavailable" by running the script with a PATH that
# contains symlinks to every utility the script needs EXCEPT python3. This makes
# `command -v python3` return nothing → the script takes the python-absent
# fallback branch. We build the sanitized PATH dir from the real binary
# locations so the test works regardless of where coreutils live on this host.
# ---------------------------------------------------------------------------
TC="TC-STL-6: python-unavailable fallback emits empty (not uncapped) fast tier"
tmp_home=$(mktemp -d)
trap "rm -rf '$tmp_home'" EXIT

fake_repo=$(mktemp -d)
mkdir -p "$fake_repo/knowledge"

# Many large lessons → if the fallback copied the slow tier verbatim, the fast
# tier would be well over 8 KB. The safe fallback must keep it empty instead.
make_lessons_yml "$fake_repo/knowledge/toolbox-lessons.yml" 30 400

# Build a PATH dir with symlinks to the utilities the sync script needs, EXCEPT
# python3. Listing them explicitly keeps the test deterministic across hosts.
nopy_bin=$(mktemp -d)
for util in bash sh env dirname pwd mkdir cp cat mktemp chmod rm cut date tr; do
  util_path=$(command -v "$util" 2>/dev/null || true)
  [[ -n "$util_path" ]] && ln -sf "$util_path" "$nopy_bin/$util"
done
# Sanity: python3 must NOT be reachable via this PATH.
if PATH="$nopy_bin" command -v python3 >/dev/null 2>&1; then
  fail_test "$TC" "test setup error: python3 still reachable via sanitized PATH"
else
  OUTPUT=$(PATH="$nopy_bin" HOME="$tmp_home" \
    SOURCE_OVERRIDE="$fake_repo/knowledge/toolbox-lessons.yml" \
    "$nopy_bin/bash" "$SYNC_SCRIPT" --quiet 2>&1)
  RC=$?
  FAST_FILE="$tmp_home/.claude/toolbox-knowledge/lessons.yml"

  # CONTRACT CHANGED on this branch: this fallback emits an EMPTY fast tier, and an
  # empty tier now signals exit 3 so the condition survives the `2>/dev/null` that
  # install.sh and update.sh both apply. Exit 0 previously meant "degraded, carry
  # on" — but carrying on silently over a tier the agent reads NOTHING from is the
  # month-long outage this work exists to fix. Fail-soft is preserved where it
  # matters: the pack is still written, install/update still complete every later
  # step, and the caller warns instead of claiming success.
  #
  # The OTHER fallback branch — a prior capped tier exists and is preserved — still
  # exits 0, because that tier is NOT empty. Verified separately.
  if [[ $RC -eq 3 ]]; then
    pass_test "$TC (exits 3 — empty tier signalled, not silently passed off as success)"
  else
    fail_test "$TC" "expected exit 3 (empty fast tier) under python-absent fallback, got $RC"
  fi

  # Fast tier must exist, be ≤ 8 KB, and contain ZERO lessons (header-only).
  if [[ -f "$FAST_FILE" ]]; then
    FB_SIZE=$(wc -c < "$FAST_FILE" | tr -d ' ')
    # grep -c already prints 0 on no match (and exits 1); do NOT add `|| echo 0`
    # or the count becomes "0\n0" (grep's 0 plus the echo's 0) → arithmetic error.
    FB_LESSONS=$(grep -c '^  - id:' "$FAST_FILE")
    if [[ "$FB_SIZE" -le 8192 && "$FB_LESSONS" -eq 0 ]]; then
      pass_test "$TC (fast tier is header-only/empty: ${FB_SIZE}B, 0 lessons — NOT an uncapped copy)"
    else
      fail_test "$TC" "fast tier is ${FB_SIZE}B with $FB_LESSONS lessons — fallback wrote an uncapped copy"
    fi
    # Must still be valid YAML structure.
    if grep -q 'schema_version:' "$FAST_FILE" && grep -q 'lessons:' "$FAST_FILE"; then
      pass_test "$TC (header-only fast tier is valid YAML structure)"
    else
      fail_test "$TC" "header-only fast tier is missing schema_version or lessons keys"
    fi
  else
    fail_test "$TC" "fast tier file was not produced under python-absent fallback"
  fi
fi

rm -rf "$nopy_bin" "$fake_repo" "$tmp_home"

# ---------------------------------------------------------------------------
# TC-STL-7: automated-review capture filename CONTRACT (writer == fold-read), byte-identical
#
# WHY: the old test rebuilt both WRITER_FILE and FOLD_FILE from the SAME local
# sanitize_id() helper — a tautology that could never catch real writer/fold
# divergence. The test PARSES the source files: the WRITER lives in
# commands/review-pr.md (Step 4); the FOLD-read used to live inline in
# commands/merge-pr.md (Step 2.5) but was extracted into scripts/pr-postmerge-fold.sh
# (automated-review finding, PR #127 — the fold now runs from BOTH /merge-pr Step 2.5
# AND /review-pr Step 0.5's MERGED fallback, so it had to become a single
# shared script rather than staying inline in one caller). It greps for every
# distinct .pr-learnings-…jsonl filename template ACROSS BOTH FILES and
# asserts there is exactly ONE (i.e. all sites use the same template) with at
# least one occurrence IN EACH FILE (deleting either side breaks the
# contract). It also asserts zero SAFE_OWNER/SAFE_REPO_NAME assignments in
# either file use `echo` (echo appends a newline that tr -c turns into a
# trailing '_', causing orphaned capture files).
# ---------------------------------------------------------------------------
TC="TC-STL-7: automated-review capture writer/fold filename is byte-identical (parsed from review-pr.md + pr-postmerge-fold.sh)"
# Locate the source files relative to this test script (scripts/ -> ../commands/, ./).
REVIEW_PR_MD="$(cd "$(dirname "$0")/.." && pwd)/commands/review-pr.md"
MERGE_PR_MD="$(cd "$(dirname "$0")/.." && pwd)/commands/merge-pr.md"
POSTMERGE_FOLD_SH="$(cd "$(dirname "$0")" && pwd)/pr-postmerge-fold.sh"
if [[ ! -f "$REVIEW_PR_MD" || ! -f "$MERGE_PR_MD" || ! -f "$POSTMERGE_FOLD_SH" ]]; then
  fail_test "$TC" "cannot locate commands/review-pr.md ($REVIEW_PR_MD), commands/merge-pr.md ($MERGE_PR_MD), or scripts/pr-postmerge-fold.sh ($POSTMERGE_FOLD_SH)"
else
  # Parse the ACTUAL sources: every site that builds the .pr-learnings filename
  # must use the SAME template. If a future edit makes one site diverge (different
  # var order, echo vs printf, different suffix), the distinct-template count goes
  # >1 and this fails — unlike the old tautology that rebuilt both sides from one
  # local helper and could never diverge.
  # ⛔ CODE LINES ONLY, here as everywhere in this suite. ⛔ These scans said
  # nothing about whether the line was code, so the day someone documents the
  # removed writer by name — which this repo's comment policy actively asks for —
  # deleting the live writer would still leave the template "present" in both
  # files and this contract would pass over a broken one. No such comment exists
  # today; that is luck, not a property, and it is the same luck the four
  # comment-satisfiable assertions on this branch ran out of.
  DISTINCT_TEMPLATES=$( { code_text_in "$REVIEW_PR_MD" '\.pr-learnings-'; code_text_in "$POSTMERGE_FOLD_SH" '\.pr-learnings-'; } \
    | grep -oE '\.pr-learnings-[^"]*\.jsonl' | sort -u)
  TEMPLATE_COUNT=$(printf '%s\n' "$DISTINCT_TEMPLATES" | grep -c .)
  # Per-file occurrence counts. The WRITER (review-pr.md Step 4) and the
  # FOLD-read (pr-postmerge-fold.sh) must BOTH be present — requiring >=1 in
  # EACH file catches the case where one side is deleted (a total count across
  # both files could still pass with one side missing).
  # `|| true`: under `set -o pipefail` (set at the top of this script), a grep that
  # matches nothing makes the pipeline exit non-zero. There's no `set -e` here so it
  # would not actually abort, but the `|| true` removes the ambiguity and matches the
  # ECHO_SANITIZERS line below — and keeps it correct if `set -e` is ever added.
  WRITER_OCCURRENCES=$(code_text_in "$REVIEW_PR_MD" '\.pr-learnings-' | grep -oE '\.pr-learnings-[^"]*\.jsonl' | wc -l | tr -d ' ' || true)
  FOLD_OCCURRENCES=$(code_text_in "$POSTMERGE_FOLD_SH" '\.pr-learnings-' | grep -oE '\.pr-learnings-[^"]*\.jsonl' | wc -l | tr -d ' ' || true)
  # ⛔ /merge-pr must STILL invoke the shared fold after extraction. Parsing only
  # the writer + the script would let a regression where /merge-pr stops calling
  # pr-postmerge-fold.sh pass silently (direct agent-side merges would then skip
  # the fold entirely). Match an ACTUAL `bash ".../pr-postmerge-fold.sh"`
  # invocation, NOT any textual mention — a prose/comment reference to the script
  # name must not satisfy the check (automated-review finding, PR #127).
  # This is the assertion whose own comment above claimed "a prose/comment
  # reference to the script name must not satisfy the check" while a plain `grep`
  # could not tell the two apart: a commented-out
  # `# bash ".../pr-postmerge-fold.sh" …` line satisfied it exactly. Code only.
  MERGE_CALL_OCCURRENCES=$(code_re_lines_in "$MERGE_PR_MD" 'bash ".*/pr-postmerge-fold\.sh"' | grep -c . || true)
  # The SAFE_OWNER/SAFE_REPO_NAME sanitizers must all use printf '%s' (echo would
  # append a newline that tr -c turns into a trailing '_', diverging the filename).
  # Code only for the opposite reason to the checks above: this is a NEGATIVE
  # assertion (must be 0), so a comment discussing the echo-vs-printf trap would
  # fail it spuriously — punishing the documentation the repo requires.
  ECHO_SANITIZERS=$( { code_text_in "$REVIEW_PR_MD" 'SAFE_(OWNER|REPO_NAME)='; code_text_in "$POSTMERGE_FOLD_SH" 'SAFE_(OWNER|REPO_NAME)='; } \
    | grep -c 'echo ' || true)
  if [[ "$TEMPLATE_COUNT" -eq 1 && "$WRITER_OCCURRENCES" -ge 1 && "$FOLD_OCCURRENCES" -ge 1 && "$MERGE_CALL_OCCURRENCES" -ge 1 && "$ECHO_SANITIZERS" -eq 0 ]]; then
    pass_test "$TC (single template across all sites: $(printf '%s' "$DISTINCT_TEMPLATES" | tr '\n' ' '); writer=$WRITER_OCCURRENCES, fold=$FOLD_OCCURRENCES, merge-call=$MERGE_CALL_OCCURRENCES; 0 echo-based sanitizers)"
  else
    fail_test "$TC" "templates=$TEMPLATE_COUNT (expected 1: $(printf '%s' "$DISTINCT_TEMPLATES" | tr '\n' '|')), writer=$WRITER_OCCURRENCES (expected >=1 in review-pr.md), fold=$FOLD_OCCURRENCES (expected >=1 in pr-postmerge-fold.sh), merge-call=$MERGE_CALL_OCCURRENCES (expected >=1 in merge-pr.md), echo-sanitizers=$ECHO_SANITIZERS (expected 0)"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-8: /review-pr Step 0.5 MERGED fallback runs the fold BEFORE consuming it
#
# WHY (automated-review finding, PR #127): the fold was extracted to a shared script so
# it also runs from /review-pr Step 0.5's MERGED path — catching PRs merged via
# the GitHub UI / bare gh (not /merge-pr). That coverage depends on THREE
# structural properties that a future edit could silently break:
#   (a) the fallback call exists in review-pr.md,
#   (b) it is gated on the facts THIS caller owns — PR_STATE == MERGED and the
#       toolbox repo — and NOT on HAS_AUTO_FLAG. That term used to be here as
#       the mis-attribution guard; issue #154 measured it failing at that job
#       (a hand-typed late `--auto` satisfied it), so the guard moved into
#       pr-postmerge-fold.sh where the merge age and the handover's own task
#       heading can be read. Its absence is asserted, not merely tolerated,
#   (c) it runs BEFORE the consumer is invoked — if the call moved after it, a
#       UI-merged PR's snapshot would not exist yet when the consumer enumerated
#       the directory, so that PR's deviations would be missed on the run that
#       was supposed to catch them. Ordering still matters for exactly the same
#       reason it did when the reader opened one named file: the snapshot has to
#       be on disk before the read happens.
# This test parses review-pr.md and asserts all three (static ordering check —
# there is no runnable harness for a .md command file, so line-order is the
# proxy for "call precedes consumption").
#
# ⛔ THE READER ANCHOR MOVED AGAIN, AND THIS TIME IT LEFT THE FILE. ⛔ It was
# `SNAPSHOT_FILE=`, then the `for … pending-deviations-*.log` sweep loop, and
# issue #140 moved the whole consumer into scripts/consume-deviations.sh — so the
# thing that consumes snapshots in review-pr.md is now the `surface` invocation.
# Re-anchoring to it is not a weakening: the old glob anchor had in fact become
# UNSOUND, because `improve N`'s prose legitimately says "walk every record of
# every `~/.claude/pending-deviations-*.log`" and the scanners deliberately treat
# markdown prose as code (in a `.md` command file an English instruction IS the
# instruction). That paragraph matched the sweep pattern, so the anchor would
# have landed on documentation 700 lines below the real call site. An invocation
# line cannot be confused with prose about one.
#
# The single-key per-PR read must still be gone file-wide, in review-pr.md AND in
# the script: that is the strand-the-queue bug, and it can be reintroduced on
# either side of the new boundary.
#
# ⛔ EVERY ANCHOR HERE IS SCANNED AS CODE, NOT AS TEXT. ⛔ Every lookup below used
# a plain `grep`, and the paragraph above claimed the sub-assertions guard against
# "a COMMENTED-OUT sweep" while none of them could tell a comment from code.
# Verified by hand: prefixing the live `bash ".../pr-postmerge-fold.sh"` line
# with `# ` left the call anchor satisfied (the comment two lines below it names
# the script), prefixing the `for … pending-deviations-*.log` line with `# ` left
# the sweep anchor AND its nullglob window satisfied, and the HAS_AUTO_FLAG /
# PR_STATE gate window was satisfiable by the comment that explains the gate. So
# the test could report the whole mechanism intact with all of it commented out —
# the fourth comment-satisfiable assertion this branch produced, which is why the
# scanners are now shared (`code_lines_in` / `code_re_lines_in`, top of file) and
# why every anchor in this test goes through them.
# ---------------------------------------------------------------------------
TC="TC-STL-8: /review-pr Step 0.5 fallback fold is present, MERGED+toolbox-gated (never --auto-gated), and precedes a live guarded sweep"
REVIEW_PR_MD="$(cd "$(dirname "$0")/.." && pwd)/commands/review-pr.md"
if [[ ! -f "$REVIEW_PR_MD" ]]; then
  fail_test "$TC" "cannot locate commands/review-pr.md ($REVIEW_PR_MD)"
else
  # (a) the fallback CALL line (any `bash ".../pr-postmerge-fold.sh"` invocation
  #     — matched loosely on the script path so the check doesn't couple to the
  #     exact install-dir prefix), IN CODE.
  FALLBACK_CALL_LINE=$(code_re_lines_in "$REVIEW_PR_MD" 'bash ".*/pr-postmerge-fold\.sh"' | head -1)
  # (c) the reader: the `surface` invocation of consume-deviations.sh. This is
  #     the first line that CONSUMES snapshots, so it holds the same positional
  #     role the sweep loop did and "fold call precedes consumption" still means
  #     what it says. Code-only, so a commented-out call does not count.
  READER_LINE=$(code_re_lines_in "$REVIEW_PR_MD" 'consume-deviations\.sh"?.*surface|CONSUME_SCRIPT"? surface' | head -1)
  # The consumer must still ARM nullglob before its own sweep — an unmatched glob
  # would otherwise pass the literal pattern to the loop body and the sweep would
  # silently read nothing while every structural check still passed. That guard
  # now lives in the script, so it is asserted there rather than here.
  READER_NULLGLOB=0
  CONSUMER_SWEEP_LINE=$(code_re_lines_in "$CONSUMER_SCRIPT" 'for .*pending-deviations-\*\.log' | head -1)
  if [[ -n "$CONSUMER_SWEEP_LINE" ]]; then
    READER_WIN=$(( CONSUMER_SWEEP_LINE > 8 ? CONSUMER_SWEEP_LINE - 8 : 1 ))
    READER_NULLGLOB=$(code_re_lines_in "$CONSUMER_SCRIPT" 'shopt -s nullglob' \
      | lines_between "$READER_WIN" "$CONSUMER_SWEEP_LINE")
  fi
  # The strand-the-queue bug can be reintroduced on EITHER side of the new
  # boundary, so both files are scanned.
  SINGLE_KEY_READS=$(( $(code_re_lines_in "$REVIEW_PR_MD" 'pending-deviations-[$]\{?PR_NUMBER' | grep -c . || true) \
                     + $(code_re_lines_in "$CONSUMER_SCRIPT" 'pending-deviations-[$]\{?PR_NUMBER' | grep -c . || true) ))

  if [[ -z "$FALLBACK_CALL_LINE" ]]; then
    fail_test "$TC" "no Step 0.5 fallback call to pr-postmerge-fold.sh found in review-pr.md CODE (coverage for UI/gh-merged PRs is gone — note a commented-out call does not count)"
  elif [[ -z "$READER_LINE" ]]; then
    fail_test "$TC" "could not locate the consume-deviations.sh \`surface\` invocation in review-pr.md CODE — Step 0.5 no longer consumes anything, or a commented-out call is standing in for it"
  elif [[ -z "$CONSUMER_SWEEP_LINE" ]]; then
    fail_test "$TC" "could not locate the pending-deviations sweep (for ... pending-deviations-*.log) in scripts/consume-deviations.sh CODE — a commented-out sweep does not count"
  elif [[ "$READER_NULLGLOB" -lt 1 ]]; then
    fail_test "$TC" "the consumer's sweep at scripts/consume-deviations.sh:$CONSUMER_SWEEP_LINE has no \`shopt -s nullglob\` in the 8 CODE lines above it — an unmatched glob would pass the literal pattern through, so the sweep exists but consumes nothing"
  elif [[ "$SINGLE_KEY_READS" -ne 0 ]]; then
    fail_test "$TC" "$SINGLE_KEY_READS single-key pending-deviations-\${PR_NUMBER} read(s) remain in review-pr.md or consume-deviations.sh — a per-PR read strands every other snapshot"
  else
    # (b) STRONG gate check — the call must be governed by a POSITIVE
    # PR_STATE==MERGED condition and by the toolbox-repo condition, not just the
    # bare substrings appearing somewhere nearby. Both positive comparison tokens
    # must appear on CODE lines in the 8-line guard window; a negated/renamed/
    # unrelated condition fails, and so does the comment that explains the gate
    # (which sits right above it and contains the same names).
    #
    # ⛔ HAS_AUTO_FLAG IS NO LONGER PART OF THIS GATE, AND ITS ABSENCE IS NOW
    # ASSERTED. ⛔ This test used to REQUIRE `$HAS_AUTO_FLAG == "true"` here, on
    # the reasoning quoted in (b) above: a cron fires promptly, so it catches a
    # UI/`gh` merge while handover.md still belongs to that PR's work. Issue #154
    # measured the flag failing at exactly that job — a hand-typed
    # `/review-pr … 149 --auto` 9.4h after the merge satisfied it — because
    # `--auto` is an argv string, not a clock. The real gate moved into
    # scripts/pr-postmerge-fold.sh, which measures the merge's age and whether
    # handover.md's trailing task heading names this PR's work (TC-STL-74 runs
    # it). Re-adding the flag here would restore a check that reads as safety and
    # measures nothing, so the NEGATIVE assertion below keeps it out.
    GUARD_LO=$(( FALLBACK_CALL_LINE > 8 ? FALLBACK_CALL_LINE - 8 : 1 ))
    HAS_MERGED_GATE=$(code_re_lines_in "$REVIEW_PR_MD" '"\$PR_STATE"[[:space:]]*==[[:space:]]*"MERGED"' \
      | lines_between "$GUARD_LO" "$FALLBACK_CALL_LINE")
    HAS_TOOLBOX_GATE=$(code_re_lines_in "$REVIEW_PR_MD" '"\$REPO_NAME"[[:space:]]*==[[:space:]]*"ai-engineering"' \
      | lines_between "$GUARD_LO" "$FALLBACK_CALL_LINE")
    STALE_AUTO_GATE=$(code_re_lines_in "$REVIEW_PR_MD" '"\$HAS_AUTO_FLAG"[[:space:]]*==[[:space:]]*"true"' \
      | lines_between "$GUARD_LO" "$FALLBACK_CALL_LINE")
    if [[ "$HAS_MERGED_GATE" -ge 1 && "$HAS_TOOLBOX_GATE" -ge 1 && "$STALE_AUTO_GATE" -eq 0 \
       && "$FALLBACK_CALL_LINE" -lt "$READER_LINE" ]]; then
      pass_test "$TC (call@$FALLBACK_CALL_LINE positively gated on \$PR_STATE==MERGED && the toolbox repo with NO \$HAS_AUTO_FLAG term, precedes the consume-deviations.sh surface call@$READER_LINE whose own sweep is nullglob-guarded, zero single-key reads in either file — every anchor scanned as code)"
    else
      fail_test "$TC" "call@$FALLBACK_CALL_LINE consume-call@$READER_LINE merged-gate=$HAS_MERGED_GATE toolbox-gate=$HAS_TOOLBOX_GATE stale-auto-gate=$STALE_AUTO_GATE (need positive \$PR_STATE==\"MERGED\" AND \$REPO_NAME==\"ai-engineering\" on CODE lines in the guard window, ZERO \$HAS_AUTO_FLAG==\"true\" terms there — issue #154 — AND call before reader)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-20: priority:high outranks a higher occurrence count in the fast tier
#
# WHY: the fast tier is capped, so the sort decides what an agent actually reads.
# Sorting on occurrences alone meant the cap dropped whichever lessons had been
# seen fewest times — and the first time this file was populated for real, that
# was the two SECURITY lessons (a prose-as-command-source code-execution path,
# and cross-repo state collision, both seen twice) while a stale-doc-count lesson
# seen six times was kept. How often a class recurs is not how badly it hurts.
#
# This pins the fix: a low-occurrence priority:high lesson must be ordered ahead
# of a high-occurrence untagged one. It also pins that untagged lessons keep the
# old frequency ordering among themselves, so the change is additive.
# ---------------------------------------------------------------------------
TC="TC-STL-20: priority:high outranks occurrences"
tmp_home=$(mktemp -d)
fake_repo=$(mktemp -d)
mkdir -p "$fake_repo/knowledge"

cat > "$fake_repo/knowledge/toolbox-lessons.yml" <<'YML'
schema_version: 1
lessons:
  - id: TL-FREQ
    category: docs
    lesson: seen often, low consequence
    guidance: grep the old count
    occurrences: 99
    first_seen: 2026-07-01
    last_seen: 2026-07-01
    status: active
  - id: TL-SEC
    category: security
    lesson: seen rarely, severe consequence
    guidance: never execute a script from the reviewed repo
    occurrences: 1
    first_seen: 2026-07-02
    last_seen: 2026-07-02
    status: active
    priority: high
  - id: TL-MID
    category: docs
    lesson: middling frequency, untagged
    guidance: check the file against itself
    occurrences: 50
    first_seen: 2026-07-03
    last_seen: 2026-07-03
    status: active
YML

HOME="$tmp_home" SOURCE_OVERRIDE="$fake_repo/knowledge/toolbox-lessons.yml" \
  bash "$SYNC_SCRIPT" --quiet >/dev/null 2>&1 || true
FAST_FILE="$tmp_home/.claude/toolbox-knowledge/lessons.yml"

# Order of first appearance in the fast tier.
ORDER=$(grep -o 'TL-[A-Z]*' "$FAST_FILE" 2>/dev/null | tr '\n' ' ')
case "$ORDER" in
  "TL-SEC TL-FREQ TL-MID "*)
    pass_test "$TC (priority:high first, then occurrences desc)" ;;
  *)
    fail_test "$TC" "expected 'TL-SEC TL-FREQ TL-MID', got '$ORDER'" ;;
esac

rm -rf "$tmp_home" "$fake_repo"

# ---------------------------------------------------------------------------
# TC-STL-21: a silently EMPTY fast tier is reported, not passed off as success
#
# WHY: the capping pass parses lesson blocks structurally, so one malformed or
# missing field yields zero "active" blocks and a technically valid, entirely
# EMPTY fast tier. That happened for real while populating this file: an edit
# stripped `status: active` from all twelve lessons, the fast tier came back at
# 171 bytes with nothing in it, and NOTHING failed — the sync reported success,
# these unit tests passed (they use their own fixtures, not the real source), and
# verify.sh passed. The agent would have read zero lessons, which is precisely the
# month-long outage the surrounding work exists to repair.
#
# Note the guard counts lesson BLOCKS, not `status: active` lines. Counting the
# status line was the first attempt and it did not work: stripping `status:` drops
# the active count to zero as well, so "0 of 0 kept" read as fine. The blocks-vs-
# kept comparison is what actually detects the case.
#
# Non-fatal by design — an empty source is legitimate at first install, which the
# second half of this test pins.
# ---------------------------------------------------------------------------
TC="TC-STL-21: empty fast tier is reported"
tmp_home=$(mktemp -d)
fake_repo=$(mktemp -d)
mkdir -p "$fake_repo/knowledge"

# Three well-formed lesson blocks, none marked active.
cat > "$fake_repo/knowledge/toolbox-lessons.yml" <<'YML'
schema_version: 1
lessons:
  - id: TL-A
    category: docs
    lesson: body a
    guidance: do a
    occurrences: 3
    first_seen: 2026-07-01
    last_seen: 2026-07-01
  - id: TL-B
    category: docs
    lesson: body b
    guidance: do b
    occurrences: 2
    first_seen: 2026-07-02
    last_seen: 2026-07-02
YML

OUT=$(HOME="$tmp_home" SOURCE_OVERRIDE="$fake_repo/knowledge/toolbox-lessons.yml" \
  bash "$SYNC_SCRIPT" 2>&1 || true)
case "$OUT" in
  *"Fast tier is EMPTY"*) pass_test "$TC (warns when blocks exist but none are kept)" ;;
  *) fail_test "$TC" "expected an EMPTY-fast-tier warning; got: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-200)" ;;
esac

# A genuinely empty source must NOT warn — nothing is wrong at first install.
tmp_home2=$(mktemp -d)
fake_repo2=$(mktemp -d)
mkdir -p "$fake_repo2/knowledge"
printf 'schema_version: 1\nlessons: []\n' > "$fake_repo2/knowledge/toolbox-lessons.yml"
OUT2=$(HOME="$tmp_home2" SOURCE_OVERRIDE="$fake_repo2/knowledge/toolbox-lessons.yml" \
  bash "$SYNC_SCRIPT" 2>&1 || true)
case "$OUT2" in
  *"Fast tier is EMPTY"*) fail_test "$TC" "warned on a legitimately empty source (lessons: [])" ;;
  *) pass_test "$TC (silent on a legitimately empty source)" ;;
esac

rm -rf "$tmp_home" "$fake_repo" "$tmp_home2" "$fake_repo2"

# ---------------------------------------------------------------------------
# TC-STL-22: the empty-fast-tier condition survives the callers' `2>/dev/null`
#
# WHY: TC-STL-21 proved the WARNING is emitted. An audit then proved the warning
# is useless in production, because both automated callers invoke this script as
# `... --quiet 2>/dev/null` and then print their own unconditional success — so
# the only signal was discarded on 100% of installs and updates. A guard that
# fires only on a manual run is not a guard; that is this repo's own TL-0003
# (a partial gate reading as complete) reproduced inside the fix for it.
#
# The condition therefore travels by EXIT CODE 3, which survives the redirect.
# This pins the contract both callers depend on: 3 for empty-but-source-has-blocks,
# 0 for healthy. If someone later makes this a hard failure, install.sh and
# update.sh must be updated together — they distinguish 3 from a real failure.
# ---------------------------------------------------------------------------
TC="TC-STL-22: empty-tier signal survives 2>/dev/null"
tmp_home=$(mktemp -d); fake_repo=$(mktemp -d); mkdir -p "$fake_repo/knowledge"
cat > "$fake_repo/knowledge/toolbox-lessons.yml" <<'YML'
schema_version: 1
lessons:
  - id: TL-A
    category: docs
    lesson: body a
    guidance: do a
    occurrences: 3
    first_seen: 2026-07-01
    last_seen: 2026-07-01
YML
RC=0
HOME="$tmp_home" SOURCE_OVERRIDE="$fake_repo/knowledge/toolbox-lessons.yml" \
  bash "$SYNC_SCRIPT" --quiet 2>/dev/null || RC=$?
if [[ "$RC" -eq 3 ]]; then
  pass_test "$TC (exit 3 with stderr discarded)"
else
  fail_test "$TC" "expected exit 3 through 2>/dev/null, got $RC"
fi
rm -rf "$tmp_home" "$fake_repo"

# A healthy source must still exit 0 — otherwise every install warns.
tmp_home2=$(mktemp -d); fake_repo2=$(mktemp -d); mkdir -p "$fake_repo2/knowledge"
make_lessons_yml "$fake_repo2/knowledge/toolbox-lessons.yml" 3 50 "no"
RC2=0
HOME="$tmp_home2" SOURCE_OVERRIDE="$fake_repo2/knowledge/toolbox-lessons.yml" \
  bash "$SYNC_SCRIPT" --quiet 2>/dev/null || RC2=$?
if [[ "$RC2" -eq 0 ]]; then
  pass_test "$TC (healthy source still exits 0)"
else
  fail_test "$TC" "healthy source exited $RC2, expected 0 — every install would warn"
fi
rm -rf "$tmp_home2" "$fake_repo2"

# ---------------------------------------------------------------------------
# TC-STL-23: an ALL-SUPERSEDED source is a valid config, not a malformation
#
# WHY: the fast tier is active-ONLY by design, so a source whose lessons have all
# been retired legitimately produces an empty tier. The first version of the
# empty-tier guard keyed purely on "blocks exist AND nothing kept", which fired
# here — crying wolf on a valid configuration and, worse, exiting 3 so every
# install and update would report a problem (automated-review, PR #134).
#
# The distinction is whether each block carries a RECOGNISED status:
#   all superseded      -> status lines == blocks, none active. Correct, silent.
#   status line missing -> status lines <  blocks. Malformed, warn.
#   active but none kept-> active > 0 with kept == 0. Something ate them, warn.
# This pins the first case; TC-STL-21/22 pin the other two.
# ---------------------------------------------------------------------------
TC="TC-STL-23: all-superseded source is silent"
tmp_home=$(mktemp -d); fake_repo=$(mktemp -d); mkdir -p "$fake_repo/knowledge"
cat > "$fake_repo/knowledge/toolbox-lessons.yml" <<'YML'
schema_version: 1
lessons:
  - id: TL-OLD1
    category: docs
    lesson: retired guidance one
    guidance: superseded by TL-NEW
    occurrences: 2
    first_seen: 2026-07-01
    last_seen: 2026-07-01
    status: superseded
  - id: TL-OLD2
    category: docs
    lesson: retired guidance two
    guidance: superseded by TL-NEW
    occurrences: 1
    first_seen: 2026-07-02
    last_seen: 2026-07-02
    status: superseded
YML
RC=0
OUT=$(HOME="$tmp_home" SOURCE_OVERRIDE="$fake_repo/knowledge/toolbox-lessons.yml" \
  bash "$SYNC_SCRIPT" --quiet 2>&1) || RC=$?
if [[ "$RC" -eq 0 ]]; then
  pass_test "$TC (exits 0 — retired lessons are not a malformation)"
else
  fail_test "$TC" "all-superseded source exited $RC, expected 0 — every install would warn"
fi
# Assert on the WARNING MARKER, not on two known phrasings. automated-review's follow-up:
# allowlisting "EMPTY" and "no recognised status" means a regression that warns in
# DIFFERENT words sails through — the test claims "silent" while only checking for
# the two strings I happened to write. `warn()` prefixes every warning with ⚠️, so
# the absence of that character is the actual contract, independent of wording.
#
# Stronger than asserting empty output, which would also fail on any benign
# non-warning line a future version might legitimately print under --quiet.
case "$OUT" in
  *"⚠️"*) fail_test "$TC" "warned on a legitimate all-superseded source: $OUT" ;;
  *) pass_test "$TC (no warning of any wording)" ;;
esac
rm -rf "$tmp_home" "$fake_repo"

# ---------------------------------------------------------------------------
# TC-STL-24: the deviation consumer's structural invariants, asserted by
#            EXECUTING scripts/consume-deviations.sh
#
# WHY THIS TEST CHANGED SHAPE (issue #140). Every assertion in this test used to
# be a scan over commands/review-pr.md, because the consumer WAS
# commands/review-pr.md — English prose with illustrative shell fences. That is
# the weakest form a test can take, and the branch history proves it rather than
# asserting it: over five review rounds the same file produced five separate
# dismissal-log writers where the design claimed one, and FIVE assertions that a
# comment or a paragraph could satisfy. Each was found by a test-quality review
# rather than by a regression, which is exactly what "the test cannot fail"
# means. Round 4's own guard is the clearest case: its needle was `>>.*dismissed`,
# so it could only ever see a writer shaped like a shell append — and the writer
# it missed was English.
#
# The consumer is now a script. So the sweep, the gates, the archive rule and the
# fail-closed defaults are asserted by RUNNING it and looking at what happened to
# the files, not by proving a line still sits in a particular place. Each leg
# below names the production edit that flips it RED.
#
# WHAT IS DELIBERATELY NOT HERE ANY MORE, and why that is not a loss:
#   - the nullglob-above-the-sweep check. It is a property of the script's source
#     rather than of a run (the `-f` filter one line below it independently
#     rejects an unmatched literal pattern, so removing nullglob alone changes no
#     observable behaviour), and TC-STL-8 pins it statically in the script.
#   - the positional "which pass does this grep live in" checks (old 7b/7c). The
#     invariant they approximated — being SHOWN never archives, only being
#     DISMISSED does — is asserted behaviourally by TC-STL-26, which is where it
#     belongs.
#   - the `CLAUDE_DIR=` agreement check (old 8f). Leg (i) below runs the writer
#     with a redirected HOME and asserts the file lands at `$HOME/.claude/…`,
#     which pins the real resolution instead of pinning two expressions to each
#     other.
# ---------------------------------------------------------------------------
TC="TC-STL-24: the consumer's sweep, gates and archive rule (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the consumer parses JSONL with jq, so this behavioural test cannot run (brew install jq / apt install jq)"
else
  A24_FAILURES=()

  # A record body plus the digest the script will derive from it, computed here
  # with the same formula, independently of anything the script writes.
  a24_digest() { printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; }
  a24_seed_record() {  # <state dir> <pr number> <body>
    printf '{"ts":"2026-01-01T00:00:00Z","phase":"Implementation","body":"%s"}\n' "$3" \
      > "$1/pending-deviations-$2.log"
  }

  # --- (a) THE SWEEP: every queued snapshot, not just the merging PR's ---
  # This is the defect the whole test was created for. A snapshot written for PR
  # #129 used to be re-read only by a run FOR #129, and once #129 merged nothing
  # ever ran for it again: 6 snapshots / 75 records / 57 unique bodies sat unread
  # in ~/.claude while dismissed-deviations.log stayed 0 bytes. The run below is
  # for PR 999 and neither snapshot belongs to it, so a per-PR reader surfaces
  # nothing at all.
  # FALSIFYING EDIT: change the enumeration in `dev_enumerate_snapshots` to read
  # `$CLAUDE_DIR/pending-deviations-${pr}.log` instead of globbing.
  a24_h1=$(mktemp -d); a24_s1="$a24_h1/.claude"; mkdir -p "$a24_s1"
  a24_b_alpha="SWEEP alpha from an older PR"
  a24_b_beta="SWEEP beta from another older PR"
  a24_seed_record "$a24_s1" 111 "$a24_b_alpha"
  a24_seed_record "$a24_s1" 222 "$a24_b_beta"
  A24_OUT_A=$(HOME="$a24_h1" bash "$CONSUMER_SCRIPT" surface baselito ai-engineering 999 MERGED attended 2>&1)
  printf '%s\n' "$A24_OUT_A" | grep -q "$(a24_digest "$a24_b_alpha" | cut -c1-8)" \
    || A24_FAILURES+=("(a) the run for PR 999 did not surface the snapshot from PR 111 — the consumer is reading one PR's file instead of sweeping the queue, which strands every other snapshot permanently: $A24_OUT_A")
  printf '%s\n' "$A24_OUT_A" | grep -q "$(a24_digest "$a24_b_beta" | cut -c1-8)" \
    || A24_FAILURES+=("(a) the run for PR 999 did not surface the snapshot from PR 222: $A24_OUT_A")
  printf '%s\n' "$A24_OUT_A" | grep -q 'CONSUME-DEVIATIONS: surface surfaced=2 ' \
    || A24_FAILURES+=("(a) the summary line did not report surfaced=2: $A24_OUT_A")
  rm -rf "$a24_h1"

  # --- (b) AN EMPTY QUEUE CONSUMES NOTHING AND CLAIMS NOTHING ---
  # An enumeration that reported success on an empty set would print the surface
  # header ("Surfacing captured deviations (N snapshot(s) …)") over a queue that
  # holds nothing, and every count downstream would be describing a set that was
  # never built.
  # FALSIFYING EDIT: make `dev_enumerate_snapshots` return 0 unconditionally.
  a24_h2=$(mktemp -d); mkdir -p "$a24_h2/.claude"
  A24_OUT_B=$(HOME="$a24_h2" bash "$CONSUMER_SCRIPT" surface baselito ai-engineering 1 MERGED attended 2>&1)
  printf '%s\n' "$A24_OUT_B" | grep -q 'Surfacing captured deviations' \
    && A24_FAILURES+=("(b) an EMPTY state dir printed the surface header — the enumeration reported work on a queue that holds nothing: $A24_OUT_B")
  printf '%s\n' "$A24_OUT_B" | grep -q 'surfaced=0 remaining=0' \
    || A24_FAILURES+=("(b) an empty state dir did not report surfaced=0: $A24_OUT_B")
  rm -rf "$a24_h2"

  # --- (c) THE REPO GATE ---
  # Snapshots are keyed by PR NUMBER ALONE with no owner/repo, and only the
  # toolbox fold writes them — so every pending-deviations-*.log in ~/.claude is
  # a TOOLBOX snapshot. The `--auto` leg of the caller's condition has no repo
  # gate of its own, so before this branch existed an `--auto` cron fire on a
  # merged PR in ANY project repo would sweep, surface and then consume the whole
  # toolbox queue — silently, because it prints into a session nobody is watching.
  # The fixture is FULLY DECIDED on purpose: with the gate removed this run
  # archives, so the leg fails on a state change rather than on a missing print.
  # FALSIFYING EDIT: delete the `is_toolbox_repo` check from `cmd_surface`.
  a24_h3=$(mktemp -d); a24_s3="$a24_h3/.claude"; mkdir -p "$a24_s3"
  a24_b_gate="REPO GATE record that a project repo must never touch"
  a24_seed_record "$a24_s3" 333 "$a24_b_gate"
  consumer_dismiss "$a24_h3" deviation "$a24_b_gate" >/dev/null
  A24_OUT_C=$(HOME="$a24_h3" bash "$CONSUMER_SCRIPT" surface someorg someproject 1 MERGED attended 2>&1)
  printf '%s\n' "$A24_OUT_C" | grep -q 'refused=not-toolbox-repo' \
    || A24_FAILURES+=("(c) a run from someorg/someproject was not refused by the repo gate: $A24_OUT_C")
  [[ "$(consumer_archived "$a24_s3")" -eq 0 ]] \
    || A24_FAILURES+=("(c) a run from a PROJECT repo archived a toolbox snapshot — the repo gate is gone and any project repo's --auto cron fire now consumes the toolbox queue: $A24_OUT_C")
  [[ "$(consumer_queued "$a24_s3")" -eq 1 ]] \
    || A24_FAILURES+=("(c) the toolbox snapshot left the queue on a project-repo run")

  # --- (d) THE MERGED GATE ---
  # A CLOSED PR means the work did not ship, so there is nothing to learn from
  # and nothing to retire. Same fully-decided fixture, so the gate is the only
  # thing preventing an archive.
  # FALSIFYING EDIT: delete the `[[ "$state" != "MERGED" ]]` check from `cmd_surface`.
  A24_OUT_D=$(HOME="$a24_h3" bash "$CONSUMER_SCRIPT" surface baselito ai-engineering 1 CLOSED attended 2>&1)
  printf '%s\n' "$A24_OUT_D" | grep -q 'refused=pr-not-merged' \
    || A24_FAILURES+=("(d) a CLOSED PR was not refused: $A24_OUT_D")
  [[ "$(consumer_archived "$a24_s3")" -eq 0 ]] \
    || A24_FAILURES+=("(d) a CLOSED PR archived a snapshot — work that did not ship retired the record of why: $A24_OUT_D")

  # --- (d2) POSITIVE CONTROL for (c) and (d) ---
  # ⛔ WITHOUT THIS THE TWO GATE LEGS ABOVE ARE SATISFIED BY A CONSUMER THAT
  # ARCHIVES NOTHING EVER. ⛔ The same fixture, now with the right repo and the
  # right state, MUST archive — otherwise "nothing was archived" proves only that
  # the feature is broken.
  A24_OUT_D2=$(HOME="$a24_h3" bash "$CONSUMER_SCRIPT" surface baselito ai-engineering 1 MERGED attended 2>&1)
  [[ "$(consumer_archived "$a24_s3")" -eq 1 ]] \
    || A24_FAILURES+=("(d2 positive control) the SAME fully-decided fixture did not archive on a toolbox/MERGED run — legs (c) and (d) would then pass against a consumer that can never archive at all: $A24_OUT_D2")
  rm -rf "$a24_h3"

  # --- (e) A SYMLINKED STATE DIRECTORY IS REFUSED ---
  # State files live outside any repo, so a malicious branch cannot replace them
  # — but a user who has linked their home config elsewhere can, and following
  # the link would clobber unintended paths. Better to skip the loop than to
  # write through it.
  # FALSIFYING EDIT: delete the `claude_dir_is_symlink` branch from `cmd_surface`.
  a24_h4=$(mktemp -d); a24_real4="$a24_h4/real-state"; mkdir -p "$a24_real4"
  ln -s "$a24_real4" "$a24_h4/.claude"
  a24_b_sym="SYMLINK state dir record"
  a24_seed_record "$a24_real4" 444 "$a24_b_sym"
  printf '[%s] 2026-01-01T00:00:00Z | %s\n' "$(a24_digest "$a24_b_sym")" "$a24_b_sym" \
    > "$a24_real4/dismissed-deviations.log"
  A24_OUT_E=$(HOME="$a24_h4" bash "$CONSUMER_SCRIPT" surface baselito ai-engineering 1 MERGED attended 2>&1)
  printf '%s\n' "$A24_OUT_E" | grep -q 'refused=symlinked-state-dir' \
    || A24_FAILURES+=("(e) a SYMLINKED state directory was not refused: $A24_OUT_E")
  [[ -f "$a24_real4/pending-deviations-444.log" ]] \
    || A24_FAILURES+=("(e) the consumer followed a symlinked state dir and moved a file through it: $A24_OUT_E")
  rm -rf "$a24_h4"

  # --- (f) A SYMLINKED SNAPSHOT IS NEVER CONSUMED ---
  # Two escapes close at the enumeration: a symlinked FILE, and a symlinked
  # DIRECTORY named like a snapshot (whose ENTRIES would otherwise expand into
  # the set, each of them an ordinary file that passes a later per-file symlink
  # test — so the guard would be bypassed by exactly the thing it exists to
  # catch). A legitimate decided snapshot runs alongside, so the leg cannot pass
  # by the consumer doing nothing.
  # FALSIFYING EDIT: drop `! -L "$_snap"` from the enumeration filter in
  # `dev_enumerate_snapshots`.
  a24_h5=$(mktemp -d); a24_s5="$a24_h5/.claude"; mkdir -p "$a24_s5"
  a24_b_legit="LEGIT decided record"
  a24_seed_record "$a24_s5" 501 "$a24_b_legit"
  a24_b_link="LINKED record that must not be consumed through a symlink"
  printf '{"ts":"2026-01-01T00:00:00Z","phase":"Verification","body":"%s"}\n' "$a24_b_link" \
    > "$a24_h5/outside-target.log"
  ln -s "$a24_h5/outside-target.log" "$a24_s5/pending-deviations-502.log"
  consumer_dismiss "$a24_h5" deviation "$a24_b_legit" >/dev/null
  consumer_dismiss "$a24_h5" deviation "$a24_b_link" >/dev/null
  A24_OUT_F=$(consumer_run "$a24_h5" attended)
  [[ -f "$a24_h5/outside-target.log" ]] \
    || A24_FAILURES+=("(f) the symlink's TARGET was moved out of place — a snapshot sweep followed a symlink and relocated a file the state dir does not own: $A24_OUT_F")
  [[ -L "$a24_s5/pending-deviations-502.log" ]] \
    || A24_FAILURES+=("(f) the symlinked snapshot was consumed (it is no longer a symlink in the state dir): $A24_OUT_F")
  [[ -f "$a24_s5/consumed-deviations/pending-deviations-501.log" ]] \
    || A24_FAILURES+=("(f) the LEGITIMATE fully-decided snapshot was not archived — the symlink filter has been bought by excluding valid snapshots too: $A24_OUT_F")
  rm -rf "$a24_h5"

  # --- (g) ARCHIVE, NEVER DELETE — and the evidence is byte-identical ---
  # "Consumed" must mean MOVED, never destroyed: the archived file is the only
  # remaining record that the triage happened at all.
  # FALSIFYING EDITS: replace the `mv` in `dev_archive_pass` with `rm`, or with
  # a copy that rewrites the file.
  a24_h6=$(mktemp -d); a24_s6="$a24_h6/.claude"; mkdir -p "$a24_s6"
  a24_b_arch="ARCHIVE ME, do not delete me"
  a24_seed_record "$a24_s6" 601 "$a24_b_arch"
  a24_before=$(shasum -a 256 < "$a24_s6/pending-deviations-601.log" | awk '{print $1}')
  consumer_dismiss "$a24_h6" deviation "$a24_b_arch" >/dev/null
  A24_OUT_G=$(consumer_run "$a24_h6" attended)
  if [[ ! -f "$a24_s6/consumed-deviations/pending-deviations-601.log" ]]; then
    A24_FAILURES+=("(g) the fully-decided snapshot is not in consumed-deviations/ — it was deleted rather than archived, or never retired at all: $A24_OUT_G")
  else
    a24_after=$(shasum -a 256 < "$a24_s6/consumed-deviations/pending-deviations-601.log" | awk '{print $1}')
    [[ "$a24_before" == "$a24_after" ]] \
      || A24_FAILURES+=("(g) the archived snapshot's content changed during the move — the archive is supposed to be the untouched evidence")
  fi
  [[ "$(consumer_queued "$a24_s6")" -eq 0 ]] \
    || A24_FAILURES+=("(g) the archived snapshot is still queued as well — it was copied, not moved, so it will surface forever")
  rm -rf "$a24_h6"

  # --- (h) AN UNPARSEABLE MODE REFUSES AND WRITES NOTHING ---
  # ⛔ THE ATTENDED/UNATTENDED DISTINCTION DECIDES WHETHER THE REPRINT POINTER MAY
  # BE WRITTEN, AND WRITING IT WRONGLY HIDES RECORDS PERMANENTLY. ⛔ So a value
  # the script does not recognise must not be guessed in either direction: it is
  # a CALLER bug, it exits 2, and it performs no work at all. (Guessing
  # "attended" would hide records; guessing "unattended" would hide the typo.)
  # FALSIFYING EDIT: change the `*)` arm of the MODE case in `cmd_surface` to
  # default to attended or unattended instead of exiting.
  a24_h7=$(mktemp -d); a24_s7="$a24_h7/.claude"; mkdir -p "$a24_s7"
  a24_b_mode="MODE record"
  a24_seed_record "$a24_s7" 701 "$a24_b_mode"
  consumer_dismiss "$a24_h7" deviation "$a24_b_mode" >/dev/null
  A24_OUT_H=$(HOME="$a24_h7" bash "$CONSUMER_SCRIPT" surface baselito ai-engineering 1 MERGED attende 2>&1)
  A24_RC_H=$?
  [[ "$A24_RC_H" -eq 2 ]] \
    || A24_FAILURES+=("(h) a misspelled MODE exited $A24_RC_H, expected 2 — a caller bug on the one argument that decides whether records can be hidden must be loud, never guessed: $A24_OUT_H")
  [[ "$(consumer_archived "$a24_s7")" -eq 0 ]] \
    || A24_FAILURES+=("(h) a run refused for a bad MODE still archived a snapshot — a usage error must perform no work: $A24_OUT_H")
  [[ ! -e "$a24_s7/surfaced-deviations.log" ]] \
    || A24_FAILURES+=("(h) a run refused for a bad MODE created the reprint pointer — a usage error must write nothing: $A24_OUT_H")
  rm -rf "$a24_h7"

  # --- (i) THE STATE DIRECTORY IS `$HOME/.claude`, RESOLVED FROM HOME ---
  # ⛔ THIS REPLACES THE OLD "both CLAUDE_DIR= expressions agree" SCAN. ⛔ That
  # scan only ever proved the file agreed with ITSELF: changing BOTH assignments
  # to the same wrong directory left the whole suite green, and reader and writer
  # would then agree with each other while disagreeing with the two things they
  # must match — scripts/pr-postmerge-fold.sh, which WRITES the snapshots to a
  # literal `$HOME/.claude`, and scripts/verify.sh, which reads the backlog from
  # the same literal. Running the writer with a redirected HOME and looking at
  # where the byte landed pins the real resolution instead of pinning two
  # expressions to each other.
  # FALSIFYING EDITS: change `CLAUDE_DIR="$HOME/.claude"` in
  # scripts/consume-deviations.sh to any other path, or make it honour an
  # environment override the fold does not honour.
  a24_h8=$(mktemp -d)
  a24_b_home="HOME RESOLUTION record"
  consumer_dismiss "$a24_h8" deviation "$a24_b_home" >/dev/null
  [[ -s "$a24_h8/.claude/dismissed-deviations.log" ]] \
    || A24_FAILURES+=("(i) the dismissal did not land at \$HOME/.claude/dismissed-deviations.log with HOME redirected to $a24_h8 — the consumer resolves its state directory somewhere other than the literal \$HOME/.claude that scripts/pr-postmerge-fold.sh writes and scripts/verify.sh reads, so decisions land where nothing consumes them")
  # And the FOLD — the writer of the snapshots this consumer reads — must resolve
  # the same directory. This half stays static because running the fold needs a
  # git checkout and `gh`; it is the cheapest possible check that the two ends of
  # the shared key space have not drifted apart.
  # The fold builds its paths through a state-dir VARIABLE in one place and from
  # the literal in another, so a naive "does the line say \$HOME/.claude" scan
  # reports a false split. One level of indirection is resolved before comparing:
  # a directory expression counts as correct if it is the literal, or a variable
  # this file defines as exactly that literal.
  # FALSIFYING EDIT: change either `SNAPSHOT_CLAUDE_DIR="$HOME/.claude"` or the
  # inline `$HOME/.claude/pending-lessons-…` in scripts/pr-postmerge-fold.sh to a
  # different directory.
  A24_FOLD_SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/pr-postmerge-fold.sh"
  if [[ -f "$A24_FOLD_SCRIPT" ]]; then
    A24_FOLD_BAD=$(awk '
      !/^[[:space:]]*#/ {
        # Record simple `NAME="value"` definitions so a path built through one
        # can be resolved.
        if (match($0, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="[^"]*"/)) {
          t = substr($0, RSTART, RLENGTH); sub(/^[[:space:]]*/, "", t)
          eq = index(t, "="); nm = substr(t, 1, eq - 1)
          val = substr(t, eq + 2, length(t) - eq - 2)
          def[nm] = val
        }
        keep[NR] = $0
      }
      END {
        for (i in keep) {
          line = keep[i]
          if (line !~ /\/pending-(deviations|lessons)-/) continue
          # The directory expression is everything between the opening quote and
          # the /pending- segment.
          if (!match(line, /"[^"]*\/pending-(deviations|lessons)-/)) continue
          seg = substr(line, RSTART + 1, RLENGTH - 1)
          sub(/\/pending-(deviations|lessons)-.*$/, "", seg)
          # Resolve ONE level of `$VAR` / `${VAR}` at the head of the expression.
          if (match(seg, /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/)) {
            head = substr(seg, RSTART, RLENGTH)
            nm = head; gsub(/[$\{\}]/, "", nm)
            if (nm in def) { rest = substr(seg, RSTART + RLENGTH); seg = def[nm] rest }
          }
          if (seg != "$HOME/.claude") print i ":" seg
        }
      }' "$A24_FOLD_SCRIPT")
    A24_FOLD_TOTAL=$(awk '!/^[[:space:]]*#/ && /\/pending-(deviations|lessons)-/ { n++ } END { print n+0 }' "$A24_FOLD_SCRIPT")
    [[ "$A24_FOLD_TOTAL" -ge 2 ]] \
      || A24_FAILURES+=("(i) scripts/pr-postmerge-fold.sh names only $A24_FOLD_TOTAL snapshot path(s) in code, expected at least 2 (one per half) — the scan is looking at the wrong thing, and a scan that finds nothing reports everything as correct")
    [[ -z "$A24_FOLD_BAD" ]] \
      || A24_FAILURES+=("(i) scripts/pr-postmerge-fold.sh writes snapshot(s) outside \$HOME/.claude at $(printf '%s ' $A24_FOLD_BAD) — the writer and this consumer are no longer on one key space, so every snapshot written to the other directory is stranded and nothing ever reports it")
  fi
  rm -rf "$a24_h8"

  if [[ ${#A24_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: a run for an unrelated PR surfaced both queued snapshots; an empty queue claimed nothing; a project-repo run and a CLOSED-PR run each refused and archived nothing while the identical toolbox/MERGED run DID archive; a symlinked state dir was refused and a symlinked snapshot was never consumed while a valid one still retired; the archived snapshot was byte-identical and gone from the queue; a misspelled MODE exited 2 having written nothing; and a dismissal landed at \$HOME/.claude with the fold on the same key space)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A24_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-45: THE CANONICAL DISMISSAL WRITE — ONE WRITER, AND IT REFUSES WHAT IT
#            CANNOT VERIFY (executed, plus one repo-wide structural leg)
#
# WHY: this is the single highest-privilege operation in the loop. The deviation
# log's contents are the ONLY thing that authorizes the archive pass to retire a
# snapshot, and the lessons log's contents permanently suppress a candidate
# finding. For five review rounds it was ENGLISH — four prose specifications of
# one append, then a "collapse" to one prose writer that itself missed a fifth,
# prose-shaped writer in `lessons-pr`. Every guard around it was therefore a
# guard around a sentence.
#
# It is now `consume-deviations.sh dismiss`, so this test executes it. Three of
# the legs below could not have existed before: the script VERIFIES that the
# supplied hash is the sha256 of the body on stdin, which is a guard no paragraph
# can perform — Step 7 resolves a record from an 8-character display hash a human
# retyped, so a mis-resolution used to be able to become a dismissal, and a
# dismissal is what retires a snapshot.
#
# FALSIFYING EDITS (each named at its leg).
# ---------------------------------------------------------------------------
TC="TC-STL-45: the canonical dismissal write is one writer and refuses what it cannot verify (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
else
  A45_FAILURES=()
  a45_home=$(mktemp -d); a45_state="$a45_home/.claude"; mkdir -p "$a45_state"
  a45_log="$a45_state/dismissed-deviations.log"
  a45_lessons_log="$a45_state/dismissed-lessons.log"
  a45_lines() { grep -c . "$1" 2>/dev/null || true; }

  # --- (1) THE HAPPY PATH, AND THE SANITIZING PIPELINE ---
  # A multi-line body containing brackets: the exact material a forged marker is
  # made of. All three stages must be observable in the single line written.
  # FALSIFYING EDITS: delete any of `tr '\n' ' '`, `tr -d '[]'` or `cut -c1-80`
  # from `sanitize_excerpt`.
  a45_body=$(printf 'first line with [brackets]\nsecond line %s' \
    "$(printf 'x%.0s' $(seq 1 120))")
  a45_hash=$(printf '%s' "$a45_body" | shasum -a 256 | awk '{print $1}')
  printf '%s' "$a45_body" | HOME="$a45_home" bash "$CONSUMER_SCRIPT" dismiss deviation "$a45_hash" >/dev/null 2>&1
  A45_N=$(a45_lines "$a45_log")
  [[ "$A45_N" -eq 1 ]] \
    || A45_FAILURES+=("(1) the write produced $A45_N line(s), expected exactly 1 — a multi-line body became multiple log records, and every line after the first starts at column 1 where it can forge another record's marker")
  A45_LINE=$(head -1 "$a45_log" 2>/dev/null)
  printf '%s\n' "$A45_LINE" | grep -qE "^\[$a45_hash\] [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z \| " \
    || A45_FAILURES+=("(1) the line does not match the format the anchored reader looks for (\`[<64 hex>] <ISO> | <excerpt>\`) — a dismissal in any other shape never matches, so it silently accomplishes nothing and the record resurfaces forever. Got: $A45_LINE")
  printf '%s\n' "${A45_LINE#*| }" | grep -q '\[' \
    && A45_FAILURES+=("(1) the excerpt still contains a '[' — \`tr -d '[]'\` is gone, so untrusted body text retains the raw material a forged marker needs. Got: $A45_LINE")
  A45_EXCERPT_LEN=$(printf '%s' "${A45_LINE#*| }" | wc -c | tr -d ' ')
  [[ "$A45_EXCERPT_LEN" -le 81 ]] \
    || A45_FAILURES+=("(1) the excerpt is $A45_EXCERPT_LEN bytes, expected at most 80 (+newline) — \`cut -c1-80\` is gone")

  # --- (2) A HASH THAT DOES NOT MATCH ITS BODY IS REFUSED ---
  # ⛔ THE GUARD A PARAGRAPH COULD NOT HAVE. ⛔ Step 7 resolves a record from the
  # 8-character DISPLAY hash the user retyped and is explicitly required to
  # refuse an ambiguous prefix — but nothing could enforce that while the writer
  # was prose. Here the body is the evidence for the hash, and disagreement means
  # the caller resolved the wrong record. Retiring the wrong snapshot destroys
  # the only remaining sign that its work was never triaged.
  # FALSIFYING EDIT: delete the `derived != hash_full` check from `cmd_dismiss`.
  A45_BEFORE=$(a45_lines "$a45_log")
  printf 'a completely different body' | HOME="$a45_home" bash "$CONSUMER_SCRIPT" dismiss deviation "$a45_hash" >/dev/null 2>&1
  A45_RC2=$?
  [[ "$A45_RC2" -eq 2 ]] \
    || A45_FAILURES+=("(2) a hash that does not match the body on stdin exited $A45_RC2, expected 2 — a mis-resolved record can become a dismissal, and a dismissal is what retires a snapshot")
  [[ "$(a45_lines "$a45_log")" -eq "$A45_BEFORE" ]] \
    || A45_FAILURES+=("(2) the refused dismissal still appended to the log — a refusal that writes is not a refusal")

  # --- (3) AN EMPTY BODY IS REFUSED — BY THE EMPTY-BODY GUARD, WITH NO SECOND
  #         ROUTE LEFT IN THE FIXTURE ---
  # ⛔ THIS LEG WAS TAUTOLOGICAL, AND THE SHAPE IS THE ONE THIS BRANCH KEEPS
  # REPEATING. ⛔ It used to send the empty body under `$a45_hash` — leg (1)'s
  # digest — so the HASH-MISMATCH guard refused the call whether or not the
  # empty-body guard existed. Measured: deleting the empty-body check from
  # `cmd_dismiss` left this leg GREEN and the whole suite at its old total. The
  # assertion named one mechanism and exercised a different one.
  #
  # The fixture now supplies the sha256 OF THE EMPTY STRING, so `derived` equals
  # `hash_full` and the mismatch guard CANNOT fire — the empty-body guard is the
  # only thing standing. Under the same deletion the script writes a
  # CONTENT-FREE dismissal (`[e3b0c442…] <ts> | `), and the anchored reader
  # matches it happily, so a snapshot gets retired on evidence that is literally
  # nothing. Both halves are asserted: the refusal, and WHICH guard refused.
  # FALSIFYING EDIT: delete the empty-body check from `cmd_dismiss`.
  a45_empty_hash=$(printf '' | shasum -a 256 | awk '{print $1}')
  A45_ERR3=$(printf '' | HOME="$a45_home" bash "$CONSUMER_SCRIPT" dismiss deviation "$a45_empty_hash" 2>&1)
  A45_RC3=$?
  [[ "$A45_RC3" -eq 2 ]] \
    || A45_FAILURES+=("(3) an EMPTY body on stdin exited $A45_RC3, expected 2 — with a matching digest nothing else refuses it, so the write lands as a content-free dismissal that still authorizes retiring a snapshot")
  [[ "$(a45_lines "$a45_log")" -eq "$A45_BEFORE" ]] \
    || A45_FAILURES+=("(3) the empty-body dismissal still appended to the log: $A45_ERR3")
  printf '%s' "$A45_ERR3" | grep -q 'EMPTY body' \
    || A45_FAILURES+=("(3) the refusal did not come from the EMPTY-BODY guard — that guard is what this leg names, and asserting only the exit code let a different guard satisfy it for five rounds. Got: $A45_ERR3")
  printf '%s' "$A45_ERR3" | grep -q 'does not match the sha256' \
    && A45_FAILURES+=("(3) the HASH-MISMATCH guard answered instead — the fixture has regained a second route to the same exit code, which is exactly how this leg became tautological. Got: $A45_ERR3")

  # --- (4) A MALFORMED KEY IS REFUSED ---
  # An 8-character key is the DISPLAY form. Writing it produces a line the
  # anchored `^\[<64 hex>\] ` reader can never match, so the dismissal silently
  # accomplishes nothing — and 32 bits would let one record's dismissal retire a
  # different record that merely shares a prefix.
  # ⛔ TAUTOLOGICAL FOR THE SAME REASON AS LEG (3), AND FIXED DIFFERENTLY. ⛔
  # An 8-character key can never equal a 64-character digest, so the
  # hash-MISMATCH guard refuses this input whether or not `HASH_RE` validation
  # exists — measured: deleting the validation left this leg GREEN. Unlike leg
  # (3) the second route cannot be removed from the fixture, because no body has
  # `deadbeef` for a digest. So the assertion binds to THE MECHANISM'S OWN
  # OUTPUT instead of to the run's end state: the key check names the
  # 64-character requirement, the mismatch guard names the sha256 disagreement,
  # and exactly one of them may speak.
  # FALSIFYING EDIT: delete the `HASH_RE` validation from `cmd_dismiss`.
  A45_ERR4=$(printf 'some body' | HOME="$a45_home" bash "$CONSUMER_SCRIPT" dismiss deviation "deadbeef" 2>&1)
  A45_RC4=$?
  [[ "$A45_RC4" -eq 2 ]] \
    || A45_FAILURES+=("(4) an 8-character display hash was accepted as a key — the line it writes can never be matched by the anchored reader, and a shared prefix retires the wrong snapshot")
  [[ "$(a45_lines "$a45_log")" -eq "$A45_BEFORE" ]] \
    || A45_FAILURES+=("(4) the malformed-key dismissal still appended to the log: $A45_ERR4")
  printf '%s' "$A45_ERR4" | grep -q '64-character sha256 digest' \
    || A45_FAILURES+=("(4) the refusal did not come from the KEY-FORMAT check — that check is what this leg names, and the mismatch guard reaches the same exit code from the same input, so the exit code alone proves nothing. Got: $A45_ERR4")
  printf '%s' "$A45_ERR4" | grep -q 'does not match the sha256' \
    && A45_FAILURES+=("(4) the HASH-MISMATCH guard answered instead of the key-format check — \`HASH_RE\` validation is gone, and a caller passing a display hash now depends on a guard that only fires when the body disagrees. Got: $A45_ERR4")

  # --- (5) THE `lesson` KIND TARGETS THE OTHER LOG, AND ONLY THAT ONE ---
  # FALSIFYING EDIT: point both KIND arms at the same file.
  a45_lbody="A LESSONS finding to dismiss"
  consumer_dismiss "$a45_home" lesson "$a45_lbody" >/dev/null
  [[ "$(a45_lines "$a45_lessons_log")" -eq 1 ]] \
    || A45_FAILURES+=("(5) \`dismiss lesson\` did not write exactly one line to dismissed-lessons.log")
  [[ "$(a45_lines "$a45_log")" -eq "$A45_BEFORE" ]] \
    || A45_FAILURES+=("(5) \`dismiss lesson\` also wrote to dismissed-deviations.log — the two destinations have been merged, so a lessons decision would authorize retiring a deviation snapshot")

  # --- (6) AN UNKNOWN KIND IS REFUSED — there is no third destination ---
  # FALSIFYING EDIT: add a `*)` arm that picks a default log.
  printf 'x' | HOME="$a45_home" bash "$CONSUMER_SCRIPT" dismiss findings "$(printf 'x' | shasum -a 256 | awk '{print $1}')" >/dev/null 2>&1
  [[ $? -eq 2 ]] \
    || A45_FAILURES+=("(6) an unknown KIND was accepted — a third destination is a third format and a third reader, i.e. this whole failure class one file over")

  # --- (7) A SYMLINKED LOG IS NOT WRITTEN THROUGH ---
  # ⛔ THE WRITE SIDE'S GUARD, AND THE ASYMMETRY MADE IT WORSE THAN A PLAIN
  # MISSING GUARD: the READER refuses to read a symlinked dismissed log, so an
  # append through a symlink went somewhere arbitrary and silently, with no
  # compensating failure anywhere, and the queue simply never archived.
  # (This comment used to call it "the ONE unguarded path in the whole loop".
  # It was not: `cmd_archive` — the path that performs the `mv` — had no
  # per-file `-L` test either, and on byte-identical state `surface` refused
  # while `archive` archived. TC-STL-48 legs (4) and (5) pin that half.)
  # FALSIFYING EDIT: delete the `-L` guard from `cmd_dismiss`.
  a45_h7=$(mktemp -d); a45_s7="$a45_h7/.claude"; mkdir -p "$a45_s7"
  : > "$a45_h7/outside-log"
  ln -s "$a45_h7/outside-log" "$a45_s7/dismissed-deviations.log"
  consumer_dismiss "$a45_h7" deviation "SYMLINKED LOG body" >/dev/null
  [[ ! -s "$a45_h7/outside-log" ]] \
    || A45_FAILURES+=("(7) the dismissal was appended THROUGH a symlinked log to $a45_h7/outside-log — a path-traversal write on the single operation that authorizes destroying queue state")
  rm -rf "$a45_h7"

  # --- (8) THERE IS EXACTLY ONE WRITER, REPO-WIDE, IN ANY SHAPE ---
  # ⛔ THIS IS THE ASSERTION ISSUE #140 EXISTS TO MAKE POSSIBLE. ⛔ Its ancestor
  # (old 8d-ii/8e) had to scan ONE markdown file for prose that might be a
  # writer, using needles that could only see the shapes someone had already
  # thought of — and it missed a writer for exactly that reason. Now a writer has
  # to be CODE, so the question becomes "does any file other than the one script
  # write to either log", which is answerable with certainty.
  #
  # `scripts/test-*.sh` is excluded, and the exclusion is honest rather than
  # convenient: a test that builds a dismissed-log FIXTURE is not a production
  # writer, and several legs above and in TC-STL-27/28 deliberately hand-build
  # the OLD unsanitized line to prove the hazard is still reachable. Forbidding
  # that would delete the vacuity guards.
  # FALSIFYING EDITS: add `printf … >> "$HOME/.claude/dismissed-lessons.log"` to
  # any command, skill, hook or non-test script; or alias the path into a
  # variable and append through the alias (the alias pass below follows it).
  A45_REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  # `--cached --others --exclude-standard`, not a bare `git ls-files`: a bare
  # listing shows only TRACKED files, so a brand-new writer added in the working
  # tree — the exact thing a review is looking at — would be invisible to the
  # check meant to catch it. (Verified: with a bare listing the scan could not
  # even see scripts/consume-deviations.sh before its first commit, and the
  # vacuity guard below is what caught that.)
  A45_WRITERS=$(cd "$A45_REPO_ROOT" && git ls-files --cached --others --exclude-standard 2>/dev/null \
    | grep -Ev '^scripts/test-' \
    | while IFS= read -r _f; do
        [[ -f "$_f" ]] || continue
        awk -v F="$_f" '
          !/^[[:space:]]*#/ {
            low = tolower($0)
            # ALIAS PASS. Any line that NAMES a dismissed log and also performs an
            # assignment creates a variable the real write may go through without
            # ever saying "dismissed" — `log="$DISMISSED_FILE"` inside a case arm
            # is exactly that shape, and it is the shape the production writer
            # uses. So every `name=` on such a line is registered, not just one
            # anchored at the start of it.
            if (low ~ /dismissed[-_ ]?(deviations|lessons)|dismissed_(log|file|lessons_log)/) {
              rest = low
              while (match(rest, /[a-z_][a-z0-9_]*=/)) {
                nm = substr(rest, RSTART, RLENGTH - 1)
                alias[nm] = 1
                rest = substr(rest, RSTART + RLENGTH)
              }
            }
            line[NR] = low
          }
          END {
            targets = "dismissed[-_ ]?(deviations|lessons)|dismissed_(log|file|lessons_log)"
            for (a in alias) targets = targets "|" a
            # ⛔ THE REDIRECT MUST LOOK LIKE A REDIRECT, NOT LIKE PROSE. ⛔ A bare
            # `>` matched markdown placeholders such as `<full digest>` followed
            # later in the same sentence by the words "dismissed-deviations.log",
            # and every one of those false hits would have to be silenced by hand
            # — which is how a detector stops being trusted. Requiring the
            # operator to be followed by a quote, a `$`, a `/` or a `~` keeps
            # every real redirect and drops the prose.
            wr1 = ">>?[[:space:]]*[\"'"'"'$/~][^|;&]*(" targets ")"
            wr2 = "(tee([[:space:]]+-a)?|sed[^|]*-i|truncate)[[:space:]]+[^|;&]*(" targets ")"
            for (i in line)
              if (line[i] ~ wr1 || line[i] ~ wr2) print F ":" i
          }' "$_f"
      done | sort -u)
  A45_BAD_WRITERS=$(printf '%s\n' "$A45_WRITERS" | grep -v '^$' | grep -v '^scripts/consume-deviations\.sh:' || true)
  [[ -z "$A45_BAD_WRITERS" ]] \
    || A45_FAILURES+=("(8) a dismissed log is written outside scripts/consume-deviations.sh at: $(printf '%s ' $A45_BAD_WRITERS) — a second writer of the file that authorizes retiring a snapshot is the exact defect the one-writer collapse exists to prevent, and it survived three review rounds when the check could only see prose")
  # VACUITY GUARD: the scan is meaningless if it finds no writer at all.
  A45_GOOD_WRITERS=$(printf '%s\n' "$A45_WRITERS" | grep -c '^scripts/consume-deviations\.sh:' || true)
  [[ "$A45_GOOD_WRITERS" -ge 1 ]] \
    || A45_FAILURES+=("(8) the repo-wide scan found NO writer of either dismissed log anywhere, including in consume-deviations.sh — the detector is broken, and a broken detector reports every file as clean")

  # --- (9) EXACTLY TWO DESTINATIONS EXIST, REPO-WIDE ---
  # (8) binds every mention of the two KNOWN logs; a third log invented under a
  # new name is not a mention of either, so (8) is blind to it while the
  # canonical section keeps asserting there is no third destination.
  # FALSIFYING EDIT: name a `dismissed-anything-else.log` anywhere.
  A45_DESTS=$(cd "$A45_REPO_ROOT" && git ls-files --cached --others --exclude-standard 2>/dev/null | while IFS= read -r _f; do
      [[ -f "$_f" ]] && awk '!/^[[:space:]]*#/' "$_f"
    done | grep -oEi 'dismissed-[a-z]+\.log' | tr 'A-Z' 'a-z' | sort -u | tr '\n' ' ')
  A45_DESTS=${A45_DESTS% }
  [[ "$A45_DESTS" == "dismissed-deviations.log dismissed-lessons.log" ]] \
    || A45_FAILURES+=("(9) the dismissed-log destinations named in the repo are '$A45_DESTS', not exactly 'dismissed-deviations.log dismissed-lessons.log' — a third log is a third format nothing reads")

  rm -rf "$a45_home"
  if [[ ${#A45_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real writer: a bracketed multi-line body produced ONE anchored, bracket-stripped, 80-char line; a mismatched hash, an empty body, an 8-char key and an unknown kind were each refused with exit 2 and no append; the lesson kind hit only the lessons log; a symlinked log was not written through; and repo-wide, scripts/consume-deviations.sh is the only writer of either log with exactly 2 destinations named)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A45_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-46: THE LESSONS HALF, EXECUTED — the anchor, the dedupe, and the only
#            branch that deletes anything
#
# WHY: the two halves of this machinery have already diverged TWICE, each time
# because a fix landed on one side only — first the archive semantics, then the
# excerpt sanitization. The reason is structural: the deviation half was bash a
# harness could run, and the lessons half's anchored lookup was pinned by exactly
# one static assertion (old 8b) that required a particular `grep -qE` spelling to
# appear inside a line range. Any rewording of that lookup silently un-pinned it.
#
# Both halves are now in one script, and this test runs the lessons half through
# the SAME scenario TC-STL-27 runs the deviation half through — so a fix that
# lands on one side and not the other fails here rather than being found by the
# next review round.
#
# THE DELETING BRANCH IS THE OTHER REASON THIS EXISTS. `lessons` is the only
# subcommand in the whole loop that REMOVES files, and it is allowed to only when
# every record parsed cleanly AND every one is already dismissed. A malformed
# line means a finding we could not read, and deleting then loses it silently.
# ---------------------------------------------------------------------------
TC="TC-STL-46: the lessons half anchors its lookup, dedupes, and deletes only a genuinely drained queue (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the lessons half parses JSONL with jq, so this behavioural test cannot run"
else
  A46_FAILURES=()
  a46_lessons() { HOME="$1" bash "$CONSUMER_SCRIPT" lessons baselito ai-engineering 4242 MERGED "$1" 2>&1; }
  a46_seed() {  # <state> <file suffix> <finding>
    printf '{"finding":"%s","verdict":"fixed","origin":"automated-review"}\n' "$3" \
      > "$1/pending-lessons-$2.jsonl"
  }

  # --- (1) DEDUPE ACROSS SNAPSHOTS, AND DISMISSED FINDINGS ARE FILTERED ---
  # The fold appends with `>>` across reruns and automated-review/Codex contribute
  # overlapping findings, so the same body legitimately appears several times.
  # FALSIFYING EDITS: delete the per-run `set_has` dedupe (the duplicate becomes
  # a second candidate); delete the `hash_logged_in … DISMISSED_LESSONS_LOG`
  # lookup (the dismissed finding is re-proposed forever).
  a46_h1=$(mktemp -d); a46_s1="$a46_h1/.claude"; mkdir -p "$a46_s1"
  a46_dup="A finding that appears in two snapshots"
  a46_gone="A finding that was already dismissed"
  a46_new="A genuinely new finding"
  a46_seed "$a46_s1" 101 "$a46_dup"
  a46_seed "$a46_s1" 102 "$a46_dup"
  printf '{"finding":"%s","verdict":"fixed","origin":"codex"}\n' "$a46_gone" >> "$a46_s1/pending-lessons-102.jsonl"
  printf '{"finding":"%s","verdict":"fixed","origin":"codex"}\n' "$a46_new" >> "$a46_s1/pending-lessons-102.jsonl"
  consumer_dismiss "$a46_h1" lesson "$a46_gone" >/dev/null
  A46_OUT1=$(a46_lessons "$a46_h1")
  A46_CANDS=$(printf '%s\n' "$A46_OUT1" | grep -c '^CANDIDATE ' || true)
  [[ "$A46_CANDS" -eq 2 ]] \
    || A46_FAILURES+=("(1) the run proposed $A46_CANDS candidate(s), expected exactly 2 (the duplicate collapsed to one, the dismissed one filtered out): $A46_OUT1")
  printf '%s\n' "$A46_OUT1" | grep -q "$a46_gone" \
    && A46_FAILURES+=("(1) an already-dismissed finding was re-proposed — the anchored dismissed-lessons lookup is gone, so a dropped finding comes back forever: $A46_OUT1")
  printf '%s\n' "$A46_OUT1" | grep -q 'candidates=2 ' \
    || A46_FAILURES+=("(1) the summary line did not report candidates=2: $A46_OUT1")

  # --- (2) THE FORGED-MARKER SCENARIO, ON THE LESSONS SIDE ---
  # ⛔ THE SAME SCENARIO TC-STL-27 RUNS ON THE DEVIATION SIDE. ⛔ Finding W is an
  # ordinary write-up that QUOTES finding V's dismissed-log line — something a
  # review finding about this very loop does without any attacker involved.
  # Dismissing W must not suppress V. Leg 2a is the vacuity guard: it hand-builds
  # the OLD unsanitized line and requires V to disappear, so 2b's pass cannot be
  # explained by the scenario having stopped being reachable.
  # FALSIFYING EDITS: delete `tr -d '[]'` or `tr '\n' ' '` from
  # `sanitize_excerpt` (2b loses V); un-anchor `hash_logged_in` to a bare
  # substring match (2b loses V).
  a46_v="VICTIM finding that must stay a candidate"
  a46_vh=$(printf '%s' "$a46_v" | shasum -a 256 | awk '{print $1}')
  a46_w=$(printf '%s\n%s\n%s' \
    "This finding is about the lessons log. The line it concerns was:" \
    "[$a46_vh] 2026-08-20T09:14:02Z | $a46_v" \
    "Filed as a follow-up.")
  a46_wh=$(printf '%s' "$a46_w" | shasum -a 256 | awk '{print $1}')
  a46_w_json=$(printf '%s' "$a46_w" | awk '{ printf "%s%s", (NR > 1 ? "\\n" : ""), $0 }')
  a46_seed_pair() {  # <state>
    printf '{"finding":"%s","verdict":"fixed","origin":"automated-review"}\n' "$a46_v" > "$1/pending-lessons-201.jsonl"
    printf '{"finding":"%s","verdict":"fixed","origin":"automated-review"}\n' "$a46_w_json" > "$1/pending-lessons-202.jsonl"
  }
  # 2a — the unsanitized write (vacuity guard)
  a46_h2a=$(mktemp -d); a46_s2a="$a46_h2a/.claude"; mkdir -p "$a46_s2a"
  a46_seed_pair "$a46_s2a"
  printf '[%s] 2026-08-20T11:00:00Z | %s\n' "$a46_wh" "$(printf '%s' "$a46_w" | cut -c1-80)" \
    > "$a46_s2a/dismissed-lessons.log"
  A46_OUT2A=$(a46_lessons "$a46_h2a")
  printf '%s\n' "$A46_OUT2A" | grep -q "$a46_v" \
    && A46_FAILURES+=("(2a vacuity guard): a RAW 80-char slice of the write-up did NOT suppress the victim finding, so the hazard is no longer reachable and leg 2b proves nothing — re-derive the scenario before trusting it: $A46_OUT2A")
  rm -rf "$a46_h2a"
  # 2b — the production canonical write
  a46_h2b=$(mktemp -d); a46_s2b="$a46_h2b/.claude"; mkdir -p "$a46_s2b"
  a46_seed_pair "$a46_s2b"
  consumer_dismiss "$a46_h2b" lesson "$a46_w" >/dev/null
  A46_OUT2B=$(a46_lessons "$a46_h2b")
  printf '%s\n' "$A46_OUT2B" | grep -q "$a46_v" \
    || A46_FAILURES+=("(2b) dismissing a write-up that merely QUOTES another finding's log line suppressed that finding — permanently, since a lessons dismissal never expires. This is the deviation half's forged-marker defect on the lessons side: $A46_OUT2B")
  rm -rf "$a46_h2b"

  # --- (2c) THE ANCHOR ITSELF, with a fixture the truncation cannot save ---
  # ⛔ WHY LEG 2b DOES NOT PIN THE ANCHOR, MEASURED. ⛔ Un-anchoring
  # `hash_logged_in` to a bare `grep -qF "$hash"` left BOTH leg 2b and TC-STL-27
  # green. The reason is the fixture, not the guard: 2b's write-up says 67
  # characters of preamble before it quotes the marker, so `cut -c1-80` keeps
  # only ~13 characters of the victim's 64-character digest and even an
  # unanchored FIXED-STRING search cannot match it. The truncation was doing the
  # defending, and an assertion that passes because a DIFFERENT stage held is an
  # assertion about that other stage.
  #
  # This leg moves the quoted marker to the START of the write-up, so the whole
  # 64-character digest survives into the excerpt. The excerpt still cannot reach
  # column 1 — `[<write-up hash>] <ISO> | ` precedes it — so the anchored reader
  # is correct and the victim survives; an unanchored one matches the digest
  # mid-line and suppresses a finding nobody decided, permanently.
  #
  # `hash_logged_in` is ONE function shared by the deviation and lessons halves
  # now, which is why a single behavioural leg pins the anchor for both. While
  # the two halves were separate implementations, this could only be asserted
  # statically, per half, by requiring a particular `grep` spelling to appear
  # inside a line range — and any rewording silently un-pinned it.
  # FALSIFYING EDIT: rewrite `hash_logged_in` as `grep -qF "$hash" "$file"`, or
  # merely delete the leading `^` from its pattern.
  a46_h2c=$(mktemp -d); a46_s2c="$a46_h2c/.claude"; mkdir -p "$a46_s2c"
  a46_w2=$(printf '%s\n%s' \
    "[$a46_vh] 2026-08-20T09:14:02Z | $a46_v" \
    "Quoted above: this finding is about the lessons log.")
  a46_w2_json=$(printf '%s' "$a46_w2" | awk '{ printf "%s%s", (NR > 1 ? "\\n" : ""), $0 }')
  printf '{"finding":"%s","verdict":"fixed","origin":"automated-review"}\n' "$a46_v" > "$a46_s2c/pending-lessons-203.jsonl"
  printf '{"finding":"%s","verdict":"fixed","origin":"automated-review"}\n' "$a46_w2_json" > "$a46_s2c/pending-lessons-204.jsonl"
  consumer_dismiss "$a46_h2c" lesson "$a46_w2" >/dev/null
  # PRECONDITION: the victim's FULL digest must really have survived into the
  # dismissed-log excerpt, or this leg silently degrades into a repeat of 2b.
  A46_LEAKED=$(grep -c "$a46_vh" "$a46_s2c/dismissed-lessons.log" 2>/dev/null || true)
  [[ "$A46_LEAKED" -ge 1 ]] \
    || A46_FAILURES+=("(2c precondition) the victim's full digest did NOT survive into the dismissed-log excerpt, so an unanchored lookup could not match it either and this leg tests nothing — re-derive the fixture")
  A46_OUT2C=$(a46_lessons "$a46_h2c")
  printf '%s\n' "$A46_OUT2C" | grep -q "$a46_v" \
    || A46_FAILURES+=("(2c) a finding whose digest merely APPEARS mid-line in another record's excerpt was treated as dismissed — the lookup is matching the hash as a bare substring instead of anchoring it to its own column, so one record's body permanently suppresses another's: $A46_OUT2C")
  rm -rf "$a46_h2c"

  # --- (3) THE DELETING BRANCH: only a genuinely drained queue is removed ---
  # FALSIFYING EDIT: drop the `parse_failures -eq 0` half of the delete
  # condition in `cmd_lessons`.
  a46_h3=$(mktemp -d); a46_s3="$a46_h3/.claude"; mkdir -p "$a46_s3"
  a46_seed "$a46_s3" 301 "$a46_new"
  consumer_dismiss "$a46_h3" lesson "$a46_new" >/dev/null
  A46_OUT3=$(a46_lessons "$a46_h3")
  [[ ! -e "$a46_s3/pending-lessons-301.jsonl" ]] \
    || A46_FAILURES+=("(3) a queue whose every record is dismissed and whose every record parsed was NOT removed — every future merge re-reads and re-filters the same dead records: $A46_OUT3")
  printf '%s\n' "$A46_OUT3" | grep -q 'deleted=yes' \
    || A46_FAILURES+=("(3) the summary line did not report deleted=yes: $A46_OUT3")
  rm -rf "$a46_h3"

  # --- (4) A MALFORMED RECORD PRESERVES THE WHOLE QUEUE ---
  # A line that fails to parse may hold a finding we simply cannot read yet.
  # Deleting then drops it permanently and the loss is silent — which is the
  # failure this entire loop exists to remove.
  # FALSIFYING EDIT: as (3), or make a parse failure `continue` without counting.
  a46_h4=$(mktemp -d); a46_s4="$a46_h4/.claude"; mkdir -p "$a46_s4"
  a46_seed "$a46_s4" 401 "$a46_new"
  printf 'this line is not json at all\n' >> "$a46_s4/pending-lessons-401.jsonl"
  consumer_dismiss "$a46_h4" lesson "$a46_new" >/dev/null
  A46_OUT4=$(a46_lessons "$a46_h4")
  [[ -e "$a46_s4/pending-lessons-401.jsonl" ]] \
    || A46_FAILURES+=("(4) a snapshot holding an UNPARSEABLE record was deleted once its readable records were dismissed — a finding nobody could read was destroyed silently: $A46_OUT4")
  printf '%s\n' "$A46_OUT4" | grep -q 'failed to parse' \
    || A46_FAILURES+=("(4) nothing in the output says a record failed to parse — the user is told the queue holds nothing actionable when it holds a record we could not read: $A46_OUT4")
  printf '%s\n' "$A46_OUT4" | grep -q 'deleted=no' \
    || A46_FAILURES+=("(4) the summary line did not report deleted=no: $A46_OUT4")
  rm -rf "$a46_h4"

  # --- (5) THE REPO GATE, on the half that DELETES ---
  # The lessons half is the one that removes files, so a missing repo gate here
  # does not merely read another repo's queue — it destroys it.
  # FALSIFYING EDIT: delete the `is_toolbox_repo` check from `cmd_lessons`.
  A46_OUT5=$(HOME="$a46_h1" bash "$CONSUMER_SCRIPT" lessons someorg someproject 1 MERGED "$a46_h1" 2>&1)
  printf '%s\n' "$A46_OUT5" | grep -q 'refused=not-toolbox-repo' \
    || A46_FAILURES+=("(5) a run from someorg/someproject was not refused: $A46_OUT5")
  [[ -e "$a46_s1/pending-lessons-101.jsonl" ]] \
    || A46_FAILURES+=("(5) a PROJECT-repo run DELETED a toolbox lessons snapshot: $A46_OUT5")
  rm -rf "$a46_h1"

  # --- (6) A RECORD-LESS SNAPSHOT IS NOT A DRAINED ONE ---
  # ⛔ THE ARCHIVE PASS'S OWN LESSON, ON THE LESSONS HALF. ⛔ `dev_archive_pass`
  # refuses to retire a snapshot that produced ZERO decisions, because a file
  # holding no records satisfies "nothing outstanding" VACUOUSLY — and every
  # fail-open finding in that pass's history came from inferring completion from
  # an absence rather than counting. The per-file lessons delete carries the same
  # `records > 0` term, and this leg is what pins it.
  #
  # ADDED WITH THE PER-FILE DELETE, AND IT WOULD HAVE BEEN RED BEFORE IT: at
  # 906a6c3 the delete was run-wide and keyed only on
  # `candidates == 0 && parse_failures == 0`, both of which a 0-byte file
  # satisfies, so the empty snapshot was REMOVED. The leg is recorded here rather
  # than in the round-2 red block because it is the inverse-direction control for
  # a term that block does not otherwise reach — no fixture in it holds a
  # record-less lessons snapshot.
  # FALSIFYING EDIT: drop the `_f_records -gt 0` term from the per-file delete
  # condition in `cmd_lessons`.
  a46_h6=$(mktemp -d); a46_s6="$a46_h6/.claude"; mkdir -p "$a46_s6"
  : > "$a46_s6/pending-lessons-601.jsonl"
  A46_OUT6=$(a46_lessons "$a46_h6")
  [[ -e "$a46_s6/pending-lessons-601.jsonl" ]] \
    || A46_FAILURES+=("(6) a RECORD-LESS snapshot was deleted as though it were drained — a file that yielded no records is evidence of nothing, and the deviation half refuses the identical shape for the identical reason: $A46_OUT6")
  printf '%s\n' "$A46_OUT6" | grep -q 'deleted=no' \
    || A46_FAILURES+=("(6) the summary reported a deletion on a run whose only snapshot held no records at all: $A46_OUT6")
  rm -rf "$a46_h6"

  if [[ ${#A46_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: two snapshots holding a duplicate plus a dismissed finding yielded exactly 2 candidates; a write-up quoting another finding's log line suppressed it under a raw slice but NOT through the production write; a fully-dismissed clean queue was removed; a queue holding an unparseable record was preserved and reported; a record-less snapshot was not mistaken for a drained one; and a project-repo run deleted nothing)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A46_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-47: THE SCRIPT/AGENT BOUNDARY — commands/review-pr.md CALLS the
#            consumer and does not restate it, and the archive rule has ONE
#            implementation reached by BOTH call sites
#
# WHY THE SECOND HALF MATTERS MOST. The archive is reachable by two routes:
# Step 0.5's post-merge consumption and Step 7's cleanup after a triage reply.
# Until issue #140 the first was bash a harness could execute and the second was
# ENGLISH an agent followed — and they drifted exactly as that asymmetry
# predicts. The coded half required `_decided > 0`; the prose half said only "if
# EVERY record in it has been DECIDED", which is VACUOUSLY TRUE of a file with no
# records. So after any unrelated decision, a 0-byte snapshot satisfied the
# instruction, the `mv` created a file in consumed-deviations/, and that
# directory is what scripts/selfimprovement-backlog.sh reads as "a triage has
# completed on this machine" — permanently retiring the never-completed warning
# with nobody having decided anything.
#
# The old test (9e) could only assert that the ENGLISH still contained the words
# "at least one", and it shipped INERT for a round because a section-wide scan
# was satisfied by the justification paragraph rather than by the instruction.
# Leg (1) below runs that exact scenario through the `archive` subcommand
# instead.
#
# THE FIRST HALF IS THE ANTI-REGRESSION GUARD. Nothing stops a future edit from
# pasting the algorithm back into the markdown "for clarity" and leaving the
# script behind — which recreates the two-implementations problem in one commit.
# So the `.md` is required to CALL and required NOT to restate.
# ---------------------------------------------------------------------------
TC="TC-STL-47: the .md calls the consumer instead of restating it, and both archive call sites are one implementation (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" || ! -f "$CONSUMER_MD" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh or commands/review-pr.md"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the archive pass parses JSONL with jq, so this behavioural test cannot run"
else
  A47_FAILURES=()

  # --- (1) THE (9e) DEFECT, NOW EXECUTED: a record-less snapshot archives
  #         NOTHING even after an unrelated decision was recorded ---
  # FALSIFYING EDIT: drop the `_decided -gt 0` clause from the completeness gate
  # in `dev_archive_pass`.
  a47_h1=$(mktemp -d); a47_s1="$a47_h1/.claude"; mkdir -p "$a47_s1"
  : > "$a47_s1/pending-deviations-901.log"
  consumer_dismiss "$a47_h1" deviation "An unrelated decision from some other snapshot" >/dev/null
  A47_OUT1=$(HOME="$a47_h1" bash "$CONSUMER_SCRIPT" archive baselito ai-engineering 2>&1)
  [[ "$(consumer_archived "$a47_s1")" -eq 0 ]] \
    || A47_FAILURES+=("(1) the \`archive\` call site retired a RECORD-LESS snapshot after an unrelated dismissal — that single file flips \`dir_has_file\` in scripts/selfimprovement-backlog.sh and permanently silences the never-completed warning with nobody having decided anything: $A47_OUT1")
  [[ "$(consumer_queued "$a47_s1")" -eq 1 ]] \
    || A47_FAILURES+=("(1) the record-less snapshot left the queue: $A47_OUT1")
  rm -rf "$a47_h1"

  # --- (2) POSITIVE CONTROL: the `archive` call site DOES retire a genuinely
  #         fully-decided snapshot ---
  # Without this, leg (1) is satisfied by an `archive` subcommand that never
  # archives anything — the fail-closed default bought by breaking the feature.
  # FALSIFYING EDIT: delete the completeness gate entirely.
  a47_h2=$(mktemp -d); a47_s2="$a47_h2/.claude"; mkdir -p "$a47_s2"
  a47_body="A REAL decided record reached through the Step 7 cleanup route"
  printf '{"ts":"2026-01-01T00:00:00Z","phase":"Implementation","body":"%s"}\n' "$a47_body" \
    > "$a47_s2/pending-deviations-902.log"
  consumer_dismiss "$a47_h2" deviation "$a47_body" >/dev/null
  A47_OUT2=$(HOME="$a47_h2" bash "$CONSUMER_SCRIPT" archive baselito ai-engineering 2>&1)
  [[ "$(consumer_archived "$a47_s2")" -eq 1 ]] \
    || A47_FAILURES+=("(2 positive control) the \`archive\` call site did NOT retire a fully-decided snapshot — leg (1) would then pass against a cleanup route that can never drain the queue: $A47_OUT2")

  # --- (3) THE TWO CALL SITES AGREE ON THE SAME FIXTURE ---
  # `surface` runs the archive pass too. Given the identical state, both routes
  # must reach the identical outcome — that is what "one implementation" means,
  # and it is the property the prose restatement could not have.
  # FALSIFYING EDIT: give `cmd_archive` its own completeness logic instead of
  # calling `dev_archive_pass`.
  a47_h3=$(mktemp -d); a47_s3="$a47_h3/.claude"; mkdir -p "$a47_s3"
  : > "$a47_s3/pending-deviations-901.log"
  printf '{"ts":"2026-01-01T00:00:00Z","phase":"Implementation","body":"%s"}\n' "$a47_body" \
    > "$a47_s3/pending-deviations-902.log"
  consumer_dismiss "$a47_h3" deviation "$a47_body" >/dev/null
  consumer_run "$a47_h3" attended >/dev/null 2>&1
  A47_SURF_ARCH=$(consumer_archived "$a47_s3"); A47_SURF_QUEUE=$(consumer_queued "$a47_s3")
  A47_ARCH_ARCH=$(consumer_archived "$a47_s2"); A47_ARCH_QUEUE=$(consumer_queued "$a47_s2")
  # $a47_s2 holds only the decided snapshot; $a47_s3 holds that PLUS the empty
  # one, so the comparable quantity is what each route did to the decided file.
  [[ "$A47_SURF_ARCH" -eq "$A47_ARCH_ARCH" ]] \
    || A47_FAILURES+=("(3) \`surface\` archived $A47_SURF_ARCH and \`archive\` archived $A47_ARCH_ARCH from equivalent fixtures — the two call sites are no longer one implementation, which is precisely the drift that let a prose restatement be weaker than the code")
  [[ "$A47_SURF_QUEUE" -eq 1 ]] \
    || A47_FAILURES+=("(3) \`surface\` left $A47_SURF_QUEUE queued, expected 1 (the record-less snapshot)")
  rm -rf "$a47_h2" "$a47_h3"

  # --- (4) THE .md CALLS ALL THREE ENTRY POINTS, IN CODE ---
  # FALSIFYING EDIT: comment out or delete any of the three invocations.
  # ⛔ ONE REGEX PER SUBCOMMAND, WITH NO SHARED ALTERNATIVE. ⛔ The first version
  # of this loop appended `|dismiss deviation` to EVERY subcommand's pattern, so
  # the `dismiss` call satisfied the `surface` check too: deleting the surface
  # invocation entirely left this leg GREEN. Measured, not theorised — the
  # mutation run that produced this comment reported TC-STL-8 RED and TC-STL-47
  # green on that exact edit. An alternation shared across N checks is N-1
  # assertions that cannot fail.
  for _sub in surface lessons archive; do
    A47_CALL=$(code_re_lines_in "$CONSUMER_MD" "consume-deviations\\.sh\"? $_sub|CONSUME_SCRIPT\"? $_sub" | grep -c . || true)
    [[ "$A47_CALL" -ge 1 ]] \
      || A47_FAILURES+=("(4) commands/review-pr.md never invokes \`consume-deviations.sh $_sub\` in code — that half of the loop is unreachable from the command that is supposed to drive it")
  done
  A47_DISMISS_CALL=$(code_re_lines_in "$CONSUMER_MD" 'dismiss (deviation|lesson)' | grep -c . || true)
  [[ "$A47_DISMISS_CALL" -ge 1 ]] \
    || A47_FAILURES+=("(4) commands/review-pr.md never invokes the canonical dismissal write in code — Step 7 would record decisions nowhere")

  # --- (5) THE .md DOES NOT RESTATE THE ALGORITHM ---
  # ⛔ THE ANTI-REGRESSION GUARD. ⛔ Pasting the consumer back into the markdown
  # "for clarity" recreates the two-implementations problem in a single commit,
  # and the weaker copy is always the prose one because nothing executes it.
  # Three constructs are forbidden outright, and each is the load-bearing part of
  # a pass rather than a mention of one: the archive `mv`, the reprint-pointer
  # append, and the completeness accounting.
  # FALSIFYING EDIT: paste any of `mv "$_snap" "$_dest"`,
  # `>> "$SURFACED_FILE"`, or `_decided`/`_outstanding` back into review-pr.md.
  A47_RESTATE=""
  for _needle_desc in \
      'mv "\$_snap"|the archive move' \
      '>> "\$SURFACED_FILE"|the reprint-pointer append' \
      '_outstanding=\$\(\(|the archive-completeness accounting'; do
    _n=${_needle_desc%%|*}; _d=${_needle_desc#*|}
    _hit=$(code_re_lines_in "$CONSUMER_MD" "$_n" | grep -c . || true)
    [[ "$_hit" -eq 0 ]] || A47_RESTATE="$A47_RESTATE $_d"
  done
  [[ -z "$A47_RESTATE" ]] \
    || A47_FAILURES+=("(5) commands/review-pr.md has re-inlined$A47_RESTATE — the algorithm now exists in two places, and the copy in the .md is the one nothing executes, which is the exact asymmetry issue #140 removed")

  if [[ ${#A47_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: the \`archive\` call site refused a record-less snapshot after an unrelated dismissal, still retired a genuinely decided one, and agreed with \`surface\` on an equivalent fixture; and commands/review-pr.md invokes surface/lessons/archive/dismiss in code while restating none of the algorithm)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A47_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-48: THE ARCHIVE PASS'S OWN GUARDS — the three that authorize the `mv`
#            and that the suite could not see
#
# WHY THIS EXISTS. `dev_archive_pass` is the only code in the loop that DESTROYS
# queue state: an `mv` out of ~/.claude retires a record, and a retired record
# is one nobody will ever triage. Three of the guards standing in front of it
# were provably unpinned — each was removed from the script, the whole suite was
# re-run, and it stayed at its previous total with every test passing:
#
#   (A) the `.phase` validation — deleted, suite green;
#   (B) the empty-body guard — flipped from fail-closed to `continue`, suite
#       green, and the mutated run `mv`'d a snapshot holding an undecided
#       record;
#   (C) the symlink precondition on the `archive` ENTRY POINT — `surface` had
#       it, `archive` did not, and on byte-identical state `surface` refused
#       while `archive` archived. Deleting it again, suite green.
#
# Every leg below therefore asserts a guard that a mutation demonstrably
# survives without it. The legs marked CONTROL are green both ways by design and
# exist so the others cannot be satisfied by an `archive` that simply never
# archives anything.
#
# Driven through the `archive` SUBCOMMAND (Step 7's cleanup route) rather than
# through `surface`, because that is the entry point where the pass runs with
# nothing else in front of it — a surface run classifies bad records on its own
# account first, which can mask whether the archive pass would have held them.
# ---------------------------------------------------------------------------
TC="TC-STL-48: the archive pass's record validation and symlink precondition hold the mv (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the archive pass parses JSONL with jq, so this behavioural test cannot run"
else
  A48_FAILURES=()

  # Build a state dir holding ONE snapshot plus a dismissal for each body named.
  # Returns the HOME. The dismissal goes through the canonical write, so the log
  # line is one production actually produces rather than a hand-built fixture.
  a48_make() {  # a48_make <snapshot-file-contents> <body-to-dismiss>...
    local h st; h=$(mktemp -d); st="$h/.claude"; mkdir -p "$st"
    printf '%s' "$1" > "$st/pending-deviations-4848.log"
    shift
    local b
    for b in "$@"; do consumer_dismiss "$h" deviation "$b" >/dev/null 2>&1; done
    printf '%s' "$h"
  }
  a48_archive() { HOME="$1" bash "$CONSUMER_SCRIPT" archive baselito ai-engineering 2>&1; }

  # --- (1) A RECORD WITH NO `.phase` BLOCKS ARCHIVAL ---
  # ⛔ THE TWO PASSES MUST AGREE ON WHAT A VALID RECORD IS. ⛔ The surface pass
  # requires BOTH `.body` and `.phase`, so `{"ts":…,"body":"x"}` is a record it
  # REFUSES TO SHOW. If the archive pass accepts it, that record can be judged
  # "decided" and its snapshot retired while no human was ever given the chance
  # to see it — the record is destroyed by the one pass that never displayed it.
  # The body here IS dismissed, so `_decided` is non-zero and the ONLY thing
  # holding the file is the `.phase` parse.
  # FALSIFYING EDIT: delete the `_phase=$(… jq -er '.phase' …)` line and its
  # `|| { _outstanding=…; break; }` from `dev_archive_pass`. (Measured: suite
  # stayed at 50/50 with it gone.)
  a48_nophase_body="A record the surface pass would refuse to show, because it carries no phase"
  a48_h1=$(a48_make "$(printf '{"ts":"2026-01-01T00:00:00Z","body":"%s"}\n' "$a48_nophase_body")" "$a48_nophase_body")
  A48_OUT1=$(a48_archive "$a48_h1")
  [[ "$(consumer_archived "$a48_h1/.claude")" -eq 0 ]] \
    || A48_FAILURES+=("(1) a snapshot whose only record has NO \`.phase\` was ARCHIVED — the surface pass refuses to display that record, so the archive pass just destroyed a deviation no human could ever have seen: $A48_OUT1")
  [[ "$(consumer_queued "$a48_h1/.claude")" -eq 1 ]] \
    || A48_FAILURES+=("(1) the phase-less snapshot left the queue: $A48_OUT1")

  # --- (2) CONTROL (green both ways by design): the SAME fixture WITH a
  #         `.phase` DOES archive ---
  # Without this, leg (1) is satisfied by an archive pass that has stopped
  # archiving altogether — the fail-closed default bought by breaking the
  # feature, which is how a guard test turns into a feature-removal test.
  a48_ok_body="An ordinary decided record, phase and all"
  a48_h2=$(a48_make "$(printf '{"ts":"2026-01-01T00:00:00Z","phase":"Implementation","body":"%s"}\n' "$a48_ok_body")" "$a48_ok_body")
  A48_OUT2=$(a48_archive "$a48_h2")
  [[ "$(consumer_archived "$a48_h2/.claude")" -eq 1 ]] \
    || A48_FAILURES+=("(2 CONTROL) a fully-decided, well-formed snapshot did NOT archive — leg (1) and legs (4)-(5) would then pass against a cleanup route that can never drain the queue: $A48_OUT2")

  # --- (3) AN EMPTY BODY BLOCKS ARCHIVAL — IT IS NOT MERELY SKIPPED ---
  # ⛔ `continue` IS FAIL-OPEN HERE AND `break` IS NOT. ⛔ A skipped record is
  # counted in NEITHER tally, so a file whose OTHER records are all decided
  # satisfies `_decided > 0 && _outstanding == 0` and is archived — carrying the
  # empty-body record away with it. The fixture puts the decided record FIRST so
  # that under the mutation `_decided` reaches 1 before the empty body is
  # reached, which is precisely the state that authorizes the `mv`.
  # FALSIFYING EDIT: change `[[ -z "$_body" ]] && { _outstanding=$((…+1));
  # break; }` to `[[ -z "$_body" ]] && continue`. (Measured: suite stayed at
  # 50/50, and the mutated run archived the file.)
  a48_h3=$(a48_make "$(printf '{"ts":"2026-01-01T00:00:00Z","phase":"Implementation","body":"%s"}\n{"ts":"2026-01-01T00:00:01Z","phase":"Code Review","body":""}\n' "$a48_ok_body")" "$a48_ok_body")
  A48_OUT3=$(a48_archive "$a48_h3")
  [[ "$(consumer_archived "$a48_h3/.claude")" -eq 0 ]] \
    || A48_FAILURES+=("(3) a snapshot holding an EMPTY-BODY record alongside a decided one was ARCHIVED — the empty-body record was never decided by anyone, and the mv destroyed it: $A48_OUT3")
  [[ "$(consumer_queued "$a48_h3/.claude")" -eq 1 ]] \
    || A48_FAILURES+=("(3) the snapshot holding an undecided empty-body record left the queue: $A48_OUT3")

  # --- (4) A SYMLINKED ARCHIVE DIRECTORY IS REFUSED, AND THE REFUSAL SAYS SO ---
  # ⛔ REPRODUCED ON BYTE-IDENTICAL STATE. ⛔ `surface` refused this exact fixture
  # with `refused=symlinked-state-file` while `archive` reported `archived=1`
  # and landed the snapshot OUTSIDE ~/.claude, where no later run can find it.
  # Both entry points now call `state_symlink_violation`.
  #
  # ⛔ THE ASSERTION IS THE GUARD'S OWN OUTPUT, NOT THE END STATE. ⛔ "Nothing was
  # archived" is also what a broken archive pass produces, and legs (1) and (3)
  # already showed how easily an end-state assertion is satisfied by the wrong
  # mechanism. The summary token is emitted by that guard and by nothing else.
  # FALSIFYING EDIT: delete the `state_symlink_violation` call from `cmd_archive`.
  # (Measured: suite stayed at 50/50 with it gone.)
  a48_h4=$(a48_make "$(printf '{"ts":"2026-01-01T00:00:00Z","phase":"Implementation","body":"%s"}\n' "$a48_ok_body")" "$a48_ok_body")
  mkdir -p "$a48_h4/outside-archive"
  rm -rf "$a48_h4/.claude/consumed-deviations"
  ln -s "$a48_h4/outside-archive" "$a48_h4/.claude/consumed-deviations"
  A48_OUT4=$(a48_archive "$a48_h4")
  printf '%s' "$A48_OUT4" | grep -q 'CONSUME-DEVIATIONS: archive refused=symlinked-state-file' \
    || A48_FAILURES+=("(4) \`archive\` did not refuse a SYMLINKED archive directory — \`surface\` refuses this identical state, so the two entry points have diverged again and the one that performs the mv is the permissive one. Got: $A48_OUT4")
  [[ "$(find "$a48_h4/outside-archive" -type f 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ]] \
    || A48_FAILURES+=("(4) the snapshot was moved THROUGH the symlink to $a48_h4/outside-archive — it is now outside the state dir every reader of this loop looks in: $A48_OUT4")
  [[ "$(consumer_queued "$a48_h4/.claude")" -eq 1 ]] \
    || A48_FAILURES+=("(4) the snapshot left the queue despite the symlinked archive dir: $A48_OUT4")

  # --- (5) A SYMLINKED DISMISSED LOG IS REFUSED ---
  # The sharper half of the same gap: the dismissed log is the ONLY thing that
  # authorizes archival, so reading it through a symlink means an attacker-
  # writable file decides which snapshots retire. The dismissal here is PLANTED
  # (not written through `consume-deviations.sh`), because the canonical write
  # refuses a symlinked log — which is the point: the writer was guarded and the
  # reader that acts on it was not.
  # FALSIFYING EDIT: as leg (4).
  a48_h5=$(mktemp -d); mkdir -p "$a48_h5/.claude" "$a48_h5/attacker"
  a48_evil_body="A deviation nobody ever triaged"
  a48_evil_hash=$(printf '%s' "$a48_evil_body" | shasum -a 256 | awk '{print $1}')
  printf '{"ts":"2026-01-01T00:00:00Z","phase":"Implementation","body":"%s"}\n' "$a48_evil_body" \
    > "$a48_h5/.claude/pending-deviations-4848.log"
  printf '[%s] 2026-01-01T00:00:00Z | planted, never decided by a human\n' "$a48_evil_hash" \
    > "$a48_h5/attacker/planted.log"
  ln -s "$a48_h5/attacker/planted.log" "$a48_h5/.claude/dismissed-deviations.log"
  A48_OUT5=$(a48_archive "$a48_h5")
  printf '%s' "$A48_OUT5" | grep -q 'CONSUME-DEVIATIONS: archive refused=symlinked-state-file' \
    || A48_FAILURES+=("(5) \`archive\` did not refuse a SYMLINKED dismissed log — the file that authorizes every retirement was read from outside the state dir. Got: $A48_OUT5")
  [[ "$(consumer_queued "$a48_h5/.claude")" -eq 1 ]] \
    || A48_FAILURES+=("(5) a never-triaged snapshot was retired on the strength of a planted dismissal reached through a symlink: $A48_OUT5")

  rm -rf "$a48_h1" "$a48_h2" "$a48_h3" "$a48_h4" "$a48_h5"

  if [[ ${#A48_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: a phase-less record and an empty-body record each blocked the mv while a well-formed decided snapshot still retired, and \`archive\` refused both a symlinked archive dir and a symlinked dismissed log with the guard's own refusal token rather than merely archiving nothing)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A48_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-49: THE SURFACE PASS'S OWN GATES — the mirror image of TC-STL-48
#
# WHY THIS EXISTS AT ALL. The defect 906a6c3 fixed was "the ARCHIVE entry point
# lacks the symlink precondition SURFACE has". The fix pinned the archive call
# site — and a mutation sweep then showed that deleting the check from the
# SURFACE call site left the whole suite green at 51/51. Same for the `.phase`
# validation and the `HASH_RE` validation: archive side pinned, surface side not.
# A test round that closes one half of an asymmetry and pins only that half has
# rebuilt the asymmetry it just removed.
#
# SHAPE COPIED FROM TC-STL-48 DELIBERATELY: every leg is independently
# falsifiable, leg (2) is a LIVE control (a well-formed record must still
# surface, so the guard legs cannot be satisfied by a surface pass that has
# stopped surfacing), and the three symlink legs assert the SAME refusal token
# while exercising THREE DIFFERENT sub-terms of `state_symlink_violation`, so no
# single mutation satisfies more than its own.
#
# ⛔ THE ASSERTION IS THE GUARD'S OWN OUTPUT WHERE ONE EXISTS. ⛔ "Nothing was
# archived" is also what a broken surface pass produces. The `refused=` token is
# emitted by that guard and by nothing else.
#
# GUARD → MUTATION → this test goes RED (each verified in an isolated copy):
#   `.phase` validation, surface pass    `jq -er` → `jq -r`      leg (1)
#   `state_symlink_violation` @ surface  `if false`             legs (3)(4)(5)
#   ... its `-L "$SURFACED_FILE"` term   term dropped           leg (3)
#   `cmd_surface` no-jq gate             `if false`             leg (6)
#   per-run dedupe, deviation side       `set_has …` → `:`      leg (7)
# ---------------------------------------------------------------------------
TC="TC-STL-49: the SURFACE entry point's gates and record validation (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the surface pass parses JSONL with jq, so this behavioural test cannot run"
else
  A49_FAILURES=()
  a49_body="An ordinary deviation with a phase, surfaced and then decided"

  # A throwaway HOME holding ONE snapshot. Returns the HOME.
  a49_make() {  # a49_make <snapshot-contents> [body-to-dismiss ...]
    local h st; h=$(mktemp -d); st="$h/.claude"; mkdir -p "$st"
    printf '%s' "$1" > "$st/pending-deviations-4949.log"
    shift
    local b
    for b in "$@"; do consumer_dismiss "$h" deviation "$b" >/dev/null 2>&1; done
    printf '%s' "$h"
  }
  a49_rec() {  # a49_rec <phase-json-fragment-or-empty> <body>
    if [[ -n "$1" ]]; then
      printf '{"ts":"2026-01-01T00:00:00Z","phase":"%s","body":"%s"}\n' "$1" "$2"
    else
      printf '{"ts":"2026-01-01T00:00:00Z","body":"%s"}\n' "$2"
    fi
  }

  # --- (1) A RECORD WITH NO `.phase` IS NEVER DISPLAYED ---
  # `jq -er` fails on a missing key AND on a null value; `jq -r` returns the
  # string "null" and succeeds. Under the weaker spelling the record is SHOWN
  # with a phase of `null`, marked surfaced, and — because the archive pass's own
  # `.phase` check (TC-STL-48 leg 1) is the only thing left holding it — the two
  # passes disagree again about what a valid record is.
  a49_h1=$(a49_make "$(a49_rec "" "A record with no phase at all")")
  A49_OUT1=$(consumer_run "$a49_h1" attended)
  printf '%s\n' "$A49_OUT1" | grep -q 'surfaced=0 ' \
    || A49_FAILURES+=("(1) a record with NO \`.phase\` was SURFACED — the surface pass is using a spelling of the jq extraction that accepts a missing key, so a record the archive pass calls invalid is displayed and marked shown: $A49_OUT1")
  printf '%s\n' "$A49_OUT1" | grep -q 'parse_failures=1 ' \
    || A49_FAILURES+=("(1) a record with NO \`.phase\` was not counted as a parse failure, so its snapshot is not held by parse_fail_files either: $A49_OUT1")
  printf '%s\n' "$A49_OUT1" | grep -q 'A record with no phase at all' \
    && A49_FAILURES+=("(1) the phase-less record's BODY was printed to the user: $A49_OUT1")
  rm -rf "$a49_h1"

  # --- (2) CONTROL (green both ways by design): the same record WITH a phase
  #         DOES surface ---
  # Without this, every leg below is satisfied by a surface pass that surfaces
  # nothing at all — the fail-closed default bought by breaking the feature.
  a49_h2=$(a49_make "$(a49_rec "Implementation" "$a49_body")")
  A49_OUT2=$(consumer_run "$a49_h2" attended)
  printf '%s\n' "$A49_OUT2" | grep -q 'surfaced=1 ' \
    || A49_FAILURES+=("(2 CONTROL) a well-formed record did NOT surface — every other leg here would then pass against a surface pass that can never show anything: $A49_OUT2")
  rm -rf "$a49_h2"

  # --- (3) A SYMLINKED SURFACED LOG IS REFUSED (the `-L "$SURFACED_FILE"` term) ---
  # This term is the one the archive path carries "even though `archive` never
  # touches it", and the file-header defends that as deliberate. On the SURFACE
  # path it is not defence-in-depth at all: the surfaced log is written here, so
  # a symlink means this run's markers land wherever the link points and the
  # pointer this loop depends on is under someone else's control.
  a49_h3=$(a49_make "$(a49_rec "Implementation" "$a49_body")" "$a49_body")
  mkdir -p "$a49_h3/outside"
  : > "$a49_h3/outside/surfaced.log"
  rm -f "$a49_h3/.claude/surfaced-deviations.log"
  ln -s "$a49_h3/outside/surfaced.log" "$a49_h3/.claude/surfaced-deviations.log"
  A49_OUT3=$(consumer_run "$a49_h3" attended)
  printf '%s\n' "$A49_OUT3" | grep -q 'CONSUME-DEVIATIONS: surface refused=symlinked-state-file' \
    || A49_FAILURES+=("(3) \`surface\` did not refuse a SYMLINKED surfaced log — this run writes that file, so its markers now land outside the state dir: $A49_OUT3")
  [[ "$(consumer_archived "$a49_h3/.claude")" -eq 0 ]] \
    || A49_FAILURES+=("(3) the run archived a snapshot despite the symlinked surfaced log: $A49_OUT3")
  [[ "$(consumer_queued "$a49_h3/.claude")" -eq 1 ]] \
    || A49_FAILURES+=("(3) the snapshot left the queue despite the symlinked surfaced log: $A49_OUT3")
  rm -rf "$a49_h3"

  # --- (4) A SYMLINKED DISMISSED LOG IS REFUSED (the `-L "$DISMISSED_FILE"` term) ---
  # The dismissed log is the ONLY thing that authorizes archival, and `surface`
  # reaches the archive pass. The dismissal is PLANTED, not written through the
  # canonical writer, because the writer refuses a symlinked log — which is the
  # point: the writer was guarded and the readers acting on it must be too.
  a49_h4=$(mktemp -d); mkdir -p "$a49_h4/.claude" "$a49_h4/attacker"
  a49_evil="A deviation nobody ever triaged, retired by a planted dismissal"
  a49_evil_h=$(printf '%s' "$a49_evil" | shasum -a 256 | awk '{print $1}')
  a49_rec "Implementation" "$a49_evil" > "$a49_h4/.claude/pending-deviations-4949.log"
  printf '[%s] 2026-01-01T00:00:00Z | planted, never decided by a human\n' "$a49_evil_h" \
    > "$a49_h4/attacker/planted.log"
  ln -s "$a49_h4/attacker/planted.log" "$a49_h4/.claude/dismissed-deviations.log"
  A49_OUT4=$(consumer_run "$a49_h4" attended)
  printf '%s\n' "$A49_OUT4" | grep -q 'CONSUME-DEVIATIONS: surface refused=symlinked-state-file' \
    || A49_FAILURES+=("(4) \`surface\` did not refuse a SYMLINKED dismissed log — the file that authorizes every retirement was read from outside the state dir: $A49_OUT4")
  [[ "$(consumer_queued "$a49_h4/.claude")" -eq 1 ]] \
    || A49_FAILURES+=("(4) a never-triaged snapshot was retired on the strength of a planted dismissal reached through a symlink: $A49_OUT4")
  rm -rf "$a49_h4"

  # --- (5) A SYMLINKED ARCHIVE DIRECTORY IS REFUSED (the `-L "$CONSUMED_DIR"` term) ---
  # `surface` runs `dev_archive_pass`, so it performs the `mv` too. Through a
  # symlinked archive dir the snapshot lands outside ~/.claude, where no later
  # run can find it — and `dir_has_file` in selfimprovement-backlog.sh then no
  # longer sees the evidence either.
  a49_h5=$(a49_make "$(a49_rec "Implementation" "$a49_body")" "$a49_body")
  mkdir -p "$a49_h5/outside-archive"
  rm -rf "$a49_h5/.claude/consumed-deviations"
  ln -s "$a49_h5/outside-archive" "$a49_h5/.claude/consumed-deviations"
  A49_OUT5=$(consumer_run "$a49_h5" attended)
  printf '%s\n' "$A49_OUT5" | grep -q 'CONSUME-DEVIATIONS: surface refused=symlinked-state-file' \
    || A49_FAILURES+=("(5) \`surface\` did not refuse a SYMLINKED archive directory: $A49_OUT5")
  [[ "$(find "$a49_h5/outside-archive" -type f 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ]] \
    || A49_FAILURES+=("(5) the snapshot was moved THROUGH the symlink to $a49_h5/outside-archive — it is now outside the state dir every reader of this loop looks in: $A49_OUT5")
  [[ "$(consumer_queued "$a49_h5/.claude")" -eq 1 ]] \
    || A49_FAILURES+=("(5) the snapshot left the queue despite the symlinked archive dir: $A49_OUT5")
  rm -rf "$a49_h5"

  # --- (6) NO jq ON PATH: THE SURFACE IS REFUSED UP FRONT, NOT ATTEMPTED ---
  # ⛔ "THE OUTPUT MENTIONS jq" IS NOT ENOUGH. ⛔ TC-STL-28 leg 2 measured the
  # same trap on the shasum side: with the guard replaced by `elif false` the run
  # proceeds and the SHELL's own `jq: command not found` lands on stderr, so a
  # bare `grep -qi jq` passes on a completely unguarded run. The discriminators
  # that bind THIS guard are its summary token and the absence of the surface
  # header — a refused run never starts the listing at all.
  a49_h6=$(a49_make "$(a49_rec "Implementation" "$a49_body")" "$a49_body")
  a49_minbin="$a49_h6/minbin"
  a49_shell=$(command -v bash 2>/dev/null)
  if [[ ! -x "$a49_shell" ]] || ! consumer_minbin_without "$a49_minbin" jq; then
    A49_FAILURES+=("(6) setup: could not resolve bash or one of the tools the consumer calls, so a jq-absent PATH could not be built without also removing something else")
  else
    A49_OUT6=$(HOME="$a49_h6" PATH="$a49_minbin" "$a49_shell" "$CONSUMER_SCRIPT" surface baselito ai-engineering 4242 MERGED attended 2>&1)
    printf '%s\n' "$A49_OUT6" | grep -q 'CONSUME-DEVIATIONS: surface refused=no-jq' \
      || A49_FAILURES+=("(6) a run with no jq on PATH did not report \`refused=no-jq\` — the tool's absence is being INFERRED from a run that quietly turns every record into a parse failure instead of reported: $A49_OUT6")
    printf '%s\n' "$A49_OUT6" | grep -q 'Surfacing captured deviations' \
      && A49_FAILURES+=("(6) the run printed the surface header with no jq available — it was ATTEMPTED rather than refused up front, so any 'jq' text in the output is the shell's own command-not-found noise: $A49_OUT6")
    [[ "$(consumer_queued "$a49_h6/.claude")" -eq 1 ]] \
      || A49_FAILURES+=("(6) the snapshot did not survive a jq-less run — PRESERVE is the whole contract of a missing-tool refusal: $A49_OUT6")
    [[ "$(consumer_archived "$a49_h6/.claude")" -eq 0 ]] \
      || A49_FAILURES+=("(6) a run that could not parse anything still ARCHIVED a snapshot: $A49_OUT6")
  fi
  rm -rf "$a49_h6"

  # --- (7) TWO SNAPSHOTS, ONE BODY: THE PER-RUN DEDUPE COLLAPSES THEM ---
  # handover.md was not cleared between several merges, so byte-identical bodies
  # legitimately appear in several snapshots. Without the dedupe the same record
  # is printed once per snapshot and the duplicates eat the 15-record cap, which
  # is the mechanism that pushes real deviations out of view.
  a49_h7=$(mktemp -d); mkdir -p "$a49_h7/.claude"
  a49_dup="A deviation captured twice because handover.md was never cleared"
  a49_rec "Implementation" "$a49_dup" > "$a49_h7/.claude/pending-deviations-4971.log"
  a49_rec "Implementation" "$a49_dup" > "$a49_h7/.claude/pending-deviations-4972.log"
  A49_OUT7=$(consumer_run "$a49_h7" attended)
  printf '%s\n' "$A49_OUT7" | grep -q 'surfaced=1 ' \
    || A49_FAILURES+=("(7) two snapshots holding a BYTE-IDENTICAL body did not collapse to one surfaced record — duplicates consume the surface cap and push undisplayed deviations past it: $A49_OUT7")
  rm -rf "$a49_h7"

  if [[ ${#A49_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: a phase-less record was refused display and counted as a parse failure while a well-formed one still surfaced; \`surface\` refused a symlinked surfaced log, a symlinked dismissed log and a symlinked archive dir with the guard's own token, archiving nothing and moving nothing outside the state dir; a jq-less run was refused up front and preserved its snapshot; and a body duplicated across two snapshots surfaced once)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A49_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-50: `cmd_lessons`' GATES — the weakest-covered half of the consumer
#
# WHY: `lessons` is the ONLY subcommand that DELETES files (`rm -f` over every
# pending snapshot plus the cross-PR deferred queue), and it was the least
# exercised: two invocations in the whole suite, every gate unpinned. A mutation
# sweep removed each of them in turn and the suite stayed green at 51/51 —
# including the one that matters most: with the symlink gate replaced by
# `if false`, a `dismissed-lessons.log` symlinked to an attacker-written file
# carrying ONE planted marker reported `deleted=yes` and left ZERO pending
# files. `rm -f` on the strength of a dismissal nobody made.
#
# This is the lessons-half twin of TC-STL-48 legs (4)/(5), which existed only on
# the deviation half — the same asymmetry, one function over.
#
# Every leg asserts the guard's OWN summary token, because "nothing was deleted"
# is also what a `cmd_lessons` that has stopped working produces; leg (9) is a
# LIVE control that keeps the guard legs from being satisfied that way.
#
# GUARD → MUTATION → this test goes RED (each verified in an isolated copy):
#   `cmd_lessons` claude_dir_is_symlink        `if false`            leg (1)
#   `cmd_lessons` MERGED gate                  `if false`            leg (2)
#   `cmd_lessons` symlinked-state-file gate    `if false`         legs (3)(4)
#   ... its `-L "$DISMISSED_LESSONS_LOG"` term term dropped          leg (3)
#   ... its `-L "$DEFERRED_LESSONS"` term      term dropped          leg (4)
#   `cmd_lessons` no-jq gate                   `if false`            leg (5)
#   `cmd_lessons` no-shasum gate               `if false`            leg (6)
#   EOF-residue guard in `cmd_lessons`         `|| [[ -n … ]]` dropped leg (7)
#   `$DEFERRED_LESSONS` skip in the glob       line deleted          RETIRED —
#     no longer reddens anything. C-6 added `LESSONNAME_RE`, which already excludes
#     `pending-lessons-deferred.jsonl` (`deferred` is not digits), so this guard
#     became redundant DURING the fix round and leg (8) stopped depending on it.
#     Re-measured at this HEAD: line deleted, `All 67 tests passed`, TC-STL-50 PASS.
#     Kept in the production file for construction-level disjointness, not coverage
#     — see the deliberately-unpinned list near the top of this file.
# ---------------------------------------------------------------------------
TC="TC-STL-50: the lessons half's gates hold the only rm in the loop (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the lessons half parses JSONL with jq, so this behavioural test cannot run"
else
  A50_FAILURES=()
  # REPO_ROOT is the throwaway HOME, exactly as TC-STL-46 does it: the script
  # only ever builds a display string from it, so pointing it at a directory
  # holding no knowledge/ dir keeps the leg about the gate under test.
  a50_lessons() { HOME="$1" bash "$CONSUMER_SCRIPT" lessons baselito ai-engineering 4242 "${2:-MERGED}" "$1" 2>&1; }
  a50_rec() { printf '{"finding":"%s","verdict":"fixed","origin":"automated-review"}\n' "$1"; }
  a50_finding="A finding nobody has triaged, in a queue only cmd_lessons can delete"

  # --- (1) A SYMLINKED ~/.claude IS REFUSED ---
  a50_h1=$(mktemp -d); mkdir -p "$a50_h1/real-claude"
  ln -s "$a50_h1/real-claude" "$a50_h1/.claude"
  a50_rec "$a50_finding" > "$a50_h1/real-claude/pending-lessons-501.jsonl"
  A50_OUT1=$(a50_lessons "$a50_h1")
  printf '%s\n' "$A50_OUT1" | grep -q 'CONSUME-DEVIATIONS: lessons refused=symlinked-state-dir' \
    || A50_FAILURES+=("(1) \`lessons\` did not refuse a SYMLINKED state directory — every mkdir, touch and rm below that gate then follows the link out of ~/.claude: $A50_OUT1")
  [[ -e "$a50_h1/real-claude/pending-lessons-501.jsonl" ]] \
    || A50_FAILURES+=("(1) the pending queue was DELETED through a symlinked state dir: $A50_OUT1")
  rm -rf "$a50_h1"

  # --- (2) A PR THAT IS NOT MERGED IS REFUSED ---
  # A CLOSED PR means the work did not ship. Without this gate a closed-PR run
  # reaches the delete branch and drains a queue whose findings were never
  # resolved.
  a50_h2=$(mktemp -d); mkdir -p "$a50_h2/.claude"
  a50_rec "$a50_finding" > "$a50_h2/.claude/pending-lessons-502.jsonl"
  consumer_dismiss "$a50_h2" lesson "$a50_finding" >/dev/null 2>&1
  A50_OUT2=$(a50_lessons "$a50_h2" CLOSED)
  printf '%s\n' "$A50_OUT2" | grep -q 'CONSUME-DEVIATIONS: lessons refused=pr-not-merged' \
    || A50_FAILURES+=("(2) a CLOSED PR was not refused: $A50_OUT2")
  [[ -e "$a50_h2/.claude/pending-lessons-502.jsonl" ]] \
    || A50_FAILURES+=("(2) a CLOSED-PR run reached the delete branch and removed the queue: $A50_OUT2")
  rm -rf "$a50_h2"

  # --- (3) A SYMLINKED dismissed-lessons.log IS REFUSED ---
  # ⛔ THE SHARPEST OF THE FOUR. ⛔ That log is the only thing that suppresses a
  # candidate, and a suppressed candidate is what makes `candidates == 0` — the
  # sole condition authorizing the `rm -f`. Read through a symlink, ONE planted
  # marker in an attacker-writable file drains the entire queue. The marker is
  # PLANTED rather than written through the canonical writer because that writer
  # refuses a symlinked log; the writer was guarded and the reader acting on it
  # must be too.
  a50_h3=$(mktemp -d); mkdir -p "$a50_h3/.claude" "$a50_h3/attacker"
  a50_rec "$a50_finding" > "$a50_h3/.claude/pending-lessons-503.jsonl"
  a50_fh=$(printf '%s' "$a50_finding" | shasum -a 256 | awk '{print $1}')
  printf '[%s] 2026-01-01T00:00:00Z | planted, no human ever decided this\n' "$a50_fh" \
    > "$a50_h3/attacker/planted.log"
  ln -s "$a50_h3/attacker/planted.log" "$a50_h3/.claude/dismissed-lessons.log"
  A50_OUT3=$(a50_lessons "$a50_h3")
  printf '%s\n' "$A50_OUT3" | grep -q 'CONSUME-DEVIATIONS: lessons refused=symlinked-state-file' \
    || A50_FAILURES+=("(3) \`lessons\` did not refuse a SYMLINKED dismissed-lessons log — the file that suppresses candidates, and therefore authorizes the only rm in this loop, was read from outside the state dir: $A50_OUT3")
  [[ -e "$a50_h3/.claude/pending-lessons-503.jsonl" ]] \
    || A50_FAILURES+=("(3) the pending queue was DELETED on the strength of a planted dismissal reached through a symlink: $A50_OUT3")
  rm -rf "$a50_h3"

  # --- (4) A SYMLINKED DEFERRED QUEUE IS REFUSED ---
  # A different sub-term of the same predicate, and a different consequence:
  # the deferred queue is a RECORD SOURCE, so through a symlink an
  # attacker-written file is read and its contents are proposed to the agent as
  # lessons candidates. The `deleted` half of leg (3) cannot detect that, which
  # is why this leg asserts on the candidate text instead.
  a50_h4=$(mktemp -d); mkdir -p "$a50_h4/.claude" "$a50_h4/attacker"
  a50_rec "$a50_finding" > "$a50_h4/.claude/pending-lessons-504.jsonl"
  a50_injected="INJECTED via a symlinked deferred queue, written by nobody this loop trusts"
  a50_rec "$a50_injected" > "$a50_h4/attacker/deferred.jsonl"
  ln -s "$a50_h4/attacker/deferred.jsonl" "$a50_h4/.claude/pending-lessons-deferred.jsonl"
  A50_OUT4=$(a50_lessons "$a50_h4")
  printf '%s\n' "$A50_OUT4" | grep -q 'CONSUME-DEVIATIONS: lessons refused=symlinked-state-file' \
    || A50_FAILURES+=("(4) \`lessons\` did not refuse a SYMLINKED deferred queue: $A50_OUT4")
  printf '%s\n' "$A50_OUT4" | grep -q "$a50_injected" \
    && A50_FAILURES+=("(4) a record read THROUGH the symlinked deferred queue was proposed as a lessons candidate — the deferred queue is a record source, so a symlink there feeds the consensus pass text from outside the state dir: $A50_OUT4")
  rm -rf "$a50_h4"

  # --- (5) NO jq ON PATH: REFUSED AND PRESERVED ---
  # Same trap as TC-STL-49 leg (6) and TC-STL-28 leg 2: the shell's own
  # `command not found` puts the tool's name on stderr, so the token is the
  # discriminator, not the word.
  a50_h5=$(mktemp -d); mkdir -p "$a50_h5/.claude"
  a50_rec "$a50_finding" > "$a50_h5/.claude/pending-lessons-505.jsonl"
  consumer_dismiss "$a50_h5" lesson "$a50_finding" >/dev/null 2>&1
  a50_shell=$(command -v bash 2>/dev/null)
  a50_nojq="$a50_h5/nojq"
  if [[ ! -x "$a50_shell" ]] || ! consumer_minbin_without "$a50_nojq" jq; then
    A50_FAILURES+=("(5) setup: could not build a jq-absent PATH holding every other tool the consumer calls")
  else
    A50_OUT5=$(HOME="$a50_h5" PATH="$a50_nojq" "$a50_shell" "$CONSUMER_SCRIPT" lessons baselito ai-engineering 4242 MERGED "$a50_h5" 2>&1)
    printf '%s\n' "$A50_OUT5" | grep -q 'CONSUME-DEVIATIONS: lessons refused=no-jq' \
      || A50_FAILURES+=("(5) a jq-less run did not report \`refused=no-jq\`: $A50_OUT5")
    [[ -e "$a50_h5/.claude/pending-lessons-505.jsonl" ]] \
      || A50_FAILURES+=("(5) a run that could not parse a single record still DELETED the queue — every record in it would then be gone with nothing having read it: $A50_OUT5")
  fi
  rm -rf "$a50_h5"

  # --- (6) NO shasum ON PATH: REFUSED AND PRESERVED ---
  # Without shasum every finding hash is the empty string and the anchored
  # dismissed lookup degrades to `^\[\] `, so one marker in that shape suppresses
  # EVERY candidate — which then satisfies `candidates == 0` and deletes the
  # whole queue. This branch had never been reached by any test.
  a50_h6=$(mktemp -d); mkdir -p "$a50_h6/.claude"
  a50_rec "$a50_finding" > "$a50_h6/.claude/pending-lessons-506.jsonl"
  a50_nosha="$a50_h6/nosha"
  if [[ ! -x "$a50_shell" ]] || ! consumer_minbin_without "$a50_nosha" shasum; then
    A50_FAILURES+=("(6) setup: could not build a shasum-absent PATH holding every other tool the consumer calls")
  else
    A50_OUT6=$(HOME="$a50_h6" PATH="$a50_nosha" "$a50_shell" "$CONSUMER_SCRIPT" lessons baselito ai-engineering 4242 MERGED "$a50_h6" 2>&1)
    printf '%s\n' "$A50_OUT6" | grep -q 'CONSUME-DEVIATIONS: lessons refused=no-shasum' \
      || A50_FAILURES+=("(6) a shasum-less run did not report \`refused=no-shasum\` — the lessons half must refuse for the same reason the deviation half does, or every finding collapses onto one empty key: $A50_OUT6")
    [[ -e "$a50_h6/.claude/pending-lessons-506.jsonl" ]] \
      || A50_FAILURES+=("(6) a run that could not derive a single hash still DELETED the queue: $A50_OUT6")
  fi
  rm -rf "$a50_h6"

  # --- (7) A FINAL RECORD WITH NO TRAILING NEWLINE IS STILL READ ---
  # `read` returns non-zero at EOF without a delimiter, so without the
  # `|| [[ -n "$_record" ]]` residue guard the last record is left in the
  # variable and the loop body never runs for it. It is then counted NEITHER as
  # a candidate NOR as a parse failure — which is exactly the pair of zeroes the
  # delete branch keys on, so the file holding it is REMOVED.
  a50_h7=$(mktemp -d); mkdir -p "$a50_h7/.claude"
  printf '{"finding":"A finding written without a trailing newline","verdict":"fixed","origin":"codex"}' \
    > "$a50_h7/.claude/pending-lessons-507.jsonl"
  A50_OUT7=$(a50_lessons "$a50_h7")
  printf '%s\n' "$A50_OUT7" | grep -q 'candidates=1 ' \
    || A50_FAILURES+=("(7) a final record with NO trailing newline produced no candidate — it is counted in neither tally, which is precisely the state that authorizes the delete: $A50_OUT7")
  [[ -e "$a50_h7/.claude/pending-lessons-507.jsonl" ]] \
    || A50_FAILURES+=("(7) the snapshot holding a newline-less final record was DELETED with that record never having been read: $A50_OUT7")
  rm -rf "$a50_h7"

  # --- (8) THE DEFERRED QUEUE IS NOT COUNTED AS A PER-PR SNAPSHOT ---
  # `pending-lessons-deferred.jsonl` matches the per-PR glob but is read and
  # deleted separately. Without the skip every deferred record is read twice and
  # the file is deleted by both paths, and the count the user is shown is wrong.
  a50_h8=$(mktemp -d); mkdir -p "$a50_h8/.claude"
  a50_rec "$a50_finding" > "$a50_h8/.claude/pending-lessons-508.jsonl"
  a50_rec "A finding a human explicitly DEFERRED to a later PR" > "$a50_h8/.claude/pending-lessons-deferred.jsonl"
  A50_OUT8=$(a50_lessons "$a50_h8")
  printf '%s\n' "$A50_OUT8" | grep -q 'snapshots=1 ' \
    || A50_FAILURES+=("(8) the cross-PR deferred queue was counted among the per-PR snapshots — it is read and deleted on its own path, so counting it here double-reads every deferred record: $A50_OUT8")
  rm -rf "$a50_h8"

  # --- (9) CONTROL (green both ways by design): an ordinary queue is READ ---
  # Every leg above asserts a refusal or a preservation, and a `cmd_lessons`
  # that refuses everything satisfies all of them. This one requires the
  # subcommand to still do its job.
  a50_h9=$(mktemp -d); mkdir -p "$a50_h9/.claude"
  a50_rec "$a50_finding" > "$a50_h9/.claude/pending-lessons-509.jsonl"
  A50_OUT9=$(a50_lessons "$a50_h9")
  printf '%s\n' "$A50_OUT9" | grep -q 'candidates=1 ' \
    || A50_FAILURES+=("(9 CONTROL) an ordinary readable queue holding one undismissed finding produced no candidate — every refusal leg above would then pass against a lessons half that can never propose anything: $A50_OUT9")
  printf '%s\n' "$A50_OUT9" | grep -q 'refused=' \
    && A50_FAILURES+=("(9 CONTROL) an ordinary run was REFUSED: $A50_OUT9")
  rm -rf "$a50_h9"

  # --- (10) A shasum THAT EXISTS BUT FAILS — the key validation, not the gate ---
  # ⛔ THE LESSONS-SIDE TWIN OF TC-STL-28, AND IT WAS MISSING. ⛔ Legs (5)/(6)
  # remove a tool from PATH, which the `have_tools` gate catches before any record
  # is read. This leg leaves shasum ON PATH and makes it FAIL — a shadowed binary,
  # an exec failure under resource pressure, a truncated pipe — so the gate passes
  # and every finding digest is the EMPTY STRING. The consequence is the whole
  # queue: an empty key makes the anchored dismissed lookup degrade to `^\[\] `,
  # so no finding is a candidate, so every file looks to hold nothing undismissed,
  # so the per-file delete removes ALL of them. The `HASH_RE` validation inside
  # `lesson_record_hash` is the only thing standing there, and it counts the
  # record as a parse failure, which preserves its file.
  # (Added with the round-2 fixes: the term was unpinned on this half while the
  # deviation half had TC-STL-28 for the identical shape.)
  # FALSIFYING EDIT: drop `[[ "$_h" =~ $HASH_RE ]] || return 1` from
  # `lesson_record_hash`.
  a50_h10=$(mktemp -d); mkdir -p "$a50_h10/.claude"
  a50_rec "$a50_finding" > "$a50_h10/.claude/pending-lessons-510.jsonl"
  a50_badsha="$a50_h10/badsha"
  if [[ ! -x "$a50_shell" ]] || ! consumer_minbin_without "$a50_badsha" shasum; then
    A50_FAILURES+=("(10) setup: could not build a PATH holding every tool the consumer calls except shasum")
  else
    # shasum is PRESENT (so `command -v` succeeds and the gate passes) and BROKEN.
    printf '#!/usr/bin/env bash\nexit 127\n' > "$a50_badsha/shasum"
    chmod +x "$a50_badsha/shasum"
    A50_OUT10=$(HOME="$a50_h10" PATH="$a50_badsha" "$a50_shell" "$CONSUMER_SCRIPT" lessons baselito ai-engineering 4242 MERGED "$a50_h10" 2>&1)
    # Precondition: the run must have got PAST the tool gate, or this leg is just
    # leg (6) again with a different fixture.
    printf '%s\n' "$A50_OUT10" | grep -q 'refused=no-shasum' \
      && A50_FAILURES+=("(10 precondition) the run was refused by the missing-tool gate, so the key validation was never reached and this leg tests nothing — the stub must be ON PATH: $A50_OUT10")
    [[ -e "$a50_h10/.claude/pending-lessons-510.jsonl" ]] \
      || A50_FAILURES+=("(10) a broken-but-present shasum made every finding digest the EMPTY STRING, and the queue was DELETED on the strength of an anchored lookup degraded to \`^\\[\\] \` — no attacker, one failing binary: $A50_OUT10")
    printf '%s\n' "$A50_OUT10" | grep -q 'candidates=0 ' \
      || A50_FAILURES+=("(10) a record whose digest could not be derived was still proposed as a candidate — the key was used without being validated: $A50_OUT10")
    printf '%s\n' "$A50_OUT10" | grep -q 'deleted=no' \
      || A50_FAILURES+=("(10) the summary reported a deletion on a run that could not derive a single hash: $A50_OUT10")
  fi
  rm -rf "$a50_h10"

  if [[ ${#A50_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: a symlinked state dir, a non-MERGED PR, a symlinked dismissed-lessons log, a symlinked deferred queue, an absent jq and an absent shasum were each refused with the guard's own token and each left the queue on disk; a planted dismissal reached through a symlink deleted nothing and an injected deferred record was never proposed; a newline-less final record still produced a candidate; the deferred queue was not counted as a per-PR snapshot; and an ordinary queue still yielded one)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A50_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-51: THE ARCHIVE-NAME COLLISION PATH, AND `archive`'s REMAINING GATES
#
# ⛔ NO TEST HAD EVER CREATED AN ARCHIVE-NAME COLLISION. ⛔ The `mv` in
# `dev_archive_pass` is preceded by a bounded suffix search, and by an explicit
# REFUSAL when that search is exhausted. Collapsing the three-branch
# `if [[ -e "$_dest" ]] / elif mv / else` to a bare `if mv` left the whole suite
# green — and the measured consequence is the sharpest in the file: with all 100
# suffixes taken, `archived=0 still_queued=1` became `archived=1
# still_queued=0`, and the contents of `<name>.<epoch>.100` were REPLACED by the
# incoming snapshot. Previously-archived evidence destroyed, silently, by the
# one operation in this loop with no undo.
#
# `date` is stubbed to a fixed epoch so the suffix space is genuinely
# exhaustible: with a live clock the loop finds a free name on the next second
# and the branch is unreachable. The stub answers only `+%s` and delegates
# everything else to the real `date`, so no other use of it changes meaning.
#
# GUARD → MUTATION → this test goes RED (each verified in an isolated copy):
#   `mv` exhaustion refusal      `if [[ -e ]]`/`elif mv` → `if mv`   leg (1)
#   `cmd_archive` claude_dir_is_symlink   `if false`                 leg (3)
#   `cmd_archive` `have_tools` gate       `if false`              legs (4)(5)
# ---------------------------------------------------------------------------
TC="TC-STL-51: an exhausted archive-name search refuses instead of clobbering (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the archive pass parses JSONL with jq, so this behavioural test cannot run"
else
  A51_FAILURES=()
  a51_body="A decided deviation whose snapshot is about to be archived"
  a51_epoch=1700000000
  a51_real_date=$(command -v date 2>/dev/null)
  a51_shell=$(command -v bash 2>/dev/null)

  # A HOME holding one fully-decided snapshot. Returns the HOME.
  a51_make() {
    local h st; h=$(mktemp -d); st="$h/.claude"; mkdir -p "$st/consumed-deviations"
    printf '{"ts":"2026-01-01T00:00:00Z","phase":"Implementation","body":"%s"}\n' "$a51_body" \
      > "$st/pending-deviations-5151.log"
    consumer_dismiss "$h" deviation "$a51_body" >/dev/null 2>&1
    printf '%s' "$h"
  }
  # A `date` that reports a FIXED epoch for `+%s` and is otherwise the real one.
  a51_date_stub() {  # a51_date_stub <bindir>
    mkdir -p "$1" || return 1
    {
      printf '#!/bin/sh\n'
      printf 'for a in "$@"; do\n'
      printf '  case "$a" in +%%s) echo %s; exit 0 ;; esac\n' "$a51_epoch"
      printf 'done\n'
      printf 'exec %s "$@"\n' "$a51_real_date"
    } > "$1/date"
    chmod +x "$1/date"
  }

  if [[ ! -x "$a51_real_date" || ! -x "$a51_shell" ]]; then
    A51_FAILURES+=("setup: could not resolve the real date or bash, so the fixed-epoch stub could not be built")
  else
    # --- (1) EVERY SUFFIX TAKEN: REFUSE, AND LEAVE THE EVIDENCE ALONE ---
    a51_h1=$(a51_make)
    a51_c1="$a51_h1/.claude/consumed-deviations"
    printf 'ARCHIVED EVIDENCE base\n' > "$a51_c1/pending-deviations-5151.log"
    _i=1
    while [[ $_i -le 100 ]]; do
      printf 'ARCHIVED EVIDENCE %s\n' "$_i" > "$a51_c1/pending-deviations-5151.log.$a51_epoch.$_i"
      _i=$((_i+1))
    done
    a51_bin1="$a51_h1/bin"; a51_date_stub "$a51_bin1"
    A51_OUT1=$(HOME="$a51_h1" PATH="$a51_bin1:$PATH" "$a51_shell" "$CONSUMER_SCRIPT" archive baselito ai-engineering 2>&1)
    printf '%s\n' "$A51_OUT1" | grep -q 'CONSUME-DEVIATIONS: archive archived=0 still_queued=1' \
      || A51_FAILURES+=("(1) with every archive name taken the run did not report \`archived=0 still_queued=1\` — the suffix search was exhausted, so the only safe move is to leave the snapshot queued: $A51_OUT1")
    printf '%s\n' "$A51_OUT1" | grep -q 'could not find a free archive name' \
      || A51_FAILURES+=("(1) the exhausted suffix search printed no WARN naming it — a snapshot that will never retire must say why, or it looks like an ordinary queued file forever: $A51_OUT1")
    [[ "$(cat "$a51_c1/pending-deviations-5151.log.$a51_epoch.100" 2>/dev/null)" == "ARCHIVED EVIDENCE 100" ]] \
      || A51_FAILURES+=("(1) the LAST archive slot was OVERWRITTEN by the incoming snapshot — previously-archived evidence is the one thing in this loop that cannot be regenerated, and the mv destroyed it: $A51_OUT1")
    [[ "$(consumer_queued "$a51_h1/.claude")" -eq 1 ]] \
      || A51_FAILURES+=("(1) the snapshot left the queue even though no free archive name existed: $A51_OUT1")
    rm -rf "$a51_h1"

    # --- (2) CONTROL (green both ways by design): ONE collision still archives ---
    # Leg (1) is also satisfied by an archive pass that has stopped archiving.
    # Here exactly one name is taken, so the search must find `.<epoch>.1` and
    # the snapshot must retire WITHOUT touching the file already there.
    a51_h2=$(a51_make)
    a51_c2="$a51_h2/.claude/consumed-deviations"
    printf 'ARCHIVED EVIDENCE base\n' > "$a51_c2/pending-deviations-5151.log"
    a51_bin2="$a51_h2/bin"; a51_date_stub "$a51_bin2"
    A51_OUT2=$(HOME="$a51_h2" PATH="$a51_bin2:$PATH" "$a51_shell" "$CONSUMER_SCRIPT" archive baselito ai-engineering 2>&1)
    printf '%s\n' "$A51_OUT2" | grep -q 'CONSUME-DEVIATIONS: archive archived=1 still_queued=0' \
      || A51_FAILURES+=("(2 CONTROL) a snapshot whose archive name was taken exactly ONCE did not retire into the next free suffix — leg (1) would then pass against a cleanup route that can never drain the queue: $A51_OUT2")
    [[ "$(cat "$a51_c2/pending-deviations-5151.log" 2>/dev/null)" == "ARCHIVED EVIDENCE base" ]] \
      || A51_FAILURES+=("(2 CONTROL) the pre-existing archive entry was overwritten rather than side-stepped: $A51_OUT2")
    rm -rf "$a51_h2"

    # --- (3) A SYMLINKED ~/.claude IS REFUSED ON THE ARCHIVE PATH ---
    # This is the path that performs the mv, so it is the one where following a
    # link out of the state dir does the damage.
    a51_h3=$(mktemp -d); mkdir -p "$a51_h3/real-claude/consumed-deviations"
    ln -s "$a51_h3/real-claude" "$a51_h3/.claude"
    printf '{"ts":"2026-01-01T00:00:00Z","phase":"Implementation","body":"%s"}\n' "$a51_body" \
      > "$a51_h3/real-claude/pending-deviations-5151.log"
    printf '[%s] 2026-01-01T00:00:00Z | decided\n' "$(printf '%s' "$a51_body" | shasum -a 256 | awk '{print $1}')" \
      > "$a51_h3/real-claude/dismissed-deviations.log"
    A51_OUT3=$(HOME="$a51_h3" bash "$CONSUMER_SCRIPT" archive baselito ai-engineering 2>&1)
    printf '%s\n' "$A51_OUT3" | grep -q 'CONSUME-DEVIATIONS: archive refused=symlinked-state-dir' \
      || A51_FAILURES+=("(3) \`archive\` did not refuse a SYMLINKED state directory: $A51_OUT3")
    [[ -e "$a51_h3/real-claude/pending-deviations-5151.log" ]] \
      || A51_FAILURES+=("(3) a snapshot was archived through a symlinked state dir: $A51_OUT3")
    rm -rf "$a51_h3"

    # --- (4)/(5) NO TOOLS: REFUSE TO ARCHIVE, AND SAY WHICH ---
    # `have_tools` is one predicate over two commands, so each leg removes a
    # DIFFERENT one and both must produce the refusal. A snapshot whose records
    # cannot be read must never be retired: with jq gone the legacy-format guard
    # skips every record, so an unguarded run reports a perfectly ordinary
    # `archived=0` and nothing tells the user why nothing ever drains.
    _n=4
    for _tool in jq shasum; do
      a51_ht=$(a51_make)
      a51_min="$a51_ht/min$_tool"
      if ! consumer_minbin_without "$a51_min" "$_tool"; then
        A51_FAILURES+=("($_n) setup: could not build a $_tool-absent PATH holding every other tool the consumer calls")
      else
        A51_OUTH=$(HOME="$a51_ht" PATH="$a51_min" "$a51_shell" "$CONSUMER_SCRIPT" archive baselito ai-engineering 2>&1)
        printf '%s\n' "$A51_OUTH" | grep -q 'CONSUME-DEVIATIONS: archive refused=missing-tools' \
          || A51_FAILURES+=("($_n) \`archive\` with no $_tool on PATH did not report \`refused=missing-tools\` — it reported an ordinary run instead, so a machine that can never archive anything looks identical to one with nothing to archive: $A51_OUTH")
        [[ "$(consumer_queued "$a51_ht/.claude")" -eq 1 ]] \
          || A51_FAILURES+=("($_n) the snapshot did not survive a $_tool-less archive run: $A51_OUTH")
        [[ "$(consumer_archived "$a51_ht/.claude")" -eq 0 ]] \
          || A51_FAILURES+=("($_n) a run that could not read a single record still ARCHIVED a snapshot: $A51_OUTH")
      fi
      rm -rf "$a51_ht"
      _n=$((_n+1))
    done
  fi

  if [[ ${#A51_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script under a fixed-epoch date: with all 100 archive suffixes taken the run refused, warned, left the snapshot queued and left the last archived file byte-identical, while a single collision still retired into the next free suffix; and \`archive\` refused a symlinked state dir and a PATH missing either jq or shasum, preserving the snapshot each time)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A51_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-52: THE ENUMERATION AND THE ORDERING PASS — three layers of one defence
#
# WHY: `dev_enumerate_snapshots` decides WHICH files this loop will open, read,
# and ultimately `mv`. It has three layers — the `-f`/`! -L` source filter, the
# filename regex, and an ordering pass that may only PERMUTE the validated set —
# and a mutation sweep found NONE of them pinned. TC-STL-31 covers one specific
# escape (a name holding a space) but nothing bound the layers themselves.
#
# The ordering pass is driven by `ls -t`, so the only way to test what it does
# with output it did not expect is to make `ls` produce that output. The stub
# below is on PATH for the consumer's own process only, and `ls` is called from
# exactly one place in the script, so nothing else changes meaning.
#
# ⛔ THE INJECTED SET MUST HAVE THE SAME CARDINALITY AS THE REAL ONE. ⛔ The
# fail-closed count check is a SECOND layer: hand `ls` three lines where two went
# in and the count check rejects the result before the membership test matters,
# so a leg built that way would pass with the membership test deleted and prove
# nothing. Leg (3) therefore swaps ONE member for a non-member, keeping the count
# equal, which is the only shape that isolates the membership test.
#
# GUARD → MUTATION → this test goes RED (each verified in an isolated copy):
#   `-f` half of the source filter     `[[ ! -L … ]]` only          leg (2)
#   `DEVNAME_RE` filename rule         line deleted                 leg (1)
#   ordering-pass membership test      bare `_sorted+=`             leg (3)
#   lossy-ordering fail-closed check   `-eq` → `-gt 0`           legs (3)(4)
# ---------------------------------------------------------------------------
TC="TC-STL-52: the sweep opens only the files the writer writes, and a sort may only permute (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the sweep parses JSONL with jq, so this behavioural test cannot run"
else
  A52_FAILURES=()
  a52_rec() { printf '{"ts":"2026-01-01T00:00:00Z","phase":"Implementation","body":"%s"}\n' "$1"; }
  a52_shell=$(command -v bash 2>/dev/null)

  # --- (1) A NAME THE WRITER NEVER WRITES IS NOT A SNAPSHOT ---
  # `scripts/pr-postmerge-fold.sh` only ever emits
  # `pending-deviations-<PR NUMBER>.log`. A file matching the glob but not the
  # NAME is somebody's hand-maintained file, and the downstream operation is an
  # irreversible `mv` out of the directory they put it in.
  a52_h1=$(mktemp -d); a52_s1="$a52_h1/.claude"; mkdir -p "$a52_s1"
  a52_ok="A record in a snapshot the fold really wrote"
  a52_odd="A record in a hand-maintained file that merely matches the glob"
  a52_rec "$a52_ok"  > "$a52_s1/pending-deviations-5201.log"
  a52_rec "$a52_odd" > "$a52_s1/pending-deviations-notes-2026-Q1.log"
  consumer_dismiss "$a52_h1" deviation "$a52_ok"  >/dev/null 2>&1
  consumer_dismiss "$a52_h1" deviation "$a52_odd" >/dev/null 2>&1
  A52_OUT1=$(consumer_run "$a52_h1" attended)
  [[ -e "$a52_s1/pending-deviations-notes-2026-Q1.log" ]] \
    || A52_FAILURES+=("(1) a file whose name is NOT \`pending-deviations-<digits>.log\` was swept and ARCHIVED — the fold never writes that name, so it belongs to a human and the mv took it out of the directory they left it in: $A52_OUT1")
  [[ "$(consumer_archived "$a52_s1")" -eq 1 ]] \
    || A52_FAILURES+=("(1) expected exactly the ONE legitimately-named snapshot to archive, got $(consumer_archived "$a52_s1"): $A52_OUT1")
  rm -rf "$a52_h1"

  # --- (2) A DIRECTORY WEARING A SNAPSHOT'S NAME IS NOT A SNAPSHOT ---
  # `-f` is what excludes it, and it must exclude it AT THE SOURCE: a later
  # per-file guard walks the already-expanded list, and `ls -t` handed a
  # DIRECTORY lists its CONTENTS as bare basenames which then resolve against
  # CWD. Here the observable is simpler and just as binding — a directory that
  # reaches the sweep is counted as an UNREADABLE snapshot, so the run reports
  # outstanding work that does not exist and can never be drained.
  a52_h2=$(mktemp -d); a52_s2="$a52_h2/.claude"; mkdir -p "$a52_s2/pending-deviations-5277.log"
  printf 'not a snapshot\n' > "$a52_s2/pending-deviations-5277.log/inside.txt"
  a52_rec "$a52_ok" > "$a52_s2/pending-deviations-5202.log"
  consumer_dismiss "$a52_h2" deviation "$a52_ok" >/dev/null 2>&1
  A52_OUT2=$(consumer_run "$a52_h2" attended)
  printf '%s\n' "$A52_OUT2" | grep -q 'unreadable=0 ' \
    || A52_FAILURES+=("(2) a DIRECTORY named like a snapshot was swept and counted as an unreadable file — the \`-f\` test must exclude it at the source, before the ordering pass inherits it: $A52_OUT2")
  rm -rf "$a52_h2"

  # --- (3) A SORT MAY PERMUTE THE SET; IT MAY NEVER ADD TO IT ---
  # The old form was an unquoted command substitution inside an array
  # assignment, so `ls -t` output was subject to word splitting and pathname
  # expansion. Reading line-oriented fixes those; the membership test is what
  # fixes INJECTION, because a permutation of a set cannot contain a non-member.
  # The stub swaps snapshot B for a file in a working tree — same line count, so
  # the fail-closed count check cannot be what rejects it.
  a52_h3=$(mktemp -d); a52_s3="$a52_h3/.claude"; mkdir -p "$a52_s3" "$a52_h3/worktree"
  a52_a="Record A, a real snapshot the fold wrote"
  a52_b="Record B, a second real snapshot the fold wrote"
  a52_v="Record V, living in a working tree the sweep has no business touching"
  a52_rec "$a52_a" > "$a52_s3/pending-deviations-5203.log"
  a52_rec "$a52_b" > "$a52_s3/pending-deviations-5204.log"
  a52_rec "$a52_v" > "$a52_h3/worktree/victim.log"
  for _b in "$a52_a" "$a52_b" "$a52_v"; do consumer_dismiss "$a52_h3" deviation "$_b" >/dev/null 2>&1; done
  a52_bin3="$a52_h3/bin"; mkdir -p "$a52_bin3"
  {
    printf '#!/bin/sh\n'
    printf '# Answers any `ls` with a set the caller never passed in: one real\n'
    printf '# member, and one path from outside the state dir entirely.\n'
    printf 'printf "%%s\\\\n" "%s" "%s"\n' "$a52_s3/pending-deviations-5203.log" "$a52_h3/worktree/victim.log"
  } > "$a52_bin3/ls"
  chmod +x "$a52_bin3/ls"
  A52_OUT3=$(HOME="$a52_h3" PATH="$a52_bin3:$PATH" "$a52_shell" "$CONSUMER_SCRIPT" surface baselito ai-engineering 4242 MERGED attended 2>&1)
  [[ -e "$a52_h3/worktree/victim.log" ]] \
    || A52_FAILURES+=("(3) a path the ordering pass INVENTED was swept and archived — the file was moved out of the working tree it lived in, which is the unquoted-\`ls\` class the membership test exists to close: $A52_OUT3")
  [[ "$(consumer_queued "$a52_s3")" -eq 0 ]] \
    || A52_FAILURES+=("(3) $(consumer_queued "$a52_s3") of the 2 REAL snapshots were left behind — an ordering pass that substitutes a non-member for a member also DROPS the member it replaced, and a dropped snapshot is a stranded record: $A52_OUT3")
  rm -rf "$a52_h3"

  # --- (4) A LOSSY ORDERING PASS KEEPS THE UNSORTED VALIDATED SET ---
  # If the permutation does not return exactly what went into it — an `ls`
  # failure, an unreadable directory, a name holding a literal newline — the run
  # must fall back to the validated set it already had. Accepting a SHORTER
  # result silently drops snapshots, and recency in a listing is worth far less
  # than a record. The stub returns one of the two members.
  a52_h4=$(mktemp -d); a52_s4="$a52_h4/.claude"; mkdir -p "$a52_s4"
  a52_rec "$a52_a" > "$a52_s4/pending-deviations-5205.log"
  a52_rec "$a52_b" > "$a52_s4/pending-deviations-5206.log"
  consumer_dismiss "$a52_h4" deviation "$a52_a" >/dev/null 2>&1
  consumer_dismiss "$a52_h4" deviation "$a52_b" >/dev/null 2>&1
  a52_bin4="$a52_h4/bin"; mkdir -p "$a52_bin4"
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\\\n" "%s"\n' "$a52_s4/pending-deviations-5205.log"
  } > "$a52_bin4/ls"
  chmod +x "$a52_bin4/ls"
  A52_OUT4=$(HOME="$a52_h4" PATH="$a52_bin4:$PATH" "$a52_shell" "$CONSUMER_SCRIPT" surface baselito ai-engineering 4242 MERGED attended 2>&1)
  [[ "$(consumer_archived "$a52_s4")" -eq 2 ]] \
    || A52_FAILURES+=("(4) an ordering pass that returned FEWER paths than it was given was accepted, so only $(consumer_archived "$a52_s4") of 2 fully-decided snapshots were seen at all — the dropped one is invisible to this run and to every count derived from it: $A52_OUT4")
  [[ "$(consumer_queued "$a52_s4")" -eq 0 ]] \
    || A52_FAILURES+=("(4) $(consumer_queued "$a52_s4") snapshot(s) were stranded by a lossy ordering pass: $A52_OUT4")
  rm -rf "$a52_h4"

  # --- (5) CONTROL (green both ways by design): the ordinary two-snapshot sweep ---
  # Legs (3) and (4) both assert "nothing was stranded", which is also true of a
  # sweep that archives everything for the wrong reasons; and legs (1) and (2)
  # assert files were NOT touched, which a broken sweep satisfies trivially. This
  # leg requires the ordinary path — two snapshots, real `ls`, both decided — to
  # still work end to end.
  a52_h5=$(mktemp -d); a52_s5="$a52_h5/.claude"; mkdir -p "$a52_s5"
  a52_rec "$a52_a" > "$a52_s5/pending-deviations-5207.log"
  a52_rec "$a52_b" > "$a52_s5/pending-deviations-5208.log"
  consumer_dismiss "$a52_h5" deviation "$a52_a" >/dev/null 2>&1
  consumer_dismiss "$a52_h5" deviation "$a52_b" >/dev/null 2>&1
  A52_OUT5=$(consumer_run "$a52_h5" attended)
  [[ "$(consumer_archived "$a52_s5")" -eq 2 ]] \
    || A52_FAILURES+=("(5 CONTROL) two ordinary fully-decided snapshots did not both retire — every leg above would then pass against a sweep that has stopped sweeping: $A52_OUT5")
  rm -rf "$a52_h5"

  if [[ ${#A52_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: a glob-matching file the fold never named and a DIRECTORY wearing a snapshot name were both left alone; an \`ls\` that substituted an outside path for a real member neither relocated that path nor stranded the member it displaced; an \`ls\` that returned fewer paths than it was given fell back to the validated set with nothing dropped; and the ordinary two-snapshot sweep still retired both)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A52_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-53: THE TWO-CODE EXIT CONTRACT, IN BOTH DIRECTIONS
#
# The script's header commits to exactly two exit codes and spends a paragraph
# on why there is no third: 0 for "the run completed, INCLUDING a run a gate
# refused", 2 for a CALLER bug that writes nothing. A mutation sweep found 5 of
# the 10 paths unpinned — and, worse, found that **nothing at all pinned the
# half the contract is FOR**: no test asserted that a gate refusal exits 0
# rather than non-zero. Flipping `exit 2` on an unknown subcommand to `exit 0`
# also left the suite green.
#
# Both directions matter, and they fail in opposite ways:
#   - a refusal that exits NON-ZERO makes `commands/review-pr.md` read a
#     deliberate, self-healing skip as a failed step. That is a real bug this
#     loop already had: a successful surface once inherited exit 1 from a
#     trailing short-circuit test and looked like a failed step to its caller.
#   - a caller bug that exits ZERO is worse still — a typo'd MODE, a missing
#     argument or a malformed hash reports success while having written nothing,
#     so the agent believes a dismissal it never recorded.
#
# `commands/review-pr.md:1546` flattens these two classes into one list, which
# is exactly the reading this test forbids: the first group exits 2, the
# symlink refusals exit 0.
#
# GUARD → MUTATION → this test goes RED (verified in an isolated copy):
#   dispatch `exit 2` on an unknown subcommand   → `exit 0`        leg (A5)
# ---------------------------------------------------------------------------
TC="TC-STL-53: a caller bug exits 2 and writes nothing; a gate refusal exits 0 (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
else
  A53_FAILURES=()
  a53_home=$(mktemp -d); a53_state="$a53_home/.claude"; mkdir -p "$a53_state"
  a53_body="An ordinary deviation used to exercise the exit contract"
  a53_hash=$(printf '%s' "$a53_body" | shasum -a 256 2>/dev/null | awk '{print $1}')
  printf '{"ts":"2026-01-01T00:00:00Z","phase":"Implementation","body":"%s"}\n' "$a53_body" \
    > "$a53_state/pending-deviations-5353.log"

  # stdin is closed on every invocation: `dismiss` reads its body from stdin, so
  # a leg that reaches the read without a redirect would hang the whole suite
  # rather than fail it.
  a53_run() {  # a53_run <home> <args...>  → sets A53_OUT / A53_RC
    local h="$1"; shift
    A53_OUT=$(HOME="$h" bash "$CONSUMER_SCRIPT" "$@" 2>&1 </dev/null)
    A53_RC=$?
  }

  # === GROUP A: CALLER BUGS — exit 2, and NOTHING is written ==================
  # Each of these is a distinct dispatch or argument path. `-h`/`--help`/`help`
  # exit 2 rather than 0 deliberately: a caller that asked for usage did not ask
  # the script to do its job, so a 0 there would be indistinguishable from a
  # completed run to a caller that only reads the status.
  a53_expect2() {  # a53_expect2 <label> <args...>
    local label="$1"; shift
    a53_run "$a53_home" "$@"
    [[ "$A53_RC" -eq 2 ]] \
      || A53_FAILURES+=("(A) $label: expected exit 2 (USAGE ERROR), got $A53_RC — a caller bug that reports success is a dismissal the agent believes and the log never received: $A53_OUT")
  }
  # (A1) no subcommand at all
  A53_OUT=$(HOME="$a53_home" bash "$CONSUMER_SCRIPT" 2>&1 </dev/null); A53_RC=$?
  [[ "$A53_RC" -eq 2 ]] \
    || A53_FAILURES+=("(A1) invoking the script with NO subcommand exited $A53_RC, expected 2: $A53_OUT")
  printf '%s\n' "$A53_OUT" | grep -q 'usage:' \
    || A53_FAILURES+=("(A1) invoking the script with NO subcommand printed no usage text: $A53_OUT")
  a53_expect2 "-h"                       -h
  a53_expect2 "--help"                   --help
  a53_expect2 "help"                     help
  a53_expect2 "unknown subcommand"       frobnicate
  a53_expect2 "surface with missing args" surface baselito ai-engineering
  a53_expect2 "surface with an unparseable MODE" surface baselito ai-engineering 4242 MERGED sometimes
  a53_expect2 "archive with missing args" archive baselito
  a53_expect2 "lessons with missing args" lessons baselito ai-engineering 4242
  a53_expect2 "dismiss with an unknown kind" dismiss notakind "$a53_hash"
  a53_expect2 "dismiss with a display-length hash" dismiss deviation "${a53_hash:0:8}"

  # ⛔ "A USAGE ERROR WRITES NOTHING" IS PART OF THE CONTRACT, NOT A SIDE EFFECT. ⛔
  # Every leg above ran against the same state dir, so if any of them had
  # written, a dismissed log would exist here — and `cmd_dismiss` is the only
  # writer, so its refusals are the only ones that could have created one.
  [[ ! -e "$a53_state/dismissed-deviations.log" ]] \
    || A53_FAILURES+=("(A) a dismissed-deviations.log exists after nothing but USAGE ERRORS — an exit-2 path wrote to the highest-privilege store in the loop: $(cat "$a53_state/dismissed-deviations.log" 2>/dev/null)")
  [[ ! -e "$a53_state/dismissed-lessons.log" ]] \
    || A53_FAILURES+=("(A) a dismissed-lessons.log exists after nothing but USAGE ERRORS")

  # === GROUP B: GATE REFUSALS — exit 0, with the refusal on the summary line ==
  # ⛔ THIS IS THE HALF THE TWO-CODE CONTRACT EXISTS FOR, AND NOTHING PINNED IT. ⛔
  a53_expect_refusal() {  # a53_expect_refusal <label> <home> <token> <args...>
    local label="$1" h="$2" token="$3"; shift 3
    a53_run "$h" "$@"
    [[ "$A53_RC" -eq 0 ]] \
      || A53_FAILURES+=("(B) $label: a REFUSAL exited $A53_RC — callers must never read a refused run as a failed step, and this loop already shipped that bug once: $A53_OUT")
    printf '%s\n' "$A53_OUT" | grep -q "CONSUME-DEVIATIONS: $token" \
      || A53_FAILURES+=("(B) $label: expected the summary token \`$token\`, which is how a caller tells a refusal from a completed run when both exit 0: $A53_OUT")
  }
  a53_expect_refusal "surface from a project repo"  "$a53_home" "surface refused=not-toolbox-repo"   surface someorg someproject 4242 MERGED attended
  a53_expect_refusal "surface on a non-merged PR"   "$a53_home" "surface refused=pr-not-merged"      surface baselito ai-engineering 4242 CLOSED attended
  a53_expect_refusal "archive from a project repo"  "$a53_home" "archive refused=not-toolbox-repo"   archive someorg someproject
  a53_expect_refusal "lessons from a project repo"  "$a53_home" "lessons refused=not-toolbox-repo"   lessons someorg someproject 4242 MERGED "$a53_home"
  a53_expect_refusal "lessons on a non-merged PR"   "$a53_home" "lessons refused=pr-not-merged"      lessons baselito ai-engineering 4242 CLOSED "$a53_home"

  # The symlink refusals need their own state dirs, one per entry point.
  a53_symhome() {  # a53_symhome  → prints a HOME whose .claude is a symlink
    local h; h=$(mktemp -d); mkdir -p "$h/real-claude"; ln -s "$h/real-claude" "$h/.claude"
    printf '{"ts":"2026-01-01T00:00:00Z","phase":"Implementation","body":"%s"}\n' "$a53_body" \
      > "$h/real-claude/pending-deviations-5353.log"
    printf '%s' "$h"
  }
  a53_sh1=$(a53_symhome)
  a53_expect_refusal "surface with a symlinked state dir" "$a53_sh1" "surface refused=symlinked-state-dir" surface baselito ai-engineering 4242 MERGED attended
  a53_sh2=$(a53_symhome)
  a53_expect_refusal "archive with a symlinked state dir" "$a53_sh2" "archive refused=symlinked-state-dir" archive baselito ai-engineering
  a53_sh3=$(a53_symhome)
  a53_expect_refusal "lessons with a symlinked state dir" "$a53_sh3" "lessons refused=symlinked-state-dir" lessons baselito ai-engineering 4242 MERGED "$a53_sh3"
  rm -rf "$a53_sh1" "$a53_sh2" "$a53_sh3"

  # `dismiss` past every validation, refused only by the symlinked log: the
  # write is declined, the caller is told, and the status is still 0 because
  # the record simply stays undecided and resurfaces.
  a53_dh=$(mktemp -d); mkdir -p "$a53_dh/.claude" "$a53_dh/outside"
  : > "$a53_dh/outside/planted.log"
  ln -s "$a53_dh/outside/planted.log" "$a53_dh/.claude/dismissed-deviations.log"
  A53_OUT=$(printf '%s' "$a53_body" | HOME="$a53_dh" bash "$CONSUMER_SCRIPT" dismiss deviation "$a53_hash" 2>&1); A53_RC=$?
  [[ "$A53_RC" -eq 0 ]] \
    || A53_FAILURES+=("(B) dismiss onto a symlinked log exited $A53_RC — the refusal costs exactly one dismissal and is not a caller bug, so it belongs on the 0 side of the contract: $A53_OUT")
  printf '%s\n' "$A53_OUT" | grep -q 'CONSUME-DEVIATIONS: dismiss refused=symlink' \
    || A53_FAILURES+=("(B) dismiss onto a symlinked log did not report \`refused=symlink\`: $A53_OUT")
  rm -rf "$a53_dh"

  # === GROUP C: CONTROL — the ordinary completed runs also exit 0 =============
  # Without this, every leg in group B is satisfied by a script that exits 0 no
  # matter what, and group A by one that exits 2 no matter what.
  if command -v jq >/dev/null 2>&1; then
    a53_run "$a53_home" surface baselito ai-engineering 4242 MERGED attended
    [[ "$A53_RC" -eq 0 ]] \
      || A53_FAILURES+=("(C CONTROL) an ordinary successful surface exited $A53_RC: $A53_OUT")
    printf '%s\n' "$A53_OUT" | grep -q 'CONSUME-DEVIATIONS: surface surfaced=1 ' \
      || A53_FAILURES+=("(C CONTROL) an ordinary surface did not surface its one record — every refusal leg above would then pass against a script that refuses everything: $A53_OUT")
    A53_OUT=$(printf '%s' "$a53_body" | HOME="$a53_home" bash "$CONSUMER_SCRIPT" dismiss deviation "$a53_hash" 2>&1); A53_RC=$?
    [[ "$A53_RC" -eq 0 ]] \
      || A53_FAILURES+=("(C CONTROL) an ordinary dismissal exited $A53_RC: $A53_OUT")
    printf '%s\n' "$A53_OUT" | grep -q 'CONSUME-DEVIATIONS: dismiss recorded=' \
      || A53_FAILURES+=("(C CONTROL) an ordinary dismissal did not report \`recorded=\` — group A's 'nothing was written' assertion would then hold for a writer that never writes: $A53_OUT")
  fi
  rm -rf "$a53_home"

  if [[ ${#A53_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: eleven caller-bug paths each exited 2 leaving both dismissed logs non-existent, nine gate refusals across all four subcommands each exited 0 carrying their own summary token, and an ordinary surface and an ordinary dismissal still exited 0 having done their work)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A53_FAILURES[@]}")"
  fi
fi

# ===========================================================================
# ⛔ TC-STL-54 … TC-STL-64 — THE RED BLOCK. ⛔
#
# These describe behaviour that DOES NOT YET EXIST at 906a6c3. They were
# written and committed BEFORE the production fixes, with their expected
# direction recorded, so that a "must FAIL" that quietly passes is caught
# before any fix is written rather than after (round-5 lesson, and
# `feedback_verify_the_real_path`).
#
# DIRECTION TABLE — verified by running the suite at 906a6c3:
#
#   TC-STL-54  C-1 forward: an unreadable snapshot is never deleted    FAIL
#   TC-STL-55  C-1 inverse: a clean drained queue STILL deletes        PASS (stays)
#   TC-STL-56  F2c: per-file accounting, not one run-wide counter      FAIL
#   TC-STL-57  C-6: a name the writer never writes is not a snapshot   FAIL
#   TC-STL-58  C-5: a symlinked lessons yml is not an off switch       FAIL
#   TC-STL-59  C-2 forward: a failed dismissal append is REPORTED      FAIL
#   TC-STL-60  C-2 inverse: a writable log still records               PASS (stays)
#   TC-STL-61  C-3a: the `defer` subcommand owns the deferred queue    FAIL
#   TC-STL-62  C-4: verify.sh detects an INSTALLED COPY THAT DIFFERS   FAIL
#   TC-STL-63  C-7: the full digest reaches stdout                     FAIL
#   TC-STL-64  C-9: an unreadable dismissed log is reported            FAIL
#
# ⛔ THE TWO "PASS" ROWS MATTER AS MUCH AS THE NINE "FAIL" ROWS (TL-0011). ⛔
# Without TC-STL-55 the C-1 fix can be "achieved" by disabling the cleanup
# altogether; without TC-STL-60 the C-2 fix can be "achieved" by never
# reporting a success. Both are the direction nobody changed on purpose.
# ===========================================================================

# ---------------------------------------------------------------------------
# TC-STL-54: `cmd_lessons` MUST NOT DELETE A SNAPSHOT IT COULD NOT READ
#
# The two reproductions, run end to end by the orchestrator against a throwaway
# HOME before this was written:
#
#   A. `pending-lessons-900.jsonl` (one record, already dismissed) alongside
#      `pending-lessons-901.jsonl` (one DISTINCT record, never dismissed,
#      `chmod 000`). At 906a6c3: `candidates=0 parse_failures=0 snapshots=2
#      deleted=yes`, exit 0, and 901 is GONE. `snapshots=2` proves it counted
#      the file it could not read.
#   B. Three `chmod 000` snapshots plus a `chmod 000` deferred queue, with
#      `dismissed-lessons.log` EMPTY. All four destroyed having read NOTHING,
#      while asserting every record was "already learned or dismissed" against
#      a log with zero entries.
#
# WHY IT HAPPENS: no `-r` test in the enumeration; `cat`'s error suppressed and
# its exit status discarded (process substitution — `pipefail` does not reach
# it and nothing waits on it); an unread file yields NEITHER a candidate NOR a
# parse failure, so it satisfies both halves of the delete condition; and
# `rm -f` then takes the per-PR snapshots AND the cross-PR deferred queue, the
# file holding records a human explicitly chose to hold.
#
# The SIBLING function is the template and already has all of it —
# `cmd_surface` carries the `-r` test, an `unreadable` counter, a user-facing
# message, and a comment reading "⛔ UNREADABLE IS NOT EMPTY — FAIL CLOSED, AND
# SAY SO". One file, two halves: the reviewed half fails closed and says so,
# the unreviewed half deletes and reports success.
#
# WHAT THIS TEST REQUIRES (the summary keys are the contract, so a test has
# something to bind to instead of inferring intent from an end state):
#   `unreadable=<n>` on the lessons summary line, counting the DEFERRED QUEUE
#   too — it is `cat`'d and `rm`'d unconditionally today and it is the
#   highest-value file in the queue;
#   `deleted=yes` with `unreadable>0` UNREACHABLE;
#   the "all capture records already learned or dismissed" line NOT printed
#   when nothing was read, because that claim is falsifiable from the script's
#   own state and nothing checks it.
# ---------------------------------------------------------------------------
TC="TC-STL-54: an unreadable lessons snapshot is preserved and reported, never deleted (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the lessons half parses JSONL with jq, so this behavioural test cannot run"
elif ! perms_are_enforced; then
  fail_test "$TC" "SETUP: chmod 000/444 are not enforced for this user (running as root, or a filesystem that ignores mode bits) — a chmod-based fixture would test the ordinary path and pass for the wrong reason"
else
  A54_FAILURES=()
  a54_lessons() { HOME="$1" bash "$CONSUMER_SCRIPT" lessons baselito ai-engineering 4242 MERGED "$1" 2>&1; }
  a54_rec() { printf '{"finding":"%s","verdict":"fixed","origin":"automated-review"}\n' "$1"; }

  # --- REPRODUCTION A: one unreadable victim among readable, dismissed records ---
  a54_ha=$(mktemp -d); a54_sa="$a54_ha/.claude"; mkdir -p "$a54_sa"
  a54_seen="A finding that really was dismissed by a human"
  a54_victim="A DISTINCT finding nobody has ever seen, in a file nobody can read"
  a54_rec "$a54_seen"   > "$a54_sa/pending-lessons-900.jsonl"
  a54_rec "$a54_victim" > "$a54_sa/pending-lessons-901.jsonl"
  consumer_dismiss "$a54_ha" lesson "$a54_seen" >/dev/null 2>&1
  chmod 000 "$a54_sa/pending-lessons-901.jsonl"
  A54_OUTA=$(a54_lessons "$a54_ha")
  [[ -e "$a54_sa/pending-lessons-901.jsonl" ]] \
    || A54_FAILURES+=("(A) the UNREADABLE snapshot was DELETED — nothing read it, so nothing knows what it held; this is the only unrecoverable operation in the file and it ran on a file the run could not open: $A54_OUTA")
  printf '%s\n' "$A54_OUTA" | grep -q 'unreadable=1' \
    || A54_FAILURES+=("(A) the summary line does not report \`unreadable=1\` — the deviation half counts and names unreadable files; without the same key here a caller cannot tell a drained queue from an unopenable one: $A54_OUTA")
  printf '%s\n' "$A54_OUTA" | grep -q 'deleted=no' \
    || A54_FAILURES+=("(A) the summary reported a deletion on a run that could not read every file — \`deleted=yes\` with \`unreadable>0\` must be unreachable by construction, not merely unlikely: $A54_OUTA")
  printf '%s\n' "$A54_OUTA" | grep -q 'already learned or dismissed' \
    && A54_FAILURES+=("(A) the run claimed every capture record was 'already learned or dismissed' while one file was never opened — the claim is falsifiable from the script's own state: $A54_OUTA")
  chmod 644 "$a54_sa/pending-lessons-901.jsonl" 2>/dev/null
  rm -rf "$a54_ha"

  # --- REPRODUCTION B: the degenerate case, and it is worse ---
  # Nothing was read AT ALL, and the dismissed log is EMPTY — zero dismissals
  # have ever been recorded on this machine — yet every file is destroyed on the
  # assertion that all their records were already decided.
  a54_hb=$(mktemp -d); a54_sb="$a54_hb/.claude"; mkdir -p "$a54_sb"
  : > "$a54_sb/dismissed-lessons.log"
  for _i in 910 911 912; do
    a54_rec "An undecided finding in snapshot $_i" > "$a54_sb/pending-lessons-$_i.jsonl"
  done
  a54_rec "A finding a human explicitly DEFERRED to a later PR" > "$a54_sb/pending-lessons-deferred.jsonl"
  chmod 000 "$a54_sb"/pending-lessons-910.jsonl "$a54_sb"/pending-lessons-911.jsonl \
            "$a54_sb"/pending-lessons-912.jsonl "$a54_sb"/pending-lessons-deferred.jsonl
  A54_OUTB=$(a54_lessons "$a54_hb")
  for _f in pending-lessons-910.jsonl pending-lessons-911.jsonl pending-lessons-912.jsonl pending-lessons-deferred.jsonl; do
    [[ -e "$a54_sb/$_f" ]] \
      || A54_FAILURES+=("(B) $_f was DELETED by a run that read nothing at all, against an EMPTY dismissed log: $A54_OUTB")
  done
  printf '%s\n' "$A54_OUTB" | grep -q 'unreadable=4' \
    || A54_FAILURES+=("(B) the summary does not report \`unreadable=4\` — the cross-PR deferred queue is \`cat\`'d and \`rm\`'d on exactly the same terms as the per-PR snapshots, so it must be covered by the same counter: $A54_OUTB")
  printf '%s\n' "$A54_OUTB" | grep -q 'deleted=no' \
    || A54_FAILURES+=("(B) a run that read NOTHING reported a deletion: $A54_OUTB")
  printf '%s\n' "$A54_OUTB" | grep -q 'already learned or dismissed' \
    && A54_FAILURES+=("(B) a run that read NOTHING claimed every record was already learned or dismissed, against a dismissed log holding zero entries: $A54_OUTB")
  chmod 644 "$a54_sb"/pending-lessons-*.jsonl 2>/dev/null
  rm -rf "$a54_hb"

  if [[ ${#A54_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: an unreadable snapshot beside a readable dismissed one was preserved, counted and reported rather than deleted; and an all-unreadable queue with an EMPTY dismissed log lost nothing and claimed nothing)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A54_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-55: THE INVERSE — A GENUINELY DRAINED QUEUE MUST STILL BE REMOVED
#
# ⛔ TEST THE DIRECTION YOU DID NOT JUST CHANGE (TL-0011). ⛔ TC-STL-54 can be
# satisfied by a `cmd_lessons` that has simply stopped deleting anything, and
# that failure is invisible: the queue grows, every merge re-reads and re-filters
# the same dead records, and nothing ever reports a problem. This leg is the
# control, and it is GREEN BOTH BEFORE AND AFTER the C-1 fix by design.
#
# (TC-STL-46 leg (3) asserts the same property as one leg of a nine-leg test.
# It is restated here as its own test case because the direction table for the
# C-1 fix needs a row that is independently visible in the pass/fail output.)
# ---------------------------------------------------------------------------
TC="TC-STL-55: a fully-readable, fully-dismissed lessons queue is still removed (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the lessons half parses JSONL with jq, so this behavioural test cannot run"
else
  A55_FAILURES=()
  a55_h=$(mktemp -d); a55_s="$a55_h/.claude"; mkdir -p "$a55_s"
  a55_f="A finding that was read cleanly and then dismissed by a human"
  printf '{"finding":"%s","verdict":"fixed","origin":"automated-review"}\n' "$a55_f" > "$a55_s/pending-lessons-955.jsonl"
  consumer_dismiss "$a55_h" lesson "$a55_f" >/dev/null 2>&1
  A55_OUT=$(HOME="$a55_h" bash "$CONSUMER_SCRIPT" lessons baselito ai-engineering 4242 MERGED "$a55_h" 2>&1)
  [[ ! -e "$a55_s/pending-lessons-955.jsonl" ]] \
    || A55_FAILURES+=("a queue whose every record was READ, parsed and dismissed was NOT removed — the C-1 fix must not be bought by disabling the cleanup, or every future merge re-reads the same dead records forever: $A55_OUT")
  printf '%s\n' "$A55_OUT" | grep -q 'deleted=yes' \
    || A55_FAILURES+=("the summary did not report deleted=yes on a genuinely drained queue: $A55_OUT")
  rm -rf "$a55_h"

  if [[ ${#A55_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: a queue whose single record was read, parsed and dismissed was removed and reported deleted=yes — the direction the C-1 fix must not break)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A55_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-56: ONE MALFORMED FILE MUST NOT PIN A CLEAN, FULLY-DRAINED ONE
#
# `parse_failures` is a single RUN-WIDE counter over the CONCATENATION of every
# snapshot (`cat` in one process substitution), yet it gates a delete applied to
# ALL of them. The deviation half is per-file for exactly this reason.
#
# Measured: one malformed record in the deferred queue pinned a fully-drained
# `pending-lessons-888.jsonl` forever — and `selfimprovement-backlog.sh` then
# blamed the innocent file, because the deferred queue is excluded from its
# count. So the user is told to drain a file that is already drained, by a
# command that cannot drain it.
#
# The fix is per-file accounting: read each file with its own loop, keep
# per-file `records` / `failures` / `unreadable`, and delete a file only when
# THAT file yielded at least one record, zero failures and zero read errors.
# Because the current read routes through `cat` inside a process substitution, a
# mid-read I/O error is invisible even WITH an `-r` test — the per-file loop is
# what makes it observable at all.
# ---------------------------------------------------------------------------
TC="TC-STL-56: a malformed record pins its OWN file, not the whole queue (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the lessons half parses JSONL with jq, so this behavioural test cannot run"
else
  A56_FAILURES=()
  a56_h=$(mktemp -d); a56_s="$a56_h/.claude"; mkdir -p "$a56_s"
  a56_clean="A finding in a file that is clean and completely drained"
  printf '{"finding":"%s","verdict":"fixed","origin":"automated-review"}\n' "$a56_clean" > "$a56_s/pending-lessons-888.jsonl"
  consumer_dismiss "$a56_h" lesson "$a56_clean" >/dev/null 2>&1
  # The malformed record lives in a DIFFERENT file — the cross-PR deferred queue,
  # which is also the file `selfimprovement-backlog.sh` does not count, so the
  # warning the user sees names the innocent snapshot.
  printf 'this line is not json at all\n' > "$a56_s/pending-lessons-deferred.jsonl"
  A56_OUT=$(HOME="$a56_h" bash "$CONSUMER_SCRIPT" lessons baselito ai-engineering 4242 MERGED "$a56_h" 2>&1)
  [[ ! -e "$a56_s/pending-lessons-888.jsonl" ]] \
    || A56_FAILURES+=("a file that yielded one record, zero parse failures and zero read errors was NOT removed, because a DIFFERENT file in the same run held a malformed line — a run-wide counter gating a per-file delete pins clean files forever, and the backlog reporter then blames the file that is already drained: $A56_OUT")
  [[ -e "$a56_s/pending-lessons-deferred.jsonl" ]] \
    || A56_FAILURES+=("the file that actually holds the malformed record was DELETED — a line nobody could parse may hold a finding, and deleting it is the silent loss this loop exists to end: $A56_OUT")
  printf '%s\n' "$A56_OUT" | grep -q 'parse_failures=1' \
    || A56_FAILURES+=("the summary did not report the one parse failure: $A56_OUT")
  rm -rf "$a56_h"

  if [[ ${#A56_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: a clean fully-dismissed snapshot was removed while the separate file holding the unparseable record was preserved and reported)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A56_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-57: A NAME THE WRITER NEVER WRITES IS NOT A LESSONS SNAPSHOT
#
# The deviation half validates every swept filename against
# `DEVNAME_RE='^pending-deviations-[0-9]+\.log$'` and carries a comment
# explaining why. The lessons half filters only `-f` / `! -L`, and the operation
# downstream is `rm -f`.
#
# Verified: a hand-maintained `pending-lessons-archive-2026-Q1-manual-notes.jsonl`
# was read as a snapshot and DELETED. The fix is one regex —
# `^pending-lessons-[0-9]+\.jsonl$` — with the deferred queue keeping its exact
# -path handling. Promoted from MEDIUM because the downstream op is the file's
# only unrecoverable one.
# ---------------------------------------------------------------------------
TC="TC-STL-57: the lessons sweep deletes only files the fold actually wrote (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the lessons half parses JSONL with jq, so this behavioural test cannot run"
else
  A57_FAILURES=()
  a57_h=$(mktemp -d); a57_s="$a57_h/.claude"; mkdir -p "$a57_s"
  a57_manual="A note somebody keeps by hand in a file that merely matches the glob"
  a57_real="A finding the post-merge fold really wrote"
  printf '{"finding":"%s","verdict":"fixed","origin":"human"}\n' "$a57_manual" \
    > "$a57_s/pending-lessons-archive-2026-Q1-manual-notes.jsonl"
  printf '{"finding":"%s","verdict":"fixed","origin":"automated-review"}\n' "$a57_real" \
    > "$a57_s/pending-lessons-777.jsonl"
  consumer_dismiss "$a57_h" lesson "$a57_manual" >/dev/null 2>&1
  consumer_dismiss "$a57_h" lesson "$a57_real"   >/dev/null 2>&1
  A57_OUT=$(HOME="$a57_h" bash "$CONSUMER_SCRIPT" lessons baselito ai-engineering 4242 MERGED "$a57_h" 2>&1)
  [[ -e "$a57_s/pending-lessons-archive-2026-Q1-manual-notes.jsonl" ]] \
    || A57_FAILURES+=("a file whose name is NOT \`pending-lessons-<digits>.jsonl\` was read as a snapshot and DELETED — the fold never writes that name, so the file belonged to a human and the rm was unrecoverable: $A57_OUT")
  [[ ! -e "$a57_s/pending-lessons-777.jsonl" ]] \
    || A57_FAILURES+=("the legitimately-named, fully-dismissed snapshot was NOT removed — the name rule must exclude strangers, not stop the cleanup: $A57_OUT")
  printf '%s\n' "$A57_OUT" | grep -q 'snapshots=1' \
    || A57_FAILURES+=("the summary counted more than the one legitimately-named snapshot, so the count the user is shown includes files this loop does not own: $A57_OUT")
  rm -rf "$a57_h"

  if [[ ${#A57_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: a hand-maintained file matching the lessons glob was neither counted nor deleted, while the correctly-named fully-dismissed snapshot still was)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A57_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-58: A SYMLINKED `knowledge/toolbox-lessons.yml` IS NOT A STATE FILE
#
# `cmd_lessons` NEVER OPENS that file. Its only other use is a display string.
# So the `-L "$lessons_yml"` operand in the symlink predicate protects nothing
# and supplies only an off switch — and `knowledge/toolbox-lessons.yml` is a
# GIT-TRACKED path, and git stores symlinks natively (`120000 blob`).
#
# So ANY merged PR — including one from an external fork — that turns that path
# into a symlink disables the lessons half on every machine, forever, silently:
# exit 0, `refused=symlinked-state-file`, snapshots preserved and accumulating,
# indistinguishable from a genuine tamper refusal. Verified with an explicit
# REPO_ROOT and with the `$PWD` default.
#
# Leg (2) is the control that keeps the fix narrow: the other three operands in
# that predicate ARE state, and a fix that removed the whole test would pass
# leg (1) while re-opening TC-STL-50 leg (3).
# ---------------------------------------------------------------------------
TC="TC-STL-58: a symlinked lessons yml is not a merged-PR-reachable off switch (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the lessons half parses JSONL with jq, so this behavioural test cannot run"
else
  A58_FAILURES=()
  a58_f="A brand-new finding that the run must still be able to propose"

  # --- (1) a symlinked lessons yml must NOT stop the run ---
  a58_h1=$(mktemp -d); a58_s1="$a58_h1/.claude"; mkdir -p "$a58_s1" "$a58_h1/knowledge" "$a58_h1/elsewhere"
  printf 'schema_version: 1\nlessons: []\n' > "$a58_h1/elsewhere/toolbox-lessons.yml"
  ln -s "$a58_h1/elsewhere/toolbox-lessons.yml" "$a58_h1/knowledge/toolbox-lessons.yml"
  printf '{"finding":"%s","verdict":"fixed","origin":"automated-review"}\n' "$a58_f" > "$a58_s1/pending-lessons-580.jsonl"
  A58_OUT1=$(HOME="$a58_h1" bash "$CONSUMER_SCRIPT" lessons baselito ai-engineering 4242 MERGED "$a58_h1" 2>&1)
  printf '%s\n' "$A58_OUT1" | grep -q 'refused=symlinked-state-file' \
    && A58_FAILURES+=("(1) a SYMLINKED knowledge/toolbox-lessons.yml refused the whole run — that path is git-tracked and git stores symlinks natively, so any merged PR can switch this half of the loop off on every machine, silently and indistinguishably from a real tamper refusal. The script never opens that file: it is not a state file: $A58_OUT1")
  printf '%s\n' "$A58_OUT1" | grep -q 'candidates=1' \
    || A58_FAILURES+=("(1) the run did not propose its one new finding with the lessons yml symlinked: $A58_OUT1")
  rm -rf "$a58_h1"

  # --- (2) CONTROL: the operands that ARE state still refuse ---
  a58_h2=$(mktemp -d); a58_s2="$a58_h2/.claude"; mkdir -p "$a58_s2" "$a58_h2/attacker"
  printf '{"finding":"%s","verdict":"fixed","origin":"automated-review"}\n' "$a58_f" > "$a58_s2/pending-lessons-581.jsonl"
  : > "$a58_h2/attacker/planted.log"
  ln -s "$a58_h2/attacker/planted.log" "$a58_s2/dismissed-lessons.log"
  A58_OUT2=$(HOME="$a58_h2" bash "$CONSUMER_SCRIPT" lessons baselito ai-engineering 4242 MERGED "$a58_h2" 2>&1)
  printf '%s\n' "$A58_OUT2" | grep -q 'refused=symlinked-state-file' \
    || A58_FAILURES+=("(2 CONTROL) a symlinked dismissed-lessons.log stopped being refused — the fix for (1) must remove ONE operand from that predicate, not the predicate: $A58_OUT2")
  rm -rf "$a58_h2"

  if [[ ${#A58_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: a symlinked knowledge/toolbox-lessons.yml no longer refuses the run and its one candidate was still proposed, while a symlinked dismissed-lessons log — a real state file — is still refused)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A58_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-59: A DISMISSAL WHOSE APPEND FAILED MUST NOT REPORT `recorded=`
#
# Confirmed at mode 444 and mode 555: `Permission denied` lands on stderr, then
# `CONSUME-DEVIATIONS: dismiss recorded=a05d1da2 …`, rc=0, and the log is 0
# bytes. The redirect's status is never examined.
#
# This is worse than a permissions edge case because the file header states that
# the summary line is what tests AND the agent bind to, and the function's own
# header calls this the highest-privilege operation in the loop. On `all-ignore`
# over 15 records the agent reports 15 dismissals, the user believes the batch
# is decided, and the next run reprints all 15 with no explanation — the
# stranded-queue failure, reached with nobody attacking anything.
#
# NOTE THE ASYMMETRY THE FIX IS TOWARD: `dev_archive_pass` DOES branch on `mv`'s
# status and WARNs. `dismiss` is the one unchecked destructive write, and it
# already has a refusal shape to copy — the symlink branch two lines above it.
#
# Both KINDS are exercised: `deviation` and `lesson` reach the same append
# through different `log` values, and a fix that checked only the branch it was
# debugging would leave the other silent.
# ---------------------------------------------------------------------------
TC="TC-STL-59: a dismissal that could not be written reports refused=write-failed (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v shasum >/dev/null 2>&1; then
  fail_test "$TC" "shasum is not installed — the canonical write verifies the hash against the body, so this behavioural test cannot run"
elif ! perms_are_enforced; then
  fail_test "$TC" "SETUP: chmod 000/444 are not enforced for this user (running as root, or a filesystem that ignores mode bits) — a read-only-log fixture would test the ordinary append and pass for the wrong reason"
else
  A59_FAILURES=()
  a59_body="A finding whose dismissal the agent is about to report as recorded"
  a59_hash=$(printf '%s' "$a59_body" | shasum -a 256 | awk '{print $1}')
  for _kind in deviation lesson; do
    case "$_kind" in
      deviation) _log="dismissed-deviations.log" ;;
      lesson)    _log="dismissed-lessons.log" ;;
    esac
    a59_h=$(mktemp -d); a59_s="$a59_h/.claude"; mkdir -p "$a59_s"
    : > "$a59_s/$_log"
    chmod 444 "$a59_s/$_log"
    A59_OUT=$(printf '%s' "$a59_body" | HOME="$a59_h" bash "$CONSUMER_SCRIPT" dismiss "$_kind" "$a59_hash" 2>&1)
    A59_RC=$?
    printf '%s\n' "$A59_OUT" | grep -q "CONSUME-DEVIATIONS: dismiss refused=write-failed kind=$_kind" \
      || A59_FAILURES+=("($_kind) the append to a read-only $_log did not report \`refused=write-failed kind=$_kind\` — the summary line is what the agent and this suite bind to, so an unreported failure is 15 dismissals the user believes and the log never received: $A59_OUT")
    printf '%s\n' "$A59_OUT" | grep -q 'CONSUME-DEVIATIONS: dismiss recorded=' \
      && A59_FAILURES+=("($_kind) the run reported \`recorded=\` for an append that failed — this is the one unchecked destructive write in the loop, while \`dev_archive_pass\` already branches on \`mv\`'s status: $A59_OUT")
    [[ "$A59_RC" -eq 0 ]] \
      || A59_FAILURES+=("($_kind) the refusal exited $A59_RC — a failed append costs exactly one dismissal and the record resurfaces, so it belongs on the 0 side of the two-code contract alongside the symlink refusal it mirrors: $A59_OUT")
    [[ ! -s "$a59_s/$_log" ]] \
      || A59_FAILURES+=("($_kind) $_log is non-empty after a refused write: $(cat "$a59_s/$_log" 2>/dev/null)")
    chmod 644 "$a59_s/$_log" 2>/dev/null
    rm -rf "$a59_h"
  done

  if [[ ${#A59_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: dismissing onto a read-only dismissed-deviations log and a read-only dismissed-lessons log each reported refused=write-failed with the kind, never recorded=, exited 0, and left the log empty)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A59_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-60: THE INVERSE — A WRITABLE LOG STILL RECORDS
#
# ⛔ TEST THE DIRECTION YOU DID NOT JUST CHANGE (TL-0011). ⛔ TC-STL-59 is
# satisfied by a `dismiss` that never reports success at all, and that failure
# is invisible in exactly the same way the bug is: the agent stops believing its
# own dismissals, every record resurfaces, and nothing says why. GREEN BOTH
# BEFORE AND AFTER the C-2 fix by design.
# ---------------------------------------------------------------------------
TC="TC-STL-60: a dismissal onto a writable log still records and says so (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v shasum >/dev/null 2>&1; then
  fail_test "$TC" "shasum is not installed — the canonical write verifies the hash against the body, so this behavioural test cannot run"
else
  A60_FAILURES=()
  a60_body="A finding whose dismissal really is written to a writable log"
  a60_hash=$(printf '%s' "$a60_body" | shasum -a 256 | awk '{print $1}')
  a60_h=$(mktemp -d); a60_s="$a60_h/.claude"; mkdir -p "$a60_s"
  A60_OUT=$(printf '%s' "$a60_body" | HOME="$a60_h" bash "$CONSUMER_SCRIPT" dismiss deviation "$a60_hash" 2>&1)
  A60_RC=$?
  printf '%s\n' "$A60_OUT" | grep -q "CONSUME-DEVIATIONS: dismiss recorded=${a60_hash:0:8} kind=deviation" \
    || A60_FAILURES+=("an ordinary dismissal onto a writable log did not report \`recorded=\` — TC-STL-59 would then pass against a writer that never reports success, which is the same stranded queue wearing the opposite sign: $A60_OUT")
  [[ "$A60_RC" -eq 0 ]] \
    || A60_FAILURES+=("an ordinary dismissal exited $A60_RC: $A60_OUT")
  A60_LINES=$(grep -cE "^\[$a60_hash\] " "$a60_s/dismissed-deviations.log" 2>/dev/null || true)
  [[ "$A60_LINES" -eq 1 ]] \
    || A60_FAILURES+=("the writable log holds $A60_LINES line(s) anchored on the record's full digest, expected exactly 1 — the anchored reader is what authorizes archival, so a line it cannot match is a dismissal that accomplishes nothing: $A60_OUT")
  rm -rf "$a60_h"

  if [[ ${#A60_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: an ordinary dismissal onto a writable log exited 0, reported recorded= with the display key and the kind, and left exactly one line the anchored reader can match — the direction the C-2 fix must not break)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A60_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-61: THE `defer` SUBCOMMAND — THE PENDING-LESSONS STORE HAS ONE WRITER
#
# The script's header claims it owns "every write to the four state stores".
# That was false when written: `commands/review-pr.md`'s `lessons-defer` block
# appends to the cross-PR deferred queue and deletes the per-PR snapshot, in
# PROSE, with a hand-described dedupe rule and NO statement of the record
# format — while `cmd_lessons` requires `.finding`, `.verdict` and `.origin` via
# `jq -er`. A record missing any of the three raises `parse_failures`, which
# permanently disables the ONLY branch that can drain the queue. Stranded queue,
# no attacker, on the ordinary path. Coverage before this test:
# `grep -n "lessons-defer\|pending-lessons-deferred\|deferred queue"` over this
# suite returned NOTHING.
#
# This is TL-0013 recurring one state store over — the exact class the branch
# exists to close — so it cannot be waved through, and the adjudicated fix is
# option (a): a `defer` subcommand owning the append and the delete, with the
# two prose blocks reduced to a call.
#
# ⛔ THIS TEST DEFINES THE CONTRACT; THE IMPLEMENTATION MUST MEET IT. ⛔ Written
# to match the existing interface shapes rather than invent new ones:
#
#   consume-deviations.sh defer OWNER REPO PR_NUMBER
#
#   * repo gate — it DELETES, so it needs the gate `lessons` has;
#   * symlink gate on ~/.claude, the deferred queue and the per-PR snapshot,
#     which is what the prose block already specifies;
#   * every record validated the way `cmd_lessons` reads them (`.finding`,
#     `.verdict`, `.origin`), so a record this appends is a record that half can
#     later drain — the whole point of collapsing the writer;
#   * dedupe on the full finding digest, to bound growth;
#   * a record already in `dismissed-lessons.log` is not re-deferred;
#   * the per-PR snapshot is deleted ONLY when every record in it was appended
#     or deliberately skipped — a parse failure preserves it;
#   * one `CONSUME-DEVIATIONS: defer …` summary line, like every other
#     subcommand.
# ---------------------------------------------------------------------------
TC="TC-STL-61: the deferred-lessons queue has ONE writer, and it is this script (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the deferred queue is JSONL, so this behavioural test cannot run"
else
  A61_FAILURES=()
  a61_defer()   { HOME="$1" bash "$CONSUMER_SCRIPT" defer "${2:-baselito}" "${3:-ai-engineering}" "$4" 2>&1; }
  a61_lessons() { HOME="$1" bash "$CONSUMER_SCRIPT" lessons baselito ai-engineering "$2" MERGED "$1" 2>&1; }
  a61_rec() { printf '{"finding":"%s","verdict":"fixed","origin":"automated-review"}\n' "$1"; }

  # --- (1) ROUND TRIP: defer on one PR, resurface on a LATER one ---
  a61_h=$(mktemp -d); a61_s="$a61_h/.claude"; mkdir -p "$a61_s"
  a61_f="A finding a human chose to hold until a later PR"
  a61_rec "$a61_f" > "$a61_s/pending-lessons-610.jsonl"
  A61_OUT1=$(a61_defer "$a61_h" baselito ai-engineering 610)
  printf '%s\n' "$A61_OUT1" | grep -q 'CONSUME-DEVIATIONS: defer ' \
    || A61_FAILURES+=("(1) \`defer\` produced no summary line — every subcommand ends with exactly one, and it is what a caller binds to instead of parsing prose: $A61_OUT1")
  [[ ! -e "$a61_s/pending-lessons-610.jsonl" ]] \
    || A61_FAILURES+=("(1) the per-PR snapshot survived the defer — the deferred records would then be read twice, once from each file: $A61_OUT1")
  [[ -e "$a61_s/pending-lessons-deferred.jsonl" ]] \
    || A61_FAILURES+=("(1) no deferred queue was written — the records a human explicitly held are gone: $A61_OUT1")
  A61_OUT1B=$(a61_lessons "$a61_h" 611)
  printf '%s\n' "$A61_OUT1B" | grep -q "$a61_f" \
    || A61_FAILURES+=("(1) the deferred finding did not resurface on a LATER merged PR — a defer that cannot round-trip is a delete with extra steps: $A61_OUT1B")

  # --- (2) DEDUPE: deferring the same finding twice leaves one line ---
  # The prose block already specifies "append only records whose finding hash is
  # not already in that queue, to bound growth". A rule stated only in prose is a
  # rule with no test, which is how this store came to have three writers.
  a61_rec "$a61_f" > "$a61_s/pending-lessons-612.jsonl"
  A61_OUT2=$(a61_defer "$a61_h" baselito ai-engineering 612)
  A61_DUP=$(grep -c "$a61_f" "$a61_s/pending-lessons-deferred.jsonl" 2>/dev/null || true)
  [[ "$A61_DUP" -eq 1 ]] \
    || A61_FAILURES+=("(2) the deferred queue holds $A61_DUP copies of the same finding, expected 1 — an unbounded queue is re-read and re-filtered on every future merge: $A61_OUT2")

  # --- (3) A MALFORMED RECORD IS NOT APPENDED, AND PINS ITS SNAPSHOT ---
  # ⛔ THE FAILURE THIS SUBCOMMAND EXISTS TO PREVENT. ⛔ `cmd_lessons` reads
  # `.finding`, `.verdict` and `.origin` with `jq -er`; a record missing any of
  # them raises `parse_failures`, and `parse_failures > 0` permanently disables
  # the only branch that can drain the queue. So a defer that appends a record
  # the reader cannot parse strands the queue forever — on the ordinary path,
  # with nobody attacking anything.
  a61_bad='{"finding":"A record the agent-side prose never specified a format for"}'
  printf '%s\n' "$a61_bad" > "$a61_s/pending-lessons-613.jsonl"
  A61_OUT3=$(a61_defer "$a61_h" baselito ai-engineering 613)
  printf '%s\n' "$A61_OUT3" | grep -q 'parse_failures=1' \
    || A61_FAILURES+=("(3) a record missing \`.verdict\`/\`.origin\` was not reported as a parse failure: $A61_OUT3")
  grep -q 'never specified a format for' "$a61_s/pending-lessons-deferred.jsonl" 2>/dev/null \
    && A61_FAILURES+=("(3) a record \`cmd_lessons\` cannot parse was APPENDED to the deferred queue — one such record raises parse_failures forever, which permanently disables the only branch that drains this queue: $A61_OUT3")
  [[ -e "$a61_s/pending-lessons-613.jsonl" ]] \
    || A61_FAILURES+=("(3) the snapshot holding an unappendable record was DELETED — the record is now gone and nothing read it: $A61_OUT3")
  printf '%s\n' "$A61_OUT3" | grep -q 'deleted=no' \
    || A61_FAILURES+=("(3) the summary did not report deleted=no for a snapshot that could not be fully deferred: $A61_OUT3")

  # --- (4) THE REPO GATE, on a subcommand that deletes ---
  a61_rec "$a61_f" > "$a61_s/pending-lessons-614.jsonl"
  A61_OUT4=$(a61_defer "$a61_h" someorg someproject 614)
  printf '%s\n' "$A61_OUT4" | grep -q 'CONSUME-DEVIATIONS: defer refused=not-toolbox-repo' \
    || A61_FAILURES+=("(4) a run from someorg/someproject was not refused — every snapshot in ~/.claude is a TOOLBOX snapshot, and this subcommand deletes them: $A61_OUT4")
  [[ -e "$a61_s/pending-lessons-614.jsonl" ]] \
    || A61_FAILURES+=("(4) a PROJECT-repo run deleted a toolbox lessons snapshot: $A61_OUT4")
  rm -rf "$a61_h"

  # --- (5) THE SYMLINK GATE, which the prose block already specifies ---
  a61_h5=$(mktemp -d); a61_s5="$a61_h5/.claude"; mkdir -p "$a61_s5" "$a61_h5/attacker"
  a61_rec "$a61_f" > "$a61_s5/pending-lessons-615.jsonl"
  : > "$a61_h5/attacker/deferred.jsonl"
  ln -s "$a61_h5/attacker/deferred.jsonl" "$a61_s5/pending-lessons-deferred.jsonl"
  A61_OUT5=$(a61_defer "$a61_h5" baselito ai-engineering 615)
  printf '%s\n' "$A61_OUT5" | grep -q 'CONSUME-DEVIATIONS: defer refused=symlinked-state-file' \
    || A61_FAILURES+=("(5) a symlinked deferred queue was not refused — an unguarded \`>>\` through it is a path-traversal write, which is exactly what the prose block it replaces says must not happen: $A61_OUT5")
  [[ -e "$a61_s5/pending-lessons-615.jsonl" ]] \
    || A61_FAILURES+=("(5) the per-PR snapshot was deleted despite the refusal — the records would be gone with the append having gone somewhere else: $A61_OUT5")
  [[ ! -s "$a61_h5/attacker/deferred.jsonl" ]] \
    || A61_FAILURES+=("(5) records were appended THROUGH the symlink into $a61_h5/attacker/deferred.jsonl: $A61_OUT5")
  rm -rf "$a61_h5"

  # ⛔ LEGS (6)–(8) WERE WRITTEN ALONGSIDE THE IMPLEMENTATION, NOT BEFORE IT. ⛔
  # Legs (1)–(5) come from the contract above and were committed RED. These three
  # pin guards that contract does not reach — a caller-supplied path component, an
  # append whose status is unchecked, and the dismissed-log filter — and each was
  # falsified by neutering its guard in an isolated copy and watching this test go
  # red. They are recorded as later additions so nobody reads them as evidence
  # the contract predicted them.

  # --- (6) PR_NUMBER IS A PATH COMPONENT, AND THIS SUBCOMMAND DELETES ---
  # `defer` builds `~/.claude/pending-lessons-<PR>.jsonl` and `rm -f`s it. With
  # PR_NUMBER unvalidated, a `..` inside it walks out of the state dir — and the
  # traversal only needs a DIRECTORY named like a snapshot to pivot through, which
  # is the same shape as the symlinked-directory escape the deviation sweep
  # already closed at its source. Here it costs a file in $HOME.
  # FALSIFYING EDIT: drop the `LESSONNAME_RE` test on the constructed snapshot
  # name in `cmd_defer`.
  a61_h6=$(mktemp -d); a61_s6="$a61_h6/.claude"; mkdir -p "$a61_s6/pending-lessons-1" "$a61_h6/victim"
  a61_rec "A note in a file that is none of this loop's business" > "$a61_h6/victim/notes.jsonl"
  A61_OUT6=$(HOME="$a61_h6" bash "$CONSUMER_SCRIPT" defer baselito ai-engineering '1/../../victim/notes' 2>&1)
  A61_RC6=$?
  [[ -e "$a61_h6/victim/notes.jsonl" ]] \
    || A61_FAILURES+=("(6) a PR_NUMBER holding \`..\` walked out of the state dir and DELETED \$HOME/victim/notes.jsonl — the argument is a path component in the one operation here with no undo: $A61_OUT6")
  [[ "$A61_RC6" -eq 2 ]] \
    || A61_FAILURES+=("(6) a PR_NUMBER that is not the name the fold writes exited $A61_RC6, expected 2 — it is a CALLER bug, and the two-code contract makes those loud: $A61_OUT6")
  grep -q 'none of this loop' "$a61_s6/pending-lessons-deferred.jsonl" 2>/dev/null \
    && A61_FAILURES+=("(6) the contents of a file outside the state dir were appended to the deferred queue: $A61_OUT6")
  rm -rf "$a61_h6"

  # --- (7) AN APPEND THAT COULD NOT BE WRITTEN IS REPORTED, AND KEEPS THE
  #         SNAPSHOT ---
  # The append is what makes the snapshot redundant, so reporting a success the
  # file never received would delete the only remaining copy of those records.
  # This is TC-STL-59's defect one writer over, and the fix must not be applied to
  # `dismiss` alone — that would recreate the very asymmetry this branch exists to
  # close.
  # FALSIFYING EDIT: replace the checked `if ( printf … >> … )` in `cmd_defer`
  # with an unchecked append.
  if ! perms_are_enforced; then
    A61_FAILURES+=("(7) SETUP: chmod 444 is not enforced for this user (running as root, or a filesystem that ignores mode bits) — a read-only-queue fixture would exercise the ordinary append and pass for the wrong reason")
  else
    a61_h7=$(mktemp -d); a61_s7="$a61_h7/.claude"; mkdir -p "$a61_s7"
    a61_rec "A finding whose defer the agent is about to be told succeeded" > "$a61_s7/pending-lessons-617.jsonl"
    : > "$a61_s7/pending-lessons-deferred.jsonl"
    chmod 444 "$a61_s7/pending-lessons-deferred.jsonl"
    A61_OUT7=$(a61_defer "$a61_h7" baselito ai-engineering 617)
    printf '%s\n' "$A61_OUT7" | grep -q 'CONSUME-DEVIATIONS: defer refused=write-failed' \
      || A61_FAILURES+=("(7) an append to a read-only deferred queue did not report \`refused=write-failed\` — the summary line is what the caller binds to, so an unreported failure is a defer the agent believes and the queue never received: $A61_OUT7")
    [[ -e "$a61_s7/pending-lessons-617.jsonl" ]] \
      || A61_FAILURES+=("(7) the per-PR snapshot was DELETED after an append that failed — the records existed in exactly two places and both are now gone: $A61_OUT7")
    [[ ! -s "$a61_s7/pending-lessons-deferred.jsonl" ]] \
      || A61_FAILURES+=("(7) the read-only queue is non-empty after a refused write: $(cat "$a61_s7/pending-lessons-deferred.jsonl" 2>/dev/null)")
    chmod 644 "$a61_s7/pending-lessons-deferred.jsonl" 2>/dev/null
    rm -rf "$a61_h7"
  fi

  # --- (8) AN ALREADY-DECIDED FINDING IS NOT RE-DEFERRED ---
  # "Learned" and "dropped" both mean the finding must never resurface. Deferring
  # one puts it back in the only file that outlives its PR, so the reader would
  # filter it out of every future run forever — and a queue that only grows is
  # what the dedupe exists to prevent. A skip is a DECISION, so it does not hold
  # the snapshot.
  # FALSIFYING EDIT: delete the `hash_logged_in … DISMISSED_LESSONS_LOG` lookup
  # from `cmd_defer`.
  a61_h8=$(mktemp -d); a61_s8="$a61_h8/.claude"; mkdir -p "$a61_s8"
  a61_done="A finding that was already learned and must never come back"
  a61_rec "$a61_done" > "$a61_s8/pending-lessons-618.jsonl"
  consumer_dismiss "$a61_h8" lesson "$a61_done" >/dev/null 2>&1
  A61_OUT8=$(a61_defer "$a61_h8" baselito ai-engineering 618)
  grep -q "$a61_done" "$a61_s8/pending-lessons-deferred.jsonl" 2>/dev/null \
    && A61_FAILURES+=("(8) a finding already in dismissed-lessons.log was re-deferred — it now sits in the one file that outlives its PR, to be filtered out on every future merge forever: $A61_OUT8")
  printf '%s\n' "$A61_OUT8" | grep -q 'skipped=1' \
    || A61_FAILURES+=("(8) the summary did not report the skip, so a caller cannot tell 'nothing to defer' from 'one already-decided record': $A61_OUT8")
  [[ ! -e "$a61_s8/pending-lessons-618.jsonl" ]] \
    || A61_FAILURES+=("(8) the snapshot was preserved although its only record was deliberately skipped — a decided record is accounted for, and a file nothing can ever move is re-read on every merge: $A61_OUT8")
  rm -rf "$a61_h8"

  # --- (9) EACH REQUIRED KEY IS CHECKED INDEPENDENTLY ---
  # ⛔ WHY LEG (3) DOES NOT PIN THE INDIVIDUAL KEYS, MEASURED. ⛔ Leg (3)'s record
  # is missing BOTH `.verdict` AND `.origin`, so either check alone catches it:
  # deleting just one of them left the whole suite green. The keys mask each other,
  # and the masked one is a real hole — `cmd_lessons` reads all three with
  # `jq -er`, so a record missing exactly one is appended by `defer` and then
  # raises `parse_failures` on every future read, which permanently disables the
  # only branch that can drain the queue. That is the defect this subcommand
  # exists to prevent, reachable through the guard that was supposed to prevent
  # it.
  # This leg carries one record missing ONLY `.verdict`, one missing ONLY
  # `.origin`, and one missing ONLY `.finding`, so no single deletion satisfies
  # it. The third also pins the `-e` in `jq -er '.finding'`: without it a record
  # with no `.finding` yields the STRING "null", which hashes fine and becomes a
  # candidate — a junk finding proposed to the consensus pass and appended to the
  # queue as though it were real.
  # FALSIFYING EDIT: drop the `.verdict` check, drop the `.origin` check, or
  # weaken `jq -er '.finding'` to `jq -r` — each reddens this leg on its own.
  a61_h9=$(mktemp -d); a61_s9="$a61_h9/.claude"; mkdir -p "$a61_s9"
  {
    printf '{"finding":"MISSING VERDICT — appended, this record strands the queue","origin":"automated-review"}\n'
    printf '{"finding":"MISSING ORIGIN — appended, this record strands the queue","verdict":"fixed"}\n'
    printf '{"verdict":"fixed","origin":"automated-review"}\n'
  } > "$a61_s9/pending-lessons-619.jsonl"
  A61_OUT9=$(a61_defer "$a61_h9" baselito ai-engineering 619)
  printf '%s\n' "$A61_OUT9" | grep -q 'parse_failures=3' \
    || A61_FAILURES+=("(9) three records each missing exactly ONE required key did not all count as parse failures — the keys were masking each other, and a record missing exactly one gets appended and then strands the queue on every future read: $A61_OUT9")
  grep -q 'strands the queue' "$a61_s9/pending-lessons-deferred.jsonl" 2>/dev/null \
    && A61_FAILURES+=("(9) a record the reader cannot parse was APPENDED to the deferred queue: $(cat "$a61_s9/pending-lessons-deferred.jsonl" 2>/dev/null)")
  [[ -e "$a61_s9/pending-lessons-619.jsonl" ]] \
    || A61_FAILURES+=("(9) the snapshot holding the unappendable records was DELETED: $A61_OUT9")
  rm -rf "$a61_h9"

  if [[ ${#A61_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: a defer round-tripped through the cross-PR queue and resurfaced on a later merged PR, a repeat defer stayed at one line, a record cmd_lessons cannot parse was neither appended nor allowed to take its snapshot with it, a project-repo run and a symlinked queue were each refused with nothing written or deleted, a PR_NUMBER holding \`..\` was refused before it could delete a file outside the state dir, an append onto a read-only queue reported refused=write-failed and kept its snapshot, and an already-dismissed finding was skipped rather than re-deferred)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A61_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-62: verify.sh MUST DETECT AN INSTALLED COPY THAT DIFFERS FROM THE REPO
#
# The check this branch ADDED covers three conditions and misses the only one
# that matters:
#
#   repo copy missing            → fail  exit 1
#   installed copy missing       → warn  exit 0
#   installed, not executable    → warn  exit 0
#   installed, executable, STALE → NO BRANCH EXISTS → ok, exit 0
#
# Falsified by planting a 3-line stub in place of the 1128-line script:
#   ✅ consume-deviations.sh installed and executable at …
#   ✅ All checks passed — everything is healthy          EXIT 0
# That is issue #137's exact failure mode — merged but inert, nothing says so —
# reproduced by the check added to prevent it. `verify.sh` has no content
# comparison anywhere: `grep -n "cmp \|diff \|shasum\|md5\|sha256\|checksum"`
# over it returns nothing.
#
# In scope because the branch adds the check: an inert detector is worse than no
# detector, because it converts "unknown" into a green tick (TL-0002).
#
# ⛔ DELIBERATE CONSEQUENCE, RECORD IT HERE SO NOBODY LATER SOFTENS IT. ⛔
# `fail` on mismatch means verify.sh FAILS on any branch that edits
# consume-deviations.sh until install.sh is re-run. That is honest and it is the
# point — a `warn` would restore exactly the green tick this test forbids, so
# the assertion below is that the ERROR COUNT rises, which a `warn` does not do.
#
# ⛔⛔ verify.sh RUNS THIS SUITE. ⛔⛔ `scripts/verify.sh` executes
# `scripts/test-sync-toolbox-lessons.sh` (and six sibling suites) and treats a
# non-zero exit as a verify failure. So a test in THIS file that invokes the
# REPO'S verify.sh is MUTUALLY RECURSIVE — suite → verify → suite → verify →
# … — and it does not terminate. Measured while writing this test: the run blew
# past a ten-minute ceiling with no output after TC-STL-61.
#
# The fix is not a re-entrancy flag (that would still cost two full nested
# verify runs, and would need a change to verify.sh, which this test is not
# allowed to make). It is to run verify.sh against a THROWAWAY COPY of the repo
# whose `scripts/test-*.sh` are replaced by `exit 0` stubs. What is under test
# here is one filesystem comparison inside verify.sh; the seven unit suites it
# also runs are unrelated to it, and stubbing them removes the recursion AND
# takes a run from ~2 minutes to ~20 seconds.
#
# ⛔ AND NOTE WHAT IS *NOT* STUBBED: verify.sh ITSELF. ⛔ The script under test
# is the real one, unmodified, resolving its own REPO_ROOT and CLAUDE_HOME
# exactly as it does in production. Extracting the check block into this test —
# the way it was first falsified — would be a reconstruction, and this file's
# header records what reconstructions cost.
#
# ONE repo copy serves both runs: REPO_ROOT is identical for them, and the only
# difference is the CONTENT of the installed copy under each fake HOME. The two
# runs are started CONCURRENTLY.
# ---------------------------------------------------------------------------
TC="TC-STL-62: verify.sh reports an installed consume-deviations.sh that differs from the repo (executed)"
A62_REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
A62_VERIFY="$A62_REPO_ROOT/scripts/verify.sh"
if [[ ! -f "$A62_VERIFY" ]]; then
  fail_test "$TC" "cannot locate scripts/verify.sh ($A62_VERIFY)"
elif [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v rsync >/dev/null 2>&1; then
  fail_test "$TC" "rsync is not available — the throwaway repo copy that breaks the verify.sh ↔ test-suite recursion cannot be built"
else
  A62_FAILURES=()
  a62_tmp=$(mktemp -d); a62_repo="$a62_tmp/repo"; mkdir -p "$a62_repo"
  rsync -a --exclude '.git' "$A62_REPO_ROOT"/ "$a62_repo"/ 2>/dev/null
  # ⛔ THE RECURSION CUT. ⛔ Without this, verify.sh runs this very suite, which
  # runs verify.sh again, without bound. Only the OTHER suites' invocations are
  # neutered; verify.sh and consume-deviations.sh in the copy are byte-identical
  # to the repo.
  for _t in "$a62_repo"/scripts/test-*.sh; do
    printf '#!/usr/bin/env bash
exit 0
' > "$_t"
  done
  # Precondition: the copy's own consume-deviations.sh — the "repo copy" side of
  # the comparison — must really match the repo's, or both runs compare against
  # the wrong baseline and the delta below means nothing.
  if ! cmp -s "$CONSUMER_SCRIPT" "$a62_repo/scripts/consume-deviations.sh"; then
    A62_FAILURES+=("setup: the throwaway repo copy's consume-deviations.sh differs from the repo's, so both verify runs would compare against the wrong baseline")
  fi

  # Two fake HOMEs identical in every respect EXCEPT the CONTENT of the
  # installed consume-deviations.sh. Everything else verify.sh checks is missing
  # from both, so both runs report the same baseline errors and the DIFFERENCE
  # between their error counts is attributable to this one check.
  a62_match="$a62_tmp/home-match"; mkdir -p "$a62_match/.claude/scripts"
  cp "$CONSUMER_SCRIPT" "$a62_match/.claude/scripts/consume-deviations.sh"
  chmod +x "$a62_match/.claude/scripts/consume-deviations.sh"

  a62_stale="$a62_tmp/home-stale"; mkdir -p "$a62_stale/.claude/scripts"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# A stale installed copy: present, executable, and not the reviewed script.\n'
    printf 'exit 0\n'
  } > "$a62_stale/.claude/scripts/consume-deviations.sh"
  chmod +x "$a62_stale/.claude/scripts/consume-deviations.sh"

  a62_out_match="$a62_tmp/verify-match.out"
  a62_out_stale="$a62_tmp/verify-stale.out"
  HOME="$a62_match" bash "$a62_repo/scripts/verify.sh" > "$a62_out_match" 2>&1 &
  a62_pid_match=$!
  HOME="$a62_stale" bash "$a62_repo/scripts/verify.sh" > "$a62_out_stale" 2>&1 &
  a62_pid_stale=$!
  wait "$a62_pid_match" 2>/dev/null
  wait "$a62_pid_stale" 2>/dev/null

  # Strip the colour escapes before matching, so an assertion never depends on
  # which SGR sequence a helper happens to emit.
  a62_plain() { sed 's/\[[0-9;]*m//g' "$1"; }
  # The summary reports "N error(s)"; a clean run prints a different line and
  # means zero.
  a62_errors() {
    local n
    n=$(a62_plain "$1" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) error(s).*/\1/p' | tail -1)
    [[ -n "$n" ]] || n=0
    printf '%s' "$n"
  }

  A62_STALE_LINE=$(a62_plain "$a62_out_stale" | grep 'consume-deviations.sh' | grep '❌' || true)
  A62_MATCH_BAD=$(a62_plain "$a62_out_match" | grep 'consume-deviations.sh' | grep '❌' || true)
  A62_MATCH_OK=$(a62_plain "$a62_out_match" | grep 'consume-deviations.sh' | grep '✅' || true)
  A62_E_STALE=$(a62_errors "$a62_out_stale")
  A62_E_MATCH=$(a62_errors "$a62_out_match")

  # Precondition: both runs must have reached the summary at all.
  a62_plain "$a62_out_stale" | grep -q 'consume-deviations.sh' \
    || A62_FAILURES+=("setup: the stale run produced no line mentioning consume-deviations.sh at all, so verify.sh did not reach the check: $(a62_plain "$a62_out_stale" | tail -3 | tr '\n' ' ')")

  [[ -n "$A62_STALE_LINE" ]] \
    || A62_FAILURES+=("an installed consume-deviations.sh that is a STUB — present, executable, and not the reviewed script — produced no ❌ line naming it. That is issue #137's failure mode reproduced by the check added to prevent it: the loop is inert and the health check reports a green tick. verify.sh said: $(a62_plain "$a62_out_stale" | grep 'consume-deviations' | tr '\n' ' ')")
  [[ -z "$A62_MATCH_BAD" ]] \
    || A62_FAILURES+=("a BYTE-IDENTICAL installed copy was reported as a failure — the check must fire on a mismatch, not on the ordinary installed state, or every healthy machine reports an error: $A62_MATCH_BAD")
  [[ -n "$A62_MATCH_OK" ]] \
    || A62_FAILURES+=("a byte-identical installed copy produced no ✅ line naming consume-deviations.sh: $(a62_plain "$a62_out_match" | grep 'consume-deviations' | tr '\n' ' ')")
  [[ "$A62_E_STALE" -eq $((A62_E_MATCH + 1)) ]] \
    || A62_FAILURES+=("the stale copy gave $A62_E_STALE error(s) while the matching copy gave $A62_E_MATCH — expected exactly one more. A \`warn\` does not raise the error count, so it would satisfy a line-only assertion while still exiting 0 under a healthy-looking summary, which is the softening this check exists to prevent")

  rm -rf "$a62_tmp"

  if [[ ${#A62_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (ran the real verify.sh against two fake homes differing only in the CONTENT of the installed consume-deviations.sh: the stub raised an error naming it and the byte-identical copy did not, and the error count differed by exactly one)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A62_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-63: THE FULL DIGEST MUST REACH STDOUT ON THE DEVIATION SURFACE PATH
#
# The surface listing prints `(hash: <8 hex>)` and nothing else. The FULL
# 64-character digest never reaches stdout, and on an unattended run it is not
# even persisted (the surfaced-log write is attended-only). So Step 7's
# `ignore N` / `improve N` resolve a record from a 32-bit prefix a human
# retyped, and `cmd_dismiss`'s pair-consistency check — hash vs body — is
# STRUCTURALLY unable to notice that the agent resolved the WRONG record: the
# body it is handed is the wrong record's body, so the pair agrees.
#
# Demonstrated end to end: a mis-resolved dismissal retired an untriaged victim,
# and the next surface printed `surfaced=0 still_queued=1` — the victim is now
# permanently invisible while the queue reports work outstanding forever.
#
# What drives this is NOT grinding (that needs the victim's exact body, which
# lives in a local handover.md no external actor reads) but ordinary
# mis-resolution: a forged item header, a compaction, or a retyping slip.
#
# ⛔ THIS TEST DEFINES THE CONTRACT. ⛔ It mirrors `cmd_lessons`, which already
# emits one machine-readable line per candidate so the agent resolves the SAME
# numbering the listing printed instead of re-deriving it:
#
#   SURFACED <index> <64-hex digest>
#
#   one line per record this run actually displayed, in listing order, with the
#   index matching the `[N]` the human sees. The 8-character form stays as the
#   human-facing display only.
# ---------------------------------------------------------------------------
TC="TC-STL-63: every surfaced record's FULL digest reaches stdout, keyed to its listing index (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1 || ! command -v shasum >/dev/null 2>&1; then
  fail_test "$TC" "jq or shasum is not installed — the surface pass needs both, so this behavioural test cannot run"
else
  A63_FAILURES=()
  a63_h=$(mktemp -d); a63_s="$a63_h/.claude"; mkdir -p "$a63_s"
  a63_b1="The first deviation in the listing, which item 1 must resolve to"
  a63_b2="The second deviation in the listing, whose digest shares no prefix worth guessing"
  a63_d1=$(printf '%s' "$a63_b1" | shasum -a 256 | awk '{print $1}')
  a63_d2=$(printf '%s' "$a63_b2" | shasum -a 256 | awk '{print $1}')
  {
    printf '{"ts":"2026-01-01T00:00:00Z","phase":"Implementation","body":"%s"}\n' "$a63_b1"
    printf '{"ts":"2026-01-01T00:00:01Z","phase":"Code Review","body":"%s"}\n' "$a63_b2"
  } > "$a63_s/pending-deviations-6363.log"
  A63_OUT=$(consumer_run "$a63_h" attended)

  printf '%s\n' "$A63_OUT" | grep -q 'surfaced=2 ' \
    || A63_FAILURES+=("precondition: the fixture did not surface its two records, so nothing below is about the digest: $A63_OUT")
  A63_N=$(printf '%s\n' "$A63_OUT" | grep -c '^SURFACED ' || true)
  [[ "$A63_N" -eq 2 ]] \
    || A63_FAILURES+=("the run emitted $A63_N machine-readable \`SURFACED \` line(s) for 2 displayed records — without one per record the agent resolves \`ignore N\` from the 8-character DISPLAY prefix a human retyped, and cmd_dismiss's hash-vs-body check structurally cannot detect a mis-resolution because the body it is handed is the wrong record's: $A63_OUT")
  printf '%s\n' "$A63_OUT" | grep -qE "^SURFACED 1 $a63_d1( |\$)" \
    || A63_FAILURES+=("no \`SURFACED 1 <full digest>\` line carrying item 1's 64-character digest — the index must key to the SAME numbering the human listing printed, or the machine line resolves a different record than the one the user read: $A63_OUT")
  printf '%s\n' "$A63_OUT" | grep -qE "^SURFACED 2 $a63_d2( |\$)" \
    || A63_FAILURES+=("no \`SURFACED 2 <full digest>\` line carrying item 2's 64-character digest: $A63_OUT")
  # The display form stays: this promotes the full digest, it does not remove
  # the short one a human reads off the screen.
  printf '%s\n' "$A63_OUT" | grep -q "(hash: ${a63_d1:0:8})" \
    || A63_FAILURES+=("the human-facing 8-character display hash is gone from the listing — the full digest is for the agent, the short one is for the reader, and both are needed: $A63_OUT")
  rm -rf "$a63_h"

  if [[ ${#A63_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: both displayed records emitted a machine-readable SURFACED line carrying the full 64-character digest keyed to the listing index the human saw, with the 8-character display form still printed alongside)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A63_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-64: AN UNREADABLE DISMISSED LOG IS REPORTED, NOT SILENT
#
# Verified at mode 000: the ARCHIVE path correctly declines (`archived=0`) with
# NO warning of any kind, and the SURFACE path REPRINTS an already-decided
# record while reporting `unreadable=0`. Every re-dismissal then appends to a
# file nothing can read.
#
# Failing closed for archival is right. Asserting a clean run is not: the
# summary is what the agent and this suite bind to, and it currently says
# "nothing was unreadable" about a run whose authorizing file could not be
# opened. The deviation half already has the vocabulary — `unreadable` is
# reported alongside `parse_failures` and never folded into it, because one
# means "we read a record and could not understand it" and the other means "we
# could not read it at all".
#
# Contract: `dismissed_log_unreadable=yes` on the summary line of BOTH entry
# points that consult it.
# ---------------------------------------------------------------------------
TC="TC-STL-64: an unreadable dismissed log is named on the summary line (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the consumer parses JSONL with jq, so this behavioural test cannot run"
elif ! perms_are_enforced; then
  fail_test "$TC" "SETUP: chmod 000/444 are not enforced for this user (running as root, or a filesystem that ignores mode bits) — an unreadable-log fixture would test the ordinary path and pass for the wrong reason"
else
  A64_FAILURES=()
  a64_body="A deviation whose decision status cannot be determined this run"
  a64_make() {
    local h st; h=$(mktemp -d); st="$h/.claude"; mkdir -p "$st"
    printf '{"ts":"2026-01-01T00:00:00Z","phase":"Implementation","body":"%s"}\n' "$a64_body" \
      > "$st/pending-deviations-6464.log"
    consumer_dismiss "$h" deviation "$a64_body" >/dev/null 2>&1
    chmod 000 "$st/dismissed-deviations.log"
    printf '%s' "$h"
  }

  # --- (1) SURFACE ---
  a64_h1=$(a64_make)
  A64_OUT1=$(consumer_run "$a64_h1" attended)
  printf '%s\n' "$A64_OUT1" | grep -q 'dismissed_log_unreadable=yes' \
    || A64_FAILURES+=("(1) \`surface\` did not name the unreadable dismissed log on its summary line — it reprinted a record that IS decided while reporting a clean run, so every re-dismissal appends to a file nothing can read: $A64_OUT1")
  chmod 644 "$a64_h1/.claude/dismissed-deviations.log" 2>/dev/null
  rm -rf "$a64_h1"

  # --- (2) ARCHIVE ---
  # The archive path is the one where the consequence is structural: that log is
  # the ONLY thing that authorizes a retirement, so a run that cannot read it can
  # never drain anything — and today it says so nowhere.
  a64_h2=$(a64_make)
  A64_OUT2=$(HOME="$a64_h2" bash "$CONSUMER_SCRIPT" archive baselito ai-engineering 2>&1)
  printf '%s\n' "$A64_OUT2" | grep -q 'dismissed_log_unreadable=yes' \
    || A64_FAILURES+=("(2) \`archive\` did not name the unreadable dismissed log — it declined correctly, which is right, but reported an ordinary \`archived=0\`, so a machine that can never retire anything looks identical to one with nothing to retire: $A64_OUT2")
  printf '%s\n' "$A64_OUT2" | grep -q 'archived=0' \
    || A64_FAILURES+=("(2) a run that could not read the authorizing log still ARCHIVED something: $A64_OUT2")
  chmod 644 "$a64_h2/.claude/dismissed-deviations.log" 2>/dev/null
  rm -rf "$a64_h2"

  # --- (3) CONTROL: a READABLE dismissed log reports no such thing ---
  # Without this, legs (1) and (2) are satisfied by a script that prints the key
  # unconditionally, which tells a caller nothing at all.
  a64_h3=$(mktemp -d); a64_s3="$a64_h3/.claude"; mkdir -p "$a64_s3"
  printf '{"ts":"2026-01-01T00:00:00Z","phase":"Implementation","body":"%s"}\n' "$a64_body" \
    > "$a64_s3/pending-deviations-6464.log"
  consumer_dismiss "$a64_h3" deviation "$a64_body" >/dev/null 2>&1
  A64_OUT3=$(HOME="$a64_h3" bash "$CONSUMER_SCRIPT" archive baselito ai-engineering 2>&1)
  printf '%s\n' "$A64_OUT3" | grep -q 'dismissed_log_unreadable=yes' \
    && A64_FAILURES+=("(3 CONTROL) a perfectly readable dismissed log was reported as unreadable — a key printed unconditionally carries no information: $A64_OUT3")
  printf '%s\n' "$A64_OUT3" | grep -q 'archived=1' \
    || A64_FAILURES+=("(3 CONTROL) a fully-decided snapshot with a readable dismissed log did not retire: $A64_OUT3")
  rm -rf "$a64_h3"

  if [[ ${#A64_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: both \`surface\` and \`archive\` named the unreadable dismissed log on their summary lines and archived nothing, while a readable one reported no such key and still retired its fully-decided snapshot)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A64_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-65: A LESSONS DELETE THAT DID NOT HAPPEN MUST NOT REPORT deleted=yes
#
# ⛔ THE ASYMMETRY CLASS, FOURTH RECURRENCE ON THIS BRANCH. ⛔ `cmd_dismiss` had
# an unchecked `>>` followed by an unconditional `recorded=` (C-2). It was fixed.
# `cmd_lessons` kept the same shape one level down: an unchecked `rm -f`
# followed by an unconditional `deleted=yes`. A guard present on one path and
# absent on its siblings is what the (unshipped) asymmetry gate in issue #157
# was built to catch; automated-review caught this one instead.
#
# WHY IT MATTERS, not just that it is untidy: `rm -f` suppresses a MISSING file,
# not a permission error. With ~/.claude read-only every unlink is refused, the
# snapshots all survive, and the run reports the queue drained. The caller then
# believes those records are retired while they are still queued, so the next
# merge reads and re-filters exactly the same records with no explanation — the
# stranded-queue failure, reached with nobody attacking anything.
#
# ⛔ TL-0002: A GUARD WITH NO FAILING TEST IS ASSUMED INERT. ⛔ This test exists
# because the class has now recurred four times, and each earlier fix was
# verified only in the direction it was written. Both directions are asserted
# here: leg (1) is RED before the fix (the run says `deleted=yes` over a file
# that is still on disk) and leg (2) is the control, GREEN both before and after
# — a `cmd_lessons` that simply stopped deleting would satisfy leg (1) alone,
# and that failure is invisible: the queue grows and nothing ever reports it.
# ---------------------------------------------------------------------------
TC="TC-STL-65: a lessons delete that could not happen is not reported as done (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the lessons half parses JSONL with jq, so this behavioural test cannot run"
elif ! dir_unlink_is_blocked; then
  fail_test "$TC" "SETUP: a read-only directory does not refuse unlink for this user (running as root, or a filesystem that ignores mode bits) — the fixture would exercise the ordinary delete and pass for a reason unrelated to the guard"
else
  A65_FAILURES=()

  # ---- leg (1): the defect. A fully-drained snapshot that CANNOT be unlinked.
  # The directory is made read-only AFTER the dismissal is recorded, so the
  # dismissed log exists and is writable: `touch` on an existing writable file
  # needs no directory write, which is what keeps this a test of the `rm` and
  # not of some earlier step failing first.
  a65_h=$(mktemp -d); a65_s="$a65_h/.claude"; mkdir -p "$a65_s"
  a65_f="A lessons finding read cleanly and dismissed, in a directory that refuses unlink"
  printf '{"finding":"%s","verdict":"fixed","origin":"automated-review"}\n' "$a65_f" > "$a65_s/pending-lessons-965.jsonl"
  consumer_dismiss "$a65_h" lesson "$a65_f" >/dev/null 2>&1
  chmod 555 "$a65_s"
  A65_OUT1=$(HOME="$a65_h" bash "$CONSUMER_SCRIPT" lessons baselito ai-engineering 4242 MERGED "$a65_h" 2>&1)
  chmod 755 "$a65_s"

  # The fixture must actually have blocked the unlink, or the assertions below
  # are about nothing. Asserted, not assumed.
  [[ -e "$a65_s/pending-lessons-965.jsonl" ]] \
    || A65_FAILURES+=("(1 SETUP) the snapshot was removed from a read-only directory, so the fixture never produced a failing unlink and nothing about the guard was exercised: $A65_OUT1")
  printf '%s\n' "$A65_OUT1" | grep -q 'deleted=yes' \
    && A65_FAILURES+=("(1) the run reported \`deleted=yes\` for a file that is STILL ON DISK. The caller is told the queue is drained while the records are still queued, so the next merge re-reads and re-filters them with no explanation — the C-2 stranded-queue failure, one level down: $A65_OUT1")
  printf '%s\n' "$A65_OUT1" | grep -q 'deleted=no' \
    || A65_FAILURES+=("(1) a run whose delete was refused did not report \`deleted=no\` on its summary line: $A65_OUT1")
  printf '%s\n' "$A65_OUT1" | grep -q 'WARN: could not remove pending-lessons-965.jsonl' \
    || A65_FAILURES+=("(1) the surviving file was not NAMED on stderr — \`deleted=no\` alone does not tell the person reading it WHICH file to go and fix: $A65_OUT1")
  rm -rf "$a65_h"

  # ---- leg (2): the control. Identical fixture, writable directory.
  # GREEN before and after the fix by design: it is what stops the guard from
  # being bought by a `cmd_lessons` that has quietly stopped deleting anything.
  a65_h2=$(mktemp -d); a65_s2="$a65_h2/.claude"; mkdir -p "$a65_s2"
  printf '{"finding":"%s","verdict":"fixed","origin":"automated-review"}\n' "$a65_f" > "$a65_s2/pending-lessons-965.jsonl"
  consumer_dismiss "$a65_h2" lesson "$a65_f" >/dev/null 2>&1
  A65_OUT2=$(HOME="$a65_h2" bash "$CONSUMER_SCRIPT" lessons baselito ai-engineering 4242 MERGED "$a65_h2" 2>&1)
  [[ ! -e "$a65_s2/pending-lessons-965.jsonl" ]] \
    || A65_FAILURES+=("(2 CONTROL) a fully-drained snapshot in a WRITABLE directory was not removed — the guard must not be bought by disabling the cleanup, or every future merge re-reads the same dead records forever: $A65_OUT2")
  printf '%s\n' "$A65_OUT2" | grep -q 'deleted=yes' \
    || A65_FAILURES+=("(2 CONTROL) a delete that genuinely happened was not reported as \`deleted=yes\`: $A65_OUT2")
  printf '%s\n' "$A65_OUT2" | grep -q 'WARN: could not remove' \
    && A65_FAILURES+=("(2 CONTROL) a successful delete still printed a survivor warning — a warning printed unconditionally carries no information: $A65_OUT2")
  rm -rf "$a65_h2"

  if [[ ${#A65_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: a fully-drained lessons snapshot in a directory that refuses unlink survived, was reported \`deleted=no\`, and was NAMED on stderr; the same fixture in a writable directory was removed, reported \`deleted=yes\` and printed no warning)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A65_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-66: THE SAME GUARD ON `defer` — THE FIFTH SIBLING
#
# `cmd_defer` carried the identical shape: `rm -f "$snap"` then `deleted=yes`,
# unconditional. Its own header already argues at length that the APPEND's
# status decides whether the snapshot may go — and then discarded the status of
# the delete that followed. That is the asymmetry class inside a single
# function.
#
# WHAT IT COSTS HERE IS SMALLER, and the test asserts the smaller thing rather
# than overclaiming: by the time the `rm` runs, the records are already in the
# deferred queue and the dedupe recognises them, so a surviving snapshot
# re-defers nothing — it reports them as `skipped` next time. The defect is the
# false STATUS, so that is what leg (1) pins.
#
# ⛔ THE FIXTURE HAS TO REACH THE `rm`, NOT DIE BEFORE IT. ⛔ A read-only
# ~/.claude would normally fail the APPEND first and return early with
# `deleted=no` — which would pass this test for entirely the wrong reason. So
# the deferred queue and the dismissed log are created (and left writable)
# BEFORE the directory is sealed: appending to an existing writable file needs
# no directory write, while unlinking does. Leg (1) therefore asserts
# `appended=1` as well — proof that the run really did get past the append and
# that the `rm` is the thing being measured.
# ---------------------------------------------------------------------------
TC="TC-STL-66: a deferred snapshot that could not be removed is not reported as deleted (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the defer subcommand validates every record with jq, so this behavioural test cannot run"
elif ! dir_unlink_is_blocked; then
  fail_test "$TC" "SETUP: a read-only directory does not refuse unlink for this user (running as root, or a filesystem that ignores mode bits) — the fixture would exercise the ordinary delete and pass for a reason unrelated to the guard"
else
  A66_FAILURES=()
  a66_f="A lessons finding deferred out of a snapshot that cannot be unlinked"

  # ---- leg (1): the defect. The append succeeds, the unlink is refused.
  a66_h=$(mktemp -d); a66_s="$a66_h/.claude"; mkdir -p "$a66_s"
  printf '{"finding":"%s","verdict":"defer","origin":"automated-review"}\n' "$a66_f" > "$a66_s/pending-lessons-966.jsonl"
  : > "$a66_s/pending-lessons-deferred.jsonl"   # exists + writable => the >> works
  : > "$a66_s/dismissed-lessons.log"            # exists + writable => the touch works
  chmod 644 "$a66_s/pending-lessons-deferred.jsonl" "$a66_s/dismissed-lessons.log"
  chmod 555 "$a66_s"
  A66_OUT1=$(HOME="$a66_h" bash "$CONSUMER_SCRIPT" defer baselito ai-engineering 966 2>&1)
  chmod 755 "$a66_s"

  printf '%s\n' "$A66_OUT1" | grep -q 'appended=1' \
    || A66_FAILURES+=("(1 SETUP) the run did not append its record, so it never reached the \`rm\` and nothing about the delete guard was exercised: $A66_OUT1")
  [[ -e "$a66_s/pending-lessons-966.jsonl" ]] \
    || A66_FAILURES+=("(1 SETUP) the snapshot was removed from a read-only directory, so the fixture never produced a failing unlink: $A66_OUT1")
  printf '%s\n' "$A66_OUT1" | grep -q 'deleted=yes' \
    && A66_FAILURES+=("(1) the run reported \`deleted=yes\` for a snapshot that is STILL ON DISK — the same false status as the unchecked dismissal append (C-2), on the sibling call site: $A66_OUT1")
  printf '%s\n' "$A66_OUT1" | grep -q 'deleted=no' \
    || A66_FAILURES+=("(1) a run whose delete was refused did not report \`deleted=no\`: $A66_OUT1")
  printf '%s\n' "$A66_OUT1" | grep -q 'WARN: could not remove pending-lessons-966.jsonl' \
    || A66_FAILURES+=("(1) the surviving snapshot was not NAMED on stderr: $A66_OUT1")
  # The records must NOT have been lost: they are in the queue, which is exactly
  # why this guard is about a false status and not about data loss.
  grep -q "$a66_f" "$a66_s/pending-lessons-deferred.jsonl" 2>/dev/null \
    || A66_FAILURES+=("(1) the record never reached the deferred queue — the guard must not be bought by refusing to defer at all: $A66_OUT1")
  rm -rf "$a66_h"

  # ---- leg (2): the control. Identical fixture, writable directory.
  a66_h2=$(mktemp -d); a66_s2="$a66_h2/.claude"; mkdir -p "$a66_s2"
  printf '{"finding":"%s","verdict":"defer","origin":"automated-review"}\n' "$a66_f" > "$a66_s2/pending-lessons-966.jsonl"
  : > "$a66_s2/pending-lessons-deferred.jsonl"
  A66_OUT2=$(HOME="$a66_h2" bash "$CONSUMER_SCRIPT" defer baselito ai-engineering 966 2>&1)
  [[ ! -e "$a66_s2/pending-lessons-966.jsonl" ]] \
    || A66_FAILURES+=("(2 CONTROL) a fully-deferred snapshot in a WRITABLE directory was not removed — the guard must not be bought by disabling the cleanup: $A66_OUT2")
  printf '%s\n' "$A66_OUT2" | grep -q 'deleted=yes' \
    || A66_FAILURES+=("(2 CONTROL) a delete that genuinely happened was not reported as \`deleted=yes\`: $A66_OUT2")
  printf '%s\n' "$A66_OUT2" | grep -q 'WARN: could not remove' \
    && A66_FAILURES+=("(2 CONTROL) a successful delete still printed a survivor warning — a warning printed unconditionally carries no information: $A66_OUT2")
  rm -rf "$a66_h2"

  if [[ ${#A66_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: a defer whose append SUCCEEDED but whose unlink was refused reported \`deleted=no\`, named the surviving snapshot on stderr and still left its record safely in the deferred queue; the same fixture in a writable directory removed the snapshot, reported \`deleted=yes\` and printed no warning)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A66_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-67: THE DELETE IS AUTHORIZED BY A CONFIRMED READ, NOT BY A LOOP ENDING
#
# ⛔ THE C-1 CRITICAL, SURVIVING IN A NARROWER FORM. ⛔ `cmd_lessons` decides a
# file is drained from `_f_records>0 && _f_failures==0 && _f_live==0` — all three
# of which are satisfied by an all-dismissed PREFIX of a file whose read failed
# partway through. `while IFS= read -r` cannot tell that apart from a clean EOF:
# bash returns 1 for both. Measured on the platform this suite runs on (GNU bash
# 3.2.57, the macOS system bash), where even a `-t` timeout — the one case the
# manual documents as returning >128 — returns 1. So the `[[ ! -f || ! -r ]]`
# pre-test catches "cannot open" and NOTHING caught "stopped reading partway",
# while the operation downstream is the `rm`.
#
# The fix is a confirming re-read whose exit status IS inspected, gating the
# delete only. WHAT THIS TEST CAN AND CANNOT PROVE, stated plainly rather than
# overclaimed: a genuine mid-read I/O error cannot be injected from a test (Codex
# could not inject one either), so this asserts the WIRING and its DIRECTION —
# when the confirming read cannot succeed, the file is preserved, counted as
# unreadable and named. It does not prove behaviour under a real EIO.
#
# The confirmation is made to fail by building a PATH without `cat`, using the
# suite's existing minimal-PATH helper. That is a genuine failure of the exact
# command the guard depends on, and it needs no special filesystem.
# ---------------------------------------------------------------------------
TC="TC-STL-67: a lessons delete needs a CONFIRMED read, not merely a loop that ended (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the lessons half parses JSONL with jq, so this behavioural test cannot run"
else
  A67_FAILURES=()
  a67_f="A lessons finding whose file cannot be confirmed read to the end"

  # ---- leg (1): the confirming read cannot succeed => nothing is deleted.
  a67_h=$(mktemp -d); a67_s="$a67_h/.claude"; mkdir -p "$a67_s"
  a67_min="$a67_h/minbin"
  a67_shell=$(command -v bash 2>/dev/null)
  printf '{"finding":"%s","verdict":"fixed","origin":"automated-review"}\n' "$a67_f" > "$a67_s/pending-lessons-967.jsonl"
  # Recorded with the ORDINARY PATH: `dismiss` reads the body from stdin with
  # `cat`, so it has to happen before `cat` is taken away — otherwise leg (1)
  # would fail at the dismissal and never reach the delete decision at all.
  consumer_dismiss "$a67_h" lesson "$a67_f" >/dev/null 2>&1
  if [[ ! -x "$a67_shell" ]] || ! consumer_minbin_without "$a67_min" cat; then
    A67_FAILURES+=("(1 SETUP) could not resolve bash or one of the tools the consumer calls, so a cat-absent PATH could not be built without also removing something else")
  else
    A67_OUT1=$(HOME="$a67_h" PATH="$a67_min" "$a67_shell" "$CONSUMER_SCRIPT" lessons baselito ai-engineering 4242 MERGED "$a67_h" 2>&1)
    [[ -e "$a67_s/pending-lessons-967.jsonl" ]] \
      || A67_FAILURES+=("(1) a snapshot whose read could NOT be confirmed was deleted anyway — every clause of the delete condition is satisfied by an all-dismissed PREFIX of a file that failed partway through, which is the C-1 CRITICAL in a narrower form: $A67_OUT1")
    printf '%s\n' "$A67_OUT1" | grep -q 'deleted=no' \
      || A67_FAILURES+=("(1) the run did not report \`deleted=no\` after refusing an unconfirmed delete: $A67_OUT1")
    printf '%s\n' "$A67_OUT1" | grep -q 'unreadable=1' \
      || A67_FAILURES+=("(1) the file was not counted as unreadable, so the run-wide fail-closed gate that suppresses EVERY deletion was never engaged: $A67_OUT1")
    printf '%s\n' "$A67_OUT1" | grep -q 'could not be read through to the end' \
      || A67_FAILURES+=("(1) the run did not SAY that a file could not be read through to the end — a preserved file with no explanation is the silent-skip the whole loop exists to end: $A67_OUT1")
  fi
  rm -rf "$a67_h"

  # ---- leg (2): the control. Same fixture, ordinary PATH, confirmation succeeds.
  # Green before and after: it is what stops the guard from being satisfied by a
  # cmd_lessons that has simply stopped deleting.
  a67_h2=$(mktemp -d); a67_s2="$a67_h2/.claude"; mkdir -p "$a67_s2"
  printf '{"finding":"%s","verdict":"fixed","origin":"automated-review"}\n' "$a67_f" > "$a67_s2/pending-lessons-967.jsonl"
  consumer_dismiss "$a67_h2" lesson "$a67_f" >/dev/null 2>&1
  A67_OUT2=$(HOME="$a67_h2" bash "$CONSUMER_SCRIPT" lessons baselito ai-engineering 4242 MERGED "$a67_h2" 2>&1)
  [[ ! -e "$a67_s2/pending-lessons-967.jsonl" ]] \
    || A67_FAILURES+=("(2 CONTROL) a snapshot whose read WAS confirmed was not deleted — the guard must not be bought by disabling the cleanup: $A67_OUT2")
  printf '%s\n' "$A67_OUT2" | grep -q 'deleted=yes' \
    || A67_FAILURES+=("(2 CONTROL) a confirmed, genuinely drained queue was not reported \`deleted=yes\`: $A67_OUT2")
  printf '%s\n' "$A67_OUT2" | grep -q 'unreadable=0' \
    || A67_FAILURES+=("(2 CONTROL) a readable file was counted as unreadable — a counter incremented unconditionally carries no information: $A67_OUT2")
  rm -rf "$a67_h2"

  if [[ ${#A67_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: with the confirming read unable to succeed, a snapshot passing every clause of the delete condition was PRESERVED, counted unreadable and named on stdout; with it succeeding, the same fixture was deleted and reported \`deleted=yes unreadable=0\`)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A67_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-68: A BROKEN TOOL MUST NOT BE DIAGNOSED AS A BAD CALLER
#
# `cmd_dismiss` was the ONLY subcommand with no `command -v` gate. Every sibling
# refuses with `refused=<cause>` at exit 0 when a tool it needs is missing; this
# one went straight to `body_hash`, got an empty string back, failed its own
# hash/body comparison and exited 2 saying "the supplied hash does not match the
# sha256 of the body … resolve the record again". The dismissal was valid. The
# tool was broken. The message blames the caller and sends them to re-resolve a
# record that was already resolved correctly — and the exit code disagrees with
# every other refusal in the file. Sixth recurrence of the asymmetry class on
# this branch.
#
# Nothing was ever written on that path, so this is about the DIAGNOSIS and the
# exit code, not about safety — and the test asserts exactly that, including leg
# (3), which keeps the genuine caller-bug case loud. Without leg (3) the new gate
# could have swallowed a real hash/body mismatch and the test would still pass.
# ---------------------------------------------------------------------------
TC="TC-STL-68: a missing shasum is refused as a tool failure, not blamed on the caller (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v shasum >/dev/null 2>&1; then
  fail_test "$TC" "shasum is not installed on this machine, so the control leg cannot record a real dismissal"
else
  A68_FAILURES=()
  a68_h=$(mktemp -d); a68_s="$a68_h/.claude"; mkdir -p "$a68_s"
  a68_min="$a68_h/minbin"
  a68_shell=$(command -v bash 2>/dev/null)
  a68_body="A lessons finding dismissed on a machine whose shasum is gone"
  # Derived with the REAL shasum, so the hash genuinely matches the body: leg (1)
  # must fail for the tool's absence and for nothing else.
  a68_hash=$(printf '%s' "$a68_body" | shasum -a 256 | awk '{print $1}')

  # ---- leg (1): shasum absent from PATH entirely.
  if [[ ! -x "$a68_shell" ]] || ! consumer_minbin_without "$a68_min" shasum; then
    A68_FAILURES+=("(1 SETUP) could not resolve bash or one of the tools the consumer calls, so a shasum-absent PATH could not be built without also removing something else")
  else
    A68_OUT1=$(printf '%s' "$a68_body" | HOME="$a68_h" PATH="$a68_min" "$a68_shell" "$CONSUMER_SCRIPT" dismiss lesson "$a68_hash" 2>&1)
    A68_RC1=$?
    [[ "$A68_RC1" -eq 0 ]] \
      || A68_FAILURES+=("(1) a dismissal refused for a MISSING TOOL exited $A68_RC1; every sibling refusal in this file returns 0 with a \`refused=\` token, and a usage exit code says the caller got the arguments wrong when the caller got them right: $A68_OUT1")
    printf '%s\n' "$A68_OUT1" | grep -q 'refused=no-shasum' \
      || A68_FAILURES+=("(1) the summary line did not name the missing tool as the cause: $A68_OUT1")
    printf '%s\n' "$A68_OUT1" | grep -q 'does not match the sha256' \
      && A68_FAILURES+=("(1) a valid dismissal on a machine with no shasum was diagnosed as a hash/body MISMATCH — the caller is told to resolve the record again, which is both wrong and unactionable: $A68_OUT1")
    [[ ! -s "$a68_s/dismissed-lessons.log" ]] \
      || A68_FAILURES+=("(1) something was written to the dismissed log on a run that could not derive a digest — an empty or partial key in that file suppresses records that were never decided: $(cat "$a68_s/dismissed-lessons.log")")
  fi

  # ---- leg (2): the control. Ordinary PATH, same body and hash.
  A68_OUT2=$(consumer_dismiss "$a68_h" lesson "$a68_body")
  printf '%s\n' "$A68_OUT2" | grep -q "recorded=${a68_hash:0:8}" \
    || A68_FAILURES+=("(2 CONTROL) a valid dismissal with shasum present did not record — the gate must not refuse the ordinary path: $A68_OUT2")
  [[ -s "$a68_s/dismissed-lessons.log" ]] \
    || A68_FAILURES+=("(2 CONTROL) the dismissed log is empty after a dismissal that reported success: $A68_OUT2")

  # ---- leg (3): the genuine caller bug must STAY loud.
  # A hash that does not match the body is a real mis-resolution, and it is what
  # stops a dismissal retiring the wrong snapshot. The new gate must not have
  # swallowed it.
  A68_OUT3=$(printf '%s' "a completely different body" | HOME="$a68_h" bash "$CONSUMER_SCRIPT" dismiss lesson "$a68_hash" 2>&1)
  A68_RC3=$?
  [[ "$A68_RC3" -eq 2 ]] \
    || A68_FAILURES+=("(3) a hash that genuinely does NOT match its body exited $A68_RC3 instead of 2 — the tool gate must not have swallowed the real caller-bug case, which is what stops a mis-resolved dismissal retiring the wrong record: $A68_OUT3")
  printf '%s\n' "$A68_OUT3" | grep -q 'does not match the sha256' \
    || A68_FAILURES+=("(3) a genuine hash/body mismatch no longer says so: $A68_OUT3")
  rm -rf "$a68_h"

  if [[ ${#A68_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: with shasum absent a valid dismissal returned 0 with \`refused=no-shasum\`, wrote nothing and did NOT claim a hash/body mismatch; with shasum present the same dismissal recorded; and a genuinely mismatched hash still exited 2 and said so)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A68_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-69: `defer` REPORTS THE READABILITY OF THE FILE THAT DECIDES ITS SKIPS
#
# TC-STL-64 established this property for `surface` and `archive`, which both
# emit `dismissed_log_unreadable=`. `defer` was the one pass that neither guarded
# nor reported it: `hash_logged_in` simply failed, and already-decided findings
# re-entered the deferred queue behind a summary line that looked identical to a
# clean run. Seventh recurrence of the asymmetry class on this branch, and the
# smallest — nothing is lost, because the next `lessons` read filters those
# records once the log is readable. The defect is the SILENCE.
#
# So this asserts REPORTING, not refusal, and leg (1) deliberately checks that
# the run still did its job: the records belong in the queue, and refusing to
# defer them would strand the snapshot the user just asked to hold.
# ---------------------------------------------------------------------------
TC="TC-STL-69: defer reports an unreadable dismissed-lessons log instead of failing quietly (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the defer subcommand validates every record with jq, so this behavioural test cannot run"
elif ! perms_are_enforced; then
  fail_test "$TC" "SETUP: chmod 000/444 are not enforced for this user (running as root, or a filesystem that ignores mode bits) — an unreadable-log fixture would test the ordinary path and pass for the wrong reason"
else
  A69_FAILURES=()
  a69_f="A lessons finding deferred while the dismissed log cannot be opened"

  # ---- leg (1): the dismissed log exists but cannot be read.
  a69_h=$(mktemp -d); a69_s="$a69_h/.claude"; mkdir -p "$a69_s"
  printf '{"finding":"%s","verdict":"defer","origin":"automated-review"}\n' "$a69_f" > "$a69_s/pending-lessons-969.jsonl"
  printf '[%064d] 2026-08-20T12:00:00Z | an unrelated already-decided finding\n' 0 > "$a69_s/dismissed-lessons.log"
  chmod 000 "$a69_s/dismissed-lessons.log"
  A69_OUT1=$(HOME="$a69_h" bash "$CONSUMER_SCRIPT" defer baselito ai-engineering 969 2>&1)
  chmod 644 "$a69_s/dismissed-lessons.log"

  printf '%s\n' "$A69_OUT1" | grep -q 'dismissed_log_unreadable=yes' \
    || A69_FAILURES+=("(1) the summary line did not report that the file deciding which findings to skip could not be opened — a run that cannot recognise an already-decided finding must not look identical to one that can: $A69_OUT1")
  # REPORTING, not refusal: the records still belong in the queue.
  printf '%s\n' "$A69_OUT1" | grep -q 'appended=1' \
    || A69_FAILURES+=("(1) the run stopped deferring because the dismissed log was unreadable — that would strand the snapshot the user just asked to hold, and nothing is at risk here since the next lessons read filters already-decided records: $A69_OUT1")
  grep -q "$a69_f" "$a69_s/pending-lessons-deferred.jsonl" 2>/dev/null \
    || A69_FAILURES+=("(1) the record never reached the deferred queue: $A69_OUT1")
  rm -rf "$a69_h"

  # ---- leg (2): the control. A readable log must NOT print the key as yes.
  a69_h2=$(mktemp -d); a69_s2="$a69_h2/.claude"; mkdir -p "$a69_s2"
  printf '{"finding":"%s","verdict":"defer","origin":"automated-review"}\n' "$a69_f" > "$a69_s2/pending-lessons-969.jsonl"
  A69_OUT2=$(HOME="$a69_h2" bash "$CONSUMER_SCRIPT" defer baselito ai-engineering 969 2>&1)
  printf '%s\n' "$A69_OUT2" | grep -q 'dismissed_log_unreadable=yes' \
    && A69_FAILURES+=("(2 CONTROL) a perfectly readable dismissed log was reported as unreadable — a key printed unconditionally carries no information: $A69_OUT2")
  printf '%s\n' "$A69_OUT2" | grep -q 'dismissed_log_unreadable=no' \
    || A69_FAILURES+=("(2 CONTROL) the key is absent from the ordinary path, so its presence on leg (1) says nothing about the guard: $A69_OUT2")
  rm -rf "$a69_h2"

  if [[ ${#A69_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: an unreadable dismissed-lessons log was named on defer's summary line while the run still appended its record to the queue, and a readable one reported the key as no)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A69_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-70: EVERY CONSUMER-INVOKING FENCE IN review-pr.md MUST PARSE AS SHELL
#
# The whole point of issue #140 was to stop the consumer being English an agent
# followed and make it a script a shell runs. A ```bash fence in review-pr.md
# that CANNOT be executed is that same defect one level down: the agent is told
# to run the block, bash dies before the call, and the store the block was
# supposed to drain is left exactly as inert as the prose was.
#
# The concrete regression this pins: the `lessons-defer` fence carried
# `PR_NUMBER=<the N from that line>` — a prose placeholder in executable
# position. `<` is input redirection and the spaces make the assignment
# invalid, so the fence was a SYNTAX ERROR, not a template. It was introduced
# by the fix for an INERT `defer` call, which is the sharper reason for this
# test: the fix round is where this class gets introduced, and nothing in the
# suite could see it.
#
# ⛔ SCOPE, AND WHY IT IS NOT "every fence in the file". ⛔ Measured, not
# assumed: at the parent commit 18 ```bash fences exist and 7 of them do not
# parse. Six are DELIBERATE pseudocode (`if no PR_NUMBER arg:`,
# `Bash(gh api …)`, `for id in $PROCESSED_IDS:`) — illustrative shapes nobody
# is asked to paste, and reddening on those would make this test noise that the
# next person deletes. The seventh was the defer fence. The dividing line that
# separates them is not style, it is CONSEQUENCE: a fence that invokes
# consume-deviations.sh is a fence an agent runs verbatim against a store that
# deletes files, and one that fails to parse strands that store. So the rule is
# exactly that, and it is stated as a rule rather than a list so a NEW call site
# is covered the day it is added.
#
# Leg (SETUP) fails closed on the extraction: an awk that stopped matching would
# check zero fences and pass in silence, which is the inert-detector shape
# (TL-0002) this suite is arranged against. Leg (CONTROL) proves `bash -n` can
# still reject the exact line that was here, so a green result means the fences
# are clean rather than that the checker stopped checking.
# ---------------------------------------------------------------------------
TC="TC-STL-70: every consume-deviations.sh fence in review-pr.md parses as shell (executed)"
A70_MD="$(cd "$(dirname "$0")/.." && pwd)/commands/review-pr.md"
if [[ ! -f "$A70_MD" ]]; then
  fail_test "$TC" "cannot locate commands/review-pr.md ($A70_MD)"
else
  A70_FAILURES=()
  a70_dir=$(mktemp -d)
  # Leading whitespace is allowed on the fence markers: the archive block sits
  # inside a numbered list and is indented three spaces, and an anchored-at-
  # column-0 pattern would silently skip it — one of the two fences this test
  # most needs to see.
  awk -v out="$a70_dir" '
    /^[[:space:]]*```bash[[:space:]]*$/ { n++; infence=1; f = out "/fence_" n ".sh"; next }
    /^[[:space:]]*```[[:space:]]*$/     { infence=0 }
    infence                             { print > f }
  ' "$A70_MD"

  a70_checked=0
  for a70_f in "$a70_dir"/fence_*.sh; do
    [[ -f "$a70_f" ]] || continue
    grep -q 'consume-deviations\.sh' "$a70_f" || continue
    a70_checked=$((a70_checked + 1))
    if ! a70_err=$(bash -n "$a70_f" 2>&1); then
      A70_FAILURES+=("a fence that INVOKES consume-deviations.sh does not parse as shell, so an agent told to run it gets a syntax error and the store it drains stays queued — bash -n said: $(printf '%s' "$a70_err" | tr '\n' ' ')")
    fi
  done

  # FAIL CLOSED on the extraction itself. Four such fences exist today (Step 0.5
  # surface, the canonical dismissal write, the archive cleanup, lessons-defer);
  # a floor rather than an equality so ADDING a call site does not redden this,
  # while an extractor that quietly matched nothing does.
  [[ "$a70_checked" -ge 4 ]] \
    || A70_FAILURES+=("(SETUP) only $a70_checked fence(s) invoking consume-deviations.sh were extracted from review-pr.md, expected at least 4 — the extraction is broken and this test would have passed without checking anything")

  # CONTROL: `bash -n` must still reject the exact line that caused this.
  printf 'PR_NUMBER=<the N from that line>\n' > "$a70_dir/control.sh"
  if bash -n "$a70_dir/control.sh" 2>/dev/null; then
    A70_FAILURES+=("(CONTROL) bash -n ACCEPTED \`PR_NUMBER=<the N from that line>\` — the checker cannot fail, so a green result above says nothing about the fences")
  fi
  rm -rf "$a70_dir"

  if [[ ${#A70_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (parsed all $a70_checked fences that invoke the consumer with bash -n; the control line that caused this — a prose placeholder in executable position — was still rejected)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A70_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-71: NO CONSUMER CALL SITE MAY ASK THE CURRENT DIRECTORY WHO IT IS
#
# `consume-deviations.sh` takes OWNER and REPO as an explicit argument pair and
# applies `is_toolbox_repo` to them. That gate is the only thing standing
# between a run and someone else's store, and a call site that fills those
# arguments from a BARE `gh repo view` hands the gate the identity of whatever
# checkout the shell happened to be in — in a turn that can be arbitrarily far
# from the one that surfaced the records. TL-0004 states the rule: repo
# identity cannot come from the checkout.
#
# ⛔ WHAT THIS PINS, AND WHAT IT DOES NOT. ⛔ Both reply-handler call sites
# (`archive` after a deviation triage, `defer` after `lessons-defer`) shipped
# the bare form, and the second one got it by being told to copy the first. The
# check therefore targets the SHAPE rather than either site by name, so the next
# copy is caught the day it is made. It does NOT prove the slug a human fills in
# is the right one — a typed value can be wrong, and nothing here can know that.
# It proves only that the value did not come from the cwd, which is the part
# that goes wrong SILENTLY.
#
# Step 0.1's own bare `gh repo view` is deliberately out of scope and stays: it
# runs in the SAME turn as the user's explicit `/review-pr`, where the checkout
# IS the answer. That fence does not invoke the consumer, which is exactly the
# boundary the fence filter draws.
#
# The control leg runs a synthetic line through the SAME function the fences go
# through — not through a pattern written next to it — so a green result cannot
# mean the matcher quietly stopped matching.
# ---------------------------------------------------------------------------
TC="TC-STL-71: no consume-deviations.sh call site derives repo identity from the cwd (executed)"

# Prints one line per violation found in the file it is given. Full-line
# comments are stripped first: every one of these fences DESCRIBES the bare form
# in prose to explain why it is banned, and a checker that could not tell prose
# from code would either redden on the explanation or force the explanation out.
a71_violations() {
  sed 's/[[:space:]]*#.*$//' "$1" | while IFS= read -r _l; do
    case "$_l" in
      *"gh repo view"*)
        # The token after `view` must exist and must not be an option: a repo
        # slug is positional, so `gh repo view --json …` is the bare form.
        printf '%s\n' "$_l" | grep -Eq 'gh repo view[[:space:]]+[^-[:space:]]' \
          || printf 'bare `gh repo view` (no repo argument): %s\n' "$_l"
        ;;
    esac
    case "$_l" in
      *"gh pr view"*)
        printf '%s\n' "$_l" | grep -Eq -- '--repo|REPO_FLAG' \
          || printf 'unqualified `gh pr view` (no --repo): %s\n' "$_l"
        ;;
    esac
  done
}

A71_MD="$(cd "$(dirname "$0")/.." && pwd)/commands/review-pr.md"
if [[ ! -f "$A71_MD" ]]; then
  fail_test "$TC" "cannot locate commands/review-pr.md ($A71_MD)"
else
  A71_FAILURES=()
  a71_dir=$(mktemp -d)
  awk -v out="$a71_dir" '
    /^[[:space:]]*```bash[[:space:]]*$/ { n++; infence=1; f = out "/fence_" n ".sh"; next }
    /^[[:space:]]*```[[:space:]]*$/     { infence=0 }
    infence                             { print > f }
  ' "$A71_MD"

  a71_checked=0
  a71_view_lines=0
  for a71_f in "$a71_dir"/fence_*.sh; do
    [[ -f "$a71_f" ]] || continue
    grep -q 'consume-deviations\.sh' "$a71_f" || continue
    a71_checked=$((a71_checked + 1))
    a71_view_lines=$((a71_view_lines + $(sed 's/[[:space:]]*#.*$//' "$a71_f" | grep -cE 'gh (repo|pr) view')))
    a71_bad=$(a71_violations "$a71_f")
    [[ -z "$a71_bad" ]] \
      || A71_FAILURES+=("a fence that invokes consume-deviations.sh resolves repo identity from the current directory, so the toolbox gate is answered by wherever the shell happens to be rather than by the invocation — $(printf '%s' "$a71_bad" | tr '\n' ' ')")
  done

  # FAIL CLOSED twice: on the extraction, and on there being any `gh … view`
  # left to inspect at all. Without the second, deleting every lookup would make
  # this test pass while saying nothing.
  [[ "$a71_checked" -ge 4 ]] \
    || A71_FAILURES+=("(SETUP) only $a71_checked fence(s) invoking consume-deviations.sh were extracted, expected at least 4 — the extraction is broken and nothing was inspected")
  [[ "$a71_view_lines" -ge 1 ]] \
    || A71_FAILURES+=("(SETUP) no \`gh repo view\`/\`gh pr view\` code line was found in any consumer fence — the matcher had nothing to judge, so a pass here is vacuous")

  # CONTROL: the exact bare form both call sites shipped, through the SAME
  # function, must still be reported.
  printf '%s\n' 'OWNER=$(gh repo view --json owner --jq '"'"'.owner.login'"'"' 2>/dev/null)' > "$a71_dir/control.sh"
  printf '%s\n' 'PR_URL=$(gh pr view "$PR_NUMBER" --json url --jq '"'"'.url'"'"')' >> "$a71_dir/control.sh"
  a71_ctl=$(a71_violations "$a71_dir/control.sh")
  [[ $(printf '%s\n' "$a71_ctl" | grep -c 'gh repo view') -ge 1 ]] \
    || A71_FAILURES+=("(CONTROL) the bare \`gh repo view --json owner\` form was NOT reported — the matcher cannot fail, so the green result above says nothing")
  [[ $(printf '%s\n' "$a71_ctl" | grep -c 'gh pr view') -ge 1 ]] \
    || A71_FAILURES+=("(CONTROL) an unqualified \`gh pr view\` was NOT reported — a lookup without --repo resolves against the checkout exactly as the bare repo view does")
  rm -rf "$a71_dir"

  if [[ ${#A71_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (inspected $a71_checked consumer fences carrying $a71_view_lines gh-view code line(s): every one names its repo explicitly, and the bare forms both call sites shipped were still reported by the same matcher)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A71_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-72: THE INSTALL MUST NOT WRITE THE CONSUMER THROUGH A PLANTED SYMLINK
#
# The previous round made the install atomic — stage, then rename — and picked
# `.consume-deviations.sh.$$.tmp` as the staging name. A PID is a small
# guessable integer, and `cp` FOLLOWS a symlink already at its destination. So
# anything able to write $CLAUDE_HOME/scripts could pre-create that name as a
# link and have the installer write this script's bytes to a target of its
# choosing — and the `mv` right after would then move the LINK into place,
# leaving every caller executing a file the attacker still controls. That is a
# security property, and a security property that cannot be made to fail is not
# a tested one.
#
# ⛔ WHY THIS EXECUTES THE INSTALLER'S OWN TEXT. ⛔ The block is extracted from
# scripts/install.sh verbatim and eval'd, so this cannot pass against a copy
# that has drifted from what ships. It is eval'd inside a SUBSHELL, which is
# what makes the fixture possible at all: in bash `$$` is the invoking shell's
# PID and a subshell inherits it, so the pre-fix staging path is exactly
# predictable from HERE — the test can plant the symlink at the very path the
# old code would have chosen. The subshell also keeps the stub `ok`/`warn` out
# of the suite's own namespace.
#
# Leg (3) is the one that makes legs (1) and (2) mean anything: it runs the
# PRE-FIX staging shape against the same fixture and requires the victim to be
# clobbered. Without it, "the victim was untouched" is equally consistent with a
# symlink planted at a path nothing ever looks at.
# ---------------------------------------------------------------------------
TC="TC-STL-72: the install stages through an exclusively-created file, not a guessable path (executed)"
A72_INSTALL="$SCRIPT_DIR/install.sh"
A72_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
A72_SRC="$A72_REPO/scripts/consume-deviations.sh"
if [[ ! -f "$A72_INSTALL" || ! -f "$A72_SRC" ]]; then
  fail_test "$TC" "cannot locate scripts/install.sh ($A72_INSTALL) or scripts/consume-deviations.sh ($A72_SRC)"
else
  A72_FAILURES=()
  # Verbatim extraction of the installer's consume-deviations block: from its
  # `if [ -f … ]; then` header to the first column-0 `fi`.
  a72_block=$(awk '
    /^if \[ -f "\$REPO_ROOT\/scripts\/consume-deviations\.sh" \]; then$/ { inb=1 }
    inb { print }
    inb && /^fi$/ { exit }
  ' "$A72_INSTALL")

  if ! printf '%s\n' "$a72_block" | grep -q 'consume-deviations\.sh' \
     || ! printf '%s\n' "$a72_block" | grep -q '^fi$'; then
    A72_FAILURES+=("(SETUP) could not extract the consume-deviations install block from install.sh — the header line or its closing \`fi\` moved, so nothing below executed the real installer")
  else
    # ---- leg (1): a symlink sitting at the PRE-FIX staging path.
    a72_h1=$(mktemp -d); mkdir -p "$a72_h1/scripts"
    printf 'VICTIM-CONTENTS-MUST-SURVIVE\n' > "$a72_h1/victim.txt"
    printf '#!/usr/bin/env bash\n# an older installed consumer\n' > "$a72_h1/scripts/consume-deviations.sh"
    ln -s "$a72_h1/victim.txt" "$a72_h1/scripts/.consume-deviations.sh.$$.tmp"
    (
      ok()   { :; }
      warn() { :; }
      CLAUDE_HOME="$a72_h1"
      REPO_ROOT="$A72_REPO"
      eval "$a72_block"
    ) >/dev/null 2>&1

    grep -q 'VICTIM-CONTENTS-MUST-SURVIVE' "$a72_h1/victim.txt" 2>/dev/null \
      || A72_FAILURES+=("(1) the installer wrote consume-deviations.sh THROUGH a symlink planted at its staging path — an arbitrary-file overwrite driven by a guessable name: $(head -c 120 "$a72_h1/victim.txt" 2>/dev/null)")
    [[ ! -L "$a72_h1/scripts/consume-deviations.sh" ]] \
      || A72_FAILURES+=("(1) the installed consumer is now itself a SYMLINK — the staged 'file' was the planted link and \`mv\` relocated it into place, so every caller executes a target the planter chooses")
    cmp -s "$A72_SRC" "$a72_h1/scripts/consume-deviations.sh" \
      || A72_FAILURES+=("(1) the install did not complete despite the staging path being irrelevant to it — a planted symlink must be ignored, not turned into an install failure")
    rm -rf "$a72_h1"

    # ---- leg (2): the control. No symlink, ordinary install.
    a72_h2=$(mktemp -d); mkdir -p "$a72_h2/scripts"
    (
      ok()   { :; }
      warn() { :; }
      CLAUDE_HOME="$a72_h2"
      REPO_ROOT="$A72_REPO"
      eval "$a72_block"
    ) >/dev/null 2>&1
    cmp -s "$A72_SRC" "$a72_h2/scripts/consume-deviations.sh" \
      || A72_FAILURES+=("(2 CONTROL) the ordinary install did not produce a byte-identical copy — the guard must not be bought by an installer that stopped installing")
    [[ -x "$a72_h2/scripts/consume-deviations.sh" ]] \
      || A72_FAILURES+=("(2 CONTROL) the installed consumer is not executable — mktemp creates 0600, so the mode has to be set on the staged file before the rename")
    # No staging residue may survive either outcome.
    a72_left=$(find "$a72_h2/scripts" -name '.consume-deviations.sh.*' 2>/dev/null | wc -l | tr -d ' ')
    [[ "$a72_left" -eq 0 ]] \
      || A72_FAILURES+=("(2 CONTROL) $a72_left staging file(s) were left behind in the scripts directory")
    rm -rf "$a72_h2"

    # ---- leg (3): the fixture must be able to reach the victim.
    # The PRE-FIX shape, re-created deliberately: a `$$`-derived staging path fed
    # straight to `cp`. If THIS does not clobber the victim, leg (1) proves
    # nothing and the symlink is being planted somewhere nothing looks.
    a72_h3=$(mktemp -d); mkdir -p "$a72_h3/scripts"
    printf 'VICTIM-CONTENTS-MUST-SURVIVE\n' > "$a72_h3/victim.txt"
    ln -s "$a72_h3/victim.txt" "$a72_h3/scripts/.consume-deviations.sh.$$.tmp"
    cp "$A72_SRC" "$a72_h3/scripts/.consume-deviations.sh.$$.tmp" 2>/dev/null
    grep -q 'VICTIM-CONTENTS-MUST-SURVIVE' "$a72_h3/victim.txt" 2>/dev/null \
      && A72_FAILURES+=("(3 FIXTURE) the pre-fix \`cp\` to the \$\$-derived staging path did NOT reach the planted symlink's target, so leg (1) is not observing anything — the fixture path or \$\$ does not match what the old code used")
    rm -rf "$a72_h3"

    # ---- leg (4): the staging PATH replaced between creation and copy.
    # mktemp closes the creation race; it does NOT stop the pathname being
    # swapped afterwards, because `cp`/`chmod`/`mv` all reopen it by name. That
    # residual window is reached here by stubbing `mktemp` itself to hand back a
    # path that IS a symlink — the state the block would be in had an actor
    # unlinked the staged file and dropped a link there a moment later.
    #
    # ⛔ WHAT THIS LEG ASSERTS IS NARROWER THAN LEG (1), DELIBERATELY. ⛔ By the
    # time the `! -L` test runs, `cp` has ALREADY written through the link, and
    # that write is not recoverable in this block — so this does NOT assert the
    # victim's contents survived, which would be a claim the code cannot support.
    # It asserts the two things the one-line test does buy: the link is not
    # renamed into place as the live consumer (the severe half — that is what
    # would leave every later /review-pr executing attacker-chosen content), the
    # previously installed copy is left intact, and the cleanup removes the LINK
    # rather than following it to delete the target.
    a72_h4=$(mktemp -d); mkdir -p "$a72_h4/scripts" "$a72_h4/stub"
    printf 'VICTIM\n' > "$a72_h4/victim.txt"
    printf '#!/usr/bin/env bash\n# PRIOR-INSTALLED-CONSUMER\n' > "$a72_h4/scripts/consume-deviations.sh"
    # A `mktemp` that returns a symlink instead of the regular file it promises.
    printf '#!/bin/sh\np=$(printf "%%s" "$1" | sed "s/XXXXXX$/ZZZZZZ/")\nln -s "%s" "$p"\nprintf "%%s\\n" "$p"\n' \
      "$a72_h4/victim.txt" > "$a72_h4/stub/mktemp"
    chmod +x "$a72_h4/stub/mktemp"
    (
      ok()   { :; }
      warn() { :; }
      PATH="$a72_h4/stub:$PATH"
      CLAUDE_HOME="$a72_h4"
      REPO_ROOT="$A72_REPO"
      eval "$a72_block"
    ) >/dev/null 2>&1

    [[ ! -L "$a72_h4/scripts/consume-deviations.sh" ]] \
      || A72_FAILURES+=("(4) a staging path that was a SYMLINK when the copy ran got renamed into place, so the installed consumer is now a link to attacker-chosen content and every later /review-pr executes it")
    grep -q 'PRIOR-INSTALLED-CONSUMER' "$a72_h4/scripts/consume-deviations.sh" 2>/dev/null \
      || A72_FAILURES+=("(4) the previously installed consumer was replaced on a run that could not verify its own staging file — a refusal must leave the working copy alone: $(head -c 120 "$a72_h4/scripts/consume-deviations.sh" 2>/dev/null)")
    [[ -e "$a72_h4/victim.txt" ]] \
      || A72_FAILURES+=("(4) the failure-branch cleanup followed the staging symlink and DELETED its target — \`rm -f\` must remove the link, not what it points at")
    [[ ! -e "$a72_h4/scripts/.consume-deviations.sh.ZZZZZZ" ]] \
      || A72_FAILURES+=("(4) the staging symlink was left behind in the scripts directory after the refusal")
    rm -rf "$a72_h4"
  fi

  if [[ ${#A72_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed install.sh's own block: a symlink planted at the pre-fix \$\$ staging path was ignored and its victim survived; the ordinary install is a regular executable byte-identical copy with no staging residue; the pre-fix shape demonstrably DOES clobber that victim, so the fixture reaches it; and a staging path that was a symlink AT COPY TIME was refused rather than renamed into place, leaving the prior install intact and removing the link rather than its target)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A72_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-73: A shasum THAT EXISTS AND DOES NOT WORK IS STILL A TOOL FAILURE
#
# TC-STL-68 pinned the ABSENT case. The gate it pinned is `command -v shasum`,
# which answers exactly one question — is there a shasum on PATH — and the
# comment written beside it in the same round said it handled a tool that was
# "missing or broken". It handled absence only, and the gap is on the same
# ordinary path: a shasum that exists and fails at runtime (broken install, stub
# on PATH, read error) leaves `body_hash` returning an empty or partial string,
# which flows into the hash comparison and produces the caller-blaming exit 2
# the gate was added to remove. Measured at the parent commit: a stub exiting 7
# gave `rc=2` and "does not match the sha256 of the body".
#
# ⛔ TWO BROKEN SHAPES, NOT ONE. ⛔ Leg (1) is the tool that fails loudly
# (non-zero, no output). Leg (2) is the tool that exits ZERO and prints
# something that is not a digest — the shape an exit-status check would wave
# through, which is why the production guard tests the digest for BEING a digest
# rather than testing shasum's return code.
#
# Legs (3) and (4) are the two directions the guard must not buy its pass with:
# the ordinary dismissal must still record, and a GENUINE caller mis-resolution
# must still exit 2 and say so. Without (4) this gate could have swallowed the
# real hash/body mismatch — the one thing stopping a mis-resolved dismissal
# retiring the wrong snapshot — and the test would still be green.
#
# What is deliberately NOT asserted, because the production comment now says the
# same: a shasum returning a WELL-FORMED 64-hex digest that is simply wrong is
# indistinguishable from a caller mis-resolution and still exits 2. No local
# check can separate them.
# ---------------------------------------------------------------------------
TC="TC-STL-73: a shasum that runs and fails is refused as a tool failure, not blamed on the caller (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v shasum >/dev/null 2>&1; then
  fail_test "$TC" "shasum is not installed on this machine, so the control leg cannot record a real dismissal"
else
  A73_FAILURES=()
  a73_h=$(mktemp -d); a73_s="$a73_h/.claude"; mkdir -p "$a73_s"
  a73_min="$a73_h/minbin"
  a73_shell=$(command -v bash 2>/dev/null)
  a73_body="A lessons finding dismissed on a machine whose shasum is broken"
  # Derived with the REAL shasum, so the hash genuinely matches the body: the
  # broken-tool legs must fail for the tool and for nothing else.
  a73_hash=$(printf '%s' "$a73_body" | shasum -a 256 | awk '{print $1}')

  # A PATH holding every tool the consumer needs EXCEPT shasum, into which each
  # leg then drops its own broken stub.
  if [[ ! -x "$a73_shell" ]] || ! consumer_minbin_without "$a73_min" shasum; then
    A73_FAILURES+=("(SETUP) could not resolve bash or one of the tools the consumer calls, so a broken-shasum PATH could not be built without also removing something else")
  else
    # ---- leg (1): shasum present, exits non-zero, prints nothing.
    printf '#!/bin/sh\nexit 7\n' > "$a73_min/shasum"; chmod +x "$a73_min/shasum"
    A73_OUT1=$(printf '%s' "$a73_body" | HOME="$a73_h" PATH="$a73_min" "$a73_shell" "$CONSUMER_SCRIPT" dismiss lesson "$a73_hash" 2>&1)
    A73_RC1=$?
    [[ "$A73_RC1" -eq 0 ]] \
      || A73_FAILURES+=("(1) a dismissal refused for a BROKEN TOOL exited $A73_RC1; every refusal in this file returns 0 with a \`refused=\` token, and a usage exit code says the caller got the arguments wrong when the caller got them right: $A73_OUT1")
    printf '%s\n' "$A73_OUT1" | grep -q 'refused=unusable-shasum' \
      || A73_FAILURES+=("(1) the summary line did not name the unusable tool as the cause: $A73_OUT1")
    printf '%s\n' "$A73_OUT1" | grep -q 'does not match the sha256' \
      && A73_FAILURES+=("(1) a valid dismissal on a machine with a BROKEN shasum was diagnosed as a hash/body MISMATCH — the exact misdiagnosis the presence check was added to remove, still reachable because presence is not usability: $A73_OUT1")
    [[ ! -s "$a73_s/dismissed-lessons.log" ]] \
      || A73_FAILURES+=("(1) something was written to the dismissed log on a run that could not derive a digest — an empty or partial key in that file suppresses records that were never decided: $(cat "$a73_s/dismissed-lessons.log")")

    # ---- leg (2): shasum present, exits ZERO, prints a non-digest.
    # This is the shape a return-code check would accept.
    printf '#!/bin/sh\nprintf %%s "not-a-digest"\nexit 0\n' > "$a73_min/shasum"; chmod +x "$a73_min/shasum"
    A73_OUT2=$(printf '%s' "$a73_body" | HOME="$a73_h" PATH="$a73_min" "$a73_shell" "$CONSUMER_SCRIPT" dismiss lesson "$a73_hash" 2>&1)
    A73_RC2=$?
    [[ "$A73_RC2" -eq 0 ]] \
      || A73_FAILURES+=("(2) a shasum that exited 0 with non-digest output exited $A73_RC2 — a guard that only checks the return code would have let this through to the caller-blaming comparison: $A73_OUT2")
    printf '%s\n' "$A73_OUT2" | grep -q 'refused=unusable-shasum' \
      || A73_FAILURES+=("(2) the summary line did not name the unusable tool as the cause: $A73_OUT2")
    [[ ! -s "$a73_s/dismissed-lessons.log" ]] \
      || A73_FAILURES+=("(2) something was written to the dismissed log from a non-digest key: $(cat "$a73_s/dismissed-lessons.log")")

    # ---- leg (5): the third broken shape — FAILS but prints a valid digest.
    # This is the one a SHAPE-only check waves through, exactly as leg (2) is the
    # one a STATUS-only check waves through. The stub prints the genuinely
    # correct digest for the body and then exits 7, so nothing about the value
    # is wrong — only the tool is — and a guard that trusted the shape alone
    # would sail past into the comparison and record the dismissal.
    #
    # This depends on `set -o pipefail` at the top of the consumer: without it
    # the failing shasum's status is masked by the `awk` at the end of
    # `body_hash`'s pipeline and `hash_rc` reads 0. Verified both ways before
    # this landed (with pipefail rc=7, without it rc=0), so if that `set` line
    # is ever removed this leg is what notices.
    printf '#!/bin/sh\nprintf "%%s  -\\n" "%s"\nexit 7\n' "$a73_hash" > "$a73_min/shasum"
    chmod +x "$a73_min/shasum"
    A73_OUT5=$(printf '%s' "$a73_body" | HOME="$a73_h" PATH="$a73_min" "$a73_shell" "$CONSUMER_SCRIPT" dismiss lesson "$a73_hash" 2>&1)
    A73_RC5=$?
    [[ "$A73_RC5" -eq 0 ]] \
      || A73_FAILURES+=("(5) a shasum that FAILED while printing a well-formed digest exited $A73_RC5 instead of refusing at 0: $A73_OUT5")
    printf '%s\n' "$A73_OUT5" | grep -q 'refused=unusable-shasum' \
      || A73_FAILURES+=("(5) a shasum that exited non-zero was not reported as an unusable tool — its output is 64-hex-shaped, so a check on the DIGEST alone lets a failed hashing command reach the comparison: $A73_OUT5")
    [[ ! -s "$a73_s/dismissed-lessons.log" ]] \
      || A73_FAILURES+=("(5) a dismissal was recorded from the output of a hashing command that reported failure: $(cat "$a73_s/dismissed-lessons.log")")
  fi

  # ---- leg (3): the control. Ordinary PATH, same body and hash, must record.
  A73_OUT3=$(consumer_dismiss "$a73_h" lesson "$a73_body")
  printf '%s\n' "$A73_OUT3" | grep -q "recorded=${a73_hash:0:8}" \
    || A73_FAILURES+=("(3 CONTROL) a valid dismissal with a working shasum did not record — the new shape check must not refuse the ordinary path: $A73_OUT3")

  # ---- leg (4): the genuine caller bug must STAY loud.
  A73_OUT4=$(printf '%s' "a completely different body" | HOME="$a73_h" bash "$CONSUMER_SCRIPT" dismiss lesson "$a73_hash" 2>&1)
  A73_RC4=$?
  [[ "$A73_RC4" -eq 2 ]] \
    || A73_FAILURES+=("(4) a hash that genuinely does NOT match its body exited $A73_RC4 instead of 2 — the shape check must not have swallowed the real caller-bug case, which is what stops a mis-resolved dismissal retiring the wrong record: $A73_OUT4")
  printf '%s\n' "$A73_OUT4" | grep -q 'does not match the sha256' \
    || A73_FAILURES+=("(4) a genuine hash/body mismatch no longer says so: $A73_OUT4")
  rm -rf "$a73_h"

  if [[ ${#A73_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: all three broken shapes — exit 7 silent, exit 0 with non-digest output, and exit 7 WITH a well-formed correct digest — returned 0 with \`refused=unusable-shasum\`, wrote nothing and did NOT claim a hash/body mismatch; the ordinary dismissal still recorded; and a genuinely mismatched hash still exited 2 and said so)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A73_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-25: the fold's deviation extractor STOPS at the next h2 phase block
#
# WHY: scripts/pr-postmerge-fold.sh extracts deviations from .claude/handover.md
# with a small awk state machine. `### Deviations` sets an `inside` flag, and
# `### <anything-else>` clears it — but `## <next phase>` did NOT clear it. A
# handover file is a sequence of `## <phase>` blocks, and many of them open with
# plain `- ` bullets (phase-card metadata: which agent ran, "Jira: n/a", the PR
# link) BEFORE their first `### ` sub-heading. So once ANY phase's Deviations
# section had been entered, every such bullet in every LATER phase block was
# captured as if it were a deviation.
#
# This is not hypothetical. ~/.claude/pending-deviations-122.log holds 21
# records, of which roughly half are phase-card metadata lines like
# "Agent: chief-of-staff", "Jira: n/a - toolbox self-change" and
# "PR #122 (...) targeting main". Those records then consume the surface's
# triage cap and the user's attention, pushing real deviations out of view.
#
# The fixture below is the minimum shape that reproduces it: a Deviations
# section, then a NEW h2 block whose first lines are bullets. Only the two
# bullets under `### Deviations` may appear in the snapshot.
#
# The test drives the REAL script (not a re-implementation of its awk) so it
# cannot pass against a copy that has drifted from production. `gh` is stubbed
# out on PATH because the script's lessons half calls `gh pr view`; the stub
# keeps this test offline and deterministic.
# ---------------------------------------------------------------------------
TC="TC-STL-25: fold stops capturing deviations at the next h2 phase block"
FOLD_SCRIPT="$SCRIPT_DIR/pr-postmerge-fold.sh"
if [[ ! -f "$FOLD_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/pr-postmerge-fold.sh ($FOLD_SCRIPT)"
else
  tmp_home=$(mktemp -d)
  fake_repo=$(mktemp -d)
  stub_bin=$(mktemp -d)
  mkdir -p "$fake_repo/.claude"

  # Stub `gh` so the script cannot reach the network. It used to `exit 1`, which
  # the lessons half handles (`|| echo ''`) — but the deviation half now READS
  # this call for the PR's merge time and fails CLOSED when it cannot get one
  # (issue #154, pinned by TC-STL-74). An `exit 1` stub would therefore make this
  # test assert the refusal path instead of the awk it is about. The stub answers
  # with a merge that happened seconds ago — /merge-pr's at-merge case — so the
  # gate opens and the extractor under test actually runs.
  tc25_merged_at=$(date -u -r "$(date -u +%s)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$(date -u +%s)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\t%%s\\t%%s\\n" "%s" "fixture/branch" "fixture PR title and body"\n' "$tc25_merged_at"
  } > "$stub_bin/gh"
  chmod +x "$stub_bin/gh"

  # The script only reads handover.md when the checkout's origin slug matches
  # the OWNER/REPO_NAME it was given, so the fixture repo needs a real remote.
  git -C "$fake_repo" init -q 2>/dev/null
  git -C "$fake_repo" remote add origin https://github.com/baselito/ai-toolbox.git 2>/dev/null

  # ASCII-only phase names: the assertions below are greps, so an em-dash in a
  # phase title would make the pattern harder to read for no benefit.
  cat > "$fake_repo/.claude/handover.md" <<'HANDOVER'
# Handover

## Discovery fixture phase
Completed: 2026-01-01

### What was done
- unrelated bullet that is not a deviation

### Deviations
- REAL-DEVIATION-ONE belongs to the Discovery block
- REAL-DEVIATION-TWO belongs to the Discovery block

## Investigation Gate fixture phase
- PHASE-CARD-METADATA bullet that must never be captured
- ANOTHER-PHASE-CARD-METADATA bullet that must never be captured

## Verification fixture phase

### Deviations
- SENTINEL-QUOTING-DEVIATION: the checklist said "None observed." before we skipped review
- None observed.

Blockers: none
HANDOVER

  HOME="$tmp_home" PATH="$stub_bin:$PATH" \
    bash "$FOLD_SCRIPT" baselito ai-engineering 4242 "$fake_repo" >/dev/null 2>&1

  SNAP="$tmp_home/.claude/pending-deviations-4242.log"
  if [[ ! -f "$SNAP" ]]; then
    fail_test "$TC" "no snapshot written to $SNAP — the fixture never reached the awk (check the origin-slug gate)"
  else
    REC_COUNT=$(grep -c . "$SNAP" || true)
    LEAKED=$(grep -c 'PHASE-CARD-METADATA' "$SNAP" || true)
    LEAKED_PHASE=$(grep -c '"phase":"Investigation Gate fixture phase"' "$SNAP" || true)
    GOT_ONE=$(grep -c 'REAL-DEVIATION-ONE' "$SNAP" || true)
    GOT_TWO=$(grep -c 'REAL-DEVIATION-TWO' "$SNAP" || true)
    # ⛔ THE BASELINE SENTINEL IS AN EXACT BODY, NOT A SUBSTRING. ⛔
    # The emit() filter was `buf ~ /None observed\./` — a regex SEARCH — so ANY
    # deviation whose text happened to contain the sentinel phrase was discarded
    # with no warning, no count and no snapshot line. That is an UNDER-capture,
    # the worst failure this pipeline has, because the backlog reporter can only
    # count what reached a snapshot. And the body is not exotic: a deviation
    # about review discipline quotes the phrase naturally, which is exactly the
    # kind of process failure the loop exists to capture. Both directions are
    # pinned here — the quoting deviation must survive, the bare sentinel must
    # still be dropped — because a fix that captured everything would be as wrong
    # as the bug.
    # FALSIFYING EDITS: restore `buf ~ /None observed\./` (GOT_SENTINEL drops to
    # 0); drop the sentinel filter entirely (GOT_BASELINE rises to 1).
    GOT_SENTINEL=$(grep -c 'SENTINEL-QUOTING-DEVIATION' "$SNAP" || true)
    GOT_BASELINE=$(grep -c '"body":"None observed\."' "$SNAP" || true)

    if [[ "$LEAKED" -ne 0 || "$LEAKED_PHASE" -ne 0 ]]; then
      fail_test "$TC" "over-capture: $LEAKED metadata bullet(s) and $LEAKED_PHASE record(s) attributed to the following h2 block leaked into the snapshot (\`## \` must clear the Deviations flag)"
    elif [[ "$GOT_ONE" -ne 1 || "$GOT_TWO" -ne 1 ]]; then
      fail_test "$TC" "under-capture: expected both real deviations exactly once, got ONE=$GOT_ONE TWO=$GOT_TWO (the fix must not swallow genuine deviations)"
    elif [[ "$GOT_SENTINEL" -ne 1 ]]; then
      fail_test "$TC" "under-capture: a genuine deviation whose body QUOTES the baseline sentinel was captured $GOT_SENTINEL time(s), expected 1 — the sentinel filter is matching a substring instead of comparing the whole body, so any deviation mentioning 'None observed.' is silently dropped"
    elif [[ "$GOT_BASELINE" -ne 0 ]]; then
      fail_test "$TC" "over-capture: the bare baseline sentinel body was captured $GOT_BASELINE time(s), expected 0 — 'None observed.' is a no-deviation report, not a deviation"
    elif [[ "$REC_COUNT" -ne 3 ]]; then
      fail_test "$TC" "expected exactly 3 records (2 Discovery deviations + the sentinel-quoting one), got $REC_COUNT"
    else
      pass_test "$TC (3 records: both Discovery deviations plus the one quoting the sentinel; bare sentinel dropped, zero metadata leakage)"
    fi
  fi
  rm -rf "$tmp_home" "$fake_repo" "$stub_bin"
fi

# ---------------------------------------------------------------------------
# TC-STL-26: ARCHIVING A SNAPSHOT REQUIRES A DISMISSAL, NOT A SURFACING —
#            asserted by EXECUTING the consumer, not by reading it
#
# WHY this test exists: this is the "the loop looks drained but is not"
# regression, and it has now shipped TWICE — once as the stranded per-PR read
# (TC-STL-24), and once as the archive pass consulting surfaced-deviations.log.
# The second one is the subtle one. A record PRINTED ONCE into an unattended
# `--auto` cron session that nobody was watching counted as accounted-for; its
# snapshot was archived; `dir_has_file "$CONSUMED_DIR"` then flipped
# DEV_LOOP_COMPLETED in scripts/selfimprovement-backlog.sh; and a queue with
# ZERO human decisions reported as "OK: no self-improvement backlog". Every
# stage said success and no deviation was ever triaged.
#
# WHY IT RUNS THE SCRIPT instead of grepping a spec: "the surfaced read is in
# the surface pass" is a proxy for the invariant, not the invariant. The
# invariant is a BEHAVIOUR: surfacing must leave the snapshot queued, and only a
# dismissal may retire it. So this test runs scripts/consume-deviations.sh three
# times against a temp state dir:
#   run 1 — two fresh records: both are shown, and NOTHING is archived.
#   run 2 — same state, no decisions: prints "nothing new to triage" AND STILL
#           archives nothing. This is the trap: the run LOOKS drained.
#   run 3 — both hashes appended to dismissed-deviations.log: NOW it archives.
# Proven RED before the fix by re-adding the surfaced read to the archive pass:
# run 1 alone archived the snapshot while dismissed-deviations.log was 0 bytes.
#
# WHY THERE IS NO LONGER A VACUITY GUARD ON THE EXTRACTION: there is no
# extraction. This used to cut a line range out of commands/review-pr.md and had
# to prove the cut contained a sweep and an `mv`, because otherwise "nothing was
# archived" passed against an empty string. The subject is now a real script
# invoked by path, and run 3 is the positive control that proves it CAN archive —
# so a consumer that did nothing at all fails run 1 and run 3 rather than
# silently satisfying runs 1 and 2.
# ---------------------------------------------------------------------------
TC="TC-STL-26: surfacing does not archive; only a dismissal does (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the deviation consumer parses JSONL with jq, so this behavioural test cannot run (jq is a documented toolbox dependency; install it: brew install jq / apt install jq)"
else
  a26_home=$(mktemp -d)
  a26_state="$a26_home/.claude"
  mkdir -p "$a26_state"

  # `attended` on every run here, and it must be explicit: the caller
  # (commands/review-pr.md Step 0.5) defaults an unset --auto flag to unattended,
  # which never records what it printed. This test is about the
  # surfaced/dismissed split on a run a human is watching, so it says so rather
  # than inheriting a default. TC-STL-29 covers the unattended leg.

  # Two records with stable, single-line bodies. The hashes are computed here
  # with the SAME formula the consumer uses, independently of anything the
  # consumer writes — so run 3's fixture is not derived from run 1's output.
  a26_body1="RECORD ONE alpha"
  a26_body2="RECORD TWO beta"
  # TWO forms per record, because the consumer uses two: the FULL digest is the
  # key written into the dismissed/surfaced logs, and the first 8 characters are
  # what the surface message prints for a human to retype. Asserting on the wrong
  # one silently stops testing anything, so both are derived here with the same
  # formula the consumer uses, independently of anything the consumer writes.
  a26_f1=$(printf '%s' "$a26_body1" | shasum -a 256 | awk '{print $1}')
  a26_f2=$(printf '%s' "$a26_body2" | shasum -a 256 | awk '{print $1}')
  a26_h1=${a26_f1:0:8}
  a26_h2=${a26_f2:0:8}
  printf '{"ts":"2026-01-01T00:00:00Z","phase":"Implementation","body":"%s"}\n' "$a26_body1" \
    > "$a26_state/pending-deviations-777.log"
  printf '{"ts":"2026-01-01T00:00:01Z","phase":"Verification","body":"%s"}\n' "$a26_body2" \
    >> "$a26_state/pending-deviations-777.log"

  a26_archived() { find "$a26_state/consumed-deviations" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' '; }
  a26_queued()   { find "$a26_state" -maxdepth 1 -type f -name 'pending-deviations-*.log' 2>/dev/null | wc -l | tr -d ' '; }

  A26_FAILURES=()
  if true; then
    # --- run 1: surface two fresh records ---
    A26_OUT1=$(consumer_run "$a26_home" attended)
    printf '%s\n' "$A26_OUT1" | grep -q "$a26_h1" || A26_FAILURES+=("run 1 did not surface record 1 (hash $a26_h1) — the consumer showed nothing, so the rest of this test would prove nothing")
    printf '%s\n' "$A26_OUT1" | grep -q "$a26_h2" || A26_FAILURES+=("run 1 did not surface record 2 (hash $a26_h2)")
    A26_ARCH1=$(a26_archived); A26_QUEUE1=$(a26_queued)
    # ⛔ THE INVARIANT. ⛔ Being shown is not being decided.
    [[ "$A26_ARCH1" -eq 0 ]] || A26_FAILURES+=("run 1 ARCHIVED $A26_ARCH1 snapshot(s) after merely SURFACING them — a record printed into an unattended --auto session must never retire its snapshot")
    [[ "$A26_QUEUE1" -eq 1 ]] || A26_FAILURES+=("run 1 left $A26_QUEUE1 queued snapshot(s), expected 1 — surfacing must leave the file in place")

    # --- run 2: same state, still no decisions ---
    # The output here is the trap: it says "nothing new to triage", which reads
    # like a drained queue. The file must still be on disk so
    # selfimprovement-backlog.sh keeps reporting it.
    A26_OUT2=$(consumer_run "$a26_home" attended)
    A26_ARCH2=$(a26_archived); A26_QUEUE2=$(a26_queued)
    printf '%s\n' "$A26_OUT2" | grep -q 'nothing new to triage' \
      || A26_FAILURES+=("run 2 did not report 'nothing new to triage' — expected the already-surfaced path: $A26_OUT2")
    [[ "$A26_ARCH2" -eq 0 ]] || A26_FAILURES+=("run 2 ARCHIVED $A26_ARCH2 snapshot(s) with dismissed-deviations.log still empty — this is the silent drain: every stage reports success and nothing was ever triaged")
    [[ "$A26_QUEUE2" -eq 1 ]] || A26_FAILURES+=("run 2 left $A26_QUEUE2 queued snapshot(s), expected 1 — 'nothing new to PRINT' must not mean 'the queue is empty'")
    [[ -s "$a26_state/dismissed-deviations.log" ]] \
      && A26_FAILURES+=("run 2 wrote to dismissed-deviations.log — surfacing must never record a decision on the user's behalf")

    # --- run 2b: the surfaced markers are now ANCIENT. Still not decided. ---
    # ⛔ TIME MUST NEVER BECOME A DECISION. ⛔ Runs 1 and 2 both write their
    # surfaced markers "now", so they can only ever catch a rule that treats
    # being-shown as deciding. They structurally CANNOT catch the tacit-acceptance
    # variant of the same idea — "a record surfaced more than N days ago and never
    # objected to is settled; archive it" — which is a plausible future
    # convenience and is the identical silent drain wearing a timestamp: nobody
    # decided anything, the snapshot retires, and
    # scripts/selfimprovement-backlog.sh reports the loop drained. The whole point
    # of the surfaced/dismissed split is that only a HUMAN DECISION retires a
    # snapshot, and a clock is not a human.
    #
    # Both plausible implementations of "how old is this marker" are aged out, so
    # neither is left as an untested path: the ISO timestamp inside each marker
    # line, and the log file's own mtime.
    # FALSIFYING EDIT: add any age-based rule to the archive pass — e.g. archive a
    # snapshot whose records all appear in $SURFACED_FILE with a timestamp older
    # than 30/60/90 days, or whose $SURFACED_FILE mtime is older than that.
    #
    # ⛔ THE FIXTURE IS BUILT HERE, NOT INHERITED FROM RUN 2. ⛔ It used to
    # back-date whatever run 2 had left behind, which made this leg depend on run
    # 2 leaving markers in place. Run 2 now RESETS the reprint pointer when it
    # prints nothing while undecided records remain (a deliberate anti-hiding
    # rule), so the inherited fixture would have been an EMPTY file: the sed
    # matched nothing, no aged marker existed, and this leg would have quietly
    # exercised a plain fresh surface instead of the age-gate it names — passing
    # for the wrong reason. Writing the aged markers directly makes the leg stand
    # alone, and the precondition below proves the fixture is real.
    printf '[%s] 2000-01-01T00:00:00Z | %s\n' "$a26_f1" "$a26_body1" \
      > "$a26_state/surfaced-deviations.log"
    printf '[%s] 2000-01-01T00:00:00Z | %s\n' "$a26_f2" "$a26_body2" \
      >> "$a26_state/surfaced-deviations.log"
    touch -t 200001010000 "$a26_state/surfaced-deviations.log" 2>/dev/null
    A26_AGED=$(grep -cE '^\[[0-9a-f]{64}\] 2000-01-01' "$a26_state/surfaced-deviations.log" 2>/dev/null || true)
    [[ "$A26_AGED" -eq 2 ]] \
      || A26_FAILURES+=("run 2b precondition: wrote $A26_AGED aged surfaced markers, expected 2 — without a real aged fixture this leg tests a fresh surface, not the age gate it claims to test")
    A26_OUT2B=$(consumer_run "$a26_home" attended)
    A26_ARCH2B=$(a26_archived); A26_QUEUE2B=$(a26_queued)
    [[ "$A26_ARCH2B" -eq 0 ]] || A26_FAILURES+=("run 2b ARCHIVED $A26_ARCH2B snapshot(s) after the surfaced markers were backdated ~26 years with dismissed-deviations.log still empty — age has become a substitute for a decision: $A26_OUT2B")
    [[ "$A26_QUEUE2B" -eq 1 ]] || A26_FAILURES+=("run 2b left $A26_QUEUE2B queued snapshot(s), expected 1 — an old undecided record is still an undecided record")
    [[ -s "$a26_state/dismissed-deviations.log" ]] \
      && A26_FAILURES+=("run 2b wrote to dismissed-deviations.log — the passage of time must never record a decision on the user's behalf")

    # --- run 3: both records DECIDED, then and only then archived ---
    # The dismissals go through the REAL canonical write (`consume-deviations.sh
    # dismiss`), not a hand-built log line. That matters twice over: the writer's
    # format is now exercised by the test rather than imitated by it, and the
    # script refuses a hash that does not match its body, so a fixture that
    # drifted from the record could not silently produce a line the archive pass
    # happens to match anyway.
    consumer_dismiss "$a26_home" deviation "$a26_body1" >/dev/null
    consumer_dismiss "$a26_home" deviation "$a26_body2" >/dev/null
    A26_OUT3=$(consumer_run "$a26_home" attended)
    A26_ARCH3=$(a26_archived); A26_QUEUE3=$(a26_queued)
    [[ "$A26_ARCH3" -eq 1 ]] || A26_FAILURES+=("run 3 archived $A26_ARCH3 snapshot(s) after BOTH records were dismissed, expected 1 — a fully-decided snapshot must retire, or the queue never drains and the report cries wolf forever: $A26_OUT3")
    [[ "$A26_QUEUE3" -eq 0 ]] || A26_FAILURES+=("run 3 left $A26_QUEUE3 snapshot(s) queued after every record was dismissed")
    # Archived, not deleted: the evidence must still exist under its own name.
    [[ -f "$a26_state/consumed-deviations/pending-deviations-777.log" ]] \
      || A26_FAILURES+=("run 3 did not leave consumed-deviations/pending-deviations-777.log — a retired snapshot must be MOVED, not destroyed")
  fi

  if [[ ${#A26_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: surfaced 2 records without archiving, re-ran without archiving, still archived nothing with the surfaced markers backdated to 2000 — age is not a decision — and archived only after both hashes were dismissed)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A26_FAILURES[@]}")"
  fi
  rm -rf "$a26_home"
fi

# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# TC-STL-27: DISMISSING ONE DEVIATION MUST NOT RETIRE A RECORD ITS BODY QUOTES
#            — the dismissed-log WRITE is sanitized (executed, two legs)
#
# WHY this test exists: three review rounds hardened the READER of
# dismissed-deviations.log — anchored lookups, fail-closed skips, a decided-not-
# seen archive gate — and the residue then turned out to be one hop UPSTREAM. The
# reader was bash inside a fenced block, so reviewers could lint it, mutate it and
# execute it, and did. The WRITER was three paragraphs of ENGLISH telling an agent
# what to append, so the single highest-privilege write in the loop — the only one
# whose contents AUTHORIZE destroying queue state — had no code, no test and no
# sanitization. The spec said only "first 80 chars of deviation body". Issue #140
# moved that writer into `consume-deviations.sh dismiss`, which is why leg B below
# now EXECUTES it instead of imitating what the spec says.
#
# THE SCENARIO NEEDS NO ATTACKER AND NOTHING CRAFTED. An engineer files a
# deviation ABOUT the deviation loop whose body pastes the surfaced-log line it
# concerns — a completely ordinary thing for such a write-up to do — and then does
# ONE ordinary `ignore` on that write-up. Both readings of "first 80 chars" put
# the QUOTED record's marker at column 1: line-oriented `cut -c1-80` emits a
# three-line entry whose second line is the full victim marker, and byte-oriented
# `head -c 80` emits `[<hash>] 20`, where eleven characters already suffice
# because the archive pass only needs `^\[hash\] ` to match. Either way the quoted
# record counts as DECIDED, its snapshot is archived un-triaged, and
# scripts/selfimprovement-backlog.sh reports "no self-improvement backlog".
#
# WHY TWO LEGS. Leg A builds the dismissed line as a RAW 80-char slice and
# requires the victim to be archived. That looks like asserting a bug, and it is
# deliberate: it is the VACUITY GUARD. Without it, "the victim survived" could be
# true because the reader gained some unrelated second defence, or because the
# fixture stopped reproducing the scenario at all, and this test would pass while
# testing nothing. Leg B is the real assertion.
#
# WHY LEG B CALLS THE PRODUCTION WRITER. It used to READ commands/review-pr.md,
# ask whether the spec still stated the sanitizing pipeline, and then imitate
# whichever answer it got — because the writer was prose and there was nothing to
# call. That was the best available approximation and it had the weakness every
# assertion-over-English has: it proved the paragraph still said the right words,
# not that anything did the right thing. Leg B now pipes the body into
# `consume-deviations.sh dismiss deviation <digest>` and asserts on what actually
# landed in the log, so a production edit to the pipeline flips this RED with no
# spec-reading step in between.
#
# FALSIFYING EDITS (each flips this test RED):
#   - delete any stage of the `tr '\n' ' ' | tr -d '[]' | cut -c1-80` pipeline
#     from `sanitize_excerpt` in scripts/consume-deviations.sh (leg B archives
#     the victim);
#   - delete `tr '\n' ' '` from `sanitize_excerpt` (leg B archives the victim:
#     the write-up becomes three log lines and the second one IS the victim's
#     marker, at column 1).
#
# ⛔ WHAT THIS TEST DOES *NOT* CATCH, MEASURED RATHER THAN ASSUMED. ⛔ Two edits
# leave it green, and both are caught elsewhere — say so here rather than let a
# reader infer coverage this test does not have:
#   - deleting `tr -d '[]'` alone. The newline fold then keeps the whole write-up
#     on ONE line, so the quoted marker can never reach column 1 and the anchor
#     still holds. That is the layered defence working as designed; TC-STL-45
#     leg (1) catches the missing strip directly, by asserting no `[` survives
#     into the excerpt.
#   - un-anchoring the lookup to `grep -qF "$HASH"`. This fixture puts 67
#     characters of preamble before the quoted marker, so `cut -c1-80` keeps only
#     ~13 characters of the 64-character digest and even a bare substring search
#     cannot match. TC-STL-46 leg (2c) carries a fixture built to survive the
#     truncation, and pins the anchor behaviourally for BOTH halves — they share
#     one `hash_logged_in` now.
#
# A THIRD bullet used to sit here — "add `surfaced-deviations.log` back into the
# archive-completeness test" — under a heading that says TWO. It was not merely a
# miscount: the edit does NOT leave this test green. Measured by making it (a
# `hash_logged_in … "$SURFACED_FILE"` alternative in `dev_archive_pass`): TC-STL-26,
# 27, 29, 30 and 32 all went RED. A "not covered" list that names a case the suite
# DOES cover is the same overclaim as one that names a case it does not (TL-0019)
# — it just fails in the direction that costs a reviewer their time instead of
# their coverage. Verify every entry on a list like this by making the edit.
# ---------------------------------------------------------------------------
TC="TC-STL-27: dismissing a deviation must not retire a record its body quotes (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the consumer parses JSONL with jq, so this behavioural test cannot run (brew install jq / apt install jq)"
else
  A27_FAILURES=()

  # The victim: an innocent record in its own snapshot. Nobody ever decides it.
  a27_victim="VICTIM deviation that must NOT be archived"
  # FULL digest, because that is what the logs key on. The 8-char form is kept
  # separately only for matching what the surface message PRINTS.
  a27_vh=$(printf '%s' "$a27_victim" | shasum -a 256 | awk '{print $1}')
  a27_vh_short=${a27_vh:0:8}
  # The write-up: an ordinary deviation about the loop, quoting the victim's
  # surfaced-log line verbatim. This is the whole attack surface — a paste.
  a27_marker="[$a27_vh] 2026-08-20T09:14:02Z | $a27_victim"
  a27_writeup=$(printf '%s\n%s\n%s' \
    "The consumer never re-showed this record. Its surfaced marker was:" \
    "$a27_marker" \
    "Filed as a follow-up.")
  a27_wh=$(printf '%s' "$a27_writeup" | shasum -a 256 | awk '{print $1}')
  # Same text with real newlines re-escaped for the JSONL line. The body carries
  # no quotes or backslashes of its own, so this is the only escaping needed.
  a27_writeup_json=$(printf '%s' "$a27_writeup" | awk '{ printf "%s%s", (NR > 1 ? "\\n" : ""), $0 }')

  a27_seed() {
    local st="$1"
    mkdir -p "$st"
    printf '{"ts":"2026-08-20T09:14:02Z","phase":"Verification","body":"%s"}\n' "$a27_victim" \
      > "$st/pending-deviations-888.log"
    printf '{"ts":"2026-08-20T10:00:00Z","phase":"Implementation","body":"%s"}\n' "$a27_writeup_json" \
      > "$st/pending-deviations-777.log"
  }

  # --- leg A: RAW 80-char slice (the vacuity guard) ---
  # This leg deliberately hand-builds the OLD, unsanitized line — the one the
  # prose spec used to authorize — because its whole job is to prove the hazard
  # is still reachable. It must NOT go through the production writer: if it did,
  # it would be testing the fix rather than the scenario the fix exists for, and
  # leg B's pass would then mean nothing.
  a27_home_a=$(mktemp -d); a27_state_a="$a27_home_a/.claude"
  a27_seed "$a27_state_a"
  A27_OUT_A1=$(consumer_run "$a27_home_a" attended)
  # The surface prints the 8-char DISPLAY form, so match on that; every log
  # assertion below matches on the full digest.
  printf '%s\n' "$A27_OUT_A1" | grep -q "$a27_vh_short" \
    || A27_FAILURES+=("leg A run 1 did not surface the victim (displayed hash $a27_vh_short) — the fixture no longer reproduces the scenario, so nothing below proves anything: $A27_OUT_A1")
  # ONE ordinary `ignore` on the WRITE-UP, written the way the old spec said.
  printf '[%s] 2026-08-20T11:00:00Z | %s\n' "$a27_wh" "$(printf '%s' "$a27_writeup" | cut -c1-80)" \
    >> "$a27_state_a/dismissed-deviations.log"
  A27_LEAK_A=$(grep -cE "^\[$a27_vh\] " "$a27_state_a/dismissed-deviations.log" 2>/dev/null || true)
  consumer_run "$a27_home_a" attended >/dev/null 2>&1
  A27_VICTIM_GONE_A=false
  [[ -f "$a27_state_a/consumed-deviations/pending-deviations-888.log" ]] && A27_VICTIM_GONE_A=true
  [[ "$A27_LEAK_A" -ge 1 ]] \
    || A27_FAILURES+=("leg A (vacuity guard): a raw \`cut -c1-80\` slice of the write-up did NOT plant a column-1 victim marker (count $A27_LEAK_A). The scenario this test exists for is no longer reachable — re-derive whether leg B still tests anything before trusting it")
  [[ "$A27_VICTIM_GONE_A" == "true" ]] \
    || A27_FAILURES+=("leg A (vacuity guard): the victim snapshot survived even with an UNSANITIZED dismissal. Either the reader gained another defence or the fixture drifted — leg B's pass would then be meaningless. Investigate before relaxing this")
  rm -rf "$a27_home_a"

  # --- leg B: the write PERFORMED BY THE PRODUCTION WRITER ---
  a27_home_b=$(mktemp -d); a27_state_b="$a27_home_b/.claude"
  a27_seed "$a27_state_b"
  consumer_run "$a27_home_b" attended >/dev/null 2>&1
  # ONE ordinary `ignore` on the write-up, recorded exactly as Step 7 records it.
  A27_DISMISS_B=$(consumer_dismiss "$a27_home_b" deviation "$a27_writeup")
  printf '%s\n' "$A27_DISMISS_B" | grep -q 'dismiss recorded=' \
    || A27_FAILURES+=("leg B: the canonical dismissal write did not record the write-up (output: $A27_DISMISS_B) — with no dismissal on disk every assertion below passes vacuously")
  A27_LEAK_B=$(grep -cE "^\[$a27_vh\] " "$a27_state_b/dismissed-deviations.log" 2>/dev/null || true)
  A27_OUT_B2=$(consumer_run "$a27_home_b" attended)
  A27_ARCH_B=$(consumer_archived "$a27_state_b")
  A27_QUEUE_B=$(consumer_queued "$a27_state_b")
  [[ "$A27_LEAK_B" -eq 0 ]] \
    || A27_FAILURES+=("leg B: the dismissed log holds $A27_LEAK_B line(s) starting \`[$a27_vh] \` — the write-up's excerpt planted the VICTIM's marker at column 1, so a record nobody decided now reads as decided. The canonical dismissal write is not sanitizing its excerpt")
  [[ -f "$a27_state_b/pending-deviations-888.log" ]] \
    || A27_FAILURES+=("leg B: the victim snapshot pending-deviations-888.log was RETIRED after a single \`ignore\` on a DIFFERENT deviation that merely quoted it — an undecided record was archived un-triaged: $A27_OUT_B2")
  [[ "$A27_ARCH_B" -eq 1 ]] \
    || A27_FAILURES+=("leg B archived $A27_ARCH_B snapshot(s), expected exactly 1 — the write-up's own snapshot IS fully decided and must retire, or a real dismissal accomplishes nothing: $A27_OUT_B2")
  [[ "$A27_QUEUE_B" -eq 1 ]] \
    || A27_FAILURES+=("leg B left $A27_QUEUE_B queued snapshot(s), expected exactly 1 (the victim's)")
  rm -rf "$a27_home_b"

  if [[ ${#A27_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: leg A confirms a raw 80-char slice DOES forge the victim's marker and retire its snapshot; leg B, dismissing through the production canonical write, planted 0 forged markers, retired only the genuinely-decided snapshot and left the victim queued)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A27_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-28: A HASH THAT CANNOT BE DERIVED MUST NOT BECOME A SHARED KEY
#
# WHY: every dedupe, suppression and archive decision in the consumer is keyed on
# `HASH_FULL=$(printf '%s' "$BODY" | shasum -a 256 | awk '{print $1}')` (it was
# `cut -c1-8` until the key/display split landed), and the comment beside the
# anchored lookups asserts the hash carries no regex metacharacters. Nothing ever
# checked that. `jq` was guarded with `command -v`;
# `shasum` was not, so its absence was INFERRED from the output rather than
# reported. On failure the substitution yields the EMPTY STRING, the anchored
# pattern degrades to `^\[\] `, and every record in every snapshot collapses onto
# ONE key. Verified with `shasum` shadowed by a stub exiting 127: three snapshots
# holding three DISTINCT bodies surfaced only 1 of 3 records, printed `(hash: )`,
# and wrote `[] <ISO> | DISTINCT RECORD 953` into surfaced-deviations.log.
# Appending ONE dismissal in that same shape then archived ALL THREE snapshots —
# the same silent mass-archive this branch exists to prevent, reached by a
# missing-tool accident with nobody attacking anything.
#
# Two legs, because there are two distinct failure modes and the fixes differ:
#   leg 1 — shasum BROKEN but present: `command -v` passes, so the per-record
#           `[[ "$HASH_FULL" =~ ^[0-9a-f]{64}$ ]]` validation is the only thing
#           standing between a failed hash and a shared key.
#   leg 2 — shasum ABSENT from PATH: the `command -v shasum` guard should refuse
#           the whole run and say so, exactly as the jq guard beside it does.
#
# FALSIFYING EDITS:
#   - delete the `[[ "$HASH_FULL" =~ $_hash_re ]] || { … }` validation (the regex
#     is `^[0-9a-f]{64}$`, held in a variable for bash/zsh portability) from the
#     SURFACE pass (leg 1: records collapse onto the empty key);
#   - delete it from the ARCHIVE pass, or change its action from
#     `_complete=false; break` to `continue` (leg 1: the empty-key dismissal
#     archives every snapshot, because `continue` leaves `_complete` at `true`);
#   - delete the `elif ! command -v shasum` guard (leg 2: no message is printed
#     and the run proceeds on empty hashes).
# ---------------------------------------------------------------------------
TC="TC-STL-28: an underivable hash never becomes a shared key (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the consumer parses JSONL with jq, so this behavioural test cannot run"
else
  A28_FAILURES=()
  a28_home=$(mktemp -d); a28_state="$a28_home/.claude"; mkdir -p "$a28_state"
  a28_bin="$a28_home/bin"; mkdir -p "$a28_bin"

  # Three snapshots, three DISTINCT bodies. Distinct is the whole point: if the
  # empty key is accepted, all three collapse onto it and one dismissal retires
  # every file.
  for _i in 1 2 3; do
    printf '{"ts":"2026-08-20T0%s:00:00Z","phase":"Implementation","body":"DISTINCT RECORD %s"}\n' "$_i" "$_i" \
      > "$a28_state/pending-deviations-90$_i.log"
  done
  # --- leg 1: shasum present on PATH but broken ---
  # Exit 127 mimics the real observed failure (a shim that cannot exec its
  # target); any non-zero exit with no stdout produces the same empty HASH.
  printf '#!/bin/sh\nexit 127\n' > "$a28_bin/shasum"
  chmod +x "$a28_bin/shasum"
  A28_OUT1=$(HOME="$a28_home" PATH="$a28_bin:$PATH" bash "$CONSUMER_SCRIPT" surface baselito ai-engineering 4242 MERGED attended 2>&1)

  # --- leg 1b: THE EMPTY KEY MUST NOT REACH THE SURFACED LOG EITHER ---
  # One poisoned `[] <ISO> | …` marker suppresses every future record once
  # shasum works again, because the surfaced lookup is anchored on the same key.
  #
  # ⛔ CAPTURED HERE, IMMEDIATELY AFTER RUN 1 — AND THAT ORDERING IS THE WHOLE
  # ASSERTION. ⛔ This used to sit BELOW the second `surface` call, and run 2's
  # self-healing pointer reset (`: > "$SURFACED_FILE"`, reached because run 2
  # prints nothing while snapshots are still queued) TRUNCATES the very file the
  # grep inspects. Measured with the surface pass's own `HASH_RE` validation
  # deleted: `after RUN 1 -> markers=1`, `after RUN 2 -> markers=0 bytes=0`, and
  # the assertion ran after run 2. It named one mechanism (the key guard) and was
  # satisfied by a different one (the pointer reset), so it could not fail — the
  # fifth tautology found on this branch.
  A28_SURF_LOG="$a28_state/surfaced-deviations.log"
  if [[ ! -f "$A28_SURF_LOG" ]]; then
    A28_FAILURES+=("leg 1b vacuity guard: run 1 left no surfaced-deviations.log at all, so a grep over it can only ever return 0 — the surface pass was refused before it touched its state files, which is not the state this leg is about: $A28_OUT1")
  else
    A28_EMPTY_MARKER=$(grep -cE '^\[\] ' "$A28_SURF_LOG" 2>/dev/null || true)
    # ⛔ DETECTOR CONTROL, in the shape of TC-STL-46 leg (2a). ⛔ A count of 0
    # from a pattern that cannot match anything is indistinguishable from a
    # count of 0 from a log that is genuinely clean. The identical grep is run
    # over a hand-planted marker — the exact line a triage performed under a
    # broken shasum writes — and MUST return 1, or the assertion below is a
    # statement about the regex rather than about the run.
    a28_probe="$a28_home/empty-key-probe.log"
    printf '[] 2026-08-20T12:00:00Z | DISTINCT RECORD 1\n' > "$a28_probe"
    A28_PROBE=$(grep -cE '^\[\] ' "$a28_probe" 2>/dev/null || true)
    [[ "$A28_PROBE" -eq 1 ]] \
      || A28_FAILURES+=("leg 1b vacuity guard: the \`^\\[\\] \` detector found $A28_PROBE of 1 planted empty-key marker(s), so 'found 0 in the real log' is a fact about the pattern, not about the run")
    [[ "$A28_EMPTY_MARKER" -eq 0 ]] \
      || A28_FAILURES+=("leg 1b: run 1 wrote $A28_EMPTY_MARKER empty-key marker(s) \`[] <ISO> | …\` into surfaced-deviations.log — that single line suppresses every future record once shasum works again: $A28_OUT1")
  fi

  # Now append a dismissal in exactly the shape a triage performed under a broken
  # shasum would have produced — the empty key. Hand-built ON PURPOSE: the
  # canonical write now REFUSES a hash that is not 64 hex characters, so this
  # line can no longer be produced through it. That refusal is a second,
  # independent layer (pinned by TC-STL-45); what this leg tests is the READER's
  # own guard, which has to hold even if such a line reaches the log by any route
  # — an older toolbox version, a hand edit, a partial write.
  printf '[] 2026-08-20T12:00:00Z | DISTINCT RECORD 1\n' >> "$a28_state/dismissed-deviations.log"
  HOME="$a28_home" PATH="$a28_bin:$PATH" bash "$CONSUMER_SCRIPT" surface baselito ai-engineering 4242 MERGED attended >/dev/null 2>&1
  A28_ARCH1=$(consumer_archived "$a28_state")
  A28_QUEUE1=$(consumer_queued "$a28_state")
  [[ "$A28_ARCH1" -eq 0 ]] \
    || A28_FAILURES+=("leg 1 (broken shasum) ARCHIVED $A28_ARCH1 snapshot(s) — an underivable hash became a shared empty key, so one dismissal retired snapshots holding records nobody ever saw: $A28_OUT1")
  [[ "$A28_QUEUE1" -eq 3 ]] \
    || A28_FAILURES+=("leg 1 (broken shasum) left $A28_QUEUE1 of 3 snapshots queued — a hash that cannot be derived must fail CLOSED, preserving every file")
  # --- leg 2: shasum absent from PATH entirely ---
  # A minimal PATH holding only the tools the block actually calls, minus shasum,
  # so `command -v shasum` genuinely fails. Built by resolving each tool through
  # the real PATH first: if one cannot be found the leg reports a setup failure
  # rather than asserting against a run that died for an unrelated reason.
  # The interpreter is invoked by ABSOLUTE path with the script as its argument,
  # because bash is not one of the tools the consumer calls and must not be on
  # the stripped PATH (and running the script by path would re-resolve its
  # shebang through it).
  a28_minbin="$a28_home/minbin"; mkdir -p "$a28_minbin"
  a28_shell_path=$(command -v bash 2>/dev/null)
  a28_setup_ok=true
  [[ -x "$a28_shell_path" ]] || a28_setup_ok=false
  for _t in awk basename cat cut date grep head jq ls mkdir mv sed touch tr; do
    _p=$(command -v "$_t" 2>/dev/null) || { a28_setup_ok=false; break; }
    [[ -n "$_p" ]] || { a28_setup_ok=false; break; }
    ln -sf "$_p" "$a28_minbin/$_t"
  done
  if [[ "$a28_setup_ok" != "true" ]]; then
    A28_FAILURES+=("leg 2 setup: could not resolve bash or one of the tools the consumer calls, so a shasum-absent PATH could not be built without also removing something else")
  else
    rm -f "$a28_state/dismissed-deviations.log" "$a28_state/surfaced-deviations.log"
    A28_OUT2=$(HOME="$a28_home" PATH="$a28_minbin" "$a28_shell_path" "$CONSUMER_SCRIPT" surface baselito ai-engineering 4242 MERGED attended 2>&1)
    A28_ARCH2=$(consumer_archived "$a28_state")
    A28_QUEUE2=$(consumer_queued "$a28_state")
    printf '%s\n' "$A28_OUT2" | grep -qi 'shasum' \
      || A28_FAILURES+=("leg 2 (shasum absent) printed nothing naming shasum — the tool's absence is being INFERRED from a run that quietly produces empty hashes instead of reported, which is exactly the gap the jq guard beside it already closes: $A28_OUT2")
    # ⛔ "NAMES SHASUM" IS NOT ENOUGH ON ITS OWN. ⛔ Verified: with the
    # `command -v shasum` guard replaced by `elif false`, the run proceeds, the
    # shell's own `shasum: command not found` lands on stderr, and a bare
    # `grep -qi shasum` PASSED on that. The discriminator that actually binds the
    # guard is behavioural: a guarded run REFUSES the whole surface, so it never
    # prints the surface header at all. An unguarded run prints it and then
    # reports parse failures.
    printf '%s\n' "$A28_OUT2" | grep -q 'Surfacing captured deviations' \
      && A28_FAILURES+=("leg 2 (shasum absent) printed the surface header — the run was ATTEMPTED with no way to derive a hash rather than refused up front. Any 'shasum' text in the output is then the shell's own command-not-found noise, not the guard reporting: $A28_OUT2")
    [[ "$A28_ARCH2" -eq 0 ]] \
      || A28_FAILURES+=("leg 2 (shasum absent) ARCHIVED $A28_ARCH2 snapshot(s) — a run that cannot hash anything must retire nothing")
    [[ "$A28_QUEUE2" -eq 3 ]] \
      || A28_FAILURES+=("leg 2 (shasum absent) left $A28_QUEUE2 of 3 snapshots queued — the guard must PRESERVE, exactly as the jq guard does")
  fi

  # --- leg 3: shasum breaks BETWEEN the two passes ---
  # ⛔ THIS LEG EXISTS BECAUSE LEG 1 CANNOT REACH THE ARCHIVE PASS. ⛔ Verified:
  # deleting the archive pass's own hash validation, and changing its action from
  # `_complete=false; break` to `continue`, BOTH left legs 1 and 2 green. When
  # shasum is broken for the whole run, the surface pass diverts every snapshot
  # into PARSE_FAIL_FILES and the archive pass skips those files outright, so its
  # guard is never executed. The only way to exercise it is the real race the
  # guard is for: hashing works while the surface pass runs and fails afterwards
  # (a shim that starts failing, a PATH change, resource pressure, a partial
  # write). The `continue` spelling is the dangerous one — it skips the record
  # WITHOUT counting it in either tally, so `_outstanding` stays 0 and a file whose
  # other records were all decided reads as "nothing outstanding" and the `mv` is
  # authorized. (Before the counters existed the same `continue` was worse still:
  # it left `_complete` at an initial `true`, which authorized the `mv` even with
  # no decided records at all. That default is gone — see (9c) — but `continue`
  # here remains wrong for the reason above.)
  #
  # The stub switches on a SIGNAL rather than a call count: the surfaced-marker
  # write is the only thing that happens between the two passes, so "the surfaced
  # log is non-empty" IS the pass boundary. That survives any change to how many
  # times per record the block hashes.
  a28_home3=$(mktemp -d); a28_state3="$a28_home3/.claude"; mkdir -p "$a28_state3"
  a28_bin3="$a28_home3/bin"; mkdir -p "$a28_bin3"
  a28_real_shasum=$(command -v shasum 2>/dev/null)
  if [[ ! -x "$a28_real_shasum" ]]; then
    A28_FAILURES+=("leg 3 setup: no real shasum on PATH to delegate to")
  else
    for _i in 1 2 3; do
      printf '{"ts":"2026-08-20T0%s:00:00Z","phase":"Implementation","body":"LEG3 RECORD %s"}\n' "$_i" "$_i" \
        > "$a28_state3/pending-deviations-91$_i.log"
    done
    # An empty-key dismissal, the shape a triage performed under a broken shasum
    # would itself have written. Without the archive-pass guard this one line
    # matches `^\[\] ` for every record and retires all three snapshots.
    printf '[] 2026-08-20T12:00:00Z | LEG3 RECORD 1\n' > "$a28_state3/dismissed-deviations.log"
    {
      printf '#!/bin/sh\n'
      printf '# Succeed until the surfaced log has been written, then fail.\n'
      printf 'if [ -s "%s/surfaced-deviations.log" ]; then exit 127; fi\n' "$a28_state3"
      printf 'exec %s "$@"\n' "$a28_real_shasum"
    } > "$a28_bin3/shasum"
    chmod +x "$a28_bin3/shasum"
    A28_OUT3=$(HOME="$a28_home3" PATH="$a28_bin3:$PATH" bash "$CONSUMER_SCRIPT" surface baselito ai-engineering 4242 MERGED attended 2>&1)
    A28_ARCH3=$(consumer_archived "$a28_state3")
    A28_QUEUE3=$(consumer_queued "$a28_state3")
    # Precondition: the surface pass must have completed with REAL hashes, or the
    # archive pass was never reached and this leg proves nothing.
    # 64 hex, not 8: the marker's key column is the FULL digest now, and the
    # whole point of this precondition is that the surface pass ran with REAL
    # hashes. An `{8}` pattern would not match a 64-char key at all, so the
    # precondition would fail (loudly, which is the right direction) rather than
    # match a truncated one.
    A28_SURF3=$(grep -cE '^\[[0-9a-f]{64}\] ' "$a28_state3/surfaced-deviations.log" 2>/dev/null || true)
    [[ "$A28_SURF3" -eq 3 ]] \
      || A28_FAILURES+=("leg 3 precondition: expected 3 real-hash markers in surfaced-deviations.log after the surface pass, found $A28_SURF3 — the stub's switch point no longer straddles the two passes, so the archive-pass guard was not exercised: $A28_OUT3")
    [[ "$A28_ARCH3" -eq 0 ]] \
      || A28_FAILURES+=("leg 3 ARCHIVED $A28_ARCH3 snapshot(s) — hashing failed between the surface and archive passes and the archive pass accepted the empty key, so a single \`[] …\` dismissal retired snapshots holding three DISTINCT undecided records: $A28_OUT3")
    [[ "$A28_QUEUE3" -eq 3 ]] \
      || A28_FAILURES+=("leg 3 left $A28_QUEUE3 of 3 snapshots queued — a record whose hash cannot be derived must fail CLOSED in the archive pass too (count it as OUTSTANDING and \`break\`, never \`continue\`)")
  fi
  rm -rf "$a28_home3"

  if [[ ${#A28_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: a broken shasum surfaced no forged key, wrote no \`[]\` marker and archived nothing even with an empty-key dismissal present; an absent shasum was refused up front and preserved all 3 snapshots; a shasum that broke BETWEEN the passes archived nothing despite an empty-key dismissal)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A28_FAILURES[@]}")"
  fi
  rm -rf "$a28_home"
fi


# ---------------------------------------------------------------------------
# TC-STL-29: THE REPRINT POINTER MUST NOT BECOME A THIRD WAY TO HIDE A RECORD
#            (executed, five runs)
#
# WHY: closing the ARCHIVE side of the silent-drain defect (TC-STL-26) left the
# SURFACE side open, and it is the same defect wearing a different hat. Every run
# recorded the hashes it printed into surfaced-deviations.log, future runs skipped
# them, and nothing ever cleared them. So an unattended `--auto` cron fire would
# print 15 records into a session with no reader, mark all 15 shown, and they
# would never appear again — while all six snapshots stayed pending and the
# triage text promised "they surface on the next merged-PR consumption". Run it
# enough times and every record is marked shown, every run reports nothing to
# triage, and the queue is invisible to its own consumer. Nothing is deleted and
# nothing is archived; the records are simply unreachable.
#
# The consumer now carries two rules, and this test is the only thing that binds
# them, because both are invisible to a static scan:
#   1. WRITTEN AND RESET BY ATTENDED RUNS ONLY — a cron fire may read the pointer
#      but never write or clear it, since it has no reader by definition.
#   2. SELF-HEALING RESET — when an ATTENDED run prints nothing new while
#      snapshots holding undecided records are still queued, the pointer has
#      stopped being a resume marker, so it is truncated and the queue
#      re-surfaces next run.
#
# The eight runs:
#   A (auto)     — both records surface; NO marker file content is written.
#   B (auto)     — both surface AGAIN. This is rule 1's whole point: an unread
#                  run cannot consume the queue's visibility.
#   C (attended) — both surface; two full-digest markers are now recorded.
#   D (auto)     — prints nothing new (the attended markers suppress it) and MUST
#                  LEAVE THEM ALONE. A cron fire that reset the pointer would
#                  destroy a human's place in a capped session between fires.
#   E (attended) — prints nothing new, and NOW resets: the pointer is truncated
#                  and the run says so.
#   F (attended) — both records surface again, proving E's reset was real.
#   G (attended) — a SECOND snapshot is now `chmod 000`. Nothing new prints and
#                  the run reports the unreadable file, so it takes the middle
#                  `elif` of the chain rather than the final `else` — and the
#                  reset must STILL fire. This is the state the reset could not
#                  reach while it lived inside that `else`.
#   H (attended) — the readable records surface again, proving G's reset was real.
# Throughout: nothing is archived and dismissed-deviations.log stays empty. A
# reset must never be mistaken for a decision — and an unreadable snapshot is
# never "fully decided", so it is never archived either.
#
# FALSIFYING EDITS (each verified to flip this test RED):
#   - delete the `[[ "$attended" == "true" ... ]]` guard around the
#     `>> "$SURFACED_FILE"` write in scripts/consume-deviations.sh: run A records
#     markers, so run B prints nothing and rule 1 is gone;
#   - delete the `: > "$SURFACED_FILE"` reset block: run E leaves the markers, so
#     run F prints nothing and the queue is hidden permanently;
#   - drop `"$attended" == "true"` from the RESET condition: run D resets, so run
#     E prints both records instead of reporting nothing new.
#   - move the reset back INSIDE the final `else` of the three-way chain: runs
#     A-F still pass, and run G fails on both the marker count and the missing
#     reset message. VERIFIED — this is the round-5 F2 regression.
#   - drop `"$SURFACED_ANY" != "true"` from the RESET condition, now that the
#     reset sits below the chain: every run that DID print would also clear its
#     own pointer, so run C ends with 0 markers instead of 2 and run D re-prints
#     what a human is mid-way through reading.
# The `$STILL_QUEUED -gt 0` half of the reset condition is deliberately NOT
# claimed as falsifiable here: with nothing queued there is nothing to re-surface,
# so the reset is a no-op either way. It is a belt, not a mechanism.
# ---------------------------------------------------------------------------
TC="TC-STL-29: an unread run never hides a record, and a stale pointer resets itself (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the consumer parses JSONL with jq, so this behavioural test cannot run"
else
  A29_FAILURES=()
  a29_home=$(mktemp -d); a29_state="$a29_home/.claude"; mkdir -p "$a29_state"
  a29_b1="UNREAD RECORD ONE"; a29_b2="UNREAD RECORD TWO"
  a29_s1=$(printf '%s' "$a29_b1" | shasum -a 256 | awk '{print $1}'); a29_s1=${a29_s1:0:8}
  a29_s2=$(printf '%s' "$a29_b2" | shasum -a 256 | awk '{print $1}'); a29_s2=${a29_s2:0:8}
  printf '{"ts":"2026-01-01T00:00:00Z","phase":"Implementation","body":"%s"}\n' "$a29_b1" \
    > "$a29_state/pending-deviations-555.log"
  printf '{"ts":"2026-01-01T00:00:01Z","phase":"Verification","body":"%s"}\n' "$a29_b2" \
    >> "$a29_state/pending-deviations-555.log"

  # The same state dir, run in the two MODES. `unattended` is what an `--auto`
  # cron fire passes; `attended` is what a human-typed /review-pr passes.
  a29_markers() { grep -cE '^\[[0-9a-f]{64}\] ' "$a29_state/surfaced-deviations.log" 2>/dev/null || true; }

  # Run C below is the vacuity guard for the whole test: if the consumer never
  # recorded a marker at all, "an unread run recorded nothing" would be trivially
  # true. C requires 2, so a consumer that writes no pointer fails there.
  if true; then
    # --- run A: unattended ---
    A29_OUT_A=$(consumer_run "$a29_home" unattended)
    printf '%s\n' "$A29_OUT_A" | grep -q "$a29_s1" \
      || A29_FAILURES+=("run A (auto) did not surface record 1 — the fixture never reached the surface, so nothing below proves anything: $A29_OUT_A")
    A29_MARK_A=$(a29_markers)
    [[ "$A29_MARK_A" -eq 0 ]] \
      || A29_FAILURES+=("run A (auto) recorded $A29_MARK_A surfaced marker(s) — an unattended cron fire has no reader, so marking its output 'shown' hides those records from every future run: $A29_OUT_A")

    # --- run B: unattended again — the records must come back ---
    A29_OUT_B=$(consumer_run "$a29_home" unattended)
    printf '%s\n' "$A29_OUT_B" | grep -q "$a29_s1" \
      || A29_FAILURES+=("run B (auto) did not re-surface record 1 — an unread run consumed the queue's visibility, which is the permanent-hiding defect this test exists for: $A29_OUT_B")
    printf '%s\n' "$A29_OUT_B" | grep -q "$a29_s2" \
      || A29_FAILURES+=("run B (auto) did not re-surface record 2: $A29_OUT_B")

    # --- run C: attended — NOW the pointer is written ---
    A29_OUT_C=$(consumer_run "$a29_home" attended)
    A29_MARK_C=$(a29_markers)
    [[ "$A29_MARK_C" -eq 2 ]] \
      || A29_FAILURES+=("run C (attended) recorded $A29_MARK_C full-digest marker(s), expected 2 — without the pointer a capped attended session re-prints its first batch forever, so rule 1 must not have thrown the resume marker away entirely: $A29_OUT_C")

    # --- run D: unattended — must NOT clear an attended pointer ---
    A29_OUT_D=$(consumer_run "$a29_home" unattended)
    A29_MARK_D=$(a29_markers)
    printf '%s\n' "$A29_OUT_D" | grep -q 'nothing new to triage' \
      || A29_FAILURES+=("run D (auto) did not report 'nothing new to triage' — expected the already-surfaced path after run C recorded both records: $A29_OUT_D")
    [[ "$A29_MARK_D" -eq 2 ]] \
      || A29_FAILURES+=("run D (auto) left $A29_MARK_D marker(s), expected 2 — a cron fire cleared the pointer a human is mid-way through, losing their place in a capped session: $A29_OUT_D")

    # --- run E: attended, nothing new, undecided records queued -> RESET ---
    A29_OUT_E=$(consumer_run "$a29_home" attended)
    A29_MARK_E=$(a29_markers)
    printf '%s\n' "$A29_OUT_E" | grep -q 'nothing new to triage' \
      || A29_FAILURES+=("run E (attended) did not report 'nothing new to triage' first — the reset is supposed to happen ON that path: $A29_OUT_E")
    [[ "$A29_MARK_E" -eq 0 ]] \
      || A29_FAILURES+=("run E (attended) left $A29_MARK_E marker(s) after printing nothing while 1 snapshot still held undecided records — the pointer has stopped being a resume marker and is now permanently suppressing a live queue: $A29_OUT_E")
    printf '%s\n' "$A29_OUT_E" | grep -q 'reprint pointer has been reset' \
      || A29_FAILURES+=("run E (attended) reset the pointer without saying so — a silent state change on the path that prints 'nothing new' is indistinguishable from the bug: $A29_OUT_E")

    # --- run F: attended — the records are visible again ---
    A29_OUT_F=$(consumer_run "$a29_home" attended)
    printf '%s\n' "$A29_OUT_F" | grep -q "$a29_s1" \
      || A29_FAILURES+=("run F did not re-surface record 1 after run E's reset — the reset was reported but did nothing: $A29_OUT_F")

    # --- run G: attended, nothing new, and ONE SNAPSHOT IS UNREADABLE -> RESET ---
    # THE STATE THE RESET COULD NOT REACH. For one round the reset lived in the
    # final `else` of a three-way chain whose middle branch is
    # `elif [[ $PARSE_FAILURES -gt 0 || $UNREADABLE -gt 0 ]]`. A `chmod 000`
    # snapshot — the same permissions accident the fail-closed guard already
    # treats as first-class — plus all readable records already surfaced sends the
    # run down that elif, so it printed nothing AND never reset: the queue stayed
    # buried permanently, which is the exact state the reset exists to break. Run
    # F re-surfaced both records, so their markers are on disk again; adding an
    # unreadable second snapshot now reproduces it precisely.
    printf '{"ts":"2026-01-01T00:00:02Z","phase":"Verification","body":"UNREADABLE SNAPSHOT RECORD"}\n' \
      > "$a29_state/pending-deviations-556.log"
    chmod 000 "$a29_state/pending-deviations-556.log"
    A29_OUT_G=$(consumer_run "$a29_home" attended)
    A29_MARK_G=$(a29_markers)
    # Two independent confirmations that the fixture really landed in the middle
    # branch, because both assertions below are worthless otherwise: the surface
    # loop's per-file skip line, and the `elif` branch's own summary. Grepping the
    # `SURFACED_ANY` branch's "could not be read" wording would be wrong here —
    # that line only prints when something DID surface, which is precisely not
    # this state.
    printf '%s\n' "$A29_OUT_G" | grep -q 'not readable' \
      || A29_FAILURES+=("run G (attended) never reported skipping the unreadable snapshot — the fixture did not reach the unreadable path, so the reset assertions below would prove nothing: $A29_OUT_G")
    printf '%s\n' "$A29_OUT_G" | grep -q 'no parseable deviations surfaced' \
      || A29_FAILURES+=("run G (attended) did not take the middle 'no parseable deviations surfaced' branch — this run is supposed to reproduce the branch the reset used to be unreachable from: $A29_OUT_G")
    [[ "$A29_MARK_G" -eq 0 ]] \
      || A29_FAILURES+=("run G (attended) left $A29_MARK_G marker(s) after printing nothing while 2 snapshot(s) held undecided records — the reset is bound to one branch's wording instead of to the fact that a silent attended run still has work queued, so an unreadable snapshot buries the queue forever: $A29_OUT_G")
    printf '%s\n' "$A29_OUT_G" | grep -q 'reprint pointer has been reset' \
      || A29_FAILURES+=("run G (attended) reset nothing on the unreadable path — the self-healing reset is unreachable from the branch a chmod 000 accident takes: $A29_OUT_G")

    # --- run H: attended — the readable records are visible again ---
    A29_OUT_H=$(consumer_run "$a29_home" attended)
    printf '%s\n' "$A29_OUT_H" | grep -q "$a29_s1" \
      || A29_FAILURES+=("run H did not re-surface record 1 after run G's reset — the reset was reported but did nothing: $A29_OUT_H")
    # Restore the mode so the harness can clean the fixture up.
    chmod 644 "$a29_state/pending-deviations-556.log"

    # --- and none of the eight runs may decide or archive anything ---
    A29_ARCH=$(consumer_archived "$a29_state")
    A29_QUEUE=$(consumer_queued "$a29_state")
    [[ "$A29_ARCH" -eq 0 ]] \
      || A29_FAILURES+=("$A29_ARCH snapshot(s) were archived across eight runs with dismissed-deviations.log empty — printing and resetting are not decisions, and an UNREADABLE snapshot is never 'fully decided'")
    [[ "$A29_QUEUE" -eq 2 ]] \
      || A29_FAILURES+=("$A29_QUEUE snapshot(s) queued, expected 2 — both the readable and the unreadable file must stay on disk the whole time")
    [[ -s "$a29_state/dismissed-deviations.log" ]] \
      && A29_FAILURES+=("dismissed-deviations.log is non-empty — a reset or a surface recorded a decision on the user's behalf")
  fi

  if [[ ${#A29_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: two unattended runs surfaced the same records and recorded nothing; an attended run recorded both; an unattended run left that pointer intact; the next attended run reset it and said so; the records came back; then a chmod 000 second snapshot sent an attended run down the 'no parseable deviations surfaced' branch and it STILL reset, and the records came back again — nothing archived, nothing dismissed across eight runs)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A29_FAILURES[@]}")"
  fi
  rm -rf "$a29_home"
fi

# ---------------------------------------------------------------------------
# TC-STL-30: A RECORD THE LOOP CANNOT SHOW MUST BLOCK ARCHIVAL, NOT BE DROPPED
#            (executed, two legs)
#
# WHY: both loops over a snapshot's records had a way to skip a record while
# leaving the file looking complete, and "looks complete" is what authorizes the
# `mv`. Two distinct instances, and neither is exotic:
#
#   leg 1 — EOF RESIDUE. `while IFS= read -r RECORD_JSON` returns non-zero at EOF
#           without a delimiter, so a final JSON object with NO TRAILING NEWLINE
#           was assigned to the variable and then dropped: the loop body never ran
#           for it. In the surface pass that record never appeared and was never
#           counted. In the ARCHIVE pass it never appeared either — so a snapshot
#           whose last record was undecided read as "nothing outstanding" and was
#           retired with a live record inside it. A truncated write, a `printf`
#           without `\n`, or an editor stripping the final newline is enough. The
#           writer's awk happens to emit one today, which is exactly the sort of
#           accident that must not be load-bearing.
#
#   leg 2 — EMPTY BODY. `[[ -z "$BODY" ]] && continue` in the surface pass dropped
#           a record `jq` had parsed fine, silently and uncounted; the identical
#           line in the archive pass left `_complete` at its initial `true`, so a
#           `"body":""` record authorized the `mv` with no dismissal at all.
#
# HONEST LIMITS OF LEG 2: it binds the SURFACE pass. Once the surface pass counts
# an empty body as a parse failure, the file lands in PARSE_FAIL_FILES and the
# archive pass skips it outright — so from THIS entry point the archive pass's own
# empty-body guard is unreachable, exactly as TC-STL-28 leg 3 documents for the
# hash guard. Reverting BOTH lines together is caught here (nothing is reported
# and the file is archived); reverting only the archive-pass line is NOT caught
# here — it is pinned behaviourally by TC-STL-48 leg (3), which drives the
# `archive` subcommand, where the pass runs with no surface classification in
# front of it. (This used to cite "TC-STL-24 (9b)". That leg was deleted when
# TC-STL-24 was rewritten against the extracted script — its legs are (a)-(i) —
# so the citation named nothing, and the guard it claimed was covered was in
# fact unpinned: flipping that one line to `continue` left the suite at 50/50.)
#
# FALSIFYING EDITS (each verified to flip this test RED):
#   - delete `|| [[ -n "$RECORD_JSON" ]]` from the SURFACE loop: leg 1's record 2
#     never surfaces;
#   - delete it from the ARCHIVE loop: leg 1 archives the snapshot after only
#     record 1 is dismissed;
#   - revert both empty-body guards to a bare `continue`: leg 2 reports no parse
#     failure and archives the snapshot.
# ---------------------------------------------------------------------------
TC="TC-STL-30: an unshowable record blocks archival instead of vanishing (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the consumer parses JSONL with jq, so this behavioural test cannot run"
else
  A30_FAILURES=()

  # --- leg 1: a final record with NO trailing newline ---
  a30_home=$(mktemp -d); a30_state="$a30_home/.claude"; mkdir -p "$a30_state"
  a30_b1="EOF LEG record one"; a30_b2="EOF LEG record two with no trailing newline"
  a30_f2=$(printf '%s' "$a30_b2" | shasum -a 256 | awk '{print $1}')
  # Note the deliberate absence of \n on the SECOND printf — that is the fixture.
  printf '{"ts":"2026-01-01T00:00:00Z","phase":"Implementation","body":"%s"}\n' "$a30_b1" \
    > "$a30_state/pending-deviations-666.log"
  printf '{"ts":"2026-01-01T00:00:01Z","phase":"Verification","body":"%s"}' "$a30_b2" \
    >> "$a30_state/pending-deviations-666.log"
  # Precondition: prove the fixture really lacks the final newline, or leg 1 is
  # testing an ordinary two-record file and proves nothing.
  a30_lastbyte=$(tail -c 1 "$a30_state/pending-deviations-666.log" | od -An -c | tr -d ' \n')
  [[ "$a30_lastbyte" != "\\n" ]] \
    || A30_FAILURES+=("leg 1 precondition: the fixture ends with a newline after all, so the EOF-residue case is not reproduced")
  A30_OUT1=$(consumer_run "$a30_home" attended)
  printf '%s\n' "$A30_OUT1" | grep -q "${a30_f2:0:8}" \
    || A30_FAILURES+=("leg 1: the final record (no trailing newline) never surfaced — \`read\` dropped it, so a real deviation is invisible and uncounted: $A30_OUT1")
  # Dismiss ONLY record 1. The file still holds an undecided record, so it must
  # NOT be archived — which is precisely what the dropped-residue bug got wrong.
  consumer_dismiss "$a30_home" deviation "$a30_b1" >/dev/null
  consumer_run "$a30_home" attended >/dev/null 2>&1
  A30_ARCH_PARTIAL=$(consumer_archived "$a30_state")
  [[ "$A30_ARCH_PARTIAL" -eq 0 ]] \
    || A30_FAILURES+=("leg 1: the snapshot was archived with only its FIRST record dismissed — the archive pass dropped the trailing record too, so a live deviation was retired: $A30_OUT1")
  # Now dismiss the second as well: the file is genuinely complete and must retire.
  consumer_dismiss "$a30_home" deviation "$a30_b2" >/dev/null
  A30_OUT1B=$(consumer_run "$a30_home" attended)
  A30_ARCH_FULL=$(consumer_archived "$a30_state")
  [[ "$A30_ARCH_FULL" -eq 1 ]] \
    || A30_FAILURES+=("leg 1: with BOTH records dismissed the snapshot was not archived ($A30_ARCH_FULL) — the EOF guard must not make a complete file un-retirable, or the queue never drains: $A30_OUT1B")
  rm -rf "$a30_home"

  # --- leg 2: an EMPTY body ---
  a30_home2=$(mktemp -d); a30_state2="$a30_home2/.claude"; mkdir -p "$a30_state2"
  printf '{"ts":"2026-01-01T00:00:00Z","phase":"Implementation","body":""}\n' \
    > "$a30_state2/pending-deviations-667.log"
  A30_OUT2=$(consumer_run "$a30_home2" attended)
  A30_ARCH2=$(consumer_archived "$a30_state2")
  A30_QUEUE2=$(consumer_queued "$a30_state2")
  [[ "$A30_ARCH2" -eq 0 ]] \
    || A30_FAILURES+=("leg 2: a snapshot holding only an EMPTY-body record was archived with dismissed-deviations.log empty — an unshowable record authorized the mv: $A30_OUT2")
  [[ "$A30_QUEUE2" -eq 1 ]] \
    || A30_FAILURES+=("leg 2: the snapshot left the queue ($A30_QUEUE2 remaining, expected 1)")
  printf '%s\n' "$A30_OUT2" | grep -q 'failed to parse' \
    || A30_FAILURES+=("leg 2: nothing in the output says a record failed to parse — an empty body was skipped silently, so the user is told the queue holds nothing actionable when it holds a record we could not show: $A30_OUT2")
  rm -rf "$a30_home2"

  if [[ ${#A30_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: a newline-less final record surfaced, blocked archival until dismissed, then retired; an empty-body record was reported as a parse failure and never authorized the mv)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A30_FAILURES[@]}")"
  fi
fi


# ---------------------------------------------------------------------------
# TC-STL-31: THE SNAPSHOT SWEEP MUST NEVER RELOCATE A FILE FROM THE WORKING TREE
#            (executed, two legs)
#
# WHY: the sweep filtered its glob matches with `-f` and `! -L`, and then REBUILT
# the array with `ALL_DEV_SNAPSHOTS=( $(ls -t "${ALL_DEV_SNAPSHOTS[@]}") )` — an
# UNQUOTED command substitution inside an array assignment, so `ls -t`'s output
# was subject to word splitting AND pathname expansion. The filter therefore
# protected nothing downstream of itself: a REGULAR FILE named
# `pending-deviations-1 victim.log` passed `-f`/`! -L` cleanly, then split into
# `<dir>/pending-deviations-1` and a bare `victim.log` — and a bare relative name
# resolves against the CWD, which for this command is the REPO ROOT. If a file of
# that name in the working tree happens to hold dismissed-looking JSONL, the
# archive pass `mv`s it out of the checkout. A snapshot sweep must never move a
# repo file, and "the writer only emits digits" was a fact about the WRITER that
# nothing in the reader enforced.
#
# TWO INDEPENDENT FIXES, and this test is built so neither can be mistaken for
# sufficient on its own:
#   - the NAME RULE (`^pending-deviations-[0-9]+\.log$`) keeps such a file out of
#     the set entirely;
#   - the LOSSLESS ORDERING READ (line-oriented `while read` plus a membership
#     test against the pre-sort set) means a permutation can only ever contain
#     members, so nothing new can enter even if the name rule is bypassed.
#
# LEG A is the fixture's vacuity guard: it reproduces the SPLIT ITSELF in
# isolation, so leg B's "nothing moved" cannot pass merely because the fixture
# stopped being dangerous. LEG B runs the real consumer.
#
# FALSIFYING EDIT: revert BOTH fixes together — delete the `_devname_re` name
# check from `dev_enumerate_snapshots` AND restore the unquoted
# `ALL_DEV_SNAPSHOTS=( $(ls -t "${ALL_DEV_SNAPSHOTS[@]}") )` rebuild. Reverting
# either ONE alone leaves this green, which is the point of having two: verified
# by hand in both directions.
# ---------------------------------------------------------------------------
TC="TC-STL-31: the sweep never relocates a file from the working tree (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the consumer parses JSONL with jq, so this behavioural test cannot run"
else
  A31_FAILURES=()
  a31_home=$(mktemp -d); a31_state="$a31_home/.claude"; mkdir -p "$a31_state"
  a31_cwd=$(mktemp -d)     # stands in for the repo root the command runs from

  # A legitimate snapshot, so the run has real work to do and the archive pass
  # actually executes its `mv`.
  a31_body="LEGITIMATE record in a properly named snapshot"
  a31_full=$(printf '%s' "$a31_body" | shasum -a 256 | awk '{print $1}')
  printf '{"ts":"2026-01-01T00:00:00Z","phase":"Implementation","body":"%s"}\n' "$a31_body" \
    > "$a31_state/pending-deviations-701.log"
  printf '[%s] 2026-01-01T00:00:00Z | %s\n' "$a31_full" "$a31_body" \
    > "$a31_state/dismissed-deviations.log"

  # The decoy: a REGULAR FILE whose name contains a space, matching the glob.
  a31_decoy="$a31_state/pending-deviations-1 victim.log"
  printf '{"ts":"2026-01-01T00:00:00Z","phase":"X","body":"decoy"}\n' > "$a31_decoy"
  # The bystander: a file of the SPLIT-OFF name sitting in the working tree, with
  # content that would read as fully decided if it were ever treated as a
  # snapshot. This is the file that must not move.
  printf '{"ts":"2026-01-01T00:00:00Z","phase":"X","body":"%s"}\n' "$a31_body" \
    > "$a31_cwd/victim.log"

  # --- leg A: prove the split is real (vacuity guard) ---
  # Run ONLY the dangerous idiom, in isolation, over the decoy path.
  A31_SPLIT=$(cd "$a31_cwd" && bash -c '
    arr=( "$1" )
    rebuilt=( $(ls -t "${arr[@]}") )
    for e in "${rebuilt[@]}"; do printf "%s\n" "$e"; done' _ "$a31_decoy" 2>/dev/null \
    | grep -cx 'victim.log' || true)
  [[ "$A31_SPLIT" -ge 1 ]] \
    || A31_FAILURES+=("leg A (vacuity guard): the unquoted \`ls -t\` rebuild did NOT split '$a31_decoy' into a bare 'victim.log' on this shell, so leg B cannot prove anything — re-derive whether the hazard still exists before trusting leg B")

  # --- leg B: the real consumer, run from the working tree ---
  A31_OUT=$( cd "$a31_cwd" && consumer_run "$a31_home" attended )

  [[ -f "$a31_cwd/victim.log" ]] \
    || A31_FAILURES+=("leg B: victim.log was MOVED OUT of the working tree by a snapshot sweep — a bare split-off name resolved against the CWD and the archive pass relocated a repo file: $A31_OUT")
  [[ ! -e "$a31_state/consumed-deviations/victim.log" ]] \
    || A31_FAILURES+=("leg B: consumed-deviations/victim.log exists — a file that was never a snapshot was archived as one: $A31_OUT")
  [[ -f "$a31_decoy" ]] \
    || A31_FAILURES+=("leg B: the space-containing decoy left the state dir — it is not a valid snapshot name, so the sweep must ignore it, never consume it: $A31_OUT")
  # And the legitimate, fully-decided snapshot must still retire, or the fix has
  # been bought by breaking the feature.
  [[ -f "$a31_state/consumed-deviations/pending-deviations-701.log" ]] \
    || A31_FAILURES+=("leg B: the legitimate fully-decided snapshot was NOT archived — the name rule or the lossless read has excluded a valid snapshot, so the queue would never drain: $A31_OUT")

  if [[ ${#A31_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: the unquoted rebuild demonstrably splits a spaced name into a bare 'victim.log', and the real consumer left the working-tree file untouched, ignored the decoy, and still retired the legitimate snapshot)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A31_FAILURES[@]}")"
  fi
  rm -rf "$a31_home" "$a31_cwd"
fi

# ---------------------------------------------------------------------------
# TC-STL-32: A SNAPSHOT WITH NO RECORDS ARCHIVES NOTHING (executed, three legs)
#
# WHY: the archive-completeness pass decided "every record is decided" from a
# boolean that STARTED at `true`, so every path that ran the loop body zero times
# reached the `mv`. Two such paths are reachable with no attacker and nothing
# crafted:
#   - a 0-BYTE snapshot. The writer has already produced one: a stray apostrophe
#     in a comment truncated pr-postmerge-fold.sh's single-quoted awk program and
#     it emitted an empty file.
#   - a BLANK-LINES-ONLY snapshot, whose every line is swallowed by the
#     `[[ -z "$RECORD_JSON" ]] && continue` at the top of both loops.
# Neither is caught upstream: `head -1` on such a file is empty, so the surface
# pass's legacy-format guard does not classify it, and it never enters
# PARSE_FAIL_FILES — the two lists the archive pass skips.
#
# WHY IT MATTERS EVEN THOUGH NO RECORDS ARE LOST. Archiving an empty file destroys
# nothing, so the damage is one hop away: it creates a file in
# consumed-deviations/, and `dir_has_file` on that directory is COMPLETION
# EVIDENCE in scripts/selfimprovement-backlog.sh. One empty snapshot therefore
# retires the "this loop has never completed a triage" warning permanently, on a
# machine where no human has ever decided anything. That is the same
# report-success-over-untriaged-state failure the whole branch exists to remove,
# reached through the emptiest possible input.
#
# THREE LEGS, because the fix has two halves and one of them can be bought by
# breaking the feature:
#   leg 1 — 0-byte snapshot: nothing archived, file still queued.
#   leg 2 — blank-lines-only snapshot: same, via the other zero-record path.
#   leg 3 — POSITIVE CONTROL: a genuinely fully-decided snapshot must STILL
#           retire. Without this leg, `_complete=false` with no completeness gate
#           at all would pass legs 1 and 2 perfectly while permanently stranding
#           every real queue — the failure direction that is easy to miss because
#           both fail-closed legs go green.
#
# FALSIFYING EDITS:
#   - change the archive pass's initialiser back to `_complete=true`: legs 1 and 2
#     both archive their snapshot and go RED.
#   - drop the `"$_decided" -gt 0 &&` clause from the completeness gate: legs 1
#     and 2 archive on the vacuous truth that none of zero records is outstanding.
#   - delete the `[[ "$_decided" -gt 0 && "$_outstanding" -eq 0 ]] && _complete=true`
#     line entirely: leg 3 goes RED (nothing ever archives).
# TC-STL-24 (9c) pins the same two constructs statically; this pins the behaviour.
#
# WHERE THE `.phase` VALIDATION IS PINNED: TC-STL-48 leg (1), behaviourally.
# This note used to claim the check was "not reachable behaviourally in a single
# run" and was pinned statically by TC-STL-24 legs (9d)/(9b) — three errors in
# four lines. Legs (9d) and (9b) were DELETED when TC-STL-24 was rewritten
# against the extracted script, so the citation pointed at nothing; and the
# unreachability claim only held for the `surface` entry point, where a
# phase-less record is classified as a parse failure first. Driven through the
# `archive` subcommand — Step 7's cleanup route, where the pass runs with nothing
# in front of it — the guard is directly reachable, and removing it archives the
# snapshot. Measured: with the `.phase` parse deleted the suite stayed 50/50
# before TC-STL-48 existed.
# ---------------------------------------------------------------------------
TC="TC-STL-32: a snapshot with no records archives nothing (executed)"
if [[ ! -f "$CONSUMER_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/consume-deviations.sh ($CONSUMER_SCRIPT)"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the consumer parses JSONL with jq, so this behavioural test cannot run"
else
  A32_FAILURES=()

  # --- leg 1: a 0-byte snapshot ---
  a32_home1=$(mktemp -d); a32_state1="$a32_home1/.claude"; mkdir -p "$a32_state1"
  : > "$a32_state1/pending-deviations-801.log"
  A32_OUT1=$(consumer_run "$a32_home1" attended)
  A32_ARCH1=$(consumer_archived "$a32_state1"); A32_QUEUE1=$(consumer_queued "$a32_state1")
  [[ "$A32_ARCH1" -eq 0 ]] \
    || A32_FAILURES+=("leg 1: a 0-BYTE snapshot was ARCHIVED ($A32_ARCH1 file(s) in consumed-deviations/) with zero human decisions — that single file then flips \`dir_has_file\` in scripts/selfimprovement-backlog.sh and permanently silences the never-completed warning: $A32_OUT1")
  [[ "$A32_QUEUE1" -eq 1 ]] \
    || A32_FAILURES+=("leg 1: expected the 0-byte snapshot to stay queued, found $A32_QUEUE1 queued file(s): $A32_OUT1")
  [[ -s "$a32_state1/dismissed-deviations.log" ]] \
    && A32_FAILURES+=("leg 1: the run wrote to dismissed-deviations.log — surfacing must never record a decision on the user's behalf")
  rm -rf "$a32_home1"

  # --- leg 2: a blank-lines-only snapshot ---
  # Distinct from leg 1 on purpose: an `-s`-only fix (treat 0-byte files as
  # incomplete) passes leg 1 and fails here, and a 3-byte "\n\n\n" file is
  # produced by any fold that captured only empty bullets.
  a32_home2=$(mktemp -d); a32_state2="$a32_home2/.claude"; mkdir -p "$a32_state2"
  printf '\n\n\n' > "$a32_state2/pending-deviations-802.log"
  A32_OUT2=$(consumer_run "$a32_home2" attended)
  A32_ARCH2=$(consumer_archived "$a32_state2"); A32_QUEUE2=$(consumer_queued "$a32_state2")
  [[ "$A32_ARCH2" -eq 0 ]] \
    || A32_FAILURES+=("leg 2: a BLANK-LINES-ONLY snapshot was ARCHIVED ($A32_ARCH2 file(s)) with zero human decisions — an \`-s\`-only guard passes leg 1 and misses this: $A32_OUT2")
  [[ "$A32_QUEUE2" -eq 1 ]] \
    || A32_FAILURES+=("leg 2: expected the blank-lines-only snapshot to stay queued, found $A32_QUEUE2 queued file(s): $A32_OUT2")
  rm -rf "$a32_home2"

  # --- leg 3: POSITIVE CONTROL — a real, fully-decided snapshot still retires ---
  a32_home3=$(mktemp -d); a32_state3="$a32_home3/.claude"; mkdir -p "$a32_state3"
  a32_body="A REAL decided record that must still retire its snapshot"
  printf '{"ts":"2026-01-01T00:00:00Z","phase":"Implementation","body":"%s"}\n' "$a32_body" \
    > "$a32_state3/pending-deviations-803.log"
  consumer_dismiss "$a32_home3" deviation "$a32_body" >/dev/null
  A32_OUT3=$(consumer_run "$a32_home3" attended)
  A32_ARCH3=$(consumer_archived "$a32_state3"); A32_QUEUE3=$(consumer_queued "$a32_state3")
  [[ "$A32_ARCH3" -eq 1 ]] \
    || A32_FAILURES+=("leg 3 (positive control): a fully-decided snapshot was NOT archived ($A32_ARCH3 archived) — the fail-closed default has been bought by breaking archival entirely, so every real queue is stranded forever while legs 1 and 2 still pass: $A32_OUT3")
  [[ "$A32_QUEUE3" -eq 0 ]] \
    || A32_FAILURES+=("leg 3 (positive control): $A32_QUEUE3 snapshot(s) still queued after every record was dismissed: $A32_OUT3")
  rm -rf "$a32_home3"

  # --- leg 4: the record-less snapshot is NAMED, and the false claim is gone ---
  # Refusing to archive an empty snapshot makes it PERMANENTLY resident: no triage
  # can drain a file with nothing to decide. Left unclassified it was counted as
  # "still holds records nobody has decided ... they surface again on the next
  # run" — both halves false — and the backlog reporter then warned about it
  # forever while pointing the user at the one command that cannot help. That is
  # the cry-wolf half of the same class legs 1-3 fix the silent half of.
  # FALSIFYING EDITS: stop counting EMPTY_SNAPSHOTS; or drop the EMPTY_FILES
  # exclusion from the STILL_QUEUED loop (the false message returns).
  a32_home4=$(mktemp -d); a32_state4="$a32_home4/.claude"; mkdir -p "$a32_state4"
  : > "$a32_state4/pending-deviations-804.log"
  A32_OUT4=$(consumer_run "$a32_home4" attended)
  printf '%s\n' "$A32_OUT4" | grep -qF 'pending-deviations-804.log' \
    || A32_FAILURES+=("leg 4: the record-less snapshot is not NAMED in the output — a permanently-resident file nothing mentions is the original silent-skip bug: $A32_OUT4")
  printf '%s\n' "$A32_OUT4" | grep -qi 'no records' \
    || A32_FAILURES+=("leg 4: the output does not say the snapshot holds NO records — the user cannot tell it apart from work awaiting triage: $A32_OUT4")
  printf '%s\n' "$A32_OUT4" | grep -q 'still hold records nobody has decided' \
    && A32_FAILURES+=("leg 4: the run claimed the record-less snapshot 'still holds records nobody has decided' and would 'surface again' — both false, and it is the claim that made this file look like actionable work forever: $A32_OUT4")
  rm -rf "$a32_home4"

  # --- leg 5: a FULLY-SURFACED snapshot is NOT record-less ---
  # ⛔ THIS LEG EXISTS BECAUSE THE FIX FOR LEG 4 BROKE IT ONCE. ⛔ The per-file
  # tally was first incremented after the PRINT, so a snapshot whose every record
  # was already in surfaced-deviations.log counted zero records on its second run,
  # was classified record-less, and sent the whole block down the malformed-input
  # branch. TC-STL-26 and TC-STL-29 both went red, which is how it was caught —
  # but neither names this cause, so it is pinned here explicitly.
  # FALSIFYING EDIT: move the `_seen_in_file` increment from just after the hash
  # validation to after the record is printed.
  a32_home5=$(mktemp -d); a32_state5="$a32_home5/.claude"; mkdir -p "$a32_state5"
  a32_b5="A record that was already shown to a human"
  a32_f5=$(printf '%s' "$a32_b5" | shasum -a 256 | awk '{print $1}')
  printf '{"ts":"2026-01-01T00:00:00Z","phase":"Implementation","body":"%s"}\n' "$a32_b5" \
    > "$a32_state5/pending-deviations-805.log"
  printf '[%s] 2026-01-01T00:00:00Z | %s\n' "$a32_f5" "$a32_b5" \
    > "$a32_state5/surfaced-deviations.log"
  A32_OUT5=$(consumer_run "$a32_home5" attended)
  printf '%s\n' "$A32_OUT5" | grep -qi 'no records' \
    && A32_FAILURES+=("leg 5: a snapshot whose records were merely ALREADY SURFACED was classified as holding NO records — a display decision was mistaken for a fact about the file, which also diverts the run into the malformed-input branch: $A32_OUT5")
  [[ "$(consumer_archived "$a32_state5")" -eq 0 ]] \
    || A32_FAILURES+=("leg 5: an already-surfaced but UNDECIDED snapshot was archived — surfacing is not deciding: $A32_OUT5")
  rm -rf "$a32_home5"

  # --- leg 6: the MIXED shape — a decided record PLUS blank lines ---
  # ⛔ THIS IS THE SHAPE REAL SNAPSHOTS ACTUALLY HAVE, and legs 1-5 all miss it. ⛔
  # They cover 0-byte, blank-lines-only, and single-record-with-no-blanks. The
  # untested combination is a decided record with a trailing blank line — and the
  # obvious "harden the blank-line case" edit, sitting exactly where leg 2 draws a
  # reader's attention, is to make the blank-line `continue` count as OUTSTANDING
  # and break. Measured: that mutation left all 35 tests green while permanently
  # stranding a fully-decided queue (shipped: archived=1 queued=0; mutated:
  # archived=0 queued=1). A queue that can never drain is the same failure as one
  # that drains itself, and this branch exists to remove both.
  #
  # Blank lines are NOT records: skipping them must affect neither tally. Leading,
  # trailing and interior blanks are all present so no single position can be
  # special-cased into passing.
  # FALSIFYING EDIT: change the archive pass's `[[ -z "$RECORD_JSON" ]] && continue`
  # to count the line as outstanding and break.
  a32_home6=$(mktemp -d); a32_state6="$a32_home6/.claude"; mkdir -p "$a32_state6"
  a32_b6a="Mixed-shape record one"; a32_b6b="Mixed-shape record two"
  {
    printf '\n'
    printf '{"ts":"2026-01-01T00:00:00Z","phase":"Implementation","body":"%s"}\n' "$a32_b6a"
    printf '\n'
    printf '{"ts":"2026-01-01T00:00:01Z","phase":"Verification","body":"%s"}\n' "$a32_b6b"
    printf '\n\n'
  } > "$a32_state6/pending-deviations-806.log"
  consumer_dismiss "$a32_home6" deviation "$a32_b6a" >/dev/null
  consumer_dismiss "$a32_home6" deviation "$a32_b6b" >/dev/null
  A32_OUT6=$(consumer_run "$a32_home6" attended)
  [[ "$(consumer_archived "$a32_state6")" -eq 1 ]] \
    || A32_FAILURES+=("leg 6: a snapshot whose every RECORD is dismissed was NOT archived because it also contains blank lines — blank lines are not records and must affect neither tally; treating them as outstanding strands a fully-decided queue forever, which is the same failure as draining one that was not: $A32_OUT6")
  [[ "$(consumer_queued "$a32_state6")" -eq 0 ]] \
    || A32_FAILURES+=("leg 6: the fully-decided mixed-shape snapshot is still queued: $A32_OUT6")
  rm -rf "$a32_home6"

  if [[ ${#A32_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (executed the real script: a 0-byte snapshot and a blank-lines-only snapshot both stayed queued with nothing archived and nothing dismissed; a genuinely fully-decided snapshot still retired; the record-less file was named as holding no records with no false resurface claim; an already-surfaced snapshot was NOT misclassified as record-less, and a decided snapshot padded with leading/interior/trailing blank lines still retired)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A32_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# Shared fixture builder for TC-STL-33/34/35.
#
# `make_lessons_yml` above cannot express `priority:` at all, so the eviction
# tests need their own emitter. Each lesson carries a `sources:` provenance list
# because the fast tier's byte budget depends on that list being PROJECTED AWAY —
# a fixture without provenance could not tell a working projection from a broken
# one.
#
# Args: dest_file  id  high|normal  body_bytes  occurrences  [sources_last|sources_mid]
# `sources_mid` puts the provenance list BEFORE the remaining scalar fields, which
# is the layout `make_lessons_yml` uses and the one that catches a stripper that
# deletes to end-of-block instead of scanning by indent.
# ---------------------------------------------------------------------------
emit_lesson() {
  local dest="$1" id="$2" pri="$3" bytes="$4" occ="$5" layout="${6:-sources_last}"
  local pad
  pad=$(printf '%*s' "$bytes" "" | tr ' ' 'x')
  {
    printf '  - id: "%s"\n' "$id"
    printf '    category: "test-coverage"\n'
    printf '    lesson: "Body of %s: %s"\n' "$id" "$pad"
    printf '    guidance: "Guidance for %s."\n' "$id"
    if [[ "$pri" == "high" ]]; then
      printf '    priority: high\n'
    fi
    if [[ "$layout" == "sources_mid" ]]; then
      printf '    sources:\n'
      printf '      - pr: "inherited-history#1"\n'
      printf '        origin: "automated-review"\n'
      printf '        verdict: "fixed"\n'
      printf '        ts: "2026-01-01T00:00:00Z"\n'
    fi
    printf '    occurrences: %s\n' "$occ"
    printf '    first_seen: "2026-01-01"\n'
    printf '    last_seen: "2026-01-01"\n'
    printf '    status: "active"\n'
    if [[ "$layout" == "sources_last" ]]; then
      printf '    sources:\n'
      printf '      - {pr: "inherited-history#1", origin: "automated-review", verdict: "fixed", ts: "2026-01-01T00:00:00Z"}\n'
    fi
  } >> "$dest"
}

# ---------------------------------------------------------------------------
# lesson_decisions <lessons-file>
#   Print the GENERATOR'S OWN verdict for every lesson block in <lessons-file>:
#   the decision-manifest rows it writes, one per block, tab-separated as
#   `id  priority  status  occurrences  bytes  disposition`.
#
# ⛔ THIS SUITE HAS EXACTLY ONE PARSER OF A LESSONS FILE, AND IT IS NOT HERE. ⛔
# What stood here was an awk transcription of the sync script's python regexes,
# rewritten three times, each rewrite prompted by a newly-found divergence and
# each introducing another. Measured on the last version before this one, in
# BOTH directions: `priority: -high` is ORDINARY to the generator (its capture
# class allows one optional quote, and `-` is not one, so the match simply fails)
# but HIGH to awk, whose leading-non-word strip is broader; and a `status:` whose
# value sits on the following line is ACTIVE to the generator (its `\s+` spans the
# newline) and invisible to awk, which requires whitespace after the colon on the
# same line. The inverted direction is the worse one — an INVENTED high makes
# TC-STL-34 demand exit 4 for a lesson the sync is right to evict quietly, and for
# a non-active lesson it can never pass at all, because such a lesson is never
# written to the fast tier.
#
# So this function does not parse YAML. It RUNS the sync against the file, in a
# throwaway HOME, and reads back the manifest the generator emits — the priority
# and status it actually resolved, and what it actually did with the block. There
# is nothing left to keep in step.
#
# COST: one sync execution per call, against a temp HOME. Accepted deliberately —
# this suite already executes the sync script from 31 call sites, so a handful
# more is not what makes it slow, and correctness by construction is worth more
# here than the milliseconds.
#
# FAIL TOWARD FAILING THE TEST: if the run leaves no complete manifest, this
# emits one synthetic HIGH+active row with an id no fixture can contain, so the
# callers below go RED. Printing nothing would be the alternative, and that is
# precisely the inert-detector shape (TL-0002) these tests exist to prevent: a
# silently empty enumeration makes TC-STL-34's loop body never run and reports
# green over an unchecked invariant.
# ---------------------------------------------------------------------------
lesson_decisions() {
  local src="$1" ld_home ld_man ld_rc=0
  ld_home=$(mktemp -d)
  HOME="$ld_home" SOURCE_OVERRIDE="$src" bash "$SYNC_SCRIPT" --quiet >/dev/null 2>&1 || ld_rc=$?
  ld_man="$ld_home/.claude/toolbox-knowledge/lessons-decisions.tsv"
  # ⛔ THE SAME CONTRACT THE SYNC APPLIES — this helper is a READER too. ⛔ It used
  # a position-blind `grep -q '^#END$'` with no CR handling, so it would have
  # accepted a manifest with rows AFTER a premature sentinel and read nothing at
  # all from a CRLF one. The sync requires the sentinel to be the last non-empty
  # line, normalises a trailing CR, and requires the read itself to succeed; a
  # harness that does less is a second reader diverging from the first, which is
  # the defect class this branch removes (automated-review, PR #152).
  local ld_last="" ld_read_rc=0
  if [[ -f "$ld_man" ]]; then
    ld_last=$(awk 'NF{last=$0} END{sub(/\r$/,"",last); print last}' "$ld_man" 2>/dev/null) || ld_read_rc=$?
  else
    ld_read_rc=1
  fi
  if [[ "$ld_read_rc" -eq 0 && "$ld_last" == "#END" ]]; then
    # Data rows only — `#`-initial lines are the column header and the sentinel.
    # CR is stripped here for the same reason the sync strips it: the disposition
    # column is last, so on a CRLF record every value would read `kept\r`.
    #
    # ⛔ THE ROW READ FAILS TOWARD RED, NOT TOWARD PARTIAL OUTPUT. ⛔ This ended in
    # `|| true`, so an awk that died half way through handed the callers a
    # SHORTENED decision list and no indication anything had gone wrong — and a
    # shortened list is exactly what makes TC-STL-34's loop body skip the lesson
    # that would have failed it. Buffer the rows, check the status, and fall
    # through to the synthetic row below if the read did not complete (automated-review,
    # PR #152).
    local ld_rows="" ld_rows_rc=0
    ld_rows=$(awk '{ sub(/\r$/, "") } !/^#/' "$ld_man" 2>/dev/null) || ld_rows_rc=$?
    if [[ "$ld_rows_rc" -eq 0 ]]; then
      # Only print when there is something to print. A manifest that is a header
      # plus `#END` with ZERO data rows is legitimate (a source with no lesson
      # blocks), and `printf '%s\n' ""` would emit a single newline — one empty
      # "row" that callers would have to know to discard. Every caller today
      # either captures with $(...) (which strips it) or pipes to awk (which
      # ignores it), so this was latent rather than live; it is still a record
      # the generator never emitted (Codex, PR #152).
      [[ -n "$ld_rows" ]] && printf '%s\n' "$ld_rows"
      rm -rf "$ld_home"
      return 0
    fi
    printf 'DECISION-MANIFEST-ROWREAD-FAILED-rc%s\thigh\tactive\t0\t0\tevicted\n' "$ld_rows_rc"
  else
    printf 'DECISION-MANIFEST-UNREADABLE-rc%s\thigh\tactive\t0\t0\tevicted\n' "$ld_rc"
  fi
  rm -rf "$ld_home"
}

# high_active_lesson_ids <lessons-file>
# The id of every lesson the generator resolved as BOTH `priority: high` AND
# `status: active` — i.e. every lesson that is entitled to a fast-tier seat and
# whose loss would be the severe one. Reads the manifest columns; asserts nothing
# about YAML.
high_active_lesson_ids() {
  lesson_decisions "$1" | awk -F'\t' '$2 == "high" && $3 == "active" { print $1 }'
}

# Header every fixture needs before any emit_lesson call.
emit_lessons_header() {
  cat > "$1" <<'FIXHDR'
# toolbox-lessons.yml — fixture for the eviction-reporting tests.
schema_version: 1
lessons:
FIXHDR
}

# ---------------------------------------------------------------------------
# TC-STL-33: EXECUTES the sync to prove a cap eviction is REPORTED, and that an
# evicted `priority: high` lesson escalates to a distinguishable exit code.
#
# WHY: the cap is fine; the SILENCE was the defect (issue #144). The measured
# state on main: 7 of 19 lessons reached the fast tier, `TL-0011` (priority:
# high) was dropped, and the run printed success and exited 0 — so no caller and
# no human could tell that a lesson deliberately marked severe never reached a
# review prompt.
#
# WHY AN EXIT CODE AND NOT ONLY A WARNING: both automated callers invoke this as
# `... --quiet 2>/dev/null` (scripts/install.sh ~line 658, scripts/update.sh
# ~line 378), so a stderr message is discarded before anything can read it — the
# same reasoning that already put the empty-fast-tier signal on exit code 3. Exit
# 4 is a SEPARATE code from 3 because the two states need different advice: 3
# means agents read nothing, 4 means they read most things. Neither aborts an
# install — both callers capture the status with `|| SYNC_RC=$?` and only warn —
# so escalating cannot brick an install.
#
# Eight legs (the header used to say "four" and list only A-D, while E and F
# were already here — corrected). Legs C and D exist so leg A cannot pass
# vacuously:
#   A   a HIGH is pushed out by the cap  -> exit 4, the HIGH is NAMED on stderr
#   B   the non-high lessons pushed out alongside it are ALSO named
#   B2  and NOTHING about the eviction lands on stdout under --quiet
#   C   nothing is evicted at all        -> exit 0, no eviction report (control)
#   D   lessons are evicted but none HIGH -> exit 0, still named on stderr
#   E   both callers MAP exit 4 to their own branch          (source-structure)
#   E2  and that branch does not claim more than exit 4 proves (source-structure)
#   F   an unreadable decision manifest escalates anyway (fail toward reporting)
# Leg D is the one that pins exit 4 to the HIGH tag specifically rather than to
# "any eviction" — without it, TC-STL-2's "sync exits 0 on valid capped input"
# and this test could not both hold. Leg F is what makes E2 necessary: it reaches
# exit 4 with a fixture in which NO lesson is high, so a caller message that
# asserts a HIGH eviction outright is false in a state this very test produces.
#
# FALSIFYING EDIT: delete the eviction-manifest read in sync-toolbox-lessons.sh,
# or drop the `HIGH_EVICTED` exit-code branch — legs A/B/D go red. Move the
# eviction `warn`s to stdout — legs A/B/B2 go red (and did NOT before the
# capture was split; the merged `2>&1` version passed that regression while
# reporting "named on stderr").
# ---------------------------------------------------------------------------
TC="TC-STL-33: cap evictions are reported and an evicted HIGH escalates (executed)"
A33_FAILURES=()

# --- Leg A + B: three oversized HIGH lessons, only two can fit -------------
# ~3000-byte bodies: measured, two blocks come to 6726 bytes and fit under the
# 8192-byte cap while the third cannot, whether or not provenance is projected
# away (the provenance list is 122 bytes, far too small to change which blocks
# fit — so this fixture saturates identically before and after the projection).
a33_home=$(mktemp -d); a33_repo=$(mktemp -d); mkdir -p "$a33_repo/knowledge"
a33_src="$a33_repo/knowledge/toolbox-lessons.yml"
emit_lessons_header "$a33_src"
emit_lesson "$a33_src" "TL-H001" high   3000 9
emit_lesson "$a33_src" "TL-H002" high   3000 8
emit_lesson "$a33_src" "TL-H003" high   3000 7
emit_lesson "$a33_src" "TL-N001" normal 3000 6
A33_RC=0
# ⛔ STDERR AND STDOUT ARE CAPTURED SEPARATELY, not merged with `2>&1`. ⛔
# The channel is part of the contract, not an accident: sync-toolbox-lessons.sh
# routes every eviction notice to STDERR even under --quiet, precisely because
# --quiet exists to keep stdout clean for the two automated callers. A merged
# `2>&1` capture cannot tell the two apart, so an implementation that printed
# the eviction report on stdout — polluting every install — would satisfy legs
# A and B unchanged. Splitting the streams is what makes those legs mean
# "reported on the degradation channel" rather than "reported somewhere".
a33_errf="$a33_home/sync-stderr.log"
a33_outf="$a33_home/sync-stdout.log"
HOME="$a33_home" SOURCE_OVERRIDE="$a33_src" bash "$SYNC_SCRIPT" --quiet >"$a33_outf" 2>"$a33_errf" || A33_RC=$?
A33_ERR=$(cat "$a33_errf" 2>/dev/null || true)
A33_STDOUT=$(cat "$a33_outf" 2>/dev/null || true)
# Both streams, for failure messages only — never for an assertion.
A33_OUT="[stderr] $A33_ERR [stdout] $A33_STDOUT"
a33_fast="$a33_home/.claude/toolbox-knowledge/lessons.yml"
a33_kept=$(grep -c '^  - id:' "$a33_fast" 2>/dev/null || echo 0)

# Sanity: the fixture must actually saturate, or legs A/B prove nothing.
if [[ "$a33_kept" -ge 4 ]]; then
  A33_FAILURES+=("leg A precondition: the fixture did not saturate — all $a33_kept lessons fit, so nothing was evicted and the eviction report cannot be exercised")
fi
# Leg A: the evicted HIGH must be named on stderr AND raise the exit code.
if ! grep -q 'TL-H003' <<<"$A33_ERR"; then
  A33_FAILURES+=("leg A: the evicted priority:high lesson TL-H003 is not named on STDERR — a HIGH lesson that reaches no review prompt must say so, on the degradation channel: $A33_OUT")
fi
if [[ "$A33_RC" -ne 4 ]]; then
  A33_FAILURES+=("leg A: sync exited $A33_RC after evicting a priority:high lesson, expected 4 — both callers run this as '--quiet 2>/dev/null', so a stderr-only warning is discarded and the exit code is the only channel that survives")
fi
# Leg B: the ordinary lessons that also fell out must be listed, not just the HIGH.
if ! grep -q 'TL-N001' <<<"$A33_ERR"; then
  A33_FAILURES+=("leg B: the evicted non-high lesson TL-N001 is not named on STDERR — the report must cover EVERY eviction, not only the escalating one: $A33_OUT")
fi
# Leg B2: and NOTHING about the eviction may land on stdout. `--quiet` exists to
# keep stdout clean for install.sh / update.sh; an eviction report printed there
# becomes install noise on every run and, worse, would let legs A and B pass with
# the degradation channel broken. This is the assertion the merged `2>&1` capture
# could not make.
if grep -qi 'evict' <<<"$A33_STDOUT"; then
  A33_FAILURES+=("leg B2: an eviction notice reached STDOUT under --quiet — the report belongs on stderr only, or it becomes install noise and the stderr contract is unenforced: [stdout] $A33_STDOUT")
fi
rm -rf "$a33_home" "$a33_repo"

# --- Leg C (control): nothing evicted -> exit 0 and no eviction report -----
# This leg is GREEN both before and after the fix. It is a CONTROL: it exists so
# that "exit 4 on eviction" cannot be satisfied by an unconditional exit 4, and
# so an eviction report cannot be printed when there is nothing to report.
a33_home2=$(mktemp -d); a33_repo2=$(mktemp -d); mkdir -p "$a33_repo2/knowledge"
a33_src2="$a33_repo2/knowledge/toolbox-lessons.yml"
emit_lessons_header "$a33_src2"
emit_lesson "$a33_src2" "TL-H101" high   200 3
emit_lesson "$a33_src2" "TL-N101" normal 200 2
A33_RC2=0
A33_OUT2=$(HOME="$a33_home2" SOURCE_OVERRIDE="$a33_src2" bash "$SYNC_SCRIPT" --quiet 2>&1) || A33_RC2=$?
if [[ "$A33_RC2" -ne 0 ]]; then
  A33_FAILURES+=("leg C (control): sync exited $A33_RC2 on a source that fits entirely — nothing was evicted, so nothing may escalate: $A33_OUT2")
fi
if grep -qi 'evict' <<<"$A33_OUT2"; then
  A33_FAILURES+=("leg C (control): sync reported an eviction on a source where every lesson fit: $A33_OUT2")
fi
rm -rf "$a33_home2" "$a33_repo2"

# --- Leg D: evictions with NO high tag -> reported, but exit stays 0 -------
a33_home3=$(mktemp -d); a33_repo3=$(mktemp -d); mkdir -p "$a33_repo3/knowledge"
a33_src3="$a33_repo3/knowledge/toolbox-lessons.yml"
emit_lessons_header "$a33_src3"
emit_lesson "$a33_src3" "TL-N201" normal 3000 9
emit_lesson "$a33_src3" "TL-N202" normal 3000 8
emit_lesson "$a33_src3" "TL-N203" normal 3000 7
A33_RC3=0
A33_OUT3=$(HOME="$a33_home3" SOURCE_OVERRIDE="$a33_src3" bash "$SYNC_SCRIPT" --quiet 2>&1) || A33_RC3=$?
if [[ "$A33_RC3" -ne 0 ]]; then
  A33_FAILURES+=("leg D: sync exited $A33_RC3 when the evicted lessons carried NO priority:high tag — exit 4 must mean 'a severe lesson was dropped', not 'the cap did its job', or TC-STL-2's exit-0-on-capped-input contract breaks: $A33_OUT3")
fi
if ! grep -q 'TL-N203' <<<"$A33_OUT3"; then
  A33_FAILURES+=("leg D: the evicted lesson TL-N203 is not named in the sync output — every eviction is reported even when none escalates: $A33_OUT3")
fi
rm -rf "$a33_home3" "$a33_repo3"

# --- Leg E (structural): both callers must MAP exit 4 to its own message ---
# ⛔ This leg is a SOURCE-STRUCTURE assertion, not a behavioural one, and says so.
# Running install.sh in a test would rewrite the developer's real ~/.claude, so
# the caller-side mapping cannot be executed here. `code_lines_in` excludes
# comment lines, so a commented-out branch does not satisfy it. What this leg
# CANNOT prove is that the branch prints something useful — only that exit 4 is
# handled separately from the generic failure branch, which would otherwise
# report a healthy pack as "stale or missing".
for a33_caller in "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/update.sh"; do
  if [[ ! -f "$a33_caller" ]]; then
    A33_FAILURES+=("leg E: caller $a33_caller not found")
    continue
  fi
  a33_hits=$(code_re_lines_in "$a33_caller" 'SYNC_RC.*-eq[[:space:]]*4' | wc -l | tr -d ' ')
  if [[ "$a33_hits" -lt 1 ]]; then
    A33_FAILURES+=("leg E: $(basename "$a33_caller") has no 'SYNC_RC -eq 4' branch — it would fall through to the generic failure message and tell the developer the pack is 'stale or missing' when in fact the pack is fine and a HIGH lesson was dropped")
    continue
  fi

  # Leg E2 (also SOURCE-STRUCTURE): the exit-4 branch may not claim more than
  # exit 4 proves. Exit 4 has TWO causes, and this test exercises both:
  #   leg A  a lesson above ordinary priority really was pushed out, and
  #   leg F  the decision manifest was missing/truncated, so the sync could not
  #          tell whether any evicted lesson was high and escalated rather than
  #          stay silent — a state leg F reaches with a fixture in which NO
  #          lesson is high at all.
  # A branch that states only the first is factually false in the second, and
  # sends the developer looking for a severe eviction that may not have happened.
  # Scoped to the BRANCH BODY, not the whole file: "manifest" appears in both
  # callers for unrelated reasons (install.sh's agent manifest, update.sh's
  # local-owned manifest), so a file-level grep would pass vacuously.
  a33_b4=$(awk '
    /SYNC_RC" -eq 4 \]/ { inb = 1; next }
    inb && /^[[:space:]]*(elif|else|fi)([[:space:]]|$)/ { inb = 0 }
    inb && !/^[[:space:]]*#/ { print }
  ' "$a33_caller")
  if [[ -z "$a33_b4" ]]; then
    A33_FAILURES+=("leg E2: could not locate the exit-4 branch body in $(basename "$a33_caller") — the branch shape changed and this assertion can no longer see it")
  elif ! grep -qi 'manifest' <<<"$a33_b4"; then
    A33_FAILURES+=("leg E2: the exit-4 branch in $(basename "$a33_caller") names only the evicted-HIGH cause. Leg F proves exit 4 also fires when the eviction manifest is missing or truncated with nothing high evicted, so a message asserting that a 'priority: high' lesson WAS evicted is false in that state: $a33_b4")
  fi
done

# --- Leg F: FAIL-OPEN — an unreadable eviction list escalates anyway ------
# The report is only as good as the manifest the python pass writes, so the
# branch that runs when the manifest is MISSING has to be exercised too. A
# `python3` shim earlier on PATH forwards only the first four arguments, so the
# real pass still writes a correct fast tier but never writes a manifest — the
# exact state where the script knows lessons went missing and cannot tell whether
# any was tagged high.
#
# The fixture is leg D's (evictions, none of them HIGH), which normally exits 0.
# Under the shim it must exit 4 instead: with the list unavailable the guard has
# to assume the worst, because the alternative default is the silent drop this
# whole test exists to end. Reusing leg A's fixture here would prove nothing —
# it would exit 4 from the HIGH tag alone.
a33_shim=$(mktemp -d)
a33_realpy=$(command -v python3 || true)
if [[ -z "$a33_realpy" ]]; then
  A33_FAILURES+=("leg F: no python3 on PATH, cannot build the argument-dropping shim")
else
  # Forward script + src + cap + dest ($1..$4) and drop ONLY the manifest path
  # ($5). Dropping $4 as well makes the real pass fail on a missing dest and the
  # script falls back to an EMPTY fast tier — a different code path entirely,
  # which is what the precondition below exists to catch.
  printf '#!/usr/bin/env bash\nexec %s "$1" "$2" "$3" "$4"\n' "$a33_realpy" > "$a33_shim/python3"
  chmod +x "$a33_shim/python3"
  a33_home4=$(mktemp -d); a33_repo4=$(mktemp -d); mkdir -p "$a33_repo4/knowledge"
  a33_src4="$a33_repo4/knowledge/toolbox-lessons.yml"
  emit_lessons_header "$a33_src4"
  emit_lesson "$a33_src4" "TL-N301" normal 3000 9
  emit_lesson "$a33_src4" "TL-N302" normal 3000 8
  emit_lesson "$a33_src4" "TL-N303" normal 3000 7
  A33_RC4=0
  A33_OUT4=$(PATH="$a33_shim:$PATH" HOME="$a33_home4" SOURCE_OVERRIDE="$a33_src4" \
    bash "$SYNC_SCRIPT" --quiet 2>&1) || A33_RC4=$?
  a33_fast4="$a33_home4/.claude/toolbox-knowledge/lessons.yml"
  a33_kept4=$(grep -c '^  - id:' "$a33_fast4" 2>/dev/null || echo 0)
  # Precondition: the shim must not have broken the fast tier itself, or leg F
  # would be measuring a crash rather than the fail-open branch.
  if [[ "$a33_kept4" -lt 1 ]]; then
    A33_FAILURES+=("leg F precondition: the argument-dropping shim produced an empty fast tier ($a33_kept4 lessons), so the missing-manifest branch was never the thing under test: $A33_OUT4")
  fi
  if [[ "$A33_RC4" -ne 4 ]]; then
    A33_FAILURES+=("leg F: with the decision manifest unwritten, sync exited $A33_RC4 — it kept $a33_kept4 of 3 active lessons, so it KNOWS lessons were dropped and cannot prove none was priority:high; the guard must default to reporting (4), because defaulting to silence is the defect: $A33_OUT4")
  fi
  if ! grep -qi 'manifest' <<<"$A33_OUT4"; then
    A33_FAILURES+=("leg F: the output does not mention the missing/truncated manifest, so a developer seeing exit 4 cannot tell a real HIGH eviction from an unreadable report: $A33_OUT4")
  fi
  rm -rf "$a33_home4" "$a33_repo4"
fi
rm -rf "$a33_shim"

if [[ ${#A33_FAILURES[@]} -eq 0 ]]; then
  pass_test "$TC (an evicted priority:high lesson was named on stderr — captured separately from stdout — and raised exit 4; the non-high lessons evicted with it were named too; nothing about the eviction leaked onto stdout under --quiet; a source that fits entirely stayed at exit 0 with no eviction report; evictions carrying no high tag were reported at exit 0; an unwritten eviction manifest still escalated to 4 and said why; and both callers map exit 4 to their own branch AND name the unconfirmed-manifest cause rather than asserting a HIGH eviction outright)"
else
  fail_test "$TC" "$(printf '%s; ' "${A33_FAILURES[@]}")"
fi

# ---------------------------------------------------------------------------
# TC-STL-34: EXECUTES the sync against the REAL knowledge/toolbox-lessons.yml to
# pin the selection invariant that saturation used to break.
#
# WHY THE REAL FILE AND NOT A FIXTURE: the defect was a property of the actual
# byte budget — 19 lessons totalling ~18.4 KB competing for 8192 bytes. A fixture
# can reproduce the shape but not the numbers, and it was the numbers that
# decided which lessons a reviewer never sees. Measured on main: the fast tier
# held 7 lessons and dropped `TL-0008` (7 occurrences, the most-recurring pattern
# in the file) and `TL-0001` (6) while keeping three single-occurrence lessons,
# because `priority: high` outranked frequency absolutely and there were more
# high-tagged lessons than slots.
#
# Three assertions, chosen so adding a 20th lesson does not make this test lie:
#   1. every `priority: high` lesson in the source either reaches the fast tier
#      or the run exits 4 and names it — the INVARIANT, not a fixed membership
#      list, so growth is allowed as long as it is not silent
#   2. TL-0008 and TL-0001 reach the fast tier — the issue's stated goal
#   3. TL-0005 and TL-0006 reach the fast tier — the two SECURITY lessons the
#      priority tag was originally added to protect (sync-toolbox-lessons.sh
#      records that sorting on occurrences alone once dropped them). Any fix that
#      buys frequency by regressing those two is not a fix.
#
# FALSIFYING EDIT: restore the verbatim block emission (drop the provenance
# projection) — assertion 2 goes red because TL-0008 and TL-0001 no longer fit.
# ---------------------------------------------------------------------------
TC="TC-STL-34: the real lesson file's most-recurring and security lessons all reach the fast tier (executed)"
A34_FAILURES=()
a34_real="$SCRIPT_DIR/../knowledge/toolbox-lessons.yml"
if [[ ! -f "$a34_real" ]]; then
  fail_test "$TC" "the real knowledge/toolbox-lessons.yml was not found at $a34_real"
else
  a34_home=$(mktemp -d)
  A34_RC=0
  A34_OUT=$(HOME="$a34_home" SOURCE_OVERRIDE="$a34_real" bash "$SYNC_SCRIPT" --quiet 2>&1) || A34_RC=$?
  a34_fast="$a34_home/.claude/toolbox-knowledge/lessons.yml"
  a34_size=$(wc -c < "$a34_fast" 2>/dev/null | tr -d ' ')
  a34_kept=$(grep -c '^  - id:' "$a34_fast" 2>/dev/null || echo 0)

  # The cap itself is not up for negotiation — consumers inject this file
  # assuming <= 8 KB, so a fix that simply raised the ceiling is not accepted.
  if [[ "${a34_size:-0}" -gt 8192 ]]; then
    A34_FAILURES+=("the fast tier is ${a34_size} bytes, over the 8192-byte cap the review-prompt consumers assume")
  fi

  # Assertion 1 — no HIGH may be missing SILENTLY. Enumerate the high-tagged ids
  # from the source itself rather than hardcoding them, so a newly-tagged lesson
  # is covered the day it lands.
  #
  # ⛔ DECIDE AT BLOCK END, NOT ON WHICHEVER KEY COMES SECOND. ⛔ The first
  # version set a flag on `priority:` and printed on `status:`, so a lesson whose
  # `status:` line PRECEDES its `priority:` line was never emitted. YAML mapping
  # keys have no required order and three real entries (TL-0013, TL-0018,
  # TL-0019) are written that way, so this enumerated 5 of the 8 high-tagged
  # lessons. The loop below then asserted the invariant over that subset only —
  # evicting any of those three left this test green, which is the inert-detector
  # class (TL-0002) inside the test written to prevent a silent eviction. Both
  # flags are now collected across the whole block and the decision is made when
  # the block ends, which is order-independent by construction.
  # One sync run, read twice: the high+active ids for assertion 1, and the
  # occurrence count for assertion 2's failure message. Both come from the
  # generator's manifest, so neither re-reads the YAML.
  a34_decisions=$(lesson_decisions "$a34_real")
  a34_high_ids=$(printf '%s\n' "$a34_decisions" | awk -F'\t' '$2 == "high" && $3 == "active" { print $1 }')
  for a34_id in $a34_high_ids; do
    if ! grep -q "id: $a34_id" "$a34_fast" 2>/dev/null; then
      # Missing is allowed — SILENTLY missing is not.
      if [[ "$A34_RC" -ne 4 ]] || ! grep -q "$a34_id" <<<"$A34_OUT"; then
        A34_FAILURES+=("priority:high lesson $a34_id is absent from the fast tier and the run neither exited 4 nor named it (exit was $A34_RC) — that is the silent HIGH eviction issue #144 is about")
      fi
    fi
  done

  # Assertion 2 — the two most-recurring patterns must be injected. These are the
  # defect classes the repo re-commits most often, so they are the ones a review
  # prompt most needs. Named explicitly because the issue names them.
  for a34_id in TL-0008 TL-0001; do
    if ! grep -q "id: $a34_id" "$a34_fast" 2>/dev/null; then
      a34_occ=$(printf '%s\n' "$a34_decisions" | awk -F'\t' -v want="$a34_id" '$1 == want { print $4; exit }')
      A34_FAILURES+=("$a34_id (${a34_occ:-?} occurrences — among the most-seen in the file) did not reach the fast tier, so the review prompts that would catch its defect class never carry it; only $a34_kept of the source's lessons fit in ${a34_size} bytes")
    fi
  done

  # Assertion 3 — non-regression on the two SECURITY lessons.
  for a34_id in TL-0005 TL-0006; do
    if ! grep -q "id: $a34_id" "$a34_fast" 2>/dev/null; then
      A34_FAILURES+=("security lesson $a34_id fell out of the fast tier — the priority tag exists precisely because an earlier occurrences-only sort dropped TL-0005 and TL-0006, and buying frequency back by re-dropping them is a regression, not a fix")
    fi
  done

  rm -rf "$a34_home"
  if [[ ${#A34_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (${a34_kept} lessons in ${a34_size}B: every active priority:high lesson reached the fast tier or was named at exit 4, TL-0008 and TL-0001 both reached it, and the TL-0005/TL-0006 security lessons were not traded away)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A34_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-35: EXECUTES the sync to prove the fast tier carries the reviewer-facing
# fields and DROPS the `sources:` provenance list — the projection that freed the
# byte budget TC-STL-34 depends on.
#
# WHY provenance and nothing else: `sources:` records which PR raised a finding,
# which reviewer, with what verdict, and when. No review agent reads any of that
# — both consumers (skills/code-review-orchestration/SKILL.md,
# skills/codex-review/SKILL.md) `cat` the file into a prompt as advisory prose.
# The slow tier is already declared the immutable provenance record, so the
# audit trail is not lost, it is just not paid for twice. Measured on the real
# file: 4408 of 18417 bytes, which is what lifts membership from 7 lessons to 10.
#
# Three legs:
#   1. the fast tier contains no provenance keys, the slow tier still does
#   2. a `sources:` list that is NOT the last field does not swallow the fields
#      after it — the stripper scans by indent, and a to-end-of-block delete
#      would silently eat occurrences/first_seen/last_seen/status
#   3. control: the SLOW tier for the same fixture DOES carry those provenance
#      keys, so leg 1's absence cannot be satisfied by a fixture that never had
#      provenance in the first place
#
# FALSIFYING EDIT: emit blocks verbatim again — leg 1 goes red. Replace the
# indent scan with `re.sub(r"\n    sources:.*", "", block, flags=S)` — leg 2 goes
# red because status/occurrences vanish with the provenance.
# ---------------------------------------------------------------------------
TC="TC-STL-35: the fast tier drops provenance and keeps every reviewer-facing field (executed)"
A35_FAILURES=()
a35_home=$(mktemp -d); a35_repo=$(mktemp -d); mkdir -p "$a35_repo/knowledge"
a35_src="$a35_repo/knowledge/toolbox-lessons.yml"
emit_lessons_header "$a35_src"
# sources_mid: provenance sits BEFORE occurrences/first_seen/last_seen/status.
emit_lesson "$a35_src" "TL-M001" normal 100 5 sources_mid
# sources_last: provenance is the final field, the real file's layout.
emit_lesson "$a35_src" "TL-M002" high   100 4 sources_last
A35_RC=0
A35_OUT=$(HOME="$a35_home" SOURCE_OVERRIDE="$a35_src" bash "$SYNC_SCRIPT" --quiet 2>&1) || A35_RC=$?
a35_fast="$a35_home/.claude/toolbox-knowledge/lessons.yml"
a35_slow="$a35_home/.claude/toolbox-knowledge/toolbox-lessons.yml"

if [[ "$A35_RC" -ne 0 ]]; then
  A35_FAILURES+=("sync exited $A35_RC on a two-lesson source that fits well inside the cap: $A35_OUT")
fi
# Leg 1 — no provenance in the fast tier.
for a35_key in 'sources:' 'origin:' 'verdict:' 'inherited-history#1'; do
  if grep -qF "$a35_key" "$a35_fast" 2>/dev/null; then
    A35_FAILURES+=("leg 1: the fast tier still carries the provenance key '$a35_key' — provenance is audit metadata no review agent reads, and the bytes it costs are what evict lessons that agents DO read")
  fi
done
# Leg 2 — the fields that FOLLOW a mid-block sources list must survive.
a35_m001=$(awk '/^  - id: "TL-M001"/{f=1;next} f&&/^  - id:/{exit} f' "$a35_fast" 2>/dev/null)
for a35_key in 'occurrences:' 'first_seen:' 'last_seen:' 'status:'; do
  if ! grep -qF "$a35_key" <<<"$a35_m001"; then
    A35_FAILURES+=("leg 2: TL-M001 lost '$a35_key' in the fast tier — its provenance list sits BEFORE those fields, so a stripper that deletes to end-of-block takes real reviewer-facing data with it")
  fi
done
if ! grep -qF 'guidance:' <<<"$a35_m001"; then
  A35_FAILURES+=("leg 2: TL-M001 lost 'guidance:' in the fast tier — guidance is the field that tells the agent what to DO about the lesson")
fi
# Leg 3 (control) — the slow tier must still hold the provenance the fast tier dropped.
for a35_key in 'origin:' 'verdict:' 'inherited-history#1'; do
  if ! grep -qF "$a35_key" "$a35_slow" 2>/dev/null; then
    A35_FAILURES+=("leg 3 (control): the SLOW tier is missing provenance key '$a35_key' — the audit trail must survive the projection, and without this leg the fast tier's cleanliness in leg 1 could just mean the fixture had no provenance at all")
  fi
done
rm -rf "$a35_home" "$a35_repo"

if [[ ${#A35_FAILURES[@]} -eq 0 ]]; then
  pass_test "$TC (the fast tier carried no sources/origin/verdict/PR keys, a lesson whose provenance list sits mid-block kept occurrences/first_seen/last_seen/status/guidance, and the slow tier still held the full provenance)"
else
  fail_test "$TC" "$(printf '%s; ' "${A35_FAILURES[@]}")"
fi

# ---------------------------------------------------------------------------
# TC-STL-36: the generator must resolve every `priority: high` spelling it
# claims to accept, and must exclude a lesson that is not active.
#
# WHAT THIS PINS, NOW THAT THERE IS ONE PARSER: `high_active_lesson_ids` no
# longer transcribes anything — it runs the sync and reads the priority and
# status the generator RESOLVED, from the decision manifest the generator emits.
# So these legs are assertions about the generator itself: that its capture class
# accepts `high`, `"high"`, `'high'`, `HIGH` and `high # trailing comment` (the
# `\w+` capture stops before the `#`), that `priority: normal` is not swept up
# with them, and that a `status: superseded` lesson never counts as an active
# high one however it is tagged.
#
# That matters because TC-STL-34's whole value is assertion 1 — "no active
# `priority: high` lesson may go missing from the fast tier SILENTLY" — and its
# loop runs over exactly this set. A spelling the generator resolves as ordinary
# when a human meant it as high is a lesson the invariant does not cover, and no
# amount of care in the reader can find that: only the generator's own answer
# can. TC-STL-34 cannot make this assertion itself, because every high tag in
# the real lesson file happens to be written bare.
#
# ⛔ THIS IS NO LONGER A TWO-PARSERS-AGREE TEST, AND MUST NOT BE READ AS ONE. ⛔
# Its predecessor compared an awk enumerator against the python generator and was
# rewritten three times chasing divergences. There is nothing to compare now. The
# residual risk this cannot see is a generator whose accepted spellings drift
# from what a lesson author expects — which is why the fixture spells them out.
#
# Three legs:
#   1  every accepted spelling resolves to high+active, and neither a `normal`
#      lesson nor a SUPERSEDED high one does
#   2  (CONTROL — green both before and after the single-parser change) the
#      resolved priority has its observable CONSEQUENCE: those same lessons win
#      fast-tier seats over the ordinary ones, or are labelled priority=high in
#      the eviction report. Without it, a manifest that recorded a priority the
#      sort never used would satisfy leg 1 while the fast tier ignored it.
#   3  (CONTROL — green both ways) key order inside a block does not change the
#      answer. `re.search` is per-key and order-independent by construction, and
#      three real lessons (TL-0013/TL-0018/TL-0019) write `status:` first.
#
# ⛔ LEGS 1 AND 3 WERE GREEN BEFORE THIS CHANGE TOO. ⛔ They passed against the
# awk transcription and pass against the manifest, so neither is evidence that
# the single-parser change works — TC-STL-37 legs 9 and 10 are the ones that
# were RED before it. Leg 1 is kept because it still holds the generator to its
# documented spellings; it is not a regression test for this fix.
#
# FALSIFYING EDIT, applied and measured rather than assumed: compare the
# generator's captured priority WITHOUT `.lower()` — legs 1 and 2 both go red on
# TL-Q008 (`priority: HIGH`), and nothing else in the suite moves. Leg 2 going
# red with leg 1 is the point of leg 2: the spelling stops winning its fast-tier
# seat at the same moment it stops being reported as high.
# ---------------------------------------------------------------------------
TC="TC-STL-36: the generator resolves every priority spelling it accepts, and excludes non-active lessons (executed)"
A36_FAILURES=()

a36_repo=$(mktemp -d); mkdir -p "$a36_repo/knowledge"
a36_src="$a36_repo/knowledge/toolbox-lessons.yml"
# Hand-rolled rather than emit_lesson, because emit_lesson can only write the
# bare `priority: high` spelling — the one form that was never in question.
{
  printf '%s\n' '# fixture: every priority spelling the generator accepts'
  printf '%s\n' 'schema_version: 1'
  printf '%s\n' 'lessons:'
} > "$a36_src"
# a36_lesson <id> <priority-line-text> <status> [status_first]
a36_lesson() {
  local id="$1" priline="$2" st="$3" order="${4:-priority_first}" pad
  pad=$(printf '%*s' 3000 "" | tr ' ' 'y')
  {
    printf '  - id: %s\n' "$id"
    printf '    category: "test-coverage"\n'
    printf '    lesson: "Body of %s: %s"\n' "$id" "$pad"
    printf '    guidance: "Guidance for %s."\n' "$id"
    if [[ "$order" == "status_first" ]]; then
      printf '    status: "%s"\n' "$st"
      printf '%s\n' "$priline"
    else
      printf '%s\n' "$priline"
      printf '    status: "%s"\n' "$st"
    fi
    printf '    occurrences: 1\n'
    printf '    first_seen: "2026-01-01"\n'
    printf '    last_seen: "2026-01-01"\n'
  } >> "$a36_src"
}
a36_lesson TL-Q001 '    priority: high'            active
a36_lesson TL-Q002 '    priority: "high"'          active
a36_lesson TL-Q003 "    priority: 'high'"          active
a36_lesson TL-Q004 '    priority: high # severe'   active
a36_lesson TL-Q005 '    priority: high'            active status_first
a36_lesson TL-Q006 '    priority: normal'          active
a36_lesson TL-Q007 '    priority: high'            superseded
# UPPERCASE. The generator compares `.lower() == "high"`, so `HIGH` is a high tag
# to it; no lesson in the real file is written that way and nothing here covered
# the spelling, which is exactly how an accepted spelling goes unverified.
a36_lesson TL-Q008 '    priority: HIGH'            active

# --- Leg 1: the enumerator's answer -----------------------------------------
a36_got=$(high_active_lesson_ids "$a36_src" | tr '\n' ' ')
for a36_id in TL-Q001 TL-Q002 TL-Q003 TL-Q004 TL-Q008; do
  if [[ " $a36_got " != *" $a36_id "* ]]; then
    A36_FAILURES+=("leg 1: $a36_id is tagged with a priority spelling the sync script ranks HIGH, but the enumerator did not return it — a lesson it cannot see is a lesson TC-STL-34's no-silent-eviction invariant does not cover. Returned: [$a36_got]")
  fi
done
if [[ " $a36_got " == *" TL-Q006 "* ]]; then
  A36_FAILURES+=("leg 1: TL-Q006 is 'priority: normal' but the enumerator returned it as HIGH — over-matching turns TC-STL-34 into a false-failure generator. Returned: [$a36_got]")
fi
if [[ " $a36_got " == *" TL-Q007 "* ]]; then
  A36_FAILURES+=("leg 1: TL-Q007 is 'status: superseded' and never reaches the fast tier at all, but the enumerator returned it — the invariant only covers ACTIVE lessons. Returned: [$a36_got]")
fi

# --- Leg 2 (CONTROL): the generator's answer, for the same fixture ----------
# GREEN BOTH BEFORE AND AFTER the enumerator fix, and it asserts nothing about
# the enumerator. Its only job is to stop leg 1 being an invented convention: it
# proves the sync script itself really does treat 'high' and high # comment as
# HIGH, by making them the only lessons that survive the cap and reading back
# which ids the eviction report labels priority=high.
a36_home=$(mktemp -d)
A36_RC=0
a36_errf="$a36_home/stderr.log"
HOME="$a36_home" SOURCE_OVERRIDE="$a36_src" bash "$SYNC_SCRIPT" --quiet >/dev/null 2>"$a36_errf" || A36_RC=$?
A36_ERR=$(cat "$a36_errf" 2>/dev/null || true)
for a36_id in TL-Q003 TL-Q004 TL-Q008; do
  # Either it was kept (it outranked the ordinary lessons -> it IS high to the
  # generator), or it was evicted and the report must label it priority=high.
  if grep -q "id: $a36_id" "$a36_home/.claude/toolbox-knowledge/lessons.yml" 2>/dev/null; then
    continue
  fi
  if ! grep -qE "evicted: $a36_id \(priority=high" <<<"$A36_ERR"; then
    A36_FAILURES+=("leg 2 (control): the sync script did not treat $a36_id as priority=high — if the generator does not accept that spelling either, leg 1 is asserting a convention nobody implements: $A36_ERR")
  fi
done
# The fixture must actually saturate, or leg 2 proves nothing.
if [[ "$A36_RC" -ne 4 ]]; then
  A36_FAILURES+=("leg 2 (control) precondition: sync exited $A36_RC on a fixture of eight 3 KB lessons, expected 4 — nothing was evicted, so the eviction report leg 2 reads was never produced: $A36_ERR")
fi
rm -rf "$a36_home"

# --- Leg 3: key order inside a block must not matter ------------------------
# GREEN both ways today. It PINS the order-independent flush() that shipped with
# this test file and had nothing holding it: TL-Q005 writes `status:` BEFORE
# `priority:`, the layout three real lessons (TL-0013/TL-0018/TL-0019) use.
if [[ " $a36_got " != *" TL-Q005 "* ]]; then
  A36_FAILURES+=("leg 3: TL-Q005 declares status: active BEFORE priority: high and was not enumerated — YAML mapping keys have no required order and three real lessons are written that way, so an order-dependent enumerator silently drops them. Returned: [$a36_got]")
fi

rm -rf "$a36_repo"
if [[ ${#A36_FAILURES[@]} -eq 0 ]]; then
  pass_test "$TC (bare, double-quoted, single-quoted, UPPERCASE and trailing-comment high tags all resolved to high+active; a normal lesson and a superseded high lesson did not; the fast-tier selection independently agreed on the quoted and uppercase spellings; and a status-before-priority block resolved the same)"
else
  fail_test "$TC" "$(printf '%s; ' "${A36_FAILURES[@]}")"
fi

# ---------------------------------------------------------------------------
# TC-STL-37: the generator's RESOLVED priority/status — the record every other
# check now reads — must match what the generator actually acts on.
#
# WHY IT EXISTS, given TC-STL-36 already does: TC-STL-36 pins the VALUE dimension
# (which spellings of `high` count). This pins the POSITION dimension — where in
# a block the generator looks — plus, in legs 9 and 10, the two inputs that broke
# the old two-parser arrangement outright.
#
# The generator matches `\n\s+priority:` and `\n\s+status:` at ANY indent and
# `re.search` returns the FIRST occurrence, so a key-shaped line inside a
# `lesson: |` block scalar is a candidate to it. That is a surprising rule but it
# is the real one, and the manifest must report it rather than a tidier fiction,
# because the manifest is what decides whether TC-STL-34 demands a fast-tier seat.
#
# ⛔ LEGS 4-8 WERE GREEN BEFORE THE SINGLE-PARSER CHANGE AND ARE GREEN AFTER. ⛔
# They were written against the awk transcription's third revision, which already
# matched the generator on these four inputs; they are CONTROLS with respect to
# this change and are NOT evidence that it works. Legs 9 and 10 are the ones that
# were RED. Legs 4-8 are kept because they still hold the generator's position
# rules — they just do not pin this fix.
#
#   leg 4  (control) a body-scalar `priority: high` above an ordinary field is
#          resolved HIGH, because re.search takes the first match
#   leg 5  (control) a body-scalar `priority: normal` above a `priority: high`
#          field is resolved ORDINARY, for the same reason
#   leg 6  (control) a body-scalar `status: active` in a block whose status field
#          says superseded is resolved ACTIVE
#   leg 7  (control) `status: inactive` is NOT active — the capture is a whole
#          word, not a substring
#   leg 8  (control) the generator's SELECTION agrees with the resolution: the
#          two it called high keep their fast-tier seats and the ordinary one is
#          evicted and labelled priority=normal
#   leg 9  RED BEFORE — `priority: -high` is ORDINARY to the generator (its
#          capture allows one optional quote, and `-` is not one, so the match
#          fails and no later priority line exists), and the old awk read it as
#          HIGH because its leading-non-word strip was broader
#   leg 10 RED BEFORE — a `status:` whose value sits on the FOLLOWING line is
#          ACTIVE to the generator (`\s+` spans the newline) and was invisible to
#          the old awk, which required whitespace after the colon on that line
#
# WHY 9 AND 10 ARE THE ONES THAT MATTER: they are the two directions of the same
# defect. Leg 10 is a missed high — a hole in TC-STL-34's invariant, and the same
# input that made the sync's own `SRC_ACTIVE` guard inert (issue #151 P0-2). Leg
# 9 is an INVENTED high, which is worse: it makes TC-STL-34 demand exit 4 for a
# lesson the sync is right to evict quietly, i.e. red on correct behaviour.
#
# FALSIFYING EDIT, measured rather than assumed: restore the awk enumerator that
# stood in this file before the single-parser change and legs 9 and 10 both go
# red (leg 9 because `-high` enumerates, leg 10 because the multiline status does
# not) while nothing else in the suite moves.
# ---------------------------------------------------------------------------
TC="TC-STL-37: the generator resolves priority/status from the position it acts on (executed)"
A37_FAILURES=()

a37_repo=$(mktemp -d); mkdir -p "$a37_repo/knowledge"
a37_src="$a37_repo/knowledge/toolbox-lessons.yml"
{
  printf '%s\n' '# fixture: priority/status text that is PROSE, not a field'
  printf '%s\n' 'schema_version: 1'
  printf '%s\n' 'lessons:'
} > "$a37_src"

# a37_lesson <id> <body-line> <priority-field> <status-field>
# The body is a `lesson: |` block scalar, which is where a key-shaped line can
# legitimately appear as prose — lessons in the real file quote reviewer text.
# Each is padded to ~3 KB so the fixture saturates the 8 KB cap for leg 8.
a37_lesson() {
  local id="$1" body="$2" pri="$3" st="$4" pad
  pad=$(printf '%*s' 3000 "" | tr ' ' 'z')
  {
    printf '  - id: %s\n' "$id"
    printf '    category: "test-coverage"\n'
    printf '    lesson: |\n'
    printf '      Body of %s. %s\n' "$id" "$pad"
    printf '      %s\n' "$body"
    printf '    guidance: "Guidance for %s."\n' "$id"
    printf '    priority: %s\n' "$pri"
    printf '    status: "%s"\n' "$st"
    printf '    occurrences: 1\n'
    printf '    first_seen: "2026-01-01"\n'
    printf '    last_seen: "2026-01-01"\n'
  } >> "$a37_src"
}
#            id        prose line inside the block scalar   priority  status
a37_lesson TL-R001 'priority: high'                         normal    active
a37_lesson TL-R002 'priority: normal'                       high      active
a37_lesson TL-R003 'status: active'                         high      superseded
a37_lesson TL-R004 'nothing key-shaped here'                high      inactive

a37_got=$(high_active_lesson_ids "$a37_src" | tr '\n' ' ')

# --- Legs 4 and 6: the generator sees HIGH+active, the enumerator must too ---
if [[ " $a37_got " != *" TL-R001 "* ]]; then
  A37_FAILURES+=("leg 4: TL-R001's FIRST priority-shaped line is 'priority: high' inside its lesson body, which is the one the generator's re.search returns, so the sync ranks it HIGH — the enumerator did not return it, so TC-STL-34's no-silent-eviction invariant does not cover it. Returned: [$a37_got]")
fi
if [[ " $a37_got " != *" TL-R003 "* ]]; then
  A37_FAILURES+=("leg 6: TL-R003 is 'priority: high' and the generator's get_status reads the FIRST status-shaped line, 'status: active' in its body, so the sync treats it as an active HIGH — the enumerator did not return it. Returned: [$a37_got]")
fi

# --- Legs 5 and 7: the generator does NOT, so the enumerator must not either --
if [[ " $a37_got " == *" TL-R002 "* ]]; then
  A37_FAILURES+=("leg 5: TL-R002's first priority-shaped line is 'priority: normal', so the generator ranks it ORDINARY — enumerating it as HIGH makes TC-STL-34 demand exit 4 for a lesson the sync is right to evict quietly, i.e. red on correct behaviour. Returned: [$a37_got]")
fi
if [[ " $a37_got " == *" TL-R004 "* ]]; then
  A37_FAILURES+=("leg 7: TL-R004 is 'status: inactive'; the generator captures the whole word and drops the block from the active set, so it can NEVER appear in the fast tier — enumerating it as active HIGH makes TC-STL-34 fail unconditionally. Returned: [$a37_got]")
fi

# --- Leg 8 (CONTROL): the generator's own answer for the same fixture -------
# GREEN BOTH WAYS and it asserts nothing about the enumerator. Its only job is to
# stop legs 4-7 asserting an invented convention: it runs the real sync over this
# same file and reads back what the generator actually did. Three 3 KB active
# lessons against an 8 KB cap means exactly two survive, and priority outranks
# everything else in the sort — so R001 and R003 surviving IS the generator
# calling them HIGH, and R002 being the one evicted IS it calling R002 ordinary.
a37_home=$(mktemp -d)
A37_RC=0
a37_errf="$a37_home/sync-stderr.log"
HOME="$a37_home" SOURCE_OVERRIDE="$a37_src" bash "$SYNC_SCRIPT" --quiet >/dev/null 2>"$a37_errf" || A37_RC=$?
A37_ERR=$(cat "$a37_errf" 2>/dev/null || true)
a37_fast="$a37_home/.claude/toolbox-knowledge/lessons.yml"
for a37_id in TL-R001 TL-R003; do
  if ! grep -q "id: $a37_id" "$a37_fast" 2>/dev/null; then
    A37_FAILURES+=("leg 8 (control): the sync did not rank $a37_id above the ordinary lesson — it lost its fast-tier seat to TL-R002, so the generator does not read the block-scalar key the way legs 4/6 assume and those legs are asserting a convention nobody implements. stderr: $A37_ERR")
  fi
done
if grep -q "id: TL-R002" "$a37_fast" 2>/dev/null; then
  A37_FAILURES+=("leg 8 (control): TL-R002 kept a fast-tier seat, so the cap did not bind and this control proves nothing about ranking. stderr: $A37_ERR")
elif ! grep -qE "evicted: TL-R002 \(priority=normal" <<<"$A37_ERR"; then
  A37_FAILURES+=("leg 8 (control): TL-R002 was evicted but the report did not label it priority=normal — leg 5 assumes the generator reads its body's 'priority: normal' rather than its 'priority: high' field. stderr: $A37_ERR")
fi
if grep -q "id: TL-R004" "$a37_fast" 2>/dev/null; then
  A37_FAILURES+=("leg 8 (control): TL-R004 is 'status: inactive' and reached the fast tier anyway — leg 7 assumes the generator drops it from the active set entirely. stderr: $A37_ERR")
fi
rm -rf "$a37_home"

rm -rf "$a37_repo"

# --- Legs 9 and 10: the two inputs that broke the old transcription ---------
# Small blocks, no padding: nothing here is about the cap, only about how the
# two keys resolve. Both lessons are `status: active` in intent; TL-D902 writes
# that value on the next line, which is legal YAML and which the generator's
# `\s+` reads straight through.
a37_repo2=$(mktemp -d); mkdir -p "$a37_repo2/knowledge"
a37_src2="$a37_repo2/knowledge/toolbox-lessons.yml"
{
  printf '%s\n' '# fixture: the two divergences that motivated the single-parser change'
  printf '%s\n' 'schema_version: 1'
  printf '%s\n' 'lessons:'
  # `-high`: the generator allows ONE optional quote character after the colon
  # and `-` is not one, so its match fails and the block is ordinary.
  printf '%s\n' '  - id: TL-D901'
  printf '%s\n' '    lesson: "leading-punctuation priority value"'
  printf '%s\n' '    priority: -high'
  printf '%s\n' '    status: "active"'
  # A multiline status value — active to the generator, invisible to any
  # single-line reader.
  printf '%s\n' '  - id: TL-D902'
  printf '%s\n' '    lesson: "status value on the following line"'
  printf '%s\n' '    priority: high'
  printf '%s\n' '    status:'
  printf '%s\n' '      active'
} > "$a37_src2"

a37_got2=$(high_active_lesson_ids "$a37_src2" | tr '\n' ' ')
if [[ " $a37_got2 " == *" TL-D901 "* ]]; then
  A37_FAILURES+=("leg 9: TL-D901 is 'priority: -high', which the generator resolves as ORDINARY — reporting it as HIGH makes TC-STL-34 demand exit 4 for a lesson the sync is right to evict quietly, i.e. red on correct behaviour. Returned: [$a37_got2]")
fi
if [[ " $a37_got2 " != *" TL-D902 "* ]]; then
  A37_FAILURES+=("leg 10: TL-D902 writes its 'status:' value on the next line, which the generator resolves as ACTIVE, and it is 'priority: high' — not reporting it leaves TC-STL-34's no-silent-eviction invariant blind to exactly the input that made the sync's own SRC_ACTIVE guard inert (issue #151 P0-2). Returned: [$a37_got2]")
fi
rm -rf "$a37_repo2"

if [[ ${#A37_FAILURES[@]} -eq 0 ]]; then
  pass_test "$TC (a body-scalar 'priority: high' and 'status: active' resolved exactly as the generator acts on them, a lesson whose field says high but whose body says normal did not resolve high, 'inactive' was not mistaken for active, the selection independently agreed on all four, and the two divergence inputs — 'priority: -high' and a multiline status — resolved ordinary and active respectively)"
else
  fail_test "$TC" "$(printf '%s; ' "${A37_FAILURES[@]}")"
fi

# ---------------------------------------------------------------------------
# TC-STL-38: the generator EMITS its decisions, durably, completely, and once
# per lesson block.
#
# WHY: this file's whole silent-eviction class came from bash re-deriving in
# grep/awk what the python pass had already computed in `re`, and diverging.
# The cure is that the pass writes its verdicts down and everything else reads
# THAT — so the record itself needs pinning: it has to survive the script's exit
# (the previous eviction manifest was a mktemp file the EXIT trap deleted, so no
# caller could ever read it), it has to be complete or visibly incomplete, it has
# to cover EVERY block rather than only the evicted ones, and a PRIOR run's copy
# must never be mistaken for this run's.
#
# Five legs:
#   1  the manifest is at the pack path after the script has exited, with #END
#   2  one data row per lesson block, carrying the RESOLVED priority and status
#   3  dispositions are right: kept for what fit, evicted for what did not, and
#      `excluded` — never `evicted` — for a block that was never a candidate
#   4  the row for a non-active block still exists, so "considered and rejected"
#      is distinguishable from "not in the file"
#   5  a stale manifest left by an earlier run is NOT read as this run's
#
# ⛔ ONLY LEGS 1 AND 5 WERE RED AGAINST THE PREVIOUS SCRIPT. ⛔ Legs 2-4 sit in
# the `else` of leg 1 and did not run at all there, because there was no durable
# manifest for them to read — so the before-state is NOT evidence that they bite.
# What holds them is the falsifying edit below, which was applied and measured
# rather than assumed: emitting rows only for the evicted blocks (the shape the
# old eviction manifest had) reds legs 2, 3 and 4 together — the row count comes
# back 1 of 4, TL-D001's resolved priority and status read empty, its disposition
# reads empty rather than `kept`, and TL-D004 has no row at all.
#
# FALSIFYING EDITS, each applied and measured:
#   manifest back to a mktemp path        -> legs 1 and 5 red, and TC-STL-34/36/37
#                                            red with them (they all read it)
#   rows only for evicted blocks          -> legs 2, 3 and 4 red, and TC-STL-21/22
#                                            (the empty-tier guards) and TC-STL-40
#                                            red with them
#   drop the `rm -f` clearing the prior
#   manifest before the pass runs         -> leg 5 red, and nothing else moves
#
# The collateral in the first two is worth reading as a result in its own right:
# the manifest is not a report bolted onto the side, it is what the empty-tier
# guards and the whole high-lesson invariant now run on. Break it and they stop
# working, which is the property the single-parser change was after.
# ---------------------------------------------------------------------------
TC="TC-STL-38: the generator emits a durable, complete, per-block decision manifest (executed)"
A38_FAILURES=()

a38_home=$(mktemp -d); a38_repo=$(mktemp -d); mkdir -p "$a38_repo/knowledge"
a38_src="$a38_repo/knowledge/toolbox-lessons.yml"
emit_lessons_header "$a38_src"
# Two 3 KB active lessons fit; the third cannot. A superseded one is present so
# leg 4 has a block the pass considers and rejects.
emit_lesson "$a38_src" "TL-D001" high   3000 9
emit_lesson "$a38_src" "TL-D002" normal 3000 8
emit_lesson "$a38_src" "TL-D003" high   3000 7
printf '  - id: "TL-D004"\n    lesson: "retired"\n    guidance: "g"\n    occurrences: 1\n    status: "superseded"\n' >> "$a38_src"
A38_RC=0
HOME="$a38_home" SOURCE_OVERRIDE="$a38_src" bash "$SYNC_SCRIPT" --quiet >/dev/null 2>&1 || A38_RC=$?
a38_man="$a38_home/.claude/toolbox-knowledge/lessons-decisions.tsv"

# Leg 1 — durable and complete. Read AFTER the script exited, which is the whole
# point: the previous manifest was unlinked by the EXIT trap.
if [[ ! -f "$a38_man" ]]; then
  A38_FAILURES+=("leg 1: no decision manifest at $a38_man after the sync exited — a record only the script itself can read is not a record any caller or test can use, which is what the mktemp manifest was")
elif ! grep -q '^#END$' "$a38_man"; then
  A38_FAILURES+=("leg 1: the decision manifest has no #END sentinel, so a truncated file is indistinguishable from a complete one that recorded nothing: $(cat "$a38_man")")
else
  # Leg 2 — one row per block, with resolved values.
  a38_rows=$(grep -vc '^#' "$a38_man" || true)
  if [[ "${a38_rows:-0}" -ne 4 ]]; then
    A38_FAILURES+=("leg 2: the manifest holds ${a38_rows:-0} data row(s) for a 4-block source — a record that covers only some blocks cannot answer 'was anything dropped', which is the question it exists for: $(cat "$a38_man")")
  fi
  # a38_field <id> <column>  -> the manifest's value, or the empty string
  a38_field() { awk -F'\t' -v want="$1" -v col="$2" '!/^#/ && $1 == want { print $col; exit }' "$a38_man"; }
  [[ "$(a38_field TL-D001 2)" == "high"   ]] || A38_FAILURES+=("leg 2: TL-D001 is 'priority: high' but the manifest resolved priority='$(a38_field TL-D001 2)'")
  [[ "$(a38_field TL-D002 2)" == "normal" ]] || A38_FAILURES+=("leg 2: TL-D002 carries no priority field but the manifest resolved priority='$(a38_field TL-D002 2)'")
  [[ "$(a38_field TL-D001 3)" == "active" ]] || A38_FAILURES+=("leg 2: TL-D001 is 'status: active' but the manifest resolved status='$(a38_field TL-D001 3)'")
  # Leg 3 — dispositions. Priority outranks frequency, so the two high lessons
  # take the seats and the ordinary one is the eviction.
  [[ "$(a38_field TL-D001 6)" == "kept"    ]] || A38_FAILURES+=("leg 3: TL-D001 is in the fast tier but the manifest calls it '$(a38_field TL-D001 6)'")
  [[ "$(a38_field TL-D002 6)" == "evicted" ]] || A38_FAILURES+=("leg 3: TL-D002 lost its seat to the two high lessons but the manifest calls it '$(a38_field TL-D002 6)'")
  # Leg 4 — the superseded block is recorded, and recorded as NOT a candidate.
  # 'excluded' rather than 'evicted' matters: an evicted lesson had a claim on a
  # fast-tier seat and lost it, which is a degradation; a non-active lesson never
  # had one, and reporting it as an eviction would cry wolf on every retirement.
  if [[ -z "$(a38_field TL-D004 1)" ]]; then
    A38_FAILURES+=("leg 4: the superseded lesson TL-D004 has no row at all — 'the pass considered it and rejected it' then reads identically to 'it is not in the source', and the empty-tier guard needs to tell those apart")
  fi
  [[ "$(a38_field TL-D004 6)" == "excluded"   ]] || A38_FAILURES+=("leg 4: TL-D004 is superseded and was never a fast-tier candidate, but the manifest calls it '$(a38_field TL-D004 6)'")
  [[ "$(a38_field TL-D004 3)" == "superseded" ]] || A38_FAILURES+=("leg 4: TL-D004's resolved status is '$(a38_field TL-D004 3)', not 'superseded'")
fi
rm -rf "$a38_home" "$a38_repo"

# --- Leg 5: a PRIOR run's manifest must never read as this run's ------------
# The manifest is durable, which is exactly why this needs pinning: an earlier
# run's file sitting at the same path would otherwise satisfy every "is there a
# manifest?" check while describing a different source entirely. The pass is made
# to fail immediately here, so nothing new is written and the only manifest that
# could be read is the planted one.
a38_home5=$(mktemp -d); a38_repo5=$(mktemp -d); mkdir -p "$a38_repo5/knowledge" "$a38_home5/.claude/toolbox-knowledge"
a38_src5="$a38_repo5/knowledge/toolbox-lessons.yml"
emit_lessons_header "$a38_src5"
emit_lesson "$a38_src5" "TL-D501" normal 200 1
printf 'TL-STALE-GHOST\thigh\tactive\t9\t999\tevicted\n#END\n' > "$a38_home5/.claude/toolbox-knowledge/lessons-decisions.tsv"
a38_shim5=$(mktemp -d)
printf '#!/usr/bin/env bash\nexit 1\n' > "$a38_shim5/python3"; chmod +x "$a38_shim5/python3"
A38_RC5=0
A38_OUT5=$(PATH="$a38_shim5:$PATH" HOME="$a38_home5" SOURCE_OVERRIDE="$a38_src5" \
  bash "$SYNC_SCRIPT" --quiet 2>&1) || A38_RC5=$?
if grep -q 'TL-STALE-GHOST' <<<"$A38_OUT5"; then
  A38_FAILURES+=("leg 5: the run reported TL-STALE-GHOST, an id that exists only in a manifest planted before it started — a durable record that is not cleared first lets a previous run's verdicts be reported as this one's: $A38_OUT5")
fi
if [[ -f "$a38_home5/.claude/toolbox-knowledge/lessons-decisions.tsv" ]] && \
   grep -q 'TL-STALE-GHOST' "$a38_home5/.claude/toolbox-knowledge/lessons-decisions.tsv"; then
  A38_FAILURES+=("leg 5: the stale manifest is still on disk after a failed run, so the NEXT run would read it as its own")
fi
rm -rf "$a38_home5" "$a38_repo5" "$a38_shim5"

if [[ ${#A38_FAILURES[@]} -eq 0 ]]; then
  pass_test "$TC (the manifest survived the script's exit with a #END sentinel, carried one row per lesson block with the resolved priority and status, marked the two high lessons kept and the ordinary one evicted, recorded the superseded block as excluded rather than evicted, and a manifest planted before the run was neither reported nor left behind)"
else
  fail_test "$TC" "$(printf '%s; ' "${A38_FAILURES[@]}")"
fi

# ---------------------------------------------------------------------------
# TC-STL-39: a capping pass that fails AFTER writing must not hide the eviction.
#
# WHY (issue #151 P0-1): python wrote the fast tier BEFORE it wrote its manifest,
# so a pass that then exited non-zero left a truncated file that fast_tier_fallback
# found, called a prior capped tier and preserved — while the whole eviction
# report was skipped, because it sat in the `else` of the failure test. Measured
# on a FRESH HOME with no prior tier in existence: exit 0, 2 of 3 high lessons
# present, zero eviction lines on stderr, and a stderr message claiming to
# preserve something that had never existed.
#
# The fix has two halves and this test has a leg for each: the manifest is moved
# into place BEFORE the fast tier (so a recorded run can still be reported), and
# any pre-existing tier is snapshotted up front (so "prior" is known rather than
# inferred from a file being present).
#
#   A  the pass records, then fails -> the eviction is still reported, exit 4
#   B  the record is lost and the pass fails -> the run says the file is its own
#      output, not a prior tier, and escalates rather than reporting success
#   C  (CONTROL — green both before and after) a genuine prior tier with a pass
#      that fails before doing anything IS preserved verbatim, at exit 0. Without
#      it, leg B is satisfiable by deleting the preserve branch outright, which
#      would clobber good packs on every degraded run.
#
# FALSIFYING EDITS, applied and measured:
#   put the eviction report back inside the `else` of the PYTHON_RC test
#     -> leg A red, and TC-STL-41 leg 1 red with it
#   restore `[[ -f "$FAST_DEST" ]]` as the FIRST fallback branch
#     -> leg B red, and nothing else moves
#
# ⛔ ONE EDIT THAT LOOKS LIKE IT SHOULD FALSIFY LEG A DOES NOT. ⛔ Moving the
# fast-tier write back ahead of the manifest write reds NOTHING in this suite —
# because the shim here lets the real pass finish before it exits non-zero, so
# both files land whichever order they are written in. The write order buys
# something narrower: it bounds what a pass killed PART WAY THROUGH can leave
# behind. What leg A actually holds is the restructure — the report reading the
# manifest whenever one exists, instead of only when the pass exited 0.
# ---------------------------------------------------------------------------
TC="TC-STL-39: a post-write capping failure still reports the eviction (executed)"
A39_FAILURES=()
a39_realpy=$(command -v python3 || true)
if [[ -z "$a39_realpy" ]]; then
  fail_test "$TC" "no python3 on PATH, cannot build the post-write failure shims"
else
  # --- Leg A: the pass writes everything, THEN exits non-zero ---------------
  a39_shim=$(mktemp -d)
  printf '#!/usr/bin/env bash\n%s "$@"\nexit 1\n' "$a39_realpy" > "$a39_shim/python3"
  chmod +x "$a39_shim/python3"
  a39_home=$(mktemp -d); a39_repo=$(mktemp -d); mkdir -p "$a39_repo/knowledge"
  a39_src="$a39_repo/knowledge/toolbox-lessons.yml"
  emit_lessons_header "$a39_src"
  emit_lesson "$a39_src" "TL-P001" high 3000 9
  emit_lesson "$a39_src" "TL-P002" high 3000 8
  emit_lesson "$a39_src" "TL-P003" high 3000 7
  A39_RC=0
  A39_OUT=$(PATH="$a39_shim:$PATH" HOME="$a39_home" SOURCE_OVERRIDE="$a39_src" \
    bash "$SYNC_SCRIPT" --quiet 2>&1) || A39_RC=$?
  a39_kept=$(grep -c '^  - id:' "$a39_home/.claude/toolbox-knowledge/lessons.yml" 2>/dev/null || echo 0)
  # Precondition: the fixture must saturate, or there is no eviction to hide.
  if [[ "$a39_kept" -ne 2 ]]; then
    A39_FAILURES+=("leg A precondition: the fast tier holds $a39_kept lesson(s), expected 2 of 3 — the fixture did not saturate the cap, so nothing was evicted and this leg proves nothing: $A39_OUT")
  fi
  if ! grep -q 'TL-P003' <<<"$A39_OUT"; then
    A39_FAILURES+=("leg A: the pass recorded its decisions and then exited non-zero, and the evicted priority:high lesson TL-P003 was not named — a report the script already has in hand must not be discarded because the process that produced it died afterwards: $A39_OUT")
  fi
  if [[ "$A39_RC" -ne 4 ]]; then
    A39_FAILURES+=("leg A: sync exited $A39_RC after a post-record failure that evicted a priority:high lesson, expected 4 — both callers run this as '--quiet 2>/dev/null', so the exit code is the only surviving channel: $A39_OUT")
  fi
  rm -rf "$a39_home" "$a39_repo" "$a39_shim"

  # --- Leg B: the record is lost as well, on a HOME with no prior tier ------
  # The shim removes the manifest ($5) after the real pass has written both
  # files, which is the state the old code described as "preserving existing
  # capped fast tier" on a HOME where no tier had ever existed.
  a39_shim2=$(mktemp -d)
  printf '#!/usr/bin/env bash\n%s "$@"\nrm -f "$5"\nexit 1\n' "$a39_realpy" > "$a39_shim2/python3"
  chmod +x "$a39_shim2/python3"
  a39_home2=$(mktemp -d); a39_repo2=$(mktemp -d); mkdir -p "$a39_repo2/knowledge"
  a39_src2="$a39_repo2/knowledge/toolbox-lessons.yml"
  emit_lessons_header "$a39_src2"
  emit_lesson "$a39_src2" "TL-P101" high 3000 9
  emit_lesson "$a39_src2" "TL-P102" high 3000 8
  emit_lesson "$a39_src2" "TL-P103" high 3000 7
  A39_RC2=0
  A39_OUT2=$(PATH="$a39_shim2:$PATH" HOME="$a39_home2" SOURCE_OVERRIDE="$a39_src2" \
    bash "$SYNC_SCRIPT" --quiet 2>&1) || A39_RC2=$?
  if [[ "$A39_RC2" -ne 4 ]]; then
    A39_FAILURES+=("leg B: sync exited $A39_RC2 on a HOME with no prior fast tier, after a failed pass left its own truncated output behind — the run cannot confirm which lessons reached the tier, and reporting success over that is the silent drop this whole file exists to end: $A39_OUT2")
  fi
  if grep -qi 'preserving existing capped fast tier' <<<"$A39_OUT2"; then
    A39_FAILURES+=("leg B: the run claimed to preserve an EXISTING capped fast tier on a HOME where none had ever existed — the file it describes is its own output from the pass that just failed: $A39_OUT2")
  fi
  rm -rf "$a39_home2" "$a39_repo2" "$a39_shim2"

  # --- Leg C (CONTROL): a genuine prior tier is still preserved -------------
  # Green both before and after. It asserts nothing about the fix; its job is to
  # stop leg B being satisfied by removing the preserve branch, which would let
  # every degraded run replace a good pack with an empty one.
  a39_shim3=$(mktemp -d)
  printf '#!/usr/bin/env bash\nexit 1\n' > "$a39_shim3/python3"; chmod +x "$a39_shim3/python3"
  a39_home3=$(mktemp -d); a39_repo3=$(mktemp -d)
  mkdir -p "$a39_repo3/knowledge" "$a39_home3/.claude/toolbox-knowledge"
  a39_src3="$a39_repo3/knowledge/toolbox-lessons.yml"
  emit_lessons_header "$a39_src3"
  emit_lesson "$a39_src3" "TL-P201" normal 200 1
  printf 'schema_version: 1\nlessons:\n  - id: TL-PRIOR\n    lesson: "from an earlier successful run"\n' \
    > "$a39_home3/.claude/toolbox-knowledge/lessons.yml"
  A39_RC3=0
  A39_OUT3=$(PATH="$a39_shim3:$PATH" HOME="$a39_home3" SOURCE_OVERRIDE="$a39_src3" \
    bash "$SYNC_SCRIPT" --quiet 2>&1) || A39_RC3=$?
  if ! grep -q 'TL-PRIOR' "$a39_home3/.claude/toolbox-knowledge/lessons.yml" 2>/dev/null; then
    A39_FAILURES+=("leg C (control): a fast tier built by an earlier successful run was destroyed by a degraded one — stale advisory lessons beat none, and clobbering a good pack is strictly worse than serving it: $A39_OUT3")
  fi
  if [[ "$A39_RC3" -ne 0 ]]; then
    A39_FAILURES+=("leg C (control): preserving a genuine prior capped tier exited $A39_RC3, expected 0 — that branch is the documented graceful degradation and must not start warning on every python-less host: $A39_OUT3")
  fi
  rm -rf "$a39_home3" "$a39_repo3" "$a39_shim3"

  if [[ ${#A39_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (a pass that recorded its decisions and then failed still named the evicted priority:high lesson and exited 4; one that also lost the record refused to call its own output a prior capped tier and escalated instead; and a genuine prior tier was still preserved verbatim at exit 0)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A39_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-40: a `status:` whose value sits on the next line must not blind the
# guards.
#
# WHY (issue #151 P0-2): the counts the guards compare used to come from a grep
# over the SOURCE YAML — `^[[:space:]]*status:[[:space:]]*.\?active` — which
# cannot see a value on the following line, while the generator's `\s+` reads
# straight through it. So SRC_ACTIVE came back 0 on a perfectly valid file and
# `elif [[ FAST_KEPT -lt SRC_ACTIVE ]]`, the guard written precisely to catch a
# truncated manifest, could never fire. Measured: exit 0, 2 of 3 kept, zero
# stderr lines. Completely silent.
#
# Legs 1 and 2 read the same property from two angles, and both were RED before:
#   1  with the manifest unavailable, the multiline-status source still escalates
#      and says why (the guard the input used to defeat)
#   2  on the ordinary path the reported active COUNT is 3, not 0 — proof the
#      number comes from the pass's resolved status and not from a source grep
#   3  (CONTROL — green both ways) the same shape with single-line statuses also
#      reports 3, so leg 2 cannot be satisfied by hardcoding
#
# FALSIFYING EDIT, applied and measured: derive SRC_ACTIVE from a grep over
# "$SRC" again and leg 2 goes red — it reports "of 0 active lesson(s)" for a
# three-lesson file — while nothing else in the suite moves.
#
# ⛔ LEG 1 DOES NOT GO RED ON THAT EDIT, AND IT IS NOT MEANT TO. ⛔ Leg 1 is red
# against the PREVIOUS script, where the missing-manifest branch was gated on
# `FAST_KEPT -lt SRC_ACTIVE` and a wrong SRC_ACTIVE made it unreachable. The
# branch no longer computes SRC_ACTIVE at all — with no manifest it reports the
# unknown rather than guessing at a count — so reintroducing the grep cannot
# reach it. Leg 1 holds the escalation; leg 2 holds where the count comes from.
# ---------------------------------------------------------------------------
TC="TC-STL-40: a multiline status value does not blind the empty/eviction guards (executed)"
A40_FAILURES=()

# a40_build <dest> <M|I> [count] — `count` ~3 KB high lessons, defaulting to 3,
# which saturates the 8 KB cap. `M` writes each status value on the line AFTER
# the key; `I` writes it inline. Nothing else differs.
a40_build() {
  local dest="$1" mode="$2" n="${3:-3}" i pad
  pad=$(printf '%*s' 3000 "" | tr ' ' 'w')
  emit_lessons_header "$dest"
  for i in $(seq 1 "$n"); do
    {
      printf '  - id: TL-S%s%s\n' "$mode" "$i"
      printf '    lesson: "Body %s"\n' "$pad"
      printf '    guidance: "g"\n'
      printf '    priority: high\n'
      printf '    occurrences: %s\n' "$i"
      if [[ "$mode" == "M" ]]; then printf '    status:\n      active\n'; else printf '    status: "active"\n'; fi
    } >> "$dest"
  done
}

# --- Leg 1: manifest unavailable + multiline status -> must still escalate ---
a40_realpy=$(command -v python3 || true)
if [[ -z "$a40_realpy" ]]; then
  A40_FAILURES+=("leg 1: no python3 on PATH, cannot build the argument-dropping shim")
else
  a40_shim=$(mktemp -d)
  printf '#!/usr/bin/env bash\nexec %s "$1" "$2" "$3" "$4"\n' "$a40_realpy" > "$a40_shim/python3"
  chmod +x "$a40_shim/python3"
  a40_home=$(mktemp -d); a40_repo=$(mktemp -d); mkdir -p "$a40_repo/knowledge"
  a40_src="$a40_repo/knowledge/toolbox-lessons.yml"
  a40_build "$a40_src" M
  A40_RC=0
  A40_OUT=$(PATH="$a40_shim:$PATH" HOME="$a40_home" SOURCE_OVERRIDE="$a40_src" \
    bash "$SYNC_SCRIPT" --quiet 2>&1) || A40_RC=$?
  a40_kept=$(grep -c '^  - id:' "$a40_home/.claude/toolbox-knowledge/lessons.yml" 2>/dev/null || echo 0)
  if [[ "$a40_kept" -ne 2 ]]; then
    A40_FAILURES+=("leg 1 precondition: the fast tier holds $a40_kept lesson(s), expected 2 of 3 — the multiline-status fixture did not saturate, so no lesson went missing and the guard was never the thing under test: $A40_OUT")
  fi
  if [[ "$A40_RC" -ne 4 ]]; then
    A40_FAILURES+=("leg 1: sync exited $A40_RC on a source whose statuses are written across two lines, with the manifest unavailable — it kept $a40_kept of 3 and cannot prove none of the missing ones was priority:high, so it must escalate; exiting 0 here is the exact silence issue #151 P0-2 reported: $A40_OUT")
  fi
  if ! grep -qi 'manifest' <<<"$A40_OUT"; then
    A40_FAILURES+=("leg 1: nothing in the output names the missing manifest, so a developer seeing exit 4 cannot tell an unreadable report from a real high eviction: $A40_OUT")
  fi
  rm -rf "$a40_home" "$a40_repo" "$a40_shim"
fi

# --- Leg 2: the reported active count comes from the pass, not from a grep ---
# Run WITHOUT --quiet: the count lives on the info line, which --quiet suppresses.
a40_home2=$(mktemp -d); a40_repo2=$(mktemp -d); mkdir -p "$a40_repo2/knowledge"
a40_src2="$a40_repo2/knowledge/toolbox-lessons.yml"
a40_build "$a40_src2" M
A40_RC2=0
A40_OUT2=$(HOME="$a40_home2" SOURCE_OVERRIDE="$a40_src2" bash "$SYNC_SCRIPT" 2>&1) || A40_RC2=$?
if ! grep -q 'of 3 active lesson' <<<"$A40_OUT2"; then
  A40_FAILURES+=("leg 2: the run did not report 3 active lessons for a three-lesson source whose statuses are written across two lines — the count is still being re-derived from the YAML rather than read from the pass's own resolution, which is what made the guard inert: $A40_OUT2")
fi
rm -rf "$a40_home2" "$a40_repo2"

# --- Leg 3 (CONTROL): a DIFFERENT count, with single-line statuses ----------
# Green both before and after. Its job is to stop leg 2 passing on a hardcoded 3.
# The contrast is deliberately the LESSON COUNT and not the status spelling: two
# inline lessons must report "of 2", so a constant cannot satisfy both legs, and
# the check needs no pattern of its own over the fixture's YAML. (Asserting the
# inline fixture's shape by grepping `status:` would put a second reader of a
# lessons file back into this suite for no gain — the very thing the
# single-parser change removed.)
a40_home3=$(mktemp -d); a40_repo3=$(mktemp -d); mkdir -p "$a40_repo3/knowledge"
a40_src3="$a40_repo3/knowledge/toolbox-lessons.yml"
a40_build "$a40_src3" I 2
A40_RC3=0
A40_OUT3=$(HOME="$a40_home3" SOURCE_OVERRIDE="$a40_src3" bash "$SYNC_SCRIPT" 2>&1) || A40_RC3=$?
if ! grep -q 'of 2 active lesson' <<<"$A40_OUT3"; then
  A40_FAILURES+=("leg 3 (control): a two-lesson source did not report 2 active lessons — if it reported 3, leg 2's number is a constant rather than the pass's own count and proves nothing: $A40_OUT3")
fi
rm -rf "$a40_home3" "$a40_repo3"

if [[ ${#A40_FAILURES[@]} -eq 0 ]]; then
  pass_test "$TC (a source whose status values sit on the following line escalated to 4 with the manifest unavailable and named the missing manifest, reported all 3 of its lessons as active on the ordinary path, and a two-lesson inline contrast fixture reported 2 — so the count tracks the input rather than a constant)"
else
  fail_test "$TC" "$(printf '%s; ' "${A40_FAILURES[@]}")"
fi

# ---------------------------------------------------------------------------
# TC-STL-41: exit 4 must not assert a HIGH eviction it cannot demonstrate.
#
# WHY: exit 4 has two causes — a lesson above ordinary priority really was pushed
# out, or the run could not confirm that none was. Only the first has a lesson to
# name. The escalation flag is raised by BOTH, so any message gated on the flag
# rather than on the named ids is false in the second case, and this branch
# creates a third way to reach it (a pass that recorded its decisions and then
# exited non-zero) in which every evicted lesson can be ordinary.
#
# Three legs:
#   1  ordinary-only evictions + a post-record failure -> exit 4, the evictions
#      ARE named, and the "priority above ordinary" claim is NOT made
#   2  (CONTROL — green both ways) a real high eviction DOES make that claim and
#      names the id, so leg 1 is not satisfiable by deleting the message
#   3  (source structure) the script's own exit-code documentation for 4 must
#      state the cannot-confirm cause rather than describing 4 as an eviction
#      outright — the header asserted the latter while the suite produced the
#      former
#
# FALSIFYING EDIT: gate the "Evicted with a priority above ordinary" warn on
# HIGH_EVICTED instead of on the collected ids — leg 1 red, leg 2 still green.
# ---------------------------------------------------------------------------
TC="TC-STL-41: exit 4 does not claim a HIGH eviction it cannot name (executed)"
A41_FAILURES=()
a41_claim='priority above ordinary'
a41_realpy=$(command -v python3 || true)
if [[ -z "$a41_realpy" ]]; then
  fail_test "$TC" "no python3 on PATH, cannot build the post-record failure shim"
else
  a41_shim=$(mktemp -d)
  printf '#!/usr/bin/env bash\n%s "$@"\nexit 1\n' "$a41_realpy" > "$a41_shim/python3"
  chmod +x "$a41_shim/python3"

  # --- Leg 1: nothing high anywhere, yet the run reaches exit 4 -------------
  a41_home=$(mktemp -d); a41_repo=$(mktemp -d); mkdir -p "$a41_repo/knowledge"
  a41_src="$a41_repo/knowledge/toolbox-lessons.yml"
  emit_lessons_header "$a41_src"
  emit_lesson "$a41_src" "TL-F001" normal 3000 9
  emit_lesson "$a41_src" "TL-F002" normal 3000 8
  emit_lesson "$a41_src" "TL-F003" normal 3000 7
  A41_RC=0
  A41_OUT=$(PATH="$a41_shim:$PATH" HOME="$a41_home" SOURCE_OVERRIDE="$a41_src" \
    bash "$SYNC_SCRIPT" --quiet 2>&1) || A41_RC=$?
  if [[ "$A41_RC" -ne 4 ]]; then
    A41_FAILURES+=("leg 1 precondition: sync exited $A41_RC, expected 4 — this leg needs a state that escalates without any high lesson present, and without it the message under test never prints: $A41_OUT")
  fi
  if ! grep -q 'TL-F003' <<<"$A41_OUT"; then
    A41_FAILURES+=("leg 1: the evicted ordinary lesson TL-F003 was not named — every eviction is reported even when none escalates: $A41_OUT")
  fi
  if grep -qi "$a41_claim" <<<"$A41_OUT"; then
    A41_FAILURES+=("leg 1: the run asserted that something above ordinary priority was evicted, on a source where every lesson is ordinary — the claim is gated on the escalation flag rather than on an actually-named id, and it sends the developer hunting a severe eviction that did not happen: $A41_OUT")
  fi
  rm -rf "$a41_home" "$a41_repo"

  # --- Leg 2 (CONTROL): a real high eviction still says so ------------------
  # Green both before and after; it exists so leg 1 cannot be satisfied by
  # removing the warning altogether, which would restore the original silence.
  a41_home2=$(mktemp -d); a41_repo2=$(mktemp -d); mkdir -p "$a41_repo2/knowledge"
  a41_src2="$a41_repo2/knowledge/toolbox-lessons.yml"
  emit_lessons_header "$a41_src2"
  emit_lesson "$a41_src2" "TL-F101" high 3000 9
  emit_lesson "$a41_src2" "TL-F102" high 3000 8
  emit_lesson "$a41_src2" "TL-F103" high 3000 7
  A41_RC2=0
  A41_OUT2=$(HOME="$a41_home2" SOURCE_OVERRIDE="$a41_src2" bash "$SYNC_SCRIPT" --quiet 2>&1) || A41_RC2=$?
  if ! grep -qi "$a41_claim" <<<"$A41_OUT2"; then
    A41_FAILURES+=("leg 2 (control): a priority:high lesson really was evicted and the run did not say so — leg 1 must constrain the message, not delete it: $A41_OUT2")
  fi
  if ! grep -q 'TL-F103' <<<"$A41_OUT2"; then
    A41_FAILURES+=("leg 2 (control): the escalating lesson TL-F103 was not named alongside the claim: $A41_OUT2")
  fi
  rm -rf "$a41_home2" "$a41_repo2" "$a41_shim"
fi

# --- Leg 3 (source structure): the exit-code documentation ------------------
# ⛔ This leg reads COMMENT text on purpose, and says so. ⛔ The exit-code block
# at the top of the sync script is the contract callers are written against, and
# item D of issue #151 is that it described 4 as "at least one priority: high
# lesson was EVICTED" while leg 1 above reaches 4 with no high lesson in the
# source at all. There is no runtime artifact for a header comment, so this is
# the only place it can be pinned.
a41_doc4=$(awk '/^#   4  /{inb=1} inb{print} inb && /^#   Callers/{exit}' "$SYNC_SCRIPT")
if [[ -z "$a41_doc4" ]]; then
  A41_FAILURES+=("leg 3: could not locate the exit-code 4 documentation block in $SYNC_SCRIPT — the block shape changed and this assertion can no longer see it")
elif ! grep -qi 'confirm' <<<"$a41_doc4"; then
  A41_FAILURES+=("leg 3: the exit-4 documentation does not mention that the code also covers a run that could not CONFIRM whether a high lesson was evicted. Leg 1 reaches exit 4 with no high lesson present, so documenting 4 as an eviction outright is false in a state this very suite produces: $a41_doc4")
fi

if [[ ${#A41_FAILURES[@]} -eq 0 ]]; then
  pass_test "$TC (a run that escalated with every evicted lesson ordinary named them without claiming a severe eviction; a run that really did evict a priority:high lesson still made the claim and named it; and the exit-code documentation states the cannot-confirm cause rather than asserting an eviction)"
else
  fail_test "$TC" "$(printf '%s; ' "${A41_FAILURES[@]}")"
fi

# ---------------------------------------------------------------------------
# TC-STL-42: the THIRD exit-4 cause is documented, and the sentinel must be the
# manifest's LAST record rather than merely present somewhere in it.
#
# WHY: exit 4 has THREE causes, not the two the header documented. Besides (a) a
# lesson above ordinary priority evicted at the cap and (b) a missing/truncated
# manifest, there is (c) a capping pass that recorded its decisions COMPLETELY and
# then exited non-zero. Path (c) is reachable with every evicted lesson ordinary,
# and — unlike (b) — it DOES name the evicted lessons, because the manifest it is
# escalating about is right there and readable. Two claims written in this branch
# are therefore false on that path: the header's "That has two causes", and
# commands/review-pr.md's "In those states no lesson is named because none can be".
# Both are the guard-prose-overclaims class (TL-0019) that issue #151 says has now
# recurred five times in this file, so they are pinned here rather than argued.
#
# The sentinel legs pin a separate weakness in the same record: `grep -q '^#END$'`
# accepts the sentinel ANYWHERE, so a manifest whose rows follow its `#END` reads
# as complete. The whole point of the sentinel is to distinguish a complete record
# from a truncated one, and a check that ignores POSITION cannot do that — a
# generator that emitted the sentinel first would keep every existing assertion
# green while shipping rows nothing should have trusted.
# ---------------------------------------------------------------------------
TC="TC-STL-42: exit 4 documents its third cause and the sentinel must terminate the manifest (executed)"
A42_FAILURES=()

# --- Leg 1 (SOURCE STRUCTURE): the header documents the post-write cause ----
# ⛔ Reads COMMENT text on purpose. ⛔ The exit-code block is the contract callers
# are written against and there is no runtime artifact for it, so this is the only
# place it can be pinned — the same reasoning as TC-STL-41 leg 3.
a42_doc4=$(awk '/^#   4  /{inb=1} inb{print} inb && /^#   Callers/{exit}' "$SYNC_SCRIPT")
if [[ -z "$a42_doc4" ]]; then
  A42_FAILURES+=("leg 1: could not locate the exit-code 4 documentation block in $SYNC_SCRIPT — the block shape changed and this assertion can no longer see it")
else
  if grep -qi 'two causes' <<<"$a42_doc4"; then
    A42_FAILURES+=("leg 1: the exit-4 documentation still says 'two causes'. Leg 3 below reaches exit 4 by a THIRD route — a pass that recorded its decisions in full and then exited non-zero — so the enumeration is incomplete in a state this suite produces: $a42_doc4")
  fi
  # The third cause must be ENUMERATED and DESCRIBED, not merely counted
  # differently. Checked as "a third lettered item exists" plus "it names the
  # trait that defines it" (the pass exited non-zero after its record was
  # complete) rather than as a fixed phrase, so a rewording of the prose cannot
  # fail this leg while a dropped cause still does.
  if ! grep -qE '^#        c\.' <<<"$a42_doc4"; then
    A42_FAILURES+=("leg 1: the exit-4 documentation has no third enumerated cause. Leg 3 and TC-STL-39 both reach exit 4 via a pass that recorded its decisions in full and then exited non-zero, which is neither (a) an eviction at the cap nor (b) an unusable manifest: $a42_doc4")
  elif ! grep -qi 'non-zero' <<<"$a42_doc4"; then
    A42_FAILURES+=("leg 1: the exit-4 documentation enumerates a third cause but never says what distinguishes it — that the capping pass exited NON-ZERO after its record was already complete. Without that, a reader cannot tell case (c), which names every eviction, from case (b), which can name none: $a42_doc4")
  fi
fi

# --- Leg 2 (SOURCE STRUCTURE): review-pr.md must not claim nothing is named -
# The caller-facing prose in commands/review-pr.md tells the developer how to read
# exit 4. It asserted that in every cannot-confirm state "no lesson is named
# because none can be" — which is exactly backwards on the post-write path, where
# the manifest is complete and every eviction IS named.
a42_reviewpr="$SCRIPT_DIR/../commands/review-pr.md"
if [[ ! -f "$a42_reviewpr" ]]; then
  A42_FAILURES+=("leg 2: $a42_reviewpr not found — the caller-facing exit-4 prose cannot be checked")
elif grep -qi 'no lesson is named because none can be' "$a42_reviewpr"; then
  A42_FAILURES+=("leg 2: commands/review-pr.md still says 'no lesson is named because none can be' about the cannot-confirm states. Leg 3 reaches exit 4 with a COMPLETE manifest and the evicted lesson named on stderr, so the claim is false on the very path the same sentence lists ('the capping pass failed after recording it')")
fi

# --- Leg 3 (EXECUTED): a non-terminal #END must NOT be trusted --------------
# Build a manifest whose sentinel precedes its rows. If the reader only asks
# "does #END appear", this file reads as a complete record and its rows are
# consumed; if the reader requires the sentinel to TERMINATE the file, the run
# falls to the cannot-confirm branch and says so.
a42_realpy=$(command -v python3 || true)
if [[ -z "$a42_realpy" ]]; then
  A42_FAILURES+=("leg 3: no python3 on PATH, cannot build the sentinel-reordering shim")
else
  a42_shim=$(mktemp -d)
  # Run the real pass, then REWRITE the manifest so #END sits before the rows.
  # Argument 4 is the manifest path the sync passes in (argv[5] of the real call).
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s "$@"\n' "$a42_realpy"
    printf 'rc=$?\n'
    printf 'm="$5"\n'
    printf 'if [[ -n "$m" && -f "$m" ]]; then\n'
    printf '  { grep    "^#END$" "$m"; grep -v "^#END$" "$m"; } > "$m.reordered"\n'
    printf '  mv "$m.reordered" "$m"\n'
    printf 'fi\n'
    printf 'exit $rc\n'
  } > "$a42_shim/python3"
  chmod +x "$a42_shim/python3"

  a42_home=$(mktemp -d); a42_repo=$(mktemp -d); mkdir -p "$a42_repo/knowledge"
  a42_src="$a42_repo/knowledge/toolbox-lessons.yml"
  emit_lessons_header "$a42_src"
  emit_lesson "$a42_src" "TL-W001" high 3000 9
  emit_lesson "$a42_src" "TL-W002" high 3000 8
  emit_lesson "$a42_src" "TL-W003" high 3000 7
  A42_RC=0
  A42_OUT=$(PATH="$a42_shim:$PATH" HOME="$a42_home" SOURCE_OVERRIDE="$a42_src" \
    bash "$SYNC_SCRIPT" --quiet 2>&1) || A42_RC=$?
  a42_manifest="$a42_home/.claude/toolbox-knowledge/lessons-decisions.tsv"
  # Precondition: the shim really did move the sentinel off the last line.
  a42_last=$(awk 'NF{l=$0} END{print l}' "$a42_manifest" 2>/dev/null || true)
  if [[ "$a42_last" == "#END" ]]; then
    A42_FAILURES+=("leg 3 precondition: the manifest still ends with #END, so the shim did not reorder it and this leg proves nothing about sentinel position (last line: [$a42_last])")
  elif ! grep -q '^#END$' "$a42_manifest" 2>/dev/null; then
    A42_FAILURES+=("leg 3 precondition: the reordered manifest has no #END line at all — that is the ALREADY-COVERED missing-sentinel case, not the misplaced-sentinel case this leg is for")
  else
    # The manifest is misplaced-sentinel. The run must refuse to trust it.
    if ! grep -qi 'manifest' <<<"$A42_OUT"; then
      A42_FAILURES+=("leg 3: the sync consumed a manifest whose #END precedes its rows without saying a word about the record being unusable. 'Present somewhere' is not the sentinel's contract — it exists to mark the END of a complete record, so a reader that ignores position cannot tell a complete file from a truncated one: $A42_OUT")
    fi
    if [[ "$A42_RC" -ne 4 ]]; then
      A42_FAILURES+=("leg 3: sync exited $A42_RC on a manifest it cannot legitimately trust, expected 4 — a misplaced sentinel means the record's completeness is unproven, and the fail-toward-reporting default that covers every other unprovable state must cover this one too: $A42_OUT")
    fi
  fi
  rm -rf "$a42_home" "$a42_repo" "$a42_shim"
fi

# --- Leg 4 (CONTROL): a properly terminated manifest is still trusted -------
# ⛔ GREEN BOTH BEFORE AND AFTER — this is a CONTROL. ⛔ Its only job is to stop
# leg 3 being satisfied by rejecting every manifest: a well-formed record must
# still be read, its eviction still named, and its high escalation still made.
# Without this leg, "never trust the manifest" would pass leg 3 while destroying
# the entire reporting path the branch exists to build.
a42_home2=$(mktemp -d); a42_repo2=$(mktemp -d); mkdir -p "$a42_repo2/knowledge"
a42_src2="$a42_repo2/knowledge/toolbox-lessons.yml"
emit_lessons_header "$a42_src2"
emit_lesson "$a42_src2" "TL-W101" high 3000 9
emit_lesson "$a42_src2" "TL-W102" high 3000 8
emit_lesson "$a42_src2" "TL-W103" high 3000 7
A42_RC2=0
A42_OUT2=$(HOME="$a42_home2" SOURCE_OVERRIDE="$a42_src2" bash "$SYNC_SCRIPT" --quiet 2>&1) || A42_RC2=$?
a42_manifest2="$a42_home2/.claude/toolbox-knowledge/lessons-decisions.tsv"
a42_last2=$(awk 'NF{l=$0} END{print l}' "$a42_manifest2" 2>/dev/null || true)
if [[ "$a42_last2" != "#END" ]]; then
  A42_FAILURES+=("leg 4 (control): a healthy run did not terminate its manifest with #END (last line: [$a42_last2]) — leg 3's contract is unmeetable if the generator does not itself satisfy it")
fi
if ! grep -q 'evicted: TL-W103' <<<"$A42_OUT2"; then
  A42_FAILURES+=("leg 4 (control): a well-formed manifest's eviction was not read back and named — leg 3 must reject only MISPLACED sentinels, not disable manifest reading altogether: $A42_OUT2")
fi
if [[ "$A42_RC2" -ne 4 ]]; then
  A42_FAILURES+=("leg 4 (control): a genuine priority:high eviction exited $A42_RC2, expected 4 — the escalation path must survive leg 3's tightening: $A42_OUT2")
fi
rm -rf "$a42_home2" "$a42_repo2"

# --- Leg 5 (SOURCE STRUCTURE): the pack README must not overclaim -----------
# The README written into the pack directory said the manifest is "Rewritten on
# every sync". It is not: a missing or unreadable source exits BEFORE the
# `rm -f "$DECISION_MANIFEST"`, so a sentinel-terminated manifest from an earlier
# run survives verbatim. That is the right BEHAVIOUR (the tiers are left intact
# too, so record and pack stay mutually consistent) — it is the sentence that is
# wrong, and an unconditional claim about a file's freshness is precisely what
# sends the next reader trusting a stale one.
a42_readme_claim=$(code_text_in "$SYNC_SCRIPT" 'Rewritten on every sync' 2>/dev/null || true)
if [[ -n "$a42_readme_claim" ]]; then
  A42_FAILURES+=("leg 5: the pack README still claims the manifest is 'Rewritten on every sync'. A missing or unreadable source returns before the manifest is deleted, so a complete manifest from a PRIOR run outlives that sync unchanged: $a42_readme_claim")
fi
# The narrower retry of that same claim is false too: "a sync that reaches the
# capping pass writes a new one". A READABLE but undecodable source (a stray 0xFF
# byte) reaches the pass, which deletes the old manifest and then dies on decode
# before writing one — measured: exit 3, no manifest on disk. Banning the phrase
# is not enough on its own, so the positive pin below requires the README to
# actually SAY the record can be absent.
a42_readme_claim2=$(code_text_in "$SYNC_SCRIPT" 'reaches the capping pass writes' 2>/dev/null || true)
if [[ -n "$a42_readme_claim2" ]]; then
  A42_FAILURES+=("leg 5: the pack README still promises that a sync reaching the capping pass writes a new manifest. A readable-but-undecodable source reaches the pass, deletes the old record and dies before writing one — exit 3 with no manifest on disk: $a42_readme_claim2")
fi
if ! code_re_lines_in "$SYNC_SCRIPT" 'no record at all' | grep -q .; then
  A42_FAILURES+=("leg 5: the pack README never states that the pack can legitimately hold two tiers and NO decision record. Banning a false phrase does not make the replacement say anything true — this pins that the absent-record case is actually documented for whoever opens the directory")
fi

if [[ ${#A42_FAILURES[@]} -eq 0 ]]; then
  pass_test "$TC (the exit-4 documentation enumerates the post-write-failure cause instead of claiming two, review-pr.md no longer says nothing can be named on a path that names everything, a manifest whose #END precedes its rows was refused and escalated, a well-formed manifest was still read and its high eviction still named, and the pack README no longer claims an unconditional rewrite)"
else
  fail_test "$TC" "$(printf '%s; ' "${A42_FAILURES[@]}")"
fi

# ---------------------------------------------------------------------------
# TC-STL-43: tightening the sentinel check must not reject records the generator
# legitimately writes, must fail CLOSED when the reader itself breaks, and must
# not let an inherited environment variable pick the exit code.
#
# WHY: TC-STL-42 leg 3 tightened "is #END present" into "is #END the last record".
# That is a PREDICATE CHANGE, and a predicate change has two directions. Leg 3
# only pinned the under-match side (a misplaced sentinel must be refused). These
# legs pin the OVER-match side and the reader's own failure mode, which is where
# the first tightening actually broke something:
#
#   - the old `grep -q '^#END$'` MATCHED a `#END\r` line, and the awk replacement
#     does not — so on any platform whose python writes CRLF, every healthy sync
#     would silently start escalating to exit 4. Measured, not reasoned about:
#     grep said MATCH and awk said no-match on the identical two-line fixture.
#   - `grep -q` decided on its EXIT STATUS, so a broken grep failed closed. The
#     awk form decides on captured STDOUT, so an awk that prints `#END` and then
#     dies is trusted. Swapping a status test for a text test quietly moved the
#     failure direction from closed to open.
#   - `HIGH_EVICTED`/`EMPTY_FAST_TIER` are initialised INSIDE the python branch,
#     so on the python-absent path they are never reset and `${HIGH_EVICTED:-0}`
#     reads whatever the caller exported — an exit code chosen by the environment
#     rather than by the run.
# ---------------------------------------------------------------------------
TC="TC-STL-43: the sentinel check accepts CRLF, fails closed, and ignores the environment (executed)"
A43_FAILURES=()
a43_realpy=$(command -v python3 || true)
a43_realawk=$(command -v awk || true)

# --- Leg 1: a CRLF-terminated manifest is still a COMPLETE manifest ---------
# The generator's own record, byte-for-byte, with CRLF line endings — exactly
# what a python running on a CRLF platform produces. Nothing about it is
# truncated, so a run over a source that fits entirely must stay at exit 0.
if [[ -z "$a43_realpy" ]]; then
  A43_FAILURES+=("leg 1: no python3 on PATH, cannot build the CRLF shim")
else
  a43_shim=$(mktemp -d)
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s "$@"\n' "$a43_realpy"
    printf 'rc=$?\n'
    printf 'm="$5"\n'
    # Rewrite the manifest with CRLF endings, leaving content identical.
    printf 'if [[ -n "$m" && -f "$m" ]]; then\n'
    printf '  %s -c \x27import sys,io\np=sys.argv[1]\nd=open(p,"rb").read().replace(b"\\r\\n",b"\\n").replace(b"\\n",b"\\r\\n")\nopen(p,"wb").write(d)\x27 "$m"\n' "$a43_realpy"
    printf 'fi\n'
    printf 'exit $rc\n'
  } > "$a43_shim/python3"
  chmod +x "$a43_shim/python3"

  a43_home=$(mktemp -d); a43_repo=$(mktemp -d); mkdir -p "$a43_repo/knowledge"
  a43_src="$a43_repo/knowledge/toolbox-lessons.yml"
  emit_lessons_header "$a43_src"
  emit_lesson "$a43_src" "TL-C001" high 200 3
  emit_lesson "$a43_src" "TL-C002" normal 200 2
  A43_RC=0
  A43_OUT=$(PATH="$a43_shim:$PATH" HOME="$a43_home" SOURCE_OVERRIDE="$a43_src" \
    bash "$SYNC_SCRIPT" --quiet 2>&1) || A43_RC=$?
  a43_m="$a43_home/.claude/toolbox-knowledge/lessons-decisions.tsv"
  # Precondition: the shim really did produce CRLF.
  if ! grep -q $'\r' "$a43_m" 2>/dev/null; then
    A43_FAILURES+=("leg 1 precondition: the manifest has no CR bytes, so the shim did not rewrite it and this leg is not testing CRLF at all")
  elif [[ "$A43_RC" -ne 0 ]]; then
    A43_FAILURES+=("leg 1: a source that fits entirely exited $A43_RC with a CRLF-terminated manifest, expected 0. The record is COMPLETE — only its line endings differ — so rejecting it turns every healthy sync on a CRLF platform into a permanent cannot-confirm escalation. The predicate that replaced 'is #END present' with 'is #END last' must not also silently narrow which bytes count as the sentinel: $A43_OUT")
  fi
  rm -rf "$a43_home" "$a43_repo" "$a43_shim"
fi

# --- Leg 2: a reader that PRINTS the sentinel but dies must not be trusted --
# `grep -q` decided on exit status, so a broken grep failed closed. Deciding on
# captured stdout instead means a reader that emits the right text and then dies
# is believed. The manifest may be perfect; the point is that THIS RUN could not
# reliably read it, which is the same "cannot confirm" the missing-manifest
# branch exists for.
if [[ -z "$a43_realawk" ]]; then
  A43_FAILURES+=("leg 2: no awk on PATH, cannot build the failing-reader shim")
else
  a43_shim2=$(mktemp -d)
  {
    printf '#!/usr/bin/env bash\n'
    # Only the sentinel probe is sabotaged; every other awk in the script is
    # passed through untouched, so this leg isolates the reader under test.
    printf 'if [[ "$*" == *"NF{last=\\$0}"* ]]; then\n'
    printf '  %s "$@"\n' "$a43_realawk"
    printf '  exit 2\n'
    printf 'fi\n'
    printf 'exec %s "$@"\n' "$a43_realawk"
  } > "$a43_shim2/awk"
  chmod +x "$a43_shim2/awk"

  a43_home2=$(mktemp -d); a43_repo2=$(mktemp -d); mkdir -p "$a43_repo2/knowledge"
  a43_src2="$a43_repo2/knowledge/toolbox-lessons.yml"
  emit_lessons_header "$a43_src2"
  emit_lesson "$a43_src2" "TL-C101" high 200 3
  emit_lesson "$a43_src2" "TL-C102" normal 200 2
  A43_RC2=0
  A43_OUT2=$(PATH="$a43_shim2:$PATH" HOME="$a43_home2" SOURCE_OVERRIDE="$a43_src2" \
    bash "$SYNC_SCRIPT" --quiet 2>&1) || A43_RC2=$?
  if [[ "$A43_RC2" -ne 4 ]]; then
    A43_FAILURES+=("leg 2: the sentinel probe printed '#END' and then exited 2, and the sync exited $A43_RC2 (expected 4) — it believed a reader that demonstrably failed. A status test fails closed; a text test does not, and swapping one for the other must not move the failure direction: $A43_OUT2")
  fi
  rm -rf "$a43_home2" "$a43_repo2" "$a43_shim2"
fi

# --- Leg 3: an inherited HIGH_EVICTED must not choose the exit code ---------
# Both status variables are set inside the python branch, so the python-ABSENT
# path never resets them and the final `${HIGH_EVICTED:-0}` reads the caller's
# environment. That is a fourth route to exit 4, belonging to none of the three
# documented causes, and it is decided by something outside the run entirely.
# Same sanitized-PATH idiom TC-STL-6 uses: symlink in exactly the utilities the
# sync script needs and leave python3 out, so the run reaches the python-ABSENT
# fallback rather than dying at 127 on a missing coreutil.
a43_shim3keep=""
a43_shim3=$(mktemp -d)
for a43_util in bash sh env dirname pwd mkdir cp cat mktemp chmod rm cut date tr grep awk sed; do
  a43_up=$(command -v "$a43_util" 2>/dev/null || true)
  [[ -n "$a43_up" ]] && ln -sf "$a43_up" "$a43_shim3/$a43_util"
done
if PATH="$a43_shim3" command -v python3 >/dev/null 2>&1; then
  A43_FAILURES+=("leg 3 setup: python3 is still reachable via the sanitized PATH, so this leg would not exercise the python-absent fallback at all")
else
  a43_home3=$(mktemp -d); a43_repo3=$(mktemp -d); mkdir -p "$a43_repo3/knowledge"
  a43_src3="$a43_repo3/knowledge/toolbox-lessons.yml"
  emit_lessons_header "$a43_src3"
  emit_lesson "$a43_src3" "TL-C201" normal 200 2
  # Seed a prior capped fast tier so the fallback takes its PRESERVE branch,
  # which is the branch that legitimately exits 0.
  mkdir -p "$a43_home3/.claude/toolbox-knowledge"
  printf 'schema_version: 1\nlessons:\n  - id: "TL-C201"\n' > "$a43_home3/.claude/toolbox-knowledge/lessons.yml"
  A43_RC3=0
  A43_OUT3=$(PATH="$a43_shim3" HIGH_EVICTED=1 HOME="$a43_home3" SOURCE_OVERRIDE="$a43_src3" \
    "$a43_shim3/bash" "$SYNC_SCRIPT" --quiet 2>&1) || A43_RC3=$?
  if [[ "$A43_RC3" -ne 0 ]]; then
    A43_FAILURES+=("leg 3: with python3 absent and a prior capped fast tier preserved, the sync exited $A43_RC3 (expected 0) because HIGH_EVICTED=1 was inherited from the environment. Nothing about this run evicted anything; the status variables must be initialised before the python branch so the exit code describes the RUN and not the caller's shell: $A43_OUT3")
  fi
  rm -rf "$a43_home3" "$a43_repo3"
  # Leg 3b reuses this sanitized PATH, so the directory outlives this block and
  # is removed after that leg instead of here.
  a43_shim3keep="$a43_shim3"
fi

# --- Leg 4 (CONTROL): the env var must not be able to SUPPRESS an escalation -
# ⛔ GREEN BOTH BEFORE AND AFTER — this is a CONTROL. ⛔ Leg 3 could be satisfied
# by hard-coding the exit to 0 on the fallback path, which would destroy the real
# escalation. This pins the other direction: an inherited HIGH_EVICTED=0 must not
# stop a genuine high eviction from reaching exit 4.
a43_home4=$(mktemp -d); a43_repo4=$(mktemp -d); mkdir -p "$a43_repo4/knowledge"
a43_src4="$a43_repo4/knowledge/toolbox-lessons.yml"
emit_lessons_header "$a43_src4"
emit_lesson "$a43_src4" "TL-C301" high 3000 9
emit_lesson "$a43_src4" "TL-C302" high 3000 8
emit_lesson "$a43_src4" "TL-C303" high 3000 7
A43_RC4=0
A43_OUT4=$(HIGH_EVICTED=0 HOME="$a43_home4" SOURCE_OVERRIDE="$a43_src4" \
  bash "$SYNC_SCRIPT" --quiet 2>&1) || A43_RC4=$?
if [[ "$A43_RC4" -ne 4 ]]; then
  A43_FAILURES+=("leg 4 (control): a genuine priority:high eviction exited $A43_RC4 with HIGH_EVICTED=0 inherited, expected 4 — leg 3 must make the exit code independent of the environment, not pinned to the environment's value: $A43_OUT4")
fi
if ! grep -q 'TL-C303' <<<"$A43_OUT4"; then
  A43_FAILURES+=("leg 4 (control): the evicted high lesson was not named: $A43_OUT4")
fi
rm -rf "$a43_home4" "$a43_repo4"

# --- Leg 5 (SOURCE STRUCTURE): exit 4 must not promise a usable fast tier ---
# The header describes 4 as "pack written and usable". Cause (c) — the pass
# recorded its decisions and then failed — can leave NO fast tier at all: run on
# a fresh HOME with an all-superseded source and a pass that lands the manifest
# but not the tier, and the sync returns 4 with no lessons.yml on disk. Promising
# a usable pack there sends the reader past the one thing that is actually wrong.
a43_doc4=$(awk '/^#   4  /{inb=1} inb{print} inb && /^#   Callers/{exit}' "$SYNC_SCRIPT")
if [[ -z "$a43_doc4" ]]; then
  A43_FAILURES+=("leg 5: could not locate the exit-code 4 documentation block in $SYNC_SCRIPT")
elif grep -qi 'pack written and usable' <<<"$a43_doc4"; then
  A43_FAILURES+=("leg 5: the exit-4 documentation still promises the pack is 'written and usable'. Cause (c) is reachable with no fast tier on disk at all, so the promise is false in a state the script itself produces: $a43_doc4")
fi

# --- Leg 6 (SOURCE STRUCTURE): the callers enumerate all three causes -------
# TC-STL-42 pins the header and review-pr.md but never looks at install.sh or
# update.sh, so their warning blocks could be reverted to the old two-cause
# wording with the whole suite still green. These are the strings a developer
# actually sees at install time, so they are pinned where they live.
for a43_caller in "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/update.sh"; do
  if [[ ! -f "$a43_caller" ]]; then
    A43_FAILURES+=("leg 6: caller $a43_caller not found")
    continue
  fi
  if code_re_lines_in "$a43_caller" 'one of two things' | grep -q .; then
    A43_FAILURES+=("leg 6: $(basename "$a43_caller") still tells the developer exit 4 means 'one of two things'. There are three, and the third — a pass that recorded its decisions and then failed — NAMES its evictions, so a reader who only knows two will misread the output")
  fi
  if code_re_lines_in "$a43_caller" 'SEVERE eviction' | grep -q .; then
    A43_FAILURES+=("leg 6: $(basename "$a43_caller") still headlines exit 4 as a 'SEVERE eviction'. Two of the three causes are reachable with no high-priority lesson in the source at all, so the headline asserts something exit 4 does not prove")
  fi
done


# --- Leg 1b: a CRLF manifest must still REPORT, not just avoid escalating ----
# ⛔ THE HALF-FIX IS WORSE THAN NO FIX. ⛔ Leg 1 only asks that a CRLF record stop
# being rejected. Normalising the SENTINEL alone does exactly that — and then the
# data rows still carry their CR, so `$6` reads `evicted\r`, matches nothing, and
# the eviction report comes back empty. The run then exits 0 with a priority:high
# lesson missing and NOT ONE WORD said about it: strictly worse than the reject,
# which at least escalated. Measured: exit 0, fast tier holding 2 of 3, zero
# eviction lines, manifest column reading [evicted^M]. Leg 1 and this leg must
# both hold, or "accepts CRLF" means "reads the sentinel and nothing else".
if [[ -n "$a43_realpy" ]]; then
  a43_shimB=$(mktemp -d)
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s "$@"\n' "$a43_realpy"
    printf 'rc=$?\n'
    printf 'm="$5"\n'
    printf 'if [[ -n "$m" && -f "$m" ]]; then\n'
    printf '  %s -c \x27import sys\np=sys.argv[1]\nd=open(p,"rb").read().replace(b"\\r\\n",b"\\n").replace(b"\\n",b"\\r\\n")\nopen(p,"wb").write(d)\x27 "$m"\n' "$a43_realpy"
    printf 'fi\n'
    printf 'exit $rc\n'
  } > "$a43_shimB/python3"
  chmod +x "$a43_shimB/python3"

  a43_homeB=$(mktemp -d); a43_repoB=$(mktemp -d); mkdir -p "$a43_repoB/knowledge"
  a43_srcB="$a43_repoB/knowledge/toolbox-lessons.yml"
  emit_lessons_header "$a43_srcB"
  emit_lesson "$a43_srcB" "TL-C401" high 3000 9
  emit_lesson "$a43_srcB" "TL-C402" high 3000 8
  emit_lesson "$a43_srcB" "TL-C403" high 3000 7
  A43_RCB=0
  A43_OUTB=$(PATH="$a43_shimB:$PATH" HOME="$a43_homeB" SOURCE_OVERRIDE="$a43_srcB" \
    bash "$SYNC_SCRIPT" --quiet 2>&1) || A43_RCB=$?
  a43_mB="$a43_homeB/.claude/toolbox-knowledge/lessons-decisions.tsv"
  if ! grep -q $'\r' "$a43_mB" 2>/dev/null; then
    A43_FAILURES+=("leg 1b precondition: the manifest carries no CR bytes, so this leg is not exercising CRLF data rows")
  else
    if ! grep -q 'TL-C403' <<<"$A43_OUTB"; then
      A43_FAILURES+=("leg 1b: the evicted priority:high lesson TL-C403 was NOT named on a CRLF manifest. Normalising only the sentinel makes the record look complete while every data row still ends in CR, so \$6 reads 'evicted\\r', the eviction list comes back empty and the run reports nothing — a SILENT drop, which is worse than the rejection leg 1 removed: $A43_OUTB")
    fi
    if [[ "$A43_RCB" -ne 4 ]]; then
      A43_FAILURES+=("leg 1b: sync exited $A43_RCB on a CRLF manifest whose record shows a priority:high eviction, expected 4 — accepting the sentinel must not also mean discarding the rows it terminates: $A43_OUTB")
    fi
  fi
  rm -rf "$a43_homeB" "$a43_repoB" "$a43_shimB"
fi

# --- Leg 3b: EMPTY_FAST_TIER is inheritable too, and it outranks HIGH_EVICTED --
# Leg 3 pins only HIGH_EVICTED, but BOTH flags were moved, and EMPTY_FAST_TIER is
# the one that wins the precedence contest at the bottom of the script — so an
# inherited 3 overrides everything the run actually decided.
if [[ -d "$a43_shim3keep" ]]; then
  a43_home3b=$(mktemp -d); a43_repo3b=$(mktemp -d); mkdir -p "$a43_repo3b/knowledge"
  a43_src3b="$a43_repo3b/knowledge/toolbox-lessons.yml"
  emit_lessons_header "$a43_src3b"
  emit_lesson "$a43_src3b" "TL-C501" normal 200 2
  mkdir -p "$a43_home3b/.claude/toolbox-knowledge"
  printf 'schema_version: 1\nlessons:\n  - id: "TL-C501"\n' > "$a43_home3b/.claude/toolbox-knowledge/lessons.yml"
  A43_RC3B=0
  A43_OUT3B=$(PATH="$a43_shim3keep" EMPTY_FAST_TIER=3 HIGH_EVICTED=0 HOME="$a43_home3b" \
    SOURCE_OVERRIDE="$a43_src3b" "$a43_shim3keep/bash" "$SYNC_SCRIPT" --quiet 2>&1) || A43_RC3B=$?
  if [[ "$A43_RC3B" -ne 0 ]]; then
    A43_FAILURES+=("leg 3b: an inherited EMPTY_FAST_TIER=3 produced exit $A43_RC3B (expected 0) on the python-absent path. It is the flag that OUTRANKS HIGH_EVICTED in the final precedence, so leaving it uninitialised lets the environment assert 'agents read NOTHING' about a run that preserved a perfectly good tier: $A43_OUT3B")
  fi
  rm -rf "$a43_home3b" "$a43_repo3b"
fi

# --- Leg 7: the callers must not promise a usable pack either ---------------
# The header stopped promising it (leg 5), but both callers still printed "The
# pack is usable" unconditionally on exit 4 — and cause (c) reaches exit 4 with
# no fast tier on disk at all. Pinning the header alone left the strings the
# developer actually SEES saying the thing that was just removed as false.
for a43_caller2 in "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/update.sh"; do
  [[ -f "$a43_caller2" ]] || continue
  if code_re_lines_in "$a43_caller2" 'The pack is usable' | grep -q .; then
    A43_FAILURES+=("leg 7: $(basename "$a43_caller2") still tells the developer 'The pack is usable' on exit 4. A pass that lands its manifest and then dies before replacing the tier reaches exit 4 with NO lessons.yml on disk, so the sentence is false exactly when the developer most needs it to be true")
  fi
  # Positively pin the enumeration, rather than only banning the old phrasings:
  # a block reduced to "sync returned exit 4" would satisfy a ban but explain
  # nothing, which is the failure mode leg 6's negative checks cannot see.
  if ! code_re_lines_in "$a43_caller2" 'recorded its decisions' | grep -q .; then
    A43_FAILURES+=("leg 7: $(basename "$a43_caller2") never describes the third cause (a pass that recorded its decisions and then failed). Banning the old two-cause wording does not make the new wording say anything — this asserts the cause is actually explained")
  fi
done
rm -rf "$a43_shim3keep" 2>/dev/null || true

# --- Leg 8 (SOURCE STRUCTURE): the HARNESS's own reader obeys the same contract -
# ⛔ THE SUITE IS A READER TOO. ⛔ TC-STL-42 leg 3 tightened the sync's sentinel
# check to "the last non-empty line", and TC-STL-43 legs 1/1b/2 added CR
# normalisation and a reader-status requirement. `lesson_decisions()` — the helper
# TC-STL-34/36/37 read the generator's verdicts through — kept the ORIGINAL
# position-blind `grep -q '^#END$'` and no CR handling. That is a second reader of
# the same record diverging from the first, which is the exact defect class this
# whole branch exists to remove; it just happens to live in the harness rather
# than the script. A manifest with rows after a premature sentinel would be
# consumed as complete, and the callers would report green over rows nothing
# should have trusted (automated-review, PR #152).
# CODE lines only. The helper's own comment block explains the position-blind
# grep it replaced, and a check that reads comments would match that prose and
# fail forever on a correct implementation — the same false-positive shape the
# residual sweep in the PR body had to disclose.
a43_helper=$(awk '/^lesson_decisions\(\) \{/{inb=1} inb && !/^[[:space:]]*#/{print} inb && /^\}/{exit}' "$0")
if [[ -z "$a43_helper" ]]; then
  A43_FAILURES+=("leg 8: could not locate the lesson_decisions() helper in this file — its shape changed and this assertion can no longer see it")
else
  if grep -qE "grep -q .\^#END\\\$." <<<"$a43_helper"; then
    A43_FAILURES+=("leg 8: lesson_decisions() still validates the manifest with a position-blind 'grep -q ^#END\$'. The sync itself requires the sentinel to be the LAST non-empty line (TC-STL-42 leg 3); a harness that accepts it anywhere will read rows after a premature sentinel and report the invariant as holding: $a43_helper")
  fi
  if ! grep -q 'END{' <<<"$a43_helper"; then
    A43_FAILURES+=("leg 8: lesson_decisions() never inspects the manifest's LAST record. Banning the old grep is not enough — the helper has to apply the same terminal-sentinel rule the sync applies, or the two readers have simply diverged in a new way: $a43_helper")
  fi
  if ! grep -q 'sub(/\\r' <<<"$a43_helper"; then
    A43_FAILURES+=("leg 8: lesson_decisions() does not normalise a trailing CR. The sync's four readers do (TC-STL-43 legs 1/1b), so on a CRLF manifest the harness would read 'evicted\\r' in the disposition column, enumerate nothing, and every caller's loop body would silently never run: $a43_helper")
  fi
fi

# --- Leg 8b (EXECUTED): the harness emits no row the generator never wrote ---
# ⛔ BEHAVIOURAL, not lexical. ⛔ Legs 8/9/10 read source text, which pins the
# SHAPE of the fix but not its effect — a semantically different rewrite could
# satisfy them (Codex, PR #152). This leg runs the helper for real against a
# source with NO lesson blocks: the generator writes a header and `#END` and
# zero data rows, so the helper must emit NOTHING. It emitted a single newline —
# one empty "row" — because `printf '%s\n' ""` prints a newline regardless.
# Latent today (every caller strips or ignores it) but it is still a record the
# generator never wrote, arriving from the reader.
a43_home5=$(mktemp -d)
a43_src5="$a43_home5/no-lessons.yml"
printf 'schema_version: 1\nlessons: []\n' > "$a43_src5"
a43_bytes=$(lesson_decisions "$a43_src5" | wc -c | tr -d ' ')
if [[ "$a43_bytes" -ne 0 ]]; then
  A43_FAILURES+=("leg 8b: lesson_decisions() emitted $a43_bytes byte(s) for a source with no lesson blocks, expected 0. The manifest is a header plus #END with zero data rows, so the correct enumeration is empty; printing a bare newline invents a row the generator never wrote and leaves every caller to know to discard it")
fi
rm -rf "$a43_home5"

# --- Leg 9 (SOURCE STRUCTURE): EVERY path the trap reaps carries $RUN_TAG ----
# ⛔ A CLEANUP THAT UNDOES THE FIX IT CLEANS UP AFTER. ⛔ Giving a file in the
# SHARED pack directory a per-process name exists so two concurrent syncs stop
# colliding on it. Removing it on exit under any name a PEER also uses hands that
# straight back: whichever run finishes first deletes the other's live file.
#
# ⛔ THIS IS A POSITIVE INVARIANT, NOT A BLACKLIST OF SPELLINGS. ⛔ It used to be
# one: it banned the `*.tmp` GLOB and nothing else, so it stayed green while the
# trap removed `.lessons.yml.prior` — a fixed shared name, on the very file the
# prior-vs-own-output distinction rests on — and it would have stayed green for
# whatever fixed name came next. Both shared-name defects on this branch were
# found by review rather than by this leg, one at a time, each fix leaving the
# next one undetected. So the rule is stated the other way round: every operand
# the trap removes under $PACK_DIR must carry $RUN_TAG. A glob carries no
# $RUN_TAG and a fixed name carries no $RUN_TAG, so one assertion catches both,
# and any spelling nobody has thought of yet (automated-review + Codex, PR #152).
#
# MEASURED, not asserted: against the trap at 1d877c6 — which ended with
# "$PACK_DIR/.lessons.yml.prior" — the old `*.tmp` assertion passed and this one
# reports that operand. Against the trap here, both pass.
a43_trap=$(awk '/^trap /{print}' "$SYNC_SCRIPT")
if [[ -z "$a43_trap" ]]; then
  A43_FAILURES+=("leg 9: could not locate the EXIT trap in $SYNC_SCRIPT")
else
  # Every double-quoted operand under $PACK_DIR, minus the ones carrying the tag.
  a43_untagged=$(grep -oE '"\$PACK_DIR/[^"]*"' <<<"$a43_trap" | grep -v 'RUN_TAG' || true)
  if [[ -n "$a43_untagged" ]]; then
    A43_FAILURES+=("leg 9: the EXIT trap removes pack-directory path(s) carrying no \$RUN_TAG, so a peer sync sharing this HOME owns the same name and whichever run exits first destroys the other's live file: $(printf '%s ' $a43_untagged)-- full trap: $a43_trap")
  fi
fi

# --- Leg 10 (SOURCE STRUCTURE): the harness must not swallow a partial read --
# Leg 8 made lesson_decisions() check the exit status of the read that VALIDATES
# the sentinel. The read that EMITS the rows was left with a trailing `|| true`,
# so an awk that dies half way through hands the callers a partial decision list
# and no indication anything went wrong — TC-STL-34/36/37 would then enumerate a
# truncated set and report the invariant as holding. The helper already has the
# right answer for an unreadable manifest (a synthetic row that forces RED); a
# failed row read has to take that same path, not `|| true`.
if [[ -n "$a43_helper" ]]; then
  if grep -qE '!/\^#/.*\|\| true' <<<"$a43_helper"; then
    A43_FAILURES+=("leg 10: lesson_decisions() still ends its row-emitting awk with '|| true', converting a failed read into partial output that looks successful. A half-read manifest must fail toward RED like an unreadable one, not quietly shorten the enumeration: $a43_helper")
  fi
fi

# --- Leg 11 (EXECUTED): the prior-tier SNAPSHOT is per-run and its use guarded -
# ⛔ THE THIRD FIXED SHARED NAME IN THE PACK DIRECTORY. ⛔ The scratch temps were
# given a run tag (leg 9) but `.lessons.yml.prior` — the snapshot the whole
# prior-vs-own-output distinction rests on — was left on a fixed name AND deleted
# by the trap on a fixed name. So a peer run's exit removes a live run's snapshot,
# and `fast_tier_fallback` then runs `cp "$PRIOR_FAST" "$FAST_DEST"` on a file that
# is gone. The branch is gated on `[[ -n "$PRIOR_FAST" ]]` — a STRING test, not a
# file test — so `cp` fails and `set -euo pipefail` kills the script at exit 1,
# an undocumented code, on the degraded path that exists to keep lessons alive.
# Deterministic here: the python shim deletes the snapshot and then fails, which
# forces the fallback with the snapshot already gone.
if [[ -n "$a43_realpy" ]]; then
  a43_shimP=$(mktemp -d)
  {
    printf '#!/usr/bin/env bash\n'
    # Delete every prior-snapshot spelling in the pack dir, then fail so the
    # fallback runs. $4 is FAST_DEST, whose directory is the pack dir.
    printf 'd=$(dirname "$4")\n'
    printf 'rm -f "$d"/.lessons.yml*.prior\n'
    printf 'exit 1\n'
  } > "$a43_shimP/python3"
  chmod +x "$a43_shimP/python3"

  a43_homeP=$(mktemp -d); a43_repoP=$(mktemp -d); mkdir -p "$a43_repoP/knowledge" "$a43_homeP/.claude/toolbox-knowledge"
  a43_srcP="$a43_repoP/knowledge/toolbox-lessons.yml"
  emit_lessons_header "$a43_srcP"
  emit_lesson "$a43_srcP" "TL-P901" normal 200 2
  # A prior capped fast tier must exist, so PRIOR_FAST is taken and branch 1 runs.
  printf 'schema_version: 1\nlessons:\n  - id: "TL-PRIOR"\n' > "$a43_homeP/.claude/toolbox-knowledge/lessons.yml"
  A43_RCP=0
  A43_OUTP=$(PATH="$a43_shimP:$PATH" HOME="$a43_homeP" SOURCE_OVERRIDE="$a43_srcP" \
    bash "$SYNC_SCRIPT" --quiet 2>&1) || A43_RCP=$?
  if [[ "$A43_RCP" -eq 1 ]]; then
    A43_FAILURES+=("leg 11: the sync died at exit 1 when its prior-tier snapshot vanished before the fallback copied it. 1 is not one of this script's documented codes (0/3/4), nothing is printed, and the fallback is the path that exists to KEEP lessons when capping fails — so a peer run's cleanup turns a degraded-but-working sync into a silent crash: $A43_OUTP")
  fi
  if [[ ! -f "$a43_homeP/.claude/toolbox-knowledge/lessons.yml" ]]; then
    A43_FAILURES+=("leg 11: the fast tier is GONE after the snapshot vanished. Losing the prior tier is the one outcome fast_tier_fallback exists to prevent — a vanished snapshot must degrade to the next branch, not destroy the file: $A43_OUTP")
  fi
  rm -rf "$a43_homeP" "$a43_repoP" "$a43_shimP"
fi

# --- Leg 12 (SOURCE STRUCTURE): the snapshot name carries the run tag --------
# Leg 11 proves the crash is gone; this proves the SHARING is gone, which is what
# stops a peer deleting it in the first place. Both are needed: a guarded cp on a
# still-shared file is a silent degradation on every concurrent run.
if [[ -n "$a43_trap" ]]; then
  if grep -qE '\.lessons\.yml\.prior' <<<"$a43_trap"; then
    A43_FAILURES+=("leg 12: the EXIT trap still removes the prior-tier snapshot by its FIXED name '.lessons.yml.prior'. That is the same shared-name collision leg 9 removed from the scratch temps, on the one file the prior-vs-own-output distinction depends on: $a43_trap")
  fi
fi
# The CREATION site matters as much as the trap. Checking only the trap leaves the
# assignment free to go back to a fixed name — the trap would then delete nothing,
# leg 11's file guard would keep the run alive, and both legs would stay green
# while every concurrent run silently shared one snapshot again (Codex, PR #152).
a43_prior_set=$(code_text_in "$SYNC_SCRIPT" 'PRIOR_FAST="\$PACK_DIR' 2>/dev/null || true)
if [[ -z "$a43_prior_set" ]]; then
  A43_FAILURES+=("leg 12: could not find where PRIOR_FAST is assigned in $SYNC_SCRIPT — it moved and this assertion can no longer see it")
elif ! grep -q 'RUN_TAG' <<<"$a43_prior_set"; then
  A43_FAILURES+=("leg 12: the prior-tier snapshot is CREATED under a name that does not carry \$RUN_TAG, so concurrent runs share one file regardless of what the trap deletes: $a43_prior_set")
fi

# --- Leg 14 (SOURCE STRUCTURE): the record is read exactly ONCE --------------
# ⛔ ONE OPEN, ONE STATE. ⛔ Validating the run tag from one open and then counting
# rows from another leaves a gap a peer can swap the record into: this run
# validates its OWN tag, the peer replaces the file, and the counts and eviction
# rows that follow come from the peer's record — so the tag check passes and the
# report is still someone else's. The fix is not a tighter check, it is reading
# the file once and deriving every answer from that copy; the tag then means what
# it claims. Asserted structurally because the race has no deterministic hook: the
# manifest path may appear as a reader's INPUT at most once.
# ⛔ COUNT EVERY MENTION, DO NOT BLACKLIST COMMAND NAMES. ⛔ This matched
# `(awk|grep|sed|cat)…"$DECISION_MANIFEST"`, which a second open written as
# `$(< "$DECISION_MANIFEST")`, `head`, or `read <` slips past entirely —
# demonstrated: planting a bare `MANIFEST_RELOAD=$(< "$DECISION_MANIFEST")` left
# this leg green. That is the same blacklist shape leg 9 was rewritten out of one
# commit earlier. The invariant is positional, not lexical: the path may appear on
# exactly the lines that legitimately need it — the `rm -f` that clears a stale
# record, the ONE `cat` that loads it, and warning text that names it for the
# developer. Anything else is a second open, whatever command performs it.
# ⛔ COUNT OCCURRENCES, NOT LINES, AND CHECK EACH LINE. ⛔ Counting lines let a
# second open hide on a line that already had a sanctioned one:
# `warn "... $DECISION_MANIFEST"; SNEAK=$(cat "$DECISION_MANIFEST")` was one use
# and one allowed line, and the leg stayed green (automated-review, PR #152). Two rules
# now: no code line may name the record twice, and every line that names it must
# be sanctioned. The first is what makes the second's line-based matching sound.
# Counted WITHOUT requiring surrounding quotes: inside a warn string the variable
# appears bare (`warn "record at $DECISION_MANIFEST"`), so a quoted-only pattern
# saw one occurrence on a line that named the record twice and the sneak read
# beside it stayed invisible. The variable is the thing being counted, not one
# spelling of it.
a43_dbl=$(awk '!/^[[:space:]]*#/ { n = gsub(/\$DECISION_MANIFEST/, "&"); if (n > 1) c++ } END { print c+0 }' "$SYNC_SCRIPT")
if [[ "$a43_dbl" -gt 0 ]]; then
  A43_FAILURES+=("leg 14: $a43_dbl code line(s) name \$DECISION_MANIFEST more than once. A second open sharing a line with a sanctioned one is still a second open, and the per-line allowlist below cannot see it — so one line per mention is what makes that allowlist mean anything")
fi
a43_uses=$(code_re_lines_in "$SYNC_SCRIPT" '"\$DECISION_MANIFEST"' | wc -l | tr -d ' ')
# The sanctioned appearances, each of which is NOT a read of the contents by this
# script: the `rm -f` that clears a stale record, the argv that hands the PATH to
# the python pass, the `-f` existence test, the ONE `cat` that loads it, and
# `warn` text that names the file for the developer.
#
# ⛔ THE LIST HAS TO MATCH THE COMMENT ABOVE IT. ⛔ The first version of this
# sanctioned warning text in prose and then omitted it from the pattern, so a
# perfectly ordinary `warn "... $DECISION_MANIFEST ..."` would have failed the leg
# — a guard whose comment and code disagree, which is the class this whole branch
# keeps correcting (automated-review, PR #152). Demonstrated by planting one: the leg went
# red on a use its own comment calls legitimate.
# Every alternative must ALSO require the manifest path on the same line. A bare
# `warn "` matched every warning in the file and inflated the allowed count until
# the difference could never be positive — the leg accepted a planted `$(< …)`,
# a `head`, and a `sed` second open in a row. An allowlist that over-matches does
# not weaken a guard, it deletes it.
a43_allowed=$(code_re_lines_in "$SYNC_SCRIPT" '(rm -f "\$DECISION_MANIFEST"|python3 "\$PYTHON_TMPFILE"[^|]*"\$DECISION_MANIFEST"|\[\[ -f "\$DECISION_MANIFEST" \]\]|MANIFEST_TEXT=\$\(cat "\$DECISION_MANIFEST"|warn "[^|]*"\$DECISION_MANIFEST")' | wc -l | tr -d ' ')
if [[ "$(( a43_uses - a43_allowed ))" -gt 0 ]]; then
  A43_FAILURES+=("leg 14: \$DECISION_MANIFEST appears on $a43_uses code lines, of which only $a43_allowed are the sanctioned ones (the stale-record rm, the single cat that loads it, and warning text). The remainder is a second open — each one is a window for a concurrent sync to replace the record between two of this run's own checks, which is how the run tag can validate against THIS run while the rows describe a peer's. Read it once and derive every check from that copy")
fi

# --- Leg 13 (EXECUTED): a manifest from ANOTHER run must not be trusted ------
# ⛔ THE LAST SILENT PATH. ⛔ The manifest moved from a per-run mktemp file to a
# fixed shared path in the pack directory, which is what lets the CALLER read it
# after the script exits — but it also means a concurrent sync can replace it
# between this run's manifest write and its fast-tier write. This run then reads
# the PEER's verdicts, sees no eviction in them, and exits 0 with empty stderr
# while its own fast tier is missing an evicted `priority: high` lesson. That is
# the exact issue #144/#151 invariant this branch exists to close, and on
# origin/main it cannot happen at all (the manifest is mktemp, unclobberable), so
# it is a window this branch OPENED.
#
# Serialising the two runs needs a lock and stays out of scope. What must not
# stand is the SILENCE: a record this run did not write is a record it cannot
# confirm, and the fail-toward-reporting default that covers every other
# unprovable state has to cover this one. Deterministic here — the shim rewrites
# the manifest's run tag to a foreign value, which is exactly what a peer's
# rewrite looks like from this run's side.
if [[ -n "$a43_realpy" ]]; then
  a43_shimR=$(mktemp -d)
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s "$@"\n' "$a43_realpy"
    printf 'rc=$?\n'
    printf 'm="$5"\n'
    # Replace the WHOLE record with a complete, well-formed, sentinel-terminated
    # manifest from a peer run that evicted NOTHING — which is what this run would
    # actually find if a concurrent sync finished in the gap. Rewriting only the
    # `#run` line would leave THIS run's own eviction rows in place, so the
    # ordinary eviction report would still fire and the leg would pass at exit 4
    # whether or not the tag is ever compared. That tautology is precisely the
    # "green regardless" shape these legs are supposed to avoid.
    printf 'if [[ -n "$m" && -f "$m" ]]; then\n'
    printf '  printf \x27#run\\tFOREIGN-RUN-9999\\n#id\\tpriority\\tstatus\\toccurrences\\tbytes\\tdisposition\\nTL-PEER\\tnormal\\tactive\\t1\\t50\\tkept\\n#END\\n\x27 > "$m"\n'
    printf 'fi\n'
    printf 'exit $rc\n'
  } > "$a43_shimR/python3"
  chmod +x "$a43_shimR/python3"

  a43_homeR=$(mktemp -d); a43_repoR=$(mktemp -d); mkdir -p "$a43_repoR/knowledge"
  a43_srcR="$a43_repoR/knowledge/toolbox-lessons.yml"
  emit_lessons_header "$a43_srcR"
  emit_lesson "$a43_srcR" "TL-R901" high 3000 9
  emit_lesson "$a43_srcR" "TL-R902" high 3000 8
  emit_lesson "$a43_srcR" "TL-R903" high 3000 7
  A43_RCR=0
  A43_OUTR=$(PATH="$a43_shimR:$PATH" HOME="$a43_homeR" SOURCE_OVERRIDE="$a43_srcR" \
    bash "$SYNC_SCRIPT" --quiet 2>&1) || A43_RCR=$?
  a43_manR="$a43_homeR/.claude/toolbox-knowledge/lessons-decisions.tsv"
  if ! grep -q '^#run' "$a43_manR" 2>/dev/null; then
    A43_FAILURES+=("leg 13: the manifest carries no '#run' tag line at all, so this run has no way to tell its OWN record from a concurrent run's. The record lives at a fixed shared path precisely so the caller can read it after exit; that same choice is what lets a peer replace it mid-run")
  elif [[ "$A43_RCR" -ne 4 ]]; then
    A43_FAILURES+=("leg 13: the sync exited $A43_RCR while reading a manifest tagged to a DIFFERENT run, expected 4. Those verdicts describe a peer's fast tier, not this run's, so no eviction in them rules anything out — exiting 0 here reports success over an unread record, which is the silent drop the whole branch exists to end: $A43_OUTR")
  fi
  rm -rf "$a43_homeR" "$a43_repoR" "$a43_shimR"
fi

# --- Leg 13b (SOURCE STRUCTURE): the format notes describe the run tag -------
# Both places that document the record's shape enumerated its `#`-initial lines,
# and adding a third one without updating them leaves a reader who opens the pack
# directory with a format description that is now incomplete — the same
# docs-behind-code drift the exit-4 enumeration already had to be corrected for
# twice on this branch.
# Checked as TWO NAMED BLOCKS, not as a count of mentions. A count is satisfied by
# any two lines anywhere and would stay green while either specific description
# went stale — the inert-detector shape (TL-0002) these tests exist to prevent.
a43_fmt_block=$(awk '/^#   Format: TAB-separated/{inb=1} inb{print} inb && /^#   TSV is safe/{exit}' "$SYNC_SCRIPT")
if [[ -z "$a43_fmt_block" ]]; then
  A43_FAILURES+=("leg 13b: could not locate the file-header 'Format:' block in $SYNC_SCRIPT — it moved and this assertion can no longer see it")
elif ! grep -q '#run' <<<"$a43_fmt_block"; then
  A43_FAILURES+=("leg 13b: the file-header Format note enumerates the record's '#'-initial lines but never mentions the '#run' tag, so it describes a format the generator no longer writes: $a43_fmt_block")
fi
a43_rdm_block=$(awk '/^- .lessons-decisions\.tsv. — DECISION MANIFEST/{inb=1} inb{print} inb && /single source of truth/{exit}' "$SYNC_SCRIPT")
if [[ -z "$a43_rdm_block" ]]; then
  A43_FAILURES+=("leg 13b: could not locate the pack README's decision-manifest paragraph in $SYNC_SCRIPT — it moved and this assertion can no longer see it")
elif ! grep -q '#run' <<<"$a43_rdm_block"; then
  A43_FAILURES+=("leg 13b: the pack README's manifest paragraph enumerates the record's '#'-initial lines but never mentions the '#run' tag. That paragraph is what someone who opens the pack directory reads, and it would be describing a format that no longer exists: $a43_rdm_block")
fi

# --- Leg 15 (EXECUTED): a failing ROW reader degrades, it does not kill --------
# ⛔ THE FAIL-CLOSED GUARD HAS TO COVER EVERY READER, NOT THE FIRST TWO. ⛔ The
# sentinel probe and the tag probe capture their reader's exit status (legs 2 and
# 14); the three counts and the eviction extractor did not. Under `set -euo
# pipefail` a failing awk there kills the script at exit 2 — an undocumented code,
# no warning, before the cannot-confirm branch that exists for exactly this — so
# the same broken reader produces a clean degradation at one call site and a
# silent death two lines later. The shim below fails ONLY the count program, so a
# perfectly healthy manifest takes the crash path.
# ⛔ EACH READER IS BROKEN SEPARATELY. ⛔ A shim that fails only the COUNT program
# leaves the eviction extractor untested, and the comment above would then claim
# "every reader" while covering two of them — which is exactly what happened: the
# extractor captured its status into a variable whose only check had already run
# 60 lines earlier, so the failure was recorded and never acted on. One sub-case
# per reader is the only shape that cannot make that claim falsely (automated-review, PR
# #152). The eviction program is identified by its `evicted` predicate, the count
# programs by `n++`.
if [[ -n "$a43_realawk" ]]; then
  for a43_prog in 'n++' 'evicted'; do
    a43_shimC=$(mktemp -d)
    {
      printf '#!/usr/bin/env bash\n'
      # A FAILED reader produces NO OUTPUT. Running the real awk and then exiting
      # non-zero still hands the caller a full result, so the ordinary code path
      # carries on and the leg passes for reasons unrelated to the guard — the
      # first draft did exactly that and stayed green over a live silent drop.
      printf 'if [[ "$*" == *%s* ]]; then\n' "$(printf '%q' "$a43_prog")"
      printf '  exit 2\n'
      printf 'fi\n'
      printf 'exec %s "$@"\n' "$a43_realawk"
    } > "$a43_shimC/awk"
    chmod +x "$a43_shimC/awk"

    a43_homeC=$(mktemp -d); a43_repoC=$(mktemp -d); mkdir -p "$a43_repoC/knowledge"
    a43_srcC="$a43_repoC/knowledge/toolbox-lessons.yml"
    emit_lessons_header "$a43_srcC"
    # Saturating, with a HIGH lesson evicted — so the eviction reader is actually
    # exercised and a suppressed report is a suppressed HIGH report.
    emit_lesson "$a43_srcC" "TL-G001" high 3000 9
    emit_lesson "$a43_srcC" "TL-G002" high 3000 8
    emit_lesson "$a43_srcC" "TL-G003" high 3000 7
    A43_RCC=0
    A43_OUTC=$(PATH="$a43_shimC:$PATH" HOME="$a43_homeC" SOURCE_OVERRIDE="$a43_srcC" \
      bash "$SYNC_SCRIPT" --quiet 2>&1) || A43_RCC=$?
    # ⛔ THE EXIT CODE ALONE CANNOT CARRY THIS LEG. ⛔ The fixture saturates the cap
    # with three HIGH lessons, so the ordinary high-eviction path reaches exit 4 on
    # its own — the `n++` sub-case passed with its guard deleted, satisfied entirely
    # by an escalation it had nothing to do with (automated-review, PR #152). Each sub-case
    # therefore asserts the diagnostic that ONLY its own reader's failure can emit,
    # which is the thing the guard actually does.
    case "$a43_prog" in
      'n++')     a43_diag='could not finish counting it' ;;
      'evicted') a43_diag='could not extract the evicted rows' ;;
    esac
    if [[ "$A43_RCC" -eq 2 ]]; then
      A43_FAILURES+=("leg 15 [$a43_prog]: a failing record reader killed the sync at exit 2. 2 is not one of this script's documented codes (0/3/4) and nothing is printed, so the same broken awk produces an orderly cannot-confirm at one call site and a silent death at another: $A43_OUTC")
    elif [[ "$A43_RCC" -ne 4 ]]; then
      A43_FAILURES+=("leg 15 [$a43_prog]: the sync exited $A43_RCC when its '$a43_prog' reader failed, expected 4. A record this run could not finish reading cannot rule out a dropped high lesson — capturing the reader's status into a variable that nothing checks afterwards is the inert-guard shape these guards exist to prevent: $A43_OUTC")
    elif ! grep -qF "$a43_diag" <<<"$A43_OUTC"; then
      A43_FAILURES+=("leg 15 [$a43_prog]: the run reached exit 4 but never said the '$a43_prog' reader had failed ('$a43_diag'). This fixture evicts a priority:high lesson, so exit 4 is reachable through the ordinary escalation with the reader guard deleted entirely — without this assertion the sub-case is satisfied by an escalation it played no part in: $A43_OUTC")
    fi
    rm -rf "$a43_homeC" "$a43_repoC" "$a43_shimC"
  done
fi

# --- Leg 16 (EXECUTED): a failed reader is named ACCURATELY ------------------
# ⛔ ONE STATUS VARIABLE, TWO READERS, NEVER RESET. ⛔ The count readers and the
# eviction reader both assign to $ROW_READ_RC, and nothing clears it in between —
# so a COUNT failure leaves it non-zero and the eviction guard downstream prints
# "The eviction reader ... failed" about a reader that ran perfectly. The
# escalation is right and the attribution is wrong, which is worse than silence
# for whoever has to act on it: it sends them to the wrong awk. It also weakens
# leg 15 [evicted], whose diagnostic then fires on an n++ failure too.
if [[ -n "$a43_realawk" ]]; then
  a43_shimD=$(mktemp -d)
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [[ "$*" == *"n++"* ]]; then\n'
    printf '  exit 2\n'
    printf 'fi\n'
    printf 'exec %s "$@"\n' "$a43_realawk"
  } > "$a43_shimD/awk"
  chmod +x "$a43_shimD/awk"

  a43_homeD=$(mktemp -d); a43_repoD=$(mktemp -d); mkdir -p "$a43_repoD/knowledge"
  a43_srcD="$a43_repoD/knowledge/toolbox-lessons.yml"
  emit_lessons_header "$a43_srcD"
  emit_lesson "$a43_srcD" "TL-H001" high 3000 9
  emit_lesson "$a43_srcD" "TL-H002" high 3000 8
  emit_lesson "$a43_srcD" "TL-H003" high 3000 7
  A43_RCD=0
  A43_OUTD=$(PATH="$a43_shimD:$PATH" HOME="$a43_homeD" SOURCE_OVERRIDE="$a43_srcD" \
    bash "$SYNC_SCRIPT" --quiet 2>&1) || A43_RCD=$?
  if ! grep -qF 'could not finish counting it' <<<"$A43_OUTD"; then
    A43_FAILURES+=("leg 16 precondition: the count reader was broken but the run never said so, so this leg is not observing the state it is about: $A43_OUTD")
  elif grep -qF 'could not extract the evicted rows' <<<"$A43_OUTD"; then
    A43_FAILURES+=("leg 16: the run blamed the EVICTION reader on a run where only the COUNT reader was broken — the eviction awk ran fine. The two share \$ROW_READ_RC and nothing resets it between them, so the count failure leaks downstream and misnames itself. An escalation that names the wrong reader sends whoever acts on it to the wrong awk, and it makes leg 15 [evicted]'s diagnostic fire for the wrong cause: $A43_OUTD")
  fi
  rm -rf "$a43_homeD" "$a43_repoD" "$a43_shimD"
fi

# --- Leg 17 (SOURCE STRUCTURE): exit 4 enumerates ALL of its causes ----------
# ⛔ THE ENUMERATION HAS BEEN WRONG THREE TIMES ON THIS BRANCH. ⛔ It said two when
# there were three; it was corrected to three; and this branch then added TWO more
# without touching it — a complete record tagged to ANOTHER run, and a reader of
# the record that failed. Five causes, documented as three, in the block callers
# are written against. The two new ones are the ones a reader is least likely to
# guess, because both describe a record that is present and well-formed.
a43_doc=$(awk '/^#   4  /{inb=1} inb{print} inb && /^#   Callers/{exit}' "$SYNC_SCRIPT")
if [[ -z "$a43_doc" ]]; then
  A43_FAILURES+=("leg 17: could not locate the exit-code 4 documentation block in $SYNC_SCRIPT")
else
  if grep -qiE 'THREE causes|one of three things' <<<"$a43_doc"; then
    A43_FAILURES+=("leg 17: the exit-4 documentation still says THREE causes. A foreign-tagged record and a failed record reader both reach exit 4 and are neither (a), (b) nor (c): $a43_doc")
  fi
  if ! grep -qiE 'another run|foreign|another sync' <<<"$a43_doc"; then
    A43_FAILURES+=("leg 17: the exit-4 documentation never mentions a record tagged to ANOTHER run. That record is complete and well-formed — the one state a reader would never guess escalates — so leaving it out is the least forgivable omission in the list: $a43_doc")
  fi
  if ! grep -qiE 'reader' <<<"$a43_doc"; then
    A43_FAILURES+=("leg 17: the exit-4 documentation never mentions a failed READER of the record. The record can be present, complete and this run's own, and still be unreadable by this run — which escalates: $a43_doc")
  fi
fi
# The caller-facing text has to carry it too: these are the strings a developer
# actually sees, and they were corrected once already for exactly this.
for a43_c3 in "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/update.sh"; do
  [[ -f "$a43_c3" ]] || continue
  if code_re_lines_in "$a43_c3" 'one of three things' | grep -q .; then
    A43_FAILURES+=("leg 17: $(basename "$a43_c3") still tells the developer exit 4 means 'one of three things'. There are five, and the two added on this branch (a foreign-tagged record, a failed reader) both describe a record that is present and complete")
  fi
done

if [[ ${#A43_FAILURES[@]} -eq 0 ]]; then
  pass_test "$TC (a CRLF-terminated manifest was still accepted, a sentinel probe that printed the right text and then died was refused rather than believed, an inherited HIGH_EVICTED neither invented nor suppressed an escalation, the exit-4 documentation stopped promising a usable pack on a path that can leave none, and both callers enumerate three causes without asserting a severe eviction)"
else
  fail_test "$TC" "$(printf '%s; ' "${A43_FAILURES[@]}")"
fi

# ---------------------------------------------------------------------------
# TC-STL-44: EXECUTES two real syncs against one HOME to prove the victim run
# never reports success over a peer's decisions.
#
# ⛔ WHY THIS EXISTS WHEN TC-STL-43 LEG 13 ALREADY COVERS THE TAG. ⛔ Leg 13
# SIMULATES the peer: its shim overwrites the record with a hand-written
# foreign-tagged manifest. That proves the COMPARISON works, and nothing more. It
# cannot prove that a real concurrent sync actually produces the state the
# comparison is aimed at — an assumption about the generator, the write ordering
# and the up-front `rm -f` all have to hold for the simulated file to resemble
# the real one, and every one of those is exactly what this branch kept changing.
# This test runs the ACTUAL second sync and lets it write whatever it writes.
#
# The interleaving, which is imposed by the call graph rather than raced for:
#
#   run A: rm the record; A's pass writes A's; A's pass writes the tier
#   run B: rm the record  <-- A's is GONE; B writes B's; B writes a tier
#   run A: reads "the record" -> finds B's -> must NOT report success
#
# A's own pass evicted a `priority: high` lesson. MEASURED at 20791b5, before the
# `#run` tag landed: exit 0, stderr completely EMPTY, TL-A003 unnamed — while
# origin/main exits 4 on the identical interleaving because its record is a
# `mktemp` path no peer can write. The fixed shared path was therefore a
# REGRESSION against main until the tag comparison closed it.
#
# WHAT THIS LEG DOES AND DOES NOT REQUIRE: it requires the victim not to exit 0
# and not to be silent — that is the invariant issues #144/#151 are about. It
# deliberately does NOT require the evicted lesson to be NAMED. Under the landed
# design the victim cannot name it: it detects a foreign record and escalates to
# cannot-confirm, so its own verdicts are unavailable to it. origin/main does
# name it, because it reads a private record. Pinning the naming here would
# encode one of the two designs into a test about the invariant, so the leg
# pins the invariant and this comment records the difference (automated-review + Codex,
# PR #152).
#
# FALSIFYING EDIT: drop the `#run` comparison in sync-toolbox-lessons.sh — leg A
# goes red (exit 0, empty stderr) while legs B and C stay green.
# ---------------------------------------------------------------------------
TC="TC-STL-44: two real concurrent syncs — the victim never reports success (executed)"
A44_FAILURES=()
a44_realpy=$(command -v python3 2>/dev/null || true)

if [[ -z "$a44_realpy" ]]; then
  # No python3 means no capping pass and no record at all, so the collision this
  # test executes cannot arise. Skipping is honest; asserting would be a test
  # that passes because the mechanism it targets never ran.
  pass_test "$TC (skipped — python3 unavailable, so no decision record is produced and the peer-collision path cannot be exercised)"
else
  # Peer B's source: small, ordinary, fits entirely. Its record therefore shows
  # NO eviction — which is what makes it a convincing impostor for A's.
  a44_repoB=$(mktemp -d); mkdir -p "$a44_repoB/knowledge"
  a44_srcB="$a44_repoB/knowledge/toolbox-lessons.yml"
  emit_lessons_header "$a44_srcB"
  emit_lesson "$a44_srcB" "TL-B001" normal 200 2
  emit_lesson "$a44_srcB" "TL-B002" normal 200 1

  # The peer-run injector: run A's real work, then a COMPLETE second sync inside
  # A's window. Guarded against recursion, so exactly one peer runs.
  a44_shim=$(mktemp -d)
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [[ -n "${A44_NESTED:-}" ]]; then exec "$A44_REALPY" "$@"; fi\n'
    printf '"$A44_REALPY" "$@"\n'
    printf 'rc=$?\n'
    printf 'A44_NESTED=1 SOURCE_OVERRIDE="$A44_SRCB" bash "$A44_SYNC" --quiet >/dev/null 2>&1 || true\n'
    printf 'exit $rc\n'
  } > "$a44_shim/python3"
  chmod +x "$a44_shim/python3"

  # --- Leg A: run A evicts a HIGH lesson while a real peer replaces the record -
  a44_repoA=$(mktemp -d); mkdir -p "$a44_repoA/knowledge"
  a44_srcA="$a44_repoA/knowledge/toolbox-lessons.yml"
  emit_lessons_header "$a44_srcA"
  emit_lesson "$a44_srcA" "TL-A001" high 3000 9
  emit_lesson "$a44_srcA" "TL-A002" high 3000 8
  emit_lesson "$a44_srcA" "TL-A003" high 3000 7

  # PRECONDITION, established through the suite's ONE parser rather than
  # asserted: run A's source, alone, really does evict TL-A003 as high. Without
  # it the leg could pass against a fixture that never saturated.
  a44_pre=$(lesson_decisions "$a44_srcA" | awk -F'\t' '$1 == "TL-A003" { print $2 "/" $6 }')
  if [[ "$a44_pre" != "high/evicted" ]]; then
    A44_FAILURES+=("leg A precondition: run A's source does not evict TL-A003 as a high lesson on its own (generator says '${a44_pre:-<no row>}'), so the interleaving below would prove nothing")
  fi

  a44_home=$(mktemp -d); mkdir -p "$a44_home/.claude/toolbox-knowledge"
  a44_errf="$a44_home/a-stderr.log"
  A44_RC=0
  # stderr captured separately: "did not exit 0" and "did not do it silently" are
  # two different assertions and a merged 2>&1 could not tell stdout from stderr.
  A44_REALPY="$a44_realpy" A44_SRCB="$a44_srcB" A44_SYNC="$SYNC_SCRIPT" \
    PATH="$a44_shim:$PATH" HOME="$a44_home" SOURCE_OVERRIDE="$a44_srcA" \
    bash "$SYNC_SCRIPT" --quiet 2>"$a44_errf" >/dev/null || A44_RC=$?
  A44_ERR=$(cat "$a44_errf" 2>/dev/null || true)

  # PRECONDITION: the peer really did run inside A's window. B writes the slow
  # tier during the shim and A never rewrites it, so B's lessons standing in the
  # slow tier is the observable proof that a second sync executed.
  if ! grep -q 'TL-B001' "$a44_home/.claude/toolbox-knowledge/toolbox-lessons.yml" 2>/dev/null; then
    A44_FAILURES+=("leg A precondition: peer sync B left no trace in the slow tier, so the interleaving never happened and leg A is vacuous")
  fi

  if [[ "$A44_RC" -eq 0 ]]; then
    A44_FAILURES+=("leg A: sync A exited 0 while its OWN capping pass evicted the priority:high lesson TL-A003 and a REAL peer sync replaced the decision record inside A's window. A record this run did not write cannot rule out its own eviction, so this is the silent high-priority drop of issues #144/#151; origin/main exits 4 on the identical interleaving. stderr was: [$A44_ERR]")
  fi
  if [[ -z "$A44_ERR" ]]; then
    A44_FAILURES+=("leg A: sync A said NOTHING on stderr while reading a record a real peer had replaced. Exit code and stderr are separate channels — --quiet keeps stdout clean, so stderr is where a human learns why the run could not confirm its own verdicts; escalating without a word leaves the cause unfindable")
  fi

  # --- Leg B (CONTROL): concurrency alone must not manufacture an escalation --
  # GREEN BOTH BEFORE AND AFTER THE FIX. It exists so leg A cannot be satisfied
  # by escalating whenever a peer is present: run A here evicts nothing and its
  # record is still its own, so a peer running alongside must leave it at exit 0.
  a44_repoC=$(mktemp -d); mkdir -p "$a44_repoC/knowledge"
  a44_srcC="$a44_repoC/knowledge/toolbox-lessons.yml"
  emit_lessons_header "$a44_srcC"
  emit_lesson "$a44_srcC" "TL-C001" high   200 3
  emit_lesson "$a44_srcC" "TL-C002" normal 200 2
  a44_home2=$(mktemp -d); mkdir -p "$a44_home2/.claude/toolbox-knowledge"
  A44_RC2=0
  A44_OUT2=$(HOME="$a44_home2" SOURCE_OVERRIDE="$a44_srcC" bash "$SYNC_SCRIPT" --quiet 2>&1) || A44_RC2=$?
  if [[ "$A44_RC2" -ne 0 ]]; then
    A44_FAILURES+=("leg B (control): a solo run that evicted NOTHING exited $A44_RC2, expected 0 — the tag comparison must accept a run's OWN record, or every healthy sync escalates forever: $A44_OUT2")
  fi

  # --- Leg C (CONTROL): the durable published record survives the run ---------
  # GREEN BOTH BEFORE AND AFTER THE FIX. The record was moved out of `mktemp`
  # precisely because callers and this suite's own lesson_decisions() read it
  # AFTER the script exits. A fix that restored concurrency safety by making the
  # record private again would re-break that caller, so the durable artifact at
  # the documented pack path is pinned here.
  a44_pub="$a44_home2/.claude/toolbox-knowledge/lessons-decisions.tsv"
  if [[ ! -f "$a44_pub" ]]; then
    A44_FAILURES+=("leg C (control): no decision record survives at $a44_pub after the run — the record is documented as a pack member and is read after exit by lesson_decisions(); a per-run-only record re-breaks the caller that mktemp broke")
  elif [[ "$(awk 'NF{last=$0} END{sub(/\r$/,"",last); print last}' "$a44_pub" 2>/dev/null)" != "#END" ]]; then
    A44_FAILURES+=("leg C (control): the surviving record at $a44_pub is not terminated by its #END sentinel, so every reader must treat it as truncated")
  fi

  rm -rf "$a44_repoA" "$a44_repoB" "$a44_repoC" "$a44_home" "$a44_home2" "$a44_shim"

  if [[ ${#A44_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (a REAL second sync replacing the record inside run A's window left A escalating and saying why rather than exiting 0 in silence; a solo run that evicted nothing still exited 0; and a complete, sentinel-terminated record still survived at the documented pack path)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A44_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-74: a C0 CONTROL BYTE ANYWHERE IN handover.md STILL YIELDS PARSABLE
#            JSON — and ordinary text still round-trips byte-identically
#
# WHY (issue #155): the fold's `json_escape` escaped only backslash, double
# quote, tab, CR and LF. Every OTHER C0 control byte (0x01-0x1F) passed through
# raw, and a raw control byte inside a JSON string is invalid per spec — `jq`
# enforces it:
#
#   jq: parse error: Invalid string: control characters from U+0000 through
#       U+001F must be escaped
#
# No attacker is needed to produce one. Pasting colourised terminal output into
# a phase heading puts a raw ESC (0x1B) in a `## ` line, and the fold copies the
# heading straight into the record's `phase` field.
#
# WHY THAT IS WORSE THAN A PARSE ERROR — the part this test exists for: the
# record becomes UNRECOVERABLE, because two guards each decline it and neither
# hands it on. The /review-pr Step 0.5 deviation consumer fails its
# `jq -er '.phase'`, so the snapshot joins PARSE_FAIL_FILES and is never
# archived and never surfaced (correct fail-closed behaviour in isolation); and
# the legacy-format guard inspects only line 1, which the offending line usually
# is not, so the file is not classified legacy either. Net: the snapshot is
# pinned forever, re-reported as a parse failure on every run, with no path to
# resolution offered anywhere. That is TL-0012 (capture-without-consumption)
# arriving through a new door, in its cry-wolf form.
#
# HOW IT ASSERTS: it drives the REAL scripts/pr-postmerge-fold.sh (as TC-STL-25
# does) and then parses the emitted records with the EXACT invocation the
# consumer uses — `printf '%s' "$RECORD" | jq -er '.phase'` — rather than a
# looser `jq .` over the whole file, so a record this suite calls parsable is
# one the real reader can also read.
#
# BOTH DIRECTIONS ARE PINNED (TL-0011 — a test only in the direction just
# changed is a mirror):
#   leg A  a phase heading carrying a raw ESC, AND a body carrying ALL 29
#          representable C0 bytes (0x01-0x1F less LF and CR, which end the
#          record), parse and decode back to the ORIGINAL bytes;
#   leg B  an ordinary heading and body — plain ASCII plus a multi-byte em dash
#          — round-trip byte-identically, so the escaping did not mangle normal
#          input or corrupt UTF-8;
#   leg C  the five pre-existing escapes still work: a body holding a literal
#          backslash, a double quote and a tab decodes back to exactly those.
#          This is also the ORDERING pin — `json_escape` must keep handling the
#          literal backslash FIRST. If the C0 pass ran before it, the backslash
#          that the C0 pass itself writes would be doubled by the backslash
#          gsub, and leg A's body would decode to the six literal characters
#          backslash-u-0-0-1-b instead of an ESC byte.
#
# Escaping (not stripping) is what is pinned here: the round-trip assertions
# require the original bytes back. Stripping the control byte would also produce
# valid JSON, but it silently discards an operator's data, and a deviation
# pipeline whose whole purpose is capture must not delete what it captured.
#
# FALSIFYING EDITS (each must turn this test RED): remove the C0 pass from
# `json_escape` (leg A's records stop parsing — this is the pre-fix state, which
# was run and observed); move the C0 pass ABOVE the backslash `gsub` (leg A's
# body decodes to a literal backslash-u sequence); replace the escape with a
# strip (leg A's body loses bytes); stop escaping the double quote or the
# backslash (leg C fails).
#
# `gh` is stubbed to exit 1 so the script's lessons half stays offline, exactly
# as in TC-STL-25.
# ---------------------------------------------------------------------------
TC="TC-STL-74: control bytes are escaped and ordinary text round-trips (executed)"
FOLD_SCRIPT_74="$SCRIPT_DIR/pr-postmerge-fold.sh"
if [[ ! -f "$FOLD_SCRIPT_74" ]]; then
  fail_test "$TC" "cannot locate scripts/pr-postmerge-fold.sh ($FOLD_SCRIPT_74) — the writer whose escaping this test pins is missing"
elif ! command -v jq >/dev/null 2>&1; then
  fail_test "$TC" "jq is not installed — the whole point of this test is that the emitted record parses with the same jq the /review-pr consumer uses, so it cannot run without it (jq is a documented toolbox dependency; install it: brew install jq / apt install jq)"
else
  a74_home=$(mktemp -d)
  a74_repo=$(mktemp -d)
  a74_stub=$(mktemp -d)
  mkdir -p "$a74_repo/.claude"
  A74_FAILURES=()

  # ⛔ THIS STUB MUST ANSWER mergedAt. ⛔ The deviation snapshot is gated on measured
  # freshness and task binding (issue #154). An `exit 1` stub leaves the fold unable to
  # read the merge time and unable to bind the handover, so it REFUSES — correctly — and
  # this test silently stops asserting what its name says, becoming a test of the refusal
  # path instead. Answer with a seconds-old merge and a binding branch/title.
  tc74_merged=$(date -u -v-30S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "30 seconds ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\t%%s\\t%%s\\n" "%s" "fixture/branch" "fixture title body"\n' "$tc74_merged"
  } > "$a74_stub/gh"
  chmod +x "$a74_stub/gh"

  # The fold only reads handover.md when the checkout's origin slug matches the
  # OWNER/REPO_NAME it was given, so the fixture repo needs a real remote.
  git -C "$a74_repo" init -q 2>/dev/null
  git -C "$a74_repo" remote add origin https://github.com/baselito/ai-toolbox.git 2>/dev/null

  # Raw control bytes, built with printf so they reach the fixture as single
  # bytes rather than as the two-character sequences a here-doc would write.
  # NUL (0x00) is not in THIS fixture because it is now handled one layer earlier
  # and has its own case, TC-STL-78. ⛔ THE OLD REASON GIVEN HERE WAS TOO NARROW: ⛔
  # it said "awk truncates an input record at the first NUL, so a NUL never reaches
  # json_escape and no escaping change could rescue it". True of the macOS system
  # awk this was measured on, NOT true of awk in general — gawk on Linux can carry
  # a NUL through a record, where it would reach json_escape, match nothing in the
  # 1..31 lookup, and be copied out RAW. The reviewer on PR #162 raised this five
  # times and was right. The fold now strips NUL before any awk sees it, so the
  # behaviour is identical on every implementation. ESC remains the byte that
  # actually turns up in practice.
  A74_ESC=$(printf '\033')
  A74_TAB=$(printf '\011')

  # ⛔ THE WHOLE SWEEP, NOT A HANDFUL. ⛔ Every C0 byte the fold can actually be
  # handed on one line: 0x01-0x1F less LF (0x0A) and CR (0x0D), which end the
  # record before json_escape is ever reached. An earlier fixture carried four
  # of these 29 (BEL, VT, FF, ESC) while this test's own header claimed it
  # proved "every one of them" — so a regression that stopped escaping, say,
  # 0x1A would have sailed through green under a heading that said otherwise.
  # Tab (0x09) is in the sweep and keeps its short \t form; that is still a
  # correct escape and still round-trips, so it does not need excluding.
  A74_ALL_C0=''
  for A74_I in 1 2 3 4 5 6 7 8 9 11 12 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
    A74_ALL_C0="$A74_ALL_C0$(printf "\\$(printf '%03o' "$A74_I")")"
  done
  # VACUITY GUARD: if that loop ever produced nothing (a quoting change, a shell
  # difference), leg A would be asserting a round-trip over a body with no
  # control bytes in it — a pass proving nothing. Pin the byte count.
  A74_SWEEP_LEN=$(printf '%s' "$A74_ALL_C0" | LC_ALL=C wc -c | tr -d ' ')
  if [[ "$A74_SWEEP_LEN" -ne 29 ]]; then
    A74_FAILURES+=("fixture bug: the C0 sweep built $A74_SWEEP_LEN bytes, expected 29 (0x01-0x1F less LF and CR) — leg A would assert nothing")
  fi

  # The three expected round-trip values, defined once and used both to BUILD
  # the fixture and to ASSERT the decode — so the two can never drift apart.
  A74_PHASE_C0="Colourised phase ${A74_ESC}[0m name"
  A74_BODY_C0="C0-BODY all[${A74_ALL_C0}] esc${A74_ESC}[1m end"
  A74_PHASE_PLAIN="Ordinary phase name"
  A74_BODY_PLAIN="PLAIN-BODY ordinary text with an em dash — and nothing exotic"
  A74_BODY_ESCAPES="ESCAPES-BODY a backslash \\ a quote \" and a${A74_TAB}tab"

  # printf with %s arguments (not a here-doc) so backslashes, quotes and control
  # bytes land in the file literally.
  {
    printf '# Handover\n\n'
    printf '## %s\n' "$A74_PHASE_C0"
    printf 'Completed: 2026-01-01\n\n'
    printf '### Deviations\n'
    printf -- '- %s\n\n' "$A74_BODY_C0"
    printf '## %s\n' "$A74_PHASE_PLAIN"
    printf 'Completed: 2026-01-01\n\n'
    printf '### Deviations\n'
    printf -- '- %s\n' "$A74_BODY_PLAIN"
    printf -- '- %s\n\n' "$A74_BODY_ESCAPES"
    printf 'Blockers: none\n'
  } > "$a74_repo/.claude/handover.md"

  HOME="$a74_home" PATH="$a74_stub:$PATH" \
    bash "$FOLD_SCRIPT_74" baselito ai-engineering 7474 "$a74_repo" >/dev/null 2>&1

  A74_SNAP="$a74_home/.claude/pending-deviations-7474.log"
  if [[ ! -f "$A74_SNAP" ]]; then
    A74_FAILURES+=("no snapshot written to $A74_SNAP — the fixture never reached the awk (check the origin-slug gate)")
  else
    # (1) EVERY record must parse through the consumer's own call shape. A
    # record that fails here is one the real reader counts as a PARSE_FAILURE
    # and then strands forever.
    A74_PARSE_FAILS=0
    A74_FIRST_ERR=''
    A74_PHASES=()
    A74_BODIES=()
    while IFS= read -r A74_REC || [[ -n "$A74_REC" ]]; do
      [[ -z "$A74_REC" ]] && continue
      A74_P=$(printf '%s' "$A74_REC" | jq -er '.phase' 2>&1) || {
        A74_PARSE_FAILS=$((A74_PARSE_FAILS + 1))
        [[ -z "$A74_FIRST_ERR" ]] && A74_FIRST_ERR="$A74_P"
        continue
      }
      A74_B=$(printf '%s' "$A74_REC" | jq -er '.body' 2>&1) || {
        A74_PARSE_FAILS=$((A74_PARSE_FAILS + 1))
        [[ -z "$A74_FIRST_ERR" ]] && A74_FIRST_ERR="$A74_B"
        continue
      }
      A74_PHASES+=( "$A74_P" )
      A74_BODIES+=( "$A74_B" )
    done < "$A74_SNAP"

    A74_REC_COUNT=$(grep -c . "$A74_SNAP" || true)
    if [[ "$A74_PARSE_FAILS" -ne 0 ]]; then
      A74_FAILURES+=("$A74_PARSE_FAILS of $A74_REC_COUNT record(s) failed the consumer's own \`jq -er\` call — a raw C0 byte reached the JSON string. jq said: [${A74_FIRST_ERR}]. Such a snapshot is never archived and never surfaced: it is stranded, and re-reported as a parse failure on every run")
    fi
    if [[ "$A74_REC_COUNT" -ne 3 ]]; then
      A74_FAILURES+=("expected exactly 3 records (the C0 deviation, the plain one and the escapes one), got $A74_REC_COUNT")
    fi

    # (2) ROUND-TRIP, all three legs. Only checked when every record parsed —
    # otherwise the arrays are short and the indices below mean nothing.
    if [[ "$A74_PARSE_FAILS" -eq 0 && "${#A74_BODIES[@]}" -eq 3 ]]; then
      # leg A — the control-byte record decodes back to the ORIGINAL bytes.
      [[ "${A74_PHASES[0]}" == "$A74_PHASE_C0" ]] \
        || A74_FAILURES+=("leg A: the phase carrying a raw ESC did not decode back to its original bytes (the escaping is lossy or mis-ordered)")
      [[ "${A74_BODIES[0]}" == "$A74_BODY_C0" ]] \
        || A74_FAILURES+=("leg A: the body carrying all 29 representable C0 bytes (0x01-0x1F less LF and CR) did not decode back to its original bytes — at least one control byte was stripped, double-escaped, or left unescaped rather than represented as a unicode escape")
      # leg B (CONTROL) — ordinary text, including a multi-byte em dash, is
      # untouched. GREEN BOTH BEFORE AND AFTER THE FIX: it exists so leg A
      # cannot be satisfied by an escaper that rewrites everything.
      [[ "${A74_PHASES[1]}" == "$A74_PHASE_PLAIN" ]] \
        || A74_FAILURES+=("leg B (control): an ordinary phase heading no longer round-trips")
      [[ "${A74_BODIES[1]}" == "$A74_BODY_PLAIN" ]] \
        || A74_FAILURES+=("leg B (control): an ordinary body no longer round-trips — check the multi-byte em dash, which a byte-walking escaper must reassemble unchanged")
      # leg C (CONTROL + ORDERING) — the five pre-existing escapes still hold.
      [[ "${A74_PHASES[2]}" == "$A74_PHASE_PLAIN" ]] \
        || A74_FAILURES+=("leg C (control): the second deviation of a block lost its phase attribution")
      [[ "${A74_BODIES[2]}" == "$A74_BODY_ESCAPES" ]] \
        || A74_FAILURES+=("leg C: a body holding a literal backslash, a double quote and a tab no longer decodes back to exactly those — the pre-existing five escapes must keep working, and the literal backslash must still be handled FIRST")
    fi

    # (3) NO RAW C0 BYTE MAY SURVIVE anywhere in the file. The record separators
    # are the only legitimate newlines, so they are deleted first; then
    # EVERYTHING from 0x20 up is deleted, leaving only 0x00-0x1F. `tr` is used
    # rather than `grep` because grep applies binary-file heuristics to input
    # holding control bytes and would report a match it refuses to show.
    #
    # ⛔ THE UPPER BOUND IS 0x1F, NOT 0x7E. ⛔ This deleted `\040-\176` and
    # `\200-\377`, which spared 0x7F (DEL) and so counted it as a violation. But
    # JSON forbids only U+0000-U+001F unescaped; DEL is legal bare, and
    # pr-postmerge-fold.sh says so in as many words ("DEL (0x7F) and the C1 range
    # are legal unescaped in JSON and are left alone") and deliberately does NOT
    # escape it. A DEL pasted into handover.md therefore produced valid JSON that
    # the consumer read without complaint, while this assertion failed the suite —
    # a test contradicting the writer it is meant to pin. Deleting `\040-\377` in
    # one range leaves exactly the set JSON actually forbids.
    A74_RAW_CTL=$(LC_ALL=C tr -d '\n' < "$A74_SNAP" | LC_ALL=C tr -d '\040-\377' | wc -c | tr -d ' ')
    [[ "$A74_RAW_CTL" -eq 0 ]] \
      || A74_FAILURES+=("$A74_RAW_CTL raw control byte(s) survive in the snapshot — JSON forbids U+0000-U+001F unescaped inside a string, so every one of them is a record the consumer cannot read")

    # (4) The representation is the unicode ESCAPE, named explicitly. Round-trip
    # already forces it (a strip would lose bytes), but naming it here says
    # WHICH of the issue's two options this codebase chose.
    A74_ESCAPED=$(LC_ALL=C grep -c '\\u001b' "$A74_SNAP" || true)
    [[ "$A74_ESCAPED" -ge 1 ]] \
      || A74_FAILURES+=("no backslash-u-0-0-1-b escape found in the snapshot — the ESC byte must be REPRESENTED as a unicode escape, not deleted")
  fi

  rm -rf "$a74_home" "$a74_repo" "$a74_stub"

  if [[ ${#A74_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (a phase heading carrying a raw ESC and a body carrying all 29 representable C0 bytes both parsed through the consumer's own jq call and decoded back to their original bytes; ordinary ASCII + a multi-byte em dash round-tripped untouched; a literal backslash, quote and tab still decoded to exactly those; and zero raw C0 bytes survive in the file)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A74_FAILURES[@]}")"
  fi
fi

# TC-STL-79: the deviation snapshot is gated on MEASURED freshness and task
#            binding — NOT on a caller flag (issue #154, executed)
#
# WHY THIS TEST EXISTS. commands/review-pr.md Step 0.5 gated its post-merge fold
# fallback on `HAS_AUTO_FLAG`, and the comment beside the gate stated the real
# requirement correctly: run the fold only while handover.md still belongs to
# THIS PR's work. But `--auto` is a string in an argv list, not evidence of
# recency. A human can type it and a starved cron can fire hours late, so the
# gate tested a SHAPE and inferred a FACT it never measured.
#
# REPRODUCED (issue #154): `/review-pr --repo baselito/ai-engineering 149 --auto`
# typed by hand 9.4 hours after PR #149 merged. HAS_AUTO_FLAG=true authorised the
# fold; no snapshot existed so the fold's own idempotency guard would not have
# stopped it; and .claude/handover.md held a DIFFERENT task's deviations (its
# trailing `# NEW TASK` heading named issue #140). Five deviations would have been
# filed under PR #149 — the exact mis-attribution the gate was written to prevent,
# reached THROUGH the gate rather than around it.
#
# WHY THE ASSERTIONS LIVE HERE AND RUN THE SCRIPT. The gate now lives in
# scripts/pr-postmerge-fold.sh, which is where BOTH merge routes converge
# (/merge-pr Step 2.5 at merge time, /review-pr Step 0.5's fallback later). That
# placement is the same lesson the archive semantics taught: one rule stated in
# two places is one rule that will diverge. And because it is a script, this test
# EXECUTES it — the previous gate was never once exercised with a late `--auto`,
# which is exactly why it survived (TL-0002, the inert detector).
#
# THE SIX LEGS, and which direction each moves:
#   1. RED before the fix — a mismatched handover (marker names issue #140) for a
#      PR merged 9.4h ago must write NOTHING and must SAY the marker names other
#      work. This is the reproduction.
#   2. CONTROL, green both sides — a handover BOUND to this PR (marker names an
#      issue the PR closes, and the PR's own branch) must still snapshot even
#      though the merge is 9.4h old. Binding outranks the clock; without this leg
#      the fix could be "achieved" by refusing everything late.
#   3. CONTROL, green both sides — an unmarked handover with a 30-second-old
#      merge must snapshot. This is /merge-pr's at-merge path, the primary
#      producer of every snapshot the loop consumes, AND this suite's vacuity
#      guard: it can only pass if the script really read the stubbed metadata.
#   4. RED before the fix — the same unmarked handover 9.4h after the merge is
#      refused. Nothing binds it and nothing measures fresh, so it is not this
#      PR's work to snapshot.
#   5. RED before the fix — with `gh` unavailable the age is unknowable, so the
#      run must fail CLOSED and say so rather than write on an assumption
#      (TL-0001: the recurring defect in this repo is the guard that permits what
#      it could not evaluate).
#   6. A refusal must leave no debris — no snapshot, no `.tmp`, and handover.md
#      untouched. A gate that refuses by damaging its input is not a gate.
# ---------------------------------------------------------------------------
TC="TC-STL-79: the fold measures freshness and task binding before snapshotting (executed)"
FOLD_SCRIPT="$SCRIPT_DIR/pr-postmerge-fold.sh"
if [[ ! -f "$FOLD_SCRIPT" ]]; then
  fail_test "$TC" "cannot locate scripts/pr-postmerge-fold.sh ($FOLD_SCRIPT)"
else
  A79_FAILURES=()

  # An ISO-8601 Z timestamp N seconds in the past. Both date dialects are tried
  # because this suite runs on stock macOS (BSD `date -r <epoch>`) and on Linux
  # CI (GNU `date -d @<epoch>`); the production script resolves the same split.
  a79_iso_ago() {
    local a_secs="$1" a_epoch
    a_epoch=$(( $(date -u +%s) - a_secs ))
    date -u -r "$a_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -d "@$a_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
  }

  # ONE fixture builder + runner, so the legs differ only in the three inputs
  # that decide the verdict: the handover's trailing task marker, how long ago
  # the PR merged, and what the PR itself is. Sets A79_OUT / A79_SNAP / A79_HOME
  # / A79_REPO / A79_BIN for the caller to assert on and then clean up.
  a79_run() {
    local a_marker="$1" a_merged="$2" a_pr="$3" a_branch="$4" a_titlebody="$5" a_gh="$6"
    A79_HOME=$(mktemp -d)
    A79_REPO=$(mktemp -d)
    A79_BIN=$(mktemp -d)
    mkdir -p "$A79_REPO/.claude"

    if [[ "$a_gh" == "down" ]]; then
      # The whole point of leg 5: the metadata read fails, so nothing about this
      # merge's age is knowable.
      printf '#!/bin/sh\nexit 1\n' > "$A79_BIN/gh"
    else
      # Deliberately ARG-INSENSITIVE. This test pins the fold's DECISION given
      # the facts, not the exact `--json`/`--jq` expression it writes to obtain
      # them — a reworded query still exercises the same decision, while a query
      # that stops asking for the merge time shows up as leg 3 going red (the
      # script would have no age to measure and must then fail closed).
      {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\t%%s\\t%%s\\n" "%s" "%s" "%s"\n' "$a_merged" "$a_branch" "$a_titlebody"
      } > "$A79_BIN/gh"
    fi
    chmod +x "$A79_BIN/gh"

    # The fold only reads handover.md when the checkout's origin slug matches the
    # OWNER/REPO_NAME it was handed, so the fixture needs a real remote.
    git -C "$A79_REPO" init -q 2>/dev/null
    git -C "$A79_REPO" remote add origin https://github.com/baselito/ai-toolbox.git 2>/dev/null

    # Two phase blocks either side of the optional task marker: the FIRST holds a
    # deviation from whatever came before, the SECOND holds the record under test.
    # A fold that ignores the marker entirely captures both.
    {
      printf '# Handover\n\n'
      printf '## Implementation\n\n### Deviations\n- OLD-TASK-DEVIATION from whatever came before\n\n'
      if [[ -n "$a_marker" ]]; then
        printf '%s\n\n' "$a_marker"
      fi
      printf '## Verification\n\n### Deviations\n- FIXTURE-DEVIATION-ONE the record under test\n'
    } > "$A79_REPO/.claude/handover.md"

    A79_OUT=$(HOME="$A79_HOME" PATH="$A79_BIN:$PATH" \
      bash "$FOLD_SCRIPT" baselito ai-engineering "$a_pr" "$A79_REPO" 2>&1)
    A79_SNAP="$A79_HOME/.claude/pending-deviations-${a_pr}.log"
  }
  a79_cleanup() { rm -rf "$A79_HOME" "$A79_REPO" "$A79_BIN"; }

  A79_STALE=$(a79_iso_ago 33840)   # 9.4 hours — the measured reproduction
  A79_FRESH=$(a79_iso_ago 30)      # what /merge-pr's at-merge call looks like

  if [[ -z "$A79_STALE" || -z "$A79_FRESH" ]]; then
    A79_FAILURES+=("could not build ISO-8601 fixtures with either date dialect — every leg below would be testing the fold's UNKNOWN-age path instead of the ages it names")
  fi

  # --- Leg 1: THE REPRODUCTION. Mismatched handover + a 9.4h-old merge ---------
  a79_run '# NEW TASK — issue #140: extract the deviation consumer into a real script' \
          "$A79_STALE" 149 'feature/lessons-fast-tier-selection' \
          'fix(lessons): report every eviction, and fit 10 lessons instead of 7 Closes #144' \
          up
  if [[ -f "$A79_SNAP" ]]; then
    A79_FAILURES+=("leg 1: the fold SNAPSHOTTED $(grep -c . "$A79_SNAP" 2>/dev/null) record(s) to $A79_SNAP for PR #149 while handover.md's trailing marker names issue #140 and the merge is 9.4h old — this is issue #154's reproduction: a different task's deviations filed under an old PR's number")
  fi
  if ! printf '%s\n' "$A79_OUT" | grep -q 'Skipping deviation snapshot'; then
    A79_FAILURES+=("leg 1: the run did not report a skipped deviation snapshot — a refusal that says nothing is indistinguishable from a fold that found no deviations, and edge-cases General Rule 1 forbids failing silently. Output was: [$A79_OUT]")
  fi
  if ! printf '%s\n' "$A79_OUT" | grep -q '140'; then
    A79_FAILURES+=("leg 1: the refusal never named the task the handover actually belongs to (issue #140), so a reader cannot tell a binding refusal from a staleness one. Output was: [$A79_OUT]")
  fi
  # --- Leg 6 rides on leg 1's state: a refusal must not damage its input -------
  A79_DEBRIS=$(find "$A79_HOME/.claude" -maxdepth 1 -name 'pending-deviations-*' 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$A79_DEBRIS" != "0" ]]; then
    A79_FAILURES+=("leg 6: a refused fold left $A79_DEBRIS pending-deviations artefact(s) behind (a snapshot or a .tmp) — the reader sweeps that directory by glob, so a leftover .tmp is not inert")
  fi
  if ! grep -q 'FIXTURE-DEVIATION-ONE' "$A79_REPO/.claude/handover.md" 2>/dev/null; then
    A79_FAILURES+=("leg 6: handover.md no longer holds its deviation after a refused fold — refusing must never consume the source, or the record is lost to the very check meant to protect it")
  fi
  a79_cleanup

  # --- Leg 2 (CONTROL — green before AND after the fix) ------------------------
  # The handover names issue #140 AND the PR's own branch; the PR closes #140.
  # It IS this PR's work, so a 9.4h-old merge must not stop the snapshot. Without
  # this leg, "refuse everything older than the window" would pass legs 1/4/5.
  a79_run '# ROUND 7 + FIX ROUND — issue #140, branch refactor/consume-deviations-script' \
          "$A79_STALE" 159 'refactor/consume-deviations-script' \
          'refactor(deviations): make the consumer a script Closes #140' \
          up
  if [[ ! -f "$A79_SNAP" ]]; then
    A79_FAILURES+=("leg 2 (control): NO snapshot written for PR #159 although handover.md's marker names issue #140 (which this PR closes) and the PR's own branch — binding must outrank the clock, or a fix for issue #154 just throws away late-but-correct telemetry. Output was: [$A79_OUT]")
  elif ! grep -q 'FIXTURE-DEVIATION-ONE' "$A79_SNAP"; then
    A79_FAILURES+=("leg 2 (control): a snapshot exists but does not hold the fixture's deviation — the fold wrote something other than what handover.md said")
  fi
  a79_cleanup

  # --- Leg 3 (CONTROL + VACUITY GUARD — green before AND after the fix) --------
  # An unmarked handover 30 seconds after the merge: /merge-pr Step 2.5's call,
  # which produces most snapshots the loop ever consumes. It can only pass if the
  # script actually READ the stubbed merge time, so it is also what stops legs
  # 1/4/5 passing against a script that simply never writes.
  a79_run '' "$A79_FRESH" 900 'fix/some-branch' 'fix: a toolbox change' up
  if [[ ! -f "$A79_SNAP" ]]; then
    A79_FAILURES+=("leg 3 (control): NO snapshot written 30s after the merge with an unmarked handover — this is /merge-pr's at-merge path, and refusing it drains the whole self-improvement loop. It is also this test's vacuity guard: legs 1/4/5 prove nothing if the script never writes. Output was: [$A79_OUT]")
  elif ! grep -q 'FIXTURE-DEVIATION-ONE' "$A79_SNAP"; then
    A79_FAILURES+=("leg 3 (control): the fresh-merge snapshot does not hold the fixture's deviation")
  fi
  a79_cleanup

  # --- Leg 4: unmarked handover, 9.4h after the merge --------------------------
  # Nothing binds it to this PR and nothing measures it fresh. The `--auto` gate
  # permitted exactly this.
  a79_run '' "$A79_STALE" 901 'fix/some-branch' 'fix: a toolbox change' up
  if [[ -f "$A79_SNAP" ]]; then
    A79_FAILURES+=("leg 4: the fold snapshotted PR #901 9.4h after its merge from a handover that names no task at all — with neither binding nor recency established, the content is an assumption, and the assumption is what issue #154 measured going wrong")
  elif ! printf '%s\n' "$A79_OUT" | grep -q 'Skipping deviation snapshot'; then
    A79_FAILURES+=("leg 4: nothing was written and nothing was said — silence here reads to every caller as 'this PR had no deviations'. Output was: [$A79_OUT]")
  fi
  a79_cleanup

  # --- Leg 7: mismatch + FRESH — the leg that makes BINDING load-bearing -------
  # ⛔ WITHOUT THIS LEG THE BINDING CHECK IS NOT PINNED. ⛔ Leg 1's handover is
  # both mismatched AND 9.4h old, so a gate with no binding check at all —
  # "snapshot if the merge is inside the window, else refuse" — passes legs 1
  # through 6 untouched. Measured, not assumed: deleting the mismatch branch from
  # fold_handover_belongs_to_pr leaves every other leg green. This leg is the one
  # that fails, because here the clock says fresh and only the handover's own
  # trailing heading knows the work is somebody else's. That is issue #154's
  # first requested fix, and the reason it is first: it is the check that holds
  # when the flag AND the clock are both wrong.
  #
  # The refusal must also be DISTINGUISHABLE from the staleness one. Both name
  # the marker, so a message assertion that only looked for "140" would pass
  # against either — the operator has to be able to tell "this handover is not
  # yours" from "this merge is too old", because the remedies differ (fix the
  # marker or the PR's issue reference vs. re-run sooner).
  a79_run '# NEW TASK — issue #140: extract the deviation consumer into a real script' \
          "$A79_FRESH" 149 'feature/lessons-fast-tier-selection' \
          'fix(lessons): report every eviction Closes #144' \
          up
  if [[ -f "$A79_SNAP" ]]; then
    A79_FAILURES+=("leg 7: the fold snapshotted PR #149 seconds after its merge from a handover whose trailing heading names issue #140 — recency is a PROXY, and here it is the wrong one: the file says outright whose work it is, and it is not this PR's")
  elif ! printf '%s\n' "$A79_OUT" | grep -q 'names other work'; then
    A79_FAILURES+=("leg 7: the refusal did not identify itself as a BINDING refusal — a fresh merge refused with a staleness message tells the operator to re-run sooner, which cannot fix a mismatched marker. Output was: [$A79_OUT]")
  fi
  a79_cleanup

  # --- Leg 5: `gh` unavailable, so the merge age is unknowable ------------------
  a79_run '' '' 902 'fix/some-branch' 'fix: a toolbox change' down
  if [[ -f "$A79_SNAP" ]]; then
    A79_FAILURES+=("leg 5: the fold wrote a snapshot for PR #902 while it could not read the merge time at all — permitting what it could not evaluate is TL-0001, the fail-open class this repo keeps re-shipping")
  elif ! printf '%s\n' "$A79_OUT" | grep -q 'Skipping deviation snapshot'; then
    A79_FAILURES+=("leg 5: an unmeasurable merge age produced no message — the operator cannot tell a broken `gh` from a PR that genuinely had no deviations. Output was: [$A79_OUT]")
  fi
  a79_cleanup

  # --- leg 8: BRANCH-ONLY binding, with NO issue reference anywhere -----------
  # Isolates the branch predicate. The old single control supplied both a matching
  # branch AND `Closes #140`, so either predicate could be deleted with every leg
  # still green — the test could not tell them apart.
  A79_OLD=$(date -u -v-9H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "9 hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
  a79_run '# NEW TASK — branch feature/payments' "$A79_OLD" 401 'feature/payments' \
          'feat: payments work with no issue reference at all' up
  if [[ ! -f "$A79_SNAP" ]]; then
    A79_FAILURES+=("leg 8: a 9h-old merge whose handover names THIS PR's branch and no issue at all did NOT snapshot — the branch predicate alone must bind, or binding does not outrank the clock")
  fi

  # --- leg 9: the branch as a SUBSTRING of a different branch -----------------
  # `feature/payments` must NOT bind `feature/payments-v2`. Before the boundary
  # fix it did, so another task's handover was accepted as this PR's and recency
  # was bypassed — the mechanism built to stop cross-task capture performing it.
  a79_run '# NEW TASK — branch feature/payments-v2' "$A79_OLD" 402 'feature/payments' \
          'feat: payments work' up
  if [[ -f "$A79_SNAP" ]]; then
    A79_FAILURES+=("leg 9: branch feature/payments bound a handover naming feature/payments-v2 — the branch is matched as an unbounded SUBSTRING, so a sibling branch's deviations get filed under this PR")
  fi

  # --- leg 10: ISSUE-ONLY binding via a real closing keyword -----------------
  # Isolates the issue predicate: no branch match, but the PR genuinely closes the
  # issue the handover names.
  a79_run '# NEW TASK — issue #777: the work this handover belongs to' "$A79_OLD" 403 \
          'some/unrelated-branch' 'chore: tidy up. Closes #777' up
  if [[ ! -f "$A79_SNAP" ]]; then
    A79_FAILURES+=("leg 10: a 9h-old merge whose PR body CLOSES the issue its handover names did NOT snapshot — the issue predicate alone must bind")
  fi

  # --- leg 15: CONTROL — a PR with no closing keyword still folds ------------
  # ⛔ THIS IS A CONTROL, NOT A PIN, AND IT IS LABELLED SO DELIBERATELY. ⛔
  # A reviewer reported that grep exiting 1 on no-match aborts the fold under
  # `set -euo pipefail`. Measured against the real structure: it does NOT — the grep
  # chain is a NESTED substitution supplying an argument to `printf`, so the
  # assignment's status is `printf | sort`. Reverting the `|| true` leaves this leg
  # GREEN, which is how the mirror was caught: it cannot fail, so it pins nothing.
  # It is kept as a control — an ordinary chore PR with no issue reference anywhere
  # must still fold — and NOT presented as evidence for the guard.
  a79_run '# NEW TASK — branch chore/tidy-up' "$A79_OLD" 408 'chore/tidy-up' \
          'chore: tidy up some files, no issue references anywhere' up
  if [[ ! -f "$A79_SNAP" ]]; then
    A79_FAILURES+=("leg 15: a PR with no closing keyword produced no snapshot — grep exiting 1 on no-match aborts the fold under set -euo pipefail, so an ordinary chore PR captures nothing at all. Output was: [$A79_OUT]")
  fi

  # --- leg 12: a keyword INSIDE a longer word is not a closing reference ------
  # `Discloses #777` contains the substring `closes #777`. Without a LEFT word
  # boundary a PR that merely disclosed something claimed to close it.
  a79_run '# NEW TASK — issue #778: somebody else work' "$A79_OLD" 405 \
          'some/unrelated-branch' 'chore: writeup. Discloses #778 and closes #154' up
  if [[ -f "$A79_SNAP" ]]; then
    A79_FAILURES+=("leg 12: 'Discloses #778' was read as a closing reference — the keyword match has no left word boundary, so any word ENDING in a keyword claims ownership")
  fi

  # --- leg 13: a CROSS-REPO closing reference must bind -----------------------
  # GitHub honours `Fixes octo-org/octo-repo#100`. Dropping it is a FALSE NEGATIVE:
  # a correctly-bound handover is refused and its deviations lost silently.
  a79_run '# NEW TASK — issue #909: the work this handover belongs to' "$A79_OLD" 406 \
          'some/unrelated-branch' 'fix: the thing. Fixes octo-org/octo-repo#909' up
  if [[ ! -f "$A79_SNAP" ]]; then
    A79_FAILURES+=("leg 13: a cross-repo closing reference (owner/repo#909) did not bind — GitHub honours that form, so a correctly-bound handover is refused and its telemetry lost")
  fi

  # --- leg 14: a branch name continuation char is not a delimiter -------------
  # `@ + = ! , %` are legal in git refs. A boundary class built from "not a
  # branch character" still let `feature/payments` bind `feature/payments@v2`.
  a79_run '# NEW TASK — branch feature/payments@v2' "$A79_OLD" 407 'feature/payments' \
          'feat: payments' up
  if [[ -f "$A79_SNAP" ]]; then
    A79_FAILURES+=("leg 14: branch feature/payments bound a handover naming feature/payments@v2 — the boundary class was built from branch-name characters and @ is legal in a ref, so a sibling branch still cross-binds")
  fi

  # --- leg 11: a MENTIONED issue is not a CLOSED one -------------------------
  # `Closes #154; follow-up #777` must not claim #777. A mention is not ownership.
  a79_run '# NEW TASK — issue #777: somebody else work' "$A79_OLD" 404 \
          'some/unrelated-branch' 'fix: the real thing. Closes #154; follow-up #777' up
  if [[ -f "$A79_SNAP" ]]; then
    A79_FAILURES+=("leg 11: a PR that merely MENTIONS #777 (while closing #154) bound a handover headed issue #777 — every #N in the title/body is being read as a closing reference, so an unrelated task's deviations are filed here")
  fi

  if [[ ${#A79_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (a 9.4h-old merge whose handover names a different issue wrote nothing and named that issue; a same-age merge BOUND to its handover still snapshotted; a 30s-old merge with an unmarked handover snapshotted; the same unmarked handover 9.4h later and an unreadable merge time were each refused out loud; and no refusal left a snapshot, a .tmp or a damaged handover behind)"
  else
    # ⛔ THIS PRINTED ${A74_FAILURES[@]} — THE C0 TEST'S ARRAY, NOT THIS ONE'S. ⛔
    # A leftover from renumbering this test 74 -> 79. A failing leg would have
    # reported another test's failures, or none, so the message could never lead a
    # reader to the leg that actually broke. Same class as a test that cannot fail:
    # the assertion fires, the diagnosis does not.
    fail_test "$TC" "$(printf '%s; ' "${A79_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# TC-STL-75: the merge-authority decision is recorded, and every gate it claims
#            the hook still performs is really in the hook (issue #143)
#
# WHY THIS EXISTS. rules/git-workflow.md said "the agent never merges a PR on its
# own — every merge is user-commanded", while /merge-pr is an agent-side merge
# path the agent itself invokes. Both statements are true under one reading and
# contradictory under another, and the question was being re-derived on every
# toolbox PR. It was settled by falsifying a claim rather than by picking a side:
# the session memory asserted that PR #130 merging proved the auto-mode
# classifier does not block an APPROVED PR — tested on PR #135, which was
# APPROVED, not agent-authored that session, all gates green, and denied twice.
# What actually unblocked merging was the user adding `Bash(gh pr merge:*)` to
# `permissions.allow`. So the retirement of BARE self-merge stands, and the
# standing authorization is what makes the agent's `/merge-pr` invocation
# "user-commanded". It removes the PROMPT, never a CHECK.
#
# WHAT THIS TEST CAN AND CANNOT DO, stated before the assertions rather than
# after. Legs 1 and 3 are PROSE assertions — "a decision was recorded, with a
# date, and it says the hook needs no change." A prose assertion cannot tell you
# the decision is right; it only fails when the record is deleted or silently
# reworded past its own anchors. That is worth having (the record's whole purpose
# is to stop the re-derivation) and it is worth NOT overselling.
#
# LEG 2 IS THE ONE THAT EARNS ITS KEEP, and it is a TL-0019 detector: the record
# claims `pr-action-safety.sh` still live-re-verifies five specific gates on
# every merge, and that claim is exactly the kind this repo keeps shipping false.
# So each claimed gate is paired with the CODE that performs it, and BOTH halves
# are required — the record must name the gate AND the hook must implement it on
# a code line. Strip a check from the hook and the record's "no change needed"
# becomes a lie; this leg goes red for it. The honest limit: the pairs table
# lives in this test, so a SIXTH gate added to the prose with no code behind it
# is not caught. It pins the five that the decision actually rests on.
#
# LEGS 4 AND 5 ARE CONTROLS, green before and after. They are what stops the
# documentation change from quietly buying itself authority:
#   4 — a PR touching knowledge/toolbox-lessons.yml is still never agent-merged
#       (the R2 carve-out). Those entries are injected into every future review
#       prompt, so they get a human read regardless of who is authorized.
#   5 — Step 5.5 still does not merge: no `gh pr merge` and no merge-gate marker
#       creation anywhere in review-pr.md's code. The decision corrects what the
#       file SAYS about merge authority; it must not change what /review-pr DOES.
# ---------------------------------------------------------------------------
TC="TC-STL-75: the merge-authority decision is recorded and its hook claims are true of the hook"
A75_RULES="$(cd "$(dirname "$0")/.." && pwd)/rules/git-workflow.md"
A75_HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/pr-action-safety.sh"
if [[ ! -f "$A75_RULES" || ! -f "$A75_HOOK" ]]; then
  fail_test "$TC" "cannot locate rules/git-workflow.md ($A75_RULES) or hooks/pr-action-safety.sh ($A75_HOOK)"
else
  A75_FAILURES=()

  # The decision's own section, cut from its `### Decision` heading to the next
  # heading of any level. Scanned as PROSE, deliberately: this suite's
  # code_*_lines_in helpers drop every line starting with `#`, which in a
  # markdown file is every heading — they are the wrong tool for a document.
  A75_SECTION=$(awk '
    started && /^#+ / { exit }
    /^### Decision/  { started = 1 }
    started          { print }
  ' "$A75_RULES")

  # --- Leg 1 (PROSE): the decision exists, is dated, and names its scope -------
  if [[ -z "$A75_SECTION" ]]; then
    A75_FAILURES+=("leg 1 (prose): no '### Decision' section in rules/git-workflow.md — issue #143 asks for ONE decision recorded with a date so the merge-authority question stops being re-derived on every toolbox PR")
  else
    printf '%s\n' "$A75_SECTION" | grep -qE '20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]' \
      || A75_FAILURES+=("leg 1 (prose): the decision section carries no ISO date — an undated decision cannot be told apart from a claim someone edited in later, which is how the falsified memory survived as long as it did")
    printf '%s\n' "$A75_SECTION" | grep -q 'ai-engineering' \
      || A75_FAILURES+=("leg 1 (prose): the decision section does not name baselito/ai-engineering — the standing authorization was granted for the toolbox repo, and a decision that reads as repo-agnostic is a wider claim than the one that was made")
    printf '%s\n' "$A75_SECTION" | grep -q '/merge-pr' \
      || A75_FAILURES+=("leg 1 (prose): the decision section never names /merge-pr, the command whose invocation the authorization makes 'user-commanded' — without it the decision does not say what it licenses")
    printf '%s\n' "$A75_SECTION" | grep -qi 'prompt' \
      || A75_FAILURES+=("leg 1 (prose): the decision section does not say what the authorization removes. 'It removes the prompt, never a check' is the load-bearing half — omit it and the record reads as permission to skip gates")
  fi

  # --- Leg 2 (TL-0019): every gate the record claims must be in the hook ------
  # One row per claimed gate: the token that must appear in the decision section,
  # and the CODE that must perform it in hooks/pr-action-safety.sh. Both halves
  # required — a claim with no code is the defect this repo keeps re-shipping,
  # and code with no claim means the record undersells the gate it rests on.
  # Tab-separated so the ERE column can contain spaces.
  #
  # The claim tokens are phrases, not abbreviations, because a two-letter token is
  # not an assertion: `CI` alone is a substring of `DECISION`, so that row would
  # have passed against practically any prose — including a section that never
  # mentions CI at all. `CI green` cannot be satisfied by accident.
  A75_PAIRS='OPEN	"\$LIVE_STATE"[[:space:]]*==[[:space:]]*"OPEN"
mergeable	"\$LIVE_MERGEABLE"[[:space:]]*==[[:space:]]*"MERGEABLE"
CI green	"\$MERGE_OK"[[:space:]]*==[[:space:]]*"true"
CHANGES_REQUESTED	"\$LIVE_REVIEW_DECISION"[[:space:]]*!=[[:space:]]*"CHANGES_REQUESTED"
unresolved	"\$UNRESOLVED"[[:space:]]*==[[:space:]]*"0"'
  while IFS=$'\t' read -r a75_claim a75_re; do
    [[ -z "$a75_claim" ]] && continue
    if ! printf '%s\n' "$A75_SECTION" | grep -q -- "$a75_claim"; then
      A75_FAILURES+=("leg 2: the decision section never names the '$a75_claim' gate, yet the decision's whole basis is that pr-action-safety.sh still live-verifies every gate on a user-commanded merge — a record that lists fewer gates than the hook performs understates what the authorization is safe because of")
    fi
    A75_HITS=$(code_re_lines_in "$A75_HOOK" "$a75_re" | grep -c . || true)
    if [[ "$A75_HITS" -lt 1 ]]; then
      A75_FAILURES+=("leg 2: rules/git-workflow.md claims the hook still verifies '$a75_claim', but no CODE line in hooks/pr-action-safety.sh matches /$a75_re/ — the record now overclaims what the guard covers (TL-0019). Either the hook lost a check or the record gained one it never had")
    fi
  done <<< "$A75_PAIRS"

  # --- Leg 3 (PROSE): the no-hook-change conclusion is stated, not implied -----
  # Issue #143's third open criterion, in its own words: state it explicitly
  # rather than leaving it an implied no-op, so the next reader does not reopen
  # it. An unstated no-op is indistinguishable from an oversight.
  if ! printf '%s\n' "$A75_SECTION" | grep -q 'pr-action-safety.sh'; then
    A75_FAILURES+=("leg 3 (prose): the decision section never names hooks/pr-action-safety.sh — 'no hook change is needed under this decision' has to be written down, or the next reader re-opens the question exactly as issue #143 did")
  fi

  # --- Leg 4 (CONTROL — green before AND after): R2 survives -------------------
  A75_R2_DETECT=$(code_re_lines_in "$CONSUMER_MD" 'knowledge/toolbox-lessons\.yml' | grep -c . || true)
  A75_R2_SET=$(code_re_lines_in "$CONSUMER_MD" 'LESSONS_PR_CARVEOUT=true' | grep -c . || true)
  A75_R2_GUARD=$(code_re_lines_in "$CONSUMER_MD" 'LESSONS_PR_CARVEOUT[^=]*==[[:space:]]*"true"' | grep -c . || true)
  if [[ "$A75_R2_DETECT" -lt 1 || "$A75_R2_SET" -lt 1 || "$A75_R2_GUARD" -lt 1 ]]; then
    A75_FAILURES+=("leg 4 (control): the R2 lessons carve-out is not intact in commands/review-pr.md CODE (detect=$A75_R2_DETECT set=$A75_R2_SET guard=$A75_R2_GUARD, each expected >=1) — a PR touching knowledge/toolbox-lessons.yml must never be agent-merged, because those entries are injected into every future review prompt and need the human read regardless of what any merge authorization says")
  fi

  # --- Leg 5 (CONTROL — green before AND AFTER): Step 5.5 scoped merge ---
  # The decision permits only the toolbox path to merge. Project repos and the
  # lessons carve-out must remain notification/manual paths. Check the actual
  # guarded region, not independent needles that can drift apart.
  #
  # ⛔ THE MARKER COUNT IS THE LOAD-BEARING HALF. ⛔ pr-action-safety.sh accepts a
  # merge in exactly two shapes, and BOTH require `~/.claude/.pr-merge-gate-…` to
  # exist (the combined form creates it in the same command). A review-pr.md that
  # never writes that marker therefore cannot merge anything past the hook, no
  # matter what else it contains — so this is the assertion that actually holds.
  #
  # The merge invocation must be inside the explicit toolbox + lessons guard.
  # There are exactly two intentional executable merge forms in this command:
  # one guarded auto-poll action and one explicit user-commanded fallback. Any
  # additional merge line outside those forms is a regression, even if one
  # valid guarded line remains.
  A75_MERGE_CALLS=$(code_re_lines_in "$CONSUMER_MD" '^[[:space:]]*(touch[^&]*&&[[:space:]]*)?gh pr merge' | grep -c . || true)
  A75_MARKER_TOUCH=$(code_re_lines_in "$CONSUMER_MD" 'touch .*\.pr-merge-gate' | grep -c . || true)
  if [[ "$A75_MERGE_CALLS" -lt 1 || "$A75_MARKER_TOUCH" -lt 1 ]]; then
    A75_FAILURES+=("leg 5 (control): commands/review-pr.md is missing the scoped toolbox merge form (merge calls=$A75_MERGE_CALLS, marker forms=$A75_MARKER_TOUCH)")
  fi
  A75_SCOPE_START=$(code_re_lines_in "$CONSUMER_MD" 'TOOLBOX_AUTO_MERGE_BEGIN=true' | head -1)
  A75_SCOPE_END=$(code_re_lines_in "$CONSUMER_MD" 'TOOLBOX_AUTO_MERGE_END=true' | head -1)
  if [[ -z "$A75_SCOPE_START" || -z "$A75_SCOPE_END" || "$A75_SCOPE_END" -le "$A75_SCOPE_START" ]]; then
    A75_FAILURES+=("leg 5 (control): toolbox auto-merge guard region is missing or malformed")
  else
    A75_SCOPED_MERGES=$(code_re_lines_in "$CONSUMER_MD" '^[[:space:]]*gh pr merge' | lines_between "$A75_SCOPE_START" "$A75_SCOPE_END")
    A75_SCOPED_GATE=$(code_re_lines_in "$CONSUMER_MD" 'IS_TOOLBOX_REPO.*true.*LESSONS_PR_CARVEOUT|LESSONS_PR_CARVEOUT.*false' | lines_between "$A75_SCOPE_START" "$A75_SCOPE_END")
    A75_FALLBACK_START=$(code_re_lines_in "$CONSUMER_MD" 'For that explicit human-commanded fallback' | head -1)
    A75_FALLBACK_END=$(code_re_lines_in "$CONSUMER_MD" 'Read the PR state back separately' | head -1)
    if [[ -z "$A75_FALLBACK_START" || -z "$A75_FALLBACK_END" || "$A75_FALLBACK_END" -le "$A75_FALLBACK_START" ]]; then
      A75_FAILURES+=("leg 5 (control): the explicit marker-bound fallback region is missing or malformed")
    else
      A75_VALID_COMBINED=$(code_re_lines_in "$CONSUMER_MD" 'touch ~/.claude/\.pr-merge-gate-baselito-ai-engineering-<N> && gh pr merge <N> --repo baselito/ai-engineering --squash --delete-branch' | lines_between "$A75_FALLBACK_START" "$A75_FALLBACK_END")
      A75_FALLBACK_MARKER_TOUCH=$(code_re_lines_in "$CONSUMER_MD" 'touch .*\.pr-merge-gate' | lines_between "$A75_FALLBACK_START" "$A75_FALLBACK_END")
      if [[ "$A75_MERGE_CALLS" -ne 2 || "$A75_SCOPED_MERGES" -ne 1 || "$A75_VALID_COMBINED" -ne 1 || "$A75_FALLBACK_MARKER_TOUCH" -ne 1 || "$A75_SCOPED_GATE" -lt 1 ]]; then
        A75_FAILURES+=("leg 5 (control): merge invocations are not limited to one guarded GoalRun form plus one exact marker-bound fallback (total merges=$A75_MERGE_CALLS, scoped merges=$A75_SCOPED_MERGES, fallback forms=$A75_VALID_COMBINED, fallback markers=$A75_FALLBACK_MARKER_TOUCH, scoped gates=$A75_SCOPED_GATE)")
      fi
    fi
  fi

  # --- Leg 6: nowhere may repeat the OBSERVATION without naming the MECHANISM --
  # ⛔ THE DECISION IS RECORDED ONCE; EVERY OTHER FILE MUST CITE, NOT RE-DERIVE. ⛔
  # The denial wording on PRs #110–#123 named same-session authorship, so four
  # files independently wrote that authorship down as the REASON a merge is
  # blocked. It is not: PR #135 was APPROVED, not agent-authored that session,
  # all gates green, denied twice. What actually unblocked merging was the user
  # adding `Bash(gh pr merge:*)` to `permissions.allow`.
  #
  # Left alone, `commands/merge-pr.md`'s own header contradicted the decision in
  # the rule it cites, one file apart — the prose-drifts-from-code class (TL-0019)
  # with both halves in prose. A per-file spot check would have to be re-written
  # every time a fifth file repeats it, so this is a REPO-WIDE rule instead: any
  # markdown that still carries the same-session observation must also name
  # `permissions.allow`, the one unambiguous token for what really happened.
  # Keeping the observation is fine and in the incident history it is correct —
  # what is not fine is stating it with no sign that the reading was corrected.
  #
  # ⛔ THE FIRST VERSION OF THIS LEG WAS INERT, AND HOW IT DIED IS THE LESSON. ⛔
  # It triggered on the FALSE PHRASE itself ("authored in the same session"), and
  # required any file carrying it to also name `permissions.allow`. That made the
  # fix able to disarm the detector: correcting merge-pr.md removed the phrase, so
  # the file stopped being scanned at all. MEASURED — with the corrected header in
  # place, deleting BOTH `permissions.allow` mentions from merge-pr.md left the
  # suite at "All 78 tests passed". A guard that only watches files still carrying
  # the defect stops watching the moment the defect is fixed, which is the exact
  # inert-detector shape this file is arranged against (TL-0002).
  #
  # So the trigger is now the TOPIC, not the error: a file that ASSERTS the
  # retirement or a denial is a file explaining why an autonomous merge does not
  # happen, and it must say what makes a COMMANDED one run without a prompt —
  # either by naming `permissions.allow` or by citing the decision by name.
  # Citing `rules/git-workflow.md` alone is deliberately NOT enough: the pre-fix
  # merge-pr.md already cited that file (for the merge command's shape) while
  # contradicting its decision, so a bare filename reference is exactly the
  # anchor that passed over the defect.
  #
  # SCOPE — and `docs/` is excluded on a measurement, not a hunch. Three files
  # there (docs/concepts/skills.md, docs/reference/external-commands.md,
  # docs/reference/skill-list.md) match the trigger only inside a skill-catalog
  # row listing "why autonomous self-merge is retired" as one of the
  # `pr-automation` skill's TOPICS. Naming a topic asserts no mechanism, so
  # requiring the anchor there would be noise a future author has to satisfy
  # without learning anything. The scanned scope is the normative set: the rule,
  # the commands, the skills, and the repo's agent instructions.
  #
  # HONEST LIMIT: the anchor proves the correction is PRESENT in the file, not
  # that the sentence around it is right. Legs 1-3 cover the record itself.
  A75_REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  A75_SIG='self-merge (is )?retired|classifier denie|denies .{0,20}merge'
  A75_ANCHOR='permissions\.allow|standing authorization satisfies'
  A75_CARRIERS=0
  A75_ORPHANS=""
  while IFS= read -r a75_f; do
    [[ -z "$a75_f" ]] && continue
    A75_CARRIERS=$((A75_CARRIERS + 1))
    grep -qE "$A75_ANCHOR" "$a75_f" 2>/dev/null \
      || A75_ORPHANS="$A75_ORPHANS ${a75_f#$A75_REPO_ROOT/}"
  done <<< "$(grep -rlE "$A75_SIG" --include='*.md' \
      "$A75_REPO_ROOT/rules" "$A75_REPO_ROOT/commands" "$A75_REPO_ROOT/skills" \
      "$A75_REPO_ROOT/CLAUDE.md" 2>/dev/null)"

  # VACUITY GUARD. rules/git-workflow.md asserts the retirement in its own opening
  # line, so the carrier set can never legitimately be empty. Zero means the scan
  # stopped finding anything — a reworded trigger, a moved file, a broken glob —
  # and a scan that finds nothing reports every file as correct.
  if [[ "$A75_CARRIERS" -eq 0 ]]; then
    A75_FAILURES+=("leg 6: the retirement/denial trigger matched NO file in the normative scope, but rules/git-workflow.md asserts the retirement in its opening line — the scan is looking at the wrong thing, and a scan that finds nothing passes every file including the ones that regressed")
  elif [[ -n "$A75_ORPHANS" ]]; then
    A75_FAILURES+=("leg 6: these file(s) assert that autonomous merging is retired/denied without naming permissions.allow OR citing the decision by name:$A75_ORPHANS — a file that explains why an autonomous merge does not happen must also say what makes a COMMANDED one run without a prompt, or it re-derives the mechanism and drifts. Note a bare 'rules/git-workflow.md' mention does NOT count: the pre-fix merge-pr.md cited that file for the merge command's shape while contradicting its decision")
  fi

  # --- Leg 6b (CONTROL — green before AND after): merge-pr.md keeps the CHECK --
  # The correction removes a false MECHANISM from that header. It must not touch
  # what makes the merge safe: the sanctioned marker form and the hook that
  # live-verifies behind it. Standing authorization removes the prompt, never
  # this.
  A75_MERGE_MD="$A75_REPO_ROOT/commands/merge-pr.md"
  if [[ ! -f "$A75_MERGE_MD" ]]; then
    A75_FAILURES+=("leg 6b (control): cannot locate commands/merge-pr.md")
  else
    grep -q 'pr-action-safety\.sh' "$A75_MERGE_MD" \
      || A75_FAILURES+=("leg 6b (control): commands/merge-pr.md no longer names hooks/pr-action-safety.sh — the hook IS why a standing authorization is safe, so a header that stops naming it has removed the check along with the false mechanism")
    grep -q '\.pr-merge-gate' "$A75_MERGE_MD" \
      || A75_FAILURES+=("leg 6b (control): commands/merge-pr.md no longer names the .pr-merge-gate marker — that marker is the only shape the hook accepts, and dropping it from the command's own documentation is how the sanctioned form gets reshaped into one that is denied")
  fi

  if [[ ${#A75_FAILURES[@]} -eq 0 ]]; then
    pass_test "$TC (a dated, repo-scoped decision names /merge-pr and what the authorization removes; all five gates it rests on are named in the record AND performed on code lines in pr-action-safety.sh; the hook remains in place; the R2 carve-out and Step 5.5's scoped toolbox form are intact; and all $A75_CARRIERS file(s) still carrying the same-session observation name permissions.allow, with merge-pr.md keeping the hook and the marker)"
  else
    fail_test "$TC" "$(printf '%s; ' "${A75_FAILURES[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
# ---------------------------------------------------------------------------
# TC-STL-78: a NUL BYTE IN handover.md STILL YIELDS A PARSABLE SNAPSHOT, WITH THE
# SURROUNDING TEXT INTACT.
#
# The C0 lookup in the fold covers 0x01-0x1F. `index()` is 1-based, so position 0
# cannot be represented; a NUL reaching json_escape falls to the pass-through branch
# and is emitted RAW — an unparsable snapshot, i.e. the permanent stranding the whole
# C0 sweep exists to prevent.
#
# Why this needs its OWN case rather than one more byte in TC-STL-74's fixture: the
# failure mode is PLATFORM-DEPENDENT. On the macOS system awk the record is truncated
# at the first NUL (measured: printf 'A\000B\n' | awk '{print length($0)}' prints 1),
# so json_escape never sees one and the bug is invisible. On gawk the NUL survives the
# record and the bug is live. A fixture running only on macOS reports green either
# way — which is what happened, and what the reviewer on PR #162 flagged five times.
#
# The fold now strips NUL before any awk sees it, so both platforms behave alike.
# Three properties are asserted, not just "it parsed":
#   1. the snapshot is valid JSON;
#   2. the text on BOTH SIDES of the NUL survives — a "fix" that dropped the record
#      or truncated at the NUL would also produce valid JSON;
#   3. a neighbouring C0 byte is still ESCAPED, so the strip did not become a
#      blanket control-byte deletion.
TC="TC-STL-78: a NUL in handover.md yields parsable JSON with surrounding text intact (executed)"
A78_REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
a78_home=$(mktemp -d); a78_repo="$a78_home/repo"
mkdir -p "$a78_home/.claude" "$a78_repo/.claude"
git -C "$a78_repo" init -q 2>/dev/null
git -C "$a78_repo" remote add origin https://github.com/baselito/ai-toolbox.git 2>/dev/null

# A NUL cannot survive a shell variable, so write the fixture with printf directly.
{
  printf '## Implementation\n\n### Deviations\n\n'
  printf -- '- **Guard fail-open** \000 NUL here and \033 an ESC here, tail text\n'
  printf '\n'
} > "$a78_repo/.claude/handover.md"

a78_bin="$a78_home/bin"; mkdir -p "$a78_bin"
a78_merged=$(date -u -v-30S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d "30 seconds ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
{
  printf '#!/bin/sh\n'
  printf 'printf "%s\\t%s\\t%s\\n" "%s" "fixture/branch" "fixture title body"\n' "$a78_merged"
} > "$a78_bin/gh"
chmod +x "$a78_bin/gh"
a78_out=$(HOME="$a78_home" PATH="$a78_bin:$PATH" bash "$A78_REPO_ROOT/scripts/pr-postmerge-fold.sh" \
            baselito ai-engineering 178 "$a78_repo" 2>&1)
a78_snap="$a78_home/.claude/pending-deviations-178.log"

if [[ ! -f "$a78_snap" ]]; then
  fail_test "$TC" "no snapshot written. Fold said: $(printf '%s' "$a78_out" | head -2 | tr '\n' ' ')"
elif ! jq -e . "$a78_snap" >/dev/null 2>&1; then
  fail_test "$TC" "snapshot is not valid JSON, so a NUL still reaches the output raw: $(head -c 160 "$a78_snap" | cat -v)"
elif ! jq -r '.body' "$a78_snap" 2>/dev/null | grep -q 'tail text'; then
  fail_test "$TC" "the text AFTER the NUL is missing — the record was truncated rather than the NUL removed"
elif ! jq -r '.body' "$a78_snap" 2>/dev/null | grep -q 'NUL here'; then
  fail_test "$TC" "the text BEFORE the NUL is missing"
elif [[ "$(tr -cd '\000' < "$a78_snap" | wc -c | tr -d ' ')" != "0" ]]; then
  fail_test "$TC" "a raw NUL byte survived into the snapshot"
elif ! grep -q 'u001b' "$a78_snap"; then
  fail_test "$TC" "the neighbouring ESC is no longer escaped — the NUL strip became a blanket control-byte deletion"
else
  pass_test "$TC" "a NUL and an ESC in one deviation body: snapshot parses, text on both sides of the NUL survives, zero raw NUL bytes, and the ESC is still \\u001b"
fi
rm -rf "$a78_home"

TOTAL=$((PASS + FAIL))

# ⛔ THE EXPECTED-TOTAL BACKSTOP — A COMPARISON, NOT A COMMENT. ⛔
# Raise this by hand, in the SAME commit, whenever you add or remove a
# pass_test/fail_test call. That manual step is the entire point: it forces a
# human to look at the new assertion once. Verified by injecting a test case
# whose assertion calls a helper that does not exist, in this suite's own
# `$( … 2>/dev/null )` idiom: it PASSES vacuously (the substitution is empty and
# `[[ "" -eq 0 ]]` is true), prints nothing on stderr, and at 906a6c3 the run
# ended "All 52 tests passed." exit 0. With this comparison it exits 1 and
# names the drift. See the header note for what this check does NOT prove.
EXPECTED_TOTAL=80
if [[ "$TOTAL" -ne "$EXPECTED_TOTAL" ]]; then
  TOTAL_DRIFTED=true
else
  TOTAL_DRIFTED=false
fi

if [[ $FAIL -eq 0 ]]; then
  printf "  All %d tests passed.\n" "$TOTAL"
else
  printf "  %d/%d tests FAILED:\n" "$FAIL" "$TOTAL"
  for t in "${FAILED_TESTS[@]}"; do
    printf "    - %s\n" "$t"
  done
fi

# Reported AFTER the pass/fail lines and checked INDEPENDENTLY of them, because
# the two say different things: `FAIL` counts assertions that ran and were
# wrong, `TOTAL_DRIFTED` says the SET of assertions that ran is not the set this
# file claims to run. A green run with a drifted total is the more dangerous of
# the two, so it must not be able to hide behind a green pass count.
if [[ "$TOTAL_DRIFTED" == "true" ]]; then
  printf "\n  ⛔ SUITE TOTAL DRIFTED: %d assertion(s) ran, EXPECTED_TOTAL says %d.\n" "$TOTAL" "$EXPECTED_TOTAL"
  printf "     If you added or removed coverage, update EXPECTED_TOTAL at the bottom of\n"
  printf "     %s in the same commit.\n" "$(basename "${BASH_SOURCE[0]}")"
  printf "     If you did NOT, the set of assertions that ran is not the set this file\n"
  printf "     claims: a TC skipped by a missing fixture, a deleted pass_test, or a new\n"
  printf "     assertion whose helper does not exist and passed vacuously.\n"
  exit 1
fi

[[ $FAIL -eq 0 ]] || exit 1

exit 0
