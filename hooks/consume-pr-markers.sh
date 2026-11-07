#!/bin/bash
# consume-pr-markers.sh
#
# PostToolUse hook matching on the Bash tool.
# Consumes the single-use PR-creation gate markers — but ONLY after a
# `gh pr create` that actually succeeded.
#
# Why this exists (the "gates fail in rotation" deadlock):
#   enforce-pr-skill.sh (.pr-skill-invoked) and enforce-compliance-audit.sh
#   (.audit-complete) are PreToolUse gates that USED to delete their marker on
#   the allow path. But PreToolUse runs BEFORE the command. When several gates
#   guard the same `gh pr create`, a DENY by ANY one of them (e.g. enforce-codex-
#   review rejecting a `cd`) meant the command never ran — yet the gates that
#   passed had already consumed their markers, so the retry needed a full
#   re-invoke/re-audit and the gates kept failing in rotation, never all green
#   on one attempt (~6 wasted subagent spawns on PR #96).
#
#   Fix: the PreToolUse gates no longer delete on allow (a DENY is now idempotent).
#   Single-use is enforced HERE instead — this PostToolUse hook deletes the two
#   markers only after a `gh pr create` whose output proves a PR was created. A
#   second PR in the same session therefore still requires a fresh skill invoke +
#   audit, exactly as before, but without the rotation deadlock.
#
#   The Codex marker (.codex-review-complete) is NOT consumed here — it is HEAD-
#   keyed and already idempotent (enforce-codex-review.sh), so it needs no
#   success-gated cleanup.
#
# Detection mirrors auto-poll-after-pr.sh: a successful `gh pr create` prints the
# new PR URL (https://github.com/<owner>/<repo>/pull/<n>) to stdout. No URL =>
# the create did not succeed (blocked, errored, dry-run, or a non-create command)
# => markers are LEFT INTACT so the next attempt can still pass the gates.
#
# Accepted residual (documented, LOW — workflow-discipline gate, not an
# adversarial sandbox): success is detected from the hook payload's
# `.tool_result.stdout`, so a create whose stdout was REDIRECTED to a file
# (`gh pr create > out`) prints no URL to the captured stream and the markers
# are NOT consumed — they persist and could satisfy a LATER PR in the same
# session (or a future session) without a fresh skill/audit. Same class: a
# session abandoned after the markers were written but before a successful
# create. We deliberately do NOT close this by consuming on ANY executed
# `gh pr create` regardless of output — that would re-break RC2: a create that
# RAN but transiently FAILED (network blip, "PR already exists") would consume
# the markers and force a needless re-audit on retry. And we do NOT HEAD-key
# the `.audit-complete`/`.pr-skill-invoked` markers (the obvious alternative):
# the Codex pre-PR pass (finishing-a-development-branch Step 3.6) can apply
# fixes that ADVANCE HEAD between the audit and `gh pr create`, so a HEAD-keyed
# audit marker would false-block and REINTRODUCE a deadlock. The toolbox's own
# PR path always runs a PLAIN `gh pr create` (no redirect), the first PR is
# always fully gated, and the worst case here is a weakened single-use (a
# SECOND PR reusing markers), never a no-audit PR — so the residual is accepted
# rather than fixed at the cost of the deadlock it would create.
#
# Conversely, a COMPOUND command can OVER-consume: `gh pr create || echo <pr-url>`
# (or `gh pr create ; echo <pr-url>`) puts a PR URL into the captured stdout even
# when the `gh pr create` itself FAILED, so the markers get consumed and the next
# attempt must re-run skill+audit. That is the SAFE direction — it forces an EXTRA
# audit, never a SKIPPED one (PostToolUse has no per-segment exit code to tell a
# failed-then-echoed URL from a real one). Banning `||`/`;` to close it would TRADE
# it for the harmful direction: a legitimate `gh pr create ; echo done` success
# would then NOT consume, leaving markers to linger. The toolbox's own flow always
# runs a PLAIN `gh pr create`, so neither case fires in practice — both stay
# documented fail-safe residuals rather than fragile, edge-trading detection.
#
# The HEAD-keyed Codex gate (enforce-codex-review.sh) independently still re-requires
# a review when HEAD changes.

set -euo pipefail

# PostToolUse cleanup is best-effort; without jq we simply skip it (no enforcement
# decision is made here, so failing-open is safe — worst case a marker lingers and
# is reused by a later create in the same session, which is the pre-fix behaviour).
if ! command -v jq &>/dev/null; then
  exit 0
fi

HOOK_DATA=$(cat)

TOOL_NAME=$(echo "$HOOK_DATA" | jq -r '.tool_name // empty')
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

COMMAND=$(echo "$HOOK_DATA" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
STDOUT=$(echo "$HOOK_DATA" | jq -r '.tool_result.stdout // empty' 2>/dev/null || echo "")

# Only act on a real `gh pr create` token. This MUST stay in step with the
# detector the four gate hooks use (enforce-codex-review, enforce-compliance-
# audit, enforce-fable-review, enforce-pr-skill) — this file CONSUMES the
# markers those gates set, so a shape they recognise and this one does not
# leaves the marker armed.
#
# It did not stay in step. The C2 widening landed in those four files and not
# in this one, while this comment still claimed "same anchored boundary as the
# gate hooks". Measured consequence: `gh --repo O/R pr create` — the spelling
# rules/git-workflow.md prescribes for /review-pr, i.e. the COMMON path — was
# gated but never consumed. `.pr-skill-invoked` is session-scoped (3600s, not
# sha-bound), so it stayed armed and the NEXT PR within the hour skipped
# enforce-pr-skill without re-invoking the skill.
#
# here-string (NOT printf|grep) to avoid the pipefail SIGPIPE bypass
# documented in enforce-pr-skill.sh.
# ⛔ THE TWO FAILURE DIRECTIONS ARE NOT SYMMETRIC, AND THAT DECIDES THE SHAPE. ⛔
#     over-consume a READ   -> the next PR re-runs the skill and the audit.
#                              Friction, and SAFE.
#     under-consume a CREATE -> the next PR SKIPS them. A FAIL-OPEN.
# An earlier revision added an explicit POST requirement to stop a read (`gh api
# /repos/O/R/pulls`, whose list body carries html_url) from consuming the markers.
# It bought the safe-direction friction at the cost of the unsafe one, and did not
# even close the read case. Measured on it:
#   MISSED  gh api /repos/O/R/pulls -f title=x -f head=h   <- a REAL create; gh
#           defaults to POST whenever -f is present, so the markers stayed armed
#   MISSED  --method=POST and -XPOST spellings
#   STILL CONSUMED  gh api /repos/O/R/pulls --paginate; echo --method POST
#           because the three greps each scanned the WHOLE command independently
# So it is reverted. The read case is an ACCEPTED residual: a read of the pulls
# collection between a create and the next PR consumes the markers and costs one
# re-invocation of the skill and one re-run of the audit. That is the direction to
# fail in. Closing it properly needs to know which gh invocation actually created
# the PR, which the command text alone cannot tell us.
# TC-CPM-8 pins the GraphQL arm; TC-CPM-9 pins the -f create that the POST
# requirement broke, so the regression cannot come back.
# ⛔ BOTH SPELLINGS, BECAUSE BOTH GATES RECOGNISE BOTH. ⛔
# The four gate hooks recognise TWO ways to open a PR: the `pr create` token
# sequence AND `gh api` against the pulls collection (or the createPullRequest
# GraphQL mutation). This consumer recognised only the first, so a PR opened the
# api way was gated by all four and consumed by none — leaving `.pr-skill-invoked`
# and `.audit-complete` armed, so the NEXT PR within the session skipped those
# gates without re-invoking the skill or re-running the audit.
# That is the asymmetry class this branch exists to close, in the same file that
# had already been fixed once for the `pr create` half. Cross-family review
# (Codex) caught the api half. Condition copied VERBATIM from enforce-pr-skill.sh
# — do not hand-write an equivalent. SCOPE OF THAT PIN, stated rather than implied:
# TC-PRC-IDENT5's extractor keys on `create(`, so it asserts byte-identity of the
# CREATE detector across the five files and does NOT cover the api detector below
# it. The api half is pinned FUNCTIONALLY instead, by TC-CPM-5/6. Measured today:
# all five files carry identical text for both. A comment crediting a test with
# more than it asserts is the overclaim class this file is full of corrections for.
if ! grep -qE '(^|[;&|()`[:space:]])(["]([^[:space:];&|()]*/)?gh["]|'"'"'([^[:space:];&|()]*/)?gh'"'"'|([^[:space:];&|()]*/)?gh)([[:space:]]+-[^[:space:];&|()]*([[:space:]]+[^-[:space:];&|()][^[:space:];&|()]*)?)*[[:space:]]+(["]pr["]|'"'"'pr'"'"'|pr)([[:space:]]+-[^[:space:];&|()]*([[:space:]]+[^-[:space:];&|()][^[:space:];&|()]*)?)*[[:space:]]+(["]create["]|'"'"'create'"'"'|create)([[:space:];&|()<>`"'"'"']|$)' <<< "$COMMAND" \
   && ! { grep -qE '(^|[;&|()`[:space:]])(["]([^[:space:];&|()]*/)?gh["]|'"'"'([^[:space:];&|()]*/)?gh'"'"'|([^[:space:];&|()]*/)?gh)([[:space:]]+-[^[:space:];&|()]*([[:space:]]+[^-[:space:];&|()][^[:space:];&|()]*)?)*[[:space:]]+(["]api["]|'"'"'api'"'"'|api)([[:space:]]|$)' <<< "$COMMAND" \
          && grep -qE '(^|[^[:alnum:]_])repos/[^[:space:]/;&|()]+/[^[:space:]/;&|()]+/pulls([^[:alnum:]_/]|$)|createPullRequest' <<< "$COMMAND"; }; then
  exit 0
fi

# Require proof the PR was actually created: a PR URL in stdout. A blocked or
# failed create prints no URL, so we keep the markers intact for the retry.
if ! grep -qE 'https://github\.com/[^[:space:]]+/pull/[0-9]+' <<< "$STDOUT"; then
  exit 0
fi

# Success — consume the single-use markers. State dir mirrors the gate hooks
# (CLAUDE_STATE_DIR override for tests; defaults to $HOME/.claude).
STATE_DIR="${CLAUDE_STATE_DIR:-$HOME/.claude}"
rm -f "$STATE_DIR/.pr-skill-invoked" "$STATE_DIR/.audit-complete"

exit 0
