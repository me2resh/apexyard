# Exclude framework rules per clone

> In the context of absolute-path memory matching, I decided to write a local exclude to preserve personal and project rules.

## Status

Accepted for #1388. Supersedes the wide-pattern decision and scope trade-off in AgDR-0160. The rule index remains unchanged.

## Context

Claude Code merges exclusion arrays across settings layers. The checked-in pattern excluded personal and managed-project rules alongside framework rules.
A checked-in absolute path cannot describe every adopter's clone. Local settings contain user permissions and must retain unrelated bytes.

## Options Considered

| Option | Pros | Cons |
| --- | --- | --- |
| Keep the wide checked-in pattern | No local writer | Hides personal and managed-project rules |
| Move the framework rules | Removes exclusion setting | Requires changing hundreds of references |
| Write one local absolute pattern | Preserves the rule index and other rule directories | Requires local repair and startup timing precautions |

## Decision

Chosen: **write one local absolute pattern** with `.claude/hooks/write-rule-excludes.sh`.

- Remove `claudeMdExcludes` from checked-in settings.
- Resolve the ops root through `_lib-ops-root.sh`, consulting the session pin first.
- Canonicalize directory symlinks with `pwd -P`.
- Map shared governance roots back to this hook's worktree only when both roots share their Git common directory.
- Append `/.claude/rules/**` to the escaped root.
- Use bracket literals for glob metacharacters. Claude Code normalizes backslashes before matching, so backslash escapes are unsuitable.
- Refuse roots containing literal backslashes. Report one warning and continue with existing settings.
- Check protected instruction files, hook paths, and tracked settings before writing.
- Require Git to confirm that local settings are ignored and untracked.
- Reject invalid JSON, duplicate top-level keys, invalid exclusion arrays, and symbolic-link settings files.
- Use jq to merge only `claudeMdExcludes`. Splice that value into the original JSON to preserve all unrelated bytes.
- Preserve existing file mode, write a sibling temporary file, then atomically rename it.
- Refuse an intervening settings edit detected before replacement.
- Report one line after a write. Leave unchanged files untouched on subsequent runs.

The gitignored `.claude/session/rule-excludes.owned` sidecar records the exact entry last written.
After relocation, the writer removes only that recorded entry when it differs from the new entry.
All other exclusions remain unchanged, including absolute user exclusions.
A missing sidecar means the writer removes nothing. An old writer entry can remain after the first upgrade run.
The sidecar uses the same symlink rejection, temporary-file write, and atomic replacement as settings.
The writer rejects symbolic-link session directories.
The resolved root must be the running hook's clone or share its Git common directory.
An unrelated resolved root causes a zero exit without any write.

`/setup` runs the writer once. The existing SessionStart dispatcher runs it after ops-root pinning.
Failures affect token reduction only. The writer always returns zero and never changes gate settings.
The advisory checks actual personal and workspace rule files against local, shared, and personal settings exclusions.
It reports one line when those existing exclusions match. It does not remove user exclusions.

### Startup ordering and first-session gap

The [memory documentation](https://code.claude.com/docs/en/memory#exclude-specific-claude-md-files) documents absolute matching and merged arrays.
The [hook documentation](https://code.claude.com/docs/en/hooks#sessionstart) says interactive SessionStart hooks run in the background.
The first model response waits for their completion. The documentation does not guarantee that initial memory loading waits for these hooks.

Inspection of the installed Claude Code 2.1.296 binary found a cached memory load and a lazily cached exclusion matcher.
The matcher normalizes backslashes in both patterns and paths. This confirms why bracket literals are required.
A second isolated startup probe used a clone path containing brackets, stars, question marks, braces, parentheses, and extglob operators.
With the writer-generated exclude present before startup, InstructionsLoaded reported CLAUDE.md but omitted the framework rule.
An isolated `claude -p` startup probe confirmed the timing gap on 2026-10-12.
The probe used disposable HOME and configuration directories and a loopback API endpoint. It sent no model request successfully.
A SessionStart hook logged START, waited two seconds, wrote the exclude, and logged END.
An InstructionsLoaded hook logged both CLAUDE.md and the framework rule between START and END.
Memory therefore loaded before the SessionStart writer completed in this observed mode.

A fresh clone can load framework rules during its first session. A moved clone has the same potential gap.
`/setup` writes the setting for subsequent launches. Restart after setup or repair to obtain a reliable startup exclude.
The hook cannot retract instructions already loaded. Interactive startup ordering can differ, so no stronger guarantee is claimed.

## Consequences

- Framework rules remain available for explicit reads.
- Personal and managed-project rules remain eligible for automatic loading.
- Existing user exclusions continue to apply and can still exclude these files.
- jq and Python 3 are required for the writer. Missing dependencies produce one warning without blocking a session.
- Existing file modes and unrelated setting bytes remain unchanged.
- The advisory matcher covers standard wildcard and character-class patterns. Brace expansion and extglob user patterns are not fully modeled.
- Atomic replacement prevents partial JSON writes. Concurrent external writers still require coordination beyond the final content check.

## Artifacts

- Issue #1388 and its security requirements.
- `.claude/hooks/write-rule-excludes.sh` and `lib/rule-excludes.py`.
- `.claude/hooks/tests/test_write_rule_excludes.sh` and its Python regression cases.
- Updated setup instructions, SessionStart dispatcher, and rule-loading documentation.
