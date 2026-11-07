#!/usr/bin/env bash
# test-merge-gate-dedupe.sh
#
# Unit tests for the merge-gate statusCheckRollup dedupe transform shared by
# three production sites:
#   - hooks/pr-action-safety.sh          (LIVE_FAILING)
#   - commands/review-pr.md Step 5.5     (FAILING_OR_PENDING)
#   - commands/review-pr.md Step 5.4     (S54_LATEST — automated-review-scoped variant)
#
# WHY these test cases exist:
#   PR #99 fixed a "permanently un-mergeable" bug by deduping the rollup to
#   the latest run per check name. A security + code review pass on that fix
#   (commit 1396f37) found a CRITICAL race (an in-flight rerun with a null
#   startedAt could be shadowed by a stale completed entry) plus a HIGH
#   cross-workflow collision (two workflows emitting the same check name) and
#   two MEDIUM gaps (legacy StatusContext timestamps, non-deterministic ties).
#   This harness pins the hardened transform's behaviour against fixture JSON
#   so a future edit cannot silently regress any of these cases.
#
# The transform under test is a pure jq expression — no gh/network calls are
# needed. It is EXTRACTED VERBATIM from the production hook at test runtime
# (between the MERGE-GATE-DEDUPE-JQ-BEGIN/END markers in
# hooks/pr-action-safety.sh), so the fixtures exercise the exact expression
# that ships — a future edit to the hook cannot silently drift away from this
# test (Codex P2 on the Wave-1b review). A separate 3-site consistency check
# below also fails the run if the group-key core in commands/review-pr.md's
# two sites diverges from the hook's.
#
# Test cases (assert exact counts):
#   TC-MGD-1: PR #99 case — same-name CANCELLED x4 (older) + SUCCESS (newer) → 0
#   TC-MGD-2: Pending in-group — CANCELLED(old) + QUEUED(no timestamp) → 1
#   TC-MGD-3: Cross-workflow collision — same job name, different workflows,
#             one SUCCESS (newer) one FAILURE (older) → 1
#   TC-MGD-4: Legacy StatusContext — {context,state:FAILURE,createdAt newer}
#             beats a same-name CheckRun SUCCESS (older startedAt) → 1
#   TC-MGD-5: Equal-timestamp tie — SUCCESS + CANCELLED, identical startedAt,
#             both array orders → 1 both ways (fail-closed, order-independent)
#   TC-MGD-6: Empty/null rollup → 0
#   TC-MGD-7: Genuine latest FAILURE → 1
#   TC-MGD-8: Cross-APP collision with blank workflowName — two non-Actions
#             apps posting the same check name are distinguished by the URL
#             origin of detailsUrl/targetUrl; app B's older FAILURE must not
#             be masked by app A's newer SUCCESS → 1
#   TC-MGD-10: stale empty-conclusion entry (older) + newer SUCCESS → 0
#              (PR #130 — a superseded "" entry must not block the gate)
#   TC-MGD-11: newest entry empty-conclusion → 1 (fail-closed; the TC-MGD-10
#              fix must NOT open an under-block on an unknown latest state)
#   TC-MGD-9: 3-site consistency — the group-key core in the two
#             commands/review-pr.md sites matches the hook's (normalized)
#
# Usage:
#   ./scripts/test-merge-gate-dedupe.sh
# Exits 0 if all tests pass, 1 otherwise.

set -uo pipefail

PASS=0
FAIL=0
FAILED_TESTS=()

# ---------------------------------------------------------------------------
# The canonical transform — EXTRACTED VERBATIM from the production hook at
# runtime (between the MERGE-GATE-DEDUPE-JQ-BEGIN/END markers), so these
# fixtures always test the exact expression that ships. Semantics:
#   - group by (check name, workflow name, URL origin) — cross-workflow AND
#     cross-app same-name checks stay distinct (non-Actions apps have a blank
#     workflowName; the detailsUrl/targetUrl origin is the app proxy)
#   - a group is non-passing if ANY entry is genuinely in-flight
#     (PENDING/IN_PROGRESS/QUEUED/EXPECTED) — a queued rerun reports state
#     QUEUED, so the null-startedAt race stays closed. An empty-string effective
#     status ("" — both conclusion AND state null) is deliberately NOT counted
#     as in-flight: a SUPERSEDED check-run left with an empty conclusion must not
#     block the gate forever (PR #130). An "" entry is judged only by the
#     max-timestamp clause below — it blocks only if it is the group's newest.
#   - otherwise, a group is non-passing if ANY entry at the group's MAXIMUM
#     timestamp (startedAt // completedAt // createdAt) is not
#     SUCCESS/SKIPPED/NEUTRAL — ties resolve fail-closed and are
#     order-independent
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_FILE="$SCRIPT_DIR/../hooks/pr-action-safety.sh"

if [[ ! -f "$HOOK_FILE" ]]; then
  echo "FATAL: cannot find $HOOK_FILE to extract the canonical jq" >&2
  exit 1
fi

# Pull the marked block, then capture the single-quoted jq program inside it.
# perl -0777 slurps the whole block; the greedy (.*) up to the LAST '') grabs
# the full multi-line program between  | jq '  and  ') .
MARKED_BLOCK=$(sed -n '/# MERGE-GATE-DEDUPE-JQ-BEGIN/,/# MERGE-GATE-DEDUPE-JQ-END/p' "$HOOK_FILE")
CANONICAL_JQ=$(printf '%s' "$MARKED_BLOCK" | perl -0777 -ne "print \$1 if /\\|\\s*jq\\s*'(.*)'\\)/s")

if [[ -z "$CANONICAL_JQ" ]]; then
  echo "FATAL: failed to extract the jq program from $HOOK_FILE (markers or wrapper shape changed?)" >&2
  exit 1
fi

# Run the canonical transform against a JSON fixture and assert the resulting
# count matches expected. Args: <test-name> <json-fixture> <expected-count>
assert_count() {
  local test_name="$1"
  local fixture="$2"
  local expected="$3"
  local got

  got=$(printf '%s' "$fixture" | jq "$CANONICAL_JQ" 2>&1)

  if [[ "$got" == "$expected" ]]; then
    PASS=$((PASS + 1))
    printf '  PASS: %s (count=%s)\n' "$test_name" "$got"
  else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$test_name: expected $expected, got $got")
    printf '  FAIL: %s — expected %s, got %s\n' "$test_name" "$expected" "$got"
  fi
}

echo ""
echo "=== test-merge-gate-dedupe.sh ==="
echo ""

# ---------------------------------------------------------------------------
# TC-MGD-1: PR #99 case — 4 permanently-CANCELLED entries from superseded
# runs, plus a strictly-newer SUCCESS. Must resolve to 0 (not stuck failing).
# ---------------------------------------------------------------------------
FIXTURE_1='{"statusCheckRollup":[
  {"name":"automated-review-approval-gate","conclusion":"CANCELLED","startedAt":"2026-01-01T00:00:00Z"},
  {"name":"automated-review-approval-gate","conclusion":"CANCELLED","startedAt":"2026-01-01T00:01:00Z"},
  {"name":"automated-review-approval-gate","conclusion":"CANCELLED","startedAt":"2026-01-01T00:02:00Z"},
  {"name":"automated-review-approval-gate","conclusion":"CANCELLED","startedAt":"2026-01-01T00:03:00Z"},
  {"name":"automated-review-approval-gate","conclusion":"SUCCESS","startedAt":"2026-01-01T00:10:00Z"}
]}'
assert_count "TC-MGD-1: PR #99 stale CANCELLED residue + newer SUCCESS → 0" "$FIXTURE_1" "0"

# ---------------------------------------------------------------------------
# TC-MGD-2: A freshly QUEUED rerun (no timestamps at all) alongside an older
# completed CANCELLED entry. The in-flight member must block the group even
# though it has no timestamp to compete on — this is the CRITICAL race fix.
# ---------------------------------------------------------------------------
FIXTURE_2='{"statusCheckRollup":[
  {"name":"build","conclusion":"CANCELLED","startedAt":"2026-01-01T00:00:00Z"},
  {"name":"build","conclusion":"QUEUED"}
]}'
assert_count "TC-MGD-2: in-flight QUEUED rerun (no timestamp) blocks group → 1" "$FIXTURE_2" "1"

# ---------------------------------------------------------------------------
# TC-MGD-3: Same check name ("test") emitted by two different workflows.
# Workflow A is SUCCESS (newer), workflow B is FAILURE (older). Grouping by
# name alone would merge these and let A's SUCCESS mask B's FAILURE. Grouping
# by (name, workflowName) keeps them separate — B's group must still fail.
# ---------------------------------------------------------------------------
FIXTURE_3='{"statusCheckRollup":[
  {"name":"test","workflowName":"A","conclusion":"SUCCESS","startedAt":"2026-01-01T00:10:00Z"},
  {"name":"test","workflowName":"B","conclusion":"FAILURE","startedAt":"2026-01-01T00:00:00Z"}
]}'
assert_count "TC-MGD-3: cross-workflow same-name collision → 1 (B fails independently)" "$FIXTURE_3" "1"

# ---------------------------------------------------------------------------
# TC-MGD-4: Legacy StatusContext (context/state, only createdAt) reporting
# FAILURE alongside a same-name modern CheckRun SUCCESS. With `__typename` in
# the group key these are DISTINCT checks in separate groups (a check run and
# a commit status are different things — automated-review 🔴 on PR #101) — the failing
# legacy status blocks regardless of timestamps. The createdAt fallback still
# orders entries WITHIN all-StatusContext groups.
# ---------------------------------------------------------------------------
FIXTURE_4='{"statusCheckRollup":[
  {"__typename":"StatusContext","context":"ci/legacy","state":"FAILURE","createdAt":"2026-01-01T00:10:00Z"},
  {"__typename":"CheckRun","name":"ci/legacy","conclusion":"SUCCESS","startedAt":"2026-01-01T00:00:00Z"}
]}'
assert_count "TC-MGD-4: legacy StatusContext FAILURE not masked by same-name CheckRun → 1" "$FIXTURE_4" "1"

# ---------------------------------------------------------------------------
# TC-MGD-4b: Same as 4 but the CheckRun SUCCESS is NEWER and both share the
# SAME github.com origin — only the __typename key component separates them.
# Pre-__typename this collapsed to one group and the newer SUCCESS masked the
# legacy FAILURE.
# ---------------------------------------------------------------------------
FIXTURE_4B='{"statusCheckRollup":[
  {"__typename":"StatusContext","context":"lint","state":"FAILURE","createdAt":"2026-01-01T00:00:00Z","targetUrl":"https://github.com/x/y/1"},
  {"__typename":"CheckRun","name":"lint","conclusion":"SUCCESS","startedAt":"2026-01-01T00:10:00Z","detailsUrl":"https://github.com/x/y/2"}
]}'
assert_count "TC-MGD-4b: __typename splits CheckRun vs StatusContext on same origin → 1" "$FIXTURE_4B" "1"

# ---------------------------------------------------------------------------
# TC-MGD-4c/4d: createdAt ordering WITHIN an all-StatusContext group (same
# context name, same type, same origin → one group). GitHub keeps only the
# latest status per context, but the dedupe must still order correctly if
# multiple appear. 4c: newer FAILURE via createdAt → blocks. 4d: newer
# SUCCESS via createdAt → passes (older failure superseded). These directly
# assert the `.createdAt` fallback in the max-timestamp key (automated-review 🟡:
# the 4-rewrite had dropped this direct assertion).
# ---------------------------------------------------------------------------
FIXTURE_4C='{"statusCheckRollup":[
  {"__typename":"StatusContext","context":"ci/ext","state":"SUCCESS","createdAt":"2026-01-01T00:00:00Z","targetUrl":"https://ci.example.com/a"},
  {"__typename":"StatusContext","context":"ci/ext","state":"FAILURE","createdAt":"2026-01-01T00:10:00Z","targetUrl":"https://ci.example.com/b"}
]}'
assert_count "TC-MGD-4c: within-StatusContext group, newer FAILURE via createdAt → 1" "$FIXTURE_4C" "1"

FIXTURE_4D='{"statusCheckRollup":[
  {"__typename":"StatusContext","context":"ci/ext","state":"FAILURE","createdAt":"2026-01-01T00:00:00Z","targetUrl":"https://ci.example.com/a"},
  {"__typename":"StatusContext","context":"ci/ext","state":"SUCCESS","createdAt":"2026-01-01T00:10:00Z","targetUrl":"https://ci.example.com/b"}
]}'
assert_count "TC-MGD-4d: within-StatusContext group, newer SUCCESS via createdAt → 0" "$FIXTURE_4D" "0"

# ---------------------------------------------------------------------------
# TC-MGD-5: Equal-timestamp tie between SUCCESS and CANCELLED. Must resolve
# fail-closed (any non-passing entry at the max timestamp blocks the group)
# and be ORDER-INDEPENDENT — tested both array orderings. The old `max_by`
# silently picked whichever entry GitHub's undocumented array order put last;
# this pins deterministic fail-closed behaviour regardless of array order.
# ---------------------------------------------------------------------------
FIXTURE_5A='{"statusCheckRollup":[
  {"name":"flaky","conclusion":"SUCCESS","startedAt":"2026-01-01T00:00:00Z"},
  {"name":"flaky","conclusion":"CANCELLED","startedAt":"2026-01-01T00:00:00Z"}
]}'
assert_count "TC-MGD-5a: equal-timestamp tie, SUCCESS first → 1 (fail-closed)" "$FIXTURE_5A" "1"

FIXTURE_5B='{"statusCheckRollup":[
  {"name":"flaky","conclusion":"CANCELLED","startedAt":"2026-01-01T00:00:00Z"},
  {"name":"flaky","conclusion":"SUCCESS","startedAt":"2026-01-01T00:00:00Z"}
]}'
assert_count "TC-MGD-5b: equal-timestamp tie, CANCELLED first → 1 (order-independent)" "$FIXTURE_5B" "1"

# ---------------------------------------------------------------------------
# TC-MGD-6: Empty array and null rollup (PRs with zero status checks
# configured) must both resolve to 0, not error.
# ---------------------------------------------------------------------------
assert_count "TC-MGD-6a: empty statusCheckRollup array → 0" '{"statusCheckRollup":[]}' "0"
assert_count "TC-MGD-6b: null statusCheckRollup → 0" '{"statusCheckRollup":null}' "0"

# ---------------------------------------------------------------------------
# TC-MGD-7: A single genuine latest FAILURE with no dedupe complications.
# Baseline sanity check that the transform still flags a real failure.
# ---------------------------------------------------------------------------
FIXTURE_7='{"statusCheckRollup":[
  {"name":"lint","conclusion":"FAILURE","startedAt":"2026-01-01T00:00:00Z"}
]}'
assert_count "TC-MGD-7: genuine latest FAILURE, no other complications → 1" "$FIXTURE_7" "1"

# ---------------------------------------------------------------------------
# TC-MGD-8: Two NON-Actions GitHub Apps (blank workflowName) posting the same
# check name. Without the URL-origin key component, app A's newer SUCCESS
# would mask app B's older FAILURE (Codex P1). The origins differ, so the
# groups stay distinct and B's failure must still block.
# ---------------------------------------------------------------------------
FIXTURE_8='{"statusCheckRollup":[
  {"name":"scan","conclusion":"SUCCESS","startedAt":"2026-01-01T00:10:00Z","detailsUrl":"https://app-a.example.com/checks/1"},
  {"name":"scan","conclusion":"FAILURE","startedAt":"2026-01-01T00:00:00Z","detailsUrl":"https://app-b.example.com/checks/2"}
]}'
assert_count "TC-MGD-8: cross-app same-name, blank workflowName → 1 (origins distinguish)" "$FIXTURE_8" "1"

# ---------------------------------------------------------------------------
# TC-MGD-10: STALE empty-conclusion entry (older) superseded by a newer
# terminal SUCCESS for the same check. This is the PR #130 bug: GitHub left a
# `automated-review / review` entry with an empty conclusion in the rollup; counting ""
# as in-flight pinned the gate at "1 pending" forever so auto-merge never fired.
# The empty entry is older than the SUCCESS, so it must be ignored → 0.
# ---------------------------------------------------------------------------
FIXTURE_10='{"statusCheckRollup":[
  {"name":"automated-review / review","conclusion":null,"state":null,"startedAt":"2026-01-01T00:00:00Z"},
  {"name":"automated-review / review","conclusion":"SUCCESS","startedAt":"2026-01-01T00:10:00Z"}
]}'
assert_count "TC-MGD-10: stale empty-conclusion entry + newer SUCCESS → 0 (PR #130 fix)" "$FIXTURE_10" "0"

# ---------------------------------------------------------------------------
# TC-MGD-11: NEWEST entry has an empty-conclusion status (older SUCCESS behind
# it). Dropping "" from the in-flight set must NOT open an under-block: a
# genuinely-unknown LATEST state still blocks via the max-timestamp clause
# (fail-closed) → 1. This pins the safe direction of the TC-MGD-10 fix.
# ---------------------------------------------------------------------------
FIXTURE_11='{"statusCheckRollup":[
  {"name":"automated-review / review","conclusion":"SUCCESS","startedAt":"2026-01-01T00:00:00Z"},
  {"name":"automated-review / review","conclusion":null,"state":null,"startedAt":"2026-01-01T00:10:00Z"}
]}'
assert_count "TC-MGD-11: newest entry empty-conclusion → 1 (fail-closed, no under-block)" "$FIXTURE_11" "1"

# ---------------------------------------------------------------------------
# TC-MGD-9: 3-site consistency — verifies the FULL jq logic (not just the
# group_by key) stays aligned across the three production sites (automated-review 🟡
# on PR #101):
#   9a) Step 5.5's ENTIRE jq program must equal the hook's, normalized for
#       whitespace (they are the same count-of-non-passing-groups transform).
#   9b) Step 5.4's automated-review-scoped variant must CONTAIN every shared core
#       fragment: the full group_by key, the in-flight predicate, the max-
#       timestamp key line, and the fail-closed tie select.
# ---------------------------------------------------------------------------
normalize_core() { tr -s ' \n\t' '   ' | sed 's/^ *//; s/ *$//'; }
MD_FILE="$SCRIPT_DIR/../commands/review-pr.md"
CONSISTENT=true
DETAIL=""

# 9a — full-expression comparison: hook jq vs Step 5.5's FAILING_OR_PENDING jq.
HOOK_NORM=$(printf '%s' "$CANONICAL_JQ" | normalize_core)
STEP55_JQ=$(perl -0777 -ne "print \$1 if /FAILING_OR_PENDING=\\\$\\(echo \"\\\$PR_JSON\"[^']*'(.*?)'\\)/s" "$MD_FILE")
STEP55_NORM=$(printf '%s' "$STEP55_JQ" | normalize_core)
if [[ -z "$STEP55_NORM" ]]; then
  CONSISTENT=false; DETAIL="could not extract Step 5.5 FAILING_OR_PENDING jq from review-pr.md"
elif [[ "$STEP55_NORM" != "$HOOK_NORM" ]]; then
  CONSISTENT=false; DETAIL="Step 5.5 full jq diverges from the hook's (normalized)"
fi

# 9b — Step 5.4 (S54_LATEST) must contain each shared core fragment.
if $CONSISTENT; then
  STEP54_JQ=$(perl -0777 -ne "print \$1 if /S54_LATEST=\\\$\\(echo \"\\\$S54_JSON\"[^']*'(.*?)'\\)/s" "$MD_FILE")
  STEP54_NORM=$(printf '%s' "$STEP54_JQ" | normalize_core)
  if [[ -z "$STEP54_NORM" ]]; then
    CONSISTENT=false; DETAIL="could not extract Step 5.4 S54_LATEST jq from review-pr.md"
  else
    for FRAG in \
      'map(select(((.name // .context // "")|ascii_downcase|startswith("automated-review"))))' \
      'group_by([(.__typename // ""), (.name // .context // "unknown"), (.workflowName // ""), ((.detailsUrl // .targetUrl // "") | split("/")[0:3] | join("/"))])' \
      '$c=="PENDING" or $c=="IN_PROGRESS" or $c=="QUEUED" or $c=="EXPECTED"' \
      'max_by(.startedAt // .completedAt // .createdAt // "")' \
      '(map(select((.startedAt // .completedAt // .createdAt // "") == $maxk))) as $maxentries' \
      '$c != "SUCCESS" and $c != "SKIPPED" and $c != "NEUTRAL"))) as $maxfailed' \
      'if ($inflight > 0) then' \
      'elif ($maxfailed | length > 0) then'; do
      FRAG_NORM=$(printf '%s' "$FRAG" | normalize_core)
      if [[ "$STEP54_NORM" != *"$FRAG_NORM"* ]]; then
        CONSISTENT=false; DETAIL="Step 5.4 missing shared core fragment: [$FRAG_NORM]"
        break
      fi
    done
  fi
fi

if $CONSISTENT; then
  PASS=$((PASS + 1))
  printf '  PASS: TC-MGD-9: 3-site full-logic consistency (5.5 exact, 5.4 core-contained)\n'
else
  FAIL=$((FAIL + 1))
  FAILED_TESTS+=("TC-MGD-9: $DETAIL")
  printf '  FAIL: TC-MGD-9 — %s\n' "$DETAIL"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
TOTAL=$((PASS + FAIL))
if [[ $FAIL -eq 0 ]]; then
  printf "  All %d tests passed.\n" "$TOTAL"
else
  printf "  %d/%d tests FAILED:\n" "$FAIL" "$TOTAL"
  for t in "${FAILED_TESTS[@]}"; do
    printf "    - %s\n" "$t"
  done
  exit 1
fi

exit 0
