# AgDR-0196: Bound merge data scrubbing and verify library functions

> Merge gates use an independent, narrow data scrub and explicit function checks. This reduces false positives while preserving the raw scan for uncertain commands.

## Context

The merge parser matched command words inside `grep` patterns and scratch heredocs. The same parser must still detect CLI merges, API merges, wrapper calls, and shell execution of quoted text. A sourced library can also be empty while `source` returns success. The gates then treat an undefined merge detector as a negative result.

AgDR-0104 identifies shell text matching as a backstop. The forge remains the authoritative merge control. The local gates still need to fail closed when their own logic is missing.

Review found that the general scrubber allowed `gh api`, `git`, `rg`, and `sort`. These programs can execute quoted endpoints or payloads written earlier in the command. A line-based first-word check also matched later lines.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Scan all raw text | Keeps current conservative matches | Blocks data-only review commands |
| Scrub every command | Removes more false positives | Could hide a merge in an ambiguous wrapper |
| Scrub bounded data commands and retain a raw fallback | Covers the reported cases and keeps uncertain shapes visible | Some read-only wrappers remain conservatively gated |

## Decision

Chosen: **scrub only the narrow merge-specific command list and retain a raw fallback**.

- Every segment must start with a literal `grep`, `egrep`, `fgrep`, `cat`, `echo`, `jq`, `head`, `tail`, or `wc` command word. `printf` is excluded: `printf -v` into an array element evaluates the subscript, which can run a command substitution.
- The parser checks each segment across separators and newlines. It never searches whole lines for an apparent first word.
- Any other command word preserves the entire raw command, including `gh`, `glab`, `git`, `tracker_pr_merge`, `rg`, `sort`, `xargs`, `find`, and shells.
- Quoted arguments and confirmed heredoc bodies are data only after every command word passes this check.
- Uncertain syntax, substitutions, incomplete input, and parser failures preserve the raw scan. JSON parsing failures also use the raw scan.

The merge scrubber lives in `_lib-extract-pr.sh`. Merge detection does not source `_lib-command-scrub.sh` or use its general allowlist. Non-merge consumers retain that library and its existing behavior.

Each gate lists `_scrub_merge_command` as a required function. The existing `command -v` and `declare -F` checks remain unchanged. Missing functions block with a named error.

AgDR-0204 extends the raw fallback for unquoted `~[`, startup and `.git/hooks/` redirects, and grep-family execution options.

## Consequences

- `grep` patterns and confirmed heredoc bodies no longer look like merges in the covered read-only shapes.
- Executable merges and uncertain wrappers retain the raw match path.
- A missing or truncated required library blocks before the gate reads the command.
- The merge path has no optional scrubber dependency.
- `rg` patterns and other commands outside the narrow list retain conservative raw matching, even when their arguments appear harmless.

## Known limits

- A merge phrase split with quotes can evade the contiguous text match after scrubbing blanks each quoted span.
- A two-step write-then-run can hide a merge: one turn writes merge text to an ordinary file, and a later turn runs that file.
- A grep option name padded with more than 48 characters of empty quote pairs, before or inside the name, is not recognised (AgDR-0204 reads a fixed window so the check stays linear).
- A glob such as `?-filter=` expands to an option name only when a matching file exists. The check does not read the file system, so it does not see this.

Forge controls remain authoritative for these limits.

## Architecture evolution

### #1507 raw fallbacks for three execution shapes

PR #1497 reviews named three shapes inside the narrow list that can still execute data. The scrubber now keeps the entire raw command for unquoted `~[`, output redirects to shell startup names or `.git/hooks/`, and grep-family `--filter` / `--pager` / `--view` / `--format-open`. Ordinary `grep`, `cat`, and `echo` data cases stay scrubbed. See AgDR-0204.

### #1639 jq joins the data-only list

We added `jq` because it cannot execute shell text.
The raw fallback still applies to any other command word outside the list.
`test_merge_command_data.sh` adds jq data cases and pins executable forms to the raw scan.
`test_block_ambient_tracker_repo.sh` adds data cases and pins real PR checks to explicit repository selection.

### #1639 ORBIT arguments join the general data allowlist

The owner chose the allowlist fix for PR #1657 after Rex reviewed `4158947`.
`orbit` joins `_lib-command-scrub.sh`: its planning arguments are data, not shell text.
The narrow merge list is unchanged. Shell wrappers and substitutions retain the raw scan.
`codex` and `cursor-agent` remain excluded. `codex exec` accepts a prompt as data,
but its agent can run commands outside this hook. We have not established that every
invocation of either CLI meets the data-only contract, so the conservative fallback stays.

A standalone lowercase scalar assignment with a literal path value can precede a quoted file heredoc.
Environment prefixes, uppercase special variables, arrays, expansions, and executable assignment values retain raw scanning.
The zsh names path, fpath, cdpath, manpath, module_path, mailpath, and psvar also retain raw scanning.
Assigning path in zsh sets PATH.
The other names set tied search arrays.
Tests cover the variable-path heredoc and later real tracker commands on two active repositories.

### #1665 zsh tied names stay raw

The lowercase path-assignment exception treated `path=/x` as data.
In zsh that assignment sets PATH.
The same exception now keeps path, fpath, cdpath, manpath, module_path, mailpath, and psvar raw.
`test_command_scrub_regressions.sh` checks one heredoc redirect per name.
An ordinary name such as `d=/tmp/x` stays data.

`_portfolio_reset_caches` used `export -n` to drop the export flag on its internal names.
zsh rejects that option and prints `bad option: -n`.
Bash 3.2 still uses `export -n`.
zsh uses `typeset -g +x`, which leaves the same empty unexported names.
`test_portfolio_paths.sh` sources the library under zsh and expects empty stderr.

## Artifacts

- Issue #1489
- Issue #1507
- Issue #1665
- `test_merge_command_data.sh`
- `test_merge_gate_library_functions.sh`
- `test_merge_known_limits.sh`
- `test_command_scrub_must_block.sh`
- AgDR-0204
