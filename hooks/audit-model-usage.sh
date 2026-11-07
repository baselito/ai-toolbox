#!/bin/bash
# audit-model-usage.sh
#
# PostToolUse hook on Agent tool.
# Logs every Agent spawn with timestamp, agent type, model, and description
# to ~/.claude/model-audit.log. Creates an external audit trail that can be
# reviewed independently of the handover (which is self-reported).
#
# Incident: TASK-760 — handover recorded "✅ match" for model routing but the
# orchestrator ran a skill inline on the wrong model. Self-reported model
# compliance is not independently verifiable.

set -uo pipefail

if ! command -v jq &>/dev/null; then
  exit 0
fi

HOOK_DATA=$(cat) || exit 0

TOOL_NAME=$(echo "$HOOK_DATA" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0

if [[ "$TOOL_NAME" != "Agent" ]]; then
  exit 0
fi

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
AGENT_TYPE=$(echo "$HOOK_DATA" | jq -r '.tool_input.subagent_type // "general-purpose"' 2>/dev/null || echo "unknown")
MODEL=$(echo "$HOOK_DATA" | jq -r '.tool_input.model // "inherited"' 2>/dev/null || echo "unknown")
# Sanitize description: collapse to single line, strip control chars, truncate
DESCRIPTION=$(echo "$HOOK_DATA" | jq -r '.tool_input.description // "no description"' 2>/dev/null || echo "no description")
DESCRIPTION=$(printf '%s' "$DESCRIPTION" | tr '\n\r\t' '   ' | tr -cd '[:print:] ' | tr -s ' ' | cut -c1-120)

LOG_FILE="$HOME/.claude/model-audit.log"
mkdir -p "$(dirname "$LOG_FILE")"

printf '[%s] agent=%s model=%s desc=%s\n' "$TIMESTAMP" "$AGENT_TYPE" "$MODEL" "$DESCRIPTION" >> "$LOG_FILE"

exit 0
