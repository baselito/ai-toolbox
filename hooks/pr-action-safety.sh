#!/bin/bash
# pr-action-safety.sh
#
# PreToolUse hook matching on the Bash tool. Enforces "agent-managed" PR
# state changes at the tool boundary.
#
# Blocks:
#   - gh pr close — always (destructive, no legitimate autonomous use)
#   - gh pr merge — UNLESS all of:
#       * command has no shell chain operators (no `&&`, `||`, `;`, `|`)
#       * marker file `~/.claude/.pr-merge-gate-<owner>-<repo>-<N>` exists
#         at the REPO ROOT (not cwd subdirectory)
#       * live PR state RE-VERIFIED via gh at call time:
#             state == OPEN
#             mergeStateStatus in {CLEAN, UNSTABLE with zero FAILURE/ERROR/PENDING}
#             reviewDecision != CHANGES_REQUESTED
#             all non-outdated review threads isResolved == true (paginated)
#
# Why re-verify instead of trusting the marker:
#   Any Bash path in the agent session can write the marker file and then
#   run `gh pr merge`. The marker alone is forgeable. Re-verifying the
#   PR state at call time means even a forged marker on a PR with
#   unresolved threads, failing CI, or pending required approvals will
#   be rejected. The marker serves as "this agent run intended to merge"
#   (a tripwire for chain/cwd/repo attacks), and GitHub's live state is
#   the authoritative gate.
#
# Marker is single-use: consumed (rm -f) after allowing one merge call.
# Stale markers (PR state no longer meets gate) are also deleted.

set -euo pipefail

# Capture the caller's executable resolution before replacing PATH with a
# fixed toolchain path. The later gate accepts only a standard trusted path,
# never an arbitrary project shim.
CALLER_GH_PATH="$(type -P gh 2>/dev/null || true)"
CALLER_GH_FUNCTION=false
if declare -F gh >/dev/null 2>&1; then
  CALLER_GH_FUNCTION=true
fi

# All parser and filesystem helpers used below must come from fixed system
# locations. A project-controlled PATH must not be able to replace jq/grep/sed
# and turn a deny into an allow. gh itself is invoked by absolute path later.
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/snap/bin"
export PATH

# Fail CLOSED when jq is missing — see enforce-auto-poll.sh comment. This
# hook is the only gate between `gh pr merge` and a live merge, so silent
# disarm on missing jq would mean any `gh pr merge` call succeeds without
# state verification.
if ! command -v jq &>/dev/null; then
  cat <<'__DENY__'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: jq is required for hook enforcement (pr-action-safety). Install jq (brew install jq / apt install jq / yum install jq) to continue. Hook fails closed for safety."}}
__DENY__
  exit 0
fi
resolve_gh() {
  local candidate
  # Prefer the executable the caller would actually run when it is one of the
  # fixed trusted locations. This avoids rejecting a valid install merely
  # because another trusted gh exists earlier in the hard-coded list.
  for candidate in \
    "${HOME:-}/.local/bin/gh" \
    "/opt/homebrew/bin/gh" \
    "/usr/local/bin/gh" \
    "/usr/bin/gh" \
    "/snap/bin/gh"; do
    if [[ -n "$CALLER_GH_PATH" && "$CALLER_GH_PATH" == "$candidate" \
       && -x "$candidate" && ! -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  # Claude hook subprocesses may not inherit the interactive shell's PATH.
  # Only fixed, standard installation locations are accepted. Deliberately do
  # not fall back to command -v or an environment-selected HOME-local path: a
  # caller can provide either one as a shim that forges the live state used by
  # this merge gate. Claude/Codex installations should use one of the fixed
  # native locations below when the hook subprocess PATH is sanitized.
  for candidate in \
    "/opt/homebrew/bin/gh" \
    "/usr/local/bin/gh" \
    "/usr/bin/gh" \
    "/snap/bin/gh"; do
    if [[ -x "$candidate" && ! -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

is_fixed_gh_path() {
  case "$1" in
    /opt/homebrew/bin/gh|/usr/local/bin/gh|/usr/bin/gh|/snap/bin/gh)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

HOOK_DATA=$(cat)
TOOL_NAME=$(echo "$HOOK_DATA" | jq -r '.tool_name // empty')
if [[ "$TOOL_NAME" != "Bash" ]]; then
  exit 0
fi

COMMAND=$(echo "$HOOK_DATA" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
CWD=$(echo "$HOOK_DATA" | jq -r '.cwd // "."' 2>/dev/null || echo ".")

# A Codex/Claude tool runner may know the fixed native executable while its
# hook subprocess does not inherit the same PATH. Keep an explicitly
# path-qualified invocation usable in that case, but recognize only the same
# fixed native locations as resolve_gh — never an arbitrary project path.
COMMAND_GH_BIN=""
case "$COMMAND" in
  /opt/homebrew/bin/gh[[:space:]]*) COMMAND_GH_BIN="/opt/homebrew/bin/gh" ;;
  /usr/local/bin/gh[[:space:]]*) COMMAND_GH_BIN="/usr/local/bin/gh" ;;
  /usr/bin/gh[[:space:]]*) COMMAND_GH_BIN="/usr/bin/gh" ;;
  /snap/bin/gh[[:space:]]*) COMMAND_GH_BIN="/snap/bin/gh" ;;
esac
# Capture how the sanctioned command itself would resolve `gh` BEFORE changing
# this hook's PATH. The hook's absolute verifier must be the same executable
# that the following Bash tool call will run; otherwise a PATH shim or exported
# shell function could receive the merge after this hook approves it.
GH_BIN="$(resolve_gh || true)"
if [[ -z "$GH_BIN" && -n "$COMMAND_GH_BIN" ]] \
   && is_fixed_gh_path "$COMMAND_GH_BIN"; then
  # The tool runner may execute this hook in a sandbox that cannot stat the
  # host's native CLI path even though the following Bash tool can execute it.
  # The command path is still restricted to the fixed native allowlist above;
  # assigning it here lets the live state query itself be the availability
  # check, and any failed query remains fail-closed below.
  GH_BIN="$COMMAND_GH_BIN"
fi
GH_EXECUTION_MATCH=false
if [[ -n "$COMMAND_GH_BIN" && "$COMMAND_GH_BIN" == "$GH_BIN" \
   && "$CALLER_GH_FUNCTION" != "true" ]]; then
  GH_EXECUTION_MATCH=true
elif [[ -n "$GH_BIN" && "$CALLER_GH_PATH" == "$GH_BIN" && "$CALLER_GH_FUNCTION" != "true" ]]; then
  GH_EXECUTION_MATCH=true
elif [[ -z "$COMMAND_GH_BIN" && -z "$CALLER_GH_PATH" \
   && -n "$GH_BIN" && "$CALLER_GH_FUNCTION" != "true" ]]; then
  # Claude/Codex hook subprocesses can receive a sanitized PATH even when the
  # Bash tool that follows runs in an interactive environment where `gh` is
  # available. With no caller resolution to compare, accept only a fixed
  # native path selected by resolve_gh; HOME-derived or PATH-resolved shims are
  # never candidates in this branch.
  GH_EXECUTION_MATCH=true
fi
# Keep the existing command sites simple while ensuring every gh invocation in
# this gate resolves to the same trusted binary that was checked above.
if [[ -n "$GH_BIN" ]]; then
  PATH="$(dirname "$GH_BIN"):$PATH"
  export PATH
fi

# -----------------------------------------------------------------------------
# HEREDOC SUB-LAYER REMOVED (PR #128): earlier revisions built a
# heredoc-body-stripped COMMAND_STRIPPED (a `_hd_*` state machine distinguishing
# "executable" vs "content" heredocs + a live command-substitution span
# extractor) and fed NORM_COMMAND from it. That sub-layer kept producing
# both-direction parser bugs — a real `gh pr merge`/`close` hidden in a heredoc
# body escaped detection (under-block) while inert commit-message prose
# false-blocked (over-block). It is gone: NORM_COMMAND is built directly from
# the raw $COMMAND, so a `gh pr merge`/`close` at command position INSIDE a
# heredoc body is seen and BLOCKS (an over-block — the SAFE direction). ACCEPTED
# RESIDUAL: a DATA/commit-message heredoc that merely mentions the phrase now
# false-blocks; re-word it. The live PR-state re-verification below is the
# authoritative gate regardless.
# -----------------------------------------------------------------------------
# NORM_COMMAND — the raw command with shell quoting punctuation removed so
# detection, the flag check, and PR/repo extraction see something close to the
# form Bash actually executes. We delete the quoting CHARACTERS `$`, `"`, `'`,
# `\`, which collapses `"gh" pr merge`, `gh pr "merge"`, `gh pr $'merge'`,
# `\--body`, `$'--admin'` to their executed token form.
#
# Why this is sound (and why it is the OPPOSITE of the reverted strip):
#   * The reverted attempt removed quoted *regions* (content between quotes).
#     That hid real commands — `echo "$(gh pr merge ...)"` lost its payload —
#     producing unsafe false NEGATIVES.
#   * This removes only delimiter CHARACTERS, keeping all content. Deleting
#     characters can only bring tokens CLOSER together, never split a joined
#     phrase, so it can only ADD matches (safe over-blocks), never remove a real
#     `gh pr merge|close` from view. (A single portable `sed` — the GNU
#     `:a;N;$!ba` slurp idiom is NOT used; BSD/macOS sed discards input on `N`
#     at EOF, which silently emptied NORM_COMMAND and disarmed the hook.)
#
# Residual, ACCEPTED, OUT-OF-SCOPE — a command that hides the action from any
# literal-text match: backslash-NEWLINE line continuations (`gh pr mer\<NL>ge`),
# variable indirection, `eval`, base64-decode-pipe-sh, `${x}` parameter
# expansion. No string transform in a hook can catch these — it is an unwinnable
# arms race. They are backstopped by (a) the live PR-state re-verification below
# and (b) GitHub branch protection. This hook is a tripwire for honest mistakes
# and realistic prompt-injection (`gh pr merge N`, which IS caught), not a
# complete shell sandbox.
#
# Backtick and `$(` are deliberately preserved for the RAW-command guards in
# the combined-form path below (NORM is only for detection/extraction).
# -----------------------------------------------------------------------------
NORM_COMMAND=$(printf '%s' "$COMMAND" | sed "s/[\$\"'\\\\]//g")

# -----------------------------------------------------------------------------
# Detection principle, UPDATED (Task 2, security/bash-guard-command-position):
# this hook still does NOT try to strip QUOTES first (only quote CHARACTERS are
# deleted, never quoted regions — see NORM_COMMAND above) and it still does NOT
# anchor detection to a command position the way push-safety.sh's GIT_CMDPOS
# does. Both of those remain deliberate: shell quoting/position is syntax, not
# inert text, and a regex stripper cannot reliably tell a real `gh pr merge`
# from a mention of the phrase without a real shell parser. `"gh" pr merge`,
# `gh pr "merge"`, `echo "$(gh pr merge ...)"` all execute a real action and
# must stay detected — command-position anchoring here would let `FOO=bar gh
# pr merge`-shaped prefixes or a non-adjacent `gh` slip past the SAME way a
# naive push-safety anchor would have (see push-safety.sh's GIT_CMDPOS comment)
# — NOT worth the risk for a gate this narrow in scope (merge/close only).
#
# What DID change: ONE narrow, PROVABLE loosening runs in front of this
# still-unchanged substring detection, closing a concrete false positive found
# in production (see discovery notes) without touching the one-directional
# safety trade-off described below:
#   - The SEARCH-TOOL MENTION EXEMPTION immediately below — a
#     grep/egrep/fgrep/rg invocation whose PATTERN argument mentions
#     "gh pr merge"/"gh pr close" is inspecting text, not executing an
#     action; TWO guard conditions (no embedded newline/CR/VT/FF, no
#     `$(`/backtick/`<(`) plus a per-segment "every mention must be
#     search-tool-led" check keep this narrow and provably safe (see its own
#     comment block for the full reasoning). `sed` is deliberately EXCLUDED
#     from this allowlist (security-engineer, Task 2 round 2): GNU sed's `e`
#     command and `s///e` flag EXECUTE the pattern space as a shell command,
#     so `sed 's/.*/gh pr merge 5/e' f` is not "inspecting text" at all — it
#     RUNS a real merge while looking exactly like a read-only search-tool
#     mention. grep/egrep/fgrep/rg have no such execute primitive, so they
#     stay in the allowlist.
#
# (The heredoc-body strip that used to run here too was REMOVED in PR #128 —
# see the HEREDOC SUB-LAYER REMOVED note at NORM_COMMAND above. Detection now
# runs on the raw command, so a `gh pr merge`/`close` at command position in a
# heredoc body BLOCKS rather than being stripped from view.)
#
# Everything else keeps the EXACT SAME one-directional trade-off as before:
# this gate may still over-block a command that only mentions the phrase as
# text through some OTHER vector (e.g. `echo "gh pr merge"`, a git-commit -m
# PROSE argument, or now any heredoc body that mentions the phrase) — that
# remains an acceptable, safe cost (R7: the agent reworks the wording). It will
# NEVER let a real merge/close past without the marker + live verification.
# Safety beats convenience here.
# -----------------------------------------------------------------------------

# gh launcher option-run — a global gh option run between `gh` and `pr`
# (`gh -R owner/repo pr merge`, `gh --repo owner/repo pr close`,
# `gh --repo=owner/repo pr merge`). The detectors below originally required
# `gh pr` ADJACENCY, so any global flag before `pr` skipped the entire gate —
# the only technical control that stops the agent from autonomously merging a
# project repo or closing a PR. Consuming the run keeps the gate intact. The
# `-R`/`--repo` branch matches an option that takes a SEPARATE-word value; the
# general `--?flag` branch matches any other flag, incl. the `--repo=x` equals
# form and the `-Rx` bundled form (single token, no inner space). Broadening
# only ADDS matches: it never lets a previously-gated command through, and a
# non-merge/non-close `gh pr` command still falls to the final `exit 0`.
GH_OPT_RUN='((-R|--repo)[[:space:]]+[^[:space:]]+[[:space:]]+|--?[^[:space:]]+[[:space:]]+)*'

# Only care about `gh pr` commands (matched on the quote-normalized command).
# All detectors below match with here-strings (`<<<`), never `echo | grep`:
# under `set -euo pipefail` the pipe form can SIGPIPE (141) on large multiline
# input and flip a deny to an allow (static guard: TC-PAS-25).
if ! grep -qE "\bgh[[:space:]]+${GH_OPT_RUN}pr\b" <<< "$NORM_COMMAND"; then
  exit 0
fi

# -----------------------------------------------------------------------------
# SEARCH-TOOL MENTION EXEMPTION (Task 2, security/bash-guard-command-position).
#
# NORM_COMMAND only deletes quote CHARACTERS ($, ", ', \) — it never strips
# heredoc bodies (handled above) or neutralises interior text the way
# push-safety's _neutralize_quoted does — so a QUOTED "gh pr merge"/"gh pr
# close" mention inside a grep/egrep/fgrep/rg PATTERN argument survives as
# a literal substring and false-triggers CHECK 1/2 below (TC-PAS-31/32: a
# read-only `grep -n "gh pr merge" log` was blocked in production this way).
#
# This is a NARROW, PROVABLE loosening, not a general anchoring change (see the
# detection-principle comment above for why command-position anchoring is NOT
# used here). It exempts a command ONLY when:
#   (a) $COMMAND (the RAW command, checked BEFORE any stripping) has no
#       embedded LF/CR/VT/FF — a real newline could smuggle a second,
#       un-mentioned `gh pr merge`/`close` invocation past a single-segment
#       scan (mirrors push-safety's PR #125 round-3 newline guard; TC-PAS-39).
#   (b) $COMMAND has no `$(`, backtick, `<(`, or `>(` — command/process
#       substitution (INPUT `<(...)` or OUTPUT `>(...)`) can execute a real gh
#       action while the OUTER text merely "mentions" the phrase as a grep
#       argument; never exempt when present (TC-PAS-38, TC-PAS-40). `>(...)`
#       (automated-review finding, PR #128) is just as live as `<(...)`: `grep "gh pr
#       merge" log > >(gh pr merge 5 --admin)` satisfies every OTHER guard
#       here (no newline, no `$(`/backtick, every MENTION segment is
#       grep-led) while the real merge runs inside the output process
#       substitution — the missing `>(` check let this exact shape through.
#   (c) EVERY segment of NORM_COMMAND (split on `;`, `&`, `|` — the same
#       characters CHECK 2's own chain-rejection matches on) that mentions
#       "gh pr merge"/"gh pr close" is LED by one of the four read-only search
#       tools (grep/egrep/fgrep/rg) at the start of that segment. A grep
#       mention chained with a REAL, non-search-tool-led merge/close
#       (`grep 'gh pr merge' f && gh pr merge 5 ...`) has ONE mention segment
#       that fails this test, so the WHOLE command is NOT exempted and falls
#       through to the unchanged detection below (TC-PAS-37).
# `sed` is deliberately NOT in this allowlist (security-engineer, Task 2
# round 2, TC-PAS-33 flip): GNU sed's `e` command and `s///e` flag EXECUTE the
# pattern space as a shell command, so a `sed` invocation "mentioning" the
# phrase can be a REAL merge in disguise (`sed 's/.*/gh pr merge 5/e' f`) —
# unlike grep/egrep/fgrep/rg, which have no execute primitive and can only
# ever be inspecting text. `echo`/`git commit -m`/any other non-search-tool
# mention is likewise explicitly NOT in the allowlist and stays over-blocked
# — same R7 asymmetry as before (TC-PAS-36, TC-PAS-11/12 unaffected).
#
# A command with NO mention of the phrase at all falls through unexempted too
# (mention_found stays false) — this block only ever EXEMPTS, it never blocks
# on its own; the unchanged CHECK 1/2 below remain the sole source of denies.
#
# ⛔ The `done < <(printf … | tr …)` PROCESS SUBSTITUTION is LOAD-BEARING —
# see push-safety.sh's identical warning: the piped form runs the loop in a
# SUBSHELL, so a flag set inside would silently vanish and defeat guard (c).
#
# The segment scan below tracks the shell's simple quote/escape state so a
# separator inside a quoted grep pattern is not mistaken for a pipeline. This
# is intentionally only used to decide whether a command is a read-only search
# mention; the main detector remains conservative and still scans NORM_COMMAND.
if [[ "$COMMAND" != *$'\n'* && "$COMMAND" != *$'\r'* && "$COMMAND" != *$'\v'* && "$COMMAND" != *$'\f'* ]] \
   && [[ "$COMMAND" != *'$('* ]] \
   && [[ "$COMMAND" != *'<('* ]] \
   && [[ "$COMMAND" != *'>('* ]] \
   && ! grep -q '`' <<< "$COMMAND"; then
  _pas_mention_found=false
  _pas_all_search_led=true
  _pas_segments=()
  _pas_seg=""
  _pas_quote=""
  _pas_escape=false
  _pas_i=0
  while (( _pas_i < ${#COMMAND} )); do
    _pas_char="${COMMAND:_pas_i:1}"
    if [[ "$_pas_escape" == "true" ]]; then
      _pas_seg+="$_pas_char"
      _pas_escape=false
    elif [[ -n "$_pas_quote" ]]; then
      _pas_seg+="$_pas_char"
      if [[ "$_pas_quote" == "'" && "$_pas_char" == "'" ]] || \
         [[ "$_pas_quote" == '"' && "$_pas_char" == '"' ]]; then
        _pas_quote=""
      elif [[ "$_pas_quote" == '"' && "$_pas_char" == "\\" ]]; then
        _pas_escape=true
      fi
    else
      if [[ "$_pas_char" == "'" || "$_pas_char" == '"' ]]; then
        _pas_quote="$_pas_char"
        _pas_seg+="$_pas_char"
      elif [[ "$_pas_char" == "\\" ]]; then
        _pas_escape=true
        _pas_seg+="$_pas_char"
      elif [[ "$_pas_char" == ';' || "$_pas_char" == '&' || "$_pas_char" == '|' ]]; then
        _pas_segments+=("$_pas_seg")
        _pas_seg=""
      else
        _pas_seg+="$_pas_char"
      fi
    fi
    ((_pas_i += 1))
  done
  _pas_segments+=("$_pas_seg")
  for _pas_raw_seg in "${_pas_segments[@]}"; do
    _pas_norm_seg=$(printf '%s' "$_pas_raw_seg" | sed "s/[\$\"'\\\\]//g")
    if grep -qE "\bgh[[:space:]]+${GH_OPT_RUN}pr[[:space:]]+(merge|close)\b" <<< "$_pas_norm_seg"; then
      _pas_mention_found=true
      if ! grep -qE '^[[:space:]]*(grep|egrep|fgrep|rg)([[:space:]]|$)' <<< "$_pas_norm_seg"; then
        _pas_all_search_led=false
      fi
    fi
  done
  if [[ "$_pas_mention_found" == "true" && "$_pas_all_search_led" == "true" ]]; then
    exit 0
  fi
fi

# -----------------------------------------------------------------------------
# CHECK 1 (FIRST) — `gh pr close` is ALWAYS blocked, even if the command
# also contains an otherwise-allowed `gh pr merge`. This prevents
# `gh pr merge 123 && gh pr close 999` from slipping past because the
# merge branch exited early.
# -----------------------------------------------------------------------------
if grep -qE "\bgh[[:space:]]+${GH_OPT_RUN}pr[[:space:]]+close\b" <<< "$NORM_COMMAND"; then
  jq -n '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": "BLOCKED: gh pr close is a human-only action. Closing a PR discards work without merging; the agent has no legitimate reason to do this autonomously. If a PR should be closed, ask the user to close it manually."
    }
  }'
  exit 0
fi

# -----------------------------------------------------------------------------
# CHECK 2 — `gh pr merge` with a strict gate
# -----------------------------------------------------------------------------
if grep -qE "\bgh[[:space:]]+${GH_OPT_RUN}pr[[:space:]]+merge\b" <<< "$NORM_COMMAND"; then
  FIXED_GH_DIRECT=false
  case "$NORM_COMMAND" in
    /opt/homebrew/bin/gh[[:space:]]*) FIXED_GH_DIRECT=true ;;
    /usr/local/bin/gh[[:space:]]*) FIXED_GH_DIRECT=true ;;
    /usr/bin/gh[[:space:]]*) FIXED_GH_DIRECT=true ;;
    /snap/bin/gh[[:space:]]*) FIXED_GH_DIRECT=true ;;
  esac
  # Only a direct `gh` command is eligible. Path-qualified executables and
  # wrappers (command/env/exec) can invoke a different binary after the hook
  # verifies the ambient `gh`; the combined marker form is the sole exception
  # and is validated by its exact shape below.
  if ! [[ "$NORM_COMMAND" =~ ^[[:space:]]*gh[[:space:]] ]] \
    && [[ "$FIXED_GH_DIRECT" != "true" ]] \
    && ! grep -qE '^touch[[:space:]]+(~|\$HOME)/\.claude/\.pr-merge-gate-[^[:space:]]+[[:space:]]+&&[[:space:]]+gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+[0-9]+' <<< "$COMMAND"; then
    jq -n '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "BLOCKED: merge must invoke the trusted gh executable directly. Path-qualified gh binaries and command/env/exec wrappers are not accepted by the merge gate."
      }
    }'
    exit 0
  fi
  if [[ "$COMMAND" == *$'\n'* || "$COMMAND" == *$'\r'* ]]; then
    jq -n '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "BLOCKED: merge commands may contain exactly one single-line gh invocation; newline-separated commands are rejected."
      }
    }'
    exit 0
  fi
  if [[ "$GH_EXECUTION_MATCH" != "true" ]]; then
    jq -n --arg path "$CALLER_GH_PATH" --arg trusted "$GH_BIN" '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": ("BLOCKED: the gh executable that would run the merge does not match the trusted verifier (caller=" + $path + ", trusted=" + $trusted + "). Refusing to approve a merge through a PATH shim or shell function; use the standard trusted gh installation path.")
      }
    }'
    exit 0
  fi
  # A simple command can override PATH immediately before invoking gh, after
  # this hook has captured the caller's original resolution. Reject assignment
  # prefixes and env launchers so the verified absolute binary is also the one
  # the sanctioned Bash command will execute.
  # Check both the quote-normalized form and the raw command. NORM_COMMAND
  # removes quote delimiters, so PATH="/tmp x" becomes PATH=/tmp x and the
  # value's whitespace can evade the normalized assignment regex. The raw
  # form catches quoted values before the hook returns to Bash.
  if grep -qE '(^|[[:space:];|&])env[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=|(^|[[:space:];|&])[A-Za-z_][A-Za-z0-9_]*=[^[:space:];|&]*[[:space:]]+gh[[:space:]]' <<< "$NORM_COMMAND" \
    || grep -qE '(^|[[:space:];|&])env[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=|(^|[[:space:];|&])[A-Za-z_][A-Za-z0-9_]*=[^;|&]*[[:space:]]+gh[[:space:]]' <<< "$COMMAND" \
    || grep -qE '(^|[[:space:];|&])[[:space:]]*(export[[:space:]]+)?PATH[[:space:]]*=' <<< "$COMMAND"; then
    jq -n '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "BLOCKED: environment assignments and env launchers before gh are not allowed for a merge. They can replace the executable after the hook verifies it; use the standard sanctioned merge command with no env prefix."
      }
    }'
    exit 0
  fi
  # Track whether this is the approved combined-form (touch && gh pr merge).
  # In that form the marker file does not exist yet (the touch will create it
  # after the hook exits 0), so marker presence cannot be used as evidence.
  # The shape regex below only confirms the command is well-formed; the live
  # state verification at the bottom of CHECK 2 is what actually authorises
  # the merge. Both paths converge on the same live-verification block.
  # ---------------------------------------------------------------------------
  # Flag allowlist — `gh pr merge` may carry ONLY a known-safe set of flags.
  # Default-deny: any other flag token rejects the command (Codex review, PR1).
  #   * `--admin`/`-A` bypasses branch protection — never allowed autonomously
  #     (closes the doc/behaviour gap where /merge-pr claimed --admin was
  #     rejected but the hook had no such check).
  #   * `--body`/`-b`/`--body-file`/`-F`/`--subject`/`-t` carry arbitrary text
  #     and can smuggle a second `--repo` token, binding the gate's live-check
  #     to a DIFFERENT repo than gh actually merges. Rejecting them removes that
  #     repo/PR-confusion vector.
  # The `--repo`/`-R` *value* (owner/name) has no leading dash, so it is not a
  # flag token and is never matched here. Short flags map (per `gh pr merge`):
  # -s squash, -m merge, -r rebase, -d delete-branch, -R repo (all allowed);
  # -t subject, -b body, -F body-file, -A admin (all rejected).
  # Allowlisted flag tokens (matched on NORM_COMMAND so quoted/escaped flags
  # like "--admin" or \--body are normalized to bare and still caught):
  #   --squash/-s, --merge/-m, --rebase/-r, --delete-branch/-d, --repo/-R,
  #   --auto, --disable-auto, --match-head-commit <sha>, plus bundled short booleans `-[smrd]+` (e.g. -sd
  #   = -s -d, a legitimate gh shorthand). A bundle that includes a
  #   value-carrying short flag (e.g. -sdb -> contains -b/body) fails the
  #   `^-[smrd]+$` test and is rejected — exactly what we want.
  # Everything else is rejected by default:
  #   * --admin bypasses branch protection.
  #   * --body/-b, --body-file/-F, --subject/-t, --author-email/-A,
  #     --match-head-commit carry arbitrary text. A text value can contain a
  #     fake `--repo o/r`; since we extract the repo by scanning the command,
  #     a permitted text flag would let the gate verify a DIFFERENT repo than
  #     gh actually merges. Banning value-carrying flags closes that vector at
  #     the source (Codex review, PR1 rounds 1-2).
  DISALLOWED_FLAG=$(grep -oE '(^|[[:space:]])-{1,2}[A-Za-z][A-Za-z-]*' <<< "$NORM_COMMAND" \
    | sed -E 's/^[[:space:]]+//' \
    | grep -vxE -- '--squash|--merge|--rebase|--delete-branch|--repo|--auto|--disable-auto|--match-head-commit|-R|-[smrd]+' \
    | head -1 || true)
  if [[ -n "$DISALLOWED_FLAG" ]]; then
    jq -n --arg f "$DISALLOWED_FLAG" '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": ("BLOCKED: gh pr merge may only use --squash/--merge/--rebase, --delete-branch, --repo, --auto/--disable-auto, --match-head-commit (and bundled short booleans like -sd). Disallowed flag: " + $f + ". Flags that bypass branch protection (--admin) or carry arbitrary text (--body/--subject/--body-file/--author-email) are refused — text values can smuggle a second --repo and bind the safety check to the wrong repo.\n\nNOT actually running a merge? Heredoc bodies are scanned on purpose, so a heredoc that merely MENTIONS this phrase in prose or documentation trips the same check (a deliberate accepted residual — see the header comments in pr-action-safety.sh). Workaround: create the file with a NON-Bash write path (the Write tool), then run it. Writing it via a Bash heredoc does NOT help - that command carries the same phrase in its own body and is scanned before it can run.")
      }
    }'
    exit 0
  fi

  COMBINED_FORM=false

  # Combined pattern: touch ~/.claude/.pr-merge-gate-<owner>-<repo>-<N> && gh pr merge <N> --repo <owner>/<repo> ...
  # Mirrors push-safety's combined-command support for when the stage 2 classifier
  # blocks standalone `touch ~/.claude/.pr-merge-gate-*`. The marker name in the
  # touch must encode the same (owner, repo, PR#) as the gh pr merge command — this
  # prevents a forged marker from authorising a different PR. Single-line guard
  # prevents multiline smuggling.
  #
  # Trailing-args restriction: the regex's `[^;&|`$]*` AND the explicit guards
  # `[[ "$COMMAND" != *'$('* ]]` and the backtick grep block command substitution
  # so an attacker cannot smuggle a second action via `--body "$(curl evil)"` or
  # backtick subshells. Newlines, &, &&, ||, ;, | are also rejected.
  if [[ "$COMMAND" != *$'\n'* ]] \
     && [[ "$COMMAND" != *'$('* ]] \
     && ! grep -q '`' <<< "$COMMAND" \
     && grep -qE '^touch[[:space:]]+(~|\$HOME)/\.claude/\.pr-merge-gate-[^[:space:]]+[[:space:]]+&&[[:space:]]+gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+[0-9]+([[:space:]][^;&|`$]*)?$' <<< "$COMMAND"; then
    # Each grep is wrapped with `|| true` because the outer regex on line 104
    # accepts combined-form commands that may legitimately omit --repo (relying
    # on cwd resolution). Under `set -euo pipefail`, a no-match grep otherwise
    # terminates the script with exit 1 instead of falling through to the
    # standalone-form deny path below.
    MARKER_SUFFIX=$(grep -oE '\.pr-merge-gate-[^[:space:]]+' <<< "$NORM_COMMAND" | head -1 | sed 's/^\.pr-merge-gate-//' || true)
    PR_NUM_C=$(grep -oE 'merge[[:space:]]+[0-9]+' <<< "$NORM_COMMAND" | grep -oE '[0-9]+$' | head -1 || true)
    # Repo from --repo OR -R (both allowlisted). Reject if multiple DISTINCT
    # values are present — an ambiguous repo could bind the live-check to a
    # different repo than gh resolves (Codex P1: `-R` and duplicate `--repo`).
    REPO_VALUES_C=$(grep -oE -- '(--repo|-R)[[:space:]=]+[^[:space:]]+' <<< "$NORM_COMMAND" | sed -E 's/^(--repo|-R)[[:space:]=]+//' | sort -u || true)
    if [[ "$(grep -c . <<< "$REPO_VALUES_C" || true)" -gt 1 ]]; then
      jq -n '{
        "hookSpecificOutput": {
          "hookEventName": "PreToolUse",
          "permissionDecision": "deny",
          "permissionDecisionReason": "BLOCKED: gh pr merge has multiple, conflicting --repo/-R values. Specify exactly one repo so the safety check verifies the same repo gh merges."
        }
      }'
      exit 0
    fi
    REPO_C="$REPO_VALUES_C"
    # If no repo flag, resolve from cwd. The combined-form regex intentionally
    # accepts commands that rely on cwd resolution (e.g. `touch ... && gh pr
    # merge 123` with no --repo) — a regression caught by automated-review.
    if [[ -z "$REPO_C" ]]; then
      REPO_C=""
      if [[ -n "$GH_BIN" ]]; then
        REPO_C=$(cd "$CWD" 2>/dev/null && "$GH_BIN" repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
      fi
    fi
    if [[ -n "$PR_NUM_C" && -n "$REPO_C" && "$REPO_C" == */* ]]; then
      OWNER_C="${REPO_C%/*}"
      REPO_NAME_C="${REPO_C#*/}"
      EXPECTED_SUFFIX="${OWNER_C}-${REPO_NAME_C}-${PR_NUM_C}"
      if [[ "$MARKER_SUFFIX" == "$EXPECTED_SUFFIX" ]]; then
        # Shape OK and marker name matches the gh pr merge target. Fall
        # through to live verification with PR_NUM/OWNER/REPO_NAME set from
        # the combined form. DO NOT exit 0 here — the shape regex alone is
        # not safety; live PR state (CI, threads, review decision) must still
        # be verified before the merge is allowed.
        COMBINED_FORM=true
        PR_NUM="$PR_NUM_C"
        REPO_SPEC="${OWNER_C}/${REPO_NAME_C}"
        OWNER="$OWNER_C"
        REPO_NAME="$REPO_NAME_C"
      fi
    fi
  fi

  # Reject chained commands UNLESS this is the approved combined form (which
  # has already passed its own strict shape validation above).
  if [[ "$COMBINED_FORM" != "true" ]] && grep -qE '(&&|\|\||;|\||&)' <<< "$NORM_COMMAND"; then
    jq -n '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "BLOCKED: gh pr merge must be issued as a standalone command with no shell chain operators (no && || ; | &), OR as the approved combined form `touch ~/.claude/.pr-merge-gate-<owner>-<repo>-<N> && gh pr merge <N> --repo <owner>/<repo> ...`."
      }
    }'
    exit 0
  fi

  # Extract PR_NUM and REPO_SPEC for the standalone form. The combined form
  # already populated PR_NUM/OWNER/REPO_NAME above.
  if [[ "$COMBINED_FORM" != "true" ]]; then
    # Extract PR number from the command. Accept `gh pr merge <N>` — require
    # an explicit integer. Implicit current-branch merge is disallowed so
    # the marker lookup always has a definite PR number.
    PR_NUM=$(grep -oE 'merge[[:space:]]+[0-9]+' <<< "$NORM_COMMAND" \
      | grep -oE '[0-9]+$' \
      | head -1 || true)
    if [[ -z "$PR_NUM" ]]; then
      jq -n '{
        "hookSpecificOutput": {
          "hookEventName": "PreToolUse",
          "permissionDecision": "deny",
          "permissionDecisionReason": "BLOCKED: gh pr merge requires an explicit PR number (e.g., gh pr merge 42 --squash --delete-branch). The marker-file gate needs a definite PR number to look up."
        }
      }'
      exit 0
    fi

    # Extract repo from --repo OR -R if present; else resolve from current repo.
    # The repo binds the marker to a specific (owner, repo, PR) triple so an
    # approval for repo A cannot authorise a merge on repo B. Reject multiple
    # DISTINCT values (Codex P1: -R / duplicate --repo divergence).
    REPO_VALUES=$(grep -oE -- '(--repo|-R)[[:space:]=]+[^[:space:]]+' <<< "$NORM_COMMAND" | sed -E 's/^(--repo|-R)[[:space:]=]+//' | sort -u || true)
    if [[ "$(grep -c . <<< "$REPO_VALUES" || true)" -gt 1 ]]; then
      jq -n '{
        "hookSpecificOutput": {
          "hookEventName": "PreToolUse",
          "permissionDecision": "deny",
          "permissionDecisionReason": "BLOCKED: gh pr merge has multiple, conflicting --repo/-R values. Specify exactly one repo so the safety check verifies the same repo gh merges."
        }
      }'
      exit 0
    fi
    REPO_SPEC="$REPO_VALUES"
    if [[ -z "$REPO_SPEC" ]]; then
      REPO_SPEC=""
      if [[ -n "$GH_BIN" ]]; then
        REPO_SPEC=$(cd "$CWD" 2>/dev/null && "$GH_BIN" repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
      fi
    fi
    if [[ -z "$REPO_SPEC" || "$REPO_SPEC" != */* ]]; then
      jq -n '{
        "hookSpecificOutput": {
          "hookEventName": "PreToolUse",
          "permissionDecision": "deny",
          "permissionDecisionReason": "BLOCKED: cannot determine repo for gh pr merge (no --repo flag and cwd is not a gh-tracked repo). Pass --repo owner/name or run from inside the repo checkout."
        }
      }'
      exit 0
    fi
    OWNER="${REPO_SPEC%/*}"
    REPO_NAME="${REPO_SPEC#*/}"
  fi

  # State directory: defaults to $HOME/.claude/ (outside any repo). Can be
  # overridden via CLAUDE_STATE_DIR for testing. Merge markers live here
  # instead of in the repo to avoid worktree/gitignore issues.
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
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "BLOCKED: neither HOME nor CLAUDE_STATE_DIR is set, so the PR-action guard cannot locate the per-PR merge-gate marker that the user-commanded /merge-pr path creates. Without it, it cannot tell a user-authorised merge from an autonomous one.\n\nA gate that cannot find its own evidence has not been satisfied, so it fails closed.\n\nThis cannot be fixed from inside a Bash tool call — every call is a fresh shell, so an `export` here does not survive to the next one. Set HOME (or CLAUDE_STATE_DIR) in the environment the agent itself runs in — the `env` block of ~/.claude/settings.json, or the container/CI environment — and start a new session."}}
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


  MARKER="$STATE_DIR/.pr-merge-gate-${OWNER}-${REPO_NAME}-${PR_NUM}"

  # Marker existence check — only for the standalone form. In the combined
  # form, the marker file is created by the `touch` that runs AFTER this hook
  # exits 0, so there is nothing on disk to check yet. The shape regex on
  # the combined form already verified the marker NAME binds to this PR/repo.
  if [[ "$COMBINED_FORM" != "true" ]] && [[ ! -f "$MARKER" ]]; then
    MARKER_DISPLAY="$MARKER"
    if [[ -n "${HOME:-}" && "$MARKER" == "$HOME"/* ]]; then
      MARKER_DISPLAY="~${MARKER#"$HOME"}"
    fi
    REASON="BLOCKED: gh pr merge ${PR_NUM} on ${OWNER}/${REPO_NAME} requires the marker file ${MARKER} OR the combined form \`touch ${MARKER_DISPLAY} && gh pr merge ${PR_NUM} --repo ${OWNER}/${REPO_NAME} ...\`. The marker is created only by the user-commanded /merge-pr path (commands/merge-pr.md Step 2)."
    jq -n --arg reason "$REASON" '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": $reason
      }
    }'
    exit 0
  fi

  # Live PR state verification — runs in BOTH paths. The marker (when it
  # exists) is only a tripwire; live state via gh is the authoritative gate.
  # The combined form has no marker on disk yet, so it relies entirely on
  # this verification — which is exactly why the verification MUST run.
  if [[ -z "$GH_BIN" ]]; then
    rm -f "$MARKER" 2>/dev/null || true
    jq -n '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "BLOCKED: gh not available for live PR state re-verification. Merge blocked for safety; marker consumed."
      }
    }'
    exit 0
  fi

  STATE_JSON=""
  if ! STATE_JSON=$("$GH_BIN" pr view "$PR_NUM" --repo "${OWNER}/${REPO_NAME}" \
    --json state,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup,headRefOid 2>/dev/null); then
    rm -f "$MARKER" 2>/dev/null || true
    REASON="BLOCKED: could not fetch PR state for ${OWNER}/${REPO_NAME}#${PR_NUM}. Marker consumed. Re-run /review-pr to re-gate."
    jq -n --arg reason "$REASON" '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": $reason
      }
    }'
    exit 0
  fi
  if [[ -z "$STATE_JSON" ]]; then
    rm -f "$MARKER" 2>/dev/null || true
    REASON="BLOCKED: could not fetch PR state for ${OWNER}/${REPO_NAME}#${PR_NUM}. Marker consumed. Re-run /review-pr to re-gate."
    jq -n --arg reason "$REASON" '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": $reason
      }
    }'
    exit 0
  fi

  if ! printf '%s' "$STATE_JSON" | jq -e 'type == "object" and has("statusCheckRollup") and (.state | type == "string") and (.mergeable | type == "string") and (.mergeStateStatus | type == "string") and (.headRefOid | type == "string" and length > 0) and ((.statusCheckRollup == null) or (.statusCheckRollup | type == "array"))' >/dev/null 2>&1; then
    rm -f "$MARKER" 2>/dev/null || true
    jq -n '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "BLOCKED: gh returned invalid PR-state JSON; merge gate fails closed."
      }
    }'
    exit 0
  fi
  LIVE_STATE=$(printf '%s' "$STATE_JSON" | jq -r .state)
  LIVE_MERGEABLE=$(printf '%s' "$STATE_JSON" | jq -r .mergeable)
  LIVE_MERGE_STATE=$(printf '%s' "$STATE_JSON" | jq -r .mergeStateStatus)
  LIVE_REVIEW_DECISION=$(printf '%s' "$STATE_JSON" | jq -r '.reviewDecision // "PENDING"')
  LIVE_HEAD=$(printf '%s' "$STATE_JSON" | jq -r .headRefOid)

  # If supplied, --match-head-commit is the GitHub-side compare-and-swap for
  # the merge. It closes the small race after this hook's read and before the
  # merge API call: GitHub refuses the operation when the PR head moved.
  MATCH_HEAD_VALUES=$(grep -oE -- '--match-head-commit[[:space:]=]+[0-9A-Fa-f]+' <<< "$NORM_COMMAND" \
    | sed -E 's/^--match-head-commit[[:space:]=]+//' | sort -u || true)
  if [[ "$(grep -c . <<< "$MATCH_HEAD_VALUES" || true)" -gt 1 ]]; then
    rm -f "$MARKER" 2>/dev/null || true
    jq -n '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: gh pr merge has multiple --match-head-commit values. Specify exactly one commit."}}'
    exit 0
  fi
  if [[ -n "$MATCH_HEAD_VALUES" && ( -z "$LIVE_HEAD" || "$MATCH_HEAD_VALUES" != "$LIVE_HEAD" ) ]]; then
    rm -f "$MARKER" 2>/dev/null || true
    jq -n --arg requested "$MATCH_HEAD_VALUES" --arg live "$LIVE_HEAD" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":("BLOCKED: --match-head-commit " + $requested + " does not match the live PR head " + $live + ". Re-run the GoalRun merge gate.")}}'
    exit 0
  fi

  # A GoalRun-issued marker binds authorization to the exact head that was
  # checked. Empty markers remain valid for the explicit user-commanded
  # touch-and-merge form; non-empty markers must be the runtime capability.
  if [[ "$COMBINED_FORM" != "true" && -s "$MARKER" ]]; then
    if [[ -z "$MATCH_HEAD_VALUES" ]]; then
      rm -f "$MARKER" 2>/dev/null || true
      jq -n '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: GoalRun merge requires --match-head-commit. Re-run the live GoalRun merge gate."}}'
      exit 0
    fi
    if ! MARKER_HEAD=$(jq -er --arg repo "${OWNER}/${REPO_NAME}" --argjson pr "$PR_NUM" \
      'select(type == "object" and .mode == "goal-run" and .repo == $repo and .pr == $pr and (.head_sha | type == "string" and length > 0)) | .head_sha' \
      "$MARKER" 2>/dev/null); then
      rm -f "$MARKER" 2>/dev/null || true
      jq -n '{
        "hookSpecificOutput": {
          "hookEventName": "PreToolUse",
          "permissionDecision": "deny",
          "permissionDecisionReason": "BLOCKED: merge capability marker is non-empty but not a valid GoalRun capability. Re-run the live GoalRun merge gate."
        }
      }'
      exit 0
    fi
    if [[ "$MARKER_HEAD" != "$LIVE_HEAD" ]]; then
      rm -f "$MARKER" 2>/dev/null || true
      jq -n --arg marker "$MARKER_HEAD" --arg live "$LIVE_HEAD" '{
        "hookSpecificOutput": {
          "hookEventName": "PreToolUse",
          "permissionDecision": "deny",
          "permissionDecisionReason": ("BLOCKED: merge capability was issued for head " + $marker + " but the PR is now at " + $live + ". Re-run the GoalRun merge gate.")
        }
      }'
      exit 0
    fi
  fi
  # Count non-passing status checks. GitHub's statusCheckRollup is a union of
  # two types: CheckRun (modern — has `.conclusion`) and StatusContext (legacy
  # commit statuses — has `.state` instead, null conclusion). Coalesce both
  # into one "effective" value so SUCCESS from either type reads as passing.
  #
  # GROUP BY (check name, workflow name) — NOT name alone (security-reviewer
  # HIGH finding): two different workflows can emit a check with the same job
  # name (e.g. "test" in workflow A and workflow B). Grouping by name alone
  # would merge their entries and let one workflow's SUCCESS mask the other's
  # FAILURE. `.workflowName // ""` keeps cross-workflow same-name checks
  # distinct. The key also includes:
  #   - `__typename` (CheckRun vs StatusContext) — a modern check run and a
  #     legacy commit status sharing a name are DIFFERENT checks and are
  #     never merged into one group (they were counted separately before
  #     this change too).
  #   - the URL ORIGIN of detailsUrl/targetUrl (scheme://host) as a partial
  #     app proxy — without it, a newer SUCCESS from app A would mask an
  #     older FAILURE from app B posting the same check name (Codex P1).
  # HONEST LIMITATION: gh's statusCheckRollup exposes NO app identity, so
  # two DIFFERENT apps posting the same-named check with the same origin
  # (both on github.com) and blank workflowName still collapse into one
  # group. This residual gap is accepted and bounded: any in-flight entry
  # still blocks the group; the CLEAN mergeStateStatus path (GitHub's own
  # synthesis, which does know app identity for required checks) remains
  # authoritative; and Step 5.4's recovery only touches automated-review*-named
  # checks. Perfect {name, app} parity requires switching the data source
  # to the REST check-runs API (exposes app.slug) — a deliberate follow-up,
  # not silently claimed here.
  #
  # A group is NON-PASSING when EITHER:
  #   (a) any entry in the group is genuinely in-flight — conclusion/state is
  #       PENDING/IN_PROGRESS/QUEUED/EXPECTED. This closes the race where a
  #       freshly QUEUED rerun (often with a null startedAt) could otherwise be
  #       shadowed by a stale completed SUCCESS entry from a prior run: a queued
  #       rerun reports state QUEUED, so it is caught here regardless of
  #       timestamp. NOTE an empty-string effective status ("" — BOTH conclusion
  #       AND state null) is deliberately NOT treated as in-flight here: GitHub
  #       leaves a SUPERSEDED check-run entry with an empty conclusion in the
  #       rollup, and counting "" as in-flight made such a stale entry block the
  #       gate forever even after a newer terminal run for the same check (PR
  #       #130: a stale `automated-review / review` "" entry pinned the toolbox gate at
  #       "1 pending" so auto-merge never fired). An empty entry is instead
  #       judged by clause (b): it blocks ONLY if it is the group's newest entry
  #       (a genuinely-unknown latest state → fail-closed), and is ignored when a
  #       strictly-newer terminal entry supersedes it.
  #   (b) OTHERWISE, any entry that shares the group's MAXIMUM timestamp key is
  #       non-passing (this includes an empty-string status when it IS the
  #       newest → blocks). The timestamp key falls back `startedAt //
  #       completedAt // createdAt` — createdAt covers legacy StatusContext
  #       entries, which have neither startedAt nor completedAt. Ties at the max
  #       timestamp resolve FAIL-CLOSED (any non-passing entry at the max blocks
  #       the group) and are order-independent — the old `max_by` silently picked
  #       whichever entry GitHub's undocumented array order put last.
  #
  # DEDUPE TO LATEST RUN PER CHECK NAME (PR #99 incident): GitHub's rollup
  # retains check-run entries from SUPERSEDED workflow runs (cancelled by a
  # concurrency group, or re-runs). PR #99 had 4 permanently-CANCELLED
  # `automated-review-approval-gate` entries left over from superseded runs sitting
  # alongside a current, strictly-newer SUCCESS entry — a naive count-all
  # approach sees the CANCELLED residue and treats the gate as forever
  # un-mergeable. That case still resolves to 0 under the logic above,
  # because the max-timestamp entry is the newer SUCCESS.
  #
  # Timestamps are compared as strings — safe because GitHub emits UTC
  # 'Z'-suffixed ISO-8601, which sorts lexicographically in time order.
  #
  # SUCCESS/SKIPPED/NEUTRAL are the only passing values. Anything else —
  # FAILURE/ERROR/TIMED_OUT/CANCELLED/STARTUP_FAILURE/PENDING/IN_PROGRESS/
  # QUEUED/EXPECTED or null/empty for in-flight work — counts as not-safe.
  # `(.statusCheckRollup // [])[]` handles a null rollup (no checks configured).
  # MERGE-GATE-DEDUPE-JQ-BEGIN (extracted verbatim by scripts/test-merge-gate-dedupe.sh — keep markers)
  LIVE_FAILING=""
  if ! LIVE_FAILING=$(printf '%s' "$STATE_JSON" \
    | jq '[ (.statusCheckRollup // [])
            | group_by([(.__typename // ""), (.name // .context // "unknown"), (.workflowName // ""),
                        ((.detailsUrl // .targetUrl // "") | split("/")[0:3] | join("/"))])[]
            | (map(select((.conclusion // .state // "") as $c
                  | $c=="PENDING" or $c=="IN_PROGRESS" or $c=="QUEUED" or $c=="EXPECTED")) | length) as $inflight
            | (max_by(.startedAt // .completedAt // .createdAt // "") | (.startedAt // .completedAt // .createdAt // "")) as $maxk
            | select(
                ($inflight > 0)
                or
                ( [ .[] | select((.startedAt // .completedAt // .createdAt // "") == $maxk)
                        | select((.conclusion // .state // "") as $c
                            | $c != "SUCCESS" and $c != "SKIPPED" and $c != "NEUTRAL") ] | length > 0 )
              ) ]
          | length'); then
    rm -f "$MARKER" 2>/dev/null || true
    jq -n '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "BLOCKED: could not validate PR status checks; merge gate fails closed."
      }
    }'
    exit 0
  fi
  # MERGE-GATE-DEDUPE-JQ-END

  MERGE_OK=false
  if [[ "$LIVE_MERGE_STATE" == "CLEAN" ]]; then
    MERGE_OK=true
  elif [[ "$LIVE_MERGE_STATE" == "UNSTABLE" && "$LIVE_FAILING" == "0" ]]; then
    MERGE_OK=true
  fi

  # Paginate reviewThreads — > 100 threads must not hide unresolved ones.
  UNRESOLVED=0
  AFTER="null"
  while true; do
    PAGE=""
    if ! PAGE=$("$GH_BIN" api graphql \
      -f query='query($cursor: String) { repository(owner: "'"$OWNER"'", name: "'"$REPO_NAME"'") { pullRequest(number: '"$PR_NUM"') { reviewThreads(first: 100, after: $cursor) { pageInfo { hasNextPage endCursor } nodes { isResolved isOutdated } } } } }' \
      -F cursor="$AFTER" 2>/dev/null); then
      UNRESOLVED=-1
      break
    fi
    if [[ -z "$PAGE" ]]; then
      UNRESOLVED=-1
      break
    fi
    if ! PAGE_U=$(printf '%s' "$PAGE" | jq -r '
      . as $root
      | ($root.errors) as $errors
      | .data as $data
      | $data.repository.pullRequest.reviewThreads as $threads
      | if (
          (($root | (has("errors") | not)) or ($errors | type == "array" and length == 0))
          and ($data | type == "object")
          and ($data.repository | type == "object")
          and ($data.repository.pullRequest | type == "object")
          and ($threads | type == "object")
          and ($threads.nodes | type == "array")
          and ($threads.pageInfo | type == "object")
          and ($threads.pageInfo.hasNextPage | type == "boolean")
          and (($threads.pageInfo.hasNextPage == false)
               or ($threads.pageInfo.endCursor | type == "string"))
          and ([ $threads.nodes[]
                 | select((.isResolved | type) != "boolean"
                         or (.isOutdated | type) != "boolean") ] | length == 0)
        ) then
          [ $threads.nodes[]
            | select(.isResolved == false and .isOutdated == false) ] | length
        else
          error("invalid review-thread GraphQL response")
        end' 2>/dev/null); then
      UNRESOLVED=-1
      break
    fi
    UNRESOLVED=$((UNRESOLVED + PAGE_U))
    HAS_NEXT=$(printf '%s' "$PAGE" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false')
    if [[ "$HAS_NEXT" != "true" ]]; then
      break
    fi
    AFTER=$(printf '%s' "$PAGE" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')
  done

  if [[ "$LIVE_STATE" == "OPEN" \
     && "$LIVE_MERGEABLE" == "MERGEABLE" \
     && "$MERGE_OK" == "true" \
     && "$LIVE_REVIEW_DECISION" != "CHANGES_REQUESTED" \
     && "$UNRESOLVED" == "0" ]]; then
    # Authoritative gate passed. Allow the merge through but do NOT delete
    # the marker yet — if the merge command fails (network error, CI not ready,
    # wrong arguments), the agent can retry within the 60-second window without
    # recreating the marker. The marker expires on its own after 60 seconds;
    # /merge-pr confirms the outcome via a separate `gh pr view` state read.
    #
    # Marker-expiry check applies ONLY to the standalone form. The combined
    # form's marker is being created BY the same compound command (the touch
    # has not yet run when this hook fires), so there is nothing on disk to
    # date-check — the shape regex already proved freshness.
    if [[ "$COMBINED_FORM" != "true" ]]; then
      # Cross-platform stat: use uname to pick the right flag. GNU=-c %Y,
      # BSD/macOS=-f %m. (The previous fallback-chain form could succeed on
      # GNU's `-f` with non-numeric output and produce garbage timestamps.)
      if [[ "$(uname)" == "Darwin" ]]; then
        marker_mtime=$(stat -f %m "$MARKER" 2>/dev/null || echo 0)
      else
        marker_mtime=$(stat -c %Y "$MARKER" 2>/dev/null || echo 0)
      fi
      MARKER_AGE=$(( $(date +%s) - marker_mtime ))
      if [[ "$MARKER_AGE" -gt 60 ]]; then
        rm -f "$MARKER" 2>/dev/null || true
        REASON="BLOCKED: merge gate marker expired (${MARKER_AGE}s > 60s). Re-run /review-pr to re-gate."
        jq -n --arg reason "$REASON" '{
          "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": $reason
          }
        }'
        exit 0
      fi
    fi
    exit 0
  fi

  # Live state doesn't match the gate — delete the (forged or stale) marker
  # and block. Reason includes the specific failing signal so the user /
  # /review-pr can diagnose.
  rm -f "$MARKER" 2>/dev/null || true
  REASON="BLOCKED: live PR state for ${OWNER}/${REPO_NAME}#${PR_NUM} does not meet merge gate. state=${LIVE_STATE} mergeable=${LIVE_MERGEABLE} mergeStateStatus=${LIVE_MERGE_STATE} failing=${LIVE_FAILING} reviewDecision=${LIVE_REVIEW_DECISION} unresolved_threads=${UNRESOLVED}. Marker consumed; re-run /review-pr to re-gate."
  jq -n --arg reason "$REASON" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": $reason
    }
  }'
  exit 0
fi

# All other `gh pr` commands allowed
exit 0
