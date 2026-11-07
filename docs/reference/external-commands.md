# External Commands and Skills Reference

When you type `/` in Claude Code, you see commands from three sources: **ours** (no prefix), **ECC plugin** (some prefixed with `/everything-claude-code:`, most unprefixed as skills), and **Beads plugin** (prefixed with `/beads:`).

**Always use our commands first.** They include full agent orchestration, Jira integration, beads tracking, handover, and quality gates. The ECC commands are standalone and skip all of that.

This page documents every external command and skill so you know what each one does, whether it conflicts with ours, and whether it's relevant to your work.

---

## Can I Disable the Noise?

As of March 2026, Claude Code does not support disabling individual skills from a plugin — only entire plugins can be enabled/disabled. Since we depend on ECC for agents, rules, and core skills, we can't disable the plugin without losing functionality we need.

The `/` list will always show all 125+ ECC skills. This page helps you know which ones to ignore and which ones are useful.

If Claude Code adds per-skill disable support in the future, we'll update the install script to disable the noise automatically. Track the feature request: [anthropics/claude-code#14920](https://github.com/anthropics/claude-code/issues/14920).

---

## Our Commands (use these)

These are the 20 commands built for this toolbox. They run the full workflow with agents, quality gates, Jira, and beads tracking.

| Command | What it does |
|---|---|
| `/start` | Daily entry point — menu, ticket routing |
| `/init` | Project setup wizard — auto-detects stack and methodology, asks 5 questions, saves PROJECT.md |
| `/status` | PR review activity snapshot — active /review-pr crons, recent /review-pr actions from audit log, open PRs with new comments. Read-only. Scoped to /review-pr workflow (not a general "what did the agent do" report) |
| `/flow` | Full ticket workflow — design to PR with all quality gates |
| `/build` | Ad-hoc build — no Jira required |
| `/presentation` | PowerPoint creation/editing through the packaged `presentation-master` skill |
| `/bug` | Bug investigation — systematic debugging + fix + PR |
| `/hotfix` | Urgent same-day fix — skips design, fast-tracks CI/CD |
| `/incident` | Production down — logs first, restore service, post-mortem |
| `/review` | Code review — read-only, no PR |
| `/review-pr` | Autonomous PR comment reader — reads reviewer comments, decides agreement, replies or fixes. Inline handling is the reliable path; every new PR also gets a best-effort 1-minute host poll (Claude CronCreate or Codex Desktop heartbeat). A passing auto-poll may merge only `baselito/ai-engineering` after the runtime and live hook gates; other repos are reported ready |
| `/merge-pr` | User-commanded PR merge — `/merge-pr 862 863`. Works in any repo and reuses `pr-action-safety.sh`; it is the fallback for project repos where autonomous merge is disabled |
| `/refactor` | Cleanup — no new features |
| `/security` | OWASP scan — severity report, fix CRITICALs |
| `/perf` | Performance investigation — not broken, just slow |
| `/continue` | Resume after session break — reads `.claude/handover.md`, migrates legacy files to backups |
| `/feedback` | Report toolbox issues |
| `/commands` | Quick reference — lists all commands |
| `/ask` | Q&A + advisory discovery — answer questions, diagnose issues, propose evidence-backed improvements |

---

## Our Skills (use these)

These are the 30 skills installed by the toolbox. They're invoked automatically by our commands during workflows.

| Skill | What it does | Invoked by |
|---|---|---|
| `/brainstorming` | Socratic design refinement — 3-5 scoping questions | `/flow`, `/build` |
| `/work-breakdown` | Decomposes goals into epic/stories/tasks | `/flow` (agent-first/hybrid) |
| `/advisory-discovery` | Read-only evidence gathering and ranked improvement proposals before approval | `/ask`, `/goal advise` |
| `/systematic-debugging` | 4-phase root cause analysis | `/bug`, `/hotfix`, `/incident`, `/perf` |
| `/test-driven-development` | RED-GREEN-REFACTOR enforcement | All work commands |
| `/receiving-code-review` | Technical evaluation of review feedback | During code review |
| `/verification-before-completion` | End-to-end verification before marking done | All work commands |
| `/finishing-a-development-branch` | Branch decision — merge, PR, keep, or discard | All work commands |
| `/using-git-worktrees` | Parallel task execution with isolated branches | `/flow` (when tasks are independent) |
| `/ef-migration-management` | Entity Framework migration patterns | When migration files are touched |
| `/event-driven-messaging` | Event-driven architecture patterns | When messaging code is touched |
| `/microservice-patterns` | Microservice generation patterns | `/build` (microservice work) |
| `/monolith-decomposition` | Monolith-to-microservice decomposition | `/refactor` (architecture work) |
| `/blazor-radzen` | Blazor/Radzen component patterns | When Blazor files are touched |
| `/code-review-orchestration` | Wraps chief-of-staff review orchestration — blocks direct agent spawns | All work commands (code review phase) |
| `/discovery` | Codebase exploration and ticket investigation — delegates to Opus | `/flow`, `/bug`, `/hotfix`, `/incident`, `/perf` |
| `/respond-to-pr-reviews` | PR comment decision framework — agree/disagree evaluation, automated-review keywords, escalation | `/review-pr` — autonomously replies or applies fixes |
| `/codex-review` | Local Codex adversarial review on the current diff before a PR is opened | Pre-PR (when Codex enabled) |
| `/workflow-discipline` | On-demand detail behind the workflow-discipline rule — Stryker keyword grammar, gitignore pre-check script, toolbox install/update gating, incident histories | When a Stryker keyword appears, before branching, or installing/updating the toolbox |
| `/mutation-testing` | Stryker-backed mutation testing for supported stacks, explicit unavailable/not-applicable evidence, and the production-code boundary | Normal verification during `/flow`, `/build`, `/bug`, `/refactor`, and GoalRun |
| `/presentation-master` | unbranded PowerPoint generation/editing with the optional user template and content/layout validation | `/presentation` and any deck request |
| `/pr-automation` | On-demand detail behind the git-workflow auto-poll/merge-readiness directives — CronCreate construction, best-effort cron rationale, four-gate readiness logic, why autonomous self-merge is retired, incident histories | At PR creation, when a cron starves, or when reasoning about the merge gate |
| `/edge-cases` | The detailed edge-case response playbooks behind the edge-cases rule — exact wording per failure scenario (service down, empty result, rejection, invalid input, mid-workflow failure, handover, Scrum/kanban) | When one of those scenarios arises and the standard handling is needed |
| `/cross-tool-sync` | The full provider synchronization rules behind the cross-tool-sync directives — shared runtime, host adapters, count locations, and dead-reference checks | When editing the toolbox itself |
| `/agent-orchestration` | The agent-selection reference behind the agents rule — conditional-agent file-pattern table, parallel-execution order, fixed model assignments | When chief-of-staff selects which agents/models run for a phase or code review |
| `/handover-protocol` | The exact `.claude/handover.md` phase-entry template and the Deviations field guidance behind the handover rule | When appending a phase entry or filling in the Deviations field |
| `/subagent-liveness` | Spawn a dedicated Haiku monitor alongside a long-running background subagent so a working-but-slow agent is never mistaken for a stalled one | When the orchestrator spawns a background subagent expected to run more than ~5 min |
| `/loop-design` | Doctrine for any loop run unattended — the five components, the verification ladder, the three guards (iteration ceiling, no-progress detector, spend cap) and which native primitive each uses, cost-per-accepted-change as the metric, and the when-NOT-to-loop list | Before creating any loop, cron, `/goal` condition or unattended run; when raising a loop bound; when a loop spins without landing anything |
| `/flow-reference` | Reference material for `/flow` kept out of the command file — per-phase Jira comment templates (standard + streamlined), phases-vs-columns worked examples, phase-comment spawn mechanism, per-phase subagent prompt templates | When posting a `/flow` phase comment or composing a subagent spawn prompt |

---

## Beads Plugin Commands (safe to use)

These are utility commands for inspecting beads data. Our workflows create the beads — these let you browse them.

| Command | What it does |
|---|---|
| `/beads:list` | List all beads in the current project |
| `/beads:show` | Show details of a specific bead |
| `/beads:stats` | Show bead statistics (active, blocked, completed) |
| `/beads:search` | Search beads by keyword |
| `/beads:audit` | Audit bead health and consistency |
| `/beads:blocked` | List blocked beads |
| `/beads:close` | Close a bead |
| `/beads:comments` | View/add comments on a bead |
| `/beads:create` | Create a bead manually |
| `/beads:decision` | Record a decision on a bead |
| `/beads:delete` | Delete a bead |
| `/beads:dep` | Manage bead dependencies |
| `/beads:epic` | View/manage epic beads |
| `/beads:export` | Export beads data |
| `/beads:import` | Import beads data |
| `/beads:init` | Initialize beads in a project (our commands do this automatically) |
| `/beads:label` | Add labels to beads |
| `/beads:prime` | Prime the agent with bead context |
| `/beads:quickstart` | Quick setup guide for beads |
| `/beads:ready` | Mark a bead as ready |
| `/beads:rename-prefix` | Rename bead prefixes |
| `/beads:reopen` | Reopen a closed bead |
| `/beads:restore` | Restore a deleted bead |
| `/beads:sync` | Sync beads across sessions |
| `/beads:template` | Manage bead templates |
| `/beads:update` | Update a bead |
| `/beads:version` | Show beads version |
| `/beads:compact` | Compact bead storage |
| `/beads:workflow` | View workflow-linked beads |

---

## ECC Utility Skills (potentially useful alongside our commands)

These don't conflict with our commands — they provide additional capabilities that our workflows don't cover.

| Skill | What it does | When useful |
|---|---|---|
| `/strategic-compact` | Smart context compaction strategy | When context window is filling up mid-workflow |
| `/loop` | Run a command on a recurring interval | Monitoring long-running processes |
| `/deep-research` | Multi-pass research workflow | When you need to understand a complex topic before building |
| `/release-notes` | Generate release notes from commits | After merging a PR or finishing a sprint |
| `/pr-comments` | Handle PR comment discussions | When reviewing PRs with team feedback |
| `/heapdump` | Memory/heap analysis | Debugging memory leaks |
| `/insights` | Analytics and pattern extraction | Understanding codebase trends |
| `/prompt-optimizer` | Refine and optimise prompts | When building prompt-based features |
| `/exa-search` | Web search powered by Exa | Research during debugging or design |
| `/rules-distill` | Summarise and distill rules | When reviewing or simplifying rules |
| `/search-first` | Search-before-build pattern | Good practice for any implementation |
| `/verification-loop` | Iterative verification cycle | Extended verification beyond our standard check |
| `/project-guidelines-example` | Project guideline templates | Setting up new projects |
| `/nanoclaw-repl` | Interactive REPL environment | Quick experimentation |

---

## ECC Agent/Harness Tools (for toolbox developers only)

Only useful if you're developing new agents, skills, or harnesses for the ai-engineering repo itself.

| Skill | What it does |
|---|---|
| `/agent-eval` | Evaluate agent performance |
| `/agent-harness-construction` | Build test harnesses for agents |
| `/agentic-engineering` | Agentic design patterns reference |
| `/ai-first-engineering` | AI-first development methodology |
| `/ai-regression-testing` | Regression testing for AI agents |
| `/eval-harness` | Build evaluation harnesses |
| `/enterprise-agent-ops` | Enterprise agent operations patterns |
| `/skill-create` | Author new skills |
| `/skill-comply` | Compliance checking for skills |
| `/skill-health` | Check skill health |
| `/mcp-server-patterns` | MCP server development patterns |

---

## ECC Skills That Conflict with Ours (don't use these)

These do similar things to our commands but without the full orchestration. Our versions are better.

| ECC skill | Our equivalent | Why ours is better |
|---|---|---|
| `/debug` | `/bug` + `systematic-debugging` | Ours runs 4-phase root cause analysis with Seq logs and deep-reasoning-tier escalation |
| `/tdd-workflow` | `/flow` + `test-driven-development` | Ours enforces TDD as part of every workflow with anti-rationalisation rules |
| `/security-review` | `/security` | Ours runs full OWASP scan with `security-engineer` (deep-reasoning tier) + severity grading |
| `/security-scan` | `/security` | Same — our `/security` is more comprehensive |
| `/e2e-testing` | `/flow` (e2e-runner agent) | Ours runs E2E as part of the quality gate chain |
| `/documentation-lookup` | `docs-lookup` agent | Our agent uses Context7 MCP for live documentation |
| `/database-migrations` | `ef-migration-management` skill | Our skill is EF-specific and tailored to our stack |
| `/api-design` | `api-tester` agent | Our agent runs API testing as part of the review chain |
| `/architecture-decision-records` | `/flow` (architect agent) | Our architect (deep-reasoning tier) generates ADRs within the workflow |
| `/backend-patterns` | `/build` + `blazor-radzen` | Our patterns are stack-specific (C#/Blazor/Next.js) |
| `/frontend-patterns` | `/build` + `blazor-radzen` | Our patterns are stack-specific (Blazor/Radzen/React) |
| `/deployment-patterns` | `/hotfix` + `devops-automator` | Our deployment is handled by the devops-automator agent |

---

## ECC Language/Framework Patterns (not our stack — ignore)

These are patterns for languages and frameworks we don't use. They show in the `/` list but are irrelevant to our C#/Blazor/Next.js/NestJS stack.

**If you expand to a new stack in the future**, check this list — the skill you need might already be installed.

| Category | Skills | When to activate |
|---|---|---|
| **Django/Python** | `django-patterns`, `django-security`, `django-tdd`, `django-verification`, `python-patterns`, `python-testing`, `pytorch-patterns` | If you start a Python/Django project |
| **Laravel/PHP** | `laravel-patterns`, `laravel-security`, `laravel-tdd`, `laravel-verification` | If you start a PHP/Laravel project |
| **Go** | `golang-patterns`, `golang-testing` | If you start a Go project |
| **Kotlin/JVM** | `kotlin-patterns`, `kotlin-testing`, `kotlin-coroutines-flows`, `kotlin-exposed-patterns`, `kotlin-ktor-patterns`, `java-coding-standards`, `jpa-patterns`, `springboot-patterns`, `springboot-security`, `springboot-tdd`, `springboot-verification` | If you start a Kotlin/Java/Spring project |
| **Rust** | `rust-patterns`, `rust-testing` | If you start a Rust project |
| **Swift/iOS** | `swift-actor-persistence`, `swift-concurrency-6-2`, `swift-protocol-di-testing`, `swiftui-patterns` | If you start an iOS/Swift project |
| **C++** | `cpp-testing` | If you start a C++ project |
| **Perl** | `perl-patterns`, `perl-security`, `perl-testing` | If you start a Perl project |
| **Flutter/Dart** | `flutter-dart-code-review` | If you start a Flutter project |
| **Android** | `android-clean-architecture` | If you start an Android project |
| **Nuxt/Vue** | `nuxt4-patterns` | If you start a Nuxt/Vue project |
| **Next.js** | `nextjs-turbopack` | Already relevant — Turbopack-specific patterns for Next.js |
| **PostgreSQL** | `postgres-patterns` | If your project uses PostgreSQL |
| **Docker** | `docker-patterns` | If working with Dockerfiles and container config |

---

## ECC Industry/Domain Skills (not our domain — ignore)

These are skills for specific industries or business domains not relevant to toolbox's current work.

**If toolbox expands into a new domain**, check this list — the skill you need might already be installed.

| Skill | Domain | When to activate |
|---|---|---|
| `customs-trade-compliance` | Trade/customs | If building compliance software |
| `energy-procurement` | Energy | If building energy procurement tools |
| `investor-materials` | Finance/IR | If building investor relations tools |
| `investor-outreach` | Finance/IR | If building investor outreach tools |
| `inventory-demand-planning` | Supply chain | If building inventory management |
| `logistics-exception-management` | Logistics | If building logistics software |
| `production-scheduling` | Manufacturing | If building production scheduling |
| `quality-nonconformance` | Manufacturing QA | If building quality management |
| `returns-reverse-logistics` | Supply chain | If building returns management |
| `visa-doc-translate` | Immigration | If building visa/document tools |
| `market-research` | Research | If building market research tools |
| `ralphinho-rfc-pipeline` | RFC process | If building RFC automation |
| `nutrient-document-processing` | Document processing | If using Nutrient SDK |

---

## ECC Miscellaneous Skills (niche — ignore unless needed)

| Skill | What it does |
|---|---|
| `article-writing` | Article/content generation |
| `crosspost` | Cross-posting content to platforms |
| `video-editing` | Video editing workflows |
| `videodb` | Video database operations |
| `fal-ai-media` | AI media generation |
| `data-scraper-agent` | Web data scraping |
| `regex-vs-llm-structured-text` | Text extraction comparison |
| `x-api` | X/Twitter API integration |
| `frontend-slides` | Slide/presentation generation |
| `liquid-glass-design` | Apple design language patterns |
| `foundation-models-on-device` | On-device ML patterns |
| `santa-method` | Structured analysis methodology |
| `team-builder` | Team/agent composition |
| `remote-control` | Remote agent control |
| `autonomous-loops` | Extended autonomous operation |
| `batch` | Batch operations |
| `iterative-retrieval` | Multi-pass retrieval |
| `evolve` | Self-improvement patterns |
| `dmux-workflows` | Multiplexed workflows |
| `instinct-export` | Export learned patterns |
| `instinct-import` | Import learned patterns |
| `instinct-status` | Check learned pattern status |
| `plankton-code-quality` | Code quality checks |
