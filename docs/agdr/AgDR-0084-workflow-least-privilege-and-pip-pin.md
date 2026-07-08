# AgDR-0084 — Job-scoped write permissions + Docker-digest pin over pip hash-locking

> In the context of OpenSSF Scorecard flagging 5 High/Medium alerts on the framework's own CI (4 Token-Permissions, 1 Pinned-Dependencies), facing a choice between two independent hardening questions — where write scopes should live in a workflow, and how to pin a `pip install` that Scorecard's pinning check can only ever see as unpinned — I decided to (1) **move every top-level write scope down to job level, leaving all workflow-level `permissions:` blocks read-only**, and (2) **replace `pip install semgrep` with Semgrep's official Docker image pinned by digest** rather than hash-lock the pip install, to achieve a clean Scorecard pass without changing what any pipeline does, accepting that the Semgrep step's supply-chain guarantee now rests on a digest bump discipline instead of pip's native hash-checking mode.

## Context

`me2resh/apexyard#819` tracked 5 Scorecard alerts:

- Token-Permissions (High) #58 `auto-tag-on-release-pr-merge.yml`, #59 `codeql.yml`, #60 `extract-subpacks-on-release.yml`, #61 `scorecard.yml`
- Pinned-Dependencies (Medium) #32 `security-scan.yml`

All five workflows already declared a `permissions:` block — the framework had already been through one hardening pass (#636, dc588e1). That ruled out the obvious diagnosis ("no permissions declared") and required reading Scorecard's actual probe source (`probes/topLevelPermissions/impl.go`, `checks/raw/shell_download_validate.go`) plus the live GitHub code-scanning alerts (`gh api repos/me2resh/apexyard/code-scanning/alerts`) to find the real trigger:

1. **`topLevelPermissions` flags ANY write scope declared at workflow level** — regardless of whether a job also declares its own (more restrictive or identical) permissions block. Four workflows granted a write scope (`security-events`, `contents`, or both) at the top level; three of the four already had matching job-level blocks, which didn't matter to this probe.
2. **`isUnpinnedPipInstall` only accepts one thing as "pinned": the literal `--require-hashes` flag.** Adding `--hash=sha256:...` to a normal `pip install pkg==ver` command does NOT satisfy it — the function's control flow treats any non-flag, non-wheel, non-`--require-hashes` argument as "additional args" and returns "unpinned" unconditionally. There is no version-pin-only path that passes.

Verified with `gh api` against the live alert list before writing any fix — see the alert JSON quoted in the PR description for the exact file:line:message triples.

## Options Considered

### Axis 1 — Where do write permissions live

| Option | Pros | Cons |
|--------|------|------|
| Keep top-level `permissions: <write-scope>`, rely on job-level re-declaration to "already be minimal" | No edit needed | This is the exact shape Scorecard flags; job-level scoping doesn't offset a top-level grant in this probe's logic |
| **Top-level `permissions: contents: read` (or `{}` when no checkout happens) on every workflow; any write scope moves to the one job that needs it** | Matches the probe's actual pass condition; matches the convention already used by `tests.yml`/`markdown-lint.yml`/`shellcheck.yml` in this repo; self-documenting (the write grant sits next to the job that uses it) | One more block to add per job that previously relied on a workflow-level grant (`auto-tag`, `pr-title-check`) |
| Set top-level to `permissions: write-all` equivalent and scope down everywhere | — | Strictly worse on every axis; not seriously considered |

Chosen: **top-level read-only, job-level write-where-needed**, applied to `scorecard.yml`, `codeql.yml`, `auto-tag-on-release-pr-merge.yml`, `extract-subpacks-on-release.yml`, and (defence-in-depth sweep) `pr-title-check.yml`. `extract-subpacks-on-release.yml` additionally lost `contents: write` entirely — re-reading the job (checkout → run script → run smoke test → content guard → upload-artifact → summary) found no push, tag, or PR-creation step; the write grant was simply excess, not misplaced. `scorecard.yml` also dropped `id-token: write` at both levels — dead since `publish_results: false` (#679) removed the only step that used Sigstore/OIDC.

### Axis 2 — How to pin the Semgrep install

| Option | Pros | Cons |
|--------|------|------|
| Add `--hash=sha256:...` per package to the `pip install` line | Smallest textual diff | Confirmed by reading Scorecard's source: does NOT satisfy the check. Ships a diff that looks like a fix and isn't. |
| `pip install --require-hashes -r <hash-locked requirements file>` | The literal condition Scorecard checks for; textbook-correct pip hardening | Requires generating and maintaining hashes for semgrep's full transitive dependency tree (many packages), refreshed on every version bump — meaningfully more ongoing maintenance than any other pin in this repo, for a tool that isn't itself part of the shipped product |
| Switch to `pipx install semgrep==<ver>` | Escapes Scorecard's pip-specific regex (`isPipInstall` checks literal `pip`/`pip3` argv[0]) with a one-line change | Passes the *heuristic*, not the underlying concern — pipx still resolves the same unpinned transitive tree under the hood; this is gaming the metric rather than closing the gap it's a proxy for |
| **Run Semgrep via its official Docker image (`semgrep/semgrep`), pinned by digest** | Real reproducibility guarantee (a digest is content-addressed, same guarantee as SHA-pinning an action) with a one-line bump on upgrade, matching every `uses:` action already pinned in this repo; Scorecard's pinned-dependency check does not inspect `docker run` invocations inside `run:` scripts (confirmed: the pre-existing `docker run ghcr.io/gitleaks/gitleaks:v8.18.4` in `extract-subpacks-on-release.yml`, tag-pinned not digest-pinned, isn't flagged either) | Adds a `docker run` dependency to a job that previously only needed Python; output file ownership inside the mounted volume may be root-owned on the runner (harmless — the following `python3` parsing step and `upload-artifact` both only need read access, verified empirically: pulled `semgrep/semgrep@sha256:59fbed61...` locally, ran the exact scan invocation against a test file, confirmed valid JSON output at the expected path, exit 0) |

Chosen: **Docker image pinned by digest**, `semgrep/semgrep@sha256:59fbed6127ea7c5dde3ba6a85142733bb20ea9aaa36120c953904f1539aaf66e` (tag `1.168.0` at time of writing, verified against Docker Hub's tags API and `docker manifest inspect` — confirms a multi-arch manifest list including `linux/amd64`, what GitHub-hosted `ubuntu-latest` runners use). Rejected the hash-lock path because the maintenance cost (regenerating a hashes file across semgrep's full dependency closure on every bump) is disproportionate for a scan tool with no runtime footprint in the shipped product, and rejected `pipx` because it satisfies the letter of Scorecard's regex without closing the actual unpinned-supply-chain gap the check exists to catch.

## Decision

Chosen: **least-privilege top-level permissions + Docker-digest pin for Semgrep**, because both close the real Scorecard-flagged gap (verified against Scorecard's own probe source and the live alert JSON, not just against the alert's plain-English title) while keeping every pipeline's actual behaviour — what gets scanned, what gets uploaded, what triggers what — unchanged.

## Consequences

- Four Token-Permissions alerts (#58, #59, #60, #61) and one Pinned-Dependencies alert (#32) should clear on the next Scorecard run against `main` after this PR merges and releases.
- Bumping Semgrep going forward is a one-line digest change (same discipline as bumping any SHA-pinned action in this repo), not a `pip install semgrep` version bump — slightly more friction, in exchange for a verifiable artefact.
- The `extract-subpacks-on-release.yml` header comment still describes a future "opens a sync PR" step (deferred to v2 per AgDR-0049) that would need its own `contents: write` (or `pull-requests: write`) grant *at that job* when it's built — this AgDR's `contents: read` reflects the workflow's current, actual behaviour only.
- No pipeline's inputs, outputs, or trigger conditions changed — this is a permissions/pinning-only PR per the driving ticket's explicit scope.

## Artifacts

- me2resh/apexyard#819 (driving ticket)
- PR: (see accompanying pull request, branch `chore/819-least-priv-workflow-perms`)
