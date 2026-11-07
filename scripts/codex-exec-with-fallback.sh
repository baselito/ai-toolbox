#!/usr/bin/env bash
# codex-exec-with-fallback.sh — Run the Codex pre-PR review exec pinned to the
# review-gate model, retrying ONCE unpinned on a model-specific error.
#
# WHY THIS EXISTS:
#   skills/codex-review/SKILL.md Step 3 pins the review gate to GPT-5.6 Terra
#   (-m gpt-5.6-terra) and defines a retry contract: if that exact model is
#   rejected (renamed / retired / not on this plan / CLI too old for it), retry
#   ONCE on the ~/.codex/config.toml default model — but a spend-cap, network,
#   or timeout failure must NOT retry (those take the skill's outage path, and a
#   retry would burn quota for nothing). The Terra pre-PR review of PR #124
#   flagged this contract as mechanically testable but untested. Extracting the
#   logic here (instead of inline prose-bash in the skill) lets
#   scripts/test-codex-exec-with-fallback.sh exercise it with a fake `codex` CLI
#   — run by verify.sh, so a regression is caught mechanically.
#
# USAGE:
#   bash scripts/codex-exec-with-fallback.sh <prompt-file> <out-file>
#
# ENV:
#   CODEX_MODEL  — model to pin with -m. Default: gpt-5.6-terra (the balanced
#                  GPT-5.6 tier — see rules/performance.md). Set to the EMPTY
#                  string to run unpinned on the config.toml default (then no
#                  model-fallback is possible or needed). Note the ${VAR-default}
#                  expansion: empty-but-set is respected, only unset gets the default.
#   CODEX_EFFORT — model_reasoning_effort for BOTH attempts. Default: xhigh (the
#                  review-gate default — see the effort table in rules/performance.md).
#
# OUTPUT: codex's combined stdout+stderr is written to <out-file>. On retry the
#   file is OVERWRITTEN — the final attempt's output is authoritative, and it is
#   what the caller greps for the spend-cap outage signal.
#
# EXIT CODE: the exit code of the FINAL codex attempt (0 = review produced).

set -uo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <prompt-file> <out-file>" >&2
  exit 2
fi
PROMPT_FILE="$1"
OUT_FILE="$2"
if [[ ! -r "$PROMPT_FILE" ]]; then
  echo "codex-exec-with-fallback: prompt file not readable: $PROMPT_FILE" >&2
  exit 2
fi

# ${CODEX_MODEL-...} (no colon) — an explicitly EMPTY value means "run unpinned";
# only a genuinely unset variable gets the Terra default.
CODEX_MODEL="${CODEX_MODEL-gpt-5.6-terra}"
CODEX_EFFORT="${CODEX_EFFORT:-xhigh}"

# Model-specific error matcher. Covers BOTH orderings — "model … unknown/not
# found/…" AND the CLI's own "Unknown model `x`" (which `model.*unknown` misses —
# caught by the Terra review of PR #124) — plus "requires a newer version", the
# API's CLI-version-gate error observed live 2026-07-10 (outdated CLI 0.141.0 +
# pinned gpt-5.6-terra → HTTP 400; a config default on an older model still
# works, so falling back rescues the gate). Deliberately does NOT match
# spend-cap / credits / timeout / usage-limit strings — those must reach the
# caller's outage path unretried. Tested both directions by
# scripts/test-codex-exec-with-fallback.sh.
MODEL_ERR_RE='model.*(not found|unknown|unavailable|unsupported|does not exist|no access|requires a newer version)|unknown model'

# run_codex [pin-args...] — one codex exec attempt with the shared fixed flags.
# --sandbox read-only: Codex must never modify files (reports findings only).
run_codex() {
  codex exec "$@" -c model_reasoning_effort="$CODEX_EFFORT" --sandbox read-only --skip-git-repo-check - < "$PROMPT_FILE" > "$OUT_FILE" 2>&1
}

if [[ -n "$CODEX_MODEL" ]]; then
  run_codex -m "$CODEX_MODEL"
  RC=$?
  if [[ $RC -ne 0 ]] && grep -qiE "$MODEL_ERR_RE" "$OUT_FILE"; then
    # One-shot fallback — never loops, even if the unpinned attempt also
    # returns a model error (the config default being broken is an outage).
    echo "codex-exec-with-fallback: pinned model '$CODEX_MODEL' rejected — retrying once on the config.toml default (if this persists, update the CLI: codex update)" >&2
    run_codex
    RC=$?
  fi
else
  # Unpinned mode: config.toml default model; no pin means no fallback to try.
  run_codex
  RC=$?
fi

exit "$RC"
