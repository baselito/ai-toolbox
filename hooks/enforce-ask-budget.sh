#!/bin/bash
# enforce-ask-budget.sh
#
# PreToolUse hook on `AskUserQuestion`. Makes the Ask Test in
# `rules/autonomy.md` structural instead of aspirational: an ask must name one
# of the four categories that justify spending a question, or it is denied and
# the agent decides, states the decision, and proceeds.
#
# WHY A HOOK AND NOT PROSE:
#   The toolbox named AskUserQuestion on 141 lines of rules, commands and skills
#   (measured: `git grep -n AskUserQuestion` on origin/main, less the test harness),
#   several of them behind ⛔ markers with hooks and audit checks enforcing them,
#   while "don't ask, just do it" lived only in unenforced memory files. The
#   asymmetry is the whole defect: prose that says "be autonomous" loses to prose
#   that says "⛔ NEVER proceed without asking", every time. Removing the mandate
#   from those files (this PR's other half) stops REQUIRING the ask; this hook is
#   what makes the new default actually hold under pressure, in the same way
#   enforce-loop-bounds.sh holds the loop-bound rule.
#
# WHO IT APPLIES TO — opt-in, by design:
#   Only a developer whose `~/.claude/memory.md` carries a `- Autonomy: goal`
#   line. Absent that line the hook is a no-op, so every other toolbox user is
#   completely unaffected and nothing about their prompting changes. Same
#   opt-in shape and same regex style as the `- Codex: enabled` gate in
#   enforce-codex-review.sh, deliberately: one declaration file, one line
#   grammar, one place to look.
#
#   ⛔ THE OPT-IN GATE RUNS FIRST — BEFORE jq, BEFORE THE PAYLOAD IS PARSED. ⛔
#   The first cut judged payload integrity first, so a malformed payload (or a
#   machine without jq) denied the ask for EVERY developer, opted in or not.
#   That contradicted the no-op contract two paragraphs up, and the argument for
#   it ("the same input must not be classified two ways") was wrong: classifying
#   the same input two ways is exactly what an opt-in switch IS. A developer who
#   never declared `- Autonomy: goal` has no Ask Test to enforce, so there is no
#   invariant to fail closed on — only an ask to break. Everything below the
#   opt-in gate therefore applies to opted-in developers only.
#
# WHAT IT CHECKS:
#   EVERY question in the payload must carry a `header` beginning with one of
#     Irreversible | Scope | Unknown | Conflict | Blocked
#   — the four Ask Test categories plus `Blocked`, which is the phase-card
#   status that `rules/agents.md` step 4 still allows to stop the workflow. ALL
#   questions must qualify, not merely one: a payload that bundles one genuine
#   Irreversible question with three "shall I continue" ones would otherwise
#   launder the three through the one, and batching is exactly what the autonomy
#   rule tells the agent to do, so bundling is the expected shape rather than an
#   exotic one.
#
#   The match is on the START of the header, and the category word must END
#   THERE — it is followed by a non-word character or by nothing at all. So
#   `Scope — drop one goal?`, `Scope:` and a bare `Scope` all pass, while
#   `Scopey`, `Blockedness` and `Conflictual` do NOT. A plain `^Scope` prefix
#   test accepted those three, which is a real hole rather than a pedantic one:
#   the whole value of the gate is that the header states a category a READER
#   can check, and a word that merely starts like one states nothing.
#   The "non-word character" class is UNICODE-AWARE (\p{L}, \p{N} -- jq's
#   Oniguruma engine supports them), not ASCII [A-Za-z0-9_]. With the ASCII
#   class `Scopee-acute` passed: an accented letter is not in [A-Za-z0-9_], so it
#   read as a boundary and the header looked categorised. That is the `Scopey`
#   hole again, one character class over, and it would have been the easy way to
#   launder an uncategorised ask past the gate in any non-English text.
#   `Continue?`, `Next step`, `Confirm` and an EMPTY/ABSENT header do not pass
#   either. A category word appearing anywhere else — in the question text, in
#   an option label — does not count: what is being certified is the CATEGORY
#   THE AGENT CLAIMED, and the header is the one field that states it.
#   Comparison is case-sensitive as spelled here (`Scope`, not `scope`),
#   matching the rule's own spelling; the deny message tells the agent the exact
#   word to use, so a case slip costs one re-ask.
#
# FAIL DIRECTION — deliberately MIXED, and each direction is argued. Note that
# every "DENY" below is reachable only AFTER the opt-in gate has passed:
#   * reading memory.md errors out (unreadable file,
#     permissions, unset $HOME, grep failure)        → ALLOW (fail OPEN), and it
#     is the FIRST thing decided. Two independent reasons, and the second is the
#     one a reviewer keeps missing:
#       (a) memory.md is the OPT-IN switch, so a broken read means "we could not
#           confirm this developer opted in". Denying there would block EVERY
#           ask for a developer who never opted in.
#       (b) THE RISK DIRECTION IN THIS HOOK IS INVERTED relative to every other
#           gate in this directory. Elsewhere "allow" lets the agent act
#           unsupervised, so failing open is failing toward danger. Here the
#           thing being gated is a QUESTION: "allow" means the question reaches
#           the human — MORE oversight — while "deny" forces the agent to
#           proceed without asking — LESS. Failing open on the opt-in read
#           therefore fails toward human oversight. That is why it is correct on
#           its own merits, not merely because it matches prior behaviour.
#     This has been filed as a fail-open defect once already. It is not one.
#   * `jq` missing                                   → DENY. Same as every other
#     PreToolUse gate here: without jq we can neither parse the payload nor emit
#     a structured decision, so allowing would silently disarm the layer.
#   * payload is not a readable JSON OBJECT          → DENY (fail CLOSED). This
#     is the one place this hook is STRICTER than its neighbours, which fall
#     through to allow on an unparseable payload. It is strict because an
#     unreadable payload has no readable headers, and "we cannot see the
#     categories" must not read as "the categories are fine".
#   * `tool_name` absent or empty                    → DENY (fail CLOSED). The
#     hook is registered on the `AskUserQuestion` matcher, so a payload that
#     reached it and cannot say what tool it is, is a payload we cannot clear.
#     A DIFFERENT tool name is a clean no-op (exit 0) — that is out of scope,
#     not unreadable.
#   * `tool_input.questions` absent, not an array,
#     or empty                                       → DENY (fail CLOSED). The
#     first cut read it as `// []`, so a payload shaped differently by a future
#     runtime produced no bad headers and no deny — the gate silently evaporated
#     on exactly the input it could not inspect. An AskUserQuestion with no
#     readable question list is not "nothing to ask", it is "we cannot see what
#     is being asked".
#   * a header that is not readable text             → DENY (fail CLOSED).
#   * all headers categorised                        → exit 0, no-op.
#
# WHAT THIS HOOK DOES NOT DO — residuals, named so nobody has to rediscover them:
#   * It cannot check whether the claimed category is TRUE. An agent can label a
#     "shall I continue" question `Scope` and get through. That is accepted: the
#     hook's job is to force the agent to NAME a category, which is the step that
#     makes an unjustified ask visible to a reader (and to a compliance audit) —
#     not to adjudicate it. Honesty about the label is a rules-level obligation.
#   * It sees only the `AskUserQuestion` tool. A question the agent simply writes
#     at the end of a reply is not a tool call and is invisible here; that half
#     of the Ask Test rests on `rules/autonomy.md` alone. This is why the rule
#     covers "any reply ending in a question or option list" explicitly.
#   * It does not rate-limit. There is no per-session ask counter — a category
#     ask is allowed as often as it is genuinely needed. "Budget" here means
#     "spend a question only where a category justifies it", not a quota.
#
# All detectors match with here-strings (`<<<`), never `echo | grep`: under
# `set -euo pipefail` the pipe form can SIGPIPE (141) on large input and flip a
# deny into an allow. Same rule and same reason as the other gates in this
# directory; scripts/verify-hooks.sh asserts it statically. The same reasoning
# is why emit_deny hands its reason to jq on STDIN rather than in argv — see
# there.

set -euo pipefail

# Drain stdin FIRST, before any exit path. Every later branch — including the
# no-op ones — then leaves the writer with a fully-consumed pipe, so a large
# payload cannot SIGPIPE the harness on an early exit. `cat` is the only
# external command this needs, which matters for the jq-missing path below.
HOOK_DATA=$(cat)

# ---------------------------------------------------------------------------
# OPT-IN GATE — no `- Autonomy: goal` line in memory.md → this hook is a no-op.
# Runs first, for the reason argued in the header block.
#
# STATE_DIR is overridable (CLAUDE_STATE_DIR) so tests can exercise both paths
# deterministically without depending on the machine's real memory.md — same
# convention as every other stateful hook here.
#
# `${HOME:-}` is NOT decoration. Under `set -u` a bare `$HOME` on a machine with
# HOME unset ABORTS the script here — exit 1 with nothing on stdout, which the
# hook protocol reads as a silent ALLOW. That lands in the same place as the
# deliberate fail-open below, but by crashing rather than by deciding, and a
# crash-shaped allow is precisely the failure mode this directory has been bitten
# by. Defaulting to empty makes STATE_DIR `/.claude`, the grep finds nothing, and
# the no-op is taken ON PURPOSE.
#
# Anchored on the exact state token `goal`, so `- Autonomy: ask` /
# `- Autonomy: not goal` do NOT enable the gate. The trailing class allows an
# inline `# comment` or end-of-line after the token. Same regex shape as the
# `- Codex: enabled` gate in enforce-codex-review.sh, on purpose.
#
# FAIL OPEN here (see FAIL DIRECTION above). Three things make that hold, and
# all three are load-bearing:
#   * `2>/dev/null` swallows the "No such file"/"Permission denied" diagnostic,
#     so an absent or unreadable memory.md is indistinguishable from "no match".
#   * The grep sits in an `if` CONDITION, which is exempt from `set -e` — a
#     non-zero grep (no match, or a read failure) is a false branch, never an
#     abort. That is why no `|| true` is needed and none is written: appending
#     one to the `fi` would be dead code implying a risk that is not there.
#   * AUTONOMY_ON is pre-set to empty, so every non-yes path lands on the no-op.
# ---------------------------------------------------------------------------
STATE_DIR="${CLAUDE_STATE_DIR:-${HOME:-}/.claude}"
MEMORY_FILE="$STATE_DIR/memory.md"
AUTONOMY_ON=""
if grep -qiE '^- *Autonomy:[[:space:]]*goal([[:space:]#]|$)' "$MEMORY_FILE" 2>/dev/null; then
  AUTONOMY_ON="yes"
fi
if [[ -z "$AUTONOMY_ON" ]]; then
  exit 0   # developer has not declared goal-autonomy → every ask allowed
fi

# Fail CLOSED when jq is missing — consistent with every other PreToolUse gate
# here, and reachable only for a developer who opted in. Spaces after the colons
# are deliberate: scripts/verify-hooks.sh greps for the spaced
# `"permissionDecision": "deny"` spelling, so the compact form some older hooks
# use would be invisible to the harness assertion.
if ! command -v jq &>/dev/null; then
  cat <<'__DENY__'
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "BLOCKED: jq is required for hook enforcement (enforce-ask-budget). Install jq (brew install jq / apt install jq / yum install jq) to continue. Hook fails closed for safety."}}
__DENY__
  exit 0
fi

# emit_deny <reason> — print the deny JSON and exit. Always exits 0: a hook's
# own exit code is not the decision channel, the JSON is. Deny JSON at exit 0
# BLOCKS; the identical JSON at a non-zero exit is IGNORED and the action
# proceeds, so every path through this function must reach `exit 0`.
#
# The reason is handed to jq on STDIN via a here-string, NOT as an `--arg`
# value. An `--arg` travels in argv, and a multi-megabyte question header —
# which the caller below happily interpolates into the message — would blow
# ARG_MAX and make the exec fail AFTER the deny path had already begun,
# printing nothing at all. Nothing-on-stdout is a silent allow: the biggest
# possible bad input would have been the one that got through.
emit_deny() {
  if ! jq -Rs '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": (. | sub("\n$"; ""))
    }
  }' <<< "$1"; then
    # LAST-RESORT DENY: jq itself failed while rendering the message. A deny
    # path must never exit having printed nothing. This literal interpolates
    # nothing, so there is no input that can make it fail in turn.
    cat <<'__DENY__'
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "BLOCKED: enforce-ask-budget denied this ask but could not render its explanation (jq failed). Re-issue the call with ONE short header per question, beginning with Irreversible, Scope, Unknown, Conflict or Blocked — or decide, state the decision, and proceed. See rules/autonomy.md."}}
__DENY__
  fi
  exit 0
}

# ---------------------------------------------------------------------------
# Fail CLOSED on a payload that is not a readable JSON object.
#
# `jq -e 'type == "object"'` answers both halves at once: invalid JSON makes jq
# exit non-zero, and valid-but-not-an-object JSON (an array, a bare string, a
# number, `null`) makes the test false. Either way we cannot read a `header`
# out of it, and an unreadable ask must not be read as a categorised one.
# ---------------------------------------------------------------------------
if ! jq -e 'type == "object"' <<< "$HOOK_DATA" &>/dev/null; then
  emit_deny "BLOCKED: unreadable AskUserQuestion payload (enforce-ask-budget).

The hook input was not a readable JSON object, so the question headers cannot be checked against the Ask Test in rules/autonomy.md. This gate fails closed: \"the categories cannot be seen\" must not be treated as \"the categories are fine\".

Re-issue the AskUserQuestion call. If this recurs, the harness is emitting a malformed hook payload — that is a bug to report, not something to work around."
fi

# ---------------------------------------------------------------------------
# `tool_name` must be READABLE. Absent or empty fails CLOSED; a different tool
# is a clean no-op.
#
# hooks-config.json already scopes the matcher to AskUserQuestion, but a hook
# must not depend on its registration for correctness — the same defensive
# shape the other gates in this directory use. The first cut used
# `// empty` and then compared, so an ABSENT tool_name took the
# "not AskUserQuestion, none of my business" branch. On a hook registered for
# exactly one tool that reading is backwards: the payload reached us because
# the runtime matched AskUserQuestion, so a missing tool_name is a payload we
# cannot clear, not a payload about something else.
# ---------------------------------------------------------------------------
#
# And it must be a STRING. `// ""` substitutes only for `null`, so it cannot
# see a TYPE error: `jq -r` renders a number, an array or an object as its JSON
# TEXT, which is non-empty and never equal to "AskUserQuestion" — so every
# malformed shape took the "not my business" branch at exit 0 and the header
# check below never ran. Measured before this fix: `{"tool_name":123,…}` with
# an uncategorised header was ALLOWED, while the identical header with a
# well-formed name was denied.
#
# That is the same defect the paragraph above describes, one shape further in:
# the guard was written for the case the author pictured (key absent) and was
# absent on its sibling (key present, wrong type). `-e` here is exit-status-
# on-output, so a valid string yields 0 and anything else takes the `TOOL_NAME=""`
# fallback into the shared fail-closed deny — one path, not two.
if ! TOOL_NAME=$(jq -er '
  if (.tool_name | type) == "string" then .tool_name else error("tool_name is not text") end
' <<< "$HOOK_DATA" 2>/dev/null); then
  TOOL_NAME=""
fi

if [[ -z "$TOOL_NAME" ]]; then
  emit_deny "BLOCKED: AskUserQuestion payload names no tool (enforce-ask-budget).

The payload carries no readable \`tool_name\`, so this hook cannot confirm what it is being asked to clear. It is registered on AskUserQuestion only, so an unnamed payload here is an unreadable ask, not somebody else's business — and it fails closed.

Re-issue the call. If this recurs, the harness is emitting a hook payload without a tool name — report that rather than working around it."
fi

if [[ "$TOOL_NAME" != "AskUserQuestion" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# `tool_input.questions` must be a NON-EMPTY ARRAY.
#
# The first cut read it as `.tool_input.questions // []`, which made every
# unreadable shape — key absent, `tool_input` a string, questions an object —
# produce an empty list, hence no bad headers, hence a fall-through ALLOW. The
# gate evaporated on precisely the payloads it could not inspect. An empty array
# is denied for the same reason: an AskUserQuestion asking zero questions is not
# a payload with nothing to check, it is a payload we do not understand.
#
# jq raises on `.tool_input.questions` when `.tool_input` is not an object, so
# the `if !` (exempt from `set -e`) catches that as a false, not an abort.
# ---------------------------------------------------------------------------
if ! QUESTIONS_OK=$(jq -r '
  if ((.tool_input.questions | type) == "array") and ((.tool_input.questions | length) > 0)
  then "yes" else "no" end
' <<< "$HOOK_DATA" 2>/dev/null); then
  QUESTIONS_OK="no"
fi

if [[ "$QUESTIONS_OK" != "yes" ]]; then
  emit_deny "BLOCKED: AskUserQuestion carries no readable question list (enforce-ask-budget).

\`tool_input.questions\` is missing, is not an array, or is empty, so the Ask Test in rules/autonomy.md cannot be applied to anything. This gate fails closed — an ask whose questions cannot be read is not an ask with nothing to check.

Re-issue the call with at least one question, each carrying a \`header\` that begins with Irreversible, Scope, Unknown, Conflict or Blocked."
fi

# ---------------------------------------------------------------------------
# THE CHECK — every question's header must begin with a category word, and the
# word must END there (followed by a non-word character, or by nothing).
#
# The jq program collects the BAD headers rather than testing that all are good:
# `all` on an empty array is vacuously true, so a "the payload is fine" phrasing
# would wave through a list with nothing in it. The non-empty check above
# already rejects that case, and collecting the offenders is also what lets the
# deny message NAME them.
#
# `.header // ""` maps an absent or null header to the empty string, which
# matches no category and is therefore reported as bad. `tostring` is NOT used:
# a non-string header (a number, an object) would render as something that could
# coincidentally start with a category word only if it literally spelled one, and
# jq's `test` on a non-string raises — caught by the `if !` guard, which denies.
# Fail closed on a header we cannot read as text.
#
# Each reported header is TRUNCATED to 80 characters and at most 5 are listed.
# That is not cosmetic: the list is interpolated into the deny message, and an
# unbounded message is how a huge header used to turn a deny into a crash (see
# emit_deny). Bounding it here and passing it on stdin there are belt and braces.
# ---------------------------------------------------------------------------
if ! BAD_HEADERS=$(jq -r '
  [ .tool_input.questions[]
    | (.header // "")
    | select(test("^(Irreversible|Scope|Unknown|Conflict|Blocked)([^\\p{L}\\p{N}_]|$)") | not)
    | if . == "" then "<empty>"
      elif (. | length) > 80 then (.[0:80] + "…(truncated)")
      else . end
  ] | .[0:5] | join(" | ")
' <<< "$HOOK_DATA" 2>/dev/null); then
  emit_deny "BLOCKED: AskUserQuestion headers could not be read (enforce-ask-budget).

One or more question headers is not readable text, so the Ask Test in rules/autonomy.md cannot be applied to it. This gate fails closed.

Re-issue the call with a plain-string \`header\` on every question, beginning with Irreversible, Scope, Unknown, Conflict or Blocked."
fi

if [[ -n "$BAD_HEADERS" ]]; then
  emit_deny "Ask denied (autonomy). If this is Irreversible/Scope/Unknown/Conflict, re-ask with that word as the header. Otherwise: decide, state \`Decided: …\`, proceed. Sequencing and continue questions are yours (rules/autonomy.md).

Uncategorised header(s): ${BAD_HEADERS}

The header must BEGIN with a category word and the word must END there — \`Scope\`, \`Scope:\` and \`Scope — drop a goal\` all qualify; \`Scopey\` does not.

The four categories, and nothing else, justify spending a question:
  Irreversible — merge on a non-toolbox repo, delete/discard work, force-push, production, spend, data loss; also any effect that lands on someone else and cannot be silently retracted (a push or PR where no standing consent is recorded, an external send)
  Scope        — the work would grow beyond the agreed goal, or two agreed goals conflict so one must be DROPPED
  Unknown      — not inferable from the goal, ~/.claude/memory.md, .claude/PROJECT.md, the ticket or the repo
  Conflict     — the action would contradict a standing user instruction, or collides with another person's claim on the same work
(\`Blocked\` is also accepted: it is the phase-card status that rules/agents.md step 4 still allows to stop on.)

Not asks, ever: sequencing, ordering, which-first, tool choice, retries, how to recover from a failure, whether a ticket is \"simple enough\", or \"shall I continue\".

Decide-and-state format — one line, never a question:
  Decided: <X> — <reason>. (Say \"switch\" to change.)

This gate is active because ~/.claude/memory.md declares \`- Autonomy: goal\`. It checks that a category was NAMED, not that the naming is honest — label a question truthfully or not at all."
fi

exit 0
