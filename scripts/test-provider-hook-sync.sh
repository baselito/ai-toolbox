#!/usr/bin/env bash
# Regression tests for the provider-neutral managed-hook synchronizer.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$ROOT/scripts/sync-provider-hooks.sh"
REMOVE="$ROOT/scripts/remove-provider-hooks.js"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1${2:+ — $2}"; }

assert_true() {
  local name="$1" detail="$2"
  shift 2
  if "$@"; then pass "$name"; else fail "$name" "$detail"; fi
}

assert_contains() {
  local name="$1" needle="$2" file="$3"
  if grep -Fq -- "$needle" "$file"; then pass "$name"; else fail "$name" "missing '$needle' in $file"; fi
}

echo ""
echo "=== provider-neutral managed hook sync ==="

SOURCE="$WORK/source"
CLAUDE_HOOKS="$WORK/claude/hooks"
CODEX_HOOKS="$WORK/codex/hooks"
mkdir -p "$SOURCE" "$CLAUDE_HOOKS" "$CODEX_HOOKS"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CLAUDE_HOOKS/retired.sh"
printf 'retired.sh\n' > "$CLAUDE_HOOKS/.toolbox-hook-manifest"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SOURCE/first.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SOURCE/second.sh"
cat > "$SOURCE/hooks-config.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/first.sh"}]}],
    "CronCreate": [{"matcher": "*", "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/first.sh"}]}],
    "AskUserQuestion": [{"matcher": "*", "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/first.sh"}]}]
  },
  "permissions": {"allow": ["Bash"]}
}
JSON

# RED: this command must fail until the shared synchronizer exists.
if bash "$SYNC" --source "$SOURCE" --destination "$CLAUDE_HOOKS" \
    --config "$WORK/claude/config.json" --provider claude >/dev/null 2>&1; then
  sync_rc=0
else
  sync_rc=$?
fi
assert_true "the sync command is available" "sync-provider-hooks.sh exited $sync_rc" test "$sync_rc" -eq 0

if [ "$sync_rc" -eq 0 ]; then
  assert_true "Claude receives every managed hook" "second.sh was not copied" test -f "$CLAUDE_HOOKS/second.sh"
  assert_true "Claude hook is executable" "first.sh is not executable" test -x "$CLAUDE_HOOKS/first.sh"
  assert_true "stale managed Claude hooks are removed" "retired.sh was not removed" test ! -e "$CLAUDE_HOOKS/retired.sh"
  assert_contains "Claude config keeps its native hook path" "$CLAUDE_HOOKS/first.sh" "$WORK/claude/config.json"

  # Seed a stale Codex config and prove the synchronizer replaces managed
  # matchers while retaining unrelated user configuration.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CODEX_HOOKS/retired.sh"
  printf 'retired.sh\n' > "$CODEX_HOOKS/.toolbox-hook-manifest"
  cat > "$WORK/codex/config.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [{"matcher": "Bash", "hooks": [
      {"type": "command", "command": "bash CODEX_HOOKS/retired.sh"},
      {"type": "command", "command": "echo user-managed-matcher"},
      {"type": "command", "command": "bash CODEX_HOOKS/first.sh-wrapper"}
    ]}],
    "CustomEvent": [{"matcher": "*", "hooks": [{"type": "command", "command": "echo user"}]}]
  },
  "custom": {"keep": true}
}
JSON
  sed -i.bak "s#CODEX_HOOKS#$CODEX_HOOKS#g" "$WORK/codex/config.json"
  rm -f "$WORK/codex/config.json.bak"
  if bash "$SYNC" --source "$SOURCE" --destination "$CODEX_HOOKS" \
      --config "$WORK/codex/config.json" --provider codex >/dev/null 2>&1; then
    codex_rc=0
  else
    codex_rc=$?
  fi
  assert_true "Codex sync completes" "sync exited $codex_rc" test "$codex_rc" -eq 0
  if [ "$codex_rc" -eq 0 ]; then
    assert_true "Codex receives every managed hook" "second.sh was not copied" test -f "$CODEX_HOOKS/second.sh"
    assert_true "Codex hook is executable" "first.sh is not executable" test -x "$CODEX_HOOKS/first.sh"
    assert_true "stale managed Codex hooks are removed" "retired.sh was not removed" test ! -e "$CODEX_HOOKS/retired.sh"
    assert_contains "Codex config points at its own hook directory" "$CODEX_HOOKS/first.sh" "$WORK/codex/config.json"
    assert_true "stale managed Codex matcher entries are removed" "retired hook registration remained" bash -c '! grep -Fq "retired.sh" "$1"' _ "$WORK/codex/config.json"
    assert_contains "unrelated hook in a managed matcher is preserved" 'echo user-managed-matcher' "$WORK/codex/config.json"
    assert_contains "hook-name prefixes are not treated as managed" 'first.sh-wrapper' "$WORK/codex/config.json"
    assert_true "Codex config has no Claude hook path" "Claude path leaked into Codex config" bash -c '! grep -Fq "~/.claude/hooks" "$1"' _ "$WORK/codex/config.json"
    assert_true "Codex config omits Claude permissions" "Claude permissions leaked into Codex config" bash -c '! grep -Fq '"'"'"permissions"'"'"' "$1"' _ "$WORK/codex/config.json"
    assert_true "Codex config omits Claude-only CronCreate matcher" "CronCreate leaked into Codex config" bash -c '! grep -Fq '"'"'"CronCreate"'"'"' "$1"' _ "$WORK/codex/config.json"
    assert_true "Codex config omits Claude-only AskUserQuestion matcher" "AskUserQuestion leaked into Codex config" bash -c '! grep -Fq '"'"'"AskUserQuestion"'"'"' "$1"' _ "$WORK/codex/config.json"
    assert_contains "unrelated Codex hook configuration is preserved" '"CustomEvent"' "$WORK/codex/config.json"
    assert_contains "unrelated Codex settings are preserved" '"custom"' "$WORK/codex/config.json"

    CODEX_TARGET="$WORK/codex/config-target.json"
    CODEX_LINK="$WORK/codex/config-link.json"
    printf '{"settings":{"keep":true}}\n' > "$CODEX_TARGET"
    ln -s "$CODEX_TARGET" "$CODEX_LINK"
    if bash "$SYNC" --source "$SOURCE" --destination "$CODEX_HOOKS" \
        --config "$CODEX_LINK" --provider codex >/dev/null 2>&1; then
      symlink_rc=0
    else
      symlink_rc=$?
    fi
    assert_true "syncing through a Codex config symlink completes" "symlink sync exited $symlink_rc" test "$symlink_rc" -eq 0
    if [ "$symlink_rc" -eq 0 ]; then
      assert_true "Codex config symlink is preserved" "config symlink was replaced" test -L "$CODEX_LINK"
      assert_contains "Codex symlink target receives managed hooks" "$CODEX_HOOKS/first.sh" "$CODEX_TARGET"
    fi

    CODEX_DANGLING_TARGET="$WORK/codex/dangling-target.json"
    CODEX_DANGLING_LINK="$WORK/codex/config-dangling.json"
    ln -s "$CODEX_DANGLING_TARGET" "$CODEX_DANGLING_LINK"
    if bash "$SYNC" --source "$SOURCE" --destination "$CODEX_HOOKS" \
        --config "$CODEX_DANGLING_LINK" --provider codex >/dev/null 2>&1; then
      dangling_rc=0
    else
      dangling_rc=$?
    fi
    assert_true "syncing through a dangling Codex config symlink completes" "dangling symlink sync exited $dangling_rc" test "$dangling_rc" -eq 0
    if [ "$dangling_rc" -eq 0 ]; then
      assert_true "dangling Codex config symlink is preserved" "dangling config symlink was replaced" test -L "$CODEX_DANGLING_LINK"
      assert_contains "dangling symlink target receives managed hooks" "$CODEX_HOOKS/first.sh" "$CODEX_DANGLING_TARGET"
    fi

    CODEX_UNSAFE_TARGET="$WORK/outside/unsafe-target.json"
    CODEX_UNSAFE_LINK="$WORK/codex/config-unsafe-dangling.json"
    mkdir -p "$WORK/outside"
    ln -s "$CODEX_UNSAFE_TARGET" "$CODEX_UNSAFE_LINK"
    if bash "$SYNC" --source "$SOURCE" --destination "$CODEX_HOOKS" \
        --config "$CODEX_UNSAFE_LINK" --provider codex >/dev/null 2>&1; then
      unsafe_rc=0
    else
      unsafe_rc=$?
    fi
    assert_true "sync rejects a dangling Codex config symlink outside its config directory" "unsafe symlink sync unexpectedly succeeded" test "$unsafe_rc" -ne 0
    assert_true "unsafe dangling Codex config symlink is preserved" "unsafe config symlink was replaced" test -L "$CODEX_UNSAFE_LINK"
    assert_true "unsafe dangling symlink target is not created" "unsafe target was written" test ! -e "$CODEX_UNSAFE_TARGET"

    CODEX_NESTED_TARGET="$WORK/outside/nested-target.json"
    CODEX_NESTED_LINK="$WORK/codex/nested-link.json"
    CODEX_NESTED_CONFIG="$WORK/codex/config-nested-dangling.json"
    ln -s "$CODEX_NESTED_TARGET" "$CODEX_NESTED_LINK"
    ln -s "$CODEX_NESTED_LINK" "$CODEX_NESTED_CONFIG"
    if bash "$SYNC" --source "$SOURCE" --destination "$CODEX_HOOKS" \
        --config "$CODEX_NESTED_CONFIG" --provider codex >/dev/null 2>&1; then
      nested_rc=0
    else
      nested_rc=$?
    fi
    assert_true "sync rejects a chained dangling Codex config symlink" "nested symlink sync unexpectedly succeeded" test "$nested_rc" -ne 0
    assert_true "chained dangling Codex config symlink is preserved" "nested config symlink was replaced" test -L "$CODEX_NESTED_CONFIG"
    assert_true "chained dangling symlink target is not created" "nested unsafe target was written" test ! -e "$CODEX_NESTED_TARGET"

    rm -f "$CODEX_HOOKS/.toolbox-hook-manifest"
    # A symlinked manifest whose target is empty exercises the defensive
    # empty-manifest path while proving the synchronizer does not replace it.
    ln -s /dev/null "$CODEX_HOOKS/.toolbox-hook-manifest"
    EMPTY_CONFIG="$WORK/codex/empty-manifest-config.json"
    cat > "$EMPTY_CONFIG" <<JSON
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash $CODEX_HOOKS/guard.sh"},{"type":"command","command":"echo keep-empty-manifest"}]}]}}
JSON
    if bash "$SYNC" --source "$SOURCE" --destination "$CODEX_HOOKS" \
        --config "$EMPTY_CONFIG" --provider codex >/dev/null 2>&1; then
      empty_manifest_rc=0
    else
      empty_manifest_rc=$?
    fi
    assert_true "syncing with an empty Codex manifest completes" "empty-manifest sync exited $empty_manifest_rc" test "$empty_manifest_rc" -eq 0
    if [ "$empty_manifest_rc" -eq 0 ]; then
      assert_true "empty-manifest symlink is preserved" "manifest symlink was replaced" test -L "$CODEX_HOOKS/.toolbox-hook-manifest"
      assert_contains "empty-manifest unproven hook registration is preserved" 'guard.sh' "$EMPTY_CONFIG"
      assert_contains "empty-manifest unrelated hook is preserved" 'keep-empty-manifest' "$EMPTY_CONFIG"
    fi
    rm -f "$CODEX_HOOKS/.toolbox-hook-manifest"
    printf 'first.sh\nsecond.sh\n' > "$CODEX_HOOKS/.toolbox-hook-manifest"
  fi
fi

UNINSTALL_CONFIG="$WORK/codex/uninstall-config.json"
cat > "$UNINSTALL_CONFIG" <<JSON
{
  "hooks": {
    "PreToolUse": [{"matcher":"Bash","hooks":[
      {"type":"command","command":"bash $CODEX_HOOKS/first.sh"},
      {"type":"command","command":"echo keep-in-shared-matcher"},
      {"type":"command","command":"bash $CODEX_HOOKS/first.sh-wrapper"}
    ]}],
    "PostToolUse": [{"matcher":"Write","hooks":[
      {"type":"command","command":"bash $CODEX_HOOKS/second.sh"}
    ]}],
    "CustomEvent": [{"matcher":"*","hooks":[
      {"type":"command","command":"bash $CODEX_HOOKS/not-owned.sh"}
    ]}]
  },
  "custom": {"keep": true}
}
JSON
printf 'first.sh\nsecond.sh\n' > "$WORK/codex/uninstall-manifest"
if PROVIDER_HOOK_CONFIG="$UNINSTALL_CONFIG" PROVIDER_HOOKS_ROOT="$CODEX_HOOKS" \
    PROVIDER_HOOK_MANIFEST="$WORK/codex/uninstall-manifest" node "$REMOVE"; then
  uninstall_rc=0
else
  uninstall_rc=$?
fi
assert_true "provider hook removal helper completes" "removal exited $uninstall_rc" test "$uninstall_rc" -eq 0
if [ "$uninstall_rc" -eq 0 ]; then
  assert_true "uninstall removes manifest-owned first hook entry" "first hook remained" bash -c '! jq -r '\''.. | objects | .command? // empty'\'' "$1" | grep -Fxq "$2"' _ "$UNINSTALL_CONFIG" "bash $CODEX_HOOKS/first.sh"
  assert_true "uninstall removes manifest-owned second hook entry" "second hook remained" bash -c '! jq -r '\''.. | objects | .command? // empty'\'' "$1" | grep -Fxq "$2"' _ "$UNINSTALL_CONFIG" "bash $CODEX_HOOKS/second.sh"
  assert_contains "uninstall preserves unrelated hook sharing a matcher" 'keep-in-shared-matcher' "$UNINSTALL_CONFIG"
  assert_contains "uninstall preserves unowned hook paths" 'not-owned.sh' "$UNINSTALL_CONFIG"
  assert_contains "uninstall preserves hook-name prefixes" 'first.sh-wrapper' "$UNINSTALL_CONFIG"
  assert_contains "uninstall preserves unrelated settings" '"custom"' "$UNINSTALL_CONFIG"
fi
assert_contains "Windows config replacement path is implemented" 'process.platform === '\''win32'\''' "$SYNC"
assert_contains "uninstall preserves Codex state without ownership proof" 'No Codex hook ownership manifest found' "$ROOT/scripts/uninstall.sh"

LEGACY_HOME="$WORK/legacy-home"
LEGACY_CODEX="$LEGACY_HOME/.codex"
mkdir -p "$LEGACY_HOME/.claude" "$LEGACY_CODEX/hooks"
printf '#!/usr/bin/env bash\nexit 0\n' > "$LEGACY_CODEX/hooks/enforce-loop-bounds.sh"
cat > "$LEGACY_CODEX/hooks.json" <<JSON
{
  "hooks": {
    "PreToolUse": [
      {"matcher":"Bash","hooks":[
        {"type":"command","command":"bash $LEGACY_CODEX/hooks/enforce-loop-bounds.sh"},
        {"type":"command","command":"echo keep-legacy-user-hook"}
      ]}
    ]
  },
  "custom": {"keep": true}
}
JSON
if printf 'yes\nno\n' | HOME="$LEGACY_HOME" CODEX_HOME="$LEGACY_CODEX" bash "$ROOT/scripts/uninstall.sh" > "$WORK/legacy-uninstall.log" 2>&1; then
  legacy_rc=0
else
  legacy_rc=$?
fi
assert_true "uninstall handles a missing Codex manifest" "legacy uninstall exited $legacy_rc: $(tail -30 "$WORK/legacy-uninstall.log")" test "$legacy_rc" -eq 0
if [ "$legacy_rc" -eq 0 ]; then
  assert_contains "missing-manifest uninstall preserves unknown registration" 'enforce-loop-bounds.sh' "$LEGACY_CODEX/hooks.json"
  assert_contains "missing-manifest uninstall preserves user hook" 'keep-legacy-user-hook' "$LEGACY_CODEX/hooks.json"
  assert_true "missing-manifest uninstall preserves host hook files" "host hook file was deleted" test -f "$LEGACY_CODEX/hooks/enforce-loop-bounds.sh"
fi

echo "provider-neutral managed hook sync: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
