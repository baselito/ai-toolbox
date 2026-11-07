#!/bin/bash
# compliance-auditor.sh
#
# PostToolUse hook that runs after skill invocations.
# Independently verifies orchestration compliance — replaces self-reported checks.
#
# Checks (all write warnings to stderr — visible to agent in context):
#   1. Execution plan exists in handover.md (chief-of-staff Step 1.8)
#   2. Code review section mentions chief-of-staff/code-review-orchestration
#   3. Model routing entries exist (Model: X — Expected: Y → ✅/❌)
#   4. Phase-map adherence — phases in handover used valid phase keys, not
#      hardcoded column names. The orchestrator should pass `phase=<key>` to
#      jira-workflow-steward; if it instead names a column directly we want
#      to flag the regression. Soft-check (warning, not blocker).
#
# This is a WARNING hook, not a blocker. The agent sees the warnings and
# must acknowledge them. Combined with the PreToolUse hooks (which block),
# this provides post-hoc verification for things hooks can't prevent.

set -euo pipefail

# Guard: ensure jq is available
if ! command -v jq &>/dev/null; then
  echo "WARNING: jq not installed — compliance-auditor hook cannot run" >&2
  exit 0
fi

HOOK_DATA=$(cat)

TOOL_NAME=$(echo "$HOOK_DATA" | jq -r '.tool_name // empty')
CWD=$(echo "$HOOK_DATA" | jq -r '.cwd // empty')

# Only run after Skill tool calls
if [[ "$TOOL_NAME" != "Skill" ]]; then
  exit 0
fi

HANDOVER_FILE="$CWD/.claude/handover.md"

# Check if handover file exists
if [[ ! -f "$HANDOVER_FILE" ]]; then
  exit 0
fi

WARNINGS=""

# Check 1: Does the execution plan exist?
# Chief-of-staff should have created this at Step 1.8
if ! grep -q "## Execution Plan" "$HANDOVER_FILE" 2>/dev/null; then
  WARNINGS="${WARNINGS}[Compliance Audit] WARNING: No '## Execution Plan' section found in handover.md. Chief-of-staff should have created this at Step 1.8. Was Step 1.8 skipped?\n"
fi

# Check 2: Code review section has structured orchestration evidence.
#
# MATCHING RULE: Must find specific structured phrases that the skill
# itself produces, not just any mention of the skill name. Plain
# substring match for "chief-of-staff" or "code-review-orchestration"
# is satisfied by passing mentions ("we considered the skill", "future
# use of chief-of-staff...") and produces false-positive PASS results.
#
# The skill's Step 5 return template (see SKILL.md) writes one of:
#   - "Orchestration: chief-of-staff (Opus) via code-review-orchestration"
#   - "Agents selected:" (the skill always emits this line with rationale)
#   - "Independence: Yes" (attestation line)
# At least one of these structured lines should appear.
# Matched with a here-string (`<<<`), NOT `echo | grep`: under `set -euo
# pipefail` the pipe form can SIGPIPE (141) on a large multiline Code Review
# section and flip the deny-on-no-match `if !` into wrongly reading a match
# (static guard: TC-CAUD-1).
if grep -q "## Code Review" "$HANDOVER_FILE" 2>/dev/null; then
  CODE_REVIEW_SECTION=$(awk '/^## Code Review/{found=1; next} /^## /{if(found) exit} found' "$HANDOVER_FILE" | head -30)

  if ! grep -qE "Orchestration:[[:space:]]+chief-of-staff|Agents selected:|Independence:[[:space:]]+Yes" <<< "$CODE_REVIEW_SECTION"; then
    WARNINGS="${WARNINGS}[Compliance Audit] WARNING: Code Review section lacks structured orchestration evidence. Expected one of: 'Orchestration: chief-of-staff ...', 'Agents selected: ...', or 'Independence: Yes'. Plain mention of 'chief-of-staff' does not satisfy this check — the structured phrases prove the skill's return template was used.\n"
  fi
fi

# Check 3: Model routing entries exist
# Each phase handover entry should have "Model: X — Expected: Y → ✅/❌"
if grep -q "Model:.*Expected:" "$HANDOVER_FILE" 2>/dev/null; then
  # Check for any violations (❌)
  VIOLATION_COUNT=$(grep -c "❌ VIOLATION" "$HANDOVER_FILE" 2>/dev/null || echo "0")
  if [[ "$VIOLATION_COUNT" -gt 0 ]]; then
    WARNINGS="${WARNINGS}[Compliance Audit] WARNING: ${VIOLATION_COUNT} model routing violation(s) found in handover.md. Check the Model: lines for phases that used the wrong model.\n"
  fi
else
  # No model routing entries at all — phases aren't reporting models
  PHASE_COUNT=$(grep -c "^## " "$HANDOVER_FILE" 2>/dev/null || echo "0")
  if [[ "$PHASE_COUNT" -gt 2 ]]; then
    # More than 2 phase sections but no model entries — agent isn't reporting
    WARNINGS="${WARNINGS}[Compliance Audit] WARNING: No 'Model: X — Expected: Y' entries found in handover.md despite multiple phases completed. Phase summaries must include model verification.\n"
  fi
fi

# Check 4: Phase-map adherence (soft).
#
# Two failure modes worth flagging:
#
# (a) Handover entries mention a Jira column directly (e.g. "moved to Ready
#     for Development") but never reference a phase key. Indicates the
#     orchestrator bypassed jira-workflow-steward's phase-map lookup and
#     hardcoded a column name — exactly the drift the phase map exists to
#     prevent. We grep for known phase keys; absence is the signal.
#
# (b) Phase-map drift validation (Step 0) was skipped. Step 0 writes
#     "Phase-map validated" or surfaces drift to the user. If neither
#     appears AND any phase= entry appears, the orchestrator likely jumped
#     past Step 0.
#
# This is a SOFT check — warns the agent but doesn't block. Hard enforcement
# would interfere with one-shot commands and the migration path for legacy
# `jira_columns` projects.
if grep -q "## Discovery\|## Implementation\|## Code Review\|## Verification" "$HANDOVER_FILE" 2>/dev/null; then
  if ! grep -qE "phase[[:space:]]*=[[:space:]]*(discovery|ready_for_dev|in_progress|code_review|ready_for_release)" "$HANDOVER_FILE" 2>/dev/null; then
    WARNINGS="${WARNINGS}[Compliance Audit] WARNING: Handover has phase entries but no 'phase=<key>' references found. The orchestrator should pass phase keys (discovery, ready_for_dev, in_progress, code_review, ready_for_release) to jira-workflow-steward — not hardcoded column names. If the project predates phase-mapping, run /flow Step 0 to migrate jira_columns → jira_phase_map.\n"
  fi

  if grep -qE "phase[[:space:]]*=[[:space:]]*(discovery|ready_for_dev|in_progress|code_review|ready_for_release)" "$HANDOVER_FILE" 2>/dev/null; then
    if ! grep -qE "Phase-map validated|Phase-map drift detected|Phase-map migration" "$HANDOVER_FILE" 2>/dev/null; then
      WARNINGS="${WARNINGS}[Compliance Audit] WARNING: Phase-map calls were made but Step 0 (drift validation) is not recorded in handover. Either /flow skipped Step 0, or the entry is missing. Future runs may break if a column was renamed since /init.\n"
    fi
  fi
fi

# Output all warnings to stderr (visible to agent)
if [[ -n "$WARNINGS" ]]; then
  echo -e "$WARNINGS" >&2
fi

exit 0
