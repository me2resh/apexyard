# Subagent skill-listing size 2026-10-19

Aggregate measurement only. No path and no username.

## Method

Open one local Claude Code subagent transcript.
Find the attachment whose type is `skill_listing`.
Measure the UTF-8 byte length of that attachment's `content` field.
Also record the UTF-8 byte length of the full attachment JSON object.

## Result

| Field | Value |
|---|---|
| Date | 2026-10-19 |
| `content` field (UTF-8 bytes) | 30,077 |
| Skill lines in that listing (about) | 138 |
| Full attachment JSON (UTF-8 bytes) | 32,847 |

This size supports the harness request that agents without the Skill tool should not receive a skill listing.
