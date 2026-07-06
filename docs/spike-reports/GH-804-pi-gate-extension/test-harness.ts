/**
 * Isolated proof harness for spike #804 — see pi-gate-extension.md for the
 * full findings writeup.
 *
 * WHAT THIS PROVES, AND WHAT IT DOESN'T
 * --------------------------------------
 * This harness mocks pi's `ExtensionAPI.on()` registration call exactly per
 * the documented `tool_call` event contract (event.toolName, event.input;
 * return { block, reason } | undefined — see the findings doc's "Pi API
 * facts" section for citations) and then invokes the REAL extension
 * (apexyard-merge-gate.ts) with synthetic tool_call events against the
 * REAL, unmodified block-unreviewed-merge.sh hook.
 *
 * This proves BY CONSTRUCTION that:
 *   - the extension correctly reconstructs the hook's stdin contract
 *   - the hook's exit code correctly maps to a pi block/allow decision
 *   - a real, live merge-gate hook's verdict (checked against real GitHub
 *     PR state via `gh`) flows through unchanged
 *
 * It does NOT prove that pi's own runtime calls `tool_call` handlers with
 * this exact object shape at the JS engine level — that would require
 * running this file loaded by the real `pi` binary during a live agent
 * turn, which needs a model API key this sandbox does not have (see the
 * findings doc's "proven live vs proven by construction" section). The
 * mock below is written to match the documented/observed contract as
 * closely as possible so the gap between "mocked" and "real" is a
 * transport detail, not a logic gap.
 *
 * RUN
 * ---
 *   APEXYARD_REPO_ROOT=/path/to/apexyard node test-harness.ts
 *
 * (Node >=22 runs .ts files directly via type-stripping — no build step,
 * matching how pi itself loads extensions via jiti with no compile step.)
 */

import apexyardMergeGate, { type ExtensionAPI, type ExtensionContext, type ToolCallEvent, type ToolCallResult } from "./apexyard-merge-gate.ts";

type Handler = (event: ToolCallEvent, ctx: ExtensionContext) => Promise<ToolCallResult | undefined> | ToolCallResult | undefined;

function makeMockPi(): { pi: ExtensionAPI; handlers: Map<string, Handler> } {
  const handlers = new Map<string, Handler>();
  const pi: ExtensionAPI = {
    on(event, handler) {
      handlers.set(event, handler as Handler);
    },
  };
  return { pi, handlers };
}

async function main() {
  const repoRoot = process.env.APEXYARD_REPO_ROOT || process.cwd();
  console.log(`[harness] APEXYARD_REPO_ROOT = ${repoRoot}`);

  const { pi, handlers } = makeMockPi();
  apexyardMergeGate(pi);

  const toolCall = handlers.get("tool_call");
  if (!toolCall) {
    console.error("FAIL: extension did not register a tool_call handler");
    process.exit(1);
  }

  const ctx: ExtensionContext = { cwd: repoRoot, hasUI: false };

  let failures = 0;

  async function check(name: string, event: ToolCallEvent, expectBlock: boolean) {
    const result = await toolCall!(event, ctx);
    const blocked = result?.block === true;
    const pass = blocked === expectBlock;
    console.log(
      `${pass ? "PASS" : "FAIL"} — ${name}\n` +
        `  command: ${String(event.input.command)}\n` +
        `  expected: ${expectBlock ? "BLOCK" : "ALLOW"}, got: ${blocked ? "BLOCK" : "ALLOW"}` +
        (result?.reason ? `\n  reason (first line): ${result.reason.split("\n")[0]}` : ""),
    );
    if (!pass) failures++;
  }

  // Case 1 — a non-merge bash command must pass through untouched. Proves
  // the adapter doesn't accidentally gate ordinary tool use.
  await check(
    "non-merge command passes through",
    { type: "tool_call", toolCallId: "1", toolName: "bash", input: { command: "echo hello" } },
    false,
  );

  // Case 2 — a non-bash tool call must never reach the hook at all (the
  // hook only knows how to parse a shell command).
  await check(
    "non-bash tool is ignored",
    { type: "tool_call", toolCallId: "2", toolName: "read", input: { path: "README.md" } } as unknown as ToolCallEvent,
    false,
  );

  // Case 3 — merging a PR with no recorded Rex/CEO approval markers must be
  // BLOCKED. Uses a PR number that cannot possibly have real markers.
  await check(
    "ungated merge is BLOCKED (real hook, real gh lookup, no markers)",
    {
      type: "tool_call",
      toolCallId: "3",
      toolName: "bash",
      input: { command: "gh pr merge 999999 --repo me2resh/apexyard --squash" },
    },
    true,
  );

  // Case 4 (optional, only runs if the caller sets ALLOW_TEST_PR) — a real
  // PR that already carries valid, HEAD-matching Rex + CEO markers in this
  // ops root must be ALLOWED. This demonstrates the full allow path against
  // a real merged PR's real approval history, not just the block path.
  const allowTestPr = process.env.ALLOW_TEST_PR;
  if (allowTestPr) {
    await check(
      `previously-approved PR #${allowTestPr} is ALLOWED (real markers, real HEAD match)`,
      {
        type: "tool_call",
        toolCallId: "4",
        toolName: "bash",
        input: { command: `gh pr merge ${allowTestPr} --repo me2resh/apexyard --squash` },
      },
      false,
    );
  } else {
    console.log("SKIPPED — allow-path check (set ALLOW_TEST_PR=<pr-with-real-markers> to run it)");
  }

  console.log(failures === 0 ? "\nALL CHECKS PASSED" : `\n${failures} CHECK(S) FAILED`);
  process.exit(failures === 0 ? 0 : 1);
}

main();
