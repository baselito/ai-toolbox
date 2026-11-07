#!/bin/bash
# enforce-jira-delegation.sh
#
# PreToolUse hook matching on the Bash tool.
# Blocks acli jira WRITE operations (comment create, assign, transition)
# unless a valid delegation token exists (~/.claude/.jira-delegation-token).
#
# Why: jira-workflow-steward is the designated Haiku agent for all Jira
# write operations. Running acli commands on the orchestrator agent costs
# 30x more for work that Haiku handles faster and cheaper. The flow.md
# rules say "ALL acli calls go through jira-workflow-steward" but without
# a structural gate, the agent routes Jira ops through itself to save
# "the overhead" of spawning a subagent.
#
# Detection:
#   - Token-file approach: the orchestrator creates
#     ~/.claude/.jira-delegation-token before spawning jira-workflow-steward.
#   - The hook checks if the token file exists and is < 3600 seconds old.
#   - If valid: allows the operation (session-level — not consumed on use).
#   - If missing or expired (> 3600s): blocks the operation.
#   - This follows the same pattern as push-safety.sh (.push-ready).
#
# Previous approach (REMOVED — broken):
#   The hook previously inspected the first 5 lines of the JSONL transcript
#   for "subagent_type": "jira-workflow-steward". This failed because
#   subagents share the parent's transcript file, so the structured JSON
#   field was not reliably at the expected position. Result: both the
#   orchestrator AND the steward subagent were blocked — no automated path
#   worked.
#
# Exempt commands (read-only, safe on any model):
#   - acli jira workitem view
#   - acli jira workitem search
#   - acli jira board
#   - acli jira auth
#   - `acli jira <verb> --help` / `--version` in its bare form only: the verb
#     path plus the trailing help flag and nothing else. A write carrying real
#     operands is NOT exempt just because a help flag appears somewhere in it.
#
# Every exemption is decided on the command HEAD (see HEAD_CLASS below). Note
# what that does and does not buy: HEAD_CLASS distinguishes a bare `acli` head
# from anything else, so class "other" covers BOTH a genuine non-acli wrapper
# and an acli write invoked by full path or through env/sudo/timeout. Head
# class alone therefore cannot stop argument text from satisfying an exemption —
# every exemption pairs it with a second constraint. Three of the four ANCHOR
# their regex (project list/view, --help/--version, python3-transition). The
# read-only exemption deliberately does NOT: it has to keep accepting `$TICKET`
# variables and quoted JQL with parentheses (TC-JD-59/60), so its second
# constraint is HEAD_CLASS == "read" plus the metacharacter guards, not an
# anchor. The claim that head class alone was enough was wrong and cost a live
# bypass.
#
# Exempt contexts (already enforced by other mechanisms):
#   - acli jira workitem transition inside python3 (transition script)
#   - These are caught by enforce-transition-script.sh

set -euo pipefail

# Guard: ensure jq is available. Fail CLOSED — see enforce-auto-poll.sh.
if ! command -v jq &>/dev/null; then
  cat <<'__DENY__'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: jq is required for hook enforcement (enforce-jira-delegation). Install jq (brew install jq / apt install jq / yum install jq) to continue. Hook fails closed for safety."}}
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

# Exit early if not an acli jira command.
# Also exempt git commit commands — the hook was false-triggering on commit
# messages that mention "acli jira" in their body text (e.g. heredoc messages
# documenting hook changes). A git commit is never an acli write operation.
# All detectors below match with here-strings (`<<<`), never `echo | grep`:
# under `set -euo pipefail` the pipe form can SIGPIPE (141) on large multiline
# input and flip a deny to an allow (static guard: TC-JD-11).
if ! grep -qE "acli[[:space:]]+jira" <<< "$COMMAND"; then
  exit 0
fi
# Exempt standalone git commit commands. The hook was false-triggering on
# commit messages that contain "acli jira" text (e.g. documenting hook changes).
# A git commit is never an acli write operation.
#
# Approach: if the command starts with `git commit`, check whether `acli`
# appears as a SEPARATE command (after a shell separator like &&, ||, ;, |,
# or newline). If acli only appears within the git commit's arguments
# (i.e. inside the message text), it's safe to exempt.
#
# This avoids the false-positive where `git commit -m "fix: acli jira; cleanup"`
# would be blocked because the semicolon is inside the quoted message, not a
# real shell separator.
if grep -qE "^\s*git[[:space:]]+commit" <<< "$COMMAND"; then
  # Check if acli appears as a separate command after a shell separator or newline.
  # Extract everything after the FIRST shell separator, then check if the
  # remainder contains acli. If no separator exists, acli is only in git
  # commit args → safe.
  #
  # ⛔ MUST match the FIRST separator, not the last. The previous version used
  # greedy `.*[;&|]` which consumed up to the LAST separator — so
  # `git commit -m x && acli jira ... && echo done` would yield only
  # `echo done` as AFTER_SEPARATOR, missing the acli in the middle.
  # Using `[^;&|]*` (non-separator chars) stops at the FIRST separator.
  AFTER_SEPARATOR=$(echo "$COMMAND" | sed -n 's/^[^;&|]*[;&|]\{1,2\}[[:space:]]*//p')
  # Also check for newline-separated commands
  if [[ "$COMMAND" == *$'\n'* ]]; then
    AFTER_NEWLINE=$(echo "$COMMAND" | tail -n +2)
  else
    AFTER_NEWLINE=""
  fi
  # If neither the post-separator nor post-newline text contains acli, exempt
  if ! grep -qE "acli" <<< "$AFTER_SEPARATOR" \
    && ! grep -qE "acli" <<< "$AFTER_NEWLINE"; then
    exit 0
  fi
  # acli appears after a separator → fall through to delegation check
fi

# ---------------------------------------------------------------------
# HEAD-COMMAND CLASSIFICATION
#
# Decide on the command HEAD — the command actually being invoked — not on
# text that merely appears somewhere in its arguments.
#
# WHY (2026-08-25 security review; both bypasses were measured against the
# shipped hook, both allowed an undelegated WRITE with no token):
#   1. CRITICAL — `acli jira workitem comment create --key X --body "..." # --help`
#      matched the --help/--version exemption below. `#` is not one of the
#      metacharacters the clean-stance guards reject, and a trailing shell
#      comment is never executed, so the write ran for real while the inert
#      `--help` satisfied the exemption's UNANCHORED regex.
#   2. HIGH — `acli jira workitem comment create --key X --body "see acli
#      jira board list output"` matched the read-only exemption because the
#      COMMENT BODY quoted a read-only command.
# The control for both — the same write with a plain body — was correctly
# denied, which isolates the cause to the argument text, not the verb.
#
# THE RULE: an exemption may not fire when the head is an acli-jira write,
# regardless of what its arguments contain. Classification happens once,
# here; each exemption below consults HEAD_CLASS.
#
# FAILS CLOSED, and that is the default: HEAD_CLASS starts at "write", so an
# unrecognised verb, a bare `acli jira` with no verb, and any head this
# parser cannot place all stay "write" and require the delegation token.
# Only the explicit read allowlist moves it to "read".
#
# Chained and smuggled commands are NOT this gate's job — a read head with a
# `&&`/`;`/`|`/`$(`/`<(`/`>(`/newline payload is still rejected by the
# per-exemption clean-stance guards below, which are unchanged. This gate
# closes the case those guards cannot see: a write at the head whose own
# arguments quote an exempt token.
# ---------------------------------------------------------------------

# Only the FIRST line participates in classification. Every exemption below
# independently rejects a multi-line command via its own LF/CR/VT/FF guard,
# so this classification never decides a multi-line case by itself.
HEAD_LINE="${COMMAND%%$'\n'*}"
# Strip leading whitespace and leading `NAME=value` environment assignments
# (`FOO=1 acli jira ...`) so that prefix cannot hide the real head word.
#
# The VALUE is a sequence of segments — bare characters, a "double-quoted" run,
# or a 'single-quoted' run — so a value containing whitespace is stripped whole
# (`FOO="a b" acli jira workitem view X`). The earlier `[^[:space:]]*` value
# stopped at the first space and left `b" acli jira workitem view X` as the
# head, which classified as "other" and denied a plain read its exemption
# (TC-JD-71/72). Direction of the error was fail-CLOSED, never a bypass.
#
# Widening the value cannot widen an exemption: an unterminated quote matches
# no alternative, so the group fails and NOTHING is stripped (fail-closed), and
# a longer strip only exposes the real head word — `acli` contains no `=`, so
# the command word itself can never be consumed as an assignment. TC-JD-73 is
# the control that pins that: a quoted spaced prefix in front of a WRITE head
# is still blocked.
HEAD_CMD=$(sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=([^[:space:]"'"'"']|"[^"]*"|'"'"'[^'"'"']*'"'"')*[[:space:]]+)*//' <<< "$HEAD_LINE")

HEAD_CLASS="write"
if grep -qE "^acli[[:space:]]+jira[[:space:]]+(workitem[[:space:]]+(view|search)|board|auth|project[[:space:]]+(list|view))([[:space:]]|$)" <<< "$HEAD_CMD"; then
  # The head is one of the read-only verbs the exemptions below speak for.
  HEAD_CLASS="read"
elif ! grep -qE "^acli([[:space:]]|$)" <<< "$HEAD_CMD"; then
  # The head is some OTHER command — a wrapper (`env`, `timeout`, `xargs`),
  # or a command whose argument text merely mentions acli. The acli-argument
  # exemptions below cannot speak for it, so they are skipped. The two
  # exemptions that legitimately have a non-acli head keep their own
  # dedicated logic: `git commit` above, and `python3` transition below.
  # Narrowing note: a read invoked through a wrapper now needs the token.
  # Measured against this repo — every non-head-position acli invocation
  # that exists here (`if acli jira auth status &>...;`, `echo TOKEN | acli
  # jira auth login`) already carries a metacharacter the guards below
  # reject, so no working invocation changes behaviour.
  HEAD_CLASS="other"
fi

# Exempt READ-ONLY commands — these are safe on any model
# Matches: acli jira workitem view, search; acli jira board *; acli jira auth *
#
# SECURITY (2026-07-07 security review, TC-JD-23/24-27): this regex is
# unanchored, so without a control-char guard a command with an embedded
# newline would match "acli jira workitem view ..." on line 1 and exit 0
# (ALLOW) before line 2 — a smuggled write op — was ever inspected, e.g.
# `acli jira workitem view TICKET-1\nacli jira workitem comment create ...`.
# Mirrors the project-list/view clean-stance guard below: only take the
# exemption when the command has no control-char line/vertical separator
# (LF/CR/VT/FF). A command carrying any of those falls through to the
# same delegation-required path it would hit if the regex simply hadn't
# matched (fail-closed).
#
# SECURITY (TC-JD-33/35/36): the newline guard alone was insufficient — the
# match is unanchored, so a SINGLE-LINE shell chain smuggled a write the same
# way (`acli jira workitem view X && acli jira workitem comment create ...`,
# or `;`/`|`). Reject any chain/substitution operator (`;`, `&`, `|`, backtick,
# `$(`, and process substitution `<(` / `>(` — which spawns its inner command
# immediately, TC-JD-38/39) too, so the exemption only fires for a lone read.
# Over-blocks a read that legitimately pipes/backgrounds (rare) — fail-safe: it
# just requires the delegation token, it never allows an undelegated write.
#
# SECURITY (TC-JD-42/43/44/45): the guards above reject a SMUGGLED write but
# cannot see a write at the HEAD whose own argument text quotes a read-only
# command (`--body "see acli jira board list output"`) — the unanchored regex
# matched that text and exempted the write. HEAD_CLASS == "read" is the gate
# for that: the head must itself be one of the read verbs.
if [[ "$HEAD_CLASS" == "read" ]] \
   && [[ "$COMMAND" != *$'\n'* ]] \
   && [[ "$COMMAND" != *$'\r'* ]] \
   && [[ "$COMMAND" != *$'\v'* ]] \
   && [[ "$COMMAND" != *$'\f'* ]] \
   && [[ "$COMMAND" != *';'* ]] \
   && [[ "$COMMAND" != *'&'* ]] \
   && [[ "$COMMAND" != *'|'* ]] \
   && [[ "$COMMAND" != *'`'* ]] \
   && [[ "$COMMAND" != *'$('* ]] \
   && [[ "$COMMAND" != *'<('* ]] \
   && [[ "$COMMAND" != *'>('* ]] \
   && grep -qE "acli[[:space:]]+jira[[:space:]]+(workitem[[:space:]]+(view|search)|board|auth)" <<< "$COMMAND"; then
  exit 0
fi

# Strict read-only exemption for `acli jira project list` / `project view`.
# DELIBERATELY CONSERVATIVE: only the clean, SINGLE-LINE, standalone form with
# metacharacter-free arguments is exempt. Any shell separator (; & |), command
# substitution ($(...) / backtick / <(...)), quote, newline, or other control-char
# line/vertical separator means the command is not this simple form -> fall through
# -> delegation token required (fail-closed).
# Bypass-free BY CONSTRUCTION: executing a hidden second command requires a
# metacharacter the anchored pattern forbids, and the control-char guard below
# rejects newline (LF) AND carriage-return (CR), vertical-tab (VT), and form-feed
# (FF) so the exempt form is strictly single-line with no control whitespace.
# CR/VT/FF are not bash command separators (not exploitable today), but the
# clean-stance guard rejects them so the exempt form has a clear invariant:
# "contains no control-char line or vertical separator of any kind."
# (We chose this strict form after precise command-vs-data parsing repeatedly
# introduced security bypasses on this PR; the pre-existing workitem/board/auth
# exemptions above are unchanged and out of scope.)
#
# HEAD_CLASS == "read" is redundant here TODAY — the anchored `^...$` pattern
# already pins `acli jira project list|view` at the head, and that head is in
# the read allowlist. It is stated anyway so the head-gate invariant ("no
# exemption fires when the head is a write") holds uniformly across all four
# exemptions, and so it still holds if this pattern is ever loosened.
if [[ "$HEAD_CLASS" == "read" ]] \
   && [[ "$COMMAND" != *$'\n'* ]] \
   && [[ "$COMMAND" != *$'\r'* ]] \
   && [[ "$COMMAND" != *$'\v'* ]] \
   && [[ "$COMMAND" != *$'\f'* ]] \
   && grep -qE "^[[:space:]]*acli[[:space:]]+jira[[:space:]]+project[[:space:]]+(list|view)([[:space:]]+[^[:space:];&|\$\`()<>'\"\\]+)*[[:space:]]*$" <<< "$COMMAND"; then
  exit 0
fi

# Exempt introspection flags — --help and --version are read-only on any command.
# SECURITY (2026-07-07 review of this branch — CRITICAL): this exemption uses an
# unanchored regex with a greedy `.*`, so WITHOUT the control-char guard a
# newline-smuggled write executes for real while `--help`/`--version` on the OTHER
# line satisfies the match — a full delegation bypass with no token required, the
# most permissive of the three same-class gaps this branch closes. Same LF/CR/VT/FF
# clean-stance guard as the read-only and project exemptions above: a control-char
# command falls through to the fail-closed delegation-required path. Regression
# tests: TC-JD-31 (blocked) / TC-JD-32 (single-line still allowed).
# SECURITY (TC-JD-34/39): also reject single-line shell chain/substitution
# operators (`;`, `&`, `|`, backtick, `$(`, and process substitution `<(` / `>(`)
# — otherwise `acli jira ... --help && acli jira workitem comment create ...` (or
# a `<(...)` process substitution) smuggles a write past the unanchored `.*`.
#
# SECURITY (2026-08-25 — CRITICAL, TC-JD-46..50): those guards still let a real
# write through, because the old pattern was `acli jira .*--(help|version)` —
# unanchored with a greedy `.*`, so a `--help` ANYWHERE satisfied it. Appending
# a shell comment (` # --help`) to a write matched it (and `#` is absent from
# every guard list above — deliberately, since on a READ head a trailing
# comment is inert and harmless), and so did a `--help` sitting inside the
# write's own `--body` text. Both ran the write undelegated.
#
# The pattern is now ANCHORED to a form that carries no operands: `acli jira`,
# then bare lowercase verb words, then a SINGLE trailing `--help`/`--version`
# and nothing else. What that buys, precisely: no `--body`, `--key`, `--status`
# or `--assignee` payload can be present, because any second token starting
# with `-` breaks the match, and the help flag must be the final token. The
# verb path is additionally capped at 3 words — the deepest path in the
# canonical reference (agents/jira-workflow-steward.md) is `workitem comment
# create` — so a bare lowercase positional operand cannot ride along either
# (`... create foo --help` is a 4th word and does not match). So
# `acli jira workitem comment create --help` (the documented way to verify CLI
# syntax — rules/agents.md "CLI Command Verification") stays exempt, while
# `... create --key X --body "..." # --help` does not match at all.
# `--help` on a READ verb needs nothing from this block — the read-only and
# project exemptions above already cover it.
# Anchoring is safe HERE but was measured to be wrong for the read-only
# exemption, which must keep accepting `$TICKET` variables and quoted JQL with
# parentheses; a help invocation has no such operands to interpolate.
# The LF/CR/VT/FF guard is still required even though the pattern is anchored:
# grep applies `^...$` per LINE, so on a two-line command it would match the
# help line and never see the write on the next one.
if [[ "$COMMAND" != *$'\n'* ]] \
   && [[ "$COMMAND" != *$'\r'* ]] \
   && [[ "$COMMAND" != *$'\v'* ]] \
   && [[ "$COMMAND" != *$'\f'* ]] \
   && [[ "$COMMAND" != *';'* ]] \
   && [[ "$COMMAND" != *'&'* ]] \
   && [[ "$COMMAND" != *'|'* ]] \
   && [[ "$COMMAND" != *'`'* ]] \
   && [[ "$COMMAND" != *'$('* ]] \
   && [[ "$COMMAND" != *'<('* ]] \
   && [[ "$COMMAND" != *'>('* ]] \
   && grep -qE "^[[:space:]]*acli[[:space:]]+jira([[:space:]]+[a-z][a-z0-9-]*){0,3}[[:space:]]+--(help|version)[[:space:]]*$" <<< "$COMMAND"; then
  exit 0
fi

# Exempt transition commands that run INSIDE the python3 transition script.
#
# MATCHING RULE: python3 must appear BEFORE acli in the command string.
# The previous version allowed any command that contained both `python3`
# and `acli jira workitem transition` anywhere — so a crafted command
# like `python3 -c 'import os' && acli jira workitem transition ...`
# would match (python3 is present, acli transition is present) and bypass
# the delegation requirement, even though python3 isn't actually wrapping
# the acli call. The order-sensitive match prevents that bypass.
#
# ⛔ LOAD-BEARING PROPERTY: [^;&|]* is intentionally character-level,
# NOT shell-parse-level. It blocks at any semicolon, pipe, or &&
# regardless of quoting context. This means commands like
# `python3 "evil; acli jira workitem transition"` do NOT match, because
# the regex stops at the semicolon inside the quoted string even though
# a real shell would treat that semicolon as a literal character. This
# property is security-critical: do NOT "fix" the character class to be
# more permissive or to understand shell quoting — it would reopen
# bypass vectors. See scripts/verify-hooks.sh TC-JD-5/6/7 for regression
# tests and docs/concepts/independence-principle.md for the threat model.
#
# Note: enforce-transition-script.sh has a simpler grep -q "python3"
# presence check. That hook provides the initial exemption for legitimate
# script usage; THIS hook provides the tighter order-sensitive guard.
# The asymmetry is intentional — see comments in enforce-transition-script.sh.
#
# SECURITY (2026-07-07 security review, TC-JD-28/29/30): [^;&|]* is a
# negated character class, which (unlike `.`) matches newline by default —
# so a command with an embedded newline could match "python3 ... acli jira
# workitem transition" entirely on line 1 and exit 0 (ALLOW) before line 2 —
# a smuggled write op — was ever inspected. Mirrors the project-list/view
# clean-stance guard above: only take the exemption when the command has no
# control-char line/vertical separator (LF/CR/VT/FF). A command carrying
# any of those falls through to the same delegation-required path it would
# hit if the regex simply hadn't matched (fail-closed).
#
# SECURITY (2026-08-25, TC-JD-51): this regex is unanchored on its LEFT side
# too, so a write at the head whose argument text mentions the wrapper —
# `acli jira workitem comment create --body "python3 acli jira workitem
# transition"` — satisfied `python3[^;&|]*acli...transition` and was exempted.
# `HEAD_CLASS != "write"` is NOT sufficient on its own, and the earlier
# comment here claimed it was. Class "other" means only "the head is not
# literally acli" - so an acli WRITE invoked as /usr/local/bin/acli, or via
# env / sudo / timeout / command / a variable, classifies as "other" and
# satisfied this gate. Six such heads were verified ALLOW with no token,
# reachable with an ordinary body (a comment describing a transition script).
# The regex is therefore ANCHORED at the command head as well: python3 must be
# the first word, so argument text can never satisfy it.
#
# ⚠️ HONEST SCOPE of the `HEAD_CLASS != "write"` conjunct below: with the regex
# anchored, it is TAUTOLOGICAL TODAY and adds nothing. If the anchored regex
# matches then line 1 begins with `python3`, `python3` is not a `NAME=value`
# assignment, so HEAD_CMD begins with `python3`, which is not `acli` — the head
# always classifies "other". It is kept as a defence-in-depth conjunct that
# holds the head-gate invariant ("no exemption fires on a write head") uniformly
# across all four exemptions, and so it still holds if the anchor is ever
# loosened. It is NOT a second independent narrowing, and an earlier version of
# this comment claiming the pair was "strictly narrower than either" was wrong.
if [[ "$HEAD_CLASS" != "write" ]] \
   && [[ "$COMMAND" != *$'\n'* ]] \
   && [[ "$COMMAND" != *$'\r'* ]] \
   && [[ "$COMMAND" != *$'\v'* ]] \
   && [[ "$COMMAND" != *$'\f'* ]] \
   && grep -qE "^[[:space:]]*python3[^;&|]*acli[[:space:]]+jira[[:space:]]+workitem[[:space:]]+transition" <<< "$COMMAND"; then
  exit 0
fi

# This is a WRITE operation (comment, assign, transition outside script).
# Check for a valid delegation token.
#
# DETECTION: Token-file approach. The orchestrator creates
# ~/.claude/.jira-delegation-token before spawning jira-workflow-steward.
# The hook validates the token (< 3600 seconds old, session-level — not consumed), and allows.
# Without a valid token, the write is blocked.
#
# This replaces the previous transcript-based detection (head -5 of JSONL
# transcript looking for "subagent_type": "jira-workflow-steward") which
# failed because subagents share the parent's transcript file — the
# structured JSON field was not reliably in the first 5 lines.
#
# The token is session-level: created once per workflow, valid for 3600 seconds
# (1 hour), NOT consumed on use. The orchestrator touches it once at workflow
# start; all Jira steward spawns within that session share the same token.
# This avoids the overhead of creating a fresh token before each of the 8+
# steward spawns per workflow while still blocking the orchestrator from bypassing delegation.
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
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "BLOCKED: neither HOME nor CLAUDE_STATE_DIR is set, so the Jira gate cannot locate the delegation token that authorises a Jira write. Without it, it cannot tell a delegated write from a direct one.\n\nA gate that cannot find its own evidence has not been satisfied, so it fails closed.\n\nThis cannot be fixed from inside a Bash tool call — every call is a fresh shell, so an `export` here does not survive to the next one. Set HOME (or CLAUDE_STATE_DIR) in the environment the agent itself runs in — the `env` block of ~/.claude/settings.json, or the container/CI environment — and start a new session."}}
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

DELEGATION_TOKEN="$STATE_DIR/.jira-delegation-token"
if [[ -f "$DELEGATION_TOKEN" ]]; then
  if [[ "$(uname)" == "Darwin" ]]; then
    FILE_AGE=$(( $(date +%s) - $(stat -f %m "$DELEGATION_TOKEN") ))
  else
    FILE_AGE=$(( $(date +%s) - $(stat -c %Y "$DELEGATION_TOKEN") ))
  fi
  if [[ "$FILE_AGE" -lt 3600 ]]; then
    exit 0  # Session token valid — allow without consuming
  fi
  rm -f "$DELEGATION_TOKEN"
fi

# Determine which operation is being attempted for a clearer error message
OPERATION="unknown"
if grep -qE "acli[[:space:]]+jira[[:space:]]+workitem[[:space:]]+comment" <<< "$COMMAND"; then
  OPERATION="comment"
elif grep -qE "acli[[:space:]]+jira[[:space:]]+workitem[[:space:]]+assign" <<< "$COMMAND"; then
  OPERATION="assign"
elif grep -qE "acli[[:space:]]+jira[[:space:]]+workitem[[:space:]]+transition" <<< "$COMMAND"; then
  OPERATION="transition"
elif grep -qE "acli[[:space:]]+jira[[:space:]]+workitem[[:space:]]+create" <<< "$COMMAND"; then
  # create is now a routine steward operation (ticket creation via the
  # Ticket Description Template) — label it so the blocked-without-token
  # error message says "create" instead of the "unknown" fallback.
  OPERATION="create"
fi

# Extract a short excerpt of the command (first 200 chars) to include in the
# error message. This gives the agent actionable context — previously the
# OPERATION="unknown" fallback produced a useless message for Jira writes
# that didn't match comment/assign/transition (e.g. acli jira workitem update,
# delete, label). Truncating prevents unbounded error messages on pathological
# inputs.
COMMAND_EXCERPT=$(echo "$COMMAND" | head -c 200)

# BLOCK: Jira write operation without delegation token
jq -n --arg op "$OPERATION" --arg cmd "$COMMAND_EXCERPT" --arg root "$REMEDY_DIR" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": ("BLOCKED: acli jira " + $op + " operation requires a delegation token. Running Jira writes on the orchestrator costs 30x more — delegate to jira-workflow-steward (Haiku).\n\nCommand attempted:\n  " + $cmd + "\n\nCorrect pattern — create the session token once, then spawn the steward for each operation:\n\n  touch " + $root + "/.jira-delegation-token\n  Agent(\n    subagent_type: \"jira-workflow-steward\",\n    prompt: \"Perform this Jira operation: " + $op + " on ticket DEV-XXXX. [details]\"\n  )\n\nThe token is valid for 3600 seconds (1 hour) and shared across the workflow session. Create it once at workflow start — no need to re-create before each steward spawn.\n\nExempt operations (no token needed):\n  - acli jira workitem view / search\n  - acli jira board *\n  - acli jira auth *\n  - acli jira project list / view (clean standalone form only; project create/delete/edit are writes)\n  - acli jira <verb> --help / --version in its bare form (verb path + the help flag and nothing else)\n\nExemptions are decided on the command HEAD: a write is not exempt because a read-only command or a --help flag appears inside its arguments (e.g. in --body text or after a # comment).")
  }
}'
exit 0
