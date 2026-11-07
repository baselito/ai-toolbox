# Security Rules

These rules apply to all code changes. No exceptions.

## Requirements

- Never log sensitive data (passwords, tokens, API keys, PII)
- Always validate input at system boundaries (user input, API requests, external data)
- OWASP compliance is required for all code changes
- No hardcoded secrets or API keys in source code — use environment variables or secret managers
- Use parameterised queries — never concatenate user input into SQL
- Sanitise all output to prevent XSS
- Use HTTPS for all external communications
- Apply principle of least privilege to all access control
- Encrypt sensitive data at rest and in transit
- Never expose stack traces or internal error details to end users
- Session tokens must have appropriate expiry
- Rate limiting must be applied to authentication endpoints

## Architecture-Level Security

When reviewing or designing security-sensitive code:

- Review IAM and access control patterns
- Evaluate zero-trust architecture compliance
- Review OAuth/RBAC implementation at the design level
- Conduct threat modelling for new features and architecture changes
- Review secrets management strategy
- Assess security implications of configuration changes

## OWASP Top 10 Compliance

Check all code changes against:

1. Injection (SQL, NoSQL, OS, LDAP)
2. Broken authentication
3. Sensitive data exposure
4. XML external entities (XXE)
5. Broken access control
6. Security misconfiguration
7. Cross-site scripting (XSS)
8. Insecure deserialization
9. Using components with known vulnerabilities
10. Insufficient logging and monitoring

## Severity Grading

Grade all findings:

| Severity | Meaning |
|---|---|
| CRITICAL | Must fix immediately — blocks PR |
| HIGH | Fix before next release |
| MEDIUM | Should fix |
| LOW | Advisory |

## Guards Fail Closed, Or They Are Not Guards

**A guard spec that does not state its fail direction has stated "open".** That
is the default nobody chooses and everybody inherits: the input classes the spec
forgot are the ones the implementation permits. Five separate guards in this
toolbox shipped that way and were found in one sweep (issues #146, #150, #153, #156,
and #158), so this is the generalisation, not a hypothetical.

When writing, reviewing, or specifying ANY guard — a hook, a validator, a
schema check, an auth decision, a CI gate:

1. **Measure the fact you act on, not a shape that correlates with it.** The
   compliance-audit hook required a line starting `AUDIT COMPLETE:` and never
   read what followed, so an audit that said `BLOCKED` opened the PR. Checking
   that a report EXISTS is not checking what it SAYS.
2. **Enumerate every input class, including "unrecognised" and "unreadable",
   and give each one a direction.** Unknown input is not consent. A gate that
   cannot establish it was satisfied has NOT been satisfied.
3. **Bind evidence to the thing it certifies.** A review, an audit, a signature
   or a scan result is about one revision. Key it to that revision (a commit
   sha, a content hash, a version) or it silently certifies everything after it
   too.
4. **A guard must not block its own remedy.** If the deny message says "run X"
   and the guard refuses X, it is not a guard, it is a deadlock. Check the exact
   string the guard PRINTS against the rule it enforces — the auto-poll hook
   printed a path spelled one way and accepted only the other spelling.
5. **The deny message is part of the guard.** It must name a way out that works,
   and must close off the obvious wrong retry. A correct block that sends the
   reader into a loop costs the same time as a failure to block.
6. **Every conditional gets a test that goes RED when the conditional is
   neutered.** Not "the suite passes" — flip the guard off in a scratch copy and
   watch a named test fail. A branch no test can distinguish from its neighbour
   is a branch nobody will notice rotting, and redundant guards are worse than
   one guard: they look like defence in depth and are unverifiable.
7. **Prefer over-blocking to under-blocking, and write the residual down.** An
   over-block costs one re-worded command; an under-block is the thing the guard
   existed to stop. Where a gap is accepted, NAME it in the source — an
   unnamed residual reads as a guarantee.

**When reviewing a guard, the question is not "does it block the bad case?" but
"what does it do with the case nobody listed?"** Grade an unstated fail-open
direction as a real finding, at the severity of whatever the guard protects.

## What Happens on Violation

If a security violation is detected in code being written or reviewed:

1. Flag it immediately
2. Do not proceed until it is fixed — or until the user explicitly overrides after a strong warning (see the `edge-cases` skill for the override protocol: CRITICAL requires strong warning + user confirmation, HIGH/MEDIUM/LOW the user can decline and the agent documents the decision)
3. Document the finding with severity grade
