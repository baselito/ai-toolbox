#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTER="$SCRIPT_DIR/register-pr-poll.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

assert_fail() {
  if "$@" >/dev/null 2>&1; then
    echo "FAIL: expected command to fail: $*" >&2
    exit 1
  fi
}

mkdir -p "$TEST_ROOT/state"
printf 'baselito/ai-engineering 181\n' > "$TEST_ROOT/state/.auto-poll-pending"
(cd "$TEST_ROOT" && AI_ENGINEERING_STATE_DIR="$TEST_ROOT/state" "$REGISTER" \
  --repo baselito/ai-engineering --pr 181 --provider codex --poll-id monitor-ai-engineering-pr-181)

POLL_FILE="$TEST_ROOT/state/.pr-baselito-ai-engineering-181-cron-id"
grep -qx 'provider=codex' "$POLL_FILE"
grep -qx 'poll_id=monitor-ai-engineering-pr-181' <(sed -n '2p' "$POLL_FILE")
[[ ! -e "$TEST_ROOT/state/.auto-poll-pending" ]]

printf 'baselito/ai-engineering 181\n' > "$TEST_ROOT/state/.auto-poll-pending"
(cd "$TEST_ROOT" && AI_ENGINEERING_STATE_DIR="$TEST_ROOT/state" "$REGISTER" \
  --repo baselito/ai-engineering --pr 181 --provider claude --poll-id cron-181)
grep -qx 'provider=claude' "$POLL_FILE"
grep -qx 'poll_id=cron-181' <(sed -n '2p' "$POLL_FILE")

# A stale registration for the same PR is replaced atomically, so a provider
# switch cannot leave the next poller using the old identity.
printf 'provider=codex\npoll_id=stale-181\nregistered_at=2000-01-01T00:00:00Z\n' > "$POLL_FILE"
(cd "$TEST_ROOT" && AI_ENGINEERING_STATE_DIR="$TEST_ROOT/state" "$REGISTER" \
  --repo baselito/ai-engineering --pr 181 --provider claude --poll-id fresh-181)
grep -qx 'provider=claude' "$POLL_FILE"
grep -qx 'poll_id=fresh-181' <(sed -n '2p' "$POLL_FILE")

printf 'baselito/ai-engineering 181\n' > "$TEST_ROOT/state/.auto-poll-pending"
(cd "$TEST_ROOT" && AI_ENGINEERING_STATE_DIR="$TEST_ROOT/state" "$REGISTER" \
  --repo baselito/ai-engineering --pr 182 --provider codex --poll-id heartbeat-182)
[[ -e "$TEST_ROOT/state/.auto-poll-pending" ]]

# A registration invoked outside Git must not consume a structured marker bound
# to a different originating checkout.
cat > "$TEST_ROOT/state/.auto-poll-pending-structured" <<EOF
repo=baselito/ai-engineering
pr=183
worktree=$TEST_ROOT/owning-checkout
head=sha
EOF
(cd "$TEST_ROOT" && AI_ENGINEERING_STATE_DIR="$TEST_ROOT/state" "$REGISTER" \
  --repo baselito/ai-engineering --pr 183 --provider codex --poll-id heartbeat-183 >/dev/null)
[[ -e "$TEST_ROOT/state/.auto-poll-pending-structured" ]]

# During migration, a legacy marker may coexist with the owning structured
# marker. Registration from the owner clears only the bound marker; the
# unbound legacy marker is preserved because its originating checkout cannot be
# proven during migration.
mkdir -p "$TEST_ROOT/owning-checkout"
git -C "$TEST_ROOT/owning-checkout" init -q
cat > "$TEST_ROOT/state/.auto-poll-pending-structured-owner" <<EOF
repo=baselito/ai-engineering
pr=184
worktree=$(cd "$TEST_ROOT/owning-checkout" && pwd -P)
head=sha
EOF
printf 'baselito/ai-engineering 184\n' > "$TEST_ROOT/state/.auto-poll-pending"
(cd "$TEST_ROOT/owning-checkout" && AI_ENGINEERING_STATE_DIR="$TEST_ROOT/state" "$REGISTER" \
  --repo baselito/ai-engineering --pr 184 --provider codex --poll-id heartbeat-184 >/dev/null)
[[ ! -e "$TEST_ROOT/state/.auto-poll-pending-structured-owner" ]]
[[ -e "$TEST_ROOT/state/.auto-poll-pending" ]]

assert_fail env AI_ENGINEERING_STATE_DIR="$TEST_ROOT/state" "$REGISTER" \
  --repo 'baselito/ai-engineering;touch' --pr 181 --provider codex --poll-id bad
assert_fail env AI_ENGINEERING_STATE_DIR="$TEST_ROOT/state" "$REGISTER" \
  --repo baselito/ai-engineering --pr 181 --provider codex --poll-id '$(touch-poll)'

# Keep the provider-neutral registrar suite in the repository's health gate.
# Without this check, the suite can remain green while verify.sh silently
# stops executing it after a test-list edit.
VERIFY_SCRIPT="$SCRIPT_DIR/verify.sh"
if ! grep -Fq 'test-register-pr-poll.sh' "$VERIFY_SCRIPT"; then
  echo "FAIL: verify.sh does not execute test-register-pr-poll.sh" >&2
  exit 1
fi

echo "register-pr-poll: all tests passed"
