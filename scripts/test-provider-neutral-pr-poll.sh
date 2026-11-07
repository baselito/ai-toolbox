#!/usr/bin/env bash
# Regression tests for the Claude/Codex shared PR-poll handshake.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/enforce-auto-poll.sh"
CODEX_HOOK="$SCRIPT_DIR/../hooks/enforce-codex-review.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
check() {
  local name="$1" want="$2" out rc
  out=$(printf '%s' "$3" | env -i HOME="$WORK/home" CLAUDE_STATE_DIR="$WORK/claude" \
    AI_ENGINEERING_STATE_DIR="$WORK/shared" PATH="/usr/bin:/bin" "$HOOK" 2>/dev/null)
  rc=$?
  decision=$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<< "$out" 2>/dev/null || true)
  if [[ "$want" == blocked && "$rc" -eq 0 && "$decision" == deny ]]; then
    PASS=$((PASS + 1)); echo "PASS: $name"
  elif [[ "$want" == allowed && "$rc" -eq 0 && "$decision" != deny ]]; then
    PASS=$((PASS + 1)); echo "PASS: $name"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $name (rc=$rc output=$out)"
  fi
}

mkdir -p "$WORK/home/.claude" "$WORK/claude" "$WORK/shared"
printf 'baselito/ai-engineering 901\n' > "$WORK/shared/.auto-poll-pending"

PAYLOAD=$(jq -cn '{tool_name:"Bash", tool_input:{command:"echo unrelated work"}, cwd:"/tmp"}')
check "the enforcement reader uses the shared provider-neutral state root" blocked "$PAYLOAD"

REGISTRAR_PAYLOAD=$(jq -cn '{tool_name:"Bash", tool_input:{command:"$HOME/.codex/bin/register-pr-poll.sh --repo baselito/ai-engineering --pr 901 --provider codex --poll-id heartbeat-901"}, cwd:"/tmp"}')
check "the Codex registrar command printed by the hook is permitted" allowed "$REGISTRAR_PAYLOAD"

CODEX_WORK="$WORK/ai-engineering"
OTHER_WORK="$WORK/other-repo"
for repo in "$CODEX_WORK" "$OTHER_WORK"; do
  mkdir -p "$repo"
  git -C "$repo" init -q
done
git -C "$CODEX_WORK" remote add origin ssh://git@github.com/baselito/ai-toolbox.git
git -C "$OTHER_WORK" remote add origin https://github.com/baselito/ai-toolbox.git
printf '%s\n' '## Toolbox Path' "$CODEX_WORK" > "$WORK/home/.claude/memory.md"
printf '%s\n' '# Personal Defaults' '- Codex: enabled' > "$WORK/claude/memory.md"

check_codex_skip() {
  local name="$1" cwd="$2" want="$3" out rc decision payload
  payload=$(jq -cn --arg cwd "$cwd" '{tool_name:"Bash", tool_input:{command:"gh pr create --title test"}, cwd:$cwd}')
  out=$(printf '%s' "$payload" | env -i HOME="$WORK/home" CLAUDE_STATE_DIR="$WORK/claude" \
    AI_ENGINEERING_SKIP_CODEX_REVIEW=1 PATH="/usr/bin:/bin" "$CODEX_HOOK" 2>/dev/null)
  rc=$?
  decision=$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<< "$out" 2>/dev/null || true)
  if [[ "$want" == allowed && "$rc" -eq 0 && "$decision" != deny ]]; then
    PASS=$((PASS + 1)); echo "PASS: $name"
  elif [[ "$want" == blocked && "$rc" -eq 0 && "$decision" == deny ]]; then
    PASS=$((PASS + 1)); echo "PASS: $name"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $name (rc=$rc decision=$decision output=$out)"
  fi
}

check_codex_skip "Codex pre-PR review skip is scoped to ai-engineering" "$CODEX_WORK" allowed
check_codex_skip "Codex pre-PR review skip cannot disable another repository's gate" "$OTHER_WORK" blocked

check_codex_skip_prefix() {
  local payload out rc decision
  payload=$(jq -cn --arg cwd "$CODEX_WORK" '{tool_name:"Bash", tool_input:{command:"AI_ENGINEERING_SKIP_CODEX_REVIEW=1 gh pr create --title test"}, cwd:$cwd}')
  out=$(printf '%s' "$payload" | env -i HOME="$WORK/home" CLAUDE_STATE_DIR="$WORK/claude" \
    PATH="/usr/bin:/bin" "$CODEX_HOOK" 2>/dev/null)
  rc=$?
  decision=$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<< "$out" 2>/dev/null || true)
  [[ "$rc" -eq 0 && "$decision" != deny ]]
}
if check_codex_skip_prefix; then
  PASS=$((PASS + 1)); echo "PASS: the exact command-line skip prefix is accepted"
else
  FAIL=$((FAIL + 1)); echo "FAIL: the exact command-line skip prefix is accepted"
fi

echo "provider-neutral PR-poll: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
