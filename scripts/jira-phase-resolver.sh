#!/usr/bin/env bash
# Resolve one universal Jira phase against a live board and explicit phase map.
#
# Usage:
#   jira-phase-resolver.sh <input.json>
#
# The input is JSON with phase, phase_map, live_columns, and either
# current_column or current_status_id plus status_to_column from
# jira-board-columns.sh --mapping. For a transition, available_transitions
# must contain the target column names Jira currently allows from the ticket's
# state; no-transition and in-place decisions do not need that field.
#
# The output is one JSON decision with action:
#   transition | no_transition | in_place | blocked
# Blocked decisions exit 2; all other decisions exit 0.
# This helper is deliberately network-free. The caller owns live API reads;
# this script owns the deterministic decision and safety checks.

set -u

INPUT_FILE="${1:-}"
if [ -z "$INPUT_FILE" ]; then
  printf '%s\n' 'Usage: jira-phase-resolver.sh <input.json>' >&2
  exit 2
fi

python3 - "$INPUT_FILE" <<'PY'
import json
import sys


def blocked(reason, message, **extra):
    result = {"action": "blocked", "reason": reason, "message": message}
    result.update(extra)
    print(json.dumps(result, sort_keys=True))
    raise SystemExit(2)


try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        data = json.load(handle)
except (OSError, json.JSONDecodeError) as exc:
    blocked("invalid_input", f"could not read valid JSON input: {exc}")

if not isinstance(data, dict):
    blocked("invalid_input", "input must be a JSON object")

required = ("phase", "phase_map", "live_columns")
missing = [key for key in required if key not in data]
if missing:
    blocked("invalid_input", f"missing required field(s): {', '.join(missing)}")

phase = data["phase"]
phase_map = data["phase_map"]
live_columns = data["live_columns"]
if not isinstance(phase, str) or not isinstance(phase_map, dict):
    blocked("invalid_input", "phase must be a string and phase_map must be an object")
if not isinstance(live_columns, list) or not all(isinstance(column, str) for column in live_columns):
    blocked("invalid_input", "live_columns must be an array of strings")

if "status_to_column" in data:
    status_to_column = data["status_to_column"]
    status_id = str(data.get("current_status_id", ""))
    if not isinstance(status_to_column, dict) or not status_id:
        blocked("current_status_unmapped", "current_status_id and status_to_column are required together")
    current_column = status_to_column.get(status_id)
    if not isinstance(current_column, str) or not current_column:
        blocked("current_status_unmapped", f"current status ID {status_id!r} has no board-column mapping")
    if not any(column.casefold() == current_column.casefold() for column in live_columns):
        blocked(
            "current_column_missing",
            f"current column {current_column!r} is not on the live board",
            current_column=current_column,
        )
    supplied_column = data.get("current_column")
    if supplied_column is not None and str(supplied_column).casefold() != current_column.casefold():
        blocked("current_column_mismatch", "current_column disagrees with status_to_column", current_column=current_column)
else:
    current_column = data.get("current_column")
    if not isinstance(current_column, str) or not current_column:
        blocked("invalid_input", "current_column or status_to_column/current_status_id is required")

if phase not in phase_map:
    blocked("phase_missing", f"phase {phase!r} is missing from phase_map", phase=phase, current_column=current_column)

target_column = phase_map[phase]
if target_column is None:
    print(json.dumps({
        "action": "no_transition",
        "reason": "phase_unmapped",
        "phase": phase,
        "current_column": current_column,
    }, sort_keys=True))
    raise SystemExit(0)

if not isinstance(target_column, str) or not target_column:
    blocked("invalid_phase_map", f"phase {phase!r} must map to a column name or null")

live_by_name = {column.casefold(): column for column in live_columns}
target_key = target_column.casefold()
if target_key not in live_by_name:
    blocked(
        "mapped_column_missing",
        f"phase {phase!r} maps to {target_column!r}, which is not on the live board",
        phase=phase,
        target_column=target_column,
        current_column=current_column,
    )

canonical_target = live_by_name[target_key]
if canonical_target.casefold() == current_column.casefold():
    print(json.dumps({
        "action": "in_place",
        "reason": "target_is_current",
        "phase": phase,
        "current_column": current_column,
        "target_column": canonical_target,
    }, sort_keys=True))
    raise SystemExit(0)

if "available_transitions" not in data:
    blocked(
        "transition_unavailable",
        "Jira transition permissions were not supplied",
        phase=phase,
        current_column=current_column,
        target_column=canonical_target,
    )

transitions = data["available_transitions"]
if not isinstance(transitions, list) or not all(isinstance(target, str) for target in transitions):
    blocked("invalid_input", "available_transitions must be an array of strings")
if not any(target.casefold() == canonical_target.casefold() for target in transitions):
    blocked(
        "transition_unavailable",
        f"Jira does not currently allow transition to {canonical_target!r}",
        phase=phase,
        current_column=current_column,
        target_column=canonical_target,
    )

print(json.dumps({
    "action": "transition",
    "reason": "mapped_phase_target",
    "phase": phase,
    "current_column": current_column,
    "target_column": canonical_target,
}, sort_keys=True))
PY
