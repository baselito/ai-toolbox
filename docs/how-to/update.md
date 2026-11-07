# Updating

How updates work, the weekly check, update.sh behaviour, and the PR review process.

> **All updating happens in the `ai-engineering` repo — never in your project repos.** Your project repos don't contain agents, skills, or rules (those live on your machine at `~/.claude/`). When updates are available, you update `ai-engineering`, then re-run `install.sh` to copy the new files to your machine.

---

## When to Read This

- You received a notification that updates are available
- You want to understand how the update process works
- You want to run update.sh manually

---

## Why Updates Exist

This toolbox doesn't write all its agents, skills, and rules from scratch. It's built on top of three actively maintained open-source repos. When those repos release improvements — a better code review agent, a new debugging technique, a stricter security rule — you want those improvements in your toolbox too.

## What Gets Updated From Each Repo

| Upstream repo | What we pull | What we use it for |
|---|---|---|
| [ECC](https://github.com/affaan-m/everything-claude-code) | Rules (`common/` + `typescript/`) — diffed before overwrite | Coding style, security, performance, git workflow standards that run on every task |
| [Superpowers](https://github.com/obra/superpowers) | Nothing — the 5 skills this script fetches are all LOCAL-OWNED (see below); 2 more Superpowers-origin skills (`test-driven-development`, `receiving-code-review`) are vendored in this repo and were never part of the fetch list at all | N/A — toolbox-forked versions are used instead |
| [Agency Agents](https://github.com/msitarzewski/agency-agents) | Nothing — the repo isn't cloned; all 8 agents are LOCAL-OWNED (see below) | N/A — toolbox-forked versions are used instead |

**Not updated by this script:** Our custom agents (`accessibility-auditor`, `performance-benchmarker`, `docs-lookup`), custom skills (`advisory-discovery`, `work-breakdown`, `discovery`, `code-review-orchestration`, etc.), commands (`/flow`, `/start`, `/bug`, etc.), MCP configs, and orchestration rules. Those are ours — they only change when we change them. `test-driven-development` and `receiving-code-review` are Superpowers-origin (see `source:` in their frontmatter) but are vendored copies living in this repo's own `skills/` directory rather than being pulled by the 5-skill `SUPERPOWERS_SKILLS` fetch list below — this script never touches them either way.

## LOCAL-OWNED Files — Never Synced From Upstream

**Audit finding (2026-07-02):** `update.sh` used to blind-copy upstream files over local ones with no diff check. A verified comparison against live upstream clones found every file we pull from Superpowers and Agency Agents had been substantially rewritten for toolbox — the old sync would have silently destroyed that work on the next run. Two things changed as a result:

1. **A LOCAL-OWNED manifest** at the top of `update.sh` names every file/directory the script must never overwrite or delete: all 5 Superpowers skill directories (`brainstorming`, `systematic-debugging`, `using-git-worktrees`, `verification-before-completion`, `finishing-a-development-branch`), all 8 Agency Agents files (`project-manager-senior`, `jira-workflow-steward`, `devops-automator`, `incident-response-commander`, `security-engineer`, `evidence-collector`, `reality-checker`, `api-tester`), and the 7 ECC-origin rules (`agents`, `coding-style`, `development-workflow`, `git-workflow`, `performance`, `security`, `testing`) — all heavy toolbox rewrites (e.g. `rules/agents.md` is 326 local lines vs 51 upstream). Rules are listed per-file, never as a `rules/` directory entry, so NEW upstream rules we have no local copy of (e.g. ECC's `code-review.md`, `hooks.md`, `patterns.md`) remain pullable through the new-file path.
2. **The Agency Agents sync is retired entirely** — `update.sh` no longer clones `agency-agents` at all. The upstream repo restructured into division-prefixed folders, which had already made the old path-search logic a silent no-op; that accident is now a documented, deliberate policy instead.

If upstream ships an improvement worth having in one of these files, pull it in manually as a reviewed edit to the local file — not via this script. When upstream DOES differ from a local-owned file, the run prints `LOCAL-OWNED — upstream differs (+N/-M), review manually` so you get awareness without clobber risk.

## Diff-Before-Overwrite for Everything Else

For files NOT on the LOCAL-OWNED manifest (e.g. new upstream rules we've never pulled), `update.sh` diffs the upstream file against the local one before touching anything:

- **Identical** → skipped silently, no noise in the diff
- **Different** → copied, and recorded with a `+N/-M` line-count summary
- **New upstream file with no local counterpart** → copied, counted as fully "added"

At the end of the run, the script prints a "Files changed by this sync" list with one `+N/-M` line per file, so the reviewer sees exactly what moved before ever looking at `git diff`.

## How the Update Process Works

Updates are never automatic. The process is:
1. Periodically check upstream repos for changes (weekly recommended)
2. You run `update.sh` manually when your team is ready
4. Review the diff, commit what you want, push a PR, test, merge

---

## Checking for Updates

There is no automated notifier — check manually. `./scripts/verify.sh` warns when the ai-engineering repo itself has unpulled origin commits. `./scripts/update.sh` pulls and diffs ECC rules on a review branch — Superpowers and Agency Agents are LOCAL-OWNED, so the script reports them as skipped rather than checking for upstream changes:

```
Files changed by this sync:
  rules/testing.md (+12/-3)
LOCAL-OWNED (toolbox fork) — skipped: skills/brainstorming
...
Run ./scripts/update.sh to review and create a PR.
```

---

## Step-by-Step Update Flow

All steps happen in the **`ai-engineering` repo** — not your project repos.

---

### Step 1 — Check for updates

You'll know updates are available from one of these:
- `./scripts/verify.sh` Part 3 (warns when ai-engineering has unpulled origin commits)
- Running `update.sh` manually to check the three upstreams

---

### Step 2 — Run update.sh

You can run this from **anywhere** — the script finds the `ai-engineering` repo automatically.

```bash
# From inside ai-engineering:
./scripts/update.sh

# Or from any project repo (auto-detects ai-engineering location):
~/Developer/ai-engineering/scripts/update.sh
```

The script:
1. Finds the `ai-engineering` repo (searches common locations if not run from inside it)
2. Checks for a clean working tree (fails if you have uncommitted changes)
3. Creates a branch: `update/ecc-YYYY-MM-DD`
4. Downloads the latest files from upstream repos
5. Shows exactly what changed (diff summary + detailed diff)
6. **Stops and waits** — nothing is applied yet

> Your project repo is never touched. All changes happen in `ai-engineering`.

> **Codex note:** `update.sh` only pulls upstream changes into a review branch — it has no Codex logic and ignores `INSTALL_CODEX`. The Codex opt-in lives entirely in `install.sh`, which you re-run after merging the update branch. See `rules/workflow-discipline.md` Rule 8 (8a = Codex gating, `install.sh` only; 8b = docs verification, both scripts).

---

### Step 3 — Review the changes

Read the diff. The script only updates these components:

| Component | Updated? | Notes |
|---|---|---|
| ECC rules | ✅ Yes, diffed first | Coding style, security, performance standards — only files that actually differ are copied, each with a `+N/-M` summary |
| Superpowers skills | ❌ Never (LOCAL-OWNED) | All 5 are toolbox rewrites — see "LOCAL-OWNED Files" above |
| Agency agents | ❌ Never (LOCAL-OWNED, repo not cloned) | All 8 are toolbox rewrites — see "LOCAL-OWNED Files" above |
| Custom agents | ❌ Never touched | Our agents stay as-is |
| Custom skills | ❌ Never touched | Our skills stay as-is |
| Commands | ❌ Never touched | Our commands stay as-is |
| MCP configs | ❌ Never touched | Our configs stay as-is |

---

### Step 4 — Commit and create a PR

```bash
git add -p                  # stage the changes you want to keep
git commit -m "chore: pull upstream updates (YYYY-MM-DD)"
git push -u origin update/ecc-YYYY-MM-DD
```

Create a PR on GitHub. Let the team review it. If the changes look wrong, delete the branch — nothing happened.

---

### Step 5 — After the PR is merged, re-install on your machine

Merging the PR only updates the `ai-engineering` repo on GitHub. Your local `~/.claude/` still has the old files until you re-install:

```bash
cd ai-engineering          # ← the toolbox repo, NOT your project
./scripts/install.sh       # pulls latest from main, re-installs everything
```

`install.sh` automatically **cleans** the managed directories (`agents/`, `skills/`, `commands/`, `rules/` inside `~/.claude/`) before copying fresh files. This removes any stale files from renamed or deleted components — you don't need to uninstall first.

What is **not** touched during cleanup:
- `~/.claude/memory.md` (your personal defaults)
- `~/.claude/settings.json` (permissions and hooks config)
- `~/.claude/hooks/` (hook scripts)
- `~/.claude.json` (MCP server config)

`install.sh` runs `verify.sh` at the end to confirm everything is healthy.

**Every developer on the team** needs to run this on their own machine after the PR is merged — the install is per-machine, not shared.

---

## Notes

- Updates never apply automatically — always a conscious team decision
- The update branch is safe to delete if you decide not to apply the changes
- LOCAL-OWNED files (all 5 Superpowers skills, all 8 Agency Agents) are never touched by this script — there's nothing to review-for-conflicts there because nothing is copied
- For non-owned files (ECC rules), review the `+N/-M` summary and the diff for conflicts with our customisations before merging
- Run `verify.sh` after applying updates to confirm nothing is broken
