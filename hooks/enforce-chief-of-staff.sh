#!/bin/bash
# enforce-chief-of-staff.sh
#
# PreToolUse hook matching on the Agent tool.
# Blocks direct spawns of review agents unless chief-of-staff
# or code-review-orchestration skill was already invoked.
#
# DETECTION: Only checks subagent_type field — NOT description or prompt.
# Previous version matched agent names in prompt text, causing false
# positives when prompts said things like "chief-of-staff selected
# tdd-guide and code-reviewer" in descriptive context.
#
# ORCHESTRATION CHECK: Uses a marker file (~/.claude/.review-orchestrated)
# instead of JSONL transcript parsing. The code-review-orchestration
# skill creates this file when chief-of-staff completes. Simple file
# existence check — no fragile transcript format dependency.

set -euo pipefail

# Guard: ensure jq is available. Fail CLOSED — without jq we cannot reliably
# parse hook input or emit structured deny responses, so allowing the action
# would silently disarm enforcement on a devcontainer/CI image without jq.
if ! command -v jq &>/dev/null; then
  cat <<'__DENY__'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: jq is required for hook enforcement (enforce-chief-of-staff). Install jq (brew install jq / apt install jq / yum install jq) to continue. Hook fails closed for safety."}}
__DENY__
  exit 0
fi

# Read hook input from stdin
HOOK_DATA=$(cat)

TOOL_NAME=$(echo "$HOOK_DATA" | jq -r '.tool_name // empty')

# Only apply to Agent tool calls
if [[ "$TOOL_NAME" != "Agent" ]]; then
  exit 0
fi

# Extract the subagent_type — this is the ONLY field used for detection.
# Description and prompt are free-text that can contain review agent names
# in descriptive context (e.g. "chief-of-staff selected tdd-guide"),
# causing false positives.
SUBAGENT_TYPE=$(echo "$HOOK_DATA" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null || echo "")

# If no subagent_type specified, this is a general-purpose agent — allow it
if [[ -z "$SUBAGENT_TYPE" ]]; then
  exit 0
fi

# Lowercase for comparison
SUBAGENT_LOWER=$(echo "$SUBAGENT_TYPE" | tr '[:upper:]' '[:lower:]')

# List of review agent subagent_type patterns — matched against subagent_type ONLY
REVIEW_AGENTS=(
  "tdd-guide"
  "code-reviewer"
  "reality-checker"
  "accessibility-auditor"
  "database-reviewer"
  "api-tester"
  "security-reviewer"
  "security-engineer"
  "devops-automator"
  "evidence-collector"
  "doc-updater"
  "performance-benchmarker"
)

# Check if this subagent_type matches a review agent.
#
# MATCHING RULE: "exact name" OR "namespace:name" only. Substring match
# would false-positive on names like "my-custom-tdd-guide-wrapper" or
# "chief-of-staff-helper" — this previously allowed a theoretical bypass
# where any agent whose name contained "chief-of-staff" as a substring
# (e.g. "chief-of-staff-lite") would be exempted from the gate entirely.
IS_REVIEW_AGENT=false
for agent in "${REVIEW_AGENTS[@]}"; do
  if [[ "$SUBAGENT_LOWER" == "$agent" || "$SUBAGENT_LOWER" == *":$agent" ]]; then
    IS_REVIEW_AGENT=true
    break
  fi
done

# If not a review agent, allow it (planner, Explore, general-purpose, etc.)
if [[ "$IS_REVIEW_AGENT" == "false" ]]; then
  exit 0
fi

# Check if this IS chief-of-staff being spawned (allow it — it's the orchestrator).
# Uses exact-match allow-list, not substring — see matching rule above.
case "$SUBAGENT_LOWER" in
  "chief-of-staff")
    exit 0
    ;;
esac

# ORCHESTRATION CHECK: Does the marker file exist?
# The code-review-orchestration skill creates ~/.claude/.review-orchestrated
# after chief-of-staff completes its agent selection. If this file exists,
# chief-of-staff has approved the review plan and agents can be spawned.
#
# State directory: defaults to $HOME/.claude/ (outside any repo). Can be
# overridden via CLAUDE_STATE_DIR for testing.
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
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "BLOCKED: neither HOME nor CLAUDE_STATE_DIR is set, so the review-orchestration gate cannot locate the marker chief-of-staff creates. Without it, it cannot tell an orchestrated review-agent spawn from an unorchestrated one.\n\nA gate that cannot find its own evidence has not been satisfied, so it fails closed.\n\nThis cannot be fixed from inside a Bash tool call — every call is a fresh shell, so an `export` here does not survive to the next one. Set HOME (or CLAUDE_STATE_DIR) in the environment the agent itself runs in — the `env` block of ~/.claude/settings.json, or the container/CI environment — and start a new session."}}
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


MARKER_FILE="$STATE_DIR/.review-orchestrated"

if [[ -f "$MARKER_FILE" ]]; then
  # Chief-of-staff orchestration completed — allow review agent spawns.
  #
  # MARKER LIFECYCLE: This hook does NOT delete the marker on allow.
  # A single orchestration run spawns multiple review agents (parallel
  # and sequential groups per chief-of-staff's plan), so the marker
  # must persist across those spawns. The code-review-orchestration
  # skill is responsible for removing the marker at Step 4 (after all
  # review agents complete) — see skills/code-review-orchestration/SKILL.md.
  #
  # If the skill crashes before cleanup, a stale marker can linger.
  # This is an accepted risk because (a) a second review within the
  # same session without re-invoking the skill is rare, and (b) the
  # handover audit catches workflows that skipped chief-of-staff.
  exit 0
fi

# NO TRANSCRIPT FALLBACK.
#
# A previous version grep'd the transcript for "code-review-orchestration" as a
# fallback. That created a security hole: once the skill ran ONCE in a session,
# every future direct review-agent spawn bypassed the marker check — even for
# unrelated tasks, even after the marker was cleaned up. The fallback defeated
# the purpose of the marker file.
#
# The marker file is now the ONLY gate. If you see this block:
#   1. The code-review-orchestration skill must be invoked to create the marker
#   2. Each review cycle requires a fresh marker (marker is removed after use)
#   3. There is no "once per session" shortcut

# BLOCK: Review agent spawn without active orchestration marker
jq -n --arg root "$REMEDY_DIR" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": ("BLOCKED: Review agent spawn attempted without chief-of-staff orchestration. The implementing agent must invoke the code-review-orchestration skill first (Step 9 of /flow). Chief-of-staff then decides which agents to run. Do NOT spawn review agents directly.\n\nIf chief-of-staff already ran, ensure " + $root + "/.review-orchestrated marker file exists.")
  }
}'
exit 0
