# Add opt-in Azure DevOps adapters

## Context

Issue #2138 adds Azure Boards and Azure Repos support alongside GitHub.
The existing tracker library separates issue providers from review providers.
The user approved Azure CLI with its Azure DevOps extension on 2026-11-22.

## Options Considered

| Option | Benefit | Cost |
|--------|---------|------|
| Azure CLI extension | Reuses Microsoft authentication and existing shell adapters. | Requires Azure CLI and the extension. |
| Direct REST client | Controls every API request. | Adds credential and HTTP handling. |
| Custom templates | Requires fewer framework changes. | Repeats integration work for each adopter. |

## Decision

Add the opt-in `az` provider through the existing issue and review interfaces.
Keep `gh` as the default provider.
Use explicit organization, project, and repository settings for every Azure operation.
Resolve project overrides before global settings, as existing adapters do.
Never infer Azure context from the current working directory or CLI defaults.

Use Azure CLI authentication without storing credentials in project configuration.
Pass values as separate arguments. Never evaluate provider responses or ticket bodies.
Validate response identity and required fields before returning normalized data.
Use `AB-<number>` for work-item references and existing project aliases for registry lookup.

Governed merge support requires Azure-aware resolution of PR identity, head, changed paths, and CI evidence.
Until all merge gates have that evidence, Azure merges must fail closed.
Do not translate unavailable evidence into success or silently dispatch Azure operations to GitHub.
Do not use policy bypass, automatic completion, or administrator flags.

## Consequences

GitHub projects retain their existing commands and defaults.
Mixed-provider projects can select `issue_kind` and `review_kind` separately.
Azure adopters install the Azure DevOps extension and configure their project context explicitly.
Mocked CLI tests verify contracts without Azure credentials.
Live Azure tenant validation remains a separately reported verification limit.
Azure Pipelines generation and Azure DevOps Server remain outside this change.

## Artifacts

- [Feature issue #2138](https://github.com/me2resh/apexyard/issues/2138).
- [Technical design](../design/azure-devops.md).
