# AgDR-0196: Bound merge data scrubbing and verify library functions

> In the context of merge gates that scan Bash text, I chose a bounded data scrub and explicit function checks. This reduces false positives while preserving the raw scan for uncertain commands. It adds a small dependency on the existing scrubber for the improved read-only behavior.

## Context

The merge parser matched command words inside `grep` patterns and scratch heredocs. The same parser must still detect CLI merges, API merges, wrapper calls, and shell execution of quoted text. A sourced library can also be empty while `source` returns success. The gates then treat an undefined merge detector as a negative result.

AgDR-0104 identifies shell text matching as a backstop. The forge remains the authoritative merge control. The local gates still need to fail closed when their own logic is missing.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Scan all raw text | Keeps current conservative matches | Blocks data-only review commands |
| Scrub every command | Removes more false positives | Could hide a merge in an ambiguous wrapper |
| Scrub bounded data commands and retain a raw fallback | Covers the reported cases and keeps uncertain shapes visible | Some read-only wrappers remain conservatively gated |

## Decision

Chosen: **scrub bounded data commands and retain a raw fallback**. The parser uses the existing allowlist scrubber when a command starts with a data-producing word. The scrubber returns raw text if it sees a command it cannot classify. The gates scan raw text when JSON parsing fails. Each gate checks its required functions after sourcing each required library. A missing function blocks with a named error.

## Consequences

- `grep` patterns and confirmed heredoc bodies no longer look like merges in the covered read-only shapes.
- Executable merges and uncertain wrappers retain the raw match path.
- A missing or truncated required library blocks before the gate reads the command.
- A missing optional scrubber leaves the conservative raw scan in place.

## Artifacts

- Issue #1489
- `test_merge_command_data.sh`
- `test_merge_gate_library_functions.sh`
