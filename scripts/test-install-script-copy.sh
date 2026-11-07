#!/usr/bin/env bash
# test-install-script-copy.sh — the installer's utility-script copy blocks.
#
# WHY THIS EXISTS. `scripts/install.sh` runs under `set -euo pipefail`. Its
# utility-script blocks were written as
#
#     if cp -v "$REPO_ROOT/scripts/observe.sh" "$CLAUDE_HOME/scripts/" 2>/dev/null; then
#       chmod +x "$CLAUDE_HOME/scripts/observe.sh"     # <- result thrown away
#       ok "Copied observe.sh to $CLAUDE_HOME/scripts/"
#
# and the review that found this described the symptom as "install reports
# success while the sensor is non-executable". MEASURED, that is not what
# happens, and the truth is worse: under `set -e` the unchecked `chmod` ABORTS
# THE ENTIRE INSTALLER at that line — no `ok`, no `warn`, no remedy, and every
# later step (hooks, MCP config, memory) silently skipped. A destination that is
# writable but denies mode changes (a mounted volume, a restrictive ACL, a
# root-owned ~/.claude) is enough to trigger it.
#
# TWO blocks really COULD report success on failure, and for a different reason:
# `jira-board-columns.sh` and the hooks `chmod +x …/hooks/*.sh` used
# `… || true` followed by an UNCONDITIONAL `ok`, so the result was discarded and
# the success line printed regardless. Those are fixed the same way.
#
# The behavioural case below extracts the SHIPPED observe.sh block verbatim from
# install.sh (between the INSTALL-SCRIPT-COPY-BEGIN/END markers) and runs it under
# the installer's own shell settings with a `chmod` that fails — the same
# extract-the-production-code approach scripts/test-merge-gate-dedupe.sh uses, so
# a future edit to install.sh cannot silently drift away from this test.
#
# The static case covers the SIBLINGS. This defect class in this repo is
# specifically "a fix applied to one of two derivations in the same block", so
# the value is in the siblings, not the named site.
#
# Usage: ./scripts/test-install-script-copy.sh
# Exits 0 if all tests pass, 1 otherwise.

set -uo pipefail   # no -e: every case must run even if an earlier one fails

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/install.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
failed() {
  FAIL=$((FAIL + 1))
  FAILED_TESTS+=("$1${2:+ — $2}")
  echo "  FAIL: $1${2:+ — $2}"
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$name"; else failed "$name" "expected to contain '$needle'"; fi
}
assert_rc() {
  local name="$1" want="$2" got="$3" detail="${4-}"
  if [[ "$got" -eq "$want" ]]; then pass "$name"; else failed "$name" "expected rc=$want got rc=$got${detail:+ · $detail}"; fi
}
assert_true() {
  local name="$1" detail="${2-}"
  shift 2 2>/dev/null || shift $#
  if "$@"; then pass "$name"; else failed "$name" "$detail"; fi
}

# --- SUITE SELF-CHECK: every assert_* helper CALLED must actually EXIST --------
# This suite has no `set -e` (deliberately — a failing case must not abort the
# rest), so calling an undefined helper writes "command not found" to stderr and
# CONTINUES: the assertion never runs and the suite still reports 0 failed. That
# exact bug shipped in scripts/test-observe.sh once, and only the PASS total gave
# it away. Same static check, same reasoning; see that file for the full history.
_SELF="${BASH_SOURCE[0]}"
_ASSERT_DEFINED=$(grep -oE '^assert_[a-z_]+\(\)' "$_SELF" | sed 's/()$//' | sort -u)
_SELF_CODE=$(sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:];]#.*$//' "$_SELF")
_ASSERT_CALLED=$(printf '%s\n' "$_SELF_CODE" \
                 | grep -oE "(^|[[:space:];&|(){}='\"\`])assert_[a-z_]+([[:space:];&|)'\"\`]|\$)" \
                 | grep -oE 'assert_[a-z_]+' | sort -u)
_ASSERT_BAD=""
for _fn in $_ASSERT_CALLED; do
  grep -qx "$_fn" <<< "$_ASSERT_DEFINED" || _ASSERT_BAD="$_ASSERT_BAD $_fn"
done
if [[ -n "$_ASSERT_BAD" ]]; then
  echo ""
  echo "  FATAL: this suite calls assertion helper(s) that are not defined:$_ASSERT_BAD"
  echo "         Each such call is a SILENT NO-OP — the assertion never runs."
  exit 1
fi

echo ""
echo "=== install.sh utility-script copy ==="

# ---------------------------------------------------------------------------
# Harness: run the SHIPPED observe.sh copy block with a chosen `chmod`.
# $1 = fail | work
# Sets: ISC_OUT, ISC_RC, ISC_DEST
# ---------------------------------------------------------------------------
run_shipped_block() {
  local mode="$1" d
  d=$(mktemp -d "$WORK/case.XXXXXX")
  mkdir -p "$d/bin" "$d/home/scripts" "$d/repo/scripts"
  if [ "$mode" = "fail" ]; then
    # A chmod that refuses. This is the destination-denies-mode-changes case,
    # reproduced deterministically instead of hunting for such a filesystem.
    printf '#!/bin/sh\nexit 1\n' > "$d/bin/chmod"
    command chmod +x "$d/bin/chmod"
  else
    ln -s "$(command -v chmod)" "$d/bin/chmod"
  fi
  printf 'sensor\n' > "$d/repo/scripts/observe.sh"

  sed -n '/# INSTALL-SCRIPT-COPY-BEGIN (observe.sh)/,/# INSTALL-SCRIPT-COPY-END (observe.sh)/p' \
    "$INSTALL_SH" > "$d/block.sh"
  # The markers must actually be there — an extraction that silently produced an
  # empty file would make every assertion below vacuous.
  if [ ! -s "$d/block.sh" ]; then
    ISC_OUT="EXTRACTION FAILED: no INSTALL-SCRIPT-COPY markers in $INSTALL_SH"
    ISC_RC=99; ISC_DEST="$d/home/scripts/observe.sh"
    return 0
  fi

  {
    # install.sh's OWN shell settings — the abort under test only happens with -e.
    echo 'set -euo pipefail'
    echo 'ok()   { printf "OK: %s\n" "$1"; }'
    echo 'warn() { printf "WARN: %s\n" "$1"; }'
    echo "REPO_ROOT=$d/repo"
    echo "CLAUDE_HOME=$d/home"
    cat "$d/block.sh"
    # If this prints, the installer survived the block and later steps would run.
    echo 'printf "REACHED-END-OF-INSTALLER\n"'
  } > "$d/run.sh"

  ISC_OUT=$(PATH="$d/bin:/usr/bin:/bin" bash "$d/run.sh" 2>&1)
  ISC_RC=$?
  ISC_DEST="$d/home/scripts/observe.sh"
  return 0
}

# ---------------------------------------------------------------------------
# TC-ISC-1..3 — a failing chmod must not take the installer down with it.
# FALSIFYING EDIT: restore the bare `chmod +x "$CLAUDE_HOME/scripts/observe.sh"`
# inside the `then` branch of install.sh's observe.sh block — 1, 2 and 3 go red.
# ---------------------------------------------------------------------------
run_shipped_block fail
assert_rc "TC-ISC-1: a chmod that fails does not abort the installer" 0 "$ISC_RC" "$ISC_OUT"
assert_contains "TC-ISC-2: and the later steps still run (the block did not exit)" \
  "REACHED-END-OF-INSTALLER" "$ISC_OUT"
assert_contains "TC-ISC-3: and it warns with the actual remedy command, not 'Copied'" \
  "Fix with: chmod +x" "$ISC_OUT"
# The distinction that matters to a reader: a warning, NOT a success line.
assert_true "TC-ISC-4: and it does NOT claim the copy succeeded" \
  "output still contained an OK: line" \
  bash -c '[[ "$1" != *"OK: Copied"* ]]' _ "$ISC_OUT"

# ---------------------------------------------------------------------------
# TC-ISC-5..6 (CONTROL) — without these, a block that had simply stopped copying
# anything would pass every assertion above.
# ---------------------------------------------------------------------------
run_shipped_block work
assert_contains "TC-ISC-5: with a working chmod the block still reports the copy" \
  "OK: Copied observe.sh" "$ISC_OUT"
assert_true "TC-ISC-6: and the installed file really is executable" \
  "destination is not executable" \
  test -x "$ISC_DEST"

# ---------------------------------------------------------------------------
# TC-ISC-7 — THE SIBLINGS. install.sh installs eight scripts and a directory of
# hooks by the same idiom, and the recurring defect in this repo is a fix applied
# to one derivation and not the others. A bare `chmod` in statement position is
# the shape that aborts under `set -e`, so none may remain: every one must be a
# CONDITION (`if chmod …`), part of an `&&`/`||` chain, or explicitly tolerated.
#
# Deliberately NOT scoped to $CLAUDE_HOME — the point is to catch the next one
# wherever it is added.
# ---------------------------------------------------------------------------
ISC_BARE=$(grep -nE '^[[:space:]]*chmod ' "$INSTALL_SH" | grep -vE '(\|\||&&)' || true)
assert_true "TC-ISC-7: no unchecked bare 'chmod' remains in install.sh (aborts under set -e)" \
  "unchecked chmod at: $(printf '%s' "$ISC_BARE" | tr '\n' ' ')" \
  test -z "$ISC_BARE"

# TC-ISC-8 — the other half of the same class: a `chmod`/`cp` whose result is
# discarded with `|| true` and then followed by an unconditional success line.
# That pair is what genuinely printed "Copied …" after a failure.
ISC_OKAFTER=$(awk '
  function is_success(line) {
    return line ~ /(^|;|&&)[[:space:]]*ok "(Copied|Hook scripts)/
  }
  {
    # Catch an unconditional success on the same source line as the discarded
    # result, as well as after blank/comment-only lines. Stop at the next real
    # statement so an unrelated later success is not attributed to this one.
    if ($0 !~ /^[[:space:]]*#/ && $0 ~ /\|\|[[:space:]]*true/) {
      rest = $0
      sub(/^.*\|\|[[:space:]]*true/, "", rest)
      if (is_success(rest)) print NR ":" $0
      pending = 1
      next
    }
    if (pending) {
      if ($0 ~ /^[[:space:]]*(#|$)/) next
      if (is_success($0)) print NR ":" $0
      pending = 0
    }
  }
' "$INSTALL_SH")
assert_true "TC-ISC-8: no 'result discarded with || true' immediately followed by an ok() success line" \
  "found: $(printf '%s' "$ISC_OKAFTER" | tr '\n' ' ')" \
  test -z "$ISC_OKAFTER"

# TC-ISC-9..10 (Automated review): the recorded Claude executable must be canonicalized
# before the lexical trusted-prefix check. Otherwise a traversal or a symlink
# can make an untrusted target look like a native install.
ISC_TRUST_FN=$(sed -n '/^is_trusted_claude_path()/,/^}/p' "$INSTALL_SH")
ISC_CANON_LINE=$(printf '%s\n' "$ISC_TRUST_FN" | grep -nF 'resolved="$(canonicalize_path "$candidate"' | cut -d: -f1 | head -1)
ISC_CASE_LINE=$(printf '%s\n' "$ISC_TRUST_FN" | grep -nF 'case "$resolved" in' | cut -d: -f1 | head -1)
assert_true "TC-ISC-9: installer canonicalizes Claude candidates before the trust case" \
  "canonicalization line=$ISC_CANON_LINE case line=$ISC_CASE_LINE" \
  bash -c 'test "$1" -gt 0 && test "$2" -gt 0 && test "$1" -lt "$2"' \
    _ "$ISC_CANON_LINE" "$ISC_CASE_LINE"
assert_true "TC-ISC-10: installer records the canonical Claude target" \
  "record block does not canonicalize before its trust check" \
  bash -c 'block="$1"; canon=$(printf "%s\\n" "$block" | grep -nF '\''CLAUDE_BIN_RESOLVED="$(canonicalize_path "$CLAUDE_BIN_RESOLVED"'\'' | cut -d: -f1 | head -1); trust=$(printf "%s\\n" "$block" | grep -nF '\''is_trusted_claude_path "$CLAUDE_BIN_RESOLVED"'\'' | cut -d: -f1 | head -1); test -n "$canon" && test -n "$trust" && test "$canon" -lt "$trust"' _ "$(sed -n '/CLAUDE_BIN_RECORD=/,/if \[ -n /p' "$INSTALL_SH")"
assert_contains "TC-ISC-11: canonicalization uses only fixed readlink locations" \
  'for readlink_candidate in /usr/bin/readlink /bin/readlink' "$(sed -n '/^canonicalize_path()/,/^}/p' "$INSTALL_SH")"
assert_true "TC-ISC-12: canonicalization has no PATH-based readlink fallback" \
  "canonicalization must not resolve readlink through PATH" \
  bash -c 'fn="$1"; ! grep -Eq '\''(^|[^[:alnum:]_./-])readlink([[:space:]]|$)'\'' <<< "$fn"' _ "$(sed -n '/^canonicalize_path()/,/^}/p' "$INSTALL_SH")"

# TC-ISC-13 — the Codex registrar must be independently guarded from the
# optional GoalRun runtime copy. A partial Codex installation still needs the
# provider-neutral PR-poll helper, so the copy condition must test only the
# registrar source before copying it.
ISC_CODEX_POLL_GUARD=$(grep -nF \
  'if [ -f "$REPO_ROOT/scripts/register-pr-poll.sh" ] && cp -v "$REPO_ROOT/scripts/register-pr-poll.sh" "$CODEX_BIN_HOME/"' \
  "$INSTALL_SH" | cut -d: -f1 | head -1)
ISC_CODEX_GOAL_OK=$(grep -nF 'ok "Copied durable goal-loop runtime to $CODEX_BIN_HOME/"' "$INSTALL_SH" \
  | cut -d: -f1 | head -1)
assert_true "TC-ISC-13: Codex PR registrar is independent of GoalRun runtime copy" \
  "registrar guard line=$ISC_CODEX_POLL_GUARD goal-loop success line=$ISC_CODEX_GOAL_OK" \
  bash -c 'test -n "$1" && test -n "$2" && test "$1" -gt "$2"' \
  _ "$ISC_CODEX_POLL_GUARD" "$ISC_CODEX_GOAL_OK"

# TC-ISC-14 — execute the shipped Codex install block with the GoalRun files
# absent. This is the behavioural proof the static line-order check cannot
# provide: a nested registrar copy is skipped by the missing runtime files,
# while an independent copy must still produce an executable helper.
run_codex_partial_block() {
  local d block
  d=$(mktemp -d "$WORK/codex-partial.XXXXXX")
  mkdir -p "$d/repo/scripts" "$d/codex"
  printf '#!/bin/sh\nprintf registrar\n' > "$d/repo/scripts/register-pr-poll.sh"
  chmod +x "$d/repo/scripts/register-pr-poll.sh"
  block=$(awk '
    /^CODEX_HOME_DIR=/ { active=1 }
    /^# Keep Codex'"'"'s local merge hook/ { active=0 }
    active { print }
  ' "$INSTALL_SH")
  if [[ -z "$block" ]]; then
    ISC_OUT="EXTRACTION FAILED: Codex install block not found"
    ISC_RC=99
    ISC_CODEX_DEST="$d/codex/bin/register-pr-poll.sh"
    return 0
  fi
  {
    echo 'set -euo pipefail'
    echo 'ok() { printf "OK: %s\\n" "$1"; }'
    echo 'warn() { printf "WARN: %s\\n" "$1"; }'
    printf 'REPO_ROOT=%q\n' "$d/repo"
    printf 'CODEX_HOME=%q\n' "$d/codex"
    printf '%s\n' "$block"
  } > "$d/run.sh"
  ISC_OUT=$(bash "$d/run.sh" 2>&1)
  ISC_RC=$?
  ISC_CODEX_DEST="$d/codex/bin/register-pr-poll.sh"
}

run_codex_partial_block
assert_rc "TC-ISC-14: partial Codex install still copies PR registrar" 0 "$ISC_RC" "$ISC_OUT"
assert_true "TC-ISC-14b: partial Codex install makes registrar executable" \
  "registrar was not installed at $ISC_CODEX_DEST" \
  test -x "$ISC_CODEX_DEST"

echo ""
echo "=== install.sh utility-script copy: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
  echo ""
  echo "Failures:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - $t"
  done
  exit 1
fi
exit 0
