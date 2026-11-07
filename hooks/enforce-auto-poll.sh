#!/bin/bash
# enforce-auto-poll.sh
#
# PreToolUse hook on Bash.
# Blocks Bash commands when auto-poll setup is pending (marker created by
# auto-poll-after-pr.sh PostToolUse hook after gh pr create).
#
# The pending marker (~/.claude/.auto-poll-pending-*) contains a structured
# repo/PR/worktree record (with a legacy two-token marker accepted during
# upgrade). This hook checks if the corresponding cron-id file exists. If not, it blocks
# all Bash commands EXCEPT those that are part of the auto-poll setup flow.
#
# This converts auto-poll from a passive reminder (ignored in multiple incidents)
# to a structural gate the agent cannot bypass.
#
# Allowed commands when pending:
# - Commands writing to cron-id files (echo ... > ~/.claude/.pr-*-cron-id)
# - The guarded cron-id write this hook's own deny prints, verbatim
#   ([ -n "$CRON_ID" ] && echo "$CRON_ID" > ~/.claude/.pr-*-cron-id)
# - The creation-time stamp this hook's own deny prints
#   (date +%s > ~/.claude/.pr-*-cron-created)
# - All gh CLI commands (safe — pr-action-safety.sh blocks dangerous ones)
# - Commands removing the pending marker (opt-out: rm ~/.claude/.auto-poll-pending-*)
# - Git read-only commands (status, log, diff, branch, show, rev-parse)
#
# ⛔ A GUARD MUST NOT BLOCK ITS OWN REMEDY (issue #150). ⛔
#   This hook blocks EVERY Bash command until auto-poll is active, and every way
#   out it prints has to be carried out in Bash. When the printed remedy is not
#   in the allowlist, the guard is not a guard, it is a trap — and it was one:
#
#     * Step 2 (`date +%s > …-cron-created`) had no branch at all. The only
#       write branch matched `echo|printf` into a `*-cron-id` path.
#     * Step 3 (`[ -n "$CRON_ID" ] && …`) was refused by the compound-command
#       rejection, because the message itself writes it as an `&&` chain. The
#       hook told the agent to run a shape it refuses.
#     * The opt-out was printed with $HOME EXPANDED, while the allowlist below
#       recognises only the literal `$HOME`, `~`, `/Users/<u>`, `/home/<u>` or
#       `/root` spellings. On a home of any other shape — a devcontainer, a CI
#       image, a test workspace — the exact command the hook printed was the one
#       it refused, and the spelling that worked was the one it never printed.
#
#   The third one needed no new branch, only a path the existing branch accepts:
#   every remedy is now printed with a literal `~`, which is home-agnostic and
#   already allowed. (Honest half of the finding: the `~` spelling was ALWAYS
#   accepted — TC-EAP-26 is the control that says so — so #150's claim that all
#   three documented paths were blocked was too strong for this one.)
#
#   The other two are real allowlist gaps and are closed below by two branches
#   that admit EXACTLY the command shapes this hook prints, nothing wider.
#   Widening an allowlist to be helpful is how a gate acquires a bypass; these
#   two are transcriptions of the deny text, and TC-EAP-23/24/25 replay the
#   remedy EXTRACTED FROM THE MESSAGE AT RUNTIME, so a future reword that drifts
#   from the allowlist fails the suite instead of re-creating the trap.
#
# Incidents: TASK-747 PR #788, TASK-760 PR #800, PR #55 — auto-poll not set up
# despite Rule 4 and the reminder hook.

set -euo pipefail

# THE STATE ROOT MUST RESOLVE FIRST. With neither variable set, the expansion
# below is an unbound-variable abort under `set -u`: exit 1, no JSON, gate
# fails OPEN. `-z` covers unset AND empty; with HOME="" this hook did not abort
# but silently ALLOWED, reading "the pending marker is missing under /.claude"
# as "no PR is waiting". Canonical copy and full rationale:
# enforce-fable-review.sh.
#
# THIS COPY IS AT THE TOP OF THE FILE, and it is the one deliberate exception
# to the "place it next to the state read" rule the canonical copy states. This
# hook gates EVERY Bash command, so it is the only gate that sees the FIRST
# call of a session — which makes it the one that surfaces a broken state root
# immediately, instead of letting the other four rot open until someone tries
# to open a PR. The over-block is the point.
if [[ -z "${AI_ENGINEERING_STATE_DIR:-}" && -z "${CLAUDE_STATE_DIR:-}" && -z "${HOME:-}" ]]; then
  cat <<'__DENY__'
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "BLOCKED: none of AI_ENGINEERING_STATE_DIR, HOME or CLAUDE_STATE_DIR is set, so enforce-auto-poll cannot locate the state directory its auto-poll markers live in — and neither can the four PR gates that read the same directory. A gate that cannot find its own evidence has not been satisfied, so it fails closed.\n\nThis cannot be fixed from inside a Bash tool call — every call is a fresh shell, so an `export` here does not survive to the next one. Set AI_ENGINEERING_STATE_DIR, HOME (or CLAUDE_STATE_DIR) in the environment the agent itself runs in — the `env` block of ~/.claude/settings.json, or the container/CI environment — and start a new session."}}
__DENY__
  exit 0
fi

# State directory: one shared root for Claude and Codex, overridable via
# AI_ENGINEERING_STATE_DIR. CLAUDE_STATE_DIR remains the compatibility fallback.
# — the same contract the four PR gates already honoured and this one did not.
# The divergence was a real hazard, not a cosmetic one: a redirected state root
# moved the four gates' markers and left this hook reading the un-redirected
# path, so the two halves of the auto-poll handshake could look at different
# directories. Both spellings resolve to the same place in production, where
# CLAUDE_STATE_DIR is unset.
STATE_DIR="${AI_ENGINEERING_STATE_DIR:-${CLAUDE_STATE_DIR:-$HOME/.claude}}"
# ⛔ A NON-EMPTY STATE ROOT IS NOT A RESOLVED ONE. ⛔
# The check above only proves at least one state-root source is not empty. Three
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

# STATE_ROOT_RE — THE DIRECTORY CLASS THE FOUR PATH-PINNED ALLOWLIST BRANCHES
# BELOW SHARE. Two things had to be true at once and only one of them was:
#
#   1. ⛔ AN ALLOWLIST MUST NOT PERMIT A WRITE OUTSIDE THE STATE ROOT. ⛔ The
#      two remedy-transcription branches (the `date +%s > …-cron-created` and
#      the `[ -n "$CRON_ID" ] && echo … > …-cron-id`) pinned only the BASENAME,
#      with `[^[:space:]<>|;&`$()]*` in front of it. That class admits slashes
#      and dot-segments, so all of these MEASURED as allowed:
#        date +%s > /tmp/evil/.pr-x-y-1-cron-created
#        date +%s > ../../../tmp/evil/.pr-x-y-1-cron-created
#      and since `>` follows symlinks, a symlink at that path redirects the
#      write anywhere. This is the SAME defect the marker-write branch above
#      was narrowed for on this branch — left standing on its two siblings
#      three lines away, which is this file's own recurring shape. Branch 1
#      (the general `echo|printf … > …-cron-id` write) had the same open
#      directory and is pinned here too.
#   2. The pin must not refuse the path the deny PRINTS. The deny now
#      interpolates REMEDY_DIR, so under a CLAUDE_STATE_DIR override it prints
#      the resolved root — and a home-class-only pin would then reject the
#      gate's own remedy. That is why the resolved root is an ALTERNATIVE here
#      rather than a replacement: pinning to it ALONE would break TC-XG-3i,
#      where a literal /Users/<name>/.claude path with no relation to this
#      process's HOME is asserted allowed, because matching command TEXT is not
#      the same as matching a resolved path.
#
# The home half is byte-identical to the class the printf and rm branches
# already carry: a leading alnum/underscore then alnum/dot/dash/underscore,
# which cannot form `$(` and cannot be `..`.
STATE_DIR_RE=$(printf '%s' "$STATE_DIR" | sed 's/[][^$.*+?(){}|\\]/\\&/g')
STATE_ROOT_RE="($STATE_DIR_RE|(\$HOME|\~|/Users/[A-Za-z0-9_][A-Za-z0-9._-]*|/home/[A-Za-z0-9_][A-Za-z0-9._-]*|/root)/\.claude)"


# Pending obligations are per PR/worktree. Keep the legacy singleton in the
# candidate set for upgrades, but never let one worktree overwrite another's
# obligation.
PENDING_CANDIDATE_FOUND=0
for candidate in "$STATE_DIR/.auto-poll-pending" "$STATE_DIR"/.auto-poll-pending-*; do
  if [[ -f "$candidate" ]]; then
    PENDING_CANDIDATE_FOUND=1
    break
  fi
done

# No pending marker — allow everything
if [[ "$PENDING_CANDIDATE_FOUND" -eq 0 ]]; then
  exit 0
fi

# Fail CLOSED when jq is missing — without jq we cannot reliably parse hook
# input or emit structured deny responses, so allowing the action would
# silently disarm this entire enforcement layer. A devcontainer/CI image
# without jq would otherwise let every guarded operation through.
if ! command -v jq &>/dev/null; then
  cat <<'__DENY__'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: jq is required for hook enforcement (enforce-auto-poll). Install jq (brew install jq / apt install jq / yum install jq) to continue. Hook fails closed for safety."}}
__DENY__
  exit 0
fi

HOOK_DATA=$(cat)

TOOL_NAME=$(echo "$HOOK_DATA" | jq -r '.tool_name // empty')

if [[ "$TOOL_NAME" != "Bash" ]]; then
  exit 0
fi

COMMAND=$(echo "$HOOK_DATA" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
# The caller's working directory. Read for the bystander check below; this hook
# had no notion of WHO was calling it, which is the whole of #168.
CWD=$(echo "$HOOK_DATA" | jq -r '.cwd // empty' 2>/dev/null || echo "")

# Select the pending obligation belonging to this caller. A malformed
# structured marker is selected and remains fail-closed; inability to establish
# ownership is not proof that the caller is unrelated. A valid marker for a
# different worktree is skipped, so concurrent sessions do not wedge each other.
PENDING_FILE=""
PENDING_CONTENT=""
PENDING_REPO=""
PENDING_PR=""
PENDING_WORKTREE=""
PENDING_INVALID=0
for candidate in "$STATE_DIR/.auto-poll-pending" "$STATE_DIR"/.auto-poll-pending-*; do
  [[ -f "$candidate" ]] || continue
  candidate_content=$(cat "$candidate" 2>/dev/null || echo "")
  candidate_repo=""
  candidate_pr=""
  candidate_worktree=""
  candidate_invalid=0
  if grep -q '^repo=' <<< "$candidate_content"; then
    candidate_repo=$(sed -n 's/^repo=//p' <<< "$candidate_content" | head -1)
    candidate_pr=$(sed -n 's/^pr=//p' <<< "$candidate_content" | head -1)
    candidate_worktree=$(sed -n 's/^worktree=//p' <<< "$candidate_content" | head -1)
    if [[ -z "$candidate_repo" || -z "$candidate_pr" || -z "$candidate_worktree" ]]; then
      candidate_invalid=1
    fi
  else
    candidate_repo=$(echo "$candidate_content" | awk '{print $1}')
    candidate_pr=$(echo "$candidate_content" | awk '{print $2}')
  fi
  candidate_owner=$(echo "$candidate_repo" | cut -d/ -f1)
  candidate_repo_name=$(echo "$candidate_repo" | cut -d/ -f2)
  candidate_cron="$STATE_DIR/.pr-${candidate_owner}-${candidate_repo_name}-${candidate_pr}-cron-id"
  if [[ -f "$candidate_cron" ]]; then
    rm -f "$candidate"
    continue
  fi
  if [[ "$candidate_invalid" -eq 1 ]]; then
    PENDING_FILE="$candidate"
    PENDING_CONTENT="$candidate_content"
    PENDING_REPO="$candidate_repo"
    PENDING_PR="$candidate_pr"
    PENDING_WORKTREE="$candidate_worktree"
    PENDING_INVALID=1
    break
  fi
  if [[ -n "$candidate_worktree" ]]; then
    CALLER_WORKTREE=""
    if [[ -n "$CWD" && -d "$CWD" ]]; then
      CALLER_WORKTREE=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)
      if [[ -n "$CALLER_WORKTREE" ]]; then
        CALLER_WORKTREE=$(cd "$CALLER_WORKTREE" 2>/dev/null && pwd -P || true)
      fi
    fi
    MARKER_WORKTREE=$(cd "$candidate_worktree" 2>/dev/null && pwd -P || true)
    if [[ -z "$CALLER_WORKTREE" || -z "$MARKER_WORKTREE" ]]; then
      # Missing hook metadata is not evidence that the caller is a bystander.
      # Keep the obligation selected and fail closed below.
      PENDING_FILE="$candidate"
      PENDING_CONTENT="$candidate_content"
      PENDING_REPO="$candidate_repo"
      PENDING_PR="$candidate_pr"
      PENDING_WORKTREE="$candidate_worktree"
      PENDING_INVALID=1
      break
    fi
    if [[ "$CALLER_WORKTREE" != "$MARKER_WORKTREE" ]]; then
      continue
    fi
  fi
  PENDING_FILE="$candidate"
  PENDING_CONTENT="$candidate_content"
  PENDING_REPO="$candidate_repo"
  PENDING_PR="$candidate_pr"
  PENDING_WORKTREE="$candidate_worktree"
  break
done

# No marker belongs to this caller; leave other worktrees' obligations intact.
if [[ -z "$PENDING_FILE" ]]; then
  exit 0
fi

PENDING_OWNER=$(echo "$PENDING_REPO" | cut -d/ -f1)
PENDING_REPO_NAME=$(echo "$PENDING_REPO" | cut -d/ -f2)
PENDING_BASENAME=$(basename "$PENDING_FILE")
if [[ "$PENDING_BASENAME" == ".auto-poll-pending" ]]; then
  REMEDY_MARKER="${REMEDY_DIR}/.auto-poll-pending"
else
  REMEDY_MARKER="${REMEDY_DIR}/${PENDING_BASENAME}"
fi

# ---------------------------------------------------------------------------
# Worktree ownership is enforced above. Structured markers let linked
# worktrees and provider-specific subagents continue independently while the
# owning checkout remains gated until Claude or Codex registers its poller.
# Legacy two-token markers intentionally keep the old fail-closed behaviour
# until they are registered or explicitly opted out.
# ---------------------------------------------------------------------------

# All detectors below match with here-strings (`<<<`), never `echo | grep`:
# under `set -euo pipefail` the pipe form can SIGPIPE (141) on large multiline
# input and flip a deny to an allow (static guard: TC-EAP-13).
#
# Newline-smuggling guard (security review 2026-07-07, TC-EAP-14..17): every
# allowlist branch below anchors with ^...$, which POSIX grep with `<<<`
# evaluates PER LINE, not across the whole string. A COMMAND with an embedded
# literal newline needs none of `;`/`|`/backtick/`$(`/`&&`/`||` to smuggle a
# second command — e.g. line 1 `gh api foo` (matches the gh anchor on line
# 97), line 2 `rm -rf /tmp/x` (never seen by the compound-command detectors,
# which also only look at one line at a time). Reject any command containing
# a literal newline (LF) OUTRIGHT before the allowlist chain runs, so no
# per-line match can ever fire. Also reject CR, vertical-tab, and form-feed —
# matching the enforce-jira-delegation.sh "clean stance" convention: the
# allowed single-line forms carry no control-char line/vertical separator of
# any kind, not just LF. CR/VT/FF are not bash command separators today, but
# rejecting them keeps the invariant simple and future-proof rather than
# re-litigating it per control character. This check only matters while the
# pending gate above is active — with no pending marker the hook already
# exited 0 at the top, so it never changes behaviour for the steady state.
if [[ "$COMMAND" == *$'\n'* || "$COMMAND" == *$'\r'* || "$COMMAND" == *$'\v'* || "$COMMAND" == *$'\f'* ]]; then
  : # fall through to block — no allowlist branch may evaluate a multiline command

# -1. A SIBLING GATE'S PRINTED REMEDY (H1). Checked here, before the
#     compound-command rejection, because the remedy contains a `$(…)` and that
#     rejection fires on the two characters alone.
#
#     WHY THIS BRANCH EXISTS: rules/security.md item 4 says a guard must not
#     block its own remedy. Issue #150 applied that WITHIN this file. It is
#     equally true ACROSS gates, and there it was still broken. With the
#     pending marker armed, this hook permits `gh pr create` (branch 2 allows
#     all gh), so the agent reaches enforce-fable-review's deny, is told to run
#     exactly one command, and is refused by THIS hook. The shortest way out a
#     stuck agent finds from there is `rm ~/.claude/.auto-poll-pending`, which
#     branch 3 permits — so the rotation's only exit is switching a guard OFF.
#     That is not defence in depth, it is a trap that teaches the agent to
#     disarm gates.
#
#     This is a TRANSCRIPTION of the exact string enforce-fable-review prints,
#     not a general permission for `printf` or for command substitution. The
#     command word, the format string, the substitution and the target file
#     name are all fixed; the path is pinned to the SAME home class this file already
#     uses for the .auto-poll-pending rm branch below, so the directory is not
#     free either. An earlier revision pinned only the BASENAME and left the
#     directory open, and its comment claimed the class "excludes every shell
#     metacharacter" — measured FALSE: that class excluded nine characters and
#     admitted `~ * ? [ ] { } \ " ' !`. Measured shapes it wrongly ALLOWED:
#     /tmp/evil/.fable-review-complete, a bare .fable-review-complete in the
#     repo CWD, ~root/.fable-review-complete, and
#     ~/.claude/../../../../tmp/pwn/.fable-review-complete. Since `>>` follows
#     symlinks, the bare-CWD case also let a repo commit a mode-120000
#     .fable-review-complete pointing at ~/.claude/settings.json. TC-XG-1 replays the remedy EXTRACTED FROM THE FABLE
#     GATE'S MESSAGE AT RUNTIME, so a reword on either side fails the suite
#     instead of silently recreating the trap; TC-XG-3 pins a different BASENAME
#     (~/.ssh/authorized_keys) and TC-XG-3b pins a different DIRECTORY
#     (/tmp/evil/.fable-review-complete). TC-XG-3 alone did NOT cover the
#     directory — its name said "any other path" while it asserted one
#     basename, which is why the hole survived a full review round.
#
#     NAMED RESIDUAL (rules/security.md item 7): the codex-review skill writes
#     its marker with a DIFFERENT shape (`echo "reviewed $HEAD_SHA  # $(date …)"
#     >> "$STATE_DIR/.codex-review-complete"`) and that shape is NOT allowed
#     here. It does not need to be — the Codex pass runs before the PR exists,
#     so the pending marker cannot be armed while it writes — but if that ever
#     changes, this is the branch to extend, and extending it means
#     transcribing that string too, not widening this one.
# ⛔ THE USERNAME CLASS IS DELIBERATELY NARROW — [^[:space:]/]+ WAS INJECTABLE. ⛔
# A first version of this pin used `/Users/[^[:space:]/]+`, reasoning that excluding
# `/` and whitespace pinned the directory. It does not: that class still admits `$`,
# `(` and `)`, so a segment can BE a command substitution, and it admits `..`, so the
# directory is not pinned either. Both measured as ALLOWED against that class:
#     printf 'reviewed %s\n' "$(git rev-parse HEAD)" >> /Users/x$(id)/.claude/.fable-review-complete
#     printf 'reviewed %s\n' "$(git rev-parse HEAD)" >> /Users/../.claude/.fable-review-complete
# The first executes the substitution; the second walks out of /Users. Cross-family
# review (Codex) found this after seven same-family reviewers did not — the class
# LOOKS restrictive because of what it excludes, and nobody enumerated what it admits.
# The class below allows only a leading alnum/underscore then alnum/dot/dash/underscore,
# which cannot form `$(`, cannot be `..`, and still covers every real home directory
# name. TC-XG-3g/3h pin both shapes.
elif grep -qE '^[[:space:]]*printf[[:space:]]+'"'"'reviewed %s\\n'"'"'[[:space:]]+"\$\(git rev-parse HEAD\)"[[:space:]]*>>[[:space:]]*'"$STATE_ROOT_RE"'/\.fable-review-complete[[:space:]]*$' <<< "$COMMAND"; then
  exit 0

# Reject compound/chained commands — allowlist checks must apply to a single command.
# Semicolons, pipes, &&, ||, backticks, and $() can chain arbitrary work after an
# allowed prefix. The one exception: `&&` chains where EVERY segment is allowed
# (e.g. `echo ID > cron-id && cat cron-id`) — but validating each segment is
# complex and error-prone, so we block all compound forms and let the agent
# issue separate Bash calls.
elif grep -qE '[;|`]|\$\(' <<< "$COMMAND"; then
  : # fall through to block
# 0. THE HOOK'S OWN REMEDIES (issue #150) — checked BEFORE the compound-command
#    rejection, because remedy step 3 is an `&&` chain and would otherwise be
#    refused by the very message that prints it. The multiline/control-char
#    guard above still runs first, so each regex here sees a single line and its
#    `^…$` anchors bind the WHOLE command.
#
#    Both patterns are transcriptions of the deny text below — not general
#    permissions for `date` or for guarded writes. ⛔ THIS USED TO CLAIM the path
#    class "excludes every shell metacharacter ... so nothing can be smuggled into
#    the redirect target" — the SAME sentence this file records as measured FALSE
#    fifty lines up. It excludes `; | & \` $ ( ) < >` and whitespace and ADMITS
#    `~ * ? [ ] { } \ ' " !`; bash performs tilde and glob expansion on a redirect
#    target, so the DIRECTORY is steerable. The basename stays pinned and this
#    branch is a fall-through (exit 0), not the auto-approved allow, so the impact
#    is low — the false sentence was the defect. One instance was corrected and its
#    sibling three lines away was left, which is this branch's own recurring shape.
#    The composite `.pr-OWNER-REPO-N-` key is required exactly as branch 1 requires it.
#
#    NOT PINNED, stated rather than implied: only the exact spellings the deny
#    prints are exercised by the suite. A cosmetic variant (`date "+%s"`, a
#    different guard around the write) is NOT accepted and will block. That is
#    the deliberate direction — if the message changes, change these with it,
#    and TC-EAP-23/24 will tell you if you forget.
#
#    The likeliest variant to trip this is a path spelled with SHELL VARIABLES
#    (`~/.claude/.pr-${OWNER}-${REPO_NAME}-${pr}-cron-created`, as the
#    `pr-automation` and `finishing-a-development-branch` skills write it in
#    their templates): the redirect-target class excludes `$`, so that form
#    blocks. It has to be inlined to literal values anyway — each Bash tool
#    call is a fresh shell, so nothing set earlier survives to expand — and
#    the deny message prints the literals ready to copy.
elif grep -qE '^[[:space:]]*date[[:space:]]+\+%s[[:space:]]*>[[:space:]]*'"$STATE_ROOT_RE"'/\.pr-[^/[:space:]>]+-[^/[:space:]>]+-[0-9]+-cron-created[[:space:]]*$' <<< "$COMMAND"; then
  exit 0
elif grep -qE '^[[:space:]]*\[[[:space:]]+-n[[:space:]]+"\$CRON_ID"[[:space:]]+\][[:space:]]*&&[[:space:]]*echo[[:space:]]+"\$CRON_ID"[[:space:]]*>[[:space:]]*'"$STATE_ROOT_RE"'/\.pr-[^/[:space:]>]+-[^/[:space:]>]+-[0-9]+-cron-id[[:space:]]*$' <<< "$COMMAND"; then
  exit 0

# 0b. Provider-neutral registrar. Claude's host can satisfy this gate with
# CronCreate, while Codex uses the installed registrar after creating its
# heartbeat. The command is pinned to the literal home-relative Codex/Claude
# install paths and to validated scalar arguments; it cannot become a general
# shell escape. Keeping this branch before compound-command rejection makes the
# command printed in the Codex remedy executable by the gate that printed it.
elif grep -qE '^[[:space:]]*(\$HOME|~)/(\.codex/bin|\.claude/scripts)/register-pr-poll\.sh[[:space:]]+--repo[[:space:]]+[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+[[:space:]]+--pr[[:space:]]+[1-9][0-9]*[[:space:]]+--provider[[:space:]]+(claude|codex)[[:space:]]+--poll-id[[:space:]]+[A-Za-z0-9][A-Za-z0-9_.:-]*[[:space:]]*$' <<< "$COMMAND"; then
  exit 0

elif grep -cE '&&|\|\|' <<< "$COMMAND" | grep -qv '^0$'; then
  : # fall through to block

# 1. Writing cron-id files — composite key ONLY (.pr-OWNER-REPO-PR-cron-id).
#    Legacy form (.pr-PR-cron-id) is NOT writable: a legacy write would orphan
#    the pending marker forever because the marker check on line 63 only reads
#    the composite path. Read access (cat/ls) below stays permissive so the
#    transition fallback in /review-pr can still read legacy files.
elif grep -qE '^[[:space:]]*(echo|printf)[[:space:]][^>]*>[[:space:]]*'"$STATE_ROOT_RE"'/\.pr-[^/[:space:]>]+-[^/[:space:]>]+-[0-9]+-cron-id[[:space:]]*$' <<< "$COMMAND"; then
  exit 0
elif grep -qE '^[[:space:]]*(cat|ls)[[:space:]].*\.pr-.*-cron-id' <<< "$COMMAND"; then
  exit 0

# 2. All gh CLI commands — safe to allow because pr-action-safety.sh independently
#    blocks dangerous operations (gh pr merge, gh pr close). The agent needs gh api,
#    gh pr checks, gh pr list, etc. during normal workflow after a push.
elif grep -qE '^[[:space:]]*gh[[:space:]]' <<< "$COMMAND"; then
  exit 0

# 3. Removing the pending marker (opt-out — home-directory paths only, end-anchored)
#    Matches $HOME, ~, /Users/<user>, /home/<user>, /root — not arbitrary paths.
#
#    WHY: When NO_AUTO_POLL is NOT set but the agent removes the pending marker,
#    that's a deliberate opt-out bypassing normal auto-poll setup. The user may
#    not realise reviewer comments (human + automated-review) will NOT be auto-processed
#    for this PR. We emit a visible systemMessage warning so they can decide
#    whether to re-enable auto-poll via CronCreate. When NO_AUTO_POLL IS set,
#    the user clearly intended to skip — allow silently, no warning needed.
# ⛔ SAME NARROW CLASS AS THE MARKER-WRITE BRANCH ABOVE — AND FOR THE SAME REASON. ⛔
# This branch ends in an explicit auto-approved `allow`, so it is a MORE
# consequential place to be loose than the write branch, not less.
# PRE-EXISTING, not introduced by this change: `/Users/[^[:space:]/]+` here is
# byte-identical to main. Measured on it:
#     rm /Users/x$(id)/.claude/.auto-poll-pending   -> DENY   (the downstream
#         compound-command rejection catches the substitution, so this branch was
#         never command-injectable the way the write branch was)
#     rm /Users/../.claude/.auto-poll-pending       -> ALLOW  (traversal: an
#         auto-approved delete of a path that is not under any user's home)
# So the real hole here is traversal, not injection — narrower than it first looks,
# and low impact. It is fixed anyway because it is the SAME class this branch is
# named for, in the SAME file whose sibling branch was just narrowed, and leaving
# it would be one more instance of exactly the asymmetry this branch keeps
# finding: a guard fixed on one path and left on its neighbour.
# TC-XG-4b/4c pin both directions.
elif grep -qE '^[[:space:]]*rm[[:space:]]+(-f[[:space:]]+)?'"$STATE_ROOT_RE"'/\.auto-poll-pending(-[A-Za-z0-9_.-]+)?[[:space:]]*$' <<< "$COMMAND"; then
  # ⛔ A PR LOSING ITS GATE MUST LEAVE A TRACE (issue #168 item 5). ⛔
  # This branch is an auto-approved DELETE of the only evidence that auto-poll
  # was owed. Before this, the sole record was a systemMessage in one transcript
  # — nothing durable, so a PR could silently lose its gate and no later reader
  # could tell. Appended unconditionally, before the NO_AUTO_POLL split, because
  # the deliberate opt-out is exactly as worth recording as the accidental one.
  # ⛔ THE CWD IS CALLER-CONTROLLED AND THIS LOG IS TAB-SEPARATED. ⛔
  # It arrives from the payload's `.cwd`. A NEWLINE in it forges additional
  # records; a TAB forges FIELDS within a record. Escaping only the newline (the
  # first suggested fix) leaves the tab, and a forged field is as misleading as a
  # forged row. Swept with the same complete control-character class as the JSON
  # escaping above, for the same reason: an enumeration of the characters someone
  # thought of is what failed the first time.
  EAP_CWD_SAFE=${CWD:-unknown}
  EAP_CWD_SAFE=${EAP_CWD_SAFE//[[:cntrl:]]/ }
  # ⛔ AND A RECORD THAT MAY SILENTLY NOT EXIST IS NOT AN AUDIT TRAIL. ⛔
  # This was `>> … 2>/dev/null || true`, so an unwritable or full state directory
  # meant the opt-out proceeded with no trace while the deny text promised one -
  # a gate asserting a fact it never measured, which is the defect class this
  # branch exists for, introduced by my own fix for it. If the record cannot be
  # written the opt-out is REFUSED: an unobservable disarm is worse than a
  # blocked one, and the same unwritable directory would fail the user's `rm`
  # anyway, so this denies nothing that would otherwise have worked.
  if ! printf '%s\t%s\t%s\tcwd=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${PENDING_REPO:-unknown}" "${PENDING_PR:-unknown}" \
      "$EAP_CWD_SAFE" >> "$STATE_DIR/.auto-poll-optout.log" 2>/dev/null; then
    printf '%s\n' "{\"hookSpecificOutput\": {\"hookEventName\": \"PreToolUse\", \"permissionDecision\": \"deny\", \"permissionDecisionReason\": \"BLOCKED: cannot record the auto-poll opt-out, so it is refused (enforce-auto-poll, issue #168). Removing the pending marker disarms this PR's auto-poll gate, and that is only permitted when it leaves a durable record. The append to the opt-out log under the resolved state root failed - the directory is unwritable, full, or gone. Fix the state root and retry; an opt-out nobody can later observe is worse than one that is blocked.\"}}"
    exit 0
  fi
  if [[ -z "${NO_AUTO_POLL:-}" ]]; then
    # NO_AUTO_POLL not set — allow but warn: reviewer comments won't be auto-processed.
    # Use JSON with hookSpecificOutput "allow" + systemMessage so the user sees
    # the warning inline. The command is still permitted (permissionDecision: "allow").
    jq -n \
      --arg pr "$PENDING_PR" \
      --arg repo "$PENDING_REPO" \
      '{
        "hookSpecificOutput": {
          "hookEventName": "PreToolUse",
          "permissionDecision": "allow"
        },
        "systemMessage": ("⚠️  Auto-poll DISABLED for PR #" + $pr + " on " + $repo + ". Reviewer comments (human + automated-review) will NOT be auto-processed. To opt out cleanly next time, set NO_AUTO_POLL=1 before creating the PR. To re-enable now: CronCreate a /review-pr cron for this PR and save the cron ID.")
      }'
    exit 0
  else
    # NO_AUTO_POLL is set — user explicitly opted out, allow silently.
    exit 0
  fi

# 4. Git read-only commands (anchored)
#    `rev-parse` was added by H1: it is as read-only as the other five, and it
#    is the command sitting INSIDE the marker-write remedy enforce-fable-review
#    prints — an agent reads the sha before writing it at least as often as it
#    inlines the substitution. Omitting it made the gate refuse a lookup it was
#    effectively asking for. Pinned by TC-XG-2; TC-XG-4 pins that chaining
#    anything onto it still blocks.
elif grep -qE '^[[:space:]]*git[[:space:]]+(status|log|diff|branch|show|rev-parse)([[:space:]]|$)' <<< "$COMMAND"; then
  exit 0

fi

# Block everything else
REASON="BLOCKED: Auto-poll setup required for PR #${PENDING_PR} on ${PENDING_REPO} (Rule 4 — workflow-discipline.md).

The agent MUST set up auto-poll before continuing other work:

  1. CronCreate(cron: \"*/1 * * * *\", prompt: \"/review-pr --repo ${PENDING_REPO} ${PENDING_PR} --auto\", recurring: true, durable: true)
  2. Record creation time IMMEDIATELY (before parsing cron ID — WHY: /review-pr Step 0.5 age
     check runs on HAS_AUTO_FLAG alone, not gated on cron-id presence; writing here ensures
     the 1-day cap applies even if cron-id parsing fails due to response-format changes):
     date +%s > ${REMEDY_DIR}/.pr-${PENDING_OWNER}-${PENDING_REPO_NAME}-${PENDING_PR}-cron-created
  3. Save the cron ID (only if non-empty — do NOT write empty cron-id file):
     [ -n \"\$CRON_ID\" ] && echo \"\$CRON_ID\" > ${REMEDY_DIR}/.pr-${PENDING_OWNER}-${PENDING_REPO_NAME}-${PENDING_PR}-cron-id

To opt out: rm ${REMEDY_MARKER}

All three commands above are explicitly permitted by this hook, so none of them is blocked by the gate that printed it. Copy them as written: the leading tilde is deliberate and home-agnostic, and a cosmetic variant may not match the allowlist.

This hook blocks all other Bash commands until auto-poll is active (cron-id file exists) or the pending marker is removed.

WHAT THIS MARKER IS: it records that auto-poll has NOT BEEN SET UP YET for this PR and originating worktree. It is not the cron. Removing it does NOT cancel or unset an existing cron — use CronList/CronDelete for that. An agent that removed this marker and reported the cron as unset was wrong on both counts (issue #168).

IF YOU DID NOT OPEN THIS PR: a valid structured marker for another worktree is ignored by this caller, so unrelated linked checkouts are not wedged. Missing or malformed caller metadata is deliberately fail-closed; use the owning checkout or register the poller from it. Removing the marker is the documented opt-out and is recorded in .auto-poll-optout.log; prefer registering the poller instead of disarming its gate."

jq -n --arg reason "$REASON" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": $reason
  }
}'
exit 0
