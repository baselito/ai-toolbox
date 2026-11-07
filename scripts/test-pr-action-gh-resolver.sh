#!/usr/bin/env bash
# Regression tests for the merge hook's restricted-PATH gh resolution.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/pr-action-safety.sh"
PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

assert_contains() {
  local name="$1" needle="$2"
  if grep -qF -- "$needle" "$HOOK"; then
    PASS=$((PASS + 1)); echo "PASS: $name"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $name — missing [$needle]"
  fi
}

assert_contains "resolver stores a trusted gh path" 'GH_BIN='
assert_contains "resolver includes Homebrew ARM path" '"/opt/homebrew/bin/gh"'
assert_contains "resolved binary is prepended for all gh calls" 'PATH="$(dirname "$GH_BIN"):$PATH"'
assert_contains "sanitized fallback only applies to bare gh" '-z "$COMMAND_GH_BIN" && -z "$CALLER_GH_PATH"'
assert_contains "missing gh remains fail-closed" 'if [[ -z "$GH_BIN" ]]; then'
if grep -qF 'resolved="$(command -v gh' "$HOOK"; then
  FAIL=$((FAIL + 1)); echo "FAIL: resolver must not trust command -v gh"
else
  PASS=$((PASS + 1)); echo "PASS: resolver does not trust project PATH gh"
fi

# Execute the real resolver function with a fake PATH-only gh. A trusted
# fixed-location gh may exist on the host; either way the resolver must never
# return the fake path supplied by the caller's PATH.
RESOLVER=$(sed -n '/^resolve_gh()/,/^}/p' "$HOOK")
mkdir -p "$WORK/bin"
touch "$WORK/bin/gh"
chmod +x "$WORK/bin/gh"
RESOLVED=$(PATH="$WORK/bin:/usr/bin:/bin" bash -c "$RESOLVER; resolve_gh" 2>/dev/null || true)
if [[ "$RESOLVED" == "$WORK/bin/gh" ]]; then
  FAIL=$((FAIL + 1)); echo "FAIL: runtime resolver accepted PATH-only gh shim"
else
  PASS=$((PASS + 1)); echo "PASS: runtime resolver rejects PATH-only gh shim"
fi

# The deny path must still emit structured JSON when HOME is unset but the
# test state root is supplied. Under set -u, interpolating $HOME in the marker
# explanation used to abort before emitting the fail-closed decision.
mkdir -p "$WORK/state"
HOOK_OUTPUT=$(env -u HOME CLAUDE_STATE_DIR="$WORK/state" bash "$HOOK" \
  <<< '{"tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"gh pr merge 42 --repo baselito/ai-engineering"}}' 2>&1 || true)
if printf '%s' "$HOOK_OUTPUT" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
  PASS=$((PASS + 1)); echo "PASS: HOME-unset merge denial remains structured and fail-closed"
else
  FAIL=$((FAIL + 1)); echo "FAIL: HOME-unset merge denial lost its structured deny (output=$HOOK_OUTPUT)"
fi

# An exported shell function named gh must not shadow the absolute binary used
# by the hook. The no-repo path exercises repo discovery before marker checks;
# the function writes a sentinel if the hook accidentally invokes bare gh.
rm -f "$WORK/gh-function-used"
HOOK_OUTPUT=$(HOME="$WORK" CLAUDE_STATE_DIR="$WORK/state" \
  bash -c 'gh() { touch "$GH_SENTINEL"; return 1; }; export -f gh; GH_SENTINEL="$1"; export GH_SENTINEL; cd /tmp && bash "$2" <<< "$3"' \
  bash "$WORK/gh-function-used" "$HOOK" \
  '{"tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"gh pr merge 42"}}' 2>&1 || true)
if [[ ! -e "$WORK/gh-function-used" ]] \
   && printf '%s' "$HOOK_OUTPUT" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
  PASS=$((PASS + 1)); echo "PASS: hook gh calls cannot be shadowed by exported shell functions"
else
  FAIL=$((FAIL + 1)); echo "FAIL: exported gh function shadowed the hook or deny was lost (output=$HOOK_OUTPUT)"
fi

# A path-qualified gh must not be able to pass the ambient resolver check.
HOOK_OUTPUT=$(HOME="$WORK" CLAUDE_STATE_DIR="$WORK/state" bash "$HOOK" \
  <<< '{"tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"/tmp/gh pr merge 42 --repo baselito/ai-engineering --squash"}}' 2>&1 || true)
if printf '%s' "$HOOK_OUTPUT" | grep -q 'trusted gh executable directly'; then
  PASS=$((PASS + 1)); echo "PASS: path-qualified merge executables are rejected"
else
  FAIL=$((FAIL + 1)); echo "FAIL: path-qualified merge executable was not rejected (output=$HOOK_OUTPUT)"
fi

# Inline environment prefixes can change the executable in the command after
# the hook returns. They must be rejected even when the ambient gh resolves to
# the trusted binary.
HOOK_OUTPUT=$(HOME="$WORK" CLAUDE_STATE_DIR="$WORK/state" bash "$HOOK" \
  <<< '{"tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"PATH=/tmp/shim gh pr merge 42 --repo baselito/ai-engineering --squash"}}' 2>&1 || true)
if printf '%s' "$HOOK_OUTPUT" | grep -Eq 'environment assignments and env launchers|trusted gh executable directly'; then
  PASS=$((PASS + 1)); echo "PASS: inline environment prefixes cannot replace merge executable"
else
  FAIL=$((FAIL + 1)); echo "FAIL: inline environment prefix was not rejected (output=$HOOK_OUTPUT)"
fi

HOOK_OUTPUT=$(HOME="$WORK" CLAUDE_STATE_DIR="$WORK/state" bash "$HOOK" \
  <<< '{"tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"PATH=\"/tmp shim\" gh pr merge 42 --repo baselito/ai-engineering --squash"}}' 2>&1 || true)
if printf '%s' "$HOOK_OUTPUT" | grep -Eq 'environment assignments and env launchers|trusted gh executable directly'; then
  PASS=$((PASS + 1)); echo "PASS: quoted inline environment prefixes cannot replace merge executable"
else
  FAIL=$((FAIL + 1)); echo "FAIL: quoted inline environment prefix was not rejected (output=$HOOK_OUTPUT)"
fi

for command in \
  'PATH=/tmp/shim; gh pr merge 42 --repo baselito/ai-engineering --squash' \
  'export PATH=/tmp/shim; gh pr merge 42 --repo baselito/ai-engineering --squash' \
  "touch /tmp/marker && PATH='/tmp shim'; gh pr merge 42 --repo baselito/ai-engineering --squash"; do
  HOOK_OUTPUT=$(HOME="$WORK" CLAUDE_STATE_DIR="$WORK/state" bash "$HOOK" \
    <<< "{\"tool_name\":\"Bash\",\"cwd\":\"/tmp\",\"tool_input\":{\"command\":\"$command\"}}" 2>&1 || true)
  if printf '%s' "$HOOK_OUTPUT" | grep -Eq 'environment assignments and env launchers|trusted gh executable directly'; then
    PASS=$((PASS + 1)); echo "PASS: PATH mutation in a prior shell segment is rejected"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: prior-shell-segment PATH mutation was not rejected (command=$command output=$HOOK_OUTPUT)"
  fi
done

# A PATH-only jq shim must not be able to turn malformed hook input into an
# allow. The hook resets PATH before parsing, so the sentinel remains absent and
# the normal missing-marker denial is still structured.
mkdir -p "$WORK/jq-bin"
cat > "$WORK/jq-bin/jq" <<'SHIM'
#!/usr/bin/env bash
touch "$JQ_SENTINEL"
exit 1
SHIM
chmod +x "$WORK/jq-bin/jq"
HOOK_OUTPUT=$(HOME="$WORK" CLAUDE_STATE_DIR="$WORK/state" JQ_SENTINEL="$WORK/jq-shim-used" \
  PATH="$WORK/jq-bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$HOOK" \
  <<< '{"tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"gh pr merge 42 --repo baselito/ai-engineering --squash"}}' 2>&1 || true)
if [[ ! -e "$WORK/jq-shim-used" ]] \
   && printf '%s' "$HOOK_OUTPUT" | grep -q 'requires the marker file'; then
  PASS=$((PASS + 1)); echo "PASS: PATH-only jq shim cannot control merge-hook parsing"
else
  FAIL=$((FAIL + 1)); echo "FAIL: PATH-only jq shim controlled merge-hook parsing (output=$HOOK_OUTPUT)"
fi

# Parseable but malformed statusCheckRollup data must produce a structured
# denial rather than an unhandled jq exit, and the gate marker must be consumed.
mkdir -p "$WORK/.local/bin" "$WORK/.claude"
cat > "$WORK/.local/bin/gh" <<'SHIM'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  printf '%s\n' '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","statusCheckRollup":"not-an-array"}'
else
  printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
fi
SHIM
chmod +x "$WORK/.local/bin/gh"
touch "$WORK/.claude/.pr-merge-gate-baselito-ai-engineering-42"
HOOK_OUTPUT=$(HOME="$WORK" CLAUDE_STATE_DIR="$WORK/.claude" \
  PATH="$WORK/.local/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$HOOK" \
  <<< '{"tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"gh pr merge 42 --repo baselito/ai-engineering --squash"}}' 2>&1 || true)
if [[ ! -e "$WORK/.claude/.pr-merge-gate-baselito-ai-engineering-42" ]] \
   && printf '%s' "$HOOK_OUTPUT" | grep -q 'invalid PR-state JSON'; then
  PASS=$((PASS + 1)); echo "PASS: malformed status-check JSON fails closed with structured denial"
else
  FAIL=$((FAIL + 1)); echo "FAIL: malformed status-check JSON escaped structured denial (output=$HOOK_OUTPUT)"
fi

# A response with an explicit null errors field is not an accepted success
# shape for this fail-closed merge gate and must not be interpreted as zero
# unresolved review threads. The fake gh is in
# the hook's documented fixed user-local location ($HOME/.local/bin/gh), not a
# project PATH-only shim; PATH is included solely so the caller-resolution
# consistency check sees that same trusted binary.
cat > "$WORK/.local/bin/gh" <<'SHIM'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  printf '%s\n' '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","statusCheckRollup":[],"headRefOid":"0123456789abcdef0123456789abcdef01234567"}'
else
  printf '%s\n' '{"errors":null,"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
fi
SHIM
chmod +x "$WORK/.local/bin/gh"
touch "$WORK/.claude/.pr-merge-gate-baselito-ai-engineering-42"
HOOK_OUTPUT=$(HOME="$WORK" CLAUDE_STATE_DIR="$WORK/.claude" \
  PATH="$WORK/.local/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$HOOK" \
  <<< '{"tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"gh pr merge 42 --repo baselito/ai-engineering --squash"}}' 2>&1 || true)
if [[ ! -e "$WORK/.claude/.pr-merge-gate-baselito-ai-engineering-42" ]] \
   && printf '%s' "$HOOK_OUTPUT" | grep -q 'unresolved_threads=-1'; then
  PASS=$((PASS + 1)); echo "PASS: explicit null GraphQL errors field fails closed"
else
  FAIL=$((FAIL + 1)); echo "FAIL: explicit null GraphQL errors field was treated as clean (output=$HOOK_OUTPUT)"
fi

# A valid GraphQL response with no errors member must produce a numeric page
# count. This exercises the success branch directly; a jq expression that
# leaks its validation boolean would abort under set -u while adding PAGE_U.
cat > "$WORK/.local/bin/gh" <<'SHIM'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  printf '%s\n' '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","statusCheckRollup":[],"headRefOid":"0123456789abcdef0123456789abcdef01234567"}'
else
  printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
fi
SHIM
chmod +x "$WORK/.local/bin/gh"
touch "$WORK/.claude/.pr-merge-gate-baselito-ai-engineering-42"
HOOK_OUTPUT=$(HOME="$WORK" CLAUDE_STATE_DIR="$WORK/.claude" \
  PATH="$WORK/.local/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$HOOK" \
  <<< '{"tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"gh pr merge 42 --repo baselito/ai-engineering --squash"}}' 2>&1 || true)
if [[ -e "$WORK/.claude/.pr-merge-gate-baselito-ai-engineering-42" ]] \
   && [[ -z "$HOOK_OUTPUT" ]]; then
  PASS=$((PASS + 1)); echo "PASS: valid GraphQL review-thread data yields numeric count"
else
  FAIL=$((FAIL + 1)); echo "FAIL: valid GraphQL review-thread data did not pass cleanly (output=$HOOK_OUTPUT)"
fi

# A HOME-local executable must not become trusted merely because the hook's
# subprocess PATH is sanitized and CALLER_GH_PATH is empty. HOME is an
# environment variable, so only independently fixed native locations may be
# used for this fallback.
touch "$WORK/.claude/.pr-merge-gate-baselito-ai-engineering-42"
HOOK_OUTPUT=$(HOME="$WORK" CLAUDE_STATE_DIR="$WORK/.claude" \
  PATH="/usr/bin:/bin" bash "$HOOK" \
  <<< '{"tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"gh pr merge 42 --repo baselito/ai-engineering --squash"}}' 2>&1 || true)
if [[ ! -e "$WORK/.claude/.pr-merge-gate-baselito-ai-engineering-42" ]] \
   && printf '%s' "$HOOK_OUTPUT" | grep -q 'could not fetch PR state\|gh not available'; then
  PASS=$((PASS + 1)); echo "PASS: sanitized caller PATH cannot trust HOME-local gh"
else
  FAIL=$((FAIL + 1)); echo "FAIL: sanitized caller PATH trusted HOME-local gh (output=$HOOK_OUTPUT)"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "All $PASS gh-resolver tests passed."
  exit 0
fi
echo "$FAIL gh-resolver tests failed."
exit 1
