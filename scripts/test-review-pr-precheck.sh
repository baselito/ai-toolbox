#!/usr/bin/env bash
# test-review-pr-precheck.sh — Unit tests for scripts/review-pr-precheck.sh.
#
# Tests the decision logic by stubbing gh/jq with function overrides so no
# network calls are made. Covers all four code paths the production cron exercises:
#   1. count increased       → PROCESS (new reviewer comments arrived)
#   2. count same, gate dead → SKIP    (no-op fire — save compute)
#   3. count same, gate live → PROCESS (merge gate might be ready)
#   4. error / missing state → PROCESS (fail-open — never drop a comment)
#
# Usage: ./scripts/test-review-pr-precheck.sh
# Exits 0 if all tests pass, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRECHECK="$SCRIPT_DIR/review-pr-precheck.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

# Run the precheck script inside a subshell where gh is stubbed via a fake
# executable on PATH — the most portable approach on macOS/Linux (exported
# bash functions are not reliably inherited by child processes on all platforms).
#
# Args: <owner/repo> <pr-number> <stored-count> <stub-meta-json> <stub-inline-count>
#       [<jq-available: true|false>]  [<stub-api-exit: integer>]  [<stub-issue-count>]
#
# <stub-meta-json>     — JSON string returned by the stubbed "gh pr view" call
# <stub-inline-count>  — integer (or multi-line integers for pagination) returned as
#                        the inline comment count
# <jq-available>       — optional; default true. When false, jq is hidden to test fail-open.
# <stub-api-exit>      — optional; when set (non-empty), the fake gh api subcommand exits
#                        with this code after printing output, simulating a gh api failure
#                        that still produced bytes (fail-open path from Finding 2).
# <stub-issue-count>   — optional; default 0. Integer (or multi-line integers for
#                        pagination) returned for the paginated ISSUE-comments REST call
#                        (gh api .../issues/<N>/comments). Separate from the META
#                        .comments array — the production script counts issue comments
#                        via the paginated REST endpoint, NOT the GraphQL-capped
#                        `gh pr view --json comments` field (Codex P1 finding).
run_precheck() {
  local owner_repo="$1"
  local pr_number="$2"
  local stored_count="$3"
  local stub_meta="$4"
  local stub_inline="$5"
  local jq_available="${6:-true}"
  local stub_api_exit="${7:-}"
  local stub_issue="${8:-0}"
  local reuse_dir="${REUSE_PRECHECK_DIR:-}"

  # Scratch dir holds: .claude/ (count file), bin/ (stub executables).
  local tmp_dir
  if [[ -n "$reuse_dir" ]]; then
    tmp_dir="$reuse_dir"
  else
    tmp_dir=$(mktemp -d)
  fi
  # Use a trap scoped to the RETURN of this function — remove the tmp_dir when
  # run_precheck returns (even on error). The child subshell inherits the dir.
  if [[ -z "$reuse_dir" ]]; then
    local trap_tmp_dir="$tmp_dir"
    trap "rm -rf '$trap_tmp_dir'" RETURN
  fi

  # Write stub response files. The fake gh script reads these.
  local stub_meta_file="$tmp_dir/stub_meta"
  local stub_inline_file="$tmp_dir/stub_inline"
  local stub_issue_file="$tmp_dir/stub_issue"
  printf '%s' "$stub_meta" > "$stub_meta_file"
  printf '%s' "$stub_inline" > "$stub_inline_file"
  printf '%s' "$stub_issue" > "$stub_issue_file"

  # Create a fake gh executable that returns our stubbed responses.
  # Placed in $tmp_dir/bin/ and prepended to PATH inside the child bash call.
  # Using a fake executable avoids bash function export reliability issues.
  local fake_bin="$tmp_dir/bin"
  mkdir -p "$fake_bin"

  # Write the fake gh script.
  # The script reads response content from the sibling files in $tmp_dir.
  # STUB_META_FILE and STUB_INLINE_FILE are exported env vars in the child env.
  # STUB_API_EXIT (optional) lets tests simulate a non-zero gh api exit code
  # while the stub still produces output — exercises the fail-open path for
  # "gh api exits non-zero but still printed bytes before dying" (Finding 2).
  cat > "$fake_bin/gh" << STUBEOF
#!/usr/bin/env bash
# Fake gh stub for review-pr-precheck tests.
# Reads responses from files named in STUB_META_FILE and STUB_INLINE_FILE.
subcmd="\$1"
case "\$subcmd" in
  pr)
    # gh pr view ... → return stub meta JSON
    cat "\$STUB_META_FILE"
    ;;
  api)
    # Route by endpoint (both are paginated REST count calls, --jq 'length'):
    #   repos/.../issues/<N>/comments → issue-comment count (STUB_ISSUE_FILE)
    #   repos/.../pulls/<N>/comments  → inline-comment count (STUB_INLINE_FILE)
    # Return one integer per page (multiple lines simulate pagination).
    if [[ "\$2" == */issues/* ]]; then
      cat "\$STUB_ISSUE_FILE"
    else
      cat "\$STUB_INLINE_FILE"
    fi
    # If STUB_API_EXIT is set, exit with that code to simulate a gh api failure
    # that still produced output before dying (fail-open must still print PROCESS).
    if [[ -n "\${STUB_API_EXIT:-}" ]]; then
      exit "\$STUB_API_EXIT"
    fi
    ;;
  *)
    echo "stub-gh: unexpected subcmd \$subcmd" >&2
    exit 1
    ;;
esac
STUBEOF
  chmod +x "$fake_bin/gh"
  mkdir -p "$tmp_dir/.local/bin"
  cp "$fake_bin/gh" "$tmp_dir/.local/bin/gh"
  chmod +x "$tmp_dir/.local/bin/gh"

  # Capture bash's absolute path BEFORE any PATH manipulation.
  # This is essential for the jq-missing test (Finding 3): if bash and jq share
  # a directory (e.g. /usr/bin), stripping that directory to hide jq also makes
  # 'bash' unresolvable when passed as a bare word to `env`.  By capturing the
  # absolute path now, we can invoke bash directly even after PATH is stripped.
  local BASH_BIN
  BASH_BIN="$(command -v bash)"

  # Optionally block jq from being found (simulates jq missing).
  # To simulate jq truly missing, build a PATH that has NO jq directory in it.
  # We strip jq's directory from PATH; then invoke bash via BASH_BIN (absolute
  # path, captured above) so bash itself remains available regardless of whether
  # bash and jq share a directory — fixing the portability issue in Finding 3.
  if [[ "$jq_available" == "false" ]]; then
    # Build a PATH that excludes the directory containing jq.
    local jq_path
    jq_path=$(command -v jq 2>/dev/null)
    local jq_dir=""
    if [[ -n "$jq_path" ]]; then
      jq_dir=$(dirname "$jq_path")
    fi

    local no_jq_path
    no_jq_path=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v "^${jq_dir}$" | tr '\n' ':' | sed 's/:$//')
    # Prepend fake_bin so our gh stub still works.
    NO_JQ_PATH="${fake_bin}:${no_jq_path}"
  fi

  # Write the stored count file now (before the child process starts) so we
  # don't need mkdir or printf inside the child's PATH-restricted environment.
  mkdir -p "$tmp_dir/.claude/scripts"
  # The production precheck uses the installed detector only. Copy the source
  # into the test HOME to exercise that integration instead of letting tests
  # silently take the fail-open missing-install path.
  cp "$SCRIPT_DIR/loop-progress-signature.sh" "$tmp_dir/.claude/scripts/loop-progress-signature.sh"
  chmod +x "$tmp_dir/.claude/scripts/loop-progress-signature.sh"
  if [[ -n "$stored_count" ]]; then
    local count_file_key
    count_file_key=$(printf '%s' "$owner_repo" | tr '/' '-')
    printf '%s' "$stored_count" > "$tmp_dir/.claude/.pr-${count_file_key}-${pr_number}-count"
  fi

  # Determine the PATH to use: either the standard fake_bin-prepended PATH, or
  # the no-jq PATH constructed above when jq_available=false.
  local child_path
  if [[ "$jq_available" == "false" ]]; then
    child_path="${NO_JQ_PATH}"
  else
    child_path="${fake_bin}:${PATH}"
  fi

  # Run the precheck in a child bash process.
  # We pass env vars via the environment directly (env command) rather than
  # relying on shell expansion inside a quoted string — avoids quoting pitfalls.
  # Note: we invoke "$BASH_BIN" (absolute path) rather than bare 'bash' so the
  # jq-missing test still works when bash and jq share the same directory.
  # STUB_API_EXIT is passed through to the fake gh stub when set — allows tests
  # to simulate a non-zero gh api exit code (fail-open path, Finding 2).
  # We build the optional STUB_API_EXIT entry as a shell array element so it
  # is only present when stub_api_exit is non-empty (env doesn't do parameter
  # expansion itself).
  local extra_env=()
  if [[ -n "$stub_api_exit" ]]; then
    extra_env=("STUB_API_EXIT=$stub_api_exit")
  fi

  env \
    HOME="$tmp_dir" \
    STUB_META_FILE="$stub_meta_file" \
    STUB_INLINE_FILE="$stub_inline_file" \
    STUB_ISSUE_FILE="$stub_issue_file" \
    "${extra_env[@]+"${extra_env[@]}"}" \
    PATH="$child_path" \
    "$BASH_BIN" "$PRECHECK" "$owner_repo" "$pr_number" 2>&1
}

# Assert that the precheck output starts with "PROCESS".
assert_process() {
  local test_name="$1"
  local output="$2"
  if printf '%s' "$output" | grep -q '^PROCESS'; then
    PASS=$((PASS + 1))
    printf '  PASS: %s\n' "$test_name"
  else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$test_name: expected PROCESS, got: $output")
    printf '  FAIL: %s — expected PROCESS, got: %s\n' "$test_name" "$output"
  fi
}

# Assert that the precheck output starts with "SKIP".
assert_skip() {
  local test_name="$1"
  local output="$2"
  if printf '%s' "$output" | grep -q '^SKIP'; then
    PASS=$((PASS + 1))
    printf '  PASS: %s\n' "$test_name"
  else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$test_name: expected SKIP, got: $output")
    printf '  FAIL: %s — expected SKIP, got: %s\n' "$test_name" "$output"
  fi
}

# Assert that the no-progress guard stops a repeated unchanged blocked state.
assert_stop() {
  local test_name="$1"
  local output="$2"
  if printf '%s' "$output" | grep -q '^STOP'; then
    PASS=$((PASS + 1))
    printf '  PASS: %s\n' "$test_name"
  else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$test_name: expected STOP, got: $output")
    printf '  FAIL: %s — expected STOP, got: %s\n' "$test_name" "$output"
  fi
}

# ---------------------------------------------------------------------------
# JSON fixtures — comments/reviews are arrays of objects (real gh pr view format)
# ---------------------------------------------------------------------------
# PR open, merge gate NOT ready (BLOCKED, no CHANGES_REQUESTED).
META_OPEN_BLOCKED='{"comments":[],"reviews":[],"mergeStateStatus":"BLOCKED","reviewDecision":"PENDING","state":"OPEN"}'
# PR open, merge gate CLEAN, no CHANGES_REQUESTED → gate might pass.
META_OPEN_CLEAN='{"comments":[],"reviews":[],"mergeStateStatus":"CLEAN","reviewDecision":"PENDING","state":"OPEN"}'
# PR open, merge gate UNSTABLE (e.g. non-required CI jobs SKIPPED), no CHANGES_REQUESTED.
META_OPEN_UNSTABLE='{"comments":[],"reviews":[],"mergeStateStatus":"UNSTABLE","reviewDecision":"PENDING","state":"OPEN"}'
# PR open, CHANGES_REQUESTED → gate cannot pass even when CLEAN.
META_OPEN_CHANGES_REQUESTED='{"comments":[],"reviews":[],"mergeStateStatus":"CLEAN","reviewDecision":"CHANGES_REQUESTED","state":"OPEN"}'
# PR with 3 issue comments + 1 review = 4 combined, no inline. Gate BLOCKED so only count matters.
META_4_COMMENTS='{"comments":[{"body":"c1"},{"body":"c2"},{"body":"c3"}],"reviews":[{"body":"r1"}],"mergeStateStatus":"BLOCKED","reviewDecision":"PENDING","state":"OPEN"}'
# PR merged (state != OPEN) — precheck reports SKIP because gate requires state=OPEN.
# (Step 0.5 handles MERGED termination upstream; precheck is only reached for OPEN PRs
# in normal operation, but we test robustness here.)
META_MERGED='{"comments":[],"reviews":[],"mergeStateStatus":"UNKNOWN","reviewDecision":"PENDING","state":"MERGED"}'

# ---------------------------------------------------------------------------
# Finding C fixtures — BLOCKED + automated-review check state in statusCheckRollup.
#
# WHY: a FAILED required automated-review check makes mergeStateStatus BLOCKED, which
# is not CLEAN/UNSTABLE — so the old MERGE_GATE_MIGHT_PASS logic always said
# SKIP. That starves Step 5.4 (commands/review-pr.md), which is the ONLY
# thing that re-triggers a failed automated-review check — it never runs on a fire
# the precheck already skipped. These fixtures exercise the new automated-review
# override that PROCESSes when a automated-review* check is failed-terminal, using
# the SAME grouping semantics as Step 5.4's S54_LATEST (group by
# [__typename, name/context, workflowName, detailsUrl/targetUrl origin],
# any in-flight member blocks, otherwise resolve on the max-timestamp
# entries) — copied from hooks/pr-action-safety.sh's MERGE-GATE-DEDUPE-JQ
# block and scoped to automated-review*-named checks.
# ---------------------------------------------------------------------------
# (a) BLOCKED + a automated-review check whose LATEST run is FAILURE (terminal-failed)
#     → PROCESS, so Step 5.4's recovery gets a chance to re-trigger it.
META_BLOCKED_REVIEWER_FAILED='{"comments":[],"reviews":[],"mergeStateStatus":"BLOCKED","reviewDecision":"PENDING","state":"OPEN","statusCheckRollup":[{"name":"automated-review-approval-gate","conclusion":"FAILURE","startedAt":"2026-01-01T00:00:00Z"}]}'

# (b) BLOCKED + a automated-review group whose latest run actually PASSES — an older
#     FAILED run was superseded by a newer SUCCESS (the exact PR #99 shape,
#     scoped to automated-review). The latest-run-per-group semantics must resolve
#     this to "pass", so the override must NOT fire — falls through to the
#     ordinary MERGE_GATE_MIGHT_PASS check, which is false for BLOCKED → SKIP.
META_BLOCKED_REVIEWER_SUPERSEDED='{"comments":[],"reviews":[],"mergeStateStatus":"BLOCKED","reviewDecision":"PENDING","state":"OPEN","statusCheckRollup":[{"name":"automated-review-approval-gate","conclusion":"FAILURE","startedAt":"2026-01-01T00:00:00Z"},{"name":"automated-review-approval-gate","conclusion":"SUCCESS","startedAt":"2026-01-01T00:10:00Z"}]}'

# (c) BLOCKED + zero automated-review entries in the rollup (some other required
#     check is what's blocking, e.g. a real failing test) → override must
#     NOT fire — a genuine non-automated-review failure is never auto-recovered.
#     Falls through to ordinary logic → SKIP.
META_BLOCKED_NO_REVIEWER='{"comments":[],"reviews":[],"mergeStateStatus":"BLOCKED","reviewDecision":"PENDING","state":"OPEN","statusCheckRollup":[{"name":"build","conclusion":"FAILURE","startedAt":"2026-01-01T00:00:00Z"}]}'

OWNER_REPO="baselito/ai-engineering"
PR_NUMBER="42"
OWNER="baselito"
REPO_NAME="ai-engineering"

# ---------------------------------------------------------------------------
# TC-PCP-1: Count increased → PROCESS
# Stored count = 3, current = 4 (3 issue via paginated REST + 1 review, 0 inline).
# ---------------------------------------------------------------------------
echo ""
echo "=== review-pr-precheck.sh ==="
echo ""

OUTPUT=$(run_precheck "$OWNER_REPO" "$PR_NUMBER" "3" "$META_4_COMMENTS" "0" "" "" "3")
assert_process "TC-PCP-1: count increased (3→4) → PROCESS" "$OUTPUT"

# ---------------------------------------------------------------------------
# TC-PCP-2: Count same, gate not ready → SKIP
# Stored = 0, current = 0 (no comments), gate BLOCKED.
# ---------------------------------------------------------------------------
OUTPUT=$(run_precheck "$OWNER_REPO" "$PR_NUMBER" "0" "$META_OPEN_BLOCKED" "0")
assert_skip "TC-PCP-2: count same + gate BLOCKED → SKIP" "$OUTPUT"

# ---------------------------------------------------------------------------
# TC-PCP-3: Count same, gate CLEAN → PROCESS (merge gate might pass)
# Stored = 0, current = 0, mergeStateStatus=CLEAN, reviewDecision=PENDING.
# ---------------------------------------------------------------------------
OUTPUT=$(run_precheck "$OWNER_REPO" "$PR_NUMBER" "0" "$META_OPEN_CLEAN" "0")
assert_process "TC-PCP-3: count same + gate CLEAN → PROCESS (merge gate might pass)" "$OUTPUT"

# ---------------------------------------------------------------------------
# TC-PCP-4: Error / gh failure → PROCESS (fail-open)
# Simulated by passing invalid JSON as stub_meta, which jq will fail to parse.
# ---------------------------------------------------------------------------
OUTPUT=$(run_precheck "$OWNER_REPO" "$PR_NUMBER" "0" "NOT_VALID_JSON" "0")
assert_process "TC-PCP-4: invalid gh output (parse error) → PROCESS (fail-open)" "$OUTPUT"

# ---------------------------------------------------------------------------
# TC-PCP-5: Count same, gate UNSTABLE (non-required jobs skipped) → PROCESS
# UNSTABLE with no CHANGES_REQUESTED is treated like CLEAN (safe to evaluate).
# ---------------------------------------------------------------------------
OUTPUT=$(run_precheck "$OWNER_REPO" "$PR_NUMBER" "0" "$META_OPEN_UNSTABLE" "0")
assert_process "TC-PCP-5: count same + gate UNSTABLE → PROCESS (merge gate might pass)" "$OUTPUT"

# ---------------------------------------------------------------------------
# TC-PCP-6: Count same, gate CLEAN but CHANGES_REQUESTED → SKIP
# Reviewer blocked the PR — merge gate will not pass regardless of CI state.
# ---------------------------------------------------------------------------
OUTPUT=$(run_precheck "$OWNER_REPO" "$PR_NUMBER" "0" "$META_OPEN_CHANGES_REQUESTED" "0")
assert_skip "TC-PCP-6: count same + CLEAN but CHANGES_REQUESTED → SKIP" "$OUTPUT"

# ---------------------------------------------------------------------------
# TC-PCP-7: Missing stored count (first run) + no new comments + gate dead → SKIP
# Count file absent → stored count defaults to 0. Current = 0. Gate BLOCKED.
# ---------------------------------------------------------------------------
OUTPUT=$(run_precheck "$OWNER_REPO" "$PR_NUMBER" "" "$META_OPEN_BLOCKED" "0")
assert_skip "TC-PCP-7: no count file (first run) + count=0 + gate BLOCKED → SKIP" "$OUTPUT"

# ---------------------------------------------------------------------------
# TC-PCP-8: Missing stored count (first run) + new inline comments → PROCESS
# Count file absent → stored = 0. Current = 2 (0 issue/review + 2 inline). Gate BLOCKED.
# ---------------------------------------------------------------------------
OUTPUT=$(run_precheck "$OWNER_REPO" "$PR_NUMBER" "" "$META_OPEN_BLOCKED" "2")
assert_process "TC-PCP-8: no count file + 2 inline comments → PROCESS" "$OUTPUT"

# ---------------------------------------------------------------------------
# TC-PCP-9: a PATH that omits jq must not replace the fixed helper path. The
# host's trusted jq still parses the fixture, so this remains the safe SKIP
# result rather than pretending the dependency is absent.
# ---------------------------------------------------------------------------
OUTPUT=$(run_precheck "$OWNER_REPO" "$PR_NUMBER" "0" "$META_OPEN_BLOCKED" "0" "false")
assert_skip "TC-PCP-9: PATH-only jq omission does not bypass fixed helper resolution" "$OUTPUT"

# ---------------------------------------------------------------------------
# TC-PCP-10: Inline count contributes to total
# Stored = 4, current = 3 issue (paginated REST) + 1 review + 2 inline = 6
# → count increased → PROCESS.
# ---------------------------------------------------------------------------
OUTPUT=$(run_precheck "$OWNER_REPO" "$PR_NUMBER" "4" "$META_4_COMMENTS" "2" "" "" "3")
assert_process "TC-PCP-10: inline count pushes total above stored count → PROCESS" "$OUTPUT"

# ---------------------------------------------------------------------------
# TC-PCP-11: Count same with inline included → SKIP
# Stored = 6, current = 3 issue + 1 review + 2 inline = 6, gate BLOCKED → SKIP.
# ---------------------------------------------------------------------------
OUTPUT=$(run_precheck "$OWNER_REPO" "$PR_NUMBER" "6" "$META_4_COMMENTS" "2" "" "" "3")
assert_skip "TC-PCP-11: count same including inline (6=6) + gate BLOCKED → SKIP" "$OUTPUT"

# ---------------------------------------------------------------------------
# TC-PCP-12: Invalid repo format → PROCESS (fail-open)
# ---------------------------------------------------------------------------
OUTPUT=$(bash "$PRECHECK" "not-a-valid/repo/path" "$PR_NUMBER" 2>/dev/null)
assert_process "TC-PCP-12: invalid repo format → PROCESS (fail-open, bad input)" "$OUTPUT"

# ---------------------------------------------------------------------------
# TC-PCP-13: Invalid PR number → PROCESS (fail-open)
# ---------------------------------------------------------------------------
OUTPUT=$(bash "$PRECHECK" "$OWNER_REPO" "abc" 2>/dev/null)
assert_process "TC-PCP-13: non-numeric PR number → PROCESS (fail-open, bad input)" "$OUTPUT"

# ---------------------------------------------------------------------------
# TC-PCP-14: Missing arguments → PROCESS (fail-open)
# ---------------------------------------------------------------------------
OUTPUT=$(bash "$PRECHECK" 2>/dev/null)
assert_process "TC-PCP-14: no arguments → PROCESS (fail-open, missing args)" "$OUTPUT"

# ---------------------------------------------------------------------------
# TC-PCP-15: Count same + PR not OPEN (merged) + gate dead → SKIP
# State=MERGED disqualifies the merge gate. Count same → no new comments. → SKIP.
# ---------------------------------------------------------------------------
OUTPUT=$(run_precheck "$OWNER_REPO" "$PR_NUMBER" "0" "$META_MERGED" "0")
assert_skip "TC-PCP-15: count same + PR MERGED → SKIP (gate requires OPEN)" "$OUTPUT"

# ---------------------------------------------------------------------------
# TC-PCP-16: gh api exits non-zero despite producing output → PROCESS (fail-open)
# Exercises the INLINE_GH_EXIT capture fix (HIGH finding): the stub emits "0"
# (a valid-looking inline count) but then exits 1, simulating a transient REST
# outage that still flushed some bytes before dying.  The script must treat the
# non-zero exit as a failure and print PROCESS, NOT SKIP.
# Stored count = 0, so without the exit-code check the script would compute
# CURRENT=0, compare 0==0, and emit SKIP — silently eating any real comments.
# ---------------------------------------------------------------------------
OUTPUT=$(run_precheck "$OWNER_REPO" "$PR_NUMBER" "0" "$META_OPEN_BLOCKED" "0" "true" "1")
assert_process "TC-PCP-16: gh api exits 1 despite output → PROCESS (fail-open, non-zero exit)" "$OUTPUT"

# ---------------------------------------------------------------------------
# TC-PCP-17: Paginated inline count is summed correctly.
# The production script uses --paginate; jq emits one integer per page.
# Stub returns two lines ("1\n2"), representing two pages with 1 and 2 inline
# comments respectively.  The awk summing logic must produce 3, which exceeds
# the stored count of 2 → new comments → PROCESS.
# This directly tests the multi-page awk sum path (Finding 4).
# ---------------------------------------------------------------------------
STUB_INLINE_MULTI=$'1\n2'
OUTPUT=$(run_precheck "$OWNER_REPO" "$PR_NUMBER" "2" "$META_OPEN_BLOCKED" "$STUB_INLINE_MULTI")
assert_process "TC-PCP-17: paginated inline counts (1+2=3) exceed stored=2 → PROCESS" "$OUTPUT"

# ---------------------------------------------------------------------------
# TC-PCP-18 (Finding C): BLOCKED + automated-review check failed-terminal → PROCESS.
# Count unchanged (0=0) and mergeStateStatus is BLOCKED (not CLEAN/UNSTABLE),
# so without the automated-review override this would SKIP — starving Step 5.4's
# recovery, which only runs when the precheck lets the fire through.
# ---------------------------------------------------------------------------
OUTPUT=$(run_precheck "$OWNER_REPO" "$PR_NUMBER" "0" "$META_BLOCKED_REVIEWER_FAILED" "0")
assert_process "TC-PCP-18: BLOCKED + automated-review check FAILED (latest run) → PROCESS (Step 5.4 recovery gate)" "$OUTPUT"

# ---------------------------------------------------------------------------
# TC-PCP-19 (Finding C): BLOCKED + automated-review group's LATEST run passes (an
# older FAILURE was superseded by a newer SUCCESS) → override must NOT fire.
# Falls through to ordinary logic (gate not CLEAN/UNSTABLE) → SKIP.
# ---------------------------------------------------------------------------
OUTPUT=$(run_precheck "$OWNER_REPO" "$PR_NUMBER" "0" "$META_BLOCKED_REVIEWER_SUPERSEDED" "0")
assert_skip "TC-PCP-19: BLOCKED + automated-review latest run is SUCCESS (older FAILURE superseded) → SKIP" "$OUTPUT"

# ---------------------------------------------------------------------------
# TC-PCP-19b (Finding C, automated-review PR #105): BLOCKED + automated-review group's latest
# run is still in-flight — an older FAILURE exists, but any in-flight member
# must block the group from being treated as failed-terminal. This is exactly
# the recovery state Step 5.4 creates right after re-triggering automated-review; if
# the override fired here, cron fires would PROCESS and re-trigger duplicate
# work instead of waiting for the current rerun to settle. → SKIP.
# (The in-flight entry has conclusion/state absent — the jq's `// ""` fallback
# classifies empty as in-flight, same as the canonical dedupe block.)
# ---------------------------------------------------------------------------
META_BLOCKED_REVIEWER_IN_FLIGHT='{"comments":[],"reviews":[],"mergeStateStatus":"BLOCKED","reviewDecision":"PENDING","state":"OPEN","statusCheckRollup":[{"name":"automated-review-approval-gate","conclusion":"FAILURE","startedAt":"2026-01-01T00:00:00Z"},{"name":"automated-review-approval-gate","status":"IN_PROGRESS","startedAt":"2026-01-01T00:10:00Z"}]}'
OUTPUT=$(run_precheck "$OWNER_REPO" "$PR_NUMBER" "0" "$META_BLOCKED_REVIEWER_IN_FLIGHT" "0")
assert_skip "TC-PCP-19b: BLOCKED + automated-review newer run in progress (older FAILURE present) → SKIP" "$OUTPUT"

# ---------------------------------------------------------------------------
# TC-PCP-20 (Finding C): BLOCKED with zero automated-review entries in the rollup —
# some other (non-automated-review) required check is blocking. The override must
# scope strictly to automated-review*-named checks and never fire here — a genuine
# non-automated-review failure is never auto-recovered. → SKIP.
# ---------------------------------------------------------------------------
OUTPUT=$(run_precheck "$OWNER_REPO" "$PR_NUMBER" "0" "$META_BLOCKED_NO_REVIEWER" "0")
assert_skip "TC-PCP-20: BLOCKED + zero automated-review entries (non-automated-review check blocking) → SKIP" "$OUTPUT"

# ---------------------------------------------------------------------------
# TC-PCP-21 (Finding C follow-up): BLOCKED + statusCheckRollup is malformed
# (not an array) — the automated-review-override jq expression throws internally, but
# the `[[ ... =~ ^[0-9]+$ ]] || REVIEWER_FAILED=0` guard must catch it and fall
# through to the ordinary logic rather than crash the script. Distinct from
# TC-PCP-4 (whole-payload invalid JSON) — this is a malformed FIELD inside
# otherwise-valid JSON, exercising the override's own fail-open path.
# ---------------------------------------------------------------------------
META_BLOCKED_MALFORMED_ROLLUP='{"comments":[],"reviews":[],"mergeStateStatus":"BLOCKED","reviewDecision":"PENDING","state":"OPEN","statusCheckRollup":"garbage"}'
OUTPUT=$(run_precheck "$OWNER_REPO" "$PR_NUMBER" "0" "$META_BLOCKED_MALFORMED_ROLLUP" "0")
assert_skip "TC-PCP-21: BLOCKED + malformed statusCheckRollup (non-array) → SKIP (override fail-open, no crash)" "$OUTPUT"

# ---------------------------------------------------------------------------
# TC-PCP-22 (Codex P1): issue comments beyond the GraphQL 100-cap must still
# be counted. `gh pr view --json comments` is capped at 100 entries (same as
# reviews) — counting issue comments from it reproduces the exact "comments
# beyond a cap are permanently dropped" failure class this PR fixes for
# pagination. The production script must count issue comments via the
# PAGINATED REST endpoint (gh api .../issues/<N>/comments --paginate) instead.
#
# Fixture: the capped GraphQL view (META .comments) shows 1 comment, but the
# paginated REST endpoint returns 2 pages of 1 each (= 2 issue comments —
# one "beyond the cap" in this simulation). Stored = 1, gate BLOCKED.
#   OLD (capped) metric: 1 + 0 reviews + 0 inline = 1 = stored → SKIP (bug:
#   the new comment is silently dropped).
#   NEW (paginated) metric: 2 + 0 + 0 = 2 > 1 → PROCESS.
# The two-line stub also exercises the awk page-summing on the issue leg.
# ---------------------------------------------------------------------------
META_BLOCKED_CAPPED_COMMENTS='{"comments":[{"body":"c1"}],"reviews":[],"mergeStateStatus":"BLOCKED","reviewDecision":"PENDING","state":"OPEN"}'
STUB_ISSUE_MULTI=$'1\n1'
OUTPUT=$(run_precheck "$OWNER_REPO" "$PR_NUMBER" "1" "$META_BLOCKED_CAPPED_COMMENTS" "0" "" "" "$STUB_ISSUE_MULTI")
assert_process "TC-PCP-22: issue comment beyond GraphQL cap (REST sees 2, view sees 1) → PROCESS" "$OUTPUT"

# ---------------------------------------------------------------------------
# TC-PCP-23: reviewDecision is an EMPTY STRING (fresh PR — no reviews yet).
# jq's `//` operator treats "" as truthy, so `.reviewDecision // "PENDING"`
# passes the empty string through and the `[[ -z ]]` parse guard misfires —
# fail-opening EVERY cron fire on a review-less PR to PROCESS (observed live
# on PR #105's first fire). Gate semantics: "" is not CHANGES_REQUESTED, so
# with count unchanged and gate BLOCKED the correct answer is SKIP.
# ---------------------------------------------------------------------------
META_BLOCKED_EMPTY_DECISION='{"comments":[],"reviews":[],"mergeStateStatus":"BLOCKED","reviewDecision":"","state":"OPEN"}'
OUTPUT=$(run_precheck "$OWNER_REPO" "$PR_NUMBER" "0" "$META_BLOCKED_EMPTY_DECISION" "0")
assert_skip "TC-PCP-23: BLOCKED + empty reviewDecision (no reviews yet) → SKIP (not parse-guard fail-open)" "$OUTPUT"

# ---------------------------------------------------------------------------
# TC-PCP-24 (loop blocker): repeated unchanged blocked fires must advance the
# installed no-progress detector and stop at its threshold instead of emitting
# SKIP forever. Keep one HOME across both invocations so the detector's state
# is genuinely carried between fires.
# ---------------------------------------------------------------------------
REUSE_PRECHECK_DIR=$(mktemp -d)
OUTPUT=$(REUSE_PRECHECK_DIR="$REUSE_PRECHECK_DIR" run_precheck "$OWNER_REPO" "$PR_NUMBER" "0" "$META_OPEN_BLOCKED" "0")
assert_skip "TC-PCP-24a: first unchanged blocked fire records progress state → SKIP" "$OUTPUT"
OUTPUT=$(REUSE_PRECHECK_DIR="$REUSE_PRECHECK_DIR" run_precheck "$OWNER_REPO" "$PR_NUMBER" "0" "$META_OPEN_BLOCKED" "0")
assert_stop "TC-PCP-24b: second unchanged blocked fire reaches threshold → STOP" "$OUTPUT"
touch "$REUSE_PRECHECK_DIR/.claude/.pr-${OWNER}-${REPO_NAME}-${PR_NUMBER}-loop-stalled"
OUTPUT=$(REUSE_PRECHECK_DIR="$REUSE_PRECHECK_DIR" run_precheck "$OWNER_REPO" "$PR_NUMBER" "0" "$META_OPEN_CHANGES_REQUESTED" "0")
assert_skip "TC-PCP-24c: changed blocked signature resets the guard → SKIP" "$OUTPUT"
if [[ ! -e "$REUSE_PRECHECK_DIR/.claude/.pr-${OWNER}-${REPO_NAME}-${PR_NUMBER}-loop-stalled" ]]; then
  PASS=$((PASS + 1)); echo "  PASS: TC-PCP-24d: changed signature clears stalled marker"
else
  FAIL=$((FAIL + 1)); FAILED_TESTS+=("TC-PCP-24d: stalled marker was not cleared")
  echo "  FAIL: TC-PCP-24d — stalled marker was not cleared"
fi
OUTPUT=$(REUSE_PRECHECK_DIR="$REUSE_PRECHECK_DIR" run_precheck "$OWNER_REPO" "$PR_NUMBER" "0" "$META_OPEN_CHANGES_REQUESTED" "0")
assert_stop "TC-PCP-24e: repeated changed signature can stop and re-arm notification" "$OUTPUT"
rm -rf "$REUSE_PRECHECK_DIR"

# ---------------------------------------------------------------------------
# TC-PCP-25: a PATH-only gh shim cannot control the optimization. The trusted
# user-local binary returns the blocked fixture; the earlier PATH shim would
# return a different answer and create a sentinel if accidentally invoked.
# ---------------------------------------------------------------------------
SHIM_DIR=$(mktemp -d)
mkdir -p "$SHIM_DIR/.claude/scripts" "$SHIM_DIR/.local/bin" "$SHIM_DIR/bin"
cp "$PRECHECK" "$SHIM_DIR/.claude/scripts/review-pr-precheck.sh"
cp "$SCRIPT_DIR/loop-progress-signature.sh" "$SHIM_DIR/.claude/scripts/loop-progress-signature.sh"
chmod +x "$SHIM_DIR/.claude/scripts/review-pr-precheck.sh" "$SHIM_DIR/.claude/scripts/loop-progress-signature.sh"
printf '%s' "$META_OPEN_BLOCKED" > "$SHIM_DIR/meta"
cat > "$SHIM_DIR/.local/bin/gh" <<'TRUSTED_GH'
#!/usr/bin/env bash
if [[ "$1" == "pr" ]]; then cat "$STUB_META_FILE"; else echo 0; fi
TRUSTED_GH
cat > "$SHIM_DIR/bin/gh" <<'PATH_SHIM'
#!/usr/bin/env bash
touch "$GH_SENTINEL"
exit 1
PATH_SHIM
chmod +x "$SHIM_DIR/.local/bin/gh" "$SHIM_DIR/bin/gh"
SHIM_OUTPUT=$(HOME="$SHIM_DIR" STUB_META_FILE="$SHIM_DIR/meta" GH_SENTINEL="$SHIM_DIR/path-shim-used" \
  PATH="$SHIM_DIR/bin:/usr/bin:/bin" bash "$SHIM_DIR/.claude/scripts/review-pr-precheck.sh" \
  "$OWNER_REPO" "$PR_NUMBER" 2>&1)
if [[ ! -e "$SHIM_DIR/path-shim-used" ]] && printf '%s' "$SHIM_OUTPUT" | grep -q '^SKIP'; then
  PASS=$((PASS + 1)); echo "  PASS: TC-PCP-25: PATH-only gh shim cannot control precheck"
else
  FAIL=$((FAIL + 1)); FAILED_TESTS+=("TC-PCP-25: PATH-only gh shim controlled precheck: $SHIM_OUTPUT")
  echo "  FAIL: TC-PCP-25 — PATH-only gh shim controlled precheck: $SHIM_OUTPUT"
fi
rm -rf "$SHIM_DIR"

# ---------------------------------------------------------------------------
# TC-PCP-26 (Automated review): CLAUDE_HOME must not select a caller-controlled
# progress detector. The trusted detector under HOME/.claude handles the
# decision; the planted helper must never execute.
# ---------------------------------------------------------------------------
ATTACKER_HOME=$(mktemp -d)
mkdir -p "$ATTACKER_HOME/scripts" "$SHIM_DIR/.claude/scripts"
printf '#!/usr/bin/env bash\ntouch "$PROGRESS_ATTACK_SENTINEL"\nprintf "0\\n"\n' \
  > "$ATTACKER_HOME/scripts/loop-progress-signature.sh"
chmod +x "$ATTACKER_HOME/scripts/loop-progress-signature.sh"
printf '#!/usr/bin/env bash\ntouch "$TRUSTED_PROGRESS_SENTINEL"\nexec "%s" "$@"\n' \
  "$SCRIPT_DIR/loop-progress-signature.sh" \
  > "$SHIM_DIR/.claude/scripts/loop-progress-signature.sh"
chmod +x "$SHIM_DIR/.claude/scripts/loop-progress-signature.sh"
OLD_CLAUDE_HOME="${CLAUDE_HOME-}"
OLD_APPDATA="${APPDATA-}"
export PROGRESS_ATTACK_SENTINEL="$ATTACKER_HOME/used"
export TRUSTED_PROGRESS_SENTINEL="$SHIM_DIR/trusted-used"
export CLAUDE_HOME="$ATTACKER_HOME"
export APPDATA="$ATTACKER_HOME"
cp "$PRECHECK" "$SHIM_DIR/.claude/scripts/review-pr-precheck.sh"
mkdir -p "$SHIM_DIR/.local/bin"
printf '%s' "$META_OPEN_BLOCKED" > "$SHIM_DIR/meta"
printf '#!/usr/bin/env bash\nif [[ "$1" == "pr" ]]; then cat "$STUB_META_FILE"; else echo 0; fi\n' \
  > "$SHIM_DIR/.local/bin/gh"
chmod +x "$SHIM_DIR/.local/bin/gh"
OUTPUT=$(HOME="$SHIM_DIR" STUB_META_FILE="$SHIM_DIR/meta" \
  PATH="$SHIM_DIR/.local/bin:/usr/bin:/bin" bash \
  "$SHIM_DIR/.claude/scripts/review-pr-precheck.sh" "$OWNER_REPO" "$PR_NUMBER" 2>&1)
if [[ -n "$OLD_CLAUDE_HOME" ]]; then
  export CLAUDE_HOME="$OLD_CLAUDE_HOME"
else
  unset CLAUDE_HOME
fi
if [[ -n "$OLD_APPDATA" ]]; then
  export APPDATA="$OLD_APPDATA"
else
  unset APPDATA
fi
if [[ ! -e "$ATTACKER_HOME/used" && -e "$SHIM_DIR/trusted-used" ]] \
   && printf '%s' "$OUTPUT" | grep -q '^SKIP'; then
  PASS=$((PASS + 1)); echo "  PASS: TC-PCP-26: caller-controlled CLAUDE_HOME cannot replace progress helper"
else
  FAIL=$((FAIL + 1)); FAILED_TESTS+=("TC-PCP-26: CLAUDE_HOME selected attacker helper: $OUTPUT")
  echo "  FAIL: TC-PCP-26 — CLAUDE_HOME selected attacker helper: $OUTPUT"
fi
rm -rf "$ATTACKER_HOME"

# ---------------------------------------------------------------------------
# TC-PCP-27 (Automated review): standard Windows installs must still locate the
# toolbox helper without trusting an arbitrary APPDATA value. The installer
# places Claude state at %USERPROFILE%/AppData/Roaming/Claude on Windows; the
# precheck must consider that fixed home-relative location after ~/.claude.
# ---------------------------------------------------------------------------
WINDOWS_HOME=$(mktemp -d)
mkdir -p "$WINDOWS_HOME/.claude/scripts" "$WINDOWS_HOME/AppData/Roaming/Claude/scripts" \
  "$WINDOWS_HOME/.local/bin"
printf '#!/usr/bin/env bash\ntouch "$WINDOWS_UNIX_SENTINEL"\nprintf "0\\n"\n' \
  > "$WINDOWS_HOME/.claude/scripts/loop-progress-signature.sh"
chmod +x "$WINDOWS_HOME/.claude/scripts/loop-progress-signature.sh"
printf '#!/usr/bin/env bash\ntouch "$WINDOWS_ROAMING_SENTINEL"\nprintf "0\\n"\n' \
  > "$WINDOWS_HOME/AppData/Roaming/Claude/scripts/loop-progress-signature.sh"
chmod +x "$WINDOWS_HOME/AppData/Roaming/Claude/scripts/loop-progress-signature.sh"
printf '%s' "$META_OPEN_BLOCKED" > "$WINDOWS_HOME/meta"
printf '#!/usr/bin/env bash\nif [[ "$1" == "pr" ]]; then cat "$STUB_META_FILE"; else echo 0; fi\n' \
  > "$WINDOWS_HOME/.local/bin/gh"
chmod +x "$WINDOWS_HOME/.local/bin/gh"
printf '0' > "$WINDOWS_HOME/.claude/.pr-${OWNER}-${REPO_NAME}-${PR_NUMBER}-count"
WINDOWS_OUTPUT=$(HOME="$WINDOWS_HOME" APPDATA="$WINDOWS_HOME/attacker-controlled" \
  CLAUDE_PLATFORM=windows \
  WINDOWS_UNIX_SENTINEL="$WINDOWS_HOME/unix-used" \
  WINDOWS_ROAMING_SENTINEL="$WINDOWS_HOME/roaming-used" \
  STUB_META_FILE="$WINDOWS_HOME/meta" \
  PATH="$WINDOWS_HOME/.local/bin:/usr/bin:/bin" \
  bash "$PRECHECK" "$OWNER_REPO" "$PR_NUMBER" 2>&1)
if [[ ! -e "$WINDOWS_HOME/unix-used" && -e "$WINDOWS_HOME/roaming-used" ]] \
   && printf '%s' "$WINDOWS_OUTPUT" | grep -q '^SKIP'; then
  PASS=$((PASS + 1)); echo "  PASS: TC-PCP-27: Windows home-relative Claude state is supported"
else
  FAIL=$((FAIL + 1)); FAILED_TESTS+=("TC-PCP-27: Windows Claude state was not found: $WINDOWS_OUTPUT")
  echo "  FAIL: TC-PCP-27 — Windows Claude state was not found: $WINDOWS_OUTPUT"
fi
rm -rf "$WINDOWS_HOME"

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
