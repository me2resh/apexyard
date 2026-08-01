# Centralize Trust-Chain Lib Self-Location Behind One Anchored Helper

> In the context of four `_lib-*.sh` self-location sites the #1100 security review found still using unfixed spellings of the `${BASH_SOURCE[0]}` cwd-substitution bug, facing the risk that a fifth per-site patch would just add a fifth spelling to fix later, I decided to centralize the fail-closed bootstrap guard behind one shared function (`resolve_anchored_lib_dir` in `_lib-ops-root.sh`) to achieve a single point of correctness for this idiom, accepting that the very first hop (locating `_lib-ops-root.sh` itself) can never be fully centralized and still needs a small, uniform, textually-repeated bootstrap snippet at each call site.

## Context

`#1100` patched nine sites of the `${BASH_SOURCE[0]:-}` self-location idiom that, under a non-bash sourcing shell (zsh — notably the Claude Code Bash tool's own execution shell), resolves `dirname "" -> "."` and silently substitutes the caller's `$PWD` for the script's own directory. If the caller's cwd happens to ship a same-named sibling lib, that sibling gets sourced unanchored — an attacker-controlled (or merely coincidental) cwd can smuggle arbitrary code into a trust-chain hook.

The #1100 security review found four more sites the original grep missed, each a **different, uncoordinated spelling** of the same defect:

| Site | Spelling | Problem |
|---|---|---|
| `_lib-read-config.sh` (`_config_repo_root`) | `${BASH_SOURCE[0]:-}` | Guard present for the immediate `dirname` step, but the eventual `git rev-parse --show-toplevel` fallback had no anchor check of its own — see "Divergence from the initial brief" below |
| `_lib-extract-push-ref.sh` | `${BASH_SOURCE[0]}` | No `:-` guard at all — a hard reference, not merely an unguarded one |
| `_lib-git-hooks-path.sh` | `${BASH_SOURCE[0]:-$0}` | A **fake fix**: under zsh, `$0` inside a sourced file is the sourcing invocation path *as typed*, not a reliable self-location signal — it inherits the same cwd-substitution hazard `:-` alone has |
| `_lib-protected-branches.sh` (`protected_branch_regex`) | `${BASH_SOURCE[0]:-$0}` | Same fake fix, but inside a function body rather than at top level |

Four independent spellings for the same fix is exactly the failure mode that regenerates this defect: the next site added to `.claude/hooks/` has no single place to copy the fix from, so it either re-derives its own (possibly-broken) variant or gets missed by the next grep too.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Patch each of the four sites independently, matching the exact idiom `#1100` already used (`hook_dir=...; if [ -z "${BASH_SOURCE[0]:-}" ]; then hook_dir=""; fi`) | Minimal diff per site, proven idiom | Adds a FIFTH copy of the same logic (nine existing + four new = thirteen instances); does nothing to stop a future site from drifting again |
| Centralize the **entire** self-location bootstrap (including finding `_lib-ops-root.sh` itself) behind one sourced function | Maximal DRY | **Structurally impossible.** To call a function defined in `_lib-ops-root.sh`, a call site must already have safely located that file — which is the exact problem the function exists to solve. A sourced helper cannot bootstrap its own discovery. |
| Centralize only the **fail-closed guard step** (`resolve_anchored_lib_dir`) behind one function in `_lib-ops-root.sh`; accept a small, uniform, repeated bootstrap snippet at each site to reach that function in the first place | One canonical place for the guard's actual logic; the repeated part is a fixed ~10-line idiom, not four divergent spellings; matches the shape `#1100` already established (that fix was itself a repeated idiom, just not function-backed) | The bootstrap snippet is still duplicated textually at every site (chosen; see Decision) |

## Decision

Chosen: **centralize the guard, accept the irreducible bootstrap** — because the four broken spellings prove that leaving *any* part of this logic to be re-derived per-site produces drift, and the bootstrap-can't-bootstrap-itself constraint means the "centralize everything" option is not actually available, only asymptotically approachable.

### `resolve_anchored_lib_dir` (`_lib-ops-root.sh`)

```sh
resolve_anchored_lib_dir() {
  local raw="${1:-}"
  [ -n "$raw" ] || return 1
  local dir
  dir="$(cd "$(dirname "$raw")" 2>/dev/null && pwd)" || return 1
  [ -n "$dir" ] || return 1
  printf '%s' "$dir"
  return 0
}
```

Callers pass their own `${BASH_SOURCE[0]:-}` explicitly (a function in a sourced lib cannot see the *caller's* array slot 0 — `BASH_SOURCE[0]` inside the function refers to `_lib-ops-root.sh` itself). The function is a single fail-closed guard: empty input (the zsh case) returns nothing; a genuine `BASH_SOURCE[0]` is resolved via `cd`+`pwd` exactly as before. All four sites now share this one implementation instead of four spellings of it.

### The irreducible bootstrap

Every call site still needs this shape to reach `_lib-ops-root.sh` in the first place:

```sh
_RAW="${BASH_SOURCE[0]:-}"
LIB_DIR=""
if [ -n "$_RAW" ]; then
  _CANDIDATE="$(cd "$(dirname "$_RAW")" 2>/dev/null && pwd)"
  if [ -n "$_CANDIDATE" ] && [ -f "$_CANDIDATE/_lib-ops-root.sh" ]; then
    . "$_CANDIDATE/_lib-ops-root.sh"
    command -v resolve_anchored_lib_dir >/dev/null 2>&1 && LIB_DIR="$(resolve_anchored_lib_dir "$_RAW")"
  fi
fi
```

This is not a regression to the four-spelling problem: it is now **one** fixed idiom, applied identically at all four sites (and documented identically, each site's own "SELF-LOCATION BOOTSTRAP" comment references this AgDR and `resolve_anchored_lib_dir`'s header for the full reasoning). The risk of *this* snippet drifting is much lower than the original bug's, because it contains no branching logic to get subtly wrong — it is a single existence check, structurally incapable of a "fake fix" variant the way `:-$0` was.

### Divergence from the initial brief — the `_lib-read-config.sh` fallback stays UNANCHORED

The task brief that produced this fix asked for a second change: make `_lib-read-config.sh`'s `git rev-parse --show-toplevel` fallback (used when no `.apexyard-fork` / `onboarding.yaml`+`apexyard.projects.yaml` anchor is found above `$PWD`) **anchored by default**, with bare-clone/CI usability preserved via an explicit `APEXYARD_ALLOW_UNANCHORED_CONFIG=1` opt-in.

**I implemented that shape, then reverted it after it broke real, already-shipped behavior**, discovered empirically via `test_lib_protected_branches.sh` (4 of 16 cases failed) and confirmed across `test_githooks_pre_commit_protected_branch.sh`, `test_check_git_hooks_installed.sh`, and `test_validate_branch_name_heredoc.sh`. The mechanism:

- `_lib-read-config.sh` is sourced **transitively** by `_lib-protected-branches.sh`, `validate-branch-name.sh`, `require-active-ticket.sh`, and the `.githooks/pre-push`/`pre-commit` install path.
- All of those run **standalone inside every managed project's own git hooks** — not just inside the apexyard ops fork's Claude Code session. A managed project correctly has neither `.apexyard-fork` nor the onboarding pair; those markers are ops-fork-specific by design.
- Gating the fallback on that anchor therefore silently degraded every managed project's own `.claude/project-config.json` (e.g. its own `.git.protected_branches[]`) to the framework default the instant the resolver ran under a shell where `BASH_SOURCE[0]` was unusable — which, notably, is not even an exotic edge case: it is what happens whenever a hook is invoked in a way that lands in this fallback branch at all.
- **This fallback was never actually reachable through the reported vulnerability.** The bug lives entirely in the *self-location* step (finding `_lib-ops-root.sh` via a cwd-derived path) — now closed by `resolve_anchored_lib_dir`'s bootstrap guard. `git rev-parse --show-toplevel` is not BASH_SOURCE-derived at all; it is scoped to the actual repo the shell is running in. Trusting "the repo we are actually in" for *that repo's own config* is the file's original, correct, and still-safe design for non-portfolio deployments — the same "legacy behaviour for non-apexyard environments" the pre-#1102 comment already documented.

**Resolution:** the fallback in `_lib-read-config.sh` is left **unconditional**, unchanged from before #1102 (`root=$(git rev-parse --show-toplevel 2>/dev/null)`). The vulnerability-relevant fix in that file is the same `resolve_anchored_lib_dir` bootstrap guard as the other three sites, applied to the step that locates `_lib-ops-root.sh` — not the fallback. No `APEXYARD_ALLOW_UNANCHORED_CONFIG` env var was introduced; there is nothing to opt out of.

This is a **conscious divergence from the initial brief**, made under the brief's own explicit authorization ("if you conclude a different escape-hatch shape is safer, record your reasoning in the AgDR — but never leave a silent unanchored default") — and it is not a silent unanchored default: it is the same git-repo-scoped resolution this file has always used for its own explicitly-documented non-portfolio-fork use case, now reached through a self-location path that is no longer exploitable via cwd substitution. **Flagging this prominently for human review**, per the brief's instruction, since a reviewer may want a narrower anchor (e.g. gated only when running inside a detected Claude Code session) rather than the status quo I restored.

## Consequences

- All four sites (`_lib-read-config.sh`, `_lib-extract-push-ref.sh`, `_lib-git-hooks-path.sh`, `_lib-protected-branches.sh`) now route their self-location through one shared, auditable function (`resolve_anchored_lib_dir`) instead of four independently-maintained spellings.
- The nine sites `#1100` already fixed are untouched — they keep their own already-correct `${BASH_SOURCE[0]:-}` + git-toplevel-anchored-fallback idiom (that idiom is specifically appropriate for `_lib-tracker.sh`/`_lib-fresh-fork.sh`'s **ops-root-resolution** purpose, which genuinely wants the ops-root anchor; see below).
- `resolve_anchored_lib_dir` is deliberately **not** ops-root-anchored (no `.apexyard-fork` / onboarding-pair check) — an earlier draft added that as defense-in-depth and it broke real per-project hook usage the same way the fallback change did, for the same underlying reason (three of the four sites are hook libs deployed into every project's own `.claude/hooks/`, not just the ops fork). The bootstrap guard (never substitute cwd for an unavailable `BASH_SOURCE[0]`) is what actually closes the reported bug; ops-root anchoring is a different, narrower-scope concern that only `_lib-read-config.sh`'s own portfolio-root walk-up (unchanged, pre-existing) needs.
- Under zsh (or any shell where `BASH_SOURCE[0]` is unavailable), all four sites now fail closed to "self-location unavailable" — for `_lib-protected-branches.sh` and `_lib-extract-push-ref.sh`/`_lib-git-hooks-path.sh` this means falling back to the hardcoded safe default (`main|master|dev|develop`) or skipping the sibling entirely, rather than resolving via cwd. A genuine apexyard fork sourced under zsh will not resolve its own config in this narrow case — the same documented trade-off `_lib-read-config.sh`'s existing "run under bash, not zsh" warning already accepts.
- Several pre-existing test sandboxes (`test_lib_protected_branches.sh`, `test_githooks_pre_commit_protected_branch.sh`, `test_check_git_hooks_installed.sh`, `test_validate_branch_name_heredoc.sh`) needed a one-line addition (copy `_lib-ops-root.sh` into the sandbox) because their fixtures now need to satisfy the new bootstrap step to reach the sibling libs they were already testing.

## Artifacts

- `.claude/hooks/_lib-ops-root.sh` — new `resolve_anchored_lib_dir` function
- `.claude/hooks/_lib-read-config.sh`, `_lib-extract-push-ref.sh`, `_lib-git-hooks-path.sh`, `_lib-protected-branches.sh` — migrated onto the shared helper
- `.claude/hooks/tests/test_lib_self_location_cwd_anchor.sh` — extended with a discriminating impostor case per site (BASE reproduces, FIX closes)
- PR: fix(#1102) — centralize trust-chain lib self-location behind one anchored helper
