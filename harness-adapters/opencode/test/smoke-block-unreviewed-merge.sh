#!/usr/bin/env bash
# smoke-block-unreviewed-merge.sh — proves the REAL, unmodified
# block-unreviewed-merge.sh blocks a fabricated `gh pr merge` command when
# driven through this adapter's full pipeline (settings.json -> derived
# gate table -> real subprocess exec -> exit-code -> throw), not through a
# mock.
#
# WHAT THIS PROVES (and doesn't)
# --------------------------------
# This is "proven live against the real hook" for everything downstream of
# the opencode transport boundary: the real settings.json parse, the real
# gate-matching, the real subprocess spawn of the real
# block-unreviewed-merge.sh, and the real exit-code -> throw mapping. It
# does NOT prove opencode's own internal tool.execute.before dispatch calls
# this handler with a matching event shape during a real, model-driven
# opencode session in THIS environment — that gap is documented in
# docs/opencode-adapter.md as the one AC this build could not directly
# re-verify (no live opencode session / model credentials available here).
# Spike #816 already closed that exact gap once, live, with a real model
# turn (see the spike findings in the linked ticket); this script re-proves
# the transport boundary in a fixture repo so local/CI runs can catch a
# regression in the adapter itself without needing opencode credentials.
#
# A negative control (a fixture ops root with NO block-unreviewed-merge.sh
# present) proves the block observed in the positive case comes from the
# hook actually running, not from some always-throw bug in the dispatcher.
#
# RUN
# ---
#   bash harness-adapters/opencode/test/smoke-block-unreviewed-merge.sh
#
# Requires: node >=22, bash, jq, gh (same hard dependencies the framework's
# own hooks already require — see AgDR-0038). The fabricated command below
# targets a nonexistent PR/repo so block-unreviewed-merge.sh's own
# `gh pr view` HEAD-resolution call fails fast and falls back to local HEAD
# (its own documented fallback path) rather than hanging — no real GitHub
# state is needed for this script to pass.

set -euo pipefail

ADAPTER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRAMEWORK_ROOT="$(cd "$ADAPTER_ROOT/../.." && pwd)"

TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-opencode-smoke.XXXXXX")
trap 'rm -rf "$TMPDIR"' EXIT

POSITIVE_ROOT="$TMPDIR/positive"
NEGATIVE_ROOT="$TMPDIR/negative"
mkdir -p "$POSITIVE_ROOT/.claude" "$NEGATIVE_ROOT/.claude"

# Positive fixture: a real, unmodified copy of .claude/hooks/ + the real
# settings.json wiring, so the full derive-from-settings.json pipeline runs
# end-to-end, not just a single hardcoded gate.
cp -R "$FRAMEWORK_ROOT/.claude/hooks" "$POSITIVE_ROOT/.claude/hooks"
cp "$FRAMEWORK_ROOT/.claude/settings.json" "$POSITIVE_ROOT/.claude/settings.json"
touch "$POSITIVE_ROOT/.apexyard-fork"
# No .claude/session/reviews/ markers — the fixture has no Rex/CEO approval
# for any PR, so the merge gate must block regardless of network/gh state.

# Negative control: same settings.json wiring, but NO hook scripts are
# present at all (empty .claude/hooks/) — every derived gate's own
# existsSync(hookPath) check makes it a no-op, so this must NOT throw. That
# proves the positive case's block comes from a hook actually running, not
# from the dispatcher blocking unconditionally. (Removing only
# block-unreviewed-merge.sh is not a clean control here: the merge-shape
# glob also wires block-merge-on-red-ci.sh, require-design-review-for-ui.sh,
# and require-architecture-review.sh against the same command, and any one
# of those would still legitimately block — proving nothing about
# block-unreviewed-merge.sh specifically.)
mkdir -p "$NEGATIVE_ROOT/.claude/hooks"
cp "$FRAMEWORK_ROOT/.claude/settings.json" "$NEGATIVE_ROOT/.claude/settings.json"
touch "$NEGATIVE_ROOT/.apexyard-fork"

RUNNER="$TMPDIR/run-case.ts"
cat > "$RUNNER" <<'RUNNER_EOF'
import { pathToFileURL } from "node:url";
import { join } from "node:path";

const [, , adapterRoot, opsRoot, command] = process.argv;
const dispatcherUrl = pathToFileURL(join(adapterRoot, "src", "gate-dispatcher.ts")).href;
const { registerGateDispatcher } = await import(dispatcherUrl);

const hooks = registerGateDispatcher(
  { directory: opsRoot, worktree: opsRoot },
  { resolveOpsRoot: () => opsRoot },
);

try {
  await hooks["tool.execute.before"](
    { tool: "bash", sessionID: "smoke", callID: "smoke-1" },
    { args: { command } },
  );
  console.log("RESULT: ALLOWED (no throw)");
} catch (err) {
  console.log("RESULT: BLOCKED");
  console.log("REASON:", err instanceof Error ? err.message : String(err));
}
RUNNER_EOF

FABRICATED_COMMAND="gh pr merge 999999 --repo apexyard-smoke-fixture/does-not-exist --squash"

# block-unreviewed-merge.sh sources _lib-ops-root.sh, which — when run
# inside a REAL Claude Code session (as this smoke script typically is,
# while being developed/verified) — honors a session-pin env var
# (CLAUDE_CODE_SESSION_ID / APEXYARD_OPS_PIN_DIR) that would resolve marker
# paths to the ambient session's real ops root instead of this script's
# fixture root. A real opencode session never sets that var (it's
# Claude-Code-specific — see resolve-ops-root.ts's header comment), so
# unsetting it here makes the smoke test behave the way it would under a
# real opencode session, not leak into whatever ops root this script
# happens to be developed inside.
RUN_NODE=(env -u CLAUDE_CODE_SESSION_ID -u APEXYARD_OPS_PIN_DIR node)

echo "== Positive case: real block-unreviewed-merge.sh, no Rex/CEO markers =="
POSITIVE_OUTPUT=$("${RUN_NODE[@]}" "$RUNNER" "$ADAPTER_ROOT" "$POSITIVE_ROOT" "$FABRICATED_COMMAND")
echo "$POSITIVE_OUTPUT"

echo ""
echo "== Negative control: same wiring, no hook scripts present =="
NEGATIVE_OUTPUT=$("${RUN_NODE[@]}" "$RUNNER" "$ADAPTER_ROOT" "$NEGATIVE_ROOT" "$FABRICATED_COMMAND")
echo "$NEGATIVE_OUTPUT"

echo ""
FAIL=0
if ! echo "$POSITIVE_OUTPUT" | grep -q "RESULT: BLOCKED"; then
  echo "FAIL: expected the positive case to be BLOCKED by the real hook" >&2
  FAIL=1
fi
if ! echo "$POSITIVE_OUTPUT" | grep -qi "no recorded code-reviewer"; then
  echo "FAIL: expected block-unreviewed-merge.sh's own Rex-approval reason text in the block message" >&2
  FAIL=1
fi
if ! echo "$NEGATIVE_OUTPUT" | grep -q "RESULT: ALLOWED"; then
  echo "FAIL: expected the negative control (hook file absent) to be ALLOWED — a block here would mean the dispatcher blocks unconditionally, not because of the hook" >&2
  FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
  echo "PASS: the real, unmodified block-unreviewed-merge.sh blocks a fabricated merge through the opencode adapter shim, and the negative control confirms the block is hook-driven."
  exit 0
fi
exit 1
