#!/usr/bin/env bash
set -e

# =============================================================================
# AI Engineering — Update Script
# Diffs and pulls ECC rule updates. Superpowers skills and Agency Agents
# files are LOCAL-OWNED toolbox rewrites (see LOCAL_OWNED_PATHS below) and are
# never fetched or overwritten.
# Creates a branch and shows diff — never auto-applies.
# =============================================================================

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ok()   { printf "${GREEN}✅ %s${NC}\n" "$1"; }
warn() { printf "${YELLOW}⚠️  %s${NC}\n" "$1"; }
fail() { printf "${RED}❌ %s${NC}\n" "$1"; }
info() { printf "${BLUE}ℹ️  %s${NC}\n" "$1"; }

# ---------------------------------------------------------------------------
# CHANGED_FILES — running list of files this run actually modified.
# WHY: the final summary needs to tell the reviewer exactly what changed,
# not just "diff found something" — see the per-file +N/-M reporting below.
# ---------------------------------------------------------------------------
CHANGED_FILES=()
# LOCAL-OWNED paths where upstream diverged (or shipped new files) — never
# copied, but the final summary must surface them so "up to date" is honest.
OWNED_DIVERGENCES=()

# ---------------------------------------------------------------------------
# Locate ai-engineering repo (works from any directory)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# If script was called directly from the repo, use that
if [ -f "$REPO_ROOT/CLAUDE.md" ] && grep -q "AI Engineering" "$REPO_ROOT/CLAUDE.md" 2>/dev/null; then
  : # already found
else
  # Not in ai-engineering — search common locations
  REPO_ROOT=""
  for candidate in \
    "$HOME/Developer/ai-engineering" \
    "$HOME/repos/ai-engineering" \
    "$HOME/repos/ai-engineering" \
    "$HOME/ai-engineering" \
    "$HOME/dev/ai-engineering" \
    "$HOME/projects/ai-engineering"; do
    if [ -f "$candidate/CLAUDE.md" ] && grep -q "AI Engineering" "$candidate/CLAUDE.md" 2>/dev/null; then
      REPO_ROOT="$candidate"
      break
    fi
  done

  if [ -z "$REPO_ROOT" ]; then
    fail "Cannot find the ai-engineering repo."
    info "Looked in: ~/Developer/ai-engineering, ~/repos/ai-engineering, ~/ai-engineering, ~/dev/ai-engineering, ~/projects/ai-engineering"
    info "Either cd into ai-engineering and run ./scripts/update.sh, or clone it first:"
    info "  git clone https://github.com/baselito/ai-toolbox.git"
    exit 1
  fi

  info "Found ai-engineering at: $REPO_ROOT"
  info "Switching there now (your project repo is untouched)."
fi

cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Ensure clean working tree
# ---------------------------------------------------------------------------
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
  fail "Working tree has uncommitted changes. Commit or stash them first."
  exit 1
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
DATE_STAMP="$(date +%Y-%m-%d)"
UPDATE_BRANCH="update/ecc-${DATE_STAMP}"
TEMP_DIR="$(mktemp -d)"

# Upstream repos — only fetch specific files we use.
# NOTE: agency-agents is intentionally NOT cloned — see "Agency agents"
# section below (sync retired, all 8 agents are local-owned toolbox rewrites).
ECC_REPO="https://github.com/affaan-m/everything-claude-code.git"
SUPERPOWERS_REPO="https://github.com/obra/superpowers.git"

# Superpowers skills we use (5 only)
SUPERPOWERS_SKILLS=(
  "brainstorming"
  "systematic-debugging"
  "using-git-worktrees"
  "verification-before-completion"
  "finishing-a-development-branch"
)

# Agency agents we use (8 only)
AGENCY_AGENTS=(
  "project-manager-senior"
  "jira-workflow-steward"
  "devops-automator"
  "incident-response-commander"
  "security-engineer"
  "evidence-collector"
  "reality-checker"
  "api-tester"
)

# ---------------------------------------------------------------------------
# LOCAL-OWNED manifest — paths this script must NEVER overwrite or delete.
#
# WHY THIS EXISTS (audit 2026-07-02): update.sh used to blind-`cp` upstream
# files over local ones with no diff check. Verified against a live upstream
# clone, EVERY superpowers skill we pull and EVERY agency-agents file we pull
# has been substantively rewritten for toolbox (automated-review/jira-steward/handover/
# Codex wiring in finishing-a-development-branch and verification-before-
# completion; EnterWorktree + gitignore-verification logic in
# using-git-worktrees; /flow planner hand-off rewiring in brainstorming;
# prose-tightening + toolbox process notes in systematic-debugging). All 8
# agency-agents files carry a `source:` frontmatter field the upstream
# persona-format files don't have, and are complete rewrites to our schema.
#
# A file on this list is skipped entirely — never copied, never deleted —
# even if upstream has changed it. If upstream ships something worth pulling
# in, that's a manual, reviewed edit to our local file, not a script copy.
#
# Skill entries name the whole directory (not just SKILL.md) — some of these
# skills carry supporting reference files (e.g. systematic-debugging/
# root-cause-tracing.md) that are just as local-owned as SKILL.md itself.
# ---------------------------------------------------------------------------
LOCAL_OWNED_PATHS=(
  "skills/brainstorming"
  "skills/systematic-debugging"
  "skills/using-git-worktrees"
  "skills/verification-before-completion"
  "skills/finishing-a-development-branch"
  "agents/project-manager-senior.md"
  "agents/jira-workflow-steward.md"
  "agents/devops-automator.md"
  "agents/incident-response-commander.md"
  "agents/security-engineer.md"
  "agents/evidence-collector.md"
  "agents/reality-checker.md"
  # The 7 vendored ECC agents (code-reviewer, tdd-guide, security-reviewer,
  # database-reviewer, e2e-runner, refactor-cleaner, build-error-resolver) are
  # NOT listed here on purpose. This manifest only guards paths this script
  # actually syncs, and the ECC branch never touches agents/ at all — it only
  # passes rules to copy_if_changed. Listing them would imply a protection and
  # an upstream-difference report that do not exist (Codex pre-PR review, P2).
  # They are safe because nothing syncs them, not because they are listed.
  "agents/api-tester.md"
  # The 7 ECC-origin rules are heavy toolbox rewrites (e.g. rules/agents.md is
  # 326 local lines vs 51 upstream) — forks, not tracked copies. Listed
  # PER-FILE (never a "rules/" directory entry) so NEW upstream rules that we
  # have no local copy of (e.g. code-review.md, hooks.md, patterns.md) still
  # fall through to copy_if_changed's new-file branch and remain pullable.
  "rules/agents.md"
  "rules/coding-style.md"
  "rules/development-workflow.md"
  "rules/git-workflow.md"
  "rules/performance.md"
  "rules/security.md"
  "rules/testing.md"
)

# is_local_owned <repo-relative-path> — true if the path IS a manifest entry,
# or is nested inside one (so a directory entry like "skills/foo" also
# protects "skills/foo/bar.md").
is_local_owned() {
  local candidate="$1"
  local owned
  for owned in "${LOCAL_OWNED_PATHS[@]}"; do
    case "$candidate" in
      "$owned"|"$owned"/*)
        return 0
        ;;
    esac
  done
  return 1
}

# copy_if_changed <src-file> <dest-file-repo-relative-path>
# Diffs before copying. Identical files are skipped silently (no-op).
# Different files are copied AND recorded with a +N/-M summary line so the
# final report tells the reviewer exactly what moved, not just "diff found
# something". This is the core of "diff-before-overwrite" — the alternative
# to the old blind `cp`.
copy_if_changed() {
  local src="$1"
  local rel_dest="$2"
  local dest="$REPO_ROOT/$rel_dest"

  if is_local_owned "$rel_dest"; then
    # Awareness without clobber risk: if upstream genuinely differs from our
    # fork, say so — a maintainer can review upstream's changes manually and
    # cherry-pick ideas. Never copied either way.
    if [ -f "$dest" ] && ! diff -q "$src" "$dest" >/dev/null 2>&1; then
      local o_added o_removed
      o_added=$(diff "$dest" "$src" 2>/dev/null | grep -c '^>' || true)
      o_removed=$(diff "$dest" "$src" 2>/dev/null | grep -c '^<' || true)
      info "LOCAL-OWNED (toolbox fork) — upstream differs (+${o_added}/-${o_removed}), review manually: $rel_dest"
      OWNED_DIVERGENCES+=("$rel_dest (upstream differs +${o_added}/-${o_removed})")
    elif [ ! -f "$dest" ]; then
      # Upstream ships a file under a local-owned path that we don't have —
      # still never pulled (the whole path is owned), but say so distinctly.
      info "LOCAL-OWNED path — upstream has a NEW file here, not pulled: $rel_dest"
      OWNED_DIVERGENCES+=("$rel_dest (new upstream file, not pulled)")
    else
      info "LOCAL-OWNED (toolbox fork) — skipped: $rel_dest"
    fi
    return 0
  fi

  if [ -f "$dest" ] && diff -q "$src" "$dest" >/dev/null 2>&1; then
    return 0  # identical — nothing to do, no noise
  fi

  local added=0 removed=0
  if [ -f "$dest" ]; then
    # `diff` exits 1 when files differ — that's expected here, not a failure,
    # so don't let it trip `set -e`.
    local stat
    stat=$(diff "$dest" "$src" 2>/dev/null | grep -c '^>' || true)
    added="$stat"
    stat=$(diff "$dest" "$src" 2>/dev/null | grep -c '^<' || true)
    removed="$stat"
  else
    # No local counterpart — this is a brand-new file from upstream, so the
    # whole thing counts as "added" (nothing existed locally to remove).
    # awk counts records, not newline chars, so a missing trailing newline
    # on the last line doesn't undercount by one (as `wc -l` would).
    added=$(awk 'END {print NR}' "$src")
  fi

  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  CHANGED_FILES+=("$rel_dest (+$added/-$removed)")
}

# ---------------------------------------------------------------------------
# Create update branch
# ---------------------------------------------------------------------------
info "Creating update branch: $UPDATE_BRANCH"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
# Fail FAST if the branch already exists — reusing it could materialize stale
# committed changes from an earlier same-day run (possibly made by the old
# pre-manifest script) onto LOCAL-OWNED paths before the guards run. The user
# decides: delete the old branch or finish reviewing it first.
if git show-ref --verify --quiet "refs/heads/$UPDATE_BRANCH"; then
  fail "Branch $UPDATE_BRANCH already exists (from an earlier run today).
  Review or delete it first:  git branch -D $UPDATE_BRANCH
  Then re-run this script."
  exit 1
fi
git checkout -b "$UPDATE_BRANCH"

# ---------------------------------------------------------------------------
# Fetch upstream — ECC
# ---------------------------------------------------------------------------
info "Checking ECC for updates..."

ECC_DIR="$TEMP_DIR/ecc"
git clone --depth 1 --quiet "$ECC_REPO" "$ECC_DIR" 2>/dev/null || {
  warn "Could not clone ECC repo — skipping ECC updates"
  ECC_DIR=""
}

if [ -n "$ECC_DIR" ] && [ -d "$ECC_DIR" ]; then
  # ECC rules — common/ and typescript/ only. Every local rules/*.md file
  # that shares a name with an ECC common rule has been substantially
  # rewritten for toolbox (verified 2026-07-02: e.g. rules/agents.md is 326
  # local lines vs 51 upstream). copy_if_changed diffs first so an identical
  # upstream rule is a no-op and a genuinely different one is copied with a
  # visible +N/-M line instead of silently clobbering our rewrite.
  if [ -d "$ECC_DIR/rules/common" ]; then
    for f in "$ECC_DIR/rules/common/"*.md; do
      [ -f "$f" ] || continue
      copy_if_changed "$f" "rules/$(basename "$f")"
    done
  fi
  if [ -d "$ECC_DIR/rules/typescript" ]; then
    for f in "$ECC_DIR/rules/typescript/"*.md; do
      [ -f "$f" ] || continue
      copy_if_changed "$f" "rules/$(basename "$f")"
    done
  fi
  ok "ECC rules checked"

  # Note: ECC agents, skills, and commands are managed by the ECC plugin itself.
  # We do NOT overwrite custom command files in commands/ — those are ours.
  info "ECC agents/skills managed by plugin — not overwriting repo files"
fi

# ---------------------------------------------------------------------------
# Fetch upstream — Superpowers (5 skills only)
# ---------------------------------------------------------------------------
info "Checking Superpowers for updates..."

SP_DIR="$TEMP_DIR/superpowers"
git clone --depth 1 --quiet "$SUPERPOWERS_REPO" "$SP_DIR" 2>/dev/null || {
  warn "Could not clone Superpowers repo — skipping"
  SP_DIR=""
}

if [ -n "$SP_DIR" ] && [ -d "$SP_DIR" ]; then
  # All 5 skills we pull from Superpowers are LOCAL-OWNED (see manifest
  # above) — every one carries toolbox-specific wiring verified against a
  # live upstream clone on 2026-07-02. copy_if_changed still walks each
  # upstream file so the "LOCAL-OWNED — skipped" line is visible per file,
  # but is_local_owned() short-circuits every copy — nothing here is ever
  # written. This loop is intentionally a no-op review trail, not dead code:
  # if a 6th skill is ever added to SUPERPOWERS_SKILLS without also adding
  # it to LOCAL_OWNED_PATHS, this is where it would start actually syncing.
  for skill in "${SUPERPOWERS_SKILLS[@]}"; do
    # Look for skill in common locations within the superpowers repo
    for search_dir in "$SP_DIR/skills" "$SP_DIR" "$SP_DIR/src/skills"; do
      if [ -d "$search_dir/$skill" ]; then
        while IFS= read -r -d '' upstream_file; do
          rel_path="skills/$skill/${upstream_file#"$search_dir/$skill/"}"
          copy_if_changed "$upstream_file" "$rel_path"
        done < <(find "$search_dir/$skill" -type f -print0)
        break
      fi
    done
  done
  ok "Superpowers skills checked (${#SUPERPOWERS_SKILLS[@]} skills — all local-owned, see manifest)"
fi

# ---------------------------------------------------------------------------
# Agency agents (8 agents) — sync intentionally retired (audit 2026-07-02)
#
# WHY NO CLONE / NO SEARCH HERE: all 8 agents in AGENCY_AGENTS are full toolbox
# rewrites — different frontmatter schema entirely (`source:`, `effort:`,
# our own model assignments) versus upstream's persona-format files. On top
# of that, upstream restructured into division-prefixed folders (e.g.
# `project-management/project-management-jira-workflow-steward.md`), so the
# old path-search loop (agents/, repo root, src/agents/) was already a
# silent no-op before this rewrite — it just happened to be the thing
# accidentally protecting our rewrites from being clobbered. That accident
# is now a deliberate, documented policy instead: these 8 agents are
# LOCAL-OWNED (see manifest above) and this script never clones or touches
# the agency-agents repo at all. If a specific upstream agent update is ever
# worth pulling, do it as a manual, reviewed edit to the local file.
# ---------------------------------------------------------------------------
info "Agency agents (8) are LOCAL-OWNED (toolbox rewrites) — sync retired, not fetched"
for agent in "${AGENCY_AGENTS[@]}"; do
  info "LOCAL-OWNED (toolbox fork) — skipped: agents/$agent.md"
done
ok "Agency agents checked (${#AGENCY_AGENTS[@]} agents — all local-owned, upstream not fetched)"

# ---------------------------------------------------------------------------
# Clean up temp directory
# ---------------------------------------------------------------------------
rm -rf "$TEMP_DIR"

# ---------------------------------------------------------------------------
# Re-sync toolbox lessons knowledge pack
# WHY: An update may have added new lessons to knowledge/toolbox-lessons.yml
# (via a merged learned-lessons PR). The fast tier needs to be rebuilt so
# review agents and Codex pick up the new lessons on the next run.
# Fail-soft: if the source is missing or sync fails, update continues.
# ---------------------------------------------------------------------------
if [ -f "$REPO_ROOT/scripts/sync-toolbox-lessons.sh" ]; then
  info "Re-syncing toolbox lessons knowledge pack..."
  # Exit 3 is NOT the same as a sync failure: the pack wrote fine, but the fast tier
  # is empty while the source declares lessons. Reporting it as "may be stale" would
  # understate it — agents read nothing at all.
  SYNC_RC=0
  bash "$REPO_ROOT/scripts/sync-toolbox-lessons.sh" --quiet 2>/dev/null || SYNC_RC=$?
  if [ "$SYNC_RC" -eq 0 ]; then
    ok "Toolbox lessons knowledge pack re-synced."
  elif [ "$SYNC_RC" -eq 3 ]; then
    warn "Toolbox lessons re-synced but the FAST TIER IS EMPTY — agents will read no lessons."
    warn "A lesson block in knowledge/toolbox-lessons.yml is likely malformed (missing 'status: active')."
    warn "Diagnose with: bash scripts/sync-toolbox-lessons.sh"
  elif [ "$SYNC_RC" -eq 4 ]; then
    # Own branch for the same reason as install.sh: the pack synced fine, so the
    # generic "may be stale" message below would misdescribe it.
    #
    # ⛔ SAY ONLY WHAT EXIT 4 PROVES. ⛔ Same three causes as install.sh: one or
    # more lessons above ordinary priority were evicted; OR the decision manifest
    # was missing, truncated or unterminated and the sync escalated rather than
    # stay silent — which it does even when every evicted lesson was ordinary; OR
    # the capping pass recorded its decisions in full and then failed, in which
    # case every eviction IS named and only the tier's agreement is in doubt. The
    # earlier wording asserted the first, unconditionally and in the singular, and
    # the headline asserted a SEVERE eviction the other two do not prove.
    warn "Toolbox lessons re-synced, but the run could NOT confirm every 'priority: high' lesson survived the 8 KB cap (exit 4)."
    warn "That means one of five things, and only the sync's own output tells you which:"
    warn "  - one or more lessons above ordinary priority were pushed out of the fast tier, or"
    warn "  - the sync could not confirm what was dropped — its decision manifest was missing,"
    warn "    truncated, or unterminated — so it escalated rather than report nothing, or"
    warn "  - the capping pass recorded its decisions in full and then failed; it NAMES every"
    warn "    eviction, but the fast tier on disk may not match what it recorded."
    warn "  - the record was complete but tagged to ANOTHER run — a concurrent sync sharing this"
    warn "    HOME replaced it mid-run, so its verdicts describe that run's fast tier, not this one's, or"
    warn "  - a reader of the record failed, so the figures could not be taken at all."
    warn "The SLOW tier (the full lesson set) is on disk either way; anything evicted stays there but reaches no review prompt."
    warn "The FAST tier is not guaranteed on this path — a pass that recorded its decisions and then died can leave none at all."
    warn "See which lessons, and how many, with: bash scripts/sync-toolbox-lessons.sh"
  else
    warn "Toolbox lessons sync failed (non-fatal) — fast-tier lessons may be stale; re-run scripts/sync-toolbox-lessons.sh."
  fi
fi

# ---------------------------------------------------------------------------
# Check README counts against actual files
# ---------------------------------------------------------------------------
info "Checking README component counts..."

ACTUAL_AGENTS=$(ls "$REPO_ROOT/agents/"*.md 2>/dev/null | wc -l | tr -d ' ')
ACTUAL_SKILLS=$(ls -d "$REPO_ROOT/skills/"*/ 2>/dev/null | wc -l | tr -d ' ')
ACTUAL_COMMANDS=$(ls "$REPO_ROOT/commands/"*.md 2>/dev/null | wc -l | tr -d ' ')
ACTUAL_RULES=$(ls "$REPO_ROOT/rules/"*.md 2>/dev/null | wc -l | tr -d ' ')
ACTUAL_DOCS=$(find "$REPO_ROOT/docs" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')

COUNT_MISMATCH=false

# Check agency agents count (look for "8 agency" or "8 specialized" in README)
README_AGENCY=$(grep -oE '[0-9]+ agency' "$REPO_ROOT/README.md" | head -1 | grep -oE '[0-9]+')
if [ -n "$README_AGENCY" ] && [ "$README_AGENCY" != "$ACTUAL_AGENTS" ]; then
  warn "README says $README_AGENCY agency agents but repo has $ACTUAL_AGENTS — update README"
  COUNT_MISMATCH=true
fi

# Check superpowers skills count
README_SKILLS=$(grep -oE '[0-9]+ superpowers' "$REPO_ROOT/README.md" | head -1 | grep -oE '[0-9]+')
if [ -n "$README_SKILLS" ] && [ "$README_SKILLS" != "$ACTUAL_SKILLS" ]; then
  warn "README says $README_SKILLS superpowers skills but repo has $ACTUAL_SKILLS — update README"
  COUNT_MISMATCH=true
fi

# Check commands count
README_CMDS=$(grep -oE 'Commands \| [0-9]+' "$REPO_ROOT/README.md" | head -1 | grep -oE '[0-9]+')
if [ -n "$README_CMDS" ] && [ "$README_CMDS" != "$ACTUAL_COMMANDS" ]; then
  warn "README says $README_CMDS commands but repo has $ACTUAL_COMMANDS — update README"
  COUNT_MISMATCH=true
fi

# Check rules count
README_RULES=$(grep -oE 'Rules \| [0-9]+' "$REPO_ROOT/README.md" | head -1 | grep -oE '[0-9]+')
if [ -n "$README_RULES" ] && [ "$README_RULES" != "$ACTUAL_RULES" ]; then
  warn "README says $README_RULES rules but repo has $ACTUAL_RULES — update README"
  COUNT_MISMATCH=true
fi

# Check docs count
README_DOCS=$(grep -oE '[0-9]+ documentation files' "$REPO_ROOT/README.md" | head -1 | grep -oE '[0-9]+')
if [ -n "$README_DOCS" ] && [ "$README_DOCS" != "$ACTUAL_DOCS" ]; then
  warn "README says $README_DOCS docs but repo has $ACTUAL_DOCS — update README"
  COUNT_MISMATCH=true
fi

if [ "$COUNT_MISMATCH" = true ]; then
  warn "README counts are out of sync. Update the numbers in README.md and CLAUDE.md before committing."
else
  ok "README counts match actual files"
fi

# ---------------------------------------------------------------------------
# Show what changed
#
# CHANGED_FILES was populated by copy_if_changed() above — every file that
# was actually copied because it differed from our local version, with its
# +N/-M line count. This is the explicit, per-file record the diff-before-
# overwrite design promised: the reviewer sees exactly what moved, not just
# a generic "diff found something".
# ---------------------------------------------------------------------------
printf "\n"
info "Changes found:"
printf "\n"

if [ "${#CHANGED_FILES[@]}" -eq 0 ]; then
  if [ "${#OWNED_DIVERGENCES[@]}" -eq 0 ]; then
    ok "No upstream changes detected. Everything is up to date."
  else
    # Honest summary: nothing copyable changed, but owned forks have upstream
    # movement worth a manual look. NOT "everything is up to date".
    ok "No copyable upstream changes — but ${#OWNED_DIVERGENCES[@]} LOCAL-OWNED path(s) have upstream divergence (never auto-copied):"
    for entry in "${OWNED_DIVERGENCES[@]}"; do
      printf "  %s\n" "$entry"
    done
    info "Review upstream manually and cherry-pick as reviewed edits if desired."
  fi
  info "Switching back to $CURRENT_BRANCH"
  git checkout "$CURRENT_BRANCH"
  git branch -d "$UPDATE_BRANCH" 2>/dev/null || true
  exit 0
fi

printf "${BLUE}── Files changed by this sync ──${NC}\n"
for entry in "${CHANGED_FILES[@]}"; do
  printf "  %s\n" "$entry"
done

if [ "${#OWNED_DIVERGENCES[@]}" -gt 0 ]; then
  printf "\n${BLUE}── LOCAL-OWNED divergences (never auto-copied — manual review) ──${NC}\n"
  for entry in "${OWNED_DIVERGENCES[@]}"; do
    printf "  %s\n" "$entry"
  done
fi

printf "\n"
# Show unstaged changes summary
git diff --stat

printf "\n"
info "Detailed diff:"
git diff

# ---------------------------------------------------------------------------
# Instructions — never auto-commit
# ---------------------------------------------------------------------------
printf "\n"
printf "${GREEN}════════════════════════════════════════════════════${NC}\n"
printf "${GREEN}  Update branch ready: $UPDATE_BRANCH              ${NC}\n"
printf "${GREEN}════════════════════════════════════════════════════${NC}\n"
printf "\n"
info "Changes are on branch $UPDATE_BRANCH — your main branch is untouched."
printf "\n"
printf "${YELLOW}── Why a separate branch? ──${NC}\n"
info "A new or changed ECC rule might conflict with our customisations"
info "or duplicate something we already handle. Review everything"
info "before merging."
printf "\n"
printf "${BLUE}── What to check ──${NC}\n"
info "  • Do any changed rules conflict with our custom rules in rules/?"
info "  • Do updated skills overlap with our custom skills"
info "    (test-driven-development, receiving-code-review)?"
info "  • Note: agency-agents (8 agents) and 5 superpowers skills are"
info "    LOCAL-OWNED — never fetched/copied by this script (see the"
info "    'LOCAL-OWNED (toolbox fork) — skipped' lines above). Pull specific"
info "    upstream improvements into them manually, reviewed, if wanted."
printf "\n"
printf "${BLUE}── Next steps ──${NC}\n"
info "  1. Review the diff above carefully"
info "  2. Stage what you want:  git add -p"
info "  3. Commit:  git commit -m \"chore: pull upstream updates ($DATE_STAMP)\""
info "  4. Push the branch:  git push -u origin $UPDATE_BRANCH"
info "  5. Create a PR on GitHub for team review"
info "  6. Merge when the team is happy"
printf "\n"
printf "${BLUE}── After merging — apply to your machine ──${NC}\n"
info "  cd ai-engineering"
info "  ./scripts/install.sh         # auto-pulls latest + re-installs + verifies"
printf "\n"
warn "Merging the PR only updates the repo on GitHub."
warn "Your local ~/.claude/ still has the old versions until you re-run install.sh."
warn "Every developer on the team needs to run install.sh on their own machine."
printf "\n"
warn "If the changes look wrong, just delete the branch: git checkout main && git branch -D $UPDATE_BRANCH"
printf "\n"
