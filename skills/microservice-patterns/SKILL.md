---
name: microservice-patterns
type: passive
source: this repo
description: Project-driven patterns for .NET service endpoints, handlers, configuration, and persistence.
used_in: /flow, /build, /refactor, /bug
---

# Microservice Patterns

## Discover the Project

Inspect solution files, package references and versions, startup code, and one comparable endpoint from authorization through persistence to response mapping. Identify test commands and configuration sources. Document missing private dependency access; do not invent substitute APIs.

A custom factory, mediator, result union, or vertical slice layout is a project choice, not a toolbox prerequisite. Follow existing conventions rather than introducing a competing framework.

## Implement a Feature

- Place endpoints and supporting types alongside comparable features.
- Register dependencies using the project's actual mechanism and appropriate lifetimes.
- Propagate cancellation tokens through asynchronous I/O.
- Follow validation and error-response conventions; distinguish expected business outcomes from unexpected failures.
- Preserve public response codes, serialization, and compatibility.
- Enforce configured authentication and authorization on the server, including resource and tenant boundaries. Do not replace unavailable permission checks with unrestricted access.
- Follow existing entity mapping conventions and review generated migrations and shared-schema consumers.
- If a database write must emit a durable message, use the project's verified outbox or equivalent recovery mechanism; saving then publishing is not atomic.

## Verification

Run the project's build and relevant tests. Cover success, invalid input, unauthorized access, missing resources, and relevant cancellation or persistence failures. Use `event-driven-messaging` for message changes and `ef-migration-management` for schema changes.
