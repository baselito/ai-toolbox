---
name: blazor-radzen
type: passive
source: this repo
description: Blazor guidance based on the target hosting model and Radzen components when already configured.
used_in: /flow, /build, /refactor, /bug
---

# Blazor and Radzen Patterns

## Discover the Application

Inspect project references and startup code for the .NET version, hosting model, render modes, routing, and authentication. Locate shared libraries, feature components, API clients, and tests; do not assume a particular topology or folder structure.

Check whether `Radzen.Blazor` is installed and which version is used. Reuse shared wrappers and styling conventions before adding direct component use.

## Components and Forms

- Follow local conventions for feature modules, code-behind, and `@code` blocks.
- Use Radzen where it fits the established UI and accessibility requirements; semantic HTML remains appropriate where needed.
- Use the existing validation integration rather than assuming a particular library exists.
- Include labels, keyboard interaction, focus management, loading, empty, and error states. Prevent unintended duplicate submissions.
- Verify component properties, event signatures, and test APIs against installed versions and existing examples.

## API Access and Authentication

Reuse configured API clients and dependency injection. Do not duplicate token, retry, and error handling in components. Identify the actual identity provider rather than assuming a cloud tenant.

Enforce permissions on the API: client-side visibility and route protection are not server authorization. Keep secrets out of browser-delivered code. Document required API base URL, authority, client ID, and redirect settings as configurable values.

## Verification

Build affected client and host projects. Use the installed component test framework, such as bUnit, and established browser tests, such as Playwright. Exercise validation, failed requests, unauthorized responses, and responsive keyboard-accessible behavior as relevant.
