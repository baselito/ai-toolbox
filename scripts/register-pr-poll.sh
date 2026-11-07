#!/usr/bin/env bash
# Register the host-side poller for one PR.
# Claude Code records its CronCreate id; Codex desktop records its heartbeat
# automation id. Both are recorded in the existing per-PR cron-id marker so
# the Claude gate's trust boundary remains unchanged. Structured pending
# markers are per originating worktree; registration clears only the marker
# for the current checkout when that can be established.

set -euo pipefail

usage() {
  echo "usage: $0 --repo OWNER/REPO --pr NUMBER --provider claude|codex --poll-id ID" >&2
  exit 2
}

REPO=""
PR=""
PROVIDER=""
POLL_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) [[ $# -ge 2 ]] || usage; REPO="$2"; shift 2 ;;
    --pr) [[ $# -ge 2 ]] || usage; PR="$2"; shift 2 ;;
    --provider) [[ $# -ge 2 ]] || usage; PROVIDER="$2"; shift 2 ;;
    --poll-id) [[ $# -ge 2 ]] || usage; POLL_ID="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
[[ "$PR" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$PROVIDER" == "claude" || "$PROVIDER" == "codex" ]] || usage
[[ "$POLL_ID" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]*$ ]] || usage

# Preserve the existing Claude state-root contract while allowing a Codex
# installation to select the same shared state explicitly.
STATE_DIR="${AI_ENGINEERING_STATE_DIR:-${CLAUDE_STATE_DIR:-$HOME/.claude}}"
[[ "$STATE_DIR" == /* && -d "$STATE_DIR" && -r "$STATE_DIR" && -x "$STATE_DIR" ]] || {
  echo "state directory is not an existing absolute readable directory: $STATE_DIR" >&2
  exit 1
}

OWNER="${REPO%%/*}"
REPO_NAME="${REPO#*/}"
POLL_FILE="$STATE_DIR/.pr-${OWNER}-${REPO_NAME}-${PR}-cron-id"
PENDING_FILE="$STATE_DIR/.auto-poll-pending"

CURRENT_WORKTREE=""
CURRENT_WORKTREE=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -n "$CURRENT_WORKTREE" ]]; then
  CURRENT_WORKTREE=$(cd "$CURRENT_WORKTREE" 2>/dev/null && pwd -P || true)
fi

TMP_FILE="$(mktemp "$STATE_DIR/.pr-poll.XXXXXX")"
cleanup() { [[ -z "${TMP_FILE:-}" ]] || rm -f "$TMP_FILE"; }
trap cleanup EXIT
printf 'provider=%s\npoll_id=%s\nregistered_at=%s\n' \
  "$PROVIDER" "$POLL_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TMP_FILE"
chmod 600 "$TMP_FILE"
mv -f "$TMP_FILE" "$POLL_FILE"
TMP_FILE=""

# Never clear a pending marker belonging to another PR or worktree. Current
# markers are key/value records; accept the legacy two-token form during the
# upgrade. If multiple same-PR markers exist and the caller has no matching
# checkout, leave them in place rather than clearing an arbitrary obligation.
MATCHING_MARKERS=()
MATCHING_COUNT=0
STRUCTURED_MARKERS=()
for candidate in "$STATE_DIR/.auto-poll-pending" "$STATE_DIR"/.auto-poll-pending-*; do
  [[ -f "$candidate" ]] || continue
  marker_repo=""
  marker_pr=""
  marker_worktree=""
  marker_structured=0
  if grep -q '^repo=' "$candidate"; then
    marker_structured=1
    marker_repo=$(sed -n 's/^repo=//p' "$candidate" | head -1)
    marker_pr=$(sed -n 's/^pr=//p' "$candidate" | head -1)
    marker_worktree=$(sed -n 's/^worktree=//p' "$candidate" | head -1)
  elif [[ "$(awk '{print $1, $2}' "$candidate" 2>/dev/null || true)" == "$REPO $PR" ]]; then
    marker_repo="$REPO"
    marker_pr="$PR"
  fi
  [[ "$marker_repo" == "$REPO" && "$marker_pr" == "$PR" ]] || continue
  if [[ "$marker_structured" -eq 1 && -z "$marker_worktree" ]]; then
    continue
  fi
  if [[ "$marker_structured" -eq 1 && -z "$CURRENT_WORKTREE" ]]; then
    continue
  fi
  if [[ -n "$CURRENT_WORKTREE" && -n "$marker_worktree" ]]; then
    marker_worktree=$(cd "$marker_worktree" 2>/dev/null && pwd -P || true)
    [[ "$marker_worktree" == "$CURRENT_WORKTREE" ]] || continue
  fi
  MATCHING_MARKERS+=("$candidate")
  MATCHING_COUNT=$((MATCHING_COUNT + 1))
  [[ "$marker_structured" -eq 1 ]] && STRUCTURED_MARKERS+=("$candidate")
done
if [[ -n "$CURRENT_WORKTREE" ]]; then
  # Structured markers can be proven to belong to this checkout and may be
  # cleared. Legacy two-token markers have no worktree binding, so preserve
  # them when a Git checkout is known; deleting one would consume an
  # obligation that cannot be attributed to this caller. The registered poll
  # still lets the enforcement hook retire a legacy marker on its next pass.
  for marker in ${STRUCTURED_MARKERS+"${STRUCTURED_MARKERS[@]}"}; do
    rm -f "$marker"
  done
elif [[ "$MATCHING_COUNT" -eq 1 ]]; then
  rm -f "${MATCHING_MARKERS[0]}"
elif [[ "$MATCHING_COUNT" -gt 1 ]]; then
  echo "multiple pending markers match $REPO#$PR; run this from the owning worktree" >&2
  exit 1
fi

echo "registered $PROVIDER poll $POLL_ID for $REPO#$PR"
