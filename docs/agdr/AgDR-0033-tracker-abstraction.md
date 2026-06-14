# AgDR-0033 — Tracker abstraction for mechanical hooks (`_lib-tracker.sh`)

> In the context of mechanical hooks that verify ticket existence (`/start-ticket`, `validate-pr-create.sh`, `verify-commit-refs.sh`, `validate-branch-name.sh`), facing the failure mode that all four call `gh issue view` directly and therefore silently break for adopters using Linear / Jira / Asana, I decided to introduce a `_lib-tracker.sh` library that dispatches the right CLI based on a new `tracker` config block, to achieve a tracker-agnostic framework with zero behaviour change for the default GitHub adopter, accepting a per-tracker adapter that has to be authored once per supported CLI (gh / linear / jira / asana / custom).

## Context

The ticket-CREATE gate was already tracker-agnostic from #268 (the `ticket.create_command_patterns` list in `project-config.defaults.json` matches `gh issue create`, `linear issue create`, `jira issue create`, etc.). But the **existence-verification** layer was not:

| Consumer | Hardcoded call | Failure mode for non-GH adopters |
|---|---|---|
| `/start-ticket` | `gh issue view <N> --repo <repo> --json ...` | Skill refuses to write the active-ticket marker; all downstream Edit/Write hooks block |
| `validate-pr-create.sh` | `gh issue view` to confirm the ticket exists | Blocks PR creation even when the ticket exists in Linear/Jira |
| `verify-commit-refs.sh` | `gh issue view` per `Closes #N` reference | Blocks commits with valid `Closes LIN-42` references |
| `validate-branch-name.sh` | Hardcoded regex `[A-Z]+-[0-9]+ \| #[0-9]+` | Shape regex was already permissive enough (Linear / Jira IDs pass); no functional gap here today, but the regex was inlined in the hook rather than parameterised, so future stricter shapes would have nowhere to plug in |

The shape regex was already permissive enough for Jira (`TIC-1234`) and Linear (`ENG-123`); the gap was the **existence-verification step** calling `gh`.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| (A) Inline `case "$TRACKER_KIND"` blocks in each consumer | No new abstraction layer; obvious where the dispatch happens | 4 hooks × N tracker kinds = repeated parsing logic per hook; adding a new kind means editing every consumer; per-CLI JSON shapes leak into each hook |
| (B) New `_lib-tracker.sh` library with one `tracker_view` function + adapters | Single place to add a new tracker; per-tracker JSON normalisation done once; consumers stay short and tracker-naive | New file to maintain; consumers do `source` + `tracker_view` instead of direct CLI — slight indirection |
| (C) Shell-out to a runtime config that returns the command template | Most flexible (any operator can drop a script) | Bash-from-config is a code-injection surface; harder to test; loses the per-tracker normalisation step |

## Decision

Chosen: **(B) — `_lib-tracker.sh` library with config-driven kind + per-adapter JSON normalisation**.

The library exposes a small public API:

- `tracker_kind` — echoes the configured kind (`gh` / `linear` / `jira` / `asana` / `custom` / `none`)
- `tracker_id_pattern` — echoes the regex for valid ticket-ID shapes
- `tracker_view <id> [<owner_repo>]` — dispatches the configured view command, emits normalised JSON `{state, title, url, labels}` on stdout, exit 0 if ticket exists; non-zero otherwise
- `tracker_state <id> [<owner_repo>]` — convenience that prints just the `.state` field
- `tracker_clear_cache` — resets per-process caches (test-only)

Behind the public API, six internal adapters parse the underlying CLI's JSON into the common shape:

| Adapter | CLI assumption |
|---|---|
| `gh` | `gh issue view {id} --repo {owner_repo} --json state,title,url,labels` — labels come back as `[{name, …}]`, flattened to string array |
| `linear` | `linear issue view {id} --json` — state may be string or `{name}`; both shapes handled |
| `jira` | `jira issue view {id} --raw` (ankitpokhrel/jira-cli format) — reads `.fields.status.name`, `.fields.summary`, `.self`, `.fields.labels` |
| `asana` | `asana task get {id} --json` — derives state from `.completed` boolean (true → `"Closed"`, false → `"Open"`) |
| `custom` | Pass-through — operator-supplied command is assumed to emit shaped JSON; optional `.tracker.normalise_jq` expression can remap raw output |
| `none` | No-op — exits 1 so callers fall back to shape-only verification |

Closed-state recognition in the consumer hooks is broadened from a literal `CLOSED` match to a case-insensitive set: `closed` / `done` / `cancelled` / `canceled` / `resolved` / `completed`. This matches the workflow-state vocabulary across the four supported trackers without requiring per-kind branching in the consumers.

The `view_command` template uses `{id}` and `{owner_repo}` placeholders so the same dispatcher works regardless of whether the tracker has a per-repo concept. The default config preserves today's behaviour exactly:

```json
"tracker": {
  "kind": "gh",
  "view_command": "gh issue view {id} --repo {owner_repo} --json state,title,url,labels",
  "id_pattern": "^(#[0-9]+|GH-[0-9]+|[A-Z]{2,10}-[0-9]+)$"
}
```

The upstream-fallback logic (#207) — important for fork → upstream PRs in `me2resh/apexyard`-style adopter forks — is **kept inside each consumer** rather than pushed into the library, because it's GH-specific (Linear / Jira / Asana don't have a fork-of-a-tracker concept). Each consumer gates the upstream lookup on `[ "$TRACKER_KIND" = "gh" ]`.

## Consequences

**Zero behaviour change for existing GH adopters.** The default config matches today's calls byte-for-byte (same template, same flags, same JSON fields requested). The regression test in `test_tracker_aware_hooks.sh` exercises this path with a mock `gh` to lock the default in.

**Adding a new tracker is one file edit.** Drop a `view_command` template + `id_pattern` into `.apexyard/project-config.json` and (if its JSON shape doesn't match the lib's six built-in adapters) write a `normalise_jq` expression. No hook edits required.

**Per-tracker authentication remains the operator's problem.** The lib doesn't try to set up `gh auth login` / `linear login` / `jira config init`. If the CLI is missing or unauthenticated, `tracker_view` exits non-zero with empty stdout — the consumers see "ticket not found" and emit a clear blocked-message that points the operator at their CLI's docs.

**`none` is a documented escape hatch, not a footgun.** It's the right answer for adopters whose tracker has no CLI and no scriptable HTTP endpoint. Shape validation via `tracker_id_pattern` still happens; existence verification is skipped with an advisory in the relevant consumer.

**The library is bash-only.** No new language dependencies — same shape as `_lib-portfolio-paths.sh` and `_lib-read-config.sh`. Tested on the macOS bash 3.2 / Linux bash 5.x split that the rest of the hook suite targets.

## Artifacts

- `.apexyard/hooks/_lib-tracker.sh` — new library
- `.apexyard/project-config.defaults.json` — new `tracker` block
- `.apexyard/hooks/validate-pr-create.sh` — refactored to call `tracker_view`
- `.apexyard/hooks/verify-commit-refs.sh` — refactored to call `tracker_view`
- `.apexyard/hooks/validate-branch-name.sh` — regex sourced from `tracker_id_pattern`
- `.apexyard/skills/start-ticket/SKILL.md` — refactored to use the tracker lib
- `.apexyard/hooks/tests/test_tracker_aware_hooks.sh` — regression + Linear / Jira / none / custom coverage
- `.apexyard/rules/git-conventions.md` — points at `tracker.id_pattern` instead of hardcoding the regex
- `docs/multi-project.md` — Linear/Jira/Asana setup examples added to the FAQ
- me2resh/apexyard#283
