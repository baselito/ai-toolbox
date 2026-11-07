#!/usr/bin/env bash
# Regression tests for the installer's non-mutating help path.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/install.sh"
WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
failed() { FAIL=$((FAIL + 1)); echo "  FAIL: $1${2:+ — $2}"; }

assert_rc() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" -eq "$expected" ]]; then pass "$name"; else failed "$name" "expected rc=$expected got rc=$actual"; fi
}
assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$name"; else failed "$name" "missing '$needle'"; fi
}
assert_true() {
  local name="$1" detail="$2"; shift 2
  if "$@"; then pass "$name"; else failed "$name" "$detail"; fi
}

run_help() {
  local home="$WORK/home-$1"
  mkdir -p "$home"
  HELP_OUT=$(HOME="$home" bash "$INSTALL_SH" "$1" 2>&1)
  HELP_RC=$?
  HELP_HOME="$home"
}

echo ""
echo "=== install.sh help ==="

run_help --help
assert_rc "--help exits successfully" 0 "$HELP_RC"
assert_contains "--help prints usage" "Usage:" "$HELP_OUT"
assert_contains "--help documents Codex opt-in" "INSTALL_CODEX=1" "$HELP_OUT"
assert_true "--help does not create Claude state" "HOME was mutated" test ! -e "$HELP_HOME/.claude"

run_help -h
assert_rc "-h exits successfully" 0 "$HELP_RC"
assert_contains "-h prints usage" "Usage:" "$HELP_OUT"
assert_true "-h does not create Claude state" "HOME was mutated" test ! -e "$HELP_HOME/.claude"

UNKNOWN_HOME="$WORK/unknown-home"
mkdir -p "$UNKNOWN_HOME"
UNKNOWN_OUT=$(HOME="$UNKNOWN_HOME" bash "$INSTALL_SH" --not-an-installer-option 2>&1)
UNKNOWN_RC=$?
assert_rc "unknown option fails" 2 "$UNKNOWN_RC"
assert_contains "unknown option prints usage" "Usage:" "$UNKNOWN_OUT"
assert_true "unknown option does not create Claude state" "HOME was mutated" test ! -e "$UNKNOWN_HOME/.claude"

if [[ "$FAIL" -eq 0 ]]; then
  echo "install-help: $PASS passed, $FAIL failed"
  exit 0
fi
echo "install-help: $PASS passed, $FAIL failed"
exit 1
