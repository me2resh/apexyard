# Parse gh pr create structurally — body-file, multi-line, body-example

> In the context of the `validate-pr-create.sh` PreToolUse hook, facing three
> distinct false-positive / false-negative failures caused by scanning the raw
> command string instead of its logical structure, I decided to parse the command
> structurally — normalise line continuations first, gate on the command head
> (not raw text), and resolve body-file paths from the command's CWD — to achieve
> correct validation under all three bug scenarios, accepting a modest increase
> in preprocessing complexity.

## Context

`validate-pr-create.sh` validates `gh pr create` invocations for PR title format,
required body sections (`## Testing`, `## Glossary`), and ticket existence. It
extracted flags by scanning the raw `COMMAND` string as received from the
PreToolUse JSON payload.

Three independent bugs all trace back to the same root cause: raw-string scanning
instead of structural parsing.

**Bug 1 — `--body-file` relative-path invisible.**
The hook checked `[ -f "$BODY_FILE" ]` against the hook's own CWD, not the
`cd`-prefixed target directory in the command. A relative `--body-file body.md`
in `cd /project && gh pr create --body-file body.md` resolved to the hook's CWD,
not `/project/body.md`, so `BODY_CONTENT` was empty and the section check false-blocked.

**Bug 2 — multi-line `\`-continued commands mis-resolved `--repo`.**
Without normalisation, `sed` processes multi-line strings line by line. When
`--repo <value>` sits on a continuation line ending with `\`, the `\` could be
captured as part of the value (or the value garbled by adjacent shell comment
text), yielding a garbage `TRACKER_REPO` like `(hook)` and a spurious "issue does
not exist in (hook)" block.

**Bug 3 — gate fires on `gh pr create` inside a body payload.**
The guard `grep '\bgh\s+pr\s+create\b'` ran against the full raw command. A
`gh issue create --body "...example: gh pr create..."` matched the pattern, and
the hook proceeded to validate the issue-create command as if it were a PR-create.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Raw string scanning (status quo) | Simple, no preprocessing | Three independent failure modes; brittle against multi-line commands, body content, and CWD-relative paths |
| Full shell AST parser (e.g. `bash -n` + eval) | Perfectly correct | Requires executing untrusted code; security risk; no standard cross-platform AST tool in scope |
| Structural preprocessing: normalise continuations + strip body before gate + CWD-aware path resolution | Eliminates all three bugs; no untrusted execution; uses only bash + sed + grep primitives already in scope | Slightly more preprocessing steps; depends on the convention that `--body` / `--body-file` / `-F` flags precede no other positional flags (true for `gh pr create`) |

## Decision

Chosen: **structural preprocessing**, because it eliminates all three failure modes
using the same portable primitives the hook already relies on, without executing
untrusted command content.

Three targeted changes:

1. **Line-continuation normalisation** — replace every `\<newline>` pair with a
   single space immediately after COMMAND extraction. This is a one-liner bash
   parameter expansion (`COMMAND="${COMMAND//$'\\\n'/ }"`) and makes all
   subsequent `sed` flag extractions see a single logical command line.

2. **Gate on command head, not raw text** — before checking for `gh pr create`,
   strip the `--body` / `--body-file` / `-F` payload and everything after it from
   the command, then test the remainder. This eliminates Bug 3 by excluding body
   content from the subcommand detection.

3. **CWD-aware `--body-file` resolution** — after extracting the body-file path,
   resolve relative paths against `CD_TARGET` (extracted via `pr_cmd_cd_target`
   from `_lib-pr-repo.sh`, which is already sourced for `CMD_REPO` parsing).
   This eliminates Bug 1's relative-path case. Absolute paths are unaffected.
   Unreadable files emit a `WARN` and degrade gracefully rather than hard-blocking.

`CD_TARGET` extraction is moved to just after `CMD_REPO` parsing so it is
available for both body-file path resolution (new) and the branch-name fallback
(existing), removing the duplicate `pr_cmd_cd_target` call.

## Consequences

- All three bugs are closed. Existing tests (28 cases across three test files)
  are unaffected.
- Seven new regression tests in
  `test_validate_pr_create_structural_parse.sh` cover Bug 1 (absolute body-file,
  pass + block), Bug 2 (multi-line continuation), Bug 3 (inline body + body-file
  variants), and two regressions.
- The gate-stripping sed pipeline (`--body-file` → `--body` → `-F`, in that order
  to avoid `--body` matching the prefix of `--body-file`) assumes `gh pr create`
  does not use `-F` for a flag other than `--body-file`. This is true for all
  `gh` releases at time of writing.
- The note in the Bug 3 description about `block-unreviewed-merge` matching
  `gh pr merge` inside heredoc bodies is a related but distinct issue, intentionally
  out of scope for this PR.

## Artifacts

- PR: `fix/GH-743-pr-create-structural-parse`
- Files changed: `.claude/hooks/validate-pr-create.sh`,
  `.claude/hooks/tests/test_validate_pr_create_structural_parse.sh`
- Closes: me2resh/apexyard#743
