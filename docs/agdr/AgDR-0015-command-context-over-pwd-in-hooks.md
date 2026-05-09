# Resolve git context from the command, not from `$PWD`, in validation hooks

> In the context of three validation hooks (`validate-branch-name.sh`,
> `validate-pr-create.sh`, `validate-commit-format.sh`) that gate `git push`,
> `gh pr create`, and `git commit` respectively, facing repeated misfires when
> `/fan-out` workers ran from sibling worktrees while the harness's `$PWD` was
> the parent session's directory, I decided to **resolve git context from the
> command's own arguments first and fall back to `$PWD`-derived state only
> when the command is silent**, to achieve worktree-safe validation, accepting
> a small parsing-complexity tax in each hook plus one new shared helper.

## Context

Three independent agents in a recent fan-out session each tripped the same
class of bug:

- `validate-branch-name.sh` reads the branch from `git branch --show-current`,
  which resolves against the harness's `$PWD`. A worker that `cd`'d into its
  own worktree got blocked because the parent `$PWD` was a sibling worktree
  whose branch happened not to match the convention.
- `validate-pr-create.sh` did the same lookup for the trailing
  branch-has-ticket-id check, with the same failure mode under fan-out.
- `validate-commit-format.sh` blocked legitimate `git commit -m "$(cat <<'EOF'
  ...EOF)"` heredoc-substitution invocations because the `-m` value the hook
  read was literal-pre-expansion (`$(cat <<'EOF' ... EOF )`), which
  obviously doesn't match the conventional-commit subject regex.

Each agent invented a different workaround: branch-rename the host worktree,
`git -C` to override resolution, drop a sentinel `onboarding.yaml` to satisfy
the parent-walk, fall back to `gh api .../pulls` to bypass `gh pr create`.
None of those should have been necessary — and the variety of workarounds
demonstrates the cost: every agent re-discovers the bug, every workaround is
invisible to Rex, the worked-around behavior ships, and the hook's enforcement
is hollow.

Same shape as the `gh api .../pulls/<N>/merge` bypass closed in
[#47](https://github.com/me2resh/apexyard/issues/47): the hook read
`$PWD`-derived state instead of parsing the command for the actual context,
and a tool-surface change (or a new harness pattern like fan-out) silently
undermined the rule.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A. Command-arg first, `$PWD` fallback** (chosen) | Worktree-safe in all observed cases. Backwards-compatible — silent-command shapes still resolve via `$PWD` exactly as before. Same shape as `_lib-extract-pr.sh` (#47), so future hook authors have a precedent to follow. Fits cleanly into existing hook structure (a small `extract_*` helper + one `${VAR:-fallback}` line in the hook). | One new helper + parsing tax in three hooks. Heredoc-substitution is a special case (the hook can't read the message; can only detect-and-skip). |
| **B. Always trust the command, never fall back** | Simpler conceptual model. | Breaking change — silent commands (`git push` with no args, no-`--head` `gh pr create`) would suddenly stop validating. Not acceptable; that's the dominant shape today. |
| **C. Walk up from FILE_PATH / refer-by-cwd-token** | Could let other hooks reuse the resolved repo root for downstream lookups. | These three hooks gate Bash commands, not Edit/Write/MultiEdit — there's no `FILE_PATH` to walk from. Doesn't apply. |
| **D. Have the harness export the agent's worktree directory as a hook env var** | One-shot fix — every hook would inherit the right `$PWD` automatically. | Requires a Claude Code harness change, not a framework-side fix. We don't own the harness; can't mandate this. |
| **E. Run hooks via `git -C "$resolved_root"` everywhere** | Forces all `git` calls to a known root. | Doesn't solve the fundamental problem — `$resolved_root` is computed from `$PWD`, so if `$PWD` is wrong, `$resolved_root` is wrong. Just moves the bug. |

## Decision

Chosen: **Option A — command-arg first, `$PWD` fallback**.

Concretely:

1. New shared helper `_lib-extract-push-ref.sh` parses the source ref out of a
   `git push` command, returning empty when the command is silent.
2. `validate-branch-name.sh` sources the helper, takes the push ref when
   present, falls back to `git branch --show-current` otherwise.
3. `validate-pr-create.sh` reads `--head` directly via a one-liner sed
   extraction (the existing hook already does the same for `--repo` and
   `--title`, so no helper warranted yet — promotable later if a fourth hook
   needs the same parse).
4. `validate-commit-format.sh` detects the `git commit -m "$(cat <<EOF ...)"`
   heredoc-substitution pattern and exits 0 with an INFO message recommending
   `git commit -F file` for full validation on multi-line subjects.

Backwards compatibility is preserved: every shape that worked before still
works. Only previously-broken shapes (worktree-isolated fan-out, heredoc
substitution) move from blocked to allowed.

## Consequences

- Worktree-isolated fan-out workers can `git push`, `gh pr create`, and
  `git commit -m "$(cat <<'EOF'...)"` without inventing local workarounds.
  This unblocks the `/fan-out` skill and the parallel-work rule.
- Future hook authors who write a Bash-gating validator should follow this
  pattern by default. The README's new "PWD-vs-command-context distinction"
  section calls this out and lists the existing helpers to centralise the
  parsing.
- The heredoc-substitution skip is a small (bounded) softening of
  `validate-commit-format.sh` — a malformed heredoc body now slips through
  the subject check. The bound is the heredoc-substitution shape itself; the
  more common `git commit -F` shape still validates fully, and operators who
  want validation on a multi-line message have a clear path. Trade-off
  accepted; rationale in the hook's inline comment.
- Two new test files (`test_validate_branch_name_pushref.sh`,
  `test_validate_pr_create_head.sh`, `test_validate_commit_format_heredoc.sh`)
  pin the new behaviour. The full hook test sweep stays green.
- The new helper joins `_lib-extract-pr.sh` as a reusable parsing primitive.
  Same pattern, same tests-co-located convention, same "any change here goes
  here, not inline in the hooks" rule.

## Artifacts

- Issue: [me2resh/apexyard#194](https://github.com/me2resh/apexyard/issues/194)
- Related: [me2resh/apexyard#47](https://github.com/me2resh/apexyard/issues/47) (`gh api .../merge` bypass — same root cause class)
- Helper: `.claude/hooks/_lib-extract-push-ref.sh`
- Patched hooks: `.claude/hooks/validate-branch-name.sh`, `.claude/hooks/validate-pr-create.sh`, `.claude/hooks/validate-commit-format.sh`
- Tests: `.claude/hooks/tests/test_validate_branch_name_pushref.sh`, `.claude/hooks/tests/test_validate_pr_create_head.sh`, `.claude/hooks/tests/test_validate_commit_format_heredoc.sh`
- Doc: `.claude/hooks/README.md` § "PWD-vs-command-context distinction"
