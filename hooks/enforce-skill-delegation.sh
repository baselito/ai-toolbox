#!/bin/bash
# enforce-skill-delegation.sh
#
# PreToolUse hook matching on the Skill tool.
# Blocks direct invocation of skills that must run on Opus subagents,
# not inline on the orchestrator (Fable).
#
# Skills that must be delegated:
#   - discovery (Opus)
#   - brainstorming (Opus)
#   - verification-before-completion (Opus)
#   - finishing-a-development-branch (Opus)
#
# DELEGATION DETECTION:
# Transcript-based detection (head-5 [DELEGATED], short transcript heuristic)
# is fundamentally broken: subagents share the parent's JSONL transcript file,
# so a subagent reads the parent's long transcript with no [DELEGATED] marker
# in the first lines. Both Check 1 (head-5) and Check 2 (line count < 20)
# fail for every legitimate subagent.
#
# Fix: Token file approach (~/.claude/.skill-delegation-token), same pattern as
# .push-ready in push-safety.sh. The orchestrator creates the token before
# spawning a delegated subagent. The hook checks for the token, allows if
# valid (< 300s old), and deletes it. No transcript inspection needed.

set -euo pipefail

# Guard: ensure jq is available. Fail CLOSED — see enforce-auto-poll.sh.
if ! command -v jq &>/dev/null; then
  cat <<'__DENY__'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: jq is required for hook enforcement (enforce-skill-delegation). Install jq (brew install jq / apt install jq / yum install jq) to continue. Hook fails closed for safety."}}
__DENY__
  exit 0
fi

# Read hook input from stdin
HOOK_DATA=$(cat)

TOOL_NAME=$(echo "$HOOK_DATA" | jq -r '.tool_name // empty')

# Only apply to Skill tool calls
if [[ "$TOOL_NAME" != "Skill" ]]; then
  exit 0
fi

# Extract the skill name from tool input
# Try both .tool_input.skill and .tool_input.name to handle different schemas
# ⛔ `//` DOES NOT FALL BACK ON THE EMPTY STRING — only on null and false. ⛔
# A payload carrying `skill: ""` with the real name under `name` therefore read
# as EMPTY here too, and an empty SKILL_NAME matches no delegated skill, so the
# gate no-ops. Same defect, same fix, as enforce-loop-bounds.sh's LOOP_SKILL
# read: each field is taken only when it is a non-empty string, so empty, null,
# missing and wrong-typed all fall through to the next spelling identically.
# ⛔ A WHITESPACE-ONLY VALUE IS NOT A NAME, AND IT SHADOWED THE FALLBACK. ⛔
# The `select(type == "string" and length > 0)` above got the empty case right
# and let `"   "` straight through: length 3, so the FIRST alternative wins, and
# `//` never looks at the next spelling. The bash normalisation below then trims
# it back to the empty string, which matches no known skill, so the gate no-ops.
# Measured at 5b94753 on the real hook: `{"skill":"   ","name":"loop"}` with no
# turn clause produced EMPTY stdout and exit 0 - a silent ALLOW of an unbounded
# /loop, past the only bound this hook enforces. Trimming INSIDE the select is
# what makes `""`, `"   "`, `"\t"`, null, missing and wrong-typed all fall
# through to the next spelling identically, which is what the comment above
# already claimed.
#
# NOT a contradiction of the sibling finding: automated-review also reported that a
# BOOLEAN `skill` makes jq error and abort the extraction. Measured false - jq's
# `and` short-circuits, so `length` is never evaluated for a non-string, and
# `{"skill":true,"name":"loop"}` already denied at 5b94753. The whitespace case
# is the one that was real.
SKILL_NAME=$(echo "$HOOK_DATA" | jq -r '((.tool_input.skill | select(type == "string") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "") | select(length > 0)) // (.tool_input.name | select(type == "string") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "") | select(length > 0)) // (.tool_input.args | select(. != null and . != "")) // empty) | tostring' 2>/dev/null || echo "")

# If we couldn't extract a skill name, allow (fail open — better than blocking all skills)
if [[ -z "$SKILL_NAME" ]]; then
  exit 0
fi

# Skills that MUST be delegated to an Opus subagent
MUST_DELEGATE=(
  "discovery"
  "brainstorming"
  "verification-before-completion"
  "finishing-a-development-branch"
)

# Skills that must be delegated but do NOT require chief-of-staff to have run
# first. commands/flow.md's documented execution order is strict: Step 1.5
# (Discovery investigation) runs BEFORE Step 1.8 (chief-of-staff's execution
# plan) — Discovery is read-only and happens ahead of ticket assignment, which
# is itself ahead of chief-of-staff. Requiring HAS_EXECUTION_PLAN for
# "discovery" made that documented order unreachable: on a fresh session
# chief-of-staff genuinely has not run yet when discovery is legitimately
# invoked, so the hook blocked every correctly-delegated discovery call (C1,
# hook-safety audit). The other MUST_DELEGATE skills (brainstorming at Step 5,
# verification-before-completion, finishing-a-development-branch) DO run after
# Step 1.8 in flow.md's order, so they keep the chief-of-staff prerequisite.
NO_COS_PREREQUISITE=(
  "discovery"
)

SKIPS_COS_PREREQUISITE=false
for skill in "${NO_COS_PREREQUISITE[@]}"; do
  if [[ "$SKILL_NAME" == "$skill" ]]; then
    SKIPS_COS_PREREQUISITE=true
    break
  fi
done

# Check if this skill requires delegation
REQUIRES_DELEGATION=false
for skill in "${MUST_DELEGATE[@]}"; do
  if [[ "$SKILL_NAME" == "$skill" ]]; then
    REQUIRES_DELEGATION=true
    break
  fi
done

# If the skill doesn't require delegation, allow it
if [[ "$REQUIRES_DELEGATION" == "false" ]]; then
  exit 0
fi

# PREREQUISITE CHECK (runs BEFORE token check): chief-of-staff must have
# been spawned earlier in the session. This works correctly with shared
# transcripts because the question is "was chief-of-staff EVER spawned?"
# (global), not "am I a subagent?" (local). The shared transcript reliably
# shows the orchestrator's spawns.
#
# Why before the token check: if the token check ran first and found a valid
# token, it would exit 0 (allow) — bypassing this prerequisite entirely.
# A valid delegation token means "yes, the orchestrator intended to delegate
# this skill" but does NOT mean "chief-of-staff was consulted first." Both
# gates must pass.
#
# SKIPPED for "discovery" (NO_COS_PREREQUISITE above): commands/flow.md's
# execution order runs Step 1.5 (Discovery) strictly BEFORE Step 1.8
# (chief-of-staff's execution plan) — see the ordering note above
# NO_COS_PREREQUISITE. Discovery still falls through to the mandatory token
# check below, so it can never run inline; it just isn't gated on an event
# (chief-of-staff) that hasn't happened yet by design at that point in the
# flow.
if [[ "$SKIPS_COS_PREREQUISITE" == "false" ]]; then
  TRANSCRIPT_PATH=$(echo "$HOOK_DATA" | jq -r '.transcript_path // empty')

  # Fail closed: if transcript_path is missing or the file doesn't exist, we
  # can't verify chief-of-staff was spawned. Block the skill to prevent bypass
  # via omitting transcript_path (automated-review finding: "valid token bypasses
  # chief-of-staff prerequisite when transcript_path is absent").
  if [[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
    jq -n --arg skill "$SKILL_NAME" '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": ("BLOCKED: " + $skill + " requires chief-of-staff verification but transcript_path is missing or the file does not exist. Cannot verify the execution plan was created. Ensure the hook receives a valid transcript_path.")
      }
    }'
    exit 0
  fi

  HAS_EXECUTION_PLAN=false
  # EXACT-match the bare vendored name — NOT a substring/suffix match. The old
  # pattern ("[^"]*chief-of-staff") also matched the prefixed ECC key
  # everything-claude-code:chief-of-staff, which upstream repurposed into a
  # comms-triage agent: its presence in a transcript is NOT evidence that our
  # execution-plan chief-of-staff ran (Codex P1, vendoring PR).
  if grep -q '"subagent_type"[[:space:]]*:[[:space:]]*"chief-of-staff"' "$TRANSCRIPT_PATH" 2>/dev/null; then
    HAS_EXECUTION_PLAN=true
  fi

  if [[ "$HAS_EXECUTION_PLAN" == "false" ]]; then
    jq -n --arg skill "$SKILL_NAME" '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": ("BLOCKED: " + $skill + " requires the chief-of-staff execution plan (Step 1.8). Chief-of-staff has not been spawned yet in this session. Spawn chief-of-staff first to create the execution plan, THEN delegate " + $skill + " to an Opus subagent.\n\nStep 1.8: Agent(subagent_type: \"chief-of-staff\", prompt: \"Create execution plan for DEV-XXXX...\")\nPass no model: argument — the chief-of-staff frontmatter (opus) is authoritative.")
      }
    }'
    exit 0
  fi
fi

# DELEGATION CHECK: Token file approach.
# The orchestrator creates ~/.claude/.skill-delegation-token before spawning
# a delegated subagent. The subagent invokes the skill, this hook finds the
# token, allows, and deletes it. Same pattern as .push-ready.
#
# State directory: defaults to $HOME/.claude/ (outside any repo). Can be
# overridden via CLAUDE_STATE_DIR for testing.
#
# Runs AFTER the prerequisite check above — a valid token only matters if
# chief-of-staff was already consulted.
# ⛔ NEITHER HOME NOR CLAUDE_STATE_DIR SET -> DENY, DO NOT ABORT. ⛔
# Under `set -u`, expanding ${CLAUDE_STATE_DIR:-$HOME/.claude} with BOTH unset
# aborts the shell with "HOME: unbound variable" BEFORE any JSON is printed, and
# PreToolUse treats a non-blocking exit as ALLOW — so the abort silently disarms
# this gate.
#
# ⛔ THIS HOOK WAS CLEARED OF THIS CLASS TWICE, WRONGLY, FOR THE SAME REASON. ⛔
# Both sweeps probed it with an *Agent* payload, on which it correctly exits 0
# before ever reaching this line — so it looked clean. It gates the *Skill* tool.
# Driven by the payload it actually gates, it is squarely in the class:
#     Skill{skill:"discovery"}, HOME unset -> exit 1, no JSON, "unbound variable"
#     Skill{skill:"discovery"}, HOME set   -> deny
# The first sweep used one payload for every hook; the second reused that result
# and wrote "do not fix these two" into the fix list. Cross-family review (Codex)
# caught it. The lesson is in the sibling matrix in scripts/verify-hooks.sh: a
# gate must be probed with the payload IT gates, or the probe proves nothing.
# `-z` covers unset AND empty. Canonical copy: enforce-fable-review.sh.
if [[ -z "${CLAUDE_STATE_DIR:-}" && -z "${HOME:-}" ]]; then
  cat <<'__DENY__'
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "BLOCKED: neither HOME nor CLAUDE_STATE_DIR is set, so enforce-skill-delegation cannot locate the delegation token that authorises running a skill on the orchestrator. A gate that cannot find its own evidence has not been satisfied, so it fails closed.\n\nThis cannot be fixed from inside a Bash tool call \u2014 every call is a fresh shell, so an `export` here does not survive to the next one. Set HOME (or CLAUDE_STATE_DIR) in the environment the agent itself runs in \u2014 the `env` block of ~/.claude/settings.json, or the container/CI environment \u2014 and start a new session."}}
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
# ⛔ A REMEDY NAMING A PATH THE GATE DOES NOT READ IS AN UNFOLLOWABLE REMEDY,
# AND THAT IS THE H1 DEADLOCK CLASS THIS BRANCH ALREADY FIXED ONCE. ⛔
# The marker read above honours CLAUDE_STATE_DIR; every deny below used to
# print a hardcoded ~/.claude. So under an override the gate told the operator
# to write the marker into a directory it would never look in, and following
# the printed instruction EXACTLY left the PR blocked forever. That is the same
# shape as a gate refusing its own remedy — the difference is only that the
# writer and the reader disagree instead of two branches of one file.
#
# When no override is set, the resolved root IS $HOME/.claude, and the tilde
# spelling is kept for that case ON PURPOSE, not as a leftover: it is the
# spelling enforce-auto-poll's allowlist accepts and the suite's controls pin,
# and it is copyable between machines where an expanded /Users/<someone>/...
# is not.
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


DELEGATION_TOKEN="$STATE_DIR/.skill-delegation-token"

if [[ -f "$DELEGATION_TOKEN" ]]; then
  # Compute token age — fail closed if stat fails (e.g. token deleted between
  # -f check and stat, permissions issue, or unsupported stat invocation).
  # Default to 999 (expired) so a stat failure blocks rather than allows.
  FILE_AGE=999
  if [[ "$(uname)" == "Darwin" ]]; then
    FILE_AGE=$(( $(date +%s) - $(stat -f %m "$DELEGATION_TOKEN" 2>/dev/null || echo "0") )) 2>/dev/null || FILE_AGE=999
  else
    FILE_AGE=$(( $(date +%s) - $(stat -c %Y "$DELEGATION_TOKEN" 2>/dev/null || echo "0") )) 2>/dev/null || FILE_AGE=999
  fi
  if [[ "$FILE_AGE" -lt 300 ]]; then
    rm -f "$DELEGATION_TOKEN"
    exit 0
  fi
  rm -f "$DELEGATION_TOKEN"
fi

# BLOCK: No delegation token found. Either the orchestrator is invoking
# the skill directly (violation) or it forgot to create the token before
# spawning the subagent.
jq -n --arg skill "$SKILL_NAME" --arg root "$REMEDY_DIR" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": ("BLOCKED: " + $skill + " requires a delegation token. The orchestrator must create " + $root + "/.skill-delegation-token before spawning the subagent:\n\n1. touch " + $root + "/.skill-delegation-token\n2. Agent(model: \"opus\", prompt: \"[DELEGATED] You are a " + $skill + " subagent. Invoke the " + $skill + " skill and follow its FULL process for [TICKET]. Do not skip any steps.\")\n\nThe token is valid for 300 seconds and consumed on use. This prevents the orchestrator from invoking delegated skills inline (far costlier than a subagent).")
  }
}'
exit 0
