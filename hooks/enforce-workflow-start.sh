#!/bin/bash
# enforce-workflow-start.sh
#
# PreToolUse hook matching on the Bash tool.
# Blocks `git checkout -b` with a Jira ticket-ID pattern in the branch name
# unless the /start or /flow workflow has been invoked in the current session.
#
# Why: The agent interprets "start working on TASK-756" as a freeform coding
# instruction and jumps straight to branch creation + implementation —
# bypassing /start, /flow, discovery, chief-of-staff, phase comments, and
# the entire orchestrated workflow. Past sessions showed the agent creating
# branches and editing code without any workflow phase executing.
#
# Detection: /start and /flow create ~/.claude/.workflow-started at Step 0.
# The marker is session-level (not consumed on use) because the same
# workflow may create multiple branches (worktrees). It is cleaned up
# at session end or when a new /start is invoked.
#
# Ticket-ID patterns matched: TASK-NNN, DEV-NNN, or any UPPERCASE-digits
# pattern commonly used in Jira (e.g. PROJ-123). Branches without a
# ticket-ID pattern are allowed (ad-hoc branches, toolbox work).

set -euo pipefail

# Guard: ensure jq is available. Fail CLOSED — see enforce-auto-poll.sh.
if ! command -v jq &>/dev/null; then
  cat <<'__DENY__'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: jq is required for hook enforcement (enforce-workflow-start). Install jq (brew install jq / apt install jq / yum install jq) to continue. Hook fails closed for safety."}}
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

# Launcher option-run — a global git option run between `git` and its subcommand
# (`git -c core.pager=cat checkout -b …`, `git -C path switch -c …`). Without
# consuming it, the `^git[[:space:]]+(checkout -b|switch -c)` detector required
# git and its subcommand to be ADJACENT and was bypassed by any global option in
# between — the same launcher-adjacency class fixed in push-safety.sh. The named
# value-taking options each grab a SEPARATE-word value; that value may be a bare
# token OR a double-quoted string (a path with a space, e.g. `-C "my repo"` —
# TC-EWS-6), so the value class accepts `"[^"]*"` too. The general `--?flag`
# branch handles every other flag plus `--opt=value` / `-xval` glued forms. Both
# the detector and the branch-name extractor below consume it, so the ticket-ID
# check still sees the real branch name.
#
# Accepted residual (fail-safe, same class push-safety documents): a single-quoted
# value (`-C 'my repo'`) or a glued long option with a quoted-space value
# (`--git-dir="my repo"`) still breaks the run — detection then misses and the
# branch-create is allowed without /start. This is a workflow-discipline gate, not
# a security boundary, and is already soft by design (an ad-hoc branch name with no
# ticket ID bypasses it intentionally), so the residual only means a ticket-named
# branch may skip the /start marker in that exotic shape.
GIT_OPT_RUN='((-c|-C|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix|--config-env|--attr-source)[[:space:]]+("[^"]*"|[^[:space:]]+)[[:space:]]+|--?[^[:space:]]+[[:space:]]+)*'

# Split the command into segments on UNQUOTED &, ;, and | characters only,
# then check each segment anchored to its start. This avoids false positives
# where "git checkout -b" appears inside quoted strings (commit messages,
# echo, grep patterns).
#
# Real branch creation: "git checkout -b bugfix/TASK-756-slug origin/main"
# False positive: "git commit -m 'mentions git checkout -b TASK-123'"
# False positive: "echo 'git checkout -b' | sed '...'"
#
# By checking ^[[:space:]]*git at segment start, we only match commands
# where git is the actual verb, not text inside arguments.
#
# SECURITY/FP (automated-review PR #126 finding, TC-EWS-7/8): the `|`-split added
# for the pipe-chain bypass (TC-EWS-3) used an unconditional `tr '|' '\n'`,
# which ALSO split on a `|` character sitting inside a quoted string — so
# `echo "x | git checkout -b feature/TASK-1-x"` (a pipe that is only ever
# text, never executed) false-triggered the branch-create detector. Fix:
# split_unquoted_segments() does a character-level scan that tracks
# single-/double-quote state (mirrors the quote-handling philosophy in
# push-safety.sh — character-level, NOT a full shell parser) and only
# treats `&`/`;`/`|` as a segment boundary when it occurs OUTSIDE any
# quote. A REAL unquoted chain — `true | git checkout -b ...` (TC-EWS-3) or
# a real chain following quoted text (TC-EWS-9) — still splits and is still
# detected; only separators actually inside quotes are neutralized.
#
# Residual (accepted, same class as elsewhere in this file — a workflow-
# discipline gate, not a security boundary): a backslash-escaped quote
# (`\"`) or a quote spanning multiple physical lines is not tracked. Both
# directions of that residual are fail-safe here — the gate is FP-avoidance,
# not a bypass surface — so a missed quote can only make detection MORE
# conservative (an extra split point), never allow a real branch-create to
# slip through undetected.
#
# Detectors below match with here-strings (`<<<`), never `echo | grep`: under
# `set -euo pipefail` the pipe form can SIGPIPE (141) on a large/multi-segment
# command and silently flip a deny into an allow (static guard: TC-EWS-1).
split_unquoted_segments() {
  awk '
    # sq = literal single-quote via sprintf("%c",39). The `\x27` hex escape is a
    # gawk extension and does NOT evaluate to a quote on stock macOS /usr/bin/awk
    # (POSIX awk), which silently broke single-quote tracking there (automated-review
    # PR #126 round 2). sprintf("%c",39) is portable POSIX and needs no shell
    # quoting gymnastics inside this single-quoted awk program.
    BEGIN { seg = ""; in_single = 0; in_double = 0; sq = sprintf("%c", 39) }
    {
      line = $0
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (c == sq && in_double == 0) { in_single = !in_single; seg = seg c; continue }
        if (c == "\"" && in_single == 0)   { in_double = !in_double; seg = seg c; continue }
        if (in_single == 0 && in_double == 0 && (c == "&" || c == ";" || c == "|")) {
          print seg
          seg = ""
          continue
        }
        seg = seg c
      }
      print seg
      seg = ""
    }
  ' <<< "$1"
}

IS_BRANCH_CREATE=false
BRANCH_SEGMENT=""

while IFS= read -r segment; do
  # Trim leading whitespace
  trimmed=$(echo "$segment" | sed 's/^[[:space:]]*//')
  # Check if this segment starts with git checkout -b or git switch -c
  if grep -qE "^git[[:space:]]+${GIT_OPT_RUN}(checkout[[:space:]]+-b|switch[[:space:]]+-c)" <<< "$trimmed"; then
    IS_BRANCH_CREATE=true
    BRANCH_SEGMENT="$trimmed"
    break
  fi
done < <(split_unquoted_segments "$COMMAND")

if [[ "$IS_BRANCH_CREATE" != "true" ]]; then
  exit 0
fi

# Extract the branch name (first argument after -b/-c), ignoring the
# optional upstream/start-point ref. This prevents false positives when
# the ref contains a ticket ID but the branch name doesn't — e.g.
# "git checkout -b tmp origin/TASK-756-fix" should be allowed.
BRANCH_NAME=$(echo "$BRANCH_SEGMENT" | sed -E "s/^git[[:space:]]+${GIT_OPT_RUN}(checkout[[:space:]]+-b|switch[[:space:]]+-c)[[:space:]]+//" | awk '{print $1}')

# Only block if the branch name contains a Jira ticket-ID pattern.
# Pattern: 1+ uppercase letters, a hyphen, 1+ digits (e.g. TASK-756, DEV-5647).
# Ad-hoc branches without ticket IDs are allowed without /start.
if ! grep -qE "[A-Z]+-[0-9]+" <<< "$BRANCH_NAME"; then
  exit 0
fi

# Check for workflow marker
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
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "BLOCKED: neither HOME nor CLAUDE_STATE_DIR is set, so the workflow gate cannot locate the workflow marker. Without it, it cannot tell a ticket branch created through /start from one created outside the workflow.\n\nA gate that cannot find its own evidence has not been satisfied, so it fails closed.\n\nThis cannot be fixed from inside a Bash tool call — every call is a fresh shell, so an `export` here does not survive to the next one. Set HOME (or CLAUDE_STATE_DIR) in the environment the agent itself runs in — the `env` block of ~/.claude/settings.json, or the container/CI environment — and start a new session."}}
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


MARKER_FILE="$STATE_DIR/.workflow-started"

if [[ -f "$MARKER_FILE" ]]; then
  # Workflow was started — allow branch creation
  exit 0
fi

# BLOCK: Branch creation with ticket ID but no active workflow
jq -n '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED: Creating a ticket branch without going through /start first.\n\nThe agent MUST route through /start → /flow before creating a branch for a Jira ticket. Jumping straight to branch creation bypasses discovery, chief-of-staff, phase comments, and the entire orchestrated workflow.\n\nWhen the user says \"start working on TASK-756\", \"pick up DEV-5647\", or similar — invoke /start with the ticket ID:\n\n  Skill(\"start\", args: \"TASK-756\")\n\n/start routes to /flow, which creates the workflow marker at Step 0. After that, branch creation is allowed at Step 7.\n\nIf this is genuinely ad-hoc work without a ticket, use a branch name without a ticket ID pattern."
  }
}'
exit 0
