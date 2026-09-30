# AgDR-0204: Keep raw scans for additional execution shapes

> For merge data scrubbing, I chose additional raw fallbacks because shell expansion, persistent writes, and grep options can execute data, accepting conservative matches.

## Context

AgDR-0196 allows a narrow command list to hide quoted data from merge detection.
Issue #1507 identifies three execution shapes within that list.
All four merge gates share this parser.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Scan every command as raw text | Preserves uncertain merge phrases | Blocks ordinary read-only data cases |
| Add bounded raw fallbacks | Preserves existing read-only behavior | Cannot model every shell execution path |
| Parse complete shell semantics | Could distinguish more cases | Adds complexity and host-specific assumptions |

## Decision

Chosen: **add bounded raw fallbacks**, because each check can only give the existing detector more text to match.

- For each shape, return the raw command and the `dev` scrubbed text, on separate lines. The detector then matches everything `dev` matched, plus the raw text.
- Add the raw command when unquoted `~[` appears outside a heredoc body.
- Add the raw command for output redirects to shell startup names or paths under `.git/hooks/`.
- Inspect quoted and concatenated literal redirect targets without evaluating them.
- Add the raw command for `grep`, `egrep`, and `fgrep` options named `--filter`, `--pager`, `--view`, or `--format-open`.
- Recognize separate values, `=` values, and option names that are fully or partly quoted (`--"filter"=`, `""--filter=`). The shell removes the quotes, so grep receives `--filter=`. The check reads a fixed window at each word start and drops quote characters from it.
- Treat these option names conservatively even when an earlier argument could make them data.
- Preserve the existing fallback for expansions, escapes, unknown commands, and incomplete syntax.

The checks do not execute command text or consult the host filesystem.
Each check stays linear in the length of the command. The grep-option check reads a fixed 24-character window, and only at a dash that starts a word. A gate that times out does not block, so a slow check would open the gates (Hakim, review of PR #1517).
Startup names include shell dotfiles and their common system variants.
The path check recognizes literal names, not symlinks or arbitrary custom startup locations.

## Consequences

- The detector matches every command that `dev` matched. A first version returned only the raw text, which lost a merge phrase split by quotes, because `dev` scrubbed each quoted span to spaces and so joined the words (review of PR #1517). Returning both views fixes that.
- Ordinary `grep`, `cat`, and `echo` data cases still pass.
- Each new execution shape must reach all four merge gates.
- AgDR-0196 records split merge phrases and separate write-then-run calls as known limits.
- Forge controls remain authoritative.

## Architecture evolution

### Bounded raw fallbacks for #1507

The narrow scrub from AgDR-0196 blanked quoted merge text inside allowlisted commands. Three shapes can still execute that text: zsh `~[`, redirects into startup or hook paths, and grep options that run a program. Adding the raw text for those shapes, next to the `dev` scrubbed text, is stricter than `dev` was after #1497, and does not loosen any prior match. Known limits stay documented on AgDR-0196 rather than closed here.

## Artifacts

- Issue #1507
- `.claude/hooks/_lib-extract-pr.sh`
- `.claude/hooks/tests/test_merge_command_data.sh`
- `.claude/hooks/tests/test_merge_known_limits.sh`
- `docs/agdr/AgDR-0196-merge-command-data-and-library-integrity.md`
