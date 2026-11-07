---
name: event-driven-messaging
type: passive
source: this repo
description: Reliable messaging guidance based on the target broker, transport, and messaging library.
used_in: /flow, /build, /refactor, /bug
---

# Event-Driven Messaging Patterns

## Discover Transport and Contracts

Identify the configured broker, library version, endpoint naming, serializer, retries, and dead-letter handling. Inspect existing registration code and packages. For MassTransit projects, follow installed `IConsumer<T>`, `IPublishEndpoint`, and `ConsumeContext<T>` usage; do not assume private abstractions exist.

Distinguish in-process mediation from durable broker delivery. Record required endpoints, authentication, secret sources, and provisioning using configurable values. Test with local or disposable infrastructure.

## Publishing Reliably

Database persistence and broker publication have separate failure points. Saving first and publishing afterward can lose an event if the process fails between them; publishing first can advertise a transaction that later fails.

When both effects require reliability, use the project's supported transactional outbox or an explicitly designed recovery mechanism. Verify transaction and dispatch behavior against the installed library. Do not claim atomicity from statement ordering alone.

## Consumers

- Expect duplicate delivery. Use durable deduplication or idempotent transitions, coordinated with business writes in the appropriate transaction. A pre-insert existence check alone does not prevent concurrent duplicates.
- Propagate cancellation and distinguish transient failures from invalid messages.
- Bound retries and expose failure or dead-letter handling. Do not silently acknowledge unprocessed work.
- Account for out-of-order events and concurrent consumers when maintaining read models.

## Contract Evolution

Events describe facts; commands request actions. Follow established naming and compatibility conventions and preserve fields consumers require. Avoid unnecessary sensitive data in messages and logs.

For legacy synchronization, determine source ownership and consumers before changing behavior. Do not assume a retirement timeline or remove subscribers without evidence from the actual migration plan.

## Verification

Use the configured test harness or disposable broker environment. Test successful delivery, duplicates, transient errors, retries, invalid messages, and recovery across the persistence/publication boundary. Verify affected producers and consumers together when contracts change.
