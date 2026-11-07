---
name: monolith-decomposition
type: passive
source: this repo
description: Evidence-based maintenance and incremental extraction guidance for monoliths and shared service boundaries.
used_in: /flow, /build, /refactor
---

# Monolith Maintenance and Decomposition

## Map the System

Inspect solution and deployment configuration, dependency references, routes, jobs, persistence, authentication, and integrations. Identify responsibilities, independently deployed components, shared libraries, database readers and writers, synchronization flows, and existing modernization decisions.

Mark unknown dependencies explicitly. A separate project or repository does not imply independent ownership or deployment. Do not assume fixed framework versions, service counts, or a replacement roadmap.

## Maintenance

Keep bug fixes focused and preserve behavior outside scope. Establish regression coverage around the affected boundary. Evaluate performance changes with measurements: indexes and eager loading introduce costs as well as benefits.

Follow actual framework support and dependency policies. Do not freeze upgrades or mandate replacement based on a generic architectural preference.

## Extraction Planning

Extract only within the requested scope and when benefits justify operational complexity. Define the domain boundary, API or event contract, data ownership, deployment, observability, and recovery plan before moving code.

Prefer incremental rollout with a clear routing switch and comparison of old/new behavior. Avoid uncoordinated dual writes; use explicit reconciliation or reliable propagation when multiple systems temporarily hold data.

## Shared Database Changes

Find consumers before changing shared tables or persistence libraries. Use compatible expansion, backfill, application rollout, and contraction as appropriate. Review additive changes too: defaults, required columns, indexes, and triggers affect existing clients and availability.

Identify one migration owner. Validate event and read-model contracts when synchronized data changes. Do not declare independence while a service depends on monolith schema or runtime internals.

## Verification

Run affected module, integration, contract, and representative end-to-end tests. For extraction, verify deployment order, authorization, failure behavior, observability, and recovery. Document dependencies or operational steps that cannot be verified locally.
