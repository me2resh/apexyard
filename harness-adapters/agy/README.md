# apexyard agy Gate Adapter

`agy-hook.sh` routes Google Antigravity CLI (agy) hook events to the unmodified
ApexYard gates in `.claude/hooks/`. It is a transport. Bash owns every gate
decision. The wrapper prints only `ask` or `deny`. It never prints `allow`,
`force_ask`, or `auto_approve`, and it fails closed.

## Install

Run this once in each clone of the fork:

```bash
bash bin/sync-agy-adapter.sh          # write .agents/hooks.json
bash bin/sync-agy-adapter.sh --check  # exit non-zero on drift
```

`.agents/hooks.json` is gitignored, because it holds this clone's absolute path
to the wrapper. Run the sync again after a `.claude/settings.json` change, or
after you move the clone. Then open agy in the fork root or a folder inside it.
agy keeps trusted folders in `trustedWorkspaces` in its user settings. When agy
started in a new linked worktree, it asked to trust that folder first, although
a parent folder was trusted. A refused trust prompt was not tested.

## How it works

1. `.agents/hooks.json` sends every agy tool call and the session start to
   `agy-hook.sh`, through one catch-all matcher.
2. The wrapper checks the argument shape and sorts the tool into a policy
   class:
   - the gated tools run the gates,
   - a short read-only list gets `ask`,
   - keystroke tools and every unrouted tool get `deny`.
3. The wrapper applies the `permissions.deny` rules of `.claude/settings.json`
   literally.
4. For a gated tool, it maps the call to the Claude Code `tool_name` and
   `tool_input`. It reads the PreToolUse handlers from `.claude/settings.json`
   and runs each matching command unchanged.
5. Exit 2 from any gate gives `deny` with the gate's stderr. When every gate
   passes, the wrapper prints `ask`, and agy applies its own permission check.

The agy wiring is a protected target in the live fork root:
`.agents/hooks.json`, `.agents/plugins/`, `.agents/plugins.json`, and this
folder. Change them in an isolated worktree.

## Testing

```bash
# the wrapper, the generator, the fixtures, and the real gates in a temporary fork
bash .claude/hooks/tests/test_agy_adapter.sh

# the agy wiring is a protected target in the live root, editable in a worktree
bash .claude/hooks/tests/test_protected_agy_wiring.sh
```

The payloads in `.claude/hooks/tests/fixtures/agy-payloads/` have the key
shapes that agy CLI 1.5.14 sent, with synthetic values. No test runs agy.
Google's terms forbid driving agy from another agent, so a person, not an
agent, runs agy for every live check.

## Reference

- Full reference: [`docs/harnesses/agy.md`](../../docs/harnesses/agy.md)
- Decision record: [AgDR-0325](../../docs/agdr/AgDR-0325-agy-harness-adapter.md)
