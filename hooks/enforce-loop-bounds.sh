#!/bin/bash
# enforce-loop-bounds.sh
#
# PreToolUse hook. Makes the FIRST of the three loop guards structural instead
# of aspirational: **every loop declares its own bound at the moment it is
# created.** Doctrine for all three guards (iteration ceiling, no-progress
# detector, spend cap): the `loop-design` skill.
#
# WHY A HOOK AND NOT PROSE:
#   The toolbox had the pieces and no class. `commands/review-pr.md` carries
#   MAX_RETRIES=2/COOLDOWN=300, the auto-poll cron carries a 1-day cap, and
#   `skills/codex-review` carries a spend cap — three one-off instances, so
#   every new loop either reinvented a bound or shipped without one. A loop
#   with no bound is the one defect class that costs money while nobody is
#   watching, which is exactly the situation instructions do not survive.
#
# THREE DETECTORS, deliberately narrow:
#
#   A. CronCreate self-termination. A RECURRING scheduled job must run a prompt
#      the toolbox has registered as self-terminating. The registry lives in
#      this file (see SELF_TERMINATING_PROMPTS below) — one trust level above
#      any project file, same reasoning as the verification registry in the
#      `workflow-discipline` skill §1c. An unregistered recurring prompt is
#      DENIED; a one-shot is allowed because a job that runs once is bounded by
#      construction. "One-shot" means a genuine JSON boolean `recurring: false`
#      and nothing else — a non-boolean flag is not readable as "does not
#      repeat", so it goes down the recurring path.
#
#   B. `/goal` turn bound. A `/goal` condition that SETS a goal must carry both
#      mandatory clauses from `commands/flow.md` → "`/goal` — Machine-Checkable
#      Phase Exits": a turn clause ("... or after N turns") and a no-progress
#      clause ("... N consecutive iterations"). `/goal` carries no cap of its
#      own, so a condition without a turn clause IS an unbounded loop — and in
#      an interactive session (no `--max-budget-usd`) those two clauses are the
#      whole budget. Both numbers are also checked against the ceilings in the
#      `workflow-discipline` skill §1d.
#
#   C. `/loop` bound (issue #146). The same two clauses, in the same
#      vocabulary, required of the harness's own loop primitive — which is
#      invoked through the Skill tool this hook already matches, so it was in
#      the path all along and simply had no detector. A and B bounded the two
#      loop kinds the TOOLBOX invented and left unbounded the one the HARNESS
#      provides. Measured while writing this: `CLAUDE_CODE_MAX_TURNS` and
#      `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` are unset and set by no toolbox
#      script, so a `/loop` had no ceiling from any layer.
#
# WHICH TOOLS THIS FIRES ON (hooks/hooks-config.json): `CronCreate` and `Skill`.
#   Bash is deliberately NOT a matcher. Detector B searches the whole tool
#   input, so matching Bash would block every `cat`/`grep` of a toolbox file
#   that merely QUOTES a `/goal` example — including this repo's own docs. The
#   cost of that exclusion is stated honestly rather than hidden: a `/goal`
#   the USER types, or one a future runtime routes through an unmatched tool,
#   is NOT observable here. For those the bound stays flow.md's requirement and
#   compliance check 14's audit (which reads the recorded bound out of the
#   handover entry). This hook closes the paths it can see; it is not claimed
#   to close all of them.
#
# FAIL DIRECTION — CLOSED, on every ambiguity:
#   * `jq` missing                            → deny (same as every other gate here)
#   * CronCreate whose prompt cannot be read  → deny (an unreadable prompt has no provable bound)
#   * CronCreate recurring, prompt unregistered → deny (fail-closed-on-unknown-key, as §1c)
#   * CronCreate whose `recurring` is not a boolean → treated as recurring, so the
#                                               registry check decides (usually deny)
#   * a `/goal` set whose bounds do not parse → deny
#   * a `/loop` missing either clause, out of range, or with no arguments → deny
#   * anything else (no CronCreate, no `/goal`, no `/loop`) → exit 0, no-op
#   The asymmetry is intentional. An over-block costs one re-worded tool call;
#   an under-block costs an unattended loop spending real money with nothing
#   stopping it. ACCEPTED RESIDUAL: a `Skill`/`CronCreate` payload that merely
#   quotes an unbounded `/goal` example is denied. Re-word it, or put the text
#   in a file.
#
#   TWO HONEST EXCEPTIONS to "closed on every ambiguity". Both rest on the
#   harness emitting well-formed hook input — an integrity assumption about our
#   own runtime, not a boundary defended against an adversary. (Checked: the
#   only field adversary-controlled content can reach is `tool_input.command`,
#   a JSON string value, which is escaped by the serialiser. Six payloads
#   engineered to break a naive serialiser — unbalanced braces, an embedded
#   `"tool_name"`, embedded newlines, nested JSON, a NUL, invalid UTF-8 — all
#   produced valid JSON and zero aborts.) The claims above describe SEMANTIC
#   ambiguity in a well-formed payload, which is what this hook is for.
#
#   (1) A payload that is not a readable JSON OBJECT reaches ALLOW, because
#   both `jq` reads yield empty strings and neither detector then has anything
#   to match. ⛔ THIS USED TO SAY "not parseable JSON at all" — measured, the
#   class is WIDER than that: VALID json that is an array (`[]`) or a string
#   (`"aString"`) aborts identically, since the failure is `jq` indexing a
#   non-object, not a parse error. ABORT=11 FALL-THROUGH=3 DENY=0 for all three
#   spellings. A residual described one notch narrower than it is has the same
#   defect in miniature as an unnamed one.
#
#   (2) An ABSENT or RENAMED `tool_name` disarms all FOURTEEN, and this was
#   named nowhere before. Every gate's first act is
#   `[[ "$TOOL_NAME" != "Bash" ]] && exit 0`, so a payload of `{}` — or empty
#   stdin — makes every one of them a silent no-op. Measured: `{}` and empty
#   stdin both give ABORT=0 FALL-THROUGH=14 DENY=0. That is QUIETER than the
#   abort class above (exit 0, no stderr at all) and correspondingly harder to
#   notice, which is the opposite of what the severity ordering should be. If
#   the harness ever renames or omits that field, the entire enforcement layer
#   becomes a no-op with no signal anywhere.
#
#   THIS PARAGRAPH USED TO CLAIM "that is the behaviour of EVERY PreToolUse
#   gate in this directory". Measured across the fourteen PreToolUse hooks
#   hooks-config.json registers: ELEVEN do not fall through at all. They ABORT
#   under `set -euo pipefail` on an unguarded `jq` read — exit 5, a parse error
#   on stderr, no JSON. The claim was false by eleven, and it is exactly the
#   kind of "every X does Y" line that reads as a guarantee and was never
#   measured.
#
#   What IS uniform, and is what matters for the fail direction: NO PreToolUse
#   gate here emits a deny on unparseable input, so none of them BLOCKS — the
#   aborting eleven get there by dying rather than by deciding, and a non-zero
#   exit that is not 2 does not block. TC-M2-1 pins that uniformity over the
#   registered list, and it is deliberately not a test that they all exit 0
#   (that would enshrine eleven aborts as intended) nor that they all deny.
#   Flipping the direction to deny is still a change to make to all fourteen at
#   once, never to this one alone — and TC-M2-1 is now what tells you which
#   ones you missed.
#
# All detectors match with here-strings (`<<<`), never `echo | grep`: under
# `set -euo pipefail` the pipe form can SIGPIPE (141) on large input and flip a
# deny into an allow. Same rule and same reason as the other gates in this
# directory; scripts/verify-hooks.sh asserts it statically.

set -euo pipefail

# Fail CLOSED when jq is missing — consistent with every other PreToolUse gate
# here. Without jq we cannot parse the hook input or emit a structured deny, so
# allowing would silently disarm the whole layer.
if ! command -v jq &>/dev/null; then
  # Spaces after the colons are deliberate. The harness assertion in
  # scripts/verify-hooks.sh greps for `"permissionDecision": "deny"`, so the
  # compact spelling the older hooks use here is invisible to it — which is why
  # none of their jq-missing paths is actually covered by a test. Emitting the
  # spaced form is what makes TC-ELB-19 a real assertion rather than a comment.
  cat <<'__DENY__'
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "BLOCKED: jq is required for hook enforcement (enforce-loop-bounds). Install jq (brew install jq / apt install jq / yum install jq) to continue. Hook fails closed for safety."}}
__DENY__
  exit 0
fi

HOOK_DATA=$(cat)
TOOL_NAME=$(jq -r '.tool_name // empty' <<< "$HOOK_DATA" 2>/dev/null || echo "")

# ---------------------------------------------------------------------------
# Toolbox-owned ceilings. MUST stay equal to the `workflow-discipline` skill
# §1d table, which is the single documented source of truth for the numbers.
# scripts/verify-hooks.sh cross-checks these two literals against that table,
# so a drift in either direction fails the build rather than quietly widening
# a bound. Not settable from PROJECT.md, by design: a knob that bounds
# unattended behaviour must not be raisable through a project PR.
# ---------------------------------------------------------------------------
TURNS_CEILING=60
NO_PROGRESS_CEILING=5

# emit_deny <reason> — print the deny JSON and exit. Always exits 0: a hook's
# own exit code is not the decision channel, the JSON is.
emit_deny() {
  jq -n --arg reason "$1" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": $reason
    }
  }'
  exit 0
}

# ---------------------------------------------------------------------------
# The two mandatory clauses, extracted ONCE and shared by detectors B and C.
#
# WHY FUNCTIONS AND NOT TWO COPIES: detector C (`/loop`) checks the same two
# clauses in the same vocabulary as detector B (`/goal`). Two inline copies of
# these regexes would be two things to keep equal, and the failure mode of them
# drifting is silent — one loop kind quietly accepting a spelling the other
# rejects. One definition, two callers.
#
# awk's match() is used rather than `grep -o … | head -1`: the pipe form can
# SIGPIPE under pipefail, and a greedy sed capture would silently take the LAST
# match. Digit runs are length-capped so an absurd literal cannot overflow the
# arithmetic in the callers — an over-long number simply fails to match and is
# then treated as a MISSING clause, which denies. Fail-closed either way.
# Both print the empty string when there is no match; neither ever fails.
#
# THE CAP IS LOAD-BEARING, not tidiness, and it is now pinned (TC-ELB-55/56/57).
# `10#18446744073709551641` evaluates to 25 in bash — a 64-bit wrap that lands
# INSIDE both ceilings — so without `length(s) <= 9` an absurd literal would
# read as a legitimate bound and the range check would wave it through. It
# affects `/goal` as well as `/loop`, because both detectors call these.
#
# ACCEPTED RESIDUAL, named rather than implied (rules/security.md item 7):
# these clauses match ANYWHERE in the text, so INCIDENTAL PROSE counts as a
# declared bound — "I gave up after 3 turns of this" satisfies the turn clause.
# The check is that a bound was WRITTEN DOWN, not that it was written down in
# the right grammatical role; distinguishing those needs a parser, and the
# failure direction of the gap is a loop that carries a real number it did not
# mean rather than a loop with no number at all. Not closed here.

# _clause_turns <text> — the iteration ceiling, e.g. "... or after 25 turns".
_clause_turns() {
  awk 'match($0, /[Aa]fter [0-9]+ turns?/) { s = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); if (length(s) <= 9) print s; exit }' <<< "$1"
}

# _clause_no_progress <text> — the no-progress detector, e.g. "... the same
# failure survives 2 consecutive iterations".
_clause_no_progress() {
  awk 'match($0, /[0-9]+ consecutive iterations?/) { s = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); if (length(s) <= 9) print s; exit }' <<< "$1"
}

# ===========================================================================
# Detector A — a recurring CronCreate needs a registered self-termination
# ===========================================================================
if [[ "$TOOL_NAME" == "CronCreate" ]]; then
  CRON_PROMPT=$(jq -r '.tool_input.prompt // empty' <<< "$HOOK_DATA" 2>/dev/null || echo "")
  # `recurring` is read through a TYPE GATE, not through its value: ONLY a
  # genuine JSON boolean `false` is treated as a one-shot. Everything else —
  # absent, null, a string, a number, an object, an array — reads as "we could
  # not tell whether this repeats" and falls through to the registry check
  # below, which is the fail-CLOSED direction.
  #
  # Two traps live on this one line, and each shipped once:
  #   * `.recurring // "absent"` failed CLOSED but wrongly: jq's alternative
  #     operator fires on `false` as well as `null`, so it maps an explicit
  #     `recurring: false` to "absent" and DENIES a legitimate one-shot job
  #     (TC-ELB-4).
  #   * `if has("recurring") then (.recurring | tostring)` failed OPEN, which is
  #     worse: `tostring` renders the JSON *string* `"false"` as the same
  #     `false` a boolean does, so a payload carrying `recurring: "false"` was
  #     classified one-shot and never reached the registry check at all
  #     (TC-ELB-32). That is the one direction the FAIL DIRECTION block above
  #     says this hook never takes, and it is not type-pedantry: a JS/TS
  #     scheduler treats the NON-EMPTY string "false" as TRUTHY, so it can
  #     register the job as RECURRING after this hook has already waved it
  #     through as a job that runs once.
  # Gating on `(.recurring | type) == "boolean"` before reading the value is
  # what makes the value trustworthy: it is consulted only when it means what
  # it says. TC-ELB-32/33/34/35 cover string/number/object payloads.
  CRON_RECURRING=$(jq -r '(.tool_input // {}) | if (.recurring | type) == "boolean" then (.recurring | tostring) else "non-boolean" end' <<< "$HOOK_DATA" 2>/dev/null || echo "non-boolean")

  # A one-shot job (`recurring: false`) needs no registry entry — its REPETITION
  # is bounded by construction. It does NOT skip the rest of this hook, and that
  # distinction matters: the earlier `exit 0` here meant a cron firing ONCE could
  # launch a completely UNBOUNDED `/goal` loop and detector B never saw it. "Runs
  # once" bounds how often the job starts, not how long it then runs.
  if [[ "$CRON_RECURRING" != "false" ]]; then

  if [[ -z "$CRON_PROMPT" ]]; then
    emit_deny "BLOCKED: recurring CronCreate with no readable prompt (enforce-loop-bounds, guard 1 — iteration ceiling).

A recurring job whose prompt cannot be read has no provable self-termination, so this hook cannot tell a bounded loop from an unbounded one and fails closed.

Pass the prompt as \`prompt:\`, or schedule the job with \`recurring: false\` if it should run once."
  fi

  # -------------------------------------------------------------------------
  # SELF_TERMINATING_PROMPTS — the toolbox-owned registry.
  #
  # An entry means: the toolbox has an IMPLEMENTED, documented mechanism that
  # ends this recurring job, and the entry names where it lives so a reader can
  # go check it. This is a registry and not a regex-for-anything-that-looks-
  # bounded on purpose: the whole point of the guard is that the bound has been
  # reviewed once, in the toolbox, rather than asserted at the call site.
  #
  #   /review-pr … --auto
  #     Terminates three ways: `/review-pr` Step 0.5 refuses an `--auto` run
  #     whose ~/.claude/.pr-<owner>-<repo>-<N>-cron-created stamp is older than
  #     one day; the run self-terminates when the PR is merged or closed; and a
  #     session cron expires with the session anyway. `--auto` is REQUIRED
  #     because the 1-day cap is keyed on that flag — an auto-poll cron without
  #     it is the unbounded variant of the same prompt.
  #
  # Adding an entry is a toolbox PR, and the bound has to exist in code first.
  # -------------------------------------------------------------------------
  # The registry match is a WHOLE-PROMPT SHAPE-AND-VOCABULARY check, not a token
  # search. After line endings are folded to a blank (see CRON_ONE_LINE below),
  # exactly two things are required of that one string:
  #   (a) it consists of nothing but `/review-pr` followed by argument groups
  #       drawn from a FIXED VOCABULARY — `--auto`, `--repo <owner>/<repo>` (the
  #       slug halves being [A-Za-z0-9_.-]), or a bare integer (the PR number);
  #       and
  #   (b) `--auto` is one of those blank-delimited tokens.
  # Anything else anywhere in the prompt is outside the vocabulary, so the
  # prompt does not match and the cron is DENIED: an unrecognised flag
  # (`--help`, `--message`, `--repo=o/r`), a bare word, a second slash command,
  # a shell operator (`;` `&&` `||` `|` `&`), a quote, a backslash (including a
  # trailing line-continuation), a backtick, `$`, `(`/`)`, a redirection
  # (`<` `>`), a glob, a free-floating `owner/repo` slug not introduced by
  # `--repo`, a control character that is not a line ending (`\v`, `\f`, or a
  # lone `\r` INSIDE the prompt — those are not legal separators), or a second
  # line of instructions.
  #
  # TWO RESIDUALS THIS CHECK DOES NOT CLOSE — named here because this comment
  # has now been corrected three times for claiming more than the code does,
  # and an unnamed residual is how that keeps happening:
  #   - A *trailing* lone `\r` IS accepted, unlike a mid-prompt one. It is
  #     stripped below (see the CRLF note) because command substitution eats the
  #     `\n` of a trailing CRLF and strands the `\r` on an otherwise canonical
  #     prompt. Safe because a trailing `\r` has nothing behind it to hide a
  #     rider; the strip is `%` (one char) and never `%%…*` (which would
  #     truncate at the FIRST `\r` and silently discard a rider).
  #   - The VALUE after `--repo` is an unconstrained `owner/repo`-shaped slug,
  #     so `--repo grind-the-backlog-forever/and-ever --auto` is ALLOWED. Prose
  #     riders are rejected as bare words but survive if they wear one slash and
  #     sit immediately after `--repo`. Inert as a loop — the scheduled command
  #     is still `/review-pr … --auto`, which Step 0.5 caps at 1 day — so this
  #     is a precision gap, not a fail-open. Constraining it means validating a
  #     GitHub owner/repo grammar here, which is a registry-design change.
  #
  # WHY A VOCABULARY AND NOT TWO TOKEN GREPS — five weaker versions shipped, and
  # each certified a command the job never ran:
  #   1. Two free-floating "does this token appear anywhere" greps allowed
  #      "grind on the backlog forever ; /review-pr --auto is not what this
  #      does" (TC-ELB-26).
  #   2. Anchoring only the `/review-pr` conjunct to the first line, with
  #      `--auto` still searched over the WHOLE prompt, allowed a first line
  #      running an UNREGISTERED form (`/review-pr --help`) to be certified by an
  #      `--auto` sitting in prose on a later line (TC-ELB-28).
  #   3. Tying both conjuncts to the first line but treating EVERY token on it as
  #      an argument of the command allowed
  #      "/review-pr --help ; run-unbounded-loop forever --auto" — an
  #      unregistered invocation plus a shell-chained unbounded command,
  #      certified by an `--auto` belonging to neither (TC-ELB-30) — and
  #      "/review-pr --repo o/r 5 --message \"not --auto really\"", where the
  #      certifying token sat inside another flag's quoted value (TC-ELB-31).
  #   4. Accepting ANY token built from [A-Za-z0-9_./:=@,+-] as an argument left
  #      the prompt an open instruction channel, because a cron prompt is text an
  #      agent reads, not a string a shell execs. It allowed a rider that is
  #      itself a slash command, "/review-pr --auto /loop 1m
  #      grind-the-backlog-forever" (TC-ELB-36); arbitrary hyphen-joined prose,
  #      "/review-pr --auto and-then-loop-forever-with-no-bound" (TC-ELB-37);
  #      and an UNREGISTERED invocation wearing a valid flag, "/review-pr --help
  #      --auto" (TC-ELB-41) — where `/review-pr` prints help and never reaches
  #      the Step 0.5 cap that is the whole reason `--auto` is required.
  #   5. Judging the FIRST LINE only left lines 2..n unchecked by this detector,
  #      so "/review-pr --repo o/r 5 --auto" plus a second line of "then keep
  #      grinding forever" was certified (TC-ELB-40) — and because `[[:space:]]`
  #      matches CR/TAB/VT/FF while only `\n` split the line, a rider hidden
  #      behind an invisible CR read as a mere argument (TC-ELB-38/39).
  # What the registry certifies is THE COMMAND THE JOB RUNS, and a cron's prompt
  # IS that command, so the whole prompt has to BE the command and nothing else,
  # with `--auto` among its own arguments. Flag ORDER stays free: `--auto --repo
  # o/r 5` and `--repo o/r 5 --auto` both match (TC-ELB-29), as does the legacy
  # bare-PR form `/review-pr 5 --auto` (TC-ELB-42).
  #
  # WHAT THIS CHECK DOES NOT DO — the residuals, stated so a future reader does
  # not have to rediscover them:
  #   * It does not parse shell grammar and does not understand quoting, so it
  #     cannot tell a harmless quoted argument from a dangerous one. It rejects
  #     the whole prompt the moment anything outside the vocabulary appears,
  #     which over-blocks a legitimate quoted argument on purpose.
  #   * The vocabulary is a WHITELIST of exactly the argument forms the toolbox's
  #     own auto-poll constructions emit (`skills/pr-automation`,
  #     `skills/finishing-a-development-branch`, `hooks/auto-poll-after-pr.sh`,
  #     `hooks/enforce-auto-poll.sh`). A future `/review-pr` flag that belongs in
  #     a cron prompt is DENIED until it is added here — deliberately, and it is
  #     a coupling: the PR that adds such a flag has to widen this list too.
  #   * It does not check arity or repetition: `--auto --auto` and several bare
  #     integers all match. Both are inert — a duplicated flag and a stray number
  #     carry no instruction — so the check does not spend precision there.
  #   * It certifies only that the SCHEDULED PROMPT is this command. That the
  #     command then self-terminates is the registry's claim, resting on
  #     /review-pr Step 0.5, not on anything this hook can observe.
  #   * Detector A sees only `CronCreate` payloads. A loop created any other way
  #     is out of scope here — see WHICH TOOLS THIS FIRES ON at the top.
  #
  # Fold LINE ENDINGS — CRLF and LF — to a blank BEFORE matching, so the `^`/`$`
  # anchors below apply to the whole prompt instead of to whichever line grep
  # happens to be looking at. This is what makes "the prompt IS the command"
  # checkable: a second line of instructions becomes extra tokens on the one
  # line, and extra tokens are not in the vocabulary (TC-ELB-40). Pure parameter
  # expansion, no subprocess.
  #
  # A LONE `\r`, `\v` or `\f` is deliberately NOT folded. Folding it would
  # WEAKEN the check: it would promote a byte that is currently out-of-class —
  # and so a hard DENY on its own, whatever the vocabulary happens to allow — into
  # a legal separator, leaving the rider behind it for the vocabulary alone to
  # catch. Verified by patching: with the fold widened to `[$'\n\r\v\f']` and the
  # vocabulary reverted, "/review-pr --auto\rrider-forever" goes back to ALLOW;
  # with a lone `\r` left in place it does not. None of the three is a line
  # ending anything in this toolbox emits (lone-CR was classic Mac OS 9's, and
  # nothing here writes it), so nothing legitimate is lost. CRLF *is* one, hence
  # the first substitution.
  #
  # Separators are `[[:blank:]]` (space and tab), NOT `[[:space:]]`: the wider
  # class also matches CR/VT/FF, which is precisely how a rider used to hide
  # behind an invisible control character while only `\n` actually split the line
  # (TC-ELB-38).
  #
  # NOTE on trailing whitespace: the `[[:blank:]]*` anchors at both ends tolerate
  # leading and trailing SPACES and TABS (TC-ELB-43). A trailing NEWLINE is
  # tolerated too, but by two mechanisms rather than one, and it is worth knowing
  # which fires: `CRON_PROMPT=$(jq -r …)` strips trailing newlines the way all
  # command substitution does, so the newline never reaches this matcher at all —
  # and had it survived, the fold above would turn it into a blank that the
  # trailing anchor accepts anyway. Verified by patching: removing EITHER
  # mechanism alone still allows a trailing newline; removing both denies it
  # (TC-ELB-43b).
  #
  # That stripping is also why the LAST substitution below exists. On a prompt
  # ending in CRLF, command substitution eats the `\n` before this code runs, so
  # the `\r\n` fold never sees a pair — a lone `\r` is left stranded at the end
  # and would deny an otherwise canonical prompt. Dropping ONE trailing `\r`
  # fixes that and cannot reopen a rider, because a trailing `\r` by definition
  # has nothing behind it. It is `%` (remove one trailing `\r`), never `%%…*`:
  # the latter would truncate the string at the FIRST `\r` and throw a rider
  # away, turning a deny into an allow.
  CRON_ONE_LINE="${CRON_PROMPT//$'\r\n'/ }"
  CRON_ONE_LINE="${CRON_ONE_LINE//$'\n'/ }"
  CRON_ONE_LINE="${CRON_ONE_LINE%$'\r'}"
  if grep -qE '^[[:blank:]]*/review-pr([[:blank:]]+(--auto|--repo[[:blank:]]+[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+|[0-9]+))*[[:blank:]]*$' <<< "$CRON_ONE_LINE" \
     && grep -qE '(^|[[:blank:]])--auto([[:blank:]]|$)' <<< "$CRON_ONE_LINE"; then
    # Registered: allowed to RECUR. Fall through to detector B, which still
    # checks any `/goal` the prompt carries — being a known job does not exempt
    # a loop inside it from declaring its own bound.
    :
  else

  emit_deny "BLOCKED: recurring CronCreate with no registered self-termination (enforce-loop-bounds, guard 1 — iteration ceiling).

Prompt: ${CRON_PROMPT}

Every loop the toolbox creates must carry an explicit bound. A recurring cron is a loop, so its prompt has to name a command the toolbox has registered as self-terminating. Registered today: \`/review-pr … --auto\` (1-day cap in /review-pr Step 0.5, plus merge/close self-termination).

Three ways forward:
  1. If this should run ONCE, schedule it with \`recurring: false\` — the JSON boolean, not the string \"false\". Only a real boolean reads as one-shot; any other type is treated as recurring, because a value we cannot read must not be read as \"does not repeat\".
  2. If this is auto-poll, the WHOLE prompt must be nothing but \`/review-pr\` and its own arguments, drawn only from \`--auto\`, \`--repo <owner>/<repo>\` and a bare PR number, with \`--auto\` among them — the 1-day cap is keyed on \`--auto\`, so without it the cron is the unbounded variant. Flag order is free; \`/review-pr --repo o/r 5 --auto\`, \`/review-pr --auto --repo o/r 5\` and the legacy \`/review-pr 5 --auto\` all match. Everything else is rejected outright, including: any other flag (\`--help\`, \`--message\`, \`--repo=o/r\`), a bare word, a second slash command, a shell operator, a quote, a backslash, a backtick, \`\$\`, parentheses, a redirection, and any second line of instructions. This hook does not parse shell grammar or quoting, so it cannot tell which side of a chain would actually run — it accepts only the argument vocabulary the toolbox's own auto-poll constructions emit. Mentioning \`--auto\` anywhere else — a later line, surrounding prose, or another flag's value — does not count: what is registered is the command the job RUNS, so the prompt has to BE that command.
  3. If this is a new kind of recurring job, implement its termination first, then register it in hooks/enforce-loop-bounds.sh (SELF_TERMINATING_PROMPTS) in a toolbox PR. Doctrine: the \`loop-design\` skill.

This hook fails closed on an unrecognised prompt for the same reason the verification registry does (\`workflow-discipline\` skill §1c): an unreviewed bound is not a bound."
  fi   # end registry match
  fi   # end "recurring is not false"
fi     # end TOOL_NAME == CronCreate

# ===========================================================================
# Detector C — `/loop`, the harness's own loop primitive, must declare its bound
# ===========================================================================
#
# WHY THIS EXISTS (issue #146): detectors A and B bound the two loop kinds the
# TOOLBOX invented — a recurring CronCreate and a `/goal` phase exit — and left
# unbounded the one the HARNESS provides. `/loop` is invoked through the Skill
# tool, which this hook already matches on, so it was in the path the whole
# time and simply had no detector.
#
# WHAT `/loop` IS BOUNDED BY OTHERWISE — measured, not assumed. Phase 1 of this
# change checked: `CLAUDE_CODE_MAX_TURNS` and `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`
# are unset in the environment, absent from ~/.claude/settings.json, and appear
# in NO toolbox script. A `/loop` therefore carried no ceiling from any layer,
# and an interactive session has no `--max-budget-usd` either. That makes the
# clauses below the entire bound, exactly as they are for `/goal`.
# rules/workflow-discipline.md Rule 9 claimed the harness enforced a ceiling
# here; that row now states the residual instead of the claim.
#
# THE CONTRACT: a Skill payload whose skill is `loop` must carry BOTH mandatory
# clauses in its arguments, in the same vocabulary detector B already requires,
# and both numbers must be inside the toolbox ceilings above. A missing clause,
# an out-of-range number, or no arguments at all DENIES. Fail closed, because
# allowing on unknown input is the runaway this guard exists to stop.
#
# OUT OF SCOPE, stated rather than implied: a loop launched by Bash running the
# CLI directly, and an Agent spawn whose prompt says "loop until done", are NOT
# observable to this hook — it is registered on CronCreate and Skill only. See
# WHICH TOOLS THIS FIRES ON at the top of this file.
if [[ "$TOOL_NAME" == "Skill" ]]; then
  # READ BOTH SCHEMA SPELLINGS (H2). `.tool_input.skill` alone was a fail-OPEN:
  # enforce-skill-delegation.sh — the toolbox's OTHER hook on this exact `Skill`
  # matcher, reading this exact payload — has always read
  # `.tool_input.skill // .tool_input.name // …`, because the field the runtime
  # uses is not guaranteed. So a payload carrying the name under `name` was
  # ALLOWED here, unbounded loop and all, and no fixture used that schema, so
  # nothing reddened. Two hooks reading the same payload two different ways is
  # one of them being wrong, and the fail-open one is the wrong one.
  #
  # `.tool_input.args` is deliberately NOT in this chain, though the sibling
  # has it third. There, everything is a skill NAME and a fallback to args is a
  # last resort. Here `args` is a DIFFERENT field with a different meaning —
  # the loop's own arguments, read below — so falling back to it would make a
  # `/flow` invocation whose args merely mention loop get judged as one.
  #
  # Strip an optional `<plugin>:` prefix so a plugin-qualified spelling of the
  # same skill is judged the same way. This CANNOT widen the match onto a
  # neighbour: `everything-claude-code:autonomous-loops` reduces to
  # `autonomous-loops`, not `loop`. Pinned by TC-ELB-53; the schema fallback by
  # TC-ELB-52.
  # ⛔ `//` DOES NOT FALL BACK ON THE EMPTY STRING. ⛔ jq's alternative
  # operator only replaces `null` and `false`, so a payload carrying
  # `skill: ""` alongside `name: "loop"` set LOOP_SKILL to EMPTY and skipped
  # Detector C outright — an unbounded /loop, allowed, by the hook whose only
  # enforced bound this is. The fix reads each field through a `select` that
  # requires a non-empty STRING, so an empty, a null, a missing and a
  # wrong-typed field all fall through to the next spelling identically.
  # Pinned by TC-ELB-52b (empty skill + valid name) and its control TC-ELB-52c.
  # ⛔ A WHITESPACE-ONLY VALUE IS NOT A NAME, AND IT SHADOWED THE FALLBACK. ⛔
  # The `select(type == "string" and length > 0)` above got the empty case right
  # and let `"   "` straight through: length 3, so the FIRST alternative wins, and
  # `//` never looks at the next spelling. The bash normalisation below then trims
  # it back to the empty string, which matches no known skill, so the gate no-ops.
  # Measured at 5b94753 on the real hook: `{"skill":"   ","name":"loop"}` with no
  # turn clause produced EMPTY stdout and exit 0 - a silent ALLOW of an unbounded
  # /loop, past the only bound this hook enforces. Trimming INSIDE the select is
  # what makes `""`, `"   "`, `"\t"`, null, missing and wrong-typed all fall
  # through to the next spelling identically, which is what the comment above
  # already claimed.
  #
  # NOT a contradiction of the sibling finding: automated-review also reported that a
  # BOOLEAN `skill` makes jq error and abort the extraction. Measured false - jq's
  # `and` short-circuits, so `length` is never evaluated for a non-string, and
  # `{"skill":true,"name":"loop"}` already denied at 5b94753. The whitespace case
  # is the one that was real.
  LOOP_SKILL=$(jq -r '(.tool_input.skill | select(type == "string") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "") | select(length > 0)) // (.tool_input.name | select(type == "string") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "") | select(length > 0)) // empty' <<< "$HOOK_DATA" 2>/dev/null || echo "")
  # Fold case and strip surrounding whitespace before comparing. The
  # comparison below is EXACT, so `Loop` and `  loop  ` both slipped the
  # detector entirely — and neither is exotic: a runtime that title-cases a
  # skill name, or a payload built by string concatenation, produces exactly
  # those. `tr` + `awk` rather than `${var,,}` because the target is bash
  # 3.2.57, which has neither case-conversion expansion nor a trim operator.
  # This CANNOT widen onto a neighbour, because what follows is an equality
  # test and not a substring search: `autonomous-loops` folds to
  # `autonomous-loops`, which is not `loop` (TC-ELB-60).
  # ⛔ ORDER IS LOAD-BEARING: STRIP THE PREFIX BEFORE TRIMMING. ⛔
  # These two lines used to run the other way round — trim, then strip — and
  # `${LOOP_SKILL##*:}` RE-INTRODUCES a leading space on any `<plugin>: loop`
  # spelling, which the exact comparison below then fails to match. Measured on
  # the pre-fix order: `loop`, `Loop`, `  loop  `, `ecc:loop` all DENY, while
  # `ecc: loop`, `plugin: loop` and `superpowers:  loop` were ALLOWED — a
  # straight bypass of the only enforced bound on an unbounded /loop. The
  # justification originally given for adding the trim ("a payload built by
  # string concatenation") is exactly what produces `plugin: loop`.
  # Stripping first and folding second leaves no residue for either shape.
  LOOP_SKILL="${LOOP_SKILL##*:}"
  LOOP_SKILL=$(tr '[:upper:]' '[:lower:]' <<< "$LOOP_SKILL" | awk '{$1=$1};1')

  if [[ "$LOOP_SKILL" == "loop" ]]; then
    # Read the arguments field specifically rather than the whole tool_input
    # blob. If a future runtime moves the arguments to another key this reads
    # EMPTY, which denies — the fail-closed direction. A blob read would keep
    # finding the clauses and keep allowing, which is the wrong direction for
    # a guard whose whole job is to notice a missing bound. Pinned by
    # TC-ELB-54: clauses that WOULD satisfy the gate, placed in another field,
    # do not satisfy it.
    LOOP_ARGS=$(jq -r '.tool_input.args // empty' <<< "$HOOK_DATA" 2>/dev/null || echo "")
    # Normalise every kind of whitespace — escaped and literal — down to single
    # spaces, so a condition wrapped across source lines is matched the same as
    # a one-line one. Same reason as detector B: without this, "…after 25\nturns"
    # would read as having no turn clause and false-block a bounded loop.
    LOOP_ARGS=$(sed -e 's/\\[nrt]/ /g' -e 's/[[:space:]][[:space:]]*/ /g' <<< "$LOOP_ARGS")

    LOOP_TURNS=$(_clause_turns "$LOOP_ARGS")
    LOOP_NO_PROGRESS=$(_clause_no_progress "$LOOP_ARGS")
    LOOP_PREVIEW="${LOOP_ARGS:0:220}"
    # A bare `/loop` with no arguments at all is the self-pacing form: no
    # interval, no bounds, nothing. It reaches the two checks below with both
    # extractions empty and is denied by the first — the most unbounded shape
    # there is needs no special case, it just fails the same test.

    # ONE conditional per clause, each covering "absent" and "out of range"
    # together. The pin sweep is why: split into a `-z` branch and a separate
    # range branch, the `-z` branch reddened NO test — because `10#` on an
    # empty string evaluates to 0 in bash, so the range check absorbed the
    # missing-clause case and denied anyway, with a message reading "turn
    # bound  is outside the toolbox range". Correct decision, useless text,
    # and a branch no test could tell from its neighbour. Testing the SHAPE
    # first and short-circuiting keeps the arithmetic away from a non-number
    # entirely, so there is one branch, it is pinned, and it can say which of
    # the two things went wrong because it still has both values.
    #
    # (Detector B above splits these the old way. Its `-z` branches have the
    # same redundancy and the same garbled fallback text; left alone here
    # because this branch owns `/loop`, and reshaping `/goal`'s deny messages
    # is a separate, separately-reviewable change.)
    if [[ ! "$LOOP_TURNS" =~ ^[0-9]+$ ]] || (( 10#$LOOP_TURNS < 1 || 10#$LOOP_TURNS > TURNS_CEILING )); then
      emit_deny "BLOCKED: /loop declares no usable turn bound (enforce-loop-bounds, guard 1 — iteration ceiling).

Turn clause found: ${LOOP_TURNS:-<none>}
Arguments (first 220 chars): ${LOOP_PREVIEW:-<none — a bare /loop is the self-pacing form, which is the most unbounded shape there is>}

\`/loop\` runs a prompt over and over and has NO turn cap of its own. \`CLAUDE_CODE_MAX_TURNS\` and \`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP\` are unset here and are set by no toolbox script, and an interactive session has no \`--max-budget-usd\` either — so the clause you write IS the bound, and an out-of-range number is rejected rather than silently clamped (there is nothing behind it to fall back on).

Declare it in range 1-${TURNS_CEILING}, using the clamped \`max_turns\` from the \`loop:\` block in .claude/PROJECT.md (\`min(project, ${TURNS_CEILING})\`; toolbox default 25 when the block is absent) — never a number invented at the point of use:

  /loop 5m <your prompt> — stop after 25 turns, or if the same failure survives 2 consecutive iterations with no change in the gate output

Clamps: \`workflow-discipline\` skill §1d. Doctrine: the \`loop-design\` skill."
    fi

    if [[ ! "$LOOP_NO_PROGRESS" =~ ^[0-9]+$ ]] || (( 10#$LOOP_NO_PROGRESS < 1 || 10#$LOOP_NO_PROGRESS > NO_PROGRESS_CEILING )); then
      emit_deny "BLOCKED: /loop declares no usable no-progress bound (enforce-loop-bounds, guard 2 — no-progress detector).

No-progress clause found: ${LOOP_NO_PROGRESS:-<none>}
Arguments (first 220 chars): ${LOOP_PREVIEW}

The turn bound alone lets a loop rewrite the same failing file until it runs out of turns. The no-progress clause is what stops it early, and it is mandatory in every bounded-loop template.

Declare it in range 1-${NO_PROGRESS_CEILING}, using the clamped \`no_progress_after\` (\`min(project, ${NO_PROGRESS_CEILING})\`; toolbox default 2):

  ... or if the same failure survives 2 consecutive iterations with no change in the gate output

The runtime detector behind that clause is scripts/loop-progress-signature.sh — it compares a normalised failure signature, NOT file mtimes: a loop rewriting the same failing file reads as healthy to an mtime detector forever. Doctrine: the \`loop-design\` skill, guard 2."
    fi
  fi   # end skill == loop
fi     # end TOOL_NAME == Skill

# ===========================================================================
# Detector B — a `/goal` that SETS a goal must carry both bound clauses
# ===========================================================================
#
# Read the whole tool input as one JSON string so the detector does not depend
# on WHICH field carries the text — `tostring` also turns real newlines into
# the two-character `\n` escape, which is why the newline-smuggling problem
# that shaped enforce-auto-poll.sh does not arise here: there is nothing left
# for a `^...$` anchor to be evaluated per-line against.
GOAL_BLOB=$(jq -r '.tool_input // {} | tostring' <<< "$HOOK_DATA" 2>/dev/null || echo "")
# Normalise every kind of whitespace — escaped (\n \r \t, from tostring) and
# literal — down to single spaces, so a condition wrapped across source lines
# is matched the same as a one-line one. Without this, "…or after 25\nturns."
# would read as having no turn clause and false-block a correctly bounded goal.
GOAL_BLOB=$(sed -e 's/\\[nrt]/ /g' -e 's/[[:space:]][[:space:]]*/ /g' <<< "$GOAL_BLOB")

# Clear/status aliases from commands/flow.md — these END a goal rather than
# setting one, so they carry no condition and need no bound. A bare `/goal`
# (nothing after it) reports status and is likewise not a set.
GOAL_CLEAR_WORDS='clear|stop|off|reset|none|cancel'

REST="$GOAL_BLOB"
while [[ "$REST" == */goal* ]]; do
  # Consume through this occurrence. The loop always makes progress (REST gets
  # strictly shorter each pass), so it terminates on any input.
  REST="${REST#*/goal}"
  case "$REST" in
    ' '*)  CANDIDATE="${REST# }" ;;
    '')    break ;;        # trailing bare `/goal` → status, not a set
    *)     continue ;;      # `/goals`, `/goal-foo` → not a `/goal` invocation
  esac

  # Only judge THIS goal's text: truncate at the next `/goal` so a second,
  # correctly bounded condition in the same payload cannot satisfy this one.
  CANDIDATE="${CANDIDATE%%/goal*}"
  [[ -z "$CANDIDATE" ]] && continue

  # Judge "is this a clear alias" against the WHOLE argument, not just its first
  # word. Testing the first word alone read `/goal none of the tests fail` as the
  # `none` alias and exempted a real, unbounded goal from every bound check below
  # — and `none`/`stop`/`reset` are all natural ways to OPEN a condition, so this
  # was not a corner case. Only a BARE alias may skip the bounds.
  #
  # Strip the trailing JSON tail first: `tostring` leaves `","nextkey":"…"}`
  # after the value, so an untrimmed comparison would reject a legitimate
  # `/goal clear` whenever another field followed it in tool_input. Cutting at
  # the first `"` also truncates a condition containing an escaped quote — that
  # only SHORTENS the text, so a real condition loses its bound clauses and is
  # denied. Fail-closed in the safe direction.
  CLEAR_ARG="${CANDIDATE%%\"*}"
  if grep -qiE "^(${GOAL_CLEAR_WORDS})[[:space:][:punct:]]*$" <<< "$CLEAR_ARG"; then
    continue   # `/goal clear` and friends — nothing to bound
  fi

  # Extract the FIRST occurrence of each mandatory clause. Shared with
  # detector C — see _clause_turns / _clause_no_progress above for why these
  # are functions and why they fail closed on a missing or absurd number.
  TURNS=$(_clause_turns "$CANDIDATE")
  NO_PROGRESS=$(_clause_no_progress "$CANDIDATE")

  GOAL_PREVIEW="${CANDIDATE:0:220}"

  if [[ -z "$TURNS" ]]; then
    emit_deny "BLOCKED: /goal condition carries no turn bound (enforce-loop-bounds, guard 1 — iteration ceiling).

Condition (first 220 chars): ${GOAL_PREVIEW}

\`/goal\` has NO turn cap of its own, so a condition without a turn clause is an unbounded loop — and in an interactive session there is no \`--max-budget-usd\` either, which makes the clause the only hard stop that exists.

Add the mandatory clause, using the clamped \`max_turns\` from the \`loop:\` block in .claude/PROJECT.md (\`min(project, ${TURNS_CEILING})\`; toolbox default 25 when the block is absent) — never a number invented at the point of use:

  ... or after 25 turns.

Templates: commands/flow.md Steps 8a and 11a. Clamps: \`workflow-discipline\` skill §1d."
  fi

  if [[ -z "$NO_PROGRESS" ]]; then
    emit_deny "BLOCKED: /goal condition carries no no-progress clause (enforce-loop-bounds, guard 2 — no-progress detector).

Condition (first 220 chars): ${GOAL_PREVIEW}

The turn bound alone lets a loop rewrite the same failing file until it runs out of turns. The no-progress clause is what stops it early, and it is mandatory in every condition template.

Add it, using the clamped \`no_progress_after\` (\`min(project, ${NO_PROGRESS_CEILING})\`; toolbox default 2):

  ... if the same failure survives 2 consecutive iterations with no change in the gate output ...

The runtime detector behind that clause is scripts/loop-progress-signature.sh — it compares a normalised failure signature, NOT file mtimes. Doctrine: the \`loop-design\` skill, guard 2."
  fi

  # 10# forces base-10 so a leading zero ("after 08 turns") is not read as octal.
  if (( 10#$TURNS < 1 || 10#$TURNS > TURNS_CEILING )); then
    emit_deny "BLOCKED: /goal turn bound ${TURNS} is outside the toolbox range 1-${TURNS_CEILING} (enforce-loop-bounds, guard 1 — iteration ceiling).

Condition (first 220 chars): ${GOAL_PREVIEW}

Unlike a PROJECT.md value — which is kept and ignored in favour of the clamp — the number in a \`/goal\` condition IS the bound. There is nothing behind it to fall back on, so an out-of-range value is rejected rather than silently clamped.

Use \`min(project max_turns, ${TURNS_CEILING})\` (\`workflow-discipline\` skill §1d; toolbox default 25)."
  fi

  if (( 10#$NO_PROGRESS < 1 || 10#$NO_PROGRESS > NO_PROGRESS_CEILING )); then
    emit_deny "BLOCKED: /goal no-progress bound ${NO_PROGRESS} is outside the toolbox range 1-${NO_PROGRESS_CEILING} (enforce-loop-bounds, guard 2 — no-progress detector).

Condition (first 220 chars): ${GOAL_PREVIEW}

Use \`min(project no_progress_after, ${NO_PROGRESS_CEILING})\` (\`workflow-discipline\` skill §1d; toolbox default 2)."
  fi
done

exit 0
