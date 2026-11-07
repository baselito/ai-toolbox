#!/bin/bash
# enforce-codex-review.sh
#
# PreToolUse hook matching on the Bash tool.
# HARD-BLOCKS `gh pr create` unless a Codex pre-PR review has actually run
# for the exact commit being PR'd — but ONLY when Codex is enabled on this
# machine. This makes "Codex reviews before every PR" a guarantee, not a
# best-effort instruction the agent could skip.
#
# Why a hook (not just the skill step):
#   finishing-a-development-branch Step 3.6 *tells* the agent to run the Codex
#   pre-PR pass, but that is an instruction — the agent could slip past it.
#   The user requires it ALWAYS. This hook is the structural backstop: no
#   marker for the current HEAD → no PR.
#
# Enablement gating (Codex is OPTIONAL per machine):
#   The single signal is the `- Codex: enabled` line in memory.md (written by
#   install.sh ONLY after `codex --version` was verified to run). If that line
#   is absent, this hook is a NO-OP — it allows the PR. A teammate who never
#   opted into Codex is never blocked. The gate only bites when the developer
#   chose to enable Codex. The hook deliberately does NOT re-check `codex
#   --version` live: that would let a transient CLI breakage (enabled but not
#   runnable) make the hook treat Codex as disabled while the codex-review
#   skill treats it as enabled — or vice versa. Keeping both on the memory
#   flag means they agree, and the skill's `unavailable` marker handles a real
#   CLI outage without deadlocking PR creation.
#
# Proof of review — the marker:
#   ~/.claude/.codex-review-complete contains a line per reviewed commit:
#     reviewed <full-HEAD-sha>      (Codex ran and returned findings)
#     unavailable <full-HEAD-sha>   (Codex enabled but errored/timed out —
#                                    an explicit, logged escape so a Codex
#                                    OUTAGE does not brick all PRs; this is
#                                    NOT a silent skip — the skill records it)
#   The codex-review skill writes this marker AFTER the pass (and after any
#   fixes it applied), capturing the FINAL HEAD that will be PR'd. The hook
#   binds the marker to the current HEAD sha so a stale marker from an
#   earlier commit/PR cannot satisfy a new PR.
#
# THE DENY TEXT IS PART OF THE GATE (issue #158):
#   The detector reads the RAW command with no heredoc or quote awareness, so a
#   compliance report written via a heredoc gets denied for QUOTING the gate it
#   reports on. The deny is right about the string it matched and wrong about
#   what the command does. ⛔ The fix is NOT to narrow the regex — the breadth
#   is deliberate (see the detector comment below: a gate that recognises one
#   spelling is a gate with a bypass). The fix is that the deny must name a way
#   out that WORKS.
#
#   There are TWO deny paths in this file — the cd/--repo branch and the
#   no-marker branch — and the false positive can land on either, so both carry
#   the same remedy paragraph, defined once. It has two halves and needs both:
#     (a) the non-Bash write path (the Write tool), because writing the text to
#         a temp file FROM BASH re-enters the same scan; and
#     (b) that re-running it as a heredoc cannot help, because the retry
#         carries the same phrase IN ITS OWN BODY.
#   Half (b) is what stops a retry loop, and it is the reader's obvious next
#   move — omitting it costs real time, which is how #158 was found. The wording
#   is copied from pr-action-safety.sh rather than invented: two gates
#   describing the same escape differently is how one of them ends up
#   describing it wrongly.

set -euo pipefail

# Fail CLOSED when jq is missing — consistent with the other PreToolUse hooks.
if ! command -v jq &>/dev/null; then
  cat <<'__DENY__'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: jq is required for hook enforcement (enforce-codex-review). Install jq to continue. Hook fails closed for safety."}}
__DENY__
  exit 0
fi

HOOK_DATA=$(cat)
TOOL_NAME=$(echo "$HOOK_DATA" | jq -r '.tool_name // empty')
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

COMMAND=$(echo "$HOOK_DATA" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
CWD=$(echo "$HOOK_DATA" | jq -r '.cwd // "."' 2>/dev/null || echo ".")

# Return success only when COMMAND contains an actual shell pipeline
# separator. A pipe inside a quoted rg/grep pattern is data, not execution;
# an unquoted pipe can run a second command and must not satisfy this
# read-only-search exemption.
has_unquoted_shell_pipe() {
  local text="$1" char quote="" escaped=0 i
  for ((i=0; i<${#text}; i++)); do
    char="${text:i:1}"
    if (( escaped )); then
      escaped=0
      continue
    fi
    if [[ -z "$quote" && "$char" == "\\" ]]; then
      escaped=1
      continue
    fi
    if [[ -n "$quote" ]]; then
      if [[ "$quote" == '"' && "$char" == "\\" ]]; then
        escaped=1
      elif [[ "$char" == "$quote" ]]; then
        quote=""
      fi
    elif [[ "$char" == "'" || "$char" == '"' ]]; then
      quote="$char"
    elif [[ "$char" == '|' ]]; then
      return 0
    fi
  done
  return 1
}

# `rg --pre` executes a caller-supplied command for each input file, and an
# unquoted pipe can execute a second command. Neither is a read-only search,
# even when the guarded PR action appears only inside a search pattern. Deny
# these shapes explicitly because the conservative PR detector below cannot
# safely infer execution from quoted arguments.
if [[ "$COMMAND" =~ ^[[:space:]]*(rg|grep|egrep|fgrep)([[:space:]]|$) ]] \
   && [[ "$COMMAND" == *"gh pr create"* ]] \
   && { [[ "$COMMAND" == *'--pre'* ]] || has_unquoted_shell_pipe "$COMMAND"; }; then
  jq -n '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": "BLOCKED: this search command can execute a caller-supplied preprocessor or a piped command; it is not read-only, so the Codex PR-review gate cannot exempt it."
    }
  }'
  exit 0
fi

# Read-only search commands frequently quote the guarded action while
# inspecting hook source or documenting a blocker. They are not an action and
# must not force the agent into a deadlock merely because the search pattern
# contains a pipe-separated phrase. Keep this exemption narrow: only the four
# non-executing search tools, only a single command, and never shell
# substitution/chaining. Real action commands remain subject to the gate below.
if [[ "$COMMAND" =~ ^[[:space:]]*(rg|grep|egrep|fgrep)([[:space:]]|$) ]] \
   && [[ "$COMMAND" == *"gh pr create"* ]] \
   && [[ "$COMMAND" != *$'\n'* && "$COMMAND" != *$'\r'* ]] \
   && [[ "$COMMAND" != *'&&'* && "$COMMAND" != *'||'* && "$COMMAND" != *';'* ]] \
   && ! has_unquoted_shell_pipe "$COMMAND" \
   && [[ "$COMMAND" != *'`'* && "$COMMAND" != *'$('* && "$COMMAND" != *'<('* && "$COMMAND" != *'>('* ]] \
   && [[ "$COMMAND" != *'--pre'* ]]; then
  exit 0
fi

# The toolbox policy intentionally skips a local Codex pre-PR pass when the
# user requests Automated review as the independent reviewer. Keep that opt-out scoped
# to this toolbox repository; an environment variable must never disable the
# pre-PR gate in an unrelated project. No marker is written, so the skip is
# explicit and visible in the command environment rather than pretending that
# Codex reviewed the commit.
# PreToolUse receives the raw shell command separately from the environment
# that will be used to execute it. Accept the policy either from the hook
# environment (direct callers) or from the exact leading assignment used by
# `gh pr create`; never treat an arbitrary mention of the variable as a skip.
SKIP_CODEX_REVIEW_REQUESTED=0
if [[ "${AI_ENGINEERING_SKIP_CODEX_REVIEW:-}" == "1" && "$COMMAND" =~ ^[[:space:]]*gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$) ]]; then
  SKIP_CODEX_REVIEW_REQUESTED=1
elif [[ "$COMMAND" =~ ^[[:space:]]*AI_ENGINEERING_SKIP_CODEX_REVIEW=1[[:space:]]+gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$) ]]; then
  SKIP_CODEX_REVIEW_REQUESTED=1
fi

if (( SKIP_CODEX_REVIEW_REQUESTED )); then
  # Do not use the mutable origin URL as repository identity. Instead compare
  # the checkout's git-common-dir with the toolbox root recorded by install.sh
  # in trusted host state. This also recognises linked worktrees, whose common
  # git directory is shared with the installed toolbox checkout, while an
  # unrelated repository with a spoofed origin still fails closed.
  TRUSTED_TOOLBOX_ROOT=""
  if [[ -f "$HOME/.claude/memory.md" ]]; then
    TRUSTED_TOOLBOX_ROOT=$(awk '/^## Toolbox Path$/{getline; print; exit}' "$HOME/.claude/memory.md" 2>/dev/null || true)
  fi
  canonical_common_dir() {
    local repo="$1" common
    common=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null || true)
    [[ -n "$common" ]] || return 1
    if [[ "$common" != /* ]]; then
      common=$(cd "$repo" 2>/dev/null && cd "$common" 2>/dev/null && pwd -P) || return 1
    else
      common=$(cd "$common" 2>/dev/null && pwd -P) || return 1
    fi
    printf '%s\n' "$common"
  }
  CURRENT_COMMON_DIR=$(canonical_common_dir "$CWD" || true)
  TRUSTED_COMMON_DIR=$(canonical_common_dir "$TRUSTED_TOOLBOX_ROOT" || true)
  if [[ -n "$CURRENT_COMMON_DIR" && -n "$TRUSTED_COMMON_DIR" && "$CURRENT_COMMON_DIR" == "$TRUSTED_COMMON_DIR" ]]; then
    exit 0
  fi
fi

# Gate any `gh pr create` TOKEN SEQUENCE. Anchoring `gh` at a boundary (start, or
# after a separator/subshell/WHITESPACE) plus a boundary after `create` stops
# substring over-matching like `gh pr createX` or `mygh pr create` (automated-review PR
# #77), but note what it does NOT do: because whitespace is an accepted leading
# boundary, the phrase matches wherever it appears after a space — including
# inside `echo "... gh pr create ..."` or a `--body` string. This comment used
# to claim those were exempt. They are not, and the false claim cost a later
# session real time: an `echo` mentioning the phrase was blocked with a deny
# message asserting the command "changes directory", which was doubly confusing
# because the command ran no `gh` at all.
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
# WHAT A "PR CREATE" IS — three shapes, not one (C2). THIS FILE IS THE
# CANONICAL COPY of the two detector lines below; enforce-fable-review.sh,
# enforce-compliance-audit.sh and enforce-pr-skill.sh carry them byte for byte
# and point back here rather than re-arguing them. TC-PRC-IDENT asserts the
# four copies are identical, because three gates that recognise a PR create
# slightly differently is three chances for one of them to be the one with the
# hole — and that is exactly what C2 found: six spellings, zero denies, four
# gates.
#
#   1. AN OPTIONAL PATH PREFIX on the command name. `/opt/homebrew/bin/gh pr
#      create` sailed through every gate, because `/` is not in the leading
#      boundary class and so a path-qualified gh was not a gh at all. The
#      prefix group must END in `/`, which is what still keeps `mygh pr create`
#      — the substring over-match from automated-review PR #77 — out.
#   2. FLAG GROUPS BETWEEN THE THREE TOKENS. The old detector required `gh`,
#      `pr` and `create` ADJACENT, so `gh --repo O/R pr create`, `gh -R O/R pr
#      create` and `gh pr -R O/R create` all missed it. That is not an
#      adversarial spelling — `--repo` is what rules/git-workflow.md tells the
#      agent to pass for /review-pr. A group is a token starting with `-`,
#      optionally followed by ONE token that does not; deliberately not "any
#      token", so `gh issue comment 5 --body "the pr will create a thing"`
#      stays allowed (TC-PRC-C2). This is also what makes the --repo/-R
#      refusal below reachable at all: for the flag-interspersed spelling that
#      branch was dead code, because the detector exited first.
# ⛔ THE TRAILING CLASS AFTER `create` NOW INCLUDES BOTH QUOTES. ⛔
# It enumerated shell metacharacters — space, `;&|()<>` and a backtick — and
# omitted `"` and `'`. A create with an EMPTY QUOTED SUFFIX therefore ended in
# a character the class did not list: measured on the pre-fix detector, both
# `<create>""` and `<create>''` were NOT-GATED, and both are ordinary shell for
# a real create. Enumerating terminators is the losing shape this header
# already names one paragraph down; the two quote characters were the ones
# forgotten. Cost of the widening, stated because it is real: prose ending in a
# quote right after the phrase (an `echo "… <create>"`) now over-blocks too,
# which is the same accepted over-block class the bullets below describe, with
# the same Write-tool remedy in the deny.
#
# ⛔ THE api ENDPOINT TRAILING CLASS IS ANY NON-ALNUM, NOT AN ENUMERATED SET. ⛔
# It used to list specific terminators — space, ; & | ( ) < > and a backtick — and a
# QUOTED endpoint therefore escaped it: `gh api '/repos/O/R/pulls' -f title=x` ends
# in a quote, which was not in the list, so the detector missed a real create.
# Enumerating terminators is the same losing shape as enumerating separators: the one
# you forget is the bypass. Any non-alphanumeric now terminates it, which also covers
# `/` is deliberately EXCLUDED, so `/pulls/123` and `/pulls/57/comments` remain
# reads and are NOT matched. (An earlier draft of this very comment claimed the
# opposite — in the commit that was fixing a comment for overclaiming.) The
# widening is an over-match in the SAFE direction for both consumers of this
# pattern (a gate should over-block; the marker consumer should over-consume).
#   3. `gh api` AGAINST THE PULLS COLLECTION, or the createPullRequest GraphQL
#      mutation. No hook mentioned `gh api` anywhere, and it is the standard
#      fallback an agent reaches for when the normal path keeps failing —
#      which is precisely the state a rotation of PR gates manufactures.
#      `pulls` must be the LAST path segment, so the read paths /review-pr
#      actually uses (`…/pulls/<N>/comments`, `…/issues/<N>/comments`) are NOT
#      gated (TC-PRC-C1).
#
# ACCEPTED RESIDUALS — named, because an unnamed residual reads as a guarantee
# (rules/security.md item 7):
#   * A quote- or backtick-wrapped command NAME is still not gated (`"gh" pr
#     create`), unchanged: putting those in the boundary class would
#     over-block ordinary markdown prose, and anyone who can run arbitrary
#     Bash can delete this file anyway.
#   * `gh api /repos/O/R/pulls` with no POST is gated too. That is a read, so
#     it is an over-block; requiring a method flag would add `-XPOST` and
#     `--method post` spellings to chase, and item 7 says take the over-block.
#   * ⛔ CLOSED, NO LONGER A RESIDUAL — `env -C … <create>` and `git -C`. ⛔
#     This bullet has been rewritten twice and both earlier versions were
#     wrong in a way worth recording, because the shape recurs. Version one
#     claimed the command was "still not seen"; measured, it IS seen — the
#     detector matches the three tokens wherever they sit and does not care
#     what precedes them. Version two corrected that and then named the REAL
#     problem — that `env -C`/`git -C` defeat the narrower cd/--repo BINDING
#     check further down, which resolves HEAD from the payload cwd and so
#     certifies the wrong tree — as an ACCEPTED residual. Naming a hole is not
#     accepting it: a reviewer graded that red, correctly, because the binding
#     is the whole control and a documented bypass of it is still a bypass.
#     The cwd-change check now has an `env -C`/`--chdir`/`git -C` arm and
#     denies all four spellings. Measured before: allowed with a marker for
#     THIS checkout. After: denied by the relocation arm, in all three
#     sha-binding gates, with the plain form still allowed (the control that
#     matters — an over-block here deadlocks every PR).
#     Genuinely not seen by the DETECTOR: a variable-indirected interpreter
#     path, and a backslash-newline continuation BETWEEN the three tokens.
#     Closing those needs a shell-aware parser, not another boundary tweak.
#   * ⛔ STALE BULLET, CORRECTED — the api arm's flag grammar. ⛔ This used to
#     say the api group was `([[:space:]]+-[^S]*)*`, bare flags only, so a
#     VALUED global flag before the subcommand (a `--hostname h.com` ahead of
#     `api`) scored api=0 and was allowed. That was true of an earlier
#     revision. It is NOT true of the code two lines below, which carries the
#     SAME flag+value group as its pr-create sibling — measured: the
#     `--hostname`-before-`api` spelling against the pulls collection is GATED,
#     and TC-PRC-38 pins it. A reviewer re-reported the bullet as a live
#     bypass, which is the cost of leaving a residual note behind after the
#     code moved: it is indistinguishable from a real finding until someone
#     measures. Nothing was changed in the detector for this; the defect was
#     the comment.
#   * The over-block on inert prose is unchanged and still deliberate: the
#     phrase after any whitespace matches, so an echo or a --body string
#     mentioning it is gated. The remedy is in the deny.
#     COST, NOW MEASURED rather than asserted: writing the review notes for
#     this very round tripped this over-block THREE times — once each on
#     pr-action-safety, enforce-jira-delegation and this gate — purely for
#     QUOTING a gated phrase in prose. The documented remedy (write the file
#     with a non-Bash tool) worked every time. Recording the number because
#     #139 is open on whether a shell-aware parser is worth it, and that
#     decision needs a real cost figure rather than an impression.
#
# Matched with here-strings (`<<<`), never `printf | grep`: under pipefail the
# pipe form can SIGPIPE on large input and flip a deny into an allow.
if ! grep -qE '(^|[;&|()`[:space:]])(["]([^[:space:];&|()]*/)?gh["]|'"'"'([^[:space:];&|()]*/)?gh'"'"'|([^[:space:];&|()]*/)?gh)([[:space:]]+-[^[:space:];&|()]*([[:space:]]+[^-[:space:];&|()][^[:space:];&|()]*)?)*[[:space:]]+(["]pr["]|'"'"'pr'"'"'|pr)([[:space:]]+-[^[:space:];&|()]*([[:space:]]+[^-[:space:];&|()][^[:space:];&|()]*)?)*[[:space:]]+(["]create["]|'"'"'create'"'"'|create)([[:space:];&|()<>`"'"'"']|$)' <<< "$COMMAND" \
   && ! { grep -qE '(^|[;&|()`[:space:]])(["]([^[:space:];&|()]*/)?gh["]|'"'"'([^[:space:];&|()]*/)?gh'"'"'|([^[:space:];&|()]*/)?gh)([[:space:]]+-[^[:space:];&|()]*([[:space:]]+[^-[:space:];&|()][^[:space:];&|()]*)?)*[[:space:]]+(["]api["]|'"'"'api'"'"'|api)([[:space:]]|$)' <<< "$COMMAND" \
          && grep -qE '(^|[^[:alnum:]_])repos/[^[:space:]/;&|()]+/[^[:space:]/;&|()]+/pulls([^[:alnum:]_/]|$)|createPullRequest' <<< "$COMMAND"; }; then
  exit 0
fi
# Trailing boundary includes shell metacharacters (`;&|()<>`), not just
# whitespace/EOL: a REAL `gh pr create` can be immediately followed by `;`,
# `&&`, `||`, `)`, or a redirection (`>`/`<`) with no intervening space —
# e.g. `gh pr create;next`, `gh pr create&&echo ok`, `(gh pr create)`. The
# earlier whitespace-only trailing boundary let those slip the gate entirely
# (automated-review PR #77 round-2, two 🔴 findings). A real command token is never
# followed directly by a letter/dash/slash, so `gh pr createX` still does not
# match — the substring-over-match fix from round-1 is preserved.

# --- Enablement check: gate ONLY when the developer opted into Codex ---
# The single source of truth is the `- Codex: enabled` line in memory.md, which
# install.sh writes ONLY after verifying `codex --version` actually runs. Using the
# memory flag (not a live `codex --version` here) keeps the hook and the codex-review
# skill in lockstep on what "enabled" means — otherwise the skill could treat Codex as
# disabled (CLI not runnable) and skip, while the hook treats it as enabled and blocks,
# deadlocking PR creation. If the CLI is enabled-but-broken, the skill's outage path
# records an `unavailable` marker, which this hook accepts.
# STATE_DIR is overridable (CLAUDE_STATE_DIR) so tests can exercise both paths
# deterministically without depending on the machine's real memory.md.
#
# THE STATE ROOT MUST RESOLVE FIRST. With neither variable set, the expansion
# below is an unbound-variable abort under `set -u`: exit 1, no JSON, gate
# fails OPEN. With HOME="" this hook was worse than the siblings — it did not
# abort, it read enablement from `/.claude/memory.md`, found nothing, and
# silently ALLOWED. Canonical copy of this guard, and the full rationale for
# both spellings and for the placement, is in enforce-fable-review.sh.
if [[ -z "${CLAUDE_STATE_DIR:-}" && -z "${HOME:-}" ]]; then
  cat <<'__DENY__'
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "BLOCKED: neither HOME nor CLAUDE_STATE_DIR is set, so enforce-codex-review cannot locate the state directory holding memory.md and the review marker — it cannot even establish whether Codex is enabled here. A gate that cannot find its own evidence has not been satisfied, so it fails closed.\n\nThis cannot be fixed from inside a Bash tool call — every call is a fresh shell, so an `export` here does not survive to the next one. Set HOME (or CLAUDE_STATE_DIR) in the environment the agent itself runs in — the `env` block of ~/.claude/settings.json, or the container/CI environment — and start a new session."}}
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

MEMORY_FILE="$STATE_DIR/memory.md"

# "I CANNOT READ memory.md" IS NOT "CODEX IS DISABLED" (H5). It is "enablement
# is unknown", and unknown input is not consent (rules/security.md item 2).
#
# The old single `grep … 2>/dev/null` collapsed the two into one answer, and
# that made CLAUDE_STATE_DIR a ONE-VARIABLE SILENT DISABLE for this gate.
# Redirect it and the four PR gates react in OPPOSITE directions: three get
# STRICTER, because their markers are not under the new root, so they deny.
# This one got WEAKER — it read enablement from the same root, found nothing,
# concluded "never opted in", and allowed. Measured: state=real -> deny,
# state=empty -> allow. The asymmetry is what made it dangerous rather than
# merely wrong: the observable symptom of the disable read as SUCCESS. And the
# variable is settable persistently from the `env` block of
# ~/.claude/settings.json, with no gated tool call anywhere in the path.
#
# install.sh always creates memory.md (Step 6.5 seeds it from the repo template
# before writing any Codex line, and a later step creates it when absent), so
# on a machine this toolbox installed, an ABSENT memory.md means the state root
# is not the state root. Fail closed and say so.
#
# A memory.md that EXISTS and carries no Codex line is a real opt-out and still
# allows — a teammate who never enabled Codex is never blocked. That
# distinction is the whole fix, and TC-ECR-67 (plus TC-ECR-5) is the control
# that keeps it.
if [[ ! -r "$MEMORY_FILE" ]]; then
  jq -n --arg mem "$MEMORY_FILE" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": ("BLOCKED: enforce-codex-review cannot read memory.md, so it cannot establish whether Codex is enabled here — and an unreadable enablement file is not an opt-out.\n\n  expected at: " + $mem + "\n\nIf CLAUDE_STATE_DIR is set, it is pointing at a directory that has no memory.md. That single variable used to turn this gate OFF while making the other PR gates STRICTER, so the disable looked like success. Unset it, or point it at the real state directory.\n\nIf you never opted into Codex, that is recorded by memory.md EXISTING without a `- Codex:` line — which still allows. Re-run scripts/install.sh, or create ~/.claude/memory.md, and this gate goes back to being a no-op for you.")
    }
  }'
  exit 0
fi

# Anchor on the exact state token `enabled` — `.*enabled` would also match
# `- Codex: not enabled` / `- Codex: disabled (was enabled)` and wrongly gate
# a developer who opted OUT. The trailing class allows an inline `# comment`
# or end-of-line after the token. The codex-review skill uses the SAME regex
# so the two stay in lockstep on what "enabled" means.
if ! grep -qiE '^- *Codex:[[:space:]]*enabled([[:space:]#]|$)' "$MEMORY_FILE" 2>/dev/null; then
  exit 0   # Codex not enabled for this developer → PR allowed (no-op)
fi

# --- Codex enabled BUT known-down (spend cap / hard outage) → no-op, do not block ---
# The codex-review skill touches ~/.claude/.codex-unavailable when `codex exec` hits the
# workspace spend cap or any hard failure. While that marker is FRESH (TTL 3600s), Codex is
# treated exactly like "not enabled": the skill skips it and the workflow proceeds Claude-only,
# so the gate must not deadlock PR creation waiting for a review that cannot run. A stale marker
# (> TTL) is ignored — the next task re-probes Codex, and a real review (or a fresh `unavailable`
# marker) is expected again. This is the graceful-degradation path from rules/performance.md.
CAP_MARKER="$STATE_DIR/.codex-unavailable"
if [ -f "$CAP_MARKER" ]; then
  # Portable mtime: GNU `stat -c %Y` first (BSD rejects -c), else BSD `stat -f %m`.
  # NOT `date -r FILE` — on macOS that interprets the arg as epoch seconds, not a file.
  CAP_MTIME=$(stat -c %Y "$CAP_MARKER" 2>/dev/null || stat -f %m "$CAP_MARKER" 2>/dev/null || echo 0)
  CAP_AGE=$(( $(date +%s) - CAP_MTIME ))
  if [ "$CAP_MTIME" -gt 0 ] && [ "$CAP_AGE" -ge 0 ] && [ "$CAP_AGE" -lt 3600 ]; then
    exit 0   # Codex known-unavailable (capped/outage) within TTL → PR allowed (no-op)
  fi
fi

# --- Reject a `cd` that runs BEFORE `gh pr create` in the same command ---
# The marker is bound to the Bash tool's cwd (.cwd below). Any construct that
# could run `gh pr create` in a DIFFERENT directory or against a DIFFERENT repo
# would let a review done in repo A unblock a PR created in repo B (Codex PR7
# round-2/round-3 P1). The agent's normal path is a plain `gh pr create` from
# the checkout, so we fail closed on the cwd/repo-changing constructs we know:
#   - `cd` / `pushd` / `popd` at a command boundary — start, after a separator
#     (`;` `&&` `||` `|`), or opening a subshell `(`. We scan the WHOLE command
#     (not just the text before the first `gh pr create`) so a no-op decoy like
#     `: gh pr create; cd ../b && gh pr create` and a subshell like
#     `(cd ../b && gh pr create)` are both caught.
#   - `gh pr create --repo/-R <other>` — aims the PR at a repo other than the
#     reviewed cwd, even with no `cd`.
# Boundary-anchored (not bare whitespace) so the word "cd" inside a title/body
# doesn't false-positive, and `git push && gh pr create` stays allowed.
#
# This is a WORKFLOW-DISCIPLINE gate, not an adversarial sandbox: anyone who can
# run arbitrary Bash can defeat any hook (delete it, forge the marker). The goal
# is that the agent's normal PR-create path cannot SILENTLY skip the review.
# Known residuals (out of scope, documented deliberately): a
# variable-indirected interpreter path. ⛔ `env -C` AND `git -C` USED TO BE ON
# THIS LINE and are no longer residuals — the cwd-change check below denies
# both, plus `--chdir` in either spelling. They were removed from this list in
# the same change that added the arm, because a residual list that still names
# a closed hole is worse than no list: the next reader trusts it and stops
# looking. Also formerly listed here: a literal
# a `cd` inside an INLINE `--body`/`--title`. ⛔ THE SPELLING NAMED HERE USED TO BE
# only `;cd`/`(cd`, which understated it: the cwd detector anchors PER LINE, so an
# ordinary PR body whose "how to test" section simply STARTS A LINE with `cd ` trips
# it — neither of the two spellings named, and by far the commoner one. Measured: a
# body of `## How to test / cd packages/api / npm test` is denied by THREE gates
# — enforce-fable-review, enforce-compliance-audit AND THIS ONE. An earlier
# revision of this comment named only the other two, counting the siblings from
# INSIDE the third, and the --body-file escape was then added to exactly the two
# it named. That is this branch's own recurring asymmetry, committed by the fix
# for the previous instance of it. Denied by
# enforce-fable-review and enforce-compliance-audit; the same text mid-sentence is
# not. An unnamed residual reads as a guarantee (rules/security.md item 7), and a
# residual named one notch narrower than it is has the same defect in miniature.
# ⛔ AND THIS USED TO SAY
# "our workflow uses `--body-file`, so this is rare" — MEASURED FALSE. The only
# documented PR-create form in the toolbox is the INLINE heredoc body at
# skills/finishing-a-development-branch/SKILL.md, and `--body-file` appears there
# ZERO times. So the inline body is not the rare path, it is the ONLY path, and
# the same scan makes a repo flag MENTIONED IN BODY PROSE block a legitimate
# create — measured: a body reading "merge with /merge-pr N --repo owner/repo"
# is denied by enforce-fable-review, enforce-compliance-audit and this gate. It over-blocks,
# never under-blocks, but the remedy has to be NAMED: write the body to a file
# and pass `--body-file <path>`, which clears the repo-flag deny while leaving
# every real workflow gate in place (verified). This is the same unmeasured
# "our workflow always does X" claim class that the eleven-not-five correction
# in enforce-loop-bounds.sh exists to stop;
# the repo flag INTERSPERSED before the `create` token
# (`gh -R other/repo pr create`, `gh --repo x pr create`, `gh pr -R x create`),
# which slips the `gh<sp>pr<sp>create` detector entirely; and exotic shell
# packagings of the call — backtick command substitution (``url=`gh pr create``)
# and backslash-newline continuation (`gh pr\<newline>create`). Broadening the
# detector to chase these spellings has blast radius on the whole gate (this
# regex has already regressed twice from added cleverness), and the normal
# workflow never writes them — so they stay documented residuals, consistent
# with the workflow-discipline (not adversarial-sandbox) scope above. Closing
# them properly needs a shell-aware parser, not another boundary tweak.
# Matched with a here-string (`<<<`), NOT `printf | grep`: under `set -o
# pipefail`, `printf "$COMMAND" | grep -qE` can return non-zero even on a MATCH
# when the command is large/multi-line — `grep -q` matches an early line and
# exits, `printf` then dies with SIGPIPE (141), pipefail propagates the 141,
# and the caller's branch wrongly takes the "no match" path → gate BYPASSED.
# This is the exact bug enforce-pr-skill.sh already fixed (see its "Matched
# with a here-string" comment) for the `gh pr create` detector at line 135
# above; these two detectors (cd/pushd/popd and --repo/-R) were the unfixed
# follow-up that comment flagged. A here-string has no upstream process to
# SIGPIPE, so the match is reliable regardless of command size.
DENY_REASON=""
if grep -qE '(^|[;&|(])[[:space:]]*(cd|pushd|popd)[[:space:]]' <<< "$COMMAND"; then
  DENY_REASON="changes directory (cd/pushd/popd) — the Codex review is bound to the working directory, so this could let a review done here unblock a PR created elsewhere"
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
  DENY_REASON="relocates the command with env -C/--chdir or git -C - the Codex review is bound to the HEAD this hook resolves in the command's own working directory, while -C moves only where the command itself executes, so the reviewed commit need not be the pushed one. Issue the create plainly from inside the checkout that was reviewed, with no cd/pushd, no -C and no --repo."
elif grep -qE '(^|[[:space:]])(--repo([[:space:]=]|$)|-R[[:space:]=]|-R[A-Za-z0-9._-]*/[A-Za-z0-9._-])' <<< "$COMMAND"; then
  # Match every gh-accepted repo-flag spelling: `--repo x`, `--repo=x`,
  # `-R x`, `-R=x`, and the ATTACHED form `-Rowner/repo`. The attached form
  # requires a `/` (a repo spec is owner/repo) so a title word like `-Region`
  # is NOT mistaken for a repo flag (automated-review PR #77: -R-in-title false
  # positive). The boundary prefix keeps `-R` from matching mid-token.
  DENY_REASON="targets another repository (--repo/-R) — the Codex review is bound to the current checkout HEAD, not the named repo"
fi
if [[ -n "$DENY_REASON" ]]; then
  jq -n --arg why "$DENY_REASON" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": ("BLOCKED: Codex is enabled and this command " + $why + ". Run `gh pr create` as a plain command from the repository checkout (no cd/pushd, no --repo), after the codex-review skill has recorded a marker for the current checkout HEAD.\n\nIf there is no cd/pushd and no --repo in your COMMAND because the token is inside a --body or --title STRING, this scan has no quote awareness and read your prose as part of the command. Note the cwd detector anchors PER LINE, so a PR body whose how-to-test section starts a line with the two characters c,d then a space trips it. Write the body to a file with the Write tool and pass --body-file <path> instead, which clears this deny and leaves every other gate in place.\n\nNOT actually creating a PR? The scan reads the RAW command text with no heredoc or quote awareness, so a command that merely MENTIONS the phrase in prose — a report, a comment, a documentation body — trips the same check. That over-block is deliberate and accepted (PR #128 removed the quote/heredoc-aware parser because it produced misses in the other direction, and for a workflow-discipline gate an over-block is the safe failure).\n\nWorkaround: create the file with a NON-Bash write path (the Write tool), then run it. Writing it via a Bash heredoc does NOT help — that command carries the same phrase in its own body and is scanned before it can run. Re-wording the text (e.g. splitting `gh pr` and `create` across words) also works.")
    }
  }'
  exit 0
fi

# --- Codex IS enabled → require proof of a pre-PR review for the current HEAD ---
MARKER_FILE="$STATE_DIR/.codex-review-complete"

# Resolve the commit being PR'd (the branch tip). Use the tool's cwd so the
# hook reads the right repo even when fired from a subagent.
HEAD_SHA=$(cd "$CWD" 2>/dev/null && git rev-parse HEAD 2>/dev/null || echo "")
if [[ -z "$HEAD_SHA" ]]; then
  # HARD gate — fail CLOSED. Codex is enabled but we cannot prove which commit
  # is being PR'd. This happens when the command runs from a non-repo cwd, or
  # `cd`s elsewhere first, or uses `gh pr create --repo <other>` to open a PR
  # from outside the checkout. Failing OPEN here would be a real bypass: an
  # agent could `cd /tmp && gh pr create --repo …` to dodge the review the
  # user requires ALWAYS. So we deny and tell the agent to run `gh pr create`
  # from inside the repo, where HEAD resolves and can be bound to the marker.
  jq -n '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": "BLOCKED: Codex is enabled but enforce-codex-review could not resolve the commit being PR'\''d (HEAD did not resolve in the command'\''s working directory). Run `gh pr create` from inside the repository checkout so the Codex pre-PR review can be bound to the exact HEAD. If you intentionally create PRs from outside the checkout, do that step manually after running the `codex-review` skill."
    }
  }'
  exit 0
fi

# Allow if the marker records a review (or an explicit unavailable escape)
# for THIS exact commit. `reviewed <sha>` or `unavailable <sha>`.
if [[ -f "$MARKER_FILE" ]] && grep -qE "^(reviewed|unavailable)[[:space:]]+${HEAD_SHA}([[:space:]]|$)" "$MARKER_FILE"; then
  exit 0
fi

# BLOCK — Codex is enabled but no pre-PR review is recorded for this commit.
jq -n --arg sha "${HEAD_SHA:0:12}" --arg root "$REMEDY_DIR" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": ("BLOCKED: Codex is enabled but no pre-PR Codex review is recorded for the current commit (HEAD " + $sha + "). Codex MUST review every PR before it is created.\n\nRun the pre-PR pass first: invoke the `codex-review` skill on the final diff. It runs Codex read-only and writes " + $root + "/.codex-review-complete for this HEAD, after which `gh pr create` is allowed. (This is normally Step 3.6 of finishing-a-development-branch — do not skip it.)\n\nIf Codex genuinely cannot run (outage), the codex-review skill records an `unavailable` marker for this HEAD so an outage does not block the PR — but that path only triggers after the skill actually attempts the review, never as a silent skip.\n\nNOT actually creating a PR? The scan reads the RAW command text with no heredoc or quote awareness, so a command that merely MENTIONS the phrase in prose — a report, a comment, a documentation body — trips the same check. That over-block is deliberate and accepted (PR #128 removed the quote/heredoc-aware parser because it produced misses in the other direction, and for a workflow-discipline gate an over-block is the safe failure).\n\nWorkaround: create the file with a NON-Bash write path (the Write tool), then run it. Writing it via a Bash heredoc does NOT help — that command carries the same phrase in its own body and is scanned before it can run. Re-wording the text (e.g. splitting `gh pr` and `create` across words) also works.")
  }
}'
exit 0
