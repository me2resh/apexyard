# AgDR-0206: Compare the pre-push session pin by file identity

> In the context of pre-push install advice, facing a pin path that names the fork through a different spelling, I decided to compare the pin with Git's main worktree root by file identity (`test -ef`), so a pin that names the real fork always receives advice.

## Context

AgDR-0198 requires a valid session pin and compares it with the checked repository's main worktree.
Git reports a resolved absolute path for that worktree.
The pin file can hold a symlink path, or a different letter case on a case-insensitive filesystem, for the same directory.
A plain string compare then treats the real fork as "not an ApexYard fork" and withholds install advice.
The failure withholds advice only. It is not a security gap.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep the string compare | No change | Symlink and case spellings lose install advice |
| Resolve the pin with `pwd -P`, then compare strings | Fixes the symlink case | Bash `pwd -P` keeps the given letter case, so a case variant still fails |
| Compare with `test -ef` | One operator. Fixes symlink and case spellings through inode identity | None found. The pin string is not used after the compare |

## Decision

Chosen: **compare with `test -ef`**.
The hook still trusts only a pin that the shared ops-root library validates.
Two paths match when they name the same directory on disk.
A pin that does not exist does not match, so it receives only the scope note, as before.

## Consequences

- A pin written through a symlink to the fork receives install advice.
- A case-variant pin on a case-insensitive filesystem, such as default macOS, receives install advice.
- A pin to a different repository still receives only the scope note.

## Artifacts

- Issue #1504
- AgDR-0198
- `.claude/hooks/pre-push-gate.sh`
- `.claude/hooks/tests/test_pre_push_gate.sh`
