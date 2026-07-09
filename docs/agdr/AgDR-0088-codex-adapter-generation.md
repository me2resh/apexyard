# AgDR-0088 — Codex adapter delegates gates to the Claude runtime

> In the context of adding Codex support to a framework whose canonical runtime
> currently lives under `.claude/`, facing first-pass generated `.agents/` and
> `.codex/` output that could fork the gate logic by copying and rewriting bash
> hooks, I decided to generate only the Codex-facing skill, agent, and hook
> wiring while delegating gate execution to the existing unmodified
> `.claude/hooks/*.sh` scripts, to achieve portable multi-agent support without
> creating a second governance implementation, accepting that live enforcement
> still depends on Codex's hook runtime and trust settings.

## Context

- ApexYard's skills, hooks, agents, settings, migrations, registries, and rules
  are authored under `.claude/` today.
- A first-pass Codex migration produced useful `.agents/` and `.codex/` output,
  but it also embedded local clone paths and inconsistent casing in places.
- The central adapter risk is not merely file drift; it is enforcement
  faithfulness. A governance adapter is dangerous if it looks wired but silently
  stops enforcing ticket, review, merge, secret, or trust-chain gates.
- The pi adapter decision, [`AgDR-0082`](AgDR-0082-pi-gate-dispatcher-adapter.md),
  established the preferred harness pattern: a thin transport layer shells out
  to the existing, unmodified bash hooks so hook logic remains single-source.
- Claude agent model labels (`opus`, `sonnet`, `haiku`) are not valid Codex
  model identifiers, so the adapter must translate them during generation.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Track the first-pass generated `.agents/` and `.codex/` output | Fastest path to visible Codex files | Commits machine-local paths and stale casing risk; no source-of-truth story; can falsely imply enforced governance |
| Copy and rewrite `.claude/hooks/` into `.codex/hooks/` | Gives Codex-labeled hook files | Forks executable gate logic; mutates marker/session/trust-chain paths; duplicates the review surface |
| Generate skills/agents only, with no Codex hook wiring | Avoids false enforcement claims | Leaves Codex users without even the documented hook entrypoint for ApexYard gates |
| Generate Codex hook wiring that execs unmodified `.claude/hooks/*.sh` | Preserves audited gate logic and marker paths; matches the pi adapter principle; supports drift checks | Relies on Codex's hook loader/trust behavior and still needs runtime conformance testing outside this repo's shell harness |

## Decision

Chosen: **generate Codex-facing skills, agents, and hook wiring while delegating
hooks to `.claude/`**, because `.claude/` is the existing canonical runtime and
the safe adapter shape is a transport over that runtime, not a rewritten copy of
it.

The generator emits:

- `.claude/skills/` as `.agents/skills/`, rewriting only
  `.claude/skills/...` references to `.agents/skills/...`
- `.claude/agents/*.md` as `.codex/agents/*.toml`, mapping the Claude model-tier
  labels to Codex models (`opus`→`gpt-5.5`, `sonnet`→`gpt-5.4`, `haiku`→`gpt-5.4-mini`)
  via the shared `.claude/harness-models.json` matrix — the single source of truth
  every harness adapter reads, so the pi/opencode adapters add a column instead of
  hardcoding a second mapping. Per
  [`AgDR-0087`](AgDR-0087-reasoning-agents-require-frontier-model.md), each
  harness's `opus` row stays on that harness's strongest available model
- `.claude/settings.json` as `.codex/hooks.json`, preserving commands that exec
  `$r/.claude/hooks/*.sh`
- Claude Code's handler-level `if` predicates as shell-side preflight filters in
  the generated command, because Codex only documents matcher groups plus command
  handlers, not handler-local `if` metadata

The generator intentionally does not copy hooks, rules, migrations, registries,
or project defaults into `.codex/`.

## Consequences

- `.claude/` remains the source of truth for framework behavior.
- Codex support can be regenerated in a fresh clone without embedding local
  filesystem paths.
- The adapter no longer rewrites `.claude/session` review markers, the
  `~/.claude/apexyard` session pin path, or trust-chain literals such as
  `.claude/hooks/*`.
- The smoke test exercises the generated hook command with synthetic stdin,
  verifies both block (`exit 2`) and allow (`exit 0`) behavior across the adapter
  boundary, and verifies a nonmatching command predicate is skipped before the
  canonical hook runs.
- Generated output can stay local/untracked while the format settles; an adopter
  who relies on Codex governance should review/trust the generated
  `.codex/hooks.json` and consider tracking generated output plus enforcing
  `--check` in CI.
- The remaining enforcement risk is Codex-runtime conformance: this repository's
  bash test proves command delegation and exit-code preservation, but live
  model-turn coverage depends on Codex loading trusted project hooks and invoking
  matching hook events as documented.
- The generator becomes the compatibility boundary. If Codex changes its agent,
  hook, or skill formats, this script is where the adapter evolves.

## Artifacts

- Refs me2resh/apexyard#729
- `bin/sync-codex-adapter.sh`
- `docs/codex-adapter.md`
- `.claude/hooks/tests/test_sync_codex_adapter.sh`
