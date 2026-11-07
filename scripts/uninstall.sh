#!/usr/bin/env bash
# Strict mode
set -euo pipefail

# =============================================================================
# AI Engineering — Uninstaller
#
# Removes everything that install.sh placed into ~/.claude/ and ~/.claude.json.
# Safe to run before installing ECC or any other toolbox — leaves no hooks,
# agents, skills, commands, or rules behind.
#
# What this removes:
#   - ~/.claude/agents/        (all toolbox agent files)
#   - ~/.claude/skills/        (all toolbox skill directories)
#   - ~/.claude/commands/      (all toolbox command files)
#   - ~/.claude/rules/         (all toolbox rule files)
#   - ~/.claude/hooks/         (all toolbox hook scripts)
#   - ~/.claude/scripts/       (toolbox utility scripts)
#   - ~/.claude/settings.json  (hooks section only — preserves other settings)
#   - ~/.claude.json           (managed MCPs only — preserves user-added MCPs)
#   - Claude Code plugins      (everything-claude-code, beads)
#   - ~/.claude/.managed-*.json (tracking files)
#
# What this does NOT remove:
#   - ~/.claude/memory.md      (your personal preferences — optional, prompted)
#   - Claude Code itself       (the app/CLI)
#   - acli, gh, Beads CLI      (system tools, not toolbox-exclusive)
#   - Any other Claude Code data (conversations, project configs)
# =============================================================================

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ok()   { printf "${GREEN}✅ %s${NC}\n" "$1"; }
warn() { printf "${YELLOW}⚠️  %s${NC}\n" "$1"; }
fail() { printf "${RED}❌ %s${NC}\n" "$1"; }
info() { printf "${BLUE}ℹ️  %s${NC}\n" "$1"; }
step() { printf "\n${BLUE}──── Step %s — %s${NC}\n" "$1" "$2"; }

# ---------------------------------------------------------------------------
# Locate repo root (same as install.sh)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Confirm before doing anything destructive
# ---------------------------------------------------------------------------
printf "\n"
printf "${RED}════════════════════════════════════════════════════════${NC}\n"
printf "${RED}  AI Engineering — Uninstaller                    ${NC}\n"
printf "${RED}════════════════════════════════════════════════════════${NC}\n"
printf "\n"
printf "This will remove all toolbox toolbox files from your machine:\n"
printf "  - All agents, skills, commands, and rules from ~/.claude/\n"
printf "  - All hooks from ~/.claude/hooks/ and ~/.claude/settings.json\n"
printf "  - Managed MCP servers from ~/.claude.json\n"
printf "  - Claude Code plugins: everything-claude-code, beads\n"
printf "\n"
printf "It will NOT remove:\n"
printf "  - Claude Code itself\n"
printf "  - acli, gh, or Beads CLI tools\n"
printf "  - Your conversation history\n"
printf "  - memory.md (you will be asked separately)\n"
printf "\n"
printf "After this, you can install ECC or any other toolbox cleanly.\n"
printf "\n"

read -r -p "Are you sure you want to uninstall? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  info "Uninstall cancelled."
  exit 0
fi

# ---------------------------------------------------------------------------
# Detect OS and set CLAUDE_HOME (mirrors install.sh Step 5)
# ---------------------------------------------------------------------------
case "$(uname -s)" in
  Darwin*|Linux*)
    CLAUDE_HOME="$HOME/.claude"
    ;;
  CYGWIN*|MINGW*|MSYS*)
    CLAUDE_HOME="${APPDATA:-$HOME/.claude}/Claude"
    ;;
  *)
    CLAUDE_HOME="$HOME/.claude"
    ;;
esac

CLAUDE_JSON="$HOME/.claude.json"

# Whether to skip ~/.claude/ directory steps (Steps 1-6).
# MCP config (~/.claude.json) and plugin uninstall can exist independently
# of the ~/.claude/ directory, so those steps (7-8) always run regardless.
if [ ! -d "$CLAUDE_HOME" ]; then
  warn "~/.claude/ not found — skipping directory cleanup (will still clean MCPs and plugins)."
  SKIP_CLAUDE_DIR=true
else
  SKIP_CLAUDE_DIR=false
  info "Uninstalling from: $CLAUDE_HOME"
fi

# Steps 1–6 operate inside ~/.claude/ — skip them when the directory is absent.
if [ "$SKIP_CLAUDE_DIR" = "false" ]; then

# ---------------------------------------------------------------------------
# Step 1 — Remove agents
# ---------------------------------------------------------------------------
step "1" "Remove agents"

# The specific agent files installed by install.sh Steps 6-7
# (ECC plugin agents + repo agents)
AGENT_FILES=(
  # Repo agents (from agents/ directory)
  observer.md
  jira-workflow-steward.md
  accessibility-auditor.md
  performance-benchmarker.md
  docs-lookup.md
  security-engineer.md
  evidence-collector.md
  reality-checker.md
  incident-response-commander.md
  project-manager-senior.md
  api-tester.md
  devops-automator.md
  build-error-resolver.md
  chief-of-staff.md
  code-reviewer.md
  database-reviewer.md
  e2e-runner.md
  refactor-cleaner.md
  security-reviewer.md
  tdd-guide.md
)

REMOVED_AGENTS=0
for agent in "${AGENT_FILES[@]}"; do
  if [ -f "$CLAUDE_HOME/agents/$agent" ]; then
    rm -f "$CLAUDE_HOME/agents/$agent"
    REMOVED_AGENTS=$((REMOVED_AGENTS + 1))
  fi
done

# Also remove any remaining agents if the directory only has toolbox files
# (safe because ECC plugin manages its own agents separately)
if [ -d "$CLAUDE_HOME/agents" ]; then
  REMAINING=$(ls "$CLAUDE_HOME/agents/" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$REMAINING" -eq 0 ]; then
    rmdir "$CLAUDE_HOME/agents" 2>/dev/null || true
    ok "Removed agents directory ($REMOVED_AGENTS files)"
  else
    ok "Removed $REMOVED_AGENTS agent files (${REMAINING} files remaining from other sources)"
  fi
else
  ok "No agents directory found — already clean"
fi

# ---------------------------------------------------------------------------
# Step 2 — Remove skills
# ---------------------------------------------------------------------------
step "2" "Remove skills"

# The specific skill directories installed by install.sh Step 8
SKILL_DIRS=(
  finishing-a-development-branch
  respond-to-pr-reviews
  brainstorming
  systematic-debugging
  code-review-orchestration
  blazor-radzen
  microservice-patterns
  using-git-worktrees
  event-driven-messaging
  work-breakdown
  monolith-decomposition
  test-driven-development
  verification-before-completion
  ef-migration-management
  receiving-code-review
  discovery
  loop-design
  advisory-discovery
  agent-orchestration
  codex-review
  cross-tool-sync
  edge-cases
  observed-work
  flow-reference
  handover-protocol
  mutation-testing
  presentation-master
  pr-automation
  subagent-liveness
  workflow-discipline
)

REMOVED_SKILLS=0
for skill in "${SKILL_DIRS[@]}"; do
  if [ -d "$CLAUDE_HOME/skills/$skill" ]; then
    rm -rf "$CLAUDE_HOME/skills/$skill"
    REMOVED_SKILLS=$((REMOVED_SKILLS + 1))
  fi
done

if [ -d "$CLAUDE_HOME/skills" ]; then
  REMAINING=$(ls "$CLAUDE_HOME/skills/" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$REMAINING" -eq 0 ]; then
    rmdir "$CLAUDE_HOME/skills" 2>/dev/null || true
    ok "Removed skills directory ($REMOVED_SKILLS skill directories)"
  else
    ok "Removed $REMOVED_SKILLS skill directories (${REMAINING} remaining from other sources)"
  fi
else
  ok "No skills directory found — already clean"
fi

# ---------------------------------------------------------------------------
# Step 3 — Remove commands
# ---------------------------------------------------------------------------
step "3" "Remove commands"

# The specific command files installed by install.sh Step 9
COMMAND_FILES=(
  flow.md
  review-pr.md
  init.md
  start.md
  perf.md
  bug.md
  security.md
  hotfix.md
  status.md
  refactor.md
  commands.md
  build.md
  incident.md
  feedback.md
  continue.md
  ask.md
  review.md
  goal.md
  merge-pr.md
  presentation.md
)

REMOVED_COMMANDS=0
for cmd in "${COMMAND_FILES[@]}"; do
  if [ -f "$CLAUDE_HOME/commands/$cmd" ]; then
    rm -f "$CLAUDE_HOME/commands/$cmd"
    REMOVED_COMMANDS=$((REMOVED_COMMANDS + 1))
  fi
done

if [ -d "$CLAUDE_HOME/commands" ]; then
  REMAINING=$(ls "$CLAUDE_HOME/commands/" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$REMAINING" -eq 0 ]; then
    rmdir "$CLAUDE_HOME/commands" 2>/dev/null || true
    ok "Removed commands directory ($REMOVED_COMMANDS command files)"
  else
    ok "Removed $REMOVED_COMMANDS command files (${REMAINING} remaining from other sources)"
  fi
else
  ok "No commands directory found — already clean"
fi

# ---------------------------------------------------------------------------
# Step 4 — Remove rules
# ---------------------------------------------------------------------------
step "4" "Remove rules"

# The specific rule files installed by install.sh Step 10
RULE_FILES=(
  agents.md
  git-workflow.md
  edge-cases.md
  handover.md
  cross-tool-sync.md
  development-workflow.md
  feedback-detection.md
  docs-before-commit.md
  performance.md
  testing.md
  security.md
  coding-style.md
)

REMOVED_RULES=0
for rule in "${RULE_FILES[@]}"; do
  if [ -f "$CLAUDE_HOME/rules/$rule" ]; then
    rm -f "$CLAUDE_HOME/rules/$rule"
    REMOVED_RULES=$((REMOVED_RULES + 1))
  fi
done

if [ -d "$CLAUDE_HOME/rules" ]; then
  REMAINING=$(ls "$CLAUDE_HOME/rules/" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$REMAINING" -eq 0 ]; then
    rmdir "$CLAUDE_HOME/rules" 2>/dev/null || true
    ok "Removed rules directory ($REMOVED_RULES rule files)"
  else
    ok "Removed $REMOVED_RULES rule files (${REMAINING} remaining from other sources)"
  fi
else
  ok "No rules directory found — already clean"
fi

# ---------------------------------------------------------------------------
# Step 5 — Remove hook scripts
# ---------------------------------------------------------------------------
step "5" "Remove hook scripts"

# The specific hook scripts installed by install.sh Step 10.6
HOOK_SCRIPTS=(
  enforce-chief-of-staff.sh
  compliance-auditor.sh
  push-safety.sh
  pr-action-safety.sh
  enforce-skill-delegation.sh
  enforce-transition-script.sh
  enforce-pr-skill.sh
  workflow-auto-approve.sh
  enforce-jira-delegation.sh
  enforce-compliance-audit.sh
  enforce-codex-review.sh
  enforce-fable-review.sh
  auto-poll-after-pr.sh
  consume-pr-markers.sh
  enforce-workflow-start.sh
  audit-model-usage.sh
  enforce-auto-poll.sh
  enforce-loop-bounds.sh
  enforce-ask-budget.sh
  enforce-standing-auth.sh
)

REMOVED_HOOKS=0
for hook in "${HOOK_SCRIPTS[@]}"; do
  if [ -f "$CLAUDE_HOME/hooks/$hook" ]; then
    rm -f "$CLAUDE_HOME/hooks/$hook"
    REMOVED_HOOKS=$((REMOVED_HOOKS + 1))
  fi
done
# Also clean up any renamed stale hook from previous installs
rm -f "$CLAUDE_HOME/hooks/handover-auto-approve.sh" 2>/dev/null || true
# Remove project hooks template (generated by install.sh for per-project config)
rm -f "$CLAUDE_HOME/hooks/project-hooks-template.json" 2>/dev/null || true

if [ -d "$CLAUDE_HOME/hooks" ]; then
  REMAINING=$(ls "$CLAUDE_HOME/hooks/" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$REMAINING" -eq 0 ]; then
    rmdir "$CLAUDE_HOME/hooks" 2>/dev/null || true
    ok "Removed hooks directory ($REMOVED_HOOKS hook scripts)"
  else
    ok "Removed $REMOVED_HOOKS hook scripts (${REMAINING} remaining from other sources)"
  fi
else
  ok "No hooks directory found — already clean"
fi

# ---------------------------------------------------------------------------
# Step 6 — Remove hooks from settings.json
# ---------------------------------------------------------------------------
step "6" "Remove hooks from settings.json"

SETTINGS_FILE="$CLAUDE_HOME/settings.json"
MANAGED_HOOKS_FILE="$CLAUDE_HOME/.managed-hooks.json"

if [ -f "$SETTINGS_FILE" ] && command -v node &>/dev/null; then
  # Read the managed hook event keys saved by install.sh
  # If the tracking file is missing, use the known hook events from hooks-config.json
  if [ -f "$MANAGED_HOOKS_FILE" ]; then
    MANAGED_KEYS_SOURCE="$MANAGED_HOOKS_FILE"
  elif [ -f "$REPO_ROOT/hooks/hooks-config.json" ]; then
    MANAGED_KEYS_SOURCE="$REPO_ROOT/hooks/hooks-config.json"
  else
    MANAGED_KEYS_SOURCE=""
  fi

  if [ -n "$MANAGED_KEYS_SOURCE" ]; then
    node -e "
      const fs = require('fs');
      const settings = JSON.parse(fs.readFileSync('$SETTINGS_FILE', 'utf8'));

      // Determine which hook event keys to remove
      let keysToRemove = [];
      try {
        const src = JSON.parse(fs.readFileSync('$MANAGED_KEYS_SOURCE', 'utf8'));
        // .managed-hooks.json is an array of key strings
        // hooks-config.json is an object with a 'hooks' property
        if (Array.isArray(src)) {
          keysToRemove = src;
        } else if (src.hooks) {
          keysToRemove = Object.keys(src.hooks);
        }
      } catch (e) {
        console.error('Could not read managed hook keys:', e.message);
      }

      if (settings.hooks) {
        for (const key of keysToRemove) {
          delete settings.hooks[key];
        }
        // Remove empty hooks object
        if (Object.keys(settings.hooks).length === 0) {
          delete settings.hooks;
        }
      }

      // Remove permissions added by toolbox — only the specific hook scripts
      // managed by this toolbox. Using '/.claude/hooks/' as a substring would
      // also strip allow-rules for other toolboxes sharing the same hooks dir.
      const TOOLBOX_HOOKS = [
        'enforce-chief-of-staff.sh',
        'compliance-auditor.sh',
        'push-safety.sh',
        'pr-action-safety.sh',
        'enforce-skill-delegation.sh',
        'enforce-transition-script.sh',
        'enforce-pr-skill.sh',
        'workflow-auto-approve.sh',
        'enforce-jira-delegation.sh',
        'enforce-compliance-audit.sh',
        'enforce-codex-review.sh',
        'enforce-fable-review.sh',
        'auto-poll-after-pr.sh',
        'consume-pr-markers.sh',
        'enforce-workflow-start.sh',
        'audit-model-usage.sh',
        'enforce-auto-poll.sh',
        'enforce-loop-bounds.sh',
        'enforce-ask-budget.sh',
        'enforce-standing-auth.sh',
        'handover-auto-approve.sh',  // legacy name, removed by Step 5
      ];
      // Build all path forms so rules stored with any common representation
      // (expanded home, tilde, or $HOME variable) are all caught.
      // Using basename-only matching (previous approach) would also remove
      // unrelated rules from other toolboxes that share the same filename.
      const home = process.env.HOME || '';
      const toolboxHookPaths = TOOLBOX_HOOKS.flatMap(hook => [
        \`\${home}/.claude/hooks/\${hook}\`,   // canonical expanded form
        \`~/.claude/hooks/\${hook}\`,           // tilde literal (not shell-expanded)
        \`$HOME/.claude/hooks/\${hook}\`,       // variable literal (not shell-expanded)
      ]);
      if (settings.permissions && settings.permissions.allow) {
        settings.permissions.allow = settings.permissions.allow.filter(rule => {
          // Remove rules that reference a known toolbox hook in any of the above forms
          return !toolboxHookPaths.some(hookPath => rule.includes(hookPath));
        });
        if (settings.permissions.allow.length === 0) {
          delete settings.permissions.allow;
        }
        if (Object.keys(settings.permissions).length === 0) {
          delete settings.permissions;
        }
      }

      fs.writeFileSync('$SETTINGS_FILE', JSON.stringify(settings, null, 2));
      console.log('Hooks removed from settings.json');
    "
    ok "Removed toolbox hooks from settings.json (other settings preserved)"
  else
    warn "Could not find hook key list — manually check $SETTINGS_FILE and remove the 'hooks' section if needed"
  fi
elif [ ! -f "$SETTINGS_FILE" ]; then
  ok "No settings.json found — nothing to clean"
else
  warn "Node.js not available — manually remove the 'hooks' section from $SETTINGS_FILE"
fi

# End of ~/.claude/ directory steps (Steps 1–6)
fi  # SKIP_CLAUDE_DIR

# ---------------------------------------------------------------------------
# Step 7 — Remove managed MCPs from ~/.claude.json
# ---------------------------------------------------------------------------
step "7" "Remove managed MCP servers from ~/.claude.json"

MANAGED_MCPS_FILE="$CLAUDE_HOME/.managed-mcps.json"

if [ -f "$CLAUDE_JSON" ] && command -v node &>/dev/null; then
  if [ -f "$MANAGED_MCPS_FILE" ]; then
    MCP_KEYS_SOURCE="$MANAGED_MCPS_FILE"
  elif [ -f "$REPO_ROOT/mcp-configs/mcp-servers.json" ]; then
    MCP_KEYS_SOURCE="$REPO_ROOT/mcp-configs/mcp-servers.json"
  else
    MCP_KEYS_SOURCE=""
  fi

  if [ -n "$MCP_KEYS_SOURCE" ]; then
    node -e "
      const fs = require('fs');
      const config = JSON.parse(fs.readFileSync('$CLAUDE_JSON', 'utf8'));

      let keysToRemove = [];
      try {
        const src = JSON.parse(fs.readFileSync('$MCP_KEYS_SOURCE', 'utf8'));
        // .managed-mcps.json is an array of key strings
        // mcp-servers.json has a 'mcpServers' object
        if (Array.isArray(src)) {
          keysToRemove = src;
        } else if (src.mcpServers) {
          keysToRemove = Object.keys(src.mcpServers);
        }
      } catch (e) {
        console.error('Could not read managed MCP keys:', e.message);
      }

      if (config.mcpServers) {
        for (const key of keysToRemove) {
          delete config.mcpServers[key];
          console.log('Removed MCP:', key);
        }
        if (Object.keys(config.mcpServers).length === 0) {
          delete config.mcpServers;
        }
      }

      fs.writeFileSync('$CLAUDE_JSON', JSON.stringify(config, null, 2));
    "
    ok "Removed toolbox MCP servers from ~/.claude.json (user-added MCPs preserved)"
  else
    warn "Could not find MCP key list — manually remove toolbox MCPs from $CLAUDE_JSON if needed"
  fi
elif [ ! -f "$CLAUDE_JSON" ]; then
  ok "No ~/.claude.json found — nothing to clean"
else
  warn "Node.js not available — manually remove toolbox MCP servers from $CLAUDE_JSON"
fi

# ---------------------------------------------------------------------------
# Step 8 — Uninstall Claude Code plugins (ECC and Beads)
# ---------------------------------------------------------------------------
step "8" "Uninstall Claude Code plugins"

CLAUDE_BIN=""
if command -v claude &>/dev/null; then
  CLAUDE_BIN="claude"
else
  for claude_path in \
    "$HOME/Library/Application Support/Claude/claude-code"/*/claude.app/Contents/MacOS/claude \
    "$HOME/.local/share/claude"*/claude; do
    if [ -x "$claude_path" ] 2>/dev/null; then
      CLAUDE_BIN="$claude_path"
      break
    fi
  done
fi

if [ -n "$CLAUDE_BIN" ]; then
  for plugin in everything-claude-code beads; do
    if "$CLAUDE_BIN" plugin list 2>/dev/null | grep -q "$plugin"; then
      info "Uninstalling plugin: $plugin"
      "$CLAUDE_BIN" plugin uninstall "$plugin" 2>/dev/null && ok "Uninstalled $plugin" || warn "Could not uninstall $plugin — remove manually: claude plugin uninstall $plugin"
    else
      info "Plugin not installed: $plugin — skipping"
    fi
  done
else
  warn "Claude Code CLI not found — manually uninstall plugins: claude plugin uninstall everything-claude-code && claude plugin uninstall beads"
fi

# ---------------------------------------------------------------------------
# Step 9 — Remove utility scripts
# ---------------------------------------------------------------------------
step "9" "Remove utility scripts"

if [ -f "$CLAUDE_HOME/scripts/jira-board-columns.sh" ]; then
  rm -f "$CLAUDE_HOME/scripts/jira-board-columns.sh"
  ok "Removed jira-board-columns.sh"
fi

if [ -f "$CLAUDE_HOME/scripts/loop-progress-signature.sh" ]; then
  rm -f "$CLAUDE_HOME/scripts/loop-progress-signature.sh"
  ok "Removed loop-progress-signature.sh"
fi

if [ -f "$CLAUDE_HOME/scripts/consume-deviations.sh" ]; then
  rm -f "$CLAUDE_HOME/scripts/consume-deviations.sh"
  ok "Removed consume-deviations.sh"
fi

for goal_file in goal-loop goal_loop_runtime.py loop-progress-signature.sh loop-config.sh loop-launch.sh observe.sh claude-bin; do
  if [ -f "$CLAUDE_HOME/scripts/$goal_file" ]; then
    rm -f "$CLAUDE_HOME/scripts/$goal_file"
    ok "Removed $goal_file"
  fi
done

# Codex receives the shared skills and the same durable CLI under ~/.codex/bin.
# Remove only toolbox-owned names, preserving unrelated Codex tools.
CODEX_HOME_PATH="${CODEX_HOME:-$HOME/.codex}"
CODEX_SKILLS_HOME="$CODEX_HOME_PATH/skills"
CODEX_BIN_HOME="$CODEX_HOME_PATH/bin"
CODEX_SKILL_MANIFEST="$CODEX_HOME_PATH/.toolbox-skill-manifest"
if [ -f "$CODEX_SKILL_MANIFEST" ]; then
  while IFS= read -r skill; do
    [[ "$skill" == \#* || -z "$skill" ]] && continue
    [[ "$skill" =~ ^[a-z0-9-]+$ ]] || continue
    if [ -d "$CODEX_SKILLS_HOME/$skill" ]; then
      rm -rf "$CODEX_SKILLS_HOME/$skill"
    fi
  done < "$CODEX_SKILL_MANIFEST"
  rm -f "$CODEX_SKILL_MANIFEST"
else
  warn "No Codex ownership manifest found — preserving all existing Codex skills."
fi
for goal_file in goal-loop goal_loop_runtime.py loop-progress-signature.sh loop-config.sh loop-launch.sh observe.sh claude-bin; do
  if [ -f "$CODEX_BIN_HOME/$goal_file" ]; then
    rm -f "$CODEX_BIN_HOME/$goal_file"
  fi
done

# Remove only the managed Codex hook files and their hook registrations. The
# manifest is written by sync-provider-hooks.sh; unrelated Codex hooks and
# settings remain untouched.
CODEX_HOOKS_MANIFEST="$CODEX_HOME_PATH/hooks/.toolbox-hook-manifest"
if [ -f "$CODEX_HOOKS_MANIFEST" ]; then
  while IFS= read -r hook_name; do
    [ -n "$hook_name" ] && rm -f "$CODEX_HOME_PATH/hooks/$hook_name"
  done < "$CODEX_HOOKS_MANIFEST"
  if [ -f "$CODEX_HOME_PATH/hooks.json" ] && command -v node >/dev/null 2>&1; then
    PROVIDER_HOOK_CONFIG="$CODEX_HOME_PATH/hooks.json" \
    PROVIDER_HOOKS_ROOT="$CODEX_HOME_PATH/hooks" \
    PROVIDER_HOOK_MANIFEST="$CODEX_HOOKS_MANIFEST" \
    node "$REPO_ROOT/scripts/remove-provider-hooks.js"
  fi
  rm -f "$CODEX_HOOKS_MANIFEST"
  ok "Removed toolbox-managed Codex hooks and registrations"
else
  # Without the manifest there is no proof that a same-named hook or
  # registration belongs to toolbox. Preserve the host state rather than
  # guessing and deleting user configuration.
  warn "No Codex hook ownership manifest found — preserving existing Codex hooks and registrations."
fi
if [ -d "$CODEX_BIN_HOME" ]; then
  CODEX_BIN_REMAINING=$(ls "$CODEX_BIN_HOME/" 2>/dev/null | wc -l | tr -d ' ')
  [ "$CODEX_BIN_REMAINING" -eq 0 ] && rmdir "$CODEX_BIN_HOME" 2>/dev/null || true
fi

# Remove scripts dir if empty
if [ -d "$CLAUDE_HOME/scripts" ]; then
  REMAINING=$(ls "$CLAUDE_HOME/scripts/" 2>/dev/null | wc -l | tr -d ' ')
  [ "$REMAINING" -eq 0 ] && rmdir "$CLAUDE_HOME/scripts" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Step 10 — Remove tracking files
# ---------------------------------------------------------------------------
step "10" "Remove tracking files"

TRACKING_FILES=(
  .managed-plugins.json
  .managed-hooks.json
  .managed-mcps.json
)

for f in "${TRACKING_FILES[@]}"; do
  [ -f "$CLAUDE_HOME/$f" ] && rm -f "$CLAUDE_HOME/$f" && info "Removed $f"
done
ok "Tracking files removed"

# ---------------------------------------------------------------------------
# Step 11 — Optional: remove memory.md
# ---------------------------------------------------------------------------
step "11" "memory.md (optional)"

if [ -f "$CLAUDE_HOME/memory.md" ]; then
  printf "\n"
  printf "memory.md contains your personal preferences (tool choice, methodology,\n"
  printf "Jira URL, team size, etc.) saved by /init. You may want to keep it\n"
  printf "if you plan to reinstall toolbox later — /init reads it to skip questions.\n"
  printf "\n"
  read -r -p "Remove memory.md? (yes/no): " REMOVE_MEMORY
  if [[ "$REMOVE_MEMORY" == "yes" ]]; then
    rm -f "$CLAUDE_HOME/memory.md"
    ok "Removed memory.md"
  else
    info "Kept memory.md — will be ignored by ECC (ECC doesn't read it)"
  fi
else
  ok "No memory.md found — nothing to do"
fi

# ---------------------------------------------------------------------------
# Verification — confirm nothing toolbox left behind
# ---------------------------------------------------------------------------
printf "\n"
info "Verifying clean state..."

LEFTOVERS=0

# Check for toolbox-managed files specifically, using the same lists that the
# removal steps used. If any survive their respective step, they count as
# genuine toolbox leftovers — even when the containing directory also has files
# from other toolboxes that are correctly left in place.

# Agents (mirrors Step 1 AGENT_FILES list)
for agent in "${AGENT_FILES[@]}"; do
  if [ -f "$CLAUDE_HOME/agents/$agent" ]; then
    warn "toolbox agent still present after uninstall: $CLAUDE_HOME/agents/$agent"
    LEFTOVERS=$((LEFTOVERS + 1))
  fi
done

# Skills (mirrors Step 2 SKILL_DIRS list)
for skill in "${SKILL_DIRS[@]}"; do
  if [ -d "$CLAUDE_HOME/skills/$skill" ]; then
    warn "toolbox skill still present after uninstall: $CLAUDE_HOME/skills/$skill"
    LEFTOVERS=$((LEFTOVERS + 1))
  fi
done

# Commands (mirrors Step 3 COMMAND_FILES list)
for cmd in "${COMMAND_FILES[@]}"; do
  if [ -f "$CLAUDE_HOME/commands/$cmd" ]; then
    warn "toolbox command still present after uninstall: $CLAUDE_HOME/commands/$cmd"
    LEFTOVERS=$((LEFTOVERS + 1))
  fi
done

# Rules (mirrors Step 4 RULE_FILES list)
for rule in "${RULE_FILES[@]}"; do
  if [ -f "$CLAUDE_HOME/rules/$rule" ]; then
    warn "toolbox rule still present after uninstall: $CLAUDE_HOME/rules/$rule"
    LEFTOVERS=$((LEFTOVERS + 1))
  fi
done

# Hooks (mirrors Step 5 — includes legacy handover-auto-approve.sh)
TOOLBOX_HOOK_FILES=(
  "enforce-chief-of-staff.sh"
  "compliance-auditor.sh"
  "push-safety.sh"
  "pr-action-safety.sh"
  "enforce-skill-delegation.sh"
  "enforce-transition-script.sh"
  "enforce-pr-skill.sh"
  "workflow-auto-approve.sh"
  "enforce-jira-delegation.sh"
  "enforce-compliance-audit.sh"
  "enforce-codex-review.sh"
  "enforce-fable-review.sh"
  "auto-poll-after-pr.sh"
  "consume-pr-markers.sh"
  "enforce-workflow-start.sh"
  "audit-model-usage.sh"
  "enforce-auto-poll.sh"
  "enforce-loop-bounds.sh"
  "enforce-ask-budget.sh"
  "enforce-standing-auth.sh"
  "handover-auto-approve.sh"  # legacy name still removed by Step 5
)
for hook in "${TOOLBOX_HOOK_FILES[@]}"; do
  if [ -f "$CLAUDE_HOME/hooks/$hook" ]; then
    warn "toolbox hook still present after uninstall: $CLAUDE_HOME/hooks/$hook"
    LEFTOVERS=$((LEFTOVERS + 1))
  fi
done

# Inform about any remaining files in shared directories (NOT counted as
# LEFTOVERS — they are likely from other toolboxes, and the targeted checks
# above already catch any genuine toolbox residue by filename).
for dir in agents skills commands rules hooks; do
  if [ -d "$CLAUDE_HOME/$dir" ]; then
    COUNT=$(ls "$CLAUDE_HOME/$dir/" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$COUNT" -gt 0 ]; then
      warn "$CLAUDE_HOME/$dir/ still has $COUNT file(s) — may be from other toolboxes"
    fi
  fi
done

# Check settings.json for remaining hooks
if [ -f "$SETTINGS_FILE" ] && command -v node &>/dev/null; then
  HAS_HOOKS=$(node -e "
    const s = JSON.parse(require('fs').readFileSync('$SETTINGS_FILE', 'utf8'));
    console.log(s.hooks ? 'yes' : 'no');
  " 2>/dev/null || echo "unknown")
  if [ "$HAS_HOOKS" = "yes" ]; then
    warn "settings.json still has a 'hooks' section — may be from other toolboxes or user-added"
    LEFTOVERS=$((LEFTOVERS + 1))
  fi
fi

if [ "$LEFTOVERS" -eq 0 ]; then
  ok "Clean — no toolbox files detected in ~/.claude/"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
printf "\n"
printf "${GREEN}════════════════════════════════════════════════════════${NC}\n"
printf "${GREEN}  ✅ Uninstall complete                                  ${NC}\n"
printf "${GREEN}════════════════════════════════════════════════════════${NC}\n"
printf "\n"
printf "All toolbox toolbox files have been removed.\n"
printf "No hooks, agents, skills, commands, or rules remain.\n"
printf "\n"
printf "${BLUE}You can now install ECC cleanly:${NC}\n"
printf "  Follow the ECC install instructions at:\n"
printf "  https://github.com/affaan-m/everything-claude-code\n"
printf "\n"
printf "${BLUE}To reinstall toolbox later:${NC}\n"
printf "  cd %s && ./scripts/install.sh\n" "$REPO_ROOT"
printf "\n"
