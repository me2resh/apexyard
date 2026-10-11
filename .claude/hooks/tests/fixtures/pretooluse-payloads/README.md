# PreToolUse payload fixtures

These files are real hook inputs from Claude Code, captured on 2026-10-11 with a
payload-dump hook. Session ids, paths and tool-use ids are replaced.

| File | Caller | `agent_type` | `agent_id` |
|---|---|---|---|
| `bash-main-thread.json` | the main thread (orchestrator) | absent | absent |
| `bash-code-reviewer.json` | a `code-reviewer` sub-agent | `code-reviewer` | present |
| `bash-general-purpose.json` | a `general-purpose` sub-agent | `general-purpose` | present |
| `posttooluse-bash-general-purpose.json` | the same, PostToolUse event | `general-purpose` | present |

The harness sets `agent_type` to the agent name. The hooks trust this field
(AgDR-0145, amendment of 2026-10-11).
