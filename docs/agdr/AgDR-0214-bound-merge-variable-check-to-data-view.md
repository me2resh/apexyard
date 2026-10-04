# AgDR-0214: Bound merge variable checks to the data view

> For issue #1525, I chose the existing merge scrub for variable checks. Executable and uncertain commands retain raw scanning. #1552 closes the cheap argv-merge gaps that still slipped past that detector.

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

The raw detector also recognizes consecutive quoted `gh`, `pr`, and `merge` argument elements, independent of the interpreter or function name. It accepts single or double quotes, optional backslash-escaped quotes, and multi-line lists. It also recognizes quoted `gh`, `api`, and a `.../pulls/<N>/merge` path as separate elements. These forms contain no contiguous CLI phrase. An argv-only merge never uses the current branch's PR or repo as a fallback. The shared unresolved-target check blocks it in all four gates before their PR extraction step.

Any argv merge makes the target opaque, even when the same command also holds a parseable CLI form. In a mixed command, the extractors would read the CLI form's PR, which can be text that is only echoed, while the argv list merges a different PR. Agents must run a merge as a plain CLI command with a literal PR and repo.

Issue #1552 extends that detector. It still prefers a cheap text match over a full argv parser. A missed merge remains the failure that matters; a rare false block is acceptable. GitHub's required-review rule stays the backstop for shapes this text detector cannot see.

## Consequences

- A quoted data-only `cat` heredoc no longer reports a merge variable from the helper.
- `bash`, `sh`, `zsh`, `eval`, `source`, and piped shell heredocs retain raw merge text.
- An unquoted heredoc with command substitution retains raw merge text.
- A real variable merge beside a data heredoc still blocks because the compound call includes a non-allowlisted `gh` command word.
- The ticket's Python edit still blocks by design. An interpreter can execute its heredoc body.
- A representative `claude -p` build-agent command triggers the tracker gate's raw fallback. The ticket does not include the exact build-agent command word.
- The raw argument match covers literal Python, Node, and Ruby calls with consecutive quoted elements, including JSON-escaped quotes. The bounded scrub still removes quoted data-only heredocs before detection.
- Tokens built at runtime, passed through variables, or hidden in base64 remain outside this text detector's guarantee.
- #1552: padded or full-path `gh` elements, global flags between argv tokens, `glab`/`mr`/`merge` lists, API argv elements that contain commas or backticks, split-tail `"pr merge …"` strings, JS backtick quotes, and short list-join / star-unpack glue (≤ 20 characters with at least one of `][+*,`) are detected and treated as opaque targets.
- Issue 1552: `['sh' or bash or zsh, '-c', <merge text>]`, `xargs` feeding a merge, and Perl `qw(gh pr merge …)` / `qw(glab mr merge …)` stay detected as merges but are opaque targets so they never inherit the branch PR. Opacity is statement-local: separators inside quotes do not split the statement. `xargs` anywhere in the same statement makes the merge opaque (no character window). The argv `-c` form still requires the merge within 200 characters after `-c`. Perl `system('gh','pr','merge',…)` is opaque via the argv list match.

## Follow-ups

| # | Shape | Status | Reason |
|---|-------|--------|--------|
| 1 | Padded / full-path `gh` element (`' gh'`, `'/usr/bin/gh'`) | Handled | Quoted binary element allows an optional path prefix and leading pad. |
| 2 | Global flags between elements (`'-R'`, `'--repo'`) | Handled | Optional quoted flag elements between major tokens. |
| 3 | `glab` / `mr` / `merge` argv lists | Handled | Same argv matcher with a `glab` binary element and `mr` token. |
| 4 | Comma inside another API argv element (`'m=a,b'`) | Handled | Intermediate quoted args may contain commas. |
| 5 | Split-tail element (`'pr merge 5'.split(...)`) | Handled | Quoted `gh` element plus a short glue gap, then a quoted string that starts with `pr` + `merge`. |
| 6 | JS backtick element quotes | Handled | Each quote style matches on its own (`'…'`, `"…"`, `` `…` ``). A backtick inside a single- or double-quoted element (for example a `commit_message` with inline code) does not end that element. |
| 7 | Joined lists / star-unpacking | Handled (bounded) | At most 20 characters between tokens, and the gap must include at least one of `]`, `[`, `+`, `*`, or `,`. Space-only gaps between quoted tokens stay non-matches so prose like `` `gh` `pr` `merge` `` does not look like an argv list. |
| 8 | Python triple-quoted elements, or a comment between elements | Out of scope | A text matcher that accepted comments or triple quotes would also match ordinary prose and review samples. |
| 9 | API path built with an f-string | Out of scope | The merge path is not literal in the command text; no static phrase exists to match. |
| 10 | `['sh', '-c', <merge text>]`, also with `bash` or `zsh` | Handled | Contiguous merge phrase already detects. Opacity applies only when the shell `-c` tokens and the merge phrase share one statement (quote-aware split on semicolon, AND/OR operators, or newline), within 200 characters after `-c`. An earlier unrelated `-c` in a separate statement does not make a later plain merge opaque. |
| 11 | `xargs` feeding a merge | Handled | Contiguous phrase detects. Opacity applies when `xargs` and the merge phrase share one statement (quote-aware). Separators inside the quoted `-c` script that `xargs` runs do not split them apart. No character window. An earlier `xargs` in another statement does not poison a later plain merge. |
| 12 | Perl `qw(...)` and `system('gh','pr','merge',…)` | Handled | `qw` is opaque for both `gh pr merge` and `glab mr merge` (paren and slash forms). The `system` list form is an argv merge. |

### Known limits (not regressions against `dev`)

Rex's LOW advisories. The gates may still resolve the branch PR or miss the merge for these shapes. Recorded so operators recognize the gap; not filed as tickets.

| Limit | Example shape | Notes |
|-------|---------------|-------|
| `qw` list broken across lines inside the merge phrase | `qw(gh pr` then a newline then `merge 5)` | Not detected as a merge. The contiguous phrase check works one line at a time. |
| API argv element with an escaped inner double quote | `"m=say \"hi\""` as an intermediate element | Not detected. The element ends at the inner quote. |
| Argv `bash -c` that changes directory first, or has more than 200 characters before the merge | `['bash','-c','cd other && … merge …']` or a long `-c` script | Resolves to the branch PR. A plain merge with no PR number after a `cd` has the same gap on `dev`. |
| Unquoted command substitution or backticks beside `xargs` | An `env $(…)` or backtick argument containing `;` before the merge | The scanner splits at that semicolon and may resolve the branch PR. Tracking nested substitutions is outside this bounded text scan. |
| Escaped apostrophe inside an ANSI-C string with a trailing comment | An escaped quote inside `$'…'` before `xargs`, followed by `# it's` | The trailing apostrophe balances the scanner's quote count. The target may resolve to the branch PR. `dev` behaves the same way. |
| Heredoc apostrophe with a trailing comment | A heredoc line containing one apostrophe before `xargs`, followed by `# it's` | The trailing apostrophe balances the scanner's quote count. The target may resolve to the branch PR. `dev` behaves the same way. |
| Merge phrase only inside a `#` comment, or glued by `echo … \` onto a later real merge | `# … merge 5 \` then a real `merge 7`, or `echo hello \` then `merge 5` then `merge 7` | Extractors may still read the decoy PR/repo. `dev` matches. Comment-aware join (#1568) stops `# … \` from rewriting `--repo` onto a later line; it does not strip comment decoys. |
| Older `mawk` without interval-expression support | An argv `sh -c` list followed by merge text | The `sh -c` opacity check never triggers because the awk interval expression does not match. The target may resolve to the branch PR. `dev` behaves the same way. |

### Known false positives (fail closed)

These non-merge commands can still match the argv detector. The gate blocks with an unresolved target. That is acceptable. A missed merge is the failure that matters.

| Class | Example shape | Notes |
|-------|---------------|-------|
| JSON argv blob | `jq . <<< '{"cmd":["gh","pr","merge"]}'` | Present before #1552. Comma-separated quoted elements look like a real argv list. |
| Compact JSON / encoded payloads | Same three tokens as consecutive JSON string elements | Same cause as the row above. |

## Artifacts

- Issue #1525
- Issue #1552
- `.claude/hooks/_lib-extract-pr.sh`
- `.claude/hooks/tests/test_extract_pr.sh`
- `.claude/hooks/tests/test_block_unreviewed_merge.sh`
- `.claude/hooks/tests/test_merge_command_data.sh`
- `.claude/hooks/tests/test_command_scrub_must_block.sh`
- `.claude/hooks/tests/test_require_design_review_for_ui.sh`
- `.claude/hooks/tests/test_require_architecture_review.sh`
- `.claude/hooks/tests/test_block_ambient_tracker_repo.sh`

## Evolution

**2026-10-04 — Argv-merge gap shapes (#1552).** The #1525 argv matcher closed the contiguous-phrase hole for literal `['gh','pr','merge']` lists, but padded binaries, global flags, `glab` lists, commas inside API elements, split-tail strings, JS backticks, short list joins, and nested `sh -c` / `xargs` / Perl `qw` wrappers still either missed detection or resolved the wrong PR. Fix: extend `_has_argv_merge` for the cheap literal shapes, and mark nested wrappers opaque via `_has_opaque_merge_wrapper` so extractors never fall back to the branch PR. Triple-quoted elements, comments between tokens, and f-string API paths stay out of scope — a text detector cannot see them without matching prose. Reasoning: a missed merge is the failure that matters; GitHub's required-review rule remains the backstop for runtime-built payloads.

**2026-10-04 — Rex #1556 delta (#1552 follow-up).** The first #1552 pass put the backtick in a shared quote class. It also removed the backtick from the element body. A backtick inside a `'…'` or `"…"` API element then ended that element. The merge became invisible. Fix: match each quote style on its own. The Perl `qw` opacity patterns now match `glab mr merge` as well as the GitHub phrase. Wrapper opacity for `sh -c` and `xargs` now requires the same segment. Newlines flatten to ` ; ` for that check. The scan uses a 200-character bound after `-c` and the existing 80-character bound after `xargs`. Joined-list glue now requires a structural join character. That change drops three space-separated prose false positives. Compact JSON argv blobs remain a known fail-closed false positive. Reasoning: restore detection that base already had. Finish the GitLab `qw` acceptance criterion. Stop unrelated earlier wrappers from blocking plain literal merges.

**2026-10-04 — Rex #1556 round-2 (issue 1552 follow-up).** The segment loop ran one `grep` per statement. A plain merge with thousands of trailing lines took about 10–18 s per gate under `/bin/bash` 3.2 and could time out fail-open. The splitter also ignored quotes, so `xargs -I{} sh -c` with a semicolon inside the quoted script separated `xargs` from the merge and fell back to the branch PR. The 80-character `xargs` window had the same gap for longer same-statement forms. Fix: one awk pass that tracks single and double quotes (and backslash escapes outside single quotes), splits only on unquoted semicolon / AND / OR / newline, and treats same-statement `xargs` as opaque with no character window. The argv `-c` form keeps the 200-character bound. Awk failure fails closed when a merge phrase is present. Known limits above record Rex's four LOW advisories. Reasoning: keep every block that `dev` had, close the main `xargs -I{} sh -c` form, and keep gate latency bounded under bash 3.2.

**2026-10-04 — Rex #1556 round-3 (issue 1552 follow-up).** Repeated one-character `substr` calls in macOS awk made a single long merge statement quadratic. The scanner now splits the text into characters once and extracts each statement at its boundary. It also skips shell comments and treats an open quote at the end of a merge-shaped scan as an opaque target. This closes wrong-PR resolution when an earlier comment or heredoc line contains an apostrophe, or an ANSI-C string contains an escaped quote. A multi-line GitLab `qw(` opener is now handled. Unquoted nested substitutions beside `xargs` remain a known limit above.
**2026-10-04 — #1568 continued-merge target + comment-aware join.** Detectors already scanned `_join_shell_continuations` text (#1564/#1566), but extractors and `_is_argv_only_merge_command` did not. A backslash-newline split CLI merge fell through to the branch PR. Fix: join at the entry of the five PR/repo extractors and opacity helpers, and treat argv merges found only after join as opaque. Security pre-review then found that blind join across `# … \` rewrote `--repo` onto a later merge (bash does not continue comments). Fix: track `#` comments and double quotes in the join awk so comment-ending backslashes do not join, while double-quoted continuations still do. Reasoning: the gate must check the PR/repo the shell actually merges; joining is required for split argv/CLI forms, but must not invent a less-strict target across a comment boundary.

