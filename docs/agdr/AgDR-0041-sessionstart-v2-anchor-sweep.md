# SessionStart hook wrappers must recognise both ops-fork anchors

> In the context of split-portfolio v2 (framework #242) moving `onboarding.yaml` from the public fork to the private sibling repo, facing every SessionStart / PreToolUse / PostToolUse wrapper in `.claude/settings.json` walking up looking for `onboarding.yaml` only, I decided to sweep every wrapper to recognise BOTH `.apexyard-fork` AND `onboarding.yaml` (whichever appears first, mirroring `_lib-ops-root.sh`), to achieve a single canonical wrapper shape that works under single-fork, split-portfolio v1, AND split-portfolio v2 layouts, accepting that wrappers can't source the helper directly (they run as `bash -c`, no `$0` script path) so the v2 anchor check is inlined verbatim instead of via the lib.

## Context

Pre-#242, every adopter's ops fork had `onboarding.yaml` + `apexyard.projects.yaml` at the root. The walk-up shape baked into every `.claude/settings.json` hook wrapper was:

```bash
r=$PWD; while [ ! -f "$r/onboarding.yaml" ] && [ "$r" != / ]; do r=${r%/*}; done; exec "$r/.claude/hooks/<name>.sh"
```

PR #242 (split-portfolio v2) moved `onboarding.yaml` and `apexyard.projects.yaml` into the private sibling repo. The public fork is anchored solely by the new `.apexyard-fork` marker file. Inside a v2 fork, the legacy walk-up:

- Never finds `onboarding.yaml` going up the tree (it's now in a sibling repo)
- Walks all the way to `/`
- At `/`, the loop guard `[ "$r" != / ]` becomes false → exit, then `exec "$r/.claude/hooks/<name>.sh"` becomes `exec "/.claude/hooks/<name>.sh"` which doesn't exist → exec fails silently
- OR: on shells where `${r%/*}` on a single-segment path returns the empty string, `r=""`, the guard `[ "" != / ]` stays true and the loop runs forever — confirmed in testing: 50 iterations stuck at `r=""`

Either failure mode means v2 adopters get **zero SessionStart banners**: no upstream-drift, no jq-missing, no portfolio-config-broken, no onboarding-not-run, no bootstrap-marker sweep, no custom-skill linking. Silent regression for the entire v2 layout.

The same legacy walk-up appears in 35+ PreToolUse / PostToolUse entries — same failure mode applies. v2 forks under PreToolUse get no migration-ticket check, no ticket-first gate, no AGdR check, no merge gates, no leak protection, no anything.

PR #300 (the `check-jq-installed.sh` hook) shipped using the same legacy shape, and Rex caught it during code review — surfacing this as a framework-wide bug rather than a single new-hook bug. Filed as #302.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A. Source `_lib-ops-root.sh` from the wrapper** | Single source of truth for the anchor check; can't drift. | `bash -c '...'` has no `$0` script path (`$0` is `bash`), so `dirname "$0"` doesn't yield the hooks dir. You'd have to walk up yourself first to find the lib, defeating the point. Rejected. |
| **B. Inline the v2-aware walk-up in every wrapper** | Self-contained; matches what the lib does internally; one canonical shape. | Logic duplicated across ~35 wrapper entries; if the anchor set changes again, both the lib and every wrapper need updating. Acceptable: anchors don't change every release. |
| **C. Replace wrappers with a single dispatch script (`.claude/hooks/_dispatch.sh <name>`)** | DRY — anchor check lives in one place. | Adds an extra hop on every hook invocation; introduces a script lookup before any hook can run; failure modes get worse if the dispatch script itself can't be located. Defer. |
| **D. Drop the wrapper walk entirely, exec from `$PWD/.claude/hooks/<name>.sh`** | Simpler. | Breaks when the operator works in `workspace/<project>/` — `$PWD` is the project clone, not the ops fork. Project clones don't have framework hooks. Rejected. |
| **E. Push the walk into the Claude Code runtime — runtime resolves hook paths from the ops-fork root, not from `$PWD` via `bash -c`** | Cleanest — no inline walk in any wrapper, no dispatch hop, no lib-sourcing dance. The runtime already knows where the project root is. | Needs an upstream Claude Code change (settings.json semantics + how hook commands are resolved). Out of this PR's scope. Defer; this AgDR's Option B is the right shape until the runtime grows that ability. |

## Decision

Chosen: **Option B — inline the v2-aware walk-up in every wrapper**, with three explicit checks:

```bash
r=$PWD; \
while [ ! -f "$r/.apexyard-fork" ] && \
      [ ! -f "$r/onboarding.yaml" ] && \
      [ -n "$r" ] && \
      [ "$r" != / ]; do \
  r=${r%/*}; \
done; \
exec "$r/.claude/hooks/<name>.sh"
```

Three deliberate properties:

1. **`.apexyard-fork` checked first.** Cheapest test (single `-f` against a marker that, by convention, only ever sits at the ops-fork root) and the v2 anchor. Mirrors `_lib-ops-root.sh`.
2. **`onboarding.yaml` checked second as the legacy v1 fallback.** This is a relaxation from `_lib-ops-root.sh`'s v1 check (which requires BOTH `onboarding.yaml` AND `apexyard.projects.yaml`). The wrapper's job is to find the dir containing `.claude/hooks/<name>.sh`, not to establish "this is definitely the ops fork" — checking either marker is sufficient because the hook itself can re-resolve ops-root via the lib if it needs framework state. Reducing to one check makes the wrapper shorter without losing safety.
3. **`[ -n "$r" ]` guard.** Closes the empty-string infinite-loop failure mode: when `${r%/*}` on `/foo` yields `""`, the loop must exit. The legacy shape didn't have this and would either hang or fall through depending on shell semantics.

The wrapper's only job remains: find the dir containing `.claude/hooks/<name>.sh` and exec it. The hook does any further framework-state resolution via `_lib-ops-root.sh` internally — that pattern is well-established in `check-portfolio-config.sh`, `clear-bootstrap-marker.sh`, `clear-issue-skill-marker.sh`, `check-jq-installed.sh`, and (post-this-AgDR) `link-custom-skills.sh`.

## Consequences

- **No regression for v1 adopters.** Single-fork and split-portfolio v1 forks have `onboarding.yaml` at the root; the wrapper finds it the same as before.
- **v2 adopters get the same banners + hooks as v1.** `.apexyard-fork` is at the v2 fork root; the wrapper finds it first and exec's the hook. SessionStart banners, PreToolUse gates, PostToolUse follow-ups all fire correctly under v2.
- **No more silent infinite-loop on v2 forks that somehow lack both anchors** (a misconfigured fork or a test fixture). The `-n "$r"` guard makes the loop exit cleanly with `r=""`, and the subsequent `exec ""/.claude/hooks/<name>.sh` fails fast in a visible way.
- **New SessionStart hooks must ship with the v2-aware wrapper from day one.** This AgDR is the citation. PR review should reject new entries that use the legacy shape — Rex catches it as a `settings.json` diff red flag.
- **`link-custom-skills.sh` no longer maintains its own private walk-up.** It now sources `_lib-ops-root.sh` with the same graceful-degradation fallback as `check-jq-installed.sh` and `clear-bootstrap-marker.sh`. One canonical shape across all hooks that resolve ops-root internally.
- **Future anchor changes are an N+1 edit problem.** If v3 introduces a new anchor file, every wrapper needs updating again. Acceptable cost; this is rare and well-flagged (the wrapper sweep is documented in this AgDR + the `_lib-ops-root.sh` header).

## Canonical wrapper shape

For every future SessionStart / PreToolUse / PostToolUse entry in `.claude/settings.json`:

```bash
bash -c 'r=$PWD;while [ ! -f "$r/.apexyard-fork" ] && [ ! -f "$r/onboarding.yaml" ] && [ -n "$r" ] && [ "$r" != / ];do r=${r%/*};done;exec "$r/.claude/hooks/<hook-name>.sh"'
```

For every hook script that needs to resolve framework state (write to `<ops_root>/.claude/session/...`, read `<ops_root>/.claude/project-config.json`, etc.):

```bash
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$HOOK_DIR/_lib-ops-root.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-ops-root.sh"
  ops_root=$(resolve_ops_root "$PWD")
else
  # Graceful-degradation fallback: inline walk-up with both anchors.
  ops_root=""
  cur="$PWD"
  while [ -n "$cur" ] && [ "$cur" != "/" ]; do
    if [ -f "$cur/.apexyard-fork" ]; then ops_root="$cur"; break; fi
    if [ -f "$cur/onboarding.yaml" ] && [ -f "$cur/apexyard.projects.yaml" ]; then
      ops_root="$cur"; break
    fi
    cur=$(dirname "$cur")
  done
fi
```

The fallback's v1 check requires BOTH `onboarding.yaml` AND `apexyard.projects.yaml` — stricter than the wrapper because the hook is now establishing canonical ops-root, not just finding a script path.

## Artifacts

- GitHub issue: [me2resh/apexyard#302](https://github.com/me2resh/apexyard/issues/302)
- Branch: `refactor/GH-302-sessionstart-v2-sweep`
- Related: AgDR-0019 (v2 layout introduction); `_lib-ops-root.sh` lib header documents the helper itself.
- PR #300 (`check-jq-installed.sh`) was the immediate trigger — Rex caught the legacy shape during code review and surfaced the framework-wide gap.
