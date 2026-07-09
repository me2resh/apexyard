# Harness support — Cursor

**Status:** Adapter **merged** (#831 → PR #838, [AgDR-0091](../agdr/AgDR-0091-cursor-adapter-generation.md)); live conformance tested against Cursor.app 3.10.20 + the `cursor-agent` CLI ([#840](https://github.com/me2resh/apexyard/issues/840)) — **install at the USER level** (`bin/install-cursor-adapter.sh`), the CLI is **not covered**, and IDE enforcement currently rests on `failClosed` rather than confirmed clean delegated execution. Read "What's enforced vs advisory today" below before treating this as equivalent to the opencode/pi adapters.

**Cursor is now the sole outlier among the four third-party adapters on live conformance.** opencode and pi are both live-proven (their CLIs genuinely run the delegated extension code). Codex carried the same "live conformance unverified" caveat as Cursor when AgDR-0088/AgDR-0091 were written, but live testing since closed that gap (it was a trust-prompt issue, fixed via `--dangerously-bypass-hook-trust` / a user-level trust grant) — Codex is now live-proven too. Cursor alone remains in the weaker "failClosed blocks known-bad commands, delegated execution not confirmed" state described below.

Cursor support follows the same declarative-generate pattern as Codex: `.cursor/hooks.json`'s content is **generated** from the canonical `.claude/` runtime and every generated hook **delegates to the unmodified `.claude/hooks/*.sh`** — gate logic never forks. The full generate / install / drift-check workflow lives in **[`docs/cursor-adapter.md`](../cursor-adapter.md)** (linked here, not duplicated).

## What's enforced vs advisory today

**Cursor IDE only — the CLI is not covered, confirmed by live test.** `cursor-agent` (the CLI) does not read `hooks.json` at all; instrumented hooks recorded zero fires while a benign command executed cleanly through it. `cursor-agent` enforces via its own `~/.cursor/cli-config.json` `permissions.allow`/`deny` model instead — a different surface this adapter does not address. Everything below is about the Cursor IDE agent (Cursor.app / Composer) only.

**Install location — USER config, not project, confirmed by live test.** A project `.cursor/hooks.json` (Cursor's documented location, and what earlier revisions of this adapter shipped) showed `Configured Hooks (0)` in a real Cursor.app 3.10.20 session — never loaded. The identical file installed at `~/.cursor/hooks.json` loaded and enforced. Use `bin/install-cursor-adapter.sh`, which merges into the user config by default and preserves any pre-existing, non-apexyard entries there.

**Delegated (blocking) — but via `failClosed`, not confirmed clean execution.** Cursor's hook contract natively treats **exit code 2 as deny**, so in principle the bash hooks' block semantics pass through without translation, and the in-repo smoke test (`.claude/hooks/tests/test_sync_cursor_adapter.sh`) proves that delegation by construction inside a synthetic fixture. The live IDE test went further: a real agent turn's `git add .` was blocked. But the delegated hook's own instrumentation never fired and the agent reported `MainThreadShellExec not initialized` — the most defensible read is that Cursor's hook-runner could not cleanly exec the delegated bash command in this version, and `failClosed: true` denied the action because the hook errored, not because the gate logic evaluated and returned exit 2. **This is weaker than the opencode/pi adapters**, where the delegated bash genuinely runs — a command a gate would *allow* may also fail closed here. Treat it as "known-bad commands get blocked," not as "the gate logic runs." Full detail: [`docs/cursor-adapter.md`](../cursor-adapter.md) § Known Limitations.

**failClosed hardening:** the 10 security-critical gates (merge gates, red-CI, design/architecture review, secrets scan, migration blast-radius, trust-chain/leak hooks) are generated with Cursor's `"failClosed": true` — a crashed, timed-out, **or non-executing** gate hook **blocks** instead of failing open. Given the finding above, this is now doing double duty on Cursor: its originally-intended hardening role, and (unintentionally, for now) most of the actual observed enforcement. Advisory/process hooks stay fail-open, matching their native behaviour.

**Advisory:** a generated `.cursor/rules/apexyard.mdc` carries the advisory governance bridge (git conventions, ticket vocabulary, reporting rules) as Cursor rules content, at the project level (unaffected by the user-vs-project hooks.json finding).

## How it works (transport)

`bin/sync-cursor-adapter.sh` generates the hooks.json content from `.claude/settings.json`; `bin/install-cursor-adapter.sh` merges that content into `~/.cursor/hooks.json` (the location that actually loads):

- **Event mapping:** `Bash` → `beforeShellExecution` · `Edit|Write|MultiEdit` → `preToolUse` (matcher) · `SessionStart` → `sessionStart` · `UserPromptSubmit` → `beforeSubmitPrompt`, with post-tool events split the same way.
- **Stdin remap:** Cursor delivers the shell command top-level (`{"command": …}`); the generated command re-wraps it into the Claude-Code shape (`{"tool_name":"Bash","tool_input":{"command":…}}`) before piping to the hook — so the hooks run byte-identical logic on both harnesses.
- Claude Code's handler-level `if` predicates are compiled into the same `Bash(glob)` preflight filter the Codex adapter uses; unconditional hooks get glob `*` (remapped, never skipped).
- No hook bodies are copied; every entry execs `$r/.claude/hooks/*.sh`.
- **User-level merge:** apexyard's own entries (identified by every command execing a `.claude/hooks/*.sh` script) are replaced wholesale on each install; anything else already in `~/.cursor/hooks.json` — the user's own hooks, or a different tool's — is preserved untouched.

## How to install / generate

```bash
bin/install-cursor-adapter.sh            # merge into ~/.cursor/hooks.json (the loaded location) + refresh project rules
bin/install-cursor-adapter.sh --uninstall # remove only apexyard's entries from ~/.cursor/hooks.json

bin/sync-cursor-adapter.sh               # project-level generation only — kept available, NOT loaded by Cursor 3.x on its own
bin/sync-cursor-adapter.sh --check       # verify generated project files still match .claude/ (non-zero on drift)
bin/sync-cursor-adapter.sh --user --check  # verify the installed USER config still matches .claude/ (non-zero on drift)
```

## Gaps + tracking

- **Whether Cursor's `beforeShellExecution` can cleanly exec an external script in agent mode at all** is an open investigation (`MainThreadShellExec not initialized`, #840 finding #4) — not yet a separately filed tracked issue. Until resolved, enforcement is `failClosed`-backed, not confirmed delegated-logic-backed.
- The `preToolUse`/`postToolUse` passthrough path (non-shell tools) carries only process/advisory hooks; its `tool_input` field names are unverified against a real Cursor session — the live IDE test only exercised the shell-command path. Also #840.
- A `cursor-agent`-CLI adapter (translating apexyard's gates into `~/.cursor/cli-config.json` permissions) is unscoped future work, not this adapter's job.

## Related AgDRs

- [AgDR-0091](../agdr/AgDR-0091-cursor-adapter-generation.md) — Cursor adapter generation; delegate gates to the `.claude/` runtime
- [AgDR-0088](../agdr/AgDR-0088-codex-adapter-generation.md) — the Codex precedent this adapter mirrors
- [AgDR-0086](../agdr/AgDR-0086-hooks-stay-bash-not-ported.md) — hooks stay bash (the source of truth the adapter execs)

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
