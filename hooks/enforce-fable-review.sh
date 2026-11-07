#!/bin/bash
# enforce-fable-review.sh
#
# PreToolUse hook matching on the Bash tool.
# Blocks `gh pr create` unless a Fable adjudication has been recorded for the
# EXACT commit being PR'd.
#
# WHAT "ADJUDICATION" MEANS HERE (issue #156): a pre-push pass in which the
# orchestrator tier reads the final diff and decides whether the change is
# what the ticket asked for. It is the judgment step that sits between "the
# tests are green" and "open the PR" — the one the other gates do not cover.
# enforce-pr-skill proves the PR BODY came from the template; the compliance
# audit proves the WORKFLOW was followed; the Codex gate proves an outside
# model looked. None of them establishes that anyone weighed the change
# itself. This does.
#
# WHY A HOOK AND NOT PROSE: it is the same argument as every sibling gate in
# this directory. An instruction to adjudicate before pushing is an
# instruction, and a rule that lives only in session memory dies with the
# session — which is the fragility issue #156 exists to remove. The marker is
# bound to a sha so the reviewed thing has to be the pushed thing; a marker
# satisfiable by any past review is the #153 defect wearing different clothes.
#
# ADVISORY, NEVER AUTHORITY — the same contract rules/performance.md gives the
# Codex gate. This hook checks that the adjudication HAPPENED and that it
# covered this commit. It has no opinion on what the adjudication concluded,
# and it is not a place to encode one: a gate that could veto on the substance
# of a review would be making the decision instead of recording it.
#
# THE MARKER, and it has exactly ONE word in its vocabulary:
#
#   ~/.claude/.fable-review-complete, one line per commit:
#     reviewed <full-HEAD-sha>       adjudicated; allow
#
# ⛔ NO PRODUCER SHIPS WITH THIS HOOK. ⛔ Nothing in the toolbox writes
# .fable-review-complete yet — the marker grammar and the deny message below
# ARE the specification, and the deny tells the reader the exact command that
# satisfies it. That is enough to be unblockable, and it is deliberately not
# enough to be automatic: which workflow step owns the adjudication (and
# whether `finishing-a-development-branch` should record it) is a decision for
# the person reviewing this, not something to infer from a test list. Until a
# producer exists, expect to satisfy this by hand on the first PR after
# install. This paragraph is the honest version of "wire it up later".
#
# WHY THERE IS NO `unavailable` ESCAPE (H8), and why the earlier design call
# that added one was wrong. It was copied from enforce-codex-review.sh, and the
# copy does not carry over, for two reasons that are the same reason:
#
#   * Codex's escape is bounded by a fact OUTSIDE the agent — the CLI is
#     missing, the workspace spend cap is hit, `codex exec` timed out. There is
#     no equivalent fact here. There is no state of the world in which an
#     orchestrator that is executing Bash cannot read its own diff, so
#     "unavailable" would never be TRUE of this pass.
#   * Codex's `unavailable` line is written by a PRODUCER — the codex-review
#     skill, only after a real attempt failed. This gate has no producer at
#     all. So `unavailable` would not be the rare escape hatch used when the
#     pass cannot run; it would be the ONLY path, hand-written every time,
#     because it is one word shorter than the honest one and never requires
#     doing the thing. The gate would certify nothing from its first PR
#     onward, while reporting that it did.
#
# An escape hatch with no other path through it is a hole with a label on it.
# So the gate ships with `reviewed` only, the first PR after install blocks
# LOUDLY, and that is the intended behaviour rather than a rough edge. The
# outage word goes in the SAME change that adds a producer able to tell "the
# pass could not run" from "nobody ran it". TC-EFR-5 pins the rejection and
# TC-EFR-5b pins that the deny does not advertise a word this hook refuses —
# a deny naming a remedy the gate rejects is issue #150's trap in a new file.
#
# INSTALLED BY scripts/install.sh IN THE CHECKED FORM (issue #160).
# install.sh copies hooks one `cp` per NAME — there is no `hooks/*.sh` glob (the
# `chmod +x` at the end of that block is a glob, which is easy to mistake for
# one), so a new hook that nobody adds a line for is registered, absent, and
# silently permissive: the command exits 127, which is not exit 2, so PreToolUse
# fails OPEN while the install prints success. That is issue #145's class, and
# this hook shipped that way for one commit.
#
# Its copy line therefore checks `cp`'s EXIT STATUS rather than using the
# unchecked `|| true` form most hooks in that block use, and TC-EFR-8 in
# scripts/verify-hooks.sh pins the shape so it cannot be quietly weakened —
# the same pairing enforce-loop-bounds.sh has with TC-ELB-27.
#
# THE cwd/REPO RESIDUAL IS NOW CLOSED (H6), for this hook and for
# enforce-compliance-audit.sh together, as its earlier statement said it should
# be. It read: HEAD is resolved from the Bash tool's reported cwd, so
# `cd ../other-repo && gh pr create` resolves HEAD in the ORIGINAL checkout and
# an adjudication done here could unblock a PR opened there.
#
# It was also UNDERSTATED. `--repo other-owner/other-repo` needs no `cd` at
# all: HEAD still resolves here, the marker still matches, and the PR opens
# against a repository this gate never inspected. Both shapes are refused
# below, with the same two detectors enforce-codex-review.sh uses — that hook
# was the only one that refused them, and it only bites when Codex is enabled,
# so it was never a backstop for everyone. The reason given for leaving it open
# (adding branches no test exercises) no longer applies: TC-CD-* covers both
# shapes, both hooks, and the "cd inside a title" false-positive control.

set -euo pipefail

# Fail CLOSED when jq is missing — consistent with every other PreToolUse gate
# here. Without jq we can neither parse the input nor emit a structured deny.
# The spaces after the colons are deliberate: scripts/verify-hooks.sh greps for
# `"permissionDecision": "deny"`, so the compact spelling some older hooks use
# is invisible to it.
if ! command -v jq &>/dev/null; then
  cat <<'__DENY__'
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "BLOCKED: jq is required for hook enforcement (enforce-fable-review). Install jq (brew install jq / apt install jq / yum install jq) to continue. Hook fails closed for safety."}}
__DENY__
  exit 0
fi

HOOK_DATA=$(cat)
TOOL_NAME=$(jq -r '.tool_name // empty' <<< "$HOOK_DATA" 2>/dev/null || echo "")
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

COMMAND=$(jq -r '.tool_input.command // empty' <<< "$HOOK_DATA" 2>/dev/null || echo "")
CWD=$(jq -r '.cwd // "."' <<< "$HOOK_DATA" 2>/dev/null || echo ".")

# Gate an actual `gh pr create` TOKEN SEQUENCE, using the SAME anchored regex
# as enforce-codex-review.sh and enforce-compliance-audit.sh. Deliberately the
# same string, character for character: three gates that recognise a PR create
# slightly differently is three chances for one of them to be the one with the
# hole. Its two accepted residuals come with it and are not re-argued here —
# read them in enforce-codex-review.sh, which is the canonical copy:
#   * OVER-block: the phrase after any whitespace matches, so inert prose
#     (an echo, a --body string, a heredoc body line) is gated too. Safe
#     direction for a workflow-discipline gate; the remedy is in the deny.
#   * UNDER-block: a quote- or backtick-wrapped command name is not gated,
#     because including those in the boundary class would over-block ordinary
#     markdown. Anyone who can run arbitrary Bash can delete this file anyway.
# The two detector lines below are byte-identical to enforce-codex-review.sh's
# — the canonical copy — and TC-PRC-IDENT asserts it. Between them they
# recognise three shapes, not one: a PATH-qualified `gh`, flag groups
# INTERSPERSED between `gh`/`pr`/`create` (`gh --repo O/R pr create`), and a
# `gh api` call against the pulls collection or the createPullRequest GraphQL
# mutation. All six of those spellings reached a real PR with zero deny from
# any gate before C2. Read the full argument and the named residuals in
# enforce-codex-review.sh; they are not re-argued here.
#
# Matched with here-strings (`<<<`), never `printf | grep`: under pipefail the
# pipe form can SIGPIPE on large input and flip a deny into an allow.
if ! grep -qE '(^|[;&|()`[:space:]])(["]([^[:space:];&|()]*/)?gh["]|'"'"'([^[:space:];&|()]*/)?gh'"'"'|([^[:space:];&|()]*/)?gh)([[:space:]]+-[^[:space:];&|()]*([[:space:]]+[^-[:space:];&|()][^[:space:];&|()]*)?)*[[:space:]]+(["]pr["]|'"'"'pr'"'"'|pr)([[:space:]]+-[^[:space:];&|()]*([[:space:]]+[^-[:space:];&|()][^[:space:];&|()]*)?)*[[:space:]]+(["]create["]|'"'"'create'"'"'|create)([[:space:];&|()<>`"'"'"']|$)' <<< "$COMMAND" \
   && ! { grep -qE '(^|[;&|()`[:space:]])(["]([^[:space:];&|()]*/)?gh["]|'"'"'([^[:space:];&|()]*/)?gh'"'"'|([^[:space:];&|()]*/)?gh)([[:space:]]+-[^[:space:];&|()]*([[:space:]]+[^-[:space:];&|()][^[:space:];&|()]*)?)*[[:space:]]+(["]api["]|'"'"'api'"'"'|api)([[:space:]]|$)' <<< "$COMMAND" \
          && grep -qE '(^|[^[:alnum:]_])repos/[^[:space:]/;&|()]+/[^[:space:]/;&|()]+/pulls([^[:alnum:]_/]|$)|createPullRequest' <<< "$COMMAND"; }; then
  exit 0
fi

# ---------------------------------------------------------------------------
# THE MARKER IS BOUND TO A COMMIT RESOLVED IN *THIS* CWD (H6). Refuse the two
# command shapes that make that binding certify the wrong repository. Same two
# detectors as enforce-codex-review.sh, which is the canonical copy and carries
# the full argument and residual list.
#
# This used to be a KNOWN RESIDUAL in this file's header, naming only the `cd`
# half and pointing at enforce-compliance-audit.sh, which named it back. It was
# also understated: `--repo other-owner/other-repo` needs NO `cd` at all. HEAD
# still resolves HERE, the marker still matches, and the PR opens against a
# repository this gate never inspected. An adjudication of THIS diff certifying
# a PR THERE is the marker meaning nothing, which is exactly what binding to a
# sha existed to prevent. enforce-codex-review already refused both shapes and
# was the only gate that did — and it only bites when Codex is enabled, so it
# was never a backstop for everyone.
#
# NOT ADDED to enforce-pr-skill.sh, deliberately: its marker records that a
# SKILL ran in this session and is bound to no repository, so `--repo` creates
# no confusion there. TC-CD-11 pins that as a decision rather than an omission.
#
# The `cd` detector is boundary-anchored so the letters "cd" inside a title do
# not false-positive (TC-CD-cdword), and the repo detector requires a `/` in
# the ATTACHED `-Rowner/repo` form so a title word like `-Region` is not read
# as a repo flag. `env -C`/`--chdir` and `git -C` are NO LONGER residuals —
# they used to be named here and allowed, and a reviewer graded that red on the
# right grounds: they defeat the sha binding this block exists to protect, and
# naming a bypass is not accepting it. The arm below denies all four spellings.
# The residual that DOES come with the copy and is not re-argued here: a
# literal `;cd`/`(cd` inside an inline `--body`, which merely over-blocks.
EFR_CWD_DENY=""
if grep -qE '(^|[;&|(])[[:space:]]*(cd|pushd|popd)[[:space:]]' <<< "$COMMAND"; then
  EFR_CWD_DENY="changes directory (cd/pushd/popd), so the commit this gate resolved is not necessarily the commit the PR would be opened from. If there is no cd/pushd in your COMMAND because the token is in a --body or --title STRING, note this detector anchors PER LINE: a PR body whose how-to-test section starts a line with the two characters c,d then a space trips it, and there is then nothing in the command to remove. Write the body to a file with the Write tool and pass --body-file <path> instead, which clears this deny and leaves every other gate in place."
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
  EFR_CWD_DENY="relocates the command with env -C/--chdir or git -C, so the commit this gate resolved is not the commit the PR would be opened from. The HEAD lookup runs in this command's own working directory, while -C moves only where the command itself executes - and that is the half that decides what gets pushed. If the token is in a --body or --title STRING rather than a real flag, this scan has no quote awareness: write the body to a file with the Write tool and pass --body-file <path> instead, which clears this deny and leaves every other gate in place."
elif grep -qE '(^|[[:space:]])(--repo([[:space:]=]|$)|-R[[:space:]=]|-R[A-Za-z0-9._-]*/[A-Za-z0-9._-])' <<< "$COMMAND"; then
  EFR_CWD_DENY="targets another repository (--repo/-R), so an adjudication recorded for THIS checkout would open a PR against one this gate never read. If there is no --repo flag to remove because the token is inside a --body or --title STRING, this scan has no quote awareness and read your prose as a flag: write the body to a file with the Write tool and pass --body-file <path> instead, which clears this deny and leaves every other gate in place."
fi
if [[ -n "$EFR_CWD_DENY" ]]; then
  jq -n --arg why "$EFR_CWD_DENY" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": ("BLOCKED: this command " + $why + ".\n\nThe Fable adjudication marker is keyed to `git rev-parse HEAD` resolved in this command'\''s working directory. A command that moves the working directory, or aims the PR elsewhere with --repo/-R, breaks that binding — the marker would certify a diff nobody involved in this PR ever read.\n\nRun `gh pr create` as a PLAIN command from inside the checkout you adjudicated, with no cd/pushd and no --repo.\n\nNOT actually creating a PR? The scan reads the RAW command text with no heredoc or quote awareness, so a command that merely MENTIONS the phrase in prose trips the same check. That over-block is deliberate and accepted. Workaround: create the file with a NON-Bash write path (the Write tool), then run it. Writing it via a Bash heredoc does NOT help — that command carries the same phrase in its own body and is scanned before it can run.")
    }
  }'
  exit 0
fi

# ---------------------------------------------------------------------------
# THE STATE ROOT MUST RESOLVE — canonical copy of a guard all five PR/Bash
# gates carry. enforce-codex-review.sh, enforce-compliance-audit.sh,
# enforce-pr-skill.sh and enforce-auto-poll.sh each carry the same two lines
# and point back here rather than re-arguing it.
#
# THE DEFECT IT CLOSES: every marker this gate reads lives under
# `${CLAUDE_STATE_DIR:-$HOME/.claude}`. Under `set -u` that expansion ABORTS
# when neither variable is set — bash exits 1 having printed nothing — and a
# PreToolUse hook that exits non-zero with no deny JSON does not block. So the
# single input class "the environment carried no home directory" (a
# devcontainer, a CI image, anything launched `env -i`) disarmed ELEVEN gates
# at once, silently. `: "${HOME:?}"` does NOT fix it: still exit 1, still no
# JSON. Only an explicit test that emits the deny itself does.
#
# `-z` covers BOTH unset and empty, because they are different bugs. HOME=""
# does not abort: it resolves the state root to `/.claude`, and the five gates
# then split — three deny for the wrong reason (marker not found under a
# nonsense path) while codex-review and auto-poll silently ALLOW, reading "the
# file I check enablement in is missing" as "this gate does not apply". An
# asymmetry nobody chose is the signature of an input class nobody enumerated
# (rules/security.md item 2).
#
# PLACEMENT — deliberately AFTER the `gh pr create` detector above, not at the
# top of the file. This gate has an opinion about exactly one command shape;
# denying every Bash call because the state root is missing would be a blanket
# block with no remedy runnable from Bash, which is the deadlock item 4 exists
# to stop. enforce-auto-poll.sh is the ONE exception and places its copy at the
# top, because it gates every Bash command anyway and is therefore the gate
# that surfaces a broken state root on the FIRST call rather than the first PR.
#
# THE REMEDY IS DELIBERATELY NOT A BASH COMMAND (item 5 — the deny must name a
# way out that works). Each Bash tool call is a fresh shell, so an `export
# HOME=...` here would not survive to the next call; printing one would be
# printing a remedy that cannot work.
if [[ -z "${CLAUDE_STATE_DIR:-}" && -z "${HOME:-}" ]]; then
  cat <<'__DENY__'
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "BLOCKED: neither HOME nor CLAUDE_STATE_DIR is set, so enforce-fable-review cannot locate the state directory its adjudication marker lives in. A gate that cannot find its own evidence has not been satisfied, so it fails closed.\n\nThis cannot be fixed from inside a Bash tool call — every call is a fresh shell, so an `export` here does not survive to the next one. Set HOME (or CLAUDE_STATE_DIR) in the environment the agent itself runs in — the `env` block of ~/.claude/settings.json, or the container/CI environment — and start a new session."}}
__DENY__
  exit 0
fi

# State directory: defaults to $HOME/.claude (outside any repo), overridable
# via CLAUDE_STATE_DIR so the suite can exercise both paths without touching
# the developer's real state. Same contract as enforce-codex-review.sh.
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

MARKER_FILE="$STATE_DIR/.fable-review-complete"

# Resolve the commit being PR'd (the branch tip), from the tool's own cwd so
# the hook reads the right repo even when fired from a subagent.
HEAD_SHA=$(cd "$CWD" 2>/dev/null && git rev-parse HEAD 2>/dev/null || echo "")

# ONE condition, two clauses, and the message adapts by parameter expansion
# rather than by a second branch.
#
# THE `-z` CLAUSE IS LOAD-BEARING. This comment used to say the opposite — that
# it was belt-and-braces, because with an empty HEAD_SHA the pattern becomes
# `^reviewed[[:space:]]+([[:space:]]|$)`, which "requires whitespace-then-
# whitespace and so cannot match a real `reviewed <sha>` line", so the gate
# "already fails CLOSED on an unresolvable HEAD by construction".
#
# Measured, and it is false. `[[:space:]]+` BACKTRACKS: against the line
# `reviewed ` — keyword plus ONE trailing space — it consumes the space and the
# trailing `([[:space:]]|$)` then matches END OF LINE. The pattern matches, and
# without this clause the gate would ALLOW.
#
# That line is not a contrivance. It is what the deny's OWN remedy writes when
# it is run from outside a checkout: `printf 'reviewed %s\n' "$(git rev-parse
# HEAD)"` with an unresolvable HEAD substitutes the empty string and appends
# exactly `reviewed `. So the sequence is: follow the instructions from the
# wrong directory once, then create a PR from a non-repo cwd, and the gate is
# satisfied by a line that names no commit. A fail-open reached by the gate's
# own printed remedy.
#
# The clause is also what lets the deny SAY that HEAD did not resolve, instead
# of reporting an empty sha and sending the reader looking for a marker that
# could never have existed. Pinned by TC-EFR-5h.
#
# EVERY CLAUSE OF THE MARKER PATTERN IS PINNED (TC-EFR-5c..5g): the `^` anchor
# against a commented-out line, the keyword against an invented synonym, the
# `[[:space:]]+` separator against a run-together line, and the trailing
# boundary against a sha that merely STARTS with HEAD. TC-EFR-5g records the
# inverse as a decision rather than an accident: a trailing comment after a
# valid line IS accepted, because the boundary is whitespace-or-EOL.
#
# NOTE ON THE DEFAULT STRING: it carries no apostrophe on purpose. Bash parses
# quotes inside ${VAR:-word} even within double quotes, so a lone ' there is
# an unterminated-string syntax error, not literal text — the hook would fail
# to parse and PreToolUse would fail OPEN.
#
# The marker is NOT consumed on allow. It is keyed to a sha, so it invalidates
# itself the moment another commit lands — there is nothing for a PostToolUse
# consumer to clean up, and deleting it here would force a needless re-run
# whenever a sibling gate denies the same command (the "gates fail in rotation"
# deadlock the marker design already avoids elsewhere).
if [[ -z "$HEAD_SHA" ]] \
   || ! grep -qE "^reviewed[[:space:]]+${HEAD_SHA}([[:space:]]|$)" "$MARKER_FILE" 2>/dev/null; then
  jq -n --arg sha "${HEAD_SHA:-<HEAD did not resolve in the working directory of this command>}" \
        --arg root "$REMEDY_DIR" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": ("BLOCKED: no Fable adjudication is recorded for the commit being PR'\''d.\n\n  HEAD: " + $sha + "\n\nThe adjudication is the pre-push pass where the final diff is read and judged against what the ticket asked for — the step the other gates do not cover. It is bound to a sha so the reviewed thing is the pushed thing; a marker satisfiable by any past review would be no marker at all.\n\nRun the pass, then record it — this ONE line, exactly:\n\n  printf '\''reviewed %s\\n'\'' \"$(git rev-parse HEAD)\" >> " + $root + "/.fable-review-complete\n\nThat command runs no `gh pr create`, so the gate that printed it does not block it, and enforce-auto-poll explicitly permits it too. Append, do not overwrite — the file is one line per commit.\n\n`reviewed` is the only word this gate accepts, and there is deliberately no outage escape: nothing in the toolbox writes this marker yet, so an `unavailable` line would not be a rare hatch for a pass that could not run, it would be the only path anyone ever wrote — one word shorter than the honest one and never requiring the work. An escape hatch with no other path through it is a hole with a label on it. If you genuinely cannot adjudicate, say so to the user and stop; do not invent a word for it.\n\nIf HEAD did not resolve above, run the PR-create command plainly from inside the repository checkout first; the marker cannot be bound to a commit this hook cannot see.")
    }
  }'
  exit 0
fi

exit 0
