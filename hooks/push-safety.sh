#!/bin/bash
# push-safety.sh
#
# PreToolUse hook matching on the Bash tool.
# Guards dangerous git operations on main/master without explicit user confirmation:
#   - CHECK 0   : force-push on any branch
#   - CHECK 1/2 : `git push` to main, or any push while ON main
#   - CHECK 3   : `git commit` while ON main (the "never commit to main" rule, enforced)
#
# This prevents the end-of-workflow autopilot failure where the agent pushes stale
# commits to main without checking — and the related slip where the agent forgets to
# branch and commits straight onto main (CHECK 3 catches that at commit time, not just
# at push time). Override tokens: .push-ready (push) / .commit-on-main-ok (commit).

set -euo pipefail

# Guard: ensure jq is available. Fail CLOSED — see enforce-auto-poll.sh.
# This hook is the primary defense against `git push origin main` — silent
# disarm on missing jq would allow direct pushes to main without approval.
if ! command -v jq &>/dev/null; then
  cat <<'__DENY__'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: jq is required for hook enforcement (push-safety). Install jq (brew install jq / apt install jq / yum install jq) to continue. Hook fails closed for safety."}}
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

# _neutralize_quoted <string> — emit the string with the INTERIOR of shell
# quoted spans neutralised: any separator (`;`, `&`, `|`, newline) or whitespace
# (space, tab) BETWEEN a pair of matching quotes is replaced by `_`. The quote
# chars and all other characters are preserved, so keyword/flag detection is
# unaffected.
#
# WHY: the admit filter below and the two segment loops later split on / gate by
# `;`, `&`, `|`, newline and whitespace, all of which are character-based and
# quoting-blind. Newline matters as much as `;&|`: the segment loops use `read`
# over a `tr`-processed stream and `grep`/here-strings match per line, so an
# embedded newline INSIDE a quoted value (`git -c x="A<LF>B" push origin main`)
# is one inert char to the shell but still splits the command between `git` and
# `push` — a CRITICAL bypass in its own right (automated-review PR #125 round 3).
# A literal separator INSIDE a quoted git option value (`git -c x="A&B" push`,
# or a decoy `git push --dry-run; git -c x="A&B" push origin main`) is one inert
# character to the shell, but raw `tr`/grep would cut/misread the command there —
# landing the boundary BETWEEN `git` and `push`, so neither piece matches
# `\bgit … push\b` and a REAL push is FALSELY EXEMPTED / NOT BLOCKED. This is a
# CRITICAL bypass (security-reviewer, PR #125 round 2): it defeats the dry-run
# exemption's decoy check, CHECK 2's cwd guard, AND the coarse admit filter's
# early-exit (a bare `git -c x="A&B" push` on main slipped every check because
# admit early-`exit 0`'d before CHECK 2 ran). Neutralising separators inside
# quotes makes every downstream split/match agree with the shell's own
# tokenisation. Interior whitespace is neutralised too so a quoted value with a
# space (`-c "a b"`) stays a single `[^[:space:]]+` token for GIT_OPT_RUN —
# otherwise the option-run breaks mid-value and again misses the trailing push.
#
# FIXED (automated-review round-7 finding, PR #128): the RESIDUAL this comment used to
# document — "backslash-escaped quotes (`\"`) ... not modelled ... over-neutralise
# (fail-safe)" — was wrong about the failure DIRECTION for one real shape. An
# escaped `\"` inside a double-quoted argument does NOT close the string in real
# bash (`printf "a\"; git push origin main"` is ONE inert argument end to end),
# but the un-parity-aware code above closed the quote AT the escaped `"` anyway —
# that UNDER-neutralises (exits quote mode early), leaving the rest of the
# argument as unneutralised RAW text that can satisfy GIT_CMDPOS's own boundary
# anchor (a `;` inside what should still be inert quoted prose) and cause a FALSE
# BLOCK — the opposite of "never a dropped check". `nb` (consecutive-backslash
# count, reset after every non-backslash char) gates both the close AND the open
# check on backslash PARITY: an EVEN count (0, 2, ...) means the quote char itself
# is unescaped; an ODD count means the preceding backslash escapes it, so it does
# not toggle quote state. Single quotes have NO escape mechanism in real bash, so
# their close/open stays unconditional (the `q == "'"` branch of the OR). ANSI-C
# `$'…'`/`$"…"` locale quoting and nested unmatched quotes remain accepted,
# out-of-scope residuals — this fix only closes the escaped-`\"` gap.
_neutralize_quoted() {
  local s="$1" out="" ch q="" i n=${#1} nb=0
  for (( i=0; i<n; i++ )); do
    ch="${s:i:1}"
    if [[ "$ch" == '\' ]]; then
      nb=$(( nb + 1 )); out+="$ch"; continue
    fi
    if [[ -n "$q" ]]; then
      if [[ "$ch" == "$q" ]] && { [[ "$q" == "'" ]] || (( nb % 2 == 0 )); }; then
        q=""; out+="$ch"                       # closing quote — leave state
      elif [[ "$ch" == ";" || "$ch" == "&" || "$ch" == "|" || "$ch" == " " || "$ch" == $'\t' || "$ch" == $'\n' ]]; then
        out+="_"                               # neutralise interior separator/space/newline
      else
        out+="$ch"
      fi
    elif [[ "$ch" == '"' || "$ch" == "'" ]] && (( nb % 2 == 0 )); then
      q="$ch"; out+="$ch"                      # opening quote
    else
      out+="$ch"
    fi
    nb=0
  done
  printf '%s' "$out"
}

# Quoting-neutralised view of the raw command — used by the admit filter, the
# dry-run segment loop, and (after PR #128 removed the heredoc sub-layer) by
# CHECK 0/1/2/3 directly. Neutralising quote interiors keeps GIT_OPT_RUN's
# `[^[:space:]]+` value token intact when a `-c`/`-C` value is quoted and
# contains a separator/space character. Built once from the raw $COMMAND —
# there is no separate heredoc-stripped view any more (detection runs on the
# full command, so a gated op at command position inside a heredoc body BLOCKS).
COMMAND_NEUTRALIZED=$(_neutralize_quoted "$COMMAND")

# Only care about git push (CHECK 0/1/2) and git commit (CHECK 3) commands. Coarse
# admit-filter only — admit if the command runs git and mentions push/commit anywhere
# after it (incl. global options between, e.g. `git -c x=y commit`). The precise checks
# below do the real matching, so being loose here is safe (a non-push/non-commit command
# that slips through just falls to the final `exit 0`). Prose like `echo "git commit"`
# passes this guard but is correctly ALLOWED at CHECK 3 (command-position detection).
# Matched against COMMAND_NEUTRALIZED so a quoted separator inside a git option value
# (`git -c x="A&B" push`) can't defeat the `[^;&|]` span and early-`exit 0` a real push.
# All detectors below match with here-strings (`<<<`), never `echo | grep`:
# under `set -euo pipefail` the pipe form can SIGPIPE (141) on large multiline
# input and flip a deny to an allow (static guard: TC-PS-51).
#
# Optional quote/backslash + path-prefix before `git`, and optional closing quote
# after it (Task 2, security/bash-guard-command-position, TC-PS-119): discovered
# while widening CHECK 1 to require command-position `git` — a quoted or
# path-qualified invocation like `"/usr/bin/git" push origin main` has NO
# whitespace directly after the bare word "git" (a quote character sits between
# them), so the OLD admit filter here silently `exit 0`'d before CHECK 0/1/2/3
# ever ran, regardless of how those checks were anchored. This was a PRE-EXISTING
# gap (verified present on origin/main for `"/usr/bin/git" commit` on main too —
# CHECK 3's own quote/path-aware _c3_commit_count_re/_c3_git_re were dead code for
# that shape, never reached). Broadening this admit-only regex is a purely SAFE
# direction — it only ever ADDS candidates for the precise checks below to judge;
# it cannot itself turn a real push/commit into a silent allow.
#
# UNDERSCORE-AS-WHITESPACE (automated-review finding, PR #128): this filter runs
# against COMMAND_NEUTRALIZED, whose docstring (_neutralize_quoted, above)
# replaces every interior separator/whitespace char INSIDE a quoted span with
# `_` — load-bearing for GIT_OPT_RUN's value token and the dry-run segment
# loop. A "git push" sitting inside a top-level quoted argument therefore has
# its own "git"-to-"push" space turned into `_`, so a required `[[:space:]]`
# after "git" would not match a literal space and this coarse filter would
# early-`exit 0`. Accepting `_` anywhere `[[:space:]]` is required treats the
# neutralisation marker as the whitespace it stands in for — the same "loose is
# safe here" principle: it only ever ADDS candidates, the precise checks still
# gate for real. (A gated command hidden inside a quoted argument is not a
# command-position match at the precise checks anyway — the same accepted
# residual as `echo "$(git push origin main)"`; TC-PS-152/154 lock that.)
# CAVEAT (security-review F2, PR #128): the residual is a SUPERSET of the
# top-level `echo "$(...)"` case, not an equivalence. At top level, single
# quotes genuinely suppress expansion (`echo '$(git push)'` runs nothing). But
# inside an UNQUOTED heredoc body the quote characters are literal DATA, not
# shell quoting — so `'$(git push origin main)'` on a heredoc-body line is a
# REAL executing push that this coarse filter (and GIT_CMDPOS) no longer catch.
# It stays an accepted residual (workflow-discipline gate; push-time CHECK 1/2
# still catch any real push from main), but do NOT assume single quotes are
# inert here the way they are at top level.
if ! grep -qE "[\"'\\]?([^[:space:];&|()\"'\\]*/)?git[\"']?[[:space:]_]([^;&|]*[[:space:]_])?(push|commit)" <<< "$COMMAND_NEUTRALIZED"; then
  exit 0
fi

# Launcher option-run — a global git option run between `git` and its
# subcommand (`git -c http.sslVerify=false push`, `git -C . push`,
# `git --no-pager push`, `git --git-dir X --work-tree Y push`). CHECK 3's
# commit detector already consumes such a run (automated-review PR #91); the push
# detectors (CHECK 0/1/2) originally required `git push` ADJACENCY and so
# were bypassed by ANY global option before `push` (e.g. `git -c x=y push
# origin main` slipped every guard). Consuming the run keeps the push guards
# aligned with the commit guard.
#
# Two variants, because the checks judge on different signals:
#
#   GIT_OPT_RUN (target-based) — used by CHECK 0 (force, ALL branches) and
#   CHECK 1 (explicit main/master TARGET). These block on what the command
#   is/does regardless of the current directory, so they consume the FULL
#   run, including value-taking long options that redirect the repo
#   (`--git-dir X`, `--work-tree Y`, `-C path`): a force-push or an explicit
#   `push … main` is unsafe no matter which repo it targets. The named
#   value-taking options each grab a SEPARATE-word value; the general
#   `--?flag` branch handles every other flag plus the `--opt=value` /
#   `-Rvalue` glued forms.
#
#   GIT_OPT_RUN_CWD (cwd-based) — used by CHECK 2, which fires only because
#   the CURRENT directory is on main and infers "this push is from main".
#   A command that explicitly redirects to another repo/worktree
#   (`git -C <feature-worktree> push`) is NOT a push from the main cwd, so
#   CHECK 2's inference does not apply — that is exactly why CHECK 3 resolves
#   `-C` before judging. This variant therefore deliberately OMITS the
#   repo-redirecting options from its value branch (only `-c NAME=VALUE`, a
#   repo-NEUTRAL config option, is consumed), so `git -c x=y push` from main
#   is caught while `git -C <feature-worktree> push` is left to CHECK 1
#   (explicit target) / CHECK 3 semantics — see TC-PS-78. The residual
#   (`git -C <path> push` with no explicit target, from a main cwd, not
#   caught by CHECK 2) is the same `-C` cross-repo residual family already
#   documented for CHECK 3 (TC-PS-64); CHECK 1 still catches any explicit
#   `main`/`master` target.
#
# Broadening only ADDS matches — every command blocked before stays blocked;
# the only new direction is fail-safe (block).
# CHECK 2's CWD variant excludes ONLY the three options that redirect git to a
# different repo/worktree (`-C`, `--git-dir`, `--work-tree`) — every other
# value-taking global option is repo-NEUTRAL (you are still operating on the
# main-cwd repo), so it stays in the value branch and CHECK 2 still fires (e.g.
# `git --exec-path X push` from main is a push from main).
#
# RESIDUALS (accepted, fail-safe — mirror CHECK 3's documented residuals):
#  - A `-c`/`-C`/`--git-dir`/… VALUE containing whitespace (quoted, e.g.
#    `-C "my repo"`) breaks the `[^[:space:]]+` value token, so the option-run
#    stops mid-value and the detector may not match. Pre-existing in CHECK 3;
#    strictly BETTER than before this fix (before, every option form bypassed).
#  - CHECK 2 structurally exempts `-C`/`--git-dir`/`--work-tree` without
#    resolving whether the redirect actually points elsewhere, so
#    `git -C . push` (bare, no explicit target) from a main cwd is not caught
#    by CHECK 2 — the same `-C` cross-repo residual family CHECK 3 documents
#    (TC-PS-64). CHECK 1 still catches any explicit `main`/`master` target.
GIT_OPT_RUN='((-c|-C|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix|--config-env|--attr-source)[[:space:]]+[^[:space:]]+[[:space:]]+|--?[^[:space:]]+[[:space:]]+)*'
GIT_OPT_RUN_CWD='((-c|--namespace|--exec-path|--super-prefix|--config-env|--attr-source)[[:space:]]+[^[:space:]]+[[:space:]]+|--?[^[:space:]]+[[:space:]]+)*'

# GIT_CMDPOS — command-position anchor for CHECK 0/1/2 (automated-review finding,
# Task 2 / security/bash-guard-command-position). CHECK 0/1/2 used to match
# `\bgit[[:space:]]+…push\b` as a raw SUBSTRING anywhere in the command,
# without requiring "git" to sit at a real command position. That meant a
# grep/rg SEARCH PATTERN or an echo that merely MENTIONED "git push" as text
# false-triggered a deny (see TC-PS-111/112/119). (A "git push" mention inside
# a heredoc BODY now DOES block — since PR #128 removed the heredoc sub-layer,
# body text flows through this same command-position anchor, an accepted
# over-block; see the COMMAND_NEUTRALIZED note above.)
#
# GIT_CMDPOS closes that gap by requiring "git" to appear at a genuine shell
# command position: the start of the command/segment, or right after a
# separator (`;` `&` `|` `(`), optionally preceded by one or more env-var
# assignments (`FOO=bar `) and/or `command`/`env`/`sudo`/`nice`/`nohup`/
# `time`/`exec` launcher wrapper words, and optionally quote/backslash- and
# path/-decorated (`"/usr/bin/git"`, `'\''git'\''`, `\git`). This is NOT a
# new invention: it is CHECK 3's own launcher-agnostic commit-counter prefix
# (_c3_commit_count_re, below) with the trailing `commit` keyword removed —
# GIT_OPT_RUN (already defined above) plus the literal `push` supply the
# rest. Reusing that exact, already-reviewed prefix (rather than a bare
# `(^|[;&|(])[[:space:]]*git`) is deliberate and load-bearing: a bare anchor
# would NOT match `FOO=bar git push origin main`, `command git push
# --force …`, `sudo git push origin main`, or `"/usr/bin/git" push …` —
# silently turning a currently-BLOCKED real push into an ALLOW.
# TC-PS-114..119 lock the env/wrapper/quote/path cases.
#
# ROUND 2 (automated-review consensus finding, security-engineer + code-reviewer,
# Task 2 round 2): the launcher-word alternation originally shipped as
# `(command|env)` only. The OLD (pre-command-position) CHECK 0/1/2 matched
# `\bgit[[:space:]]+…push\b` as a raw SUBSTRING anywhere in the command, so
# it ALSO caught `sudo git push origin main`, `time git push origin main`,
# `nice git push origin main`, `nohup git push origin main`, and `exec git
# push origin main` — anchoring detection to command position REGRESSED all
# five from BLOCK to a silent ALLOW, because none of those five words were
# in the alternation. The alternation now lists
# `command|env|sudo|nice|nohup|time|exec` so every one of these launcher
# forms stays BLOCKED, restoring pre-fix behaviour. TC-PS-120..126 lock this.
#
# Applied to COMMAND_NEUTRALIZED (the raw command with quote interiors
# neutralised — see above), never to raw $COMMAND, so a real command-position
# push is still caught even when it carries a quoted `-c` option value
# containing a separator character (TC-PS-118). Since PR #128 removed the
# heredoc sub-layer, this is the view CHECK 0/1/2/3 use — a gated op at command
# position inside a heredoc body now reaches it and BLOCKS.
#
# ROUND 3 (automated-review finding, PR #128): the launcher-word alternation only
# matched a launcher word IMMEDIATELY followed by whitespace-then-`git` — a
# REAL launcher invocation almost always carries the launcher's OWN options
# between the word and `git` (`sudo -u root git push origin main`, `env -i
# git commit -m x`, `nice -n 5 git push --force`, `time -p git commit`), so
# none of these matched and all four slipped back to a silent ALLOW.
# LAUNCHER_OPT_RUN (below) consumes that option run: zero or more tokens,
# each either a dash-flag (optionally with an attached `=value`, e.g.
# `--foo=bar`) or an `env`-style `VAR=val` assignment, each OPTIONALLY
# followed by a separate plain (non-dash) value token (`-u root`, `-n 5`).
# The value half is optional so a flag that takes NO separate value (`-i`,
# `-p`) is not forced to eat the next word — and because grep/bash use
# POSIX leftmost-longest matching (a real automaton, not a backtracking
# scanner), the engine tries every split and keeps whichever one lets the
# REQUIRED trailing `git` literal match; it can never get "stuck" having
# wrongly consumed `git` as somebody's option value. This only ever ADDS
# matches (a longer accepted prefix before `git`), so it can never turn a
# currently-blocked command into a silent allow — same fail-safe direction
# as every prior widening in this block. TC-PS-131..135 lock this.
#
# Non-goal (documented, not a regression): a NON-launcher word before `git`
# still does not match (`foo git push` stays unaffected) — LAUNCHER_OPT_RUN
# only activates AFTER one of the seven recognised launcher words, it does
# not change which words start the branch.
#
# ACCEPTED RESIDUAL (PR #128, automated-review dbid 3580122117): the optional
# separate-value token in LAUNCHER_OPT_RUN's `([[:space:]]+[^-…]…)?` group can
# also consume a following non-option WORD, so `env VAR=1 echo git push` on main
# matches GIT_CMDPOS (env → VAR=1 → echo eaten as the assignment's "value" → git
# push) and is treated as a real push — even though bash actually runs
# `echo git push` (prints the text, never runs git). This is an OVER-block (a
# harmless `echo` on main is denied; the agent re-words), the SAFE direction for
# a workflow-discipline gate. NOT fixed here: distinguishing "env VAR=1 echo …"
# (echo is the command) from "env VAR=1 git …" (git is the command) needs a real
# shell parser — exactly the both-direction quote/position parsing this PR is
# retiring. TC-PS-158 locks the over-block outcome.
LAUNCHER_OPT_RUN='((-[^[:space:];&|()]*|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*)([[:space:]]+[^[:space:];&|()-][^[:space:];&|()]*)?[[:space:]]+)*'
GIT_CMDPOS='(^|[;&|(])[[:space:]]*(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)|((command|env|sudo|nice|nohup|time|exec)[[:space:]]+'"$LAUNCHER_OPT_RUN"'))*["'\''`\\]?([^[:space:];&|()"'\''`\\]*/)?git["'\'']?[[:space:]]+'

# BACKTICK IN THE DECORATION CLASS (automated-review finding, PR #128): the
# quote-decoration class right before "git" (`["'\''`\\]?`) includes a
# backtick. It was added when the now-removed _hd_extract_live_spans emitted
# backtick-delimited substitution text, but it is kept after that removal
# because it is a pure WIDENING — a leading backtick before a command-position
# "git" (e.g. `` `git push origin main` `` as a raw unquoted substitution) only
# ever ADDS a recognised prefix character, the same fail-safe direction as every
# other GIT_CMDPOS broadening in this file. It does not change which separators
# start the branch, nor the launcher alternation, nor the closing decoration
# after "git". (A backtick/`$(...)` command substitution whose interior gets
# quote-neutralised is the accepted `echo "$(git push)"` residual — TC-PS-152/154.)

# RESIDUALS introduced by GIT_CMDPOS (accepted, same regex-can't-parse-shell
# family CHECK 3 already documents at _c3_commit_count_re/_c3_git_re — not
# hidden): `xargs … git push`, `eval git push …`, `sh -c '… git push …'`
# (all RE-EXECUTE an argument string, which no regex anchor can see through
# — no launcher-word alternation can help here, because these tools invoke
# git through a NEW shell/argv rather than as a literal adjacent word); a
# real push hidden inside `$(...)`/backtick command substitution (`echo
# "$(git push origin main)"`) is not a command-position match at the OUTER
# level — same pre-existing class as CHECK 3's `-m "$(...)"` residual; and
# `-C <path>` cross-repo redirects are resolved ONLY by CHECK 3 (commit),
# not by CHECK 0/1/2 (push) — CHECK 2's redirect-exemption comment below
# already documents that this is a residual, by design (CHECK 1 backstops
# any explicit main/master target regardless of which repo is redirected
# to). Every one of these falls back to TODAY's pre-fix behaviour or an
# over-block, never a new silent allow of a plain `git … push` — the class
# of command GIT_CMDPOS exists to fix.
#
# CORRECTION (Task 2 round 2): earlier revisions of this comment listed
# `sudo git push`, `time git push`, `nice git push`, `exec git push`, and
# `nohup git push` here as accepted residuals, framed as a gap "inherited"
# from CHECK 3's commit counter. That was wrong on both counts: (1) these
# five forms are not residuals — they are exactly the launcher words the
# alternation above now lists, so they are BLOCKED; (2) "inherited from
# CHECK 3" implied CHECK 3 already handled them safely, when in fact CHECK
# 3 had the SAME `(command|env)`-only gap in its own multi-commit counter
# (_c3_commit_count_re) AND a separate, deeper gap in its entry test (which
# had no launcher/env support at all) — both are fixed together in this
# same round, not one inheriting safety from the other. See the CHECK 3
# comment block below for the commit-side detail.
#


# Exempt dry-run pushes — they don't actually push anything, so a dry-run needs
# no approval token. This is a match-ANYWHERE early `exit 0` for the WHOLE hook
# call, so it must exempt ONLY when the command has no OTHER consequential git op
# that a later check must still evaluate: a non-dry-run push (CHECK 0/1/2) or any
# git commit (CHECK 3). We segment the command on shell separators (;, &, |,
# newline) and inspect each segment:
#   - a decoy dry-run in a chain (`... push --dry-run && git push origin main`,
#     or `... --dry-run && git commit`) is caught — the real push/commit lands in
#     its OWN segment, so we do NOT exempt and the real check blocks it;
#   - an ordinary redirection or pipe on a LONE dry-run (`git push --dry-run
#     2>&1`, `git push --dry-run | tee log`) stays exempt — the `&`/`|` there
#     introduces no second git op. Splitting on `&` also breaks `2>&1` into
#     `2>`/`1`, neither a git op, so the redirection is correctly ignored.
# Fixes BOTH the decoy-dry-run bypass AND the over-block of ordinary dry-run
# redirections/pipes that the earlier "no separators at all" guard caused
# (configured reviewer review of PR #125; the earlier guard came from the Sonnet review).
#
# ⛔ The `done < <(printf … | tr …)` PROCESS SUBSTITUTION is LOAD-BEARING —
# do NOT "simplify" it to `printf … | tr … | while read`: the pipe form runs
# the loop in a SUBSHELL, so `_EXEMPT_DRYRUN=false` set inside would silently
# vanish and every decoy chain would be exempted. Same invariant applies to
# the CHECK 2 segment loop below.
#
# Segmentation is quoting-aware — it splits COMMAND_NEUTRALIZED (see the
# _neutralize_quoted helper above), so a separator inside a quoted value
# (`git -c x="A&B" push`) no longer splits mid-command and hides a real push.
#
# RESIDUALS (accepted — same regex-can't-parse-shell class as CHECK 3's):
#  - A real git op INSIDE command substitution (`git push --dry-run
#    $(git push origin main)`) is not seen as its own segment — pre-existing on
#    the old guard too; CHECK 1 still backstops any explicit main/master target.
#  - A real push sharing a segment with literal `--dry-run` text (e.g. a
#    trailing `# --dry-run` comment) is treated as a dry-run — pre-existing,
#    not a realistic agent slip.
#  - Backslash-escaped / ANSI-C quotes are not modelled by _neutralize_quoted
#    (fail-safe over-split); see its header.
if grep -qE "git[[:space:]]+${GIT_OPT_RUN}push[[:space:]]+[^|;&]*--dry-run" <<< "$COMMAND"; then
  _EXEMPT_DRYRUN=true
  # `|| [[ -n "$_seg" ]]` — the piped `printf '%s'` output has NO trailing
  # newline, so plain `read -r` returns non-zero on the FINAL segment and the
  # loop body would never inspect it. A decoy chain's real push is exactly that
  # final segment (`… --dry-run && git push origin main`), so without this
  # guard the exemption fires and the real push slips through (TC-PS-89/90/95/96).
  while IFS= read -r _seg || [[ -n "$_seg" ]]; do
    # A real (non-dry-run) push in this segment → let CHECK 0/1/2 handle it.
    if grep -qE "\bgit[[:space:]]+${GIT_OPT_RUN}push\b" <<< "$_seg" && ! grep -qE -- "--dry-run" <<< "$_seg"; then
      _EXEMPT_DRYRUN=false; break
    fi
    # A git commit in this segment → let CHECK 3 handle it.
    if grep -qE "\bgit[[:space:]]+${GIT_OPT_RUN}commit\b" <<< "$_seg"; then
      _EXEMPT_DRYRUN=false; break
    fi
  done < <(printf '%s' "$COMMAND_NEUTRALIZED" | tr ';' '\n' | tr '&' '\n' | tr '|' '\n')
  if [[ "$_EXEMPT_DRYRUN" == "true" ]]; then
    exit 0
  fi
fi

# CHECK 0 — Block force-push on ALL branches.
#
# Force-push rewrites history and can destroy reviewer work, squash someone
# else's commits, or erase a PR's review trail. The /review-pr safety rail
# says "Never force-push" — this hook enforces it technically.
#
# Matches: --force, -f (as a git push flag), --force-with-lease.
# Runs BEFORE the approval-token check so no one can push-approve their way
# past a force-push.
#
# Matched against COMMAND_NEUTRALIZED (raw command, quote-interiors neutralised),
# not raw $COMMAND, and anchored with GIT_CMDPOS (not a bare `\bgit`) — see the
# GIT_CMDPOS comment block above. A grep/echo mention of "git push --force" is
# not a command-position match, so it stays allowed (TC-PS-116); a force-push at
# command position inside a heredoc body now DOES match and blocks (accepted
# over-block since PR #128 removed the heredoc sub-layer).
if grep -qE "${GIT_CMDPOS}${GIT_OPT_RUN}push\b[^;&|]*(--force\b|[[:space:]]-f\b|--force-with-lease\b)" <<< "$COMMAND_NEUTRALIZED"; then
  jq -n '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": "BLOCKED: force-push detected (--force, -f, or --force-with-lease). Force-pushing rewrites history and can destroy reviewer work or a PR review trail. If force-push is truly necessary, ask the user to run the command themselves outside the agent context."
    }
  }'
  exit 0
fi

# CHECK 0.5 — Combined self-approval pattern:
#   "touch ~/.claude/.push-ready && git push ..."
#
# When the stage 2 classifier blocks standalone `touch ~/.claude/.push-ready`
# (a known Claude Code platform behaviour where the classifier overrides the
# workflow-auto-approve hook's stage 1 allow), the agent falls back to combining
# token creation and push in a single command. This hook recognises that pattern
# and allows it.
#
# Security model:
#   - Force-push is still blocked by CHECK 0 above (runs first, before this check).
#   - The rules/git-workflow.md rule requires AskUserQuestion before pushing to main.
#     That rule is the PRIMARY gate. This token is belt-and-suspenders.
#   - An agent that bypasses AskUserQuestion could use this pattern — but it could
#     also bypass AskUserQuestion for any other rule. Compliance with AskUserQuestion
#     is enforced by the rule, not by this hook.
#   - The combined pattern makes the approval intent explicit in the command string.
#
# Matches:  touch ~/.claude/.push-ready && git push
#           touch ~/.claude/.push-ready && git push origin main
#           touch ~/.claude/.push-ready && git push -u origin feature/branch
# Does NOT match (caught by CHECK 0): touch ... && git push --force ...
#
# Security: pin to the canonical Claude home — only `~/.claude` or `$HOME/.claude`.
# A broader path regex (e.g. any `*/.claude/`) would let `touch ./tmp/.claude/.push-ready`
# satisfy the pattern without creating the real approval token. The `~` and `$HOME`
# prefixes are the only paths that resolve to the actual Claude state directory.
# Multiline guard: grep evaluates line-by-line, so a COMMAND with an embedded
# newline could match on line 1 while hiding additional push commands on later
# lines. Only allow the combined pattern when COMMAND is a single line (no \n).
if [[ "$COMMAND" != *$'\n'* ]] && grep -qE '^touch[[:space:]]+(~|\$HOME)/\.claude/\.push-ready[[:space:]]+&&[[:space:]]+git[[:space:]]+push([[:space:]][^;&|]*)?$' <<< "$COMMAND"; then
  exit 0  # Allow — force-push already blocked above; AskUserQuestion is the primary gate
fi

# Check for approval override — the agent creates ~/.claude/.push-ready
# after getting user confirmation via AskUserQuestion. If the file exists
# and is less than 300 seconds old, allow the push and delete the file.
# This prevents the hook from blocking a push the user already approved.
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
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "BLOCKED: neither HOME nor CLAUDE_STATE_DIR is set, so the push/commit guard cannot locate the approval token (~/.claude/.push-ready) that authorises a push, nor the commit-on-main override. Without them it cannot tell an approved push from an unapproved one.\n\nA gate that cannot find its own evidence has not been satisfied, so it fails closed.\n\nThis cannot be fixed from inside a Bash tool call — every call is a fresh shell, so an `export` here does not survive to the next one. Set HOME (or CLAUDE_STATE_DIR) in the environment the agent itself runs in — the `env` block of ~/.claude/settings.json, or the container/CI environment — and start a new session."}}
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


CWD=$(echo "$HOOK_DATA" | jq -r '.cwd // "."')
APPROVAL_FILE="$STATE_DIR/.push-ready"
if [[ -f "$APPROVAL_FILE" ]]; then
  if [[ "$(uname)" == "Darwin" ]]; then
    FILE_AGE=$(( $(date +%s) - $(stat -f %m "$APPROVAL_FILE") ))
  else
    FILE_AGE=$(( $(date +%s) - $(stat -c %Y "$APPROVAL_FILE") ))
  fi
  if [[ "$FILE_AGE" -lt 300 ]]; then
    rm -f "$APPROVAL_FILE"
    exit 0
  fi
  rm -f "$APPROVAL_FILE"
fi

# (The heredoc-strip sub-layer that used to build a COMMAND_STRIPPED view here
# was REMOVED in PR #128 — CHECK 0/1/2/3 now match COMMAND_NEUTRALIZED, the
# quote-neutralised RAW command. See the COMMAND_NEUTRALIZED note near the top.)

# CHECK 1 — Explicit push to main/master (any position in command).
#
# Matches "git push ... main" or "git push ... master" where main/master is
# a STANDALONE branch argument. The required preceding char is whitespace or
# `:` (refspec separator), and the required trailing char is whitespace, `:`,
# or end-of-string. This deliberately excludes `-` and `/` so branch names
# that contain `main` or `master` as a suffix or substring (e.g.
# `fix/init-no-commit-to-main`, `feature/main-fix`, `main-feature`) do NOT
# false-trigger.
#
# Why not `\b(main|master)\b`?
# Bash regex `\b` treats `-` and `/` as non-word chars, which means BOTH the
# `-main` boundary in `fix/init-no-commit-to-main` AND the `/main` boundary
# in `feature/main-fix` count as word boundaries. The previous version of
# this hook claimed `\b` prevented matching `feature/main-fix`, but it did
# not — both branch names matched and produced false positives that blocked
# legitimate feature-branch pushes.
#
# Matches WE WANT to catch:
#   git push origin main                  → " main" + EOL → match
#   git push -u origin master             → " master" + EOL → match
#   git push origin local:main            → ":main" + EOL → match
#   git push origin main:other            → " main" + ":" → match
#   git push origin refs/heads/main       → separate alternation catches this
#
# Matches WE DO NOT want to catch (previously false-triggered):
#   git push -u origin fix/init-no-commit-to-main  → "-main" preceded by `-` → no match
#   git push origin feature/main-fix               → "main" trailing `-` → no match
#   git push origin main-feature                   → "main" trailing `-" → no match
#   git push origin feature/main                   → "/main" NOT in char class → no match
#
# The preceding char class for the first alternation is [[:space:]:] (space or
# colon only). `/` is NOT included — that caused false positives for branch
# names like `feature/main`. The `refs/heads/main` case is handled by a
# separate alternation that matches the full `refs/heads/` prefix explicitly.
#
# The negated character class [^;&|] prevents matching across chained commands
# (e.g., "git push feature && echo main" would NOT match "main" as a push target).
#
# Matched against COMMAND_NEUTRALIZED and anchored with GIT_CMDPOS (not a
# bare `\bgit`) — see the GIT_CMDPOS comment block above. Before this fix, the
# `\bgit` anchor matched ANYWHERE the literal word "git" appeared (no command
# position requirement), so an echo/grep mention of "git push origin main"
# false-triggered this check (TC-PS-111), while a quoted, path-qualified
# invocation like `"/usr/bin/git" push origin main` was MISSED entirely (no
# whitespace directly follows "git" there) — TC-PS-119 locks that this fix
# does not regress into a silent allow for exactly that quoted/path form.
if grep -qE "${GIT_CMDPOS}${GIT_OPT_RUN}push\b[^;&|]*([[:space:]:](main|master)([[:space:]:]|$)|refs/heads/(main|master)([[:space:]:]|$))" <<< "$COMMAND_NEUTRALIZED"; then
  jq -n '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": "BLOCKED: git push to main/master detected. Before pushing to main:\n1. Run: git log origin/main..main --oneline\n2. Show the commits to the user\n3. Get explicit approval via AskUserQuestion\n\nNever push to main without user confirmation — even for config or tooling commits."
    }
  }'
  exit 0
fi

# CHECK 2 — On main/master branch, any git push requires approval.
#
# Previous version anchored to start-of-command (^git push) which was bypassed
# by chained commands like "rm .push-ready; git push". Now we match a
# command-position "git push" in ANY segment of the command (GIT_CMDPOS,
# not a bare `\bgit` substring match) — see the GIT_CMDPOS comment block
# above. This is still conservative: if you're on main and any segment has a
# real `git push` invocation (even targeting a feature branch), approval is
# required. Workaround: checkout the feature branch first.
#
# Before this fix, `\bgit` matched the word "git" ANYWHERE (no command-
# position requirement), so a cwd-on-main echo/prose mention of "git push"
# false-triggered this check (TC-PS-112).
CURRENT_BRANCH=""
if git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1; then
  CURRENT_BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null || echo "")
fi

if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
  # Evaluate per shell segment (split on ;, &, |, newline — same segmentation
  # as the dry-run exemption above) so the repo-redirect exemption below stays
  # PER-INVOCATION: in `git --git-dir=/other push; git push`, the second (cwd)
  # push must still block even though the first one is redirected. A real git
  # invocation can never span a segment boundary, so splitting loses no matches.
  #
  # Repo-redirect exemption — why: CHECK 2 fires purely on the cwd being main,
  # so a push that explicitly redirects git to another repo/worktree
  # (`-C <path>`, `--git-dir[= ]<path>`, `--work-tree[= ]<path>`) is NOT a push
  # from the main cwd and the inference does not apply. GIT_OPT_RUN_CWD already
  # exempts the SPACE forms structurally (the value token stops the option run),
  # but its `--?flag` fallback still consumed the GLUED forms
  # (`--git-dir=/other`), so those were inconsistently blocked (configured reviewer review
  # of PR #125). The redirect grep below exempts a segment only when the
  # redirect option sits in option-run position: GIT_OPT_RUN (the full variant)
  # must consume every option BEFORE it, so a `-c` VALUE that merely contains
  # the text `--git-dir=` (e.g. `git -c x=--git-dir=y push`) cannot satisfy it.
  # Same accepted residual family as the space forms (TC-PS-64/78): the
  # redirect target is not resolved; CHECK 0/1 still catch force-pushes and
  # explicit main/master targets on redirected pushes.
  _C2_BLOCK=false
  # `|| [[ -n … ]]` — final-segment guard: COMMAND_NEUTRALIZED may not end with
  # a newline, so this loop must not silently skip the last segment.
  #
  # Both greps below are anchored with GIT_CMDPOS (not a bare `\bgit`) so
  # "push"/the redirect options are only recognised when they belong to a
  # real command-position git invocation IN THIS SEGMENT — a segment that
  # merely mentions "git push" as prose (no command-position git at all)
  # never reaches either grep with a match. Feeds the ALREADY-computed
  # COMMAND_NEUTRALIZED (raw command, quote-interiors neutralised, built once
  # near the top) instead of recomputing `_neutralize_quoted` here.
  while IFS= read -r _c2_seg || [[ -n "$_c2_seg" ]]; do
    if grep -qE "${GIT_CMDPOS}${GIT_OPT_RUN_CWD}push\b" <<< "$_c2_seg"; then
      if grep -qE "${GIT_CMDPOS}${GIT_OPT_RUN}(-C[[:space:]]|--git-dir(=|[[:space:]])|--work-tree(=|[[:space:]]))" <<< "$_c2_seg"; then
        continue  # redirected push — CHECK 2's cwd inference does not apply
      fi
      _C2_BLOCK=true; break
    fi
  done < <(printf '%s' "$COMMAND_NEUTRALIZED" | tr ';' '\n' | tr '&' '\n' | tr '|' '\n')
  if [[ "$_C2_BLOCK" == "true" ]]; then
    jq -n '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "BLOCKED: Currently on main/master branch and the command contains git push. Any push from main requires explicit approval.\n\nBefore pushing:\n1. Run: git log origin/main..main --oneline\n2. Show the commits to the user\n3. Get explicit approval via AskUserQuestion\n4. Create the approval token: touch ~/.claude/.push-ready (valid for 300s)\n\nIf you intend to push a feature branch, checkout that branch first — do not push from main."
      }
    }'
    exit 0
  fi
fi

# _c3_norm <token> — normalise one path token extracted for CHECK 3 into
# $_C3_NORM; sets _C3_NORM_FAIL=true when the token needs shell expansion we
# refuse to do. Quote-stripping runs FIRST because a legitimately quoted plain
# path (e.g. `-C "/repo"`) must lose its quotes to pass the `== /*`
# absolute-path test and the `[[ -d ]]` directory check downstream; the
# $/backtick rejection itself is order-insensitive (it matches anywhere in
# the token, with or without surrounding quotes). The token is only ever
# passed as a QUOTED argument to [[ -d ]] / git -C — never eval'd — so
# rejection (not expansion) is the safe answer for $ and backticks.
_c3_norm() {
  _C3_NORM="$1"; _C3_NORM_FAIL=false
  # Strip one layer of matching surrounding quotes ("path" or 'path').
  case "$_C3_NORM" in
    \"*\") _C3_NORM="${_C3_NORM#\"}"; _C3_NORM="${_C3_NORM%\"}" ;;
    \'*\') _C3_NORM="${_C3_NORM#\'}"; _C3_NORM="${_C3_NORM%\'}" ;;
  esac
  # Unexpandable input → resolution failure (caller falls back to cwd branch).
  case "$_C3_NORM" in
    *'$'*|*'`'*) _C3_NORM_FAIL=true; return 0 ;;
  esac
  # Expand leading ~ / ~/ to $HOME (~user is NOT expanded — it will fail the
  # directory check and fall back, which is the fail-safe direction).
  if [[ "$_C3_NORM" == "~" ]]; then _C3_NORM="$HOME"
  elif [[ "$_C3_NORM" == "~/"* ]]; then _C3_NORM="$HOME/${_C3_NORM#\~/}"
  fi
  return 0
}

# CHECK 3 — On main/master branch, a real `git commit` requires approval.
#
# "Never commit to main" was previously instruction-only (rules/git-workflow.md). This
# makes it a hook gate so a forgotten `git checkout -b` cannot silently land a commit on
# main — the push backstop (CHECK 2) only catches it at PUSH time, leaving a local
# commit-on-main that needs manual recovery. CHECK 3 catches it at the source.
#
# Detection is COMMAND-POSITION (start of a line, or right after `;` `&&` `||` `|` `(`),
# NOT "anywhere", so `echo "run git commit"` / `grep "git commit" f` do NOT false-trigger
# — only a real `git commit` invocation does. Runs on COMMAND_NEUTRALIZED / raw $COMMAND
# (PR #128 removed the heredoc sub-layer), so a commit-message heredoc body that mentions
# a command-position "git commit" now DOES reach this check and blocks (accepted over-block).
# (Differs deliberately from CHECK 2's "git push anywhere": the string "git commit" appears
# in prose/messages far more often than "git push", so command-position avoids the noise.)
#
# Global options between `git` and `commit` ARE handled (automated-review PR #91): the option run
# `((-c|-C) VALUE | --?flag)*` is consumed before `commit`, so `git -c user.name=x commit`,
# `git -C repo commit`, and `git --no-pager commit` are all caught. The `-c`/`-C` branch is
# listed first because those take a separate VALUE token; flag options (--no-pager, -p, …)
# match the `--?[^space]+` branch and do NOT swallow the following `commit`.
#
# ENTRY test, WIDENED (Task 2 round 2, TC-PS-127/128): the boolean test that gates
# whether this whole CHECK 3 block runs at all previously required a BARE `git` at
# command position — no env-var-assignment prefix, no `command`/`env` wrapper, and
# none of the launcher words GIT_CMDPOS lists. That was a DEEPER gap than the
# in-chain counter's: a STANDALONE `sudo git commit -m x` / `command git commit -m x`
# / `env git commit -m x` / `FOO=bar git commit -m x` on main skipped CHECK 3
# entirely and was silently ALLOWED, even though the counter already recognised
# `command`/`env` for a SECOND commit in a chain (TC-PS-72/74). The entry test now
# reuses `${GIT_CMDPOS}${GIT_OPT_RUN}commit\b` — the SAME widened prefix CHECK 0/1/2
# use for `push` — so entry and push gate identically. The RESOLUTION regex
# (_c3_git_re, step (3) below) stays STRICT/bare-git-only as before: a
# launcher-prefixed commit that now enters CHECK 3 simply fails resolution and falls
# back to CURRENT_BRANCH (cwd), same fail-safe direction as every other resolution
# failure in this block — never a new silent allow.
#
# The branch checked is the commit's TARGET repo's branch — resolved from a single leading
# `cd <path> &&|;` prefix plus the `-C` values in the option run of the FIRST command-position
# `git … commit` match — with fallback to CURRENT_BRANCH (cwd) whenever resolution fails. That
# fallback is EXACTLY the pre-change gate, so every case this resolution can't handle degrades
# to the behaviour this hook already had, never to a silent allow.
#
# Why the automated-review PR #91 follow-up failure mode (reverted at the time) no longer applies — but
# ONLY for the RESOLUTION steps (1),(3),(4): bash `=~` is leftmost-match, so extraction anchors
# on the FIRST command-position match — the real `git … commit` invocation always precedes its
# own `-m` string, so a commit MESSAGE mentioning `-C` can never BE that match. `-C` is read
# ONLY from the option run BETWEEN that `git` and its `commit` keyword, so text AFTER `commit`
# (message bodies — TC-PS-48/59) is never read as a target PATH by the resolution logic. This is
# a stricter, narrower parse than the reverted attempt: it never looks past the keyword that ends
# the option run, so a `-m "… -C other …"` cannot redirect the resolved directory.
#
# The above scoping is important: the step-(2) `cd` scan still scans the WHOLE RAW command
# (message bodies included) — it is a safety counter, not a path extractor, so breadth over
# precision is deliberate. A commit MESSAGE that itself contains a command-position `cd`
# (e.g. `-m "…; cd x"`) will INFLATE that count and force the fail-safe fallback to
# CURRENT_BRANCH (cwd). The step-(0) multi-commit COUNTER USED TO behave the same way on the raw
# command, but as of PR #128 (automated-review dbid 3580911797) it scans COMMAND_NEUTRALIZED instead (see
# the QUOTED ENV-ASSIGNMENT note at the counter below): a separator INSIDE a quoted `-m` message
# (`-m "x; git commit y"`) is neutralised and no longer inflates the COMMIT count — the counter
# now counts only REAL command-position commits, matching the entry test's own view. Both
# remaining directions stay safe: from a MAIN cwd a `cd`-inflated command over-blocks (denied even
# though only one real commit runs — fail-safe); from a NON-main cwd it degrades to CURRENT_BRANCH
# (feature → allowed), the SAME pre-existing cross-repo residual family documented for TC-PS-64
# (single-command `git -C <main> commit` from a feature cwd is allowed on origin/main too;
# CHECK 1/2 backstop any eventual push from main). It can NEVER turn a pre-change block into a
# silent allow. A follow-up is filed to close the remaining `cd`-in-message residual: distinguishing
# a real chained `cd` from a `; cd` inside a quoted `-m` needs a real shell parser — the exact
# complexity the PR #91 revert warned against.
#
# Fallback matrix — ALL of the following fall back to checking CURRENT_BRANCH (cwd), never a
# silent allow: MORE THAN ONE command-position `git … commit` ANYWHERE in the command (multi-commit
# chains — later commits run in the shell's cwd, so judging the whole command by the first
# match's target would unguard them; see step (0). This counter scans COMMAND_NEUTRALIZED, so a
# separator inside a quoted `-m` message is neutralised and does NOT inflate the count — only REAL
# command-position commits are counted; see the QUOTED ENV-ASSIGNMENT note at step (0)); the
# extracted path contains `$`
# or a backtick (refuses to guess shell expansion);
# any command-position `cd` other than the single leading one ANYWHERE in the command (untracked
# directory state — this `cd` scan still reads the RAW command, so `-m "…; cd x"` can still force this fallback);
# `=~` cannot re-find what the detection `grep` found (e.g. `git commit-tree`, or a `git commit`
# that is line-initial only on a LATER line of a multiline command — `grep` scans per-line with
# `^`, `=~` does not re-scan for a fresh `^` mid-string); or the resolved directory doesn't exist
# or isn't a git repo.
#
# Accepted residuals — this is a workflow-discipline gate, not an adversarial sandbox (anyone who
# can run Bash can delete the hook). Every residual below resolves to TODAY's behaviour or an
# OVER-block, never a new bypass. One is a DETECTION-level gap, distinct from the resolution
# fallbacks: a `-c`/`-C` VALUE containing whitespace (e.g. quoted `-C "path with spaces"`) is a
# PRE-EXISTING SILENT ALLOW of the DETECTION regex itself, unchanged by this diff — the
# `[^[:space:]]+` value token cannot span whitespace, so the detection grep never matches,
# CHECK 3 never runs, and the commit is allowed (verified identical on origin/main). It is NOT
# covered by the "never a silent allow" invariant of the resolution logic above, which governs
# only commands the detection ADMITS; a follow-up is filed to close the detection gap. The
# remaining residuals all resolve through the fallback: env-prefixed/launcher-wrapped/
# absolute-path git and `--git-dir=` invocations now ENTER this block (Task 2 round 2 widened
# the entry test to admit them — they used to skip CHECK 3 entirely, a silent ALLOW, not a
# fallback; see TC-PS-127/128) but are NOT parsed by the strict RESOLUTION regex
# (_c3_git_re), so they fall back to CURRENT_BRANCH exactly like any other resolution
# failure; multi-commit chains (more than one command-position `git … commit`) ALWAYS fall back to the
# cwd branch — same as the multi-`cd` guard and exactly the pre-change gate; per-segment
# resolution is deliberately NOT attempted (each chain segment runs in the shell's cwd anyway,
# and per-match parsing is the complexity the PR #91 revert warned about). Consequence, from a
# NON-main cwd: `git commit && git -C <main-repo> commit` degrades to the cwd branch (feature →
# allowed) — the PRE-EXISTING cross-repo residual, verified identical on origin/main (the
# single-command `git -C <main-repo> commit` IS blocked — TC-PS-54; only the chained form
# degrades, and CHECK 1/2 still backstop any eventual push from main; TC-PS-64 locks this
# consciously); subshell forms
# (`(cd … && git commit)`) and any other non-leading `cd` (falls back, per the matrix above); and
# multi-line `-m` strings containing line-initial `git commit` text (`grep`'s per-line `^`
# detects it, but `=~`'s string-anchored `^` can't re-find it after the real match — falls back
# to an OVER-block, which is fail-safe: it blocks a commit rather than silently letting one
# through). The push backstop (CHECK 1/2) still catches any eventual push from main.
#
# Override: the agent touches ~/.claude/.commit-on-main-ok (valid 300s) ONLY after the user
# explicitly confirms a sanctioned commit to main (rules/git-workflow.md "Never Commit to
# Main"). A SEPARATE token from .push-ready, so approving a commit never also approves a push.
#
# ENTRY TEST matched against COMMAND_NEUTRALIZED, not raw $COMMAND (automated-review
# finding, PR #128): GIT_CMDPOS's env-assignment branch only matches
# `NAME=[^[:space:]]*` — a value with no embedded whitespace. A QUOTED assignment
# with an interior space (`FOO="a b" git commit -m x`) is a single shell word but
# breaks that `[^[:space:]]*` token on the raw command view, so the env-assignment
# branch would not consume it and the entry test would never match — CHECK 3
# silently skipped. COMMAND_NEUTRALIZED is the SAME quote-interior-neutralised
# view CHECK 0/1/2 already use (via GIT_CMDPOS+GIT_OPT_RUN above): the space inside
# the quotes becomes `_`, so `FOO="a_b"` matches `[^[:space:]]*` as one token and the
# entry test fires correctly. The downstream RESOLUTION logic below intentionally
# keeps scanning the un-neutralised raw $COMMAND (via _c3_scan) — neutralising
# would corrupt a `-C "path with spaces"` value it tries to read back out. TC-PS-136
# locks this.
if grep -qE "${GIT_CMDPOS}${GIT_OPT_RUN}commit\b" <<< "$COMMAND_NEUTRALIZED"; then
  # --- Resolve the commit's TARGET repo (see comment block above) -------
  COMMIT_TARGET_BRANCH="$CURRENT_BRANCH"   # fail-safe default: the pre-change cwd gate
  _c3_dir="$CWD"
  _c3_fail=false
  _c3_scan="$COMMAND"

  # (0) SECURITY guard (security-review CRITICAL): resolution below inspects
  #     only the FIRST command-position `git … commit`; later commits in a
  #     chain run in the shell's cwd and would go UNGUARDED whenever the first
  #     target is non-main (`git -C <feature-wt> commit && git commit` from a
  #     main cwd would land the second commit on MAIN). Mirror the multi-`cd`
  #     guard in (2): if the command contains MORE THAN ONE command-position
  #     git-commit, fall back to CURRENT_BRANCH (cwd) for the whole command —
  #     exactly the pre-change chain gate. Counting is per LINE with a
  #     string-consuming `=~` loop, because the detection grep's `^` is
  #     per-line while `=~`'s `^` is string-anchored: a single whole-string
  #     scan would MISS a newline-positioned second commit (TC-PS-65).
  #     Pipe-free (no `grep -o | wc` — SIGPIPE class under pipefail) and
  #     bash-3.2-safe (no \b in =~). Early-exits at 2 — the exact count beyond
  #     that is irrelevant.
  #
  #     Security fix (automated-review PR #122, Finding 2 — v2, launcher-AGNOSTIC):
  #     the COUNTER must recognise a second git-commit no matter HOW git is
  #     invoked, or a chain like `git -C <feature-wt> commit && <LAUNCHER> commit`
  #     from a main cwd counts 1, resolves to the feature target, and ALLOWS the
  #     chain while the second commit really runs in cwd (main) UNGUARDED — a
  #     regression vs origin/main, which blocked any command-position commit
  #     unconditionally while cwd==main. The first fix used an ALLOWLIST
  #     (`/git` | `command git` | `VAR=… git`) which security-reviewer showed
  #     still had live bypasses: `env git commit` (a separate wrapper word, not
  #     ending in "git"), `"/usr/bin/git"` / `'/usr/bin/git'` (a quote breaks a
  #     `[^…]*/git` token), and `\git` (backslash). So the COUNTER now uses ONE
  #     launcher-AGNOSTIC regex, _c3_commit_count_re, matching a command-position
  #     git-commit through ANY prefix: an optional run of env-assignments
  #     (`VAR=val `) and/or the `command`/`env` wrapper words, then an optional
  #     leading quote or backslash, an optional path ending in `/`, `git`, an
  #     optional closing quote, then a PERMISSIVE gap + trailing-boundary.
  #
  #     Security fix (automated-review PR #122, Finding 3 — value-taking options): the
  #     option-run the counter first used (mirroring _c3_git_re) only modelled
  #     `-c|-C <value>`; a git option that takes a SEPARATE-word value
  #     (`--git-dir .git`, `--work-tree .`, `--namespace x`) left a stray token
  #     before `commit`, so a 2nd command-position commit like
  #     `env git --git-dir .git --work-tree . commit` was MISSED — undercount →
  #     no fallback → the main-cwd commit was allowed. The counter no longer
  #     models the option run at all: it now spans `git`…`commit` with a
  #     PERMISSIVE gap `([^;&|()]*[[:space:]])?` (any run of non-separator
  #     tokens). This closes the whole value-option family in one move and is
  #     simpler than the nested option-run. The gap stops at a command separator
  #     (`;&|()`) so it never swallows a following command segment, and it is a
  #     single starred class (not nested alternation) → no ReDoS. Widening the
  #     counter only ever OVER-counts → over-blocks; still never a new allow.
  #     The RESOLUTION regex _c3_git_re stays STRICT and unchanged — only the
  #     counter widened.
  #
  #     Why broad is SAFE here: over-counting only pushes MORE commands into the
  #     cwd fallback → from a main cwd that is an over-BLOCK (deny a chain that
  #     may have had one real commit), never a new allow. A counter can only err
  #     toward blocking; it never opens a bypass. This is scoped to the COUNTER
  #     ONLY — the RESOLUTION regex (_c3_git_re, used in steps (3)/(4)) stays
  #     BARE-git-only: a launcher-form target is not a path we resolve, it only
  #     needs to force the same multi-commit fallback a second bare commit would.
  #     _c3_git_re is defined here (used only by (3)/(4)); see (3) for why the
  #     grep's `commit\b` becomes an explicit trailing class (bash 3.2 =~ lacks \b).
  #
  #     Accepted residuals (DOCUMENTED, not chased): `xargs git commit`,
  #     `eval git commit`, and `sh -c '… git commit'` all RE-EXECUTE an
  #     argument string through a NEW shell/argv and cannot be detected without
  #     a real shell parser — the same accepted-residual class as the base
  #     bare-git regex, backstopped by CHECK 1/CHECK 2 at push time. These are
  #     folded into the shell-aware-parsing follow-up (task_edae40d1).
  #
  #     ROUND 2 (automated-review consensus finding, Task 2 round 2): the launcher-word
  #     alternation above originally shipped as `(command|env)` only, which is
  #     why the residuals list used to also name `sudo`/`nice`/`exec git commit`
  #     here. That was a live undercount bug, not a residual: a chain like
  #     `git -C <feature> commit && sudo git commit` from a main cwd counted
  #     only 1 (the launcher-prefixed 2nd commit was invisible to the counter),
  #     skipped the multi-commit fallback, and ALLOWED the chain — but the 2nd
  #     commit really runs in the shell's cwd (main), unguarded. The
  #     alternation now lists `command|env|sudo|nice|nohup|time|exec`,
  #     mirroring GIT_CMDPOS's own widening (see its comment above), so all of
  #     those forms are counted correctly. TC-PS-129/130 lock this.
  #
  #     ROUND 3 (automated-review finding, PR #128): same gap as GIT_CMDPOS's ROUND 3
  #     fix above — the launcher word had to be followed IMMEDIATELY by
  #     whitespace-then-`git`, so a 2nd commit launched with the launcher's
  #     OWN options (`sudo -u root git commit`) undercounted. Reuses the same
  #     LAUNCHER_OPT_RUN defined next to GIT_CMDPOS. TC-PS-135 locks this.
  #
  #     BACKTICK IN THE COUNTER DECOR (automated-review finding, PR #128): the counter's
  #     decor class allows a leading BACKTICK before `git`, mirroring GIT_CMDPOS.
  #     It was added when a live backtick span was extracted by the now-removed
  #     _hd_extract_live_spans, but it is kept as a pure widening — a
  #     backtick-decorated command-position `git commit` (e.g. an unquoted
  #     `` `git commit -m x` `` substitution) only ever OVER-counts, which forces
  #     the fail-safe multi-commit fallback (never a new allow). The RESOLUTION
  #     regex (_c3_git_re, bare-git-only) is intentionally left unchanged — only
  #     the COUNTER carries the backtick.
  #
  #     QUOTED ENV-ASSIGNMENT UNDERCOUNT (automated-review finding, PR #128, dbid
  #     3580911797): the COUNTER loop below scans COMMAND_NEUTRALIZED — the SAME
  #     quote-interior-neutralised view the CHECK 3 ENTRY test (line ~783) and
  #     CHECK 0/1/2 (GIT_CMDPOS) use — NOT the raw $COMMAND it scanned before.
  #     Why this was a live BYPASS, not a cosmetic mismatch: the entry test
  #     admitted `FOO="a b" git commit …` (quote-neutralised, so the interior
  #     space becomes `_` and the env-assignment token `[A-Za-z_]*=[^space]*`
  #     matches `FOO="a_b"` as one word), but the counter on RAW $COMMAND could
  #     NOT consume that same prefix — the literal space inside `"a b"` breaks
  #     `[^[:space:]]*`, so `git` was preceded only by a space, not a command
  #     position. In a chain `FOO="a b" git -C <main-repo> commit … && git -C
  #     <feature-repo> commit …` from a MAIN cwd, CHECK 3 ENTERED (first commit)
  #     but the counter's leftmost match anchored only on the `&&` → counted 1 →
  #     no multi-commit fallback → resolution read ONLY the second commit's
  #     feature target and silently ALLOWED the chain, even though the first
  #     commit lands on main. Scanning the counter on COMMAND_NEUTRALIZED makes
  #     its command-position view AGREE with the entry test and the shell's own
  #     tokenisation: the quoted-space env prefix is consumed, BOTH commits are
  #     counted, count>=2 forces the fail-closed fallback to CURRENT_BRANCH (cwd
  #     = main) → BLOCK. TC-PS-160 locks the block; TC-PS-161 locks that a lone
  #     env-prefixed feature commit is NOT over-blocked (single commit → count 1).
  #
  #     Direction guarantee (this fix can only make CHECK 3 MORE conservative for
  #     REAL commits): neutralisation only rewrites characters INSIDE matched
  #     quote pairs. A REAL command-position commit — and its command-position
  #     anchor (`^`/`;`/`&`/`|`/`(`) — lives OUTSIDE quotes, so it is never
  #     touched and stays exactly as countable on COMMAND_NEUTRALIZED as on raw.
  #     The counter therefore never UNDERCOUNTS a real commit; it only stops
  #     spuriously OVER-counting a separator that sits INSIDE a quoted `-m`
  #     message (e.g. `-m "x; git commit y"`, whose interior `;` becomes `_`), so
  #     such an inert message no longer force-fails a single real commit. The
  #     RESOLUTION scan (_c3_scan, below) deliberately stays on the RAW $COMMAND —
  #     neutralising would corrupt a `-C "path with spaces"` value it reads back;
  #     only the COUNTER's source changed. The step-(2) `cd` scan also still
  #     reads the raw _c3_scan, so a `-m "…; cd x"` can still inflate the cd count
  #     (fail-safe over-block) — that path is unchanged by this fix.
  _c3_git_re='(^|[;&|(])[[:space:]]*git[[:space:]]+(((-c|-C)[[:space:]]+[^[:space:]]+[[:space:]]+|--?[^[:space:]]+[[:space:]]+)*)commit([[:space:]]|[;&|)]|$)'
  _c3_commit_count_re='(^|[;&|(])[[:space:]]*(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)|((command|env|sudo|nice|nohup|time|exec)[[:space:]]+'"$LAUNCHER_OPT_RUN"'))*["'\''`\\]?([^[:space:];&|()"'\''`\\]*/)?git["'\'']?[[:space:]]+([^;&|()]*[[:space:]])?commit([[:space:]]|[;&|)]|$)'
  _c3_commit_count=0
  while IFS= read -r _c3_line; do
    _c3_line_rest="$_c3_line"
    while [[ "$_c3_commit_count" -lt 2 && "$_c3_line_rest" =~ $_c3_commit_count_re ]]; do
      _c3_commit_count=$((_c3_commit_count + 1))
      # Consume through the end of this match. The match text is glob-quoted
      # inside the parameter-expansion pattern so glob chars in paths stay
      # literal; leftmost-match means its first literal occurrence IS the
      # match position. The remainder strictly shrinks, so the loop
      # terminates. Note the match's trailing class consumes one separator
      # char, so `commit&&git commit` leaves `&git commit` — the remaining
      # `&` still satisfies the next iteration's `(^|[;&|(])`.
      _c3_line_rest="${_c3_line_rest#*"${BASH_REMATCH[0]}"}"
    done
    [[ "$_c3_commit_count" -ge 2 ]] && break
  done <<< "$COMMAND_NEUTRALIZED"   # quote-neutralised view — see QUOTED ENV-ASSIGNMENT note above (dbid 3580911797)
  if [[ "$_c3_commit_count" -ge 2 ]]; then
    _c3_fail=true
  fi

  # (1) Single LEADING `cd <path>` followed by && or ; at the very start.
  #     String-anchored ^ (bash =~ has no multiline mode) — only a true prefix
  #     counts. Path token stops at whitespace/separators; quoted-with-space
  #     paths simply fail to match here and are caught by (2) below.
  _c3_cd_re='^[[:space:]]*cd[[:space:]]+([^[:space:];&|()]+)[[:space:]]*(&&|;)'
  if [[ "$_c3_scan" =~ $_c3_cd_re ]]; then
    _c3_norm "${BASH_REMATCH[1]}"
    if [[ "$_C3_NORM_FAIL" == "true" ]]; then
      _c3_fail=true
    elif [[ "$_C3_NORM" == /* ]]; then
      _c3_dir="$_C3_NORM"
    else
      _c3_dir="$_c3_dir/$_C3_NORM"
    fi
    _c3_scan="${_c3_scan#"${BASH_REMATCH[0]}"}"   # consume the prefix we handled
  fi

  # (2) Any OTHER command-position `cd` means directory state we can't track
  #     — fall back to the cwd branch (today's behaviour, never a new allow).
  if [[ "$_c3_fail" == "false" ]] && grep -qE '(^|[;&|(])[[:space:]]*cd([[:space:]]|$)' <<< "$_c3_scan"; then
    _c3_fail=true
  fi

  # (3) FIRST command-position `git … commit` match — capture its option run.
  #     Uses _c3_git_re defined in (0). `commit\b` from the grep becomes an
  #     explicit trailing class there: macOS bash 3.2 =~ (POSIX regcomp) does
  #     not support \b. If =~ cannot re-find what grep detected (e.g. git
  #     commit-tree), fall back — never allow. Step (0) already guaranteed at
  #     most ONE command-position commit exists past this point, so the
  #     leftmost match found here is THE commit being judged.
  _c3_run=""
  if [[ "$_c3_fail" == "false" ]]; then
    if [[ "$_c3_scan" =~ $_c3_git_re ]]; then
      _c3_run="${BASH_REMATCH[2]}"   # group 2 = the full option run between git and commit
    else
      _c3_fail=true
    fi
  fi

  # (4) Walk the option-run tokens. -C VALUE chains left-to-right against the
  #     effective dir (git -C semantics); -c consumes its VALUE token; --flags
  #     take no value (mirrors the detection regex's alternation exactly).
  #     Tokens after `commit` are NEVER in _c3_run — `git commit -C HEAD`
  #     (reuse-message option) cannot be mistaken for a directory (TC-PS-50).
  if [[ "$_c3_fail" == "false" && -n "$_c3_run" ]]; then
    read -ra _c3_toks <<< "$_c3_run" || true
    _c3_i=0
    _c3_n=${#_c3_toks[@]}
    while [[ "$_c3_fail" == "false" && "$_c3_i" -lt "$_c3_n" ]]; do
      _c3_t="${_c3_toks[$_c3_i]:-}"
      if [[ "$_c3_t" == "-C" ]]; then
        _c3_i=$((_c3_i + 1))
        _c3_norm "${_c3_toks[$_c3_i]:-}"
        if [[ "$_C3_NORM_FAIL" == "true" || -z "$_C3_NORM" ]]; then
          _c3_fail=true
        elif [[ "$_C3_NORM" == /* ]]; then
          _c3_dir="$_C3_NORM"
        else
          _c3_dir="$_c3_dir/$_C3_NORM"
        fi
      elif [[ "$_c3_t" == "-c" ]]; then
        _c3_i=$((_c3_i + 1))   # -c always takes a separate VALUE token — skip it
      fi
      _c3_i=$((_c3_i + 1))
    done
  fi

  # (5) Validate and read the target branch. Any failure keeps the fail-safe
  #     default (CURRENT_BRANCH). Empty result (detached HEAD) is not main —
  #     allowed, same as the pre-change behaviour for a detached cwd.
  #
  #     Security fix (automated-review PR #122, Finding 1 — correctness): only
  #     overwrite COMMIT_TARGET_BRANCH when `branch --show-current` actually
  #     SUCCEEDS (exit 0). The previous `$(... || echo "")` form treated a
  #     NON-ZERO exit (old git <2.22 without --show-current, a transient git
  #     error, or a corrupted/unusual HEAD ref) the SAME as a
  #     successful-but-empty result (detached HEAD) — both produced an empty
  #     string, which is not "main"/"master", so the deny below was silently
  #     skipped and the commit was ALLOWED. That contradicts this function's
  #     own contract: "any failure keeps the fail-safe default." A genuine
  #     lookup FAILURE must keep CURRENT_BRANCH, not silently clear it —
  #     only a genuine SUCCESS (including a successful empty result, which
  #     legitimately means detached HEAD) may overwrite it.
  #
  #     The assignment lives INSIDE the `if` condition (not assigned first
  #     and checked after) so that under `set -euo pipefail` a non-zero exit
  #     from the command substitution does NOT trip `set -e` and abort the
  #     hook — bash does not apply `set -e` to a command substitution used
  #     directly as an `if`/`while` condition. An aborted hook prints no deny
  #     JSON at all, which is the same silent-allow bug in a different shape.
  if [[ "$_c3_fail" == "false" ]]; then
    if [[ -d "$_c3_dir" ]] && git -C "$_c3_dir" rev-parse --git-dir >/dev/null 2>&1; then
      if _c3_branch=$(git -C "$_c3_dir" branch --show-current 2>/dev/null); then
        COMMIT_TARGET_BRANCH="$_c3_branch"
      fi
      # else: the lookup FAILED (non-zero exit) — keep the CURRENT_BRANCH
      # fail-safe default set above; do NOT overwrite it with an empty string.
    fi
  fi

  if [[ "$COMMIT_TARGET_BRANCH" == "main" || "$COMMIT_TARGET_BRANCH" == "master" ]]; then
    COMMIT_OK_FILE="$STATE_DIR/.commit-on-main-ok"
    COMMIT_APPROVED=false
    if [[ -f "$COMMIT_OK_FILE" ]]; then
      if [[ "$(uname)" == "Darwin" ]]; then
        OK_AGE=$(( $(date +%s) - $(stat -f %m "$COMMIT_OK_FILE") ))
      else
        OK_AGE=$(( $(date +%s) - $(stat -c %Y "$COMMIT_OK_FILE") ))
      fi
      [[ "$OK_AGE" -lt 300 ]] && COMMIT_APPROVED=true
      rm -f "$COMMIT_OK_FILE"   # one-time token, consumed whether fresh or stale
    fi
    if [[ "$COMMIT_APPROVED" == false ]]; then
      jq -n '{
        "hookSpecificOutput": {
          "hookEventName": "PreToolUse",
          "permissionDecision": "deny",
          "permissionDecisionReason": "BLOCKED: this `git commit` targets a repo checked out on main/master (target resolved from `git -C`/leading `cd`, falling back to the call'\''s cwd). All code/doc changes go through a feature branch + PR — never commit to main.\n\nDo this instead:\n1. Create a feature branch: git checkout -b <type>/<slug>\n2. Re-run the commit on that branch\n\nIf the USER explicitly wants this commit on main, the agent must confirm with them first, then: touch ~/.claude/.commit-on-main-ok (valid 300s) and re-run."
        }
      }'
      exit 0
    fi
  fi
fi

# All other pushes (feature branch, no main/master target) and commits are allowed
exit 0
