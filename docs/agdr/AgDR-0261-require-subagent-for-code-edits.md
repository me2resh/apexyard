---
id: AgDR-0261
timestamp: 2026-10-19T00:00:00Z
agent: tech-lead (Hisham)
model: claude-opus-5-5
session: draft
trigger: user-prompt
status: accepted
category: security
---

<!-- Approved design v6, filed as AgDR-0261 by the D17 ticket me2resh/apexyard#1806. All line references are at upstream dev 23d8387. v6 answers the Security Auditor pass on v5 (S1-S3, A1-A5) and records the CEO decisions D1-D21 of 2026-10-19. -->

# Block code edits on the main thread and require a build-role subagent

> In the context of build work that the orchestrator does on the main thread or hands to `general-purpose`, facing role boundaries that no hook enforces and hook and settings files that an agent can change in-session, I decided to land a tamper-hardening ticket first and then a gate that classifies the caller by `agent_id`, `agent_type` and a SubagentStart ledger, rolled out in warn mode, to make role boundaries mechanical, accepting one subagent spawn for each small fix, one release of warnings, hook work only in isolated worktrees, and Bash backstops that cannot catch every write form.

## Outcome and next action

- Outcome: the CEO decided D1 to D21 on 2026-10-19 (§ Decisions for the CEO). This record states the design that those decisions select. No item is open.
- The work is split into tickets in a fixed order (§ Decision, "Ticket order"). Each ticket has its own section with its scope, tests and artifacts.
- The D17 tamper-hardening ticket cites this record. It needs no new AgDR. Its section carries the AgDR-0181 § Scope amendment (D14). It is blocked by the #1748 build (D21).
- The Security Auditor (Hakim) passed § B and § C of v5 with two blocking findings. v6 fixes them (§ Review response). The CEO closed the design rounds on 2026-10-19.
- Next action: build the D17 tamper ticket (#1806), after the #1748 build (PR #1804) merges. The Security Auditor reviews the D17 code PR. § B.14 lists the merge requirements of that PR.

## Glossary

| Term | Definition |
|------|------------|
| Main thread | The top-level Claude Code session that orchestrates work |
| Subagent | An agent that the main thread starts with the `Agent` tool |
| Teammate | An in-process agent-team member. The harness gives it an `agent_id`. |
| Build role | A subagent type on the build-role list in § D.4 |
| Review agent | A subagent type in `REVIEW_AGENT_SLUGS` or `review_markers.extra_review_agents` |
| Pin tree | The directory `${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}` |
| Session gate directory | `<pin tree>/gate-session-<session_id>/`. It holds the session snapshot and the subagent ledger. |
| Session snapshot | A write-once record that the first SessionStart of a session writes into the session gate directory (§ B.1) |
| Subagent ledger | The per-session record of each `agent_id` and `agent_type` that a SubagentStart hook saw (§ D.1). The review called it a "registry". This record uses "ledger" because "registry" already names `apexyard.projects.yaml`. |
| Portfolio registry | `apexyard.projects.yaml` |
| Live root | The resolved, physical path of the pinned ops root, or of the project directory that the session snapshot recorded (§ B.1) |
| Live settings file | `.claude/settings.json` or `.claude/settings.local.json` directly under a live root |
| Live hook script | A file under `.claude/hooks/` of a live root. The settings launchers run these files. |
| Protected path | A path in § B.2. No caller may change it through a tool call. |
| Protected ancestor | A directory that contains a protected path, such as `.claude/hooks`, `.claude`, a live root, the pin tree or `~/.claude`. § B.2 lists them. |
| Protected token | A text string in a raw Bash command that names a protected path, listed in § B.4 |
| Temp root | `/tmp`, `/var/tmp`, `$TMPDIR` or `$CLAUDE_CODE_TMPDIR`, as `_lib-active-ticket.sh:1537` lists them, compared by physical path on both sides |
| Orchestrator path | A path that the main thread may write, listed in § D.2 |
| Code path | A write target inside a governed tree or any git work tree that is not an orchestrator path |
| Governed tree | The ops fork, or a registered `workspace/<project>` clone |
| Edit channel | The `Edit`, `Write`, `MultiEdit` and `NotebookEdit` tools |
| Bash channel | The `Bash` tool |
| Control | A gate that decides on harness-set, structured fields (AgDR-0104 label) |
| Backstop | A gate that classifies command text, and so cannot be sound (AgDR-0104 label) |

## Context

### The problem

The framework tells the orchestrator to send build work to a role agent. `.claude/rules/agent-role-selection.md` states that this is "primarily self-discipline" and that no guard ships (§ "Backstop"). Two failures follow:

1. The main thread edits code directly, often for a "small" fix.
2. The main thread spawns `general-purpose` for build work, so the role's CAN and CANNOT boundaries do not apply.

Both fill the main context with file dumps. AgDR-0074 already records that the main thread dominates token spend. It names a thin orchestrator as a cost lever.

A gate is only as strong as the files that define it. Today an agent can change those files in-session (§ "Settings, hooks and pin tampering today"). So this record hardens them first.

### What the hooks read today

Three hooks read the caller fields from the hook input:

| Hook | Lines | What it reads | What it assumes |
|------|-------|---------------|-----------------|
| `.claude/hooks/block-reviewer-ci-wait.sh` | 17-26, 55-56, 64, 270-271 | `agent_type`, `agent_id` | No type and no id means the orchestrator. It keys a counter on `agent_id`, else on `agent_type`. |
| `.claude/hooks/_lib-review-markers.sh` | 258-297 | `agent_type` first, then `agent_id` | Lines 260-263: "sets neither agent_type nor agent_id on a main-thread call". Line 282 tests `agent_type` before `agent_id`. |
| `.claude/hooks/inject-project-context.sh` | 26-31, 47, 89 | `agent_id` only | An empty `agent_id` means "main" (line 89). A subagent has its own `agent_id` (line 30, "spike-confirmed"). |

`review_caller_class` returns `other-agent` for any typed caller (`_lib-review-markers.sh:282-285`). It returns `main` only when both fields are absent (line 296). It never asks whether a typed caller has an `agent_id`. It has six call sites in five hooks: `auto-code-review.sh:109`, `block-reviewer-ci-wait.sh:86`, `block-reviewer-repo-mutation.sh:263`, `require-active-ticket.sh:409` and `:881`, and `warn-review-marker-write.sh:745`.

### Evidence for "agent_id is absent on the main thread"

1. Captured payloads. `.claude/hooks/tests/fixtures/pretooluse-payloads/README.md:3-11` lists real inputs from 2026-10-11. `bash-main-thread.json:1-17` has no `agent_id` and no `agent_type`. `bash-code-reviewer.json:2-3` and `bash-general-purpose.json:2-3` have both. All three carry the same `session_id`.
2. Version. AgDR-0145 (amendment of 2026-10-11) records the capture on Claude Code 2.1.296. `docs/hooks-fail-closed.md:98-100` states that no earlier version was tested.
3. Vendor reference. The Claude Code hooks reference (read on 2026-10-19) describes `agent_id` as the "Unique identifier for the subagent or in-process teammate the hook fires in". It describes `agent_type` as "Present when the session uses `--agent` or the hook fires inside a subagent".

Limits of this evidence:

- The fixtures are Bash calls only. No fixture shows an `Edit`, `Write`, `MultiEdit` or `NotebookEdit` payload.
- No fixture shows a main thread started with `claude --agent <name>`. The vendor text says that this main thread carries `agent_type`. The text does not say that it carries no `agent_id`.
- The vendor text defines `agent_id` for subagents and teammates. It never says that the field is absent on the main thread. The absence is an observation on one build, not a contract.
- A hook cannot read the Claude Code version cheaply (`docs/hooks-fail-closed.md:105-107`). So the gate cannot refuse to run on an untested build.

So the claim is supported for Bash on 2.1.296 only. § D.1 adds a ledger so that a later change fails loud.

### What the harness offers

The hooks reference (read on 2026-10-19) states these facts:

- SubagentStart "Runs when Claude spawns a subagent with the Agent tool, when Claude resumes a subagent, and each time an in-process agent team teammate handles a new message." Its input has `agent_id` and `agent_type`. It cannot block.
- SessionStart has the sources `startup`, `resume`, `clear`, `compact` ("Auto or manual compaction") and `fork`. So SessionStart fires again inside one session without operator action.
- ConfigChange runs "when a settings file, a managed policy file, or a skill file changes". Its matchers are `user_settings`, `project_settings`, `local_settings`, `policy_settings` and `skills`. Its input has `source` and "optionally `file_path`".
- A ConfigChange block means "the new settings are not applied to the running session". `policy_settings` changes cannot be blocked. "A blocked change surfaces no message to you or to Claude".
- "a `"disableAllHooks": false` in a project's `.claude/settings.json` overrides a `true` in your user settings". `--settings '{"disableAllHooks": true}'` "takes precedence over project and local settings".
- `transcript_path` "is the main session's transcript, while `agent_transcript_path` is the subagent's own transcript" (SubagentStop input).

Hook output:

- "Claude never sees stderr from a hook that exits 0."
- On exit 0, Claude Code parses stdout as JSON "when the whole output is one JSON object with nothing around it but whitespace". For PreToolUse, other stdout goes to the debug log.
- `systemMessage` is a "Warning message shown to the user".
- PreToolUse `hookSpecificOutput.additionalContext` is a "String added to Claude's context alongside the tool result". `hookSpecificOutput` "requires a `hookEventName` field".
- PreToolUse `permissionDecision` `"allow"` "skips the permission prompt".
- On exit 2, "The message that comes with the block is your hook's stderr". Claude Code "still reads the JSON output fields, but they can't override the block".

The settings reference (read on 2026-10-19) gives this precedence, highest first: managed, command line, `.claude/settings.local.json`, `.claude/settings.json`, `~/.claude/settings.json`. `CLAUDE_CONFIG_DIR` moves the user settings file.

### Settings, hooks and pin tampering today

- Tracked `.claude/settings.json` sets only `$schema` and `hooks`. It does not set `disableAllHooks`. So a user-level `"disableAllHooks": true` wins today.
- `.claude/settings.json` has 16 hook entries. Every launcher reads the pin `${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-$CLAUDE_CODE_SESSION_ID`. It checks only `-d "$r/.claude/hooks"`. Then it runs `exec "$r/.claude/hooks/<gate>.sh"` (for example lines 9, 20 and 53).
- Each launcher ends `[ -d "$r/.claude/hooks" ] || exit 0`. So `mv <ops-root>/.claude/hooks /tmp/x` or `rm -rf .claude/hooks` turns off every hook, and every launcher exits 0.
- Only 3 of the 16 entries set `onFailure: block`. If a gate script loses its exec bit (`chmod -x`), `exec` fails. The other 13 entries then fail open.
- Both dispatchers run sub-hooks as `"$HOOK_DIR/$script"` (`dispatch-bash.sh:70, 73, 76, 107`, `dispatch-session-start.sh:27, 73`). `run_hook` treats exit 126 as a warning. So `chmod -x` on a sub-hook makes every `run_hook` gate fail open, including `block-main-push.sh`.
- The main thread's working directory persists between Bash calls. So a `cd .claude/hooks` in one call changes what a relative path means in the next call.
- `pin-ops-root.sh` runs `resolve_ops_root_walk "$PWD"` (line 73) and writes the pin on every SessionStart, with no check of the source (header line 37). So a `compact` or `clear` in a session whose `$PWD` moved to another tree with the tracked `.apexyard-fork` anchor re-pins the session to that tree. A linked worktree maps back to the main checkout through `_ops_root_main_worktree` (`_lib-ops-root.sh:82`). A standalone clone or a constructed tree does not.
- The write detector reports no write when a command runs a script. So `bash .claude/hooks/pin-ops-root.sh` re-pins the session in one call, and the detector sees nothing.
- The pin tree is outside every governed tree. The main thread can write it today. A pin to a directory with no-op scripts turns off every gate.
- An edit to a live hook script has the same effect as `disableAllHooks`. A main thread can do this today with `Edit` or `sed -i`.
- A settings `env` block can set `APEXYARD_OPS_PIN_DIR`, `PATH`, `BASH_ENV` or `BASH_FUNC_<name>%%`. The first redirects the pin. The second can put a fake `jq` first. The last two can override shell functions in hook processes. The Security Auditor found that bash 3.2 imports `BASH_FUNC_` functions from the environment.
- `docs/hooks-fail-closed.md:158` says "Do not set `disableAllHooks` in a tracked settings file". `.claude/hooks/tests/test_settings_fail_closed.sh:88-89` fails only when a tracked file sets it to `true`.
- Gate configuration lives in `.claude/project-config.json`. A build role can change it in-session.

### What already exists to reuse

- Write detection. `.claude/hooks/_lib-detect-bash-write.sh` has `bash_command_appears_to_write` (lines 851-894), `bash_command_is_deletion_only` (line 941), `bash_extract_write_targets` (line 1343) and `bash_command_has_unextractable_write` (lines 1416-1480). It covers redirects, `tee`, `sed -i`, `awk -i inplace`, movers (`cp`, `mv`, `rm`, `dd`, `install`), archives, interpreters and heredoc-fed interpreters (lines 83-136). It does not cover `git apply`, `patch`, `ln`, `chmod`, `rsync` or `truncate`.
- Shared detector consumers. Four production gates source `_lib-detect-bash-write.sh`: `require-active-ticket.sh`, `require-migration-ticket.sh`, `block-forged-menu-approval.sh` and `warn-review-marker-write.sh`.
- Scrubbed view. AgDR-0181 § Scope (`docs/agdr/AgDR-0181-fail-closed-bash-command-scrubbing.md:39-44`) allows exactly two consumers to read it: `_lib-detect-bash-write.sh` and `auto-code-review.sh`. Every other matcher reads the raw command (line 46).
- Scrub allowlist. AgDR-0181 line 56 lists the data-only command words. `git` is on it only for `log`, `show`, `diff`, `status`, `commit`, `add`, `rev-parse`, `branch`, `ls-files` and `blame` (line 60). `patch`, any shell and any interpreter are not on it.
- Heredoc stripping. `_lib-strip-heredoc.sh:27-40` and AgDR-0113 forbid the use of `strip_heredoc_bodies` as a subtractive gate filter.
- Ticket-first gate. `require-active-ticket.sh:1092-1159` runs the detector per target with AND semantics (#886). It exempts deletion-only commands (lines 1119-1123, #569). It treats an unextractable write as a block (lines 1131-1140). It fails closed on an unparsable payload (lines 1070-1083).
- Temp directories. `_ratc_in_temp_dir` (`require-active-ticket.sh:221-232`) accepts `/tmp`, `/var/tmp` and `$TMPDIR` by physical path. The scratchpad helpers in `_lib-active-ticket.sh` (lines 1537 and 1562) also accept `$CLAUDE_CODE_TMPDIR`.
- Scratchpad check. `active_ticket_in_session_scratchpad` (`_lib-active-ticket.sh:1624`) and AgDR-0231 validate a session scratchpad path.
- Ticket marker. `active_ticket_is_marker_target` (`_lib-active-ticket.sh:1060`) identifies the `/start-ticket` marker.
- Path resolution. `_resolve_real_path` (`_lib-path-resolve.sh:39`) follows directory links. It expands neither `~` nor a variable. A final-component link can stay unresolved (lines 30-32).
- Shared detector on `tar`. `bash_command_has_unextractable_write` reports every `tar -x` as unextractable (`_lib-detect-bash-write.sh:1424`).
- Fail-closed wiring. `dispatch-bash.sh:105` (`run_fail_closed_hook`) and `.claude/settings.json:16-26` (`onFailure: block`). The Bash dispatcher entry has a 20 s timeout (`.claude/settings.json:49-55`).
- Dispatcher stdout. `dispatch-bash.sh` does not capture any sub-hook's stdout (lines 70, 73, 76 and 107). Sub-hook stdout goes straight to the dispatcher's stdout.
- Alias resolution. The #1748 design adds `git_alias_check <verbs>` to `_lib-git-global.sh`. It is not merged at 23d8387.
- Process budget. `.claude/hooks/tests/test_active_ticket_process_budget.sh` is the model for a budget test.
- Skill preambles. 56 skill files source a library with `source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-*.sh"`. Examples: `setup/SKILL.md:20-21`, `handover/SKILL.md:29-30`, `update/SKILL.md:31-32`. `code-reviewer.md:546` sources hooks libraries with `.` in the same way.

### What the review agents already have

- `code-reviewer.md:6-7`, `security-reviewer.md:6-7` and `solution-architect.md:5-6` declare a `tools:` allowlist and `disallowedTools: Write, Edit`. The allowlist already excludes `MultiEdit` and `NotebookEdit`. The harness honors `tools:`.
- `block-reviewer-repo-mutation.sh` blocks repository-mutating git commands by a review agent (lines 1-6, 254-280). It does not block `sed -i`, `cat >` or other file writes.
- The real gap is `qa-engineer`. Its file uses `allowed-tools: Bash, Read, Grep, Glob` (`qa-engineer.md:5`). The harness ignores that key. The agent listing reports "All tools" for it.

### Day-one blast radius

34 skills list `Write` or `Edit` in `allowed-tools`. Most run on the main thread. Several write paths that are not orchestrator paths:

| Skill | Write target | Source |
|-------|--------------|--------|
| `/release` | `CHANGELOG.md` | `.claude/skills/release/SKILL.md:229-231` |
| `/roadmap` | `projects/<name>/roadmap.md` | `.claude/skills/roadmap/SKILL.md:257` |
| `/c4` | `docs/architecture/*.md` and `projects/<name>/architecture/*.md` | `.claude/skills/c4/SKILL.md:48-51` |
| `/codify-rule` | `handbooks/**` | `.claude/skills/codify-rule/SKILL.md:148-158` |
| `/idea`, `/update`, `/split-portfolio`, `/process`, `/orbit` | Named by the review. Targets not yet traced. | First review, B3 |

### Conflicts with earlier records

- AgDR-0050 § Axis 6 (`docs/agdr/AgDR-0050-agent-runtime-overhaul.md:124`) keeps in-flow-class roles in-thread. `.claude/rules/role-triggers.md:164` and `.claude/hooks/detect-role-trigger.sh:171-172, 205` tell the main thread to adopt Backend, Frontend and Platform Engineer in-thread. With this gate, an in-thread persona cannot write code.
- `roles/engineering/tech-lead.md:150` says "the operator drives implementation in-thread".
- AgDR-0181 § Scope allows two scrubbed-view consumers. This record adds a third, narrow one (D14, § B.6).

## Options Considered

### 1. How to detect the main thread

| Option | Pros | Cons |
|--------|------|------|
| A. `agent_id` absent means main thread | The harness sets the field. It stays correct in `--agent` mode. It matches `inject-project-context.sh:89`. | Proof is Bash-only on 2.1.296. A build that adds `agent_id` to the main thread makes the block fail open in silence. |
| B. `agent_type` absent means main thread | Matches `review_caller_class` (`_lib-review-markers.sh:282`). | In `claude --agent backend-engineer` mode the main thread has a build-role type and could write code. |
| C. Both fields absent means main thread | No new helper. | Same `--agent` hole as B. |
| D. Classify by `transcript_path` shape | Independent of the two fields. | The path layout is not a documented contract. |
| E. Option A plus a SubagentStart ledger (decided, D1) | A main thread never starts through the Agent tool, so it never enters the ledger. A future `agent_id` on the main thread fails loud as `unregistered`. | One more hook event. If the ledger write fails, every subagent edit blocks (loud). |

### 2. What the Bash backstop counts as a code-path write

| Option | Pros | Cons |
|--------|------|------|
| A. Reuse the write detector, then judge every target (decided, D2) | Reuses the tested detector (AgDR-0181). Same AND-per-target shape as the ticket gate (#886). | The detector misses `xargs`, `find -exec` and custom scripts (`_lib-detect-bash-write.sh:137-143`). |
| B. Deny every main-thread command except a read-only allow list | Catches unknown writers. | Blocks most real work, including the Codex and Cursor launch. |
| C. Block writes only to a glob list of source files | Few false positives. | Open by default. Misses config, infra and new languages. |
| D. Strip heredoc bodies, then match | Simple. | AgDR-0113 forbids it. |

#### 2b. Where the new matchers live

| Option | Pros | Cons |
|--------|------|------|
| Shared detector | One detector. | Changes four other gates. |
| Gate-local (decided, D7) | The four consumers keep their behaviour. One ticket per trust-chain PR. | Two places know about write families. |

#### 2c. Deletion-only commands

| Option | Pros | Cons |
|--------|------|------|
| Count `rm src/app.ts` as a code edit | Closes one more role gap. | Cleanup of scratch clones blocks. |
| Do not count it in the class rules (decided, D9) | Same rule as `require-active-ticket.sh:1119-1123`. | The main thread can delete a code file. The PR diff shows it. |

D9 applies to the class rules only. The protected-path rules judge deletion operands (§ B.3).

#### 2d. Which command view the gate-local git matchers read

| Option | Pros | Cons |
|--------|------|------|
| Scrubbed view with an amendment to AgDR-0181 § Scope (decided, D14) | Every matched verb is outside the data-only allowlist (AgDR-0181:56, 60). So the scrubber returns the raw command whenever one of them runs. Quoted mentions in `grep` and PR bodies stay data. | Widens a security record's scope. Needs the safety argument and a test. |
| Raw command | No change to AgDR-0181. | `grep -n 'git apply' file` and heredoc PR bodies false-block. |

The protected-token rule reads the raw command. It only adds blocks, so it needs no scrubbed view.

### 3. Which agent types are build roles

| Option | Pros | Cons |
|--------|------|------|
| A. Fixed list of 8, replaceable through config, review agents always refused (decided, D3) | Matches `.claude/rules/pr-workflow.md:231` and the build-class block in each agent file. | A custom build agent needs a config line. |
| B. Derive from agent frontmatter | No list. | The build-role files use the ignored `allowed-tools:` key. |
| C. Additive-only list | Config cannot remove a built-in. | Blocks narrowing, which is the safe direction. |

### 4. Fail-closed behaviour and the escape hatch

| Option | Pros | Cons |
|--------|------|------|
| A. `APEXYARD_ALLOW_MAIN_THREAD_EDITS=1` in the hook process environment, logged, never named in the block message (decided, D4) | Matches `block-onboarding-in-git.sh:54` and `require-skill-for-issue-create.sh:145`. It lifts one gate. | A settings `env` block could set it. § B.7 and § D.6 close that. |
| B. Global hatch only | Already documented and tested. | Turns off the merge gates too. |
| C. Marker file under `.claude/session/` | No restart. | The main thread can write its own pass. |
| D. Mode key in `.claude/project-config.json` | Persistent. | A policy switch, not a recovery hatch. |

#### 4b. Main-thread write access to `.claude/settings.local.json`

| Option | Pros | Cons |
|--------|------|------|
| Keep it with a key allowlist | Config skills keep working. | Local settings outrank the tracked file. The parser is new attack surface. |
| Protect it (decided, D6) | No content rule to get wrong. | Config skills that write it fail. |

### 5. Rollout

| Option | Pros | Cons |
|--------|------|------|
| A. Block both channels at once | Simple. | Text-gate false positives (AgDR-0109, #1066, #1760). 34 skills write files. |
| B. Warn first, block the edit channel after the skill inventory, block Bash one release later (decided, D5) | Real write targets in the log. Day one breaks no skill. | The main benefit waits one release. |
| C. Block the edit channel at once | Low false-positive risk on that channel. | Breaks several skills on day one. |
| D. Inventory first, then block | No known breakage. | Misses run-time targets. No real-use data. |

### 6. How the gate reads its own configuration

| Option | Pros | Cons |
|--------|------|------|
| Read the gate keys from the session snapshot (decided, D19) | A mid-session change to `.claude/project-config.json` cannot weaken the running session. Build roles keep normal write access to the file. | A config change applies at the next session start. Rollback needs a relaunch. |
| Protect the live config files | Changes cannot happen in-session at all. | Every config edit needs an isolated worktree or the operator. Adopter config work gets harder. |

### 7. When to close the launcher `exit 0`

| Option | Pros | Cons |
|--------|------|------|
| In the pin-check ticket, sequenced right after D17 (decided, D18) | D17 already blocks `mv`, `rm`, `ln` and `chmod` on protected ancestors in-session. The launcher change touches all 16 entries and is its own trust-chain change. | Between the two merges, a write that hides its operands can still remove the hooks directory. |
| Inside the D17 ticket | One merge closes the whole bypass. | A larger trust-chain PR. It mixes launcher logic with the protected-path gate. |

## Decision

### Summary

| # | Sub-decision | Decided or open |
|---|--------------|-----------------|
| 1 | Main-thread detection | Decided (D1): option 1E |
| 2 | Bash code-path rule | Decided (D2, D7, D9, D14): option 2A, gate-local matchers, deletion-only not counted by the class rules, scrubbed view under an AgDR-0181 amendment |
| 3 | Build roles | Decided (D3): option 3A |
| 4 | Fail closed and hatch | Decided (D4, D6, D13, D15, D16, D17): hatch 4A, a protected set for live settings, live hooks and the pin tree, a token rule, a ConfigChange hook without restore, all landed first |
| 5 | Rollout | Decided (D5): option 5B |
| 6 | Gate configuration source | Decided (D19): the session snapshot |
| 7 | Launcher `exit 0` | Decided (D18): the pin-check ticket, right after D17 |

### Ticket order

1. Sibling ticket (§ A). It files this AgDR (D12).
2. The #1748 build ticket, for `git_alias_check` (D21). The D17 ticket is blocked by it.
3. D17 tamper-hardening ticket, #1806 (§ B).
4. Launcher pin-check ticket (§ C), right after D17 (D18).
5. #1762 gate (§ D). #1762 is blocked by tickets 1, 3 and 4.
6. Skill inventory ticket, then the two flip tickets (§ D.8).

### A. Sibling ticket: spawn in-flow roles for code edits

Scope:

1. `.claude/rules/role-triggers.md:164` and `.claude/hooks/detect-role-trigger.sh:171-172, 205`: in-flow-class roles are spawned for code edits, not adopted in-thread.
2. `roles/engineering/tech-lead.md:150`: remove "the operator drives implementation in-thread".
3. An amendment note on AgDR-0050 § Axis 6 that points to this record.
4. This AgDR file, with its number.

This ticket touches a production hook, so it carries one ticket only (`right-size-ceremony.md:37, 40-42`).

### B. D17 ticket: harden settings and hooks against in-session tampering

This ticket cites this record. It ships one new hook script, `.claude/hooks/block-protected-target-writes.sh`, on both channels. It does not need caller classes or the ledger. It blocks for every caller in every session. It has no mode key and no hatch. The operator recovery path is `--settings '{"disableAllHooks": true}'`.

This ticket is blocked by the #1748 build ticket (PR #1804) (D21). It uses `git_alias_check` from that build (§ B.6).

#### B.1 Live roots and the session snapshot

Snapshot sources:

- A SessionStart with source `startup`, `resume` or `fork` writes the session snapshot into `<pin tree>/gate-session-<session_id>/`. These sources start a process that loads settings from disk.
- Write-once: the step writes nothing when a snapshot already exists for that `session_id`.
- A SessionStart with source `compact` or `clear` never writes the snapshot. Compaction runs without operator action. Under D16 a blocked settings file stays on disk. So a `compact` or `clear` snapshot could take a tampered file as its baseline.
- A session with no snapshot stays in no-snapshot mode for its whole life (see the end of this section).

Pin (Security Auditor S1):

- Change `pin-ops-root.sh` to write the pin only on `startup`, `resume` or `fork`, and only when no pin exists for that `session_id`. It never writes on `compact` or `clear`.
- The snapshot records the pinned ops root (item 5 below).
- § B and the § C launcher compare the pin with the snapshot record on each run. A mismatch blocks: § B exits 2, and the launcher exits 2.
- A session with no snapshot keeps the pin behaviour of today, because there is no record to compare with.

Build amendment (#1806, captures P12b of 2026-10-19):

- `clear` issues a new `session_id`. `compact` keeps it. So a `clear` session starts with no pin and no snapshot.
- A Bash `cd` inside the project persists into the hook-process `$PWD`. `CLAUDE_PROJECT_DIR` stays at the launch directory in every hook call.
- With no pin, every launcher walks up from `$PWD` on each call. A `cd` into a constructed fork tree inside the project could then select hooks that do nothing.
- So `pin-ops-root.sh` also writes the pin on `clear` when no pin exists for the new `session_id`. It resolves from `CLAUDE_PROJECT_DIR`, never from `$PWD`. It writes no pin when `CLAUDE_PROJECT_DIR` is not set.
- `clear` still writes no snapshot (D16). The `clear` session stays in no-snapshot mode.

Build amendment (#1806, review of the first code PR):

- The gate compares every protected form without regard to case, because the default macOS volume ignores letter case. This covers paths, live roots, tokens, the unresolved-operand list, harness-only writer names and the sandbox pin tree. The `pt_nocase` helper sets `nocasematch` only for these tests. Option and verb tests stay case-sensitive, so `-c` is not `-C`. On a case-sensitive volume the change only adds blocks.
- The tokenizer joins the combined append forms (`&>>`, `>>&`) and the zsh clobber suffix forms (`>!`, `>>|`, `&>!`, `>&!` and the related forms) into one operator. Each one is a redirect slot.
- A trailing `!` has two readings. Zsh reads it as the clobber suffix, so the next word is the target. Bash and sh read it as the first character of the target word, or as a file named `!` when a space follows. The gate cannot know which shell runs the text. So for an operator that ends in `!`, it judges the next word, the next word with a leading `!`, and the file `!`.
- `.claude/worktrees/` is not a sensitive directory. A command that runs in an isolated worktree is not in token context for that reason alone. A live path that the command names is still judged. A `find -exec` with a read-only verb does not judge the find roots. A mutating or unknown verb still does.
- The `-f` flag takes a value only for `tar`. For `rm`, `cp` and `mv` the operand after it is judged.

Order inside `dispatch-session-start.sh`:

1. `run_direct pin-ops-root.sh` (line 57, unchanged).
2. `run_direct write-session-snapshot.sh`, alone, before the concurrent batch.
3. The concurrent batch (lines 37-54), which includes `write-rule-excludes.sh`. That hook rewrites `.claude/settings.local.json` on each start. The snapshot must exist before that write, so ConfigChange finds a record.

The snapshot records:

1. The resolved, physical `CLAUDE_PROJECT_DIR` at session start.
2. For each settings source (`user_settings`, `project_settings`, `local_settings`): the resolved path, a hash of `jq -S -c '.hooks // null'`, and a hash of `jq -S -c '.env // null'`. An absent file counts as `{}`. So "absent file", "no `hooks` key" and "no `env` key" are explicit values, not missing records.
3. The `disableAllHooks` value of each source.
4. The gate keys from `.claude/project-config.json`, for § D.5 (D19).
5. The resolved, physical ops root that the pin holds at snapshot time.

On a `resume` SessionStart with an existing snapshot, the snapshot step compares the on-disk hashes with the snapshot. It also checks `config-change-blocks.jsonl` for entries. If either shows a change, it prints a plain-text warning to stdout. For SessionStart, Claude Code adds plain-text stdout to Claude's context. The SessionStart dispatcher does not emit one JSON object today, so the step does not use `systemMessage`.

Live roots:

- The live roots are the resolved pinned ops root and the snapshot project directory. Compare each target as an exact path (§ B.3, "Path forms").
- A session started in a worktree has that worktree as its snapshot project directory. That worktree is then live.
- A worktree subagent does not make its worktree live, even if its hook process sees another `CLAUDE_PROJECT_DIR`. The snapshot, not the per-call environment, defines the live roots. Capture P12 checks this (§ B.10).

No-snapshot mode (a session that started before this ticket merged, or a `clear` that issues a new `session_id`):

- Live roots are the pinned ops root and the current `CLAUDE_PROJECT_DIR`. With neither, every `*/.claude/settings*.json` and `*/.claude/hooks*` is live.
- ConfigChange uses the narrower no-snapshot rules in § B.7.
- The #1762 gate uses its built-in config defaults (§ D.5).

#### B.2 Protected paths

1. Each live settings file: `.claude/settings.json` and `.claude/settings.local.json` directly under each live root.
2. Each live hook script: every file under `<live root>/.claude/hooks/` (D13). This covers this ticket's own script, the dispatchers and every library they source.
3. Both user settings files: `$CLAUDE_CONFIG_DIR/settings.json` when the variable is set, and `~/.claude/settings.json` always.
4. The hook state in the pin tree: `ops-root-*`, `gate-session-*/**`, `resolve-cache-*` and `projctx/**`. Hooks trust these files. Other files in the pin tree, such as `activity-sync.log` from the operator's sync job, are not protected. No shipped skill or agent writes into the pin tree (checked at 23d8387).
5. Files that the Bash tool sources and that can change its environment without command text: `~/.claude/session-env/**`, `~/.claude/shell-snapshots/**`, the same two directories under `$CLAUDE_CONFIG_DIR` when set, and the file that `$CLAUDE_ENV_FILE` names when set. This carries follow-up item 5 of the #1748 record (CEO decision 12, residual R5). The harness writes these files itself, not through a tool call, so this rule does not stop them.

Protected ancestors: `<live root>/.claude/hooks`, `<live root>/.claude`, each live root, the pin tree directory, `~/.claude`, `$CLAUDE_CONFIG_DIR`, and every directory above them. § B.3 says which operand roles they apply to.

Pin-tree cleanup: the pin tree holds about 6,200 old pins on a long-used machine (Security Auditor A2). `pin-ops-root.sh` deletes `ops-root-*` and `resolve-cache-*` files older than 30 days, with `find -P -maxdepth 1`. The main thread cannot delete them, because they are protected.

The protected set does not cover the rest of `~/.claude` or `$CLAUDE_CONFIG_DIR`. The auto-memory directory is there and is an orchestrator path.

SessionStart hooks do not pass PreToolUse. So `pin-ops-root.sh`, `write-rule-excludes.sh`, `apply-agent-routing.sh` and the snapshot step keep working.

#### B.3 Edit channel and Bash operands

Path forms (both channels):

- Collapse `//` and `/./` in each path.
- Judge two forms of each path: the lexical form after `..` is resolved as text, and the physical form after `_lib-path-resolve.sh` and one follow of a final-component symlink.
- Block when either form is a protected path, or a protected ancestor where the operand role in the table below requires it.
- v4 said that "a symlink or a `..` segment keeps the gate closed". That rule would block every edit under `/tmp` and `/var/folders`, where macOS temp paths are links. v5 replaces it.

Edit channel:

- Add a PreToolUse entry for `Edit|Write|MultiEdit|NotebookEdit`, with `timeout` 10 and `onFailure` `block`.
- Read the target from `tool_input.file_path`, then `tool_input.notebook_path`. Resolve a relative target against the payload `cwd`.
- Block when the target is a protected path.
- Label this entry point `CLASS: CONTROL`.

Bash channel:

- Register the script in `dispatch-bash.sh` with `run_fail_closed_hook`. Label it `CLASS: BACKSTOP`.
- Use the detector's extracted targets. Also run a gate-local operand matcher for these verbs:
  - Copy, move and link: `cp`, `mv`, `install`, `dd`, `ln`, `link`, `git mv`, `rsync`, `ditto`.
  - Remove: `rm`, `rmdir`, `unlink`, `shred`, `git rm`.
  - Mode, owner and attributes: `chmod`, `chown`, `chgrp`, `chflags`, `chattr`, `xattr` (write, delete and clear forms), `setfacl`.
  - Create and truncate: `touch`, `mkdir`, `truncate`.
  - Archives: `tar`, `unzip`, `cpio -i`, `pax -r`.
  - In-place editors: `perl -i` (and `-pi`), `ruby -i`, `gsed -i`, `ed`, `ex`, `vi -c` and `vim -c`, `sponge`.
  - Decode and convert tools that write a file: `base64` with `-o` or `--output`, `openssl` with `-out`, `iconv -o`, `plutil -o` or in-place `plutil -convert`, `uudecode -o`, and `gzip`, `gunzip`, `bzip2`, `bunzip2`, `xz` and `unxz` on a file operand (they replace the file in place).
- The operand matcher also finds these verbs after a prefix: `find ... -exec`, `-execdir`, `-ok` and `-okdir`, and `xargs`, `env`, `command`, `exec`, `sudo`, `nice`, `nohup` and `time`.
- `{}` and `xargs` input are unextractable operands. With a protected token, condition 1(2) of § B.4 then blocks. Example: `find .claude/hooks -name 'block-*' -exec chmod -x {} +` blocks.

Operand roles:

| Role | Commands and operands | Judged against |
|------|----------------------|----------------|
| Remove, rename source, mode, owner, attribute, link name | `rm`, `rmdir`, `unlink`, `shred` and `git rm` operands, `mv` and `git mv` sources, `chmod`, `chown`, `chgrp`, `chflags`, `chattr`, `xattr` and `setfacl` operands, the link name of `ln` and `link`. Also any source of `rsync --remove-source-files` and any input of `tar --remove-files`. | Protected paths and protected ancestors |
| Single-file write destination | `cp`, `mv`, `install` and `git mv` destination, the value of `-t` or `--target-directory=` for `cp`, `mv`, `install` and `ln` (judged as `<dir>/<basename>` for each source), `install -D` destination, `dd of=`, `truncate`, `touch` and `mkdir` operands, in-place editor operands, decode-tool output values, compressor file operands, redirect and `tee` targets, `patch` file and `-o` (§ B.5). A single-file copy into a directory is judged as `<dir>/<basename>`. | Protected paths only |
| Recursive write destination | `cp -R`, `cp -r` and `cp -a` destination (also as a `-t` value), `rsync` destination (also with `--delete`), `ditto` destination, `unzip -d`, `tar -x -C`, `cpio -i` and `pax -r` in the effective directory | Protected paths and protected ancestors |
| Read-only source | `cp`, `rsync` and `ditto` sources (without a source-removing option), `dd if=`, `tar -c` inputs and `-C` in create mode (without `--remove-files`), the target of `ln`, `git archive` pathspecs | Not judged |

The operand role depends on the options. A source-removing or source-modifying option moves the source to the remove role. An option value that names a destination is judged as a destination. The shared detector can report the source as the target for an option-form destination such as `cp -t <dir> <src>`. This gate parses the options itself.

Examples:

- `mv <ops-root>/.claude/hooks /tmp/x` and `rm -rf .claude` block.
- `cp .claude/settings.json /tmp/bak`, `dd if=.claude/settings.json of=/tmp/x`, `tar -C .claude -cf /tmp/h.tar hooks` and `ln -s <live>/.claude/hooks/x.sh /tmp/l` pass.
- `rsync -a <live>/ <scratch>/` passes when the scratch destination is not protected. `rsync -a --remove-source-files <live>/.claude/hooks/ /tmp/x/` blocks.
- `cp -t .claude/hooks x.sh`, `install -t .claude/hooks x.sh`, `install -D x.sh .claude/hooks/x.sh` and `dd if=/tmp/x of=.claude/settings.json` block (Security Auditor A5).
- `cp -R /tmp/tpl/* .` passes outside a live root. It blocks in a live root, because the live root is a protected ancestor and the copy can overwrite live hooks.

Archive extract:

- A `tar -x` with exactly one literal `-C <dir>` and no absolute-name flag (`-P`, `--absolute-names`) is a recursive write to `<dir>`. Judge `<dir>`. It is not unextractable for this gate, although the shared detector reports every `tar -x` as unextractable (`_lib-detect-bash-write.sh:1424`).
- So `git archive <ref> .claude/hooks | tar -x -C <literal scratch>` passes. Reviewers use this form (`code-reviewer.md:80`, `security-reviewer.md:62`).
- Any other `tar -x` stays unextractable, and § B.4 applies.

Variable and home expansion (N1):

1. Before judging an operand, expand a leading `~`, `$HOME`, `$CLAUDE_PROJECT_DIR`, `$CLAUDE_CONFIG_DIR`, `$CLAUDE_CODE_SESSION_ID`, `$APEXYARD_OPS_PIN_DIR` and `${APEXYARD_OPS_PIN_DIR:-<default>}`, in plain and braced forms. Use the hook process values.
2. Also expand a variable that a literal assignment (`NAME=value` or `export NAME=value`) earlier in the same command sets. A literal value holds no `$(`, backtick or unresolved expansion, other than the names in item 1.
3. Then judge the expanded operand by its role.
4. If an expansion stays unresolved, block when one of these holds:
   1. The literal text after the last unresolved expansion names a protected component: `.claude/settings.json`, `.claude/settings.local.json`, a basename `settings.json` or `settings.local.json`, `.claude/hooks`, `.claude/apexyard`, `ops-root-`, `gate-session-`, `session-env/` or `shell-snapshots/`.
   2. The operand role uses protected ancestors, and the literal tail ends in `/.claude` or `/.claude/hooks`.
   3. The operand is a bare variable, and its same-command assignment names a protected token.
5. An unresolved variable with any other tail does not block. Do not make every variable operand unextractable. 50 shipped blocks in 36 skill and agent files write through a variable next to a protected token. Examples: 12 skills write `$ops_root/.claude/session/active-issue-skill`, and `code-reviewer.md:525-568` writes `cat > "$REVIEW_BODY_FILE"` beside `PIN_FILE`.

Examples that block: `p=.claude/hooks/x.sh; echo evil > "$p"`, `echo x > ~/.claude/apexyard/ops-root-abc`, `echo x > $HOME/.claude/settings.json`, and `echo /tmp/decoy > "${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-$CLAUDE_CODE_SESSION_ID"`.

Effective directory (N2):

- The main thread's working directory persists between Bash calls. The payload `cwd` holds it.
- Resolve every relative operand against the effective directory. Use the § B.5 resolver: the payload `cwd`, then each literal `cd`, `pushd` and `popd` in order.
- A subshell `( cd <dir>; ... )` changes the directory only inside the parentheses.
- For `bash -c '<literal>'` and `sh -c '<literal>'`, run the same checks on the literal string, with the current effective directory.
- A directory change that the resolver cannot follow (`cd "$X"`, `cd -`, `cd $(...)`) sets the effective directory to the live root.

#### B.4 Protected-token rule

- Condition 1: one of these holds:
  1. The write detector reports a write, and at least one target is unextractable. Interpreter writes such as `python3 -c`, `node -e` and heredoc-fed interpreters fall in this case.
  2. The operand matcher in § B.3 fires, and an operand is unextractable.
  3. Closing rule (Security Auditor S3): a simple command has an operand that resolves, after § B.3 expansion and directory resolution, to a protected path or a protected ancestor. Its command word is not in the § B.3 operand matcher, and it is not on the read-only allowlist below. A script runner whose script operand is that path is also exempt (see "Script runners").
- Read-only allowlist for the closing rule: `cat`, `grep`, `rg`, `jq`, `ls`, `diff`, `cmp`, `head`, `tail`, `wc`, `stat`, `file`, `readlink`, `realpath`, `shasum`, `sha256sum`, `test`, `[`, and `git log`, `git show`, `git diff`, `git blame`, `git ls-files` and `git status`. `source` and `.` are handled by the sourced-library rule.
- Script runners: `bash <path>`, `sh <path>` and `zsh <path>` with no `-c` run a script. They do not count under the closing rule, except for the harness-only state writers below.
- Condition 2: one of these holds:
  1. The raw command contains a protected token.
  2. The effective directory (§ B.3) is inside `<live root>/.claude`, the pin tree, `~/.claude` or `$CLAUDE_CONFIG_DIR`. So `cd .claude/hooks` in one call, then `python3 -c "open('dispatch-bash.sh','w')"` in the next, blocks.
- When both conditions hold, block.
- Protected tokens: `.claude/settings.local.json`, `.claude/settings.json`, `.claude/hooks` (no trailing slash, D15), the resolved pin-tree path, `.claude/apexyard`, `APEXYARD_OPS_PIN_DIR`, `ops-root-`, `gate-session-`, `CLAUDE_CONFIG_DIR`, the resolved `$CLAUDE_CONFIG_DIR` path, `CLAUDE_ENV_FILE`, `session-env/` and `shell-snapshots/`.
- Before the token search, collapse `//` and `/./` in the command text.
- Sourced libraries: a token does not count when it is inside the first operand of a `source` or `.` command. Skill preambles always name `.claude/hooks/_lib-*.sh` this way. Every other token in the command still counts.
- The rule reads the raw command. It only adds blocks (AgDR-0113). The `source` exclusion removes one named occurrence only.
- The block message tells a build role to use the `Edit` tool for a non-live file. The edit channel judges the exact path.
- Residual: a path built at run time, for example `os.path.join('.claude','hooks','x.sh')`, string joins or `base64`, contains no token. It is caught only when the effective directory is protected.

Harness-only state writers (Security Auditor S2):

- These scripts write state that the hooks trust: `pin-ops-root.sh`, `write-session-snapshot.sh`, `record-subagent-start.sh` (§ D.1) and `dispatch-session-start.sh`. Only the harness may run them, through SessionStart or SubagentStart.
- Block a Bash call whose raw command names one of these four file names as a word, for every class in every mode. This is a fixed-name match. It is additive and needs no path resolution.
- Exception: the same command sets `APEXYARD_OPS_PIN_DIR` to a literal path that is not in the protected set, as hook tests do. The script then writes into that sandbox.
- The location of the named script does not matter. A worktree copy writes the same live pin tree.
- Write-once (§ B.1 and § D.1) is the second layer.
- `bash .claude/hooks/write-rule-excludes.sh` still passes (§ D.9 item 11). It is not on the list. ConfigChange limits what it can change to `claudeMdExcludes`.
- Residual: a custom script that calls one of these writers by a computed name.

#### B.5 Git and patch commands on protected paths

This section holds the protected half of the git and patch matchers. § D.3 holds the code-path half.

Work-tree resolution (shared with § B.3):

1. Start at the payload `cwd`.
2. Apply each literal `cd`, `pushd` and `popd` earlier in the same command, with the subshell and `bash -c` rules of § B.3.
3. Apply each `-C <dir>` in order. Apply `--work-tree=<dir>`, `--git-dir=<dir>`, and `GIT_WORK_TREE=` or `GIT_DIR=` in a prefix or an `export`.
4. If any of these values is not literal after § B.3 expansion, treat the work tree as a live root.
5. Find the enclosing work tree by a walk up for `.git`. Resolve each pathspec relative to the effective directory.

Pathspec commands:

- Match `git checkout` and `git restore` with and without `--`.
- First consume option values: `-b`, `-B`, `--orphan`, `-t`, `--track`, `--conflict=`, `-s` and `--source`. Then choose pathspecs.
- `git restore`: every remaining non-option operand is a pathspec.
- `git checkout`: every remaining non-option operand after the first is a pathspec. The first is a pathspec when it names an existing path in the work tree. `-p`, `--patch`, `--theirs`, `--ours` and `-m` with paths count too.
- These pathspecs cover protected paths and fail closed: `.`, any directory that is a protected ancestor, any magic pathspec (starts with `:`, such as `:/` or `:(top)`), any glob (`*`, `?`, `[`), and `--pathspec-from-file` or `--pathspec-file-nul`.
- Block when a pathspec covers a protected path in a live root, for every class.
- Also block `git checkout-index` and `git read-tree -u` (and `--reset -u`) when the work tree is a live root, for every class. With `git update-index --cacheinfo`, these write any blob over a live hook.
- `git checkout <branch>` with no pathspec is out of scope (§ Risks).

Patch commands:

- Match `git apply` (except `--check` and `--stat`), `git am`, and `patch` (except `--dry-run`).
- Block when the effective work tree is a live root, for every class. For `patch`, the effective directory includes `-d <dir>`.
- `patch` file operands: judge the positional file to patch and `-o` or `--output` as single-file write destinations. So `cd /tmp && patch <live>/.claude/hooks/dispatch-bash.sh x.diff` blocks.
- `patch` input: when the input is a literal readable file (`-i <file>`, a positional patch file, or `< <file>`), read its `---` and `+++` headers. Block when a header names an absolute path, or a `..` path, that resolves to a protected path. When the input is not a literal file and the raw command names a protected token, block. When the input is not a literal file, names no token, and the effective directory is not a live root, the header paths are a residual.
- `git apply --directory=<dir>`: prefix each patch path with `<dir>` inside the work tree. The live-root rule above covers it.
- `git apply --unsafe-paths`: block for every class. Its targets can sit outside the work tree, and the gate cannot see them.
- macOS `patch -p0` with absolute or `..` header paths is a capture in the D17 merge requirements (§ B.14). GNU patch rejects such paths by default. Keep the header rule above until the capture shows the macOS behaviour.

Aliases (D21):

- Call `git_alias_check checkout restore apply am checkout-index read-tree` from the #1748 build.
- Block an alias that resolves to one of these verbs when the effective work tree is a live root. The message says "run the real verb", as #1748 does.

#### B.6 AgDR-0181 § Scope amendment (D14)

- The D17 PR adds an amendment note to `docs/agdr/AgDR-0181-fail-closed-bash-command-scrubbing.md` § Scope.
- The note adds a third consumer: the git and patch matchers in `block-protected-target-writes.sh` (§ B.5) and in `require-subagent-for-code-edits.sh` (§ D.3). They may read the scrubbed view for these verbs only.
- Safety argument: `git checkout`, `git restore`, `git apply`, `git am`, `git checkout-index`, `git read-tree` and `patch` are outside the data-only allowlist (AgDR-0181:56, 60). So the scrubber returns the raw command whenever one of them runs. Quoted mentions stay data.
- Test: for each matched verb, `scrub_bash_command` returns the input unchanged.

#### B.7 ConfigChange hook

- Add `.claude/hooks/block-hook-disabling-config-change.sh` on ConfigChange, with matchers `user_settings`, `project_settings` and `local_settings`.
- Resolve the changed file from `file_path`. If `file_path` is absent, resolve it from `source`:
  - `user_settings`: `$CLAUDE_CONFIG_DIR/settings.json` when set, else `~/.claude/settings.json`.
  - `project_settings`: `<snapshot project dir>/.claude/settings.json`.
  - `local_settings`: `<snapshot project dir>/.claude/settings.local.json`.
  - Block when the source cannot be resolved.
- When `file_path` names a file that is not a live settings file or a user settings file, allow the change and log it. The session does not load that file. Capture P12c checks what the harness sends for a worktree settings edit.
  - Build amendment (#1806, capture P12c of 2026-10-19): a worktree subagent added an `env` key to its worktree `.claude/settings.json`, and no ConfigChange fired. Capture P12 showed that a worktree subagent runs the hooks of the main session.
  - Defence in depth: for a file that is not live, block in three cases. The file sets `disableAllHooks` to `true`. The file does not parse. The file changes `hooks` or `env` against the committed copy in its own work tree. A file that is not committed has `{}` as its baseline. Allow and log every other change.
- Parse the file with `jq`. Treat an absent file as `{}`. Block when the parse fails.
- Block when the snapshot record for that source is unreadable, or missing in a session that has a snapshot.
- No-snapshot mode (Security Auditor A1):
  - `project_settings`: compare `hooks` and `env` with `git show HEAD:.claude/settings.json` from the live root. Block a difference.
  - `local_settings` and `user_settings`: block when the file has a non-empty `hooks` or `env` value.
  - All sources: block `disableAllHooks: true`.
  - Allow every other change. So a "don't ask again" permission write still works after `/clear`.
- Block when the file sets `disableAllHooks` to `true`.
- Block when the hash of `jq -S -c '.hooks // null'` differs from the snapshot.
- Block when the hash of `jq -S -c '.env // null'` differs from the snapshot. This covers `APEXYARD_ALLOW_*`, `APEXYARD_OPS_PIN_DIR`, `PATH`, `BASH_ENV`, `CLAUDE_ENV_FILE` and `BASH_FUNC_<name>%%`.
- Allow any other change, such as permissions, `claudeMdExcludes` or `enabledPlugins`.
- Append one JSON line to `<ops-root>/.claude/session/config-change-blocks.jsonl` for each block. A blocked change shows no message, so the log is the only evidence.
  - Build amendment (#1806): when the session has no pin, write the line under the snapshot project directory, or else under `CLAUDE_PROJECT_DIR`.
- No restore from the snapshot (D16). The blocked file stays on disk.
- Limit: the block applies to the running session only. The next session, a `resume` or a `fork` reads the changed file at startup.
- Limit: `policy_settings` changes cannot be blocked.

#### B.8 Tracked settings

- Add `"disableAllHooks": false` to tracked `.claude/settings.json`. It overrides a `true` in user settings.
- `--settings '{"disableAllHooks": true}'` still works. `bin/check-escape-hatch.sh` must still pass.
- Local settings outrank the tracked file. The protected set covers that file.
- Change `docs/hooks-fail-closed.md:158` to "Do not set `disableAllHooks` to `true` in a tracked settings file".

#### B.9 Fail-closed rules

- No `jq`, or an unparsable payload: block an edit-channel call. Block a Bash call when the raw text looks like a write or names a protected token. Use `raw_payload_tool_matches` and `raw_payload_command_matches` (`_lib-fail-closed-json.sh:6, 11`). The raw pattern matches inside words, such as `sed` in `used`. So with no `jq` it also blocks some read-only commands. This is the safe direction, because `jq` is a hard dependency (AgDR-0038).
- A missing `_lib-detect-bash-write.sh` blocks a Bash call that names a protected token.
- A missing `_lib-git-global.sh` blocks a git command whose work tree is a live root.
- A crash or timeout blocks through `onFailure: block` and `run_fail_closed_hook`.
- Blocks exit 2 with the reason on stderr. This script emits no JSON.

#### B.10 Merge requirement: captures P12

Before the D17 PR merges, capture these payloads and commit sanitised fixtures:

| # | Session | Event and tool | Record |
|---|---------|----------------|--------|
| P12 | Subagent spawned with `isolation: worktree` | PreToolUse `Edit` | The hook-process `CLAUDE_PROJECT_DIR`, the payload `cwd` and the worktree location |
| P12b | Same session: a Bash `cd` to another directory, then `/compact`, then `/clear` | SessionStart | `source`, `session_id` and the hook-process `$PWD` for each. The pin before and after. |
| P12c | Same worktree subagent edits the worktree's `.claude/settings.json` | ConfigChange, if any | Whether it fires, and its `source` and `file_path` |

Pass criteria:

- P12: the snapshot project directory is the session's start directory. The worktree is not a live root. A hook edit in the worktree passes this ticket's checks.
- If the harness sets `CLAUDE_PROJECT_DIR` to the worktree in the hook process, record it. The snapshot rule in § B.1 keeps D13 correct.
- P12b: neither `compact` nor `clear` rewrites the snapshot or the pin, even when the hook-process `$PWD` has moved. Record whether `clear` issues a new `session_id`. If it does, the session continues in no-snapshot mode. Document that limit.
- P12c: if ConfigChange fires with the worktree `file_path`, the hook allows it (§ B.7). If it fires with no `file_path`, the hook compares the live file, which did not change, and allows it.

#### B.11 Consequences of this ticket

- From the merge, these changes block for every caller:
  - An edit-channel write to a protected path.
  - A Bash write, removal, rename, link, permission or ownership change whose operand hits a protected path. Operands are judged after expansion and directory resolution. Protected ancestors count for the roles in § B.3.
  - An interpreter or other unextractable write that names a protected token or runs in a protected directory.
- A write that hides the path fully still passes (§ Risks).
- A build role cannot edit live hooks or live settings (D13). Framework hook and settings work runs only in an isolated worktree.
- Hook work that is in progress in the live root breaks. Move it into an isolated worktree before the merge.
- `/update` merges upstream in the live root. A conflict in `.claude/hooks/*.sh` or `.claude/settings.json` cannot be resolved in-session. Route: run `/update` and hook work in an isolated worktree, merge there, then run `git pull` in the live root.
- A mid-session `git pull` or `/update` that changes `hooks` in tracked settings makes ConfigChange block that change in silence. The new hooks apply at the next session start.
- A session in no-snapshot mode has every settings change blocked. A `write-rule-excludes.sh` rewrite in that mode is blocked too, so a changed `claudeMdExcludes` applies at the next start. Restart sessions after the merge.
- `git apply`, `git am`, `patch`, `git checkout-index` and `git read-tree -u` block in a live root for every caller. `git restore .` and `git checkout .` in a live root block too.
- `cp -R <src>/* .` in a live root blocks.
- Running `pin-ops-root.sh`, `write-session-snapshot.sh`, `record-subagent-start.sh` or `dispatch-session-start.sh` through a tool call blocks, unless the command sets a sandbox `APEXYARD_OPS_PIN_DIR`.
- A command that names a live protected path and runs a verb outside the operand matcher and the read-only allowlist blocks. An unusual read tool may false-block. Add it to the allowlist with a test.
- The pin is written once per session. A session started outside the fork stays unpinned until the next start.
- `.claude/settings.local.json` is no longer writable through a tool call. The operator uses `/permissions` or edits the file outside the session.
- The tracked settings file now sets `disableAllHooks` to `false`. An adopter who turned hooks off in user settings gets them back.

#### B.12 Tests for this ticket

Write `.claude/hooks/tests/test_block_protected_target_writes.sh`. Run every case for class `main`, a `platform-engineer` subagent and a `code-reviewer` subagent.

1. Edit channel: `Edit`, `Write`, `MultiEdit` and `NotebookEdit` on each protected path in § B.2 block. This includes a `\u`-escaped key and a split-key `Edit` on `settings.local.json`.
2. Live hooks: an `Edit` and a `sed -i` on `<ops-root>/.claude/hooks/require-active-ticket.sh` block. The same `platform-engineer` `Edit` in an isolated worktree, which is not a live root, passes.
3. Worktree session: with a snapshot project directory that is a worktree, an `Edit` on that worktree's `.claude/hooks/x.sh` and `.claude/settings.json` blocks.
4. User settings and harness env files: `$CLAUDE_CONFIG_DIR/settings.json`, `~/.claude/settings.json`, a file under `~/.claude/session-env/`, a file under `~/.claude/shell-snapshots/` and the `$CLAUDE_ENV_FILE` file all block.
5. Pin tree: a write to an `ops-root-` pin and to a `gate-session-` file blocks.
6. Path forms: an `Edit` under `/tmp` and under `/var/folders/...` passes. A symlink under `/tmp` whose target is a live hook blocks. A `..` path that resolves to a live hook blocks. `.claude//hooks/x.sh` and `.claude/./hooks/x.sh` block.
7. Operand roles, blocking: `mv <ops-root>/.claude/hooks /tmp/x`, `rm -rf .claude/hooks`, `rm -rf .claude`, `rm .claude/hooks/x.sh`, `ln -sf /tmp/x .claude/hooks/x.sh`, `git rm -r .claude/hooks`, `git mv .claude/hooks h`, `rsync -a /tmp/x/ .claude/hooks/`, `truncate -s 0 .claude/settings.json`, `chmod -x .claude/hooks/dispatch-bash.sh`, `chown x .claude`, `unzip -o x.zip -d .claude/hooks`, `ditto /tmp/x .claude/hooks`, `tar -x -C .claude -f x.tar`, `cp x.sh .claude/hooks/` and, in a live root, `cp -R /tmp/tpl/* .`.
8. Operand roles, passing: `cp .claude/settings.json /tmp/bak`, `dd if=.claude/settings.json of=/tmp/x`, `rsync -a <live>/ <scratch>/`, `tar -C .claude -cf /tmp/h.tar hooks`, `ln -s <live>/.claude/hooks/x.sh /tmp/l`, `cp x ~`, and `cp -R /tmp/tpl/* .` outside a live root.
   1. Option-aware roles, blocking: `cp -t .claude/hooks x.sh`, `cp --target-directory=.claude/hooks x.sh`, `mv -t .claude/hooks x.sh`, `install -t .claude/hooks x.sh`, `install -D x.sh .claude/hooks/x.sh`, `dd if=/tmp/x of=.claude/settings.json`, `rsync -a --remove-source-files .claude/hooks/ /tmp/x/` and `tar --remove-files -cf /tmp/h.tar .claude/hooks`.
   2. Option-aware roles, passing: `cp -t /tmp/bak .claude/settings.json` and `rsync -a --delete <live>/ <scratch>/`.
   3. More verbs, blocking: `rmdir .claude/hooks`, `unlink .claude/settings.json`, `shred .claude/hooks/x.sh`, `chgrp x .claude`, `chflags uchg .claude/settings.json`, `xattr -w a b .claude/hooks/x.sh`, `setfacl -m u:x:r .claude/hooks/x.sh`, `touch .claude/hooks/x.sh`, `perl -pi -e 's/a/b/' .claude/hooks/x.sh`, `ruby -i -pe '1' .claude/settings.json`, `printf ',d\nw\n' | ed .claude/hooks/x.sh`, `cat x | sponge .claude/settings.json`, `base64 -d -o .claude/hooks/x.sh x.b64`, `openssl enc -d -in x -out .claude/settings.json`, `iconv -f a -t b -o .claude/settings.json x`, `plutil -convert json .claude/settings.json` and `gzip .claude/hooks/x.sh`.
   4. Closing rule: an unknown verb with a live protected operand, such as `mytool .claude/hooks/x.sh`, blocks. `bash .claude/hooks/tests/test_x.sh` and `bash .claude/hooks/write-rule-excludes.sh` pass (script runners). `wc -l .claude/hooks/*.sh` and `git log -- .claude/hooks` pass (read-only allowlist). In an isolated worktree, `mytool .claude/hooks/x.sh` passes, because the operand is not live.
9. Harness-only writers: `bash .claude/hooks/pin-ops-root.sh`, `bash <worktree>/.claude/hooks/pin-ops-root.sh`, `echo '{}' | bash .claude/hooks/write-session-snapshot.sh`, `bash .claude/hooks/record-subagent-start.sh` and `source .claude/hooks/dispatch-session-start.sh` block for every class. `APEXYARD_OPS_PIN_DIR=/tmp/sb bash .claude/hooks/pin-ops-root.sh` passes. `bash .claude/hooks/write-rule-excludes.sh` passes.
9b. Prefixes: `find .claude/hooks -name 'block-*' -exec chmod -x {} +`, `find .claude -execdir rm {} \;`, `printf '%s\n' .claude/hooks/x.sh | xargs chmod -x`, `env chmod -x .claude/hooks/x.sh`, `command rm .claude/settings.json`, `nohup mv .claude/hooks /tmp/x` and `time rm -rf .claude` block.
10. Archive extract: `git archive HEAD .claude/hooks | tar -x -C "<literal scratchpad>"` passes. `tar -x -C .claude/hooks -f x.tar` blocks. `tar -xP -C /tmp -f x.tar` with a token in the command blocks. `tar -x -C a -C b` with a token blocks.
11. Expansion: `p=.claude/hooks/x.sh; echo evil > "$p"`, `echo x > ~/.claude/apexyard/ops-root-abc`, `echo x > $HOME/.claude/settings.json`, `echo /tmp/decoy > "${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-$CLAUDE_CODE_SESSION_ID"`, `echo x > "$D/.claude/settings.local.json"` with `D` unset, and `rm -rf "$R/.claude"` block.
12. Expansion passes: `echo x > "$ops_root/.claude/session/active-issue-skill"` with `ops_root=$(git rev-parse --show-toplevel)`, and `cat > "$REVIEW_BODY_FILE"` with a literal scratchpad assignment.
13. Shipped-block corpus: extract every fenced `bash` block from `.claude/skills/*/SKILL.md` and `.claude/agents/*.md` at test time. Run each block that names a protected token and writes. Assert that each passes. At 23d8387 this is 50 blocks in 36 files. Replace placeholder values with fixture paths so each block runs as written.
14. Effective directory: with payload `cwd` at `<live>/.claude/hooks`, `python3 -c "open('dispatch-bash.sh','w')"` blocks. `cd .claude/hooks && python3 -c "open('x.sh','w')"` blocks. `pushd .claude/hooks; python3 -c "open('x','w')"` blocks. `( cd /tmp; python3 -c "open('x','w')" )` passes. `bash -c 'cd .claude/hooks && touch x.sh'` blocks. `cd "$X" && echo x > .claude/settings.json` blocks. `bash -c 'cd .claude && cd hooks && python3 -c "open(\"x\",\"w\")"'` blocks. A nested subshell `( ( cd .claude/hooks; touch x ) )` blocks, and `( cd .claude/hooks ); touch x` in the ops root passes. `popd` with an empty stack sets the effective directory to the live root.
15. Token rule:
    1. `python3 -c "open('.claude/settings.local.json','w').write('{}')"` blocks.
    2. `node -e "require('fs').writeFileSync('.claude/settings.local.json','{}')"` blocks.
    3. `python3 - <<'EOF'` with a body that writes `<pin tree>/ops-root-<sid>` blocks.
    4. An interpreter write whose text names `.claude/hooks`, `.claude//hooks`, `CLAUDE_CONFIG_DIR` or `CLAUDE_ENV_FILE` blocks.
    5. Paired passes: `python3 -c "print(1)"`, `grep -n '.claude/settings.json' docs/x.md` and `jq . .claude/settings.json`.
    6. Preamble pairs: `source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"; python3 -c "open('/tmp/x','w')"` passes. `. .claude/hooks/_lib-x.sh; python3 -c "open('.claude/hooks/x.sh','w')"` blocks.
16. Pathspec forms in a live root: `git checkout HEAD -- .claude/settings.local.json`, `git checkout HEAD .claude/hooks/x.sh`, `git checkout -b tmp HEAD -- .claude/hooks/x.sh`, `git restore .claude/hooks/x.sh`, `git restore -s HEAD~1 .claude/hooks/x.sh`, `git restore --source=HEAD~1 .claude/hooks/x.sh`, `git checkout -p -- .claude`, `git checkout --theirs .claude/settings.json`, `git restore .`, `git restore :/`, `git restore ':(top).claude'`, `git restore '.claude/*'` and `git restore --pathspec-from-file=list` block. `git checkout -b feature` passes.
17. Index writers in a live root: `git checkout-index -f -a`, `git checkout-index -f .claude/hooks/x.sh` and `git read-tree -u -m HEAD` block.
18. Work-tree forms: `git -C .claude restore hooks/x.sh`, `cd .claude/hooks && git restore x.sh`, `git --work-tree=<root> checkout HEAD -- .claude/hooks/x.sh`, `GIT_WORK_TREE=<root> git checkout HEAD -- .claude/hooks/x.sh` and `git -C "$D" restore x.sh` block.
19. Patch: in a live root, `git apply x.patch`, `git am x.mbox`, `patch -p1 < x.patch` and `patch -d <root> -p1 < x.patch` block. `cd /tmp && patch <live>/.claude/hooks/dispatch-bash.sh x.diff` and `patch -o <live>/.claude/hooks/x.sh a b.diff` block. A literal patch file whose `+++` header is an absolute live-hook path blocks from `/tmp`. `git apply --unsafe-paths x.patch` blocks everywhere. In an isolated worktree, `git apply x.patch` passes this ticket's checks. `git apply --check x.patch` passes.
20. Aliases: `git -c alias.co=checkout co HEAD -- .claude/hooks/x.sh` and a configured `alias.rs=restore` block.
21. Scrubbed view (§ B.6): `grep -n 'git apply' file` passes. `bash -c 'git apply x.patch'` in a live root blocks. For each matched verb, `scrub_bash_command` returns the input unchanged.
22. Fail closed: no `jq` blocks an edit-channel call on a protected path. A missing detector library blocks a Bash call that names a protected token. A missing `_lib-git-global.sh` blocks `git restore x` in a live root.

Write `.claude/hooks/tests/test_block_hook_disabling_config_change.sh`:

1. Block on `disableAllHooks: true`, a changed `hooks` value, a changed `env` value (`APEXYARD_ALLOW_X`, `APEXYARD_OPS_PIN_DIR`, `PATH`, `BASH_ENV`, `CLAUDE_ENV_FILE`, `BASH_FUNC_x%%`), a parse error and a missing snapshot record.
2. A key-order change in `hooks` or `env` does not count as a change (`jq -S -c`).
3. Allow a change that edits only `claudeMdExcludes`, as `write-rule-excludes.sh` does.
4. Allow a "don't ask again" permission write that creates `settings.local.json` when the snapshot recorded it as absent.
5. Resolve the file from `source` when `file_path` is absent. Block when the source cannot be resolved.
5b. No-snapshot mode: a "don't ask again" write to `settings.local.json` passes. A `hooks` change to `.claude/settings.json` that differs from `git show HEAD:.claude/settings.json` blocks. An `env` key in `settings.local.json` blocks.
6. Allow and log a change whose `file_path` is a worktree settings file that is not live.
7. Each block writes one log line.

Write `.claude/hooks/tests/test_pin_write_once.sh`:

1. A `startup` SessionStart writes the pin when none exists.
2. A `compact` and a `clear` SessionStart with a different `$PWD`, under a tree that has the `.apexyard-fork` anchor, leave the pin unchanged.
3. A pin that differs from the snapshot record makes `block-protected-target-writes.sh` exit 2 and the § C launcher exit 2.
4. Cleanup deletes an `ops-root-*` file older than 30 days and keeps a newer one. It does not follow a symlink.

Write `.claude/hooks/tests/test_session_snapshot.sh`:

1. A `startup`, `resume` or `fork` SessionStart writes the snapshot when none exists.
2. A second SessionStart of any source with the same `session_id` does not change it.
3. A `compact` or `clear` SessionStart with no existing snapshot writes nothing, and the session stays in no-snapshot mode.
4. An absent file and a file with no `hooks` key give explicit recorded values.
5. `dispatch-session-start.sh` runs the snapshot step after `pin-ops-root.sh` and before `write-rule-excludes.sh`. A ConfigChange fired by `write-rule-excludes.sh` in the same start finds the record and allows the change.
6. A `resume` SessionStart with a changed on-disk hash, or with entries in `config-change-blocks.jsonl`, prints the plain-text warning.
7. The snapshot records the pinned ops root.

Also update:

1. `.claude/hooks/tests/test_settings_fail_closed.sh`: assert that tracked `.claude/settings.json` sets `disableAllHooks` to `false`.
2. `bin/check-escape-hatch.sh`: must still report 0 hook runs under `--settings '{"disableAllHooks": true}'`.
3. `.claude/hooks/tests/test_dispatch_session_start.sh`: the new step and its position.

#### B.13 Artifacts of this ticket

- New: `.claude/hooks/block-protected-target-writes.sh`, `.claude/hooks/block-hook-disabling-config-change.sh`, `.claude/hooks/write-session-snapshot.sh`, the four test files above, fixtures P12, P12b and P12c.
- Changed: `.claude/hooks/pin-ops-root.sh` (write-once on `startup`, `resume` and `fork`, and pin-tree cleanup).
- Changed: `.claude/settings.json` (PreToolUse and ConfigChange entries, `"disableAllHooks": false`), `.claude/hooks/dispatch-bash.sh` (registration), `.claude/hooks/dispatch-session-start.sh` (snapshot step, run alone before the batch), `.claude/hooks/tests/test_settings_fail_closed.sh`, `.claude/hooks/tests/test_dispatch_session_start.sh`, `docs/hooks-fail-closed.md`, `docs/agdr/AgDR-0181-fail-closed-bash-command-scrubbing.md` (§ Scope amendment note).
- Depends on: the #1748 build (`git_alias_check` in `_lib-git-global.sh`).

#### B.14 Merge requirements of the D17 build PR

The Security Auditor reviews the D17 code PR. The PR must show:

1. The shipped-block corpus test (§ B.12 item 13) passes in CI with the § B.4 closing rule active.
2. The effective-directory resolver tests (§ B.12 item 14) pass, including `cd` inside `bash -c`, a nested subshell and `popd` with an empty stack.
3. A capture of macOS `patch -p0` with an absolute header path and with a `..` header path. Keep the § B.5 header rule until the capture is in. A non-literal patch input that names a protected token blocks.
4. Captures P12, P12b and P12c (§ B.10).
5. The pin-versus-snapshot comparison (§ B.1) in `block-protected-target-writes.sh`, with `test_pin_write_once.sh`. The § C ticket adds the same comparison to the launchers.

### C. Launcher pin-check ticket (right after D17, D18)

Scope:

1. When this session has a pin and the pinned root has no `.claude/hooks` directory, the launcher exits 2. It does not exit 0. A pin exists only when SessionStart found the fork. So a missing hooks directory then means tampering, not a foreign project.
2. Validate the pinned root beyond `-d "$r/.claude/hooks"` in every launcher in `.claude/settings.json` and in `bin/sync-cursor-adapter.sh`. When a session snapshot exists, compare the pin with the ops root that the snapshot recorded (§ B.1). A mismatch exits 2.
3. Run each script with `bash <path>`, not by its exec bit:
   1. In each launcher: `exec bash "$r/.claude/hooks/<gate>.sh"`.
   2. In `dispatch-bash.sh`: every sub-hook call (lines 70, 73, 76 and 107, and the other run functions) becomes `bash "$HOOK_DIR/$script"`.
   3. In `dispatch-session-start.sh`: `run_direct` (line 27) and `run_hook` (line 73) do the same.
4. Reason for item 3: `run_hook` treats exit 126 as a warning. So `chmod -x` on a gate script makes every `run_hook` gate fail open, including `block-main-push.sh`. § B blocks every detected `chmod`. Item 3 removes the exec-bit dependency for hidden forms.

Until this ticket merges, a write that hides its operands can still remove the hooks directory or clear an exec bit. § B blocks every detected form.

### D. #1762 ticket: require a build-role subagent for code edits

#### D.1 Caller classification and the subagent ledger

The gate classifies each call in this order:

1. The payload is not valid JSON, or `jq` is missing: class `unparsable`.
2. `agent_id` is present but is not a non-empty string: class `unparsable`.
3. `agent_id` is absent: class `main`. The gate ignores `agent_type` for this class.
4. `agent_id` is present but the ledger has no entry for it, or the entry type differs from `agent_type`: class `unregistered`.
5. A ledger entry matches and `agent_type` is a review agent: class `review`.
6. A ledger entry matches and `agent_type` is on the build-role list: class `build`.
7. Any other matched caller: class `other`. This includes `general-purpose`, `Explore`, `qa-engineer`, an untyped subagent and a teammate.

Put this in a new `_lib-caller-class.sh`. Do not change `review_caller_class`. Its six call sites depend on its type-first order (AgDR-0145, Decision 2).

Subagent ledger:

- Writer: a new SubagentStart hook, `.claude/hooks/record-subagent-start.sh`, with no matcher.
- Location: `<pin tree>/gate-session-<session_id>/ledger/<agent_id>`. The file holds the `agent_type`, or an empty line for an untyped agent. Each write also touches the session gate directory.
- Validation: accept `agent_id` only when it matches `^[A-Za-z0-9_-]{1,128}$`. Accept `session_id` only in the UUID form. Write nothing for any other value.
- The ledger is in the pin tree, which § B protects. § B.4 blocks a tool call that runs `record-subagent-start.sh`, so a caller cannot register its own id. The writer is write-once per `agent_id` and type as a second layer.
- A resume or a repeat teammate message writes the same entry again. The write is idempotent.
- Cleanup: at SessionStart, `pin-ops-root.sh` runs `find -P "<pin tree>" -maxdepth 1 -type d -name 'gate-session-*'`. It deletes a directory only when the name matches `gate-session-<uuid>` and the directory's newest entry is older than 7 days.

Behaviour of class `unregistered`:

- In `block` mode on the edit channel: block. The message says "harness contract mismatch: this caller has an agent_id that no SubagentStart recorded". It tells the operator to report the Claude Code version.
- In `warn` mode: emit the warning as JSON output (§ D.7). Append a log line. Do not block.
- On the Bash channel: apply the rules for class `main`.

#### D.2 Class rules and orchestrator paths

- Class `build`: allow. Other gates still apply.
- Class `main` or `review`: allow a target only when it is an orchestrator path.
- Class `other`: allow a target only when it is an orchestrator path, except `.claude/session/reviews/**` (D10).
- Class `unregistered`: see § D.1.
- Class `unparsable`: block.
- For class `main`, `other`, `review` and `unregistered`, in every mode: block a write to any `*/.claude/settings.json`, `*/.claude/settings.local.json` or `*/.claude/hooks/**` that is not live. This covers worktrees and workspace clones. This rule needs caller classes, so it lives in this ticket, not in § B.

Orchestrator paths:

1. The session scratchpad, validated with `active_ticket_in_session_scratchpad` (`_lib-active-ticket.sh:1624`) and AgDR-0231.
2. `<ops-root>/.claude/session/**`. Class `main` and `review` keep `.claude/session/reviews/**`, because `/approve-merge` and Rex write markers there (`code-reviewer.md:513, 549`, `approve-merge/SKILL.md:152`). The SHA check in `block-unreviewed-merge.sh` stays the control.
3. The auto-memory directory: `dirname(transcript_path)/memory/**`. `transcript_path` is the main session's transcript, also on a subagent call.
4. The portfolio routing files that `portfolio_registry` (`_lib-portfolio-paths.sh:503`) and `portfolio_agent_routing` (line 632) resolve.
5. The `/start-ticket` marker (`_lib-active-ticket.sh:1060`).
6. For class `review` only: a git work tree under a temp root or under the session scratchpad (AgDR-0147, AgDR-0205).
7. Entries in `build.orchestrator_paths`. This key adds paths only. It cannot add a protected path, because § B runs as a separate gate.

Resolve each target with `_lib-path-resolve.sh` before the match. A target outside every governed tree and outside every git work tree is not a code path (#883, `require-active-ticket.sh:44-50`).

#### D.3 Edit and Bash channels

Edit channel:

- Add a PreToolUse entry for `Edit|Write|MultiEdit|NotebookEdit`, with `timeout` 10 and `onFailure` `block`. Label it `CLASS: CONTROL`.
- Read the target from `tool_input.file_path`, then `tool_input.notebook_path`.

Bash channel:

- Register the script in `dispatch-bash.sh` with `run_fail_closed_hook`. Label it `CLASS: BACKSTOP`.
- Apply the class rules to class `main`, `other`, `review` and `unregistered`. Class `build` exits early.
- Use `bash_command_appears_to_write`, then `bash_command_is_deletion_only`, then `bash_extract_write_targets`, then judge every target (AND semantics, #886).
- A deletion-only command passes the class rules (D9).
- Treat an unextractable write as a code-path write. The one exception is a command whose only write targets are orchestrator paths.
- Code-path half of the git matchers: use the work-tree resolution and pathspec rules of § B.5. A `git checkout` or `git restore` pathspec on a code path follows the class rules. `git apply`, `git am` and `patch` outside a live root follow the class rules. Read the scrubbed view under the § B.6 amendment.
- Temp roots: use the list in `_lib-active-ticket.sh:1537`: `/tmp`, `/var/tmp`, `$TMPDIR` and `$CLAUDE_CODE_TMPDIR`. Resolve each root and each target by physical path, so `/var/folders/...` compares as `/private/var/folders/...` on both sides.
- Archive extract: § B.3 makes a literal `tar -x -C <dir>` an extracted recursive write to `<dir>`. For the class rules, the write passes for class `review` when `<dir>` is the scratchpad or under a temp root.
- Do not change `_lib-detect-bash-write.sh`. Do not call `strip_heredoc_bodies`. Do not add a subtractive prefilter.

External coding CLIs:

- A `codex` or `cursor-agent` launch is not a write family. The gate allows it.
- Document the safe form: write the prompt to the scratchpad, then run `codex exec - < "$SCRATCH/prompt.md"`.
- If the quoted-prompt form false-blocks, add the CLI names to a data-only list for this gate only.

Latency budget:

- Target: the new dispatcher entry adds no more than 300 ms at the 95th percentile per call on the CI runner. This is a target, not a measurement.
- Hard limit: the budget test fails when one call takes more than 2 s. The dispatcher timeout is 20 s (`.claude/settings.json:54`).

#### D.4 Build-role list

- Default list (8 types): `backend-engineer`, `frontend-engineer`, `platform-engineer`, `data-engineer`, `product-manager`, `ui-designer`, `ux-designer`, `tech-lead`.
- Source of the first seven: `.claude/rules/pr-workflow.md:231` and the build-class block in each agent file.
- `tech-lead` authors designs and AgDRs under `docs/` (CEO answer 3).
- Location: `build.role_agents` in `.claude/project-config.defaults.json`, beside `build.isolation` (line 204). `_lib-read-config.sh:8-9` merges objects and replaces arrays.
- Fallback: the same 8 types from hook code. Validation: the slug rule from `_lib-review-markers.sh:229-231`.
- Review agents are never build roles. A config entry cannot change this.
- `contrarian`, `dependency-auditor` and `qa-engineer` are not on the list.

Effect on review agents: defense in depth on the edit channel, and the first layer against Bash file writes. Effect on `qa-engineer`: the first real control.

#### D.5 Gate configuration source (D19)

- Read `build.main_thread_edits`, `build.main_thread_bash`, `build.role_agents` and `build.orchestrator_paths` from the session snapshot (§ B.1). The SessionStart snapshot step reads them through `_lib-read-config.sh`.
- A mid-session change to `.claude/project-config.json` applies at the next session start.
- With no snapshot, the gate uses the built-in defaults in hook code: `warn`, `warn`, the 8 roles and no extra paths.
- Each flip ticket (§ D.8 steps 3 and 4) also changes the matching built-in default in hook code. Otherwise a no-snapshot session stays in `warn` after the flip.

#### D.6 Escape hatch

- Name: `APEXYARD_ALLOW_MAIN_THREAD_EDITS=1`, read from the hook process environment only.
- A `VAR=1 <command>` prefix in a Bash call reaches only the child shell, so the agent cannot set it from a command.
- The gate refuses the hatch when a live settings file or a user settings file sets the variable in `env`. It checks this with a fixed-string search, so it works without `jq`. The refusal is a warning (§ D.7).
- Scope: it lifts the class rules for the session. It does not touch § B.
- With the hatch set and an unparsable payload, the gate allows with a warning. With no `jq`, it prints a fixed JSON string.
- Each use emits `main-thread edit gate bypassed` (§ D.7) and appends one line to `<ops-root>/.claude/session/main-thread-edit-overrides.jsonl`.
- The block message tells the agent to delegate to a build-role agent. It does not name the variable.
- `docs/hooks-fail-closed.md` names the variable for operators and states why this gate has a per-gate hatch.

#### D.7 Warning output and the dispatcher contract

- A block exits 2 with the reason on stderr. It writes no JSON and sets no `continue`. On exit 2, JSON fields cannot override the block.
- A warning exits 0 and writes exactly one JSON object to stdout. Warnings are the `warn`-mode would-block, the `unregistered` mismatch in `warn` mode, each hatch use and a refused hatch.
- The object has `systemMessage` for the operator, and `hookSpecificOutput` with `hookEventName` `"PreToolUse"` and `additionalContext` for Claude.
- The object has no `permissionDecision` field. `"allow"` would skip the permission prompt.
- Dispatcher contract (`dispatch-bash.sh`):
  1. Send the stdout of every other sub-hook to stderr. Today PreToolUse plain-text stdout goes only to the debug log, so no visible output is lost.
  2. Capture this gate's stdout.
  3. Emit this gate's JSON object once, after the last sub-hook, and only on the exit-0 path.
  4. On an exit-2 path, emit no JSON.

#### D.8 Rollout, inventory, flips and rollback

Mode keys: `build.main_thread_edits` and `build.main_thread_bash`, with values `block`, `warn` and `off`.

- In `warn` mode, the gate emits the block text as a warning (§ D.7) and exits 0. It appends a line to `.claude/session/main-thread-edit-would-block.jsonl`, with the skill name when known.
- In `off` mode, the class rules do not run. § B still runs.

Steps:

1. The #1762 PR ships both modes as `warn`. It includes the P1-P11 and P13 fixtures (merge requirement, § D.9). It also updates:
   1. `CLAUDE.md` always-on floor: one line, "Code edits run in a build-role subagent. The main thread writes only orchestrator paths."
   2. `.claude/rules/agent-role-selection.md` § "Backstop": name the new gate.
   3. `docs/hooks-fail-closed.md`: the hatch and the rollback steps.
   4. `.claude/hooks/pin-ops-root.sh`: the ledger cleanup.
2. Skill inventory ticket. Start from § Context "Day-one blast radius" and the would-block log. For each skill, choose delegate, scratchpad or a new orchestrator path. Each new orchestrator path needs CEO sign-off. Include `/decide`.
3. Flip `build.main_thread_edits` to `block` in its own ticket. Preconditions: the inventory ticket is closed, one release has passed in `warn`, and the log has no unexplained edit-channel or `harness contract mismatch` entry.
4. Flip `build.main_thread_bash` to `block` in its own ticket, one release later, with the same criteria for Bash entries.
5. Record each flip and its log data in a changelog entry on this AgDR.

Rollback:

1. The operator relaunches with `APEXYARD_ALLOW_MAIN_THREAD_EDITS=1`. This lifts the class rules.
2. A build-role agent sets both mode keys to `off` in `.claude/project-config.json`. The change applies at the next session start (D19), so the operator relaunches again.
3. If § B or the ledger misfires, the operator relaunches with `--settings '{"disableAllHooks": true}'`. A build-role agent reverts the PR in an isolated worktree. The live root gets the revert through `git pull`. Do not merge or push other work in that session (`docs/hooks-fail-closed.md:151-154`).

#### D.9 Tests for this ticket

Live payload proof (merge requirement for the #1762 PR). Record `claude --version` with each capture.

| # | Session | Event and tool | Expected `agent_id` | Expected `agent_type` |
|---|---------|----------------|---------------------|-----------------------|
| P1 | Plain `claude` main thread | PreToolUse `Edit` | absent | absent |
| P2 | Plain `claude` main thread | PreToolUse `Write` | absent | absent |
| P3 | Plain `claude` main thread | PreToolUse `NotebookEdit` | absent | absent |
| P4 | `claude --agent backend-engineer` main thread | PreToolUse `Edit` | absent | `backend-engineer` |
| P5 | `claude --agent backend-engineer` main thread | PreToolUse `Bash` | absent | `backend-engineer` |
| P6 | `backend-engineer` subagent | PreToolUse `Edit` | present | `backend-engineer` |
| P7 | `general-purpose` subagent | PreToolUse `Write` | present | `general-purpose` |
| P8 | Subagent inside a `claude --agent tech-lead` session | PreToolUse `Edit` | present | the subagent's type |
| P9 | The P6 subagent, then a resume of it | SubagentStart | equal to the P6 `agent_id` | `backend-engineer` |
| P10 | In-process teammate | SubagentStart, then PreToolUse `Edit` | present and equal in both | the teammate's type |
| P11 | Plain `claude` main thread | PreToolUse `MultiEdit` | absent | absent |
| P13 | A skill with `context: fork` | SubagentStart, if any, then PreToolUse `Edit` | record | record |

Pass criteria:

- P1 to P5 and P11 have no `agent_id`. If P4 or P5 has one, stop. Decision 1 then needs a new option.
- P6 to P8 have an `agent_id`. P8 shows the subagent type.
- P9: the SubagentStart `agent_id` and `session_id` equal the PreToolUse values. SubagentStart fires again on resume.
- P9 race check: run P9 with a SubagentStart hook that sleeps 2 s before it writes the ledger. The subagent's first PreToolUse must find the entry. If it does not, stop and add an option to Decision 1.
- P10: SubagentStart fires for the teammate, and the ids match. If not, teammates block. Document that limit.
- P11: if the pinned build has no `MultiEdit` tool, record that fact instead.
- P13: record whether a `context: fork` skill fires SubagentStart and carries an `agent_id`. If it carries an id with no SubagentStart, it is `unregistered`. Document that limit.
- P6 and P7: `transcript_path` is the main session's transcript.

Write `.claude/hooks/tests/test_require_subagent_for_code_edits.sh`:

1. Caller classes: each of the seven classes, with each fixture.
2. Ledger: no entry and a type mismatch give `unregistered`. An unreadable ledger directory makes every present id `unregistered`. `record-subagent-start.sh` writes nothing for an `agent_id` with `/`, `..` or a space. A resume writes the same entry.
3. Ledger cleanup: a `gate-session-<uuid>` directory with a newest entry older than 7 days is deleted. A newer one stays. A directory named `gate-session-x` is not touched. A symlink is not followed.
4. `unregistered`: blocks in `block` mode with the "harness contract mismatch" text. It warns and logs in `warn` mode.
5. Edit channel: a main-thread `Edit` on `src/app.ts` blocks in `block` mode. A main-thread `Write` to each orchestrator path passes.
6. Memory directory: a subagent payload with the main session's `transcript_path` resolves to the same memory directory.
7. Review markers: a `general-purpose` `Write` to `.claude/session/reviews/x-rex.approved` blocks. A `code-reviewer` Bash write of its marker passes. A main-thread `/approve-merge` marker write passes.
8. Path tricks: a symlink in the scratchpad into the ops fork blocks. A `..` segment blocks. Another session's scratchpad blocks.
9. Non-live settings and hooks: a main-thread write to a worktree's `.claude/settings.local.json` or `.claude/hooks/x.sh` blocks in every mode. A `platform-engineer` `Edit` on the same files passes.
10. Bash writes that block for class `main`, `other`, `review` and `unregistered`: `sed -i`, BSD `sed -i ''`, `>` and `>>`, `tee`, `cat > src/x.ts <<'EOF'`, `python3 - <<EOF`, `git apply x.patch` and `git restore src/app.ts` outside a live root, and a two-target command whose first target is the scratchpad (#886).
11. Bash commands that pass for class `main`: `grep -n 'sed -i' file`, `git log --format='%h > %s'`, a scratchpad heredoc body that names `git apply` and `> src/app.ts`, `git apply --check x.patch`, `patch --dry-run`, `gh pr view`, both `codex exec` forms, `rm src/app.ts`, `bash .claude/hooks/write-rule-excludes.sh` and `claude plugin install apexyard-status@apexyard --scope local`.
12. Review class: `sed -i src/app.ts` in the ops fork blocks. A write inside a scratch clone under `/tmp`, `/private/tmp`, `/var/tmp`, `$TMPDIR` and `$CLAUDE_CODE_TMPDIR` passes after resolution. `git archive HEAD | tar -x -C <literal scratchpad path>` passes. The same command with `-C "$SCRATCH"` is unextractable and blocks in `block` mode.
13. Build roles: a `backend-engineer` `Edit` on `src/app.ts` passes. `general-purpose`, `qa-engineer` and `code-reviewer` edits block. A config list that adds `code-reviewer` still blocks it.
14. Config: a replaced `build.role_agents` list takes effect at the next session start. A mid-session change to `.claude/project-config.json` does not change the running session (D19). A missing or malformed key falls back to the built-ins.
15. Warning output:
    1. In `warn` mode, stdout is exactly one JSON object with `systemMessage`, `hookSpecificOutput.hookEventName` equal to `"PreToolUse"` and `hookSpecificOutput.additionalContext`.
    2. The object has no `permissionDecision` and no `continue` key at any level.
    3. The hatch, a refused hatch and the `unregistered` warning use the same shape.
    4. With no `jq` and the hatch set, stdout is still one valid JSON object.
    5. Through `dispatch-bash.sh`, with this gate warning, a second sub-hook that writes plain text to stdout and a third that writes to stderr, the dispatcher stdout is one valid JSON object. The plain text appears on stderr.
    6. On an exit-2 path, the dispatcher stdout is empty.
16. Hatch: `APEXYARD_ALLOW_MAIN_THREAD_EDITS=1` allows a code-path write, warns and logs. A settings `env` entry for the variable makes the gate refuse it. The block message does not contain the variable name.
17. Modes: `warn` exits 0 with the JSON warning. `off` exits 0 with no output.
18. Fail closed: no `jq` blocks an edit-channel call. A non-string `agent_id` blocks. A missing detector library blocks a main-thread Bash write.
19. Adversarial pairing (AgDR-0109): each bypass in item 10 has a paired pass in item 11.

Also write `.claude/hooks/tests/test_record_subagent_start.sh` and `.claude/hooks/tests/test_require_subagent_process_budget.sh` (model: `test_active_ticket_process_budget.sh`). Add a shared-detector no-drift case: `bash_command_appears_to_write` still returns 1 for `git apply x.patch`.

#### D.10 Artifacts of this ticket

- New: `.claude/hooks/require-subagent-for-code-edits.sh`, `.claude/hooks/_lib-caller-class.sh`, `.claude/hooks/record-subagent-start.sh`, the three test files in § D.9, fixtures P1-P11 and P13.
- Changed: `.claude/settings.json` (PreToolUse and SubagentStart entries), `.claude/hooks/dispatch-bash.sh` (registration and the stdout contract), `.claude/hooks/write-session-snapshot.sh` (gate keys, D19), `.claude/hooks/pin-ops-root.sh` (ledger cleanup, beside the D17 pin changes), `.claude/project-config.defaults.json`, `CLAUDE.md`, `.claude/rules/agent-role-selection.md`, `docs/hooks-fail-closed.md`.

## Consequences

- Role boundaries become mechanical after the edit-channel flip. A main-thread edit and a `general-purpose` edit both block.
- For one release or more, the #1762 channels only warn. Claude sees each warning as `additionalContext`, and the operator sees it as `systemMessage`.
- Tamper hardening (§ B) lands first and blocks from its merge. § B.11 lists its own consequences, including the `/update` route.
- The main thread keeps conclusions, not diffs. This supports AgDR-0074.
- Cost: a one-line fix needs a subagent spawn after the flip.
- Cost: one ledger write on each spawn, resume and teammate message. One more detector pass on each Bash call, inside the budget in § D.3.
- AgDRs and other `docs/` artifacts need a `tech-lead` or `product-manager` subagent after the flip. The inventory ticket changes `/decide`.
- In-flow-class roles no longer write code in-thread. The sibling ticket amends AgDR-0050 § Axis 6.
- `qa-engineer` loses code-path writes for the first time.
- An operator who starts `claude --agent backend-engineer` for a solo build is blocked on the main thread after the flip.
- The four other consumers of `_lib-detect-bash-write.sh` keep their behaviour.
- AgDR-0181 § Scope gains a third, narrow scrubbed-view consumer (D14).
- `dispatch-bash.sh` sends other sub-hooks' stdout to stderr and emits at most one JSON object.
- A gate config change applies at the next session start (D19).

### Risks

| Risk | Effect | Mitigation |
|------|--------|------------|
| A future Claude Code build adds `agent_id` to main-thread calls | The id has no ledger entry, so the call is `unregistered` and blocks loud (warns in `warn` mode) | The ledger. Repeat the capture when the pinned version changes. |
| A future build stops firing SubagentStart, or changes the id format | Every subagent edit is `unregistered` and blocks | Fails loud. The hatch recovers. P9 detects it. |
| A future build drops `agent_id` from subagent calls | Subagent edits become class `main` and block | Fails loud. The hatch recovers. |
| Teammates or `context: fork` skills do not fire SubagentStart | Their edits block | P10 and P13 check it. Document the limit. |
| A write hides its operands fully: a custom script, an unresolved variable with a harmless tail, `os.path.join`, string joins or `base64`, run outside a protected directory | No extracted operand, no token and no protected directory, so § B misses it | Backstop limit (`_lib-detect-bash-write.sh:137-143`). ConfigChange covers settings in the running session. § C closes the hooks-directory removal. |
| A hidden write removes or renames `.claude/hooks` before § C merges | Every launcher exits 0 | § C, sequenced right after D17 (D18). |
| A hidden `chmod -x` on a gate script before § C merges | 13 launcher entries without `onFailure: block` fail open. `run_hook` in both dispatchers treats exit 126 as a warning, so every `run_hook` gate fails open, including `block-main-push.sh`. | § C runs every script with `bash <path>`, in launchers and in both dispatchers. |
| A write to `.git/config` in a live root, for example through `git config` | A setting such as `core.fsmonitor` or `core.hooksPath` changes what git runs inside hook processes | Named residual (Security Auditor A4). `git config` is not a write family, and the target is not a protected path. A follow-up can add it. |
| A verb name in a different letter case, for example an interpreter or a nested shell (Security Auditor A8) | The default macOS volume runs it as the real program. The verb tests are case-sensitive, so it goes to the unknown-verb rule. That rule judges only a literal protected operand. It does not read a nested program, an interpreter script, an `xargs` input or a `dd` output operand. | Named residual. Follow-up ticket. |
| From an isolated worktree, a mutation that takes its operands from stdin, such as an `xargs` form, with a relative path to live state and no protected token (Security Auditor A9) | The worktree is not a sensitive directory, so token context is off. The gate does not see an operand that arrives on stdin. The same class already passed from the live root. | Named residual. Follow-up ticket. |
| A custom script runs a harness-only writer by a computed name | The fixed-name rule does not see it | Named residual. Write-once on the pin and the snapshot is the second layer. |
| Local settings set `disableAllHooks: true` before a session starts | No hook runs | Outside any hook's reach. § B makes it hard to write from inside a session. |
| A blocked settings change stays on disk (D16) | The next session or a fork loads it | The ConfigChange log records the block. |
| A ConfigChange block is silent | The operator does not see it | `config-change-blocks.jsonl`. |
| `claude plugin install --scope local` and `claude mcp add` write settings through a CLI, with no detected write | A plugin can add its own hooks or MCP servers | Recorded residual. ConfigChange blocks only `hooks`, `env` and `disableAllHooks` changes in settings files. Plugin hooks cannot remove ApexYard hooks. |
| A build role edits a live `.claude/agents/*.md` frontmatter | A changed tool list applies to later spawns | Named residual (D20). The gate classifies by `agent_type` and the ledger, not by the file. Review agents stay review class. The edit goes through PR review. |
| A hook change committed elsewhere (for example in a worktree) reaches the live root through `git checkout <branch>`, `git reset --hard`, `git stash pop`, `git merge` or `git cherry-pick` | Live hooks change to that version | Named residual. These commands are not counted, like `git pull`. Remote branch protection does not stop a local commit. A commit made in the live root needs a hook edit there, which § B blocks. `git checkout-index` and `git read-tree -u` are matched (§ B.5). |
| The `.claude/hooks` token (D15) false-blocks a build-role interpreter script in a worktree | A legitimate build step blocks | The message names the `Edit` tool. A paired test records it. |
| The main thread deletes a code file with `rm` | The class rules allow it (D9) | § B still blocks deletions of protected paths. The PR diff shows the rest. |
| The main thread "delegates" through `codex exec` | The gate cannot tell delegation from a shortcut | In scope by CEO decision. The CLI output goes through review. |
| The logs are under `.claude/session/` | The main thread can delete them | Evidence for the human, not tamper-proof records. |
| The second detector pass is slow | Bash calls slow down or time out | The budget test. |

## CEO answers (2026-10-19)

1. Portfolio routing files: only the registry and `agent-routing.yaml`. `onboarding.yaml` is not an orchestrator path. The main thread delegates edits to it.
2. Bootstrap skills: the gate does not honor the `active-bootstrap` marker. `/setup`, `/handover` and `/scaffold` spawn a build role for repo writes.
3. `tech-lead` is on the default build-role list. `docs/agdr/**` is not an orchestrator path.

## Decisions for the CEO

### Decided (CEO, 2026-10-19)

Source: the CEO decision note for #1762 of 2026-10-19, including § "#1762 round 3" and § "#1762 round 4". No item is open.

| # | Decision | Decided |
|---|----------|---------|
| D1 | Main-thread detection | Option 1E: `agent_id` absent means main thread, plus the SubagentStart ledger and the `unregistered` class |
| D2 | Bash code-path rule | Option 2A |
| D3 | Build roles | Option 3A |
| D4 | Hatch | Option 4A. It does not lift the tamper hardening. |
| D5 | Rollout | Option 5B |
| D6 | `.claude/settings.local.json` | Protected, not an orchestrator path |
| D7 | New matchers | Gate-local |
| D8 | Review class on the Bash channel | Applies, with scratch clones and markers allowed |
| D9 | Deletion-only Bash | Not counted by the class rules |
| D10 | `.claude/session/reviews/**` | Excluded for class `other` only |
| D11 | Non-live settings files | A build role may edit them |
| D12 | AgDR filing | In the sibling ticket's PR, which merges before #1762 |
| D13 | Live hook scripts | Protected for every class, including `build`. Hook work only in an isolated worktree. |
| D14 | Git matcher command view | Scrubbed view. This record amends AgDR-0181 § Scope (§ B.6). |
| D15 | `.claude/hooks` as a protected token | Yes |
| D16 | Restore from snapshot | No. Log only. |
| D17 | Tamper hardening | Lands first as its own ticket (§ B), before #1762 |
| D18 | Launcher `exit 0` | Closed in the pin-check ticket, merged right after D17 (§ C) |
| D19 | Gate configuration source | The gate reads its keys from the SessionStart snapshot (§ D.5) |
| D20 | Live `.claude/agents/*.md` frontmatter | A named residual (§ Risks) |
| D21 | Alias coverage | The #1748 build merges before the D17 ticket. D17 is blocked by it and calls `git_alias_check` (§ B.5). |

## Follow-up tickets

Do not file these yet. Each is one ticket. § Decision "Ticket order" sets the sequence.

| Title | Scope |
|-------|-------|
| Spawn in-flow roles for code edits and amend AgDR-0050 Axis 6 | § A. Files this AgDR. |
| Harden settings and hooks against in-session tampering (D17) | Filed as #1806. § B. Cites this AgDR. Carries the AgDR-0181 § Scope amendment. Merge requirement: P12, P12b and P12c. Blocked by the #1748 build (D21). |
| Harden the hook launcher pin check | § C. Exit 2 when a pinned root loses `.claude/hooks`. Run every script with `bash <path>` in the launchers, `dispatch-bash.sh` and `dispatch-session-start.sh`. Validate the pin in `.claude/settings.json` and `bin/sync-cursor-adapter.sh`. |
| Inventory main-thread skill write targets | For each of the 34 writing skills, choose delegate, scratchpad or a new orchestrator path. Include `/decide`. |
| Fix the hatch advice in two block messages | `block-onboarding-in-git.sh:115` and `require-skill-for-issue-create.sh:168` advise `VAR=1 <command>`, which never reaches the hook process. |
| Match `NotebookEdit` in the ticket-first gate | The entry at `.claude/settings.json:16` matches `Edit\|Write\|MultiEdit` only. |
| Give `qa-engineer` a real tool allowlist | Replace `allowed-tools:` in `qa-engineer.md:5` with `tools:` and `disallowedTools:`. Check the other agent files. |
| Evaluate patch matchers in the shared write detector | Decide whether `git apply`, `git am` and `patch` belong in `_lib-detect-bash-write.sh` for all four consumers. |
| Protect `.git/config` and `.git/hooks/` in a live root | Decide whether `git config` writes and `.git/hooks/` files in a live root join the protected set (Security Auditor A4). |
| Flip `build.main_thread_edits` to `block` | § D.8 step 3. |
| Flip `build.main_thread_bash` to `block` | § D.8 step 4. |

## Artifacts

- Ticket: me2resh/apexyard#1762
- Sibling ticket (§ A): `.claude/rules/role-triggers.md`, `.claude/hooks/detect-role-trigger.sh`, `roles/engineering/tech-lead.md`, `docs/agdr/AgDR-0050-agent-runtime-overhaul.md`, this AgDR
- D17 ticket: me2resh/apexyard#1806 (§ B.13)
- Pin-check ticket: § C
- #1762: § D.10
- Amends: AgDR-0050 § Axis 6, AgDR-0181 § Scope
- Applies: AgDR-0104 and AgDR-0109 (control and backstop labels), AgDR-0113 (no subtractive heredoc filter), AgDR-0181 (only named consumers read the scrubbed view), AgDR-0145 (caller fields as trust root), AgDR-0231 (scratchpad validation), AgDR-0147 and AgDR-0205 (reviewer scratch clones)
- Depends on: the #1748 build (`git_alias_check`). The D17 ticket is blocked by it (D21).
- Related: #886, #883, #569, #1066, #1418, #1760, AgDR-0074, AgDR-0120
- Reviews: Solution Architect review of v1, delta review of v2, delta checks of v3 and v4, and a Security Auditor pass on v5, 2026-10-19. Next: the D17 build. The Security Auditor reviews its code PR.

## Review response

### First review (v1 to v2)

| Finding | What changed |
|---------|--------------|
| Citation fixes | `active_ticket_in_session_scratchpad` cites line 1624. Six call sites of `review_caller_class` in five hooks. |
| B1 | Option 1E with the ledger and class `unregistered`. P1-P11 capture as a merge requirement. |
| B2 | Protected set, `settings.local.json` protected, `"disableAllHooks": false`, ConfigChange hook, pin-check ticket, tamper tests. |
| B3 | Warn-first rollout, blast-radius table, inventory ticket. |
| B4 | Bash channel applies to class `review`. Reviewer `tools:` allowlists corrected. `qa-engineer` named as the real gap. |
| B5 | Gate-local matchers, no-drift test, budget test and latency target. |
| B6 | Text changes moved to the sibling ticket, merged before #1762. |
| Suggestions | Hatch message, review markers for class `other`, deletion-only rule, rollback, memory directory, latency. |

### Delta review (v2 to v3)

| Finding | What changed |
|---------|--------------|
| N1 | Live hook scripts protected for every class (D13). |
| N2 | Scrubbed view with an AgDR-0181 § Scope amendment (D14). AgDR-0181 scope misstatement fixed. |
| N3 | Warnings as one JSON object with `systemMessage` and `additionalContext`, no `permissionDecision`. |
| N4 | Additive protected-token rule. |
| Suggestions | P9 race, both user settings files, live settings by exact path, ConfigChange missing hash, temp roots, pathspecs, ledger cleanup, tamper ticket option. |

### Delta check (v3 to v4)

| Finding | What changed |
|---------|--------------|
| D14-D17 decided | Moved to § Decided everywhere: Outcome, Summary, § 2d, § B, § D, Consequences, Follow-up tickets and Artifacts. Removed every "if the CEO accepts or rejects" branch for D14 to D17. The "Open (v3)" table is gone. |
| B1(a) | § B.3 judges every path operand, including mover sources, `dd if=` and deletion operands. D9 now applies to the class rules only. |
| B1(b) | § B.2 adds protected ancestors: `.claude/hooks`, `.claude`, each live root, the pin tree and every directory above them. |
| B1(c) | § B.3 adds a gate-local operand matcher for `ln`, `git rm`, `git mv`, `rsync`, `truncate`, `chmod`, `chown`, `unzip`, `ditto` and `tar -C`. It satisfies condition 1 of the token rule (§ B.4). |
| B1(d) | § Context names the launcher `exit 0` and the 13 entries without `onFailure: block`. Chose to close it in the pin-check ticket, merged right after D17 (§ C, then open item D18, decided in round 4). § C also runs gate scripts with `bash <path>`. |
| B1(e) | § B.12 items 6 and 7: `mv`, `rm -rf` on the directory, `ln -sf`, `git rm -r` and `chmod -x` on live hooks, for class `main`, `platform-engineer` and `code-reviewer`. |
| B2(a) | § B.5 matches `git checkout` and `git restore` with and without `--`, plus `--source`, `-p`, `--theirs`, `--ours` and `-m`. |
| B2(b) | § B.5 treats `.`, protected ancestors, magic, glob and from-file pathspecs as covering protected paths. |
| B2(c) | § B.5 resolves the work tree from `cwd`, `cd`, `-C`, `--work-tree`, `--git-dir`, `GIT_WORK_TREE` and `GIT_DIR`. A non-literal value fails closed. |
| B2(d) | § B.5 reuses `git_alias_check` from #1748 for `checkout`, `restore`, `apply` and `am`. The ordering was open item D21, decided in round 4: the #1748 build merges first. |
| B2(e) | § B.5 blocks `git apply`, `git am` and `patch` whose effective work tree is a live root, for every class. |
| B2(f) | § B.12 items 9 to 12 test each form. |
| B3(1) | § B.1 records explicit values for an absent file and a missing key. A missing snapshot record is the only "missing" case. § B.12 tests a "don't ask again" write. |
| B3(2) | § B.1 makes the snapshot write-once per `session_id`. `test_session_snapshot.sh` tests that `compact` does not overwrite it. P12b captures it. |
| B3(3) | § B.7 hashes the whole `env` object and blocks any change. This covers `APEXYARD_OPS_PIN_DIR`, `PATH`, `BASH_ENV` and `BASH_FUNC_<name>%%`. |
| B3(4) | § B.7 resolves the file from `source` when `file_path` is absent, and fails closed on an unresolvable source. |
| B3(5) | § B.11 states that a mid-session `git pull` or `/update` that changes `hooks` is blocked in silence, and the new hooks apply next session. |
| B4(a) | Protected item 5 (non-live settings and hooks for non-build classes) stays in #1762 (§ D.2). § B ships items 1-4 only. |
| B4(b) | The protected halves of the pathspec and patch matchers and the AgDR-0181 amendment are in § B.5 and § B.6. The code-path halves are in § D.3. |
| B4(c) | § B.4 does not count a token inside the first operand of `source` or `.`. § B.12 item 8.7 has paired tests. |
| B4(d) | Tokens now use `.claude/hooks` with no trailing slash. Added `CLAUDE_CONFIG_DIR`, its resolved path, `.claude/apexyard` and `APEXYARD_OPS_PIN_DIR`. `os.path.join` is a named residual. |
| B4(e) | § B.10 adds P12 as a merge requirement for the D17 ticket. § B.1 defines live roots from the session snapshot, so a worktree subagent cannot make D13 block all hook work. |
| B4(f) | § B.11 names the `/update` conflict and in-progress hook work as D17 consequences, with the worktree-then-`git pull` route. |
| B4(g) | Rollout, tests and artifacts are now one section per ticket: § A sibling, § B D17, § C pin check, § D #1762. |
| B5 | § D.5 reads the gate keys from the session snapshot (then open item D19, decided in round 4). It is in #1762, not D17. |
| C1 | § D.7 states the dispatcher contract. Other sub-hooks' stdout goes to stderr. This gate's object is emitted once, after the last sub-hook, on the exit-0 path only. No `continue`. § D.9 item 15.5 adds a second sub-hook that writes plain text to stdout. |
| S1 | § D.3 reused `_ratc_in_temp_dir`. v5 replaces it with the `_lib-active-ticket.sh:1537` list, which includes `$CLAUDE_CODE_TMPDIR`. The archive-extract form moved into § B.3 in v5. |
| S2 | § D.1 cleanup ages by newest entry, touches the directory on each write, uses `find -P -maxdepth 1` and matches only `gate-session-<uuid>`. |
| S3 | § D.9 adds capture P13 for a `context: fork` skill. |
| S4 | § D.6 refuses the hatch when a loaded settings file sets it in `env`. |
| S5 | Recorded as a residual in § Risks (then open item D20, decided in round 4). |
| S6 | `claude plugin install --scope local` and `claude mcp add` are a recorded residual in § Risks. |
| D17 self-contained | § B is a complete ticket section that cites this AgDR and carries the AgDR-0181 amendment. No new AgDR is needed. |

### Delta check (v4 to v5)

| Finding | What changed |
|---------|--------------|
| N1 | § B.3 "Variable and home expansion": expands `~`, `$HOME`, `$CLAUDE_PROJECT_DIR`, `$CLAUDE_CONFIG_DIR`, `$CLAUDE_CODE_SESSION_ID`, `$APEXYARD_OPS_PIN_DIR`, `${APEXYARD_OPS_PIN_DIR:-<default>}` and same-command literal assignments, then judges. An unresolved expansion blocks only on a protected tail, an ancestor tail for remove-class roles, or a bare variable whose assignment names a token. Every variable is not made unextractable. § B.12 item 11 tests the four bypass forms, item 12 the passing forms, and item 13 runs the 50-block shipped corpus at test time. |
| N2 | § B.3 "Effective directory": relative operands resolve against the payload `cwd` plus literal `cd`, `pushd`, `popd`, subshells and `bash -c` strings. An unfollowable change means the live root. § B.4 condition 2 also holds in `<live root>/.claude`, the pin tree, `~/.claude` or `$CLAUDE_CONFIG_DIR`. § B.12 item 14 tests it. |
| N3 | § B.3 "Operand roles" table: remove, rename, mode, owner and link-name operands check protected paths and ancestors. Single-file destinations check protected paths only, with a copy into a directory judged as `<dir>/<basename>`. Recursive destinations check paths and ancestors. Read-only sources are not judged. § B.3 "Path forms" replaces the symlink and `..` rule with lexical and physical checks. § B.12 items 6 to 8 test both sides. |
| N4 | § B.3 "Archive extract": a literal single `tar -x -C <dir>` with no absolute-name flag is an extracted recursive write. The reviewer form at `code-reviewer.md:80` and `security-reviewer.md:62` passes. § B.12 item 10 has paired tests. |
| N5 | § B.1: the snapshot is written only on `startup`, `resume` or `fork`, write-once per `session_id`, and never on `compact` or `clear`. A session with no snapshot stays in no-snapshot mode. P12b and `test_session_snapshot.sh` now cover `/clear`. |
| N6 | § B.1: `write-session-snapshot.sh` runs alone with `run_direct`, after `pin-ops-root.sh` (line 57) and before the concurrent batch (lines 37-54). `test_session_snapshot.sh` item 5 tests the order and a ConfigChange from `write-rule-excludes.sh`. |
| N7 | § C item 3 covers both dispatchers (`dispatch-bash.sh:70, 73, 76, 107`, `dispatch-session-start.sh:27, 73`) and the launchers. § B.3 finds operand verbs after `-exec`, `-execdir`, `-ok`, `-okdir`, `xargs`, `env`, `command`, `exec`, `sudo`, `nice`, `nohup` and `time`. `{}` and `xargs` input are unextractable, so the `find` form blocks with its token. § B.12 item 9 tests it. |
| N8 | § B.5 judges the `patch` positional file and `-o` or `--output` as destinations, honours `-d`, reads literal patch-file headers for absolute and `..` paths, prefixes `git apply --directory=`, and blocks `--unsafe-paths`. The macOS `patch -p0` question is a note for the Security Auditor. § B.12 item 19 tests it. |
| N9 | D18 to D21 are decided everywhere. The "Open (v4)" table is gone. The D17 ticket is blocked by the #1748 build (Outcome, Ticket order, § B, Follow-up tickets, Artifacts). The § B.5 alias fallback branch is deleted, and § B.12 item 20 is unconditional. #1748 follow-up item 5 is in § B.2 item 5 (`~/.claude/session-env/**`, `~/.claude/shell-snapshots/**`, the `$CLAUDE_ENV_FILE` file) and § B.4 (tokens `CLAUDE_ENV_FILE`, `session-env/`, `shell-snapshots/`). |
| Suggestion: `git checkout <branch>` row | § B.5 now matches `git checkout-index` and `git read-tree -u` in a live root. The § Risks row now says that remote branch protection does not stop a local commit, and it names the worktree-commit route as a residual. |
| Suggestion: `//` and `/./` | Collapsed before the token search and in path checks (§ B.3, § B.4). |
| Suggestion: hash form | The snapshot and ConfigChange hash `jq -S -c` output (§ B.1, § B.7). A key-order test is added. |
| Suggestion: flip fallback | § D.5: each flip ticket also changes the built-in default in hook code. |
| Suggestion: P12 ConfigChange | Capture P12c records whether a worktree settings edit fires ConfigChange, with its `source` and `file_path`. § B.7 allows a change whose `file_path` is not a live or user settings file. |
| Suggestion: option values | § B.5 consumes `-b`, `-B`, `--orphan`, `-t`, `--track`, `--conflict=`, `-s` and `--source` before it chooses pathspecs. § B.12 item 16 tests `git checkout -b tmp HEAD -- <path>` and `git checkout -b feature`. |

### Security Auditor pass (v5 to v6)

| Finding | What changed |
|---------|--------------|
| S1 (blocking) | § B.1: `pin-ops-root.sh` writes the pin once per `session_id`, only on `startup`, `resume` or `fork`. The snapshot records the pinned ops root. § B and the § C launcher compare the pin with the snapshot and exit 2 on a mismatch. § Context names the old behaviour (`pin-ops-root.sh:73`). `test_pin_write_once.sh` tests a `compact` and a `clear` with a different `$PWD`. P12b records the hook-process `$PWD` after a Bash `cd` and `/compact`. |
| S2 (blocking) | § B.4 "Harness-only state writers": a fixed-name match blocks a tool call that runs `pin-ops-root.sh`, `write-session-snapshot.sh`, `record-subagent-start.sh` or `dispatch-session-start.sh`, for every class, unless the command sets a sandbox `APEXYARD_OPS_PIN_DIR`. Write-once is the second layer. § D.1 states the same cover for the ledger writer. § B.12 item 9 has paired tests, and `bash .claude/hooks/write-rule-excludes.sh` still passes. |
| S3 (high) | § B.3: option-aware operand roles (`-t`, `--target-directory=`, `install -D`, `--remove-source-files`, `--remove-files`), more remove, mode, attribute and link verbs, in-place editors, and decode and convert tools. § B.4 condition 1(3): the closing rule for an unknown verb with a live protected operand, with a read-only allowlist and a script-runner exemption. § B.12 items 8.1 to 8.4 have paired cases. |
| A1 | § B.7: no-snapshot mode blocks only `disableAllHooks: true`, a `hooks` or `env` difference from `git show HEAD:.claude/settings.json` for project settings, and a non-empty `hooks` or `env` in local or user settings. A "don't ask again" write still works after `/clear`. Test 5b. |
| A2 | § B.2 narrows pin-tree protection to `ops-root-*`, `gate-session-*/**`, `resolve-cache-*` and `projctx/**`. The pin tree directory stays a protected ancestor. No shipped skill or agent writes into the pin tree. `pin-ops-root.sh` cleans up pins and caches older than 30 days. |
| A3 | § B.1: a `resume` SessionStart prints a plain-text warning when on-disk hashes differ from the snapshot or the block log has entries. Plain text, because SessionStart adds plain stdout to Claude's context and its dispatcher does not emit one JSON object. |
| A4 | § Risks names `.git/config` in a live root as a fully hidden write. A follow-up ticket covers `.git/config` and `.git/hooks/`. |
| A5 | § B.3 examples and § B.12 item 8.1: `dd of=` and `install -t` on protected paths block. |
| Merge requirements | § B.14 carries the corpus CI test with the closing rule, the resolver tests, the macOS `patch -p0` capture (with the header rule kept and non-literal input with a token blocked), captures P12 to P12c, and the pin-versus-snapshot comparison. |

### Amendment (#1858)

Four small changes to the tamper gates. Three of them have a paired block case and allow case in the suites. The case-blind live-file change has one case only. It runs only on a case-insensitive file system, so Linux CI skips it.

| Change | Effect |
|--------|--------|
| Narrow the pin-tree token | The Bash write gate treats only the pin files, the gate session state, the resolve cache and the project context folder as state. A write to another file in the pin tree, such as a private brief or probe file, passes. This applies to the raw token test and to the working-directory test. |
| Rotate the ConfigChange log | After a `resume` prints the warning, the session-start hook moves the block log to a `.old` file. A later resume shows the warning again only for a new block or a new settings difference. |
| Case-blind live-file test | The ConfigChange hook judges "is this a live settings file" with the same case-blind helper as the other protected-form tests. |
| `find` file-output primary | The `find` verb judges the target of the `-fls` primary, next to `-fprint`, `-fprint0` and `-fprintf`. |

