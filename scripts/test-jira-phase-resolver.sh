#!/usr/bin/env bash
# Regression tests for jira-phase-resolver.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="$SCRIPT_DIR/jira-phase-resolver.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  printf '  PASS: %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL: %s\n' "$1"
}

if [ ! -x "$RESOLVER" ]; then
  fail "resolver is executable"
  printf '\nresolver test: %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

run_case() {
  local name="$1"
  local expected_action="$2"
  local expected_reason="$3"
  local json="$4"
  local fixture="$TMP_DIR/input.json"
  local output rc action reason

  printf '%s\n' "$json" > "$fixture"
  output=$("$RESOLVER" "$fixture" 2>"$TMP_DIR/stderr")
  rc=$?
  action=$(printf '%s' "$output" | jq -r '.action // empty' 2>/dev/null)
  reason=$(printf '%s' "$output" | jq -r '.reason // empty' 2>/dev/null)

  if [ "$action" = "$expected_action" ] && [ "$reason" = "$expected_reason" ]; then
    pass "$name (rc=$rc)"
  else
    fail "$name (rc=$rc action=$action reason=$reason output=$output)"
  fi
}

BOARD='["Backlog","Selected for Development","In Progress","Ready for Release","Done"]'
STATUS_MAP='{"10000":"Backlog","10985":"Selected for Development","3":"In Progress","10477":"Ready for Release","10002":"Done"}'
FULL_MAP='{"discovery":null,"ready_for_dev":"Selected for Development","in_progress":"In Progress","code_review":"In Progress","ready_for_release":"Ready for Release"}'

run_case "null discovery has no transition" "no_transition" "phase_unmapped" \
  "{\"phase\":\"discovery\",\"current_status_id\":\"10000\",\"status_to_column\":$STATUS_MAP,\"phase_map\":$FULL_MAP,\"live_columns\":$BOARD}"

run_case "ready-for-development transitions from backlog" "transition" "mapped_phase_target" \
  "{\"phase\":\"ready_for_dev\",\"current_column\":\"Backlog\",\"phase_map\":$FULL_MAP,\"live_columns\":$BOARD,\"available_transitions\":[\"Selected for Development\"]}"

run_case "lumped code review stays in place" "in_place" "target_is_current" \
  "{\"phase\":\"code_review\",\"current_column\":\"in progress\",\"phase_map\":$FULL_MAP,\"live_columns\":$BOARD}"

run_case "simplified board can omit ready-for-development" "transition" "mapped_phase_target" \
  '{"phase":"in_progress","current_column":"Backlog","phase_map":{"ready_for_dev":null,"in_progress":"Doing","code_review":"Doing","ready_for_release":null},"live_columns":["Backlog","Doing","Done"],"available_transitions":["Doing"]}'

run_case "stale mapped column blocks" "blocked" "mapped_column_missing" \
  "{\"phase\":\"ready_for_dev\",\"current_column\":\"Backlog\",\"phase_map\":{\"ready_for_dev\":\"Refined\"},\"live_columns\":$BOARD}"

run_case "missing phase key blocks" "blocked" "phase_missing" \
  "{\"phase\":\"ready_for_dev\",\"current_column\":\"Backlog\",\"phase_map\":{\"in_progress\":\"In Progress\"},\"live_columns\":$BOARD}"

run_case "unavailable transition blocks" "blocked" "transition_unavailable" \
	"{\"phase\":\"ready_for_dev\",\"current_column\":\"Backlog\",\"phase_map\":$FULL_MAP,\"live_columns\":$BOARD,\"available_transitions\":[\"In Progress\"]}"

run_case "stale current status mapping blocks" "blocked" "current_column_missing" \
	"{\"phase\":\"ready_for_dev\",\"current_status_id\":\"99999\",\"status_to_column\":{\"99999\":\"Removed\"},\"phase_map\":$FULL_MAP,\"live_columns\":$BOARD,\"available_transitions\":[\"Selected for Development\"]}"

run_case "missing transition permissions blocks" "blocked" "transition_unavailable" \
	"{\"phase\":\"ready_for_dev\",\"current_column\":\"Backlog\",\"phase_map\":$FULL_MAP,\"live_columns\":$BOARD}"

MALFORMED="$TMP_DIR/malformed.json"
printf '%s\n' '{not-json' > "$MALFORMED"
output=$("$RESOLVER" "$MALFORMED" 2>"$TMP_DIR/stderr")
rc=$?
if [ "$rc" -ne 0 ] && [ "$(printf '%s' "$output" | jq -r '.action // empty')" = "blocked" ] && [ "$(printf '%s' "$output" | jq -r '.reason // empty')" = "invalid_input" ]; then
  pass "malformed input blocks safely (rc=$rc)"
else
  fail "malformed input blocks safely (rc=$rc output=$output)"
fi

for non_object in '[]' 'null' '"text"'; do
	output=$(printf '%s\n' "$non_object" > "$MALFORMED"; "$RESOLVER" "$MALFORMED" 2>"$TMP_DIR/stderr")
	rc=$?
	if [ "$rc" -eq 2 ] && [ "$(printf '%s' "$output" | jq -r '.action // empty')" = "blocked" ] && [ "$(printf '%s' "$output" | jq -r '.reason // empty')" = "invalid_input" ]; then
		pass "non-object JSON blocks safely ($non_object, rc=$rc)"
	else
		fail "non-object JSON blocks safely ($non_object, rc=$rc output=$output)"
	fi
done

printf '\njira phase resolver: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
