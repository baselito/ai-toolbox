# Incident Response

How to handle production incidents using the `/incident` command — from first alert to post-mortem.

---

## When to Read This

- Production is down or degraded right now
- You want to understand the incident workflow before an incident happens
- You need to review or improve the post-mortem process

---

## The /incident Workflow

Run `/incident` when production is down or a P1 issue is reported. The workflow follows a strict restore-first approach:

1. **Seq log query** — the agent queries Seq immediately for recent errors, exceptions, and anomalies
2. **Triage** — the `incident-response-commander` agent classifies severity (P1-P4) and identifies affected systems
3. **Restore service** — the agent focuses on restoring service first, not root cause. This may mean a rollback, config change, or feature flag toggle
4. **Root cause analysis** — once service is restored, the agent investigates what went wrong
5. **Fix** — the agent implements a proper fix with tests
6. **Post-mortem** — the agent files a structured post-mortem automatically

---

## Restore First, Investigate Later

This is the core principle. The agent does not spend time debugging while production is down. The priority order is:

1. Restore service (rollback, disable feature, scale up)
2. Confirm service is healthy
3. Then investigate root cause
4. Then implement a proper fix

---

## The incident-response-commander Agent

This agent (Opus) runs the full incident protocol:

- **Triage** — reads Seq logs, identifies error patterns, classifies severity
- **Coordination** — works with `devops-automator` for deployment rollbacks
- **Timeline** — maintains a timestamped incident timeline throughout
- **Post-mortem** — generates a structured report with timeline, root cause, fix, and prevention steps

The agent hands off to `devops-automator` (Opus) when a deployment action is needed (rollback, fast-track deploy).

---

## Seq Log Queries

Use a configured, user-managed Seq MCP server only after checking its tools and redaction policy. Otherwise inspect local logs or sanitized exports.

**Query sequence during an incident:**

1. `seq_get_levels_summary` (fromMinutes: 30) — quick health check: how many Warning/Error/Fatal in the last 30 minutes
2. `seq_group_errors` (fromMinutes: 60) — triage: errors ranked by priority (level × environment × count)
3. `seq_get_error_events` (eventType: top error's @i hex ID) — drill-down: error occurrences with surrounding context timeline
4. `seq_query_events` with filter — cross-service correlation, specific endpoint investigation

Use a configured, user-managed Seq MCP server only after checking its tools and redaction policy. Otherwise inspect local logs or sanitized exports.

---

## Post-Mortem

After the incident is resolved, the agent automatically generates a post-mortem containing:

- **Timeline** — timestamped events from detection to resolution
- **Root cause** — what failed and why
- **Fix applied** — what was done to restore service and the permanent fix
- **Prevention** — what changes prevent recurrence
- **Beads record** — the full incident is tracked in Beads for future reference

---

## Severity Classification

| Severity | Meaning | Response |
|---|---|---|
| P1 | Production down, all users affected | Immediate — restore within minutes |
| P2 | Major feature broken, many users affected | Urgent — restore within the hour |
| P3 | Minor feature broken, some users affected | Same day |
| P4 | Cosmetic or low-impact issue | Normal priority |

---

## Related Docs

- [Commands Reference](commands.md) — `/incident` and `/hotfix`
- [Agent List](../reference/agent-list.md) — `incident-response-commander` and `devops-automator`
- [Beads — AI Task Tracking](../concepts/beads.md) — post-mortem storage
- [MCP Connections](../concepts/mcp.md) — Seq setup
