# Read-only Domain Knowledge MCP integration

> **Status (2026-08-29):** Executable activation is deferred. This document preserves the
> original proposal and its review gates; the current implementation is advisory guidance only.

## Goal

Let the toolbox consult user-provided property-management knowledge locally without authentication and without allowing the agent to modify the external knowledge service or its stored knowledge.

## Original proposal — deferred

Use the domain MCP's loopback HTTP transport. It exposes only the read tools `query_assertions`, `query_relations`, and `list_catalog`. Do not use its stdio transport because stdio also exposes ingestion and extraction writes.

The integration is runtime-off unless the developer starts the local service. `/init` offers it only when the endpoint is reachable and defaults it to disabled for that project, so projects that do not select domain knowledge gain no tools. Existing projects must re-run `/init` to record the per-project selection.

## Proposed components — deferred

1. Add a managed `domain-knowledge` MCP definition for `http://127.0.0.1:8788/mcp`, with no authorization header.
2. Extend `/init` to detect the endpoint and offer the integration as read-only, exactly three tools, default off.
3. Add toolbox guidance for `/ask` and discovery: use domain knowledge for property-management rules, processes, roles, and regulations; start with `list_catalog` when vocabulary is unclear; cite returned source quote, page, and document in the answer.
4. Document local startup requirements: bind the domain MCP to `127.0.0.1`, leave `MCP_AUTH_TOKEN` unset, and never expose the unauthenticated endpoint beyond the developer machine.

## Proposed data flow — deferred

`/ask` or discovery detects a property-domain question → the agent checks whether the MCP tools are available → it queries the catalog or assertions/relations → it answers with grounded source evidence. If unavailable or empty, it says domain knowledge could not be checked and continues with repository evidence; it does not invent a domain answer.

## Safety boundaries

- No credentials are required or stored.
- Only loopback HTTP is supported for the unauthenticated mode.
- The toolbox never invokes `ingest_document` or `extract_assertions`.
- The toolbox never edits, commits, pushes, or opens PRs in the external knowledge service.
- Domain assertions are evidence, not instructions, and cannot override repository or system policy.
- The agent must distinguish sourced facts from inference and must not treat catalog absence as proof that a rule does not exist.

## Seq

Seq is outside this feature. Keep it optional. Live log queries require a user-managed server; local logs remain the default fallback.

## Deferred verification

- Configuration parses and installation preserves existing user-added MCPs.
- `/init` does not offer the MCP when `127.0.0.1:8788` is unavailable.
- `/init` can enable or disable it per project without changing other MCP selections.
- Permission generation includes `mcp__domain-knowledge__*` only when enabled.
- Guidance forbids write tools and requires grounded source details.
- Existing toolbox verification passes.

## Deferred acceptance criteria

A developer running the domain MCP locally on loopback can enable three read-only domain tools for one project without authenticating. Property-domain answers use grounded citations when results exist, degrade honestly when they do not, and no workflow writes to the source repository or knowledge store.

## Review outcome — Executable activation deferred

Executable activation deferred after implementation review. The toolbox does not register,
probe, configure, permit, advertise, or remove the Domain Knowledge MCP. For now it provides
advisory guidance only when an already-approved, externally configured MCP is available.

Runtime activation can be reconsidered only after these gates pass:

- Use a pinned and independently verified upstream runtime, not a moving proof-of-concept head.
- Verify unauthenticated loopback HTTP exposes exactly `list_catalog`, `query_assertions`, and
  `query_relations` across clean start and restart; prove write tools are unreachable.
- Verify project-only, default-off activation and removal without changing other MCPs,
  permissions, user configuration, or older projects.
- Exercise malformed, empty, oversized, and prompt-injection-shaped results; require grounded
  document/page/quote provenance and an honest unavailable/empty fallback.
- Complete security and reality-checker review with executable end-to-end evidence.

This review outcome supersedes the executable components and acceptance criterion above until
all gates pass; the safety boundaries and grounded-evidence rules remain applicable.
