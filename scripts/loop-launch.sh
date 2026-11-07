#!/bin/bash
# loop-launch.sh — apply the toolbox loop contract to one native Claude run.
#
# This is the single launcher for a self-paced loop. It reads only numeric
# values from .claude/PROJECT.md, clamps them to toolbox-owned ceilings, and
# passes the resulting values to Claude's native controls. Project text is
# never evaluated as shell code and cannot select the executable or add flags.

set -uo pipefail

die() {
  echo "loop-launch: $1" >&2
  exit 2
}

SCRIPT_PATH="${BASH_SOURCE[0]}"
if [[ "$SCRIPT_PATH" == */* ]]; then
  SCRIPT_DIR="${SCRIPT_PATH%/*}"
else
  SCRIPT_DIR="."
fi
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd -P)"
CONFIG_SCRIPT="$SCRIPT_DIR/loop-config.sh"
[[ -x "$CONFIG_SCRIPT" ]] || die "missing loop-config.sh beside launcher"
EFFECTIVE_TURNS=$(bash "$CONFIG_SCRIPT" --value max_turns) || exit $?
EFFECTIVE_NO_PROGRESS=$(bash "$CONFIG_SCRIPT" --value no_progress_after) || exit $?
EFFECTIVE_SPEND=$(bash "$CONFIG_SCRIPT" --value max_spend_usd) || exit $?

# The wrapper owns these bounds. Refusing a duplicate spend flag prevents a
# caller from replacing the project-derived value later in Claude's argv.
for arg in "$@"; do
  case "$arg" in
    --max-budget-usd|--max-budget-usd=*)
      die "do not pass --max-budget-usd to loop-launch; set loop.max_spend_usd in .claude/PROJECT.md"
      ;;
    --max-turns|--max-turns=*)
      die "do not pass --max-turns to loop-launch; set loop.max_turns in .claude/PROJECT.md"
      ;;
  esac
done

CLAUDE_BIN=""
# Hook/launcher subprocesses can have a reduced or project-influenced PATH.
# Never accept command -v here: a checkout can contain a claude shim that
# ignores the bounds this wrapper is responsible for applying. Only fixed
# native-install locations or the absolute path recorded by install.sh are
# trusted. The record is written under ~/.claude by the installer, after it
# explicitly resolves the user's selected CLI; it lets npm/nvm and Windows
# installs work without trusting a project-controlled PATH at loop time.
if [[ -f "$SCRIPT_DIR/claude-bin" && ! -L "$SCRIPT_DIR/claude-bin" ]]; then
  RECORDED_CLAUDE_BIN=""
  IFS= read -r RECORDED_CLAUDE_BIN < "$SCRIPT_DIR/claude-bin" || true
  if [[ "$RECORDED_CLAUDE_BIN" == /* && -x "$RECORDED_CLAUDE_BIN" && ! -d "$RECORDED_CLAUDE_BIN" ]]; then
    CLAUDE_BIN="$RECORDED_CLAUDE_BIN"
  fi
fi
HOME_DIR="${HOME:-}"
LOCAL_APP_DATA="${LOCALAPPDATA:-}"
if [[ -z "$LOCAL_APP_DATA" && -n "$HOME_DIR" ]]; then
  LOCAL_APP_DATA="$HOME_DIR/AppData/Local"
fi
if [[ -z "$CLAUDE_BIN" && -n "$HOME_DIR" ]]; then
  for candidate in \
    "$HOME_DIR/.local/bin/claude" \
    "$HOME_DIR/.npm-global/bin/claude" \
    "$HOME_DIR/Library/Application Support/Claude/claude-code"/*/claude.app/Contents/MacOS/claude \
    "$HOME_DIR/Library/Application Support/Claude/claude-code-vm"/*/claude \
    "$HOME_DIR/.local/share/claude"*/claude \
    "$HOME_DIR/.nvm/versions/node"/*/bin/claude \
    "$HOME_DIR/AppData/Local/Programs/Claude/claude.exe" \
    "$HOME_DIR/AppData/Local/Claude/claude-code"*/claude \
    "$HOME_DIR/AppData/Local/Claude/claude-code"*/claude.exe; do
    if [[ -x "$candidate" && ! -d "$candidate" ]]; then
      CLAUDE_BIN="$candidate"
      break
    fi
  done
fi
if [[ -z "$CLAUDE_BIN" && -n "$LOCAL_APP_DATA" ]]; then
  for candidate in \
    "$LOCAL_APP_DATA/Programs/Claude/claude.exe" \
    "$LOCAL_APP_DATA/Claude/claude-code"*/claude \
    "$LOCAL_APP_DATA/Claude/claude-code"*/claude.exe; do
    if [[ -x "$candidate" && ! -d "$candidate" ]]; then
      CLAUDE_BIN="$candidate"
      break
    fi
  done
fi
if [[ -z "$CLAUDE_BIN" ]]; then
  for candidate in \
    "/opt/homebrew/bin/claude" \
    "/usr/local/bin/claude" \
    "/usr/bin/claude"; do
    if [[ -x "$candidate" && ! -d "$candidate" ]]; then
      CLAUDE_BIN="$candidate"
      break
    fi
  done
fi
[[ -n "$CLAUDE_BIN" ]] || die "Claude Code CLI not found on PATH or in a trusted native install location"

echo "loop-launch: max_turns=$EFFECTIVE_TURNS no_progress_after=$EFFECTIVE_NO_PROGRESS max_spend_usd=$EFFECTIVE_SPEND" >&2
export CLAUDE_CODE_MAX_TURNS="$EFFECTIVE_TURNS"
export CLAUDE_CODE_STOP_HOOK_BLOCK_CAP="$EFFECTIVE_TURNS"
export LOOP_NO_PROGRESS_AFTER="$EFFECTIVE_NO_PROGRESS"
exec "$CLAUDE_BIN" --max-budget-usd "$EFFECTIVE_SPEND" "$@"
