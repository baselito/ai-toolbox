#!/usr/bin/env bash
# =============================================================================
# Reads actual Jira board column names via the REST API.
#
# Usage:
#   ./scripts/jira-board-columns.sh <board_id>             → column names (default)
#   ./scripts/jira-board-columns.sh <board_id> --mapping   → JSON status-to-column map
#   ./scripts/jira-board-columns.sh <board_id> --json      → JSON array of column names
#
# Output (default):
#   Column names separated by " → " (e.g. "Backlog → Discovery → In Progress → Done")
#
# Output (--mapping):
#   JSON mapping of status IDs to column names, for grouping tickets by column:
#   {"10000": "Backlog", "10503": "Discovery", "3": "In Progress", ...}
#
# Output (--json):
#   JSON array of column names in board order, used by /init (anchor question
#   dropdowns) and /flow (drift validation against jira_phase_map):
#   ["Backlog", "Selected for Development", "In Progress", "Ready for Release", "Done"]
#
# DEDUPLICATION:
#   The same column name can appear twice in the API response when a board
#   admin has linked multiple statuses to one column or has created a duplicate
#   column with the same display name (TASK-738 case — the user's screenshot
#   showed 5 distinct columns but the API returned 6 entries with one repeat).
#   We collapse adjacent and non-adjacent duplicates by NAME, preserving order
#   of first appearance. This is safe because the toolbox reasons about
#   columns by NAME, not by id — two API entries with the same name represent
#   the same UI swimlane to the user.
#
# Exit 1 if it fails — caller should ask the user manually.
# =============================================================================

set -e

BOARD_ID="${1:?Usage: jira-board-columns.sh <board_id> [--mapping|--json]}"
MODE="${2:-columns}"

# --- Get email from acli config ---
EMAIL=""
if [ -f "$HOME/.config/acli/jira_config.yaml" ]; then
  EMAIL=$(grep 'email:' "$HOME/.config/acli/jira_config.yaml" | head -1 | sed 's/.*email: *//')
fi
if [ -z "$EMAIL" ]; then
  echo "ERROR: Could not read email from acli config" >&2
  exit 1
fi

# --- Get site from acli config ---
SITE=""
if [ -f "$HOME/.config/acli/jira_config.yaml" ]; then
  SITE=$(grep 'site:' "$HOME/.config/acli/jira_config.yaml" | head -1 | sed 's/.*site: *//')
fi
if [ -z "$SITE" ]; then
  echo "ERROR: Could not read site from acli config" >&2
  exit 1
fi

# --- Get API token from keychain ---
TOKEN=""

# macOS: acli stores token in keychain with service name "acli"
# The value is prefixed with "go-keyring-base64:" and base64 encoded
if command -v security &>/dev/null; then
  RAW=$(security find-generic-password -s "acli" -w 2>/dev/null || echo "")
  if [ -n "$RAW" ]; then
    # Strip the go-keyring-base64: prefix and decode
    TOKEN=$(echo "$RAW" | python3 -c "
import sys, base64
raw = sys.stdin.read().strip()
if raw.startswith('go-keyring-base64:'):
    raw = raw.replace('go-keyring-base64:', '')
try:
    print(base64.b64decode(raw).decode())
except:
    print(raw)
" 2>/dev/null)
  fi
fi

# Linux: try secret-tool (GNOME keyring)
if [ -z "$TOKEN" ] && command -v secret-tool &>/dev/null; then
  TOKEN=$(secret-tool lookup service acli 2>/dev/null || echo "")
fi

# Fallback: check environment variable
if [ -z "$TOKEN" ] && [ -n "$ATLASSIAN_API_TOKEN" ]; then
  TOKEN="$ATLASSIAN_API_TOKEN"
fi

if [ -z "$TOKEN" ]; then
  echo "ERROR: Could not extract API token from keychain or environment" >&2
  echo "Set ATLASSIAN_API_TOKEN in your shell profile, or re-authenticate: acli jira auth login" >&2
  exit 1
fi

# --- Call Jira REST API for board column configuration ---
RESPONSE=$(curl -s -w "\n%{http_code}" \
  -u "$EMAIL:$TOKEN" \
  "https://$SITE/rest/agile/1.0/board/$BOARD_ID/configuration" 2>/dev/null)

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "200" ]; then
  echo "ERROR: Jira API returned HTTP $HTTP_CODE" >&2
  echo "$BODY" >&2
  exit 1
fi

# --- Parse output based on mode ---
# All three modes share the same dedup-by-name logic via Python's dict.fromkeys
# (preserves first-seen order, drops later duplicates) so /init dropdowns,
# /flow drift validation, and the legacy " → " join all see the same canonical
# column list.

if [ "$MODE" = "--mapping" ]; then
  # Output JSON mapping: status ID → column name
  # Used by the agent to group tickets by actual board column
  echo "$BODY" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
mapping = {}
for col in data.get('columnConfig', {}).get('columns', []):
    name = col['name']
    for status in col.get('statuses', []):
        # status has 'id' field
        sid = status.get('id', '')
        if sid:
            mapping[sid] = name
if mapping:
    print(json.dumps(mapping))
else:
    print('ERROR: No status-to-column mapping found', file=sys.stderr)
    sys.exit(1)
"
elif [ "$MODE" = "--json" ]; then
  # Output JSON array of column names in board order, deduplicated by name.
  # /init reads this for anchor-question dropdowns; /flow reads it at workflow
  # start to validate jira_phase_map against the live board (drift detection).
  echo "$BODY" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
raw = [col['name'] for col in data.get('columnConfig', {}).get('columns', [])]
# Preserve first-seen order while dropping duplicates — fixes TASK-738 where
# the API reported 6 entries for a 5-column board.
columns = list(dict.fromkeys(raw))
if columns:
    print(json.dumps(columns))
else:
    print('ERROR: No columns found in board configuration', file=sys.stderr)
    sys.exit(1)
"
else
  # Output column names as a human-readable arrow-joined string.
  # Same dedup logic so /init's confirmation prompt matches what /flow sees.
  echo "$BODY" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
raw = [col['name'] for col in data.get('columnConfig', {}).get('columns', [])]
columns = list(dict.fromkeys(raw))
if columns:
    print(' → '.join(columns))
else:
    print('ERROR: No columns found in board configuration', file=sys.stderr)
    sys.exit(1)
"
fi
