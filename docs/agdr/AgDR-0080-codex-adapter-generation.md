# Codex adapter is generated from the Claude runtime

> In the context of adding Codex support to a framework whose canonical runtime
> currently lives under `.claude/`, facing first-pass generated `.agents/` and
> `.codex/` output that can contain local paths and drift from source, I decided
> to generate the Codex adapter from `.claude/` instead of hand-maintaining or
> directly tracking the generated mirror, to achieve portable multi-agent
> support, accepting that Codex parity depends on the generator's rewrite rules.

## Context

- ApexYard's skills, hooks, agents, settings, migrations, registries, and rules
  are authored under `.claude/` today.
- A first-pass Codex migration produced useful `.agents/` and `.codex/` output,
  but it also embedded local clone paths and inconsistent casing in places.
- Hand-maintaining two runtime trees would create drift every time the Claude
  runtime changes.
- The framework already prefers plain shell and markdown for portable tooling,
  so a generator fits the existing maintenance model.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Track the first-pass generated `.agents/` and `.codex/` output | Fastest path to visible Codex files | Commits machine-local paths and stale casing risk; no source-of-truth story |
| Hand-maintain separate Claude and Codex runtime trees | Each runtime can be tailored precisely | High drift risk; doubles review surface for every skill/hook/agent change |
| Generate the Codex adapter from `.claude/` | Single source of truth; portable rewrites; supports drift checks | Generator must keep up with Codex runtime format changes |

## Decision

Chosen: **generate the Codex adapter from `.claude/`**, because `.claude/` is the
existing canonical runtime and the main risk is drift, not lack of files. The
generator mirrors skills, hooks, agents, rules, migrations, registries, and
config defaults into `.agents/` and `.codex/`, rewrites repo-local references to
Codex-facing paths, and exposes `--check` for drift detection.

## Consequences

- `.claude/` remains the source of truth for framework behavior.
- Codex support can be regenerated in a fresh clone without embedding local
  filesystem paths.
- Generated output can stay local/untracked while the format settles; a future
  PR can choose to track it and enforce `--check` in CI.
- The generator becomes the compatibility boundary. If Codex changes its agent,
  hook, or skill formats, this script is where the adapter evolves.

## Artifacts

- Refs me2resh/apexyard#729
- `bin/sync-codex-adapter.sh`
- `docs/codex-adapter.md`
- `.claude/hooks/tests/test_sync_codex_adapter.sh`
