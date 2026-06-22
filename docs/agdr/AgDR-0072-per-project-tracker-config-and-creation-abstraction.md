---
id: AgDR-0072
timestamp: 2026-06-21T06:00:00Z
agent: claude
model: claude-opus-4-8[1m]
trigger: user-prompt
status: proposed
---

# Per-project tracker config + `tracker_create` creation abstraction

> In the context of a portfolio whose projects use **different trackers** (e.g. one on GitHub and one on GitLab) under a single apexyard fork, facing the #310 invariant that tracker config is resolved **once at the ops-fork level** and the fact that issue/PR **creation** still hardcodes `gh issue create` in `/task` / `/feature` / `/bug`, I decided to introduce **per-project tracker config** (an optional per-project override in `apexyard.projects.yaml`, with the global `.claude/project-config.json → tracker` block as the default) **and** a **`tracker_create` creation abstraction** mirroring AgDR-0033's verification-adapter pattern — selecting the project from the **operation's target repo (never cwd, never a session-global marker)** — to achieve coexisting heterogeneous trackers with zero change for single-tracker forks, accepting added config surface and per-CLI create-output parsing.

## Context

- **Verification is already tracker-agnostic** (AgDR-0033 / #283): `_lib-tracker.sh` dispatches `tracker_view` by `tracker.kind` (`gh` / `linear` / `jira` / `asana` / `custom` / `none`) via a `view_command` template. But the `tracker` block is a single, **fork-level** block in `.claude/project-config.json`.
- **#310 deliberately made tracker resolution fork-global.** Its fix resolved tracker config to the ops-fork anchor *even when invoked from inside `workspace/<project>/`*, because cwd-based resolution silently defaulted to `gh` in workspaces. So "one tracker per portfolio" is an **intentional invariant** — and any per-project design must NOT key the "which project am I?" signal off raw cwd, or it reintroduces #310.
- **Creation is NOT abstracted.** `/task`, `/feature`, `/bug` hardcode `gh issue create --repo …`. The create *guard* (`require-skill-for-issue-create.sh`, #268) matches `ticket.create_command_patterns` = `gh issue create`, `gh api repos/`, `linear`/`jira`/`asana` create forms — but **not** `glab issue create`, and recognising a command ≠ being able to emit it.
- **Driver:** a portfolio with one project on GitHub and a prospective project on GitLab cannot be governed under one fork: verification has one global `kind`, and creation is `gh`-hardcoded. Setting `kind: custom` only fixes *verification* — creation still calls `gh`.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A. Per-project verification only** — per-project `tracker` override in the registry; leave creation `gh`-hardcoded | Small; backward-compatible; unblocks per-project *verification* | **Does not unblock the driver** — still cannot `/task`/`/feature`/`/bug` on the non-GitHub project (creation stays `gh`) |
| **B. Full: per-project config + `tracker_create` abstraction (implemented A→B)** | Fully unblocks multi-tracker portfolios; reuses AgDR-0033's proven adapter shape; backward-compatible for single-tracker forks | Larger surface; per-CLI create-output parsing (issue number/URL) differs per tracker; relaxes the #310 single-tracker invariant |
| **C. Per-project config now; creation abstraction as a tracked follow-up** | Ships verification value sooner | Driver stays blocked until the follow-up lands; risks a half-abstracted verify-yes / create-no state |

## Decision

Chosen: **Option B — per-project tracker config + a `tracker_create` creation abstraction, implemented A→B.**

Concrete shape:

1. **Per-project config (A).** Add an optional `tracker:` block to each `apexyard.projects.yaml` entry (same `kind` / `view_command` / `id_pattern` keys as the global block, plus a new `create_command`). `_lib-tracker.sh` merges **per-project over the global default**; an entry with no `tracker:` behaves exactly as today.
2. **Resolution signal — the operation's target repo, threaded as a parameter.** `tracker_kind` / `tracker_id_pattern` / `_tracker_view_template` (and the future `create_command`) take an **optional `owner/repo` argument**. When supplied, the lib looks up that project's registry `tracker:` block and merges it over the global default; when absent, it returns the global default — **byte-for-byte today's behaviour**. Consumers already hold this repo at the call site (`validate-pr-create` → `CMD_REPO`; `verify-commit-refs` → `TRACKER_REPO`; `/start-ticket` → the ticket's `owner/repo`). The one consumer with no repo in scope (`validate-branch-name`, shape-check only) calls with no argument and correctly gets the global (permissive) pattern. **No session-global marker is read** — a session marker is the wrong signal here, because a hook can fire for project B while the marker points at project A (the exact GitHub+GitLab scenario this feature exists for).
3. **The #310 guardrail, correctly scoped.** #310's lesson is about locating the config *file* via the ops-fork anchor instead of cwd — already handled by `config_get` / `_config_repo_root`. It was **not** about project *selection* (there was only one tracker then). Selecting *which project's* tracker by the operation's target repo is legitimate — `require-active-ticket.sh` itself keys off the `workspace/<project>/` path. The guardrail this design honours: **never pick the project from raw cwd, and never from a session-global marker** — only from the explicit per-operation target repo.
4. **Creation abstraction (B).** Add `tracker_create` to `_lib-tracker.sh` (mirroring `tracker_view`) with per-`kind` adapters (`gh`, `glab`, …, `custom`) that **parse the returned issue ref** (`{ref, url}`) into a common shape. **Crucially — unlike `view` (which substitutes only the simple `{id}`/`{owner_repo}` tokens), `create` carries an arbitrary title + body, so `tracker_create` is a FUNCTION taking args, NOT a string-templated eval.** Built-in kinds (`gh`, `glab`) pass title/labels as proper `--flag "$val"` arguments and the body via `--body-file` (`gh`) / `--description` (`glab`). The `create_command` **template** is reserved for the trusted `custom` kind, where the arbitrary values are passed through **environment variables** (`$TRACKER_TITLE` / `$TRACKER_BODY_FILE` / `$TRACKER_LABELS`) the operator references — quoted values at eval time, never command syntax — with only `{owner_repo}` substituted. This mirrors AgDR-0033's built-in-adapters + custom-passthrough shape and keeps the injection surface closed. Refactor `/task`, `/feature`, `/bug` to call `tracker_create` instead of hardcoding `gh issue create`. **`tracker_create` is itself a creation entry point, so it is added to `ticket.create_command_patterns` — a skill-less `tracker_create` call stays blocked by `require-skill-for-issue-create.sh`.**
5. **Close the guard gap.** Extend `ticket.create_command_patterns` with `glab issue create` (and the `glab` create forms) so the create guard recognises GitLab.

Because, of the three, only B actually unblocks the driver: per-project verification (A) without creation abstraction leaves the non-GitHub project un-`/task`-able. B reuses the adapter pattern AgDR-0033 already validated, so it is consistent rather than novel, and stays backward-compatible for the common single-tracker fork.

## Consequences

- **Backward-compatible.** Single-tracker forks keep one global `tracker` block and a registry with no per-project `tracker:` — zero behaviour change. The default-config regression test (à la `test_tracker_aware_hooks.sh`) must lock this in.
- **Phasing is implementation order, not partial value.** A→B is the build sequence; the driver stays **blocked until B (creation) lands**. A alone must not be mistaken for "solved."
- **#310 is not regressed** *iff* resolution keys off the operation's target repo (passed by the caller). If a future implementer wires it to cwd or a session-global marker, the #310-class bug returns — this AgDR names that explicitly.
- **Creation adapters carry the real complexity.** Unlike `view`, `create` has heterogeneous flags and must parse each CLI's success output for the new issue number/URL; this is the bulk of the work and the main test surface.
- **Per-project resolution needs a YAML parser (`yq` or `python3`+PyYAML).** The registry is YAML and `jq` can't read it. When neither parser is present, `_tracker_project_value` returns empty and the lookup **silently degrades to the global tracker** — a single-tracker fork is unaffected, but an adopter who *has* a per-project `tracker:` block on a parser-less machine gets it **silently ignored, with no warning**. Known edge for Part A; a future hardening could emit a one-line advisory when a per-project block exists but no parser is available. The per-project tests SKIP (don't fail) when no parser is present, mirroring the `jq` guard, so a bare adopter's suite stays green.
- **New config surface** (`create_command` template, per-project `tracker:` block) is documented in `docs/multi-project.md` alongside the existing Linear/Jira/Asana examples.

## Delivery

Shipped as **two stacked PRs against `dev`**, to stay under the <400-line review guideline (`workflows/code-review.md` § Metrics / Anti-Patterns). Each PR is independently reviewable; PR-B builds on PR-A.

- **PR-A — per-project config resolution** (+ this AgDR): registry `tracker:` override, active-ticket/registry resolution (the #310 guardrail), `_lib-tracker.sh` merge of per-project over global, `apexyard.projects.yaml.example` schema, tests. PR body: `Refs #670` (Part 1 — does not close the issue, since the driver is still blocked without creation).
- **PR-B — creation abstraction**, stacked on PR-A: `tracker_create` + per-`kind` adapters, `/task`·`/feature`·`/bug` refactor, `glab issue create` added to `create_command_patterns`, tests. PR body: `Closes #670` (Part 2 — completes the driver).

## Artifacts

- AgDR-0033 / #283 — the verification-abstraction pattern this mirrors
- #310 — the fork-global tracker-resolution invariant this relaxes
- #268 — the create guard / `ticket.create_command_patterns`
- #670 — the feature request this implements (closed by PR-B)
