# Codex Adapter

ApexYard's canonical runtime still lives in `.claude/`: skills, agents, hooks,
rules, and hook wiring are authored there first. Codex support is generated from
that source of truth so the two agent surfaces do not drift by hand.

Decision record: [`AgDR-0080`](agdr/AgDR-0080-codex-adapter-generation.md).

## Generate The Adapter

```bash
bin/sync-codex-adapter.sh
```

The command mirrors:

- `.claude/skills/` to `.agents/skills/`
- `.claude/agents/*.md` to `.codex/agents/*.toml`
- `.claude/hooks/` to `.codex/hooks/`
- `.claude/rules/` to `.codex/rules/`
- `.claude/migrations/` to `.codex/migrations/`
- `.claude/registries/` to `.codex/registries/`
- `.claude/project-config.defaults.json` to `.codex/project-config.defaults.json`
- `.claude/settings.json` to `.codex/hooks.json`

During generation, repo-local references are rewritten from `.claude/...` to the
Codex-facing paths. The generated hook wiring remains relocatable: commands find
the ops root at runtime instead of embedding the local clone path.

Agent model labels are translated to Codex-native equivalents:

| Claude label | Codex label |
|--------------|-------------|
| `opus` | `gpt-5.5` |
| `sonnet` | `gpt-5.4` |
| `haiku` | `gpt-5.4-mini` |

## Drift Check

```bash
bin/sync-codex-adapter.sh --check
```

Use `--check` when generated adapter files are present and you want to verify
they still match `.claude/`. It exits non-zero on drift and prints the files that
need regeneration.

## Clean Regeneration

```bash
bin/sync-codex-adapter.sh --clean
```

Use `--clean` when you want to remove any existing generated `.agents/` and
`.codex/` trees before regenerating them. This is useful after generator changes
or when a source file was renamed or deleted, because a plain generation updates
known output paths but may leave unrelated stale files behind.

## Tracking Policy

The first-pass Codex migration output produced by an editor or assistant should
not be committed directly. It may contain absolute paths, stale casing, or other
machine-local details. For local exploration, add those generated directories to
`.git/info/exclude` in your clone:

```gitignore
.agents/
.codex/
```

The durable upstream contribution is the generator and its tests. A future PR can
decide to track generated adapter output once the generated format is considered
stable; if that happens, `--check` should be part of CI.

## Design Notes

- `.claude/` remains the source of truth.
- Generated files must not contain absolute paths to the local clone.
- Generated paths use lowercase `.codex` and `.agents` consistently so the
  adapter works on case-sensitive filesystems.
- The generator is intentionally plain Bash plus `jq`, matching the rest of the
  framework's hook/test toolchain.
