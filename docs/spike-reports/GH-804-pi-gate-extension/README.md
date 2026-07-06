# Spike #804 prototype — pi gate extension over bash hooks

Throwaway spike artifact. Full findings: [`../pi-gate-extension.md`](../pi-gate-extension.md). Ticket: [me2resh/apexyard#804](https://github.com/me2resh/apexyard/issues/804).

## Files

- `apexyard-merge-gate.ts` — the prototype pi extension. Registers on pi's `tool_call` event, and for `bash` tool calls, shells out to `.claude/hooks/block-unreviewed-merge.sh` unchanged, mapping its exit code to pi's `{ block, reason }` contract.
- `test-harness.ts` — isolated proof harness. Mocks pi's `ExtensionAPI.on()` registration per the documented `tool_call` contract, then drives the extension against the real, unmodified bash hook (real `gh` lookups included).

## Run it

From an apexyard checkout (needs `gh` authenticated against `me2resh/apexyard`, and Node ≥22 for native `.ts` execution):

```bash
cd docs/spike-reports/GH-804-pi-gate-extension
APEXYARD_REPO_ROOT=/path/to/apexyard-checkout node test-harness.ts
```

Add `ALLOW_TEST_PR=<pr-number>` (a real PR in this ops root's `.claude/session/reviews/` with valid, HEAD-matching Rex+CEO markers) to also exercise the allow path against real approval history, not just the block path.

Expected output: 3–4 `PASS` lines (4 if `ALLOW_TEST_PR` is set), ending in `ALL CHECKS PASSED`.
