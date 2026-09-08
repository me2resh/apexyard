# Staged private-reference commit gate

> In the context of a public framework repository, facing irreversible disclosure of private portfolio identifiers in commit history, I decided to scan complete staged file content in a Git-native pre-commit hook to block publication before a commit exists, accepting that users can bypass local Git hooks and need the existing command-layer backstop as defence in depth.

## Context

- Issue #1218 requires detection of private identifiers in any staged file. A net diff cannot find a reference that is added and removed in separate commits.
- The existing command-text hook protects tracker writes. It cannot inspect content committed to a file.
- Git invokes a pre-commit hook inside the repository that owns the staged index. This avoids parsing a shell command to find the target repository.

## Options considered

| Option | Benefits | Costs |
|---|---|---|
| Extend the command-text hook | Reuses an existing scanner. | Cannot reliably obtain complete staged content or cover direct Git commits outside the harness. |
| Scan the net PR diff | Runs in a central review path. | Misses add-then-remove history and acts after a commit exists. |
| Scan staged blobs in a Git pre-commit hook | Reads the exact indexed content before commit creation and detects each committed version. | `--no-verify` and clones without installed Git hooks can bypass the local control. |

## Decision

Chosen: **scan staged blobs from a Git-native pre-commit hook**, because the Git index is the only local boundary that contains every file version about to become reachable history without depending on a rendered diff or a parsed shell command.

The hook will resolve the existing portfolio registry, derive the same private identifier classes that leak protection already defines, inspect added, copied, modified, and renamed staged blobs, and report only the file path. It will not print a matched private identifier.

## Consequences

- Every staged file revision is checked before its commit can create public history.
- A later removal cannot erase the earlier blocked commit because the earlier commit cannot be made through the protected path.
- The command-layer hook remains necessary for tracker text and as a backstop against `git commit --no-verify` in agent-driven sessions.
- The control needs Git-hook wiring and end-to-end tests for the installed-hook path.

## Artifacts

- Issue #1218
- `.githooks/pre-commit`
- `.claude/hooks/check-private-refs-staged.sh`
