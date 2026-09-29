# AgDR-0191: Detect git/sort/yq output writes and python3 -Bc

> In the write detector, facing five missed write forms listed as AgDR-0181 residue, I decided to add dedicated matchers and target extraction where the flag names a path, and to widen the python `-c` presence pattern for bundled shorts, so the ticket and migration gates see those writes without changing the AgDR-0181 scrubber allowlist.

## Context

Issue #1480 listed detector gaps that already existed on `dev`. They were not a regression from PR #1466. `git log` / `git diff` `--output`, `sort -o`, and `yq -i` write files. `python3 -Bc` runs the same `-c` program as `python3 -c`, but the old presence regex required a separate `-c` token.

`git`, `sort`, and `yq` stay on the data-only allowlist from AgDR-0181. Detection must fire on the scrubbed syntax view those tools receive, and on the raw view when scrubbing does not apply.

## Options Considered

| Option | Benefit | Cost |
|--------|---------|------|
| Remove `git` / `sort` / `yq` from the scrubber allowlist | Forces raw text for those tools | Reopens ordinary quoted false positives such as `git log --format='%h > %s'` |
| Add detector matchers only, keep the allowlist | Closes the gaps. Keeps scrubbing for allowlisted data tools | Matcher table grows |
| Treat every new form as unextractable only | Smallest change. Still blocks under #1416 | Loses named targets for `git` / `sort` / `yq` in gate messages |

## Decision

Add detection for each form. Keep the AgDR-0181 allowlist unchanged.

Extract the path for `git log|diff --output`, `sort -o` / `--output`, and `yq -i` / `--inplace` when the flag or trailing operand names it. Leave `python3 -Bc` unextractable, like other inline interpreter writes. An empty target list still fails closed under the existing #1416 rule.

Widen `_BDW_PYTHON_DASH_C_RE` so a lone `-c`, bundled shorts that include `c` (`-Bc`, `-cB`), and preceding short flags without `c` (`-B -c`) all match. Long options such as `--check` stay out because a second leading dash fails the short-option class.

Wire the new matchers into `bash_command_appears_to_write`, `_bdw_detects_other_write`, and `bash_command_is_deletion_only` so sed `w` decoy hold-back stays in step.

## Consequences

- The five #1480 forms block without an active ticket and allow with one.
- Ordinary allowlisted reads such as `git log --format='%h > %s'`, bare `sort`, and `yq` without `-i` stay ungated.
- AgDR-0181 Residue no longer lists these forms.

## Artifacts

- Issues: #1480, #1459
- Library: `.claude/hooks/_lib-detect-bash-write.sh`
- Tests: `.claude/hooks/tests/test_detect_bash_write.sh`, `.claude/hooks/tests/test_command_scrub_must_block.sh`, `.claude/hooks/tests/test_command_scrub_regressions.sh`, `.claude/hooks/tests/test_require_active_ticket_bash.sh`
- Related: [AgDR-0181](AgDR-0181-fail-closed-bash-command-scrubbing.md)
