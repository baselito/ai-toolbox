---
name: ef-migration-management
type: passive
source: this repo
description: Migration guidance based on the target context, provider, schema ownership, and deployment process.
used_in: /flow, /build, /refactor, /bug
---

# EF Core Migration Management

## Adding a Migration

1. Identify the actual project, startup project, context, EF version, provider, schema owner, and deployment process.
2. Make the model change using local mapping conventions.
3. Generate a migration with the established project command, specifying the verified project, startup project, and context as needed.
4. Review migration and snapshot for unrelated changes, data loss, constraints, defaults, index costs, and provider-specific behavior.
5. Test on a disposable database with representative data. Verify the connection before applying changes; do not run database updates against an unknown environment.
6. Correct deployed migrations through new migrations rather than rewriting shared history.

## Shared Schema and Rollout

Identify every application, job, and integration reading or writing affected tables. Choose one schema migration owner. Use staged compatible changes when application versions overlap.

Additive changes also need review: required columns without backfills, costly indexes, and table rewrites can break deployments. Plan data backfills, locking, rollout order, and recovery before altering constraints or removing fields.

## Long Migration Chains

Migration count alone does not justify squashing. Measure the tooling or deployment problem first. Baselining is a separate, explicitly requested operation requiring backups, an environment inventory, provider-specific history handling, and review. Do not delete migrations or fabricate migration history rows during routine maintenance.

Follow the installed EF version and provider guidance. Verify creation of a fresh database and upgrade of a restored existing database, including data preservation and rollback or forward recovery.

## Verification

Inspect generated deployment SQL where used. Check implicit conversions, nullable-to-required changes, referential actions, and locking on realistic data. Run persistence tests. Record the starting schema, provider, tested migration range, and required rollout steps.
