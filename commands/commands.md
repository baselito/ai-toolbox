# /commands — Quick Reference

Show this list when the user types `/commands`. Do not run any other command — just display the table and wait.

---

Display the following exactly:

```
Available commands:

  /start vs running a command directly — what's the difference?
  ───────────────────────────────────────────────────────────────

  /start reads your Jira board, picks the right command based on
  the ticket type, and routes you automatically. It's the recommended
  daily entry point — you don't need to think about which command.

  Running a command directly (e.g. /bug, /flow, /hotfix) skips the
  menu and goes straight to that workflow. Use this when you already
  know what you need.

  Nothing is lost either way:
  - Project not configured yet? Both paths run /init automatically
  - Jira configured? Both create tickets and move statuses
  - Beads enabled? Both create and track beads
  - All agents run the same regardless of entry point

  The only differences:
  - /start shows the menu and routes by ticket type — direct commands don't
  - /start reads the board and hands the ticket to the command —
    direct commands ask you to describe the issue or paste a ticket

  Getting started
  ───────────────────────────────────────────────────────────────

  /start        Start here every morning. Shows a menu, reads
                your Jira board, and routes you to the right
                command based on the ticket type.
                Example: "I'm starting my day, what should I
                work on?" → /start

  /init         Run once per project. Asks about your stack,
                Jira board, methodology, and tracking preferences.
                Creates .claude/PROJECT.md. Runs automatically
                if you use /start in an unconfigured project.
                Example: "I just cloned a new repo and want to
                set it up for the toolbox" → /init

  /continue     Resuming after a tool switch or session break.
                Reads handover files and picks up where the
                previous session left off.
                Example: "I hit the rate limit earlier, now I'm
                back and want to continue" → /continue

  /goal         Durable goal control across sessions.
                Starts and inspects GoalRuns, runs one bounded
                iteration, shows advisor status, and supports
                pause/resume/cancel. GPT-6 Astra/Fable advise and
                Opus/Luna work; lightweight agents handle check-ins.
                Jira still uses acli through jira-workflow-steward.
                Auto-merge is toolbox-only after the live gate.

  Building and creating
  ───────────────────────────────────────────────────────────────

  /flow         You have a Jira ticket and want to build it.
                Full workflow: design → code → test → review → PR.
                Kanban and Scrum teams both use this — Scrum
                boards get sprint planning + retrospective
                automatically.
                Example: "I want to build DEV-5644 right now,
                I don't need the /start menu" → /flow

  /build        You want to build something but there's no Jira
                ticket for it. Same quality gates as /flow but
                without Jira. Good for experiments and side tasks.
                Example: "I want to try adding a caching layer,
                there's no ticket for it yet" → /build

  /presentation Create or edit an toolbox PowerPoint using the
                packaged presentation-master skill and template.
                Works with Claude and Codex and validates the
                generated deck before delivery.
                Example: "Make a 6-slide deck about our Q2 progress"
                → /presentation

  Fixing
  ───────────────────────────────────────────────────────────────

  /bug          Something is broken but not urgent. Full
                investigation: reproduce → find root cause →
                fix → add regression test → PR.
                Example: "Users report the search filter returns
                wrong results sometimes" → /bug

  /hotfix       Something is broken and needs fixing today.
                Skips design phase, fast-tracks the CI/CD
                deployment queue. Use when it can't wait.
                Example: "The login page is showing a 500 error
                for some users, we need this fixed now" → /hotfix

  /incident     Production is down right now. Queries Seq logs
                immediately, focuses on restoring service first,
                then does root cause analysis and post-mortem.
                Example: "The whole portal is unreachable, users
                can't access anything" → /incident

  Reviewing
  ───────────────────────────────────────────────────────────────

  /review       You want a code review without writing new code.
                Read-only analysis — no PR created, no branches.
                Example: "A colleague asked me to review their
                PR, I want the agent to help me check it" → /review

  /review-pr    Autonomous PR comment reader. Reads reviewer
                comments (human or automated-review), decides if it
                agrees, and either replies or applies a fix.
                Small fixes (≤ 50 LOC) auto-apply; larger
                changes flag to you.
                Reviewer comments are handled inline as the
                reliable path; every new PR also gets a
                best-effort 1-minute auto-poll. Claude uses CronCreate;
                Codex Desktop uses a heartbeat registered with
                `register-pr-poll.sh`. Both self-terminate when the
                PR is merged or closed. Use `/status` to see active
                polling; cancel it through the host that created it.
                Example: "Automated review posted findings on PR #42,
                process them for me" → /review-pr 42

  /merge-pr     You explicitly want the agent to merge one or
                more PRs you name — no terminal typing. Works on
                ANY repo because you commanded it in chat. Each
                PR still passes the live safety gate (open,
                mergeable, CI green, not changes-requested, all
                threads resolved) or it's refused.
                Example: "merge PR 862 and 863" → /merge-pr 862 863

  /refactor     You want to clean up existing code. No new
                features allowed — only modernisation, dead code
                removal, and pattern improvements.
                Example: "This controller has grown to 800 lines,
                I want to split it up" → /refactor

  /security     You want an OWASP security scan. Produces a
                severity report and offers to fix critical issues.
                Example: "We have a security audit next month,
                let's scan the codebase" → /security

  /perf         Something is slow. Queries Seq logs, runs API
                benchmarks, identifies bottlenecks, and measures
                before/after improvements.
                Example: "The dashboard page takes 8 seconds to
                load, it used to be fast" → /perf

  Utilities
  ───────────────────────────────────────────────────────────────

  /status       PR review activity snapshot — active /review-pr
                polling jobs, recent /review-pr actions from the
                audit log, open PRs with new reviewer comments.
                Read-only, safe to run anytime. Scoped to the
                /review-pr + /loop workflow — not a general
                "what did the agent do" report, so it's usually
                empty when you're mid-fix.
                Example: "Did /review-pr process anything on
                PR #42 while I was at lunch?" → /status

  /ask          Ask any question about the toolbox, report an issue,
                or ask what should be fixed or improved. Reads the
                docs, performs read-only advisory discovery, ranks
                evidence-backed proposals, and prepares approved Jira
                work or a fix branch.
                Example: "What agents run when I touch a
                migration file?" → /ask

  /feedback     Report a problem with the toolbox itself — bugs,
                token waste, agent overlaps, or improvement ideas.

  /commands     This list.
```

After displaying, say: "Type any command to run it. Most developers just use `/start` — it routes you to the right command automatically."
