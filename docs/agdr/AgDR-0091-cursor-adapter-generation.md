# AgDR-0091 — Cursor adapter: event-mapped delegation with a stdin remap, fail-closed on the security-critical gates

> In the context of extending the multiharness family (Claude Code · Codex ·
> pi · opencode planned) to Cursor — the largest third-party agent-IDE user
> base, per #831 — facing a hook vocabulary that does not name-match Claude
> Code's (`beforeShellExecution` / `preToolUse` / `postToolUse` /
> `sessionStart` / `beforeSubmitPrompt` vs. `PreToolUse` / `PostToolUse` /
> `SessionStart` / `UserPromptSubmit`) and a shell-command stdin shape that
> puts `command` at the top level instead of nested under
> `tool_input.command`, I decided to generate `.cursor/hooks.json` with an
> explicit event-mapping table, a stdin remap shim scoped to the
> `beforeShellExecution` path, and `failClosed: true` on a fixed list of
> security-critical gates, delegating every hook to the unmodified
> `.claude/hooks/*.sh` scripts exactly as the Codex and pi adapters do, to
> achieve Cursor-native governance without a second gate-logic
> implementation, accepting that field-name conformance for the
> `preToolUse`/`postToolUse` (Edit/Write/Read) path and live-Cursor
> conformance overall remain unverified until a real Cursor session is
> exercised.

## Context

- AgDR-0088 (Codex) and AgDR-0082 (pi) both established the pattern this
  repeats: generate the harness-native hook config from `.claude/settings.json`,
  delegate execution to the existing, unmodified `.claude/hooks/*.sh` scripts,
  never fork gate logic into a second file tree.
- Cursor's hooks system (verified against the live docs,
  <https://cursor.com/docs/hooks>, 2026-07-09) differs from both Codex and pi
  in two structural ways that neither prior adapter had to solve:
  1. **Its event names don't match Claude Code's at all.** Codex's generator
     could keep `PreToolUse`/`PostToolUse`/etc. as literal JSON keys in
     `.codex/hooks.json` because Codex's own hook config uses the same
     top-level event vocabulary. Cursor's events are a different, camelCase,
     more granular set (`beforeShellExecution`, `beforeMCPExecution`,
     `beforeReadFile`, `afterFileEdit`, `preToolUse`, `postToolUse`,
     `sessionStart`, `beforeSubmitPrompt`, …) — a straight key rename does
     not work; an explicit mapping table does.
  2. **Its dedicated shell-command hook (`beforeShellExecution`) puts the
     command at the top level of stdin**, not nested under
     `tool_input.command` the way every `.claude/hooks/*.sh` script parses
     it. This is the literal stdin-remap shim #831 called out by name.
- Cursor's `preToolUse` event, by contrast, *does* carry a `tool_name` /
  `tool_input` envelope close to Claude Code's shape, and for its `Shell`
  matcher the live docs confirm `tool_input.command` is present — genuinely
  no remap needed on that specific path. But Cursor's own tool-type matcher
  vocabulary (`Shell`, `Read`, `Write`, `Grep`, `Delete`, `Task`) is coarser
  than Claude Code's (`Edit`, `Write`, `MultiEdit` are three distinct
  matchers in `.claude/settings.json`), and the live docs do not enumerate
  `tool_input`'s field names for `Write`/`Read` beyond the base envelope —
  so passthrough on that path carries an explicit, documented conformance
  risk (see docs/cursor-adapter.md § Known Limitations).
- Cursor's docs confirm exit code `2` is a **native deny**
  ("equivalent to returning `permission: "deny"`") with no JSON translation
  required — simpler than Codex, which needed a JSON `permission` payload
  translation layer. This removed an entire class of complexity Codex's
  adapter had to solve.
- Cursor is the only adapter target so far that documents a per-hook
  `failClosed` option — a crashed or timed-out hook script BLOCKS instead of
  fails open. Neither Claude Code nor Codex expose this. It is a genuine
  hardening opportunity worth using selectively, not uniformly (uniform
  fail-closed would turn every advisory banner into a potential hard block
  on a transient script failure).

## Options Considered

### Axis 1 — Event mapping strategy

| Option | Pros | Cons |
|--------|------|------|
| Keep Claude Code's literal event names as JSON keys (Codex's approach) | Reuses the exact generator shape, minimal new code | Cursor does not recognize `PreToolUse`/`PostToolUse`/etc. as hook-config keys at all — the config would be silently inert |
| **Explicit per-matcher mapping table (`Bash`→`beforeShellExecution`, `Edit\|Write\|MultiEdit`/`Write`→`preToolUse`+matcher `Write`, `Read\|Glob\|Grep`→`preToolUse`+matcher `Read\|Grep`, `PostToolUse` split the same way, `SessionStart`→`sessionStart`, `UserPromptSubmit`→`beforeSubmitPrompt`)** | Every existing `.claude/settings.json` matcher group lands on the Cursor event closest to its actual semantics; deterministic and testable | Requires maintaining the mapping table by hand if Cursor's event vocabulary changes; coarser Cursor matcher values (no Edit/MultiEdit distinction) is a documented, accepted gap |
| Drop non-Bash/non-shell hooks from the Cursor adapter entirely (ship only merge/secrets/ticket gates that fire on shell commands) | Avoids the field-name conformance risk on the Edit/Write path entirely | Silently drops governance coverage (ticket-first, docs-index maintenance, MCP-reindex suggestions) that Cursor users would reasonably expect parity on; the risk is better documented than hidden |

### Axis 2 — Shell-command stdin shape

| Option | Pros | Cons |
|--------|------|------|
| Target `preToolUse` with matcher `Shell` (its `tool_input.command` field matches ours 1:1 per the live docs — zero remap) | Simplest possible implementation; no remap code at all | `preToolUse` is the generic multi-tool-call event; `beforeShellExecution` is Cursor's dedicated, purpose-built pre-execution block point for shell commands specifically — the semantically closer analog to our per-command `PreToolUse:Bash` matcher, and the one #831 explicitly asked the remap to target |
| **Target `beforeShellExecution`, remap its top-level `command` into `{"tool_name":"Bash","tool_input":{"command":…}}` before delegating** | Matches the ticket's explicit design note; uses Cursor's dedicated shell gate; the remap is one deterministic three-line shell script, testable directly | The remap adds a moving part `preToolUse`+`Shell` wouldn't have needed |

Chosen: `beforeShellExecution` with the remap, per #831's explicit design
note. The three-line shim is a bounded, unit-testable risk; using the
purpose-built shell-execution hook is the more defensible choice for the
governance-critical majority of our gates (merge gates, secrets scan,
ticket-vocabulary validators — all matched on `Bash`).

### Axis 3 — `failClosed` scope

| Option | Pros | Cons |
|--------|------|------|
| `failClosed: true` on every generated hook | Maximum hardening; a crashed script never silently passes | Turns every advisory banner (role-trigger detection, MCP-reindex suggestions) into a potential hard block on a transient jq/bash failure — disproportionate; also diverges from how those same hooks behave under Claude Code today (exit 0 on internal error) |
| `failClosed: false` (Cursor's own default) everywhere, i.e. don't use the option | Zero risk of a new failure mode | Forfeits the one piece of hardening Cursor offers that neither Claude Code nor Codex do; the ticket explicitly calls this out as worth using |
| **`failClosed: true` on a fixed, named list — the four merge gates, the secrets scanner, and the trust-chain/leak-protection class (no-git-add-all, no-direct-main-push, leak-protection scrubber, onboarding-config leak guard)** | Matches the ticket's framing ("mark the security-critical gates … fail-CLOSED") with a defensible, documented boundary; everything else keeps its existing fail-open posture | The boundary is a judgment call — a future security-relevant hook must be added to the list by hand; documented in both this AgDR and `docs/cursor-adapter.md` as the place to extend it |

## Decision

Chosen: **event-mapped delegation with a scoped stdin remap, `failClosed`
on a named security-critical list**, implemented in
`bin/sync-cursor-adapter.sh`:

- `PreToolUse`/`Bash` → `beforeShellExecution`, remapped (Axis 2).
- `PreToolUse`/`{Edit|Write|MultiEdit, Write}` → `preToolUse` + matcher
  `Write`, passthrough. `PreToolUse`/`Read|Glob|Grep` → `preToolUse` +
  matcher `Read|Grep`, passthrough.
- `PostToolUse`/`Bash` → `postToolUse` + matcher `Shell`, passthrough.
  `PostToolUse`/`Write|Edit|MultiEdit` → `postToolUse` + matcher `Write`,
  passthrough.
- `SessionStart` → `sessionStart`, passthrough. `UserPromptSubmit` →
  `beforeSubmitPrompt`, passthrough.
- Handler-level `if: "Bash(glob)"` predicates are compiled into the
  remap shim as a `[[ "$cmd" == $GLOB ]]` preflight filter — the same
  technique Codex's adapter uses for its own `if`-predicate conversion, with
  glob `*` substituted when no `if` was present (so unconditional Bash
  hooks are still remapped, not skipped).
- `failClosed: true` is set on exactly nine hooks:
  `block-unreviewed-merge.sh`, `block-merge-on-red-ci.sh`,
  `require-design-review-for-ui.sh`, `require-architecture-review.sh`
  (merge gates); `check-secrets.sh` (secrets scan); `block-git-add-all.sh`,
  `block-main-push.sh`, `block-private-refs-in-public-repos.sh`,
  `block-onboarding-in-git.sh` (trust-chain / leak protection). The list is
  a bash array (`FAIL_CLOSED_HOOKS`) near the top of the generator, matched
  against the hook script's basename — extend it there when a future hook
  earns the same posture.
- A minimal `.cursor/rules/apexyard.mdc` (`alwaysApply: true`) is generated
  alongside `hooks.json` as the advisory bridge: it states the gates are
  mechanical, lists the five load-bearing rules, and points at `CLAUDE.md` /
  `.claude/rules/*.md` for the rest. It does not inline the framework's SDLC
  content — the gates carry the enforcement; this file is a pointer, per
  #831's "keep it minimal."
- No `.codex/agents/*.toml`-equivalent generation and no `cursor` column on
  `.claude/harness-models.json` — out of scope (see Scope below).

## Scope

**In**: `.cursor/hooks.json` generation with the event-mapping table above,
the `beforeShellExecution` stdin remap, `failClosed` on the named
security-critical list, the `.cursor/rules/apexyard.mdc` advisory bridge,
`--check` drift detection, `--clean` regeneration, and a smoke test that
exercises the delegation boundary (block/allow/skip across the remap,
`failClosed` present/absent by hook class, exit-code preservation on the
`preToolUse` passthrough path, no absolute paths, drift detection).

**Out** (per #831 and consistent with AgDR-0086, "hooks stay bash"):
porting hook logic to TS/JS; Cursor Tab/completions behaviour;
enterprise/team-level hooks distribution; a `cursor` column on
`.claude/harness-models.json` (no agent-config surface analogous to
Codex's `.codex/agents/*.toml` exists for this adapter to populate — see
docs/cursor-adapter.md § Known Limitations); a live-Cursor conformance test
(tracked as a follow-up, same class of gap the Codex adapter carries today).

## Consequences

- `.claude/` remains the sole source of truth for gate logic across all
  three adapters (Claude Code native, Codex, Cursor).
- A Cursor user running `bin/sync-cursor-adapter.sh` gets the same audited
  merge gates, secrets scan, ticket-vocabulary checks, and trust-chain
  protections Claude Code enforces, with the security-critical subset hardened
  fail-closed — a strictly stronger default posture than Codex's adapter
  offers today (Codex has no `failClosed` equivalent to set).
- The `preToolUse`/`postToolUse` (Edit/Write/Read) passthrough path carries
  an accepted, documented conformance risk: Cursor's exact `tool_input`
  field names for those tool types are not verified against a real session.
  If a live-Cursor conformance test later reveals a field mismatch, the fix
  is scoped to that passthrough path — the `beforeShellExecution` remap
  (proven end-to-end against a real gate hook, `block-git-add-all.sh`,
  during generator development) is unaffected.
- The `FAIL_CLOSED_HOOKS` list is a manually maintained boundary, not derived
  automatically from hook content. A future PR that adds a new
  security-critical hook must also add it to this list and to the
  corresponding table in `docs/cursor-adapter.md`, or it silently inherits
  Cursor's fail-open default.
- Regenerating after any `.claude/settings.json` or `.claude/hooks/*.sh`
  change is manual (`bin/sync-cursor-adapter.sh`); `--check` catches drift
  but nothing currently runs it automatically in CI.

## Artifacts

- Refs me2resh/apexyard#831
- `bin/sync-cursor-adapter.sh`
- `docs/cursor-adapter.md`
- `.claude/hooks/tests/test_sync_cursor_adapter.sh`
- Precedent: AgDR-0088 (Codex adapter), AgDR-0082 (pi gate dispatcher adapter), AgDR-0086 (hooks stay bash), AgDR-0087 (frontier-model floor — not applicable here, no model pinning added)
