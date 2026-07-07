/**
 * resolve-ops-root — pi-flavored port of `.claude/hooks/_lib-ops-root.sh`.
 *
 * WHY THIS EXISTS
 * ----------------
 * The bash gate hooks (block-unreviewed-merge.sh and siblings) resolve an
 * "ops root" — the directory holding `.claude/session/reviews/*.approved`
 * markers — via `_lib-ops-root.sh`. That resolution has Claude-Code-specific
 * assumptions baked in:
 *
 *   1. A SessionStart hook (`pin-ops-root.sh`) writes a pin file at
 *      `${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-<SESSION_ID>`,
 *      keyed by `CLAUDE_CODE_SESSION_ID`. pi has no equivalent session-id
 *      env var and no SessionStart hook to write the pin in the first
 *      place, so the pin branch of `_lib-ops-root.sh` is dead code under pi
 *      — it silently falls through to the walk-up, which is fine, but it's
 *      worth being explicit that pi gets NONE of the pin-first safety net
 *      that closed apexyard#381 (the /tmp-clone-resolves-wrong-tree bug).
 *   2. The walk-up anchor conditions themselves (`.apexyard-fork` marker,
 *      or the legacy `onboarding.yaml` + `apexyard.projects.yaml` pair) are
 *      harness-agnostic — they're just files on disk — so THAT part of the
 *      contract ports cleanly.
 *
 * This module reproduces the anchor-walk (condition 2) faithfully in
 * TypeScript, and layers a pi-specific override on top instead of the
 * Claude-Code-specific session pin (condition 1): an explicit
 * `APEXYARD_OPS_ROOT` environment variable, or an explicit `opsRoot` field
 * a pi user can set once in their own extension config. This is a
 * DELIBERATE divergence, not an oversight — see
 * docs/agdr/AgDR-0082-pi-gate-dispatcher-adapter.md for the decision and
 * its consequences.
 *
 * WHAT THIS DOES NOT DO
 * ----------------------
 * It does not touch `_lib-ops-root.sh` — that file remains the single
 * source of truth for Claude Code sessions. This module is a parallel,
 * pi-only resolution path that the dispatcher extension consults before
 * shelling out to a gate hook, so the hook's own bash-side resolution
 * (which re-derives the same answer from $PWD when invoked directly) stays
 * consistent with what the dispatcher already decided.
 */

import { existsSync } from "node:fs";
import { dirname, resolve as resolvePath } from "node:path";

export interface ResolveOpsRootOptions {
  /** Directory to start the walk-up from. Defaults to process.cwd(). */
  startCwd?: string;
  /** Explicit override — highest priority, skips the walk when set and valid. */
  explicitOpsRoot?: string;
  /** Environment lookup, injectable for tests. Defaults to `process.env`. */
  env?: Record<string, string | undefined>;
}

/**
 * Returns true if `dir` satisfies one of the two ops-root anchor
 * conditions apexyard recognises (mirrors `_ops_root_anchor_valid` in
 * `_lib-ops-root.sh`):
 *   - v2: a `.apexyard-fork` marker file is present, OR
 *   - v1 (legacy): both `onboarding.yaml` AND `apexyard.projects.yaml` are present.
 */
export function isOpsRootAnchor(dir: string): boolean {
  if (existsSync(`${dir}/.apexyard-fork`)) return true;
  if (existsSync(`${dir}/onboarding.yaml`) && existsSync(`${dir}/apexyard.projects.yaml`)) return true;
  return false;
}

/**
 * Pure walk-up from `startDir` toward `/`, looking for the first directory
 * that satisfies an ops-root anchor condition. Mirrors
 * `resolve_ops_root_walk` in `_lib-ops-root.sh` line for line.
 *
 * Returns the resolved path, or `undefined` if no ancestor directory
 * satisfies an anchor (the hook's bash equivalent falls back to the
 * caller's own default in that case — same contract here).
 */
export function walkUpOpsRoot(startDir: string): string | undefined {
  let dir = resolvePath(startDir);
  // Cap the walk at a sane depth so a pathological filesystem (symlink
  // loop, extremely deep nesting) can't spin forever — the bash version
  // is bounded by reaching "/", which this loop also respects via the
  // dirname(dir) === dir fixed-point check below.
  for (let i = 0; i < 128; i++) {
    if (isOpsRootAnchor(dir)) return dir;
    const parent = dirname(dir);
    if (parent === dir) break; // reached filesystem root
    dir = parent;
  }
  return undefined;
}

/**
 * pi-flavored ops-root resolver. Priority order:
 *
 *   1. `options.explicitOpsRoot` (or `APEXYARD_OPS_ROOT` env var) — the
 *      pi-specific override this module introduces in place of the
 *      Claude-Code session pin. Validated against the anchor conditions
 *      before being trusted; an invalid override falls through rather
 *      than silently pointing the merge gate at the wrong directory.
 *   2. Walk-up from `options.startCwd` (or `process.cwd()`), identical
 *      logic to `_lib-ops-root.sh`'s `resolve_ops_root_walk`.
 *   3. `undefined` if neither resolves — callers should treat this the
 *      same way the bash hooks do: fall back to the tool-call's own cwd
 *      and accept that markers may not be found (fail toward re-review,
 *      never toward silently allowing).
 */
export function resolveOpsRootForPi(options: ResolveOpsRootOptions = {}): string | undefined {
  const env = options.env ?? process.env;
  const explicit = options.explicitOpsRoot ?? env.APEXYARD_OPS_ROOT;
  if (explicit && isOpsRootAnchor(resolvePath(explicit))) {
    return resolvePath(explicit);
  }
  return walkUpOpsRoot(options.startCwd ?? process.cwd());
}
