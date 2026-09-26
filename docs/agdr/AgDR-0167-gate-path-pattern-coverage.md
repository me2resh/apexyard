# Broaden gate path coverage without weakening detection or merge semantics

> In the context of three gate path-coverage gaps (me2resh/apexyard#1390, #1368, #1369), I decided to fix each gap narrowly. The design gate was blind to Astro, MDX, and template UI. The migration gate caught Alembic's own tooling files. A config array override could silently drop default gate coverage, with no signal, for keys that carry a JSON default. The fix adds one shared UI-pattern library, two narrow Alembic exemptions, and an advisory WARN for dropped array defaults. Every existing detection stays intact, and config merge semantics stay unchanged.

## Status

Accepted

## Context

All three fixes touch production files under `.claude/hooks/**` — the
security-critical trust chain (`.claude/rules/role-triggers.md`'s own
definition). Rail 1 of `.claude/rules/agdr-decisions.md` makes a trust-chain change
material at any diff size. This AgDR records the batch as one decision.

**#1390 — design gate blind to Astro/MDX/template UI.** `require-design-review-for-ui.sh`'s
default UI pattern list predates Astro, MDX, and server-side template
engines. A PR that changes only `.astro` files merges with no design-review
marker required. The `/approve-design` skill's step 5 had a second, hard-coded copy of the
pattern list. That copy was narrower than the hook's list. It was out of
sync before this fix.

**#1368 — migration gate catches Alembic's own tooling.** `require-migration-ticket.sh`'s
generic `*/migrations/*` catch-all matches any file under a `migrations/`
directory, any extension. Alembic's `env.py` is its runtime config.
`script.py.mako` is its revision template. Both files sit directly under the
migrations root, in the default `alembic/` layout or in a renamed
`migrations/` layout. Neither file is a migration.

**#1369 — config array overrides silently drop default gate coverage.**
`_lib-read-config.sh`'s merge is `jq -s '.[0] * .[1]'`, which replaces an
array wholesale on override. An adopter who overrides `branch.type_whitelist`
(or any other defaults-JSON array key) to add one entry drops every other
shipped entry with no signal. The issue rates `migration_paths`, `ui_paths`,
and `architecture_paths` as the highest-severity keys. These three keys have
no JSON default. Each hook holds its default in bash. A JSON diff cannot
detect a drop against a default that is not JSON.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **#1390: one shared `_lib-ui-paths.sh`, both consumers call it** | Single list. Cannot drift again. Small diff | The skill's step 5 instructions must trust an agent to follow the new bash snippet, same as before |
| #1390 alternative: fix the hook only, leave the skill's copy | Smaller diff | Leaves the exact drift this issue reported. The skill's copy stays a second source of truth |
| **#1368: two narrow `case` arms exempting `env.py`/`script.py.mako` under `alembic/` or `migrations/`** | Fixes the reported false positive. Leaves every existing arm (including the catch-all) unchanged for every other file | Does not broaden the Alembic arm to `*/versions/*.py` for a renamed layout — that is the issue's own "suggested direction", not its acceptance criterion, and is a separate, larger judgement call |
| #1368 alternative: broaden the Alembic arm to any `versions/` dir | Also fixes non-default `script_location` detection gaps | Widens scope beyond the reported bug. Not requested by this batch |
| **#1369: advisory WARN on dropped defaults, merge semantics unchanged** | Matches the maintainer decision recorded in the batch brief. Non-breaking. The documented replace-semantics stays true | Cannot warn for the override-only keys (`migration_paths`, `ui_paths`, `architecture_paths`) that motivated the issue's highest-severity examples — a structural limit, not an oversight. #1401 tracks closing it |
| #1369 alternative: explicit extend/remove syntax (`"key+"` / `"key-"`) | Lets an adopter add one entry without restating the rest | New config syntax. A breaking change to how every array key is read. Explicitly the larger of the two options the issue itself proposed |

## Decision

Chosen, for all three: **the narrowest fix that closes the reported gap
without touching any other behavior.**

- **#1390**: `_lib-ui-paths.sh` now holds the default UI pattern list —
  `.tsx`, `.jsx`, `.vue`, `.svelte`, `.astro`, `.mdx`, `.hbs`, `.njk`,
  `.liquid`, `.css`, `.scss`, `.sass`, `.less`, `design-tokens` — plus the
  `.ui_paths` override read. `require-design-review-for-ui.sh` and
  `/approve-design`'s step 5 both source it instead of keeping their own
  copy. `.hbs`/`.njk`/`.liquid` cover the issue's own "common HTML template
  formats" note. This batch does not add a bare `.html$` pattern. The issue
  author was unsure about it. It would also match generated docs and example
  HTML that are not components.
- **#1368**: `is_migration_path()` gains two `case` arms, ordered before the
  generic `*/migrations/*` catch-all, exempting `alembic/env.py`,
  `alembic/script.py.mako`, `<root>/migrations/env.py`, and
  `<root>/migrations/script.py.mako`. Every other arm — including
  `*/alembic/versions/*.py` and the catch-all itself — is untouched. Only the
  renamed `<root>/migrations/` layout changes behavior. That path segment is
  literally named `migrations`, so it already reached the generic catch-all.
  The default `alembic/` layout never reached that catch-all. Its arm changes
  no result today. It stays as defense against a future bare `alembic/` case.
- **#1369**: `_config_load()` calls a new `_config_warn_dropped_defaults()`
  whenever an overrides file is present. It compares each array path in
  `project-config.defaults.json` with the override. It checks only paths
  that it reaches through object keys, never through an array index. So it
  does not compare a nested array such as `skill_intent.map[0].phrases` a
  second time. It prints one `WARN:` line per dropped array, naming the key
  and every dropped entry,
  to stderr only. The merge result (`_rc_merged`) is unchanged either way.

## Consequences

- A PR that changes only `.astro`/`.mdx`/`.hbs`/`.njk`/`.liquid` files now
  requires a design-review marker before merge, closing #1390's reported
  bypass.
- `/approve-design` step 5 and the merge gate both read the default UI list
  from `_lib-ui-paths.sh`. Both read `.ui_paths` from the PR's own repo
  root, not the ops-fork root. The two checks no longer diverge on
  "does this PR touch UI" for that override. Step 5 still does not apply
  `.ui_paths_exclude`, a narrower, pre-existing gap the hook does not share.
- Editing `env.py` or `script.py.mako` under a renamed `<root>/migrations/`
  layout no longer requires a migration ticket + AgDR. Alembic's default
  `alembic/` layout already exempted both files before this batch. Every
  real revision script — under `alembic/versions/`, a bare `migrations/`
  directory, or any other existing arm — is gated exactly as before. The
  regression suite's selection-parity check (comparing this hook's target
  selection against its parent commit for two `.sql` payloads) still passes
  unchanged. The new arms match by filename only. Django imports every
  module in a `migrations/` package, except names that start with `_` or
  `~`. Such a package can hold a real migration named `env.py`. That file
  is a deliberate, visible bypass a human reviewer sees in the diff, not a
  silent one.
- **Known limits from the security review.** Hakim's LOW-2 proposes a
  narrower Alembic exemption. It would match `<dir>/env.py` only when
  `<dir>/versions/` or `<dir>/script.py.mako` also exists. This batch does
  not add that check. It stays a known limit, not a blocking gap. Hakim's
  LOW-3 is a pre-existing limit, not introduced by this batch. In POSIX
  mode, a failed `source` call exits 1. The hook dispatcher treats that
  exit code as continue, not as blocked. This limit needs its own
  follow-up issue, tracked separately from #1390, #1368, and #1369.
- An operator can override `branch.type_whitelist`, `ticket.prefix_whitelist`,
  or another array key that has a JSON default. The operator now sees a
  `WARN:` line that names each dropped entry. Nothing merges differently —
  array overrides still replace the default wholesale, per the documented,
  unchanged semantics.
- `migration_paths`, `migration_label`, `ui_paths`, `ui_paths_exclude`,
  `design_paths`, `design_paths_exclude`, and `architecture_paths` remain
  outside this WARN's reach, because none has a JSON default to diff
  against. Closing that gap needs a different mechanism than a
  defaults-vs-override JSON diff. #1365's `_override_only_keys` allowlist is
  a different, narrower mechanism. It stops `/update` from flagging these
  keys as deprecated. It does not warn on a dropped default entry. #1401
  tracks the dropped-default gap for these seven keys. #1369's own reporter
  incident used `migration_paths`, one of the seven, so **#1369 is only
  partly addressed by this batch**. #1369 stays open until #1401 closes it.
- This batch does not edit `.claude/project-config.defaults.json`. Open PR
  #1365 edits that file to add `_override_only_keys`. The two PRs should
  rebase cleanly against each other.

## Artifacts

- Issues: me2resh/apexyard#1390, #1368, #1369 (partly addressed — see
  Consequences)
- Follow-up: #1401 (dropped-default detection for the seven override-only
  keys, tracks closing #1369's own residual case)
- Related, unmerged at the time of this record: PR #1365 (`_override_only_keys`
  allowlist, same file, disjoint change, a different mechanism from #1401)
- New: `.claude/hooks/_lib-ui-paths.sh`
- Changed: `.claude/hooks/require-design-review-for-ui.sh`,
  `.claude/hooks/require-migration-ticket.sh`, `.claude/hooks/_lib-read-config.sh`,
  `.claude/skills/approve-design/SKILL.md`
- Tests: `.claude/hooks/tests/test_require_design_review_for_ui.sh`,
  `.claude/hooks/tests/test_require_migration_ticket.sh`,
  `.claude/hooks/tests/test_config_warn_dropped_defaults.sh` (new)
