---
id: AgDR-0182
timestamp: 2026-09-29T11:35:35Z
agent: codex
model: gpt-6
session: codex-1436
trigger: user-prompt
status: executed
category: security
---

# Scan staged private references as bytes

> In the staged leak scanner, I chose bytewise matching for all registry scans to catch invalid UTF-8, accepting broader matches near non-ASCII bytes.

## Context

BSD `grep` can skip a staged line that contains invalid UTF-8 under a UTF-8 locale. A private name, repo, or workspace on that line can pass the commit gate.

All three scans call `staged_blob_matches`. The owner exemption already runs its text tools under `LC_ALL=C`.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Run the shared `grep` under `LC_ALL=C` | Scans all staged bytes with one change | Treats non-ASCII bytes as token boundaries |
| Rewrite invalid bytes before matching | Could retain locale-aware boundaries | Changes staged content before scanning and adds parsing risk |

## Decision

Chosen: **Run the shared `grep` under `LC_ALL=C`**. This covers the name, repo, and workspace loops without changing their patterns or exemptions.

## Consequences

- A private identifier beside an invalid UTF-8 byte blocks the commit on macOS.
- Bytewise boundaries can block more text near non-ASCII bytes. This favors the leak gate's conservative behavior.
- The regression tests stage Latin-1 bytes in separate name, repo, and workspace cases.

## Artifacts

- `.claude/hooks/check-private-refs-staged.sh`
- `.claude/hooks/tests/test_check_private_refs_non_utf8.sh`
