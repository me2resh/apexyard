# Project Config

`.claude/project-config.defaults.json` ships the framework defaults. Each fork optionally creates `.claude/project-config.json` to override specific top-level keys. Both files live inside `.claude/`, so edits are exempt from the ticket-first hook (per `.claude/rules/workflow-gates.md`).

Related: apexyard#109 introduced this scheme; apexyard#107, #111, #112, #113, #114, #115 all read from it.

## Files

| File | Who maintains | Purpose |
| --- | --- | --- |
| `.claude/project-config.defaults.json` | apexyard upstream | Shipped defaults. Do not edit in a fork — upstream syncs via `/update`. |
| `.claude/project-config.json` | fork owner | Overrides. Optional. Commit or gitignore per the fork's preference. |

## Merge semantics

**Shallow** at the top level. If the override file defines `"ticket": {...}`, that entire subtree replaces the default `ticket` subtree. To extend rather than replace, copy the default fields and add new ones. This keeps the merge behaviour predictable without requiring deep-merge semantics in shell scripts.

## Schema (v1)

```json
{
  "_schema_version": 1,

  "ticket": {
    "prefix_whitelist": ["Feature", "Bug", "Chore", "Refactor", "Testing", "CI", "Docs"],
    "label_priority_scheme": "P0,P1,P2,P3"
  },

  "branch": {
    "type_whitelist": ["feature", "fix", "refactor", "chore", "docs", "test", "spike", "ci", "build", "perf"]
  },

  "commit": {
    "type_whitelist": ["feat", "fix", "refactor", "test", "docs", "chore", "style", "perf", "build", "ci", "revert"]
  },

  "pr": {
    "title_type_whitelist": ["feat", "fix", "docs", "style", "refactor", "perf", "test", "build", "ci", "chore", "revert"]
  }
}
```

### Key meanings

| Key | Used by | Purpose |
| --- | --- | --- |
| `ticket.prefix_whitelist` | `/feature`, `/task`, `/bug`, (future) validate-issue-structure.sh | Bracketed title prefixes accepted for tickets (`[Feature]`, `[Chore]`, …). |
| `ticket.label_priority_scheme` | `/feature`, `/bug`, `/task`, (future) batch skill | Comma-separated priority label scheme. Teams using `P0/P1/P2/P3` vs. `priority-p0/priority-p1/…` configure here. |
| `branch.type_whitelist` | `validate-branch-name.sh` | Acceptable branch-name prefixes (`feature/`, `fix/`, …). |
| `commit.type_whitelist` | `validate-commit-format.sh` | Conventional-commit types for commit subjects. |
| `pr.title_type_whitelist` | `validate-pr-create.sh`, `pr-title-check.yml` (CI) | Conventional-commit types for PR titles. |

## Extending the defaults

### Add a new ticket prefix (e.g. `[Security]`)

```json
{
  "ticket": {
    "prefix_whitelist": ["Feature", "Bug", "Chore", "Refactor", "Testing", "CI", "Docs", "Security"],
    "label_priority_scheme": "P0,P1,P2,P3"
  }
}
```

Every consumer (skills + validator) picks this up on next invocation — no framework edits needed.

### Use a different priority label scheme

```json
{
  "ticket": {
    "prefix_whitelist": ["Feature", "Bug", "Chore", "Refactor", "Testing", "CI", "Docs"],
    "label_priority_scheme": "priority-p0,priority-p1,priority-p2"
  }
}
```

## Reading the config from a hook

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
. "$REPO_ROOT/.claude/hooks/_lib-read-config.sh"

# Get a list of values
types=$(config_get '.branch.type_whitelist[]' | paste -sd'|' -)

# Get a single value with a fallback
scheme=$(config_get_or '.ticket.label_priority_scheme' 'P0,P1,P2,P3')
```

The reader uses `jq` for merging and path lookups. If `jq` is unavailable, the reader emits `{}` (quiet fallback) and prints a one-time warning on stderr — callers should apply their own safety nets.

## Backward compatibility

`validate-commit-format.sh` previously read a flat `commit_types` top-level key from `.claude/project-config.json`. That reader is still honoured as a fallback, so forks that customised commit types before apexyard#109 keep working without edits. New customisations should use the nested `commit.type_whitelist` form.

## Voice prompts

```jsonc
{
  "voice_prompts": {
    "enabled": false,        // master switch — flip to true to opt in
    "voice": "Daniel",       // macOS `say` voice; "Daniel" is British male premium
    "max_chars": 200,        // cap on spoken length, truncated at sentence boundary
    "rate_wpm": 180,         // `say -r` words-per-minute
    "trigger": "questions-only"  // "questions-only" (default) or "always"
  }
}
```

**What it does:** when the assistant ends a turn with a question (or a recognised "Reply with X" / "Approved?" / "(a)/(b)/(c)" pattern), the `voice-prompt-on-pause.sh` Stop hook speaks the last paragraph aloud via macOS `say` — Jarvis-from-Iron-Man style. Surfaces "I'm waiting for input" attentionally for users who've stepped away from the keyboard. See `docs/agdr/AgDR-0009-voice-prompts-on-pause.md` for the full design.

**When it does nothing:** `enabled` is `false` (the shipped default), `say` is not on PATH (Linux/Windows — Phase 2 will add cross-platform), the message doesn't match the trigger heuristic (in `questions-only` mode), or the trigger is set to an unknown value.

**Examples:**

```jsonc
// Turn it on (most common override)
{ "voice_prompts": { "enabled": true } }

// Try a different macOS voice — `say -v ?` lists available
{ "voice_prompts": { "enabled": true, "voice": "Samantha" } }

// Speak every turn-end (debugging the hook itself; noisy in normal use)
{ "voice_prompts": { "enabled": true, "trigger": "always" } }
```

**Privacy:** the hook reads the assistant's text from the local transcript file and pipes it to `say`, which is a local OS binary — nothing leaves the machine. When/if a future phase adds cloud TTS providers (OpenAI, ElevenLabs), that becomes an AgDR-worthy decision in its own right. Today's implementation is fully local.

**Test mode:** the hook respects `VOICE_PROMPTS_SYNC=1` to run `say` synchronously instead of fire-and-forget. Used by `tests/test_voice_prompt_on_pause.sh` so the test runner doesn't race against orphaned background processes. Production invocations always run async.
