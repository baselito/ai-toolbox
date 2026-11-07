#!/bin/bash
# enforce-standing-auth.sh
#
# PreToolUse hook on `Write`, `Edit` and `Bash`. Makes ONE sentence in
# `rules/git-workflow.md` structural instead of aspirational:
#
#     the agent must never write its own standing authorization.
#
# WHY THIS HOOK EXISTS:
#   Standing consent to push / open a PR / run `/merge-pr` used to live in a
#   TRACKED markdown table in this repo. Anyone who could land a commit could
#   add a row that read exactly like consent, so the record was moved OUT of the
#   repo and into `~/.claude/memory.md` — user-owned, untracked, unreachable by
#   a pull request:
#
#       - Standing: <owner>/<repo> push,pr,merge-pr (<YYYY-MM-DD>)
#
#   That closed the REMOTE path. It did not close the LOCAL one. Nothing stopped
#   the AGENT from appending that line itself and then reading it back as the
#   user's consent — the self-granting loop, with a prose sentence as its only
#   guard. That is this branch's whole subject: a guarantee ASSERTED rather than
#   ENFORCED. A guard whose only enforcement is the sentence describing it is
#   not a guard.
#
# WHAT IT DENIES:
#   Any tool call that would CREATE OR MODIFY a `- Standing:` line in the memory
#   file, where the memory file is `${CLAUDE_STATE_DIR:-$HOME/.claude}/memory.md`.
#   Three tools can write a line into a file, so all three are covered:
#     * `Write` — `file_path` targets the memory file AND `content` carries the line
#     * `Edit`  — `file_path` targets the memory file AND `new_string` carries it
#                 (`old_string` is checked against the existing file so an
#                 in-place rewrite cannot change an existing authorization;
#                 removing one complete Standing line remains allowed)
#     * `Bash`  — a write-capable command naming the memory file
#
#   ⛔ A GUARD ON ONE PATH AND ABSENT ON ITS SIBLINGS IS THIS REPO'S MOST-
#   REPEATED DEFECT. ⛔ Covering Write and forgetting Edit would leave the agent
#   one tool call away from the same result, which is why verify-hooks.sh gives
#   each of the three its own deny case rather than one shared case.
#
# WHY THE BASH RULE DOES NOT ENUMERATE WRITE VERBS:
#   `echo >>`, `printf >>`, `cat <<EOF >>`, `tee -a`, `sed -i`, `ed`, `perl -pi`,
#   `python -c`, `>|`, `dd`… enumerating them is how the siblings get missed, and
#   the list is not closed. So the rule is the CONJUNCTION, not the verb:
#
#       this command mentions memory.md  AND  this command is not PROVABLY read-only:
#           → DENY.
#
#   The one legitimate command naming memory.md is a READ — the agent grepping
#   it to see whether authorization exists. That is the single
#   false positive worth engineering around, so it gets a narrow, explicit
#   allowance rather than the rule getting loosened:
#
#     (1) EVERY segment head — the command split on `|`, `||`, `&&`, `;`, `&` and
#         newlines — must be one of: grep rg cat head tail less wc.
#         Checking every segment and not just the first is what closes
#         `grep -q x memory.md; sed -i '…' memory.md`, whose head is `grep` and
#         whose actual work is a write. A first-token-only check allows it.
#     (2) No `>`, `<` or backtick anywhere, and no `$(`. That is redirection and
#         command substitution — the two ways a read-looking command produces a
#         write. It is also what catches `cat <<EOF >> memory.md`, whose head IS
#         on the allowlist.
#     (3) No `-i` / `--in-place` token, and no `tee`. Mostly redundant with (1)
#         — `sed`/`perl`/`tee` are not on the allowlist — and kept anyway as the
#         cheap second layer. It costs one documented false deny: `grep -i` is a
#         harmless read and is denied. Re-run without `-i`.
#
# ALWAYS ON — NOT OPT-IN, AND THE REASON MATTERS:
#   `enforce-ask-budget.sh` is opt-in (a no-op unless memory.md carries
#   `- Autonomy: goal`) because it gates a WORKFLOW PREFERENCE, and forcing that
#   preference on a developer who never asked for it would break their prompting.
#   This hook gates a SECURITY BOUNDARY — privilege escalation by self-granted
#   consent — and two things follow:
#     * Gating it on a memory.md line would put the guard's own switch INSIDE the
#       file the guard protects. An agent that can write `- Standing:` can write
#       (or delete) the opt-in line in the same breath. A switch an attacker
#       controls is not a switch.
#     * The blast radius on a developer who never uses standing authorization is
#       exactly ZERO. The hook fires only on a call that both targets memory.md
#       and carries a Standing line; every other Write, Edit and Bash call in
#       every session falls through at exit 0 having done a few greps.
#
# FAIL DIRECTION — closed on unreadable, no-op on out-of-scope:
#   * `jq` missing                          → DENY. Same as every other
#     PreToolUse gate here: without jq we can neither parse the payload nor emit
#     a structured decision, so allowing would silently disarm the layer. Note
#     this hook is registered on `Bash`, so on a jq-less machine it denies every
#     Bash call — exactly as push-safety.sh and enforce-jira-delegation.sh
#     already do. The machine is not in a supported state either way.
#   * payload is not a readable JSON OBJECT → DENY (fail CLOSED). An unreadable
#     write to the memory file must not be treated as "fine". The risk direction
#     here is the ORDINARY one, unlike enforce-ask-budget: there the gated thing
#     is a QUESTION, so allowing means more human oversight and failing open is
#     failing toward oversight. Here the gated thing is a WRITE, so allowing
#     means the agent acts unsupervised. Closed is correct.
#   * `tool_name` absent, empty, or NOT A STRING → DENY (fail CLOSED). The
#     non-string case is called out because it was a LIVE fail-open in
#     enforce-ask-budget.sh until this branch: `// ""` substitutes only for
#     `null`, so it cannot see a TYPE error — `jq -r` renders `123` as the text
#     "123", which is non-empty and never equals "Write", so every malformed
#     shape took the "not my business" branch and the content scan never ran.
#     Reintroducing that here would be the same bug one file over.
#   * `tool_name` names a DIFFERENT tool     → exit 0, clean no-op. Out of scope
#     is not the same as unreadable.
#   * `file_path` / `content` / `new_string` / `command` present but not a
#     STRING                                 → DENY (fail CLOSED). "We cannot see
#     WHICH file" must not read as "not the memory file", and "we cannot see WHAT
#     is being written" must not read as "nothing bad is being written".
#   * nothing matches                        → exit 0, no-op.
#
# WHY THIS HOOK DOES NOT CARRY THE STATE-ROOT GUARD (the `SR_WHY` shape):
#   (spelled without its trailing `=` on purpose — scripts/verify-hooks.sh
#   TC-DOC-SR-1 finds guarded hooks by grepping hook SOURCE for that assignment,
#   comments included, so writing the assignment out here would make this hook
#   read as guarded and demand a row in a doc paragraph it does not belong in.)
#   Twelve gates in this directory refuse to run at all unless the resolved state
#   root is absolute, existing, readable and safely printable. Those gates decide
#   from a MARKER FILE under the root, so an unresolvable root makes them read a
#   marker that can never be there — a fail-OPEN. This hook does not decide from a
#   marker. Its primary test is the file NAME (`memory.md`), which needs no root at
#   all; the root is used only by the secondary exact-path rule. An unresolvable
#   root therefore degrades it from two detection rules to one, and refusing to run
#   would trade a partial detector for none at all. Recorded here so a reader
#   counting guards concludes "deliberate", not "forgotten".
#
# ⛔ EVERY DENY PATH EXITS 0. ⛔ A hook's exit code is not the decision channel —
# the JSON is. Deny JSON at exit 0 BLOCKS; the IDENTICAL JSON at a non-zero exit
# is IGNORED and the action proceeds. So a deny that exits 1 is an allow with
# extra steps.
#
# ---------------------------------------------------------------------------
# PATH SHAPES — WHAT IS COVERED AND WHAT IS NOT. Read this before trusting it.
#
# A path is judged by TWO independent rules, and a hit on either denies:
#   (a) EXACT — after expanding a leading `~`, a literal `$HOME`/`${HOME}` and a
#       literal `$CLAUDE_STATE_DIR`/`${CLAUDE_STATE_DIR}`, making a relative path
#       absolute against the payload's `cwd`, following symlinks at the leaf
#       (bounded at 16 hops) and resolving the directory with `cd -P`, the path
#       equals the same resolution of `$STATE_DIR/memory.md`.
#   (b) BASENAME — the resolved path is named `memory.md`, wherever it lives.
#
# Neither rule subsumes the other, and both are tested:
#   * (b) alone catches the ordinary spellings AND the repo's own `memory.md`
#     template, which `scripts/install.sh` copies to `~/.claude/memory.md` on a
#     machine that has none — so a Standing line landed in the template is a
#     standing grant on the next fresh install. Third file, same loop.
#   * (a) alone catches a write that reaches the memory file WITHOUT being named
#     `memory.md`: a symlink under another name pointing at it, and the inverse
#     case where memory.md is itself a symlink and the write targets its real
#     destination.
#
# COVERED (each has a test case): `~/.claude/memory.md`; `$HOME/.claude/memory.md`
# and `${HOME}/…`; `$CLAUDE_STATE_DIR/memory.md` and `${CLAUDE_STATE_DIR}/…`; a
# fully-expanded absolute path; a relative path resolved against `cwd`; a bare
# `memory.md`; `..` and symlinked parent directories (via `cd -P`); a symlink at
# the leaf in either direction; any other file named `memory.md`.
#
# NOT COVERED — stated plainly rather than overclaimed:
#   * A path assembled from a shell variable the hook cannot see
#     (`F=~/.claude/memory.md; echo … >> "$F"` — the second call carries no
#     `memory.md` text). Only the literal text of THIS call is available.
#   * A Bash command reaching the file through a symlink named something else:
#     the Bash branch matches on the literal text `memory.md`, and text cannot be
#     resolved. The Write/Edit branch DOES resolve symlinks, because there the
#     path is a single unambiguous field.
#   * A Bash command reaching the file through a path assembled from a shell
#     variable, without a literal `memory.md` in the command text.
#   * Any tool other than Write, Edit and Bash — a `MultiEdit`-style batch tool,
#     an MCP filesystem server, or an editor launched from a terminal the hook
#     does not gate.
#   * The hook cannot tell a *legitimate* Standing line from a self-granted one,
#     and does not try: the point is that the AGENT never writes it. The USER
#     writes it, in their own terminal, where no PreToolUse hook runs.
#
# The Bash branch matches the literal text `memory.md` case-insensitively
# ANYWHERE in the command and denies every non-read-only command that names it.
# That deliberately over-blocks ordinary Bash writes such as `- Codex:` too;
# Write/Edit remain available for those non-standing updates. A Bash command is
# arbitrary text in which the hook cannot tell which file a token refers to, so
# the conservative choice is to guard the whole file rather than infer whether
# a dynamically assembled payload contains an authorization.
#
# THE ONE OVER-BLOCK THAT WILL ACTUALLY BE HIT, named so it is not a surprise:
# authoring DOCUMENTATION that quotes both `memory.md` and a `- Standing:` line —
# this very file, `rules/git-workflow.md`, the test cases — through a Bash
# heredoc is denied, because the hook cannot see that the target is a doc rather
# than the memory file. The Bash deny message says so and points at Write/Edit on
# that doc, which is the normal path for authoring a file anyway and is NOT an
# escape: Write and Edit on the memory file are separately and fully gated.
# ---------------------------------------------------------------------------
#
# All detectors match with here-strings (`<<<`), never `echo | grep`: under
# `set -euo pipefail` the pipe form can SIGPIPE (141) on large input and flip a
# deny into an allow. Same rule and same reason as the other gates in this
# directory; scripts/verify-hooks.sh TC-ESA-22 asserts it statically.

set -euo pipefail

# Drain stdin FIRST, before any exit path, so a large payload cannot SIGPIPE the
# harness on an early no-op exit. `cat` is the only external command this needs,
# which matters for the jq-missing path below.
HOOK_DATA=$(cat)

# Fail CLOSED when jq is missing. Spaces after the colons are deliberate:
# scripts/verify-hooks.sh greps for the spaced `"permissionDecision": "deny"`
# spelling, so the compact form some older hooks use is invisible to it.
if ! command -v jq &>/dev/null; then
  cat <<'__DENY__'
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "BLOCKED: jq is required for hook enforcement (enforce-standing-auth). Install jq (brew install jq / apt install jq / yum install jq) to continue. Hook fails closed for safety."}}
__DENY__
  exit 0
fi

# emit_deny <reason> — print the deny JSON and exit 0. The reason is handed to
# jq on STDIN via a here-string, NOT as an `--arg` value: an `--arg` travels in
# argv, and a multi-megabyte interpolated path would blow ARG_MAX and make the
# exec fail AFTER the deny path had begun, printing nothing at all —
# nothing-on-stdout being a silent ALLOW.
emit_deny() {
  if ! jq -Rs '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": (. | sub("\n$"; ""))
    }
  }' <<< "$1"; then
    # LAST-RESORT DENY: jq itself failed while rendering the message. A deny path
    # must never exit having printed nothing. This literal interpolates nothing,
    # so no input can make it fail in turn.
    cat <<'__DENY__'
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "BLOCKED: enforce-standing-auth denied this call but could not render its explanation (jq failed). The agent must not write a '- Standing:' line into ~/.claude/memory.md. Ask the USER to add it themselves. See rules/git-workflow.md."}}
__DENY__
  fi
  exit 0
}

# --------------------------------------------------------------------------
# Fail CLOSED on a payload that is not a readable JSON object. `jq -e
# 'type == "object"'` answers both halves at once: invalid JSON makes jq exit
# non-zero, and valid-but-not-an-object JSON (array, string, number, null)
# makes the test false.
# --------------------------------------------------------------------------
if ! jq -e 'type == "object"' <<< "$HOOK_DATA" &>/dev/null; then
  emit_deny "BLOCKED: unreadable hook payload (enforce-standing-auth).

The hook input was not a readable JSON object, so this call cannot be checked against the standing-authorization guard in rules/git-workflow.md. The gate fails closed: \"we cannot see what is being written\" must not be treated as \"nothing is being written\".

Re-issue the call. If this recurs, the harness is emitting a malformed hook payload — that is a bug to report, not something to work around."
fi

# --------------------------------------------------------------------------
# `tool_name` must be a READABLE STRING. Absent, empty or wrongly-typed fails
# CLOSED; a DIFFERENT tool is a clean no-op. See the FAIL DIRECTION block for
# why the non-string case is called out by name.
# --------------------------------------------------------------------------
if ! TOOL_NAME=$(jq -er '
  if (.tool_name | type) == "string" then .tool_name else error("tool_name is not text") end
' <<< "$HOOK_DATA" 2>/dev/null); then
  TOOL_NAME=""
fi

if [[ -z "$TOOL_NAME" ]]; then
  emit_deny "BLOCKED: this payload names no tool (enforce-standing-auth).

The payload carries no readable \`tool_name\` (absent, empty, or not a string), so this hook cannot confirm what it is being asked to clear. It guards writes of a \`- Standing:\` line into ~/.claude/memory.md, and an unnamed payload is an unreadable write rather than somebody else's business — so it fails closed.

Re-issue the call. If this recurs, the harness is emitting a hook payload without a tool name — report that rather than working around it."
fi

case "$TOOL_NAME" in
  Write|Edit|Bash) ;;
  *) exit 0 ;;   # out of scope — a clean no-op, not a decision
esac

# --------------------------------------------------------------------------
# State root. Overridable via CLAUDE_STATE_DIR so tests can exercise both
# branches without touching the machine's real memory.md — same convention as
# every other stateful hook here. `${HOME:-}` is not decoration: under `set -u`
# a bare `$HOME` on a machine with HOME unset ABORTS the script, which prints
# nothing and therefore reads as a silent ALLOW.
# --------------------------------------------------------------------------
STATE_DIR="${CLAUDE_STATE_DIR:-${HOME:-}/.claude}"
MEMORY_FILE="$STATE_DIR/memory.md"

# The cwd a relative `file_path` is resolved against. Falls back to the hook's
# own cwd when the payload does not carry one.
if ! HOOK_CWD=$(jq -er '
  if (.cwd | type) == "string" then .cwd else error("no cwd") end
' <<< "$HOOK_DATA" 2>/dev/null); then
  HOOK_CWD="$PWD"
fi

# The exact command the USER runs to grant standing authorization. Named once so
# the deny message and the docs cannot drift apart.
ESA_USER_ACTION="echo '- Standing: <owner>/<repo> push,pr,merge-pr (YYYY-MM-DD)' >> ~/.claude/memory.md"

# --------------------------------------------------------------------------
# _esa_expand <path> — substitute the variable spellings the agent actually
# writes. Deliberately textual: the hook sees the path as the agent typed it,
# and the shell never expanded it. `${HOME}` is replaced before `$HOME` so the
# braced form is not left with a stray `{…}` tail.
# --------------------------------------------------------------------------
_esa_expand() {
  local p="$1"
  case "$p" in
    "~")   p="${HOME:-}" ;;
    "~/"*) p="${HOME:-}/${p#\~/}" ;;
  esac
  p="${p//\$\{CLAUDE_STATE_DIR\}/$STATE_DIR}"
  p="${p//\$CLAUDE_STATE_DIR/$STATE_DIR}"
  p="${p//\$\{HOME\}/${HOME:-}}"
  p="${p//\$HOME/${HOME:-}}"
  printf '%s' "$p"
}

# --------------------------------------------------------------------------
# _esa_resolve <path> — expand, make absolute against the payload cwd, follow
# leaf symlinks (bounded — a symlink cycle must not hang a PreToolUse gate),
# then resolve the directory physically with `cd -P` so `..` segments and
# symlinked parent directories collapse. `realpath`/`readlink -f` are NOT used:
# `readlink -f` is a GNU extension absent on stock macOS, and both fail on a
# path that does not exist yet — which is the normal case for a Write.
# --------------------------------------------------------------------------
_esa_resolve() {
  local p d b t hops=0
  p="$(_esa_expand "$1")"
  if [[ "$p" != /* ]]; then
    p="$HOOK_CWD/$p"
  fi
  d="$(dirname -- "$p")"
  b="$(basename -- "$p")"
  while [[ -L "$d/$b" ]] && [[ "$hops" -lt 16 ]]; do
    if ! t="$(readlink "$d/$b")"; then
      break
    fi
    if [[ "$t" != /* ]]; then
      t="$d/$t"
    fi
    d="$(dirname -- "$t")"
    b="$(basename -- "$t")"
    hops=$((hops + 1))
  done
  local rd
  rd="$(cd -P -- "$d" 2>/dev/null && pwd)" || rd="$d"
  printf '%s/%s' "$rd" "$b"
}

# --------------------------------------------------------------------------
# _esa_targets_memory <path> — rules (a) and (b) from the PATH SHAPES block.
# A hit on either denies; neither subsumes the other.
# --------------------------------------------------------------------------
_esa_targets_memory() {
  local resolved base target
  resolved="$(_esa_resolve "$1")"
  base="${resolved##*/}"
  # (b) BASENAME — any file named memory.md, wherever it lives. This is what
  #     covers the repo's install template as well as every ordinary spelling.
  if [[ "$base" == "memory.md" ]]; then
    return 0
  fi
  # (a) EXACT — resolves to THE memory file under another name. Catches the
  #     case where memory.md is itself a symlink and the write targets its real
  #     destination, which the basename rule cannot see.
  target="$(_esa_resolve "$MEMORY_FILE")"
  if [[ "$resolved" == "$target" ]]; then
    return 0
  fi
  return 1
}

# --------------------------------------------------------------------------
# _esa_has_standing_line <text> — is there a LIST LINE granting standing auth?
#
# Anchored to a line that begins (after optional indentation) with a dash and
# then `Standing:`. Deliberately LOOSER than the canonical `- Standing:` the
# docs specify — leading whitespace, a missing space after the dash, extra
# spaces, and any casing all match — because the point is to catch every
# spelling a READER would take for standing authorization, not just the one
# spelling the grammar blesses. Over-matching here costs nothing: the only
# remedy the agent is offered is "ask the user", in every case.
#
# It is NOT a bare substring search for "Standing". A memory.md that discusses
# standing authorization in prose grants nothing, and denying that would make
# the file undocumentable.
# --------------------------------------------------------------------------
_esa_has_standing_line() {
  grep -qiE '^[[:space:]]*-[[:space:]]*Standing[[:space:]]*:' <<< "$1"
}

# --------------------------------------------------------------------------
# _esa_read_only_bash <command> — is this command PROVABLY a read?
# Returns 0 only when all three conditions in the header block hold. Anything
# it cannot prove read-only is not read-only.
# --------------------------------------------------------------------------
_esa_read_only_bash() {
  local cmd="$1"
  # (2) redirection, command substitution, backticks — the ways a read-looking
  #     command produces a write. `<` is included because a heredoc write
  #     (`cat <<EOF >> file`) has an allowlisted head.
  if grep -qE '[<>`]' <<< "$cmd"; then
    return 1
  fi
  if grep -qF '$(' <<< "$cmd"; then
    return 1
  fi
  # (3) in-place edit flags and tee. Mostly redundant with (1); kept as the
  #     cheap second layer. Documented cost: `grep -i` is denied.
  if grep -qE '(^|[[:space:]])(-i|--in-place)([[:space:]=]|$)' <<< "$cmd"; then
    return 1
  fi
  if grep -qE '(^|[[:space:]])tee([[:space:]]|$)' <<< "$cmd"; then
    return 1
  fi
  # (1) EVERY segment head must be on the read-only allowlist. Splitting is done
  #     with parameter expansion rather than `sed 's/…/\n/'` because BSD sed
  #     (stock macOS) emits a literal `n` for `\n` in the replacement — the
  #     splitter would silently do nothing and every command would look like a
  #     single allowlisted segment.
  local norm="$cmd"
  norm="${norm//&&/$'\n'}"
  norm="${norm//||/$'\n'}"
  norm="${norm//|/$'\n'}"
  norm="${norm//;/$'\n'}"
  norm="${norm//&/$'\n'}"
  local seg head
  while IFS= read -r seg; do
    seg="${seg#"${seg%%[![:space:]]*}"}"     # strip leading whitespace
    if [[ -z "$seg" ]]; then
      continue
    fi
    head="${seg%%[[:space:]]*}"
    head="${head##*/}"                        # /usr/bin/grep -> grep
    case "$head" in
      grep|rg|cat|head|tail|less|wc) ;;
      *) return 1 ;;
    esac
  done <<< "$norm"
  return 0
}

# --------------------------------------------------------------------------
# _esa_deny_self_grant <what> — the ONE deny message. It must say what was
# blocked, why, and the single action available — which is the USER's, not the
# agent's. It deliberately offers the agent NO workaround: a workaround is the
# self-granting loop wearing a different hat.
# --------------------------------------------------------------------------
_esa_deny_self_grant() {
  emit_deny "BLOCKED: the agent cannot write its own standing authorization (enforce-standing-auth).

WHAT WAS BLOCKED: $1 — a call that would create or modify a \`- Standing:\` line in ~/.claude/memory.md.

WHY: that line is the record of the USER's standing consent to push, open a PR, and run /merge-pr in a named repo. An agent that can write the line can grant itself the authority it then reads back as consent — the self-granting loop. The record was moved out of this repo's tracked table precisely so that no actor other than the user could write it; the agent writing it locally restores the same hole through a different file. Consent that the agent can author is not consent.

THE ONE ACTION — the USER runs this, in their own terminal:
  $ESA_USER_ACTION

Until that line exists, there is no standing authorization for that repo: ask per branch before pushing or opening a PR (rules/git-workflow.md, \"Standing authorization — dated decisions\").

Do not look for another way to write it. Reading ~/.claude/memory.md is unaffected — this gate blocks writes of that line, not reads of it.${2:-}"
}

# ===========================================================================
# THE CHECK — one branch per tool. Each of the three is a sibling of the other
# two; a fix that lands on one is not a fix that lands on all.
# ===========================================================================
case "$TOOL_NAME" in

  Write|Edit)
    # Write scans its complete new content. Edit scans both the replacement and
    # the existing target so an agent cannot rewrite only the owner/repo/date
    # portion of an existing Standing line.
    if [[ "$TOOL_NAME" == "Write" ]]; then
      ESA_FIELD="content"
    else
      ESA_FIELD="new_string"
    fi

    # `file_path` must be readable text. Fail CLOSED if it is not: "we cannot
    # see WHICH file" must not read as "not the memory file".
    if ! ESA_PATH=$(jq -er '
      if (.tool_input.file_path | type) == "string" then .tool_input.file_path
      else error("file_path is not text") end
    ' <<< "$HOOK_DATA" 2>/dev/null); then
      emit_deny "BLOCKED: this $TOOL_NAME payload's file_path is not readable text (enforce-standing-auth).

The target file cannot be determined, so this hook cannot rule out that it is ~/.claude/memory.md. The gate fails closed — an unreadable target is not the same as a safe one.

Re-issue the call with a plain-string file_path."
    fi

    # Not the memory file → none of this hook's business. This is the exit taken
    # by essentially every Write and Edit in every session.
    if ! _esa_targets_memory "$ESA_PATH"; then
      exit 0
    fi

    # It IS the memory file, so the written text must be readable. Fail CLOSED.
    if ! ESA_TEXT=$(jq -er --arg f "$ESA_FIELD" '
      if (.tool_input[$f] | type) == "string" then .tool_input[$f]
      else error("field is not text") end
    ' <<< "$HOOK_DATA" 2>/dev/null); then
      emit_deny "BLOCKED: this $TOOL_NAME targets ~/.claude/memory.md but its \`$ESA_FIELD\` is not readable text (enforce-standing-auth).

The hook cannot see what would be written, so it cannot rule out a \`- Standing:\` line. The gate fails closed — \"we cannot see what is being written\" must not be treated as \"nothing is being written\".

Re-issue the call with a plain-string \`$ESA_FIELD\`."
    fi

    if _esa_has_standing_line "$ESA_TEXT"; then
      _esa_deny_self_grant "a $TOOL_NAME to $ESA_PATH"
    fi

    if [[ "$TOOL_NAME" == "Edit" ]]; then
      if ! ESA_OLD=$(jq -er '
        if (.tool_input.old_string | type) == "string" then .tool_input.old_string
        else error("old_string is not text") end
      ' <<< "$HOOK_DATA" 2>/dev/null); then
        emit_deny "BLOCKED: this Edit payload's old_string is not readable text (enforce-standing-auth).

The hook cannot compare the edit with the existing memory file, so it cannot rule out that the edit rewrites a Standing authorization. The gate fails closed.

Re-issue the call with a plain-string old_string, or remove one complete Standing line at a time."
      fi

      ESA_REAL_PATH="$(_esa_resolve "$ESA_PATH")"
      if [[ -f "$ESA_REAL_PATH" ]]; then
        if ! ESA_CURRENT=$(cat -- "$ESA_REAL_PATH" 2>/dev/null); then
          emit_deny "BLOCKED: this Edit targets ~/.claude/memory.md but the existing file cannot be read (enforce-standing-auth).

The hook cannot determine whether old_string rewrites an existing Standing authorization, so it fails closed."
        fi
        ESA_REMOVES_LINE="no"
        ESA_TOUCHES_STANDING="no"
        ESA_OLD_OFFSET=0
        ESA_SEARCH="$ESA_CURRENT"
        # Find every occurrence of a non-empty old_string in the complete
        # current file so a multiline Edit cannot hide a Standing line behind
        # a newline. The wrapper line scan below then compares byte/character
        # intervals, including each line's trailing newline, rather than
        # requiring the whole old_string to fit inside one current line.
        #
        # An empty old_string carries no insertion offset in the Edit payload.
        # If an existing Standing line is present, fail closed: otherwise an
        # insertion inside that line could alter its authorization text while
        # looking like unrelated new_string content.
        if [[ -z "$ESA_OLD" ]]; then
          if _esa_has_standing_line "$ESA_CURRENT"; then
            _esa_deny_self_grant "an Edit with no old_string that could insert into an existing Standing line in $ESA_PATH"
          fi
        else
          while [[ "$ESA_SEARCH" == *"$ESA_OLD"* ]]; do
            ESA_PREFIX="${ESA_SEARCH%%"$ESA_OLD"*}"
            ESA_MATCH_START=$((ESA_OLD_OFFSET + ${#ESA_PREFIX}))
            ESA_MATCH_END=$((ESA_MATCH_START + ${#ESA_OLD}))
            ESA_LINE_START=0
            while IFS= read -r ESA_CURRENT_LINE; do
              ESA_LINE_END=$((ESA_LINE_START + ${#ESA_CURRENT_LINE} + 1))
              if _esa_has_standing_line "$ESA_CURRENT_LINE" \
                 && (( ESA_MATCH_START < ESA_LINE_END && ESA_MATCH_END > ESA_LINE_START )); then
                ESA_TOUCHES_STANDING="yes"
              fi
              ESA_LINE_START=$ESA_LINE_END
            done <<< "$ESA_CURRENT"
            ESA_SEARCH="${ESA_SEARCH#*"$ESA_OLD"}"
            ESA_OLD_OFFSET=$((ESA_MATCH_END))
          done
        fi
        while IFS= read -r ESA_CURRENT_LINE; do
          if _esa_has_standing_line "$ESA_CURRENT_LINE"; then
            if [[ "$ESA_OLD" == "$ESA_CURRENT_LINE" ]] \
               && ! _esa_has_standing_line "$ESA_TEXT"; then
              ESA_REMOVES_LINE="yes"
            elif [[ -n "$ESA_OLD" && "$ESA_CURRENT_LINE" == *"$ESA_OLD"* ]]; then
              ESA_TOUCHES_STANDING="yes"
            fi
          fi
        done <<< "$ESA_CURRENT"
        if _esa_has_standing_line "$ESA_CURRENT" \
           && [[ "$ESA_REMOVES_LINE" != "yes" ]] \
           && [[ "$ESA_TOUCHES_STANDING" == "yes" ]]; then
          _esa_deny_self_grant "an Edit that modifies an existing Standing line in $ESA_PATH"
        fi
      fi
    fi
    exit 0
    ;;

  Bash)
    # `command` must be readable text. Fail CLOSED if it is not.
    if ! ESA_CMD=$(jq -er '
      if (.tool_input.command | type) == "string" then .tool_input.command
      else error("command is not text") end
    ' <<< "$HOOK_DATA" 2>/dev/null); then
      emit_deny "BLOCKED: this Bash payload's command is not readable text (enforce-standing-auth).

The command cannot be inspected, so this hook cannot rule out a write of a \`- Standing:\` line into ~/.claude/memory.md. The gate fails closed.

Re-issue the call with a plain-string command."
    fi

    # A read-only memory.md command is the one legitimate Bash shape. Every
    # other Bash command naming the file is denied, whether it contains a
    # literal Standing token or assembles one dynamically.
    if ! grep -qiF 'memory.md' <<< "$ESA_CMD"; then
      exit 0
    fi
    if _esa_read_only_bash "$ESA_CMD"; then
      exit 0
    fi

    _esa_deny_self_grant "a write-capable Bash command naming memory.md" "

IF YOU ARE EDITING DOCUMENTATION that merely QUOTES a memory.md path — this hook, rules/git-workflow.md, or a test case — use the Write or Edit tool on that file instead. A Bash command is arbitrary text in which this gate cannot tell which file a token refers to, so it takes the conservative reading. Write and Edit on the memory file itself remain separately gated."
    exit 0
    ;;

esac

exit 0
