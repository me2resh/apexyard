---
id: AgDR-0006
timestamp: 2026-04-24T00:00:00Z
agent: claude
model: claude-opus-4-7
trigger: user-prompt
status: executed
---

# Project-configurable ticket / branch / commit / PR schema

> In the context of external adopters now running apexyard, facing the problem that hard-coded prefix lists in skills and hooks force every team into one opinion (where one team's `[Security]` need meets another's `[Perf]` need meets the framework's hardcoded six), I decided to lift the prefix / type whitelists into a versioned JSON config (`.claude/project-config.defaults.json` + optional `.claude/project-config.json` override) read by a shared shell library (`_lib-read-config.sh`), to achieve one source of truth that skills, hooks, and CI can all read, accepting that the framework now carries a config schema that future tickets must coordinate around.

## Context

- Five near-identical lists were maintained independently across the framework: skill prefix tables (`/task`, `/feature`, `/bug`), `validate-branch-name.sh` regex, `validate-pr-create.sh` regex, `validate-commit-format.sh` regex, `.github/workflows/pr-title-check.yml`. Each had its own wording, its own default list, and its own drift.
- A prior version of `validate-commit-format.sh` already did ad-hoc config reading via a flat `commit_types` top-level key — setting a precedent without a schema, and inconsistent with what future tickets would need.
- External adopters asked for additional prefixes (`[Security]`, `[Scaffold]`, `[Infra]`, `[Design]`, etc.). Hardcoding each new prefix in the framework just shifts the drift and forces every fork to accept our opinion.
- Multiple in-flight hook tickets (#107, #111, #112, #113, #114, #115) need to read project-level config. Without a shared loader they would each reinvent parsing with different conventions.

## Options Considered

| Option | Pros | Cons |
| -------- | ------ | ------ |
| **A. Keep lists hardcoded in each hook** | Zero new abstraction | Drift; forks can't customise without editing framework files; upstream sync becomes conflict-heavy |
| **B. Each hook reads its own one-off config key** | Minimal coupling | Same-pattern drift — every hook's reader differs; forks face N small config keys instead of one schema |
| **C. Shared `_lib-read-config.sh` + versioned schema at `.claude/project-config.*.json` — CHOSEN** | One source of truth; skills / hooks / CI all read the same file; shipped defaults upgrade cleanly via `/update`; forks override only what they need | Schema now has a version number the framework must honour; object merges are recursive and arrays replace wholesale |
| **D. Schema in `onboarding.yaml` | Reuses an existing user-facing file | Mixes org config (stack, quality bar) with tooling policy (prefix lists); YAML parsing adds jq+yq complexity to every hook |

## Decision

Chosen: **Option C**, because it gives every consumer — skills, hooks, CI, future upstream additions — one read path and one file to override. The shipped-defaults file means upstream changes propagate via `/update` without overwriting fork customisation. The implementation uses `jq -s '.[0] * .[1]'`: objects merge recursively, scalar conflicts use the override, and arrays replace wholesale. This keeps the reader aligned with jq while making array replacement explicit to adopters.

Keeping the schema in `.claude/` (not `onboarding.yaml`) reflects the split that already exists in the framework: `onboarding.yaml` is org / stack / quality-bar config the human writes once; `.claude/project-config.*.json` is tooling policy the framework reads on every hook invocation.

## Consequences

**Added:**

- `.claude/project-config.defaults.json` (v1 schema, committed upstream)
- `.claude/hooks/_lib-read-config.sh` (shared reader lib, used by hooks + skills + future)
- `docs/project-config.md` (schema reference + extension guide)

**Migrated:**

- `validate-branch-name.sh` — accepts branch types from `.branch.type_whitelist`
- `validate-commit-format.sh` — accepts commit types from `.commit.type_whitelist` (with backward-compat for the legacy flat `commit_types` key)
- `validate-pr-create.sh` — accepts PR title types from `.pr.title_type_whitelist`
- `/feature`, `/task`, `/bug` skills — reference the config in their Rules sections, do not hardcode the prefix list

**Unlocked (downstream tickets):**

- #107 validate-issue-structure.sh — reads `.ticket.required_sections` (to be added in that ticket's extension of the schema)
- #111 pre-push-gate blocking — reads `.pre_push.commands`
- #112 require-agdr-for-arch-pr.sh — reads `.agdr_trigger_paths` and `.agdr_trigger_dep_files`
- #113 Testing section — reads `.pr.required_sections`
- #114 single Closes keyword — reads `.pr.allow_multiple_closes`
- #115 warn-stale-review-markers.sh — reads `.review_markers.on_stale`
- #110 leak protection — reads `.leak_protection.*`

Each of those tickets extends the schema by adding keys under its own subtree; the reader + merge semantics handle this without further changes.

**Non-consequences (explicitly):**

- Object merges are recursive in the shipped jq implementation; arrays replace wholesale. A fork that overrides an array must copy the entries it wants to retain.
- No runtime schema validation. A malformed config degrades gracefully (reader returns null, hooks fall back to shipped defaults). Add JSON Schema validation if schema complexity grows.
- No migration tool for the legacy `commit_types` flat key — it keeps working via backward-compat in `validate-commit-format.sh`. Will deprecate with a warning in a future ticket once usage is measured.

## Artifacts

- Ticket: `me2resh/apexyard#109`
- Reader lib: `.claude/hooks/_lib-read-config.sh`
- Defaults file: `.claude/project-config.defaults.json`
- Reference doc: `docs/project-config.md`
