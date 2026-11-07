#!/bin/bash
# enforce-pr-skill.sh
#
# PreToolUse hook matching on the Bash tool.
# Blocks `gh pr create` commands unless the finishing-a-development-branch
# skill was invoked in the current session first.
#
# Why: The main agent can spawn an Opus subagent with [DELEGATED] but
# write the entire PR body inline in the prompt — bypassing the skill
# entirely. The skill's template (What this changes / Why this matters /
# What was built / Key decisions) never loads. This hook forces the skill
# to be invoked so its content enters the subagent's context.
#
# Detection:
#   Marker file ~/.claude/.pr-skill-invoked (created by the skill) is the
#   ONLY gate. No transcript fallback — see "NO TRANSCRIPT FALLBACK"
#   comment block below for why.

set -euo pipefail

# Guard: ensure jq is available. Fail CLOSED — see enforce-auto-poll.sh.
if ! command -v jq &>/dev/null; then
  cat <<'__DENY__'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: jq is required for hook enforcement (enforce-pr-skill). Install jq (brew install jq / apt install jq / yum install jq) to continue. Hook fails closed for safety."}}
__DENY__
  exit 0
fi

# Read hook input from stdin
HOOK_DATA=$(cat)

TOOL_NAME=$(echo "$HOOK_DATA" | jq -r '.tool_name // empty')

# Only apply to Bash tool calls
if [[ "$TOOL_NAME" != "Bash" ]]; then
  exit 0
fi

# Extract the command being run
COMMAND=$(echo "$HOOK_DATA" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")

# Only gate an actual `gh pr create` token sequence — not arbitrary text that
# merely CONTAINS those words (a quote-adjacent string, a grep pattern). Anchor
# `gh` at a command boundary (start, or after a separator/subshell/whitespace)
# and require a boundary after `create` too — including shell
# metacharacters/redirections so real metachar-trailing forms
# (`gh pr create;`/`&&`/`)`/`>file`) stay gated. A real command token is never
# followed directly by a letter, so `gh pr createfoo` does NOT match, and a
# quote-adjacent mention (`echo "gh pr create"`) is not gated. Uses the same
# anchored regex as enforce-codex-review.sh (added in PR #77; this fix ports it
# to the sibling hooks); the bare-substring version caused false-positive blocks
# of legitimate commands that merely echoed/quoted the phrase.
#
# Matched with a here-string (`<<<`), NOT `printf | grep`: under `set -o
# pipefail`, `printf "$COMMAND" | grep -qE` can return non-zero even on a MATCH
# when the command is large/multi-line — `grep -q` matches an early line and
# exits, `printf` then dies with SIGPIPE (141), pipefail propagates the 141, and
# the `if !` negation wrongly takes the allow path → gate BYPASSED (Codex
# pre-PR review). A here-string has no upstream process to SIGPIPE, so the match
# is reliable. (enforce-codex-review.sh now uses the same here-string idiom —
# its cd/pushd/popd and --repo/-R detectors were the last pipe-form holdouts,
# fixed in the hook-safety audit batch and guarded by TC-ECR-25.)
#
# Documented residual (fail-safe): a phrase surrounded by whitespace/newlines or
# separators mid-string (`echo see gh pr create here`, or a heredoc body line
# that is just `gh pr create`) STILL matches — spaces/newlines look like command
# boundaries, and a non-token-aware regex can't tell quoted prose from a real
# token without a shell parser. This over-blocks (recoverable: rephrase / write
# to a file) rather than under-blocks (a real PR slipping the gate) — the safe
# direction for a gate.
#
# Inverse residual (accepted, automated-review PR #78): conversely, a command whose NAME
# is quoted or backtick-wrapped (`"gh" pr create`, `` `gh pr create` ``) is NOT
# gated, because `"` and backtick are deliberately EXCLUDED from the boundary
# class. Including them to catch those adversarial forms would re-over-block
# realistic prose — `echo "gh pr create"` and, very commonly, a markdown
# `` `gh pr create` `` mention inside a PR `--body` — which is the exact
# false-positive this PR removes. The two directions are irreducible without a
# shell parser. This gate's scope is workflow-discipline (stop the agent's
# NORMAL plain `gh pr create` from skipping review), NOT an adversarial sandbox:
# anyone who can run arbitrary Bash can already delete the hook or forge the
# marker, so a deliberately quote/backtick-evaded invocation is out of scope.
# (automated-review accepted this same reasoning on enforce-codex-review.sh, PR #77.)
# HEREDOC SUB-LAYER REMOVED (PR #128): earlier revisions stripped heredoc
# BODY text out of the command before this anchor check (a `_hd_*` state
# machine distinguishing "executable" vs "content" heredocs, plus a live
# command-substitution span extractor). That sub-layer kept producing
# both-direction parser bugs — a real `gh pr create` hidden in a heredoc body
# escaped the gate (under-block) while inert prose false-blocked (over-block).
# It is gone: detection now runs on the FULL raw $COMMAND, so a `gh pr create`
# at a line boundary INSIDE a heredoc body BLOCKS (an over-block — the SAFE
# direction for a workflow-discipline gate). ACCEPTED RESIDUAL: a DATA heredoc
# that merely spells the phrase at a line start false-blocks; re-word it or
# write it to a file. The backtick in the boundary class below only ever ADDS
# matches (same fail-safe direction), so it stays.
# C2 — the two detector lines below are byte-identical to
# enforce-codex-review.sh's, the canonical copy, and TC-PRC-IDENT asserts it.
# Between them they recognise three shapes rather than one: a PATH-qualified
# `gh` (`/opt/homebrew/bin/gh pr create`), flag groups INTERSPERSED between the
# three tokens (`gh --repo O/R pr create`, which is the spelling
# rules/git-workflow.md itself instructs for /review-pr), and a `gh api` call
# against the pulls COLLECTION or the createPullRequest GraphQL mutation. All
# six spellings reached a real PR with zero deny from any of the four gates
# before this. Full argument and the named residuals: enforce-codex-review.sh.
if ! grep -qE '(^|[;&|()`[:space:]])(["]([^[:space:];&|()]*/)?gh["]|'"'"'([^[:space:];&|()]*/)?gh'"'"'|([^[:space:];&|()]*/)?gh)([[:space:]]+-[^[:space:];&|()]*([[:space:]]+[^-[:space:];&|()][^[:space:];&|()]*)?)*[[:space:]]+(["]pr["]|'"'"'pr'"'"'|pr)([[:space:]]+-[^[:space:];&|()]*([[:space:]]+[^-[:space:];&|()][^[:space:];&|()]*)?)*[[:space:]]+(["]create["]|'"'"'create'"'"'|create)([[:space:];&|()<>`"'"'"']|$)' <<< "$COMMAND" \
   && ! { grep -qE '(^|[;&|()`[:space:]])(["]([^[:space:];&|()]*/)?gh["]|'"'"'([^[:space:];&|()]*/)?gh'"'"'|([^[:space:];&|()]*/)?gh)([[:space:]]+-[^[:space:];&|()]*([[:space:]]+[^-[:space:];&|()][^[:space:];&|()]*)?)*[[:space:]]+(["]api["]|'"'"'api'"'"'|api)([[:space:]]|$)' <<< "$COMMAND" \
          && grep -qE '(^|[^[:alnum:]_])repos/[^[:space:]/;&|()]+/[^[:space:]/;&|()]+/pulls([^[:alnum:]_/]|$)|createPullRequest' <<< "$COMMAND"; }; then
  exit 0
fi

# THE STATE ROOT MUST RESOLVE FIRST. With neither variable set, the expansion
# below is an unbound-variable abort under `set -u`: exit 1, no JSON, gate
# fails OPEN — the single input class "the environment carried no home
# directory" disarmed ELEVEN registered PreToolUse gates at once — not five.
# The first fix round guarded five and stopped; the other six (push-safety,
# pr-action-safety, enforce-jira-delegation, enforce-chief-of-staff,
# enforce-workflow-start, enforce-transition-script) were measured in the
# identical class and guarded a round later. `-z` covers unset AND
# empty, which are different bugs. Canonical copy and full rationale:
# enforce-fable-review.sh.
if [[ -z "${CLAUDE_STATE_DIR:-}" && -z "${HOME:-}" ]]; then
  cat <<'__DENY__'
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "BLOCKED: neither HOME nor CLAUDE_STATE_DIR is set, so enforce-pr-skill cannot locate the state directory its skill marker lives in. A gate that cannot find its own evidence has not been satisfied, so it fails closed.\n\nThis cannot be fixed from inside a Bash tool call — every call is a fresh shell, so an `export` here does not survive to the next one. Set HOME (or CLAUDE_STATE_DIR) in the environment the agent itself runs in — the `env` block of ~/.claude/settings.json, or the container/CI environment — and start a new session."}}
__DENY__
  exit 0
fi

# Check for marker file — the skill creates this when invoked.
# State directory: defaults to $HOME/.claude/ (outside any repo). Can be
# overridden via CLAUDE_STATE_DIR for testing.
STATE_DIR="${CLAUDE_STATE_DIR:-$HOME/.claude}"
# ⛔ A NON-EMPTY STATE ROOT IS NOT A RESOLVED ONE. ⛔
# The check above only proves the two variables are not BOTH empty. Three
# input classes still walk straight past it, and each one lands the gate in
# the same place: the marker read below misses, and a gate that reads "no
# evidence" as "nothing to enforce" fails OPEN.
#   * CLAUDE_STATE_DIR=/missing  — non-empty, so the emptiness check passes,
#     and every marker path under it is unopenable.
#   * HOME=/nonexistent          — same shape via the default branch.
#   * CLAUDE_STATE_DIR=.         — the WORST of the three, and the reason a
#     mere existence check is not enough: a relative root resolves against
#     THIS COMMAND'S working directory, so a token or marker committed into
#     any repo the agent merely reads would satisfy the gate. That is not a
#     missing state root, it is an attacker-supplied one.
# So the RESOLVED root must be absolute, an existing directory, and readable
# AND searchable — and the deny must name WHICH of those failed, or the reader
# has to re-check all three to find out what to fix.
#
# ⛔ NO jq IN THIS BLOCK, DELIBERATELY. ⛔ In enforce-auto-poll this guard runs
# BEFORE the jq-availability check, so a jq-built deny would print nothing and
# exit 0 on an image without jq — a silent ALLOW, emitted by the guard whose
# entire purpose is failing closed. The JSON is built with parameter expansion
# and printf instead. The path is interpolated into the message, so it is
# JSON-escaped first: a backslash or a double quote in it would otherwise
# truncate the deny into unparseable output, which the harness also reads as
# no-decision. The message carries no backtick for the same class of reason —
# inside the double-quoted printf argument a backtick would EXECUTE.
SR_WHY=""
# ⛔ THIS TEST RUNS FIRST BECAUSE IT IS ABOUT THE STRING, NOT THE DISK. ⛔
# It was the LAST arm of this chain, which meant it only ran when the root
# was absolute AND existed AND was readable - so the ordinary unsafe case, a
# root that does not exist, was answered by the `! -d` arm and never reached
# the character test at all. Measured at c4d765a:
#   CLAUDE_STATE_DIR='/tmp/nonexistent-x$(id)/.claude' -> "does not exist"
# Whether a path can be safely printed does not depend on whether it exists,
# so ordering it after an existence check was the defect. First position also
# makes it order-INDEPENDENT: no arm added above can shadow it again.
if [[ -n "${STATE_DIR//[A-Za-z0-9\/._+@,=: -]/}" ]]; then
  SR_WHY="contains a character this gate cannot put in the remedy it prints - the denies below interpolate the resolved root into copyable shell commands, and a substitution, glob, quote or separator there would execute or expand instead of naming the directory"
elif [[ "$STATE_DIR" != /* ]]; then
  SR_WHY="is RELATIVE, so every marker path below would resolve against this command's working directory rather than a trusted state root"
elif [[ ! -d "$STATE_DIR" ]]; then
  SR_WHY="does not exist, or is not a directory, so the marker this gate reads can never be found there"
elif [[ ! -r "$STATE_DIR" || ! -x "$STATE_DIR" ]]; then
  SR_WHY="is not readable and searchable by this process, so the marker this gate reads cannot be opened"
# ⛔ A ROOT THIS GATE CANNOT NAME IN ITS OWN REMEDY IS NOT A USABLE ROOT. ⛔
# Every deny below interpolates the resolved root into a command the reader is
# meant to COPY AND RUN (`touch <root>/.token`, `date +%s > <root>/...`). The
# JSON escaping above makes the message parseable; it does nothing about the
# SHELL. So a root spelled /tmp/x$(id) printed a remedy that ran `id` when
# pasted, and /tmp/a*b printed one whose glob expands to some other directory
# - the H1 "remedy nobody can follow" class this branch has fixed twice, one
# layer further out. Rejecting the root is chosen over shell-quoting the
# remedy on purpose: the quoted spelling would then have to be taught to
# enforce-auto-poll's four path-pinned allowlist branches in the same change,
# and a gate whose allowlist refuses the string it prints is the same trap
# from the other side.
#
# The test is a WHITELIST - strip every character that is safe in a shell word
# and see whether anything is left - because the reject-list form has to be
# complete to be correct, and this file's own history records two classes that
# "excluded every metacharacter" and did not. `/` is BACKSLASH-ESCAPED inside
# the class: in ${var//pattern/repl} bash splits on the first unquoted `/`, so
# a bare one silently ends the pattern and makes the rest of the class the
# replacement text - measured, it stripped nothing at all.
#
# NAMED RESIDUAL (rules/security.md item 7): SPACE is in the safe set. A root
# with a space still prints a remedy that word-splits, but it names a wrong
# path rather than executing anything, and /Users/<First Last> is a real macOS
# home - rejecting it would hard-block every gate for that user. Fixing that
# half needs the quoted spelling, and so the allowlist change above.
# Tracked as issue #170, which carries the measurement, the full list of
# allowlist sites that must move in lockstep, and the two candidate designs.
fi
if [[ -n "$SR_WHY" ]]; then
  SR_PATH=${STATE_DIR//\\/\\\\}
  SR_PATH=${SR_PATH//\"/\\\"}
  # ⛔ NEWLINE, CR AND TAB ARE THREE OF THIRTY-TWO. ⛔ This escaping used to
  # name those three and stop. Every other C0 control character - form feed,
  # vertical tab, backspace, ESC - is legal in a Unix directory name and is
  # ILLEGAL raw inside a JSON string, so one of them in the resolved root made
  # THIS deny unparseable. Measured at 5b94753 with
  # CLAUDE_STATE_DIR=/nonexistent<FF>state: the hook printed its deny and exited
  # 0, and both jq and python refused the output ("control characters from
  # U+0000 through U+001F must be escaped"). The harness reads unparseable
  # output as NO DECISION, so the fail-closed guard became a silent ALLOW - the
  # exact shape this branch exists to close, in the guard written to close it.
  # One bracket expression covers all thirty-two and cannot drift out of sync
  # the way an enumeration does; [[:cntrl:]] works on bash 3.2.57, the floor
  # this repo targets. Replaced with a SPACE rather than \b/\f escapes because
  # the path here is diagnostic text, not data to be round-tripped.
  SR_PATH=${SR_PATH//[[:cntrl:]]/ }
  printf '%s\n' "{\"hookSpecificOutput\": {\"hookEventName\": \"PreToolUse\", \"permissionDecision\": \"deny\", \"permissionDecisionReason\": \"BLOCKED: the resolved Claude state root ${SR_PATH} ${SR_WHY}. A gate that cannot read its own evidence has not been satisfied, so it fails closed.\\n\\nThe root is CLAUDE_STATE_DIR when that is set, and HOME/.claude otherwise. Point CLAUDE_STATE_DIR at an existing absolute directory, or unset it so HOME/.claude is used, in the environment the agent itself runs in — the env block of the Claude settings file, or the container/CI environment — and start a new session. An export from inside a Bash tool call does not survive to the next call, so this cannot be fixed from a Bash command.\"}}"
  exit 0
fi


MARKER_FILE="$STATE_DIR/.pr-skill-invoked"

# STALENESS GATE. The marker is only consumed on a SUCCESSFUL `gh pr create`
# (PostToolUse consume-pr-markers.sh), so a PR attempt DENIED by a sibling gate and
# never retried leaves it behind forever — observed in practice: a 13.8-day-old,
# zero-byte .pr-skill-invoked was still satisfying this gate, letting a later
# `gh pr create` skip the skill entirely and write the PR body from memory (exactly
# the low-quality-summary failure this hook exists to prevent).
#
# Anything older than MAX_MARKER_AGE is treated as absent. 3600s matches the
# session-token window in enforce-jira-delegation.sh: long enough to survive gates
# failing in rotation within one PR attempt, short enough not to cross sessions.
MAX_MARKER_AGE=3600

# ONE block plus a seeded MARKER_AGE — see the matching comment in
# enforce-compliance-audit.sh. A split "compute then compare" structure with a
# second `-f` test between the halves fails OPEN when the marker is recreated
# mid-check: the comparison reads an unset MARKER_AGE and `set -u` aborts the
# hook before any deny JSON is emitted (Codex pre-PR review, P1).
MARKER_AGE=-1
if [[ -f "$MARKER_FILE" ]]; then
  MARKER_MTIME=$(stat -c %Y "$MARKER_FILE" 2>/dev/null || stat -f %m "$MARKER_FILE" 2>/dev/null || echo "")
  # Validate NUMERIC before any arithmetic. GNU `stat -f` means "filesystem
  # status", where %m is not a valid directive — it can SUCCEED and print
  # literal "%m", which would skip the fallback and then abort the arithmetic
  # under `set -e` with no deny emitted. GNU form is tried first and the
  # result must be all digits, so neither platform can produce garbage here.
  [[ "$MARKER_MTIME" =~ ^[0-9]+$ ]] || MARKER_MTIME=""
  if [[ -z "$MARKER_MTIME" ]]; then
    rm -f "$MARKER_FILE"
  else
    MARKER_AGE=$(( $(date +%s) - MARKER_MTIME ))
  fi
fi

if [[ -f "$MARKER_FILE" ]]; then
  # Reject BOTH directions. A negative age means the marker is dated in the
  # FUTURE — a clock rollback, a bad `touch -t`, or a copied mtime. Checking only
  # `>= MAX` would fail OPEN there: the marker would stay accepted until wall
  # clock caught up to its mtime (Codex pre-PR review, P1). A future-dated marker
  # is never legitimate — the skill stamps it at creation time.
  if [[ "$MARKER_AGE" -lt 0 || "$MARKER_AGE" -ge "$MAX_MARKER_AGE" ]]; then
    # Stale or future-dated — the skill must be re-invoked for this PR. Deleting
    # the file is the whole signal: the existence re-check below now fails and
    # falls through to the deny path, as if the marker had never been written.
    rm -f "$MARKER_FILE"
  fi
fi

if [[ -f "$MARKER_FILE" ]]; then
  # Skill was invoked recently — allow the PR creation.
  # Do NOT delete the marker here. PreToolUse runs BEFORE the command, so if
  # another gate in the chain (enforce-codex-review, enforce-compliance-audit)
  # DENIES this same `gh pr create`, the command never runs — yet deleting here
  # would consume the marker anyway, forcing a needless re-invoke on retry (the
  # "gates fail in rotation" deadlock). Single-use is now enforced on SUCCESS by
  # the PostToolUse hook consume-pr-markers.sh, which deletes this marker only
  # after `gh pr create` actually creates a PR. A DENY leaves the marker intact
  # so the retry (after the other gate is satisfied) passes without re-invoking.
  exit 0
fi

# NO TRANSCRIPT FALLBACK.
#
# A previous version grep'd the transcript for "finishing-a-development-branch"
# as a fallback. That created a security hole: once the skill ran for ONE PR
# in a session, every subsequent `gh pr create` bypassed the marker — even
# after the marker was cleaned up. A second PR in the same session could be
# created without re-invoking the skill (and without the template).
#
# The marker file is now the ONLY gate. Invoke the skill for every PR.
# Single-use consumption happens in consume-pr-markers.sh (PostToolUse) on
# success — NOT here — to prevent the gates-fail-in-rotation deadlock.

# BLOCK: gh pr create without active skill marker
jq -n '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED: `gh pr create` called without invoking the finishing-a-development-branch skill first.\n\nThe skill defines the PR body template (What this changes / Why this matters / What was built / Key decisions / Test plan with status emojis). Writing the PR body inline bypasses the template and produces low-quality summaries.\n\nInvoke the skill first:\n  Skill(\"finishing-a-development-branch\")\n\nThe skill will guide you through the PR template. After it completes, `gh pr create` is allowed.\n\nIf you are a delegated subagent: invoke the skill from within your context, then run gh pr create."
  }
}'
exit 0
