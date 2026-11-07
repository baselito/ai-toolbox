#!/usr/bin/env bash
# Strict mode:
#   -e      exit on any command failure
#   -u      treat unset variables as errors (prevents $HOME= / $PWD= footguns)
#   -o pipefail  fail the whole pipeline if any command in it fails
set -euo pipefail

# =============================================================================
# AI Engineering — Full Installer
# Run once per machine. Sets up agents, skills, commands, rules, MCPs, and Beads.
# =============================================================================

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No colour

ok()   { printf "${GREEN}✅ %s${NC}\n" "$1"; }
warn() { printf "${YELLOW}⚠️  %s${NC}\n" "$1"; }
fail() { printf "${RED}❌ %s${NC}\n" "$1"; }
info() { printf "${BLUE}ℹ️  %s${NC}\n" "$1"; }
step() { printf "\n${BLUE}──── Step %s — %s${NC}\n" "$1" "$2"; }

usage() {
  cat <<'EOF'
Usage: bash scripts/install.sh [--help|-h]

Install the AI Engineering toolbox for Claude Code.

Options:
  -h, --help       Show this help and exit without changing the system.

Environment:
  INSTALL_CODEX=1  Also install the shared toolbox skills for Codex.
EOF
}

if [[ "$#" -eq 1 && ( "${1:-}" == "--help" || "${1:-}" == "-h" ) ]]; then
  usage
  exit 0
elif [[ "$#" -ne 0 ]]; then
  usage >&2
  exit 2
fi

INSTALL_REQUIRED_ERRORS=0

# Resolve the selected CLI before trusting its location. This prevents a
# project-controlled symlink or PATH shim from becoming the loop executable.
canonicalize_path() {
  local candidate="$1" parent leaf target readlink_bin readlink_candidate i
  readlink_bin=""
  for readlink_candidate in /usr/bin/readlink /bin/readlink; do
    if [[ -x "$readlink_candidate" && ! -d "$readlink_candidate" ]]; then
      readlink_bin="$readlink_candidate"
      break
    fi
  done
  [[ -n "$readlink_bin" && "$candidate" == /* ]] || return 1
  for ((i = 1; i <= 40; i++)); do
    parent="$(cd -P "$(dirname "$candidate")" 2>/dev/null && pwd -P)" || return 1
    leaf="$(basename "$candidate")"
    candidate="$parent/$leaf"
    if [[ ! -L "$candidate" ]]; then
      [[ -e "$candidate" ]] || return 1
      printf '%s\n' "$candidate"
      return 0
    fi
    target="$("$readlink_bin" "$candidate" 2>/dev/null)" || return 1
    [[ "$target" == /* ]] && candidate="$target" || candidate="$parent/$target"
  done
  return 1
}

is_trusted_claude_path() {
  local candidate="$1" resolved home_root appdata_root
  resolved="$(canonicalize_path "$candidate" 2>/dev/null || true)"
  [[ -n "$resolved" ]] || return 1
  home_root="$(canonicalize_path "$HOME" 2>/dev/null || true)"
  appdata_root="$(canonicalize_path "${LOCALAPPDATA:-/nonexistent}" 2>/dev/null || true)"
  if [[ -n "$appdata_root" && "$resolved" == "$appdata_root"/* ]]; then
    return 0
  fi
  case "$resolved" in
    "$home_root"/.local/*|"$home_root"/.npm-global/*|"$home_root"/.nvm/*|"$home_root"/Library/Application\ Support/Claude/*|"$home_root"/AppData/Local/*|/opt/homebrew/*|/usr/local/*|/usr/bin/*|/bin/*)
      return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Step 0 — Locate repo root
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ ! -f "$REPO_ROOT/README.md" ]; then
  fail "Cannot find repo root. Run this script from inside the ai-engineering repo."
  exit 1
fi

info "Repo root: $REPO_ROOT"

# ---------------------------------------------------------------------------
# Step 0.5 — Auto-pull latest changes (if inside a git repo with a remote)
# ---------------------------------------------------------------------------
if [ -d "$REPO_ROOT/.git" ]; then
  # Check if we have a remote and are on main
  CURRENT_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  HAS_REMOTE="$(git -C "$REPO_ROOT" remote 2>/dev/null | head -1)"

  if [ -n "$HAS_REMOTE" ] && [ "$CURRENT_BRANCH" = "main" ]; then
    info "Checking for latest changes on main..."
    git -C "$REPO_ROOT" fetch origin --quiet 2>/dev/null || true

    LOCAL_HEAD="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)"
    REMOTE_HEAD="$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null || echo "")"

    if [ -n "$REMOTE_HEAD" ] && [ "$LOCAL_HEAD" != "$REMOTE_HEAD" ]; then
      info "Updates found on remote. Pulling latest..."
      git -C "$REPO_ROOT" pull --ff-only origin main 2>/dev/null && {
        ok "Pulled latest changes from origin/main"
      } || {
        warn "Could not auto-pull (merge conflict or diverged). Run 'git pull' manually."
        warn "Continuing with current local files."
      }
    else
      ok "Already up to date with origin/main"
    fi
  elif [ -n "$CURRENT_BRANCH" ] && [ "$CURRENT_BRANCH" != "main" ]; then
    info "On branch $CURRENT_BRANCH (not main) — skipping auto-pull. Installing from current branch."
  fi
fi

# ---------------------------------------------------------------------------
# Step 1 — Detect OS
# ---------------------------------------------------------------------------
step "1" "Detect operating system"

OS="unknown"
PACKAGE_MANAGER="unknown"

case "$(uname -s)" in
  Darwin*)
    OS="mac"
    info "Detected: macOS"
    ;;
  Linux*)
    OS="linux"
    info "Detected: Linux"
    ;;
  CYGWIN*|MINGW*|MSYS*)
    OS="windows"
    info "Detected: Windows (Git Bash / MSYS)"
    ;;
  *)
    fail "Unsupported OS: $(uname -s)"
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Step 2 — Ensure package manager
# ---------------------------------------------------------------------------
step "2" "Ensure package manager"

case "$OS" in
  mac)
    if command -v brew &>/dev/null; then
      ok "Homebrew already installed"
    else
      info "Installing Homebrew..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      ok "Homebrew installed"
    fi
    PACKAGE_MANAGER="brew"
    ;;
  linux)
    if command -v apt &>/dev/null; then
      PACKAGE_MANAGER="apt"
      ok "apt available"
    elif command -v dnf &>/dev/null; then
      PACKAGE_MANAGER="dnf"
      ok "dnf available"
    elif command -v pacman &>/dev/null; then
      PACKAGE_MANAGER="pacman"
      ok "pacman available"
    else
      fail "No supported package manager found (apt, dnf, pacman)."
      exit 1
    fi
    ;;
  windows)
    if command -v winget &>/dev/null; then
      PACKAGE_MANAGER="winget"
      ok "winget available"
    else
      warn "winget not found. Please install packages manually."
      PACKAGE_MANAGER="manual"
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# Step 3 — Ensure Node.js
# ---------------------------------------------------------------------------
step "3" "Ensure Node.js"

if command -v node &>/dev/null; then
  NODE_VERSION="$(node --version)"
  ok "Node.js already installed ($NODE_VERSION)"
else
  info "Installing Node.js..."
  case "$OS" in
    mac)    brew install node ;;
    linux)
      case "$PACKAGE_MANAGER" in
        apt)    sudo apt update && sudo apt install -y nodejs npm ;;
        dnf)    sudo dnf install -y nodejs npm ;;
        pacman) sudo pacman -S --noconfirm nodejs npm ;;
      esac
      ;;
    windows) winget install OpenJS.NodeJS ;;
  esac
  ok "Node.js installed ($(node --version))"
fi

# ---------------------------------------------------------------------------
# Step 4 — Ensure Claude Code CLI
# ---------------------------------------------------------------------------
step "4" "Ensure Claude Code CLI"

CLAUDE_BIN=""
if command -v claude &>/dev/null; then
  PATH_CLAUDE_BIN="$(type -P claude 2>/dev/null || true)"
  PATH_CLAUDE_BIN_RESOLVED="$(canonicalize_path "$PATH_CLAUDE_BIN" 2>/dev/null || true)"
  if [[ -n "$PATH_CLAUDE_BIN_RESOLVED" ]] && is_trusted_claude_path "$PATH_CLAUDE_BIN_RESOLVED"; then
    CLAUDE_BIN="$PATH_CLAUDE_BIN_RESOLVED"
    ok "Claude Code CLI already installed (trusted path)"
  else
    warn "Claude Code CLI on PATH is outside trusted install locations; ignoring it for loop launches."
  fi
fi

if [ -z "$CLAUDE_BIN" ]; then
  # Check native app install locations even when an untrusted PATH shim exists.
  for claude_path in \
    "$HOME/Library/Application Support/Claude/claude-code"/*/claude.app/Contents/MacOS/claude \
    "$HOME/Library/Application Support/Claude/claude-code-vm"/*/claude \
    "$HOME/.local/share/claude"*/claude \
    "${LOCALAPPDATA:-/nonexistent}/Programs/Claude/claude" \
    "${LOCALAPPDATA:-/nonexistent}/Claude/claude-code"*/claude; do
    if [ -x "$claude_path" ] 2>/dev/null; then
      CLAUDE_BIN="$(canonicalize_path "$claude_path" 2>/dev/null || true)"
      break
    fi
  done
  if [ -n "$CLAUDE_BIN" ]; then
    ok "Claude Code CLI found (native app install)"
  fi
fi

if [ -z "$CLAUDE_BIN" ]; then
  info "Installing Claude Code CLI via npm..."
  npm install -g @anthropic-ai/claude-code 2>/dev/null && {
    CLAUDE_BIN="$(type -P claude 2>/dev/null || true)"
    ok "Claude Code CLI installed"
  } || {
    warn "Claude Code CLI install failed — install via Claude desktop app or: npm install -g @anthropic-ai/claude-code"
  }
fi

# ---------------------------------------------------------------------------
# Step 4.5 — Install target info
# ---------------------------------------------------------------------------
step "4.5" "Install target"

printf "\n"
info "Installing ai-engineering toolbox for Claude Code."
info "Works in any terminal, any IDE's terminal pane (VS Code, Cursor, Zed), or Claude Desktop — same install."
printf "\n"

# ---------------------------------------------------------------------------
# Step 4.6 — Migration cleanup: remove old Antigravity config from prior installs
# ---------------------------------------------------------------------------
# Pre-Antigravity-removal installs created ~/.gemini/GEMINI.md, ~/.claude/antigravity-cache/,
# and synced .agent/ into project repos. These are now dead weight. Clean them up silently
# so re-running install.sh on an existing machine works cleanly.
step "4.6" "Migration cleanup"

# Safety guard: refuse to run cleanup if HOME or PWD look suspicious
# (deliberately prevents rm -rf /.gemini if HOME=/ or is empty)
if [[ -z "${HOME:-}" || "${HOME:-}" == "/" ]] || [[ -z "${PWD:-}" || "${PWD:-}" == "/" ]]; then
  warn "HOME or PWD is suspiciously short ('${HOME:-}' / '${PWD:-}') — skipping migration cleanup for safety"
else
  CLEANUP_ITEMS=()
  [ -d "$HOME/.gemini" ] && CLEANUP_ITEMS+=("$HOME/.gemini")
  # NOTE: CLAUDE_HOME isn't set yet (Step 5 sets it) — use the default for the detection phase
  [ -d "$HOME/.claude/antigravity-cache" ] && CLEANUP_ITEMS+=("$HOME/.claude/antigravity-cache")
  [ -f "$PWD/.claude/antigravity-handover.md" ] && CLEANUP_ITEMS+=("$PWD/.claude/antigravity-handover.md")
  [ -f "$PWD/.claude/backup-handover.md" ] && CLEANUP_ITEMS+=("$PWD/.claude/backup-handover.md")
  # Only delete .agent/ in the current project if:
  #   1. We're NOT in the toolbox repo itself (self-delete guard)
  #   2. The directory has at least ONE of rules/, workflows/, or skills/ as an
  #      Antigravity-specific marker. OR logic catches partial legacy trees (where
  #      a prior manual cleanup left only some subdirs) while still rejecting
  #      unrelated custom tooling that uses .agent/ without any of these subdirs.
  if [ -d "$PWD/.agent" ] && [ "$PWD" != "$REPO_ROOT" ] \
     && { [ -d "$PWD/.agent/rules" ] \
          || [ -d "$PWD/.agent/workflows" ] \
          || [ -d "$PWD/.agent/skills" ]; }; then
    CLEANUP_ITEMS+=("$PWD/.agent")
  fi

  if [ ${#CLEANUP_ITEMS[@]} -gt 0 ]; then
    info "Found old Antigravity config — cleaning up:"
    for item in "${CLEANUP_ITEMS[@]}"; do
      echo "   - $item"
    done
    rm -rf "${CLEANUP_ITEMS[@]}"
    ok "Removed ${#CLEANUP_ITEMS[@]} old Antigravity paths"
  else
    ok "No old Antigravity config found — nothing to clean up"
  fi

  # Remove the exact editor-assistant files created by older toolbox installs.
  # This is deliberately limited to the current project and known toolbox
  # paths; it never scans or deletes arbitrary .github content.
  RETIRED_ASSISTANT_ITEMS=()
  if [ "$PWD" != "$REPO_ROOT" ]; then
    for retired_file in \
      "$PWD/.github/copilot-instructions.md" \
      "$PWD/.github/scripts/sync-ai-instructions.sh" \
      "$PWD/.github/sync-repos.txt" \
      "$PWD/.github/workflows/sync-ai-instructions.yml"; do
      [ -f "$retired_file" ] && RETIRED_ASSISTANT_ITEMS+=("$retired_file")
    done
    RETIRED_ASSISTANT_FILENAMES=(
      advisory-discovery.instructions.md
      agents.instructions.md
      api-review.instructions.md
      architect.instructions.md
      autonomy.instructions.md
      blazor-radzen.instructions.md
      brainstorming.instructions.md
      code-review-orchestration.instructions.md
      code-review.instructions.md
      coding-style.instructions.md
      communication.instructions.md
      cross-tool-sync.instructions.md
      debugging.instructions.md
      development-workflow.instructions.md
      devops.instructions.md
      discovery.instructions.md
      doc-updater.instructions.md
      docs-before-commit.instructions.md
      edge-cases.instructions.md
      ef-migration-management.instructions.md
      event-driven-messaging.instructions.md
      feedback-detection.instructions.md
      git-workflow.instructions.md
      handover.instructions.md
      monolith-decomposition.instructions.md
      performance.instructions.md
      personas.instructions.md
      planner.instructions.md
      receiving-code-review.instructions.md
      respond-to-pr-reviews.instructions.md
      security.instructions.md
      test-driven-development.instructions.md
      testing.instructions.md
      ui-verification.instructions.md
      verification-before-completion.instructions.md
      work-breakdown.instructions.md
      workflow-bug.instructions.md
      workflow-build.instructions.md
      workflow-commands.instructions.md
      workflow-continue.instructions.md
      workflow-discipline.instructions.md
      workflow-feedback.instructions.md
      workflow-flow.instructions.md
      workflow-hotfix.instructions.md
      workflow-incident.instructions.md
      workflow-perf.instructions.md
      workflow-refactor.instructions.md
      workflow-review-pr.instructions.md
      workflow-review.instructions.md
      workflow-security.instructions.md
    )
    for retired_name in "${RETIRED_ASSISTANT_FILENAMES[@]}"; do
      retired_file="$PWD/.github/instructions/ai-engineering/$retired_name"
      [ -f "$retired_file" ] && RETIRED_ASSISTANT_ITEMS+=("$retired_file")
    done
  fi

  if [ ${#RETIRED_ASSISTANT_ITEMS[@]} -gt 0 ]; then
    info "Found retired editor-assistant files — removing:"
    for item in "${RETIRED_ASSISTANT_ITEMS[@]}"; do
      echo "   - $item"
    done
    rm -f "${RETIRED_ASSISTANT_ITEMS[@]}"
    rmdir "$PWD/.github/instructions/ai-engineering" "$PWD/.github/instructions" "$PWD/.github/scripts" 2>/dev/null || true
    ok "Removed ${#RETIRED_ASSISTANT_ITEMS[@]} retired editor-assistant file(s)"
  else
    ok "No retired editor-assistant files found — nothing to clean up"
  fi
fi

# ---------------------------------------------------------------------------
# Step 5 — Set up target directories
# ---------------------------------------------------------------------------
step "5" "Set up target directories"

case "$OS" in
  mac|linux)
    CLAUDE_HOME="$HOME/.claude"
    ;;
  windows)
    CLAUDE_HOME="${APPDATA}/Claude"
    if [ -z "$APPDATA" ]; then
      CLAUDE_HOME="$HOME/.claude"
      warn "APPDATA not set — falling back to $CLAUDE_HOME"
    fi
    ;;
esac

# Clean previous install to remove stale files (renamed/deleted agents, skills, etc.)
# Directories (agents, skills, commands, rules) are wiped and re-created fresh.
# MCPs, hooks, and plugins track what was previously installed — stale ones are removed.
# Preserved: memory.md, settings.json (non-hook keys), .claude.json (non-managed MCPs).
for dir in agents skills commands rules; do
  if [ -d "$CLAUDE_HOME/$dir" ]; then
    rm -rf "$CLAUDE_HOME/$dir"
  fi
done

mkdir -p "$CLAUDE_HOME/agents"
mkdir -p "$CLAUDE_HOME/skills"
mkdir -p "$CLAUDE_HOME/commands"
mkdir -p "$CLAUDE_HOME/rules"
mkdir -p "$CLAUDE_HOME/hooks"

ok "Target directories cleaned and ready: $CLAUDE_HOME"

# ---------------------------------------------------------------------------
# Step 6 — Install ECC plugin
# ---------------------------------------------------------------------------
step "6" "Install ECC plugin (affaan-m/everything-claude-code)"

# Current managed plugins — if a plugin is removed from this list, it gets uninstalled
MANAGED_PLUGINS=("everything-claude-code" "beads")
PREV_MANAGED_PLUGINS_FILE="$CLAUDE_HOME/.managed-plugins.json"

# Remove plugins that were previously managed but are no longer in the list
if [ -f "$PREV_MANAGED_PLUGINS_FILE" ]; then
  while IFS= read -r prev_plugin; do
    prev_plugin=$(echo "$prev_plugin" | tr -d '",' | xargs)
    [ -z "$prev_plugin" ] || [[ "$prev_plugin" == "[" ]] || [[ "$prev_plugin" == "]" ]] && continue
    STILL_MANAGED=false
    for mp in "${MANAGED_PLUGINS[@]}"; do
      if [ "$mp" = "$prev_plugin" ]; then
        STILL_MANAGED=true
        break
      fi
    done
    if [ "$STILL_MANAGED" = false ] && [ -n "$CLAUDE_BIN" ] && "$CLAUDE_BIN" plugin list 2>/dev/null | grep -q "$prev_plugin"; then
      info "Removing stale plugin: $prev_plugin"
      "$CLAUDE_BIN" plugin uninstall "$prev_plugin" 2>/dev/null || warn "Could not uninstall $prev_plugin"
    fi
  done < "$PREV_MANAGED_PLUGINS_FILE"
fi

# Install ECC plugin
if [ -n "$CLAUDE_BIN" ] && "$CLAUDE_BIN" plugin list 2>/dev/null | grep -q "everything-claude-code"; then
  ok "ECC plugin already installed"
else
  info "Adding ECC plugin from marketplace..."
  "$CLAUDE_BIN" plugin marketplace add affaan-m/everything-claude-code 2>/dev/null || true
  if "$CLAUDE_BIN" plugin install everything-claude-code@everything-claude-code 2>/dev/null; then
    ok "ECC plugin installed"
  else
    fail "ECC plugin install failed — run manually: claude plugin marketplace add affaan-m/everything-claude-code && claude plugin install everything-claude-code@everything-claude-code"
  fi
fi

# ---------------------------------------------------------------------------
# Step 6.5 — Optional: Codex plugin + CLI (local pre-PR adversarial reviewer)
# ---------------------------------------------------------------------------
# The local Codex REVIEWER is opt-in because it consumes OpenAI quota. The
# provider-neutral GoalRun runtime and shared skills are a separate parity
# surface and are installed whenever a Codex home already exists below.
step "6.5" "Optional: Codex (local pre-PR reviewer; GoalRun parity is separate)"

MEMORY_FILE="$CLAUDE_HOME/memory.md"

# Decide whether to install: explicit INSTALL_CODEX=1 wins; otherwise prompt only on
# an interactive terminal; non-interactive runs skip (leaving any prior state intact).
WANT_CODEX="skip"
if [ "${INSTALL_CODEX:-}" = "1" ]; then
  WANT_CODEX="yes"
elif [ "${INSTALL_CODEX:-}" = "0" ]; then
  WANT_CODEX="no"
elif [ -t 0 ]; then
  printf "\n  Install Codex for local pre-PR review? Needs an OpenAI/ChatGPT subscription.\n"
  printf "  (Optional — catches issues locally before PRs, reducing reviewer rounds.)\n"
  printf "  Install Codex now? [y/N] "
  read -r CODEX_ANSWER < /dev/tty || CODEX_ANSWER=""
  case "$CODEX_ANSWER" in
    [Yy]*) WANT_CODEX="yes" ;;
    *)     WANT_CODEX="no" ;;
  esac
else
  info "Non-interactive install — skipping Codex (set INSTALL_CODEX=1 to enable, 0 to silence)."
fi

# Helper: record Codex state in memory.md, replacing any prior "- Codex:" line so
# re-runs don't accumulate duplicates. The codex-review skill greps for
# '^- *Codex:.*enabled'.
set_codex_state() {
  local state="$1"  # enabled | disabled
  # Seed the full memory.md template if it does not exist yet. Step 6.5 runs
  # BEFORE the "Create memory.md template" step further down, which skips when
  # the file already exists. Without seeding here, writing the Codex line first
  # would create a memory.md containing ONLY the Codex line, and the later step
  # would then skip the real template — leaving a memory.md with no ## Tool /
  # Jira / CI sections (Codex self-review P1). Seeding from the repo template
  # keeps a single source of truth.
  if [ ! -f "$MEMORY_FILE" ] && [ -f "$REPO_ROOT/memory.md" ]; then
    cp "$REPO_ROOT/memory.md" "$MEMORY_FILE"
  fi
  touch "$MEMORY_FILE"
  # Remove any existing Codex state line, then append the new one.
  grep -ivE '^- *Codex:' "$MEMORY_FILE" > "$MEMORY_FILE.tmp" 2>/dev/null || true
  mv "$MEMORY_FILE.tmp" "$MEMORY_FILE"
  printf -- "- Codex: %s\n" "$state" >> "$MEMORY_FILE"
}

if [ "$WANT_CODEX" = "yes" ]; then
  CODEX_OK=true
  # 1. Plugin (the /codex:* slash commands) — BEST-EFFORT only. The codex-review
  #    skill calls the `codex exec` CLI directly and does NOT need the plugin, so
  #    a plugin install failure must NOT disable Codex. Enablement gates on the
  #    CLI alone (step 2). The plugin is a bonus convenience (Codex self-review P2).
  if [ -n "$CLAUDE_BIN" ]; then
    if "$CLAUDE_BIN" plugin list 2>/dev/null | grep -q "codex"; then
      ok "Codex plugin already installed"
    else
      info "Adding Codex plugin from marketplace (openai/codex-plugin-cc)..."
      "$CLAUDE_BIN" plugin marketplace add openai/codex-plugin-cc 2>/dev/null || true
      if "$CLAUDE_BIN" plugin install codex@openai-codex 2>/dev/null; then
        ok "Codex plugin installed"
      else
        warn "Codex plugin install failed (optional — the /codex:* commands won't be available, but pre-PR review still works via the CLI). Manual: claude plugin marketplace add openai/codex-plugin-cc && claude plugin install codex@openai-codex"
      fi
    fi
  else
    info "Claude CLI not found — skipping the optional Codex plugin (CLI-based review still works)."
  fi

  # 2. Codex CLI (the `codex exec` binary the codex-review skill calls). Always
  #    latest. Install if not already present, then gate enablement on an actual
  #    RUN check below.
  if codex --version >/dev/null 2>&1; then
    ok "Codex CLI already installed ($(codex --version 2>/dev/null | head -1))"
  elif command -v npm >/dev/null 2>&1; then
    info "Installing Codex CLI (npm i -g @openai/codex@latest)..."
    npm install -g @openai/codex@latest >/dev/null 2>&1 || true
  else
    warn "npm not found — cannot install the Codex CLI. Install Node/npm, then: npm i -g @openai/codex@latest"
    CODEX_OK=false
  fi

  # Verify the binary actually RUNS — not merely that it is discoverable on PATH.
  # `command -v` only proves PATH discovery; a broken install / bad shebang /
  # missing runtime could still fail at review time. `codex --version` proves the
  # CLI starts (local + fast, no auth/network), which is the real enablement
  # precondition (automated-review PR #76 findings). stderr is redirected to swallow any
  # startup warnings. If npm's global bin isn't on PATH, this also catches it.
  if [ "$CODEX_OK" = true ] && ! codex --version >/dev/null 2>&1; then
    NPM_BIN_HINT=$(npm prefix -g 2>/dev/null)
    warn "Codex CLI does not run (\`codex --version\` failed) — leaving Codex DISABLED. Check the install / ensure npm's global bin is on PATH (e.g. ${NPM_BIN_HINT:+$NPM_BIN_HINT/bin}), then re-run install.sh."
    CODEX_OK=false
  fi

  if [ "$CODEX_OK" = true ]; then
    set_codex_state "enabled"
    # 3. Seed the local knowledge pack so reviews are reviewer-aligned.
    bash "$REPO_ROOT/scripts/sync-codex-knowledge.sh" --quiet 2>/dev/null \
      && ok "Codex knowledge pack synced (~/.claude/codex-knowledge/)" \
      || warn "Codex knowledge sync skipped (reviewer knowledge source unavailable) — re-run ~/.claude/scripts/sync-codex-knowledge.sh later."
    info "Codex enabled. Authenticate once with:  codex login"
  else
    set_codex_state "disabled"
    warn "Codex not fully installed — left DISABLED. Fix the step above and re-run install.sh to enable."
  fi
elif [ "$WANT_CODEX" = "no" ]; then
  set_codex_state "disabled"
  info "Codex left disabled. Re-run install.sh (or set INSTALL_CODEX=1) to enable later."
else
  info "Codex state unchanged."
fi

# ---------------------------------------------------------------------------
# Step 7 — Copy agents (20 agents: 8 agency + 5 custom + 7 vendored from ECC at the Opus review tier)
# ---------------------------------------------------------------------------
step "7" "Copy agents"

if [ -d "$REPO_ROOT/agents" ]; then
  cp -v "$REPO_ROOT/agents/"*.md "$CLAUDE_HOME/agents/" 2>/dev/null || true
  AGENT_COUNT=$(ls "$REPO_ROOT/agents/"*.md 2>/dev/null | wc -l | tr -d ' ')
  ok "Copied $AGENT_COUNT agent files to $CLAUDE_HOME/agents/"
else
  warn "agents/ directory not found in repo — skipping"
fi

# ---------------------------------------------------------------------------
# Step 8 — Copy skills (30 skills: 7 superpowers + 23 custom)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# NEW-AGENT WARNING. Claude Code snapshots the agent registry at session start,
# so an agent FILE copied in mid-session is not spawnable until the session
# restarts — `Agent(subagent_type: "new-agent")` hard-errors with "Agent type not
# found". Existing names DO pick up file changes (a tier edit takes effect at
# once); only NEW names need the restart.
#
# This bit real work: seven agents were vendored in, install.sh reported success,
# and every spawn of them failed until restart with nothing explaining why.
# Diff against a manifest of what the previous run installed so the next
# vendoring gets the warning for free.
AGENT_MANIFEST="$CLAUDE_HOME/.agent-manifest"
CURRENT_AGENTS=$(ls "$CLAUDE_HOME/agents"/*.md 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.md$//' | LC_ALL=C sort)
# On the FIRST install there is no manifest, so a naive `if [ -f ]` skips the
# comparison entirely — which is exactly the run that introduces the most new
# names, and the one that bit us (Codex pre-PR review, P1). Treat a missing
# manifest as an empty one: every agent is new, and the user is told once.
# No manifest yet = first install = every agent is new. Compare against
# /dev/null rather than creating an empty temp file: a shared "$AGENT_MANIFEST.empty"
# is racy between concurrent installs and is left behind if the run is interrupted
# (Codex pre-PR review, P2). /dev/null is always an empty, always-sorted input.
if [ -f "$AGENT_MANIFEST" ]; then
  COMPARE_AGAINST="$AGENT_MANIFEST"
else
  COMPARE_AGAINST=/dev/null
fi
NEW_AGENTS=$(LC_ALL=C comm -13 "$COMPARE_AGAINST" <(LC_ALL=C sort <<< "$CURRENT_AGENTS") 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')
if [ -n "$NEW_AGENTS" ]; then
    warn "NEW agent name(s) installed: $NEW_AGENTS"
    warn "  These are NOT spawnable in an already-running Claude Code session — the agent"
    warn "  registry is snapshotted at session start. Restart Claude Code before using them."
fi
printf '%s\n' "$CURRENT_AGENTS" > "$AGENT_MANIFEST"

step "8" "Copy skills"

if [ -d "$REPO_ROOT/skills" ]; then
  SKILL_COPY_FAILED=0
  for skill_dir in "$REPO_ROOT/skills"/*/; do
    if [ -d "$skill_dir" ]; then
      skill_name="$(basename "$skill_dir")"
      mkdir -p "$CLAUDE_HOME/skills/$skill_name"
      if ! cp -rv "$skill_dir"* "$CLAUDE_HOME/skills/$skill_name/" 2>/dev/null; then
        fail "Could not copy skill $skill_name to $CLAUDE_HOME/skills/"
        SKILL_COPY_FAILED=1
      fi
    fi
  done
  SKILL_COUNT=$(ls -d "$REPO_ROOT/skills"/*/ 2>/dev/null | wc -l | tr -d ' ')
  ok "Copied $SKILL_COUNT skill directories to $CLAUDE_HOME/skills/"

  # The repository is the shared source of truth for Claude and Codex skills.
  # Only copy to Codex when explicitly enabled or when a Codex skill root already
  # exists; this preserves the installer's existing Codex opt-in boundary without
  # preventing a later Codex session from using the same skill package.
  CODEX_SKILLS_HOME="${CODEX_HOME:-$HOME/.codex}/skills"
  CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
  if [ -d "$CODEX_HOME_DIR" ] || [ "${INSTALL_CODEX:-}" = "1" ] || [ "${WANT_CODEX:-skip}" = "yes" ]; then
    mkdir -p "$CODEX_SKILLS_HOME"
    for skill_dir in "$REPO_ROOT/skills"/*/; do
      if [ -d "$skill_dir" ]; then
        skill_name="$(basename "$skill_dir")"
        mkdir -p "$CODEX_SKILLS_HOME/$skill_name"
        if ! cp -rv "$skill_dir"* "$CODEX_SKILLS_HOME/$skill_name/" 2>/dev/null; then
          fail "Could not copy skill $skill_name to $CODEX_SKILLS_HOME/"
          SKILL_COPY_FAILED=1
        fi
      fi
    done
    ok "Copied $SKILL_COUNT shared skill directories to $CODEX_SKILLS_HOME"
    CODEX_SKILL_MANIFEST="${CODEX_HOME:-$HOME/.codex}/.toolbox-skill-manifest"
    {
      echo "# AI Engineering toolbox-owned Codex skills"
      for skill_dir in "$REPO_ROOT/skills"/*/; do
        [ -d "$skill_dir" ] && basename "$skill_dir"
      done
    } | LC_ALL=C sort > "$CODEX_SKILL_MANIFEST"
    if [ ! -f "$CODEX_SKILLS_HOME/presentation-master/SKILL.md" ]; then
      fail "Presentation skill was not installed for Codex"
      SKILL_COPY_FAILED=1
    fi
  else
    info "Codex skill root not enabled/present — Claude install remains complete; set INSTALL_CODEX=1 to install shared skills for Codex."
  fi
else
  warn "skills/ directory not found in repo — skipping"
fi

if [ "${SKILL_COPY_FAILED:-0}" -ne 0 ]; then
  fail "Skill installation incomplete; refusing to report a successful install"
  exit 1
fi
if [ ! -f "$CLAUDE_HOME/skills/presentation-master/SKILL.md" ]; then
  fail "Presentation skill was not installed for Claude"
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 9 — Copy commands (20 commands)
# ---------------------------------------------------------------------------
step "9" "Copy commands"

if [ -d "$REPO_ROOT/commands" ]; then
  cp -v "$REPO_ROOT/commands/"*.md "$CLAUDE_HOME/commands/" 2>/dev/null || true
  CMD_COUNT=$(ls "$REPO_ROOT/commands/"*.md 2>/dev/null | wc -l | tr -d ' ')
  ok "Copied $CMD_COUNT command files to $CLAUDE_HOME/commands/"
else
  warn "commands/ directory not found in repo — skipping"
fi

# ---------------------------------------------------------------------------
# Step 10 — Copy rules (15 rules: 7 ECC-based customized + 8 custom)
# ---------------------------------------------------------------------------
step "10" "Copy rules"

if [ -d "$REPO_ROOT/rules" ]; then
  cp -v "$REPO_ROOT/rules/"*.md "$CLAUDE_HOME/rules/" 2>/dev/null || true
  RULE_COUNT=$(ls "$REPO_ROOT/rules/"*.md 2>/dev/null | wc -l | tr -d ' ')
  ok "Copied $RULE_COUNT rule files to $CLAUDE_HOME/rules/"
else
  warn "rules/ directory not found in repo — skipping"
fi

# ---------------------------------------------------------------------------
# Step 10.5 — Copy utility scripts
# ---------------------------------------------------------------------------
step "10.5" "Copy utility scripts"

mkdir -p "$CLAUDE_HOME/scripts"
if [ -f "$REPO_ROOT/scripts/jira-board-columns.sh" ]; then
  if cp -v "$REPO_ROOT/scripts/jira-board-columns.sh" "$CLAUDE_HOME/scripts/" 2>/dev/null \
     && chmod +x "$CLAUDE_HOME/scripts/jira-board-columns.sh" 2>/dev/null; then
    ok "Copied jira-board-columns.sh to $CLAUDE_HOME/scripts/"
  else
    warn "jira-board-columns.sh did not install cleanly."
  fi
fi

# Copy the network-free phase decision helper. Board discovery remains in
# jira-board-columns.sh; this helper makes the transition/comment/block choice
# deterministic through the shared Claude state root.
if [ -f "$REPO_ROOT/scripts/jira-phase-resolver.sh" ]; then
  if cp -v "$REPO_ROOT/scripts/jira-phase-resolver.sh" "$CLAUDE_HOME/scripts/" 2>/dev/null \
     && chmod +x "$CLAUDE_HOME/scripts/jira-phase-resolver.sh" 2>/dev/null; then
    ok "Copied jira-phase-resolver.sh to $CLAUDE_HOME/scripts/"
  else
    fail "Could not install jira-phase-resolver.sh — board-aware Jira decisions are unavailable."
    INSTALL_REQUIRED_ERRORS=$((INSTALL_REQUIRED_ERRORS + 1))
  fi
else
  fail "Missing jira-phase-resolver.sh — board-aware Jira decisions are unavailable."
  INSTALL_REQUIRED_ERRORS=$((INSTALL_REQUIRED_ERRORS + 1))
fi

# Copy sync-toolbox-lessons.sh (needed for the post-merge lessons sync path).
if [ -f "$REPO_ROOT/scripts/sync-toolbox-lessons.sh" ]; then
  if cp -v "$REPO_ROOT/scripts/sync-toolbox-lessons.sh" "$CLAUDE_HOME/scripts/" 2>/dev/null \
     && chmod +x "$CLAUDE_HOME/scripts/sync-toolbox-lessons.sh" 2>/dev/null; then
    ok "Copied sync-toolbox-lessons.sh to $CLAUDE_HOME/scripts/"
  else
    warn "Could not copy sync-toolbox-lessons.sh (non-fatal) — post-merge lessons sync will be skipped until the next successful install."
  fi
fi

# Copy review-pr-precheck.sh (needed by /review-pr Step 0.7's auto-poll
# cost-optimization gate). WHY it MUST be installed: the installed copy under
# $CLAUDE_HOME/scripts/ is the ONLY path Step 0.7 ever executes — there is
# deliberately NO repo-local fallback, because any cwd-derived identity signal
# (origin URL, repo files) is forgeable local state (automated-review PR #105 security
# findings). If this copy is missing, Step 0.7 fails open (full pipeline every
# fire) — safe but unoptimized.
if [ -f "$REPO_ROOT/scripts/review-pr-precheck.sh" ]; then
  if cp -v "$REPO_ROOT/scripts/review-pr-precheck.sh" "$CLAUDE_HOME/scripts/" 2>/dev/null \
     && chmod +x "$CLAUDE_HOME/scripts/review-pr-precheck.sh" 2>/dev/null; then
    ok "Copied review-pr-precheck.sh to $CLAUDE_HOME/scripts/"
  else
    fail "Could not install review-pr-precheck.sh — /review-pr Step 0.7 cannot use its installed precheck."
    INSTALL_REQUIRED_ERRORS=$((INSTALL_REQUIRED_ERRORS + 1))
  fi
else
  fail "Missing review-pr-precheck.sh — /review-pr Step 0.7 cannot use its installed precheck."
  INSTALL_REQUIRED_ERRORS=$((INSTALL_REQUIRED_ERRORS + 1))
fi

# Copy pr-postmerge-fold.sh (the shared post-merge fold — deviation snapshot +
# automated-review/Codex lessons fold — called by /merge-pr Step 2.5 AND /review-pr
# Step 0.5's MERGED fallback so the fold runs no matter how a toolbox PR
# merged: /merge-pr, the GitHub UI, or a bare `gh pr merge`). Same trust
# boundary as review-pr-precheck.sh above: the installed copy under
# $CLAUDE_HOME/scripts/ is the ONLY path either caller ever executes — no
# repo-local fallback, so an attacker-planted repo-local script can't get
# code execution. If this copy is missing, the fold silently no-ops in both
# callers (safe — no telemetry lost beyond what was already missing).
if [ -f "$REPO_ROOT/scripts/pr-postmerge-fold.sh" ]; then
  if cp -v "$REPO_ROOT/scripts/pr-postmerge-fold.sh" "$CLAUDE_HOME/scripts/" 2>/dev/null \
     && chmod +x "$CLAUDE_HOME/scripts/pr-postmerge-fold.sh" 2>/dev/null; then
    ok "Copied pr-postmerge-fold.sh to $CLAUDE_HOME/scripts/"
  else
    warn "Could not copy pr-postmerge-fold.sh (non-fatal) — the post-merge deviation/lessons fold will be skipped until this is fixed."
  fi
fi

# Copy consume-deviations.sh (the deterministic half of the self-improvement
# loop — surface / archive / dismiss / lessons-candidates, called by /review-pr
# Step 0.5 and by Steps 7 and 7b). Same trust boundary as the two scripts above:
# the installed copy under $CLAUDE_HOME/scripts/ is the ONLY path the command
# ever executes, because /review-pr can fire while the shell's cwd is a
# completely different repo and a repo-local scripts/ path would be
# attacker-plantable code execution. If this copy is missing, Step 0.5 warns and
# PRESERVES the snapshots rather than consuming them — no records are lost, the
# queue simply waits for a working install.
if [ -f "$REPO_ROOT/scripts/consume-deviations.sh" ]; then
  # ⛔ STAGE THEN RENAME — NEVER cp STRAIGHT OVER THE LIVE CONSUMER. ⛔ A plain
  # `cp` TRUNCATES the destination before it writes a byte, so a disk-full,
  # permission or I/O error partway through leaves a HALF-WRITTEN script at the
  # only path every caller executes — and this failure is deliberately
  # non-fatal, so install would go on to report success over it. That fragment
  # is not inert: consume-deviations.sh performs `rm -f` under $HOME, and a
  # truncation can land anywhere, including after a delete but before the guard
  # that authorizes it.
  #
  # Copying to a temp file IN THE SAME DIRECTORY and then `mv`-ing is what
  # removes the window: a rename within one filesystem is atomic, so the
  # destination is either the previous complete script or the new complete
  # script, never a fragment of either. Same directory is load-bearing — across
  # a mount point `mv` degrades to copy+unlink and the window comes back.
  # `chmod +x` is applied to the STAGED file so the mode arrives with the
  # content rather than after it.
  #
  # NOTE FOR A FOLLOW-UP: every sibling script copied in this file (the
  # review-pr precheck, the post-merge fold, the codex fallback, the loop
  # progress signature) still uses the plain `cp` shape. They are left alone
  # here on purpose — this branch owns consume-deviations.sh, and generalising
  # the pattern across the installer belongs with issues #145/#147.
  #
  # ⛔ AND THE STAGING NAME MUST NOT BE GUESSABLE. ⛔ It was
  # `.consume-deviations.sh.$$.tmp` — a PID, which is a small guessable integer
  # — and `cp` FOLLOWS a symlink already sitting at its destination. Anything
  # able to write $CLAUDE_HOME/scripts could therefore pre-create that name as a
  # link and have the installer write this script's contents through it to a
  # target of its choosing; worse, the `mv` that follows would then move the
  # LINK into place, leaving every caller executing a file the attacker still
  # controls. `mktemp` is given a TEMPLATE inside the destination directory, not
  # a bare `mktemp`, because the same-filesystem property above is what makes
  # the rename atomic.
  #
  # ⛔ WHAT mktemp CLOSES, AND WHAT IT DOES NOT — because the first draft of this
  # comment implied it closed the whole thing. ⛔
  #   IT DOES     close the CREATION race and remove the guessable name: mktemp
  #               creates the file itself with O_EXCL, so a path already sitting
  #               at that name is refused rather than opened, and the name is
  #               random rather than derived from the PID.
  #   IT DOES NOT stop the PATHNAME being replaced afterwards. `cp`, the test
  #               below, `chmod` and `mv` each reopen the staging path BY NAME,
  #               so an actor able to write this directory can unlink the staged
  #               file and drop a symlink in its place between any two of them.
  #               That window is narrowed here, not eliminated, and no rewrite
  #               of this block in bash eliminates it — there is no no-follow
  #               copy primitive to reach for, and building one would be more
  #               machinery than the exposure justifies.
  #
  # The `! -L` / `-f` test after the `cp` is DEFENCE IN DEPTH, and is worth one
  # line for what it prevents rather than for closing a live hole: if the staged
  # file was swapped for a link before the copy, the copy has already written
  # through it — that write is not recoverable here — but the test stops the
  # LINK being renamed into place, which is the more severe half, because that
  # is what would leave every later /review-pr executing a target the planter
  # still controls. The `rm -f` in the failure branch then removes the link
  # itself, not what it points at.
  #
  # ⛔ AND THE THREAT MODEL, PLAINLY, SO NOBODY SPENDS MORE ON THIS. ⛔ Every
  # variant above needs an actor who can already create files in
  # $CLAUDE_HOME/scripts — the directory that HOLDS the live consumer and the
  # other installed scripts. Such an actor can simply overwrite
  # consume-deviations.sh directly, before or after any install, and never race
  # anything. The staging path is not the weak link, and this is the same
  # adjudication made about the `state_symlink_violation` TOCTOU earlier on this
  # branch: anyone who can symlink inside ~/.claude already runs as the user.
  #
  # `chmod 755`, not `chmod +x`: mktemp creates the file 0600, so `+x` would
  # install this one script as 0700 while every sibling in that directory is
  # 0755. The mode is deliberately the mode the previous `cp`-then-`chmod +x`
  # produced — changing what gets installed is not this fix's job.
  _cd_staged=$(mktemp "$CLAUDE_HOME/scripts/.consume-deviations.sh.XXXXXX" 2>/dev/null) || _cd_staged=""
  if [ -z "$_cd_staged" ]; then
    # No staging file means nothing was attempted at all, so say that rather
    # than reusing the failed-copy wording: the live consumer was never opened.
    warn "Could not create a staging file for consume-deviations.sh (non-fatal) — /review-pr will PRESERVE deviation/lessons snapshots instead of surfacing them until this is fixed. Nothing was written; the previously installed copy, if any, is untouched and still complete."
  elif cp "$REPO_ROOT/scripts/consume-deviations.sh" "$_cd_staged" 2>/dev/null \
     && [ ! -L "$_cd_staged" ] && [ -f "$_cd_staged" ] \
     && chmod 755 "$_cd_staged" 2>/dev/null \
     && mv -f "$_cd_staged" "$CLAUDE_HOME/scripts/consume-deviations.sh" 2>/dev/null; then
    ok "Copied consume-deviations.sh to $CLAUDE_HOME/scripts/"
  else
    # Clear the fragment rather than leaving a dot-file nobody will look for.
    # `|| true` because the installer runs under `set -e` and a failed cleanup
    # must not be more fatal than the failed install it is cleaning up after.
    rm -f "$_cd_staged" 2>/dev/null || true
    warn "Could not copy consume-deviations.sh (non-fatal) — /review-pr will PRESERVE deviation/lessons snapshots instead of surfacing them until this is fixed. The previously installed copy, if any, is untouched and still complete."
  fi
fi

# Copy codex-exec-with-fallback.sh (the codex-review skill's pinned-model retry
# contract — GPT-5.6 Terra pin with one-shot unpinned fallback on model errors).
# If this copy is missing, the skill degrades to an unpinned codex exec on the
# config.toml default model — safe, just not pinned to the review-gate tier.
# loop-progress-signature.sh — guard 2 of the three loop guards (the
# no-progress detector). It has to live in $CLAUDE_HOME/scripts/ because its
# callers run from a PROJECT repo, not from this checkout: a loop body or a
# /goal phase in someone else's repo has no path to this directory. Same
# reasoning, and same install shape, as review-pr-precheck.sh above.
if [ -f "$REPO_ROOT/scripts/loop-progress-signature.sh" ]; then
  if cp -v "$REPO_ROOT/scripts/loop-progress-signature.sh" "$CLAUDE_HOME/scripts/" 2>/dev/null \
     && chmod +x "$CLAUDE_HOME/scripts/loop-progress-signature.sh" 2>/dev/null; then
    ok "Copied loop-progress-signature.sh to $CLAUDE_HOME/scripts/"
  else
    warn "loop-progress-signature.sh did NOT install — the no-progress guard will be unavailable to loops in project repos."
    warn "  Fix with: cp \"$REPO_ROOT/scripts/loop-progress-signature.sh\" \"$CLAUDE_HOME/scripts/\""
  fi
else
  fail "Missing loop-progress-signature.sh — the no-progress guard cannot be installed."
  INSTALL_REQUIRED_ERRORS=$((INSTALL_REQUIRED_ERRORS + 1))
fi

# Record the trusted Claude executable so loop-launch works when Claude was
# installed through npm/nvm and a later project PATH contains a shim.
CLAUDE_BIN_RECORD="$CLAUDE_HOME/scripts/claude-bin"
CLAUDE_BIN_RESOLVED="$(canonicalize_path "$CLAUDE_BIN" 2>/dev/null || true)"
CLAUDE_BIN_RESOLVED="$(canonicalize_path "$CLAUDE_BIN_RESOLVED" 2>/dev/null || true)"
if [[ -n "$CLAUDE_BIN_RESOLVED" && -x "$CLAUDE_BIN_RESOLVED" && ! -d "$CLAUDE_BIN_RESOLVED" ]] \
   && is_trusted_claude_path "$CLAUDE_BIN_RESOLVED"; then
  if printf '%s\n' "$CLAUDE_BIN_RESOLVED" > "$CLAUDE_BIN_RECORD" \
     && chmod 644 "$CLAUDE_BIN_RECORD" 2>/dev/null; then
    ok "Recorded Claude CLI path for portable loop launches"
  else
    warn "Could not record the Claude CLI path; loop-launch will use trusted native locations."
  fi
else
  warn "Could not record an absolute Claude CLI path; loop-launch will use trusted native locations."
fi

# Install the shared bounded loop resolver/launcher and deterministic observer.
for loop_script in loop-config.sh loop-launch.sh; do
  if [ -f "$REPO_ROOT/scripts/$loop_script" ]; then
    if cp -v "$REPO_ROOT/scripts/$loop_script" "$CLAUDE_HOME/scripts/" 2>/dev/null \
       && chmod +x "$CLAUDE_HOME/scripts/$loop_script" 2>/dev/null; then
      ok "Copied $loop_script to $CLAUDE_HOME/scripts/"
    else
      fail "$loop_script did not install cleanly — bounded loop launches are unavailable."
      INSTALL_REQUIRED_ERRORS=$((INSTALL_REQUIRED_ERRORS + 1))
    fi
  else
    fail "Missing $loop_script — bounded loop launches are unavailable."
    INSTALL_REQUIRED_ERRORS=$((INSTALL_REQUIRED_ERRORS + 1))
  fi
done

# INSTALL-SCRIPT-COPY-BEGIN (observe.sh) — extracted by test-install-script-copy.sh.
if [ -f "$REPO_ROOT/scripts/observe.sh" ]; then
  if cp -v "$REPO_ROOT/scripts/observe.sh" "$CLAUDE_HOME/scripts/" 2>/dev/null; then
    if chmod +x "$CLAUDE_HOME/scripts/observe.sh" 2>/dev/null; then
      ok "Copied observe.sh to $CLAUDE_HOME/scripts/"
    else
      warn "observe.sh was copied but could NOT be made executable — declared-work observation is unavailable."
      warn "  Fix with: chmod +x \"$CLAUDE_HOME/scripts/observe.sh\""
    fi
  else
    warn "observe.sh did NOT install — declared-work observation is unavailable."
    warn "  Fix with: cp \"$REPO_ROOT/scripts/observe.sh\" \"$CLAUDE_HOME/scripts/\""
  fi
fi
# INSTALL-SCRIPT-COPY-END (observe.sh)

# The durable GoalRun CLI remains available to the /goal command. It is copied
# to both provider homes independently of the optional Codex pre-PR reviewer;
# either provider can therefore resume a run after the other reaches a limit.
if [ -f "$REPO_ROOT/scripts/goal_loop_runtime.py" ] && [ -f "$REPO_ROOT/scripts/goal-loop" ]; then
  if cp -v "$REPO_ROOT/scripts/goal_loop_runtime.py" "$CLAUDE_HOME/scripts/" 2>/dev/null \
     && cp -v "$REPO_ROOT/scripts/goal-loop" "$CLAUDE_HOME/scripts/" 2>/dev/null \
     && chmod +x "$CLAUDE_HOME/scripts/goal-loop" 2>/dev/null; then
    ok "Copied durable goal-loop runtime to $CLAUDE_HOME/scripts/"
  else
    warn "Could not copy durable goal-loop runtime — /goal will remain unavailable until install succeeds."
  fi
fi

if [ -f "$REPO_ROOT/scripts/register-pr-poll.sh" ]; then
  if cp -v "$REPO_ROOT/scripts/register-pr-poll.sh" "$CLAUDE_HOME/scripts/" 2>/dev/null \
     && chmod +x "$CLAUDE_HOME/scripts/register-pr-poll.sh" 2>/dev/null; then
    ok "Copied provider-neutral PR poll registrar to $CLAUDE_HOME/scripts/"
  else
    warn "Could not copy provider-neutral PR poll registrar to Claude."
  fi
fi

CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
if [ -d "$CODEX_HOME_DIR" ] || [ "${INSTALL_CODEX:-}" = "1" ]; then
  CODEX_BIN_HOME="$CODEX_HOME_DIR/bin"
  mkdir -p "$CODEX_BIN_HOME"
  if [ -f "$REPO_ROOT/scripts/goal_loop_runtime.py" ] && [ -f "$REPO_ROOT/scripts/goal-loop" ]; then
    if cp -v "$REPO_ROOT/scripts/goal_loop_runtime.py" "$CODEX_BIN_HOME/" 2>/dev/null \
       && cp -v "$REPO_ROOT/scripts/goal-loop" "$CODEX_BIN_HOME/" 2>/dev/null \
       && chmod +x "$CODEX_BIN_HOME/goal-loop" 2>/dev/null; then
      ok "Copied durable goal-loop runtime to $CODEX_BIN_HOME/"
    else
      warn "Could not copy durable goal-loop runtime to Codex."
    fi
  fi
  if [ -f "$REPO_ROOT/scripts/register-pr-poll.sh" ] && cp -v "$REPO_ROOT/scripts/register-pr-poll.sh" "$CODEX_BIN_HOME/" 2>/dev/null \
     && chmod +x "$CODEX_BIN_HOME/register-pr-poll.sh" 2>/dev/null; then
    ok "Copied provider-neutral PR poll registrar to $CODEX_BIN_HOME/"
  else
    warn "Could not copy provider-neutral PR poll registrar to Codex."
  fi
fi

# Keep Codex's local merge hook synchronized when its hook directory exists.
if [ -f "$REPO_ROOT/scripts/sync-codex-pr-action-hook.sh" ]; then
  CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
  CODEX_HOOKS_DIR="$CODEX_HOME/hooks"
  if [ -d "$CODEX_HOOKS_DIR" ]; then
    if bash "$REPO_ROOT/scripts/sync-codex-pr-action-hook.sh" "$CODEX_HOOKS_DIR" 2>/dev/null; then
      ok "Synchronized Codex PR-action safety hook"
    else
      warn "Codex PR-action safety hook was not synchronized (non-fatal)."
    fi
  else
    info "Codex hooks directory does not exist — skipping local PR-action hook synchronization."
  fi
fi

if [ -f "$REPO_ROOT/scripts/codex-exec-with-fallback.sh" ]; then
  if cp -v "$REPO_ROOT/scripts/codex-exec-with-fallback.sh" "$CLAUDE_HOME/scripts/" 2>/dev/null \
     && chmod +x "$CLAUDE_HOME/scripts/codex-exec-with-fallback.sh" 2>/dev/null; then
    ok "Copied codex-exec-with-fallback.sh to $CLAUDE_HOME/scripts/"
  else
    warn "Could not copy codex-exec-with-fallback.sh (non-fatal) — the codex-review gate will run unpinned on the config.toml default model until this is fixed."
  fi
fi

# Copy sync-codex-knowledge.sh so the codex-review skill can re-sync the knowledge
# pack from the TRUSTED installed copy. The skill runs in arbitrary project repos —
# it must never execute a repo-local scripts/ path (an attacker-planted file would
# get code execution; same trust boundary as review-pr-precheck.sh and
# codex-exec-with-fallback.sh above). The script's own REPO_ROOT derivation
# ($SCRIPT_DIR/..) resolves to ~/.claude when run from ~/.claude/scripts/, so it
# reads the installed skill's review-concepts-distilled.md — also trusted.
# If this copy is missing, the skill skips the sync and reviews without the pack.
if [ -f "$REPO_ROOT/scripts/sync-codex-knowledge.sh" ]; then
  if cp -v "$REPO_ROOT/scripts/sync-codex-knowledge.sh" "$CLAUDE_HOME/scripts/" 2>/dev/null \
     && chmod +x "$CLAUDE_HOME/scripts/sync-codex-knowledge.sh" 2>/dev/null; then
    ok "Copied sync-codex-knowledge.sh to $CLAUDE_HOME/scripts/"
  else
    warn "Could not copy sync-codex-knowledge.sh (non-fatal) — the codex-review skill will skip pack re-sync until this is fixed."
  fi
fi

# Run the toolbox-lessons sync to populate the fast tier from knowledge/toolbox-lessons.yml.
# Fail-soft: if the source is missing or sync fails for any reason, install continues.
# WHY: The sync runs after the Codex pack sync (Step 10.x) so both knowledge packs are
# fresh at the same time. A first-time install with an empty lessons list produces a valid
# empty fast tier — no lessons to inject yet, but the file structure is ready.
if [ -f "$REPO_ROOT/scripts/sync-toolbox-lessons.sh" ]; then
  # Capture the exit code rather than `|| true` + an unconditional ok. Exit 3 means
  # the pack was written but the fast tier came out EMPTY while the source declares
  # lessons — the agent would read none. Discarding stderr AND the status made that
  # state invisible on every install.
  SYNC_RC=0
  bash "$REPO_ROOT/scripts/sync-toolbox-lessons.sh" --quiet 2>/dev/null || SYNC_RC=$?
  if [ "$SYNC_RC" -eq 0 ]; then
    ok "Toolbox lessons knowledge pack synced."
  elif [ "$SYNC_RC" -eq 3 ]; then
    warn "Toolbox lessons synced but the FAST TIER IS EMPTY — agents will read no lessons."
    warn "A lesson block in knowledge/toolbox-lessons.yml is likely malformed (missing 'status: active')."
    warn "Diagnose with: bash scripts/sync-toolbox-lessons.sh"
  elif [ "$SYNC_RC" -eq 4 ]; then
    # Exit 4 needs its OWN branch: the pack is written and usable, so the generic
    # branch below would call it "stale or missing" and send the developer looking
    # for the wrong problem. Install continues either way — the pack is on disk.
    #
    # ⛔ SAY ONLY WHAT EXIT 4 PROVES. ⛔ The sync script raises 4 from THREE places
    # (see its eviction-report block), and only its own stderr separates them:
    #   1. an evicted lesson's priority column read something other than
    #      "normal" — in practice `priority: high`, possibly MORE THAN ONE; or
    #   2. the decision manifest was missing, truncated, or not terminated by its
    #      `#END` sentinel, so the script could not tell WHAT was evicted, let
    #      alone whether any of it was high, and escalated rather than stay
    #      silent. Nothing is demonstrated to have gone missing on this path —
    #      deleting the manifest after a cap pass in which everything FIT also
    #      lands here — which is exactly why it names nothing; or
    #   3. the capping pass recorded its decisions IN FULL and then exited
    #      non-zero. Here the verdicts ARE readable and every eviction is named;
    #      the escalation is that the tier on disk may not match the record.
    # The earlier wording here asserted (1) unconditionally and in the singular
    # ("a ... lesson", "that one"), which is simply false in cases (2) and (3),
    # and understates case (1) when several were dropped. The headline used to
    # assert a SEVERE eviction outright, which (2) and (3) both reach with no
    # high-priority lesson in the source at all.
    warn "Toolbox lessons synced, but the run could NOT confirm every 'priority: high' lesson survived the 8 KB cap (exit 4)."
    warn "That means one of five things, and only the sync's own output tells you which:"
    warn "  - one or more lessons above ordinary priority were pushed out of the fast tier, or"
    warn "  - the sync could not confirm what was dropped — its decision manifest was missing,"
    warn "    truncated, or unterminated — so it escalated rather than report nothing, or"
    warn "  - the capping pass recorded its decisions in full and then failed; it NAMES every"
    warn "    eviction, but the fast tier on disk may not match what it recorded."
    warn "  - the record was complete but tagged to ANOTHER run — a concurrent sync sharing this"
    warn "    HOME replaced it mid-run, so its verdicts describe that run's fast tier, not this one's, or"
    warn "  - a reader of the record failed, so the figures could not be taken at all."
    warn "The SLOW tier (the full lesson set) is on disk either way; anything evicted stays there but reaches no review prompt."
    warn "The FAST tier is not guaranteed on this path — a pass that recorded its decisions and then died can leave none at all."
    warn "See which lessons, and how many, with: bash scripts/sync-toolbox-lessons.sh"
  else
    # ANY other non-zero is a real failure and must not be reported as success.
    # The first version of this block special-cased only 3 and let everything else
    # fall through to `ok` — converting a genuine sync failure into a healthy-looking
    # install with a stale or missing lessons pack (automated-review, PR #134). That is the
    # same silent-success shape this whole branch is about, reintroduced in the fix
    # for it.
    warn "Toolbox lessons sync FAILED (exit $SYNC_RC) — the lessons pack may be stale or missing."
    warn "Install continues; diagnose with: bash scripts/sync-toolbox-lessons.sh"
  fi
fi

# ---------------------------------------------------------------------------
# Step 10.6 — Install hooks (backup handover)
# ---------------------------------------------------------------------------
step "10.6" "Install hooks"

if [ -d "$REPO_ROOT/hooks" ]; then
  # -------------------------------------------------------------------------
  # THE HOOK ROSTER — one name list, one checked copy loop.
  #
  # WHY A ROSTER AND NOT 19 `cp` LINES: hooks-config.json registers every hook
  # UNCONDITIONALLY, so a hook this step never copies — or copies
  # unsuccessfully — makes the registered command exit 127. 127 is NOT exit 2,
  # so PreToolUse does not block: the guard FAILS OPEN while this install
  # prints success. That is issue #145's class, and it has now shipped twice
  # (#145, then #160 when enforce-fable-review.sh was added with no copy line
  # at all, because install.sh was owned by an open PR at the time).
  #
  # #160 fixed the SHAPE for three hooks by checking `cp`'s exit status, and
  # left FOURTEEN on the unchecked `cp … || true` form — including
  # enforce-compliance-audit.sh and enforce-pr-skill.sh, both of which gate PR
  # creation. Same incident, one file over. Copying from a roster in a loop
  # that checks every copy makes "unchecked hook copy" a shape that cannot
  # exist here, rather than a rule fourteen lines have to keep remembering.
  #
  # Checking the EXIT STATUS matters more than checking that the file exists:
  # if a STALE copy from an older install is already present and the overwrite
  # fails (permission or filesystem error), an existence check passes while the
  # gate silently runs OUTDATED logic (automated-review PR #77 round-2).
  #
  # ⛔ Do not add a hook to hooks/ or to hooks-config.json without adding it
  # here. scripts/verify-hooks.sh TC-HI-1/2/3 assert the three-way agreement
  # between this roster, hooks-config.json and hooks/*.sh, and TC-HI-5/6/7
  # assert that uninstall.sh's three lists cover it too. Those cases replace
  # the per-hook TC-EFR-8 and TC-ELB-27 pins with the same property applied to
  # every hook.
  # -------------------------------------------------------------------------
  HOOK_FILES=(
    audit-model-usage.sh
    auto-poll-after-pr.sh
    compliance-auditor.sh
    consume-pr-markers.sh
    enforce-ask-budget.sh
    enforce-auto-poll.sh
    enforce-chief-of-staff.sh
    enforce-codex-review.sh
    enforce-compliance-audit.sh
    enforce-fable-review.sh
    enforce-jira-delegation.sh
    enforce-loop-bounds.sh
    enforce-pr-skill.sh
    enforce-skill-delegation.sh
    enforce-standing-auth.sh
    enforce-transition-script.sh
    enforce-workflow-start.sh
    pr-action-safety.sh
    push-safety.sh
    workflow-auto-approve.sh
  )

  HOOK_COPY_FAILURES=0
  for hook_name in "${HOOK_FILES[@]}"; do
    # `if ! cp` consumes the non-zero exit, so a failed copy warns loudly and
    # does NOT abort the install under `set -euo pipefail`.
    if ! cp -v "$REPO_ROOT/hooks/$hook_name" "$CLAUDE_HOME/hooks/" 2>/dev/null; then
      HOOK_COPY_FAILURES=$((HOOK_COPY_FAILURES + 1))
      echo "⚠️  WARNING: $hook_name did NOT install/update to $CLAUDE_HOME/hooks/." >&2
      echo "    hooks-config.json registers it regardless, so the missing or stale hook exits 127 —" >&2
      echo "    which is NOT exit 2, so PreToolUse does not block and that guard FAILS OPEN." >&2
      echo "    Copy it manually:" >&2
      # `cp -f`, not plain `cp`: the comment above names the stale-and-unwritable
      # case as a reason this copy fails, and in exactly that case a plain `cp`
      # fails identically (measured: plain cp exit 1, cp -f exit 0). Printing a
      # remedy that reproduces the failure it is offered for is the H1 shape.
      echo "      cp -f \"$REPO_ROOT/hooks/$hook_name\" \"$CLAUDE_HOME/hooks/\"" >&2
    fi
  done

  # Remove enforce-handover-writer if previously installed (hook removed — Single-Writer Rule now enforced by prompt instructions only)
  rm -f "$CLAUDE_HOME/hooks/enforce-handover-writer.sh" 2>/dev/null || true
  # Clean up old hook name if present from previous install
  rm -f "$CLAUDE_HOME/hooks/handover-auto-approve.sh" 2>/dev/null || true
  if ! chmod +x "$CLAUDE_HOME/hooks/"*.sh 2>/dev/null; then
    fail "Hook scripts were copied but could not all be made executable."
    INSTALL_REQUIRED_ERRORS=$((INSTALL_REQUIRED_ERRORS + 1))
  fi
  # Report what actually happened. An unconditional `ok` here would be the same
  # silent-success shape the checked copies exist to remove: the whole point of
  # checking `cp` is lost if the summary line says "copied" either way.
  if [ "$HOOK_COPY_FAILURES" -gt 0 ]; then
    warn "$HOOK_COPY_FAILURES of ${#HOOK_FILES[@]} hook scripts did NOT copy — enforcement is INCOMPLETE. See the warnings above."
  else
    ok "All ${#HOOK_FILES[@]} hook scripts copied to $CLAUDE_HOME/hooks/"
  fi

  # Generate project hooks template (kept for reference / per-project overrides)
  if [ -f "$REPO_ROOT/hooks/hooks-config.json" ]; then
    sed "s|~/|$HOME/|g" "$REPO_ROOT/hooks/hooks-config.json" > "$CLAUDE_HOME/hooks/project-hooks-template.json"
    ok "Project hooks template saved to $CLAUDE_HOME/hooks/project-hooks-template.json"
  fi

  # Merge hooks into global settings.json so they're active immediately after install.
  # Safety hooks (push-safety, pr-action-safety, etc.) should be global — they protect
  # every project, not just ones that opted in. The install script runs in the user's
  # terminal (not inside Claude), so the classifier doesn't block this write.
  SETTINGS_FILE="$CLAUDE_HOME/settings.json"
  if [ -f "$CLAUDE_HOME/hooks/project-hooks-template.json" ]; then
    if [ -f "$SETTINGS_FILE" ]; then
      node -e "
        const fs = require('fs');
        let settings;
        try {
          settings = JSON.parse(fs.readFileSync('$SETTINGS_FILE', 'utf8'));
        } catch (e) {
          console.error('Warning: $SETTINGS_FILE contains invalid JSON — backing up and recreating');
          fs.copyFileSync('$SETTINGS_FILE', '$SETTINGS_FILE.bak');
          settings = {};
        }
        const template = JSON.parse(fs.readFileSync('$CLAUDE_HOME/hooks/project-hooks-template.json', 'utf8'));
        // Merge hooks: for template matchers, replace wholesale (removes stale hooks on upgrade).
        // For user-added matchers not in the template, preserve them.
        if (!settings.hooks) settings.hooks = {};
        for (const [event, matchers] of Object.entries(template.hooks || {})) {
          if (!settings.hooks[event]) { settings.hooks[event] = matchers; continue; }
          for (const newMatcher of matchers) {
            const idx = settings.hooks[event].findIndex(m => m.matcher === newMatcher.matcher);
            if (idx >= 0) {
              settings.hooks[event][idx] = newMatcher;
            } else {
              settings.hooks[event].push(newMatcher);
            }
          }
        }
        if (!settings.permissions) settings.permissions = {};
        if (!settings.permissions.deny) settings.permissions.deny = [];
        fs.writeFileSync('$SETTINGS_FILE', JSON.stringify(settings, null, 2));
      "
      ok "Hooks merged into global $SETTINGS_FILE"
    else
      # No settings.json yet — create one from the template, then seed the
      # orchestrator tier. "model" is only ever written on a FRESH install:
      # the merge branch above deliberately leaves non-hook keys alone, so an
      # existing developer's model choice is never overwritten by an update.
      # Fable is the orchestrator tier per rules/performance.md ("The four
      # tiers"); subagent tiers come from agent frontmatter, not from here.
      cp "$CLAUDE_HOME/hooks/project-hooks-template.json" "$SETTINGS_FILE"
      node -e "
        const fs = require('fs');
        const settings = JSON.parse(fs.readFileSync('$SETTINGS_FILE', 'utf8'));
        settings.model = 'fable';
        fs.writeFileSync('$SETTINGS_FILE', JSON.stringify(settings, null, 2));
      " 2>/dev/null && MODEL_SEEDED=1 || MODEL_SEEDED=0
      # Only claim the tier was set if it actually was. Reporting success on a
      # failed seed left a fresh install silently on the wrong orchestrator tier
      # with an "ok" line saying otherwise (automated-review PR #132).
      if [ "$MODEL_SEEDED" = "1" ]; then
        ok "Created $SETTINGS_FILE with hooks config + Fable orchestrator tier"
      else
        warn "Created $SETTINGS_FILE with hooks config, but could NOT seed the orchestrator model — set \"model\": \"fable\" in $SETTINGS_FILE manually, or pick it with /model."
      fi
    fi
  fi

  # Codex uses the same managed hook source, translated to its native hooks.json
  # shape. Keep this independent of the optional Codex reviewer/CLI setup: an
  # already-installed Codex host must receive current safety and polling hooks
  # even when Claude or Codex usage limits prevent the reviewer from running.
  CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
  if [ -d "$CODEX_HOME_DIR" ] || [ "${INSTALL_CODEX:-}" = "1" ]; then
    CODEX_HOOKS_DIR="$CODEX_HOME_DIR/hooks"
    CODEX_HOOKS_CONFIG="$CODEX_HOME_DIR/hooks.json"
    if [ -x "$REPO_ROOT/scripts/sync-provider-hooks.sh" ]; then
      if bash "$REPO_ROOT/scripts/sync-provider-hooks.sh" \
          --source "$REPO_ROOT/hooks" \
          --destination "$CODEX_HOOKS_DIR" \
          --config "$CODEX_HOOKS_CONFIG" \
          --provider codex >/dev/null 2>&1; then
        ok "Synchronized managed hooks and config for Codex at $CODEX_HOME_DIR"
      else
        fail "Codex hook synchronization failed — its guardrails may be stale."
        INSTALL_REQUIRED_ERRORS=$((INSTALL_REQUIRED_ERRORS + 1))
      fi
    else
      fail "Codex hook synchronizer is missing or not executable."
      INSTALL_REQUIRED_ERRORS=$((INSTALL_REQUIRED_ERRORS + 1))
    fi
  else
    info "Codex home not present — skipping Codex hook synchronization."
  fi

  # Clean up managed-hooks tracking file (legacy)
  rm -f "$CLAUDE_HOME/.managed-hooks.json" 2>/dev/null || true
else
  warn "hooks/ directory not found in repo — skipping"
fi

# ---------------------------------------------------------------------------
# Step 11 — Install Beads
# ---------------------------------------------------------------------------
step "11" "Install Beads"

if command -v bd &>/dev/null || command -v beads &>/dev/null; then
  ok "Beads CLI already installed"
else
  case "$OS" in
    mac)
      info "Installing Beads CLI via Homebrew..."
      brew install beads 2>/dev/null || {
        warn "Homebrew install failed — trying install script..."
        curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash 2>/dev/null || warn "Beads install failed — see https://github.com/steveyegge/beads/blob/main/docs/INSTALLING.md"
      }
      ;;
    linux)
      info "Installing Beads CLI..."
      if command -v brew &>/dev/null; then
        info "Homebrew detected — installing via brew..."
        brew install beads 2>/dev/null || {
          warn "Homebrew install failed — trying install script..."
          curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash 2>/dev/null || warn "Beads install failed — see https://github.com/steveyegge/beads/blob/main/docs/INSTALLING.md"
        }
      else
        curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash 2>/dev/null || {
          warn "Install script failed — trying go install..."
          if command -v go &>/dev/null; then
            go install github.com/steveyegge/beads/cmd/bd@latest 2>/dev/null || warn "go install failed — see https://github.com/steveyegge/beads/blob/main/docs/INSTALLING.md"
          else
            warn "Beads install failed (no Go found) — see https://github.com/steveyegge/beads/blob/main/docs/INSTALLING.md"
          fi
        }
      fi
      ;;
    windows)
      info "Installing Beads CLI..."
      if command -v go &>/dev/null; then
        go install -tags gms_pure_go github.com/steveyegge/beads/cmd/bd@latest 2>/dev/null || warn "go install failed — see https://github.com/steveyegge/beads/blob/main/docs/INSTALLING.md"
      else
        warn "Beads requires Go on Windows — install Go from https://go.dev then run: go install -tags gms_pure_go github.com/steveyegge/beads/cmd/bd@latest"
      fi
      ;;
  esac

  if command -v bd &>/dev/null || command -v beads &>/dev/null; then
    ok "Beads CLI installed"
  else
    # Check common install locations that may not be on PATH
    BD_FOUND=""
    for bd_path in "$HOME/.local/bin/bd" "$HOME/go/bin/bd" "${GOPATH:-/nonexistent}/bin/bd"; do
      if [ -x "$bd_path" ]; then
        BD_FOUND="$bd_path"
        break
      fi
    done
    if [ -n "$BD_FOUND" ]; then
      BD_DIR=$(dirname "$BD_FOUND")
      warn "Beads CLI installed at $BD_FOUND but not on PATH"
      warn "Add to your shell profile: export PATH=\"$BD_DIR:\$PATH\""
    else
      warn "Beads CLI not installed — agent will work without it but loses cross-session context"
    fi
  fi
fi

# Install Beads plugin in Claude Code
if [ -n "$CLAUDE_BIN" ] && "$CLAUDE_BIN" plugin list 2>/dev/null | grep -q "beads"; then
  ok "Beads plugin already installed"
else
  info "Installing Beads Claude Code plugin..."
  "$CLAUDE_BIN" plugin marketplace add steveyegge/beads 2>/dev/null || true
  if "$CLAUDE_BIN" plugin install beads@beads-marketplace 2>/dev/null; then
    ok "Beads plugin installed"
  else
    warn "Beads plugin install failed — Beads CLI works without the plugin"
  fi
fi

# Save managed plugins list for next install (to detect removals)
printf '[\n  "everything-claude-code",\n  "beads"\n]\n' > "$PREV_MANAGED_PLUGINS_FILE"

# ---------------------------------------------------------------------------
# Step 11.5 — Ensure GitHub CLI (gh)
# ---------------------------------------------------------------------------
step "11.5" "Ensure GitHub CLI (gh)"

if command -v gh &>/dev/null; then
  ok "GitHub CLI already installed ($(gh --version | head -1))"
else
  info "Installing GitHub CLI..."
  case "$OS" in
    mac)
      brew install gh 2>/dev/null || warn "GitHub CLI install failed — install manually: brew install gh"
      ;;
    linux)
      if command -v brew &>/dev/null; then
        brew install gh 2>/dev/null || warn "Homebrew install failed"
      elif [ "$PACKAGE_MANAGER" = "apt" ]; then
        # Official GitHub apt repo
        (type -p wget >/dev/null || sudo apt install -y wget) && \
        sudo mkdir -p -m 755 /etc/apt/keyrings && \
        wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null && \
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
        sudo apt update && sudo apt install -y gh 2>/dev/null || warn "GitHub CLI install failed — see https://cli.github.com/"
      elif [ "$PACKAGE_MANAGER" = "dnf" ]; then
        sudo dnf install -y gh 2>/dev/null || warn "GitHub CLI install failed — see https://cli.github.com/"
      elif [ "$PACKAGE_MANAGER" = "pacman" ]; then
        sudo pacman -S --noconfirm github-cli 2>/dev/null || warn "GitHub CLI install failed — see https://cli.github.com/"
      else
        warn "GitHub CLI install failed — see https://cli.github.com/"
      fi
      ;;
    windows)
      winget install GitHub.cli 2>/dev/null || warn "GitHub CLI install failed — see https://cli.github.com/"
      ;;
  esac

  if command -v gh &>/dev/null; then
    ok "GitHub CLI installed"
  else
    warn "GitHub CLI (gh) not installed — PR creation and GitHub operations will not work"
  fi
fi

# Check gh auth status
if command -v gh &>/dev/null; then
  if gh auth status &>/dev/null; then
    ok "GitHub CLI authenticated"
  else
    info "GitHub CLI not authenticated — run 'gh auth login' to connect"
  fi
fi

# ---------------------------------------------------------------------------
# Step 11.6 — Ensure Atlassian CLI (acli)
# ---------------------------------------------------------------------------
step "11.6" "Ensure Atlassian CLI (acli)"

if command -v acli &>/dev/null; then
  ok "Atlassian CLI already installed"
else
  info "Installing Atlassian CLI..."
  case "$OS" in
    mac)
      brew tap atlassian/homebrew-acli 2>/dev/null || true
      brew install acli 2>/dev/null || warn "acli install failed — see https://developer.atlassian.com/cloud/acli/"
      ;;
    linux)
      if command -v brew &>/dev/null; then
        brew tap atlassian/homebrew-acli 2>/dev/null || true
        brew install acli 2>/dev/null || warn "acli install failed via brew"
      elif [ "$PACKAGE_MANAGER" = "apt" ]; then
        # Official Atlassian apt repo
        sudo apt-get install -y wget gnupg2 2>/dev/null || true
        sudo mkdir -p -m 755 /etc/apt/keyrings
        wget -nv -O- https://acli.atlassian.com/gpg/public-key.asc | sudo gpg --dearmor -o /etc/apt/keyrings/acli-archive-keyring.gpg 2>/dev/null
        sudo chmod go+r /etc/apt/keyrings/acli-archive-keyring.gpg 2>/dev/null
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/acli-archive-keyring.gpg] https://acli.atlassian.com/linux/deb stable main" | sudo tee /etc/apt/sources.list.d/acli.list > /dev/null 2>/dev/null
        sudo apt update 2>/dev/null && sudo apt install -y acli 2>/dev/null || warn "acli apt install failed"
      elif [ "$PACKAGE_MANAGER" = "dnf" ]; then
        sudo yum-config-manager --add-repo https://acli.atlassian.com/linux/rpm/acli.repo 2>/dev/null
        sudo yum install -y acli 2>/dev/null || warn "acli yum install failed"
      else
        # Binary download fallback
        info "Downloading acli binary..."
        ACLI_ARCH="amd64"
        case "$(uname -m)" in aarch64|arm64) ACLI_ARCH="arm64" ;; esac
        curl -LO "https://acli.atlassian.com/linux/latest/acli_linux_${ACLI_ARCH}/acli" 2>/dev/null && \
          chmod +x ./acli && \
          mkdir -p "$HOME/.local/bin" && \
          mv ./acli "$HOME/.local/bin/acli" && \
          info "acli installed to ~/.local/bin/acli" || \
          warn "acli install failed — see https://developer.atlassian.com/cloud/acli/"
      fi
      ;;
    windows)
      winget install Atlassian.AtlassianCLI 2>/dev/null || {
        warn "winget install failed — trying binary download..."
        curl -LO "https://acli.atlassian.com/windows/latest/acli_windows_amd64/acli.exe" 2>/dev/null && \
          info "acli.exe downloaded — move to a directory on your PATH" || \
          warn "acli install failed — see https://developer.atlassian.com/cloud/acli/"
      }
      ;;
  esac

  if command -v acli &>/dev/null; then
    ok "Atlassian CLI installed"
  else
    warn "Atlassian CLI (acli) not installed — Jira operations will not work. Set up later via /init."
  fi
fi

# ---------------------------------------------------------------------------
# Step 11.7 — Ensure jq (required by hooks)
# ---------------------------------------------------------------------------
step "11.7" "Ensure jq"

if command -v jq &>/dev/null; then
  ok "jq already installed"
else
  info "Installing jq..."
  case "$OS" in
    mac)
      brew install jq 2>/dev/null || warn "jq install failed"
      ;;
    linux)
      case "$PACKAGE_MANAGER" in
        apt)    sudo apt install -y jq 2>/dev/null || warn "jq install failed" ;;
        dnf)    sudo dnf install -y jq 2>/dev/null || warn "jq install failed" ;;
        pacman) sudo pacman -S --noconfirm jq 2>/dev/null || warn "jq install failed" ;;
      esac
      ;;
    windows)
      winget install jqlang.jq 2>/dev/null || warn "jq install failed — install manually: https://jqlang.github.io/jq/"
      ;;
  esac

  if command -v jq &>/dev/null; then
    ok "jq installed"
  else
    warn "jq not installed — hook scripts that parse JSON input will not work (enforce-*, push-safety, pr-action-safety, workflow-auto-approve)"
  fi
fi

# ---------------------------------------------------------------------------
# Step 11.8 — Ensure Dolt (Beads dependency)
# ---------------------------------------------------------------------------
step "11.8" "Ensure Dolt (Beads dependency)"

if command -v dolt &>/dev/null; then
  ok "Dolt already installed"
else
  info "Installing Dolt..."
  case "$OS" in
    mac)
      brew install dolt 2>/dev/null || warn "Dolt install failed"
      ;;
    linux)
      if command -v brew &>/dev/null; then
        brew install dolt 2>/dev/null || warn "Dolt install failed via brew"
      else
        curl -fsSL https://github.com/dolthub/dolt/releases/latest/download/install.sh | bash 2>/dev/null || warn "Dolt install failed — see https://docs.dolthub.com/introduction/installation"
      fi
      ;;
    windows)
      if command -v winget &>/dev/null; then
        winget install DoltHub.Dolt 2>/dev/null || warn "Dolt install failed — see https://docs.dolthub.com/introduction/installation"
      else
        warn "Dolt not installed — install manually: https://docs.dolthub.com/introduction/installation"
      fi
      ;;
  esac

  if command -v dolt &>/dev/null; then
    ok "Dolt installed"
  else
    warn "Dolt not installed — Beads sync features may not work"
  fi
fi

# ---------------------------------------------------------------------------
# Step 12 — Configure MCPs
# ---------------------------------------------------------------------------
step "12" "Configure MCPs"

CLAUDE_JSON="$HOME/.claude.json"

if [ -f "$REPO_ROOT/mcp-configs/mcp-servers.json" ]; then
  if [ -f "$CLAUDE_JSON" ]; then
    info "Merging MCP config into existing $CLAUDE_JSON"
    # Back up existing config
    cp "$CLAUDE_JSON" "$CLAUDE_JSON.backup.$(date +%Y%m%d%H%M%S)"
    ok "Backup created"

    # Replace managed MCP servers (remove stale ones, add new ones, preserve user-added ones)
    # MCPs listed in mcp-servers.json are "managed" — they get replaced.
    # Any MCP in ~/.claude.json that is NOT in mcp-servers.json is "user-added" and preserved.
    node -e "
      const fs = require('fs');
      const existing = JSON.parse(fs.readFileSync('$CLAUDE_JSON', 'utf8'));
      const managed = JSON.parse(fs.readFileSync('$REPO_ROOT/mcp-configs/mcp-servers.json', 'utf8'));
      const managedKeys = Object.keys(managed.mcpServers || {});

      // Read previous managed keys (saved from last install) to detect removals
      const prevManagedPath = '$CLAUDE_HOME/.managed-mcps.json';
      let prevManaged = [];
      try { prevManaged = JSON.parse(fs.readFileSync(prevManagedPath, 'utf8')); } catch {}

      // Remove previously managed MCPs that are no longer in the repo
      const currentServers = existing.mcpServers || {};
      for (const key of prevManaged) {
        if (!managedKeys.includes(key)) {
          delete currentServers[key];
        }
      }

      // Merge current managed MCPs (preserving user-set env values like tokens)
      for (const [key, val] of Object.entries(managed.mcpServers)) {
        if (currentServers[key] && currentServers[key].env) {
          // Preserve non-empty env values the user already configured
          const userEnv = currentServers[key].env;
          val.env = val.env || {};
          for (const [envKey, envVal] of Object.entries(userEnv)) {
            if (envVal && envVal.length > 0) val.env[envKey] = envVal;
          }
        }
        currentServers[key] = val;
      }

      // Expand ~ to real home directory in args
      for (const [key, val] of Object.entries(currentServers)) {
        if (val.args) {
          val.args = val.args.map(a => a.replace(/^~\//, '$HOME/'));
        }
      }

      existing.mcpServers = currentServers;
      fs.writeFileSync('$CLAUDE_JSON', JSON.stringify(existing, null, 2));

      // Save current managed keys for next install
      fs.writeFileSync(prevManagedPath, JSON.stringify(managedKeys, null, 2));
    "
    ok "MCP servers synced to $CLAUDE_JSON (stale MCPs removed, user tokens preserved)"
  else
    info "Creating $CLAUDE_JSON with MCP config"
    cp "$REPO_ROOT/mcp-configs/mcp-servers.json" "$CLAUDE_JSON"
    ok "MCP config created at $CLAUDE_JSON"
  fi
else
  warn "mcp-configs/mcp-servers.json not found — skipping MCP configuration"
fi

# ---------------------------------------------------------------------------
# Create memory.md template
# ---------------------------------------------------------------------------
info "Setting up memory.md template..."

MEMORY_FILE="$CLAUDE_HOME/memory.md"
if [ -f "$MEMORY_FILE" ]; then
  ok "memory.md already exists — not overwriting"
else
  if [ -f "$REPO_ROOT/memory.md" ]; then
    cp "$REPO_ROOT/memory.md" "$MEMORY_FILE"
    ok "memory.md template created at $MEMORY_FILE"
  else
    warn "memory.md template not found in repo — creating blank"
    cat > "$MEMORY_FILE" << 'MEMEOF'
# Personal Defaults

> This file is managed by /init. Do not edit manually.

## Tool
<!-- filled by /init -->

## Methodology
<!-- filled by /init -->

## Logging
<!-- filled by /init -->

## Team Size
<!-- filled by /init -->

## CI/CD
<!-- filled by /init -->

## Tracking
<!-- filled by /init -->

## Notifications
<!-- filled by /init -->

## Jira URL
<!-- filled by /init -->

## Jira Workflow
<!-- filled by /init -->
MEMEOF
    ok "Blank memory.md created at $MEMORY_FILE"
  fi
fi

# Save a simple marker in memory.md's Tool section so /init can skip Q0.
# No tool choice menu anymore — this is always "Claude Code".
TOOL_NAME="Claude Code"
if grep -q "<!-- filled by /init -->" "$MEMORY_FILE" 2>/dev/null; then
  awk -v tool="$TOOL_NAME" '/^## Tool$/{print; getline; print tool; next}1' "$MEMORY_FILE" > "$MEMORY_FILE.tmp" && mv "$MEMORY_FILE.tmp" "$MEMORY_FILE"
elif grep -q "^## Tool" "$MEMORY_FILE" 2>/dev/null; then
  awk -v tool="$TOOL_NAME" '/^## Tool$/{print; getline; print tool; next}1' "$MEMORY_FILE" > "$MEMORY_FILE.tmp" && mv "$MEMORY_FILE.tmp" "$MEMORY_FILE"
fi

# ---------------------------------------------------------------------------
# Step 13 — Safety net: gitignore toolbox if cloned inside a project repo
# ---------------------------------------------------------------------------
# If someone cloned ai-engineering inside their project (e.g. ~/projects/my-app/ai-engineering),
# add ai-engineering/ to the parent project's .gitignore so it never gets committed.
PARENT_DIR="$(dirname "$REPO_ROOT")"
TOOLBOX_DIRNAME="$(basename "$REPO_ROOT")"
# Use git rev-parse instead of [ -d .git ] — handles worktrees and submodules
# where .git is a file, not a directory.
if git -C "$PARENT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ "$PARENT_DIR" != "$REPO_ROOT" ]; then
  PARENT_GITIGNORE="$PARENT_DIR/.gitignore"
  # Symlink defense: don't follow symlinks — a malicious parent repo could
  # point .gitignore at an arbitrary file outside the repo boundary.
  if [ -L "$PARENT_GITIGNORE" ]; then
    warn "Skipping parent .gitignore update because $PARENT_GITIGNORE is a symlink."
  elif ! grep -qF "$TOOLBOX_DIRNAME/" "$PARENT_GITIGNORE" 2>/dev/null; then
    {
      printf "\n"
      printf "# ai-engineering toolbox — cloned locally, should not be committed\n"
      printf "%s/\n" "$TOOLBOX_DIRNAME"
    } >> "$PARENT_GITIGNORE"
    ok "Added $TOOLBOX_DIRNAME/ to parent project's .gitignore ($PARENT_GITIGNORE)"
    warn "Tip: move the toolbox outside your project (e.g. ~/tools/ai-engineering) to keep things clean."
  fi
fi

# ---------------------------------------------------------------------------
# Step 13.5 — Save toolbox path to ~/.claude/memory.md
# ---------------------------------------------------------------------------
# /start and /init use this path to detect whether the installed toolbox is
# stale. Save REPO_ROOT under a "## Toolbox Path" section in memory.md so the
# commands can check drift without asking the user.
# Idempotent: updates the existing value if already present, adds a new
# section otherwise.
TOOLBOX_PATH_SECTION="## Toolbox Path"
if grep -q "^$TOOLBOX_PATH_SECTION$" "$MEMORY_FILE" 2>/dev/null; then
  # Section exists — rewrite it using a state machine that correctly handles:
  #   1. Value line exists immediately after heading → replace it
  #   2. Value line missing (heading followed directly by next ## or EOF) →
  #      insert the new value. The old `awk ... getline ... next` approach
  #      unconditionally consumed the line after the heading, which SWALLOWED
  #      the next section's heading when no value was present.
  awk -v path="$REPO_ROOT" '
    BEGIN { skip=0; printed=0 }
    # Match the Toolbox Path heading: print it, write the new value, then
    # enter skip mode to drop the old value line (if any).
    /^## Toolbox Path$/ {
      print
      print path
      printed=1
      skip=1
      next
    }
    # In skip mode, stop skipping as soon as we hit another heading or end of
    # file. This is how we avoid swallowing adjacent sections when the
    # current section had no value line under it.
    skip == 1 && /^## / {
      skip=0
      print
      next
    }
    # Skip mode: drop the single old value line (if it exists). One-shot —
    # after dropping one line we are back in normal mode.
    skip == 1 {
      skip=0
      next
    }
    # Normal line — print as-is
    { print }
  ' "$MEMORY_FILE" > "$MEMORY_FILE.tmp" && mv "$MEMORY_FILE.tmp" "$MEMORY_FILE"
else
  # Section missing — append it
  printf "\n%s\n%s\n" "$TOOLBOX_PATH_SECTION" "$REPO_ROOT" >> "$MEMORY_FILE"
fi
ok "Saved toolbox path to ~/.claude/memory.md (used by /start and /init)"

# ---------------------------------------------------------------------------
# Run verification
# ---------------------------------------------------------------------------
printf "\n"
info "Running verification..."
if [ -x "$REPO_ROOT/scripts/verify.sh" ]; then
  bash "$REPO_ROOT/scripts/verify.sh"
else
  warn "verify.sh not found or not executable — skipping verification"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
printf "\n"
printf "${GREEN}════════════════════════════════════════════════════════${NC}\n"
printf "${GREEN}  ✅ Installation complete                             ${NC}\n"
if [ "$INSTALL_REQUIRED_ERRORS" -gt 0 ]; then
  fail "Installation finished with $INSTALL_REQUIRED_ERRORS required error(s); fix them and rerun the installer."
  exit 1
fi
printf "${GREEN}════════════════════════════════════════════════════════${NC}\n"
printf "\n"
printf "${BLUE}  Next steps:${NC}\n"
printf "    1. cd into your project directory (or stay here if already there)\n"
printf "    2. Run ${GREEN}claude${NC} to start Claude Code\n"
printf "       (works in any terminal — standalone or inside your IDE's terminal pane)\n"
printf "    3. If asked to log in, select ${GREEN}Claude.ai Subscription${NC}\n"
printf "       (the company Team/Enterprise subscription)\n"
printf "    4. Type ${GREEN}/start${NC} in the chat\n"
printf "\n"
info "Installed to: $CLAUDE_HOME"
info "MCP config:   $CLAUDE_JSON"
info "Run ./scripts/verify.sh at any time to check health"
printf "\n"

# Show what's installed
printf "${BLUE}── What's installed ──${NC}\n"
info "Claude Code toolbox:  $CLAUDE_HOME (agents, skills, commands, rules, MCPs)"
printf "\n"
