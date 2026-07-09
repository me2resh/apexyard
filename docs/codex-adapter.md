# Codex Adapter

ApexYard's canonical runtime still lives in `.claude/`: skills, agents, hooks,
rules, and hook wiring are authored there first. Codex support is generated from
that source of truth so the two agent surfaces do not drift by hand.

Decision record: [`AgDR-0088`](agdr/AgDR-0088-codex-adapter-generation.md). For where Codex sits among all supported harnesses (and the shared-core architecture behind every adapter), see the [harness support index](harnesses/README.md).

## Generate The Adapter

```bash
bin/sync-codex-adapter.sh
```

The command emits:

- `.claude/skills/` to `.agents/skills/`
- `.claude/agents/*.md` to `.codex/agents/*.toml`
- `.claude/settings.json` to `.codex/hooks.json`

It does **not** copy `.claude/hooks/` into `.codex/hooks/`. The generated
`hooks.json` keeps the existing commands that exec the unmodified
`.claude/hooks/*.sh` scripts. That keeps gate decisions, session markers,
review markers, and trust-chain path checks in the same audited bash files that
Claude Code uses today.

Codex documents repo-local hook loading from `.codex/hooks.json`; trusted
project hooks run from the session working directory, and `PreToolUse` hooks can
block by exiting `2` ([Codex hooks docs](https://developers.openai.com/codex/hooks)).
The adapter test therefore proves the generated command path preserves the hook
stdin and exit-code contract. Live Codex coverage still depends on Codex's hook
runtime and trust settings.

Claude Code's handler-level `if` predicates are not part of Codex's documented
hook handler shape. During generation, those predicates are compiled into the
generated shell command as a preflight filter, and the unsupported `if` field is
omitted from `.codex/hooks.json`.

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
or when a source file was renamed or deleted. It also removes stale generated
`.codex/hooks/`, `.codex/rules/`, `.codex/migrations/`, and `.codex/registries/`
directories from earlier adapter versions that copied too much of `.claude/`.

## Tracking Policy

The first-pass Codex migration output produced by an editor or assistant should
not be committed directly. It may contain absolute paths, stale casing, or other
machine-local details. For local exploration, add those generated directories to
`.git/info/exclude` in your clone:

```gitignore
.agents/
.codex/
```

The durable upstream contribution is the generator and its tests. If an adopter
wants to treat Codex as an enforced governance surface, review and trust the
generated `.codex/hooks.json` explicitly and consider tracking the generated
adapter plus enforcing `--check` in CI.

## Design Notes

- `.claude/` remains the source of truth.
- Generated files must not contain absolute paths to the local clone.
- Skill references to `.claude/skills/...` are rewritten to `.agents/skills/...`.
- Hook, rule, session, and review-marker references stay pointed at `.claude/...`
  because those files remain canonical and audited.
- The generator is intentionally plain Bash plus `jq`, matching the rest of the
  framework's hook/test toolchain.
