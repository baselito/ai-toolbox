---
name: cross-tool-sync
source: Custom
scope: always active when editing the toolbox
---

# Toolbox synchronization

The toolbox supports Claude Code and Codex. Keep their shared workflow contract
aligned without duplicating provider-specific host features.

Before committing a toolbox change:

1. Update the runtime, installer, command, rule, skill, and documentation
   surfaces that describe the changed behavior.
2. Keep counts and file lists in `README.md`, `CLAUDE.md`, and the reference
   docs consistent with the repository.
3. Search for dead links and stale provider-specific wording.
4. Preserve native Claude features where they exist, and document the bounded
   Codex equivalent instead of pretending the hosts are identical.
5. Run the retired editor-assistant integration check and `scripts/verify.sh` before claiming the
   toolbox is ready.

The goal is one maintainable workflow contract with small provider adapters,
not parallel copies of every instruction file.
