# Use Azure DevOps Services

Select Azure Boards and Azure Repos per project while retaining GitHub for other projects.
GitHub remains the default. Azure Pipelines generation and Azure DevOps Server are outside this adapter's scope.

## Prerequisites

Install Azure CLI and its Azure DevOps extension.
Authenticate using Microsoft's supported Azure CLI flow.
Use the minimum work-item and code permissions required by your operations.
Never commit credentials or place them in project configuration.

```bash
az extension add --name azure-devops
az login
```

See Microsoft's [Azure DevOps CLI authentication guide](https://learn.microsoft.com/en-us/azure/devops/cli/log-in-via-pat).
The adapter uses the CLI's authentication. It does not read or store tokens.

## Configure a provider

Add these settings to your gitignored `.claude/project-config.json`:

```json
{
  "tracker": {
    "kind": "az",
    "azure_organization": "https://dev.azure.com/example",
    "azure_project": "Example Project",
    "azure_repository": "service",
    "azure_work_item_type": "Task"
  }
}
```

Organization context must use `https://dev.azure.com/<organization>`.
Project and repository settings accept names or IDs.
The adapter resolves names and verifies server-returned project and repository identity.
It disables automatic CLI context detection.

For a mixed-provider project, select each axis separately:

```json
{
  "tracker": {
    "issue_kind": "az",
    "review_kind": "gh",
    "azure_organization": "https://dev.azure.com/example",
    "azure_project": "Example Project"
  }
}
```

This example uses Azure Boards with GitHub pull requests.
Set `review_kind` to `az` for Azure Repos.
Each project's registry `tracker` settings override global settings.

```yaml
projects:
  - name: example-service
    repo: azure/service
    ticket_prefix: AB
    tracker:
      kind: az
      azure_organization: https://dev.azure.com/example
      azure_project: Example Project
      azure_repository: service
```

The `repo` field is a unique registry alias for the provider context.
Use the same alias in tracker calls and review markers.
Never reuse an alias for another repository while active approvals exist.
Keep each clone's actual Azure Git remote URL for Git operations.
No adapter call derives its organization from that remote or the working directory.

## Work-item operations

The tracker library accepts numeric IDs and `AB-<number>` references.
It returns uppercase states, browser URLs, descriptions, and tags as labels.
It creates `Task` work items unless `azure_work_item_type` specifies another process-supported type.

```bash
source .claude/hooks/_lib-tracker.sh
tracker_view AB-42 azure/service
tracker_create azure/service 'Add validation' /absolute/path/ticket.md enhancement
tracker_list azure/service state=open limit=30
```

Lists support `state`, `since`, and limits from 1 through 200.
Open and closed filters use the standard Closed, Done, Removed, and Resolved state names.
For custom process states, use `state=all` and inspect the returned states.
The adapter rejects assignee, author, label, search, and milestone filters.
Since-filtered lists report unknown completeness rather than implying a complete result.
An uncertain creation result requires reconciliation before another create attempt.

## Pull-request operations

Use the tracker interface for Azure PR creation, review, and completion.
Preserve your project's structured ticket and review requirements.
Skills that still invoke `gh` directly need provider-specific read steps. These adapters do not translate arbitrary GitHub CLI commands.

```bash
source .claude/hooks/_lib-tracker.sh
tracker_pr_create azure/service 'feat(AB-42): add validation' /absolute/path/pr.md main feature/AB-42-validation
tracker_review_submit azure/service 7 comment /absolute/path/review.md
```

Creation requires an explicit source branch, target branch, and body file.
It runs the existing PR creation validator and never enables automatic completion.
Review submission creates a server thread associated with the reviewed source iteration.
Approve and request-changes verdicts also submit the matching Azure vote.
A vote alone does not prove that a review occurred at a commit.

Complete a PR only through the existing human-approved merge workflow.
Its `tracker_pr_merge` call runs all four merge gates before submitting completion.
The request supplies the expected source SHA and never bypasses branch policy.
Missing evidence, changed source commits, and uncertain responses stop completion.
The adapter never retries an uncertain completion automatically.

The Bash dispatcher blocks raw Azure PR create and update commands, including automatic completion.
It also blocks raw Azure REST invocation. Adapter internals use that interface with explicit validated context.
Read-only commands such as `az repos pr show` remain available.
These command-text hooks guide agent operations. They do not sandbox arbitrary executable code.

## Required merge evidence

- Reviewer and human approval markers must match the Azure source SHA.
- Every source SHA change requires renewed Azure approvals. GitHub's approval carry-over does not apply.
- Posted-review checks join thread iteration context to the server's source commit.
- UI and architecture checks require a complete changed-path response, including original rename paths.
- Changes to gate configuration require readable base-branch configuration.
- CI requires approved blocking policies and successful statuses associated with the current source iteration.
- The source branch must contain the target branch's commits.

Configure current-iteration PR status publication and at least one blocking branch policy before enabling governed Azure completion.
Missing current-iteration statuses block completion, even when all policies show approval.
Changed-path responses above 3,000 entries or with continuation indicators also block completion.
Each CLI call has a 30-second timeout.

## Validation limits

The regression suite uses mocked CLI responses and does not require Azure credentials.
Before production use, validate authentication, process-specific fields, thread context, policies, and expected-source completion in a disposable Azure project.
In particular, verify that a concurrent source update rejects an expected-source completion request.
Do not treat mocked tests as evidence of live tenant validation.

See [AgDR-0323](../agdr/AgDR-0323-azure-devops-adapters.md) for the decision and trade-offs.

## Glossary

| Term | Definition |
|------|------------|
| Azure Boards | Azure DevOps work-item tracking. |
| Azure Repos | Azure DevOps Git repositories and pull requests. |
| Iteration | An Azure PR revision associated with a source commit. |
| SHA | The hexadecimal identifier of a Git commit. |
| WIQL | Work Item Query Language used by Azure Boards. |
