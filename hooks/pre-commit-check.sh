#!/usr/bin/env bash

# =============================================================================
# Pre-commit check — catches stale counts and broken references
# Run automatically before every commit in the ai-engineering repo.
# Prevents pushing documentation that doesn't match the actual files.
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
ERRORS=0

fail() { printf "${RED}  ❌ %s${NC}\n" "$1"; ERRORS=$((ERRORS + 1)); }
ok()   { printf "${GREEN}  ✅ %s${NC}\n" "$1"; }

# ---------------------------------------------------------------------------
# Count actual files in repo
# ---------------------------------------------------------------------------
ACTUAL_AGENTS=$(find "$REPO_ROOT/agents" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
ACTUAL_SKILLS=$(find "$REPO_ROOT/skills" -maxdepth 1 -type d 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
ACTUAL_COMMANDS=$(find "$REPO_ROOT/commands" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
ACTUAL_RULES=$(find "$REPO_ROOT/rules" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
ACTUAL_DOCS=$(find "$REPO_ROOT/docs" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')

printf "\nPre-commit: checking counts and references...\n\n"

# ---------------------------------------------------------------------------
# Check README.md counts
# ---------------------------------------------------------------------------
README="$REPO_ROOT/README.md"
if [ -f "$README" ]; then
  # Custom agent count
  README_AGENTS=$(grep -o 'Agents | [0-9]* custom' "$README" | head -1 | grep -o '[0-9]*')
  if [ -n "$README_AGENTS" ] && [ "$README_AGENTS" != "$ACTUAL_AGENTS" ]; then
    fail "README: says $README_AGENTS custom agents, repo has $ACTUAL_AGENTS"
  fi

  # Command count
  README_CMDS=$(grep -o 'Commands | [0-9]*' "$README" | head -1 | grep -o '[0-9]*')
  if [ -n "$README_CMDS" ] && [ "$README_CMDS" != "$ACTUAL_COMMANDS" ]; then
    fail "README: says $README_CMDS commands, repo has $ACTUAL_COMMANDS"
  fi
fi

# ---------------------------------------------------------------------------
# Check CLAUDE.md counts
# ---------------------------------------------------------------------------
CLAUDEMD="$REPO_ROOT/CLAUDE.md"
if [ -f "$CLAUDEMD" ]; then
  # Command count
  CLAUDE_CMDS=$(grep -o 'Commands ([0-9]* total)' "$CLAUDEMD" | grep -o '[0-9]*')
  if [ -n "$CLAUDE_CMDS" ] && [ "$CLAUDE_CMDS" != "$ACTUAL_COMMANDS" ]; then
    fail "CLAUDE.md: says $CLAUDE_CMDS commands, repo has $ACTUAL_COMMANDS"
  fi

  # Agent directory count
  CLAUDE_AGENTS=$(grep -o 'agents/.*→ [0-9]* ' "$CLAUDEMD" | head -1 | grep -o '[0-9]*')
  if [ -n "$CLAUDE_AGENTS" ] && [ "$CLAUDE_AGENTS" != "$ACTUAL_AGENTS" ]; then
    fail "CLAUDE.md: says $CLAUDE_AGENTS agents in repo structure, repo has $ACTUAL_AGENTS"
  fi

  # Claude Code skills directory count (line with "copied to ~/.claude/skills/")
  CLAUDE_SKILLS=$(grep 'skills/.*copied to' "$CLAUDEMD" | grep -o '[0-9]*' | head -1)
  if [ -n "$CLAUDE_SKILLS" ] && [ "$CLAUDE_SKILLS" != "$ACTUAL_SKILLS" ]; then
    fail "CLAUDE.md: says $CLAUDE_SKILLS skills in repo structure, repo has $ACTUAL_SKILLS"
  fi
fi

# ---------------------------------------------------------------------------
# Check install.sh comments
# ---------------------------------------------------------------------------
INSTALL="$REPO_ROOT/scripts/install.sh"
if [ -f "$INSTALL" ]; then
  INSTALL_AGENTS=$(grep -o 'Copy agents ([0-9]* agents' "$INSTALL" | grep -o '[0-9]*')
  if [ -n "$INSTALL_AGENTS" ] && [ "$INSTALL_AGENTS" != "$ACTUAL_AGENTS" ]; then
    fail "install.sh: comment says $INSTALL_AGENTS agents, repo has $ACTUAL_AGENTS"
  fi

  INSTALL_SKILLS=$(grep -o 'Copy skills ([0-9]* skills' "$INSTALL" | grep -o '[0-9]*')
  if [ -n "$INSTALL_SKILLS" ] && [ "$INSTALL_SKILLS" != "$ACTUAL_SKILLS" ]; then
    fail "install.sh: comment says $INSTALL_SKILLS skills, repo has $ACTUAL_SKILLS"
  fi

  INSTALL_CMDS=$(grep -o 'Copy commands ([0-9]* commands' "$INSTALL" | grep -o '[0-9]*')
  if [ -n "$INSTALL_CMDS" ] && [ "$INSTALL_CMDS" != "$ACTUAL_COMMANDS" ]; then
    fail "install.sh: comment says $INSTALL_CMDS commands, repo has $ACTUAL_COMMANDS"
  fi
fi

# ---------------------------------------------------------------------------
# Check .claude-plugin/plugin.json component counts
#
# WHY THIS BLOCK EXISTS: plugin.json is the SEVENTH place a component count
# lives, and it was the only one no automation read. The `cross-tool-sync`
# skill's "How to Check" step 1 already NAMES it as a file to grep — but naming
# a file in a checklist is not enforcement. A branch that added the 26th skill
# left plugin.json on 25, and this script still printed "All counts match —
# commit is clean". A consistency gate with a silent hole is worse than no gate,
# because the green line gets read as proof.
#
# Counts are read with a tolerant grep rather than jq, for the same reason every
# check above uses grep: this script must keep working on a machine without jq.
# A missing key is SKIPPED, not failed — the job here is catching DRIFT between
# two numbers that both exist, not policing plugin.json's schema.
# ---------------------------------------------------------------------------
PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"
if [ -f "$PLUGIN_JSON" ]; then
  PLUGIN_SKILLS=$(grep -o '"skills"[[:space:]]*:[[:space:]]*[0-9][0-9]*' "$PLUGIN_JSON" | grep -o '[0-9][0-9]*')
  if [ -n "$PLUGIN_SKILLS" ] && [ "$PLUGIN_SKILLS" != "$ACTUAL_SKILLS" ]; then
    fail "plugin.json: says $PLUGIN_SKILLS skills, repo has $ACTUAL_SKILLS"
  fi

  PLUGIN_AGENTS=$(grep -o '"agents"[[:space:]]*:[[:space:]]*[0-9][0-9]*' "$PLUGIN_JSON" | grep -o '[0-9][0-9]*')
  if [ -n "$PLUGIN_AGENTS" ] && [ "$PLUGIN_AGENTS" != "$ACTUAL_AGENTS" ]; then
    fail "plugin.json: says $PLUGIN_AGENTS agents, repo has $ACTUAL_AGENTS"
  fi

  PLUGIN_CMDS=$(grep -o '"commands"[[:space:]]*:[[:space:]]*[0-9][0-9]*' "$PLUGIN_JSON" | grep -o '[0-9][0-9]*')
  if [ -n "$PLUGIN_CMDS" ] && [ "$PLUGIN_CMDS" != "$ACTUAL_COMMANDS" ]; then
    fail "plugin.json: says $PLUGIN_CMDS commands, repo has $ACTUAL_COMMANDS"
  fi

  PLUGIN_RULES=$(grep -o '"rules"[[:space:]]*:[[:space:]]*[0-9][0-9]*' "$PLUGIN_JSON" | grep -o '[0-9][0-9]*')
  if [ -n "$PLUGIN_RULES" ] && [ "$PLUGIN_RULES" != "$ACTUAL_RULES" ]; then
    fail "plugin.json: says $PLUGIN_RULES rules, repo has $ACTUAL_RULES"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [ $ERRORS -eq 0 ]; then
  ok "All counts match — commit is clean"
  printf "\n"
  exit 0
else
  printf "\n${RED}  Commit blocked: $ERRORS count mismatch(es) found.${NC}\n"
  printf "  Update the documentation to match actual file counts before committing.\n\n"
  exit 1
fi
