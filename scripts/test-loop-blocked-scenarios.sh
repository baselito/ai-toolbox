#!/usr/bin/env bash
# Regression matrix for blockers observed during autonomous GoalRun/PR work.
# This is intentionally offline: it exercises hook contracts and the durable
# runtime without changing GitHub state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
AUTO_GATE="$REPO_ROOT/hooks/enforce-auto-poll.sh"
AUTO_WRITER="$REPO_ROOT/hooks/auto-poll-after-pr.sh"
CODEX_GATE="$REPO_ROOT/hooks/enforce-codex-review.sh"
REGISTER="$REPO_ROOT/scripts/register-pr-poll.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
check_decision() {
  local name="$1" want="$2" hook="$3" payload="$4" cwd="$5" out rc decision
  out=$(printf '%s' "$payload" | env -i HOME="$WORK/home" CLAUDE_STATE_DIR="$WORK/state" \
    AI_ENGINEERING_STATE_DIR="$WORK/state" PATH="/opt/homebrew/bin:/usr/bin:/bin" \
    "$hook" 2>/dev/null)
  rc=$?
  decision=$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<< "$out" 2>/dev/null || true)
  if [[ "$want" == allowed && "$rc" -eq 0 && "$decision" != deny ]]; then
    PASS=$((PASS + 1)); echo "PASS: $name"
  elif [[ "$want" == blocked && "$rc" -eq 0 && "$decision" == deny ]]; then
    PASS=$((PASS + 1)); echo "PASS: $name"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $name (cwd=$cwd rc=$rc decision=$decision output=$out)"
  fi
}

mkdir -p "$WORK/home/.claude" "$WORK/state" "$WORK/owned" "$WORK/bystander"
OWNED_ROOT=$(cd "$WORK/owned" && pwd -P)
BYSTANDER_ROOT=$(cd "$WORK/bystander" && pwd -P)
git -C "$WORK/owned" init -q
git -C "$WORK/bystander" init -q
for repo in "$WORK/owned" "$WORK/bystander"; do
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name scenario-test
  printf 'scenario\n' > "$repo/README"
  git -C "$repo" add README
  git -C "$repo" commit -qm baseline
done
OWNED_HEAD=$(git -C "$WORK/owned" rev-parse HEAD)

# A pending marker belongs to the checkout that opened the PR. It must not wedge
# an unrelated worktree, while the owning worktree remains gated until polling
# is registered. Exercise the actual PostToolUse writer rather than hand-writing
# the marker so the app-provided cwd/HEAD binding is covered too.
POST_PAYLOAD=$(jq -cn --arg cwd "$WORK/owned" \
  '{tool_name:"Bash",tool_input:{command:"gh pr create"},tool_result:{stdout:"https://github.com/baselito/ai-toolbox/pull/901"},cwd:$cwd}')
printf '%s' "$POST_PAYLOAD" | env -i HOME="$WORK/home" CLAUDE_STATE_DIR="$WORK/state" \
  AI_ENGINEERING_STATE_DIR="$WORK/state" PATH="/opt/homebrew/bin:/usr/bin:/bin" \
  "$AUTO_WRITER" >/dev/null 2>&1
PENDING_FILE=$(find "$WORK/state" -maxdepth 1 -name '.auto-poll-pending-*' -type f -print -quit)
if grep -Fxq "worktree=$OWNED_ROOT" "$PENDING_FILE" \
   && grep -Fxq "head=$OWNED_HEAD" "$PENDING_FILE"; then
  PASS=$((PASS + 1)); echo "PASS: PostToolUse writer records the originating worktree"
else
  FAIL=$((FAIL + 1)); echo "FAIL: PostToolUse writer records the originating worktree"
fi
BYSTANDER=$(jq -cn --arg cwd "$WORK/bystander" '{tool_name:"Bash",tool_input:{command:"echo unrelated work"},cwd:$cwd}')
OWNER=$(jq -cn --arg cwd "$WORK/owned" '{tool_name:"Bash",tool_input:{command:"echo unrelated work"},cwd:$cwd}')
check_decision "pending poll does not block a bystander worktree" allowed "$AUTO_GATE" "$BYSTANDER" "$WORK/bystander"
check_decision "pending poll still blocks its owning worktree" blocked "$AUTO_GATE" "$OWNER" "$WORK/owned"

# The registrar used by either provider must understand the same structured
# marker and clear only the matching PR.
(cd "$OWNED_ROOT" && AI_ENGINEERING_STATE_DIR="$WORK/state" "$REGISTER" \
  --repo baselito/ai-engineering --pr 901 --provider codex --poll-id heartbeat-901 >/dev/null)
if [[ ! -e "$PENDING_FILE" ]]; then
  PASS=$((PASS + 1)); echo "PASS: Codex heartbeat registration clears the matching structured marker"
else
  FAIL=$((FAIL + 1)); echo "FAIL: Codex heartbeat registration clears the matching structured marker"
fi

# A second PR in another worktree must not be cleared by registering PR 901.
cat > "$WORK/state/.auto-poll-pending-baselito-ai-engineering-902" <<EOF
repo=baselito/ai-engineering
pr=902
worktree=$WORK/bystander
head=$(git -C "$WORK/bystander" rev-parse HEAD)
EOF
AI_ENGINEERING_STATE_DIR="$WORK/state" "$REGISTER" \
  --repo baselito/ai-engineering --pr 901 --provider codex --poll-id heartbeat-901b >/dev/null
if [[ -e "$WORK/state/.auto-poll-pending-baselito-ai-engineering-902" ]]; then
  PASS=$((PASS + 1)); echo "PASS: poll registration preserves another PR's marker"
else
  FAIL=$((FAIL + 1)); echo "FAIL: poll registration preserves another PR's marker"
fi

# Missing or malformed hook metadata must remain fail-closed. In particular,
# an owning invocation with no cwd payload cannot be treated as a bystander.
cat > "$WORK/state/.auto-poll-pending-baselito-ai-engineering-903" <<EOF
repo=baselito/ai-engineering
pr=903
worktree=$WORK/owned
EOF
UNKNOWN_CWD=$(jq -cn '{tool_name:"Bash",tool_input:{command:"echo unrelated work"}}')
check_decision "missing hook cwd does not bypass a pending obligation" blocked "$AUTO_GATE" "$UNKNOWN_CWD" ""

# A read-only search that mentions a guarded action is not that action. The
# actual action must remain blocked without its explicit review evidence.
printf '## Toolbox Path\n%s\n' "$WORK/owned" > "$WORK/home/.claude/memory.md"
printf '%s\n' '# Personal Defaults' '- Codex: enabled' > "$WORK/state/memory.md"
SEARCH=$(jq -cn --arg cwd "$WORK/owned" '{tool_name:"Bash",tool_input:{command:"rg -n '\''CWD|gh pr create|merge'\'' hooks"},cwd:$cwd}')
SEARCH_ESCAPED_PIPE=$(jq -cn --arg cwd "$WORK/owned" '{tool_name:"Bash",tool_input:{command:"rg -n \"gh \\\"pr create\\\"|merge\" hooks"},cwd:$cwd}')
SEARCH_PRE=$(jq -cn --arg cwd "$WORK/owned" '{tool_name:"Bash",tool_input:{command:"rg --pre '\''gh pr create'\'' pattern hooks"},cwd:$cwd}')
SEARCH_PIPE=$(jq -cn --arg cwd "$WORK/owned" '{tool_name:"Bash",tool_input:{command:"rg '\''gh pr create'\'' hooks | gh pr create --title test"},cwd:$cwd}')
CREATE=$(jq -cn --arg cwd "$WORK/owned" '{tool_name:"Bash",tool_input:{command:"gh pr create --title test"},cwd:$cwd}')
check_decision "Codex review gate allows read-only inspection text" allowed "$CODEX_GATE" "$SEARCH" "$WORK/owned"
check_decision "Codex review gate allows escaped quotes and pipes inside search data" allowed "$CODEX_GATE" "$SEARCH_ESCAPED_PIPE" "$WORK/owned"
check_decision "Codex review gate blocks executable rg preprocessors" blocked "$CODEX_GATE" "$SEARCH_PRE" "$WORK/owned"
check_decision "Codex review gate blocks a pipe to the guarded action" blocked "$CODEX_GATE" "$SEARCH_PIPE" "$WORK/owned"
check_decision "Codex review gate still blocks an unreviewed action" blocked "$CODEX_GATE" "$CREATE" "$WORK/owned"

# The runtime tests are the authoritative offline checks for provider fallback,
# unknown outcomes, comment-thread gates, and explicit merge-state policy.
if python3 "$REPO_ROOT/scripts/test_goal_loop_runtime.py" >/dev/null; then
  PASS=$((PASS + 1)); echo "PASS: durable runtime blocker scenarios"
else
  FAIL=$((FAIL + 1)); echo "FAIL: durable runtime blocker scenarios"
fi

for suite in test-review-pr-precheck.sh test-merge-gate-dedupe.sh test-loop-progress-signature.sh; do
  if bash "$REPO_ROOT/scripts/$suite" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "PASS: $suite blocker coverage"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $suite blocker coverage"
  fi
done

echo "loop-blocked-scenarios: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
