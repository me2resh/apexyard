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
(tracked as a follow-up — at the time this AgDR was written, Codex carried
the same "live conformance unverified" gap Cursor did; per the GH-840 update
below, Codex's gap has since been closed via live testing, making Cursor the
sole remaining outlier among the four third-party adapters).

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

## Update (GH-840)

Rex's review on #838 named two follow-ups beyond the "generator hardening" fail-loud guard (tracked separately as B1/B2): whether `require-migration-ticket.sh` belongs on `FAIL_CLOSED_HOOKS` alongside the four merge gates, the secrets scanner, and the trust-chain/leak-protection class. This section records that call.

**Decision: yes — added.** `require-migration-ticket.sh` is now in `FAIL_CLOSED_HOOKS` in `bin/sync-cursor-adapter.sh`, wired under Cursor's `preToolUse` event (the same `Edit|Write|MultiEdit` path `require-active-ticket.sh` already uses).

**Rationale.** The `failClosed` boundary this AgDR's Axis 3 established was never "every hook that can block" — it's specifically the hooks whose *silent fail-open* is itself a high-blast-radius outcome: an unreviewed merge slipping through, a secret landing in a public diff, a leaked private-project reference, a direct push to `main`. `require-migration-ticket.sh` belongs in that company for the same reason: it exists precisely because schema/data migrations carry outsized blast radius (data loss, downtime, cross-service coordination — see `.claude/rules/workflow-gates.md` § "Migration Gate (3a)"), and gates the *start* of that work, not just its merge. A crashed or timed-out hook here that fails open would let a migration file get edited with no ticket, no AgDR, and no rollback plan on record — the exact failure the gate exists to prevent, just arriving via hook-crash instead of via a missing ticket. `require-active-ticket.sh` (the general ticket-first gate) deliberately stays fail-open, by contrast: its blast radius on a crash is "an edit proceeds without a ticket reference," a process gap Rex and the merge gate can still catch downstream, not a data-loss-class event.

**What changed:**

- `bin/sync-cursor-adapter.sh` — `require-migration-ticket.sh` added to `FAIL_CLOSED_HOOKS`; the header comment above the array now names the migration blast-radius class explicitly.
- `docs/cursor-adapter.md` — the `failClosed` table's class breakdown gained a "Migration blast-radius" row.
- `.claude/hooks/tests/test_sync_cursor_adapter.sh` — the fixture now wires `require-migration-ticket.sh` under the `Edit|Write|MultiEdit` matcher, with an assertion that it carries `failClosed: true` and a paired assertion that `require-active-ticket.sh` still does not (guards the boundary from drifting either direction).

**Consequence.** The `FAIL_CLOSED_HOOKS` list remains a manually maintained boundary (unchanged from this AgDR's original "Consequences" section) — this update adds one more entry to it, not a new maintenance mechanism. A future security- or blast-radius-relevant hook still needs the same three-part update: the bash array, `docs/cursor-adapter.md`'s table, and a fixture assertion.

## Update (GH-840) — live conformance: install location, CLI scope, and a `failClosed`-vs-delegated-execution correction

The original "Update (GH-840)" section above (the `require-migration-ticket.sh` `failClosed` addition) landed before live conformance testing against a real Cursor.app session and the `cursor-agent` CLI. That testing (2026-07-09) produced three findings this section records, two of which change what adopters should actually run.

**Finding 1 — the adapter must install at the USER level, not project level.** Cursor 3.x's own "Open config" points at `~/.cursor/hooks.json`. A project `.cursor/hooks.json` — what `bin/sync-cursor-adapter.sh` generates without `--user`, and what this AgDR originally specified as the sole output — showed `Configured Hooks (0)` in a real Cursor.app 3.10.20 session: never loaded, no trust prompt. The *identical* generated file, installed at `~/.cursor/hooks.json` instead, showed `Configured Hooks (1)` and was loaded and enforced. This was a **location bug, not a schema bug** — `version: 1`, the `beforeShellExecution` event, and `failClosed` were already correct; only the write target was wrong.

**Finding 2 — `cursor-agent` (the CLI) does not read `hooks.json` at all.** Instrumented every generated `beforeShellExecution` entry to log on fire, then ran a benign command through `cursor-agent -p -f`: the command executed and the log stayed empty. `cursor-agent` enforces via its own `~/.cursor/cli-config.json` `permissions.allow`/`deny` model — a different, undocumented-by-this-adapter surface. This AgDR's Scope section already excluded CLI agent-config surfaces by omission (it only ever discussed the Cursor IDE); this finding makes that exclusion explicit and confirmed rather than merely unaddressed.

**Finding 3 — observed IDE enforcement is `failClosed`, not confirmed clean delegated execution.** With the adapter correctly installed at the user level, a real Cursor.app 3.10.20 agent turn's `git add .` was blocked and nothing staged. But the delegated hook's own instrumentation (a log write on fire) never wrote, and the agent explained the block by grepping `block-git-add-all.sh`'s source rather than citing execution output — and separately reported `MainThreadShellExec not initialized` when the shell-exec path was probed directly. The defensible read: Cursor's hook-runner could not cleanly exec the delegated bash command in this version, and `failClosed: true` (Axis 3's hardening, chosen for a different reason — hardening against hook *crashes*) denied the action because the hook-runner itself errored, not because `block-git-add-all.sh` ran and returned exit 2. This is materially weaker than what Axis 2's "proven end-to-end against a real gate hook" language in this AgDR's original Consequences section claimed — that proof was against a synthetic fixture (`test_sync_cursor_adapter.sh`), not a live Cursor session, and the live session does not confirm the same execution path holds.

**Decision — corrections to ship, not just observations to record.**

1. **`bin/install-cursor-adapter.sh` is added** as the primary entrypoint (mirroring the pi/opencode adapters' install-script pattern from #844/#845): it merges the same generated hooks.json content into `~/.cursor/hooks.json`, preserving any pre-existing non-apexyard entries there, with a timestamped backup before every write and a symmetric `--uninstall`.
2. **`bin/sync-cursor-adapter.sh` gains `--user [--user-dir <path>]`**, reusing its existing jq generation pipeline unchanged and adding only the merge-into-user-config write path — no gate logic forked. Default (no `--user`) behaviour, and the tests exercising it, are unchanged; project-level generation is kept available (useful for inspection, for a possible future Cursor version that reads project config, or for adopters who want to track the generated file), documented as no longer the load-bearing install path.
3. **Docs corrected to state the install-location finding as fact, not a caveat** — `docs/cursor-adapter.md` and `docs/harnesses/cursor.md` lead with "install at the user level" rather than mentioning it as a footnote.
4. **The `failClosed`-vs-delegated-execution gap is documented as an open, unresolved limitation**, not glossed over as "delegation confirmed." Both docs pages now say plainly: enforcement observed so far blocks *known-bad* commands, but does not yet prove the gate's actual decision logic (as opposed to a hook-runner error) is what's running. Whether Cursor's `beforeShellExecution` can cleanly exec an external script in agent mode at all remains an open investigation.
5. **`cursor-agent` non-coverage is stated plainly**, not implied by omission — both docs pages and `bin/install-cursor-adapter.sh`'s own output now say the CLI is not addressed and enforces via a separate `cli-config.json` permissions model.

**What did NOT change:** the event-mapping table (Axis 1), the `beforeShellExecution` stdin remap (Axis 2), and the `failClosed` hook list (Axis 3, plus the `require-migration-ticket.sh` addition above) are all unaffected — the schema this AgDR chose was correct throughout; only the install target and the honesty of the delegated-execution claim needed fixing.

**Consequence.** `.claude/` remains the sole source of truth for gate logic; nothing here forks it. The `FAIL_CLOSED_HOOKS` list is now doing double duty on Cursor specifically: its originally-intended role (hardening against a genuinely crashed or timed-out hook) and, per Finding 3, most of the *actually observed* enforcement on the current Cursor release — a fact worth remembering if a future Cursor update makes delegated execution reliable and this posture ought to be revisited. A live-Cursor conformance test suite (beyond the manual testing this update records) remains a tracked gap; `MainThreadShellExec not initialized` is not yet filed as its own tracked issue as of this writing.

## Artifacts (GH-840 update)

- Refs me2resh/apexyard#840
- `bin/install-cursor-adapter.sh` (new)
- `bin/sync-cursor-adapter.sh` (`--user`/`--user-dir` added)
- `docs/cursor-adapter.md`, `docs/harnesses/cursor.md` (corrected)
- `.claude/hooks/tests/test_sync_cursor_adapter.sh` (`--user` merge/idempotency/drift assertions added)
- `.claude/hooks/tests/test_install_cursor_adapter.sh` (new)
