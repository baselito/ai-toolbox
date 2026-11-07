#!/bin/bash
# enforce-compliance-audit.sh
#
# PreToolUse hook matching on the Bash tool.
# Blocks `gh pr create` unless an independent compliance audit subagent
# has been spawned in the current session.
#
# Why: The compliance self-check is self-grading — the agent that did
# the work reports its own compliance. Past sessions showed the agent
# reporting ✅ on items that were ❌ in reality. This is the same
# anti-pattern as "implementing agent reviews own code" which the rules
# explicitly prevent via chief-of-staff orchestration.
#
# The audit MUST be done by an independent subagent (general-purpose or
# similar) that reads handover.md fresh and verifies with evidence —
# not by the orchestrator grading itself.
#
# Detection: the audit subagent writes its findings to
# ~/.claude/.audit-complete, ending with a line starting "AUDIT COMPLETE:".
# Hook requires the file to exist, be non-empty, AND contain that
# signature line — an empty `touch` does not satisfy the check.
#
# MARKER GRAMMAR (the `AUDIT HEAD:` line was added by #153):
#   AUDIT HEAD: <full 40-hex sha of the commit that was audited>
#   ... one line per audited item ...
#   AUDIT COMPLETE: <N>/<M> items verified — PASSED|BLOCKED
#
# #153 — WHAT THE SIGNATURE LINE DOES NOT PROVE. Until that issue, the hook
# grep'd `^AUDIT COMPLETE:` and stopped reading at the colon, so it inferred
# two facts it never measured:
#   (a) that the audit PASSED. An audit ending "8/14 items verified — BLOCKED"
#       satisfied the gate. Confirmed live twice on 2026-08-26 (5/14, then
#       7/14) — the hook would have opened the PR both times.
#   (b) that the audit covered THIS commit. With no binding, an audit written
#       for an earlier sha satisfied the gate for every later one — the same
#       staleness hole .codex-review-complete already closes with a sha.
# Both are now checked, and BOTH fail CLOSED on anything they cannot read:
# a verdict that is neither PASSED nor BLOCKED, a missing `AUDIT HEAD:` line,
# a sha mismatch, or a HEAD that does not resolve in the command's cwd. A gate
# that cannot establish it was satisfied has NOT been satisfied — permitting on
# unrecognised input is the fail-open shape TL-0001 records seven times.
#
# The `AUDIT HEAD:` line is a separate line rather than a suffix on the
# signature line on purpose: the `^AUDIT COMPLETE:` grammar (and the deny
# message below that teaches it) is unchanged, so this is an added check
# rather than a rewrite of a format other docs already describe.
#
# NOTE: This complements enforce-pr-skill.sh (which requires the
# finishing-a-development-branch skill). Both must pass for PR creation.

set -euo pipefail

# Guard: ensure jq is available. Fail CLOSED — see enforce-auto-poll.sh.
if ! command -v jq &>/dev/null; then
  cat <<'__DENY__'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: jq is required for hook enforcement (enforce-compliance-audit). Install jq (brew install jq / apt install jq / yum install jq) to continue. Hook fails closed for safety."}}
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

# The Bash tool's own working directory. Needed to resolve the commit the PR
# would be created FROM, so the audit marker can be bound to it (#153). Read
# from the payload rather than $PWD so the hook reads the right repo even when
# fired from a subagent — same approach as enforce-codex-review.sh.
CWD=$(echo "$HOOK_DATA" | jq -r '.cwd // "."' 2>/dev/null || echo ".")

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
# is reliable. (enforce-codex-review.sh still uses the pipe form — flagged for
# the same fix as a follow-up.)
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

# ---------------------------------------------------------------------------
# THE AUDIT IS BOUND TO A COMMIT RESOLVED IN *THIS* CWD (H6). Refuse the two
# command shapes that make that binding certify the wrong repository. Same two
# detectors as enforce-codex-review.sh, the canonical copy, and the same
# reasoning as the block enforce-fable-review.sh now carries.
#
# #153 bound the audit report to a sha so an audit of an earlier commit could
# not certify a later one. That binding is only as good as the assumption that
# the sha it resolves is the sha the PR is opened from — and `cd ../other &&`
# or `--repo other-owner/other-repo` breaks the assumption without touching the
# marker. `--repo` is the sharper half: it needs no `cd` at all, so HEAD
# resolves here, the AUDIT HEAD line matches, and the PR opens against a
# repository the auditor never read.
#
# The `cd` detector is boundary-anchored so the letters "cd" inside a PR title
# do not false-positive (TC-CD-cdword), and the attached `-Rowner/repo` form
# requires a `/` so `-Region` in a title is not read as a repo flag.
CA_CWD_DENY=""
if grep -qE '(^|[;&|(])[[:space:]]*(cd|pushd|popd)[[:space:]]' <<< "$COMMAND"; then
  CA_CWD_DENY="changes directory (cd/pushd/popd), so the commit this gate resolved is not necessarily the commit the PR would be opened from. If there is no cd/pushd in your COMMAND because the token is in a --body or --title STRING, note this detector anchors PER LINE: a PR body whose how-to-test section starts a line with the two characters c,d then a space trips it, and there is then nothing in the command to remove. Write the body to a file with the Write tool and pass --body-file <path> instead, which clears this deny and leaves every other gate in place."
# ⛔ `env -C` AND `git -C` RELOCATE THE COMMAND WITHOUT A `cd`. ⛔
# This was a NAMED RESIDUAL here and in the sibling gates, on the reasoning
# that the pr-create DETECTOR still sees the command, so the gate is not
# bypassed. That is right about the detector and wrong about the BINDING, which
# is the control this block exists to protect: an `env -C ../other-checkout`
# prefix is detected, reaches this gate, and then HEAD is resolved by `git
# rev-parse` in the PAYLOAD cwd - THIS checkout - while the command itself runs
# in ../other-checkout. So a marker legitimately written for the commit that WAS
# reviewed authorises a PR opened from a commit, branch or repository nobody
# read. That is exactly what `cd` is refused for, so naming it and allowing it
# made the residual a documented hole rather than an accepted one. `git -C
# <dir>` is the same shape through git instead of env; `--chdir <dir>` and
# `--chdir=<dir>` are env's long spellings.
#
# `env` takes its own options and NAME=VALUE assignments before the command, so
# the group in front of -C admits both. The `-[^C...]` class inside that group
# is what stops a preceding bare option from swallowing the -C itself. Anchored
# the same way as the cd arm, so the letters inside a PR title do not
# false-positive; an inline --body that spells it merely OVER-blocks, with the
# same Write-tool remedy the deny already prints.
elif grep -qE '(^|[;&|(])[[:space:]]*env([[:space:]]+[^[:space:];&|()]+)*[[:space:]]+(-[^C[:space:];&|()=]*C([^[:space:];&|()]*)?([[:space:]]|$)|--chdir([[:space:]=]|$))' <<< "$COMMAND" \
     || grep -qE '(^|[;&|(`[:space:]])([^[:space:];&|()]*/)?git([[:space:]]+-[^C[:space:];&|()][^[:space:];&|()]*)*[[:space:]]+-C([[:space:]]|$)' <<< "$COMMAND"; then
  CA_CWD_DENY="relocates the command with env -C/--chdir or git -C, so the commit this gate resolved is not the commit the PR would be opened from. The HEAD lookup runs in this command's own working directory, while -C moves only where the command itself executes - and that is the half that decides what gets pushed. If the token is in a --body or --title STRING rather than a real flag, this scan has no quote awareness: write the body to a file with the Write tool and pass --body-file <path> instead, which clears this deny and leaves every other gate in place."
elif grep -qE '(^|[[:space:]])(--repo([[:space:]=]|$)|-R[[:space:]=]|-R[A-Za-z0-9._-]*/[A-Za-z0-9._-])' <<< "$COMMAND"; then
  CA_CWD_DENY="targets another repository (--repo/-R), so an audit written for THIS checkout would open a PR against one nobody audited. If there is no --repo flag to remove because the token is inside a --body or --title STRING, this scan has no quote awareness and read your prose as a flag: write the body to a file with the Write tool and pass --body-file <path> instead, which clears this deny and leaves every other gate in place."
fi
if [[ -n "$CA_CWD_DENY" ]]; then
  jq -n --arg why "$CA_CWD_DENY" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": ("BLOCKED: this command " + $why + ".\n\nThe compliance audit report is keyed to `git rev-parse HEAD` resolved in this command'\''s working directory (the `AUDIT HEAD:` line, issue #153). A command that moves the working directory, or aims the PR elsewhere with --repo/-R, breaks that binding — the report would certify a change nobody involved in this PR ever audited.\n\nRun `gh pr create` as a PLAIN command from inside the checkout that was audited, with no cd/pushd and no --repo.\n\nNOT actually creating a PR? The scan reads the RAW command text with no heredoc or quote awareness, so a command that merely MENTIONS the phrase in prose trips the same check. That over-block is deliberate and accepted. Workaround: create the file with a NON-Bash write path (the Write tool), then run it. Writing it via a Bash heredoc does NOT help — that command carries the same phrase in its own body and is scanned before it can run.")
    }
  }'
  exit 0
fi

# Check for audit report — the audit subagent must write its findings
# to ~/.claude/.audit-complete with CONTENT, not just touch an empty file.
#
# CONTENT ATTESTATION: An empty `touch ~/.claude/.audit-complete` bypasses
# the Independence Principle the hook is meant to enforce — the agent
# could self-certify by creating an empty marker. Requiring non-empty
# content with a specific signature line raises the bar: the agent must
# produce a valid-looking audit report, which is harder to fake than a
# zero-byte file. This is not adversarial resistance (the agent could
# still write a fake report) — it is designed to prevent the careless
# on-rails-agent failure mode where the marker is touched without the
# subagent actually running.
#
# Required signature line (case-sensitive): "AUDIT COMPLETE:"
#   Example full line:
#     AUDIT COMPLETE: 14/14 items verified with evidence — PASSED
#
# The audit subagent prompt (see /flow Step 15) instructs the subagent
# to end its report with this signature line.
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
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "BLOCKED: neither HOME nor CLAUDE_STATE_DIR is set, so enforce-compliance-audit cannot locate the state directory its audit report lives in. A gate that cannot find its own evidence has not been satisfied, so it fails closed.\n\nThis cannot be fixed from inside a Bash tool call — every call is a fresh shell, so an `export` here does not survive to the next one. Set HOME (or CLAUDE_STATE_DIR) in the environment the agent itself runs in — the `env` block of ~/.claude/settings.json, or the container/CI environment — and start a new session."}}
__DENY__
  exit 0
fi

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


MARKER_FILE="$STATE_DIR/.audit-complete"

# STALENESS GATE. The marker is only consumed on a SUCCESSFUL `gh pr create`
# (PostToolUse consume-pr-markers.sh). If a PR attempt is DENIED by a sibling gate
# and never retried, the marker survives indefinitely — observed in practice: a
# 14.9-day-old .audit-complete was still satisfying this gate, so the next
# `gh pr create` would have sailed through with an audit of a different, long-gone
# change. That defeats the "Each PR requires a fresh audit" contract stated below.
#
# Anything older than MAX_MARKER_AGE is treated as absent and removed. 3600s matches
# the session-token window already used by enforce-jira-delegation.sh: long enough to
# survive gates failing in rotation within one PR attempt (the deadlock the
# no-delete-in-PreToolUse design exists to avoid), short enough that a marker cannot
# carry across sessions.
MAX_MARKER_AGE=3600

# ONE block, deliberately. An earlier revision split this into "compute age" and
# "compare age" blocks with a second `-f` test between them — which reintroduced a
# fail-OPEN: if the marker vanished after the first test and a FRESH one appeared
# before the second, the comparison ran with MARKER_AGE unset and `set -u` aborted
# the hook before any deny JSON was emitted (Codex pre-PR review, P1). A single
# block cannot desynchronise: MARKER_AGE is only ever read on the path that just
# assigned it.
#
# MARKER_AGE is also seeded so no path can reach a comparison on an unset value.
MARKER_AGE=-1
if [[ -f "$MARKER_FILE" ]]; then
  # Read mtime WITHOUT letting a failure abort the hook. BSD form first, GNU
  # second, empty if both fail. Inline `$(( $(date +%s) - $(stat ...) ))` would
  # throw an arithmetic error then an unbound-variable abort on a stat failure —
  # again exiting non-zero with no deny JSON. The marker really can be removed
  # between the `-f` test and the `stat`.
  MARKER_MTIME=$(stat -c %Y "$MARKER_FILE" 2>/dev/null || stat -f %m "$MARKER_FILE" 2>/dev/null || echo "")
  # Validate NUMERIC before any arithmetic. GNU `stat -f` means "filesystem
  # status", where %m is not a valid directive — it can SUCCEED and print
  # literal "%m", which would skip the fallback and then abort the arithmetic
  # under `set -e` with no deny emitted. GNU form is tried first and the
  # result must be all digits, so neither platform can produce garbage here.
  [[ "$MARKER_MTIME" =~ ^[0-9]+$ ]] || MARKER_MTIME=""
  if [[ -z "$MARKER_MTIME" ]]; then
    # Age cannot be established — treat exactly like an invalid marker.
    rm -f "$MARKER_FILE"
  else
    MARKER_AGE=$(( $(date +%s) - MARKER_MTIME ))
  fi
fi

if [[ -f "$MARKER_FILE" ]]; then
  # Reject BOTH directions. A negative age means the marker is dated in the
  # FUTURE — a clock rollback, a bad `touch -t`, or a copied mtime. Checking only
  # `>= MAX` would fail OPEN there: the marker would stay accepted until wall
  # clock caught up to its mtime, which is exactly the indefinite acceptance this
  # gate exists to stop. A future-dated marker is never legitimate — this hook's
  # own writer stamps it at creation time. The -1 seed also lands here, so a
  # marker recreated mid-check is rejected rather than silently trusted.
  if [[ "$MARKER_AGE" -lt 0 || "$MARKER_AGE" -ge "$MAX_MARKER_AGE" ]]; then
    # Stale, future-dated, or unverifiable — a fresh audit is required.
    rm -f "$MARKER_FILE"
  # File is fresh — verify it has content and the required signature line
  elif [[ -s "$MARKER_FILE" ]] && grep -q "^AUDIT COMPLETE:" "$MARKER_FILE" 2>/dev/null; then
    # ---------------------------------------------------------------
    # #153 — the two checks the signature line never made. Each is ONE
    # conditional, deliberately: an earlier draft split them into five
    # narrower branches and the pin sweep showed three of the five could be
    # deleted without reddening a single test, because every fixture that
    # reaches them trips a later branch as well. A guard no test can
    # distinguish from its neighbour is a guard nobody will notice rotting,
    # so the redundancy is gone and what remains is pinned.
    # ---------------------------------------------------------------

    # (1) BIND TO A COMMIT. Resolve the commit this PR would be created
    #     from, and read the sha the report claims to have audited. CWD
    #     comes from the payload so the hook reads the right repo even when
    #     fired from a subagent (as enforce-codex-review.sh does).
    CA_HEAD_SHA=$(cd "$CWD" 2>/dev/null && git rev-parse HEAD 2>/dev/null || echo "")
    #     A full 40-hex sha on its own `AUDIT HEAD:` line. Anything shorter
    #     or malformed extracts as empty and is treated as absent.
    CA_AUDIT_HEAD=$(sed -n 's/^AUDIT HEAD:[[:space:]]*\([0-9a-f]\{40\}\)[[:space:]]*$/\1/p' "$MARKER_FILE" 2>/dev/null | head -1 || true)

    # Three ways to fail one condition. Equality ALONE would not be enough:
    # two empty strings compare equal, so an unresolvable HEAD and an unbound
    # marker would agree with each other and open the gate. The two `-z`
    # clauses make either emptiness a failure on its own.
    #
    # WHAT THE SUITE PINS: the mismatch clause by TC-CAV-5, the condition as a
    # whole by TC-CAV-5/6/8, and — since the review round that followed —
    # THE BOTH-EMPTY CASE BY TC-CAV-12. This comment used to end "they earn
    # their place on the both-empty case, which no test covers; treat them as
    # load-bearing when editing", which was an honest label on a gap and not a
    # reason to leave it: the case is reachable (a PR create from a non-repo
    # cwd, plus a report with no `AUDIT HEAD:` line) and therefore pinnable.
    # Drop the two `-z` clauses and the condition becomes a bare inequality
    # that two empty strings SATISFY, so an unresolvable HEAD and an unbound
    # report certify each other.
    #
    # An unresolvable HEAD fails CLOSED here, exactly as enforce-codex-review
    # does (its TC-ECR-7). Failing OPEN would re-open the staleness hole from
    # the other side: run the PR-create command from a non-repo cwd and no
    # sha can ever mismatch, so the binding would protect nothing precisely
    # where it is easiest to sidestep.
    if [[ -z "$CA_HEAD_SHA" || -z "$CA_AUDIT_HEAD" || "$CA_AUDIT_HEAD" != "$CA_HEAD_SHA" ]]; then
      jq -n \
        --arg audited "${CA_AUDIT_HEAD:-<the report carries no AUDIT HEAD: line>}" \
        --arg head "${CA_HEAD_SHA:-<did not resolve in the command working directory>}" '{
        "hookSpecificOutput": {
          "hookEventName": "PreToolUse",
          "permissionDecision": "deny",
          "permissionDecisionReason": ("BLOCKED: the compliance audit report is not bound to the commit being PR'"'"'d.\n\n  audited: " + $audited + "\n  HEAD:    " + $head + "\n\nAn audit certifies the commit it read; commits made after it are uncertified, and a report bound to nothing certifies nothing.\n\nIf HEAD did not resolve, run the PR-create command plainly from inside the repository checkout. Otherwise re-run the compliance audit subagent against the current HEAD — its FIRST line must be:\n\n  AUDIT HEAD: <the full 40-character sha of the commit it audited>")
        }
      }'
      exit 0
    fi

    # (2) READ THE VERDICT. The summary line is the LAST `AUDIT COMPLETE:`
    #     line in the file, so an auditor that revised its conclusion is read
    #     on its final word rather than its first.
    CA_SUMMARY=$(grep "^AUDIT COMPLETE:" "$MARKER_FILE" 2>/dev/null | tail -1 || true)
    # ⛔ THIS BLOCK IS SUPERSEDED — IT DESCRIBED v1 OF THE RULE. ⛔
    # It said the protection came from "requiring punctuation rather than merely
    # whitespace", and that the negated spelling "follows from the same regex but
    # is NOT pinned by a test". Both statements were true of v1 and false of the
    # code below it, which is v6. Leaving them here meant this file — the one whose
    # entire thesis is that an overclaiming comment is a defect — carried a comment
    # contradicting the code immediately underneath it. Found by the independent
    # compliance audit, after three cross-family passes and two adjudications had
    # each read this file without noticing.
    #
    # WHAT THE CODE BELOW ACTUALLY DOES, in the order it does it:
    #   * the line SHAPE is anchored: `AUDIT COMPLETE: N/M items verified ...`
    #   * N must be NON-ZERO — a zero-count audit certifies nothing
    #   * the free-words region is LOWERCASE only, because a verdict is uppercase
    #     and prose is not; that is what excludes REJECTED/NEGATIVE/DENIED and any
    #     other shouted verdict WITHOUT enumerating them
    #   * the separator takes `+`, since the em dash is three bytes and a POSIX
    #     bracket expression matches one
    #   * PASSED must be the final token, so a trailing clause cannot ride along
    #   * a negation denylist runs afterwards as belt-and-braces, no longer
    #     load-bearing
    # Pinned by TC-CAV-13 (welds), TC-CAV-13b (letter negations needing no
    # separator), TC-CAV-13c (no count), TC-CAV-14 (legitimate separators) and
    # TC-CAV-2/9/10/11 (the original four shapes).
    #
    # ONE conditional, and it is the PASSED one: BLOCKED and "unreadable" take
    # the same action for the same reason (the audit did not certify this
    # change), so they share a deny that names both rather than a second
    # branch the suite cannot tell from the first.
    # ⛔ THE SEPARATOR MUST NOT BE ABLE TO GLUE A NEGATION ONTO THE VERDICT. ⛔
    # This used to end the optional prefix at ANY non-alnum, non-space character.
    # `-` qualifies, so `NOT-PASSED` parsed as prefix `NOT`, separator `-`, verdict
    # `PASSED` — and was ACCEPTED. So was `BLOCKED-PASSED`. Measured against the old
    # pattern:
    #     AUDIT COMPLETE: 5/14 items verified — NOT-PASSED       -> ACCEPTED
    #     AUDIT COMPLETE: 5/14 items verified — BLOCKED-PASSED   -> ACCEPTED
    #     AUDIT COMPLETE: 5/14 items verified — NOT PASSED       -> rejected
    # A gate written to read the verdict rather than the signature was reading a
    # SUFFIX, which is the same shape-not-fact defect this whole branch closes.
    # Cross-family review (Codex) found it; seven same-family reviewers did not.
    # The separator class now excludes `-` and `_`, so a negation word cannot be
    # welded to the verdict. Em dash, colon, comma and period still separate.
    # TC-CAV-13 pins the two accepted spellings; TC-CAV-2 remains the positive control.
    # ⛔ THE VERDICT IS A WORD, SO REQUIRE THE SPACE THAT MAKES IT ONE. ⛔
    # Two previous attempts at this line were each wrong in a DIFFERENT direction,
    # and the second was wrong in both:
    #   v1  ended the prefix at ANY non-alnum, so `-` welded a negation on:
    #         ... — NOT-PASSED       -> ACCEPTED   (a negative audit opens the PR)
    #   v2  excluded `-` and `_` from the separator class. That still welded on the
    #       punctuation it did not exclude, AND it broke a documented separator:
    #         ... — NOT.PASSED       -> ACCEPTED   (still welds, via `.`)
    #         ... — NOT—PASSED       -> ACCEPTED   (still welds, via the em dash)
    #         ... verified - PASSED  -> REJECTED   (a legitimate audit is BLOCKED)
    #       An over-block here is not benign: it deadlocks every PR.
    # Enumerating which punctuation may separate was the wrong shape of rule. What
    # actually distinguishes a verdict from a weld is the SPACE: `— PASSED` has one,
    # `NOT-PASSED` and `NOT.PASSED` and `NOT—PASSED` do not. So require a non-alnum
    # separator, then at least one space, then PASSED as the final token.
    # Measured on this pattern:
    #   ACCEPT  ... verified — PASSED | - PASSED | : PASSED | , PASSED
    #   reject  ... NOT-PASSED | NOT.PASSED | NOT—PASSED | NOT_PASSED | NOT PASSED
    #   reject  ... — PASSED — but 3 items BLOCKED   (the $ anchor, TC-CAV-9)
    # `NOT PASSED` is rejected because the character before the space is alphanumeric.
    # TC-CAV-13 pins the welds, TC-CAV-14 the legitimate separators — both directions,
    # because this line has now been wrong in each of them once.
    # ⛔ FOURTH SHAPE OF THIS RULE. THE FIRST THREE ALL MATCHED A TAIL. ⛔
    # v1  ended the prefix at any non-alnum:      ... — NOT-PASSED   ACCEPTED
    # v2  excluded `-` and `_`:                   ... — NOT.PASSED   ACCEPTED
    #                                             ... — NOT—PASSED   ACCEPTED
    #     and REJECTED the legitimate             ... verified - PASSED
    # v3  required whitespace before the verdict: ... — NOT — PASSED ACCEPTED
    #     because `.*` simply consumed the negation and the trailing `— PASSED`
    #     satisfied the pattern on its own.
    # Every one of those matched a TAIL inside free prose, and a tail-match cannot
    # be made safe by refining what may precede it — `.*` will always swallow the
    # negation. So this pins the WHOLE LINE. There is no free `.*` left for a
    # negation to sit in, and the verdict is a complete alternation rather than a
    # word the pattern hopes is final.
    # Measured on this grammar:
    #   ACCEPT  ... 14/14 items verified — PASSED | - PASSED   (and BLOCKED, read below)
    #   reject  ... NOT — PASSED | NOT- PASSED | NOT-PASSED | NOT.PASSED | NOT—PASSED
    #   reject  ... — PASSED — but 3 items BLOCKED     (no trailing clause fits)
    #   reject  ... 5/14 BLOCKED, definitely — NOT — PASSED
    # THE COST, STATED: this is stricter than the deny text's prose implies, so an
    # auditor that free-forms its summary line is BLOCKED. That is deliberate — an
    # over-block here costs one re-run, while the under-block it replaces opened a
    # PR on a negative audit — but it means the deny MUST print the exact grammar,
    # which it does immediately below. TC-CAV-13 pins the welds, TC-CAV-14 the two
    # legitimate separators, (An earlier revision cited a TC-CAV-15 that was never written — a comment naming a test that does not exist is the same overclaim class as a test naming behaviour it does not assert.)
    # ⛔ TWO CHECKS, NOT ONE PATTERN. FOUR SINGLE-PATTERN ATTEMPTS ALL FAILED. ⛔
    # v1 ended the prefix at any non-alnum      -> `NOT-PASSED` ACCEPTED
    # v2 excluded `-` and `_`                   -> `NOT.PASSED`, `NOT—PASSED` ACCEPTED
    #                                              and the legitimate `- PASSED` REJECTED
    # v3 required whitespace before the verdict -> `.*` swallowed the negation and the
    #                                              trailing `— PASSED` satisfied it:
    #                                              `— NOT — PASSED` ACCEPTED
    # v4 pinned the whole line                  -> REJECTED the DOCUMENTED spelling
    #                                              `items verified with evidence — PASSED`
    #                                              and broke seven existing cases
    # The mistake was the SHAPE. One positive pattern has to be loose enough for the
    # free prose an auditor legitimately writes AND tight enough to exclude a negation
    # hiding in that same prose. Those pull in opposite directions, which is why every
    # fix to one side broke the other.
    #
    # So: two checks that pull the SAME way.
    #   1. POSITIVE — the line ends in a punctuation separator, whitespace, then PASSED.
    #   2. NEGATIVE — no negation word appears anywhere on the line.
    #
    # Measured, all twelve spellings collected across the four attempts:
    #   ACCEPT  ... 14/14 items verified — PASSED
    #   ACCEPT  ... 14/14 items verified with evidence — PASSED   (the documented form)
    #   ACCEPT  ... 14/14 items verified - PASSED    ACCEPT  ... 1/1 items verified — PASSED
    #   reject  ... — NOT — PASSED   ... — NOT- PASSED   ... — NOT-PASSED
    #   reject  ... — NOT.PASSED     ... — BLOCKED-PASSED
    #   reject  ... 5/14 BLOCKED, definitely — NOT — PASSED
    #   reject  ... — PASSED — but 3 items are BLOCKED   (the $ anchor, TC-CAV-9)
    #   reject  ... 11/14 items verified — BLOCKED
    #
    # ⛔ THE SEPARATOR CLASS TAKES `+`, NOT EXACTLY ONE — THE EM DASH IS 3 BYTES. ⛔
    # A POSIX bracket expression matches a single BYTE, so `[^[:alnum:][:space:]]`
    # matched only the first byte of `—` and the next byte was not a space. The
    # canonical `... items verified — PASSED` was DENIED. `+` consumes all three.
    # ⛔ AND A ZERO-COUNT AUDIT IS NOT A PASS. ⛔ `0/14 items verified — PASSED` was
    # ACCEPTED by every version of this rule including the one whose commit message
    # cites that exact string as the harm it exists to prevent. The verified count
    # must now be non-zero. Found by the independent compliance audit — after three
    # Codex passes and two adjudications had each read this line and not seen it.
    # What it does NOT require is N == M: an auditor that verified 13 of 14 and still
    # certifies PASSED is making a judgement call this gate does not second-guess.
    # Zero is different in kind — it certifies nothing at all.
    # ⛔ A NEGATION NEEDS NO SEPARATOR — IT CAN BE A WORD. THAT KILLED v5. ⛔
    # v5 pinned the region before the separator to alnum+space and asserted that
    # "every negation-before-PASSED needs a SECOND separator". False: a negation
    # made of LETTERS sits in that region and needs no separator at all.
    #     AUDIT COMPLETE: 0/14 items verified REJECTED — PASSED   -> ALLOWED
    #     AUDIT COMPLETE: REJECTED — PASSED                       -> ALLOWED
    # A 0/14 audit opened the PR. Found by adjudication, not by a test — v5's
    # rewrite was a MIRROR: reverting it changed no suite verdict, because every
    # weld TC-CAV-13 knows contains NOT or BLOCKED and so is caught by check 2.
    #
    # THE STRUCTURAL PROPERTY, at last: a VERDICT IS UPPERCASE, PROSE IS NOT.
    # The free-words region is now [[:lower:][:digit:][:space:]]*, so the
    # documented `verified with evidence — PASSED` still passes while REJECTED,
    # NEGATIVE, DENIED or any other shouted verdict cannot sit there — without
    # enumerating a single one of them. The line shape is anchored too, so a bare
    # `AUDIT COMPLETE: REJECTED — PASSED` has no count to match.
    # ⛔ CHECK 2 IS NOW GENUINELY BELT-AND-BRACES. ⛔
    # A denylist covers only the negations someone thought of, and
    # `... verified — REJECTED — PASSED` proved it: REJECTED was not on the list,
    # the positive tail matched, and a 0/14 audit would have opened the PR.
    # Check 1 now pins the region between `items verified` and the separator to
    # ALPHANUMERICS AND SPACES ONLY, so the documented `verified with evidence —
    # PASSED` still passes while any shape needing a SECOND separator — which is
    # what every negation-before-PASSED needs — cannot.
    # ⛔ CHECK 2 IS A DENYLIST, WHICH IS NAMED AS SUCH RATHER THAN DRESSED UP. ⛔
    # Its residual: a negation this list does not know — a different language, an
    # invented word, "NEGATIVE", "REJECTED" — would pass check 2. That is a real gap
    # and it is bounded by check 1, which still requires the line to END in PASSED, so
    # an auditor emitting `— REJECTED` is rejected by check 1 anyway. What check 2 adds
    # is protection against a negation sitting BEFORE a genuine-looking `— PASSED`
    # tail, which is the only shape check 1 cannot see. Widen the list rather than
    # loosening check 1 if a real auditor ever trips it.
    # ⛔ THE COUNT CHECK IS NUMERIC, NOT LEXICAL. ⛔
    # A first version wrote it as the pattern `[1-9][0-9]*`, which is a statement
    # about DIGITS rather than about a NUMBER, and so was wrong in both directions
    # at once:
    #     1/0   items verified — PASSED  -> ACCEPTED   (a zero TOTAL is impossible)
    #     01/14 items verified — PASSED  -> REJECTED   (padding is legitimate)
    # The second is the dangerous one: an over-block here deadlocks every PR, and the
    # documented grammar is `[N]/[M]` with no rule against padding.
    # So the pattern above matches the SHAPE, and the two numbers are compared
    # arithmetically here. `10#` forces base ten, or `08` would be an octal error
    # rather than eight.
    CA_VERIFIED=$(sed -nE 's|^AUDIT COMPLETE:[[:space:]]+([0-9]+)/([0-9]+).*|\1|p' <<< "$CA_SUMMARY" | head -1)
    CA_TOTAL=$(sed -nE 's|^AUDIT COMPLETE:[[:space:]]+([0-9]+)/([0-9]+).*|\2|p' <<< "$CA_SUMMARY" | head -1)
    CA_COUNTS_SANE=no
    if [[ "$CA_VERIFIED" =~ ^[0-9]+$ && "$CA_TOTAL" =~ ^[0-9]+$ ]] \
       && (( 10#$CA_VERIFIED > 0 )) && (( 10#$CA_TOTAL > 0 )); then
      CA_COUNTS_SANE=yes
    fi

    if ! grep -qE '^AUDIT COMPLETE:[[:space:]]+[0-9]+/[0-9]+[[:space:]]+items[[:space:]]+verified[[:lower:][:digit:][:space:]]*[^[:alnum:][:space:]]+[[:space:]]+PASSED[[:space:]]*$' <<< "$CA_SUMMARY" \
       || [[ "$CA_COUNTS_SANE" != "yes" ]] \
       || grep -qiE '(^|[^[:alnum:]])(NOT|BLOCKED|FAIL|FAILED|INCOMPLETE|UNVERIFIED)([^[:alnum:]]|$)' <<< "$CA_SUMMARY"; then
      # Quote the audit's OWN summary line back. A gate that blocks without
      # saying which audit blocked it sends the reader hunting for a file they
      # do not know the name of.
      jq -n --arg summary "$CA_SUMMARY" --arg root "$REMEDY_DIR" '{
        "hookSpecificOutput": {
          "hookEventName": "PreToolUse",
          "permissionDecision": "deny",
          "permissionDecisionReason": ("BLOCKED: the compliance audit ran but did NOT report PASSED. Its own summary line reads:\n\n  " + $summary + "\n\nThis gate reads the verdict, not just the signature. The recognised grammar is:\n\n  AUDIT COMPLETE: [N]/[M] items verified — PASSED|BLOCKED\n\nIf that line says BLOCKED, the auditor could not verify the workflow was followed: read " + $root + "/.audit-complete, fix the ❌ items it names, and re-run the audit against the current HEAD.\n\nIf it says anything else — an invented word, or a line that trails off — the verdict is unreadable and the hook denies rather than guessing. A gate that cannot establish the audit was satisfied has not established it.")
        }
      }'
      exit 0
    fi

    # Verdict PASSED, bound to this exact HEAD — allow PR creation.
    # Do NOT delete the marker here. PreToolUse runs BEFORE the command; if another
    # gate DENIES this same `gh pr create`, the command never runs, and deleting here
    # would force a needless re-audit on retry (gates failing in rotation — the
    # deadlock this fix removes). Single-use is enforced on SUCCESS by the PostToolUse
    # hook consume-pr-markers.sh, which deletes this marker only after `gh pr create`
    # actually creates a PR. A DENY leaves the marker intact (idempotent retry).
    exit 0
  fi
  # File exists but is empty or lacks signature — treat as invalid
  # (do not delete — the agent can inspect what's wrong)
fi

# NO TRANSCRIPT FALLBACK.
#
# A previous version grep'd the transcript for "compliance auditor" or
# "compliance audit" as a fallback. That created the same security hole
# that was closed in enforce-pr-skill.sh and enforce-chief-of-staff.sh:
# once those strings appeared anywhere in the session (user prompt,
# handover entry, PR body, prior block message), every subsequent
# `gh pr create` bypassed the marker check.
#
# Worse: both enforce-pr-skill.sh and this hook gate `gh pr create`. If
# one hook's fallback leaks, the PR's stated Independence Principle
# claim ("orchestrator does not grade own compliance") is half-broken —
# the "compliance audit" keyword appears in handover comments, PR
# bodies, and Jira comments as normal workflow text, permanently
# satisfying the fallback after the first mention.
#
# The marker file is now the ONLY gate. The audit subagent must create
# ~/.claude/.audit-complete explicitly. Each PR requires a fresh audit.

# BLOCK: PR creation without active audit marker
jq -n --arg root "$REMEDY_DIR" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": ("BLOCKED: `gh pr create` called without a valid compliance audit report.\n\nThe orchestrator CANNOT grade its own compliance — this is the same anti-pattern as the implementing agent reviewing its own code. Past sessions showed the self-check reporting ✅ when reality was ❌ (missing Jira comments, inline PR body, skipped skill invocations).\n\nAn empty `touch " + $root + "/.audit-complete` does NOT satisfy the check — the file must contain the audit report, be keyed to the current HEAD, and end with a line starting \"AUDIT COMPLETE:\" whose verdict is PASSED.\n\nSpawn the compliance audit subagent (see /flow Step 15):\n\n  Agent(\n    subagent_type: \"general-purpose\",\n    model: \"opus\",\n    prompt: \"[DELEGATED] You are the compliance auditor for DEV-XXXX. Verify the 14 compliance items with evidence from handover.md — grep matches, file existence, command output. Do NOT trust orchestrator claims. Write your findings to " + $root + "/.audit-complete. Its FIRST line must bind the report to the commit you audited:\\n\\n    AUDIT HEAD: $(git rev-parse HEAD)\\n\\nThen ONE item per line (✅/❌ + evidence). End the file with a summary line:\\n\\n    AUDIT COMPLETE: [N]/[M] items verified — PASSED|BLOCKED\\n\\nReport the verdict you actually reached. BLOCKED is a valid, expected outcome — the hook reads it and stops the PR, which is the point. Do NOT write PASSED to unblock yourself.\"\n  )\n\n⛔ The ORCHESTRATOR (main agent) must spawn and AWAIT this audit BEFORE delegating PR creation. If you are a DELEGATED PR-creation subagent and you see this, do NOT spawn the audit yourself — a subagent cannot reliably await a grandchild; return to the orchestrator so it runs the audit first, then re-delegate.\n\nThe audit must run AFTER verification and BEFORE PR creation.")
  }
}'
exit 0
