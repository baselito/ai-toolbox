#!/bin/bash
# auto-poll-after-pr.sh
#
# PostToolUse hook matching on the Bash tool.
# Triggers on TWO events:
#   1. After `gh pr create` — a new PR was just created
#   2. After `git push` to a branch with an open PR — new commits pushed,
#      automated-review will review them and may leave new comments
#
# Creates a pending-marker file in the shared provider-neutral state root that the
# companion PreToolUse hook (enforce-auto-poll.sh) uses to BLOCK subsequent
# Bash calls until auto-poll is registered by the active host. Claude uses
# CronCreate; Codex desktop uses a heartbeat automation.
#
# Why: Rule 4 of workflow-discipline.md requires auto-poll after every PR,
# but the orchestrator forgot in production (multiple incidents). The previous
# version was a passive reminder (stderr) that the agent kept ignoring.
# Additionally, pushing fixes to an existing PR triggers new configured reviewer reviews
# that go unnoticed if auto-poll isn't active.
#
# The hook does NOT create the cron itself — CronCreate is a separate tool
# the agent must call. This hook creates the enforcement trigger.

set -euo pipefail

if ! command -v jq &>/dev/null; then
  exit 0
fi

HOOK_DATA=$(cat)

TOOL_NAME=$(echo "$HOOK_DATA" | jq -r '.tool_name // empty')

if [[ "$TOOL_NAME" != "Bash" ]]; then
  exit 0
fi

COMMAND=$(echo "$HOOK_DATA" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
STDOUT=$(echo "$HOOK_DATA" | jq -r '.tool_result.stdout // empty' 2>/dev/null || echo "")
CALLER_CWD=$(echo "$HOOK_DATA" | jq -r '.cwd // empty' 2>/dev/null || echo "")

# Check if user opted out
if [[ "${NO_AUTO_POLL:-}" == "1" ]]; then
  exit 0
fi

PR_NUMBER=""
OWNER=""
REPO_NAME=""

# --- Trigger 1: gh pr create ---
# Detectors and extractors match with here-strings (`<<<`), never `echo | grep`:
# under `set -euo pipefail` the pipe form can SIGPIPE (141) on large multiline
# input (e.g. a long gh stdout) and kill the hook mid-run, silently skipping
# poll setup (static guard: TC-APP-1).
if grep -qE "gh[[:space:]]+pr[[:space:]]+create" <<< "$COMMAND"; then
  PR_URL=$(grep -oE 'https://github\.com/[^[:space:]]+/pull/[0-9]+' <<< "$STDOUT" | sed -n '1p' || true)
  if [[ -z "$PR_URL" ]]; then
    exit 0
  fi
  PR_NUMBER=$(grep -oE '[0-9]+$' <<< "$PR_URL")
  REPO_PATH=$(echo "$PR_URL" | sed 's|https://github.com/||; s|/pull/[0-9]*$||')
  OWNER=$(echo "$REPO_PATH" | cut -d/ -f1)
  REPO_NAME=$(echo "$REPO_PATH" | cut -d/ -f2)

# --- Trigger 2: git push (to a branch with an open PR) ---
elif grep -qE "git[[:space:]]+push" <<< "$COMMAND"; then
  # Skip pushes to main/master (no PR for those)
  if grep -qE "origin[[:space:]]+(main|master)" <<< "$COMMAND"; then
    exit 0
  fi
  # Skip if push failed — no new commits reached the remote.
  # PostToolUse receives tool_result; check stderr for common failure patterns.
  STDERR=$(echo "$HOOK_DATA" | jq -r '.tool_result.stderr // empty' 2>/dev/null || echo "")
  if grep -qiE "rejected|failed|error|fatal|denied|non-fast-forward" <<< "$STDERR"; then
    exit 0
  fi
  # Quick check: does the PUSHED branch have an open PR?
  # Parse the branch name from the push command so the lookup targets the
  # actual pushed branch, not the currently-checked-out branch. This matters
  # when the agent runs `git push origin other-branch` from a different
  # worktree: previously the hook would resolve the WRONG PR (current branch's
  # PR), creating a stale auto-poll marker for an unrelated PR.
  #
  # Patterns supported (in order of precedence):
  #   git push origin BRANCH           → BRANCH
  #   git push -u origin BRANCH        → BRANCH
  #   git push origin HEAD:BRANCH      → BRANCH (right side of refspec)
  #   git push origin HEAD             → current branch (gh default)
  #   git push                         → current branch (gh default)
  #   git push origin                  → current branch (gh default)
  PUSHED_BRANCH=""
  PUSH_ARGS=$(echo "$COMMAND" | sed -E 's/.*git[[:space:]]+push[[:space:]]*//')
  # Strip option flags:
  #   1. Combined form `--name=value` or `-x=value` → drop whole token (the
  #      `(=([^[:space:]]+))?` part handles `--force-with-lease=refs/heads/main`)
  #   2. Bare flags `--name` / `-xyz` → drop the flag (no value attached)
  # Tokens with separate values (`-o ci.skip`, `--push-option ci.skip`,
  # `--receive-pack rp`) are handled by the next pass which drops the value.
  PUSH_ARGS_NO_FLAGS=$(echo "$PUSH_ARGS" | sed -E 's/(^|[[:space:]])(-[a-zA-Z]+|--[a-z-]+)(=([^[:space:]]+))?([[:space:]]|$)/ /g' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  # Second pass: known separate-value option NAMES that may have appeared as
  # bare-flag matches above are now consumed but their VALUE token remains.
  # Walk tokens; if the previous-emitted token was one of these names, drop
  # the next token too. The original PUSH_ARGS is the source of truth.
  PUSH_ARGS_FILTERED=$(echo "$PUSH_ARGS" | awk '
    BEGIN { skip_next = 0 }
    {
      for (i = 1; i <= NF; i++) {
        if (skip_next) { skip_next = 0; continue }
        t = $i
        # Bare flag forms (already stripped above, but re-skip here for safety)
        if (t ~ /^--[a-z-]+$/ || t ~ /^-[a-zA-Z]+$/) {
          # Known options that consume the next token as a value. Note:
          # `--signed` is a boolean flag (`--signed[=<mode>]`), not a
          # separate-value option — including it here would drop the next
          # positional arg incorrectly for `git push --signed origin BRANCH`.
          if (t == "-o" || t == "--push-option" || t == "--receive-pack" \
              || t == "--repo" || t == "--exec") {
            skip_next = 1
          }
          continue
        }
        # Combined form (already stripped above)
        if (t ~ /^--?[a-zA-Z][a-zA-Z0-9-]*=/) continue
        printf "%s ", t
      }
      print ""
    }
  ' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  PUSH_ARGS_NO_FLAGS="$PUSH_ARGS_FILTERED"
  # Split on whitespace into up to two args.
  ARG1=$(echo "$PUSH_ARGS_NO_FLAGS" | awk '{print $1}')
  ARG2=$(echo "$PUSH_ARGS_NO_FLAGS" | awk '{print $2}')
  if [[ -n "$ARG2" ]]; then
    # "origin BRANCH" or "remote BRANCH" form
    if [[ "$ARG2" == "HEAD" ]]; then
      PUSHED_BRANCH=""  # current branch — let gh default work
    elif [[ "$ARG2" == *":"* ]]; then
      PUSHED_BRANCH="${ARG2#*:}"  # right side of refspec
    else
      PUSHED_BRANCH="$ARG2"
    fi
  elif [[ -n "$ARG1" && "$ARG1" == *":"* \
       && "$ARG1" != *@*:* \
       && "$ARG1" != *"://"* \
       && "$ARG1" != *.git ]]; then
    # Single-arg refspec form: `git push HEAD:other-branch` or
    # `git push +HEAD:other-branch` (force-update via leading +).
    # Git infers the remote from config; we just need the destination branch.
    #
    # URL-pattern exclusions prevent misparsing of common remote URLs:
    #   - `*@*:*` catches `user@host:path` regardless of username
    #     (git@github.com:owner/repo, alice@example.com:repo, etc.)
    #   - `*://*` catches `ssh://`, `https://`, `http://`, `file://`, etc.
    #   - `*.git` catches typical bare-repo URLs ending in .git
    #
    # Accepted residual risk: host-only SCP URLs without a username AND
    # without a `.git` suffix (e.g. `example.com:repo`) would be misparsed
    # as refspecs. We previously tried rejecting LHS containing a dot to
    # catch this, but that broke valid dotted refspecs like
    # `release/1.2:prod` and `v1.2.3:deploy`. Dotted refspecs are more
    # common in practice than host-only SCP URLs without a `.git` suffix,
    # so the dot check has been removed.
    PUSHED_BRANCH="${ARG1#*:}"
  fi
  # Validate: branch name must contain only safe characters. Git branch names
  # can legally contain `+`, `@`, and a few other characters, so we accept a
  # broader set than before — but REFUSE rather than silently falling back to
  # the current branch, which previously let a malformed branch name in one
  # worktree silently attach auto-poll to a different worktree's PR.
  if [[ -n "$PUSHED_BRANCH" ]] && ! [[ "$PUSHED_BRANCH" =~ ^[A-Za-z0-9._/+@-]+$ ]]; then
    # Unsafe characters — exit without setting up auto-poll. Better to skip
    # than to attach to the wrong PR.
    exit 0
  fi

  # gh with a best-effort timeout. `timeout` is NOT installed on stock macOS
  # (the primary dev platform) and neither is `gtimeout` unless coreutils is
  # present — a hardcoded `timeout 5 gh …` returned 127, the `|| echo ""` below
  # swallowed it, PR_JSON came back empty, and this trigger silently no-op'd
  # (the pending marker was never written). Probe for a timeout wrapper and fall
  # back to plain gh (gh has its own network timeouts) when none exists. TC-APP-2.
  # Trade-off: with no wrapper the gh call is unbounded, so a stalled network call
  # can hang this PostToolUse hook. That is strictly better than the previous
  # silent no-op (a hang is visible and interruptible; a skipped marker was not),
  # and gh bounds most failure modes itself; a pure-bash background+kill fallback
  # was judged not worth the complexity for a best-effort auto-poll trigger.
  _gh_timeout() {
    if command -v timeout >/dev/null 2>&1; then
      timeout 5 gh "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
      gtimeout 5 gh "$@"
    else
      gh "$@"
    fi
  }
  if [[ -n "$PUSHED_BRANCH" ]]; then
    PR_JSON=$(_gh_timeout pr view "$PUSHED_BRANCH" --json number,state,url 2>/dev/null || echo "")
  else
    PR_JSON=$(_gh_timeout pr view --json number,state,url 2>/dev/null || echo "")
  fi
  if [[ -z "$PR_JSON" ]]; then
    exit 0
  fi
  PR_STATE=$(echo "$PR_JSON" | jq -r '.state // empty')
  if [[ "$PR_STATE" != "OPEN" ]]; then
    exit 0
  fi
  PR_NUMBER=$(echo "$PR_JSON" | jq -r '.number // empty')
  PR_URL=$(echo "$PR_JSON" | jq -r '.url // empty')
  if [[ -z "$PR_NUMBER" || -z "$PR_URL" ]]; then
    exit 0
  fi
  REPO_PATH=$(echo "$PR_URL" | sed 's|https://github.com/||; s|/pull/[0-9]*$||')
  OWNER=$(echo "$REPO_PATH" | cut -d/ -f1)
  REPO_NAME=$(echo "$REPO_PATH" | cut -d/ -f2)

else
  # Not a PR create or git push — skip
  exit 0
fi

# Validate we got the required fields
if [[ -z "$PR_NUMBER" || -z "$OWNER" || -z "$REPO_NAME" ]]; then
  exit 0
fi

# Check if auto-poll cron already exists for this PR
# ⛔ RESOLVE THE STATE ROOT THE SAME WAY THE READER DOES. ⛔
# enforce-auto-poll.sh (the PreToolUse gate these files arm) reads
# ${AI_ENGINEERING_STATE_DIR:-${CLAUDE_STATE_DIR:-$HOME/.claude}}. This writer
# previously hardcoded $HOME/.claude, so
# under a CLAUDE_STATE_DIR override the writer and the reader used DIFFERENT
# directories and the gate never armed — a guard disabled by a supported
# configuration, with no error anywhere. Same writer/reader split that
# automated-review PR #77 closed for the codex gate; found here by cross-family review.
AP_STATE_DIR="${AI_ENGINEERING_STATE_DIR:-${CLAUDE_STATE_DIR:-$HOME/.claude}}"
CRON_ID_FILE="$AP_STATE_DIR/.pr-${OWNER}-${REPO_NAME}-${PR_NUMBER}-cron-id"

if [[ -f "$CRON_ID_FILE" ]]; then
  # Auto-poll already active — no action needed
  exit 0
fi

# ---------------------------------------------------------------------------
# Declare the PR's TERMINAL OUTCOME to the observed-work sensor.
#
# ⛔ THE OUTCOME, NOT A PROXY, AND NOT BY REMEMBERING. ⛔
# Two PRs once sat finished-but-unmerged for hours while the agent reported "READY"
# as though that were the result. The sensor that exists to catch precisely that did
# not, because every declaration made was DIFF-shaped — fix rounds, review rounds,
# suite counts — and none was the outcome. It was finally declared by hand, after the
# failure, because the agent happened to remember. A guard you must remember is not a
# guard, so it is declared HERE, in the hook that already fires on every PR creation
# and already has the owner, repo and number.
#
# `done_when` is MERGED. Every proxy available during that incident —
# mergeStateStatus=CLEAN, reviewDecision=APPROVED, zero unresolved threads, a green
# suite — was true for hours while the PR stayed open, so none of them can be it.
#
# ⛔ CLOSED WAS IN THIS SET AND HAD TO COME OUT. ⛔ The reasoning for including it
# was sound — a PR that will never merge is equally FINISHED, and the sensor exists
# to notice work that stops. But `done_when` is not only "stop observing": it is the
# predicate `close --outcome shipped` RE-RUNS, and it is the single place a false
# success can enter the permanent record. Measured, with the terminal set
# {MERGED, CLOSED} and a PR closed WITHOUT merging:
#     observe.sh close --id <pr> --outcome shipped
#     -> CLOSED <pr> outcome=shipped done_when_rc=0    (exit 0 — ACCEPTED)
# The same case with `done_when` = MERGED alone is REFUSED (exit 1, CLOSE_REFUSED).
# An abandoned PR recorded as shipped is exactly the failure this mechanism exists
# to make impossible, so terminality does not get to borrow the success gate.
#
# Terminality is covered by the declaration staying RED, not by anything automatic.
# A PR closed unmerged never satisfies `done_when`, so it never reads as done — which is
# the honest record of work that stopped without finishing.
#
# ⛔ AND THE DEADLINE IS NOT SELF-ENFORCING — THIS COMMENT SAID IT WAS, TWICE. ⛔
# `hard_deadline_s` is applied by `checkin`, `probe`, `close`, or a RUNNING watcher.
# Nothing here starts a watcher, and `status` displays an overdue declaration WITHOUT
# enforcing it (observe.sh:1593). So an untouched declaration stays active past its
# deadline indefinitely, with no snapshot. Earlier drafts claimed the deadline "retires
# it with a snapshot", and then — after a first correction — that it stays active only
# "until something observes it". Both overstated; the second more subtly than the first;
# both caught by review rather than by the author.
#
# Best-effort by construction: every path below exits quietly. Observability failing
# must never be a reason a PR does not get created.
# ⛔ RESOLVE THE INSTALL ROOT THE WAY install.sh AND observe.sh BOTH DO. ⛔
# `observe.sh` was taught to find `%APPDATA%\Claude` on Windows; this lookup was
# not, so on an ordinary Windows install the sensor exists and this hook cannot
# see it — and the `-x` test below then skips the whole block WITHOUT A WORD. A
# half-applied fix is worse than none here: the PR-outcome declaration is the one
# guard that exists because remembering to declare by hand had already failed.
_obs_home="${CLAUDE_HOME:-}"
if [[ -z "$_obs_home" ]]; then
  if [[ -n "${APPDATA:-}" && -d "$APPDATA/Claude" ]]; then
    _obs_home="$APPDATA/Claude"
  else
    _obs_home="$HOME/.claude"
  fi
fi
OBSERVE_SH="$_obs_home/scripts/observe.sh"
if [[ ! -x "$OBSERVE_SH" ]]; then
  # Silence is the bad part. Best-effort still means the absence is observable —
  # the same correction already made to the declare failure path below.
  printf 'auto-poll: observe.sh not found at %s — PR #%s was NOT declared to the sensor\n' \
    "$OBSERVE_SH" "$PR_NUMBER" >&2
fi
if [[ -x "$OBSERVE_SH" ]]; then
  _obs_id="pr-${OWNER}-${REPO_NAME}-${PR_NUMBER}"
  # observe.sh deliberately caps ids at 64 characters because each id becomes
  # part of four filesystem paths. GitHub owner/repository names can be longer
  # than the remaining space, so keep a stable, bounded identifier instead of
  # silently skipping the outcome guard for long-named repositories.
  if (( ${#_obs_id} > 64 )); then
    _obs_key="${OWNER}/${REPO_NAME}#${PR_NUMBER}"
    _obs_hash=""
    if command -v shasum >/dev/null 2>&1; then
      _obs_hash=$(printf '%s' "$_obs_key" | shasum -a 256 | awk '{print $1}' || :)
    elif command -v sha256sum >/dev/null 2>&1; then
      _obs_hash=$(printf '%s' "$_obs_key" | sha256sum | awk '{print $1}' || :)
    fi
    if [[ "$_obs_hash" =~ ^[[:xdigit:]]{64}$ ]]; then
      _obs_id="pr-${PR_NUMBER}-${_obs_hash:0:32}"
    else
      _obs_hash=$(printf '%s' "$_obs_key" | cksum | awk '{print $1}' || printf '0')
      _obs_id="pr-${PR_NUMBER}-${OWNER:0:12}-${REPO_NAME:0:30}-${_obs_hash}"
      _obs_id="${_obs_id:0:64}"
    fi
  fi
  _obs_err=$(mktemp "${TMPDIR:-/tmp}/observe-declare.XXXXXX" 2>/dev/null) || _obs_err=""
  # Re-declaring an active id is refused by observe.sh; a push to an existing PR
  # re-runs this hook, so skip quietly rather than emitting a refusal every time.
  # ⛔ USE THE ROOT ALREADY RESOLVED ABOVE — DO NOT RE-DERIVE IT. ⛔ This guard used
  # to write `${CLAUDE_HOME:-$HOME/.claude}/…` for itself, which drops the APPDATA
  # branch the block twelve lines up exists to add. On an ordinary Windows install
  # the guard could then never match, so `declare` re-fired on every push and
  # observe.sh emitted a refusal each time — the exact thing the sentence above
  # claims this prevents. Same defect class, same block, as the `-x` lookup: a fix
  # applied to one of two derivations. Regression: verify-hooks.sh TC-APP-4/5.
  if [[ ! -f "$_obs_home/observer/active/${_obs_id}.json" ]]; then
    # ONE `gh` call, not two. Two sequential calls doubled the latency inside a 30s
    # probe bound (measured 1.36s combined, 0.6s each), and left a window in which
    # the state could change between them — a predicate that reads its subject twice
    # can answer about two different subjects.
    _obs_done="test \"\$(gh pr view ${PR_NUMBER} --repo ${OWNER}/${REPO_NAME} --json state --jq .state 2>/dev/null)\" = MERGED"
    # The probe must move DURING the work, not only at the end: head sha moves on a
    # push, reviewDecision moves when a review round lands. A probe that only changed
    # at the finish reported a busy agent as stalled for an hour once.
    #
    # ⛔ mergeStateStatus IS DELIBERATELY NOT IN HERE, AND THE REASON IS A RISK RATHER
    # THAN A MEASURED FAILURE — stated that way on purpose. ⛔ GitHub computes
    # mergeability asynchronously, so the field can move with no work behind it. What
    # was actually measured here: on a long-merged PR it returned UNKNOWN on four
    # consecutive runs and `declare` ACCEPTED the three-field probe. There was no open
    # PR available to test the case that matters — a freshly created one, which is
    # exactly when this hook fires and when the field is most likely to settle from
    # UNKNOWN to CLEAN/BLOCKED.
    #
    # It is dropped because it can only cost and cannot pay: if it does flip, `declare`
    # runs the probe twice back-to-back and REJECTS the whole declaration (the guard
    # against `--progress-probe 'date +%s'`), and a later flip reports delta=1 with
    # nothing done — the false-progress case the delta exists to catch. Against that,
    # it adds no signal the other two fields lack: head sha moves on a push,
    # reviewDecision moves on a review, and both move only when someone acts.
    _obs_probe="gh pr view ${PR_NUMBER} --repo ${OWNER}/${REPO_NAME} --json headRefOid,reviewDecision --jq '[.headRefOid[0:8],.reviewDecision]|@tsv' 2>/dev/null"
    _obs_declare() {
      OBSERVER_ROOT="$AP_STATE_DIR/observer" "$OBSERVE_SH" declare --id "$_obs_id" \
      --intent "PR #${PR_NUMBER} on ${OWNER}/${REPO_NAME} is MERGED — the outcome, not merge-readiness. A PR closed without merging never satisfies this and stays RED, which is the honest record of work that stopped without finishing. Retirement is NOT automatic: nothing starts a watcher, and status displays an overdue declaration without enforcing it, so the deadline is applied only by checkin, probe, close, or a running watcher — an untouched declaration stays active past its deadline indefinitely" \
      --done-when "$_obs_done" \
      --progress-probe "$_obs_probe" \
      --checkin-every-s 900 --hard-deadline-s 21600 --max-rounds 20 \
      --pr "${OWNER}/${REPO_NAME}#${PR_NUMBER}"
    }
    if [[ -n "$_obs_err" ]]; then
      _obs_declare >/dev/null 2>"$_obs_err" || {
        # ⛔ BEST-EFFORT MUST NOT MEAN SILENT. ⛔ `>/dev/null 2>&1 || true` swallowed
        # every rejection — an id over 64 characters, a `gh` call that timed out, a
        # probe `declare` judged unstable. The point of declaring HERE rather than by
        # hand is that a guard you must remember is not a guard; a guard that fails
        # invisibly is the same thing wearing a hook. One line to stderr, so the
        # absence is observable. It still never blocks the PR.
        printf 'auto-poll: could not declare the PR outcome to observe.sh: %s\n' \
          "$(head -1 "$_obs_err" 2>/dev/null)" >&2
      }
      rm -f "$_obs_err" 2>/dev/null
    else
      _obs_declare_err=$(_obs_declare 2>&1 >/dev/null) || {
        printf 'auto-poll: could not declare the PR outcome to observe.sh (temporary error capture unavailable): %s\n' \
          "$(printf '%s\n' "$_obs_declare_err" | head -1)" >&2
      }
    fi
  fi
fi

# Create pending marker — enforce-auto-poll.sh (PreToolUse) will block
# subsequent Bash calls until the cron-id file exists.
AP_STATE_DIR="${AI_ENGINEERING_STATE_DIR:-${CLAUDE_STATE_DIR:-$HOME/.claude}}"
# Bind the obligation to the originating checkout. Hooks launched by a desktop
# app can have a stale process PWD, so use the event payload's cwd and resolve
# the Git top-level from there. A blank value is deliberately fail-closed by
# enforce-auto-poll; it is never treated as permission to bypass the gate.
POLL_WORKTREE=""
POLL_HEAD=""
if [[ -n "$CALLER_CWD" && -d "$CALLER_CWD" ]]; then
  POLL_WORKTREE=$(git -C "$CALLER_CWD" rev-parse --show-toplevel 2>/dev/null || true)
  POLL_HEAD=$(git -C "$CALLER_CWD" rev-parse HEAD 2>/dev/null || true)
  if [[ -n "$POLL_WORKTREE" ]]; then
    POLL_WORKTREE=$(cd "$POLL_WORKTREE" 2>/dev/null && pwd -P || true)
  fi
fi
# Include the resolved checkout in the marker name. A PR can be handled from
# multiple linked worktrees; a repo/PR-only filename lets one PostToolUse hook
# overwrite another worktree's still-unregistered obligation. The digest is
# only a filename key; the authoritative path remains in the marker content.
if [[ -n "$POLL_WORKTREE" ]]; then
  if command -v shasum >/dev/null 2>&1; then
    POLL_WORKTREE_KEY=$(printf '%s' "$POLL_WORKTREE" | shasum -a 256 | awk '{print substr($1,1,16)}')
  elif command -v cksum >/dev/null 2>&1; then
    # cksum is present on the minimal POSIX environments supported by the
    # installer. It is only a collision-resistant-enough filename key; the
    # marker's worktree field remains the source of truth for ownership.
    POLL_WORKTREE_KEY=$(printf '%s' "$POLL_WORKTREE" | cksum | awk '{print $1}')
  elif command -v od >/dev/null 2>&1 && command -v awk >/dev/null 2>&1; then
    # Keep this fallback bounded so the marker remains within common filename
    # limits, while hashing every byte so paths sharing a prefix do not simply
    # collapse to the same truncated key. The two independent 1e9-sized
    # rolling hashes fit exactly in awk's portable integer precision.
    POLL_WORKTREE_KEY=$(LC_ALL=C printf '%s' "$POLL_WORKTREE" | od -An -tu1 | awk '
      BEGIN { h1=146959; h2=109951 }
      {
        for (i=1; i<=NF; i++) {
          h1=(h1*257+$i)%1000000007
          h2=(h2*263+$i)%1000000009
        }
      }
      END { printf "%09d%09d", h1, h2 }
    ')
  else
    printf 'auto-poll: no supported worktree-key utility (shasum, cksum, or od+awk) for %s#%s\n' "$OWNER/$REPO_NAME" "$PR_NUMBER" >&2
    exit 1
  fi
else
  POLL_WORKTREE_KEY="unknown"
fi
PENDING_FILE="$AP_STATE_DIR/.auto-poll-pending-${OWNER}-${REPO_NAME}-${PR_NUMBER}-${POLL_WORKTREE_KEY}"
PENDING_TMP=$(mktemp "$AP_STATE_DIR/.auto-poll-pending.XXXXXX" 2>/dev/null || true)
if [[ -z "$PENDING_TMP" ]]; then
  printf 'auto-poll: could not create pending marker for %s#%s\n' "$OWNER/$REPO_NAME" "$PR_NUMBER" >&2
  # A successful PostToolUse result here would falsely report that the PR
  # entered the polling lifecycle. Fail the hook so the host records the
  # infrastructure failure instead of silently leaving the PreToolUse gate
  # unarmed.
  exit 1
fi
printf 'repo=%s\npr=%s\nworktree=%s\nhead=%s\n' \
  "${OWNER}/${REPO_NAME}" "$PR_NUMBER" "$POLL_WORKTREE" "$POLL_HEAD" > "$PENDING_TMP"
chmod 600 "$PENDING_TMP"
mv -f "$PENDING_TMP" "$PENDING_FILE"

# Determine trigger context for the message
if grep -qE "gh[[:space:]]+pr[[:space:]]+create" <<< "$COMMAND"; then
  TRIGGER="PR #${PR_NUMBER} created"
else
  TRIGGER="New commits pushed to PR #${PR_NUMBER} — automated-review will review"
fi

# Output reminder to agent context so the agent knows what to do
echo "" >&2
echo "⛔ AUTO-POLL REQUIRED — ${TRIGGER} on ${OWNER}/${REPO_NAME}." >&2
echo "All Bash commands are BLOCKED until auto-poll is set up." >&2
echo "Rule 4 (workflow-discipline.md) requires auto-poll. Register it with the active host:" >&2
echo "" >&2
echo "  CronCreate(" >&2
echo "    cron:      \"*/1 * * * *\"," >&2
echo "    prompt:    \"/review-pr --repo ${OWNER}/${REPO_NAME} ${PR_NUMBER} --auto\"," >&2
echo "    recurring: true," >&2
echo "    durable:   true" >&2
echo "  )" >&2
echo "" >&2
echo "Claude: save the returned ID with: echo \"\$CRON_ID\" > ${CRON_ID_FILE}" >&2
echo "Codex desktop: create a 1-minute heartbeat for this PR, then run:" >&2
echo "  \$HOME/.codex/bin/register-pr-poll.sh --repo ${OWNER}/${REPO_NAME} --pr ${PR_NUMBER} --provider codex --poll-id <automation-id>" >&2
echo "To opt out: rm ${PENDING_FILE}" >&2
echo "" >&2

exit 0
