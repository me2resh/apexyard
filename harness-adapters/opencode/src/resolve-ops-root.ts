/**
 * resolve-ops-root — opencode-flavored port of `.claude/hooks/_lib-ops-root.sh`,
 * reusing the same approach the pi adapter already validated
 * (`harness-adapters/pi/src/resolve-ops-root.ts`; see AgDR-0082).
 *
 * WHY THIS EXISTS
 * ----------------
 * The bash gate hooks resolve an "ops root" — the directory holding
 * `.claude/session/reviews/*.approved` markers and `.claude/hooks/*.sh`
 * itself — via `_lib-ops-root.sh`. That resolution has Claude-Code-specific
 * assumptions baked in:
 *
 *   1. A SessionStart hook (`pin-ops-root.sh`) writes a pin file at
 *      `${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-<SESSION_ID>`,
 *      keyed by `CLAUDE_CODE_SESSION_ID`. opencode has no equivalent
 *      session-id env var and no SessionStart hook to write the pin, so
 *      the pin branch of `_lib-ops-root.sh` is dead code under opencode —
 *      same situation the pi adapter documented, and the same consequence:
 *      opencode gets NONE of the pin-first safety net that closed
 *      apexyard#381 (the /tmp-clone-resolves-wrong-tree bug).
 *   2. The walk-up anchor conditions themselves (`.apexyard-fork` marker,
 *      or the legacy `onboarding.yaml` + `apexyard.projects.yaml` pair) are
 *      harness-agnostic — they're just files on disk — so THAT part of the
 *      contract ports cleanly, unchanged from the pi adapter's version.
 *
 * A DELIBERATE DIVERGENCE FROM PI'S PER-CALL RESOLUTION
 * --------------------------------------------------------
 * pi's dispatcher resolves the ops root on EVERY `tool_call` event, because
 * pi hands the dispatcher a fresh `ctx.cwd` on each event. opencode's
 * plugin lifecycle is different: a plugin function is called ONCE per
 * session, at load time, and receives `directory`/`worktree` in that single
 * call — there is no later opportunity for cwd to differ from what was
 * passed at init. So this module resolves the ops root once, at plugin
 * init, from `directory` (falling back to `worktree`); the gate dispatcher
 * caches that single result for the session rather than re-resolving per
 * tool call. This is a genuine platform difference, not a missed
 * optimization — see `src/gate-dispatcher.ts` for where this is called.
 *
 * WHAT THIS DOES NOT DO
 * ----------------------
 * It does not touch `_lib-ops-root.sh` or the pi adapter's
 * `resolve-ops-root.ts` — both remain their own source of truth for their
 * own harness. This module is a parallel, opencode-only resolution path.
 */

import { existsSync } from "node:fs";
import { dirname, resolve as resolvePath } from "node:path";

export interface ResolveOpsRootOptions {
  /** Directory to start the walk-up from — opencode's PluginInput.directory (or .worktree). */
  startCwd?: string;
  /** Explicit override — highest priority, skips the walk when set and valid. */
  explicitOpsRoot?: string;
  /** Environment lookup, injectable for tests. Defaults to `process.env`. */
  env?: Record<string, string | undefined>;
}

/**
 * Returns true if `dir` satisfies one of the two ops-root anchor
 * conditions apexyard recognises (mirrors `_ops_root_anchor_valid` in
 * `_lib-ops-root.sh`, identical to the pi adapter's own check):
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
 * `resolve_ops_root_walk` in `_lib-ops-root.sh` line for line (same
 * implementation as the pi adapter's `walkUpOpsRoot`).
 *
 * Returns the resolved path, or `undefined` if no ancestor directory
 * satisfies an anchor.
 */
export function walkUpOpsRoot(startDir: string): string | undefined {
  let dir = resolvePath(startDir);
  // Cap the walk at a sane depth so a pathological filesystem (symlink
  // loop, extremely deep nesting) can't spin forever — bounded further by
  // the dirname(dir) === dir fixed-point check below (reaching "/").
  for (let i = 0; i < 128; i++) {
    if (isOpsRootAnchor(dir)) return dir;
    const parent = dirname(dir);
    if (parent === dir) break; // reached filesystem root
    dir = parent;
  }
  return undefined;
}

/**
 * opencode-flavored ops-root resolver. Priority order:
 *
 *   1. `options.explicitOpsRoot` (or `APEXYARD_OPS_ROOT` env var) — the
 *      same override the pi adapter introduced in place of the Claude-Code
 *      session pin, reused here rather than inventing a second variable
 *      name. Validated against the anchor conditions before being trusted;
 *      an invalid override falls through rather than silently pointing the
 *      merge gate at the wrong directory.
 *   2. Walk-up from `options.startCwd` (typically opencode's
 *      `PluginInput.directory`), identical logic to `_lib-ops-root.sh`'s
 *      `resolve_ops_root_walk`.
 *   3. `undefined` if neither resolves — callers should fail toward
 *      re-review (not enforcing), never toward silently allowing on a
 *      resolution error being mistaken for an "allow".
 */
export function resolveOpsRootForOpencode(options: ResolveOpsRootOptions = {}): string | undefined {
  const env = options.env ?? process.env;
  const explicit = options.explicitOpsRoot ?? env.APEXYARD_OPS_ROOT;
  if (explicit && isOpsRootAnchor(resolvePath(explicit))) {
    return resolvePath(explicit);
  }
  return walkUpOpsRoot(options.startCwd ?? process.cwd());
}
