# Technical Design: Azure DevOps adapters

**Status**: Approved for implementation
**Author**: Codex, acting as Tech Lead
**Date**: 2026-11-22
**Requirements**: [Issue #2138](https://github.com/me2resh/apexyard/issues/2138)
**Decision**: [AgDR-0323](../agdr/AgDR-0323-azure-devops-adapters.md)

## Overview

Add opt-in Azure Boards and Azure Repos adapters without changing GitHub defaults.
Use Azure CLI with the Azure DevOps extension, as the user approved.
Preserve the existing ticket, review, and merge controls.
Obtain independent architecture review before implementation.

## Architecture

The tracker library dispatches `az` issue and review operations to a sibling Azure helper.
Load that helper only for Azure operations so existing minimal test fixtures still work.
Keep existing normalized tracker contracts.

Resolve `azure_organization`, `azure_project`, and `azure_repository` from the project's tracker block before global tracker settings.
The registry's existing `repo` alias identifies the project. It need not encode the Azure URL.
Require an HTTPS organization URL under `dev.azure.com` with a single organization segment.
Reject missing context, control characters, and invalid IDs before invoking the CLI.
Disable CLI context detection explicitly wherever the command supports it.
Authenticate through Azure CLI or its supported environment variable. Never read or print credentials.

### Work items

Accept numeric IDs and `AB-<number>` references.
Normalize title, description, tags, state, and browser URL from Azure work-item fields.
Verify the returned ID and project against the requested context.
Create work items with an explicit configured type, defaulting to `Task`.
Pass descriptions and tags as literal arguments.
Never retry uncertain creation automatically.

List work items with a project-scoped WIQL query.
Escape WIQL string literals separately from shell arguments.
Reject unsupported filters rather than returning an incorrectly filtered result.
Normalize the server result and preserve the existing completeness reporting contract.
Treat tags as labels. Azure does not require a separate label-creation operation.

### Pull requests

Resolve PR data through explicit organization context and verify its project and repository identity.
Normalize head SHA and source and target branch names from Azure PR fields.
Review comments use Azure PR threads with commit context.
Votes map to approve, reject, and comment without policy bypass.
Commit-specific evidence must come from server-returned thread context, never a body-only SHA claim.
If Azure cannot prove the required evidence, return an error and keep the gate closed.

Read PR iterations through `az devops invoke --area git --resource pullRequestIterations`.
Create review threads through `pullRequestThreads` with an iteration context whose second comparing iteration identifies the reviewed source commit.
Read threads and join each thread's second comparing iteration to the server iteration's `sourceRefCommit.commitId`.
Require a nondeleted text comment, a positive thread ID, valid iteration context, and an exact SHA match.
Reject deleted threads, missing iterations, vote-only results, malformed JSON, and body-only SHA claims.
Return verification error code `2` for unavailable Azure evidence, never unsupported code `3`.
Return code `1` only after a complete successful read finds no matching review.

Extend merge command detection and hook wiring for Azure CLI completion and the tracker wrapper.
Resolve changed paths and CI or policy status through Azure APIs before allowing governed completion.
Pending, failed, malformed, or incomplete results block completion.
Recheck the source commit before completion and supply the expected source commit where the API supports it.
Preserve review-marker comparisons and human approval requirements.
Do not claim complete governed merge support while any gate still calls GitHub for an Azure PR.

### Completion boundary

Support completion only through `tracker_pr_merge <alias> <id> ...`.
A raw-command guard rejects Azure PR update commands and mutating Azure CLI REST invocations.
It also rejects raw PR creation with automatic completion or completion options, including `az repos pr create --auto-complete true`.
Reject every raw Azure PR create or update command, including abbreviated subcommands, rather than attempting to prove completion options absent.
This restriction includes automatic completion, policy bypass, body-file payloads, and ambiguous mutation methods.
Read-only Azure commands such as `az repos pr show` remain available.
Raw `az devops invoke` is restricted to adapter internals, including GET requests, so mixed method options cannot hide a mutation.
The framework does not claim that command-text hooks can sandbox arbitrary executable code or hidden shell aliases.
Document the normal wrapper as the sole supported agent completion route.

| Control | Azure implementation |
|---------|----------------------|
| Identity | Validate PR ID, repository ID or name, and project ID or name against explicit configuration. |
| Head and base | Extend `_lib-extract-pr.sh` with Azure reads. The trusted dispatcher never publishes GitHub metadata snapshots for Azure. |
| Marker checks | Preserve `block-unreviewed-merge.sh` comparisons against the Azure source SHA. |
| Posted review | Join thread iteration context to source SHA in `tracker_review_at_sha`. |
| UI and architecture paths | Query the latest iteration changes, including original rename paths, and reject incomplete results. |
| CI | Read policy evaluations and PR statuses. Failed, queued, running, absent, malformed, or incomplete required evidence blocks. |
| Freshness | Query commit differences for target branch and source SHA. Unknown or positive behind count blocks. |
| Completion | Submit a PATCH through Azure CLI invocation with `lastMergeSourceCommit.commitId` equal to the checked head. |

The completion payload sets policy bypass to false and supplies explicit completion options.
It does not enable auto-completion. Do not implement an approval-state shortcut.
Invoke all four existing merge-gate scripts with the literal wrapper payload before the completion request.
Re-read the source SHA after those gates. Abort if it differs from the initial checked SHA.
The expected source commit in the completion request protects against a source update after that recheck.
Validate completed status and a merge commit before reporting success.
An uncertain completion response is an error, never a signal to retry the write.

Limit each Azure CLI call to 30 seconds through the existing timeout infrastructure or an equivalent process timeout.
Bound changed-path reads at 3,000 entries. Reject a continuation or a larger set instead of accepting a partial list.
Use `$compareTo=0` for changes against the common source and target commit.
Treat positive `nextSkip` or `nextTop` values as incomplete changed-path evidence.
Bound policy and status reads and reject continuation indicators that cannot be consumed safely.
List operations retain the existing `COMPLETE`, `TRUNCATED`, and `UNKNOWN` results.

### Configuration and identity

```json
{
  "tracker": {
    "issue_kind": "az",
    "review_kind": "gh",
    "azure_organization": "https://dev.azure.com/example",
    "azure_project": "Example Project",
    "azure_repository": "service",
    "azure_work_item_type": "Task"
  }
}
```

Set `review_kind` to `az` for Azure Repos.
Project and repository settings accept names or GUIDs and match server-returned identity explicitly.
Each registry alias must identify one organization, project, and repository tuple.
Existing review markers remain alias-qualified. Never reuse an alias for a different Azure repository while approvals remain active.
Do not share GitHub metadata snapshots with Azure reads.

### Regression matrix

The wrapper must block missing reviewer approval, missing human approval, stale approval SHA, failed CI, and an outdated source branch.
UI and architecture gates must block incomplete paths and missing required design approvals.
Raw PR updates and mutating REST invocations must block regardless of payload location or auto-completion options.
Completion must reject a source SHA change, policy bypass, malformed response, and incomplete evidence.
Review tests must reject old-iteration threads, vote-only responses, and unavailable evidence.

## Implementation Plan

| Step | Task | Acceptance coverage | Dependency |
|------|------|---------------------|------------|
| 1 | Add explicit context resolution and strict response normalization. | Configuration, failure handling, mixed providers. | Architecture review. |
| 2 | Add work-item view, creation, and listing adapters. | Azure Boards operations. | Step 1. |
| 3 | Add PR review and evidence adapters. | Azure Repos reviews. | Step 1. |
| 4 | Extend forge resolution, merge gates, and CLI dispatch. | Governed PR operations. | Step 3. |
| 5 | Document setup, limitations, and provider examples. | Adopter documentation. | Steps 2–4. |
| 6 | Run regression tests and contribution checks. | Compatibility and test evidence. | Steps 1–5. |

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| CLI defaults select the wrong organization. | Supply context explicitly and verify returned identity. |
| Uncertain creation duplicates a work item. | Report the uncertain write and require reconciliation. |
| Azure completion bypasses framework gates. | Extend both command detection and structured evidence resolution. |
| A provider response resembles success but lacks evidence. | Validate response shape and required fields. |
| New code breaks GitHub adopters. | Keep default dispatch unchanged and run existing adapter tests. |

## Security Considerations

- Treat titles, descriptions, tags, paths, and CLI responses as untrusted data.
- Use argument arrays and JSON encoders instead of shell evaluation.
- Never commit tokens, filled onboarding configuration, or private project identifiers.
- Never weaken a merge gate to compensate for missing Azure evidence.
- Preserve separate independent reviewer and human merge approval requirements.

## Testing Strategy

Use mocked `az` commands for success, CLI failure, malformed output, wrong project, and wrong repository cases.
Cover mixed GitHub and Azure providers, hostile text, closed states, list completeness, and invalid IDs.
Run each new regression against base code to establish fail-before evidence.
Run the full hook suite, shellcheck, pinned markdownlint, and writing-profile checks.
Report Bash version and any unavailable live Azure validation explicitly.

## Approvals

| Role | Status |
|------|--------|
| Human approver | Approved Azure CLI approach in chat on 2026-11-22. |
| Tech Lead | Authored this design. |
| Solution Architect | Independent document review approved the design after two revisions on 2026-11-22. |
| Security Auditor | Independent implementation review found no remaining Important findings after the evidence fixes. |
