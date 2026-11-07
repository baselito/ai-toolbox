#!/bin/bash
# enforce-transition-script.sh
#
# PreToolUse hook matching on the Bash tool.
# Blocks bare `acli jira workitem transition` calls — forces transitions
# through jira-workflow-steward so every move is paired with a mandatory
# phase comment (preventing the Jira comment regression: 5→4→3→1 across
# test sessions).
#
# Current path: the orchestrator creates ~/.claude/.jira-delegation-token,
# then spawns jira-workflow-steward (Haiku), which runs the transition AND
# posts the phase comment atomically. The token escape below allows that.
# (A python3-wrapped transition is also still accepted by the python3 escape
# below, but flow.md no longer documents one — the steward path supersedes it.
# See rules/agents.md → "Jira Phase-Map Transitions".)
#
# What's blocked:
#   - `acli jira workitem transition --key DEV-XXXX --status "In Progress"`
#   - Any direct acli transition command
#
# What's allowed:
#   - `python3 -c "..." ` (legacy python3-wrapped transition — still accepted)
#   - `acli jira workitem transition` when a valid ~/.claude/.jira-delegation-token
#     exists (the jira-workflow-steward path — see token escape below)
#   - `acli jira workitem transitions` (READ-ONLY listing of available transitions)
#   - `acli jira workitem view` (reading tickets)
#   - `acli jira workitem assign` (assignment)
#   - `acli jira workitem comment` (standalone comments like Step 9)
#   - `acli jira board` (board queries)

set -euo pipefail

# Guard: ensure jq is available. Fail CLOSED — see enforce-auto-poll.sh.
if ! command -v jq &>/dev/null; then
  cat <<'__DENY__'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: jq is required for hook enforcement (enforce-transition-script). Install jq (brew install jq / apt install jq / yum install jq) to continue. Hook fails closed for safety."}}
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

# Exempt standalone git commit commands — the hook false-triggers on commit
# messages that mention "transition" in their body text (heredoc message
# documenting workflow changes). A git commit is never an acli transition
# operation.
#
# Check: if the command starts with `git commit`, see if `acli` or
# `transition` (as a standalone word, not "transitions") appears as a
# SEPARATE command after a shell separator (&&, ||, ;, |) or newline.
# If it only appears within the git commit's message text, exempt.
# All detectors below match with here-strings (`<<<`), never `echo | grep`:
# under `set -euo pipefail` the pipe form can SIGPIPE (141) on large multiline
# input and flip a deny to an allow (static guard: TC-TS-16).
if grep -qE "^\s*git[[:space:]]+commit" <<< "$COMMAND"; then
  # ⛔ MUST match the FIRST separator, not the last. Previous greedy `.*`
  # consumed up to the last separator, missing flagged keywords in the middle
  # of a chain (e.g. `git commit && acli ... && echo done` → only `echo done`).
  AFTER_SEPARATOR=$(echo "$COMMAND" | sed -n 's/^[^;&|]*[;&|]\{1,2\}[[:space:]]*//p')
  if [[ "$COMMAND" == *$'\n'* ]]; then
    AFTER_NEWLINE=$(echo "$COMMAND" | tail -n +2)
  else
    AFTER_NEWLINE=""
  fi
  if ! grep -qE "acli|transition" <<< "$AFTER_SEPARATOR" \
    && ! grep -qE "acli|transition" <<< "$AFTER_NEWLINE"; then
    exit 0
  fi
fi

# Only check for acli transition WRITE commands.
# Allow read-only listing: `acli jira workitem transitions` (note trailing 's')
# which returns available transitions for a ticket — not a state change.
if ! grep -qE "acli[[:space:]].*[[:space:]]transition(\b|[[:space:]])" <<< "$COMMAND"; then
  exit 0
fi

# Exempt `transitions` (plural) — read-only listing of available transitions.
# Only allow if the command does NOT also contain a singular write-form
# `transition` (without trailing 's'). This prevents chained commands like
# `acli jira workitem transitions --key X && acli jira workitem transition --key X --status Done`
# from bypassing the hook via the plural exemption.
if grep -qE "acli[[:space:]].*[[:space:]]transitions(\b|[[:space:]]|$)" <<< "$COMMAND"; then
  # Strip all occurrences of 'transitions' (plural) and re-check for singular 'transition'
  STRIPPED=$(echo "$COMMAND" | sed 's/transitions//g')
  if ! grep -qE "transition(\b|[[:space:]])" <<< "$STRIPPED"; then
    exit 0
  fi
  # If singular 'transition' remains after stripping plurals, fall through to block
fi

# Exempt introspection flags — --help and --version are read-only
if grep -qE "transition[[:space:]].*--(help|version)(\b|$)" <<< "$COMMAND"; then
  exit 0
fi

# Allow if a valid jira-delegation-token exists — the delegation hook
# (enforce-jira-delegation.sh) already ensures cost discipline by requiring
# the token. If the token is valid, the caller is a delegated steward
# context and can run transitions directly without the python3 wrapper.
#
# ⛔ TTL MUST stay 3600s to match enforce-jira-delegation.sh and the
# session-level token semantics in rules/agents.md ("valid for 3600 seconds,
# NOT consumed"). A shorter TTL here caused a real bug: in workflows taking
# longer than the old 300s window, comments/assign still succeeded (gated by
# the delegation hook's 3600s window) but the transition was wrongly blocked
# here — the token's 300s window had expired even though it was still valid
# everywhere else. Keep the two windows identical.
#
# IMPORTANT: Do NOT consume (delete) the token on a valid use here.
# enforce-jira-delegation.sh likewise never deletes it on a valid (in-window)
# use — it only removes an EXPIRED token as cleanup. The token is session-level
# and shared across every jira-workflow-steward spawn in a workflow. Both hooks
# run in the same Bash PreToolUse chain; on a valid token each only CHECKS its
# presence and age, never removing it.
# ⛔ NEITHER HOME NOR CLAUDE_STATE_DIR SET -> DENY, DO NOT ABORT. ⛔
# Under `set -u`, expanding ${CLAUDE_STATE_DIR:-$HOME/.claude} with BOTH unset
# aborts the shell with "HOME: unbound variable" BEFORE any JSON is printed.
# PreToolUse treats any exit other than 2 as ALLOW, so the abort silently
# disarms this gate. Measured on this hook: exit 1, no JSON, while the same
# payload with a valid HOME denies correctly.
# `-z` covers unset AND empty — different bugs, same outcome here.
# Canonical copy and full rationale: enforce-fable-review.sh.
if [[ -z "${CLAUDE_STATE_DIR:-}" && -z "${HOME:-}" ]]; then
  cat <<'__DENY__'
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "BLOCKED: neither HOME nor CLAUDE_STATE_DIR is set, so the transition gate cannot locate the delegation token that authorises a Jira transition. Without it, it cannot tell a delegated transition from a direct one.\n\nA gate that cannot find its own evidence has not been satisfied, so it fails closed.\n\nThis cannot be fixed from inside a Bash tool call — every call is a fresh shell, so an `export` here does not survive to the next one. Set HOME (or CLAUDE_STATE_DIR) in the environment the agent itself runs in — the `env` block of ~/.claude/settings.json, or the container/CI environment — and start a new session."}}
__DENY__
  exit 0
fi

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

# REMEDY_DIR — THE STATE ROOT AS THIS GATE'S OWN REMEDY MUST SPELL IT.
#
# ⛔ A REMEDY NAMING A PATH THE GATE DOES NOT READ IS AN UNFOLLOWABLE REMEDY. ⛔
# The token/marker read below honours CLAUDE_STATE_DIR; the deny used to print
# a hardcoded ~/.claude, so under an override it named a directory this gate
# never looks in. When no override is set the resolved root IS $HOME/.claude and
# the home-agnostic tilde spelling is kept for that case on purpose — it is
# copyable between machines where an expanded /Users/<someone>/... is not.
# ⛔ AN EMPTY HOME MAKES THIS COMPARISON TRUE AND THE REMEDY WRONG. ⛔
# With HOME unset or empty, "${HOME:-}/.claude" is the literal "/.claude".
# So CLAUDE_STATE_DIR=/.claude compared EQUAL, this branch chose the tilde
# spelling, and the deny then told the operator to write into ~/.claude —
# which bash expands from the PASSWD entry, not from the empty variable, so
# it names a directory this gate does not read. That is the unfollowable
# remedy class again (TC-SR-REM-*), reached through the one input where the
# tilde and the resolved root stop being the same path. Requiring HOME to be
# non-empty makes the tilde spelling conditional on the thing that makes it
# true. Reported against enforce-compliance-audit alone; the identical
# comparison is in eight hooks.
if [[ -n "${HOME:-}" && "$STATE_DIR" == "$HOME/.claude" ]]; then
  REMEDY_DIR="~/.claude"
else
  REMEDY_DIR="$STATE_DIR"
fi

DELEGATION_TOKEN="$STATE_DIR/.jira-delegation-token"
if [[ -f "$DELEGATION_TOKEN" ]]; then
  if [[ "$(uname)" == "Darwin" ]]; then
    FILE_AGE=$(( $(date +%s) - $(stat -f %m "$DELEGATION_TOKEN") ))
  else
    FILE_AGE=$(( $(date +%s) - $(stat -c %Y "$DELEGATION_TOKEN") ))
  fi
  if [[ "$FILE_AGE" -lt 3600 ]]; then
    exit 0
  fi
fi

# Allow if this is inside a python3 script (a python3-wrapped transition).
# Such a command runs as: python3 -c "...acli...transition..."
#
# ⛔ INTENTIONALLY SIMPLE: this check uses `grep -q "python3"` (presence
# anywhere). It is NOT order-sensitive. A crafted command like
# `acli jira workitem transition && python3 -c ''` would pass this check.
#
# That gap is closed by `enforce-jira-delegation.sh`, which runs in the
# same hook chain on Bash tool calls and applies a stricter order-sensitive
# regex: `python3[^;&|]*acli...transition` (python3 must come BEFORE
# acli in the same shell segment). Both hooks must allow for the command
# to proceed.
#
# Do NOT "simplify" enforce-jira-delegation.sh to match this check —
# the stricter guard is load-bearing. Do NOT tighten this hook to match
# the delegation hook either — this hook's simple check is the first
# gate and the delegation hook is the fallback. See
# scripts/verify-hooks.sh TC-JD-5/6/7 for the composition tests.
if grep -q "python3" <<< "$COMMAND"; then
  exit 0
fi

# BLOCK: Direct acli transition command outside the transition script
jq -n --arg root "$REMEDY_DIR" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": ("BLOCKED: Direct `acli jira workitem transition` is not allowed — transitions must go through jira-workflow-steward so the move is paired with a mandatory phase comment and the correct phase→column mapping.\n\nRecovery: ask the orchestrator to delegate the transition via jira-workflow-steward. Do not create `" + $root + "/.jira-delegation-token` manually; that token must be orchestrator-issued. See rules/agents.md → \"Jira Phase-Map Transitions\".")
  }
}'
exit 0
