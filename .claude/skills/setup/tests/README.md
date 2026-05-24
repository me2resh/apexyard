# `/setup` tests

Sandbox-based regression tests for the `/setup` skill's file-state outcomes. Each test builds a synthetic fork under `mktemp -d`, runs the file-state actions the SKILL.md prescribes, then asserts the post-state matches the spec.

## What's tested

| Test | Covers | Reference in `SKILL.md` |
|------|--------|-------------------------|
| `test_setup_split_portfolio_v2.sh` | Split-portfolio v2 setup branch — config block with all 7 `portfolio.*` keys, `.apexyard-fork` marker, gitignore additions, `portfolio_validate` happy, `portfolio_is_v2` true, `resolve_ops_root` walks via the marker | Step 2b (config-block mode) + AgDR-0021 § B |
| `test_setup_single_fork.sh` | Single-fork setup branch — placeholder replacement in `onboarding.yaml`, marker written even in single-fork mode, no `portfolio:` block (defaults apply), in-fork registry resolution | Step 6 (single-fork branch) |
| `test_setup_reset.sh` | `--reset` flag — restore `onboarding.yaml` to the framework template defaults, idempotent on re-run | Step 1 (`--reset` mode detection) |

## What's NOT tested

`/setup`'s interactive prompts (Step 2 "describe your stack", Step 2a privacy gate, Step 2c LSP enablement) are out of scope — they're operator-interactive and OS / shell-dependent. The tests target the file-state outcomes that survive every branch of the interactive flow.

The LSP enablement step (Step 2c) is doubly out of scope: it installs language-server binaries and mutates shell rc files. Driving that in a sandbox would require mock prerequisites (npm / pipx / go / rustup) that the framework can't ship.

## Running

```bash
# Individual test
bash .claude/skills/setup/tests/test_setup_split_portfolio_v2.sh

# All setup tests
for t in .claude/skills/setup/tests/test_*.sh; do bash "$t" || exit 1; done
```

## Adding a new test

1. Copy the closest existing test as a starting shape.
2. Match the conventions from `.claude/hooks/tests/test_split_portfolio_v2_migration.sh` (the canonical sandbox-test reference):
   - `set -u` at the top
   - `ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"` to resolve the fork root from the test file's location (four `..` for `setup/tests/test_*.sh`)
   - `red()` / `green()` color helpers + per-case `==` banner echos
   - `mark_pass` / `mark_fail` + a per-test `PASS` / `FAIL` counter
   - Sandbox dir via `mktemp -d`
   - `trap 'rm -rf "$TMP_ROOT"' EXIT` (single-quoted trap, double-quoted variable — shellcheck SC2064)
   - Exit 0 on all-pass, 1 on any fail
3. Source `_lib-portfolio-paths.sh` from the sandbox's `.claude/hooks/` copy (NOT the live fork's) — copying the libs into the sandbox via the `cp "$LIB_*"` lines keeps the test hermetic.
4. Call `portfolio_clear_cache` before each new assertion that re-resolves portfolio paths; otherwise the per-process cache will return stale state from an earlier case.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
