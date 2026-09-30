# AgDR-0203: Close write-detector gaps for versioned Python and here-doc failure

> In the context of the bash write detector, facing three fail-open gaps on versioned interpreters, option arguments that contain `c`, and unwritable here-doc temp files, I decided to broaden the Python `-c` presence match and fail closed when a segment here-doc cannot be read. This keeps the ticket and migration gates aligned with real writes.

## Context

Issue #1502 found three detector misses after PR #1485 and PR #1496.

1. `python3.12 -c` did not match the `python3?` token.
2. `python3 -W error::ResourceWarning -c` and `python3 -X pycache_prefix=/x -c` hid `-c` behind an option argument that contains the letter `c`.
3. On macOS bash 3.2, segment loops read through a here-doc temp file. When that file cannot be created, the loop saw no segments and reported no write.

Security hooks must never match less than `dev` for any prior input.

## Options Considered

| Option | Benefit | Cost |
|--------|---------|------|
| Keep the #1480 legacy and bundled regex pair and add narrow patches | Small diff | Easy to miss the next option-argument shape |
| One broader `-c` presence form plus a versioned interpreter token | Covers versioned binaries and any intervening option text | Slightly more over-matching on odd commands |
| Document the here-doc failure as accepted residue | No code change | Leaves a real fail-open on full disk and `ulimit -f 0` |
| Fail closed when a segment here-doc produces no reads | Gate blocks when detection cannot run | One extra ticket check when the temp file cannot be written |

## Decision

Chosen: **broader Python `-c` presence plus fail-closed here-doc reads**, because the detector must see the write or refuse to claim a read.

Match `python[0-9]*(\.[0-9]+)*` as the interpreter, and add a form that allows any intervening text, up to a `|`, `;` or `&`, before a short flag that contains `c`. Keep the two #1480 forms in the same alternation, unchanged. The dev `[^c]*` skipper can span `|`, `;` and `&`, so the union keeps the detector from matching less than dev for any input. Track whether a segment here-doc `read` ran. If it never ran, report a write. Suppress the bash here-doc setup message on that path so stderr stays quiet.

## Consequences

- Versioned `pythonX.Y -c` writes reach the ticket and migration gates.
- Option arguments that contain `c` no longer hide `-c`.
- A failed segment here-doc blocks instead of allowing the write.
- Prior #1480 shapes (`-W ignore -c`, `-Bc`, `-B -c`) remain matched because the new form is a strict superset.

## Artifacts

- `.claude/hooks/_lib-detect-bash-write.sh`
- `.claude/hooks/tests/test_detect_bash_write_1502.sh`
- me2resh/apexyard#1502
