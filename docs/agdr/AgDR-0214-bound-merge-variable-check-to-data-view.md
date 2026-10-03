# AgDR-0214: Bound merge variable checks to the data view

> For issue #1525, I chose the existing merge scrub for variable checks. Executable and uncertain commands retain raw scanning.

## Context

`is_merge_command` uses `_scrub_merge_command` before it decides whether a Bash call looks like a merge. `merge_command_uses_variable` read the raw call instead. A quoted `cat` heredoc with a sample merge passes the gate today because merge detection stops first. The variable helper still reports a variable in that data when called directly.

The ticket's Python edit uses an interpreter outside the merge scrub allowlist. Its heredoc remains visible and can block. A Python `subprocess.run` argument list also lacked a contiguous `gh pr merge` phrase, so the merge detector missed that executable form.

AgDR-0181 and AgDR-0196 permit data scrubbing only when every command word passes the data-only allowlist. AgDR-0204 adds raw fallbacks for more execution shapes. The tracker gate already uses its own allowlisted scrub under AgDR-0192.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep the raw variable check | Preserves every current block. | The helper disagrees with merge detection on data-only commands. |
| Strip all quoted heredocs before variable checks | Removes more false blocks. | Hides executable bodies from shells, interpreters, and wrappers. |
| Reuse the bounded merge scrub | Aligns the two checks on data-only calls. | Uncertain compound calls can still block on data text. |

## Decision

Chosen: **Reuse the bounded merge scrub**, because its raw fallback keeps executable and uncertain calls visible. The variable helper now uses the same scrubbed view as merge detection.

The raw detector also recognizes consecutive quoted `gh`, `pr`, and `merge` argument elements, independent of the interpreter or function name. It accepts single or double quotes, optional backslash-escaped quotes, and multi-line lists. It also recognizes quoted `gh`, `api`, and a `.../pulls/<N>/merge` path as separate elements. These forms contain no contiguous CLI phrase. The approval gate blocks when it cannot resolve the target.

## Consequences

- A quoted data-only `cat` heredoc no longer reports a merge variable from the helper.
- `bash`, `sh`, `zsh`, `eval`, `source`, and piped shell heredocs retain raw merge text.
- An unquoted heredoc with command substitution retains raw merge text.
- A real variable merge beside a data heredoc still blocks because the compound call includes a non-allowlisted `gh` command word.
- The ticket's Python edit still blocks by design. An interpreter can execute its heredoc body.
- A representative `claude -p` build-agent command triggers the tracker gate's raw fallback. The ticket does not include the exact build-agent command word.
- The raw argument match covers literal Python, Node, and Ruby calls with consecutive quoted elements, including JSON-escaped quotes. The bounded scrub still removes quoted data-only heredocs before detection.
- Tokens built at runtime, passed through variables, or hidden in base64 remain outside this text detector's guarantee.

## Artifacts

- Issue #1525
- `.claude/hooks/_lib-extract-pr.sh`
- `.claude/hooks/tests/test_extract_pr.sh`
- `.claude/hooks/tests/test_block_unreviewed_merge.sh`
- `.claude/hooks/tests/test_merge_command_data.sh`
- `.claude/hooks/tests/test_command_scrub_must_block.sh`
- `.claude/hooks/tests/test_require_design_review_for_ui.sh`
- `.claude/hooks/tests/test_require_architecture_review.sh`
- `.claude/hooks/tests/test_block_ambient_tracker_repo.sh`
