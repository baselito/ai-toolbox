#!/usr/bin/env bash

# =============================================================================
# AI Engineering — Health Check (Dynamic)
# Verifies all components are installed and consistent.
# Reads expected components from the REPO, not hardcoded lists.
# Silent when healthy — only reports problems.
# =============================================================================

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ok()   { printf "${GREEN}  ✅ %s${NC}\n" "$1"; }
warn() { printf "${YELLOW}  ⚠️  %s${NC}\n" "$1"; WARNINGS=$((WARNINGS + 1)); }
fail() { printf "${RED}  ❌ %s${NC}\n" "$1"; ERRORS=$((ERRORS + 1)); }
info() { printf "${BLUE}  ℹ️  %s${NC}\n" "$1"; }

ERRORS=0
WARNINGS=0

# ---------------------------------------------------------------------------
# run_bounded_capture <limit_s> <command> [<arg>…]  →  RBC_RC, RBC_OUT, RBC_TIMED_OUT
#
# ⛔ NO SUITE THIS VERIFIER RUNS MAY WAIT WITHOUT A BOUND. ⛔ The observe.sh
# acceptance suite exists because an unbounded `until grep …; do sleep 5; done`
# ran ELEVEN HOURS, and this verifier used to launch it as a bare command
# substitution — so the one regression that suite exists to catch (a wait with no
# bound) would have HUNG the verifier rather than being reported by it. A checker
# that inherits the bug it checks for is not a checker.
#
# `timeout`/`gtimeout` do not exist on the primary dev platform (stock macOS), so
# this is the same hand-written shape scripts/observe.sh uses in `run_bounded`,
# for the same reason:
#   - the child runs in its OWN PROCESS GROUP (`set -m`), and the group is what
#     gets signalled. A kill aimed only at the foreground child leaves anything
#     the child forked alive, and process-group membership survives reparenting.
#   - the child writes its OWN exit status to a sentinel file and the poll waits
#     for THAT, not for the process to vanish: a reaped-but-not-yet-waited child
#     is a zombie, and `kill -0` calls a zombie alive, which would turn every
#     bounded run into a full-length wait.
#   - the deadline is `date +%s` arithmetic with a 1-second real sleep. The
#     pacing has to come from a real clock.
#
# ⛔ A TIMEOUT IS NOT A TEST FAILURE. ⛔ RBC_TIMED_OUT is reported SEPARATELY from
# the exit code, because "the suite hung" and "a test failed" are different
# defects with different fixes, and a caller that folded them together would
# report the eleven-hour bug as "some test is red".
#
# Always returns 0 and communicates through the three variables, so a caller
# running under `set -e` cannot be aborted by a bounded child's exit status.
# ---------------------------------------------------------------------------
RBC_RC=0
RBC_OUT=""
RBC_TIMED_OUT=0

_rbc_kill_group() {
  local pgid="$1"
  case "$pgid" in ''|*[!0-9]*) return 0 ;; esac
  # Fast path: an empty group needs no signals, and skips the grace sleep for the
  # overwhelmingly common case of a child that forked nothing.
  if command -v pgrep >/dev/null 2>&1 && ! pgrep -g "$pgid" >/dev/null 2>&1; then
    return 0
  fi
  kill -TERM "-$pgid" 2>/dev/null || :
  # Fallback for the case where no process group could be established (no job
  # control): reaches direct children only, the subset the group kill covers.
  command -v pkill >/dev/null 2>&1 && { pkill -TERM -P "$pgid" 2>/dev/null || :; }
  sleep 1
  kill -KILL "-$pgid" 2>/dev/null || :
  command -v pkill >/dev/null 2>&1 && { pkill -KILL -P "$pgid" 2>/dev/null || :; }
  return 0
}

# `set -m` (needed for the process group) makes the shell REPORT each job's
# termination on its OWN stderr — "Terminated: 15 { … }" — which would land in the
# verifier's output every time the bound fires and read like a verifier crash. The
# wrapper discards that. A redirection on a FUNCTION CALL does not fork a
# subshell, so RBC_RC/RBC_OUT/RBC_TIMED_OUT are still set in the caller. Same
# split, for the same reason, as observe.sh's run_bounded/run_bounded_impl.
run_bounded_capture() {
  run_bounded_capture_impl "$@"
}

run_bounded_capture_impl() {
  local limit="$1"; shift
  local out_file rc_file launch_file pid pgid deadline now had_monitor capture_attempt
  local progress_interval progress_at progress_label elapsed
  RBC_RC=0
  RBC_OUT=""
  RBC_TIMED_OUT=0

  progress_interval="${RBC_PROGRESS_INTERVAL_S:-60}"
  case "$progress_interval" in
    ''|*[!0-9]*|0) progress_interval=60 ;;
  esac
  progress_label="${RBC_PROGRESS_LABEL:-bounded verifier command}"

  out_file=$(mktemp "${TMPDIR:-/tmp}/verify.bounded.XXXXXX" 2>/dev/null) || {
    RBC_RC=126
    RBC_OUT="verify: cannot create a temp file for bounded output"
    return 0
  }
  rc_file="${out_file}.rc"
  launch_file="${out_file}.launch"

  had_monitor=0
  case "$-" in *m*) had_monitor=1 ;; esac
  set -m
  # Keep the wrapper idle until the parent has captured its process group. The
  # wrapped command may finish immediately, but its descendants must remain in
  # a group we can sweep; launching it before `ps` races with that cleanup. If
  # the group cannot be captured, the wrapper can be killed safely because the
  # user command has not started. The verifier itself is commonly run with
  # `set -e`, so record the child's non-zero result explicitly before writing
  # the sentinel.
  {
    local rc=0
    while [ ! -f "$launch_file" ]; do sleep 0.01; done
    # Run in the wrapper's foreground. A nested `&` would let Bash create a
    # second job/process group, leaving its descendants outside the group the
    # parent captured and later sweeps.
    "$@" >"$out_file" 2>&1 || rc=$?
    printf '%s' "$rc" > "$rc_file"
  } &
  pid=$!
  # Retry while the wrapper is held alive by launch_file. This makes a
  # transient `ps` miss harmless without ever guessing from a PID that may be
  # reused.
  pgid=""
  for capture_attempt in {1..100}; do
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || :)
    case "$pgid" in ''|*[!0-9]*) pgid="" ;; *) break ;; esac
    # In restricted environments `ps` may be unavailable even though Bash
    # successfully created the monitored job. With the wrapper still idle and
    # `set -m` active, its PID is the job's process-group leader; validate that
    # group exists before using this safe pre-launch fallback. The user command
    # has not started yet, so this PID cannot have been reused.
    if kill -0 -- "-$pid" 2>/dev/null; then
      pgid="$pid"
      break
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.01
  done
  [ "$had_monitor" -eq 1 ] || set +m
  if [ -z "$pgid" ]; then
    kill -TERM "$pid" 2>/dev/null || :
    wait "$pid" 2>/dev/null || :
    RBC_RC=125
    RBC_OUT="verify: cannot capture a process group for bounded command"
    rm -f "$out_file" "$rc_file" "$launch_file" 2>/dev/null || :
    return 0
  fi
  : > "$launch_file"
  now=$(date +%s)
  deadline=$(( now + limit ))
  progress_at=$(( now + progress_interval ))

  while :; do
    if [ -s "$rc_file" ]; then
      RBC_RC=$(cat "$rc_file" 2>/dev/null)
      case "$RBC_RC" in ''|*[!0-9]*) RBC_RC=1 ;; esac
      break
    fi
    now=$(date +%s)
    if [ "$now" -ge "$progress_at" ]; then
      elapsed=$(( now - (deadline - limit) ))
      printf "${BLUE}  ℹ️  %s still running (%ss elapsed; bound %ss)${NC}\n" \
        "$progress_label" "$elapsed" "$limit" >&2
      progress_at=$(( now + progress_interval ))
    fi
    if [ "$now" -ge "$deadline" ]; then
      kill -TERM "$pid" 2>/dev/null || :
      [ -n "$pgid" ] && _rbc_kill_group "$pgid"
      RBC_RC=124                 # mirrors GNU timeout, for readability
      RBC_TIMED_OUT=1
      break
    fi
    sleep 1
  done

  wait "$pid" 2>/dev/null || :
  # Sweep on EVERY path, not only on timeout: a command that returned normally can
  # still have left background children behind.
  [ -n "$pgid" ] && _rbc_kill_group "$pgid"
  RBC_OUT=$(cat "$out_file" 2>/dev/null)
  rm -f "$out_file" "$rc_file" "$launch_file" 2>/dev/null || :
  return 0
}

# TEST SEAM — verify.sh has no test harness of its own, and the bound above is
# exactly the kind of thing that is easy to delete and impossible to notice. With
# VERIFY_LIB_ONLY set, sourcing this file defines the helpers above and returns
# BEFORE any check runs, so scripts/test-observe.sh (T35) can exercise
# run_bounded_capture directly. It changes nothing about a normal run: the
# variable is set by the test and by nothing else.
if [ -n "${VERIFY_LIB_ONLY:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------------------
# Detect OS and paths
# ---------------------------------------------------------------------------
case "$(uname -s)" in
  Darwin*|Linux*)
    CLAUDE_HOME="$HOME/.claude"
    ;;
  CYGWIN*|MINGW*|MSYS*)
    CLAUDE_HOME="${APPDATA:-$HOME/.claude}/Claude"
    if [ ! -d "$CLAUDE_HOME" ]; then
      CLAUDE_HOME="$HOME/.claude"
    fi
    ;;
  *)
    CLAUDE_HOME="$HOME/.claude"
    ;;
esac

CLAUDE_JSON="$HOME/.claude.json"

# Locate repo root
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)"

if [ ! -f "$REPO_ROOT/CLAUDE.md" ]; then
  fail "Cannot find ai-engineering repo root"
  exit 1
fi

printf "${BLUE}── Part 1: Installation Health ──${NC}\n\n"

# ---------------------------------------------------------------------------
# Check: Claude Code CLI
# ---------------------------------------------------------------------------
CLAUDE_BIN=""
if command -v claude &>/dev/null; then
  CLAUDE_BIN="claude"
  ok "Claude Code CLI installed (on PATH)"
else
  # Check native app install locations (macOS desktop app, not npm)
  for claude_path in \
    "$HOME/Library/Application Support/Claude/claude-code"/*/claude.app/Contents/MacOS/claude \
    "$HOME/Library/Application Support/Claude/claude-code-vm"/*/claude \
    "$HOME/.local/share/claude"*/claude; do
    if [ -x "$claude_path" ] 2>/dev/null; then
      CLAUDE_BIN="$claude_path"
      break
    fi
  done
  if [ -n "$CLAUDE_BIN" ]; then
    ok "Claude Code CLI installed (native app)"
  else
    fail "Claude Code CLI not found — install via Claude desktop app or: npm install -g @anthropic-ai/claude-code"
  fi
fi

# ---------------------------------------------------------------------------
# Check: Node.js
# ---------------------------------------------------------------------------
if command -v node &>/dev/null; then
  ok "Node.js installed ($(node --version))"
else
  fail "Node.js not found — required for Claude Code and MCP servers"
fi

# ---------------------------------------------------------------------------
# Check: Agents (dynamic — reads from repo agents/ directory)
# ---------------------------------------------------------------------------
REPO_AGENT_COUNT=0
MISSING_AGENTS=()

for agent_file in "$REPO_ROOT/agents/"*.md; do
  [ -f "$agent_file" ] || continue
  agent_name="$(basename "$agent_file")"
  REPO_AGENT_COUNT=$((REPO_AGENT_COUNT + 1))
  if [ ! -f "$CLAUDE_HOME/agents/$agent_name" ]; then
    MISSING_AGENTS+=("${agent_name%.md}")
  fi
done

if [ ${#MISSING_AGENTS[@]} -eq 0 ]; then
  ok "All $REPO_AGENT_COUNT agents installed"
else
  fail "Missing agents (${#MISSING_AGENTS[@]} of $REPO_AGENT_COUNT): ${MISSING_AGENTS[*]}"
  info "Fix: re-run ./scripts/install.sh"
fi

# ---------------------------------------------------------------------------
# Check: Skills (dynamic — reads from repo skills/ directory)
# ---------------------------------------------------------------------------
REPO_SKILL_COUNT=0
MISSING_SKILLS=()

for skill_dir in "$REPO_ROOT/skills/"/*/; do
  [ -d "$skill_dir" ] || continue
  skill_name="$(basename "$skill_dir")"
  REPO_SKILL_COUNT=$((REPO_SKILL_COUNT + 1))
  if [ ! -d "$CLAUDE_HOME/skills/$skill_name" ]; then
    MISSING_SKILLS+=("$skill_name")
  fi
done

if [ ${#MISSING_SKILLS[@]} -eq 0 ]; then
  ok "All $REPO_SKILL_COUNT skills installed"
else
  fail "Missing skills (${#MISSING_SKILLS[@]} of $REPO_SKILL_COUNT): ${MISSING_SKILLS[*]}"
  info "Fix: re-run ./scripts/install.sh"
fi

# ---------------------------------------------------------------------------
# Check: Commands (dynamic — reads from repo commands/ directory)
# ---------------------------------------------------------------------------
REPO_CMD_COUNT=0
MISSING_COMMANDS=()

for cmd_file in "$REPO_ROOT/commands/"*.md; do
  [ -f "$cmd_file" ] || continue
  cmd_name="$(basename "$cmd_file")"
  REPO_CMD_COUNT=$((REPO_CMD_COUNT + 1))
  if [ ! -f "$CLAUDE_HOME/commands/$cmd_name" ]; then
    MISSING_COMMANDS+=("${cmd_name%.md}")
  fi
done

if [ ${#MISSING_COMMANDS[@]} -eq 0 ]; then
  ok "All $REPO_CMD_COUNT commands installed"
else
  fail "Missing commands (${#MISSING_COMMANDS[@]} of $REPO_CMD_COUNT): ${MISSING_COMMANDS[*]}"
  info "Fix: re-run ./scripts/install.sh"
fi

# ---------------------------------------------------------------------------
# Check: Rules (dynamic — reads from repo rules/ directory)
# ---------------------------------------------------------------------------
REPO_RULE_COUNT=0
MISSING_RULES=()

for rule_file in "$REPO_ROOT/rules/"*.md; do
  [ -f "$rule_file" ] || continue
  rule_name="$(basename "$rule_file")"
  REPO_RULE_COUNT=$((REPO_RULE_COUNT + 1))
  if [ ! -f "$CLAUDE_HOME/rules/$rule_name" ]; then
    MISSING_RULES+=("${rule_name%.md}")
  fi
done

# ---------------------------------------------------------------------------
# Check: Hooks (dynamic — reads from repo hooks/ directory)
# Counts only the executable hook scripts, excluding pre-commit-check.sh
# (documented as a standalone repo-verification script, not a Claude Code
# hook) and hooks-config.json (config, not a script). README/CLAUDE.md counts
# for hooks and docs had no automated check before this — only agents,
# skills, commands, and rules were cross-checked — so a stale count in either
# category could ship silently. This closes that gap.
# ---------------------------------------------------------------------------
REPO_HOOK_COUNT=0
for hook_file in "$REPO_ROOT/hooks/"*.sh; do
  [ -f "$hook_file" ] || continue
  # Only executable scripts count as installed hooks — a stray non-executable
  # helper .sh in hooks/ must not inflate the count (matches the doc comment
  # above; all 17 real hooks carry the exec bit, preserved by git).
  [ -x "$hook_file" ] || continue
  hook_name="$(basename "$hook_file")"
  [ "$hook_name" = "pre-commit-check.sh" ] && continue
  REPO_HOOK_COUNT=$((REPO_HOOK_COUNT + 1))
done

# ---------------------------------------------------------------------------
# Check: Docs (dynamic — reads from repo docs/ directory)
# ---------------------------------------------------------------------------
REPO_DOC_COUNT=$(find "$REPO_ROOT/docs" -name "*.md" | wc -l | tr -d ' ')

if [ ${#MISSING_RULES[@]} -eq 0 ]; then
  ok "All $REPO_RULE_COUNT rules installed"
else
  fail "Missing rules (${#MISSING_RULES[@]} of $REPO_RULE_COUNT): ${MISSING_RULES[*]}"
  info "Fix: re-run ./scripts/install.sh"
fi

# ---------------------------------------------------------------------------
# Check: ECC plugin
# ---------------------------------------------------------------------------
ECC_FOUND=false
if [ -n "$CLAUDE_BIN" ]; then
  if "$CLAUDE_BIN" plugin list 2>/dev/null | grep -q "everything-claude-code"; then
    ECC_FOUND=true
  fi
fi
# Also check plugin cache directory directly (works even when claude isn't on PATH)
if [ "$ECC_FOUND" = false ]; then
  for ecc_dir in "$CLAUDE_HOME/plugins/cache/"*everything-claude-code* "$CLAUDE_HOME/plugins/"*everything-claude-code*; do
    if [ -d "$ecc_dir" ] 2>/dev/null; then
      ECC_FOUND=true
      break
    fi
  done
fi
if [ "$ECC_FOUND" = true ]; then
  ok "ECC plugin installed"
else
  fail "ECC plugin not found"
  info "Fix: claude plugin marketplace add affaan-m/everything-claude-code && claude plugin install everything-claude-code@everything-claude-code"
fi

# ---------------------------------------------------------------------------
# Check: Beads
# ---------------------------------------------------------------------------
if command -v bd &>/dev/null || command -v beads &>/dev/null; then
  ok "Beads CLI installed"
else
  fail "Beads CLI not found — see https://github.com/steveyegge/beads/blob/main/docs/INSTALLING.md"
fi

# ---------------------------------------------------------------------------
# Check: MCP connections
# ---------------------------------------------------------------------------
if [ -f "$CLAUDE_JSON" ]; then
  ok "MCP config exists ($CLAUDE_JSON)"

  # Check each MCP: does the entry exist, and are the tokens filled in?
  # Optional MCPs (seq, context7) — only show if entry exists
  # Note: Jira uses acli and GitHub uses gh CLI — neither is MCP, checked separately below
  check_mcp() {
    local mcp="$1"
    local required="$2"
    local status
    status=$(node -e "
      const c = JSON.parse(require('fs').readFileSync('$CLAUDE_JSON', 'utf8'));
      const srv = c.mcpServers && c.mcpServers['$mcp'];
      if (!srv) { console.log('missing'); process.exit(0); }
      const env = srv.env || {};
      const envKeys = Object.keys(env);
      if (envKeys.length === 0) { console.log('connected'); process.exit(0); }
      const empty = envKeys.filter(k => !env[k] || env[k].length === 0);
      if (empty.length === 0) { console.log('connected'); }
      else { console.log('not-connected'); }
    " 2>/dev/null)

    case "$status" in
      connected)
        ok "MCP: $mcp connected"
        ;;
      not-connected)
        info "MCP: $mcp installed — not connected yet (connect via /start or /init on a project)"
        ;;
      missing)
        if [ "$required" = "required" ]; then
          info "MCP: $mcp not found in config — set up via /start or /init on a project"
        fi
        ;;
    esac
  }

  check_mcp "seq" "optional"
  check_mcp "context7" "optional"

  # Check GitHub CLI (gh) — replaces GitHub MCP
  if command -v gh &>/dev/null; then
    if gh auth status &>/dev/null; then
      ok "GitHub CLI (gh) authenticated"
    else
      info "GitHub CLI (gh) installed but not authenticated — run: gh auth login"
    fi
  else
    info "GitHub CLI (gh) not found — install with: brew install gh"
  fi
else
  fail "MCP config not found at $CLAUDE_JSON"
  info "Fix: re-run ./scripts/install.sh"
fi

# ---------------------------------------------------------------------------
# Check: Atlassian CLI (acli) for Jira
# ---------------------------------------------------------------------------
if command -v acli &>/dev/null; then
  ok "Atlassian CLI (acli) installed — $(acli --version 2>/dev/null | head -1)"
  # Check if authenticated
  if acli jira auth status &>/dev/null 2>&1; then
    ok "acli authenticated to Jira"
  else
    warn "acli installed but not authenticated — run: acli jira auth login --site your-team.atlassian.net --email YOUR_EMAIL --token"
  fi
else
  warn "Atlassian CLI (acli) not installed — Jira integration will not work"
  info "Fix: brew tap atlassian/homebrew-acli && brew install acli"
fi

# ---------------------------------------------------------------------------
# Check: jq (required by hooks)
# ---------------------------------------------------------------------------
if command -v jq &>/dev/null; then
  ok "jq installed"
else
  warn "jq not installed — several enforcement hooks (push-safety, pr-action-safety, enforce-*) will not work"
  info "Fix: brew install jq (macOS) / sudo apt install jq (Linux)"
fi

# ---------------------------------------------------------------------------
# Check: Dolt (Beads dependency)
# ---------------------------------------------------------------------------
if command -v dolt &>/dev/null; then
  ok "Dolt installed (Beads dependency)"
else
  warn "Dolt not installed — Beads sync features may not work"
  info "Fix: brew install dolt"
fi

# ---------------------------------------------------------------------------
# Check: memory.md
# ---------------------------------------------------------------------------
if [ -f "$CLAUDE_HOME/memory.md" ]; then
  ok "memory.md exists"
else
  warn "memory.md not found — will be created on first /init run"
fi

printf "\n${BLUE}── Part 2: Documentation Consistency ──${NC}\n\n"

# ---------------------------------------------------------------------------
# Check: Counts in README match actual files
# ---------------------------------------------------------------------------
README="$REPO_ROOT/README.md"
DOC_ERRORS=0

if [ -f "$README" ]; then
  # ---------------------------------------------------------------------------
  # Shared three-way count comparison.
  #   $1 label  $2 file  $3 extracted value  $4 expected  $5 pattern hint
  #
  # ⛔ A MISSING COUNT LINE IS A `fail`, NEVER A SILENT `ok`. ⛔
  # Two of the four checks in this section were originally written as
  #     if [ -n "$VALUE" ] && [ "$VALUE" != "$EXPECTED" ]; then fail; else ok; fi
  # which prints a GREEN TICK having compared nothing whenever the grep comes back
  # empty. The hooks and docs checks were fixed for exactly this; the agent and
  # command checks were not — and the agent one then went INERT when README's stats
  # row was reformatted from `Agents | N custom` to `Agents | N total (M in repo + K
  # ECC)`. Measured: `grep -o 'Agents | [0-9]* custom' README.md` returns empty. Five
  # stale agent counts shipped and a PR REVIEWER found them, not this suite.
  #
  # One implementation, used by every count check below, because three copies of this
  # branching is how the original asymmetry started.
  check_doc_count() {
    if [ -z "$3" ]; then
      fail "$2: $1 count line not found (expected $5) — format changed? Update this check's pattern."
      DOC_ERRORS=$((DOC_ERRORS + 1))
    elif [ "$3" != "$4" ]; then
      fail "$2 says $3 $1 but expected $4"
      DOC_ERRORS=$((DOC_ERRORS + 1))
    else
      ok "$2 $1 count matches ($4)"
    fi
  }

  # ---------------------------------------------------------------------------
  # Agents. README row: `| Agents | 25 total (20 in repo + 5 ECC) | ... |`
  # The ECC agents are external and cannot be counted from this filesystem, so that
  # half is a named constant — the one line to edit if ECC's roster changes, after
  # which every other file fails the consistency check loudly rather than drifting.
  ECC_AGENT_COUNT=5
  EXPECTED_AGENT_TOTAL=$((REPO_AGENT_COUNT + ECC_AGENT_COUNT))

  if [ -z "$REPO_AGENT_COUNT" ] || [ "$REPO_AGENT_COUNT" -eq 0 ] 2>/dev/null; then
    fail "REPO_AGENT_COUNT is empty or zero — Part 1 did not count the agents/ directory, so the agent-count cross-checks cannot run"
    DOC_ERRORS=$((DOC_ERRORS + 1))
  else
    README_AGENT_INREPO=$(sed -nE 's/^\| Agents \| ([0-9]+) total \(([0-9]+) in repo \+ ([0-9]+) ECC\).*/\2/p' "$README" | head -1)
    README_AGENT_TOTAL=$(sed -nE 's/^\| Agents \| ([0-9]+) total \(([0-9]+) in repo \+ ([0-9]+) ECC\).*/\1/p' "$README" | head -1)
    README_AGENT_ECC=$(sed -nE 's/^\| Agents \| ([0-9]+) total \(([0-9]+) in repo \+ ([0-9]+) ECC\).*/\3/p' "$README" | head -1)

    check_doc_count "in-repo agents" "README.md" "$README_AGENT_INREPO" "$REPO_AGENT_COUNT" "'| Agents | N total (M in repo + K ECC) |' in the stats table"
    check_doc_count "total agents"   "README.md" "$README_AGENT_TOTAL"  "$EXPECTED_AGENT_TOTAL" "'| Agents | N total (M in repo + K ECC) |' in the stats table"

    if [ -n "$README_AGENT_ECC" ] && [ "$README_AGENT_ECC" != "$ECC_AGENT_COUNT" ]; then
      fail "README says $README_AGENT_ECC ECC agents but verify.sh's ECC_AGENT_COUNT constant is $ECC_AGENT_COUNT — one of them is stale"
      DOC_ERRORS=$((DOC_ERRORS + 1))
    fi

    # Five further sites carry ONLY the total, in three spellings. A check on the
    # in-repo number alone would pass every one of them — which is how the stale 24
    # survived in all five.
    for _ad in README.md docs/concepts/claude-code.md docs/how-to/token-management.md; do
      [ -f "$REPO_ROOT/$_ad" ] || continue
      _av=$(grep -oE '[0-9]+ (specialised|specialized|specialist) agents' "$REPO_ROOT/$_ad" \
            | head -1 | grep -oE '^[0-9]+' || :)
      check_doc_count "total agents" "$_ad" "$_av" "$EXPECTED_AGENT_TOTAL" "'N specialised/specialized/specialist agents'"
    done
  fi

  # Commands. Pattern still matches today, but the FORM was the same fail-open one as
  # the agent check above, so it was one reformat away from going inert too.
  README_CMD_LINE=$(grep -o 'Commands | [0-9]*' "$README" | head -1 | grep -o '[0-9]*')
  check_doc_count "commands" "README.md" "$README_CMD_LINE" "$REPO_CMD_COUNT" "'Commands | N' in the stats table"

  # Check hooks count in README (e.g. "Hooks | 18 PreToolUse/PostToolUse + 1 standalone")
  README_HOOK_LINE=$(grep -o 'Hooks | [0-9]* PreToolUse' "$README" | head -1 | grep -o '[0-9]*')
  # Three-way: a MISSING count line is a failure too — otherwise reformatting
  # README silently disables this check (empty grep used to fall into "ok").
  if [ -z "$README_HOOK_LINE" ]; then
    fail "README hooks count line not found (expected 'Hooks | N PreToolUse...' in the stats table) — format changed? Update this check's grep pattern."
    DOC_ERRORS=$((DOC_ERRORS + 1))
  elif [ "$README_HOOK_LINE" != "$REPO_HOOK_COUNT" ]; then
    fail "README says $README_HOOK_LINE hooks but repo has $REPO_HOOK_COUNT (excludes pre-commit-check.sh)"
    DOC_ERRORS=$((DOC_ERRORS + 1))
  else
    ok "README hooks count matches repo ($REPO_HOOK_COUNT)"
  fi

  # Check docs count in README (e.g. "docs/  → 35 documentation files")
  README_DOC_LINE=$(grep -o '[0-9]* documentation files' "$README" | head -1 | grep -o '[0-9]*')
  # Three-way: missing count line = failure (see hooks check above for why).
  if [ -z "$README_DOC_LINE" ]; then
    fail "README docs count line not found (expected 'N documentation files') — format changed? Update this check's grep pattern."
    DOC_ERRORS=$((DOC_ERRORS + 1))
  elif [ "$README_DOC_LINE" != "$REPO_DOC_COUNT" ]; then
    fail "README says $README_DOC_LINE docs but repo has $REPO_DOC_COUNT"
    DOC_ERRORS=$((DOC_ERRORS + 1))
  else
    ok "README docs count matches repo ($REPO_DOC_COUNT)"
  fi

  # ---------------------------------------------------------------------------
  # Check skills counts (README + CLAUDE.md + the three docs that carry the total)
  #
  # ⛔ THIS CHECK DID NOT EXIST, AND THAT IS HOW A STALE TOTAL SHIPPED. ⛔
  # Part 1 computes REPO_SKILL_COUNT for the installed-skills check and Part 2 never
  # compared it to anything a human wrote. When skills/observed-work/ landed
  # (26 -> 27 in repo, 44 -> 45 with ECC's 18), four files kept the old numbers and a
  # PR REVIEWER found them, not this suite.
  #
  # ⛔ AND THE OBVIOUS VERSION OF THIS CHECK WOULD HAVE MISSED IT. ⛔
  # Verifying only the "N in repo" number passes three of those four files, because
  # they carry ONLY the TOTAL (45) — two of them carry nothing else. So the total is
  # verified as well, against in-repo + ECC.
  #
  # The ECC count is external to this repo and cannot be derived from the filesystem,
  # so it is a named constant. If it ever changes, this is the one line to edit; every
  # other file then fails the consistency check loudly, which is what we want.
  ECC_SKILL_COUNT=18
  EXPECTED_SKILL_TOTAL=$((REPO_SKILL_COUNT + ECC_SKILL_COUNT))

  # Part 1 sets REPO_SKILL_COUNT at top level, so it is in scope here. Guard anyway:
  # comparing against an empty or zero count would report every file as wrong for a
  # reason that has nothing to do with the files.
  if [ -z "$REPO_SKILL_COUNT" ] || [ "$REPO_SKILL_COUNT" -eq 0 ] 2>/dev/null; then
    fail "REPO_SKILL_COUNT is empty or zero — Part 1 did not count the skills/ directory, so the skill-count cross-checks cannot run"
    DOC_ERRORS=$((DOC_ERRORS + 1))
  else
    # Uses the shared check_doc_count helper defined at the top of this section.

    # README carries BOTH numbers: "| Skills | 48 total (30 in repo + 18 ECC) | ..."
    README_SKILL_TOTAL=$(sed -nE 's/^\| Skills \| ([0-9]+) total \(([0-9]+) in repo \+ ([0-9]+) ECC\).*/\1/p' "$README" | head -1)
    README_SKILL_INREPO=$(sed -nE 's/^\| Skills \| ([0-9]+) total \(([0-9]+) in repo \+ ([0-9]+) ECC\).*/\2/p' "$README" | head -1)
    README_SKILL_ECC=$(sed -nE 's/^\| Skills \| ([0-9]+) total \(([0-9]+) in repo \+ ([0-9]+) ECC\).*/\3/p' "$README" | head -1)

    check_doc_count "in-repo skills" "README.md" "$README_SKILL_INREPO" "$REPO_SKILL_COUNT" "'| Skills | N total (M in repo + K ECC) |' in the stats table"
    check_doc_count "total skills"   "README.md" "$README_SKILL_TOTAL"  "$EXPECTED_SKILL_TOTAL" "'| Skills | N total (M in repo + K ECC) |' in the stats table"

    # The ECC half is a constant, not a measurement — but if README disagrees with it,
    # one of the two is stale and the total above is untrustworthy either way.
    if [ -n "$README_SKILL_ECC" ] && [ "$README_SKILL_ECC" != "$ECC_SKILL_COUNT" ]; then
      fail "README says $README_SKILL_ECC ECC skills but verify.sh's ECC_SKILL_COUNT constant is $ECC_SKILL_COUNT — one of them is stale"
      DOC_ERRORS=$((DOC_ERRORS + 1))
    fi

    # CLAUDE.md states the in-repo count: "skills/  → 27 skills (copied to ...)"
    CLAUDE_SKILL_COUNT=$(sed -nE 's|^skills/[[:space:]]*.*[^0-9]([0-9]+) skills.*|\1|p' "$REPO_ROOT/CLAUDE.md" | head -1)
    check_doc_count "in-repo skills" "CLAUDE.md" "$CLAUDE_SKILL_COUNT" "$REPO_SKILL_COUNT" "'skills/ → N skills'"

    # These three carry the TOTAL, and are where the stale numbers actually hid.
    for _sd in docs/concepts/claude-code.md docs/concepts/skills.md docs/reference/skill-list.md; do
      [ -f "$REPO_ROOT/$_sd" ] || continue
      # The final grep legitimately returns 1 when the document has no count;
      # keep that data value empty so check_doc_count can report the missing
      # count instead of making extraction status control verification flow.
      _sv=$(grep -oE '[0-9]+ skills' "$REPO_ROOT/$_sd" | head -1 | grep -oE '[0-9]+' || :)
      check_doc_count "total skills" "$_sd" "$_sv" "$EXPECTED_SKILL_TOTAL" "'N skills'"
    done
  fi

  # Check for broken internal links
  BROKEN_LINKS=()
  while IFS= read -r link; do
    # Extract path from markdown link
    link_path=$(echo "$link" | sed 's|.*](\(.*\)).*|\1|' | sed 's|#.*||')
    [ -z "$link_path" ] && continue
    [[ "$link_path" == http* ]] && continue
    if [ ! -f "$REPO_ROOT/$link_path" ] && [ ! -d "$REPO_ROOT/$link_path" ]; then
      BROKEN_LINKS+=("$link_path")
    fi
  done < <(grep -oE '\[[^]]*\]\([^)]*\)' "$README" | grep -v 'http')

  if [ ${#BROKEN_LINKS[@]} -eq 0 ]; then
    ok "All README internal links valid"
  else
    for broken in "${BROKEN_LINKS[@]}"; do
      fail "Broken link in README: $broken"
      DOC_ERRORS=$((DOC_ERRORS + 1))
    done
  fi
fi

# ---------------------------------------------------------------------------
# Check: CLAUDE.md counts match actual files
# ---------------------------------------------------------------------------
CLAUDEMD="$REPO_ROOT/CLAUDE.md"

if [ -f "$CLAUDEMD" ]; then
  CLAUDE_CMD_LINE=$(grep -o 'Commands ([0-9]* total)' "$CLAUDEMD" | grep -o '[0-9]*')
  if [ -n "$CLAUDE_CMD_LINE" ] && [ "$CLAUDE_CMD_LINE" != "$REPO_CMD_COUNT" ]; then
    fail "CLAUDE.md says $CLAUDE_CMD_LINE commands but repo has $REPO_CMD_COUNT"
    DOC_ERRORS=$((DOC_ERRORS + 1))
  else
    ok "CLAUDE.md command count matches repo ($REPO_CMD_COUNT)"
  fi

  # Check docs count in CLAUDE.md (e.g. "docs/ → 35 documentation files")
  CLAUDE_DOC_LINE=$(grep -o '[0-9]* documentation files' "$CLAUDEMD" | head -1 | grep -o '[0-9]*')
  # Three-way: missing count line = failure (see README hooks check for why).
  if [ -z "$CLAUDE_DOC_LINE" ]; then
    fail "CLAUDE.md docs count line not found (expected 'N documentation files') — format changed? Update this check's grep pattern."
    DOC_ERRORS=$((DOC_ERRORS + 1))
  elif [ "$CLAUDE_DOC_LINE" != "$REPO_DOC_COUNT" ]; then
    fail "CLAUDE.md says $CLAUDE_DOC_LINE docs but repo has $REPO_DOC_COUNT"
    DOC_ERRORS=$((DOC_ERRORS + 1))
  else
    ok "CLAUDE.md docs count matches repo ($REPO_DOC_COUNT)"
  fi
fi

# ---------------------------------------------------------------------------
# Check: Commands reference agents/skills that exist
# ---------------------------------------------------------------------------
# Check explicit "**Agent:**" or "**Skill:**" references in command files
ECC_AGENTS="architect chief-of-staff planner tdd-guide code-reviewer security-reviewer database-reviewer e2e-runner refactor-cleaner doc-updater build-error-resolver harness-optimizer loop-operator"
MISSING_REFS=()

# Build list of known skill names from repo
KNOWN_SKILLS=""
for skill_dir in "$REPO_ROOT/skills/"/*/; do
  [ -d "$skill_dir" ] || continue
  KNOWN_SKILLS="$KNOWN_SKILLS $(basename "$skill_dir")"
done

for cmd_file in "$REPO_ROOT/commands/"*.md; do
  [ -f "$cmd_file" ] || continue
  cmd_name="$(basename "$cmd_file" .md)"

  # Check agent references (first backticked name per "Agent:" line)
  while IFS= read -r agent_ref; do
    [ -z "$agent_ref" ] && continue
    if [ -f "$REPO_ROOT/agents/$agent_ref.md" ]; then
      : # found in repo
    elif echo "$ECC_AGENTS" | grep -qw "$agent_ref"; then
      : # ECC plugin agent
    else
      MISSING_REFS+=("$cmd_name references agent '$agent_ref' which doesn't exist")
    fi
  done < <(grep -i '^\*\*Agent:\*\*.*`' "$cmd_file" | sed -n 's/^[^`]*`\([a-z][-a-z]*\)`.*/\1/p' | sort -u)

  # Check skill references (first backticked name per "Skill:" line)
  while IFS= read -r skill_ref; do
    [ -z "$skill_ref" ] && continue
    if echo "$KNOWN_SKILLS" | grep -qw "$skill_ref"; then
      : # found in repo
    else
      MISSING_REFS+=("$cmd_name references skill '$skill_ref' which doesn't exist")
    fi
  done < <(grep -i '^\*\*Skill:\*\*.*`' "$cmd_file" | sed -n 's/^[^`]*`\([a-z][-a-z]*\)`.*/\1/p' | sort -u)
done

if [ ${#MISSING_REFS[@]} -eq 0 ]; then
  ok "All command → agent/skill references valid"
else
  for ref in "${MISSING_REFS[@]}"; do
    warn "$ref"
  done
fi

# ---------------------------------------------------------------------------
# Check: Broken links across all docs
# ---------------------------------------------------------------------------
BROKEN_DOC_LINKS=()

for doc_file in "$REPO_ROOT/docs/"**/*.md "$REPO_ROOT/docs/"*.md; do
  [ -f "$doc_file" ] || continue
  doc_name="${doc_file#$REPO_ROOT/}"

  while IFS= read -r link; do
    link_path=$(echo "$link" | sed 's|.*](\(.*\)).*|\1|' | sed 's|#.*||')
    [ -z "$link_path" ] && continue
    [[ "$link_path" == http* ]] && continue

    # Resolve relative paths
    doc_dir=$(dirname "$doc_file")
    if [ ! -f "$doc_dir/$link_path" ] && [ ! -f "$REPO_ROOT/$link_path" ]; then
      BROKEN_DOC_LINKS+=("$doc_name → $link_path")
    fi
  done < <(grep -oE '\[[^]]*\]\([^)]*\)' "$doc_file" 2>/dev/null | grep -v 'http')
done

if [ ${#BROKEN_DOC_LINKS[@]} -eq 0 ]; then
  ok "All doc internal links valid"
else
  for broken in "${BROKEN_DOC_LINKS[@]}"; do
    warn "Broken doc link: $broken"
  done
fi

# ---------------------------------------------------------------------------
# Check: retired editor-assistant integration is absent
# ---------------------------------------------------------------------------
TEST_RETIRED_ASSISTANT_SCRIPT="$REPO_ROOT/scripts/test-removed-assistant.sh"
if [ ! -f "$TEST_RETIRED_ASSISTANT_SCRIPT" ]; then
  fail "retired editor-assistant integration test not found"
else
  RETIRED_ASSISTANT_OUTPUT=$(bash "$TEST_RETIRED_ASSISTANT_SCRIPT" 2>&1)
  RETIRED_ASSISTANT_RC=$?
  if [ "$RETIRED_ASSISTANT_RC" -eq 0 ]; then
    ok "retired editor-assistant integration is absent"
  else
    fail "retired editor-assistant integration test FAILED (exit $RETIRED_ASSISTANT_RC)"
    printf '%s\n' "$RETIRED_ASSISTANT_OUTPUT" | grep -E 'FAIL:' | head -10 | while IFS= read -r line; do
      info "$line"
    done
  fi
fi

# ---------------------------------------------------------------------------
# Check: sync-toolbox-lessons.sh exists and knowledge/toolbox-lessons.yml is valid
# WHY: These are Phase 1 self-improvement files. If either is missing, the
# knowledge sync won't run at install/update time and agents won't get lessons.
# ---------------------------------------------------------------------------
SYNC_LESSONS_SCRIPT="$REPO_ROOT/scripts/sync-toolbox-lessons.sh"
LESSONS_YML="$REPO_ROOT/knowledge/toolbox-lessons.yml"

if [ ! -f "$SYNC_LESSONS_SCRIPT" ]; then
  fail "sync-toolbox-lessons.sh not found at $SYNC_LESSONS_SCRIPT"
else
  ok "sync-toolbox-lessons.sh present"
fi

# Check that the installed copy of sync-toolbox-lessons.sh is present and
# executable in ~/.claude/scripts/. WHY: the repo copy proves the file exists
# in source control, but the installed copy is what actually runs at install/
# update time. A missing or non-executable installed copy means the lessons
# sync silently never runs, even though the repo file is fine.
INSTALLED_SYNC_LESSONS="$CLAUDE_HOME/scripts/sync-toolbox-lessons.sh"
if [ ! -f "$INSTALLED_SYNC_LESSONS" ]; then
  warn "sync-toolbox-lessons.sh is not installed at $INSTALLED_SYNC_LESSONS — run ./scripts/install.sh to install"
elif [ ! -x "$INSTALLED_SYNC_LESSONS" ]; then
  warn "sync-toolbox-lessons.sh is installed but not executable at $INSTALLED_SYNC_LESSONS — run: chmod +x $INSTALLED_SYNC_LESSONS"
else
  ok "sync-toolbox-lessons.sh installed and executable at $INSTALLED_SYNC_LESSONS"
fi

# ---------------------------------------------------------------------------
# Check: loop runtime scripts are installed and byte-identical
# ---------------------------------------------------------------------------
# These scripts are executed from arbitrary project repositories. A source copy
# alone is not enough: a missing or stale installed resolver silently restores
# the documented-but-unapplied loop bounds.
for loop_script in loop-config.sh loop-launch.sh; do
  LOOP_SOURCE="$REPO_ROOT/scripts/$loop_script"
  LOOP_INSTALLED="$CLAUDE_HOME/scripts/$loop_script"
  if [ ! -f "$LOOP_SOURCE" ]; then
    fail "$loop_script not found at $LOOP_SOURCE"
  elif [ ! -f "$LOOP_INSTALLED" ]; then
    fail "$loop_script is not installed at $LOOP_INSTALLED — run ./scripts/install.sh"
  elif ! cmp -s "$LOOP_SOURCE" "$LOOP_INSTALLED"; then
    fail "$loop_script at $LOOP_INSTALLED DIFFERS from the repo copy — the loop running on this machine is not using the reviewed runtime. Run ./scripts/install.sh."
  elif [ ! -x "$LOOP_INSTALLED" ]; then
    fail "$loop_script matches the repo copy but is not executable at $LOOP_INSTALLED — fix with: chmod +x $LOOP_INSTALLED"
  else
    ok "$loop_script installed and byte-identical"
  fi
done

# ---------------------------------------------------------------------------
# Check: installed PR-action safety hook matches the reviewed source
# ---------------------------------------------------------------------------
# This hook is the live merge boundary. A source-only green check is unsafe if
# ~/.claude/hooks/pr-action-safety.sh is stale, so drift is an error rather than
# an informational warning.
SOURCE_PR_ACTION_HOOK="$REPO_ROOT/hooks/pr-action-safety.sh"
INSTALLED_PR_ACTION_HOOK="$CLAUDE_HOME/hooks/pr-action-safety.sh"
if [ ! -f "$SOURCE_PR_ACTION_HOOK" ]; then
  fail "pr-action-safety.sh not found in the repository"
elif [ ! -f "$INSTALLED_PR_ACTION_HOOK" ]; then
  fail "pr-action-safety.sh is not installed at $INSTALLED_PR_ACTION_HOOK — run ./scripts/install.sh"
elif ! cmp -s "$SOURCE_PR_ACTION_HOOK" "$INSTALLED_PR_ACTION_HOOK"; then
  fail "pr-action-safety.sh at $INSTALLED_PR_ACTION_HOOK DIFFERS from the repo copy — the active merge gate is stale. Run ./scripts/install.sh."
elif [ ! -x "$INSTALLED_PR_ACTION_HOOK" ]; then
  fail "pr-action-safety.sh is not executable at $INSTALLED_PR_ACTION_HOOK"
else
  ok "pr-action-safety.sh installed, executable, and byte-identical"
fi

# ---------------------------------------------------------------------------
# Check: installed auto-poll helpers match the reviewed source.
# These are executed from arbitrary project repositories. A stale or missing
# installed copy silently disables the no-progress precheck/detector while the
# source-only tests remain green, so presence, executability, and byte identity
# are all required.
# ---------------------------------------------------------------------------
for loop_helper in review-pr-precheck.sh loop-progress-signature.sh; do
  HELPER_SOURCE="$REPO_ROOT/scripts/$loop_helper"
  HELPER_INSTALLED="$CLAUDE_HOME/scripts/$loop_helper"
  if [ ! -f "$HELPER_SOURCE" ]; then
    fail "$loop_helper not found in the repository"
  elif [ ! -f "$HELPER_INSTALLED" ]; then
    fail "$loop_helper is not installed at $HELPER_INSTALLED — run ./scripts/install.sh"
  elif ! cmp -s "$HELPER_SOURCE" "$HELPER_INSTALLED"; then
    fail "$loop_helper at $HELPER_INSTALLED DIFFERS from the repo copy — the active loop guard is stale. Run ./scripts/install.sh."
  elif [ ! -x "$HELPER_INSTALLED" ]; then
    fail "$loop_helper matches the repo copy but is not executable at $HELPER_INSTALLED"
  else
    ok "$loop_helper installed, executable, and byte-identical"
  fi
done

# ---------------------------------------------------------------------------
# Check: pr-postmerge-fold.sh exists in the repo and is installed + executable
# WHY: this is the shared post-merge fold (deviation snapshot + automated-review/Codex
# lessons fold) called by BOTH /merge-pr Step 2.5 AND /review-pr Step 0.5's
# MERGED fallback (automated-review finding, PR #127 — the fold has to run no matter
# how a toolbox PR merged: /merge-pr, the GitHub UI, or a bare `gh pr merge`).
# Same reasoning as the sync-toolbox-lessons.sh check above: the repo copy
# proves the file exists in source control, but the installed copy under
# $CLAUDE_HOME/scripts/ is the ONLY path either caller ever executes — a
# missing or non-executable installed copy means the fold silently no-ops in
# both callers, even though the repo file is fine.
# ---------------------------------------------------------------------------
POSTMERGE_FOLD_SCRIPT="$REPO_ROOT/scripts/pr-postmerge-fold.sh"
if [ ! -f "$POSTMERGE_FOLD_SCRIPT" ]; then
  fail "pr-postmerge-fold.sh not found at $POSTMERGE_FOLD_SCRIPT"
else
  ok "pr-postmerge-fold.sh present"
fi

INSTALLED_POSTMERGE_FOLD="$CLAUDE_HOME/scripts/pr-postmerge-fold.sh"
if [ ! -f "$INSTALLED_POSTMERGE_FOLD" ]; then
  warn "pr-postmerge-fold.sh is not installed at $INSTALLED_POSTMERGE_FOLD — run ./scripts/install.sh to install"
elif [ ! -x "$INSTALLED_POSTMERGE_FOLD" ]; then
  warn "pr-postmerge-fold.sh is installed but not executable at $INSTALLED_POSTMERGE_FOLD — run: chmod +x $INSTALLED_POSTMERGE_FOLD"
else
  ok "pr-postmerge-fold.sh installed and executable at $INSTALLED_POSTMERGE_FOLD"
fi

# ---------------------------------------------------------------------------
# Check: consume-deviations.sh exists in the repo and is installed + executable
# WHY: this is the deterministic half of the self-improvement loop (issue #140)
# — the surface pass, the archive rule, the CANONICAL DISMISSAL WRITE, and the
# lessons candidate filter. /review-pr Step 0.5 and Steps 7/7b execute the
# INSTALLED copy only: the command can fire while the shell's cwd is a
# different repo, so a repo-local path would be attacker-plantable. A missing
# installed copy is not silent — Step 0.5 warns and PRESERVES the snapshots —
# but the loop stops draining, so it is worth reporting here too.
# ---------------------------------------------------------------------------
CONSUME_DEV_SCRIPT="$REPO_ROOT/scripts/consume-deviations.sh"
if [ ! -f "$CONSUME_DEV_SCRIPT" ]; then
  fail "consume-deviations.sh not found at $CONSUME_DEV_SCRIPT"
else
  ok "consume-deviations.sh present"
fi

# ---------------------------------------------------------------------------
# ⛔ THE CONTENT COMPARISON IS THE POINT — THE PRESENCE CHECKS ARE NOT. ⛔
# This check shipped covering three conditions and missing the only one that
# matters:
#   repo copy missing            -> fail  exit 1
#   installed copy missing       -> warn  exit 0
#   installed, not executable    -> warn  exit 0
#   installed, executable, STALE -> NO BRANCH EXISTED -> ok, exit 0
# Falsified by planting a 3-line stub in place of the real script (1128 lines at
# the time of that run; 1659 now — the point is the size gap, not the number): "✅
# consume-deviations.sh installed and executable", "✅ All checks passed", exit 0.
# That is issue #137's exact failure mode — merged but inert, nothing says so —
# reproduced by the check added to prevent it. An inert detector is worse than no
# detector, because it converts "unknown" into a green tick.
#
# ⛔ DELIBERATE CONSEQUENCE — DO NOT SOFTEN THIS TO `warn`. ⛔ `fail` on mismatch
# means verify.sh FAILS on any branch that edits scripts/consume-deviations.sh
# until ./scripts/install.sh is re-run. That is intended and it is honest: while
# the two differ, the loop running on this machine is NOT the code under review,
# and every /review-pr run in that window exercises the installed copy. A `warn`
# restores the green tick this branch exists to remove, and TC-STL-62 asserts the
# ERROR COUNT rises by exactly one — which a `warn` does not do — so softening it
# reddens that test rather than passing quietly.
#
# `-x` is checked but deliberately reported as secondary: every call site in
# commands/review-pr.md invokes the script as `bash <path>`, which needs no
# execute bit, so executability is NOT a property any caller depends on.
# (Counted 5 at the time of writing — surface, lessons, dismiss, archive, defer.
# Deliberately phrased as "every" rather than a number: this comment said "four"
# until `defer` landed in this same round and nobody updated it, which is the
# stale-count class the commit before this one exists to fix. A property that
# holds for ALL call sites does not need a tally, and a tally is one more claim
# to keep true.) The
# previous "installed and executable" success string implied it was the thing
# being verified, while the one thing that mattered — content — was unchecked.
# ---------------------------------------------------------------------------
INSTALLED_CONSUME_DEV="$CLAUDE_HOME/scripts/consume-deviations.sh"
if [ ! -f "$INSTALLED_CONSUME_DEV" ]; then
  warn "consume-deviations.sh is not installed at $INSTALLED_CONSUME_DEV — run ./scripts/install.sh to install"
elif [ ! -f "$CONSUME_DEV_SCRIPT" ]; then
  # The repo copy is already reported as a `fail` above; without it there is
  # nothing to compare against, so say that rather than compare with /dev/null.
  warn "consume-deviations.sh is installed but the repo copy is missing, so the installed copy cannot be verified against it"
elif ! cmp -s "$CONSUME_DEV_SCRIPT" "$INSTALLED_CONSUME_DEV"; then
  fail "consume-deviations.sh at $INSTALLED_CONSUME_DEV DIFFERS from the repo copy — the self-improvement loop running on this machine is not the code in this checkout. Run ./scripts/install.sh to install the current version."
elif [ ! -x "$INSTALLED_CONSUME_DEV" ]; then
  warn "consume-deviations.sh matches the repo copy but is not executable at $INSTALLED_CONSUME_DEV — every caller invokes it as \`bash <path>\` so this is cosmetic; fix with: chmod +x $INSTALLED_CONSUME_DEV"
else
  ok "consume-deviations.sh installed at $INSTALLED_CONSUME_DEV and byte-identical to the repo copy"
fi

if [ ! -f "$LESSONS_YML" ]; then
  fail "knowledge/toolbox-lessons.yml not found at $LESSONS_YML"
else
  # Stronger than a substring grep: confirm schema_version is an integer, the
  # lessons: key is at column 0, and there are no tab characters (YAML forbids tabs for
  # indentation). A file that merely contains "schema_version:"/"lessons:" somewhere
  # (e.g. inside a comment or a lesson body) must NOT pass.
  if command -v python3 >/dev/null 2>&1; then
    if python3 - "$LESSONS_YML" <<'PYEOF' 2>/dev/null
import sys, re
try:
    text = open(sys.argv[1], encoding="utf-8").read()
except Exception:
    sys.exit(1)
# NOTE: no tab-indentation check here. Distinguishing an invalid tab in YAML
# indentation (e.g. "  \t- item") from a legitimate tab inside block-scalar
# content (e.g. a tab in a `body: |` line) is impossible with a line-by-line
# regex — it needs a real YAML parser that tracks block-scalar context, and the
# toolbox deliberately avoids a YAML dependency (python stdlib has none). Earlier
# regex attempts oscillated between false positives (rejecting valid block-scalar
# content) and false negatives (accepting nested tab indentation). This check is a
# schema SMOKE TEST, not a YAML linter: the lessons file is machine-generated by
# the lessons-pr synthesis step, and its real consumer (sync-toolbox-lessons.sh)
# parses it, so genuine corruption surfaces there. We validate only what a regex
# CAN reliably check: schema_version is an integer and the lessons key is present.
# Use [ ]* (space-only), NOT \s* — \s also matches newlines, making intent
# ambiguous. The trailing \r? tolerates CRLF checkouts (Windows): without it a \r
# before the line end would defeat the $ anchor and reject a valid file purely on
# line-ending style.
if not re.search(r"(?m)^schema_version:[ ]*\d+[ ]*\r?$", text):
    sys.exit(1)
# Matches `lessons:` alone (entries follow on indented lines) or `lessons: []`.
if not re.search(r"(?m)^lessons:[ ]*(\[[ ]*\])?[ ]*\r?$", text):
    sys.exit(1)
sys.exit(0)
PYEOF
    then
      ok "knowledge/toolbox-lessons.yml present and structurally valid (schema_version int + lessons key)"
    else
      fail "knowledge/toolbox-lessons.yml failed structural validation (schema_version must be an integer at col 0, lessons: key required at col 0)"
    fi
  elif grep -q "schema_version:" "$LESSONS_YML" && grep -q "lessons:" "$LESSONS_YML"; then
    ok "knowledge/toolbox-lessons.yml present (basic check — python3 unavailable for full validation)"
  else
    fail "knowledge/toolbox-lessons.yml missing schema_version or lessons keys"
  fi
fi

# ---------------------------------------------------------------------------
# Check: sync-toolbox-lessons.sh unit tests actually pass
# WHY: The sync script enforces invariants the merge path depends on (fast-tier
# cap, fail-soft on missing source, safe fallback that never emits an uncapped
# fast tier, sanitizer filename contract). A passing repo file is not enough —
# the tests are what prove the behavior. Run them here so a regression in the
# sync script is caught by `verify.sh` itself, not just by a manual test run.
# A nonzero exit from the test script is a verify FAILURE.
# ---------------------------------------------------------------------------
TEST_SYNC_LESSONS_SCRIPT="$REPO_ROOT/scripts/test-sync-toolbox-lessons.sh"
if [ ! -f "$TEST_SYNC_LESSONS_SCRIPT" ]; then
  fail "test-sync-toolbox-lessons.sh not found at $TEST_SYNC_LESSONS_SCRIPT"
else
  # Capture output + exit code without letting a test failure abort verify.sh.
  SYNC_TEST_OUTPUT=$(bash "$TEST_SYNC_LESSONS_SCRIPT" 2>&1)
  SYNC_TEST_RC=$?
  if [ $SYNC_TEST_RC -eq 0 ]; then
    ok "sync-toolbox-lessons.sh unit tests pass ($(printf '%s' "$SYNC_TEST_OUTPUT" | grep -c 'PASS:') checks)"
  else
    fail "sync-toolbox-lessons.sh unit tests FAILED (exit $SYNC_TEST_RC)"
    # Surface the failing lines so the developer sees what broke.
    printf '%s\n' "$SYNC_TEST_OUTPUT" | grep -E 'FAIL:|FAILED' | while IFS= read -r line; do
      info "$line"
    done
  fi
fi

# ---------------------------------------------------------------------------
# Check: the self-improvement backlog reporter passes its own unit tests
# WHY: the reporter below is the only thing standing between a silently stalled
# self-improvement loop and nobody noticing for six weeks. It has two opposite
# failure modes and both are silent: under-reporting (the original bug, back
# again) and crying wolf on a fresh install, because a warning that fires for
# everyone is a warning everyone learns to skip. Its suite pins both, including
# the `-s` vs `-f` trap (the real dismissed-deviations.log exists at 0 bytes, so
# presence proves nothing) and oldest-by-mtime vs oldest-by-filename. Same
# wiring pattern as the other suites: a nonzero exit is a verify FAILURE.
# ---------------------------------------------------------------------------
TEST_BACKLOG_SCRIPT="$REPO_ROOT/scripts/test-selfimprovement-backlog.sh"
if [ ! -f "$TEST_BACKLOG_SCRIPT" ]; then
  fail "test-selfimprovement-backlog.sh not found at $TEST_BACKLOG_SCRIPT"
else
  BACKLOG_TEST_OUTPUT=$(bash "$TEST_BACKLOG_SCRIPT" 2>&1)
  BACKLOG_TEST_RC=$?
  if [ $BACKLOG_TEST_RC -eq 0 ]; then
    ok "self-improvement backlog reporter unit tests pass ($(printf '%s' "$BACKLOG_TEST_OUTPUT" | grep -c 'PASS:') checks)"
    # ⛔ RELAY THE SKIPS — the suite's claim that a skip is "visible" is only true
    # if its CALLER says so. ⛔ Two cases in that suite establish their premise
    # with `chmod 000`, which root cannot do, so they SKIP under root. This branch
    # counted `PASS:` lines only, so a root run printed "15 checks" instead of 17
    # with nothing saying why — the two permission tests vanished silently at the
    # one place a human reads the result. A test that quietly stops running is
    # indistinguishable from one that never existed, which is the exact
    # invisible-gap failure the suite under test exists to end.
    #
    # `< <(...)` and NOT a pipe: `warn` increments the global WARNINGS counter, and
    # a pipe would run this loop in a subshell and discard every increment — the
    # same subshell trap this file fixes seventy lines below. (The FAIL relay in
    # the else branch uses a pipe and is harmless only because `info` counts
    # nothing; do not copy it here.)
    while IFS= read -r skipline; do
      warn "backlog reporter test SKIPPED — ${skipline#*SKIP: }"
    done < <(printf '%s\n' "$BACKLOG_TEST_OUTPUT" | grep 'SKIP:' || true)
  else
    fail "self-improvement backlog reporter unit tests FAILED (exit $BACKLOG_TEST_RC)"
    printf '%s\n' "$BACKLOG_TEST_OUTPUT" | grep -E 'FAIL:|FAILED' | while IFS= read -r line; do
      info "$line"
    done
  fi
fi

# ---------------------------------------------------------------------------
# Check: the self-improvement backlog is visible (deviations AND lessons)
# WHY: both capture->fold->surface pipelines end in a HUMAN-GATED step, and a
# human-gated step that nothing surfaces will simply not happen. Neither did.
# 69 lessons findings across 12 PRs sat unread in ~/.claude/pending-lessons-*.jsonl
# from 2026-07-03 to 2026-07-29 while knowledge/toolbox-lessons.yml stayed
# `lessons: []`. Then 75 deviation records across 6 pending-deviations-*.log
# snapshots sat unread from 2026-07-09 to 2026-08-21 while
# dismissed-deviations.log stayed at 0 bytes. Nothing failed in either case —
# the loops just never reached their last stage, and no output anywhere said so.
#
# This is INFORMATIONAL by design and must never fail the build: a backlog means
# a human has not triaged yet, which is not a defect. It only has to be LOUD.
# The threshold is deliberately low; the failure mode being prevented is silence,
# not volume.
#
# ⛔ Consume the helper via PROCESS SUBSTITUTION, never a pipe. ⛔
# `warn()` increments WARNINGS, and a pipe runs the loop body in a SUBSHELL, so
# every increment is discarded when it exits. The summary at the bottom of this
# script would then downgrade from "N warning(s)" to "All checks passed" — the
# loud signal getting quietly dropped, which is the exact failure class this
# whole check exists to prevent.
#
# The helper owns the logic (so it can be unit-tested against a temp dir without
# recursing through verify.sh) and this loop owns presentation. It is passed
# "$HOME/.claude" explicitly rather than $CLAUDE_HOME: the WRITER
# (scripts/pr-postmerge-fold.sh) writes literally there, while CLAUDE_HOME
# resolves to APPDATA/Claude on Windows, and reading a different directory than
# the writer writes to is how a backlog check reports zero forever.
# ---------------------------------------------------------------------------
SELFIMPROVEMENT_BACKLOG_SCRIPT="$REPO_ROOT/scripts/selfimprovement-backlog.sh"
if [ ! -f "$SELFIMPROVEMENT_BACKLOG_SCRIPT" ]; then
  fail "selfimprovement-backlog.sh not found at $SELFIMPROVEMENT_BACKLOG_SCRIPT"
else
  # ⛔ THE PROCESS SUBSTITUTION IS LOAD-BEARING — DO NOT TURN IT INTO A PIPE. ⛔
  # `warn()` increments the global WARNINGS counter that the summary reads. A
  # pipe would run this loop in a subshell, so every increment would be discarded
  # and a real backlog would downgrade the summary from "N warning(s)" to "All
  # checks passed". Proven directly: pipe form → WARNINGS=0, this form →
  # WARNINGS=2 on the same state. The loud signal being quietly dropped is the
  # precise failure class this check exists to prevent.
  #
  # ⛔ AND THE HELPER'S EXIT STATUS IS NOT OPTIONAL. ⛔ Because the substitution
  # sends stderr to /dev/null, a helper that cannot execute at all (deleted after
  # the -f test, a bad interpreter, a syntax error, exec failure under resource
  # pressure) produced NO output and NO complaint — verify.sh then reported
  # nothing about the backlog, which reads exactly like "no backlog". That is the
  # silent stall this check was added to detect, recreated inside the detector.
  # `$?` cannot be read after the loop (process substitution does not set it), so
  # the helper's status is written to a temp file by the substituted command
  # itself and read back afterwards. `SIB_LINES` is tracked alongside it because
  # the two failure modes are different: a nonzero exit is a broken helper, zero
  # output from a clean exit is a helper that has stopped reporting. Both must be
  # loud, and neither may fail the run — this is a reporter, not a gate.
  # `mktemp` can fail (full or unwritable TMPDIR). Unguarded, SIB_RC_FILE was
  # empty, `printf > ""` failed with its error escaping the substitution's
  # 2>/dev/null (which covers only the helper), and the empty SIB_RC then reported
  # "did not report an exit status" — a true statement attributing the wrong
  # cause. Name the real cause instead, and never gate on it.
  SIB_RC_FILE=$(mktemp 2>/dev/null) || SIB_RC_FILE=""
  if [ -z "$SIB_RC_FILE" ]; then
    warn "could not create a temp file to capture the backlog reporter's exit status (mktemp failed) — its output is still relayed below, but a failure part-way through it will not be detected"
  fi
  SIB_LINES=0
  while IFS= read -r line; do
    SIB_LINES=$((SIB_LINES + 1))
    case "$line" in
      "WARN: "*) warn "${line#WARN: }" ;;
      "INFO: "*) info "${line#INFO: }" ;;
      "OK: "*)   ok   "${line#OK: }" ;;
      "")        SIB_LINES=$((SIB_LINES - 1)) ;;
      # Unrecognised prefix: surface it rather than swallow it. Never fail on it
      # — the helper is a reporter and this caller must not turn it into a gate.
      *)         info "$line" ;;
    esac
  # ⛔ CAPTURE `$?` INTO A VARIABLE ON ITS OWN LINE. ⛔ Written as
  # `[ -n "$SIB_RC_FILE" ] && printf '%s' "$?"`, the `$?` is the exit status of
  # the `[ -n ... ]` TEST — always 0 on the branch that writes — so the helper's
  # real status was silently replaced by success. Caught by TC-SIB-18's sibling
  # TC-SIB-17 leg 5 (a reporter that prints a line and then fails), which is the
  # only leg that inspects the status rather than the output.
  done < <(bash "$SELFIMPROVEMENT_BACKLOG_SCRIPT" "$HOME/.claude" "$REPO_ROOT" 2>/dev/null
           _sib_rc=$?
           [ -n "$SIB_RC_FILE" ] && printf '%s' "$_sib_rc" > "$SIB_RC_FILE")
  SIB_RC=""
  [ -n "$SIB_RC_FILE" ] && SIB_RC=$(cat "$SIB_RC_FILE" 2>/dev/null)
  [ -n "$SIB_RC_FILE" ] && rm -f "$SIB_RC_FILE"
  # An unreadable/empty status file means the substituted command did not even
  # reach its `printf` — treat that as a failure rather than as success.
  if [ -z "$SIB_RC_FILE" ]; then
    # Already reported above by name; do not warn twice for one cause.
    :
  elif [ -z "$SIB_RC" ]; then
    warn "self-improvement backlog reporter did not report an exit status — the backlog state is UNKNOWN, not empty (scripts/selfimprovement-backlog.sh)"
  elif [ "$SIB_RC" -ne 0 ]; then
    warn "self-improvement backlog reporter exited $SIB_RC — the backlog state is UNKNOWN, not empty. Run: bash scripts/selfimprovement-backlog.sh \"\$HOME/.claude\" ."
  elif [ "$SIB_LINES" -eq 0 ]; then
    warn "self-improvement backlog reporter produced no output — the backlog state is UNKNOWN, not empty. Run: bash scripts/selfimprovement-backlog.sh \"\$HOME/.claude\" ."
  fi
fi

# ---------------------------------------------------------------------------
# Check: the tier-drift gate's falsifiability harness actually passes
# WHY: check-agent-tier-drift.py is a DETECTOR, and the only failure that matters
# for a detector is silence. Confirming it exits 0 on a clean tree proves nothing
# — a gate that matches nothing at all also exits 0. This repo has already shipped
# one inert detector (TIER_GLOSS matched no input while looking complete) and two
# consecutive "fixes" that each opened a new false negative; every one was caught
# by re-introducing the shape, never by reading the code. The harness injects a
# must-fail line per detector class into real repo files and asserts exit 1, then
# restores and asserts exit 0. Running it here means a future edit that quietly
# guts a detector fails verify.sh instead of passing it.
#
# The harness also carries strict-xfail "known gap" cases for the residual false
# negatives the gate documents but does not yet catch. Those PASS while the gate is
# still blind, so the count is surfaced on the green path below — a blind spot that
# only shows up in output nobody reads on a successful run is not documented, it is
# hidden, and that is the exact failure mode this whole check exists to prevent.
# ---------------------------------------------------------------------------
TEST_TIER_DRIFT_SCRIPT="$REPO_ROOT/scripts/test-check-agent-tier-drift.sh"
if [ ! -f "$TEST_TIER_DRIFT_SCRIPT" ]; then
  fail "test-check-agent-tier-drift.sh not found at $TEST_TIER_DRIFT_SCRIPT"
else
  # Capture output + exit code without letting a test failure abort verify.sh.
  TIER_TEST_OUTPUT=$(bash "$TEST_TIER_DRIFT_SCRIPT" 2>&1)
  TIER_TEST_RC=$?
  if [ $TIER_TEST_RC -eq 0 ]; then
    TIER_TEST_CHECKS=$(printf '%s' "$TIER_TEST_OUTPUT" | grep -c '✅')
    TIER_TEST_GAPS=$(printf '%s' "$TIER_TEST_OUTPUT" | grep -c 'KNOWN GAP still blind')
    # Coverage FLOORS — two of them, because one is not enough.
    #
    # A passing suite says nothing about how much it still covers: delete a case and
    # the suite happily reports one fewer check, all green. Same argument as pinning
    # counts in rules/cross-tool-sync.md.
    #
    # The ✅ floor alone left the strict-xfail cases unprotected, which handed anyone
    # hitting a GAP CLOSED failure an uncaught escape route: delete the gap case.
    # Deleting all four reported a green "26/26, 0 gaps" and verify.sh passed it.
    # So the TOTAL is floored too, and that total is deliberately invariant under
    # promotion — promoting a gap moves it ⚠️ -> ✅ and leaves the sum unchanged,
    # while deleting either kind drops it.
    #
    # Bump BOTH when cases are added; if either trips, a case was deleted, not fixed.
    TIER_TEST_FLOOR=28
    TIER_TEST_CASE_FLOOR=32
    TIER_TEST_CASES=$((TIER_TEST_CHECKS + TIER_TEST_GAPS))
    if [ "$TIER_TEST_CHECKS" -lt "$TIER_TEST_FLOOR" ]; then
      fail "tier-drift harness lost coverage: $TIER_TEST_CHECKS checks, expected >= $TIER_TEST_FLOOR — was a case deleted?"
    elif [ "$TIER_TEST_CASES" -lt "$TIER_TEST_CASE_FLOOR" ]; then
      fail "tier-drift harness lost cases: $TIER_TEST_CASES total (checks+gaps), expected >= $TIER_TEST_CASE_FLOOR — was a known-gap case deleted?"
    elif [ "$TIER_TEST_GAPS" -gt 0 ]; then
      ok "tier-drift gate falsifiability tests pass ($TIER_TEST_CHECKS checks, $TIER_TEST_GAPS known gap(s) still blind)"
    else
      ok "tier-drift gate falsifiability tests pass ($TIER_TEST_CHECKS checks)"
    fi
  else
    fail "tier-drift gate falsifiability tests FAILED (exit $TIER_TEST_RC) — a detector may be inert"
    printf '%s\n' "$TIER_TEST_OUTPUT" | grep -E '❌' | while IFS= read -r line; do
      info "$line"
    done
  fi
fi

# ---------------------------------------------------------------------------
# Check: merge-gate dedupe transform unit tests actually pass
# WHY: The statusCheckRollup dedupe transform (shared by hooks/pr-action-safety.sh,
# commands/review-pr.md Step 5.5, and Step 5.4) decides whether a PR is safe to
# merge. A regression here either lets a failing check slip through
# (security gap) or makes a good PR permanently un-mergeable (PR #99 class of
# bug). Run the pure-jq fixture tests here so a future edit to the transform is
# caught by `verify.sh` itself, not just by a manual test run. A nonzero exit
# from the test script is a verify FAILURE.
# ---------------------------------------------------------------------------
TEST_MERGE_GATE_SCRIPT="$REPO_ROOT/scripts/test-merge-gate-dedupe.sh"
if [ ! -f "$TEST_MERGE_GATE_SCRIPT" ]; then
  fail "test-merge-gate-dedupe.sh not found at $TEST_MERGE_GATE_SCRIPT"
else
  MERGE_GATE_TEST_OUTPUT=$(bash "$TEST_MERGE_GATE_SCRIPT" 2>&1)
  MERGE_GATE_TEST_RC=$?
  if [ $MERGE_GATE_TEST_RC -eq 0 ]; then
    ok "merge-gate dedupe unit tests pass ($(printf '%s' "$MERGE_GATE_TEST_OUTPUT" | grep -c 'PASS:') checks)"
  else
    fail "merge-gate dedupe unit tests FAILED (exit $MERGE_GATE_TEST_RC)"
    printf '%s\n' "$MERGE_GATE_TEST_OUTPUT" | grep -E 'FAIL:|FAILED' | while IFS= read -r line; do
      info "$line"
    done
  fi
fi

# ---------------------------------------------------------------------------
# Check: review-pr precheck decision logic actually passes its unit tests.
# The precheck decides whether an auto-poll cron fire runs the full /review-pr
# pipeline — a regression here either wastes compute (fail-open too often) or
# starves comment handling / automated-review recovery (skip when work is pending).
# Same wiring pattern as the two suites above.
# ---------------------------------------------------------------------------
TEST_PRECHECK_SCRIPT="$REPO_ROOT/scripts/test-review-pr-precheck.sh"
if [ ! -f "$TEST_PRECHECK_SCRIPT" ]; then
  fail "test-review-pr-precheck.sh not found at $TEST_PRECHECK_SCRIPT"
else
  PRECHECK_TEST_OUTPUT=$(bash "$TEST_PRECHECK_SCRIPT" 2>&1)
  PRECHECK_TEST_RC=$?
  if [ $PRECHECK_TEST_RC -eq 0 ]; then
    ok "review-pr precheck unit tests pass ($(printf '%s' "$PRECHECK_TEST_OUTPUT" | grep -c 'PASS:') checks)"
  else
    fail "review-pr precheck unit tests FAILED (exit $PRECHECK_TEST_RC)"
    printf '%s\n' "$PRECHECK_TEST_OUTPUT" | grep -E 'FAIL:|FAILED' | while IFS= read -r line; do
      info "$line"
    done
  fi
fi

# ---------------------------------------------------------------------------
# Check: codex-exec-with-fallback retry contract actually passes its unit tests.
# WHY: The codex-review gate pins GPT-5.6 Terra and retries once unpinned ONLY
# on model-specific errors — spend-cap/network/timeout must take the outage
# path unretried. A regression here either bricks the gate on a model rename
# (missed retry) or double-spends quota on a capped workspace (wrong retry).
# The Terra pre-PR review of PR #124 flagged this contract as mechanically
# testable — these fake-codex fixture tests are that proof. Same wiring
# pattern as the three suites above.
# ---------------------------------------------------------------------------
TEST_CODEX_FALLBACK_SCRIPT="$REPO_ROOT/scripts/test-codex-exec-with-fallback.sh"
if [ ! -f "$TEST_CODEX_FALLBACK_SCRIPT" ]; then
  fail "test-codex-exec-with-fallback.sh not found at $TEST_CODEX_FALLBACK_SCRIPT"
else
  CODEX_FALLBACK_TEST_OUTPUT=$(bash "$TEST_CODEX_FALLBACK_SCRIPT" 2>&1)
  CODEX_FALLBACK_TEST_RC=$?
  if [ $CODEX_FALLBACK_TEST_RC -eq 0 ]; then
    ok "codex-exec-with-fallback unit tests pass ($(printf '%s' "$CODEX_FALLBACK_TEST_OUTPUT" | grep -c 'PASS:') checks)"
  else
    fail "codex-exec-with-fallback unit tests FAILED (exit $CODEX_FALLBACK_TEST_RC)"
    printf '%s\n' "$CODEX_FALLBACK_TEST_OUTPUT" | grep -E 'FAIL:|FAILED' | while IFS= read -r line; do
      info "$line"
    done
  fi
fi

# ---------------------------------------------------------------------------
# Check: the no-progress loop guard actually passes its unit tests.
# WHY: scripts/loop-progress-signature.sh is guard 2 of the three loop guards
# (the `loop-design` skill). Its two claims are opposites and both are easy to
# break: churn (timestamps, paths, durations, ids) must NOT read as progress, and
# a genuinely different failure MUST. Over-normalise and the guard stops a loop
# that was working; under-normalise and it never fires and the turn cap becomes
# the only bound. Same wiring pattern as the suites above.
# ---------------------------------------------------------------------------
TEST_LOOP_PROGRESS_SCRIPT="$REPO_ROOT/scripts/test-loop-progress-signature.sh"
if [ ! -f "$TEST_LOOP_PROGRESS_SCRIPT" ]; then
  fail "test-loop-progress-signature.sh not found at $TEST_LOOP_PROGRESS_SCRIPT"
else
  LOOP_PROGRESS_TEST_OUTPUT=$(bash "$TEST_LOOP_PROGRESS_SCRIPT" 2>&1)
  LOOP_PROGRESS_TEST_RC=$?
  if [ $LOOP_PROGRESS_TEST_RC -eq 0 ]; then
    ok "loop-progress-signature unit tests pass ($(printf '%s' "$LOOP_PROGRESS_TEST_OUTPUT" | grep -c 'PASS:') checks)"
  else
    fail "loop-progress-signature unit tests FAILED (exit $LOOP_PROGRESS_TEST_RC)"
    printf '%s\n' "$LOOP_PROGRESS_TEST_OUTPUT" | grep -E 'FAIL:|FAILED' | while IFS= read -r line; do
      info "$line"
    done
  fi
fi

# Check the durable GoalRun runtime and its offline contract tests.
TEST_GOAL_LOOP_SCRIPT="$REPO_ROOT/scripts/test_goal_loop_runtime.py"
if [ ! -f "$TEST_GOAL_LOOP_SCRIPT" ]; then
  fail "test_goal_loop_runtime.py not found at $TEST_GOAL_LOOP_SCRIPT"
else
  GOAL_LOOP_TEST_OUTPUT=$(python3 "$TEST_GOAL_LOOP_SCRIPT" 2>&1)
  GOAL_LOOP_TEST_RC=$?
  if [ $GOAL_LOOP_TEST_RC -eq 0 ]; then
    ok "goal-loop runtime unit tests pass ($(printf '%s' "$GOAL_LOOP_TEST_OUTPUT" | grep -c '^Ran ' || true) suite)"
  else
    fail "goal-loop runtime unit tests FAILED (exit $GOAL_LOOP_TEST_RC)"
    printf '%s\n' "$GOAL_LOOP_TEST_OUTPUT" | grep -E 'FAIL:|ERROR:|FAILED' | while IFS= read -r line; do
      info "$line"
    done
  fi
fi

# Check the Domain Knowledge advisory boundary. This is intentionally
# static/offline: verification must prove no runtime activation surface ships
# and must never require or modify the upstream service or knowledge store.
TEST_DOMAIN_KNOWLEDGE_SCRIPT="$REPO_ROOT/scripts/test-property-domain-advisory.sh"
if [ ! -f "$TEST_DOMAIN_KNOWLEDGE_SCRIPT" ]; then
  fail "test-property-domain-advisory.sh not found at $TEST_DOMAIN_KNOWLEDGE_SCRIPT"
else
  DOMAIN_KNOWLEDGE_TEST_OUTPUT=$(bash "$TEST_DOMAIN_KNOWLEDGE_SCRIPT" 2>&1)
  DOMAIN_KNOWLEDGE_TEST_RC=$?
  DOMAIN_KNOWLEDGE_EXPECTED_CHECKS=48
  DOMAIN_KNOWLEDGE_PASS_COUNT=$(printf '%s\n' "$DOMAIN_KNOWLEDGE_TEST_OUTPUT" | grep -c '^PASS:' || true)
  DOMAIN_KNOWLEDGE_SENTINEL="All ${DOMAIN_KNOWLEDGE_EXPECTED_CHECKS} Domain Knowledge advisory boundary checks passed."
  if [ "$DOMAIN_KNOWLEDGE_TEST_RC" -eq 0 ] \
    && [ "$DOMAIN_KNOWLEDGE_PASS_COUNT" -eq "$DOMAIN_KNOWLEDGE_EXPECTED_CHECKS" ] \
    && printf '%s\n' "$DOMAIN_KNOWLEDGE_TEST_OUTPUT" | grep -Fqx -- "$DOMAIN_KNOWLEDGE_SENTINEL"; then
    ok "domain knowledge advisory boundary tests pass (${DOMAIN_KNOWLEDGE_PASS_COUNT} checks)"
  else
    fail "domain knowledge advisory boundary tests FAILED (exit $DOMAIN_KNOWLEDGE_TEST_RC, ${DOMAIN_KNOWLEDGE_PASS_COUNT}/${DOMAIN_KNOWLEDGE_EXPECTED_CHECKS} PASS lines, terminal sentinel required)"
    printf '%s\n' "$DOMAIN_KNOWLEDGE_TEST_OUTPUT" | grep -E 'FAIL:|failed\.' | while IFS= read -r line; do
      info "$line"
    done
  fi
fi

# ---------------------------------------------------------------------------
# Loop runtime resolver and launcher tests
# ---------------------------------------------------------------------------
for loop_test in test-loop-config.sh test-loop-launch.sh test-pr-action-gh-resolver.sh test-provider-neutral-pr-poll.sh test-provider-hook-sync.sh test-loop-blocked-scenarios.sh test-register-pr-poll.sh test-install-help.sh test-verify-progress.sh test-jira-phase-resolver.sh test-jira-comment-policy.sh test-provider-neutral-docs.sh; do
  LOOP_TEST="$REPO_ROOT/scripts/$loop_test"
  if [ ! -f "$LOOP_TEST" ]; then
    fail "$loop_test not found at $LOOP_TEST"
  else
    LOOP_TEST_OUTPUT=$(bash "$LOOP_TEST" 2>&1)
    LOOP_TEST_RC=$?
    if [ "$LOOP_TEST_RC" -eq 0 ]; then
      ok "$loop_test pass ($(printf '%s' "$LOOP_TEST_OUTPUT" | grep -c 'PASS:') checks)"
    else
      fail "$loop_test FAILED (exit $LOOP_TEST_RC)"
      printf '%s\n' "$LOOP_TEST_OUTPUT" | grep -E 'FAIL:|failed' | while IFS= read -r line; do
        info "$line"
      done
    fi
  fi
done

# Check: the observed-work sensor actually passes its acceptance tests.
# WHY: scripts/observe.sh is the SENSOR behind the `observed-work` skill, and it
# exists because two previous observers failed structurally — one was a model
# that FABRICATED its measurements, the other an unbounded wait that ran eleven
# hours. Its two claims are therefore "a false claim cannot survive" and "no wait
# is unbounded", and each is easy to break silently: delete one MISMATCH branch
# and a fabricated progress report sails through; drop one deadline branch and
# the eleven-hour bug is back with nothing to notice it.
#
# ⛔ THIS SUITE TAKES ~11.5 MINUTES OF REAL WALL CLOCK, ON PURPOSE. ⛔ (Measured:
# 684s on a clean full run. The header used to say ~4 minutes; that was stale, and
# a bound derived from it would have failed a healthy run.) Several of its
# tests (T1 silence, T4 the literal eleven-hour predicate, T11 the ~11.5-day
# tick, T19 the per-probe bound) assert behaviour over ELAPSED TIME, so they let
# a real clock run — mocking it would assert the arithmetic and not the
# behaviour, and mis-paced self-timing is exactly what the fabricating monitor
# got wrong. T1, T4 and T11 run concurrently, so those three cost one wait rather
# than three. Same wiring pattern as the suites above.
# ---------------------------------------------------------------------------
TEST_OBSERVE_SCRIPT="$REPO_ROOT/scripts/test-observe.sh"
if [ ! -f "$TEST_OBSERVE_SCRIPT" ]; then
  fail "test-observe.sh not found at $TEST_OBSERVE_SCRIPT"
else
  # ⛔ BOUNDED, BECAUSE THE REGRESSION THIS SUITE CATCHES IS AN UNBOUNDED WAIT. ⛔
  #
  # ⛔ AND THE NUMBER COMES FROM A MEASUREMENT, NOT FROM THE DOCS. ⛔ The first
  # version of this bound was 600s, derived from the "~4 minutes" the suite's own
  # header claimed. TIMED on a clean full run: 684s. A bound taken from the stale
  # claim would therefore have failed a HEALTHY run — a false "the suite hung"
  # alarm, which is the same class of wrong answer as no bound at all, just in the
  # other direction. 1800s is ~2.6x the measured time: enough headroom for a
  # loaded machine or a slow disk, and still bounded at half an hour rather than
  # the eleven hours the incident behind this suite actually ran.
  OBSERVE_TEST_LIMIT_S=1800
  info "Running observe.sh acceptance tests (~11.5 min measured — several tests wait on a real clock; bounded at ${OBSERVE_TEST_LIMIT_S}s)"
  RBC_PROGRESS_LABEL="observe.sh acceptance tests" \
    run_bounded_capture "$OBSERVE_TEST_LIMIT_S" bash "$TEST_OBSERVE_SCRIPT"
  OBSERVE_TEST_OUTPUT="$RBC_OUT"
  OBSERVE_TEST_RC="$RBC_RC"
  if [ "$RBC_TIMED_OUT" -eq 1 ]; then
    # A DISTINCT outcome from a red test, on purpose: "the suite hung" and "a test
    # failed" have different fixes, and reporting a hang as a failure would send
    # the reader looking for a broken assertion that does not exist.
    fail "observe.sh acceptance tests EXCEEDED THEIR BOUND — no result after ${OBSERVE_TEST_LIMIT_S}s, so the suite was killed"
    info "This is NOT a failing assertion. A suite that does not finish means a wait somewhere lost its bound —"
    info "the exact regression these tests exist to catch. Run: bash $TEST_OBSERVE_SCRIPT"
    printf '%s\n' "$OBSERVE_TEST_OUTPUT" | tail -5 | while IFS= read -r line; do
      info "last output: $line"
    done
  elif [ "$OBSERVE_TEST_RC" -eq 0 ]; then
    ok "observe.sh acceptance tests pass ($(printf '%s' "$OBSERVE_TEST_OUTPUT" | grep -c 'PASS:') checks)"
  else
    fail "observe.sh acceptance tests FAILED (exit $OBSERVE_TEST_RC)"
    printf '%s\n' "$OBSERVE_TEST_OUTPUT" | grep -E 'FAIL:|FAILED' | while IFS= read -r line; do
      info "$line"
    done
  fi
fi

# ---------------------------------------------------------------------------
# Check: the installer's utility-script copy blocks survive a failing chmod.
# WHY: install.sh runs under `set -euo pipefail`, so an unchecked `chmod` in a
# `then` branch ABORTS the whole installer at that line — no warning, no remedy,
# and every later step silently skipped. Two blocks additionally discarded their
# result with `|| true` and printed an unconditional success line. The suite
# extracts the shipped block verbatim and also statically checks the SIBLINGS,
# which is where this defect class in this repo actually lives.
# Fast (no network, no real install) — bounded anyway, for the same reason as the
# suite above: a check that can hang is not a check.
# ---------------------------------------------------------------------------
TEST_INSTALL_COPY_SCRIPT="$REPO_ROOT/scripts/test-install-script-copy.sh"
if [ ! -f "$TEST_INSTALL_COPY_SCRIPT" ]; then
  fail "test-install-script-copy.sh not found at $TEST_INSTALL_COPY_SCRIPT"
else
  INSTALL_COPY_LIMIT_S=120
  RBC_PROGRESS_LABEL="install.sh utility-script copy tests" \
    run_bounded_capture "$INSTALL_COPY_LIMIT_S" bash "$TEST_INSTALL_COPY_SCRIPT"
  INSTALL_COPY_OUTPUT="$RBC_OUT"
  INSTALL_COPY_RC="$RBC_RC"
  if [ "$RBC_TIMED_OUT" -eq 1 ]; then
    fail "install.sh copy-block tests EXCEEDED THEIR BOUND — no result after ${INSTALL_COPY_LIMIT_S}s"
  elif [ "$INSTALL_COPY_RC" -eq 0 ]; then
    ok "install.sh utility-script copy blocks pass ($(printf '%s' "$INSTALL_COPY_OUTPUT" | grep -c 'PASS:') checks)"
  else
    fail "install.sh copy-block tests FAILED (exit $INSTALL_COPY_RC)"
    printf '%s\n' "$INSTALL_COPY_OUTPUT" | grep -E 'FAIL:' | while IFS= read -r line; do
      info "$line"
    done
  fi
fi

# ---------------------------------------------------------------------------
# Agent tier drift — every doc mention of an agent must agree with that agent's
# frontmatter. The toolbox names tiers inline in ~170 places, so one frontmatter
# change silently invalidates all of them; and the stale copies in
# agents/chief-of-staff.md and skills/agent-orchestration/SKILL.md are read at
# the SPAWN DECISION POINT, where a wrong tier becomes a silent downgrade.
# ---------------------------------------------------------------------------
TIER_DRIFT_SCRIPT="$REPO_ROOT/scripts/check-agent-tier-drift.py"
if [ ! -f "$TIER_DRIFT_SCRIPT" ]; then
  fail "check-agent-tier-drift.py not found at $TIER_DRIFT_SCRIPT"
else
  TIER_DRIFT_OUTPUT=$(python3 "$TIER_DRIFT_SCRIPT" 2>&1)
  TIER_DRIFT_RC=$?
  if [ $TIER_DRIFT_RC -eq 0 ]; then
    ok "No agent tier drift — doc mentions agree with agent frontmatter"
  elif [ $TIER_DRIFT_RC -gt 1 ]; then
    # rc>1 means the checker itself failed (missing python3, syntax error) — NOT
    # that the docs are clean. Say so, rather than reporting "0 stale references".
    fail "Agent tier drift check could not run (exit $TIER_DRIFT_RC) — treating as unverified"
    printf '%s\n' "$TIER_DRIFT_OUTPUT" | head -3 | while IFS= read -r line; do info "$line"; done
  else
    fail "Agent tier drift detected ($(printf '%s' "$TIER_DRIFT_OUTPUT" | grep -c '❌') stale reference(s))"
    printf '%s\n' "$TIER_DRIFT_OUTPUT" | grep -A2 '❌' | while IFS= read -r line; do
      info "$line"
    done
  fi
fi

# ---------------------------------------------------------------------------
# Check: Upstream updates (non-blocking)
# ---------------------------------------------------------------------------
printf "\n${BLUE}── Part 3: Upstream Status ──${NC}\n\n"

if [ -d "$REPO_ROOT/.git" ]; then
  git -C "$REPO_ROOT" fetch origin --quiet 2>/dev/null || true

  CURRENT_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  # Compare local main against origin/main specifically (not HEAD) — this repo
  # is usually checked out on a feature branch during development, and comparing
  # HEAD (the feature branch tip) to origin/main always differs, firing a
  # spurious warning on every feature-branch run. Comparing the local main ref
  # avoids that: it only warns when main itself is genuinely behind origin.
  LOCAL_MAIN=$(git -C "$REPO_ROOT" rev-parse refs/heads/main 2>/dev/null || echo "")
  REMOTE_HEAD=$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null || echo "")

  if [ -z "$REMOTE_HEAD" ] || [ -z "$LOCAL_MAIN" ]; then
    info "Upstream status unknown (no origin/main or local main ref found)"
  elif [ "$LOCAL_MAIN" = "$REMOTE_HEAD" ]; then
    ok "Up to date with upstream"
  elif git -C "$REPO_ROOT" merge-base --is-ancestor "$LOCAL_MAIN" "$REMOTE_HEAD" 2>/dev/null; then
    # local main is strictly BEHIND origin/main — the only case with unpulled commits
    warn "ai-engineering has unpulled commits on origin/main — run ./scripts/update.sh or git pull"
  else
    # local main is ahead of (or diverged from) origin/main — nothing to pull
    info "Local main is ahead of or diverged from origin/main (nothing to pull)"
  fi

  if [ "$CURRENT_BRANCH" != "main" ] && [ -n "$CURRENT_BRANCH" ]; then
    info "Currently on branch '$CURRENT_BRANCH' — upstream check above compares local main, not this branch"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf "\n"

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
  printf "${GREEN}  ✅ All checks passed — everything is healthy${NC}\n"
elif [ $ERRORS -eq 0 ]; then
  printf "${YELLOW}  ⚠️  %d warning(s) — no critical issues${NC}\n" "$WARNINGS"
else
  printf "${RED}  ❌ %d error(s), %d warning(s) — action needed${NC}\n" "$ERRORS" "$WARNINGS"
  printf "\n"
  info "Run ./scripts/install.sh to fix missing components"
fi

printf "\n"

if [ $ERRORS -gt 0 ]; then
  exit 1
fi

exit 0
