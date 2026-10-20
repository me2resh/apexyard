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
- Quoted arguments, literal echo arguments, and confirmed heredoc bodies are data only after every command word passes this check.
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

- The matcher blocks redirections between merge phrase words at command position, including `&>`, `&>>`, and spaced `>&` targets.
- It joins quoted spans within phrase words and matches the host name after its last slash.
- Last-segment host rule: a quoted expansion before the last slash keeps the literal last path segment as the host. An unquoted expansion keeps the host opaque. An unquoted glob in the host word also keeps the host opaque, even when the glob leaves a literal last segment.
- Command position: the first word of a command, after assignments and the words `env`, `command`, `exec`, `builtin`, `time`, `nohup`, `!`, and the control words. Any other first word is a non-host prefix.
- At command position, a phrase window needs at least one literal phrase word. A window of only opaque phrase words matches only when a bare PR number follows it.
- Behind a non-host prefix, including a wrapper with its own options, the host word or the subcommand word must be literal. A literal verb word alone does not match, and a bare PR number does not confirm a window of only opaque words. This keeps ordinary argument lists clear. Host options on the merge host still make the target unresolved (#1812).
- Unknown expansions, escapes, brace expressions, and globs in a phrase word that still leaves a literal peer word make a matching merge target unresolved. All four gates block it.
- Ordinary variable arguments do not start a merge phrase.
- Nested scan queue: the body of a command substitution, a backtick substitution, or a process substitution in a command word goes into the nested phrase scan. When a shell, eval, or source word appears in the command, each word that holds a space or a tab also goes into it. A redirect target or a here-string word goes into it only in that case. The scan never evaluates shell text.
- Open class, owned by #1824: a command substitution in a redirect target or a here-string word, in a command with no shell, eval, or source word. The scan reads that word as data.
- Open class, owned by #1824: a substitution body that holds a closing parenthesis inside quotes or as a `case` pattern. The body scan ends at that parenthesis, so the rest of the body is not scanned as a command.
- Open class: at command position, a window of only opaque phrase words with no bare PR number after it stays clear. This includes the form with no PR argument.
- Open class: behind a non-host prefix, a window whose host word and subcommand word are both opaque stays clear.
- Commands over 120,000 characters and scanner failures block with “could not scan the command”. The unresolved-target helper also fails closed on any split-scan status other than clear.
- Nested scans have limits of three layers, 100 queued words, and 4,096 characters per word. Exceeding these limits blocks with that message.
- The redirect-target guard checks file targets after bash combined-output and zsh clobber operators. Descriptor duplication and closure remain data.
- A two-step write-then-run can hide a merge: one turn writes merge text to an ordinary file, and a later turn runs that file.
- A grep option name padded with more than 48 characters of empty quote pairs, before or inside the name, is not recognised (AgDR-0204 reads a fixed window so the check stays linear).
- A glob such as `?-filter=` expands to an option name only when a matching file exists. The check does not read the file system, so it does not see this.

Forge controls remain authoritative for these limits.

## Architecture evolution

### #1803 detect split phrases before target extraction

The bounded data view now has an additional phrase scan.
It removes intervening redirections and joins quoted word spans without executing shell input.
Unknown shell constructs match unknown word spans at command position.
Host options can precede or separate the phrase words (#1812).
The scan treats each detected split phrase as an unresolved target.
This prevents a split call from using metadata or approvals for another call.
Scanner failures use a separate scan-availability error.
The dollar-sign lookahead reads a fixed 70-character window.
Cheap literal detectors precede the split scan.
Gates reuse their raw scan when the target check has the same data view.
A joined or scrubbed view requires a new scan.
Any split-scan status other than clear fails closed in the unresolved-target check.
Each gate requires the scanner function before it reads a command.

Round 2 (#1807 review): a quoted expansion before the last slash keeps the literal last segment as the host; an unquoted expansion stays opaque.
A non-host prefix does not end the search: a later window still matches when at least one phrase word is literal.
Command-substitution and process-substitution bodies join the nested scan queue.
A window with no literal phrase word stays clear so ordinary three-variable commands do not false-positive.

Round 4 (#1807 review): a bare PR number confirms a window of only opaque words only at command position.
Behind a non-host prefix, the host word or the subcommand word must be literal.
This stops ordinary argument lists, such as a script with three quoted arguments and a number, from matching.
The words `builtin`, `time`, `nohup`, and `!` keep the next word at command position.
The redirect-target and here-string contexts and the quoted-parenthesis body limit stay open under #1824.

The redirect-target guard now checks combined-output file targets and zsh clobber targets.
Descriptor duplication and closure retain their existing data behavior.
The two-step write-then-run limit remains.
The matcher remains a bounded text check, not a shell evaluator.

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
- `test_merge_split_phrase.sh`
- `test_merge_split_rework.sh`
- `test_merge_gate_library_functions.sh`
- `test_merge_known_limits.sh`
- `test_command_scrub_must_block.sh`
- AgDR-0204
