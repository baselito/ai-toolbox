---
name: coding-style
source: ECC (common/ + typescript/)
scope: always active
---

# Coding Style Rules

Consistent naming, formatting, and structure rules that apply to all code changes.

## General

- Follow existing project conventions — detect and match the codebase style
- Use meaningful, descriptive names for variables, functions, and classes
- Prefer immutability — use `const` over `let`, `readonly` where applicable
- Keep functions small and focused — single responsibility
- Avoid deep nesting — extract early returns and guard clauses
- No magic numbers or strings — use named constants
- Remove dead code — do not comment it out. **Scope the removal to your own change:** delete code your edit made unused (e.g. a now-orphaned import or helper). Pre-existing dead code unrelated to your change — flag it or file a follow-up, but do not delete it in the same change. Silent unrelated deletions break the surgical-scope discipline in `workflow-discipline.md` (the "/flow invented scope" incident class).
- **Add comments explaining WHY, not just WHAT** — every file, class, region, and non-obvious line should have a comment explaining its purpose. Write for a beginner developer or tester who hasn't seen the code before. Examples:
  - File/class level: "// Tests that verify severity enum converts correctly to/from API strings and display labels"
  - Region/section level: "// These tests catch bugs where the API would receive wrong severity values"
  - Non-obvious logic: "// Falls back to ToString() instead of throwing — this is intentional behaviour, see ticket DEV-5670"

## TypeScript / JavaScript

- Use TypeScript strict mode
- Prefer interfaces over type aliases for object shapes
- Use explicit return types on public functions
- Prefer `async/await` over raw promises
- Use optional chaining and nullish coalescing
- Avoid `any` — use `unknown` if the type is truly unknown

## C# / Blazor

- Follow .NET naming conventions (PascalCase for public, camelCase for private)
- Use nullable reference types
- Prefer records for immutable data
- Use pattern matching where it improves readability
- Dispose resources properly — use `using` statements

## Applies To

Every agent writing or reviewing code. The agent detects the stack from PROJECT.md and applies the relevant conventions.
