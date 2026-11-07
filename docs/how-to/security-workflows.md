# Security Workflows

How to run security scans, understand severity classification, and use the security agents.

---

## When to Read This

- You want to run a dedicated security scan on your project
- You need to understand the OWASP Top 10 scanning process
- You want to know when the security agents activate automatically
- You need to fix a CRITICAL vulnerability

---

## The /security Command

Run `/security` for a dedicated OWASP Top 10 scan of your codebase. The workflow:

1. **Scan** — the `security-engineer` agent (deep-reasoning tier — see `rules/performance.md`) analyses the codebase for vulnerabilities
2. **Report** — a severity-classified report is generated
3. **Auto-fix CRITICALs** — CRITICAL vulnerabilities are fixed immediately with tests
4. **Review** — the `security-reviewer` agent (Opus) validates the fixes
5. **PR** — fixes are submitted as a PR

---

## Two Security Agents

The toolbox uses two security agents that work sequentially — the engineer designs, the reviewer validates.

### security-engineer (deep-reasoning tier)

Handles security architecture and deep analysis:

- Threat modelling — identifies attack surfaces and vectors
- IAM and zero-trust architecture review
- OAuth/RBAC configuration analysis
- OWASP Top 10 compliance assessment
- Secrets exposure detection

Runs on the deep-reasoning tier (Opus — see `rules/performance.md`) for deep reasoning on complex security decisions.

### security-reviewer (Opus)

Handles code-level vulnerability scanning:

- Injection risks (SQL, XSS, command injection)
- Authentication and session management flaws
- Permission and access control issues
- Dependency vulnerability checks
- Secrets in code or configuration

Runs on Opus — review's failure mode is the subtle miss.

**Execution order:** `security-engineer` always runs before `security-reviewer`. The engineer identifies architectural risks, then the reviewer scans the code for specific vulnerabilities.

---

## Severity Classification

| Severity | Meaning | Action |
|---|---|---|
| CRITICAL | Exploitable now, data at risk | Auto-fixed immediately by the agent |
| HIGH | Serious vulnerability, exploitation likely | Flagged for immediate manual review |
| MEDIUM | Vulnerability exists, exploitation requires effort | Included in report, fix recommended |
| LOW | Minor issue, minimal risk | Noted in report |
| INFO | Best practice suggestion | Noted in report |

---

## When Security Agents Activate Automatically

Outside of `/security`, the security agents activate conditionally during other commands:

| Files changed | Agents activated |
|---|---|
| `appsettings*`, `*auth*`, secrets | `security-engineer` (deep-reasoning tier) + `security-reviewer` (Opus) |
| `*Controller*`, `*Endpoint*` | `security-reviewer` (Opus) |
| Any `/hotfix` | `security-reviewer` (Opus) |

This means security review happens automatically when you touch security-sensitive files — no need to run `/security` separately.

---

## Security Sensitivity Levels

Configured during `/init`, the security level affects how aggressively the agent scans:

| Level | Scanning | Used for |
|---|---|---|
| Internal | Standard OWASP scan | Internal tools, admin panels |
| Customer-facing | Enhanced scanning + auth review | Public-facing applications |
| Financial | Full threat model + compliance checks | Payment, banking, PII handling |

---

## Related Docs

- [Commands Reference](commands.md) — `/security`, `/review`
- [Agent List](../reference/agent-list.md) — `security-engineer` and `security-reviewer`
- [Model Assignments](../reference/model-assignments.md) — why security-engineer uses the deep-reasoning tier
- [Agents Concept](../concepts/agents.md) — conditional activation rules
