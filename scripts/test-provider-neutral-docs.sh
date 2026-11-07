#!/usr/bin/env bash
# Regression checks for the user-facing provider-neutral setup guidance.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FAILURES=0
CHECKS=0

pass() {
  CHECKS=$((CHECKS + 1))
  printf 'PASS: %s\n' "$1"
}

fail() {
  CHECKS=$((CHECKS + 1))
  FAILURES=$((FAILURES + 1))
  printf 'FAIL: %s\n' "$1"
}

contains() {
  local file="$1" text="$2" label="$3"
  if grep -Fq -- "$text" "$REPO_ROOT/$file"; then
    pass "$label"
  else
    fail "$label — missing '$text' in $file"
  fi
}

not_contains() {
  local file="$1" text="$2" label="$3"
  if grep -Fq -- "$text" "$REPO_ROOT/$file"; then
    fail "$label — stale '$text' remains in $file"
  else
    pass "$label"
  fi
}

extract_first_code_block() {
  local file="$1" start="$2" end="$3"
  awk -v start="$start" -v end="$end" '
    index($0, start) {inside=1}
    inside && index($0, end) {ended=1; exit}
    inside && /^```/ && !seen {seen=1; code=1; next}
    code && /^```$/ {code=0; next}
    code {print}
    END {if (!ended || !seen || code) exit 2}
  ' "$file"
}

section_first_code_block_contains() {
  local file="$1" start="$2" end="$3" text="$4" label="$5"
  local section_output section_rc
  section_output=$(extract_first_code_block "$REPO_ROOT/$file" "$start" "$end")
  section_rc=$?
  if [ "$section_rc" -eq 0 ] && printf '%s\n' "$section_output" | grep -Fxq -- "$text"; then
    pass "$label"
  else
    fail "$label — missing '$text' in the first code block between '$start' and '$end' in $file"
  fi
}

TEST_FIXTURE=$(mktemp)
trap 'rm -f "$TEST_FIXTURE"' EXIT
printf '%s\n' '### Step 2' '```bash' 'wrong-default' '```' '### Later' '```bash' './scripts/install.sh' '```' '### Step 3' > "$TEST_FIXTURE"
first_block_output=$(extract_first_code_block "$TEST_FIXTURE" '### Step 2' '### Step 3')
first_block_rc=$?
if [ "$first_block_rc" -eq 0 ] && [ "$first_block_output" = 'wrong-default' ]; then
  pass 'first code block helper ignores later code blocks'
else
  fail 'first code block helper does not isolate the first code block'
fi

printf '%s\n' '### Step 2' '```bash' './scripts/install.sh' '```' > "$TEST_FIXTURE"
if extract_first_code_block "$TEST_FIXTURE" '### Step 2' '### Missing' >/dev/null; then
  fail 'first code block helper accepts a missing end marker'
else
  pass 'first code block helper rejects a missing end marker'
fi

contains README.md 'INSTALL_CODEX=1 ./scripts/install.sh' 'README gives the explicit Codex install command'
contains README.md 'INSTALL_CODEX=0 ./scripts/install.sh' 'README gives the explicit Claude-only install command'
contains docs/getting-started.md 'INSTALL_CODEX=1 ./scripts/install.sh' 'long setup guide gives the explicit Codex install command'
contains docs/getting-started.md 'INSTALL_CODEX=0 ./scripts/install.sh' 'long setup guide gives the explicit Claude-only install command'

contains README.md 'Claude Code and Codex' 'README names both supported providers'
contains README.md 'INSTALL_CODEX=1' 'README documents non-interactive Codex enablement'
contains README.md 'INSTALL_CODEX=0' 'README documents explicit Codex disablement'
contains README.md 'goal → plan → act → verify → checkpoint → repeat' 'README explains the common goal loop'
contains README.md 'Direct commands — optional shortcuts' 'README labels direct commands as optional'
contains README.md 'In Codex, describe the goal' 'README explains the Codex entry path'
contains README.md 'GOAL_LOOP_CODEX_COMMAND' 'README documents the durable Codex wrapper requirement'
section_first_code_block_contains README.md '### Step 2 — Install the toolbox' '### Step 3 — Open your provider and start' './scripts/install.sh' 'README has a provider-neutral default install command'
not_contains README.md 'Three steps: install Claude Code, install the toolbox, start working.' 'README no longer presents Claude as the only setup'
contains docs/getting-started.md 'Codex CLI' 'long setup guide names the Codex CLI'
contains docs/getting-started.md 'Claude Code and Codex use the same toolbox' 'long setup guide states shared behavior'
contains docs/getting-started.md 'INSTALL_CODEX=1' 'long setup guide documents Codex enablement'
contains docs/getting-started.md 'INSTALL_CODEX=0' 'long setup guide documents Codex disablement'
contains docs/getting-started.md 'GOAL_LOOP_CODEX_COMMAND' 'long setup guide documents the durable Codex wrapper requirement'
section_first_code_block_contains docs/getting-started.md '### Install the toolbox' '### Start working' './scripts/install.sh' 'long setup guide has a provider-neutral default install command'
contains docs/how-to/commands.md 'Claude Code command menu' 'command reference labels the host-specific menu'
contains CLAUDE.md 'Provider-neutral operation' 'canonical instructions define provider-neutral operation'

if [ "$FAILURES" -eq 0 ]; then
  printf 'All %s provider-neutral documentation checks passed.\n' "$CHECKS"
  exit 0
fi

printf '%s provider-neutral documentation checks failed.\n' "$FAILURES"
exit 1
