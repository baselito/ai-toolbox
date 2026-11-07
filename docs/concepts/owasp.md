# OWASP — Security Standards

The OWASP Top 10, how the security agents use it, and when security scanning happens.

---

## When to Read This

- You want to understand security scanning in this toolbox
- You want to know the difference between security-engineer and security-reviewer
- You are preparing for a security audit or compliance review

---

## What Is OWASP?

OWASP (Open Worldwide Application Security Project) maintains the OWASP Top 10 — a standard list of the most critical web application security risks. This toolbox uses it as the baseline for all security checks.

---

## OWASP Top 10

1. **Injection** — SQL, NoSQL, OS, LDAP injection
2. **Broken Authentication** — session management, credential handling
3. **Sensitive Data Exposure** — data at rest and in transit
4. **XML External Entities (XXE)** — XML parser vulnerabilities
5. **Broken Access Control** — unauthorised access to resources
6. **Security Misconfiguration** — default configs, open cloud storage
7. **Cross-Site Scripting (XSS)** — reflected, stored, DOM-based
8. **Insecure Deserialization** — untrusted data deserialisation
9. **Using Components with Known Vulnerabilities** — outdated dependencies
10. **Insufficient Logging and Monitoring** — missing audit trails

---

## Two Security Agents

This toolbox has two complementary security agents:

### security-engineer (deep-reasoning tier)

**Architecture-level security.** Designs security patterns:
- IAM and access control architecture
- Zero-trust design
- OAuth/RBAC implementation review
- Threat modelling
- Secrets management strategy

Runs during: `/security`, `/flow` (when security-sensitive files are changed), `/hotfix`

### security-reviewer (Opus)

**Code-level security scanning.** Finds vulnerabilities:
- Hardcoded secrets or API keys
- Injection risks in code
- Permission issues
- Insecure patterns
- Dependency vulnerabilities

Runs during: `/review`, `/security`, `/flow` (when API/auth files are changed)

**Execution order:** When both run, security-engineer goes first (designs architecture), then security-reviewer scans code (checks implementation). Sequential, not parallel.

---

## When Security Scanning Happens

| Project security level | What happens |
|---|---|
| Internal tool | Standard security check at end of each feature |
| Customer-facing | Security scan after every feature, OWASP on all API endpoints |
| Financial or sensitive data | Security Engineer runs on every task, no task done without security sign-off |

---

## The /security Command

`/security` runs a dedicated full OWASP scan:

1. Security Engineer (deep-reasoning tier — see `rules/performance.md`) — full OWASP Top 10 compliance check + architecture review
2. Security Reviewer (Opus) — code-level vulnerability scan
3. Severity-graded report (CRITICAL / HIGH / MEDIUM / LOW)
4. Automatic fix of CRITICAL issues (with user approval)
5. PR created only if fixes are made

---

## Security Rules

The `security.md` rule (from ECC) is always active in every session:
- Never log sensitive data
- Always validate input
- OWASP compliance required
- No hardcoded secrets
