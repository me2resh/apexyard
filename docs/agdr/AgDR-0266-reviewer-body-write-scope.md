---
id: AgDR-0266
timestamp: 2026-10-21T18:00:00Z
agent: platform-engineer
model: claude-opus-5-5
session: fix-1840-build
trigger: user-prompt
status: executed
category: security
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# AgDR-0266: Give review agents a Write tool that works only in the review-body folder

> In the context of the review agents (Rex and Hakim) that post a review body from a file, facing Bash gates that read the quoted command text in a heredoc body as live commands and block the write, I decided to give both agents the Write tool and to add an edit-channel hook that limits a review agent's writes to one gitignored body folder, to let a reviewer write and post its own review with no gate change, accepting one new hook on the edit channel and a wider tool list for two agents.

## Context

Ticket: me2resh/apexyard#1840. Related: AgDR-0145 (review-class agents are read-only), AgDR-0115 (gates are guardrails, not a security boundary), AgDR-0161 (the Rex marker helper reads the posted body).

`code-reviewer` and `security-reviewer` had the tools `Read, Grep, Glob, Bash`. To post a review, an agent wrote the body to a file with a Bash heredoc and passed the file to `tracker_review_submit`. A review body quotes push, commit, alias and redirect text as evidence. The Bash dispatcher scans the full command text, so it read that quoted text as commands. On 2026-10-21 this blocked four reviews with three different gate messages. The orchestrator had to save each body with its own Write tool and resume the reviewer.

The gates work as designed. A heredoc that holds command text is ambiguous to a text-level scan. Weakening the Bash gates is not an option.

The edit channel (Edit, Write, MultiEdit) sends a structured `file_path`. A hook can judge that path without reading shell text. `review_caller_class` in `_lib-review-markers.sh` already tells a review agent from the orchestrator and from a build agent.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A. Give both agents the Write tool. Add `limit-reviewer-writes.sh` on the edit channel. A review agent may write only under `<ops-root>/.claude/session/reviews/bodies/`. | The hook reads a structured path, not shell text. No Bash gate changes. The body never goes through the dispatcher. One folder, under the gitignored session state. | Two agents get a write tool. A new hook must keep the folder limit correct. |
| B. A helper that reads the body on a file descriptor that no hook scans. | No new tool for the agents. | The body still goes through a Bash call. A hook-free channel in Bash is hard to make safe and hard to explain. |
| C. Keep the current flow. The orchestrator saves each body. | No change. | Extra orchestrator work and tokens on each blocked review. The orchestrator is in the review chain. |

## Decision

Chosen: **A**, because the edit channel already carries the target as a structured field, so the limit is a path check and not a text scan.

- `.claude/agents/code-reviewer.md` and `.claude/agents/security-reviewer.md` list `Write` in `tools`. `Edit` stays in `disallowedTools`.
- `review_body_dir` and `review_body_path` in `_lib-review-markers.sh` name the folder and one file in it: `<ops-root>/.claude/session/reviews/bodies/<owner>__<repo>__<pr>-<role>.md`.
- `limit-reviewer-writes.sh` runs on the `Edit|Write|MultiEdit` matcher. When `review_caller_class` reports `reviewer`, the hook allows only an absolute target that resolves under the body folder of the ops root. It blocks every other target: repository files, hook files, settings files, review markers and any other path. It also blocks a relative path, a `.` or `..` segment, a symbolic link at the target, and a folder link that resolves outside the body folder. It does not need an active-reviewer marker for a typed review agent. It does not affect the orchestrator or a build agent.
- A payload that is not JSON fails closed only when it names a review agent type. When `_lib-review-markers.sh` is missing, the hook uses the built-in review types.
- The hook entry has a 10 second timeout and `"onFailure": "block"`. When the hook crashes or times out, Claude Code blocks the edit-channel call. `test_settings_fail_closed.sh` adds this entry to its list of named fail-closed entries, which now has six entries. The script itself blocks with exit 2 when it cannot judge the target.
- Accepted cost: a crash or timeout of this hook also blocks an edit by the orchestrator or a build agent, because the harness cannot tell the caller when the hook does not finish. In normal use the hook exits 0 for those callers after four jq calls on the payload (one JSON check in the hook, then three in `review_caller_class`). `require-active-ticket.sh` and `block-protected-target-writes.sh` already fail closed on the same channel, so a broken hook install already stops edits there. The operator escape hatch in `docs/hooks-fail-closed.md` applies.
- Rex still writes its approval marker in Bash through `review_write_rex_approved`. That path is unchanged.

In the same change, the reviewer Git-config lock in `block-reviewer-repo-mutation.sh` now judges each `git ... config` segment alone. A read may name a scope or display option before the read action (`--local --get-regexp`, `--global --get`) and may use the `get` and `list` subcommands. Before, these read-only forms were blocked, and a read in one segment let a write in another segment pass.

## Consequences

- A review agent writes its body with Write and posts it by path. The Bash command that posts the body holds only a path, so no gate reads the body text.
- A review agent cannot use Write to change the reviewed branch, the hooks, the settings or a review marker. The Bash mutation lock (AgDR-0145) is unchanged.
- Body files stay in the session state. Git ignores them and no gate reads them.
- `review_body_path` gives the same name for each review round on one PR. In a later round the file exists, so the reviewer reads it with the Read tool before the Write tool replaces it. The agent files say this.
- The hook is a guardrail against honest mistakes (AgDR-0115). It does not try to stop a hostile agent. Hard links and other unusual path shapes are out of scope.
- The ops root comes from the hook copy that runs, and from `resolve_ops_root` on the call's working directory. A body folder under any other root is blocked.

## Artifacts

- `.claude/hooks/limit-reviewer-writes.sh`
- `.claude/hooks/_lib-review-markers.sh` (`review_body_dir`, `review_body_path`)
- `.claude/hooks/block-reviewer-repo-mutation.sh` (per-segment config check)
- `.claude/settings.json`
- `.claude/hooks/tests/test_limit_reviewer_writes.sh`
- `.claude/hooks/tests/test_settings_fail_closed.sh`
- `.claude/hooks/tests/test_block_reviewer_repo_mutation.sh`
