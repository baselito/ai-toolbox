#!/usr/bin/env bash
# Regression checks for the concise, milestone-based Jira update policy.

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

contains() {
  local file="$1"
  local text="$2"
  local name="$3"
  if rg -Fq -- "$text" "$ROOT_DIR/$file"; then
    pass "$name"
  else
    fail "$name"
  fi
}

absent() {
  local file="$1"
  local text="$2"
  local name="$3"
  if rg -Fq -- "$text" "$ROOT_DIR/$file"; then
    fail "$name"
  else
    pass "$name"
  fi
}

printf '\n=== Jira comment policy checks ===\n'

contains "rules/agents.md" "Jira updates are milestone-based" "global rules define milestone updates"
contains "rules/agents.md" "Routine phase summaries, brainstorming, planning detail, reviewer activity, polling, retries," "global rules exclude routine narration"
contains "commands/flow.md" "## Jira Update Policy — short milestones, not every phase" "flow defines concise update policy"
contains "commands/flow.md" "**Start:** one short sentence when work begins." "flow defines the three normal updates"
contains "skills/flow-reference/SKILL.md" "## Jira Update Policy — milestone comments" "reference skill defines the same policy"
contains "agents/jira-workflow-steward.md" "does not post a comment for every phase" "steward no longer infers comments from phases"

absent "rules/agents.md" "EVERY PHASE ends with a Jira comment" "global rules remove every-phase mandate"
absent "commands/flow.md" "**8 comments**" "flow removes eight-comment expectation"
absent "skills/flow-reference/SKILL.md" "The 8 Jira comments are posted" "reference removes eight-comment expectation"
absent "agents/jira-workflow-steward.md" "every phase produces a comment" "steward removes every-phase mandate"

printf '\nJira comment policy: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
