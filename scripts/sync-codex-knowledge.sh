#!/usr/bin/env bash
# sync-codex-knowledge.sh
#
# Assembles the local Codex knowledge pack at ~/.claude/codex-knowledge/ so that
# local Codex pre-PR reviews (see skills/codex-review/SKILL.md) review LIKE
# automated-review — without dragging automated-review's full 188 KB concepts.yml into every
# review (Codex quota is limited; see the Codex tier in rules/performance.md).
#
# What it produces in ~/.claude/codex-knowledge/:
#   - memories.yml              (LIVE — fetched from automated-review; ~12 KB learned lessons)
#   - pr-reviewer.yml           (LIVE — fetched from automated-review; suppression/scope config)
#   - review-concepts-distilled.md  (STATIC — copied from the toolbox repo; the
#                                       slow-changing thematic backbone of concepts.yml)
#   - README.md                 (explains the pack to anyone who opens it)
#
# DESIGN: the small, high-value, fast-changing parts (memories + config) are pulled
# LIVE so they're always current. The 188 KB concepts catalogue is represented by a
# committed distilled summary (themes + meta-principle) that changes slowly — feeding
# the full catalogue every review would burn quota for little marginal signal.
#
# Fail-soft: if automated-review is unreachable (no gh auth, private repo, network), the
# script WARNS and leaves any existing pack in place rather than wiping it. The
# distilled file always lands (it ships in the toolbox).
#
# Usage:
#   bash scripts/sync-codex-knowledge.sh            # refresh the pack
#   bash scripts/sync-codex-knowledge.sh --quiet    # suppress info lines (for install.sh)
#
# Re-distilling concepts.yml: this script does NOT re-distill the 188 KB file (that
# is a semantic task, not a deterministic one). When automated-review's concepts drift enough
# to matter, re-generate skills/codex-review/review-concepts-distilled.md by hand
# (or via an agent reading the live concepts.yml) and commit it. memories.yml carries
# the freshest lessons live in the meantime.

set -euo pipefail

QUIET=false
[[ "${1:-}" == "--quiet" ]] && QUIET=true
info() { [[ "$QUIET" == "true" ]] || printf 'ℹ️  %s\n' "$1"; }
warn() { printf '⚠️  %s\n' "$1" >&2; }

REVIEWER_REPO="${REVIEWER_KNOWLEDGE_REPO:-}"
PACK_DIR="$HOME/.claude/codex-knowledge"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DISTILLED_SRC="$REPO_ROOT/skills/codex-review/review-concepts-distilled.md"

mkdir -p "$PACK_DIR"

# --- Static: the distilled concepts summary ships in the toolbox repo ---
if [[ -f "$DISTILLED_SRC" ]]; then
  cp "$DISTILLED_SRC" "$PACK_DIR/review-concepts-distilled.md"
  info "Copied distilled concepts summary into the pack."
else
  warn "Distilled concepts file not found at $DISTILLED_SRC — pack will lack the thematic backbone."
fi

# --- Live: fetch the small, high-value, fast-changing files from automated-review ---
# Helper: fetch a file from automated-review's knowledge/ dir. The decision to write is
# keyed on the API call SUCCEEDING (gh exit 0 = authoritative answer), not on the
# content being non-empty. So a transient API/network failure preserves the old
# copy, while a successful fetch of a now-empty file (e.g. automated-review's
# .pr-reviewer.yml) correctly truncates a previously non-empty local copy when
# allow_empty=true (Codex self-review P2). For files that should never be empty
# (memories.yml), allow_empty=false treats an empty result as a no-write.
# Portable base64 decode: GNU coreutils uses `-d`, BSD/macOS uses `-D`. Try GNU
# first, fall back to BSD. Returns non-zero if BOTH fail (so the caller does not
# overwrite a good copy with garbage — automated-review PR #76 portability finding).
decode_base64() {
  base64 -d 2>/dev/null || base64 -D 2>/dev/null
}

fetch_knowledge() {
  local remote_name="$1" dest="$2" allow_empty="${3:-false}"
  local tmp b64
  tmp="$(mktemp)"
  # `gh api` exits 0 only when the file exists and the call succeeded.
  if b64=$(gh api "repos/$REVIEWER_REPO/contents/knowledge/$remote_name" --jq '.content' 2>/dev/null); then
    # Decode must SUCCEED — no `|| true`. A decode failure (e.g. an unexpected
    # base64 variant) must NOT overwrite an existing good copy with garbage.
    # An empty API content field is valid: it decodes to an empty file with
    # exit 0, which is honoured only when allow_empty=true.
    if printf '%s' "$b64" | decode_base64 > "$tmp" 2>/dev/null \
       && { [[ -s "$tmp" ]] || [[ "$allow_empty" == "true" ]]; }; then
      mv "$tmp" "$dest"
      info "Synced $remote_name (live from $REVIEWER_REPO)."
      return 0
    fi
  fi
  rm -f "$tmp"
  return 1
}

GH_OK=true
command -v gh >/dev/null 2>&1 || GH_OK=false

if [[ -z "$REVIEWER_REPO" ]]; then
  info "No REVIEWER_KNOWLEDGE_REPO configured — using bundled review concepts only."
elif [[ "$GH_OK" == "true" ]]; then
  fetch_knowledge "memories.yml" "$PACK_DIR/memories.yml" \
    || warn "Could not sync memories.yml from $REVIEWER_REPO (kept existing copy if any)."
  # .pr-reviewer.yml is stored without the leading dot in the pack for clarity.
  # allow_empty=true: automated-review's config is currently empty; a successful fetch of
  # an empty file should truncate any stale local copy rather than keep it forever.
  fetch_knowledge ".pr-reviewer.yml" "$PACK_DIR/pr-reviewer.yml" true \
    || info "Could not fetch .pr-reviewer.yml from $REVIEWER_REPO (kept existing copy if any)."
else
  warn "gh CLI not available — skipping live automated-review sync. The distilled summary is still in place."
fi

# --- Pack README (orients anyone who opens the dir) ---
cat > "$PACK_DIR/README.md" <<'README'
# Codex knowledge pack

Local seed for Codex pre-PR reviews so they review like automated-review. Assembled by
`ai-engineering/scripts/sync-codex-knowledge.sh`.

- `memories.yml` — automated-review's learned lessons (LIVE, refreshed on sync).
- `pr-reviewer.yml` — automated-review's suppression/scope config (LIVE; may be empty).
- `review-concepts-distilled.md` — themed summary of the 188 KB concepts.yml
  (STATIC, ships with the toolbox; re-distill manually when it drifts).

Used by `skills/codex-review/SKILL.md`. Codex quota is limited — see the Codex tier in
`rules/performance.md` for when Codex runs (pre-PR review, toolbox self-review,
opt-in planning second opinion) and when it must NOT (reminders/watchdog).
README

info "Codex knowledge pack ready at $PACK_DIR"
